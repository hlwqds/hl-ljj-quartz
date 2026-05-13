---
title: "P4 深度探索 (二十三)：Tofino 2——12.8Tbps P4-16 交换芯片、Flex Pipes、MauSplit"
date: 2026-04-14
tags: [p4, series, tofino2, intel, tofino, architecture, flex-pipe, mau-split, 12.8t, p4-16, chip]
description: "Intel Tofino 2 深度解析——12.8Tbps P4-16 交换芯片、Flex Pipes 灵活管道、MAU Split、Packet Cryo、Secure Vector Processing、Extended Pipeline"
---

> [!info] P4 深度探索系列
> 0. [[2026-04-14-p4-deep-dive-series-index|全栈学习路径总览]]
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
> 20. [[2026-04-14-p4-deep-dive-ch20-multicast|第二十章：Multicast 与 Clone——多播组、Packet Clone、会话复制与镜像]]
> 21. [[2026-04-14-p4-deep-dive-ch21-bmv2|第二十一章：BMv2——Behavioral Model v2、软件交换机]]
> 22. [[2026-04-14-p4-deep-dive-ch22-tofino|第二十二章：Intel Tofino——Tofino 1 芯片架构、Pipeline、RAM/TCAM 资源]]
> 23. **第二十三章：Tofino 2——12.8Tbps P4-16 交换芯片、Flex Pipes、MAU Split**

---

## 1. 概述：Tofino 2 定位

**Intel Tofino 2** 是 Intel 继 Tofino 1 之后推出的第二代 P4 可编程交换芯片，2019 年发布。相较于 Tofino 1，Tofino 2 在**容量、性能、灵活性**上都有显著提升。

```
Tofino 系列演进:
================

Tofino 1 (2016)          Tofino 2 (2019)          Tofino 3 (2022)
+===============+       +===============+       +===============+
|   6.5 Tbps    |       |   12.8 Tbps   |       |   25.6 Tbps   |
|   64 x 100G   |       |   128 x 100G  |       |   256 x 100G  |
+---------------+       +---------------+       +---------------+
| 16nm Process  |       |  16nm Process |       |   7nm Process |
+---------------+       +---------------+       +---------------+
| 32 MAU Stages |       |  32 + 16      |       |   48 stages   |
| (Per Pipe)   |       |  (MAU Split)  |       |  (More ALUs)  |
+---------------+       +---------------+       +---------------+
| 4 Pipes       |       |  4 Pipes     |       |   4 Pipes     |
+---------------+       +---------------+       +---------------+
| TNA Only      |       | TNA + PSA    |       | TNA + PSA    |
+---------------+       +---------------+       +---------------+
| Fixed Arch   |       | Flex Pipes   |       | Flex Pipes   |
+===============+       +===============+       +===============+
```

### 1.1 Tofino 2 的关键升级

| 特性 | Tofino 1 | Tofino 2 | 提升 |
|------|-----------|-----------|------|
| **带宽** | 6.5 Tbps | 12.8 Tbps | **2x** |
| **端口密度** | 64 x 100G | 128 x 100G | **2x** |
| **MAU Stages** | 32 | 48 (32+16 MAU Split) | **1.5x** |
| **TCAM** | 64 Mb | 128 Mb | **2x** |
| **SRAM** | 128 MB | 256 MB | **2x** |
| **P4 支持** | P4-14 主要 | P4-16 Full | **完整** |
| **架构** | Fixed | Flex Pipes | **灵活** |
| **Secure Vector** | No | Yes | **新增** |

---

## 2. Tofino 2 芯片规格

### 2.1 型号规格表

