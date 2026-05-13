# Chapter 15: SRv6 VPN Overview - Architecture, Behaviors, and Service Delivery

## 15.1 Overview

SRv6 VPN leverages the Segment Routing over IPv6 architecture to deliver Layer 3 virtual private network services with a fundamentally different approach than traditional MPLS VPN. Where MPLS VPN relies on label-swapped LSPs for transport and separate VPN label mechanisms for service delivery, SRv6 VPN unifies transport and service into a single programmable framework using destination-address-based routing and SID behaviors. This chapter presents the comprehensive SRv6 VPN architecture, the specific behaviors that enable VPN service delivery, the BGP control-plane extensions, and the packet flows that characterize SRv6-based VPN operation.

The architectural shift from MPLS VPN to SRv6 VPN reflects broader trends in network design: the desire for IPv6-native transport, the programmability requirements of modern cloud-connected networks, and the operational simplification that comes from eliminating RSVP-TE and LDP signaling in favor of source-routed paths computed by controllers or IGP-based path calculation.

## 15.2 SRv6 VPN Architecture

### 15.2.1 Core Architectural Principles

SRv6 VPN architecture rests on three foundational principles inherited from the broader SRv6 design:

1. **Source Routing for Transport**: The ingress PE (Provider Edge) computes the path through the SRv6 domain and encodes it in the SRH (Segment Routing Header). Transit PEs perform only destination-address-based forwarding, requiring no per-VPN state.

2. **Behavior-Based Service Delivery**: The final segments in the segment list execute VPN-specific behaviors—End.DT4 for IPv4 VPN delivery, End.DT6 for IPv6 VPN delivery—that decapsulate the outer headers and deliver the inner packet to the appropriate VRF (Virtual Routing and Forwarding) table.

3. **BGP for VPN Route Distribution**: BGP carries VPN routes (VPNv4, VPNv6) between PE routers using standard BGP address families, with Route Targets controlling which VRFs import which routes. The SRv6 SID information is carried as a BGP attribute, enabling the egress PE to identify the correct SID behavior for the destination.

This architecture eliminates the MPLS label stack entirely in favor of IPv6 addressing and SRH encoding. A VPN packet traversing the SRv6 domain carries an outer IPv6 header with DA set to the endpoint SID, an SRH containing subsequent segments if needed, and an inner payload containing the original customer packet.

### 15.2.2 SRv6 VPN vs MPLS VPN Comparison

Understanding the architectural differences between SRv6 VPN and MPLS VPN clarifies the trade-offs operators face:

| Aspect | MPLS VPN | SRv6 VPN |
|--------|----------|----------|
| Transport | Label-switched LSPs via LDP or RSVP-TE | IPv6 destination-address routing via IGP |
| Signaling | LDP for LSP setup, RSVP-TE for TE | IGP for locator reachability, BGP for paths |
| VPN Delivery | VPN label (20 bits) identifies VRF + route | End.DT4/End.DT6 behavior identifies VRF |
| Encapsulation | Outer MPLS label stack | Outer IPv6 + SRH |
| Scalability | O(N) LSP state at transit LSRs | O(N) locator FIB entries at transit routers |
| OAM | TTL-based LSP ping/traceroute | ICMPv6 + SRv6 trace |
| Path Control | RSVP-TE or per-LSP steering | SR Policy, TI-LFA, FlexAlgo |
| IPv6 Native | Not native (labels are IPv4-native) | Native IPv6 underlay and overlay |

The MPLS VPN model uses a two-level label stack: the outer label steers the packet through the LSP from ingress PE to egress PE, while the inner VPN label (allocated by the egress PE and signaled via BGP) identifies the VRF and specific route at the egress. The egress PE pops both labels and performs a VRF lookup on the inner IP packet.

SRv6 VPN collapses this into a single mechanism: the outer IPv6 DA directly identifies the egress PE and the behavior to execute. The SRH (if present beyond the first segment) contains additional path segments, but the fundamental operation is destination-address-based routing, not label switching. The End.DT6 behavior at the egress PE encapsulates the decapsulation logic that would otherwise require a VPN label.

### 15.2.3 Network Topology and Components

A typical SRv6 VPN deployment involves:

```
CE (Customer Edge) devices connecting to PE (Provider Edge) routers
PE routers forming an SRv6 domain using IPv6 underlay
Route Reflectors (RR) in the control plane for BGP route distribution
SR Policy Controllers (optional) for traffic engineering
```

The CE devices are unaware of the SRv6 transport—they send normal IP packets to the PE, which encapsulates them into SRv6 for transport across the provider network. At the egress PE, the SRv6 encapsulation is stripped, and the original IP packet is delivered to the appropriate VRF based on the local VRF attachment and the routing table lookup.

## 15.3 SRv6 VPN Behaviors

### 15.3.1 End.DT6 (Decapsulation and VRF Lookup for IPv6)

**End.DT6** is the primary behavior for IPv6 VPN delivery. It performs decapsulation of the outer IPv6 and SRH headers and delivers the inner IPv6 packet to the appropriate VRF table for routing.

```
End.DT6(vrf=<vrf-id>) Behavior:
1. If SL > 0:
   a. SL = SL - 1
   b. DA = Segment[SL]
   c. Forward based on new DA
2. If SL == 0:
   a. Remove outer IPv6 header and SRH
   b. Extract inner IPv6 packet
   c. Perform VRF lookup on inner packet's DA in vrf=<vrf-id>
   d. Forward based on VRF routing table
```

The VRF table is identified by the behavior argument (vrf-id). The egress PE maintains a mapping from SID values to VRF tables—different End.DT6 SIDs can point to different VRFs, enabling multi-tenant VPN services from a single egress PE.

### 15.3.2 End.DT4 (Decapsulation and VRF Lookup for IPv4)

**End.DT4** provides identical functionality for IPv4 VPN payloads carried over SRv6. When the inner packet is IPv4, the egress PE executes End.DT4, which strips the SRv6 encapsulation and performs a VRF lookup on the inner IPv4 destination address.

```
End.DT4(vrf=<vrf-id>) Behavior:
1. If SL > 0:
   a. SL = SL - 1
   b. DA = Segment[SL]
   c. Forward based on new DA
2. If SL == 0:
   a. Remove outer IPv6 header and SRH
   b. Extract inner IPv4 packet
   c. Perform VRF lookup on inner packet's DA in vrf=<vrf-id>
   d. Forward based on VRF routing table
```

The End.DT4 behavior enables IPv4 VPN services over an SRv6 network that may be entirely IPv6 underlay—a common deployment scenario where IPv4 customer traffic traverses an IPv6-only provider network.

### 15.3.3 End.DT46 (Dual Stack VPN)

**End.DT46** handles both IPv4 and IPv6 inner packets, performing a lookup in a VRF that contains both address families. This behavior simplifies the VRF design for dual-stack VPN services.

```
End.DT46(vrf=<vrf-id>) Behavior:
1. If SL > 0:
   a. SL = SL - 1
   b. DA = Segment[SL]
   c. Forward based on new DA
2. If SL == 0:
   a. Remove outer IPv6 header and SRH
   b. Inspect inner packet's IP version
   c. If IPv4: VRF lookup in IPv4 table
   d. If IPv6: VRF lookup in IPv6 table
   e. Forward based on routing table
```

### 15.3.4 End.DX6 (Decapsulation and Cross-Connect for IPv6)

**End.DX6** delivers the inner IPv6 packet to a specific interface rather than performing a VRF lookup. This behavior is used for point-to-point L3VPN connections where the egress PE forwards directly to a connected CE.

```
End.DX6(if=<interface-id>) Behavior:
1. If SL > 0:
   a. SL = SL - 1
   b. DA = Segment[SL]
   c. Forward based on new DA
2. If SL == 0:
   a. Remove outer IPv6 header and SRH
   b. Extract inner IPv6 packet
   c. Send to interface <interface-id> without VRF lookup
```

### 15.3.5 End.DX4 (Decapsulation and Cross-Connect for IPv4)

**End.DX4** provides the same cross-connect functionality for IPv4 inner packets.

```
End.DX4(if=<interface-id>) Behavior:
1. If SL > 0:
   a. SL = SL - 1
   b. DA = Segment[SL]
   c. Forward based on new DA
2. If SL == 0:
   a. Remove outer IPv6 header and SRH
   b. Extract inner IPv4 packet
   c. Send to interface <interface-id> without VRF lookup
```

