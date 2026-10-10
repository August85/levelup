## Load, Overload and Flow Control

### Token bucket, leaky bucket and GCRA
> Enforce a long-run rate while allowing a bounded burst, cheaply and per key.

**How it works.** All three are the same contract: average rate `r`, burst `b`.

Token bucket:

1. A bucket holds up to `b` tokens and refills at `r` tokens/sec.
2. Lazily on each request: `tokens = min(b, tokens + r·Δt)`.
3. If `tokens ≥ cost`, subtract and admit; else reject or delay.

Leaky bucket comes in two forms. As a *queue* it buffers requests and drains them at a fixed rate `r`: a shaper that smooths output and adds delay. As a *meter* it is the token bucket reversed (the level rises per request and leaks at `r`), and admits exactly the same traffic.

GCRA (Generic Cell Rate Algorithm, from ATM) is the meter stored as a single timestamp:

1. Emission interval `T = 1/r`; burst tolerance `τ = (b − 1)·T`.
2. Keep `TAT`, the theoretical arrival time of the next request.
3. On arrival at `t`: if `t < TAT − τ`, reject (retry after `TAT − τ − t`).
4. Else admit and set `TAT = max(TAT, t) + T`.

```text
time ──────────────────────────────▶
          TAT-τ            TAT
  reject   │   admit window │
 ◀─────────┤▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓│
           └── τ = burst ───┘
```

**Complexity.** O(1) time per decision. Token bucket needs two fields (tokens, last refill); GCRA needs one (TAT), which makes it an atomic compare-and-set or a tiny Lua script in Redis. The leaky-bucket queue costs O(queue) memory and adds up to `queue/r` latency.

**Where you meet it.** Envoy local rate limit and AWS API Gateway (token bucket); NGINX `limit_req` (leaky bucket, with `burst` and `nodelay`); `redis-cell` and many SaaS API limiters (GCRA); Linux `tc tbf`; cloud egress shaping.

**Pitfalls.**

- Burst `b` set to zero or one makes legitimate clients bounce off at sub-second granularity.
- Distributed limits: per-node buckets multiply the global limit by node count; a central store adds a network hop and a hot key.
- Clock skew across nodes corrupts TAT when nodes write timestamps from their local clocks. Use the store's clock.
- Charging every request cost 1 when cost varies (LLM tokens, query fan-out) lets heavy callers dominate.
- Rejections without `Retry-After` produce synchronized retry storms.

**DE judgment.** Rate limiting protects *fairness and contracts*, not the server. A server under overload needs concurrency limits or load shedding, because a rate that is safe at 50 ms latency is lethal at 2 s. Use a token bucket or GCRA at the edge per tenant, weighted by real cost. Use a leaky-bucket queue only where smoothing output is the goal (an outbound partner API).

In review, probe:

- What key is limited (API key, tenant, IP)?
- Is the limit global or per node, and how is it reconciled?
- What happens when the limiter store is down: fail open or fail closed?
- Do clients receive `Retry-After`?

### Exponential backoff with jitter and retry budgets
> Recover from transient failure without turning a blip into a self-sustaining retry storm.

**How it works.**

1. On a retryable failure, wait `d = min(cap, base · 2^n)` for attempt `n`.
2. Add jitter so clients desynchronize. **Full jitter**: `sleep = rand(0, d)`. **Decorrelated jitter**: `sleep = min(cap, rand(base, prev · 3))`.
3. Stop after a maximum attempt count or a deadline, whichever comes first.
4. Gate all retries through a **retry budget**: retries may be at most a fixed fraction (often 10–20%) of recent requests.

gRPC's retry throttling is a token-style budget: each failure costs 1 token, each success adds `token_ratio`, and retries are allowed only while `tokens > max_tokens / 2`.

Amplification is the core math. With `r` attempts per layer and `k` layers each retrying, one user request can become `r^k` backend calls: 3 attempts across 4 layers is 81×.

```text
client ─3x─▶ API ─3x─▶ svc ─3x─▶ DB
  1 request  ⇒  up to 27 DB calls
```

**Complexity.** O(1) per decision. A budget needs a sliding-window counter or a token pair per client and destination. The latency cost is the sum of the sleeps, so retries must fit inside the caller's deadline.

**Where you meet it.** AWS SDKs (full jitter by default, plus client-side retry quotas); gRPC retry policy and throttling; Finagle retry budgets; Envoy `retry_budget` in cluster circuit breakers; Kubernetes controller work queues.

**Pitfalls.**

- Retrying at every layer. Retry at one layer, ideally the one closest to the user that knows the deadline.
- No jitter: synchronized clients hit the recovering service in waves.
- Retrying non-idempotent operations without idempotency keys.
- Retrying on overload signals (429, 503 with shed reason) as if they were transient.
- A deadline that is not propagated, so downstream retries outlive the caller who has already given up.
- Fixed attempt caps without a budget: at a 100% failure rate the retry load is still 3×.

**DE judgment.** Backoff only spreads load over time; a budget bounds the total. Require both. Standardize retry policy in the shared client library or the mesh, never per team.

Probe:

- Which layer owns retries, and are the others set to zero?
- Is a retry budget enforced, and what is the maximum amplification under total failure?
- Which status codes are retryable?
- Are deadlines propagated end to end?
- Are writes idempotent?

### Circuit breaker state machine
> Stop sending calls to a dependency that is failing, so callers fail fast and the dependency can recover.

**How it works.**

```text
        failure rate > θ
 ┌────────┐ (min volume) ┌──────┐
 │ CLOSED │─────────────▶│ OPEN │◀──┐
 └────────┘              └──────┘   │
     ▲                cool-down│    │probe
     │ probes ok               ▼    │fails
     │                  ┌───────────┴┐
     └──────────────────│ HALF-OPEN  │
                        └────────────┘
```

1. **Closed.** Calls pass. Record outcomes in a sliding window (count- or time-based).
2. Trip to **Open** when the failure rate (errors or slow calls over a threshold) exceeds `θ` *and* the window holds at least a minimum number of calls.
3. **Open.** Reject immediately (or serve a fallback) for a cool-down period.
4. **Half-open.** Admit a small number of probe calls. If they succeed, close; if any fails, reopen, often with a longer cool-down.

