---
title: "P4 深度探索 (十七)：Parse Varset——变长 Header 与 IPv6 Extension Header 解析"
date: 2026-04-14
tags:
  [p4, series, parse-varset, ipv6, extension-header, varbit, parser, variable-length, hop-by-hop]
description: "P4 Parse Varset 深度解析——变长 Header 定义、varbit 类型、IPv6 Extension Header 解析（Hop-by-Hop/Destination/Routing/Fragment）、状态机循环解析、TLV 编码解析、IPv6 分片处理"
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
> 15. [[2026-04-14-p4-deep-dive-ch15-checksum|第十五章：Checksum——Checksum 验证与重新计算、IPv4/TCP/UDP]]
> 16. [[2026-04-14-p4-deep-dive-ch16-extern|第十六章：Extern 对象——Hash/Checksum/Register/Queue/Digest]]
> 17. **第十七章：Parse Varset——变长 Header 与 IPv6 Extension Header 解析**

---

## 1. 概述：变长 Header 的挑战

网络协议中，很多 Header 的长度是**不固定的**——例如 IPv6 Extension Header、MPLS 标签栈、VLAN 标签栈。这些 Header 由**可变数量的 TLV（Type-Length-Value）** 子元素组成，每个 TLV 的长度需要根据实际的 TLV 值来计算。

P4 的 `varbit` 类型和 **Parse Varset** 机制，专门用于处理这类变长 Header 解析。

### 1.1 P4 中的定长 vs 变长类型

| 类型        | 关键字              | 特点                    |
| ----------- | ------------------- | ----------------------- |
| 定长位      | `bit<W>`            | 编译时已知宽度          |
| 变长位      | `varbit<W>`         | 运行时确定，最大 W 比特 |
| 定长 Header | `header`            | 所有字段定长            |
| 变长 Header | `header` + `varbit` | 至少一个字段变长        |

---

## 2. varbit 类型详解

### 2.1 varbit 声明与使用

```c
// varbit: 可变长度的位字段
// 最大宽度在编译时指定，实际宽度在运行时确定

header variable_header_t {
    bit<8>  type;      // TLV Type
    bit<8>  length;    // TLV Length (Value 的字节数)
    varbit<256> value; // TLV Value，最大 256 bits
}

// MPLS 标签栈（每标签 32 bits，但标签数量可变）
header mpls_stack_t {
    varbit<128> labels;  // 最大 4 个 MPLS 标签 (4*32=128)
}
```

### 2.2 varbit 与 packet_in

`varbit` 字段必须通过 `packet_in.extract()` 提取：

```c
parser MyParser(packet_in packet,
                out headers h,
                inout metadata m) {

    state parse_tlv {
        // extract() 会根据 length 字段动态确定 varbit 长度
        packet.extract(h.variable_header);

        // length 字段以字节为单位
        // value 的实际长度 = length × 8 bits

        transition accept;
    }
}
```

### 2.3 IPv6 Extension Header 变长问题

```
IPv6 Packet 结构:
=================

+--------+--------+--------+--------+  ----,
| IPv6   |  Ext   |  Ext   |  TCP   |       |
| Base   | HDR 1  | HDR 2  | Header |  Payload
| Header | (var)  | (var)  | (fix)  |
+--------+--------+--------+--------+  ----'
   40B    N×8B     M×8B      20B

IPv6 Base Header 长度固定: 40 bytes
Extension Header 长度可变: 每个 Extension Header 由:
  - 1 byte: Next Header
  - 1 byte: Hdr Ext Len (Extension Header 长度，不含前 8 bytes)
  - N bytes: Options/Data (由 Hdr Ext Len 决定)
```

---

## 3. IPv6 Extension Header 解析

### 3.1 IPv6 Extension Header 类型

| Next Header值 | Extension Header                     |
| ------------- | ------------------------------------ |
| 0             | Hop-by-Hop Options                   |
| 6             | TCP (不是 Extension Header)          |
| 17            | UDP (不是 Extension Header)          |
| 43            | Routing Header                       |
| 44            | Fragment Header                      |
| 50            | ESP Header                           |
| 51            | AH Header                            |
| 59            | No Next Header                       |
| 60            | Destination Options (before Routing) |

### 3.2 Hop-by-Hop Options Header

```
Hop-by-Hop Options Header:
==========================

 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|  Next Header  |  Hdr Ext Len  |                               |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+                               |
|                                                               |
+                                                               +
|                    Options (variable)                          |
|                                                               |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

### 3.3 P4 中的 IPv6 Extension Header 定义

```c
// IPv6 Base Header
header ipv6_t {
    bit<4>   version;
    bit<8>   trafficClass;
    bit<20>  flowLabel;
    bit<16>  payloadLen;
    bit<8>   nextHdr;       // 下一个 Header 的协议号
    bit<8>   hopLimit;
    bit<128> srcAddr;
    bit<128> dstAddr;
}

