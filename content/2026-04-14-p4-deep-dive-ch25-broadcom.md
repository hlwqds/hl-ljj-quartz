---
title: "P4 深度探索 (二十五)：Broadcom——DNX/Maple 交换芯片、Broadcom P4 编译器、Jericho/Ramon"
date: 2026-04-14
tags: [p4, series, broadcom, dnx, maple, jericho, ramon, switch, chip, architecture, open-npu]
description: "Broadcom P4 深度解析——DNX/Maple 交换芯片架构、Jericho/Ramon 系列、Broadcom P4 编译器 (bcmrt) 、OpenNPU、StrataXGS/Tomahawk 与 P4 的结合"
---

> [!info] P4 深度探索系列
> 0. [[2026-04-14-p4-deep-dive-series-index|全栈学习路径总览]]
> 1. [[2026-04-14-p4-deep-dive-ch1-p4-overview|第一章：P4 概述——诞生背景与协议无关包处理]]
> 2. [[2026-04-14-p4-deep-dive-ch2-p4-architecture|第二章：P4 架构模型——PSA/V1Model、Ingress/Egress]]
> 3. [[2026-04-14-p4-deep-dive-ch3-p4-vs-ebpf|第三章：P4 vs eBPF——适用场景与硬件/软件对比]]
> 4. [[2026-04-14-p4-deep-dive-ch4-p4-program|第四章：P4 程序结构——Header/Parser/Control/Table]]
> 5. [[2026-04-14-p5-deep-dive-ch5-p4-types|第五章：P4 类型系统——bit/varbit/enum/header/struct/tuple]]
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
> 20. [[2026-04-14-p4-deep-dive-ch20-multicast|第二十章：Multicast 与 Clone——多播组、Packet Clone、会话复制与镜像]]
> 21. [[2026-04-14-p4-deep-dive-ch21-bmv2|第二十一章：BMv2——Behavioral Model v2、软件交换机]]
> 22. [[2026-04-14-p4-deep-dive-ch22-tofino|第二十二章：Intel Tofino——Tofino 1 芯片架构、Pipeline、RAM/TCAM 资源]]
> 23. [[2026-04-14-p4-deep-dive-ch23-tofino2|第二十三章：Tofino 2——12.8Tbps P4-16 交换芯片、Flex Pipes]]
> 24. [[2026-04-14-p4-deep-dive-ch24-intel-ipu|第二十四章：Intel IPU——IPU/DPU、基础设施处理单元、Fxp/Dcp]]
> 25. **第二十五章：Broadcom——DNX/Maple 交换芯片、Broadcom P4 编译器、Jericho/Ramon**

---

## 1. 概述：Broadcom 交换芯片

**Broadcom** 是全球最大的交换芯片供应商，其交换芯片广泛应用于数据中心、电信和企业网络。Broadcom 采用 **DNX (Digital Network Architecture)** 和 **OpenNPU** 架构。

```
Broadcom 交换芯片产品线:
=========================

StrataXGS Series (传统 ASIC):
+=============+=============+=============+=============+
| Trident 4   | Tomahawk 4 | Jericho 2   | Ramon       |
+-------------+-------------+-------------+-------------+
| 12.8 Tbps   | 25.6 Tbps   | 10 Tbps    | 25 Tbps     |
| 64-128 x 100G| 256 x 100G  | 128 x 100G | 256 x 100G  |
| L2/L3 Switch| Router      | Fabric     | Switch/Router|
+-------------+-------------+-------------+-------------+
| OpenNPU     | OpenNPU     | OpenNPU    | OpenNPU     |
| (P4)        | (P4)        | (P4)       | (P4)        |
+=============+=============+=============+=============+

所有现代 Broadcom 交换芯片支持 P4 编程
```

### 1.1 Broadcom P4 支持

| 架构 | 支持 P4 | 说明 |
|------|---------|------|
| **DNX** | P4-14 主要 | 主要支持厂家定义 API |
| **OpenNPU** | P4-16 完整 | 开放可编程架构 |
| **Sapphire** | P4-16 | 最新架构 |

### 1.2 Broadcom vs Intel Tofino

