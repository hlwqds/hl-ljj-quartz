---
title: "Cilium 深度探索 (16)：Hubble 观测平台概述"
date: 2026-04-14
tags:
  - cilium
  - hubble
  - observability
  - ebpf
  - kubernetes
  - networking
  - flow-visibility
  - cnc
---

> [!info] Cilium 2026 深度探索系列
> 0. [[2026-04-14-cilium-deep-dive-series-index|系列索引]]
> 1. [[2026-04-14-cilium-deep-dive-ch1-cilium-overview|第一章：Cilium 概述]]
> 2. [[2026-04-14-cilium-deep-dive-ch2-architecture|第二章：Cilium 架构]]
> 3. [[2026-04-14-cilium-deep-dive-ch3-ebpf-datapath|第三章：eBPF 数据面]]
> 4. [[2026-04-14-cilium-deep-dive-ch4-kube-proxy|第四章：Kube-Proxy 替代]]
> 5. [[2026-04-14-cilium-deep-dive-ch5-cni|第五章：CNI 集成]]
> 6. [[2026-04-14-cilium-deep-dive-ch6-clusterip|第六章：ClusterIP]]
> 7. [[2026-04-14-cilium-deep-dive-ch7-nodeport|第七章：NodePort]]
> 8. [[2026-04-14-cilium-deep-dive-ch8-loadbalancer|第八章：LoadBalancer]]
> 9. [[2026-04-14-cilium-deep-dive-ch9-externalip|第九章：ExternalIP]]
> 10. [[2026-04-14-cilium-deep-dive-ch10-vxlan|第十章：VXLAN]]
> 11. [[2026-04-14-cilium-deep-dive-ch11-cnp|第十一章：CiliumNetworkPolicy]]
> 12. [[2026-04-14-cilium-deep-dive-ch12-networkpolicy|第十二章：NetworkPolicy]]
> 13. [[2026-04-14-cilium-deep-dive-ch13-layer7|第十三章：L7 策略]]
> 14. [[2026-04-14-cilium-deep-dive-ch14-dns|第十四章：DNS 策略]]
> 15. [[2026-04-14-cilium-deep-dive-ch15-categories|第十五章：策略层级]]
> 16. **第十六章：Hubble 概述** ←

---

## 1. Hubble 概述

Hubble 是 Cilium 的内置可观测性平台，专为 Kubernetes 环境和 Cilium 管理的网络流量设计。Hubble 利用 eBPF 的能力，在内核层面以极低的开销捕获网络流量元数据，提供**实时 Flow 可视化**、**网络拓扑感知**、**服务依赖图**以及**安全策略审计**能力。

Hubble 的核心设计哲学是：**网络可观测性应该是零摩擦的**，不需要额外部署探针或修改应用代码，即可获得完整的网络可见性。

```
┌─────────────────────────────────────────────────────────────┐
│                    Hubble 观测平台架构                        │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                   Hubble Server                      │   │
│  │            (每个 Agent 节点上的 DaemonSet)             │   │
│  │                                                        │   │
│  │   ┌─────────────┐  ┌─────────────┐  ┌──────────┐   │   │
│  │   │ Flow API    │  │ Metrics API │  │ Sockmap  │   │   │
│  │   │ (gRPC)      │  │ (Prom)      │  │ (L7)     │   │   │
│  │   └─────────────┘  └─────────────┘  └──────────┘   │   │
│  └─────────────────────────────────────────────────────┘   │
│                           │                                 │
│         ┌─────────────────┼─────────────────┐               │
│         ▼                 ▼                 ▼               │
│  ┌────────────┐   ┌────────────┐   ┌────────────┐        │
│  │ Hubble CLI │   │  Hubble UI │   │ Prometheus  │        │
│  │ (命令行工具) │   │ (Web 控制台) │   │ + Grafana   │        │
│  └────────────┘   └────────────┘   └────────────┘        │
└─────────────────────────────────────────────────────────────┘
```

