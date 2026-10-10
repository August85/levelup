# Cloud & Infrastructure

> A Distinguished Engineer is accountable for how systems fail under real load, and in the cloud that behavior is set by mechanisms (control loops, cgroups, conntrack tables, replication protocols, blast-radius boundaries) that most engineers treat as someone else's black box.

## Overview

Cloud infrastructure looks like an API. Underneath it is a stack of control loops, kernels, hypervisors, switches, and replication protocols. Each layer has its own consistency model, its own limits, and its own ways of failing.

At Principal level you can usually get by knowing which services to use. At DE level you are the person who has to say *why* a design will hold up at 10x scale, during a regional event, or during a bad deploy of the platform itself. You also have to say what it costs.

This volume covers four areas:

- **Kubernetes internals.** The API server, etcd, informers, the scheduler, and the kubelet, viewed as a distributed system with real consistency and scaling limits.
- **Container runtimes.** Namespaces, cgroups, OCI, and the isolation spectrum from runc to microVMs.
- **Compute, storage, and network architecture.** What the hardware and the provider's virtualization layer actually do, and where latency and cost hide.
- **Multi-region design.** Failure domains, cells, static stability, and the data-replication choices that decide what "active-active" really means.

The thread running through all of it: **most large outages are not caused by a component breaking. They come from a control plane, a dependency, or a shared limit that nobody modeled.** The DE skill is to find those hidden couplings before production finds them.

## Core Concepts

### Kubernetes as a Distributed System

Kubernetes is best understood as a set of independent controllers coordinating through a shared, versioned key-value store. Nothing calls anything directly. Every component reads desired state, observes actual state, and acts to reduce the difference.

```text
  kubectl / CI / operators
            |
            v
  +--------------------+     +--------+
  | kube-apiserver     |<--->| etcd   |
  | authn/authz/admit  |     | (Raft) |
  +--------------------+     +--------+
     ^        ^        ^
     | watch  | watch  | watch
  +------+ +-------+ +---------+
  |sched | |ctrl-mgr| | kubelet |
  +------+ +-------+ +---------+
```

**The API server is the only component that talks to etcd.** It is stateless apart from its caches, so you scale it horizontally. Every request goes through the same pipeline: authentication, authorization (usually RBAC), mutating admission, schema validation, validating admission, then persistence.

That pipeline has an operational consequence. A slow or unavailable admission webhook sits in the write path for every matching object. A webhook with `failurePolicy: Fail` that matches pods in `kube-system` can stop the cluster from healing itself.

### etcd: The Real Source of Truth

etcd is a Raft-replicated, MVCC key-value store. Every write gets a cluster-wide, monotonically increasing **revision**. Kubernetes exposes this revision as `resourceVersion`.

The properties that matter:

- **Linearizable writes through a single Raft leader.** Write throughput is bounded by the leader's disk fsync latency and the network round-trip to a quorum. etcd wants low, consistent fsync latency. A noisy shared disk shows up as leader elections and heartbeat timeouts.
- **MVCC history.** Old revisions stay around until **compaction**. The API server triggers compaction periodically (every 5 minutes by default). Compaction frees logical space. Only **defragmentation** gives disk space back, and defrag blocks that member while it runs.
- **Size quota.** The default backend quota is 2 GiB and is commonly raised to 8 GiB. When the quota is hit, etcd raises a `NOSPACE` alarm and goes read-only for writes. Large objects are the usual cause: big ConfigMaps, CRDs used as databases, or huge numbers of Events.
- **Watch.** Clients can subscribe from a revision and get every subsequent change. If the revision they ask for has been compacted, they get an error and must re-list.

Cluster size should be an odd number: 3 or 5 members. Five tolerates two failures but makes every write wait on three acknowledgments. Seven is almost never worth it. Raft membership is about fault tolerance, not throughput; adding members makes writes slower.

### List-Watch, Informers, and Level-Triggered Control

Every controller follows the same client-side pattern, implemented in client-go:

```text
  apiserver --LIST+WATCH--> Reflector
                               |
                          DeltaFIFO
                               |
             Indexer (local cache) <-- reads
                               |
                 event handlers enqueue keys
                               |
                    rate-limited workqueue
                               |
                     Reconcile(key) loop
```

1. The **Reflector** does one LIST to get a snapshot and its `resourceVersion`, then a WATCH from that version.
2. Changes go into a **DeltaFIFO** and update a local **Indexer** cache.
3. Handlers enqueue object *keys*, not objects, into a **workqueue**. The workqueue de-duplicates, so ten updates to one object produce one reconcile.
4. The reconcile function reads current state from the cache and drives the world toward the spec.

This design is **level-triggered**, not edge-triggered. The controller does not care which event happened. It looks at the current level and fixes the difference. Missed events, restarts, and duplicate deliveries are all harmless, as long as reconcile is idempotent.

Two consequences matter for reviews:

- **Caches are eventually consistent.** A controller can act on stale data. Writes use **optimistic concurrency**: an update carries the `resourceVersion` it read, and the API server rejects it with a 409 Conflict if the object changed since. Correct controllers re-read and retry. They do not force-overwrite.
- **Re-list storms are the scaling cliff.** If thousands of clients lose their watch at once (API server restart, network blip), they all LIST at once. Before the watch cache and consistent-read-from-cache work, a full LIST of pods in a large cluster could hit etcd directly and take down the control plane. Modern versions serve most lists from the API server's watch cache and support streaming lists, but custom clients that bypass informers, or that LIST with label selectors in a tight loop, still cause outages.

### API Priority and Fairness

Since v1.29 (GA), the API server uses **API Priority and Fairness (APF)** rather than a single max-inflight limit. Requests are classified by **FlowSchema** into **PriorityLevels**. Each level gets a share of concurrency, and within a level requests are fair-queued per flow (for example, per user or namespace) using shuffle sharding.

The point: a misbehaving DaemonSet hammering the API should be throttled in its own lane, while leader election and node heartbeats keep flowing. If you run platform-scale clusters, you must review APF configuration the way you review database connection pools. The defaults protect the system's own traffic, but custom operators often land in a catch-all level they share with everything else.

### Scheduler Internals

The scheduler watches for pods with no `nodeName` and binds them. It runs a **scheduling framework** with pluggable extension points:

- **PreFilter / Filter**: eliminate nodes that can't fit the pod. Checks include resource requests, taints and tolerations, node affinity, pod anti-affinity, volume topology, and port conflicts.
- **PreScore / Score**: rank the feasible nodes. Examples include least-allocated or most-allocated resources, topology spread, and image locality.
- **Reserve / Permit / Bind**: commit the decision. Binding happens asynchronously, so the scheduler can move on to the next pod.

For large clusters, the scheduler does not score every node. `percentageOfNodesToScore` stops searching once it has found enough feasible nodes, trading placement quality for throughput.

Important mechanisms:

