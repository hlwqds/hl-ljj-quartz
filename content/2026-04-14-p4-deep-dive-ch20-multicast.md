---
title: "P4 深度探索 (二十)：Multicast 与 Clone——多播组、Packet Clone、会话复制与镜像"
date: 2026-04-14
tags: [p4, series, multicast, clone, packet-replication, mirror, clone-session, psa, broadcast]
description: "P4 Multicast 与 Clone 深度解析——Multicast Group 多播组配置、Packet Clone 会话复制、Clone Session、Ingress/Egress Clone、Port Mirror、OAM 注入、PSA 中的多播与复制机制"
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
> 18. [[2026-04-14-p4-deep-dive-ch18-meter|第十八章：Meter 与 Traffic Manager——流量计量、队列管理与 QoS]]
> 19. [[2026-04-14-p4-deep-dive-ch19-int|第十九章：INT——In-band Network Telemetry 随流检测]]
> 20. **第二十章：Multicast 与 Clone——多播组、Packet Clone、会话复制与镜像**

---

## 1. 概述：Packet 复制能力

在数据中心网络中，**Multicast（多播）** 和 **Clone（复制）** 是两种核心的数据包复制机制。P4 通过 PSA/TNA 架构提供了完整的支持。

```
Multicast vs Clone:
===================

Multicast (多播):
  - 一对多：从一个源发往多个目的地
  - 目的地由 Multicast Group 决定
  - 属于正常转发路径
  - 典型应用: 视频广播、组播路由、ARP 广播

Clone (复制):
  - 包复制到多个目的地（包括控制面）
  - 不属于正常转发路径
  - 通常修改后发送到监控/日志端口
  - 典型应用: OAM、Port Mirror、Telemetry

两种机制共享 Traffic Manager 的 Packet Replication 功能
```

---

## 2. PSA Multicast 架构

### 2.1 Multicast Packet Flow

```
PSA Multicast 流程:
===================

Packet 进入 Ingress Pipeline
         |
         v
   Ingress Pipeline 处理
         |
         v
   设置 multicast_group (通过 PSA_ingress_output_metadata)
         |
         +---> multicast_group == 0: 普通单播
         |
         +---> multicast_group > 0: Multicast Group 查表
                   |
                   v
           [Multicast Group Table]
                   |
                   v
           获取出口端口列表
           (Port 1, Port 3, Port 5, ...)
                   |
                   v
           Traffic Manager 复制 Packet
           (N 份拷贝)
                   |
         +---------+---------+----- ...
         |         |         |
         v         v         v
     Port 1    Port 3    Port 5 ...
         |         |         |
         v         v         v
   [Egress]  [Egress]  [Egress] ...
```

### 2.2 Multicast Group

```c
// PSA Ingress Output Metadata 中的 Multicast 相关字段
struct PSA_ingress_output_metadata_t {
    PSA_PacketPathType_t   pass_through;
    PSA_MeterColor_t       color;
    bit<9>                 multicast_group;   // Multicast Group ID
    bit<8>                 clone_session;     // Clone Session ID
    bit<3>                 enq_qid;
    bit<2>                 enq_priority;
    bit<16>                enq_depth;
    bit<8>                 qos_class;
}

// Multicast Group 分配（通过配置，非 P4 代码）
// P4Runtime 配置示例:
//   multicast_group_id: 1
//   replicas: [
//     { port: 1, egress_port: 1 },
//     { port: 3, egress_port: 3 },
//     { port: 5, egress_port: 5 },
//   ]
```

---

## 3. P4 Multicast 实现

### 3.1 设置 Multicast Group

