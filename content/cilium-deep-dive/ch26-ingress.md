---
title: "Cilium 深度探索 (26)：Cilium Ingress Controller"
date: 2026-04-14
tags:
  - cilium
  - ingress
  - ingress-controller
  - tls
  - kubernetes
  - networking
  - gateway-api
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
>    ...
> 10. [[ch25-etcd|第二十五章：etcd]]
> 11. **第二十六章：Cilium Ingress Controller** ←

---

## 1. Ingress 概述

Ingress 是 Kubernetes 中管理外部 HTTP/HTTPS 访问的标准资源，它提供基于域名和路径的路由、反向代理、TLS 终止等功能。在 Cilium 生态中，Ingress 不是独立部署的进程，而是通过 **Cilium Agent 内置的 eBPF 数据面** 实现，具备高性能、低延迟的优势。

```
                    ┌─────────────────────────────────────────────────┐
                    │                   Client                         │
                    │              app.example.com                      │
                    └─────────────────────┬─────────────────────────────┘
                                          │
                                          ▼
                    ┌─────────────────────────────────────────────────┐
                    │           External LB / NodePort                 │
                    │              :80 / :443                         │
                    └─────────────────────┬─────────────────────────────┘
                                          │
                    ┌─────────────────────▼─────────────────────────────┐
                    │              Cilium Agent (eBPF)                  │
                    │                                                   │
                    │   ┌─────────────────────────────────────────┐     │
                    │   │         Ingress Controller (eBPF)       │     │
                    │   │                                          │     │
                    │   │  Host Path: /etc/cilium/ingress.yaml     │     │
                    │   │  TLS termination                         │     │
                    │   │  Virtual hosting                         │     │
                    │   └─────────────────────────────────────────┘     │
                    └─────────────────────┬─────────────────────────────┘
                                          │
                    ┌─────────────────────▼─────────────────────────────┐
                    │              Backend Pods                          │
                    │         service-a (cafe.example.com)              │
                    │         service-b (api.example.com)               │
                    └─────────────────────────────────────────────────┘
```

### 1.1 Cilium Ingress vs 传统 Ingress Controller

| 特性            | Cilium Ingress | Nginx Ingress     | HAProxy Ingress    |
| :-------------- | :------------- | :---------------- | :----------------- |
| **实现方式**    | eBPF 数据面    | 用户态代理进程    | 用户态代理进程     |
| **数据路径**    | 内核 eBPF Hook | iptables → nginx  | iptables → haproxy |
| **延迟**        | < 50ns         | ~100-500μs        | ~100-300μs         |
| **TLS 终止**    | eBPF 直接处理  | nginx worker 处理 | haproxy 处理       |
| **L7 策略**     | 原生支持       | 需要额外配置      | 有限支持           |
| **与 CNI 集成** | 深度集成       | 独立部署          | 独立部署           |
| **资源占用**    | 极低           | 中等              | 中等               |

---

## 2. Cilium Ingress 架构

### 2.1 组件架构

Cilium Ingress 的核心组件：

```
┌────────────────────────────────────────────────────────────┐
│                    Cilium Agent                             │
│                                                             │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐   │
│  │  Ingress     │    │   TLS       │    │   L7         │   │
│  │  Controller  │───▶│  Manager    │───▶│  Policy      │   │
│  │              │    │             │    │  Engine      │   │
│  └──────┬───────┘    └──────────────┘    └──────────────┘   │
│         │                                                  │
│         ▼                                                  │
│  ┌────────────────────────────────────────────────────┐    │
│  │              eBPF Maps                              │    │
│  │  - ingress_policy_map (L4/L7 rules)               │    │
│  │  - tls_secret_map (certificate cache)             │    │
│  │  - backend_map (endpoint selection)               │    │
│  └────────────────────────────────────────────────────┘    │
│         │                                                  │
└─────────┼──────────────────────────────────────────────────┘
          │
          ▼
┌────────────────────────────────────────────────────────────┐
│                    Kernel eBPF Hooks                        │
│                                                             │
│  sockops/sockmap: TCP connection handling                   │
│  sk_lookup: endpoint selection                              │
│  tc: packet forwarding                                     │
└────────────────────────────────────────────────────────────┘
```

### 2.2 Ingress 资源定义

