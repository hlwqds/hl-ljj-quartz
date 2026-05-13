---
title: "Cilium 深度探索 (21)：Cluster Mesh 多集群网络"
date: 2026-04-14
tags:
  - cilium
  - ebpf
  - kubernetes
  - multi-cluster
  - cluster-mesh
  - networking
  - cloud-native
---

> [!info] Cilium 2026 深度探索系列 0. [[2026-04-14-cilium-deep-dive-series-index|系列索引]]
>
> 1. [[2026-04-14-cilium-deep-dive-ch1-cilium-overview|第一章：Cilium 概述]]
> 2. [[2026-04-14-cilium-deep-dive-ch2-architecture|第二章：Cilium 架构]]
>    ...
> 3. [[2026-04-14-cilium-deep-dive-ch20-otel|第二十章：OpenTelemetry]]
> 4. **第二十一章：Cluster Mesh** ←

---

## 1. 背景：为什么需要多集群网络？

在企业级 Kubernetes 部署中，单集群模式往往无法满足以下需求：

- **地理分布**：跨 region/可用区部署，降低延迟，提高可用性
- **故障隔离**：一个集群的故障不应影响其他集群
- **多团队协作**：不同团队独立管理各自的集群
- **环境分离**：开发、测试、生产环境隔离
- **合规要求**：数据必须位于特定区域

传统方案需要外部 CNI 或服务网格来实现跨集群通信。Cilium Cluster Mesh 提供**原生的多集群网络解决方案**，无需额外部署组件。

---

## 2. Cluster Mesh 架构

### 2.1 整体架构

```
┌─────────────────────┐         ┌─────────────────────┐
│     Cluster A       │         │     Cluster B       │
│  ┌───────────────┐  │         │  ┌───────────────┐  │
│  │  Cilium Agent │◄─┼─────────┼─►│  Cilium Agent │  │
│  └───────────────┘  │  Tunnel  │  └───────────────┘  │
│         │          │  (VXLAN) │         │            │
│  ┌───────────────┐  │         │  ┌───────────────┐  │
│  │  cilium-node  │◄─┼─────────┼─►│  cilium-node  │  │
│  │    (kvstore)  │  │         │  │    (kvstore)  │  │
│  └───────────────┘  │         │  └───────────────┘  │
└─────────────────────┘         └─────────────────────┘
         │                              │
         └──────────┬───────────────────┘
                    │
           ┌────────▼────────┐
           │  etcd Cluster  │
           │  (共享状态存储)  │
           └────────────────┘
```

Cilium Cluster Mesh 的核心设计：

1. **每个集群独立运行**：Cilium Agent 在各自集群中运行
2. **共享 kvstore**：通过 etcd 同步集群间的网络状态
3. **VXLAN Tunnel**：跨集群流量通过加密的 VXLAN 隧道传输
4. **统一的身份管理**：跨集群使用相同的 Identity 体系

### 2.2 关键技术组件

#### Cilium Node

每个集群中的节点在 kvstore 中注册为 `cilium-node`，包含：

- 节点名称和 UID
- 节点 IP（用于隧道端点）
- Pod CIDR 范围
- 加密状态
- 隧道协议（VXLAN/Geneve）

#### IP Cache (ipcache)

跨集群的 IP 地址映射存储在 ipcache 中：

```
Cluster A 的 ipcache：
  10.1.0.0/16        → Cluster A 本地
  10.2.0.0/16        → Cluster B（通过 Tunnel）

Cluster B 的 ipcache：
  10.2.0.0/16        → Cluster B 本地
  10.1.0.0/16        → Cluster A（通过 Tunnel）
```

---

## 3. Pod CIDR 冲突解决方案

多集群网络的最大挑战之一是 **Pod CIDR 冲突**。当多个集群的 Pod IP 范围重叠时，传统的路由方案无法工作。

### 3.1 冲突场景

```
Cluster A：Pod CIDR = 10.1.0.0/16
Cluster B：Pod CIDR = 10.1.0.0/16  ← 冲突！

Cluster A 的 Pod-A：10.1.1.5
Cluster B 的 Pod-B：10.1.1.5       ← 相同 IP
```

