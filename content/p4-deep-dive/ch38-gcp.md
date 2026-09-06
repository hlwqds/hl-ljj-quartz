---
title: "P4 深度探索 (三十八)：GCP 网络可编程实践——Andromeda 软件定义网络、Jupiter Fabric、Espresso 边缘"
date: 2026-04-14
tags:
  [p4, series, gcp, cloud, andromeda, jupiter, network, programmable, software-defined, espresso]
description: "GCP P4 可编程网络深度解析——Andromeda 软件定义网络架构、Jupiter Fabric 96Tbps 单 clos 平面、Espresso 边缘网络、gRPC 配置管理、VPC 路由、P4 on GCP"
---

> [!info] P4 深度探索系列 0. [[p4-deep-dive|全栈学习路径总览]]
>
> 1. [[ch1-p4-overview|第一章：P4 概述]]
>    ...
> 2. [[ch36-aws|第三十六章：AWS 网络可编程实践]]
> 3. [[ch37-azure|第三十七章：Azure 网络可编程实践]]
> 4. **第三十八章：GCP 网络可编程实践——Andromeda、Jupiter Fabric、Espresso**

---

## 1. GCP 网络架构概述

Google Cloud Platform (GCP) 的网络基础设施以其自研软件定义网络著称。GCP 使用 **Andromeda** 作为其 SDN 控制平面，配合 **Jupiter Fabric** 物理网络，提供高达 96Tbps 的单 Clos 平面带宽。

```
GCP 网络架构:
============

  +-----------+     +-------------+     +-------------+
  |  GCP     |     |  Andromeda  |     |  Jupiter    |
  |  VMs     |---->|  (SDN)      |---->|  Fabric     |
  |          |     |  Control    |     |  (Physical) |
  +-----------+     +-------------+     +-------------+
                           |                   |
                           v                   v
                    +------------+     +-----------+
                    |  Espresso  |     |  BwEnf    |
                    |  (Edge)    |     |  (P4)     |
                    +------------+     +-----------+
```

---

## 2. Andromeda 软件定义网络

### 2.1 Andromeda 架构

**Andromeda** 是 Google 内部开发的 SDN 系统，为 GCP 提供虚拟网络：

```
Andromeda 架构:
===============

  +-----------+     +-------------+     +-------------+
  |  VM      |     |  Andromeda  |     |  Jupiter    |
  |  (Guest) |<--->|  Agent      |<--->|  Gateway    |
  +-----------+     +-------------+     +-------------+
         |                  |                   |
         |                  v                   |
         |           +-------------+            |
         |           |  Andromeda  |            |
         |           |  Controller |            |
         |           |  (CCP)      |            |
         |           +-------------+            |
         |                  |                   |
         v                  v                   v
  +-----------+     +-------------+     +-----------+
  |  OVS      |     |   ZooKeeper|     |  GRPC     |
  |  (DPDK)   |     |  (Cluster) |     |  (Config) |
  +-----------+     +-------------+     +-----------+

  组件说明:
  - Andromeda Agent: 运行在每个主机上
  - CCP (Central Control Plane): 集中式控制平面
  - GRPC: 配置下发通道
  - ZooKeeper: 集群状态管理
```

### 2.2 Andromeda 数据面

```c
// Andromeda 数据面 (基于 OVS-DPDK)
// 运行在每个计算节点上

// Flow 表结构
struct andromeda_flow_table {
    // Table 0: 分类
    uint32_t priority;
    uint8_t  protocol;
    uint32_t src_ip;
    uint32_t dst_ip;
    uint16_t src_port;
    uint16_t dst_port;

    // Actions
    uint8_t  action;      // FORWARD/DROP/MIRROR
    uint32_t tunnel_id;
    uint32_t next_hop;
};

// 处理流程
// 1. Parse packet headers
// 2. Match flow table
// 3. Apply actions (encap/decap/forward)
```

### 2.3 Andromeda 与 P4

虽然 Andromeda 主要基于 OVS-DPDK，GCP 也在关键路径上使用 P4：

