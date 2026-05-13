---
title: "Cilium 深度探索 (13)：L7 网络策略深度解析"
date: 2026-04-14
tags:
  - cilium
  - networkpolicy
  - l7
  - http
  - grpc
  - rest
  - sql-injection
  - envoy
  - ebpf
  - kubernetes
  - security
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
> 11. [[2026-04-14-cilium-deep-dive-ch11-cnp|第十一章：CiliumNetworkPolicy]]
> 12. [[2026-04-14-cilium-deep-dive-ch12-networkpolicy|第十二章：NetworkPolicy]]
> 13. **第十三章：L7 策略** ←

---

## 1. L7 策略概述

L7 网络策略提供**应用层深度包检测（DPI）**，在 HTTP、gRPC、DNS、Kafka、SQL 等协议层面进行细粒度控制。相比 L3/L4 策略只能基于 IP 和端口进行过滤，L7 策略可以基于：

- HTTP 方法（GET/POST/PUT/DELETE）
- URL 路径和查询参数
- HTTP 头信息（Authorization, Content-Type）
- gRPC 方法和服务名
- DNS 查询域名
- SQL 查询语句

```yaml
# L7 HTTP 策略示例
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
                path: "/api/v1/users.*"
              - method: "POST"
                path: "/api/v1/orders"
```

### 1.1 L7 策略 vs L4 策略

| 层级   | 匹配依据         | 示例                                     |
| :----- | :--------------- | :--------------------------------------- |
| **L3** | IP 地址、 CIDR   | `fromCidrs: ["10.0.0.0/8"]`              |
| **L4** | IP + 端口 + 协议 | `toPorts: [{port: "80", protocol: TCP}]` |
| **L7** | 应用层数据       | HTTP 路径、gRPC 方法、DNS 域名           |

### 1.2 L7 策略组件架构

```
┌─────────────────────────────────────────────────────────────┐
│                  L7 策略执行架构                             │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                  eBPF Hook                          │   │
│  │                                                      │   │
│  │  TC Ingress/Egress → 解析 L4 头部                    │   │
│  │       │                                             │   │
│  │       ▼                                             │   │
│  │  如果是 HTTP → 转发到 Envoy Sidecar                 │   │
│  └─────────────────────────────────────────────────────┘   │
│                         │                                   │
│                         ▼                                   │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              Envoy Proxy (Sidecar/waypoint)         │   │
│  │                                                      │   │
│  │  L7 策略执行：                                        │   │
│  │  • HTTP 路径/方法匹配                                │   │
│  │  • Header 检查                                       │   │
│  │  • gRPC 方法匹配                                     │   │
│  │  • SQL 注入检测                                      │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

---

## 2. HTTP 策略

### 2.1 基本 HTTP 规则

HTTP 策略允许基于 HTTP 请求的方法和路径进行过滤：

```yaml
# 允许特定 HTTP 方法和路径
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: http-basic-policy
spec:
  endpointSelector:
    matchLabels:
      app: api
  ingress:
    - fromEndpoints:
        - matchLabels:
            app: client
      toPorts:
        - port: "8080"
          protocol: TCP
          rules:
            http:
              # 允许 GET 请求到 /api/users 路径
              - method: "GET"
                path: "/api/users.*"
              # 允许 POST 请求到 /api/orders 路径
              - method: "POST"
                path: "/api/orders"
```

### 2.2 HTTP 方法列表

| 方法    | 说明             | 幂等性 |
| :------ | :--------------- | :----- |
| GET     | 获取资源         | 幂等   |
| POST    | 创建资源         | 非幂等 |
| PUT     | 更新资源（完整） | 幂等   |
| PATCH   | 部分更新资源     | 非幂等 |
| DELETE  | 删除资源         | 幂等   |
| HEAD    | 获取头部信息     | 幂等   |
| OPTIONS | 获取支持的选项   | 幂等   |

### 2.3 路径匹配规则

Cilium 使用 **正则表达式** 进行路径匹配：

```yaml
# 路径匹配示例
http:
  # 精确匹配
  - method: "GET"
    path: "/health"

  # 前缀匹配
  - method: "GET"
    path: "/api/v1.*" # 匹配 /api/v1/anything

  # 带有查询参数
  - method: "GET"
    path: "/api/users\\?role=admin" # 转义 ?

  # 正则表达式
  - method: "GET"
    path: "/api/users/[0-9]+" # 匹配 /api/users/123
