---
title: "Cilium 深度探索 (31)：Ambient Mode 概述"
date: 2026-04-14
tags:
  - cilium
  - ambient-mode
  - sidecarless
  - waypoint-proxy
  - zero-trust
  - service-mesh
  - envoy
  - ebpf
  - kubernetes
  - security
---

> [!info] Cilium 2026 深度探索系列 0. [[2026-04-14-cilium-deep-dive-series-index|系列索引]]
>
> 1. [[2026-04-14-cilium-deep-dive-ch1-cilium-overview|第一章：Cilium 概述]]
> 2. [[2026-04-14-cilium-deep-dive-ch2-architecture|第二章：Cilium 架构]]
>    ...
> 3. [[2026-04-14-cilium-deep-dive-ch29-cert-manager|第二十九章：Cert-Manager 与 TLS 自动化]]
> 4. [[2026-04-14-cilium-deep-dive-ch30-multitenancy|第三十章：多租户隔离]]
> 5. **第三十一章：Ambient Mode 概述** ←

---

## 1. Ambient Mode 概述

Ambient Mode 是 Cilium 1.14 引入的**无 Sidecar 零信任服务网格**模式。在传统 Sidecar 模式下，每个需要参与服务网格的 Pod 都需要注入一个 Sidecar 代理（Envoy），这带来显著的资源开销和运维复杂性。Ambient Mode 通过**节点级代理（Waypoint Proxy）** 替代 Per-Pod Sidecar，实现真正的零信任安全，同时降低资源消耗和部署复杂度。

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Ambient Mode 架构                                 │
│                                                                     │
│  ┌───────────────────────────────────────────────────────────────┐ │
│  │                        Kubernetes Node                         │ │
│  │                                                               │ │
│  │    ┌─────────────────────────────────────────────────────┐    │ │
│  │    │           Waypoint Proxy (节点级 Envoy)               │    │ │
│  │    │                                                       │    │ │
│  │    │   负责所有经过本节点 Pod 的 L4/L7 流量处理              │    │ │
│  │    │   • 身份认证 (mTLS)                                    │    │ │
│  │    │   • L7 策略执行                                        │    │ │
│  │    │   • 流量加密                                           │    │ │
│  │    └─────────────────────────────────────────────────────┘    │ │
│  │                          ▲                                      │ │
│  │                          │ 被劫持的网格流量                      │ │
│  │    ┌─────────────────────┼─────────────────────┐              │ │
│  │    │                     │                     │              │ │
│  │    │  ┌─────────────┐   │   ┌─────────────┐   │              │ │
│  │    │  │    Pod A     │◄──┴──►│    Pod B     │   │              │ │
│  │    │  │  (无需Sidecar)│       │  (无需Sidecar)│   │              │ │
│  │    │  └─────────────┘       └─────────────┘   │              │ │
│  │    │                                                  │    │ │
│  │    │  ┌─────────────┐   ┌─────────────┐            │    │ │
│  │    │  │    Pod C     │◄──┴──►│    Pod D     │            │    │ │
│  │    │  │  (无需Sidecar)│       │  (无需Sidecar)│            │    │ │
│  │    │  └─────────────┘       └─────────────┘            │    │ │
│  │    └─────────────────────────────────────────────────────┘    │ │
│  └───────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────┘
```

### 1.1 Sidecar vs Ambient 模式对比

| 特性           | Sidecar 模式              | Ambient 模式              |
| :------------- | :------------------------ | :------------------------ |
| **代理部署**   | 每个 Pod 注入独立 Sidecar | 节点级共享 Waypoint Proxy |
| **资源开销**   | O(n) Sidecar 数量         | O(节点数) Waypoint 数量   |
| **启动时间**   | Pod 启动依赖 Sidecar 就绪 | Pod 无需等待代理          |
| **升级影响**   | 升级 Sidecar 需重启 Pod   | Waypoint 升级不影响 Pod   |
| **L4 透明性**  | 需显式配置                | 自动劫持网格流量          |
| **L7 策略**    | 基于 Sidecar 执行         | 基于 Waypoint 执行        |
| **运维复杂度** | 高（大量 Sidecar）        | 低（节点级管理）          |

### 1.2 Ambient Mode 核心组件

```
┌─────────────────────────────────────────────────────────────────────┐
│                     Ambient Mode 核心组件                           │
│                                                                     │
│  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐ │
│  │   ztunnel       │    │  Waypoint Proxy  │    │    Cilium CLI   │ │
│  │                 │    │                  │    │                 │ │
│  │ • mTLS 加密      │    │ • L7 策略执行     │    │ • 模式切换       │ │
│  │ • L4 身份认证    │    │ • HTTP/gRPC 解析  │    │ • 组件管理       │ │
│  │ • 流量劫持      │    │ • 流量转发        │    │ • 状态监控       │ │
│  └─────────────────┘    └─────────────────┘    └─────────────────┘ │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │                      eBPF 数据面                              │   │
│  │  • 流量劫持 (sockmap/sendmsg/recvmsg)                        │   │
│  │  • 透明加密                                                  │   │
│  │  • 策略强制点                                                 │   │
│  └─────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 2. Ambient Mode 架构详解