```c
control MulticastControl(inout headers h,
                         inout metadata m,
                         in PSA_ingress_input_metadata_t istd,
                         inout PSA_ingress_output_metadata_t ostd) {

    // 设置 Multicast Group
    action set_multicast_group(bit<9> mgid) {
        // mgid > 0 表示多播
        // mgid == 0 表示单播
        ostd.multicast_group = mgid;
    }

    // L2 多播: 根据 MAC 地址选择 Multicast Group
    action l2_multicast() {
        // Ethernet Multicast Address: 01:00:5E:xx:xx:xx
        // 或者 IEEE 802.1Qat MRP (Multicast Registration Protocol)
        if (h.ethernet.dstAddr[23] == 1) {
            // Multicast bit (LSB of high byte)
            // 例如: 01:xx:xx:xx:xx:xx
            set_multicast_group(100);  // L2 Multicast Group 100
        }
    }

    // L3 多播: 根据 IP 地址选择 Multicast Group
    action l3_multicast(bit<32> group_addr) {
        // IPv4 multicast: 224.0.0.0 - 239.255.255.255
        if (h.ipv4.dstAddr[31:28] >= 0xE) {
            // IP 多播地址
            // 映射到 Multicast Group
            // 224.0.0.x 通常用于协议 (OSPF, etc.)
            // 239.x.x.x 用于应用多播
            set_multicast_group((bit<9>)(group_addr & 0x1FF));
        }
    }

    // VLAN 广播: 同一个 VLAN 内的所有端口
    action vlan_broadcast() {
        // VLAN broadcast: 发送到这个 VLAN 的所有 ports
        // 通常通过 ASIC 的 VLAN flooding 机制实现
        set_multicast_group(200);  // VLAN Broadcast Group
    }

    // 基于 IGMP/MLD 学习的多播组
    action ssm_multicast(bit<32> source, bit<32> group) {
        // SSM (Source-Specific Multicast)
        // 根据 (S, G) channel 选择 Multicast Group
        set_multicast_group((bit<9>)(hash(group) % 256 + 256));
    }

    // ACL: 过滤多播
    action drop_multicast() {
        // 不设置 multicast_group，走单播路径
        // 但可能在 ACL 表中被丢弃
        drop();
    }

    // 多播路由表
    table mc_routing_table {
        key = {
            h.ipv4.dstAddr: lpm;
        }
        actions = {
            l3_multicast;
            drop_multicast;
        }
        default_action = drop_multicast();
    }

    // L2 多播表
    table mc_bridge_table {
        key = {
            h.ethernet.dstAddr: exact;
        }
        actions = {
            l2_multicast;
            vlan_broadcast;
        }
        default_action = vlan_broadcast();
    }

    apply {
        if (h.ethernet.isValid()) {
            if (h.ipv4.isValid()) {
                mc_routing_table.apply();
            } else {
                mc_bridge_table.apply();
            }
        }
    }
}
```

---

## 4. Clone (Packet Replication)

### 4.1 Clone 的类型

PSA 定义了多种 Clone 类型：

```
PSA Clone 类型:
===============

1. Ingress Clone (PI2E - Packet Ingress to Egress)
   - 在 Ingress 中触发
   - 复制的数据包进入 Egress Pipeline
   - 用于: Port Mirror、OAM、Telemetry

2. Ingress Clone (PI2I - Packet Ingress to Ingress)
   - 在 Ingress 中触发
   - 复制的数据包返回 Ingress Pipeline
   - 用于: Loopback、Local Processing

3. Egress Clone (PE2E - Packet Egress to Egress)
   - 在 Egress 中触发
   - 复制的数据包再进入 Egress Pipeline
   - 用于: OAM Reply、Packet Modification

4. Egress Clone (PE2I - Packet Egress to Ingress)
   - 在 Egress 中触发
   - 复制的数据包返回 Ingress Pipeline
   - 用于: 回环处理
```

### 4.2 Clone Session

```c
// Clone Session 定义（通过配置，非 P4 代码）
// Clone Session 指定:
//   - session_id: 会话标识
//   - destinations: 复制到的端口列表
//   - cos: Class of Service
//   - packet_length: 截断长度（可选）

// Clone Session 配置示例:
//   session_id: 10
//   destinations: [
//     { port: CPU_PORT (255), egress_port: 255 },
//   ]
//   cos: 0
//   truncate: 128 bytes  (只复制前 128 字节)

// P4Runtime 配置 Clone Session
/*
CloneSessionEntry:
  session_id: 10
  replicas:
    - egress_port: 255 (CPU port)
      cos: 0
      packet_length: 0 (不截断)
*/
```

### 4.3 P4 中的 Clone 操作

