---
title: "Cilium 深度探索 (32)：Waypoint Proxy"
date: 2026-04-14
tags:
  - cilium
  - waypoint-proxy
  - ambient-mode
  - envoy
  - l7-proxy
  - identity-aware
  - service-mesh
  - ebpf
  - kubernetes
  - security
---

> [!info] Cilium 2026 深度探索系列
> 0. [[2026-04-14-cilium-deep-dive-series-index|系列索引]]
> 1. [[2026-04-14-cilium-deep-dive-ch1-cilium-overview|第一章：Cilium 概述]]
> ...
> 30. [[2026-04-14-cilium-deep-dive-ch30-multitenancy|第三十章：多租户隔离]]
> 31. [[2026-04-14-cilium-deep-dive-ch31-ambient-overview|第三十一章：Ambient Mode 概述]]
> 32. **第三十二章：Waypoint Proxy** ←

---

## 1. Waypoint Proxy 概述

Waypoint Proxy 是 Cilium Ambient Mode 的 L7 代理组件，基于 Envoy 构建，负责处理应用层协议（HTTP/gRPC）的深度检测和策略执行。与传统 Sidecar 代理不同，Waypoint Proxy 采用**节点级部署 + ServiceAccount 作用域**的架构，实现资源高效利用和策略隔离。

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Waypoint Proxy 架构                              │
│                                                                     │
│  ┌───────────────────────────────────────────────────────────────┐ │
│  │                    Kubernetes Cluster                           │ │
│  │                                                               │ │
│  │  ┌─────────────────────────────────────────────────────────┐  │ │
│  │  │                 ServiceAccount: payment                  │  │ │
│  │  │  ┌─────────────────────────────────────────────────────┐ │  │ │
│  │  │  │        Waypoint Proxy (Envoy)                        │ │  │ │
│  │  │  │                                                      │ │  │ │
│  │  │  │  • 策略执行: payment 服务的所有 L7 流量               │ │  │ │
│  │  │  │  • 身份认证: 基于 SPIFFE/SPIRE 的 mTLS               │ │  │ │
│  │  │  │  • 负载均衡: L7 级别加权轮询、重试、超时              │ │  │ │
│  │  │  └─────────────────────────────────────────────────────┘ │  │ │
│  │  └─────────────────────────────────────────────────────────┘  │ │
│  │                                                               │ │
│  │    Pod: payment-api        Pod: payment-worker       Pod: order-svc │
│  │    (sa: payment)            (sa: payment)             (sa: order)    │
│  │    ┌───────────┐           ┌───────────┐           ┌───────────┐  │
│  │    │   App     │           │   App     │           │   App     │  │
│  │    │ :8080     │           │ :8080     │           │ :8080     │  │
│  │    └───────────┘           └───────────┘           └───────────┘  │
│  │                                                               │ │
│  │  ┌─────────────────────────────────────────────────────────┐  │ │
│  │  │               ServiceAccount: order                      │  │ │
│  │  │  ┌─────────────────────────────────────────────────────┐ │  │ │
│  │  │  │        Waypoint Proxy (Envoy)                        │ │  │ │
│  │  │  │                                                      │ │  │ │
│  │  │  │  • 策略执行: order 服务的所有 L7 流量                 │ │  │ │
│  │  │  │  • 认证: order 到 payment 的调用需通过 waypoint      │ │  │ │
│  │  │  └─────────────────────────────────────────────────────┘ │  │ │
│  │  └─────────────────────────────────────────────────────────┘  │ │
│  └───────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────┘
```

### 1.1 Waypoint vs Sidecar

| 特性 | Sidecar Proxy | Waypoint Proxy |
|:---|:---|:---|
| **部署方式** | Per-Pod | Per-ServiceAccount |
| **资源占用** | O(n) Pod 数量 | O(m) ServiceAccount 数量 |
| **启动依赖** | Pod 等待 Sidecar | Waypoint 独立部署 |
| **升级影响** | 升级重启 Pod | Waypoint 滚动升级 |
| **故障域** | 单个 Pod | 单个服务 |
| **策略作用域** | 单个 Pod | ServiceAccount 级别 |

### 1.2 Waypoint 核心能力

- **L7 协议处理**：HTTP/1.1、HTTP/2、gRPC
- **L7 策略执行**：基于路径、方法、header 的访问控制
- **身份感知路由**：基于 SPIFFE 身份的安全策略
- **可观测性**：L7 指标、访问日志、分布式追踪
- **负载均衡**：加权轮询、故障注入、重试策略

---

## 2. Waypoint Proxy 工作原理

### 2.1 流量拦截机制

Ambient Mode 中，Pod 的 L7 流量通过 ztunnel (L4) 劫持后，**按需转发到 Waypoint Proxy**：

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Waypoint 流量拦截流程                             │
│                                                                     │
│  Pod A (client)                                      Pod B (server) │
│  ┌─────────────┐                                    ┌─────────────┐│
│  │   App        │                                    │   App        ││
│  └──────┬───────┘                                    └──────┬───────┘│
│         │                                                  ▲        │
│         │ HTTP 请求                                          │        │
│         ▼                                                  │        │
│  ┌─────────────┐   ┌───────────────┐   ┌───────────────────┴───┐   │
│  │   ztunnel    │──►│ Waypoint Proxy │──►│     ztunnel          │   │
│  │   (L4)       │   │    (L7)        │   │     (L4)             │   │
│  │              │   │               │   │                      │   │
│  │  • mTLS      │   │  • HTTP 解析  │   │  • mTLS 解密        │   │
│  │  • L4 转发    │   │  • L7 策略    │   │  • L4 转发          │   │
│  │              │   │  • 指标收集   │   │                      │   │
│  └─────────────┘   └───────────────┘   └──────────────────────┘   │
│                                                                     │
│  L7 策略匹配流程:                                                   │
│  1. ztunnel 劫持 TCP 连接                                          │
│  2. 如果是 L7 流量，转发到 Waypoint                                 │
│  3. Waypoint 执行 L7 策略                                           │
│  4. 允许/拒绝/修改后转发                                            │
└─────────────────────────────────────────────────────────────────────┘
```

