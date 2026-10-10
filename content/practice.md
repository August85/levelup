# Practice questions

Short-answer flash cards for interview practice. Each "## Deck" holds "### Question" cards;
the text under a question is its answer (keep it under ~60 words). Topics follow the questions
most often asked in senior, staff and principal system-design and distributed-systems loops.

## System design fundamentals
> The building blocks every design interview leans on.

### What do you do in the first five minutes of a system design interview?
Clarify scope before drawing anything: core use cases, who the users are, scale (DAU, QPS, data size), latency and availability targets, and what is explicitly out of scope. Write the assumptions down; they drive every later trade-off.

### Horizontal vs. vertical scaling?
**Vertical**: a bigger machine; simple, but has a ceiling and a single point of failure. **Horizontal**: more machines behind a load balancer; near-unbounded and fault tolerant, but needs stateless services or partitioned state.

### Why are stateless services easier to scale?
Any instance can serve any request, so you add or remove instances freely and a crash loses nothing. Session and user state move to a shared store (cache or database), which becomes the thing you scale carefully.

### Layer 4 vs. layer 7 load balancing?
**L4** routes on IP and port; fast and protocol-agnostic. **L7** reads the HTTP request, so it can route by path, header or cookie, terminate TLS, retry and do canaries, at the cost of more CPU per request.

### Cache-aside vs. write-through vs. write-back?
**Cache-aside**: app reads the cache, falls back to the DB and fills the cache. **Write-through**: writes go to cache and DB together (consistent, slower writes). **Write-back**: writes hit the cache and flush later (fast, risks loss on crash).

### What causes a cache stampede and how do you prevent it?
A hot key expires and thousands of requests miss at once and hammer the database. Fixes: request coalescing (single flight), a lock or lease on refill, serving stale while revalidating, and jittered TTLs.

### When do you reach for a CDN?
For static or cacheable content read far more than written, and for users spread across regions. It cuts latency and origin load. Watch invalidation, cache-key design and cost for long-tail content.

### SQL or NoSQL: how do you choose?
Start from access patterns. Relational fits rich queries, joins and transactions. Key-value, wide-column or document stores fit huge scale with simple, known access paths and flexible schemas. Many systems use both.

### What is database sharding and what does it cost?
Splitting data across nodes by a shard key so writes and storage scale out. Costs: cross-shard queries and transactions get hard, hot shards appear with skewed keys, and resharding needs a migration plan.

### How do you pick a shard key?
High cardinality, even distribution, and aligned with the dominant query so most requests hit one shard. Avoid monotonic keys (timestamps, auto-increment) that funnel writes to one shard.

### Why put a message queue between services?
To decouple producers from consumers: it absorbs bursts, lets each side scale and fail independently, and enables retries and fan-out. You trade immediate consistency and simple debugging for resilience.

### What does back-of-the-envelope estimation buy you?
A sanity check on the design's scale: QPS, peak QPS (2-3x average), storage per year and bandwidth. It tells you whether one database is enough, whether you need caching, and where the bottleneck will be.

### What are the latency numbers every engineer should know (roughly)?
L1 cache ~1 ns, main memory ~100 ns, SSD random read ~100 µs, round trip in a datacenter ~0.5 ms, disk seek ~10 ms, cross-continent round trip ~150 ms. Memory is ~1000x faster than SSD, which is ~100x faster than disk.

### How do you design a good API for a system design question?
Name resources and verbs clearly, make writes idempotent (idempotency keys), paginate with cursors, version the API, and return enough for the client to avoid extra round trips. State the core endpoints before the architecture.

### What is the difference between availability and durability?
**Availability**: the system answers requests (e.g. 99.99% = ~52 min down a year). **Durability**: data, once acknowledged, is never lost (e.g. eleven nines in S3). A system can be durable but briefly unavailable.

## Distributed systems
> Consistency, replication, time and failure.

### What does the CAP theorem actually say?
When a network partition happens, a replicated system must choose between consistency (every read sees the latest write) and availability (every request gets an answer). Without a partition you can have both, so CAP is about behavior during failure.

