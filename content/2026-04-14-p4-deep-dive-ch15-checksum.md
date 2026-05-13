---
title: "P4 深度探索 (十五)：Checksum——Checksum 验证与重新计算、IPv4/TCP/UDP"
date: 2026-04-14
tags: [p4, series, checksum, ipv4, tcp, udp, verification, p4-16, psa, hdrChecksum]
description: "P4 Checksum 深度解析——Checksum 验证与重新计算原理、IPv4/TCP/UDP/ICMP Checksum 算法、Header 验证、packet_in/out、Deparser 中的 Checksum 重新计算"
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
> 13. [[2026-04-14-p4-deep-dive-ch13-pipeline|第十三章：Pipeline 设计——Match-Action 流水线、逻辑阶段与物理阶段]]
> 14. [[2026-04-14-p4-deep-dive-ch14-registers|第十四章：Register 与状态——Register、Counter、Gauge、Direct/Indirect 资源]]
> 15. **第十五章：Checksum——Checksum 验证与重新计算、IPv4/TCP/UDP**

---

## 1. 概述：Checksum 是数据完整性的基础

**Checksum (校验和)** 是网络协议中用于检测数据传输错误的机制。在数据包穿越网络设备时，IP 地址、TTL 等字段可能发生变化，必须**重新计算 Checksum** 以保持协议栈的正确性。

P4 提供了专门的 **Checksum Unit** 在硬件中执行这些计算。

### 1.1 常见协议的 Checksum

| 协议  | Checksum 位置        | 覆盖范围                          |
| ----- | -------------------- | --------------------------------- |
| IPv4  | Header `hdrChecksum` | 仅 IPv4 Header                    |
| TCP   | Header `checksum`    | Pseudo-header + TCP Header + Data |
| UDP   | Header `checksum`    | Pseudo-header + UDP Header + Data |
| ICMP  | Header `checksum`    | ICMP Header + Data                |
| VXLAN | Header `flags`       | VXLAN Header + RTRs               |

---

## 2. Checksum 算法

### 2.1 Internet Checksum 算法

Internet Checksum 是 IPv4/TCP/UDP 使用的标准算法：

```
Internet Checksum 算法:
========================

1. 将数据划分为 16-bit words
2. 将所有 16-bit words 相加 (使用 one's complement arithmetic)
3. 将最终结果的 bitwise NOT 作为 Checksum

Example:
--------

数据: 0x1234, 0x5678, 0x9ABC

Step 1: 相加
  0x1234 + 0x5678 = 0x68AC
  0x68AC + 0x9ABC = 0x010268  (溢出回绕)

Step 2: 处理溢出
  0x010268 的高 16 位是 0x0001，添加到低 16 位
  0x0002 + 0x68AC = 0x68AE

Step 3: 取反
  checksum = ~0x68AE = 0x9751
```

### 2.2 One's Complement 加法

Internet Checksum 使用 **One's Complement 算术**：

```
One's Complement 加法规则:
==========================

1. 正常二进制加法
2. 如果结果产生溢出，将溢出位加回到结果的低位

Example:
  0xFFFE + 0x0002 = 0x10000
              溢出! = 0x0001
  结果: 0x0000 + 0x0001 = 0x0001
```

---

## 3. P4 Checksum 支持

### 3.1 Checksum Unit

P4 架构定义了 **Checksum Unit** 作为 Extern：

```c
extern Checksum<W> {
    // 构造函数
    Checksum();

    // 添加数据到 Checksum 计算
    void clear();           // 清零
    void add<T>(in T data); // 添加数据 (可以是任何类型)

    // 获取结果
    W get();                // 返回当前 Checksum 值
}
```

### 3.2 Checksum 验证

Parser 中可以验证 Checksum：

```c
// Checksum 验证
parser ParserImpl(...) {

    state parse_ipv4 {
        // 提取 IPv4 Header
        extract(h.ipv4);

        // 验证 Checksum
        verify_checksum(
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

        transition select(h.ipv4.protocol) {
            6: parse_tcp;
            17: parse_udp;
            1: parse_icmp;
            default: accept;
        }
    }
}
```

