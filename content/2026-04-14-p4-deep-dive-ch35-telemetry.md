---
title: "P4 深度探索 (三十五)：P4 网络测量编程——sFlow/NetFlow/IPFIX、Telemetry 导出、INT 随流遥测"
date: 2026-04-14
tags: [p4, series, telemetry, sflow, netflow, ipfix, int, monitoring, analytics, p4-16]
description: "P4 网络测量与遥测深度解析——sFlow/NetFlow/IPFIX 导出架构、Flow 统计与会话分析、INT (In-band Network Telemetry) 随流遥测、元数据插入与收集、P4 Telemetry 实战"
---

> [!info] P4 深度探索系列
> 0. [[2026-04-14-p4-deep-dive-series-index|全栈学习路径总览]]
> 1. [[2026-04-14-p4-deep-dive-ch1-p4-overview|第一章：P4 概述——诞生背景与协议无关包处理]]
> 2. [[2026-04-14-p4-deep-dive-ch2-p4-architecture|第二章：P4 架构模型——PSA/V1Model、Ingress/Egress]]
> 3. [[2026-04-14-p4-deep-dive-ch3-p4-vs-ebpf|第三章：P4 vs eBPF——适用场景与硬件/软件对比]]
> ...
> 30. [[2026-04-14-p4-deep-dive-ch30-p4-control-plane-advanced|第三十章：P4 控制面高级主题]]
> 31. [[2026-04-14-p4-deep-dive-ch31-basic-routing|第三十一章：P4 基础路由编程]]
> 32. [[2026-04-14-p4-deep-dive-ch32-access-list|第三十二章：P4 ACL 编程]]
> 33. [[2026-04-14-p4-deep-dive-ch33-vlan-vxlan|第三十三章：P4 VLAN/VXLAN 编程]]
> 34. [[2026-04-14-p4-deep-dive-ch34-load-balancer|第三十四章：P4 负载均衡编程]]
> 35. **第三十五章：P4 网络测量编程——sFlow/NetFlow/IPFIX、Telemetry 导出、INT 随流遥测**

---

## 1. 概述：网络测量与遥测

**网络测量 (Telemetry)** 是网络可观测性的基础，用于：

- **流量分析**：了解流量模式、TOP TALKER
- **安全检测**：DDoS 攻击、异常流量检测
- **性能监控**：延迟、丢包、带宽利用率
- **计费**：流量计费、SLA 验证

```
网络测量架构:
=============

  +--------+     +--------+     +--------+
  | Switch | --> |  IPFIX | --> | Collector|
  |  (P4)  |     | Agent  |     |          |
  +--------+     +--------+     +--------+
       |                               |
       | Flow Records / Packets        | Analysis
       v                               v
  +--------+                      +--------+
  | Memory |                      |  UI    |
  | (HW)   |                      |Dashboard|
  +--------+                      +--------+
```

### 1.1 测量技术对比

| 技术 | 类型 | 粒度 | 开销 | 用途 |
|------|------|------|------|------|
| **sFlow** | 采样 | Packet | 低 | 流量分析 |
| **NetFlow** | 聚合 | Flow | 中 | 流量统计 |
| **IPFIX** | 聚合 | Flow | 中 | 标准格式 |
| **INT** | 随流 | Packet | 高 | 精确诊断 |

---

## 2. sFlow 采样

### 2.1 sFlow 原理

**sFlow** (Sampling Flow) 基于**随机采样**，每个包有 1/N 的概率被采样：

```
sFlow 采样:
===========

  流量: [pkt][pkt][pkt][pkt][pkt][pkt][pkt][pkt]...
                  |
                  | 1/N 采样概率
                  v
  样本:      [pkt]                        [pkt]

  sFlow Packet (mirrored to collector):
  +---------------------+---------------------+
  | sFlow Header (68B) | Original Packet    |
  | - Version           | (truncated to 128B) |
  | - Sequence Number   |                     |
  | -采样设备信息        |                     |
  | - Flow Sample       |                     |
  +---------------------+---------------------+
```