### What does PACELC add to CAP?
**E**lse, even without a partition, you trade **L**atency against **C**onsistency. Synchronous replication costs latency on every write; that trade-off is the one you pay day to day.

### Linearizability vs. serializability?
**Linearizability**: single-object recency; once a write completes, all later reads see it. **Serializability**: multi-object transactions behave as if run one at a time, in some order. **Strict serializability** gives both.

### What is eventual consistency and what goes wrong with it?
If writes stop, replicas converge. Meanwhile users can see stale data, lose their own writes on a different replica, or see time go backwards. Session guarantees (read-your-writes, monotonic reads) patch the worst cases.

### Explain quorums with N, R and W.
Data lives on N replicas; a write waits for W acks, a read asks R replicas. If R + W > N, the read and write sets overlap, so a read sees the latest acknowledged write (absent sloppy quorums). Tune R and W for read or write speed.

### Leader-based, multi-leader and leaderless replication?
**Single leader**: simple, consistent writes, leader is a bottleneck and failover point. **Multi-leader**: writes in several regions, needs conflict resolution. **Leaderless** (Dynamo): any replica takes writes, quorums plus read repair.

### How does Raft elect a leader?
Followers that miss heartbeats for a randomized timeout become candidates, bump the term and request votes. A node votes once per term, only for a candidate whose log is at least as up to date. A majority wins; randomized timeouts avoid split votes.

### Why can't you order events across machines with wall clocks?
Clocks drift and NTP corrections can jump them backwards, so two machines' timestamps can disagree by milliseconds or more. Use logical clocks (Lamport, vector), hybrid logical clocks, or bounded-uncertainty time like TrueTime.

### Lamport clocks vs. vector clocks?
A **Lamport clock** gives a total order consistent with causality, but can't tell you whether two events were concurrent. A **vector clock** keeps one counter per node, so it can detect concurrency, at the cost of size growing with nodes.

### What is split brain and how do fencing tokens prevent damage?
Two nodes both believe they are leader after a partition or GC pause. A fencing token is a monotonically increasing number from the lock service; storage rejects writes carrying an older token, so the stale leader can't corrupt data.

### Why is two-phase commit called blocking?
If the coordinator crashes after participants vote yes, they must hold their locks until it returns; they can't decide alone. Consensus-replicated coordinators (e.g. Spanner) or sagas avoid that.

### What is the saga pattern?
A long transaction split into local steps, each with a compensating action. On failure, run the compensations in reverse. You get availability and loose coupling but give up isolation, so design for intermediate states.

### At-most-once, at-least-once and exactly-once delivery?
**At-most-once**: may lose messages. **At-least-once**: retries, may duplicate. **Exactly-once** in practice means at-least-once delivery plus idempotent or transactional processing (dedup keys, transactional offsets).

### What is the transactional outbox pattern?
Write the business change and an "event to publish" row in the same local transaction; a relay reads the outbox table (or CDC log) and publishes. It removes the dual-write problem between database and broker.

### What are CRDTs good for?
Conflict-free replicated data types merge concurrent updates deterministically without coordination: counters, sets, registers, sequences. Good for offline-first apps, collaborative editing and multi-region active-active state.

### How do Merkle trees help anti-entropy?
Replicas hash key ranges into a tree and compare roots; only differing subtrees are walked and exchanged. Synchronizing two large replicas costs bandwidth proportional to the differences, not the data size.

### What does the FLP result say?
In a fully asynchronous system with even one crash-faulty process, no deterministic consensus protocol can guarantee termination. Real systems escape with timeouts (partial synchrony) or randomization.

## Reliability and operations
> Keeping large systems up, and recovering fast.

### SLI, SLO, SLA?
**SLI**: a measured indicator (e.g. % of requests under 300 ms). **SLO**: the internal target for it (99.9%). **SLA**: the contract with customers, with penalties, set looser than the SLO.

### What is an error budget used for?
1 − SLO is the unreliability you may spend. While budget remains, ship fast; when it's burned, freeze risky launches and invest in reliability. It turns reliability debates into data.

