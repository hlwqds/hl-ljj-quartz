---
title: "P4 深度探索 (十九)：INT——In-band Network Telemetry 随流检测"
date: 2026-04-14
tags:
  [p4, series, int, in-band-network-telemetry, telemetry, network-observability, p4-16, metadata]
description: "P4 INT (In-band Network Telemetry) 深度解析——随流遥测架构、INT Header 格式、Metadata 收集与插入、Hop-by-Hop vs End-to-End INT、INT 在 Tofino 上的实现、Telemetry 收集器"
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
> 10. [[ch10-deparser|第十章：Deparser——包重组、Header 顺序、Checksum 重新计算]]
> 11. [[ch11-psa|第十一章：PSA 架构——Portable Switch Architecture、Ingress/Egress 管道]]
> 12. [[ch12-tna|第十二章：TNA 架构——Tofino Native Architecture、高性能流水线]]
> 13. [[ch13-pipeline|第十三章：Pipeline 设计——Match-Action 流水线、逻辑阶段与物理阶段]]
> 14. [[ch14-registers|第十四章：Register 与状态——Register、Counter、Gauge、Direct/Indirect 资源]]
> 15. [[ch15-checksum|第十五章：Checksum——Checksum 验证与重新计算、IPv4/TCP/UDP]]
> 16. [[ch16-extern|第十六章：Extern 对象——Hash/Checksum/Register/Queue/Digest]]
> 17. [[ch17-parsevarset|第十七章：Parse Varset——变长 Header 与 IPv6 Extension Header 解析]]
> 18. [[ch18-meter|第十八章：Meter 与 Traffic Manager——流量计量、队列管理与 QoS]]
> 19. **第十九章：INT——In-band Network Telemetry 随流检测**

---

## 1. 概述：什么是 INT？

**INT (In-band Network Telemetry，随流遥测)** 是一种网络可观测性技术，它允许网络设备在**数据包内部**插入**实时遥测数据**，无需外部探针或 NetFlow/IPFIX 轮询机制。

```
传统遥测 vs INT:
================

传统遥测 (NetFlow/sFlow):
  +--------+    Data     +--------+
  | Router | ---------> |Collector|
  +--------+            +--------+
     ^                      |
     | (periodic polling)    |
     +----------------------+

INT (In-band Telemetry):
  +--------+ +--------+ +--------+
  | Switch | | Switch | | Switch |  +--------+
  | INT    | | INT    | | INT    |->|Collector|
  +--------+ +--------+ +--------+  +--------+
     ^                        ^
     | 插入 Metadata          | 插入 Metadata
     |                        |
  Packet with embedded INT data
```

### 1.1 INT 的核心特点

- **随流**: 遥测数据附在数据包内部，跟随数据流路径
- **每跳**: 每个网络设备（交换机）都插入自己的状态
- **无探针**: 不需要独立的探针或监控端口
- **实时**: 数据平面向控制面/收集器实时报告
- **精细**: 可以精确到每个包级别的延迟/队列信息

---

## 2. INT 架构

### 2.1 INT 端到端架构

```
INT 完整架构:
=============

+------------------------------------------------------------------+
|                          Source Host                              |
|  +------------+                                                    |
|  | App / VM  | --> [INT Header Insertion] --> [Original Packet]   |
|  +------------+                                                    |
+------------------------------------------------------------------+

+------------------------------------------------------------------+
|                     Network (Switches S1-S4)                     |
|                                                                   |
|  S1 [INT Sink] --> Pipeline --> [Insert INT Metadata] --> Egress |
|    |                                                              |
|    v                                                              |
|  S2 [INT Transit] --> Pipeline --> [Append INT Metadata] --> Egress|
|    |                                                              |
|    v                                                              |
|  S3 [INT Transit] --> Pipeline --> [Append INT Metadata] --> Egress|
|    |                                                              |
|    v                                                              |
|  S4 [INT Transit] --> Pipeline --> [Append INT Metadata] --> Egress|
+------------------------------------------------------------------+

+------------------------------------------------------------------+
|                         Destination Host                           |
|  +--------------+                                                 |
|  | [INT Source] | --> Extract INT --> Forward to Collector       |
|  +--------------+                                                 |
+------------------------------------------------------------------+

+------------------------------------------------------------------+
|                          Collector                                |
|  +------------------+                                             |
|  | Telemetry Server | <-- Aggregated INT Data                     |
|  +------------------+                                             |
+------------------------------------------------------------------+
```

