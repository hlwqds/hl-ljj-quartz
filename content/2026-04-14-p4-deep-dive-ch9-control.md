---
title: "P4 深度探索 (九)：Control 编程——Control Block、条件判断、Action 调用链"
date: 2026-04-14
tags: [p4, series, control, apply, conditionals, action-invocation, pipeline, p4-16]
description: "P4 Control 编程深度解析——Control Block 结构、apply 方法、条件语句 if-else、Action 调用链、Control 之间的调用、Pipeline 阶段的编排、PSA/V1Model 中的 Ingress/Egress Control"
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
> 9. **第九章：Control 编程——Control Block、条件判断、Action 调用链**

---

## 1. 概述：Control 是 P4 程序的业务逻辑编排

**Control** 是 P4 程序中负责**业务逻辑编排**的组件。如果说 Parser 是数据包的"解读器"，Table 是"查表器"，那么 Control 就是"决策者"——它决定数据包的流向、应用哪些表、以什么顺序应用。

在 PSA（Portable Switch Architecture）或 V1Model 中，每个数据包会经过：

1. **Parser** — 解析协议头
2. **Ingress Control** — 入口流水线，决定出口和初始处理
3. **Egress Control** — 出口流水线，决定最终修改
4. **Deparser** — 重新组装数据包

Control 编程的核心是 `apply` 块——一个包含条件判断、表查询、动作调用的顺序执行块。

---

## 2. Control 的基本结构

### 2.1 Control 声明

```c
control ControlName(inout headers h,
                    inout metadata m,
                    inout standard_metadata_t sm) {

    // ========== 本地声明 ==========

    // 动作声明
    action action1(...) { ... }
    action action2(...) { ... }

    // 表声明
    table table1 { ... }
    table table2 { ... }

    // ========== apply 块 ==========
    apply {
        // 业务逻辑
    }
}
```

### 2.2 完整 Control 示例

```c
control MyIngress(inout headers h,
                  inout metadata m,
                  inout standard_metadata_t sm) {

    // ----- 动作声明 -----
    action drop() {
        mark_to_drop(sm);
    }

    action forward(bit<9> port) {
        sm.egress_spec = port;
    }

    action set_dmac(bit<48> dmac) {
        h.ethernet.dstAddr = dmac;
    }

    action decrement_ttl() {
        h.ipv4.ttl = h.ipv4.ttl - 1;
    }

    // ----- 表声明 -----
    table ipv4_routetable {
        key = { h.ipv4.dstAddr: lpm; }
        actions = {
            forward;
            drop;
        }
        default_action = drop;
    }

    table mac_rewrite {
        key = { sm.egress_spec: exact; }
        actions = {
            set_dmac;
            NoAction;
        }
    }

    // ----- apply 块 -----
    apply {
        // 1. 路由查找
        ipv4_routetable.apply();

        // 2. 如果 TTL > 0，执行后续处理
        if (h.ipv4.ttl > 0) {
            // 3. MAC 重写
            mac_rewrite.apply();

            // 4. TTL 递减
            decrement_ttl();
        }
    }
}
```

---

## 3. apply 方法详解

### 3.1 简单 apply

```c
apply {
    my_table.apply();  // 执行表查询
}
```

### 3.2 apply 结果检查

```c
apply {
    // apply() 返回一个结果对象
    // 包含 hit/miss 属性

    table_entry_lookup_result = my_table.apply();

    if (table_entry_lookup_result.hit) {
        // 表项命中
    } else {
        // 表项未命中（使用默认动作）
    }
}
```

### 3.3 条件 apply

```c
apply {
    // 仅在特定条件下查询表
    if (h.ipv4.isValid()) {
        ipv4_fib.apply();
    }

    // TCP 特定处理
    if (h.tcp.isValid() && ipv4_fib.apply().hit) {
        tcp_policies.apply();
    }
}
```

### 3.4 apply 的顺序

```c
apply {
    // 顺序执行
    // 前一个 apply 的结果可能影响后续行为

    // 例：先检查 ACL，再决定是否路由
    acl_deny.apply();  // 如果命中 deny，数据包被丢弃
    // 注意：即使 ACL 命中 deny，ipv4_fib 仍会被执行
    // 如果需要提前退出，需要使用条件 apply

    if (!acl_deny.apply().hit) {
        // 仅在 ACL 未命中 deny 时执行路由
        ipv4_fib.apply();
    }
}
```

---

## 4. 条件语句

### 4.1 if-else 语句

```c
apply {
    if (h.ethernet.isValid()) {
        // 条件为真
        if (h.ipv4.isValid()) {
            // 嵌套条件
            ipv4_forward.apply();
        } else {
            // ipv4 无效
            drop();
        }
    } else {
        // 条件为假
        drop();
    }
}
```

