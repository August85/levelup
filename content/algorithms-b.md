## Storage Engines and Recovery

### B+-tree
> Keeps a large sorted key space on block storage so that point lookups, range scans and updates each touch only a handful of pages.

**How it works.** A B+-tree is a balanced, high-fanout search tree. Interior nodes hold only separator keys and child pointers. All records (or record pointers) sit in leaves, and the leaves are chained so range scans can walk sideways.

```text
            [ 40 | 80 ]              interior
           /     |     \
  [10|20|30] [40|55|70] [80|90]      leaves
       <------->  <------->          sibling links
```

1. **Search.** Start at the root, binary-search the separators in each node, follow the child pointer, and stop at a leaf.
2. **Insert.** Find the leaf. If there is room, insert in sorted order. If the leaf is full, split it into two half-full leaves and push the middle separator up to the parent. A split can cascade to the root, and a root split is the only way the tree gets taller.
3. **Delete.** Remove the entry. If the node falls below minimum fill, borrow from a sibling or merge with it. Many engines skip merges and leave sparse pages for vacuum or rebuild to fix.

Height is about log_F(N), where F is the fanout. With 8 KB pages and short keys F is usually 100–500, so a billion rows fit in 3–4 levels. The upper levels stay in cache, so a lookup costs about one I/O.

Concurrency normally uses latch crabbing: latch the child, then release the parent once the child is known to be "safe" (not about to split). B-link trees (Lehman–Yao) add right-links and high keys so readers can recover from a concurrent split without holding latches on the path.

**Complexity.** Search, insert and delete take O(log_F N) page accesses, and a range scan of k results takes O(log_F N + k/B). Space is O(N) at roughly 50–100% fill, and about 69% under random inserts. Writing one row rewrites a whole page, so write amplification is page size divided by row size, plus WAL.

**Where you meet it.** Nearly every OLTP engine: InnoDB clustered and secondary indexes, PostgreSQL nbtree, SQL Server, Oracle, SQLite, LMDB, WiredTiger's row store. File systems such as XFS, Btrfs (a COW B-tree), NTFS and APFS use it too.

**Pitfalls.**
- Random keys such as UUIDv4 spread inserts across every leaf. The working set grows to the whole index, splits happen everywhere, and fill drops. Use time-ordered IDs (UUIDv7, ULID) or a separate surrogate key.
- Monotonic keys do the opposite: every insert hits the rightmost leaf, which becomes a latch hotspot. Engines add special handling for this, such as Postgres's fastpath for rightmost inserts.
- Wide keys reduce fanout and make the tree taller. Prefix compression and suffix truncation help.
- Torn page writes need protection, such as Postgres full-page writes or the InnoDB doublewrite buffer.
- Index bloat from MVCC dead tuples is easy to miss until scans slow down.

**DE judgment.** Pick a B+-tree for read-heavy or mixed workloads that need predictable point and range latency and in-place updates under transactional locking. Choose an LSM instead when ingest dominates, writes are mostly blind, or the device penalises random writes.

In review, probe:
- The key design and insert pattern: random or monotonic?
- How many secondary indexes each write must maintain.
- The expected fill factor and the bloat or rebuild strategy.
- Whether the hot set of interior plus leaf pages fits in the buffer pool.

### LSM-tree compaction (leveled vs tiered)
> Turns random writes into sequential ones by buffering in memory and merging sorted immutable files in the background, then trades write, read and space amplification through the compaction policy.

**How it works.**
1. Each write is appended to the WAL and inserted into an in-memory sorted memtable.
2. When the memtable is full it is frozen and flushed as an immutable sorted run (SSTable) into L0.
3. A read checks the memtable, then L0, then deeper levels. Per-file Bloom filters and fence pointers skip most files.
4. Compaction merge-sorts runs, drops overwritten versions, and eventually drops tombstones.

The compaction policy decides the amplification trade-off. Let T be the size ratio between levels and L ≈ log_T(N / memtable) the number of levels.

```text
LEVELED (1 run/level)    TIERED (≤T runs/level)
L1 [====]                L1 [=][=][=]
L2 [==========]          L2 [===][===][===]
L3 [====================] L3 [=========][=====]
```

- **Leveled.** Each level holds one sorted run, split into non-overlapping SSTables, and is T times larger than the level above. When a level overflows, one file is merged into the overlapping files in the next level. Write amplification is about T·L, because each byte is rewritten about T times per level. Read amplification is about L runs, and space amplification is about 1 + 1/T (roughly 1.1).
- **Tiered (size-tiered or universal).** Each level collects up to T runs. When it has T, they are merged into one run in the next level. Write amplification is about L, read amplification is about T·L runs, and space amplification can reach about 2× during a large merge, more if duplicates persist.

