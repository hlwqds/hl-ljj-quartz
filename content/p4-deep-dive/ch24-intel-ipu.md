---
title: "P4 深度探索 (二十四)：Intel IPU——IPU/DPU、基础设施处理单元、Fxp/Dcp、P4 控制面"
date: 2026-04-14
tags:
  [
    p4,
    series,
    ipu,
    dpu,
    intel,
    infrastructure-processing-unit,
    fxp,
    dcp,
    smartnic,
    p4,
    control-plane,
  ]
description: "Intel IPU 深度解析——Infrastructure Processing Unit / DPU、P4 在 IPU 上的部署、Fxp (Flow Processor)、Dcp (Data-path Controller)、P4 控制面架构、IPU 与交换机的差异"
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
> 19. [[ch19-int|第十九章：INT——In-band Network Telemetry 随流检测]]
> 20. [[ch20-multicast|第二十章：Multicast 与 Clone——多播组、Packet Clone、会话复制与镜像]]
> 21. [[ch21-bmv2|第二十一章：BMv2——Behavioral Model v2、软件交换机]]
> 22. [[ch22-tofino|第二十二章：Intel Tofino——Tofino 1 芯片架构、Pipeline、RAM/TCAM 资源]]
> 23. [[ch23-tofino2|第二十三章：Tofino 2——12.8Tbps P4-16 交换芯片、Flex Pipes]]
> 24. **第二十四章：Intel IPU——IPU/DPU、基础设施处理单元、Fxp/Dcp、P4 控制面**

---

## 1. 概述：什么是 IPU？

**IPU (Infrastructure Processing Unit)** 是 Intel 提出的新型数据处理芯片，用于**卸载基础设施工作负载**到专用硬件。IPU 也被称为 **DPU (Data Processing Unit)** 或 **SmartNIC**。

```
IPU 在数据中心的位置:
=====================

传统架构:
+----------+     +----------+     +----------+
|   Host   | <-> |  Switch  | <-> |   Host   |
|  (CPU)   |     |          |     |  (CPU)   |
+----------+     +----------+     +----------+

问题:
- CPU 承担网络/存储/安全功能
- 消耗大量 CPU 周期
- 性能瓶颈


IPU 架构:
+----------+     +------------------+     +----------+
|   Host   | <-> |       IPU        | <-> |  Switch  |
|  (CPU)   |     |  +------------+  |     |          |
|          |     |  | P4 Pipeline |     |          |
|          |     |  | +----------+ |     |          |
+----------+     |  | |Control   | |     +----------+
                  |  | |Plane     | |
                  |  | +----------+ |     +----------+
                  |  | +----------+ | <-> |   Host   |
                  |  | |Workload  | |     |  (CPU)  |
                  |  | |Offload   | |     +----------+
                  |  | +----------+ |
                  |  +------------+
                  +------------------+

优势:
- 基础设施功能卸载到 IPU
- 释放 CPU 周期
- 加速网络/存储/安全
```

### 1.1 IPU vs 交换机

| 维度         | IPU (SmartNIC)             | 交换机 (Tofino) |
| ------------ | -------------------------- | --------------- |
| **位置**     | Host 侧                    | 网络侧          |
| **主要功能** | 虚拟化、存储、网络卸载     | L2/L3 转发      |
| **端口数**   | 1-4 x 100G                 | 64-256 x 100G   |
| **表容量**   | 较小                       | 超大            |
| **TCAM**     | 可选                       | 原生支持        |
| **CPU 核心** | 多核 ARM/x86               | 无              |
| **DRAM**     | DDR4/HBM                   | 一般无          |
| **主要用例** | vSwitch、NVMe-oF、Security | Spine/Leaf 交换 |

### 1.2 Intel IPU 产品线