### 4.2 if 的返回类型

**P4 中的 `if` 语句是表达式**，可以返回值：

```c
// P4-16 语法：if-else 是表达式，有类型
bit<8> result = if (h.ipv4.ttl > 0) then h.ipv4.ttl else 0;

// 但在 apply 块中，if 语句的"值"通常被忽略
// 主要用于控制流
```

### 4.3 复杂条件

```c
apply {
    // 多条件组合
    if (h.tcp.isValid() &&
        h.tcp.flags[TCP_FLAG_ACK] == 1 &&
        h.tcp.srcPort == 80) {
        http_stats.apply();
    }

    // 范围检查
    if (h.tcp.srcPort >= 1024 && h.tcp.srcPort <= 65535) {
        // 临时端口
    }

    // 取反条件
    if (!h.tcp.isValid()) {
        // 非 TCP 流量
    }
}
```

---

## 5. Action 调用链

### 5.1 动作的直接调用

```c
apply {
    // 直接调用动作（不在表中）
    drop();
    forward(5);
    set_dscp(0x2E);
}
```

### 5.2 动作调用与表查询的区别

| 维度     | 直接调用           | 表查询 (apply)     |
| -------- | ------------------ | ------------------ |
| 决策时机 | 编译时静态         | 运行时动态         |
| 灵活性   | 硬编码             | 控制面可编程       |
| 性能     | 更高（无查找开销） | 略低（需要查表）   |
| 典型场景 | 固定处理逻辑       | 需要动态配置的处理 |

### 5.3 动作调用的限制

```c
action increment_ttl() {
    h.ipv4.ttl = h.ipv4.ttl + 1;  // OK
}

action do_two_things() {
    increment_ttl();           // OK：调用其他动作
    set_dscp(0);               // OK：调用多个动作
    ipv4_forward.apply();      // OK：在动作中调用表
    // 注意：在动作中调用表是允许的，但需谨慎使用
}
```

### 5.4 动作中的表调用

```c
action process_fragment() {
    // 动作中可以调用表
    fragment_table.apply();  // 处理分片
}

table fragment_table {
    key = { h.ipv4.identification: exact; }
    actions = { mark_fragment; }
}
```

---

## 6. Control 之间的调用

### 6.1 Control 实例化

```c
// 定义一个可重用的 Control Block
control ACL(inout headers h, inout metadata m) {
    table acl_table {
        key = {
            h.ipv4.srcAddr: ternary;
        }
        actions = { permit; deny; }
    }

    apply {
        acl_table.apply();
    }
}

// 在另一个 Control 中实例化
control MyIngress(inout headers h,
                  inout metadata m,
                  inout standard_metadata_t sm) {

    ACL();  // 实例化 ACL Control

    apply {
        // 先执行 ACL 检查
        acl.apply();  // 调用 ACL 实例

        // ACL 通过后执行路由
        if (!acl.acl_table.apply().hit ||
            acl.acl_table.apply().action == permit) {
            ipv4_forward.apply();
        }
    }
}
```

### 6.2 Control 包（Package）

```c
// PSA 中，使用 Package 连接各个 Control
package MySwitch(
    Parser(),
    Ingress(),   // Ingress Control
    Egress(),    // Egress Control
    Deparser()
);

MySwitch(
    MyParser(),
    MyIngress(),
    MyEgress(),
    MyDeparser()
) main;
```

---

## 7. Pipeline 阶段编排

### 7.1 PSA 中的 Pipeline

PSA (Portable Switch Architecture) 定义了标准的流水线：

```
                    ┌─────────────┐
                    │   Parser    │
                    └──────┬──────┘
                           │
                    ┌──────▼──────┐
                    │   Ingress  │
                    │   Control  │
                    └──────┬──────┘
                           │
              ┌────────────┼────────────┐
              │            │            │
       ┌──────▼──────┐     │     ┌──────▼──────┐
       │   Traffic   │     │     │   Traffic   │
       │   Manager   │     │     │   Manager   │
       │  (Queuing)   │     │     │  (Egress)   │
       └──────┬──────┘     │     └──────┬──────┘
              │            │            │
       ┌──────▼─────────────▼───────────▼──────┐
       │              Egress Control              │
       └──────────────────┬─────────────────────┘
                           │
                    ┌──────▼──────┐
                    │  Deparser   │
                    └─────────────┘
```

### 7.2 Ingress Control 典型结构

