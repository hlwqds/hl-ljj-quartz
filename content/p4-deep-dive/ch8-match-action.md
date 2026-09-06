---
title: "P4 深度探索 (八)：Match-Action 编程——Table、Action、Key、Match Kind"
date: 2026-04-14
tags: [p4, series, match-action, table, action, key, exact, lpm, ternary, p4-16]
description: "P4 Match-Action 深度解析——Table 定义与用途、Action 函数、Key 声明、Match Kind (exact/lpm/ternary/range) 的语义与硬件实现、表的默认动作、动作参数、表条目"
---

> [!info] P4 深度探索系列 0. [[p4-deep-dive|全栈学习路径总览]]
>
> 1. [[ch1-p4-overview|第一章：P4 概述——诞生背景与协议无关包处理]]
> 2. [[ch2-p4-architecture|第二章：P4 架构模型——PSA/V1Model、Ingress/Egress]]
> 3. [[ch3-p4-vs-ebpf|第三章：P4 vs eBPF——适用场景与硬件/软件对比]]
> 4. [[ch4-p4-program|第四章：P4 程序结构——Header/Parser/Control/Table]]
> 5. [[ch5-p4-types|第五章：P4 类型系统——bit/varbit/enum/header/struct/tuple]]
> 6. [[ch6-headers|第六章：Header 与 Packet——Header 定义、Header Stack]]
> 7. [[ch7-parser|第七章：Parser 编程——状态机、Header 提取、Error 处理]]
> 8. **第八章：Match-Action 编程——Table、Action、Key、Match Kind**

---

## 1. 概述：Match-Action 是 P4 数据面的核心抽象

**Match-Action** 是 P4 数据面编程的核心范式，它将网络数据面的两个基本操作分开：

1. **Match（匹配）**：根据数据包的 header/metadata 字段，在表中查找对应的表项
2. **Action（动作）**：执行查找到的动作（修改字段、发送、丢弃、复制等）

这种分离设计带来了几个关键优势：

- **协议无关**：同一套硬件可以支持不同的协议（如 ACL、路由、防火墙）
- **控制面与数据面分离**：控制面负责填充表项，数据面负责查表执行
- **硬件友好**：Match 和 Action 在硬件中是分离的资源（TCAM/RAM vs ALU/修改逻辑）

---

## 2. Table 的基本结构

### 2.1 Table 声明

```c
table table_name {
    key = { ... };           // 匹配字段
    actions = { ... };       // 支持的动作
    default_action = ...;   // 默认动作
    size = ...;              // 表大小提示
    // ...
}
```

### 2.2 完整 Table 示例

```c
table ipv4_lpm {
    key = {
        h.ipv4.dstAddr: lpm;  // 最长前缀匹配
    }
    actions = {
        ipv4_forward;         // 转发动作
        drop;                 // 丢弃动作
        NoAction;             // 空动作
    }
    default_action = NoAction;
    size = 16384;             // 16K 表项
}
```

---

## 3. Key 与 Match Kind

### 3.1 Match Kind 声明

P4 标准库预定义了四种 match_kind：

```c
match_kind {
    exact,      // 精确匹配
    lpm,        // 最长前缀匹配 (Longest Prefix Match)
    ternary,    // 三元匹配 (掩码)
    range       // 范围匹配
}
```

### 3.2 exact：精确匹配

**语义**：Key 的整个值必须与表项完全相等。

```c
table mac_learn {
    key = {
        h.ethernet.srcAddr: exact;
    }
    actions = {
        record_mac;
        NoAction;
    }
}

// 表项示例
// dstAddr = 00:11:22:33:44:55 → record_mac
// dstAddr = 00:11:22:33:44:66 → NoAction
```

### 3.3 lpm：最长前缀匹配

**语义**：用于 IP 路由场景，找到与查找值最长前缀匹配的表项。

