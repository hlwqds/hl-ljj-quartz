---
title: "Cilium 深度探索 (15)：策略层级与默认行为"
date: 2026-04-14
tags:
  - cilium
  - networkpolicy
  - layer3
  - layer4
  - layer7
  - default-deny
  - audit
  - ebpf
  - kubernetes
  - security
---

> [!info] Cilium 2026 深度探索系列 0. [[cilium-deep-dive|系列索引]]
>
> 1. [[ch1-cilium-overview|第一章：Cilium 概述]]
> 2. [[ch2-architecture|第二章：Cilium 架构]]
> 3. [[ch3-ebpf-datapath|第三章：eBPF 数据面]]
> 4. [[ch4-kube-proxy|第四章：Kube-Proxy 替代]]
> 5. [[ch5-cni|第五章：CNI 集成]]
> 6. [[ch6-clusterip|第六章：ClusterIP]]
> 7. [[ch7-nodeport|第七章：NodePort]]
> 8. [[ch8-loadbalancer|第八章：LoadBalancer]]
> 9. [[ch9-externalip|第九章：ExternalIP]]
> 10. [[ch10-vxlan|第十章：VXLAN]]
> 11. [[ch11-cnp|第十一章：CiliumNetworkPolicy]]
> 12. [[ch12-networkpolicy|第十二章：NetworkPolicy]]
> 13. [[ch13-layer7|第十三章：L7 策略]]
> 14. [[ch14-dns|第十四章：DNS 策略]]
> 15. **第十五章：策略层级** ←

---

## 1. 策略层级概述

Cilium 网络策略采用**分层架构**，从 L3（网络层）到 L7（应用层），逐层提供更细粒度的控制能力。理解这些层级以及它们之间的交互对于设计有效的安全策略至关重要。

```
┌─────────────────────────────────────────────────────────────┐
│                 Cilium 策略层级架构                          │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                    L7 应用层                          │   │
│  │  HTTP 路径、gRPC 方法、DNS 域名、SQL 操作            │   │
│  │  最高细粒度，最强安全性                               │   │
│  └─────────────────────────────────────────────────────┘   │
│                           │                                 │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                    L4 传输层                          │   │
│  │  TCP/UDP 端口、连接状态                             │   │
│  │  中等细粒度                                          │   │
│  └─────────────────────────────────────────────────────┘   │
│                           │                                 │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                    L3 网络层                          │   │
│  │  IP 地址、CIDR、身份、标签                          │   │
│  │  基础细粒度                                          │   │
│  └─────────────────────────────────────────────────────┘   │
│                           │                                 │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                    L2 数据链路层                       │   │
│  │  MAC 地址、VLAN 标签                                │   │
│  │  底层控制                                            │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 1.1 层级对比

| 层级   | 名称     | 匹配内容          | 性能影响 | 典型用途     |
| :----- | :------- | :---------------- | :------- | :----------- |
| **L2** | 数据链路 | MAC 地址、VLAN    | 极低     | 基础网络隔离 |
| **L3** | 网络层   | IP、CIDR、身份    | 极低     | IP 级别分段  |
| **L4** | 传输层   | 端口、协议        | 低       | 服务级别控制 |
| **L7** | 应用层   | HTTP/gRPC/DNS/SQL | 中等     | 深度包检测   |

---

## 2. Layer 3 策略

### 2.1 L3 策略核心概念

L3 策略是最基础的网络层控制，基于 IP 地址、CIDR 范围或身份标签进行流量筛选：

```yaml
# L3 基本策略
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: l3-basic-policy
spec:
  endpointSelector:
    matchLabels:
      app: secure-app
  # 入口 L3 策略
  ingress:
    - fromCidrs:
        - "10.0.0.0/8" # 允许内网
        - "192.168.1.0/24" # 允许办公网络
  egress:
    - toCidrs:
        - "0.0.0.0/0" # 允许所有出口（不推荐）
        - "!10.0.0.5/32" # 排除特定 IP
```

### 2.2 基于身份的 L3 策略

Cilium 为每个 Pod 分配基于标签的身份：

```yaml
# 基于身份标签的 L3 策略
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: identity-based-l3
spec:
  endpointSelector:
    matchLabels:
      app: payment-service
  ingress:
    # 允许具有特定身份的服务访问
    - fromIdentity:
        matchLabels:
          app: api-gateway
          environment: production
