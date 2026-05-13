---
title: "P4 深度探索 (十一)：PSA 架构——Portable Switch Architecture、Ingress/Egress 管道"
date: 2026-04-14
tags:
  [p4, series, psa, architecture, portable-switch-architecture, ingress, egress, pipeline, p4-16]
description: "P4 PSA 架构深度解析——Portable Switch Architecture 完整架构图、Ingress/Egress 流水线、Packet 生命周期、PSA 各阶段信号、Buffer 机制、Traffic Manager、调度器"
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
> 11. **第十一章：PSA 架构——Portable Switch Architecture、Ingress/Egress 管道**

---

## 1. 概述：PSA 是 P4 的标准架构抽象

**PSA (Portable Switch Architecture)** 是 P4 语言联盟（ P4.org ）为实现跨平台可移植性而定义的标准交换架构规范。它抽象了网络交换机的通用数据平面结构，定义了 Packet 从入端口到出端口所经过的完整处理流程。

PSA 的设计目标：

- **架构可移植**：同一份 P4 程序可以在 BMv2、Tofino、Broadcom 等不同硬件上运行
- **语义清晰**：明确定义 Ingress/Egress、Buffer、Traffic Manager 的行为
- **功能完整**：覆盖 L2/L3 转发、ACL、QoS、Multicast 等典型交换功能

### 1.1 PSA vs V1Model

PSA 是 P4-16 时代的标准架构，V1Model 是 P4-14 时代的遗留架构。两者对比：

| 特性                | V1Model     | PSA                                |
| ------------------- | ----------- | ---------------------------------- |
| P4 版本             | P4-14       | P4-16                              |
| Ingress/Egress 分离 | 是          | 是（更清晰）                       |
| Packet Buffer       | 不透明      | 显式 Traffic Manager               |
| Multicast           | 基本        | 支持 Copy-Field/Multicast Group    |
| Clone               | basic_clone | Pre/Post-ingress/post-egress clone |
| 标准 Metadata       | fixed       | 扩展性更好                         |

---

## 2. PSA 完整架构图

```
                    +-----------------------------------------------------------------+
                    |                          PACKET FLOW                             |
                    +-----------------------------------------------------------------+

    +---------+                   +------------------+                   +---------+
    | Ingress |                   |                  |                   |  Egress |
    |  Port   | ----------------> |  Ingress Pipe    | ----------------> |  Port   |
    +---------+                   +------------------+                   +---------+
                                     |        ^                               ^
                                     |        |                               |
                                     v        |                               v
                            +------------------+                    +------------------+
                            | Traffic Manager  |                    | Traffic Manager  |
                            |   (Buffer/QoS)   |                    |   (Buffer/QoS)   |
                            +------------------+                    +------------------+
                                     |        ^                               |
                                     |        |                               |
                                     v        |                               v
                            +------------------+                    +------------------+
                            |   Packet Data    |                    |   Packet Data    |
                            |     Buffer       |                    |     Buffer       |
                            +------------------+                    +------------------+


    +---------------------------------------------------------------------------------------+
    |                                    PSA ARCHITECTURE                                   |
    +---------------------------------------------------------------------------------------+

    +----------+      +-------------+      +---------------+      +-------------+      +----------+
    | Ingress  |      |   Ingress   |      |    Traffic    |      |    Egress   |      |  Egress  |
    |  Ports   | ---> |  Pipeline   | ---> |   Manager     | ---> |  Pipeline   | ---> |  Ports   |
    |(Phy/Logic)     |  (Parse+Ing+ |      |(Buffer, Queue,|      |(Egr+Depars) |      |(Phy/Logic)
    +----------+      |  Depars)    |      |  Multicast,   |      +-------------+      +----------+
                      +-------------+      |  Clone)        |
                                           +---------------+

    +===============+                     +===============+                     +===============+
    !  PSA Intrinsic !                     ! PSA Intrinsic !                     ! PSA Intrinsic !
    !    Metadata    !                     !    Metadata    !                     !    Metadata    !
    ! (ingress_port, !                     !    (eg_intr)    !                     ! (egress_port, !
    !  pkt_length,   !                     !                !                     !  pkt_length,  !
    !  queue_size)   !                     !                !                     !  queue_depth) !
    +===============+                     +===============+                     +===============+
```