```c
control CloneControl(inout headers h,
                     inout metadata m,
                     in PSA_ingress_input_metadata_t istd,
                     inout PSA_ingress_output_metadata_t ostd) {

    // Clone 到控制面 (CPU)
    action clone_to_cpu() {
        // 设置 Clone Session
        ostd.clone_session = 10;  // Clone Session 10 = CPU port

        // 标记为 Ingress Clone (PI2E)
        // Clone 类型由 Clone Session 配置决定
    }

    // Clone 到监控端口 (Analyzer)
    action clone_to_monitor() {
        ostd.clone_session = 20;  // Clone Session 20 = Analyzer port
    }

    // 有条件 Clone (基于 ACL)
    action acl_clone_to_cpu() {
        // Clone Session 可以在 ACL action 中触发
        ostd.clone_session = 10;
    }

    // ACL 表中触发 Clone
    table acl_mirror_table {
        key = {
            h.ipv4.srcAddr:  ternary;
            h.ipv4.dstAddr:  ternary;
            h.tcp.srcPort:   ternary;
            h.tcp.dstPort:   ternary;
            h.tcp.flags:     ternary;
        }
        actions = {
            forward;
            clone_to_cpu;
            clone_to_monitor;
            drop;
        }

        // 配置: 特定敏感流量 Clone 到控制面
        const entries = {
            // SSH 流量 -> Clone
            ternary &&& { h.tcp.dstPort == 22 }: clone_to_cpu();
            // HTTP流量 -> Clone
            ternary &&& { h.tcp.dstPort == 80 }: clone_to_monitor();
            // ICMP flood -> Clone
            ternary &&& { h.icmp.isValid() }: clone_to_cpu();
        }
    }

    apply {
        acl_mirror_table.apply();
    }
}
```

---

## 5. 典型应用场景

### 5.1 Port Mirror (端口镜像)

```c
// Port Mirror: 复制流量到监控端口
control PortMirror(inout headers h,
                   inout metadata m,
                   in PSA_ingress_input_metadata_t istd,
                   inout PSA_ingress_output_metadata_t ostd) {

    // 配置镜像: 基于 SPAN (Switch Port ANalyzer)
    action span_all() {
        // 将该入口的所有流量镜像到 Monitor port
        ostd.clone_session = 30;  // SPAN session
    }

    // RSPAN (Remote SPAN): 跨交换机的镜像
    action rspan_mirror() {
        // 复制到 RSPAN VLAN
        // 在出口处通过隧道发送到远程监控设备
        h.vlan.setValid();
        h.vlan.vlan_id = 1000;  // RSPAN VLAN
    }

    // ERSPAN (Encapsulated RSPAN)
    action erspan_mirror() {
        // GRE 封装的远程镜像
        // 添加 GRE Header + ERSPAN Header
        h.gre.setValid();
        h.erspan.setValid();
        h.erspan.session_id = 256;
        h.erspan.index = (bit<22>)istd.ingress_port;
    }

    table mirror_table {
        key = {
            istd.ingress_port: exact;
        }
        actions = {
            span_all;
            rspan_mirror;
            erspan_mirror;
        }
        default_action = NoAction;
    }

    apply {
        mirror_table.apply();
    }
}
```

### 5.2 OAM (Operations, Administration & Maintenance)

```c
// OAM: 802.1ag, Y.1731, BFD 等
control OAMProcessing(inout headers h,
                     inout metadata m,
                     in PSA_ingress_input_metadata_t istd,
                     inout PSA_ingress_output_metadata_t ostd) {

    // Ethernet OAM (802.1ag): CFM (Connectivity Fault Management)
    action process_cfm() {
        // CFM 报文的处理
        // CCM (Continuity Check Message): 周期性广播
        // LBM (Loopback Message): ping
        // LTM (Link Trace Message): traceroute
    }

    // BFD (Bidirectional Forwarding Detection)
    action process_bfd() {
        // BFD 报文需要快速转发到控制面处理
        // BFD 在两个转发平面之间建立会话
        // 检测链路故障
        ostd.clone_session = 40;  // BFD session
    }

    // LSP Ping (MPLS OAM)
    action process_lsp_ping() {
        // MPLS label stack validation
        // 复制到控制面进行校验
        ostd.clone_session = 50;
    }

    // OAM 表
    table oam_table {
        key = {
            h.ethernet.etherType: exact;
            h.cfm.isValid():       exact;
            h.bfd.isValid():       exact;
        }
        actions = {
            process_cfm;
            process_bfd;
            process_lsp_ping;
            NoAction;
        }
        default_action = NoAction;
    }

    apply {
        oam_table.apply();
    }
}
```

