# Chapter 14: SR Policy - Software-Defined Path Steering with Candidate Paths

## 14.1 Overview

SR Policy is the control-plane architecture that programs segment lists onto packets in SRv6 networks. Where the SID identifies a node's processing behavior and the segment list defines a path, SR Policy provides the policy framework that determines which segment list applies to which traffic, how candidate paths are evaluated, and how traffic steers onto optimal paths. SR Policy transforms SRv6 from a mechanism for describing paths into a system for **managing** those paths with the sophistication expected in modern traffic engineering.

This chapter explains the SR Policy architecture, its components (policy, candidate paths, segments), the optimization objectives that drive path selection, the PCE/PCC architecture that computes and distributes policies, and the traffic steering mechanisms that direct flows onto SR Policies.

## 14.2 SR Policy Architecture

### 14.2.1 What is an SR Policy?

An **SR Policy** is a network programming construct that specifies a path for traffic along with the administrative intent (policy) for using that path. It consists of:

```
SR Policy Components:
1. Identifiers:
   - Policy Name (unique within domain)
   - BSID (Binding SID) - optional but recommended
   - Source: Which nodes can use this policy
   - Destination: Endpoint for the policy

2. Candidate Paths:
   - One or more candidate paths
   - Each with a preference (higher = preferred)
   - Each with explicit or dynamic path definition

3. Optimization Objective:
   - The metric to optimize (TE, delay, hop count)
   - Constraints (affinities, SRLG, bandwidth)

4. Steering Rules:
   - How traffic is mapped to this policy
   - Load-balancing across candidate paths
```

SR Policy decouples the **path description** (segment list) from the **policy intent** (optimization goals) from the **traffic classification** (which packets use which policy).

### 14.2.2 SR Policy vs. Traditional TE

Traditional traffic engineering approaches (RSVP-TE, for example) signal paths through the network, reserving resources along the way. SR Policy is fundamentally different:

| Characteristic | RSVP-TE | SR Policy |
|---------------|---------|-----------|
| Path Establishment | Per-flow signaling | Source-based programming |
| State in Network | Per-LSP at every node | Locator-only at transit |
| Resource Reservation | Required | Not required |
| Path Computation | Distributed | Centralized (PCE) or Distributed |
| Rerouting Speed | Slow (re-signal) | Fast (change segment list) |
| Scale | Poor (per-flow state) | Excellent (per-policy state) |

SR Policy achieves scalability because the **network itself doesn't know it's carrying SR Policy**—it just sees IPv6 packets with certain destination addresses. The policy intelligence is at the edges (source and PCE), not in the core.

### 14.2.3 SR Policy Data Model

RFC 9256 defines the SR Policy data model:

```
SR Policy Data Model:
policy:
  identifier: <policy-id>
  name: <policy-name>
  color: <color>            # Classification identifier
  endpoint: <IPv6 prefix>   # Destination prefix

  candidate-paths:
    candidate-path:
      - preference: <pref>
        protocol-origin: <protocol>
        discriminator: <disc>
        path-type: explicit | dynamic

        explicit:
          segment-list: [<SID>, <SID>, ...]

        dynamic:
          optimization-objective: <objective>
          constraints: <constraints>
          computed-path: <computed-SID-list>

        weight: <weight>    # For load-balancing

  steering:
    binding-sid: <BSID>
    traffic-class: <TC>
    priority: <priority>
    filters:
      - <filter-criteria>
```

## 14.3 Candidate Paths

### 14.3.1 Candidate Path Concept

A single SR Policy can contain multiple **candidate paths** representing different ways to reach the same endpoint. The policy selects the active candidate path based on preference and validity.

```
Candidate Path Design:
SR Policy: policy_to_DC1
Endpoint: FC00:DB8::2 (Data Center 1)

Candidate Path 1 (Preference 100):
- Protocol Origin: PCC (locally configured)
- Path Type: Explicit
- Segment List: [A, B, C, D]
- Weight: 1

Candidate Path 2 (Preference 100):
- Protocol Origin: PCEP (PCE computed)
- Path Type: Dynamic
- Optimization: minimize-delay
- Computed Path: [A, X, Y, D]

Candidate Path 3 (Preference 200):
- Protocol Origin: BGP (via route policy)
- Path Type: Explicit
- Segment List: [A, Z, D]
- Weight: 1
```

