# Chapter 26: AWS SRv6 - Direct Connect, Transit Gateway, and Route Manager

## 26.1 Overview

Amazon Web Services (AWS) has progressively introduced SRv6 capabilities across its global infrastructure, starting with Transit Gateway (TGW) Route Manager and expanding to Direct Connect gateway integrations. AWS's approach to SRv6 emphasizes interoperability with enterprise networks, standards compliance, and tight integration with the AWS control plane (IAM, Resource Access Manager, and AWS Cloud WAN). While AWS's SRv6 support is more recent compared to some hyperscalers, its massive global footprint and deep enterprise penetration make it a critical platform for SRv6 deployments.

This chapter presents AWS SRv6 architecture: Transit Gateway Route Manager, Direct Connect + SRv6 integration, AWS Cloud WAN, VPC routing enhancements, and enterprise hybrid cloud connectivity patterns using SRv6.

## 26.2 AWS Network Overview

### 26.2.1 AWS Global Infrastructure

AWS operates the largest public cloud infrastructure:

```
AWS Global Infrastructure:

Regions (as of 2024):
- 33 launched regions globally
- 105 AZs (Availability Zones)
- 16 Local Zones
- 32 Wavelength Zones
- 410+ PoPs (Points of Presence)

Network Backbone:
- AWS Global Backbone (private network)
- 100+ Tbps aggregate bandwidth
- Direct connects to 1000+ networks
- Regional edge caching (CloudFront)

Regional Structure:
Region: us-east-1 (N. Virginia)
  - us-east-1a, us-east-1b, us-east-1c, us-east-1d, us-east-1e, us-east-1f

Services Related to Networking:
- VPC: Virtual Private Cloud
- Direct Connect: dedicated private connection
- Transit Gateway: hub-and-spoke VPC connector
- VPN: IPsec VPN connections
- Cloud WAN: global WAN management
- Route 53: DNS service
- CloudFront: CDN
- Global Accelerator: static IP anycast
```

### 26.2.2 AWS Path to SRv6

AWS has progressively adopted SRv6:

```
AWS SRv6 Timeline:

2021 - Transit Gateway Route Manager Preview:
- Announced SRv6 support for TGW Route Manager
- First AWS service with SRv6 data plane

2022 - Direct Connect Gateway Enhancements:
- SRv6 encapsulation support on DXGW
- BGP peering with SRv6 SIDs

2023 - Cloud WAN SRv6:
- SRv6 as primary transport
- Cloud WAN + Route Manager integration

2024 - VPC ENI Enhancements:
- SRv6 SRH processing on Elastic Network Interfaces
- Instance metadata support for SRv6

AWS SRv6 Drivers:
1. Enterprise Hybrid Cloud:
   - On-premises SRv6 networks
   - Seamless interconnect
   - Consistent policies

2. Global Traffic Engineering:
   - Multi-region traffic optimization
   - Application-aware routing
   - Low-latency paths

3. Standards Compliance:
   - IETF SRv6 (RFC 8986)
   - Interoperability
   - Multi-vendor support

AWS SID Structure:
AWS uses IPv6 addresses for SIDs:
- Transit Gateway: 2600:1::<SID>
- Direct Connect: 2600:2::<SID>
- VPC: IPv6 address within VPC CIDR
```

### 26.2.3 AWS SRv6 Architecture

```
AWS SRv6 Architecture Overview:

Layer 1: Customer Edge
[Enterprise Router] --SRv6--> [Direct Connect] --> [DXGW]
                              OR
[SD-WAN Edge] --SRv6--> [AWS Transit Gateway]

Layer 2: AWS Edge Services
[Direct Connect Gateway] <--> [Transit Gateway]
        |                           |
        v                           v
[Virtual Private Gateway]     [TGW Route Table]

Layer 3: VPC Network
[TGW] --> [VPC Subnet] --> [EC2/Container]

AWS SRv6 SID Examples:
2600:1::1      - Transit Gateway SID
2600:1::2      - Direct Connect Gateway SID
2600:2::<VXLAN>- VPC-specific SID (if assigned)

SRv6 Path: Enterprise -> AWS
< End.DX6@OnPrem, End.DX6@DXGW, End.DT6@VPC-VRF >
```

