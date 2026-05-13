---
title: "P4 深度探索 (三十三)：P4 VLAN/VXLAN 编程——VLAN Tagging、VXLAN Tunnel、Overlay/Underlay 网络"
date: 2026-04-14
tags: [p4, series, vlan, vxlan, overlay, underlay, network-virtualization, tunnel, p4-16]
description: "P4 VLAN/VXLAN 编程深度解析——802.1Q VLAN Tagging、Native VLAN vs Q-in-Q、VXLAN Tunnel、Overlay/Underlay 网络分离、VTEP 封装/解封装、EVPN 集成"
---

> [!info] P4 深度探索系列 0. [[2026-04-14-p4-deep-dive-series-index|全栈学习路径总览]]
>
> 1. [[2026-04-14-p4-deep-dive-ch1-p4-overview|第一章：P4 概述——诞生背景与协议无关包处理]]
> 2. [[2026-04-14-p4-deep-dive-ch2-p4-architecture|第二章：P4 架构模型——PSA/V1Model、Ingress/Egress]]
> 3. [[2026-04-14-p4-deep-dive-ch3-p4-vs-ebpf|第三章：P4 vs eBPF——适用场景与硬件/软件对比]]
>    ...
> 4. [[2026-04-14-p4-deep-dive-ch30-p4-control-plane-advanced|第三十章：P4 控制面高级主题]]
> 5. [[2026-04-14-p4-deep-dive-ch31-basic-routing|第三十一章：P4 基础路由编程]]
> 6. [[2026-04-14-p4-deep-dive-ch32-access-list|第三十二章：P4 ACL 编程]]
> 7. **第三十三章：P4 VLAN/VXLAN 编程——VLAN Tagging、VXLAN Tunnel、Overlay/Underlay**

---

## 1. 概述：网络虚拟化概述

**网络虚拟化**通过**Overlay 网络**在物理网络 (Underlay) 之上构建**逻辑网络**，实现：

- **多租户隔离**：不同租户使用不同的虚拟网络
- **弹性扩展**：虚拟机/容器可任意迁移
- **自动化**：网络配置与物理位置解耦

```
Overlay/Underlay 双层网络架构:
==============================

  Overlay (虚拟网络)                    Underlay (物理网络)
  +-------------------+                  +-------------------+
  | Tenant A: 10.0.1.x |                  |                   |
  | Tenant B: 10.0.2.x |                  |   Spine/Leaf     |
  | Tenant C: 10.0.3.x |                  |   物理交换机       |
  +-------------------+                  |                   |
           |                              +-------------------+
           | VXLAN Tunnel                        |
           v                                      v
  +-------------------+                  +-------------------+
  |      VTEP         | <--------------->|      VTEP         |
  | (VXLAN Tunnel End) |    物理网络      |                   |
  +-------------------+                  +-------------------+
```

### 1.1 VLAN vs VXLAN

| 特性              | VLAN             | VXLAN              |
| ----------------- | ---------------- | ------------------ |
| **ID 空间**       | 12-bit (4,094)   | 24-bit (16M)       |
| **网络范围**      | L2广播域**本地** | L2广播域**跨网络** |
| **封装**          | 802.1Q Tag       | UDP + VXLAN Header |
| **Underlay 依赖** | 无               | 需要 IP 网络       |
| **典型用途**      | 数据中心接入     | 多租户/跨 Pod      |

---

## 2. VLAN 编程

### 2.1 802.1Q VLAN Header

```
802.1Q VLAN Tag (4 bytes):
==========================

  0                   1                   2                   3
  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
 +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 | TPID (0x8100) |  PCP  |DEI|        VID (VLAN ID)              |
 +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

 - TPID: 0x8100 (Tag Protocol Identifier)
 - PCP:  Priority Code Point (3-bit, 802.1p QoS)
 - DEI:  Drop Eligibility Indicator (1-bit)
 - VID:  VLAN ID (12-bit, 0-4095)
```

### 2.2 P4 VLAN Header 定义