---

## 3. Packet 生命周期

一个数据包在 PSA 中的完整生命周期：

### 3.1 Ingress Port

数据包从物理端口或逻辑端口进入交换机。入口端口信息被记录在 `standard_metadata.ingress_port` 中。

```c
// PSA Intrinsic Metadata (入口)
struct standard_metadata_t {
    bit<9>  ingress_port;      // 入端口号
    bit<8>  instance_type;     // 包实例类型 (正常/克隆/递归)
    bit<32> packet_length;     // 包长度
    // ... 其他字段
}
```

### 3.2 Ingress Pipeline

Ingress Pipeline 包含三个顺序执行的阶段：

```
Ingress Pipeline 顺序：
┌────────────┐     ┌────────────┐     ┌────────────┐
│  Parser    | --> |  Ingress   | --> |  Deparser  |
│  (提取)    |     |  Control   |     |  (重组)    |
└────────────┘     │ (Match-Act) |     └────────────┘
                   └────────────┘
```

**Parser** 负责从数据包中提取 Headers，将解析状态存储在 `headers` 结构中。

**Ingress Control** 负责：

- L2 学习/Lookup (MAC 表)
- L3 路由查找 (RIB/FIB)
- ACL 检查
- Next-Hop 解析
- QoS 分类
- 出口端口决策

**Deparser** 将处理后的 Headers 重新组装成数据包。

### 3.3 Traffic Manager

Traffic Manager 是 PSA 架构的核心组件，负责：

| 功能           | 描述                              |
| -------------- | --------------------------------- |
| **Buffering**  | 临时存储数据包，等待调度          |
| **Queuing**    | 多级队列管理（优先级队列、WFQ）   |
| **Scheduling** | 决定数据包何时从哪个队列发出      |
| **Multicast**  | 将数据包复制到多个出口            |
| **Clone**      | 创建数据包副本（用于镜像/锚点）   |
| **Resubmit**   | 将数据包重新注入 Ingress Pipeline |

```c
// Traffic Manager 操作 (通过 PSA Extern 调用)
extern TrafficManager {
    // 克隆包到指定出口或特殊目的
    void clone(in bit<32> session, in bit<9> egress_port);

    // 复制包到多个出口
    void multicast(in bit<16> multicast_group);

    // 重新入队（用于 QoS 重新调度）
    void enqueue(bit<9> port, bit<8> queue_id, in packet p);
}
```

### 3.4 Egress Pipeline

Egress Pipeline 同样包含 Parser、Control、Deparser 三阶段：

```
Egress Pipeline 顺序：
┌────────────┐     ┌────────────┐     ┌────────────┐
│  Parser    | --> |   Egress   | --> |  Deparser  |
│  (提取)    |     |  Control   |     |  (重组)    |
└────────────┘     │ (Match-Act) |     └────────────┘
                   └────────────┘
```

**Egress Control** 典型用途：

- TTL 递减
- Checksum 重新计算
- 出口 VLAN Tag 处理
- 出口 ACL 检查
- 统计计数更新

### 3.5 Egress Port

数据包从物理端口发送到线缆。

---

## 4. PSA Intrinsic Metadata 详解

PSA 定义了三类 Intrinsic Metadata：

### 4.1 Ingress Intrinsic Metadata

```c
struct psa_ingress_intrinsic_metadata_t {
    bit<9>  ingress_port;           // 入口端口
    bit<8>  packet_priority;        // 包优先级 (QoS)
    bit<16> ingress_collection;     // 可选的 collection ID
}
```

