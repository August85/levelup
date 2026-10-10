## Consensus and Coordination

### Paxos (single-decree and Multi-Paxos)
> Getting a set of unreliable, asynchronous processes to agree on one value, and then on a sequence of values, without ever disagreeing.

**How it works.** Roles are proposer, acceptor and learner, and one process usually plays all three. Ballot numbers are totally ordered and unique per proposer. A common choice is `(round, proposerId)`.

Single-decree, one ballot `n`:

1. **Prepare (1a).** The proposer sends `Prepare(n)` to a quorum of acceptors.
2. **Promise (1b).** An acceptor that has promised nothing higher durably records `promised = n` and replies with the highest-ballot value it has already accepted, if any.
3. **Accept (2a).** Once a majority has promised, the proposer must propose the value with the highest accepted ballot among those replies. It may use its own value only if none was reported.
4. **Accepted (2b).** An acceptor accepts `(n, v)` unless it has since promised a higher ballot. When a majority accepts the same ballot, `v` is chosen.

```text
Proposer      A1        A2        A3
  |--Prep(5)-->|---------->|          |
  |<--Prom-----|<----------|          |
  |--Acc(5,v)->|---------->|          |
  |<--Accd-----|<----------|   v chosen
```

Safety rests on quorum intersection. Any later ballot's Phase 1 quorum overlaps the quorum that accepted `v`, so it learns `v` and must re-propose it.

Multi-Paxos runs one instance per log slot. A stable leader runs Phase 1 once for all future slots, then pays only Phase 2 for each command. A new leader re-runs Phase 1, adopts any values it finds and fills holes with no-ops.

**Complexity.** Single-decree costs 2 round trips (4 message delays to learners). Steady-state Multi-Paxos costs 1 round trip from the leader to a majority. It tolerates `f` failures with `2f+1` acceptors. Each promise and accept needs a durable write before the reply. Flexible Paxos shows that only Phase 1 and Phase 2 quorums must intersect, so `|Q1| + |Q2| > N` is enough.

**Where you meet it.** Chubby, Spanner (one Paxos group per split), Megastore, Cassandra lightweight transactions (Paxos per partition, roughly 4 round trips), Azure Storage's stream manager, and Neo4j and other clustered databases.

**Pitfalls.**
- Replying before the promise or accept record reaches disk. A restarted acceptor then forgets a promise and safety is gone.
- Duelling proposers keep pre-empting each other with higher ballots, which is livelock. Use leader election with backoff.
- The paper leaves out the engineering: log compaction, membership change, read semantics, catch-up and disk corruption. "Paxos Made Live" is the honest account of that gap.
- Linearizable reads need either a round through the log or a leader lease. A local read on the leader is stale after a silent deposition.

**DE judgment.** Almost nobody should write their own Paxos. Choose a battle-tested library or a Raft implementation. Paxos stays the right mental model for reasoning about quorums, and its variants (Flexible, EPaxos, Fast Paxos) earn their place in WAN or leaderless designs. In review, ask:
- Where are ballots persisted, and when relative to the reply?
- How are log holes filled?
- How do reads stay linearizable?
- How does membership change without two disjoint majorities?

### Raft
> Replicated-log consensus designed to be understandable, with a strong leader and a log that only flows from leader to followers.

**How it works.** Time is divided into **terms**, each with at most one leader. Every node persists `currentTerm`, `votedFor` and the log.

1. **Election.** A follower that hears nothing for a randomized timeout (for example 150–300 ms) becomes a candidate. It increments its term and sends `RequestVote`. Voters grant at most one vote per term. They grant it only if the candidate's log is at least as up to date: a higher last term, or the same last term and a last index at least as high.
2. **Replication.** The leader sends `AppendEntries(prevIndex, prevTerm, entries, commitIndex)`. A follower rejects the call if it has no matching entry at `prevIndex`. The leader then backs up `nextIndex` until the logs match, and conflicting suffixes are overwritten.
3. **Commit.** An entry is committed once it is stored on a majority and belongs to the leader's current term. Earlier-term entries are committed only indirectly; this is the "Figure 8" rule.
4. **Membership change.** Use joint consensus (C_old,new), or single-server changes applied one at a time.

```text
term 3:  L [1 2 3 4 5]   commit=4
         F [1 2 3 4]
         F [1 2 3]      <- nextIndex backs off
```

**Complexity.** A commit costs 1 round trip to a majority plus an fsync on each node. Elections take about one timeout plus one round trip. With `2f+1` nodes it tolerates `f` failures. Snapshots bound log size.

**Where you meet it.** etcd (and therefore Kubernetes), Consul, Vault, Nomad, CockroachDB and TiKV (multi-Raft, thousands of groups per node), Kafka KRaft, RabbitMQ quorum queues, YugabyteDB, and MongoDB's replication protocol, which is Raft-derived.

**Pitfalls.**
- **Disruptive servers.** A partitioned node keeps raising its term and deposes a healthy leader when it rejoins. Enable **Pre-Vote** and **CheckQuorum**.
- **Lease reads** depend on bounded clock drift. **ReadIndex** costs a heartbeat round but needs no clock assumptions.
- **The single-server membership-change bug.** The leader must commit an entry in its own term before starting a change.
- Large entries or snapshot transfer can starve heartbeats and trigger spurious elections.
- Skipping fsync, or running on disks that lie about it, silently breaks safety.
- With multi-Raft, per-group heartbeats explode. Coalesce them per node pair.

