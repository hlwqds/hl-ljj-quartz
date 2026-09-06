---
title: "Cilium 深度探索 (5)：CNI 集成"
date: 2026-04-14
tags:
  - cilium
  - cni
  - kubernetes
  - networking
  - chaining
  - standalone
---

> [!info] Cilium 2026 深度探索系列 0. [[cilium-deep-dive|系列索引]]
>
> 1. [[ch1-cilium-overview|第一章：Cilium 概述]]
> 2. [[ch2-architecture|第二章：Cilium 架构]]
> 3. [[ch3-ebpf-datapath|第三章：eBPF 数据面]]
> 4. [[ch4-kube-proxy|第四章：Kube-Proxy 替代]]
> 5. **第五章：CNI 集成** ←

---

## 1. CNI 概述

### 1.1 什么是 CNI？

CNI（Container Networking Interface）是 CNCF 定义的**容器网络接口标准**。它规定了容器运行时（如 containerd、cri-o）与网络插件（如 Cilium、Calico、Flannel）之间的接口。

> [!tip] 延伸阅读
> 如果想进一步理解 veth、netkit、`bpf_redirect_peer()` 这些容器网络快路径，
> 可以看：[[netkit-container-networking|eBPF 深入理解：netkit、veth 与容器网络加速]]

```
容器运行时                    CNI 插件
    │                            │
    │ ──── ADD (创建容器) ──────→ │
    │ ←─── ADD 命令执行完成 ──── │
    │                            │
    │ ──── DEL (删除容器) ──────→ │
    │ ←─── DEL 命令执行完成 ──── │
    │                            │
    │ ──── CHECK (检查状态) ────→ │
    │ ←─── CHECK 返回 ────────── │
```

**CNI 工作流程（Pod 创建时）：**

```
Pod 创建请求
    ↓
Kubelet 调用 CNI ADD
    ↓
CNI 插件：
  1. 创建网络命名空间
  2. 创建 veth pair
  3. 分配 IP 地址（通过 IPAM）
  4. 配置路由
  5. 设置网络策略（可选）
    ↓
返回 CONTAINER_ID, IP 地址, 路由信息
```

### 1.2 标准 CNI 插件列表

| 插件                      | 特点                           | 隧道/路由        |
| :------------------------ | :----------------------------- | :--------------- |
| **Cilium**                | eBPF 数据面，L7 策略，Hubble   | VXLAN / 直接路由 |
| **Calico**                | 纯路由，BGP 控制平面，网络策略 | IPIP / 直接路由  |
| **Flannel**               | 简单，Overlay 网络             | VXLAN / UDP      |
| **Weave Net**             | 自动 Mesh，加密                | sleeve / fastdp  |
| **Cilium（AWS VPC CNI）** | AWS 原生 ENI                   | 直接路由         |

---

## 2. Cilium 的两种 CNI 模式

Cilium 支持两种 CNI 集成方式：

| 模式                       | 说明                                  | 使用场景                      |
| :------------------------- | :------------------------------------ | :---------------------------- |
| **Standalone（独立模式）** | Cilium 作为唯一 CNI，负责所有网络功能 | 新部署，追求最高性能          |
| **Chaining（链式模式）**   | Cilium 叠加在另一个 CNI 之上          | 现有集群迁移，云厂商 CNI 集成 |

---

## 3. Standalone 模式

### 3.1 架构

Standalone 模式下，Cilium 是**唯一的 CNI 插件**，完全替代 kube-proxy 和传统 CNI：

