---
title: DeepFlow 深度架构分析与部署模式报告
date: 2026-03-08 10:00:00
tags: [deepflow, ebpf, kubernetes, architecture, observability, network]
---

## 1. 总体架构概览 (Overall Architecture)

DeepFlow 采用“重 Agent、中心化 Server”的架构设计，利用 eBPF 技术实现零侵入的数据采集，并通过高度自动化的标签注入（AutoTagging）提供业务视角的观测能力。

```text
+-------------------------------------------------------+
|              业务节点 (K8s / VM / Docker)             |
|                                                       |
|   +-----------------------+   +-------------------+   |
|   |       应用进程/容器    |   |  DeepFlow Agent   |   |
|   |         (APP)         |   |      (Rust)       |   |
|   +-----------+-----------+   +---------+---------+   |
|               |                         ^             |
|               +--- eBPF/cBPF 观测 ------+             |
+-----------------------------------------|-------------+
                                          |
        +---------------------------------+---------------------------------+
        | gRPC (Sync/Meta)                | TCP/Protobuf (Data)             |
        v                                 v                                 |
+-------+---------------------------------+---------------------------------+
|                      DeepFlow Server (Go)                                 |
|                                                                           |
|  +------------------+      +------------------+      +------------------+ |
|  |    Controller    |      |     Ingester     |      |     Querier      | |
|  |     (控制面)     |      |     (数据面)     |      |    (查询引擎)    | |
|  +--------+---------+      +--------+---------+      +--------+---------+ |
|           |                         |                         |           |
+-----------|-------------------------|-------------------------|-----------+
            |                         |                         |
            v                         v                         v
+-----------+---------+      +--------+---------+      +--------+---------+
|      MySQL/MetaDB   | <----+    ClickHouse    | <----+      Querier     |
|    (存储元数据/配置) |      | (存储指标/流日志) |      |    (统一查询口)  |
+---------------------+      +------------------+      +------------------+
```

---

## 2. 核心机制：AutoTagging (自动打标签)

这是 DeepFlow 能够实现“零侵入”且具备业务语境的核心。它通过将 Agent 采集的“物理身份”与 Controller 采集的“逻辑身份”进行中央汇聚来实现。

### 2.1 元数据获取路径

- **物理身份 (Agent 提供)**：IP 地址、MAC 地址、Container ID、进程 PID、TAP 接口信息。
- **逻辑身份 (Controller 提供)**：K8s Pod 名字/标签、Service 名字、部署环境 (VPC/子网)、云平台实例名、自定义业务标签。

### 2.2 标签注入流程

1.  **Agent** 采集原始流量或 eBPF 调用记录（仅携带 IP/MAC 等标识）。
2.  **Controller** 定期从 K8s API 或云 API 同步最新的资源拓扑，维护一份 **[IP/MAC <-> 业务标签]** 的全网映射表。
3.  **Ingester** 在接收到数据后，实时查询映射表，将数十个业务维度标签（如 `pod_name`, `service_name`, `vpc`）注入数据行。
4.  **ClickHouse** 存储最终带标签的宽表数据，供前端秒级查询。

---

## 3. 三大部署模式详细对比

根据不同的基础设施环境，DeepFlow 提供了灵活的部署与元数据关联方案：

| 维度         | **1. Kubernetes (K8s) 模式**        | **2. 纯虚拟机/物理机 模式**              | **3. 普通容器 (Docker) 模式**            |
| :----------- | :---------------------------------- | :--------------------------------------- | :--------------------------------------- |
| **部署形式** | **DaemonSet**                       | **二进制程序 / Systemd**                 | **特权容器 (Privileged)**                |
| **元数据源** | **K8s APIServer** (中心化)          | **Agent 扫描** (自底向上)                | **Docker Socket** (本地)                 |
| **同步机制** | 选举 1 个 Agent 作为 Watcher 汇报   | 每个 Agent 通过 Genesis 协议汇报本地网卡 | 每个 Agent 读取本地 `.sock` 汇报容器字典 |
| **身份标识** | Pod IP + Pod MAC + Container ID     | Host IP + Host MAC + Hostname            | Container IP + Container ID              |
| **业务标签** | Pod, Service, Deployment, Namespace | Hostname, VPC, Subnet, Cluster           | Container Name, Image, Docker Label      |
| **适用场景** | 标准 K8s / 云原生环境               | 传统机房、核心数据库服务器               | Docker Swarm、独立 Docker 节点           |

### 3.1 K8s 模式：选举与 Watch

- **特点**：为了保护 APIServer，DeepFlow 会从该集群所有 Agent 中选出一个“Watcher”。只有 Watcher 负责订阅 API 变更，Controller 汇总后将“全网地图”同步给所有 Ingester。

### 3.2 虚拟机模式：Genesis 自发现

