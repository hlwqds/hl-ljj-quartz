---
title: "P4 深度探索 (六)：Header 与 Packet——Header 定义、Header Stack、Packet 内核"
date: 2026-04-14
tags: [p4, series, header, packet, header-stack, metadata]
description: "P4 Header 与 Packet 内核深度解析——Header 类型声明与状态语义、Header Stack 数组、Packet 类的核心方法（extract/emit/truncate）、Metadata 与 Header 的区别、典型协议头的 P4 定义示例"
---

> [!info] P4 深度探索系列
> 0. [[2026-04-14-p4-deep-dive-series-index|全栈学习路径总览]]
> 1. [[2026-04-14-p4-deep-dive-ch1-p4-overview|第一章：P4 概述——诞生背景与协议无关包处理]]
> 2. [[2026-04-14-p4-deep-dive-ch2-p4-architecture|第二章：P4 架构模型——PSA/V1Model、Ingress/Egress]]
> 3. [[2026-04-14-p4-deep-dive-ch3-p4-vs-ebpf|第三章：P4 vs eBPF——适用场景与硬件/软件对比]]
> 4. [[2026-04-14-p4-deep-dive-ch4-p4-program|第四章：P4 程序结构——Header/Parser/Control/Table]]
> 5. [[2026-04-14-p4-deep-dive-ch5-p4-types|第五章：P4 类型系统——bit/varbit/enum/header/struct/tuple]]
> 6. **第六章：Header 与 Packet——Header 定义、Header Stack、Packet 内核**

---

## 1. 概述：Header 是 P4 数据面的核心抽象

在 P4 中，**Header** 是网络数据包中协议头的程序化表示。每个 Header 类型由一组固定长度的字段组成，封装了数据包的协议结构。Header 与传统编程语言中的 struct 类似，但增加了一个关键特性：**Valid/Invalid 状态**。

**Packet**（数据包）则是 P4 程序中表示实际网络数据包的抽象，它提供了从数据包中提取（extract）Header、将 Header 重新组装（emit）回数据包、以及截断（truncate）数据包长度的核心能力。

理解 Header 与 Packet 的设计，是编写正确 P4 程序的基础。

---

## 2. Header 类型声明

### 2.1 基本 Header 声明

Header 类型使用 `header` 关键字声明，语法类似于 C 语言的结构体：

```c
header ethernet_t {
    bit<48> dstAddr;    // 目标 MAC 地址
    bit<48> srcAddr;    // 源 MAC 地址
    bit<16> etherType;  // 以太网类型
}

header ipv4_t {
    bit<4>  version;       // IP 版本
    bit<4>  ihl;           // 头部长度
    bit<8>  diffserv;      // DSCP/ECN
    bit<16> totalLen;      // 总长度
    bit<16> identification; // 标识
    bit<3>  flags;         // 分片标志
    bit<13> fragOffset;    // 分片偏移
    bit<8>  ttl;           // 生存时间
    bit<8>  protocol;      // 协议
    bit<16> hdrChecksum;   // 头部校验和
    bit<32> srcAddr;       // 源 IP
    bit<32> dstAddr;       // 目标 IP
}

header tcp_t {
    bit<16> srcPort;       // 源端口
    bit<16> dstPort;       // 目标端口
    bit<32> seqNo;         // 序列号
    bit<32> ackNo;         // 确认号
    bit<4>  dataOffset;    // 数据偏移
    bit<4>  flags;         // TCP 标志
    bit<16> window;        // 窗口大小
    bit<16> checksum;      // 校验和
    bit<16> urgentPtr;     // 紧急指针
}
```

**字段类型约束**：
- Header 字段**只能是固定宽度的类型**：`bit<N>`、`varbit<N>`、`bool`
- Header 字段**不能是**：`int<N>`、`enum`（enum 可以作为字段值，但字段本身仍是 bit<N>）
- Header 字段**不能有默认值**（全零或 Invalid 是默认值）

### 2.2 标准 Header 与定制 Header

**标准协议 Header**（如 Ethernet、IPv4、TCP）：

```c
// P4 标准库提供了常用协议的 Header 定义
// 这些可以直接使用或继承重定义
header ethernet_h {
    bit<48> dst_addr;
    bit<48> src_addr;
    bit<16> ether_type;
}
```

**定制协议 Header**：