```

### 2.3 CIDR 策略进阶

```yaml
# CIDR 策略进阶
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: advanced-cidr
spec:
  endpointSelector:
    matchLabels:
      app: webserver
  egress:
    # 允许访问特定 IP 范围
    - toCidrs:
        - "93.184.216.0/24" # 允许 example.com IP 范围
        - "172.217.0.0/16" # 允许 Google IP 范围
      toPorts:
        - port: "443"
          protocol: TCP
```

---

## 3. Layer 4 策略

### 3.1 L4 策略核心概念

L4 策略在 L3 基础上添加端口和协议控制：

```yaml
# L4 基本策略
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: l4-basic-policy
spec:
  endpointSelector:
    matchLabels:
      app: database
  ingress:
    - fromEndpoints:
        - matchLabels:
            app: api-service
      toPorts:
        - port: "5432"
          protocol: TCP
  egress:
    - toEndpoints:
        - matchLabels:
            app: backup-server
      toPorts:
        - port: "873"
          protocol: TCP
```

### 3.2 多端口 L4 策略

```yaml
# 多端口 L4 策略
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

### 3.3 协议级别控制

```yaml
# UDP 端口控制
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: udp-policy
spec:
  endpointSelector:
    matchLabels:
      app: streaming-server
  egress:
    - toEndpoints:
        - matchLabels:
            app: media-source
      toPorts:
        - port: "5000"
          protocol: UDP
```

### 3.4 SCTP 协议支持

```yaml
# SCTP 协议策略
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: sctp-policy
spec:
  endpointSelector:
    matchLabels:
      app: telecom-service
  ingress:
    - toPorts:
        - port: "36444"
          protocol: SCTP
```

---

## 4. Layer 7 策略

### 4.1 L7 策略核心概念

L7 策略提供应用层深度包检测：

```yaml
# L7 HTTP 策略
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: l7-http-policy
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
              - method: "GET"
                path: "/api/v1/.*"
              - method: "POST"
                path: "/api/v1/orders"
```

### 4.2 L7 策略执行流程

```
┌─────────────────────────────────────────────────────────────┐
│                 L7 策略执行流程                              │
│                                                             │
│  1. L3/L4 检查通过                                         │
│       │                                                    │
│       ▼                                                    │
│  2. 如果有 L7 规则 → 启动 L7 代理                         │
│       │                                                    │
│       ▼                                                    │
│  3. HTTP/gRPC 解析                                         │
│       │                                                    │
│       ▼                                                    │
│  4. 匹配 L7 规则                                           │
│       │                                                    │
│       ▼                                                    │
│  5. 允许/拒绝                                              │
│       │                                                    │
│       ▼                                                    │
│  6. 记录审计日志（如果启用）                               │
└─────────────────────────────────────────────────────────────┘
```

### 4.3 L7 策略组合

```yaml
# L7 策略组合示例
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: l7-combined
spec:
  endpointSelector:
    matchLabels:
      app: admin-api
  ingress:
    - fromEndpoints:
        - matchLabels:
            app: admin-frontend
      toPorts:
        - port: "8080"
          protocol: TCP
          rules:
            http:
              # 允许管理 API
              - method: "GET"
                path: "/admin/.*"
              - method: "POST"
                path: "/admin/.*"
              - method: "PUT"
                path: "/admin/.*"
              # 允许健康检查
              - method: "GET"
                path: "/health"
              - method: "GET"
                path: "/metrics"
```

---

## 5. 策略组合与优先级

### 5.1 多层级策略组合

```yaml
# L3 + L4 + L7 组合策略
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: multi-layer-policy
spec:
  endpointSelector:
    matchLabels:
      app: payment-service
  # 入口策略
  ingress:
    # L3: 来自 API 网关
    - fromEndpoints:
        - matchLabels:
            app: api-gateway
      # L4: TCP 8080
      toPorts:
        - port: "8080"
          protocol: TCP
          # L7: HTTP 规则
          rules:
            http:
              - method: "POST"
                path: "/api/v1/payments"
              - method: "GET"
                path: "/api/v1/payments/.*"
  # 出口策略
  egress:
    # L3: 来自内部服务
    - toEndpoints:
        - matchLabels:
            app: database
      # L4: PostgreSQL
      toPorts:
        - port: "5432"
          protocol: TCP
```