### How do retries cause outages, and how do you make them safe?
Retries multiply load on an already struggling service (retry storms). Use exponential backoff with jitter, retry budgets or caps, idempotent operations, and only retry errors that are actually transient.

### What is a circuit breaker?
A client-side switch that stops calling a failing dependency after an error threshold, fails fast for a cool-down, then lets a trial request through. It protects both the caller's resources and the struggling service.

### What is backpressure?
A way for a slow consumer to signal producers to slow down (bounded queues, flow-control windows, rejecting work). Without it, queues grow until latency explodes or memory runs out.

### What is load shedding?
Deliberately rejecting some requests (lowest priority first) when near capacity, so the requests you do accept still meet their SLO. Better a fast 503 for some than timeouts for everyone.

### What is a cascading failure?
One component's failure overloads its neighbors, which fail and spread the load further, e.g. a cache outage sending all traffic to the database. Defenses: timeouts, circuit breakers, load shedding, bulkheads, capacity headroom.

### What are bulkheads?
Isolating resources (thread pools, connection pools, cells, shards) per dependency or tenant so one bad actor can only sink its own compartment.

### What is cell-based architecture?
Splitting a service into independent, identical cells, each serving a slice of customers with its own stack. Blast radius of a bad deploy or poison request is one cell; scaling means adding cells.

### Canary vs. blue-green deployment?
**Canary**: send a small slice of traffic to the new version, compare metrics, then ramp. **Blue-green**: run the new version alongside, switch all traffic at once, keep the old one for instant rollback.

### Metrics, logs and traces: what is each for?
**Metrics**: cheap aggregates for dashboards and alerts. **Logs**: detailed events for debugging one request. **Traces**: the path and timing of one request across services. Good observability links all three.

### Why alert on symptoms rather than causes?
Users feel symptoms (errors, latency); causes (CPU high) are often harmless. Page on SLO burn rate; keep cause-based signals for dashboards and diagnosis to avoid alert fatigue.

### What makes a good postmortem?
Blameless, timeline-based, focused on contributing factors and why defenses failed, with owned, prioritized action items. The goal is learning that changes the system, not a culprit.

## Databases and storage
> How data is stored, indexed and kept correct.

### B-tree vs. LSM-tree?
**B-tree** updates pages in place; fast reads, moderate write amplification. **LSM-tree** appends to a memtable and flushes sorted files merged by compaction; very fast writes, reads may check several files (helped by Bloom filters).

### What does a write-ahead log guarantee?
Changes are appended to a durable log before data pages are modified, so after a crash the database replays the log to a consistent state. It also feeds replication and change data capture.

### What are the ACID isolation levels and their anomalies?
Read uncommitted (dirty reads), read committed (non-repeatable reads), repeatable read / snapshot isolation (write skew), serializable (none). Most databases default to read committed or snapshot.

### What is write skew?
Two transactions read the same data, each makes a decision, and each writes a different row, breaking an invariant (e.g. two doctors both go off call). Snapshot isolation allows it; fix with serializable isolation or locking the rows read.

### How does MVCC work?
Each write creates a new row version tagged with a transaction id; readers see the snapshot valid at their start, so reads never block writes. Old versions are garbage-collected later (vacuum).

### What is an index and what does it cost?
A separate structure (B-tree, hash, inverted) that finds rows without scanning. It speeds reads but slows every write and uses storage; index the columns your hot queries filter and sort on.

### When do you denormalize?
When read paths need data from many tables and joins are too slow at scale. You trade storage and more complex writes (keeping copies in sync) for fast reads.

### What is change data capture?
Streaming a database's committed changes from its log (e.g. Debezium on the binlog) to other systems: caches, search indexes, warehouses. It avoids dual writes and keeps derived data in order.

### How do you do a zero-downtime schema migration?
Expand and contract: add the new column or table, dual-write, backfill, switch reads, then remove the old path. Every step stays backward compatible with the running code.

### Row store vs. column store?
**Row stores** keep a record together; good for OLTP lookups and updates. **Column stores** keep each column together; compress well and scan only needed columns, good for analytics (OLAP).

