---
title: "P4 深度探索 (十)：Deparser——包重组、Header 顺序、Checksum 重新计算"
date: 2026-04-14
tags: [p4, series, deparser, packet-emit, checksum, hdrChecksum, ipv4, p4-16]
description: "P4 Deparser 深度解析——包重组原理、emit 操作、Header 发射顺序、Checksum 验证与重新计算 (IPv4/TCP/UDP)、packet_out、Deparser 与 Parser 的对称性"
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
> 8. [[ch8-match-action|第八章：Match-Action 编程——Table、Action、Key]]
> 9. [[ch9-control|第九章：Control 编程——Control Block、条件判断、Action 调用链]]
> 10. **第十章：Deparser——包重组、Header 顺序、Checksum 重新计算**

---

## 1. 概述：Deparser 是数据包的重新组装

**Deparser** 是 P4 流水线中最后一个阶段，负责将处理后的 Header 重新**组装**成完整的数据包并输出到线缆。它的功能与 Parser 相反：

| 阶段     | 功能                | 数据方向    |
| -------- | ------------------- | ----------- |
| Parser   | 从数据包提取 Header | 线缆 → 程序 |
| Deparser | 将 Header 重新组装  | 程序 → 线缆 |

Deparser 的核心操作是 `packet.emit()`——将 Header 的值写回到数据包的输出缓冲区。

---

## 2. packet_out 与 emit

### 2.1 packet_out 类型

在 PSA/V1Model 中，Deparser 接收一个 `packet_out` 类型的对象：

```c
control DeparserImpl(packet_out packet, in headers_t h) {
    apply {
        // 使用 packet.emit() 发射 Header
    }
}
```

### 2.2 emit() 基本用法

```c
control DeparserImpl(packet_out packet, in headers_t h) {
    apply {
        // 按顺序发射各个 Header
        packet.emit(h.ethernet);   // Ethernet Header (14 bytes)
        packet.emit(h.ipv4);        // IPv4 Header (20+ bytes)
        packet.emit(h.tcp);        // TCP Header (20+ bytes)
        packet.emit(h.payload);    // 负载
    }
}
```

### 2.3 emit() 的语义

1. **仅发射 Valid Header**：Invalid Header 会被**跳过**，不会写入数据包
2. **按声明顺序发射**：Header 按照 `packet.emit()` 调用的顺序依次写入
3. **自动更新数据包长度**：packet_out 的内部指针随 emit 移动

```c
apply {
    // 如果 h.vlan 是 Invalid，VLAN Header 会被跳过
    packet.emit(h.ethernet);  // 即使 h.vlan 在 h.ethernet 之前，
                               // 也不会发射（因为 Invalid）
    packet.emit(h.vlan);      // 如果 Invalid，跳过
    packet.emit(h.ipv4);     // 发射 IPv4
}
```

---

## 3. Header 发射顺序

### 3.1 典型协议头顺序

网络协议要求 Header 按照特定顺序排列：

```
Ethernet → VLAN(s) → IPv4 → TCP → Payload
         → IPv6 → Extension Headers → UDP → Payload
```

### 3.2 简单情况

```c
control DeparserImpl(packet_out packet, in headers_t h) {
    apply {
        packet.emit(h.ethernet);
        packet.emit(h.ipv4);
        packet.emit(h.tcp);
    }
}
```

### 3.3 带 VLAN 的情况

```c
control DeparserImpl(packet_out packet, in headers_t h) {
    apply {
        // Ethernet 最先发射（除非有 PPPoE 等封装）
        packet.emit(h.ethernet);

        // VLAN Header（如果存在）
        if (h.vlan.isValid()) {
            packet.emit(h.vlan);
        }

        // IP Header
        if (h.ipv4.isValid()) {
            packet.emit(h.ipv4);
        } else if (h.ipv6.isValid()) {
            packet.emit(h.ipv6);
        }

        // 传输层 Header
        if (h.tcp.isValid()) {
            packet.emit(h.tcp);
        } else if (h.udp.isValid()) {
            packet.emit(h.udp);
        }
    }
}
```

