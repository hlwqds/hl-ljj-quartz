---
title: "P4 深度探索 (十六)：Extern 对象——Hash/Checksum/Register/Queue/Digest"
date: 2026-04-14
tags: [p4, series, extern, hash, register, queue, digest, p4-16, psa]
description: "P4 Extern 对象深度解析——Hash 哈希计算、Checksum 校验和、Register 状态存储、Queue 队列管理、Digest 数据摘要、PSA 中的各种 Extern 对象及其在数据平面中的使用方法"
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
> 16. **第十六章：Extern 对象——Hash/Checksum/Register/Queue/Digest**

---

## 1. 概述：Extern 机制

**Extern（扩展对象）** 是 P4 架构模型（PSA/TNA）中定义的数据平面功能模块，它们不是 P4 语言核心的一部分，而是由**架构规范**声明和定义。P4 程序通过调用这些 Extern 对象来完成哈希计算、状态存储、队列管理等任务。

```
P4 程序层级关系:
====================

  P4 Program (用户代码)
         |
         +-- Header definitions
         +-- Parser
         +-- Control (Match-Action)
         +-- Table definitions
         |
         v
  Architecture (PSA/TNA)
         |
         +-- Extern: Hash, Checksum, Register, Counter, Meter, Queue, Digest
         +-- Packet Buffer / Traffic Manager
         +-- Ingress / Egress Pipeline
         |
         v
  Hardware / Software Target (Tofino / BMv2)
```

### 1.1 PSA 中的主要 Extern

| Extern   | 用途                             |
| -------- | -------------------------------- |
| Hash     | 哈希计算 (CRC, random, identity) |
| Checksum | Checksum 验证与重新计算          |
| Register | 通用读写状态存储                 |
| Counter  | 只增计数器                       |
| Gauge    | 可增可减计量器                   |
| Meter    | 流量速率计量与着色               |
| Queue    | 队列管理与调度                   |
| Digest   | 向控制面发送数据包摘要           |

---

## 2. Hash 详解

### 2.1 Hash 算法

P4 的 `Hash` extern 支持多种哈希算法：

```c
// Hash 算法枚举
enum HashAlgorithm {
    crc8,       // CRC-8
    crc16,      // CRC-16 (IPv4 checksum)
    crc32,      // CRC-32 (Ethernet FCS)
    crc32custom, // 自定义 CRC-32 多项式
    identity,   // 恒等函数
    random      // 伪随机
}
```

### 2.2 Hash 对象定义与使用

```c
// 1. 定义 Hash 对象
#include <core.p4>
#include <psa.p4>

// 定义哈希输出类型
typedef bit<32> HashResult;

// 实例化 Hash
Hash<HashResult>(HashAlgorithm_t.crc32) hash_algo;

// 在 Action 中使用
control MyIngress(inout headers h, inout metadata m) {

    action compute_flow_hash() {
        // 计算流哈希：基于五元组
        hash(
            m.flow_hash,
            HashAlgorithm.crc32,
            (HashAlgorithm)0,   // 初始值
            {
                h.ipv4.srcAddr,
                h.ipv4.dstAddr,
                h.tcp.srcPort,
                h.tcp.dstPort,
                h.ipv4.protocol
            }
        );
    }

    apply { compute_flow_hash(); }
}
```

### 2.3 哈希算法的选择

不同哈希算法适用于不同场景：

