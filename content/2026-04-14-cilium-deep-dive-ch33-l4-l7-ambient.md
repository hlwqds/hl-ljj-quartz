---
title: "Cilium 深度探索 (33)：L4/L7 策略在 Ambient Mode 下的应用"
date: 2026-04-14
tags:
  - cilium
  - ambient-mode
  - l4-policy
  - l7-policy
  - networkpolicy
  - ciliumnetworkpolicy
  - waypoint-proxy
  - ztunnel
  - ebpf
  - kubernetes
  - security
---

> [!info] Cilium 2026 深度探索系列 0. [[2026-04-14-cilium-deep-dive-series-index|系列索引]]
> ... 31. [[2026-04-14-cilium-deep-dive-ch31-ambient-overview|第三十一章：Ambient Mode 概述]] 32. [[2026-04-14-cilium-deep-dive-ch32-waypoint|第三十二章：Waypoint Proxy]] 33. **第三十三章：L4/L7 策略在 Ambient Mode 下的应用** ←

---

## 1. 概述

在 Ambient Mode 下，L4 和 L7 网络策略通过不同的组件执行，形成分层防护体系。**L4 策略由 ztunnel 通过 eBPF 强制执行**，提供高效的端口和协议级别的访问控制；**L7 策略由 Waypoint Proxy 处理**，实现应用层的深度包检测。本章详细解析这两种策略在 Ambient Mode 下的工作原理、配置方法和最佳实践。

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Ambient Mode 策略分层                             │
│                                                                     │
│  ┌───────────────────────────────────────────────────────────────┐ │
│  │                    L7 策略层 (Waypoint Proxy)                   │ │
│  │                                                               │ │
│  │  • HTTP 方法/路径限制                                          │ │
│  │  • gRPC 方法匹配                                               │ │
│  │  • Header 过滤                                                 │ │
│  │  • 速率限制                                                    │ │
│  │  • 故障注入                                                    │ │
│  └───────────────────────────────────────────────────────────────┘ │
│                              ▲                                      │
│                              │ L7 流量转发                          │
│  ┌───────────────────────────────────────────────────────────────┐ │
│  │                    L4 策略层 (ztunnel + eBPF)                   │ │
│  │                                                               │ │
│  │  • 端口级别访问控制                                            │ │
│  │  • 协议检测 (TCP/UDP)                                          │ │
│  │  • mTLS 加密                                                   │ │
│  │  • 身份认证                                                    │ │
│  └───────────────────────────────────────────────────────────────┘ │
│                              ▲                                      │
│                              │ 流量劫持 (sockmap)                   │
│  ┌───────────────────────────────────────────────────────────────┐ │
│  │                    eBPF 流量劫持层                              │ │
│  │                                                               │ │
│  │  • sk_msg hook: sendmsg/recvmsg 劫持                          │ │
│  │  • sockmap: socket 重定向到 ztunnel                             │ │
│  └───────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────┘
```

### 1.1 策略执行组件对比

| 策略层级 | 执行组件       | 性能 | 匹配精度             | 功能           |
| :------- | :------------- | :--- | :------------------- | :------------- |
| **L3**   | eBPF (TC/XDP)  | 最高 | IP/CIDR              | 基础网络隔离   |
| **L4**   | ztunnel + eBPF | 高   | IP + Port + Protocol | 连接级别控制   |
| **L7**   | Waypoint Proxy | 中   | HTTP/gRPC            | 应用层深度检测 |

---

## 2. L4 策略在 Ambient Mode 下

### 2.1 L4 策略执行机制

在 Ambient Mode 中，L4 策略通过 ztunnel 和 eBPF 协同执行：

```
┌─────────────────────────────────────────────────────────────────────┐
│                    L4 策略执行流程                                    │
│                                                                     │
│  Pod A ──► eBPF (sockmap) ──► ztunnel ──► mTLS ──► ztunnel ──► Pod B │
│            │                                  │                      │
│            │                                  │                      │
│            ▼                                  ▼                      │
│     流量劫持                              策略检查                   │
│     (TCP 连接)                           (允许/拒绝)                │
│                                                                     │
│  L4 策略检查点:                                                     │
│  1. 源/目的 IP 检查                                                 │
│  2. 端口检查                                                        │
│  3. 协议检查 (TCP/UDP)                                               │
│  4. 身份验证 (SPIFFE SVID)                                          │
│  5. mTLS 加密隧道建立                                               │
└─────────────────────────────────────────────────────────────────────┘
```

### 2.2 L4 CiliumNetworkPolicy 示例

```yaml
# L4 入口策略 - 只允许来自 order 服务的 TCP 8080 端口
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: payment-l4-ingress
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
```

```yaml
# L4 出口策略 - 只允许访问特定目标
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: payment-l4-egress
spec:
  endpointSelector:
    matchLabels:
      app: payment
  egress:
    - toPorts:
        - ports:
            - port: "5432"
              protocol: TCP
          # 限制目标为数据库服务
      toEndpoints:
        - matchLabels:
            app: database
            k8s:io.kubernetes.pod.namespace: database
