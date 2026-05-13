---
title: "P4 深度探索 (二)：P4 架构模型——PSA / V1Model、Ingress/Egress、Parser/Deparser"
date: 2026-04-14
tags: [p4, series, architecture, psa, v1model, parser, deparser, ingress, egress]
description: "深入理解 P4 架构模型——PSA (Portable Switch Architecture) 和 V1Model 两种标准架构、Ingress/Egress Pipeline 划分、Parser 状态机、Deparser 重封装、Metadata 传递机制"
---

> [!info] P4 深度探索系列
> 0. [[2026-04-14-p4-deep-dive-series-index|全栈学习路径总览]]
> 1. [[2026-04-14-p4-deep-dive-ch1-p4-overview|第一章：P4 概述——诞生背景与协议无关包处理]]
> 2. **第二章：P4 架构模型——PSA/V1Model、Ingress/Egress、Parser/Deparser**
> 3. [[2026-04-14-p4-deep-dive-ch3-p4-vs-ebpf|第三章：P4 vs eBPF——适用场景与硬件/软件对比]]
> 4. [[2026-04-14-p4-deep-dive-ch4-p4-program|第四章：P4 程序结构——Header/Parser/Control/Table]]
> 5. [[2026-04-14-p4-deep-dive-ch5-p4-types|第五章：P4 类型系统——bit/varbit/enum/header/struct]]

---

## 1. 概述：什么是 P4 架构模型？

P4 语言本身是 **平台无关的**——它只描述"数据包如何处理"，而不规定"处理流水线长什么样"。要让 P4 程序能在具体硬件上运行，必须将语言映射到一个 **架构模型（Architecture Model）**。

架构模型定义了：

- **Pipeline 的结构**：有几个阶段（Stage）、每个阶段做什么
- **可用的组件**：有哪些可编程块（Parser/Control/Meter）、有哪些固定功能块
- **数据包流转顺序**：数据包如何从一个组件进入另一个组件
- **Metadata 的定义**：哪些元数据可以在组件间传递

P4-16 引入了 **Architecture Description（架构描述文件）**，以 `p4` 文件的形式定义架构接口。P4 程序通过 `arch` 文件声明它所依赖的架构，实现解耦。

---

## 2. 两种标准架构：PSA vs V1Model

### 2.1 V1Model：软件交换机的参考架构

V1Model 是 BMv2（Behavioral Model v2）软件交换机使用的架构，也是 P4-14 时代的主流架构。它结构简单，适合教学和仿真：

```
                        ┌──────────┐
                        │  Parser  │  ← 可编程：从 packet 提取 headers
                        └────┬─────┘
                             │
                             ▼
                        ┌──────────┐
                        │ Ingress  │  ← 可编程：Match-Action 表
                        │  Control │
                        └────┬─────┘
                             │
              ┌──────────────┼──────────────┐
              ▼              ▼              ▼
         ┌─────────┐    ┌──────────┐   ┌─────────┐
         │ Queue   │    │ Traffic  │   │  Drop   │
         │         │    │  Manager │   │         │
         └─────────┘    └──────────┘   └─────────┘
              │              │              │
              └──────────────┴──────────────┘
                             │
                             ▼
                        ┌──────────┐
                        │  Egress  │  ← 可编程：Match-Action 表
                        │  Control │
                        └────┬─────┘
                             │
                             ▼
                        ┌──────────┐
                        │Deparser  │  ← 可编程：将 headers 重新组装为 packet
                        └──────────┘
```

**V1Model 特点**：
- Parser → Ingress → Queue → Egress → Deparser
- Ingress 和 Egress 都是可编程的 Control Block
- 内置 `queueing_metadata` 提供队列长度、时间戳等信息
- 简单直观，适合理解 P4 流水线

### 2.2 PSA：硬件交换机的标准架构

PSA（Portable Switch Architecture）是 P4-16 的标准架构，专为硬件交换机设计，提供比 V1Model 更丰富的功能：

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Ingress Pipeline                             │
│                                                                      │
│  ┌────────┐     ┌─────────────┐     ┌──────────────────────────┐   │
│  │Parser+ │────►│  Ingress    │────►│  Traffic Manager         │   │
│  │Deparser│     │  Match-Action│     │  (Queueing/Cloning/Mirror)│   │
│  └────────┘     └─────────────┘     └──────────────────────────┘   │
│       ▲                                                       │     │
│       │                                                       │     │
└───────┼───────────────────────────────────────────────────────┼─────┘
        │                                                       │
        │          ┌─────────────────────────────────────┐      │
        │          │           Egress Pipeline             │      │
        │          │                                     │      │
        │          │  ┌─────────────┐  ┌───────────────┐ │      │
        └──────────┼─►│   Egress    │─►│  Parser+       │─┘      │
                   │  │  Match-Action│  │  Deparser      │        │
                   │  └─────────────┘  └───────────────┘        │
                   └────────────────────────────────────────────┘