## 15.4 BGP Control Plane for SRv6 VPN

### 15.4.1 BGP Address Families

SRv6 VPN uses standard BGP address families for route distribution, extended with SRv6-specific attributes:

```
BGP Address Families for SRv6 VPN:
- VPNv4: Route Distinguisher + IPv4 prefix (RD:IPv4)
- VPNv6: Route Distinguisher + IPv6 prefix (RD:IPv6)
- SRv6 VPN: Carries SRv6 SID information as BGP path attribute
```

The Route Distinguisher (RD) prepended to VPN routes ensures uniqueness across the VPN backbone—different sites using the same private address space receive distinct VPN routes because the RD creates unique route distinguisher prefixes.

### 15.4.2 BGP SRv6 VPN Route Attributes

When a PE advertises a VPN route to another PE via BGP, it includes:

```
BGP Route Attributes for SRv6 VPN:
- RD (Route Distinguisher): 8-byte value ensuring route uniqueness
- Prefix: The customer's VPN prefix (IPv4 or IPv6)
- RT (Route Target): Extended community identifying which VRFs import this route
- SRv6 SID: The End.DT6/End.DT4 SID at this PE for this route
- Next Hop: Typically the PE's loopback or locator address
```

The SRv6 SID attribute is the critical addition for SRv6 VPN. When PE1 advertises a route learned from CE1 to PE2 via BGP, it includes the SID that PE2 should use as the endpoint when sending traffic to CE1. This SID-and-behavior combination replaces the VPN label concept from MPLS VPN.

### 15.4.3 Route Target Handling

Route Targets (RT) control which VRFs receive which VPN routes:

```
RT Import/Export Process:
1. CE1 sends route to PE1 (e.g., 10.1.1.0/24)
2. PE1 exports route with RT = 100:1 (export community)
3. PE1 advertises route to RR or directly to PE2
4. PE2 has VRF configured with import RT = 100:1
5. PE2 imports route into VRF, associating it with End.DT6 SID
6. CE2 can now reach CE1's 10.1.1.0/24 via PE2
```

This import/export mechanism enables complex VPN topologies: simple intra-VPN (all sites in same VPN), hub-and-spoke (central hub receives all routes, spokes receive only hub route), or custom topologies matching business requirements.

### 15.4.4 BGP Multi-Hop and Route Reflector Design

SRv6 VPN typically uses multi-hop BGP between PEs, allowing the BGP session to traverse the IPv6 underlay without requiring direct adjacency. Route Reflectors (RR) concentrate route advertisements:

```
RR Topology:
CE1 --- PE1 --- Transit --- RR --- Transit --- PE2 --- CE2
                (SRv6 domain)         (SRv6 domain)

BGP Session: PE1 <---> RR <---> PE2 (multi-hop eBGP or iBGP)
```

The RR does not require SRv6 capability—it simply reflects BGP routes. The SRv6 SID information passes through the RR transparently as a BGP path attribute.

## 15.5 Packet Flow Examples

### 15.5.1 IPv6 VPN Packet Flow

Consider an IPv6 VPN scenario where CE1 (site A) sends traffic to CE2 (site B):

```
Network Topology:
CE1 (2001:db8:1::1) --- PE1 (Site A) --- [SRv6 Domain] --- PE2 (Site B) --- CE2 (2001:db8:2::1)

VPN: Customer A
VRF: vrf-100 at both PEs
```

**Control Plane Flow:**
```
1. CE1 advertises 2001:db8:1::/48 to PE1 via routing protocol (BGP, OSPF, or static)
2. PE1 installs route in VRF-100: 2001:db8:1::/48 → CE1 (connected interface)
3. PE1 allocates End.DT6 SID for this route: FC00:0:2:100::1 (example)
4. PE1 advertises to PE2 via BGP:
   - Prefix: RD:2001:db8:1::/48
   - RT: 100:1
   - SRv6 SID: FC00:0:2:100::1 (End.DT6, vrf=100)
   - Next Hop: PE1's locator
5. PE2 receives route, imports into VRF-100 (matching RT)
6. PE2 installs route: 2001:db8:1::/48 → End.DT6(FC00:0:2:100::1)
```