The **highest preference valid candidate path** is the active path. Equal-preference paths load-balance.

### 14.3.2 Protocol Origin

Candidate paths have a **protocol origin** indicating how they were created:

```
Protocol Origins:
- PCC: Path Computation Client (locally configured)
- PCEP: Computed by PCE and signaled via PCEP
- BGP: Learned via BGP SR Policy advertisement
- IGP: Advertised via IGP (IS-IS/OSPF)
- STATIC: Configured via CLI or management interface
```

The protocol origin influences path validity assessment and transition policies (when to switch from one origin to another).

### 14.3.3 Preference and Validity

Candidate path selection follows this algorithm:

```
Candidate Path Selection:
1. Among all candidate paths for the policy:
   a. Filter to only valid paths (reachability, constraints satisfied)
   b. Select paths with highest preference value

2. If multiple highest-preference paths:
   a. If all have explicit segment lists: load-balance
   b. If some dynamic, some explicit:
      - Typically prefer explicit (more deterministic)
      - Configurable per policy

3. Install selected path(s) in forwarding
```

**Preference values** range from 0-255, with higher values indicating stronger preference. Default preference varies by protocol origin (PCEP paths typically default to 100, BGP to 50, PCC to 200).

### 14.3.4 Path Transition Behavior

When the active candidate path becomes invalid (failure), the policy transitions to the next-best candidate path. The transition behavior is policy-configurable:

```
Transition Behaviors:
1. Make-before-break:
   - Compute and install new path before removing old
   - Minimal traffic disruption

2. Break-before-make:
   - Remove old path, then install new
   - May cause brief traffic drop

3. Manual-only:
   - Don't auto-switch; require explicit operator action
   - For maintenance windows
```

## 14.4 Optimization Objectives

### 14.4.1 What to Optimize

SR Policy optimization objectives define the metric used when computing dynamic paths:

```
Optimization Objectives:
1. minimize-cost:
   - Minimize IGP metric sum
   - Default objective

2. minimize-delay:
   - Minimize sum of interface delays
   - Uses delay metrics in topology

3. minimize-te-metric:
   - Minimize TE metric (administrative weight)
   - Separate from IGP metric

4. minimize-hop:
   - Minimize number of segments
   - For scenarios where fewer hops preferred

5. satify-constraints:
   - Meet constraints without explicit optimization
   - Feasibility determination
```

### 14.4.2 Constraints

Constraints filter which paths are acceptable:

```
Common Constraints:
1. Affinity Constraints:
   - require: links with certain affinities
   - exclude: links without certain affinities
   - Example: "must use links labeled blue"

2. SRLG Constraints:
   - exclude: links in certain SRLGs
   - Example: "avoid SRLG fiber-conduit-1"

3. Bandwidth Constraints:
   - minimum: residual bandwidth required
   - maximum: bandwidth limit
   - Example: "need 10Gbps available"

4. Domain Constraints:
   - include: must traverse certain domains
   - exclude: must not traverse certain domains
   - Example: "must go through PoP-X"

5. Latency Constraints:
   - maximum: end-to-end latency limit
   - Example: "under 5ms RTT"
```

### 14.4.3 Composite Objectives

Real policies often require composite objectives:

```
Composite Objective Example:
"Minimize delay, but ensure:
 - Path uses only links with affinity blue or green
 - Total latency under 10ms
 - At least 5Gbps residual bandwidth on each link"

Computation:
1. Filter topology to links satisfying affinity constraint
2. Further filter to links with required bandwidth
3. Further filter to paths under latency budget
4. Among remaining paths, select minimum-delay path
```

PCE implementations compute such composite constraints efficiently using constrained shortest path first (CSPF) algorithms.

## 14.5 Steering Traffic into SR Policy

