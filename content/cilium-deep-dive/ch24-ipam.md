---
title: "Cilium 深度探索 (24)：IPAM Pod IP 管理"
date: 2026-04-14
tags:
  - cilium
  - ebpf
  - kubernetes
  - ipam
  - pod-cidr
  - networking
  - cloud-native
---

> [!info] Cilium 2026 深度探索系列 0. [[cilium-deep-dive|系列索引]]
> ... 22. [[ch22-global-services|第二十二章：Global Services]] 23. [[ch23-cni-chain|第二十三章：CNI Chaining]] 24. **第二十四章：IPAM** ←

---

## 1. 概述

IPAM（IP Address Management）是 Cilium 网络栈的核心组件，负责：

- **Pod IP 分配**：为每个 Pod 分配唯一的 IP 地址
- **CIDR 管理**：管理节点和集群的 IP 地址范围
- **IP 预留**：保留特定 IP 供特殊用途使用
- **多集群 IP 协调**：在 Cluster Mesh 中协调跨集群 IP 分配

Cilium 支持多种 IPAM 模式，适应不同的部署场景。

---

## 2. IPAM 模式

### 2.1 三种 IPAM 模式

| 模式                          | 说明                             | 适用场景             |
| :---------------------------- | :------------------------------- | :------------------- |
| **Cluster Scope**             | 集中式 IPAM，集群级别统一管理    | 默认模式，推荐使用   |
| **Kubernetes Host Scope**     | 委托 Kubernetes ( kubelet ) 管理 | 与 kubelet IPAM 配合 |
| **AWS CNI / Azure CNI / GKE** | 云服务商管理                     | 云环境特定 CNI       |

### 2.2 Cluster Scope IPAM

这是 Cilium 的**默认和推荐模式**：

```
┌─────────────────────────────────────────────────────────────────┐
│                    Cluster Scope IPAM                           │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │                    Cilium Agent (每个节点)                  │ │
│  │                                                             │ │
│  │  1. 从集群 CIDR 申请 IP 块                                  │ │
│  │  2. 本地分配给 Pod                                          │ │
│  │  3. IP 使用信息同步到 kvstore                               │ │
│  └────────────────────────────────────────────────────────────┘ │
│                              │                                   │
│                              ▼                                   │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │                      etcd / kvstore                        │ │
│  │                                                             │ │
│  │  ipam/ipv4/allocation/<node-A> = 10.1.0.0/24               │ │
│  │  ipam/ipv4/allocation/<node-B> = 10.1.1.0/24               │ │
│  │  ipam/ipv4/assignment/ = [...]                             │ │
│  └────────────────────────────────────────────────────────────┘ │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

**工作流程**：

1. 节点加入集群时，Cilium Agent 从集群 CIDR 申请一段 IP（约 /24）
2. 节点上的 Pod 从本地 IP 块中分配 IP
3. Agent 定期同步 IP 使用状态到 kvstore
4. 故障节点的超时 IP 会被回收

### 2.3 Kubernetes Host Scope IPAM

当使用 `cni.exclusive=false`（链式模式）或 kubelet 管理 IP 时使用：

```
┌─────────────────────────────────────────────────────────────────┐
│                    Kubernetes Host Scope IPAM                   │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  kubelet 分配 Pod IP（通过 --pod-cidr 或 IPAM plugin）          │
│      │                                                          │
│      ▼                                                          │
│  Flannel / Calico / AWS CNI 创建网络接口                        │
│      │                                                          │
│      ▼                                                          │
│  Cilium 接管接口，附加 eBPF 程序                                 │
│      │                                                          │
│      ▼                                                          │
│  Cilium 不负责 IP 分配，只负责策略/观测                          │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## 3. Pod CIDR 配置

### 3.1 单集群 CIDR 配置

```bash
# 通过 helm 配置 Pod CIDR
helm install cilium cilium/cilium \
    --namespace kube-system \
    --set ipam.operator.clusterPoolIPv4PodCIDRList=10.1.0.0/16 \
    --set ipam.operator.clusterPoolIPv4MaskSize=24
```

配置参数：

| 参数                         | 说明                | 默认值       |
| :--------------------------- | :------------------ | :----------- |
| `clusterPoolIPv4PodCIDRList` | 集群范围的 Pod CIDR | `10.0.0.0/8` |
| `clusterPoolIPv4MaskSize`    | 每个节点的子网掩码  | `24`         |

