---
title: "Cilium 深度探索 (12)：Kubernetes NetworkPolicy 与 Cilium 增强"
date: 2026-04-14
tags:
  - cilium
  - networkpolicy
  - kubernetes
  - cidr
  - ebpf
  - security
  - networking
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
> 12. **第十二章：NetworkPolicy** ←

---

## 1. Kubernetes NetworkPolicy 概述

Kubernetes NetworkPolicy（K8s NP）是 K8s 原生的网络策略资源，定义 Pod 之间或 Pod 与外部之间的流量控制规则。NetworkPolicy 是命名空间级别资源，通过 `podSelector` 选择目标 Pod。

```yaml
# Kubernetes NetworkPolicy 示例
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: api-network-policy
  namespace: production
spec:
  # 目标 Pod 选择器
  podSelector:
    matchLabels:
      app: api
  # 入口规则
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: frontend
      ports:
        - port: 8080
          protocol: TCP
  # 出口规则
  egress:
    - to:
        - podSelector:
            matchLabels:
              app: database
      ports:
        - port: 5432
          protocol: TCP
```

### 1.1 NetworkPolicy 核心概念

| 概念             | 说明                           |
| :--------------- | :----------------------------- |
| **podSelector**  | 选择受策略影响的目标 Pod       |
| **ingress.from** | 允许访问目标 Pod 的来源        |
| **egress.to**    | 目标 Pod 允许访问的目的地      |
| **ports**        | 协议和端口规范                 |
| **policyTypes**  | 声明策略类型（INGRESS/EGRESS） |

### 1.2 默认行为

- **无 NetworkPolicy**：允许所有流量
- **有 NetworkPolicy**：只允许匹配的流量（默认拒绝未匹配）
- **命名空间隔离**：可通过 `policyTypes` 启用命名空间级别隔离

---

## 2. NetworkPolicy 资源结构

### 2.1 完整结构

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: multi-rule-policy
  namespace: production
spec:
  # 策略类型（可选，K8s 会自动推断）
  policyTypes:
    - Ingress
    - Egress

  # 目标 Pod 选择器
  podSelector:
    matchLabels:
      app: backend

  # 入口规则
  ingress:
    # 规则1: 允许前端 Pod 访问
    - from:
        - podSelector:
            matchLabels:
              app: frontend
      ports:
        - port: 8080
          protocol: TCP

    # 规则2: 允许特定命名空间的 Pod
    - from:
        - namespaceSelector:
            matchLabels:
              environment: production

    # 规则3: 允许特定 IP 范围（K8s 1.16+）
    - from:
        - ipBlock:
            cidr: 192.168.0.0/16
            except:
              - 192.168.1.0/24

  # 出口规则
  egress:
    # 规则1: 允许访问数据库
    - to:
        - podSelector:
            matchLabels:
              app: database
      ports:
        - port: 5432
          protocol: TCP

    # 规则2: 允许 DNS
    - to:
        - namespaceSelector: {}
      ports:
        - port: 53
          protocol: UDP
```

### 2.2 规则评估逻辑

```
┌─────────────────────────────────────────────────────────────┐
│               NetworkPolicy 规则评估                         │
│                                                             │
│  1. podSelector 匹配目标 Pod                                │
│       │                                                    │
│       ▼                                                    │
│  2. 评估 ingress 规则                                       │
│       │                                                    │
│       ▼                                                    │
│  3. 评估 egress 规则                                       │
│       │                                                    │
│       ▼                                                    │
│  4. 评估结果：                                              │
│     - 任何 ingress 匹配 → 允许                              │
│     - 任何 egress 匹配 → 允许                               │
│     - 无匹配 → 拒绝                                         │
└─────────────────────────────────────────────────────────────┘
```

---

## 3. Cilium 对 NetworkPolicy 的增强

Cilium 不仅支持原生 NetworkPolicy，还通过 eBPF 提供了大量增强功能：

### 3.1 增强功能对比

| 特性           | K8s NetworkPolicy | Cilium 增强                |
| :------------- | :---------------- | :------------------------- |
| **L3 CIDR**    | ✅ 支持           | ✅ + FQDN                  |
| **L4 协议**    | TCP/UDP           | + SCTP/ICMP/ANY            |
| **L7 策略**    | ❌                | ✅ HTTP/gRPC/DNS/SQL/Kafka |
| **默认拒绝**   | 部分支持          | ✅ 完整支持                |
| **策略优先级** | 基础              | 高级优先级机制             |
| **审计日志**   | ❌                | ✅ Hubble 集成             |
| **性能**       | iptables O(n)     | eBPF O(1)                  |
| **加密**       | ❌                | ✅ WireGuard/IPsec         |

### 3.2 Cilium 对 NetworkPolicy 的转换

Cilium 会自动将 K8s NetworkPolicy 转换为 eBPF 策略：

```
┌─────────────────────────────────────────────────────────────┐
│            NetworkPolicy → eBPF 转换                         │
│                                                             │
│  K8s NetworkPolicy YAML                                     │
│       │                                                    │
│       ▼                                                    │
│  Cilium Agent 解析策略                                      │
│       │                                                    │
│       ▼                                                    │
│  生成 eBPF Map 中的策略规则                                 │
│       │                                                    │
│       ▼                                                    │
│  TC Hook 执行策略检查                                       │
│                                                             │
│  自动转换，无需手动配置！                                   │
└─────────────────────────────────────────────────────────────┘
```

---

## 4. CIDR 策略

### 4.1 基于 IPBlock 的 CIDR 策略

K8s NetworkPolicy 支持 `ipBlock` 来匹配 IP 地址范围：

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ipblock-policy
spec:
  podSelector:
    matchLabels:
      app: webserver
  ingress:
    # 允许特定 IP 范围
    - from:
        - ipBlock:
            cidr: 10.0.0.0/8
            except:
              - 10.0.1.0/24 # 排除管理网段
      ports:
        - port: 80
          protocol: TCP
```

