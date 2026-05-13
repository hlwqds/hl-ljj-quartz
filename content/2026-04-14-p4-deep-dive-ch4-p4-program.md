---
title: "P4 深度探索 (四)：P4 程序结构——Header/Struct/Parser/Control/Table/Match-Action"
date: 2026-04-14
tags: [p4, series, program, header, parser, control, table, match-action, p4-16]
description: "P4-16 程序结构详解——Header 类型定义与 Header Stack、Struct 元数据结构、Parser 状态机编写、Control 块与 apply 语义、Match-Action Table 声明与 Key、Action 参数绑定"
---

> [!info] P4 深度探索系列 0. [[2026-04-14-p4-deep-dive-series-index|全栈学习路径总览]]
>
> 1. [[2026-04-14-p4-deep-dive-ch1-p4-overview|第一章：P4 概述——诞生背景与协议无关包处理]]
> 2. [[2026-04-14-p4-deep-dive-ch2-p4-architecture|第二章：P4 架构模型——PSA/V1Model、Ingress/Egress]]
> 3. [[2026-04-14-p4-deep-dive-ch3-p4-vs-ebpf|第三章：P4 vs eBPF——适用场景与硬件/软件对比]]
> 4. **第四章：P4 程序结构——Header/Struct/Parser/Control/Table/Match-Action**
> 5. [[2026-04-14-p4-deep-dive-ch5-p4-types|第五章：P4 类型系统——bit/varbit/enum/header/struct]]

---

## 1. 概述：一个完整 P4 程序的组成

一个完整的 P4-16 程序由以下核心部分组成：

```
┌──────────────────────────────────────────────────────────┐
│                   P4-16 程序结构                          │
│                                                           │
│  ┌────────────────┐                                      │
│  │ 1. Header 定义  │  网络协议头的类型声明                 │
│  └────────────────┘                                      │
│  ┌────────────────┐                                      │
│  │ 2. Struct 定义  │  元数据结构 (metadata)               │
│  └────────────────┘                                      │
│  ┌────────────────┐                                      │
│  │ 3. Parser       │  状态机：字节流 → Header 实例         │
│  └────────────────┘                                      │
│  ┌────────────────┐                                      │
│  │ 4. Control      │  Match-Action 流水线                 │
│  └────────────────┘                                      │
│  ┌────────────────┐                                      │
│  │ 5. Deparser     │  Header 实例 → 字节流                 │
│  └────────────────┘                                      │
│  ┌────────────────┐                                      │
│  │ 6. Package     │  架构绑定（TOP LEVEL）                │
│  └────────────────┘                                      │
└──────────────────────────────────────────────────────────┘
```

一个最简单的 P4 程序（以 V1Model 为例）包含：Headers 定义、Metadata 定义、Parser 定义、一个或多个 Control 定义、Deparser 定义、最后通过 `package` 将所有组件绑定到架构。

---

## 2. Header 定义：网络协议的结构化描述

### 2.1 Header 类型声明

Header 是 P4 中用于描述网络协议头的核心类型。每个 Header 类型由 `header` 关键字声明，字段可以是定长（`bit<N>`）或变长（`varbit<N>`）：

```c
// Ethernet Header (14 bytes)
header ethernet_t {
    bit<48> dstAddr;    // 目标 MAC 地址
    bit<48> srcAddr;    // 源 MAC 地址
    bit<16> etherType;  // EtherType (网络层协议类型)
}

// IPv4 Header (20-60 bytes, min 20)
header ipv4_t {
    bit<4>  version;     // 版本号 (IPv4=4)
    bit<4>  ihl;         // Header 长度 (以 4 字节为单位)
    bit<8>  diffserv;    // DSCP + ECN
    bit<16> totalLen;    // 总长度
    bit<16> identification;
    bit<3>  flags;       // 分片标志
    bit<13> fragOffset;  // 片偏移
    bit<8>  ttl;        // 生存时间
    bit<8>  protocol;   // 上层协议 (TCP=6, UDP=17)
    bit<16> hdrChecksum; // Header Checksum
    bit<32> srcAddr;     // 源 IP
    bit<32> dstAddr;    // 目标 IP
}

// TCP Header (20-60 bytes)
header tcp_t {
    bit<16> srcPort;    // 源端口
    bit<16> dstPort;    // 目标端口
    bit<32> seqNo;     // 序列号
    bit<32> ackNo;     // 确认号
    bit<4>  dataOffset; // TCP Header 长度
    bit<3>  flags;      // SYN/FIN/ACK 等
    bit<16> window;    // 窗口大小
    bit<16> checksum;   // Checksum
    bit<16> urgentPtr; // 紧急指针
}
```