**DE judgment.** Raft is the default for a replicated control plane or for sharded storage that needs linearizability. Do not use it when you need multi-region writes with low latency, because the leader's region dominates latency. In review, ask:
- Pre-Vote on?
- How are reads served?
- Election timeout versus p99 fsync and GC pauses?
- How are leaders placed across zones?
- What is the snapshot strategy?
- How many Raft groups per node, and what does recovery look like after a node loss?

### Leader leases and fencing tokens
> Ensuring that a node that believes it holds a lock or leadership cannot corrupt shared state after it has silently lost that role.

**How it works.** A **lease** is a lock with an expiry. The grantor promises not to grant it to anyone else until `t_grant + D`. The holder stops acting at `t_start + D − drift_margin`, measured on its own monotonic clock from before it sent the request.

A lease alone is not safe. A process can pause for longer than `D` (GC, VM migration, page fault, a SIGSTOP) and then act on a lease it no longer has. **Fencing** closes that gap:

1. Every successful acquisition returns a strictly increasing **token**, such as a Raft term, a ZooKeeper `zxid` or an epoch counter.
2. The holder attaches the token to every write against the protected resource.
3. The resource remembers the highest token it has seen and rejects any lower one.

```text
C1: get lease tok=33 ..[GC pause]...... write(33) X
C2:            lease expires, tok=34 -- write(34) ok
Storage: max_seen=34 -> rejects 33
```

**Complexity.** Acquisition costs one consensus round in the lock service. Renewal costs one round trip per renewal interval, typically `D/3`. Fencing adds one integer comparison per write, plus durable storage of `max_seen` on the resource.

**Where you meet it.** Chubby (lock sequencers), GFS chunk primaries (60 s leases), Bigtable tablet servers, HDFS NameNode HA (QJM epoch numbers fence the old active), Kafka controller epochs and partition leader epochs, ZooKeeper ephemeral nodes, and etcd/Raft leader leases for local reads.

**Pitfalls.**
- The resource does not check the token. This is the most common failure: the lock service is correct and the storage is not. Kleppmann's critique of Redlock rests on exactly this.
- The lease clock runs on wall time and an NTP step moves it. Use a monotonic clock and assume a bounded rate error, not bounded offset.
- The holder starts timing after receiving the grant rather than before sending the request, which loses a whole round trip of margin.
- A token is checked on one resource but not on a second one the holder also writes.
- A "STONITH" or "kill the old leader" approach with no fencing. Kills fail.

**DE judgment.** Treat leases as a performance optimization (cheap local reads, fewer elections) and fencing as the safety mechanism. If you cannot fence the downstream resource, you do not have mutual exclusion. In that case, design the writes to be idempotent or conditional (compare-and-set on a version) instead. In review, ask:
- What does the storage do with a stale token?
- What is the drift budget?
- What happens on a 30-second pause?

### Two-phase commit
> Making a transaction that spans several independent resource managers commit everywhere or nowhere.

**How it works.** A coordinator drives the participants.

1. **Prepare.** The coordinator sends `PREPARE` to every participant.
2. **Vote.** Each participant validates, writes a durable *prepared* record (redo/undo plus locks held) and votes YES. Otherwise it votes NO and aborts locally. After YES, the participant has given up its right to abort on its own.
3. **Decide.** On all YES, the coordinator force-logs COMMIT. On any NO or a timeout, it decides ABORT.
4. **Complete.** The coordinator sends the decision. Participants apply it, release locks and ack. The coordinator can then forget the transaction.

```text
Coord        P1          P2
  |--PREPARE--->|---------->|
  |<--YES-------|<--YES-----|
  [log COMMIT]
  |--COMMIT---->|---------->|
  |<--ACK-------|<--ACK-----|
```

**Complexity.** Two round trips and `4n` messages for `n` participants. Forced log writes: one per participant at prepare, one for the coordinator's decision, and optionally one per participant at commit. Locks are held for the full two round trips plus fsyncs. Presumed-abort and presumed-commit variants save writes and acks. With one participant you can skip prepare entirely (one-phase commit).

**Where you meet it.** XA/JTA, PostgreSQL `PREPARE TRANSACTION`, MySQL's internal XA between binlog and InnoDB, Spanner (2PC across Paxos groups), CockroachDB (parallel commits, which remove a round trip), Kafka transactions, and sagas' strict cousin in microservice frameworks.

**Pitfalls.**
- **Blocking.** If the coordinator dies after participants vote YES, they hold locks and cannot decide on their own. Three-phase commit does not fix this under partitions.
- Orphaned prepared transactions (for example in Postgres) pin locks and block vacuum indefinitely.
- "Heuristic" commit or abort by an operator breaks atomicity.
- Coordinator state kept in memory or on a single disk.
- Treating a timeout as abort after a participant has already voted YES elsewhere.

**DE judgment.** 2PC is fine, and often the right tool, when the coordinator and the participants are each replicated by consensus. That is Spanner's design, and Gray and Lamport formalize it as Paxos Commit. Avoid it across organizational boundaries or third-party services, where sagas with compensations fit better. In review, ask:
- Is the coordinator's decision log replicated?
- What is the in-doubt recovery path and its SLA?
- How long are locks held at p99?
- Who resolves stuck prepared transactions?

### Percolator-style transactions
> Snapshot-isolated, multi-row ACID transactions layered on a sharded key-value store that only offers single-row atomicity.

**How it works.** A **timestamp oracle** (TSO) hands out monotonically increasing timestamps. Each key has three logical columns: `data@ts`, `lock@ts` and `write@commit_ts → start_ts`. One written key is designated the **primary**, and its lock is the transaction's single source of truth.