### 3.2 多集群 CIDR 协调

在 Cluster Mesh 中，需要避免 Pod CIDR 冲突：

```bash
# Cluster A
helm install cilium cilium/cilium \
    --namespace kube-system \
    --set cluster.name=cluster-A \
    --set cluster.id=1 \
    --set ipam.operator.clusterPoolIPv4PodCIDRList=10.1.0.0/16

# Cluster B（使用不同的 CIDR）
helm install cilium cilium/cilium \
    --namespace kube-system \
    --set cluster.name=cluster-B \
    --set cluster.id=2 \
    --set ipam.operator.clusterPoolIPv4PodCIDRList=10.2.0.0/16
```

如果必须使用重叠 CIDR（如测试环境），依赖 Cluster Mesh 的 VNI 机制区分。

---

## 4. IP 预留机制

### 4.1 为什么需要 IP 预留？

某些场景需要预留特定 IP：

- **基础设施服务**：CoreDNS、Ingress Controller 等需要固定 IP
- **VIP（虚拟 IP）**：LoadBalancer 类型的 Service
- **外部 IP**：需要从 Pod CIDR 分配的外部服务

### 4.2 静态 IP 预留

```yaml
apiVersion: cilium.io/v2alpha1
kind: CiliumPodIPPool
metadata:
  name: reserved-pool
spec:
  ipv4:
    CIDR: 10.1.0.0/24
  reserved:
    - "10.1.0.1" # 网关
    - "10.1.0.2" # CoreDNS
    - "10.1.0.3" # Ingress
```

### 4.3 动态 IP 预留

对于 LoadBalancer Service，Cilium 支持从特定池分配：

```yaml
apiVersion: v1
kind: Service
metadata:
  name: nginx-lb
  annotations:
    io.cilium/lb-ipam-pool: "reserved-pool"
spec:
  type: LoadBalancer
  selector:
    app: nginx
  ports:
    - port: 80
```

---

## 5. IP 生命周期

### 5.1 分配流程

```
Pod 创建请求
    │
    ▼
kubelet → Container Runtime → CNI ADD
    │
    ▼
Cilium Agent IPAM 模块
    │
    ├── 检查本地可用 IP 池
    ├── 分配 IP（如 10.1.0.10）
    ├── 更新 kvstore（已分配 IP）
    ├── 创建 Veth Pair
    └── 配置 eBPF 映射
    │
    ▼
Pod 启动，IP 生效
```

### 5.2 释放流程

```
Pod 删除请求
    │
    ▼
kubelet → Container Runtime → CNI DEL
    │
    ▼
Cilium Agent IPAM 模块
    │
    ├── 删除 Veth Pair
    ├── 更新 kvstore（IP 可回收）
    ├── IP 返回本地空闲池
    └── 触发 eBPF 映射清理
```

### 5.3 故障恢复

当节点或 Agent 故障时：

```
节点故障（如网络分区）
    │
    ▼
其他节点检测到心跳超时
    │
    ▼
故障节点的 IP 块被标记为 "orphaned"
    │
    ▼
超时后（如 10 分钟），IP 块被强制回收
    │
    ▼
新节点可申请新的 IP 块
```

---

## 6. IPAM 与 eBPF 映射

### 6.1 关键 eBPF Map

Cilium 使用多个 eBPF Map 管理 IP 信息：

```bash
# 查看 IP 相关 Map
kubectl -n kube-system exec ds/cilium -- cilium bpf map list | grep -i ip

# 输出示例
NAME                     FILENAME                  TYPE
cilium_ipcache           ipcache                   hash    8   max_entries=512000
cilium_lb4_prefixes      lb4_prefixes              hash    8   max_entries=16384
cilium_lb4_services_v2  lb4_services_v2           array   28  max_entries=102400
cilium_eps_map_v2       eps_map                   hash    12  max_entries=65535
```

Map 说明：

| Map                        | 说明                                 |
| :------------------------- | :----------------------------------- |
| **cilium_ipcache**         | IP 到 Endpoint 的映射，包含 Identity |
| **cilium_lb4_prefixes**    | LoadBalancer 前缀范围                |
| **cilium_lb4_services_v2** | Service 到后端的映射                 |
| **cilium_eps_map_v2**      | Endpoint 安全身份映射                |