**Complexity.** O(1) per call with a ring buffer or bucketed counters. Memory is O(window) per breaker. Breakers are typically keyed per dependency, sometimes per host or per endpoint.

**Where you meet it.** Hystrix (legacy), resilience4j, Polly, Sentinel. Envoy's "circuit breakers" are actually static concurrency and pending-request caps. Envoy *outlier detection* is the per-host breaker: it ejects hosts after consecutive 5xx or success-rate deviation.

**Pitfalls.**

- Breaker granularity too coarse: one bad shard or host opens the breaker for the whole service.
- No minimum volume, so two failures at low traffic trip it.
- Counting caller-side errors (4xx, client timeouts caused by the caller's own deadline) as dependency failures.
- Half-open allowing unlimited traffic, which stampedes the recovering service.
- Fallbacks that are never exercised and fail when needed, or that shift load to a weaker system (cache miss → database).
- Breakers flapping, with every client instance cycling in phase.

**DE judgment.** A breaker is valuable when failures are fast-detectable and a fallback or fast-fail is genuinely better for the user than waiting. It does not replace timeouts, bulkheads, or concurrency limits; with good adaptive concurrency many breakers become redundant. Prefer per-host ejection in the load balancer over a global breaker when failures are host-local.

Probe:

- What is the fallback, and is it tested in game days?
- Is the breaker per host, per endpoint, or per service?
- Which errors count as failures?
- How are breaker state changes surfaced on dashboards and alerts?

### Adaptive concurrency limits (AIMD, Vegas/Gradient style)
> Find and enforce the number of in-flight requests a service can handle without a hand-tuned constant.

**How it works.** By Little's Law the ideal limit is `L = throughput × RTT_noload`. Requests beyond that only queue. The limiter estimates it online and rejects work above it.

**AIMD** (loss-based):

1. On success: `limit += 1/limit` (about +1 per window).
2. On a drop, timeout, or latency above threshold: `limit = limit × β`, with β ≈ 0.5–0.9.

**Vegas** (delay-based):

1. Track `RTT_noload` (minimum observed) and current RTT.
2. Estimate queued requests: `q = limit × (1 − RTT_noload / RTT)`.
3. If `q < α`, increase; if `q > β`, decrease; otherwise hold.

**Gradient**:

1. `gradient = RTT_noload / RTT` (or long-term / short-term RTT), clamped to [0.5, 1].
2. `newLimit = limit × gradient + headroom`, where headroom is often `√limit`.
3. Smooth the result to avoid oscillation.

```text
latency
   │                     ╱ queueing
   │          knee      ╱
   │___________●_______╱
   └───────────────────────▶ in-flight
     limit tracks ──▶ ●
```

**Complexity.** O(1) per request: an atomic in-flight counter and a few EWMAs. Limits are recomputed per sample window, not per request, to reduce noise.

**Where you meet it.** Netflix `concurrency-limits` (Vegas, Gradient2, AIMD); Envoy adaptive concurrency filter (gradient controller with periodic minRTT re-measurement); Uber and Google server-side load shedders; TCP congestion control is the same idea in the network.

**Pitfalls.**

- Stale `RTT_noload`: if minRTT is measured under load, the limit ratchets down; if it was measured during a cache-hot period, it stays too high. Envoy periodically drops to a tiny limit to re-measure, which costs throughput.
- Mixed workloads: cheap and expensive endpoints share one limit and one RTT signal. Partition by endpoint or cost class.
- Client-side limits across many clients do not converge to a fair share without care.
- Latency caused by a downstream dependency shrinks your limit even though you are not the bottleneck.
- Rejections without priority drop critical traffic alongside batch traffic.

**DE judgment.** Prefer adaptive concurrency over static rate limits for server self-protection: it tracks capacity across deploys, instance types and dependency health. Pair it with priority-aware shedding (critical vs. sheddable) and with client retry budgets so shed load does not come back tripled.

Probe:

- What latency signal is used, and is it per endpoint?
- How is minRTT refreshed?
- What happens to rejected requests: a fast 503 or 429 with a reason code the client will not retry blindly?
- Have they load-tested past the knee and shown goodput stays flat instead of collapsing?

### CoDel queue management
> Keep queues from turning into standing delay (bufferbloat) while still absorbing short bursts.

**How it works.** CoDel (Controlled Delay, Nichols and Jacobson) measures *sojourn time*, the time each item spent in the queue, rather than queue length.

1. Timestamp items on enqueue; compute sojourn at dequeue.
2. Parameters: `target` (acceptable standing delay, default 5 ms) and `interval` (about one worst-case RTT, default 100 ms).
3. If sojourn has stayed above `target` for a full `interval`, enter the **dropping** state.
4. While dropping, drop one item, then schedule the next drop at `interval / √count`. The drop rate rises until delay falls.
5. Leave the dropping state as soon as sojourn falls below `target`.

```text
sojourn
  │   burst      standing queue
  │   ╱╲        ┌──────────────
  │__╱__╲_______│ target 5ms
  │  ok: drains  ▲ >target for 100ms
  └──────────────┴──────▶ time
                 start dropping
```

A good queue drains within an interval; a bad queue does not. CoDel lets the first through and kills the second.

Applied to RPC servers (Facebook's adaptive variant): if the queue has not been empty within the last `interval`, use a short queue timeout (`target`) for new items; otherwise use the normal long timeout. This is often combined with **adaptive LIFO**, which serves newest first under overload so that some requests meet their deadline.

**Complexity.** O(1) per enqueue and dequeue; one timestamp per item plus a few state variables. No tuning per link speed, which is its main advantage over RED.

**Where you meet it.** Linux `fq_codel`, the default qdisc on most distributions; Wi-Fi drivers and home routers; Facebook/Meta Thrift server queues; similar ideas in gRPC server queueing and proxies.

**Pitfalls.**

- Using a single CoDel queue across mixed flows: one heavy flow raises delay for everyone. Flow queueing (`fq_codel`) fixes this.
- Setting `target` below the service time of one request. In RPC terms, the target must exceed the typical processing time or nothing ever drains.
- Dropping in the middle of a request that has already consumed expensive work. Shed at admission, not mid-pipeline.
- Measuring queue length in a system where item cost varies widely; sojourn time handles this, length does not.

**DE judgment.** Any in-process work queue without a sojourn bound is a latency bomb: under overload it fills, every request waits the full queue, and all of them miss their deadlines. CoDel-style admission turns that into bounded delay plus fast rejections.

Probe:

- Where are the unbounded queues: thread-pool queues, Kafka consumer lag, connection pools?
- Is queue time measured and exported?
- Is the policy FIFO, LIFO, or deadline-aware under overload?
- Do dropped requests get a fast, non-retried response?

### Hedged requests
> Cut tail latency by sending a duplicate request when the first is slower than usual.

**How it works.** From Dean and Barroso, "The Tail at Scale".

1. Send the request to one replica.
2. If no response arrives within a hedge delay (typically the p95 latency), send a second copy to a different replica.
3. Use the first response; cancel the other.

**Tied requests** go further: send to two replicas at once, each tagged with the other's identity; when one begins execution it tells the other to cancel. This removes queueing variance at almost no extra work.

```text
t=0   ──▶ replica A ......slow.......✗ cancel
t=p95 ──▶ replica B ──▶ reply ✓
          (only ~5% of calls hedge)
```

Why it works: in fan-out, `P(request is slow) = 1 − (1 − p)^n`. With 100 leaf calls and a 1% slow tail per leaf, 63% of requests hit the tail. Hedging attacks the per-leaf tail.

**Complexity.** Extra load is roughly the fraction of requests exceeding the hedge delay: about 5% at a p95 trigger. Google reported a BigTable benchmark where hedging after 10 ms cut p99.9 for 1,000-key reads from 1,800 ms to 74 ms with 2% extra requests. Requires a per-request timer and cancellation support.

**Where you meet it.** Google BigTable and Spanner clients; gRPC hedging policy; Envoy `hedge_on_per_try_timeout`; Cassandra `speculative_retry`; S3 and object-store clients with request racing; DynamoDB SDK patterns.

**Pitfalls.**

- Hedging non-idempotent writes.
- A fixed hedge delay that becomes too aggressive when latency shifts; compute it from a live percentile.
- Hedging during overload doubles load exactly when the system is weakest. Hedges must count against a retry budget and back off when the error rate rises.
- Correlated slowness (same rack, same hot partition, a slow dependency behind both replicas) makes hedges useless.
- No cancellation, so the losing request still consumes full resources.

**DE judgment.** Use hedging for read-heavy, idempotent, high fan-out paths where p99 matters and replicas are independent. Do not use it to paper over a systematic slowness; fix GC pauses, noisy neighbours and hot keys first.

Probe:

- What is the hedge trigger, and is it adaptive?
- Is hedge volume capped by a budget?
- Do replicas fail independently?
- Does the server honour cancellation?
- What is the measured extra load at p50 traffic and at peak?

## Load Balancing and Congestion

### Power of two choices (with peak-EWMA)
> Spread load nearly as well as global least-loaded, without global state or herding.

**How it works.**

1. Pick two backends uniformly at random.
2. Send the request to the one with the lower load score.

The theory (Mitzenmacher; Azar et al.): with `n` balls in `n` bins, random placement gives a maximum load of about `log n / log log n`. Choosing the better of two gives `log log n / log 2 + O(1)`, an exponential improvement. A third choice adds little.

Choosing randomly between two avoids **herding**: with stale load data, "always pick the global least-loaded" sends every client to the same backend at once.

**Peak-EWMA** (Finagle, Linkerd) is the load score:

1. Keep an EWMA of observed latency per backend.
2. If a new sample is higher than the EWMA, jump to it immediately (peak-sensitive); decay toward lower samples with time constant τ.
3. `cost = ewma_latency × (outstanding + 1)`.

```text
 random pick: [B3] [B7]
 B3 cost = 12ms × (4+1) = 60
 B7 cost =  9ms × (2+1) = 27  ──▶ send to B7
```

**Complexity.** O(1) per request: two random draws and two score lookups. Each client keeps O(backends) local state; no coordination.

**Where you meet it.** Envoy `LEAST_REQUEST` (P2C by default); NGINX `random two least_conn`; HAProxy `random(2)`; Finagle and Linkerd (P2C + peak-EWMA); gRPC weighted round robin and ORCA-based balancers that combine backend-reported load.

**Pitfalls.**

- New or recovering backends: zero outstanding and no latency history attract a burst. Use slow start or a pessimistic initial EWMA.
- A fast-failing backend (returns errors in 1 ms) looks like the best one and absorbs traffic. Penalize errors in the score or eject via outlier detection.
- Heterogeneous hosts: least-request without weights under-uses big machines.
- Few clients, each with a small subset of backends, produce poor balance; subsetting must be deterministic and well-spread.
- Pure round robin is fine only when requests and hosts are uniform.

**DE judgment.** P2C with a latency- or outstanding-aware score is the right default for service-to-service RPC. It handles heterogeneous request costs and partially degraded hosts far better than round robin, with no central state.

Probe:

- What is the load signal: connections, in-flight, latency, or server-reported utilization?
- How are slow-start and fast-failure handled?
- How does subsetting work at scale (thousands of clients times thousands of servers)?
- Is there a coupling between the load balancer and server-side concurrency limits, so shed responses steer traffic away?

### TCP CUBIC
> Fill high bandwidth-delay-product paths quickly while remaining fair to other loss-based flows.

**How it works.** CUBIC is a loss-based congestion control (RFC 9438) whose window growth is a cubic function of time since the last loss, not of RTT count.

1. On loss, record `W_max` (the window at loss) and cut: `cwnd = β · W_max` with β = 0.7.
2. Grow by `W(t) = C·(t − K)³ + W_max`, where `C = 0.4` and `K = ∛(W_max·(1 − β)/C)` is the time to return to `W_max`.
3. The curve is concave approaching `W_max` (cautious near the last loss point), then convex beyond it (probes quickly for new capacity).
4. A "TCP-friendly" region ensures CUBIC is never slower than standard Reno-style AIMD on short-RTT paths.
5. HyStart exits slow start early on delay increase to avoid massive overshoot.

```text
cwnd
 │                            ╱
W_max ─ ─ ─ ─ ─ ──────────────╯ convex
 │          ╭──────╯
 │        ╱  concave
 │      ●  cut to 0.7·W_max
 └──────┼───────────┼─────────▶ t
       loss         K
```

**Complexity.** O(1) per ACK. Because growth is time-based, flows with different RTTs converge to fairer shares than Reno, where short-RTT flows win.

**Where you meet it.** Default in Linux since 2.6.19, also in Windows, macOS and Android stacks. Most QUIC stacks offer CUBIC or NewReno as the default alongside BBR.

**Pitfalls.**

- Loss-based means it fills buffers until they drop. With deep buffers this causes bufferbloat: hundreds of milliseconds of added latency for every flow on the link.
- It treats random loss (Wi-Fi, cellular) as congestion and collapses throughput on lossy links.
- On very high BDP paths, recovery after loss still takes many seconds.
- Fairness with BBR flows on the same bottleneck can be poor in either direction depending on buffer depth.

**DE judgment.** CUBIC is the safe, well-understood default for general server traffic and data-centre bulk transfer with shallow buffers and AQM. Consider BBR for long-haul, lossy, or user-facing delivery (video, CDN egress), and DCTCP or similar ECN-based schemes inside a controlled data centre.

Probe:

- What congestion control runs on the edge, internal and cross-region paths?
- Is there AQM (`fq_codel`) and pacing (`fq` qdisc) on hosts?
- How was throughput measured: on lossless lab links or on real last-mile paths?

### BBR congestion control
> Run at the bottleneck's bandwidth with minimal queue, using a model of the path rather than loss as the signal.

**How it works.** BBR (Bottleneck Bandwidth and Round-trip propagation time, Google) models the path with two numbers.

1. **BtlBw**: windowed *maximum* delivery rate over about 6–10 round trips.
2. **RTprop**: windowed *minimum* RTT over about 10 s.
3. **BDP** = `BtlBw × RTprop`, the data needed in flight to fill the pipe with no queue.
4. Send at `pacing_rate = pacing_gain × BtlBw`; cap in-flight at `cwnd = cwnd_gain × BDP` (gain ≈ 2).

A state machine probes the model:

- **Startup**: gain ≈ 2.89 (2/ln 2), doubling each RTT until bandwidth stops growing for 3 rounds.
- **Drain**: gain < 1 to empty the queue built in Startup.
- **ProbeBW**: cycle gains `1.25, 0.75, 1, 1, 1, 1, 1, 1` to probe for more bandwidth and then drain.
- **ProbeRTT**: every ~10 s, drop in-flight to 4 packets for 200 ms to re-measure RTprop.

```text
 delivery          ┌───────── BtlBw
 rate     ╱‾‾‾‾‾‾‾‾│  queue builds →
         ╱         │  RTT rises
        ╱  RTT flat│
 ──────●───────────●──────▶ in-flight
      BDP (BBR aims here)
```

**Complexity.** O(1) per ACK, plus windowed max/min filters. It needs accurate pacing (the `fq` qdisc or internal TCP pacing) to work.

**Where you meet it.** Google front ends, YouTube, Google Cloud; QUIC stacks; Linux `tcp_bbr`; many CDNs for egress. BBRv2 and BBRv3 add responses to loss and ECN.

**Pitfalls.**

- BBRv1 ignores loss: in shallow buffers it can sustain very high retransmit rates, and it can starve CUBIC flows (or be starved, in very deep buffers).
- ProbeRTT causes periodic throughput dips that matter for latency-sensitive flows.
- Delivery-rate estimates are fooled by ACK aggregation (Wi-Fi, cellular, offloads), causing overestimates.
- Multiple BBR flows can converge to a shared standing queue of about 1 BDP because of the cwnd gain.
- Rollouts often regress on a minority of paths; aggregate wins hide them.

**DE judgment.** BBR is compelling for user-facing egress over lossy, long-RTT, or deep-buffer paths: it often gives higher throughput and lower latency there. Prefer BBRv2/v3 or a vendor-tuned version over v1 where you share bottlenecks with other traffic.

Probe:

- Is pacing enabled?
- How were fairness and retransmit rates measured against CUBIC traffic on the same links?
- Is there a per-path or per-region rollout with QoE metrics (rebuffering, time to first byte), not only throughput?

## Caching and Queueing

### LRU, LFU, ARC and W-TinyLFU
> Decide which items to keep in a fixed-size cache so the hit rate stays high across changing access patterns.

**How it works.**

**LRU** evicts the least recently used item. A hash map plus a doubly linked list gives O(1) get, put and evict: move to head on access, evict from tail.

**LFU** evicts the least frequently used item. An O(1) version keeps a list of items per frequency count. Without aging, items that were popular once stay forever.

**ARC** (Adaptive Replacement Cache, Megiddo and Modha) balances recency and frequency:

1. `T1`: items seen once recently. `T2`: items seen at least twice.
2. Ghost lists `B1` and `B2` hold *keys only* of items recently evicted from `T1` and `T2`.
3. A hit in `B1` means "recency was undersized": grow the `T1` target `p`. A hit in `B2` shrinks `p`.
4. Total cache = `c` items; ghosts add another `c` keys.

**W-TinyLFU** (Einziger, Friedman, Manes) splits admission from eviction:

```text
 new ─▶ [Window LRU ~1%] ─evict─▶ candidate
                                     │
     TinyLFU: freq(candidate) > freq(victim)?
                │yes                 │no
                ▼                    ▼
  [Main SLRU: probation 20% │     drop candidate
              protected 80%]
```

1. Frequencies live in a Count-Min Sketch with 4-bit counters, plus a "doorkeeper" Bloom filter that absorbs one-hit wonders.
2. Every `W` accesses (about 10× cache size), all counters are halved. This ages history.
3. A candidate evicted from the window replaces the main-cache victim only if its estimated frequency is higher.
4. Caffeine adapts the window size by hill climbing on the observed hit rate.

**Complexity.** All are O(1) per operation. LRU costs two pointers per entry. ARC costs roughly 2× key metadata for the ghosts. W-TinyLFU's sketch is about 8 bytes per cached entry, which is small versus storing history. LRU's list update on every read is a write under a lock; sharded or sampled designs (Redis approximated LRU, CLOCK) avoid that contention.

**Where you meet it.** LRU: memcached (segmented), most framework caches. Approximate LRU/LFU: Redis `allkeys-lru` and `allkeys-lfu` with sampling and a logarithmic counter. ARC: ZFS, some storage controllers. W-TinyLFU: Caffeine (Java), Ristretto (Go), many CDN and database caches. CLOCK-Pro and newer FIFO-based designs (S3-FIFO, SIEVE) appear in storage systems.

**Pitfalls.**

- LRU is not scan-resistant: one table scan or batch job flushes the hot set.
- Pure LFU without decay keeps yesterday's hot keys forever.
- Hit rate is measured by count, but misses differ in cost and size; a size-aware or cost-aware policy may matter more than the algorithm.
- Global locks on the recency list become the bottleneck at high QPS.
- Evaluating policies on synthetic Zipf traces instead of production traces.

**DE judgment.** Default to W-TinyLFU (or the library's equivalent) for in-process caches; it is near-optimal on most real traces and scan-resistant. ARC is a strong choice for storage-layer page caches; the IBM patent that long kept it out of open-source projects has since expired. Plain LRU is fine for small caches with no scans.

Probe:

- What is the measured hit rate, and what is the cost of a miss (latency and backend load)?
- What happens on cold start or after a mass eviction?
- Is there a stampede guard (request coalescing, soft TTL)?
- Has anyone replayed a production trace against alternative policies?

### Little's Law and the M/M/1 queue
> Relate concurrency, throughput and latency, and predict how latency explodes as utilization rises.

**How it works.**

**Little's Law** holds for any stable system, regardless of arrival or service distribution:

`L = λW`, equivalently `W = L / λ`

where `L` is the mean number in the system, `λ` the arrival rate, `W` the mean time in the system. A service at 2,000 RPS and 50 ms mean latency has 100 requests in flight on average. That number sizes thread pools, connection pools and concurrency limits.

**M/M/1** (Poisson arrivals, exponential service, one server):

1. Utilization `ρ = λ / μ`, where `μ = 1/S` is the service rate.
2. Mean time in system: `W = S / (1 − ρ)`.
3. Mean number in system: `L = ρ / (1 − ρ)`.
4. Mean queueing delay: `Wq = ρS / (1 − ρ)`.

```text
 W/S
 20 ┤                         ●
 10 ┤                     ●
  5 ┤                 ●
  2 ┤         ●
  1 ┼●────────────────────────▶ ρ
    0       0.5     0.8 0.9 0.95
```

At 50% utilization latency doubles; at 80% it is 5×; at 90%, 10×; at 95%, 20×.

For general distributions, Kingman's approximation for G/G/1 shows variance matters as much as load: `Wq ≈ (ρ/(1−ρ)) · ((cₐ² + cₛ²)/2) · S`, where `c` is the coefficient of variation. Multi-server pools (M/M/c) do much better at the same utilization, which is why one shared queue beats per-worker queues.

**Complexity.** Closed form, O(1) to evaluate. The value is in reasoning, not computation.

**Where you meet it.** Capacity planning; sizing connection pools (pool ≈ peak RPS × query time); autoscaling targets (why CPU targets sit at 50–70%); Kafka consumer lag estimation; any SLO negotiation.

**Pitfalls.**

- Applying Little's Law to an unstable system (arrival > service), where queues grow without bound and averages are meaningless.
- Mixing units or windows (λ per second, W in milliseconds, measured over different periods).
- Assuming M/M/1 percentiles for real systems: real service times are heavy-tailed, so p99 is far worse than the mean suggests.
- Utilization averaged over a minute hides seconds at 100%.
- Treating "80% CPU" as safe without knowing whether the bottleneck is CPU at all.

**DE judgment.** Every capacity and latency SLO conversation should be anchored here. Ask what utilization the design runs at, at peak, and what the latency multiplier is there.

Probe:

- What is the in-flight count implied by target RPS and latency, and do pool sizes match it?
- What is the headroom at peak plus one zone failure?
- How variable are service times, and can variance be reduced (separate queues for slow requests, caching, batching)?

### Universal Scalability Law
> Model how throughput scales with concurrency or nodes, including the point where adding more makes it worse.

**How it works.** Neil Gunther's USL:

`C(N) = N / (1 + α(N − 1) + βN(N − 1))`

- `N`: load (users, threads, nodes).
- `α`: **contention**, the serialized fraction (locks, a single leader, a shared queue). This alone is Amdahl's Law, and throughput plateaus at `1/α`.
- `β`: **coherency**, the cost of keeping shared state consistent (cache-line bouncing, cross-node chatter, distributed locks). This term grows quadratically and makes throughput *decline*.

Peak throughput occurs at `N* = √((1 − α) / β)`.

```text
throughput
 │        ideal ╱  Amdahl (β=0)
 │            ╱   ___________
 │          ╱ ___╱‾‾‾‾╲  USL
 │        ╱_╱          ╲___
 │      ╱╱  peak at N*      ‾‾
 └────────────────────────────▶ N
```

To fit it:

1. Measure throughput at several values of `N` (at least 6, ideally spanning past the expected peak).
2. Normalize by `C(1)`.
3. Fit α and β with nonlinear least squares (or linear regression on the transformed form).
4. Read off `N*` and the ceiling; extrapolate cautiously.

**Complexity.** Closed form; fitting is trivial. The cost is in running clean benchmarks at enough points.

**Where you meet it.** Database and storage benchmarking (connection count vs. TPS); thread-pool sizing; deciding cluster sizes for consensus groups and sharded systems; explaining why a 3-node to 6-node expansion gained only 30%.

**Pitfalls.**

- Fitting on too few points, or only on the linear part of the curve, gives a meaningless β.
- Mixing scale-up and scale-out data in one fit.
- Benchmarks hitting a different bottleneck (load generator, network) than production.
- Treating the model as physics: it describes a curve, it does not tell you which lock causes α.
- Ignoring that α and β change with the workload mix and data size.

**DE judgment.** Use USL to make scaling claims falsifiable. A "linear scalability" claim in a design review should come with a curve; if β is meaningfully above zero, there is a hard ceiling and adding nodes will eventually lose throughput.

Probe:

- What are the serialization points (α): a leader, a global lock, a single partition?
- What are the coherency costs (β): fan-out reads, cross-shard transactions, cache invalidation broadcasts?
- What is the fitted `N*`, and how far is production from it?

## AI Systems

### Transformer attention and the KV cache
> Let every token draw on every earlier token, and avoid recomputing that history at each decoding step.

**How it works.** Scaled dot-product attention:

`Attention(Q, K, V) = softmax(QKᵀ / √d_k) V`

1. Each token's hidden state is projected into a query `q`, key `k` and value `v` per head.
2. Scores `QKᵀ` say how much each query attends to each key; dividing by `√d_k` keeps softmax out of saturation.
3. A causal mask sets future positions to −∞ in decoder models.
4. Softmax normalizes each row; the output is a weighted sum of values.
5. Multi-head attention runs `h` heads in parallel and concatenates them.

**KV cache.** In autoregressive decoding, keys and values for past tokens never change. Store them per layer, and each new token computes only its own `q, k, v` and attends over the cache.

```text
 prefill: whole prompt in one pass
 ┌──────── KV cache (per layer) ────────┐
 │ k1 v1 │ k2 v2 │ ... │ kn vn │ +k v → │
 └──────────────────────────────────────┘
 decode: 1 new q attends over n cached k
```

Size per token:

`2 × layers × kv_heads × head_dim × bytes`

For a 70B-class model with 80 layers, 8 KV heads (GQA) and head dim 128 in FP16, that is about 320 KiB per token: 2.5 GiB for one 8K-token sequence.

**Complexity.**

- Prefill: O(n²·d) compute per layer; compute-bound and parallel.
- Decode: O(n·d) per new token, but dominated by *reading* weights and the KV cache from HBM, so it is memory-bandwidth-bound.
- KV memory: O(n) per sequence and linear in batch size; it, not compute, usually caps concurrency.

Mitigations: GQA/MQA (fewer KV heads), MLA (low-rank latent KV), FlashAttention (tiled, IO-aware; same FLOPs, O(n) memory, much faster), sliding-window attention, and KV cache quantization.

**Where you meet it.** Every LLM inference server: vLLM, TensorRT-LLM, SGLang, TGI, llama.cpp. Prompt or prefix caching in hosted APIs reuses KV for shared prefixes.

**Pitfalls.**

- Capacity planning on weights only; the KV cache for long contexts and large batches often exceeds the weights.
- Measuring only time-to-first-token or only throughput: prefill and decode have different bottlenecks.
- Prefix caches that miss because of tiny prompt variations (timestamps at the top of system prompts).
- Long context degrading quality ("lost in the middle") even when it fits.
- Numerical issues: softmax in low precision without max subtraction.

**DE judgment.** Treat inference as a memory-bandwidth and KV-capacity problem. Model choice (GQA, context length) and prompt design (stable shared prefixes) often matter more than hardware.

Probe:

- KV bytes per token, expected context length, and target concurrency per GPU.
- Prefix-cache hit rate and prompt structure.
- Separate SLOs for time-to-first-token and inter-token latency.
- Whether prefill and decode are disaggregated onto different pools at scale.

### Continuous batching and PagedAttention
> Keep GPUs busy serving many variable-length generations without wasting KV-cache memory.

**How it works.**

**Continuous (iteration-level) batching** (Orca, 2022):

1. The scheduler forms the batch at every decode step, not per request.
2. A sequence that emits its end token leaves immediately; a waiting request joins at the next step.
3. Prefill of new requests is mixed with decode of running ones; **chunked prefill** splits long prompts so they do not stall decoding.

Static batching, by contrast, waits for the longest sequence in the batch, leaving slots idle.

**PagedAttention** (vLLM, 2023) manages the KV cache like virtual memory:

1. The KV cache is divided into fixed-size blocks (e.g. 16 tokens).
2. Each sequence has a block table mapping logical blocks to physical blocks, allocated on demand.
3. Attention kernels gather keys and values through the block table.
4. Blocks are reference-counted, enabling shared prefixes and copy-on-write for parallel sampling and beam search.
5. Under memory pressure, sequences are preempted by swapping blocks to CPU or by recomputing later.

```text
 seq A table: [0]→P7 [1]→P2 [2]→P9
 seq B table: [0]→P7 [1]→P4   (P7 shared)
 physical:  P2 P4 P7 P9 ... free list
```

**Complexity.** Scheduling is O(batch) per step. PagedAttention reduces KV waste from fragmentation and over-reservation (reported as 60–80% in earlier systems) to under about 4%, which translates into 2–4× throughput at the same latency. Block-table indirection adds a small kernel overhead.

**Where you meet it.** vLLM, SGLang (RadixAttention: a radix tree of shared prefixes), TensorRT-LLM ("in-flight batching" with paged KV), TGI, and hosted LLM APIs generally.

**Pitfalls.**

- Larger batches raise throughput but also inter-token latency; without a latency-aware scheduler, interactive users suffer during batch-job spikes.
- Long prompts hogging prefill; without chunked prefill, decode stalls and p99 inter-token latency spikes.
- Preemption thrash: admitting too many sequences, then repeatedly evicting and recomputing them.
- Output length is unknown at admission, so memory planning must be probabilistic.
- Benchmarks with uniform prompt and output lengths overstate real throughput.

**DE judgment.** Continuous batching with paged KV is table stakes for any self-hosted LLM serving; do not build on a server without it. The real design work is the scheduler policy: priorities, fairness across tenants, and the latency/throughput trade.

Probe:

- Target time-to-first-token and inter-token latency per tier.
- Maximum batch size and KV memory fraction.
- Admission control and preemption policy.
- Whether prefix sharing is exploited.
- Load tests with production-shaped length distributions.

### Speculative decoding
> Generate several tokens per expensive forward pass of a large model, without changing its output distribution.

**How it works.** Decode is memory-bound, so verifying `k` tokens in one pass costs about the same as generating one.

1. A cheap **draft** (small model, extra heads, or n-gram lookup) proposes `k` tokens `x₁…x_k` with probabilities `q(x)`.
2. The **target** model scores all `k` positions in one forward pass, giving `p(x)`.
3. For each `xᵢ` in order, accept with probability `min(1, p(xᵢ)/q(xᵢ))`.
4. At the first rejection, sample a replacement from `norm(max(0, p − q))` and stop.
5. If all `k` are accepted, sample one bonus token from the target.

This rejection scheme makes the output *exactly* the target's distribution. With greedy decoding it reduces to "accept while the draft matches the target's argmax".

```text
 draft:  the  cat  sat  on   a
 target:  ✓    ✓    ✓   ✗→the
 emitted: the cat sat the   (4 tokens, 1 pass)
```

Expected tokens per target pass, with per-token acceptance rate α: `(1 − α^(k+1)) / (1 − α)`.

**Complexity.** Speedups of 2–3× are typical at small batch sizes. Cost: draft compute, extra KV cache for the draft, and wasted target compute on rejected tokens. Gains shrink as batch size grows, because the target becomes compute-bound and verification is no longer free.

**Where you meet it.** vLLM, TensorRT-LLM, SGLang and llama.cpp support draft models; Medusa and EAGLE add lightweight draft heads; prompt-lookup decoding copies spans from the context (strong for editing and RAG); DeepSeek-V3 style multi-token prediction heads double as drafters.

**Pitfalls.**

- Draft and target tokenizers must match (or be mapped).
- Low acceptance (domain mismatch, high temperature) makes it slower than plain decoding.
- An implementation bug in the acceptance step silently changes the output distribution; test against reference sampling.
- Throughput can fall at high load; enable it adaptively by batch size.
- Tail latency can rise because the cost per step varies.

**DE judgment.** Use it for latency-sensitive, low-to-moderate concurrency serving, and for predictable outputs (code edits, structured output, RAG answers quoting sources). Skip it for throughput-maximized batch jobs.

Probe:

- Measured acceptance rate on production traffic, not benchmarks.
- Speedup at the actual operating batch size.
- Whether lossless sampling is preserved.
- Memory cost of the draft model versus using that memory for a larger batch.

### Quantization (INT8/INT4, GPTQ/AWQ-style)
> Shrink model weights (and sometimes activations and KV cache) to fewer bits to cut memory and bandwidth with minimal quality loss.

**How it works.** Affine quantization maps a real value to an integer:

`x_q = clamp(round(x / s) + z, q_min, q_max)`, and `x ≈ s · (x_q − z)`

with scale `s = (max − min) / (2^b − 1)` and zero point `z`. Symmetric schemes set `z = 0`.

Granularity trades accuracy for metadata: per-tensor, per-channel, or per-group (e.g. one scale per 128 weights, the common INT4 setting).

Schemes:

- **W8A8** (INT8 or FP8 weights and activations): uses integer or FP8 tensor cores; needs activation outlier handling (LLM.int8() keeps outlier columns in FP16; SmoothQuant migrates activation scale into weights).
- **W4A16** (weight-only INT4): weights are dequantized in the kernel; ideal for memory-bound decode.

**GPTQ** (post-training, layer by layer):

1. Use calibration inputs `X` to form the Hessian proxy `H = 2XXᵀ`.
2. Quantize weight columns one at a time.
3. After each column, update the not-yet-quantized columns using `H⁻¹` to compensate the error just introduced.

**AWQ**:

1. Find salient weight channels (about 1%) from *activation* magnitudes on calibration data.
2. Scale those channels up before quantization (and inversely scale activations), which reduces their relative error.
3. Search the scale per layer to minimize output error; no backprop needed.

```text
 FP16 70B: ████████████████ 140 GB
 INT8    : ████████          70 GB
 INT4    : ████              ~37 GB (+scales)
```

**Complexity.** GPTQ and AWQ run in minutes to hours on one GPU. At inference, 4-bit weights cut weight bandwidth about 4× versus FP16, which speeds memory-bound decode roughly proportionally *if* fused dequant kernels exist (e.g. Marlin). At large batch sizes compute dominates and weight-only quantization helps less.

**Where you meet it.** vLLM, TensorRT-LLM, TGI, llama.cpp (GGUF k-quants); FP8 on H100-class and later GPUs; KV cache in FP8 or INT8; on-device models.

**Pitfalls.**

- Judging quality on perplexity alone; reasoning, code, long-context and multilingual tasks degrade first.
- Calibration data unlike production data.
- No fast kernel for the chosen format on the target hardware, making the quantized model slower.
- Activation outliers ruining naive W8A8.
- Stacking quantization with LoRA or fine-tuning without re-evaluating.

**DE judgment.** Quantization is usually the cheapest capacity lever in LLM serving. Default to FP8 where hardware supports it and INT4 weight-only for memory-constrained or edge serving, gated on task-level evals.

Probe:

- Eval suite and regression thresholds against the FP16 baseline.
- Throughput and latency measured at real batch sizes.
- Kernel and hardware support.
- Whether the KV cache is quantized too, and its effect on long contexts.

### HNSW vector search
> Find approximate nearest neighbours in high-dimensional embeddings with high recall and low latency.

**How it works.** Hierarchical Navigable Small World (Malkov and Yashunin) is a multi-layer proximity graph.

1. Each inserted vector gets a top layer `l = ⌊−ln(U) · m_L⌋`, with `U ~ Uniform(0,1)` and `m_L = 1/ln(M)`. Upper layers are exponentially sparser.
2. **Search**: start at the entry point on the top layer; greedily move to the closest neighbour until no improvement; drop a layer and repeat.
3. On layer 0, run a best-first beam search keeping `ef` candidates; return the top `k`.
4. **Insert**: search with `efConstruction` candidates per layer; connect to up to `M` neighbours (`2M` on layer 0) chosen by a diversity heuristic that skips neighbours already closer to each other.

```text
 L2  ●─────────────────●
     │                 │
 L1  ●─────●───────●───●
     │     │       │   │
 L0  ●─●─●─●─●─●─●─●─●─●  ← beam (ef)
```

**Complexity.**

- Query: roughly O(log N) hops, each costing `M` distance computations.
- Memory: full vectors plus about `2M × 4` bytes of links per node on layer 0.
- Build: O(N log N), slow and CPU-heavy at large N.
- Recall and latency are tuned at query time with `ef`.

**Where you meet it.** FAISS (`IndexHNSW`), hnswlib, pgvector, Lucene/Elasticsearch/OpenSearch, Qdrant, Weaviate, Milvus, Redis, Vespa.

**Pitfalls.**

- RAM: everything is memory-resident. A billion 768-dim float vectors is about 3 TB before links.
- Filtering: post-filtering a top-k loses recall when filters are selective; pre-filtering removes nodes and can disconnect the graph. Engines need filter-aware traversal or fall back to brute force for small candidate sets.
- Deletes are tombstones; heavy churn degrades the graph until rebuild.
- Recall is rarely measured in production; teams tune `ef` on a benchmark and drift.
- Embedding model changes require a full re-index.

**DE judgment.** HNSW is the right default up to hundreds of millions of vectors when RAM is affordable and latency matters. Beyond that, or when cost dominates, use compressed (IVF-PQ, or HNSW over quantized vectors with re-ranking) or disk-based indexes (DiskANN).

Probe:

- Recall@k against exact search on a held-out query set.
- Memory per vector, and growth plans.
- Filter selectivity and how filtering is implemented.
- Update and delete rate, and the rebuild strategy.
- Index versioning tied to the embedding model version.

### IVF-PQ vector search
> Search billions of vectors in limited memory by clustering the space and compressing each vector to a few bytes.

**How it works.**

**IVF (inverted file):**

1. Train `nlist` centroids with k-means (commonly √N to 16√N).
2. Assign each vector to its nearest centroid's list; store the residual `r = x − c`.
3. At query time, probe only the `nprobe` closest lists.

**PQ (product quantization):**

1. Split each `D`-dim residual into `m` sub-vectors of `D/m` dims.
2. Train a 256-entry codebook per sub-space; encode each sub-vector as one byte.
3. A vector becomes `m` bytes.

**ADC (asymmetric distance computation):**

1. For the query, precompute an `m × 256` table of distances to every codeword.
2. A vector's approximate distance is the sum of `m` table lookups.
3. Re-rank the top candidates with full-precision vectors if available.

```text
 x (768 float32 = 3072 B)
 ├ sub1 ├ sub2 ├ ... ├ sub96 ┤
   ↓      ↓            ↓
  [17]   [203]   ...  [88]    = 96 bytes
```

**Complexity.**

- Memory: `m` bytes per vector plus IDs; 32× or more compression versus float32.
- Query: O(nlist · D) to choose lists + O(nprobe · N/nlist · m) lookups. Highly SIMD- and GPU-friendly.
- Training: k-means on a sample, minutes to hours.

**Where you meet it.** FAISS (`IVF4096,PQ64` style factory strings, GPU indexes), Milvus, ScaNN (anisotropic quantization), LanceDB, and as the compressed tier of billion-scale systems. OPQ adds a learned rotation before PQ to balance variance across sub-spaces.

**Pitfalls.**

- Recall ceiling: PQ distance error limits recall unless you re-rank against full vectors.
- `nprobe` too low misses neighbours near list boundaries; too high approaches brute force.
- Training on unrepresentative samples, or never re-training as the data distribution drifts, leaves lists imbalanced.
- Imbalanced lists cause tail latency on queries that hit the big ones.
- Cosine similarity requires normalized vectors before training and indexing.

**DE judgment.** Choose IVF-PQ when scale or cost rules out keeping full vectors in RAM, typically above a few hundred million vectors, or on GPU for batch similarity search. Accept lower recall at fixed latency, and recover it with re-ranking.

Probe:

- Recall@k with and without re-ranking.
- Where full vectors live (SSD, object storage) for re-ranking.
- `nlist`, `nprobe` and `m` choices, with the latency/recall curve.
- Re-training cadence and list balance monitoring.

### BM25 and hybrid retrieval with Reciprocal Rank Fusion
> Retrieve documents that match exact terms and meaning, then merge lexical and vector rankings robustly.

**How it works.**

**BM25** scores document `D` for query terms `qᵢ`:

`score = Σ IDF(qᵢ) · f·(k₁+1) / (f + k₁·(1 − b + b·|D|/avgdl))`

- `f`: term frequency of `qᵢ` in `D`. Saturates via `k₁` (typically 1.2–2.0).
- `b` (typically 0.75): length normalization against the average document length `avgdl`.
- `IDF(q) = ln(1 + (N − n_q + 0.5)/(n_q + 0.5))`, where `n_q` is the number of documents containing `q`.

**Hybrid retrieval:**

1. Run BM25 and dense vector search in parallel, each returning its top `K` (e.g. 100).
2. Fuse with **Reciprocal Rank Fusion**: `RRF(d) = Σᵣ 1 / (k + rankᵣ(d))`, with `k = 60` by convention.
3. Optionally re-rank the fused top N with a cross-encoder or LLM.

```text
 query ─┬─▶ BM25   ─▶ ranks ─┐
        └─▶ vector ─▶ ranks ─┴─▶ RRF ─▶ rerank ─▶ top N
 doc ranked 1 & 3: 1/61 + 1/63 = 0.0323
```

RRF uses only ranks, so it needs no score normalization between incomparable scales (BM25 is unbounded; cosine is in [−1, 1]).

**Complexity.** BM25 runs on an inverted index; WAND or block-max WAND prune posting lists for sub-linear top-k. RRF is O(K) per list with a hash map. The dominant costs are the two retrievals and any cross-encoder re-ranking (O(N) model calls).

**Where you meet it.** Lucene, Elasticsearch and OpenSearch (BM25 default; RRF and hybrid query support), Vespa, Weaviate, Azure AI Search (RRF hybrid), Postgres full-text with pgvector, and most production RAG pipelines.

**Pitfalls.**

- Analyzer mismatch: tokenization, stemming and synonyms decide BM25 quality more than `k₁` and `b`.
- IDF computed per shard skews scores when term distributions differ across shards.
- RRF discards score magnitude: a confident top hit from one retriever counts the same as a marginal one. A tuned convex combination of normalized scores can beat it with labelled data.
- A retriever whose top-K is shallow contributes nothing beyond its depth.
- Evaluating on generic benchmarks instead of in-domain labelled queries.

**DE judgment.** Hybrid with RRF is the robust default for enterprise and RAG search: BM25 wins on identifiers, codes, names and rare terms; dense wins on paraphrase. Add a re-ranker when precision at the top matters.

Probe:

- Labelled evaluation set and metrics (nDCG@10, recall@100).
- Per-retriever contribution and an ablation.
- Analyzer configuration for the domain.
- Re-ranker latency budget.
- How freshness and access-control filters apply to both retrievers consistently.
