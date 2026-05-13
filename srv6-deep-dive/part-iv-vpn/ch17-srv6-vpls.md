# Chapter 17: SRv6 VPLS - Ethernet LAN Emulation over SRv6 Transport

## 17.1 Overview

VPLS (Virtual Private LAN Service) provides an Ethernet LAN emulation service across an IP/MPLS network, making geographically distributed sites appear as a single Ethernet switch. While EVPN has largely superseded VPLS in modern deployments due to its control-plane MAC learning and multi-homing capabilities, VPLS remains relevant for legacy deployments and specific use cases where its flood-and-learn model is acceptable. This chapter presents the VPLS architecture, how it operates over SRv6 transport, the pseudowire (PW) mechanisms that carry Layer 2 frames, MAC learning behavior, flooding suppression techniques, and the comparison between VPLS and its more modern EVPN counterpart.

SRv6 VPLS leverages the same transport principles as SRv6 L3VPN but delivers Ethernet frames rather than IP packets to VRF tables. The ingress PE encapsulates Ethernet frames in SRv6, the pseudowire carries them across the SRv6 domain, and the egress PE decapsulates and delivers them to the appropriate attachment circuit. The control plane may use LDP for pseudowire signaling (traditional VPLS) or BGP for auto-discovery (BGP-based VPLS).

## 17.2 VPLS Architecture Fundamentals

### 17.2.1 VPLS Service Model

VPLS emulates an Ethernet switch across the service provider's network:

```
VPLS Emulation Model:
CE1                              CE2
  |                                |
  | (802.1Q VLAN 100)              | (802.1Q VLAN 100)
  |                                |
PE1 ========== [VPLS Domain] ====== PE2
  |                                |
  | (802.1Q VLAN 100)              | (802.1Q VLAN 100)
  |                                |
CE3                              CE4

Logical View (emulated Ethernet switch):
+------------------------------------------+
|            VPLS Instance (VID 100)       |
|                                          |
|  CE1 ----+                               |
|          +---- [Emulated Switch] ---- CE2 |
|  CE3 ----+                      |        |
|                               CE4        |
+------------------------------------------+

All CEs appear connected to same Ethernet switch
MAC learning: CE1 learned on port1, CE3 on port2, etc.
Broadcast: Frame from CE1 reaches CE2, CE3, CE4
```

### 17.2.2 VPLS Components

VPLS involves several key components:

```
VPLS Components:
1. Provider Edge (PE) routers
   - Terminate ACs (Attachment Circuits) to CEs
   - Participate in VPLS forwarding
   - Maintain MAC address tables

2. Pseudowire (PW)
   - Point-to-point logical circuit between PEs
   - Carries L2 frames across the SP network
   -Signaled via LDP or BGP

3. VPLS Instance (VSI - Virtual Switch Instance)
   - Per-customer emulated Ethernet switch
   - MAC address table
   - Flooding domain

4. Attachment Circuit (AC)
   - Physical or VLAN interface connecting PE to CE
   - Carries customer traffic into/from VPLS
```

### 17.2.3 VPLS vs Traditional Ethernet

VPLS extends Ethernet beyond its native reach:

```
Native Ethernet Limitation:
- Maximum 100km (with repeaters)
- Geographically limited
- Single broadcast domain

VPLS Extension:
- Spans across service provider WAN
- CE devices unaware of WAN technology
- Emulated as single Ethernet segment
- Scalable to many sites
```

## 17.3 Pseudowire Architecture

### 17.3.1 Pseudowire Overview

A pseudowire (PW) is a point-to-point connection that carries Layer 2 frames across an IP/MPLS or SRv6 network:

```
Pseudowire Architecture:
PE1                              PE2
  |                                |
  | AC (CE traffic)                | AC (CE traffic)
  |                                |
  |------- Pseudowire (PW) --------|
  |                                |
  |   [Encapsulated L2 frames]    |
  |   [over SRv6 underlay]        |

PW Types:
- Ethernet (raw mode): Carries Ethernet frames directly
- Ethernet VLAN: Carries VLAN-tagged frames
- VPLS (Kompella): BGP-based pseudowire setup
```