```
Tofino 2 型号规格:
==================

| 型号           | 12.8T    | 10.0T    | 8.0T     | 6.5T     |
|----------------|----------|----------|----------|----------|
|----------------|----------|----------|----------|----------|
| Total BW       | 12.8 Tbps| 10.0 Tbps| 8.0 Tbps | 6.5 Tbps |
| 100GE Ports    | 128      | 100      | 80       | 64       |
|----------------|----------|----------|----------|----------|
| MAU Stages (I) | 32       | 32       | 32       | 32       |
| MAU Stages (E) | 16       | 16       | 16       | 16       |
| Total MAU      | 48       | 48       | 48       | 48       |
|----------------|----------|----------|----------|----------|
| TCAM           | 128 Mb   | 96 Mb    | 64 Mb    | 64 Mb    |
| SRAM           | 256 MB   | 192 MB   | 128 MB   | 128 MB   |
|----------------|----------|----------|----------|----------|
| Packet Buffer  | 256 MB   | 192 MB   | 128 MB   | 128 MB   |
|----------------|----------|----------|----------|----------|
| Tofino 2 Specific:                                                    |
|----------------|----------|----------|----------|----------|
| Cryo Unit      | Yes      | Yes      | Yes      | Yes      |
| MAU Split      | Yes      | Yes      | Yes      | Yes      |
| Flex Pipes     | Yes      | Yes      | Yes      | Yes      |
| Secure Vector  | Yes      | Yes      | Yes      | Yes      |
+----------------------------------------------------------------------+
```

### 2.2 Tofino 2 物理封装

```
Tofino 2 封装:
==============

        +============================================+
        |                                            |
        |    +----------------------------------+    |
        |    |         Tofino 2 ASIC           |    |
        |    |                                  |    |
        |    |  +------+  +------+  +------+   |    |
        |    |  | Pipe |  | Pipe |  | Pipe |   |    |
        |    |  |  0   |  |  1   |  |  2   |   |    |
        |    |  +------+  +------+  +------+   |    |
        |    |                                  |    |
        |    |           TM / MC / Clone        |    |
        |    |                                  |    |
        |    +----------------------------------+    |
        |                                            |
        |  +--------------------------------------+  |
        |  |   128 x 100G SerDes (QSFP28/QSFP56) |  |
        |  +--------------------------------------+  |
        |                                            |
        +============================================+

典型系统配置:
- 2 x Tofino 2 (25.6T total switch)
- 1U / 2U / 4U form factor
- DDR4 DRAM (for large tables)
- BMC for management
```

---

## 3. MAU Split 架构

### 3.1 什么是 MAU Split？

Tofino 2 引入了 **MAU Split** 架构，将 Ingress 和 Egress Pipeline 的 MAU 资源**解耦**：

```
Tofino 1 Pipeline (Fixed):
==========================

Ingress: [Parser] --> [MAU 32 stages] --> [Deparser]
                                                  |
Egress:  [Parser] --> [MAU 32 stages] --> [Deparser]

问题: Ingress 和 Egress MAU 必须对称使用
      某些场景下一边资源浪费


Tofino 2 MAU Split:
====================

Ingress: [Parser] --> [MAU 32 stages] --> [Deparser]
                                                  |
Egress:  [Parser] --> [MAU 16 stages] --> [Deparser]

优势:
- Ingress: 32 stages (复杂入口处理)
- Egress: 16 stages (简化出口处理)
- 资源分配更灵活
```

### 3.2 MAU Split 资源分配

```
MAU Split 资源模型:
===================

Tofino 2 总 MAU Stages = 48

可用分配模式:
+-------------+------------+------------+
|   模式      | Ingress    | Egress     |
+-------------+------------+------------+
| Balanced    | 32         | 16         |
| I-heavy     | 40         | 8          |
| E-heavy     | 24         | 24         |
| Max Ingress | 48         | 0 (bypass) |
| Max Egress  | 0 (bypass) | 48         |
+-------------+------------+------------+

注意: MAU Split 是通过工具链配置的，
      不是运行时动态的
```

### 3.3 MAU Split 编程

