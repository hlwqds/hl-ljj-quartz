---
title: "P4 深度探索 (四十)：阿里云网络可编程实践——自研 P4 交换机、Xihe 平台、高性能网络"
date: 2026-04-14
tags: [p4, series, alibaba, cloud, aliyun, network, programmable, xihe, self-developed, switch, hw]
description: "阿里云 P4 可编程网络深度解析——自研 P4 交换机 (Xihe)、高性能网络 (HG、Cargoo)、AliNOS P4 操作系统、负载均衡与流量调度、P4 在阿里云的实践"
---

> [!info] P4 深度探索系列 0. [[2026-04-14-p4-deep-dive-series-index|全栈学习路径总览]]
>
> 1. [[2026-04-14-p4-deep-dive-ch1-p4-overview|第一章：P4 概述]]
>    ...
> 2. [[2026-04-14-p4-deep-dive-ch39-huawei|第三十九章：华为网络可编程实践]]
> 3. **第四十章：阿里云网络可编程实践——自研 P4 交换机、Xihe 平台、高性能网络**

---

## 1. 阿里云网络架构概述

阿里云是中国最大的公有云服务商，其网络基础设施经历了从商用设备到自研设备的演进。阿里云在 P4 可编程网络方面主要体现在其 **自研交换机** 和 **Xihe** 网络平台上。

```
阿里云网络架构演进:
==================

  早期 (商用设备):
  ================
    商用交换机 -> 用户态网络 (DPDK) -> 软件定义

  当前 (自研设备):
  ================
    自研 P4 交换机 (Xihe) -> 硬件卸载 -> 软硬一体

  新一代 (HG Network):
  ====================
    HG 交换机 -> 400G/800G -> 端到端可编程
```

---

## 2. Xihe 自研 P4 交换机

### 2.1 Xihe 平台概述

**Xihe** (羲和) 是阿里云自研的数据中心交换机的代号：

```
Xihe 交换机架构:
================

  +--------------------------------------------------+
  |                   Xihe Switch                     |
  |                                                   |
  |  +----------+   +------------+   +------------+  |
  |  |  P4     |   |  Packet    |   |  Traffic   |  |
  |  |  Core   |<->|  Parser    |<->|  Manager   |  |
  |  |(Pipeline)|   +------------+   +------------+  |
  |  +----------+          |                   |       |
  |         |             |                   |       |
  |  +----------+   +------------+   +------------+  |
  |  |  TCAM    |   |   Hash     |   |  Queuing   |  |
  |  |  (ACL)   |   |   Engine   |   |  Engine   |  |
  |  +----------+   +------------+   +------------+  |
  |                                                   |
  |  +------------+   +------------+                 |
  |  |  Crypto   |   |   MAC      |                 |
  |  |  (IPSec)  |   |   PCS      |                 |
  |  +------------+   +------------+                 |
  +--------------------------------------------------+
```

### 2.2 Xihe 规格

| 型号     | 端口    | 交换容量 | P4 版本 | 特点       |
| -------- | ------- | -------- | ------- | ---------- |
| Xihe-100 | 64x100G | 12.8Tbps | P4-16   | 接入交换机 |
| Xihe-400 | 32x400G | 25.6Tbps | P4-16   | 汇聚交换机 |
| Xihe-800 | 64x400G | 51.2Tbps | P4-16   | 核心交换机 |

### 2.3 Xihe P4 流水线