```
Intel IPU 产品线:
=================

1. Intel IPU E2000 系列
   - 基于 Tofino 2 交换芯片
   - 32-64 x 100GE ports
   - P4 可编程
   - 用于混合云/电信

2. Intel IPU M1000 系列
   - 基于 FPGA (Agilex)
   - 2 x 100GE + 1 x 200GE
   - 灵活可编程
   - 用于边缘/电信

3. Intel IPU C6000 系列
   - 基于 CPU + Switch
   - 内置 x86 cores
   - 运行标准 Linux
   - 用于存储/安全

4. Intel IPU C5000X
   - 基于 Tofino 2
   - 64 x 200GE
   - 高密度
   - 用于超大规模
```

---

## 2. IPU 架构详解

### 2.1 IPU 整体架构

```
Intel IPU 整体架构:
===================

+==========================================================================+
||                           HOST INTERFACE                                ||
+==========================================================================+
||                                                                           ||
||   +------------------+    +------------------+    +------------------+  ||
||   |   PCIe Gen 4/5  |    |   CXL 2.0        |    |   CCIX          |  ||
||   |   x16           |    |   (Cache coheren)|    |   (Accelerator)  |  ||
||   +--------+---------+    +--------+---------+    +--------+---------+  ||
||            |                         |                         |         ||
+==========================================================================+
                                    |
                                    v
+==========================================================================+
||                         IPU INTERNAL FABRIC                             ||
+==========================================================================+
||                                                                           ||
||   +------------------+                        +------------------+       ||
||   |   Traffic       |                        |   Workload       |       ||
||   |   Director      | <====================> |   Engine         |       ||
||   |   (Packet       |                        |   (ARM/x86 Cores)|       ||
||   |    Distributor) |                        +------------------+       ||
||   +--------+---------+                                                       ||
||            |                                                                 ||
||            v                                                                 ||
||   +========================================================================+ ||
||   ||                      P4 DATA PLANE (Fxp)                            || ||
||   ||  +----------+  +----------+  +----------+  +----------+             || ||
||   ||  | Parser   |->|  MAU     |->|  MAU     |->| Deparser |             || ||
||   ||  |          |  |  Stage   |  |  Stage   |  |          |             || ||
||   ||  +----------+  +----------+  +----------+  +----------+             || ||
||   +========================================================================+ ||
||                                    |                                      ||
+==========================================================================+
                                    |
                                    v
+==========================================================================+
||                         NETWORK INTERFACE                                ||
+==========================================================================+
||                                                                           ||
||   +------------------+    +------------------+    +------------------+  ||
||   |   100GE MAC     |    |   200GE MAC      |    |   400GE MAC      |  ||
||   |   (SerDes)      |    |   (SerDes)       |    |   (SerDes)       |  ||
||   +------------------+    +------------------+    +------------------+  │
||                                                                           ||
+==========================================================================+
```

### 2.2 IPU 与主机连接

```
IPU-Host 连接架构:
==================

传统 PCIe:
+----------+         +----------+
|   Host   | <=====> |   IPU    |
|   CPU    |  PCIe   |          |
|   (VM)   |         |  Network |
+----------+         +----------+

问题: PCIe 带宽成为瓶颈


SR-IOV 架构:
+----------+  VF  +----------+
|   VM 1   | <==> |   IPU    |
+----------+      |          |
+----------+  VF  |  VF 1   |
|   VM 2   | <==> |          |
+----------+      |  VF 2   |
+----------+  PF  |          |
|   Host   | <==> |  PF 0   |
|   Linux  |      |          |
+----------+      +----------+

优势:
- 虚拟机直接访问 IPU VF
- 绕过 Hypervisor
- 降低延迟
- 释放 CPU
```

### 2.3 IPU 工作负载卸载

```
IPU 卸载的工作负载:
====================

1. 虚拟交换 (vSwitch)
   - Open vSwitch (OvS)
   - 100% 卸载到 IPU P4
   - 性能: ~200Mpps

2. 存储协议
   - NVMe-oF (TCP/RDMA)
   - iSCSI
   - 存储镜像/复制

3. 网络功能
   - Firewall (VNF)
   - Load Balancer
   - VPN/IPSec

4. 安全功能
   - TLS/DTLS 加密
   - WireGuard
   - DDoS 防护

5. Telemetry
   - INT (In-band Network Telemetry)
   - sFlow/NetFlow 采集
   - 流量监控
```