### 2.2 Header Stack：连续同类型 Header 的数组

当需要处理多个同类型的 Header（如 MPLS 标签栈、VLAN 栈）时，使用 Header Stack：

```c
// VLAN Header Stack，最多支持 2 层 VLAN (QinQ)
header vlan_t[2] vlan_stack;

// IPv6 Extension Header Chain (可选的多个扩展头)
header ipv6_hop_opts_t    hop_opts;
header ipv6_routing_t     routing;
header ipv6_fragment_t    fragment;
header ipv6_ah_t           ah;
```

Header Stack 的访问方式与数组类似：

```c
vlan_stack[0].setValid();  // 第一个 VLAN
vlan_stack[1].setValid();  // 第二个 VLAN (QinQ)
vlan_stack[0].vid = 100;   // 访问字段
```

### 2.3 Valid/Invalid 状态

P4 的 Header 有两种状态：**Valid**（有效）和 **Invalid**（无效）。只有 Valid 的 Header 才能被读写：

```c
if (h.ipv4.isValid()) {       // 检查是否有效
    h.ipv4.ttl = h.ipv4.ttl - 1;  // 只有 Valid 才能访问字段
}
h.ipv4.setValid();   // 标记为 Valid
h.ipv4.setInvalid(); // 标记为 Invalid（相当于移除这个 Header）
```

---

## 3. Struct 定义：Metadata 的结构化

### 3.1 元数据结构

Metadata 用于在 Parser → Ingress → Egress → Deparser 全程传递上下文信息：

```c
// 用户自定义元数据
struct metadata {
    bit<24>     vni;              // VXLAN Network Identifier
    bit<16>    original_ethertype; // 封装前的 EtherType
    bit<8>     traffic_class;    // QoS 优先级
    bool       is_unicast;        // 是否单播
    bit<9>     egress_port;       // 预定义的出口端口
}
```

### 3.2 Headers 容器结构

所有 Header 类型通常集中在一个 `headers` 结构中，便于在整个流水线中传递：

```c
// 所有 Header 实例的容器
struct headers {
    ethernet_t  ethernet;
    vlan_t[2]   vlan;
    ipv4_t      ipv4;
    ipv6_t      ipv6;
    tcp_t       tcp;
    udp_t       udp;
    vxlan_t     vxlan;
}
```

---

## 4. Parser：状态机编写

### 4.1 Parser 的基本结构

Parser 是将字节流解析为 Header 实例的有限状态机：

```c
// V1Model Parser 签名
parser MyParser(packet_in packet,
                out headers h,
                inout metadata m,
                inout standard_metadata_t sm) {

    // 状态机主体
}
```

### 4.2 状态转换：select + transition

Parser 的核心是状态转换逻辑，使用 `select` 语句根据当前数据包的某些值决定下一个状态：

```c
state start {
    transition parse_ethernet;
}

state parse_ethernet {
    packet.extract(h.ethernet);  // 提取以太网头
    transition select(h.ethernet.etherType) {
        16w0x0800: parse_ipv4;       // IPv4
        16w0x86DD: parse_ipv6;       // IPv6
        16w0x8100: parse_vlan;      // VLAN
        16w0x8847: parse_mpls;      // MPLS (Unicast)
        16w0x8848: parse_mpls;      // MPLS (Multicast)
        default: accept;              // 未知类型，停止解析
    }
}

state parse_vlan {
    packet.extract(h.vlan[0]);  // 提取第一层 VLAN
    transition select(h.vlan[0].etherType) {
        16w0x0800: parse_ipv4;
        16w0x86DD: parse_ipv6;
        16w0x8100: parse_second_vlan;
        default: accept;
    }
}

state parse_second_vlan {
    packet.extract(h.vlan[1]);  // 提取第二层 VLAN (QinQ)
    transition select(h.vlan[1].etherType) {
        16w0x0800: parse_ipv4;
        16w0x86DD: parse_ipv6;
        default: accept;
    }
}

state parse_ipv4 {
    packet.extract(h.ipv4);
    transition select(h.ipv4.protocol) {
        8w6:   parse_tcp;    // TCP
        8w17:  parse_udp;    // UDP
        default: accept;
    }
}

state parse_tcp {
    packet.extract(h.tcp);
    transition accept;
}
```