// Hop-by-Hop Options Header
header ipv6_hop_by_hop_t {
    bit<8>  nextHdr;
    bit<8>  hdrExtLen;       // Extension Header 长度（不含前 8 bytes）
    varbit<320> options;     // Options 字段，最大 320 bits
}

// Destination Options Header
header ipv6_dst_options_t {
    bit<8>  nextHdr;
    bit<8>  hdrExtLen;
    varbit<320> options;
}

// Routing Header
header ipv6_routing_t {
    bit<8>  nextHdr;
    bit<8>  hdrExtLen;
    bit<8>  routingType;
    bit<8>  segmentsLeft;
    varbit<320> addresses;  // 取决于路由类型
}

// Fragment Header
header ipv6_fragment_t {
    bit<8>   nextHdr;
    bit<8>   reserved;
    bit<13>  fragOffset;
    bit<2>   res;
    bit<1>   m;            // More Fragments
    bit<32>  identification;
}
```

---

## 4. 状态机循环解析

### 4.1 链式 Extension Header 解析

IPv6 Extension Header 的核心挑战：**下一个 Header 的类型在当前 Header 中指示**，必须**循环解析**直到遇到真正的上层协议。

```
IPv6 Extension Header 解析流程:
==============================

1. 解析 IPv6 Base Header
   - 读取 nextHdr 字段
   |
   v
2. 根据 nextHdr 选择下一状态
   |
   +--> 6 (TCP)     --> parse_tcp
   +--> 17 (UDP)    --> parse_udp
   +--> 0 (Hop-by-Hop) --> parse_hop_by_hop
   +--> 43 (Routing)    --> parse_routing
   +--> 44 (Fragment)   --> parse_fragment
   +--> 51 (AH)         --> parse_ah
   +--> 59 (No Next)    --> accept
   |
   v
3. 解析每个 Extension Header 后，用其 nextHdr 继续循环
```

### 4.2 P4 状态机实现

```c
// ================ IPv6 Extension Header 解析器 ================

// 扩展 Header 栈
header_union ipv6_ext_union {
    ipv6_hop_by_hop_t hop_by_hop;
    ipv6_routing_t     routing;
    ipv6_fragment_t    fragment;
    ipv6_dst_options_t dst_options_1;  // 第一个 Destination Options
    ipv6_dst_options_t dst_options_2;  // 第二个 Destination Options (before Routing)
}

// Extension Header 状态
enum bit<8> ext_hdr_state_t {
    HBH,    // Hop-by-Hop
    DEST1,  // Destination Options (before Routing)
    ROUTING,// Routing
    FRAG,   // Fragment
    DEST2,  // Destination Options (after Routing)
    DONE    // 解析完成
}