```c
// 自定义 VLAN Header
header vlan_t {
    bit<3>  pcp;        // Priority Code Point
    bit<1>  dei;        // DEI (Drop Eligibility Indicator)
    bit<12> vid;        // VLAN ID
    bit<16> etherType;  // 嵌套的以太网类型
}

// VXLAN Header (定制协议)
header vxlan_t {
    bit<8>  flags;          // 标志位
    bit<24> reserved;        // 保留字段
    bit<24> vni;             // VXLAN Network Identifier
    bit<8>  reserved2;      // 保留字段
}

// GRE Header
header gre_t {
    bit<1>  checksum_flag;   // 校验和标志
    bit<1>  reserved_flag;  // 保留标志
    bit<1>  key_flag;       // Key 标志
    bit<1>  sequence_flag;  // 序列号标志
    bit<9>  reserved;       // 保留
    bit<16> protocol;       // 协议类型
}
```

---

## 3. Header 实例化与 Valid/Invalid 状态

### 3.1 Header 实例化

Header 类型声明后，需要在 `headers` 结构体中实例化：

```c
// headers_t 结构体包含所有 Header 实例
struct headers_t {
    ethernet_t ethernet;
    ipv4_t     ipv4;
    ipv6_t     ipv6;
    tcp_t      tcp;
    udp_t      udp;
    vlan_t[2]  vlans;     // Header Stack：最多 2 个 VLAN
    vxlan_t    vxlan;
}
```

**注意**：`headers_t` 必须是 `struct` 类型，不能是 `header` 类型。Header 是具体的数据结构，而 `headers_t` 是它们的聚合容器。

### 3.2 Valid/Invalid 状态

每个 Header 实例都有一个隐藏的 **Valid/Invalid 状态位**：

```c
header ethernet_t eth;  // 初始状态: Invalid

// 检查状态
if (eth.isValid()) {
    // 仅当 eth 为 Valid 时才进入此分支
}

// 标记为有效并填充字段
eth.setValid();
eth.dstAddr = 0x001122334455;
eth.srcAddr = 0xAABBCCDDEEFF;
eth.etherType = 0x0800;  // IPv4

// 标记为无效
eth.setInvalid();  // 状态变为 Invalid
```

**Valid/Invalid 的语义**：

| 操作 | 当 Invalid 时 | 当 Valid 时 |
|------|--------------|-------------|
| `isValid()` | 返回 `false` | 返回 `true` |
| 读取字段值 | **未定义行为** | 返回字段值 |
| 写入字段 | **未定义行为** | 写入成功 |
| `setValid()` | 变为 Valid | 仍为 Valid |
| `setInvalid()` | 仍为 Invalid | 变为 Invalid |

**重要警告**：访问 Invalid Header 的字段是**未定义行为**，在某些硬件上可能返回垃圾值，在软件交换机上可能触发断言失败。

### 3.3 Valid/Invalid 的典型用法

```c
control Ingress() {
    apply {
        // 从数据包提取 Ethernet Header
        packet.extract(h.ethernet);

        // 检查 Ethernet 是否有效
        if (h.ethernet.isValid()) {
            // 检查 EtherType
            if (h.ethernet.etherType == 0x0800) {
                // 提取 IPv4
                packet.extract(h.ipv4);
                
                if (h.ipv4.isValid() && h.ipv4.ttl > 0) {
                    // 处理 IPv4 包
                    ipv4_forward.apply();
                }
            }
            // ... 其他协议处理
        }
    }
}
```

---

## 4. Header Stack：Header 数组

### 4.1 Header Stack 声明

Header Stack 是**相同类型 Header 实例的数组**，使用 `[N]` 语法声明：

```c
header vlan_t[2]   vlans;      // 最多 2 个 VLAN
header mpls_t[3]   mpls_stack; // 最多 3 个 MPLS 标签
header ipv6_option_t[8] ipv6_options; // 最多 8 个 IPv6 选项
```

### 4.2 Header Stack 的索引访问

```c
// 访问单个元素
vlans[0].setValid();
vlans[0].vid = 100;

// 遍历
for (int i = 0; i < 2; i++) {
    if (vlans[i].isValid()) {
        // 处理 vlans[i]
    }
}
```

### 4.3 Header Stack 的特殊方法

Header Stack 提供了一些方便的方法：

```c
// lastValid(): 返回最后一个有效的元素索引
int last_idx = vlans.lastValid();  // 如 [0]=Valid, [1]=Invalid, 返回 0

// pop_front(n): 从前面移除 n 个元素
// mpls_stack.pop_front(1);  // 移除第一个 MPLS 标签

// push_front(n): 从前面压入 n 个元素
// mpls_stack.push_front(1);  // 在前面添加一个新标签

// getLast(): 获取最后一个有效元素
// vlan_t last_vlan = vlans.getLast();
```