1. **Start.** Take `start_ts` from the TSO. Reads see the latest `write` record with a timestamp at or below `start_ts`.
2. **Prewrite.** For each key, using a conditional single-row write: abort if a `write` record exists after `start_ts` (write-write conflict) or if any lock exists. Otherwise write `data@start_ts` and `lock@start_ts`. Secondary locks point to the primary.
3. **Commit.** Take `commit_ts`. On the primary, check that the lock still exists, write `write@commit_ts` and delete the lock. This single-row write is the commit point.
4. **Secondaries.** Their write records are produced and their locks removed asynchronously.

```text
key  data@10  lock@10      write
P    "a"      PRIMARY      @15->10  (commit point)
S1   "b"      ->P          (lazy)
```

A reader that hits a lock at or below its `start_ts` resolves it through the primary. If the primary is committed, it rolls the secondary forward. If the primary lock is gone with no write record, it rolls back. If the primary lock is expired, it aborts the primary.

**Complexity.** Two TSO round trips, plus a prewrite round and a primary commit round. Secondary cleanup is off the critical path. TiKV's async commit and one-phase-commit (1PC) optimizations take latency down to roughly one write round in common cases. The TSO is a central component, so it is batched and pipelined.

**Where you meet it.** Google Percolator (incremental indexing on Bigtable), TiDB/TiKV, and in spirit the transaction-record designs in CockroachDB and YugabyteDB.

**Pitfalls.**
- TSO latency and availability bound every transaction. Cross-region TSO round trips are costly.
- Lock resolution adds tail latency to *readers*. A crashed client leaves locks until a TTL expires.
- Large transactions write many locks and conflict broadly.
- Snapshot isolation permits **write skew**. Use explicit `SELECT FOR UPDATE` or serializable modes.
- Garbage collection of old versions must respect the oldest active `start_ts`.

**DE judgment.** It is a strong pattern when you already have a scalable KV store and need cross-shard transactions without a separate coordinator service. Probe in review:
- TSO placement and failover.
- Lock TTLs and who resolves them.
- Write skew risk in the workload.
- Long-transaction limits.
- Whether the read-heavy path can avoid the TSO, for example with stale reads.

### Viewstamped Replication and ZAB (compared with Raft)
> Two leader-based replicated-log protocols, older than Raft and closely related to it, that differ mainly in how a new leader obtains the log.

**How it works.** All three share a structure: a single leader orders operations, a majority acks before commit, and an epoch number (view, epoch or term) rejects stale leaders.

**Viewstamped Replication** (Oki and Liskov 1988; "Revisited" 2012):
1. The primary assigns `op-number`s and sends `Prepare`. Backups append and send `PrepareOK`. A majority means committed.
2. **View change.** Replicas move to view `v+1` and send `DoViewChange` with their logs to the new primary, which is chosen round-robin by view number. The new primary takes the log with the highest last-normal view and then the highest op-number, and installs it everywhere.
3. A recovery protocol with nonces lets a replica rejoin without having persisted its log, provided a majority stays up.

**ZAB** (ZooKeeper Atomic Broadcast):
1. Transactions carry a `zxid = (epoch, counter)`.
2. Phases: **discovery** (agree on a new epoch and find the most up-to-date follower), **synchronization** (the leader brings followers to its history using DIFF, TRUNC or SNAP), then **broadcast** (two-phase propose/ack/commit).
3. It guarantees **primary order**: a leader's transactions are delivered in its order, and an epoch's transactions all come before the next epoch's.

```text
          leader pick     log to new leader
Raft      most up-to-date   none needed
VR        round-robin       sent in DoViewChange
ZAB       most up-to-date*  sync phase repairs
```
\* ZAB's Fast Leader Election favors the highest zxid.

**Complexity.** All three cost one round trip per commit in steady state and tolerate `f` failures with `2f+1` nodes. A VR view change ships logs, so it is heavier when logs diverge. Raft's election is lighter, but the leader may need many AppendEntries round trips to repair followers.

**Where you meet it.** ZAB in ZooKeeper (and so in HBase, older Kafka, Hadoop HA and Solr). VR influenced Harp, a lineage of BFT protocols (PBFT is VR-shaped) and TigerBeetle, which uses VSR.

**Pitfalls.**
- ZooKeeper reads are served locally and are **sequentially consistent, not linearizable**. Call `sync()` before a read that must see the latest writes.
- ZooKeeper's session and ephemeral-node semantics combined with GC pauses cause "two leaders" bugs in clients unless fencing is used.
- VR without persistence depends on a majority never failing at once. A correlated power loss breaks that.
- Historical ZAB implementation bugs lived in the synchronization phase.

**DE judgment.** Treat them as one family. Choose by ecosystem and operational maturity, not by protocol. In a design review, care less about VR versus Raft and more about these questions:
- Are reads linearizable?
- How is the leader fenced?
- How does the system recover from a correlated crash?
- Is disk durability actually honored?
- Where does an existing ZooKeeper dependency already leak sequential-consistency assumptions into application code?

## Time and Ordering

### Lamport clocks
> Giving events in a distributed system timestamps that respect causality, without synchronized physical clocks.

**How it works.** Each process keeps an integer counter `C`.

1. Before each local event or send, set `C := C + 1`.
2. Stamp every outgoing message with `C`.
3. On receive, set `C := max(C, msg.C) + 1`.

This guarantees the **clock condition**: if `a → b` (a happened before b), then `C(a) < C(b)`. The converse does not hold. `C(a) < C(b)` does not imply `a → b`, because the events may be concurrent. Ordering by `(C, processId)` gives a **total order** consistent with causality, which is enough for deterministic tie-breaking and for Lamport's mutual-exclusion algorithm.