### 3.3 Checksum 重新计算

Deparser 中重新计算 Checksum：

```c
// Deparser 中的 Checksum 重新计算
control DeparserImpl(packet_out packet, in headers_t h) {

    apply {
        // 重新计算 IPv4 Checksum
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

        // 发射 Headers
        packet.emit(h.ethernet);
        packet.emit(h.ipv4);
        packet.emit(h.tcp);
        packet.emit(h.payload);
    }
}
```

---

## 4. IPv4 Checksum 详解

### 4.1 IPv4 Header 结构

```
IPv4 Header:
===========

 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|Version|  IHL  |   DSCP    |ECN|         Total Length          |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|        Identification         |Flags|     Fragment Offset     |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|  Time-to-Live |    Protocol   |        Header Checksum       |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                       Source Address                          |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                    Destination Address                         |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                    Options (if IHL > 5)                        |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

Checksum 覆盖: 从 Version 到 Destination Address (20 bytes)
```

### 4.2 IPv4 Checksum 计算示例

```c
// IPv4 Checksum 重新计算
control Ingress(...) {

    action decrement_ttl() {
        h.ipv4.ttl = h.ipv4.ttl - 1;

        // 重新计算 Checksum
        // TTL 变化会影响 Checksum
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
                h.ipv4.ttl,        // TTL 变了
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

---

## 5. TCP/UDP Checksum 详解

### 5.1 Pseudo Header

TCP/UDP Checksum 覆盖 **Pseudo Header + 实际数据**：

```
TCP/UDP Pseudo Header:
======================

TCP/UDP Checksum 计算需要 Pseudo Header:

+--------+--------+--------+--------+
|     Source IP Address          |  (4 bytes)
+--------+--------+--------+--------+
|     Destination IP Address     |  (4 bytes)
+--------+--------+--------+--------+
|  Zero  | Proto |   TCP/UDP Len  |  (2 + 1 + 2 = 4 bytes, 但只占 12 bytes 的位置)
+--------+--------+--------+--------+

