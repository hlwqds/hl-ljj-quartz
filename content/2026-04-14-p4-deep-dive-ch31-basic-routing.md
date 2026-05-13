---
title: "P4 深度探索 (三十一)：P4 基础路由编程——L3 转发、RIB/FIB、Longest Prefix Match"
date: 2026-04-14
tags: [p4, series, routing, l3, rib, fib, lpm, basic-routing, p4-16]
description: "P4 基础路由编程深度解析——IPv4/IPv6 L3 转发、RIB/FIB 分离架构、Longest Prefix Match (LPM) 表查找、默认路由、TTL 处理、ECMP 哈希基础"
---

> [!info] P4 深度探索系列
> 0. [[2026-04-14-p4-deep-dive-series-index|全栈学习路径总览]]
> 1. [[2026-04-14-p4-deep-dive-ch1-p4-overview|第一章：P4 概述——诞生背景与协议无关包处理]]
> 2. [[2026-04-14-p4-deep-dive-ch2-p4-architecture|第二章：P4 架构模型——PSA/V1Model、Ingress/Egress]]
> 3. [[2026-04-14-p4-deep-dive-ch3-p4-vs-ebpf|第三章：P4 vs eBPF——适用场景与硬件/软件对比]]
> 4. [[2026-04-14-p4-deep-dive-ch4-p4-program|第四章：P4 程序结构——Header/Parser/Control/Table]]
> 5. [[2026-04-14-p4-deep-dive-ch5-p4-types|第五章：P4 类型系统——bit/varbit/enum/header/struct]]
> ...
> 30. [[2026-04-14-p4-deep-dive-ch30-p4-control-plane-advanced|第三十章：P4 控制面高级主题]]
> 31. **第三十一章：P4 基础路由编程——L3 转发、RIB/FIB、Longest Prefix Match**

---

## 1. 概述：路由查找 vs 转发

**路由 (Routing)** 是 L3 交换机的核心功能——根据**目的 IP 地址**查找转发表，决定数据包的**下一跳**和**出端口**。

```
数据包转发决策流程:
========================

  +----------+     +----------+     +----------+     +----------+
  | Ethernet | --> |   IPv4   | --> |   IPv4   | --> |   IPv4   |
  |  Header  |     |  Parser  |     |  Route   |     | Forward  |
  | Parsing  |     |          |     |  Lookup  |     | + Tx    |
  +----------+     +----------+     +----------+     +----------+
       |                |                 |                |
       |            Extract             LPM              Send to
       |           dstAddr            Match              next hop
       |                                                       
  [Parse Ethernet]    [Extract IPv4 header fields]    [Rewrite & Output]
```

### 1.1 RIB vs FIB

|| 概念 | 说明 |
|------|------|
| **RIB (Routing Information Base)** | 控制面维护的路由信息库，包含所有路由策略、距离向量等 |
| **FIB (Forwarding Information Base)** | 数据面使用的转发表，是 RIB 的子集，已优化为硬件查找格式 |
| **分离架构** | 控制面计算 RIB，通过 P4 Runtime 写入 FIB，数据面只做快速查表 |

```
RIB/FIB 分离架构:
=================

  控制面 (Control Plane)              数据面 (Data Plane)
  +-------------+                     +-------------+
  |    RIB      |                     |    FIB      |
  |             |    P4 Runtime        |             |
  | - OSPF      | ----------------->  | - 20K 路由   |
  | - BGP       |     Write            | - LPM 表   |
  | - Static    |                     | - Exact 表  |
  +-------------+                     +-------------+
        |                                   |
        | 计算最优路径                       | 查表转发
        v                                   v
  [路由协议收敛]                    [线速数据包处理]
```

---

## 2. Longest Prefix Match (LPM) 查找

### 2.1 什么是 LPM？

传统精确匹配 (Exact Match) 只能匹配完整 key（如 MAC 地址），而路由查找需要找到**最长前缀匹配**：