```c
// CRC32：适用于流负载均衡
Hash<bit<32>>(HashAlgorithm.crc32) flow_hash;

// identity：适用于精确匹配保持
Hash<bit<32>>(HashAlgorithm.identity) exact_hash;

// random：适用于随机抽样
Hash<bit<32>>(HashAlgorithm.random) random_hash;

// ECMP / 负载均衡示例
control ECMPControl(inout headers h, inout metadata m) {

    @noWarn("unused") -1;

    action set_ecmp_group(bit<16> ecmp_group_id, bit<8> num_members) {
        // 使用哈希选择 ECMP 成员
        bit<16> hash_value;
        hash(
            hash_value,
            HashAlgorithm.crc16,
            (bit<16>)0,
            {
                h.ipv4.srcAddr,
                h.ipv4.dstAddr,
                h.tcp.srcPort,
                h.tcp.dstPort
            }
        );

        // 取模得到成员索引
        bit<8> member_idx = (bit<8>)(hash_value % num_members);
        m.ecmp_output_port = (bit<9>)(ecmp_group_id * 256 + member_idx);
    }

    table ecmp_group_table {
        key = {
            h.ipv4.dstAddr: lpm;  // 最长前缀匹配
        }
        actions = {
            set_ecmp_group;
            NoAction;
        }
        default_action = NoAction;
    }

    apply { ecmp_group_table.apply(); }
}
```

### 2.4 哈希的 ECMP 应用

```
ECMP 哈希选择流程:
====================

Packet (src=10.0.0.1, dst=192.168.1.100, sport=12345, dport=80)
         |
         v
    [CRC16 Hash] --> 0x9F3A (例如)
         |
         v
    hash_value % num_members = 0x9F3A % 4 = 2
         |
         v
    选择 ECMP 成员 2
         |
         v
    从 Port 列表中选出对应出端口
```

---

## 3. Register 详解

### 3.1 Register 定义与读写

Register 是通用读写存储，每个 Register 有一个固定大小的数组：

```c
// 定义 Register
extern Register<W> {
    Register(bit<32> size);                  // 指定大小
    Register(bit<32> size, W initial_data);   // 指定大小和初始值

    @noSideEffects void read (out W result, in bit<32> index);
    void write(in bit<32> index, in W value);
}
```

### 3.2 Register 使用示例

```c
// 定义一个 1024 项的 Register，每项 32 bits
Register<bit<32>>(1024) flow_byte_count;

control MyIngress(inout headers h, inout metadata m) {

    // 读取当前字节计数
    action update_flow_counter() {
        bit<32> current_count;
        flow_byte_count.read(current_count, m.flow_id);

        // 累加当前包的字节数
        current_count = current_count + (bit<32>)h.ipv4.totalLen;

        // 写回
        flow_byte_count.write(m.flow_id, current_count);
    }

    // 检测 SYN Flood: 统计 SYN 包数量
    Register<bit<16>>(65536) syn_counter;

    action count_syn() {
        bit<16> syn_count;
        syn_counter.read(syn_count, h.tcp.srcPort);

        if (syn_count < 0xFFFF) {
            syn_counter.write(h.tcp.srcPort, syn_count + 1);
        }
    }

    apply {
        if (h.tcp.isValid() && h.tcp.syn == 1 && h.tcp.ack == 0) {
            count_syn();
        }
        update_flow_counter();
    }
}
```

### 3.3 Register 数组初始化

```c
// 带初始值的 Register
Register<bit<48>>(256, 0) last_flow_time;

action record_timestamp() {
    bit<48> current_time;
    // 读取当前时间戳（假设在 metadata 中传入）
    last_flow_time.write(m.flow_id, m.timestamp);
}

action check_rate_limit() {
    bit<48> last_time;
    last_flow_time.read(last_time, m.flow_id);

    // 检查时间间隔
    if (m.timestamp - last_time < 1000) {
        // 太频繁，限速
        ingress_drop();
    } else {
        last_flow_time.write(m.flow_id, m.timestamp);
    }
}
```

---

## 4. Queue 详解

### 4.1 Queue Extern

Queue 是 PSA 中用于**队列管理**的 Extern：

```c
// Queue 定义
extern Queue {
    // 构造函数
    Queue(bit<32> size);

    // 入队
    void enq(in bit<32> index);

    // 出队
    void deq(in bit<32> index);

    // 查询队列长度
    void size(out bit<32> result, in bit<32> index);
}
```

### 4.2 Queue 使用场景

