# Chapter 27: SRv6 Multi-Cloud Interconnection - Architecture, End-to-End SRv6, and Unified Control Plane

## 27.1 Overview

Multi-cloud architectures — where enterprises distribute workloads across multiple cloud providers simultaneously — have become the de facto standard for enterprise cloud strategy. SRv6 provides a compelling foundation for multi-cloud networking because it offers a unified, programmable data plane that can span cloud providers, an on-premises data center, and edge locations. Unlike traditional approaches that rely on IPsec VPNs, MPLS interconnect services, or provider-specific gateways, SRv6 enables end-to-end source routing across cloud boundaries with consistent policies, unified telemetry, and simplified operations.

This chapter presents SRv6 multi-cloud architecture: the challenges of multi-cloud networking, end-to-end SRv6 path construction across cloud providers, unified control plane design, SID translation and interoperability between providers, cloud-native service mesh integration, and practical deployment patterns for enterprise multi-cloud environments.

## 27.2 Multi-Cloud Networking Challenges

### 27.2.1 Traditional Multi-Cloud Connectivity

Connecting multiple cloud providers traditionally requires:

```
Traditional Multi-Cloud Approaches:

Approach 1: Full-Mesh IPsec
[On-Prem] --IPsec--> [AWS VPC]
   |                      |
   +--IPsec--> [Azure VNet]
   |                      |
   +--IPsec--> [GCP VPC]
   +--IPsec--> [Alibaba VPC]

Problems:
- N*(N-1)/2 tunnels required
- Inconsistent policies per tunnel
- Complex key management
- Latency from encapsulation overhead

Approach 2: MPLS Interconnect
[On-Prem MPLS] ---> [Cloud Provider 1 MPLS GW]
                 ---> [Cloud Provider 2 MPLS GW]

Problems:
- Provider-dependent (not all support MPLS)
- Limited TE capabilities
- BGP peering complexity
- Cost at scale

Approach 3: Cloud Exchange (Colo/IX)
[CSP 1] <---> [Cloud Exchange] <---> [CSP 2]
                     |
[On-Prem] -----------+

Problems:
- Single point of failure
- Bandwidth costs at exchange
- Limited SLA control
- Provider lock-in risk

Multi-Cloud Connectivity Matrix:
| Source\Dest | AWS | Azure | GCP | Alibaba | On-Prem |
|-------------|-----|-------|-----|---------|---------|
| AWS         | -   | VPN   | VPN | VPN     | DX/VPN  |
| Azure       | VPN | -     | VPN | VPN     | Express |
| GCP         | VPN | VPN   | -   | VPN     | CloudR  |
| Alibaba     | VPN | VPN   | VPN | -       | DC PPP  |
| On-Prem     | DX  | Expr  | CR  | DC      | -       |

Legend: DX=Direct Connect, Expr=ExpressRoute, CR=Cloud Router, DC=DataCom/Partner
```

### 27.2.2 Why SRv6 for Multi-Cloud

SRv6 addresses multi-cloud challenges:

```
SRv6 Multi-Cloud Value Proposition:

1. End-to-End Source Routing:
   - Single SID list spans all providers
   - No per-cloud gateway configuration
   - Controller programs entire path

2. Unified Data Plane:
   - All providers support IPv6
   - SRH is standard (RFC 8754)
   - No encapsulation translation

3. Programmable Path:
   - Per-application SID policies
   - Multi-cloud SLA enforcement
   - Dynamic re-optimization

4. Simplified Operations:
   - One protocol (SRv6) everywhere
   - Unified telemetry
   - Consistent security model

Traditional vs SRv6 Multi-Cloud:
| Aspect              | Traditional         | SRv6                 |
|---------------------|---------------------|----------------------|
| Connectivity        | N*(N-1)/2 tunnels   | Single SRv6 domain   |
| Path Control        | Tunnel-level        | Segment-level        |
| Policy              | Per-tunnel          | Global               |
| Cloud Provider      | Per-provider config | Provider-agnostic    |
| Telemetry           | Fragmented          | End-to-end           |
| Failover            | Manual/re Ansible   | Automatic (TI-LFA)   |
| Scalability         | Limited by tunnels  | Linear with SIDs     |

Multi-Cloud SRv6 Providers Status (as of 2024):
- AWS: Transit Gateway Route Manager + Direct Connect SRv6
- Azure: vWAN + ExpressRoute SRv6 (preview)
- GCP: Cloud Router + Dedicated Interconnect (SRv6 roadmap)
- Alibaba Cloud: Full SRv6 ENS + VPN Gateway
- Huawei Cloud: Full SRv6 CloudWAN + CloudConnect
```

