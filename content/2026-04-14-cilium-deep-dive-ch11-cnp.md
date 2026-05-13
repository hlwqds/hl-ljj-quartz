---
title: "Cilium 深度探索 (11)：CiliumNetworkPolicy 网络策略"
date: 2026-04-14
tags:
  - cilium
  - networkpolicy
  - ciliumnetworkpolicy
  - l3-l4-l7
  - ebpf
  - kubernetes
  - security
  - networking
---

> [!info] Cilium 2026 深度探索系列 0. [[2026-04-14-cilium-deep-dive-series-index|系列索引]]
>
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
> 11. **第十一章：CiliumNetworkPolicy** ←

---

## 1. CiliumNetworkPolicy 概述

CiliumNetworkPolicy（CNP）是 Cilium 自定义的 Kubernetes CRD，扩展了 Kubernetes 原生的 NetworkPolicy，提供**L3/L4/L7 细粒度网络策略**和**基于身份的断路器**功能。与 K8s NetworkPolicy 相比，CNP 支持：

- **L7 应用层策略**：HTTP/gRPC/REST/DNS 协议过滤
- **基于 CIDR 的策略**：支持 IP 地址段匹配
- **基于身份的策略**：替代传统的基于 Pod Selector 的策略
- **入口/出口规则**：双向流量控制
- **ICMP 协议控制**：Layer 3 ICMP 协议字段匹配

```yaml
# CiliumNetworkPolicy 示例：限制前端只能访问后端 API
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: frontend-to-backend
spec:
  endpointSelector:
    matchLabels:
      app: frontend
  ingress:
    - fromEndpoints:
        - matchLabels:
            app: backend
      toPorts:
        - port: "8080"
          protocol: TCP
          rules:
            http:
              - method: "GET"
                path: "/api/v1.*"
```

### 1.1 CNP vs K8s NetworkPolicy

| 特性         | K8s NetworkPolicy      | CiliumNetworkPolicy     |
| :----------- | :--------------------- | :---------------------- |
| **L3 策略**  | Pod/namespace selector | + CIDR 范围             |
| **L4 策略**  | TCP/UDP port           | + ICMP, SCTP            |
| **L7 策略**  | ❌ 不支持              | HTTP/gRPC/DNS/SQL/Kafka |
| **默认行为** | 允许一切（未匹配时）   | 可配置默认拒绝          |
| **策略级别** | 命名资源               | + 全局/集群范围         |
| **身份感知** | Pod 身份               | 加密身份 + 审计         |

---

## 2. 策略结构解析

### 2.1 顶层结构

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: my-policy
spec:
  # 目标端点选择器（必须）
  endpointSelector:
    matchLabels:
      app: my-app

  # 入口规则（可选）
  ingress:
    - from:
        # 方式1: 通过端点选择器
        - endpointSelector:
            matchLabels:
              app: other-app
        # 方式2: 通过 CIDR
        - cidrs:
            - "10.0.0.0/8"
        # 方式3: 通过身份
        - identity:
            matchLabels:
              app: specific-identity
      toPorts:
        - port: "80"
          protocol: TCP
          rules:
            http:
              - method: "GET"
                path: "/health"

  # 出口规则（可选）
  egress:
    - toEndpoints:
        - matchLabels:
            app: database
      toPorts:
        - port: "5432"
          protocol: TCP
        - toDNS:
            - "*.example.com"
          port: "53"
```

### 2.2 规则评估顺序

```
┌─────────────────────────────────────────────────────────────┐
│                  CNP 规则评估流程                            │
│                                                             │
│  1. EndpointSelector 匹配目标 Pod                           │
│       │                                                    │
│       ▼                                                    │
│  2. 检查入口/出口规则                                       │
│       │                                                    │
│       ▼                                                    │
│  3. 规则按出现顺序评估（first-match）                        │
│       │                                                    │
│       ▼                                                    │
│  4. 匹配规则 → 应用允许/拒绝动作                             │
│       │                                                    │
│       ▼                                                    │
│  5. 无匹配 → 应用默认策略（allow by default）               │
└─────────────────────────────────────────────────────────────┘
```

---

## 3. L3 策略

### 3.1 基于 Endpoint Selector 的 L3 策略

最基本的 L3 策略，通过标签选择器控制哪些 Pod 可以访问目标 Pod：

```yaml
# 允许带有 app:client 标签的 Pod 访问目标 Pod
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: l3-client-policy
spec:
  endpointSelector:
    matchLabels:
      app: server
  ingress:
    - fromEndpoints:
        - matchLabels:
            app: client
