# Chapter 25: Huawei Cloud SRv6 - Cloud Backbone, iMaster NCE, and Campus

## 25.1 Overview

Huawei Cloud (华为云) has deployed SRv6 as a foundational technology across its cloud backbone, enterprise connectivity services, and campus networking solutions. Huawei's SRv6 implementation leverages its extensive experience in carrier networking (learned from its Huawei Enterprise and Carrier businesses) and integrates deeply with the iMaster NCE (Network Cloud Engine) management platform. Huawei Cloud's SRv6 supports ultra-low latency connectivity, deterministic network performance, and seamless integration with enterprise campus networks.

This chapter presents Huawei Cloud SRv6 architecture: the cloud backbone design, iMaster NCE controller integration, CloudWAN service, Huawei Cloud Campus (CloudCampus) solution, and enterprise connectivity options including CloudConnect and Lean over.

## 25.2 Huawei Cloud Network Architecture

### 25.2.1 Huawei Cloud Global Infrastructure

Huawei Cloud operates a rapidly expanding global network:

```
Huawei Cloud Global Infrastructure:

Regions (as of 2024):
- China: 10+ regions (cn-east-1, cn-south-1, cn-north-1, etc.)
- Asia Pacific: 8 regions (sg, th, my, ph, id, kr, jp, au)
- Europe: 4 regions (de, uk, fr, ie)
- Latin America: 3 regions (br, mx, cl)
- Middle East: 2 regions (ae, za)

Availability Zones:
- 60+ availability zones globally
- 3+ AZs per region
- Full mesh within region

Network Services:
- Cloud WAN: enterprise connectivity
- CloudConnect: DC interconnects
- CloudCampus: campus networking
- CloudPhone: cloud phone
- CDN Pro: content delivery

Backbone Capacity:
- 100+ Tbps global bandwidth
- 100G links between AZs
- Direct peering with 3000+ ISPs
```

### 25.2.2 Huawei's SRv6 Heritage

Huawei pioneered SRv6 development:

```
Huawei SRv6 History:

Pioneering Role:
- First RFC 8402 (IGP in SR) contributor
- First RFC 8754 (SRH) implementation
- First RFC 8986 (Network Programming) vendor
- Active in IETF SPRING and SRv6 working groups

Huawei's SRv6 Product Lines:
1. NetEngine Router Series:
   - NE40E: carrier edge
   - NE8000: cloud backbone
   - CloudEngine: data center + campus

2. AC-Controller (iMaster NCE):
   - Campus iMaster NCE-Campus
   - WAN iMaster NCE-WAN
   - Data Center iMaster NCE-Fabric

3. Cloud Services:
   - Huawei Cloud WAN
   - CloudConnect
   - CloudCampus

Huawei SRv6 Differentiators:
- Hardware: ASIC-native SRv6 (T-bit capacity)
- Software: Huawei VRP OS (decades of refinement)
- Standards: active IETF contributor
- Integration: end-to-end Huawei stack
```

### 25.2.3 Huawei Cloud SRv6 Architecture

```
Huawei Cloud SRv6 Architecture:

Layer 1: Access Layer
[Enterprise CPE] --SRv6/IPsec--> [Huawei Cloud Edge PoP]
                                      |
                                      v
                               +--------------+
                               | CloudEdge     |
                               | (NE8000 series)|
                               +--------------+

Layer 2: Regional Network
[Edge PoP] --SRv6--> [Regional Router] --> [AZ VPC]
                     |
                     v
              +-------------+
              |可用区 A      |
              +-------------+
              |可用区 B      |
              +-------------+
              |可用区 C      |
              +-------------+

Layer 3: Cloud Backbone
[Region A] --SRv6--> [Inter-Region Backbone] --> [Region B]
                   |
                   v
            +-------------+
            | Global Gateway|
            +-------------+

Huawei Cloud SID Format:
Locator: <Region>.<PoP>.<Node>
Function: End.DT4, End.DT6, End.DX4, End.DX6

Example SID:
Region: cn-east-1, PoP: SHA-01, Node: R1
Locator: fd00:0:1::/48
End.DT4: fd00:0:1:0:0:0:0:1
```