```c
// GCP P4 程序片段 (简化)
// 实现 Andromeda 封装和 ACL

#include <core.p4>
#include <tna.p4>

// Andromeda Tunnel Header
header andromeda_t {
    bit<32>  tunnel_id;       // VNI
    bit<28>  flow_id;
    bit<4>   flags;
    bit<32>  metadata;
}

// ACL 元数据
struct acl_meta_t {
    bool     acl_permit;
    bool     logged;
    bit<32>  rule_id;
}

// ACL 规则表
table gcp_acl_table {
    key = {
        hdr.ipv4.srcAddr:    lpm;     // CIDR 支持
        hdr.ipv4.dstAddr:    lpm;
        hdr.tcp.srcPort:     range;   // 端口范围
        hdr.tcp.dstPort:     range;
        hdr.ipv4.protocol:   exact;
    }
    actions = {
        permit;
        deny;
        permit_and_log;
    }
}

// Tunnel 封装表
table tunnel_encap_table {
    key = {
        meta.tunnel_id: exact;
    }
    actions = {
        encap_andromeda;
        encap_vxlan;
        encap_geneve;
        no_encap;
    }
}
```

---

## 3. Jupiter Fabric

### 3.1 Jupiter 架构

**Jupiter** 是 Google 数据中心的 Clos 网络架构，提供高达 **96Tbps** 的单平面带宽：

```
Jupiter Clos 架构:
=================

         +---------+     +---------+     +---------+
         | Spine   |---->| Spine   |<----| Spine   |
         +---------+     +---------+     +---------+
              |               |               |
    +---------+---------+---------+---------+---------+
    |         |         |         |         |         |
    v         v         v         v         v         v
 +------+ +------+ +------+ +------+ +------+ +------+
 | Aggr  | | Aggr  | | Aggr  | | Aggr  | | Aggr  | | Aggr  |
 +------+ +------+ +------+ +------+ +------+ +------+
    |         |         |         |         |         |
    +---------+---------+---------+---------+---------+
                        |
            +-----------+-----------+
            |           |           |
            v           v           v
         +------+   +------+   +------+
         | Tor   |   | Tor   |   | Tor  |
         +------+   +------+   +------+

  层次:
  - Spine: 96 x 400Gbps (双向 192Tbps)
  - Aggregation: 互联 Spine 和 TOR
  - TOR (Top of Rack): 连接到服务器的交换机
```

### 3.2 Jupiter 单 Clos 平面

Jupiter 的创新在于实现 **Single CLOS** 架构，所有交换机在同一平面：

```
Jupiter Single CLOS:
====================

  特性:
  - 所有交换机对等 (No hierarchy)
  - 任意两个节点之间只有 2 跳
  - 支持 100K+ 服务器
  - 带宽: 96Tbps aggregate

  路由协议:
  - 基于 IP Spine
  - BGP as IGP (EIGRP/IS-IS 风格)
  - ECMP 多路径
```

### 3.3 Jupiter P4 流水线

```c
// Jupiter P4 流水线 (Tofino)
// 实现 L2/L3 转发和负载均衡

#include <core.p4>
#include <tna.p4>

// Jupiter 自定义 Header
header jupiter_metadata_t {
    bit<1>   is_local;
    bit<1>   is_bcast;
    bit<14>  vlan_id;
    bit<16>  ether_type;
}

// RACL (Router ACL) 表
table jracl_table {
    key = {
        hdr.ipv4.srcAddr:    lpm;
        hdr.ipv4.dstAddr:    lpm;
        hdr.tcp.srcPort:     range;
        hdr.tcp.dstPort:     range;
    }
    actions = {
        racl_permit;
        racl_deny;
        racl_permit_log;
    }
}

// ECMP 负载均衡
table jecmp_table {
    key = {
        hdr.ipv4.srcAddr:    exact;
        hdr.ipv4.dstAddr:    exact;
        hdr.ipv4.protocol:   exact;
        hdr.tcp.srcPort:     exact;
        hdr.tcp.dstPort:     exact;
    }
    actions = {
        fwd_to_spine_1;
        fwd_to_spine_2;
        fwd_to_spine_3;
        fwd_to_spine_4;
    }
    default_action = fwd_to_spine_1();
}

// BUM 流量处理 (Broadcast/Unknown Unicast/Multicast)
table jbum_table {
    key = {
        hdr.ethernet.dstAddr: exact;
    }
    actions = {
        flood;
        fwd_to_port;
        no_flood;
    }
}
```

---

## 4. Espresso 边缘网络

### 4.1 Espresso 架构

**Espresso** 是 GCP 的边缘网络系统，为 GCP 区域提供网络出口：