```c
// VLAN Header (802.1Q)
header vlan_t {
    bit<16> tpid;      // 0x8100
    bit<3>  pcp;       // Priority Code Point (802.1p)
    bit<1>  dei;       // DEI/CFI
    bit<12> vid;       // VLAN ID (0-4095)
}

// QinQ (双重 VLAN Tag, 802.1ad)
header stacked_vlan_t {
    bit<16> tpid;      // 0x8100 (内层)
    bit<3>  pcp;
    bit<1>  dei;
    bit<12> vid;       // S-VLAN (Service VLAN)

    bit<16> tpid2;     // 0x8100 或 0x88A8 (外层)
    bit<3>  pcp2;
    bit<1>  dei2;
    bit<12> vid2;      // C-VLAN (Customer VLAN)
}
```

### 2.3 VLAN Parser

```c
// VLAN-aware Parser
parser parse_vlan(packet_in packet,
                  out headers hdr) {

    state start {
        transition parse_ethernet;
    }

    state parse_ethernet {
        packet.extract(hdr.ethernet);
        transition select(hdr.ethernet.etherType) {
            0x8100:  parse_vlan;           // VLAN Tagged
            0x9100:  parse_qinq;           // QinQ (legacy)
            0x9200:  parse_qinq;           // QinQ (another TPID)
            0x88A8:  parse_qinq;           // QinQ (802.1ad)
            default: accept;               // Untagged
        }
    }

    state parse_vlan {
        packet.extract(hdr.vlan);
        // 根据 VLAN VID 决定后续处理
        // 例如: VID 4095 用于 CPU/Special
        transition select(hdr.vlan.vid) {
            4095: parse_special;           // 控制流量
            default: parse_ipv4;           // 普通流量
        }
    }

    state parse_qinq {
        packet.extract(hdr.stacked_vlan);
        transition parse_ipv4;
    }
}
```

### 2.4 VLAN Ingress 处理

```c
// VLAN 处理 Control
control vlan_ingress(inout headers hdr,
                    inout metadata_t meta) {

    // VLAN 表: VID -> VLAN 动作
    table vlan_lookup {
        key = {
            hdr.vlan.vid: exact;  // VLAN ID
        }
        actions = {
            vlan_permit;          // 允许
            vlan_drop;            // 丢弃 (未授权 VLAN)
            vlan_learn;           // 触发 MAC 学习
        }
    }

    // VLAN 成员端口表
    table vlan_member {
        key = {
            hdr.vlan.vid:   exact;
            // egress_port 来自 standard_metadata
        }
        actions = {
            allow;               // 端口是该 VLAN 成员
            deny;                // 端口不是该 VLAN 成员
        }
    }

    action vlan_permit() {
        // 设置内部元数据
        meta.vlan_id = hdr.vlan.vid;
        meta.vlan_pcp = hdr.vlan.pcp;
    }

    action vlan_drop() {
        // 丢弃不属于该 VLAN 的流量
        // 已在 vlan_member 表中过滤
    }

    apply {
        // 检查 VLAN 是否授权
        // ...
    }
}
```

### 2.5 VLAN Egress 处理

```c
// VLAN Egress Control
control vlan_egress(inout headers hdr,
                    inout metadata_t meta) {

    // VLAN 转换表
    table vlan_transform {
        key = {
            meta.ingress_vlan: exact;   // 原始 VLAN
            meta.egress_vlan:  exact;   // 目标 VLAN
        }
        actions = {
            // VLAN 转换动作
            vlan_swap;             // 交换内外层 VLAN
            vlan_add;              // 添加 VLAN Tag
            vlan_remove;           // 移除 VLAN Tag
            vlan_promote;          // QinQ -> Single Tag
        }
    }

    apply {
        if (hdr.vlan.isValid()) {
            // VLAN Tag 处理
        }
    }
}
```

---

## 3. VXLAN 编程

### 3.1 VXLAN 封装格式