---

## 3. Fxp (Flow Processor) 详解

### 3.1 Fxp 概述

**Fxp (Flow Processor)** 是 IPU 上的 P4 可编程数据平面组件，负责**数据包处理**。

```
Fxp 架构:
=========

Fxp 与 Tofino Switch 的对比:

| 组件      | Tofino Switch | IPU Fxp          |
|-----------|---------------|-------------------|
| Pipeline  | 32+32 stages  | 16-32 stages      |
| TCAM      | 128 Mb        | 可选 (通常无)     |
| SRAM      | 256 MB        | 32-64 MB          |
| Packet Buf| 256 MB        | 8-16 MB           |
| Ports     | 64-256 x 100G | 2-4 x 100G        |
| 主要功能  | L2/L3 转发    | 虚拟化/卸载       |
| 运行位置  | 交换机       | SmartNIC/IPU      |
```

### 3.2 Fxp 流水线

```
Fxp 流水线架构:
===============

Per Port Pipeline:
+----------------+    +----------------+    +----------------+
|    Parser      |--> |   MAU Stage    |--> |   MAU Stage    |
|    (32 states) |    |   (Hash+ALU)   |    |   (Hash+ALU)   |
+----------------+    +----------------+    +----------------+
                            |                        |
                            v                        v
                     +----------------+    +----------------+
                     |   MAU Stage    |    |    Deparser     |
                     |   (Hash+ALU)   |    |                |
                     +----------------+    +----------------+
                                                     |
Global Resources:                                     v
- Hash Units: 16                              +------------+
- SRAM: 64 MB total                           |  TM        |
- Clone/MC Engine                             |  Queues    |
                                              +------------+
```

### 3.3 Fxp P4 程序示例

