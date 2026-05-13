---
title: "P4 深度探索 (十二)：TNA 架构——Tofino Native Architecture、高性能流水线"
date: 2026-04-14
tags: [p4, series, tna, tofino, architecture, pipeline, native-architecture, intel, p4-16]
description: "P4 TNA 架构深度解析——Tofino Native Architecture 完整架构、MAU (Match-Action Unit)、Gate List、Packet Clock、Ingress/Egress 优化、BFN (布隆过滤器)、Tofino 专属特性"
---

> [!info] P4 深度探索系列
> 0. [[2026-04-14-p4-deep-dive-series-index|全栈学习路径总览]]
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
> 12. **第十二章：TNA 架构——Tofino Native Architecture、高性能流水线**

---

## 1. 概述：TNA 是 Tofino 的原生架构

**TNA (Tofino Native Architecture)** 是 Intel Tofino 系列交换芯片的原生 P4 架构。它在 PSA 基础上添加了大量 Tofino 特定的优化和硬件原生支持，是实现**线速处理 (Wire-speed Processing)** 的关键。

与 PSA 相比，TNA 的核心区别：
- **硬件原生**：充分利用 Tofino 的并行处理能力
- **确定性延迟**：流水线级数固定，延迟可精确预测
- **丰富资源**：超大容量的 TCAM/RAM 资源
- **专用加速**：DDoS 防护、Network Address Translation 等硬件加速

---

## 2. Tofino 芯片架构概览

```
+==============================================================================+
|                           INTEL TOFINO SWITCH                                |
+==============================================================================+

    +-----------+    +-----------+    +-----------+    +-----------+
    |  Port 0   |    |  Port 1   |    |  Port 2   |    |  Port 63  |
    |  100G     |    |  100G     |    |  100G     |    |  100G     |
    +-----+-----+    +-----+-----+    +-----+-----+    +-----+-----+
          |              |              |              |
          v              v              v              v
    +---------------------------------------------------------------+
    |                     Ingress Pipeline (Shared)                  |
    |  +-----------+  +-----------+  +-----------+  +-----------+  |
    |  |  Ingress  |  |   MAU     |  |   MAU     |  |   MAU     |  |
    |  |  Parser   |->|  Stage 0  |->|  Stage 1  |->|  Stage N  |  |
    |  +-----------+  +-----------+  +-----------+  +-----------+  |
    +---------------------------------------------------------------+
          |                                      |
          v                                      v
    +---------------------------------------------------------------+
    |                      Traffic Manager                          |
    |   +-------------+  +-------------+  +-------------+             |
    |   |   Queue     |  |  Multicast  |  |  Clone/     |             |
    |   |   Engine    |  |  Engine     |  |  Resubmit   |             |
    |   +-------------+  +-------------+  +-------------+             |
    +---------------------------------------------------------------+
          |                                      |
          v                                      v
    +---------------------------------------------------------------+
    |                     Egress Pipeline (Shared)                    |
    |  +-----------+  +-----------+  +-----------+  +-----------+  |
    |  |   MAU     |  |   MAU     |  |   MAU     |  |  Egress   |  |
    |  |  Stage 0  |->|  Stage 1  |->|  Stage N  |->|  Deparser |  |
    |  +-----------+  +-----------+  +-----------+  +-----------+  |
    +---------------------------------------------------------------+
          |              |              |              |
          v              v              v              v
    +-----------+    +-----------+    +-----------+    +-----------+
    |  Port 0   |    |  Port 1   |    |  Port 2   |    |  Port 63  |
    +-----------+    +-----------+    +-----------+    +-----------+

+==============================================================================+
|                              KEY COMPONENTS                                  |
+==============================================================================+

+---------------+     +---------------+     +---------------+
|  Ingress MAU  |     | Traffic Mgr   |     |  Egress MAU  |
|  ============ |     | ============= |     | ============= |
|  * 32 stages  |     | * 16K queues  |     | * 32 stages  |
|  * Parallel   |     | * 128         |     | * Parallel    |
|    lookup     |     |   multicast   |     |   lookup     |
|  * 4 ALUs/stage|    |   groups      |     | * 4 ALUs/stage|
|  * Gate logic |     | * Clone/session|     | * Gate logic |
+---------------+     +---------------+     +---------------+
```

---

## 3. MAU (Match-Action Unit) 详解

### 3.1 MAU 架构

MAU 是 Tofino 流水线的核心执行单元。每个 MAU Stage 包含：

