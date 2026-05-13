# Chapter 23: SRv6 SD-WAN - Architecture, Integration, and Enterprise Deployment

## 23.1 Overview

SD-WAN (Software-Defined Wide Area Network) has transformed enterprise connectivity by decoupling control plane intelligence from hardware, enabling application-aware routing, centralized policy management, and dynamic path selection across multiple underlay links. Traditional SD-WAN solutions rely on IPsec tunnels, VxLAN encapsulation, or MPLS LSPs to carry customer traffic across the WAN. SRv6 brings source routing, network programmability, and tight TE integration to SD-WAN architectures, enabling per-application path selection with explicit segment lists, seamless underlay optimization, and cloud-native integration.

This chapter presents SRv6 SD-WAN architecture: how SRv6 integrates with SD-WAN control and data planes, CPE (Customer Premises Equipment) design with SRv6, overlay-underlay协同 with cloud security service integration (Zscaler, Palo Alto), SRv6-based service chaining, and deployment considerations for enterprise multi-branch networks.

## 23.2 SD-WAN Architecture Fundamentals

### 23.2.1 Traditional SD-WAN Components

A conventional SD-WAN consists of:

```
Traditional SD-WAN Architecture:

[Branch-1 CPE] ---- Internet ---- [Branch-2 CPE]
      |                              |
      |   Underlay: Internet/MPLS    |
      v                              v
[SD-WAN Controller] <---- HTTPS ---- [SD-WAN Controller]
      |
      v
[Policy Engine]

Components:
1. CPE (Customer Premises Equipment):
   - vEdge, Silver Peak, VeloCloud, Fortinet
   - WAN interface (Internet + MPLS)
   - Overlay tunnel establishment
   - Local policy enforcement

2. SD-WAN Controller:
   - vBond/vSmart (Velocloud), Arcosan (Fortinet)
   - Centralized control plane
   - Policy distribution
   - Tunnel orchestration

3. Underlay Network:
   - Internet broadband
   - MPLS VPN
   - 4G/5G LTE backup

4. Overlay Network:
   - IPsec tunnels (DIA to branch)
   - VxLAN encapsulation
   - Full mesh or hub-spoke
```

### 23.2.2 SRv6 SD-WAN Advantages

SRv6 transforms SD-WAN by providing explicit path control at the network layer:

```
SRv6 SD-WAN Value Proposition:

1. Source Routing:
   - Controller computes exact path
   - SID list encodes path segments
   - CPE simply follows segment list
   - No per-tunnel state on transit nodes

2. Programmable Path Selection:
   - Per-application SID policies
   - Latency-sensitive: End.DT6 + delay constraint
   - Bulk data: bandwidth-optimized path
   - Compliance: geo-fenced segment list

3. Cloud-Native Integration:
   - Direct SRv6 to cloud edge (AWS TGW, Azure VWAN)
   - No IPsec overhead at cloud
   - Native IPv6 path to cloud services

4. Unified Underlay:
   - Single SRv6 domain across WAN + Cloud
   - No overlay/underlay translation
   - Consistent TE across entire path

Traditional vs SRv6 SD-WAN:
| Feature              | Traditional SD-WAN   | SRv6 SD-WAN          |
|---------------------|----------------------|----------------------|
| Path Control        | Tunnel-level        | Segment-level        |
| Encapsulation       | IPsec/VxLAN          | SRv6 (native IPv6)   |
| Cloud Integration   | IPsec VPN gateway    | Direct SRv6          |
| Transit State       | Per-tunnel           | Per-SID (shared)     |
| TE Granularity       | Per-tunnel           | Per-flow/packet      |
| Controller          | Proprietary          | PCE-based standard   |
```

### 23.2.3 SRv6 SD-WAN Reference Architecture