```
┌─────────────────────────────────────────────────────────┐
│                    Kubernetes Node                       │
│                                                          │
│  Kubelet                                                  │
│    │                                                      │
│    │ CNI 调用                                             │
│    ▼                                                      │
│  ┌─────────────────────────────────────────────────┐     │
│  │              Cilium CNI Plugin                   │     │
│  │                                                  │     │
│  │  - IPAM（IP 分配）                               │     │
│  │  - veth pair 创建                                │     │
│  │  - 路由配置                                       │     │
│  │  - eBPF 程序加载                                 │     │
│  │  - Endpoint 注册                                 │     │
│  └─────────────────────────────────────────────────┘     │
│    │                                                      │
│    │ 网络命名空间创建 / 配置                              │
│    ▼                                                      │
│  ┌─────────────────────────────────────────────────┐     │
│  │              Pod Network Namespace                │     │
│  │                                                  │     │
│  │  eth0@ifXX ──→ veth pair ──→ cilium_host        │     │
│  │              (Cilium eBPF 策略控制)              │     │
│  └─────────────────────────────────────────────────┘     │
└─────────────────────────────────────────────────────────┘
```

### 3.2 安装 Standalone 模式

```bash
# 使用 helm 安装（默认模式）
helm install cilium cilium/cilium \
    --namespace kube-system \
    --set kubeProxyReplacement=strict \
    --set ipam.mode=cluster-pool \
    --set tunnel=vxlan

# 验证 CNI 配置
cat /etc/cni/net.d/05-cilium.conflist
# 应该看到 Cilium 作为唯一的 CNI 插件
```

### 3.3 IPAM 模式

Cilium 支持多种 IPAM（IP Address Management）模式：

| 模式             | 说明                                               | 适用场景   |
| :--------------- | :------------------------------------------------- | :--------- |
| **cluster-pool** | 每个节点分配一个 CIDR 块，Pod IP 从节点 CIDR 分配  | 默认，简单 |
| **eni**          | AWS/GCP/Azure 云厂商 ENI 模式，Pod 使用弹性网卡 IP | 云环境     |
| **kubernetes**   | Kubernetes Node CIDR 模式                          | 兼容旧部署 |
| **static**       | 静态 IP 分配                                       | 特殊需求   |

```bash
# cluster-pool 模式配置
helm install cilium cilium/cilium \
    --namespace kube-system \
    --set ipam.mode=cluster-pool \
    --set ipam.operator.clusterPoolIPv4PodCIDR=10.244.0.0/16 \
    --set ipam.operator.clusterPoolIPv4MaskSize=24
```

### 3.4 Pod 网络创建流程

```
Kubelet 创建 Pod
    ↓
CNI ADD 调用（传入 container ID, network namespace）
    ↓
Cilium CNI 插件：
    ↓
    1. 从 IPAM 获取 Pod IP
    ↓
    2. 创建 veth pair（host 端 + container 端）
    ↓
    3. 将 container 端移到容器网络命名空间
    ↓
    4. 配置 IP 和路由
    ↓
    5. 调用 bpftool 加载 eBPF 程序到 veth
    ↓
    6. 在 cilium_endpoints Map 中注册 Endpoint
    ↓
    7. 向 Kubernetes API 注册 CiliumEndpoint 资源
    ↓
返回成功（包含 IP, MAC, 路由信息）
```

---

## 4. Chaining 模式

### 4.1 为什么需要 Chaining？

在现有集群中，已经有一个 CNI 插件运行。直接替换 Cilium 可能导致业务中断。Chaining 允许**叠加 Cilium 在现有 CNI 之上**：

```
传统部署：
  Kubelet → Flannel CNI → Pod（只有基本的二层/三层连通性）

Chaining 部署：
  Kubelet → Flannel CNI → Cilium CNI → Pod
                              ↑
                         提供 L3-L7 策略
                         Hubble 可观测性
                         eBPF 加速
```

### 4.2 支持的 Chaining 模式

| 底层 CNI           | Chaining 模式 | 说明                                            |
| :----------------- | :------------ | :---------------------------------------------- |
| **AWS VPC CNI**    | `aws-cni`     | Cilium 叠加在 AWS 原生 CNI 上                   |
| **GKE native CNI** | `gke`         | Cilium 叠加在 GKE 原生 CNI 上                   |
| **EKS CNI**        | `eks`         | Cilium 叠加在 EKS CNI 上                        |
| **Flannel**        | `flannel`     | Cilium 叠加在 Flannel 上                        |
| **Calico**         | `calico`      | Cilium 叠加在 Calico 上（需要禁用 Calico 策略） |