### What is a Bloom filter?
A compact bit array with k hash functions that answers "definitely not present" or "maybe present". No false negatives, tunable false positives. Used to skip disk reads in LSM trees and caches.

### How does consistent hashing reduce rebalancing?
Nodes and keys hash onto a ring; each key goes to the next node clockwise. Adding or removing a node moves only about 1/N of keys. Virtual nodes smooth out the load.

## Design principles
> The principles behind maintainable code and systems.

### State the Single Responsibility Principle.
A module should have one reason to change, i.e. answer to one actor. It keeps changes local and code easier to test and understand.

### What is the Open/Closed Principle?
Software should be open for extension but closed for modification: add behavior with new code (plugins, strategies, polymorphism) rather than editing stable, tested code.

### Explain the Liskov Substitution Principle.
Subtypes must be usable wherever the base type is expected without surprising the caller: no stronger preconditions, no weaker postconditions. A square that breaks a rectangle's setters violates it.

### What is the Interface Segregation Principle?
Clients shouldn't depend on methods they don't use. Prefer several small, role-specific interfaces over one fat one.

### What is the Dependency Inversion Principle?
High-level policy shouldn't depend on low-level details; both depend on abstractions. It makes infrastructure swappable and logic testable with fakes.

### Coupling vs. cohesion?
**Cohesion**: how closely the parts of one module belong together (want high). **Coupling**: how much modules depend on each other's internals (want low). Together they decide how far a change ripples.

### What is the principle of least knowledge (Law of Demeter)?
A unit should talk only to its immediate collaborators, not reach through chains like a.getB().getC().do(). It limits coupling to internal structure.

### Composition over inheritance: why?
Inheritance couples a child to its parent's implementation and fixes behavior at compile time. Composition assembles behavior from small parts that can be swapped at runtime and tested alone.

### What does YAGNI warn against?
Building for speculative future needs. Each unneeded abstraction costs design, code and maintenance now and often guesses wrong. Build for today's requirements, keep code easy to change.

### What is Conway's Law and how do you use it?
Systems mirror the communication structure of the organizations that build them. Use it deliberately (the inverse Conway maneuver): shape teams around the architecture you want.

### Why "make illegal states unrepresentable"?
Encode invariants in types and data models so invalid combinations can't be constructed. Whole classes of bugs then become compile errors instead of runtime checks.

### What does "design for failure" mean in practice?
Assume every dependency will be slow or down. Set timeouts, retries with backoff, fallbacks and graceful degradation, and test them (chaos experiments) instead of hoping.

### What is idempotency and why does it matter for APIs?
An idempotent operation has the same effect whether applied once or many times. With retries and at-least-once delivery everywhere, idempotency keys on writes prevent double charges and duplicate records.

### What is the end-to-end argument?
Correctness guarantees (integrity, exactly-once, security) belong at the endpoints, because lower layers can't fully provide them. Lower layers may add the same checks only as a performance optimization.

### Two-way door vs. one-way door decisions?
**Two-way doors** are reversible: decide quickly, delegate. **One-way doors** are costly to undo (data models, public APIs, vendor lock-in): slow down, write it up, get review.

## Algorithms and data structures
> The patterns behind most coding rounds.

### When does a hash map beat a balanced tree?
For exact-key lookup, insert and delete in O(1) average. Use a tree (O(log n)) when you need ordering: range queries, min/max, sorted iteration, or predictable worst-case time.

### What is the two-pointer technique good for?
Sorted arrays and linked lists: pair sums, removing duplicates, merging, palindromes, and cycle detection (fast and slow pointers). It turns many O(n²) scans into O(n).

### When do you use a sliding window?
For contiguous subarrays or substrings that satisfy a condition (longest substring without repeats, max sum of size k). Grow the right edge, shrink the left while the window is invalid: O(n).

### BFS vs. DFS?
**BFS** explores level by level with a queue; it finds shortest paths in unweighted graphs. **DFS** goes deep with recursion or a stack; good for connectivity, cycle detection, topological order and backtracking.

### When do you use Dijkstra's algorithm, and when not?
Shortest paths from one source with non-negative edge weights, O((V+E) log V) with a heap. With negative edges use Bellman-Ford; for all pairs, Floyd-Warshall; with a good heuristic, A*.

