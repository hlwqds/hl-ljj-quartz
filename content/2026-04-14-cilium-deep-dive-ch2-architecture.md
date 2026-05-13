---
title: "Cilium 深度探索 (2)：Cilium 架构"
date: 2026-04-14
tags:
  - cilium
  - ebpf
  - architecture
  - kubernetes
  - networking
  - cloud-native
---

> [!info] Cilium 2026 深度探索系列 0. [[2026-04-14-cilium-deep-dive-series-index|系列索引]]
>
> 1. [[2026-04-14-cilium-deep-dive-ch1-cilium-overview|第一章：Cilium 概述]]
> 2. **第二章：Cilium 架构** ←
> 3. [[2026-04-14-cilium-deep-dive-ch3-ebpf-datapath|第三章：eBPF 数据面]]
> 4. [[2026-04-14-cilium-deep-dive-ch4-kube-proxy|第四章：Kube-Proxy 替代]]
> 5. [[2026-04-14-cilium-deep-dive-ch5-cni|第五章：CNI 集成]]

---

## 1. 整体架构概览

Cilium 采用**纯软件数据面 + 集中式控制面**的架构，数据平面完全运行在内核的 eBPF 虚拟机中，Agent 作为 DaemonSet 部署在每个节点上。

```
┌─────────────────────────────────────────────────────────────────┐
│                    Kubernetes Control Plane                      │
│              (kube-apiserver, etcd, controller managers)         │
└─────────────────────────────┬───────────────────────────────────┘
                              │ API 订阅 / 状态同步
┌─────────────────────────────▼───────────────────────────────────┐
│                     Cilium Agent (DaemonSet)                      │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │                     Cilium Daemon Process                    │ │
│  │                                                               │ │
│  │  ┌───────────────┐  ┌────────────────┐  ┌───────────────┐  │ │
│  │  │  Kubernetes   │  │   Policy       │  │   IPAM        │  │ │
│  │  │  Controller   │  │   Engine       │  │   (IP Alloc)  │  │ │
│  │  └───────┬───────┘  └───────┬────────┘  └───────────────┘  │ │
│  │          │                  │                               │ │
│  │  ┌───────▼──────────────────▼────────┐                    │ │
│  │  │         eBPF Map Manager            │                    │ │
│  │  │   (维护所有 eBPF Maps 的生命周期)    │                    │ │
│  │  └───────┬──────────────────┬──────────┘                    │ │
│  │          │                  │                               │ │
│  │  ┌───────▼──────────────────▼──────────┐                    │ │
│  │  │       eBPF Compilation Pipeline     │                    │ │
│  │  │    (clang → O(1) 加载到内核)         │                    │ │
│  │  └─────────────────────────────────────┘                    │ │
│  │                     ║                                       │ │
│  │                     ║ clang + LLVM                          │ │
│  │                     ║ (编译 eBPF 字节码)                     │ │
│  └─────────────────────║───────────────────────────────────────┘ │
│                        ║                                          │
└────────────────────────▼──────────────────────────────────────────┘
                         ║
┌────────────────────────▼──────────────────────────────────────────┐
│                      Linux Kernel                                  │
│                                                                  ║
│  ┌─────────────────────────────────────────────────────────────┐ ║
│  │                    eBPF Subsystem                           │ ║
│  │                                                             │ ║
│  │   eBPF Programs (loaded by Cilium Agent):                  │ ║
│  │   ┌─────────────────────────────────────────────────────┐   │ ║
│  │   │  TC Ingress  │  TC Egress  │  XDP  │  sk_lookup   │   │ ║
│  │   └─────────────────────────────────────────────────────┘   │ ║
│  │                                                             │ ║
│  │   eBPF Maps (shared between programs):                      │ ║
│  │   ┌─────────────────────────────────────────────────────┐   │ ║
│  │   │ cilium_services  │  cilium_eps  │  cilium_policy   │   │ ║
│  │   │ cilium_ipcache   │  cilium_tunnel│  cilium_vtep     │   │ ║
│  │   └─────────────────────────────────────────────────────┘   │ ║
│  └─────────────────────────────────────────────────────────────┘ ║
│                                                                  ║
│  ┌─────────────────────────────────────────────────────────────┐ ║
│  │               Netdev (Network Device)                       │ ║
│  │   eth0  │  vethxxx  │  cilium_host (dummy)                │ ║
│  └─────────────────────────────────────────────────────────────┘ ║
└──────────────────────────────────────────────────────────────────┘
```