### 5.2 策略优先级

```yaml
# 显式优先级（ CiliumNetworkPolicy）
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: high-priority
spec:
  priority: 1 # 高优先级
  endpointSelector:
    matchLabels:
      app: critical-service
  ingress:
    - fromCidrs:
        - "10.0.0.0/8"
      toPorts:
        - port: "443"
          protocol: TCP

---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: low-priority
spec:
  priority: 100 # 低优先级
  endpointSelector:
    matchLabels:
      app: critical-service
  ingress:
    - fromCidrs:
        - "0.0.0.0/0"
      toPorts:
        - port: "443"
          protocol: TCP
```

### 5.3 策略评估顺序

```
┌─────────────────────────────────────────────────────────────┐
│               策略评估顺序                                   │
│                                                             │
│  1. 优先级排序（priority 值小 → 高优先级）                  │
│       │                                                    │
│       ▼                                                    │
│  2. 端点选择器匹配                                         │
│       │                                                    │
│       ▼                                                    │
│  3. 入口/出口规则评估                                       │
│       │                                                    │
│       ▼                                                    │
│  4. L3 规则 → L4 规则 → L7 规则                           │
│       │                                                    │
│       ▼                                                    │
│  5. 第一个匹配 → 执行允许/拒绝                              │
│                                                             │
│  注意：没有匹配 → 应用默认行为                              │
└─────────────────────────────────────────────────────────────┘
```

---

## 6. 默认拒绝 (Default Deny)

### 6.1 默认行为

Cilium 的默认行为取决于策略类型：

| 场景                         | 默认行为             |
| :--------------------------- | :------------------- |
| **无任何策略**               | 允许所有流量         |
| **应用 NetworkPolicy**       | 只允许匹配的流量     |
| **应用 CiliumNetworkPolicy** | 只允许匹配的流量     |
| **命名空间级别默认拒绝**     | 拒绝所有未匹配的流量 |

### 6.2 实现默认拒绝

```yaml
# 命名空间级别默认拒绝入口
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: production
spec:
  podSelector: {} # 选择所有 Pod
  policyTypes:
    - Ingress # 只拒绝入口

---
# 命名空间级别默认拒绝出口
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-egress
  namespace: production
spec:
  podSelector: {}
  policyTypes:
    - Egress
```

### 6.3 默认拒绝 + 精确允许

```yaml
# 默认拒绝 + 精确允许：最佳安全实践
---
# 1. 默认拒绝所有入口
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress

---
# 2. 允许前端访问后端
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-frontend-to-backend
spec:
  podSelector:
    matchLabels:
      app: backend
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: frontend
      ports:
        - port: 8080
          protocol: TCP

---
# 3. 允许后端访问数据库
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-backend-to-db
spec:
  podSelector:
    matchLabels:
      app: database
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: backend
      ports:
        - port: 5432
          protocol: TCP
  egress:
    - to:
        - podSelector:
            matchLabels:
              app: backend
      ports:
        - port: 5432
          protocol: TCP
```

---

## 7. 审计日志

### 7.1 Hubble 审计功能

Hubble 提供完整的网络流量审计：

```bash
# 查看所有被拒绝的流量
hubble observe --type drop

# 查看 L3 被拒绝的流量
hubble observe --type drop --protocol ip

# 查看 L4 被拒绝的流量
hubble observe --type drop --protocol tcp

# 查看 L7 被拒绝的流量
hubble observe --type drop --protocol http

# 查看特定端点的流量
hubble observe --from-label app=frontend --to-label app=backend
```

### 7.2 策略审计日志

```bash
# 查看策略评估日志
kubectl -n kube-system exec ds/cilium -- \
    cilium-dbg policy

# 查看端点策略状态
kubectl -n kube-system exec ds/cilium -- \
    cilium endpoint list

# 查看特定端点的策略
kubectl -n kube-system exec ds/cilium -- \
    cilium endpoint get <endpoint-id>

# 跟踪策略变更
kubectl get cnp -w
```

### 7.3 L7 审计配置