## 25.3 Huawei Cloud Backbone

### 25.3.1 Cloud Backbone Architecture

Huawei Cloud's backbone uses SRv6 extensively:

```
Huawei Cloud Backbone Design:

Regional Backbone:
- CloudEngine 16800 series as core
- 100G/400G ports per router
- Full mesh between AZs
- SRv6 + MPLS dual-stack

Inter-Region Backbone:
- Dedicated backbone links
- Submarine cable investments
- Regional hubs (Hong Kong, Singapore, Frankfurt)
- Direct routes to minimize hops

Backbone Features:
1. Deterministic Latency:
   - Fixed latency per hop (10us)
   - Path with minimal hops
   - No congestion (oversubscription < 50%)

2. High Availability:
   - 3+ disjoint paths per destination
   - TI-LFA protection
   - Seamless restoration

3. Traffic Engineering:
   - Per-flow load balancing
   - Bandwidth-aware path selection
   - FlexAlgo support

4. Security:
   - MACsec on backbone links
   - Segment-level encryption option
   - Source address validation

SRv6 Backbone SID:
- Node SID: router loopback IPv6
- Adj SID: physical link
- Anycast SID: service gateway
- uSID: compressed paths (uN, uA, uDT)
```

### 25.3.2 Path Computation Engine

Huawei Cloud uses PCE for path computation:

```
Huawei PCE Architecture:

PCE Components:
1. Global PCE:
   - Inter-region path computation
   - Global topology DB
   - Cross-domain policies

2. Regional PCE:
   - Intra-region paths
   - Local optimization
   -故障恢复

3. Domain PCE:
   - Per-router local computation
   - TI-LFA backup paths
   - ECMP handling

PCE Protocol:
- PCEP (RFC 5440) for path computation
- BGP-LS for topology distribution
- gRPC for telemetry

Path Computation Request:
From: cn-east-1 VPC
To: de-west-1 VPC
Constraint: latency < 200ms

PCE Computation:
1. Global PCE receives
2. Queries BGP-LS topology:
   - cn-east-1 region
   - International gateway (HK/SG)
   - de-west-1 region
3. Applies constraints
4. Computes SID list

Result SID List:
< End.DT4@SHA-VPC,          # Local VPC
  End.DX6@SHA-GW,           # Shanghai gateway
  End.DX6@HK-Intl-GW,       # Hong Kong international
  End.DX6@FRA-Intl-GW,      # Frankfurt international
  End.DX6@DUS-GW,           # Dusseldorf gateway
  End.DT4@DUS-VPC >         # Remote VPC

TI-LFA Backup Path:
< End.DT4@SHA-VPC,
  End.DX6@NRT-GW,           # Tokyo as backup
  End.DX6@LAX-GW,           # Los Angeles
  End.DX6@FRA-Intl-GW,
  End.DX6@DUS-GW,
  End.DT4@DUS-VPC >
```

### 25.3.3 Multi-Layer Traffic Engineering

Huawei Cloud implements TE at multiple layers:

```
Multi-Layer TE Architecture:

Layer 1: Network TE
- IGP metrics (delay, bandwidth)
- FlexAlgo definitions
- SR Policy computation

Layer 2: Service TE
- Per-VPC bandwidth guarantees
- DSCP-to-SR policy mapping
- Application-aware steering

Layer 3: Application TE
- Database: low latency
- Video: high bandwidth
- IoT: edge-optimized

Huawei TE Components:
1. iMaster NCE-WAN:
   - Centralized TE controller
   - Policy computation
   - Real-time monitoring

2. CloudEngine OS:
   - Distributed TE enforcement
   - Per-packet load balancing
   - Queue management

3. Agile Controller:
   - Application policy
   - SLA enforcement
   - Analytics

Example TE Policy:
Policy: "Database-Primary"
  Color: 200 (critical)
  Preference: 100

  Candidate Path 1:
    SID: <End.DX6@SHA-DC1, End.DX6@SHA-DC2, End.DT6@Service>
    Metric: latency 2ms

  Candidate Path 2:
    SID: <End.DX6@NGB-DC1, End.DX6@NGB-DC2, End.DT6@Service>
    Metric: latency 5ms (backup)

Constraint:
- Max latency: 10ms
- Min bandwidth: 1Gbps
- Protection: required (TI-LFA)
```

