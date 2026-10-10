# Design Principles

## Correctness and Data

### End-to-end argument
> A function that can only be completely and correctly implemented with knowledge held at the endpoints must be implemented at the endpoints; lower layers can only optimize it.

**Why it holds.** Saltzer, Reed and Clark (1984) observed that a reliable file transfer cannot be guaranteed by a reliable network alone: disks corrupt, buffers flip bits, processes crash after acknowledging. Only the endpoint that knows what "correct" means can verify it. Every intermediate guarantee is partial, so the endpoint check is required anyway.

Lower-layer mechanisms are still worth building when they make the common case cheaper. They are performance enhancements, not correctness guarantees.

**In practice.** A payment system relies on TCP, TLS and a durable queue, yet still carries an end-to-end idempotency key and reconciles ledger totals against the processor's settlement file daily. The queue's "exactly-once" claim reduces duplicates; the reconciliation is what proves money is right.

The same logic applies to checksums on objects stored across multiple tiers, and to user-visible confirmation that an order was persisted, not merely accepted by a load balancer.

**Anti-pattern.** Trusting a middleware guarantee as the whole story: "Kafka is exactly-once, so we don't need dedup." Or the inverse: pushing application semantics (business validation, retries with domain meaning) into the network or service mesh, where they cannot be correct and become impossible to change.

**Review question.** Which property here must be true for the user, and which component is the only one that can actually verify it? What lower-layer guarantee are we treating as if it were end-to-end?

### Idempotency by default
> Every operation that can be retried should produce the same outcome whether it executes once or many times.

**Why it holds.** In a distributed system a caller that times out cannot know whether the request failed, succeeded, or is still running. Retries are therefore unavoidable, and at-least-once delivery is the only practical guarantee most transports give. Without idempotency, every retry is a gamble on duplication.

Idempotency converts the unknowable "did it happen?" into a safe "do it again."

**In practice.** Stripe's API accepts an `Idempotency-Key` header; the server stores the key with the response and replays it for duplicates within a window. Internally, design writes as conditional puts ("set state to SHIPPED if version = 7"), upserts keyed on natural identifiers, or operations recorded in a dedup table within the same transaction as the effect.

Consumers of queues should key on a message or business identifier, not assume the broker deduplicates.

**Anti-pattern.** `POST /charge` that increments a counter or creates a new row per call. Retry logic added later in a client library, silently double-charging during an incident. Dedup tables held in a separate store from the effect, so a crash between them reintroduces the duplicate.

**Review question.** If this request is delivered twice, ten seconds apart, what happens? Where is the dedup record stored, and is it written atomically with the side effect?

### One system of record per fact
> Each fact has exactly one authoritative owner; every other copy is a derived, explicitly stale view.

**Why it holds.** When two systems both accept writes for the same fact, they will diverge, and there is no principled way to decide which is right. Reconciliation logic grows without bound and encodes guesses.

A single owner gives a clear answer to "what is true?", a single place to enforce invariants, and a defined direction of data flow.

**In practice.** The billing service owns the customer's plan; search indexes, the data warehouse and caches consume its change stream and are labeled as projections with known lag. Other teams that want to change the plan call billing's API rather than writing their own copy.

When migrating ownership, move it explicitly: dual-read, then cut writes over, then retire the old owner. Do not run a long period with two writable masters.

**Anti-pattern.** CRM and billing both editable for customer address, synced by a nightly job with "last write wins." Caches that become de facto authoritative because the origin was deleted or is too slow to query. Spreadsheets as the true source for configuration that a service also writes.

**Review question.** For each entity in this design, which system is authoritative? If two copies disagree, which one wins, and does everyone know that?

### Make illegal states unrepresentable
> Shape types, schemas and APIs so that invalid combinations cannot be constructed, rather than validating them after the fact.

**Why it holds.** Validation is a check every code path must remember to perform; a type or constraint is enforced once, everywhere, by the compiler or the database. The number of states a structure can represent is the number of states the code must handle. Shrinking that space removes whole classes of bugs instead of individual ones.

**In practice.** Replace `{status: string, shippedAt?: Date, trackingId?: string}` with a sum type where `Shipped` carries non-optional `shippedAt` and `trackingId`. In the database, use `NOT NULL`, foreign keys, check constraints and exclusion constraints rather than application-level assertions.

At API boundaries, parse untrusted input into precise domain types once ("parse, don't validate") so interior code never sees raw strings. Model money as integer minor units with a currency, never as a float.

**Anti-pattern.** Boolean flags whose combinations are partly meaningless (`isActive`, `isDeleted`, `isSuspended`). Nullable columns used to encode lifecycle stages. Defensive checks scattered across services because no layer trusts the shape it receives.

**Review question.** What states can this data model represent that the business says are impossible? Which invariants are enforced by structure, and which only by convention?

### Expand–contract schema evolution
> Change shared schemas in backward-compatible steps: add the new form, migrate readers and writers, then remove the old form.

**Why it holds.** In any system with more than one deployable unit, old and new code run simultaneously during rollout and rollback. A breaking schema change forces a lockstep deploy, which is impossible to do atomically across fleets, clients, and stored data. Expand–contract (also called parallel change) keeps every intermediate state compatible with its neighbors.

**In practice.** Renaming a column: (1) add the new column; (2) deploy code that writes both and reads the old; (3) backfill; (4) switch reads to the new column; (5) stop writing the old; (6) drop it after a retention window. Each step is independently deployable and reversible.

For events and RPC, apply the same discipline with Protobuf or Avro: add optional fields, never reuse field numbers, and enforce compatibility in a schema registry in CI. Mobile clients extend the contract phase by months.

**Anti-pattern.** A migration that renames a column in the same release that changes the code, followed by an outage when rollback is needed. Deleting an enum value that still exists in queued messages. "Big bang" data migrations with no dual-write period.

**Review question.** During rollout, what does old code do with new data, and new code with old data? At which step does this become irreversible, and how long do we wait before taking it?

### Choose the consistency model explicitly
> Decide, per operation, what consistency the business requires, and make that choice visible rather than inheriting a store's default.

**Why it holds.** Consistency is a spectrum (linearizable, sequential, causal, read-your-writes, eventual), and each step weaker buys latency and availability, per CAP and PACELC. Different operations in the same product legitimately need different points: a balance withdrawal needs linearizability; a like count does not.

Defaults are rarely aligned with intent, and anomalies under weak consistency only appear under concurrency and failure, when they are hardest to diagnose.

**In practice.** An inventory system uses a strongly consistent store for decrementing stock, but serves the product page's "in stock" badge from an eventually consistent cache with a documented staleness bound. A social feed guarantees read-your-writes via session stickiness so a user sees their own post, without global ordering.

Write the chosen model in the API contract, and test it with fault injection or a tool such as Jepsen when correctness matters.

**Anti-pattern.** Using a replica read for a check-then-act sequence ("is username free?"). Assuming a database's "serializable" setting means the same as the textbook definition without checking. Uniformly strong consistency everywhere, paying cross-region latency for data no one needs fresh.

**Review question.** Which operations break an invariant if they observe stale data? What anomaly would a user see under replication lag, and is that acceptable?

### No dual writes
> Never update two independent systems in sequence and hope both succeed; make one write authoritative and derive the other from it.

