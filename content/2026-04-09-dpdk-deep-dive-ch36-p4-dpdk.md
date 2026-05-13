---
title: "DPDK 第三十六章：P4 可编程数据面与 behavioral model"
date: 2026-04-09 16:10:00
tags: [dpdk, p4, programmable, behavioral-model, networking, pipeline]
description: "深入解析 P4 语言架构、可编程数据面流水线、behavioral model 与 DPDK 的集成"
---

# DPDK 第三十六章：P4 可编程数据面与 behavioral model

> [!abstract] 核心要点
> P4 是一种数据面编程语言，允许开发者定义数据包处理流水线。本章解析 P4 架构、behavioral model (BMv2)、P4-DPDK 集成与可编程网络应用开发。

## 1. P4 概述

### 1.1 什么是 P4

**P4** (Programming Protocol-independent Packet Processors) 是一种：

- **领域特定语言**：专门用于网络数据包处理
- **协议无关**：不绑定特定协议，可定义任意包头解析
- **可编程数据面**：在 NIC、交换机、路由器上运行
- **声明式**：描述"what"而不是"how"

### 1.2 P4 vs eBPF

| 特性         | P4                         | eBPF                 |
| ------------ | -------------------------- | -------------------- |
| **目标**     | 协议无关包处理             | 内核任意计算         |
| **运行环境** | NIC/Switch/Software (BMv2) | Linux Kernel         |
| **状态支持** | tables、registers          | maps、per-CPU state  |
| **包修改**   | 完整解析/修改              | 有限（skb 直接访问） |
| **适用场景** | 交换机、路由器             | 网络观测、安全       |

### 1.3 P4 生态

```
┌─────────────────────────────────────────────────────────┐
│                      P4 Program                          │
│         (header, parser, table, action, control)         │
└────────────────────────┬────────────────────────────────┘
                         │ compile
                         ▼
┌─────────────────────────────────────────────────────────┐
│                   P4 Compiler (p4c)                       │
│  - Frontend: 语义分析                                     │
│  - Backend: 生成目标代码                                  │
│    - BMv2 (behavioral model)                             │
│    - DPDK                                                │
│    - eBPF                                                │
│    - ASIC (Broadcom, Intel Tofino)                       │
└─────────────────────────────────────────────────────────┘
```

## 2. P4 语言基础

### 2.1 基本结构

```p4
#include <core.p4>
#include <v1model.p4>  // 标准架构

// 1. 头部定义
header ethernet_t {
    bit<48> dstAddr;
    bit<48> srcAddr;
    bit<16> etherType;
}

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

// 2. 元数据
struct metadata {
    bit<32> hash;
    bit<8>  class_of_service;
}

// 3. 解析器
parser MyParser(packet_in packet,
                out headers hdr,
                inout metadata meta) {
    state start {
        packet.extract(hdr.ethernet);
        transition select(hdr.ethernet.etherType) {
            0x0800: parse_ipv4;
            default: accept;
        }
    }
    state parse_ipv4 {
        packet.extract(hdr.ipv4);
        transition accept;
    }
}

// 4. 动作
action send_to_cpu() {
    // 自定义动作
}

action drop() {
    mark_to_drop();
}

action l3_forward(bit<48> dstAddr, bit<48> srcAddr) {
    hdr.ethernet.dstAddr = dstAddr;
    hdr.ethernet.srcAddr = srcAddr;
    hdr.ipv4.ttl = hdr.ipv4.ttl - 1;
}

// 5. 表
table ipv4_lpm {
    key = {
        hdr.ipv4.dstAddr: lpm;  // longest prefix match
    }
    actions = {
        l3_forward;
        drop;
        NoAction;
    }
    default_action = drop;
    size = 16384;
}

// 6. 控制块
control MyIngress(inout headers hdr,
                  inout metadata meta) {
    apply {
        ipv4_lpm.apply();
    }
}

control MyEgress(inout headers hdr,
                 inout metadata meta) {
    apply {
        // 转发、克隆等
    }
}

control MyDeparser(packet_out packet,
                   in headers hdr) {
    apply {
        packet.emit(hdr.ethernet);
        packet.emit(hdr.ipv4);
    }
}

control MyVerifyChecksum(inout headers hdr,
                         inout metadata meta) {
    apply {
        verify_checksum(hdr.ipv4.isValid(),
                        { hdr.ipv4.version,
                          hdr.ipv4.ihl,
                          hdr.ipv4.diffserv,
                          hdr.ipv4.totalLen,
                          hdr.ipv4.identification,
                          hdr.ipv4.flags,
                          hdr.ipv4.fragOffset,
                          hdr.ipv4.ttl,
                          hdr.ipv4.protocol,
                          hdr.ipv4.srcAddr,
                          hdr.ipv4.dstAddr },
                        hdr.ipv4.hdrChecksum, HashAlgorithm.csum16);
    }
}

control MyComputeChecksum(inout headers hdr,
                          inout metadata meta) {
    apply {
        update_checksum(hdr.ipv4.isValid(),
                        { hdr.ipv4.version,
                          hdr.ipv4.ihl,
                          hdr.ipv4.diffserv,
                          hdr.ipv4.totalLen,
                          hdr.ipv4.identification,
                          hdr.ipv4.flags,
                          hdr.ipv4.fragOffset,
                          hdr.ipv4.ttl,
                          hdr.ipv4.protocol,
                          hdr.ipv4.srcAddr,
                          hdr.ipv4.dstAddr },
                        hdr.ipv4.hdrChecksum, HashAlgorithm.csum16);
    }
}

// 7. 主入口（V1Model 架构）
V1Switch(MyParser(),
          MyVerifyChecksum(),
          MyIngress(),
          MyEgress(),
          MyComputeChecksum(),
          MyDeparser()) main;
```

