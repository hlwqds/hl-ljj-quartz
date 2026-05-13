---
title: "P4 深度探索 (十八)：Meter 与 Traffic Manager——流量计量、队列管理与 QoS"
date: 2026-04-14
tags: [p4, series, meter, traffic-manager, qos, rate-limiting, psa, shaping, scheduling]
description: "P4 Meter 与 Traffic Manager 深度解析——Meter 双速率三色算法 (RFC 2697/2698)、单速率三色算法、Direct/Indirect Meter、Traffic Manager 队列管理、QoS 调度、Packet 着色与处理"
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
> 17. [[2026-04-14-p4-deep-dive-ch17-parsevarset|第十七章：Parse Varset——变长 Header 与 IPv6 Extension Header 解析]]
> 18. **第十八章：Meter 与 Traffic Manager——流量计量、队列管理与 QoS**

---

## 1. 概述：流量计量与 QoS

**Meter（流量计量器）** 和 **Traffic Manager** 是 P4 数据平面实现 **QoS（服务质量）** 和**流量控制**的核心组件。

```
Packet 进入 Traffic Manager 的完整流程:
=======================================

入端口
  |
  v
[Packet Descriptors] --> [Ingress Pipeline]
                              |
                              v
                         [Traffic Manager]
                              |
                    +--------+--------+
                    |        |        |
                 Queue 0  Queue 1  Queue N
                    |        |        |
                 [Scheduling / Shaping]
                    |        |        |
                    +--------+--------+
                              |
                              v
                         [Egress Pipeline]
                              |
                              v
出端口
```

### 1.1 Meter 的核心作用

Meter 根据**时间窗口**和**包/字节计数**对流量进行**着色**：

| 颜色           | 含义                           | 通常处理       |
| -------------- | ------------------------------ | -------------- |
| **Green** (0)  | 符合承诺速率 (CIR)             | 正常转发       |
| **Yellow** (1) | 超过 CIR，但符合峰值速率 (PIR) | 降级转发或标记 |
| **Red** (2)    | 超过 PIR                       | 丢弃或重标记   |

---

## 2. Meter 算法：RFC 2697 与 RFC 2698

### 2.1 单速率三色算法 (srTCM, RFC 2697)

srTCM 基于**单个速率**（CIR）对流量进行着色：

```
srTCM 算法:
===========

参数:
  - CIR (Committed Information Rate): 承诺信息速率
  - CBS (Committed Burst Size): 承诺突发大小
  - EBS (Excess Burst Size): 额外突发大小

颜色判断:
  - 如果包大小 <= CBS: GREEN
  - 如果包大小 <= CBS + EBS: YELLOW
  - 否则: RED

内部计数器:
  - C (Committed): 当前承诺突发剩余
  - E (Excess): 当前额外突发剩余

每个包的处理:
  1. if (包大小 <= C) {
       C -= 包大小; color = GREEN;
     } else if (包大小 <= E) {
       E -= 包大小; color = YELLOW;
     } else {
       color = RED;
     }
```

### 2.2 双速率三色算法 (trTCM, RFC 2698)

trTCM 基于**两个速率**（CIR 和 PIR）进行着色：

```
trTCM 算法:
===========

参数:
  - CIR (Committed Information Rate): 承诺信息速率
  - CBS (Committed Burst Size): 承诺突发大小
  - PIR (Peak Information Rate): 峰值信息速率
  - PBS (Peak Burst Size): 峰值突发大小

颜色判断:
  - 如果进口速率 <= CIR: GREEN
  - 如果进口速率 <= PIR: YELLOW
  - 否则: RED

内部计数器:
  - C (Committed): 当前承诺突发剩余
  - P (Peak): 当前峰值突发剩余

每个包的处理:
  1. if (包大小 > P) {
       color = RED;
     } else if (包大小 > C) {
       P -= 包大小; C -= C; color = YELLOW;  // 注意: C 不减少
     } else {
       P -= 包大小; C -= 包大小; color = GREEN;
     }
```

---

## 3. P4 Meter 实现

### 3.1 Meter 定义