### 1.1 Hubble 与 Cilium 的关系

Hubble 不是独立存在的组件，它深度集成在 Cilium Agent 中：

- **Cilium Agent** 负责管理 eBPF 程序的生命周期，包括网络策略执行
- **Hubble Server** 是 Cilium Agent 内置的子组件，提供 Flow 观测 API
- **eBPF Flow Hook** 位于 Cilium 数据面的关键路径上，生成 Flow 事件

```
Cilium Agent
├── eBPF Data Path
│   └── [Flow Hook] ──→ Flow Events
├── Hubble Server (gRPC API :4244)
│   ├── Flow 实时流
│   └── Agent State API
└── Prometheus Metrics Exporter (:9090)
```

### 1.2 Hubble 的核心能力

| 能力 | 描述 | 数据来源 |
|:---|:---|:---|
| **Flow 可视化** | 实时查看所有网络流量（入口/出口/转发） | eBPF perf ring |
| **服务依赖图** | 自动发现服务间调用拓扑关系 | Flow 聚合 |
| **策略可视化** | 展示策略匹配结果（允许/拒绝/审计） | eBPF verdict hook |
| **L7 观测** | HTTP/gRPC/DNS 等 L7 协议请求追踪 | Envoy/L7 proxy |
| **网络指标** | 延迟、吞吐、连接数等 Prometheus 指标 | Metrics API |
| **分布式追踪** | 与 OpenTelemetry 集成的 Trace | OTel exporter |

---

## 2. Hubble 架构详解

### 2.1 整体架构

Hubble 采用**分布式收集 + 集中消费**的架构：

```
┌──────────────────────────────────────────────────────────────────────┐
│                         Hubble 架构                                   │
│                                                                      │
│  ┌─────────────┐                                                    │
│  │  Cluster    │                                                    │
│  │  Network    │                                                    │
│  └──────┬──────┘                                                    │
│         │                                                            │
│  ┌──────┴──────┐  ┌─────────────┐  ┌─────────────┐                │
│  │ Node 1      │  │ Node 2      │  │ Node N      │                │
│  │ ┌────────┐  │  │ ┌────────┐  │  │ ┌────────┐  │                │
│  │ │Cilium  │  │  │ │Cilium  │  │  │ │Cilium  │  │                │
│  │ │Agent   │  │  │ │Agent   │  │  │ │Agent   │  │                │
│  │ │        │  │  │ │        │  │  │ │        │  │                │
│  │ │Hubble  │  │  │ │Hubble  │  │  │ │Hubble  │  │                │
│  │ │Server  │  │  │ │Server  │  │  │ │Server  │  │                │
│  │ └────┬───┘  │  │ └────┬───┘  │  │ └────┬───┘  │                │
│  │      │      │  │      │      │  │      │      │                │
│  │  [eBPF Flow] │  │  [eBPF Flow] │  │  [eBPF Flow] │                │
│  └──────┴──────┘  └──────┴──────┘  └──────┴──────┘                │
│         │                 │                 │                      │
│         └─────────────────┼─────────────────┘                      │
│                           │                                        │
│                    ┌──────▼──────┐                                 │
│                    │ Relay Server │ (可选，集中聚合)                  │
│                    │ (ClusterMesh)│                                 │
│                    └──────┬──────┘                                 │
│                           │                                        │
│              ┌────────────┼────────────┐                          │
│              ▼            ▼            ▼                           │
│        ┌─────────┐  ┌─────────┐  ┌─────────┐                    │
│        │Hubble CLI│  │Hubble UI│  │Prometheus│                    │
│        └─────────┘  └─────────┘  └─────────┘                    │
└──────────────────────────────────────────────────────────────────────┘
```

### 2.2 Hubble Server

Hubble Server 是每个 Cilium Agent 节点上运行的 gRPC 服务（默认监听 `:4244` 端口），负责：