### 5.3 Intellite (带内网络遥测) Clone

```c
// INT Clone: 将带内遥测数据复制到收集器
control INTTelemetry(inout headers h,
                     inout metadata m,
                     in PSA_ingress_input_metadata_t istd,
                     inout PSA_ingress_output_metadata_t ostd) {

    // 将 INT 数据包的元数据发送到遥测收集器
    action clone_int_telemetry() {
        // 只 Clone 一份到 CPU/Collector
        ostd.clone_session = 60;  // INT Telemetry session
    }

    // 触发 Clone 的条件
    table int_telemetry_table {
        key = {
            h.int_header.isValid():   exact;  // INT 包
            h.ipv4.srcAddr:           exact;  // 特定源
            h.int_header.instruction_bitmap: ternary;  // 特定 INT 配置
        }
        actions = {
            clone_int_telemetry;
        }
        default_action = NoAction;
    }

    apply {
        if (h.int_header.isValid()) {
            int_telemetry_table.apply();
        }
    }
}
```

---

## 6. Multicast 与 Clone 的联合使用

### 6.1 ACL 日志与监控

```c
// 综合安全监控: ACL + Clone + Multicast
control SecurityMonitoring(inout headers h,
                            inout metadata m,
                            in PSA_ingress_input_metadata_t istd,
                            inout PSA_ingress_output_metadata_t ostd) {

    // 记录匹配的 ACL 条目
    action log_and_forward(bit<9> mgid) {
        // 设置多播组
        ostd.multicast_group = mgid;

        // 同时克隆一份到安全监控端口
        ostd.clone_session = 100;

        // 记录日志: 流信息 + timestamp
        // 使用 Digest 发送到控制面
        digest<flow_info_t>(1) flow_log_digest;
        flow_info_t info;
        info.timestamp = (bit<48>)istd.ingress_timestamp;
        info.src_ip = h.ipv4.srcAddr;
        info.dst_ip = h.ipv4.dstAddr;
        info.src_port = h.tcp.srcPort;
        info.dst_port = h.tcp.dstPort;
        info.protocol = h.ipv4.protocol;
        info.action = ACL_ACTION_DENY;
        flow_log_digest.emit(info);
    }

    // 防火墙 ACL
    table firewall_acl {
        key = {
            h.ipv4.srcAddr: lpm;
            h.ipv4.dstAddr: lpm;
            h.tcp.srcPort:  range;
            h.tcp.dstPort:  range;
            h.tcp.flags:    ternary;
        }
        actions = {
            forward;
            drop;
            log_and_forward;
        }

        const entries = {
            // 阻止并记录 SSH 暴力破解
            * &&& * &&& { 22 <= tcp.srcPort <= 22 } &&& { tcp.flags & 0x02 != 0 }: log_and_forward(0);
        }
    }

    apply {
        firewall_acl.apply();
    }
}
```

---

## 7. Multicast Group 配置

### 7.1 P4Runtime 配置 Multicast Group