### 3.4 Header Stack 的发射

```c
// Header Stack 自动发射所有 Valid 元素
apply {
    packet.emit(h.ethernet);
    packet.emit(h.vlans);  // 发射所有有效的 VLAN 标签
    packet.emit(h.ipv4);
}
```

---

## 4. Checksum 重新计算

### 4.1 为什么需要重新计算 Checksum

当数据包在流水线中被修改时（如 TTL 递减、IP 地址转换），Checksum 会变得无效，需要**重新计算**：

```
场景 1: IPv4 TTL 递减
原始: TTL=64, Checksum=0x1234 (包含TTL)
修改: TTL=63
结果: Checksum=0x1234 (不正确) → 需要重新计算

场景 2: IP 地址转换 (NAT)
原始: SrcIP=10.0.0.1, Checksum=0x5678 (包含SrcIP)
修改: SrcIP=192.168.1.1
结果: Checksum=0x5678 (不正确) → 需要重新计算
```

### 4.2 P4 的 Checksum 操作

P4 提供两种 Checksum 操作：

| 操作                | 用途                               |
| ------------------- | ---------------------------------- |
| `verify_checksum()` | 在 Parser 中验证 Checksum 是否正确 |
| `update_checksum()` | 在 Control 中重新计算 Checksum     |

### 4.3 update_checksum() 语法

```c
update_checksum(
    condition,        // 条件：仅当条件为 true 时执行
    data_to_checksum, // 要计算校验和的数据 (tuple)
    checksum_field,   // 存储结果的字段 (inout)
    algorithm         // 校验和算法
)
```

### 4.4 IPv4 Checksum 重新计算

```c
control Ingress(inout headers h, inout metadata m) {

    action decrement_ttl() {
        h.ipv4.ttl = h.ipv4.ttl - 1;

        // 重新计算 IPv4 Header Checksum
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
                h.ipv4.ttl,         // 变化点
                h.ipv4.protocol,
                h.ipv4.srcAddr,
                h.ipv4.dstAddr
            },
            h.ipv4.hdrChecksum,
            HashAlgorithm.csum16
        );
    }

    apply {
        if (h.ipv4.isValid()) {
            decrement_ttl();
        }
    }
}
```

### 4.5 TCP/UDP Checksum 重新计算

TCP/UDP Checksum 涉及**伪头部**（Pseudo Header），包含源/目的 IP 地址：

```c
// TCP Checksum 需要伪头部
update_checksum(
    h.tcp.isValid(),
    {
        h.ipv4.srcAddr,       // 伪头部
        h.ipv4.dstAddr,       // 伪头部
        8w0,                   // 伪头部：协议 (8位0)
        h.ipv4.protocol,       // 伪头部：协议
        h.tcp.srcPort,        // TCP 头部
        h.tcp.dstPort,
        h.tcp.seqNo,
        h.tcp.ackNo,
        h.tcp.dataOffset,
        h.tcp.flags,
        h.tcp.window,
        16w0,                  // checksum 字段置零
        h.tcp.urgentPtr,
        h.tcp.payload         // 负载（如果有）
    },
    h.tcp.checksum,
    HashAlgorithm.csum16
);
```

### 4.6 简化：仅在需要时计算

```c
// 如果 TTL 只在 > 1 时递减
action decrement_ttl() {
    h.ipv4.ttl = h.ipv4.ttl - 1;

    // 仅当 TTL 变化时才重新计算 Checksum
    if (h.ipv4.ttl > 0) {
        update_checksum(true,
            { h.ipv4.version, h.ipv4.ihl, /* ... */ },
            h.ipv4.hdrChecksum,
            HashAlgorithm.csum16);
    }
}
```

---