```
Espresso 架构:
=============

  +-----------+     +------------+     +-----------+
  |  GCP     |     |  Espresso  |     |  External |
  |  Region  |---->|  Peering   |---->|  Internet |
  |  Network |     |  (Edge)    |     |           |
  +-----------+     +------------+     +-----------+
                           |
                           v
                    +------------+
                    |  Peering  |
                    |  Router   |
                    |  (P4)     |
                    +------------+
```

### 4.2 Espresso P4 功能

Espresso 使用 P4 实现以下功能：

| 功能                 | 描述         | P4 表    |
| -------------------- | ------------ | -------- |
| **BGP Route Server** | BGP 路由服务 | 路由表   |
| **Route Filtering**  | 路由过滤     | ACL 表   |
| **Traffic Policing** | 流量监管     | Meter 表 |
| **NAT**              | 网络地址转换 | NAPT 表  |
| **Load Balancing**   | 负载均衡     | Hash 表  |

```c
// Espresso P4 NAT 实现
#include <core.p4>
#include <tna.p4>

// NAT 元数据
struct nat_metadata_t {
    bit<32>  original_src;    // 原始源 IP
    bit<32>  translated_src;   // 翻译后源 IP
    bit<16>  original_sport;   // 原始源端口
    bit<16>  translated_sport; // 翻译后源端口
    bool     is_nat_enabled;
}

// NAT 翻译表
table nat_table {
    key = {
        hdr.ipv4.srcAddr:  exact;
        hdr.tcp.srcPort:   exact;
    }
    actions = {
        do_nat;
        no_nat;
    }
}

// 外部流量入口处理
control EspressoIngress(
    inout headers hdr,
    inout nat_metadata_t nat_meta,
    inout standard_metadata_t sm) {

    // NAT 处理
    table nat_lookup {
        key = {
            hdr.ipv4.srcAddr:  exact;
            hdr.tcp.srcPort:   exact;
        }
        actions = {
            translate_src_ip;
            translate_port;
            no_translate;
        }
    }

    // BGP 路由查找
    table bgp_rib {
        key = {
            hdr.ipv4.dstAddr: lpm;   // Longest Prefix Match
        }
        actions = {
            fwd_to_region;
            fwd_to_internet;
            fwd_to_peering;
        }
    }

    // 流量监管
    meter traffic_meter {
        meter_type: bytes;
        rate_type: pir;           // Peak Information Rate
        cbs: 1000000;             // Committed Burst Size
        pir: 1000000000;          // 1 Gbps
    }

    apply {
        nat_lookup.apply();
        bgp_rib.apply();
    }
}
```

---

## 5. GCP VPC 网络

### 5.1 VPC 架构

GCP Virtual Private Cloud (VPC) 提供软件定义的隔离网络：

```
GCP VPC 架构:
============

  +-----------+     +------------+     +-----------+
  |  GCP     |     |   VPC      |     |  Jupiter  |
  |  VM      |---->|   Router   |---->|  Fabric   |
  |          |     |  (Google)  |     |           |
  +-----------+     +------------+     +-----------+
       |                  |                  |
       |                  v                  v
  +-----------+     +------------+     +-----------+
  |  vNIC    |     |   Routes   |     |   P4      |
  |  (gVNIC) |     |   (SDN)    |     |  Pipeline |
  +-----------+     +------------+     +-----------+
```

### 5.2 VPC 路由

GCP VPC 使用分布式路由模型：

```python
# GCP VPC 路由配置
# 使用 gcloud CLI

# 创建自定义路由
gcloud compute routes create my-route \
    --network my-vpc \
    --destination-range 10.0.0.0/24 \
    --next-hop-gateway internet-gateway

# 创建 VPN 隧道路由
gcloud compute routes create vpn-route \
    --network my-vpc \
    --destination-range 192.168.0.0/16 \
    --next-hop-vpn-tunnel my-vpn-tunnel

# 查看路由表
gcloud compute routes list --filter="network:my-vpc"
```

### 5.3 GCP P4 VPC 实现

```c
// GCP VPC P4 实现
// 在 Jupiter TOR 上实现

// VPC 封装
header vpc_encap_t {
    bit<24>  vpc_id;            // VPC 标识
    bit<8>   tenant_id;         // 租户 ID
    bit<32>  flow_id;           // Flow 标识
}

// VPC 路由表
table vpc_route_table {
    key = {
        hdr.ipv4.dstAddr:    lpm;    // 支持 /0 到 /32
        meta.vpc_id:         exact;
    }
    actions = {
        vpc_fwd;
        vpc_drop;
        vpc_to_internet;
    }
}

// VPC ACL 表
table vpc_acl_table {
    key = {
        hdr.ipv4.srcAddr:    lpm;
        hdr.ipv4.dstAddr:    lpm;
        hdr.tcp.srcPort:     range;
        hdr.tcp.dstPort:     range;
        meta.tenant_id:      exact;
    }
    actions = {
        vpc_permit;
        vpc_deny;
        vpc_log;
    }
}
```