- **Scheduling uses requests, not usage.** A node is "full" when the sum of requests reaches allocatable capacity, even if real CPU is 10%. This is the source of most cluster cost waste.
- **Preemption.** A pending high-priority pod can evict lower-priority pods. Without PriorityClasses, a burst of batch jobs can starve critical services of capacity.
- **Pod topology spread constraints** distribute replicas across zones or nodes. `whenUnsatisfiable: DoNotSchedule` gives a hard guarantee but can leave pods Pending during a zone outage. That is exactly when you need them to schedule elsewhere.
- **Inter-pod anti-affinity is expensive.** It is evaluated against existing pods and historically scaled poorly in big clusters. Prefer topology spread.

### The Kubelet and the Node

The kubelet is a node-local controller. It watches pods bound to its node, calls the container runtime through the **Container Runtime Interface (CRI)** over gRPC, mounts volumes through CSI, and reports status.

Key mechanisms:

- **Node heartbeats** use Lease objects in `kube-node-lease`, which are cheap to update. After the node-monitor grace period (around 40–50 seconds, depending on version), the node lifecycle controller marks the node NotReady. Pods are then evicted through taint-based eviction, by default after 300 seconds (`tolerationSeconds`).
- **PLEG (Pod Lifecycle Event Generator)** relists containers from the runtime to detect state changes. "PLEG is not healthy" usually means the runtime is slow: too many containers, a hung storage mount, or a struggling containerd. Evented PLEG reduces the polling cost.
- **Eviction.** The kubelet watches memory, disk, and inode pressure against thresholds. Under pressure it evicts pods in QoS order: BestEffort first, then Burstable pods exceeding their requests, then Guaranteed.
- **QoS classes** come from requests and limits. **Guaranteed** means requests equal limits for CPU and memory in every container. **Burstable** means some request is set. **BestEffort** means none are set. QoS also sets the `oom_score_adj` the kernel uses to choose OOM victims.

The node is where Kubernetes abstractions meet the kernel. Most "Kubernetes bugs" in production are actually kernel, runtime, or cgroup behavior.

### Extending Kubernetes Safely

**Custom Resource Definitions (CRDs) and operators** turn Kubernetes into a general control-plane framework. This is powerful and easy to overuse.

Rules of thumb:

- **CRDs are not a database.** Every object lives in etcd, is cached in full by every informer that watches it, and is fanned out to every watcher on each change. Ten thousand frequently updated CRs can dominate etcd write load and API server memory.
- **Finalizers** block deletion until a controller removes them. If the controller is gone, the object (and often the namespace) hangs in Terminating forever.
- **Owner references** drive garbage collection. Cascading deletion of a parent removes children. A wrong owner reference can delete production resources.
- **Server-side apply** tracks field ownership per manager. It prevents two controllers (or a controller and a GitOps tool) from silently fighting over a field. When they do conflict, it surfaces the conflict.

### Kubernetes Networking

Kubernetes requires a flat network: every pod gets its own IP and can reach every other pod without NAT. How you achieve that is the CNI plugin's job.

**CNI implementation choices:**

| Model | How it works | Cost |
|---|---|---|
| Overlay | VXLAN/Geneve encap | MTU loss, CPU |
| Native routing | BGP or cloud routes | Route limits |
| VPC-native | Pod IPs from VPC | IP exhaustion |

VPC-native CNIs (the AWS VPC CNI, GKE alias IPs, Azure CNI) make pods first-class network citizens. Load balancers can target pods directly and flow logs show real pod IPs. The cost is IP address consumption. A /16 VPC runs out faster than anyone expects. On AWS, the number of ENIs and IPs per instance type also caps pod density, unless you use prefix delegation.

**Services** are a virtual IP plus a set of endpoints, published through **EndpointSlices** (which replaced monolithic Endpoints objects, since updating one huge object on every pod change caused O(n²) fan-out).

**kube-proxy** programs the data plane on every node:

- **iptables mode.** Rules are evaluated sequentially, so the cost grows with the number of Services. Full rule-set rewrites get slow in big clusters, and endpoint selection is random per connection.
- **IPVS mode.** Kernel hash tables give O(1) lookup and support more load-balancing algorithms.
- **nftables mode.** GA in v1.33. It uses verdict maps for efficient lookups and incremental updates, and is the forward path from iptables.
- **eBPF replacement** (for example Cilium). It does service translation at the socket or TC hook with no per-packet iptables traversal, and often replaces kube-proxy entirely.

**Connection tracking (conntrack)** sits underneath most of these. NAT'd connections need conntrack entries. A full conntrack table drops new connections silently, logging `nf_conntrack: table full` in dmesg. High-churn workloads, UDP DNS especially, are the usual culprits.

**DNS** is the hidden hot path. The default pod `resolv.conf` uses `ndots:5` with several search domains. A lookup for `api.example.com` (two dots, fewer than five) tries every search suffix first. One external lookup can become four or more queries, times two for A and AAAA. Mitigations: use fully qualified names with a trailing dot, lower `ndots`, and run **NodeLocal DNSCache** to avoid conntrack races on UDP and to absorb load.

### Container Runtimes: What a Container Actually Is

A container is a process. It is a normal Linux process with a restricted view of the system, applied through kernel features:

- **Namespaces** restrict what a process can *see*. The types are mount, PID, network, IPC, UTS (hostname), user, cgroup, and time.
- **cgroups** restrict what a process can *use*: CPU, memory, I/O, and PIDs.
- **Capabilities** split root's powers into units (for example `CAP_NET_ADMIN`, `CAP_SYS_ADMIN`). Containers drop most of them by default.
- **seccomp** filters which syscalls the process may make. The Docker/containerd default profile blocks around 40–50 risky syscalls.
- **LSMs** (AppArmor, SELinux) add mandatory access control.
- **The root filesystem** is usually an **overlayfs** union of read-only image layers plus a writable upper layer.

All containers on a node share **one kernel**. That one fact defines the security boundary. A kernel vulnerability reachable from inside a container can be a host escape.

### The Runtime Stack

```text
 kubelet
   | CRI (gRPC)
   v
 containerd / CRI-O      high-level runtime:
   |                     images, snapshots, CRI
   v
 containerd-shim         per-pod; survives
   |                     runtime restarts
   v
 runc / crun / runsc     low-level OCI runtime:
   |                     creates ns, cgroups
   v
 container process
```

- **OCI Image Spec** defines the image format: a manifest, a config, and content-addressed layer tarballs.
- **OCI Runtime Spec** defines a bundle (a rootfs plus `config.json`) and the lifecycle operations (create, start, kill, delete).
- **containerd** and **CRI-O** are high-level runtimes. They pull images, manage snapshots, and implement CRI. Dockershim was removed from Kubernetes in v1.24.
- **The shim** decouples container lifetime from the daemon. You can restart containerd without killing workloads.
- **runc** (Go) and **crun** (C) are the standard low-level runtimes.