## 5. verify_checksum：Checksum 验证

### 5.1 verify_checksum 语法

```c
verify_checksum(
    condition,          // 条件：仅当条件为 true 时验证
    data_to_checksum,    // 要验证的数据 (tuple)
    checksum_field,     // Checksum 字段
    algorithm,          // 校验和算法
    error_tag           // 错误标签：如果验证失败
)
```

### 5.2 Parser 中的 Checksum 验证

```c
state parse_ipv4 {
    packet.extract(h.ipv4);

    // 验证 IPv4 Header Checksum
    verify_checksum(
        true,  // 始终验证
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
        HashAlgorithm.csum16,
        error.IPv4ChecksumError
    );

    transition select(h.ipv4.protocol) {
        6: parse_tcp;
        17: parse_udp;
        default: accept;
    }
}
```

### 5.3 可选验证

```c
// 仅当存在负载时验证 TCP Checksum
verify_checksum(
    h.tcp.isValid(),
    { /* pseudo header + tcp header */ },
    h.tcp.checksum,
    HashAlgorithm.csum16,
    error.TCPChecksumError
);
```

---

## 6. Deparser 的完整示例

### 6.1 基本 Deparser

```c
control DeparserImpl(packet_out packet, in headers_t h) {
    apply {
        // 发射 Ethernet
        packet.emit(h.ethernet);

        // 发射 VLAN（如果存在）
        if (h.vlan.isValid()) {
            packet.emit(h.vlan);
        }

        // 发射 IPv4
        if (h.ipv4.isValid()) {
            packet.emit(h.ipv4);
        }

        // 发射传输层
        if (h.tcp.isValid()) {
            packet.emit(h.tcp);
        } else if (h.udp.isValid()) {
            packet.emit(h.udp);
        }
    }
}
```

### 6.2 带 Checksum 重新计算的 Deparser

```c
control DeparserImpl(packet_out packet, in headers_t h) {

    // Checksum 重新计算在 Ingress/Egress 中完成
    // Deparser 只需要按顺序发射

    apply {
        packet.emit(h.ethernet);

        if (h.vlan.isValid()) {
            packet.emit(h.vlan);
        }

        if (h.ipv4.isValid()) {
            packet.emit(h.ipv4);

            // 注意：IPv4 Checksum 的重新计算应该在 Ingress 中完成
            // Deparser 发射时，h.ipv4.hdrChecksum 已经是更新后的值
        }

        if (h.tcp.isValid()) {
            packet.emit(h.tcp);
        } else if (h.udp.isValid()) {
            packet.emit(h.udp);
        }
    }
}
```

### 6.3 复杂协议栈的 Deparser

```c
control DeparserImpl(packet_out packet, in headers_t h) {
    apply {
        // 最外层：Ethernet
        packet.emit(h.outer_ethernet);

        // VLAN 标签（可能多个）
        if (h.vlans[0].isValid()) {
            packet.emit(h.vlans[0]);
        }
        if (h.vlans[1].isValid()) {
            packet.emit(h.vlans[1]);
        }

        // MPLS 标签栈
        if (h.mpls[0].isValid()) {
            packet.emit(h.mpls[0]);
        }
        if (h.mpls[1].isValid()) {
            packet.emit(h.mpls[1]);
        }

        // IPv4 或 IPv6
        if (h.ipv4.isValid()) {
            packet.emit(h.ipv4);
        } else if (h.ipv6.isValid()) {
            packet.emit(h.ipv6);

            // IPv6 Extension Headers
            if (h.ipv6_hop_by_hop.isValid()) {
                packet.emit(h.ipv6_hop_by_hop);
            }
            if (h.ipv6_routing.isValid()) {
                packet.emit(h.ipv6_routing);
            }
            if (h.ipv6_fragment.isValid()) {
                packet.emit(h.ipv6_fragment);
            }
            if (h.ipv6_dest_options.isValid()) {
                packet.emit(h.ipv6_dest_options);
            }
        }

        // 传输层
        if (h.tcp.isValid()) {
            packet.emit(h.tcp);
        } else if (h.udp.isValid()) {
            packet.emit(h.udp);
        }

        // 应用层（如 VXLAN）
        if (h.vxlan.isValid()) {
            packet.emit(h.vxlan);
            packet.emit(h.inner_ethernet);
            packet.emit(h.inner_ipv4);
        }
    }
}
```