```

**PSA 特点**：
- **架构定义更完整**：`PSA.p4` 完整定义了所有组件接口
- **统一 Parser+Deparser**：Parser 解析后，数据包经过 Ingress → Traffic Manager → Egress → Deparser，Deparser 复用 Parser 的解析结果
- **Traffic Manager**：支持多播（Multicast）、克隆（Clone）、镜像（Mirror）操作
- **Port Metadata**：每个端口携带入口/出口元数据
- **可移植性**：同一 P4 程序，经过 PSA 后端编译，可部署到任何支持 PSA 的硬件

---

## 3. Parser：状态机驱动的包解析

### 3.1 Parser 的本质

Parser 是 P4 流水线中**第一个可编程的组件**，负责将字节流（packet）解析为结构化的 Headers。它的本质是一个 **有限状态机（Finite State Machine, FSM）**：

```
State machine:
  start ──► parse_ethernet ──► parse_ipv4 ──► parse_tcp ──► accept
                  │                │             │
                  ▼                ▼             ▼
                drop             drop          drop
```

每个状态对应一个 Header 类型，状态转换由数据包的当前内容决定。

### 3.2 Parser 状态机示例

```c
// P4-16 Parser 示例
parser MainParser(packet_in packet,
                  out headers h,
                  inout metadata m,
                  inout standard_metadata_t sm) {

    state start {
        transition parse_ethernet;
    }

    state parse_ethernet {
        packet.extract(h.ethernet);        // 提取以太网头
        transition select(h.ethernet.etherType) {
            0x0800: parse_ipv4;           // IPv4
            0x86DD: parse_ipv6;           // IPv6
            0x8100: parse_vlan;           // VLAN
            default: accept;              // 未知类型，接受（不解析更多）
        }
    }

    state parse_ipv4 {
        packet.extract(h.ipv4);
        transition select(h.ipv4.protocol) {
            6: parse_tcp;                 // TCP
            17: parse_udp;                // UDP
            default: accept;
        }
    }

    state parse_ipv6 { /* 类似 IPv4 */ }

    state parse_tcp {
        packet.extract(h.tcp);
        transition accept;
    }

    state parse_udp {
        packet.extract(h.udp);
        transition accept;
    }
}
```

**关键点**：

1. `packet.extract()` 从数据包中提取 Header，更新 Parser 的内部状态
2. `transition select()` 根据已解析的 Header 字段值决定下一个状态
3. `accept` 状态表示解析完成，数据包进入 Match-Action 流水线
4. `drop` 状态表示解析失败，数据包被丢弃
5. Parser 可以设置 `error` 来标记解析异常

### 3.3 Parser 的Metadata

Parser 可以设置两种 Metadata：

```c
// 标准元数据（架构定义）
inout standard_metadata_t sm;  // 入口端口、出口端口、丢弃标志等