```
SRv6 SD-WAN Reference Architecture:

                    +------------------+
                    |   SD-WAN         |
                    |   Controller     |
                    |   (PCE + Policy) |
                    +--------+---------+
                             |
              BGP SRv6       | REST/gRPC
              Policy         | Telemetry
              Distribution   |
                             v
+--------+   +--------+  +--------+  +--------+  +--------+
|Branch-1|   |Branch-2|  |Branch-3|  |  DC-1  |  | Cloud- |
|CPE     |   |CPE     |  |CPE     |  |Edge    |  | Edge   |
+--------+   +--------+  +--------+  +--------+  +--------+
   |             |            |           |           |
   |  SRv6       |  SRv6      |  SRv6     |  SRv6    |
   |  Overlay    |  Overlay   |  Overlay  |  Overlay |
   +-------------+------------+-----------+----------+
                SRv6 Underlay Network (IPv6 Fabric)
                     (MPLS/Internet Underlay)

Traffic Flow Example:
App: Zoom (latency-sensitive)
Path: Branch-1 -> Core-1 -> Delay-Constrained-Node -> DC-1
SID List: <Node-SID-Branch-1, Delay-Constrained-SID, Node-SID-DC1>
```

## 23.3 SRv6 SD-WAN Control Plane

### 23.3.1 Controller Architecture

The SD-WAN controller in SRv6 architecture performs PCE (Path Computation Element) functions:

```
SRv6 SD-WAN Controller Components:

1. PCE (Path Computation Element):
   - Path computation with SRv6 constraints
   - SID list generation
   - Optimization objective (latency, bandwidth, affinity)
   - BGP-LS or IGP topology subscription

2. Policy Engine:
   - Application-to-SID mapping
   - SLA policy definition
   - Security policy integration
   - Compliance rules

3. Telemetry Collector:
   - Network-wide traffic matrix
   - Per-branch utilization
   - Latency/loss measurements
   - Anomaly detection

4. CPE Orchestrator:
   - Zero-touch provisioning
   - SRv6 SID allocation
   - Policy distribution
   - Firmware management

Communication:
[Controller] <---BGP-LS---> [Underlay IGP]
[Controller] <---gRPC---> [CPE Agents]
[Controller] <---REST---> [NMS / OSS]
```

### 23.3.2 BGP SRv6 for SD-WAN Control Plane

BGP carries SRv6 VPN routes and SD-WAN policy information:

```
BGP SRv6 SD-WAN Control Plane:

VRF Route with SRv6 SID:
BGP Route (IPv4/IPv6 VPN):
  Prefix: 10.1.0.0/16 (Branch-1 LAN)
  RD: 65001:100
  RT: 65001:100
  SRv6 L3VPN SID: uDT4 (VRF instance)
  SRv6 Path: <End.DT4@Branch-1>

Route Propagation:
1. Branch-1 CPE announces:
   - Local LAN prefixes
   - SRv6 L3VPN SID (End.DT4)
   - Path attributes (delay, jitter, bandwidth)

2. Controller receives via BGP:
   - Installs route in global table
   - Computes SRv6 policy
   - Distributes SID list

3. Branch-2 CPE receives:
   - Route to 10.1.0.0/16 via SRv6
   - SID list: <..., Branch-1-End.DT4>
   - Installs in local VRF

BGP Address Families:
- AFI/SAFI 1/1 (IPv4 unicast) - underlay
- AFI/SAFI 2/1 (IPv6 unicast) - underlay
- AFI/SAFI 1/132 (IPv4 SRv6 VPN) - overlay
- AFI/SAFI 2/132 (IPv6 SRv6 VPN) - overlay
- AFI/SAFI 1/140 (BGP-LS) - topology
```

### 23.3.3 Policy Distribution

The controller distributes SRv6 policies to CPEs:

```
SRv6 Policy Distribution:

Policy Structure:
SR Policy:
  Name: "Zoom-Low-Latency"
  Color: 100 (DSCP EF marker)
  Preference: 100

  Candidate Path 1:
    Protocol-Origin: PCE
    Preference: 100
    Metric-Type: TE
    Explicit SID List:
      - End.X@Branch-1 (via MPLS-A)
      - End.DX6@MPLS-DC1 (cross-connect)
      - End.DT6@DC1 (VRF terminate)

    Constraints:
      - Max latency: 50ms
      - Min bandwidth: 10Mbps
      - Affinity: avoid "congested"

Distribution via gRPC:
[Controller] --gRPC--> [Branch CPE]
  Policy payload (protobuf):
  - SR policy name
  - SID list (encoded)
  - Steering rules (DSCP -> policy)
  - Validity timer

[Controller] --BGP SR Policy--> [PE routers]
  BGP SR Policy NLRI:
  - Policy name
  - Color (DSCP mapping)
  - SID list
  - Preference
```

