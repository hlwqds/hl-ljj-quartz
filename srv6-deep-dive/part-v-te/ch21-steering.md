# Chapter 21: Traffic Steering - LFA, RLFA, TI-LFA, and ECMP

## 21.1 Overview

Traffic steering is the mechanism that determines which path packets take through the network. In SRv6 networks, steering decisions happen at the ingress node based on SR Policies, FlexAlgo associations, and native ECMP capabilities. The steering system must not only place traffic on optimal paths during normal operation but also rapidly redirect traffic when failures occur—the failure protection mechanisms (LFA, RLFA, and TI-LFA) that Chapter 13 introduced in the context of SRv6 forwarding are equally central to the traffic steering architecture.

This chapter examines traffic steering in its full scope: how the ingress node selects among candidate paths, how ECMP provides natural load distribution, how failure protection mechanisms intercept steering decisions to redirect around failures, and how these mechanisms combine to provide both optimal traffic placement and carrier-grade resilience.

## 21.2 Traffic Steering Fundamentals

### 21.2.1 Steering Architecture

Traffic steering in SRv6 operates at the ingress node:

```
Steering Architecture Components:

[Ingress PE]
     |
     | +----------------+
     | | Forwarding     |
     | | FIB            |
     | +----------------+
     | | +------------+ |
     | | | SR Policy  | |---------> Segment List
     | | | Table      | |
     | | +------------+ |
     | | | Color Map  | |---------> Color derivation
     | | +------------+ |
     | | | ECMP Groups| |---------> Load distribution
     | | +------------+ |
     | +----------------+
     |
     v

Packet Processing at Ingress:
1. Packet arrives
2. Extract destination address, DSCP, etc.
3. Determine color (classification)
4. Determine endpoint (usually destination IP)
5. Lookup (endpoint, color) -> SR Policy
6. Select active candidate path
7. Apply segment list
8. Forward
```

### 21.2.2 Steering Criteria

Traffic is classified and mapped to policies based on multiple criteria:

```
Steering Criteria:

1. Destination Prefix:
   - Primary classification mechanism
   - Routes have associated SIDs
   - SID's algorithm determines base path

2. Color (DSCP-based):
   - DSCP value maps to color
   - Color selects SR Policy
   - Example: EF (46) -> color 100

3. Color (Application-based):
   - Application ID maps to color
   - NFlated by DPI or ACL
   - Example: video-app -> color 200

4. Source Prefix:
   - Combined with destination
   - (Src, Dst) tuple -> policy
   - Enables src-based TE

5. Input Interface:
   - Interface-based classification
   - Useful for wholesale services
   - Example: interface 1 -> color 50

6. Flow (5-tuple):
   - Most granular
   - Per-flow policy assignment
   - High overhead, specific use cases
```

### 21.2.3 Steering Resolution Process

The steering resolution follows a specific lookup hierarchy:

```
Steering Resolution (Endpoint, Color):

Step 1: Determine Endpoint
- Use packet destination IP
- Match to longest-prefix route
- Route has associated SID

Step 2: Determine Color
- Extract DSCP from packet
- Lookup color map: DSCP -> color
- Or use default color 0

Step 3: Lookup SR Policy
- Match (endpoint SID, color) tuple
- Find SR Policy with matching color/endpoint
- If no match, use default routing

Step 4: Select Candidate Path
- Among policy's candidate paths
- Select highest-preference valid path
- If equal preference, load-balance

Step 5: Apply Segment List
- Set outer IPv6 DA = first segment
- Install SRH with remaining segments
- Forward into network

Lookup Example:
Packet: dst=10.2.2.2, DSCP=EF (46)

Route lookup: 10.2.2.0/24
- Next-hop SID: FC00:0:1:200:: (algorithm 30)
- Endpoint = FC00:0:1:200::

Color: DSCP EF -> color 100

Policy lookup: (FC00:0:1:200::, color 100)
- Found: SR Policy "low-latency-to-DC1"
- Active CP: preference 100, [A, B, C]

Result: Encapsulate with segment list [A, B, C]
```

## 21.3 ECMP in SRv6

### 21.3.1 ECMP Fundamentals

ECMP (Equal-Cost Multi-Path) provides natural load distribution:

```
ECMP in SRv6:

When multiple equal-cost paths exist to a destination:
- Traffic distributes across all paths
- Per-flow hash ensures packet ordering
- Different flows may use different paths

ECMP vs. SR Policy:
- ECMP: Traffic spreads across IGP-shortest paths
- SR Policy: Explicit path selection
- Can combine: SR Policy to ECMP-enabled path

Example:
IGP Topology:
A --10-- B --10-- C
  \           /
   \---10---/

A to C: Two equal-cost paths (A-B-C, A-C)
ECMP: Traffic load-balanced 50/50
```