| 维度 | Broadcom DNX | Intel Tofino |
|------|--------------|--------------|
| **市场份额** | ~70% | ~15% |
| **P4 支持** | OpenNPU | TNA (Native) |
| **表容量** | 大 | 中等 |
| **TCAM** | 原生 | 原生 |
| **编译工具** | bcmrt | p4c-bft |
| **控制面** | OpenSDK | SDE |
| **价格** | 较低 | 较高 |

---

## 2. DNX 架构详解

### 2.1 DNX 整体架构

**DNX (Digital Network Architecture)** 是 Broadcom 交换芯片的底层架构：

```
Broadcom DNX 架构:
==================

+==========================================================================+
||                           PACKET FLOW                                   ||
+==========================================================================+

    Ingress Port
         |
         v
+---------------------------+
|      ITP (Ingress         |
|      Traffic Processor)   |
+---------------------------+
         |
         v
+---------------------------+
|      Parser (PP)          |
|      (Programmable        |
|       Parser)             |
+---------------------------+
         |
         v
+---------------------------+
|      Ingress Pipeline     |
|  +---------------------+  |
|  |  ETM (Early          |  |
|  |  Transparent          |  |
|  |  Modification)        |  |
|  +---------------------+  |
|  |                     |  |
|  |  +---------------+  |  |
|  |  |    TCAM       |  |  |
|  |  |  (Exact/LPM/  |  |  |
|  |  |   Ternary)    |  |  |
|  |  +---------------+  |  |
|  |  |    SRAM       |  |  |
|  |  |  (Exact)      |  |  |
|  |  +---------------+  |  |
|  |                     |  |
|  +---------------------+  |
|                           |
|  +---------------------+  |
|  |   ALU (Action       |  |
|  |   Engine)           |  |
|  +---------------------+  |
|                           |
+---------------------------+
         |
         v
+---------------------------+
|      Traffic Manager      |
|  +---------------------+  |
|  |    Queues           |  |
|  |    (UC/MC)          |  |
|  +---------------------+  |
|  |    Scheduling       |  |
|  |    (SP/WFQ)         |  |
|  +---------------------+  |
|  |    Fabric IF        |  |
|  +---------------------+  |
+---------------------------+
         |
         v
+---------------------------+
|      Egress Pipeline      |
|  +---------------------+  |
|  |   Deparser          |  |
|  +---------------------+  |
|  |   ETM (Egress       |  |
|  |   Transparent       |  |
|  |   Modification)     |  |
|  +---------------------+  |
+---------------------------+
         |
         v
    Egress Port

+==========================================================================+
||                         KEY COMPONENTS                                   ||
+==========================================================================+

| Component    | Description                                           |
|--------------|------------------------------------------------------|
| ITP          | Ingress Traffic Processor - 入口处理                   |
| PP           | Programmable Parser - 可编程解析器                      |
| TCAM         | Ternary CAM - 三元匹配                                 |
| SRAM         | Static RAM - 精确匹配                                  |
| ALU          | Action Logic Unit - 动作执行                           |
| TM           | Traffic Manager - 队列和调度                          |
| ETM          | Early/Embedded Transparent Modification - 早期修改     |
| MMU          | Memory Management Unit - 内存管理                      |
```

### 2.2 DNX Pipeline 阶段

```
DNX Ingress Pipeline 阶段:
===========================

Stage 0-3:   Parsing (可编程状态机)
Stage 4-7:   Key Generation (Hash + Field Selection)
Stage 8-11:  TCAM Lookup (LPM/Ternary)
Stage 12-15: SRAM Lookup (Exact)
Stage 16-19: Action Execution (ALU)
Stage 20-23: Hdr Modification (Field Modification)
Stage 24-27: Post-processing (Stats, Mirror)

DNX Egress Pipeline 阶段:
=========================

Stage 0-3:   Parsing (可选)
Stage 4-7:   Field Modification
Stage 8-11:  ACL Check
Stage 12-15: Stats Update
Stage 16-19: Mirror/Clone
Stage 20-23: Deparse
```

---

## 3. OpenNPU 架构

### 3.1 OpenNPU 概述

**OpenNPU** 是 Broadcom 的 P4 可编程架构，与 Intel TNA/PSA 类似：