```bash
# 查看 L7 审计日志
hubble observe --type l7 --protocol http

# 示例输出：
# TIME     SOURCE          DESTINATION   L7 PROTOCOL  METHOD  PATH         RESPONSE
# 10:23:01 frontend        backend       http         GET     /api/users   200
# 10:23:05 frontend        backend       http         POST    /api/orders  201
# 10:23:10 attacker        backend       http         POST    /admin/./..  403
#                               ↑ L7 拒绝！
```

### 7.4 审计日志配置

```yaml
# 配置 Hubble 审计
apiVersion: cilium.io/v2
kind: CiliumClusterwideHubbleFlowStatus
metadata:
  name: clusterwide-flow-status
spec:
  enabled: true
  # 记录所有流量（包括允许的）
  log-filter: all
  # 或只记录拒绝的
  log-filter: denied
```

---

## 8. 完整策略示例

### 8.1 分层安全策略

```yaml
# 完整分层安全策略
# 场景：电商平台的微服务架构
---
# 默认拒绝（命名空间级别）
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
  namespace: ecommerce
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress

---
# 前端服务策略
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: frontend-policy
spec:
  endpointSelector:
    matchLabels:
      app: frontend
  egress:
    # L3+L4: 只能访问 API 网关
    - toEndpoints:
        - matchLabels:
            app: api-gateway
      toPorts:
        - port: "8080"
          protocol: TCP
    # L3+L4: DNS
    - toPorts:
        - port: "53"
          protocol: UDP
      toEndpoints:
        - matchLabels:
            k8s-app: kube-dns

---
# API 网关策略
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: api-gateway-policy
spec:
  endpointSelector:
    matchLabels:
      app: api-gateway
  ingress:
    # L3+L4: 来自前端
    - fromEndpoints:
        - matchLabels:
            app: frontend
      toPorts:
        - port: "8080"
          protocol: TCP
          # L7: HTTP 规则
          rules:
            http:
              - method: "GET"
                path: "/api/products.*"
              - method: "POST"
                path: "/api/orders"
              - method: "GET"
                path: "/api/users.*"
  egress:
    # 访问用户服务
    - toEndpoints:
        - matchLabels:
            app: user-service
      toPorts:
        - port: "8080"
          protocol: TCP
    # 访问产品服务
    - toEndpoints:
        - matchLabels:
            app: product-service
      toPorts:
        - port: "8080"
          protocol: TCP
    # 访问订单服务
    - toEndpoints:
        - matchLabels:
            app: order-service
      toPorts:
        - port: "8080"
          protocol: TCP
    # DNS
    - toPorts:
        - port: "53"
          protocol: UDP
      toEndpoints:
        - matchLabels:
            k8s-app: kube-dns

---
# 订单服务策略
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: order-service-policy
spec:
  endpointSelector:
    matchLabels:
      app: order-service
  ingress:
    # L3+L4: 来自 API 网关
    - fromEndpoints:
        - matchLabels:
            app: api-gateway
      toPorts:
        - port: "8080"
          protocol: TCP
          rules:
            http:
              - method: "POST"
                path: "/api/v1/orders"
              - method: "GET"
                path: "/api/v1/orders/[0-9]+"
              - method: "PUT"
                path: "/api/v1/orders/[0-9]+/cancel"
  egress:
    # 访问数据库
    - toEndpoints:
        - matchLabels:
            app: order-database
      toPorts:
        - port: "5432"
          protocol: TCP
    # DNS
    - toPorts:
        - port: "53"
          protocol: UDP
      toEndpoints:
        - matchLabels:
            k8s-app: kube-dns
```

### 8.2 零信任策略模板

```yaml
# 零信任网络策略模板
---
# 1. 默认拒绝
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: zero-trust-default-deny
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress

---
# 2. DNS 允许
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: zero-trust-dns
spec:
  endpointSelector:
    matchLabels:
      app: "*"
  egress:
    - toPorts:
        - port: "53"
          protocol: UDP
      toEndpoints:
        - matchLabels:
            k8s-app: kube-dns

---
# 3. API Server 允许（如果需要）
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: zero-trust-kube-apiserver
spec:
  endpointSelector:
    matchLabels:
      app: "*"
  egress:
    - toEndpoints:
        - matchLabels:
            k8s-app: kube-apiserver
      toPorts:
        - port: "443"
          protocol: TCP
```