---

## 2. 组件详解

### 2.1 Cilium Agent（Agent 组件）

Cilium Agent 是一个跑在每个节点上的 DaemonSet 进程，是整个 Cilium 的**控制平面 + 数据面编排器**。

**核心职责：**

1. **Kubernetes 控制器**：监听 Pod、Service、Endpoint、NetworkPolicy 变化
2. **eBPF 程序编译与加载**：将高级策略编译为 eBPF 字节码，加载到内核
3. **eBPF Map 管理**：创建、更新、删除 eBPF Map
4. **IPAM（IP Address Management）**：为节点上的 Pod 分配 IP
5. **状态同步**：与 kvstore（etcd）同步集群拓扑状态

**通信方式：**

- 通过 Kubernetes API Server 获取集群元数据（无需直接访问 etcd）
- 通过 kvstore（etcd）同步跨节点状态（Cluster Mesh）

### 2.2 eBPF Datapath（数据平面）

eBPF Datapath 是 Cilium 的**实际数据转发引擎**，完全运行在内核中。

**三层 eBPF Hook：**

```
Packet arrives at NIC
        ↓
┌─────────────────────────────────────────────────┐
│  XDP (Express Data Path)                        │
│  Earliest programmable point                    │
│  - DDoS 防护（在分配 skb 之前）                   │
│  - 直接丢包（blackholing）                       │
│  - 负载均衡（Direct Server Return）               │
└────────────────────┬────────────────────────────┘
                     ↓
┌─────────────────────────────────────────────────┐
│  TC (Traffic Control) Ingress Hook             │
│  After routing decision                        │
│  - Service 查找（cilium_services map）          │
│  - 策略检查（cilium_policy map）                │
│  - 身份验证（Security Identity）                 │
│  - VXLAN 封装/解封装                            │
└────────────────────┬────────────────────────────┘
                     ↓
┌─────────────────────────────────────────────────┐
│  Socket Operations Hook                        │
│  - connect() / bind() / sendmsg() 劫持          │
│  - 进程级别的策略（socket-based policy）        │
│  - Sockmap（TCP 连接优化）                      │
└────────────────────┬────────────────────────────┘
                     ↓
┌─────────────────────────────────────────────────┐
│  TC (Traffic Control) Egress Hook              │
│  - NAT（如果需要）                               │
│  - 出口策略检查                                  │
│  - 隧道封装                                     │
└─────────────────────────────────────────────────┘
```

### 2.3 eBPF Maps（映射表）

eBPF Map 是 Cilium 数据面的**状态存储核心**，以键值对形式存在，供 eBPF 程序和用户态进程共享访问。

| Map 名称            | 类型            | 用途                           |
| :------------------ | :-------------- | :----------------------------- |
| `cilium_services`   | LPM Trie / Hash | Service IP → Backend Pods 映射 |
| `cilium_endpoints`  | Hash            | Pod IP → Endpoint 元数据       |
| `cilium_policy`     | LPM Trie        | 安全策略规则存储               |
| `cilium_ipcache`    | LPM Trie        | IP → Identity 缓存             |
| `cilium_tunnel_map` | Tunnel          | VXLAN/Geneve 隧道端点          |
| `cilium_node_map`   | Hash            | 集群节点信息                   |
| `cilium_vtep_map`   | Hash            | VTEP（VXLAN Tunnel End Point） |

### 2.4 kvstore（分布式键值存储）

Cilium 可选使用 **etcd** 或 **consul** 作为 kvstore，主要用于：

1. **跨节点状态同步**：Cluster Mesh 中节点之间的拓扑信息
2. **Identity 分配**：确保全局唯一的 Security Identity
3. **IPAM 分配**：避免跨节点 IP 冲突（当使用 kvstore IPAM 时）
4. **Policy 同步**：在大规模集群中加速策略分发

> [!note] 无 kvstore 模式
> 在简单部署中，Cilium 可以完全不需要外部 kvstore，直接通过 Kubernetes API 获取所有元数据。

---

## 3. 两种架构模式：CCN 与 CNCM

Cilium 支持两种集群网络架构。

### 3.1 CCN（Cilium Cluster-wide Network）

CCN 是**单一 Kubernetes 集群内**的 Pod 网络模型：