### 2.2 INT Metadata 类型

| Metadata 类型    | 描述                   |
| ---------------- | ---------------------- |
| Switch ID        | 交换机标识             |
| Ingress Port     | 入端口                 |
| Egress Port      | 出端口                 |
| Hop Timestamp    | 时间戳（纳秒/微秒）    |
| Queue Depth      | 队列深度（包数或字节） |
| Queue Occupancy  | 队列占用率 (0-100%)    |
| Congestion ECN   | ECN 拥塞标记           |
| Hop Latency      | 本跳延迟               |
| Processing Delay | 处理延迟               |
| Hop Count        | 跳数                   |
| Flow ID          | 流标识符               |

---

## 3. INT Header 格式

### 3.1 INT Header 结构 (INT over UDP)

INT 通常通过 UDP 隧道传输，Header 结构如下：

```
INT Header over UDP (Metadata Stack):
====================================

UDP Header:
+--------+--------+--------+--------+
|    Source Port    |   Dest Port     |
+--------+--------+--------+--------+
|     Length       |    Checksum      |
+--------+--------+--------+--------+

INT UDP Header:
+----------+----------+----------+----------+
|  Ver(2)  |  Rep(4)  |   C(1)   |   I(1)   |  (1 byte)
+----------+----------+----------+----------+
|       Reserved(4)      |   Max Hop(4)     |  (1 byte)
+----------+----------+----------+----------+
|   Meta Checksum (16)                        |  (2 bytes)
+----------+----------+----------+----------+
|    Instruction Bitmap (32)                 |  (4 bytes)
+----------+----------+----------+----------+

INT Metadata Header (per hop):
+----------+----------+----------+----------+
|    Switch ID (16)    |  Generic Flags(8) |  (3 bytes)
+----------+----------+----------+----------+
|  Ingress Port (32)   |   Egress Port(32)|  (8 bytes)
+----------+----------+----------+----------+
|      Timestamp (48)                      |  (6 bytes)
+----------+----------+----------+----------+
|      Queue Depth (32)                     |  (4 bytes)
+----------+----------+----------+----------+
```

### 3.2 INT Header 定义 (P4)

```c
// INT Header over UDP (UDP Destination Port = 6081)
// See INT spec: https://github.com/p4lang/INT

// INT-MD Header
header int_header_t {
    bit<2>  ver;
    bit<4>  rep;          // Replication factor
    bit<1>  c;            // Copy bit (1 = copy at every hop)
    bit<1>  i;            // INT Insert bit (1 = insert INT)
    bit<4>  reserved;
    bit<4>  max_hop;      // Maximum hop count
    bit<16> total_hop_metadata_len;
    bit<4>  reserved2;
    bit<12> instruction_bitmap;
    bit<16> reserved3;
}

// INT Metadata Header (per hop)
header int_metadata_header_t {
    bit<16> switch_id;
    bit<8>  generic_flags;
    bit<8>  qid;
    bit<32> ingress_port;
    bit<32> egress_port;
    bit<48> hop_timestamp;
    bit<32> queue_depth;
    bit<16> reserved4;
    bit<14> congestion_ecn;
    bit<2>  q_occupancy;
    bit<32> hop_latency;
    bit<32> processing_delay;
    bit<8>  hop_count;
    bit<8>  link_delay;
    bit<16> reserved5;
}

// INT-MD Metadata Stack (variable length)
header int_metadata_stack_t[16] {
    int_metadata_header_t[0],
    int_metadata_header_t[1],
    int_metadata_header_t[2],
    int_metadata_header_t[3],
    int_metadata_header_t[4],
    int_metadata_header_t[5],
    int_metadata_header_t[6],
    int_metadata_header_t[7],
    int_metadata_header_t[8],
    int_metadata_header_t[9],
    int_metadata_header_t[10],
    int_metadata_header_t[11],
    int_metadata_header_t[12],
    int_metadata_header_t[13],
    int_metadata_header_t[14],
    int_metadata_header_t[15]
}
```

---

## 4. INT Parser 与 Deparser

### 4.1 INT Parser 实现

