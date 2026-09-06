---
title: "Cilium 深度探索 (23)：CNI Chaining 多 CNI 协同"
date: 2026-04-14
tags:
  - cilium
  - ebpf
  - kubernetes
  - cni
  - chaining
  - flannel
  - calico
  - networking
  - cloud-native
---

> [!info] Cilium 2026 深度探索系列 0. [[cilium-deep-dive|系列索引]]
> ... 21. [[ch21-cluster-mesh|第二十一章：Cluster Mesh]] 22. [[ch22-global-services|第二十二章：Global Services]] 23. **第二十三章：CNI Chaining** ←

---

## 1. 背景：CNI 协同的需求

在实际生产环境中，完全替换现有 CNI 往往是一个高风险操作。企业可能面临：

- **存量集群**：现有集群已经运行着 Flannel/Calico/Weave 等 CNI
- **团队知识**：运维团队对这些 CNI 有丰富经验
- **特定功能**：某些 CNI 有独特的底层网络能力
- **迁移风险**：一次性替换可能导致业务中断

Cilium 的 **CNI Chaining（链式）模式** 允许 Cilium 与现有 CNI 共存，既保留原有 CNI 的网络功能，又叠加 Cilium 的高级能力（eBPF 加速、Hubble 观测、L7 策略等）。

---

## 2. CNI Chaining 架构

### 2.1 链式模式原理

```
传统模式（Standalone）：
  kubelet → Cilium CNI → 直接创建网络接口

链式模式（Chaining）：
  kubelet → 主机 CNI（如 Flannel）→ Cilium CNI（附加策略/观测）
```

CNI Chaining 的核心思想：

1. **主机 CNI 负责基础网络**：IP 分配、Veth Pair 创建、路由设置
2. **Cilium 在上层附加功能**：eBPF 策略、加速、加密、观测
3. **分工明确**：每个 CNI 做自己最擅长的事

### 2.2 支持的链式 CNI

Cilium 支持与以下 CNI 链式配合：

| CNI         | 模式      | 说明                                     |
| :---------- | :-------- | :--------------------------------------- |
| **Flannel** | `flannel` | 经典的 Overlay 网络，与 Cilium eBPF 叠加 |
| **Calico**  | `calico`  | 路由 + 网络策略，与 Cilium 策略叠加      |
| **Weave**   | `weave`   | 网格网络，与 Cilium 观测叠加             |
| **Generic** | `generic` | 通用链式，支持任意 CNI                   |

---

## 3. Flannel + Cilium 链式

### 3.1 架构

```
┌─────────────────────────────────────────────────────────────────┐
│           Flannel (基础网络) + Cilium (eBPF 增强)                 │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Flannel (Backend: VXLAN)                                        │
│      │                                                          │
│      ├── 分配 Pod IP (10.244.0.0/16)                             │
│      ├── 创建 Veth Pair (主机端)                                 │
│      └── 管理 VXLAN 隧道 (10.244.x.x → Node IP)                  │
│                                                                  │
│  Cilium (eBPF 增强层)                                            │
│      │                                                          │
│      ├── eBPF Service 映射 (替代 kube-proxy)                     │
│      ├── eBPF NetworkPolicy (L3/L4/L7)                         │
│      ├── Hubble 流量观测                                        │
│      └── Bandwidth Manager (限速)                               │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### 3.2 部署步骤

**前置条件：已有 Flannel 集群**

```bash
# 1. 已有 Flannel 集群（无需修改）
kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml

# 2. 安装 Cilium（链式模式）
helm install cilium cilium/cilium \
    --namespace kube-system \
    --set cni.chainingMode=flannel \
    --set cni.exclusive=false \
    --set kubeProxyReplacement=partial \
    --set ebpF.enabled=true
```

### 3.3 工作原理

Flannel 负责基础网络，Cilium 在此基础上通过 eBPF 添加增强：

```bash
# 查看 Cilium 管理的接口
kubectl -n kube-system exec ds/cilium -- cilium bpf endpoint list