1. **收集 eBPF Flow 事件**：从 eBPF perf ring buffer 读取 Flow 数据
2. **聚合与富化**：将原始 Flow 与 Kubernetes API（Pod、Service、Endpoint 元数据）关联
3. **服务发现**：提供 Node/Service/Pod 的实时状态查询
4. **状态 API**：返回 Cilium 端点、策略、身份等运行时状态

```bash
# 查看 Hubble Server 状态
cilium hubble status

# 期望输出
Hubble Server: OK   (localhost:4244)
TLS: OK   (mTLS)
Peer Name: node-1
Node Addresses:
  - 10.0.0.1 (IPv4)
  - fd00::1 (IPv6)
```

### 2.3 eBPF Flow 生成机制

Hubble 的 Flow 数据来源于 Cilium eBPF 数据面的多个 Hook 点：

```
┌─────────────────────────────────────────────────────────────┐
│              eBPF Flow 生成点                                 │
│                                                             │
│  Packet Ingress                                              │
│       │                                                     │
│       ▼                                                     │
│  [tc ingress hook] ──→ Flow Event (L3/L4)                  │
│       │                                                     │
│       ▼                                                     │
│  [socket transform] ──→ Flow Event (socket-level)          │
│       │                                                     │
│       ▼                                                     │
│  [policy verdict] ────→ Flow Event (allow/deny)            │
│       │                                                     │
│       ▼                                                     │
│  [forwarding] ────────→ Flow Event (forward/drop)          │
│       │                                                     │
│       ▼                                                     │
│  Packet Egress                                              │
└─────────────────────────────────────────────────────────────┘
```

每个 Flow 事件包含：

| 字段 | 描述 |
|:---|:---|
| `source` | 源 IP、端口、Pod、Namespace、身份 |
| `destination` | 目标 IP、端口、Pod、Namespace、身份 |
| `layer` | 事件层级（L2/L3/L4/L7） |
| `verdict` | 流量判定（forwarded、dropped、audited） |
| `timestamp` | 事件时间戳 |
| `DNS` | DNS 查询域名（如果适用） |
| `http` | HTTP 方法/路径/状态码（如果适用） |
| `traffic_direction` | 入口或出口 |
| `namespace` | 源/目标命名空间 |
| `pod_name` | 源/目标 Pod 名称 |

### 2.4 Hubble Relay（可选组件）

在多节点集群中，Hubble Relay 提供**跨节点的 Flow 聚合服务**：

```yaml
# Hubble Relay 部署
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hubble-relay
spec:
  replicas: 1
  template:
    spec:
      containers:
        - name: relay
          image: quay.io/cilium/hubble-relay:latest
          ports:
            - containerPort: 4245  # gRPC API
```

Hubble Relay 的作用：
- 聚合集群中所有节点的 Hubble Server Flow 数据
- 提供统一的 gRPC API 端点（`:4245`）
- 支持跨 ClusterMesh 的多集群 Flow 聚合

```bash
# 配置 Hubble CLI 连接到 Relay
hubble config view
# server: "clusterMesh-hubble-relay:443"
```

---

## 3. Flow 可视化核心概念

### 3.1 Flow 生命周期

每个网络包在 Cilium eBPF 数据面中经历完整的 Flow 生命周期：