```c
parser IngressParser(packet_in packet,
                    out headers h,
                    inout metadata m,
                    in PSA_ParserInputMetadata_t istd) {

    // 状态机
    state start {
        packet.extract(h.ethernet);
        transition select(h.ethernet.etherType) {
            0x86DD: parse_ipv6;
            0x0800: parse_ipv4;
            default: accept;
        }
    }

    state parse_ipv4 {
        packet.extract(h.ipv4);
        transition select(h.ipv4.protocol) {
            6:   parse_tcp;
            17:  parse_udp;
            default: accept;
        }
    }

    state parse_ipv6 {
        packet.extract(h.ipv6);
        transition select(h.ipv6.nextHdr) {
            6:   parse_tcp;
            17:  parse_udp;
            0:   parse_hop_by_hop;  // 可能携带 INT
            default: accept;
        }
    }

    state parse_udp {
        packet.extract(h.udp);
        transition select(h.udp.dstPort) {
            // INT over UDP: 6081
            6081: parse_int_header;
            default: accept;
        }
    }

    state parse_tcp {
        packet.extract(h.tcp);
        transition accept;
    }

    state parse_hop_by_hop {
        packet.extract(h.hop_by_hop);
        // 检查是否有 INT option
        transition select(h.hop_by_hop.nextHdr) {
            17: parse_udp;  // Hop-by-Hop 之后是 UDP
            default: accept;
        }
    }

    // INT Header 解析
    state parse_int_header {
        packet.extract(h.int_header);

        // 读取 INT Header 了解元数据栈的长度
        m.int_meta_count = h.int_header.max_hop;
        m.int_meta_len = h.int_header.total_hop_metadata_len;

        // 跳转到传输层（TCP/UDP）
        transition select(h.udp.nextHdr) {
            6:   parse_tcp;
            17:  parse_udp;  // 可能是嵌套的 UDP
            default: accept;
        }
    }
}
```

### 4.2 INT Deparser 实现

```c
control IngressDeparser(packet_out packet,
                        inout headers h,
                        in metadata m,
                        in PSA_ingress_output_metadata_t ostd) {

    // INT Metadata 收集器
    Checksum<bit<32>>(HashAlgorithm.crc32) int_meta_checksum;

    apply {
        // INT-MD Header 更新
        if (h.int_header.isValid()) {
            // 更新 hop count
            h.int_header.total_hop_metadata_len =
                (bit<16>)(m.int_meta_count * 4);  // 每跳 4 字节

            // 计算 Checksum
            // INT Meta Checksum 覆盖整个 INT Metadata Stack
        }

        // 发射 Headers (INT 在 UDP Payload 中)
        packet.emit(h.ethernet);
        packet.emit(h.ipv4);

        if (h.int_header.isValid()) {
            packet.emit(h.int_header);
            // 发射 INT Metadata Stack
            packet.emit(h.int_metadata_stack);
        }

        packet.emit(h.tcp);
    }
}
```

---

## 5. INT Metadata 收集

### 5.1 收集 INT Metadata 的 Action

```c
control INTCollector(inout headers h,
                     inout metadata m,
                     in PSA_ingress_input_metadata_t istd,
                     inout PSA_ingress_output_metadata_t ostd) {

    // 获取交换机 ID (通过配置或 Register)
    Register<bit<16>>(1) switch_id_reg;

    // 获取队列深度
    action get_queue_depth(out bit<32> depth) {
        // 从 Traffic Manager 获取队列深度
        // PSA egress_output_metadata 提供入队时的队列深度
        depth = (bit<32>)ostd.enq_depth * 64;  // 转换为字节或包数
    }

    // 获取时间戳
    action get_timestamp(out bit<48> ts) {
        // 使用 PSA_Clock 获取纳秒时间戳
        // 在 Tofino 上: 取 ingress_timestamp
        ts = (bit<48>)istd.ingress_timestamp;
    }

    // 获取 Ingress Port
    action get_ingress_port(out bit<32> port) {
        port = (bit<32>)istd.ingress_port;
    }

    // 获取 Egress Port
    action get_egress_port(out bit<32> port) {
        port = (bit<32>)ostd.egress_port;
    }

    // 收集完整的 Hop Metadata
    action collect_hop_metadata() {
        // 从 PSA Metadata 中获取各字段
        m.current_hop.switch_id = m.local_switch_id;
        m.current_hop.ingress_port = (bit<32>)istd.ingress_port;
        m.current_hop.egress_port = (bit<32>)ostd.egress_port;
        m.current_hop.hop_timestamp = (bit<48>)istd.ingress_timestamp;
        m.current_hop.queue_depth = (bit<32>)ostd.enq_depth;
        m.current_hop.congestion_ecn = (bit<14>)ostd.enq_congestion_ecn;
        m.current_hop.q_occupancy = (bit<2>)0;  // 需要硬件支持

        // 跳数递增
        m.hop_count = m.hop_count + 1;
    }
}
```

