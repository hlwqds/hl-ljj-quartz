# Chapter 2: Segment Routing Overview

## 2.1 The Core Insight

Segment Routing, formalized in RFC 8402, represents a fundamental reimagining of how paths are established and traffic is directed through a network. The central insight is elegantly simple: **the head-end router specifies the entire path by encoding a stack of instructions in the packet header itself**. Transit routers execute these instructions without requiring any per-flow state or dynamic signaling.

This stands in stark contrast to traditional MPLS, where each LSP was independently signaled through the network using RSVP-TE or LDP. In Segment Routing, the path definition travels with the packet, allowing the head-end to program network behavior without coordinating with transit nodes.

Consider the difference:

```
Traditional MPLS (RSVP-TE):
  [R1] ----signals----> [R2] ----signals----> [R3] ----signals----> [R4]
         RSVP RESV         RSVP RESV         RSVP RESV
         (per-LSP state)   (per-LSP state)   (per-LSP state)

Segment Routing:
  [R1] --pushes segments--> [R2] --executes--> [R3] --executes--> [R4]
         No signaling needed        No per-flow state
```

The SR architecture derives its name from these **segments**—the atomic instructions that define a packet's treatment at each hop.

## 2.2 Fundamental Concepts

### 2.2.1 Segments

A **segment** is an instruction executed at a specific node. Segments are identified by a **Segment ID (SID)**—a unique identifier within the SR domain.

Three fundamental segment types form the foundation:

1. **Prefix Segment (Prefix-SID)**: Represents a destination prefix. When a node processes a Prefix-SID, it performs a lookup and forwards the packet toward that prefix. This is the SR equivalent of an IGP route.

2. **Adjacency Segment (Adjacency-SID)**: Represents a specific interface or peer. When a node processes an Adjacency-SID, it forwards the packet out the associated interface, regardless of shortest-path calculations.

3. **Node Segment (Node-SID)**: A special case of Prefix-SID, representing the router's own prefix (typically a loopback address). Node-SIDs are anchor points for path computation and are typically globally significant within the SR domain.

```
SR Domain Example:

    192.0.2.1/32 (Node-SID 101)        192.0.2.3/32 (Node-SID 103)
           [R1]---------------------------[R3]
            |   \                           |
            |    \100Gbps                   |200Gbps
            |     \                         |
            |      \                  [R5]
            |       \                      /
            |        [R4]-----------------
       50Gbps            (Node-SID 104)
            |
            |
           [R2]---------------------------[R6]
    192.0.2.2/32 (Node-SID 102)        192.0.2.6/32 (Node-SID 106)

R1 can program paths by combining segments:
- Path to R3 via R2: Node-SID 102, Node-SID 103
- Path to R3 via R4 (100Gbps link): Node-SID 104, Node-SID 103
- Direct to R3: Node-SID 103
```

### 2.2.2 Segment Lists and SR Paths

An **SR Path** is an ordered list of segments. The packet carries this list in its header, and each router processes the active segment at the front of the list.

The segment stack operates as a last-in, first-out (LIFO) structure:

1. When a packet arrives at a node, the node examines the active (top) segment.
2. The node executes the segment's instruction.
3. The node advances to the next segment in the list.
4. The process repeats until the segment list is exhausted.

```
Packet at R1 with SR path: [Adj-SID R1→R4, Node-SID 103]

Step 1: R1 processes Adj-SID R1→R4
        - Forwards packet out interface toward R4
        - Advances to next segment (Node-SID 103)

Step 2: R4 receives packet
        - Processes Node-SID 103
        - Forwards packet toward R3 (IGP shortest path)
        - Advances to next segment (none)

Step 3: R3 receives packet
        - Node-SID 103 is local (R3's own SID)
        - Packet has reached destination
```

### 2.2.3 Global and Local Segments

SR supports two scopes for segment allocation:

- **Global Segment**: Advertised by multiple nodes; any node in the SR domain can process it. Prefix-SIDs are typically global, allowing any router to forward toward the prefix.

- **Local Segment**: Allocated and processed only by the node that created it. Adjacency-SIDs are inherently local—they represent a specific interface on a specific node.

This distinction is fundamental to SR's efficiency: Prefix-SIDs require only one entry per prefix in the forwarding plane, while Adjacency-SIDs represent the local interface being programmed.

## 2.3 SR Architecture Components

### 2.3.1 The SR Data Plane

Segment Routing operates over two data planes:

- **SR-MPLS**: Uses MPLS encapsulation with label stacks encoding segment lists. This is the evolution of traditional MPLS, where labels serve as SIDs.

- **SRv6**: Uses IPv6 extension headers to carry segment lists within native IPv6 packets. This is the subject of subsequent chapters.

