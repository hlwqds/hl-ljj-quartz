---
title: "eBPF 深入理解：netkit、veth 与容器网络加速"
date: 2026-05-26
tags:
  - ebpf
  - netkit
  - veth
  - cilium
  - container-networking
  - kubernetes
description: "从容器流量路径理解 netkit、veth fast redirect、Cilium eBPF 数据面，以及它们和 DPDK/vhost-user 的边界"
---

# eBPF 深入理解：netkit、veth 与容器网络加速

> [!abstract] 核心要点
> netkit 不是“另一个 DPDK”，而是 Linux 内核里的 BPF 可编程虚拟网卡。
> 它解决的是普通容器网络里 veth/netns 切换和 Host 网络栈路径过长的问题。
> 不过，veth 后来也通过 `bpf_redirect_peer()` 等能力补上了很多 fast redirect
> 能力，所以今天更准确的理解是：**veth 和 netkit 都可以走 eBPF 快路径；
> netkit 是更面向 Cilium/BPF 数据面的新设备模型。**

## 1. 这是什么商业场景

netkit 这类技术面向的是大规模 Kubernetes 集群里的 **通用容器网络加速**。

它不是为 5G UPF、防火墙、虚拟路由器这类极端 packet processor 设计的；那类场景
通常会走 DPDK、SR-IOV、AF_XDP、vhost-user 或 memif。

netkit/veth fast redirect 的典型目标是：

```text
普通 Pod 仍然使用 socket
普通应用不改代码
Kubernetes 语义仍然保留
NetworkPolicy / Service / 可观测性仍然可用
同节点 Pod-to-Pod 和 Pod-to-Host 路径更短
```

所以它解决的是：

```text
如何让通用容器网络接近 Host namespace 的性能，
但又不牺牲 Kubernetes 的网络模型。
```

## 2. 传统 veth 路径的问题

普通 Kubernetes Pod 最常见的是 veth pair：

```text
Pod A App
  -> socket
  -> Pod A TCP/IP stack
  -> Pod A eth0
  -> veth peer
  -> Host namespace
  -> bridge / routing / OVS / tc / netfilter
  -> peer veth
  -> Pod B eth0
  -> Pod B TCP/IP stack
  -> Pod B App
```

这个路径的好处是通用、稳定、可观测，所有 Linux 网络工具都能理解。

问题是中间模块很多：

```text
Pod netns
veth pair
Host netns
qdisc
tc
netfilter
routing
bridge/OVS
peer veth
peer Pod netns
```

对于普通业务，这个成本可以接受。对于大规模高 QPS 服务，尤其同节点 Pod-to-Pod，
这部分开销会变成明显的 CPU 成本和尾延迟来源。

## 3. veth 后来的快路径：bpf_redirect_peer

早期理解里，veth 只是“虚拟网线”。但今天的 veth 已经可以配合 eBPF 做 fast
redirect。

关键能力是：

```text
bpf_redirect_peer()
```

它的作用是：在 TC ingress BPF 程序里，把 skb 直接 redirect 到 peer 设备所在的
network namespace 的 ingress 路径。

简化后，路径从：

```text
veth ingress
  -> Host backlog / routing / upper stack
  -> peer device
```

变成：

```text
veth ingress
  -> BPF policy / lookup
  -> bpf_redirect_peer()
  -> peer ingress
```

这就是你说的“veth 也扩展出了类似 netkit 的能力”的核心。

更准确地说：

```text
veth + TC BPF + bpf_redirect_peer()
```

已经能把很多同节点容器转发路径缩短，不再必须把包完整推到 Host 协议栈里再转发。

## 4. netkit 做了什么

netkit 是 Linux 里的 BPF-programmable network device。它被设计出来，就是为了让
容器网络设备更贴近 eBPF 数据面。

从使用者视角看，它替代的是：

```text
Pod eth0 <-> veth peer
```

变成：

```text
Pod netkit peer <-> Host netkit peer
```

和普通 veth 的区别不应该理解成“netkit 会魔法零成本转发”，而应该理解成：

```text
netkit 把容器虚拟网卡这件事做成 BPF-first 的模型。
```

典型路径是：

```text
Pod App
  -> socket
  -> Pod TCP/IP stack
  -> netkit peer
  -> BPF program
  -> redirect / policy / routing decision
  -> peer Pod / Host / NIC
```

netkit 重要的设计点：

- 面向 BPF 数据面，而不是先走传统 veth 再外挂 BPF。
- Pod 侧程序由 Host 侧管理，避免容器内进程随便修改关键 BPF 程序。
- 可以和 tcx、Cilium eBPF host routing 等能力配合。
- 对 Cilium 这类 CNI 来说，它让“Pod 虚拟网卡 + BPF 策略 + redirect”成为更一致的模型。

## 5. veth fast redirect 和 netkit 的关系

今天不能简单说：

```text
veth 慢，netkit 快
```

更准确是：

```text
传统 veth:
  路径长，经过更多 Host 网络栈模块

veth + BPF fast redirect:
  已经能绕过很多 Host 网络栈路径

netkit:
  更面向 BPF/Cilium 的虚拟网卡模型，把 fast path 作为一等能力
```

对比：

