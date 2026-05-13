---
title: "P4 深度探索 (十三)：Pipeline 设计——Match-Action 流水线、逻辑阶段与物理阶段"
date: 2026-04-14
tags: [p4, series, pipeline, mau, match-action, logical-stage, physical-stage, compiler, p4-16]
description: "P4 Pipeline 设计深度解析——Match-Action 流水线架构、逻辑阶段 (Logical Stage) 与物理阶段 (Physical Stage) 映射、p4c 编译器优化、Resource Allocation、Table Placement、流水线平衡"
---

> [!info] P4 深度探索系列 0. [[2026-04-14-p4-deep-dive-series-index|全栈学习路径总览]]
>
> 1. [[2026-04-14-p4-deep-dive-ch1-p4-overview|第一章：P4 概述——诞生背景与协议无关包处理]]
> 2. [[2026-04-14-p4-deep-dive-ch2-p4-architecture|第二章：P4 架构模型——PSA/V1Model、Ingress/Egress]]
> 3. [[2026-04-14-p4-deep-dive-ch3-p4-vs-ebpf|第三章：P4 vs eBPF——适用场景与硬件/软件对比]]
> 4. [[2026-04-14-p4-deep-dive-ch4-p4-program|第四章：P4 程序结构——Header/Parser/Control/Table]]
> 5. [[2026-04-14-p4-deep-dive-ch5-p4-types|第五章：P4 类型系统——bit/varbit/enum/header/struct/tuple]]
> 6. [[2026-04-14-p4-deep-dive-ch6-headers|第六章：Header 与 Packet——Header 定义、Header Stack]]
> 7. [[2026-04-14-p4-deep-dive-ch7-parser|第七章：Parser 编程——状态机、Header 提取、Error 处理]]
> 8. [[2026-04-14-p4-deep-dive-ch8-match-action|第八章：Match-Action 编程——Table、Action、Key]]
> 9. [[2026-04-14-p4-deep-dive-ch9-control|第九章：Control 编程——Control Block、条件判断、Action 调用链]]
> 10. [[2026-04-14-p4-deep-dive-ch10-deparser|第十章：Deparser——包重组、Header 顺序、Checksum 重新计算]]
> 11. [[2026-04-14-p4-deep-dive-ch11-psa|第十一章：PSA 架构——Portable Switch Architecture、Ingress/Egress 管道]]
> 12. [[2026-04-14-p4-deep-dive-ch12-tna|第十二章：TNA 架构——Tofino Native Architecture、高性能流水线]]
> 13. **第十三章：Pipeline 设计——Match-Action 流水线、逻辑阶段与物理阶段**

---

## 1. 概述：Pipeline 是 P4 程序到硬件的桥梁

**Pipeline** 是 P4 编译器将 P4 程序转换为可在硬件上执行的指令序列的过程。它涉及：

- **逻辑阶段 (Logical Stage)**：P4 程序中的 Control 顺序
- **物理阶段 (Physical Stage)**：硬件实际执行单元（MAU Stage、Pipeline Stage）
- **资源分配 (Resource Allocation)**：TCAM/SRAM/ALU 的映射

Pipeline 设计决定了数据平面的**吞吐量**、**延迟**和**功能上限**。

---

## 2. Match-Action 流水线架构

### 2.1 流水线基本结构

Match-Action 流水线是网络交换芯片的核心处理模型：

```
Match-Action Pipeline (N stages):
============================================================

Stage 0          Stage 1          Stage 2     ...    Stage N
+--------+       +--------+       +--------+          +--------+
| Match  |       | Match  |       | Match  |          | Match  |
| Table  |------>| Table  |------>| Table  |----...-->| Table  |
|  LPM   |       | Exact  |       | Ternary|          | ACL    |
+--------+       +--------+       +--------+          +--------+
    |                 |                 |                  |
    v                 v                 v                  v
+--------+       +--------+       +--------+          +--------+
|Action  |       |Action  |       |Action  |          |Action  |
|Execute |------>|Execute |------>|Execute |----...-->|Execute |
+--------+       +--------+       +--------+          +--------+
    |                 |                 |                  |
    +-----------------+-----------------+------------------+
                        |
                        v
                  Next Stage
```

### 2.2 流水线的并行性

每个 Stage 内可以并行执行：