### 4.2 Common Intrinsic Metadata (Ingress → Egress)

```c
struct psa_ingress_to_egress_metadata_t {
    bit<8>  class_of_service;       // 服务等级
    bit<32> enq_timestamp;         // 入队时间戳
    bit<16> enq_qid;               // 队列 ID
    bit<3>  enq_qdepth;            // 入队时队列深度
}
```

### 4.3 Egress Intrinsic Metadata

```c
struct psa_egress_intrinsic_metadata_t {
    bit<9>  egress_port;           // 出口端口
    bit<8>  class_of_service;       // 服务等级
    bit<32> deq_timestamp;         // 出队时间戳
    bit<16> deq_qid;               // 队列 ID
    bit<19> deq_qdepth;            // 出队时队列深度 (19 bits for high-speed)
}
```

---

## 5. Multicast 与 Clone 机制

### 5.1 Multicast

PSA 支持将一个数据包复制到多个出口。Multicast 在 Traffic Manager 中实现：

```c
control IngressControl(inout headers h,
                       inout metadata m,
                       inout standard_metadata_t sm) {

    action multicast(bit<16> group_id) {
        // 设置多播组 ID，Traffic Manager 会复制包到该组所有端口
        sm.multicast_group = group_id;
    }

    table multicast_table {
        key = { h.ipv4.dstAddr : lpm; }
        actions = { multicast; }
        default_action = NoAction;
    }

    apply {
        if (h.ipv4.isValid()) {
            multicast_table.apply();
        }
    }
}
```

### 5.2 Clone (Mirror)

Clone 用于创建包的精确副本，常见用途：

- **端口镜像**：将流量复制到监控端口
- **锚点 (Anchoring)**：保存包的状态用于后续处理
- **OAM**：Operations, Administration & Maintenance

```c
// Clone Session 定义 (控制面配置)
struct clone_session_t {
    bit<32> session_id;
    bit<9>  egress_port;    // 克隆目的地
    bit<8>  class_of_service;
    bool    truncate;        // 是否截断
    bit<16> truncate_length;
}
```

---

## 6. PSA 的 Buffer 管理

### 6.1 队列结构

PSA 的 Traffic Manager 通常实现多级队列：

```
Port
  |
  +-- Queue 0 (Highest Priority, SP)
  +-- Queue 1 (Medium Priority)
  +-- Queue 2 (Low Priority)
  +-- Queue 3 (Best Effort)
  ...
  +-- Queue N
```

### 6.2 调度算法

| 调度算法                        | 描述                                         |
| ------------------------------- | -------------------------------------------- |
| **Strict Priority (SP)**        | 严格优先级，只有高优先级队列空才服务低优先级 |
| **WRR (Weighted Round Robin)**  | 加权轮询，按权重比例服务                     |
| **WFQ (Weighted Fair Queuing)** | 加权公平队列，基于字节数的公平调度           |
| **Deficit Round Robin (DRR)**   | 赤字轮询，弥补 WRR 的包长度差异问题          |

---

## 7. PSA 程序模板

### 7.1 完整 PSA P4-16 程序结构