Both data planes share the same segment routing concepts; they differ only in encoding.

### 2.3.2 The SR Control Plane

SR's control plane distributes SID information through extensions to existing IGPs:

- **IS-IS SR Extension**: RFC 8662 specifies Segment Routing extensions for IS-IS, distributing Prefix-SIDs, Adjacency-SIDs, and Node-SIDs.

- **OSPF SR Extension**: RFC 8665 specifies Segment Routing extensions for OSPF, providing equivalent functionality for OSPF-based networks.

These IGP extensions distribute SID information within an IGP area. For multi-area networks, BGP-LS (BGP Link-State) collects topology and SID information for centralized path computation.

### 2.3.3 Path Computation Element (PCE)

For large-scale networks, PCE (RFC 5440) provides centralized path computation. The PCE maintains a complete topology view and computes explicit paths on behalf of head-end routers.

SR integrates naturally with PCE:

- PCC (Path Computation Client) requests paths from PCE
- PCE returns path segments as SID lists
- PCC (typically the head-end router) encodes the SID list in the packet

This architecture enables:

- **Inter-area SR**: PCE has topology visibility across areas, computing optimal paths that would be invisible to per-area IGP computation.
- **Inter-AS SR**: PCE spans AS boundaries, computing end-to-end paths across provider boundaries.
- **Traffic engineering**: PCE applies constraints (bandwidth, latency, affinity) to path computation.

## 2.4 SID Structure and Allocation

### 2.4.1 The SID Label Block

In SR-MPLS, the SID label space is carefully allocated:

- **Node-SIDs**: Allocated from a provider's SID label block, typically assigned per router based on its Router-ID or ASN.

- **Adjacency-SIDs**: Dynamically allocated from a separate label block when adjacencies are formed, typically with significant local scope.

- **Anycast-SIDs**: Representing a set of nodes advertising the same prefix (typically for protection or load sharing).

The IGP extensions carry SID label sub-TLVs that explicitly advertise the label value for each SID:

```
IS-IS SR Extension SID sub-TLV:
+-------------------------------+
| Type (1 octet)                |
+-------------------------------+
| Length (1 octet)              |
+-------------------------------+
| Flags (1 octet)               |
+-------------------------------+
| MT (Multi-Topology, 2 octets) |
+-------------------------------+
| Algorithm (1 octet)           |
+-------------------------------+
| SID (4 octets)                |
+-------------------------------+
```

### 2.4.2 The SRGB (Segment Routing Global Block)

The **SRGB** is a range of label values reserved for Segment Routing globally within an SR domain. Each node typically advertises its own SRGB, allowing SID values to be interpreted correctly across vendor implementations.

```
Example SRGB configurations:
- Cisco: 16000-23999 (8000 labels)
- Juniper: 100000-999999 (900000 labels - very large)
- Huawei: 16000-1048575

When Node-SID 101 is advertised with an SRGB of 16000-23999:
- The absolute label is 16000 + 101 = 16101
- Any node in the SR domain can push label 16101
- The label's meaning is globally consistent
```

The use of SRGB decouples SID allocation from absolute label values, enabling multi-vendor deployments where different vendors may use different underlying label spaces.

## 2.5 SR Path Types

### 2.5.1 IGP Shortest Path

The simplest SR path uses only a single Prefix-SID—the destination's Node-SID. The packet follows the IGP shortest path, but the path is encoded in the packet rather than computed at each hop.

```
Packet to 192.0.2.3 with SID list [Node-SID 103]
- R1 looks up Node-SID 103
- Forwards toward R3 via shortest path
- No further SR processing needed at transit nodes
```

This may seem redundant—why encode what the IGP would compute anyway? The answer lies in path pinning and traffic engineering.

### 2.5.2 Explicit Path via Segment List

A more interesting path combines multiple segments to force specific routing:

```
Packet to 192.0.2.3 with SID list [Node-SID 104, Node-SID 103]
- R1 forwards to R4 (first segment)
- R4 forwards to R3 (second segment)

The packet is pinned to the R1→R4→R3 path regardless of
IGP metrics, link utilization, or other dynamic factors.
```

### 2.5.3 Path with Adjacency Segments

Adjacency-SIDs enable fine-grained outgoing interface control:

```
Packet to 192.0.2.3 with SID list [Adj-SID R1-to-R4, Node-SID 103]
- R1 sends packet directly to R4 via specific interface
- R4 processes Node-SID 103, forwards to R3 via shortest path

This combination forces the first hop but allows
IGP to determine the remainder.
```

### 2.5.4 Anycast Segments