```
VXLAN Packet 结构:
==================

Outer Ethernet Header:
 +----------------+----------------+----------------+
 | Outer DMAC (6) | Outer SMAC (6) | EtherType (2) |
 +----------------+----------------+----------------+

Outer IP Header:
 +--------+--------+--------+--------+--------+--------+--------+--------+
 |  Ver  |   IHL  |   TOS  |       Total Len      |    ID    |(3)|(Flg)|(13)Frag-Offset  |
 +--------+--------+--------+--------+--------+--------+--------+--------+
 |  TTL  | Proto=17(UDP) |    Header Checksum      |      Source IP         |
 +--------+--------+--------+--------+--------+--------+--------+--------+
 |                           Destination IP                       |
 +--------+--------+--------+--------+--------+--------+--------+--------+

Outer UDP Header:
 +----------------+----------------+
 |    Source Port (Vxlan Hash)  |    Dest Port (4789)            |
 +----------------+----------------+
 |    UDP Length          |   UDP Checksum (optional)           |
 +----------------+----------------+

VXLAN Header (8 bytes):
 +--------+(1)+--------+--------+--------+--------+--------+--------+
 | Reserved(24bit) |I|R|R|R|         VNI (24-bit)          |Reserved|
 +----------------+-+--------+--------+--------+--------+--------+

Inner Ethernet Header:
 +----------------+----------------+----------------+
 | Inner DMAC (6) | Inner SMAC (6) | EtherType (2) |
 +----------------+----------------+----------------+

Payload: Original packet (IP/TCP/UDP etc.)
```

### 3.2 P4 VXLAN Header 定义

```c
// VXLAN Header
header vxlan_t {
    bit<8>  flags;        // 8 bits: I(1) + R(3) + Reserved(4)
    bit<24> reserved;     // 24 bits
    bit<24> vni;           // 24-bit VXLAN Network Identifier
    bit<8>  reserved2;    // 8 bits
}

// Outer Header (封装前的原始包内容)
header outer_ethernet_t {
    bit<48> dstAddr;
    bit<48> srcAddr;
    bit<16> etherType;     // 0x0800 for IPv4, 0x86DD for IPv6
}

header outer_ipv4_t {
    bit<4>  version;
    bit<4>  ihl;
    bit<8>  diffserv;
    bit<16> totalLen;
    bit<16> identification;
    bit<3>  flags;
    bit<13> fragOffset;
    bit<8>  ttl;
    bit<8>  protocol;     // 17 for UDP
    bit<16> hdrChecksum;
    bit<32> srcAddr;
    bit<32> dstAddr;
}

header outer_udp_t {
    bit<16> srcPort;       // Hash-based ECMP
    bit<16> dstPort;       // 4789 (VXLAN)
    bit<16> length;
    bit<16> checksum;
}
```

### 3.3 VXLAN Parser

```c
parser parse_vxlan(packet_in packet,
                   out headers hdr,
                   inout metadata_t meta) {

    state start {
        transition parse_outer_ethernet;
    }

    state parse_outer_ethernet {
        packet.extract(hdr.outer_ethernet);
        transition select(hdr.outer_ethernet.etherType) {
            0x0800: parse_outer_ipv4;
            default: accept;
        }
    }

    state parse_outer_ipv4 {
        packet.extract(hdr.outer_ipv4);
        transition select(hdr.outer_ipv4.protocol) {
            17: parse_outer_udp;     // UDP
            default: accept;
        }
    }

    state parse_outer_udp {
        packet.extract(hdr.outer_udp);
        transition select(hdr.outer_udp.dstPort) {
            4789: parse_vxlan;       // VXLAN
            default: accept;
        }
    }

    state parse_vxlan {
        packet.extract(hdr.vxlan);
        // 保存 VNI 到元数据
        meta.vni = hdr.vxlan.vni;
        transition parse_inner_ethernet;
    }

    state parse_inner_ethernet {
        packet.extract(hdr.inner_ethernet);
        // 内部 etherType 决定后续解析
        transition select(hdr.inner_ethernet.etherType) {
            0x0800: parse_inner_ipv4;
            0x86DD: parse_inner_ipv6;
            default: accept;
        }
    }

    // ... 内部 IPv4/IPv6 Parser
}
```

### 3.4 VXLAN 封装 (Tunnel Encapsulation)

