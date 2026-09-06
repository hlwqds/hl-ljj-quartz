---
title: "P4 深度探索 (二十八)：P4 与 SDN 控制器——ONOS/Barefoot Runtime、OpenFlow 演进、Stratum、P4-Overlay 架构"
date: 2026-04-14
tags: [p4, series, sdn, onos, openflow, stratum, barefoot, control-plane, p4runtime]
description: "P4 与 SDN 控制器深度解析——ONOS P4 支持、Barefoot Runtime、OpenFlow 到 P4 Runtime 的演进、Stratum 交换机抽象、P4-Overlay 网络架构、分布式控制面"
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
> 24. [[ch24-intel-ipu|第二十四章：Intel IPU——IPU/DPU、基础设施处理单元、Fxp/Dcp、P4 控制面]]
> 25. [[ch25-broadcom|第二十五章：Broadcom——DNX/Maple 交换芯片、Jericho/Ramon]]
> 26. [[ch26-p4-runtime|第二十六章：P4 Runtime——gRPC/Protobuf API、P4Info、表条目管理架构]]
> 27. [[ch27-p4-runtime-table|第二十七章：P4 Runtime 表管理——动态表项更新、Action Profile、P4Runtime 客户端]]
> 28. **第二十八章：P4 与 SDN 控制器——ONOS/Barefoot Runtime、OpenFlow 演进、Stratum**

---

## 1. 概述：SDN 与 P4 的关系

**SDN (Software Defined Networking)** 核心思想是将**控制平面**与**数据平面**分离，实现网络的集中式可编程。P4 的诞生进一步推动了数据平面的可编程性，与 SDN 形成完美互补。

```
SDN + P4 架构:
==============

+==========================================================================+
|||                          SDN 控制平面                                   |||
||  +------------------+  +------------------+  +------------------+       ||
||  |   ONOS          |  |   OpenDaylight  |  |   Stratum       |       ||
||  |                  |  |                  |  |                  |       ||
||  |  - 网络视图      |  |  - YANG/NETCONF |  |  - gRPC/P4Runtime|       ||
||  |  - 路径计算      |  |  - OpenFlow      |  |  - P4 + OpenConfig|       ||
||  |  - 拓扑管理      |  |  - Service Abst. |  |  - 厂商无关       |       ||
||  +--------+---------+  +--------+---------+  +--------+---------+       ||
||           |                     |                     |                 ||
||           +---------------------+---------------------+                 ||
||                               |                                       ||
+==========================================================================+
                                |
                                | OpenFlow / P4 Runtime / gRPC
                                |
+==========================================================================+
|||                          P4 数据平面                                   |||
||  +------------------+  +------------------+  +------------------+       ||
||  |   Tofino 1/2     |  |   Broadcom DNX   |  |   BMv2          |       ||
||  |                  |  |                  |  |                  |       ||
||  |  - 32+ stages   |  |  - 24 stages     |  |  - Software     |       ||
||  |  - TNA Arch     |  |  - OpenNPU       |  |  - PSA Arch     |       ||
||  |  - 12.8T+      |  |  - 25.6T+       |  |  - 100Mpps     |       ||
||  +------------------+  +------------------+  +------------------+       ||
||                                                                          ||
+==========================================================================+
```

### 1.1 P4 增强 SDN 的能力

| 能力           | 传统 OpenFlow | P4 + SDN     |
| -------------- | ------------- | ------------ |
| **协议支持**   | 固定协议栈    | 任意协议定义 |
| **Parser**     | 固定解析      | 可编程解析   |
| **Match**      | 固定字段      | 可编程匹配   |
| **Action**     | 固定动作      | 可编程动作   |
| **Telemettry** | Polling       | In-band INT  |
| **芯片依赖**   | 厂商相关      | 厂商无关     |

---

## 2. OpenFlow 到 P4 Runtime 的演进

### 2.1 OpenFlow 的局限性

**OpenFlow** 是最早的 SDN 南向接口，但存在诸多局限：

```
OpenFlow 的局限性:
==================

1. 固定协议头匹配
   - 只能匹配已定义的字段 (L2, L3, L4)
   - 无法支持新协议 (如 SRv6)

2. 固定 Parser
   - 无法解析自定义协议
   - 无法处理变长 Header

3. 有限的状态管理
   - Counter/Meter 能力有限
   - 没有 Register 支持

4. 厂商实现差异
   - 不同厂商的 OpenFlow 实现不一致
   - 功能特性各不相同

5. 性能限制
   - 消息开销大
   - 不适合高速数据平面
```

### 2.2 P4 Runtime 的优势