```

### 3.2 基于 CIDR 的 L3 策略

CNP 支持基于 IP 地址段的 L3 策略，这在控制外部访问时特别有用：

```yaml
# 允许特定 IP 范围访问
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: cidr-policy
spec:
  endpointSelector:
    matchLabels:
      app: internal-service
  ingress:
    - fromCidrs:
        - "192.168.1.0/24" # 允许办公室网络
        - "10.0.0.0/8" # 允许内网
        - "!10.0.0.5/32" # 排除特定 IP
```

**CIDR 策略的典型使用场景**：

- 限制管理接口访问
- 允许 VPN 客户端访问
- 防止 IP 地址欺骗

### 3.3 组合 L3 策略

可以组合多种 L3 条件：

```yaml
# 组合策略：同时满足多个条件
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: combined-l3-policy
spec:
  endpointSelector:
    matchLabels:
      app: sensitive-data
  ingress:
    - from:
        # 必须同时满足：
        # 1. 来自指定 CIDR
        # 2. 来自带有特定标签的端点
        - cidrs:
            - "10.0.0.0/8"
          endpointSelector:
            matchLabels:
              zone: trusted
```

---

## 4. L4 策略

### 4.1 基本 L4 策略

L4 策略在 L3 基础上添加端口和协议控制：

```yaml
# 允许 TCP 80 端口访问
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: l4-tcp-policy
spec:
  endpointSelector:
    matchLabels:
      app: webserver
  ingress:
    - toPorts:
        - port: "80"
          protocol: TCP
```

### 4.2 多端口 L4 策略

```yaml
# 允许多个端口
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: multi-port-policy
spec:
  endpointSelector:
    matchLabels:
      app: webserver
  ingress:
    - toPorts:
        - ports:
            - port: "80"
              protocol: TCP
            - port: "443"
              protocol: TCP
            - port: "8080"
              protocol: TCP
```

### 4.3 支持的协议

CiliumNetworkPolicy 支持的协议：

| 协议 | 说明               | 示例                   |
| :--- | :----------------- | :--------------------- |
| TCP  | 传输控制协议       | `protocol: TCP`        |
| UDP  | 用户数据报协议     | `protocol: UDP`        |
| SCTP | 流控制传输协议     | `protocol: SCTP`       |
| ICMP | 互联网控制消息协议 | `protocol: ICMP`       |
| ANY  | 任何协议           | `protocol: 1` (ICMPv6) |

### 4.4 ICMP 协议控制

```yaml
# 控制 ICMP 流量
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: icmp-policy
spec:
  endpointSelector:
    matchLabels:
      app: network-tool
  egress:
    - toPorts:
        - port: "0"
          protocol: ICMP
          rules:
            icmps:
              - fields:
                  - type: 8 # Echo Request
                    code: 0
```

---

## 5. L7 策略

L7 策略提供**应用层深度包检测（DPI）**，支持 HTTP、gRPC、DNS、Kafka、SQL 等协议。

### 5.1 HTTP 策略

```yaml
# HTTP 策略示例
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: http-policy
spec:
  endpointSelector:
    matchLabels:
      app: api-gateway
  ingress:
    - fromEndpoints:
        - matchLabels:
            app: frontend
      toPorts:
        - port: "8080"
          protocol: TCP
          rules:
            http:
              # 允许 GET /api/users
              - method: "GET"
                path: "/api/users"
              # 允许 GET /api/products
              - method: "GET"
                path: "/api/products"
            # 拒绝其他所有请求（隐式）