### 2.1 组件职责

**ztunnel** 是 Ambient Mode 的 L4 组件，负责：

- **mTLS 隧道建立**：在节点间建立加密隧道
- **L4 流量劫持**：通过 eBPF sockmap 劫持 Pod 出向流量
- **身份传播**：将工作负载身份注入到 mTLS 证书中
- **健康检查**：检测对端点健康状态

**Waypoint Proxy** 是 Ambient Mode 的 L7 组件，负责：

- **L7 策略执行**：HTTP/gRPC 协议的深度检测
- **流量路由**：基于规则的请求转发
- **指标收集**：L7 访问日志和度量数据
- **负载均衡**：L7 级别的负载均衡策略

### 2.2 流量路径

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Ambient Mode 流量路径                             │
│                                                                     │
│  Pod A (client)                                      Pod B (server) │
│  ┌─────────────┐                                    ┌─────────────┐│
│  │   App        │                                    │   App        ││
│  │  :8080       │                                    │  :8080       ││
│  └──────┬───────┘                                    └──────┬───────┘│
│         │                                                  ▲        │
│         │ tcp connect()                                    │        │
│         ▼                                                  │        │
│  ┌─────────────┐   ┌─────────────────────────────────┐   │        │
│  │   eBPF       │──►│       ztunnel (L4 劫持)           │───┘        │
│  │  (sockmap)   │   │                                 │            │
│  │              │   │  1. 劫持 TCP 连接                  │            │
│  │              │   │  2. mTLS 加密                     │            │
│  │              │   │  3. 转发到 Waypoint 或直连        │            │
│  └─────────────┘   └─────────────────────────────────┘            │
│                                    │                                │
│                                    ▼                                │
│                      ┌─────────────────────────────────┐            │
│                      │    Waypoint Proxy (L7 处理)      │            │
│                      │                                  │            │
│                      │  • HTTP 头/路径解析               │            │
│                      │  • L7 策略匹配                    │            │
│                      │  • 请求转发                      │            │
│                      └─────────────────────────────────┘            │
└─────────────────────────────────────────────────────────────────────┘
```

**流量分类**：

1. **网格内到网格内（East-West）**：
   - L4：ztunnel → ztunnel（mTLS 加密）
   - L7：ztunnel → Waypoint → Waypoint → ztunnel

2. **网格内到网格外（North-South）**：
   - ztunnel 透明转发，不加密

### 2.3 命名空间启用

Ambient Mode 可以按命名空间启用，无需全集群开启：

```yaml
# 启用 namespace-wide ambient mode
apiVersion: v1
kind: Namespace
metadata:
  name: production
  labels:
    # 启用 Ambient Mode
    istio.io/dataplane-mode: ambient
```

---

## 3. Ambient Mode 与 eBPF

### 3.1 流量劫持机制

Ambient Mode 的 L4 流量劫持依赖 eBPF sockmap 技术：

```
┌─────────────────────────────────────────────────────────────────────┐
│                     eBPF Sockmap 劫持                               │
│                                                                     │
│  ┌───────────────────────────────────────────────────────────────┐ │
│  │                        eBPF Program                            │ │
│  │                                                               │ │
│  │   sk_msg hook ──────────────────────────────────────────►    │ │
│  │       │                                                       │ │
│  │       │  劫持 sendmsg/recvmsg                                  │ │
│  │       ▼                                                       │ │
│  │   sockhash/sockmap ──► 重定向到 ztunnel                        │ │
│  │                                                               │ │
│  └───────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────┘
```

**eBPF 程序挂载点**：

- `sk_msg`：劫持 `sendmsg`/`recvmsg` 系统调用
- `sk_skb`：劫持 socket 数据流
- `cgroup_sock`：在 cgroup 级别进行 socket 操作拦截

### 3.2 透明加密

Ambient Mode 利用 WireGuard 实现节点间流量加密：

```yaml
# Cilium 配置 - 启用 WireGuard 透明加密
apiVersion: cilium.io/v1alpha1
kind: CiliumConfig
metadata:
  name: cilium-config