## 26.3 Transit Gateway Route Manager

### 26.3.1 Transit Gateway Overview

Transit Gateway (TGW) is AWS's hub for VPC connectivity:

```
Transit Gateway Architecture:

TGW Components:
1. Transit Gateway:
   - Regional hub router
   - Connects VPCs and on-prem networks
   - Route tables for steering

2. Transit Gateway Attachments:
   - VPC attachment
   - VPN attachment (Site-to-Site)
   - Direct Connect attachment
   - Transit Gateway Connect (GRE)

3. Transit Gateway Route Tables:
   - Main route table
   - Custom route tables
   - Route propagation
   - Static routes

TGW vs Other AWS Networking:
| Service              | Use Case                     |
|---------------------|------------------------------|
| VPC Peering         | 2 VPCs, no transitive routing|
| Transit Gateway     | Hub-spoke, 100s of VPCs      |
| PrivateLink         | Service exposure             |
| Direct Connect      | On-prem connectivity         |
| VPN                 | Encrypted on-prem connect    |

TGW Limits:
- Max VPC attachments per TGW: 50 (default)
- Max VPN attachments per TGW: 50 (default)
- Max route tables per TGW: 20
- Max routes per TGW RT: 10,000
```

### 26.3.2 Route Manager with SRv6

Route Manager extends TGW with SRv6:

```
Transit Gateway Route Manager:

Route Manager Function:
- Centralized route management
- SRv6 path selection
- Traffic engineering

Route Manager + SRv6 Features:
1. SRv6 Path Definition:
   - Define SID lists for paths
   - Associate with route tables
   - Per-prefix path selection

2. Path Attributes:
   - Latency
   - Bandwidth
   - AS-path
   - Community

3. Policy-Based Routing:
   - Match DSCP/prefix
   - Select SRv6 path
   - Forward to destination

Route Manager CIDR Announcements:
Example: 10.0.0.0/8 via SRv6 path to us-east-1

SRv6 Path:
SID List: <End.DX6@TGW-US-EAST, End.DT6@VPC-A>
= 2600:1::1 : 2600:1::2

AWS CLI Create SRv6 Path:
aws ec2 create-transit-gateway-route
  --transit-gateway-route-table-id tgw-rtb-xxxx
  --destination-cidr-block 10.0.0.0/8
  --transit-gateway-attachment-id attach-xxxx
  --blackhole  # false for normal route

Route Manager Path Selection:
1. Prefix: 10.0.1.0/24 (Web tier)
   Path: Low-latency SID list
   SID: <TGW-SEA, TGW-US-EAST-1, VPC-A>

2. Prefix: 10.0.2.0/24 (DB tier)
   Path: High-security SID list
   SID: <TGW-SEA, TGW-US-EAST-2, VPC-B (isolated)>]
```

### 26.3.3 TGW Route Manager API

Route Manager is programmable via API:

```
AWS CLI / API for Route Manager:

Create Transit Gateway with Route Manager:
aws ec2 create-transit-gateway
  --description "My SRv6 TGW"
  --options "TransitGatewayRouteTableId=tgw-rtb-xxxx"

Associate Route Table:
aws ec2 associate-transit-gateway-route-table
  --transit-gateway-route-table-id tgw-rtb-xxxx
  --transit-gateway-attachment-id attach-xxxx

Create SRv6 Route:
aws ec2 create-transit-gateway-route
  --transit-gateway-route-table-id tgw-rtb-xxxx
  --destination-cidr-block 10.0.0.0/8
  --transit-gateway-attachment-id attach-xxxx
  --sr6-options "SidList=[2600:1::1,2600:1::2]"

Route Manager Telemetry:
aws cloudwatch get-metric-statistics
  --namespace AWS/TransitGateway
  --metric-name RouteManagerLatency
  --dimensions Name=TransitGateway,Value=tgw-xxxx
  --start-time 2024-01-01T00:00:00Z
  --end-time 2024-01-02T00:00:00Z
  --period 300
  --statistics Average

Terraform Provider:
resource "aws_ec2_transit_gateway" "example" {
  description = "SRv6 TGW"
  options {
    transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.example.id
  }
}
```