```

### 2.4 完整 HTTP 策略示例

```yaml
# REST API 完整策略
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: rest-api-policy
spec:
  endpointSelector:
    matchLabels:
      app: user-service
  ingress:
    - fromEndpoints:
        - matchLabels:
            app: api-gateway
      toPorts:
        - port: "8080"
          protocol: TCP
          rules:
            http:
              # 用户管理
              - method: "GET"
                path: "/api/v1/users"
              - method: "POST"
                path: "/api/v1/users"
              - method: "GET"
                path: "/api/v1/users/[0-9]+"
              - method: "PUT"
                path: "/api/v1/users/[0-9]+"
              - method: "DELETE"
                path: "/api/v1/users/[0-9]+"
              # 账户操作
              - method: "POST"
                path: "/api/v1/users/[0-9]+/password"
              - method: "POST"
                path: "/api/v1/users/[0-9]+/verify"
```

---

## 3. Header 匹配

### 3.1 基本 Header 匹配

```yaml
# 要求特定 Header
http:
  - method: "POST"
    path: "/api/payments"
    headers:
      - "Content-Type: application/json"
      - "Authorization: Bearer .*" # 正则匹配
```

### 3.2 常见 Header 匹配场景

```yaml
# API Key 验证
- method: "GET"
  path: "/api/.*"
  headers:
    - "X-API-Key: [a-f0-9]{32}" # 32位十六进制 API Key

# JWT Token 验证
- method: "POST"
  path: "/api/.*"
  headers:
    - "Authorization: Bearer eyJ.*" # JWT Token 前缀

# 来源验证
- method: "GET"
  path: "/api/.*"
  headers:
    - "X-Forwarded-For: 192\\.168\\..*"
```

### 3.3 多个 Header 要求

```yaml
# 必须同时满足多个 Header
http:
  - method: "POST"
    path: "/api/admin/.*"
    headers:
      - "X-Admin-Token: .+" # 必须有 Admin Token
      - "X-Request-ID: [a-z0-9-]+" # 必须有请求 ID
      - "Content-Type: application/json"
```

---

## 4. gRPC 策略

### 4.1 gRPC 协议基础

gRPC 使用 HTTP/2 作为传输协议，请求路径格式为 `/package.Service/Method`：

```protobuf
// gRPC 服务定义
service UserService {
  rpc GetUser (GetUserRequest) returns (User);
  rpc CreateUser (CreateUserRequest) returns (User);
  rpc DeleteUser (DeleteUserRequest) returns (google.protobuf.Empty);
}
```

gRPC 请求路径：`/UserService/GetUser`, `/UserService/CreateUser`

### 4.2 gRPC 策略配置

```yaml
# gRPC 策略
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: grpc-policy
spec:
  endpointSelector:
    matchLabels:
      app: user-service
  ingress:
    - fromEndpoints:
        - matchLabels:
            app: api-gateway
      toPorts:
        - port: "50051"
          protocol: TCP
          rules:
            http:
              # gRPC 方法匹配（使用 POST + 路径）
              - method: "POST"
                path: "/UserService/GetUser"
              - method: "POST"
                path: "/UserService/CreateUser"
              - method: "POST"
                path: "/UserService/DeleteUser"
              # 前缀匹配
              - method: "POST"
                path: "/UserService/Update.*"
```

### 4.3 gRPC 健康检查

```yaml
# gRPC 健康检查
- method: "POST"
  path: "/grpc.health.v1.Health/Check"
- method: "POST"
  path: "/grpc.health.v1.Health/Watch"
```

---

## 5. DNS 策略

### 5.1 DNS 策略配置

DNS 策略控制出口 DNS 查询：

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
              # 允许访问的域名
              - matchPattern: "*.example.com"
              - matchPattern: "api.internal.net"
              - matchPattern: "*.kubernetes.default"
```

### 5.2 DNS 策略匹配模式

```yaml
# 域名匹配模式
dns:
  # 精确域名
  - matchPattern: "api.example.com"

  # 子域名（*.example.com 匹配 api.example.com, www.example.com）
  - matchPattern: "*.example.com"

  # 多级子域名
  - matchPattern: "*.api.example.com"

  # Kubernetes 服务
  - matchPattern: "*.kubernetes.default.svc.cluster.local"
```

### 5.3 出口 DNS 控制示例