```c
// Xihe P4 流水线
// 基于阿里云自研架构

#include <core.p4>
#include <xihe.p4>  // 阿里云 P4 扩展

// Xihe 自定义 Header
header xihe_metadata_t {
    bit<32>  tenant_id;        // 租户 ID
    bit<24>  vpc_id;           // VPC ID
    bit<8>   qos_class;        // QoS 类别
    bit<1>   is_encrypted;     // 是否加密
    bit<3>   reserved;
}

// Xihe Parser
parser XiheParser(
    packet_in pkt,
    out headers hdr,
    inout xihe_metadata_t meta,
    inout standard_metadata_t sm) {

    state start {
        pkt.extract(hdr.ethernet);
        transition select(hdr.ethernet.etherType) {
            0x0800:      parse_ipv4;
            0x86DD:      parse_ipv6;
            0x8100:     parse_vlan;
            0x8847:     parse_mpls;
            default:    accept;
        }
    }

    state parse_vlan {
        pkt.extract(hdr.vlan);
        transition select(hdr.vlan.ethertype) {
            0x0800:      parse_ipv4;
            default:    accept;
        }
    }
}

// VPC ACL 表
table vpc_acl_table {
    key = {
        hdr.ipv4.srcAddr:    lpm;     // 源地址 (CIDR)
        hdr.ipv4.dstAddr:    lpm;     // 目的地址
        hdr.tcp.srcPort:     range;   // 源端口范围
        hdr.tcp.dstPort:     range;   // 目的端口范围
        meta.vpc_id:         exact;   // VPC 隔离
    }
    actions = {
        permit;
        deny;
        permit_log;
    }
    default_action = deny;
}
```

---

## 3. HG 高性能网络

### 3.1 HG 网络架构

**HG (High Performance Grid)** 是阿里云的高性能计算网络：

```
HG 网络架构:
============

  +-----------+     +------------+     +-----------+
  |  ECS     |     |   HG      |     |  ECS      |
  |  (GPU)   |====>|  Switch   |====>|  (GPU)    |
  |  实例     |     |  (P4)     |     |  实例      |
  +-----------+     +------------+     +-----------+
         |                                     |
         |         RDMA (RoCEv2)               |
         +-------------------------------------+

  HG 特点:
  - 端到端 RDMA (RoCEv2)
  - 0.5us 延迟
  - 400Gbps 带宽
  - P4 可编程拥塞控制
```

### 3.2 HG P4 拥塞控制

```c
// HG RDMA P4 拥塞控制
// 基于 DCQCN / TIMELY

// HG Congestion Header
header hg_congestion_t {
    bit<8>   cong_event;       // 拥塞事件标志
    bit<16>  cong_timestamp;   // 时间戳
    bit<8>   qp_number;       // Queue Pair 号
    bit<16>  packet_number;   // 包序号
    bit<8>   priority;        // 优先级
}

// ECN 标记 (RoCEv2)
table ecn_roce_table {
    key = {
        sm.enq_q_depth:   range;   // 队列深度范围
        hdr.rocev2.ect:   exact;   // ECN 能力
    }
    actions = {
        mark_ce;          // 标记 CE
        mark_ect0;        // 保持 ECT
        drop;             // 丢包 (极端情况)
    }
    default_action = mark_ect0();
}

// RoCEv2 Priority Flow Control
table roce_pfc_table {
    key = {
        hdr.ethernet.vlan_pcp: exact;
    }
    actions = {
        enable_pfc;
        disable_pfc;
        set_pfc_xoff_threshold;
    }
}
```

### 3.3 HG 负载均衡

```c
// HG 负载均衡 P4 实现

// Flowlet 负载均衡
struct flowlet_metadata_t {
    bit<32>  last_switch_time;   // 上次切换时间
    bit<32>  current_path;        // 当前路径
    bit<16>  flowlet_gap;         // Flowlet 间隔
    bool     is_flowlet;         // 是否是新 Flowlet
}

// Flowlet 检测表
table flowlet_detect_table {
    key = {
        hdr.ipv4.srcAddr:   exact;
        hdr.ipv4.dstAddr:   exact;
        hdr.tcp.srcPort:    exact;
        hdr.tcp.dstPort:    exact;
    }
    actions = {
        update_flowlet_info;
        create_new_flowlet;
    }
}

// 路径选择表
table path_select_table {
    key = {
        meta.flow_hash:     range;  // Hash 值范围 -> 路径
        meta.flowlet_gap:   exact;  // Flowlet 间隔
    }
    actions = {
        select_path_0;
        select_path_1;
        select_path_2;
        select_path_3;
    }
    default_action = select_path_0();
}
```