### 4.3 AWS VPC CNI Chaining

AWS EKS 默认使用 AWS VPC CNI，它为 Pod 分配 **ENI 上的弹性 IP**。Cilium 可以叠加其上：

```bash
# 安装 Cilium，叠加在 AWS VPC CNI 之上
helm install cilium cilium/cilium \
    --namespace kube-system \
    --set cni.chainingMode=aws-cni \
    --set cni.exclusive=false \
    --set kubeProxyReplacement=strict \
    --set ipam.mode=eni

# AWS VPC CNI 的 ENI 仍然负责 Pod IP 分配
# Cilium 接管：策略执行、可观测性、eBPF 加速
```

**架构变化**：

```
之前：AWS VPC CNI 直接管理 Pod 网络
之后：AWS VPC CNI → Cilium → Pod
```

### 4.4 Flannel Chaining

在已有 Flannel 的集群中添加 Cilium：

```bash
# 1. 确保 Flannel 已经安装并运行
kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml

# 2. 安装 Cilium（Flannel chaining 模式）
helm install cilium cilium/cilium \
    --namespace kube-system \
    --set cni.chainingMode=flannel \
    --set cni.flannel.unmanagedPodRecovery=false \
    --set flannel.masterDevice=cni0

# 3. 配置 Cilium 使用 Flannel 的网络
#    - Cilium 复用 Flannel 的 Pod CIDR
#    - Cilium 接管策略和可观测性
```

**Flannel Chaining 的限制**：

- Flannel 提供 L2 广播（ARP）和 VXLAN 隧道
- Cilium 提供 L3-L7 策略和 Hubble 观测
- 不支持 Cilium 的 ClusterIP eBPF 加速（因为 Pod IP 分配由 Flannel 控制）

---

## 5. 多网络接口（Multus + Cilium）

### 5.1 Multus CNI

Multus 允许 Pod 同时连接**多个网络接口**：

```bash
# 安装 Multus
kubectl apply -f https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/master/deployments/multus-daemonset.yml

# 创建 NetworkAttachmentDefinition
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: my-macvlan-net
spec:
  config: |
    {
      "cniVersion": "0.3.1",
      "name": "my-macvlan",
      "type": "macvlan",
      "master": "eth0",
      "mode": "bridge",
      "ipam": {
        "type": "host-local",
        "subnet": "10.1.0.0/16"
      }
    }
```

### 5.2 Cilium + Multus

Cilium 可以与 Multus 配合：

```yaml
# Pod 注解使用多个 CNI
apiVersion: v1
kind: Pod
metadata:
  annotations:
    k8s.v1.cni.cncf.io/networks: |
      [
        {"name": "cilium"},
        {"name": "my-macvlan-net"}
      ]
  name: multi-network-pod
spec:
  containers:
    - name: app
      image: nginx
```

**注意**：当使用 Multus 时，只有 `cilium` 命名的接口受 Cilium 策略保护。

---

## 6. CNI 配置详解

### 6.1 CNI 配置文件位置

CNI 配置文件位于 `/etc/cni/net.d/`：

```bash
# 查看 CNI 配置
ls -la /etc/cni/net.d/

# 典型配置（按文件名排序，第一个生效）
# 05-cilium.conflist  ← Cilium
# 10-flannel.conflist ← Flannel（如果使用 chaining）
```

### 6.2 Cilium CNI 配置参数

```json
{
  "cniVersion": "0.3.1",
  "name": "cilium",
  "type": "cilium-cni",
  "mtu": 1500,
  "enable-debug": false,
  "log-file": "/var/run/cilium/cilium-cni.log",
  "ipam": {
    "mode": "cluster-pool",
    "pool": {
      "ipv4": "10.244.0.0/16",
      "ipv6": "fd00::/64"
    },
    "mask-size": 24
  },
  "agent": "cilium-agent",
  "container-runtime-endpoint": ["/var/run/containerd/containerd.sock", "/var/run/cri-o.sock"],
  "polkit-enabled": false
}
```

