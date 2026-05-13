---
title: "Cilium 深度探索 (34)：从 Sidecar 到 Ambient 的迁移"
date: 2026-04-14
tags:
  - cilium
  - migration
  - sidecar
  - ambient-mode
  - istio
  - waypoint-proxy
  - ztunnel
  - kubernetes
  - zero-trust
---

> [!info] Cilium 2026 深度探索系列
> 0. [[2026-04-14-cilium-deep-dive-series-index|系列索引]]
> ...
> 32. [[2026-04-14-cilium-deep-dive-ch32-waypoint|第三十二章：Waypoint Proxy]]
> 33. [[2026-04-14-cilium-deep-dive-ch33-l4-l7-ambient|第三十三章：L4/L7 策略在 Ambient Mode 下的应用]]
> 34. **第三十四章：从 Sidecar 到 Ambient 的迁移** ←

---

## 1. 迁移概述

从 Sidecar 模式迁移到 Ambient Mode 是 Cilium 服务网格演进的重要步骤。Sidecar 模式虽然提供细粒度的代理控制，但每个 Pod 都需要注入独立代理，带来显著的资源开销和运维复杂性。Ambient Mode 通过节点级 Waypoint Proxy 替代 Per-Pod Sidecar，实现**零信任安全的同时降低资源消耗**。

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Sidecar 到 Ambient 迁移                          │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │                    迁移前: Sidecar 模式                        │   │
│  │                                                              │   │
│  │   Pod A              Pod B              Pod C               │   │
│  │  ┌─────────┐        ┌─────────┐        ┌─────────┐         │   │
│  │  │  App    │        │  App    │        │  App    │         │   │
│  │  │ ┌─────┐ │        │ ┌─────┐ │        │ ┌─────┐ │         │   │
│  │  │ │Sidecar│ │        │ │Sidecar│ │        │ │Sidecar│ │         │   │
│  │  │ └─────┘ │        │ └─────┘ │        │ └─────┘ │         │   │
│  │  └─────────┘        └─────────┘        └─────────┘         │   │
│  │                                                              │   │
│  │  问题:                                                       │   │
│  │  • O(n) Sidecar 数量 → 高资源开销                           │   │
│  │  • Pod 启动依赖 Sidecar → 延迟                              │   │
│  │  • Sidecar 升级 → Pod 重启                                  │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                              │                                      │
│                              │ 迁移                                 │
│                              ▼                                      │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │                    迁移后: Ambient 模式                        │   │
│  │                                                              │   │
│  │   ┌──────────────────────────────────────────────────┐      │   │
│  │   │                    Node                           │      │   │
│  │   │                                                      │      │   │
│  │   │   Pod A        Pod B        Pod C                   │      │   │
│  │   │  ┌─────────┐  ┌─────────┐  ┌─────────┐             │      │   │
│  │   │  │  App    │  │  App    │  │  App    │             │      │   │
│  │   │  └─────────┘  └─────────┘  └─────────┘             │      │   │
│  │   │        │                                         │      │   │
│  │   │        │ 流量劫持                                 │      │   │
│  │   │        ▼                                         │      │   │
│  │   │  ┌──────────────────────────────────────────┐     │      │   │
│  │   │  │        Waypoint Proxy (节点级)           │     │      │   │
│  │   │  │  ┌─────┐ ┌─────┐ ┌─────┐               │     │      │   │
│  │   │  │  │ SA:A │ │ SA:B │ │ SA:C │ ...         │     │      │   │
│  │   │  │  └─────┘ └─────┘ └─────┘               │     │      │   │
│  │   │  └──────────────────────────────────────────┘     │      │   │
│  │   └──────────────────────────────────────────────────┘      │   │
│  │                                                              │   │
│  │  优势:                                                       │   │
│  │  • O(节点数) Waypoint → 资源高效                             │   │
│  │  • Pod 独立启动 → 零延迟                                     │   │
│  │  • Waypoint 升级不影响 Pod                                  │   │
│  └─────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

### 1.1 迁移前提条件

- Kubernetes 1.24+
- Cilium 1.14+
- 已部署 Cilium 和 Istio Sidecar (若从 Sidecar 迁移)
- 命名空间标签支持 `istio.io/dataplane-mode: ambient`

### 1.2 迁移风险评估

| 风险 | 影响 | 缓解措施 |
|:---|:---|:---|
| **L7 策略兼容性** | Sidecar L7 策略可能需要调整 | 迁移前测试环境验证 |
| **mTLS 证书切换** | 短暂连接中断 | 滚动迁移避免同时切换 |
| **Waypoint 性能** | 高流量下 Waypoint 可能瓶颈 | 监控资源使用，提前扩容 |
| **Istio CRD 兼容** | 某些 Istio CRD 不支持 | 检查 CRD 兼容性 |