The low-level runtime is pluggable through **RuntimeClass**, which is how you mix isolation levels in one cluster.

### The Isolation Spectrum

| Runtime | Boundary | Overhead |
|---|---|---|
| runc | Shared kernel | Lowest |
| gVisor (runsc) | User-space kernel | Syscall cost |
| Kata Containers | Lightweight VM | Boot, memory |
| Firecracker | MicroVM (KVM) | ~125 ms boot |

- **gVisor** intercepts syscalls and serves them from Sentry, a Go re-implementation of the Linux kernel surface. It has a small host attack surface. Syscall-heavy workloads (lots of small I/O, networking) pay a real cost, and compatibility is not perfect.
- **Kata Containers** runs each pod in a lightweight VM with its own guest kernel, behind a CRI-compatible interface. It is a hardware-virtualization boundary at the cost of memory overhead and slower startup.
- **Firecracker** (from AWS, powering Lambda and Fargate) is a minimal KVM-based VMM. It has a tiny device model and boots in roughly 125 ms with a few MiB of overhead. It was designed for multi-tenant density, as described in the NSDI 2020 paper.

**Judgment:** running untrusted code (customer workloads, CI for external contributors, plugins) on runc with a shared kernel is a choice to accept kernel-level risk. For multi-tenant platforms, a VM boundary is the industry norm for good reason. For your own trusted services, runc with seccomp, dropped capabilities, non-root, and read-only rootfs is usually enough.

### cgroups v1 vs v2, and CPU Throttling

**cgroups v2** uses a single unified hierarchy and is the default in modern distros and Kubernetes. It brings:

- Memory accounting that includes kernel memory and page cache consistently.
- `memory.high`, a soft throttling limit before the OOM killer, alongside `memory.max`.
- **PSI (Pressure Stall Information)**: how much time tasks spent stalled on CPU, memory, or I/O. This is a far better saturation signal than utilization.
- Safer delegation to unprivileged processes.

**CPU limits deserve special attention.** A CPU *request* maps to `cpu.weight` (shares). It is a proportional guarantee under contention and costs nothing when the node is idle. A CPU *limit* maps to the CFS bandwidth controller: `cpu.max` sets a quota per period, 100 ms by default.

A limit of 1 CPU means 100 ms of CPU time per 100 ms period, *summed across all threads*. A process with 8 busy threads can burn its whole quota in 12.5 ms of wall time, then get **throttled for the remaining 87.5 ms**. Average utilization looks low, while p99 latency gets wrecked.

This is why many large operators remove CPU limits from latency-sensitive services and rely on requests plus node-level headroom. The trade-off is weaker noisy-neighbor protection. The metric to watch is `container_cpu_cfs_throttled_periods_total` relative to total periods. (A kernel bug that throttled excessively due to slice expiration was fixed around Linux 5.4. Old kernels make this much worse.)

Runtimes also need to be told about the limits. The JVM, Go (`GOMAXPROCS`; Go 1.25 made it cgroup-aware by default), and Node.js size thread pools and heaps from what they think the machine has. A Go service with `GOMAXPROCS=64` on a 2-CPU quota will throttle constantly.

### Memory and the OOM Killer

Memory is incompressible. When a cgroup hits `memory.max`, the kernel first tries to reclaim page cache. If it can't, the **cgroup OOM killer** kills a process in that cgroup. That is the `OOMKilled` status with exit code 137.

Subtleties that bite:

- **Page cache counts toward the cgroup.** A service that reads large files can look like it is "using" its whole limit. Usually that is fine, because cache is reclaimable. Dirty pages and tmpfs (`emptyDir` with `medium: Memory`) are not reclaimable.
- **Node-level OOM** is different from cgroup OOM. If the node runs out before any container hits its limit (because limits are overcommitted), the kernel's global OOM killer chooses victims by `oom_score_adj`. The kubelet's eviction thresholds exist to act *before* that happens.
- **Requests below real usage** let the scheduler overpack nodes. Memory requests should approximate the working set at p95 or above. Set limits equal to requests for memory unless you have a specific reason not to.

### Compute Architecture

Modern cloud VMs run on hardware-assisted virtualization (Intel VT-x, AMD-V) with heavy offload. AWS **Nitro** is the canonical example: networking, EBS storage, and management run on dedicated cards, so nearly all host CPU goes to guests and the hypervisor is minimal.

What matters for design:

- **NUMA.** Large instances span multiple sockets or NUMA nodes. Cross-node memory access is slower. Latency-critical workloads (databases, packet processing) benefit from CPU and memory pinning. The Kubernetes **CPU Manager** (`static` policy), **Memory Manager**, and **Topology Manager** do this for Guaranteed pods with integer CPU requests.
- **SMT (hyperthreads).** A vCPU is usually a hyperthread, not a core. Two vCPUs on sibling threads share execution units and caches.
- **SR-IOV / ENA / gVNIC.** Virtual functions give guests near-native network performance. Packets-per-second limits per instance are real and documented. They are often hit before bandwidth limits, especially with small packets.
- **Burstable instances** (for example the AWS T family) run on CPU credits. When credits run out, performance drops to the baseline. That is a very different failure from "slow." Don't put steady-state production on them without unlimited mode and cost monitoring.

**Spot / preemptible capacity** is typically 60–90% cheaper and can be reclaimed with short notice (two minutes on AWS, about 30 seconds on GCP). It works well for stateless, checkpointable, or batch work spread across many instance types and zones. It fails when a whole fleet depends on one instance type in one zone. Reclamation is correlated, and it happens exactly when demand spikes.

### Autoscaling: Four Loops, Four Timescales

```text
 metric spike
    |
    v
 HPA adds pods ........... seconds to ~1 min
    |
    v
 pods Pending
    |
    v
 node autoscaler ......... 1-5 min (VM boot,
    |                      image pull, join)
    v
 pods Running
```

- **HPA** scales replicas on metrics. It is a control loop with stabilization windows. Scaling on CPU is reactive, while scaling on queue depth or request rate leads.
- **VPA** adjusts requests. It historically required pod restarts. In-place pod resize (beta in v1.33) reduces that cost.
- **Cluster Autoscaler** scales node groups when pods are Pending. **Karpenter** provisions instances directly to fit pending pods, choosing from many instance types, and consolidates underused nodes.
- **Predictive / scheduled scaling** pre-warms capacity for known peaks.

The DE insight: **the total reaction time is the sum of the loops.** If traffic can double in 60 seconds and node provisioning takes 4 minutes, you need standing headroom. Some teams use low-priority "balloon" pods that get preempted to make instant room. Autoscaling is a cost optimization. It does not replace capacity planning.

### Storage Architecture

Three storage models with different semantics:

| Type | Semantics | Typical use |
|---|---|---|
| Block | Raw device, one writer | Databases |
| File | POSIX, shared | Legacy, ML data |
| Object | Whole-object PUT/GET | Data lakes, blobs |