// 用户定义元数据（程序定义）
inout metadata m;              // 自定义的解析上下文
```

典型用途：解析 VXLAN 时，将 VNI（24bit）存入 metadata，供后续 Control 使用。

---

## 4. Match-Action Pipeline：Ingress 与 Egress

### 4.1 Ingress Control：入口流水线

Ingress 是数据包进入交换机后第一个处理阶段，负责：
- **查表匹配**：根据数据包 header 字段查 Match-Action 表
- **路由决策**：决定数据包出口（egress port）
- **修改 Header**：更新 TTL、MAC 地址、IP 地址等
- **组播/复制**：决定是否需要复制数据包
- **设置 QoS**：标记队列、优先级

```c
control MainIngress(inout headers h,
                    inout metadata m,
                    inout standard_metadata_t sm) {

    // 定义 Action（动作）
    action drop() {
        mark_to_drop(sm);
    }

    action ipv4_forward(bit<48> dstAddr, bit<48> srcAddr, bit<32> port) {
        h.ethernet.dstAddr = dstAddr;
        h.ethernet.srcAddr = srcAddr;
        sm.egress_spec = port;
    }

    action broadcast() {
        sm.mcast_grp = 1;  // 设置组播组
    }

    // 定义 Table（匹配表）
    table ipv4_lpm {
        key = {
            h.ipv4.dstAddr: lpm;  // Longest Prefix Match
        }
        actions = {
            ipv4_forward;
            drop;
            broadcast;
        }
        default_action = drop;
        // 实现细节由编译器/硬件决定（TCAM 或 Hash + CAM）
    }

    apply {
        if (h.ipv4.isValid()) {
            ipv4_lpm.apply();  // 执行查表
        }
    }
}
```

### 4.2 Egress Control：出口流水线

Egress 是数据包离开交换机前的最后一个处理阶段，负责：
- **出口过滤**：根据出口端口特性过滤数据包
- **TTL 递减**：在 Ingress 已处理，一般做额外修改
- **封装/解封装**：VXLAN 封装的终点（Decap）
- **镜像/克隆**：复制数据包到监控端口
- **修改出口 Metadata**：如出口时间戳

```c
control MainEgress(inout headers h,
                   inout metadata m,
                   inout standard_metadata_t sm) {

    action add_vlan(bit<12> vlan_id) {
        // VXLAN 封装逻辑在 Egress 完成
        h.vlan.setValid();
        h.vlan.vid = vlan_id;
    }

    table send_to_cpu {
        key = { sm.mcast_grp: exact; }
        actions = { clone; }
    }

    apply {
        // 如果是组播流，复制到监控端口
        if (sm.mcast_grp != 0) {
            // clone_preserving_field_list(...);
        }
    }
}
```

### 4.3 Ingress 与 Egress 的区别

| 维度 | Ingress | Egress |
|------|---------|--------|
| 执行时机 | 数据包进入交换芯片时 | 数据包离开交换芯片时 |
| 主要职责 | 路由决策、ACL、转发 | 封装、镜像、出口处理 |
| 资源 | TCAM（表项查找） | 主要内存访问 |
| 对同一数据包的多次处理 | 入口侧唯一执行 | 可能因多播而执行多次 |
| 是否可见出口端口 | 不可见（此时未选定） | 已知（可据此做判断） |

---

## 5. Deparser：包重组与序列化

### 5.1 Deparser 的职责

Deparser 是流水线的最后一个组件，负责将 P4 程序中已修改的 Header 结构重新序列化为字节流，写入物理网络：

```
数据包字节流 ──► Parser ──► [修改后的 Headers] ──► Deparser ──► 输出字节流
                (提取)                              (序列化)
```

**核心职责**：
1. 按定义的顺序重新排列 Header 字段
2. 将修改后的 Header 值写回数据包
3. 计算并更新 Checksum（如 IPv4 Header Checksum）

### 5.2 Deparser 实现

```c
control MainDeparser(packet_out packet,
                     in headers h,
                     in metadata m,
                     inout standard_metadata_t sm) {
    apply {
        // 按顺序序列化所有 Headers
        packet.emit(h.ethernet);  // 先输出 Ethernet
        packet.emit(h.vlan);     // 然后 VLAN（如果 Valid）
        packet.emit(h.ipv4);     // IPv4
        packet.emit(h.tcp);      // TCP
        // 负载(payload)由底层自动传递，不需要显式 emit
    }
}
```

**关键点**：

- `packet.emit()` 将 Header 的当前值序列化到输出数据包
- 只有 `setValid()` 的 Header 才会被 emit（条件 Header）
- Deparser 必须与 Parser 顺序一致，否则接收方无法正确解析

### 5.3 Checksum 重新计算

Deparser 中经常需要重新计算 Checksum，因为 Ingress 可能修改了 Header 字段（如 TTL 递减）：

```c
// 在 P4 中，Checksum 计算一般在 Ingress/Egress 的 apply 块中完成
// 然后在 Deparser 中注入
control MainDeparser(packet_out packet,
                     in headers h,
                     in metadata m,
                     inout standard_metadata_t sm) {
    apply {
        // Checksum 验证与计算在 Ingress 阶段完成
        // 这里直接 emit 已更新 Checksum 的 Header
        packet.emit(h.ipv4);  // IPv4 Header 中的 chksum 字段已被更新
        packet.emit(h.tcp);
    }
}
```

P4 提供 `verify()` 语句在 Parser 中验证 Checksum，以及 `update()` 在 Control 中重新计算。

---

## 6. Metadata 传递机制

### 6.1 标准 Metadata

每个架构都定义了一套标准 Metadata，在整个流水线中传递：

```c
// PSA standard_metadata_t 定义
struct standard_metadata_t {
    bit<9>  ingress_port;      // 入口端口号
    bit<9>  egress_spec;       // 指定出口端口
    bit<9>  egress_port;       // 实际出口端口（Egress 可读）
    bit<48> ingress_timestamp; // 入口时间戳
    bit<32> packet_length;    // 数据包总长度
    bit<4>  egress_rid;        // 多播复制实例 ID
    bit<3>  priority;          // QoS 优先级
    // ... 省略部分字段
}
```

### 6.2 用户定义 Metadata

P4 程序可以定义自己的 Metadata 结构，在 Parser → Ingress → Egress → Deparser 全程传递：

```c
// 用户定义元数据结构
struct metadata {
    bit<24> vni;              // VXLAN Network Identifier
    bit<8>  tenant_id;        // 租户 ID
    bool    is_broadcast;     // 是否广播流
    bit<16> original_ethertype; // 保存原始 EtherType（封装后丢失）
}
```

使用方式：

```c
// Parser 设置 metadata
state parse_vxlan {
    packet.extract(h.vxlan);
    m.vni = h.vxlan.vni;  // 从 VXLAN Header 中提取 VNI
    transition accept;
}