```c
// Tofino 2 MAU Split 配置 (通过 SDE 工具)
// $SDE/share/p4/targets/tofino2/mausplit.cfg

# MAU Split 配置文件示例
# 配置 Ingress 32 stages, Egress 16 stages

[global]
device = tofino2
model = ES2-12.8T

[pipeline]
ingress_stages = 32
egress_stages = 16

# 可选: 指定哪些 stage 用于特定功能
# [stage_allocation]
# ingress_tunnel_term = 0-4
# ingress_acl = 5-20
# ingress_routing = 21-31
# egress_qos = 0-8
# egress_mirror = 9-15
```

---

## 4. Flex Pipes 灵活管道

### 4.1 Flex Pipes 概念

**Flex Pipes** 是 Tofino 2 引入的创新架构，允许不同的 **Pipe** 配置为不同的**转发路径**：

```
传统交换机架构:
===============

All Ports --> [Fixed Pipeline A] --> All Ports

问题: 所有流量走同一条流水线
      无法针对不同流量类型优化


Tofino 2 Flex Pipes:
====================

     +---> [Pipe 0: L2/L3 Pipeline] -----> Ports 0-31
     |
Ports
     +---> [Pipe 1: Storage Pipeline] ---> Ports 32-47
     |
     +---> [Pipe 2: Telemetry Pipeline] -> Ports 48-63
     |
     +---> [Pipe 3: Security Pipeline] --> Ports 64-95

优势:
- 不同端口组走不同流水线
- 优化特定场景的处理
- 资源按需分配
```

### 4.2 Flex Pipes 使用场景

| 场景 | Pipe 0 | Pipe 1 | Pipe 2 | Pipe 3 |
|------|--------|--------|--------|--------|
| **Spine Switch** | L3 Fabric | L3 Fabric | L3 Fabric | L3 Fabric |
| **Leaf Switch** | L2/VXLAN | L3 | | |
| **Storage** | NVMe-oF | iSCSI | | |
| **Telemetry** | Normal | INT | sFlow | |
| **Security** | Firewall | IDS | DPI | |

### 4.3 Flex Pipes 配置

```python
#!/usr/bin/env python3
# flex_pipes_config.py - Tofino 2 Flex Pipes 配置工具

class FlexPipesConfig:
    def __init__(self, device='tofino2'):
        self.device = device
        self.pipes = {}
        
    def create_pipe(self, pipe_id, pipeline_type, ports):
        """
        创建 Flex Pipe
        
        Args:
            pipe_id: 0-3
            pipeline_type: 'l2', 'l3', 'storage', 'telemetry', 'security'
            ports: port list, e.g., [0, 1, 2, 3]
        """
        self.pipes[pipe_id] = {
            'type': pipeline_type,
            'ports': ports,
            'ingress_stages': self._get_stage_count(pipeline_type),
            'egress_stages': 16,  # Default
        }
        
    def _get_stage_count(self, pipe_type):
        """根据类型确定 ingress stages"""
        stage_map = {
            'l2': 20,
            'l3': 28,
            'storage': 24,
            'telemetry': 32,
            'security': 16,
        }
        return stage_map.get(pipe_type, 24)
    
    def generate_config(self):
        """生成 SDE 配置文件"""
        config = f"""
# Flex Pipes Configuration
# Generated for {self.device}

[global]
device = {self.device}

[pipeline]
mode = flex_pipes

"""
        for pipe_id, pipe in self.pipes.items():
            config += f"""
[pipe_{pipe_id}]
type = {pipe['type']}
ports = {','.join(map(str, pipe['ports']))}
ingress_stages = {pipe['ingress_stages']}
egress_stages = {pipe['egress_stages']}
"""
        return config

# 使用示例
if __name__ == '__main__':
    config = FlexPipesConfig('tofino2-12.8t')
    
    # Leaf switch: L2/VXLAN on first 32 ports, L3 on rest
    config.create_pipe(0, 'l2', list(range(0, 32)))
    config.create_pipe(1, 'l3', list(range(32, 64)))
    
    # 生成配置文件
    with open('flex_pipes.cfg', 'w') as f:
        f.write(config.generate_config())
    
    print("Flex Pipes config generated: flex_pipes.cfg")
```