**Data Plane Flow (CE1 to CE2):**
```
1. CE1 sends packet: Src=2001:db8:1::1, Dst=2001:db8:2::1
2. PE1 receives packet on VRF-100 interface
3. PE1 VRF lookup: 2001:db8:2::1 matches 2001:db8:2::/48 → End.DT6 SID = FC00:0:2:200::1
4. PE1 encapsulates:
   - Outer IPv6: Src=PE1-locator, Dst=FC00:0:2:200::1
   - SRH: [empty or single segment], SL=0
   - Inner: Original CE1→CE2 packet
5. Transit routers forward based on DA (FC00:0:2:200::1 matches PE2 locator)
6. PE2 receives packet with DA = FC00:0:2:200::1
7. PE2 executes End.DT6(vrf=100):
   - SL == 0: Remove outer IPv6/SRH
   - Inner packet: 2001:db8:1::1 → 2001:db8:2::1
   - VRF-100 lookup: 2001:db8:2::1 connected to CE2
8. PE2 forwards original packet to CE2
```

### 15.5.2 IPv4 VPN over SRv6 Packet Flow

IPv4 VPN over SRv6 demonstrates SRv6's ability to carry legacy IPv4 traffic over IPv6 transport:

```
Network Topology:
CE1 (10.1.1.1) --- PE1 (Site A) --- [SRv6 Domain] --- PE2 (Site B) --- CE2 (10.2.2.2)

Inner packet: IPv4 (not IPv6)
Outer transport: IPv6 + SRH
```

**Control Plane Flow:**
```
1. CE1 advertises 10.1.1.0/24 to PE1
2. PE1 installs in VRF-100: 10.1.1.0/24 → CE1
3. PE1 allocates End.DT4 SID for this route: FC00:0:2:100::DT4 (using DT4 function code)
4. PE1 advertises to PE2 via BGP:
   - Prefix: RD:10.1.1.0/24
   - RT: 100:1
   - SRv6 SID: FC00:0:2:100::DT4 (End.DT4, vrf=100)
```

**Data Plane Flow:**
```
1. CE1 sends: Src=10.1.1.1, Dst=10.2.2.2
2. PE1 VRF lookup: 10.2.2.2 → End.DT4 SID = FC00:0:2:200::DT4
3. PE1 encapsulates:
   - Outer IPv6: Src=PE1-locator, Dst=FC00:0:2:200::DT4
   - SRH: SL=0
   - Inner: Original IPv4 packet (10.1.1.1 → 10.2.2.2)
4. Transit forwards via IPv6 (PE2 locator)
5. PE2 receives, DA matches End.DT4 SID
6. PE2 executes End.DT4(vrf=100):
   - Strip IPv6/SRH
   - Inner IPv4 packet delivered to VRF-100
   - Lookup 10.2.2.2 → CE2
7. Forward to CE2
```

The IPv4 packet traverses the entire SRv6 domain inside an IPv6 envelope—the transit network is IPv6-only, yet carries IPv4 customer traffic without modification.

## 15.6 SRv6 VPN Transport Options

### 15.6.1 Single SID Transport

In the simplest case, the ingress PE uses a single SID (the End.DT6 SID at the egress PE) as the destination address:

```
Single SID Encapsulation:
- Outer DA = End.DT6 SID at egress PE
- SRH = Empty (no additional segments)
- SL = 0
```

This provides basic reachability but no traffic engineering—the IGP shortest path determines the route through the SRv6 domain.

### 15.6.2 SR Policy Transport

For traffic engineering, the ingress PE programs an SR Policy with an explicit segment list:

```
SR Policy Transport:
- Outer DA = First segment in SR Policy
- SRH contains: [End.DT6 SID at egress PE, ..., transit segments]
- SL = N-1 (where N = number of segments)

Example: Segment list [S1, S2, E] where S1/S2 are midpoints
- Ingress PE pushes SRH: Segments = [S1, S2, E], SL=2
- S1: End behavior, SL=2→1, DA=S2
- S2: End behavior, SL=1→0, DA=E
- E: End.DT6, decapsulate and VRF deliver
```