## 25.4 iMaster NCE Platform

### 25.4.1 iMaster NCE Overview

iMaster NCE is Huawei's network automation platform:

```
iMaster NCE (Network Cloud Engine):

NCE Platform Components:
1. iMaster NCE-Campus:
   - Campus network management
   - SWL/LWL provisioning
   - User access control

2. iMaster NCE-WAN:
   - WAN topology management
   - SR Policy computation
   - Traffic engineering

3. iMaster NCE-Fabric:
   - Data center network
   - CloudFabric solution
   - VXLAN/EVPN management

4. iMaster NCE-Storage:
   - Storage network
   - Lossless Ethernet

Common Features:
- YANG/NETCONF programmability
- gRPC telemetry
- REST API
- Terraform provider
- Kubernetes operator

NCE Architecture:
         +--------------------+
         | iMaster NCE        |
         | (Central Platform) |
         +--------+-----------+
                  |
    +-------------+-------------+
    |             |             |
    v             v             v
[NCE-Campus]  [NCE-WAN]    [NCE-Fabric]
```

### 25.4.2 iMaster NCE-WAN for SRv6

NCE-WAN manages Huawei Cloud's WAN connectivity:

```
iMaster NCE-WAN Architecture:

NCE-WAN Components:
1. Controller:
   - Path computation (PCE)
   - Policy management
   - Topology discovery

2. Analytics:
   - Real-time telemetry
   - Traffic matrix
   - Anomaly detection

3. Orchestrator:
   - Service provisioning
   - Multi-domain coordination
   - Automation workflows

NCE-WAN for Huawei Cloud SRv6:

1. Topology Discovery:
   - BGP-LS from backbone routers
   - IS-IS SRv6 topology
   - Customer CPE peering

2. SID Management:
   - Allocate SID blocks to regions
   - Assign SIDs to services
   - Monitor SID usage

3. Policy Computation:
   - Compute optimal SID lists
   - Distribute to CPEs
   - Monitor policy effectiveness

4. Traffic Monitoring:
   - Per-flow telemetry
   - Latency/loss/jitter
   - SLA violation alerts

NCE-WAN API:
REST API Examples:

# Create SRv6 Policy
POST /nce-wan/v1/sr-policies
{
  "name": "db-low-latency",
  "color": 200,
  "preference": 100,
  "sidList": [
    "End.DX6@SHA-DC1",
    "End.DX6@SHA-DC2",
    "End.DT6@Service"
  ],
  "constraint": {
    "maxLatency": 10,
    "minBandwidth": 1000
  }
}

# Query Policy Status
GET /nce-wan/v1/sr-policies/{id}/status

# Update Traffic Engineering
PUT /nce-wan/v1/te/policies/{id}
{
  "metricType": "latency",
  "weight": 1.0
}
```

### 25.4.3 Cloud Campus Integration

iMaster NCE-Campus integrates with Huawei Cloud:

```
Huawei Cloud Campus (CloudCampus):

CloudCampus Architecture:
[Enterprise Campus] <--SRv6--> [Huawei Cloud]
         |                          |
         v                          v
  +-------------+           +-----------------+
  | Campus AP   |           | CloudCampus    |
  | (Access)    |           | (Cloud Mgmt)    |
  +-------------+           +-----------------+
  | Campus Switch|           | iMaster NCE    |
  | (Aggregation)|           | -Campus        |
  +-------------+           +-----------------+
  | Campus Router|           | Cloud WAN      |
  | (Core)       |           | (SRv6 backbone)|
  +-------------+           +-----------------+

CloudCampus Features:
1. Cloud-Managed WiFi:
   - APs managed from cloud
   - Zero-touch provisioning
   - RF optimization

2. SD-WAN Branch:
   - SRv6-enabled CPE
   - Multi-link support
   - Application steering

3. Campus Network:
   - VXLAN/EVPN campus fabric
   - Segment routing for policy
   - Micro-segmentation

4. Identity Integration:
   - 802.1X authentication
   - Cloud ID (Huawei IDaaS)
   - Guest management

SRv6 Cloud Campus Path:
Branch -> Campus Router -> Cloud WAN Edge -> Huawei Cloud VPC
```