| 维度         | OpenFlow 1.3 | P4 Runtime      |
| ------------ | ------------ | --------------- |
| **协议定义** | 固定         | 可编程          |
| **Parser**   | 固定         | 可编程          |
| **表结构**   | 厂商定义     | 程序定义        |
| **匹配类型** | 12 元组      | 任意字段        |
| **性能**     | ~10K msg/s   | ~1M msg/s       |
| **类型安全** | 无           | Protobuf 强类型 |

### 2.3 演进路径

```
OpenFlow -> P4 Runtime 演进:
============================

Phase 1: OpenFlow 主导
+----------+     +----------+
|  ONOS    | --> |  Switch  |
|          | OpenFlow    |
+----------+     +----------+

Phase 2: P4 引入
+----------+     +----------+     +----------+
|  ONOS    | --> |  Stratum | --> |  Tofino  |
|          | OF+ |  (P4RT)  | P4RT |          |
+----------+     +----------+     +----------+

Phase 3: 纯 P4 Runtime
+----------+     +----------+
|  ONOS    | --> |  Switch  |
|          | P4Runtime   |
+----------+     +----------+

注意: Stratum 作为 P4Runtime 代理
```

---

## 3. Stratum：云原生交换机抽象

### 3.1 Stratum 概述

**Stratum** 是 Google 主导的开源项目，旨在为交换机构建**厂商无关的软件抽象层**。Stratum 以容器的形式运行在交换机上，通过 P4Runtime 与底层 P4 交换机交互。

```
Stratum 架构:
============

+==========================================================================+
|||                          Stratum 层                                   |||
||                                                                          ||
||  +------------------+  +------------------+  +------------------+       ||
||  |   gNMI (YANG)   |  |   gNOI (Telemetry)|  |   P4Runtime     |       ||
||  |   Config       |  |   Operational     |  |   Data Plane    |       ||
||  |   (OpenConfig) |  |   (Streaming)    |  |   Control       |       ||
||  +--------+---------+  +--------+---------+  +--------+---------+       ||
||           |                     |                     |                 ||
||           +---------------------+---------------------+                 ||
||                               |                                       ||
||  +========================================================================+||
||  ||                     Stratum Core                                   || ||
||  ||  +----------------+  +----------------+  +----------------+       || ||
||  ||  |   Pipeline    |  |   Chassis      |  |   Interface    |       || ||
||  ||  |   Config      |  |   Manager      |  |   Manager      |       || ||
||  ||  +----------------+  +----------------+  +----------------+       || ||
||  +========================================================================+||
||                               |                                       ||
+==========================================================================+
                                |
                                | P4Runtime + gRPC
                                |
+==========================================================================+
|||                      底层 P4 交换机                                    |||
||                                                                          ||
||  +------------------+  +------------------+  +------------------+       ||
||  |   Tofino        |  |   Broadcom DNX   |  |   Barefoot SKU   |       ||
||  +------------------+  +------------------+  +------------------+       ||
||                                                                          ||
+==========================================================================+
```

### 3.2 Stratum 接口

| 接口           | 协议        | 用途                    |
| -------------- | ----------- | ----------------------- |
| **gNMI**       | gRPC        | 配置管理 (基于 YANG)    |
| **gNOI**       | gRPC        | 运营接口 (清算、镜像等) |
| **P4Runtime**  | gRPC        | 数据平面表项管理        |
| **OpenConfig** | YANG Models | 标准化数据模型          |

### 3.3 Stratum 部署

```bash
# Stratum 部署架构
# 通常以 Docker 容器运行在交换机上的 COTS 服务器

# 目录结构
/switch/
├── stratum/
│   ├── bin/
│   │   └── stratum        # 主程序
│   ├── config/
│   │   └── chassis_config.pb.txt
│   └── p4c-out/
│       └── demo.json      # P4 编译输出
└── daemons/
    └── rest of switch services

# 启动 Stratum
stratum \
    -flagfile=/path/to/flagsfile.txt \
    -chassis_config_file=/path/to/chassis_config.pb.txt \
    -p4c_log_dir=/var/log/p4c
```

### 3.4 Stratum 与 ONOS 集成

```bash
# ONOS 通过 gNMI/P4Runtime 连接 Stratum

# 1. ONOS 发现 Stratum 交换机
onos> drivers

# 2. 激活 Stratum 驱动
onos> app activate org.onosproject.drivers.stratum

# 3. 配置交换机
onos> pipeconf-add /path/to/pipeconf.json

# 4. 查看端口状态
onos> devices
```

---

## 4. ONOS P4 支持

### 4.1 ONOS 架构

**ONOS (Open Network Operating System)** 是面向服务provider的开源 SDN 控制器，提供分布式控制平面。