```c
// VXLAN 封装 Control
control vxlan_encap(inout headers hdr,
                     inout metadata_t meta) {

    // VNI -> 远端 VTEP IP 查找
    table vxlan_vtep_lookup {
        key = {
            meta.vni: exact;         // 24-bit VNI
        }
        actions = {
            set_tunnel_info;         // 设置封装信息
            drop;
        }
    }

    // ECMP 哈希: 基于内层 5-tuple
    action compute_vxlan_hash() {
        hash(
            hdr.outer_udp.srcPort,   // Outer UDP src port for ECMP
            HashAlgorithm.crc16,
            0,
            {
                hdr.inner_ipv4.srcAddr,
                hdr.inner_ipv4.dstAddr,
                hdr.inner_ipv4.protocol,
                // 需要解析 L4 获取端口
                hdr.inner_tcp.srcPort,
                hdr.inner_tcp.dstPort
            },
            16                        // 16-way ECMP
        );
    }

    action set_tunnel_info(bit<32> dst_vtep_ip, bit<8> dst_port) {
        // 设置 Outer 封装头
        hdr.outer_ethernet.setValid();
        hdr.outer_ipv4.setValid();
        hdr.outer_udp.setValid();
        hdr.vxlan.setValid();

        // Outer Ethernet
        hdr.outer_ethernet.dstAddr = meta.tunnel_dst_mac;
        hdr.outer_ethernet.srcAddr = meta.tunnel_src_mac;
        hdr.outer_ethernet.etherType = 0x0800;

        // Outer IPv4
        hdr.outer_ipv4.setValid();
        hdr.outer_ipv4.srcAddr = meta.tunnel_src_ip;
        hdr.outer_ipv4.dstAddr = dst_vtep_ip;
        hdr.outer_ipv4.ttl = 64;
        hdr.outer_ipv4.protocol = 17;  // UDP

        // VXLAN
        hdr.vxlan.vni = meta.vni;

        // 计算 ECMP 哈希
        compute_vxlan_hash();
    }

    apply {
        // 执行 VXLAN 封装
        vxlan_vtep_lookup.apply();
    }
}
```

### 3.5 VXLAN 解封装 (Tunnel Decapsulation)

```c
// VXLAN 解封装 Control
control vxlan_decap(inout headers hdr,
                     inout metadata_t meta) {

    // VTEP 验证表
    table vxlan_vtep_validate {
        key = {
            hdr.outer_ipv4.srcAddr: exact;  // 源 VTEP IP
            hdr.vxlan.vni:          exact;  // VNI
        }
        actions = {
            validate_vtep;
            drop_invalid_vtep;
        }
    }

    action validate_vtep() {
        // VTEP 验证通过，保存信息用于后续处理
        meta.tunnel_src_ip = hdr.outer_ipv4.srcAddr;
        meta.tunnel_vni = hdr.vxlan.vni;

        // 标记解封装完成
        meta.tunnel_decap = true;
    }

    apply {
        // 在 Parser 之后验证并解封装
        vxlan_vtep_validate.apply();

        if (meta.tunnel_decap) {
            // 移除 Outer Header
            hdr.outer_ethernet.setInvalid();
            hdr.outer_ipv4.setInvalid();
            hdr.outer_udp.setInvalid();
            hdr.vxlan.setInvalid();
        }
    }
}
```

---

## 4. VLAN/VXLAN 集成

### 4.1 混合 VLAN + VXLAN 场景

```c
// VLAN VXLAN 转换表
table vlan_to_vxlan {
    key = {
        // 内部 VLAN
        hdr.vlan.vid:    exact;
        // 目的 VTEP
        meta.dst_vtep:   exact;
    }
    actions = {
        // VLAN -> VXLAN 映射
        // 客户 VLAN 10 <-> VNI 10000
        map_vlan_to_vni;
        drop;
    }
}

// VXLAN -> VLAN 转换表
table vxlan_to_vlan {
    key = {
        hdr.vxlan.vni: exact;
    }
    actions = {
        // VNI -> VLAN 映射
        map_vni_to_vlan;
        // 直接桥接到 VLAN
        decap_and_bridge;
    }
}
```

### 4.2 完整处理流程