## 25.5 Huawei Cloud Connectivity Services

### 25.5.1 CloudConnect

CloudConnect provides enterprise private connectivity:

```
CloudConnect Architecture:

CloudConnect Service:
- Dedicated physical connection
- Layer 2 / Layer 3 options
- Global coverage

Connection Types:
1. Direct Connect:
   - Physical fiber cross-connect
   - 1G / 10G / 100G ports
   - Single region access

2. Partner Connect:
   - Via Huawei certified partners
   - 200+ partner networks
   - Local loop to Huawei Cloud

3. SD-WAN CloudConnect:
   - CloudConnect as underlay
   - SRv6 overlay
   - Branch-cloud connectivity

CloudConnect + SRv6:
Enterprise DC -> CloudConnect -> Huawei Cloud
                          |
                          v
                   CloudConnect Router
                          |
                          v
                   SRv6 Backbone -> VPC

SRv6 over CloudConnect:
1. Enterprise announces prefixes via BGP
2. CloudConnect edge assigns SRv6 SID
3. SRv6 path: DC -> CloudConnect -> VPC
4. No IPsec needed (private line)
```

### 25.5.2 Cloud WAN

Cloud WAN is Huawei's SD-WAN service:

```
Huawei Cloud WAN Architecture:

Cloud WAN Components:
1. Cloud WAN Gateway:
   - Edge CPE (AR series)
   - Cloud gateway (vGW)
   - SRv6 enabled

2. Cloud WAN Controller:
   - iMaster NCE-WAN
   - Path computation
   - Policy management

3. Underlay Network:
   - Internet broadband
   - MPLS VPN
   - CloudConnect private

Cloud WAN vs Traditional SD-WAN:

| Feature              | Traditional      | Huawei Cloud WAN |
|---------------------|------------------|------------------|
| Underlay            | IPsec tunnels    | SRv6 native      |
| Path Control        | Tunnel-level     | Segment-level    |
| Cloud Integration   | VPN gateway      | Direct SRv6      |
| Controller          | Proprietary      | iMaster NCE      |
| Multi-Cloud         | Limited          | Full SRv6        |
| Branch CPE          | vEdge/CPE        | AR series        |

Cloud WAN SID Structure:
Locator: fd00:<Region>:<PoP>:<Node>::/64
Function: End.DT4 (L3VPN), End.DX6 (cross-connect)

Example:
Region: cn-east-1, PoP: SHA-01
Locator: fd00:0:1:0:1::/64
End.DT4: fd00:0:1:0:1::1
```

### 25.5.3 Lean Over (Cloud Phone)

Lean over is Huawei's cloud phone service:

```
Lean Over (云手机) + SRv6:

Lean Over Service:
- Cloud-based Android phone
- ARM-based cloud instances
- Graphics rendering in cloud
- Low-latency display streaming

SRv6 for Lean Over:
- Cloud phone instances need low-latency
- User connects to nearest cloud phone region
- SRv6 path: User -> Cloud Region -> Lean Over Region

Example:
User in Shanghai connects to Lean Over instance in cn-east-1
Path: SHA-User -> cn-east-1 Lean Over Zone
SID List: <End.DX6@SHA-Edge, End.DT6@LeanOver-Zone>

Latency Requirements:
- Display: < 20ms (imperceptible)
- Touch: < 50ms (acceptable)
- Audio: < 100ms (usable)

SRv6 Path Optimization:
- User to edge: minimize
- Edge to cloud phone: minimize
- Overall: < 30ms target
```

## 25.6 Huawei Cloud Campus Solution

### 25.6.1 CloudCampus Architecture

Huawei CloudCampus extends to enterprise campuses:

```
CloudCampus Architecture:

Components:
1. Access Points (AP):
   - WiFi 6 / WiFi 7
   - Cloud-managed
   - Built-in SRv6 agent

2. Campus Switches (S series):
   - Aggregation switches
   - VXLAN/EVPN fabric
   - SRv6 underlay

3. Campus Routers (AR series):
   - Branch/Campus gateway
   - SRv6 + IPsec
   - Multi-WAN support

4. iMaster NCE-Campus:
   - Cloud management
   - Policy provisioning
   - Analytics

Campus Network Design:
[Campus Building 1]
  | Fiber
  v
[Aggregation Switch] <-> [Core Router] --SRv6--> [WAN]
  |                                           |
  v                                           v
[Campus Building 2]                    [Cloud Campus]

SRv6 Campus Topology:
- IGP: IS-IS SRv6
- Locator: fd01:<Campus-ID>:<Building>:<Device>::/80
- SID: Node-SID per device
- Policy: per-building, per-service
```

### 25.6.2 SRv6 Campus Underlay

Campus uses SRv6 as underlay:

```
Campus SRv6 Underlay:

IGP Protocol:
- IS-IS SRv6 (RFC 8662)
- Wide metrics
- Multi-instance

SID Allocation:
Campus Locator Block: fd01::/32

Per-Campus Allocation (/56):
fd01:<Campus-ID>::/56

Per-Building (/64):
fd01:<Campus-ID>:<Building-ID>::/64

Per-Device (/80):
fd01:<Campus-ID>:<Building-ID>:<Device-ID>::/80

Example:
Campus: HQ-01 (ID: 0x001)
Building: Admin (ID: 0x01)
Device: Core-Router-01 (ID: 0x01)

Locator: fd01:0:1:1::/80
Node SID: fd01:0:1:1::1

Campus Backbone Path:
Building-1 -> Building-2
SID List: <fd01:0:1:1::1, fd01:0:1:2::1>

Cross-Campus to Cloud:
Building-1 -> Cloud
SID List: <fd01:0:1:1::1, fd00:0:1:0:1::1 (Cloud Edge)>
```

### 25.6.3 CloudCampus + Cloud WAN Integration

Campus connects to cloud via Cloud WAN:

```
Campus-to-Cloud Architecture:

Enterprise HQ (CloudCampus) -> Huawei Cloud (Cloud WAN)

Campus Side:
- AR series router (branch gateway)
- Connects to ISP/MPLS
- Establishes SRv6 to Cloud WAN

Cloud Side:
- Cloud WAN Gateway
- Region-edge router
- VPC attachment

End-to-End Path:
[Campus Building] -> [AR Router] -> [ISP/MPLS] -> [Cloud WAN GW]
                                                                    |
                                                                    v
                                                              [VPC Subnet]

SRv6 SID List:
< End.DX6@AR-Campus,        # Campus gateway
  End.DX6@WAN-GW-Region,   # Cloud WAN regional gateway
  End.DT6@VPC >            # VPC VRF

Policy Example:
Policy: "Campus-to-VPC"
  Traffic: All
  SID: <AR-Campus, WAN-GW-Region, VPC-End.DT6>

Multi-Site Deployment:
Site-1: HQ -> cn-east-1 VPC
Site-2: Branch -> cn-south-1 VPC
Site-3: DC -> cn-north-1 VPC

Inter-Site via Cloud WAN:
Site-1 -> Site-2
SID: <End.DX6@HQ, End.DX6@Region-CN-SOUTH, End.DX6@Branch-2>
```

## 25.7 Technical Details

### 25.7.1 SID Allocation

Huawei Cloud SID allocation:

```
Huawei Cloud SID Block:

Allocated Block: fd00::/8 (U-L bloc global)
Regional Blocks: fd00:0:<Region-ID>::/40

Region ID Mapping:
0x001  - cn-east-1 (Shanghai)
0x002  - cn-south-1 (Shenzhen)
0x003  - cn-north-1 (Beijing)
0x004  - cn-west-1 (Ulanqab)
0x010  - sg (Singapore)
0x011  - my (Malaysia)
0x012  - th (Thailand)
0x020  - de (Germany)
0x021  - uk (UK)
0x022  - fr (France)
0x030  - us-west (US West)
0x031  - us-east (US East)

SID Format:
<Locator (48 bits)>:<Function (16 bits)>:<Argument (64 bits)>

Locator: <Region (16 bits)>:<PoP (16 bits)>:<Node (16 bits)>

Function Types:
- End (0x00): Endpoint
- End.X (0x01): Endpoint with cross-connect
- End.DX2 (0x02): L2 cross-connect
- End.DX4 (0x03): IPv4 cross-connect
- End.DX6 (0x04): IPv6 cross-connect
- End.DT4 (0x05): IPv4 VRF termination
- End.DT6 (0x06): IPv6 VRF termination
- End.B6.Encaps (0x08): B6 encapsulation
- End.B6.Encaps.Red (0x09): B6 reduced encapsulation
```