---

## 4. 阿里云网络操作系统 AliNOS

### 4.1 AliNOS 架构

**AliNOS** 是阿里云的交换机网络操作系统：

```
AliNOS 架构:
===========

  +--------------------------------------------------+
  |                    AliNOS Platform                |
  |                                                   |
  |  +----------+  +----------+  +----------+        |
  |  |  CLI     |  |  gNMI    |  |  gRPC    |        |
  |  |  (VTYSH) |  |  (OpenConfig)|  |  (P4RT)  |        |
  |  +----------+  +----------+  +----------+        |
  |                                                   |
  |  +--------------------------------------------+  |
  |  |            P4 Runtime (PI)                  |  |
  |  +--------------------------------------------+  |
  |                                                   |
  |  +--------------------------------------------+  |
  |  |          AliNOS P4 Pipeline                |  |
  |  |                                             |  |
  |  |  +----------+  +----------+  +----------+  |  |
  |  |  |  Parser |  |  Match-  |  | Deparser |  |  |
  |  |  |         |->|  Action  |->|          |  |  |
  |  |  +----------+  +----------+  +----------+  |  |
  |  +--------------------------------------------+  |
  |                                                   |
  +--------------------------------------------------+
                          |
                          v
  +--------------------------------------------------+
  |              Xihe Hardware (P4 ASIC)              |
  +--------------------------------------------------+
```

### 4.2 AliNOS P4 支持

AliNOS 支持标准 P4-16 和阿里云扩展：

```c
// AliNOS P4 扩展
#include <alionos.p4>

// 阿里云网络功能
extern ali_hash_t {
    // 阿里云自定义 Hash 算法
    void compute_hash(
        out bit<32> hash_value,
        in HashAlgorithm algo,
        in bit<32> base,
        in something data
    );
}

extern ali_encrypt_t {
    // IPsec 加密卸载
    void encrypt_ipsec(
        inout headers hdr,
        in bit<32> key,
        out bit<128> icv
    );
}

// AliNOS 元数据
struct alinos_metadata_t {
    bit<32>  aliyun_vswitch_id;
    bit<24>  aliuyun_route_table_id;
    bit<16>  aliyun_security_group_id;
}
```

---

## 5. 阿里云 VPC 网络

### 5.1 VPC 架构

阿里云 VPC (Virtual Private Cloud) 使用 P4 实现网络虚拟化：

```
阿里云 VPC 架构:
===============

  +-----------+     +------------+     +-----------+
  |  ECS     |     |   vSwitch  |     |   Xihe   |
  |  实例     |---->|  (P4)      |---->|  Switch   |
  |          |     |            |     |           |
  +-----------+     +------------+     +-----------+
                           |                   |
                           v                   v
                    +------------+     +-----------+
                    |  VPC      |     |  Router   |
                    |  Gateway  |     |  (P4)     |
                    +------------+     +-----------+
```

### 5.2 vSwitch P4 实现

```c
// 阿里云 vSwitch P4 实现
// 在 Xihe TOR 上实现

// VPC Tunnel Header
header vpc_tunnel_t {
    bit<24>  vpc_id;            // VPC ID
    bit<8>   tunnel_type;       // 0: VXLAN, 1: GENEVE
    bit<32>  flow_id;           // Flow ID
    bit<16>  header_length;     // 头部长度
    bit<16>  reserved;
}

// VPC 路由表
table vpc_route_table {
    key = {
        hdr.ipv4.dstAddr:    lpm;    // 支持 /0 到 /32
        meta.vpc_id:         exact;
    }
    actions = {
        vpc_local_fwd;        // 本地转发
        vpc_remote_fwd;       // 远程转发 (跨交换机)
        vpc_drop;
    }
    default_action = vpc_drop();
}

// VPC 安全组表
table vpc_sg_table {
    key = {
        meta.security_group_id: exact;
        hdr.ipv4.srcAddr:        lpm;
        hdr.ipv4.dstAddr:        lpm;
        hdr.tcp.srcPort:         range;
        hdr.tcp.dstPort:         range;
        hdr.ipv4.protocol:       exact;
    }
    actions = {
        sg_permit;
        sg_deny;
        sg_log;
    }
}
```