### 2.2 P4 sFlow 实现

```c
// sFlow 采样元数据
struct sflow_metadata_t {
    bit<32> sflow_sample_pool;      // 采样计数器
    bit<32> sflow_sample_threshold; // 采样阈值 (例如 1000)
    bool    sflow_sampled;          // 是否被采样
    bit<32> sflow_tunnel_id;        // 采样隧道 ID
}

// sFlow 采样表
table sflow_sample_table {
    key = {
        // 可以基于特定条件触发采样
        // 例如: ACL log, 异常流量
    }
    actions = {
        enable_sflow;
        disable_sflow;
    }
}

// sFlow 采样决策
action sflow_decision() {
    // 伪随机采样: hash(src_ip) % threshold == 0 时采样
    hash(
        meta.sflow_hash,
        HashAlgorithm.crc32,
        0,
        {
            hdr.ipv4.srcAddr,
            hdr.ipv4.dstAddr,
            sm.ingress_port
        },
        1024  // 采样率: 1/1024
    );

    // 如果 hash 结果在阈值内，标记为采样
    meta.sflow_sampled = (meta.sflow_hash < sflow_rate);
}

// sFlow 封装
action sflow_mirror_to_collector() {
    // 创建 sFlow 采样包副本
    // 副本发送到 sFlow collector 端口
    clone_preserving_field_list(
        CloneType.I2E,
        SFLOW_MIRROR_SESSION,
        SFLOW_FIELD_LIST
    );
}
```

### 2.3 sFlow Collector 端

```
sFlow Collector 接收到的数据:
============================

1. Flow Sample:
   - 采样时间戳
   - 源/目的 MAC, IP, Port
   - 协议
   - 包大小
   - 采样接口

2. Counter Sample:
   - 接口计数器 (ifInOctets, ifOutOctets)
   - CPU/内存利用率
   - 队列长度

Collector 聚合分析:
   - TOP N 流
   - 流量矩阵
   - 协议分布
```

---

## 3. NetFlow/IPFIX

### 3.1 NetFlow vs IPFIX

| 特性 | NetFlow v5/v9 | IPFIX |
|------|---------------|-------|
| **标准化** | Cisco 私有 | IETF 6053 |
| **字段数** | 固定 (v5) / 灵活 (v9) | 灵活 |
| **模板** | FlowSet | Template + Data Set |
| **传输** | UDP | UDP/TCP/SCTP |
| **扩展** | 有限 | 完全可扩展 |

### 3.2 Flow 记录结构

```c
// NetFlow v9/IPFIX Flow 记录
struct netflow_record_t {
    // 键字段 (Key Fields)
    bit<32> srcAddr;           // 源 IP
    bit<32> dstAddr;           // 目标 IP
    bit<8>  protocol;          // 协议 (TCP/UDP/ICMP)
    bit<16> srcPort;           // 源端口
    bit<16> dstPort;           // 目标端口
    bit<8>  tos;                // IP TOS/DSCP
    bit<8>  tcp_flags;         // TCP 标志
    bit<12> srcAs;              // 源 AS 号
    bit<12> dstAs;              // 目标 AS 号

    // 计数字段
    bit<32> pkts;              // 包数量
    bit<32> octets;            // 字节数
    bit<32> first_switched;   // 流起始时间
    bit<32> last_switched;     // 流结束时间

    // 接口
    bit<16> input_iface;       // 入接口
    bit<16> output_iface;      // 出接口
}
```

### 3.3 P4 NetFlow/IPFIX 实现