```text
P1: 1 ---- 2(send) ------------- 3
                  \
P2: 1 ----------- max(1,2)+1=3 - 4
```

**Complexity.** O(1) space per process and O(1) (one integer) per message. Updates are constant time.

**Where you meet it.**
- Ballot numbers in Paxos and terms in Raft are Lamport-style logical clocks.
- Operation IDs in sequence CRDTs (RGA, Automerge, Yjs) are `(counter, actorId)` pairs.
- Kafka leader epochs, and the logical part of Hybrid Logical Clocks.
- Distributed mutual exclusion and total-order broadcast textbooks.

**Pitfalls.**
- Using Lamport order to detect conflicts. It cannot tell concurrent from causally ordered, so you will overwrite concurrent updates silently.
- Counter overflow in compact encodings, or a counter reset after restart because it was not persisted. Persist it, or restart above any value you may have emitted.
- The total order says nothing about real time. A user's later action can sort earlier than another user's earlier action.
- Byzantine or buggy nodes can inflate the counter arbitrarily, and every peer follows.

**DE judgment.** Use Lamport clocks when you need a cheap, causality-respecting total order and can accept that concurrent events are ordered arbitrarily. Examples are tie-breaking, CRDT op IDs, and epochs that reject stale leaders. When you need to *detect* concurrency, move to version vectors. When you need order tied to wall time, move to HLC. In review, ask:
- Does anyone interpret this order as "happened before"?
- Does the counter survive restarts?

### Vector clocks
> Capturing the full causal order between events so that concurrent updates can be detected rather than silently ordered.

**How it works.** Each process `i` keeps a vector `V[1..N]`.

1. On a local event or send: `V[i] += 1`. Attach `V` to the message.
2. On receive: `V[j] := max(V[j], msg.V[j])` for all `j`, then `V[i] += 1`.
3. Compare: `V ≤ W` iff every component is ≤. Then `a → b` iff `V(a) < V(b)`. If neither `≤` holds, the events are **concurrent**.

```text
A: [1,0,0] -> [2,0,0]
                 \ msg
B: [0,1,0] ------> [2,2,0]
C: [0,0,1]   concurrent with [2,2,0]
```

In storage systems you usually want **version vectors**, which track one entry per *replica* for versions of a key, not per process event. **Dotted version vectors** fix the sibling explosion that occurs when a server issues versions on behalf of many clients.

**Complexity.** O(N) space per timestamp and per message. Comparison and merge are O(N). The cost grows with the number of actors, so actor choice is the critical design decision.

**Where you meet it.** Amazon Dynamo (the original paper), Riak (dotted version vectors since 2.0), Voldemort, causal-consistency research systems (COPS, Eiger), CRDT metadata (OR-Set/ORSWOT), and distributed debuggers and race detectors (happens-before analysis in ThreadSanitizer uses vector clocks).

**Pitfalls.**
- Using *client IDs* as actors makes vectors grow without bound.
- **Pruning** old entries to cap size causes false concurrency (spurious siblings) or, worse, false dominance (lost writes).
- Applications that never resolve siblings let them accumulate.
- Detecting a conflict is not resolving it. Someone has to write the merge.
- Mixing vector-clock reasoning with LWW timestamps in one code path.

**DE judgment.** Use vector or version vectors when the system must accept concurrent writes and preserve them for merge, as in multi-master or offline-first designs. Avoid them if a single-leader design is acceptable, since it removes the problem. In review, ask:
- What are the actors, and how many?
- What is the pruning policy?
- Who resolves siblings, and is the merge deterministic and commutative?
- What is the worst-case metadata size per key?

### Hybrid Logical Clocks
> Timestamps that respect causality like Lamport clocks yet stay within a bounded distance of physical time, using commodity NTP.

**How it works.** A timestamp is `(l, c)`. `l` tracks the largest physical time observed, and `c` is a logical counter for ties. `pt` is the local physical clock.

1. Local or send event:
   `l' := max(l, pt)`. If `l' == l` then `c += 1`, else `c := 0`. Set `l := l'`.
2. Receive `(lm, cm)`:
   `l' := max(l, lm, pt)`.
   - If `l' == l == lm`: `c := max(c, cm) + 1`.
   - Else if `l' == l`: `c += 1`.
   - Else if `l' == lm`: `c := cm + 1`.
   - Else: `c := 0`.

Properties: `e → f ⇒ hlc(e) < hlc(f)`, and `l − pt ≤ ε`, where ε is the clock-synchronization bound. HLCs are typically packed into 64 bits, for example 48 bits of milliseconds and 16 bits of counter, so they drop into existing timestamp fields.

```text
pt:  100      100      101
P1: (100,0) -send-> P2 had (99,0)
P2: max(99,100,100)=100 -> (100,1)
```

**Complexity.** O(1) space and per-message overhead, the same as Lamport clocks. No extra round trips. The counter stays bounded under bounded skew.

**Where you meet it.** CockroachDB (MVCC timestamps plus uncertainty intervals), YugabyteDB, MongoDB cluster time (causal sessions), and many event-sourcing and CDC pipelines that need sortable, near-real-time IDs.