```c
table ipv4_fib {
    key = {
        h.ipv4.dstAddr: lpm;
    }
    actions = {
        ipv4_forward;
        drop;
    }
}

// 表项示例 (CIDR 表示)
// 10.0.0.0/8     → 转发到 port 1
// 10.0.1.0/24    → 转发到 port 2
// 10.0.1.128/25 → 转发到 port 3
// 192.168.0.0/16 → 转发到 port 4

// 查找 10.0.1.200:
// 10.0.0.0/8    匹配 8 位 ✅
// 10.0.1.0/24   匹配 24 位 ✅
// 10.0.1.128/25 匹配 25 位 ✅ ← 最长匹配
```

### 3.4 ternary：三元匹配

**语义**：Key 的每个位可以是 `0`、`1` 或 `*`（通配符，不关心）。

```c
table ddos_filter {
    key = {
        h.ipv4.srcAddr: ternary;   // 源地址掩码匹配
        h.tcp.srcPort: ternary;     // 源端口掩码匹配
    }
    actions = {
        drop;
        allow;
    }
}

// 表项示例 (使用 &&& 表示掩码)
// 0x0A000000 &&& 0xFF000000 → drop  // 10.0.0.0/8
// 0x00000000 &&& 0x00000000 → allow // 任意地址
```

**掩码语法**：

```
value &&& mask

// 10.0.0.0/24 表示为:
// value = 0x0A000000
// mask = 0xFFFFFF00
```

### 3.5 range：范围匹配

**语义**：Key 的值必须在表项指定的范围内。

```c
table acl_filter {
    key = {
        h.tcp.srcPort: range;  // 源端口范围
    }
    actions = {
        drop;
        allow;
    }
}

// 表项示例
// 0..1023    → drop     // 特权端口
// 1024..65535 → allow   // 临时端口
```

### 3.6 Match Kind 与硬件资源

| Match Kind | 硬件资源              | 典型应用               |
| ---------- | --------------------- | ---------------------- |
| exact      | Hash + CAM            | MAC 学习、ACL 精确匹配 |
| lpm        | TCAM 或 Patricia Tree | IP 路由查找            |
| ternary    | TCAM                  | ACL 规则、防火墙       |
| range      | TCAM (转换为三元)     | 端口范围、长度范围     |

---

## 4. Action 函数

### 4.1 Action 声明

```c
// 无参数的 Action
action drop() {
    mark_to_drop(standard_metadata);
}

// 有参数的 Action
action ipv4_forward(bit<48> dstMac, bit<48> srcMac, bit<9> egressPort) {
    h.ethernet.dstAddr = dstMac;
    h.ethernet.srcAddr = srcMac;
    standard_metadata.egress_spec = egressPort;
}

// 使用 metadata 的 Action
action set_egress_port(bit<9> port) {
    standard_metadata.egress_spec = port;
}
```

### 4.2 Action 体中的可用操作

```c
action modify_fields() {
    // 1. 修改 Header 字段
    h.ipv4.ttl = h.ipv4.ttl - 1;
    h.ipv4.srcAddr = 0x0A000001;

    // 2. 修改 Metadata
    meta.qos_class = 3;

    // 3. 设置出口端口
    standard_metadata.egress_spec = 5;

    // 4. 标记丢弃
    mark_to_drop(standard_metadata);

    // 5. 修改校验和
    h.ipv4.hdrChecksum = ipv4_checksum.update(h.ipv4);

    // 6. 调用其他动作
    // 注意：不能递归调用，但可以在动作中调用其他动作
}
```

### 4.3 预定义的 Common Actions

P4 提供了一些预定义的常用动作：

```c
// PSA / V1Model 预定义动作
action drop() {
    mark_to_drop(standard_metadata);
}

action NoAction() {
    // 空动作，什么都不做
}

// 常用修改动作
action add(bit<48> srcMac, bit<48> dstMac, bit<9> port) {
    // ...
}
```

### 4.4 Action 数据来源

```c
// 动作参数可以从以下来源获取值：

// 1. 表项数据（entry data）
//    由控制面通过 P4Runtime 写入表项时指定

// 2. packet header
//    直接从数据包的 header 字段读取

// 3. metadata
//    从包的 metadata 中读取（如 ingress_port）

// 4. 立即数常量
//    在 P4 程序中硬编码
```

---

## 5. Table 的完整定义

### 5.1 Table 属性

