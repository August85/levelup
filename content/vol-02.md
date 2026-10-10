# Databases

> The database is where your system's correctness guarantees actually live or die, so a Distinguished Engineer has to reason about storage engines, isolation and replication from the mechanism up, not from the vendor's datasheet.

## Overview

Most production incidents that destroy data, lose money or cause multi-hour outages trace back to a gap between what engineers *believed* the database guaranteed and what it actually did. "We use transactions" is not a correctness argument. Neither is "it's ACID" or "it's strongly consistent." Each of those words hides a dozen design choices, and the defaults differ between products.

At Principal level you usually own a system and pick a database for it. At Distinguished level you set the patterns that dozens of teams copy. You decide which engines the company runs, what the default isolation level is, how sharding is done, and what failover means. Your mistakes get multiplied.

This volume works through the stack from the bottom up:

- **Storage engines.** How B-trees and LSM trees put bytes on disk, and why that sets your write, read and space amplification.
- **Write-ahead logging.** How durability and crash recovery actually work, and where they quietly fail.
- **MVCC.** How databases give readers a stable snapshot without blocking writers, and the garbage it leaves behind.
- **Isolation levels.** What anomalies each level allows, and why the names lie.
- **Distributed SQL.** How Spanner-style systems combine consensus, timestamps and two-phase commit.
- **Sharding.** How to split data, and how that choice constrains you for a decade.
- **Replication topologies.** Single-leader, multi-leader, leaderless and consensus, and how each one fails.
- **Query optimization.** How planners choose plans, why they get it wrong, and how to keep plans stable.

The thread running through all of it: every guarantee has a mechanism, every mechanism has a cost, and every cost shows up somewhere in production. Your job is to know where.

## Core Concepts

### Storage engines: B-trees

The B+tree has been the default on-disk index for fifty years. It is a balanced tree of fixed-size pages, usually 4–16 KB. PostgreSQL uses 8 KB pages and InnoDB uses 16 KB. Interior pages hold separator keys and child pointers. Leaf pages hold either the rows or pointers to them, and leaves are linked to their siblings so range scans can walk sideways.

Fanout is what makes B-trees fast. An 8 KB interior page holding 16-byte keys and pointers has a fanout in the hundreds. Three or four levels address billions of rows. The top levels are almost always cached, so a point lookup usually costs one or two random I/Os.

```text
            [ root: 40 | 80 ]
           /        |        \
   [10|20|30]  [50|60|70]  [90|95]
     |  |  |     |  |  |     |  |
    leaves <-> leaves <-> leaves
   (sorted, linked for range scans)
```

**Updates happen in place.** To change a row, the engine finds its leaf page, modifies it in the buffer pool and later writes the whole page back. When a page fills up it splits into two, and a separator key goes up to the parent. Splits can cascade up to the root, which is the only way the tree gets taller.

**Two layout families matter in practice:**

- **Clustered (index-organized).** InnoDB stores rows inside the primary-key B+tree. A secondary index stores the primary key, not a physical address, so a secondary lookup walks two trees. Random primary keys such as UUIDv4 scatter inserts across the whole tree, causing page splits and poor cache locality. Time-ordered keys such as UUIDv7 or ULID avoid most of this.
- **Heap plus indexes.** PostgreSQL stores rows in an unordered heap. Every index points at a physical tuple ID (page, offset). When a row moves to a new location, every index has to be updated unless the update qualifies as HOT (heap-only tuple). HOT requires that no indexed column changed and that the same page has free space.

**Write amplification comes from page granularity.** Changing one 100-byte row still dirties an 8 KB page. Torn-page protection adds more. PostgreSQL logs a full page image the first time a page is modified after each checkpoint (`full_page_writes`). InnoDB writes pages through a doublewrite buffer. On write-heavy workloads, these full-page images can dominate WAL volume.

**B-trees are strong at:** predictable point reads, range scans and read-mostly workloads. Their performance is easy to reason about.

**B-trees are weak at:** random-write-heavy workloads on large datasets. They also fragment over time, and they waste space when pages are only partly full. Space utilization after random inserts settles around 67–70%.

### Storage engines: LSM trees