---

## 2. 迁移策略

### 2.1 推荐的迁移路径

```
┌─────────────────────────────────────────────────────────────────────┐
│                    推荐的三阶段迁移策略                               │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  阶段 1: 并行验证 (1-2 周)                                    │   │
│  │                                                              │   │
│  │  • 部署 parallel ambient 环境                                │   │
│  │  • 复制生产流量到测试环境                                     │   │
│  │  • 验证所有 L7 策略兼容性                                     │   │
│  │  • 性能基准测试                                              │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                              │                                       │
│                              ▼                                       │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  阶段 2: 命名空间渐进迁移 (2-4 周)                            │   │
│  │                                                              │   │
│  │  • 选择低风险命名空间开始                                     │   │
│  │  • 移除 Sidecar 注入标签                                     │   │
│  │  • 添加 Ambient 标签                                        │   │
│  │  • 验证流量正常                                              │   │
│  │  • 监控指标                                                  │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                              │                                       │
│                              ▼                                       │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  阶段 3: 全量切换与清理 (1 周)                                 │   │
│  │                                                              │   │
│  │  • 切换所有命名空间到 Ambient                                │   │
│  │  • 移除 Sidecar 注入配置                                     │   │
│  │  • 清理旧 Sidecar 资源                                      │   │
│  │  • 监控稳定后完成迁移                                        │   │
│  └─────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

### 2.2 命名空间级迁移

**渐进式迁移**：按命名空间逐个迁移，降低风险：

```bash
# 1. 为命名空间启用 Ambient Mode
kubectl label namespace <namespace> istio.io/dataplane-mode=ambient --overwrite

# 2. 验证 ztunnel 捕获命名空间流量
kubectl get ztunnel -n kube-system

# 3. 检查 Waypoint 部署状态
kubectl get ciliumenvoyconfigs -A

# 4. 验证流量
hubble observe --from-namespace <namespace> --to-namespace <namespace>
```

### 2.3 关键配置对比

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Sidecar vs Ambient 配置对比                       │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │                    Sidecar 模式配置                           │   │
│  │                                                              │   │
│  │  # Pod 注入 Sidecar                                         │   │
│  │  template:                                                  │   │
│  │    metadata:                                               │   │
│  │      annotations:                                           │   │
│  │        sidecar.istio.io/inject: "true"                      │   │
│  │    spec:                                                   │   │
│  │      containers:                                            │   │
│  │      - name: istio-proxy                                    │   │
│  │        ...                                                 │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │                    Ambient 模式配置                          │   │
│  │                                                              │   │
│  │  # Namespace 启用 Ambient                                    │   │
│  │  apiVersion: v1                                             │   │
│  │  kind: Namespace                                            │   │
│  │  metadata:                                                  │   │
│  │    name: production                                         │   │
│  │    labels:                                                  │   │
│  │      istio.io/dataplane-mode: ambient                       │   │
│  │                                                              │   │
│  │  # Pod 无需任何特殊配置                                      │   │
│  │  spec:                                                      │   │
│  │    containers:                                               │   │
│  │    - name: app                                              │   │
│  │      ...                                                     │   │
│  └─────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 3. 迁移步骤详解

### 3.1 第一步：环境准备

```bash
# 1. 确认 Cilium 版本
kubectl get cilium -n kube-system
cilium operator --version

# 2. 确认 Istio 版本 (若从 Istio Sidecar 迁移)
kubectl get pods -n istio-system

# 3. 检查当前 Sidecar 注入状态
kubectl get namespace -L istio-injection
```

### 3.2 第二步：部署 Ambient Mode 组件

```bash
# 1. 启用 Cilium Ambient Mode
helm upgrade cilium cilium/cilium \
  --version 1.14.6 \
  --namespace kube-system \
  --reuse-values \
  --set ambient.enabled=true \
  --set ztunnel.enabled=true

# 2. 等待 ztunnel DaemonSet 就绪
kubectl rollout status ds/ztunnel -n kube-system --timeout=300s

# 3. 验证 ztunnel 状态
kubectl get pods -n kube-system -l app=ztunnel
kubectl logs -n kube-system -l app=ztunnel --tail=50
```

### 3.3 第三步：验证基础连接

```bash
# 1. 创建测试命名空间
kubectl create namespace ambient-test

# 2. 启用 Ambient Mode
kubectl label namespace ambient-test istio.io/dataplane-mode=ambient

# 3. 部署测试应用
kubectl apply -n ambient-test -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: client
spec:
  containers:
  - name: sleep
    image: curlimages/curl:latest
    command: ["sleep", "infinity"]
