# Distributed Systems

> At Distinguished level you are the person who notices, before launch, that a design quietly assumes synchronized clocks, exactly-once delivery, or a network that fails cleanly, and who can explain what that assumption will cost at 3 a.m.

## Overview

Most production incidents in large systems are not caused by exotic algorithms failing. They come from ordinary components meeting conditions their designers assumed away. A timeout fires during a GC pause. A retry duplicates a payment. A failover promotes a replica that was 40 seconds behind. A cache cluster recovers and the backing store collapses under the cold-start load.

This volume covers the eight topics that sit underneath nearly every architecture review:

- **Consensus**: how a group of machines agrees on one value or one ordered log despite crashes.
- **Replication**: how copies of data are kept, and what "kept" really promises.
- **Partitioning**: how data and load are split, and what breaks at the seams.
- **Consistency models**: the contract a system offers about what reads can observe.
- **Time and ordering**: why wall clocks lie and what to use instead.
- **Failure taxonomy**: the shapes failure actually takes, especially the partial and slow ones.
- **Idempotency**: how to make retries safe, which is the only practical road to "exactly once".
- **Backpressure**: how systems stay stable when demand exceeds capacity.

A Principal Engineer typically knows these mechanisms well enough to build with them. The step to Distinguished is different in kind. You are expected to spot the implicit assumption in someone else's design, to name the failure mode it creates, to estimate its blast radius, and to recommend the cheapest change that removes it. You are also expected to know when the "correct" answer is overkill.

The recurring theme: **every distributed guarantee is bought with latency, availability, or operational complexity.** Your job is to make sure the organization is buying the guarantees it needs, knows what it paid, and is not accidentally relying on guarantees it never bought.

## Core Concepts

### Consensus

**The problem.** Consensus means a set of processes agree on a single value such that: every non-faulty process eventually decides (termination), all deciders pick the same value (agreement), and the value was proposed by someone (validity). Repeating consensus for each slot of a log gives you **state machine replication**: every replica applies the same commands in the same order and therefore reaches the same state.

**Why it is hard.** The FLP result (Fischer, Lynch, Paterson, 1985) proves that in a fully asynchronous system, no deterministic algorithm can guarantee consensus terminates if even one process may crash. The reason is that you cannot distinguish a crashed process from a slow one.

Practical protocols escape FLP by keeping safety unconditional and making liveness depend on timing. They never decide two different values, but they may stall when the network misbehaves. This is the right trade, and it explains a production pattern: a consensus cluster under network stress does not corrupt data, it stops making progress.

**Quorums.** With `N = 2f + 1` nodes, a majority quorum of `f + 1` tolerates `f` crash failures. Any two majorities intersect in at least one node, and that overlapping node carries knowledge of prior decisions forward. Five nodes tolerate two failures. Four nodes still tolerate only one, so even cluster sizes add cost without adding fault tolerance.

**Paxos.** Lamport's Paxos runs in two phases:

1. **Prepare/Promise.** A proposer picks a ballot number `b` and asks acceptors to promise to ignore lower ballots. Each acceptor replies with the highest-ballot value it has already accepted, if any.
2. **Accept/Accepted.** If a majority promised, the proposer must propose the value from the highest ballot it was told about (or its own value if none). Once a majority accepts, the value is chosen.

Multi-Paxos amortizes phase 1: a stable leader runs it once for all future slots and then needs only one round trip per command. The classic paper is famously terse about everything a real system needs: leader election, log compaction, membership changes, and client interaction.

**Raft.** Raft (Ongaro and Ousterhout, 2014) is equivalent in power to Multi-Paxos but decomposes the problem for understandability:

- **Terms.** Time is divided into numbered terms, each with at most one leader. A node that sees a higher term steps down.
- **Election.** Followers that hear no heartbeat within a randomized timeout become candidates and request votes. A node only votes for a candidate whose log is at least as up to date as its own. This rule guarantees the new leader holds every committed entry.
- **Log replication.** The leader appends entries and sends `AppendEntries` carrying the previous entry's index and term. Followers reject on mismatch, and the leader backs up until logs agree (the Log Matching property).
- **Commit.** An entry is committed once stored on a majority. Subtly, a leader only counts replicas to commit entries from its **own** term. Older entries commit indirectly. Getting this wrong is the "Figure 8" bug in the Raft paper, where a committed-looking entry is later overwritten.

```text
Client --> Leader (term 7)
             | append idx 42
             +--> F1  ack ----+
             +--> F2  ack ----+--> majority (3/5)
             +--> F3  (slow)  |    commit idx 42
             +--> F4  (down)  |    apply, reply
                              v
           commitIndex advanced in next heartbeat
```

**Other members of the family.** Viewstamped Replication (Oki and Liskov, 1988) predates Paxos's publication and is close to Raft in structure. Zab powers ZooKeeper. EPaxos and other leaderless variants trade complexity for lower latency across regions by avoiding a single leader. Flexible Paxos (Howard et al., 2016) showed that only the election quorum and the replication quorum must intersect; replication quorums can be smaller if election quorums are larger.

**Byzantine consensus.** If nodes can lie, you need `N = 3f + 1` (PBFT, Castro and Liskov, 1999), more message rounds, and usually cryptographic signatures. Inside a single organization's datacenter, Byzantine tolerance is almost never worth it. Corrupt-but-not-malicious faults such as bit flips and firmware bugs are better handled with checksums end to end.

**Production details that matter more than the algorithm:**

- **Reads.** A leader that serves reads from local state may be a deposed leader that does not know it yet. Correct options: route reads through the log (slow), use **ReadIndex** (confirm leadership with a heartbeat round, then read), or use **leader leases** (assume leadership for a bounded time). Leases depend on bounded clock drift, which you are now relying on for correctness.
- **Pre-vote and CheckQuorum.** Without pre-vote, a node isolated by a partial partition keeps incrementing its term and, on rejoining, forces a needless election. Without CheckQuorum, a leader cut off from the majority keeps thinking it leads. Both are standard extensions; check that your library has them on.
- **Membership changes.** Changing the cluster from configuration C_old to C_new must not allow two disjoint majorities. Raft uses joint consensus or one-node-at-a-time changes. Ad hoc "just edit the peer list" changes have caused split brain.
- **Disk.** Consensus is only as durable as `fsync`. Systems that ack before fsync, or run on storage that lies about flushes, lose committed data on correlated power loss.
- **Snapshots and log compaction.** A slow follower that falls behind the compacted log needs a full snapshot transfer, which can saturate the leader's network and look like an outage.