---

## 5. Tofino 2 新增特性

### 5.1 Secure Vector Processing

**Secure Vector** 是 Tofino 2 的硬件安全特性：

```
Secure Vector Processing:
=========================

传统处理: 数据包 --> Pipeline --> 输出
              |
              v
         [攻击检测]
              |
         发现攻击 --> 丢包

Secure Vector: 数据包 --> Pipeline --> 输出
                          |
                          v
                    [安全检查点]
                     |         |
                     v         v
              [正常转发]   [隔离处理]
                     |
                     v
              [Crypto Engine]
              (加密/解密)

特性:
- 硬件级加密/解密 (IPsec, MACsec)
- 防侧信道攻击
- 密钥管理单元
```

### 5.2 Packet Cryo

**Packet Cryo** 是 Tofino 2 的低延迟优化：

```
Packet Cryo:
============

目标: 进一步降低延迟 (< 500ns)

优化点:
1. Fast Path Optimization
   - 旁路某些不必要的检查
   - 直接从 Parser 到 Action

2. Cut-Through Switching
   - 不等待整个包接收完就转发
   - 降低存储转发延迟

3. Low-Latency Queue
   - 专用超低延迟队列
   - 绕过正常 Traffic Manager

典型延迟对比:
+-------------+-------------+
|   优化前     |   优化后     |
+-------------+-------------+
|  ~360ns     |  ~200ns     |
+-------------+-------------+
```

### 5.3 Extended Hash

Tofino 2 增强了 Hash 单元：

```
Tofino 2 Hash 算法:
===================

Tofino 1 Hash:
- CRC16, CRC32
- xxHash (32, 64)
- Identity

Tofino 2 Hash (Extended):
- CRC16, CRC32, CRC64
- xxHash (32, 64, 128)
- SipHash
- Murmur3
- AES-GCM (for crypto)

新增应用:
- IPSec SPI lookup
- MACsec Key Derivation
- INT Metadata Hash
```

---

## 6. Tofino 2 流水线详解

### 6.1 完整流水线架构

```
Tofino 2 完整流水线:
====================

Ingress Pipeline (Tofino 2):
+--------+    +------------------+    +------------------+    +---------+
|Parser  |--> |  MAU (Stage 0-31) |--> |  MAU (Stage 32+) |--> |Deparser |
+--------+    |                  |    | (if MAU Split)  |    +---------+
              +------------------+    +------------------+

Egress Pipeline (Tofino 2):
+--------+    +------------------+    +---------+
|Parser  |--> |  MAU (Stage 0-15) |--> |Deparser |
+--------+    +------------------+    +---------+

Packet Flow:
Packet --> Ingress Parser --> [MAU 0-31] --> [TM] --> [MAU 0-15] --> Egress Deparser --> Output
                    |                                    |
                    v                                    v
              (Normal Path)                    (Egress Processing)
```

### 6.2 Tofino 2 MAU 内部结构