| 目的地址 | 路由表条目 | 匹配结果 |
|---------|-----------|---------|
| `10.1.2.3` | `10.1.0.0/16` | ✅ 匹配 (匹配 16 位) |
| `10.1.2.3` | `10.1.2.0/24` | ✅ 匹配 (匹配 24 位，更优先) |
| `10.1.2.3` | `10.2.0.0/16` | ❌ 不匹配 |
| `10.1.2.3` | `0.0.0.0/0` | ✅ 匹配 (默认路由，匹配 0 位) |

**最长匹配原则**：选择前缀长度最长的路由条目。

### 2.2 P4 中 LPM Table

```c
// P4-16 中 LPM 表定义
table ipv4_route {
    key = {
        // LPM match kind：支持最长前缀匹配
        hdr.ipv4.dstAddr: lpm;
    }
    actions = {
        // 路由转发动作
        ipv4_forward;    // 正常转发
        drop;            // 丢弃
        NoAction;        // 无操作
    }

    // 默认动作用于未匹配流量
    default_action = drop();

    // 表大小（硬件资源估算）
    size = 65536;
}
```

### 2.3 LPM 查找的硬件实现

```
LPM 查找实现方式:
==================

1. TCAM (Ternary Content Addressable Memory)
   +--------+--------+--------+
   | 0.0.0.0| 000000 |   /0   |  默认路由
   +--------+--------+--------+
   | 10.1.2 | 000000 |  /24   |  最具体
   +--------+--------+--------+
   | 10.1   | 000000 |  /16   |  次具体
   +--------+--------+--------+
   按长度排序，最长在前，硬件并行查找

2. 树形结构 (Tree-based)
   IPv4 地址空间二叉树
   /0 (根) -> /8 -> /16 -> /24 (叶)
   查找时从根向下，找到最长匹配路径

3. Patricia/Radix Tree
   压缩前缀树，减少节点数量
```

---

## 3. 完整 L3 路由转发 P4 程序

### 3.1 Header 定义

```c
// Ethernet Header
header ethernet_t {
    bit<48> dstAddr;
    bit<48> srcAddr;
    bit<16> etherType;
}

// IPv4 Header
header ipv4_t {
    bit<4>  version;
    bit<4>  ihl;
    bit<8>  diffserv;
    bit<16> totalLen;
    bit<16> identification;
    bit<3>  flags;
    bit<13> fragOffset;
    bit<8>  ttl;
    bit<8>  protocol;
    bit<16> hdrChecksum;
    bit<32> srcAddr;
    bit<32> dstAddr;
}

// IPv6 Header (简化)
header ipv6_t {
    bit<4>   version;
    bit<8>   trafficClass;
    bit<20>  flowLabel;
    bit<16>  payloadLen;
    bit<8>   nextHdr;
    bit<8>   hopLimit;
    bit<128> srcAddr;
    bit<128> dstAddr;
}
```

### 3.2 Metadata 结构

```c
// 路由查找使用的元数据
struct metadata_t {
    // 路由查找结果
    bit<32>  lpm_ipv4_match_bd;      // 匹配的 BD/VLAN
    bit<48>  lpm_ipv4_nexthop_mac;   // 下一跳 MAC
    bit<32>  lpm_ipv4_nexthop_ipv4;   // 下一跳 IP
    bit<8>   lpm_ipv4_nexthop_port;   // 出端口

    // 路由查找状态
    bool     route_hit;              // 路由命中标志
}

// Parser 元数据（用于传递中间状态）
struct parser_metadata_t {
    bit<16>  l4_srcPort;
    bit<16>  l4_dstPort;
}
```

### 3.3 Parser 实现

```c
// IPv4 Parser
parser parse_ipv4(packet_in packet,
                  out headers hdr,
                  inout metadata_t meta) {
    state start {
        transition parse_ethernet;
    }

    state parse_ethernet {
        packet.extract(hdr.ethernet);
        transition select(hdr.ethernet.etherType) {
            0x0800:  parse_ipv4;      // IPv4
            0x86DD: parse_ipv6;      // IPv6
            default: accept;
        }
    }

    state parse_ipv4 {
        packet.extract(hdr.ipv4);
        // TTL 减 1 处理在 Ingress Control 中进行
        transition accept;
    }

    state parse_ipv6 {
        packet.extract(hdr.ipv6);
        transition accept;
    }
}
```