```c
control TrafficManager(inout headers h, inout metadata m) {

    // 定义多个队列
    Queue(1024) q0;
    Queue(1024) q1;
    Queue(1024) q2;
    Queue(1024) q3;

    // 队列调度：根据 DSCP 选择队列
    action enqueue_packet() {
        bit<8> dscp = h.ipv4.diffserv;

        if (dscp >= 46) {       // EF (Expedited Forwarding)
            q3.enq(0);          // 高优先级队列
        } else if (dscp >= 34) { // AF (Assured Forwarding)
            q2.enq(0);          // 中优先级队列
        } else if (dscp >= 26) {
            q1.enq(0);
        } else {
            q0.enq(0);          // Best Effort
        }
    }

    // 队列长度检测（用于拥塞控制）
    action check_queue_depth() {
        bit<32> q0_size;
        q0.size(q0_size, 0);

        if (q0_size > 800) {
            // 队列拥塞，标记 ECN
            h.ipv4.ecn = 3;
        }
    }

    apply {
        enqueue_packet();
        check_queue_depth();
    }
}
```

### 4.3 PSA 中的 Traffic Manager 队列

PSA 的 Traffic Manager 提供了更完整的队列管理：

```
PSA Traffic Manager 队列层次:
==============================

Port Level
    |
    +-- Queue 0 (Highest Priority)
    +-- Queue 1
    +-- Queue 2
    +-- Queue 3 (Lowest Priority)
    |
    v
Scheduling
    |
    +-- Priority Scheduling (严格优先级)
    +-- Deficit Round Robin (DRR)
    +-- Weighted Fair Queuing (WFQ)
```

---

## 5. Digest 详解

### 5.1 Digest 机制

Digest 用于从数据平面向**控制平面**发送数据包摘要信息：

```c
// Digest 定义
extern Digest<T> {
    Digest();                     // 默认构造函数
    Digest(bit<32> max_size);     // 指定最大缓冲大小

    // 发射摘要数据
    void emit(in T data);
}
```

### 5.2 Digest 使用示例

```c
// 定义 Digest 数据类型
struct digest_data_t {
    bit<48> src_mac;
    bit<48> dst_mac;
    bit<16> ether_type;
    bit<32> src_addr;
    bit<32> dst_addr;
    bit<8> protocol;
    bit<128> ipv6_src;
    bit<128> ipv6_dst;
}

// 实例化 Digest
Digest<digest_data_t>() digest_flow_info;

// 在 Ingress 中使用
control MyIngress(inout headers h, inout metadata m) {

    // 检测新流并报告给控制面
    action report_new_flow() {
        digest_data_t data;
        if (h.ipv4.isValid()) {
            data.src_addr = h.ipv4.srcAddr;
            data.dst_addr = h.ipv4.dstAddr;
            data.protocol = h.ipv4.protocol;
        } else if (h.ipv6.isValid()) {
            data.ipv6_src = h.ipv6.srcAddr;
            data.ipv6_dst = h.ipv6.dstAddr;
        }
        data.src_mac = h.ethernet.srcAddr;
        data.dst_mac = h.ethernet.dstAddr;
        data.ether_type = h.ethernet.etherType;

        digest_flow_info.emit(data);
    }

    table new_flow_table {
        key = {
            h.ipv4.srcAddr: exact;
            h.ipv4.dstAddr: exact;
            h.tcp.srcPort: exact;
            h.tcp.dstPort: exact;
        }
        actions = {
            NoAction;
            report_new_flow;
        }
        default_action = report_new_flow();
    }

    apply { new_flow_table.apply(); }
}
```

### 5.3 P4Runtime 中的 Digest 接收

在 Python 控制面接收 Digest：

```python
import grpc
from p4.v1 import p4_pb2
from p4.runtime import P4RuntimeClient

class FlowMonitor:
    def __init__(self, addr="192.168.1.1:50051"):
        self.client = P4RuntimeClient(addr)

    def recv_flow_digest(self):
        # 接收 Digest 数据
        while True:
            for digest in self.client.DigestRead():
                data = digest.digest.data

                # 解析字段
                print(f"New Flow: {data[3].struct.data[0].bitstring} -> "
                      f"{data[3].struct.data[1].bitstring}")
```

