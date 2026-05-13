# Chapter 16: SRv6 EVPN - Multi-Homed Ethernet Services over SRv6

## 16.1 Overview

EVPN (Ethernet VPN) represents a significant evolution in Layer 2 VPN services, bringing BGP-based route distribution to Ethernet multi-homing and MAC address learning across the VPN backbone. When EVPN operates over SRv6 transport, it combines the operational simplicity and scalability of BGP-controlled Ethernet services with the programmatic path control and traffic engineering capabilities of Segment Routing over IPv6. This chapter presents the EVPN architecture, its integration with SRv6, the Ethernet Segment (ES) concept for multi-homed connectivity, the Designated Forwarder (DF) election mechanism that prevents duplicate frame delivery, and the operational considerations for deploying EVPN over SRv6 underlays.

EVPN fundamentally changes how Ethernet services are delivered compared to traditional VPLS (Virtual Private LAN Service). Where VPLS relies on flood-and-learn for MAC address discovery and provides no built-in multi-homing mechanism, EVPN provides control-plane MAC learning via BGP, active-active multi-homing through the Ethernet Segment framework, and per-flow load balancing across redundant paths.

## 16.2 EVPN Architecture Fundamentals

### 16.2.1 EVPN Overview

EVPN operates as a BGP-based control plane for Ethernet services, where MAC addresses and other Ethernet state are distributed via BGP routes rather than learned through flooding. This control-plane learning approach provides significant advantages:

```
EVPN vs Traditional VPLS:
VPLS (flood-and-learn):
- MAC addresses learned from traffic (data plane)
- Flood for unknown DAMAC (broadcast replication)
- No native multi-homing mechanism
- Scaling challenges with many MAC addresses

EVPN (control-plane learning):
- MAC addresses distributed via BGP routes
- Optimal forwarding (no unnecessary flooding)
- Built-in multi-homing with DF election
- Better scaling for large MAC spaces
```

### 16.2.2 EVPN Route Types

EVPN defines multiple BGP route types for different functions:

```
EVPN Route Types:
Type 1: Ethernet Auto-Discovery (A-D) Route
- Distributes ES information per Ethernet Segment
- Indicates remote PEs connected to same ES
- Used for multi-homing and DF election

Type 2: MAC/IP Advertisement Route
- Carries MAC address and optional IP address
- Distributed when MAC is learned or updated
- Replaces flood-and-learn for known MACs

Type 3: Inclusive Multicast Ethernet Tag Route
- Creates multicast tunnel for broadcast/unknown unicast
- Establishes replication list for BUM traffic

Type 4: Ethernet Segment Route
- ES discovery and route target assignment
- Used for ESI labeling and multi-homing

Type 5: IP Prefix Route
- Distributes routes for IP prefixes attached to ES
- Alternative to Type 2 for pure L3 services
```

### 16.2.3 EVPN Instances and Ethernet Tags

EVPN introduces the concept of an EVPN Instance (EVI) and Ethernet Tag:

```
EVPN Instance (EVI):
- Represents a single EVPN domain (similar to VRF in L3VPN)
- Each EVI has a Route Distinguisher (RD)
- Route Targets (RT) control route import/export

Ethernet Tag:
- Identifies a broadcast domain within an EVI
- Can represent a VLAN, a VLAN bundle, or a VXLAN VNI
- Enables service differentiation within an EVI
```

## 16.3 Ethernet Segment Identifier (ESI)

### 16.3.1 ESI Concept

The Ethernet Segment Identifier (ESI) is a 10-byte value that uniquely identifies an Ethernet segment—a set of physical links forming a multi-homed connection between a Customer Edge (CE) device and one or more Provider Edge (PE) routers:

```
ESI Structure (10 bytes):
+---------------------------+
|        ESI Value          |
|  (operator-assigned or    |
|   auto-generated)        |
+---------------------------+
        10 bytes (80 bits)

ESI Types:
- Type 0: Auto-generated from LACP (link aggregation)
- Type 1: Force based (static Ethernet interface)
- Type 2-255: Reserved for future use
```

### 16.3.2 Multi-Homed CE Scenarios

ESI enables three multi-homing models:

```
Single-Homed CE:
CE --- PE
(No ESI needed; single attachment)

Dual-Homed CE (Active-Active):
CE ---+--- PE1 (both links forwarding)
      |
      +--- PE2 (both links forwarding)

Dual-Homed CE (Active-Standby):
CE ---+--- PE1 (primary link forwarding)
      |
      +--- PE2 (backup link, standby)
```

In active-active dual-homing (the most common EVPN deployment), both PE1 and PE2 forward traffic to/from the CE simultaneously, providing both redundancy and load balancing. The ESI ensures both PEs recognize they share the same customer attachment.

### 16.3.3 LACP Auto-Discovery

When the CE uses LACP (Link Aggregation Control Protocol) for link bundling, the ESI can be auto-generated from the LACP system ID:

```
LACP-Based ESI Generation:
CE (LACP System ID = 00:11:22:33:44:55)
    |
    +--- Port-channel1 --- PE1
    |
    +--- Port-channel1 --- PE2

ESI = 00:11:22:33:44:55:00:00:00:00
      (LACP System ID) + (zeroes)

Both PE1 and PE2 detect the same LACP system,
inferring they connect to the same CE's port-channel.
```

The PEs exchange Type 1 (Ethernet A-D) routes advertising their ESI, establishing the multi-homed relationship and enabling DF election.

## 16.4 Designated Forwarder (DF) Election

### 16.4.1 The DF Election Problem

In active-active multi-homed scenarios, a CE sends a broadcast/unknown unicast (BUM) frame that both PEs receive. Without coordination, both PEs would forward the frame into the EVPN domain, causing duplication. The Designated Forwarder (DF) election designates one PE as responsible for forwarding BUM traffic for each Ethernet segment:

```
DF Election Problem:
CE ---+--- PE1 (receives BUM from CE)
      |
      +--- PE2 (also receives BUM from CE)

Without DF:
- PE1 forwards BUM into EVPN
- PE2 forwards BUM into EVPN
- Duplicate frames delivered to remote PEs

With DF:
- DF (say, PE1) forwards BUM into EVPN
- PE2 drops BUM (non-DF)
- No duplication
```

### 16.4.2 DF Election Algorithm

The DF election uses a deterministic algorithm based on the ESI and PE router ID:

```
DF Election Algorithm:
1. Compute hash: hash(ESI, VLAN_ID) mod (number of PEs on ES)
2. Result determines which PE is DF
3. Algorithm ensures:
   - One DF per (ESI, Ethernet Tag) combination
   - Same DF election across all PEs (consistency)
   - Load balancing across PEs for different VLANs

Example:
ESI = 00:11:22:33:44:55:00:00:00:00
VLAN 100 → Hash → PE1 is DF
VLAN 200 → Hash → PE2 is DF

PE1: DF for VLAN 100, non-DF for VLAN 200
PE2: DF for VLAN 200, non-DF for VLAN 100
```

### 16.4.3 DF Election States

Each PE maintains DF and non-DF (backup DF) state for each Ethernet Tag on each ES:

```
DF Election States:
- DF: Forwarding BUM traffic for this ES/VLAN
- Backup DF (BDF): Standby DF, ready to take over if current DF fails
- Non-DF: Not participating in DF election for this ES/VLAN

DF Election Events:
- New PE joins ES: Re-election occurs, traffic may shift
- DF PE fails: BDF immediately becomes new DF
- ES configuration changes: Re-election
```

## 16.5 SRv6 EVPN Integration

### 16.5.1 EVPN over SRv6 Architecture

SRv6 provides the underlay transport for EVPN, replacing MPLS or VXLAN with IPv6 segment routing:

```
EVPN over SRv6 Architecture:
CE1 --- PE1 --- [SRv6 Domain] --- PE2 --- CE2

Control Plane:
- BGP EVPN routes advertised via IPv6 BGP sessions
- SRv6 SIDs included as BGP path attributes

Data Plane:
- EVPN traffic encapsulated in SRv6 (IPv6 + SRH)
- End.DX2 behavior delivers to Ethernet interfaces
- Multi-homing via ESI framework
```

### 16.5.2 SRv6 EVPN Behaviors

EVPN over SRv6 uses specific behaviors for Ethernet service delivery:

```
End.DX2 (Decapsulation to Ethernet):
- Used at egress PE to deliver frames to CE
- Strips outer IPv6/SRH
- Sends inner Ethernet frame to specified interface

End.DX2(vlan=<vlan-id>, if=<interface>) Behavior:
1. If SL > 0:
   a. SL = SL - 1
   b. DA = Segment[SL]
   c. Forward based on new DA
2. If SL == 0:
   a. Remove outer IPv6 header and SRH
   b. Extract inner Ethernet frame
   c. Apply VLAN tag if specified
   d. Send to interface
```

For EVPN multi-homing, the End.DX2 behavior is associated with the ESI and VLAN, ensuring proper forwarding behavior at multi-homed PEs.

### 16.5.3 SRv6 SID Allocation for EVPN

EVPN SIDs are allocated per Ethernet Segment and per MAC address:

```
SID Allocation for EVPN:
- Per-ES SID: Identifies the Ethernet Segment (End.DX2 SID)
- Per-MAC SID: Optional, for MAC-specific steering (End.DX2+MAC)

Example SID structure:
- ES SID: FC00:0:1:100::DX2 (End.DX2 at PE1 for ES-100)
- MAC SID: FC00:0:1:100::MAC1234 (End.DX2+MAC at PE1)
```

### 16.5.4 EVPN Route Extensions for SRv6

EVPN routes carry SRv6 SID information as BGP attributes:

```
EVPN Type 2 Route (MAC/IP Advertisement) with SRv6 SID:
- Route Distinguisher: RD for this EVI
- Ethernet Segment Identifier: ESI
- MAC Address: Customer's MAC
- IP Address: Optional (for ARP suppression)
- MPLS Label: (for MPLS EVPN)
- SRv6 SID: End.DX2 SID for this MAC (for SRv6 EVPN)
- SRv6 Locator: Which PE owns this SID
```

The receiving PE uses the SRv6 SID to construct the segment list for traffic destined to that MAC address.

## 16.6 MAC Learning in SRv6 EVPN

### 16.6.1 Control Plane MAC Learning

In SRv6 EVPN, MAC addresses are learned and distributed via BGP rather than flooding:

```
MAC Learning Flow:
1. CE1 sends ARP request or data frame to PE1
2. PE1 learns CE1's MAC and associates with ESI + VLAN
3. PE1 advertises Type 2 route (MAC/IP route) to all PEs via BGP:
   - MAC: 00:11:22:33:44:55
   - ESI: 00:11:22:33:44:55:00:00:00:00 (auto-generated)
   - SRv6 SID: FC00:0:1:100::DX2
   - RT: Export RT for this EVI
4. PE2 receives, imports into EVI
5. PE2 installs: MAC 00:11:22:33:44:55 → End.DX2 via SRv6 SID
6. Traffic destined to this MAC uses SRv6 path to PE1
```

### 16.6.2 Optimal Reverse Path

When CE2 sends traffic to CE1, the path is optimal because PE2 learns CE1's MAC with the SRv6 SID pointing directly to PE1:

```
Optimal Forwarding:
CE2 → PE2 → [SRv6 path to PE1] → CE1

Segment list computed based on End.DX2 SID at PE1.
No flooding, no learning frames—direct path.
```

### 16.6.3 Unknown Unicast Handling

Unicast frames with unknown destination MAC are handled via the Inclusive Multicast Ethernet Tag route:

```
Unknown Unicast Handling:
1. Frame arrives at PE1 with DA = unknown MAC
2. PE1 is DF for this ES/VLAN
3. PE1 replicates to all remote PEs via multicast tunnel
4. Remote PEs deliver to their CEs
5. If CE responds, MAC learned and future traffic is unicast
```

The multicast tunnel is established via the Type 3 (Inclusive Multicast) route, which creates replication entries at each PE.

## 16.7 Multi-Homing Operation

### 16.7.1 Active-Active Multi-Homing

In active-active multi-homed scenarios, both PEs forward traffic simultaneously:

```
Active-Active Multi-Homing:
CE (port-channel with LACP)
  |
  +--- PE1 (ESI = 00:11:22:33:44:55)
  |
  +--- PE2 (same ESI)

Both PE1 and PE2:
- Forward traffic to/from CE (load balanced)
- Exchange Type 1 A-D routes for ES
- Participate in DF election per VLAN

Load Balancing:
- Per-flow hash based on src/dst MAC, IP, ports
- CE uses LACP hashing to distribute across links
- Both PEs see different flows, forward independently
```