**Network block storage** (EBS, Persistent Disk, Azure Managed Disk) is replicated within a zone and attached over the network. Key facts:

- **It is zonal.** A volume cannot follow a pod to another AZ. Kubernetes handles this with topology-aware provisioning: `volumeBindingMode: WaitForFirstConsumer` delays volume creation until the pod is scheduled, so the volume lands in the right zone. Without it you get pods stuck Pending in zone B with their volume in zone A.
- **Performance is provisioned.** IOPS and throughput are both capped. Instance-level EBS bandwidth is a *separate* cap, and a common hidden bottleneck.
- **Latency is network latency.** It is usually sub-millisecond to low single-digit milliseconds, with tail variance. Every fsync is a network round trip.

**Local NVMe** gives roughly 10–100x lower latency and huge IOPS. It is **ephemeral**: the data is gone when the instance stops or the host fails. It is right for caches, scratch space, and databases that replicate themselves (Cassandra, Kafka, CockroachDB, Vitess-managed MySQL with replicas). It is wrong for a single-instance database.

**Object storage** (S3, GCS, Azure Blob) is the durability backbone of the cloud. S3 is designed for eleven nines of durability using erasure coding across devices and AZs. It has offered **strong read-after-write consistency** for all operations since December 2020. Before that, overwrite and list operations were eventually consistent, and a lot of tooling (S3Guard, EMRFS consistent view) existed to work around it.

Object storage design rules:

- Throughput scales with parallelism and key-prefix partitioning. S3 supports at least 3,500 writes and 5,500 reads per second per prefix and auto-partitions as load grows. Hot single keys still hit limits.
- There is no rename and no partial update. "Directories" are a listing convention. Table formats (Iceberg, Delta, Hudi) build atomic commits on top using metadata files and conditional writes.
- Per-request costs dominate for small objects. A billion 1 KB objects cost far more in requests than in storage.

### Durability vs Availability vs Consistency in Storage

These are three different properties, and conflating them causes bad designs.

- **Durability** means the data will not be lost. It comes from replication or erasure coding across independent failure domains, plus checksums and scrubbing.
- **Availability** means you can read or write it right now.
- **Consistency** means what a read returns relative to prior writes.

**Erasure coding** (for example Reed-Solomon with k data and m parity shards) gives high durability at about 1.2–1.5x storage overhead, compared with 3x for triple replication. The costs are reconstruction CPU, read amplification on degraded reads, and higher small-object latency. Replication is better for hot, small, latency-sensitive data. Erasure coding is better for large and cold data.

**fsync semantics are a correctness issue.** "Written" means different things at the page cache, the device write cache, and replicated storage. The 2018 PostgreSQL "fsyncgate" episode showed that on Linux, a failed fsync could clear the error state. Retrying fsync then falsely reported success. Databases now treat fsync failure as fatal (PANIC). Know what your storage acknowledges and when.

### Cloud Networking Architecture

**VPC fundamentals:** a VPC is a software-defined overlay on the provider's physical network. Subnets are zonal on AWS and regional on GCP. Route tables, security groups (stateful, per-ENI), and network ACLs (stateless, per-subnet) are enforced in the virtualization layer, not in your guest.

Things that matter at scale:

- **IP address planning.** It is hard to change later. Plan non-overlapping CIDRs across every VPC, region, and on-prem network you might ever connect. VPC-native pod networking multiplies IP demand. IPv6, or dual-stack, is the long-term fix.
- **Cross-AZ traffic costs money.** On AWS it is commonly about $0.01/GB in each direction. A chatty microservice graph spread evenly across three AZs sends about two-thirds of its calls cross-zone. **Topology-aware routing** (`trafficDistribution: PreferClose` on Services) keeps traffic in-zone, but only works when endpoints are balanced per zone.
- **NAT gateways** charge per GB processed. Pulling container images or calling S3 through NAT instead of a VPC endpoint is a top-five surprise on cloud bills.
- **MTU.** Overlays and tunnels (VXLAN adds 50 bytes, IPsec and WireGuard add more) reduce effective MTU. If ICMP "fragmentation needed" messages are blocked, **Path MTU Discovery breaks**. Small requests then work and large responses hang, which is maddening to debug.
- **Connection limits.** Security groups and NAT have connection-tracking limits too. Long-lived idle connections can be silently dropped by middleboxes with idle timeouts (350 seconds on AWS NAT gateways). Use TCP keepalives shorter than the smallest idle timeout in the path.

### Load Balancing

| Layer | Sees | Typical choice |
|---|---|---|
| L4 | IP, port, TCP/UDP | NLB, Maglev |
| L7 | HTTP headers, paths | ALB, Envoy |
| DNS | Name to IP | Route 53, GSLB |
| Anycast | One IP, many sites | CDN, global LBs |

- **L4 load balancers** at hyperscale use consistent hashing so any LB instance maps a flow to the same backend, with no shared state. Google's **Maglev** (NSDI 2016) is the canonical design: ECMP from routers spreads packets across LB machines, and each machine uses a Maglev hash table to pick backends with minimal disruption when the set changes.
- **L7 load balancers** terminate connections. They enable per-request balancing, retries, and header routing, but add a hop and a stateful component.
- **Long-lived connections defeat L4 balancing.** HTTP/2 and gRPC multiplex many requests over one TCP connection. An L4 balancer pins all of them to one backend. New pods get no traffic while old ones melt. Use L7 (request-level) balancing, client-side load balancing, or periodic connection recycling (`MaxConnectionAge` in gRPC).
- **Connection draining and readiness.** Rolling deploys drop requests unless the pod stops getting new traffic *before* it stops serving. In Kubernetes, endpoint removal and SIGTERM happen concurrently. That is why `preStop` sleeps of a few seconds are common, and why the app must handle SIGTERM by draining.

**Least-request beats round-robin** under heterogeneous latency. "Power of two random choices" (pick two backends at random, send to the less loaded) gets most of the benefit at low coordination cost.

### Failure Domains and Multi-Region Design

Cloud providers give you nested failure domains:

```text
 Global (control planes, IAM, DNS)
   |
   +-- Region (independent stack)
         |
         +-- AZ (separate power, cooling,
         |       network; ~ms apart)
         +-- AZ
         +-- AZ
               |
               +-- rack / host / cell
```

- **AZs** are physically separate data centers (or clusters of them) with independent power and networking. They are close enough for synchronous replication: typically sub-2 ms round trips.
- **Regions** are designed to be independent. Cross-region latency runs tens to hundreds of milliseconds, so synchronous replication across regions costs every write a WAN round trip.
- **Global services** (IAM, DNS control planes, some billing and console paths) are often anchored in one region. They are a hidden common dependency.

