---
title: Cilium: eBPF 原生 Kubernetes 网络与安全
date: 2026-04-25 10:00:00
tags: [network, github, ebpf, kubernetes, tooling]
description: Cilium 是基于 eBPF 的云原生网络、安全和可观测性开源项目，为 Kubernetes 提供高性能内核级数据包处理能力。
---

# Cilium: eBPF 原生 Kubernetes 网络与安全

## 项目概览

**Cilium** 是 Linux 原生 eBPF（Extended Berkeley Packet Filter）技术驱动的 Kubernetes 网络、安全和可观测性开源项目，由 CNCF 托管。区别于传统的 iptables/netfilter 链路，Cilium 在内核层面通过 eBPF 程序实现数据包处理、策略执行和流量可视化，大幅提升云原生场景下的网络性能与安全能力。

- **GitHub**: https://github.com/cilium/cilium
- **语言**: Go
- **Stars**: 24,200 ⭐
- **Forks**: 3,730
- **最新版本**: v1.19.3（2026-04-15）
- **最新提交**: 2026-04-25（约 7 小时前）
- **License**: Apache-2.0
- **主页**: https://cilium.io

## 核心技术亮点

### eBPF 数据平面

Cilium 的核心创新在于将 eBPF 程序挂载到内核的网络数据路径上，实现：

- **XDP（eXpress Data Path）**：在网卡驱动层（driver level）直接处理数据包，实现接近线速（line-rate）的转发，延迟低于 10µs
- **TC（Traffic Control）**：在网络接口层处理 ingress/egress 流量，支持 L3/L4/L7 策略
- **kprobe/tracepoint**：挂载到内核函数，实现透明加密（WireGuard）、负载均衡等高级功能
- **套接字级别处理**：支持套接字转移（socket redirect）和服务映射

### 多层网络模型

| 层级     | 技术        | 能力                         |
| -------- | ----------- | ---------------------------- |
| L3/L4    | eBPF        | 扁平 IP 互联、NetworkPolicy  |
| L7       | Envoy 集成  | HTTP/gRPC 感知策略、mTLS     |
| 加密     | WireGuard   | 传输加密、ClusterMesh 跨集群 |
| 负载均衡 | eBPF Maglev | 分布式 L4 负载均衡           |

### 核心功能

1. **CNI 插件**：无缝集成 Kubernetes，提供 Pod 网络、IPAM 和服务发现
2. **NetworkPolicy**：支持 L3/L4/L7 维度的零信任安全策略
3. **ClusterMesh**：跨 Kubernetes 集群的 eBPF 互联，支持全局服务负载均衡
4. **Hubble**：内置可观测性，支持服务依赖图、流量监控和 L7 可见性
5. **BGP 控制平面**：支持与物理网络设备对等宣告
6. **带宽管理**：基于 eBPF 的本地限速（EDT）

## 近期更新（2026-04）

根据最新提交记录，近 7 天内的主要变更包括：

- `bpf: Never allocate ct_buffers on stack`：修复 BPF 映射缓冲区栈分配问题
- `encryption: remove deprecated enable-encryption-strict-mode options`：移除废弃的加密配置项
- `ci: add drop monitor for GKE conformance tests`：新增 GKE 合规性测试的丢包监控
- `clustermesh: fix MCS-API CRD install bug`：修复多集群服务 API 的 CRD 安装问题
- `helm,docs: add configDriftDetection Helm values`：新增配置漂移检测文档和 Helm 参数
- `fixes typo in Helm clustermesh cert template`：修正 Helm clustermesh 证书模板拼写错误

## 适用场景

- **生产级 Kubernetes 网络**：大规模集群（100+ 节点）的扁平网络和策略管理
- **零信任安全**：基于身份的网络策略，覆盖 L3-L7 层
- **多集群互联**：跨云/跨数据中心的 ClusterMesh 部署
- **高性能服务网格**：替代 EnvoySidecar，提供 eBPF 加速的 L7 可观测性
- **合规要求**：内核级数据包捕获和审计日志

## 快速部署

```bash
# Helm 安装 Cilium
helm install cilium cilium/cilium \
  --namespace kube-system \
  --set ipam.mode=kubernetes \
  --set egressMasqueradeInterfaces=eth0 \
  --set hubble.enabled=true \
  --set hubble.ui.enabled=true

# 验证部署
cilium status
cilium connectivity test
```

## 技术优势对比

相比传统 iptables 方案（如 kube-proxy）：

| 维度       | iptables       | Cilium eBPF    |
| ---------- | -------------- | -------------- |
| 规则扩展性 | O(n)           | O(1) 哈希查找  |
| 最大规则数 | ~10k           | 无硬性限制     |
| 延迟       | 随规则线性增长 | 常数时间       |
| 可观测性   | 无内置         | Hubble 集成    |
| 加密       | 外部方案       | WireGuard 原生 |

## 相关资源

- 官方文档：https://docs.cilium.io
- GitHub Issues：https://github.com/cilium/cilium/issues
- Slack：#cilium（CNCF Slack）
