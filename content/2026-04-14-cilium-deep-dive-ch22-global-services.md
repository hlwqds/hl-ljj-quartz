---
title: "Cilium 深度探索 (22)：Global Services 跨集群服务访问"
date: 2026-04-14
tags:
  - cilium
  - ebpf
  - kubernetes
  - multi-cluster
  - global-services
  - failover
  - networking
  - cloud-native
---

> [!info] Cilium 2026 深度探索系列
> 0. [[2026-04-14-cilium-deep-dive-series-index|系列索引]]
> ...
> 20. [[2026-04-14-cilium-deep-dive-ch20-otel|第二十章：OpenTelemetry]]
> 21. [[2026-04-14-cilium-deep-dive-ch21-cluster-mesh|第二十一章：Cluster Mesh]]
> 22. **第二十二章：Global Services** ←

---

## 1. 概述

Global Services 是 Cilium Cluster Mesh 的核心功能之一，允许跨多个 Kubernetes 集群访问同一服务。在多集群部署中，Global Service 提供：

- **统一入口**：无论 Pod 运行在哪个集群，客户端使用相同的 DNS 名称访问
- **透明故障转移**：当一个集群的 Pod 不可用时，流量自动转移到其他集群
- **地理分布**：用户被路由到最近（最低延迟）的集群
- **零信任安全**：基于 Identity 的跨集群访问控制

---

## 2. Global Service 架构

### 2.1 工作原理

```
                    ┌─────────────────────────────────────────┐
                    │          Global Service: nginx-global   │
                    │              (10.96.0.100)              │
                    └─────────────────────────────────────────┘
                           │              │              │
            ┌──────────────┘              │              └──────────────┐
            ▼                             ▼                              ▼
   ┌─────────────────┐          ┌─────────────────┐          ┌─────────────────┐
   │   Cluster A     │          │   Cluster B     │          │   Cluster C     │
   │  Weight: 100    │          │  Weight: 50     │          │  Weight: 50     │
   │                 │          │                 │          │                 │
   │  Pod-A1 (10.1.0.10)         │  Pod-B1 (10.2.0.10)         │  Pod-C1 (10.3.0.10)         │
   │  Pod-A2 (10.1.0.11)         │  Pod-B2 (10.2.0.11)         │  Pod-C2 (10.3.0.11)         │
   └─────────────────┘          └─────────────────┘          └─────────────────┘
```

### 2.2 Service 同步机制

Global Service 的实现依赖于 **kvstore 同步**：

1. **Service 注册**：每个集群的 Cilium Agent 将本地 Service 注册到 etcd
2. **跨集群传播**：etcd 的变化通知（watch）机制将 Service 信息传播到所有集群
3. **本地缓存**：每个集群的 Agent 维护一份全局 Service 的本地缓存
4. **健康检查**：Cilium Agent 定期检查远程集群 Pod 的健康状态

```
Cluster A 的 cilium-agent 写入 kvstore：
  key: "cilium/state/services/v1/cluster-A/nginx-global"
  value: {
    frontend: "10.96.0.100",
    backends: [
      { ip: "10.1.0.10", port: 80, cluster: "cluster-A" },
      { ip: "10.1.0.11", port: 80, cluster: "cluster-A" }
    ]
  }

etcd 广播到所有集群 → Cluster B 和 Cluster C 的 Agent 收到通知
```

---

## 3. 配置 Global Service

### 3.1 基本配置

启用 Global Service 只需添加注解：

```yaml
apiVersion: v1
kind: Service
metadata:
  name: nginx-global
  annotations:
    io.cilium/global-service: "true"
spec:
  type: ClusterIP
  selector:
    app: nginx
  ports:
    - port: 80
      targetPort: 80
```

### 3.2 配置权重

通过注解配置跨集群流量权重：

```yaml
apiVersion: v1
kind: Service
metadata:
  name: nginx-global
  annotations:
    io.cilium/global-service: "true"
    io.cilium/shared-service: "true"    # 允许其他集群共享此服务
spec:
  type: ClusterIP
  selector:
    app: nginx
  ports:
    - port: 80
      targetPort: 80
---
# 在不同集群可以为同一服务设置不同权重
apiVersion: v1
kind: Service
metadata:
  name: nginx-global
  annotations:
    io.cilium/global-service: "true"
    io.cilium/service-affinity: "local"  # 优先本地后端
    io.cilium/global-service-weight: "100"  # 权重 100
```

常用注解：

| 注解 | 说明 |
|:---|:---|
| `io.cilium/global-service` | 标记为全局服务 |
| `io.cilium/shared-service` | 允许其他集群发现此服务 |
| `io.cilium/global-service-weight` | 跨集群流量权重 |
| `io.cilium/service-affinity` | `local`（优先本地）或 `all`（全局） |

---

## 4. 故障转移机制

### 4.1 健康检查流程

```
┌─────────────────────────────────────────────────────────────────┐
│                    跨集群健康检查流程                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Cluster A Agent                                                │
│      │                                                          │
│      ├── 定期检查本地 Pod nginx-A1:80 → Healthy ✓                │
│      ├── 定期检查本地 Pod nginx-A2:80 → Healthy ✓               │
│      │                                                          │
│      └── 通过 kvstore 接收 Cluster B 的健康状态                  │
│             │                                                   │
│             ├── Pod nginx-B1:80 → Healthy ✓                     │
│             └── Pod nginx-B2:80 → Unhealthy ✗ (重启中)          │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### 4.2 故障转移场景

**场景 1：单个 Pod 故障**

```
请求 → nginx-global → Cluster A (Pod-A1, Pod-A2) + Cluster B (Pod-B1)
                              ↓                          ↓
                         Pod-A1 故障               Pod-B1 正常
                              ↓                          ↓
                         自动移除                 继续提供服务