```
Node A                          Node B
┌──────────────────┐           ┌──────────────────┐
│  Pod1 (10.0.0.1) │           │  Pod3 (10.0.0.3) │
│  veth ──────────┼───────────┼─ veth            │
│                  │  VXLAN   │                  │
│  Cilium Host Net │  Tunnel   │  Cilium Host Net │
│  (10.0.0.254)    │◄─────────►│  (10.0.0.254)    │
└──────────────────┘           └──────────────────┘
```

- 所有节点共享同一个 Pod CIDR
- 跨节点通信通过 VXLAN（默认）或 IPIP 隧道
- 每个节点维护完整的 Endpoint 映射

### 3.2 CNCM（Cilium Node-to-Node Connectivity Mode）

CNCM 定义了**跨节点 Pod 通信的方式**，有三种选择：

| 模式       | 隧道类型      | 封装头         | 适用场景             |
| :--------- | :------------ | :------------- | :------------------- |
| **vxlan**  | VXLAN         | 额外 50 字节   | 默认，通用           |
| **geneve** | GENEVE        | 可扩展 64 字节 | 需要携带自定义元数据 |
| **direct** | IPIP / 无封装 | 直接路由       | 高性能，支持 TSO/GSO |

### 3.3 直接路由模式（Direct Routing）

在支持的环境中，可以使用**直接路由模式**，绕过隧道封装：

```bash
# 启用直接路由 + BGP 控制平面
helm install cilium cilium/cilium \
    --set tunnel=disabled \
    --set autoDirectNodeRoutes=true \
    --set bgpControlPlane.enabled=true
```

数据包直接通过内核路由表转发，无需额外封装头。

---

## 4. 架构设计哲学

### 4.1 数据平面优先

Cilium 的核心理念是：**数据平面尽可能快地完成转发**，所有复杂逻辑在编译时（eBPF 程序加载时）确定。

```
传统 iptables：
  包到达 → 遍历每条 iptables 规则 → 匹配 → 执行动作
           ↑ 每次转发都要执行

Cilium eBPF：
  包到达 → Map 查找（O(1)）→ 执行动作
           ↑ 首次加载时编译，之后恒速
```

### 4.2 无中心化数据面

Cilium Agent 分布在每个节点上，数据面的决策完全在**本地完成**，不存在单点瓶颈或跨节点协调延迟。

```
跨节点 Service 访问路径（假设 Node A 上的 Pod 访问 Node B 上的 Pod）：

1. Pod A 发起请求到 Service IP
2. Node A 的 TC Ingress Hook 查找 cilium_services
3. 如果目标在本地 → 直接转发
4. 如果目标在远程 → 封装通过 VXLAN 发往 Node B
5. Node B 的 TC Ingress Hook 解封装
6. 查找 cilium_endpoints → 转发到 Pod B
```

### 4.3 身份与策略分离

Cilium 的安全模型基于 **Identity**，而非 IP 或端口：

```yaml
# CiliumNetworkPolicy 示例
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: "web-policy"
spec:
  endpointSelector:
    matchLabels:
      app: frontend
  ingress:
    - fromEndpoints:
        - matchLabels:
            app: backend
      toPorts:
        - port: "80"
          protocol: TCP
          rules:
            http:
              - method: "GET"
                path: "/api/*"
```

策略的目标是 `app: backend` 这个**标签身份**，而不是具体的 Pod IP。

---

## 5. 章节总结

| 组件               | 职责                                               | 位置                |
| :----------------- | :------------------------------------------------- | :------------------ |
| **Cilium Agent**   | 控制器：监听 K8s API、编译加载 eBPF 程序、管理 Map | 用户态（DaemonSet） |
| **eBPF Datapath**  | 数据面：包转发、策略执行、隧道封装                 | 内核态（eBPF VM）   |
| **eBPF Maps**      | 状态存储：Service 映射、Endpoint 元数据、策略规则  | 内核态（RAM）       |
| **kvstore (etcd)** | 跨节点状态同步、IPAM、Identity 分配                | 用户态（可选）      |
| **Hubble**         | 可观测性：Flow 日志、Metrics、UI                   | 用户态 + 内核态     |

**下一章**：深入 eBPF 数据面，理解 TC/XDP Hook、Socket 转发和 Host Routing 的实现细节。

---

## 参考资料

- [Cilium Architecture Documentation](https://docs.cilium.io/en/stable/architecture/)
- [Cilium Datapath](https://docs.cilium.io/en/stable/architecture/datapath/)
- [eBPF Maps in Cilium](https://docs.cilium.io/en/stable/bpf/)