---
apiVersion: v1
kind: Pod
metadata:
  name: server
spec:
  containers:
  - name: nginx
    image: nginx:1.25
EOF

# 4. 测试连通性
kubectl exec -it client -n ambient-test -- curl -v http://server.ambient-test.svc.cluster.local

# 5. 使用 Hubble 观察流量
hubble observe --from-pod ambient-test/client --to-pod ambient-test/server
```

### 3.4 第四步：迁移第一个命名空间

```bash
# 1. 选择低风险命名空间
NAMESPACE=staging

# 2. 备份当前 Sidecar 配置
kubectl get namespace $NAMESPACE -o yaml > /tmp/${NAMESPACE}-backup.yaml

# 3. 检查命名空间中的 Sidecar 注入状态
kubectl get namespace $NAMESPACE -o jsonpath='{.metadata.annotations.sidecar\.istio\.io/inject}'

# 4. 禁用 Sidecar 注入
kubectl label namespace $NAMESPACE istio-injection- --overwrite
kubectl annotate namespace $NAMESPACE sidecar.istio.io/inject=false --overwrite

# 5. 启用 Ambient Mode
kubectl label namespace $NAMESPACE istio.io/dataplane-mode=ambient --overwrite

# 6. 重启 Pod 以移除 Sidecar
kubectl rollout restart deployment -n $NAMESPACE
kubectl rollout restart daemonset -n $NAMESPACE

# 7. 验证 Pod 不再包含 istio-proxy
kubectl get pod -n $NAMESPACE -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .spec.containers[*]}{.name}{"\n"}{end}'
```

### 3.5 第五步：验证 L7 策略

```bash
# 1. 测试 L4 连通性
kubectl exec -it <client-pod> -n $NAMESPACE -- curl -v http://<service>.<namespace>.svc.cluster.local

# 2. 测试 L7 策略 (如果有)
kubectl exec -it <client-pod> -n $NAMESPACE -- curl -v http://<service>.<namespace>.svc.cluster.local/api/v1/users

# 3. 检查 Waypoint 是否为 L7 策略创建
kubectl get ciliumenvoyconfigs -A

# 4. 查看 Waypoint 日志
kubectl logs -n kube-system -l app=cilium-envoy --tail=100

# 5. 检查 Hubble L7 策略匹配
hubble observe --protocol=http --namespace $NAMESPACE --verdict=L7
```

### 3.6 第六步：完成迁移

```bash
# 1. 迁移所有命名空间
for NAMESPACE in $(kubectl get namespace -l istio-injection=enabled -o jsonpath='{.items[*].metadata.name}'); do
  echo "Migrating $NAMESPACE..."
  kubectl label namespace $NAMESPACE istio-injection- --overwrite
  kubectl annotate namespace $NAMESPACE sidecar.istio.io/inject=false --overwrite
  kubectl label namespace $NAMESPACE istio.io/dataplane-mode=ambient --overwrite
  kubectl rollout restart deployment -n $NAMESPACE
done

# 2. 验证所有命名空间已迁移
kubectl get namespace -l istio.io/dataplane-mode=ambient
kubectl get namespace -l istio-injection=enabled

# 3. 检查所有 Pod 不再包含 istio-proxy
kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{range .spec.containers[*]}{.name}{"\n"}{end}' | grep -v istio-proxy | wc -l
```

---

## 4. 策略转换指南

### 4.1 Istio Sidecar 资源转换

Ambient Mode 使用 Cilium CRD 替代 Istio CRD：

| Istio Sidecar 资源 | Cilium Ambient 资源 | 说明 |
|:---|:---|:---|
| `VirtualService` | `CiliumEnvoyConfig` + `CiliumNetworkPolicy` | 流量路由 |
| `DestinationRule` | `CiliumNetworkPolicy` | 负载均衡/连接池 |
| `AuthorizationPolicy` | `CiliumNetworkPolicy` | L4/L7 授权 |
| `PeerAuthentication` | 自动 (mTLS) | 传输加密 |
| `Sidecar` | 不需要 | Ambient 无 Sidecar |

### 4.2 VirtualService 转换示例

```yaml
# Istio VirtualService (Sidecar 模式)
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: payment-vs
spec:
  hosts:
  - payment
  http:
  - match:
    - headers:
        X-Request-Type:
          exact: refund
    route:
    - destination:
        host: payment
        subset: v2
  - route:
    - destination:
        host: payment
        subset: v1
```

转换后的 Cilium 配置：

```yaml
# CiliumEnvoyConfig (Ambient 模式) - 路由配置
apiVersion: cilium.io/v2
kind: CiliumEnvoyConfig
metadata:
  name: payment-l7-config