```c
control Ingress(inout headers h,
                inout metadata m,
                inout standard_metadata_t sm) {

    // ========== 动作 ==========
    action drop() { mark_to_drop(sm); }
    action forward(bit<9> port) { sm.egress_spec = port; }

    // ========== 表 ==========
    table mac_table {
        key = { h.ethernet.srcAddr: exact; }
        actions = { learn_mac; NoAction; }
    }

    table vlan_table {
        key = { h.vlan.vid: exact; }
        actions = { set_vlan_info; drop; }
    }

    table ipv4_route {
        key = { h.ipv4.dstAddr: lpm; }
        actions = { forward; drop; }
    }

    table acl_table {
        key = { h.ipv4.srcAddr: ternary; }
        actions = { permit; drop; }
    }

    // ========== apply ==========
    apply {
        // 1. VLAN 验证
        vlan_table.apply();

        // 2. MAC 学习
        mac_table.apply();

        // 3. ACL 检查
        acl_table.apply();

        // 4. IP 路由（ACL 允许后才执行）
        if (acl_table.apply().action != drop) {
            ipv4_route.apply();
        }
    }
}
```

### 7.3 Egress Control 典型结构

```c
control Egress(inout headers h,
               inout metadata m,
               inout standard_metadata_t sm) {

    // ========== 动作 ==========
    action add_vlan(bit<12> vid) {
        // 添加 VLAN 标签
    }

    action rewrite_mac(bit<48> smac) {
        h.ethernet.srcAddr = smac;
    }

    // ========== 表 ==========
    table egress_mac_rewrite {
        key = { sm.egress_port: exact; }
        actions = { rewrite_mac; }
    }

    table mirror_table {
        key = { h.ipv4.srcAddr: exact; }
        actions = { mirror_to_cpu; }
    }

    // ========== apply ==========
    apply {
        // 1. 出口 MAC 重写
        egress_mac_rewrite.apply();

        // 2. 镜像（如果需要）
        if (h.ipv4.isValid()) {
            mirror_table.apply();
        }

        // 3. TTL 递减检查
        if (h.ipv4.ttl == 0) {
            // TTL 到期，生成 ICMP 错误
            // 生成 ICMP 报文（通过 Clone）
        }
    }
}
```

---

## 8. PSA 中的 Metadata 流

### 8.1 standard_metadata_t

PSA 定义了 `standard_metadata_t`：

```c
struct standard_metadata_t {
    bit<9>  ingress_port;           // 入口端口
    bit<9>  egress_spec;           // 出口端口（可写）
    bit<9>  egress_port;           // 实际出口端口（只读）
    bit<32> instance;              // 包实例（用于克隆/多播）
    bit<1>  clone;                  // 是否是克隆包
    bit<1>  drop;                  // 是否被标记丢弃
    bit<16> packet_length;         // 数据包长度
    bit<8>  queue_id;              // 出口队列
    bit<8>  queue_depth;           // 队列深度
    bit<2>  padding;               //
    // ... 更多字段
}
```

### 8.2 用户自定义 Metadata

```c
struct metadata_t {
    bit<32> nexthop_id;           // 下一跳 ID
    bit<24> vni;                  // VXLAN VNI
    bit<8>  qos_color;            // QoS 颜色（绿/黄/红）
    bool    is_broadcast;         // 是否广播
    bool    allow_internet;       // 是否允许上互联网
    bit<48> timestamp_ingress;    // 入口时间戳
    bit<48> timestamp_egress;     // 出口时间戳
}
```

---

## 9. 条件与表查询的组合模式

### 9.1 优先查询小表

```c
apply {
    // 小表（精确匹配）先查
    if (exact_match_table.apply().hit) {
        // 命中，处理完成
        return;  // 提前返回（如果架构支持）
    }

    // 大表（LPM）后查
    lpm_table.apply();
}
```

### 9.2 条件分支

```c
apply {
    if (h.vlan.isValid()) {
        // VLAN 包处理
        vlan_acl.apply();
        vlan_forward.apply();
    } else if (h.mpls.isValid()) {
        // MPLS 包处理
        mpls_table.apply();
    } else {
        // 普通 IP 包处理
        ipv4_fib.apply();
        acl.apply();
    }
}
```

### 9.3 循环处理（Header Stack）

```c
apply {
    // 遍历有效的 VLAN 标签
    for (int i = 0; i < 2; i++) {
        if (h.vlans[i].isValid()) {
            vlan_processing.apply();
        }
    }
}
```

---

## 10. Control 编程的最佳实践

### 10.1 表的顺序安排

```
好的顺序：
1. 验证/过滤类表（ACL、Deny）— 尽早丢弃无效包
2. 学习类表（MAC Learning）— 尽早学习
3. 转发类表（Routing）— 核心转发决策
4. 修改类表（QoS、计数器）— 最后执行
```

### 10.2 避免冗余查表

```c
// 不好：重复查表
apply {
    acl.apply();  // 第一次查表
    if (acl.apply().hit) {  // 第二次查表！
        // ...
    }
}

// 好：保存查表结果
apply {
    auto result = acl.apply();
    if (result.hit) {
        // 使用 result
    }
}
```