```
ONOS 架构:
==========

+==========================================================================+
|||                          应用层                                       |||
||  +------------------+  +------------------+  +------------------+       ||
||  |   Intent        |  |   Topology      |  |   Routing       |       ||
||  |   Framework     |  |   Service       |  |   Apps          |       ||
||  +--------+---------+  +--------+---------+  +--------+---------+       ||
||           |                     |                     |                 ||
+==========================================================================+
                                |
                                v
+==========================================================================+
|||                       Core 层 (分布式)                                |||
||                                                                          ||
||  +------------------+  +------------------+  +------------------+       ||
||  |   Network        |  |   Distributed   |  |   Provider      |       ||
||  |   Graph          |  |   Store (CRDT)  |  |   Registry      |       ||
||  +------------------+  +------------------+  +------------------+       ||
||                                                                          ||
||  +------------------+  +------------------+  +------------------+       ||
||  |   Device        |  |   Link           |  |   Host          |       │
||  |   Manager       |  |   Manager        |  |   Manager       |       ||
||  +------------------+  +------------------+  +------------------+       ||
||                                                                          ||
+==========================================================================+
                                |
                                v
+==========================================================================+
|||                       南向接口层                                      |||
||                                                                          ||
||  +------------------+  +------------------+  +------------------+       ||
||  |   OpenFlow       |  |   P4Runtime     |  |   gNMI/gNOI     |       ||
||  |   (OF 1.0-1.5)   |  |                  |  |                  |       ||
||  +------------------+  +------------------+  +------------------+       ||
||                                                                          ||
+==========================================================================+
```

### 4.2 ONOS P4Runtime 插件

```java
// ONOS P4Runtime 插件架构

ONOS P4Runtime Provider:
+-------------------------+
|   P4RuntimeProvider    |  <- 设备发现和连接管理
+-------------------------+
          |
          v
+-------------------------+
|   P4DeviceAgent        |  <- 设备抽象
+-------------------------+
          |
          v
+-------------------------+
|   P4PipelineInterpreter |  <- P4 程序解释器
+-------------------------+
          |
          v
+-------------------------+
|   P4RuntimeController   |  <- gRPC 通信
+-------------------------+
          |
          v
+-------------------------+
|   gRPC Channel         |  <- 底层 P4Runtime 连接
+-------------------------+
```

### 4.3 ONOS P4 程序流程

```java
// ONOS 中配置 P4 交换机流程

// 1. 加载 Pipeconf (P4 程序配置)
PipeconfId pipeconfId = new PipeconfId("org.opencord.p4runtimedemo");
providerService.registerPipeconf(pipeconfId, pipeconf);

// 2. 创建设备
DeviceId deviceId = DeviceId.deviceId("p4rt:1");
providerService.deviceConnected(deviceId, deviceInfo);

// 3. 配置流水线
ForwardingPipelineCatalog catalog = providerService.buildPipeline(pipelineConfig);
providerService.forwardingPipelines().setPipeline(deviceId, pipeconfId, catalog);

// 4. 写入表项
TrafficTreatment treatment = DefaultTrafficTreatment.builder()
    .setOutput(PortNumber.portNumber(1))
    .build();

TrafficSelector selector = DefaultTrafficSelector.builder()
    .matchIPDst(IpPrefix.valueOf("10.0.1.0/24"))
    .build();

FlowRule flowRule = DefaultFlowRule.builder()
    .forDevice(deviceId)
    .withSelector(selector)
    .withTreatment(treatment)
    .withPriority(100)
    .fromApp(appId)
    .build();

flowRuleService.applyFlowRules(flowRule);
```

---

## 5. Barefoot Runtime

### 5.1 Barefoot Runtime 概述

**Barefoot Runtime** 是 Intel (收购 Barefoot 后) 提供的 P4 控制面SDK，专门针对 Tofino 交换机优化。

```
Barefoot Runtime vs 标准 P4Runtime:
====================================

| 组件        | 标准 P4Runtime | Barefoot Runtime |
|-------------|-----------------|------------------|
| 厂商        | 通用            | Intel 专用       |
| 性能优化    | 通用            | Tofino 优化      |
| INT 支持    | 基础            | 完整 INT 集成     |
| 流水线配置  | P4Info         | P4Info + BF-rt   |
| 表管理      | 标准 API        | 高性能批量操作   |
| 错误处理    | Protobuf       | 增强的错误报告   |
```

### 5.2 Barefoot Runtime 特性