Cilium 支持标准的 Kubernetes Ingress 资源，同时提供增强功能：

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: cafe-ingress
  annotations:
    # Cilium 特定注解
    cilium.io/ingress: "true"
    cilium.io/ingress-class: "cilium"
spec:
  ingressClassName: cilium
  tls:
    - hosts:
        - cafe.example.com
      secretName: cafe-tls
  rules:
    - host: cafe.example.com
      http:
        paths:
          - path: /tea
            pathType: Prefix
            backend:
              service:
                name: tea-svc
                port:
                  number: 80
          - path: /coffee
            pathType: Exact
            backend:
              service:
                name: coffee-svc
                port:
                  number: 80
```

---

## 3. 启用 Cilium Ingress

### 3.1 通过 Helm 启用

```bash
# 使用 Helm 安装/升级 Cilium，启用 Ingress Controller
helm upgrade cilium cilium/cilium \
  --namespace kube-system \
  --set ingressController.enabled=true \
  --set ingressController.loadbalancerMode=dedicated \
  # 可选: dedicated (独占) / shared (共享) / awslb (AWS LB)
```

### 3.2 Ingress Class 配置

Cilium 会自动创建名为 `cilium` 的 IngressClass：

```yaml
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: cilium
  annotations:
    ingressclass.kubernetes.io/is-default-class: "true"
spec:
  controller: io.cilium/ingress-controller
```

---

## 4. TLS 终止

### 4.1 TLS 流程

```
Client                    Cilium Agent                    Backend Pod
   │                           │                               │
   │──── HTTPS Request ───────▶│                               │
   │   (TLS ClientHello)       │                               │
   │                           │──── TLS Handshake ───────────▶│
   │                           │◀─── TLS Response ─────────────│
   │                           │                               │
   │◀─── TLS Termination ──────│   (HTTP 明文)                  │
   │   (HTTP/1.1 请求)         │                               │
   │                           │                               │
   │──── HTTP Request ────────▶│                               │
   │                           │──── HTTP Request ───────────▶│
   │                           │◀─── HTTP Response ───────────│
   │◀─── HTTP Response ────────│                               │
```

### 4.2 TLS 配置方式

**方式一：手动创建 Secret**

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: cafe-tls
  namespace: default
type: kubernetes.io/tls
data:
  tls.crt: <base64-encoded-cert>
  tls.key: <base64-encoded-key>
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: cafe-ingress
spec:
  ingressClassName: cilium
  tls:
    - hosts:
        - cafe.example.com
      secretName: cafe-tls
  rules:
    - host: cafe.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: cafe
                port:
                  number: 80
```

**方式二：使用 cert-manager 自动管理（见第二十九章）**

---

## 5. 路径重写与重定向

### 5.1 路径重写注解

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: api-ingress
  annotations:
    # 重写 URL 路径
    cilium.io/ingress-rewrite-target: /api/v1
    # 或者使用 nginx 风格的注解（兼容）
    nginx.ingress.kubernetes.io/rewrite-target: /api/v1
spec:
  ingressClassName: cilium
  rules:
    - host: api.example.com
      http:
        paths:
          - path: /v1
            pathType: ImplementationSpecific
            backend:
              service:
                name: api-backend
                port:
                  number: 8080
```

### 5.2 正则路径匹配

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: regex-ingress
  annotations:
    cilium.io/ingress-regex-template: "^/users/(?P<id>[0-9]+)$"
spec:
  ingressClassName: cilium
  rules:
    - host: api.example.com
      http:
        paths:
          - path: /users
            pathType: ImplementationSpecific
            backend:
              service:
                name: user-service
                port:
                  number: 8080
```

---

## 6. 负载均衡策略

### 6.1 流量分配算法

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: weighted-ingress
  annotations:
    # 流量加权和分配
    cilium.io/ingress-backend-scheme: weighted
    cilium.io/ingress-service-weight: |
      {
        "tea-svc": 70,
        "coffee-svc": 30
      }
spec:
  ingressClassName: cilium
  rules:
    - host: cafe.example.com
      http:
        paths:
          - path: /beverages
            pathType: Prefix
            backend:
              service:
                name: weighted-backend
                port:
                  number: 80
