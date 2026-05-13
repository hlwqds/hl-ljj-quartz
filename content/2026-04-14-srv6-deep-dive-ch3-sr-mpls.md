# Chapter 3: SR-MPLS - Segment Routing with MPLS Data Plane

## 3.1 Overview

SR-MPLS is the implementation of Segment Routing over the existing MPLS data plane. It reuses MPLS label stack encoding as the mechanism for carrying segment lists, requiring no new header formats or forwarding hardware. For carriers with established MPLS infrastructure, SR-MPLS offers a migration path to Segment Routing that leverages existing investments.

The fundamental innovation of SR-MPLS is conceptual rather than mechanical: instead of signaling individual LSPs through RSVP-TE or LDP, SR-MPLS encodes the path as a label stack that the head-end router applies to packets. Transit routers process labels according to their semantics (prefix lookup, adjacency forwarding) without maintaining per-LSP state.

## 3.2 How SR-MPLS Works

### 3.2.1 The Label Stack as Segment List

In SR-MPLS, each SID corresponds to an MPLS label. A segment list becomes a label stack, with the active segment at the top of the stack (bottom of the packet, following MPLS convention for stack operations).

```
Traditional MPLS LSP:
  Push Label 16103 (R3's Node-SID) → Transit swaps → Tail-end pops

SR-MPLS explicit path (R1→R4→R3):
  Push Label Stack [16104, 16103]
  
  - Top of stack = 16104 (R4's Node-SID, next hop)
  - Second label = 16103 (R3's Node-SID, final destination)
  
  Processing at each hop:
  - R1: Pushes [16104, 16103], forwards to R4's direction
  - R4: Swaps top label 16104 → (local), now top is 16103
        Forwards to R3 direction
  - R3: Pops label 16103, forwards IP packet
```

### 3.2.2 Penultimate Hop Popping (PHP)

SR-MPLS leverages standard MPLS PHP behavior. When a packet approaches its final segment's destination, the label is popped at the penultimate router rather than the ultimate router.

```
When R1 sends to R3 via Node-SID 16103:

Without PHP: R2 sends labeled packet to R3; R3 pops
With PHP:    R2 pops label and sends IP to R3

PHP eliminates an unnecessary label swap at the tail-end,
optimizing forwarding and allowing R3 to process the
native IP packet directly.
```

### 3.2.3 Explicit Null and UDLD

When the tail-end requires MPLS processing (for VPN services, for example), the penultimate router uses **Explicit Null** (label 0) rather than popping:

```
R1 sends packet with label stack [16103, 2] (VPN label 2)
PHP at R2: Push Explicit Null (label 0) as outer label
R3 receives [0, 2], sees outer label 0, processes inner VPN label 2

RFC 4182 specifies this behavior for scenarios where
the tail-end needs to preserve MPLS context.
```

## 3.3 SID Distribution in SR-MPLS

### 3.3.1 IGP Advertisement of SIDs

SR-MPLS distributes SID information through IGP extensions. Each router advertises:

- **Prefix-SID**: For each IGP prefix (typically loopback), the router advertises its assigned SID for that prefix. This SID is global within the SR domain.

- **Adjacency-SID**: For each IGP adjacency, the router advertises a locally-allocated SID representing that specific link. Adjacency-SIDs are typically single-hop—they represent forwarding out a specific interface.

```
IS-IS SR Prefix-SID sub-TLV:
+-------------------------------+
| Type = 3                      | (1 octet)
+-------------------------------+
| Length                       | (1 octet)
+-------------------------------+
| Flags                        | (1 octet)
|   R=Re-advertisement flag    |
|   N=Node-SID flag            |
|   P=no-PHP flag              |
|   M=Mapping server flag      |
+-------------------------------+
| MT                           | (2 octets)
+-------------------------------+
| Algorithm                    | (1 octet)
|   0 = SPF                    |
|   1 = Strict SPF             |
+-------------------------------+
| SID                          | (4 octets)
+-------------------------------+
```

### 3.3.2 The SRGB and SID Resolution

As discussed in Chapter 2, each node advertises its **Segment Routing Global Block (SRGB)**. When a router processes a SID, it adds the SID value to the SRGB base to obtain the absolute label:

```
R3 advertises:
  - SRGB: 16000-23999
  - Node-SID index: 103
  - SID label: 16000 + 103 = 16103

When R1 programs a path to R3:
  - R1 looks up R3's Node-SID index: 103
  - R1 computes absolute label: 16000 + 103 = 16103
  - R1 pushes label 16103 onto packets

Transit routers see label 16103, recognize it as within
their own SRGB, and forward according to R3's advertised
SID (forward to R3 via shortest path).
```

### 3.3.3 Multi-Vendor SRGB Considerations