### 16.7.2 Failover Behavior

When one PE fails in an active-active setup:

```
Failover Sequence:
1. PE1 fails (physical or control-plane)
2. CE detects LACP timeout on PE1 links
3. CE shifts all traffic to PE2 (single-homed temporarily)
4. Remote PEs learn of PE1 failure via BGP withdrawal
5. Remote PEs update MAC routes to use PE2's SID
6. Traffic previously sent to PE1 now sent to PE2
7. DF election updates: PE2 becomes DF for all VLANs
```

### 16.7.3 BUM Traffic Forwarding

BUM (Broadcast, Unknown Unicast, Multicast) traffic uses DF election:

```
BUM Forwarding with DF:
CE sends broadcast frame:
  → PE1 (DF): Forwards to EVPN domain
  → PE2 (non-DF): Drops frame (does not forward)

Remote PE receives single copy from DF:
  → Delivers to its CE

Multicast replication at DF:
- DF creates replication list from Type 3 route
- Single copy sent to each remote PE
```

## 16.8 EVPN Route Target and VRF Integration

### 16.8.1 Route Target Design

EVPN uses Route Targets to control which PEs import which routes:

```
EVPN Route Target Design:
- Per-EVI RT: Each EVPN Instance has export/import RTs
- RT must be configured identically on PEs sharing the same EVPN
- Type 1/2/3/4 routes carry RT as extended community

Example:
EVI 100 (VLAN 100 customer):
  - RD: 100:1
  - RT: 65001:100 (import and export)
  - Both PE1 and PE2 configure RT 65001:100
```

### 16.8.2 EVPN to L3VPN Integration

EVPN can integrate with L3VPN for routed traffic:

```
EVPN + L3VPN Integration:
EVPN carries Layer 2 information (MAC addresses)
L3VPN carries Layer 3 information (IP routes)

Integration scenarios:
1. EVPN for L2 services, L3VPN for L3 services (separate)
2. EVPN with Type 5 routes (IP prefix) for L3 in EVPN
3. EVPN with gateway to L3VPN for inter-VPN routing
```

## 16.9 SRv6 EVPN vs MPLS EVPN

### 16.9.1 Underlay Comparison

| Aspect | MPLS EVPN | SRv6 EVPN |
|--------|-----------|-----------|
| Transport | MPLS LSPs | IPv6 + SRH |
| Signaling | LDP or RSVP-TE for LSPs | IGP for locators |
| SID Type | MPLS label (20 bits) | IPv6 SID (128 bits) |
| Path Control | RSVP-TE or per-LSP steering | SR Policy segment lists |
| Multi-homing | ESI with L2 FEC | ESI with SRv6 behaviors |
| BUM transport | Pseudowire or Ingress Replication | Multicast over SRv6 or IR |

### 16.9.2 Operational Comparison

| Aspect | MPLS EVPN | SRv6 EVPN |
|--------|-----------|-----------|
| Hardware | Label lookup in TCAM | IPv6 FIB (native) |
| OAM | LSP ping, VCCV | ICMPv6, SRv6 trace |
| Scaling | Label stack complexity | Single IPv6 header |
| IPv6 | Dual-stack or 6PE/6VPE | Native IPv6 underlay |
| Migration | From VPLS to EVPN | From VPLS to EVPN + SRv6 |

## 16.10 Packet Flow Examples

### 16.10.1 MAC Learning Flow

```
Topology:
CE1 (MAC: 00:11:22:33:44:55) --- PE1
                                    \
                                     [SRv6 Domain]
                                    /
CE2 ------------------------------ PE2

Step 1: CE1 sends frame to PE1
- Source MAC: 00:11:22:33:44:55
- DA: unknown (first frame)
- VLAN: 100

Step 2: PE1 learns MAC
- MAC 00:11:22:33:44:55 → ESI 100, VLAN 100
- SID allocated: FC00:0:1:100::DX2

Step 3: PE1 advertises Type 2 route
BGP EVPN Type 2:
  - RD: 100:1
  - ESI: 00:11:22:33:44:55:00:00:00:00
  - MAC: 00:11:22:33:44:55
  - SRv6 SID: FC00:0:1:100::DX2
  - RT: 65001:100

Step 4: PE2 imports and installs
- MAC 00:11:22:33:44:55 → SRv6 to PE1 (End.DX2 SID)
```

