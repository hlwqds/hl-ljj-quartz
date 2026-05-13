---
title: cilium eBPF 网络技术调研
date: 2026-04-22 10:00:00
tags: [network, github, ebpf, kubernetes, tooling]
description: eBPF-based Networking, Security, and Observability — 云原生网络、安全与可观测性的开源解决方案
---

# cilium eBPF 网络技术调研

## 项目概览

**cilium/cilium** 是目前 GitHub 上最活跃的云原生网络项目之一，基于 eBPF（Extended Berkeley Packet Filter）技术，为 Kubernetes 集群提供高性能的**网络连接、安全策略和可观测性**能力。

| 指标 | 数值 |
| --- | --- |
| GitHub Stars | 24.2k |
| Forks | 3.7k |
| Commits | 42,241 |
| 主要语言 | Go |
| 最新更新 | 2026-04-22（1 小时前） |

项目定位为 CNI（容器网络接口）插件，同时也是一个完整的**服务网格（Service Mesh）**解决方案，深度集成 Kubernetes Gateway API。

## 核心技术亮点

### 1. eBPF 内核级数据平面

cilium 将网络和安全逻辑直接注入 Linux 内核，借助 eBPF 的高效、灵活特性，实现：

- **分布式负载均衡**：在 eBPF 哈希表中维护连接追踪，支持几乎无限的扩展规模
- **身份安全模型**：基于身份（Identity）的 L3-L7 网络安全策略，而非传统的 IP/端口规则
- **原生数据包处理**：内核态直接转发，绕过 iptables/netfilter 性能瓶颈
- **动态策略下发**：无需重启内核或应用，即可实时更新网络策略

### 2. Kubernetes Gateway API 深度集成

近期版本重点推进了对 Kubernetes Gateway API 的完整支持，包括：

- `GatewayClass`、`Gateway`、`HTTPRoute` 等 CRD 的原生实现
- 严格模式（strict-mode）Ingress + WireGuard 加密配置
- 稳定版 v1alpha2 API（network-policy-api release-0.2）

### 3. 跨集群网络（Cluster Mesh）

支持多 Kubernetes 集群间的**安全无缝互通**，统一管理跨集群的服务发现、安全策略和可观测性。

### 4. 可观测性平台

集成 Hubble——一个专为 cilium 设计的可观测性平台，提供：

- 网络流量可视化和追踪
- 策略命中（Policy Hits）分析
- 告警和异常检测

## 最近更新（近 7 天）

| Commit | 时间 | 内容 |
| --- | --- | --- |
| `5a75007f` | 2026-04-21 | fix: improve validator logging and prevent unnecessary watches |
| `42324fc1` | 2026-04-21 | Update network-policy-api to official release-0.2 (v1alpha2) |
| `e4f96757` | 2026-04-21 | gateway-api: Fix missed version upgrades for stable objects |
| `f7af4d09` | 2026-04-21 | ces: remove deprecated `ces-slice-mode` option |
| `d2b17f41` | 2026-04-20 | bpf: encap: move & use DSR-GENEVE helpers |
| `59fa538a` | 2026-04-15 | ci: add strict-mode-ingress WireGuard to both stable and newest config |
| `e88e8376` | 2026-04-02 | feat(annotations): allow per-pod source IP verification control |

**近期待发布版本**：`v1.20.0-pre.1`，稳定版本包括 `v1.19.3`、`v1.18.9`、`v1.17.15`。

## 适用场景

- **Kubernetes 生产集群网络**：作为 CNI 插件提供高性能 Pod 网络
- **服务网格**：替代或补充 Istio，提供更底层的 L4 可见性和安全
- **多集群互联**：跨云/跨数据中心的 Kubernetes 集群网络
- **安全合规**：基于身份的细粒度网络策略（支持 FQDN/DNS、可观测性）
- **eBPF 技术调研**：学习 eBPF 在云原生场景落地的最佳实践

## 快速部署

```bash
# 安装 cilium CLI
curl -LO https://github.com/cilium/cilium-cli/releases/latest/cilium-linux-amd64.tar.gz
tar xzf cilium-linux-amd64.tar.gz

# 部署 cilium 到 Kubernetes 集群
cilium install

# 验证部署状态
cilium status
cilium connectivity test
```

## 参考链接

- GitHub: https://github.com/cilium/cilium
- 官方文档: https://docs.cilium.io
- eBPF 介绍: https://ebpf.io
- 官网: https://cilium.io