### 3.4 Ingress Control 实现

```c
// 主要路由转发 Control
control ingress(packet_in packet,
                inout headers hdr,
                inout metadata_t meta,
                inout standard_metadata_t standard_metadata) {

    // LPM 路由表
    table ipv4_route {
        key = { hdr.ipv4.dstAddr: lpm; }
        actions = {
            ipv4_forward;
            drop;
        }
        default_action = drop();
    }

    // 下一跳信息表 ( nexthop -> MAC + Port)
    table ipv4_nexthop {
        key = { meta.lpm_ipv4_nexthop_ipv4: exact; }
        actions = {
            set_nexthop_info;
            drop;
        }
    }

    action ipv4_forward(bit<48> nexthop_mac, bit<8> port) {
        // 1. TTL 减 1
        hdr.ipv4.ttl = hdr.ipv4.ttl - 1;

        // 2. 重新计算 Checksum
        // (实际使用 extern checksum，这里简化)

        // 3. 替换目标 MAC 为下一跳 MAC
        hdr.ethernet.dstAddr = nexthop_mac;

        // 4. 替换源 MAC 为本机出口 MAC
        // (需从 port metadata 获取)

        // 5. 发送到指定端口
        standard_metadata.egress_spec = port;
    }

    action set_nexthop_info(bit<48> nexthop_mac, bit<8> port) {
        meta.lpm_ipv4_nexthop_mac = nexthop_mac;
        meta.lpm_ipv4_nexthop_port = port;
    }

    apply {
        // Step 1: 路由查找 (LPM)
        ipv4_route.apply();

        // Step 2: 如果路由命中，查找下一跳信息
        if (meta.route_hit) {
            ipv4_nexthop.apply();
        }
    }
}
```

### 3.5 Deparser 实现

```c
control egress(packet_in packet,
               inout headers hdr,
               inout metadata_t meta,
               inout standard_metadata_t standard_metadata) {

    apply {
        // 重新计算 IPv4 Header Checksum
        // 必须在 deparser 中，因为 TTL 已在 ingress 修改
        verify_checksum(
            hdr.ipv4.isValid(),
            {
                hdr.ipv4.version,
                hdr.ipv4.ihl,
                hdr.ipv4.diffserv,
                hdr.ipv4.totalLen,
                hdr.ipv4.identification,
                hdr.ipv4.flags,
                hdr.ipv4.fragOffset,
                hdr.ipv4.ttl,
                hdr.ipv4.protocol,
                hdr.ipv4.srcAddr,
                hdr.ipv4.dstAddr
            },
            hdr.ipv4.hdrChecksum,
            HashAlgorithm.csum16
        );

        // 序列化 Header
        packet.emit(hdr.ethernet);
        packet.emit(hdr.ipv4);
    }
}
```

---

## 4. TTL 处理与防环路

### 4.1 TTL 递减

TTL (Time to Live) 字段用于**防止数据包在网络中无限循环**。每经过一个路由器，TTL 减 1。当 TTL 变为 0 时，数据包被丢弃。

```c
// TTL 递减逻辑
action decrement_ttl() {
    // TTL 减 1
    hdr.ipv4.ttl = hdr.ipv4.ttl - 1;

    // 检查是否超时
    if (hdr.ipv4.ttl == 0) {
        // TTL 超时，丢弃数据包
        // 通常在另一个表中处理
    }
}
```

### 4.2 TTL 超时统计

```c
// TTL 超时计数器
table ttl_exceeded {
    key = { /* empty */ }
    actions = {
        send_to_cpu;     // 发送副本到控制面分析
        drop;
    }
    // 用于收集 ICMP Time Exceeded 消息的样本
}
```

---

## 5. ECMP 哈希基础

### 5.1 ECMP (Equal Cost Multi-Path)

当存在多条等成本路由时，ECMP 通过**哈希负载均衡**将流量分散到多个下一跳。