```python
#!/usr/bin/env python3
"""通过 P4Runtime 配置 Multicast Group"""

from p4.v1 import p4_pb2
from p4.runtime import P4RuntimeClient

class MulticastController:
    def __init__(self, addr="192.168.1.1:50051"):
        self.client = P4RuntimeClient(addr)

    def create_multicast_group(self, group_id, replicas):
        """创建 Multicast Group

        Args:
            group_id: Multicast Group ID (bit<9>)
            replicas: List of (port, egress_port) tuples
        """
        mc_entry = p4_pb2.MulticastGroupEntry()
        mc_entry.multicast_group_id = group_id

        for port, egress_port in replicas:
            replica = mc_entry.replicas.add()
            replica.egress_port = egress_port
            replica.instance = 0  # 通常为 0

        self.client.Write(mc_entry)
        print(f"Created Multicast Group {group_id} with {len(replicas)} replicas")

    def create_clone_session(self, session_id, replicas, cos=0):
        """创建 Clone Session

        Args:
            session_id: Clone Session ID (bit<8>)
            replicas: List of (port, egress_port) tuples
            cos: Class of Service
        """
        clone_entry = p4_pb2.CloneSessionEntry()
        clone_entry.session_id = session_id
        clone_entry.class_of_service = cos
        clone_entry.packet_length_bytes = 0  # 0 = 不截断

        for port, egress_port in replicas:
            replica = clone_entry.replicas.add()
            replica.egress_port = egress_port
            replica.instance = 0

        self.client.Write(clone_entry)
        print(f"Created Clone Session {session_id}")

    def config_l2_multicast(self):
        """配置 L2 Multicast (VLAN flooding)"""
        # VLAN 10 的所有端口
        self.create_multicast_group(100, [
            (1, 1), (2, 2), (3, 3), (4, 4),
            (5, 5), (6, 6), (7, 7), (8, 8),
        ])

    def config_erspan(self):
        """配置 ERSPAN 镜像到远程监控"""
        # Clone Session 30 -> GRE tunnel to 10.0.1.100
        self.create_clone_session(30, [
            (100, 100),  # Port 100 是 ERSPAN tunnel 端口
        ])

if __name__ == "__main__":
    mc = MulticastController()

    # L2 Multicast: VLAN 10
    mc.config_l2_multicast()

    # ACL Mirror: Clone Session 10 -> CPU port 255
    mc.create_clone_session(10, [(255, 255)])

    # Port Mirror: Clone Session 30 -> Analyzer port 50
    mc.create_clone_session(30, [(50, 50)])

    # ERSPAN
    mc.config_erspan()
```

---

## 8. Multicast 与 Clone 的性能考虑

### 8.1 资源使用

```
Clone / Multicast 资源开销:
===========================

1. Packet Buffer 消耗:
   - 每个 Clone 副本占用 Buffer
   - 多个 Clone 会成倍增加 Buffer 使用

2. 端口带宽:
   - 每个 Clone 副本占用出端口带宽
   - 多个端口的 Clone 会增加 ASIC 内部带宽

3. Pipeline 次数:
   - Ingress Clone: 包在 Ingress 处理后被复制
   - 副本仍然需要经过 Egress Pipeline
   - 对每个副本都执行完整的 Egress 处理

4. Replication Engine:
   - ASIC 专门的 Replication Engine 处理多播复制
   - 复制次数受硬件限制 (Tofino: 每个 Packet 最多 16 副本)
```

### 8.2 Tofino 的 Multicast 实现

```
Tofino Multicast 架构:
======================

Tofino 的 Packet Replication 单元 (PRU):
  - 独立的硬件模块
  - 支持 Multicast 和 Clone
  - 复制数量受 PRU 端口数量限制

Tofino Multicast 表:
  - MC Group 表: 最多 4096 个组
  - 每个组最多 128 个端口
  - 支持跨 Pipeline 复制

Tofino Clone Session:
  - 最多 32 个 Clone Session
  - 每个 Session 支持多个出口
```

---

## 9. 小结

本章介绍了 P4 中的 **Multicast** 和 **Clone** 两种 Packet 复制机制：

| 机制                     | 触发位置 | 典型用途                        |
| ------------------------ | -------- | ------------------------------- |
| **Multicast**            | Ingress  | L2/L3 多播、组播路由、VLAN 广播 |
| **Ingress Clone (PI2E)** | Ingress  | Port Mirror、ACL Log、OAM、INT  |
| **Ingress Clone (PI2I)** | Ingress  | Loopback、Local Processing      |
| **Egress Clone (PE2E)**  | Egress   | OAM Reply、Packet Modification  |
| **Egress Clone (PE2I)**  | Egress   | 回环处理                        |

### PSA 中的 Multicast/Clone Metadata

```c
struct PSA_ingress_output_metadata_t {
    // ...
    bit<9>  multicast_group;   // >0: 多播组 ID
    bit<8>  clone_session;     // Clone 会话 ID
    // ...
};
```

两种机制共享 ASIC 的 **Packet Replication Engine**，但配置方式不同：

- **Multicast Group** 通过 `multicast_group` 字段引用组表
- **Clone Session** 通过 `clone_session` 字段引用会话配置

两者结合，可以实现复杂的安全监控、OAM、和遥测功能。