```
MAU Stage 内部 (Tofino 2 增强):
================================

┌─────────────────────────────────────────────────────────────┐
│                    MAU Stage Block                           │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  Input PHV ─────────────────────────────────────────> Output │
│                     │                                         │
│                     v                                         │
│  +----------------------------------------------------------+ │
│  |              Stage Memory (Tofino 2 Enhanced)            | │
│  |  +----------+  +----------+  +----------+  +----------+  | │
│  |  | Hash #0  |  | Hash #1  |  | Hash #2  |  | Hash #3  |  | │
│  |  | Extended |  | Extended |  | Extended |  | Extended |  | │
│  |  +----------+  +----------+  +----------+  +----------+  | │
│  |       |            |            |            |          | │
│  |  +----+----+  +----+----+  +----+----+  +----+----+      | │
│  |  | TCAM    |  | SRAM     |  | SRAM     |  | TCAM     |   | │
│  |  | 4K      |  | 16K      |  | 16K      |  | 4K       |   | │
│  |  +---------+  +----------+  +----------+  +---------+    | │
│  +----------------------------------------------------------+ │
│                            │                                  │
│                            v                                  │
│  +----------------------------------------------------------+ │
│  |              Action Engine (ALU)                         │ │
│  |  +--------+  +--------+  +--------+  +--------+           │ │
│  |  | ALU #0 |  | ALU #1 |  | ALU #2 |  | ALU #3 |           │ │
│  |  |256-bit |  |256-bit |  |256-bit |  |256-bit |           │ │
│  |  +--------+  +--------+  +--------+  +--------+           │ │
│  +----------------------------------------------------------+ │
│                            │                                  │
│                            v                                  │
│  +----------------------------------------------------------+ │
│  |              Gate Logic (Enhanced)                        │ │
│  |  - More conditional branches                              │ │
│  |  - Nested gate support                                    │ │
│  +----------------------------------------------------------+ │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 6.3 Tofino 2 新增指令

```c
// Tofino 2 新增 P4 Action 指令

// 1. 新增 Hash 算法
action hash_for_ipsec(bit<32> src_ip, bit<32> dst_ip) {
    // Tofino 2 新增: AES-GCM based hash
    bit<32> hash_result;
    // 使用 Secure Vector Hash
    hash<bit<32>>(HashAlgorithm.aes_gcm)(
        hash_result,
        { src_ip, dst_ip, standard_metadata.ingress_port }
    );
    // 用于 IPSec SPI lookup
    meta.spi = hash_result;
}

// 2. 新增位操作指令
action enhanced_bit_operations() {
    // Tofino 2 新增: popcount
    bit<8> count = popcount(h.ipv4.srcAddr ^ h.ipv4.dstAddr);
    
    // Tofino 2 新增: find_first_one
    bit<8> index = find_first_one(h.tcp.flags);
    
    // Tofino 2 新增: bit_reverse
    bit<32> reversed = bit_reverse(h.ipv4.srcAddr);
}

// 3. 增强的校验和计算
action enhanced_checksum() {
    // Tofino 2 新增: 直接校验和更新 (增量)
    // 不需要重新计算整个 header
    bit<16> delta = h.ipv4.ttl - 1;
    // 增量更新 checksum
    h.ipv4.hdrChecksum = update_checksum_delta(
        h.ipv4.hdrChecksum,
        { 8w0xFF, delta }
    );
}
```

---

## 7. Tofino 2 资源详解

### 7.1 资源对比表

| 资源 | Tofino 1 | Tofino 2 | 说明 |
|------|----------|-----------|------|
| **TCAM** | 64 Mb | 128 Mb | 2x, per chip |
| **SRAM** | 128 MB | 256 MB | 2x, per chip |
| **Hash Units** | 64 (2/stage) | 128 (4/stage) | 2x |
| **Packet Buffer** | 128 MB | 256 MB | 2x |
| **Queues** | 16K | 32K | 2x |
| **MC Groups** | 1K | 4K | 4x |
| **Clone Sessions** | 128 | 512 | 4x |
| **Meter** | 64K | 128K | 2x |
| **INT Stages** | 8 | 16 | 2x |

### 7.2 Tofino 2 新增资源

```
Tofino 2 独有资源:
==================

1. Secure Vector Unit
   - 加密/解密引擎
   - AES-128/256 支持
   - MACsec 引擎

2. Extended Hash
   - 新增 Hash 算法
   - 可编程 Hash 函数

3. Packet Cryo Engine
   - 超低延迟路径
   - Cut-through 优化

4. Enhanced Gate Logic
   - 更多条件分支
   - 嵌套 Gate 支持
```

### 7.3 资源估算

```python
#!/usr/bin/env python3
# tofino2_resource_estimator.py