### 16.10.2 Data Forwarding Flow

```
Continuing from 16.10.1:

CE2 wants to send to MAC 00:11:22:33:44:55

Step 1: CE2 sends frame
- Src MAC: CE2's MAC
- Dst MAC: 00:11:22:33:44:55

Step 2: PE2 receives, lookup MAC table
- 00:11:22:33:44:55 → SRv6 SID FC00:0:1:100::DX2

Step 3: PE2 encapsulates for SRv6 transport
- Outer IPv6: Src=PE2-locator, Dst=FC00:0:1:100::DX2
- SRH: SL=0
- Inner: Original Ethernet frame

Step 4: Transit routers forward to PE1

Step 5: PE1 receives, DA = End.DX2 SID
- PE1 executes End.DX2(if=gi0/0)
- Decapsulate, send to CE1
```

## 16.11 Configuration Overview

### 16.11.1 PE Configuration Elements

Key configuration elements for SRv6 EVPN:

```
SRv6 EVPN Configuration (IOS-XR style):
1. Enable SRv6
   segment-routing srv6
     locators
       locator LOC1
         48-bit prefix FC00:0:1::/48
         microSID

2. EVPN Instance
   evpn
     instance EVI-100
       rd 100:1
       route-target both 65001:100
       ethernet-segment
         identifier type 0 00.1122.3344.5500.0000

3. Interface to CE
   interface GigabitEthernet0/0
     encapsulation dot1q 100
     evpn
       instance EVI-100
         ethernet-segment
           identifier type 0 00.1122.3344.5500.0000
```

### 16.11.2 Verification Commands

```
show evpn ethernet-segment:
- ESI values and status
- DF election state per ES
- Remote PEs on each ES

show evpn mac:
- MAC addresses learned locally and remotely
- Associated ESI and VLAN
- SRv6 SID for remote MACs

show srv6 sid:
- All allocated SIDs including EVPN End.DX2
- SID to behavior mapping
```

## 16.12 Summary

EVPN over SRv6 delivers multi-homed Ethernet services with the scalability and control of BGP learning:

- **Control Plane Learning**: MAC addresses and Ethernet Segment membership are distributed via BGP Type 1-5 routes, eliminating flood-and-learn and enabling optimal forwarding.

- **Ethernet Segment Identifier (ESI)**: The 10-byte ESI uniquely identifies multi-homed Ethernet segments, enabling PEs to recognize shared attachments and coordinate forwarding.

- **Designated Forwarder Election**: The DF algorithm designates one PE per (ESI, VLAN) as responsible for BUM forwarding, preventing duplicate frame delivery in active-active multi-homing.

- **SRv6 Transport**: EVPN routes carry SRv6 SID information, and the End.DX2 behavior delivers frames to Ethernet interfaces over the SRv6 underlay.

- **Active-Active Multi-Homing**: Both PEs forward simultaneously for a dual-homed CE, with per-flow load balancing and immediate failover on PE failure.

- **Comparison to MPLS EVPN**: SRv6 EVPN provides native IPv6 underlay, simplified hardware (IPv6 FIB vs. label lookup), and programmable path control, while maintaining feature parity with MPLS EVPN.

EVPN sets the foundation for modern Ethernet service delivery, while VPLS (Chapter 17) addresses legacy LAN emulation requirements and IOAM (Chapter 18) provides the operational visibility needed to manage these services at scale.

---

**References**

- RFC 7209: Requirements for Ethernet VPN (EVPN)
- RFC 7432: BGP EVPN (comprehensive EVPN specification)
- RFC 7626: BGP EVPN Reverse Path Labeling
- RFC 8214: Virtual Private Wire Service Support in EVPN
- RFC 8365: A Network Virtualization Overlay Solution Using EVPN
- RFC 8986: SRv6 Network Programming (End.DX2 behavior)
- RFC 8754: IPv6 Segment Routing Header (SRH)
- IETF draft: EVPN Integration with SRv6
- IETF draft: SRv6 EVPN Use Cases and Deployment
- IEEE 802.1AX: Link Aggregation (LACP)