### 5.3 NAT Gateway P4 实现

```c
// 阿里云 NAT Gateway P4 实现

// SNAT 表
table snat_table {
    key = {
        hdr.ipv4.srcAddr:  exact;     // 内部 IP
        hdr.tcp.srcPort:   exact;     // 内部端口
        meta.vpc_id:       exact;
    }
    actions = {
        snat_translate;              // SNAT
        no_snat;                     // 不做 SNAT
    }
}

// DNAT 表
table dnat_table {
    key = {
        // 公网 IP + 端口
        hdr.ipv4.dstAddr:    exact;     // 公网 IP
        hdr.tcp.dstPort:     exact;     // 公网端口
    }
    actions = {
        dnat_translate;              // DNAT
        dnat_drop;
    }
}

// NAT 元数据
struct nat_metadata_t {
    bit<32>  original_src_ip;     // 原始源 IP
    bit<32>  translated_src_ip;  // 翻译后源 IP
    bit<16>  original_src_port;  // 原始源端口
    bit<16>  translated_src_port;// 翻译后源端口
    bit<32>  nat_pool_id;        // NAT 池 ID
}
```

---

## 6. 负载均衡 (SLB)

### 6.1 阿里云 SLB 架构

**Server Load Balancer (SLB)** 是阿里云的负载均衡服务：

```
SLB 架构:
========

  +-----------+     +------------+     +-----------+
  |  Client   |     |    SLB     |     |  Backend  |
  |           |---->|  (P4)      |---->|  Server   |
  +-----------+     +------------+     +-----------+
                           |
                           v
                    +------------+
                    |  VIP       |
                    |  Manager   |
                    +------------+

  SLB 算法:
  - RR (Round Robin)
  - WRR (Weighted RR)
  - LC (Least Connections)
  -一致性 Hash
```

### 6.2 SLB P4 实现

```c
// SLB P4 负载均衡实现

// VIP 元数据
struct slb_vip_metadata_t {
    bit<32>  vip_addr;           // 虚拟 IP
    bit<16>  vip_port;          // 虚拟端口
    bit<32>  backend_count;     // 后端数量
    bit<32>  selected_backend;  // 选中的后端
    bit<8>   algorithm;         // 算法类型
}

// VIP 表
table slb_vip_table {
    key = {
        hdr.ipv4.dstAddr:    exact;   // VIP
        hdr.tcp.dstPort:     exact;   // 端口
    }
    actions = {
        select_backend_rr;         // 轮询
        select_backend_wrr;        // 加权轮询
        select_backend_hash;       // 一致性 Hash
        drop;
    }
}

// 一致性 Hash 表
table consistent_hash_table {
    key = {
        // Hash(src_ip, dst_ip, src_port, dst_port)
        hash_value: range;
    }
    actions = {
        select_backend_ring_0;
        select_backend_ring_1;
        select_backend_ring_2;
    }
    default_action = select_backend_ring_0();
}

// 后端选择器
table backend_select_table {
    key = {
        meta.backend_index: exact;
    }
    actions = {
        fwd_to_backend;
        health_check;
    }
}
```

---

## 7. 高速通道 (Express Connect)

### 7.1 Express Connect 架构

Express Connect 是阿里云的专线连接服务：