## 26.4 Direct Connect with SRv6

### 26.4.1 Direct Connect Overview

Direct Connect provides dedicated private connectivity:

```
Direct Connect Architecture:

Components:
1. Direct Connect Port:
   - 1 Gbps, 10 Gbps, 100 Gbps
   - Located at AWS Direct Connect locations
   - 802.1Q VLAN tagging

2. Virtual Interface (VIF):
   - Public VIF: AWS public services
   - Private VIF: VPC connectivity
   - Transit VIF: Transit Gateway

3. Direct Connect Gateway:
   - Global resource
   - Links to one or more VPCs
   - Cross-region connectivity

4. Connection:
   - Dedicated connection (AWS-owned)
   - Hosted connection (partner-owned)
   - Hosted virtual interface

Direct Connect Locations:
- 100+ locations globally
- Major carrier hotels
- AWS Direct Connect PoPs
- Partner POPs

Direct Connect Limits:
- Max VLANs per connection: 50
- Max BGP peerings: 50
- Max prefixes per BGP: 1000
- Max Direct Connect gateways: 10
```

### 26.4.2 Direct Connect Gateway with SRv6

DXGW supports SRv6 encapsulation:

```
Direct Connect Gateway + SRv6:

DXGW SRv6 Support:
- SRv6 encapsulation on private VIF
- BGP route propagation with SRv6 SID
- Cross-connect to Transit Gateway

SRv6 Configuration on DXGW:
1. Customer announces IPv6 prefix with SRv6 SID
2. DXGW accepts and propagates
3. Transit Gateway routes via SID list

BGP SRv6 Attribute:
Customer Edge router announces:
- IPv6 prefix: 2600:1::/32 (customer SID block)
- SRv6 SID attribute: uSID block allocation
- BGP Community: 7224:8100 (AWS SRv6)

AWS-Side SRv6 Processing:
- DXGW assigns 2600:2::<VXLAN> SID
- For each VPC attachment, unique SID
- Transit Gateway routes based on SID

SRv6 Path over Direct Connect:
Enterprise DC -> Direct Connect -> DXGW -> TGW -> VPC

Packet Format (Egress to VPC):
[Outer IPv6 DA: 2600:2::<VPC-SID>][SRH][Payload]
[Outer IPv6 SA: 2600:1::<CPE-SID>][Payload]

SID List:
< End.DX6@DXGW, End.DT6@VPC-Attach >
```

### 26.4.3 Direct Connect VIF Types with SRv6

Different VIF types support SRv6 differently:

```
VIF Types and SRv6 Support:

1. Private VIF + SRv6:
   - Direct to VPC
   - SRv6 encapsulation
   - BGP MD5 authentication

   Configuration:
   Customer Router:
   - BGP peer: <VPC-CIDR>::1
   - IPv6 BGP session
   - SRv6 SID: 2600:1::1

2. Transit VIF + SRv6:
   - Via Transit Gateway
   - SRv6 SID list through TGW
   - Multi-VPC routing

   Configuration:
   Customer Router:
   - BGP peer: 2600:1::1
   - SRv6 enabled
   - Announcement: enterprise prefixes

3. Public VIF + SRv6:
   - AWS public services (S3, DynamoDB)
   - Not SRv6 (public internet)
   - Use for non-sensitive traffic

Transit VIF Example (Recommended for SRv6):
Direct Connect Location: Los Angeles (LAX)
Customer Router: 2600:1::1 (SID)
Direct Connect Gateway: 2600:2::1
Transit Gateway: 2600:3::1
VPC Attachment: 2600:4::<VPC-ID>

SRv6 Path to VPC us-west-2:
< 2600:1::1, 2600:2::1, 2600:3::1, 2600:4::<VPC-ID> >
```

## 26.5 AWS Cloud WAN