**Pitfalls.**
- **One clock far in the future drags the whole cluster forward**, because HLC propagates the max. Reject messages beyond a max offset. CockroachDB self-terminates nodes whose skew exceeds `max-offset` (500 ms by default).
- HLC alone does **not** give linearizability. A causally unrelated later transaction can receive a smaller timestamp. Systems add *uncertainty intervals*: a read that sees a value in `(ts, ts+max_offset]` must restart at a higher timestamp, which shows up as read-restart errors and tail latency.
- If ε is underestimated (VM pauses, a broken NTP daemon), correctness assumptions silently break.

**DE judgment.** HLC is the right default for MVCC timestamps and globally sortable event IDs when you lack TrueTime-grade clocks. In review, ask:
- What max-offset is assumed, and what enforces it (monitoring, self-fencing)?
- What isolation does the product claim, and how do uncertainty restarts affect p99?
- What happens when a node's clock jumps?

### TrueTime and commit-wait
> Achieving external consistency (linearizable transactions globally) by making clock uncertainty explicit and waiting it out.

**How it works.** `TT.now()` returns an interval `[earliest, latest]` that is guaranteed to contain absolute time. Its half-width ε comes from GPS receivers and atomic clocks in each datacenter, Marzullo-style intersection across time masters, and a worst-case drift assumption between polls. Historically ε averaged about 4 ms, with a sawtooth of roughly 1–7 ms.

For a read-write transaction:

1. Acquire locks and run 2PC/Paxos as usual.
2. Choose commit timestamp `s ≥ TT.now().latest`, also above any prepared timestamps.
3. **Commit-wait:** do not release locks or acknowledge until `TT.now().earliest > s`. Absolute time has then certainly passed `s`.
4. Any transaction that starts after the client sees the ack gets a larger timestamp, so timestamp order matches real-time order.

```text
      s=latest       wait ~2ε     earliest > s
t: ----|=============|-------------|--> ack
       [  uncertainty  ]
```

Read-only transactions pick `TT.now().latest`, or a stale bound, and read lock-free at any replica whose `t_safe ≥ ts`.

**Complexity.** Commit-wait adds about 2ε of latency. It mostly overlaps Paxos replication, which already takes several milliseconds across zones. There are no extra messages. Snapshot reads at past timestamps cost no coordination.

**Where you meet it.** Spanner and Cloud Spanner. AWS exposes bounded-error clocks through ClockBound and the Amazon Time Sync Service, and Aurora DSQL builds on them. CockroachDB deliberately chose HLC plus uncertainty restarts instead.

**Pitfalls.**
- The guarantee is only as good as the ε bound. A bad oscillator or an uncorrected leap smear understates uncertainty and quietly breaks external consistency.
- When ε rises (time masters unreachable), commit latency rises for everything.
- Leases in Spanner also depend on the clock. Leader-lease disjointness is a TrueTime invariant too.
- Bolting "commit-wait" onto NTP with a guessed ε is not TrueTime.

**DE judgment.** Choose bounded-uncertainty clocks when you need globally linearizable transactions without a central timestamp oracle and you control the time infrastructure, or your cloud exposes an error bound. Otherwise a TSO (single region) or HLC with uncertainty is more honest. In review, ask:
- Where does ε come from, and is it measured or assumed?
- What happens operationally when ε grows?
- Does every time-dependent invariant (leases, commit order) use the same bounded clock?

## Membership and Failure Detection

### Gossip (epidemic dissemination)
> Spreading information to every node of a large, churning cluster with no central coordinator, at low per-node cost.

**How it works.** Each round (for example every second), every node picks `k` random peers (the fanout) and exchanges state.

- **Push:** send what I know. It is fast early in the spread and slow at the tail.
- **Pull:** ask what they know. It is slow early and fast at the tail.
- **Push-pull:** exchange digests, then send only the newer entries. This is the usual production choice.

Demers et al. distinguish **anti-entropy** (periodically reconcile full state; this always converges) from **rumor mongering** (spread a hot update until it stops being news, then stop; cheaper, with a small chance of missing nodes, so it is backed by anti-entropy).

```text
round 0:  ●○○○○○○○
round 1:  ●●○○○○○○
round 2:  ●●●●○○○○
round 3:  ●●●●●●●●   ~log2(N) rounds
```

State is usually a map of `node → (version/heartbeat, attributes)`, merged by higher version.

**Complexity.** Infection reaches all N nodes in O(log N) rounds with high probability. Per-node load is O(k) messages per round regardless of N. Total messages per update are about O(N log N) for push. Bandwidth scales with state size times fanout, which is the real limit.

**Where you meet it.** Cassandra and ScyllaDB (membership, schema versions, token ownership), Consul, Serf and Nomad through HashiCorp memberlist, Redis Cluster's bus, Akka Cluster, CockroachDB (cluster settings and liveness hints), and Bitcoin/Ethereum transaction propagation.

**Pitfalls.**
- **Gossiping corrupted state.** Amazon S3's July 2008 outage started with a single bit-flipped gossip message that spread everywhere. Checksum messages and validate merged state.
- State grows with cluster size. Full-state exchanges at 1,000+ nodes swamp the network.
- "Converges eventually" hides a long tail. A slow, partitioned or overloaded node can lag minutes behind.
- Removed nodes come back as zombies when stale peers re-gossip them. Use tombstones with expiry.
- Cross-datacenter gossip needs topology awareness.

**DE judgment.** Use gossip for *soft*, convergent metadata (membership hints, load, schema versions) where eventual agreement is fine. Never use it for decisions that must be agreed, such as ownership changes that need a lock or consensus. In review, ask:
- State size at 10x nodes?
- Message checksums?
- How are departures tombstoned?
- What depends on gossip having converged, and how is that checked?

### SWIM
> Scalable membership and failure detection with constant per-node load and a false-positive rate that does not grow with cluster size.

