---
title: Hubble - 基于 eBPF 的 Kubernetes 网络可观测性平台
date: 2026-04-09 10:00:00
tags: [ebpf, kubernetes, observability, cilium, networking]
description: Hubble 是构建在 Cilium 和 eBPF 之上的分布式网络和安全可观测性平台
---

# Hubble - 基于 eBPF 的 Kubernetes 网络可观测性平台

## 项目概览

| 属性         | 值                                                |
| ------------ | ------------------------------------------------- |
| **GitHub**   | [cilium/hubble](https://github.com/cilium/hubble) |
| **Stars**    | 4.1k                                              |
| **语言**     | Go                                                |
| **最新更新** | 3天前 (2026-03-31)                                |
| **最新版本** | v1.18                                             |
| **License**  | Apache-2.0                                        |

## 核心定位

Hubble 是构建在 **Cilium** 和 **eBPF** 之上的完全分布式网络和安全可观测性平台，为云原生工作负载提供深度可见性。

### 它能回答的问题

**服务依赖与通信地图：**

- 哪些服务在相互通信？频率如何？服务依赖图长什么样？
- 哪些 HTTP 调用正在发生？服务消费哪些 Kafka topics？

**运维监控与告警：**

- 是否有网络通信失败？为什么失败？是 DNS、应用还是网络问题？
- 哪些服务最近遇到 TCP 连接中断或超时？
- TCP SYN 请求未回复率是多少？

**应用监控：**

- 某服务或整个集群的 5xx/4xx HTTP 响应码比率是多少？
- HTTP 请求与响应的 P95/P99 延迟是多少？
- 两服务之间的延迟是多少？

**安全可观测性：**

- 哪些服务因网络策略被阻止连接？
- 哪些服务从集群外部访问？
- 哪些服务解析了特定 DNS 名称？

## 技术架构

```
┌─────────────────────────────────────────────────────────────┐
│                      Hubble UI (Beta)                       │
├─────────────────────────────────────────────────────────────┤
│                    Hubble Relay (多节点)                     │
├─────────────────────────────────────────────────────────────┤
│           Hubble Server (Stable)  ←── eBPF                   │
│              ↕ via gRPC                                         │
├─────────────────────────────────────────────────────────────┤
│                    Cilium Agent                              │
├─────────────────────────────────────────────────────────────┤
│                      Linux Kernel                            │
│                    (eBPF Hooks)                              │
└─────────────────────────────────────────────────────────────┘
```

### 核心组件状态

| 组件           | 领域   | 状态   |
| -------------- | ------ | ------ |
| Hubble CLI     | 核心   | Stable |
| Hubble Server  | 核心   | Stable |
| Hubble Metrics | 核心   | Stable |
| Hubble Relay   | 多节点 | Stable |
| Hubble UI      | UI     | Beta   |

## 核心功能

### 1. Service Dependency Graph (服务依赖图)

Hubble 自动发现 Kubernetes 集群在 L3/L4 甚至 L7 的服务依赖图，提供零努力的自动服务地图可视化。

### 2. Metrics & Monitoring

提供系统状态概览，支持识别故障模式：

- **网络行为指标**：TCP/UDP 连接状态
- **网络策略观测**：哪些连接被策略阻止
- **HTTP 请求/响应率与延迟**
- **DNS 请求/响应监控**

### 3. Flow Visibility

在网络和应用协议级别提供流量可见性：

```bash
# 查看 DNS 解析失败
hubble observe --since=1m -t l7 -o json \
  | jq 'select(.l7.dns.rcode==3)'

# 查看 HTTP 请求与延迟
hubble observe --protocol=http
```

## 与 Cilium 的关系

Hubble 依赖 Cilium 的 eBPF 功能：

- Cilium 负责在内核中插入 eBPF 程序捕获网络流量
- Hubble 负责收集、聚合和展示这些数据
- Hubble CLI 与所有支持的 Cilium 版本向后兼容

## 适用场景

1. **Kubernetes 生产环境网络诊断**
2. **微服务依赖分析**
3. **安全事件调查（哪些服务被阻止）**
4. **性能瓶颈定位（P95/P99 延迟）**
5. **DNS 问题排查**

## 快速开始

```bash
# 安装 Hubble CLI
curl -LO https://github.com/cilium/hubble/releases/latest/download/hubble-linux-amd64.tar.gz
tar -xzf hubble-linux-amd64.tar.gz

# 在 Cilium 启用 Hubble
cilium hubble enable

# 查看流量
hubble observe
```

## 与 DeepFlow 对比

| 维度     | Hubble            | DeepFlow |
| -------- | ----------------- | -------- |
| 依赖     | 必须配合 Cilium   | 独立部署 |
| 语言     | Go                | Go       |
| L7 协议  | HTTP/Kafka/DNS    | 多种协议 |
| 服务图   | 支持              | 支持     |
| 集成方式 | Kubernetes Native | 多环境   |

Hubble 更适合已经使用 Cilium 的 Kubernetes 环境，DeepFlow 则提供更广泛的环境支持和更丰富的 L7 协议支持。

---

**相关项目**：

- [Cilium](https://github.com/cilium/cilium) - 24.1k stars，eBPF-based Networking, Security, and Observability
- [eCapture](https://github.com/gojue/ecapture) - 无 CA 证书捕获 SSL/TLS 明文