```

**场景 2：整个集群故障**

```
Cluster A 整体不可用（网络分区/灾难）
      │
      ▼
etcd 检测到 Cluster A 的节点心跳超时
      │
      ▼
所有集群的 Agent 收到通知
      │
      ▼
Cluster A 的后端从 Global Service 中移除
      │
      ▼
100% 流量切换到 Cluster B 和 Cluster C
```

### 4.3 恢复后的自动回滚

当故障集群恢复时：

1. 节点重新注册到 kvstore
2. 健康检查恢复
3. 流量逐渐恢复到正常分布

---

## 5. 跨集群 DNS 解析

### 5.1 架构

```
┌─────────────────────────────────────────────────────────────────┐
│                    跨集群 DNS 解析                                │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Client (Cluster A)                                             │
│      │                                                          │
│      │ nslookup nginx-global.default.svc.cluster.local         │
│      ▼                                                          │
│  CoreDNS (Cluster A)                                            │
│      │                                                          │
│      ├── 本地解析 → ClusterIP of nginx-global                   │
│      │                                                          │
│      └── 跨集群解析 → Global Service → ClusterMesh DNS          │
│                           │                                     │
│                           ▼                                     │
│                    返回集群最优的 ClusterIP                      │
│                    (基于健康状态 + 权重)                          │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### 5.2 配置 DNS 跨集群解析

```bash
# 启用跨集群 DNS
helm upgrade cilium cilium/cilium \
    --namespace kube-system \
    --set clustermesh.useAPIServer=true \
    --set clustermesh.enableExternalServiceIPs=true
```

客户端无需关心 Pod 实际位于哪个集群，DNS 解析自动返回最优的 Service Endpoint。

---

## 6. 流量管理与策略

### 6.1 基于权重的流量分配

```yaml
# Cluster A 的 Service（权重 100，表示主集群）
apiVersion: v1
kind: Service
metadata:
  name: nginx-global
  annotations:
    io.cilium/global-service: "true"
    io.cilium/global-service-weight: "100"
spec:
  selector:
    app: nginx
  ports:
    - port: 80

---
# Cluster B 的 Service（权重 50，表示备份集群）
apiVersion: v1
kind: Service
metadata:
  name: nginx-global
  annotations:
    io.cilium/global-service: "true"
    io.cilium/global-service-weight: "50"
spec:
  selector:
    app: nginx
  ports:
    - port: 80
```

流量分配比例：Cluster A : Cluster B = 100 : 50 ≈ 2 : 1

### 6.2 跨集群网络策略

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-frontend-to-nginx
spec:
  endpointSelector:
    matchLabels:
      app: nginx
  ingress:
    - fromEndpoints:
        - matchLabels:
            app: frontend
      # 无需指定集群，Identity 跨集群有效
```

### 6.3 零信任跨集群访问

Cilium 的 Identity 机制天然支持零信任：

1. **同 Identity 不同集群**：即使 `app=frontend` 的 Pod 分布在两个集群，它们拥有相同的 Identity
2. **策略基于 Identity**：跨集群访问时，策略检查基于 Identity 而非 IP 或集群
3. **加密传输**：Cluster Mesh 支持 WireGuard/IPsec 加密跨集群流量

---

## 7. 性能与监控

### 7.1 Hubble 观测 Global Service

```bash
# 查看跨集群流量
hubble flow --from-label app=frontend --to-label app=nginx --protocol tcp

# 输出示例
TIMESTAMP   SOURCE                         DESTINATION           TYPE           VERDICT
2026-04-14  frontend-xyz/cluster-A:12345   nginx-global/cluster-B FLOW_TO_BACKEND  FORWARDED
2026-04-14  frontend-xyz/cluster-A:12345   nginx-global/cluster-A FLOW_TO_BACKEND  FORWARDED
```

### 7.2 Prometheus Metrics

启用 Global Service 相关的 metrics：

```bash
helm upgrade cilium cilium/cilium \
    --namespace kube-system \
    --set hubble.metrics.enabled=true \
    --set hubble.metrics.export=true
```

关键指标：

| 指标 | 说明 |
|:---|:---|
| `cilium_services_global` | 全局 Service 总数 |
| `cilium_global_service_backends` | 每个 Global Service 的后端数 |
| `cilium_global_service_errors` | 跨集群健康检查失败次数 |

---

## 8. 局限性

| 限制 | 说明 |
|:---|:---|
| **L7 策略限制** | L7 (HTTP/gRPC) 策略只能在单集群内生效 |
| **Session Affinity** | 跨集群的会话亲和基于 RemoteCluster，不支持更细粒度 |
| **Headless Service** | Global Service 不支持 Headless 模式 |
| **Service Type** | 仅支持 ClusterIP 类型 |

---

## 9. 章节总结

| 概念 | 说明 |
|:---|:---|
| **Global Service** | 跨集群共享的 Service，通过 `io.cilium/global-service` 注解启用 |
| **故障转移** | 基于健康检查的自动故障转移，无需人工干预 |
| **权重配置** | 通过注解配置跨集群流量权重 |
| **DNS 解析** | 跨集群 DNS 返回最优的后端 |
| **零信任** | 基于 Identity 的访问控制，跨集群有效 |

**下一章**：探讨 CNI Chaining，了解 Cilium 如何与 Flannel、Calico 等其他 CNI 协同工作。

---

## 参考资料

- [Cilium Global Service Documentation](https://docs.cilium.io/en/stable/network/clustermesh/services/)
- [Cilium Cluster Mesh Architecture](https://docs.cilium.io/en/stable/network/clustermesh/)
- [Multi-cluster Service Failover (Cilium Design)](https://github.com/cilium/cilium/blob/main/Documentation/operations/clustermesh/services.rst)