Different vendors use different SRGB ranges:

| Vendor   | Default SRGB    | Size      |
|----------|-----------------|-----------|
| Cisco    | 16000-23999     | 8,000     |
| Juniper  | 100000-1048575  | 949,576   |
| Huawei   | 16000-1048575   | 1,032,560 |
| Nokia    | 15000-1048575   | 1,033,576 |

When planning an SR-MPLS domain with multi-vendor equipment, SID allocation must account for these different SRGBs. Two approaches exist:

1. **Normalization at the ABR/ASBR**: Area border routers maintain label mappings between vendor-specific SRGBs, translating as needed.

2. **Unified SRGB**: Configure all vendors with a common SRGB range (typically 16000-23999), ensuring consistent SID interpretation.

## 3.4 SR-MPLS Path Computation

### 3.4.1 Distributed Path Computation

The simplest SR-MPLS paths require no centralized controller. Using IGP-distributed topology and SID information, any router can compute an explicit path:

```
Algorithm to compute SID list from R1 to R3 via R4:

1. Obtain topology with SID information
2. Run SPF from R1 to R3 via constraint (must go through R4)
3. Extract path: R1→R4→R3
4. Extract SIDs:
   - R4's Node-SID index: 104 → absolute label 16104
   - R3's Node-SID index: 103 → absolute label 16103
5. Encode as stack [16104, 16103]

This computation can occur at the head-end router
without any external controller or signaling.
```

### 3.4.2 PCE-Initiated Paths

For complex scenarios (inter-area, inter-AS, multi-constraint TE), PCE provides centralized path computation:

```
PCE Architecture:

[PCC/R1] <---PCEP---> [PCE]
                         |
                         v
              +------------------+
              | Topology DB     |
              | (via BGP-LS)    |
              +------------------+

PCE computes path and returns SID list:
  - PCE knows full topology (BGP-LS collection)
  - PCE applies constraints (bandwidth, latency, affinity)
  - PCE returns explicit SID list via PCEP
  - R1 encodes SID list in packets
```

PCEP (Path Computation Element Communication Protocol), defined in RFC 5440 and extended for SR in RFC 8664, carries:

- **SR-ERO (Explicit Route Object)**: The SID list encoding the computed path
- **Bandwidth constraints**: RSVP-TE style bandwidth reservation
- **Metric preferences**: Optimize for delay, hop count, TE metric, etc.

## 3.5 SR-MPLS Operations

### 3.5.1 Encapsulation and Forwarding

SR-MPLS encapsulation places the label stack directly between the Layer 2 header and the original payload:

```
+----------------+----------------+------------------------+
| Layer 2 Header | Label Stack    | Original IP Packet     |
+----------------+----------------+------------------------+
                 |                |
                 |  [16104][16103]| <-- Two-label stack
                 |                |
                 +----------------+
```

At each hop:

1. Router receives frame on interface
2. Router examines outermost (top) label
3. Router performs LFIB lookup: label → (outgoing interface, next label, action)
4. Router executes action (swap, pop, push)
5. Router transmits frame on outgoing interface

### 3.5.2 LFA and Remote-LFA with SR

SR-MPLS can leverage LFA (Loop-Free Alternates) for local protection:

- **LFA**: Pre-computed backup next-hop that avoids the failed link/node
- **Remote LFA (rLFA)**: Extends LFA to topologies where no direct backup exists, tunneling to a remote PQ node that can deliver traffic without crossing the failure

SR enhances these by encoding the backup path as segments:

```
TI-LFA (Topology-Independent LFA) with SR-MPLS:

Normal path: R1 --R2-- R3 --R4-- R5
              Protected: R2-R3 link

TI-LFA computation:
1. Find Repair Point (RP): R2
2. Find PQ node: R6 (post-convergence node)
3. Compute repair path: R2 → R6 → R3

Encode as SID list:
- Adj-SID for R2→R6
- Node-SID for R6
- (R3 is reached via shortest path from R6)

On failure detection at R2:
- R2 pushes TI-LFA segment list
- Packet tunneled to R6 via R2→R6 adjacency
- R6 forwards via Node-SID to R3
- R3 delivers to R5
```

### 3.5.3 ECMP and Load Balancing

SR-MPLS naturally supports ECMP (Equal-Cost Multipath) at nodes with multiple outgoing paths to the same SID:

```
R1 to R3 has two equal-cost paths:
  Path A: R1--R2--R3 (2 hops, 10Gbps each link)
  Path B: R1--R7--R3 (2 hops, 10Gbps each link)

When R1 pushes [Node-SID 103]:
- R1's ECMP hash selects between Path A and Path B
- Each transit router may also ECMP across parallel links
- Traffic flows across both paths without per-flow signaling

For unequal-cost load balancing, SR allows explicit path
programming with multiple SID lists (weighted ECMP).
```