### 17.3.2 PW Encapsulation for VPLS

The pseudowire encapsulation carries Ethernet frames over the SRv6 underlay:

```
PW Encapsulation over SRv6:
Outer: IPv6 header + SRH
  - DA = End.DX2 SID at remote PE
  - SA = Local PE locator
  - SRH = Empty or transit segments

Inner: Pseudowire header + Ethernet frame
  - Control Word (optional, 4 bytes)
  - PW ID (for demultiplexing at egress)
  - Ethernet frame (DA, SA, Type, Payload)

Complete Packet:
+------------------+
| IPv6 Header      |  (outer transport)
| SRH              |
+------------------+
| Control Word     |  (PW demultiplexing)
+------------------+
| PW ID            |
+------------------+
| Ethernet Header  |  (customer frame)
| Ethernet Payload |
+------------------+
```

### 17.3.3 LDP PW Signaling

Traditional VPLS uses LDP for pseudowire setup:

```
LDP PW Signaling:
1. PW ID ( FEC 129 or FEC 128) signaled between PEs
2. LDP label (MPLS label) allocated per PW
3. PW becomes active when both directions operational

FEC 128 (VPLS):
- PW ID: <Remote PE Address, PW ID>
- Demultiplexes traffic at egress PE
```

When running over SRv6, the LDP component is replaced by SRv6 behaviors—the PW ID still demultiplexes traffic at the egress, but the transport uses IPv6 destination-address routing instead of MPLS labels.

### 17.3.4 BGP Auto-Discovery for VPLS

BGP-based VPLS (Kompella model) uses BGP for both auto-discovery and PW setup:

```
BGP VPLS (Kompella):
1. PE advertises VPLS BGP routes:
   - RD (Route Distinguisher): Identifies PE and VPLS instance
   - RT (Route Target): VPLS instance membership
   - L2 VPN Information:
     - VEID (VPLS Edge ID): Local identifier
     - VBS (VPLS Block Size): Range of labels
     - Label base: Starting label value

2. Remote PEs learn of this PE via BGP
3. PW established between all PEs in same VPLS
4. No LDP required for PW setup
```

SRv6 VPLS can use BGP-based discovery to find remote PEs, then SRv6 transport to forward frames—the SRv6 SID replaces the MPLS label for demultiplexing.

## 17.4 MAC Learning in VPLS

### 17.4.1 Flood-and-Learn

VPLS uses data-plane MAC learning (flood-and-learn):

```
MAC Learning Process:
1. PE1 receives frame from CE1
   - Src MAC: MAC-A
   - PE1 learns: MAC-A → interface to CE1

2. PE1 needs to forward to CE2 (on remote PE2)
   - PE1 does not know MAC-A's location (PE2)
   - PE1 floods frame to all PEs in VPLS
   - PE2 receives, learns: MAC-A → PE1 (via PW)

3. Return traffic from CE2 to MAC-A:
   - PE2 has MAC-A in table → PE1
   - Unicast forward over PW to PE1
   - No flooding needed

Drawback: First traffic to unknown MAC floods entire VPLS
```

### 17.4.2 MAC Address Table

Each PE maintains a MAC address table per VPLS instance:

```
MAC Address Table (VPLS Instance X):
| MAC Address | Learned From      | Age Timer |
|-------------|-------------------|-----------|
| MAC-A       | Local AC (CE1)    | 300s      |
| MAC-B       | PW to PE2         | 200s      |
| MAC-C       | PW to PE3         | 180s      |

Aging:
- MAC entries age out if no traffic seen
- Default aging: 300 seconds (configurable)
- Traffic refreshes the age timer
```

### 17.4.3 Unknown Unicast Flooding

Frames destined to unknown MAC addresses flood across the VPLS:

```
Unknown Unicast Handling:
CE1 sends frame:
  DA = unknown MAC (never seen in VPLS)
  SA = MAC-A (known locally)

PE1 forwarding decision:
1. MAC-A is local → learn on AC
2. DA unknown → flood domain
3. Flood to all PEs via pseudowires
4. Each remote PE delivers to attached CEs
5. If CE responds, MAC learned and future traffic unicast
```