```c
table my_table {
    // ========== 必需属性 ==========
    key = {
        field1: match_kind;
        field2: match_kind;
    }
    actions = {
        action1;
        action2;
    }

    // ========== 可选属性 ==========
    default_action = action2;       // 默认动作
    size = 1024;                    // 表大小提示（编译器使用）
    supports_timeout = true;         // 支持表项超时
    idle_timeout = 300;             // 空闲超时（秒）

    // ========== 内部属性（编译器/架构使用） ==========
    // const entries = { };          // 编译时常量表项
}
```

### 5.2 const entries：编译时常量表项

```c
table ipv4_acl {
    key = {
        h.ipv4.srcAddr: ternary;
        h.ipv4.dstAddr: ternary;
        h.ipv4.protocol: ternary;
        h.tcp.srcPort: ternary;
        h.tcp.dstPort: ternary;
    }
    actions = {
        permit;
        deny;
    }
    const entries = {
        // 格式: key_value: action;
        0x0A000000 &&& 0xFF000000 &&& 0xFF &&& 0x0000 &&& 0x0000: permit;
        0x0A000000 &&& 0xFF000000 &&& 0xFF &&& 0x0000 &&& 0x0000: deny;
        _ &&& _ &&& _ &&& _ &&& _: permit;  // 默认允许
    }
}
```

### 5.3 表的默认动作

```c
table ipv4_fib {
    key = {
        h.ipv4.dstAddr: lpm;
    }
    actions = {
        ipv4_forward;
        drop;
    }
    // 如果没有匹配的表项，执行 ipv4_forward
    // 使用元组作为默认动作参数
    default_action = ipv4_forward(0, 0, 0);
}

// 默认动作也可以是 NoAction
table mac_table {
    key = {
        h.ethernet.dstAddr: exact;
    }
    actions = {
        forward;
        NoAction;  // 默认是 NoAction
    }
    default_action = NoAction;
}
```

---

## 6. Table 应用（apply）

### 6.1 基本 apply 语法

```c
control Ingress() {
    apply {
        // 简单 apply
        ipv4_lpm.apply();

        // 保存 apply 结果
        if (ipv4_lpm.apply().hit) {
            // 表项命中
        } else {
            // 表项未命中（使用默认动作）
        }
    }
}
```

### 6.2 apply 结果检查

```c
table ipv4_fib {
    key = { h.ipv4.dstAddr: lpm; }
    actions = { ipv4_forward; drop; NoAction; }
    default_action = NoAction;
}

control Ingress() {
    apply {
        // 检查表是否命中
        if (ipv4_fib.apply().hit) {
            // 表项被命中，执行对应动作
        }

        // 结合条件判断
        if (h.tcp.isValid()) {
            tcp_acl.apply();
        }
    }
}
```

### 6.3 多表顺序应用

```c
control Ingress() {
    apply {
        // 1. MAC 学习表（精确匹配，先执行）
        mac_learn.apply();

        // 2. VLAN 验证表
        vlan_check.apply();

        // 3. IPv4 路由表（LPM）
        ipv4_fib.apply();

        // 4. ACL 表（三元匹配，最后执行）
        if (h.tcp.isValid()) {
            acl_table.apply();
        }
    }
}
```

---

## 7. Table 的控制面编程

### 7.1 P4Runtime Table Entry

通过 P4Runtime，控制面可以动态添加/删除/修改表项：

```protobuf
// TableEntry 消息格式
message TableEntry {
    string table_id = 1;
    MatchKey match_key = 2;
    Action action = 3;
    int32 priority = 4;          // 优先级（用于 ternary）
    uint32 idle_timeout_ns = 5;  // 空闲超时
    bool idle_timeout_set = 6;
}
```

### 7.2 表项添加示例