### What is a topological sort for?
Ordering nodes of a DAG so every edge goes forward: build systems, course prerequisites, task scheduling. Kahn's algorithm (in-degree queue) also detects cycles.

### How do you recognize a dynamic programming problem?
Optimal substructure plus overlapping subproblems: the answer composes from answers to smaller versions that repeat. Define the state, the recurrence and base cases; memoize top-down or tabulate bottom-up.

### What does a heap give you?
O(1) access to the min or max and O(log n) insert and pop. Classic uses: top-k, merging k sorted lists, scheduling, Dijkstra, and running medians with two heaps.

### When is a trie the right structure?
For prefix queries over many strings: autocomplete, spell check, IP routing (longest prefix match). Lookups cost O(length of key), independent of how many keys are stored.

### What is union-find used for?
Tracking connected components under merges in near-constant time (path compression plus union by rank): Kruskal's MST, network connectivity, grouping equivalent items.

### What is binary search on the answer?
When feasibility is monotonic in a parameter (capacity, speed, time), binary search that parameter and test feasibility each step: O(log range × check).

### How do you find the top-k items in a stream?
Keep a min-heap of size k: O(n log k). For heavy hitters in huge streams with bounded memory, use Count-Min Sketch plus a heap, or Misra-Gries.

### How does HyperLogLog estimate cardinality?
It hashes items and tracks the maximum run of leading zeros per register; more distinct items produce longer runs. With ~12 KB it estimates billions of distinct values within ~1-2% error.

## Scalable system designs
> One-line answers to the classic design prompts.

### URL shortener: how do you generate short codes?
Base62-encode a unique 64-bit id (from a ticket server or Snowflake-style generator), or hash the URL and resolve collisions. Seven Base62 characters give ~3.5 trillion codes. Cache hot redirects; use 301 vs. 302 deliberately (302 if you need click analytics).

### Rate limiter: which algorithm and where?
Token bucket for bursts with an average rate; sliding window counter for accuracy with little memory. Keep counters in Redis with atomic Lua scripts, enforce at the API gateway, return 429 with retry headers.

### Unique ID generator: how does Snowflake work?
A 64-bit id = timestamp (41 bits) + datacenter and machine ids (10 bits) + per-millisecond sequence (12 bits). Ids are roughly time-sorted and generated locally without coordination; watch clock skew.

### News feed: fan-out on write or on read?
**Fan-out on write** pushes posts into followers' cached feeds: fast reads, expensive for celebrities. **Fan-out on read** builds the feed at request time. Most use a hybrid: push for normal users, pull for celebrities.

### Chat system: how do messages reach online users?
Clients hold persistent WebSocket connections to chat servers; a presence service maps users to servers; messages go through a queue to the recipient's server. Store history in a wide-column store keyed by channel and time-ordered message id.

### Search autocomplete: what is the core data structure?
A trie of prefixes with the top-k suggestions cached at each node, rebuilt offline from query logs and served from memory or a cache. Shard by prefix; filter unsafe suggestions.

### Web crawler: what keeps it polite and efficient?
A URL frontier with per-host queues and delays, robots.txt respect, DNS caching, content dedup by hash, URL dedup with a Bloom filter, and priority by page importance and freshness.

### Notification system: what are the key pieces?
An API that validates and enqueues, per-channel queues and workers (push, SMS, email), third-party providers, user preferences and rate limits, retries with dedup, and delivery tracking.

### Video platform: how does upload and playback work?
Upload to object storage via pre-signed URLs, transcode in a DAG of parallel jobs into many bitrates and formats, then serve through CDNs with adaptive bitrate streaming (HLS or DASH).

### Proximity service: how do you find nearby places fast?
Index locations with geohash, quadtree or S2 cells; query the user's cell and its neighbors, then filter by distance. Business data is read-heavy and changes rarely, so replicate and cache it.

### Payment system: how do you avoid double charges?
Idempotency keys on every payment request, a ledger with double-entry bookkeeping, exactly-once processing through idempotent consumers, and daily reconciliation against the payment provider.