```

```yaml
# L4 双向策略
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: payment-l4-bidirectional
spec:
  endpointSelector:
    matchLabels:
      app: payment
  ingress:
    - fromEndpoints:
        - matchLabels:
            app: frontend
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
  egress:
    - toEndpoints:
        - matchLabels:
            app: database
      toPorts:
        - ports:
            - port: "5432"
              protocol: TCP
```

### 2.3 L4 策略与 mTLS

Ambient Mode 下，启用 L4 策略的命名空间自动获得 mTLS 保护：

```yaml
# 命名空间启用 Ambient Mode
apiVersion: v1
kind: Namespace
metadata:
  name: production
  labels:
    istio.io/dataplane-mode: ambient
---
# L4 策略自动获得 mTLS 保护
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: secure-payment
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
  # 隐式启用 mTLS - 无需额外配置
```

### 2.4 端口级策略

```yaml
# 多端口策略
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: multi-port-policy
spec:
  endpointSelector:
    matchLabels:
      app: payment
  ingress:
  - fromEndpoints:
    - matchLabels:
        app: frontend
    toPorts:
    - ports:
      - port: "8080"
        protocol: TCP
      - port: "9090"
        protocol: TCP
        # HTTP 流量
        protocol: HTTP
```

---

## 3. L7 策略在 Ambient Mode 下

### 3.1 L7 策略执行机制

L7 策略通过 Waypoint Proxy 执行，提供应用层深度检测：

```
┌─────────────────────────────────────────────────────────────────────┐
│                    L7 策略执行流程                                    │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │                      HTTP/gRPC 请求                        │    │
│  │                                                              │    │
│  │   GET /api/v1/payments/123 HTTP/1.1                        │    │
│  │   Host: payment.default.svc.cluster.local                  │    │
│  │   Authorization: Bearer token                               │    │
│  └─────────────────────────────────────────────────────────────┘    │
│                                │                                    │
│                                ▼                                    │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │                    Waypoint Proxy                            │    │
│  │                                                              │    │
│  │   1. 解析 HTTP 头部                                          │    │
│  │   2. 提取路径: /api/v1/payments/123                         │    │
│  │   3. 提取方法: GET                                          │    │
│  │   4. 匹配 L7 策略规则                                        │    │
│  │   5. 允许/拒绝/修改                                          │    │
│  │                                                              │    │
│  │   ┌─────────────────────────────────────────────────────┐   │    │
│  │   │  L7 策略规则:                                        │   │    │
│  │   │  - method: GET                                      │   │    │
│  │   │  - path: /api/v1/payments.*                         │   │    │
│  │   │  → ALLOW                                            │   │    │
│  │   └─────────────────────────────────────────────────────┘   │    │
│  └─────────────────────────────────────────────────────────────┘    │
│                                │                                    │
│                                ▼                                    │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │                    后端服务响应                                │    │
│  └─────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────┘
```

### 3.2 L7 CiliumNetworkPolicy 示例

```yaml
# HTTP 方法和路径限制
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: payment-l7-http
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
              # 允许获取支付信息
              - method: "GET"
                path: "/api/v1/payments/[0-9]+"
              # 允许创建支付
              - method: "POST"
                path: "/api/v1/payments"
              # 允许退款
              - method: "POST"
                path: "/api/v1/refund"
            # 拒绝其他所有请求（隐式默认拒绝）