### 2.2 P4 关键概念

#### 2.2.1 Header 与 Payload

```p4
// Header 是固定长度的协议字段
header tcp_t {
    bit<16> srcPort;
    bit<16> dstPort;
    bit<32> seqNo;
    bit<32> ackNo;
    bit<4>  dataOffset;
    bit<3>  flags;
    bit<16> window;
    bit<16> checksum;
    bit<16> urgentPtr;
}

// Header stack（多个同类型头部，如 VLAN）
header vlan_t {
    bit<3>  pcp;
    bit<1>  cfi;
    bit<12> vid;
    bit<16> etherType;
}

header vlan_stack_t[3];  // 最多 3 个 VLAN tag
```

#### 2.2.2 Parser

```p4
// 状态机风格的解析器
parser MyParser(...) {
    state start {
        transition parse_ethernet;
    }
    state parse_ethernet {
        packet.extract(hdr.ethernet);
        transition select(hdr.ethernet.etherType) {
            0x0800: parse_ipv4;
            0x86DD: parse_ipv6;
            0x8100: parse_vlan;  // VLAN
            _:      accept;
        }
    }
    state parse_vlan {
        packet.extract(hdr.vlan);
        transition select(hdr.vlan.etherType) {
            0x0800: parse_ipv4;
            _:      accept;
        }
    }
    // ...
}
```

#### 2.2.3 Tables

```p4
// LPM (Longest Prefix Match) 表
table ipv4_fib {
    key = { hdr.ipv4.dstAddr: lpm; }
    actions = { drop; }
    default_action = drop;
    size = 65536;
}

// Exact Match 表
table mac_acl {
    key = {
        hdr.ethernet.srcAddr: exact;
        hdr.ethernet.dstAddr: exact;
    }
    actions = { permit; deny; }
    size = 8192;
}

// Ternary 表
table acl {
    key = {
        hdr.ipv4.srcAddr: ternary;
        hdr.ipv4.dstAddr: ternary;
        hdr.ipv4.protocol: ternary;
    }
    actions = { permit; deny; }
    size = 4096;
}
```

#### 2.2.4 Actions

```p4
// 简单动作
action set_nhop(bit<48> nhop_mac, bit<32> nhop_ipv4) {
    hdr.ethernet.dstAddr = nhop_mac;
    hdr.ipv4.dstAddr = nhop_ipv4;
    hdr.ipv4.ttl = hdr.ipv4.ttl - 1;
}

// 带条件的动作
action src_port_classifier() {
    bit<8> src_port_class;
    if (hdr.tcp.isValid()) {
        src_port_class = 1;  // TCP
    } else if (hdr.udp.isValid()) {
        src_port_class = 2;  // UDP
    } else {
        src_port_class = 0;  // Other
    }
    meta.class_of_service = src_port_class;
}
```

## 3. Behavioral Model (BMv2)