## 3.6 Comparison: SR-MPLS vs. Traditional MPLS

### 6.1 Control Plane Simplification

| Aspect                    | Traditional MPLS (RSVP-TE)     | SR-MPLS                    |
|---------------------------|--------------------------------|----------------------------|
| Per-LSP state             | Required at every transit node | None (packet carries path) |
| Refresh signaling         | RSVP RESV every 30 seconds     | None                       |
| Path changes              | Re-signal entire LSP           | Re-program head-end only   |
| Inter-AS                 | Complex RSVP-TE over BGP      | BGP-LS + PCE               |
| Failure recovery         | RSVP teardown/resignaling     | Local protection (TI-LFA)  |

### 6.2 Scalability

```
Network with 10,000 LSPs, 20-hop average:

RSVP-TE:
  - 200,000 RSVP state entries (10,000 LSPs × 20 hops)
  - 200,000 periodic refresh messages
  - Convergence requires re-signaling all affected LSPs

SR-MPLS:
  - 20,000 SID entries (one per prefix per direction)
  - Zero RSVP state
  - Convergence uses pre-computed TI-LFA paths
```

### 6.3 Traffic Engineering Flexibility

```
Scenario: Shift 50% of traffic from R1→R2→R3 to R1→R4→R3

RSVP-TE approach:
  1. Create new LSP with explicit path R1→R4→R3
  2. Reserve bandwidth on R4→R3 links
  3. Migrate traffic to new LSP
  4. Tear down old LSP
  (Complex orchestration, requires RSVP across all hops)

SR-MPLS approach:
  1. Head-end R1 identifies traffic subset
  2. R1 encodes path as SID list [Node-SID 104, Node-SID 103]
  3. No coordination with transit routers needed
  (Simple, source-controlled, instantaneous)
```

## 3.7 Migration from Traditional MPLS to SR-MPLS

### 3.7.1 Incremental Deployment

SR-MPLS supports incremental migration without network-wide cutover:

1. **Enable SR on subset of routers**: Configure SRGB and SID allocation on selected nodes
2. **Enable SR on IGP adjacencies**: Extend IS-IS/OSPF with SR extensions
3. **SR availability propagates gradually**: Nodes begin advertising Prefix-SIDs
4. **SR paths become possible**: Head-ends can now program segment lists

### 3.7.2共存策略

During migration, SR-MPLS and traditional MPLS must coexist:

- **LDP and SR adjacencies**: Can coexist on same physical links
- **LDP label bindings**: Used for traditional LSPs
- **SR SIDs**: Used for SR paths
- **Dual-stack routers**: Support both forwarding models

```
Migration phases:

Phase 1: SR enabled on core routers only
  - Core forms SR adjacencies
  - Edge routers continue using LDP
  - Traffic engineering limited to core

Phase 2: SR enabled on edge routers
  - Edge routers push SR label stacks
  - Core routers process SR labels natively
  - LDP still used for label distribution

Phase 3: LDP removed
  - All routers use SR exclusively
  - SRGB and SID allocation finalized
  - Full SR traffic engineering benefits achieved
```

## 3.8 Summary

This chapter examined SR-MPLS, the MPLS data plane implementation of Segment Routing:

- **Label stack as segment list**: SR-MPLS encodes segment lists as MPLS label stacks, requiring no new forwarding hardware. The top of stack is processed first, with PHP optimizing tail-end processing.

- **SID distribution**: IGP extensions (IS-IS SR, OSPF SR) advertise Prefix-SIDs and Adjacency-SIDs throughout the SR domain. The SRGB decouples vendor-specific label spaces from globally meaningful SID values.

- **Path computation**: Distributed computation at the head-end using IGP topology, or centralized via PCE for complex scenarios. No per-LSP signaling required.

- **Operations**: Standard MPLS encapsulation and forwarding with enhanced protection (TI-LFA) and load balancing (ECMP). Hardware forwarding unchanged.

- **Migration**: SR-MPLS coexists with traditional MPLS, enabling incremental deployment without network-wide disruption.

The following chapters turn to SRv6, where Segment Routing meets IPv6, introducing new capabilities beyond what the MPLS data plane provides.

---

**References**

- RFC 8402: Segment Routing Architecture
- RFC 8662: IS-IS Extensions for Segment Routing (MPLS)
- RFC 8665: OSPF Extensions for Segment Routing (MPLS)
- RFC 8664: PCEP Extensions for SR
- RFC 5440: Path Computation Element (PCE) Communication Protocol
- RFC 4182: Removing the Restriction on the Use of MPLS Explicit NULL
- RFC 8476: Signaling of Loop-Free Alternatives Using Segment Routing