### 27.2.3 The SID Translation Challenge

Multi-cloud SRv6 requires SID interoperability:

```
SID Translation Challenge:

Problem: Each cloud provider uses different SID blocks

AWS SID Block:      2600::/16
Azure SID Block:    3FFE::/16 (hypothetical)
GCP SID Block:      2001:4860::/32
Alibaba SID Block:  FC00::/8
Huawei SID Block:   FD00::/8

Cross-Cloud Path:
On-Prem (FC00::/8) -> AWS (2600::/16) -> GCP (2001:4860::/32)

SID List would contain:
< FC00:0:1::1, 2600:1::1, 2001:4860:0:1::1 >
         ^         ^
         |         +-- GCP SID (different block)
         +-- On-Prem SID

Cross-Cloud SID Translation:
Translation Point 1: On-Prem Edge
  - Translates FC00:: to 2600:: prefix
  - Maintains SID semantics

Translation Point 2: Cloud Interconnect
  - AWS <-> GCP exchange
  - SID block mapping
  - Preserves path information

SID Translation Methods:
1. SID Mapping (Static):
   - Map each provider SID to unique global SID
   - Translation at boundary router
   - Maintains 1:1 mapping

2. SID Encapsulation:
   - Outer SRH at each cloud boundary
   - Inner SID for original path
   - Tunnel-in-tunnel approach

3. uSID Carrier:
   - Use uSID format with global block
   - All providers support FC00::/8 uSID
   - Compressed path encoding
```

## 27.3 End-to-End SRv6 Architecture

### 27.3.1 Multi-Cloud SRv6 Reference Architecture

```
End-to-End SRv6 Multi-Cloud Architecture:

Layer 1: On-Premises Network
[Enterprise DC]
  - IS-IS SRv6
  - SID block: fc00:0:1::/48
  - Edge router: fc00:0:1:0:0:0:0:1

Layer 2: Cloud Interconnects
[On-Prem Edge] --SRv6--> [Cloud Exchange/IX]
                         |
                         +---> [AWS Direct Connect] --> [AWS VPC]
                         |
                         +---> [Azure ExpressRoute] --> [Azure VNet]
                         |
                         +---> [GCP Dedicated Interconnect] --> [GCP VPC]
                         |
                         +---> [Alibaba Express Connect] --> [Alibaba VPC]

Layer 3: Cloud Provider Networks
[AWS VPC]   - SID: 2600:1::/40
[Azure VNet] - SID: 3FFE:1::/40
[GCP VPC]   - SID: 2001:4860:1::/40
[Alibaba VPC] - SID: FC00:0:10::/40

Layer 4: Cross-Cloud Path
[AWS VPC] <--SRv6--> [GCP VPC]
           |
           +-- Cloud Exchange
           |
           +-- Direct cloud-to-cloud link

Global SID Allocator (Controller):
- Assigns global SIDs per provider
- Tracks SID mappings
- Programs translation policies
```

### 27.3.2 Cross-Cloud SID List Construction

Constructing SID lists across clouds:

