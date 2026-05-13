# Chapter 20: SR-TE - Segment Routing Traffic Engineering Architecture

## 20.1 Overview

SR-TE (Segment Routing Traffic Engineering) combines the source-routing paradigm of Segment Routing with traffic engineering capabilities that enable fine-grained control over path selection, resource utilization, and traffic distribution. Unlike traditional RSVP-TE that signals per-flow state through the network, SR-TE operates entirely from the ingress node—the source computes the path, encodes it as a segment list, and the network simply forwards packets according to the source-defined path. This architectural difference yields dramatic improvements in scalability, convergence speed, and operational simplicity while providing equivalent or superior traffic engineering control.

SR-TE builds directly on SR Policy (Chapter 14) and FlexAlgo (Chapter 19) foundations: SR Policy provides the control-plane framework for managing path candidates and steering traffic, FlexAlgo provides constraint-based path computation within IGP, and SR-TE orchestrates both to deliver end-to-end traffic engineering across the network. This chapter presents the SR-TE architecture, the relationship between SR-TE and SR Policy, path computation mechanisms including PCE/PCC, the SR-TE tunnel model, and practical deployment considerations.

## 20.2 SR-TE Architecture Overview

### 20.2.1 What is SR-TE?

SR-TE is the application of Segment Routing principles to solve traffic engineering problems:

```
SR-TE Definition:
- Engineering traffic to follow specific paths
- Balancing load across network resources
- Meeting service-level objectives (latency, bandwidth)
- Protecting traffic against failures

SR-TE Characteristics:
- Source-based: Path computed at ingress
- Stateless core: Transit nodes maintain no per-flow state
- Policy-driven: Traffic mapped to policies
- Constraint-aware: Paths satisfy configured constraints
```

The key insight of SR-TE is that the network core does not need to know about TE—it merely executes the segment instructions provided by the source. This "source intelligence, stateless core" model is what enables SR-TE to scale to massive networks while maintaining precise traffic control.

### 20.2.2 SR-TE vs Traditional TE

Comparing SR-TE with RSVP-TE highlights the architectural differences:

```
| Aspect              | RSVP-TE                    | SR-TE                          |
|---------------------|----------------------------|--------------------------------|
| Architecture        | Distributed signaling      | Source-based computation       |
| Path State          | Per-LSP at every node     | Segment list at ingress only   |
| Scalability         | O(N) per LSP in network   | O(1) at each transit node      |
| Convergence         | Re-signal on failure      | Pre-computed backup segments   |
| Path Control        | Full but complex           | Full and simpler               |
| Residual Bandwidth  | Hard admission control     | No reservation needed          |
| Signaling Protocol  | RSVP-TE                   | None (uses IGP for topology)   |
| Control Plane       | RSVP + IGP                | IGP + optional PCE             |
```

RSVP-TE's per-LSP state at every node creates scaling challenges in large networks. Each LSP requires reservation state at each transit LSR. SR-TE eliminates this by encoding the entire path in the packet header—the network just does destination-address routing.

### 20.2.3 SR-TE Components

SR-TE involves several interacting components:

```
SR-TE Component Architecture:

[Controller/PCE]
     |
     | PCEP / BGP SR Policy
     v
[Ingress PE (PCC)]
     |
     | Segment Lists
     v
[Transit Routers] (stateless forwarding)
     |
     v
[Egress PE]

Components:
1. PCC (Path Computation Client):
   - Resides at ingress node
   - Creates and manages SR Policies
   - Executes traffic steering

2. PCE (Path Computation Element):
   - Computes paths on behalf of PCCs
   - Maintains TED (TE Database)
   - Can push policies to PCCs

3. SR Policy:
   - Path definition (segment list)
   - Candidate paths with preferences
   - Steering rules

4. IGP (IS-IS/OSPF):
   - Advertises topology
   - Advertises SID reachability
   - Carries FlexAlgo definitions
```

## 20.3 SR-TE Tunnel Model

### 20.3.1 SR-TE Tunnel Concept

SR-TE operates on a tunnel model similar to traditional TE:

```
SR-TE Tunnel:
- One-way tunnel from ingress to egress
- Carries traffic matching steering criteria
- Defined by SR Policy
- May have multiple candidate paths

Tunnel vs SR Policy:
- Tunnel: The forwarding construct (what packet sees)
- SR Policy: The control-plane definition (how tunnel is programmed)

In practice, "SR-TE tunnel" and "SR Policy" are often used interchangeably,
because the SR Policy creates and manages the tunnel.
```

### 20.3.2 Tunnel Establishment

SR-TE tunnel establishment differs fundamentally from RSVP-TE:

```
RSVP-TE LSP Establishment:
1. Ingress sends RSVP PATH message
2. Each transit node reserves resources
3. Egress sends RSVP RESV with labels
4. State installed at each node
5. Data can flow

SR-TE Tunnel Establishment:
1. Controller/PCC computes path (via IGP topology)
2. Segment list generated
3. SR Policy created with segment list
4. Segment list installed in ingress FIB
5. Traffic steered onto policy
6. Data can flow
```

No signaling traverses the network for SR-TE. The entire path computation and setup happens at the ingress.

### 20.3.3 Tunnel Types

SR-TE supports several tunnel types:

```
SR-TE Tunnel Types:

1. Static SR-TE Tunnel:
   - Segment list configured manually
   - No PCE involved
   - Operator defines exact path

   Example:
   SR Policy name "to-DC1"
     segment-list [A, B, C]
     color 100
     endpoint FC00:DB8::2

2. Dynamic SR-TE Tunnel:
   - PCE computes path based on constraints
   - Segment list generated algorithmically
   - Can adapt to topology changes

   Example:
   SR Policy name "to-DC1-low-latency"
     optimization: minimize-latency
     constraints:
       bandwidth minimum 1 Gbps
     color 100
     endpoint FC00:DB8::2

3. Steering-Only:
   - Uses default IGP path
   - Steering rules apply
   - No explicit segment list

   Example:
   SR Policy name "default-to-DC1"
     color 100
     endpoint FC00:DB8::2
     (uses IGP path, applies color-based steering)
```

## 20.4 Path Computation with PCE

### 20.4.1 PCE Architecture

The PCE (Path Computation Element) provides centralized path computation:

```
PCE Functions:

1. Topology Database (TED):
   - Receives IGP updates (IS-IS/OSPF)
   - Optionally receives BGP-LS updates
   - Maintains complete network topology

2. Path Computation:
   - CSPF (Constrained Shortest Path First)
   - Multi-constraint optimization
   - Multi-domain path computation

3. Policy Distribution:
   - PCEP to PCCs
   - BGP SR Policy advertisement
   - PCInitiate for PCC-controlled domains

4. Monitoring:
   - Path performance telemetry
   - Anomaly detection
   - Path re-optimization triggers
```

### 20.4.2 PCC Architecture

The PCC (Path Computation Client) is the ingress node:

```
PCC Functions:

1. Local Policy Configuration:
   - CLI-defined SR Policies
   - Request computation from PCE

2. Segment List Management:
   - Store computed segment lists
   - Install in FIB
   - Manage candidate paths

3. Traffic Steering:
   - Classify traffic to policies
   - Apply color-based steering
   - Per-flow or aggregate steering

4. Path Monitoring:
   - Liveness detection
   - Performance measurement
   - Report to PCE
```

### 20.4.3 PCEP Protocol

PCEP (Path Computation Element Protocol) carries requests and responses:

```
PCEP Message Exchange:

PCC                                PCE
  |                                  |
  | ---- PCReq (Path Computation) --> |  (request path to destination)
  |                                  |
  | <--- PCRep (Segment List) ------- |  (computed path)
  |                                  |
  | ---- PCRpt (State Report) -----> |  (policy status)
  |                                  |
  | <--- PCInitiate ----------------- |  (PCE-initiated policy)
  |                                  |
  | ---- PCUpd (Policy Update) ----> |  (path change notification)

PCReq Message:
+---------------------------------------------------+
| Request Parameters:                               |
|   - Endpoint (IPv6/IPv4 prefix)                   |
|   - Color (optional)                              |
|   - Optimization objective                        |
|   - Constraints (affinity, bandwidth, etc.)       |
|   - Path name/lifetime                            |
+---------------------------------------------------+

PCRep Message:
+---------------------------------------------------+
| Computed Path:                                     |
|   - Segment list [SID, SID, ...]                  |
|   - Candidate path attributes                     |
|   - Preference value                               |
|   - Protocol origin                               |
+---------------------------------------------------+
```

### 20.4.4 PCE Deployment Models

PCE can be deployed in several architectures:

```
PCE Deployment Models:

1. External PCE (Centralized):
   - Dedicated PCE server/cluster
   - Central point for path computation
   - Global optimization possible
   - Single point of failure (mitigated by redundancy)

2. Embedded PCE (Distributed):
   - PCE function on each router
   - Per-node computation
   - Domain-local paths only
   - No global optimization

3. Stateful PCE:
   - PCE maintains SR Policy state
   - PCC reports policy state to PCE
   - PCE can trigger re-optimization
   - Synchronized policy database

4. Stateless PCE:
   - PCE computes on-demand
   - No policy state maintained
   - PCC owns policy state
   - Lower PCE resource requirements

5. Hybrid:
   - Local PCE for fast local paths
   - External PCE for multi-domain
   - Best of both approaches
```

## 20.5 SR-TE Candidate Paths

### 20.5.1 Multiple Candidate Paths

SR Policies (Chapter 14) introduced candidate paths; here we examine SR-TE-specific aspects:

```
SR-TE Candidate Paths:

SR Policy: "to-DC1" (color 100, endpoint DC1)

Candidate Path 1 (Preference 100):
- Protocol Origin: PCEP (from PCE)
- Dynamic
- Optimization: minimize-delay
- Computed via PCE

Candidate Path 2 (Preference 100):
- Protocol Origin: BGP (from route policy)
- Explicit
- Segment List: [A, B, C]
- Operator-defined

Candidate Path 3 (Preference 200):
- Protocol Origin: PCC (local config)
- Explicit
- Segment List: [A, X, Y, C]
- Operator-defined (highest preference)

Active Path Selection:
- Highest preference: Candidate Path 3
- Installed in forwarding
- Traffic steered to segment list [A, X, Y, C]
```

### 20.5.2 Path Protection

SR-TE supports pre-computed backup paths for fast reroute:

```
Path Protection in SR-TE:

1. Candidate Path Protection:
   - Primary CP: preference 100
   - Backup CP: preference 50
   - Automatic failover on primary failure

2. TI-LFA Protection (Chapter 13):
   - Per-segment backup via SR Policy
   - Pre-computed from segment list
   - Sub-50ms activation

3. 1+1 Protection:
   - Two disjoint candidate paths
   - Traffic replicated on both
   - Egress selects correct copy

4. 1:1 Protection:
   - Primary and backup paths
   - Traffic on primary only
   - Switch to backup on failure
```

### 20.5.3 Path Re-optimization

SR-TE can automatically re-optimize paths:

```
Re-optimization Triggers:

1. Timer-based:
   - Periodic re-evaluation
   - E.g., every 5 minutes
   - Ensures paths adapt to topology changes

2. Bandwidth-based:
   - Re-optimize when bandwidth threshold crossed
   - E.g., link utilization > 80%
   - Find less congested path

3. Performance-based:
   - Re-optimize on latency degradation
   - Performance telemetry indicates problem
   - Find better-latency path

4. Event-based:
   - Link failure/restore
   - New link added
   - Re-evaluate affected paths

Re-optimization Process:
1. PCE detects re-optimization trigger
2. Compute new path with same constraints
3. Compare new path to current path
4. If better: initiate make-before-break
5. Traffic moves to new path
6. Old path removed
```

## 20.6 Traffic Steering

### 20.6.1 Steering Mechanisms

Traffic steering maps packets to SR-TE tunnels:

```
Steering Mechanisms:

1. Color-Based Steering:
   - Packet color matched to SR Policy color
   - Color derived from:
     - DSCP value
     - Application ID
     - Flow label
     - Input interface

   Example:
   DSCP EF (46) -> Color 100 (low-latency)
   DSCP BE (0) -> Color 0 (default)

2. Prefix-Based Steering:
   - Destination prefix matched to SR Policy
   - Policy resolved based on (prefix, color)

   Example:
   10.1.1.0/24 -> SR Policy with color 100
   10.2.2.0/24 -> SR Policy with color 200

3. Flow-Based Steering:
   - 5-tuple flow classification
   - Per-flow SR Policy assignment
   - Fine-grained control

4. BSID-Based Steering:
   - Packet references BSID
   - BSID resolves to active candidate path
   - Transparent to application
```

### 20.6.2 Steering Resolution

The steering resolution process:

```
Steering Resolution at Ingress:

1. Packet arrives at ingress
2. Extract packet characteristics:
   - Destination IP
   - DSCP value
   - Source IP, ports (for flow)
   - Input interface

3. Determine color:
   - Match DSCP to color map
   - Or use default color

4. Determine endpoint:
   - Use packet destination
   - Or use configured mapping

5. Lookup SR Policy:
   - Match (endpoint, color) tuple
   - Find active candidate path

6. Apply segment list:
   - Set outer IPv6 DA to first segment
   - Install SRH with remaining segments
   - Forward packet

Resolution Table:
(endpoint, color) -> SR Policy -> Candidate Path -> Segment List

Examples:
(FC00:DB8::2, 100) -> policy-100 -> CP1 -> [A, B, C]
(FC00:DB8::2, 200) -> policy-200 -> CP1 -> [A, X, Y, C]
(FC00:DB8::2, 0)   -> policy-default -> CP1 -> [A, default-B, C]
```

### 20.6.3 Dynamic Bucket Steering

Load balancing across candidate paths uses weighted distribution:

```
Dynamic Bucket Steering:

When multiple equal-preference candidate paths exist:
- Each bucket assigned to one candidate path
- Bucket count proportional to weight
- Flow hash selects bucket
- Consistent re-hashing on candidate path change

Example:
CP1: weight 3 (3 buckets)
CP2: weight 2 (2 buckets)
CP3: weight 1 (1 bucket)

Total buckets: 6

Flow Hash -> Bucket 1-6:
- Buckets 1-3 -> CP1
- Buckets 4-5 -> CP2
- Bucket 6   -> CP3

Load Distribution: 50% / 33% / 17%
```

## 20.7 SR-TE for SRv6

### 20.7.1 SR-TE SID Types in SRv6

SR-TE in SRv6 uses specific SID types:

```
SID Types for SR-TE:

1. End (Node-SID):
   - Simple endpoint
   - Advances SL and updates DA
   - For generic path construction

2. End.X (Cross-Connect SID):
   - Forward to specific neighbor
   - Interface-specific steering
   - Use when link selection matters

3. End.B6.Encaps (Encapsulation SID):
   - Push new SRv6 header
   - For service chaining
   - Add encapsulation layer

4. End.BM (Binding MIDpoint SID):
   - Reference to SR Policy
   - For hierarchical SR-TE
   - Mid-point stitching

5. uSID (microSID):
   - Compressed SID format
   - 32-bit instead of 128-bit
   - Hardware-optimized
```

### 20.7.2 SR-TE for VPN Services

SR-TE commonly engineers VPN traffic:

```
SR-TE VPN Scenarios:

Scenario 1: Per-VPN-Instance TE
- Each VPN VRF gets its own SR Policy
- Path computed per VPN requirements
- Example: VoIP VPN -> low-latency path

Scenario 2: Per-Tenant TE
- Tenant-specific SLA requirements
- Dedicated paths per tenant
- Example: Financial tenant -> dedicated low-latency

Scenario 3: Service-Chain TE
- SR-TE to service functions
- Insertion of firewall, DPI
- Example: Video -> firewall -> optimize

Packet Flow (SR-TE + VPN):
1. CE sends packet to PE
2. PE performs VRF lookup
3. VRF has route with SID:
   - End.DT4/End.DT6 for VPN delivery
   - Associated with SR Policy
4. SR Policy segment list preprended
5. Outer header: DA = first segment
6. Packet forwarded via SR-TE path
7. At egress: End.DT executes, VRF delivers
```