```python
# Barefoot Runtime Python API 示例

from bf_runtime import BFRuntimeClient

class BarefootController:
    def __init__(self, grpc_addr):
        self.client = BFRuntimeClient(grpc_addr)

    def load_pipeline(self, p4_program, p4_config):
        """加载 P4 流水线到 Tofino"""

        # Barefoot 专用 API
        self.client.SetForwardingPipelineConfig(
            p4_programs=[{
                "p4_program": p4_program,
                "p4_config": p4_config,  # Tofino 专用配置
                "p4_pipeline_name": "main"
            }]
        )

    def insert_with_id(self, table_name, entry):
        """使用表项 ID 快速插入"""
        # Barefoot 支持预分配 ID
        self.client.InsertTableEntryWithId(
            table_name=table_name,
            entry=entry,
            entry_id=entry.id  # 预分配 ID 提高性能
        )

    def enable_int(self, table_name):
        """启用 INT (In-band Network Telemetry)"""

        # Barefoot Runtime 专用 INT 配置
        int_config = {
            "enable_int": True,
            "int_sources": ["ingress_timestamp", "egress_timestamp"],
            "int_destinations": ["metadata"],
            "int_instructions": [
                "switch_id",
                "hop_latency",
                "queue_occupancy"
            ]
        }

        self.client.ConfigureINT(int_config)

    def batch_insert_optimized(self, entries):
        """优化的批量插入"""

        # Barefoot 的批量插入优化
        batch_size = 10000  # 更大的批量

        for i in range(0, len(entries), batch_size):
            batch = entries[i:i+batch_size]
            self.client.WritePreambleEntries(batch)
```

### 5.3 Barefoot 的 P4-Info 扩展

```protobuf
// Barefoot P4-Info 扩展
message BarefootTableConfig {
    bytes tna_info = 1;           // TNA 专用信息
    repeated StageTableConfig stages = 2;  // 多阶段表配置

    message StageTableConfig {
        uint32 stage_id = 1;
        uint32 table_id = 2;
        bytes stage_config = 3;    // 每阶段配置
    }
}

// Barefoot Match Key 扩展
message BarefootMatchKey {
    enum LookupType {
        NORMAL = 0;
        FAST_HASH = 1;       // 快速哈希
        GHOST = 2;           // Ghost 查找
        ALPM = 3;            // ALPM 查找
    }
    LookupType lookup_type = 1;
}
```

---

## 6. P4-Overlay 网络架构

### 6.1 Overlay vs Underlay

```
Overlay 网络架构:
================

Underlay (P4 可编程):
+----------+     +----------+     +----------+
|  Tofino  | <-> |  Tofino  | <-> |  Tofino  |
|  (P4)    |     |  (P4)    |     |  (P4)    |
+----------+     +----------+     +----------+
     |               |               |
     v               v               v
   Underlay 路由      Underlay 路由    Underlay 路由

Overlay (P4 封装):
+----------+     +----------+     +----------+
|   Host   | <->|   Host   | <->|   Host   |
+----------+     +----------+     +----------+
     |               |               |
     v               v               v
+----------+     +----------+     +----------+
|   VTEP   | <-> |   VTEP   | <-> |   VTEP   |
|   (P4)   |     |   (P4)   |     |   (P4)   |
+----------+     +----------+     +----------+
     |               |               |
     v               v               v
   Underlay 隧道      Underlay 隧道   Underlay 隧道
```

### 6.2 P4 VTEP (VXLAN Tunnel Endpoint)

```c
// P4 VXLAN VTEP 实现
control VxlanVtep(...) {

    // VXLAN 封装表
    table vxlan_encap {
        key = {
            local_vni: exact;
        }
        actions = {
            encap_vxlan;
            drop;
        }
    }

    // 远程 VTEP 表
    table vxlan_fib {
        key = {
            vni: exact;
            remote_ip: lpm;
        }
        actions = {
            forward_to_tunnel;
            drop;
        }
    }

    // 解封装表
    table vxlan_decap {
        key = {
            vni: exact;
        }
        actions = {
            decap_vxlan;
            forward_to_inner;
        }
    }

    apply {
        if (h.vxlan.isValid()) {
            // 入口: 解封装
            vxlan_decap.apply();
        } else {
            // 出口: 封装
            vxlan_encap.apply();
        }
    }
}
```

### 6.3 P4 Overlay 控制面