---

## 6. 其他 Extern 对象

### 6.1 DirectResource

有些 Extern 支持 **Direct（直接绑定）** 模式，直接关联到特定的 Table：

```c
// Direct Meter: 直接绑定到 Table 的 Meter
 @metadata("@table_annotation")
 DirectMeter<bit<2>>(MeterType.PACKETS) flow_meter;

// Direct Counter: 直接绑定到 Table 的 Counter
DirectCounter<bit<64>>(CounterType.Bytes) flow_bytes_counter;

table flow_table {
    key = {
        h.ipv4.srcAddr: exact;
        h.ipv4.dstAddr: exact;
    }
    actions = {
        allow;
        drop;
    }

    // 直接关联 Meter 和 Counter
    meters = { flow_meter: MeterDirection.BOTH };
    counters = { flow_bytes_counter: CounterType.BYTES };
}
```

### 6.2 Chronometer (时间测量)

```c
// PSA 支持 Chronometer 用于时间戳测量
extern Chronometer {
    Chronometer(Clock clock_id);

    // 获取当前时间
    void time_get(out bit<64> timestamp, in Clock clock_id);
}

// 使用
action measure_latency() {
    bit<64> current_time;
    chronometer.time_get(current_time, PSA_Clock.INGRESS_TIMESTAMP);

    m.ingress_time = current_time;
}
```

---

## 7. PSA 中的 Extern 资源布局

### 7.1 资源分配

Tofino 等硬件的 Extern 资源是**物理受限**的：

```
Tofino 芯片资源布局 (以 32 端口型号为例):
==========================================

Hash Units:      ~16 个 (所有 stage 共享)
Checksum Units:  ~8 个
Counters:        ~64K 个 (直接或间接)
Meters:          ~64K 个 (直接或间接)
Registers:       ~8MB SRAM
TCAM:            ~8MB (用于 ternary match)
```

### 7.2 资源预算示例

```c
// P4 程序中的资源声明（架构相关注释）
/*
+--------------------------------------------------+
| Resource Budget for MyProgram                    |
+--------------------------------------------------+
| Table: acl_table                                 |
|   - TCAM entries: 8192 (max)                    |
|   - Direct counters: 8192                       |
|                                                  |
| Table: routing_table                             |
|   - SRAM entries: 16384 (LPM)                    |
|   - Direct meters: 4096                         |
|                                                  |
| Register: flow_cache                             |
|   - Size: 65536 entries × 32 bits = 256KB      |
|                                                  |
| Hash: ecmp_hash                                  |
|   - Algorithm: CRC16                            |
+--------------------------------------------------+
*/

// 编译器会检查资源使用是否超限
// 超出限制时会报错
```

---

## 8. 实战：完整的 ACL + Meter + Counter 程序