### 20.7.3 SR-TE for Global Network

Large-scale SR-TE deployment:

```
Global SR-TE Design:

Domain Hierarchy:
- Core Domain: High-capacity backbone
- Regional Domain: Aggregation
- Access Domain: Edge connectivity

SR-TE Policy Layers:

1. Access-to-Access:
   - Local policies within access domain
   - Low-latency paths
   - Traffic within same access region

2. Access-to-Core:
   - Policies from access to core entry
   - Load-balancing across core entry points
   - Example: Access -> Regional-1

3. Core-to-Core:
   - Inter-region backbone paths
   - Maximum capacity
   - Minimum latency

4. Core-to-Access:
   - Policies from core exit to access
   - Optimal egress selection
   - Example: Regional-2 -> Access

5. End-to-End:
   - Full path policies
   - Computed by PCE
   - Multi-domain optimization
```

## 20.8 SR-TE Configuration

### 20.8.1 Basic SR-TE Configuration

```
IOS-XR Basic SR-TE:

1. Enable SR-TE globally:
segment-routing
 traffic-eng
  policy LOW-LATENCY
   color 100
   endpoint fc00:db8::2
   candidate-paths
    preference 100
     dynamic
      pcep
      !
      metric
       type latency
      !
     !
   !
  !
 !
!

2. Configure explicit path:
segment-routing
 traffic-eng
  policy DEDICATED-PATH
   color 200
   endpoint fc00:db8::3
   candidate-paths
    preference 100
     explicit
      segment-list SR-LIST-1
      !
     !
   !
   candidate-paths
    preference 50
     explicit
      segment-list SR-LIST-2
      !
     !
   !
  !
 !
!
```

### 20.8.2 Segment List Configuration

```
IOS-XR Segment List:

segment-routing
 traffic-eng
  segment-list SR-LIST-1
   index 10
    srv6
     sid fc00:0:1:a:: behavior end
    !
   !
   index 20
    srv6
     sid fc00:0:1:b:: behavior end
    !
   !
   index 30
    srv6
     sid fc00:0:1:c:: behavior end
    !
   !
  !
 !
!
```

### 20.8.3 PCE Configuration

```
IOS-XR PCE Configuration:

PCE Server:
segment-routing
 traffic-eng
  server
   source-address ipv6 fc00:0:0:1::1
   password test123
   family ipv4
   family ipv6
  !
 !
!

PCC Configuration (requesting paths from PCE):
segment-routing
 traffic-eng
  policy LOW-LATENCY
   color 100
   endpoint fc00:db8::2
   candidate-paths
    preference 100
     dynamic
      pcep
       pce fc00:0:0:1::1
       !
      !
      metric
       type latency
      !
     !
    !
   !
  !
 !
!
```

### 20.8.4 Verification Commands

```
show segment-routing traffic-eng policy:
- List all SR-TE policies
- Show active candidate paths
- Display segment lists

show segment-routing traffic-eng policy name LOW-LATENCY:
- Detailed policy status
- Candidate path preferences
- Path validity

show segment-routing traffic-eng segment-list:
- All configured segment lists
- SID values and types
- Usage counts

show pce paths fc00:db8::2:
- PCE-computed paths
- Optimization criteria
- Constraint satisfaction
```

## 20.9 Advanced SR-TE Topics

### 20.9.1 Multi-Domain SR-TE

Large networks span multiple administrative domains:

```
Multi-Domain SR-TE Challenges:
- PCE may not have full topology visibility
- Per-domain computation yields per-domain segments
- End-to-end path requires stitching

Multi-Domain Solutions:

1. Per-Domain PCE:
   - Each domain has local PCE
   - PCC requests path to domain border
   - Domains stitch at border routers

2. Hierarchical PCE:
   - Parent PCE coordinates child PCEs
   - Parent knows inter-domain topology
   - Child PCEs handle intra-domain

3. Path Computation at Ingress:
   - Ingress PCE has multi-domain TED
   - Computes end-to-end segment list
   - Single computation, single policy

4. Segment Stitching at Border:
   - Domain A computes path to border
   - Domain B computes path from border
   - Border stitches segments
   - Requires End.BM or similar behavior
```

### 20.9.2 SR-TE and FlexAlgo Integration

FlexAlgo and SR-TE work together:

```
FlexAlgo + SR-TE Integration:

1. FlexAlgo as Optimization Objective:
   SR Policy:
     optimization: flex-algo 30
   - PCE runs FlexAlgo 30 computation
   - Results in minimum-latency segment list

2. FlexAlgo as Constraint:
   SR Policy:
     constraints:
       flex-algo 50
   - Path must satisfy FlexAlgo 50 constraints
   - Combines FlexAlgo with SR Policy flexibility

3. FlexAlgo-Derived SID:
   - Prefix SID associated with FlexAlgo
   - SR Policy uses that SID as endpoint
   - Path computed automatically

Integration Example:
FlexAlgo 30 (minimize-latency) defined in IGP
SR Policy uses:
  optimization: flex-algo 30
  endpoint: FC00:0:1:100:: (SID with algorithm 30)
  color: 100

Traffic to 10.1.1.0/24:
1. Route has SID FC00:0:1:100:: (algorithm 30)
2. SR Policy (color 100) uses FlexAlgo 30 optimization
3. Segment list computed by FlexAlgo 30
4. Traffic follows minimum-latency path
```

### 20.9.3 SR-TE Scaling

SR-TE scales through aggregation:

```
SR-TE Scaling Techniques:

1. Hierarchical SR-TE:
   - End.BM SID references sub-policy
   - Single SID represents complex path
   - Reduces segment list length

2. BSID Aggregation:
   - BSID references SR Policy
   - Single SID for entire policy
   - Policy change doesn't require packet change

3. Color Aggregation:
   - Multiple flows share same color
   - Single policy for aggregate
   - Per-flow granularity lost but scale gained

4. Binding SID Chains:
   - Chain multiple SR Policies
   - End.B6.Encaps adds layer
   - Service chaining without per-flow state

Scaling Numbers:
- Traditional RSVP-TE: 10K-50K LSPs
- SR-TE with aggregation: 100K+ policies
- Per-packet state: zero (at transit)
```

## 20.10 Summary

SR-TE delivers sophisticated traffic engineering without the scaling and complexity limitations of traditional RSVP-TE:

- **Source-Based Architecture**: The ingress node computes and programs the path; transit nodes perform simple destination-based forwarding with no per-flow or per-policy state.

- **PCE/PCC Framework**: Centralized PCE provides global optimization and sophisticated CSPF computation; PCCs manage local policies and execute steering. PCEP carries requests, responses, and policy state.

- **SR Policy Integration**: SR Policies provide the control-plane framework with candidate paths, preferences, optimization objectives, and steering rules. SR-TE operates by creating and managing these policies.

- **Traffic Steering**: Color-based, prefix-based, and flow-based steering mechanisms map traffic to appropriate SR Policies. The (endpoint, color) tuple determines the applicable policy.

- **FlexAlgo Integration**: FlexAlgo definitions in IGP provide constraint-based path computation. SR-TE can use FlexAlgo as either optimization objective or constraint, combining IGP-computed paths with policy-based traffic engineering.

- **SRv6 Native**: SR-TE in SRv6 uses standard SID types (End, End.X, End.B6.Encaps) and can operate with uSID compression for hardware efficiency.

SR-TE represents the convergence of segment routing's simplicity with the traffic engineering capabilities that modern networks require, enabling operators to engineer traffic with precision while maintaining the operational efficiency of source-based routing.

---