### 4.3 变长 Header：varbit

IPv4 的 Header Length (`ihl`) 字段表示 IPv4 Header 的实际长度（20-60 字节），因为可能包含 Options。对于变长部分，使用 `varbit`：

```c
header ipv4_t {
    // ... 固定字段 ...
    bit<32> srcAddr;
    bit<32> dstAddr;
    // 可选的 IPv4 Options (变长, 最多 40 字节)
    varbit<320> options;  // 320 bits = 40 bytes
}
```

Parser 中根据 `ihl` 字段值动态提取 Options：

```c
state parse_ipv4 {
    packet.extract(h.ipv4);
    // h.ipv4.ihl 的单位是 4 字节
    // 如果 ihl > 5，说明有 Options
    transition select(h.ipv4.ihl) {
        4w5: accept;  // 无 Options
        default: parse_ipv4_options;
    }
}

state parse_ipv4_options {
    // 提取变长 Options 部分
    packet.extract(h.ipv4.options,
                   (bit<32>)(h.ipv4.ihl - 5) * 32);
    transition accept;
}
```

### 4.4 Error 与 verify

Parser 可以使用 `error` 声明解析错误，并在 `verify` 语句中检查条件：

```c
// 错误类型声明
error {
    IPv4HeaderLengthError,
    IPv4ChecksumError,
    TCPHeaderLengthError
}

state parse_ipv4 {
    packet.extract(h.ipv4);
    // 验证 IPv4 Header 长度是否合法 (最小 20 字节, 即 ihl >= 5)
    verify(h.ipv4.ihl >= 5, error.IPv4HeaderLengthError);
    // 验证 IPv4 Checksum (如果硬件支持)
    verify(ipv4_checksum_ok, error.IPv4ChecksumError);
    transition accept;
}
```

---

## 5. Control：Match-Action 流水线

### 5.1 Control 的基本结构

Control 是 P4 中定义数据处理逻辑的核心块，包含 Action 定义、Table 定义和 `apply` 逻辑：

```c
control MyIngress(inout headers h,
                   inout metadata m,
                   inout standard_metadata_t sm) {

    // ---- Action 定义 ----
    action drop() {
        mark_to_drop(sm);
    }

    action ipv4_forward(bit<48> dstAddr, bit<48> srcAddr, bit<9> egress_port) {
        h.ethernet.dstAddr = dstAddr;
        h.ethernet.srcAddr = srcAddr;
        sm.egress_spec = egress_port;
    }

    action send_to_cpu() {
        sm.egress_spec = 255;  // CPU 端口
    }

    // ---- Table 定义 ----
    table forward {
        key = {
            h.ipv4.dstAddr: lpm;  // Longest Prefix Match
        }
        actions = {
            ipv4_forward;
            drop;
            send_to_cpu;
            NoAction;  // 什么也不做
        }
        size = 16384;           // 表项数量上限
        default_action = drop;  // 默认动作为 drop
    }

    table acl_check {
        key = {
            h.ipv4.srcAddr: ternary;   // 三元匹配
            h.tcp.srcPort: range;       // 范围匹配
            sm.ingress_port: exact;     // 精确匹配
        }
        actions = {
            drop;
            permit;
        }
        const default_action = permit;
    }

    // ---- apply 逻辑 ----
    apply {
        if (h.ipv4.isValid()) {
            forward.apply();  // 先做 L3 转发
            if (!forward.result().hit) {
                // 处理未命中
            }
        }
        acl_check.apply();  // 再做 ACL 检查
    }
}
```

### 5.2 Action：可参数化的动作

Action 是数据包被匹配后执行的具体操作，可以有参数：

```c
// Action 参数类型：可以是 bit<N>、定长数据，或只读引用
action set_dscp(bit<8> dscp_value) {
    h.ipv4.diffserv = dscp_value;
}

// 调用 Action 时传入参数
table qos_mark {
    actions = {
        set_dscp;
    }
}

// P4Runtime 下发表项时指定参数
// Action: set_dscp, 参数: dscp_value=46 (EF)
```

Action 中可以：

- **修改 Header**：如 `h.ipv4.ttl = h.ipv4.ttl - 1`
- **修改 Metadata**：如 `m.vni = 100`
- **修改 Standard Metadata**：如 `sm.egress_spec = 3`
- **调用内置方法**：如 `mark_to_drop()`、`clone()`
- **修改 Register**：如 `my_register.write(idx, value)`