```c
// Meter 定义
extern Meter {
    // 构造函数：指定 meter 类型（PACKETS 或 BYTES）
    Meter(bit<32> size, MeterType type);

    // 执行 meter：对指定流进行计量并返回颜色
    // color 是一个 bit<W> 值：0=green, 1=yellow, 2=red
    void execute_meter<T>(in PSA_MeterColor_t init_color,
                          in T index,
                          out PSA_MeterColor_t color);
}

// Meter 类型
enum MeterType {
    PACKETS,  // 按包数计量
    BYTES    // 按字节数计量
}

// PSA Meter 颜色
PSA_MeterColor_t {
    PSA_MeterColor_t.DROP = 0,    // green
    PSA_MeterColor_t.YELLOW = 1,  // yellow
    PSA_MeterColor_t.RED = 2     // red
}
```

### 3.2 Indirect Meter（间接 Meter）

Indirect Meter 通过 Table Entry 关联到 Meter 实例：

```c
control MyIngress(inout headers h, inout metadata m) {

    // 定义 Indirect Meter
    Meter<bit<2>>(1024, MeterType.BYTES) flow_meter;

    // 流分类表：为每条流配置不同的 CIR/PIR
    table meter_config_table {
        key = {
            h.ipv4.srcAddr: exact;
            h.ipv4.dstAddr: exact;
        }
        actions = {
            NoAction;
        }
        default_action = NoAction;

        // P4Runtime 可以通过这个表配置每个流的 meter 参数
        meters = { flow_meter: MeterType.BYTES };
    }

    // 使用 Meter 的 Action
    action rate_limit() {
        PSA_MeterColor_t color;

        // 执行 meter：用 flow ID 作为索引
        flow_meter.execute_meter(
            PSA_MeterColor_t.DROP,   // 初始颜色
            m.flow_id,               // 流索引
            color                    // 输出颜色
        );

        // 根据颜色处理
        if (color == PSA_MeterColor_t.RED) {
            drop();  // 超速丢弃
        } else if (color == PSA_MeterColor_t.YELLOW) {
            // 降级处理：降低优先级或标记 ECN
            h.ipv4.diffserv = h.ipv4.diffserv | 0x02;
        }
    }

    table acl_table {
        key = {
            h.ipv4.srcAddr: ternary;
            h.ipv4.dstAddr: ternary;
        }
        actions = {
            rate_limit;
            NoAction;
        }
        default_action = rate_limit();
    }

    apply {
        meter_config_table.apply();
        acl_table.apply();
    }
}
```

### 3.3 Direct Meter（直接 Meter）

Direct Meter 直接绑定到 Table Entry：

```c
control DirectMeterExample(inout headers h, inout metadata m) {

    // Direct Meter 绑定到 Table
    DirectMeter<bit<2>>(MeterType.PACKETS) acl_meter;

    // 带 meter 的 ACL 表
    table acl_with_meter {
        key = {
            h.ipv4.srcAddr: lpm;
            h.ipv4.dstAddr: lpm;
            h.tcp.srcPort:  range;
            h.tcp.dstPort:  range;
            h.tcp.flags:    ternary;
        }
        actions = {
            permit;
            deny;
        }

        // 直接关联 meter 到这个表
        // meter 索引 = Table Entry 的 handle
        meters = { acl_meter: MeterType.PACKETS };
    }

    // 通过 meter 结果处理
    action process_by_color(PSA_MeterColor_t color) {
        if (color == PSA_MeterColor_t.RED) {
            // 超过速率限制
            deny();
        } else {
            permit();
        }
    }

    apply {
        // ACL 表执行后，meter 自动更新
        acl_with_meter.apply();
    }
}
```

### 3.4 Meter 配置

通过 P4Runtime 配置 Meter 参数：

```python
#!/usr/bin/env python3
"""通过 P4Runtime 配置 Meter"""

from p4.v1 import p4_pb2
from p4.runtime import P4RuntimeClient

def config_meter(client, table_id, meter_id, flow_index,
                 cir=1000000, pir=2000000, cbs=1000, pbs=2000):
    """配置双速率 Meter (trTCM)"""

    meter_entry = p4_pb2.MeterEntry()
    meter_entry.table_entry.table_id = table_id
    meter_entry.meter_id = meter_id

    # 配置 trTCM 参数
    config = meter_entry.config
    config.cir = cir   # 承诺速率 (bytes per second)
    config.pir = pir   # 峰值速率 (bytes per second)
    config.cbs = cbs   # 承诺突发大小 (bytes)
    config.pbs = pbs   # 峰值突发大小 (bytes)

    # 设置索引（流的标识符）
    meter_entry.index = flow_index

    client.WriteMeterEntry(meter_entry)
    print(f"Meter configured: flow={flow_index}, "
          f"CIR={cir}B/s, PIR={pir}B/s")
```