Hybrids are common: tiered at L0, leveled below (RocksDB's default shape), or "lazy leveling" with tiering everywhere except the last level (Dostoevsky).

**Complexity.** Writes cost O(1) amortised in memory, plus write amplification in background I/O. A point read costs O(L) runs, but Bloom filters bring it close to one I/O when the key exists. A range scan must merge all L (leveled) or T·L (tiered) runs.

**Where you meet it.** RocksDB and LevelDB (leveled plus universal), Cassandra (STCS, LCS, TWCS for time series, UCS in 5.0), ScyllaDB (ICS), HBase, Pebble (CockroachDB), TiKV, InfluxDB's TSM and Kafka Streams state stores.

**Pitfalls.**
- **Compaction debt.** If ingest exceeds compaction throughput, L0 file count grows, reads slow down, and the engine eventually stalls writes. This looks like a sudden p99 cliff, not gradual degradation.
- **Tombstones.** Deletes are writes. Range deletes and queue-like workloads leave tombstones that scans must step over until compaction reaches the bottom level. Cassandra's gc_grace adds a repair-safety delay on top.
- **Space headroom.** Tiered and size-tiered compaction need large free space on disk for big merges. Running at 80% disk full is a production incident waiting to happen.
- **Tuning.** Large values multiply write amplification; key-value separation (WiscKey, BlobDB, Titan) addresses this. Point-read SLOs often depend on the Bloom filter memory budget.

**DE judgment.** Pick an LSM for write-heavy ingest, SSD endurance budgets that favour sequential writes, or a need for compression and compactness. Pick leveled when reads and space matter. Pick tiered when write throughput dominates, and TWCS-style compaction for append-only TTL data.

In review, ask for:
- The measured write, read and space amplification at target load.
- Compaction throughput headroom (at least 2× ingest).
- The stall thresholds and alerting on pending compaction bytes.
- What the delete pattern looks like.

### MVCC visibility and Serializable Snapshot Isolation
> Lets readers and writers proceed without blocking each other by keeping multiple row versions, and adds a cheap runtime check so that snapshot reads still give serializable results.

**How it works.** Each row version carries the ID of the transaction that created it and the ID of the one that deleted or superseded it. Postgres calls these xmin and xmax; other engines use begin and end timestamps. A transaction takes a snapshot S at start (or per statement under READ COMMITTED).

The visibility rule for version v under snapshot S:

```text
visible(v,S) =
  committed_before(v.xmin, S) or v.xmin == self
  AND NOT ( v.xmax set AND
    (committed_before(v.xmax,S) or v.xmax==self) )
```

In Postgres, S is the triple (xmin, xmax, xip[]). A transaction ID counts as committed-before if it is below xmax, not in the in-progress list, and its commit-log entry says committed.

Snapshot Isolation (SI) adds first-committer-wins on write-write conflicts. That still allows **write skew**. Example: two on-call doctors each read "2 on call", each remove themselves, and both commit, leaving nobody on call.

SSI (Cahill et al., 2008; Postgres 9.1, Ports & Grittner) detects the cases where SI is not serializable:
1. Track SIREAD locks: the predicates and tuples each transaction read.
2. When T1 reads something T2 later overwrites, record an rw-antidependency T1 → T2.
3. Every non-serializable SI history contains a "dangerous structure": T_in → T_pivot → T_out, two consecutive rw-edges, where T_out commits first.
4. When a pivot is detected, abort one participant with a serialization failure (SQLSTATE 40001).

**Complexity.** Reads take no locks and never block. Visibility is a per-version check, but long version chains raise scan cost. SSI adds memory for SIREAD locks, which are coarsened from tuple to page to relation under pressure, plus some false-positive aborts. Throughput is usually within a small factor of SI, far better than strict 2PL under contention.

**Where you meet it.** PostgreSQL SERIALIZABLE is SSI. Oracle's "SERIALIZABLE" is really SI. MySQL InnoDB is MVCC, with 2PL-style locking for SERIALIZABLE. CockroachDB uses MVCC with timestamp ordering and read refresh rather than classic SSI. Spanner uses MVCC snapshot reads and 2PL for read-write transactions. Other examples: SQL Server SNAPSHOT, and Hekaton's optimistic MVCC.

**Pitfalls.**
- **Long-running transactions** pin the GC horizon. Vacuum cannot remove dead versions, so tables and indexes bloat and Postgres risks XID wraparound. Replica hot_standby_feedback extends this to replicas.
- **Retries are required.** SSI and SI both abort, and apps without idempotent retry loops surface 40001s as user errors.
- **Mixed isolation levels** void the guarantee: SSI only protects transactions that all run SERIALIZABLE.
- **Read-only anomalies** exist under SI. SSI handles them, and offers DEFERRABLE read-only transactions.
- **Coarsened predicate locks** raise false-positive aborts on large scans.

**DE judgment.** Default to SERIALIZABLE where invariants cross rows, such as balances, quotas or scheduling. The cost is usually smaller than the cost of one write-skew bug. Use SI or READ COMMITTED only with explicit reasoning, for example SELECT FOR UPDATE or materialised conflicts.

In review, ask:
- Which invariants span rows?
- What is the retry policy and backoff?
- What is the longest transaction, and who monitors the oldest snapshot age?
- Are batch jobs holding snapshots open for hours?

### ARIES write-ahead-log recovery
> Restores a database to a consistent state after a crash while letting the buffer manager write dirty pages whenever it likes (steal) and not forcing them at commit (no-force).

**How it works.** Every log record gets a monotonically increasing LSN. Each page stores the pageLSN of the last record applied to it.

The **WAL rule** has two parts:
- A page may be written to disk only after the log is durable up to that pageLSN.
- A commit is acknowledged only after its commit record is durable.

Each transaction's records are chained by prevLSN. Periodic **fuzzy checkpoints** log the transaction table and the dirty page table (DPT, page → recLSN, the first LSN that dirtied it) without quiescing.

Recovery has three passes:
1. **Analysis.** Scan forward from the last checkpoint and rebuild the transaction table and the DPT. Transactions with no commit or end record are the "losers".
2. **Redo: repeat history.** Start from the smallest recLSN in the DPT. For each update or CLR, reapply it unless the page is not in the DPT, the record's LSN is below that page's recLSN, or pageLSN ≥ LSN. This redoes loser work too, which restores the exact pre-crash state.
3. **Undo.** Roll back the losers in reverse LSN order. Each undo writes a Compensation Log Record (CLR) with undoNextLSN, so a crash during undo never undoes the same step twice. CLRs are redo-only.

```text
ckpt      min recLSN                    crash
 |-----------|---------------------------X
 analysis -------------------------------->
             redo ------------------------>
 <------------------------ undo (losers)
```

Logging is physiological: physical to a page, logical within it. That allows record-level locking and operation-level undo, for example undoing a B-tree insert that has since moved to another page because of a split.

**Complexity.** Normal-path cost is one sequential log append per change plus group-commit fsyncs. Recovery time is proportional to the log since the oldest recLSN, which is bounded by checkpoint frequency and dirty-page flushing.

**Where you meet it.** IBM DB2 (where ARIES originated), SQL Server, and InnoDB, which is ARIES-style with redo log plus undo segments. PostgreSQL uses WAL redo only: MVCC heap versions remove the need for an undo pass, and aborted transactions' tuples just stay invisible. SQLite WAL mode and RocksDB's WAL are simpler redo-only logs.

**Pitfalls.**
- **fsync semantics.** Linux may drop dirty pages after an fsync error ("fsyncgate", 2018). Retrying fsync then falsely succeeds, so engines now PANIC instead.
- **Torn pages.** A crash mid-write leaves a half-old page that redo cannot fix from a delta. Mitigations are full-page images after each checkpoint (Postgres), the doublewrite buffer (InnoDB), or atomic-write hardware.
- **Disk caches that lie** about durability, such as volatile write caches without FUA or PLP.
- **Checkpoint sizing.** Infrequent checkpoints mean long recovery. Aggressive checkpoints cause I/O spikes and full-page-write bloat.
- **Undo replay** of huge loser transactions makes restart time unpredictable.

**DE judgment.** You rarely implement ARIES, but you constantly depend on its invariants. The DE value lies in verifying them across layers: storage virtualisation, cloud block devices, replicated logs, and storage that separates the log from pages (Aurora's "the log is the database").

In review, probe:
- What exactly makes a commit durable, and on how many devices or AZs?
- What is the bound on recovery time objective (RTO) after a crash?
- How are torn writes prevented?
- Has crash-consistency testing been run (fault injection, power-pull, ALICE or CrashMonkey style)?

### Reed-Solomon erasure coding
> Tolerates the loss of any m out of k+m storage fragments at far less overhead than replication.

**How it works.** Split the data into k equal data chunks and compute m parity chunks, so n = k + m. Arithmetic is done in a finite field, usually GF(2^8), byte-wise. The code is a linear map: codeword = G · data, where G is an n×k generator matrix whose top k rows are the identity (systematic, so the data reads directly). Any k rows of G are invertible, which makes the code MDS (Maximum Distance Separable). Cauchy or adjusted Vandermonde constructions ensure this.

```text
 d1 d2 d3 d4 d5 d6 | p1 p2 p3     RS(6,3)
 any 6 of the 9 chunks rebuild the stripe
 overhead 9/6 = 1.5x  vs 3x replication
```

1. **Encode.** Each parity byte is a GF(2^8) linear combination of the data bytes, computed with table or SIMD multiplies (Intel ISA-L, Jerasure).
2. **Decode.** Take any k surviving chunks, invert the k×k submatrix, and multiply.
3. **Update.** Changing one data chunk requires reading the old data and recomputing all m parities, which is a read-modify-write.

**Complexity.** Storage is n/k× the raw size. Encoding costs O(k·m) field operations per byte, which reaches multiple GB/s per core with SIMD. **Repair is the big cost**: rebuilding one lost chunk reads k chunks, so repair network traffic is k× the lost data, versus 1× for replication. Durability is much better than 3× replication at about half the space.

**Where you meet it.**
- HDFS erasure coding (RS-6-3, RS-10-4 policies).
- Facebook f4 warm blob storage (RS(10,4)).
- Backblaze Vaults (17+3).
- Ceph EC pools, MinIO, and object stores generally.
- Azure Storage uses LRC (12,2,2), a locally repairable code. It adds local parities so most single-failure repairs read 6 chunks instead of 12.
- RAID-6 is the m=2 special case.

**Pitfalls.**
- **Degraded reads.** If a needed data chunk is down, the read must fetch k chunks and decode, so tail latency jumps.
- **Small objects.** Tiny files padded to stripe size waste space. Pack them into larger containers first.
- **Correlated failure.** Chunks must be placed across independent failure domains (disks, hosts, racks, AZs). An RS(6,3) stripe with 4 chunks in one rack tolerates zero rack losses.
- **Repair storms.** Losing a node triggers cross-cluster reads of k× data. Throttle repair and prioritise stripes closest to data loss.
- **Hot or mutable data.** EC is painful for frequently overwritten data because of the parity read-modify-write. Write hot data replicated, then convert to EC when cold.

**DE judgment.** Use EC for large, cold-to-warm, immutable data where cost per byte dominates. Keep replication for hot, small, latency-sensitive or frequently mutated data. Consider LRC or regenerating codes when repair bandwidth is the bottleneck.

In review, ask:
- Which k, m and placement were chosen, and what is the modelled annual durability (with MTTR included)?
- What are the degraded-read p99 and the repair bandwidth budget?
- What is the small-object strategy?
- What happens when two failure domains are down at once?

## Probabilistic Data Structures

### Bloom filter
> Answers "is x possibly in the set?" in a few bits per element, with no false negatives and a tunable false-positive rate.

**How it works.** A Bloom filter is a bit array of m bits and k independent hash functions.

1. **Insert x.** Set the bits h_1(x) … h_k(x).
2. **Query x.** If all k bits are set, return "maybe present". If any bit is clear, return "definitely absent".

```text
 insert "a": h1,h2,h3 -> 2,5,9
 bits: 0 0 1 0 0 1 0 0 0 1 0 0
 query "b": h -> 2,7,9 -> bit7=0 -> absent
```

With n elements inserted:

```text
 FPR p ≈ (1 - e^(-k·n/m))^k
 optimal k = (m/n)·ln 2
 then  p ≈ 0.6185^(m/n)
 bits/element m/n = -log2(p) / ln 2 ≈ 1.44·log2(1/p)
```

So 1% FPR needs about 9.6 bits per element with k = 7, and 0.1% needs about 14.4 bits with k = 10.

Kirsch–Mitzenmacher shows that two base hashes are enough: g_i(x) = h1(x) + i·h2(x). **Blocked Bloom filters** confine all k bits to one cache line (or SIMD word), which costs a small FPR increase and buys one memory access per query.

**Complexity.** Insert and query are O(k) with no allocation. Space is about 1.44·log2(1/p) bits per element, which is about 44% above the information-theoretic minimum of log2(1/p). Plain Bloom filters do not support deletion.

**Where you meet it.**
- LSM engines (RocksDB, LevelDB, Cassandra, HBase) keep a filter per SSTable or partition to skip disk reads.
- Distributed join filters (Spark runtime filters, Impala, Presto).
- CDN "one-hit-wonder" filtering (Akamai).
- Bitcoin SPV clients (BIP37), deprecated partly because the filter leaked privacy.
- Chrome Safe Browsing historically used one.

**Pitfalls.**
- **Overfilling.** FPR climbs steeply once n exceeds the design n. A filter sized for 1M keys holding 3M is nearly useless. Size from real cardinality, or use scalable Bloom filters (a chain of growing filters).
- **Weak or correlated hashes** inflate FPR. Hashing a 32-bit value and slicing it for large m is a classic bug.
- **Deletes.** Counting Bloom filters (4-bit counters) support delete at about 4× space, and the counters can overflow.
- **Adversarial inputs** can be crafted to collide if the hash is unkeyed.
- **Wrong denominator.** The real cost is the FPR times the price of a false positive (a disk seek), so the useful metric is wasted I/O per query.

**DE judgment.** Use a Bloom filter in front of any expensive negative lookup when false positives are cheap and false negatives are unacceptable. Prefer a Cuckoo filter when deletes are needed or the target FPR is below about 3%. Prefer Xor or Ribbon filters for static sets: they are about 20–30% smaller, and RocksDB offers Ribbon.

In review, ask:
- What n, p and memory budget were assumed, and what happens at 3× n?
- Is the filter rebuilt or merged, and how?
- Are the hashes independent and of adequate width?

### Cuckoo filter
> An approximate set-membership structure like a Bloom filter that also supports deletion, and is smaller at low false-positive rates.

**How it works.** A Cuckoo filter (Fan, Andersen, Kaminsky, Mitzenmacher, 2014) stores short fingerprints f(x) of F bits in a table of buckets, each holding b slots (typically b = 4). Each item has two candidate buckets:

```text
 i1 = hash(x)
 i2 = i1 XOR hash(f(x))     (partial-key cuckoo)
 so either bucket + fingerprint gives the other
```

1. **Insert.** If i1 or i2 has a free slot, store f(x) there. Otherwise pick a slot in one bucket, evict its fingerprint, and move it to its alternate bucket (computable from the fingerprint alone). Repeat, up to a max-kicks limit (about 500).
2. **Lookup.** Check whether f(x) is in bucket i1 or i2. That is at most two cache lines.
3. **Delete.** Remove one copy of f(x) from i1 or i2.

The false-positive rate is about 2b / 2^F, because a lookup compares against 2b fingerprints. Achievable load is about 95% with b = 4. Bits per item ≈ (log2(1/p) + log2(2b)) / α, where α is the load factor.

**Complexity.** Lookup and delete are O(1), with two bucket reads. Insert is O(1) amortised, but degrades sharply near capacity and can fail. Space beats a space-optimised Bloom filter when the target FPR is below about 3%. For example, about 13.6 bits per item at 0.1% versus 14.4 for Bloom (about 12.6 with the semi-sorted bucket variant).

**Where you meet it.**
- RedisBloom's CF.* commands.
- Packet-processing and switch tables.
- Caching layers that need delete-on-evict membership.
- Several key-value stores' in-memory indexes.

The partial-key cuckoo idea also appears in MemC3 and in cuckoo hash tables generally.

**Pitfalls.**
- **Insert failure.** Near capacity, kick chains fail. The filter is "full" and cannot simply be extended, so callers need a fallback (resize and rehash from source, or a second filter).
- **Deleting a key that was never inserted** can remove another key's matching fingerprint and create a false negative. Delete only what you know you inserted.
- **Duplicates.** At most 2b copies of the same key fit. Repeated inserts of a hot key fail.
- **Sizing.** The XOR trick needs a power-of-two table, which can waste up to 2× space. Variants such as the Vacuum or Morton filter address this.
- **Determinism.** Insert results depend on the RNG and insertion order, which matters if you expect identical filters across replicas.

**DE judgment.** Choose a Cuckoo filter when membership is dynamic (items expire or are revoked) and you need a low FPR in tight memory. Stay with Bloom if inserts must never fail, the set only grows within a known bound, or merging (bitwise OR) across shards is required, since Cuckoo filters do not union trivially.

In review, ask:
- What is the max load target and the full-filter behaviour?
- Is there a delete-safety guarantee?
- Are fingerprint bits matched to the stated FPR?

### HyperLogLog
> Estimates the number of distinct elements in a huge stream using kilobytes of memory and a few percent or less error, with lossless merging.

**How it works.** Hash each element to 64 bits. The first p bits pick one of m = 2^p registers. In the remaining bits, compute ρ: the position of the leftmost 1 bit (number of leading zeros + 1). Each register keeps the maximum ρ it has seen.

```text
 hash = 0110 | 0001 01101...
        idx=6   rho=4  -> M[6] = max(M[6],4)
```

Intuition: seeing a run of r leading zeros suggests about 2^r distinct values. Averaging across m registers with a harmonic mean controls the variance.

```text
 E = α_m · m² / Σ_j 2^(-M[j])
 α_m ≈ 0.7213 / (1 + 1.079/m)
 relative std error ≈ 1.04 / √m
```

With p = 14 (m = 16384) and 6-bit registers, that is 12 KB of memory and about 0.81% standard error.

1. **Small cardinalities** (E ≤ 2.5m with empty registers): switch to linear counting, m·ln(m/V), where V is the number of zero registers.
2. **HLL++ (Google, 2013).** Uses a 64-bit hash, so large-range correction is unnecessary. Adds empirical bias correction in the mid range and a sparse representation (a list of index and ρ pairs) for small sets, giving exact-ish small counts in tiny space.
3. **Merge.** Take the register-wise max. Union is exact with respect to the sketches, so you can pre-aggregate per shard, hour or dimension and roll up.

**Complexity.** Insert is O(1). Estimating is O(m), or O(1) with incremental tracking. Space is m·6 bits. Error is about 1.04/√m, independent of the true cardinality, so a few percent is common at small p.

**Where you meet it.**
- Redis PFADD and PFCOUNT (12 KB dense, plus a sparse encoding).
- BigQuery APPROX_COUNT_DISTINCT and HLL_COUNT.*.
- Presto/Trino approx_distinct.
- Spark approx_count_distinct.
- Druid, ClickHouse uniq*, Elasticsearch cardinality.
- Datadog, Snowflake, and Postgres via the postgresql-hll extension.

**Pitfalls.**
- **Intersections.** Estimating |A ∩ B| by inclusion–exclusion adds absolute errors. The relative error explodes when the intersection is small relative to the union. Use MinHash or theta sketches for set operations.
- **Merge compatibility.** Sketches with different precision or different hash functions cannot be merged. Pin the hash and p in the storage format, and version them.
- **Poor hashes** (low-entropy high bits) bias the result badly.
- **Biased estimates** from the raw estimator in the transition range if implementations skip HLL++ corrections.
- **Reporting.** Treating the estimate as exact in billing or quota enforcement causes disputes. Expose error bars.

**DE judgment.** Use HLL for distinct counts across many dimensions and time buckets where storing sets is impossible: unique users per page per hour, rolled up arbitrarily.

In review, ask:
- Is about 1% error acceptable for this decision?
- Are intersections or differences needed (if so, use theta or KMV sketches)?
- Is the sketch format versioned and are the hashes stable?
- Is anything financially material derived from it?

### Count-Min sketch
> Estimates per-key frequencies in a high-volume stream in sublinear space, with a one-sided, bounded overestimate.

**How it works.** A Count-Min sketch is a d×w array of counters with d pairwise-independent hash functions, one per row.

```text
       w columns
 row1 [ 0  3  0  7  1 ]   h1(x)=3 -> +c
 row2 [ 2  0  8  0  0 ]   h2(x)=2 -> +c
 row3 [ 0  9  0  0  1 ]   h3(x)=1 -> +c
 est(x) = min(7, 8, 9) = 7
```

1. **Update(x, c).** For each row i, add c to C[i][h_i(x)].
2. **Query(x).** Return the minimum over rows of C[i][h_i(x)]. Every row overestimates, because of collisions, so the minimum is the tightest bound.

The guarantee, for non-negative updates with total stream mass ‖a‖₁ = N:

```text
 a_x ≤ â_x ≤ a_x + ε·N   with prob ≥ 1 − δ
 w = ⌈e/ε⌉,  d = ⌈ln(1/δ)⌉
```

So ε = 0.1% and δ = 1% need w ≈ 2719 and d = 5, about 13.6K counters regardless of the number of distinct keys.

- **Conservative update.** Raise each counter only up to (current min + c). This sharply reduces overestimation, but you can no longer subtract.
- **Heavy hitters.** Pair the sketch with a min-heap of the top-k candidates, or use a hierarchical sketch over key prefixes.
- **Count Sketch** (Charikar et al.) uses ±1 signs and the median. It is unbiased, its error is bounded by ε·‖a‖₂, and it is better for skewed data with turnstile updates.

**Complexity.** Update and query are O(d). Space is O((1/ε)·log(1/δ)) counters. Sketches with the same dimensions and hashes merge by element-wise addition.

**Where you meet it.**
- Network telemetry and DDoS heavy-hitter detection (switch ASICs, UnivMon).
- Rate limiting and abuse detection keyed by IP or user at scale.
- Caffeine's TinyLFU admission policy (a 4-bit CM-like frequency sketch with periodic halving).
- Redis CMS.* commands.
- Streaming systems (Flink and Spark libraries), and approximate top-k in databases.

**Pitfalls.**
- **Error scales with total volume N**, not the key's own frequency. For tail keys the estimate is mostly noise. CM is only useful for keys well above ε·N.
- **Unbounded growth.** Counters grow forever, so recent-window semantics need sliding windows, periodic decay (TinyLFU halving), or rotating sketches.
- **Negative updates** break the min estimator's guarantee. Use Count Sketch instead.
- **Hash-flooding attacks.** Without keyed hashes, an attacker can inflate a victim's count.
- **Counter width.** Undersized counters overflow on hot keys.

**DE judgment.** Use CM for "how often" questions on heavy keys: top-k, frequency-based admission, abuse thresholds. Do not use it to bill or to decide on rare keys.

In review, ask:
- What is N per window, and is ε·N below the decision threshold?
- How do recency and decay work?
- Are the hashes keyed, and do merges across nodes use identical seeds?

### t-digest
> Estimates quantiles such as p50, p99 and p99.9 from streaming or distributed data in small, mergeable space, with the best accuracy at the tails.

**How it works.** A t-digest (Dunning and Ertl) summarises a distribution as a sorted list of centroids, each a (mean, weight) pair. A **scale function** k(q) limits each centroid's size based on its quantile position. A centroid spanning quantiles q_left..q_right must satisfy k(q_right) − k(q_left) ≤ 1. Common choices:

```text
 k1(q) = (δ/2π)·asin(2q − 1)
 k2/k3: log-based, tighter at tails
 δ = compression (e.g. 100–500)
```

Because asin is steep near q = 0 and q = 1, centroids at the tails hold few points, down to singletons. Centroids near the median hold many.

1. **Add.** Buffer incoming points.
2. **Compress.** Sort buffer and centroids together by mean, then sweep left to right. Merge neighbours while the k-size bound holds, otherwise start a new centroid. This is the "merging digest".
3. **Quantile(q).** Find the centroids around cumulative weight q·N and interpolate linearly between their means, treating the extremes specially using the tracked min and max.
4. **Merge digests.** Concatenate the centroids and recompress.

**Complexity.** Size is O(δ) centroids, typically a few KB. Insert is O(1) amortised with buffered compression. Queries are O(δ) or O(log δ). Error is empirically small and relative to q(1−q), very good at extreme quantiles, but there is **no worst-case guarantee**.

**Where you meet it.**
- Elasticsearch and OpenSearch percentiles aggregation.
- Apache Druid and Spark extensions, and Apache DataSketches comparisons.
- Redis TDIGEST.* commands.
- Many APM backends.

Alternatives with formal guarantees: DDSketch (Datadog; relative-value error, log-bucketed, deterministic merge), KLL (rank-error guarantee; Apache DataSketches), and HDR Histogram (fixed significant digits within a known range). Prometheus native histograms use exponential buckets.

**Pitfalls.**
- **Averaging percentiles** across hosts is mathematically wrong. Merge the digests and then query.
- **Merge order matters.** Results are not deterministic across merge orders or implementations, so two dashboards can disagree slightly.
- **Heavy duplicates or discrete data** (latencies quantised to 1 ms) give interpolation artefacts.
- **The compression setting** trades memory against accuracy. Defaults differ across libraries.
- **No error bar.** For SLO compliance or contractual reporting you may need a sketch with a provable error bound (DDSketch or KLL), or exact counting of SLO breaches as a ratio.

**DE judgment.** t-digest is a strong default for exploratory latency percentiles. For SLOs, prefer counting good versus bad events against the threshold, which is exact and cheap, plus a guaranteed-error sketch for distribution views.

In review, ask:
- Are percentiles merged correctly across hosts and windows?
- Which sketch, with what compression, and is it the same everywhere?
- Is there a stated error tolerance at p99.9?

### Reservoir sampling
> Maintains a uniform random sample of k items from a stream of unknown, possibly unbounded length in O(k) memory.

**How it works.** Algorithm R (Vitter, 1985):
1. Put the first k items in the reservoir.
2. For item i (1-indexed, i > k), draw j uniformly from [1, i]. If j ≤ k, replace reservoir[j] with item i.

```text
 P(item i survives to end n)
 = k/i · Π_{t=i+1..n} (1 − 1/t)
 = k/i · i/n = k/n
```

By induction, every item is in the sample with probability exactly k/n, and every k-subset is equally likely.

- **Algorithm L** (Li, 1994) computes how many items to skip from a geometric-like distribution instead of drawing per item. Expected RNG calls drop to O(k·(1 + log(n/k))), which matters at line rate.
- **Weighted sampling (A-Res, Efraimidis–Spirakis).** Give each item the key u^(1/w), with u ~ U(0,1) and w the weight, and keep the k largest keys in a min-heap.
- **Distributed sampling.** Tag each item with a random key and keep the k smallest per shard. The k smallest across shards' samples is a uniform sample of the union, so the method is mergeable.

**Complexity.** Space is O(k). Time is O(1) per item for R, and sublinear RNG use for L. Weighted sampling costs O(log k) per item.

**Where you meet it.**
- PostgreSQL ANALYZE samples rows with Vitter's reservoir methods.
- Database and warehouse sampling clauses.
- Tracing and log samplers.
- ML training-data pipelines over streams.
- Dropwizard/Codahale Metrics histograms: uniform, sliding and exponentially-decaying reservoirs.
- Online A/B and data-quality sampling.

**Pitfalls.**
- **The sample covers the whole stream**, not the recent past. A uniform reservoir on a long-lived process mostly reflects old traffic. Decaying reservoirs fix recency but bias the tails. Dropwizard's EDR is known to under-report latency spikes and to keep stale values when traffic stops.
- **RNG mistakes.** `rand() % i` has modulo bias, and an RNG seeded identically across workers gives correlated samples.
- **Percentiles from a small reservoir** (k = 1028) are imprecise. p99.9 from 1028 samples is about one point.
- **Merging reservoirs** without the random-key method (or without weighting by stream counts) yields a non-uniform sample.
- **Weighted variants** need positive weights and careful floating point (use log-space keys).

**DE judgment.** Use reservoir sampling when you need representative raw records: debugging samples, training data, query statistics. It is the wrong tool for exact tail metrics; use sketches or exact counters there.

In review, ask:
- Uniform over what window?
- Is the sample mergeable across shards?
- Is the RNG sound and independently seeded?
- Is anyone computing p99s from it?

### MinHash and LSH
> Estimates Jaccard similarity between large sets cheaply, and finds near-duplicate pairs among millions of items without comparing every pair.

**How it works.** Jaccard similarity is J(A,B) = |A∩B| / |A∪B|. Represent each document as a set of shingles, for example 5-word n-grams, hashed to 64 bits.

**MinHash.** For a random hash or permutation h, P[min h(A) = min h(B)] = J(A,B). Use k independent hashes to build a signature of k minima. The estimate Ĵ is the fraction of positions where two signatures agree, with standard error about √(J(1−J)/k). For example, k = 128 gives ±0.044 at J = 0.5.

Cheaper variants: one-permutation hashing with densification, or bottom-k (the k smallest values of a single hash).

**LSH banding.** Split each signature into b bands of r rows each (k = b·r). Hash each band to a bucket. Two items become a **candidate pair** if any band matches exactly.

```text
 P(candidate) = 1 − (1 − J^r)^b
 threshold   t ≈ (1/b)^(1/r)

 b=20,r=5: J=0.8 -> 0.9997   J=0.3 -> 0.047
```

The S-curve separates similar from dissimilar pairs. Tune b and r to move the threshold and trade false negatives against candidate volume. Candidates are then verified with the full signature or the exact Jaccard.

**Complexity.** Signing costs O(|A|·k), or O(|A| + k) with one-permutation schemes. Each signature is k words. LSH indexing is O(n·b), and candidate generation is roughly linear in n plus output size, versus O(n²) all-pairs.

**Where you meet it.**
- Web-crawl near-duplicate detection, from Broder's AltaVista work onward.
- LLM pretraining data deduplication pipelines (MinHash-LSH over n-grams is standard).
- Spark MLlib MinHashLSH.
- datasketch (Python).
- Plagiarism and code-clone detection, genomics (Mash), record linkage, and recommendation candidate generation.

Related techniques: SimHash for cosine similarity (Google's crawl dedup), and theta sketches for set algebra on cardinalities.

**Pitfalls.**
- **Shingling choices** dominate quality: tokenisation, normalisation (case, whitespace, boilerplate) and n-gram size. Short documents give unstable Jaccard.
- **Common shingles** (headers, licences, templates) create giant buckets and quadratic candidate blow-up. Filter frequent shingles or cap bucket sizes.
- **False negatives** are silent. Measure recall on a labelled sample rather than trusting the S-curve.
- **Signature storage** at k×8 bytes for billions of items is large. Use b-bit MinHash (store only the low bits) or smaller k.
- **Hash independence.** Linear permutations (a·x + b mod p) are fine. Reusing correlated seeds is not.
- **Transitivity.** Clustering near-duplicates via union-find over pairs can chain dissimilar items together.

**DE judgment.** Use MinHash and LSH when the similarity notion really is set overlap and n is too large for all-pairs. For semantic similarity, use embeddings with ANN indexes instead (HNSW, IVF-PQ).

In review, ask:
- What threshold is targeted and what recall was measured?
- How are hot buckets handled?
- How are clusters formed, and what is the verification step's cost?

## Partitioning and Placement

### Consistent hashing with virtual nodes
> Maps keys to a changing set of nodes so that adding or removing a node moves only about 1/N of the keys, while keeping load balanced.

**How it works.** Hash nodes and keys onto the same circular space, such as [0, 2^64). A key belongs to the first node clockwise from its hash. To reduce variance, each physical node owns V **virtual nodes** (tokens) at independent ring positions.

```text
        A1       B1
     .--*---------*--.
   C2*      k->      *A2     k lands after A1,
     |   ring 2^64   |       owner = next token
   B2*               *C1     clockwise = B1
     '--*---------*--'
        A3       B3
```

1. **Lookup.** Binary-search the sorted token array for the first token ≥ hash(key), wrapping around at the end.
2. **Join.** The new node's V tokens each take a slice from their successors. In expectation only about K/(N+1) keys move.
3. **Replication (RF = r).** Walk clockwise to collect r distinct physical nodes. Skip tokens of nodes already chosen, and skip same-rack or same-AZ nodes for topology-aware placement.

With one token per node, the largest arc is about (ln N)/N of the ring, an O(log N) imbalance. With V = Θ(log N) tokens per node, the load is within a constant factor of the mean. Relative imbalance falls roughly as 1/√V.

**Consistent hashing with bounded loads** (Mirrokni et al., 2016) caps each node at (1+ε) × average load. Overflow keys go on to the next node. This gives strict balance with slightly more movement.

**Complexity.** Lookup is O(log(N·V)) by binary search. Memory is O(N·V) tokens. Expected key movement on a membership change is K/N.

**Where you meet it.**
- Amazon Dynamo, Riak, and Cassandra and ScyllaDB (num_tokens; Cassandra 4.0 lowered the default from 256 to 16 with a token-allocation algorithm).
- Memcached client libraries (ketama), Envoy and Nginx ring-hash load balancing.
- Akamai, where the idea originated (Karger et al., 1997).

**Pitfalls.**
- **Too many vnodes.** Each node shares ranges with nearly every other node, so a two-node failure probably intersects some replica set (with RF = 3 and 256 tokens, losing any 3 nodes likely loses some quorum). Repair, streaming and anti-entropy also cost more. This is why Cassandra moved to fewer tokens.
- **Too few vnodes** without an allocation algorithm leave visible hot nodes.
- **Heterogeneous hardware** needs weights through vnode count. Changing weights moves data.
- **Hot keys** are not fixed by any hashing scheme. You need key splitting, caching or request coalescing.
- **Inconsistent membership views** across clients route the same key to different owners. Gossip or a coordination service with epochs must bound this.

**DE judgment.** Use vnodes on a ring when nodes come and go, data must move minimally, and you need replica placement as walk-the-ring with topology awareness.

In review, probe:
- How many tokens per node, and what is the failure-correlation analysis for RF and quorum?
- How are hot keys handled?
- How is membership agreed and versioned?
- Would range partitioning with a directory (Bigtable/Spanner style) better serve scans and resharding?

### Rendezvous (HRW) hashing
> Lets every client pick the same owner (or top-r owners) for a key from a node list, with minimal disruption, no ring and no shared state beyond the list.

**How it works.** Rendezvous, or Highest Random Weight, hashing was introduced by Thaler and Ravishankar (1996). For key k and each node n_i, compute a score s_i = h(k, n_i). The owner is the node with the highest score. For replication, take the top r scores.

```text
 key "u42":  h(u42,A)=0.31  h(u42,B)=0.88
             h(u42,C)=0.12  h(u42,D)=0.67
 owner = B ; replicas (r=2) = B, D
 remove B -> keys move to their own 2nd choice
```

1. **Removal.** Only keys whose top choice was the removed node move, and they spread evenly over the remaining nodes because each key's runner-up is random.
2. **Addition.** The new node takes about 1/(N+1) of the keys, from every node proportionally.
3. **Weighted HRW.** Use score = −w_i / ln(U(k, n_i)), with U uniform in (0,1). This gives a node share exactly proportional to w_i and keeps minimal disruption (the logarithmic method, Schindelhauer & Schomaker).

**Complexity.** Lookup is O(N) hash evaluations, or O(N log r) for the top r. There is no extra memory beyond the node list, and balance is near-perfect without virtual nodes. For large N, use **skeleton-based** or hierarchical HRW: hash to a group, then HRW within it, giving O(log N).

**Where you meet it.**
- Microsoft's Cache Array Routing Protocol (CARP) for proxy arrays.
- Apache Ignite's default rendezvous affinity function.
- GitHub's GLB Director, which uses HRW to fill its forwarding table.
- Kubernetes-adjacent shard assigners, distributed caches (some memcached clients), Tahoe-LAFS-style storage selection, and many internal sharding libraries.

**Pitfalls.**
- **O(N) per lookup** becomes measurable on hot paths with hundreds of nodes. Cache the result per key, or precompute a table.
- **Weak combined hashes.** Using h(k) XOR h(n) correlates scores across keys. Use a real mixing function such as xxhash or murmur over (k, n) or a keyed hash.
- **Naive weighting.** Multiplying the score by a weight does not give proportional shares.
- **Divergent node lists.** All clients need the same node identity strings. A node renamed across deploys reshuffles everything.
- **No range locality**, as with any hashing.

**DE judgment.** HRW is the simplest correct choice for small to medium N (up to a few hundred), especially when you need top-r replica selection and weights without ring machinery. It is often a better default than a vnode ring.

In review, ask:
- What is N, and what is the lookup rate?
- Is the hash mixing sound?
- Are weights computed with the logarithmic method?
- Are node IDs stable across restarts and renames?

### Jump consistent hash
> Maps a key to one of n numbered buckets with perfect balance, zero memory and minimal movement when n grows.

**How it works.** Jump consistent hash (Lamping and Veach, Google, 2014) simulates a process in which, as buckets grow from 1 to n, each key jumps to the new bucket j with probability 1/(j+1). Instead of iterating every bucket, it uses the key as a seeded PRNG and jumps directly to the next bucket where the key would move.

```text
int32 jump(uint64 key, int32 n) {
  int64 b = -1, j = 0;
  while (j < n) {
    b = j;
    key = key * 2862933555777941757ULL + 1;
    j = (b + 1) * (double(1LL << 31) /
                   double((key >> 33) + 1));
  }
  return b;
}
```

1. When going from n to n+1 buckets, exactly a 1/(n+1) fraction of keys moves, and every moved key goes to the new bucket n.
2. Every bucket gets 1/n of the keys, with standard deviation far below what ring hashing achieves.

**Complexity.** Expected time is O(ln n) loop iterations, typically tens of nanoseconds. Memory is O(1). Movement is optimal for growth at the end.

**Where you meet it.**
- Sharding when shards are logical, numbered and only appended: storage partitions mapped onto buckets, as in Google's internal sharding.
- Partition-to-shard mapping in some time-series and analytics databases.
- Client-side sharding libraries (Guava's Hashing.consistentHash uses a related LCG algorithm).
- Distributing work across a fixed, numbered set of queues or files.

It is often combined with a separate mapping from bucket to node that handles failover.

**Pitfalls.**
- **Arbitrary removal is impossible.** You can only add or remove the highest-numbered bucket. Removing a node from the middle requires an indirection layer (bucket → node table) or swapping the last bucket's identity into the hole, which moves that bucket's data.
- **Not for raw node identities.** It is a poor fit for a set of servers that fail independently. Use HRW, a ring or Maglev there.
- **Bad keys.** The key must already be a well-mixed 64-bit hash. Low-entropy keys such as sequential IDs give poor balance, so hash first.
- **No weights.** Weighting needs multiple buckets per node.
- **Cross-language drift.** Signed versus unsigned shifts or float conversion differences break bucket agreement between languages. Test with golden vectors.

**DE judgment.** Excellent when the thing being numbered is a stable logical shard set that grows, and a separate, replicated placement layer maps shards to machines. That two-level design (keys → jump → shard → directory → nodes) is often the best overall architecture.

In review, ask:
- What happens when a bucket's host dies? If the answer is "remove the bucket", jump is the wrong layer.
- Do all language implementations agree on the golden vectors?

### Maglev hashing
> Gives a software load balancer an O(1) per-packet backend lookup with near-perfect balance and minimal disruption when backends change.

**How it works.** Maglev hashing (Eisenbud et al., Google, NSDI 2016) builds a lookup table of prime size M (default 65537; generally M ≫ 100·N).

For each backend i, derive a permutation of the table slots:

```text
 offset_i = h1(name_i) mod M
 skip_i   = h2(name_i) mod (M − 1) + 1
 perm_i[j] = (offset_i + j·skip_i) mod M
```

1. **Populate.** Go round-robin over the backends. Each takes the next slot in its own permutation that is still empty. Continue until all M slots are filled. Weighted variants give a backend more turns per round.
2. **Lookup.** backend = table[hash(5-tuple) mod M].
3. **Change.** When a backend is added or removed, rebuild the table. Most slots keep their owner because each backend's preference order is unchanged.

```text
 slot:   0 1 2 3 4 5 6   (M=7)
 B0 perm 3 0 4 1 5 2 6
 B1 perm 0 2 4 6 1 3 5
 B2 perm 3 4 5 6 0 1 2
 table:  B1 B0 B1 B0 B2 B2 B0
```

**Complexity.** Lookup is O(1), one array read. Build is O(M log M) expected, or O(M·N) worst case. Memory is O(M). Each backend owns about M/N slots, differing by at most one slot in the unweighted case. Disruption is near-minimal but not strictly minimal: a few slots beyond the removed backend's share can move.

**Where you meet it.**
- Google's Maglev network load balancer.
- Envoy's MAGLEV load-balancing policy.
- Cilium's kube-proxy replacement (Maglev mode).
- Facebook Katran (a Maglev-style table).
- Several cloud L4 load balancers.

The design aim is that independent LB instances with the same backend set compute the same table, so ECMP can spray packets across LBs without shared state.

**Pitfalls.**
- **Connection breakage.** Even near-minimal disruption breaks in-flight TCP connections whose slot changed. Maglev pairs the table with a per-LB connection-tracking table. A connection that lands on a different LB after an ECMP change loses that state, so drains and changes should be slow.
- **Small M.** M too small relative to N gives imbalance and more disruption. M must be prime so that skip covers every slot.
- **Unstable backend identity.** Backend names, ordering and the h1/h2 seeds must match on every LB instance. Sort deterministically.
- **Rebuild cost** with large M and frequent health flaps causes CPU spikes and churn. Dampen health-check flapping.
- **Weights** that change constantly, for example from load feedback, defeat the stability.

**DE judgment.** Choose Maglev for packet-rate L4/L7 load balancing with many stateless front-end instances that must agree without coordination.

In review, ask:
- What is the M:N ratio?
- What connection-tracking strategy covers backend changes and ECMP changes?
- How is health-check flapping dampened?
- Are backend lists identical across instances?
- Would the app tolerate a reset, or is connection draining needed?

### Skip list
> Provides an ordered in-memory map with expected O(log n) search, insert and delete, simple to implement and easy to make concurrent or lock-free.

**How it works.** A skip list (Pugh, 1990) is a sorted linked list with probabilistic express lanes. Each node gets a random height: level ℓ with probability p^(ℓ−1)·(1−p), where p is 1/2 or 1/4, capped at MaxLevel ≈ log_{1/p} n.

```text
L3 H----------------------->30--------->NIL
L2 H------>10-------------->30--->50--->NIL
L1 H->5--->10--->17--->22-->30--->50--->NIL
```

1. **Search(x).** Start at the top level of the head. Move right while next.key < x, otherwise drop down a level. At level 1, the next node is x or x's successor.
2. **Insert.** Search while recording the predecessor at each level (the update[] array). Draw a random height h, then splice the new node in at levels 1..h.
3. **Delete.** Unlink the node at every level where it appears.

**Concurrency.** Insertion is a series of single-pointer CAS splices from the bottom up. That makes lock-free variants practical (Fraser; Herlihy–Shavit): mark the next pointer for logical deletion, then unlink physically. Readers need no locks, and in arena-allocated memtables, no reclamation either.

**Complexity.** Expected search, insert and delete are O(log n), with high probability O(log n) as well. Space is n/(1−p) pointers in expectation: 2n for p = 1/2, 1.33n for p = 1/4. Range iteration costs O(k) after the seek.

**Where you meet it.**
- LevelDB and RocksDB memtables (RocksDB's InlineSkipList with concurrent inserts).
- Pebble's arenaskl.
- Redis sorted sets: zskiplist with per-link span counts, giving O(log n) ZRANK.
- Java's ConcurrentSkipListMap.
- HBase's in-memory store and MemSQL/SingleStore's lock-free rowstore indexes.
- Apache Lucene skip data in postings lists, a related on-disk use.

**Pitfalls.**
- **Cache misses.** Each level step is a pointer chase. A B-tree or ART with cache-line-sized nodes often beats a skip list by 2–5× on lookups at large n.
- **Reverse iteration** is expensive in singly linked lock-free variants. Prev() is a fresh O(log n) search, as in RocksDB, so reverse scans on memtables are slower.
- **Memory overhead.** Per-node pointers and allocation overhead are significant for small keys. Arena allocation helps, but you cannot free individual nodes.
- **Bad RNG or uncapped height** produces degenerate towers. Using a weak, shared, contended RNG also hurts under concurrency.
- **Lock-free deletion and reclamation** are hard (ABA problems, hazard pointers or epochs). Many production uses sidestep this by being insert-only, like memtables.

**DE judgment.** Pick a skip list for concurrent, write-heavy, ordered in-memory structures with short lifetimes, where lock-free inserts and simple correctness matter more than peak lookup speed. Memtables are the canonical case.

For long-lived, read-heavy ordered indexes, consider B+-trees, Bw-trees, ART or Masstree.

In review, ask:
- What is the read/write mix?
- Is reverse iteration needed?
- What is the memory-per-entry budget?
- How are deletes and reclamation handled?
