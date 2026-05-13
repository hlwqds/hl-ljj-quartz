---
title: "Cilium 深度探索 (27)：Gateway API 标准与 HTTPRoute"
date: 2026-04-14
tags:
  - cilium
  - gateway-api
  - httproute
  - grpcroute
  - tcproute
  - networking
  - kubernetes
  - ingress
---

> [!info] Cilium 2026 深度探索系列
> 0. [[2026-04-14-cilium-deep-dive-series-index|系列索引]]
> 1. [[2026-04-14-cilium-deep-dive-ch1-cilium-overview|第一章：Cilium 概述]]
> 2. [[2026-04-14-cilium-deep-dive-ch2-architecture|第二章：Cilium 架构]]
> ...
> 25. [[2026-04-14-cilium-deep-dive-ch25-etcd|第二十五章：etcd]]
> 26. [[2026-04-14-cilium-deep-dive-ch26-ingress|第二十六章：Cilium Ingress Controller]]
> 27. **第二十七章：Gateway API** ←

---

## 1. Gateway API 概述

Gateway API 是 Kubernetes 下一代的入口流量管理标准，提供了比传统 Ingress 更强大、更灵活的 API 模型。与 Ingress 不同，Gateway API 通过**层级化的资源结构**（Gateway → Route → Backend）实现更精细的流量控制和多租户隔离。

### 1.1 核心设计理念

```
┌─────────────────────────────────────────────────────────────┐
│                     Gateway API 资源层级                       │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                   GatewayClass                        │   │
│  │           (控制器实现，如 Cilium Gateway)              │   │
│  └───────────────────────┬─────────────────────────────┘   │
│                           │                                  │
│                           ▼                                  │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                     Gateway                           │   │
│  │         (入口点：监听端口、TLS、策略绑定)              │   │
│  └───────┬─────────────┬─────────────┬───────────────────┘   │
│          │             │             │                       │
│          ▼             ▼             ▼                       │
│  ┌───────────┐  ┌───────────┐  ┌───────────┐               │
│  │ HTTPRoute │  │ GRPCRoute │  │ TCPRoute  │               │
│  │           │  │           │  │           │               │
│  │  HTTP/   │  │   gRPC   │  │   TCP    │               │
│  │  HTTPS   │  │          │  │          │               │
│  └─────┬────┘  └─────┬────┘  └─────┬────┘               │
│        │             │             │                       │
│        └─────────────┴─────────────┘                       │
│                      │                                       │
│                      ▼                                       │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                   Backend                            │   │
│  │              (Service / ServiceImport)               │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 Gateway API vs Ingress

| 特性 | Ingress | Gateway API |
|:---|:---|:---|
| **API 版本** | networking.k8s.io/v1 | gateway.networking.k8s.io/v1 |
| **资源关系** | 单一资源 | Gateway + Route 分离 |
| **扩展性** | 注解驱动 | 原生 CRD 支持 |
| **RoleBinding** | 有限 | Route 级别的 RBAC |
| **协议支持** | HTTP/HTTPS | HTTP/HTTPS/TCP/UDP/gRPC |
| **流量权重** | 注解 | 原生字段 |
| **多租户** | 受限 | 原生支持 |

---

## 2. GatewayClass

GatewayClass 是对**入口控制器实现**的描述，类似于 IngressClass。每个 Gateway API 控制器（如 Cilium）会创建一个 GatewayClass：

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: cilium
spec:
  controllerName: io.cilium/gateway-controller
```

### 2.1 Cilium GatewayClass

Cilium Agent 自动创建 GatewayClass：

```bash
kubectl get gatewayclass
NAME      CONTROLLER                 PARAMETERS
cilium    io.cilium/gateway-controller   cilium-gateway    # 关联的参数 CR
```

---

## 3. Gateway 资源

Gateway 定义了**入口监听器**的配置，包括端口、TLS、协议等：

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: cafe-gateway
  namespace: ingress
spec:
  gatewayClassName: cilium
  listeners:
  - name: https
    port: 443
    protocol: HTTPS
    tls:
      mode: Terminate
      certificateRefs:
      - name: cafe-tls
        kind: Secret
        group: ""
        namespace: ingress
    allowedRoutes:
      namespaces:
        from: Same
  - name: http
    port: 80
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: Same
```

### 3.1 Listener 配置详解

| 字段 | 说明 |
|:---|:---|
| `name` | 监听器名称 |
| `port` | 监听端口 |
| `protocol` | HTTP/HTTPS/TCP/UDP/gRPC |
| `tls.mode` | Passthrough/Terminate |
| `tls.certificateRefs` | TLS 证书引用 |
| `allowedRoutes.namespaces` | 路由命名空间范围 |

### 3.2 TLS 配置

**终止模式（Terminate）**：

```yaml
spec:
  listeners:
  - name: https
    port: 443
    protocol: HTTPS
    tls:
      mode: Terminate
      certificateRefs:
      - name: cafe-tls-cert
        kind: Secret
```

**透传模式（Passthrough）**：

```yaml
spec:
  listeners:
  - name: tls-passthrough
    port: 443
    protocol: TLS
    tls:
      mode: Passthrough
      allowedRoutes:
        namespaces:
          from: Same