---

## 9. 监控与可视化

### 9.1 Hubble CLI 监控

```bash
# 实时流量监控
hubble observe --follow

# 按标签过滤
hubble observe --from-label app=frontend --to-label app=backend

# 按命名空间过滤
hubble observe --namespace production

# 按时间过滤
hubble observe --since 5m

# 查看统计信息
hubble status
```

### 9.2 Grafana Dashboard

```bash
# 启用 Hubble + Prometheus
helm upgrade cilium cilium/cilium \
    --namespace kube-system \
    --set hubble.metrics.enableOpenMetrics=true \
    --set hubble.metrics.enabled="{flow:sourceContext=namespace,destinationContext=namespace}"

# 查看 Hubble Grafana Dashboard
# 访问: kubectl get-grafana
```

### 9.3 策略合规性检查

```bash
# 检查命名空间是否应用了默认拒绝
kubectl get netpol -A

# 检查端点策略状态
kubectl -n kube-system exec ds/cilium -- \
    cilium endpoint list -o json | jq '.[] | {id: .id, status: .status.policy, labels: .status.labels}'

# 查看策略覆盖率
kubectl -n kube-system exec ds/cilium -- \
    cilium-dbg policy get | grep -E "SelectorCoverage|Endpoints"
```

---

## 10. 最佳实践

### 10.1 策略设计原则

```
┌─────────────────────────────────────────────────────────────┐
│                 策略设计最佳实践                             │
│                                                             │
│  1. 分层防御：                                              │
│     L3/L4 作为基础过滤 + L7 作为深度检测                     │
│                                                             │
│  2. 默认拒绝：                                              │
│     先禁用所有流量，再精确允许需要的流量                      │
│                                                             │
│  3. 最小权限：                                              │
│     只允许必需的端口、协议、路径                              │
│                                                             │
│  4. 策略分组：                                              │
│     按服务或命名空间分组策略，便于管理                        │
│                                                             │
│  5. 审计验证：                                              │
│     部署前用 Hubble 验证策略效果                            │
└─────────────────────────────────────────────────────────────┘
```

### 10.2 常见错误

```yaml
# 错误1: 默认允许所有出口
egress:
- toCidrs:
  - "0.0.0.0/0"    # 太宽松！
# 正确做法：
egress:
- toPorts:
  - port: "443"
    protocol: TCP
  toEndpoints:
  - matchLabels:
      app: authorized-service

# 错误2: L7 策略没有配合 L4 规则
rules:
  http:
  - method: "GET"
    path: "/api/.*"
# 正确做法：
toPorts:
- port: "8080"
  protocol: TCP
  rules:
    http:
    - method: "GET"
      path: "/api/.*"

# 错误3: 策略覆盖不足
# 只应用了入口策略，没有出口策略
# 正确做法：
policyTypes:
- Ingress
- Egress
```

### 10.3 性能优化

```yaml
# 性能优化建议
# 1. 尽量在 L3/L4 完成过滤，减少 L7 检查
# 2. L7 规则使用前缀而非正则
# 3. 避免过多 catch-all 规则
# 4. 使用端点组而非单个端点

# 好的实践：
ingress:
  - fromEndpoints:
      - matchLabels:
          app: api-gateway # 标签选择器，匹配多个 Pod
    toPorts:
      - port: "8080"
        protocol: TCP
        rules:
          http:
            - method: "GET"
              path: "/api/v1.*" # 前缀匹配，性能好
```

---

## 11. 总结

| 层级   | 策略能力             | 性能 | 使用场景     |
| :----- | :------------------- | :--- | :----------- |
| **L3** | IP、CIDR、身份       | 极低 | 基础网络分段 |
| **L4** | 端口、协议           | 低   | 服务级别控制 |
| **L7** | HTTP、gRPC、DNS、SQL | 中等 | 深度安全控制 |

**关键要点**：

1. **分层防御**：L3/L4 做粗过滤，L7 做细检测
2. **默认拒绝**：最小权限原则，精确允许
3. **策略优先级**：确保高优先级策略先生效
4. **持续审计**：用 Hubble 监控和验证策略效果

通过合理使用这些策略层级，可以构建**零信任网络安全模型**，实现微服务间的细粒度访问控制。