**Multi-AZ is the baseline** for anything production. **Multi-region** is a business decision with large costs: data replication, consistency semantics, duplicated capacity, operational complexity, and testing. It is justified by regulatory need, latency for global users, or a requirement to survive a full-region event.

### Control Planes, Data Planes, and Static Stability

AWS's Builders' Library popularized a distinction every DE should apply reflexively:

- **The control plane** changes the system: create, scale, configure, deploy. It is complex, lower volume, and allowed to be less available.
- **The data plane** does the work: serves requests, routes packets, stores bytes. It is simple, high volume, and must be highly available.

**Static stability** means the data plane keeps working, with its last known good configuration, when the control plane is impaired. Examples:

- EC2 instances keep running when the EC2 API is down.
- Pods keep running when the Kubernetes API server is down. The kubelet does not kill healthy containers just because it can't reach the API.
- A service pre-provisions capacity in each AZ to absorb the loss of one AZ, *without needing to launch anything*. Launching new capacity during an incident depends on the control plane at its most stressed.

Design implication: **recovery paths must not depend on control planes that are likely to be impaired by the same event.** If your failover runbook says "scale up region B," you have made region B's control plane and capacity pool part of your critical path.

### Cell-Based Architecture and Shuffle Sharding

A **cell** is a complete, independent copy of the service stack (compute, storage, queues) that serves a subset of customers or keys. A thin **routing layer** maps each request to its cell.

```text
          request
             |
      +-------------+
      | cell router |  (thin, static,
      +-------------+   cached mapping)
       /     |     \
   +-----+ +-----+ +-----+
   |cell1| |cell2| |cell3|
   +-----+ +-----+ +-----+
   full stack in each
```

Benefits:

- **Blast radius.** A bad deploy, poison request, or overload affects one cell's customers.
- **Bounded scale.** Each cell has a known maximum size that you have actually tested. You grow by adding cells, not by making one cell bigger.
- **Safe deployment.** Roll out cell by cell, with bake time.

Costs:

- The router is a global dependency. It must be extremely simple and statically stable.
- Cross-cell operations (global queries, customer migration between cells) are hard.
- Capacity is fragmented, so utilization is lower.

**Shuffle sharding** assigns each customer to a random *combination* of k workers out of n. With 8 workers and 2 per customer there are 28 combinations. One bad customer can take out its 2 workers, but other customers share at most one of them with it, so each still has a healthy worker. Route 53's use of this is the canonical example. It turns "one noisy tenant takes everyone down" into "one noisy tenant takes itself down."

### Multi-Region Topologies

| Pattern | RTO | RPO |
|---|---|---|
| Backup & restore | Hours | Hours |
| Pilot light | 10s of min | Minutes |
| Warm standby | Minutes | Seconds–min |
| Active-active | ~0 | ~0 to seconds |

- **Backup & restore.** Data is backed up cross-region and infrastructure is rebuilt from code on disaster. It is cheapest, slowest, and the most likely to fail when you actually need it.
- **Pilot light.** Data is replicated continuously and core infrastructure exists but is scaled to near zero.
- **Warm standby.** A scaled-down but functional copy serves no (or little) traffic and is scaled up on failover.
- **Active-active.** All regions serve traffic. Each region needs enough headroom to absorb the others' load, or a policy for shedding it.

**RPO and RTO are set by the data tier, not the stateless tier.** Moving stateless compute between regions is easy. The hard question is always "what happens to writes in flight, and who is the authority for this record?"

### Data Replication Across Regions

The core trade-off is the speed of light. New York to London is about 5,570 km. Light in fiber covers roughly 200 km per ms, so the theoretical minimum round trip is about 56 ms, and real-world RTTs are around 70–80 ms. **Synchronous cross-region replication adds at least one WAN RTT to every write.**

Options:

- **Asynchronous primary-replica.** One writable region, async replicas elsewhere. Writes are fast. On failover, you lose the replication lag (non-zero RPO), and you must fence the old primary to avoid split-brain.
- **Synchronous quorum across regions.** Spanner, CockroachDB, and similar systems put Paxos or Raft replicas across 3+ regions. RPO is zero and failover is automatic. Write latency includes a cross-region quorum round trip. Spanner uses **TrueTime** (GPS and atomic clocks bounding clock uncertainty) to provide external consistency, waiting out the uncertainty interval on commit.
- **Multi-writer with conflict resolution.** DynamoDB global tables (last-writer-wins), Cassandra (LWW by timestamp), and CRDT-based systems. Writes are local and fast in every region. Concurrent writes to the same key resolve by rule, and LWW silently drops one of them. DynamoDB added a multi-region strong consistency option in 2024–2025, which itself trades write latency for consistency.
- **Partitioned ownership ("home region").** Each record or tenant has one home region that takes its writes. Other regions read replicas or forward writes. This is often the best practical answer: local latency for most users, no conflicts, and a clear failover unit.

**Failover mechanics:**

- **DNS failover** is bounded by TTLs, and by resolvers and clients that ignore TTLs (the JVM historically cached DNS forever with a security manager installed). Assume a long tail.
- **Anycast / global load balancers** fail over faster, at the network layer.
- **Fencing.** Before promoting a new primary, make sure the old one cannot accept writes. Use leases, epoch numbers, or STONITH-style isolation. Failover without fencing is how you get split-brain and divergent data.
- **Failback** is a separate, often harder operation. Data written in the failover region must reconcile with whatever the original region committed before it died.

## Design Principles

- **Separate control plane from data plane.** Keep the data plane simple, statically stable, and able to run on cached configuration. Accept a lower availability target for the control plane, and never put it in the request path.
- **Design for static stability.** Pre-provision enough capacity to survive the loss of an AZ (N+1 across zones) without launching anything. Recovery that requires the control plane at the moment of crisis is a recovery that may not happen.
- **Bound blast radius explicitly.** Use cells, shuffle sharding, per-tenant quotas, and progressive rollouts. Every change and every tenant should have a known maximum impact, and you should be able to state it as a number.
- **Prefer level-triggered reconciliation.** Controllers that compare desired state to observed state and converge are robust to missed events, restarts, and duplicates. Edge-triggered workflows that assume every event arrives exactly once are fragile.
- **Requests are a contract; limits are a weapon.** Set memory requests to real working-set usage and memory limits equal to requests. Be deliberate about CPU limits. They protect neighbors, but CFS throttling damages tail latency.
- **Make shared limits visible.** Track conntrack tables, ENI/IP quotas, etcd size, API server inflight requests, NAT ports, file descriptors, and per-account API rate limits. Hidden shared limits cause the outages nobody predicted.
- **Keep failure domains aligned.** Spread replicas, volumes, load balancer targets, and dependencies over the same zones. A service that is multi-AZ but whose database is single-AZ is single-AZ.
- **Treat cross-zone and cross-region bytes as a design cost.** Data transfer pricing and latency both reward locality. Make topology an explicit input to routing and placement.
- **Choose isolation to match trust.** Shared-kernel containers for trusted code. gVisor or microVMs for untrusted or multi-tenant code. Hardware or account boundaries for hard tenancy and compliance.
- **The data tier determines your RPO and RTO.** Design multi-region from the data model outward: who owns each record, how it replicates, and how you fence. Stateless failover is the easy part.
- **Exercise every recovery path.** A failover, restore, or region evacuation that hasn't been run recently should be assumed broken. Game days and continuous chaos testing turn hope into evidence.
- **Avoid synchronized behavior.** Add jitter to retries, cache expiries, cron schedules, and reconnects. Synchronized clients turn small blips into thundering herds against control planes.