- **特点**：在没有 K8s 的环境下，Agent 就是“情报员”。它主动上报自己的 MAC/IP 和 Hostname。Controller 自动将 Hostname 锚定为逻辑对象，并结合云平台 API（如 AWS/阿里云）补全 VPC 等网络标签。

### 3.3 Docker 模式：本地 Socket 桥接

- **特点**：Agent 容器通过挂载 `/var/run/docker.sock`，实时监听 Docker 引擎的事件。当容器启停时，Agent 立即获得容器名与 IP 的映射关系并上报，确保容器环境下的“对号入座”。

---

## 4. 关键组件职责拆解

### 4.1 Agent (Rust)

- **Dispatcher**: 高性能包分发，支持 cBPF 过滤。
- **EbpfCollector**: 利用 eBPF 追踪系统调用、函数调用，实现无埋点追踪。
- **FlowGenerator**: 基于 FlowMap 维护会话状态，重组 L4/L7 协议。
- **UniformSender**: 统一序列化并分发数据。

### 4.2 Server (Go)

- **Controller (Trisolaris)**: 中枢模块。分配 vtap_id，管理 Agent 状态，下发策略。
- **Controller (Genesis/Cloud)**: 元数据采集器。对接 K8s/云 API，构建全局拓扑。
- **Ingester**: 高吞吐写入器。负责核心的 AutoTagging 逻辑。
- **Querier**: 统一查询入口。支持将 SQL/PromQL 转换为 ClickHouse 优化后的聚合查询。

---

## 5. 项目亮点与技术栈总结

### 5.1 项目亮点

- **零侵入性**: 无需埋点，通过 eBPF 自动识别应用协议（HTTP/gRPC/MySQL/Redis 等）。
- **全栈覆盖**: 从内核层到应用层的端到端追踪（Distributed Tracing）。
- **高性能**: Rust Agent 可以在极低开销下处理每秒数百万个包。
- **标准化**: 兼容 OTel 协议，可作为企业级可观测性平台的核心支柱。

### 5.2 技术栈总结

- **采集端 (Agent)**: Rust, eBPF (CO-RE), cBPF, WASM (插件扩展), Tokio (异步)。
- **服务端 (Server)**: Go, Gin, GORM, ClickHouse-go, gRPC/Protobuf。
- **存储**: ClickHouse (OLAP), MySQL (MetaDB), Redis (Cache)。
- **部署**: Helm, Docker Compose, Systemd。

---

## 6. 性能损耗与采样减负逻辑 (Sampling & Load Shedding)

在生产环境中，DeepFlow 通过多级采样和资源限制，确保对业务的影响维持在 **1% CPU** 以内。

### 6.1 多级采样逻辑：省内存 vs. 省存储

采样不仅是为了省磁盘，更是为了在流量高峰期保护 Agent 的 CPU 性能。

| 采样级别    | **执行位置**               | **减负目标 (What's Saved)** | **逻辑描述**                                                                                                 |
| :---------- | :------------------------- | :-------------------------- | :----------------------------------------------------------------------------------------------------------- |
| **L4 采样** | **解析前** (FlowGenerator) | **省解析 CPU**              | “看一眼就丢”。在进入 L7 解析器前根据五元组哈希判定，直接丢弃整条流，不进行协议解析。                         |
| **L7 采样** | **解析后** (L7 Log Sender) | **省存储 & 带宽**           | “解析完再丢”。Agent 已完成 HTTP/SQL 解析，但根据状态码（如 200 OK 采样，5xx 100% 采集）决定是否发给 Server。 |

---

## 7. 环境影响最小化配置 (The Safety Valves)

除了采样，DeepFlow 提供了多重“保险丝”来防止 Agent 成为业务负担：

### 7.1 资源刚性限制 (Resource Hard Limits)

- **`max_cpus`**: 强制限制 Agent 使用的 CPU 核数（建议设为 1）。
- **`max_memory`**: 强制内存上限（如 512MB）。一旦触达，Agent 会自动清空 FlowMap（连接表）并进入丢包保护模式。

### 7.2 系统负载熔断 (Circuit Breaker)

- **`system_load_circuit_breaker_threshold`**: 监控宿主机 Load（如 Load15）。当宿主机负载超过阈值（如 1.0），Agent 会自动进入“静默模式”，停止所有非必要采集，直到系统恢复。

### 7.3 采集深度控制 (Payload Control)

- **`l7_log_packet_size`**: 载荷截断长度（默认 1024）。减小此值可显著降低内核到用户态的数据拷贝开销。
- **`l7_protocol_enabled`**: 协议黑白名单。如果不需要看 Redis 流量，关闭解析逻辑可直接节省对应的 CPU 算力。

---

_报告生成时间: 2026-03-08_
_由 Gemini CLI 分析生成_