parser IngressParser(packet_in packet,
                    out headers h,
                    inout metadata m) {

    // 记录下一个要解析的 Extension Header 类型
    state start {
        packet.extract(h.ethernet);
        transition select(h.ethernet.etherType) {
            0x86DD: parse_ipv6;
            default: accept;
        }
    }

    state parse_ipv6 {
        packet.extract(h.ipv6);

        // 记录下一个 Header 类型
        m.next_hdr = h.ipv6.nextHdr;
        m.ext_state = ext_hdr_state_t.DONE;

        transition select(h.ipv6.nextHdr) {
            0:   parse_hop_by_hop;    // Hop-by-Hop Options
            6:   parse_tcp;            // TCP
            17:  parse_udp;            // UDP
            43:  parse_routing;        // Routing Header
            44:  parse_fragment;       // Fragment Header
            51:  parse_auth;           // AH
            59:  accept;               // No Next Header
            60:  parse_dst_options_1;   // Destination Options (before Routing)
            default: accept;
        }
    }

    // ---- Hop-by-Hop Options ----
    state parse_hop_by_hop {
        packet.extract(h.hop_by_hop);
        m.next_hdr = h.hop_by_hop.nextHdr;
        m.ext_state = ext_hdr_state_t.HBH;

        transition select(h.hop_by_hop.nextHdr) {
            0:   parse_hop_by_hop;     // 链式 Hop-by-Hop
            6:   parse_tcp;
            17:  parse_udp;
            43:  parse_routing;
            44:  parse_fragment;
            60:  parse_dst_options_1;  // 跳到 Destination Options
            default: accept;
        }
    }

    // ---- Destination Options (第一次，在 Routing 之前) ----
    state parse_dst_options_1 {
        packet.extract(h.dst_options_1);
        m.next_hdr = h.dst_options_1.nextHdr;
        m.ext_state = ext_hdr_state_t.DEST1;

        transition select(h.dst_options_1.nextHdr) {
            43:  parse_routing;         // Routing Header
            6:   parse_tcp;
            17:  parse_udp;
            default: accept;
        }
    }

    // ---- Routing Header ----
    state parse_routing {
        packet.extract(h.routing);
        m.next_hdr = h.routing.nextHdr;
        m.ext_state = ext_hdr_state_t.ROUTING;

        transition select(h.routing.nextHdr) {
            60:  parse_dst_options_2;  // Destination Options (after Routing)
            6:   parse_tcp;
            17:  parse_udp;
            44:  parse_fragment;
            default: accept;
        }
    }

    // ---- Destination Options (第二次，在 Routing 之后) ----
    state parse_dst_options_2 {
        packet.extract(h.dst_options_2);
        m.next_hdr = h.dst_options_2.nextHdr;
        m.ext_state = ext_hdr_state_t.DEST2;

        transition select(h.dst_options_2.nextHdr) {
            6:   parse_tcp;
            17:  parse_udp;
            44:  parse_fragment;
            default: accept;
        }
    }

    // ---- Fragment Header ----
    state parse_fragment {
        packet.extract(h.fragment);
        m.next_hdr = h.fragment.nextHdr;
        m.ext_state = ext_hdr_state_t.FRAG;

        // 分片之后，Payload 偏移量
        m.fragment_offset = (bit<16>)h.fragment.fragOffset * 8;

        transition select(h.fragment.nextHdr) {
            6:   parse_tcp;
            17:  parse_udp;
            default: accept;
        }
    }

    // ---- Authentication Header (AH) ----
    state parse_auth {
        // AH 的长度由 Auth Data Length 字段决定
        // 固定部分之后跟着 ICV (Integrity Check Value)
        packet.extract(h.auth);

        // AH 的 Next Header 在固定位置
        m.next_hdr = h.auth.nextHdr;

        // 跳到 Payload（通常是 ESP 或传输层协议）
        transition select(h.auth.nextHdr) {
            50:  parse_esp;    // ESP
            6:   parse_tcp;
            17:  parse_udp;
            default: accept;
        }
    }

    // ---- TCP ----
    state parse_tcp {
        packet.extract(h.tcp);
        transition accept;
    }

    // ---- UDP ----
    state parse_udp {
        packet.extract(h.udp);
        transition accept;
    }
}
```

---

## 5. TLV 循环解析

### 5.1 TLV Option 循环

Hop-by-Hop Options 和 Destination Options 中的 Options 字段由多个 **TLV Option** 组成：

```
TLV Option 结构:
================

 0                   1                   2
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|  Option Type  |  Option Length  |   Option Data
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

Option Type:
  - bit[7:5] = 00: 跳过并继续处理
  - bit[7:5] = 01: 跳过并交给终节点
  - bit[7:5] = 10: 丢弃报文
  - bit[7:5] = 11: 丢弃报文并发送 ICMP
  - bit[0]: 0 = 不允许在传输过程中改变
           1 = 允许在传输过程中改变
```

### 5.2 TLV Option 循环解析

```c
// metadata 中记录 TLV 解析状态
struct metadata {
    bit<8>  current_option_type;
    bit<8>  current_option_len;
    bit<16> options_bytes_parsed;
    bit<16> options_total_len;
    bool    options_loop_continue;
}

// 在 state 中循环解析 TLV
state parse_hop_by_hop_options_loop {
    // 已经提取了 Hop-by-Hop Header 的固定 8 字节
    // 剩余的 options 字段是变长的 TLV 序列

    // 使用 Header Stack 来解析多个 TLV
    // 或者直接使用循环状态机

    // 计算剩余选项的总长度
    // Hdr Ext Len 的单位是 8 字节块，但不含前 8 字节
    // 所以总选项长度 = Hdr Ext Len * 8

    // 注意: P4 的 packet_in.extract() 支持变长提取
    // 但循环解析需要在状态机中处理

    // 检查是否还有未解析的 Options
    verify(m.options_bytes_parsed < m.options_total_len,
           error.NoNextHeader);

    transition select(m.options_bytes_parsed < m.options_total_len) {
        true:  parse_one_tlv_option;
        false: continue_to_next_hdr;
    }
}