**Why it holds.** Writing to a database and then publishing to a queue (or calling another service) has a crash window between the two. No ordering of the two calls fixes it: either the event is lost or a phantom event describes a write that never committed. Distributed transactions (2PC) close the gap but couple availability and are poorly supported across heterogeneous systems.

**In practice.** Use the transactional outbox: write the business row and an outbox row in one local transaction; a relay publishes outbox rows and marks them sent, with consumers idempotent to tolerate re-delivery. Alternatively, use change data capture (Debezium reading the database log) so the log itself is the single write.

Event sourcing takes this further: the event log is the system of record, and all stores are projections.

**Anti-pattern.** `db.save(order); kafka.send(orderCreated);` in a request handler. Cache invalidation performed as a separate call after commit, leaving stale entries after crashes. Sagas with no persisted state, so a process restart loses track of which compensations are owed.

**Review question.** Where does this flow write to more than one system? What happens if the process dies between those writes, and how would we detect it?

### Do not trust wall clocks for ordering
> Use logical ordering, versions or fencing tokens to sequence events and enforce exclusivity, not timestamps from independent machines.

**Why it holds.** Physical clocks drift, jump backwards on NTP correction, and pause during GC or VM migration. A process holding a lease can be paused past its expiry, resume, and act as though it still owns the lease. Timestamps from different hosts are therefore not comparable at the precision most designs assume.

Google Spanner works with real time only because TrueTime exposes explicit uncertainty bounds and waits them out.

**In practice.** Distributed locks issue monotonically increasing fencing tokens; the storage layer rejects writes carrying a token lower than one it has seen. Conflict resolution uses version vectors or hybrid logical clocks rather than "last write wins" on wall time.

Leader election uses a consensus system (etcd, ZooKeeper) and treats leadership as an epoch number that every downstream write carries.

**Anti-pattern.** "Last write wins" based on client timestamps, letting a device with a skewed clock overwrite newer data. Redis-based locks used for correctness without fencing. TTLs and lease logic that assume a paused process notices its lease expired.

**Review question.** If this process paused for 30 seconds at the worst possible line, what would it overwrite when it resumed? What enforces ordering: a clock, or a token the storage layer checks?

## Failure and Resilience

### Static stability
> A system should keep doing what it was doing when a dependency fails, without needing to make any new decisions or acquire new resources.

**Why it holds.** Recovery actions (launching instances, refreshing config, re-resolving endpoints) depend on control planes that are most likely to be impaired during exactly the event that requires them. A design that must react to survive has turned a dependency outage into its own outage. Pre-provisioned capacity and cached state remove that coupling.

**In practice.** AWS describes this pattern for multi-AZ services: run enough capacity in each AZ to absorb the loss of one without launching anything. Data plane hosts cache the last known good configuration and keep serving if the config service is unavailable.

EC2 instances keep running when the EC2 control plane is down; DNS resolvers serve stale records rather than failing. Credentials are fetched with long enough validity to outlast a dependency outage.

**Anti-pattern.** Auto-scaling as the only answer to AZ loss, so failover depends on the control plane and on capacity being available in the remaining zones. Services that refuse to start, or stop serving, when a config or feature-flag service is unreachable. Health checks that call dependencies, so a dependency blip removes every host.

**Review question.** If every control plane this depends on disappeared right now, what would keep working, and for how long? Which recovery steps require calling something that may also be down?

### Blast radius and cells
> Partition the system into independent cells so that any single failure, bad deploy or poison request affects a bounded fraction of customers.

**Why it holds.** Shared components make every failure global. Scaling a single shared stack also increases the size of any failure. Cells cap the impact of failures you have not predicted: correlated bugs, bad config, overload, and runaway tenants. They also bound the size of what you must test, since each cell has a known maximum scale.

**In practice.** AWS services are built as many cells, each a full copy of the stack serving a subset of customers, with a thin routing layer mapping customers to cells. Deployments go one cell at a time. Slack and DoorDash have published cellular migrations for the same reasons.

Size cells so the largest tested cell is the largest that ever runs; add cells to scale out rather than growing them. Keep the routing layer extremely simple, since it is the one shared component.

**Anti-pattern.** A global configuration push that reaches every region in minutes. One database cluster serving all tenants, so a single tenant's query storm is everyone's outage. "Regional" deployments that still share a global control plane or global cache on the request path.

**Review question.** What is the largest fraction of customers a single bad change or poison input can affect? What components remain shared across cells, and how simple are they?

### Shuffle sharding
> Assign each customer a random combination of resources so that the failure caused by one customer rarely overlaps fully with another customer's resources.

**Why it holds.** With plain sharding, a poison or abusive client takes down its shard and every co-tenant. With shuffle sharding, each client gets k of n workers. The chance that two clients share all k workers is 1 / C(n, k), which falls combinatorially. With 8 workers and shards of 2 there are 28 combinations, and most other tenants still have a healthy worker when one combination dies.

Combined with client retries across its assigned workers, nearly all other tenants see no impact.

**In practice.** Amazon Route 53 assigns each hosted zone four name servers from a large pool; a DDoS against one customer's zone saturates only those four, and the probability another customer shares all four is tiny. The same technique applies to queue partitions, worker pools and cell assignment.

It requires that clients can retry across their assigned shard members and that capacity per member is isolated.

**Anti-pattern.** Hash-modulo assignment to a single shard, so noisy neighbors always share fate with a fixed set of others. Shuffle sharding without per-tenant throttling, so one tenant can still saturate shared upstream dependencies.

**Review question.** If one tenant becomes a poison input, which other tenants share every resource with it? Do clients actually fail over across their shard members?

### Constant work
> Design hot paths to do the same amount of work regardless of load or system state, so behavior under stress matches behavior in normal operation.

**Why it holds.** Systems that do more work when things change (deltas, event-driven fan-out, reactive reconfiguration) experience their peak load during incidents, which is when they are least tested and most fragile. A system that does constant work has no surge mode: its capacity is proven every minute.

**In practice.** AWS's Route 53 health checkers push the full state of every health check to aggregators every few seconds, whether or not anything changed; a mass failure does not create a storm of updates. Similarly, a config distribution system can publish a complete snapshot on a fixed interval rather than a stream of diffs.

The trade-off is cost: you pay for peak work all the time. That cost buys predictability, and is often smaller than it looks for small, critical datasets.

**Anti-pattern.** Change notification systems that fan out N messages when N things change, overwhelming consumers during a regional failure. Caches whose miss path calls a database that is only sized for the hit-rate seen in steady state. Batch jobs that only run after failures.

**Review question.** What does this component do when everything changes at once? Is that load path exercised continuously, or only during incidents?

### Avoid bimodal behavior and risky fallback
> Avoid designs that have a rarely used operating mode; a fallback that is not exercised constantly will fail when you need it.

**Why it holds.** Fallback paths are, by definition, rarely run, so they accumulate latent bugs, untested capacity limits and stale assumptions. When triggered, they often shift load somewhere that was never sized for it. Amazon's Builders' Library documents fallbacks causing larger outages than the original fault.

Bimodal systems also make capacity planning lie: you measure the fast mode and depend on the slow one.

**In practice.** Prefer making the primary path more reliable over adding a fallback. If a fallback is unavoidable, run it continuously: send a fraction of traffic down it, or make it the same code path (for example, always read from the local cache and refresh asynchronously, rather than "call remote, fall back to cache").

