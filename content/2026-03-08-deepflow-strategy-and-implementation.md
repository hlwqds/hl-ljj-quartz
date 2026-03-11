---
title: DeepFlow 策略下发与实现机制深度解析
date: 2026-03-08 11:00:00
tags: [observability, network, deepflow, policy, ebpf, wasm]
---

> [!abstract] DeepFlow 深度分析系列文章
>
> - [[2026-03-08-deepflow-detailed-analysis-report|架构分析报告]]
> - [[2026-03-08-deepflow-strategy-and-implementation|策略下发机制]]
> - [[2026-03-08-deepflow-traffic-capture-technology|流量采集技术]]

# DeepFlow 策略下发与实现机制深度解析

## 1. 策略架构：中央集权与分布式执行

DeepFlow 采用“控制面集中配置，数据面分布式执行”的架构，确保在大规模集群下策略的实时性与一致性。

- **控制面 (Controller)**：负责将用户定义的业务逻辑（如：Namespace A 访问 Service B）翻译成 Agent 可识别的物理规则（IP/MAC 列表）。
- **数据面 (Agent)**：负责在流量产生的瞬间执行规则匹配，并根据指令执行“打标”、“采样”或“联动抓包”。

---

## 2. 策略下发流程 (Issuance Mechanism)

1.  **翻译与分发**：Controller 中的 **Trisolaris** 模块实时监听 K8s/云平台元数据，将逻辑策略计算为物理 ACL 规则。
2.  **gRPC 增量同步**：
    - Agent 定期（每分钟）通过 `SyncRequest` 发起心跳。
    - Server 比较策略版本号（`version_acls`），通过 `SyncResponse` 返回 **Protobuf 格式**的增量策略数据。
3.  **动态加载**：Agent 接收到新策略后，在内存中动态更新规则树，无需重启进程，策略秒级生效。

---

## 3. L4 策略：五元组过滤与标记 (L4 Policy)

L4 策略主要通过 **ACL (访问控制列表)** 实现，解决“谁访问了谁”以及“网络表现如何”的问题。

### 3.1 核心内容

- **匹配特征**：[源 IP/组, 目的 IP/组, 协议, 目的端口, 采集位置]。
- **执行动作 (Action)**：
  - **Tag (打标)**：为流日志注入特定的 `PolicyID`，作为后端告警的“红标签”。
  - **PCAP (联动抓包)**：自动触发原始报文镜像采集。
  - **Sample (采样)**：针对特定流量执行差异化采样率。

### 3.2 Agent 侧实现逻辑

- **多维匹配树**：Agent 利用 Rust 实现了一套高性能匹配引擎。它将数万条 ACL 规则编译为一棵多维前缀树，确保在处理百万级 PPS 流量时，单次匹配耗时在纳秒级别。

---

## 4. L7 策略：深度解析与业务逻辑 (L7 Policy)

L7 策略解决了“发送了什么”以及“内容是否合规”的问题，核心是 **协议解析器 + WASM 插件**。

### 4.1 协议解析与切片

- **自动探测**：`FlowGenerator` 自动识别 HTTP、MySQL、Redis 等协议。
- **数据切片**：通过 `l7_log_packet_size` 配置，决定每个事务保留多少载荷（默认 1024 字节），在性能与观测深度间取得平衡。

### 4.2 WASM 插件扩展 (Programmable Observability)

- **业务感知**：编写 WASM 插件从 HTTP JSON 或 SQL 参数中提取关键业务字段（如 `order_id`）。
- **安全匹配**：利用 WASM 插件执行复杂的正则表达式，识别 SQL 注入或敏感数据泄露（DLP）。
- **逻辑下发**：`.wasm` 插件文件由 Controller 统一下发至全网 Agent，运行在安全的沙箱环境中。

---

## 5. 告警实现路径：从贴标到触发

DeepFlow 的告警遵循 **“Agent 实时标记，Server 异步判定”** 的原则：

1.  **命中与贴标**：当流量触碰 ACL 或 WASM 定义的异常特征时，Agent 立即给该流盖上“违规戳记”（PolicyID / Custom Tag）。
2.  **入库存储**：带标记的 `L7FlowLog` 进入 ClickHouse。
3.  **告警判定**：Server 端的告警模块扫描 ClickHouse，发现带有特定标记的记录后，立即触发 Webhook 推送。
4.  **自动化取证**：如果策略开启了 `PCAP Action`，管理员在收到告警的同时，可以直接在界面下载由 Agent 自动抓取的、包含攻击详情的原始报文文件。

---

## 6. L4 与 L7 策略总结对比

| 特性         | **L4 策略 (网络级)**              | **L7 策略 (应用/业务级)**                  |
| :----------- | :-------------------------------- | :----------------------------------------- |
| **主要功能** | 扫描检测、DDoS 识别、网络隔离审计 | 业务合规性审计、SQL 注入识别、敏感数据提取 |
| **匹配深度** | 报文头部 (IP/Port/Proto)          | **报文载荷 (SQL/HTTP Body/Header)**        |
| **实现工具** | Agent 内置 ACL 匹配引擎           | **WASM 插件** + L7 解析器                  |
| **联动能力** | 联动 PCAP、流采样、流量标记       | 联动 PCAP、提取自定义标签、异常打标        |
| **下发方式** | gRPC `FlowAcl` 结构体             | gRPC `PluginConfig` (WASM 热分发)          |

---

_报告生成时间: 2026-03-08_
_由 Gemini CLI 分析生成_

---

## 外部参考

- [DeepFlow 官方文档](https://deepflow.io/docs/zh/)
- [eBPF 概念指南](https://ebpf.io/)