```
OpenNPU vs TNA 对比:
====================

| 组件          | OpenNPU          | TNA              |
|---------------|------------------|------------------|
| 架构风格      | PSA-based        | TNA-native       |
| Parser        | 可编程           | 可编程           |
| MAU           | Stages 0-23     | Stages 0-31      |
| Hash          | HASH-A/B/C       | Hash #0-3        |
| TCAM          | 外部或集成        | 集成             |
| SRAM          | 集成             | 集成             |
| TM            | 集成             | 集成             |
| P4 版本       | P4-16            | P4-16            |
| 编译器        | bcmrt            | p4c-bft          |
```

### 3.2 OpenNPU 程序结构

```c
// OpenNPU P4-16 程序示例
#include <core.p4>
#include <dnx.p4>  // Broadcom DNX 头文件

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

struct headers_t {
    ethernet_t ethernet;
    ipv4_t     ipv4;
    tcp_t      tcp;
}

struct metadata_t {
    bit<32> nexthop_id;
    bit<9>  egress_port;
}

// ============== Parser ==============
parser IngressParser(packet_in packet,
                    out headers h,
                    inout metadata m,
                    in dnx_parser_input_metadata_t istd) {
    
    state start {
        packet.extract(h.ethernet);
        transition select(h.ethernet.etherType) {
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
    
    state parse_tcp {
        packet.extract(h.tcp);
        transition accept;
    }
    
    state parse_udp {
        transition accept;
    }
}

// ============== Control ==============
control Ingress(inout headers h,
                inout metadata m,
                in dnx_input_metadata_t istd,
                inout dnx_output_metadata_t ostd) {
    
    // L3 转发
    action ipv4_forward(PortId_t port, bit<8> ttl_val) {
        h.ipv4.ttl = ttl_val;
        ostd.egress_port = port;
    }
    
    // Drop
    action drop() {
        ostd.drop = true;
    }
    
    // 路由表
    table ipv4_fib {
        key = {
            h.ipv4.dstAddr: lpm;
        }
        actions = {
            ipv4_forward;
            drop;
        }
        default_action = drop();
        size = 128K;
    }
    
    // ACL
    table acl_filter {
        key = {
            h.ipv4.srcAddr: ternary;
            h.ipv4.dstAddr: ternary;
            h.tcp.srcPort: ternary;
            h.tcp.dstPort: ternary;
        }
        actions = {
            allow;
            drop;
        }
        size = 32K;
    }
    
    apply {
        acl_filter.apply();
        ipv4_fib.apply();
    }
}

// ============== Deparser ==============
control IngressDeparser(packet_out packet,
                       inout headers h,
                       in metadata m,
                       in dnx_output_metadata_t ostd) {
    apply {
        packet.emit(h.ethernet);
        packet.emit(h.ipv4);
        packet.emit(h.tcp);
    }
}

// ============== Pipeline ==============
Pipeline(IngressParser(), Ingress(), IngressDeparser()) ip;
OpenNPU_Switch(ip, Egress()) main;
```

---

## 4. Jericho 系列详解

### 4.1 Jericho 规格

**Jericho** 是 Broadcom 的高端交换/路由芯片系列：

```
Jericho 系列:
=============

| 型号           | Jericho   | Jericho 2 | Jericho 2C+ |
|----------------|-----------|-----------|--------------|
|----------------|-----------|-----------|--------------|
| Bandwidth      | 4 Tbps   | 10 Tbps   | 6.4 Tbps     |
| Port Config    | 64 x 100G| 128 x 100G| 64 x 100G    |
|----------------|-----------|-----------|--------------|
| MAU Stages     | 24       | 24        | 24           |
| TCAM           | 32 Mb    | 64 Mb     | 32 Mb        |
| SRAM           | 64 MB    | 128 MB    | 64 MB        |
|----------------|-----------|-----------|--------------|
| Packet Buffer  | 64 MB    | 128 MB    | 64 MB        |
| Fabric         | 6.4T     | 12.8T     | 6.4T         |
|----------------|-----------|-----------|--------------|
| OpenNPU        | Yes      | Yes       | Yes          |
| DDR IF         | Yes      | Yes       | Yes          |
+--------------------------------------------------+

Jericho 主要用于:
- 运营商路由器
- 数据中心骨干
- 超级核心交换
```

### 4.2 Jericho 架构

