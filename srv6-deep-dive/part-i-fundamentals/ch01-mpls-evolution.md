# Chapter 1: MPLS Evolution - From ATM to Segment Routing

## 1.1 The Quest for Traffic Engineering

The story of MPLS begins in the early 1990s, a time when the internet was experiencing explosive growth and network operators faced mounting pressure to deliver better quality of service, faster packet forwarding, and more sophisticated traffic engineering capabilities.

### The ATM Imperative

Asynchronous Transfer Mode (ATM) emerged in the late 1980s as a promising technology for unified voice, video, and data transport. ATM's fixed 53-byte cell size enabled hardware-based switching with predictable latency—attributes that were highly attractive for real-time services. The fundamental innovation of ATM was the Virtual Circuit (VC) abstraction: before any data flowed, a connection was established through the network, reserving bandwidth and establishing QoS guarantees.

Two ATM connection models took shape:

- **PVC (Permanent Virtual Circuit)**: Manually configured point-to-point connections, akin to a dedicated leased line but virtualized. Network operators would provision these circuits weeks or months in advance, a process that satisfied enterprise customers seeking predictable performance but frustrated carriers managing thousands of circuits.

- **SVC (Switched Virtual Circuit)**: Dynamically established connections initiated by end-user equipment. An SVC setup resembled a phone call—signaling messages explored the network, resources were allocated, and a path materialized within milliseconds. The call ended, and resources dissolved.

The ATM Forum standardized PNNI (Private Network-to-Network Interface) for dynamic path computation, allowing ATM switches to collaborate in establishing SVCs across multivendor networks. Yet despite ATM's technical elegance, it carried fundamental limitations that would eventually limit its ubiquity.

### ATM's Structural Challenges

ATM's cell-based switching imposed significant overhead. The 5-byte cell header consumed nearly 10% of every 53-byte cell—a steep price when transmitting small packets like VoIP samples. More critically, ATM's connection-oriented model required per-flow state at every switch along a path. A network supporting millions of concurrent flows faced scalability challenges that grew with the number of flows rather than the number of destinations.

The industry recognized that something better was needed: a technology that preserved ATM's traffic engineering virtues—QoS guarantees, bandwidth reservation, explicit paths—while adopting IP's connectionless, destination-based forwarding paradigm.

## 1.2 The MPLS Revolution (1997-2001)

The IETF's MPLS working group formed in 1997, synthesizing insights from Cisco's tag switching, IBM's ARIS, and other proprietary approaches into a unified standard. The resulting framework, formalized through RFC 3031 ("Multiprotocol Label Switching Architecture"), represented a carefully negotiated compromise that balanced innovation with practical deployment constraints.

### The Label Abstraction

MPLS's central innovation was deceptively simple: insert a short, fixed-length label between the Layer 2 header and the Layer 3 header. This label, typically 4 bytes (20 bits for the label value, 3 bits for QoS/EXP, 1 bit for bottom-of-stack, and 8 bits for TTL), allowed routers to make forwarding decisions without examining the IP header.

```
+----------------+---------+-------------+------------------+
| Layer 2 Header | Label   | Layer 3 Header | Upper Layers    |
+----------------+---------+-------------+------------------+
                 ^                           ^
                 |                           |
           MPLS Shim Header            Original IP Packet
           (4 bytes)                   (no modification)
```

The label's fixed position and fixed length enabled hardware implementation. A router could parse the label, perform a single table lookup, swap the label, and forward—all in constant time, independent of the IP header's complexity or options.

### Label Distribution Protocols

MPLS required a mechanism for routers to agree on label bindings. Three protocols emerged:

- **LDP (Label Distribution Protocol)**: The baseline protocol, distributing label bindings for known prefixes through TCP-based reliable sessions. LDP's simplicity made it attractive for straightforward LSP establishment.

- **RSVP-TE (Resource Reservation Protocol - Traffic Engineering)**: An extension of RSVP that added explicit paths, bandwidth reservations, and traffic engineering capabilities. RSVP-TE became the protocol of choice for carrier networks requiring fine-grained control.

- **BGP (Border Gateway Protocol)**: RFC 3107 specified how BGP could carry label bindings, enabling MPLS VPNs (specifically, BGP/MPLS IP VPNs as described in RFC 4364) and seamless integration with existing BGP infrastructure.

### The LSP Lifecycle

An MPLS Label Switched Path (LSP) progresses through distinct phases:

1. **Path Establishment**: The head-end router computes an explicit path (either manually configured or via RSVP-TE signaling) and initiates label reservation downstream.