**When to use consensus directly.** Almost never in application code. Use it via a proven system: etcd, ZooKeeper, Consul, or a database that embeds it (Spanner, CockroachDB, TiKV, FoundationDB). Keep the consensus group small (3 or 5), keep its data small (metadata, leases, configuration), and push bulk data elsewhere.

### Replication

Replication exists for three reasons that often conflict: **durability** (survive loss of a copy), **availability** (keep serving when a node is down), and **read scaling or locality** (serve from more places, closer to users). Be explicit about which one a design is buying.

**Single-leader replication.** One node accepts writes and ships a log (physical WAL, logical row changes, or statements) to followers. Simple, gives a total order of writes, and supports strong consistency if reads go to the leader.

The key knob is when the leader acknowledges:

| Mode | Ack after | Risk |
|---|---|---|
| Async | Local write | Loses recent writes on failover |
| Semi-sync | One replica | Stalls if replica slow |
| Sync quorum | Majority | Higher write latency |

Asynchronous replication with automatic failover is the most common source of silent data loss. When the leader dies, the most caught-up follower is promoted, and anything it had not received is gone. If the old leader returns and is not fenced, it may also accept writes, creating divergent histories.

**Multi-leader replication.** Several nodes accept writes, usually one per region, and replicate asynchronously to each other. It gives low local write latency and survives inter-region partitions. The cost is conflicts: two regions modify the same row concurrently. Resolution options:

- **Last-writer-wins (LWW)** by timestamp. Simple and lossy: one write silently disappears, and clock skew decides which.
- **Application merge.** Correct but pushes complexity to every developer.
- **CRDTs** (Shapiro et al., 2011). Data types whose merge is commutative, associative, and idempotent (counters, sets, registers, sequences), so replicas converge regardless of delivery order. Powerful for collaborative or counter-like data; awkward for invariants such as "balance never negative".
- **Avoid conflicts by routing.** Give each record a home region. Most robust in practice.

**Leaderless replication.** Dynamo-style systems (Dynamo 2007, Cassandra, Riak) send writes to `N` replicas and wait for `W` acks; reads query `R` replicas. If `R + W > N`, read and write sets overlap.

Overlap does **not** by itself give linearizability. Concurrent writes, partially failed writes that leave a value on fewer than `W` nodes, and **sloppy quorums** (writing to stand-in nodes during failures, then hinted handoff) all allow stale or flip-flopping reads. Convergence relies on read repair and anti-entropy, typically Merkle-tree comparison between replicas. Version vectors detect concurrent writes so they can be surfaced as siblings rather than silently overwritten.

**Chain replication** (van Renesse and Schneider, 2004). Writes enter at the head and flow down a chain; the tail acknowledges and serves reads. It offers strong consistency with high throughput, but latency grows with chain length and a slow node stalls the chain. CRAQ lets any node serve clean reads. An external configuration service (itself consensus-backed) manages membership.

**Replication lag and read anomalies.** With async followers, a user can write then fail to read their own write, or see a value and then see an older one on refresh. Mitigations: read-your-writes by routing a user to the leader for a window after writing, or by passing a version token (log position) that a follower must reach before serving; monotonic reads by pinning a session to one replica.

**Durability is about independence.** Three replicas in one rack share a power domain. Three replicas on the same storage firmware share a bug. Three replicas behind the same deployment pipeline share a bad config push. Count failure domains, not copies.

### Partitioning

Partitioning (sharding) splits data so each node owns a subset. It is how you scale writes and storage beyond one machine. Its costs show up at the boundaries: cross-partition queries, transactions, and rebalancing.

**Range partitioning.** Keys are split into contiguous ranges (Bigtable, HBase, Spanner, CockroachDB). Range scans are efficient and splits can be adaptive. The failure mode is sequential keys: timestamps or auto-increment IDs send all writes to the last range. Fixes include key salting, hashing a prefix, or reversing bits, all of which sacrifice scan locality.

**Hash partitioning.** A hash of the key picks the partition, spreading load evenly but destroying ordering. Range queries become scatter-gather across all partitions.

**Consistent hashing** (Karger et al., 1997). Nodes and keys map onto a ring; a key belongs to the next node clockwise. Adding or removing a node moves only about `1/n` of keys. Virtual nodes (many points per physical node) smooth the distribution and let heterogeneous hardware take proportional load.

```text
          hash ring (0 .. 2^64)
        A1 ----- B1 ----- C1
       /                    \
     C2       keys map        A2
       \     clockwise to   /
        B2 --- the next ---B3
              node token
```

Alternatives: **rendezvous (highest random weight) hashing** computes a score per node per key and needs no ring; **jump consistent hash** (Lamping and Veach, 2014) is tiny and fast but only supports numbered buckets added or removed at the end. Many modern systems instead use a fixed large number of logical partitions (say 4,096) mapped to nodes by a directory. Rebalancing then means moving whole partitions, which is easier to reason about and throttle.

**Hot keys and skew.** Even perfect hashing cannot split one key. A celebrity account, a global counter, or a popular product can saturate a single partition. Mitigations, from cheapest:

- Cache the hot read path in front of the partition.
- Split writes across `k` sub-keys (`counter#0..k-1`) and aggregate on read.
- Detect hot keys dynamically and replicate them for reads.
- Redesign the data model so the hot entity is not a single row.

**Secondary indexes.** A **local** (document-partitioned) index lives with each partition, so writes are cheap but queries by the indexed field scatter to every partition. A **global** (term-partitioned) index is itself partitioned by the indexed value, so reads are targeted but every write touches a second partition, usually updated asynchronously. Global indexes are therefore often stale. Ask which kind a design uses and whether callers know.

**Cross-partition transactions.** Two-phase commit (2PC) coordinates atomic commit across partitions. Its classic weakness is blocking: if the coordinator dies after participants vote yes, they hold locks until it returns. Modern systems run the coordinator and participants on consensus groups (Spanner) so no single crash blocks, or use deterministic ordering (Calvin, 2012) to avoid 2PC entirely. Each cross-partition transaction costs extra round trips; design the partition key so the common transactions are single-partition.

**Rebalancing.** Moving data is heavy I/O on the busiest nodes at the worst time, because you rebalance when nodes are overloaded. Rebalancing must be rate-limited and should generally be operator-approved. Fully automatic rebalancing combined with automatic failure detection can amplify a transient slowdown into a cluster-wide data movement storm.