// Ingress 读取 metadata，决定路由
if (m.is_broadcast) {
    sm.mcast_grp = 2;
}
```

---

## 7. Traffic Manager：多播、克隆与镜像

### 7.1 PSA Traffic Manager

PSA 的 Traffic Manager 是 Ingress 和 Egress 之间的桥梁，负责：

- **队列管理**：将数据包放入不同队列（QoS）
- **多播复制**：一个数据包复制多份，发送到不同出口
- **克隆/镜像**：复制数据包到监控端口（如 SPAN/RSPAN/ERSPAN）
- **Packet-in**：将数据包发送到控制面（用于学习/控制）

```
Ingress ──► Traffic Manager ──► Egress
             │
             ├── Queue (排队、调度)
             ├── Clone (镜像)
             ├── Multicast (多播复制)
             └── Recirculate (重新注入流水线)
```

### 7.2 多播实现

```c
// Ingress 中设置多播组
if (h.ipv4.dstAddr == 224.0.0.1) {  // 组播地址
    sm.mcast_grp = 1;  // 关联多播组 ID
}

// P4Runtime 或配置平面预先配置多播组
// multicast_group_id=1 包含 egress_port={1,2,3}
```

### 7.3 克隆实现

```c
// 用于抓包分析、深度检测等场景
// Ingress 或 Egress 中触发克隆
if (sm.mcast_grp == 0 && sm.ingress_port == 1) {
    // 克隆到监控端口
    clone(CloneType.I2E, { sm.ingress_port, m.vni });
}
```

克隆有两种类型：
- **I2E (Ingress to Egress)**：Ingress 阶段克隆，数据包走完整 Ingress → TM → Egress 流程
- **E2E (Egress to Egress)**：Egress 阶段克隆，数据包直接复制到目标端口

---

## 8. 本章小结

本章深入讲解了 P4 的两种标准架构模型：

1. **V1Model**：BMv2 软件交换机参考架构，Parser → Ingress → Queue → Egress → Deparser，简单直观
2. **PSA**：硬件交换机标准架构，Parser+Deparser 统一、Traffic Manager 支持多播/克隆/镜像，更完整
3. **Parser**：基于状态机的字节流解析器，通过 `extract()` 提取 Header，`select()` 决定状态转换
4. **Ingress/Egress**：两个可编程的 Match-Action Control Block，分别负责入口处理和出口处理
5. **Deparser**：将修改后的 Header 重新序列化为字节流，需要与 Parser 顺序一致
6. **Metadata**：标准 Metadata（架构定义）+ 用户自定义 Metadata，在流水线全程传递
7. **Traffic Manager**：PSA 中负责队列、多播、克隆的组件

下一章我们将对比 **P4 与 eBPF** 的适用场景，从架构层面分析硬件可编程与内核可编程的差异。

---

> [!tip] 延伸阅读
> - PSA (Portable Switch Architecture) Specification: https://p4.org/p4-spec/docs/PSA-v1.1.0.html
> - V1Model Architecture: https://github.com/p4lang/p4c/blob/main/p4include/v1model.p4
> - P4-16 Language Specification: https://p4.org/p4-spec/docs/P4-16-language.html