spec:
  # WireGuard 透明加密
  encryption:
    enabled: true
    type: WireGuard
```

---

## 4. 启用 Ambient Mode

### 4.1 环境要求

- Kubernetes 1.24+
- Cilium 1.14+
- Helm 3.10+

### 4.2 安装步骤

```bash
# 1. 使用 Helm 安装 Cilium，开启 Ambient Mode
helm install cilium cilium/cilium \
  --version 1.14.6 \
  --namespace kube-system \
  --set ambient.enabled=true \
  --set ztunnel.enabled=true \
  --set egressGateway.enabled=true \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=<api-server-host> \
  --set k8sServicePort=6443

# 2. 等待 ztunnel DaemonSet 就绪
kubectl wait --for=condition=ready pod -l app=ztunnel -n kube-system --timeout=300s

# 3. 验证 ztunnel 运行状态
kubectl get pods -n kube-system -l app=ztunnel
```

### 4.3 命名空间配置

```yaml
# 为特定命名空间启用 Ambient Mode
apiVersion: v1
kind: Namespace
metadata:
  name: mesh-namespace
  labels:
    istio.io/dataplane-mode: ambient
---
# 部署示例应用
apiVersion: v1
kind: Pod
metadata:
  name: frontend
  namespace: mesh-namespace
  labels:
    app: frontend
spec:
  containers:
    - name: nginx
      image: nginx:1.25
      ports:
        - containerPort: 80
```

---

## 5. 验证 Ambient Mode

### 5.1 检查组件状态

```bash
# 检查 ztunnel DaemonSet
kubectl get ds -n kube-system ztunnel

# 检查 Waypoint Proxy (CiliumBGPPeeringPolicy)
kubectl get waypoint -A

# 检查节点级 Envoy 配置
kubectl exec -n kube-system ds/ztunnel -- cilium-dbg status
```

### 5.2 验证流量劫持

```bash
# 创建测试流量
kubectl exec -it <client-pod> -n mesh-namespace -- curl -v http://<service-name>.<namespace>.svc.cluster.local

# 使用 Hubble 观察流量
hubble observe --from-namespace mesh-namespace --to-namespace mesh-namespace
```

### 5.3 查看 ztunnel 日志

```bash
# 查看 ztunnel 日志
kubectl logs -n kube-system -l app=ztunnel --tail=100

# 实时跟踪
kubectl logs -n kube-system -l app=ztunnel -f
```

---

## 6. Ambient Mode 限制

### 6.1 当前限制

| 限制                             | 说明                                  |
| :------------------------------- | :------------------------------------ |
| **Waypoint 作用域**              | Waypoint 按 ServiceAccount 作用域隔离 |
| **L7 协议支持**                  | 仅支持 HTTP/gRPC，未来扩展            |
| **迁移限制**                     | 从 Sidecar 迁移需谨慎规划             |
| **CiliumClusterwideEnvoyConfig** | 暂不支持集群级 L7 配置                |

### 6.2 不兼容场景

- **Per-Pod Sidecar + Ambient 混合**：不支持
- **Namespace 级别的 ztunnel 注入**：暂不支持
- **Windows 节点**：Ambient Mode 仅支持 Linux

---

## 7. 总结

本章介绍了 Cilium Ambient Mode 的核心概念和架构设计：

**核心要点**：

- Ambient Mode 通过**节点级 Waypoint Proxy** 替代 Per-Pod Sidecar
- **ztunnel** 负责 L4 mTLS 加密和流量劫持
- **Waypoint Proxy** 负责 L7 策略执行
- Ambient Mode 支持**命名空间级别启用**
- 依赖 eBPF sockmap 技术实现透明流量劫持
- 显著降低资源开销和运维复杂度

**下一章节预告**：深入解析 **Waypoint Proxy** 的工作原理，包括身份感知路由、L7 策略执行、以及 Waypoint 的生命周期管理。

---

## 系列总结

Part VII（Ambient Mode）涵盖 Cilium 无 Sidecar 零信任网格的核心内容：

| 章节 | 主题              | 核心价值                         |
| :--- | :---------------- | :------------------------------- |
| 31   | Ambient Mode 概述 | 架构理念、组件职责、启用方式     |
| 32   | Waypoint Proxy    | L7 代理、身份路由、策略执行      |
| 33   | L4/L7 策略        | Ambient 模式下的策略应用         |
| 34   | 迁移指南          | 从 Sidecar 到 Ambient 的迁移路径 |

Ambient Mode 代表了 Cilium 在服务网格领域的重要演进，通过**无 Sidecar 架构**实现真正的零信任安全。