```c
// NetFlow Flow Cache
// 使用 Direct Counter 统计每个 Flow

direct_counter flow_counter32) with {
    table ipv4_flow_table;
}

direct_counter flow_byte_counter64) with {
    table ipv4_flow_table;
}

// Flow 表
table ipv4_flow_table {
    key = {
        // Flow 键: 5-tuple
        hdr.ipv4.srcAddr:   exact;
        hdr.ipv4.dstAddr:   exact;
        hdr.ipv4.protocol: exact;
        hdr.tcp.srcPort:    exact;
        hdr.tcp.dstPort:    exact;
    }
    actions = {
        update_flow_stats;  // 更新统计
        create_new_flow;    // 新建 Flow
        // Flow 超时处理
    }

    counters = {
        flow_packets: direct_counter,
        flow_bytes: direct_counter
    }

    default_action = create_new_flow();
}

// Flow 超时管理
table flow_timeout_table {
    key = {
        // Flow 键
    }
    actions = {
        export_and_delete;  // 导出到 Collector 并删除
        refresh_flow;        // 刷新超时时间
    }
}

// 更新 Flow 统计
action update_flow_stats() {
    // 增加包计数
    flow_packets.increment();
    // 增加字节计数
    flow_bytes.increment(sm.pkt_length);

    // 更新流最后包时间
    meta.flow_last_time = sm.timestamp;
}
```

### 3.4 Flow 超时机制

```c
// Flow 超时元数据
struct flow_timeout_metadata_t {
    bit<32> flow_id;
    bit<32> flow_active_timeout;   // 活动超时 (例如 300s)
    bit<32> flow_inactive_timeout; // 非活动超时 (例如 30s)
    bit<32> flow_start_time;
    bit<32> flow_last_time;
    bool    is_active;             // 是否活跃
}

// 超时检查
action check_flow_timeout() {
    bit<32> current_time = sm.timestamp;
    bit<32> inactive_time = current_time - meta.flow_last_time;

    // 非活动超时
    if (inactive_time > meta.flow_inactive_timeout) {
        // 触发导出
        export_flow_record();
    }

    // 活动超时 (长时间活跃的流)
    bit<32> total_time = current_time - meta.flow_start_time;
    if (total_time > meta.flow_active_timeout) {
        // 定期导出活跃流
        export_flow_record();
        // 重置开始时间
        meta.flow_start_time = current_time;
    }
}
```

---

## 4. INT (In-band Network Telemetry)

### 4.1 INT 原理

**INT** 是一种**随流遥测**技术，在数据包中**插入元数据**，随流传递到接收端：

```
INT 架构:
========

  +-------+     +-------+     +-------+     +-------+
  | Host  | --> |  SW1  | --> |  SW2  | --> |  SW3  | --> [Collector]
  | (SRC) |     | (INT) |     | (INT) |     | (INT) |
  +-------+     +-------+     +-------+     +-------+

  Packet with INT Header:
  +------+------+------+------+---------+
  | Eth  | IP   | INT  | TCP  | Payload |
  +------+------+------+------+---------+
              ^
              |
              | INT 元数据栈:
              | [SW1: queue_depth=10, latency=5us]
              | [SW2: queue_depth=20, latency=8us]
              | [SW3: queue_depth=5,  latency=3us]
```

### 4.2 INT Header 格式

```c
// INT Metadata Header
header int_header_t {
    bit<2>  version;         // 版本号
    bit<2>  flags;           // 标志位
    bit<5>  hop_metadata_len; // 每跳元数据长度 (words)
    bit<5>  remaining_hop_count; // 剩余跳数
    bit<4>  instruction_bitmap;  // 指令位图
    bit<4>  domain_specific_id;  // 域 ID
    bit<16> sequence_number;     // 序列号
    bit<16> node_id;             // 节点 ID
}

// INT Metadata (每跳插入)
header int_metadata_t {
    bit<48>  ingress_timestamp;  // 入方向时间戳
    bit<48>  egress_timestamp;  // 出方向时间戳
    bit<32>  queue_depth;       // 队列深度
    bit<32>  congestion_time;   // 拥塞时间
    // 可扩展更多字段
}

// INT Header Stack
header int_metadata_stack_t {
    int_header_t    header;     // 1 word
    int_metadata_t  hop1;       // N words (per hop)
    int_metadata_t  hop2;
    int_metadata_t  hop3;
    // ...
}
```