```

```yaml
# Header 过滤策略
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: header-filter-policy
spec:
  endpointSelector:
    matchLabels:
      app: payment
  ingress:
    - fromEndpoints:
        - matchLabels:
            app: frontend
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
          rules:
            http:
              - method: "POST"
                path: "/api/v1/orders"
                headers:
                  # 必须包含有效的 Authorization
                  "Authorization":
                    safeRegex: "Bearer valid-token-.*"
                  # 必须包含请求追踪 ID
                  "X-Request-ID":
                    presentMatch: true
                  # 禁止某些 header
                  "X-Forwarded-User":
                    invertMatch: true
```

```yaml
# gRPC 策略
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: grpc-policy
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
              # gRPC 使用 POST 方法，路径格式: /package.Service/Method
              - method: "POST"
                path: "/payment.PaymentService/CreatePayment"
              - method: "POST"
                path: "/payment.PaymentService/GetPayment"
              - method: "POST"
                path: "/payment.PaymentService/RefundPayment"
```

### 3.3 L7 策略与 L4 策略组合

```yaml
# 组合 L4 + L7 策略
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: combined-l4-l7
spec:
  endpointSelector:
    matchLabels:
      app: payment
  # L4 入口规则
  ingress:
  - fromEndpoints:
    - matchLabels:
        app: order
    toPorts:
    - ports:
      - port: "8080"
        protocol: TCP
      # L7 规则
      rules:
        http:
        - method: "GET"
          path: "/api/v1/payments.*"
        - method: "POST"
          path: "/api/v1/orders"
  # L4 出口规则
  egress:
  - toPorts:
    - ports:
      - port: "5432"
        protocol: TCP
    toEndpoints:
    - matchLabels:
        app: postgresql
    toPorts:
    - ports:
      - port: "5432"
        protocol: TCP
```

---

## 4. 策略优先级与匹配顺序

### 4.1 策略评估顺序

```
┌─────────────────────────────────────────────────────────────────────┐
│                    策略评估顺序                                       │
│                                                                     │
│  1. CiliumClusterwideNetworkPolicy (集群级)                          │
│     └── 最高优先级                                                  │
│                                                                      │
│  2. CiliumNetworkPolicy (命名空间级)                                 │
│     └── 次高优先级                                                   │
│                                                                      │
│  3. Kubernetes NetworkPolicy                                        │
│     └── 最低优先级                                                   │
│                                                                      │
│  同级别策略按创建时间排序 (first-defined, first-evaluated)           │
└─────────────────────────────────────────────────────────────────────┘
```

### 4.2 策略冲突处理

```yaml
# 冲突示例 - order 服务允许 GET，但 clusterwide 拒绝所有
---
# Clusterwide 策略 (优先级高)
apiVersion: cilium.io/v2
kind: CiliumClusterwideNetworkPolicy
metadata:
  name: deny-all-payment
spec:
  endpointSelector:
    matchLabels:
      app: payment
  ingress:
    - toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
---
# Namespace 策略 (优先级低，被覆盖)
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-get
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
              - method: "GET"
                path: "/api/v1/.*"
# 结果: GET 请求被 deny-all 策略拒绝
```

### 4.3 Default Deny 策略

```yaml
# 启用 Default Deny (Ambient Mode 推荐)
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: default-deny
spec:
  endpointSelector:
    matchLabels:
      app: payment
  # 无 egress/ingress 规则 = 默认拒绝所有流量
```

---

## 5. Ambient Mode 特有策略配置

### 5.1 L4 身份感知策略

```yaml
# 基于 ztunnel 身份的 L4 策略
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: identity-aware-l4
spec:
  endpointSelector:
    matchLabels:
      app: payment
  ingress:
    - fromRequires:
        # 要求调用方必须在 mesh 内
        - matchLabels:
            io.cilium.k8s.policy.cluster: default
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
```

### 5.2 L7 速率限制

```yaml
# L7 速率限制策略
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: rate-limit-policy
spec:
  endpointSelector:
    matchLabels:
      app: payment
  ingress:
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
            # 速率限制: 每秒 100 请求
            rateLimit:
              requestsPerHundredSeconds: 10000
              burst: 200