### 5.2 INT 处理 Control

```c
control INTProcessing(inout headers h,
                      inout metadata m,
                      in PSA_ingress_input_metadata_t istd,
                      inout PSA_ingress_output_metadata_t ostd) {

    // 判断是否需要 INT 处理
    action check_int_enabled() {
        // 检查 INT Header 是否存在
        if (h.int_header.isValid()) {
            m.int_enabled = true;

            // 检查是否超过 max_hop
            if (m.hop_count >= h.int_header.max_hop) {
                m.int_enabled = false;
            }

            // 检查 Copy bit
            if (h.int_header.c == 0 && m.hop_count > 0) {
                // 不是第一次复制，只在最后一跳收集
                m.int_enabled = false;
            }
        }
    }

    // 收集并插入 INT Metadata
    action insert_int_metadata() {
        if (!h.int_metadata.isValid()) {
            return;
        }

        // 填充当前 hop 的 metadata
        h.int_metadata.setValid();

        // Switch ID (来自配置)
        bit<16> sw_id;
        switch_id_reg.read(sw_id, 0);
        h.int_metadata.switch_id = sw_id;

        // Ingress Port
        h.int_metadata.ingress_port = (bit<32>)istd.ingress_port;

        // Egress Port
        h.int_metadata.egress_port = (bit<32>)ostd.egress_port;

        // Timestamp
        h.int_metadata.hop_timestamp = (bit<48>)istd.ingress_timestamp;

        // Queue Depth (以包数为单位)
        h.int_metadata.queue_depth = (bit<32>)ostd.enq_depth;

        // ECN
        h.int_metadata.congestion_ecn =
            (bit<14>)(ostd.enq_congestion_ecn & 0x03);

        // Hop Latency (ingress 到 egress 的时间差)
        bit<32> latency = (bit<32>)ostd.egress_timestamp
                        - (bit<32>)istd.ingress_timestamp;
        h.int_metadata.hop_latency = latency;
    }

    // INT 表
    table int_table {
        key = {
            // 对所有启用了 INT 的流启用
            h.int_header.isValid(): exact;
            h.ipv4.srcAddr:         exact;
            h.ipv4.dstAddr:         exact;
        }
        actions = {
            insert_int_metadata;
            NoAction;
        }
        default_action = NoAction;
    }

    apply {
        check_int_enabled();
        if (m.int_enabled) {
            int_table.apply();
        }
    }
}
```

---

## 6. INT 的两种模式

### 6.1 Hop-by-Hop INT (Per-Hop Telemetry)

每个交换机都插入自己的 Metadata：

```
Hop-by-Hop INT:
===============

Packet: [Eth][IP][UDP][INT-Hdr][Hop1-Meta][Hop2-Meta][Hop3-Meta][TCP][Data]

Hop1: Switch-1
  + Ingress: Port 1
  + Egress: Port 5
  + Timestamp: 1234567890
  + Queue Depth: 10
  + Hop Latency: 5us

Hop2: Switch-2
  + Ingress: Port 5
  + Egress: Port 12
  + Timestamp: 1234567900  (10us later)
  + Queue Depth: 45         (队列拥塞!)
  + Hop Latency: 50us       (延迟增加)
  + ECN: CE                  (拥塞标记)

Hop3: Switch-3
  + Ingress: Port 12
  + Egress: Port 3
  + Timestamp: 1234567950
  + Queue Depth: 5
  + Hop Latency: 3us
```

### 6.2 End-to-End INT (Summary Telemetry)

只在源和宿插入/收集 Metadata：

```
End-to-End INT:
===============

源端 (Sender):
  + Insert INT Header
  + Set total_hop = 3
  + Set instruction bitmap = ingress_ts | egress_ts | queue_depth
  + Record own ingress timestamp

中间交换机:
  + Transit (不做 INT 处理，或者只做 TTL 递减)
  + 只转发，不插入 Metadata

宿端 (Receiver):
  + Extract INT Header and Metadata
  + Calculate end-to-end latency
  + Forward INT data to Collector
```

