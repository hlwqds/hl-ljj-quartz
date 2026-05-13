---
title: "Cilium 深度探索 (30)：多租户隔离"
date: 2026-04-14
tags:
  - cilium
  - multi-tenancy
  - tenant-isolation
  - network-policy
  - namespace
  - rbac
  - kubernetes
  - security
---

> [!info] Cilium 2026 深度探索系列
> 0. [[2026-04-14-cilium-deep-dive-series-index|系列索引]]
> ...
> 28. [[2026-04-14-cilium-deep-dive-ch28-ingress-annotations|第二十八章：Ingress 注解详解]]
> 29. [[2026-04-14-cilium-deep-dive-ch29-cert-manager|第二十九章：Cert-Manager 与 TLS 自动化]]
> 30. **第三十章：多租户隔离** ←

---

## 1. 多租户概述

多租户（Multi-tenancy）是指单个 Kubernetes 集群支持多个租户（团队、项目、环境）的隔离运行，每个租户只能访问自己的资源，无法影响其他租户。在云原生环境中，多租户通过**命名空间隔离 + 网络策略 + RBAC** 实现。

```
┌─────────────────────────────────────────────────────────────┐
│                    Kubernetes 集群                           │
│                                                             │
│  ┌───────────────────┐    ┌───────────────────┐           │
│  │     Tenant A       │    │     Tenant B       │           │
│  │  ┌─────────────┐   │    │  ┌─────────────┐   │           │
│  │  │ Namespace A1 │   │    │  │ Namespace B1 │   │           │
│  │  │ app: web    │   │    │  │ app: api    │   │           │
│  │  │ app: api    │   │    │  │ app: worker │   │           │
│  │  └─────────────┘   │    │  └─────────────┘   │           │
│  │  ┌─────────────┐   │    │  ┌─────────────┐   │           │
│  │  │ Namespace A2 │   │    │  │ Namespace B2 │   │           │
│  │  │ app: db    │   │    │  │ app: cache  │   │           │
│  │  └─────────────┘   │    │  └─────────────┘   │           │
│  └───────────────────┘    └───────────────────┘           │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │            Cilium NetworkPolicy (Tenant 隔离)          │   │
│  │  - Default Deny (默认拒绝)                            │   │
│  │  - Label-based 允许规则                               │   │
│  │  - L3/L4/L7 策略                                      │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 1.1 多租户隔离层级

| 层级 | 隔离方式 | 说明 |
|:---|:---|:---|
| **命名空间** | Namespace 资源 | 资源逻辑隔离 |
| **网络** | CiliumNetworkPolicy | 流量访问控制 |
| **身份** | RBAC | 权限控制 |
| **资源** | ResourceQuota | CPU/内存配额 |
| **存储** | StorageClass/PVC | 数据隔离 |

---

## 2. 命名空间级隔离

### 2.1 租户命名空间规划

```yaml
# tenant-a-namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: tenant-a
  labels:
    # 租户标识
    tenant: a
    # 环境标识
    environment: production
    # 网络隔离级别
    network-isolation: strict
---
# tenant-b-namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: tenant-b
  labels:
    tenant: b
    environment: production
    network-isolation: strict
```

### 2.2 命名空间注解

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: tenant-a
  annotations:
    # 默认网络策略
    io.cilium.namespace: "tenant-a"
    # 限速配置
    io.cilium.rate-limit: "1000/s"
```

---

## 3. Cilium 网络策略隔离

### 3.1 默认拒绝策略

每个租户命名空间应部署默认拒绝策略：

```yaml
# tenant-a-default-deny.yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: default-deny
  namespace: tenant-a
spec:
  # 端点选择器（所有 Pod）
  endpointSelector:
    matchLabels:
      # 租户 A 的所有 Pod
      tenant: a
  # ingress 规则为空 = 拒绝所有入站流量
  ingress:
  - from:
    # 允许同命名空间的 Pod
    - namespaceSelector:
        matchLabels:
          tenant: a
  egress:
  - to:
    # 允许 DNS
    - toEndpoints:
        matchLabels:
          k8s:io.kubernetes.pod.namespace=kube-system
          k8s-app: kube-dns
      ports:
      - port: "53"
        protocol: UDP
    # 允许同租户内通信
    - namespaceSelector:
        matchLabels:
          tenant: a
```

### 3.2 租户内服务通信

```yaml
# tenant-a-allow-internal.yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-internal
  namespace: tenant-a
spec:
  endpointSelector:
    matchLabels:
      tenant: a
  ingress:
  - fromEndpoints:
    - matchLabels:
        tenant: a
  egress:
  - toEndpoints:
    - matchLabels:
        tenant: a
```

### 3.3 租户间完全隔离验证