### Distributed message queue: how does it scale?
Topics split into partitions, each an append-only log replicated across brokers; consumers in a group split partitions; ordering holds within a partition; offsets let consumers replay.

### Real-time leaderboard: what data structure?
A Redis sorted set: ZINCRBY to update a score, ZREVRANGE for the top N, ZREVRANK for a user's rank, all O(log n). Shard by score range or use approximate ranks at very large scale.

### Hotel reservation: how do you prevent overbooking?
Keep per-room-type, per-date inventory rows and update them in a transaction with a check, using optimistic locking (version column) or a database constraint. Use idempotency keys for retries.

## Machine learning and AI systems
> For AI-adjacent and ML-platform interviews.

### What are the stages of an ML system in production?
Data collection and labeling, feature pipelines, training, evaluation, deployment, monitoring for drift and quality, and a feedback loop that retrains. Most engineering effort sits in data and monitoring.

### What is training-serving skew?
When features are computed differently at training and serving time, the model sees different inputs in production. Fix with a shared feature store or shared feature code and logging of served features.

### Online vs. batch inference?
**Batch** precomputes predictions on a schedule; cheap, but stale. **Online** computes per request; fresh, but needs low-latency serving and autoscaling. Many systems mix both.

### What is retrieval-augmented generation (RAG)?
Retrieve relevant documents (often by vector similarity) and add them to the model's prompt, so answers are grounded in current or private data without retraining. Quality depends mostly on chunking and retrieval.

### How does approximate nearest neighbor search work (e.g. HNSW)?
HNSW builds a layered graph of vectors; search starts at the sparse top layer and greedily descends to dense layers. It trades a little recall for orders-of-magnitude speedups over brute force.

### How do you make LLM serving efficient?
Continuous batching, KV-cache reuse (prefix caching), quantization, speculative decoding, tensor or pipeline parallelism across GPUs, and routing short requests away from long ones.

### How do you evaluate an LLM-powered feature?
Build an eval set from real tasks, define pass criteria, score with exact checks, human review or LLM-as-judge (calibrated against humans), and track regressions on every prompt or model change.

### What is model or data drift?
**Data drift**: the input distribution changes. **Concept drift**: the relationship between inputs and the right answer changes. Monitor input statistics and outcome metrics, and retrain or alert.

### Precision vs. recall?
**Precision**: of what you flagged, how much was right. **Recall**: of what was really there, how much you caught. Choose by the cost of false positives vs. false negatives.

### What is an embedding?
A dense vector representation where similar items sit close together, learned from data. Used for search, recommendations, clustering and as model inputs.

## Networking and the web
> What happens between the client and your servers.

### What happens when you type a URL and hit enter?
DNS resolves the name, the client opens a TCP (or QUIC) connection and a TLS handshake, sends the HTTP request through CDNs and load balancers to servers, gets the response, then parses, fetches subresources and renders.

### TCP vs. UDP?
**TCP**: connection-oriented, reliable, ordered, congestion-controlled. **UDP**: connectionless datagrams with no guarantees; low overhead, used for DNS, real-time media and as the base for QUIC.

### What does HTTP/2 improve, and HTTP/3?
**HTTP/2** multiplexes many streams over one TCP connection with header compression, but TCP loss stalls all streams. **HTTP/3** runs over QUIC (UDP) with per-stream loss recovery and faster handshakes.

### WebSockets vs. long polling vs. server-sent events?
**WebSockets**: full-duplex persistent connection, for chat and games. **SSE**: one-way server push over HTTP, simple for feeds and progress. **Long polling**: fallback that holds requests open.

### What does TLS give you?
Confidentiality (encryption), integrity (tamper detection) and server authentication via certificates. TLS 1.3 cuts the handshake to one round trip (zero with resumption).

### How does DNS-based load balancing work, and its limits?
DNS returns different IPs by region, weight or health (GeoDNS). Limits: caching and TTLs delay failover, and the client's resolver location may not match the user's.