```
Jericho 架构图:
===============

+==========================================================================+
||                            JERICHO CHIP                                  ||
+==========================================================================+

Ingress Side:
+-------------+    +-------------+    +-------------+
|   Port IF   |--->|  Ingress   |--->|  Ingress    |
|  (100GE)    |    |  Parser    |    |  Pipeline   |
+-------------+    +-------------+    +-------------+
                                            |
                                            v
                                    +-------------+
                                    |    TCAM     |
                                    |   + SRAM     |
                                    +-------------+
                                            |
                                            v
                                    +-------------+
                                    |  ALU/Action |
                                    |   Engine    |
                                    +-------------+
                                            |
                                            v
+==========================================================================+
||                         TRAFFIC MANAGER                                  ||
+==========================================================================+
||                                                                           ||
||  +------------------+   +------------------+   +------------------+     ||
||  |  UC Queue       |   |  MC Queue        |   |  Fabric          |     ||
||  |  16K queues     |   |  1K groups       |   |  Crossbar        |     ||
||  +------------------+   +------------------+   +------------------+     ||
||                                                                           ||
+==========================================================================+
                                            |
Egress Side:                                  v
+-------------+    +-------------+    +-------------+
|   Port IF   |<---|  Egress     |<---|  Egress     |
|  (100GE)    |    |  Pipeline   |    |  Deparser   |
+-------------+    +-------------+    +-------------+

Jericho 特点:
- 内置 DDR4 控制器 (用于 large table)
- 集成 Fabric 核心
- 支持 OpenNPU P4
```

---

## 5. Ramon 架构

### 5.1 Ramon 规格

**Ramon** 是 Broadcom 的高端模块化交换芯片：

```
Ramon 系列:
===========

| 型号           | Ramon     | Ramon 2   |
|----------------|-----------|-----------|
|----------------|-----------|-----------|
| Bandwidth      | 25.6 Tbps| 51.2 Tbps |
| Port Config    | 256 x 100G| 512 x 100G|
|----------------|-----------|-----------|
| MAU Stages     | 24        | 24        |
| TCAM           | 128 Mb    | 256 Mb    |
| SRAM           | 256 MB    | 512 MB    |
|----------------|-----------|-----------|
| Packet Buffer  | 256 MB    | 512 MB    |
|----------------|-----------|-----------|
| Chiplet        | Yes       | Yes       |
| OpenNPU        | Yes       | Yes       |
+----------------------------------------+

Ramon 主要用于:
- 超大规模数据中心
- 超级核心交换
- 电信骨干网
```

### 5.2 Ramon Chiplet 架构

```
Ramon Chiplet 设计:
====================

Ramon 采用模块化 Chiplet 设计:

+==========================================================================+
||                         RAMON PACKAGE                                    ||
+==========================================================================+

  +-----------+   +-----------+   +-----------+   +-----------+
  | Chiplet 0 |   | Chiplet 1 |   | Chiplet 2 |   | Chiplet 3 |
  | 6.4 T    |   | 6.4 T    |   | 6.4 T    |   | 6.4 T    |
  +-----+-----+   +-----+-----+   +-----+-----+   +-----+-----+
        |               |               |               |
        v               v               v               v
  +---------------------------------------------------------------+
  |                    Inter-Chiplet Fabric                       |
  |                    (2.4 Tbps per direction)                   |
  +---------------------------------------------------------------+
        |               |               |               |
        v               v               v               v
  +-----------+   +-----------+   +-----------+   +-----------+
  | SerDes 0  |   | SerDes 1  |   | SerDes 2  |   | SerDes 3  |
  | 64 x 100G |   | 64 x 100G |   | 64 x 100G |   | 64 x 100G |
  +-----------+   +-----------+   +-----------+   +-----------+

优势:
- 更高集成度
- 更低功耗
- 更好的可扩展性
```

---

## 6. Broadcom P4 编译器

### 6.1 bcmrt 编译器

**bcmrt (Broadcom Runtime)** 是 Broadcom 的 P4 编译工具链：