### 4.3 P4 INT 实现

```c
// INT Ingress 处理
control int_ingress(inout headers hdr,
                    inout metadata_t meta,
                    inout standard_metadata_t sm) {

    // INT 指令表: 判断是否需要处理 INT
    table int_instruction_table {
        key = {
            hdr.ipv4.dstAddr: lpm;  // INT 目的地址
        }
        actions = {
            enable_int_processing;
            disable_int_processing;
        }
    }

    action enable_int_insertion() {
        // 设置 INT 元数据
        meta.int_enabled = true;
        meta.int_hop_count = 0;
    }

    action insert_int_metadata() {
        // 在 INT Header 后插入元数据
        // 增加 hop_metadata_len

        // 设置当前跳元数据
        hdr.int_metadata.ingress_timestamp = sm.ingress_timestamp;
        // egress_timestamp 在 egress 处理时设置
        hdr.int_metadata.queue_depth = sm.enq_q_depth;
        hdr.int_metadata.congestion_time = sm.deq_timedelta;

        meta.int_hop_count = meta.int_hop_count + 1;
    }

    apply {
        // 检查是否启用 INT
        int_instruction_table.apply();

        if (meta.int_enabled) {
            // 检查是否有空间插入元数据
            if (hdr.int_header.remaining_hop_count > 0) {
                insert_int_metadata();
            }
        }
    }
}

// INT Egress 处理
control int_egress(inout headers hdr,
                   inout metadata_t meta,
                   inout standard_metadata_t sm) {

    apply {
        if (meta.int_enabled) {
            // 更新出口时间戳
            hdr.int_metadata.egress_timestamp = sm.egress_timestamp;

            // 递减 remaining_hop_count
            hdr.int_header.remaining_hop_count =
                hdr.int_header.remaining_hop_count - 1;
        }
    }
}
```

---

## 5. 遥测导出架构

### 5.1 导出方式

| 方式 | 说明 | 优缺点 |
|------|------|--------|
| **镜像** | Packet Copy 到 Collector | 实时但开销大 |
| **Push** | 主动导出 Flow Record | 实时性好 |
| **Pull** | Collector 定期查询 | 可控但延迟 |
| **GPB** | Google Protocol Buffers | 高效压缩 |

### 5.2 P4 遥测导出

```c
// 遥测导出 Control
control telemetry_export(inout headers hdr,
                         inout metadata_t meta,
                         inout standard_metadata_t sm) {

    // 导出触发条件
    table export_trigger {
        key = {
            meta.flow_id: exact;
            meta.packet_count: exact;  // N 个包触发
            meta.flow_timeout: exact;  // 超时触发
        }
        actions = {
            trigger_export;
        }
    }

    // 导出元数据封装
    action prepare_telemetry_packet() {
        // 构建导出包
        hdr.telemetry_header.setValid();
        hdr.telemetry_header.flow_id = meta.flow_id;
        hdr.telemetry_header.src_node_id = LOCAL_NODE_ID;
        hdr.telemetry_header.export_time = sm.timestamp;

        // 复制 Flow 统计信息
        hdr.telemetry_record.pkts = meta.flow_packets;
        hdr.telemetry_record.octets = meta.flow_bytes;
        // ...
    }

    // 发送到 Collector
    action send_to_collector(bit<32> collector_ip, bit<16> collector_port) {
        // 修改目的地址为 Collector
        hdr.ipv4.dstAddr = collector_ip;
        hdr.udp.dstPort = collector_port;

        // 克隆到特殊出口
        clone_preserving_field_list(
            CloneType.I2E,
            TELEMETRY_MIRROR_SESSION,
            TELEMETRY_FIELD_LIST
        );
    }
}
```