### 26.5.1 Cloud WAN Overview

AWS Cloud WAN is a global WAN managed service:

```
AWS Cloud WAN Architecture:

Cloud WAN Components:
1. Core Network:
   - Global backbone (AWS Global)
   - Regional segments
   - SD-WAN integration

2. Network Manager:
   - Global network management
   - Policy management
   - Topology visualization

3. Attachments:
   - SD-WAN connector
   - VPN attachment
   - Direct Connect attachment
   - Branch appliances

4. Global Network Edge:
   - AWS Local Zones
   - Wavelength Zones
   - Edge compute (Outposts)

Cloud WAN vs Transit Gateway:
| Feature              | Transit Gateway   | Cloud WAN         |
|---------------------|-------------------|-------------------|
| Scope               | Regional          | Global            |
| Management          | Per-region        | Centralized       |
| Policy              | Route tables      | Global policies   |
| SD-WAN              | Manual            | Native connector  |
| SRv6                | Via Route Manager| Native support    |

Cloud WAN Benefits:
- Global policy-based networking
- Centralized management
- SD-WAN partner integration
- Built-in redundancy
```

### 26.5.2 Cloud WAN SRv6 Integration

Cloud WAN uses SRv6 for path selection:

```
Cloud WAN + SRv6:

SRv6 in Cloud WAN:
1. Core Network Policy:
   - Define SRv6 paths per segment
   - Assign SID lists
   - Set optimization objectives

2. Segment Routing:
   - Network segments = isolated domains
   - Per-segment SID allocation
   - Policy-based steering

3. TE Integration:
   - Route Manager integration
   - Traffic engineering
   - Performance monitoring

Cloud WAN Segments:
- Production segment: PRD-*
- Development: DEV-*
- Partner access: PARTNER-*

Segment SID Allocation:
Segment: Production-us-east
  SID: 2600:1:10::/56

Segment: Production-us-west
  SID: 2600:1:20::/56

SRv6 Path Policy:
Policy: "production-low-latency"
  Segment: Production
  Priority: high

  Path 1:
    SID: <Core-AZ1, Core-AZ2, VPC-Attach>
    Metric: latency

  Path 2 (backup):
    SID: <Core-AZ3, VPC-Attach>
    Metric: latency (higher)

Cloud WAN CLI:
aws cloudwan create-network
  --name "global-net"
  --description "SRv6 Global Network"

aws cloudwan create-policy
  --name "low-latency-policy"
  --rules '[{"action":"forward"}]'
  --segment-actions '[{"sid":"2600:1:10::/56"}]'
```

### 26.5.3 Cloud WAN + Route Manager

Route Manager integrates with Cloud WAN:

```
Cloud WAN Route Manager Integration:

Route Manager in Cloud WAN:
- Per-segment route tables
- SRv6 path selection
- Cross-regional routing

Cloud WAN Route Table:
Segment: Production

  Destination           | Next Hop         | SID List
  ---------------------|------------------|------------------------
  10.0.0.0/8 (local)   | Local VPC        | -
  10.1.0.0/16 (us-east)| TGW-us-east     | <2600:1:10::1>
  10.2.0.0/16 (eu-west)| TGW-eu-west     | <2600:1:20::1>
  172.16.0.0/12 (on-prem)| DX-GW         | <2600:2::1, 2600:1:10::1>

SRv6 Path from us-west to us-east via Cloud WAN:
Path: us-west-2 VPC -> TGW-us-west -> Core Backbone -> TGW-us-east -> VPC

SID List:
< End.DT6@VPC-A,
  End.DX6@TGW-US-WEST,
  End.DX6@TGW-US-EAST,
  End.DT6@VPC-B >

Cloud WAN Core Network:
Regions connected: us-east-1, us-west-2, eu-west-1, ap-southeast-1
Core links: 100G AWS backbone
Latency: < 5ms per 1000km (within continent)
```

## 26.6 VPC Routing with SRv6

### 26.6.1 VPC Routing Overview

VPC routing is the foundation for SRv6 in VPC:

```
VPC Routing Fundamentals:

VPC Components:
1. Route Table:
   - Main route table
   - Custom route tables
   - Association with subnets

2. Elastic Network Interface (ENI):
   - Primary IPv4/IPv6 address
   - Secondary IPv4/IPv6 addresses
   - Source/dest check

3. Internet Gateway (IGW):
   - VPC to internet
   - IPv4/IPv6

4. Virtual Private Gateway (VGW):
   - Site-to-Site VPN
   - Direct Connect

VPC Routing with SRv6:
SRv6-enabled VPC:
- VPC IPv6 CIDR: 2600:1ff8:cafe::/56
- Subnet IPv6: 2600:1ff8:cafe:1::/64
- Instance ENI: 2600:1ff8:cafe:1::10a

SRv6 Processing in VPC:
1. Instance sends packet with IPv6 DA in SRv6 SID range
2. VPC router processes route table
3. SRH examined if present
4. Forward based on SID or direct IPv6

VPC Route Table with SRv6:
Destination             | Target           | SID
-----------------------|------------------|----
2600:1ff8:cafe::/56    | Local            | -
10.0.0.0/16            | Local            | -
2600:2::/32 (DXGW)    | TGW attachment   | 2600:2::1
```

### 26.6.2 ENI SRv6 Processing

Elastic Network Interfaces handle SRv6:

```
ENI SRv6 Processing:

ENI Capabilities:
- IPv6 address assignment
- SRH processing (in VPC router)
- VPC routing integration

SRv6 Packet Flow in VPC:

1. Ingress (From Internet/On-prem):
   Packet arrives at ENI:
   [Outer IPv6: 2600:2::<SID>][SRH][Payload]

   VPC Router:
   - Match 2600:2::* to DXGW attachment
   - Decapsulate SRH
   - Route payload to instance

2. Egress (To Internet/On-prem):
   Instance sends:
   [IPv6: 2600:1ff8:cafe:1::10a -> 2600:2::<Dest>]

   VPC Router:
   - Route to DXGW/TGW
   - Push SRv6 header if needed
   - Encapsulate with SID list

Instance Metadata and SRv6:
Instance metadata can expose SRv6 information:
IMDSv2: GET http://169.254.169.254/latest/metaData/

Metadata Items:
- ipv6/sid: instance SRv6 SID
- ipv6/sid-block: allocated SID block
- network/route-table: associated route table
```

### 26.6.3 VPC Routing with TGW

TGW connects VPCs with SRv6 routing:

```
VPC-to-VPC via TGW with SRv6:

Architecture:
[VPC-A (us-east-1)] <--TGW--> [VPC-B (us-west-2)]
    |                          |
    | 2600:1:10::/56           | 2600:1:20::/56

VPC-A Route Table (for TGW attachment):
Destination             | Target         | SID
-----------------------|----------------|----
10.1.0.0/16            | TGW           | 2600:3::10
10.2.0.0/16            | TGW           | 2600:3::20

TGW Route Table (VPC-A -> VPC-B):
Destination             | Target         | SID
-----------------------|----------------|----
10.2.0.0/16            | VPC-B attach  | 2600:1:20::1

SRv6 Path: VPC-A Instance -> VPC-B Instance
SID List: <End.DT6@VPC-A, End.DX6@TGW, End.DT6@VPC-B>

Packet Flow:
1. VPC-A instance: 10.1.0.10 -> 10.2.0.20
2. VPC-A subnet router: matches 10.2.0.0/16 via TGW
3. TGW: SID list <End.DX6@TGW, End.DT6@VPC-B>
4. VPC-B subnet router: delivers to instance
```

## 26.7 AWS SRv6 Technical Details

### 26.7.1 AWS SID Allocation

AWS SID space and allocation:

```
AWS SID Allocation:

AWS SID Block: 2600::/16 (allocated)

Regional Blocks (/40):
2600:0001::/40   - us-east-1
2600:0002::/40   - us-west-1
2600:0003::/40   - us-west-2
2600:0010::/40   - eu-west-1
2600:0011::/40   - eu-central-1
2600:0020::/40   - ap-southeast-1
2600:0021::/40   - ap-northeast-1
... (full list in AWS documentation)

SID Format:
<AWS Block (16 bits)>:<Regional (24 bits)>:<Service (24 bits)>:<ID (32 bits)>

2600:0001:0:0:0:0:0:1
|      |  |  |  |  |  |
AWS    |  |  |  |  |  +-- Instance/Interface ID
       |  |  |  |  +-- Service: 0 = TGW, 1 = DXGW, 2 = VPC
       |  |  |  +-- PoP/Availability Zone
       |  |  +-- Region (0 = us-east-1)
       |  +-- Reserved
       +-- AWS SID Block

Service SIDs:
2600:0001:0:0:1  - Transit Gateway
2600:0001:0:0:2  - Direct Connect Gateway
2600:0001:0:0:3  - VPC (VRF termination)
```

### 26.7.2 Performance and Limits

```
AWS SRv6 Performance:

Latency (within region):
- Same AZ: < 1ms
- Cross AZ: < 2ms
- TGW in-region: < 3ms

Latency (cross-region):
- us-east-1 -> us-west-2: ~60ms
- us-east-1 -> eu-west-1: ~80ms
- us-east-1 -> ap-southeast-1: ~170ms

Throughput:
- Per ENI: 100 Gbps (latest instance types)
- Per VPC: aggregate 100 Gbps+
- TGW: 50 Gbps aggregate (default)

SRv6 Processing:
- VPC Router: hardware-accelerated
- Instance types: newer = better SRv6
- Nitro instances: SRv6 optimized

AWS Limits for SRv6:
- Max SID blocks per account: 10
- Max routes per VPC RT: 50
- Max TGW attachments: 50 (soft limit)
- Max prefixes via Direct Connect: 1000
```

### 26.7.3 AWS CLI and SDK

```
AWS CLI for SRv6:

Transit Gateway SRv6 Route:
aws ec2 create-transit-gateway-route \
  --transit-gateway-route-table-id tgw-rtb-0123456789abcdef0 \
  --destination-cidr-block 10.0.0.0/16 \
  --transit-gateway-attachment-id tgw-attach-0123456789abcdef0 \
  --sr6-options "SidList=[2600:1::1,2600:1::2]"

Cloud WAN Network:
aws cloudwan create-network \
  --cli-input-json '{
    "coreNetwork": {
      "NetworkID": "example-net",
      "Policy": {
        "segments": [{"name": "production"}]
      }
    }
  }'

Direct Connect SRv6:
aws directconnect create-private-virtual-interface \
  --connection-id dxcon-xxxx \
  --new-private-virtual-interface \
  "{
    \"virtualInterfaceName\": \"srv6-vif\",
    \"vlan\": 100,
    \"asn\": 65001,
    \"amazonAddress\": \"2600:1::1\",
    \"customerAddress\": \"2600:1::2\",
    \"addressFamily\": \"ipv6\"
  }"

Terraform Provider:
resource "aws_ec2_transit_gateway_route" "srv6" {
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.main.id
  destination_cidr_block         = "10.0.0.0/16"
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.main.id
  sr6_options {
    sid_list = ["2600:1::1", "2600:1::2"]
  }
}
```

## 26.8 Enterprise Connectivity Patterns

### 26.8.1 Hybrid Cloud with SRv6

Typical AWS hybrid cloud with SRv6:

```
Hybrid Cloud Pattern: On-Prem SRv6 -> AWS

On-Premises Network:
- Enterprise runs IS-IS SRv6
- SID block: 2001:db8:1::/48
- Edge router: 2001:db8:1:0:0:0:0:1

AWS Connection:
- Direct Connect Private VIF
- DXGW with SRv6 enabled
- Transit Gateway

SRv6 Path: On-Prem -> AWS VPC
On-Prem SID: 2001:db8:1:0:0:0:0:1
AWS SID: 2600:1:0:0:3:<VPC-ID>

Full SID List:
< End.DX6@OnPrem-Edge,
  End.DX6@DXGW,
  End.DX6@TGW,
  End.DT6@VPC >

BGP SRv6 Configuration:
On-Prem Router:
router bgp 65001
 address-family ipv6 unicast
  neighbor 2600:1::1 activate
  neighbor 2600:1::1 prefix-list SRV6-SIDS in
  neighbor 2600:1::1 route-map SRV6-ROUTES in

route-map SRV6-ROUTES permit 10
 match ipv6 address prefix-list SRV6-SIDS
 set extcommunity srv6 {sid-block 2001:db8:1::/48}
```