```
VXLAN Gateway 处理流程:
=======================

Ingress (To VTEP):
  Packet In (with VLAN Tag)
       |
       v
  [VLAN Parse] --> Extract VLAN VID
       |
       v
  [VLAN->VNI Lookup] --> Find VNI for VLAN
       |
       v
  [VNI->VTEP Lookup] --> Find remote VTEP IP
       |
       v
  [VXLAN Encap] --> Add Outer Headers
       |
       v
  [L3 Forward] --> Route to VTEP
       |
       v
  Packet Out (VXLAN encapsulated)

Egress (From VTEP):
  VXLAN Packet In
       |
       v
  [L3 Route] --> Route to local VTEP
       |
       v
  [VXLAN decap] --> Remove Outer Headers, extract VNI
       |
       v
  [VNI->VLAN Lookup] --> Find VLAN for VNI
       |
       v
  [VLAN Encap] --> Add VLAN Tag
       |
       v
  Packet Out (with VLAN Tag)
```

---

## 5. EVPN 集成

### 5.1 EVPN 简介

**EVPN (Ethernet VPN)** 是 L2VPN 的新一代技术，提供：

- **MAC 地址学习**通过 BGP 分布
- **批量收敛**而非泛洪学习
- **ARP/ND 抑制**减少广播

### 5.2 P4 EVPN 表

```c
// EVPN MAC 路由表
table evpn_mac_table {
    key = {
        hdr.evpn.mac_addr:   exact;    // MAC 地址
        hdr.evpn.vni:        exact;    // VNI
    }
    actions = {
        // 找到 MAC 的位置
        set_evpn_entry;         // 设置下一跳信息
        // MAC 不存在，需要泛洪/学习
        flood_and_learn;
    }
}

// EVPN IRB (Integrated Routing and Bridging)
table evpn_irb_table {
    key = {
        hdr.ipv4.dstAddr: lpm;  // 路由查表
        hdr.evpn.vni:    exact;
    }
    actions = {
        route_to_vtep;          // 路由到 VTEP
        route_locally;          // 本地路由
    }
}
```

---

## 6. 多租户隔离

### 6.1 租户隔离架构

```c
// 租户元数据
struct tenant_metadata_t {
    bit<24> tenant_id;          // 租户标识 (从 VNI 映射)
    bit<12> vlan_id;            // 本地 VLAN
    bit<32> vrf_id;             // VRF/路由实例
}

// 租户安全检查
table tenant_acl {
    key = {
        meta.tenant_id: exact;
        hdr.ipv4.srcAddr: lpm;
        hdr.ipv4.dstAddr: lpm;
    }
    actions = {
        permit;
        deny;
        log_and_deny;
    }
}
```

### 6.2 VLAN/VXLAN 隔离对比

| 隔离层级        | VLAN         | VXLAN                   |
| --------------- | ------------ | ----------------------- |
| **L2 隔离**     | VID (12-bit) | VNI (24-bit)            |
| **L3 隔离**     | VRF-Lite     | VRF (共享 Underlay)     |
| **租户数量**    | ~4K          | 16M                     |
| **跨 Pod 扩展** | ❌           | ✅                      |
| **封装开销**    | 4 bytes      | 54 bytes (outer header) |

---

## 7. 常见问题与排查

| 问题           | 原因               | 解决方案           |
| -------------- | ------------------ | ------------------ |
| VXLAN 包被丢弃 | VTEP 未注册        | 检查 VTEP 发现机制 |
| VLAN 内泛洪    | MAC 学习泛洪       | 启用 MAC 地址同步  |
| MTU 问题       | VXLAN 封装后超 MTU | 增大物理接口 MTU   |
| VNI 冲突       | 多租户 VNI 重叠    | 确保 VNI 全局唯一  |

---

## 8. 总结

本章涵盖 VLAN/VXLAN 编程的核心内容：

1. **VLAN (802.1Q)**：Tagging、QinQ、VLAN 成员端口过滤
2. **VXLAN**：UDP 封装、8-byte VNI Header、VTEP 隧道
3. **Overlay/Underlay 分离**：虚拟网络与物理网络解耦
4. **VLAN-VXLAN 映射**：L2 域之间的转换
5. **EVPN 集成**：BGP 驱动的 MAC 学习
6. **多租户隔离**：VNI/VRF 隔离方案

VXLAN 是现代数据中心网络虚拟化的核心协议，P4 可编程交换机可以高性能地实现 VTEP 功能。