```
Cross-Cloud SID List Example:

Scenario:
- Enterprise on-prem in Shanghai
- Production workload in AWS us-west-2
- DR workload in Azure eastus
- Analytics in GCP us-central1

On-Prem SID Block: fc00:0:1::/48
AWS SID Block: 2600:1::/40
Azure SID Block: (assigned) 3FFE:1::/40
GCP SID Block: (assigned) 2001:4860:1::/40

Path: On-Prem -> AWS -> Azure

Step-by-Step SID List:
1. On-Prem (Shanghai):
   Locator: fc00:0:1::/48
   Node SID: fc00:0:1:0:0:0:0:1

2. Cloud Interconnect (AWS Direct Connect):
   - SID: 2600:1:0:0:0:0:0:1 (AWS DXGW)
   - Function: End.DX6 (cross-connect)

3. AWS Transit Gateway:
   - SID: 2600:1:0:0:1:0:0:1 (TGW)

4. Cross-Cloud Link (AWS -> Azure):
   - Interconnect SID: 2600:1:0:0:2:0:0:1 (CloudEx GW)

5. Azure VNet:
   - SID: 3FFE:1:0:0:1:0:0:1 (Azure Gateway)

Complete SID List:
< fc00:0:1:0:0:0:0:1,    # On-Prem Edge
  2600:1:0:0:0:0:0:1,    # AWS DXGW
  2600:1:0:0:1:0:0:1,    # AWS TGW
  2600:1:0:0:2:0:0:1,    # CloudEx GW
  3FFE:1:0:0:1:0:0:1 >   # Azure VNet Gateway

SRH Encoding:
Segment List (in SRH):
[5] fc00:0:1:0:0:0:0:1
[4] 2600:1:0:0:0:0:0:1
[3] 2600:1:0:0:1:0:0:1
[2] 2600:1:0:0:2:0:0:1
[1] 3FFE:1:0:0:1:0:0:1
[0] <final destination>

Segment Left on arrival at AWS TGW: 3
(pointer to 2600:1:0:0:2:0:0:1)
```

### 27.3.3 Unified Control Plane Design

Control plane for multi-cloud SRv6:

```
Multi-Cloud SRv6 Control Plane Architecture:

1. Global PCE (Path Computation Element):
   - Computes end-to-end SID lists
   - Has global view of all providers
   - Programs SID translation policies

2. Regional PCEs:
   - Per-cloud provider PCE
   - Intra-cloud path computation
   - Telemetry aggregation

3. SID Registry:
   - Global SID block allocation
   - Per-provider SID mapping
   - SID lifecycle management

4. Policy Controller:
   - Application policies
   - SLA requirements
   - Security constraints

5. Topology Manager:
   - BGP-LS from all domains
   - IGP extension (if applicable)
   - Cloud provider API integration

Control Plane Protocols:
- PCEP: Path computation requests
- BGP-LS: Topology distribution
- gRPC: Telemetry and policy
- NETCONF/YANG: Device configuration

Protocol Flow:
[Global PCE]
    |
    +--PCEP--> [AWS Transit Gateway Controller]
    |
    +--PCEP--> [Azure vWAN Controller]
    |
    +--BGP-LS--> [On-Prem IGP]
    |
    +--gRPC--> [GCP Cloud Router]

Provider Controllers:
AWS: Transit Gateway Route Manager API
Azure: vWAN API (Azure Virtual WAN)
GCP: Cloud Router (BGP)
Alibaba: CEN API + PCE
Huawei: iMaster NCE-WAN
```

## 27.4 Cloud Provider Interoperability

### 27.4.1 AWS to Azure via SRv6

Cross-cloud path AWS to Azure:

```
AWS -> Azure SRv6 Path:

Architecture:
[On-Prem] --DX--> [AWS DXGW] --[Cloud Exchange]--> [Azure ER] --> [Azure VNet]

AWS Configuration:
- Transit Gateway: 2600:1:0:0:1::/64
- Direct Connect Gateway: 2600:1:0:0:0::/64
- Attachment to VGW: 2600:1:0:0:2::/64

Azure Configuration:
- ExpressRoute Gateway: 3FFE:1:0:0:0::/64
- Virtual WAN Hub: 3FFE:1:0:0:1::/64
- VNet: 3FFE:1:0:1::/64

Cloud Exchange (Interconnect):
- Provider: Equinix/Intercloud
- SRv6 enabled on exchange switches
- SID: 2600:1:0:0:10::/64 (AWS side)
- SID: 3FFE:1:0:0:10::/64 (Azure side)

SID Translation at Exchange:
Ingress (from AWS):
  Outer DA: 2600:1:0:0:10::1
  Inner DA: 3FFE:1:0:0:1::1 (Azure)

  Translation:
  - Decapsulate outer SRH
  - Replace outer DA with 3FFE:1:0:0:10::1
  - Forward to Azure

Egress (from Azure):
  Outer DA: 3FFE:1:0:0:10::1
  Inner DA: 2600:1:0:0:1::1 (AWS)

  Translation:
  - Decapsulate outer SRH
  - Replace outer DA with 2600:1:0:0:10::1
  - Forward to AWS
```

### 27.4.2 AWS to GCP via SRv6

Cross-cloud path AWS to GCP:

```
AWS -> GCP SRv6 Path:

Architecture:
[On-Prem] --DX--> [AWS DXGW] --[Interconnect]--> [GCP Dedicated Interconnect] --> [GCP VPC]

GCP Configuration:
- Cloud Router: 2001:4860:0:1::/64 (BR)
- Dedicated Interconnect: 2001:4860:0:0::/64
- VPC: 2001:4860:1::/64

AWS-to-GCP Interconnect Options:
1. Cloud Exchange:
   - Same as AWS->Azure approach
   - SID translation at exchange

2. Direct Cloud-to-Cloud:
   - AWS TGW -> GCP Cloud Interconnect
   - Partner-provided link
   - Single SID namespace

Recommended: Cloud Exchange with SID Translation

SID Path: On-Prem -> AWS -> GCP
< fc00:0:1:0:0:0:0:1,    # On-Prem
  2600:1:0:0:0:0:0:1,    # AWS DXGW
  2600:1:0:0:1:0:0:1,    # AWS TGW
  2600:1:0:0:10:0:0:1,   # Cloud Exchange AWS side
  2001:4860:0:0:10:0:0:1,# Cloud Exchange GCP side
  2001:4860:0:1:0:0:0:1 ># GCP Cloud Router
```

### 27.4.3 Alibaba to Huawei Cloud via SRv6

Both Chinese cloud providers with full SRv6:

```
Alibaba -> Huawei Cloud SRv6 Path:

Advantage: Both use FC00::/8 SID block
- Alibaba: fc00:0:<region>::/40
- Huawei: fd00:<region>::/40

Direct Interconnection:
- Alibaba Cloud Connect partner
- Huawei CloudConnect partner
- Or enterprise with both clouds

Alibaba Cloud SID:
Region: cn-shanghai
Locator: fc00:0:2::/40
Node SID: fc00:0:2:0:0:0:0:1

Huawei Cloud SID:
Region: cn-east-1
Locator: fd00:0:1::/40
Node SID: fd00:0:1:0:0:0:0:1

Interconnect SID (partner):
Locator: fc00:0:99::/40 (shared interconnect)
Cross-connect: fc00:0:99:0:0:0:0:1

Path: Alibaba VPC -> Huawei VPC
SID List:
< fc00:0:2:0:0:0:0:1,    # Alibaba VSwitch
  fc00:0:99:0:0:0:0:1,    # Interconnect (Alibaba side)
  fd00:0:99:0:0:0:0:1,    # Interconnect (Huawei side)
  fd00:0:1:0:0:0:0:1 >    # Huawei VRouter

Benefit: No SID translation needed!
Both use FC00::/8 family - direct SRv6 path works.
```