```yaml
# 限制只允许访问内部服务和特定外部域
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: restricted-dns-egress
spec:
  endpointSelector:
    matchLabels:
      app: microservice
  egress:
    # 允许 DNS 查询
    - toPorts:
        - port: "53"
          protocol: UDP
          rules:
            dns:
              # 内部 Kubernetes 服务
              - matchPattern: "*.svc.cluster.local"
              - matchPattern: "kubernetes.default"
              # 内部 API
              - matchPattern: "*.internal.net"
              - matchPattern: "db.internal.com"
              # 外部白名单
              - matchPattern: "*.github.com"
              - matchPattern: "storage.googleapis.com"
```

---

## 6. Kafka 策略

### 6.1 Kafka 协议检测

Cilium 支持 Kafka 协议的 L7 检测：

```yaml
# Kafka 策略
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: kafka-policy
spec:
  endpointSelector:
    matchLabels:
      app: kafka-consumer
  egress:
    - toEndpoints:
        - matchLabels:
            app: kafka-broker
      toPorts:
        - port: "9092"
          protocol: TCP
          rules:
            kafka:
              # 允许读取特定 topic
              - topic: "user-events"
                action: produce
              - topic: "order-events"
                action: consume
```

### 6.2 Kafka 动作

| 动作    | 说明                   |
| :------ | :--------------------- |
| produce | 允许生产消息           |
| consume | 允许消费消息           |
| read    | 读取（consume 的别名） |
| write   | 写入（produce 的别名） |

---

## 7. SQL 协议策略

### 7.1 SQL 注入防护

Cilium 支持 SQL 协议的检测，可以防护 SQL 注入攻击：

```yaml
# SQL 策略（限制 SQL 操作）
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: sql-policy
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
          rules:
            postgres:
              # 允许 SELECT
              - operation: "SELECT"
              # 允许 INSERT
              - operation: "INSERT"
              # 允许 UPDATE
              - operation: "UPDATE"
              # 允许 DELETE（限制）
              - operation: "DELETE"
                # 可以加条件限制
```

### 7.2 支持的 SQL 数据库

| 数据库     | 协议       |
| :--------- | :--------- |
| PostgreSQL | `postgres` |
| MySQL      | `mysql`    |
| Redis      | `redis`    |

### 7.3 PostgreSQL 操作类型

```yaml
postgres:
  - operation: "SELECT"
  - operation: "INSERT"
  - operation: "UPDATE"
  - operation: "DELETE"
  - operation: "CREATE"
  - operation: "DROP"
  - operation: "ALTER"
  - operation: "TRUNCATE"
  - operation: "GRANT"
  - operation: "REVOKE"
```

---

## 8. 拒绝动作与日志

### 8.1 L7 拒绝行为

当 L7 策略拒绝请求时：

```yaml
# HTTP 拒绝示例
http:
  # 只允许 GET /api/public/*
  - method: "GET"
    path: "/api/public.*"
# 其他所有请求被拒绝
```

**拒绝行为**：

- HTTP/gRPC：返回 403 Forbidden
- TCP 流：直接断开连接
- 日志：记录被拒绝的请求

### 8.2 Hubble L7 日志

```bash
# 查看 L7 策略拒绝的流量
hubble observe --type drop --protocol http

# 查看特定端点的 L7 流量
hubble observe --from-label app=frontend --to-label app=backend --type l7

# 查看 HTTP 详细信息
hubble observe --protocol http --verbose
```

### 8.3 L7 审计日志

```bash
# 启用 L7 审计日志
kubectl -n kube-system exec ds/cilium -- \
    cilium policy trace

# 查看策略评估
kubectl -n kube-system exec ds/cilium -- \
    cilium endpoint list -o json | jq '.[] | select(.status.policy.l7)'
```

---

## 9. 实际应用示例

### 9.1 API 网关 L7 策略

```yaml
# 完整的 API 网关 L7 策略
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: api-gateway-l7-policy
spec:
  endpointSelector:
    matchLabels:
      app: api-gateway
  ingress:
    # 来自前端的请求
    - fromEndpoints:
        - matchLabels:
            app: frontend
      toPorts:
        - port: "8080"
          protocol: TCP
          rules:
            http:
              # 用户 API
              - method: "GET"
                path: "/api/v1/users"
              - method: "POST"
                path: "/api/v1/users"
              - method: "GET"
                path: "/api/v1/users/[0-9]+"
              # 产品 API
              - method: "GET"
                path: "/api/v1/products"
              - method: "POST"
                path: "/api/v1/products"
              # 订单 API
              - method: "GET"
                path: "/api/v1/orders"
              - method: "POST"
                path: "/api/v1/orders"
              - method: "PUT"
                path: "/api/v1/orders/[0-9]+"
              # 健康检查
              - method: "GET"
                path: "/health"
              - method: "GET"
                path: "/metrics"
            # 拒绝其他所有请求
```

