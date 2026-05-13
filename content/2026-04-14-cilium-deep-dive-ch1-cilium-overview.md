---
title: "Cilium 深度探索 (1)：Cilium 概述"
date: 2026-04-14
tags:
  - cilium
  - ebpf
  - kubernetes
  - cni
  - networking
  - cloud-native
---

> [!info] Cilium 2026 深度探索系列
> 0. [[2026-04-14-cilium-deep-dive-series-index|系列索引]]
> 1. **第一章：Cilium 概述** ←
> 2. [[2026-04-14-cilium-deep-dive-ch2-architecture|第二章：Cilium 架构]]
> 3. [[2026-04-14-cilium-deep-dive-ch3-ebpf-datapath|第三章：eBPF 数据面]]
> 4. [[2026-04-14-cilium-deep-dive-ch4-kube-proxy|第四章：Kube-Proxy 替代]]
> 5. [[2026-04-14-cilium-deep-dive-ch5-cni|第五章：CNI 集成]]

---

## 1. 背景：为什么需要 Cilium？

Kubernetes 网络的核心挑战是：**如何在不给内核增加负担的情况下，以云原生的方式安全、高效地连接 Pod？**

传统方案（如 kube-proxy + iptables/nftables）存在以下根本性缺陷：

| 维度 | kube-proxy + iptables | Cilium |
|:---|:---|:---|
| **复杂度** | O(n) 规则遍历 | O(1) 哈希查找 |
| **延迟** | 每次转发数十条 iptables 链 | 直接 eBPF 映射查找 |
| **扩展性** | 节点 >1000 Service 时性能急剧下降 | 线性扩展，支持百万级 Endpoint |
| **可观测性** | 无原生 Flow 日志 | Hubble 原生 L7 Flow 可视化 |
| **策略粒度** | L3/L4 | 可到 L7（HTTP/gRPC/Kafka） |
| **加密** | 依赖外部方案 | 原生 WireGuard/IPsec |

Cilium 诞生于 2016 年，由 Google 工程师 Thomas Graf 创立，2019 年进入 CNCF 孵化项目，2021 年毕业为 CNCF 顶级项目。其核心创新是：**用 eBPF（Extended Berkeley Packet Filter）重新实现 Kubernetes 网络的所有功能**，绕过 iptables，在内核中实现高性能、可编程的数据面。

---

## 2. eBPF： Cilium 的技术基石

eBPF 允许在 Linux 内核中运行沙箱化的字节码程序，无需修改内核源码或加载内核模块。与传统 iptables 规则不同，eBPF 程序在数据包到达时**直接在内核中执行**，绕过了 Netfilter 的规则链遍历。

```
传统路径（iptables）：
  Packet → Netfilter (PREROUTING) → iptables (nat table) → iptables (filter table) 
         → ... 数十条规则遍历 ... → Routing Decision → Netfilter (POSTROUTING)

Cilium 路径（eBPF）：
  Packet → XDP Hook（最早可编程点）→ eBPF Map（O(1) 查找）→ 直接转发
```

eBPF 的核心优势：

1. **内核态执行**：数据平面在内核空间运行，无用户态/内核态切换开销
2. **程序验证**：Verifier 确保程序不会崩溃内核或无限循环
3. **即时编译**：JIT 编译器将字节码转为本地机器码，接近原生性能
4. **热更新**：无需重启内核或中断连接即可更新策略
5. **Map 机制**：键值对存储用于程序间共享状态和计数

---

## 3. Cilium 解决了哪些问题？

### 3.1 替代 kube-proxy

kube-proxy 依赖 iptables 或 IPVS 实现 Service 负载均衡。当集群规模增长时：

- iptables 规则数量 = O(n × m)，n 是节点数，m 是 Service 数
- 1000 个 Service × 10000 个 Pod = 规则爆炸
- 更新一条规则可能需要遍历整条链

Cilium 用 **eBPF Service 映射**替代 iptables，查找复杂度降为 O(1)。

### 3.2 替代传统 CNI

传统 CNI（如 Flannel、Calico）只负责 IP 分配和连通性。Cilium 额外提供：

- **网络策略**：L3/L4/L7 细粒度安全策略
- **加密传输**：WireGuard/IPsec 透明加密
- **带宽管理**：基于 eBPF 的限速
- **可观测性**：Hubble 实时流量可视化

### 3.3 服务网格（无需 Sidecar）

传统 Service Mesh（Istio/Linkerd）需要 Sidecar 代理（Envoy）拦截所有流量。Cilium Ambient Mode 通过 **Waypoint Proxy** 实现 L4/L7 策略，无需 Sidecar：

```
传统 Sidecar 模式：
  Pod → Sidecar（Envoy）→ 策略检查 → 实际服务
  
Cilium Ambient 模式：
  Pod → Waypoint Proxy（per-namespace）→ 策略检查 → 实际服务
```

Sidecar 模式下，每个 Pod 都需要一个 Envoy 容器；Ambient 模式下，一个 Namespace 只需要一个 Waypoint Proxy，大幅降低资源开销。