```

### 5.3 L7 故障注入

```yaml
# 故障注入策略 (测试用)
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: fault-injection
spec:
  endpointSelector:
    matchLabels:
      app: payment
  ingress:
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
          path: "/api/v1/health"
          fault:
            delay:
              percent: 50
              fixedDelaySeconds: 5
          fault:
            abort:
              percent: 10
              httpStatus: 503
```

---

## 6. 策略调试与验证

### 6.1 Hubble 观察 L4/L7 流量

```bash
# 观察入口 L4 流量
hubble observe --protocol tcp --port 8080

# 观察 L7 HTTP 流量
hubble observe --protocol http

# 观察特定命名空间的流量
hubble observe --from-namespace production --to-namespace production

# 观察被拒绝的流量
hubble observe --verdict DROPPED

# 观察 L7 策略匹配
hubble observe --policy-verdict=L7
```

### 6.2 策略解析

```bash
# 查看 Cilium Agent 解析的策略
kubectl exec -it -n kube-system ds/cilium -- cilium-dbg policy get

# 查看特定 endpoint 的策略
kubectl exec -it -n kube-system ds/cilium -- cilium-dbg endpoint list

# 查看 L7 策略配置
kubectl exec -it -n kube-system ds/cilium -- cilium-dbg l7-policy get
```

### 6.3 Waypoint 配置验证

```bash
# 查看 Waypoint xDS 配置
kubectl exec -it -n kube-system ztunnel-xxxx -- curl -s localhost:15000/config_dump | jq

# 查看路由配置
kubectl exec -it -n kube-system ztunnel-xxxx -- curl -s localhost:15000/config_dump | jq '.configs[].dynamic_active_listeners[].route_config'

# 测试 Waypoint 策略
kubectl exec -it <client-pod> -- curl -v http://<service>.<namespace>.svc.cluster.local/api/v1/payments
```

### 6.4 常见策略问题

| 问题           | 原因                        | 解决方法                                |
| :------------- | :-------------------------- | :-------------------------------------- |
| L7 策略不生效  | Waypoint 未部署             | 检查 CiliumNetworkPolicy 引用           |
| 流量被莫名拒绝 | Default Deny 未配置允许规则 | 添加明确允许规则                        |
| mTLS 握手失败  | 命名空间未启用 Ambient      | 添加 `istio.io/dataplane-mode: ambient` |
| L4 策略覆盖 L7 | 策略优先级问题              | 使用 CiliumClusterwideNetworkPolicy     |

---

## 7. 总结

本章介绍了 L4/L7 策略在 Ambient Mode 下的完整应用体系：

**核心要点**：

- L4 策略由 **ztunnel + eBPF** 执行，提供高效的连接级别控制
- L7 策略由 **Waypoint Proxy** 执行，提供应用层深度检测
- CiliumNetworkPolicy 同时支持 L4 和 L7 策略定义
- Ambient Mode 隐式启用 **mTLS** 加密
- 策略按 **集群级 > 命名空间级 > NetworkPolicy** 优先级执行
- Hubble 可用于观察和调试 L4/L7 流量

**Ambient Mode 策略优势**：

- 无需 Sidecar 注入，策略自动生效
- 节点级 Waypoint 降低资源开销
- L4/L7 策略统一配置，简化运维

**下一章节预告**：**从 Sidecar 到 Ambient 的迁移指南**，包括迁移前评估、迁移步骤、验证方法以及回滚策略。

---

## 系列总结

| 章节 | 主题              | 核心价值                         |
| :--- | :---------------- | :------------------------------- |
| 31   | Ambient Mode 概述 | 架构理念、组件职责、启用方式     |
| 32   | Waypoint Proxy    | L7 代理、身份路由、策略执行      |
| 33   | L4/L7 策略        | Ambient 模式下的策略应用         |
| 34   | 迁移指南          | 从 Sidecar 到 Ambient 的迁移路径 |

L4/L7 策略体系是 Cilium Ambient Mode 实现零信任安全的基础，通过分层防护为云原生工作负载提供全面的网络安全保障。