```c
// IPU Fxp P4 程序示例 - vSwitch 卸载
#include <core.p4>
#include <tna.p4>  // IPU 使用 TNA 架构

// ============== Header 定义 ==============
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
    bit<4>  flags;
    bit<16> window;
    bit<16> checksum;
    bit<16> urgentPtr;
}

header udp_t {
    bit<16> srcPort;
    bit<16> dstPort;
    bit<16> length_;
    bit<16> checksum;
}

// VXLAN Header (用于 vSwitch overlay)
header vxlan_t {
    bit<8>  flags;
    bit<24> reserved;
    bit<24> vni;
    bit<8>  reserved2;
}

struct headers_t {
    ethernet_t outer_ethernet;
    ipv4_t     outer_ipv4;
    udp_t      outer_udp;
    vxlan_t    vxlan;
    ethernet_t inner_ethernet;
    ipv4_t     inner_ipv4;
    tcp_t      tcp;
    udp_t      inner_udp;
}

struct metadata_t {
    bit<24> vni;              // VXLAN Network Identifier
    bit<12> vlan_id;          // VLAN ID
    bit<9>  src_port;         // Source virtual port
    bit<9>  dst_port;         // Destination virtual port
    bit<8>  tunnel_action;    // Tunnel operation
}

// ============== Parser ==============
parser IngressParser(packet_in packet,
                    out headers h,
                    inout metadata m,
                    in PSA_ParserInputMetadata_t istd) {

    state start {
        packet.extract(h.outer_ethernet);
        transition select(h.outer_ethernet.etherType) {
            0x0800: parse_outer_ipv4;
            default: accept;
        }
    }

    state parse_outer_ipv4 {
        packet.extract(h.outer_ipv4);
        transition select(h.outer_ipv4.protocol) {
            17: parse_outer_udp;  // UDP
            6: parse_tcp;
            default: accept;
        }
    }

    state parse_outer_udp {
        packet.extract(h.outer_udp);
        transition select(h.outer_udp.dstPort) {
            4789: parse_vxlan;  // VXLAN
            default: accept;
        }
    }

    state parse_vxlan {
        packet.extract(h.vxlan);
        m.vni = h.vxlan.vni;
        transition select(h.vxlan.vni) {
            0: accept;  // Drop if VNI is 0
            default: parse_inner_ethernet;
        }
    }

    state parse_inner_ethernet {
        packet.extract(h.inner_ethernet);
        transition select(h.inner_ethernet.etherType) {
            0x0800: parse_inner_ipv4;
            default: accept;
        }
    }

    state parse_inner_ipv4 {
        packet.extract(h.inner_ipv4);
        transition select(h.inner_ipv4.protocol) {
            6: parse_tcp;
            17: parse_inner_udp;
            default: accept;
        }
    }

    state parse_tcp {
        packet.extract(h.tcp);
        transition accept;
    }

    state parse_inner_udp {
        packet.extract(h.inner_udp);
        transition accept;
    }
}

// ============== Control ==============
control Ingress(inout headers h,
                inout metadata m,
                in PSA_ParserInputMetadata_t istd,
                inout PSA_ingress_output_metadata_t ostd) {

    // VXLAN VNI -> 目的端口映射表
    action vxlan_lookup(bit<9> port, bit<8> action_type) {
        m.dst_port = port;
        m.tunnel_action = action_type;
    }

    // L2 转发 (同一 VNI 内)
    action l2_forward(bit<48> dst_mac, bit<9> port) {
        h.inner_ethernet.dstAddr = dst_mac;
        m.dst_port = port;
    }

    // L3 转发 (跨 VNI)
    action l3_forward(bit<9> port) {
        h.inner_ipv4.ttl = h.inner_ipv4.ttl - 1;
        m.dst_port = port;
    }

    // 封装 VXLAN
    action vxlan_encap(bit<48> src_mac, bit<48> dst_mac,
                       bit<32> src_ip, bit<32> dst_ip,
                       bit<16> vni) {
        // 添加 VXLAN 封装
        h.vxlan.setValid();
        h.vxlan.vni = vni[23:0];

        // 添加外层 IP/UDP
        h.outer_ipv4.setValid();
        h.outer_ipv4.srcAddr = src_ip;
        h.outer_ipv4.dstAddr = dst_ip;
        h.outer_ipv4.protocol = 17;  // UDP
        h.outer_ipv4.ttl = 64;

        h.outer_udp.setValid();
        h.outer_udp.srcPort = 4789;
        h.outer_udp.dstPort = 4789;

        h.outer_ethernet.setValid();
        h.outer_ethernet.srcAddr = src_mac;
        h.outer_ethernet.dstAddr = dst_mac;
    }

    // 解封装 VXLAN
    action vxlan_decap() {
        // 移除 VXLAN 封装
        h.vxlan.setInvalid();
        h.outer_ipv4.setInvalid();
        h.outer_udp.setInvalid();
        h.outer_ethernet.setInvalid();
    }

    // Drop action
    action drop() {
        ostd.drop = true;
    }

    // VXLAN 表
    table vxlan_table {
        key = {
            m.vni: exact;
        }
        actions = {
            vxlan_lookup;
            drop;
        }
        size = 16K;
    }

    // L2 转发表
    table l2_table {
        key = {
            m.vni: exact;
            h.inner_ethernet.dstAddr: exact;
        }
        actions = {
            l2_forward;
            vxlan_encap;
            drop;
        }
        size = 64K;
    }

    // L3 转发表
    table l3_table {
        key = {
            h.inner_ipv4.dstAddr: lpm;
        }
        actions = {
            l3_forward;
            drop;
        }
        size = 32K;
    }

    // ACL 表
    table acl_table {
        key = {
            h.inner_ipv4.srcAddr: ternary;
            h.inner_ipv4.dstAddr: ternary;
            h.tcp.srcPort: ternary;
            h.tcp.dstPort: ternary;
            h.tcp.flags: ternary;
        }
        actions = {
            allow;
            drop;
        }
        size = 8K;
    }

    apply {
        // 首先应用 ACL
        acl_table.apply();

        // VXLAN 处理
        if (h.vxlan.isValid()) {
            vxlan_table.apply();

            if (m.dst_port != 0) {
                l2_table.apply();
            }
        } else {
            // 没有 VXLAN，做 L3 转发
            l3_table.apply();
        }
    }
}

// ============== Deparser ==============
control IngressDeparser(packet_out packet,
                       inout headers h,
                       in metadata m,
                       in PSA_ingress_output_metadata_t ostd) {
    apply {
        // 按顺序发射 headers
        packet.emit(h.outer_ethernet);
        packet.emit(h.outer_ipv4);
        packet.emit(h.outer_udp);
        packet.emit(h.vxlan);
        packet.emit(h.inner_ethernet);
        packet.emit(h.inner_ipv4);
        packet.emit(h.tcp);
        packet.emit(h.inner_udp);
    }
}

// ============== Pipeline ==============
Pipeline(IngressParser(), Ingress(), IngressDeparser()) ip;
PSA_Switch(ip, Egress()) main;
```