### 3.1 BMv2 概述

BMv2 是 P4 程序的软件参考交换机：

- **Reference Implementation**：P4 规范的参考实现
- **可移植**：运行在普通 CPU 上
- **调试友好**：支持 CLI、JSON 输出
- **性能有限**：不追求线速

### 3.2 安装 BMv2

```bash
# 安装依赖
sudo apt install -y automake libtool libgc-dev \
    libboost-dev libboost-graph-dev libboost-system-dev \
    protobuf-compiler libprotobuf-dev libnanopb-dev

# 克隆 p4c 和 BMv2
git clone --recursive https://github.com/p4lang/p4c.git
cd p4c
git submodule update --init backends/bmv2

# 编译
mkdir build && cd build
cmake ..
make -j$(nproc)
sudo make install
```

### 3.3 编译 P4 到 BMv2

```bash
# 编译为 BMv2 JSON
p4c-bm2-ss -p4v 16 -o myprogram.json myprogram.p4

# 输出文件
# myprogram.json - BMv2 配置
```

### 3.4 运行 BMv2

```bash
# 启动交换机
simple_switch --help

# 基本启动
simple_switch -i 0@00:00:00:00:00:01 -i 1@00:00:00:00:00:02 \
    --no-p4 topo.json

# 常用参数
# -i <port>@<iface>   端口映射
# -- thrift-port      Thrift API 端口
# --log-console       输出日志到控制台
# --debugger          启用调试器
```

### 3.5 BMv2 CLI

```bash
# 连接 BMv2 CLI
simple_switch_CLI --thrift-port 9090

# 命令示例
RuntimeCmd: show_tables
RuntimeCmd: table_dump ipv4_lpm
RuntimeCmd: table_add ipv4_lpm set_nhop 10.0.0.1/32 => 00:00:00:00:01:00 10.0.0.1
RuntimeCmd: table_delete ipv4_lpm 10.0.0.1/32
```

## 4. P4-DPDK 集成

### 4.1 编译 P4 到 DPDK

```bash
# 编译为 DPDK 目标
p4c-dpdk -p4v 16 -o myprogram.dpdk.json myprogram.p4

# 需要 p4c-dpdk 支持的架构
# 使用 v1model 或 pna (Portable NIC Architecture)
```

### 4.2 TTD (Time to Detect)

```bash
# 使用 testpmd 运行 P4 程序
# 需要将 JSON 配置转换为 DPDK 的格式
```

### 4.3 DPDK P4 限制

| 功能               | 支持 | 说明                    |
| ------------------ | ---- | ----------------------- |
| Basic Parsing      | ✅   | Ethernet, IPv4, TCP/UDP |
| LPM/Exact Tables   | ✅   | Hash + CMA              |
| Hash Actions       | ✅   |                         |
| Checksum Update    | ✅   |                         |
| Direct Counters    | ✅   |                         |
| Direct Meters      | ✅   |                         |
| Stateful Registers | ✅   |                         |
| Clone/Recirculate  | ⚠️   | 受限于 DPDK 架构        |
| Traffic Manager    | ❌   | 需要额外实现            |

## 5. 实际案例

### 5.1 简单路由器