**L4 直连路径**（无 L7 策略时）：

```
Pod A ──mTLS──► ztunnel A ──────────mTLS──► ztunnel B ──► Pod B
```

**L7 路径**（有 L7 策略时）：

```
Pod A ──mTLS──► ztunnel A ──HTTP──► Waypoint ──HTTP──► ztunnel B ──mTLS──► Pod B
```

### 2.2 Waypoint 生命周期

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Waypoint 生命周期                                │
│                                                                     │
│  ┌─────────────┐                                                   │
│  │   创建      │  CiliumAgent 监听 CiliumCiliumL7Policy CRD        │
│  └──────┬──────┘                                                   │
│         │                                                         │
│         ▼                                                         │
│  ┌─────────────┐                                                   │
│  │   编译      │  生成 Envoy xDS 配置                               │
│  │   xDS 配置  │  • LDS: Listener 配置                             │
│  └──────┬──────┘  • RDS: Route 配置                                │
│         │        • CDS: Cluster 配置                              │
│         │        • ECDS: ExtensionConfig                          │
│         ▼                                                         │
│  ┌─────────────┐                                                   │
│  │   部署      │  在节点上启动 Envoy 进程                           │
│  │   Envoy    │  监听 Unix Domain Socket                           │
│  └──────┬──────┘                                                   │
│         │                                                         │
│         ▼                                                         │
│  ┌─────────────┐                                                   │
│  │   就绪      │  ztunnel 开始转发 L7 流量                           │
│  └──────┬──────┘                                                   │
│         │                                                         │
│         ▼                                                         │
│  ┌─────────────┐                                                   │
│  │   更新      │  策略变更时重新编译 xDS 并热更新                    │
│  │   xDS      │                                                   │
│  └─────────────┘                                                   │
└─────────────────────────────────────────────────────────────────────┘
```

### 2.3 xDS 配置生成

Cilium Agent 将 CiliumNetworkPolicy 转换为 Envoy xDS 配置：

```yaml
# CiliumNetworkPolicy (L7)
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: payment-l7-policy
spec:
  endpointSelector:
    matchLabels:
      app: payment
  ingress:
  - fromEndpoints:
    - matchLabels:
        app: order
    toPorts:
    - port: "8080"
      protocol: TCP
      rules:
        http:
        - method: "GET"
          path: "/api/v1/payments.*"
        - method: "POST"
          path: "/api/v1/refund"