---

## 4. Dcp (Data-path Controller) 详解

### 4.1 Dcp 概述

**Dcp (Data-path Controller)** 是 IPU 上的控制平面组件，负责**管理 Fxp 和工作负载**。

```
Dcp 架构:
=========

Dcp 是运行在 IPU ARM/x86 核心上的软件栈:

+==========================================================================+
||                           DCP SOFTWARE STACK                            ||
+==========================================================================+
||                                                                           ||
||   +------------------+  +------------------+  +------------------+       ||
||   |  Application     |  |  Application     |  |  Application     |       ||
||   |  (vSwitch)      |  |  (NVMe-oF)       |  |  (Security)      |       ||
||   +--------+-------+  +--------+-------+  +--------+-------+       ||
||            |                     |                     |               ||
||            v                     v                     v               ||
||   +========================================================================+ ||
||   ||                    Dcp Runtime (Control Plane)                    || ||
||   ||  +------------+  +------------+  +------------+  +------------+  || ||
||   ||  | Table     |  | Packet     |  | DMA        |  | Timer      |  || ||
||   ||  | Manager   |  | Handler    |  | Manager    |  | Wheel      |  || ||
||   ||  +------------+  +------------+  +------------+  +------------+  || ||
||   +========================================================================+ ||
||                                    |                                      ||
||                                    v                                      ||
||   +========================================================================+ ||
||   ||                    P4Runtime / gRPC Northbound                      || ||
||   +========================================================================+ ||
||                                    |                                      ||
||                                    v                                      ||
||   +========================================================================+ ||
||   ||                    Fxp Driver (Linux Kernel)                        || ||
||   +========================================================================+ ||
||                                    |                                      ||
||                                    v                                      ||
||   +========================================================================+ ||
||   ||                         Fxp (P4 Data Plane)                          || ||
||   +========================================================================+ ||
||                                                                           ||
+==========================================================================+
```

### 4.2 Dcp 核心组件

```
Dcp Runtime 组件:
=================

1. Table Manager
   - 管理 P4 表项
   - 支持 P4Runtime
   - 表项老化/学习

2. Packet Handler
   - 处理 Packet-In (从 Fxp 来的数据包)
   - Packet-Out (发送到 Fxp)
   - OAM 报文处理

3. DMA Manager
   - Host <-> IPU 内存复制
   - 零拷贝优化

4. Timer Wheel
   - 定时任务
   - 表项老化
   - 统计收集

5. Metadata Bus
   - Fxp <-> Dcp 通信
   - 共享内存
```

### 4.3 Dcp 与 Fxp 交互

```
Dcp-Fxp 交互流程:
=================

1. 表项下发 (Dcp -> Fxp):

   [App/Ryu/ONOS] --gRPC--> [Dcp Runtime] --DMA--> [Fxp]
                                              |
                                              v
                                       [P4 Table Entry]
                                       (TCAM/SRAM)

2. Packet-In (Fxp -> Dcp):

   [Fxp] --DMA--> [Dcp Packet Queue]
                    |
                    v
              [Dcp Packet Handler]
                    |
                    v
              [App / Control Plane]

3. Statistics (Fxp -> Dcp):

   [Fxp Registers/Counters] --DMA--> [Dcp Stats Collector]
                                        |
                                        v
                                  [Telemetry Export]
```

---

