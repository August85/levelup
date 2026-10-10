# Networking

> At Distinguished level you own the outages nobody can localize, and most of those live in the network: in timeouts, retries, caches, and connection lifetimes that each team configured sensibly on its own.

## Overview

Most senior engineers treat the network as a function call with a latency distribution. That model holds until it doesn't. Then the incident is "intermittent 5-second stalls," "one AZ is slow but healthy," or "the new region doubled our error rate and nothing changed." Those incidents get escalated to the most senior person in the room. Increasingly that is you.

This volume covers networking at the level where you can reason about such failures from first principles. That means four things.

**Know the mechanisms.** How TCP opens a window and backs off. Why QUIC exists. What a resolver actually caches. How HTTP/2 multiplexing interacts with load balancers.

**Know where state lives.** Connection tables, DNS caches, CDN caches, conntrack entries, connection pools, and control-plane config. Each is a place where the system can disagree with itself.

**Know the cost model.** Round trips dominate latency far from the user. CPU dominates at the proxy. Memory dominates per-connection state. Blast radius dominates at the control plane.

**Know the failure shapes.** Networks rarely fail cleanly. They fail partially, asymmetrically, and in ways that health checks don't see. Retries, timeouts, and caches turn small faults into big ones.

The DE job is not to tune `tcp_rmem`. It is to set the defaults, budgets, and topologies that keep a thousand teams from creating the same incident independently, and to recognize the incident fast when they do anyway.

## Core Concepts

### TCP: the transport you inherit

TCP gives you an ordered, reliable byte stream over an unreliable packet network. Every property you rely on has a cost you pay in round trips, buffers, or head-of-line blocking.

**Connection setup costs round trips.** The three-way handshake costs one RTT before the first byte of data. TLS 1.3 adds one more RTT (TLS 1.2 added two). On a 100 ms transcontinental path, a cold HTTPS request costs at least 200 ms before the server sees the request. That is why connection reuse matters more than almost any server-side optimization for far-away clients.

**Slow start limits early throughput.** A new connection starts with a small congestion window. RFC 6928 set the common initial window to 10 segments, about 14 KB. The window roughly doubles each RTT until loss or a threshold. So a 1 MB response on a fresh connection takes several RTTs regardless of link bandwidth. Short-lived connections never leave slow start. This is why "we have 10 Gbps" says little about the latency of a 500 KB API response to a phone.

**Congestion control decides your tail.** Loss-based algorithms (Reno, CUBIC; CUBIC is the Linux default, RFC 9438) increase the window until packets drop, then back off. They fill buffers along the path before reacting. Deep router buffers therefore produce bufferbloat: high, variable queuing delay with no loss signal. BBR, from Google, models bottleneck bandwidth and minimum RTT instead and paces sending to match. BBR can dramatically improve throughput on lossy long paths. Early BBR versions had fairness problems when competing with CUBIC; later versions address this. Choose the algorithm per environment, and measure, rather than adopting it fleet-wide by fiat.

**Head-of-line blocking is inherent.** TCP delivers bytes in order. If one segment is lost, everything behind it waits for retransmission, even if it belongs to an unrelated logical request. Any protocol that multiplexes over one TCP connection inherits this.

**Retransmission timers shape stalls.** When a segment is lost and not enough later segments arrive to trigger fast retransmit, the sender waits for the retransmission timeout (RTO). Linux's minimum RTO is 200 ms, and it backs off exponentially. A lost SYN is worse: the initial SYN retransmit is 1 second. That is the origin of many mysterious "exactly 1 second" or "exactly 3 second" latency spikes.

**Nagle plus delayed ACK causes 40 ms stalls.** Nagle's algorithm holds small writes until the previous data is acknowledged. Delayed ACK holds the ACK hoping to piggyback it (Linux minimum about 40 ms). A write-write-read pattern on a request/response protocol deadlocks for one delayed-ACK interval. Set `TCP_NODELAY` for RPC traffic; nearly every modern RPC stack does.

**Connection teardown leaves state behind.** The side that closes first enters TIME_WAIT for 2×MSL (60 s on Linux). A client making many short connections to one destination exhausts ephemeral ports. The default Linux range is about 28,000 ports. At 500 new connections per second to a single backend IP and port, you run out in about a minute. Symptoms are `EADDRNOTAVAIL` or connect latency spikes. Fixes are pooling, more destination IPs, or `tcp_tw_reuse` for outbound connections, not `tcp_tw_recycle` (removed from Linux because it broke clients behind NAT).

**Keepalive is not liveness.** TCP keepalive defaults to two hours idle on Linux. A peer that vanished (host crash, NAT timeout, firewall state expiry) leaves the connection half-open. Your next write hangs until retransmissions give up, which can take many minutes. Application-level heartbeats or HTTP/2 PINGs with tight timeouts are the real liveness signal.

**Middleboxes hold state too.** NAT gateways, stateful firewalls, and Linux conntrack each keep per-flow entries with idle timeouts. When the middlebox forgets a flow before the endpoints do, the next packet is dropped or answered with RST. Cloud NAT idle timeouts of a few minutes routinely kill idle pooled connections. Rule: your pool's idle timeout must be shorter than every middlebox timeout on the path.

### QUIC: transport in user space

QUIC (RFC 9000, with TLS in RFC 9001 and loss recovery in RFC 9002) is a transport built on UDP. It exists because TCP could not evolve: kernels update slowly, and middleboxes ossified TCP by inspecting and rewriting its headers.

**What QUIC changes.**