**How it works.** Every protocol period `T`, each member runs:

1. **Direct probe.** Pick a member, in random round-robin order, and send `ping`. Wait for `ack`.
2. **Indirect probe.** On timeout, ask `k` random members to `ping-req` the target. They probe it and forward any ack. This separates "target is dead" from "my path to it is bad".
3. **Suspicion.** If there is still no ack, mark the target *suspect*, not dead, and disseminate that.
4. **Refutation.** A suspected node that hears about it increments its **incarnation number** and broadcasts `alive(inc+1)`, which overrides the suspicion.
5. **Confirmation.** If not refuted within the suspicion timeout, declare it *faulty*.

Membership updates are **piggybacked** on ping and ack traffic, infection-style, so no separate broadcast is needed.

```text
A --ping--> C   (timeout)
A --ping-req--> B --ping--> C
A <----ack----- B <--ack--- C
```

**Complexity.** Per-member load is O(1) messages per period. Expected time to first detection is about `T · e/(e−1)` periods. Dissemination takes O(log N) periods. The false-positive probability is independent of N for fixed `k`.

**Where you meet it.** HashiCorp memberlist (Consul, Nomad, Serf) with the **Lifeguard** extensions, Uber Ringpop, Apache Cassandra's discussions of replacements, many service meshes and game-server fleets.

**Pitfalls.**
- **A slow prober.** A CPU-starved or GC-paused node times out on healthy peers and accuses them. Lifeguard adds local-health awareness, which stretches your own timeouts when you miss acks yourself, and dynamic suspicion timeouts.
- UDP packet loss or MTU limits truncate piggyback buffers, so dissemination stalls.
- An asymmetric partition makes each half declare the other dead. Merging back requires periodic full-state sync, for example over TCP.
- Tuning `T` and the suspicion multiplier for a WAN like a LAN.

**DE judgment.** SWIM (with Lifeguard) is the default when you need a decentralized membership list for hundreds to tens of thousands of nodes. Treat its output as a hint, and gate authoritative actions such as shard reassignment behind consensus. In review, ask:
- Is Lifeguard or an equivalent on?
- What happens to the system on a false positive (flapping cost)?
- How are rejoins after partition handled?
- Is gossip traffic isolated from data-plane congestion?

### Phi accrual failure detector
> Replacing a binary "alive/dead" timeout with a continuous suspicion level that adapts to observed network behavior.

**How it works.**

1. Record inter-arrival times of heartbeats from each peer in a sliding window, for example the last 1,000.
2. Model the distribution. The original paper and Akka use a normal distribution with mean μ and standard deviation σ. Cassandra approximates it as exponential.
3. At time `t_now`, with the last heartbeat at `t_last`:
   `φ = −log10( P_later(t_now − t_last) )`,
   where `P_later(x)` is the probability that a heartbeat arrives more than `x` after the previous one.
4. Each application picks a threshold. φ = 1 means about a 10% chance the suspicion is wrong, φ = 2 means about 1%, and φ = 8 means about 10⁻⁸.

```text
phi
 8 |                       ____  convict
   |                  ___/
 2 |            ___/
 0 |___________/
   +----+----+----+----+-----> time since hb
```

**Complexity.** O(window) memory per monitored peer. φ costs O(1) to compute when μ and σ are kept incrementally. There are no extra messages beyond heartbeats.

**Where you meet it.** Cassandra (`phi_convict_threshold`, default 8), Akka Cluster and Akka Remote, ScyllaDB, and many custom cluster managers inspired by the Hayashibara et al. 2004 paper.

**Pitfalls.**
- **Long GC pauses or stop-the-world events** on the *sender* produce a φ spike. On the *monitor*, they make every peer look dead at once. Detect your own pauses and discount them.
- In a very regular network, σ approaches zero and φ jumps to infinity on tiny jitter. Clamp to a minimum σ, as Akka's `min-std-deviation` does.
- After a peer restart or a network change, the window reflects stale behavior. Bootstrap with a conservative prior.
- When heartbeats share a TCP connection with bulk data, head-of-line blocking looks like failure.
- Cross-datacenter links need separate thresholds or detectors.

**DE judgment.** Use phi accrual when different consumers want different trade-offs between false positives and detection latency. For example, stop routing reads at a low φ and evict from membership at a high φ. It is still a heuristic. In review, ask:
- What does the system *do* at each threshold, and how costly is a wrong conviction?
- What are the minimum σ and heartbeat interval?
- Is heartbeat traffic prioritized or isolated?

### Chandy-Lamport snapshots
> Recording a consistent global state of a running distributed system, including in-flight messages, without stopping it.

**How it works.** Assume reliable FIFO channels.

1. **Initiator.** Record your local state, then send a **marker** on every outgoing channel.
2. **On receiving the first marker** (on channel `c`): record your local state, record the state of `c` as empty, send markers on all outgoing channels, and start recording messages on all *other* incoming channels.
3. **On receiving a marker on channel `c` after already recording:** stop recording `c`. Its state is the messages received on `c` since you recorded your local state.
4. The snapshot is complete when every process has received a marker on every incoming channel.

The recorded states form a **consistent cut**: no message's receipt is recorded without its send.

```text
P ---m1---[M]------>  Q
          records P
Q receives m1, then M: m1 is in Q's state
P <--m2--- Q (before Q's M): m2 in chan Q->P
```

**Complexity.** O(E) marker messages for E channels. Snapshot time is bounded by the longest marker propagation path. Space is local state plus buffered in-flight messages.