## 5. IPU P4 控制面

### 5.1 IPU P4Runtime

IPU 使用标准 P4Runtime 作为北向接口：

```protobuf
// IPU P4Runtime 服务
service P4Runtime {
    // 表项操作
    rpc Write(WriteRequest) returns (WriteResponse);
    rpc Read(ReadRequest) returns (stream ReadResponse);

    // Packet 操作
    rpc PacketOut(stream PacketOut) returns (stream PacketIn);

    // 流水线配置
    rpc SetForwardingPipelineConfig(SetForwardingPipelineConfigRequest)
        returns (SetForwardingPipelineConfigResponse);
    rpc GetForwardingPipelineConfig(GetForwardingPipelineConfigRequest)
        returns (GetForwardingPipelineConfigResponse);
}
```

### 5.2 IPU 控制面部署

```
IPU 控制面部署模式:
====================

模式 1: IPU 作为独立设备
+----------+
| Switch   | <--- P4Runtime ---> [Controller]
+----------+                     (Ryu/ONOS)
     |
     v
+--------+
| IPU    | <--- P4Runtime ---> [Controller]
+--------+   (独立控制)

模式 2: IPU 与 Host 协同
+--------+         +----------+
|  Host  | <====> |   IPU    |
| (VM)   | vSwitch|          | <--- P4Runtime ---> [Controller]
+--------+ 卸载   +----------+

模式 3: 分布式 IPU 控制
+--------+         +----------+
|  IPU 1 | <====> |  IPU 2   | <--- P4Runtime ---+
+--------+  VXLAN +----------+                   |
                                                 v
                                           [Controller]
```

### 5.3 IPU 控制面实现

```python
#!/usr/bin/env python3
# ipu_control_plane.py - IPU P4 控制面实现

import grpc
from p4.v1 import p4runtime_pb2, p4runtime_pb2_grpc
from p4.config.v1 import p4info_pb2

class IPUControlPlane:
    def __init__(self, ipu_address='192.168.1.100:50051'):
        self.channel = grpc.insecure_channel(ipu_address)
        self.stub = p4runtime_pb2_grpc.P4RuntimeStub(self.channel)

    def set_pipeline_config(self, p4info_path, config_path):
        """设置 IPU 流水线配置"""
        req = p4runtime_pb2.SetForwardingPipelineConfigRequest()
        req.device_id = 0
        req.election_id.low = 1
        req.action = p4runtime_pb2.SetForwardingPipelineConfigRequest.VERIFY_AND_COMMIT

        # 读取 P4Info 和 BMv2 JSON
        with open(p4info_path, 'rb') as f:
            req.config.p4info.CopyFrom(p4info_pb2.FromString(f.read()))

        with open(config_path, 'rb') as f:
            req.config.bmv2_json_file = f.read()

        return self.stub.SetForwardingPipelineConfig(req)

    def write_vxlan_entry(self, vni, port, action_type='forward'):
        """写入 VXLAN 表项"""
        update = p4runtime_pb2.Update()
        update.type = p4runtime_pb2.Update.INSERT

        # 设置 table_entry
        entry = update.entity.table_entry
        entry.table_id = self.get_table_id('vxlan_table')

        # Match: VNI
        mf = entry.match.add()
        mf.field_id = self.get_field_id('vxlan_table', 'meta.vni')
        mf.exact.value = vni.to_bytes(3, 'big')

        # Action: vxlan_lookup
        action = entry.action.action
        action.action_id = self.get_action_id('vxlan_lookup')

        # Action params
        p = action.params.add()
        p.param_id = self.get_param_id('vxlan_lookup', 'port')
        p.value = port.to_bytes(2, 'big')

        # 写入
        req = p4runtime_pb2.WriteRequest()
        req.device_id = 0
        req.election_id.low = 1
        req.updates.append(update)

        return self.stub.Write(req)

    def write_l2_entry(self, vni, mac, port, action_type='l2_forward'):
        """写入 L2 转发表项"""
        update = p4runtime_pb2.Update()
        update.type = p4runtime_pb2.Update.INSERT

        entry = update.entity.table_entry
        entry.table_id = self.get_table_id('l2_table')

        # Match: VNI + MAC
        for field, value in [
            ('meta.vni', vni),
            ('inner_ethernet.dstAddr', mac),
        ]:
            mf = entry.match.add()
            mf.field_id = self.get_field_id('l2_table', field)
            mf.exact.value = value

        # Action
        action = entry.action.action
        action.action_id = self.get_action_id(action_type)

        req = p4runtime_pb2.WriteRequest()
        req.device_id = 0
        req.election_id.low = 1
        req.updates.append(update)

        return self.stub.Write(req)

    def read_counters(self, counter_name='ingress_counters.packets'):
        """读取计数器"""
        req = p4runtime_pb2.ReadRequest()
        entity = req.entities.add().counter_entry
        entity.counter_id = self.get_counter_id(counter_name)

        for resp in self.stub.Read(req):
            for entity in resp.entities:
                yield entity.counter_entry

    def packet_in_handler(self, callback):
        """处理 Packet-In (从 IPU 接收数据包)"""
        stream_req = p4runtime_pb2.StreamMessageRequest()

        # 启动 Packet-In stream
        def generate():
            while True:
                yield stream_req

        for resp in self.stub.PacketOut(generate()):
            if resp.HasField('packet'):
                callback(resp.packet)
```