### 14.5.1 Steering Mechanisms

Traffic steering maps packets to SR Policies. Several mechanisms exist:

```
Steering Mechanisms:
1. Color-based Steering:
   - Packets with certain color (DSCP, VLAN, etc.) map to policies
   - Policy selected by (endpoint, color) tuple

2. Prefix-based Steering:
   - Destination prefix maps to SR Policy
   - Traditional routing with SR Policy override

3. Flow-based Steering:
   - 5-tuple flows mapped to policies
   - Per-flow TE granularity

4. BSID-based Steering:
   - Packets referencing BSID are forwarded per policy
   - Indirection enables policy changes without packet modification
```

### 14.5.2 Color in SR Policy

**Color** is a 32-bit value that serves as a policy selector, allowing multiple SR Policies to the same endpoint:

```
Color-based Steering Example:
Endpoint: FC00:DB8::/32 (Corporate network)

SR Policy 1:
- Color: 100 (Real-time traffic)
- Objective: minimize-delay
- Segment List: [A, low-latency-node-B, C]

SR Policy 2:
- Color: 200 (Bulk transfer)
- Objective: minimize-cost
- Segment List: [A, cheap-path-X, Y, C]

SR Policy 3:
- Color: 0 (Default)
- Objective: minimize-cost
- Segment List: [A, default-B, C]

Traffic Classification:
- VoIP traffic → Color 100 → Policy 1
- Video conference → Color 100 → Policy 1
- File transfers → Color 200 → Policy 2
- Everything else → Color 0 → Policy 3
```

The source node classifies traffic based on its configured policies and steers accordingly.

### 14.5.3 Binding SID (BSID)

The **Binding SID** (BSID) provides an indirection layer for SR Policy invocation:

```
BSID Mechanism:
1. SR Policy has a BSID (SID value allocated from local space)
2. Traffic steered to policy by referencing BSID in DA
3. Forwarding node resolves BSID → active candidate path
4. Actual segment list installed in FIB

Packet Flow with BSID:
Normal: DA = FC00:0:1:1::1 (first segment)
With BSID: DA = BSID value (resolved to segment list)

When policy changes active candidate path:
- BSID resolution updates
- No packets need to change DA
- Indirection absorbs policy changes transparently
```

BSID is particularly valuable for TI-LFA, where the backup path may change but the BSID remains constant.

### 14.5.4 Load Balancing

When multiple candidate paths have equal preference and are valid, traffic load-balances across them:

```
Load Balancing Strategies:
1. Weighted Hash:
   - Per-flow hash selects candidate path
   - Consistent for same flow

2. Weighted Round-Robin:
   - Packets distributed round-robin
   - Weight determines proportion

3. Weighted Random:
   - Random selection weighted by weight value
   - Statistical balancing

Example:
Path A: Weight 3
Path B: Weight 2
Path C: Weight 1

Traffic distribution: A=50%, B=33%, C=17%
```

## 14.6 PCE and PCC Architecture

### 14.6.1 Path Computation Element (PCE)

The **PCE** is a network entity (can be centralized or distributed) that computes paths for SR Policies. RFC 4657 defines the PCE architecture; SR Policy extends it with segment routing capabilities.

```
PCE Functions:
1. Topology Management:
   - Maintain TED (TE Database) with full topology
   - Learn via IGP or BGP-LS

2. Path Computation:
   - CSPF for constrained paths
   - TE-aware path selection
   - Multi-domain path computation

3. Policy Distribution:
   - PCEP to PCCs for computed paths
   - BGP SR Policy for distributed deployment

4. Monitoring:
   - Path performance telemetry
   - Anomaly detection
```

### 14.6.2 Path Computation Client (PCC)

The **PCC** is the node that originates SR Policy and/or executes steering:

```
PCC Functions:
1. SR Policy Creation:
   - Local policy configuration
   - Request path computation from PCE

2. Segment List Installation:
   - Install segment lists in local FIB
   - Program BSID resolution

3. Traffic Steering:
   - Classify traffic per steering rules
   - Apply policies to packets

4. Path Monitoring:
   - Monitor active path performance
   - Report anomalies to PCE
```