### 21.3.2 ECMP with Segment Lists

SRv6's segment routing model handles ECMP naturally:

```
ECMP and Segment List Processing:

Scenario: Path has ECMP at middle node

Segment List: [A, B, C]
- Node A: End behavior, SL=2, DA=B
- Node B: End.X to C or End.X to C' (ECMP)

When packet reaches B:
- B has two equal-cost next-hops to C
- B selects one based on hash
- B executes End.X, forwards to selected interface

Result:
- Some packets go B->C
- Some packets go B->C'
- Both paths reach C (ultimate destination)

The segment list doesn't change; ECMP happens under the segment.
```

### 21.3.3 Weighted ECMP

SR Policy can provide weighted distribution across paths:

```
Weighted ECMP via SR Policy:

SR Policy with multiple equal-preference CPs:
CP1: segment-list [A, B, C], weight 3
CP2: segment-list [A, X, Y, C], weight 2
CP3: segment-list [A, Z, C], weight 1

Load distribution:
- Total weight: 6
- CP1: 50% (3/6)
- CP2: 33% (2/6)
- CP3: 17% (1/6)

Flow Hash -> Candidate Path Selection:
- Hash result mod 6 selects bucket
- Bucket maps to candidate path
- Per-flow consistency maintained
```

### 21.3.4 UCMP (Unequal-Cost ECMP)

UCMP provides bandwidth-aware unequal distribution:

```
UCMP (Unequal-Cost ECMP):

When paths have different bandwidth capacities:
- Higher-capacity path gets more traffic
- Bandwidth-normalized weights

Example:
Path 1: 10 Gbps capacity, 10ms latency
Path 2: 5 Gbps capacity, 5ms latency

UCMP Weights:
- Path 1: 2x weight (relative to Path 2)
- Path 2: 1x weight

Traffic Distribution:
- Path 1: 67% (2/3)
- Path 2: 33% (1/3)

UCMP Configuration:
SR Policy:
  candidate-path preference 100
    dynamic
     optimization minimize-te
     ucmp
      variance 2
     !
    !
```

## 21.4 LFA (Loop-Free Alternate)

### 21.4.1 LFA Fundamentals

LFA provides pre-computed backup paths for link failures:

```
LFA Concept:

Primary Path: A -> B -> C
Backup Path: A -> D -> C (when A-B link fails)

LFA Condition:
For backup path to be loop-free:
- Distance(A->D) < Distance(A->B) + Distance(B->C)
- D is closer to C than the failing link

This ensures traffic doesn't loop back toward failure.

Link-Protection LFA:
- Protects against single link failure
- Pre-computed for each protected link
- Activated instantly on failure
```

### 21.4.2 LFA Computation

LFA uses the network's metric topology:

```
LFA Computation Algorithm:

For each link (U,V) requiring protection:
1. Find pre-convergence path: U -> ... -> V
2. Find loop-free neighbors N of U:
   - Distance(N, V) < Distance(N, U) + Distance(U, V)
3. Among loop-free neighbors, find those that reach destination:
   - Distance(N, destination) < Distance(N, U) + Distance(U, destination)
4. Select backup next-hop from qualifying neighbors

Example:
Topology:
    C
   /|
  / |
 A--B--D--E
     |
     F

A to E via A-B-D-E
Protect link A-B:
- Loop-free neighbor: C
- Distance(C, B) = 20, Distance(C, A) = 10 + Distance(A, B) = 30
- 20 < 10 + 30 = 40, so C is loop-free

Backup path: A-C-B-D-E (when A-B fails)
```

### 21.4.3 LFA Limitations

LFA doesn't always provide coverage:

```
LFA Coverage Limitations:

1. Topological Constraints:
   - Not all links have loop-free alternates
   - Some nodes have no qualifying backup
   - Coverage typically 80-90% in random topologies

2. Per-Prefix vs Per-Link:
   - Per-link LFA: protects specific link
   - Per-prefix LFA: protects destination
   - Different coverage characteristics

3. Shared Risk:
   - LFA and primary may share SRLG
   - Single failure takes both out
   - LFA is link-protection only

4. Metric Sensitivity:
   - LFA depends on metric relationships
   - Changes in metrics may invalidate backup
   - Requires periodic re-computation
```

## 21.5 RLFA (Remote LFA)

### 21.5.1 RLFA Concept

RLFA extends LFA by tunneling to remote nodes:

```
RLFA Fundamentals:

Problem: LFA coverage gaps
Solution: Tunnel to a Remote Node (PQ node) that provides coverage

RLFA Terminology:
- P: Protected node
- Q: Destination (or next node toward destination)
- LFA Node: Direct neighbor of P providing LFA
- PQ Node: Remote node that can reach Q without passing through P

PQ Node Selection:
- Must not be in the failure zone (link P-Q)
- Must have path to Q that doesn't go through P
- Must be reachable from P

Tunnel Types:
- LDP tunnel (for RLFA with MPLS)
- SR-TE tunnel (for RLFA with SR-MPLS)
- No specific tunnel type for SRv6 (uses native)
```

### 21.5.2 RLFA Computation

```
RLFA Algorithm:

For link (P, Q) requiring protection:

1. Find area where failure affects paths:
   - Nodes whose shortest path to Q goes through P

2. Find PQ nodes:
   - Node X is PQ node if:
     a. P can reach X directly (1-hop)
     b. X can reach Q without going through P
     c. X is not in failure zone

3. Select PQ node:
   - Prefer nodes closer to Q
   - Prefer nodes with lower tunnel cost

4. Build tunnel:
   - P -> X: Direct adjacency or single tunnel
   - X -> Q: Normal forwarding

Example:
A --- B --- C --- D
          |
          E

Protect B-C:
- Direct LFA from B: E is loop-free
- Backup: B -> E -> C -> D

When B-C fails:
- B sends traffic to E (LFA)
- E forwards normally (path to C doesn't use B-C)
- Traffic reaches D via E-C-D
```

### 21.5.3 RLFA with SRv6

SRv6's source routing simplifies RLFA:

```
RLFA in SRv6 Environment:

SRv6 RLFA works differently than MPLS RLFA:

1. No Label Distribution Needed:
   - P knows Q's SID
   - P knows PQ node's SID
   - Direct segment programming

2. PQ Node as Segment:
   - PQ node has End.SID
   - Segment list: [PQ, ...rest of path]
   - P programs packet with PQ segment

3. Two-Level Protection:
   - If primary is [A, B, C]:
   - LFA backup is [A, E, B, C]
   - Packet has both primary and backup encoded

SRv6 RLFA Segment List Construction:

Primary path: A -> B -> C -> D
Segment list: [End(B), End(C), End(D)]

Protect B-C:
- PQ node: E
- Backup segment list: [End(E), End(C), End(D)]

When B-C fails:
- Packets already at A use [End(E), End(C), End(D)]
- Traffic goes A -> E -> C -> D
- E executes End, forwards to C
```

## 21.6 TI-LFA (Topology-Independent LFA)

### 21.6.1 TI-LFA Fundamentals

TI-LFA provides guaranteed protection coverage:

```
TI-LFA Overview:

Problem with LFA/RLFA:
- Coverage not 100%
- Depends on topology
- Some failure scenarios uncovered

TI-LFA Solution:
- Use SR segment list for backup
- Pre-compute backup path via SR computation
- Guarantees protection by encoding entire backup

Key TI-LFA Properties:
1. 100% Coverage:
   - Any link/node can be protected
   - No topological dependencies
   - Works in any network topology

2. Sub-50ms Protection:
   - Pre-computed backup path
   - No on-demand computation
   - Instant activation

3. Segment List Based:
   - Backup as explicit segment list
   - Works with SRv6 natively
   - Doesn't require tunneling
```

### 21.6.2 TI-LFA Algorithm

```
TI-LFA Computation Algorithm:

For protected path P -> Q (via primary next-hop N):

1. Post-Convergence Path:
   - What path would be used after failure?
   - Run SPF from N with link (P,N) removed
   - Get post-convergence path to Q

2. Repair Segment List:
   - Start from P
   - If link (P,N) fails: go to PQ node X
   - Then follow post-convergence path from X
   - Encode as segment list

3. Compute Repair Path:
   Let:
   - P = point of failure detection
   - N = primary next-hop from P
   - X = PQ node (remote or direct)
   - R = destination

   Primary: P -> N -> ... -> R
   Repair: P -> X -> ... -> R

   Where X is the first node on post-convergence path
   that is not P and not N.

Example:
Topology:
A --- B --- C --- D
          |
          E --- F

Primary: A -> B -> C -> D
Protect: B-C link

Post-convergence (B-C failed):
B -> E -> F -> C -> D

TI-LFA Repair:
A -> B (fails at B)

Repair path: B -> E -> F -> C -> D
Segment list: [End(E), End(F), End(C), End(D)]

When B-C fails:
- At A, segment list installed
- Packet goes A -> E -> F -> C -> D
- B-C failure bypassed
```