```c
#include <core.p4>
#include <psa.p4>

// ========== Header 定义 ==========
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
    // 用户自定义 metadata
    bit<32> nexthop_id;
}

// ========== Parser ==========
parser IngressParser(packet_in buffer,
                     out headers_t h,
                     inout metadata_t m,
                     in psa_ingress_input_metadata_t ismd,
                     in psa_ingress_output_metadata_t osmd) {

    state start {
        buffer.extract(h.ethernet);
        transition select(h.ethernet.etherType) {
            0x0800: parse_ipv4;
            default: accept;
        }
    }

    state parse_ipv4 {
        buffer.extract(h.ipv4);
        transition accept;
    }
}

// ========== Ingress Control ==========
control Ingress(inout headers_t h,
                inout metadata_t m,
                in    psa_ingress_input_metadata_t  ismd,
                inout psa_ingress_output_metadata_t osmd) {

    action drop() {
        osmd.drop = true;
    }

    action forward(bit<9> port) {
        osmd.egress_port = port;
    }

    table ipv4_lpm {
        key = { h.ipv4.dstAddr : lpm; }
        actions = { forward; drop; }
        default_action = drop;
    }

    apply {
        if (h.ipv4.isValid()) {
            ipv4_lpm.apply();
        }
    }
}

// ========== Ingress Deparser ==========
control IngressDeparser(packet_out packet,
                        out clone_session_id_t clone_session,
                        out psa_ingress_to_egress_metadata_t i2e,
                        in headers_t h,
                        in metadata_t m,
                        in psa_ingress_output_metadata_t osmd) {

    apply {
        packet.emit(h.ethernet);
        packet.emit(h.ipv4);
    }
}

// ========== Egress Parser ==========
parser EgressParser(packet_in buffer,
                    out headers_t h,
                    inout metadata_t m,
                    in psa_egress_input_metadata_t esmd,
                    in psa_egress_output_metadata_t osmd) {

    state start {
        buffer.extract(h.ethernet);
        transition select(h.ethernet.etherType) {
            0x0800: parse_ipv4;
            default: accept;
        }
    }

    state parse_ipv4 {
        buffer.extract(h.ipv4);
        transition accept;
    }
}

// ========== Egress Control ==========
control Egress(inout headers_t h,
               inout metadata_t m,
               in    psa_egress_input_metadata_t  esmd,
               inout psa_egress_output_metadata_t osmd) {

    apply {
        // TTL 递减
        if (h.ipv4.isValid()) {
            h.ipv4.ttl = h.ipv4.ttl - 1;
        }
    }
}

// ========== Egress Deparser ==========
control EgressDeparser(packet_out packet,
                       in headers_t h,
                       in metadata_t m,
                       in psa_egress_output_metadata_t osmd) {

    apply {
        packet.emit(h.ethernet);
        packet.emit(h.ipv4);
    }
}

// ========== PSA Switch ==========
Pipeline<headers_t, metadata_t,
         headers_t, metadata_t,
         headers_t, metadata_t>
main IngressPipeline(IngressParser(), Ingress(), IngressDeparser());

Pipeline<headers_t, metadata_t,
         headers_t, metadata_t,
         headers_t, metadata_t>
main EgressPipeline(EgressParser(), Egress(), EgressDeparser());

PSA_Switch(IngressPipeline(), EgressPipeline()) main;
```

---

## 8. PSA 与 TNA 的关系

| 特性       | PSA                | TNA                   |
| ---------- | ------------------ | --------------------- |
| 设计目标   | 跨平台可移植       | Intel Tofino 性能优化 |
| 架构复杂度 | 简化抽象           | 硬件原生              |
| 支持硬件   | BMv2, Tofino, etc. | Intel Tofino only     |
| 资源模型   | 通用               | Tofino 原生 RAM/TCAM  |
| 扩展性     | 通过 Extern        | 原生支持更多功能      |

PSA 是**规范 (Specification)**，TNA 是**实现 (Implementation)**。TNA 在 PSA 基础上添加了 Tofino 特定的优化和扩展。

---

## 9. 总结

PSA 架构是 P4 语言实现跨平台可移植性的核心抽象：

1. **清晰的分层**：Ingress Port → Ingress Pipeline → Traffic Manager → Egress Pipeline → Egress Port
2. **完整的 Buffer 管理**：多级队列、多种调度算法
3. **丰富的复制机制**：Multicast、Clone、Resubmit
4. **标准化的 Metadata**：Ingress/Egress Intrinsic Metadata 定义清晰

理解 PSA 是掌握 P4 数据平面编程的基础，下一章我们将深入 TNA 架构，了解 Tofino 的原生优化。