```bash
#!/bin/bash
# Broadcom P4 编译流程

# 1. 设置环境
export BCM_RT=/opt/broadcom/bcmrt
export PATH=$PATH:$BCM_RT/bin
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:$BCM_RT/lib

# 2. 编译 P4 程序
bcmrt_compile -p4v 16 \
    -p4c bcmrt \
    -o output/ \
    -DDEVICE=jericho2 \
    my_program.p4

# 编译输出:
#   my_program.bc         (字节码)
#   my_program.bcmrt.json (配置)
#   my_program.p4info.txt (P4Info)

# 3. 生成设备配置
bcmrt_build_config \
    -device jericho2 \
    -program my_program.bc \
    -output my_program.config

# 4. 烧录到设备
bcmrt_flash \
    -device 0 \
    -config my_program.config
```

### 6.2 Broadcom 特有的 P4 扩展

```c
// Broadcom 特有的 P4 扩展

#include <dnx.p4>

// ============== Broadcom 特有的 Header ==============

// 芯片内部元数据
@dk_main.int_header
header dnx_main_int_header_t {
    bit<32> timestamp;
    bit<9>  ingress_port;
    bit<9>  egress_port;
    bit<32> queue_id;
}

// 通道化信息
@dk_channel
header dnx_channel_header_t {
    bit<8> channel_id;
    bit<8> channel_type;
}

// ============== Broadcom 特有的 Action ==============

control BroadcomIngress(inout headers h,
                        inout metadata m,
                        in dnx_input_metadata_t istd,
                        inout dnx_output_metadata_t ostd) {
    
    // Broadcom 特有的动作
    
    // 读取芯片内部计数器
    action read_dnx_counter() {
        // DNX counter read
        bit<64> counter_value;
        counter32x64.read(counter_value, istd.src_port);
    }
    
    // Fabric 操作
    action send_to_fabric(bit<8> dest_chip, bit<8> dest_port) {
        // 通过 Fabric 发送到其他芯片
        dnx_fabric_header.setValid();
        dnx_fabric_header.dest_chip = dest_chip;
        dnx_fabric_header.dest_port = dest_port;
    }
    
    // FAP (Fabric Adaptation Processor)
    action process_in_fap() {
        // 使用 FAP 进行复杂处理
        // FAP 是 Broadcom 的辅助处理器
    }
    
    // 镜像到 OAMP (Operations, Administration, Maintenance Processor)
    action mirror_to_oamp() {
        // 镜像到 CPU/OAMP 端口
        dnx_oamp_header.setValid();
        dnx_oamp_header.mirror_type = 1;
    }
}
```

### 6.3 Broadcom SDK (OpenSDK)

```bash
#!/bin/bash
# Broadcom OpenSDK 安装与使用

# 1. 安装 OpenSDK
tar -xzf opensdk-12.0.tar.gz
cd opensdk-12.0
sudo ./install.sh

# 2. 设置环境变量
export OPENSDK=/opt/broadcom/opensdk
export PATH=$PATH:$OPENSDK/bin
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:$OPENSDK/lib

# 3. 查看设备
opensdk-cli show devices

# 4. 连接设备
opensdk-cli connect -d 0

# 5. 加载 P4 程序
opensdk-cli load -p my_program.bc

# 6. 添加表项
opensdk-cli table add ipv4_fib ipv4_forward 10.0.0.0/8 => 2
opensdk-cli table add mac_table l2_forward 00:00:00:00:01:02 => 3

# 7. 读取统计
opensdk-cli counter read ingress_port_stats 0
```

---

## 7. Broadcom 表类型

### 7.1 DNX 表资源

```
DNX 表类型:
===========

| 表类型        | 存储      | 匹配方式       | 典型用途            |
|---------------|-----------|----------------|---------------------|
| LPM           | TCAM      | Longest Prefix | 路由表              |
| Exact         | SRAM      | 精确匹配       | MAC 表              |
| Ternary      | TCAM      | 0/1/*         | ACL                 |
| Hash          | SRAM      | Hash 查找     | Flow table          |
| Range         | TCAM      | 范围           | Port ACL            |
| Database     | DRAM      | 复杂查找       | Large table         |

DNX Hash 算法:
+-------------+
| HASH-A     |  CRC16, CRC32
| HASH-B     |  xxHash, SipHash
| HASH-C     |  AES-based
+-------------+
```

### 7.2 Direct vs Indirect 表