```
Express Connect 架构:
====================

  +-----------+     +------------+     +-----------+
  |  On-Prem |     |   PE       |     | 阿里云    |
  |  Network |====>|  Router    |====>|  vRouter  |
  |          |     |  (P4)      |     |  (P4)     |
  +-----------+     +------------+     +-----------+
                           |
                           | 专线
                           |
                           v
                    +------------+
                    |  Physical  |
                    |  Circuit   |
                    +------------+
```

### 7.2 专线 P4 实现

```c
// Express Connect P4 实现

// 隧道封装
header express_connect_t {
    bit<32>  tunnel_id;           // 隧道 ID
    bit<24>  vc_id;               // Virtual Circuit ID
    bit<8>   tunnel_type;         // MPLS/VXLAN
    bit<32>  sequence;            // 序列号
    bit<8>   flags;
}

// MPLS 标签栈
header mpls_stack_t {
    bit<20>  label;               // MPLS Label
    bit<3>   tc;                  // Traffic Class
    bit<1>   bos;                 // Bottom of Stack
    bit<8>   ttl;                 // TTL
}

// 专线路由表
table express_route_table {
    key = {
        hdr.mpls_stack[0].label: exact;
        meta.vc_id:               exact;
    }
    actions = {
        express_forward;
        express_label_swap;
        express_drop;
    }
}
```

---

## 8. 网络监控与安全

### 8.1 网络监控

阿里云使用 P4 INT 进行网络监控：

```c
// 网络遥测 P4 实现

// INT Header
header int_metadata_t {
    bit<2>   version;
    bit<2>   flags;
    bit<12>  reserved;
    bit<5>   remaining_hop;
    bit<5>   instructionBitmap;
}

// 遥测元数据
struct telemetry_metadata_t {
    bit<48>  ingress_timestamp;
    bit<48>  egress_timestamp;
    bit<32>  queue_id;
    bit<32>  queue_depth;
    bit<8>   port_id;
    bit<8>   congestion;
}

// 遥测收集表
table telemetry_collect {
    key = {
        hdr.ipv4.srcAddr:   exact;
        hdr.ipv4.dstAddr:   exact;
        hdr.tcp.srcPort:    exact;
        hdr.tcp.dstPort:    exact;
    }
    actions = {
        enable_int_collect;
        disable_int_collect;
    }
}
```

### 8.2 DDoS 防护

```c
// DDoS 防护 P4 实现

// 源认证表
table ddos_src_auth_table {
    key = {
        hdr.ipv4.srcAddr: exact;
    }
    actions = {
        challenge_init;       // 发起挑战
        challenge_pass;      // 通过
        block_src;           // 阻断
    }
}

// 流量限制表
table ddos_rate_limit_table {
    key = {
        hdr.ipv4.srcAddr:   exact;
        meta.flow_type:     exact;
    }
    actions = {
        allow;
        rate_limit;
        block;
    }
}

// 异常流量检测
table ddos_anomaly_table {
    key = {
        meta.packet_rate:   range;
        meta.bps_rate:      range;
        meta.connection_count: exact;
    }
    actions = {
        normal;
        suspicious;
        under_attack;
    }
}
```

---

## 9. 阿里云网络 API

### 9.1 OpenAPI 管理

阿里云网络服务通过 OpenAPI 管理：

```python
# 阿里云网络 OpenAPI
from aliyunsdkcore import client
from aliyunsdkvpc.request.v20160428 import CreateVpcRequest

def create_vpc(region_id, cidr_block):
    # 创建 VPC
    request = CreateVpcRequest.CreateVpcRequest()
    request.set_CidrBlock(cidr_block)
    request.set_VpcName('my-vpc')

    response = client.do_action_with_exception(request)
    return response

# 配置 NAT 网关
from aliyunsdkvpc.request.v20160428 import CreateNatGatewayRequest

def create_nat_gateway(vpc_id, bandwidth_package_ip):
    request = CreateNatGatewayRequest.CreateNatGatewayRequest()
    request.set_VpcId(vpc_id)
    request.set_BandwidthPackageId(bandwidth_package_ip)

    response = client.do_action_with_exception(request)
    return response
```