## Trade-offs and Decision Frameworks

### Managed Kubernetes vs Alternatives

Kubernetes earns its complexity when you have many services, heterogeneous workloads, and a platform team to own it. It is the wrong default for a small number of services.

| Option | Best when | Main cost |
|---|---|---|
| Serverless (FaaS) | Spiky, event-driven | Cold starts, limits |
| Managed containers | Few services | Less control |
| Managed K8s | Many teams/services | Platform team |
| Self-managed K8s | Unusual needs | Ops burden |

A useful test: **can you name the platform team that will own upgrades for the next five years?** Kubernetes minor versions get roughly 14 months of upstream support. A cluster that isn't upgraded several times a year becomes a security and compatibility liability.

### One Big Cluster vs Many Clusters

Large shared clusters give better bin-packing and fewer things to operate. Many smaller clusters give isolation and smaller blast radius.

- **Consolidate** when workloads are trusted, the platform team is strong, and cost efficiency matters most.
- **Split** by environment (never mix prod and dev control planes), by region or cell, by compliance boundary, and by tenancy model.
- **Watch the scaling limits.** Upstream tests up to 5,000 nodes and 150,000 pods per cluster. Real limits often arrive sooner because of CRD count, watch fan-out, or etcd size. Many large operators deliberately cap clusters well below these numbers.

The modern answer for most large organizations is **a fleet of many identical clusters, managed as cattle** (fleet tooling, GitOps), with clusters as cells.

### CPU Limits: Set or Not?

| Choice | Benefit | Cost |
|---|---|---|
| No CPU limit | No throttling | Noisy neighbors |
| Limit = request | Predictable, Guaranteed QoS | Throttling, waste |
| Limit > request | Burst room | Throttling at peaks |

Framework: for latency-critical services on dedicated or well-understood node pools, prefer requests without limits, and monitor PSI. For multi-tenant clusters and batch workloads, use limits to enforce fairness. For workloads that need CPU pinning, use Guaranteed QoS with integer CPUs and the static CPU Manager.

### Storage Selection

Ask in order:

1. **Does the application replicate its own data?** If yes, local NVMe is usually best: fast, cheap, and loss is tolerated by design.
2. **Does it need a single-writer filesystem with durability?** Use network block storage, with snapshots for backup. Remember it is zonal.
3. **Is it large, immutable, or analytic?** Use object storage, with a table format if you need transactions.
4. **Do many clients need shared POSIX access?** Use a managed file service, but measure metadata-operation latency first. It is usually the bottleneck.

### Single-Region, Multi-AZ vs Multi-Region

Most systems should be **multi-AZ, single-region, with cross-region backups and a tested restore.** Move up only when a requirement forces it:

- **Latency for globally distributed users** leads to regional read replicas or edge caches first, then regional write ownership.
- **Survive full-region loss with RTO in minutes** leads to warm standby with async replication. Accept non-zero RPO, and write it down.
- **Zero RPO across regions** leads to synchronous quorum storage (a Spanner-class system). Accept cross-region write latency on every write.
- **Data residency** leads to partitioned, region-pinned data. This is a legal requirement, not an availability feature, and it often *conflicts* with cross-region failover.

Cost rule of thumb: active-active across two regions costs well over 2x. You need each region provisioned for failover load, plus cross-region data transfer, plus engineering time.

## Failure Modes and War Stories

These are drawn from public postmortems. Details are summarized. Read the originals for full timelines.

### The Control Plane Took Down the Data Plane

**OpenAI, December 2024.** A new telemetry service was deployed to every cluster. Its agents made expensive Kubernetes API calls whose cost scaled with cluster size, overwhelming the API servers in large clusters.

The data plane depended on the control plane through **DNS-based service discovery**, and CoreDNS needed the API server. Cached DNS records masked the impact at first, so the rollout continued. When the caches expired, services failed broadly. Engineers then struggled to roll back, because the fix required the API server that was overloaded.

**Lessons:**

- Data-plane request paths should not depend on the Kubernetes API being healthy.
- Caches delay failures and hide the causal link between change and impact.
- Keep "break-glass" access to the control plane that does not go through the overloaded path.
- Roll out platform-wide agents progressively, cluster by cluster, with API server load as a guardrail metric.

### Hidden Coupling in Regional Foundations

**AWS us-east-1, December 2021.** An automated scaling activity on the main AWS network triggered unexpected client behavior in AWS's internal network. That caused a large surge of connection activity, which congested the devices connecting the internal network to the main network. Monitoring and internal control-plane services were impaired, so diagnosis was slow. Many services' control planes (including APIs for launching instances) degraded, while running workloads largely continued.

**AWS us-east-1, October 2025.** A latent race condition in DynamoDB's automated DNS management left the regional DynamoDB endpoint with an empty DNS record. Services that depended on DynamoDB, including parts of EC2's own instance-launch machinery, failed. Recovery then involved working through backlogs and throttled restarts.

**Lessons:**

- Foundational services have deep, often invisible dependency graphs. Ask, "What does our recovery need, and what does *that* need?"
- Automation that manages critical records (DNS, routes, config) needs invariant checks such as "never publish an empty record set."
- Static stability at your layer: running workloads should keep running when the provider's control plane is impaired.

### A Typo Removes Too Much Capacity

**AWS S3, February 2017 (us-east-1).** During debugging, an engineer ran a playbook command to remove a small number of servers. An input error removed far more, including servers supporting the index and placement subsystems. Those subsystems needed a full restart, which hadn't been done at that scale in years and took hours. Many services, including the AWS status page's own assets, depended on S3 in us-east-1.

**Lessons:**

- Tools that remove capacity need rate limits and floors ("never below minimum capacity").
- Restart and recovery paths at full scale must be exercised. Systems that have grown since the last cold start will take longer than anyone thinks.
- Your status page and incident tooling must not depend on the thing that is down.

### A Global Configuration Push

**Facebook, October 2021.** A command intended to assess backbone capacity unintentionally disconnected Facebook's data centers from the backbone. A bug in the audit tool failed to stop it. Facebook's DNS servers, designed to withdraw their BGP announcements when they couldn't reach the data centers, did exactly that. Facebook disappeared from the internet. Internal tools and physical access systems depended on the same network, which slowed recovery.

**Lessons:**