---

## 6. GCP 网络管理

### 6.1 gRPC 配置管理

GCP 使用 gRPC 进行网络设备配置管理：

```protobuf
// GCP Network gRPC API
// 定义网络配置服务

service NetworkConfigService {
    // 获取设备配置
    rpc GetConfig(GetConfigRequest) returns (GetConfigResponse);

    // 更新设备配置
    rpc UpdateConfig(UpdateConfigRequest) returns (UpdateConfigResponse);

    // 订阅配置变更
    rpc SubscribeConfig(SubscribeRequest) returns (stream ConfigChange);
}

// VLAN 配置消息
message VlanConfig {
    string vlan_name = 1;
    uint32 vlan_id = 2;
    repeated string ports = 3;
    string vlan_type = 4;  // "ACCESS" or "TRUNK"
}

// 路由配置消息
message RouteConfig {
    string route_name = 1;
    string destination_cidr = 2;
    string next_hop_ip = 3;
    uint32 next_hop_interface_id = 4;
    uint32 metric = 5;
}
```

```python
# GCP 网络配置客户端
import grpc
from network_config_pb2 import *
from network_config_pb2_grpc import NetworkConfigServiceStub

def configure_vlan(stub, vlan_name, vlan_id, ports):
    request = UpdateConfigRequest()
    request.vlan_config.vlan_name = vlan_name
    request.vlan_config.vlan_id = vlan_id
    request.vlan_config.ports.extend(ports)

    response = stub.UpdateConfig(request)
    return response.status

# 使用 gRPC 通道
channel = grpc.secure_channel(
    'router.googleapis.com:443',
    credentials=grpc.ssl_channel_credentials()
)
stub = NetworkConfigServiceStub(channel)
```

### 6.2 网络遥测

GCP 使用 P4 INT (In-band Network Telemetry) 进行网络监控：

```c
// GCP 网络遥测 P4 实现

// INT Header
header int_t {
    bit<2>   version;
    bit<2>   flags;
    bit<12>  reserved;
    bit<5>   hop_metadata_len;
    bit<5>   remaining_hop_count;
}

// 遥测元数据 (每跳添加)
header int_hop_metadata_t {
    bit<48>  ingress_timestamp;
    bit<48>  egress_timestamp;
    bit<32>  queue_depth;
    bit<8>   congestion_ecn;
}

// 遥测收集表
table telemetry_collect_table {
    key = {
        hdr.ipv4.srcAddr:    exact;
        hdr.ipv4.dstAddr:    exact;
        hdr.tcp.srcPort:     exact;
        hdr.tcp.dstPort:     exact;
    }
    actions = {
        enable_telemetry;
        disable_telemetry;
    }
}

// 导出遥测数据
table telemetry_export_table {
    key = {
        meta.telemetry_enabled: exact;
    }
    actions = {
        export_to_collector;
        no_export;
    }
}
```

---

## 7. GCP 网络安全

### 7.1 GCP 防火墙

GCP VPC 防火墙使用 P4 ACL 实现：

```c
// GCP Firewall P4 实现
struct firewall_metadata_t {
    bit<32>  firewall_rule_id;
    bit<8>   priority;          // 优先级 (越小越高)
    bit<8>   action;           // ALLOW/DENY
    bool     log_enabled;
}

// Firewall 规则表
table gcp_firewall_table {
    key = {
        // 源过滤
        hdr.ipv4.srcAddr:    lpm;     // 支持网络范围
        meta.source_tag:     exact;   // GCP 标签
        meta.source_sa:      exact;   // 服务账号

        // 目的过滤
        hdr.ipv4.dstAddr:    lpm;
        meta.dest_tag:       exact;
        meta.dest_sa:        exact;

        // 四层过滤
        hdr.ipv4.protocol:   exact;
        hdr.tcp.srcPort:     range;
        hdr.tcp.dstPort:     range;
    }
    actions = {
        allow;
        deny;
        allow_log;
    }
    default_action = deny;
}
```