```

---

## 4. HTTPRoute 资源

HTTPRoute 定义了 HTTP 流量规则，包括主机名匹配、路径规则、权重分配等：

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: cafe-http-route
  namespace: default
spec:
  parentRefs:
  - name: cafe-gateway
    namespace: ingress
    sectionName: https
  hostnames:
  - "cafe.example.com"
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /tea
    filters:
    - type: RequestHeaderModifier
      requestHeaderModifier:
        add:
        - name: X-Tea-Request
          value: "true"
    backendRefs:
    - name: tea-svc
      port: 80
      weight: 1
  - matches:
    - path:
        type: Exact
        value: /coffee
    filters:
    - type: ResponseHeaderModifier
      responseHeaderModifier:
        add:
        - name: X-Coffee-Served
          value: "true"
    backendRefs:
    - name: coffee-svc
      port: 80
      weight: 1
```

### 4.1 路径匹配类型

| 类型 | 说明 | 示例 |
|:---|:---|:---|
| `Exact` | 精确匹配 | `/coffee` 仅匹配 `/coffee` |
| `PathPrefix` | 前缀匹配 | `/tea` 匹配 `/tea`, `/teapot` |
| `RegularExpression` | 正则匹配 | `/users/[0-9]+` |

### 4.2 权重路由

```yaml
rules:
- backendRefs:
  - name: service-v1
    port: 80
    weight: 90
  - name: service-v2
    port: 80
    weight: 10
```

---

## 5. GRPCRoute 资源

GRPCRoute 专门用于 gRPC 流量管理：

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GRPCRoute
metadata:
  name: grpc-api-route
  namespace: default
spec:
  parentRefs:
  - name: cafe-gateway
    namespace: ingress
    sectionName: https
  hostnames:
  - "api.example.com"
  rules:
  - matches:
    - method: POST
      service: cafe.CoffeeService
    - method: GET
      service: cafe.TeaService
    backendRefs:
    - name: grpc-backend
      port: 50051
```

---

## 6. TCPRoute 和 UDPRoute

### 6.1 TCPRoute

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: TCPRoute
metadata:
  name: tcp-route
spec:
  parentRefs:
  - name: cafe-gateway
    namespace: ingress
    sectionName: tcp
  rules:
  - backendRefs:
    - name: tcp-backend
      port: 9000
```

### 6.2 UDPRoute

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: UDPRoute
metadata:
  name: udp-route
spec:
  parentRefs:
  - name: cafe-gateway
    namespace: ingress
    sectionName: udp
  rules:
  - backendRefs:
    - name: dns-backend
      port: 53
```

---

## 7. Filter 机制

Gateway API 的 Filter 机制允许在请求/响应链中注入处理逻辑：

### 7.1 请求头修改

```yaml
filters:
- type: RequestHeaderModifier
  requestHeaderModifier:
    add:
    - name: X-Frontend-ID
      value: "gateway-1"
    remove:
    - name: X-Debug
```

### 7.2 响应头修改

```yaml
filters:
- type: ResponseHeaderModifier
  responseHeaderModifier:
    add:
    - name: X-Served-By
      value: "cilium-gateway"
```

### 7.3 请求镜像

```yaml
filters:
- type: RequestMirror
  requestMirror:
    backendRef:
      name: staging-backend
      port: 80
```

### 7.4 重试策略

```yaml
filters:
- type: RequestRetry
  requestRetry:
    retries: 3
    conditions:
    - type: GatewayFamily
      status: "500"
```

---

## 8. Cilium Gateway API 实现

### 8.1 架构设计

```
┌────────────────────────────────────────────────────────────┐
│                    Cilium Gateway Controller                 │
│                                                             │
│  GatewayClass ──▶ Gateway ──▶ HTTPRoute/GRPCRoute          │
│       │                │                │                   │
│       ▼                ▼                ▼                   │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              eBPF Maps                               │   │
│  │  - gateway_policy_map (L7 rules)                    │   │
│  │  - gateway_backend_map (endpoint selection)         │   │
│  │  - gateway_tls_map (certificate cache)              │   │
│  └─────────────────────────────────────────────────────┘   │
│                          │                                  │
└──────────────────────────┼──────────────────────────────────┘
                           │
                           ▼
┌────────────────────────────────────────────────────────────┐
│                    Kernel eBPF Hooks                         │
│                                                             │
│  sk_lookup: 透明流量拦截                                     │
│  sockops: TCP 连接管理                                      │
│  tc: 报文转发                                               │
└────────────────────────────────────────────────────────────┘
```

### 8.2 启用 Gateway API

```bash
# 通过 Helm 启用 Gateway API
helm upgrade cilium cilium/cilium \
  --namespace kube-system \
  --set gatewayAPI.enabled=true \
  --set ingressController.enabled=true
```

### 8.3 CRD 安装

```bash
# 安装 Gateway API CRDs
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.0.0/config/crd/standard/gateway-api-crds.yaml
```

---

## 9. 完整示例：咖啡店微服务

### 9.1 部署应用

```yaml
# cafe-backend.yaml
apiVersion: v1
kind: Service
metadata:
  name: tea-svc
  namespace: default