state parse_one_tlv_option {
    // 提取 Option Type + Length (2 bytes 头部)
    // 然后根据 Length 提取 Option Data

    // 先读取前 2 bytes 确定 Option 类型和长度
    bit<8> option_type;
    bit<8> option_len;

    // 使用 packet.lookahead<> 来预读而不消耗数据
    option_type = packet.lookahead<bit<8>>();
    option_len  = packet.lookahead<bit<8>>() >> 8;

    // 注意: lookahead 不消耗数据，extract 才消耗

    // 根据 Option Type 决定如何处理
    transition select(option_type) {
        0x00: skip_pad1;          // Pad1 Option (特殊，长度字段本身不存在)
        0x01: skip_padN;          // PadN Option
        0x05: parse_router_alert; // Router Alert Option
        0xC2: parse_jumbo_mtu;   // Jumbo Payload Hop-by-Hop Option
        default: skip_unknown_option;
    }
}

// Pad1: 特殊格式，只有 1 byte，没有 Length 和 Value
state skip_pad1 {
    m.options_bytes_parsed = m.options_bytes_parsed + 1;
    transition parse_hop_by_hop_options_loop;
}

// PadN: 2+ bytes，全部为 0
state skip_padN {
    // PadN 的 Option Length 字段指示 Value 的字节数
    m.options_bytes_parsed = m.options_bytes_parsed
                           + 2      // Type + Length
                           + m.current_option_len;  // Padding bytes
    transition parse_hop_by_hop_options_loop;
}
```

---

## 6. IPv6 Fragment 解析

### 6.1 Fragment Header 结构

```
IPv6 Fragment Header:
=====================

 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|  Next Header  |   Reserved    |      Fragment Offset   | Res |M|
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                         Identification                        |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

- Fragment Offset: 13 bits，以 8 字节为单位
- M (More Fragments): 1 = 还有更多分片，0 = 最后一个分片
- Identification: 32 bits，用于唯一标识原始包的所有分片
```

### 6.2 Fragment 解析处理

```c
header ipv6_fragment_t {
    bit<8>   nextHdr;
    bit<8>   reserved;
    bit<13>  fragOffset;
    bit<2>   res;
    bit<1>   m_flag;         // More Fragments
    bit<32>  identification;
}

// Fragment 处理逻辑
control FragmentProcessing(inout headers h, inout metadata m) {

    // 判断是否为原始包的第一个分片
    action is_first_fragment() {
        m.is_fragment = true;
        m.is_first_frag = (h.fragment.fragOffset == 0);
        m.is_last_frag = (h.fragment.m_flag == 0);
        m.fragment_id = h.fragment.identification;
        m.payload_offset = (bit<16>)h.fragment.fragOffset * 8;
    }

    // 重组判断：需要收集所有分片
    action need_reassembly() {
        // 只有最后一个分片才进行重组
        // 或者第一个分片带有完整的 Upper Layer Header
        // (Fragment Header 出现在 Destination Options 之后)
    }

    // ACL: 允许完整包，但检查分片包
    action check_fragment_policy() {
        if (h.fragment.isValid()) {
            // 分片包: 检查 Identification + Offset 组合
            // 防止分片攻击
            if (m.fragment_id == 0) {
                // Identification 为 0 的分片可能是攻击
                drop();
            }
        }
    }
}
```

---

## 7. MPLS 标签栈解析

### 7.1 MPLS 标签栈结构

```
MPLS Label Stack:
=================

+----+----+----+----+
| L1 | L2 | L3 | L4 |  (Label Entry = 32 bits = 4 bytes)
+----+----+----+----+

每个 Label Entry:
  - Label:  20 bits
  - TC:     3 bits (Traffic Class)
  - BoS:    1 bit  (Bottom of Stack, 1 表示最后一个标签)
  - TTL:    8 bits

+----+----+----+----+----+----+----+----+
|     Label    | TC |S|       TTL       |
+----+----+----+----+----+----+----+----+
  20 bits    3  1  8 bits
```

### 7.2 MPLS 标签栈解析

```c
// MPLS 标签 Header
header mpls_t {
    bit<20> label;
    bit<3>  tc;
    bit<1>  bos;     // Bottom of Stack: 1 = 最后一个标签
    bit<8>  ttl;
}

// Header Stack: 最多 3 个 MPLS 标签
header mpls_stack_t[3] {
    mpls_t[0],
    mpls_t[1],
    mpls_t[2]
}