SR Policy enables path control through specific nodes, interface selection, or avoidance of congestion. The ingress PE can compute the SR Policy itself or receive it from a PCE (Path Computation Element).

### 15.6.3 TI-LFA Protection

TI-LFA (Topology-Independent Loop-Free Alternates) provides sub-50ms protection for SRv6 VPN traffic:

```
TI-LFA Protected Path:
- Primary: [ingress PE → ... → egress PE]
- Backup: [ingress PE → ... → PQ node → ... → egress PE]

When primary link fails:
1. Pre-computed backup path instantly activates
2. O(1) switchover time
3. TI-LFA backup path encoded as SR Policy segment list
```

The TI-LFA backup path is pre-computed based on the segment list, providing rapid convergence without topology-dependent calculations at failure time.

## 15.7 Comparison with MPLS VPN

### 15.7.1 Structural Differences

The fundamental difference lies in the transport mechanism:

```
MPLS VPN Transport:
PE1                    Transit                   PE2
|                         |                        |
| <- LSP (label stack) -> |                        |
|    Outer: transport label                       |
|    Inner: VPN label                             |
                                                  |
VPN Label Operation:                              |
- PE2 allocated VPN label for each route         |
- VPN label identifies VRF + route               |
- PE2 pops both labels, VRF lookup inner IP      |

SRv6 VPN Transport:
PE1                    Transit                   PE2
|                         |                        |
| <- IPv6 + SRH (DA = SID) -> |                     |
|    Outer: IPv6 DA (locator + SID)               |
|    No VPN label needed                          |
                                                  |
SID Behavior Operation:                           |
- PE2 allocated End.DT6 SID for each VRF          |
- SID identifies behavior + VRF                   |
- PE2 executes End.DT6, VRF lookup inner IP       |
```

### 15.7.2 Operational Comparison

| Operational Aspect | MPLS VPN | SRv6 VPN |
|-------------------|----------|----------|
| Label Distribution | LDP or RSVP-TE required | IGP advertising locators suffices |
| Control Plane | BGP for VPN routes + LDP/RSVP for transport | BGP for both VPN routes and SID distribution |
| Transit State | O(N) LSPs in network | O(N) locator FIB entries |
| Path Control | RSVP-TE LSPs or per-flow steering | SR Policy segment lists |
| Fast Reroute | LFA, RLFA, TI-LFA | TI-LFA (native to SR) |
| Hardware Efficiency | Label lookup in TCAM | IPv6 FIB lookup (native forwarding) |
| IPv6 Support | Dual-stack (IPv6 labels possible but uncommon) | Native IPv6 underlay and overlay |
| OAM Tools | LSP ping, MPLS traceroute | ICMPv6, SRv6 traceroute, IOAM |
| Troubleshooting | MPLS label operations complex | Standard IPv6 tools plus SID info |

### 15.7.3 Migration Considerations

Operators migrating from MPLS VPN to SRv6 VPN face several considerations:

1. **Dual-Stack Transition**: During migration, both MPLS VPN and SRv6 VPN may coexist, with interworking at PEs that support both architectures.

2. **SID Allocation**: Operators must design their SID allocation scheme to support VPN services—End.DT4/End.DT6 SIDs need to be allocated per VRF, potentially requiring many SIDs at multi-tenant PEs.

3. **BGP Peering**: Existing BGP peerings can carry SRv6 VPN routes with the addition of SRv6 SID attributes. No new BGP sessions are required.

4. **CE Connectivity**: CE devices remain unaware of the transport mechanism—they continue using standard routing protocols to peer with PEs.

## 15.8 Multi-Tenancy with SRv6 VPN

### 15.8.1 VRF Isolation

Each tenant receives a dedicated VRF at each PE they connect to:

```
VRF Per Tenant:
- VRF Tenant-A: RD 100:1, RT import 100:1, export 100:1
- VRF Tenant-B: RD 100:2, RT import 100:2, export 100:2

PE1 Configuration:
- Interface to Tenant-A CE: VRF Tenant-A
- Interface to Tenant-B CE: VRF Tenant-B
- End.DT6 SID pool: FC00:0:1:100:: (Tenant-A), FC00:0:1:200:: (Tenant-B)
```