Caches deserve particular suspicion: a high hit rate hides the true load the origin must take on a cold start.

**Anti-pattern.** "If the primary database is unreachable, query the analytics warehouse." Failing over to another region that has never taken full production load. Retry-on-failure that switches to a more expensive algorithm. Cache-aside designs where a flush stampedes the origin.

**Review question.** What modes does this system operate in, and which have we run at full production load this week? If the fallback were triggered by every client simultaneously, what would it hit?

### Timeouts, retries, backoff and jitter, with budgets
> Every remote call needs a deliberate timeout, a bounded retry policy with exponential backoff and jitter, and a system-wide limit on retry amplification.

**Why it holds.** No timeout means a slow dependency holds resources indefinitely and spreads its slowness upstream. Unbounded retries multiply load precisely when a dependency is overloaded: three layers each retrying three times is 27x amplification at the bottom. Synchronized retries create thundering herds; jitter spreads them.

**In practice.** Set timeouts from the dependency's measured latency distribution (for example, slightly above p99.9), and propagate deadlines through the call graph so downstream work stops when the caller has given up (gRPC deadlines do this).

Retry only idempotent operations, only at one layer, with full jitter, and cap retries with a token-bucket retry budget (for example, retries may not exceed 10% of requests). Use circuit breakers to stop calling a dependency that is clearly failing.

**Anti-pattern.** Default library timeouts of 30 seconds or infinity. Retries at the client, gateway, service and database driver simultaneously. Fixed-interval retries that turn a brief blip into a synchronized wave every second.

**Review question.** What is the worst-case amplification factor if the deepest dependency starts failing? Does work stop downstream when the original caller times out?

### Load shedding and graceful degradation
> When demand exceeds capacity, reject excess work early and cheaply, and degrade nonessential features before essential ones.

**Why it holds.** An overloaded server that accepts everything slows down for everyone; once latency exceeds client timeouts, it does useful work for no one (goodput collapses while throughput stays high). Rejecting a portion of requests fast preserves useful throughput for the rest. Not all requests are equally valuable, so prioritizing them preserves the most value per unit of capacity.