---

## 7. Deparser 与 Parser 的对称性

### 7.1 Parser → Deparser 对称

```
Parser:                          Deparser:
extract() 消耗数据包字节         emit()  添加数据包字节

  packet_in                        packet_out
      │                               ▲
      ▼                               │
  ┌────────┐                     ┌────────┐
  │ parse_ │                     │deparse │
  │ethernet│                     │ethernet│
  └────┬───┘                     └───┬────┘
       │ extract(h.ethernet)          │ emit(h.ethernet)
       ▼                              │
  ┌────────┐                     ┌────────┐
  │ parse_ │                     │deparse │
  │ ipv4   │                     │ ipv4   │
  └────┬───┘                     └───┬────┘
       │ extract(h.ipv4)             │ emit(h.ipv4)
```

### 7.2 Invalid Header 的处理

```c
// Parser: Invalid Header 表示提取失败或不存在
state parse_ethernet {
    packet.extract(h.ethernet);
    // 如果数据包太短，h.ethernet 变为 Invalid
    transition select(h.ethernet.isValid()) {
        true: parse_ipv4;
        false: accept;  // 数据包太短
    }
}

// Deparser: Invalid Header 被跳过
apply {
    packet.emit(h.ethernet);  // 如果 h.ethernet 是 Invalid，
                              // 这行代码不会发射任何字节
    packet.emit(h.ipv4);      // 继续发射 IPv4
}
```

---

## 8. Deparser 的硬件考虑

### 8.1 序列化顺序

硬件 Deparser 必须按照**严格的顺序**将 Header 写入输出：

```
1. Parser 决定了解析顺序
2. Control 决定如何修改 Header
3. Deparser 必须按照协议规定的顺序序列化

错误顺序 → 线缆上出现畸形数据包 → 接收方无法解析
```

### 8.2 Checksum 计算位置

| Checksum 类型  | 计算位置          | 理由                       |
| -------------- | ----------------- | -------------------------- |
| IPv4 Header    | Ingress           | TTL 修改在 Ingress 完成    |
| TCP Checksum   | Ingress 或 Egress | 取决于封装变化             |
| UDP Checksum   | 同上              | 同上                       |
| VXLAN Checksum | Egress            | 内部 Header 在 Egress 添加 |

### 8.3 IPv6 的 Checksum

IPv6 **没有 Header Checksum**（设计决策，假设下层链路已校验）：

```
IPv4: 有 Header Checksum（校验传输正确性）
IPv6: 无 Header Checksum（依赖链路层校验）
```

因此 IPv6 Deparser 不需要重新计算 Header Checksum。

---

## 9. Deparser 高级技巧

### 9.1 条件发射

```c
apply {
    packet.emit(h.outer_ethernet);

    // 根据配置决定是否添加 VLAN
    if (m.add_vlan_tag) {
        h.vlan.setValid();
        h.vlan.vid = m.vlan_id;
        packet.emit(h.vlan);
    }

    packet.emit(h.inner_ethernet);
    packet.emit(h.ipv4);
}
```

### 9.2 动态添加 Header

```c
// 在 Deparser 中动态添加 MPLS 标签
control DeparserImpl(packet_out packet, in headers_t h) {
    apply {
        packet.emit(h.ethernet);

        // 在 IPv4 之前添加 MPLS（推送）
        if (m.add_mpls_label) {
            // 使用 push_front 在数据包前面添加空间
            packet.push_front(4);  // 添加 4 字节（MPLS 标签）

            // 手动写入 MPLS 标签值
            // 注意：P4 不直接支持此操作，需在 Ingress/Egress 准备
        }

        packet.emit(h.ipv4);
    }
}
```