### 15.8.2 Shared Services

Tenants may require access to shared services (internet break-out, centralized firewall):

```
Shared Service Model:
- Tenant-A VRF imports RT 65000:1 (shared services RT)
- Shared Services VRF exports RT 65000:1
- Tenant-A routes advertised with both RT 100:1 and RT 65000:1
- Shared services can reach tenant prefixes; tenant prefixes reach shared services
```

## 15.9 OAM and Troubleshooting

### 15.9.1 Connectivity Verification

SRv6 VPN connectivity verification uses standard IPv6 tools plus SRv6-specific extensions:

```
Ping from CE1 to CE2 (via SRv6 VPN):
1. CE1 pings CE2's address (10.2.2.2 or 2001:db8:2::1)
2. PE1 receives, forwards based on VRF
3. If SRv6 transport working: packet reaches PE2
4. PE2 delivers to CE2
5. CE2 responds, reverse path works similarly

SRv6-specific ping:
- Source sends ICMPv6 to End.DT6 SID
- SID execution at egress PE triggers ICMP response
- Verifies SRv6 reachability to the VPN endpoint
```

### 15.9.2 Traceroute

Traceroute through SRv6 VPN reveals the segment path:

```
Traceroute from CE1 to CE2:
1. TTL=1: First transit node responds with ICMP Time Exceeded
2. TTL=2: Second transit node responds
3. Continue until egress PE
4. Egress PE responds with ICMP (after End.DT6 processing)
```

### 15.9.3 BGP Route Verification

BGP route troubleshooting involves verifying the SRv6 SID attribute:

```
show bgp vpnv4 unicast <prefix>:
- Route Distinguisher
- Route Target
- Next Hop
- SRv6 SID: <SID value>, Behavior: End.DT6, VRF: <vrf-id>

verify SRv6 SID allocation:
show srv6 sid:
- List all End.DT4/End.DT6 SIDs
- Associated VRFs
- Usage count (routes using this SID)
```

## 15.10 Summary

SRv6 VPN delivers Layer 3 VPN services over IPv6 underlay using the network programming model:

- **Architectural Simplicity**: SRv6 VPN eliminates the separate label distribution plane (LDP/RSVP-TE) required for MPLS VPN, using only IGP for locator reachability and BGP for both VPN routes and SID distribution.

- **Behavior-Based Delivery**: The End.DT4 and End.DT6 behaviors perform decapsulation and VRF lookup in a single operation, replacing the VPN label mechanism with direct SID-to-behavior mapping.

- **Native IPv6 Transport**: The SRv6 underlay is natively IPv6, enabling IPv4 VPN traffic to traverse IPv6-only networks without tunneling or translation.

- **Scalable Transit**: Transit routers maintain only locator FIB entries—O(N) for N nodes—regardless of how many VPN routes or SIDs exist in the network.

- **Programmable Paths**: SR Policy enables traffic engineering for VPN traffic, while TI-LFA provides sub-50ms protection against failures.

- **BGP Control Plane**: Standard BGP address families (VPNv4, VPNv6) carry SRv6 SID information as BGP path attributes, enabling backward-compatible deployment with existing BGP route reflector infrastructure.

Understanding the SRv6 VPN architecture provides the foundation for subsequent chapters on EVPN (which adds multi-homed Ethernet service capabilities) and IOAM (which adds operational visibility to SRv6 transport).

---

**References**

- RFC 8986: SRv6 Network Programming
- RFC 8754: IPv6 Segment Routing Header (SRH)
- RFC 8402: Segment Routing Architecture
- RFC 4364: BGP MPLS/IP Virtual Private Networks (MPLS VPN)
- RFC 4659: BGP-MPLS VPN Extension for IPv6 VPN (VPNv6)
- RFC 9136: IPv6 Provider Edge Router (6PE) / IPv6 VPN Provider Edge Router (6VPE)
- RFC 5549: Advertising IPv4 Routes over IPv6 NBMA Networks
- RFC 8214: Virtual Private Wire Service Support in EVPN
- IETF draft: SRv6 VPN over IPv6 Underlay
- IETF draft: BGP SRv6 VPN