### REST vs. gRPC vs. GraphQL?
**REST**: resource-oriented HTTP, universal and cacheable. **gRPC**: binary protobuf over HTTP/2, fast and typed, great between services. **GraphQL**: clients ask for exactly the fields they need, useful for varied front ends.

### What is anycast?
Several servers announce the same IP address; routing sends each user to the nearest one. CDNs and DNS providers use it for low latency and DDoS absorption.

## Security
> The questions that come up in every design review.

### Authentication vs. authorization?
**Authentication** proves who you are (passwords, passkeys, tokens). **Authorization** decides what you may do (roles, policies, ACLs). Check authorization on every request at the server.

### How do OAuth 2.0 and OpenID Connect differ?
**OAuth 2.0** delegates access: an app gets a scoped access token to call an API on the user's behalf. **OIDC** adds identity on top: an ID token that says who the user is.

### Session cookies vs. JWTs?
**Server sessions** are easy to revoke but need a shared store. **JWTs** are self-contained and stateless but hard to revoke before expiry. Use short-lived JWTs with refresh tokens, or sessions when revocation matters.

### How should passwords be stored?
Never in plain text or with a fast hash. Use a slow, salted password hash (Argon2id, bcrypt or scrypt) with tuned cost, and prefer passkeys or MFA where you can.

### What is defense in depth?
Layering independent controls (network rules, authentication, authorization, input validation, encryption, monitoring) so that one failure doesn't expose the system.

### What is the principle of least privilege?
Give every user, service and credential only the permissions it needs, for only as long as it needs them. It limits the blast radius of a compromise.

### How do you protect secrets in a distributed system?
Keep them in a secrets manager or KMS, never in code or images; inject at runtime, rotate regularly, scope per service, and audit access. Encrypt data with envelope encryption.

### What are the most common web vulnerabilities to design against?
Injection (SQL, command), broken access control, XSS, CSRF, SSRF, insecure deserialization and misconfiguration. Use parameterized queries, output encoding, CSRF tokens, egress allowlists and secure defaults.

## Technical leadership
> Behavioral questions for staff, principal and distinguished roles. Answers are frameworks, not scripts.

### How do you structure a behavioral answer?
STAR: Situation, Task, Action, Result, plus what you learned. Spend most of the time on your own actions and decisions, quantify the result, and pick stories at the scope of the level you are interviewing for.

### Tell me about a time you influenced without authority.
Show how you built the case with data and prototypes, found the people whose problem it solved, wrote it down for broad review, adjusted to feedback, and made adopting it easy (paved path, migration help).

### Tell me about a technical decision you got wrong.
Pick a real one with consequences. Explain your reasoning at the time, the signal that showed it was wrong, how quickly you reversed, what you did for the people affected, and the mechanism you changed so it doesn't recur.

### How do you handle a strong disagreement with another senior engineer?
Separate the goal from the solution, agree on criteria first, compare options against them with data, time-box the debate, escalate cleanly if needed, then disagree and commit and support the decision fully.

### How do you decide what to work on as a principal engineer?
Look for problems with the most leverage across teams: recurring incidents, scaling cliffs, slow developer workflows, strategic bets. Balance them against the business strategy and choose what only you are positioned to unblock.

### How do you write a good technical strategy?
Diagnose the current state honestly, state guiding policies (the trade-offs you are choosing), and list coherent actions. Ground it in business goals, name what you're not doing, and revisit it as facts change.

### How do you grow other engineers?
Delegate real problems with support, review designs with questions rather than answers, give specific feedback, sponsor people for visible work, and write down your reasoning so it scales beyond your meetings.

### How do you handle technical debt?
Make it visible and quantified (incidents, velocity, cost), tie paydown to business outcomes, fix it incrementally alongside feature work, and stop adding new debt with guardrails and paved paths.

### How do you lead a large migration?
Define the end state and success metrics, build tooling so teams migrate cheaply, go in waves starting with friendly teams, track progress publicly, handle the long tail with automation or ownership, and turn off the old system.

### Describe how you run an architecture review.
Share a written design ahead of time, focus on requirements, risks and alternatives considered, probe failure modes and operability, record decisions and their rationale, and follow up on action items.