### 3.2 Cilium 的解决方案：IP-in-VXLAN + 集群唯一标识

Cilium 通过 **VXLAN 封装** 和 **集群唯一标识** 解决冲突：

```
原始数据包：
  Src: 10.1.1.5 (Pod-A in Cluster-A)
  Dst: 10.1.1.5 (Pod-B in Cluster-B)

封装后（VXLAN）：
  Outer Src: <Cluster-A Node IP>
  Outer Dst: <Cluster-B Node IP>
  VNI: <cluster_unique_id>        ← 区分不同集群的同一 IP
  Inner Src: 10.1.1.5
  Inner Dst: 10.1.1.5
```

关键设计：

| 字段                               | 作用                                 |
| :--------------------------------- | :----------------------------------- |
| **VNI (VXLAN Network Identifier)** | 每个集群分配唯一的 VNI，32 位标识    |
| **Outer Header**                   | 使用节点 IP，而非 Pod IP             |
| **Inner Header**                   | 保留原始 Pod IP，但通过 VNI 区分集群 |

### 3.3 IP 路由查找流程

```
Pod-A (Cluster-A) → Pod-B (Cluster-B, 同一 Pod IP)
    │
    ▼
eBPF ipcache 查找
    │
    ├── 本地 endpoint（ip相同）→ 直接交付
    │
    └── 远程集群
         │
         ▼
    检查 ipcache 中是否有多集群映射
         │
         ▼
    发现 VNI != 0 → 通过 VXLAN 隧道发送
         │
         ▼
    Cluster-B 节点收到 → 解析 VNI → 交付给正确的 Pod
```

### 3.4 配置示例

```bash
# Cluster A 配置
cilium install --cluster-name cluster-A \
    --cluster-id 1 \
    --pod-cidr 10.1.0.0/16

# Cluster B 配置（使用相同 Pod CIDR）
cilium install --cluster-name cluster-B \
    --cluster-id 2 \
    --pod-cidr 10.1.0.0/16  # 与 Cluster-A 相同！
```

Cluster Mesh 通过 `cluster-id` 区分不同集群，确保即使 Pod IP 相同，也能正确路由。

---

## 4. Cluster Mesh 部署

### 4.1 前提条件

- Cilium 1.10+
- 共享的 etcd 集群（或每个集群独立的 etcd + clustermesh 功能）
- 集群间网络互通（UDP 4789 for VXLAN）
- 每个集群配置唯一的 cluster-id

### 4.2 单 etcd 模式部署

最简单的部署方式是使用**共享 etcd 集群**：

```
┌─────────────────────────────────────────────────────┐
│                   etcd Cluster                      │
│         (所有集群共享同一个 kvstore)                  │
└─────────────────────────────────────────────────────┘
         │                    │                    │
         ▼                    ▼                    ▼
┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐
│   Cluster A     │  │   Cluster B     │  │   Cluster C     │
│  cluster-id=1   │  │  cluster-id=2   │  │  cluster-id=3   │
└─────────────────┘  └─────────────────┘  └─────────────────┘
```

步骤：

```bash
# 1. 部署共享 etcd 集群（使用 etcd-operator 或 K8s 外置）
# ...

# 2. 在 Cluster A 安装 Cilium
helm install cilium cilium/cilium \
    --namespace kube-system \
    --set cluster.name=cluster-A \
    --set cluster.id=1 \
    --set etcd.enabled=true \
    --set etcd.endpoints[0]=http://etcd-A:2379 \
    --set etcd.endpoints[1]=http://etcd-B:2379 \
    --set etcd.endpoints[2]=http://etcd-C:2379

# 3. 在 Cluster B 安装 Cilium
helm install cilium cilium/cilium \
    --namespace kube-system \
    --set cluster.name=cluster-B \
    --set cluster.id=2 \
    --set etcd.enabled=true \
    --set etcd.endpoints[0]=http://etcd-A:2379 \
    --set etcd.endpoints[1]=http://etcd-B:2379 \
    --set etcd.endpoints[2]=http://etcd-C:2379

# 4. 建立集群间连接
cilium clustermesh connect --context cluster-A cluster-B
```

### 4.3 分布式 kvstore 模式