```
┌─────────────────────────────────────────────────────────────────┐
│                      MAU Stage Architecture                      │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   Input ──┬─────────────────────────────────────────┬─> Output   │
│   Gate   │                                         │   Gate     │
│   List   │   +-----------+   +-----------+        │            │
│          │   | Hash Unit |   | TCAM Unit |        │            │
│          │   +-----------+   +-----------+        │            │
│          │         │             │                │            │
│          │         v             v                │            │
│          │   +-------------------------+        │            │
│          │   |    Action Engine (ALU)   |        │            │
│          │   |    * 4 execution lanes   |        │            │
│          │   |    * 256-bit registers   |        │            │
│          │   +-------------------------+        │            │
│          │                                         │            │
│          │   +---------------+                    │            │
│          │   | Local SRAM    |                    │            │
│          │   | (exact match) |                    │            │
│          │   +---------------+                    │            │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### 3.2 Packet Gate

**Gate** 是 TNA 中的基本执行控制单元。每个 Gate 包含：
- **Condition**：执行条件（布尔表达式）
- **True Action List**：条件为真时执行的动作列表
- **False Action List**：条件为假时执行的动作列表

```c
// TNA Gate 示例
gate my_gate = {
    condition: h.ipv4.isValid();
    true_action: ipv4_forward();
    false_action: drop();
};
```

### 3.3 Gate List 顺序执行

多个 Gate 组成 Gate List，按顺序执行：

```
Gate List Execution:
┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐
│  Gate 0  | -> |  Gate 1  | -> |  Gate 2  | -> |  Gate 3  |
│ (Verify) |    │ (L2 Look)|    │ (L3 Look)|    │ (ACL)    │
└──────────┘    └──────────┘    └──────────┘    └──────────┘
     │               │               │               │
     v               v               v               v
  Next Gate      Next Gate      Next Gate      Next Gate
```

### 3.4 MAU Stage 并行执行

Tofino 的 MAU 支持**跨 Stage 并行查找**：

```
Time →
Stage 0: [查找 MAC table] ──────────────────> [结果]
Stage 1:      [查找 L3 route] ──────────────> [结果]
Stage 2:           [ACL check] ─────────────> [结果]
Stage 3:                [QoS remark] ──────> [结果]

注意：虽然逻辑上是串行的 Gate List，
但不同 Stage 的操作可以并行发射 (parallel dispatch)
```

---

## 4. Ingress Pipeline 详解

### 4.1 Ingress 流水线阶段

```
Ingress Pipeline (Tofino):
====================

Port ──> Parser ──> MAU Stage 0 ──> MAU Stage 1 ──> ... ──> MAU Stage 15 ──> Deparser ──> Traffic Manager
              │                                                                      │
              │ (提取 Header)                                         (发射 Header)   │
              v                                                                      v
         提取完成后                                               所有 Stage 完成后
         进入 MAU                                                  进入 Deparser
```

### 4.2 Ingress Parser 特性

Tofino Parser 支持：
- **并行提取**：多个字段可同时提取
- **状态机并行**：多个解析状态可并行处理
- **Header 长度自动推断**：PLENGTH 机制

```c
// Tofino Parser 并行提取示例
parser IngressParser(...) {
    // 这些字段可以并行提取
    extract(h.ethernet.dstAddr);  // Field Slice 0
    extract(h.ethernet.srcAddr);  // Field Slice 1 (并行)
    extract(h.ethernet.etherType); // Field Slice 2 (并行)
}
```

### 4.3 Ingress MAU 资源

| 资源类型 | 每 Stage 容量 | 总计 (32 Stage) |
|----------|--------------|-----------------|
| SRAM (TCAM) | 4K entries | 128K entries |
| SRAM (Exact) | 16K entries | 512K entries |
| ALUs | 4 | 128 |
| Hash Units | 2 | 64 |
| Action Memory | 4K instructions | 128K instructions |

---

## 5. Traffic Manager 深度解析

### 5.1 TM 架构

```
+==========================================================================+
|                         TRAFFIC MANAGER                                 |
+==========================================================================+

    Ingress MAU ──────────────────────────────────────────────────────┐
                                                                    │
                                                                    v
                                              +-------------------+
                                              |   FIFO Buffer     |
                                              |   (Global Shared) |
                                              +-------------------+
                                                      |
                                                      v
                    +--------------------+---------------------------+
                    |                    |                           |
                    v                    v                           v
            +-------------+        +-------------+            +-------------+
            | UC Queue    |        | MC Queue    |            | Clone Queue|
            | (Unicast)   |        | (Multicast) |            | (Clone/    |
            |             |        |             |            |  Resubmit)  |
            +-------------+        +-------------+            +-------------+
                    |                    |                           |
                    v                    v                           v
            +-------------+        +-------------+            +-------------+
            | Scheduler   |        |   MCF       |            |   Clone    |
            | (SP/WFQ)    |        | (Multicast  |            |   Engine   |
            |             |        |  Fabric)    |            |             |
            +-------------+        +-------------+            +-------------+
                    |                    |                           |
                    +--------------------+---------------------------+
                                            |
                                            v
                                    +---------------+
                                    |    Egress     |
                                    |    MAU        |
                                    +---------------+
```

### 5.2 队列架构

Tofino TM 支持**多级队列**：

```
Port 0
  |
  +-- Pipe 0
  |     +-- Traffic Class 0 (Queue 0-7)
  |     +-- Traffic Class 1 (Queue 8-15)
  |     +-- Traffic Class 2 (Queue 16-23)
  |     +-- Traffic Class 3 (Queue 24-31)
  |
  +-- Pipe 1
  |     +-- Traffic Class 0-3
  |
  +-- Pipe 2 ...