### 6.3 常见配置选项

| 参数                         | 说明              | 默认值                              |
| :--------------------------- | :---------------- | :---------------------------------- |
| `mtu`                        | Pod 网络 MTU      | 1500                                |
| `ipam.mode`                  | IPAM 模式         | cluster-pool                        |
| `enable-debug`               | 启用调试日志      | false                               |
| `container-runtime-endpoint` | 容器运行时 socket | /var/run/containerd/containerd.sock |
| `log-file`                   | 日志文件路径      | /var/run/cilium/cilium-cni.log      |

---

## 7. 网络策略在 CNI 层生效

### 7.1 Endpoint 创建时的策略加载

```
CNI ADD 调用
    ↓
Cilium 分配 IP，注册 Endpoint
    ↓
Kubernetes NetworkPolicy 控制器
    ↓
将策略编译为 eBPF 字节码
    ↓
通过 bpftool 加载到 veth pair 的 TC Ingress Hook
    ↓
eBPF 程序生效：只有策略允许的流量可以通过
```

### 7.2 查看 Endpoint 状态

```bash
# 查看节点上的所有 Endpoint
kubectl -n kube-system exec ds/cilium -- cilium endpoint list

# 查看特定 Pod 的 Endpoint 详情
kubectl -n kube-system exec ds/cilium -- \
    cilium endpoint get 10.0.0.1

# 查看 Endpoint 的策略配置
kubectl -n kube-system exec ds/cilium -- \
    cilium endpoint policy 10.0.0.1
```

---

## 8. CNI 迁移指南

### 8.1 从 kube-router 迁移到 Cilium

```bash
# 1. 删除 kube-router（会清理 iptables 规则）
kubectl delete -f kube-router DaemonSet

# 2. 确保 kube-proxy 已移除
kubectl patch daemonset kube-proxy -n kube-system -p '{"spec":{"template":{"spec":{"nodeSelector":{"kubernetes.io/os":"linux"}}}}}'

# 3. 安装 Cilium
helm install cilium cilium/cilium \
    --namespace kube-system \
    --set kubeProxyReplacement=strict \
    --set cni.mode=standalone
```

### 8.2 从 Weave 迁移到 Cilium

```bash
# 1. 删除 Weave Net
kubectl delete -f weave-daemonset.yaml

# 2. 清理残留的 Weave 网络
 weave reset

# 3. 安装 Cilium
helm install cilium cilium/cilium \
    --namespace kube-system \
    --set kubeProxyReplacement=strict \
    --set cni.mode=standalone \
    --set tunnel=vxlan
```

---

## 9. 章节总结

| CNI 模式                      | 适用场景         | 特点                       |
| :---------------------------- | :--------------- | :------------------------- |
| **Standalone**                | 新部署，完全迁移 | Cilium 全功能，最高性能    |
| **Chaining (AWS/GKE/EKS)**    | 云厂商 CNI 集群  | 叠加 Cilium 策略和可观测性 |
| **Chaining (Flannel/Calico)** | 现有集群迁移     | 复用底层网络，叠加高级功能 |
| **Multus + Cilium**           | 多网络接口 Pod   | Cilium 作为主网络          |

**下一章预告**：Part II 网络功能——ClusterIP、NodePort、LoadBalancer 的深度解析与高级用法。

---

## 参考资料

- [Cilium CNI Documentation](https://docs.cilium.io/en/stable/concepts/networking/cni/)
- [Cilium Chaining Modes](https://docs.cilium.io/en/stable/gettingstarted/cni-chaining/)
- [CNI Specification](https://github.com/containernetworking/cni/blob/master/SPEC.md)
- [Cilium IPAM](https://docs.cilium.io/en/stable/concepts/networking/ipam/)