- Health-check-driven self-removal is correct locally and catastrophic when every node fails the check at once. Use "fail static": if *everyone* looks unhealthy, the health check is probably what's wrong.
- Out-of-band management networks and physical-access fallbacks are not optional at scale.

### The Kubernetes Upgrade That Broke the Network

**Reddit, March 2023 (the "Pi Day" outage).** An upgrade from Kubernetes 1.23 to 1.24 caused a roughly five-hour outage. The cause was the removal of the deprecated `master` node-role label in favor of `control-plane`. Reddit's Calico configuration used a node selector on the old label to choose BGP route reflectors. After the upgrade no nodes matched, route reflection stopped, and pod networking collapsed. Rollback required restoring the control plane from backup, a procedure that was rarely exercised.

**Lessons:**

- Read deprecation notes as a dependency audit: search all config, not just your code, for removed labels, APIs, and flags.
- Upgrade in a production-like environment that mirrors the network configuration, not just the workloads.
- Control-plane restore must be a practiced runbook.

### An OS Update Reset the Network

**Datadog, March 2023.** An automatic security update to systemd on Ubuntu hosts restarted `systemd-networkd`. That removed routes managed by the Cilium CNI, cutting off pod networking on tens of thousands of nodes across multiple regions and clouds at roughly the same time, because unattended upgrades ran on a similar schedule everywhere.

**Lessons:**

- **Correlated change is the enemy of redundancy.** Multi-region provides no protection if the same update lands everywhere in the same hour.
- Treat OS package updates as deploys. Stage them, spread them over time, and roll them out per cell.
- Know which agents own which kernel state (routes, iptables rules, BPF maps), and what else might reset it.

### Smaller Recurring Failure Patterns

These rarely make headlines but cause many incidents:

- **CFS throttling.** p99 latency spikes with low average CPU. Diagnosis: throttled periods are high. Fix: remove or raise CPU limits, set `GOMAXPROCS` or JVM CPU count correctly.
- **conntrack exhaustion.** Random connection failures under load, and `nf_conntrack: table full` in dmesg. Common on NAT-heavy nodes and DNS-heavy workloads.
- **DNS amplification and UDP races.** `ndots:5` multiplies queries. Concurrent A/AAAA lookups over UDP from the same socket hit a known conntrack insertion race, causing 5-second timeouts. Fix with NodeLocal DNSCache, `single-request-reopen`, or TCP.
- **etcd NOSPACE.** The cluster goes read-only. Causes: event floods, big CRs, missed defrag. Monitor `etcd_mvcc_db_total_size_in_bytes` against the quota.
- **Admission webhook outage.** The webhook's own pods can't be scheduled because the webhook blocks pod creation. Exclude `kube-system` and the webhook's namespace, set timeouts, and think hard about `failurePolicy`.
- **Zonal volume trap.** A StatefulSet pod can't reschedule after its zone fails because its EBS volume lives there. That is expected behavior, so design replication above the volume.
- **IP exhaustion.** A scale-up fails with "no IPs available in subnet." It surfaces during the traffic spike, never during testing.
- **Retry storms.** Client retries, mesh retries, and SDK retries multiply. Three layers making three attempts each means up to 27x amplification of a failing call. Use retry budgets and only retry at one layer.
- **Thundering herd on recovery.** A dependency comes back and every client reconnects at once, knocking it over again. Fix with jittered backoff, admission control, and gradual traffic restoration.

### The Meta-Pattern

Across these incidents the recurring shape is:

1. A change or event that is **correlated** across many nodes, regions, or clients.
2. A **hidden dependency** (DNS, control plane, shared network, config label) that wasn't on the architecture diagram.
3. A **recovery path that depends on the broken thing**, or that had never been exercised at current scale.

A DE review should hunt specifically for these three.

## What a DE Probes

- **"Walk me through what happens to request serving if the Kubernetes API server is unavailable for 30 minutes."** A good answer: pods keep running; service discovery keeps working from cached endpoints or DNS; autoscaling and deploys pause; and the team has tested this. A red flag is an app that calls the API on the request path, or DNS that fails without it.
- **"What is the blast radius of a bad config push, and how do you know?"** A good answer names a cell or wave structure, states a maximum percentage of customers affected, and describes automated rollback triggered by health metrics during bake time.
- **"Which of your recovery steps require a control plane, and is that control plane in the same failure domain?"** A good answer distinguishes pre-provisioned capacity from capacity launched on failover, and shows that failover works with the provider's APIs degraded.
- **"What are the five shared limits you'll hit first at 10x?"** A good answer lists specific numbers: etcd size, IPs per subnet, conntrack entries, API rate quotas, NAT ports, per-prefix object-store request rates. Each has current utilization and an alert.
- **"How are CPU and memory requests and limits set, and what's your throttling rate?"** A good answer cites usage data (VPA recommendations or percentiles), uses memory limit equal to request, makes a deliberate CPU-limit choice, and reports measured throttling with runtime thread counts aligned to quotas.
- **"What's your RPO and RTO, per data store, and when did you last prove them?"** A good answer gives per-store numbers that are often different, a failover or restore drill date within the last quarter, and a measured result.
- **"How do you prevent split-brain on regional failover?"** A good answer describes a fencing mechanism (leases, epochs, write-blocking on the old primary) and a defined failback process with data reconciliation.
- **"What happens to in-flight requests during a rolling deploy and a node drain?"** A good answer covers readiness gates, preStop delay, SIGTERM draining, PodDisruptionBudgets, and connection draining on the load balancer, with zero-error deploys as a measured SLO.
- **"How much of your traffic crosses AZs, and what does it cost?"** A good answer has a number from flow logs or billing, and uses topology-aware routing or zonal affinity where it pays off.
- **"Which workloads run untrusted code, and what is the isolation boundary?"** A good answer gives a clear inventory, uses VM-level isolation (gVisor, Kata, Firecracker, or separate nodes and accounts) for untrusted code, and enforces seccomp, non-root, and no privileged pods everywhere else.
- **"How do platform-wide changes (OS updates, agents, CNI upgrades) roll out?"** A good answer treats them like application deploys: staged by environment and cell, spread over time, with guardrail metrics. Unattended updates everywhere at once is a red flag.
- **"What's the oldest Kubernetes version in your fleet, and what's the upgrade cadence?"** A good answer has every cluster within supported versions, a regular cadence, and deprecated-API scanning in CI.
- **"If one tenant sends 100x normal traffic, who else suffers?"** A good answer covers per-tenant rate limits, shuffle sharding or cells, and API Priority and Fairness configured for operators and tenants.
- **"Where are the retries, and what's the maximum amplification?"** A good answer has retries at one layer, retry budgets, and jittered exponential backoff, and can compute the worst-case multiplier.

## Review Checklist