### 17.4.4 Broadcast and Multicast

Broadcast frames (DA = FF:FF:FF:FF:FF:FF) are flooded to all PEs:

```
Broadcast Handling:
CE1 sends ARP request (broadcast):
  DA = FF:FF:FF:FF:FF:FF
  SA = MAC-A

PE1 receives, forwards to all PEs:
  - PE2 via PW1
  - PE3 via PW2
  - PE4 via PW3
  - (All PEs in same VPLS)

Each PE:
  - Receives over PW
  - Delivers to attached CEs
  - ARP request reaches all CEs in VPLS
```

## 17.5 VPLS over SRv6

### 17.5.1 SRv6 VPLS Architecture

VPLS over SRv6 uses the same architecture as VPLS over MPLS, with SRv6 transport replacing the MPLS underlay:

```
VPLS over SRv6 Architecture:
CE1 --- PE1 --- [SRv6 Domain] --- PE2 --- CE2
CE3 --- PE1                            PE2 --- CE4

Control Plane:
- LDP for PW signaling (traditional)
- OR BGP for auto-discovery (Kompella)
- IGP for locator reachability in SRv6 domain

Data Plane:
- Ethernet frames encapsulated in SRv6
- End.DX2 behavior at egress delivers to AC
- PW ID for demultiplexing at egress PE
```

### 17.5.2 SRv6 VPLS Behaviors

The End.DX2 behavior delivers Ethernet frames at the egress PE:

```
End.DX2(vpw=<pw-id>) Behavior:
1. If SL > 0:
   a. SL = SL - 1
   b. DA = Segment[SL]
   c. Forward based on new DA
2. If SL == 0:
   a. Remove outer IPv6 header and SRH
   b. Extract inner PW packet
   c. Use PW ID to identify pseudowire
   d. Deliver inner Ethernet frame to specified PW
```

The PW ID carried in the encapsulation identifies which VPLS instance and pseudowire the frame belongs to, enabling the egress PE to deliver to the correct VSI.

### 17.5.3 PW Demultiplexing

Pseudowire demultiplexing identifies which VPLS instance and pseudowire a frame belongs to:

```
PW Demultiplexing (SRv6 VPLS):
Outer: IPv6 DA = End.DX2 SID at egress PE
SRH: SL=0 (single segment)

At egress PE:
1. DA matches local End.DX2 SID
2. Extract PW ID from inner encapsulation
3. PW ID identifies:
   - VPLS Instance (VSI)
   - Pseudowire (which CE interface)
4. Deliver Ethernet frame to appropriate AC
```

### 17.5.4 VPLS Service Instance (VSI) Configuration

Each VPLS instance (VSI) is configured with:

```
VSI Configuration Elements:
1. VSI Name/ID: Local identifier
2. RD: Route Distinguisher (for BGP VPLS)
3. RT: Route Target (for BGP VPLS)
4. PW type: Ethernet, Ethernet VLAN, VPLS
5. MAC aging: Timer for MAC table aging
6. Flooding: Multicast, broadcast, unknown unicast handling
7. PW to remote PEs: Established via LDP or BGP
```

## 17.6 H-VPLS (Hierarchical VPLS)

### 17.6.1 H-VPLS Overview

Hierarchical VPLS reduces flooding scope and scaling requirements in large VPLS deployments:

```
Standard VPLS:
All PEs meshed with full pseudowires
O(N²) PWs for N PEs

H-VPLS:
Regional aggregation with hub-and-spoke
Reduces PW count, limits flooding scope

Topology:
PE1 ---+
       |
       +--- Hub-PE ---- [Backbone VPLS] ---- Remote-PE1
       |                                    (spoke)
PE2 ---+                                    |
                                              Remote-PE2
```

### 17.6.2 H-VPLS with SRv6

H-VPLS over SRv6 uses the same transport principles:

```
H-VPLS Transport:
Spoke-PE → Hub-PE: SRv6 tunnel to Hub-PE
Hub-PE → Remote-PE: SRv6 tunnel to Remote-PE

Benefit:
- Spoke-PEs only maintain single PW to Hub
- Hub-PE aggregates traffic before backbone
- Flooding scope reduced to Hub+Remote PEs
```

## 17.7 VPLS vs EVPN Comparison

### 17.7.1 Feature Comparison

| Feature                | VPLS                         | EVPN                      |
| ---------------------- | ---------------------------- | ------------------------- |
| MAC Learning           | Data plane (flood-and-learn) | Control plane (BGP)       |
| Multi-homing           | Limited (no native)          | Native (ESI, DF election) |
| Optimal forwarding     | Only after learning          | Always optimal            |
| Unknown unicast        | Flood entire VPLS            | BGP分布式, selective      |
| BUM handling           | Flood                        | Per-ES DF forwarding      |
| Scaling                | Poor for large MAC spaces    | Better (no flooding)      |
| PW signaling           | LDP or BGP                   | BGP only                  |
| Operational complexity | Lower                        | Higher                    |
| Deployment maturity    | Mature                       | Modern                    |

### 17.7.2 Migration Considerations

Operators migrating from VPLS to EVPN face:

```
Migration Path:
1. Run VPLS and EVPN in parallel during transition
2. Gradually convert CEs to EVPN-capable PEs
3. Establish EVPN control plane
4. Move traffic to EVPN
5. Decommission VPLS pseudowires

Key Differences:
- MAC learning shifts from data plane to BGP
- Flooding behavior changes
- Multi-homing becomes native
- PW signaling simplified
```

## 17.8 VPLS Flooding Behavior

### 17.8.1 Flooding Domains

VPLS flooding occurs within each VPLS instance:

```
Flooding in VPLS:
Frame type → Flooding behavior:
- Broadcast (FF:FF:FF:FF:FF:FF): Flood to all PEs
- Unknown unicast: Flood to all PEs
- Multicast: Flood to all PEs (or subscribed subset)

Flooding optimization:
- Multicast replication lists (if available)
- Ingress replication (no flooding tree)
- Selective flooding based on VLAN membership
```

### 17.8.2 Broadcast Suppression

Broadcast traffic can overwhelm VPLS networks:

```
Broadcast Suppression Techniques:
1. Rate limiting: Limit broadcast traffic rate per AC
2. ARP proxy: PE answers ARP locally
   - CE sends ARP request
   - PE intercepts and responds with MAC
3. Unknown unicast rate limiting: Limit flooding rate
4. Storm control: Per-interface broadcast limit
```

### 17.8.3 ARP Proxy

ARP proxy reduces broadcastARP requests in VPLS:

```
ARP Proxy Operation:
CE1 wants MAC for 10.0.0.1 (CE2's IP):
1. CE1 broadcasts ARP request: Who has 10.0.0.1?
2. PE1 (with ARP proxy) intercepts
3. PE1 has mapping: 10.0.0.1 → MAC-B (learned via BGP or cache)
4. PE1 responds: MAC-B is at 10.0.0.1
5. CE1 sends unicast directly to MAC-B
6. Broadcast ARP eliminated

Benefit: Reduces broadcast flooding significantly
```

## 17.9 Configuration Overview

### 17.9.1 Basic VPLS Configuration

```
IOS-XR VPLS Configuration:
1. SRv6 enablement
   segment-routing srv6
     locators
       locator LOC1
         48-bit prefix FC00:0:1::/48

2. VPLS instance
   l2vpn
     vpls TEST-VSI
       rd 100:1
       route-target 65001:100
       pw-class PW-CLASS
      Interface CE1
         vlan-id 100

3. Pseudowire (LDP signaling):
   l2vpn
     pw-class PW-CLASS
       encapsulation mpls
         transport-mode ethernet

   vpls TEST-VSI
     neighbor 10.0.0.2 pw-class PW-CLASS

4. AC interface
   interface GigabitEthernet0/0.100
     encapsulation dot1q 100
     l2vpn
       xconnect group TEST-VSI
         vpls TEST-VSI
```

### 17.9.2 BGP VPLS (Kompella) Configuration