```c
#include <core.p4>
#include <psa.p4>

// ================== Header 定义 ==================
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

struct headers {
    ethernet_t ethernet;
    ipv4_t     ipv4;
    tcp_t      tcp;
}

struct metadata {
    bit<32> flow_id;
    bit<2>  meter_result;
    bit<48> packet_count;
}

// ================== Parser ==================
parser IngressParser(packet_in buffer,
                     out headers h,
                     inout metadata m,
                     in PSA_ParserInputMetadata_t istd) {

    state start {
        buffer.extract(h.ethernet);
        transition select(h.ethernet.etherType) {
            0x0800: parse_ipv4;
            default: accept;
        }
    }

    state parse_ipv4 {
        buffer.extract(h.ipv4);
        transition select(h.ipv4.protocol) {
            6: parse_tcp;
            default: accept;
        }
    }

    state parse_tcp {
        buffer.extract(h.tcp);
        transition accept;
    }
}

// ================== Control ==================
control Ingress(inout headers h,
                inout metadata m,
                in    PSA_ingress_input_metadata_t  istd,
                inout PSA_ingress_output_metadata_t ostd) {

    // ---- Extern 对象实例化 ----

    // 直接 Meter（绑定 ACL Table）
    DirectMeter<bit<2>>(MeterType.BYTES) acl_meter;

    // 计数器
    DirectCounter<bit<64>>(CounterType.PACKETS_AND_BYTES) acl_counter;

    // Hash
    Hash<bit<32>>(HashAlgorithm.crc32) flow_hash;

    // Register
    Register<bit<64>>(65536) flow_packets;

    // ---- Actions ----

    action send_to_port(bit<9> port) {
        acl_counter.count();
        send_to_port(port);
    }

    action drop() {
        acl_counter.count();
        drop();
    }

    action set_rate_limit() {
        // Meter 着色
        acl_meter.execute_meter((PSA_MeterColor_t)0, m.flow_id, m.meter_result);

        if (m.meter_result == 2) {  // RED - 超过速率限制
            drop();
        }
    }

    // ---- Tables ----

    table acl_table {
        key = {
            h.ipv4.srcAddr:   ternary @priority(10);
            h.ipv4.dstAddr:   ternary @priority(9);
            h.tcp.srcPort:    ternary @priority(8);
            h.tcp.dstPort:    ternary @priority(7);
            h.tcp.flags:      ternary @priority(6);
        }
        actions = {
            send_to_port;
            drop;
            set_rate_limit;
        }

        default_action = set_rate_limit();

        // 直接关联 meter 和 counter
        meters = { acl_meter: PSA_MeterDirection.BOTH };
        counters = { acl_counter: PSA_CounterType.PACKETS_AND_BYTES };
    }

    // 流缓存表
    table flow_cache_table {
        key = {
            h.ipv4.srcAddr: exact;
            h.ipv4.dstAddr: exact;
            h.tcp.srcPort:  exact;
            h.tcp.dstPort:  exact;
        }
        actions = {
            NoAction;
        }
        default_action = NoAction;
    }

    apply {
        // 计算 Flow ID
        flow_hash.apply(
            m.flow_id,
            HashAlgorithm.crc32,
            (bit<32>)0,
            {
                h.ipv4.srcAddr,
                h.ipv4.dstAddr,
                h.tcp.srcPort,
                h.tcp.dstPort
            }
        );

        // 更新流包计数
        bit<64> pkt_count;
        flow_packets.read(pkt_count, m.flow_id);
        flow_packets.write(m.flow_id, pkt_count + 1);

        // 应用 ACL
        acl_table.apply();
    }
}

// ================== Deparser ==================
control IngressDeparser(packet_out packet,
                        inout headers h,
                        in metadata m,
                        in PSA_ingress_output_metadata_t ostd) {
    apply {
        packet.emit(h.ethernet);
        packet.emit(h.ipv4);
        packet.emit(h.tcp);
    }
}

// ================== PSA Main ==================
PSA_Ingress(
    IngressParser(),
    Ingress(),
    IngressDeparser()
) main;
```

---

## 9. 小结

本章介绍了 P4 PSA 架构中的各种 **Extern 对象**：

| Extern   | 类型     | 主要用途                                 |
| -------- | -------- | ---------------------------------------- |
| Hash     | 计算     | 流哈希、ECMP 负载均衡、Flow ID           |
| Checksum | 计算     | IPv4/TCP/UDP Checksum 验证和重新计算     |
| Register | 状态     | 通用读写存储、会话状态、流量统计         |
| Counter  | 状态     | 只增计数、PKT/Byte 统计                  |
| Gauge    | 状态     | 可增可减计量、队列深度                   |
| Meter    | 流量管理 | 速率限制、双速率三色算法 (RFC 2697/2698) |
| Queue    | 流量管理 | 队列缓冲、QoS 调度                       |
| Digest   | 遥测     | 数据平面到控制平面的数据报告             |

理解这些 Extern 对象的**资源约束**和**性能特性**，对于设计高效的数据平面程序至关重要。