### 7.2 Cloud Armor

Cloud Armor 是 GCP 的 DDoS 防护和 WAF 服务：

```c
// Cloud Armor P4 实现
// 在边缘网络上实现

struct cloud_armor_metadata_t {
    bit<32>  policy_id;
    bit<16>  rule_id;
    bit<8>   action;           // ALLOW/DENY/LOG/REDIRECT
    bit<8>   rule_priority;
}

// 速率限制表
table rate_limit_table {
    key = {
        hdr.ipv4.srcAddr:    exact;   // 按 IP 限速
        meta.rate_limit_key: exact;  // 自定义 Key
    }
    actions = {
        allow;
        rate_limit;
        block_and_log;
    }
}

// 地理围栏表
table geo_filter_table {
    key = {
        meta.geo_id: exact;         // 国家/地区代码
    }
    actions = {
        allow;
        deny;
        redirect;
    }
}

// 攻击特征检测表
table attack_signature_table {
    key = {
        hdr.http.uri:        ternary;  // URL 特征
        hdr.http.user_agent: ternary;  // UA 特征
        hdr.tcp.payload:     ternary;  // 负载特征
    }
    actions = {
        detect_attack;
        allow;
    }
}
```

---

## 8. GCP Anthos 网络

### 8.1 Anthos 架构

Anthos 是 GCP 的混合云和多云管理平台：

```
Anthos 网络架构:
===============

  +-----------+     +------------+     +-----------+
  |  GKE     |     |  Anthos    |     |  On-Prem  |
  |  Cluster |---->|  Config    |---->|  K8s      |
  |  (GCP)   |     |  Sync      |     |  Cluster  |
  +-----------+     +------------+     +-----------+
                           |
                           v
                    +------------+
                    |  Anthos    |
                    |  Service   |
                    |  Mesh      |
                    +------------+
```

### 8.2 Anthos 网络策略

```yaml
# Anthos Network Policy (GKE)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: api-access
  namespace: production
spec:
  podSelector:
    matchLabels:
      app: api
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              role: frontend
      ports:
        - protocol: TCP
          port: 443
  egress:
    - to:
        - podSelector:
            matchLabels:
              role: database
      ports:
        - protocol: TCP
          port: 5432
```

---

## 9. GCP 网络最佳实践

### 9.1 VPC 设计

```bash
# GCP VPC 设计最佳实践
# 使用分层 VPC 模型

# 1. 创建 Shared VPC (Host Project)
gcloud compute shared-vpc enable host-project my-host-project

# 2. 创建 VPC (Region)
gcloud compute networks create my-vpc \
    --bgp-routing-mode regional

# 3. 创建子网
gcloud compute networks subnets create my-subnet \
    --network my-vpc \
    --region us-central1 \
    --range 10.0.0.0/24

# 4. 配置 Cloud NAT
gcloud compute routers create my-router \
    --network my-vpc \
    --region us-central1

gcloud compute routers nats create my-nat \
    --router my-router \
    --region us-central1 \
    --auto-allocate-nat-external-ips \
    --nat-all-subnet-ip-ranges
```

### 9.2 性能优化

```bash
# GCP VM 网络优化

# 1. 使用 gVNIC 驱动 (GPU/高性能 VM)
gcloud compute instances create my-instance \
    --image-family=cos-85-lts \
    --image-project=cos-cloud \
    --machine-type n2-standard-16 \
    --network-interface nic-type=GVNIC

# 2. 启用 IP 伪播 (IP masquerading)
gcloud compute instances create my-instance \
    --scopes cloud-platform

# 3. 配置负载均衡
gcloud compute backend-services create my-backend \
    --protocol TCP \
    --health-checks my-health-check

gcloud compute target-pools create my-pool \
    --region us-central1 \
    --backend-service my-backend
```

---

## 10. 总结

GCP 的 P4 可编程网络实践：

| 组件            | 技术          | P4 用途            |
| --------------- | ------------- | ------------------ |
| **Andromeda**   | OVS-DPDK + P4 | SDN 控制面         |
| **Jupiter**     | Tofino P4     | 96Tbps Clos Fabric |
| **Espresso**    | P4            | 边缘网络/NAT       |
| **VPC**         | P4 ACL        | 虚拟网络隔离       |
| **Cloud Armor** | P4            | DDoS 防护          |

GCP 通过 Andromeda + Jupiter 的组合，实现了高度可扩展和可编程的网络基础设施。