The log-structured merge tree (O'Neil et al., 1996) turns random writes into sequential ones. It is the engine behind RocksDB, LevelDB, Cassandra, ScyllaDB, HBase, and the storage layers of CockroachDB (Pebble), TiDB (TiKV on RocksDB) and YugabyteDB (DocDB).

**The write path:**

1. Append the write to a WAL for durability.
2. Insert it into an in-memory sorted structure called the memtable, usually a skiplist.
3. When the memtable fills, freeze it and flush it to disk as an immutable sorted file (an SSTable) in level 0.
4. Background compaction merges SSTables into larger, non-overlapping runs in deeper levels.

```text
 write -> WAL (append)
       -> memtable (RAM, sorted)
              | flush
              v
 L0: [sst][sst][sst]   overlapping ranges
              | compact
              v
 L1: [a-f][g-m][n-z]   ~10x L0, disjoint
              | compact
              v
 L2: [....... 10x L1 .......]
```

**Reads have to check several places.** A read looks at the memtable, then each L0 file, then at most one file per deeper level. Two things keep this cheap. Bloom filters let the engine skip files that cannot contain the key; about 10 bits per key gives roughly a 1% false-positive rate. Block caches keep hot index and data blocks in memory. Range scans are harder. They have to merge iterators across every level, and bloom filters do not help them unless you configure prefix bloom filters.

**Deletes are writes.** A delete writes a *tombstone*. The key's space is reclaimed only when compaction pushes the tombstone down to the bottom level and drops it. Until then, scans have to step over every tombstone. This is why "using Cassandra as a queue" is a notorious anti-pattern: reads slow down linearly with the number of deleted-but-not-compacted entries.

**Compaction strategy is the main tuning decision:**

| Strategy | Write amp | Space amp | Read amp |
|---|---|---|---|
| Leveled | High (10–30x) | Low (~1.1x) | Low |
| Size-tiered | Low | High (2x+) | Higher |
| Hybrid/universal | Medium | Medium | Medium |

Leveled compaction (RocksDB's default, LevelDB) keeps each level about 10x the size of the one above, with disjoint key ranges within a level. Size-tiered compaction (Cassandra's original default) merges similarly sized files together. It writes less but temporarily needs free disk equal to the data being compacted. Time-window compaction suits time-series data with TTLs, because whole files expire together.

**The RUM conjecture** (Athanassoulis et al., 2016) frames all of this. You can optimize for at most two of Read overhead, Update overhead and Memory/space overhead. B-trees and LSMs sit at different points on that triangle. Neither one is simply "better."

**How LSMs fail in production:**

- **Write stalls.** When compaction falls behind, L0 file counts climb. RocksDB then deliberately slows writes and finally stops them. Ingest throughput drops to zero, even though disks and CPU look underused.
- **Compaction debt.** Compaction steals I/O and CPU from foreground work. Sustained write rates above compaction throughput are not sustainable, however good your benchmark numbers look. A benchmark that runs only a few minutes never reaches steady-state compaction.
- **Tail latency.** p99 reads suffer during large compactions and when bloom filters or index blocks fall out of cache.

### Choosing between B-tree and LSM

The honest answer is about workload shape and hardware, not fashion.

- **Pick a B-tree** for read-heavy OLTP, heavy range scans, mixed workloads where predictable latency matters, and when your team's tooling and expertise are built around PostgreSQL or MySQL.
- **Pick an LSM** for write-heavy ingestion (events, time series, metrics, messaging), datasets much larger than RAM with mostly recent reads, SSDs where write endurance and compression matter, and for distributed SQL systems that are built on one anyway.

SSDs changed the calculation somewhat. Random reads are cheap on flash, which helps B-trees. But flash cells wear out with writes, and SSD firmware has its own internal write amplification, which helps LSMs. Compression also matters. LSM SSTables are immutable and compress well, often reducing size by 2–5x. Page-based compression in B-trees is awkward because pages change in place.

### Write-ahead logging and crash recovery

The WAL rule is simple: **before a modified page reaches disk, the log record that describes the change must already be on durable storage.** A commit is durable once its commit record is flushed to the log. The data pages can be written lazily, later.

ARIES (Mohan et al., 1992) is the canonical design, and InnoDB, SQL Server and DB2 are close relatives of it. Its key properties:

- **Steal.** Dirty pages from uncommitted transactions *may* be written to disk. This needs undo information.
- **No-force.** Committed transactions' pages do *not* have to be written at commit. This needs redo information.
- **LSNs.** Every log record has a log sequence number. Every page records the LSN of the last change applied to it (the pageLSN). Recovery compares the two to decide whether to reapply a change, so redo is idempotent.
- **Three-phase recovery.** *Analysis* rebuilds the dirty-page and active-transaction tables from the last checkpoint. *Redo* repeats history, including the effects of transactions that will later be rolled back. *Undo* rolls back the losers and writes compensation log records (CLRs), so a crash during recovery does not undo the same work twice.

PostgreSQL is a useful contrast. Its WAL is essentially **redo-only**. Old row versions stay in the heap because of MVCC, so aborted transactions need no physical undo. Their tuples simply never become visible, and VACUUM cleans them up later.

**Checkpoints bound recovery time.** A checkpoint flushes dirty pages and records a point from which replay can begin. Frequent checkpoints mean fast recovery, but more I/O and, in PostgreSQL, more full-page images. Rare checkpoints mean cheaper steady state but long crash recovery. PostgreSQL's `max_wal_size` and `checkpoint_timeout` control this trade-off directly.

**Group commit is the throughput lever.** An fsync takes from tens of microseconds on enterprise NVMe with power-loss protection to several milliseconds on cloud network disks. Batching the commit records of many concurrent transactions into one fsync is what makes high commit rates possible. Settings like PostgreSQL's `synchronous_commit = off` or InnoDB's `innodb_flush_log_at_trx_commit = 2` give up the last few hundred milliseconds of commits on a crash in exchange for latency. That can be a legitimate choice, but someone should make it on purpose.

**The WAL is also the replication stream.** Physical replication ships WAL bytes, so replicas are bit-identical. Logical replication decodes WAL into row changes, which feeds change data capture (CDC) through tools like Debezium. Physical replication is simpler and exact, but it requires the same major version and ties replicas to the primary's on-disk layout. Logical replication allows cross-version upgrades and selective replication, but it has gaps. In PostgreSQL, DDL and sequences are not replicated logically, and every table needs a replica identity.

**The durability stack has more layers than people think:**

```text
 app commit
   -> DB WAL buffer
   -> write() into OS page cache
   -> fsync()
   -> device write cache
   -> NAND / platter
```

Every layer can lie. Disks with volatile write caches that ignore flush commands, virtualized storage that acknowledges early, and filesystems with surprising error semantics have all caused real data loss. The 2018 "fsyncgate" episode showed that on Linux, a failed fsync could mark dirty pages clean and clear the error state. PostgreSQL's habit of retrying fsync could then report success for data that never reached disk. The fix was to PANIC on fsync failure and recover from the WAL. The lesson for a DE: durability claims end at the weakest layer, and you have to test them by pulling power, not by reading documentation.

### MVCC: multi-version concurrency control

MVCC keeps several versions of each row so that readers see a consistent snapshot without taking locks that would block writers. Writers still conflict with each other. The basic rule is that *readers don't block writers and writers don't block readers.*

**A snapshot** is a description of which transactions' effects are visible. In PostgreSQL, a snapshot records `xmin`, `xmax` and the list of in-progress transaction IDs. Each tuple carries the ID of the transaction that created it (`xmin`) and the one that deleted or replaced it (`xmax`). A tuple is visible if its creator committed before the snapshot and its deleter did not.

**There are two main storage strategies:**

| Approach | Used by | Old versions live | Cleanup |
|---|---|---|---|
| Append to heap | PostgreSQL | In the table | VACUUM |
| Undo log | InnoDB, Oracle | Undo segments | Purge |
| Version store | SQL Server | tempdb | Background |

**Append-in-heap (PostgreSQL).** An UPDATE writes a new tuple and marks the old one dead. Readers that need the old version find it directly in the heap. The costs are table and index bloat, and the VACUUM work needed to reclaim space. When a non-HOT update writes a new tuple, every index gets a new entry too.

**In-place plus undo (InnoDB, Oracle).** An UPDATE modifies the row in place and writes the before-image to an undo log. A reader that needs an older version walks the undo chain backwards. The heap stays compact, but long version chains make old snapshots slow to read. A purge thread drops undo records once no snapshot needs them.

**Garbage collection is where MVCC hurts in production.** One long-running transaction, an idle-in-transaction session, a stale replication slot, or a hot-standby query with `hot_standby_feedback` enabled pins the oldest visible snapshot. Nothing newer than that point can be cleaned up. In PostgreSQL, dead tuples pile up and tables bloat. In InnoDB, the "history list length" grows into the millions and every read slows down.

**Transaction ID wraparound is a PostgreSQL-specific hazard.** XIDs are 32-bit and compared modulo 2^32. Old tuples must be "frozen" by VACUUM before about 2 billion transactions pass, or they would appear to be in the future. If freezing falls too far behind, PostgreSQL refuses to assign new XIDs, which means it stops accepting writes, to protect data. Sentry (2015) and Mailchimp's Mandrill (2019) both had public multi-hour outages from this. Monitor `age(datfrozenxid)` and treat autovacuum as a production-critical service, not background noise.

**MVCC is not serializability.** A snapshot gives each transaction a consistent view, but two transactions with consistent views can still make decisions that conflict with each other. The next section is about exactly that gap.

### Isolation levels and anomalies

The ANSI SQL-92 standard defines four isolation levels by which "phenomena" they forbid: dirty read, non-repeatable read and phantom. Berenson et al.'s 1995 paper *A Critique of ANSI SQL Isolation Levels* showed these definitions are ambiguous and incomplete. In particular, they say nothing about snapshot isolation, which is what most "MVCC databases" actually provide. Adya's 1999 thesis gave precise, implementation-independent definitions based on dependency graphs.

**The anomalies you actually need to know:**

- **Dirty read.** You see another transaction's uncommitted write.
- **Dirty write.** You overwrite another transaction's uncommitted write. Every real level forbids this.
- **Non-repeatable read (read skew).** You read a row twice and get different values, or you read two related rows at different moments and see an inconsistent pair.
- **Lost update.** Two transactions read a value, both compute a new value, and both write it. One increment disappears.
- **Phantom.** A predicate query such as `WHERE status = 'open'` returns different rows when repeated, because of concurrent inserts.
- **Write skew.** Two transactions read an overlapping set of data, each checks an invariant, and each writes to a *different* row. Each one is valid alone, and together they break the invariant.

The classic write skew example: a hospital requires at least one doctor on call. Alice and Bob are both on call. Each, at the same moment, checks "is someone else on call?", sees yes, and takes themselves off. Under snapshot isolation both commits succeed, because they wrote different rows. Now nobody is on call.

**What the levels permit:**

| Level | Lost update | Write skew | Phantom |
|---|---|---|---|
| Read committed | Yes | Yes | Yes |
| Snapshot (SI) | No* | Yes | Mostly no |
| Serializable | No | No | No |

\*SI prevents lost updates through first-committer-wins on the same row. Implementations differ in the details.

**The names lie, and the defaults differ:**

- **PostgreSQL** defaults to Read Committed. Its `REPEATABLE READ` is snapshot isolation. Its `SERIALIZABLE` is Serializable Snapshot Isolation (SSI; Cahill et al., 2008), which tracks read-write dependencies and aborts transactions that could form a dangerous cycle.
- **MySQL/InnoDB** defaults to `REPEATABLE READ`. Plain SELECTs read a snapshot, but `UPDATE`s and locking reads act on the *latest* committed version, using next-key locks. So a transaction can read one value and then update based on another. Lost updates through read-modify-write are possible unless you use `SELECT ... FOR UPDATE`.
- **Oracle** calls its snapshot isolation `SERIALIZABLE`. It is not; it allows write skew.
- **CockroachDB** defaults to `SERIALIZABLE`. **Spanner** provides strict serializability (external consistency).

Kleppmann's *Hermitage* project tests these behaviors database by database, and it is worth reading before you trust any vendor's naming.

**Serializable has a cost, but it's not always what people expect.** SSI and optimistic serializable schemes rarely block. Instead they *abort* transactions under contention. That means application code must retry, and the retry loop must be correct: the whole transaction re-executes, side effects are idempotent, and retries are bounded with backoff. Two-phase locking (2PL) serializability blocks instead, and it deadlocks under contention.

**Practical tools below Serializable:**

- **`SELECT ... FOR UPDATE`.** Pessimistically lock the rows you will base a decision on.
- **Atomic updates.** `UPDATE accounts SET bal = bal - 10 WHERE id = ? AND bal >= 10` does the read and write in one statement.
- **Compare-and-set.** Add a version column and check it in the `WHERE` clause.
- **Materialize the conflict.** For write skew on rows that don't exist yet, such as double-booking an empty time slot, create rows that represent the slot so there is something to lock.
- **Constraints.** Unique, exclusion and foreign-key constraints are enforced correctly at any isolation level, because the database checks them against the latest state rather than your snapshot.

**Strict serializability** (also called linearizable serializability or external consistency) adds a real-time requirement on top of serializability. If T1 commits before T2 starts, T2 must see T1's effects. In a single-node database you get this for free. In a distributed database it is expensive, and it is what Spanner's TrueTime exists to provide.

### Distributed SQL

"Distributed SQL" or "NewSQL" systems try to keep the SQL and ACID model while scaling horizontally and surviving node and zone failures. Google Spanner, CockroachDB, YugabyteDB and TiDB share a common architecture.

```text
   SQL layer (stateless gateways)
     | parse, plan, distribute
     v
 txn layer (timestamps, 2PC, intents)
     |
     v
 ranges/tablets (~100s MB each)
  [R1 Raft grp] [R2 Raft grp] [R3]
   3-5 replicas across zones
     |
     v
 LSM storage per node
```

**Data is split into ranges** (CockroachDB), tablets (Spanner, YugabyteDB) or regions (TiKV). Each is typically hundreds of megabytes and holds a contiguous key range. Each range is replicated with Raft or Paxos. One replica acts as leader or leaseholder and serves consistent reads and coordinates writes. Ranges split and merge automatically and rebalance across nodes.

**Single-range transactions** are cheap: one consensus round, roughly one cross-zone round trip.

**Multi-range transactions** need atomic commit across consensus groups, which means two-phase commit:

1. The coordinator writes provisional values (write intents or locks) to each participant range, through consensus.
2. It commits by flipping a single transaction record to COMMITTED, also through consensus.
3. Intents are resolved asynchronously afterwards.

Classic 2PC blocks if the coordinator dies while participants are "prepared." Distributed SQL avoids that by making the coordinator's state itself replicated: the transaction record is in a Raft group, so another node can finish the protocol. CockroachDB's *parallel commits* goes further and removes one round of consensus latency from the commit path, by making the commit status derivable from whether all the intents were written.

**Timestamps are the hard part.** To order transactions across machines without one central clock you need some notion of time.

- **Spanner: TrueTime.** GPS receivers and atomic clocks give each machine a time interval `[earliest, latest]` with a bounded uncertainty of a few milliseconds. On commit, Spanner picks a timestamp and then *waits out the uncertainty* (commit wait) before acknowledging. That guarantees any later transaction gets a higher timestamp. The result is external consistency, paid for in hardware and a few milliseconds of latency per write.
- **CockroachDB and YugabyteDB: hybrid logical clocks (HLC) with NTP.** They assume a maximum clock offset, 500 ms by default in CockroachDB. A read that sees a value whose timestamp falls inside its uncertainty window must *restart* at a higher timestamp. A node whose clock drifts beyond the bound shuts itself down, because otherwise serializability could break. CockroachDB guarantees serializability and no stale reads for single keys, but not full strict serializability across unrelated keys.
- **TiDB: a timestamp oracle.** Its placement driver (PD) hands out monotonically increasing timestamps, following Google's Percolator design. This is simple and correct, but every transaction makes a round trip to a central service, and the oracle's leader must stay highly available.
- **Calvin (and FaunaDB): deterministic ordering.** Sequence transactions in a replicated log first, then execute them deterministically everywhere. No 2PC is needed, but transactions must declare their read and write sets up front, which rules out interactive transactions.

**Aurora-style designs are different.** Amazon Aurora is not sharded. It keeps one writer and pushes the *storage* layer out over the network. The writer ships only redo log records to a storage service with six copies across three availability zones. Writes need 4 of 6 acknowledgements and reads (used during recovery) need 3 of 6. The storage nodes materialize pages from the log themselves. This gives fast failover and read replicas that share storage, but write throughput is still limited by a single writer. Google AlloyDB and Neon follow a similar "the log is the database" separation.

**What distributed SQL costs you:**

- **Latency.** Every write is at least one consensus round across zones (1–2 ms within a region, 50–150 ms across regions). Multi-range transactions add more.
- **Contention behavior.** Hot rows under serializable isolation produce restarts and retries, not just queueing.
- **Operational complexity.** Range rebalancing, leaseholder placement, clock synchronization and new failure modes the team has not seen before.
- **Query planning across the network.** Joins that were cheap locally become distributed. Data locality (for example, interleaving or co-locating a tenant's rows) matters a great deal.

### Sharding

Sharding splits a dataset across independent databases, each owning a subset of keys. It is the most consequential, least reversible data decision most organizations make.

**Partitioning schemes:**

| Scheme | Strength | Weakness |
|---|---|---|
| Hash | Even spread | No range scans |
| Range | Range scans | Hotspots |
| Directory | Flexible moves | Lookup service |
| Geo/tenant | Locality, isolation | Skew |

- **Hash partitioning** spreads keys evenly but destroys ordering. Range queries become scatter-gather across every shard. *Consistent hashing* (Karger et al., 1997) with virtual nodes keeps data movement proportional to 1/N when nodes are added. Dynamo and Cassandra use it. Fixed partition counts are a simpler alternative: pre-split into many more partitions than nodes, such as 4,096 logical shards, and move whole partitions.
- **Range partitioning** keeps related keys together and supports efficient scans. But monotonically increasing keys (timestamps, auto-increment IDs) send *every* insert to the last range. The usual fixes are prefixing keys with a hash bucket or using a key whose high bits are not time-ordered.
- **Directory-based** sharding keeps an explicit map from key to shard. It makes moving individual tenants easy, at the cost of a highly available lookup service that everything depends on.

**Choosing the shard key is the real decision.** A good shard key:

- Appears in the vast majority of queries, so they route to a single shard.
- Groups data that is transactionally updated together, so transactions stay on one shard.
- Has high cardinality and no dominant values.
- Doesn't change over a row's lifetime.

For B2B SaaS, `tenant_id` is usually right. For consumer apps it is often `user_id`. Problems start when the access patterns diverge. A messaging app sharded by sender cannot cheaply answer "show my inbox."

**Secondary indexes on sharded data:**

- **Local (document-partitioned) indexes** live on each shard and cover only that shard's data. Writes are cheap, but any query by the indexed column must hit every shard.
- **Global (term-partitioned) indexes** are partitioned by the indexed value. Queries go to one place, but every write touches a second shard. Keeping the index synchronously consistent needs a distributed transaction, so many systems update global indexes asynchronously. DynamoDB's GSIs are eventually consistent, for example.

**Hot keys break every scheme.** A celebrity account, a viral product or a single giant tenant will overwhelm one shard no matter how good your hash is. Mitigations include splitting a hot key into sub-keys (`key#0..key#N`) with read-side aggregation, caching in front of it, moving whole-tenant outliers onto dedicated shards, and admission control. Design for skew from the start: real distributions are Zipfian, not uniform.

**Resharding is where sharding hurts most.** Moving data live requires copying a snapshot, streaming changes captured from the log, catching up, a brief write freeze or dual-write window, and then a routing cutover. Vitess (VReplication and MoveTables) and Citus (shard rebalancer) automate this. Hand-rolled sharding layers usually discover the problem the first time they need it, at the worst possible moment.

**Things you lose when you shard:** cross-shard joins, cross-shard transactions (unless you pay for 2PC), globally unique auto-increment IDs, foreign keys across shards, and simple global aggregations. Before sharding, check whether vertical scaling, read replicas, caching, partitioning a single table, or splitting by service would buy you years. A single large PostgreSQL or MySQL instance handles far more than most teams assume.

### Replication topologies

Replication serves three different purposes: durability (survive losing a machine), availability (keep serving through failures) and read scaling. Each topology trades these off differently.

**Single-leader (primary/replica).** All writes go to one leader, which streams its log to followers.

- **Synchronous:** the leader waits for at least one replica before acknowledging a commit. No acknowledged write is lost on failover, but write latency includes a replica round trip, and a slow replica stalls writes. PostgreSQL's quorum-based `synchronous_standby_names = 'ANY 1 (a, b)'` limits that stall.
- **Semi-synchronous (MySQL):** wait for a replica to *receive* the event, not apply it. Watch for the silent fallback to async when the timeout fires.
- **Asynchronous:** lowest latency, but failover can lose the last seconds of acknowledged writes. Those lost writes can reappear later as conflicts if the old leader comes back.

**Replication lag creates anomalies** that confuse users even when nothing is "broken":

- **Read-your-writes violation.** A user saves a change, reloads, and reads from a lagging replica that doesn't have it yet.
- **Monotonic read violation.** Successive reads hit different replicas and data appears to go backwards in time.
- **Consistent prefix violation.** A reader sees an answer before the question that caused it.

The fixes are routing a user's reads to the leader for a short time after they write, sticky replica selection, or waiting for a replica to reach the LSN or GTID of the user's last write before serving the read.

**Failover is the dangerous part of single-leader replication:**

- **Detection.** Timeouts that are too short cause false failovers. Timeouts that are too long cause long outages.
- **Choosing a new leader.** Pick the most up-to-date replica, or accept data loss.
- **Fencing the old leader.** If the old leader is still alive and accepting writes, you have *split brain*. Use fencing tokens, STONITH, or a lease that the old leader honors by stopping writes when it expires.
- **Rewiring clients.** DNS TTLs, connection pools and proxies all have to follow the new leader.

Tools like Patroni (using etcd or Consul as the consensus store) and Orchestrator automate this. Their correctness depends on getting the fencing right.

**Multi-leader.** Several nodes accept writes, usually one per region, and replicate to each other asynchronously.

- Each region gets local write latency and keeps working during a partition.
- In exchange, **conflicts are inevitable**: the same row changed in two places.
- Resolution strategies: last-writer-wins by timestamp (simple but silently drops data, and depends on clocks), application-level merge, or CRDTs that merge by construction.
- Auto-increment keys, unique constraints and triggers all behave surprisingly in this setup.

Use multi-leader only when the data model is naturally conflict-free or mergeable, or when each record has a clear "home" region.

**Leaderless (Dynamo-style).** Clients or coordinators write to N replicas and read from several of them. Cassandra, Riak and the original Dynamo work this way.

- **Quorums:** with N replicas, W write acknowledgements and R read responses, `R + W > N` ensures the read set overlaps the write set. A common choice is N=3, W=2, R=2.
- Overlap is not linearizability. Concurrent writes, failed partial writes and sloppy quorums can still return stale or inconsistent results.
- **Repair mechanisms:** read repair fixes stale replicas it notices during reads. Hinted handoff stores writes intended for a down node and delivers them later. Anti-entropy compares Merkle trees between replicas to find and fix differences.
- **Sloppy quorums** accept writes on whichever nodes are reachable during partitions. That improves availability but breaks the overlap guarantee.
- Conflicts are resolved by last-write-wins timestamps (Cassandra) or with version vectors and siblings (Riak).

**Consensus-replicated (Raft/Paxos).** A leader replicates log entries, and an entry commits once a majority acknowledges it. A cluster of 2f+1 nodes tolerates f failures with no acknowledged-write loss and automatic, safe leader election. Terms or epochs fence old leaders by design. etcd, ZooKeeper, Spanner, CockroachDB and TiKV all use this. The cost is a majority round trip on every write, and losing a majority means losing availability.

**Chain replication** (van Renesse and Schneider, 2004) sends writes to the head and reads to the tail. That gives strong consistency with high throughput. CRAQ extends it so any node can serve reads. It is common in storage systems such as object stores, and it needs an external configuration manager to reconfigure the chain after failures.

```text
 single-leader      leaderless (N=3)
   [L] --> [F]        client
    |                 / | \
    +----> [F]      [A][B][C]
                    W=2, R=2

 consensus (5)       chain
 [L]->[F][F][F][F]   w-> H -> M -> T ->r
 commit at 3 of 5
```

### Query optimization

A declarative query can be executed in exponentially many ways. The optimizer's job is to choose a good plan quickly enough to be worthwhile. It usually finds a reasonable plan. Sometimes it picks a catastrophic one, and that is what pages you at 3 a.m.

**The classic architecture** comes from Selinger et al.'s 1979 System R paper. It enumerates join orders with dynamic programming, estimates the cost of each candidate plan from statistics, tracks "interesting orders" (sort orders that help later operators), and picks the cheapest plan. Graefe's Volcano and Cascades frameworks generalized this into rule-based transformations with memoization. SQL Server, CockroachDB's optimizer and Apache Calcite descend from Cascades.

**The three inputs to cost:**

1. **Cardinality estimates.** How many rows each operator produces.
2. **Cost model.** CPU, I/O and network weights per operator.
3. **Plan space.** Which join orders, join algorithms and access paths are considered.

**Cardinality estimation is the dominant source of bad plans.** Leis et al.'s *How Good Are Query Optimizers, Really?* (VLDB 2015) found that estimation errors grow exponentially with the number of joins. They also found that fixing cardinality mattered far more than improving the cost model. The usual culprits are:

- **Independence assumption.** `city = 'Paris' AND country = 'France'` is estimated as the product of two selectivities, which badly underestimates correlated columns. Extended statistics (`CREATE STATISTICS` in PostgreSQL) help.
- **Stale statistics.** A table grew 100x since the last ANALYZE, or new data is outside the histogram's range. Monotonic timestamp columns are notorious for this: "rows since yesterday" estimates to 1.
- **Opaque predicates.** Functions, `LIKE '%x%'`, JSON paths and parameter markers all fall back to default selectivity guesses.

**Join algorithms and when each wins:**

- **Nested loop join.** Best when the outer side is small and the inner side has an index. Catastrophic when the outer side was estimated at 10 rows and is actually 10 million.
- **Hash join.** Best for large unsorted inputs joined on equality. It needs memory for the build side, and spills to disk when that runs out.
- **Merge join.** Best when both inputs are already sorted on the join key, for example from an index.

Most "the query suddenly took 40 minutes" incidents are a nested loop chosen because of an underestimate.

**Plan instability is a production problem**, not just a performance one:

- **Parameter sniffing** (SQL Server) and **generic vs custom plans** (PostgreSQL prepared statements, `plan_cache_mode`): a plan optimized for one parameter value gets reused for values with very different selectivity.
- **Statistics refresh flips a plan.** An auto-analyze runs at noon, and a query that was fine for a year changes plan.
- **Upgrades change the optimizer.** A major version upgrade can regress a handful of critical queries.

The tools for plan stability are SQL Server Query Store with plan forcing, Oracle SQL Plan Baselines, MySQL optimizer hints, and PostgreSQL's `pg_hint_plan` extension and `pg_stat_statements` for tracking query performance over time. For critical paths, capture plans in CI against production-like statistics and alert on plan changes.

**Index design that actually matters:**

- **Composite index order:** equality columns first, then the range or sort column. An index on `(tenant_id, created_at)` serves `WHERE tenant_id = ? ORDER BY created_at DESC LIMIT 50` with no sort at all.
- **Covering indexes** (`INCLUDE` columns) enable index-only scans. In PostgreSQL that also depends on the visibility map being current, which is another reason to keep VACUUM healthy.
- **Partial indexes** (`WHERE status = 'pending'`) keep hot subsets small.
- **Every index taxes writes.** It adds write amplification and buffer-pool pressure, and in PostgreSQL it also blocks HOT updates on that column. Audit for unused indexes.

**Query shapes that don't scale:**

- **OFFSET pagination.** It reads and discards every skipped row. Use keyset pagination (`WHERE (created_at, id) < (?, ?)`) instead.
- **N+1 queries from ORMs.**

In distributed SQL, the planner must also decide *where* operators run. Pushing filters and partial aggregations down to the data nodes, and choosing between broadcast and shuffle joins, can easily dominate the total cost.

## Design Principles

- **Name the guarantee, then find the mechanism.** For every invariant the business cares about (no double spend, no oversell, unique usernames), write down which mechanism enforces it: a constraint, a lock, serializable isolation or a single-writer design. "The database handles it" is not an answer.
- **Push invariants into the database.** Unique constraints, foreign keys, check and exclusion constraints, and conditional atomic updates are enforced correctly regardless of isolation level or application bugs. Application-level checks done with read-then-write are race conditions waiting for traffic.
- **Default to the strongest isolation you can afford, and measure.** Starting from serializable and relaxing per transaction with a written justification is safer than starting from Read Committed and discovering write skew in a financial audit.
- **Retries are part of the transaction contract.** Under serializable or optimistic concurrency, aborts are normal operation. Every transactional code path needs a bounded, idempotent retry wrapper, written once and shared across teams.
- **Choose the storage engine for the steady-state workload, not the benchmark.** Run long enough for compaction, vacuum and checkpoints to reach equilibrium, with realistic key distributions and dataset sizes several times larger than RAM.
- **Durability is end-to-end.** Count acknowledged-write loss scenarios across every layer: fsync settings, replication mode, disk caches, backup cadence and failover behavior. Write the answer down as an explicit RPO, and test it.
- **Delay sharding, then shard deliberately.** Scale up, add replicas, partition tables and split services first. When you do shard, choose the key from the dominant access pattern and transaction boundaries, and build resharding tooling before you need it.
- **Design for skew.** Assume Zipfian access patterns, giant tenants and celebrity keys. Every partitioning scheme needs a story for the 1% of keys that get 50% of the traffic.
- **Failover must fence.** Promotion without guaranteed demotion of the old leader is split brain waiting to happen. Prefer consensus-based leadership, or leases with fencing tokens, over heuristics.
- **Make replication lag a first-class signal.** Expose it, alert on it, and give applications read-your-writes primitives (LSN or GTID waits, leader pinning) instead of hoping lag stays small.
- **Garbage collection is a production service.** Vacuum, purge, compaction and tombstone cleanup need monitoring, capacity planning and owners. Long-running transactions are a resource leak and should be time-limited by policy.
- **Plan stability beats plan optimality.** For critical queries, a predictable plan that is good enough is worth more than one that is sometimes optimal and occasionally catastrophic. Pin, hint or track plans in the places that matter.
- **Backups don't exist until restores are tested.** Automate restore drills, measure restore time against your RTO, and verify the restored data, not just that the restore job exited zero.
- **Prefer boring, well-understood databases.** Every new engine adds failure modes your on-call engineers have never seen. The bar for introducing one should be a workload that the existing fleet demonstrably cannot serve.

## Trade-offs and Decision Frameworks

### Framework 1: Single node, sharded, or distributed SQL?

| Need | Default choice |
|---|---|
| < few TB, < ~50k writes/s | Single primary + replicas |
| Clear tenant key, huge scale | Sharded (Vitess/Citus) |
| Multi-region writes + ACID | Distributed SQL |
| Massive ingest, simple keys | Wide-column / KV LSM |

These thresholds are rough. Modern hardware moves them up every year, and they depend heavily on row size and query shape. The questions that actually decide it:

- **Do transactions naturally stay inside one key?** Then sharding works well. If they span arbitrary keys, you need distributed SQL or a redesign.
- **Can you tolerate seconds of data loss on regional failover?** If not, you need synchronous cross-region replication or consensus, and every write pays for it.
- **Is the team ready to operate it?** Distributed SQL removes the work of sharding by hand and replaces it with clock, range and placement problems.

### Framework 2: Choosing isolation

Ask per transaction, not per database:

- **Does it read data and then write based on what it read?** If so, Read Committed is likely wrong.
- **Does the write depend on rows it did not write (write skew)?** Then you need serializable isolation, explicit locks or a materialized conflict.
- **Is it a pure read report?** A snapshot is fine, and a read replica might be too.
- **Is it a high-contention counter?** Use an atomic update or a sharded counter, not a serializable read-modify-write that will abort constantly.

### Framework 3: Replication mode against RPO and RTO

| Mode | RPO | Write latency | Availability risk |
|---|---|---|---|
| Async | Seconds | Lowest | Data loss on failover |
| Semi-sync | ~0* | +1 RTT | Silent async fallback |
| Sync quorum | 0 | +1 RTT | Stalls if quorum lost |
| Consensus | 0 | +1 RTT | Majority needed |

\*Only zero if the fallback to async never fires.

Cross-region synchronous replication adds tens of milliseconds to every commit. Many organizations decide this is the right price for ledgers and identity data, and the wrong price for activity feeds. The DE move is to make that decision per data class and write it down, instead of using one setting for the whole company.

### Framework 4: Multi-region patterns

- **Active-passive.** One region writes and another stands by. This is simple, with failover RPO set by replication mode. Most companies should start here.
- **Home-region per record.** Each user or tenant has a home region that handles their writes. You get local latency for most writes without conflicts. Hard cases are users who move and cross-tenant operations.
- **Consensus across regions.** Strong consistency and automatic failover, but every write pays inter-region latency. A quorum of three regions is typical.
- **Multi-leader with merges.** Highest availability, but you need a conflict model the business has explicitly accepted.

## Failure Modes and War Stories

### GitHub, October 2018: failover without coordination

During routine maintenance, a 43-second network partition separated GitHub's US East Coast network hub from its primary East Coast data center. Orchestrator, their MySQL topology manager, promoted primaries in a West Coast data center. When connectivity returned, the East Coast databases held writes that were never replicated to the West, and the West held writes that the East didn't have. Applications in the East now paid cross-country latency to talk to West Coast primaries.

GitHub chose data integrity over speed. They spent over 24 hours in degraded service, restoring from backups and reconciling writes.

**Lessons:** Automated failover must understand topology and be constrained by it (for example, never promote across regions without explicit policy). Partitions shorter than a minute can cause day-long incidents. Have a documented reconciliation plan for divergent histories.

### GitLab, January 2017: the backups that didn't exist

While fighting replication lag caused by a spam-driven load spike, an engineer deleted the data directory on what he believed was the secondary in order to re-seed replication. It was the primary. When they went to restore, several backup mechanisms turned out to be broken or misconfigured, including dumps that had been failing silently. They restored from a staging snapshot taken about six hours earlier and lost roughly six hours of production data for projects, issues and comments.

**Lessons:** Restore drills are the only proof backups work. Make the primary and replicas visually unmistakable in shells and tooling. Destructive operations under stress need a second person.

### PostgreSQL fsyncgate, 2018

Engineers found that on Linux, after an fsync failure caused by an I/O error, the kernel could drop dirty pages and clear the error. A later fsync then returned success. PostgreSQL retried fsync during checkpoints, so it could believe data was durable when it was not. The fix (PostgreSQL 11.2, 2019) was to PANIC on fsync failure and recover from the WAL, which is the one copy known to be good.

**Lessons:** Durability depends on OS and storage semantics you probably have not read. Error paths are the least-tested code paths in every layer.

### Transaction ID wraparound: Sentry (2015), Mandrill (2019)

Both ran high-write PostgreSQL databases where autovacuum couldn't freeze old tuples fast enough. As the XID age approached the 2-billion limit, PostgreSQL went into protective mode and refused writes. Recovery required long single-user-mode VACUUMs on large tables, resulting in hours of downtime.

**Lessons:** Monitor `age(datfrozenxid)` with alerts well before the danger zone. Tune autovacuum aggressively on high-churn tables, and partition large tables so vacuum work is bounded.

### Uber, 2016: PostgreSQL to MySQL

Uber's published rationale for moving their core datastore illustrates storage-engine trade-offs concretely. PostgreSQL indexes point at physical tuple locations, so updates to rows with many indexes wrote new entries to every index. That amplified writes and WAL volume. Physical replication shipped all of that amplified WAL across data centers, and replicas could not run a different major version, which made upgrades painful. InnoDB's clustered index, with secondary indexes pointing at the primary key, and its logical (row-based) replication fit their update-heavy workload better.

**Lessons:** Index layout and replication format are first-order architectural concerns. Also, the "right" engine depends on workload. Many experts disputed details of the analysis, and PostgreSQL has since improved, but the shape of the trade-off is real.

### The lock queue outage (a recurring pattern)

Someone runs `ALTER TABLE ... ADD COLUMN` on a busy PostgreSQL table. The statement needs an ACCESS EXCLUSIVE lock, even though the change itself takes milliseconds. A long-running analytics query is holding a conflicting lock, so the ALTER waits. Every new query on the table now queues *behind the waiting ALTER*. Within seconds the connection pool is exhausted and the site is down. Nothing is "slow"; everything is waiting.

**Lessons:** Set `lock_timeout` on all migrations, retry with backoff, and kill long transactions before DDL. Use online schema-change tools (gh-ost, pt-online-schema-change, pg-osc) where they apply.

### More failure modes to recognize

- **The plan flip.** A statistics refresh or a new data distribution switches a hot query from an index nested loop to a full scan, or the reverse. CPU climbs to 100% and nothing was deployed. Track per-query plan hashes and latency through `pg_stat_statements` or Query Store.
- **The idle-in-transaction leak.** An application opens a transaction, makes a slow HTTP call, and holds the snapshot for minutes. Vacuum or purge stalls, tables bloat, and query latency drifts up over days. Set `idle_in_transaction_session_timeout` and statement timeouts.
- **Replication slot runaway.** A logical replication slot for an abandoned CDC consumer retains WAL until the primary's disk fills and it goes down. Monitor retained WAL per slot, and set `max_slot_wal_keep_size`.
- **Retry storms under serializable.** Contention causes aborts. Clients retry immediately with no backoff, contention gets worse, and throughput collapses. Use jittered exponential backoff and limit concurrency on hot keys.
- **Split brain after failover.** The old primary comes back, still thinks it's the leader, and accepts writes from clients with stale DNS. Two histories diverge. Use fencing tokens, STONITH, and connection routing that checks leadership epochs.
- **Clock skew in HLC systems.** A VM's clock drifts past the configured maximum offset. CockroachDB nodes self-terminate to protect consistency, which looks like random node crashes. Monitor NTP or chrony health as a database dependency.

## What a DE Probes

- **"Which invariants does this system have, and what mechanism enforces each one?"** A good answer lists concrete invariants, such as balance never negative or one active subscription per user, and maps each to a constraint, lock, isolation level or single-writer design. A weak answer says "we use transactions."
- **"What isolation level does this transaction run at, and what anomaly would break you?"** A good answer names the actual level (knowing the database's default), the specific read-then-write patterns involved, and why write skew or lost updates either can't happen or are handled.
- **"Show me the retry logic for aborted transactions."** A good answer shows a shared, bounded, jittered retry wrapper around idempotent transaction bodies, with no external side effects inside the retried block.
- **"What is the RPO and RTO, and when did you last measure them?"** A good answer gives numbers tied to the replication mode and backup cadence, along with the date and results of the last restore and failover drills.
- **"Walk me through a failover. What stops the old primary from accepting writes?"** A good answer describes detection, promotion, fencing (leases, epochs, STONITH) and client rerouting, and admits which steps are manual.
- **"What happens to reads right after a user writes?"** A good answer names read-your-writes handling, such as leader pinning, LSN or GTID waits or session stickiness, or explains why staleness is acceptable for that flow.
- **"Why this shard key? What query doesn't fit it?"** A good answer ties the key to the dominant access pattern and transaction boundary. It names the queries that become scatter-gather and how they are served, for example by a secondary store or a global index.
- **"What's your largest tenant or hottest key, as a share of total load?"** A good answer gives actual skew data and a plan for outliers: dedicated shards, key splitting, caching or request coalescing.
- **"How do you reshard, and have you done it?"** A good answer describes tooling such as Vitess, Citus or an in-house CDC-based move, with a rehearsed runbook. Hoping never to need it is not an answer.
- **"What's the steady-state write amplification, and is there headroom for compaction or vacuum?"** A good answer shows measured numbers from long-running load tests and I/O headroom reserved for background work.
- **"What's the longest transaction you allow, and how is it enforced?"** A good answer cites statement, idle-in-transaction and transaction timeouts, plus monitoring of the oldest snapshot age or history list length.
- **"How do you detect and respond to a query plan regression?"** A good answer covers per-query latency and plan tracking, alerts on plan changes for critical queries, and a way to pin a plan quickly.
- **"How do schema migrations run without locking the table?"** A good answer mentions lock timeouts, online schema-change tools, expand-and-contract migrations, and backward-compatible deploys.
- **"What's your dependency on clocks?"** A good answer covers how LWW conflict resolution, HLC uncertainty or lease expiry depend on time, how clock health is monitored, and what happens when a clock jumps.

## Review Checklist

- [ ] Every business invariant is mapped to an enforcing mechanism (constraint, lock, isolation level or single writer).
- [ ] The isolation level for each critical transaction is explicit, with anomalies analyzed against it.
- [ ] Read-modify-write paths use atomic updates, `FOR UPDATE`, compare-and-set or serializable isolation.
- [ ] A shared, bounded, jittered retry wrapper exists, and transaction bodies are idempotent.
- [ ] Commit durability settings (fsync, synchronous commit, flush-at-commit) are deliberate and documented.
- [ ] Replication mode is chosen per data class, with written RPO and RTO targets.
- [ ] Failover is automated or runbooked, and includes fencing of the old leader.
- [ ] Backups are automated and a restore drill has been run, with measured restore time and data verification.
- [ ] Replication lag is monitored and alerted, and read-your-writes is handled where users expect it.
- [ ] The shard key is justified by access patterns and transaction boundaries, with scatter-gather queries listed.
- [ ] A hot key and large tenant strategy exists, based on measured skew.
- [ ] Resharding or rebalancing tooling exists and has been exercised.
- [ ] The storage engine choice is validated with steady-state load tests longer than compaction and vacuum cycles.
- [ ] I/O and CPU headroom is reserved for compaction, vacuum, purge and checkpoints.
- [ ] Statement, lock, idle-in-transaction and transaction timeouts are configured.
- [ ] Oldest snapshot age, history list length or XID age, dead tuples and bloat are monitored.
- [ ] Replication slots and CDC consumers have retention limits and lag alerts.
- [ ] Critical queries have tracked plans and latency, with a plan-pinning escape hatch.
- [ ] Composite indexes are ordered equality-first, and unused indexes have been audited and dropped.
- [ ] No OFFSET pagination or N+1 patterns remain on hot paths.
- [ ] Schema migrations use lock timeouts and online, expand-and-contract techniques.
- [ ] Clock synchronization is monitored wherever correctness depends on time.

## Further Reading

**Books**

- Martin Kleppmann, *Designing Data-Intensive Applications* (O'Reilly, 2017; 2nd ed. with Chris Riccomini). The best single overview of storage, replication, partitioning and transactions.
- Alex Petrov, *Database Internals* (O'Reilly, 2019). B-tree and LSM internals in depth, plus distributed-systems fundamentals.
- Jim Gray and Andreas Reuter, *Transaction Processing: Concepts and Techniques* (1992). The foundational reference for locking, logging and recovery.

**Storage engines and recovery**

- Bayer and McCreight, "Organization and Maintenance of Large Ordered Indexes" (1972).
- O'Neil, Cheng, Gawlick and O'Neil, "The Log-Structured Merge-Tree (LSM-Tree)" (1996).
- Athanassoulis et al., "Designing Access Methods: The RUM Conjecture" (EDBT 2016).
- Mohan et al., "ARIES: A Transaction Recovery Method Supporting Fine-Granularity Locking and Partial Rollbacks Using Write-Ahead Logging" (TODS 1992).

**Concurrency and isolation**

- Berenson, Bernstein, Gray, Melton, O'Neil and O'Neil, "A Critique of ANSI SQL Isolation Levels" (SIGMOD 1995).
- Atul Adya, "Weak Consistency: A Generalized Theory and Optimistic Implementations for Distributed Transactions" (MIT PhD thesis, 1999).
- Cahill, Röhm and Fekete, "Serializable Isolation for Snapshot Databases" (SIGMOD 2008).
- Ports and Grittner, "Serializable Snapshot Isolation in PostgreSQL" (VLDB 2012).
- Martin Kleppmann, Hermitage: testing transaction isolation levels (github.com/ept/hermitage).
- Kyle Kingsbury, Jepsen analyses (jepsen.io).

**Distributed databases and replication**

- Corbett et al., "Spanner: Google's Globally-Distributed Database" (OSDI 2012).
- Taft et al., "CockroachDB: The Resilient Geo-Distributed SQL Database" (SIGMOD 2020).
- Huang et al., "TiDB: A Raft-based HTAP Database" (VLDB 2020).
- Peng and Dabek, "Large-scale Incremental Processing Using Distributed Transactions and Notifications" (Percolator, OSDI 2010).
- Verbitski et al., "Amazon Aurora: Design Considerations for High Throughput Cloud-Native Relational Databases" (SIGMOD 2017).
- DeCandia et al., "Dynamo: Amazon's Highly Available Key-value Store" (SOSP 2007).
- Ongaro and Ousterhout, "In Search of an Understandable Consensus Algorithm" (Raft, USENIX ATC 2014).
- van Renesse and Schneider, "Chain Replication for Supporting High Throughput and Availability" (OSDI 2004).

**Query optimization**

- Selinger et al., "Access Path Selection in a Relational Database Management System" (SIGMOD 1979).
- Goetz Graefe, "The Cascades Framework for Query Optimization" (1995) and "Volcano, an Extensible and Parallel Query Evaluation System" (1994).
- Leis et al., "How Good Are Query Optimizers, Really?" (VLDB 2015).
- Markus Winand, *SQL Performance Explained* and use-the-index-luke.com.

**Incident write-ups worth reading in full**

- GitHub, "October 21 post-incident analysis" (2018).
- GitLab, "Postmortem of database outage of January 31" (2017).
- Uber Engineering, "Why Uber Engineering Switched from Postgres to MySQL" (2016).
- Sentry, "Transaction ID Wraparound in Postgres" (2015).