### 4.4 典型应用：多 VLAN 标签

```c
state parse_vlan {
    bit<16> ether_type;
    
    packet.extract(h.vlans[next_vlan_index]);
    
    if (next_vlan_index < 2) {
        ether_type = h.vlans[next_vlan_index].etherType;
        if (ether_type == 0x8100) {
            next_vlan_index = next_vlan_index + 1;
            transition parse_vlan;  // 继续解析下一个 VLAN
        }
    }
    
    transition select(ether_type) {
        0x0800:   parse_ipv4;
        0x86DD:   parse_ipv6;
        default:  accept;
    }
}
```

---

## 5. Packet 类：数据包操作接口

### 5.1 Packet 类的核心方法

| 方法 | 作用 |
|------|------|
| `packet.extract(h)` | 从数据包中提取 Header |
| `packet.lookahead<T>()` | 预读 T 类型的数据但不消耗 |
| `packet.emit(h)` | 将 Header 重新组装到数据包 |
| `packet.push_front(size)` | 在数据包前面添加空间 |
| `packet.truncate(size)` | 截断数据包长度 |

### 5.2 extract()：Header 提取

`extract()` 是 Parser 中最重要的操作，从数据包的**当前读取位置**提取数据到 Header：

```c
// 基本用法
packet.extract(h.ethernet);  // 提取 14 字节 Ethernet Header

// 提取带变长字段的 Header (varbit)
varbit<320> ipv4_options;
packet.extract(h.ipv4.options, (bit<32>)ipv4_option_length);

// 提取 Header Stack
packet.extract(h.vlans, next_vlan_index);
```

**extract() 的语义**：
1. 从数据包当前偏移读取数据
2. 填充到 Header 的各个字段
3. 将 Header 的 Valid/Invalid 状态设置为 **Valid**
4. 更新数据包的当前读取偏移

### 5.3 lookahead()：预读

`lookahead()` 允许在不移动读取位置的情况下检查后续数据：

```c
// 预读 EtherType（Ethernet Header 后 12 字节处）
bit<16> ether_type = packet.lookahead<bit<16>>();

// 在 transition 中使用 lookahead
transition select(packet.lookahead<bit<16>>()) {
    0x0800:   parse_ipv4;
    0x86DD:   parse_ipv6;
    0x8100:   parse_vlan;
    default:  accept;
}
```

**典型用法**：在没有完整解析 Header 之前，先用 lookahead 判断下一层协议类型，避免为每个可能的协议都定义状态。

### 5.4 emit()：Header 重组

`emit()` 将 Header 重新写回到数据包的**末尾**（Deparser 中使用）：

```c
control DeparserImpl(packet_out packet, in headers_t h) {
    apply {
        packet.emit(h.ethernet);  // 发送 Ethernet Header
        packet.emit(h.vlans);     // 发送 VLAN 标签（所有有效元素）
        packet.emit(h.ipv4);      // 发送 IPv4 Header
        packet.emit(h.tcp);       // 发送 TCP Header
        packet.emit(h.payload);   // 发送负载
    }
}
```

**emit() 的语义**：
1. 仅发送 **Valid** 的 Header
2. Invalid Header 被**跳过**（不发送）
3. Header Stack 发送所有 Valid 元素

### 5.5 push_front()：添加数据包头

`push_front()` 在数据包前面插入空间（通常用于添加封装头）：

```c
// 在数据包前面添加 20 字节（用于插入 MPLS 标签）
packet.push_front(20);

// 填充 MPLS Header
mpls_t mpls;
mpls.setValid();
mpls.label = 100;
mpls.tc = 0;
mpls.bos = 1;  // 栈底
mpls.ttl = 64;

packet.emit(mpls);  // 将 MPLS Header 写入新空间
```

### 5.6 truncate()：截断数据包

`truncate()` 将数据包截断到指定长度：

```c
// 截断数据包（保留前 64 字节）
// 通常用于发送 ICMP Error 报文时
packet.truncate(64);
```

---

## 6. Metadata 与 Header 的区别

### 6.1 概念区分

| 维度 | Header | Metadata |
|------|--------|----------|
| **用途** | 表示数据包内容 | 表示包的上下文信息 |
| **来源** | 来自网络线缆 | 由程序生成或修改 |
| **序列化** | 会出现在数据包中 | 不会出现在数据包中 |
| **Valid 状态** | 有 | 无 |
| **典型示例** | Ethernet、IPv4、TCP | 入口端口、时间戳、是否被 ACL 命中 |

### 6.2 Metadata 声明