### 5.3 Table：Match-Action 的匹配表

Table 是 Match-Action 的核心数据结构，由 Key（匹配字段）、Actions（可选动作）和属性定义：

```c
table my_table {
    // ---- Key 定义 ----
    key = {
        field1: match_kind;  // match_kind 决定匹配类型
        field2: match_kind;
    }

    // ---- 可选动作列表 ----
    actions = {
        action_a;
        action_b;
        drop;
    }

    // ---- 表属性 ----
    size = 1024;              // 最大表项数
    default_action = drop;    // 默认动作（未命中时执行）
    const entries = {         // 静态表项（P4 程序中硬编码）
        0x0A000001 &&& 0xFFFFFF00: action_a(1);  // 10.0.0.0/24
        0x0A000100 &&& 0xFFFF0000: action_b(2);  // 10.0.0.0/16
    };
}
```

**三种 Match Kind**（匹配类型）：

| Match Kind     | P4 关键字 | 说明               | 硬件实现              |
| -------------- | --------- | ------------------ | --------------------- |
| 精确匹配       | `exact`   | 完全相等           | Hash + CAM            |
| LPM (最长前缀) | `lpm`     | 子网掩码，最长匹配 | TCAM 或 Patricia Tree |
| 三元匹配       | `ternary` | 位掩码，允许通配   | TCAM                  |

### 5.4 apply 的执行语义

`apply` 块中的逻辑决定表的查找顺序和条件调用：

```c
apply {
    // 顺序执行（串行）
    switch (forward.apply().action_run) {
        IPv4_forward: { acl.apply(); }
        NoAction: { /* 不做任何 ACL 检查 */ }
    }

    // 条件执行
    if (sm.ingress_port == 1) {
        qos_mark.apply();
    }
}
```

P4-16 不保证表的执行顺序（取决于架构实现），但 `switch` 语句可以根据表的结果分派不同处理逻辑。

---

## 6. Deparser：包重组

### 6.1 Deparser 基本结构

Deparser 将 Header 实例重新序列化为字节流：

```c
control MyDeparser(packet_out packet,
                    in headers h,
                    in metadata m,
                    inout standard_metadata_t sm) {
    apply {
        // 按顺序 emit Header
        packet.emit(h.ethernet);
        // 只有 Valid 的 Header 才会被 emit
        if (h.vlan[0].isValid()) {
            packet.emit(h.vlan[0]);
        }
        if (h.vlan[1].isValid()) {
            packet.emit(h.vlan[1]);
        }
        packet.emit(h.ipv4);
        packet.emit(h.tcp);
        // Payload 自动从原始数据包传递
    }
}
```

### 6.2 Checksum 更新

当 Header 被修改后，Checksum 需要重新计算。P4 提供 `update_checksum` 块：

```c
control ComputeChecksum(inout headers h, inout metadata m) {
    apply {
        // IPv4 Header Checksum 重新计算
        update_checksum(
            h.ipv4.isValid(),
            {
                h.ipv4.version,
                h.ipv4.ihl,
                h.ipv4.diffserv,
                h.ipv4.totalLen,
                h.ipv4.identification,
                h.ipv4.flags,
                h.ipv4.fragOffset,
                h.ipv4.ttl,
                h.ipv4.protocol,
                h.ipv4.srcAddr,
                h.ipv4.dstAddr
            },
            h.ipv4.hdrChecksum,
            HashAlgorithm.csum16
        );
    }
}
```

---

## 7. Package：顶层架构绑定

### 7.1 V1Model 的 Package

V1Model 是最简单的架构，直接将 Parser、Control、Deparser 绑定：

```c
// V1Model package 签名
V1Switch(
    MyParser(),       // Parser 实例
    MyIngress(),      // Ingress Control 实例
    MyEgress(),       // Egress Control 实例
    MyDeparser(),     // Deparser 实例
    MyChecksum()      // Checksum 计算实例（可选）
) main;
```

### 7.2 PSA 的 Package

PSA 的 Package 更复杂，定义了完整的架构接口：

```c
// PSA Package 结构（简化）
package main(
    // Parser
    Parser<...>(...),  // 入口 Parser
    // 后续 Parser (如 ADFS: Additional Dependent Header Processing)
    // Ingress
    Ingress<...>(...),
    // Traffic Manager
    TrafficManager<...>(),
    // Egress
    Egress<...>(...),
    // Deparser
    Deparser<...>(...)
);
```

---