- **Integrated handshake.** Transport and TLS 1.3 negotiate together. A new connection costs one RTT, not two.
- **0-RTT resumption.** A returning client can send application data in its first flight. That data is replayable by an attacker, so it is safe only for idempotent requests. Servers must enforce this; many disable 0-RTT for anything but GETs.
- **Independent streams.** Loss on one stream does not block others. Head-of-line blocking moves from the connection to the stream.
- **Encrypted transport headers.** Packet numbers and most metadata are encrypted. Middleboxes cannot ossify the protocol, and they also cannot help you debug it.
- **Connection IDs.** A connection is identified by an ID, not the 4-tuple. A phone moving from Wi-Fi to cellular keeps its connection.

**What QUIC costs.**

- **CPU.** Without kernel TCP offloads (TSO, checksum offload, decades of tuning), early QUIC deployments used noticeably more CPU per byte. UDP GSO/GRO and batching (sendmmsg) close much of the gap but not all of it.
- **UDP blocking.** Some enterprise networks block or rate-limit UDP 443. Clients must race or fall back to TCP. You run both stacks forever.
- **Load balancing.** Connection migration breaks 4-tuple hashing. An L4 load balancer must route by connection ID, which means the server must encode routing information into the IDs it issues. The IETF QUIC-LB work standardizes this coordination.
- **Observability.** You lose passive RTT and retransmit visibility from packet captures. You need endpoint logging (the qlog format) instead.

**When QUIC wins.** Lossy, high-RTT, mobile last-mile paths, where handshake savings and stream independence are measurable. Google's SIGCOMM 2017 paper reported the biggest gains for the slowest users. Inside a data center, with sub-millisecond RTT and near-zero loss, the gains are small and the CPU cost is real. Most east-west traffic should stay on TCP.

### TLS as part of the network

TLS is now the default on every hop, including inside the data center. Its costs and failure modes belong in the networking model.

**Handshake cost.** TLS 1.3 needs one RTT for a full handshake. Session resumption via tickets avoids certificate exchange and asymmetric crypto. If you terminate TLS on a fleet, ticket keys must be shared and rotated across the fleet, or resumption silently fails on every load-balancer hop to a different node.

**Certificates are a time bomb.** Expiry is the single most common self-inflicted TLS outage. Automated issuance (ACME) and expiry monitoring on every endpoint, including internal ones, is the baseline. Trust-store changes are the subtler version: the September 2021 expiry of the DST Root CA X3 certificate broke older clients that could not build the alternate chain.

**mTLS gives you identity, not authorization.** Mutual TLS proves which workload is calling. It says nothing about what that workload may do. Meshes make mTLS cheap; they don't make policy correct.

### DNS: the distributed cache you forgot you run

DNS (RFC 1034/1035) maps names to records through a hierarchy of delegations. In practice it is a globally distributed, eventually consistent cache whose consistency you don't control.