**In practice.** Admit requests based on concurrency or queue time, not CPU alone; drop requests whose deadline has already passed. Tag traffic by criticality (Google's SRE book describes CRITICAL_PLUS through SHEDDABLE) and shed lowest tiers first.

Product-level degradation: an e-commerce page drops personalized recommendations and reviews before checkout. Netflix serves a non-personalized default catalog row when its recommendation service is unhealthy.

**Anti-pattern.** Unbounded request queues that turn overload into minutes of latency. Rejecting requests after doing expensive work such as authentication and deserialization. Treating health-check traffic and batch backfills with the same priority as user checkouts.

**Review question.** At 2x expected peak, which requests do we drop first, and how cheaply? Can the system return to normal without operator intervention once load subsides?

### Isolate dependencies with bulkheads
> Give each dependency its own bounded pool of resources so that one slow or failing dependency cannot exhaust capacity needed by others.

**Why it holds.** Shared thread pools, connection pools and memory are the channel through which partial failure becomes total failure. If one downstream service slows to a crawl, every request touching it holds a thread; soon there are no threads for requests that never touch it. Bulkheads turn a capacity question into a containment boundary.

**In practice.** Separate connection and worker pools per downstream dependency, with explicit concurrency limits (Hystrix popularized this; resilience4j and Envoy's circuit-breaking thresholds provide it today). Separate fleets for interactive and batch traffic, and for internal and external tenants.

Mark dependencies as hard (request fails without it) or soft (request degrades without it), and ensure soft dependencies have tight timeouts and cannot consume shared capacity.

**Anti-pattern.** A single global HTTP client pool shared by every outbound call. Admin and reporting endpoints running on the same instances as customer traffic. Soft dependencies called synchronously on the critical path with the same timeout as hard ones.

**Review question.** If dependency X began responding in 60 seconds instead of 60 milliseconds, which unrelated features would also stop working? Which dependencies are hard, and is that list as short as possible?

### Separate control plane from data plane
> Keep the components that configure the system apart from the components that serve traffic, so that the data plane keeps working when the control plane does not.

**Why it holds.** Control planes are complex, change frequently, and have low request volume with high per-request logic; data planes are simple, change rarely, and have high volume. Their reliability needs differ by orders of magnitude. Coupling them makes the data plane's availability the product of both.

Separation also lets each scale and deploy on its own cadence.

**In practice.** In AWS, creating a load balancer is a control-plane call; forwarding packets through it is the data plane, and the latter keeps running when the former is impaired. Kubernetes nodes keep running pods if the API server is down. Envoy proxies (data plane) receive config from a control plane via xDS and continue serving their last configuration if it is unreachable.

Data planes should pull, cache and validate config, and reject a bad push rather than apply it.

**Anti-pattern.** A request path that calls the config service, the auth control plane or a service registry synchronously on every request. Control-plane deploys that restart data-plane processes. A single global control plane pushing to all regions at once.

**Review question.** Which calls on the request path go to a control-plane component? If the control plane were down for an hour, what would degrade, and when?

## Scale and Performance

### Bound everything and apply backpressure
> Every queue, buffer, pool, cache, batch and retry loop needs an explicit limit, and producers must slow down when consumers fall behind.

**Why it holds.** An unbounded structure does not prevent overload; it postpones it and converts it into latency and memory exhaustion, usually ending in a crash that loses all buffered work. Queues hide failure: by the time a backlog is visible, its age often already exceeds every client's timeout.

Bounds force a decision about what happens at the limit, which is a design decision rather than an accident.

**In practice.** Bounded channels in Go, Reactive Streams demand signaling, TCP flow control, and Kafka consumer lag alerts are all forms of backpressure. Limit request body sizes, result page sizes, fan-out width and per-tenant concurrency.

Monitor queue age, not just depth. When a bound is hit, choose deliberately: block the producer, reject with a retryable error, or drop the oldest or lowest-priority work.

**Anti-pattern.** In-memory unbounded queues between pipeline stages. APIs that return all results with no pagination. `SELECT *` fan-outs whose size grows with the largest customer. Log shippers that buffer to memory without limit during a downstream outage.

**Review question.** What is the largest input this component can receive, and what happens at one more? Where does excess work wait, for how long, and who learns it is waiting?

### Little's Law
> In a stable system, the average number of items in it equals the arrival rate times the average time each spends in it: L = λW.

**Why it holds.** Little's Law is a theorem with almost no assumptions about distributions. It connects concurrency, throughput and latency, so if you know two you know the third. It explains why latency regressions cause outages: if a service at 1,000 rps sees latency rise from 50 ms to 500 ms, in-flight requests rise from 50 to 500, and pools sized for 100 are exhausted.

**In practice.** Size connection pools and thread pools from it: a service sending 2,000 rps to a database with 5 ms mean latency needs about 10 concurrent connections, plus headroom for variance. Concurrency limiters (Netflix's adaptive concurrency limits) use it in reverse: cap L, and latency rise translates into rejection rather than queueing.

Use it to sanity-check benchmarks: a load test claiming 50,000 rps at 100 ms with 64 client threads is impossible.

**Anti-pattern.** Setting pool sizes by guessing or copying defaults. Capacity planning on throughput alone, ignoring that a slow dependency multiplies required concurrency. Treating latency as a user-experience metric only, rather than as a capacity input.

**Review question.** At peak arrival rate and p99 latency, how many requests are in flight at each layer? Which pool or limit runs out first when a dependency slows by 10x?

### Amdahl's Law
> The speedup from improving part of a system is limited by the fraction of time spent in the part you did not improve.

**Why it holds.** If 5% of a workload is serial, infinite parallelism yields at most 20x speedup. More generally, optimizing a component that accounts for 10% of latency can save at most 10%. Gunther's Universal Scalability Law extends this with a coherency term: coordination costs can make throughput decline as you add nodes.

**In practice.** Profile before optimizing, and attack the largest term. A page that makes six sequential backend calls is bound by their sum; parallelizing them helps until the slowest call dominates. A distributed job that ends in a single-reducer aggregation will not speed up beyond that reducer.

For architecture, identify the serial bottlenecks: a global lock, a single leader, a central sequencer, a shared database. Those set the ceiling regardless of how many stateless nodes you add.

**Anti-pattern.** Adding instances to a tier that is not the bottleneck. Rewriting a service in a faster language when 90% of request time is spent waiting on a database. Microservice decompositions that add network hops to a latency-critical path for organizational, not technical, reasons.

**Review question.** What fraction of this workload is inherently serial or coordinated? If we doubled capacity everywhere except one component, which component sets the limit?

### Measure the tail, not the average
> Design and set targets on high percentiles and their behavior under fan-out, because averages hide the experience of the users who matter most.

**Why it holds.** Latency distributions are long-tailed. With fan-out, the tail dominates: if a request touches 100 servers, each with a 1% chance of being slow, about 63% of requests will be slow (Dean and Barroso, "The Tail at Scale"). The heaviest users often make the most requests, so they experience high percentiles more often than the median user.

Averaging percentiles across hosts is mathematically invalid.

**In practice.** Track p99 and p99.9 per endpoint using histograms (HDR, or Prometheus native histograms) that can be aggregated correctly. Reduce tails with hedged requests (send a second request after the p95 time), tied requests, avoiding GC pauses on hot paths, and limiting fan-out width.

Load test with realistic distributions, including large tenants and cold caches, and measure using a fixed arrival rate to avoid coordinated omission.

**Anti-pattern.** Dashboards that show only mean latency. SLOs on averages. Load generators that wait for responses before sending the next request, hiding queueing delay. Averaging p99s across a fleet and calling it the fleet p99.

**Review question.** How many backend calls does one user request fan out to, and what does that imply about the needed per-call p99? Which users experience our worst percentile, and how often?

### Coordination is the scalability tax
> Scale comes from avoiding coordination; partition data and work along the access pattern so most operations touch one partition.

**Why it holds.** Any operation that requires agreement among nodes (locks, distributed transactions, consensus, global ordering) is limited by the slowest participant and by round-trip time. The Universal Scalability Law captures this as a coherency cost that grows with N squared. Coordination-free designs, such as CRDTs or per-partition processing, scale nearly linearly.

The CALM theorem gives a formal framing: monotonic computations can be run consistently without coordination.

**In practice.** DynamoDB tables are designed around a partition key that matches the dominant query, so each request is single-partition. Kafka orders only within a partition; you choose the key to scope ordering to what needs it, such as per account.

Push coordination to where it is cheap: within a single node or a single-region transaction, or escrow counters such that each partition can approve locally up to an allocated quota.

**Anti-pattern.** A global auto-increment ID or global lock on the write path. Cross-shard transactions for common operations because the partition key was chosen by data model, not access pattern. Hot partitions keyed on time or on a single large tenant.

**Review question.** Which common operations need agreement among more than one partition or node? Is the partition key chosen by the access pattern of the hottest workload?

### Data gravity
> Data attracts computation and services toward itself, so place compute near data and treat moving large datasets as a costly, slow architectural event.

**Why it holds.** Bandwidth, latency and egress costs grow with distance and volume, while compute is cheap to move. As datasets grow, more applications want low-latency access to them, which pulls further services into the same location and makes the data harder still to move. Physics and pricing (cloud egress fees) reinforce the effect.

Regulatory regimes (GDPR, data residency laws) add legal gravity on top of physical gravity.

**In practice.** Analytics platforms move queries to the data: lakehouse engines run against object storage in place rather than copying into a warehouse. Multi-region designs pin a customer's data to a home region and route their requests there.

When choosing a cloud or region, recognize that the primary data store largely determines it for years. Large migrations use physical transfer appliances (AWS Snowball) because the network is slower.

**Anti-pattern.** A service in one cloud that synchronously reads terabytes from another. ETL pipelines that copy the same dataset into five systems, each now a migration and governance problem. "Cloud-agnostic" designs that ignore that the data cannot follow the compute cheaply.

**Review question.** Where does the largest, fastest-growing dataset live, and what does it cost in time and money to move it? Which compute have we placed far from the data it reads most?

### Cost as an architectural attribute
> Treat cost per unit of business value as a first-class quality attribute, designed and reviewed like latency or availability.

**Why it holds.** In elastic infrastructure, every design choice has a direct and recurring price: replication factor, storage tier, cross-AZ traffic, log volume, idle capacity. These costs compound with growth and are hard to reverse once data and dependencies accumulate. Cost also bounds what you can afford to build next, so it is a strategic constraint, not an accounting detail.

**In practice.** Define unit economics, such as cost per thousand requests, per active customer or per GB ingested, and track them alongside SLOs. Make cost visible to owning teams through tagging and showback.

Design choices: tier storage by access frequency, avoid cross-AZ chatter in hot paths, sample traces rather than keep all, use spot or preemptible capacity for retryable batch work, and right-size before reserving. The AWS Well-Architected framework includes cost optimization as a pillar for this reason.

**Anti-pattern.** Discovering the cost of a design from the monthly bill. Retaining debug-level logs forever by default. Five-nines redundancy for an internal tool. Architectures that scale cost linearly with traffic when revenue scales sublinearly.

**Review question.** What is the cost per unit of business value, and how does it change at 10x scale? Which single design choice drives most of the cost, and is it buying something we need?

## Simplicity and Evolvability

### Information hiding (Parnas)
> Decompose systems into modules that each hide a design decision likely to change, exposing only an interface that does not reveal it.

**Why it holds.** David Parnas (1972) showed that decomposing by processing steps (flowchart order) spreads each design decision across modules, so any change ripples everywhere. Decomposing by "secrets," the decisions most likely to change, localizes change to one module. The value of a module is the complexity it hides relative to the interface it exposes; Ousterhout calls these deep modules.

**In practice.** A storage service exposes `put(key, blob)` and `get(key)`, hiding whether data sits on local disks, an object store, or is erasure-coded. A payments module hides which processor is used and its retry quirks. Unix file descriptors hide whether you are reading a file, pipe or socket.

When decomposing services, ask what each one hides, not what each one does. Service boundaries should follow volatile decisions and domain concepts, not technical layers.

**Anti-pattern.** Services split by layer (an API service, a logic service, a data service), so every feature touches all three. Interfaces that leak the database schema, such as passing ORM entities across service boundaries. Shallow wrappers whose interface is as complex as their implementation.

**Review question.** What design decision does each module hide, and what change would force multiple modules to change together? Could the implementation behind this interface be replaced without callers noticing?

### Mechanism vs policy
> Separate the mechanism that makes something possible from the policy that decides what to do, so policy can change without rewriting mechanism.

**Why it holds.** Mechanisms are general, stable and hard to get right; policies are specific, change often and are driven by business needs. Mixing them means every policy change risks the mechanism, and the mechanism cannot be reused for other policies. The principle comes from operating-systems design (Hydra, Brinch Hansen) and the X Window System.

**In practice.** A rate limiter implements token buckets (mechanism) and reads limits per tenant tier from configuration (policy). Kubernetes provides scheduling mechanics; scheduling policy is expressed through affinity rules, priorities and pluggable scheduler profiles. Open Policy Agent separates authorization decisions from the enforcement points in each service.

Policies should be declarative, versioned and validated, because they become the most frequently changed part of the system.

**Anti-pattern.** Retention periods, rate limits or pricing rules hard-coded in the core service, requiring a deploy to change. The opposite failure: a mechanism so generic it is a configuration language no one understands, and policy changes are effectively untested code deploys with no review.

**Review question.** Which parts of this design will the business want to change monthly, and can they change without modifying core code? Are policy changes validated and rolled out as carefully as code?

### Gall's Law
> A complex system that works is invariably found to have evolved from a simple system that worked; one designed from scratch never works and cannot be patched to work.

**Why it holds.** John Gall's observation reflects that complex systems have emergent interactions that cannot be fully predicted at design time. A working simple system provides a feedback loop: real usage reveals which complexity is actually needed. A big-bang design accumulates unvalidated assumptions that all fail together, with no stable base to retreat to.

**In practice.** Amazon's service-oriented architecture evolved from a monolith under real load rather than being designed whole. Successful rewrites use the strangler fig pattern: route one capability at a time to the new system while the old one keeps working.

For new platforms, ship a thin vertical slice end to end, carrying one real workload, before broadening. Keep the system working at every step of evolution.

**Anti-pattern.** Multi-year platform programs with a big-bang cutover. Designing for every future requirement up front. "Version 2" rewrites that try to deliver parity plus new features at launch, which is Brooks's second-system effect.

**Review question.** What is the simplest version of this that could carry one real workload, and when will it? At each step of the plan, is there a working system we could stop at?

### Hyrum's Law
> With enough users of an API, every observable behavior will be depended on by somebody, regardless of what the contract promises.

**Why it holds.** Hyrum Wright named this from Google's experience with large-scale changes: consumers depend on what works, not on what is documented. Iteration order, error message text, timing, default values and bugs all become de facto contract. The cost of changing an interface therefore grows with its user count, independent of documentation.

**In practice.** Go randomizes map iteration order so that no one can depend on it. Some APIs deliberately vary nonguaranteed behavior, such as returning results in a shuffled order or including random padding, to prevent accidental coupling.

Minimize the observable surface: return opaque tokens rather than structured IDs, avoid exposing internal timings, and ship explicit compatibility tests for what is promised. When changing behavior, measure who depends on it, using traffic analysis or canaries, and treat behavior changes as migrations.

**Anti-pattern.** Assuming a change is safe because "the docs never promised that." Exposing auto-increment IDs that consumers start parsing or ordering by. Error strings that clients pattern-match on. Assuming an internal API has no external users after it has been reachable for years.

**Review question.** What observable behaviors does this interface have beyond its documented contract? What would we need to do to change them, and can we make them unobservable now?

### Postel's Law and its critique
> "Be conservative in what you send, liberal in what you accept" aids interoperability early, but at scale tolerance of malformed input becomes de facto protocol and a security risk.

**Why it holds.** Jon Postel's robustness principle helped early Internet protocols interoperate among independent, imperfect implementations. But RFC 9413 (Thomson and Schinazi, 2023) documents its cost: lenient receivers let senders' bugs persist, those bugs become requirements that every new implementation must reproduce, and protocols ossify. Ambiguous parsing is also a classic attack vector, for example HTTP request smuggling, where two components interpret the same bytes differently.

**In practice.** Be strict at boundaries: reject invalid input with clear errors, especially for new protocols and internal APIs, where you control both ends. Where tolerance is needed for extensibility, define it precisely: "ignore unknown fields" in Protobuf is designed extensibility, not leniency.

Use GREASE-style techniques (as in TLS) to exercise extension points so receivers cannot ossify around their absence.

**Anti-pattern.** Parsers that accept and "fix" malformed requests, leading to discrepancies between a proxy and a backend. JSON consumers that accept duplicate keys with implementation-specific semantics. Accepting a deprecated format indefinitely because some client still sends it.

**Review question.** Where would two components in this path parse the same input differently? Are we tolerant by explicit, versioned design, or by accident?

### Choose boring technology
> Spend a limited budget of novelty only where it creates differentiated value; use proven, well-understood technology everywhere else.

**Why it holds.** Dan McKinley's framing: each organization has a few "innovation tokens." Mature technologies have known failure modes, operational tooling, documentation and people who can run them; new ones carry unknown unknowns that surface in production. Each additional technology also multiplies operational surface, hiring needs and on-call knowledge.

**In practice.** Default to a relational database (PostgreSQL) for most stateful services until a measured need requires otherwise. Standardize on a small set of languages, queues and data stores, and require a written case for adding a new one, including who will operate it at 3 a.m.

Spend novelty where it differentiates the business: a novel ranking model may be worth it; a novel service-discovery system rarely is.

**Anti-pattern.** Adopting a new database per service because each team chose its favorite. Resume-driven architecture. Building an in-house framework that solves a problem already solved by a mature open-source tool. Equally, refusing a better tool that has become boring because it is unfamiliar internally.

**Review question.** Which components here are new to our organization, and what differentiated value does each buy? Who has operated this in production under failure, and what failure modes do we know?

### Prefer duplication over the wrong abstraction
> Tolerate duplication until the common pattern is clear; a premature shared abstraction is costlier than the duplication it removes.

**Why it holds.** Sandi Metz's observation: an abstraction made from two or three examples encodes guesses about what varies. When new cases do not fit, people add parameters and conditionals, and the abstraction becomes a tangle that couples every caller. Duplication is local and cheap to change; a wrong abstraction is shared and expensive to unwind.

At organizational scale, shared libraries and shared services also couple release schedules and teams.

**In practice.** Use the rule of three as a heuristic: extract after the third concrete instance, when variation points are evidenced, not imagined. When an existing abstraction has accumulated flags for each caller, inline it back into callers and re-extract from what remains common.

For cross-team code, prefer shared standards and small, stable libraries over shared "common" services that every team must change.

**Anti-pattern.** A "common-utils" library that every service depends on, so every change requires coordinating dozens of teams. Generic workflow engines built before two workflows existed. An entity service shared by many domains, each needing a slightly different "Customer."

**Review question.** How many real, current use cases does this abstraction serve, and do they vary in the same ways? What would it cost to undo this abstraction in two years?

### Design interfaces for evolution
> Treat every published interface as a long-lived product with explicit versioning, compatibility rules and a deprecation path.

**Why it holds.** Implementations can be replaced in weeks; interfaces with many consumers last for years, because each consumer must change for the interface to change. The interface is therefore the most expensive part of a system to get wrong. Explicit compatibility rules let providers evolve without coordinating every consumer.

**In practice.** Design APIs around stable domain concepts and coarse operations rather than internal data structures. Make additive change the default: optional fields, extensible enums with an "unknown" value, and pagination tokens that are opaque.

Publish a compatibility policy (what may change without a version bump), contract-test consumers (for example, Pact), and track per-consumer usage so deprecations can be targeted. Google's API Improvement Proposals (AIPs) and Stripe's date-based API versions with server-side translation layers are good models.

**Anti-pattern.** Exposing database tables as the integration surface. Breaking changes shipped with a minor-version bump. Version proliferation with no deprecation, so the team maintains seven parallel versions forever. Chatty, fine-grained APIs that force consumers to orchestrate the provider's internal workflow.

**Review question.** What changes to this interface can we make without breaking anyone, and is that written down? How would we know which consumers still use a field we want to remove?

## Operations and Change

### Immutable infrastructure
> Never modify running infrastructure in place; replace it with a new, versioned artifact built from source.

**Why it holds.** In-place changes produce configuration drift: servers that differ in ways no one recorded, so behavior cannot be reproduced and failures cannot be reasoned about. Immutable artifacts make the deployed state equal to a known build, make rollback a matter of redeploying the previous artifact, and turn every host into a disposable, replaceable unit.

**In practice.** Build container images or machine images in CI, tag them with content hashes, and deploy by replacing instances. Declare infrastructure in code (Terraform, Pulumi, CloudFormation) and apply changes through pipelines, not consoles. Kubernetes deployments roll new pods rather than patching existing ones.

Disallow SSH-in changes in production or make them break-glass and audited, and periodically recycle hosts so long-lived drift cannot accumulate. Keep state off instances, in managed stores, so instances can be replaced freely.

**Anti-pattern.** Hotfixing a production server by hand and forgetting to commit the change. Configuration management that mutates long-lived hosts for years. "Pet" servers whose loss would be a crisis. Using the `latest` tag in deploy manifests, so the same manifest deploys different code.

**Review question.** Could we rebuild this entire environment from source control today, and how long would it take? What state lives on hosts that would be lost if they were replaced?

### Observability as a design input
> Decide what questions you will need to answer about the system in production before you build it, and design telemetry, identifiers and boundaries to answer them.

**Why it holds.** Distributed systems fail in novel ways that dashboards built for known failures cannot explain. Observability, the ability to understand internal state from external outputs, depends on design choices that are expensive to retrofit: propagation of request context, cardinality of identifiers, structured events, and clear ownership boundaries. If it is not designed in, the first serious incident becomes an archaeology project.

**In practice.** Propagate trace context (W3C Trace Context via OpenTelemetry) across every hop, including queues and batch jobs. Emit structured, wide events containing high-cardinality fields such as tenant ID, build version and feature-flag state. Define service-level indicators during design review, and include an operational readiness section listing the signals that would detect each identified failure mode.

Make async work traceable: carry correlation IDs on messages so a stuck order can be followed through every stage.

**Anti-pattern.** Adding logging after the first outage. Metrics without tenant or version dimensions, so you cannot tell if one customer or one deploy is affected. Free-text logs that cannot be queried. Queue-based designs where work disappears silently between stages.

**Review question.** For the three most likely failure modes, what signal would alert us, and how would we find which customers and which change were involved? Can we trace one request end to end, including async hops?

### Small, progressive, reversible changes
> Ship changes in small increments, expose them progressively to production, and make each one quickly reversible.

**Why it holds.** Most production incidents are triggered by change: code, config, data or infrastructure. Small changes are easier to review, have fewer interactions, and are easier to attribute when something breaks. Progressive exposure turns production into the test, with blast radius limited to the first stage. Fast rollback converts a failed change from an outage into a blip; DORA research links small batches and fast recovery to both higher velocity and stability.

**In practice.** Deploy via canary to one host, then one cell or AZ, then a region, with automated health gates comparing canary and baseline metrics (as with Spinnaker's Kayenta or Argo Rollouts). Treat configuration and feature-flag changes with the same staging as code; several major cloud outages came from global config pushes.

Before shipping, define the rollback: how, how fast, and what is not reversible, such as data migrations or emails sent.

**Anti-pattern.** Weekly release trains bundling hundreds of changes. Global config changes applied instantly everywhere. Rollback that requires a new build. Deployments that couple irreversible schema changes with code changes.

**Review question.** How many customers see this change before we have evidence it is safe, and what automated signal would halt it? What is the rollback, how long does it take, and what can it not undo?

### Decouple deploy from release
> Separate putting code into production from exposing behavior to users, so each can be controlled, staged and reversed on its own.

**Why it holds.** When deploy equals release, every code push is a user-facing risk, and rolling back a feature means rolling back unrelated code. Separating them lets teams deploy continuously while product, operations and risk owners control exposure: per tenant, per region, or by percentage. It also enables dark launches that exercise new code with production traffic before anyone sees results.

**In practice.** Use feature flags with a managed system (LaunchDarkly, OpenFeature-compatible tools, or in-house) to gate new behavior; roll out by cohort and kill instantly if metrics degrade. Shadow traffic to a new service and compare responses before switching reads.

Treat flags as inventory: give each an owner and an expiry, and remove them once fully launched. The flag service itself must be statically stable; clients should cache flag state and have safe defaults.

**Anti-pattern.** Long-lived feature branches merged in a big-bang release. Hundreds of stale flags whose combinations are untested. Flags evaluated by calling the flag service synchronously per request with no cache. Using flags to hide unfinished schema changes that are not themselves reversible.

**Review question.** Can we turn this behavior off in under a minute without a deploy? Who owns this flag, and when will it be removed?

### SLOs and error budgets
> Define reliability targets from the user's perspective, and use the remaining error budget to make explicit trade-offs between velocity and reliability.

**Why it holds.** 100% reliability is the wrong target: it is unachievable, each additional nine costs roughly an order of magnitude more, and users cannot perceive improvements beyond their own network's reliability. A service level objective makes "reliable enough" concrete. The error budget (1 minus SLO) turns reliability from a debate into a shared, measurable resource that product and engineering both spend.

**In practice.** Choose SLIs that reflect user experience, such as the proportion of checkout requests that succeed within 500 ms measured at the load balancer. Set the SLO from user need and dependency reality. Alert on burn rate over multiple windows rather than raw thresholds, as described in Google's SRE Workbook.

Agree on an error-budget policy in advance: when the budget is exhausted, feature launches pause in favor of reliability work.

**Anti-pattern.** SLOs on CPU or host uptime rather than user outcomes. SLOs set higher than those of a critical dependency. Budgets that have no consequence when exhausted. Alerts on every 5xx, producing pager fatigue and missed real incidents.

**Review question.** What does a user experience as "broken" here, and how do we measure that? When the budget runs out, what do we agree to stop doing?

### Chesterton's fence
> Do not remove or change an existing constraint until you understand why it was put there.

**Why it holds.** G. K. Chesterton's parable: a reformer who sees a fence with no obvious purpose should find out why it exists before removing it. In mature systems, odd limits, retries, sleeps and checks are often scar tissue from past incidents whose context has left with the people who wrote them. Removing them reintroduces the failure they prevented, usually under the conditions that originally caused it.

The principle cuts both ways: once the reason is known and no longer applies, the fence should go.

**In practice.** Before removing a rate limit, timeout or validation, search commit history, incident postmortems and design records for its origin. Encode the reason next to the constraint: a comment linking to the incident, or a test that reproduces the failure it guards against.

When the reason cannot be found, remove the constraint progressively and observably, behind a flag, rather than all at once.

**Anti-pattern.** "Cleanup" changes that delete unexplained code and cause a recurrence of a years-old outage. The reverse: preserving every legacy constraint forever because no one dares investigate, so cruft accumulates and the system calcifies.

**Review question.** Why does this constraint exist, and where is that written? What test or signal would tell us we reintroduced the failure it guarded against?

## Security

### Least privilege
> Every principal (person, service, workload, credential) should hold only the permissions it needs, for only as long as it needs them.

**Why it holds.** Saltzer and Schroeder listed least privilege among their 1975 protection principles. Compromise is a matter of when, not if; the damage an attacker can do equals the privileges of what they compromised. Excess privilege also turns honest mistakes into incidents, such as a script with admin rights deleting production data.

Least privilege is the security analogue of blast-radius reduction.

**In practice.** Give each service its own identity and narrowly scoped IAM role; never share credentials across services. Prefer short-lived credentials (workload identity federation, AWS STS, SPIFFE/SPIRE) over static keys. Grant humans just-in-time, time-bound elevated access with approval and audit, rather than standing admin.

Scope data access too: row- and column-level controls, and separate read and write roles. Use access analyzers to find and remove unused permissions periodically.

**Anti-pattern.** Wildcard policies (`"Action": "*"`) "to get it working" that never get tightened. Long-lived access keys in CI systems or developer laptops. A single database user shared by every service. Standing production access for an entire engineering org.

**Review question.** If this component's credentials were stolen today, what could an attacker read, change or delete? Which permissions has it not used in the last 90 days?

### Defense in depth
> Layer independent controls so that the failure or bypass of any single control does not lead to compromise.

**Why it holds.** Every control has bugs, misconfigurations and gaps. If controls are independent, the probability of all failing together is much lower than any one failing. Layers also buy time: detection and response can catch an attacker who has passed some layers before they reach the target. The key word is independent: layers that share a failure mode are one layer.

**In practice.** A customer data service is protected by network segmentation, mutual TLS service identity, per-request authorization, encryption at rest with keys in a separate KMS, audit logging, and anomaly detection on access patterns. Software supply chain defense layers signed commits, reproducible builds, provenance (SLSA), dependency scanning and admission control.

Assume each layer is breached in turn and ask what stops the next step.

**Anti-pattern.** Relying on a perimeter firewall or VPN as the only control, so anything inside is trusted. Multiple layers that all depend on the same identity provider or the same secret. Adding layers that are never monitored, so a bypass is never noticed.

**Review question.** If the outermost control here failed silently, what would stop an attacker, and how would we know? Which of our layers share a single point of failure?

### Fail closed vs fail open
> Decide explicitly, per control, whether failure should deny access (closed) or allow it (open), weighing security harm against availability harm.

**Why it holds.** When a security component fails, the system must do something. Failing closed preserves confidentiality and integrity at the cost of availability; failing open preserves availability at the cost of exposure. Neither is always right: an authorization check should fail closed; a fraud score used for advisory ranking might fail open. The danger is leaving the choice to a library default or an exception handler.

**In practice.** Authentication and authorization fail closed, but are engineered to be statically stable (cached policies, local token validation via JWKS) so failing closed is rare. A web application firewall in front of a critical consumer service might fail open with alerting, because blocking all traffic is worse than briefly losing one layer of defense.

Physical safety systems can require the opposite of data security: emergency exits fail open. Document each choice and test it.

**Anti-pattern.** `try { authorize() } catch { /* log and continue */ }`. Authorization services with no caching, so a blip fails every request closed and teams add bypasses. Rate limiters that fail closed and take down the product when Redis restarts.

**Review question.** For each security control on this path, what happens when it times out or errors, and was that chosen deliberately? Have we tested that failure mode?

### Secure by default and paved roads
> Make the secure path the easiest path, so teams get security as a property of the platform rather than as a checklist.

**Why it holds.** Security that depends on every engineer making the right choice every time will fail at scale, because attention and expertise are uneven. Defaults are used far more often than options. A paved road, a supported and well-lit path, encodes expert decisions once and amortizes them across every team, while leaving room to go off-road with explicit review.

**In practice.** Netflix popularized the paved-road model; Google's secure-by-construction frameworks make XSS and SQL injection hard by providing safe templating and query APIs. Service templates come with mTLS, authentication middleware, secret management, logging that redacts PII, and dependency scanning preconfigured.

Cloud resources are created through modules that default to encryption, private networking and no public access. Policy-as-code checks in CI block insecure configurations, with an exception process.

**Anti-pattern.** Security guidance delivered as a wiki page and an annual training. Frameworks where the secure option requires extra configuration. Paved roads so restrictive or slow that teams route around them, creating unmanaged shadow paths.

**Review question.** What would a new team have to do to build this insecurely, and is that harder than doing it securely? Which security properties come from the platform, and which depend on this team remembering?

### Explicit trust boundaries
> Identify every point where data or control crosses between trust levels, and authenticate, authorize and validate at each one; no network location confers trust.

**Why it holds.** Vulnerabilities cluster at boundaries where assumptions change: user input entering a service, a service calling another, a tenant's data entering a shared component. The perimeter model assumed everything inside the network was trustworthy, and lateral movement after one breach proved otherwise. Zero trust (as in Google's BeyondCorp and NIST SP 800-207) makes each request prove identity and authorization on its own merits.

**In practice.** Draw a data-flow diagram with trust boundaries in threat modeling (STRIDE works well), and check that each crossing has authentication, authorization and input validation. Use workload identity and mTLS for service-to-service calls, and propagate end-user identity so downstream services authorize on behalf of the real user.

In multi-tenant systems, enforce tenant isolation at the data layer, for example with row-level security, not only in application code.

**Anti-pattern.** Internal APIs with no authentication because "only our services can reach them." Services that trust a header such as `X-User-Id` from any caller. Server-side request forgery paths where a service fetches user-provided URLs from inside the trusted network.

**Review question.** Where are the trust boundaries in this design, and what is checked at each? If an attacker controlled one internal service, what could it ask others to do?

### Minimize attack surface and data held
> Expose the fewest interfaces and keep the least sensitive data possible; what you do not run or store cannot be attacked or leaked.

**Why it holds.** Every endpoint, port, dependency, admin tool and retained record is an opportunity for compromise and a liability under breach. Defensive effort scales with surface area, while an attacker needs only one gap. Data minimization also reduces regulatory exposure (GDPR, HIPAA) and the cost of breach notification.

**In practice.** Disable unused endpoints and features, use minimal (distroless) container images, and remove dependencies that are not needed. Tokenize payment data so most systems never see card numbers, narrowing PCI scope to a small vault.

Set retention periods on logs and data, delete on schedule, and avoid logging secrets or personal data. Prefer pseudonymous identifiers in analytics. Remove debug and admin interfaces from production builds, or place them behind separate strong authentication.

**Anti-pattern.** Retaining all data forever "in case it is useful." Full request bodies, including credentials, in logs. Base images with shells, compilers and package managers in production. Deprecated API versions left running years after their last legitimate caller.

**Review question.** What data does this system keep that it does not need, and for how long? Which exposed interfaces or dependencies could we remove without losing a requirement?

## Organizations and Decisions

### Conway's Law
> Organizations design systems whose structure mirrors their communication structure.

**Why it holds.** Melvin Conway (1968) observed that interfaces between components require communication between the people who build them. Where teams communicate easily, components become tightly coupled; where communication is costly, clean interfaces emerge. Architecture and org chart therefore converge over time, whether or not anyone intends it. Studies at Microsoft (on Windows Vista) found organizational metrics predicted defect-prone components better than code metrics.

**In practice.** Use the inverse Conway maneuver: shape team boundaries to match the architecture you want. If you want independent services, give each a single owning team with end-to-end responsibility. Team Topologies offers a vocabulary: stream-aligned teams, platform teams, enabling teams and complicated-subsystem teams, with explicit interaction modes.

When proposing a re-architecture, propose the matching team structure in the same document.

**Anti-pattern.** A microservice architecture owned by component teams (frontend, backend, database), so every feature requires coordination across all of them. Shared services owned by no one. A reorg that splits a cohesive service across two teams, followed by an unplanned API between them.

**Review question.** Which team owns each component in this design, and does the team structure match the intended coupling? Which interfaces exist only because of the current org chart?

### Cognitive load as a constraint
> Size team responsibilities and system boundaries so that the people who own a system can hold it in their heads.

**Why it holds.** A team's capacity to understand, operate and change software is finite. When the system exceeds it, quality, velocity and incident response all degrade; teams fall back to tribal knowledge and fear of change. Team Topologies distinguishes intrinsic load (the problem itself), extraneous load (tooling and environment friction) and germane load (domain learning); good architecture minimizes extraneous load to leave room for the other two.

**In practice.** Limit each team to a domain it can master, typically a small number of services in one bounded context. Remove extraneous load through platforms: deployment, observability and security that just work.

Use cognitive load as an explicit criterion when splitting services or assigning ownership: ask teams what they find hard to reason about. Prefer fewer, deeper components over many shallow ones that each need separate understanding.

**Anti-pattern.** One team owning 40 microservices, each in a different state of maintenance. Every team expected to be expert in Kubernetes, networking, security and its own domain. Architectures that require understanding six services to change one behavior.

**Review question.** Can the owning team explain how this system behaves under failure without consulting anyone else? What extraneous load could the platform remove from them?

### Reversible vs irreversible decisions
> Make two-way-door decisions quickly and locally; slow down and widen review only for one-way doors that are costly or impossible to undo.

**Why it holds.** Jeff Bezos's 2015 shareholder letter distinguishes Type 1 decisions (one-way doors) from Type 2 (two-way doors). Applying heavyweight process to every decision slows an organization without improving outcomes, because most decisions can be corrected cheaply. Applying lightweight process to irreversible decisions risks permanent damage. The skill is classifying correctly and converting one-way doors into two-way doors where possible.

**In practice.** Choosing a library behind an internal interface is a two-way door: let the team decide. Choosing a primary data store, a public API contract, a data model persisted for years, or a security architecture is closer to one-way: write it up, seek dissent, consider alternatives.

Engineer reversibility: abstractions over vendors, expand–contract migrations, feature flags, and pilots with explicit exit criteria. For one-way doors, identify which part is irreversible and narrow it.

**Anti-pattern.** Architecture review boards gating trivial decisions while public API shapes ship without review. Treating a hard-to-undo decision as reversible because "we can always migrate later," without costing the migration.

**Review question.** What would it cost in time and money to reverse this in 18 months? Can we restructure it so the irreversible part is smaller or later?

### Write decisions down with their context
> Record significant architectural decisions with the context, options considered and trade-offs accepted, so future readers can evaluate them rather than guess.

**Why it holds.** Decisions outlive the memory of those who made them. Without recorded context, successors either preserve choices blindly or reverse them without understanding the constraints, often reintroducing solved problems. Writing also improves decisions: articulating alternatives and trade-offs exposes weak reasoning that discussion can hide. At scale, written decisions are how an organization aligns without meetings.

**In practice.** Use Architecture Decision Records (Michael Nygard's format: context, decision, status, consequences) stored with the code. For larger changes, use design documents with explicit sections on alternatives considered, non-goals, and risks, reviewed asynchronously with time-boxed comment periods.

Record the conditions under which the decision should be revisited ("if write volume exceeds 50k/s, reconsider sharding"). Mark superseded decisions rather than deleting them.

**Anti-pattern.** Decisions made in meetings with no record. Design docs that describe only the chosen solution, so readers cannot see what was rejected and why. Documents written after implementation to justify it. Decision records so heavyweight that teams avoid writing them.

**Review question.** What alternatives did we reject, and why? Under what future conditions would this decision be wrong, and how would we notice?

### You build it, you run it
> The team that builds a system should operate it in production, so the feedback from operating it shapes how it is built.

**Why it holds.** Werner Vogels's 2006 phrase describes Amazon's model. When builders are separated from operators, the costs of poor operability fall on people who cannot fix the cause, while the people who can fix it never feel the pain. Ownership closes the loop: teams that are paged by their own systems invest in reliability, observability and automation because it pays off directly for them.

**In practice.** Owning teams carry the pager for their services, write their own runbooks and run their own postmortems. Central SRE or platform teams provide tooling, standards and consulting, and may share on-call for critical services under explicit engagement models (Google's SRE "hand back the pager" model, for example).

Make operational load visible: track pages per week and toil per team, and treat sustained overload as a staffing or architecture problem.

**Anti-pattern.** Throwing releases "over the wall" to an operations team. Shared services with no owner, so incidents bounce between teams. Ownership without authority, where a team is paged for a system whose architecture and roadmap another team controls.

**Review question.** Who gets paged when this breaks at 3 a.m., and do they have the authority and knowledge to fix the cause? How much of their time does operating it currently take?

### Optimize the whole, not the parts
> Evaluate architectural choices by their effect on end-to-end outcomes, not on the metrics of the component or team that proposes them.

**Why it holds.** Systems thinking, from Deming and Goldratt's Theory of Constraints, shows that local optimizations often degrade the whole: a faster stage before a bottleneck only grows its queue. In large organizations, each team's incentives reward local efficiency, such as its own latency, cost or delivery speed, which can push cost and complexity onto others. A Distinguished Engineer's distinctive leverage is seeing and arbitrating these cross-boundary trade-offs.

**In practice.** Measure end-to-end flow (lead time from idea to production, user-perceived latency, total cost per transaction) and make it visible to every contributing team. When one team proposes a change that saves its own cost, ask who absorbs the difference: a storage team reducing replicas may move risk to every consumer.

Find the current constraint, whether a shared database, a review queue or a release process, and focus improvement there before anywhere else.

**Anti-pattern.** Platform teams measured on adoption, pushing usage that does not fit. Product teams optimizing feature throughput while accumulating operational load on a shared on-call. Each microservice meeting its own SLO while the user journey across eight of them does not.

**Review question.** Which end-to-end outcome does this change improve, and who absorbs any costs it shifts? Is this component the current constraint, or are we optimizing a non-bottleneck?