```python
# Python P4Runtime 示例
from p4.v1 import p4runtime_pb2

# 创建表项
entry = p4runtime_pb2.TableEntry()
entry.table_id = "ipv4_fib"  # 表名
entry.priority = 1

# 设置匹配键 (10.0.0.0/24)
entry.match.key.extend([
    p4runtime_pb2.FieldMatch.LPM(
        field_id=1,
        value=b'\x0A\x00\x00\x00',
        prefix_len=24
    )
])

# 设置动作 (ipv4_forward)
action = entry.action.action
action.action_id = "ipv4_forward"  # 动作名
action.params.extend([
    p4runtime_pb2.Action.Param(
        param_id=1,
        value=b'\x00\x11\x22\x33\x44\x55'  # dstMac
    ),
    p4runtime_pb2.Action.Param(
        param_id=2,
        value=b'\x00\xaa\xbb\xcc\xdd\xee'  # srcMac
    ),
    p4runtime_pb2.Action.Param(
        param_id=3,
        value=b'\x00\x03'  # egress_port
    )
])

# 发送表项
request = p4runtime_pb2.WriteRequest()
request.entities.add().table_entry = entry
```

### 7.3 表项删除

```python
# 删除表项
request = p4runtime_pb2.WriteRequest()
request.updates.add().type = p4runtime_pb2.DELETE
request.entities.add().table_entry = entry
```

---

## 8. Table 设计最佳实践

### 8.1 表的顺序

| 顺序 | 表类型          | 理由                                 |
| ---- | --------------- | ------------------------------------ |
| 1    | MAC Learning    | 精确匹配，性能高，先执行可以学习 MAC |
| 2    | VLAN Validation | 验证 VLAN 合法性                     |
| 3    | LPM 路由表      | 较长匹配优先                         |
| 4    | ACL/Filter      | 三元匹配在最后，避免过早丢弃         |
| 5    | Counter/Meter   | 统计类表最后执行                     |

### 8.2 Key 字段选择

```c
// 好的 Key 设计
table ipv4_fib {
    key = {
        // 仅使用必要的字段
        h.ipv4.dstAddr: lpm;  // 路由只需要目的地址
    }
}

// 避免：Key 过长
table bad_acl {
    key = {
        // 过多字段会导致 TCAM 资源消耗过大
        h.ethernet.srcAddr: ternary;
        h.ethernet.dstAddr: ternary;
        h.ipv4.srcAddr: ternary;
        h.ipv4.dstAddr: ternary;
        h.ipv4.protocol: ternary;
        h.tcp.srcPort: ternary;
        h.tcp.dstPort: ternary;
        // ... 20+ 字段
    }
}
```

### 8.3 默认动作设计

```c
// 安全的默认动作
table ipv4_fib {
    key = { h.ipv4.dstAddr: lpm; }
    actions = { ipv4_forward; drop; }

    // 默认动作：丢弃（安全策略）
    // 防止路由表为空时所有包被意外转发
    default_action = drop;
}

// 或者默认转发到 CPU
table control_plane {
    key = { ... }
    actions = { forward_to_cpu; }
    default_action = forward_to_cpu;
}
```

---

## 9. Action 函数的高级特性

### 9.1 Action 常量参数

```c
// 使用 const 声明动作参数
action set_dscp(bit<8> dscp_value) {
    h.ipv4.diffserv = dscp_value;
}

// 在 const entries 中使用
table qos_table {
    key = { h.ipv4.dstAddr: lpm; }
    actions = { set_dscp; }
    const entries = {
        0x0A000000 &&& 0xFF000000: set_dscp(0x2E);  // EF (46)
        0xAC000000 &&& 0xFF000000: set_dscp(0x22);  // AF41 (34)
    }
}
```

### 9.2 动作链式调用

```c
// 动作可以包含对其他动作的调用
action decrement_ttl_and_forward() {
    // 先执行 TTL 递减
    h.ipv4.ttl = h.ipv4.ttl - 1;
    // 再执行转发
    ipv4_forward.apply();  // 递归 apply 是不允许的！
    // 正确做法：在一个动作中包含所有逻辑
}

// 正确的做法：把逻辑都写在一个动作中
action forward_with_ttl_check() {
    if (h.ipv4.ttl > 0) {
        h.ipv4.ttl = h.ipv4.ttl - 1;
        standard_metadata.egress_spec = 1;
    } else {
        mark_to_drop(standard_metadata);
    }
}
```

### 9.3 使用 extern 动作