// MPLS 解析状态机
parser parse_mpls(packet_in packet,
                  out headers h,
                  inout metadata m) {

    state start {
        // 检查 EtherType 是否为 MPLS (0x8847 或 0x8848)
        transition select(h.ethernet.etherType) {
            0x8847: parse_mpls_0;
            0x8848: parse_mpls_0;  // MPLS Unicast/Multicast
            default: accept;
        }
    }

    state parse_mpls_0 {
        packet.extract(h.mpls_stack[0]);
        m.mpls_label_count = 1;

        // 检查是否还有更多标签
        transition select(h.mpls_stack[0].bos) {
            0: parse_mpls_1;  // 还有更多标签
            1: parse_mpls_done;
        }
    }

    state parse_mpls_1 {
        packet.extract(h.mpls_stack[1]);

        transition select(h.mpls_stack[1].bos) {
            0: parse_mpls_2;
            1: parse_mpls_done;
        }
    }

    state parse_mpls_2 {
        packet.extract(h.mpls_stack[2]);
        // 最后一个标签（最多 3 层）

        transition select(h.mpls_stack[2].bos) {
            0: parse_mpls_overflow;  // 超过 3 层
            1: parse_mpls_done;
        }
    }

    state parse_mpls_done {
        // 根据 MPLS 标签决定下一步协议
        transition select(h.mpls_stack.lastNextHdr) {
            0x0800: parse_ipv4;
            0x86DD: parse_ipv6;
            default: accept;
        }
    }

    state parse_mpls_overflow {
        // 超过支持的最大标签数
        transition accept;
    }
}
```

---

## 8. 变长 Header 的 Match-Action

### 8.1 在变长 Header 上定义 Table Key

```c
control ACL(inout headers h, inout metadata m) {

    // 变长字段可以作为 exact match key
    action drop_or_permit() {
        // 假设 hop_by_hop.options 的前 8 bits 是 Router Alert Option Type
        if (h.hop_by_hop.isValid()) {
            // 使用 varbit 字段的已解析部分作为 key
            bit<8> router_alert = h.hop_by_hop.options[7:0];

            if (router_alert == 0x05) {
                // Router Alert Option - 通常是 RSVP/IGMP
                // 特殊处理
                NoAction();
            }
        }
    }

    // ACL 基于 IPv6 Extension Header
    table ipv6_ext_acl {
        key = {
            h.hop_by_hop.isValid(): exact;
            h.routing.isValid():     exact;
            h.fragment.isValid():    exact;
            // 也可以使用 varbit 字段的部分 bits
        }
        actions = {
            allow;
            drop;
        }
        default_action = allow;
    }
}
```

---

## 9. Deparser 中的变长 Header

### 9.1 重组变长 Header

Deparser 必须按照协议规范**逆序重组** Header：

```c
control IngressDeparser(packet_out packet,
                         inout headers h,
                         in metadata m,
                         in PSA_ingress_output_metadata_t ostd) {

    apply {
        // 发射 Ethernet
        packet.emit(h.ethernet);

        // 发射 IPv6 Base Header
        packet.emit(h.ipv6);

        // 按解析的逆序发射 Extension Headers
        // 如果解析了 Hop-by-Hop，再发射 Destination Options (before Routing)，
        // Routing, Destination Options (after Routing)...

        if (m.ext_state == ext_hdr_state_t.HBH) {
            packet.emit(h.hop_by_hop);
        }

        if (m.ext_state >= ext_hdr_state_t.DEST1) {
            packet.emit(h.dst_options_1);
        }

        if (m.ext_state >= ext_hdr_state_t.ROUTING) {
            packet.emit(h.routing);
        }

        if (m.ext_state >= ext_hdr_state_t.DEST2) {
            packet.emit(h.dst_options_2);
        }

        if (m.ext_state >= ext_hdr_state_t.FRAG) {
            packet.emit(h.fragment);
        }

        // 最后发射传输层 Header
        packet.emit(h.tcp);
    }
}
```

---

## 10. 小结

本章介绍了 P4 中 **Parse Varset** 处理变长 Header 的机制：

| 技术                    | 应用场景                        |
| ----------------------- | ------------------------------- |
| `varbit<W>`             | 变长位字段，最大 W bits         |
| `packet.extract()`      | 动态提取变长 Header             |
| `header_union`          | 互斥的 Header（只能有一个有效） |
| `header stack`          | 顺序排列的同类 Header（MPLS）   |
| 状态机循环              | IPv6 Extension Header 链式解析  |
| `packet.lookahead<T>()` | 预读而不消耗数据                |

IPv6 Extension Header 的解析是 Parse Varset 最复杂的应用，需要用**状态机循环**处理链式 Extension Header，直到遇到上层协议或 No Next Header。