---

## 4. Cilium 的核心组件

```
┌─────────────────────────────────────────────────────────────┐
│                        Kubernetes Cluster                   │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │                     Cilium Agent                       │   │
│  │  (DaemonSet，每个节点一个)                              │   │
│  │                                                        │   │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  │   │
│  │  │ eBPF Data   │  │  Policy     │  │   Hubble    │  │   │
│  │  │ Plane       │  │  Engine     │  │   Relay     │  │   │
│  │  │ (TC/XDP)    │  │             │  │             │  │   │
│  │  └─────────────┘  └─────────────┘  └─────────────┘  │   │
│  └──────────────────────────────────────────────────────┘   │
│                           ↕                                  │
│  ┌──────────────────────────────────────────────────────┐   │
│  │               eBPF Programs (attached to)             │   │
│  │                                                        │   │
│  │  TC (Traffic Control) Hook ──── 包分类、转发、策略     │   │
│  │  XDP (Express Data Path) ───── 最早可编程点           │   │
│  │  socket/connect ────────────── 进程级别策略           │   │
│  │  sk_lookup ─────────────────── Service 查找           │   │
│  └──────────────────────────────────────────────────────┘   │
│                           ↕                                  │
│  ┌──────────────────────────────────────────────────────┐   │
│  │               eBPF Maps (shared state)               │   │
│  │                                                        │   │
│  │  cilium_node_addresses  │  cilium_policy (L4/L7)      │   │
│  │  cilium_services        │  cilium_eps (endpoints)     │   │
│  │  cilium_ipcache         │  cilium_tunnel_map         │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                              │
│  ┌─────────────────┐     ┌─────────────────┐               │
│  │   etcd/kvstore  │     │  Kubernetes API │               │
│  │  (集群状态存储)   │     │   (元数据读取)    │               │
│  └─────────────────┘     └─────────────────┘               │
└─────────────────────────────────────────────────────────────┘
```

---

## 5. 核心概念速览

### 5.1 CiliumEndpoint (CEP)

每个 Pod 在 Cilium 中对应一个 CiliumEndpoint，包含该 Pod 的：

- IP 地址（IPv4/IPv6）
- MAC 地址
- 安全策略
- 所属 Identity（身份）

### 5.2 Identity（身份）

Cilium 不基于 IP 做策略，而是基于**身份（Identity）**。当 Pod 启动时，Cilium 为其分配一个 Security Identity，格式为 `namespace:serviceaccountname`。即使 Pod IP 变化，身份保持不变，策略持续有效。

### 5.3 eBPF Datapath（数据路径）

Cilium 的数据面完全基于 eBPF：

```
宿主机收到包
    ↓
XDP（最早可编程点）—— 极早期处理，可直接丢弃或重定向
    ↓
TC（Traffic Control）Ingress —— 包分类、策略检查、Service 查找
    ↓
Socket 劫持（connect/bind）—— 进程级别策略和透明加速
    ↓
TC Egress —— 出向策略检查、NAT
    ↓
宿主机发出包
```

---

## 6. 快速入门：单节点体验

```bash
# 1. 通过 helm 安装 Cilium（默认替换 kube-proxy）
helm install cilium cilium/cilium \
    --namespace kube-system \
    --set kubeProxyReplacement=strict \
    --set ebpF.loadBalancer.mode=hybrid

# 2. 检查 Agent 状态
kubectl get pods -n kube-system -l k8s-app=cilium
kubectl -n kube-system exec ds/cilium -- cilium status

# 3. 查看节点上的 eBPF 程序
kubectl -n kube-system exec ds/cilium -- cilium bpf endpoint list

# 4. 启用 Hubble（可观测性）
helm upgrade cilium cilium/cilium \
    --namespace kube-system \
    --set hubble.enabled=true \
    --set hubble.relay.enabled=true \
    --set hubble.ui.enabled=true

# 5. 通过 Hubble CLI 查看实时流量
cilium hubble ui &
```

---

## 7. 章节总结

本章介绍了 Cilium 的诞生背景和核心价值：

| 概念 | 说明 |
|:---|:---|
| **eBPF** | Cilium 的技术基石，内核中运行的安全沙箱程序 |
| **Identity** | 基于标签的身份，替代 IP 作为策略主体 |
| **kube-proxy 替代** | eBPF Service 映射，O(1) 查找替代 iptables O(n) 遍历 |
| **Hubble** | Cilium 内置的可观测性平台，L3-L7 Flow 可视化 |
| **Ambient Mode** | 无 Sidecar 的 Service Mesh，大幅降低资源开销 |

**下一章**：深入 Cilium 架构，理解 CCN/CNCM/eBPF Datapath/控制面的设计与协作。

---

## 参考资料

- [Cilium Official Documentation](https://docs.cilium.io/)
- [Cilium GitHub Repository](https://github.com/cilium/cilium)
- [eBPF.io - What is eBPF](https://ebpf.io/)
- Thomas Graf's Cilium Introduction (CNCF Blog)