## 27.5 Multi-Cloud Service Mesh Integration

### 27.5.1 Service Mesh Overview

Service mesh for multi-cloud:

```
Multi-Cloud Service Mesh Architecture:

Service Mesh Components:
1. Data Plane:
   - Sidecar proxies (Envoy)
   - Per-pod deployment
   - L7 traffic management

2. Control Plane:
   - Service discovery
   - Policy management
   - Security (mTLS)

Multi-Cloud Mesh Challenges:
- Different cloud provider load balancers
- Cross-cloud service discovery
- Consistent security policies
- Latency optimization

SRv6 + Service Mesh Integration:
- SRv6 for underlay transport
- Service mesh for L7 routing
- Combined: best of both worlds

Service Mesh Options:
1. Istio:
   - General-purpose
   - Cloud-native
   - Enterprise support (Red Hat)

2. Linkerd:
   - Simpler UX
   - CNCF graduated
   - Lower resource usage

3. AWS App Mesh:
   - AWS native
   - Envoy-based
   - X-Ray integration

4. Azure Service Fabric Mesh:
   - Azure native
   - Windows containers
   - ACID guarantees
```

### 27.5.2 SRv6-Aware Service Mesh

Integrating SRv6 with service mesh:

```
SRv6 + Service Mesh Architecture:

Mesh Extension for SRv6:
1. Sidecar Enhancement:
   - Envoy with SRv6 support
   - SRH insertion for egress
   - SID-based routing

2. Control Plane Integration:
   - Istio CRD for SRv6 policies
   - Global PCE for path computation
   - SID allocation to services

3. Security:
   - mTLS + SRv6 encryption option
   - Service identity in SID argument
   - Audit logging

Example: Multi-Cloud Microservice

Service: payment-api
- Pod in AWS us-east-1
- Pod in Azure eastus

SRv6 Path to payment-api in Azure:
< End.DX6@AWS-Sidecar,
  End.DX6@AWS-TGW,
  End.DX6@CloudEx-AWS,
  End.DX6@CloudEx-Azure,
  End.DX6@Azure-vWAN,
  End.DX6@Azure-Sidecar,
  End.DT6@Service-VRF >
  where SID argument contains: service=payment-api

Envoy Configuration for SRv6:
listeners:
- name: egress-srv6
  filter_chains:
  - filters:
    - name: envoy.filters.network.http_connection_manager
      typed_config:
        "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
        http_filters:
        - name: envoy.filters.http.srv6_policy
          typed_config:
            "@type": type.googleapis.com/envoy.extensions.filters.http.srv6_policy.v3.SRv6Policy
            sid_clusters:
              payment-api:
                - endpoint: 3FFE:1:0:0:1::1
                  weight: 100
                - endpoint: 2600:1:0:0:1::1
                  weight: 50
```

### 27.5.3 Cross-Cloud Service Discovery

Service discovery across clouds:

```
Multi-Cloud Service Discovery:

Challenge: Services in different clouds need to discover each other

Solution 1: Global DNS with SRv6:
- Cloud DNS (Route 53, Azure DNS, etc.)
- SRv6-aware DNS records
- Low-latency endpoint selection

DNS SRv6 Record:
payment-api.global.example.com. 300 IN SRV6 10 1 payment-api-alibaba
                                      2600:1::1:0:0:0:0:1
payment-api.global.example.com. 300 IN SRV6 10 1 payment-api-aws
                                      3FFE:1::1:0:0:0:0:1

Solution 2: Service Registry (Consul):
- HashiCorp Consul (multi-cloud)
- Centralized service catalog
- Health checking
- SRv6 SID as endpoint address

Consul Configuration:
service {
  name = "payment-api"
  id = "payment-api-1"
  port = 8080
  address = "2600:1::1"  # SRv6 SID
  meta {
    "srv6_sid" = "2600:1::1:0:0:0:0:1"
    "cloud" = "aws"
    "region" = "us-east-1"
  }
}

Solution 3: Kubernetes Federation:
- KubeFed for multi-cluster
- Sync services across clusters
- DNS via external-dns

KubeFed Config:
apiVersion: core.kubefed.io/v1beta1
kind: KubeFedConfig
metadata:
  name: kubefed
spec:
  scope: Namespaced
  controllerDuration:
    availableDelay: 20s
    unavailableDelay: 60s
  leaderElect:
    resourceName: kubefed-srv6-controller
    resourceNamespace: kube-federation-system
```

