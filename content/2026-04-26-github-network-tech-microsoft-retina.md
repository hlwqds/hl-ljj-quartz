---
title: "Microsoft Retina: 基于 eBPF 的 Kubernetes 网络可观测性工具"
date: 2026-04-26 10:00:00
tags: [network, github, ebpf, kubernetes, observability]
description: Microsoft Retina 是微软开源的基于 eBPF 的 Kubernetes 分布式网络可观测性工具，提供低开销的流量监控、安全分析和故障排查能力。
---

# Microsoft Retina: 基于 eBPF 的 Kubernetes 网络可观测性工具

## 项目概览

**Microsoft Retina** 是微软开源的基于 eBPF 的 Kubernetes 分布式网络可观测性工具。它通过 eBPF 技术在内核层面捕获网络事件，无需修改应用容器，即可实现对 Kubernetes 集群网络流量的深度可视化和安全分析。

- **GitHub**: https://github.com/microsoft/retina
- **语言**: Go
- **Stars**: 3.1k ⭐
- **Forks**: 287
- **最新提交**: 2026-04-25（昨天）
- **Commits**: 1,235
- **License**: MIT
- **维护组织**: Microsoft

## 核心技术亮点

### eBPF 数据面架构

Retina 的核心数据面基于 eBPF 程序，在 Kubernetes 节点内核层运行，捕获经过的所有网络数据包。与传统旁路抓包不同，Retina 通过 eBPF hook 在网络协议栈的关键路径上植入轻量级探针，实现：

- **零侵入监控**：无需修改 Pod 应用，无需 sidecar 代理
- **低性能开销**：eBPF 程序在内核态执行，数据直接通过 map 共享给用户态
- **L2-L7 全栈覆盖**：不仅能抓包，还能解析 HTTP/DNS/TLS 等应用层协议

```go
// Retina 的核心工作原理
// 1. DaemonSet 部署到每个 Kubernetes 节点
// 2. eBPF 程序挂载到 TC (Traffic Control) hook 或 XDP
// 3. 捕获元数据（不是完整包体）发送到用户态处理
// 4. 支持输出到 Prometheus、Grafana、OpenTelemetry 等
```

### 多层次的网络可观测性

Retina 提供多层次的网络指标采集能力：

| 层次  | 指标类型 | 示例                                      |
| ----- | -------- | ----------------------------------------- |
| L2/L3 | 连接统计 | 字节数、包数、PPS                         |
| L4    | 传输层   | TCP 重传、连接状态分布                    |
| L7    | 应用层   | HTTP 请求率、DNS 查询延迟、TLS 握手成功率 |

### 与 Cilium 的集成

Retina 最近的更新中已集成 Cilium 作为依赖（`deps(cilium): upgrade Cilium to v1.19.3`）。这意味着 Retina 可以利用 Cilium 的 eBPF datapath 和网络策略能力，形成 "Cilium 网络 + Retina 可观测性" 的组合方案。

## 适用场景

### 1. Kubernetes 网络故障排查

当集群内网络出现问题时，Retina 可以快速定位：

- 哪些 Pod 之间的通信出现问题
- TCP 重传率高的节点是哪些
- DNS 解析延迟的根因分析

### 2. 安全监控与异常检测

通过 eBPF 捕获网络元数据，Retina 可以检测：

- 异常连接模式（如内部 Pod 对外部的异常出站流量）
- 可疑的 DNS 查询（如隧道通信特征）
- 未加密的敏感流量

### 3. 网络性能分析

结合 Prometheus 和 Grafana，Retina 可以提供：

- 集群级别的网络吞吐量趋势
- 服务间调用拓扑和依赖关系
- 网络延迟的 P99/P95 分位数

## 实践要点

### 部署方式

Retina 通过 Kubernetes DaemonSet 部署，每个节点运行一个 Agent：

```bash
# Helm 安装
helm install retina microsoft/retina \
  --set enable-linux-dp=true \
  --set enable-orbpf-capture=true
```

### 与 Hubble 的对比

Retina 和 Cilium Hubble 都提供网络可观测性，但定位不同：

| 维度              | Retina                  | Hubble               |
| ----------------- | ----------------------- | -------------------- |
| 依赖              | 独立运行                | 依赖 Cilium CNI      |
| 数据源            | eBPF（自研）            | Cilium eBPF datapath |
| 指标深度          | L2-L7 全覆盖            | L3-L7                |
| Kubernetes 兼容性 | 任意 CNI                | 仅 Cilium            |
| 生态集成          | Prometheus/Grafana/OTel | Cilium Enterprise    |

Retina 的优势在于不依赖特定 CNI，适用于多云环境和混合集群场景。

## 近期更新

Retina 在最近一周（2026-04-19 至 2026-04-25）有多个活跃更新：

- `deps(cilium): upgrade Cilium to v1.19.3` — 升级 Cilium 依赖
- `chore(deps): consolidate dependabot config` — 依赖配置优化
- `chore: improve devcontainer experience` — 开发者体验改进
- `deps: bump golang in /ha` — Go 版本更新

## 总结

Microsoft Retina 代表了云原生网络可观测性的一个新方向：**eBPF + 零侵入 + 多 CNI 兼容**。相比深度绑定特定 CNI 的方案，Retina 提供了一种更通用的选择，适合需要跨集群统一网络监控的运维和安全团队。