```
BGP VPLS Configuration:
l2vpn
  vpls TEST-VSI
    bgp
      rd 100:1
      route-target both 65001:100
      ve-id 1
      ve-block-size 10
    pw-class PW-CLASS

PE learns remote VEs via BGP and automatically establishes PWs
```

### 17.9.3 Verification Commands

```
show l2vpn vpls:
- VPLS instances and their status
- MAC table for each VSI
- PW status to remote PEs

show l2vpn mac:
- MAC addresses learned locally and remotely
- Aging timers
- Associated interfaces

show srv6 sid:
- End.DX2 SIDs allocated for VPLS
- SID usage
```

## 17.10 VPLS over SRv6 Packet Flow

### 17.10.1 MAC Learning Flow

```
Topology:
CE1 (MAC-A) --- PE1
                      [SRv6 Domain]
CE2 (MAC-B) --- PE2

Step 1: CE1 sends to MAC-B (unknown at PE1)
PE1 receives on AC:
  - Src MAC: MAC-A (learn locally)
  - Dst MAC: MAC-B (unknown)
  - Flood to all remote PEs in VPLS

Step 2: PE1 encapsulates for SRv6 transport
Outer IPv6:
  - DA = End.DX2 SID at PE2
  - SA = PE1 locator
SRH: Empty
Inner: PW packet with Ethernet frame

Step 3: Transit forwards to PE2

Step 4: PE2 receives, End.DX2 processing
- DA matches local End.DX2 SID
- Extract inner Ethernet frame
- PW ID identifies VPLS instance
- Deliver to VSI, forward to CE2
- Learn MAC-A (source of frame)

Step 5: PE2 advertises MAC-B back (if BGP-based VPLS)
- MAC-B learned locally
- BGP route to other PEs
```

### 17.10.2 Unicast Flow After Learning

```
After learning (CE1 → CE2 response):
CE2 sends to MAC-A:
  - Src MAC: MAC-B
  - Dst MAC: MAC-A

PE2 forwarding decision:
  - MAC-A → PW to PE1 (known destination)
  - Encapsulate: DA = End.DX2 SID at PE1
  - SRv6 transport to PE1
  - PE1 delivers to CE1

Unicast path established, no flooding
```

## 17.11 Summary

VPLS over SRv6 provides Ethernet LAN emulation using the SRv6 transport plane:

- **Emulated Ethernet Switch**: VPLS makes geographically distributed sites appear as a single Ethernet switch, with MAC learning and flooding creating the LAN emulation.

- **Pseudowire Transport**: Ethernet frames are carried over SRv6 using End.DX2 behaviors, with PW IDs for demultiplexing at egress PEs.

- **Flood-and-Learn MAC Model**: MAC addresses are learned from traffic, and unknown destinations flood across the VPLS domain. This scales poorly for large MAC spaces.

- **BGP or LDP Signaling**: Pseudowires can be signaled via LDP (traditional) or BGP auto-discovery (Kompella), with SRv6 handling the transport.

- **H-VPLS Optimization**: Hierarchical VPLS reduces PW mesh complexity by aggregating traffic at hub PEs before entering the backbone.

- **VPLS vs EVPN**: EVPN provides control-plane MAC learning, native multi-homing, and optimal forwarding—advantages over VPLS that drive modern deployments toward EVPN.

Understanding VPLS provides context for the evolution to EVPN, while SRv6 transport provides the modern programmable underlay for both service types.

---

**References**

- RFC 4761: Virtual Private LAN Service (VPLS) Using BGP for Auto-Discovery and Signaling
- RFC 4762: Virtual Private LAN Service (VPLS) Using LDP Signaling
- RFC 5662: Ethernet VPN (EVPN) - comparison context
- RFC 7209: Requirements for Ethernet VPN (EVPN) - comparison context
- RFC 7432: BGP EVPN - comparison context
- RFC 8986: SRv6 Network Programming (End.DX2 behavior)
- RFC 8754: IPv6 Segment Routing Header (SRH)
- IETF draft: VPLS over SRv6
- IETF draft: SRv6 VPN Deployment Considerations