### 4.2 Cilium 扩展的 CIDR 策略

Cilium 在 K8s ipBlock 基础上增加了更多功能：

```yaml
# CiliumNetworkPolicy 支持更灵活的 CIDR 策略
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: extended-cidr-policy
spec:
  endpointSelector:
    matchLabels:
      app: secure-service
  egress:
    # 允许访问特定 IP 范围
    - toCidrs:
        - "192.168.1.0/24"
        - "10.0.0.0/8"
      toPorts:
        - port: "443"
          protocol: TCP
    # 拒绝特定 IP
    - toCidrs:
        - "!192.168.100.0/24"
      toPorts:
        - port: "80"
          protocol: TCP
```

### 4.3 FQDN 策略（出口流量）

Cilium 扩展支持基于 FQDN 的出口策略：

```yaml
# 基于域名的出口策略
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: fqdn-egress-policy
spec:
  endpointSelector:
    matchLabels:
      app: webserver
  egress:
    # 允许访问外部 API
    - toFQDNs:
        - matchPattern: "*.api.example.com"
        - matchPattern: "github.com"
      toPorts:
        - port: "443"
          protocol: TCP
```

---

## 5. 命名空间隔离

### 5.1 namespaceSelector

NetworkPolicy 支持通过 `namespaceSelector` 选择整个命名空间：

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: namespace-isolation
spec:
  podSelector:
    matchLabels:
      app: database
  ingress:
    # 只允许 production 命名空间的 Pod
    - from:
        - namespaceSelector:
            matchLabels:
              name: production
      ports:
        - port: 5432
          protocol: TCP
```

### 5.2 组合选择器

可以组合 `podSelector` 和 `namespaceSelector`：

```yaml
# 组合选择器示例
ingress:
  # 规则1: production 命名空间中的前端 Pod
  - from:
      - namespaceSelector:
          matchLabels:
            name: production
        podSelector:
          matchLabels:
            app: frontend

  # 规则2: 任何命名空间的监控服务
  - from:
      - podSelector:
          matchLabels:
            app: monitoring
```

---

## 6. 命名空间级别策略

### 6.1 默认 NetworkPolicy

可以为命名空间设置默认策略：

```yaml
# 为命名空间设置默认拒绝入口
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
spec:
  # 空 selector = 匹配所有 Pod
  podSelector: {}
  policyTypes:
    - Ingress
```

```yaml
# 为命名空间设置默认拒绝出口
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-egress
spec:
  podSelector: {}
  policyTypes:
    - Egress
```

### 6.2 命名空间默认策略组合

```yaml
# 允许必要的出口流量（DNS + API Server）
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-essential-egress
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    # 允许 DNS
    - to:
        - namespaceSelector: {}
      ports:
        - port: 53
          protocol: UDP
    # 允许 API Server
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: default
      ports:
        - port: 443
          protocol: TCP
```

---

## 7. 出口流量控制

### 7.1 基础出口策略

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: egress-policy
spec:
  podSelector:
    matchLabels:
      app: backend
  policyTypes:
    - Egress
  egress:
    # 允许访问数据库
    - to:
        - podSelector:
            matchLabels:
              app: postgres
      ports:
        - port: 5432
          protocol: TCP
```

### 7.2 完整出口控制示例