```p4
#include <core.p4>
#include <v1model.p4>

header ethernet_t { bit<48> dstAddr; bit<48> srcAddr; bit<16> etherType; }
header ipv4_t { bit<4> version; bit<4> ihl; bit<8> tos;
                bit<16> totalLen; bit<16> id; bit<3> flags;
                bit<13> fragOffset; bit<8> ttl; bit<8> protocol;
                bit<16> hdrChecksum; bit<32> srcAddr; bit<32> dstAddr; }

struct metadata { bit<32> nexthop; }
struct headers { ethernet_t ethernet; ipv4_t ipv4; }

parser MyParser(packet_in packet, out headers hdr, metadata meta) {
    state start {
        packet.extract(hdr.ethernet);
        transition select(hdr.ethernet.etherType) {
            0x0800: parse_ipv4;
            default: accept;
        }
    }
    state parse_ipv4 {
        packet.extract(hdr.ipv4);
        transition accept;
    }
}

control MyIngress(inout headers hdr, inout metadata meta) {
    action ipv4_forward(bit<48> dstAddr, bit<48> srcAddr, bit<32> nexthop) {
        hdr.ethernet.dstAddr = dstAddr;
        hdr.ethernet.srcAddr = srcAddr;
        meta.nexthop = nexthop;
        hdr.ipv4.ttl = hdr.ipv4.ttl - 1;
    }

    table ipv4_match {
        key = { hdr.ipv4.dstAddr: lpm; }
        actions = { ipv4_forward; drop; }
        size = 16384;
        default_action = drop;
    }

    apply { ipv4_match.apply(); }
}

control MyEgress(inout headers hdr, inout metadata meta) { apply {} }
control MyDeparser(packet_out packet, in headers hdr) {
    apply { packet.emit(hdr.ethernet); packet.emit(hdr.ipv4); }
}
control MyVerifyChecksum(inout headers hdr, inout metadata meta) {
    apply {
        verify_checksum(hdr.ipv4.isValid(),
            { hdr.ipv4.version, hdr.ipv4.ihl, hdr.ipv4.tos,
              hdr.ipv4.totalLen, hdr.ipv4.id, hdr.ipv4.flags,
              hdr.ipv4.fragOffset, hdr.ipv4.ttl, hdr.ipv4.protocol,
              hdr.ipv4.srcAddr, hdr.ipv4.dstAddr },
            hdr.ipv4.hdrChecksum, HashAlgorithm.csum16);
    }
}
control MyComputeChecksum(inout headers hdr, inout metadata meta) {
    apply {
        update_checksum(hdr.ipv4.isValid(),
            { hdr.ipv4.version, hdr.ipv4.ihl, hdr.ipv4.tos,
              hdr.ipv4.totalLen, hdr.ipv4.id, hdr.ipv4.flags,
              hdr.ipv4.fragOffset, hdr.ipv4.ttl, hdr.ipv4.protocol,
              hdr.ipv4.srcAddr, hdr.ipv4.dstAddr },
            hdr.ipv4.hdrChecksum, HashAlgorithm.csum16);
    }
}
V1Switch(MyParser(), MyVerifyChecksum(), MyIngress(),
        MyEgress(), MyComputeChecksum(), MyDeparser()) main;
```

### 5.2 负载均衡器

```p4
// 基于 ECMP 的负载均衡
control LoadBalancer(inout headers hdr, inout metadata meta) {
    action set_ecmp_group(bit<16> ecmp_base, bit<16> ecmp_count) {
        // 计算 hash
        hash(meta.hash,
            HashAlgorithm.crc16,
            (bit<1>)0,
            { hdr.ipv4.srcAddr, hdr.ipv4.dstAddr,
              hdr.tcp.srcPort, hdr.tcp.dstPort },
            ecmp_count);

        // 选择下一跳
        meta.nexthop = ecmp_base + (bit<32>)meta.hash;
    }

    table ecmp_group {
        key = { hdr.ipv4.dstAddr: lpm; }
        actions = { set_ecmp_group; drop; }
        size = 1024;
    }

    apply { ecmp_group.apply(); }
}
```

## 6. 调试与优化

### 6.1 P4 程序调试

```bash
# 启用详细日志
simple_switch -i 0@veth0 --log-console ...

# 查看日志
# Parser state transitions, table hits/misses, etc.

# CLI 调试
simple_switch_CLI
table_dump <table_name>        # 查看表内容
table_dump_entry <table_name>  # 详细条目
```

### 6.2 性能优化

```p4
// 1. 减少表大小（节省 TCAM）
table ipv4_fib {
    size = 65536;  // 根据实际需求调整
}

// 2. 使用 exact match 代替 ternary（节省资源）
table mac_table {
    key = { hdr.ethernet.dstAddr: exact; }
    // 而非 ternary
}

// 3. 简化解析器
// 避免过深的 header stack
```

## 7. 总结

P4 为网络数据面编程带来了革命性变化：

1. **协议无关**：任意定义包头解析和处理逻辑
2. **声明式**：开发者关注意图，编译器负责实现
3. **多目标**：同一程序可编译到软件或硬件
4. **BMv2**：软件参考实现，用于开发调试
5. **DPDK 集成**：通过 p4c-dpdk 生成高性能数据面

---

## 参考资源

- [P4 语言规范](https://p4.org/p4-spec/)
- [p4c 编译器](https://github.com/p4lang/p4c)
- [BMv2 behavioral model](https://github.com/p4lang/behavioral-model)