```

### 6.2 会话亲和性

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: sticky-session-ingress
  annotations:
    cilium.io/ingress-session-affinity: cookie
    cilium.io/ingress-session-cookie-name: session_id
    cilium.io/ingress-session-cookie-hash: sha1
spec:
  ingressClassName: cilium
  rules:
    - host: app.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: stateful-app
                port:
                  number: 80
```

---

## 7. Cilium Ingress 与 Gateway API 对比

> [!note] 演进路径
> Cilium Ingress 是 Kubernetes 早期的入口标准，而 Gateway API 是下一代的入口标准。Cilium 同时支持两者，推荐新项目使用 Gateway API。

| 特性                 | Ingress  | Gateway API                           |
| :------------------- | :------- | :------------------------------------ |
| **资源模型**         | 单资源   | Gateway + HTTPRoute                   |
| **层级关系**         | 平坦     | 层级化 (Gateway → Route)              |
| **扩展性**           | 注解驱动 | CRD 驱动                              |
| **多租户**           | 有限     | 原生支持                              |
| **GVR (Route) 类型** | HTTP     | HTTPRoute/GRPCRoute/TCPRoute/UDPRoute |
| **后端引用**         | Service  | Service/ServiceImport/GRPCBackend     |

---

## 8. 监控与调试

### 8.1 查看 Ingress 状态

```bash
# 查看 Cilium Ingress 配置
kubectl get ingress -A

# 查看 Cilium Ingress 类
kubectl get ingressclass cilium -o yaml

# 查看 Cilium Agent 日志
kubectl logs -n kube-system -l k8s-app=cilium | grep -i ingress
```

### 8.2 Hubble 流量监控

```bash
# 启用 Hubble 流量可视化
hubble observe --type l7

# 监控特定 Ingress 流量
hubble observe --to-label app=ingress-controller

# 启用 Hubble UI
cilium hubble enable --ui
```

### 8.3 eBPF Map 检查

```bash
# 查看 ingress policy map
cilium bpf lb list

# 查看 backend 映射
cilium bpf endpoint list

# 查看 TLS secret map
cilium bpf tls list
```

---

## 9. 最佳实践

### 9.1 生产环境配置

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: production-ingress
  annotations:
    # TLS 配置
    cilium.io/ingress-tls-min-version: "TLSv1.3"
    cilium.io/ingress-tls-cipher-suites: "TLS_AES_256_GCM_SHA384,TLS_CHACHA20_POLY1305_SHA256"

    # 速率限制
    cilium.io/ingress-rate-limit: "1000"
    cilium.io/ingress-rate-limit-window: "1s"

    # CORS 配置
    cilium.io/ingress-cors-allow-origin: "*"
    cilium.io/ingress-cors-allow-methods: "GET,POST,PUT,DELETE"
    cilium.io/ingress-cors-allow-headers: "Authorization,Content-Type"

    # 代理配置
    cilium.io/ingress-proxy-timeout: "30s"
    cilium.io/ingress-proxy-buffering: "off"
spec:
  ingressClassName: cilium
  tls:
    - hosts:
        - api.example.com
      secretName: production-tls
  rules:
    - host: api.example.com
      http:
        paths:
          - path: /api
            pathType: Prefix
            backend:
              service:
                name: api-backend
                port:
                  number: 80
```

### 9.2 迁移注意事项

1. **从 Nginx Ingress 迁移**：注解兼容，但需验证 eBPF 行为差异
2. **TLS 版本**：生产环境建议 TLS 1.3
3. **健康检查**：配置自定义健康检查路径
4. **日志格式**：统一日志格式，便于监控分析

---

## 10. 总结

本章介绍了 Cilium Ingress Controller 的核心概念、架构设计和配置方法。通过 eBPF 数据面实现，Cilium Ingress 提供了高性能的 L7 流量管理能力，相比传统 Ingress Controller 有显著的性能优势。

**核心要点**：

- Cilium Ingress 通过 eBPF Hook 实现，高性能低延迟
- 支持标准 Kubernetes Ingress 资源，兼容现有配置
- 提供 TLS 终止、路径重写、流量分割等高级功能
- 推荐新项目使用 Gateway API 获取更丰富的功能

**下一章**：Gateway API 标准与 HTTPRoute/GRPCRoute 详解。