### 9.2 Terraform 支持

```hcl
# 阿里云网络 Terraform 配置

# VPC
resource "alicloud_vpc" "my_vpc" {
  vpc_name   = "my-vpc"
  cidr_block = "10.0.0.0/16"
}

# VSwitch
resource "alicloud_vswitch" "my_vswitch" {
  vpc_id     = alicloud_vpc.my_vpc.id
  cswitch_name = "my-vswitch"
  cidr_block = "10.0.1.0/24"
  zone_id    = "cn-hangzhou-i"
}

# 安全组
resource "alicloud_security_group" "my_sg" {
  name   = "my-security-group"
  vpc_id = alicloud_vpc.my_vpc.id
}

# 安全组规则
resource "alicloud_security_group_rule" "my_rule" {
  type              = "ingress"
  ip_protocol       = "tcp"
  nic_type          = "intranet"
  policy            = "accept"
  port_range        = "80/80"
  priority          = 1
  security_group_id = alicloud_security_group.my_sg.id
  cidr_ip          = "0.0.0.0/0"
}
```

---

## 10. 阿里云网络最佳实践

### 10.1 VPC 设计

```bash
# 阿里云 VPC 设计最佳实践
# 使用 VPC + VSwitch 分层设计

# 1. 创建 VPC
aliyun vpc CreateVpc \
    --RegionId cn-hangzhou \
    --CidrBlock 10.0.0.0/8

# 2. 创建 VSwitch (业务子网)
aliyun vpc CreateVSwitch \
    --VpcId vpc-xxxxx \
    --CidrBlock 10.0.1.0/24 \
    --ZoneId cn-hangzhou-i

# 3. 创建 VSwitch (数据库子网)
aliyun vpc CreateVSwitch \
    --VpcId vpc-xxxxx \
    --CidrBlock 10.0.2.0/24 \
    --ZoneId cn-hangzhou-j

# 4. 配置路由
aliyun vpc CreateRouteEntry \
    --RouteTableId vt-xxxxx \
    --DestinationCidrBlock 0.0.0.0/0 \
    --NextHopType NatGateway \
    --NextHopId ngw-xxxxx
```

### 10.2 网络性能优化

```bash
# 阿里云 ECS 网络优化

# 1. 启用 EIP 通信
aliyun eci CreateEIP \
    --Bandwidth 100 \
    --InternetChargeType PayByBandwidth

# 2. 配置 ENI (弹性网卡)
aliyun ecs CreateNetworkInterface \
    --SecurityGroupId sg-xxxxx \
    --VSwitchId vsw-xxxxx \
    --PrimaryIpAddress 10.0.1.10

# 3. 绑定 ENI 到 ECS
aliyun ecs AttachNetworkInterface \
    --NetworkInterfaceId eth-xxxxx \
    --InstanceId i-xxxxx

# 4. 查看网络监控
aliyun cms QueryMetricList \
    --Namespace acs_vpc_eip \
    --MetricName packets_in_rate
```

---

## 11. 总结

阿里云的 P4 可编程网络实践：

| 组件        | 技术           | 特点              |
| ----------- | -------------- | ----------------- |
| **Xihe**    | 自研 P4 交换机 | 12.8Tbps-51.2Tbps |
| **HG**      | RDMA/RoCEv2    | 0.5us 延迟        |
| **AliNOS**  | P4+C 混合 OS   | 统一网络 OS       |
| **vSwitch** | P4 VXLAN       | VPC 虚拟化        |
| **SLB**     | P4 负载均衡    | 多算法支持        |

阿里云通过自研 P4 交换机和 HG 高性能网络，实现了从商用设备到软硬一体的转型，为云原生和 AI 工作负载提供了强大的网络基础设施。

---

## 参考资料

- Xihe Whitepaper: Alibaba Cloud Self-Developed Switch
- HG Network: High Performance Computing Network
- AliNOS Documentation
- 阿里云网络产品文档