2. **Label Distribution**: Each transit router receives label bindings from its downstream neighbor and advertises its own label to upstream routers.

3. **Data Forwarding**: The head-end router pushes labels onto packets; transit routers swap labels according to their LFIB (Label Forwarding Information Base); the tail-end router pops the label and forwards based on the IP header.

4. **Path Teardown**: When the LSP is no longer needed, RSVP-TE or LDP signals the release of label resources.

## 1.3 Traffic Engineering with MPLS

MPLS's most transformative application was traffic engineering—the ability to control exactly which paths traffic took through a network, independent of IGP shortest-path calculations.

### The SPF Tyranny

Traditional IP routing uses the Shortest Path First (SPF) algorithm (Dijkstra's algorithm applied to link-state IGP databases). While computationally efficient and loop-free, SPF produces a single best path per destination. When multiple links have equal cost, SPF load-balances across them, but this implicit load balancing is coarse-grained and ignores utilization patterns.

Consider a network where a 10 Gbps link serves as the sole path to a remote region, while alternative paths exist but with higher IGP metrics. SPF places all traffic on the 10 Gbps link while 40 Gbps of capacity sits idle on longer routes. The result: congestion on the primary path, underutilization elsewhere, and no mechanism to direct specific traffic flows to specific paths.

### RSVP-TE and Explicit Paths

RSVP-TE enabled network operators to specify exact paths for LSPs. An explicit path could be:

- **Strict**: Every hop specified precisely, allowing complete control but requiring detailed topology knowledge at the head-end.

- **Loose**: Only certain hops specified, allowing the network to fill in intermediate hops via SPF while respecting operator constraints.

```
[R1]----100Gbps----[R2]----100Gbps----[R3]
  |                                   |
  +-------200Gbps----[R4]----200Gbps-+
  
Shortest path from R1 to R3: R1-R2-R3 (100Gbps capacity)
Alternative explicit path: R1-R4-R3 (200Gbps capacity)

MPLS-TE allows directing high-bandwidth LSPs through R1-R4-R3
while lower-priority traffic uses the shorter R1-R2-R3 path
```

### DiffServ and QoS Integration

MPLS integrated cleanly with Differentiated Services (DiffServ). The EXP bits in the MPLS header carried QoS class markings, allowing:

- **Priority Queuing**: Critical traffic (voice, emergency services) receives preferential treatment at each hop.

- **Policing and Shaping**: Traffic entering the MPLS domain could be rate-limited and shaped to contracted bandwidth profiles.

- **PHB (Per-Hop Behavior)**: Each MPLS router applied queueing, scheduling, and dropping policies based on EXP bits, independent of IP header DSCP values.

## 1.4 MPLS Control Plane Evolution

### The Rise of Label Switch Controllers

In early MPLS architectures, label distribution required dense peerings. An LSR (Label Switching Router) needed LDP or RSVP-TE adjacencies with every other LSR in the domain—a model that scaled poorly as networks grew.

The concept of a Label Switch Controller (LSC) emerged, centralizing label management while forwarding remained distributed. An LSC would maintain the full topology database, compute optimal paths, and distribute label bindings to edge LSRs. This architecture presaged the SRv6 control plane's centralized programming model.

### MPLS-TP: Transport Profile

As MPLS penetrated carrier transport networks, operators demanded SONET/SDH-like reliability guarantees. MPLS-TP (Transport Profile), specified in RFC 5317 and further developed by the IETF and ITU-T, added:

- **Linear Protection**: 1:1 and 1+1 protection switching with sub-50ms failover, matching SONET/SDH restoration times.

- **Pseudowire Resilience**: End-to-end emulated circuit resilience across MPLS networks.

- **OAM (Operations, Administration, and Maintenance)**: Connectivity verification, path tracing, and performance monitoring analogous to SONET section/line/path overhead.

MPLS-TP demonstrated that MPLS could serve as a full transport technology, competing directly with legacy circuit-switched networks.

## 1.5 Scaling Challenges and the Path to Segment Routing

By the mid-2000s, MPLS had achieved dominant market position in carrier networks. Yet scaling limitations accumulated:

### Control Plane State Explosion

Each LSP required label bindings at every hop. A network with 10,000 LSPs traversing 20 hops maintained 200,000 label entries across the transit routers. While individual LFIB entries were compact, the aggregate state became significant, and worst-case failover scenarios required updating millions of entries.

### RSVP-TE Scaling Concerns

RSVP-TE maintained soft state at each node along an LSP. Periodic refresh messages (typically every 30 seconds) consumed bandwidth and CPU. Large-scale networks with thousands of LSPs spent meaningful resources on RSVP processing, particularly during convergence events when all LSPs required re-signaling.

### Complexity of Inter-AS Options

MPLS Inter-AS options presented particular complexity. Option A (back-to-back VRFs) required ASBRs to maintain VPN state for each跨域 connection. Option B (single-hop eBGP) distributed labeled routes but risked route reflector scaling issues. Option C (multihop eBGP) imposed significant control plane load. Each option traded complexity against scalability in different ways.

## 1.6 The MPLS-VPN Ecosystem

### BGP/MPLS IP VPNs (RFC 4364)

MPLS's most successful application was the BGP/MPLS VPN, which allowed service providers to offer layer-3 VPN services to enterprise customers. The architecture used:

- **VRF (VPN Routing and Forwarding)**: Each customer received an isolated routing and forwarding table, preventing leakage between customers.

- **Route Distinguisher (RD)**: A 64-bit prefix prepended to customer routes, creating unique VPNv4 addresses distinguishable across the provider backbone.

- **Route Target (RT)**: Extended community attributes controlling which VRFs imported and exported routes, enabling complex hub-and-spoke and mesh VPN topologies.

- **MPLS Label per VPN Route**: The provider backbone used MPLS to tunnel VPN traffic between sites, with the VPN label identifying the destination VRF.

### VPLS and EVPN

Layer-2 MPLS VPNs (VPLS - Virtual Private LAN Service) emulated LAN connectivity across the MPLS backbone, enabling enterprises to connect multiple sites in a single logical Ethernet segment. However, VPLS faced limitations in scaling (flooding, lack of optimal forwarding) that motivated the development of EVPN (Ethernet VPN).

EVPN, specified in RFC 7432, introduced:

- **MAC Learning via BGP**: Eliminated flooding-and-learning for MAC address distribution.

- **Dual-Homing**: Active/standby or active/active multi-homing to provider edges.

- **Optimal Forwarding**: Unicast traffic followed BGP-based paths rather than flooding.

EVPN quickly became the preferred solution for data center interconnect and carrier Ethernet services.

## 1.7 MPLS at the Inflection Point

By 2010, MPLS had achieved its original goals: fast hardware forwarding, traffic engineering, QoS differentiation, and scalable VPN services. Yet the architecture's age showed. New requirements emerged:

- **Simplification**: Operators sought to reduce control plane protocols and eliminate unnecessary complexity.

- **Scalability**: Internet scale demanded architectures that grew with destinations rather than flows.

- **Programmability**: Network operators and applications wanted to specify packet treatment without understanding underlying topology.

- **IPv6**: The exhaustion of IPv4 address space demanded a path forward that embraced IPv6 natively.

Segment Routing emerged to address these needs, building on MPLS's proven concepts while introducing revolutionary simplifications. The MPLS data plane remained useful and was preserved; the control plane was reimagined.

## 1.8 Summary

This chapter traced MPLS's evolution from its ATM antecedents through its standardization, traffic engineering capabilities, and scaling challenges:

- **ATM's virtual circuit model** introduced the fundamental abstraction of pre-establishing paths with reserved resources, but its connection-oriented design limited scalability.

- **MPLS (1997-2001)** synthesized multiple proprietary approaches into a unified standard, introducing the label abstraction that enabled hardware-accelerated forwarding independent of IP header complexity.

- **RSVP-TE** added traffic engineering capabilities, allowing operators to direct specific LSPs through specific paths and reserve bandwidth along those paths.

- **BGP/MPLS VPNs** became the dominant enterprise VPN solution, leveraging MPLS transport with BGP-based route distribution to offer scalable, secure layer-3 VPN services.

- **Scaling limitations**—particularly control plane state, RSVP refresh overhead, and inter-AS complexity—created pressure for architectural evolution.

Segment Routing, the subject of the following chapters, emerged from these lessons, preserving MPLS's valuable forwarding model while fundamentally simplifying the control plane and adding powerful programmability.

---

**References**

- RFC 3031: Multiprotocol Label Switching Architecture
- RFC 3209: RSVP-TE: Extensions to RSVP for LSP Tunnels
- RFC 4364: BGP/MPLS IP Virtual Private Networks (VPNs)
- RFC 5317: MPLS Transport Profile (MPLS-TP) Requirements
- RFC 7432: BGP MPLS-Based Ethernet VPN