def estimate_tofino2(p4_program):
    """
    估算 P4 程序在 Tofino 2 上的资源使用
    """
    
    print("""
Tofino 2 资源估算工具:
=====================

输入: P4 程序分析

输出:

Table: ipv4_fib (LPM, 128K entries)
  - TCAM: 192K entries (150%)
  - SRAM: 128K entries
  - Hash: 1 unit

Table: mac_table (Exact, 64K entries)
  - SRAM: 64K entries  
  - Hash: 1 unit

Table: acl (Ternary, 32K entries)
  - TCAM: 64K entries (200%)
  - Hash: 1 unit

Table: tunnel_termination (LPM, 16K entries)
  - TCAM: 24K entries
  - SRAM: 16K entries

总计 (单 Pipe):
  - TCAM: 280K / 512K available (55%)
  - SRAM: 208K / 1M available (21%)
  - Hash: 4 units / 128 available (3%)

建议:
  - 所有资源使用均在限制内 ✓
  - 可以启用 MAU Split (32 I / 16 E)
  - Flex Pipes 可配置为 Balanced 模式
""")

# Tofino 2 MAU Split 建议
print("""
MAU Split 配置建议:
===================

场景: 典型 L2/L3 Switch
+----------+------------+------------+
| 功能      | Ingress   | Egress     |
+----------+------------+------------+
| Parser   | 32 stages | 16 stages  |
| L2 MAC   | 0-4       |           |
| L3 Route | 5-20      |           |
| ACL      | 21-28     | 0-8       |
| QoS      | 29-31     | 9-15      |
+----------+------------+------------+
""")
```

---

## 8. Tofino 2 开发

### 8.1 Tofino 2 SDE 安装

```bash
# 1. 下载 Intel Tofino 2 SDE
# https://www.intel.com/content/www/us/en/download/19520/

# 2. 安装 Tofino 2 SDE
tar -xzf tofino2-sde-9.10.0.tar.gz
cd tofino2-sde-9.10.0
sudo ./install.sh

# 3. 设置环境变量
export SDE=/opt/tofino2-sde
export SDE_INSTALL=$SDE/install
export TOFINO2_SDE=$SDE
export PATH=$PATH:$SDE/bin:$SDE/sbin
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:$SDE/lib

# 4. 验证安装
bf-sde.version
# Expected: 9.10.0

# 5. 编译 P4 程序
cd $SDE/pkgs/p4-examples/simple_l3
make -j$(nproc) TOFINO2=1
```

### 8.2 Tofino 2 特有配置

```bash
#!/bin/bash
# tofino2_setup.sh

# 启用 Tofino 2 特性
export BF_SDE="tofino2"

# 设置 MAU Split 配置
bfn_config set mau_split ingress=32 egress=16

# 配置 Flex Pipes
bfn_config set flex_pipes mode=balanced

# 设置Packet Cryo (低延迟模式)
bfn_config set cryo enable=1

# 设置 Secure Vector
bfn_config set secure_vector enable=1

# 运行交换机
bf_switchd --bf-sde=$SDE \
           --install-dir=$SDE_INSTALL \
           --conf-file=simple_l3.conf \
           --init=usd \
           --log-level=info \
           --chip_tofino2
```

### 8.3 P4-16 程序模板 (Tofino 2)

```c
#include <core.p4>
#include <tna.p4>  // Tofino 2 使用 tna.p4

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

struct headers_t {
    ethernet_t ethernet;
    ipv4_t     ipv4;
}

struct metadata_t {
    bit<32> nexthop_id;
    bit<8>  tc;
}

// ============== Parser ==============
parser IngressParser(packet_in packet,
                    out headers h,
                    inout metadata m,
                    in PSA_ParserInputMetadata_t istd) {
    state start {
        packet.extract(h.ethernet);
        transition select(h.ethernet.etherType) {
            0x0800: parse_ipv4;
            default: accept;
        }
    }
    
    state parse_ipv4 {
        packet.extract(h.ipv4);
        transition accept;
    }
}