### 14.6.3 PCEP Protocol

PCEP (Path Computation Element Protocol), RFC 5440, carries path computation requests and responses:

```
PCEP Message Exchange:
1. PCC → PCE: PCReq (Path Computation Request)
   - Endpoint
   - Color
   - Optimization objective
   - Constraints

2. PCE → PCC: PCRep (Path Computation Response)
   - Computed segment list
   - Candidate path attributes
   - Preference value

3. PCE → PCC: PCReport (State Report)
   - Policy status changes
   - Path invalidation

4. PCC → PCE: PCInitiate (Policy Initiation)
   - PCE-initiated policy installation
   - Centralized policy deployment
```

### 14.6.4 Distributed vs. Centralized PCE

PCE can be deployed in two architectures:

```
Centralized PCE:
- Single PCE (or redundant pair) computes all paths
- Global optimization possible
- Single point of failure (mitigated by redundancy)
- Scales to thousands of nodes with modern PCEs

Distributed PCE:
- Each node is a PCE
- Per-domain computation
- More resilient
- Less optimal (local vs global view)
- Good for multi-domain with domain boundaries
```

Most large-scale deployments use centralized PCE for global visibility but implement redundancy (active/standby or active/active PCE pairs).

## 14.7 SR Policy in SRv6

### 14.7.1 SR Policy Components in SRv6

SR Policy in SRv6 builds on the SID and behavior architecture:

```
SRv6 SR Policy Mapping:
- Policy Endpoint → IPv6 prefix
- Policy Color → Classification
- Candidate Path Segment List → [SID values]
- BSID → Locally allocated SID
- Steering → Set DA to BSID or first segment
```

### 14.7.2 SID Types in SR Policy

SR Policy segment lists use several SID types:

```
Common SID Types in SR Policy:
1. End.S (Node-SID with next-segment):
   - Advances to next segment after processing

2. End.X (Cross-connect):
   - Forward to specific neighbor
   - For interface-specific steering

3. End.DT6 (VRF lookup):
   - Deliver to specific IPv6 VRF
   - For VPN scenarios

4. End.B6.Encaps (Encapsulation):
   - Push new outer header
   - For service chain insertion
```

### 14.7.3 SR Policy for Transport vs. Service

SR Policy operates at different layers:

```
Transport SR Policy:
- Colors traffic through network underlay
- Segment list contains only transport SIDs (End, End.X)
- Typically low-latency or low-cost paths

Service SR Policy:
- Steers traffic through service functions
- Segment list includes service function SIDs (uSF)
- May chain multiple services
```

Service SR Policies often encapsulate transport SR Policies, with service function SIDs between transport segments.

## 14.8 SR Policy Operations

### 14.8.1 Creating an SR Policy

Manual SR Policy creation via CLI:

```
IOS XR Configuration:
segment-routing
 traffic-eng
  policy srte_1_to_dc1
   color 100
   endpoint fc00:db8::2
   candidate-paths
    preference 100
     explicit
      segment-list
       sidFC00:0:1:1::1
       sid FC00:0:2:2::1
       sid FC00:0:3:3::1
      !
     !
    !
   !
  !
 !
!
```

### 14.8.2 Verifying SR Policy

Operational commands to verify SR Policy:

```
Verification Commands:
show segment-routing traffic-eng policy
show segment-routing traffic-eng policy name <name>
show segment-routing traffic-eng candidate-path
show segment-routing traffic-eng forwarding
```

Key status fields:
- **State**: Operational, Down, Init
- **Active Path**: Which candidate path is active
- **Last Computed**: When path was computed
- **Transition Count**: Number of path switches

### 14.8.3 Monitoring and Troubleshooting

Common SR Policy issues and debug approaches:

```
Issue 1: Policy won't come up
- Check endpoint reachability
- Verify segment SIDs are allocated and advertised
- Check constraint satisfaction

Issue 2: Traffic not steering to policy
- Verify steering configuration
- Check color matching
- Verify BSID resolution

Issue 3: Constant path transitions
- Check for intermittent link failures
- Verify BFD parameters
- Review transition behavior setting

Debug Commands:
debug segment-routing traffic-eng policy
debug segment-routing traffic-eng pce
debug pcep all
```