对于更大规模的部署，可以使用**分布式 kvstore**（每个集群有自己的 etcd）：

```bash
# 每个集群启用 clustermesh 功能和独立 etcd
helm install cilium cilium/cilium \
    --namespace kube-system \
    --set cluster.name=cluster-A \
    --set cluster.id=1 \
    --set clustermesh.enabled=true \
    --set etcd.enabled=true \
    --set etcd.peer.enabled=true
```

---

## 5. 跨集群服务发现

### 5.1 Global Service

Cluster Mesh 支持**跨集群服务访问**，称为 Global Service：

```yaml
apiVersion: v1
kind: Service
metadata:
  name: nginx-global
  annotations:
    io.cilium/global-service: "true" # 标记为全局服务
spec:
  selector:
    app: nginx
  ports:
    - port: 80
```

### 5.2 跨集群流量分布

```
┌─────────────────────────────────────────────────────────────┐
│                    Global Service nginx-global              │
├─────────────────────────────────────────────────────────────┤
│  Cluster A (weight=100)                                    │
│  ├── Pod nginx-1 (10.1.0.10:80)                            │
│  └── Pod nginx-2 (10.1.0.11:80)                            │
│                                                             │
│  Cluster B (weight=50)                                      │
│  ├── Pod nginx-3 (10.2.0.10:80)                            │
│  └── Pod nginx-4 (10.2.0.11:80)                            │
└─────────────────────────────────────────────────────────────┘
```

Global Service 支持：

- **跨集群健康检查**：Cilium 自动检查远程集群 Pod 的健康状态
- **故障转移**：当一个集群的 Pod 不可用时，流量自动转到其他集群
- **权重配置**：支持基于权重的流量分配

---

## 6. 网络策略跨集群扩展

### 6.1 CiliumNetworkPolicy 跨集群

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
      # 无需指定 fromClusters，相同 Identity 即可跨集群通信
```

### 6.2 跨集群身份验证

Cilium 基于 **Identity** 而非 IP 进行策略匹配。当 Pod 从集群 A 访问集群 B 时：

1. 源 Pod 的 Identity（`app=frontend`）被封装在 VXLAN 包中
2. 目标集群验证源 Identity
3. 如果策略允许，流量通过

---

## 7. 性能与局限

### 7.1 性能考量

| 指标             | 影响                                                         |
| :--------------- | :----------------------------------------------------------- |
| **VXLAN 开销**   | 额外 50 字节封装，对于 MTU 1500 的网络，实际 Payload 为 1450 |
| **隧道延迟**     | 额外的封装/解封装操作，通常增加 0.1-0.3ms                    |
| **kvstore 依赖** | 节点状态同步依赖 etcd，需要保证低延迟                        |

### 7.2 局限性

- **不支持 NetworkPolicy L7 跨集群**：L7 策略只能在单集群内生效
- **需要额外部署 etcd**：相比单集群，增加了运维复杂度
- **不支持嵌套集群**：Cluster Mesh 不支持多集群的嵌套

---

## 8. 章节总结

本章介绍了 Cilium Cluster Mesh 多集群网络方案：

| 概念                               | 说明                                   |
| :--------------------------------- | :------------------------------------- |
| **Cluster Mesh**                   | Cilium 原生的多集群网络方案            |
| **cluster-id**                     | 唯一标识每个集群，32 位整数            |
| **VNI (VXLAN Network Identifier)** | 区分重叠的 Pod IP                      |
| **IP-in-VXLAN**                    | 通过 VXLAN 封装解决 CIDR 冲突          |
| **Global Service**                 | 跨集群服务访问，支持健康检查和故障转移 |
| **共享 kvstore**                   | 通过 etcd 同步集群间状态               |

**下一章**：深入讲解 Global Services，探讨跨集群服务访问的详细机制和故障转移策略。

---

## 参考资料

- [Cilium Cluster Mesh Documentation](https://docs.cilium.io/en/stable/network/clustermesh/)
- [Cilium Multi-cluster IPAM](https://docs.cilium.io/en/stable/network/networking/ipam/)
- [Cluster Mesh Architecture (Cilium Design)](https://github.com/cilium/cilium/blob/main/Documentation/operations/clustermesh.rst)