- **多个 Table 查找**：同一 Stage 内，多个表可同时查找
- **多个 Action 执行**：同一 Stage 内，多个动作可同时执行

```
Stage 并行性示例:
====================

Stage 0:
  ┌──────────────────┐     ┌──────────────────┐
  │   MAC Lookup     |     |   VLAN Check     |  (并行)
  └────────┬─────────┘     └────────┬─────────┘
           │                          │
           v                          v
  ┌──────────────────┐     ┌──────────────────┐
  │ mac_learn action  |     │ vlan_filter act  |  (并行)
  └──────────────────┘     └──────────────────┘
```

---

## 3. 逻辑阶段 (Logical Stage)

### 3.1 逻辑阶段的定义

**逻辑阶段**是 P4 程序中 `apply` 块内各个操作的**偏序关系**。编译器根据数据依赖确定可以并行或必须串行的操作。

```c
control Ingress(...) {

    table mac_learn { /* ... */ }
    table ipv4_fib { /* ... */ }
    table acl { /* ... */ }

    apply {
        // 逻辑上这是三个阶段
        mac_learn.apply();  // 逻辑阶段 0
        ipv4_fib.apply();   // 逻辑阶段 1
        acl.apply();        // 逻辑阶段 2
    }
}
```

### 3.2 数据依赖分析

编译器分析表之间的数据依赖：

| 依赖类型                    | 描述                     | 结果       |
| --------------------------- | ------------------------ | ---------- |
| **RAW (Read After Write)**  | 表 B 读取表 A 写入的字段 | 必须串行   |
| **WAR (Write After Read)**  | 表 B 写入表 A 读取的字段 | 可能重排序 |
| **WAW (Write After Write)** | 表 B 写入表 A 写入的字段 | 可能重排序 |
| **无依赖**                  | 读写字段无交集           | 可并行     |

```c
// 数据依赖示例
apply {
    // 阶段 0: MAC 学习 (写入 srcMac)
    mac_learn.apply();

    // 阶段 1: L3 查找 (读取 dstMac 作为 Key 的一部分)
    // RAW 依赖: ipv4_fib 读取 mac_learn 写入的字段
    ipv4_fib.apply();

    // 阶段 2: ACL 检查 (读取 srcIp, dstIp)
    // 无依赖: acl 读取的字段与前两个表无交集
    acl.apply();
}
```

---

## 4. 物理阶段 (Physical Stage)

### 4.1 物理阶段的定义

**物理阶段**是硬件上实际存在的执行单元数量。在 Tofino 中，Ingress 有 32 个 MAU Stage，Egress 有 32 个 MAU Stage。

### 4.2 逻辑到物理的映射

P4 编译器 (`p4c`) 负责将逻辑阶段映射到物理阶段：

```
Logical Stages ──> p4c Compiler ──> Physical Stages
                                           │
     ┌──────────────────────────────────────┼──────────────────┐
     │                                      │                  │
     v                                      v                  v
  Stage 0 (MAU 0)                    Stage 1 (MAU 1)      Stage 2 (MAU 2)
  * MAC Lookup                       * L3 FIB             * ACL
  * VLAN Check (并行)                * Next-hop Res      * QoS Remark
                                           │
                                           v
                                      Stage 3 (MAU 3)
                                      * Rewrite
                                      * TTL Dec
```

### 4.3 物理阶段限制

| 资源                   | Tofino 1 | Tofino 2 | Tofino 3 |
| ---------------------- | -------- | -------- | -------- |
| MAU Stages (Ingress)   | 32       | 32       | 32       |
| MAU Stages (Egress)    | 32       | 32       | 32       |
| SRAM (per stage)       | 4K       | 8K       | 16K      |
| TCAM (per stage)       | 1K       | 2K       | 4K       |
| Hash Units (per stage) | 2        | 4        | 4        |
| ALUs (per stage)       | 4        | 4        | 4        |

---

## 5. p4c 编译器优化

### 5.1 编译器流水线优化流程

```
P4 Program
     │
     │ Frontend (HLIR)
     │ - 类型检查
     │ - 控制流分析
     ├──────────────────────────────┐
     │                              │
     v                              v
┌─────────────────┐    ┌─────────────────────┐
│  MidEnd         │    │   Backend           │
│  - Dependency   │───>│   - Resource Alloc  │
│    Analysis     │    │   - Stage Mapping   │
│  - Logical Stg  │    │   - Place Tables    │
│    Assignment   │    │   - Generate JSON   │
└─────────────────┘    └─────────────────────┘
                            │
                            v
                      BFN/Tofino JSON
```