**The resolution chain.** An application calls a stub resolver (glibc, the JVM, Go's resolver). The stub asks a recursive resolver (a local daemon, the VPC resolver, an ISP, or a public resolver). The recursive resolver walks root, TLD, and authoritative servers, caching each answer for its TTL.

```text
app -> stub -> recursive -> root
                   |     -> TLD (.com)
                   |     -> authoritative
                   v
           cache (per TTL)
```

**TTLs are a request, not a contract.** Recursive resolvers may clamp TTLs to a minimum. Clients may cache longer. The JVM historically cached forever when a security manager was installed, and many runtimes and connection pools resolve once and hold the IP for the life of the connection. A 60-second TTL does not mean traffic moves in 60 seconds. Plan for a long tail of stale clients on any DNS-based failover.

**Negative caching.** NXDOMAIN answers are cached too (RFC 2308), for a duration derived from the zone's SOA record. If you query a name before creating it, resolvers may keep answering "doesn't exist" for the negative TTL. This bites deploy pipelines that check for a record before it is published.

**Size and transport.** Classic DNS over UDP is limited to 512 bytes. EDNS0 allows larger responses, but fragmented UDP is unreliable, so the 2020 DNS Flag Day recommended a 1,232-byte buffer. Larger answers set the truncation bit and the client retries over TCP. If TCP 53 is blocked, large responses (many A records, DNSSEC) fail mysteriously.

**DNS as a load balancer.** Returning multiple A records or steering by geography (GSLB) works for coarse placement. It is a weak tool for fine-grained balancing. You can't see load, clients cache unevenly, and a large recursive resolver aggregates thousands of users behind one cached answer. EDNS Client Subnet (RFC 7871) gives the authoritative server a hint of the client's location at the cost of cache efficiency and privacy.

**Kubernetes specifics.** Pods get `ndots:5` by default. Any name with fewer than five dots is first tried against each search domain. A lookup of `api.example.com` can generate several failing queries (times two for A and AAAA) before the real one. Use fully qualified names with a trailing dot, or lower `ndots`, for external names in hot paths.

**The conntrack race.** On Linux, glibc sends A and AAAA queries in parallel from the same UDP socket. Under NAT via conntrack, a race can drop one of them. The stub then waits its default 5-second timeout. "Random 5-second latency" in containers is very often this. Mitigations: node-local DNS caches, `single-request-reopen`, or TCP for DNS.

**Modern records.** The HTTPS/SVCB record (RFC 9460) lets a client learn ALPN (for example, HTTP/3 support), alternative endpoints, and ECH keys in the DNS lookup itself, avoiding an extra round trip or an Alt-Svc upgrade dance.

**DNS is a dependency of everything.** Including your recovery tooling. If your auth, deploy, and paging systems resolve names through the same provider that is down, you can't fix it. Second-provider authoritative DNS and cached critical records are cheap insurance.

### HTTP/1.1, HTTP/2, and HTTP/3

HTTP semantics (methods, status codes, headers, caching) are defined once in RFC 9110 and RFC 9111. The versions differ only in how messages ride the transport, but that difference drives most of the operational behavior.

**HTTP/1.1.** One outstanding request per connection (pipelining exists but is effectively unusable). Browsers open about six connections per origin. Servers and proxies handle many short connections. Simple, debuggable, and load-balances naturally because connections are numerous and short.

**HTTP/2 (RFC 9113).** Many concurrent streams over one TCP connection, binary framing, HPACK header compression, and per-stream and per-connection flow control.

- **Fewer, longer connections.** This is the change with the most operational impact. An L4 load balancer balances connections, not requests. With HTTP/2, a client may hold one connection to one backend for hours. New backends get no traffic; a hot client pins one backend. gRPC is the canonical victim.
- **TCP head-of-line blocking.** Multiplexing over one TCP connection means one lost packet stalls every stream. Under loss, HTTP/2 can be slower than six HTTP/1.1 connections.
- **Flow control windows.** Default stream windows of 64 KB throttle large transfers on high-BDP paths unless raised. Misconfigured windows look like a bandwidth ceiling with idle CPU and network.
- **GOAWAY for graceful drain.** A server can tell a client to stop opening new streams on a connection. Correct drain during deploys depends on clients honoring it and reconnecting.
- **New attack surface.** The 2023 "Rapid Reset" attack (CVE-2023-44487) opened and immediately cancelled streams, generating server work without hitting concurrency limits. It produced record-size DDoS attacks and forced patches across every HTTP/2 implementation.

**HTTP/3 (RFC 9114).** HTTP over QUIC, with QPACK (RFC 9204) replacing HPACK because QUIC streams arrive out of order. You get stream independence and faster handshakes. Discovery happens via the `Alt-Svc` header or an HTTPS DNS record; the first visit is usually HTTP/2.

**Version per hop.** Each hop chooses independently. A typical stack is HTTP/3 or HTTP/2 from client to edge, HTTP/2 or HTTP/1.1 from edge to origin, and HTTP/2 (gRPC) east-west. Write that chain down. Protocol translation at each proxy is where header limits, trailers, timeouts, and streaming semantics silently change.

### Proxies: where policy and pain concentrate

A proxy terminates one connection and originates another. That simple fact explains most of its value and most of its failure modes.

**Types.** Forward proxies act for clients (egress control). Reverse proxies act for servers (ingress, TLS termination, routing). Sidecars are reverse and forward proxies colocated with each workload. API gateways are reverse proxies with auth, quotas, and transformation.

**What a proxy gives you.**

- Connection pooling and multiplexing to backends, so clients' connection churn doesn't hit servers.
- A single place for TLS, auth, rate limits, retries, timeouts, and telemetry.
- Decoupling client protocol from backend protocol.
- Request-level routing (path, header, weight) for canaries and migrations.

**What a proxy costs.**

- **Latency per hop.** Often well under a millisecond at the median for a local L7 proxy, but tail latency adds up, especially with GC, CPU throttling, or buffer copies.
- **Two of everything.** Two connection pools, two sets of timeouts, two TLS sessions. Each must be configured consistently with its neighbors.
- **Buffering semantics.** A proxy that buffers whole requests or responses breaks streaming, adds memory pressure, and changes latency. A proxy that doesn't buffer exposes backends to slow clients (slowloris).
- **Lost client identity.** The backend sees the proxy's IP. You must carry the client address in `X-Forwarded-For` / `Forwarded` (L7) or the PROXY protocol (L4). Then you must trust those headers only from your own proxies, or clients can spoof them.

**Request smuggling.** When two HTTP/1.1 parsers in a chain disagree on where a request ends (conflicting `Content-Length` and `Transfer-Encoding`, for example), an attacker can hide a second request inside the first. The back end then attributes it to the next user's connection. James Kettle's 2019 "HTTP Desync Attacks" research showed this across major CDNs. Defenses: normalize or reject ambiguous requests at the edge, and prefer HTTP/2 end to end.

**Timeouts must nest.** Each layer's timeout should be slightly shorter than the layer above it. If the edge gives up at 30 s while the backend proxy waits 60 s, the backend keeps working on requests nobody will read. If the inner timeout is longer, a slow dependency consumes capacity long after the user left.

```text
client 10s > edge 9s > mesh 8s > svc 7s > db 5s
```

### L4 and L7 load balancing

Load balancing is two decisions: which backend gets this unit of work, and how you know the backend is healthy. The layer determines what the unit of work is.

**L4 (transport).** Balances connections or packets by 5-tuple. It doesn't parse HTTP. It can be extremely fast and scale to millions of packets per second per node.

- **ECMP plus consistent hashing.** Routers spread packets across LB nodes with ECMP. Each LB node hashes the flow to a backend. Google's Maglev (NSDI 2016) used a consistent hashing table so that any LB node picks the same backend for a flow, and adding or removing LB nodes moves few flows. Facebook's Katran uses a similar design with XDP/eBPF.
- **Direct server return (DSR).** The backend replies straight to the client, bypassing the LB. Responses are usually much larger than requests, so this multiplies LB capacity. The cost: the LB never sees responses, so it cannot measure latency or errors.
- **Connection tracking.** Stateful L4 LBs remember flow-to-backend mappings, so backend set changes don't break live connections. That table is finite and can be exhausted by SYN floods.

```text
          ECMP
client --> router --+--> LB1 --+
                    +--> LB2 --+--> backends
                    +--> LB3 --+   (DSR reply
                                    to client)
```

**L7 (application).** Terminates the connection and balances individual requests. It can route by path or header, retry, and observe latency and status per request.

- **Required for multiplexed protocols.** HTTP/2 and gRPC need L7 balancing (or client-side balancing) to spread requests, not connections.
- **Costs CPU and adds a hop.** TLS termination and parsing are far more expensive than packet forwarding.
- **Sees everything.** That makes it the right place for outlier detection, retries, and request-level metrics, and the right place for a bad config to break everything.

**Balancing algorithms.**

- **Round robin.** Fine for homogeneous backends and uniform requests. Fails with heterogeneous request costs.
- **Least outstanding requests.** Adapts to slow backends. Needs accurate counts, which a fleet of independent LB nodes doesn't have globally.
- **Power of two choices (P2C).** Pick two backends at random, send to the less loaded. Mitzenmacher showed this reduces maximum load exponentially compared to one random choice, and it needs only local, stale information. It is the default in Envoy and Finagle-derived systems for good reason.
- **Latency-weighted (EWMA).** Weights by recent latency. Responsive, but beware feedback: a backend that fails fast looks attractive.
- **Consistent hashing / ring hash.** For cache affinity. Accept worse balance and hot keys in exchange for locality.

**Health checking.** Active checks probe an endpoint; passive checks (outlier detection) eject backends that return errors in real traffic. Use both. Active checks catch dead backends with no traffic. Passive checks catch backends that pass `/health` but fail real requests.

**Panic thresholds.** If too many backends look unhealthy, the problem is probably the checker or a shared dependency. Envoy's default panic threshold is 50%: below it, the LB ignores health and spreads to all backends. Without this, a health-check false positive concentrates all traffic on the few "healthy" hosts and kills them.

**Slow start for backends.** A new instance with cold caches and an unwarmed JIT can't take its full share immediately. Ramp its weight over tens of seconds.

**Client-side balancing.** Clients resolve backends from a registry (DNS, xDS) and balance themselves. It removes a hop and a central bottleneck. You trade that for logic in every client library, in every language, at every version.

### Service mesh

A service mesh moves cross-cutting network behavior (mTLS, retries, timeouts, routing, telemetry) out of application code and into infrastructure.

**Architecture.** A data plane of proxies handles traffic. A control plane (Istio's istiod, Linkerd's controller) computes config and pushes it to proxies, commonly over Envoy's xDS APIs.

```text
     +--------------+
     | control plane|  (certs, routes, xDS)
     +------+-------+
            | push
   +--------+--------+
   v                 v
[svc A|proxy] --> [proxy|svc B]
        mTLS, retries, metrics
```

**Data plane models.**

- **Sidecar.** One proxy per pod. Strong isolation and full L7 features. Costs CPU and memory per pod (multiplied by every pod in the fleet), adds two proxy hops per call, and complicates pod lifecycle (startup ordering, draining).
- **Per-node or ambient.** Istio's ambient mode uses a per-node L4 proxy (ztunnel) for mTLS and optional per-service L7 "waypoint" proxies. Lower resource overhead and no pod restarts to upgrade the mesh. Weaker tenant isolation on the node and a larger blast radius per proxy.
- **Proxyless.** gRPC clients consume xDS directly. No extra hop and lowest overhead. Only works for one protocol and requires consistent library versions.
- **Library (no mesh).** Finagle-style RPC frameworks. Most efficient, but every policy change is a fleet-wide redeploy in every language.

**What a mesh actually buys.**

- **Workload identity.** SPIFFE-style IDs and automated certificate rotation. This is often the strongest justification.
- **Uniform telemetry.** Golden signals for every edge without code changes.
- **Traffic management.** Weighted routing, fault injection, and per-route timeouts without redeploys.

**What it costs.**

- **Control-plane scaling.** Every endpoint change can trigger config pushes to every proxy. In a large cluster, naive full-mesh config gives each proxy state proportional to the whole cluster. Scope config to declared dependencies (Istio's `Sidecar` resource, for example).
- **Control-plane blast radius.** A bad push reaches every proxy within seconds. Proxies should keep last-known-good config if the control plane disappears, and pushes should be staged.
- **Policy in two places.** Retries in the mesh plus retries in the app multiply. A DE must decide which layer owns which policy.
- **Debuggability.** Every request now crosses several proxies. "503 UF" from Envoy has to be learned like a new language.

### CDN and edge

A CDN is a geographically distributed reverse proxy cache. Its value is cutting RTT to the user, absorbing load and attacks, and terminating TLS close to the client.

**Routing users to the edge.** Two main techniques. Anycast announces the same IP prefix from many locations and lets BGP pick the nearest. It's simple and fails over automatically, but BGP's notion of "near" is about routing policy, not latency, and route changes can move live TCP connections mid-flight. DNS steering returns different IPs per resolver location. It's controllable, but subject to resolver caching and resolver-location inaccuracy.

**Cache correctness.**

- **Cache key.** URL plus whatever headers you add. Too narrow and you serve one user's content to another. Too wide (including cookies or a raw `User-Agent`) and the hit ratio collapses.
- **`Vary`.** Tells caches which request headers change the response. `Vary: Cookie` effectively disables shared caching.
- **Freshness.** `Cache-Control: max-age` and `s-maxage` set lifetimes. `stale-while-revalidate` serves stale content while refreshing in the background. `stale-if-error` serves stale content when the origin fails (both RFC 5861). The latter turns your CDN into an availability layer.
- **Cache poisoning.** If an unkeyed header (for example `X-Forwarded-Host`) influences the response, an attacker can poison the cached copy for everyone.

**Origin protection.**

- **Request collapsing.** Concurrent misses for the same object become one origin fetch. Without it, a popular object's expiry is a thundering herd.
- **Origin shield.** A middle cache tier that all edges miss through, so the origin sees one miss per object rather than one per edge location.
- **Lock down the origin.** Accept traffic only from the CDN (mTLS, signed headers, or allowlisted ranges). Otherwise attackers bypass the CDN and its DDoS protection.

**Hit ratio math.** Origin load is total traffic times miss ratio. Going from 95% to 90% hit ratio doubles origin load. Treat a cache-key change or a mass purge as a load test against the origin.

**Purge is a distributed operation.** Purges take time to propagate, may partially fail, and mass purges cause miss storms. Prefer versioned URLs for static assets, and tag-based purges for dynamic content.

**Edge compute.** Running code at the edge (for auth, personalization, A/B routing) moves logic close to users. It also moves your deploy pipeline to hundreds of locations with a different runtime, different limits, and a different debugging story.

### Network failure analysis

Network failures are rarely clean. They are partial, intermittent, asymmetric, and misreported by health checks. Analysis is a discipline of narrowing scope and reading the signature.

**Gray failure.** Huang et al. (HotOS 2017) named the pattern: a component is unhealthy from the perspective of its clients but healthy from the perspective of the failure detector. A switch that drops 2% of packets passes ping-based checks. A host whose NIC has a bad queue answers `/health` fine but times out 5% of real requests. The fix is to observe health from the client's perspective: passive outlier detection, per-path error metrics, and probes that exercise the real data path.

**Read the latency signature.**

| Symptom | Likely cause |
|---|---|
| ~1 s, 3 s steps | SYN loss and retransmit |
| ~200 ms steps | RTO after data loss |
| ~40 ms adds | Nagle + delayed ACK |
| ~5 s stalls | DNS stub timeout |
| Large uploads hang | MTU black hole |

**MTU black holes.** Path MTU discovery relies on ICMP "fragmentation needed" messages. If a firewall drops ICMP, large packets vanish silently while small ones (handshakes, small requests) work. Tunnels and overlays (VXLAN, IPsec, GRE) reduce the effective MTU and trigger this. Fixes: clamp MSS at tunnel boundaries, allow the right ICMP, or use packetization-layer PMTUD (RFC 8899). QUIC requires paths to carry at least 1,200-byte UDP payloads.

**Incast.** Many senders reply to one receiver at the same moment (a scatter-gather fan-out). Shallow switch buffers overflow, packets drop, and TCP waits a full RTO. Throughput collapses and p99 jumps by hundreds of milliseconds. Mitigations: limit fan-out concurrency, jitter responses, use data-center TCP variants (DCTCP), and choose switches with adequate buffering.

**Resource exhaustion on the host.** Many "network" incidents are table overflows: conntrack full (`nf_conntrack: table full, dropping packet` in the kernel log), SYN backlog overflow, ephemeral ports, file descriptors, NIC ring buffer drops. Each has a counter. Know where those counters are before the incident.

**Retry amplification.** If each of four layers retries three times, one user request can become 3⁴ = 81 attempts at the bottom layer. During a partial outage, retries raise load on the struggling service exactly when it can least absorb it. This is the most common mechanism behind metastable failures (Bronson et al., HotOS 2021): the system stays down after the trigger is removed, because the retry load alone keeps it saturated.

**The method.**

1. **Scope first.** Which clients, which destinations, which AZs, which protocol, since when. Partition the population until the fault sits in one cell.
2. **Find the asymmetry.** Compare healthy and unhealthy flows. Same backend, different client? Same client, different path?
3. **Check the counters.** Retransmits (`ss -ti`, `nstat`), drops (`ethtool -S`, `netstat -s`), conntrack, DNS latency.
4. **Capture at both ends.** A packet capture on one side tells you what it sent; both sides tell you what the network did.
5. **Correlate with change.** Config pushes, certificate rotations, route changes, and kernel updates cause more network incidents than hardware.

## Design Principles

- **Round trips are the currency.** For anything far from the user, latency is dominated by RTT count, not bandwidth or server time. Count handshakes, redirects, DNS lookups, and sequential fetches in every critical user path, and design to remove them.
- **Reuse connections, but bound their lifetime.** Pooling avoids handshakes and slow start. Unbounded lifetimes break load balancing, pin traffic to stale backends, and outlive middlebox state. Set a maximum connection age with jitter, and an idle timeout shorter than any NAT or firewall on the path.
- **Timeouts nest, and every call has one.** No network call without a deadline. Each layer's timeout is shorter than its caller's. Propagate deadlines (gRPC does this natively) so downstream work stops when the user has gone.
- **Retry at one layer, with a budget.** Choose one layer to own retries for each call path. Cap retries per request and as a fraction of total traffic (around 10% is a common budget). Retry only idempotent operations, with exponential backoff and jitter.
- **Health is what the client experiences.** Liveness probes check that a process exists. Readiness must reflect the ability to serve real traffic. Combine active checks with passive outlier detection, and set panic thresholds so a broken checker can't concentrate load.
- **Balance the unit of work you care about.** If requests vary in cost or ride multiplexed connections, balance requests at L7 or in the client, not connections at L4. Use P2C or least-request over round robin.
- **Design for partial failure, not binary failure.** Assume gray failure. Detect slow as well as dead. Prefer mechanisms that degrade (shed load, serve stale) over ones that cliff.
- **Cache is an availability layer, not just a speed layer.** `stale-if-error`, request collapsing, and origin shields let you survive origin outages. Treat cache-key and TTL changes as production changes with load implications.
- **Know who caches your DNS.** TTLs are advisory. Any failover based on DNS must assume a long tail of clients on old answers. Use anycast or LB-level failover when you need seconds, not minutes.
- **Control planes fail static.** Proxies, sidecars, and edges must keep serving with last-known-good config when the control plane is unreachable. A control-plane outage should freeze changes, not stop traffic.
- **Stage config like code.** Network config (routes, mesh policy, WAF rules, CDN rules, BGP) has a blast radius equal to its reach. Canary it per cell or region with automated rollback, exactly like a binary.
- **Make the client's address and identity explicit.** Carry original client IP and workload identity through every hop, trust those signals only from your own infrastructure, and authenticate service-to-service traffic with mTLS.
- **Instrument the transport.** Export retransmits, RTT, connection counts, pool saturation, DNS latency, and TLS handshake errors as first-class metrics. You can't debug what you only see in a pcap.

## Trade-offs and Decision Frameworks

### TCP vs QUIC

| Factor | TCP + TLS | QUIC |
|---|---|---|
| Handshake | 2 RTT | 1 RTT (0 resumed) |
| HOL blocking | Connection | Per stream |
| CPU per byte | Low (offload) | Higher |
| Mobility | New conn | Survives |
| Debuggability | Mature | Needs qlog |

**Decision.** Use QUIC/HTTP/3 at the user-facing edge, especially for mobile and global audiences, usually via a CDN or edge proxy that already supports it. Keep TCP for east-west traffic unless you have measured loss and RTT that justify the CPU. Always keep the TCP fallback.

### L4 vs L7 load balancing

| Factor | L4 | L7 |
|---|---|---|
| Unit | Connection | Request |
| Cost | Very low | TLS + parse |
| Visibility | Bytes, flows | Status, latency |
| Features | Hashing, DSR | Routing, retries |

**Decision.** Layer them. L4 (anycast/ECMP plus a Maglev-style balancer) in front for raw scale and DDoS absorption. L7 behind it for request-aware routing. For gRPC and other HTTP/2 traffic, never rely on L4 alone; use L7 or client-side balancing, or at least cap connection age.

### Mesh data plane

| Model | Overhead | Isolation | Best when |
|---|---|---|---|
| Sidecar | High | Strong | Polyglot, strict |
| Ambient | Medium | Node-level | Large, cost-aware |
| Proxyless | Low | In-process | gRPC-only |
| Library | Lowest | In-process | One language |

**Decision questions.**

1. **What problem forces the mesh?** If the answer is mTLS identity across many languages, a mesh is justified. If it is "observability," consider whether existing tracing libraries already give it.
2. **How many languages and runtimes?** One language with a strong RPC framework favors a library. Many languages favor proxies.
3. **What is the fleet-wide cost?** Multiply per-pod proxy memory and CPU by pod count. Compare with the engineering cost of maintaining libraries.
4. **Who operates the control plane?** A mesh is a tier-0 platform. If no team can run it at that bar, don't adopt it.

### Traffic steering

| Technique | Failover speed | Control |
|---|---|---|
| DNS / GSLB | Minutes (tails) | High |
| Anycast BGP | Seconds | Coarse |
| L7 global LB | Seconds | Fine |
| Client-side | Per request | Finest |

**Decision.** Anycast for the edge entry point. L7 or client-side for routing between regions and backends. DNS for coarse geography and for things that tolerate slow convergence. Never make DNS your only failover mechanism for a tier-0 service.

### Where to put retries

Retry at the layer closest to the failure that still knows whether the operation is idempotent. Usually that is the client of the failing service, implemented once (in the mesh or the RPC library), with a budget. Edge and user-facing layers should generally not retry non-idempotent requests at all. Hedged requests (send a second copy after the p95 latency) cut tail latency but add load; restrict them to idempotent reads with a small hedge budget, as described in "The Tail at Scale."

### A general framework for networking decisions

1. **Draw the full path.** Client, resolver, edge, LBs, proxies, service, dependencies. Note protocol, TLS termination, and timeout at every hop.
2. **Count round trips** on the critical user path for a cold and a warm client.
3. **Locate every cache and every table.** DNS, CDN, connection pools, conntrack, NAT. Note TTLs and capacity.
4. **Place each policy once.** Retries, timeouts, auth, rate limits. If a policy appears at two layers, justify it.
5. **Ask how each component fails partially.** Slow, lossy, half of instances, one AZ. What detects it, and what does load do next?
6. **Estimate the blast radius of a bad config push** for each control plane on the path.

## Failure Modes and War Stories

### Dyn DDoS, October 2016

The Mirai botnet, made of compromised IoT devices, flooded Dyn's managed DNS infrastructure. Many large sites that used Dyn as their only authoritative provider became unreachable for large parts of the US, even though their own servers were fine.

**Lesson.** Authoritative DNS is a tier-0 dependency. Use two independent providers for critical zones, and keep TTLs on critical records long enough that resolvers can ride out a short provider outage.

### Cloudflare WAF regex, July 2019

A new WAF rule contained a regular expression that backtracked catastrophically. Deployed globally at once, it pushed CPU to 100% on servers handling HTTP traffic across Cloudflare's network, causing widespread 502 errors for about half an hour.

**Lesson.** Edge config is code with global reach. It needs staged rollout, CPU guards, and fast kill switches. Cloudflare's post-incident fixes included staged rollouts for WAF rules and a regex engine with linear-time guarantees.

### Fastly, June 2021

A valid configuration change by one customer triggered a latent bug introduced in a software deploy weeks earlier. Most of Fastly's network began returning errors, taking down many major news and commerce sites for under an hour.

**Lesson.** Shared multi-tenant edge infrastructure concentrates risk. One tenant's input can be a global trigger. For your own systems: fuzz config paths, bound blast radius by cell, and for critical properties consider multi-CDN with tested failover.

### Facebook backbone and BGP, October 2021

During routine maintenance, a command meant to assess backbone capacity unintentionally disconnected Facebook's data centers from each other. An audit tool that should have blocked it had a bug. Facebook's DNS servers were designed to withdraw their BGP anycast advertisements when they could not reach the data centers. They did so, and Facebook's DNS disappeared from the internet. Recovery was slow because internal tools and physical access systems depended on the same network.

**Lesson.** A health-based self-withdrawal that is correct for one node is catastrophic when every node withdraws at once. Add global "don't withdraw the last N" guards. Out-of-band management access must not depend on the production network or DNS.

### AWS us-east-1, December 2021

An automated scaling activity in AWS's internal network triggered unexpected behavior from a large number of clients. That caused a surge of connection activity that congested devices between the internal network and the main AWS network. Retries prolonged the congestion. Internal monitoring was itself impaired, slowing diagnosis.

**Lesson.** Retry storms and reconnect storms are the classic metastable amplifier. Clients need backoff with jitter and retry budgets, and monitoring needs a path that doesn't share the failing network.

### Recurring patterns you will see internally

**The gRPC hot spot.** A service scales from 10 to 30 pods. Latency doesn't improve. The new pods are idle. Cause: clients hold long-lived HTTP/2 connections opened when there were 10 pods, through an L4 balancer. Fix: L7 or client-side balancing, plus server-side max connection age with jitter.

**The 5-second DNS tail.** p99 latency in a container platform shows a spike at exactly 5 seconds. Cause: dropped DNS UDP packet (conntrack race or overloaded resolver) plus the stub's 5-second retry timeout. Fix: node-local DNS cache, lower `ndots`, and connection reuse so lookups leave the hot path.

**The idle-connection reset.** After quiet periods (nights, weekends), the first requests fail with connection reset or hang. Cause: a NAT gateway or firewall dropped idle flow state before the pool closed the connection. Fix: pool idle timeout below the middlebox timeout, or TCP keepalive tuned below it.

**Ephemeral port exhaustion.** A batch job or a proxy without pooling opens a new connection per request to one backend VIP. Connect errors start once TIME_WAIT sockets consume the port range. Fix: pooling, more destination IPs, `tcp_tw_reuse`.

**Conntrack table full.** A traffic spike or SYN flood fills the kernel's connection tracking table. New flows drop silently while established ones continue, so health checks over persistent connections stay green. Fix: size the table, monitor its utilization, and exempt high-volume stateless traffic from tracking.

**Health-check cascade.** A shared dependency (a database, an auth service) slows down. Every backend's deep health check fails. The LB ejects all of them, and the service goes from degraded to fully down. Fix: shallow readiness checks for LB decisions, panic thresholds, and dependency health reported as metrics, not as liveness.

**The MTU surprise after a migration.** A move to an overlay network or a VPN works in testing. In production, large responses and TLS handshakes with long certificate chains hang. Cause: reduced MTU with ICMP filtered. Fix: MSS clamping and correct ICMP policy.

**Certificate expiry.** An internal certificate nobody tracked expires. Every client fails TLS at once. This is the most common, most embarrassing, and most preventable outage in this volume. Fix: automated issuance, inventory, and alerting at 30 and 7 days.

**Cache-key regression.** A change adds a header to the cache key or sets `Vary` too broadly. Hit ratio drops from 95% to 60%, origin traffic rises eightfold, and the origin falls over at peak. Fix: treat cache config as a capacity-affecting change, and alert on hit ratio.

## What a DE Probes

- **"Draw the full request path from a user's device to the database. Where is TLS terminated, and what protocol is each hop?"** A good answer names every hop, including CDN, LBs, mesh proxies, and resolvers, and knows where protocols translate. Hesitation here predicts debugging pain later.
- **"What is the timeout at each hop, and how do they relate?"** Good: timeouts strictly nest, deadlines propagate, and someone has checked the actual config. Bad: defaults everywhere, or inner timeouts longer than outer ones.
- **"Who retries, how many times, and what caps total retries?"** Good: one owning layer per path, idempotency known, exponential backoff with jitter, a retry budget. Bad: retries in the SDK, the mesh, and the gateway simultaneously.
- **"How does traffic balance across backends when you scale out?"** Good: request-level balancing for HTTP/2 and gRPC, max connection age, and slow start for new instances. Watch for L4-only balancing of long-lived connections.
- **"What happens when half your backends are slow, not dead?"** Good: passive outlier detection, latency-aware balancing, load shedding, panic thresholds. Bad: "the health check will remove them."
- **"How fast can you move traffic away from a bad region, and what mechanism does it?"** Good: a tested L7 or anycast mechanism with a measured time, plus awareness of DNS-cache tails. Bad: "we change DNS" with no measurement.
- **"What does your system depend on for name resolution, and what happens if that provider is down?"** Good: redundant authoritative DNS for critical zones, local resolver caching, and recovery tools that don't need production DNS.
- **"What state do middleboxes keep for your flows, and with what timeouts?"** Good: knows NAT and firewall idle timeouts and sets pool idle timeouts below them. Knows conntrack capacity on nodes.
- **"What is your cache hit ratio, and what happens to origin load if it drops ten points?"** Good: knows the number, has computed origin headroom, uses request collapsing and an origin shield, and has `stale-if-error`.
- **"If your control plane disappears for an hour, what breaks?"** Good: data plane keeps serving with last-known-good config; only changes are blocked. Bad: certificates expire, or proxies drop config.
- **"How is a bad mesh, CDN, or LB config push contained?"** Good: staged rollout by cell or region, automated validation, fast rollback, and a kill switch. Bad: global push with manual monitoring.
- **"Why this protocol?"** For QUIC, HTTP/2, or a custom protocol, a good answer cites measured loss, RTT, and CPU data from this workload, not general enthusiasm.
- **"What network metrics would tell you this service is in trouble before users do?"** Good: retransmit rate, connection errors, pool saturation, DNS latency, TLS failures, per-AZ error splits.
- **"How do you know the caller is who it claims to be, and how is the original client IP preserved?"** Good: mTLS with workload identity, plus forwarded headers trusted only from known proxies.

## Review Checklist

- [ ] The end-to-end request path is documented: hops, protocols, TLS termination points
- [ ] Round trips on the cold critical path are counted and justified
- [ ] Every network call has a timeout, and timeouts nest from outer to inner
- [ ] Deadlines propagate across service boundaries
- [ ] Exactly one layer owns retries per call path
- [ ] Retries are limited to idempotent operations, with backoff, jitter, and a budget
- [ ] HTTP/2 and gRPC traffic is balanced per request (L7 or client-side), not only per connection
- [ ] Servers enforce a maximum connection age with jitter
- [ ] Pool idle timeouts are shorter than NAT, firewall, and LB idle timeouts on the path
- [ ] Health checks distinguish liveness from readiness and avoid deep dependency checks
- [ ] Passive outlier detection is enabled alongside active health checks
- [ ] Panic thresholds prevent health-check failures from concentrating load
- [ ] New instances ramp traffic with slow start
- [ ] Load shedding exists for overload, with priority for critical traffic
- [ ] Regional failover mechanism is identified, tested, and its time measured
- [ ] DNS-based failover accounts for resolver and client cache tails
- [ ] Critical zones use redundant authoritative DNS providers
- [ ] Container DNS is tuned (node-local cache, `ndots`, FQDNs on hot paths)
- [ ] CDN cache keys and `Vary` are reviewed; hit ratio is monitored and alerted
- [ ] `stale-if-error`, request collapsing, and origin shield are configured where appropriate
- [ ] Origin accepts traffic only from the CDN or edge
- [ ] Certificates are automatically issued, inventoried, and alerted before expiry
- [ ] TLS session ticket keys are shared and rotated across the terminating fleet
- [ ] Forwarded client IP headers are set by the edge and trusted only from internal proxies
- [ ] Ambiguous HTTP/1.1 requests are rejected or normalized at the edge
- [ ] Control-plane outages leave the data plane serving last-known-good config
- [ ] Network config changes (mesh, LB, CDN, WAF, BGP) roll out in stages with rollback
- [ ] MTU is validated across tunnels and overlays; MSS clamping is in place where needed
- [ ] Conntrack, ephemeral ports, SYN backlog, and NIC drops are monitored on hosts
- [ ] Transport metrics (retransmits, RTT, connection errors) are exported and dashboarded
- [ ] Out-of-band access and incident tooling don't depend on the production network or DNS
- [ ] QUIC/HTTP/3 deployments keep a tested TCP fallback, and 0-RTT is limited to idempotent requests

## Further Reading

**Foundations**

- W. Richard Stevens and Kevin Fall, *TCP/IP Illustrated, Volume 1: The Protocols* (2nd ed.). The reference for how the stack actually behaves.
- Ilya Grigorik, *High Performance Browser Networking* (O'Reilly; free at hpbn.co). Latency, TCP, TLS, HTTP/2 from the client's point of view.
- Van Jacobson, "Congestion Avoidance and Control," SIGCOMM 1988. The origin of TCP congestion control.
- Jim Gettys and Kathleen Nichols, "Bufferbloat: Dark Buffers in the Internet," ACM Queue, 2011.
- Neal Cardwell et al., "BBR: Congestion-Based Congestion Control," ACM Queue, 2016.

**Protocol specifications**

- RFC 9293, Transmission Control Protocol (consolidated TCP specification).
- RFC 6928, Increasing TCP's Initial Window.
- RFC 9438, CUBIC for Fast and Long-Distance Networks.
- RFC 8446, The Transport Layer Security (TLS) Protocol Version 1.3.
- RFC 9000, 9001, 9002: QUIC transport, QUIC-TLS, and QUIC loss detection and congestion control.
- RFC 9110 (HTTP Semantics), RFC 9111 (HTTP Caching), RFC 9113 (HTTP/2), RFC 9114 (HTTP/3), RFC 9204 (QPACK).
- RFC 1034 and RFC 1035, Domain Names; RFC 2308, Negative Caching of DNS Queries; RFC 7871, Client Subnet in DNS Queries; RFC 9460, SVCB and HTTPS DNS records.
- RFC 5861, HTTP Cache-Control Extensions for Stale Content.
- RFC 8899, Packetization Layer Path MTU Discovery.

**Systems papers**

- Adam Langley et al., "The QUIC Transport Protocol: Design and Internet-Scale Deployment," SIGCOMM 2017.
- Daniel E. Eisenbud et al., "Maglev: A Fast and Reliable Software Network Load Balancer," NSDI 2016.
- Michael Mitzenmacher, "The Power of Two Choices in Randomized Load Balancing," IEEE TPDS, 2001.
- Jeffrey Dean and Luiz André Barroso, "The Tail at Scale," Communications of the ACM, 2013.
- Peng Huang et al., "Gray Failure: The Achilles' Heel of Cloud-Scale Systems," HotOS 2017.
- Nathan Bronson et al., "Metastable Failures in Distributed Systems," HotOS 2021.
- Mohammad Alizadeh et al., "Data Center TCP (DCTCP)," SIGCOMM 2010.

**Practice**

- Betsy Beyer et al. (eds.), *Site Reliability Engineering* (O'Reilly, 2016): chapters on load balancing at the frontend and in the data center, handling overload, and addressing cascading failures.
- Envoy Proxy documentation, especially the architecture overview sections on load balancing, outlier detection, circuit breaking, and retries.
- James Kettle, "HTTP Desync Attacks: Request Smuggling Reborn," PortSwigger Research, 2019.
- Public post-incident reports: Dyn (October 2016), Cloudflare (July 2, 2019), Fastly (June 8, 2021), Facebook engineering (October 4–5, 2021), and AWS (December 7, 2021, us-east-1).