```

### 5.2 HTTP 策略字段

| 字段       | 类型          | 说明                                                |
| :--------- | :------------ | :-------------------------------------------------- |
| `method`   | string/regex  | HTTP 方法（GET/POST/PUT/DELETE/PATCH/HEAD/OPTIONS） |
| `path`     | string/regex  | URL 路径                                            |
| `protocol` | string        | HTTP 版本（HTTP/1.1, HTTP/2）                       |
| `headers`  | []HeaderMatch | 请求头匹配                                          |

```yaml
# 带 Header 匹配的 HTTP 策略
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: http-header-policy
spec:
  endpointSelector:
    matchLabels:
      app: api-gateway
  ingress:
    - fromEndpoints:
        - matchLabels:
            app: mobile-app
      toPorts:
        - port: "8080"
          protocol: TCP
          rules:
            http:
              - method: "POST"
                path: "/api/v1/payments"
                headers:
                  - "X-API-Key:.*" # 必须包含 API Key
                  - "Content-Type: application/json"
```

### 5.3 gRPC 策略

```yaml
# gRPC 策略
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: grpc-policy
spec:
  endpointSelector:
    matchLabels:
      app: order-service
  ingress:
    - fromEndpoints:
        - matchLabels:
            app: api-gateway
      toPorts:
        - port: "50051"
          protocol: TCP
          rules:
            http:
              # gRPC 使用 POST，path 为 /service.Method 格式
              - method: "POST"
                path: "/OrderService/CreateOrder"
              - method: "POST"
                path: "/OrderService/CancelOrder"
              - method: "POST"
                path: "/OrderService/GetOrder"
```

### 5.4 DNS 策略

```yaml
# DNS 策略
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: dns-policy
spec:
  endpointSelector:
    matchLabels:
      app: webserver
  egress:
    - toPorts:
        - port: "53"
          protocol: UDP
          rules:
            dns:
              - matchPattern: "*.example.com" # 允许访问 *.example.com
              - matchPattern: "internal.db.local" # 允许访问内部数据库
              - matchPattern: "kubernetes.default" # 允许 K8s API
```

---

## 6. 出口规则 (Egress)

### 6.1 基础出口策略

```yaml
# 限制出口流量
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: egress-policy
spec:
  endpointSelector:
    matchLabels:
      app: frontend
  egress:
    # 允许访问后端服务
    - toEndpoints:
        - matchLabels:
            app: backend
      toPorts:
        - port: "8080"
          protocol: TCP
    # 允许 DNS 查询
    - toPorts:
        - port: "53"
          protocol: UDP
      toEndpoints:
        - matchLabels:
            k8s-app: kube-dns
```

### 6.2 出口 CIDR 策略

```yaml
# 控制出口目的地址
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: egress-cidr-policy
spec:
  endpointSelector:
    matchLabels:
      app: backup-client
  egress:
    # 允许备份到特定 IP
    - toCidrs:
        - "192.168.50.0/24"
      toPorts:
        - port: "873"
          protocol: TCP
  # 拒绝其他所有出口
```

---

## 7. 策略优先级与默认行为

### 7.1 隐式默认行为

在未应用任何 CNP 时，Cilium 默认**允许所有流量**。应用 CNP 后：

```yaml
# 应用此策略后的行为：
# 1. 匹配 endpointSelector 的端点受到此策略约束
# 2. 未匹配任何 from 条目的流量 → 被拒绝
# 3. 匹配任一 from 条目 → 被允许
```

### 7.2 默认拒绝示例

```yaml
# 显式默认拒绝：通过精确指定允许的流量
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: default-deny-example
spec:
  endpointSelector:
    matchLabels:
      app: secure-app
  ingress:
    # 只允许前端访问
    - fromEndpoints:
        - matchLabels:
            app: frontend
      toPorts:
        - port: "443"
          protocol: TCP
  egress:
    # 只允许访问数据库
    - toEndpoints:
        - matchLabels:
            app: database
      toPorts:
        - port: "5432"
          protocol: TCP
  # 所有其他流量被隐式拒绝
```

---

## 8. 基于身份的安全 (Identity-Based Security)

### 8.1 Cilium 身份模型

Cilium 为每个 Pod 分配一个**加密身份**（基于 CNP 标签的哈希）：

```
┌─────────────────────────────────────────────────────────────┐
│                  Cilium 身份模型                             │
│                                                             │
│  Pod 标签 → 身份哈希 → eBPF Map 中的身份映射                  │
│                                                             │
│  Labels:                                                    │
│    app: frontend                                            │
│    version: v2                                              │
│    environment: production                                  │
│       │                                                    │
│       ▼                                                    │
│  Identity: sha256(...)
│                                                             │
│  这个身份用于：                                             │
│    - 加密通信（WireGuard/IPsec）                            │
│    - 策略匹配                                               │
│    - 审计日志                                               │
└─────────────────────────────────────────────────────────────┘
```

### 8.2 身份感知的策略

```yaml
# 基于身份而不是 Pod IP 的策略
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: identity-based-policy
spec:
  endpointSelector:
    matchLabels:
      app: payment-service
  ingress:
    # 允许具有特定身份标签的服务访问
    - fromIdentity:
        matchLabels:
          app: api-gateway
          environment: production
      toPorts:
        - port: "8080"
          protocol: TCP