```c
// DNX Direct 表 (动作在表项中)
table direct_table {
    key = { h.ipv4.dstAddr: lpm; }
    actions = { ipv4_forward; drop; }
    size = 64K;
    
    // Direct 资源
    @dx profile "ingress";
}

// DNX Indirect 表 (通过 Action Profile)
@阳光
action_profile my_profile {
    action_pool_size = 16K;
    max_group_size = 4;
}

table indirect_table {
    key = { h.ipv4.srcAddr: exact; }
    actions = { ipv4_forward; drop; }
    size = 256K;
    @dx
    profile = my_profile;
}

// DNX Selector 表 (ECMP/负载均衡)
table selector_table {
    key = { h.ipv4.srcAddr: exact; }
    actions = { NoAction; }
    size = 32K;
    @dx
    selector = my_selector_profile;
}
```

---

## 8. Broadcom TM (Traffic Manager)

### 8.1 DNX TM 架构

```
DNX TM 架构:
============

Ingress TM:
+--------+    +--------+    +--------+    +--------+
| ITM    |--> | MMU    |--> |queues  |--> | Fabric |
| (Ingress|    |(Memory |    |(SP/WFQ)|    | IF     |
|  Traffic|    | Manage)|    |        |    |        |
|  Manage)|    +--------+    +--------+    +--------+
+--------+

Egress TM:
+--------+    +--------+    +--------+    +--------+
| Fabric |--> | MMU    |--> |queues  |--> |ETM     |
| IF     |    |(Memory |    |(SP/WFQ)|    |(Egress |
|        |    | Manage)|    |        |    | Traffic|
|        |    +--------+    +--------+    | Manage)|
+--------+                                +--------+

DNX TM 特性:
- 层次化队列
- SP/WFQ/ETS/DWRR
- Per-port shaping
- Head-of-line blocking prevention
- Lossless Ethernet (PFC)
```

### 8.2 DNX QoS 实现

```c
// DNX QoS 实现
control DNXQoS(inout headers h,
               inout metadata m,
               in dnx_input_metadata_t istd,
               inout dnx_output_metadata_t ostd) {
    
    // DSCP -> TC mapping
    action dscp_to_tc(bit<3> tc, bit<2> color) {
        ostd.qos_class = tc;
        ostd.color = color;
    }
    
    table dscp_map {
        key = { h.ipv4.diffserv: ternary; }
        actions = { dscp_to_tc; }
        size = 64;
    }
    
    // TC -> Queue mapping
    action tc_to_queue(bit<5> queue_id) {
        ostd.enq_qid = queue_id;
    }
    
    table tc_map {
        key = { ostd.qos_class: exact; }
        actions = { tc_to_queue; }
        size = 8;
    }
    
    // 入口应用
    apply {
        dscp_map.apply();
        tc_map.apply();
    }
}
```

---

## 9. Broadcom 与云厂商

### 9.1 主要云厂商采用

```
云厂商 Broadcom 采用情况:
==========================

Google:
- 使用 Broadcom Jericho/Jericho2
- 内部称为 "Brite" 芯片
- 在 Jupiter Fabric 中部署

Microsoft:
- 使用 Broadcom Tomahawk/Trident
- 称为 "Welch" 芯片
- 在 Azure 交换机中使用

Meta:
- 使用 Broadcom Tomahawk 3/4
- 称为 "Kitfox" 芯片
- 用于 Openstep fabric

Amazon:
- 使用自研芯片 (但也用 Broadcom)
- 部分交换机使用 Broadcom

Apple:
- 使用 Broadcom 交换芯片
- 用于数据中心网络
```

### 9.2 云厂商 P4 实践