### 21.6.3 TI-LFA Implementation

```
TI-LFA with SR Policy:

TI-LFA backup paths are implemented as SR Policy:

Primary SR Policy:
- Name: primary-to-D
- Segment list: [A, B, C, D]

TI-LFA Protection:
- Backup CP: [A, E, F, C, D]
- Activated when B-C link fails
- Pre-installed in FIB

Activation Mechanism:
1. Interface failure detected
2. FIB entries depending on that interface invalidated
3. TI-LFA backup already pre-computed
4. Instant redirect to backup path

Make-Before-Break:
- Compute backup before failure
- Install backup in parallel with primary
- Switchover instant on failure
- No computation time required
```

### 21.6.4 TI-LFA vs RLFA

```
TI-LFA vs RLFA Comparison:

| Aspect             | RLFA                       | TI-LFA                     |
|--------------------|----------------------------|----------------------------|
| Coverage           | 90-95%                     | 100%                       |
| Computation        | Remote node lookup         | Full CSPF                  |
| Tunnel Required    | Yes (LDP/SR)               | No (native segment list)  |
| Complexity         | Moderate                   | Higher                     |
| Backup Format      | Tunnel to PQ               | Explicit segment list     |
| SRv6 Native        | No (needs tunneling)       | Yes (segment list)        |

TI-LFA Advantages:
- Works where RLFA doesn't
- Native SRv6 (no tunneling)
- Consistent with SR architecture
- Per-segment protection

RLFA Advantages:
- Less computation
- Works with existing LDP
- Simpler in some cases
- Good for partial deployment
```

## 21.7 Combined Steering and Protection

### 21.7.1 Multi-Layer Protection

Modern networks combine multiple protection mechanisms:

```
Protection Layers:

Layer 1: Local LFA (Fastest)
- Detects local link failure
- Immediate redirect (0 ms)
- Limited coverage (~80%)

Layer 2: TI-LFA (Comprehensive)
- Pre-computed backup
- Activated on failure detection
- 100% coverage, <50ms

Layer 3: Re-optimization (Long-term)
- PCE detects failure
- Computes new optimal path
- Moves traffic after stabilization

Timeline:
T=0:    Failure occurs
T<1ms:  Local LFA activates (if available)
T<50ms: TI-LFA activates (if LFA unavailable)
T>1s:   PCE re-optimization completes
T>10s:  Traffic on optimal post-failure path
```

### 21.7.2 Steering with Protection

SR Policy includes both primary and backup paths:

```
SR Policy with Protection:

SR Policy Structure:
policy to-DC1
  color 100
  endpoint FC00:DB8::2

  candidate-path PREFERENCE 100
    path-type dynamic
    optimization minimize-delay
    TI-LFA protection enabled
    segment-list [A, B, C, D]
    ! This implicitly creates backup path

  candidate-path PREFERENCE 50
    path-type explicit
    segment-list [A, X, Y, C, D]
    ! Manual backup path
```

### 21.7.3 Failure Domain Isolation

TI-LFA localizes failure impact:

```
Failure Domain Isolation:

When link fails within TI-LFA backup path:
- Only affected segment list fails
- Other traffic unaffected
- Micro-loop prevention

Example:
Primary: A -> B -> C -> D
Backup:  A -> X -> Y -> C -> D

If Y-Z link fails (not on backup path):
- Backup still works: A -> X -> Y -> C -> D
- No impact on this traffic

If X-Y link fails:
- TI-LFA at X activates
- X's TI-LFA: X -> ... -> Y -> C -> D
- X's local protection handles it
```

## 21.8 Traffic Engineering Scenarios

### 21.8.1 Latency-Sensitive Traffic

Voice and video require low-latency paths:

```
Latency-Sensitive Steering:

Classification:
- VoIP: DSCP EF (46) -> color 100
- Video Conference: DSCP AF41 (34) -> color 100

Policy for Color 100:
SR Policy: LOW-LATENCY
  color 100
  endpoint any
  candidate-path preference 100
    dynamic
      optimization flex-algo 30
      ! Minimize latency
    !
  !
  TI-LFA protection

Result:
- VoIP and video use minimum-latency paths
- TI-LFA provides sub-50ms protection
- Failure redirects to next-best latency path
```

### 21.8.2 Bandwidth-Intensive Traffic

Bulk transfers require high-capacity paths:

```
Bandwidth-Intensive Steering:

Classification:
- Backup: DSCP BE (0) -> color 0
- File Transfer: Application ID -> color 200
- Database Replication: color 200

Policy for Color 200:
SR Policy: HIGH-BANDWIDTH
  color 200
  endpoint any
  candidate-path preference 100
    dynamic
      optimization minimize-te
      constraints
        minimum-bandwidth 10 Gbps
      !
    !
  candidate-path preference 50
    dynamic
      optimization minimize-igp
    ! Backup if bandwidth constraint fails

Result:
- Bulk transfers use 10G+-capacity paths
- Failover to any available path
- Best-effort uses default routing
```

### 21.8.3 Multi-Tenant Isolation

Each tenant requires isolated paths:

```
Multi-Tenant Steering:

Tenant A Traffic:
- Source: 10.1.0.0/16
- Color: 100
- Policy: TENANT-A-PRIMARY

Tenant B Traffic:
- Source: 10.2.0.0/16
- Color: 200
- Policy: TENANT-B-PRIMARY

Policies:
TENANT-A-PRIMARY:
  color 100
  endpoint any
  constraints
    affinity include TENANT-A-PATH
  !

TENANT-B-PRIMARY:
  color 200
  endpoint any
  constraints
    affinity include TENANT-B-PATH
  !

Result:
- Tenant A traffic only on Tenant-A paths
- Tenant B traffic only on Tenant-B paths
- Complete tenant isolation
```

## 21.9 Advanced Steering Topics

### 21.9.1 Per-Flow Steering

Maximum granularity for specific flows:

```
Per-Flow Steering:

Classification at Ingress:
- 5-tuple: src-ip, dst-ip, src-port, dst-port, protocol
- Creates micro-flows
- Each micro-flow can have own policy

Implementation:
- ACL to classify
- Policy-based steering
- High scale but high overhead

Use Cases:
- Financial trading (latency per-trade)
- Scientific computing (specific flows)
- Regulatory requirements (audit per flow)

Scale Considerations:
- 100K flows = 100K policies (not scalable)
- Use aggregation: flow-group -> policy
- Flow-group based on common characteristics
```

### 21.9.2 Bidirectional Traffic Alignment

Ensure forward and reverse paths match:

```
Bidirectional Steering:

Problem:
- Forward path: A -> B -> C -> D
- Reverse path: D -> C -> B -> A
- Asymmetric paths may cause issues

Solution:
- Steering policy for both directions
- Use same segment list for both
- Or use uSID to encode path affinity

Implementation:
SR Policy: BIDIR-LOW-LATENCY
  color 100
  bidirectional
    forward: [A, B, C, D]
    reverse: [D, C, B, A]
  !

Both directions use same path
Symmetric latency guaranteed
```

### 21.9.3 Segment List Length Optimization

Long segment lists impact efficiency:

```
Segment List Optimization:

Problem:
- Long segment lists: many SIDs
- Each SID 128 bits + overhead
- MTU constraints

Optimization Techniques:

1. ECMP Compression:
   - Multiple equal paths: use single segment
   - ECMP within segment execution

2. uSID Compression:
   - 128-bit SID -> 32-bit uSID
   - Up to 4 uSID in single 128-bit word
   - Dramatically reduces header size

3. Hierarchical Steering:
   - End.BM for sub-policies
   - Stitch paths at midpoints
   - Shorter per-packet lists

4. FlexAlgo Offload:
   - Use FlexAlgo instead of explicit segments
   - Single SID implies algorithm
   - Ingress computes path implicitly
```

## 21.10 Summary

Traffic steering in SRv6 combines multiple mechanisms to place traffic on optimal paths and maintain that placement through failures:

- **Classification and Resolution**: Traffic is classified by destination, DSCP, source, interface, or flow, mapped to a color, and resolved to an SR Policy based on the (endpoint, color) tuple.

- **ECMP**: Equal-cost multi-path provides natural load distribution across parallel links, with weighted variants (UCMP) for bandwidth-aware distribution.

- **LFA**: Loop-Free Alternate provides instant link protection using pre-computed backup next-hops that satisfy the loop-free condition, but coverage is topology-dependent (~80-90%).

- **RLFA**: Remote LFA extends LFA coverage by tunneling to PQ nodes that can reach the destination without traversing the protected link, increasing coverage to ~95%.

- **TI-LFA**: Topology-Independent LFA provides 100% protection coverage by pre-computing complete backup segment lists via constrained SPF. It works natively with SRv6's source-routing model and provides sub-50ms protection.

- **Combined Operation**: Modern deployments layer local LFA for fastest protection, TI-LFA for comprehensive coverage, and PCE-driven re-optimization for long-term optimality.

Understanding steering and protection mechanisms is essential for designing resilient SRv6 networks that meet service-level objectives during both normal operation and failure scenarios.

---