**Choosing the partition key** is the most consequential and least reversible decision. A good key has high cardinality, even access distribution, and aligns with the dominant query and transaction boundaries (often tenant ID or user ID). Re-keying a large production dataset is a multi-quarter migration.

### Consistency Models

A consistency model is a contract: the set of histories of reads and writes that the system is allowed to produce. Stronger models allow fewer surprising histories and cost more coordination.

There are two families that are often confused:

- **Single-object (register) models** describe operations on individual keys: linearizability, sequential, causal, eventual.
- **Transaction isolation levels** describe groups of operations: serializability, snapshot isolation, read committed.

**Linearizability** (Herlihy and Wing, 1990). Every operation appears to take effect atomically at some instant between its invocation and response, consistent with real time. If write A completes before read B starts, B sees A or something later. This is what people mean by "behaves like a single copy". It is required for leader election, locks, uniqueness constraints, and anything where a stale read causes a wrong decision.

**Sequential consistency.** All processes see operations in one total order consistent with each process's program order, but that order need not respect real time across processes.

**Causal consistency.** If operation A could have influenced B (same session before it, or B read A's result), everyone sees A before B. Concurrent operations may be seen in different orders. Causal consistency is the strongest model that remains available during partitions, which makes it attractive for geo-distributed systems (COPS, 2011).

**Session guarantees** (Terry et al., 1994): read-your-writes, monotonic reads, monotonic writes, writes-follow-reads. These are cheap, local, and fix most user-visible anomalies of eventually consistent systems. They are an underused middle ground.

**Eventual consistency.** If writes stop, replicas converge. It says nothing about what you read meanwhile, nor how long "eventually" is. On its own it is a liveness property with no safety content. Always ask for the measured convergence lag and the conflict resolution rule.

**Transaction isolation.**

| Level | Prevents | Still allows |
|---|---|---|
| Read committed | Dirty reads | Non-repeatable reads |
| Snapshot (SI) | Lost update* | Write skew |
| Serializable | All of the above | Real-time anomalies |
| Strict serial. | All, plus real time | (none) |

*Most SI implementations use first-committer-wins, which prevents lost updates on the same row.

**Write skew** is the anomaly to remember. Two doctors are on call; each transaction checks "at least one other doctor is on call", sees yes in its snapshot, and removes itself. Both commit, and no one is on call. SI allows this because the two transactions wrote different rows. Fixes: serializable snapshot isolation (Cahill et al., 2008; PostgreSQL's SERIALIZABLE), explicit locking of the rows read (`SELECT ... FOR UPDATE`), or materializing the conflict as a row both transactions must write.

Note the ANSI isolation level names are defined ambiguously (Berenson et al., 1995). "Repeatable read" means different things in MySQL and PostgreSQL. Ask what anomalies are prevented, not what the level is called.

**Strict serializability** is serializability plus linearizability: transactions appear in an order consistent with real time. Spanner calls this external consistency. Plain serializability allows a transaction committed later in real time to be ordered earlier, which can surprise users ("I saved it, my colleague refreshed, and it was not there").

**CAP and PACELC.** CAP (Brewer's conjecture, proved by Gilbert and Lynch, 2002) says that during a network partition a system must choose between linearizability and availability for every request. It is narrow: it concerns one consistency model, one failure type, and a strict definition of availability. PACELC (Abadi, 2012) is more useful day to day: if Partitioned, choose Availability or Consistency; Else, choose Latency or Consistency. Partitions are rare; the latency cost of coordination is paid on every request.

**How consistency is actually verified.** Claims in documentation frequently do not match behavior under faults. Jepsen (Kyle Kingsbury) has found violations of advertised guarantees in many widely used databases. Treat a vendor's consistency claim as a hypothesis until it has been tested with fault injection and a history checker (Knossos, Elle).

### Time and Ordering

**Wall clocks are not trustworthy.** Quartz oscillators drift (tens of parts per million is typical, so seconds per day without correction). NTP corrects drift but can step the clock backward or forward, and typical accuracy across a datacenter is milliseconds, worse over the internet and much worse when NTP is misconfigured. Leap seconds have caused real outages. VM migration and pauses make it worse.

Rules that follow:

- Measure durations with a **monotonic clock**, never by subtracting wall-clock times.
- Never order events across machines by wall-clock timestamp if correctness depends on the order.
- Never let an expiry computed on one machine be checked against another machine's clock without a safety margin larger than the skew bound you actually monitor.

**Process pauses.** A thread can stop for seconds at any point: stop-the-world GC, VM steal, swapping, a slow page fault on a network disk, `SIGSTOP`. Code like "check lease is valid, then write" can pause between the check and the write. The lease expires, another node acquires it, and the paused node then writes anyway.

**Fencing tokens** fix this. The lock service issues a monotonically increasing token with each grant. The storage system remembers the highest token it has seen and rejects writes with lower ones. Safety then depends on the storage system, not on the client's sense of time. A lock without fencing is a performance hint, not a correctness mechanism. This is the core of Kleppmann's critique of Redlock.

```text
Client A: lock (token 33) .. GC pause ......... write(33)
Lock svc:            lease expires | grant 34 to B
Client B:                          write(34) ok
Storage:  max_seen=34 --> reject write(33)
```

**Logical clocks.** Lamport clocks (1978) assign each event a counter: increment on each local event, and on receive take `max(local, received) + 1`. If A happened before B, then `L(A) < L(B)`. The converse does not hold, so Lamport clocks cannot detect concurrency. They give a total order (with node ID as tiebreaker) consistent with causality.

**Vector clocks** (Fidge and Mattern, 1988) keep one counter per node. Comparing two vectors tells you whether one event happened before the other or whether they are concurrent. That is exactly what you need to detect conflicting writes. The cost is size proportional to the number of writers; version vectors per replica rather than per client keep this bounded.

**Hybrid logical clocks** (Kulkarni et al., 2014) combine a physical timestamp with a logical counter. They stay close to wall-clock time (useful for humans and for snapshot reads "as of" a time) while preserving causality even when clocks are skewed. CockroachDB and others use HLCs, combined with a configured maximum clock offset; nodes that exceed it shut themselves down rather than risk anomalies.

**TrueTime** (Spanner, 2012) exposes time as an interval `[earliest, latest]` with bounded uncertainty, backed by GPS and atomic clocks in each datacenter. To guarantee external consistency, a transaction picks a commit timestamp and then **waits out the uncertainty** (commit wait) before making the commit visible. The guarantee is only as good as the uncertainty bound, which is why Google invested in hardware to keep it to a few milliseconds. Cloud providers now offer comparable precision time services; the design principle stands regardless: if you depend on time for correctness, you must know and enforce the error bound.

**Ordering in practice.** Most systems need ordering only within a scope: per key, per partition, per user, per aggregate. Global total order requires a single sequencer or consensus and does not scale. A DE-level question is always: "ordering relative to what, and does anything actually need more than per-key order?"

### Failure Taxonomy

Failure models define what your design claims to tolerate. Most outages come from failures outside the model the design assumed.

| Model | What happens | Typical handling |
|---|---|---|
| Crash-stop | Node halts forever | Replace, re-replicate |
| Crash-recovery | Halts, returns later | Durable state, epochs |
| Omission | Messages lost | Retries, idempotency |
| Timing | Too slow, or clock off | Timeouts, hedging |
| Byzantine | Arbitrary or wrong | Checksums, BFT |

Crash-recovery is the realistic default. A node that comes back with stale state and stale beliefs ("I am the leader") is more dangerous than one that never returns. Use epochs or generation numbers so returning nodes discover they are out of date.

**Network partitions are rarely clean.** Real partitions are often:

- **Partial**: A can reach B, B can reach C, A cannot reach C. Studies of real systems (Alfatafta et al., 2020) found partial partitions caused catastrophic failures in many mature systems, because leader election and membership logic assumed symmetric reachability.
- **Asymmetric**: packets flow one way only.
- **Lossy**: the link is up but drops a percentage of packets, so health checks pass while real traffic suffers.

**Gray failure** (Huang et al., 2017). The system's failure detector believes a component is healthy while its clients experience failure. A disk that serves health-check reads from cache but times out real I/O; a host that answers pings while its application thread pool is exhausted. The gap between what the observer sees and what users see is the root issue. The fix is to measure health from the client's perspective, with real requests, and to combine signals from many observers.

**Fail-slow** (Gunawi et al., 2018). Hardware that keeps working but at a fraction of normal speed (a degraded NIC, a disk remapping sectors, a throttled CPU). In a quorum or chain system, one slow node can slow every operation. Fail-slow is often harder to handle than fail-stop, because nothing triggers failover.

**Metastable failures** (Bronson et al., 2021). The system enters a bad state, typically triggered by a load spike or a capacity loss, and **stays** there even after the trigger is removed, because a feedback loop sustains the overload. Classic loops: retries that multiply load; cache misses after a cache restart pushing the database past capacity, which keeps the cache from refilling; timeouts causing work that is discarded and redone. Recovery requires breaking the loop (shedding load hard, disabling retries), not just removing the trigger.

```text
  trigger (spike / cache flush)
            |
            v
  latency up --> timeouts --> retries
      ^                          |
      |                          v
      +------ more load <--------+
  (loop persists after trigger ends)
```

**Correlated failures.** Independent-failure math ("three nines each, so nine nines together") is almost always wrong. Shared dependencies correlate failure: the same config system, the same DNS, the same certificate expiry, the same kernel version, the same deployment wave, the same leap second. The most important availability work is finding and breaking these correlations.

**Error handling is where systems fail.** Yuan et al. (2014) studied catastrophic failures in Cassandra, HBase, HDFS, MapReduce, and Redis and found that the large majority were caused by incorrect handling of non-fatal errors that the software had explicitly signaled. Often the handler was empty, logged and continued, or aborted the whole cluster. Many would have been caught by simple tests of the error path. Reviewing error-handling code is high-leverage.

**Failure detection is a trade-off.** Short timeouts detect real failures fast but trigger false failovers during GC pauses or brief congestion; each false failover has its own cost and risk. Long timeouts mean longer outages. Adaptive detectors (phi accrual, used in Cassandra and Akka) estimate the probability of failure from the observed heartbeat distribution rather than using a fixed threshold.

### Idempotency

An operation is idempotent if applying it multiple times has the same effect as applying it once. In a distributed system, a client that times out does not know whether the request was lost, processed and the reply lost, or still in progress. The only safe recovery is to retry, and retries are only safe if the operation is idempotent.

**Delivery semantics are about effects, not messages.**

- **At-most-once**: never retry. Lose messages on failure.
- **At-least-once**: retry until acknowledged. Duplicates happen.
- **Exactly-once**: not achievable as a delivery guarantee between independent systems. What is achievable is **effectively-once processing**: at-least-once delivery plus idempotent or deduplicated application of effects.

When a vendor says "exactly once", ask "within what boundary?" Kafka's exactly-once semantics (idempotent producers with sequence numbers, plus transactions that atomically commit output records and consumer offsets) hold within Kafka. The moment a consumer calls an external API or writes to a separate database, you are back to needing idempotency at that boundary.

**Naturally idempotent operations.** `SET x = 5`, `DELETE id=7`, `PUT /resource/123` with a full representation. Non-idempotent: `x = x + 1`, `POST /payments`, "append to list", "send email". Convert where possible: an increment becomes "set balance to 105 if version = 41" (conditional write), and an append becomes "insert row with ID 9f3c" (deduplicated by primary key).

**Idempotency keys.** The client generates a unique key per logical operation (not per attempt) and sends it with every retry. The server:

1. Atomically inserts the key with status `in_progress`. If it already exists, return the stored result, or `409` if still in progress.
2. Performs the operation.
3. Stores the result with the key, **in the same transaction as the effect** whenever possible.
4. Returns the result.

The critical detail is step 3's atomicity. If the effect commits and the key record does not (or vice versa), a retry either duplicates the effect or returns a result for something that never happened. When the effect is in an external system you do not control, pass your idempotency key through to that system if it supports one, or record intent first and reconcile.

Other details that bite:

- **Fingerprint the request.** If a retry with the same key carries a different payload, reject it. Otherwise a client bug silently returns the wrong result.
- **Retention window.** Keys must live longer than the longest possible retry horizon, including queued and replayed messages. A 24-hour window does not help a message replayed from a 7-day log.
- **Scope.** Keys are typically scoped per client or tenant to prevent collisions and cross-tenant leakage.
- **Who generates the key.** If the server generates it after receipt, a lost response leaves the client without the key. The originator must generate it.

**The dual-write problem.** "Write to the database, then publish an event" is not atomic. A crash between them loses the event; reversing the order publishes events for writes that never happened. The **transactional outbox** pattern writes the event to an outbox table in the same database transaction; a relay publishes from the outbox (or change data capture tails the log). Publishing is at-least-once, so consumers must be idempotent too, typically by recording processed message IDs in the same transaction as their effects.

**Sagas.** Long-running workflows that span services cannot hold a distributed transaction. A saga is a sequence of local transactions, each with a compensating action. Compensations must themselves be idempotent and retryable, and some actions (sending an email, shipping a package) cannot be compensated, only followed by a corrective action. Durable workflow engines (Temporal, Step Functions, and similar) make sagas manageable by persisting progress.

### Backpressure

Every system has a finite capacity. When offered load exceeds it, something must give: latency grows, requests fail, or memory fills until the process dies. Backpressure is the set of mechanisms that make the "something gives" explicit and controlled, ideally by slowing producers.

**Queueing basics every reviewer should know.**

- **Little's Law**: `L = λ × W`. Items in system equal arrival rate times time in system. If a service handles 2,000 requests per second at 50 ms, about 100 requests are in flight. If latency rises to 500 ms at the same rate, 1,000 are in flight, which may exhaust a 256-thread pool or a connection limit.
- **Utilization knee**: in a simple M/M/1 queue, mean time in system scales as `1 / (1 - ρ)` where `ρ` is utilization. At 50% it is 2x service time; at 90%, 10x; at 99%, 100x. Real systems with variance in service time behave worse. Running hot is cheaper in hardware and more expensive in tail latency and fragility.
- **Unbounded queues are a bug.** They convert an overload into unbounded latency and then an out-of-memory crash. Requests sitting in the queue are often already timed out by their callers, so the server does work no one will use. This is a common way metastable failures sustain themselves.

**Mechanisms, from the producer back to the consumer.**

- **Flow control**: the consumer grants credit and the producer sends only that much (TCP windows, HTTP/2 stream windows, Reactive Streams `request(n)`, gRPC flow control). This is true backpressure: the slow party paces the fast one.
- **Bounded queues with rejection**: when full, reject immediately with a retryable signal (HTTP 429 or 503 with `Retry-After`). Fast rejection is much cheaper than slow failure.
- **Admission control and load shedding**: decide at the front door what to accept. Shed by priority (keep checkout, drop recommendations), by cost, or by tenant quota. Shed before doing expensive work, not after.
- **Deadline propagation**: pass the remaining time budget downstream (gRPC deadlines do this). Each hop drops work whose deadline has already passed instead of computing a result nobody will read.
- **Queue discipline under overload**: FIFO serves the oldest, most likely already abandoned requests first. Adaptive LIFO or CoDel-style approaches (Facebook described using controlled delay plus adaptive LIFO in their RPC stack) keep queue time bounded and serve requests that can still succeed.
- **Concurrency limits**: cap in-flight requests per downstream rather than requests per second. Adaptive limiters (in the style of TCP Vegas or AIMD) discover capacity from observed latency.

**Retries are a load multiplier.** If each of five layers retries three times, one user request can become `3^5 = 243` requests at the bottom during an outage. Rules:

- Retry at **one** layer, usually closest to the user or the one with the most context.
- Use **exponential backoff with jitter**. Without jitter, synchronized clients retry in waves (the AWS Architecture Blog's analysis of "full jitter" is the standard reference).
- Use a **retry budget**: retries limited to a fraction (for example 10%) of normal traffic per client. Under widespread failure this caps amplification at 1.1x instead of 3x.
- Never retry non-idempotent operations without an idempotency key.
- Do not retry on errors that signal overload unless honoring `Retry-After`.

**Circuit breakers** stop calling a dependency that is failing, fail fast, and periodically probe for recovery. They protect the caller's resources (threads, connections) and give the dependency room to recover. A poorly tuned breaker flaps, or opens for an entire service because one shard is unhealthy. Consider per-endpoint or per-shard breakers.

**Tail latency.** At fan-out, the slowest leaf dominates. If one server's 99th percentile is 1 second, a request fanning out to 100 such servers sees at least one 1-second response about 63% of the time. Dean and Barroso (2013) describe **hedged requests**: send a second request after the 95th percentile delay and take whichever returns first, which adds a few percent of load and sharply cuts tail latency. Hedging must be bounded and is only safe for idempotent reads.

```text
fan-out 100, each leaf p99 = 1s
P(no slow leaf) = 0.99^100 ~ 0.37
=> ~63% of requests wait ~1s
hedge at p95: tail drops, load +~5%
```

**Autoscaling is not backpressure.** Scaling takes minutes; overload kills in seconds. New instances also add cold caches, connection storms against the database, and warmup costs. Autoscaling handles trends; backpressure and shedding handle spikes. A design that relies on autoscaling alone for spikes is a design that will fall over during one.

## Design Principles

- **Name the failure model.** Every design should state what it tolerates: how many node crashes, which partitions, how much clock skew, whether disks can lie about fsync. Undocumented assumptions become production incidents.
- **Safety unconditional, liveness conditional.** Prefer designs that may stall under bad conditions but never corrupt or lose committed data. Make stalls observable and recoverable.
- **Buy the weakest consistency that is correct, and document it.** Strong consistency where a stale read causes a wrong decision (money, uniqueness, permissions, leadership); session guarantees or eventual consistency elsewhere. Write down which is which per API.
- **Never use wall-clock time for correctness without a bound.** Use monotonic clocks for durations, logical or hybrid clocks for ordering, fencing tokens for exclusion, and an enforced maximum skew wherever time remains in the critical path.
- **Every write path is idempotent.** Assume every message will be delivered at least twice and every request retried. Design keys, conditional writes, and dedup records accordingly.
- **Bound everything.** Queues, retries, timeouts, concurrency, batch sizes, cache sizes, fan-out, and payloads. An unbounded resource is a future outage with an unknown trigger.
- **Fail fast and shed early.** A quick rejection is cheaper for everyone than a slow failure. Reject at the edge, before expensive work.
- **Retry at one layer, with jitter and a budget.** Multiplicative retries turn partial outages into total ones.
- **Make the common transaction single-partition.** Choose partition keys that align with the dominant access and transaction boundary. Cross-partition coordination should be the exception.
- **Count failure domains, not replicas.** Replicas that share power, network, software version, configuration, or deployment wave are one replica for correlated failures.
- **Detect from the client's point of view.** Health checks that exercise trivial paths miss gray failures. Measure what users experience and alert on it.
- **Fence the past.** Every leader, lease, and configuration has an epoch. Stale actors must be rejected by the resource they touch, not trusted to know they are stale.
- **Keep consensus small.** Put metadata, leases, and configuration in a consensus system; keep bulk data and hot paths out of it.
- **Design the recovery path, not just the steady state.** Cold caches, rebuilds, rebalances, and restarts are when systems are most fragile. Rate-limit them and test them.
- **Prefer static stability.** During a dependency failure, a system should keep doing what it was doing (serve last known config, keep existing capacity) rather than needing the failed dependency to recover.

## Trade-offs and Decision Frameworks

### Consistency versus latency and availability

Start from the cost of a wrong answer, not from the technology.

1. **What decision is made from this read?** If a stale read causes money to move twice, a duplicate username, or an unauthorized access, you need linearizable reads or a serializable transaction at that point.
2. **What does the user perceive?** If stale data is merely confusing ("my post disappeared"), session guarantees usually fix it cheaply.
3. **What is the write topology?** Single-region writes make strong consistency cheap (one round trip within a region). Multi-region strong consistency costs at least one cross-region round trip per write, often 60 to 200 ms.

| Need | Typical choice | Cost |
|---|---|---|
| Money, uniqueness | Serializable, leader | Latency, failover |
| User sees own data | Session guarantees | Routing complexity |
| Feeds, counters | Eventual, CRDT | Anomalies, merge logic |
| Global writes | Home region per row | Cross-region on move |

### Replication topology

- **Single leader, sync quorum**: the default for systems of record. Failover is safe if the replication protocol is consensus-based.
- **Single leader, async**: acceptable when losing seconds of writes on failover is tolerable and stated. Pair with fencing to prevent split brain.
- **Multi-leader**: justified for multi-region write availability or offline clients. Budget for conflict resolution as a product feature, not an afterthought.
- **Leaderless**: high write availability and tunable latency for data that tolerates convergence (time series, activity logs, carts). Weak fit for invariants.

A useful heuristic: if the team cannot explain the conflict resolution rule in one sentence, they should not run multi-leader.

### Build versus buy for coordination

Implementing consensus or a replication protocol in-house is a multi-year commitment with a long tail of subtle bugs. The bar to justify it: an existing system demonstrably cannot meet a hard requirement, and the team has the expertise and testing infrastructure (deterministic simulation, fault injection, model checking with TLA+ or similar) to get it right. FoundationDB's deterministic simulation testing is the exemplar of what "right" costs.

### Partitioning strategy

| Workload | Strategy | Watch for |
|---|---|---|
| Range scans by key | Range | Sequential hot spots |
| Point lookups | Hash | Scatter for ranges |
| Multi-tenant | Tenant ID | Whale tenants |
| Time series | Time + hash | Write hot partition |

Plan for the largest entity, not the average. In multi-tenant systems, the biggest tenant is often 100 to 1,000 times the median, and it eventually needs a dedicated partition or cell.

### Timeouts

Set timeouts from data, not intuition. A reasonable start is a bit above the dependency's p99.9 under normal load, but always less than the caller's own deadline minus local work. Timeouts must shrink as you go deeper in the call graph. A downstream timeout longer than its caller's guarantees wasted work.

### Synchronous call versus asynchronous message

Synchronous calls couple availability: the caller is down when the callee is down. Queues decouple availability but add latency, ordering questions, poison messages, and an operational component. Use async when the caller does not need the result to respond, when work is bursty, or when the callee's availability is lower than yours. Use sync when the user is waiting on the answer and the dependency is reliable. A queue does not remove overload, it moves it; the consumer still needs backpressure and the queue needs a bound and an age alert.

### Cells and blast radius

For very large services, partition the whole stack (not just the data) into independent cells, each serving a subset of customers with its own instances, databases, and queues. A bug, bad deploy, or poison request then affects one cell. The cost is a routing layer, more operational units, and harder cross-cell features. Cell architectures pair naturally with shuffle sharding, where each customer is assigned to a random small subset of workers, so two customers rarely share all their workers.

## Failure Modes and War Stories

These are well-documented public incidents. The details are simplified; read the original postmortems for the full narratives.

### GitHub, October 2018: 43 seconds that cost a day

A network maintenance event disconnected GitHub's US East Coast data center from its primary hub for about 43 seconds. Their MySQL topology manager (Orchestrator, backed by Raft) reacted to the partition by promoting replicas in the US West Coast to primaries. When connectivity returned, writes had landed on both sides, and the West Coast primaries were now serving application traffic across the continent with much higher latency.

The team chose to preserve data integrity over fast recovery: they restored from backups and replayed, and the service was degraded for about 24 hours.

**Lessons**: automatic cross-region failover on short partitions can be worse than waiting. Failover policy must consider whether the application tier can tolerate the new topology. Decide in advance how to reconcile divergent writes.

### Cloudflare, November 2020: a partially failed switch

A network switch began partially failing, dropping some traffic between some nodes. An etcd cluster used to coordinate PostgreSQL high availability saw some members able to reach each other and others not. Leader elections flapped repeatedly. The cluster manager reacted by failing over the database, and replicas then needed lengthy rebuilds. Cloudflare's write-up described it as a Byzantine-like failure caused by inconsistent reachability.

**Lessons**: partial partitions defeat logic built for clean ones. Pre-vote and CheckQuorum matter. Automated failover of a primary database triggered by a coordination layer's instability can cascade.

### AWS EBS, April 2011: the re-mirroring storm

During a network change in one US-East Availability Zone, traffic was mistakenly shifted to a lower-capacity network. Many EBS storage nodes lost contact with their replicas and simultaneously began searching for free space to re-mirror their data. The rush exhausted capacity, and nodes that could not find space kept retrying. The control plane became overloaded and the impact spread beyond the original zone's EBS clusters. Recovery took days for some volumes.

**Lessons**: recovery actions are load. When many nodes run the same recovery at once, the recovery becomes the outage. Rate-limit and back off recovery work.

### AWS DynamoDB, September 2015: metadata retry storm

Storage servers periodically fetch their partition membership from a metadata service. A growth in the size of membership data (driven by a new feature) pushed some fetch times past the timeout. Servers that timed out retried and also removed themselves from service, increasing load on the metadata service further. The system stayed in this state until engineers added capacity and paused requests.

**Lessons**: a textbook metastable failure. Timeouts plus retries created a loop that persisted after the initial slowness. Timeouts set close to normal latency are fragile when payloads grow.

### AWS Kinesis, November 2020: thread limits

Adding capacity to the Kinesis front-end fleet caused each front-end server to exceed an operating system thread limit, because each server maintained a thread per other front-end server for shard-map gossip. Servers failed to build the shard map and could not route requests. Because the dependency was widespread (Cognito, CloudWatch, and others used Kinesis), impact spread.

**Lessons**: O(n squared) mesh communication hides until n crosses a threshold. Scaling up can be the trigger. Know your resource limits per node as a function of fleet size.

### AWS us-east-1, October 2025: DNS automation race

A latent race condition in DynamoDB's automated DNS management for its regional endpoint resulted in an empty DNS record, so clients could not resolve the endpoint. Many AWS services depend on DynamoDB internally, and recovery of dependent systems (including EC2 instance launches) took considerably longer than the DNS fix itself, as backlogs and dependent state had to drain and rebuild.

**Lessons**: control-plane automation is a distributed system with its own concurrency bugs. Recovery time is dominated by the dependency graph and backlogs, not the root-cause fix.

### Facebook, October 2021: correlated everything

A command intended to assess backbone capacity unintentionally disconnected Facebook's data centers from each other. DNS servers, designed to withdraw their BGP advertisements when they could not reach data centers, did exactly that, making Facebook's services unreachable from the internet. Internal tools needed for diagnosis and repair depended on the same network, and physical access was slowed by security systems.

**Lessons**: a safety mechanism (withdraw when unhealthy) became a correlated failure across all locations. Out-of-band access must truly be out of band.

### Leap seconds: 2012 and 2017

The June 2012 leap second triggered a Linux kernel bug that caused high CPU in many applications (Java, MySQL and others), affecting multiple large sites. On January 1, 2017, Cloudflare's DNS code computed a negative duration because wall-clock time appeared to go backward during the leap second; a random-number function panicked on the negative value.

**Lessons**: use monotonic clocks for durations. Prefer leap smearing. Treat time as an input that can misbehave.

### Generic patterns you will meet

- **Thundering herd after cache recovery**: cache restarts empty, every miss hits the database, which falls over. Mitigate with request coalescing, gradual warmup, and serving stale on error.
- **Split brain from unfenced failover**: old primary returns from a pause and accepts writes. Mitigate with fencing tokens or STONITH and epoch checks at the storage layer.
- **Poison message**: one message crashes the consumer, is redelivered, crashes it again, and blocks the partition. Mitigate with retry counts and dead-letter queues, plus alerts on dead-letter depth.
- **Health check death spiral**: overloaded instances fail health checks, are removed, and their load moves to the survivors, which then fail. Mitigate with fail-open behavior when most of a fleet is unhealthy.

## What a DE Probes

- **"What is your failure model, written down?"** Good answer: specific numbers and types (two node crashes, one AZ, partial partitions, clock skew up to X ms, fsync honored) with a test plan for each.
- **"Walk me through a write from client to durable. When do you ack?"** Good answer: names the exact point (after quorum fsync, after leader-local write) and what is lost on each kind of crash.
- **"What happens to an old leader that wakes up after a 30-second pause?"** Good answer: epochs or fencing tokens checked by the storage layer, so its writes are rejected regardless of what it believes.
- **"Which reads must be linearizable, and how are they served?"** Good answer: a short list of decision-critical reads served via leader with ReadIndex or lease (with a skew bound), and everything else explicitly marked as possibly stale.
- **"What isolation level do your transactions run at, and what anomaly does it allow that matters here?"** Good answer: names the level, the anomaly (often write skew), and the specific invariant that is protected by locking or serializable mode.
- **"Where does wall-clock time affect correctness?"** Good answer: nowhere, or a specific place with a monitored and enforced bound and a safety margin.
- **"What is the partition key, and what is your largest tenant or hottest key relative to median?"** Good answer: a measured skew ratio, a plan for whales, and a hot-key mitigation.
- **"How do you rebalance, and what stops rebalancing from becoming the outage?"** Good answer: rate limits, operator gates or bounded automation, and a tested pause switch.
- **"Show me the idempotency story for each mutating endpoint and consumer."** Good answer: keys generated by the originator, stored atomically with the effect, request fingerprinting, retention longer than the max replay horizon.
- **"How does an event get published after a database write?"** Good answer: outbox or CDC, with idempotent consumers. A red flag is "we write to the DB and then publish".
- **"What happens at 2x peak load? At 10x?"** Good answer: specific shedding behavior, which traffic is protected, bounded queues, and evidence from a load test rather than theory.
- **"Count the retries in the call path."** Good answer: retries at one layer only, with jittered backoff and a budget; deeper layers fail fast.
- **"How do timeouts relate across layers?"** Good answer: deadlines propagate, each hop's timeout fits within the caller's remaining budget.
- **"What does recovery look like from a full cold start?"** Good answer: a tested procedure with cache warming or request coalescing, bounded reconnection rates, and a known time to recover.
- **"What would a gray failure look like here, and who would notice first?"** Good answer: client-side and synthetic probes that exercise real paths, not just liveness pings; outlier detection on per-host latency.
- **"Which dependencies are shared across your replicas or cells?"** Good answer: an explicit list (DNS, config, auth, deployment pipeline) with mitigations such as static stability, staggered deploys, and cached last-known-good config.
- **"If the coordination service (etcd, ZooKeeper) is down for an hour, what still works?"** Good answer: the data plane keeps serving on cached state; only changes are blocked.
- **"How have you verified the consistency claims?"** Good answer: fault-injection tests with a history checker, or reliance on a system with published independent verification, plus game days.

## Review Checklist

- [ ] Failure model is documented: crash count, partition types, clock skew bound, disk durability assumptions.
- [ ] Acknowledgement point for writes is explicit, and data loss on failover is quantified (RPO).
- [ ] Failover is fenced: epochs or fencing tokens are checked by the resource, not the client.
- [ ] Consensus systems run 3 or 5 voters, with pre-vote and CheckQuorum (or equivalent) enabled.
- [ ] Consensus clusters store only small metadata; bulk data is elsewhere.
- [ ] Each API documents its consistency guarantee (linearizable, session, eventual).
- [ ] Decision-critical reads are served linearizably, not from possibly stale replicas.
- [ ] Transaction isolation level is named, and write-skew risks are addressed.
- [ ] No correctness logic depends on wall-clock comparisons across machines without an enforced bound.
- [ ] Durations use monotonic clocks.
- [ ] Partition key aligns with dominant queries and transactions; skew and hot keys are measured.
- [ ] Largest-tenant or hottest-key plan exists.
- [ ] Rebalancing and re-replication are rate-limited and can be paused.
- [ ] Secondary index type (local or global) and its staleness are known to callers.
- [ ] Replicas span independent failure domains, including software version and deploy wave.
- [ ] Every mutating endpoint accepts an idempotency key or is naturally idempotent.
- [ ] Idempotency records are stored atomically with effects and outlive the replay horizon.
- [ ] Event publication uses an outbox or CDC; consumers deduplicate.
- [ ] Poison messages go to a dead-letter queue with alerting.
- [ ] All queues are bounded and alert on oldest-message age.
- [ ] Retries happen at one layer, with exponential backoff, jitter, and a retry budget.
- [ ] Deadlines propagate; downstream timeouts are shorter than upstream ones.
- [ ] Load shedding exists at the edge, with priorities, and has been load tested beyond peak.
- [ ] Circuit breakers are scoped finely enough not to isolate healthy capacity.
- [ ] Health checks exercise real dependencies; gray failure detection uses client-side signals.
- [ ] Cold-start and cache-flush recovery has been tested and timed.
- [ ] Data plane is statically stable when the control plane or coordination service is down.
- [ ] Consistency and failover behavior have been verified with fault injection.

## Further Reading

**Books**

- Martin Kleppmann, *Designing Data-Intensive Applications* (O'Reilly). The best single survey of replication, partitioning, transactions, and consistency. Read chapters 5 to 9 twice. A second edition (with Chris Riccomini) updates it.
- Christian Cachin, Rachid Guerraoui, Luís Rodrigues, *Introduction to Reliable and Secure Distributed Programming*. Rigorous treatment of failure models and abstractions.
- Betsy Beyer et al., *Site Reliability Engineering* (Google), especially the chapters on handling overload and addressing cascading failures. Free at sre.google/books.

**Consensus and replication**

- Fischer, Lynch, Paterson, "Impossibility of Distributed Consensus with One Faulty Process" (1985).
- Leslie Lamport, "The Part-Time Parliament" (1998) and "Paxos Made Simple" (2001).
- Chandra, Griesemer, Redstone, "Paxos Made Live: An Engineering Perspective" (2007). What it takes to run Paxos in production.
- Diego Ongaro and John Ousterhout, "In Search of an Understandable Consensus Algorithm" (Raft, 2014), and Ongaro's PhD thesis for pre-vote, membership changes, and reads.
- Howard, Malkhi, Spiegelman, "Flexible Paxos: Quorum Intersection Revisited" (2016).
- Castro and Liskov, "Practical Byzantine Fault Tolerance" (1999).
- van Renesse and Schneider, "Chain Replication for Supporting High Throughput and Availability" (2004).
- DeCandia et al., "Dynamo: Amazon's Highly Available Key-value Store" (2007).
- Shapiro, Preguiça, Baquero, Zawirski, "Conflict-free Replicated Data Types" (2011).

**Partitioning and transactions**

- Karger et al., "Consistent Hashing and Random Trees" (1997).
- Lamping and Veach, "A Fast, Minimal Memory, Consistent Hash Algorithm" (2014).
- Corbett et al., "Spanner: Google's Globally-Distributed Database" (2012).
- Thomson et al., "Calvin: Fast Distributed Transactions for Partitioned Database Systems" (2012).
- Zhou et al., "FoundationDB: A Distributed Unbundled Transactional Key Value Store" (2021), for deterministic simulation testing.

**Consistency and time**

- Herlihy and Wing, "Linearizability: A Correctness Condition for Concurrent Objects" (1990).
- Berenson et al., "A Critique of ANSI SQL Isolation Levels" (1995).
- Atul Adya, PhD thesis, "Weak Consistency: A Generalized Theory and Optimistic Implementations for Distributed Transactions" (1999).
- Cahill, Röhm, Fekete, "Serializable Isolation for Snapshot Databases" (2008).
- Terry et al., "Session Guarantees for Weakly Consistent Replicated Data" (1994).
- Gilbert and Lynch, "Brewer's Conjecture and the Feasibility of Consistent, Available, Partition-Tolerant Web Services" (2002).
- Daniel Abadi, "Consistency Tradeoffs in Modern Distributed Database System Design" (PACELC, 2012).
- Leslie Lamport, "Time, Clocks, and the Ordering of Events in a Distributed System" (1978).
- Kulkarni et al., "Logical Physical Clocks" (hybrid logical clocks, 2014).
- Martin Kleppmann, "How to do distributed locking" (blog post, 2016) on fencing tokens.
- Jepsen analyses (jepsen.io) and Kingsbury and Alvaro, "Elle: Inferring Isolation Anomalies from Experimental Observations" (2020).

**Failure, overload, and operations**

- Huang et al., "Gray Failure: The Achilles' Heel of Cloud-Scale Systems" (HotOS 2017).
- Gunawi et al., "Fail-Slow at Scale: Evidence of Hardware Performance Faults in Large Production Systems" (FAST 2018).
- Bronson et al., "Metastable Failures in Distributed Systems" (HotOS 2021), and Huang et al., "Metastable Failures in the Wild" (OSDI 2022).
- Alfatafta et al., "Toward a Generic Fault Tolerance Technique for Partial Network Partitioning" (OSDI 2020).
- Yuan et al., "Simple Testing Can Prevent Most Critical Failures" (OSDI 2014).
- Dean and Barroso, "The Tail at Scale" (CACM, 2013).
- Marc Brooker, "Exponential Backoff and Jitter" (AWS Architecture Blog) and the Amazon Builders' Library articles on timeouts, retries, backoff, static stability, and shuffle sharding.
- Ben Maurer, "Fail at Scale" (ACM Queue, 2015), on controlled delay and adaptive LIFO at Facebook.
- Public postmortems: GitHub (October 21, 2018), Cloudflare ("A Byzantine failure in the real world", November 2020), AWS summaries for EBS (April 2011), DynamoDB (September 2015), Kinesis (November 2020), and us-east-1 (October 2025), Facebook engineering on the October 4, 2021 outage.