```
┌─────────────────────────────────────────────────────────────┐
│                  Flow 生命周期                                │
│                                                             │
│  1. PACKET RECEIVED                                         │
│       │                                                    │
│       ▼                                                    │
│  2. SOURCE IDENTITY RESOLUTION                              │
│       │  → 根据源 IP 解析 Cilium 身份                        │
│       ▼                                                    │
│  3. POLICY LOOKUP (入口)                                    │
│       │  → 匹配 CiliumNetworkPolicy / NetworkPolicy         │
│       ▼                                                    │
│  4. VERDICT                                                │
│       │  → ALLOWED → 继续处理                              │
│       │  → DENIED  → 记录 dropped Flow → 丢弃包             │
│       ▼                                                    │
│  5. SERVICE RESOLUTION (如果是 Service 流量)                 │
│       │  → ClusterIP → Backend Pod IP                       │
│       ▼                                                    │
│  6. FORWARDING / ENCAPSULATION                              │
│       │  → VXLAN / Direct Routing                          │
│       ▼                                                    │
│  7. POLICY LOOKUP (出口)                                    │
│       │  → 匹配出口策略                                     │
│       ▼                                                    │
│  8. PACKET TRANSMITTED                                      │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 Flow Verdict

每个 Flow 都有一个 verdict（判定结果）：

| Verdict | 描述 | 产生阶段 |
|:---|:---|:---|
| `FORWARDED` | 流量被允许并转发 | Policy verdict |
| `DROPPED` | 流量被策略拒绝丢弃 | Policy verdict |
| `AUDITED` | 流量匹配审计规则（记录但不丢弃） | Policy verdict |
| `ERROR` | 处理过程中发生错误 | Various |
| `TRANSLATED` | NAT/端口转换完成 | NAT handling |

### 3.3 Flow 与 Kubernetes 元数据富化

原始 eBPF Flow 只包含 IP 元数据，Hubble Server 通过查询 Kubernetes API 为 Flow 补充丰富的上下文信息：

```json
{
  "flow": {
    "time": "2026-04-14T10:30:00.123456789Z",
    "verdict": "FORWARDED",
    "drop_reason": null,
    "source": {
      "namespace": "production",
      "pod_name": "api-gateway-7d8f9c6b5-xk9pq",
      "labels": ["app=api-gateway", "version=v2"],
      "workloads": [{
        "kind": "Deployment",
        "name": "api-gateway",
        "namespace": "production"
      }]
    },
    "destination": {
      "namespace": "production",
      "pod_name": "backend-service-6b7c8d9e4-m2n8p",
      "labels": ["app=backend-service"],
      "workloads": [{
        "kind": "Deployment",
        "name": "backend-service",
        "namespace": "production"
      }]
    },
    "layer": {
      "spec": {
        "source": "10.0.1.45:54321",
        "destination": "10.0.2.67:8080",
        "protocol": "TCP"
      },
      "summary": "HTTP GET /api/v1/users"
    },
    "destination_names": ["backend-service.production.svc.cluster.local"]
  }
}
```

### 3.4 L7 Flow 详情

当流量经过 L7 代理（如 Envoy sidecar 或 Waypoint Proxy）时，Hubble 捕获 L7 协议信息：

```json
{
  "flow": {
    "time": "2026-04-14T10:30:01.234Z",
    "verdict": "FORWARDED",
    "source": {
      "namespace": "production",
      "pod_name": "frontend-5f9b8c7d6-l3m4n"
    },
    "destination": {
      "namespace": "production",
      "pod_name": "api-gateway-7d8f9c6b5-xk9pq"
    },
    "l7": {
      "protocol": "http",
      "http": {
        "method": "GET",
        "path": "/api/v1/products/123",
        "code": 200,
        "headers": [
          "user-agent: curl/7.68.0",
          "authorization: Bearer ***",
          "x-request-id: a1b2c3d4-e5f6"
        ]
      }
    },
    "traffic_direction": "INGRESS"
  }
}
```

---

## 4. Hubble 部署与配置

### 4.1 启用 Hubble

Cilium 安装时默认不启用 Hubble，需要显式配置：

```bash
# via Helm
helm install cilium cilium/cilium \
  --namespace kube-system \
  --set hubble.enabled=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  --set prometheus.enabled=true \
  --set operator.prometheus.enabled=true