```c
// 云厂商在 Broadcom 上的 P4 定制

// 1. 负载均衡 (Google 风格)
action ecmp_select(bit<16> ecmp_group_id) {
    // Google 使用 HASH 选择 ECMP 路径
    bit<16> hash_result;
    hash<bit<16>>(HashAlgorithm.crc16)(
        hash_result,
        HashAlgorithm.crc16,
        { 
            h.ipv4.srcAddr, 
            h.ipv4.dstAddr, 
            h.tcp.srcPort, 
            h.tcp.dstPort 
        }
    );
    
    // 使用 selector 表选择 nexthop
    // 动作数据存储在 action data 中
}

// 2. 拥塞控制 (Microsoft 风格)
action congestion_mark(bit<2> ecn_val) {
    // Microsoft ECN 标记
    h.ipv4.diffserv[1:0] = ecn_val;
    
    // 记录到计数器
    direct_meter<bit<2>>(MeterType.packets) congestion_meter;
    congestion_meter.read(ostd.drop, h.ipv4.diffserv);
}

// 3. 网络遥测 (Meta 风格)
action int_insert() {
    // 插入 INT 元数据
    dnx_int_header.setValid();
    dnx_int_header.switch_id = m.local_switch_id;
    dnx_int_header.ingress_port = istd.src_port;
    dnx_int_header.egress_port = ostd.dst_port;
    dnx_int_header.queue_depth = ostd.enq_depth;
}
```

---

## 10. Broadcom 开发与调试

### 10.1 开发工具链

```bash
#!/bin/bash
# Broadcom 开发环境设置

# 1. 安装 bcmrt SDK
tar -xzf bcmrt-sdk-12.0.tar.gz
cd bcmrt-sdk-12.0
sudo ./install.sh

# 2. 设置环境变量
export BCM_RT_SDK=/opt/broadcom/bcmrt-sdk
export PATH=$PATH:$BCM_RT_SDK/bin:$BCM_RT_SDK/sbin
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:$BCM_RT_SDK/lib64

# 3. 查看可用设备
bcmrt_cli list_devices

# 4. 创建模拟器实例
bcm_sim -device jericho2 -name my_sim &

# 5. 连接模拟器
bcmrt_cli connect -n my_sim

# 6. 编译 P4 程序
bcmrt_compile -p4v 16 \
    -device jericho2 \
    -o /tmp/output/ \
    my_program.p4

# 7. 加载程序
bcmrt_cli load -p /tmp/output/my_program.bc

# 8. 配置表项
bcmrt_cli table add ipv4_fib ipv4_forward 10.0.0.0/8 => 2
```

### 10.2 调试命令

```bash
#!/bin/bash
# Broadcom 调试命令

# 连接设备
bcmrt_cli connect -d 0

# 查看流水线状态
bcmrt_cli show pipeline

# 查看表项
bcmrt_cli table dump ipv4_fib
bcmrt_cli table dump mac_table
bcmrt_cli table dump acl

# 查看统计
bcmrt_cli counter read_all
bcmrt_cli stat show port 0

# 查看队列
bcmrt_cli queue show
bcmrt_cli tm status

# 抓包
bcmrt_cli packet dump start -port 0
sleep 10
bcmrt_cli packet dump stop

# 寄存器读取
bcmrt_cli register read switch_id
bcmrt_cli register read port_status

# 日志
bcmrt_cli debug log -level 4
```

### 10.3 常见问题

```
Broadcom 常见问题与排查:
=========================

1. 编译失败
   - 检查 P4 程序语法
   - 确认使用的架构正确 (dnx.p4)
   - 查看 bcmrt 错误日志

2. 表项不下发
   - 确认 P4Info 正确
   - 检查 table_id 和 field_id
   - 验证 BCM SDK 版本

3. 性能问题
   - 检查 TCAM 利用率
   - 确认队列配置
   - 查看是否有甲酸

4. 芯片不识别
   - 检查 PCIe 连接
   - 确认固件版本
   - 重置芯片
```

---

## 11. 总结

Broadcom 是 P4 可编程交换芯片的重要厂商：

1. **市场份额**：全球最大的交换芯片供应商
2. **OpenNPU**：P4 可编程架构
3. **产品线**：Trident/Tomahawk/Jericho/Ramon
4. **工具链**：bcmrt 编译器和 OpenSDK

**Part V: Implementations** 到此结束。我们覆盖了：
- **Ch21**: BMv2 软件交换机
- **Ch22**: Intel Tofino 1 架构
- **Ch23**: Intel Tofino 2 架构
- **Ch24**: Intel IPU/DPU
- **Ch25**: Broadcom DNX/Maple

**下一部分 (Part VI)** 将探讨 **P4Runtime 与控制面**，包括 P4Runtime gRPC、NETCONF/gNMI、Stratum 白盒交换机等主题。