**Where you meet it.**
- **Apache Flink's checkpoints** are a variant: asynchronous barrier snapshotting. Aligned barriers avoid recording channel state by briefly blocking inputs. *Unaligned checkpoints* record in-flight buffers, which is Chandy-Lamport's channel state proper.
- Hazelcast Jet and other stream processors.
- Distributed debugging, global predicate detection and deadlock detection.

**Pitfalls.**
- **Non-FIFO channels** break the algorithm. Use Lai-Yang (message coloring) or similar instead.
- **Backpressure delays markers.** In Flink, aligned checkpoints under backpressure can take minutes and time out. That is why unaligned checkpoints exist.
- The snapshot captures internal state only. External side effects (emails sent, rows written to an external database) need transactional or idempotent sinks for exactly-once.
- Channel state can be large under load.
- Dynamic topologies complicate the definition of the channel set.

**DE judgment.** Use it, or a framework that embeds it, when you need consistent recovery points for a stateful dataflow without pausing the world. In review, ask:
- Are channels FIFO?
- What is the checkpoint duration at peak backpressure?
- What is the size of state plus in-flight data?
- How do sinks achieve exactly-once (two-phase commit sinks, idempotent writes)?
- What recovery time does a snapshot interval imply?

## Replication and Convergence

### Quorum reads/writes (W+R>N) with read repair and hinted handoff
> Tunable consistency and availability for leaderless replicated storage by requiring overlapping sets of replicas for reads and writes.

**How it works.** Each key has N replicas, usually the next N nodes on a hash ring. The coordinator sends each write to all N and returns after W acks. It sends each read to R replicas, or to all of them with R counted, and returns the newest version. With `W + R > N`, every read quorum intersects every write quorum.

- **Read repair:** when the replies disagree, the coordinator writes the newest version back to stale replicas, synchronously or in the background.
- **Hinted handoff:** if a home replica is down, another node accepts the write with a "hint" and replays it when the owner returns.
- **Sloppy quorum:** counting those stand-in nodes toward W, which keeps writes available during failures.

```text
N=3, W=2, R=2
write -> [A ✓] [B ✓] [C ✗]
read  ->       [B v2][C v1]  -> return v2
              repair C <- v2
```

**Complexity.** Latency is the W-th (or R-th) fastest of N replicas. Message cost is N per write and between R and N per read. Read repair adds writes proportional to divergence. Hints consume disk on the stand-in.

**Where you meet it.** Amazon Dynamo, Cassandra and ScyllaDB (`ONE`/`QUORUM`/`LOCAL_QUORUM`), Riak and Voldemort. The pattern also appears in object stores and leaderless metadata services.

**Pitfalls.**
- **W+R>N is not linearizability.** Concurrent reads during a write can see new then old. A failed write that reached fewer than W replicas is not rolled back and may surface later.
- **Sloppy quorums break the intersection guarantee.** Hints sit on nodes outside the preference list.
- **Last-write-wins with skewed clocks** silently discards newer writes.
- Deletes need tombstones. If repair does not run within the tombstone grace period (`gc_grace_seconds`), deleted data **resurrects**.
- Hints pile up and overload a recovering node, so throttle replay.
- `QUORUM` across regions puts WAN latency on every request.

**DE judgment.** Use it for high-availability, partition-tolerant workloads that can tolerate per-key eventual consistency and have a sane conflict policy, such as idempotent writes or CRDTs. If the product needs read-your-writes, compare-and-set or uniqueness, use consensus per shard instead. In review, ask:
- Which consistency levels are actually used per query?
- How are conflicts resolved?
- What is the repair cadence versus the tombstone grace period?
- What is the clock-skew policy?

### Merkle-tree anti-entropy
> Finding and fixing the differences between two large replicas while exchanging data proportional to the difference, not the dataset.

**How it works.**

1. Each replica partitions its key range into leaves, by hash or token range, and hashes the content of each leaf.
2. Internal nodes hash their children, up to a root.
3. Two replicas compare roots. If they are equal, they are in sync.
4. If not, recurse only into children whose hashes differ.
5. At mismatched leaves, stream the rows in those ranges, or compare finer-grained, and apply them with normal conflict resolution.

```text
        root(≠)
       /        \
   h01(=)      h23(≠)
              /     \
          h2(=)    h3(≠) -> sync range 3
```

**Complexity.** It takes O(log L) round trips to locate a differing leaf among L leaves. Bandwidth is O(d · log L) hashes plus the data in differing leaves. Building a tree requires a full scan, O(n), unless the tree is maintained incrementally. Memory is O(L).

**Where you meet it.** Dynamo, Cassandra repair (validation compaction builds a Merkle tree per range), Riak active anti-entropy (persistent, incrementally updated hash trees), ScyllaDB row-level repair, Bitcoin and certificate transparency (inclusion proofs rather than repair), and ZFS/Git/IPFS (content addressing).

**Pitfalls.**
- **Overstreaming:** coarse leaves mean one differing row ships a whole range. Cassandra's fixed-depth trees over large token ranges were notorious for this.
- **Rebuild cost:** a full scan per repair competes with foreground I/O. Incremental or persistent trees fix this at the cost of write amplification.
- The replicas must hash the *same* range boundaries. Token ownership changes during repair cause false mismatches.
- Hashing must be over a canonical encoding, including tombstones and timestamps. Otherwise replicas that are logically equal never converge.
- Repairs that never finish on huge clusters, which leads to tombstone resurrection.