---

## 7. INT 指令位图 (Instruction Bitmap)

### 7.1 指令位定义

```c
// INT Instruction Bitmap (12 bits)
enum bit<12> INT_Instructions {
    INT_INGRESS_PORT_ID      = 0x001,  // 1: Ingress Port ID
    INT_SWITCH_ID            = 0x002,  // 2: Switch ID
    INT_HOP_METADATA_UF      = 0x004,  // 4: Hop Metadata (all fields)
    INT_QUEUE_DEPTH           = 0x008,  // 8: Queue Depth
    INT_INGRESS_TIMESTAMP     = 0x010,  // 16: Ingress Timestamp
    INT_EGRESS_TIMESTAMP      = 0x020,  // 32: Egress Timestamp
    INT_LOSS_METADATA         = 0x040,  // 64: Loss/Latency Metadata
    INT_ECN_METADATA          = 0x080,  // 128: ECN Metadata
    INT_SWITCH_LOCAL          = 0x100,  // 256: Switch-Local Metadata
    INT_TRANSPORT_METADATA    = 0x200,  // 512: TCP/UDP Port Info
    INT_CACHED_SWITCH         = 0x400,  // 1024: Cached Switch ID
    INT_ALL                    = 0xFFF   // All Instructions
};

// 配置 INT 指令位图
action set_int_instructions(bit<12> bitmap) {
    h.int_header.instruction_bitmap = bitmap;
}
```

---

## 8. INT 与 P4Runtime 集成

### 8.1 INT 配置通过 P4Runtime

```python
#!/usr/bin/env python3
"""通过 P4Runtime 配置 INT"""

from p4.v1 import p4_pb2
from p4.runtime import P4RuntimeClient

class INTController:
    def __init__(self, addr="192.168.1.1:50051"):
        self.client = P4RuntimeClient(addr)

    def enable_int_for_flow(self, src_ip, dst_ip,
                           src_port=1234, dst_port=80):
        """为特定流启用 INT"""

        # 1. 配置 INT 表项
        int_table_entry = p4_pb2.TableEntry()
        int_table_entry.table_id = self.get_table_id("int_table")

        # Match: 匹配特定流
        mf = int_table_entry.match.add()
        mf.field_id = 1  # ipv4.srcAddr
        mf.lpm.pfx = src_ip
        mf.lpm.pfx_len = 32

        mf = int_table_entry.match.add()
        mf.field_id = 2  # ipv4.dstAddr
        mf.lpm.pfx = dst_ip
        mf.lpm.pfx_len = 32

        # Action: 启用 INT 并设置指令
        action = int_table_entry.action.action
        action.action_id = self.get_action_id("int_enable")

        # 设置 INT 参数
        param = action.params.add()
        param.param_id = 1
        param.value = (0x001 | 0x008 | 0x010).to_bytes(2, 'big')
        # INT_INGRESS_PORT_ID | INT_QUEUE_DEPTH | INT_INGRESS_TIMESTAMP

        self.client.WriteTableEntry(int_table_entry)
        print(f"INT enabled for {src_ip} -> {dst_ip}")

    def read_int_data(self):
        """从 INT Metadata 中读取遥测数据"""
        # 使用 Digest 接收 INT 数据
        for digest in self.client.DigestRead():
            self.process_int_digest(digest)

    def process_int_digest(self, digest):
        """处理接收到的 INT 数据"""
        data = digest.digest.data

        # 解析 INT Metadata
        switch_id = int.from_bytes(data[0:2], 'big')
        ingress_port = int.from_bytes(data[2:6], 'big')
        egress_port = int.from_bytes(data[6:10], 'big')
        timestamp = int.from_bytes(data[10:16], 'big')
        queue_depth = int.from_bytes(data[16:20], 'big')

        print(f"Switch {switch_id}: "
              f"Ingress={ingress_port}, Egress={egress_port}, "
              f"TS={timestamp}, QueueDepth={queue_depth}")

        # 计算延迟
        # 发送到遥测分析系统
```

---

## 9. Tofino 上的 INT 实现

### 9.1 Tofino INT 支持

Intel Tofino 提供了**硬件级 INT 支持**：