### 9.3 负载发射

```c
// Deparser 无法直接"发射剩余负载"
// 负载是 Parser 未解析的剩余字节，自动包含在输出中

// 只需要发射已解析的 Header
apply {
    packet.emit(h.ethernet);
    packet.emit(h.ipv4);
    packet.emit(h.tcp);
    // 剩余的 payload 自动包含在输出数据包中
}
```

---

## 10. 完整流水线示例

### 10.1 完整 P4 程序结构

```c
#include <core.p4>
#include <v1model.p4>

// ========== Header 定义 ==========
header ethernet_t { bit<48> dst; bit<48> src; bit<16> type; }
header ipv4_t { /* ... */ }
header tcp_t { /* ... */ }

// ========== Metadata ==========
struct metadata_t { /* ... */ }
struct headers_t {
    ethernet_t ethernet;
    ipv4_t ipv4;
    tcp_t tcp;
}

// ========== Parser ==========
parser MyParser(packet_in pkt, out headers_t h, inout metadata_t m) {
    state start { transition parse_ethernet; }
    state parse_ethernet { /* ... */ }
    state parse_ipv4 { /* ... */ }
    state parse_tcp { /* ... */ }
}

// ========== Ingress Control ==========
control MyIngress(inout headers h, inout metadata_t m,
                  inout standard_metadata_t sm) {
    action drop() { mark_to_drop(sm); }
    action ipv4_forward(bit<48> dmac, bit<9> port) {
        h.ethernet.dstAddr = dmac;
        sm.egress_spec = port;
        h.ipv4.ttl = h.ipv4.ttl - 1;
        // 重新计算 Checksum
        update_checksum(/* ... */);
    }
    table ipv4_lpm { /* ... */ }
    apply { ipv4_lpm.apply(); }
}

// ========== Egress Control ==========
control MyEgress(inout headers h, inout metadata_t m,
                 inout standard_metadata_t sm) {
    apply { /* 可能添加 VLAN、Mirror 等 */ }
}

// ========== Deparser ==========
control MyDeparser(packet_out packet, in headers_t h) {
    apply {
        packet.emit(h.ethernet);
        packet.emit(h.ipv4);
        packet.emit(h.tcp);
    }
}

// ========== Pipeline ==========
V1Switch(
    MyParser(),
    MyIngress(),
    MyEgress(),
    MyDeparser()
) main;
```

---

## 11. 小结

本章深入介绍了 P4 Deparser 编程：

1. **Deparser 功能**：与 Parser 对称，将 Header 重新组装成数据包
2. **packet_out 与 emit**：发射 Valid Header，跳过 Invalid Header
3. **Header 发射顺序**：严格按照协议规定的顺序
4. **Checksum 重新计算**：使用 `update_checksum()` 重新计算被修改字段的校验和
5. **Checksum 验证**：使用 `verify_checksum()` 在 Parser 中验证
6. **Hardware 考虑**：序列化顺序、Checksum 计算位置
7. **Invalid Header 处理**：Parser 设置 Invalid，Deparser 跳过

至此，**Part II: P4 语言详解**（第 6-10 章）全部完成。我们涵盖了：

- Ch6: Header 与 Packet — Header 类型、Valid/Invalid、Header Stack
- Ch7: Parser — 状态机、transition、Error 处理、分片解析
- Ch8: Match-Action — Table、Action、Key、Match Kind
- Ch9: Control — apply、条件、动作调用链、Pipeline 编排
- Ch10: Deparser — 包重组、emit、Checksum 重新计算

下一部分 **Part III: 数据平面架构** 将介绍 PSA/TNA 架构、Pipeline 设计、Register 与状态等主题。