## 23.4 SRv6 SD-WAN Data Plane

### 23.4.1 CPE Data Plane Architecture

SRv6-enabled CPE processes packets as follows:

```
SRv6 CPE Data Plane:

Ingress (WAN -> LAN):
1. Decapsulate outer IPv6 / SRH
2. Read segment list (remaining segments)
3. If segments remain:
   - Forward to next segment (End.X behavior)
   - Decrement Segments Left
   - Re-encapsulate with updated SRH
4. If last segment (Segments Left = 0):
   - Perform final behavior (End.DT4/End.DT6)
   - Forward to local LAN

Egress (LAN -> WAN):
1. Ingress LAN interface
2. VRF lookup -> route
3. Match SLA policy (DSCP -> SR Policy)
4. Push SRv6 header with SID list
5. Forward to underlay

Packet Transformation (Branch-1 to DC-1):

Original packet:
[Ethernet][IPv4: 192.168.1.10 -> 10.100.1.20][TCP]

At Branch-1 CPE (egress):
[IPv6: Branch-1][SRH: [End.X@MPLS-A, End.DT6@DC1]][IPv4][TCP]
   ^-- SRv6 encapsulation

At MPLS-A (transit, End.X):
- IPv6 DA = MPLS-A (first SID)
- Process End.X: forward to MPLS-A -> DC1
- Update SL, advance pointer

At DC1 (final, End.DT6):
- IPv6 DA = End.DT6@DC1
- Perform End.DT6: decapsulate, lookup VRF
- Deliver IPv4 packet to DC1 LAN
```

### 23.4.2 SRv6 uSID in SD-WAN

The compressed uSID format is particularly valuable in SD-WAN:

```
uSID Format for SD-WAN:

uSID Block: FC00::/8 (shared with China/U-L bloco)
uSID for SD-WAN:
- uN (Node): <uN-Branch-1>, <uN-Branch-2>, <uN-DC1>
- uA (Anycast): <uA-Region-A>, <uA-Region-B>
- uDT (Dual Transit): <uDT4@VRF-A>, <uDT6@VRF-A>
- uDX (Dual Cross-connect): <uDX6@MPLS-A>, <uDX4@Internet>

uSID Carrier Packet:
IPv6 Destination: FC00:0:1::1 (uN-Branch-1)
                 FC00:0:1::2 (uN-Branch-2)
                 FC00:0:2::1 (uN-DC1)
                 FC00:0:3::1 (uN-MPLS-A)

Example SID List (uSID compressed):
Full SID list:   <2001:db8::1:0:0:1, 2001:db8::2:0:0:1>
uSID list:       <FC00:0:1::, FC00:0:2::>

Branch to Cloud uSID Path:
< uN-Branch-1, uN-MPLS-A, uDX6@AWS-TGW, uN-AWS-Edge >
= FC00:0:1:: : FC00:0:3:: : FCBB:0:4:: : FCCC:0:5::

Advantage:
- 128-bit SID fits in single IPv6 address
- No SRH needed for simple paths (uSID in DA only)
- Hardware-friendly (TCAM match on /32 uSID prefix)
```

### 23.4.3 Hybrid SD-WAN (SRv6 + Legacy)

Most deployments run SRv6 alongside existing SD-WAN:

```
Hybrid SD-WAN Architecture:

+------[Legacy SD-WAN Tunnel]-----> Internet
|                                        |
|  SRv6 Domain                           | IPsec
v                                        v
[Branch CPE] -------- SRv6 ------------ [Hub PE]
  |                                          |
  |  Dual-stack CPE                          |
  |  - SRv6 for new apps                     |
  |  - Legacy tunnel for brownfield          |
  |                                          |
  +-----> Local switching <----------------+

Traffic Classification:
1. New cloud-native apps -> SRv6 path
2. Legacy VPN apps -> Existing tunnel
3. Internet break-out -> Local NAT / Security service
4. Latency-sensitive -> TI-LFA protected SRv6

Migration Strategy:
Phase 1: Deploy SRv6 on new CPE hardware
Phase 2: Enable SRv6 tunnel to cloud edges
Phase 3: Migrate apps to SRv6 steering
Phase 4: Decommission legacy tunnels
```