```
Tofino INT 架构:
================

Tofino 支持两种 INT 模式:

1. Ingress-time INT:
   - 在 Ingress Pipeline 中收集 Metadata
   - 包括 Ingress Port, Ingress Timestamp, Queue Depth

2. Egress-time INT:
   - 在 Egress Pipeline 中补充 Metadata
   - 包括 Egress Port, Egress Timestamp, Hop Latency

Tofino Parser 支持 INT Header 的递归解析:
  - 识别 INT Header (UDP 6081)
  - 提取 instruction_bitmap
  - 根据 bitmap 确定需要收集的 Metadata
  - 由硬件自动插入 Metadata，不需要软件参与
```

### 9.2 Tofino INT P4 程序

```c
// Tofino INT 示例 (使用 TNA 架构)
#include <tna.p4>

// INT Header 定义
header int_md_header_t {
    bit<16> switch_id;
    bit<8>  qid;
    bit<32> ingress_port;
    bit<32> egress_port;
    bit<48> hop_timestamp;
    bit<32> queue_depth;
}

header int_shim_t {
    bit<4>  type;
    bit<4>  reserved;
    bit<8>  len;           // INT-MD Header 长度 (4 字节为单位)
    bit<4>  reserved2;
    bit<4>  dscp;
}

// Tofino Ingress Pipeline
control Ingress(
    inout header_t hdr,
    inout metadata_t met,
    in ingress_intrinsic_metadata_t ig_intr_md,
    inout ingress_intrinsic_metadata_from_parser_t ig_prsr_md,
    inout ingress_intrinsic_metadata_for_deparser_t ig_dprsr_md,
    inout ingress_intrinsic_metadata_for_tm_t ig_tm_md) {

    // INT 启用检测
    action int_collect() {
        // 设置 TM 动作：复制一份到 INT 出口
        ig_tm_md.copy_to_cpu = false;

        // 设置 INT 相关 Metadata
        // Tofino 硬件会在相应阶段自动填充这些字段
    }

    // 基于 ACL 启用 INT
    table int_enable {
        key = {
            hdr.ipv4.srcAddr: lpm;
            hdr.ipv4.dstAddr: lpm;
        }
        actions = {
            int_collect;
            NoAction;
        }
        default_action = NoAction;
    }

    apply {
        // 启用 INT 收集
        int_enable.apply();
    }
}

// Tofino Egress Pipeline
control Egress(
    inout header_t hdr,
    inout metadata_t met,
    in egress_intrinsic_metadata_t eg_intr_md,
    inout egress_intrinsic_metadata_for_deparser_t eg_dprsr_md,
    inout egress_intrinsic_metadata_for_output_queue_t eg_qe_md) {

    // INT Metadata 插入
    action int_insert() {
        // 设置 INT Shim Header
        hdr.int_shim.setValid();
        hdr.int_shim.type = 1;
        hdr.int_shim.len = 4;  // 4 * 4 = 16 bytes per hop metadata

        // 设置 INT MD Header
        hdr.int_md.setValid();
        hdr.int_md.switch_id = (bit<16>)eg_intr_md.switch_id;
        hdr.int_md.ingress_port = (bit<32>)ig_intr_md.ingress_port;
        hdr.int_md.egress_port = (bit<32>)eg_intr_md.egress_port;
        hdr.int_md.hop_timestamp = (bit<48>)eg_intr_md.enq_timestamp;
        hdr.int_md.queue_depth = (bit<32>)eg_qe_md.avg_queue_depth;

        // 更新 Checksum
        // ...
    }

    apply {
        // 检查是否为 INT 包
        if (hdr.int_shim.isValid()) {
            int_insert();
        }
    }
}
```

---

## 10. 小结

本章介绍了 **INT (In-band Network Telemetry)** 随流遥测技术：

| 概念                   | 描述                                                  |
| ---------------------- | ----------------------------------------------------- |
| **INT**                | In-band Network Telemetry，随数据包携带的实时遥测数据 |
| **INT Header**         | 位于 UDP 6081 或 Hop-by-Hop Option 中                 |
| **Instruction Bitmap** | 指定需要收集哪些 Metadata                             |
| **Hop-by-Hop INT**     | 每跳插入/追加 Metadata                                |
| **End-to-End INT**     | 仅源/宿插入/收集 Metadata                             |
| **INT Collector**      | 接收并聚合 INT 数据                                   |

INT 是 P4 在**网络可观测性**领域最重要的应用之一，它让网络运维人员能够精确地看到每个数据包在网络中的"旅程"——包括每跳的延迟、队列深度、ECN 状态等关键指标。