```bash
# 验证租户 A 的 Pod 无法访问租户 B
kubectl exec -n tenant-a -it frontend -- \
  curl -m 2 http://service-b.tenant-b.svc.cluster.local

# 预期结果：连接超时/拒绝
# curl: (28) Connection timed out after 2000 milliseconds
```

---

## 4. L7 策略与租户隔离

### 4.1 HTTP 服务访问控制

```yaml
# tenant-a-http-policy.yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: http-access
  namespace: tenant-a
spec:
  endpointSelector:
    matchLabels:
      app: api
      tenant: a
  ingress:
  - fromEndpoints:
    - matchLabels:
        app: frontend
        tenant: a
    # L7 HTTP 策略
    l7Protocols:
    - http:
        # 只允许特定路径
        method: "GET"
        path: "/api/v[0-9]+"
        # 允许的 Header
        headerMatches:
        - name: "Authorization"
          secret:
            name: api-auth
            namespace: tenant-a
```

### 4.2 金融租户严格隔离

```yaml
# fintech-tenant-policy.yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: fintech-isolation
  namespace: fintech
spec:
  endpointSelector:
    matchLabels:
      app: payment
      tenant: fintech
  # 入口完全隔离
  ingress:
  - fromEndpoints:
    - matchLabels:
        app: payment-gateway
        tenant: fintech
    l7Protocols:
    - http:
        method: "POST"
        path: "/payments"
        headerMatches:
        - name: "X-Tenant-ID"
          values:
          - "fintech"
  egress:
  - toEndpoints:
    - matchLabels:
        k8s:io.kubernetes.pod.namespace: fintech
        app: database
    ports:
    - port: "5432"
      protocol: TCP
  - toEndpoints:
    - matchLabels:
        k8s:io.kubernetes.pod.namespace: kube-system
        k8s-app: kube-dns
    ports:
    - port: "53"
      protocol: UDP
```

---

## 5. RBAC 权限控制

### 5.1 租户管理员 Role

```yaml
# tenant-a-admin-role.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: tenant-a-admin
  namespace: tenant-a
rules:
# 管理 Pod
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
# 管理 Service
- apiGroups: [""]
  resources: ["services"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
# 管理 ConfigMap
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
# 管理 CiliumNetworkPolicy
- apiGroups: ["cilium.io"]
  resources: ["ciliumnetworkpolicies"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
# 管理 Ingress
- apiGroups: ["networking.k8s.io"]
  resources: ["ingresses"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
```

### 5.2 租户开发者 Role

```yaml
# tenant-a-developer-role.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: tenant-a-developer
  namespace: tenant-a
rules:
# 只读 Pod
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
# 只读 Service
- apiGroups: [""]
  resources: ["services"]
  verbs: ["get", "list", "watch"]
# 读取日志
- apiGroups: [""]
  resources: ["pods/log"]
  verbs: ["get"]
# 执行命令（受限）
- apiGroups: [""]
  resources: ["pods/exec"]
  verbs: ["create"]
  resourceNames: ["*-app"]
```

### 5.3 租户 ServiceAccount

```yaml
# tenant-a-sa.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: tenant-a-admin
  namespace: tenant-a
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: tenant-a-admin-binding
  namespace: tenant-a
subjects:
- kind: ServiceAccount
  name: tenant-a-admin
  namespace: tenant-a
roleRef:
  kind: Role
  name: tenant-a-admin
  apiGroup: rbac.authorization.k8s.io
```

---

## 6. 资源配额

### 6.1 命名空间 ResourceQuota

```yaml
# tenant-a-quota.yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: tenant-a-quota
  namespace: tenant-a
spec:
  hard:
    # 计算资源
    requests.cpu: "10"
    limits.cpu: "20"
    requests.memory: "20Gi"
    limits.memory: "40Gi"
    # Pod 数量
    pods: "100"
    # Service 数量
    services: "50"
    # ConfigMap 数量
    configmaps: "100"
    # PVC 数量
    persistentvolumeclaims: "20"
    # Secret 数量
    secrets: "50"
```

### 6.2 LimitRange

```yaml
# tenant-a-limitrange.yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: tenant-a-limits
  namespace: tenant-a
spec:
  limits:
  - type: Container
    default:
      cpu: "500m"
      memory: "512Mi"
    defaultRequest:
      cpu: "100m"
      memory: "128Mi"
    max:
      cpu: "4"
      memory: "8Gi"
    min:
      cpu: "50m"
      memory: "64Mi"
```

---

## 7. Gateway API 多租户隔离

### 7.1 Gateway 命名空间隔离

```yaml
# ingress-gateway.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: shared-gateway
  namespace: ingress
spec:
  gatewayClassName: cilium
  listeners:
  # 租户 A 的监听器
  - name: tenant-a
    port: 80
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: Selector
        selector:
          matchLabels:
            tenant: a
  # 租户 B 的监听器
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

### 7.2 路由权限控制

```yaml
# 租户 A 的 Route
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: tenant-a-route
  namespace: tenant-a