## 8. 一个完整示例：L3 Forwarder

将所有概念整合，一个简单的 L3 转发器：

```c
#include <core.p4>
#include <v1model.p4>

// ---- 1. Header 定义 ----
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

// ---- 2. Metadata ----
struct metadata {}

struct headers {
    ethernet_t ethernet;
    ipv4_t     ipv4;
}

// ---- 3. Parser ----
parser MyParser(packet_in packet,
                out headers h,
                inout metadata m,
                inout standard_metadata_t sm) {
    state start {
        transition parse_ethernet;
    }
    state parse_ethernet {
        packet.extract(h.ethernet);
        transition select(h.ethernet.etherType) {
            0x0800: parse_ipv4;
            default: accept;
        }
    }
    state parse_ipv4 {
        packet.extract(h.ipv4);
        transition accept;
    }
}

// ---- 4. Ingress Control ----
control MyIngress(inout headers h,
                  inout metadata m,
                  inout standard_metadata_t sm) {

    action drop() {
        mark_to_drop(sm);
    }

    action ipv4_forward(bit<48> dstAddr, bit<48> srcAddr, bit<9> port) {
        h.ethernet.dstAddr = dstAddr;
        h.ethernet.srcAddr = srcAddr;
        h.ipv4.ttl = h.ipv4.ttl - 1;
        sm.egress_spec = port;
    }

    table ipv4_lpm {
        key = { h.ipv4.dstAddr: lpm; }
        actions = { ipv4_forward; drop; }
        size = 16384;
        default_action = drop;
    }

    apply {
        if (h.ipv4.isValid()) {
            ipv4_lpm.apply();
        }
    }
}

// ---- 5. Egress Control ----
control MyEgress(inout headers h,
                 inout metadata m,
                 inout standard_metadata_t sm) {
    apply { /* 本例中 Egress 不做额外处理 */ }
}

// ---- 6. Deparser ----
control MyDeparser(packet_out packet,
                   in headers h,
                   in metadata m,
                   inout standard_metadata_t sm) {
    apply {
        packet.emit(h.ethernet);
        packet.emit(h.ipv4);
    }
}

// ---- 7. Checksum ----
control MyComputeChecksum(inout headers h, inout metadata m) {
    apply {
        update_checksum(h.ipv4.isValid(),
            { h.ipv4.version, h.ipv4.ihl, h.ipv4.diffserv,
              h.ipv4.totalLen, h.ipv4.identification,
              h.ipv4.flags, h.ipv4.fragOffset,
              h.ipv4.ttl, h.ipv4.protocol,
              h.ipv4.srcAddr, h.ipv4.dstAddr },
            h.ipv4.hdrChecksum, HashAlgorithm.csum16);
    }
}

// ---- 8. Package ----
V1Switch(MyParser(), MyIngress(), MyEgress(),
         MyDeparser(), MyComputeChecksum()) main;
```

---

## 9. 本章小结

本章详细讲解了 P4-16 程序的核心组成部分：

1. **Header 定义**：`header` 类型声明网络协议头，`varbit` 处理变长字段，`isValid()/setValid()/setInvalid()` 管理 Header 状态
2. **Struct 定义**：`struct` 聚合 Header 实例和自定义 Metadata
3. **Parser**：状态机驱动的字节流解析，`extract()` 提取 Header，`select()` + `transition` 决定状态转换
4. **Control**：Match-Action 流水线，`action` 定义可参数化的动作，`table` 定义匹配表，`apply` 块定义执行逻辑
5. **Match Kind**：三种匹配类型 `exact`/`lpm`/`ternary`，分别对应 Hash+CAM/LPM TCAM/TCAM 实现
6. **Deparser**：`packet.emit()` 将 Header 重新序列化为字节流
7. **Package**：顶层绑定，将 Parser/Control/Deparser 绑定到具体架构（V1Model/PSA）

下一章我们将深入 **P4 类型系统**，讲解 bit/varbit/enum/header/struct/tuple 等类型的语义，以及 LPM/ternary 等 Match Kind 的底层原理。

---

> [!tip] 延伸阅读
>
> - P4-16 Language Specification: https://p4.org/p4-spec/docs/P4-16-language.html
> - P4 V1Model Arch: https://github.com/p4lang/p4c/blob/main/p4include/v1model.p4
> - P4 PSA Arch: https://github.com/p4lang/p4-spec/blob/main/p4src/include/psa.p4
> - P4 Tutorial: https://github.com/p4lang/tutorials