### 9.2 支付服务严格策略

```yaml
# 支付服务：严格控制所有入口
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: payment-service-policy
spec:
  endpointSelector:
    matchLabels:
      app: payment-service
  ingress:
    - fromEndpoints:
        - matchLabels:
            app: api-gateway
      toPorts:
        - port: "8080"
          protocol: TCP
          rules:
            http:
              # 支付操作
              - method: "POST"
                path: "/api/v1/payments/create"
                headers:
                  - "Authorization: Bearer .+"
                  - "X-Idempotency-Key: [a-zA-Z0-9-]+"
              - method: "GET"
                path: "/api/v1/payments/[0-9]+"
                headers:
                  - "Authorization: Bearer .+"
              # 退款
              - method: "POST"
                path: "/api/v1/payments/[0-9]+/refund"
                headers:
                  - "Authorization: Bearer .+"
                  - "X-Admin-Token: .+"
```

### 9.3 多服务协调策略

```yaml
# 服务网格中的 L7 策略协调
# 订单服务 → 库存服务 + 用户服务 + 支付服务
---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: order-service-policy
spec:
  endpointSelector:
    matchLabels:
      app: order-service
  egress:
    # 调用库存服务
    - toEndpoints:
        - matchLabels:
            app: inventory-service
      toPorts:
        - port: "8080"
          protocol: TCP
          rules:
            http:
              - method: "POST"
                path: "/api/v1/reserve"
              - method: "POST"
                path: "/api/v1/release"

    # 调用用户服务
    - toEndpoints:
        - matchLabels:
            app: user-service
      toPorts:
        - port: "8080"
          protocol: TCP
          rules:
            http:
              - method: "GET"
                path: "/api/v1/users/[0-9]+/balance"

    # 调用支付服务
    - toEndpoints:
        - matchLabels:
            app: payment-service
      toPorts:
        - port: "8080"
          protocol: TCP
          rules:
            http:
              - method: "POST"
                path: "/api/v1/charges"
```

---

## 10. 性能考虑

### 10.1 L7 策略性能影响

L7 策略需要深度包检测，性能影响比 L3/L4 更大：

| 策略类型 | 性能影响 | 原因                   |
| :------- | :------- | :--------------------- |
| L3/L4    | 极低     | eBPF O(1) 查找         |
| HTTP     | 中等     | 需要 HTTP 解析         |
| gRPC     | 中等     | HTTP/2 + Protobuf 解析 |
| SQL      | 较高     | 需要 SQL 语句解析      |
| Kafka    | 较高     | 需要 Kafka 协议解析    |

### 10.2 优化建议

```yaml
# 优化建议
# 1. 尽量使用 L3/L4 粗过滤，减少 L7 检查
# 2. HTTP 路径使用前缀匹配而非正则
# 3. 限制 Header 匹配数量
# 4. 使用 catch-all 规则减少规则数量
```

---

## 11. 故障排除

### 11.1 常见问题

```bash
# 1. L7 策略不生效？
# 检查：
# - 是否部署了 Envoy Sidecar 或 Waypoint Proxy
# - 策略是否正确定义 toPorts
# - HTTP 方法和路径是否匹配

# 2. 查看 L7 策略状态
kubectl -n kube-system exec ds/cilium -- \
    cilium policy get

# 3. 查看端点 L7 策略
kubectl -n kube-system exec ds/cilium -- \
    cilium endpoint list -o json | jq '.[] | select(.status.policy.l7)'

# 4. Hubble 流量分析
hubble observe --type drop --protocol http
hubble observe --type l7 --from-label app=client --to-label app=server
```

### 11.2 调试命令

```bash
# 查看 L7 规则
kubectl describe cnp <policy-name>

# 测试 L7 规则
kubectl exec -it <client-pod> -- \
    curl -v http://<service>:<port>/api/path

# 查看拒绝原因
hubble observe --type drop --from-label app=client | head -20
```

---

## 12. 总结

L7 网络策略是 Cilium 最强大的安全特性之一：

| 协议  | 策略能力                                |
| :---- | :-------------------------------------- |
| HTTP  | 方法、路径、Header、查询参数            |
| gRPC  | 服务名、方法名                          |
| DNS   | 域名匹配（FQDN）                        |
| Kafka | Topic、动作（produce/consume）          |
| SQL   | 操作类型（SELECT/INSERT/UPDATE/DELETE） |

L7 策略提供**应用层可见性和控制**，是实现零信任网络的关键组件。