spec:
  ports:
  - port: 80
    targetPort: 8080
  selector:
    app: tea
---
apiVersion: v1
kind: Service
metadata:
  name: coffee-svc
  namespace: default
spec:
  ports:
  - port: 80
    targetPort: 8080
  selector:
    app: coffee
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: tea
  namespace: default
spec:
  replicas: 2
  selector:
    matchLabels:
      app: tea
  template:
    metadata:
      labels:
        app: tea
    spec:
      containers:
      - name: tea
        image: hashicorp/http-echo
        args:
        - "-text=Hello from Tea Service"
        - "-listen=:8080"
        ports:
        - containerPort: 8080
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: coffee
  namespace: default
spec:
  replicas: 2
  selector:
    matchLabels:
      app: coffee
  template:
    metadata:
      labels:
        app: coffee
    spec:
      containers:
      - name: coffee
        image: hashicorp/http-echo
        args:
        - "-text=Hello from Coffee Service"
        - "-listen=:8080"
        ports:
        - containerPort: 8080
```

### 9.2 创建 Gateway

```yaml
# cafe-gateway.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: cafe-gateway
  namespace: ingress
spec:
  gatewayClassName: cilium
  listeners:
  - name: https
    port: 443
    protocol: HTTPS
    tls:
      mode: Terminate
      certificateRefs:
      - name: cafe-tls
    allowedRoutes:
      namespaces:
        from: Same
  - name: http
    port: 80
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: Same
```

### 9.3 创建 HTTPRoute

```yaml
# cafe-httproute.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: cafe-route
  namespace: default
spec:
  parentRefs:
  - name: cafe-gateway
    namespace: ingress
    sectionName: https
  hostnames:
  - "cafe.example.com"
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /tea
    backendRefs:
    - name: tea-svc
      port: 80
  - matches:
    - path:
        type: PathPrefix
        value: /coffee
    backendRefs:
    - name: coffee-svc
      port: 80
```

---

## 10. 多租户隔离

### 10.1 Route 绑定控制

```yaml
spec:
  listeners:
  - name: tenant-a
    port: 80
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: Selector
        selector:
          matchLabels:
            tenant: a
  - name: tenant-b
    port: 80
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: Selector
        selector:
          matchLabels:
            tenant: b
```

### 10.2 RBAC 权限控制

```yaml
# 租户 A 只能管理自己的 Route
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: tenant-a-gateway-admin
  namespace: ingress
rules:
- apiGroups: ["gateway.networking.k8s.io"]
  resources: ["httproutes"]
  verbs: ["get", "list", "watch", "create", "update", "patch"]
  resourceNames: ["tenant-a-*"]
```

---

## 11. 监控与调试

### 11.1 资源状态检查

```bash
# 查看 Gateway 状态
kubectl get gateway cafe-gateway -n ingress -o yaml

# 查看 HTTPRoute 绑定状态
kubectl get httproute cafe-route -o yaml

# 查看所有 Gateway 资源
kubectl get gateway -A
```

### 11.2 条件状态解析

```yaml
# Gateway 状态条件
status:
  conditions:
  - type: Accepted
    status: True
    reason: Accepted
    message: "Gateway accepted"
  - type: ResolvedRefs
    status: True
    reason: ResolvedRefs
    message: "All references resolved"
```

### 11.3 Cilium CLI 调试

```bash
# 查看 Gateway 映射
cilium bpf lb list

# 查看 Gateway 策略
cilium policy get

# 启用详细日志
cilium status --verbose
```

---

## 12. 最佳实践

### 12.1 生产环境配置

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: production-gateway
  namespace: ingress
spec:
  gatewayClassName: cilium
  listeners:
  - name: https
    port: 443
    protocol: HTTPS
    tls:
      mode: Terminate
      certificateRefs:
      - name: production-tls
      # 最小 TLS 版本
      mode: Terminate
    allowedRoutes:
      namespaces:
        from: Same
  - name: http-redirect
    port: 80
    protocol: HTTP
    # HTTP -> HTTPS 重定向
    configuration:
      protocol: HTTP
```

### 12.2 推荐的 HTTPRoute 配置

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: production-route
  namespace: default
spec:
  parentRefs:
  - name: production-gateway
    namespace: ingress
  hostnames:
  - "api.example.com"
  rules:
  # 默认后端（404 处理）
  - backendRefs:
    - name: default-backend
      port: 80
    matches:
    - path:
        type: PathPrefix
        value: /
```

---

## 13. 总结

本章介绍了 Gateway API 的核心概念和 Cilium 的实现：

**核心要点**：

- Gateway API 通过 GatewayClass → Gateway → Route 的层级结构提供更灵活的入口管理
- HTTPRoute/GRPCRoute/TCPRoute/UDPRoute 支持多种协议
- Filter 机制支持请求/响应修改、镜像、重试等高级功能
- Cilium 原生支持 Gateway API，提供高性能的 eBPF 实现

**下一章**：Ingress 注解详解，流量分割、CORS、限速等高级配置。
