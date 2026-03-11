---
title: "DPDK Flow Template API (Hardware Steering) 深度指南"
date: 2026-01-04 00:00:00
pin: true
tags: [dpdk, flow-api, hardware-steering, template-api]
---


# DPDK Flow Template API (Hardware Steering) 深度指南

本文档汇总了关于 DPDK `rte_flow` Template API 的核心概念、设计哲学以及组件关系，并补充了异步操作的关键机制。

## 1. 核心概念：什么是 "Template"？

在 DPDK Hardware Steering API 中，**Template（模板）** 指的是流规则的**预设结构**或**形状**。

*   **传统模式 (`rte_flow_create`)**：每次创建规则时，驱动都需要解析完整的协议层级（Eth/IP/TCP...）和具体数值。这就像每次打印文件都要重新排版，速度慢且资源不可控。
*   **模板模式**：
    *   你提前告诉硬件：“我通过会有成千上万条规则，它们的长相都是 `Eth / IPv4 / TCP`”。
    *   硬件根据这个“形状”预先分配资源、优化流水线。
    *   后续插入规则时，只需快速填充具体数值（如 IP 地址），无需重新解析结构。

**核心收益**：将规则插入速度从 **kpps (千条/秒)** 提升至 **Mpps (百万条/秒)** 级别。

---

## 2. `rte_flow_pattern_template` 详解

`rte_flow_pattern_template` 定义了流规则的 **“匹配部分” (Matching Pattern)**。它是不可变的结构描述符。

### 组成要素
1.  **Items (协议层)**：定义要匹配哪些协议头（如 `RTE_FLOW_ITEM_TYPE_IPV4`）。
2.  **Masks (掩码)**：定义在这些协议头中，哪些字段是**关键字段**（需要匹配），哪些是**无关字段**（忽略）。

### 示例
如果你创建了一个模板：
*   **Pattern**: Eth / IPv4 / UDP
*   **Mask**: IPv4(Src IP=FFFFFFFF, Dst IP=0), UDP(Src Port=FFFF, Dst Port=FFFF)

**这意味着**：基于此模板创建的所有规则，**必须**是 IPv4 UDP 包，且硬件会根据 **源IP** 和 **UDP端口** 来区分流量，忽略目的IP。

---

## 3. 为什么非 Template 模式需要 `validate`？

在传统 API 中，`rte_flow_validate()` 是一个至关重要的**探测器**，原因如下：

1.  **可行性检查 (Feasibility Check)**：
    *   DPDK API 定义极其宽泛，但物理网卡能力有限。`validate` 用于确认硬件是否支持当前的协议组合（例如：能否同时匹配 IPv6 Extension Header 和 GRE Tunnel）。
2.  **资源预演 (Dry Run)**：
    *   `create` 操作涉及昂贵的硬件资源分配。`validate` 仅在软件层检查逻辑，不触碰硬件，避免因失败导致的资源浪费或状态残留。
3.  **最佳策略协商**：
    *   应用可以先尝试“全卸载”，如果 `validate` 失败，再降级为“部分卸载”或“RSS 均衡”。
4.  **冲突检测**：
    *   检查当前规则是否与已存在的规则冲突（如动作互斥）。

**为什么 Template 模式不需要？**
*   检查被前置到了 **Table 创建阶段**。一旦 `rte_flow_template_table_create` 成功，代表硬件已经承诺支持该模板结构，后续插入无需再次验证。

---

## 4. Pattern 与 Actions 的对应关系

在 Template API 中，匹配（Pattern）与动作（Action）是**多对多**的关系，通过 **Template Table** 进行绑定。

### 结构层级
1.  **Level 1: 模板定义 (独立)**
    *   定义 N 个 `Pattern Templates` (PT1, PT2...)
    *   定义 M 个 `Actions Templates` (AT1, AT2...)
    *   *此时它们互不相关。*

2.  **Level 2: 模板表 (绑定)**
    *   创建一个 `Template Table`。
    *   **绑定**：指定该表使用 `[PT1, PT3]` 和 `[AT1, AT2]`。
    *   *硬件此时锁定资源。*

3.  **Level 3: 规则插入 (选择)**
    *   调用 `rte_flow_async_create`。
    *   **选择**：指定 `pattern_template_index=0` (使用 PT1) 和 `actions_template_index=1` (使用 AT2)。

### 关键点
*   **Table 是桥梁**：只有在同一张 Table 里，Pattern 和 Action 才能组合。
*   **灵活性**：同一个模板可以被不同的 Table 复用。

---

## 5. 补充：异步机制 (Async Mechanism)

这是 Template API 高性能的另一个关键支柱，之前讨论较少，在此补充：

### 5.1 异步队列 (`rte_flow_queue`)
*   传统的 `rte_flow_create` 是同步阻塞的：CPU 发指令 -> 等待网卡写寄存器 -> 等待网卡返回结果 -> 函数返回。这在 PCIe 总线上产生了巨大的等待延迟（Latency）。
*   Template API 使用 **Queue** 模式：
    *   应用将“插入规则”的指令推入队列。
    *   CPU 不等待，立即处理下一条指令。

### 5.2 Push & Pull 模式
为了利用异步队列，应用通常涉及以下操作：

1.  **Post (或者叫 Create)**：调用 `rte_flow_async_create()`。
    *   该操作受 `struct rte_flow_op_attr` 中的 `postpone` 字段控制。
    *   **如果 `postpone = 1`**：任务仅放进软件队列，**还没有发给硬件**。应用必须随后调用 `rte_flow_push()`。
    *   **如果 `postpone = 0`**：任务会被立即提交到硬件（或由驱动隐式提交）。这就是为什么在某些示例（如 `flow_filtering`）中看不到显式 `push` 调用的原因。
2.  **Push**：调用 `rte_flow_push()`。将软件队列中的一批任务“刷”到网卡硬件（Doorbell）。这在需要批量提交以优化性能时非常有用。
3.  **Pull**：调用 `rte_flow_pull()`。查询硬件，回收已经完成的任务结果（Completion）。

**性能秘诀**：通过 `Push` 批量提交任务，均摊了 PCIe 通信的开销（Doorbell Batching），从而实现了极高的吞吐量。

### 5.3 资源管理
*   在 Template 模式下，**流规则对象的内存由应用管理**，而不是 PMD。
*   应用需要预先分配好规则所需的内存，并在 `async_create` 时传入指针。这避免了驱动层频繁的 `malloc/free` 开销。

---

## 总结

DPDK Flow Template API 是为了解决传统 API **“解析慢、锁竞争、同步等待”** 三大痛点而生的。

*   **Template** 解决了解析慢。
*   **Pre-allocation (Table)** 解决了资源分配慢。
*   **Async Queue (Push/Pull)** 解决了同步等待延迟。