## 23.5 Cloud Security Service Integration

### 23.5.1 Zscaler Integration with SRv6

Zscaler (SSE/SASE platform) can integrate with SRv6 SD-WAN:

```
SRv6 + Zscaler Architecture:

Option A: Direct SRv6 to Zscaler PoP:

[Branch CPE] --SRv6--> [Zscaler PoP] --HTTP/S--> [Internet]
                    |
                    v
            Zscaler SID: <End.DX6@Zscaler-PoP>

SRv6 SID List:
< uN-Branch-1, uDX6@Zscaler-NYC, uN-Zscaler-Exit >
= FC00:0:1:: : FC00:0:ZS:: : FC00:0:ZSE::

Zscaler Processing:
1. Packet arrives at Zscaler PoP (SRv6 decapsulated)
2. Full SSL inspection
3. Policy enforcement
4. Re-encapsulate with return SRv6 SID list
5. Forward to destination

Option B:hairpin through local security:

[Branch CPE] --SRv6--> [Local Zscaler Connector]
                         |
                         v
                    [Zscaler Cloud]

SRv6 to connector:
SID List: <End.DX6@Zscaler-Connector>
```

### 23.5.2 Palo Alto Networks Prisma Access

Palo Alto Prisma Access (SASE) integration:

```
Palo Alto Prisma Access + SRv6:

Prisma Access Components:
- GlobalConnect: cloud-based security
- Remote Networks: branch connectivity
- Mobile Users: end-user clients

SRv6 Path to Prisma Access:
[Branch CPE] --SRv6--> [Prisma Access Gateway]
                        |
                        v
              +-------------------+
              | URL Filtering     |
              | SSL Decryption    |
              | Threat Prevention |
              | DNS Security      |
              +-------------------+

SID List for Prisma:
< End.DX6@PrismaAccess-GW, End.DT6@Service-VRF>

Prisma Access BGP Peer:
- Branch CPE peers with Prisma via BGP SRv6
- Prisma announces: 0.0.0.0/0 (Internet route)
- Branch announces: 10.0.0.0/8 (local LAN)
- Return traffic: SRv6 encapsulated to branch
```

### 23.5.3 Service Function Chaining with SRv6

SRv6 enables flexible service chaining without tunnels:

```
SRv6 Service Function Chaining (SFC):

Service Chain: Firewall -> Proxy -> Intrusion Detection

Traditional SFC:
[Packet] -> [GRE encapsulation] -> Firewall -> Proxy -> IDS -> [GRE decap] -> [Packet]

SRv6 SFC:
[Packet] -> [SRH: <End.DX6@FW, End.DX6@Proxy, End.DX6@IDS>] -> [Packet]

Each service node:
- Reads next SID from SRH
- Performs service function
- Forwards with SRH (or strips if last)

Example SID List for Security Chain:
< uN-Branch-1,
  uDX6@Firewall-NYC,
  uDX6@Proxy-NYC,
  uDX6@IDS-NYC,
  uN-DC1 >

Segment List Encoding:
FC00:0:1::    (uN-Branch-1)
FC00:0:FW::   (uDX6@Firewall)
FC00:0:PR::   (uDX6@Proxy)
FC00:0:IDS::  (uDX6@IDS)
FC00:0:2::    (uN-DC1)

Benefits over Traditional SFC:
1. No GRE/VxLAN overhead
2. Controller programs entire chain
3. Symmetric chains (return path reversed)
4. Per-flow chain selection
5. TI-LFA protection for chain segments
```

## 23.6 Branch WAN Architecture

### 23.6.1 Multi-Link Branch

Modern branches typically have multiple WAN links:

```
Multi-Link Branch Architecture:

[Branch CPE]
  |
  +--- Link-1: MPLS (primary, low latency)
  +--- Link-2: Internet DIA (backup)
  +--- Link-3: 5G LTE (emergency)

SRv6 Policy per Link:
1. MPLS Policy (Color: 100, Low Latency):
   SID List: <End.X@MPLS-Peer, End.DT6@DC1>
   Metric: latency < 10ms

2. Internet Policy (Color: 200, High Bandwidth):
   SID List: <End.DX6@Internet-GW, End.DT6@DC1>
   Metric: bandwidth > 100Mbps

3. LTE Policy (Color: 300, Best Effort):
   SID List: <End.DX6@LTE-APN, End.DT6@DC1>
   Metric: best-effort

Active-Active Configuration:
- VoIP: Link-1 (MPLS)
- Video Conferencing: Link-1
- File Transfer: Link-2 (Internet)
- IoT Devices: Link-3 (LTE)

Dynamic Failover:
1. MPLS link failure detected (BFD down)
2. Controller computes new policy via Internet
3. Traffic shifted to Link-2 automatically
4. TI-LFA provides sub-50ms initial protection
```

### 23.6.2 Zero-Touch Provisioning

SRv6 enables simplified branch deployment:

```
SRv6 ZTP Flow:

Day 0 - Branch Deployment:
1. Unbox CPE, connect WAN links
2. CPE boots, DHCPv6 on WAN interface
3. CPE contacts bootstrap server (DNS discovery)
4. Controller pushes:
   - SRv6 locator (uSID block allocation)
   - Initial SID list (bootstrap policy)
   - Device certificate (mutual TLS)

Bootstrap SID List:
< End.DT6@Controller, End.DX6@Hub >
= Controller provides initial connectivity

Day N - Policy Activation:
1. Controller discovers topology (BGP-LS)
2. Compute optimal SID lists for apps
3. Push SRv6 policies via gRPC
4. CPE installs policies, traffic flows

Certificate-Based Security:
- CPE has manufacturing certificate (Mfg Cert)
- Exchanges with controller via EST
- Controller issues operational certificate
- All SID list distribution signed

Management Channel:
- Out-of-band: separate management VRF
- In-band: SRv6 encapsulated management
- Protocol: gRPC/TLS, NETCONF/YANG
```

### 23.6.3 Centralized vs Distributed Control

SD-WAN control can be centralized (traditional) or distributed (full-mesh):

```
Control Plane Models:

Centralized Control (Traditional SD-WAN):
[CPE-1] <------ controller ------> [CPE-2]
         |                           |
         v                           v
    All policies              All policies
    computed at              computed at
    controller               controller

SRv6 Enhancement:
- Controller = PCE
- SID lists computed centrally
- CPE just executes segment list
- Scales better (no per-flow state at controller)

Distributed Control (SRv6 + IGP):
[CPE-1] <--- IGP ---> [CPE-2]
         |           |
         v           v
    Local policy    Local policy
    Local SRv6      Local SRv6

SRv6 Enhancement:
- IGP handles path computation
- End.X SID per link
- No controller needed for basic connectivity
- Controller adds TE policy on top

Hybrid (Recommended):
- Local IGP for underlay reachability
- Central PCE for TE policies
- BGP for overlay VPN routes
- gRPC for policy distribution

[PCE] <--BGP-LS--> [Underlay IGP]
   |
   v
[CPE-1] <---- gRPC ----> [CPE-2]
  |                        |
  +------ BGP SRv6 --------+
```

## 23.7 Enterprise Deployment Considerations

### 23.7.1 Migration from Legacy SD-WAN

Migrating from traditional SD-WAN to SRv6 SD-WAN:

```
Migration Phases:

Phase 1: Parallel Run (Weeks 1-4)
- Deploy SRv6-capable CPE alongside existing
- Establish SRv6 control channel
- Run production traffic on both simultaneously
- Validate SLAs match or exceed

Phase 2: Traffic Migration (Weeks 5-8)
- Move latency-sensitive apps to SRv6
- Validate path performance
- Monitor KPIs (latency, jitter, loss)
- Iteratively increase SRv6 traffic %

Phase 3: Legacy Decommission (Weeks 9-12)
- Reduce legacy tunnel capacity
- Maintain for fallback
- Full SRv6 cutover
- Remove legacy hardware

Validation Checklist:
[x] End-to-end SRv6 connectivity
[x] Latency within SLA
[x] TI-LFA failover < 50ms
[x] Policy steering working
[x] Telemetry reporting accurate
[x] Controller redundancy verified
```