```

---

## 9. 实际应用示例

### 9.1 微服务架构策略

```yaml
# web-frontend → api-gateway → user-service → database
---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: web-frontend-policy
spec:
  endpointSelector:
    matchLabels:
      app: web-frontend
  egress:
    - toEndpoints:
        - matchLabels:
            app: api-gateway
      toPorts:
        - port: "8080"
          protocol: TCP
          rules:
            http:
              - method: "POST"
                path: "/api/v1.*"
              - method: "GET"
                path: "/api/v1/users.*"
    - toPorts:
        - port: "53"
          protocol: UDP
      toEndpoints:
        - matchLabels:
            k8s-app: kube-dns

---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: api-gateway-policy
spec:
  endpointSelector:
    matchLabels:
      app: api-gateway
  ingress:
    - fromEndpoints:
        - matchLabels:
            app: web-frontend
      toPorts:
        - port: "8080"
          protocol: TCP
          rules:
            http:
              - method: "POST"
                path: "/api/v1.*"
  egress:
    - toEndpoints:
        - matchLabels:
            app: user-service
      toPorts:
        - port: "8080"
          protocol: TCP
    - toEndpoints:
        - matchLabels:
            app: order-service
      toPorts:
        - port: "8080"
          protocol: TCP
```

### 9.2 零信任网络策略

```yaml
# 零信任：显式拒绝所有，精确允许
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: zero-trust-policy
spec:
  endpointSelector:
    matchLabels:
      app: sensitive-app
  description: "Zero trust policy - default deny, explicit allow"
  ingress:
    # 只允许 API 网关访问
    - fromEndpoints:
        - matchLabels:
            app: api-gateway
            environment: production
      toPorts:
        - port: "443"
          protocol: TCP
          rules:
            http:
              - method: "POST"
                path: "/api/v1/data"
                headers:
                  - "Authorization: Bearer .+"
  egress:
    # 只允许访问数据库
    - toEndpoints:
        - matchLabels:
            app: postgres
      toPorts:
        - port: "5432"
          protocol: TCP
    # 只允许 DNS
    - toPorts:
        - port: "53"
          protocol: UDP
      toEndpoints:
        - matchLabels:
            k8s-app: kube-dns
```

---

## 10. 故障排除

### 10.1 策略不生效的常见原因

```bash
# 1. 检查策略是否正确应用
kubectl get cnp

# 2. 查看端点的策略状态
kubectl -n kube-system exec ds/cilium -- cilium endpoint list

# 3. 查看 Hubble 流量日志
hubble observe --from-label app=client --to-label app=server

# 4. 检查策略是否被拒绝
hubble observe --type drop
```

### 10.2 调试命令

```bash
# 查看策略详情
kubectl describe cnp <policy-name>

# 查看端点策略状态
kubectl -n kube-system exec ds/cilium -- \
    cilium endpoint list -o json | jq '.[] | select(.status.policy.egress.l4.length > 0)'

# 查看 L7 策略
kubectl -n kube-system exec ds/cilium -- \
    cilium policy get
```

---

## 11. 总结

CiliumNetworkPolicy 提供了比 K8s NetworkPolicy 更强大的网络策略能力：

| 层级         | 能力                                |
| :----------- | :---------------------------------- |
| **L3**       | Pod Selector、CIDR、身份、namespace |
| **L4**       | TCP/UDP/SCTP/ICMP 端口控制          |
| **L7**       | HTTP/gRPC/DNS/Kafka/SQL 深度检测    |
| **默认行为** | 可配置默认拒绝                      |
| **身份安全** | 加密身份、审计日志                  |

下一章我们将介绍 Kubernetes 原生 NetworkPolicy 以及 Cilium 对其的增强。
