# Chapter 19: FlexAlgo - Flexible Algorithm for Constraint-Based Path Computation

## 19.1 Overview

FlexAlgo (Flexible Algorithm) extends the IGP (IS-IS and OSPF) to compute constraint-based paths that optimize for specific metrics or satisfy defined constraints. Traditional IGP computes shortest paths based on a single metric (cost, delay, or hop count), but networks increasingly require differentiated path selection based on multiple criteria: some traffic demands minimum latency, other traffic requires maximum bandwidth, and still other traffic must avoid specific links or domains. FlexAlgo addresses this by allowing operators to define multiple algorithms within the same IGP instance, each computing paths according to its own optimization objective and constraint set.

In SRv6 networks, FlexAlgo works naturally with the segment routing architecture: when a FlexAlgo is associated with a SID (via the SID's algorithm field), traffic using that SID follows paths computed by that algorithm. This enables per-traffic-class path engineering without signaling overhead—IGP flooding carries the algorithm definition, and source routers compute paths using the appropriate algorithm to generate segment lists.

This chapter explains the FlexAlgo architecture, the algorithm definition process, how FlexAlgo interacts with SRv6 SIDs, the constraint types supported, and deployment scenarios for latency-sensitive, bandwidth-critical, and admin-defined routing policies.

## 19.2 FlexAlgo Fundamentals

### 19.2.1 The Algorithm Field in SID

SRv6 SIDs carry an **algorithm** field in their IGP advertisement that specifies which path computation algorithm applies to traffic using that SID:

```
SID Structure (per IGP advertisement):
+---------------------------------------------------+
| Locator: 48 bits                                  |
| Function: 16 bits                                  |
| Argument: 32 bits (optional)                      |
+---------------------------------------------------+
| Algorithm: 8 bits                                  |
+---------------------------------------------------+

Algorithm Values:
- 0: Shortest Path First (SPF) - default
- 1: Strict SPF (no mid-stack reductions)
- 2-127: User-defined (FlexAlgo)
- 128-255: Reserved for future use
```

When a router advertises a SID with algorithm X, it means: "Traffic destined to this SID should follow the path computed by algorithm X." The ingress router—which builds segment lists—uses the algorithm to compute the path.

### 19.2.2 FlexAlgo Definition

A FlexAlgo is defined by three components:

```
FlexAlgo Definition:
1. Optimization Objective (what to minimize):
   - IGP metric (default, like algorithm 0)
   - TE metric (administrative weight)
   - Latency metric (delay)
   - Hop count

2. Constraints (what to avoid/include):
   - Affinity-based (include/exclude specific links)
   - SRLG (Shared Risk Link Group) exclusion
   - Domain constraints (must/must-not traverse)

3. Calculation Type:
   - SPF (standard shortest path first)
   - CSPF (constrained shortest path first)
```

RFC 9479 defines the FlexAlgo standard for IS-IS; OSPF follows the same conceptual model with its own advertisement mechanisms.

### 19.2.3 FlexAlgo Advertisement

FlexAlgo definitions and SID associations are advertised via IGP:

```
IS-IS FlexAlgo Advertisement:
- TLV 135 (Extended IS reachability): carries per-link metrics per algorithm
- Sub-TLV 149: FlexAlgo definition
- Sub-TLV 150: FlexAlgo prefix-SID advertisement

IS-IS FlexAlgo Definition Sub-TLV (149):
+---------------------------------------------------+
| Type: 149                                         |  (1 byte)
+---------------------------------------------------+
| Length                                           |  (1 byte)
+---------------------------------------------------+
| Algorithm                                        |  (1 byte, 2-127)
+---------------------------------------------------+
| Flags                                            |  (1 byte)
+---------------------------------------------------+
| Metric Type                                      |  (1 byte)
+---------------------------------------------------+
| Priority                                        |  (1 byte)
+---------------------------------------------------+
| Constraint Sources                               |  (variable)
+---------------------------------------------------+
```

The **priority** field determines the order in which multiple FlexAlgo definitions are processed (higher priority = processed first). This matters when one FlexAlgo's constraint set affects another's computation.

## 19.3 FlexAlgo Metric Types

### 19.3.1 IGP Metric (Default)

The default optimization uses the standard IGP metric:

```
Algorithm 0 (Default SPF):
- Minimize sum of IGP link metrics
- Same as traditional shortest-path routing
- Used when no specific TE requirement exists

FlexAlgo 10 (Custom SPF):
- Same metric type as algorithm 0
- But with additional constraints (e.g., affinity)
- Useful when you want SPF topology with link exclusions
```

### 19.3.2 TE Metric

The TE (Traffic Engineering) metric is an administrative weight assigned to links:

```
TE Metric Usage:
- Configured per interface: te-metric <value>
- Allows independent control from IGP metric
- IGP metric may reflect physical distance
- TE metric may reflect capacity, cost, or preference

Example:
Link A-B:
- IGP metric: 10 (directly connected)
- TE metric: 1000 (congested backbone link)

FlexAlgo 20 (minimize-te):
- Would avoid this link despite short IGP distance
- Prefer alternative path with higher IGP metric but lower TE metric
```

### 19.3.3 Latency Metric

Delay-sensitive applications require latency-based path computation:

```
Latency Metric Configuration:
- Interface-level delay measurement
- Static configured delay
- TWAMP-based active measurement
- BFD-based latency monitoring

delay <microseconds>:
- Configure static delay on interface
- Advertised as FlexAlgo metric

Example:
Link A-B: delay 5000 microseconds (5ms)
Link A-C: delay 20000 microseconds (20ms)
Link C-B: delay 3000 microseconds (3ms)

FlexAlgo 30 (minimize-latency):
- Path A-C-B: 20ms + 3ms = 23ms
- Path A-B: 5ms
- Selects A-B despite potentially higher IGP cost
```

### 19.3.4 Hop Count

Some deployments require minimizing the number of hops:

```
Hop Count Optimization:
- Each link counts as 1 hop
- No metric consideration
- Useful for:
  - Satellite networks (per-hop cost high)
  - Low-power devices (processing per hop)
  - Certain regulatory requirements

FlexAlgo 40 (minimize-hop):
- Pure SPF on hop count
- No metric values considered
- Equal-cost paths: load-balance across all equal-hop paths
```

## 19.4 FlexAlgo Constraints

### 19.4.1 Link Affinity Constraints

Link affinity allows operators to color links and select or exclude them:

```
Affinity Definition:
- Each link gets zero or more colors (affinities)
- Colors are 32-bit bitmasks (32 possible colors)
- RFC 8944 defines the affinity encoding

Link Configuration:
interface Ethernet0/0
 description Core-Link
 sr-srv6
  affinity include CYAN
  affinity exclude RED

IS-IS Interface Affinity Sub-TLV:
+---------------------------------------------------+
| Affinity Flags                                    |  (4 bytes)
+---------------------------------------------------+
| Affinity Bit Array (32 colors)                    |  (4 bytes)
+---------------------------------------------------+
```

### 19.4.2 Affinity Constraint Types

FlexAlgo supports several affinity-based constraint types:

```
Affinity Constraint Types:
1. include: Path must use ONLY links with specified affinity
   - "Must use only BLUE links"
   - All links in path must have affinity BLUE

2. include-any: Path must use AT LEAST ONE link with affinity
   - "Must use at least one BLUE link"
   - At least one link has affinity BLUE

3. exclude: Path must NOT use any link with affinity
   - "Must not use RED links"
   - No link in path has affinity RED

4. exclude-all: Path must use ONLY links WITHOUT any specified affinity
   - "Must not use any colored link"
   - No link has any of the specified affinities

Example FlexAlgo Definition:
FlexAlgo 50:
  optimization: minimize-delay
  constraints:
    include: [CYAN, GREEN]
    exclude: [RED, YELLOW]
```

### 19.4.3 Shared Risk Link Groups (SRLG)

SRLG identifies links that share a common failure risk:

```
SRLG Definition:
- Multiple links may share the same fiber conduit
- If conduit fails, all SRLG-member links fail
- SRLG exclusion prevents single-point-of-failure paths

SRLG Configuration:
interface Ethernet0/0
 description First-Fiber-Conduit
 srv6
  srlg 1001

FlexAlgo 60:
  optimization: minimize-te
  constraints:
    exclude-srlg: [1001, 1002]
```

### 19.4.4 Multi-Constraint Paths

Complex policies require multiple simultaneous constraints:

```
Multi-Constraint Example:
FlexAlgo 70 (Low-Latency + High-Bandwidth):
  optimization: minimize-latency
  constraints:
    - Minimum residual bandwidth: 10 Gbps per link
    - Include affinity: [CORE]
    - Exclude affinity: [CONGESTED]
    - Exclude SRLG: [FIBER_ROUTE_1]

Computation Process:
1. Start with full topology
2. Filter out links with CONGESTED affinity
3. Filter out links in FIBER_ROUTE_1 SRLG
4. Filter out links with residual bandwidth < 10 Gbps
5. Filter to only links with CORE affinity
6. Run minimum-latency SPF on filtered topology
```

## 19.5 FlexAlgo in SRv6

### 19.5.1 SID Advertisement with FlexAlgo

SRv6 SID advertisements include the algorithm field:

```
SRv6 Locator Advertisement with Algorithm:
IS-IS SRv6 Locator TLV:
+---------------------------------------------------+
| Locator Length                                   |
+---------------------------------------------------+
| Locator Prefix                                   |
+---------------------------------------------------+
| F Flags (microSID, etc.)                         |
+---------------------------------------------------+
| Algorithm Sub-TLV (per SID in locator)           |
+---------------------------------------------------+

Example:
Locator: FC00:0:1::/48

SID: FC00:0:1:10::  Algorithm: 0   (Default SPF)
SID: FC00:0:1:20::  Algorithm: 10  (minimize-delay)
SID: FC00:0:1:30::  Algorithm: 20  (minimize-te)

When traffic uses SID FC00:0:1:20:::
- Ingress computes path using algorithm 10 (minimize-delay)
- Uses resulting segment list to reach that SID
```

### 19.5.2 Per-Prefix Algorithm Selection

The algorithm field allows fine-grained control:

```
Algorithm Selection by Prefix:

Prefix 10.1.1.0/24:
- Advertised with SID: FC00:0:1:100::  Algorithm: 0
- Traffic uses default SPF

Prefix 10.2.2.0/24 (latency-sensitive):
- Advertised with SID: FC00:0:1:200::  Algorithm: 30 (minimize-latency)
- Traffic to this prefix uses low-latency path

Prefix 10.3.3.0/24 (SLA-critical):
- Advertised with SID: FC00:0:1:300::  Algorithm: 50 (affinity-constrained)
- Traffic uses path satisfying affinity constraints
```

### 19.5.3 FlexAlgo and Segment List Computation

When an ingress router needs to send traffic to a SID with a non-zero algorithm:

```
Segment List Computation Process:
1. Ingress receives packet destined for SID: FC00:0:1:200::
2. SID algorithm field = 30 (minimize-latency)
3. Ingress retrieves FlexAlgo 30 definition from IGP:
   - Metric type: latency
   - Constraints: include [CORE], exclude [CONGESTED]
4. Ingress runs CSPF with:
   - Topology database
   - Metric: latency
   - Constraints: CORE affinity, not CONGESTED
5. Result: shortest-latency path satisfying constraints
6. Ingress builds segment list for that path
7. Packet forwarded using computed segment list
```

## 19.6 FlexAlgo Deployment Scenarios

### 19.6.1 Low-Latency Financial Networks

Financial trading networks require minimum latency:

```
Financial Network FlexAlgo Design:

FlexAlgo 30 (minimimize-latency):
- Metric: interface delay (microseconds)
- Constraints: exclude [EXPEDITED] links
- Use case: Stock trade execution traffic

FlexAlgo 40 (minimize-latency + diversity):
- Metric: latency
- Constraints: include [DIVERSE_PATH]
- Use case: Backup trading links

Example Topology:
[A] --- 1ms --- [B] --- 2ms --- [C]
 |                 |                 |
 5ms              1ms              3ms
 |                 |                 |
[D] --------------- [E] ---------------

Path A-B-C: 1ms + 2ms = 3ms (FlexAlgo 30)
Path A-D-E-C: 5ms + 1ms + 3ms = 9ms (default)
```

### 19.6.2 Service Provider Tier-1 Backbone

Tier-1 backbone operators need bandwidth-aware routing:

```
Backbone FlexAlgo Design:

FlexAlgo 10 (default-spf):
- Metric: IGP cost
- Constraints: none
- Use case: Best-effort traffic

FlexAlgo 20 (minimize-te):
- Metric: TE metric
- Constraints: exclude [MAINTENANCE]
- Use case: Standard TE traffic

FlexAlgo 50 (high-bandwidth):
- Metric: IGP cost
- Constraints:
  - Minimum bandwidth: 100 Gbps
  - Include [HYBRID_CABLE]
- Use case: Bulk data transfer

FlexAlgo 60 (low-latency):
- Metric: latency
- Constraints:
  - Include [DIRECT]
  - Exclude [SATELLITE]
- Use case: Interactive services
```

### 19.6.3 Multi-Tenant Data Center Interconnect

Data center operators need tenant isolation with performance guarantees:

```
DCI FlexAlgo Design:

FlexAlgo 10 (default):
- Per-tenant default routing
- Metric: IGP

FlexAlgo 100 (tenant-a-low-latency):
- Metric: latency
- Constraints: include [TENANT_A_PATH]
- Tenant A's SLA traffic

FlexAlgo 110 (tenant-b-dedicated):
- Metric: IGP
- Constraints: include [TENANT_B_EXCLUSIVE]
- Tenant B's isolated path

FlexAlgo 120 (cross-tenant-shared):
- Metric: IGP
- Constraints: include [SHARED_BACKBONE]
- Cross-tenant services
```

## 19.7 FlexAlgo Interoperability

### 19.7.1 Multi-Domain FlexAlgo

Large networks span multiple IGP domains:

```
Multi-Domain Considerations:
- FlexAlgo definitions must be consistent across domains
- Per-domain computation yields per-domain segments
- End-to-end path requires stitching segments across domains

Domain A FlexAlgo 10: minimize-delay
Domain B FlexAlgo 10: minimize-delay

Path Computation:
1. Compute path in Domain A using FlexAlgo 10
2. Compute path in Domain B using FlexAlgo 10
3. Stitch at domain boundary
4. Result: end-to-end minimum-delay path
```

### 19.7.2 FlexAlgo and SR Policy

FlexAlgo and SR Policy complement each other:

```
FlexAlgo + SR Policy:
1. FlexAlgo computes base path
2. SR Policy provides override or refinement

Use Cases:
- FlexAlgo defines constraint-compliant paths
- SR Policy selects specific candidate path
- SR Policy adds additional constraints or segments

Example:
FlexAlgo 30: minimize-latency
SR Policy: manual selection of specific path
- Operator can override FlexAlgo result if needed
- Maintains network programming flexibility
```

## 19.8 FlexAlgo Configuration

### 19.8.1 IS-IS FlexAlgo Configuration

```
IOS-XR FlexAlgo Configuration:

1. Define FlexAlgo
router isis core
 flex-algo 30
  metric-type latency
  priority 200
  constraint:
   exclude SRLG 1001
   exclude SRLG 1002
   include-any affinity CYAN
  !
 !

2. Configure interface metrics per algorithm
interface GigabitEthernet0/0/0/0
  srv6
   metric 10
   delay 5000
   te-metric 100
  !
 !

3. Advertise SID with specific algorithm
router isis core
 segment-routing srv6
  locator LOC1
   prefix FC00:0:1::/48
   algorithm 30
   !
  !
 !
```

### 19.8.2 OSPF FlexAlgo Configuration

```
IOS-XR OSPF FlexAlgo:

1. Define FlexAlgo
router ospf C
 flex-algo 30
  metric-type latency
  priority 200
  constraint:
   exclude affinity CYAN
  !
 !

2. Configure interface
interface GigabitEthernet0/0/0/0
  ospf
   network point-to-point
   area 0
   srv6
    delay 5000
   !
  !
 !
```

### 19.8.3 Verification Commands

```
show isis flex-algo:
- Display FlexAlgo definitions
- Show constraint sources
- Verify algorithm priority

show isis flex-algo 30:
- Detailed FlexAlgo 30 information
- Constraints applied
- Participating prefixes

show isis segment-routing srv6 sid:
- SID table with algorithm values
- Verify SID association with FlexAlgo

show route segment-routing srv6:
- SID resolution
- Paths computed per algorithm
```

## 19.9 Advanced FlexAlgo Topics

### 19.9.1 FlexAlgo Transition and Stability

FlexAlgo changes require careful handling:

```
Transition Behavior:
1. New FlexAlgo definition advertised
2. Nodes compute new paths
3. Traffic transitions to new paths
4. Old paths removed when no longer needed

Stability Considerations:
- Priority determines convergence order
- Higher priority FlexAlgo computed first
- Transient constraint conflicts possible during transition

Best Practices:
- Use make-before-break for traffic-critical changes
- Validate new paths before removing old
- Monitor for micro-loops during transition
```

### 19.9.2 FlexAlgo Path Diversity

FlexAlgo can provide path diversity for redundancy:

```
Diversity Requirement:
- Primary and backup paths must be disjoint
- No shared links, nodes, or SRLGs

FlexAlgo Design for Diversity:
FlexAlgo 10 (primary):
  - Metric: IGP
  - Constraints: none

FlexAlgo 20 (backup):
  - Metric: IGP
  - Constraints:
    - Exclude-affinity: [PRIMARY_PATH]
    - Include-affinity: [DIVERSE]

Result:
- FlexAlgo 10 and FlexAlgo 20 produce disjoint paths
- Both satisfy respective constraints
- Suitable for 1+1 protection
```

### 19.9.3 FlexAlgo and Traffic Engineering

FlexAlgo is one tool in the TE toolbox:

```
FlexAlgo vs SR Policy:
FlexAlgo:
  - Computed by IGP
  - Per-prefix algorithm selection
  - Implicit path (computed from algorithm)

SR Policy:
  - Explicitly programmed
  - Per-policy segment list
  - Full control over path

Combined Usage:
- FlexAlgo provides constraint-compliant underlay
- SR Policy adds overlay steering
- Both use same SID infrastructure
```

## 19.10 Summary

FlexAlgo extends IGP with constraint-based path computation capabilities essential for modern traffic engineering:

- **Algorithm Field**: The 8-bit algorithm field in SID advertisements links prefixes to computation algorithms, allowing per-prefix path selection based on operator-defined criteria.

- **Metric Types**: FlexAlgo supports IGP metric, TE metric, latency metric, and hop count as optimization objectives, matching diverse traffic requirements.

- **Constraints**: Affinity-based filtering, SRLG exclusion, and multi-constraint combinations enable sophisticated path requirements including bandwidth guarantees, diverse paths, and latency budgets.

- **SRv6 Integration**: When an ingress router needs to forward to a SID with a non-zero algorithm, it runs the corresponding FlexAlgo computation to derive the constraint-compliant path and builds the appropriate segment list.

- **Deployment Scenarios**: FlexAlgo serves financial networks (latency optimization), service provider backbones (bandwidth-aware routing), and multi-tenant DCI (tenant isolation with performance SLAs).

FlexAlgo represents a fundamental shift from single-metric IGP to multi-criteria TE within the IGP infrastructure, enabling sophisticated path engineering without centralized controllers or signaling protocols.

---