---

## 6. 计数器与统计

### 6.1 P4 Counter 类型

```c
// P4 支持多种计数器
// 1. Direct Counter (绑定到 Table)
direct_counter port_packets) with {
    table port_stats_table;
}

direct_counter port_bytes) with {
    table port_stats_table;
}

// 2. Indirect Counter (独立使用)
Counter(8192, CounterType.packets) flow_cache_counter;
Counter(8192, CounterType.bytes)   flow_byte_counter;

// 3. Static Counter (全局)
Counter(32, CounterType.packets_and_bytes) global_counter;
```

### 6.2 接口统计

```c
// 接口统计表
table interface_stats_table {
    key = {
        sm.ingress_port: exact;
    }
    actions = {
        no_action;
    }
    counters = {
        ingress_packets: direct_counter,
        ingress_bytes: direct_counter
    }
}

// Egress 统计
table egress_stats_table {
    key = {
        sm.egress_port: exact;
    }
    actions = {
        no_action;
    }
    counters = {
        egress_packets: direct_counter,
        egress_bytes: direct_counter
    }
}
```

---

## 7. 异常检测

### 7.1 流量异常检测

```c
// 异常检测元数据
struct anomaly_metadata_t {
    bit<32> flow_pkt_rate;       // 流包速率
    bit<32> flow_byte_rate;      // 流字节速率
    bit<32> flow_packet_size_avg; // 平均包大小
    bool    is_anomaly;          // 是否异常
    bit<4>  anomaly_type;        // 异常类型
}

// 异常类型定义
enum anomaly_type_t {
    NONE,
    DDoS,           // DDoS 攻击
    PortScan,       // 端口扫描
    HighPktRate,    // 高包速率
    LowPktRate,     // 低包速率
    AbnormalSize    // 异常包大小
}

// 异常检测表
table anomaly_detection_table {
    key = {
        meta.flow_pkt_rate: range;   // 范围检查
        meta.flow_byte_rate: range;
        meta.flow_packet_size_avg: range;
    }
    actions = {
        mark_anomaly;
        no_action;
    }
}

action mark_anomaly(bit<4> anomaly_type) {
    meta.is_anomaly = true;
    meta.anomaly_type = anomaly_type;

    // 触发告警
    send_anomaly_alert();
}
```

---

## 8. 与控制面集成

### 8.1 P4 Runtime 读取统计

```protobuf
// P4 Runtime 读取 Counter
message ReadRequest {
    Entity entity = 1;
}

message CounterEntry {
    CounterData data = 1;
}

message CounterData {
    uint64 packet_count = 1;
    uint64 byte_count = 2;
}

// gRPC 调用
// ReadDirectCounter(session, device_id, table_name, counter_name)
```

### 8.2 异步遥测

```c
// 异步遥测事件
struct telemetry_event_t {
    string event_type;     // "flow_created", "flow_deleted", "anomaly"
    uint64 timestamp;
    map<string, string> details;
}

// 控制面订阅遥测事件
service TelemetrySubscriber {
    rpc OnFlowCreated(FlowEvent) returns (Empty);
    rpc OnAnomalyDetected(AnomalyEvent) returns (Empty);
}
```

---

## 9. 总结

本章涵盖 P4 网络测量编程的核心内容：

1. **sFlow 采样**：随机采样，低开销流量分析
2. **NetFlow/IPFIX**：Flow 聚合统计，标准化导出格式
3. **INT 随流遥测**：数据包内携带网络元数据，精确诊断
4. **Counter 类型**：Direct/Indirect/Static 计数器
5. **异常检测**：基于流量模式的 DDoS/扫描检测
6. **控制面集成**：P4 Runtime 读取统计、异步遥测事件

这些技术构成了完整的网络可观测性体系，从低开销的采样统计到高精度的随流遥测，可以满足不同场景的需求。