### 26.8.2 Multi-Account AWS with SRv6

Multi-account pattern with Route Manager:

```
AWS Multi-Account SRv6 Architecture:

AWS Organizations:
- Management Account
- Security Tooling Account
- Shared Services Account
- Application Account 1
- Application Account 2

Shared Services VPC (Security Account):
- Transit Gateway
- Central Direct Connect
- Route Manager

Application VPCs (App Accounts):
- App 1 VPC: 10.1.0.0/16
- App 2 VPC: 10.2.0.0/16

TGW Route Manager Policy:
Segment: Security

  To App 1:
  SID List: <2600:3::10, 2600:3::1> (via Security TGW)

  To App 2:
  SID List: <2600:3::20, 2600:3::1>

Account Linking via RAM:
- Transit Gateway shared via Resource Access Manager
- Cross-account VPC attachments
- Centralized route policies

SRv6 Multi-Account Path:
On-Prem -> DX -> Security TGW -> App 1 VPC
```

### 26.8.3 Global Enterprise with AWS

Multi-region global enterprise:

```
Global Enterprise: AWS SRv6 Deployment:

Regions: us-east-1 (primary), eu-west-1 (DR), ap-southeast-1 (APAC)

Primary Region: us-east-1
- Direct Connect to on-premises
- TGW Route Manager
- Production VPC

DR Region: eu-west-1
- VPN backup to on-premises
- TGW
- DR VPC

APAC Region: ap-southeast-1
- SD-WAN connection
- TGW
- APAC VPC

Global Routing Policy:
- Production prefix: 10.0.0.0/8
- Region preference: primary
- Failover: automatic via Route Manager

Cross-Region SRv6 Path:
us-east-1 VPC -> TGW-us-east -> AWS backbone -> TGW-eu-west -> EU-VPC
SID List: <End.DT6@USEast-VPC, End.DX6@TGW-USEast, End.DX6@TGW-EuWest, End.DT6@EuWest-VPC>

Cloud WAN Global Network:
- Core network spanning all regions
- Global policies
- SRv6 paths per region
```

## 26.9 Summary

```
Chapter 26 Summary:

AWS SRv6 Overview:
- Transit Gateway Route Manager: SRv6 path selection
- Direct Connect: SRv6 encapsulation support
- Cloud WAN: global SRv6 policy management
- 2600::/16 SID block allocation

Transit Gateway Route Manager:
- Centralized route management
- SRv6 SID list per route
- Per-prefix path selection
- Traffic engineering

Direct Connect + SRv6:
- Private/Transit VIF with SRv6
- DXGW as SRv6 gateway
- BGP SRv6 route exchange
- Multi-VPC via TGW

AWS Cloud WAN:
- Global WAN managed service
- Policy-based segment routing
- SD-WAN connector integration
- Route Manager integration

VPC Routing:
- ENI SRH processing
- VPC router integration
- TGW attachment with SID
- Cross-AZ/region routing

Performance:
- Intra-region: < 3ms (via TGW)
- Cross-region us-us: ~60ms
- Cross-region us-eu: ~80ms
- 100 Gbps per ENI

Enterprise Patterns:
- On-prem SRv6 -> AWS via DX
- Multi-account via RAM + TGW
- Global enterprise via Cloud WAN
```

---

## References

- AWS Transit Gateway Documentation
- AWS Direct Connect User Guide
- AWS Cloud WAN Developer Guide
- AWS CLI Reference: Transit Gateway Commands
- IETF RFC 8986: SRv6 Network Programming
- IETF RFC 8754: IPv6 Segment Routing Header