---

## 4. Traffic Manager 详解

### 4.1 PSA Traffic Manager 架构

PSA 的 Traffic Manager 负责** Packet Buffering、队列管理、调度和整形**：

```
PSA Traffic Manager 内部结构:
==============================

Ingress                Traffic Manager                Egress
                         +-----------------+
Packet  --------------> |  Packet Buffer   | --------------> Packet
                        +-----------------+
                         |  Queue Manager  |
                         +-----------------+
                         |   Scheduler     |
                         +-----------------+
                         |   Shaper       |
                         +-----------------+
```

### 4.2 Packet Buffering

每个 Packet 进入 Traffic Manager 时，先进入 **Packet Buffer**：

```
Packet Buffer 结构:
==================

Buffer 深度: 通常 12-32 MB (Tofino)
Packet 存储: 以 MTU 为单位分片存储
Buffer 管理:
  - 每个端口/队列分配信用 (credit)
  - 信用不足时 packet 入队列等待
```

### 4.3 队列管理

```c
// PSA 队列操作（通过 PSA 定义的标准 Metadata）

control QueueControl(inout headers h,
                     inout metadata m,
                     in PSA_ingress_input_metadata_t istd,
                     inout PSA_ingress_output_metadata_t ostd) {

    // 设置出口队列索引
    action set_qid(bit<3> qid) {
        // PSA 定义的队列 ID Metadata
        ostd.enq_congestion_set = (bit<8>)qid;
        ostd.enq_qid = qid;
    }

    // 设置队列优先级
    action set_q_priority(bit<2> priority) {
        ostd.enq_priority = priority;
    }

    // 设置 QoS 类别
    action set_qos_class(bit<8> qos_class) {
        ostd.qos_class = qos_class;
    }

    // 根据 DSCP 选择队列
    action dscp_to_queue() {
        bit<3> qid;
        bit<8> dscp = h.ipv4.diffserv;

        // EF (46) -> 高优先级队列
        // AF (34-45) -> 中优先级
        // BE (0) -> 低优先级
        if (dscp >= 46) {
            qid = 3;  // Highest priority
        } else if (dscp >= 34) {
            qid = 2;
        } else if (dscp >= 26) {
            qid = 1;
        } else {
            qid = 0;
        }

        set_qid(qid);
    }

    table qos_table {
        key = {
            h.ipv4.diffserv: exact;
        }
        actions = {
            set_qid;
            set_q_priority;
            NoAction;
        }
        default_action = dscp_to_queue();
    }

    apply {
        if (h.ipv4.isValid()) {
            qos_table.apply();
        }
    }
}
```

---

## 5. QoS 调度与整形

### 5.1 调度算法

Traffic Manager 支持多种调度算法：

```
调度算法类型:
=============

1. Strict Priority (SP)
   - 高优先级队列永远优先
   - 低优先级只有在高优先级队列为空时才被服务
   - 缺点: 可能饿死低优先级流

2. Deficit Round Robin (DRR)
   - 每个队列有 Deficit Counter
   - 每轮服务 Quantum 字节
   - 公平分享带宽
   - 适合处理不同包大小的流

3. Weighted Fair Queuing (WFQ)
   - 按权重分配带宽
   - 按 (包到达时间 / 权重) 排序
   - 接近完美公平

4. Shaping + Scheduling 组合
   - 先整形（限制峰值速率）
   - 再调度（多队列仲裁）
```

### 5.2 P4 中的 QoS Metadata

PSA 定义了完整的 QoS 相关 Metadata：