**DE judgment.** Every leaderless replicated store needs a background anti-entropy path. Read repair alone only fixes keys that are read. In review, ask:
- How often does full repair complete, and does it beat the tombstone grace period?
- Are trees persistent or rebuilt each time?
- What is the leaf granularity?
- What is the I/O budget for repair?
- How is repair coordinated so that it does not run concurrently on overlapping ranges?

### CRDTs (G-Counter, PN-Counter, OR-Set, LWW-Register)
> Data types whose replicas can be updated independently and always converge to the same value when they exchange state, with no coordination.

**How it works.**
- **State-based (CvRDT):** state forms a join-semilattice, and `merge` is a least upper bound (commutative, associative, idempotent). Any gossip order works.
- **Op-based (CmRDT):** concurrent operations commute, but delivery must be causal and exactly-once.
- **Delta-state CRDTs** ship only the recent join-deltas.

The four data types:
- **G-Counter:** a vector `P[i]`. Node `i` increments `P[i]`. Value = `ΣP`. Merge = element-wise max.
- **PN-Counter:** two G-Counters `(P, N)`. Value = `ΣP − ΣN`.
- **LWW-Register:** `(value, timestamp, nodeId)`. Merge keeps the larger `(ts, nodeId)`.
- **OR-Set (add-wins):** each `add(e)` creates a unique tag `(e, dot)`. `remove(e)` deletes only the tags it has *observed*. An add concurrent with a remove survives. ORSWOT uses version vectors to avoid keeping tombstones.

```text
G-Counter merge (element-wise max)
A: [3,0,1]   B: [2,4,1]
merged: [3,4,1]  value = 8
```

**Complexity.** A counter takes O(#actors) space. An OR-Set takes O(elements + tags), plus tombstones or a version vector. Merge is linear in state size. Updates are O(1) locally with zero coordination latency.

**Where you meet it.** Riak data types, Redis Enterprise Active-Active, Azure Cosmos DB's multi-region conflict handling, collaborative editors (Automerge, Yjs and other sequence CRDTs), Phoenix Presence, SoundCloud's Roshi (LWW-element set), and offline-first mobile sync engines.

**Pitfalls.**
- **Metadata growth:** actor IDs, dots and tombstones accumulate, and garbage collection needs causal stability, which is a coordination problem again.
- **Invariants you cannot express:** "balance ≥ 0" or "unique username" cannot be maintained without coordination. Bounded counters or escrow help, partially.
- **LWW silently loses data** under concurrency and is only as good as your clocks.
- **Surprising semantics:** add-wins versus remove-wins, and interleaving anomalies in text CRDTs. Product owners must sign off on them.
- Op-based designs fail quietly when delivery is not actually causal or exactly-once.

**DE judgment.** Use CRDTs when availability under partition or offline operation is a product requirement and the data's merge semantics are natural: counters, sets, presence, collaborative documents. Do not use them to dodge consensus for data with invariants. In review, ask:
- Which merge semantics does each field have, and who agreed to them?
- What is the metadata growth bound and the garbage-collection strategy?
- Where do non-commutative business rules live?
- How is schema evolution handled for merged state?

### Chain replication
> Strongly consistent, high-throughput primary-backup replication by arranging replicas in a line instead of a star.

**How it works.** Replicas are ordered `head → … → tail`.

1. **Writes** go to the head. Each node applies the write and forwards it to its successor.
2. The **tail** applies the write. The write is now committed, and the tail acks the client (or acks flow back up the chain).
3. **Reads** go to the tail, which only holds committed data. This gives linearizability for free.
4. A separate **configuration master**, itself replicated by Paxos or Raft, detects failures and splices the chain.
   - A failed head is replaced by its successor.
   - A failed tail is replaced by its predecessor.
   - A failed middle node is bypassed, and its predecessor re-sends unacked updates.

```text
client-write                     client-read
     |                                ^
     v                                |
  [HEAD] --> [MID] --> [MID] --> [TAIL]
                                   |
                     ack to client <+
```

**CRAQ** lets any node serve reads. A node marks versions *dirty* until the tail's ack propagates back, and for a dirty key it asks the tail for the committed version number.

**Complexity.** Write latency is N sequential hops, versus one parallel round in quorum or primary-backup star replication. Each node sends each update once, so throughput is bounded by a single link, not the head's fan-out. It tolerates N−1 failures with N replicas, because the external master holds the quorum. Reads are 1 hop to the tail, or local with CRAQ.

**Where you meet it.** FAWN-KV, HyperDex, the CORFU and Tango shared-log storage units, Hibari, Microsoft's research systems, in-network replication (NetChain), and many internal block and object stores that use chained pipelines. HDFS's write pipeline is chain-shaped, though it is not chain replication's full protocol.

**Pitfalls.**
- **One slow node stalls the whole chain.** Gray failures (a degraded disk or NIC) dominate tail latency, so detect and splice out slow nodes, not just dead ones.
- Latency grows linearly with chain length, and cross-zone chains add WAN hops in series.
- The configuration master must be consensus-backed and authoritative. Nodes that act on a stale configuration need epoch fencing.
- Tail reads concentrate load on one node, which is why CRAQ or striping many chains across nodes exists.
- Recovery must re-send in-flight updates exactly once, in order.

**DE judgment.** Choose chain replication for storage where throughput and simple strong consistency matter more than write latency, and where you already run a consensus service for configuration. Prefer quorum-based Raft or Paxos when p99 write latency or tolerance of slow nodes matters. In review, ask:
- How are slow (not dead) nodes detected and removed?
- How is the chain configuration fenced?
- What is the chain length versus the latency SLO?
- How are reads distributed?