// ============== Control ==============
control Ingress(inout headers h,
                inout metadata m,
                in PSA_ParserInputMetadata_t istd,
                inout PSA_ingress_output_metadata_t ostd) {
    
    // Tofino 2 增强: 使用新增的 Hash 算法
    action ipv4_forward(PortId_t port, bit<8> ttl_val) {
        h.ipv4.ttl = ttl_val;
        ostd.egress_port = port;
    }
    
    table ipv4_lpm {
        key = { h.ipv4.dstAddr: lpm; }
        actions = { ipv4_forward; drop; }
        default_action = drop();
        size = 128K;
    }
    
    // Tofino 2 增强: QoS 表
    table qos_table {
        key = {
            h.ipv4.diffserv: ternary;
        }
        actions = {
            set_tc;
            NoAction;
        }
        const entries = {
            0x2E: set_tc(5);  // EF
            0x00: set_tc(0);  // BE
        }
    }
    
    apply {
        ipv4_lpm.apply();
        qos_table.apply();
    }
}

// ============== Deparser ==============
control IngressDeparser(packet_out packet,
                       inout headers h,
                       in metadata m,
                       in PSA_ingress_output_metadata_t ostd) {
    apply {
        packet.emit(h.ethernet);
        packet.emit(h.ipv4);
    }
}

// ============== Pipeline ==============
Pipeline(IngressParser(), Ingress(), IngressDeparser()) ip;
PSA_Switch(ip, Egress()) main;
```

---

## 9. Tofino 2 性能分析

### 9.1 带宽与吞吐量

```
Tofino 2 性能规格:
==================

12.8T 型号:
- 全双工带宽: 12.8 Tbps
- 128 x 100GE ports
- 线速性能: 所有端口同时 100G

吞吐量 (64B packets):
- 12.8T / (64 * 8) = 25 Gpps (数据包/秒)
- 12.8T / (1518 * 8) = 1.05 Gpps (最大帧)

延迟:
- Ingress: ~100ns
- Egress: ~60ns
- TM: ~200ns (典型)
- 总计: ~360ns (典型), ~200ns (Cryo 模式)
```

### 9.2 与 Tofino 1 对比

```
Tofino 1 vs Tofino 2 对比:
===========================

| 指标            | Tofino 1    | Tofino 2    | 变化    |
|-----------------|-------------|-------------|---------|
| Bandwidth       | 6.5 Tbps    | 12.8 Tbps   | +97%    |
| Port Count      | 64 x 100G   | 128 x 100G  | +100%   |
| MAU Stages      | 32          | 48          | +50%    |
| TCAM            | 64 Mb       | 128 Mb      | +100%   |
| SRAM            | 128 MB      | 256 MB      | +100%   |
| Packet Buffer   | 128 MB      | 256 MB      | +100%   |
| P4 Version      | P4-14 main  | P4-16 full  | 完整支持|
| Flex Pipes      | No          | Yes         | 新增    |
| MAU Split       | No          | Yes         | 新增    |
| Secure Vector   | No          | Yes         | 新增    |
| Packet Cryo     | No          | Yes         | 新增    |
| Process         | 16nm        | 16nm        | 相同    |
| TDP             | 350W        | 450W        | +29%    |
| Price           | $10K-$30K   | $20K-$60K   | ~2x     |
```

---

## 10. 总结

Tofino 2 是 Intel 第二代 P4 可编程交换芯片，核心升级：

1. **容量翻倍**：12.8Tbps / 128 ports / 256MB buffer
2. **MAU Split**：48 stages，灵活分配 Ingress/Egress
3. **Flex Pipes**：不同端口组走不同流水线
4. **新特性**：Secure Vector、Packet Cryo、Extended Hash

**下一章**我们将探讨 **Intel IPU (Infrastructure Processing Unit)**，了解 P4 在智能网卡/DPU 上的应用。