```c
// Hash 动作
action compute_hash() {
    hash(
        meta.hash_value,
        HashAlgorithm.crc32,
        16w0,
        { h.ipv4.srcAddr, h.ipv4.dstAddr, h.tcp.srcPort, h.tcp.dstPort },
        16w1024
    );
}
```

---

## 10. 完整 Match-Action 示例

```c
#include <core.p4>
#include <v1model.p4>

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

header tcp_t {
    bit<16> srcPort;
    bit<16> dstPort;
    bit<32> seqNo;
    bit<32> ackNo;
    bit<4>  dataOffset;
    bit<4>  reserved;
    bit<8>  flags;
    bit<16> window;
    bit<16> checksum;
    bit<16> urgentPtr;
}

// ========== Metadata ==========
struct metadata_t {
    bit<32> nexthop_id;
    bit<8>  dscp;
    bool    is_multicast;
}

// ========== Headers ==========
struct headers_t {
    ethernet_t ethernet;
    ipv4_t     ipv4;
    tcp_t      tcp;
}

// ========== Parser ==========
parser MyParser(...) { /* 如前章定义 */ }

// ========== Actions ==========

// IPv4 转发
action ipv4_forward(bit<48> dstMac, bit<48> srcMac, bit<9> port) {
    h.ethernet.dstAddr = dstMac;
    h.ethernet.srcAddr = srcMac;
    h.ipv4.ttl = h.ipv4.ttl - 1;
    standard_metadata.egress_spec = port;
}

// 丢弃
action drop() {
    mark_to_drop(standard_metadata);
}

// 设置 DSCP
action set_dscp(bit<8> dscp) {
    h.ipv4.diffserv = dscp[7:2];  // 取高 6 位
}

// ========== Tables ==========

// LPM 路由表
table ipv4_lpm {
    key = {
        h.ipv4.dstAddr: lpm;  // 最长前缀匹配
    }
    actions = {
        ipv4_forward;
        drop;
        NoAction;
    }
    default_action = NoAction;
    size = 16384;
}

// ACL 表
table ipv4_acl {
    key = {
        h.ipv4.srcAddr: ternary;   // 源地址掩码
        h.ipv4.dstAddr: ternary;   // 目的地址掩码
        h.ipv4.protocol: exact;    // 协议
        h.tcp.srcPort: range;      // 源端口范围
    }
    actions = {
        permit;
        drop;
    }
    default_action = drop;
    size = 8192;
}

// QoS 表
table qos_table {
    key = {
        h.ipv4.dstAddr: lpm;
    }
    actions = {
        set_dscp;
        NoAction;
    }
    default_action = NoAction;
    size = 4096;
}

// ========== Control ==========
control MyIngress(inout headers h,
                  inout metadata m,
                  inout standard_metadata_t sm) {
    apply {
        // 1. QoS 标记
        qos_table.apply();

        // 2. LPM 路由查找
        if (ipv4_lpm.apply().hit) {
            // 路由命中，执行转发
            // ipv4_forward 已在动作中处理 TTL 和出口
        }

        // 3. ACL 检查
        if (h.tcp.isValid()) {
            ipv4_acl.apply();
        }
    }
}

// ========== Deparser ==========
control MyDeparser(...) { /* 如前章定义 */ }

// ========== Pipeline ==========
V1Switch(
    MyParser(),
    MyIngress(),
    MyEgress(),
    MyDeparser(),
    my_lookup()
) main;
```

---

## 11. 小结

本章深入介绍了 P4 的 Match-Action 编程模型：

1. **Match-Action 范式**：将匹配与动作分离，硬件友好
2. **Table 结构**：key、actions、default_action、size 等属性
3. **Match Kind**：
   - exact：精确匹配（Hash + CAM）
   - lpm：最长前缀匹配（TCAM 或 Patricia Tree）
   - ternary：三元匹配（TCAM）
   - range：范围匹配（TCAM）
4. **Action 函数**：无参数/有参数动作、动作体中的可用操作
5. **Table apply**：条件 apply、多表顺序、hit/miss 检查
6. **控制面编程**：P4Runtime 动态表项管理
7. **设计最佳实践**：表顺序、Key 设计、默认动作

下一章我们将学习 **Control 编程**，了解 Control Block 的结构、条件判断、以及动作调用链。