# via cilium CLI
cilium install --enable-hubble --enable-hubble-relay --enable-hubble-ui
```

### 4.2 Hubble UI 部署

Hubble UI 提供 Web 界面用于可视化网络流量和服务拓扑：

```bash
# 检查 Hubble UI 状态
kubectl get pods -n kube-system -l k8s-app=hubble-ui
kubectl get svc -n kube-system hubble-ui

# 端口转发访问
kubectl port-forward -n kube-system svc/hubble-ui 8080:80

# 访问 http://localhost:8080
```

### 4.3 Hubble 指标配置

```yaml
# Hubble Metrics 配置
apiVersion: cilium.io/v2alpha1
kind: CiliumClusterwideHubbleMetrics
metadata:
  name: metrics
spec:
  - nodeport
  -旗袍
  - controller
  - per-endpoint流量
```

### 4.4 Hubble TLS 配置

Hubble Server 与 Relay 之间默认使用 mTLS 加密通信：

```bash
# 检查 TLS 状态
cilium hubble status

# 手动轮转 TLS 证书
cilium hubble certificate rotate
```

---

## 5. 常见使用场景

### 5.1 实时流量监控

```bash
# 实时监控所有 Flow
hubble observe

# 过滤特定 Namespace 的流量
hubble observe --namespace production

# 过滤特定 Pod 的流量
hubble observe --pod frontend-5f9b8c7d6-l3m4n

# 只看被丢弃的流量
hubble observe --type drop

# 只看 L7 HTTP 流量
hubble observe --protocol http

# 过滤特定服务
hubble observe --service backend-service:8080
```

### 5.2 服务依赖分析

```bash
# 生成服务依赖矩阵
hubble observe --format json | jq -r '
  .source.namespace + "/" + .source.pod_name + " -> " + 
  .destination.namespace + "/" + .destination.pod_name
' | sort | uniq -c | sort -rn

# 使用 hubble graph（需要 Prometheus）
hubble graph --namespace production --duration 10m
```

### 5.3 策略调试

```bash
# 监控特定策略的匹配情况
hubble observe --from-label app=frontend --to-label app=backend

# 检查被拒绝的流量
hubble observe --verdict DROPPED --last 100

# 检查策略审计日志
hubble observe --type audit --last 50
```

### 5.4 延迟分析

```bash
# 查看 HTTP 请求延迟分布
hubble observe --protocol http --format json | jq -r '
  select(.l7.http) | .l7.http.latency_ns
' | awk '{sum+=$1; count++} END {print "Avg latency: " sum/count/1000000 "ms"}'
```

---

## 6. Hubble 与其他观测工具对比

| 维度 | Hubble | Cilium + Prometheus | DeepFlow | Suricata |
|:---|:---|:---|:---|:---|
| **数据来源** | eBPF Flow | eBPF Metrics | eBPF + AF_XDP | AF_XDP/pcap |
| **部署复杂度** | 低（内置） | 低 | 中 | 中 |
| **L7 可见性** | HTTP/gRPC/DNS | 有限 | 完整 | 深度包检测 |
| **存储** | 实时/短时 | Prometheus | ClickHouse | Eve JSON |
| **延迟开销** | 极低 | 极低 | 低 | 中 |
| **分布式追踪** | OpenTelemetry | 否 | 是 | 否 |

---

## 7. 总结

Hubble 是 Cilium 可观测性的核心支柱，它充分利用 eBPF 的内核级可见性，以极低开销提供全集群的网络流量观测能力。通过 Hubble，用户可以：

1. **零代码侵入**：无需修改应用即可获得完整网络可见性
2. **全链路追踪**：从 L2 到 L7 的完整流量视图
3. **策略审计**：实时验证网络策略的实际效果
4. **服务拓扑**：自动发现服务间依赖关系
5. **多维度指标**：与 Prometheus/Grafana 深度集成

下一章我们将深入探讨 **Hubble CLI** 的详细用法，学习如何通过命令行工具高效地进行网络流量分析和问题诊断。