---

## 6. IPU 与 vSwitch 卸载

### 6.1 OvS 卸载架构

```
OvS 卸载到 IPU:
===============

传统 OvS (CPU):
+----------+
|   Host   |
| +------+ |
| | OvS  | | <--- CPU 100% 使用
| +------+ |
| | vNIC | |
+----------+

OvS 卸载 (IPU Fxp):
+----------+     +----------+
|   Host   | <==>|   IPU    |
| +------+ | DMA| +------+ |
| |vNIC   |======>>| Fxp  | | <--- P4 程序处理
| +------+ |     | | vSwitch||
+----------+     | +------+ |
                 +----------+
```

### 6.2 IPU vSwitch 功能

```c
// IPU vSwitch 功能列表
// P4 程序实现的功能:

1. VXLAN / GENEVE 隧道
   - Tunnel encap/decap
   - VNI -> Port 映射

2. L2 转发
   - MAC learning
   - MAC aging
   - VLAN隔离

3. L3 转发
   - ARP handling
   - Routing
   - ECMP

4. ACL / QoS
   - Port ACL
   - VM ACL
   - DSCP remarking

5. Security
   - DHCP snooping
   - ND detection
   - Anti-spoofing
```

### 6.3 IPU vSwitch 性能

```
OvS 卸载性能对比:
=================

| 指标              | OvS (CPU)  | IPU Fxp    | 提升     |
|-------------------|------------|------------|----------|
| Throughput       | ~5 Mpps   | ~200 Mpps | 40x     |
| Latency          | ~50 μs    | ~5 μs     | 10x     |
| CPU Usage        | 100% (8C) | ~5%       | 减少 95% |
| Throughput/Watt  | 低        | 高        | ~10x    |
```

---

## 7. IPU 存储卸载

### 7.1 NVMe-oF 卸载

```
NVMe-oF 卸载架构:
=================

传统 (CPU 处理):
+----------+         +----------+
|  Host    | <=====> |  Target  |
| +------+ |  TCP    | +------+ |
| | NVMe | |======>> | | NVMe | |
| +------+ |         | +------+ |
+----------+         +----------+
CPU 处理 TCP/IP

卸载 (IPU 处理):
+----------+         +----------+
|  Host    | <=====> |   IPU    | <=====> |  Target  |
| +------+ |  PCIe  | | TCP/IP  |  RDMA   | +------+ |
| | NVMe | |======>> | | Offload|======>> | | NVMe | |
| +------+ |         | +------+ |         | +------+ |
+----------+         +----------+         +----------+
```

### 7.2 IPU 存储功能