```

### 5.3 调度机制

| 调度类型 | 描述 |
|----------|------|
| **Strict Priority (SP)** | 严格优先级调度 |
| **Deficit Weighted Round Robin (DWRR)** | 基于信用值的加权调度 |
| **Enhanced Transmission Selection (ETS)** | 带宽保证+优先级 |
| **Per-Port Shaping** | 端口级整形 |

---

## 6. Egress Pipeline 详解

### 6.1 Egress 流水线阶段

```
Egress Pipeline (Tofino):
=====================

Traffic Manager ──> MAU Stage 0 ──> MAU Stage 1 ──> ... ──> MAU Stage 15 ──> Deparser ──> Port
                   │                                                                   │
                   │ (Packet Clone 时，可能有多路输入)                                │
                   v                                                                   v
              Clone/Resubmit                                                   最终发射
              重新入队
```

### 6.2 Egress MAU 用途

Egress Pipeline 典型用途：

1. **TTL/Salary 递减**：IP TTL、VXLAN TTL
2. **Checksum 修正**：重新计算 IPv4/TCP/UDP checksum
3. **出口 ACL**：更精细的出口过滤
4. **Mirror 决策**：基于出口的镜像
5. **统计更新**：Egress 方向的流量统计

### 6.3 Egress Parser 特性

Egress Parser 与 Ingress Parser 类似，但处理的是**经过 TM 的数据包**：

- **可能与 Ingress 不同**：由于 Clone/Resubmit，包内容可能已被修改
- **Timestamp 可用**：可提取入队/出队时间戳
- **队列信息可用**：可提取队列深度等信息

---

## 7. TNA 专属特性

### 7.1 Digest (镜像反馈)

Digest 用于将数据包信息**异步反馈**给控制面：

```c
// TNA Digest 示例
control Ingress(...) {
    
    digest<mac_learn_digest_t>(1) mac_learn;  // digest_id = 1
    
    action mac_learn() {
        // 创建 MAC 学习消息
        mac_learn_digest_t d = {
            srcMac : h.ethernet.srcAddr,
            port   : ismd.ingress_port
        };
        mac_learn.pack(d);  // 发送给控制面
    }
    
    table mac_learn_table {
        // ...
    }
    
    apply {
        mac_learn_table.apply();
    }
}
```

### 7.2 Clone Session (包镜像)

Clone Session 用于创建数据包的**精确副本**：

```c
// Clone Session 配置 (通过 BFRT/gRPC)
struct CloneSession_t {
    uint32_t session_id;
    uint16_t multicast_group_id;  // 或 egress_port
    uint8_t  class_of_service;
    uint16_t truncate_length;     // 0 = 不截断
};
```

### 7.3 Idletime (表项老化)

TNA 支持对 TCAM/SRAM 表项进行**基于时间的老化**：

```c
// Idletime 示例
table mac_table {
    key = { h.ethernet.srcAddr : exact; }
    actions = { mac_learn; }
    default_action = mac_learn;
    
    // 表项空闲超时后自动删除
    const idle_timeout = true;
    idle_timeout_seconds = 300;  // 5分钟
}
```

---

## 8. TNA 程序模板

### 8.1 TNA P4-16 程序结构

```c
#include <core.p4>
#include <tna.p4>

// ========== Header/Meta 定义 ==========
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

struct headers_t {
    ethernet_t ethernet;
    ipv4_t     ipv4;
}

struct metadata_t {
    bit<32> nexthop_id;
}

// ========== Ingress Pipeline ==========
Pipeline(IngressParser(), Ingress(), IngressDeparser()) ip;

// ========== Egress Pipeline ==========
Pipeline(EgressParser(), Egress(), EgressDeparser()) ep;

// ========== Main ==========
PSA_Switch(ip, ep) main;
```

---

## 9. TNA vs PSA 性能对比

| 指标 | PSA (BMv2) | TNA (Tofino) |
|------|-----------|--------------|
| 吞吐量 | ~10Mpps | ~1000Mpps (3.2T) |
| 延迟 | 10-50μs | **< 1μs** |
| 表容量 | 受限 | 数十 M entries |
| TCAM | 可选 | 原生支持 |
| 并行度 | 有限 | 32 Stage × 4 ALUs |
| 队列 | 简单 | 16K+ 队列 |

---

## 10. 总结

TNA 是 Intel Tofino 的原生架构，通过以下机制实现高性能：

1. **MAU 多级并行**：32 个 Stage，每个 Stage 4 个 ALU
2. **Gate List 确定性执行**：固定的流水线级数
3. **Traffic Manager 灵活调度**：多级队列 + 多种调度算法
4. **硬件原生资源**：超大 TCAM/SRAM 容量

TNA 在 PSA 基础上添加了 Tofino 特定的优化，是商用交换芯片的标杆架构。下一章我们将深入 Pipeline 设计，理解 Match-Action 流水线的逻辑与物理映射。