### 25.7.2 Performance Data

```
Huawei Cloud SRv6 Performance:

Latency (P99):
- Intra-region: < 1.5ms
- cn-east-1 -> cn-south-1: < 15ms
- CN -> SG: < 40ms
- CN -> DE: < 160ms
- SG -> AU: < 30ms

Throughput:
- Per-connection: up to 100 Gbps
- Per-region: 10+ Tbps
- Backbone: 400G per link

Jitter:
- Intra-region: < 0.3ms
- Inter-region: < 1ms
- Global: < 3ms

Availability:
- SLA: 99.95% - 99.99%
- Protection: TI-LFA < 50ms
- Redundancy: 3+ paths

SRv6 Processing:
- Hardware: CloudEngine 16800 series
- ASIC-native SRv6 processing
- < 1us per hop
- 100% SRv6 line rate
```

### 25.7.3 Integration APIs

```
Huawei Cloud APIs for SRv6:

REST API (华为云):

# Create SRv6 VPN Gateway
POST /vpc/v3/srv6-vpn-gateways
{
  "region_id": "cn-east-1",
  "vpc_id": "vpc-xxxx",
  "bandwidth": 1000,
  "locator": "fd00:0:1::/48",
  "payment_type": "PostPaid"
}

# Create CloudConnect
POST /directconnect/v1/cloud-connects
{
  "region_id": "cn-east-1",
  "bandwidth": 1000,
  "port_type": "10GBase-LR",
  "peer_location": "Enterprise-DC-SHA"
}

# Query SRv6 Path
GET /vpc/v3/srv6-paths?policy_id={id}

Terraform Provider:
resource "huaweicloud_vpc_srv6_vpn_gateway" "example" {
  name      = "srv6-gw"
  vpc_id    = huaweicloud_vpc.example.id
  bandwidth = 1000
  locator   = "fd00:0:1::/48"
}

Kubernetes Operator:
apiVersion: network.huawei.com/v1
kind: SRv6Policy
metadata:
  name: example
spec:
  color: 100
  preference: 100
  sidList:
    - End.DX6@SHA-DC1
    - End.DT6@Service
  constraints:
    maxLatency: 10
    minBandwidth: 1000
```

## 25.8 Summary

```
Chapter 25 Summary:

Huawei Cloud SRv6 Overview:
- Pioneer in SRv6 (RFC contributor, first implementation)
- CloudEngine + iMaster NCE integrated
- fd00::/8 SID space, hierarchical allocation

Cloud Backbone:
- CloudEngine 16800/400 series
- 100G/400G links, full mesh AZs
- Deterministic latency, < 1.5ms intra-region
- PCE-based path computation

iMaster NCE Platform:
- NCE-WAN: WAN TE and SR Policy
- NCE-Campus: campus network management
- NCE-Fabric: data center fabric
- YANG/NETCONF/gRPC programmability

Connectivity Services:
- CloudConnect: dedicated private line
- Cloud WAN: SRv6 SD-WAN solution
- Lean Over: cloud phone with SRv6

CloudCampus:
- Campus network as a service
- AR series + CloudCampus management
- SRv6 underlay with IS-IS
- Integration with Cloud WAN

Performance:
- Intra-region: < 1.5ms
- Cross-region: < 40ms (Asia)
- Global: < 160ms
- TI-LFA: < 50ms protection
```

---

## References

- Huawei Cloud Documentation: SRv6 VPN Gateway
- Huawei CloudConnect Product Page
- Huawei CloudWAN Technical Whitepaper
- iMaster NCE Developer Guide
- IETF RFC 8986: SRv6 Network Programming
- IETF RFC 8754: IPv6 Segment Routing Header
- RFC 8662: IS-IS SRv6