```

转换后的 Envoy Route 配置：

```json
{
  "name": "payment-ingress",
  "virtual_hosts": [{
    "name": "payment",
    "domains": ["payment:8080"],
    "routes": [{
      "match": {
        "prefix": "/api/v1/payments"
      },
      "route": {
        "cluster": "payment-backend"
      },
      "metadata_match": {
        "filter_metadata": {
          "envoy.lb": {
            "version": "v1"
          }
        }
      }
    }]
  }]
}
```

---

## 3. Waypoint 部署与管理

### 3.1 自动部署

Waypoint Proxy 由 Cilium Agent 自动管理，无需手动部署。当创建 CiliumNetworkPolicy 引用某个 ServiceAccount 时，Cilium 会自动为该 ServiceAccount 创建 Waypoint Proxy：

```bash
# 触发 Waypoint 部署
kubectl apply -f- <<EOF
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: payment-l7
spec:
  endpointSelector:
    matchLabels:
      app: payment
  ingress:
  - fromEndpoints:
    - matchLabels:
        app: order
    toPorts:
    - ports:
      - port: "8080"
        protocol: TCP
      rules:
        http:
        - method: GET
          path: "/api/v1/.*"
EOF

# 检查自动创建的 Waypoint
kubectl get ciliumenvoyconfigs -A
```

### 3.2 Waypoint 资源规格

```yaml
# 自定义 Waypoint 规格
apiVersion: cilium.io/v2
kind: CiliumEnvoyConfig
metadata:
  name: payment-waypoint
  namespace: default
spec:
  # Waypoint 作用域
  workload_selector:
    kind: ServiceAccount
    name: payment
  # 资源规格
  resources:
    - kind: CiliumClusterwideEnvoyConfig
      name: payment-clusterwide
  # 连接数限制
  connection_limit: 10000
  # 粘性会话
  session_affinity:
    enabled: true
    timeout: 10800s
```

### 3.3 查看 Waypoint 状态

```bash
# 列出所有 Waypoint
kubectl get ciliumenvoyconfigs -A

# 查看 Waypoint 详情
kubectl describe ciliumenvoyconfigs <name> -n <namespace>

# 检查 Envoy 日志
kubectl logs -n kube-system -l app=cilium-envoy --tail=100

# 查看 Envoy 配置
kubectl exec -n kube-system -it ztunnel-xxxx -- curl -s localhost:15000/config_dump
```

---

## 4. 身份感知路由

### 4.1 SPIFFE 身份体系

Waypoint Proxy 利用 SPIFFE/SPIRE 实现工作负载身份认证：

```
┌─────────────────────────────────────────────────────────────────────┐
│                    SPIFFE 身份认证流程                               │
│                                                                     │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐             │
│  │   SPIRE     │───►│  ztunnel    │───►│  Waypoint   │             │
│  │   Server    │    │             │    │             │             │
│  │             │    │  • SVID 颁发 │    │  • 验证 SVID │             │
│  │  • CA       │    │  • mTLS     │    │  • 策略匹配  │             │
│  │  • SVID     │    │             │    │             │             │
│  └─────────────┘    └─────────────┘    └─────────────┘             │
│                                                                     │
│  SPIFFE ID 格式:                                                    │
│  spiffe://cluster.local/ns/default/sa/payment                       │
└─────────────────────────────────────────────────────────────────────┘
```

### 4.2 基于身份的策略

```yaml
# 基于 SPIFFE 身份的 L7 策略
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: identity-based-l7
spec:
  endpointSelector:
    matchLabels:
      app: payment
  ingress:
  - fromRequires:
    - matchLabels:
        # 要求调用方必须具有特定 SPIFFE 身份
        io.cilium.k8s.policy.cluster: default
        io.cilium.k8s.policy.namespace: order
    toPorts:
    - ports:
      - port: "8080"
        protocol: TCP
      rules:
        http:
        - method: "POST"
          path: "/api/v1/refund"
          headers:
          - "X-Request-ID": ".*"
```

### 4.3 mTLS 配置

Waypoint 自动为所有网格流量启用 mTLS：

```bash
# 查看 ztunnel 的 mTLS 证书信息
kubectl exec -it -n kube-system ztunnel-xxxx -- systemctl status ztunnel

# 检查 SPIRE 注册状态
kubectl exec -it -n kube-system ztunnel-xxxx -- curl -s localhost:15000/certs
```

---

## 5. L7 策略执行

### 5.1 HTTP 策略类型

```yaml
# HTTP 方法和路径限制
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: http-method-path
spec:
  endpointSelector:
    matchLabels:
      app: api
  ingress:
  - toPorts:
    - ports:
      - port: "8080"
        protocol: TCP
      rules:
        http:
        # 只允许 GET 和 POST
        - method: "GET"
          path: "/api/v1/.*"
        - method: "POST"
          path: "/api/v1/.*"