```python
# P4 Overlay 网络控制面

class P4OverlayController:
    def __init__(self, underlay_controller, overlay_controller):
        self.underlay = underlay_controller  # Underlay P4Runtime
        self.overlay = overlay_controller    # Overlay P4Runtime

    def add_hosts_to_vni(self, vni, host_macs, host_ips):
        """将主机添加到 VNI"""

        # 1. 配置 overlay VTEP
        for mac, ip in zip(host_macs, host_ips):
            self.overlay.insert_mac_entry(mac, ip, vni)

        # 2. 配置 underlay 路由
        remote_vtep_ip = self.get_remote_vtep(vni)
        self.underlay.insert_tunnel_route(remote_vtep_ip)

    def establish_tunnel(self, src_vtep, dst_vtep):
        """建立 VXLAN 隧道"""

        # 1. Underlay 路由到远程 VTEP
        self.underlay.insert_route(
            prefix=dst_vtep.ip,
            nexthop=self.underlay.get_nexthop(dst_vtep)
        )

        # 2. Overlay VNI 映射
        self.overlay.insert_vni_mapping(
            vni=self.vnis[src_vtep][dst_vtep],
            remote_vtep=dst_vtep.ip
        )
```

---

## 7. 分布式控制面

### 7.1 多控制器部署

```
多控制器部署:
=============

            +----------+
            |   NMS    |
            | (Manager)|
            +----+-----+
                 |
     +-----------+-----------+
     |           |           |
     v           v           v
+----------+ +----------+ +----------+
|   ONOS   | |   ONOS   | |   ONOS   |
|  Node 1  | |  Node 2  | |  Node 3  |
| (Master) | | (Standby)| | (Standby)|
+----------+ +----------+ +----------+
     |           |           |
     |           |           |
     v           v           v
+----------+ +----------+ +----------+
| Switch 1 | | Switch 2 | | Switch 3 |
+----------+ +----------+ +----------+

特性:
- 每个交换机选举一个 Master
- Master 负责所有写操作
- Standby 同步状态
- 故障时自动切换
```

### 7.2 分布式状态同步

```python
# 分布式控制面状态同步

class DistributedP4Controller:
    def __init__(self, node_id, cluster_nodes):
        self.node_id = node_id
        self.cluster = RaftCluster(cluster_nodes)
        self.local_p4rt = P4RuntimeClient(...)

    def write_with_consensus(self, entries):
        """带共识的写入"""

        # 1. 本地预处理
        local_entries = self.prepare_entries(entries)

        # 2. 提议到集群
        proposal = self.cluster.propose(
            command="WriteTableEntries",
            data=local_entries,
            term=self.current_term
        )

        # 3. 等待共识
        committed = self.cluster.wait_for_commit(proposal)

        # 4. 应用到本地设备
        if committed:
            self.local_p4rt.WriteTableEntry(local_entries)

    def on_receive_proposal(self, proposal):
        """处理接收到的提议"""

        # 验证提议
        if self.validate_proposal(proposal):
            # 应用变更
            self.local_p4rt.WriteTableEntry(proposal.data)

            # 确认提议
            self.cluster.ack_proposal(proposal, success=True)
        else:
            self.cluster.ack_proposal(proposal, success=False)
```

---

## 8. 控制器与 P4 程序版本管理

### 8.1 流水线更新流程

```python
# P4 程序热更新流程

class PipelineUpdateManager:
    def __init__(self, p4rt_helper):
        self.p4rt = p4rt_helper
        self.current_pipeline = None

    def update_pipeline_atomic(self, new_p4_program, new_p4_config):
        """
        原子更新流水线:
        1. 准备新流水线
        2. 验证
        3. 切换
        """

        # 1. 读取当前表项
        current_entries = self.dump_all_entries()

        # 2. 加载新流水线配置 (不激活)
        self.p4rt.SetForwardingPipelineConfig(
            p4_info=new_p4_program.p4info,
            p4_config=new_p4_config,
            dev_id=1,
            action=SET_AND_VERIFY  # 验证模式
        )

        # 3. 转换表项到新格式
        new_entries = self.translate_entries(current_entries, new_p4_program)

        # 4. 原子切换
        self.p4rt.SetForwardingPipelineConfig(
            p4_info=new_p4_program.p4info,
            p4_config=new_p4_config,
            dev_id=1,
            action=RECONCILE_AND_COMMIT,  # 切换并迁移
            entries=new_entries
        )

        self.current_pipeline = new_p4_program
```

---

## 9. 总结

| SDN 组件             | 技术       | P4 集成方式        |
| -------------------- | ---------- | ------------------ |
| **ONOS**             | Java       | P4Runtime Provider |
| **Stratum**          | Go/C++     | gRPC + P4Runtime   |
| **Barefoot Runtime** | Python/C++ | 优化的 P4Runtime   |
| **OpenDaylight**     | Java       | P4Runtime Plugin   |

P4 与 SDN 的结合实现了真正的**可编程数据平面 + 集中式控制**的融合，推动网络进入新时代。