### 5.2 主要优化项

#### 5.2.1 表合并 (Table Merging)

将多个小表合并到一个物理表，利用 Key 的前缀共享：

```c
// 优化前: 两个独立表
table mac_dst_lookup {
    key = { h.ethernet.dstAddr : exact; }
    // ...
}

table mac_src_lookup {
    key = { h.ethernet.srcAddr : exact; }
    // ...
}

// 优化后: 合并为一个表 (共享存储)
table mac_lookup {
    key = {
        h.ethernet.dstAddr : exact;
        h.ethernet.srcAddr : exact;  // 添加为额外 Key
    }
    // ...
}
```

#### 5.2.2 Action 共享 (Action Sharing)

将多个动作合并到同一个 ALU 执行：

```c
// 优化前: 两个独立的动作
action set_dmac(...) { ... }
action set_smac(...) { ... }

// 优化后: 一个组合动作
action mac_rewrite(dmac, smac) {
    h.ethernet.dstAddr = dmac;
    h.ethernet.srcAddr = smac;
}
```

#### 5.2.3 表放置 (Table Placement)

根据表的大小和访问频率决定放置位置：

| 放置策略                        | 描述                               |
| ------------------------------- | ---------------------------------- |
| **早放置 (Early Placement)**    | 小表、高频表放在前面的 Stage       |
| **晚放置 (Late Placement)**     | 大表、低频表放在后面的 Stage       |
| **共享放置 (Shared Placement)** | 共享 Hash 计算单元的表放同一 Stage |

---

## 6. 资源分配详解

### 6.1 TCAM vs SRAM 选择

| 特性       | TCAM                    | SRAM (Exact)    | SRAM (LPM)     |
| ---------- | ----------------------- | --------------- | -------------- |
| Match 类型 | Ternary (任意掩码)      | Exact           | LPM (前缀匹配) |
| 查找速度   | O(1)                    | O(1)            | O(1)           |
| 容量       | 较小 (1-4K/stage)       | 大 (16K+/stage) | 中等           |
| 功耗       | 高                      | 低              | 低             |
| 成本       | 高                      | 低              | 中             |
| 典型用途   | ACL, Route (var-length) | MAC, Next-hop   | FIB (路由表)   |

### 6.2 Direct vs Indirect Resources

#### Direct Resources

Direct 资源与**单个表**绑定：

```c
// Direct Counter
table my_table {
    key = { h.ipv4.dstAddr : lpm; }
    actions = { forward; drop; }

    // Direct Counter: 每个表项一个计数器
    @pdml("counter", "bytes")
    direct counter<bit<64>>(PSA_CounterType_t.BYTES) ip_bytes;

    // Direct Meter: 每个表项一个 meter
    @pdml("meter", "packets")
    direct meter<bit<32>>(PSA_MeterType_t.PACKETS) pkts_meter;
}
```

#### Indirect Resources

Indirect 资源**共享使用**：

```c
// Indirect Counter (全局)
counter global_counter(PSA_CounterType_t.BYTES) my_counter;

// Indirect Meter (全局)
meter global_meter(PSA_MeterType_t.PACKETS) my_meter;

control Ingress(...) {
    apply {
        // 任何表都可以调用
        my_counter.count((bit<64>)metadata.packet_length);
        my_meter.execute((bit<32>)metadata.color);
    }
}
```

### 6.3 资源分配策略

| 策略         | 适用场景           |
| ------------ | ------------------ |
| **容量优先** | 大表放在 BRAM/DRAM |
| **延迟优先** | 热表放在 SRAM/TCAM |
| **负载均衡** | 均匀分布到各 Stage |
| **资源共享** | 小表合并共享资源   |

---

## 7. 流水线平衡

### 7.1 流水线瓶颈分析

流水线平衡是确保**各 Stage 负载均匀**的关键。

```
不平衡流水线:
==============

Stage 0: [████████████] 100%  (过载)
Stage 1: [████]         33%
Stage 2: [██]           17%
Stage 3: [████]         33%

结果: Stage 0 成为瓶颈，整体吞吐受限
```

### 7.2 平衡优化技术