spec:
  namespace: default
  # 指向 payment 服务的 Waypoint
  backend: payment
  listeners:
    - name: http
      port: 8080
      routes:
        - name: refund-route
          match:
            headers:
              X-Request-Type:
                exact: refund
          destination:
            service: payment
            subset: v2
        - name: default-route
          destination:
            service: payment
            subset: v1
---
# CiliumNetworkPolicy - 安全策略
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: payment-policy
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
        - method: "GET"
          path: "/api/v1/.*"
```

### 4.3 AuthorizationPolicy 转换

```yaml
# Istio AuthorizationPolicy (Sidecar 模式)
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: payment-auth
spec:
  selector:
    matchLabels:
      app: payment
  rules:
  - from:
    - source:
        principals:
        - cluster.local/ns/default/sa/order
    to:
    - operation:
        methods:
        - GET
        paths:
        - /api/v1/payments.*
```

转换后的 Cilium 配置：

```yaml
# CiliumNetworkPolicy (Ambient 模式)
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: payment-auth
spec:
  endpointSelector:
    matchLabels:
      app: payment
  ingress:
  - fromRequires:
    # 要求特定 ServiceAccount 的 mTLS 身份
    - matchLabels:
        io.cilium.k8s.policy.cluster: default
        io.cilium.k8s.policy.namespace: default
        io.cilium.k8s.policy.serviceaccount: order
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

## 5. 回滚策略

### 5.1 回滚触发条件

- L7 策略验证失败
- 关键流量中断
- Waypoint 性能严重下降
- mTLS 握手失败率上升

### 5.2 回滚步骤

```bash
# 1. 停止命名空间流量 (可选)
# kubectl scale deployment <app> -n <namespace> --replicas=0

# 2. 从 Ambient 模式移除
kubectl label namespace <namespace> istio.io/dataplane-mode- --overwrite

# 3. 恢复 Sidecar 注入
kubectl label namespace <namespace> istio-injection=enabled --overwrite

# 4. 重启 Pod
kubectl rollout restart deployment -n <namespace>

# 5. 验证 Sidecar 恢复
kubectl get pod -n <namespace> -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .spec.containers[*]}{.name}{"\n"}{end}' | grep istio-proxy

# 6. 恢复流量
# kubectl scale deployment <app> -n <namespace> --replicas=<original>
```

---

## 6. 验证清单

### 6.1 迁移前检查清单

```
□ Cilium 版本 >= 1.14
□ Kubernetes 版本 >= 1.24
□ 备份所有 Istio CRD
□ 测试环境验证完成
□ L7 策略兼容性测试通过
□ 性能基准测试完成
□ 回滚方案已准备
□ 监控告警已配置
□ 团队成员已培训
```

### 6.2 迁移后验证清单

```
□ ztunnel DaemonSet 运行正常
□ Waypoint Proxy 已部署
□ Pod 不再包含 istio-proxy 容器
□ L4 连通性测试通过
□ L7 策略执行正常
□ mTLS 加密生效
□ Hubble 可观察 L4/L7 流量
□ 监控指标正常
□ 应用无异常重启
□ 用户流量正常
```

---

## 7. 总结

本章提供了从 Sidecar 模式到 Ambient Mode 的完整迁移指南：

**核心要点**：

- Ambient Mode 通过**节点级 Waypoint** 替代 Per-Pod Sidecar
- 推荐**三阶段迁移策略**：并行验证 → 渐进迁移 → 全量切换
- **命名空间级迁移**可降低风险
- Istio CRD 需要转换为 Cilium CRD
- **回滚方案**必须提前准备并验证

**迁移优势**：

- 显著降低资源开销
- 简化运维复杂度
- 提升 Pod 启动速度
- 更好的可扩展性

**下一章节预告**：Part VIII（eBPF 高级特性）将深入探讨 Cilium 的带宽管理、节点加密、透明加密等高级功能。

---

## 系列总结

Part VII（Ambient Mode）完整覆盖了 Cilium 无 Sidecar 零信任网格的核心内容：

| 章节 | 主题 | 核心价值 |
|:---|:---|:---|
| 31 | Ambient Mode 概述 | 架构理念、组件职责、启用方式 |
| 32 | Waypoint Proxy | L7 代理、身份路由、策略执行 |
| 33 | L4/L7 策略 | Ambient 模式下的策略应用 |
| 34 | 迁移指南 | 从 Sidecar 到 Ambient 的迁移路径 |

Ambient Mode 代表了 Cilium 在服务网格领域的重大创新，通过无 Sidecar 架构实现真正的零信任安全，同时保持 Cilium 一贯的高性能和可观测性优势。