实际 Checksum 范围:
[Pseudo Header (12 bytes)] + [TCP/UDP Header] + [Data]
```

### 5.2 TCP Checksum 计算

```c
// TCP Checksum 计算
control Ingress(...) {

    action recalc_tcp_checksum() {
        // TCP Checksum 需要覆盖:
        // 1. Pseudo Header (srcIP, dstIP, zero, protocol, TCP len)
        // 2. TCP Header (不含 checksum 字段)
        // 3. TCP Data

        update_checksum_with_payload(
            h.tcp.isValid(),
            {
                // Pseudo Header
                h.ipv4.srcAddr,
                h.ipv4.dstAddr,
                8w0,
                h.ipv4.protocol,
                (bit<16>)h.tcp.len      // TCP 长度
            },
            h.tcp.checksum,
            HashAlgorithm.csum16
        );
    }

    apply {
        if (h.tcp.isValid()) {
            recalc_tcp_checksum();
        }
    }
}
```

### 5.3 UDP Checksum

UDP Checksum 是**可选的** (checksum 为 0 表示未使用)：

```c
// UDP Checksum 重新计算 (可选)
control Ingress(...) {

    action recalc_udp_checksum() {
        // UDP 长度
        bit<16> udp_len = h.udp.length;

        // 如果 UDP Checksum 为 0，保持为 0 (允许校验和为 0 表示未用)
        if (h.udp.checksum != 0) {
            update_checksum_with_payload(
                h.udp.isValid(),
                {
                    h.ipv4.srcAddr,
                    h.ipv4.dstAddr,
                    8w0,
                    h.ipv4.protocol,
                    h.udp.length          // UDP 长度
                },
                h.udp.checksum,
                HashAlgorithm.csum16
            );
        }
    }

    apply {
        if (h.udp.isValid()) {
            recalc_udp_checksum();
        }
    }
}
```

---

## 6. Checksum 与 Deparser 集成

### 6.1 Deparser 中 Checksum 重新计算顺序

Deparser 中必须按照**反向依赖**顺序重新计算 Checksum：

```c
control DeparserImpl(packet_out packet, in headers_t h) {

    apply {
        // 1. 首先处理内层 Checksum (先计算的依赖后计算)
        if (h.tcp.isValid()) {
            // TCP Checksum 依赖 IPv4 地址
            update_checksum_with_payload(
                h.tcp.isValid(),
                { h.ipv4.srcAddr, h.ipv4.dstAddr, 8w0, h.ipv4.protocol, h.tcp.len },
                h.tcp.checksum,
                HashAlgorithm.csum16
            );
        }

        if (h.udp.isValid()) {
            // UDP Checksum 依赖 IPv4 地址
            update_checksum_with_payload(
                h.udp.isValid(),
                { h.ipv4.srcAddr, h.ipv4.dstAddr, 8w0, h.ipv4.protocol, h.udp.length },
                h.udp.checksum,
                HashAlgorithm.csum16
            );
        }

        // 2. 最后处理 IPv4 Header Checksum
        // (因为 TTL 等字段可能已修改)
        if (h.ipv4.isValid()) {
            update_checksum(
                h.ipv4.isValid(),
                {
                    h.ipv4.version, h.ipv4.ihl, h.ipv4.diffserv,
                    h.ipv4.totalLen, h.ipv4.identification,
                    h.ipv4.flags, h.ipv4.fragOffset,
                    h.ipv4.ttl, h.ipv4.protocol,
                    h.ipv4.srcAddr, h.ipv4.dstAddr
                },
                h.ipv4.hdrChecksum,
                HashAlgorithm.csum16
            );
        }

        // 3. 最后发射数据包
        packet.emit(h.ethernet);
        packet.emit(h.ipv4);
        packet.emit(h.tcp);
        packet.emit(h.udp);
        packet.emit(h.payload);
    }
}
```

### 6.2 update_checksum vs update_checksum_with_payload

| 方法                           | 适用场景                                             |
| ------------------------------ | ---------------------------------------------------- |
| `update_checksum`              | Checksum 完全覆盖 Header，Header 在 packet_in 中     |
| `update_checksum_with_payload` | Checksum 覆盖 Header + Payload，Payload 需要额外引用 |

```c
// update_checksum_with_payload 示例
// 用于 TCP/UDP Checksum，它们覆盖 Pseudo Header + Header + Data

update_checksum_with_payload(
    h.tcp.isValid(),
    pseudo_header,          // Pseudo Header 元组
    h.tcp.checksum,          // 目标字段
    HashAlgorithm.csum16    // 算法
);
```

---

## 7. Checksum 优化

### 7.1 只在需要时计算

避免不必要的 Checksum 计算：

```c
// 优化: 只在字段实际改变时重新计算
action modify_src_ip(bit<32> new_src) {
    if (h.ipv4.srcAddr != new_src) {
        h.ipv4.srcAddr = new_src;

        // 只在源地址改变时重新计算 Checksum
        update_ipv4_checksum();
        update_tcp_checksum();  // TCP 也依赖源地址
    }
}
```

### 7.2 利用增量更新

对于 TTL 等单字段变化，可以手工优化 Checksum：

```
增量 Checksum 更新 (RFC 1624):
==============================

当只修改一个 16-bit 字时:

NewChecksum = OldChecksum + ~OldField + NewField

Example:
  Old TTL = 64, New TTL = 63
  Old Checksum = 0x1234

  NewChecksum = 0x1234 + ~64 + 63
              = 0x1234 + 0xFFBF + 0x003F
              = 0x1234 + 0xFFFE
              = 0x1232 (溢出回绕)