### 10.3 使用 `action =` 检查动作类型

```c
apply {
    auto result = acl.apply();

    // 检查命中动作是否为特定动作
    if (result.action == permit) {
        // 允许通过
    }

    // 或使用 hit 属性
    if (result.hit) {
        // 命中表项
    } else {
        // 未命中（使用默认动作）
    }
}
```

---

## 11. 完整 Control 示例

```c
#include <core.p4>
#include <v1model.p4>

// ========== Header/Metadata 定义 ==========
// (省略，见前几章)

// ========== Ingress Control ==========
control Ingress(inout headers h,
                inout metadata m,
                inout standard_metadata_t sm) {

    // ----- 动作 -----
    action drop() {
        mark_to_drop(sm);
    }

    action forward(bit<9> port) {
        sm.egress_spec = port;
    }

    action redirect_to_cpu() {
        sm.egress_spec = CPU_PORT;
    }

    action set_next_hop(bit<32> nexthop) {
        m.nexthop_id = nexthop;
    }

    action decrement_ttl() {
        h.ipv4.ttl = h.ipv4.ttl - 1;
        h.ipv4.hdrChecksum = ipv4_checksum.update(h.ipv4);
    }

    // ----- 表 -----

    // MAC 学习表
    table smac {
        key = { h.ethernet.srcAddr: exact; }
        actions = { NoAction; }
        default_action = NoAction;
    }

    // MAC 转发表
    table dmac {
        key = { h.ethernet.dstAddr: exact; }
        actions = { forward; drop; }
        default_action = drop;
    }

    // VLAN 表
    table vlan {
        key = { h.vlan.vid: exact; }
        actions = { set_vlan_info; drop; }
    }

    // IPv4 路由表
    table ipv4_fib {
        key = { h.ipv4.dstAddr: lpm; }
        actions = {
            forward;
            set_next_hop;
            drop;
        }
        default_action = drop;
    }

    // ACL 表
    table ipv4_acl {
        key = {
            h.ipv4.srcAddr: ternary;
            h.ipv4.dstAddr: ternary;
            h.ipv4.protocol: ternary;
            h.tcp.srcPort: ternary;
            h.tcp.dstPort: ternary;
        }
        actions = { permit; drop; }
        default_action = permit;
    }

    // ----- apply 块 -----
    apply {
        // 1. VLAN 验证
        if (h.vlan.isValid()) {
            if (!vlan.apply().hit) {
                drop();
                return;
            }
        }

        // 2. MAC 学习
        smac.apply();

        // 3. ACL 检查
        if (h.ipv4.isValid()) {
            auto acl_result = ipv4_acl.apply();
            if (acl_result.action == drop) {
                drop();
                return;
            }
        }

        // 4. IP 转发
        if (h.ipv4.isValid()) {
            auto fib_result = ipv4_fib.apply();

            if (fib_result.hit) {
                // 路由命中，执行 TTL 递减
                decrement_ttl();

                // 5. MAC 转发表（使用路由提供的出口）
                dmac.apply();
            }
        } else {
            // 非 IP 包，直接按 MAC 转发
            dmac.apply();
        }
    }
}

// ========== Egress Control ==========
control Egress(inout headers h,
               inout metadata m,
               inout standard_metadata_t sm) {

    // ----- 动作 -----
    action add_vlan(bit<12> vid) {
        // VLAN 标签添加逻辑
    }

    action mirror(bit<32> session_id) {
        // 镜像逻辑
    }

    // ----- 表 -----
    table egress_vlan_rewrite {
        key = { sm.egress_port: exact; }
        actions = { add_vlan; }
    }

    // ----- apply 块 -----
    apply {
        // 出口 VLAN 重写
        if (h.vlan.isValid()) {
            egress_vlan_rewrite.apply();
        }

        // 多播镜像
        if (sm.clone == 1) {
            mirror(m.mirror_session);
        }
    }
}
```

---

## 12. 小结

本章深入介绍了 P4 Control 编程：

1. **Control 基本结构**：声明、动作、表、apply 块
2. **apply 方法**：简单 apply、条件 apply、结果检查
3. **条件语句**：if-else、多条件组合
4. **Action 调用链**：直接调用 vs 表查询、动作中调用表
5. **Control 调用**：Control 实例化、Package 连接
6. **Pipeline 编排**：PSA Ingress/Egress 流水线、Metadata 流
7. **最佳实践**：表顺序、避免冗余查表、action = 检查

下一章我们将学习 **Deparser**，了解数据包重新组装的逻辑——Header 顺序、Checksum 重新计算、以及 emit 操作。