## 27.6 Multi-Cloud Traffic Engineering

### 27.6.1 Global TE Architecture

TE across multi-cloud:

```
Multi-Cloud Traffic Engineering:

TE Objectives:
1. Minimize Latency:
   - Route to nearest healthy endpoint
   - Avoid congested paths
   - Consider real-time latency

2. Maximize Throughput:
   - Balance load across clouds
   - Avoid bottleneck links
   - Consider bandwidth costs

3. Ensure Availability:
   - Multi-cloud redundancy
   - Automatic failover
   - TI-LFA protection

4. Optimize Cost:
   - Data transfer costs vary
   - Cloud egress pricing
   - Reserved capacity

TE Architecture:
[Global PCE]
    |
    +--BGP-LS--> [AWS TGW Topology]
    +--BGP-LS--> [Azure vWAN Topology]
    +--BGP-LS--> [GCP Cloud Router Topology]
    +--BGP-LS--> [On-Prem IGP]
    |
    v
[Global Traffic Engineering Database]
    |
    v
[Path Computation] --> [SID List]
    |
    v
[Policy Distribution] --> [Provider Controllers]
```

### 27.6.2 Application-Aware Steering

Steering traffic by application:

```
Application-Aware Multi-Cloud Steering:

Application Profiles:

1. Real-Time (VoIP/Video):
   - SLA: < 50ms latency
   - Priority: Highest
   - Path: Direct cloud interconnect
   - SID: Low-latency constrained

2. Transactional (Database):
   - SLA: < 20ms latency
   - Priority: High
   - Path: Primary region
   - SID: Minimize hops

3. Bulk (Analytics/Backup):
   - SLA: Best effort
   - Priority: Low
   - Path: Low-cost region
   - SID: Minimize cost

4. Disaster Recovery:
   - SLA: < 1hr RTO
   - Priority: Critical
   - Path: Cross-cloud DR
   - SID: DR-specific policy

Steering Configuration:

Policy: "VoIP-MultiCloud"
  Application: RTP (UDP 5000-6000)
  DSCP: EF (46)

  Candidate Paths:
  1. AWS -> Azure (low latency)
     SID: <2600:1::1, 2600:1:0:0:10::1, 3FFE:1::1>
     Latency: 25ms
     Cost: $0.05/GB

  2. AWS -> GCP (backup)
     SID: <2600:1::1, 2600:1:0:0:20::1, 2001:4860::1>
     Latency: 35ms
     Cost: $0.04/GB

  Selection: Path 1 (lower latency)
```

### 27.6.3 Failover and Protection

Multi-cloud protection mechanisms:

```
Multi-Cloud Protection:

TI-LFA in Multi-Cloud Context:

Challenge: TI-LFA typically works within IGP domain
           Multi-cloud spans multiple domains

Solution: Domain-Specific FRR + Global PCE

TI-LFA Per-Domain:
1. On-Prem domain: Local TI-LFA
2. AWS domain: AWS TGW built-in protection
3. Azure domain: vWAN built-in protection
4. GCP domain: Cloud Router protection

Cross-Domain Failover:
1. Failure detected at AWS TGW
2. PCE notified via telemetry
3. PCE recomputes path: AWS -> GCP -> Azure
4. New SID list distributed
5. Traffic rerouted in < 500ms

Failure Scenarios:

Scenario 1: AWS Region Failure
- Health check fails (Ping/TCP)
- Global PCE detects
- Routes to Azure/GCP directly
- SI list: <On-Prem, CloudEx-Azure, Azure-VNet>

Scenario 2: Cloud Interconnect Failure
- BFD down on interconnect
- Alternative interconnect path
- SI list updated to backup path

Scenario 3: On-Prem Firewall Failure
- Local switchover to backup DC
- Re-announce prefixes via BGP
- SID list updated

Global PCE Failover:
- Multiple PCE instances
- Leader election (Raft)
- State sync via etcd
- Sub-second failover
```

## 27.7 Deployment Patterns

### 27.7.1 Hub-and-Spoke Multi-Cloud

```
Hub-and-Spoke Pattern:

Architecture:
[On-Prem DC] <--Hub--> [Cloud Exchange]
                         |
           +-------------+-------------+-------------+
           |             |             |             |
           v             v             v             v
        [AWS]         [Azure]         [GCP]     [Alibaba]

Hub Components:
- Cloud Exchange at central location
- SRv6-enabled exchange switches
- Global PCE at hub
- SID translation at hub

SID List Examples:
On-Prem -> AWS:
< On-Prem, CloudEx, AWS-DXGW, AWS-VPC >

On-Prem -> Azure:
< On-Prem, CloudEx, Azure-ER, Azure-VNet >

On-Prem -> GCP:
< On-Prem, CloudEx, GCP-Interconnect, GCP-VPC >

Inter-Cloud (AWS -> Azure):
< AWS-TGW, CloudEx-AWS, CloudEx-Azure, Azure-vWAN, Azure-VNet >

Benefits:
- Single interconnection point
- Simplified management
- Consistent policies
- Cost-effective
```

### 27.7.2 Full-Mesh Multi-Cloud

```
Full-Mesh Pattern:

Architecture:
[On-Prem]
   |
   +---> [AWS Direct Connect]
   |
   +---> [Azure ExpressRoute]
   |
   +---> [GCP Dedicated Interconnect]
   |
   +---> [Alibaba Express Connect]

Each cloud has direct connection
No central hub required

Benefits:
- No single point of failure
- Lowest latency (direct)
- Maximum bandwidth
- Independent scaling

Costs:
- Higher interconnect costs
- More complex management
- More SID translation points

SID List (Inter-Cloud):
AWS -> Azure:
< AWS-TGW, AWS-DirectCloud, Azure-ER, Azure-VNet >

AWS -> GCP:
< AWS-TGW, AWS-Intercloud, GCP-Interconnect, GCP-VPC >
```

### 27.7.3 Hybrid Active-Active

```
Active-Active Multi-Cloud:

Architecture:
- Primary: AWS (us-east-1) + Azure (eastus)
- DR: GCP (us-central1) + Alibaba (cn-shanghai)
- All regions active

Traffic Split:
- 60% AWS (primary)
- 30% Azure (secondary)
- 10% GCP/Alibaba (dev/test)

SRv6 Weighted Steering:
Policy: "production-traffic"
  Weights:
    AWS: 60
    Azure: 30
    GCP: 10

  SID Lists:
  AWS:   <On-Prem, CloudEx, AWS-DX, AWS-VPC >
  Azure: <On-Prem, CloudEx, Azure-ER, Azure-VNet >
  GCP:   <On-Prem, CloudEx, GCP-Int, GCP-VPC >

  Load Balancing: Per-flow hash (5-tuple)

Failover Configuration:
1. AWS fails:
   - 60% shifts to Azure
   - 10% GCP unaffected
   - New split: Azure 90%, GCP 10%

2. Multiple failures:
   - GCP + Alibaba also fail
   - All traffic to Azure
   - DR site activated
```