```c
// PSA Ingress Output Metadata (ostd)
struct PSA_ingress_output_metadata_t {
    PSA_PacketPathType_t   pass_through;     // Packet 处理路径
    PSA_MeterColor_t       color;             // Meter 颜色
    bit<9>                 multicast_group;  // 多播组
    bit<8>                 clone_session;    // Clone 会话
    bit<3>                 enq_qid;          // 入队队列 ID
    bit<2>                 enq_priority;      // 队列优先级
    bit<16>                enq_depth;         // 入队时队列深度
    bit<32>                enq_congestion_ecn;// ECN 拥塞标记
    bit<8>                 qos_class;         // QoS 类别
    bit<8>                 tc;                // Traffic Class
}

// PSA Egress Output Metadata
struct PSA_egress_output_metadata_t {
    PSA_PacketPathType_t   pass_through;
    bit<9>                 multicast_group;
    bit<8>                 clone_session;
}
```

### 5.3 Shaping 示例

```c
// 流量整形：通过设置队列深度限制实现简单整形
control TrafficShaping(inout headers h,
                        inout metadata m,
                        in PSA_ingress_input_metadata_t istd,
                        inout PSA_ingress_output_metadata_t ostd) {

    // 检测队列深度
    action check_queue_depth() {
        // ostd.enq_depth 表示入队时的队列深度
        // 队列深度以 packet 数为单位

        if (ostd.enq_depth > 100) {
            // 队列拥塞，标记 ECN
            ostd.enq_congestion_ecn = 0x03;  // ECN CE (Congestion Experienced)

            // 可选: 降级 DSCP
            if (h.ipv4.diffserv >= 34) {
                h.ipv4.diffserv = h.ipv4.diffserv - 0x08;  // 降低 AF 等级
            }
        }
    }

    // Per-Queue 整形：通过 meter 限制每个队列的速率
    action apply_per_queue_shaping(bit<32> cir_kbps) {
        // 配置 per-queue meter
        // 在硬件中通常由专门的 Traffic Shaper 模块处理
    }

    apply {
        check_queue_depth();
    }
}
```

---

## 6. ECN 拥塞通知

### 6.1 ECN 工作原理

```
ECN (Explicit Congestion Notification):
======================================

     发送端                      路由器                      接收端
        |                           |                           |
        | ---- TCP + ECN Echo=1 ---> |                           |
        |                           | (检测到拥塞)                |
        |                           | ---- CE Codepoint=11 ----> |
        |                           |                           |
        |                           | <---- CWR=1 (TCP 报头) --- |
        | <--- CWR=1 (TCP 报头) --- |                           |
        |                           |                           |

ECN Codepoint (IPv4/IPv6 Header, 2 bits):
  - 00: 非 ECN Capable Transport (NECT)
  - 01: ECN Capable Transport (ECT(1))
  - 10: ECN Capable Transport (ECT(0))
  - 11: Congestion Experienced (CE)
```

### 6.2 P4 中的 ECN 处理

```c
control ECNProcessing(inout headers h,
                      inout metadata m,
                      in PSA_ingress_input_metadata_t istd,
                      inout PSA_ingress_output_metadata_t ostd) {

    // 在 Ingress 中标记 ECN
    action mark_ecn_ce() {
        // CE 表示拥塞 Experienced
        h.ipv4.ecn = 3;  // 11 in binary

        // 或者标记 ECT(1)
        // h.ipv4.ecn = 1;  // 01 in binary
    }

    // 根据队列深度/ECN 状态决策
    action ecn_routing() {
        // 获取队列拥塞信息
        bit<8> queue_occupancy = ostd.enq_congestion_ecn;

        // 如果队列深度超过阈值，标记 CE
        if (queue_occupancy > 200) {
            mark_ecn_ce();
        }
    }

    // 在 Egress 中处理 ECN
    control EgressECN(inout headers h,
                      in metadata m,
                      in PSA_egress_input_metadata_t istd,
                      inout PSA_egress_output_metadata_t ostd) {

        // ECN 反馈：在 TCP ACK 中设置 ECN Echo
        action set_tcp_ecn_echo() {
            // 在 TCP Header 中标记 ECN Echo
            // TCP ECN Echo 标志在 TCP flags 中
            h.tcp.flags = h.tcp.flags | 0x40;  // ECE flag
        }

        // CWR (Congestion Window Reduced) 标志
        action set_tcp_cwr() {
            h.tcp.flags = h.tcp.flags | 0x80;  // CWR flag
        }

        apply {
            // 如果收到了 CE 标记
            if (h.ipv4.ecn == 3) {
                // 设置 TCP ECN Echo
                if (h.tcp.isValid()) {
                    set_tcp_ecn_echo();
                }
            }
        }
    }
}
```