```c
// IPU 存储卸载 P4 程序片段
control StorageOffload(inout headers h,
                       inout metadata m,
                       in PSA_ingress_input_metadata_t istd,
                       inout PSA_ingress_output_metadata_t ostd) {

    // NVMe/TCP 解析
    action parse_nvme_tcp() {
        // NVMe over TCP 头部解析
        // 发现 NVMf 子ystem ID / Namespace ID
    }

    // 存储镜像/复制
    action storage_mirror(bit<32> target_addr) {
        // 将 I/O 复制到指定目标
        // 用于同步/备份
    }

    // NVMe QoS
    action nvme_qos(bit<8> priority) {
        // 基于 Namespace/扇区设置 QoS
        ostd.qos_class = priority;
    }

    table storage_offload_table {
        key = {
            h.tcp.dstPort: exact;  // 4420 (NVMe-TCP)
        }
        actions = {
            parse_nvme_tcp;
            storage_mirror;
            nvme_qos;
        }
    }

    apply {
        storage_offload_table.apply();
    }
}
```

---

## 8. IPU 开发与调试

### 8.1 IPU 开发环境

```bash
#!/bin/bash
# IPU 开发环境设置

# 1. 安装 IPU SDE
tar -xzf intel-ipu-sde-3.0.tar.gz
cd intel-ipu-sde-3.0
sudo ./install.sh

# 2. 设置环境变量
export IPU_SDE=/opt/intel-ipu-sde
export IPU_SDE_INSTALL=$IPU_SDE/install
export PATH=$PATH:$IPU_SDE/bin:$IPU_SDE/sbin
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:$IPU_SDE/lib

# 3. 编译 P4 程序
cd $IPU_SDE/pkgs/p4-examples/ipu_vswitch
make -j$(nproc)

# 4. 运行 IPU 模拟器
ipu_switchd --bf-sde=$IPU_SDE \
            --install-dir=$IPU_SDE_INSTALL \
            --conf-file=ipu_vswitch.conf \
            --init=usd \
            --log-level=info

# 5. 连接 CLI
ipu_switchd_cli --port 9090
```

### 8.2 IPU 调试工具

```bash
#!/bin/bash
# IPU 调试命令

# 1. 查看 Fxp 表项
ipu_switchd_cli << 'EOF'
table_dump vxlan_table
table_dump l2_table
table_dump l3_table
table_dump acl_table
EOF

# 2. 查看计数器
ipu_switchd_cli << 'EOF'
counter_dump ingress_counters.packets
counter_dump ingress_counters.bytes
counter_dump egress_counters.packets
EOF

# 3. 查看寄存器
ipu_switchd_cli << 'EOF'
register_dump flow_counters 0
register_dump vxlan_vni_mapping 0
EOF

# 4. 抓包 (通过 IPU)
ipu_switchd_cli << 'EOF'
pdump start
EOF
sleep 10
ipu_switchd_cli << 'EOF'
pdump stop
EOF

# 5. 查看 IPU 状态
ipu_switchd_cli << 'EOF'
show port all
show fxp resources
show tm queues
EOF
```

### 8.3 IPU 常见问题

```
IPU 常见问题与排查:
===================

1. P4 程序编译失败
   - 检查 P4Info 兼容性
   - 确认资源使用在限制内
   - 查看编译器错误信息

2. 表项下发不生效
   - 检查 P4Runtime 连接
   - 确认 election_id 正确
   - 验证 table_id 和 field_id

3. 性能问题
   - 检查队列深度
   - 确认 DMA 带宽
   - 查看是否有甲酸

4. Packet-In 不工作
   - 检查 Digest 配置
   - 确认 Clone Session 正确
   - 查看 Dcp 日志
```

---

## 9. 总结

Intel IPU 是 P4 在智能网卡/DPU 上的应用：

1. **定位**：卸载基础设施工作负载到专用硬件
2. **架构**：Fxp (P4 数据平面) + Dcp (控制平面)
3. **应用**：vSwitch 卸载、NVMe-oF、安全功能
4. **优势**：释放 CPU、降低延迟、提高性能

**下一章**我们将探讨 **Broadcom** 的 P4 交换机方案，了解另一家主要交换芯片厂商的实现。