#### 7.2.1 表拆分

将大表拆分为多个小表分布在不同 Stage：

```c
// 优化前: 一个巨大 ACL 表
table acl_large {
    key = {
        h.ipv4.srcAddr : ternary;
        h.ipv4.dstAddr : ternary;
        h.ipv4.protocol : ternary;
        h.tcp.srcPort : ternary;
        h.tcp.dstPort : ternary;
    }
    size = 128K;  // 太大!
    // ...
}

// 优化后: 拆分为多个阶段
table acl_l3 {
    key = {
        h.ipv4.srcAddr : ternary;
        h.ipv4.dstAddr : ternary;
    }
    size = 16K;
}

table acl_l4 {
    key = {
        h.ipv4.protocol : ternary;
        h.tcp.srcPort : ternary;
        h.tcp.dstPort : ternary;
    }
    size = 16K;
}
```

#### 7.2.2 动作拆分

将复杂动作拆分为多个简单动作：

```c
// 优化前: 一个复杂动作 (可能需要多周期)
action complete_rewrite(dmac, smac, sip, dip, sport, dport) {
    h.ethernet.dstAddr = dmac;
    h.ethernet.srcAddr = smac;
    h.ipv4.srcAddr = sip;
    h.ipv4.dstAddr = dip;
    h.tcp.srcPort = sport;
    h.tcp.dstPort = dport;
}

// 优化后: 拆分为多个动作
action set_ethernet(dmac, smac) {
    h.ethernet.dstAddr = dmac;
    h.ethernet.srcAddr = smac;
}

action set_ip(sip, dip) {
    h.ipv4.srcAddr = sip;
    h.ipv4.dstAddr = dip;
}

action set_transport(sport, dport) {
    h.tcp.srcPort = sport;
    h.tcp.dstPort = dport;
}
```

---

## 8. 流水线设计实战

### 8.1 典型交换机流水线设计

```
典型 L2/L3 交换机流水线:
============================

Ingress:
  Stage 0: [Parser] ──> [MAC Learning]
  Stage 1: [VLAN Check] ──> [STP/RSTP]
  Stage 2: [L2 Forwarding (MAC Table)]
  Stage 3: [L3 FIB (Longest Prefix Match)]
  Stage 4: [Next-hop Resolution]
  Stage 5: [ACL Check]
  Stage 6: [QoS Classification]
  Stage 7: [TTL/Salary Decrement]
  Stage 8: [Checksum Update]
  Stage 9: [Deparser]

Egress:
  Stage 0: [ACL Check]
  Stage 1: [Mirror/Resubmit Check]
  Stage 2: [Statistics Update]
  Stage 3: [Deparser]
```

### 8.2 流水线各阶段资源估算

| Stage      | 表项数量 | 资源类型     | 资源估算 |
| ---------- | -------- | ------------ | -------- |
| MAC Table  | 128K     | SRAM Exact   | 128K     |
| VLAN Table | 4K       | SRAM Exact   | 4K       |
| L3 FIB     | 512K     | TCAM+LPM     | 512K     |
| ACL        | 64K      | TCAM Ternary | 64K      |
| Next-hop   | 64K      | SRAM Exact   | 64K      |
| QoS        | 4K       | SRAM Exact   | 4K       |

---

## 9. 流水线调试与诊断

### 9.1 p4c 编译输出

使用 `--dump` 选项查看编译器输出：

```bash
p4c-bm2-ss --dump main.json -o main.bmv2.json my_program.p4
```

### 9.2 BFRTINFO 工具

使用 `bfrt_info` 查看表结构：

```bash
bfrt_info --device 0 --json main.bfrt.json
```

---

## 10. 总结

Pipeline 设计是 P4 数据平面编程的核心：

1. **逻辑阶段**：P4 程序中的执行顺序，由数据依赖决定
2. **物理阶段**：硬件的实际执行单元数量（如 Tofino 的 32 个 MAU Stage）
3. **编译器优化**：p4c 负责逻辑到物理的映射，包括表合并、动作共享等
4. **资源分配**：TCAM vs SRAM、Direct vs Indirect 的选择
5. **流水线平衡**：确保各 Stage 负载均匀，最大化吞吐

理解 Pipeline 设计是编写高性能 P4 程序的关键。下一章我们将探讨 Register 与状态管理，了解如何在流水线中维护动态状态。