# 输出示例
ENDPOINT ID   ADDRESS        INTERFACE         STATUS
54321         10.244.1.15    lxc_54321          ready
```

关键点：

1. **Flannel 创建接口**：`flannel.1` (VXLAN) 或 `cni0` (bridge)
2. **Cilium 接管接口**：Cilium Agent 将 eBPF 程序附加到这些接口
3. **职责分离**：
   - Flannel：IP 分配、基础路由、ARP/NDP
   - Cilium：Service 负载均衡、策略、观测

---

## 4. Calico + Cilium 链式

### 4.1 架构

```
┌─────────────────────────────────────────────────────────────────┐
│           Calico (基础网络+路由) + Cilium (策略+观测)              │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Calico (BGP 路由)                                               │
│      │                                                          │
│      ├── Felix 分配 IP (192.168.0.0/16)                        │
│      ├── Bird BGP daemon 广播路由                               │
│      └── IPIP / VXLAN 隧道（跨节点）                             │
│                                                                  │
│  Cilium (eBPF 增强)                                             │
│      │                                                          │
│      ├── eBPF Service (L4 负载均衡)                             │
│      ├── Hubble (L7 Flow 可视化)                               │
│      └── Transparent Encryption (WireGuard)                     │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### 4.2 部署步骤

```bash
# 1. 安装 Calico（默认模式）
kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml

# 2. 修改 Calico Felix 配置（禁用部分功能）
kubectl patch felixconfiguration default --type merge -p '
{
  "spec": {
    "featureDetectOverride": "Checked",
    "policySyncPathPrefix": "/var/run/calico/felix/status"
  }
}'

# 3. 安装 Cilium（Calico 链式）
helm install cilium cilium/cilium \
    --namespace kube-system \
    --set cni.chainingMode=calico \
    --set cni.exclusive=false \
    --set kubeProxyReplacement=partial \
    --set ebpF.enabled=true \
    --set enableHubble=true
```

### 4.3 兼容性矩阵

| 功能             | Calico             | Cilium Chaining    | 说明            |
| :--------------- | :----------------- | :----------------- | :-------------- |
| Pod IP 分配      | ✓ Calico           | -                  | Calico IPAM     |
| 基础路由         | ✓ Calico BGP       | -                  | Bird BGP        |
| L3 NetworkPolicy | ✓ Calico           | ✓ Cilium           | 两者叠加        |
| L4 Service LB    | -                  | ✓ Cilium eBPF      | 替代 kube-proxy |
| L7 策略          | -                  | ✓ Cilium           | HTTP/gRPC 策略  |
| Hubble 观测      | -                  | ✓ Cilium           | Flow 可视化     |
| 加密             | ✓ Calico WireGuard | ✓ Cilium WireGuard | 可叠加          |

---

## 5. Generic Chaining 模式

### 5.1 通用链式原理

Generic Chaining 允许 Cilium 与**任意符合 CNI SPEC 的实现**配合工作：

```
kubelet
    │
    ▼
主机 CNI (如 AWS CNI, Azure CNI, etc.)
    │
    ▼
Cilium Agent (通过 CNI chaining API 接入)
    │
    ▼
Pod 网络接口
```

### 5.2 实现机制

Cilium 通过 **CNI chaining API** 与主机 CNI 交互：

```bash
# 1. Cilium Agent 监听 /opt/cni/bin/cilium-cni
# 2. kubelet 调用主机 CNI（如 aws-cni）
# 3. 主机 CNI 调用 Cilium CNI（通过 chain 机制）
# 4. Cilium 附加 eBPF 程序到接口
```

### 5.3 AWS VPC CNI + Cilium 示例

```bash
# 1. 安装 AWS VPC CNI
kubectl apply -f https://raw.githubusercontent.com/aws/amazon-vpc-cni-k8s/master/config/master/aws-k8s-cni.yaml

# 2. 安装 Cilium（通用链式）
helm install cilium cilium/cilium \
    --namespace kube-system \
    --set cni.chainingMode=generic-veth \
    --set cni.exclusive=false \
    --set containerRuntime.integration=cri \
    --set kubeProxyReplacement=partial
```

---

## 6. 链式模式下的 eBPF 功能