```

```yaml
# Header 基础策略
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: header-based
spec:
  endpointSelector:
    matchLabels:
      app: api
  ingress:
  - toPorts:
    - ports:
      - port: "8080"
        protocol: TCP
      rules:
        http:
        # 要求特定 Header
        - headerMatchers:
            "Authorization":
              safeRegex: "Bearer .*"
            "X-Request-ID":
              presentMatch: true
          path: "/api/v1/.*"
```

```yaml
# 速率限制策略
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: rate-limit
spec:
  endpointSelector:
    matchLabels:
      app: api
  ingress:
  - toPorts:
    - ports:
      - port: "8080"
        protocol: TCP
      rules:
        http:
        - method: "GET"
          path: "/api/v1/.*"
          # 每分钟 100 个请求
          rateLimit:
            requestsPerHundredSeconds: 100
            burst: 10
```

### 5.2 gRPC 策略

```yaml
# gRPC 方法限制
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: grpc-policy
spec:
  endpointSelector:
    matchLabels:
      app: payment
  ingress:
  - toPorts:
    - ports:
      - port: "8080"
        protocol: TCP
      rules:
        http:
        # gRPC 通常使用 HTTP/2
        - method: "POST"
          path: "/pb.PaymentService/.*"
```

### 5.3 L7 策略组合

```yaml
# 组合 L7 策略示例
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: combined-l7
spec:
  endpointSelector:
    matchLabels:
      app: payment
  ingress:
  # 允许 order 服务访问
  - fromEndpoints:
    - matchLabels:
        app: order
    toPorts:
    - ports:
      - port: "8080"
        protocol: TCP
      rules:
        http:
        - method: "GET"
          path: "/api/v1/payments"
        - method: "POST"
          path: "/api/v1/refund"
  # 允许 frontend 服务只读访问
  - fromEndpoints:
    - matchLabels:
        app: frontend
    toPorts:
    - ports:
      - port: "8080"
        protocol: TCP
      rules:
        http:
        - method: "GET"
          path: "/api/v1/payments.*"
```

---

## 6. Waypoint 性能优化

### 6.1 资源调优

```yaml
# Waypoint 资源限制
apiVersion: cilium.io/v2
kind: CiliumEnvoyConfig
metadata:
  name: payment-waypoint
spec:
  workload_selector:
    kind: ServiceAccount
    name: payment
  resources:
    - limits:
        cpu: "500m"
        memory: "512Mi"
      requests:
        cpu: "100m"
        memory: "128Mi"
```

### 6.2 连接池配置

```yaml
# 连接池优化
apiVersion: cilium.io/v2
kind: CiliumEnvoyConfig
metadata:
  name: payment-waypoint
spec:
  cluster_connection:
    max_connections: 1024
    max_pending_requests: 512
    max_requests_per_connection: 100
```

### 6.3 指标收集

Waypoint 自动暴露 Prometheus 指标：

```yaml
# 启用 L7 指标
apiVersion: cilium.io/v2
kind: CiliumEnvoyConfig
metadata:
  name: payment-waypoint
spec:
  metrics:
    - prometheus:
        port: 9090
        path: /metrics
```

---

## 7. 总结

本章深入解析了 Waypoint Proxy 的工作原理和配置方法：

**核心要点**：

- Waypoint Proxy 是**节点级 L7 代理**，按 ServiceAccount 作用域部署
- 基于 Envoy 构建，支持 HTTP/gRPC 深度检测
- 流量通过 ztunnel 按需转发到 Waypoint 执行 L7 策略
- Cilium Agent 自动将 CiliumNetworkPolicy 转换为 Envoy xDS 配置
- 支持 SPIFFE/SPIRE 身份认证和 mTLS 加密
- 可通过 CiliumEnvoyConfig 自定义资源进行精细控制

**下一章节预告**：详解 **Ambient Mode 下的 L4/L7 策略应用**，包括策略执行顺序、优先级、以及与传统 Sidecar 模式策略的差异。

---

## 系列总结

| 章节 | 主题 | 核心价值 |
|:---|:---|:---|
| 31 | Ambient Mode 概述 | 架构理念、组件职责、启用方式 |
| 32 | Waypoint Proxy | L7 代理、身份路由、策略执行 |
| 33 | L4/L7 策略 | Ambient 模式下的策略应用 |
| 34 | 迁移指南 | 从 Sidecar 到 Ambient 的迁移路径 |