```c
struct metadata_t {
    bit<9>  ingress_port;        // 入口端口
    bit<48> ingress_timestamp;   // 入口时间戳
    bit<32> acl_hit;             // ACL 命中标记
    bit<24> vni;                 // VXLAN VNI
    bit<9>  egress_spec;         // 出口端口
    bit<8>  qos_class;           // QoS 等级
    bool    is_multicast;        // 是否多播
}
```

### 6.3 Header Stack vs Metadata Array

Header Stack 用于协议头，Metadata Array 用于存储多个元数据值：

```c
struct metadata_t {
    bit<16> acl_stats[128];  // 128 个 ACL 计数器
    ipv4_addr_t router_ids[4]; // 4 个路由器 ID
}
```

---

## 7. 典型协议头的 P4 定义

### 7.1 IPv6 Header

```c
header ipv6_t {
    bit<4>   version;        // 6
    bit<8>   trafficClass;   // 流量类别
    bit<20>  flowLabel;      // 流标签
    bit<16>  payloadLen;     // 负载长度
    bit<8>   nextHeader;     // 下一个头（类似 protocol）
    bit<8>   hopLimit;       // 跳限
    bit<128> srcAddr;        // 源地址
    bit<128> dstAddr;        // 目标地址
}
```

### 7.2 UDP Header

```c
header udp_t {
    bit<16> srcPort;     // 源端口
    bit<16> dstPort;     // 目标端口
    bit<16> length_;     // 长度
    bit<16> checksum;    // 校验和
}
```

### 7.3 ICMP Header

```c
header icmp_t {
    bit<8>  type;        // ICMP 类型
    bit<8>  code;        // ICMP 代码
    bit<16> checksum;    // 校验和
    bit<16> identifier;  // 标识符
    bit<16> sequence;    // 序列号
}
```

### 7.4 VXLAN Header

```c
header vxlan_t {
    bit<8>  flags;       // 8 bits flags
    bit<24> reserved1;  // 24 bits reserved
    bit<24> vni;         // 24 bits VXLAN Network Identifier
    bit<8>  reserved2;   // 8 bits reserved
}
```

### 7.5 GRE Header

```c
header gre_t {
    bit<1>  C;           // Checksum present
    bit<1>  R;           // Routing present
    bit<1>  K;           // Key present
    bit<1>  S;           // Sequence number present
    bit<3>  reserved;    // Reserved
    bit<3>  version;     // Version
    bit<16> protocol;   // Protocol type (Ethernet type)
}
```

---

## 8. Header 操作的高级技巧

### 8.1 条件字段访问

在某些情况下，我们需要根据其他字段的值决定是否访问某个字段：

```c
// TCP 有选项时读取选项长度
if (h.tcp.dataOffset > 5) {
    // TCP Header 长度 > 20 字节，存在选项
    bit<8> option_length = (bit<8>)(h.tcp.dataOffset - 5) * 4;
    // 提取 TCP 选项
}
```

### 8.2 Header 复制

可以将一个 Header 的值复制到另一个同类型的 Header：

```c
ethernet_t inner_ethernet;
ethernet_t outer_ethernet;

// 复制（只复制字段值，不复制 Valid/Invalid 状态）
inner_ethernet = outer_ethernet;
```

### 8.3 使用 typedef 简化类型定义

```c
typedef bit<48> mac_addr_t;
typedef bit<32> ipv4_addr_t;
typedef bit<128> ipv6_addr_t;

header ethernet_t {
    mac_addr_t  dstAddr;
    mac_addr_t  srcAddr;
    bit<16>     etherType;
}

header ipv4_t {
    bit<4>      version;
    ipv4_addr_t srcAddr;
    ipv4_addr_t dstAddr;
}
```

---

## 9. 小结

本章介绍了 P4 中 Header 与 Packet 的核心概念：

1. **Header 类型**：由固定宽度字段组成的协议头表示，支持 Valid/Invalid 状态
2. **Header 实例化**：在 `headers` 结构体中声明，通过 `setValid()`/`setInvalid()`/`isValid()` 操作状态
3. **Header Stack**：相同类型 Header 的数组，支持 push/pop 操作和 `lastValid()`/`getLast()` 方法
4. **Packet 类**：提供 `extract()`、`emit()`、`lookahead()`、`push_front()`、`truncate()` 核心操作
5. **Metadata**：不参与数据包序列化的上下文信息，与 Header 有本质区别

理解这些基础概念后，下一章我们将学习 **Parser 编程**，了解如何用状态机解析数据包中的各个协议头。