### 6.1 覆盖范围

在链式模式下，Cilium 的 eBPF 功能会有部分限制：

| 功能                | Standalone | Chaining | 说明                   |
| :------------------ | :--------- | :------- | :--------------------- |
| eBPF Service (LB)   | ✓ 完全     | ✓ 部分   | 依赖主机 CNI 的接口    |
| eBPF Host Routing   | ✓ 完全     | ✗        | 需要直接控制网络栈     |
| L4 负载均衡         | ✓ 完全     | ✓        | via eBPF Service Map   |
| L3/L4 NetworkPolicy | ✓ 完全     | ✓        | via eBPF XDP/TC        |
| L7 策略 (HTTP)      | ✓ 完全     | ✓        | via Envoy integration  |
| Hubble 观测         | ✓ 完全     | ✓        | 全流量捕获             |
| Bandwidth Manager   | ✓ 完全     | ✗        | 需要 eBPF host routing |

### 6.2 eBPF 程序附加点

即使在链式模式下，Cilium 仍然可以将 eBPF 程序附加到多个钩子：

```bash
# 查看附加的 eBPF 程序
kubectl -n kube-system exec ds/cilium -- cilium bpf prog list

# 输出示例
TYPE         HANDLE  PROGRAM
tc_ingress   1       bpf_overlay.o:[classifier]
tc_egress    2       bpf_overlay.o:[to-overlay]
xdp          3       bpf_lb.o:[tail_call_ipv4_service]
```

附加点说明：

| 钩子           | 说明                                 |
| :------------- | :----------------------------------- |
| **TC Ingress** | 入向流量分类、策略检查、Service 映射 |
| **TC Egress**  | 出向流量 NAT、策略检查               |
| **XDP**        | 最早可编程点，用于包丢弃/重定向      |

---

## 7. 迁移策略

### 7.1 从 Standalone 迁移到链式

如果当前使用 Cilium Standalone，想要切换到链式模式：

```bash
# 1. 备份当前配置
kubectl get cm -n kube-system cilium-config -o yaml > cilium-config-backup.yaml

# 2. 链式模式安装
helm upgrade cilium cilium/cilium \
    --namespace kube-system \
    --reuse-values \
    --set cni.chainingMode=flannel \
    --set cni.exclusive=false

# 3. 重启 Cilium Agent（滚动更新）
kubectl rollout restart daemonset/cilium -n kube-system

# 4. 验证
kubectl -n kube-system exec ds/cilium -- cilium status
```

### 7.2 从主机 CNI 迁移到 Cilium Standalone

完全迁移到 Cilium Standalone：

```bash
# 1. 确保 Cilium Standalone 已安装
helm install cilium cilium/cilium \
    --namespace kube-system \
    --set cni.exclusive=true \
    --set kubeProxyReplacement=strict

# 2. 禁用主机 CNI
kubectl delete -f <host-cni-manifest>.yaml

# 3. 清理残留网络配置
cilium-cli connectivity diagnose --az

# 4. 验证网络连通性
kubectl run --rm -it debug --image=busybox -- /bin/sh
```

---

## 8. 章节总结

| 概念                    | 说明                             |
| :---------------------- | :------------------------------- |
| **CNI Chaining**        | Cilium 与主机 CNI 协同工作的模式 |
| **Flannel + Cilium**    | Overlay 网络 + eBPF 增强         |
| **Calico + Cilium**     | BGP 路由 + Cilium 策略/观测      |
| **Generic Chaining**    | 通用模式，支持任意 CNI           |
| **cni.exclusive=false** | 允许 Cilium 与其他 CNI 共存      |

**下一章**：深入讲解 IPAM（IP Address Management），了解 Pod IP 分配策略和 CIDR 管理。

---

## 参考资料

- [Cilium CNI Chaining Documentation](https://docs.cilium.io/en/stable/network/cni-chaining/)
- [Cilium Flannel Chaining](https://docs.cilium.io/en/stable/network/cni-chaining/flannel/)
- [Cilium Calico Chaining](https://docs.cilium.io/en/stable/network/cni-chaining/calico/)