```c
// ECMP 哈希计算
action ecmp_select(bit<16> ecmp_group_id, bit<4> num_nhops) {
    // 基于 5-tuple 哈希
    hash(
        meta.ecmp_hash,
        HashAlgorithm.crc16,
        /* base = */ 0,
        {
            hdr.ipv4.srcAddr,     // 源 IP
            hdr.ipv4.dstAddr,     // 目标 IP
            hdr.ipv4.protocol,    // 协议
            // L4 端口 (需要先解析 TCP/UDP)
            hdr.tcp.srcPort,      // 源端口
            hdr.tcp.dstPort       // 目标端口
        },
        /* max = */ num_nhops     // 哈希范围 = 下一跳数量
    );

    // 选择下一个下一跳
    meta.ecmp_nhop_index = meta.ecmp_hash;
}
```

### 5.2 ECMP 表结构

```
ECMP 查找流程:
===============

  dstAddr (LPM)  ──>  路由表 (ECMP 组 ID)  ──>  ECMP 选择器  ──>  下一跳
       │                  │                        │                │
  最长匹配            返回 ECMP 组 ID           计算哈希          实际转发
                                          选择一个下一跳
```

---

## 6. IPv6 路由转发

IPv6 路由转发与 IPv4 类似，主要区别：

```c
// IPv6 LPM 路由表
table ipv6_route {
    key = {
        hdr.ipv6.dstAddr: lpm;  // 128 位地址的 LPM
    }
    actions = {
        ipv6_forward;
        drop;
    }
}

action ipv6_forward(bit<48> nexthop_mac, bit<8> port) {
    // IPv6 Hop Limit 递减
    hdr.ipv6.hopLimit = hdr.ipv6.hopLimit - 1;

    // 替换 MAC 地址
    hdr.ethernet.dstAddr = nexthop_mac;

    // 发送到指定端口
    standard_metadata.egress_spec = port;
}
```

---

## 7. 控制平面配置

### 7.1 通过 P4 Runtime 写入路由

```protobuf
// P4 Runtime 表项示例：IPv4 路由
message TableEntry {
    string table_name = "ipv4_route";

    message Match {
        bytes dst_addr = 1;  // 目的 IP (network byte order)
        int32 prefix_len = 2;  // 前缀长度 (1-32)
    }
    repeated Match match = 2;

    message Action {
        string action_name = "ipv4_forward";
        message Params {
            string param_name = "nexthop_mac";
            bytes value = 2;
        }
        repeated Params params = 3;
    }
    Action action = 3;
}

// 示例：添加 10.1.2.0/24 -> 00:11:22:33:44:55 via port 3
TableEntry entry = 1;
entry.match.dst_addr = "10.1.2.0";
entry.match.prefix_len = 24;
entry.action.name = "ipv4_forward";
entry.action.params.nexthop_mac = "00:11:22:33:44:55";
// port = 3 通过另一个参数传递
```

---

## 8. 常见问题与排查

| 问题 | 原因 | 解决方案 |
|------|------|---------|
| 路由命中但转发失败 | 下一跳 MAC 未配置 | 检查 nexthop 表 |
| 丢包率高 | ACL 规则覆盖 | 检查 ACL 表顺序 |
| LPM 表满 | 路由数量超限 | 启用聚合路由/默认路由 |
| TTL 不递减 | Parser 未提取 TTL | 检查 Parser 逻辑 |

---

## 9. 总结

本章涵盖了 P4 基础路由编程的核心要素：

1. **RIB/FIB 分离架构**：控制面维护 RIB，通过 P4 Runtime 写入 FIB
2. **LPM 查找**：P4 的 `lpm` match kind 支持最长前缀匹配
3. **TTL 处理**：Ingress 递减 TTL，Deparser 重新计算 Checksum
4. **ECMP 哈希**：基于 5-tuple 的负载均衡哈希
5. **IPv6 支持**：128 位地址的 LPM 路由查找

这些基础概念为后续的 ACL、VLAN/VXLAN、负载均衡等高级主题奠定基础。