### 6.2 IPCache 查找

当收到目的 IP 为 `10.1.0.10` 的包时：

```c
// eBPF 程序中的 ipcache 查找
struct ipcache_key_t {
    __u32 cluster_id;
    __u32 ip;
};

struct ipcache_value_t {
    __u32 tunnel_endpoint;    // 目标节点 IP（用于隧道）
    __u32 security_identity;  // 目标 Identity
    __u8  flag;               // 本地/远程标志
};
```

---

## 7. 多集群 IPAM

### 7.1 Cluster Mesh 下的 IPAM

在 Cluster Mesh 中，IPAM 需要协调多个集群：

```
┌─────────────────────────────────────────────────────────────────┐
│                 Cluster Mesh IPAM 协调                           │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  etcd Cluster (共享 kvstore)                                    │
│      │                                                          │
│      ├── ipam/ipv4/cluster-A/node-1 = 10.1.0.0/24             │
│      ├── ipam/ipv4/cluster-A/node-2 = 10.1.1.0/24             │
│      ├── ipam/ipv4/cluster-B/node-1 = 10.2.0.0/24             │
│      └── ipam/ipv4/cluster-B/node-2 = 10.2.1.0/24             │
│                                                                  │
│  跨集群 IP 查找：                                               │
│      当 Cluster-A 的 Pod 访问 10.2.0.10 时                      │
│          → ipcache 查到 VNI=2                                   │
│          → 通过 VXLAN 隧道发送到 Cluster-B                      │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### 7.2 跨集群 CIDR 冲突解决

Cilium 通过 `cluster-id` + `VNI` 区分重叠 CIDR：

| 集群      | cluster-id | Pod CIDR    | VNI |
| :-------- | :--------- | :---------- | :-- |
| cluster-A | 1          | 10.1.0.0/16 | 1   |
| cluster-B | 2          | 10.1.0.0/16 | 2   |

即使两个集群的 Pod IP 完全相同（如都是 `10.1.0.5`），通过 VNI 也能正确区分。

---

## 8. 监控与调试

### 8.1 IPAM 状态检查

```bash
# 查看 IPAM 状态
kubectl -n kube-system exec ds/cilium -- cilium ipam list

# 输出示例
IPAM namespace: cilium-ipam
Node: node-1
  Pools: ipv4: 10.1.0.0/16
  Allocated:
    - 10.1.0.0/24 (254 IPs, 200 used)
    - 10.1.1.0/24 (254 IPs, 150 used)
```

### 8.2 IP 分配查询

```bash
# 查看特定 IP 的分配信息
kubectl -n kube-system exec ds/cilium -- cilium ipam get 10.1.0.15

# 输出示例
IP: 10.1.0.15
  Endpoint: 54321 (default/nginx-abc-123)
  Node: node-1
  Type: pod
```

### 8.3 Hubble 流量分析

```bash
# 查看特定 Pod 的 IP 分配
hubble observe --to-pod default/nginx-abc-123

# 查看特定 IP 的流量
hubble observe --ip 10.1.0.15
```

---

## 9. 章节总结

| 概念                   | 说明                                    |
| :--------------------- | :-------------------------------------- |
| **Cluster Scope IPAM** | Cilium 默认模式，集中管理 IP 分配       |
| **Host Scope IPAM**    | 委托 kubelet/主机 CNI 管理 IP           |
| **Pod CIDR**           | 每个节点的 IP 块（通常 /24）            |
| **IP 预留**            | 保留特定 IP 供基础设施使用              |
| **VNI**                | VXLAN Network Identifier，区分重叠 CIDR |
| **IPCACHE**            | eBPF Map，IP 到 Endpoint 的快速查找     |

**下一章**：探讨 etcd 部署与高可用，了解 kvstore 在 Cilium 中的角色和可靠性设计。

---

## 参考资料

- [Cilium IPAM Documentation](https://docs.cilium.io/en/stable/network/networking/ipam/)
- [Cilium IP Address Management (GitHub)](https://github.com/cilium/cilium/blob/main/Documentation/operations/ipam.rst)
- [Cluster Pool IPAM](https://docs.cilium.io/en/stable/network/networking/ipam/cluster-pool/)