---

## 7. 重尾丢弃 (RED) 与 WRED

### 7.1 RED 算法

```
RED (Random Early Detection):
============================

当队列长度处于不同区间时，以不同概率丢弃包：

  丢弃概率
     ^
  100%|           +-----------
     |           /
     |          /
  Pmax| ---------
     |         /
     |        /
      0+-----+------+------+------+------> 队列长度
       0    min   max   2*max  buffer_size

- 队列 < min_th: 不丢弃
- min_th <= 队列 <= max_th: 线性增加丢弃概率
- max_th < 队列: 全部丢弃
```

### 7.2 WRED (Weighted RED)

WRED 在 P4 中可以通过 **Per-Queue Meter + DSCP 映射** 实现：

```c
control WRED(inout headers h,
             inout metadata m,
             in PSA_ingress_input_metadata_t istd,
             inout PSA_ingress_output_metadata_t ostd) {

    // Per-queue WRED 配置
    action apply_wred(bit<8> min_threshold, bit<8> max_threshold,
                      bit<8> max_drop_prob) {
        // 通过 meter 和 metadata 实现 WRED
        // min_threshold, max_threshold 以队列深度百分比表示
    }

    // WRED 与 ECN 结合
    action apply_wred_ecn(bit<8> min_threshold, bit<8> max_threshold) {
        // 队列深度百分比
        bit<8> q_depth_pct = (ostd.enq_depth * 100) / 64;  // 假设 max 64 packets

        if (q_depth_pct >= min_threshold) {
            // 启用 ECN 标记（而非丢弃）
            if (q_depth_pct >= max_threshold) {
                ostd.enq_congestion_ecn = 0x03;  // CE
            } else {
                // 概率性 ECN 标记
                // 实际实现由硬件处理
                ostd.enq_congestion_ecn = 0x01;  // ECT(1)
            }
        }
    }

    table wred_table {
        key = {
            ostd.enq_qid: exact;
            h.ipv4.diffserv: exact;
        }
        actions = {
            apply_wred;
            apply_wred_ecn;
            NoAction;
        }
        default_action = NoAction;
    }

    apply {
        wred_table.apply();
    }
}
```

---

## 8. 完整的 QoS 流水线

```
完整的 QoS 处理流程:
====================

Ingress:
  1. Packet 到达
  2. Parser 解析 Header
  3. 分类 (Classification)
     - ACL 检查
     - 识别流类型 (VoIP, Video, Web, etc.)
  4. Meter (srTCM/trTCM)
     - 流量着色 (Green/Yellow/Red)
     - 颜色传递给 Traffic Manager
  5. QoS 映射
     - DSCP -> Queue, Priority, TC
  6. 入队 (Enqueue)
     - Traffic Manager 入队
     - 基于颜色/队列深度决定是否丢弃

Traffic Manager:
  7. 队列调度 (Scheduling)
     - Strict Priority
     - DRR
     - WFQ
  8. 流量整形 (Shaping)
     - PIR/CIR 限制
     - Burst 控制

Egress:
  9. Egress Pipeline 处理
  10. Deparser
  11. Packet 发送
```

---

## 9. 小结

本章介绍了 P4 中的 **Meter** 和 **Traffic Manager**：

| 组件                | 功能                                 |
| ------------------- | ------------------------------------ |
| **Meter**           | 流量速率计量，三色算法 (srTCM/trTCM) |
| **Direct Meter**    | 直接绑定到 Table Entry               |
| **Indirect Meter**  | 通过 Table 配置不同流的 Meter 参数   |
| **Traffic Manager** | Packet Buffer、队列管理、调度、整形  |
| **Queue**           | 队列，入队/出队/深度查询             |
| **Scheduler**       | 严格优先级、DRR、WFQ                 |
| **Shaper**          | PIR/CIR 速率限制                     |
| **ECN**             | 显式拥塞通知                         |

Meter 和 Traffic Manager 是实现**网络 QoS** 的核心——它们共同决定了数据包何时被转发、丢弃或标记，从而保障关键业务的网络性能。