## 14.9 Advanced SR Policy Topics

### 14.9.1 Multi-Domain SR Policy

SR Policy spanning multiple administrative domains:

```
Multi-Domain Scenario:
Domain A (AS 65001): Internal network
Domain B (AS 65002): Transit provider
Domain C (AS 65003): Destination network

Multi-Domain SR Policy:
- Segment list includes cross-domain SIDs
- Requires BGP SR Policy or PCEP for cross-domain signaling
- PCE协同 (PCE federation) for inter-PCE communication
```

Multi-domain SR Policy is an advanced topic requiring careful coordination of SID allocation and policy intent across domain boundaries.

### 14.9.2 Hierarchical SR Policy

Large networks use hierarchical SR Policy:

```
Hierarchical SR Policy:
Level 1 (Core): Core transport policy
  - Segment list: [Core-node-1, Core-node-2, ...]
  - Objective: minimize-delay
  - Color: 1000

Level 2 (Aggregation): Aggregation transport
  - Segment list: [Agg-node-1, End.S, End.S, ...]
  - References Level 1 BSID where appropriate

Level 3 (Service): Service chain policy
  - Segment list: [Service-1, Service-2, Level-2 BSID]
  - Full path with services
```

This hierarchical structure enables modular policy construction and reuse.

### 14.9.3 Dynamic Path Optimization

PCE can dynamically optimize paths based on telemetry:

```
Dynamic Optimization Loop:
1. PCE monitors active path performance
2. If performance degrades (latency spike, packet loss):
   a. Evaluate alternative candidate paths
   b. If better path available:
      - Compute new segment list
      - Install as higher-preference candidate path
      - Traffic transitions to new path
3. If original path recovers:
   a. Optionally return to original (per policy config)
   b. Or maintain current path if stable
```

This closed-loop optimization provides proactive path adaptation without operator intervention.

## 14.10 Summary

SR Policy provides the control-plane framework for SRv6 traffic engineering:

- **Policy Model**: SR Policy separates intent (what we want) from implementation (how we get there), with candidate paths providing alternate implementations.

- **Candidate Paths**: Multiple candidate paths per policy with preference-based selection, load-balancing across equal-preference paths, and automatic failover on path failure.

- **Optimization Objectives**: Policies specify what to optimize (cost, delay, hops) and constraints to satisfy (bandwidth, affinities, SRLG), allowing the PCE to compute paths meeting policy intent.

- **Traffic Steering**: Steering mechanisms map traffic to policies based on color, prefix, flow, or BSID. Color-based steering with (endpoint, color) tuples provides flexible policy selection.

- **BSID Indirection**: Binding SID provides indirection that absorbs policy changes without packet modification, essential for TI-LFA and dynamic path optimization.

- **PCE/PCC Architecture**: Centralized or distributed path computation with PCEP for policy distribution enables sophisticated TE computation impossible with purely distributed approaches.

- **SRv6 Integration**: SR Policy leverages SRv6 SIDs (End, End.X, End.DT6, etc.) for segment list construction, combining network programming with traffic engineering.

SR Policy transforms SRv6 from a forwarding mechanism into a complete traffic engineering system, enabling the sophisticated path control that modern networks require while maintaining the scalability that SRv6's architecture provides.

---

**References**

- RFC 9256: Segment Routing Policy Architecture
- RFC 5440: Path Computation Element (PCE) Communication Protocol (PCEP)
- RFC 4657: Requirements for Path Computation Element (PCE)
- RFC 8402: Segment Routing Architecture
- RFC 9002: Loop-Free Alternate (LFA) for IPV6 and Segment Routing
- RFC 8667: IS-IS SRv6 Extensions
- RFC 8668: OSPFv3 Extensions for SRv6
- IETF Draft: SR Policy API
- IETF Draft: BGP SR Policy