| 维度         | veth + BPF redirect             | netkit                             |
| ------------ | ------------------------------- | ---------------------------------- |
| 基础模型     | 传统 veth pair 上挂 BPF         | BPF-first 虚拟网卡                 |
| 生态成熟度   | 很成熟，Linux/CNI 工具链熟悉    | 较新，主要跟 Cilium 等新数据面结合 |
| 快路径能力   | 支持 `bpf_redirect_peer()`      | 以 BPF redirect/policy 为核心      |
| 运维可理解性 | 高，`ip link`/tc/bpftool 都熟悉 | 需要理解 netkit/tcx/Cilium 模式    |
| 目标         | 在现有 veth 模型上加速          | 用新设备模型减少容器网络开销       |

所以，如果你的观点是“veth 现在也能做到很多 netkit 目标”，这是对的。

netkit 的价值不在于“veth 完全做不到”，而在于：

```text
把容器网络设备模型从 veth-first 推向 BPF-first。
```

## 6. 同节点 Pod-to-Pod 流量路径

### 6.1 传统 veth

```text
Pod A App
  -> Pod A kernel
  -> eth0
  -> veth peer
  -> Host bridge/routing/netfilter
  -> peer veth
  -> Pod B eth0
  -> Pod B kernel
  -> Pod B App
```

### 6.2 veth + BPF redirect

```text
Pod A App
  -> Pod A kernel
  -> eth0 / veth
  -> TC ingress BPF
  -> policy / service / endpoint lookup
  -> bpf_redirect_peer()
  -> Pod B peer ingress
  -> Pod B kernel
  -> Pod B App
```

这里还在 Linux socket 和 skb 体系里，但 Host 中间路径明显缩短。

### 6.3 netkit

```text
Pod A App
  -> Pod A kernel
  -> netkit device
  -> BPF program
  -> redirect to peer / Host / NIC
  -> Pod B netkit device
  -> Pod B kernel
  -> Pod B App
```

netkit 仍然服务普通 socket 应用，不要求应用改成 DPDK。

## 7. 和 DPDK/vhost-user 的边界

netkit/veth fast redirect 属于 **内核网络栈内加速**：

```text
App
  -> socket
  -> Linux TCP/IP
  -> skb
  -> BPF redirect
```

DPDK/vhost-user 属于 **绕过内核网络栈**：

```text
DPDK/VPP app
  -> mbuf / userspace ring
  -> vhost-user / memif / PMD
```

所以选型应该是：

| 场景                                                | 推荐                        |
| --------------------------------------------------- | --------------------------- |
| 普通微服务 Pod-to-Pod                               | veth + eBPF 或 netkit       |
| 希望少改应用，同时提升容器网络性能                  | Cilium eBPF 数据面 / netkit |
| 要 Kubernetes Service、NetworkPolicy、Hubble 可观测 | eBPF 数据面                 |
| 5G UPF、防火墙、LB、NAT、网关                       | DPDK/VPP/SR-IOV             |
| 极限 PPS、极限尾延迟                                | DPDK 或 SR-IOV              |

一句话：

```text
netkit/veth fast redirect 是把通用容器网络做快；
DPDK 是把容器变成专用网络设备。
```

## 8. 读代码时应该抓哪些点

如果后续要深入内核实现，建议按这个顺序看：

```text
1. veth 的 xmit / peer 交付逻辑
2. TC ingress BPF 执行点
3. bpf_redirect_peer() 如何切换到 peer ingress
4. netkit device 的 xmit / receive / BPF attach 逻辑
5. Cilium 如何在 endpoint 上加载 BPF 程序
6. tcx 如何替代传统 clsact/tc attach 的一部分管理复杂度
```

最关键的不是背 API，而是把每个包经过的模块画出来：

```text
skb 在哪里创建？
BPF 在哪个 hook 执行？
redirect 目标是哪个 net_device？
是否跨 network namespace？
是否进入 Host routing/netfilter？
是否还能执行 NetworkPolicy？
```

这些问题回答清楚，veth、netkit、Cilium、DPDK 的边界就清楚了。

## 9. 总结

netkit 和 veth 的关系可以这样记：

```text
veth:
  Linux 容器网络的传统虚拟网卡。

veth + BPF redirect:
  传统虚拟网卡上叠加 eBPF 快路径。

netkit:
  为 BPF 数据面重新设计的容器虚拟网卡模型。
```

所以今天讨论 netkit 时，不能只说“它比 veth 快”。更准确的说法是：

```text
veth 已经通过 BPF redirect 获得了很多快路径能力；
netkit 则把这些能力产品化成更适合 Cilium/eBPF 的设备模型。
```

---

## 参考资源

- [Cilium Performance Tuning: netkit device mode](https://docs.cilium.io/en/stable/operations/performance/tuning/)
- [eBPF helper: bpf_redirect_peer](https://docs.ebpf.io/linux/helper-function/bpf_redirect_peer/)
- [Cilium 1.9: eBPF host routing and redirect helpers](https://cilium.io/blog/2020/11/10/cilium-19/)
- [LWN: The BPF-programmable network device](https://lwn.net/Articles/952610/)
- [Isovalent: Cilium netkit](https://isovalent.com/blog/post/cilium-netkit-a-new-container-networking-paradigm-for-the-ai-era/)