```yaml
# 完整出口控制：DNS + 数据库 + 外部 API
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: complete-egress-control
spec:
  podSelector:
    matchLabels:
      app: microservice
  policyTypes:
    - Egress
  egress:
    # 规则1: DNS 查询
    - ports:
        - port: 53
          protocol: UDP
      to:
        - namespaceSelector: {}

    # 规则2: Kubernetes API
    - ports:
        - port: 443
          protocol: TCP
      to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: default

    # 规则3: 数据库
    - to:
        - podSelector:
            matchLabels:
              app: postgresql
      ports:
        - port: 5432
          protocol: TCP

    # 规则4: 外部 HTTPS
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 10.0.0.0/8
              - 172.16.0.0/12
              - 192.168.0.0/16
      ports:
        - port: 443
          protocol: TCP
```

---

## 8. 策略优先级

### 8.1 多策略评估顺序

当一个 Pod 受多个 NetworkPolicy 影响时：

```
┌─────────────────────────────────────────────────────────────┐
│               多策略评估顺序                                │
│                                                             │
│  Pod 可能有多个 NetworkPolicy 指向它：                      │
│                                                             │
│  Policy A: 允许 ingress from frontend                       │
│  Policy B: 允许 ingress from monitoring                     │
│  Policy C: 允许 egress to database                          │
│                                                             │
│  评估结果：                                                 │
│  - ingress: 允许 frontend + monitoring                      │
│  - egress: 允许 database                                    │
│                                                             │
│  多个 ingress/egress 规则取并集                             │
└─────────────────────────────────────────────────────────────┘
```

### 8.2 Cilium 优先级机制

CiliumNetworkPolicy 支持显式优先级：

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: high-priority-policy
spec:
  # 优先级数值越小越高
  priority: 1
  endpointSelector:
    matchLabels:
      app: critical-service
  ingress:
    - fromCidrs:
        - "10.0.0.0/8"
      toPorts:
        - port: "443"
          protocol: TCP
```

---

## 9. 实际部署示例

### 9.1 三层应用策略

```yaml
# frontend → backend → database
---
# Frontend NetworkPolicy
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: frontend-policy
  namespace: production
spec:
  podSelector:
    matchLabels:
      app: frontend
  policyTypes:
    - Egress
  egress:
    - to:
        - podSelector:
            matchLabels:
              app: backend
      ports:
        - port: 8080
          protocol: TCP

---
# Backend NetworkPolicy
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: backend-policy
  namespace: production
spec:
  podSelector:
    matchLabels:
      app: backend
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: frontend
      ports:
        - port: 8080
          protocol: TCP
  egress:
    - to:
        - podSelector:
            matchLabels:
              app: database
      ports:
        - port: 5432
          protocol: TCP

---
# Database NetworkPolicy (默认拒绝所有)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: database-policy
  namespace: production
spec:
  podSelector:
    matchLabels:
      app: database
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: backend
      ports:
        - port: 5432
          protocol: TCP
```

### 9.2 多租户隔离策略

```yaml
# 租户隔离：每个租户只能访问自己的命名空间
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: tenant-isolation
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
  ingress:
    # 允许同命名空间内的 Pod 互相访问
    - from:
        - podSelector: {}
  egress:
    # 允许 DNS
    - ports:
        - port: 53
          protocol: UDP
      to:
        - namespaceSelector: {}
    # 允许同一命名空间内的 Pod
    - to:
        - podSelector: {}
```

---

## 10. 故障排除

### 10.1 常见问题

```bash
# 1. 策略不生效？检查：
# - NetworkPolicy 是否在正确命名空间
# - podSelector 是否匹配目标 Pod
# - 是否有其他策略覆盖

# 2. 检查 Cilium 策略状态
kubectl -n kube-system exec ds/cilium -- \
    cilium policy get

# 3. 查看 Hubble 流量
hubble observe --type drop

# 4. 检查端点状态
kubectl -n kube-system exec ds/cilium -- \
    cilium endpoint list
```

### 10.2 调试策略

```bash
# 查看命名空间的所有 NetworkPolicy
kubectl get netpol -n <namespace>

# 查看策略详情
kubectl describe netpol <name> -n <namespace>

# 检查 Pod 是否有策略保护
kubectl get pods -n <namespace> -l app=<label> \
    --show-labels

# 测试连通性
kubectl exec -it <source-pod> -n <namespace> -- \
    curl -v <target-service>:<port>
```

---

## 11. 总结

| 特性                  | 说明                              |
| :-------------------- | :-------------------------------- |
| **K8s NetworkPolicy** | K8s 原生资源，命名空间级别        |
| **Cilium 增强**       | eBPF 实现，性能更高，支持更多协议 |
| **CIDR 支持**         | ipBlock + Cilium FQDN 扩展        |
| **默认行为**          | 匹配策略的允许，未匹配的拒绝      |
| **最佳实践**          | 命名空间级别默认拒绝 + 精确允许   |

下一章我们将深入探讨 L7 策略，了解 Cilium 如何实现 HTTP/gRPC 等应用层协议的网络策略控制。