## 27.8 Security Considerations

### 27.8.1 Multi-Cloud Security Model

```
Multi-Cloud SRv6 Security:

1. Network Segmentation:
   - Per-cloud VRF/VPC isolation
   - Cross-cloud segment policy
   - Zero-trust microsegmentation

2. Encryption:
   - SRv6 + IPsec (option)
   - MACsec on underlay
   - TLS for application

3. Identity:
   - SID as identity (uSID carrier)
   - BGP MD5 / TCP-AO for BGP
   - mTLS for service mesh

4. Compliance:
   - Data residency per cloud
   - Audit logging (all clouds)
   - SID traceability

Security Architecture:
[On-Prem Firewall] --> [Cloud Exchange FW] --> [Per-Cloud Firewall]
                            |
                            +--> [AWS: Security Group + NACL]
                            +--> [Azure: NSG + Firewall]
                            +--> [GCP: VPC Firewall]
```

### 27.8.2 Source Address Validation

```
SRv6 Source Address Validation:

Challenge: SRv6 packets can have spoofed source addresses
- SID in source address may not match originating domain
- Transit nodes need validation

Solution: Source Address Validation (SAV)

SAV Implementation:
1. uRPF (Unicast Reverse Path Forwarding):
   - Check source address against routing table
   - Strict mode: must have exact match
   - Loose mode: any route to source

2. SID Validation:
   - Validate SID block against allocator
   - Reject unknown SID blocks
   - Log and alert

3. BGPsec (Future):
   - Path validation
   - Origin validation
   - Cryptographic assurance

Per-Domain SAV:
On-Prem:
- uRPF on all interfaces
- IGP route validation

Cloud Provider:
- AWS: Source/Dest Check disabled, uRPF enabled
- Azure: UDR with nexthop validation
- GCP: Firewall rules + subnet-level checks

Cross-Cloud SAV:
- Cloud exchange validates SID blocks
- BGP prefix validation
- Community tag validation
```

## 27.9 Summary

```
Chapter 27 Summary:

Multi-Cloud SRv6 Benefits:
- End-to-end source routing across all providers
- Unified data plane (SRH standard)
- Programmable path selection
- Simplified operations

Challenges:
- SID block heterogeneity (2600::, 3FFE::, FC00::, etc.)
- SID translation at cloud interconnects
- Multi-domain TE
- Consistent security

End-to-End Architecture:
- Global PCE computes cross-cloud SID lists
- SID translation at cloud exchanges
- Provider-native transport for intra-cloud
- Unified telemetry

Cloud Interoperability:
- AWS <-> Azure: via Cloud Exchange
- AWS <-> GCP: via Dedicated Interconnect
- Alibaba <-> Huawei: direct (same FC00:: block)
- All providers: hub-and-spoke via Cloud Exchange

Service Mesh Integration:
- SRv6 underlay + Istio/Linkerd mesh
- SID as service locator
- Global DNS for service discovery
- Multi-cloud failover

Traffic Engineering:
- Global PCE for cross-cloud paths
- Per-cloud PCE for intra-cloud
- Application-aware steering
- TI-LFA per domain + PCE-driven failover

Deployment Patterns:
- Hub-and-spoke: Cloud Exchange at center
- Full-mesh: Direct connects to all clouds
- Active-active: Multiple clouds, weighted steering

Security:
- Per-cloud security groups
- SRv6 + IPsec option
- Source address validation
- Compliance via logging
```

---

## References

- IETF RFC 8986: SRv6 Network Programming
- IETF RFC 8754: IPv6 Segment Routing Header
- AWS Transit Gateway Route Manager Documentation
- Azure vWAN SRv6 Documentation
- GCP Cloud Router Documentation
- Alibaba Cloud CEN Documentation
- Huawei Cloud WAN Technical Whitepaper
- HashiCorp Consul Multi-Cloud Networking
- Istio SRv6 Extension Documentation