An **Anycast-SID** represents a group of nodes sharing the same prefix. When a packet with an Anycast-SID arrives at any node advertising that anycast, it is forwarded toward the nearest member of the group.

Common applications:

- **Protection**: An Anycast-SID representing multiple PE routers for VPN redundancy. Traffic destined for the Anycast-SID reaches the nearest available PE.

- **Load distribution**: Distributing traffic across multiple nodes without per-flow state.

## 2.6 SR Resilience and Protection

### 2.6.1 Topology-Independent Loop-Free Alternate (TI-LFA)

Traditional IP fast reroute (IPFRR) provided sub-50ms protection for single link or node failures, but the protection paths were topology-dependent and sometimes suboptimal.

**TI-LFA** (RFC 8505, later updated by RFC 9002) computes a backup path using Segment Routing's explicit path capability. The algorithm:

1. Computes the shortest path to the destination
2. Identifies the protected element (link or node)
3. Computes the shortest loop-free path that avoids the protected element
4. Encodes the backup path as a segment list

```
Normal path: R1 --R2-- R3 --R4-- R5 (protected: R3-R4 link)
TI-LFA backup: R1 --R2-- R3 --R6-- R7 --R4-- R5

When R3-R4 fails:
- R3 detects failure
- R3 pushes TI-LFA segment list onto packet
- Packet follows R3-R6-R7-R4-R5 path
- Sub-50ms failover achieved
```

TI-LFA provides **100% protection coverage** for any topology—unlike traditional IPFRR which required specific topologies for full coverage.

### 2.6.2 Microloop Avoidance

Microloops are temporary forwarding loops that can occur during IGP convergence when different routers reconverge at different speeds.

SR's microloop avoidance mechanism:

1. Before initiating convergence, the router computes a path that avoids potential microloop nodes.
2. The router encodes this path as a segment list.
3. Traffic is forwarded along the loop-free path until all routers have converged.

This technique requires coordination but provides robust protection against convergence-induced microloops.

## 2.7 SR and SDN Integration

### 2.7.1 Centralized vs. Distributed Control

SR embraces a hybrid model:

- **Distributed control**: IGP still computes shortest paths and distributes reachability information. No fundamental change to IGP's loop-free path computation guarantees.

- **Centralized programming**: Applications or controllers can specify explicit paths by providing SID lists. The head-end router (or PCC) encodes these paths in packets.

This model is sometimes called **source routing**, because the source (head-end) specifies the complete path.

### 2.7.2 BGP SR Policy

RFC 9256 introduced **SR Policy** as a native SR way to specify policies:

- An SR Policy is a container for a candidate path with associated intent (traffic engineering constraints, optimization objectives).
- The SR Policy is signaled to the head-end via BGP or PCEP.
- The head-end encodes the SID list in packets matching the policy.

BGP SR Policy provides a standardized way for controllers to program SR paths without requiring proprietary protocols.

## 2.8 Summary

This chapter introduced the fundamental concepts of Segment Routing:

- **The central insight**: The head-end encodes the complete path as a segment list in the packet header; transit routers execute segments without per-flow state or dynamic signaling.

- **Segment types**: Prefix-SIDs identify destinations, Adjacency-SIDs identify specific interfaces, and Node-SIDs anchor path computation. Global segments are advertised throughout the SR domain; local segments exist only on the advertising node.

- **SR paths**: Composed of ordered segment lists processed LIFO at each hop. Single-segment paths follow IGP shortest paths; multi-segment paths are explicitly pinned.

- **Control plane**: IGP extensions (IS-IS SR, OSPF SR) distribute SID information. PCE provides centralized path computation for complex scenarios.

- **Resilience**: TI-LFA provides 100% coverage protection using SR's explicit path encoding. Microloop avoidance prevents convergence-induced forwarding loops.

- **SR-MPLS vs. SRv6**: Both share the same architecture; SR-MPLS uses MPLS labels as SIDs, while SRv6 (covered in subsequent chapters) uses IPv6 addresses.

The following chapter explores SR-MPLS, the MPLS implementation of Segment Routing, before we dive deeply into SRv6's unique properties.

---

**References**

- RFC 8402: Segment Routing Architecture
- RFC 8662: IS-IS Extensions for Segment Routing (MPLS)
- RFC 8665: OSPF Extensions for Segment Routing (MPLS)
- RFC 8666: IS-IS SRv6 Extensions
- RFC 8667: OSPFv3 Extensions for SRv6
- RFC 5440: Path Computation Element (PCE) Communication Protocol
- RFC 8505: Advanced PCP for IP and MPLS
- RFC 9002: IS-IS Extensions for SR Policy
- RFC 9256: Segment Routing Policy Architecture