spec:
  parentRefs:
  - name: shared-gateway
    namespace: ingress
    sectionName: tenant-a
  hostnames:
  - "tenant-a.example.com"
  rules:
  - backendRefs:
    - name: tenant-a-backend
      port: 80
---
# 租户 B 的 Route（无法绑定到 tenant-a 的监听器）
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: tenant-b-route
  namespace: tenant-b
spec:
  parentRefs:
  - name: shared-gateway
    namespace: ingress
    sectionName: tenant-b
  hostnames:
  - "tenant-b.example.com"
  rules:
  - backendRefs:
    - name: tenant-b-backend
      port: 80
```

### 7.3 Route RBAC

```yaml
# 租户 A 只能管理自己的 Route
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: tenant-a-route-admin
  namespace: tenant-a
rules:
- apiGroups: ["gateway.networking.k8s.io"]
  resources: ["httproutes"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  resourceNames: ["tenant-a-*"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: tenant-a-route-admin-binding
  namespace: tenant-a
subjects:
- kind: ServiceAccount
  name: tenant-a-admin
  namespace: tenant-a
roleRef:
  kind: Role
  name: tenant-a-route-admin
  apiGroup: rbac.authorization.k8s.io
```

---

## 8. 跨租户通信控制

### 8.1 共享服务模式

某些场景下需要跨租户通信（如共享数据库）：

```yaml
# 共享数据库的 NetworkPolicy
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: shared-db-access
  namespace: shared-services
spec:
  endpointSelector:
    matchLabels:
      app: shared-database
      type: postgres
  ingress:
  # 允许租户 A 的应用服务器
  - fromEndpoints:
    - matchLabels:
        tenant: a
        app: application
    ports:
    - port: "5432"
  # 允许租户 B 的应用服务器
  - fromEndpoints:
    - matchLabels:
        tenant: b
        app: application
    ports:
    - port: "5432"
```

### 8.2 服务网格跨租户

```yaml
# Ambient Mode 下的跨租户通信
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: cross-tenant-allowed
  namespace: tenant-a
spec:
  endpointSelector:
    matchLabels:
      app: shared-service
      tenant: a
  ingress:
  - fromNamespace:
      matchLabels:
        tenant: b
    # 必须有 mTLS 身份
    authentication:
      mode: required
```

---

## 9. 网络策略示例

### 9.1 电商平台多租户

```yaml
# 用户中心命名空间策略
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: user-center-policy
  namespace: user-center
spec:
  endpointSelector:
    matchLabels:
      app: user-service
  ingress:
  - fromEndpoints:
    - matchLabels:
        app: api-gateway
  egress:
  - toEndpoints:
    - matchLabels:
        app: user-database
    ports:
    - port: "3306"
  - toEndpoints:
    - matchLabels:
        k8s:io.kubernetes.pod.namespace: kube-system
        k8s-app: kube-dns
    ports:
    - port: "53"
---
# 订单中心命名空间策略
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: order-center-policy
  namespace: order-center
spec:
  endpointSelector:
    matchLabels:
      app: order-service
  ingress:
  - fromEndpoints:
    - matchLabels:
        app: api-gateway
  egress:
  - toEndpoints:
    - matchLabels:
        app: order-database
    ports:
    - port: "3306"
  - toEndpoints:
    - matchLabels:
        app: user-service
        namespace: user-center
    ports:
    - port: "8080"
  - toEndpoints:
    - matchLabels:
        k8s:io.kubernetes.pod.namespace: kube-system
        k8s-app: kube-dns
    ports:
    - port: "53"
```

### 9.2 开发/测试/生产隔离

```yaml
# 生产环境策略
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: prod-isolation
  namespace: prod
spec:
  endpointSelector:
    matchLabels:
      environment: production
  # 严格入站规则
  ingress:
  - fromEndpoints:
    - matchLabels:
        environment: production
        namespace: prod
  # 限制出站
  egress:
  - toEndpoints:
    - matchLabels:
        environment: production
        namespace: prod
    ports:
    - port: "53"
      protocol: UDP
    - port: "443"
      protocol: TCP
  - toEndpoints:
    - matchLabels:
        k8s:io.kubernetes.pod.namespace: kube-system
    ports:
    - port: "53"
      protocol: UDP
```

---

## 10. 监控与合规

### 10.1 租户流量监控

```bash
# 使用 Hubble 监控租户 A 的流量
hubble observe --namespace tenant-a --type l7

# 查看租户 A 的所有流量
hubble flow list --from-labels tenant=a --to-labels tenant=a

# 检查未授权的跨租户访问
hubble observe --to-labels tenant=b --from-labels tenant=a
```

### 10.2 策略合规检查

```bash
# 检查命名空间是否应用了默认拒绝策略
kubectl get cnp -n tenant-a

# 验证策略有效性
cilium policy get --namespace tenant-a

# 查看被拒绝的流量
hubble observe --type drop --namespace tenant-a
```

### 10.3 审计日志

```yaml
# 启用策略审计日志
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: audited-policy
  namespace: tenant-a
spec:
  endpointSelector:
    matchLabels:
      app: sensitive
  ingress:
  - from:
    - endpointSelector:
        matchLabels:
          app: authorized
    # 记录所有匹配的事件
    auditing: true
```

---

## 11. 故障排除

### 11.1 常见问题

| 问题 | 可能原因 | 解决方案 |
|:---|:---|:---|
| 跨租户通信失败 | 默认拒绝策略 | 添加 allow 规则 |
| 策略不生效 | 选择器错误 | 检查 label 匹配 |
| DNS 解析失败 | 缺少 DNS 规则 | 添加 kube-dns 允许 |
| 服务无法访问 | RBAC 权限不足 | 检查 RoleBinding |

### 11.2 调试命令

```bash
# 查看端点策略状态
kubectl get endpoints -n tenant-a -o wide

# 查看 Cilium 策略解析
cilium policy get --from-labels "tenant=a"

# 查看特定 Pod 的策略
kubectl exec -n tenant-a -it app-xxx -- cilium policy get

# 检查 Hubble 连接
hubble status

# 查看被拒绝的连接
hubble observe --type drop --from-labels tenant=a
```

---

## 12. 最佳实践

### 12.1 命名规范

```
命名空间: tenant-{name}
标签: 
  tenant: {name}
  environment: {dev|staging|prod}

示例:
  tenant-a-dev
  tenant-a-staging
  tenant-a-prod
```

### 12.2 策略模板

**默认拒绝策略模板**：

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: default-deny
  namespace: {namespace}
spec:
  endpointSelector:
    matchLabels:
      tenant: {tenant}
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          tenant: {tenant}
  egress:
  - to:
    - toEndpoints:
        matchLabels:
          k8s:io.kubernetes.pod.namespace=kube-system
          k8s-app: kube-dns
      ports:
      - port: "53"
        protocol: UDP
```

### 12.3 部署检查清单

```
多租户隔离检查清单：

□ 命名空间隔离
  □ 创建租户命名空间
  □ 应用默认标签
  □ 配置 ResourceQuota

□ 网络策略
  □ 部署默认拒绝策略
  □ 配置内部通信规则
  □ 配置 DNS 访问
  □ 配置出站规则

□ RBAC
  □ 创建租户 ServiceAccount
  □ 配置最小权限 Role
  □ 绑定 Role 到 SA

□ 监控
  □ 配置 Hubble 流量监控
  □ 设置告警规则
  □ 启用策略审计

□ 定期审查
  □ 审查策略有效性
  □ 审查 RBAC 配置
  □ 审查资源配额
```

---

## 13. 总结

本章介绍了 Cilium 多租户隔离的完整方案：

**核心要点**：

- 命名空间是租户隔离的基础资源单位
- CiliumNetworkPolicy 提供 L3/L4/L7 的流量控制
- RBAC 控制租户对 Kubernetes 资源的访问权限
- ResourceQuota 防止单个租户耗尽集群资源
- Gateway API 支持多租户共享入口的隔离路由

**隔离层级总结**：

| 层级 | 机制 | 防护范围 |
|:---|:---|:---|
| 命名空间 | Namespace | 资源逻辑隔离 |
| 网络 | CiliumNetworkPolicy | 流量访问控制 |
| 身份 | RBAC/ServiceAccount | API 操作权限 |
| 资源 | ResourceQuota/LimitRange | 资源使用限制 |
| 存储 | StorageClass/PVC | 数据隔离 |

**下一章节预告**：Cilium Ambient Mode（无 Sidecar 零信任网格），详解 Waypoint Proxy 和 L4/L7 策略在 Ambient 模式下的应用。

---

## 系列总结

Part VI（Ingress 与 Gateway API）涵盖了 Cilium 入口流量的核心内容：

| 章节 | 主题 | 核心价值 |
|:---|:---|:---|
| 26 | Ingress Controller | eBPF 数据面实现的高性能入口 |
| 27 | Gateway API | 下一代标准入口 API |
| 28 | Ingress 注解 | 流量管理、CORS、限速配置 |
| 29 | Cert-Manager | TLS 证书自动化 |
| 30 | 多租户隔离 | 命名空间级安全隔离 |

这三个部分共同构成了 Cilium 完整的**入口流量 + 安全隔离**体系。