```

---

## 8. 常见 Checksum 错误

### 8.1 错误 1: 遗漏 Pseudo Header

```c
// 错误: 遗漏 Pseudo Header
update_checksum_with_payload(
    h.tcp.isValid(),
    { /* 错误: 只有 TCP Header，没有 Pseudo Header */ },
    h.tcp.checksum,
    HashAlgorithm.csum16
);

// 正确: 包含 Pseudo Header
update_checksum_with_payload(
    h.tcp.isValid(),
    {
        h.ipv4.srcAddr,     // Pseudo Header
        h.ipv4.dstAddr,     // Pseudo Header
        8w0,                // Zero
        h.ipv4.protocol,    // Protocol
        h.tcp.len           // TCP 长度
    },
    h.tcp.checksum,
    HashAlgorithm.csum16
);
```

### 8.2 错误 2: Checksum 字段参与自身计算

```c
// 错误: Checksum 字段参与计算
update_checksum(
    h.ipv4.isValid(),
    {
        h.ipv4.version, h.ipv4.ihl, h.ipv4.diffserv,
        h.ipv4.totalLen, h.ipv4.identification,
        h.ipv4.flags, h.ipv4.fragOffset,
        h.ipv4.ttl, h.ipv4.protocol,
        h.ipv4.srcAddr, h.ipv4.dstAddr,
        h.ipv4.hdrChecksum  // 错误: 不应该包含!
    },
    h.ipv4.hdrChecksum,
    HashAlgorithm.csum16
);
```

### 8.3 错误 3: 字节序问题

```c
// 注意: Internet Checksum 使用网络字节序 (Big Endian)
// 确保字段顺序正确

// 正确: 按网络字节序排列
{ h.ipv4.srcAddr[31:16], h.ipv4.srcAddr[15:0], ... }

// 如果本地字节序不同，可能需要转换
```

---

## 9. VXLAN/GRE 等隧道协议 Checksum

### 9.1 VXLAN Checksum 处理

```c
header vxlan_t {
    bit<8>  flags;
    bit<24> reserved;
    bit<8>  flags2;
    bit<24> vni;           // VXLAN Network Identifier
    bit<8>  reserved2;
}

// VXLAN 内部包的 Checksum 处理
control Ingress(...) {

    action decapsulate_vxlan() {
        // 删除 VXLAN Header
        // ... 省略 decapsulate 逻辑

        // 重新计算内部包的 Checksum
        if (h.inner_ipv4.isValid()) {
            // 内部 IPv4 Checksum
            update_checksum(
                h.inner_ipv4.isValid(),
                {
                    h.inner_ipv4.version, h.inner_ipv4.ihl,
                    h.inner_ipv4.diffserv, h.inner_ipv4.totalLen,
                    h.inner_ipv4.identification, h.inner_ipv4.flags,
                    h.inner_ipv4.fragOffset, h.inner_ipv4.ttl,
                    h.inner_ipv4.protocol,
                    h.inner_ipv4.srcAddr, h.inner_ipv4.dstAddr
                },
                h.inner_ipv4.hdrChecksum,
                HashAlgorithm.csum16
            );
        }
    }

    apply {
        decapsulate_vxlan();
    }
}
```

---

## 10. 总结

Checksum 在 P4 数据平面中扮演关键角色：

1. **验证 (verify_checksum)**：Parser 中检查数据完整性
2. **重新计算 (update_checksum)**：Deparser 中更新被修改的 Header
3. **覆盖范围**：
   - IPv4: 仅 Header
   - TCP/UDP: Pseudo Header + Header + Data
4. **计算顺序**：先计算依赖的，再计算被依赖的
5. **增量更新**：可利用 RFC 1624 进行单字段增量计算

理解 Checksum 机制是编写正确网络数据平面程序的基础。到此为止，Part III: Architecture 已全部完成——我们深入探讨了 PSA/TNA 架构、Pipeline 设计、状态管理 (Register/Counter/Gauge) 以及 Checksum。下一部分 (Part IV) 将探讨 P4 的高级特性，包括 Extern 对象、Parse Varset、Meter 等。