### 23.7.2 Multi-Region Enterprise

Global enterprises need multi-region SRv6 SD-WAN:

```
Multi-Region SRv6 Architecture:

Region Americas:
  [Branch-US-1] --SRv6--> [US Hub] --SRv6--> [AWS us-east-1]
  [Branch-US-2] --SRv6--> [US Hub]

Region EMEA:
  [Branch-UK-1] --SRv6--> [EU Hub] --SRv6--> [Azure westeurope]
  [Branch-DE-1] --SRv6--> [EU Hub]

Region APAC:
  [Branch-SG-1] --SRv6--> [APAC Hub] --SRv6--> [GCP asia-east-1]
  [Branch-AU-1] --SRv6--> [APAC Hub]

Inter-Region Path:
Region-US -> Transatlantic SRv6 -> Region-EU
SID List: <End.DX6@Transatlantic-Link, End.DX6@EU-Hub>

Regional Controller Hierarchy:
[Global Controller] --> [Regional Controller-US]
                      --> [Regional Controller-EU]
                      --> [Regional Controller-APAC]

Global Policy:
- Cross-region SLA
- Data residency compliance
- DR site selection
```

### 23.7.3 Performance and Scale

SRv6 SD-WAN performance considerations:

```
Performance Characteristics:

SRv6 Overhead:
- SRH: 40 bytes (fixed) + 16 bytes per segment
- uSID: 0 bytes overhead (SID in IPv6 DA)
- Typical packet: +8 to +56 bytes vs native IPv6

MTU Considerations:
- Underlay MTU: 1500 bytes typical
- SRv6 overhead: 40-72 bytes
- Payload: 1428-1460 bytes (acceptable)
- For 1500 MTU link: fragment or set DF

Hardware Support:
- Cisco 4000/5000 series: Full SRv6
- Juniper ACX/RMX series: Full SRv6
- VeloCloud (VMware): SRv6 supported
- Silver Peak (Aruba): SRv6 in progress

Scale Numbers (per CPE):
- SID entries: 10,000-100,000
- Active flows: 100,000-1,000,000
- Policies: 100-10,000
- Throughput: 1-10 Gbps (hardware)

Software CPE (vCPE):
- Lower scale (10x vs hardware)
- Suitable for small branches
- NFV-hosted SRv6
```

## 23.8 Summary

SRv6 transforms SD-WAN by bringing source routing, network programmability, and standards-based TE to enterprise connectivity. Key takeaways:

```
Chapter 23 Summary:

SRv6 SD-WAN Benefits:
- Source routing: controller-computed exact paths
- uSID compression: efficient SID encoding
- Native IPv6: direct cloud integration
- Per-flow steering: application-aware routing
- TI-LFA: sub-50ms protection

Control Plane:
- PCE-based controller computes SID lists
- BGP SRv6 for route and policy distribution
- gRPC for real-time policy updates
- BGP-LS for topology visibility

Data Plane:
- CPE pushes SRv6 header for egress traffic
- Transit nodes process SID list (End.X)
- Final node terminates SRv6 (End.DT4/End.DT6)
- uSID enables compression for simple paths

Cloud Integration:
- Direct SRv6 to AWS TGW, Azure VWAN, GCP
- Zscaler/Palo Alto via SRv6 service chaining
- No IPsec overhead at cloud
- Consistent policy across hybrid cloud

Deployment:
- Hybrid with legacy SD-WAN during migration
- Multi-link active-active with per-link policies
- Zero-touch provisioning with certificates
- Global multi-region hierarchy
```

---

## References

- IETF RFC 8986: Segment Routing over IPv6 (SRv6) Network Programming
- IETF RFC 8754: IPv6 Segment Routing Header (SRH)
- IEEE 802.1Q: Service Function Chaining
- MEF 70: SD-WAN Service Attributes and Service Framework