- [ ] Data plane serves traffic with the Kubernetes API and cloud control planes unavailable (tested)
- [ ] Capacity is pre-provisioned to survive loss of one AZ without launching new instances
- [ ] Replicas, volumes, and dependencies are spread across the same set of zones
- [ ] Topology spread constraints set, with a deliberate `whenUnsatisfiable` choice
- [ ] PodDisruptionBudgets defined for every critical workload
- [ ] Memory requests reflect measured working set; memory limit equals request
- [ ] CPU limit policy chosen deliberately; throttling rate monitored
- [ ] Runtime thread pools and heap sized to cgroup limits (GOMAXPROCS, JVM flags)
- [ ] PriorityClasses defined so critical workloads preempt batch work
- [ ] Graceful shutdown: readiness drop, preStop delay, SIGTERM draining verified
- [ ] gRPC/HTTP2 traffic balanced per request, not per connection
- [ ] Admission webhooks have timeouts, scoped selectors, and exclude system namespaces
- [ ] etcd size, defrag, and backup monitored; control-plane restore drilled
- [ ] API Priority and Fairness reviewed for custom controllers and agents
- [ ] Controllers use informers, are idempotent, and handle 409 conflicts
- [ ] Finalizers have a documented removal path if their controller is gone
- [ ] Shared limits tracked with alerts: IPs, ENIs, conntrack, NAT ports, quotas
- [ ] DNS hardened: NodeLocal DNSCache or equivalent, FQDNs for external calls
- [ ] MTU consistent across overlays and tunnels; PMTUD not blocked
- [ ] Keepalives shorter than the smallest idle timeout in the path
- [ ] Cross-AZ and NAT data transfer measured; VPC endpoints for object storage
- [ ] Storage class uses `WaitForFirstConsumer`; volume zonality understood
- [ ] Local NVMe used only where the application replicates data
- [ ] Per-data-store RPO/RTO documented and proven by drill this quarter
- [ ] Failover includes fencing of the old primary and a failback plan
- [ ] DNS TTLs and client caching behavior accounted for in failover time
- [ ] Untrusted code runs behind a VM-grade isolation boundary
- [ ] Pods run non-root, with seccomp, dropped capabilities, no privileged mode
- [ ] OS, agent, and CNI updates staged by cell and spread over time
- [ ] Config and infra changes roll out progressively with automated rollback
- [ ] Capacity-removing tools enforce rate limits and minimum floors
- [ ] Retries live at one layer with budgets and jitter
- [ ] Kubernetes versions within support; deprecated APIs scanned in CI
- [ ] Incident tooling and status page independent of production dependencies

## Further Reading

**Kubernetes and cluster management**

- Burns, Grant, Oppenheimer, Brewer, Wilkes, "Borg, Omega, and Kubernetes" (ACM Queue, 2016). The lineage and design rationale.
- Verma et al., "Large-scale cluster management at Google with Borg" (EuroSys 2015).
- Kubernetes documentation: "Kubernetes Components," "API Priority and Fairness," "Scheduling Framework," "Node-pressure Eviction," and "Considerations for large clusters." kubernetes.io/docs
- Kubernetes SIG Scalability: scalability thresholds and SLOs (github.com/kubernetes/community).
- Brendan Burns, Joe Beda, Kelsey Hightower, Lachlan Evenson, *Kubernetes: Up and Running* (O'Reilly, 3rd ed.).
- Michael Hausenblas and Stefan Schimanski, *Programming Kubernetes* (O'Reilly). Informers, controllers, and CRDs.
- Ongaro and Ousterhout, "In Search of an Understandable Consensus Algorithm" (USENIX ATC 2014). Raft, the basis of etcd.
- etcd documentation: "Operations guide," "Tuning," and "Maintenance" (compaction, defrag, quotas). etcd.io/docs

**Containers and isolation**

- Open Container Initiative: Runtime Specification and Image Specification. opencontainers.org
- Linux kernel documentation: "Control Group v2" and "CFS Bandwidth Control." docs.kernel.org
- Agache et al., "Firecracker: Lightweight Virtualization for Serverless Applications" (NSDI 2020).
- gVisor documentation: "Security Model" and architecture guide. gvisor.dev
- Liz Rice, *Container Security* (O'Reilly).

**Compute, storage, and networking**

- Eisenbud et al., "Maglev: A Fast and Reliable Software Network Load Balancer" (NSDI 2016).
- Mitzenmacher, "The Power of Two Choices in Randomized Load Balancing" (IEEE TPDS, 2001).
- Corbett et al., "Spanner: Google's Globally-Distributed Database" (OSDI 2012).
- DeCandia et al., "Dynamo: Amazon's Highly Available Key-value Store" (SOSP 2007).
- Huang et al., "Erasure Coding in Windows Azure Storage" (USENIX ATC 2012).
- Singh et al., "Jupiter Rising: A Decade of Clos Topologies and Centralized Control in Google's Datacenter Network" (SIGCOMM 2015).
- Brendan Gregg, *Systems Performance* (2nd ed.). The reference for kernel-level performance analysis, including USE method and PSI.

**Resilience and multi-region design**

- Amazon Builders' Library: "Static stability using Availability Zones," "Avoiding fallback in distributed systems," "Workload isolation using shuffle-sharding," "Timeouts, retries, and backoff with jitter," and "Avoiding insurmountable queue backlogs." aws.amazon.com/builders-library
- AWS Well-Architected Framework: Reliability Pillar, and the whitepaper "Reducing the Scope of Impact with Cell-Based Architecture."
- AWS whitepaper: "Disaster Recovery of Workloads on AWS: Recovery in the Cloud."
- Beyer, Jones, Petoff, Murphy (eds.), *Site Reliability Engineering* (O'Reilly, 2016), especially chapters on load balancing, handling overload, and cascading failures. sre.google/books
- Marc Brooker's blog (brooker.co.za/blog), on metastable failures, retries, and cell-based design.
- Bronson et al., "Metastable Failures in Distributed Systems" (HotOS 2021).
- Martin Kleppmann, *Designing Data-Intensive Applications* (O'Reilly). Replication and consistency chapters.

**Public postmortems referenced**

- AWS: "Summary of the Amazon S3 Service Disruption in the Northern Virginia (US-EAST-1) Region" (February 2017).
- AWS: "Summary of the AWS Service Event in the Northern Virginia (US-EAST-1) Region" (December 2021).
- AWS: "Summary of the Amazon DynamoDB Service Disruption in the Northern Virginia (US-EAST-1) Region" (October 2025).
- Meta Engineering: "More details about the October 4 outage" (2021).
- Reddit: "You Broke Reddit: The Pi-Day Outage" (r/RedditEng, 2023).
- Datadog: "2023-03-08 Incident: A deep dive into our incident response" and the associated technical write-up.
- OpenAI: "API, ChatGPT & Sora Facing Issues" incident report (December 2024).
- Dan Luu, "A collection of postmortems" (github.com/danluu/post-mortems).
