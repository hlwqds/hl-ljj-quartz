---
title: "内核透视：OVS 与 eBPF 路径下的身份打标与封装"
date: 2026-03-11
tags: [ebpf, ovs, skb, kernel, networking]
---

> [!abstract] 软件定义安全边界 (SDP) 深度系列
>
> 1. **[[2026-03-11-sdp-zero-trust-overview|1. 概论篇：SDP 与零信任的范式转移]]**
> 2. **[[2026-03-11-sdp-cloud-infrastructure-security|2. 基础设施篇：云底座的租户隔离与流量劫持]]**
> 3. **[[2026-03-11-sdp-kernel-path-deep-dive|3. 内核深度篇：OVS 与 eBPF 的路径博弈 (当前文章)]]**
> 4. **[[2026-03-11-sdp-application-identity-mtls|4. 应用身份篇：SPIFFE 与透明加密实施]]**
> 5. **[[2026-03-11-sdp-advanced-threat-defense|5. 防御进阶篇：应对容器逃逸与底座沦陷]]**

## 1. 深入内核：封装全路径对比

### 1.1 OVS 传统流表路径 (Heavyweight)

- **OVS Datapath**：执行基于 OpenFlow 的多级哈希匹配。
- **即时封装 (Immediate Encap)**：数据包在离开 OVS 模块进入 IP 栈前，就已经完成了内存重新分配与头部物理拷贝。在高并发下容易触发 `skb_cow` 导致的性能抖动。

### 1.2 eBPF 现代元数据路径 (Lightweight)

- **TC Egress Hook**：利用 BPF Map 瞬间完成 TID 识别。
- **延迟封装 (Delayed Encap)**：通过 `bpf_skb_set_tunnel_key` 设置内核内部元数据 `ip_tunnel_info`。
- **价值**：数据包在大部分内核路径中保持原始大小，仅在驱动发出前一步由隧道设备完成包头拼凑，极大地优化了内存开销。

## 2. skb 在不同路径下的变形全过程 (ASCII)

### 2.1 eBPF 路径变迁

```text
阶段 1: 租户发出 [ Ethernet | IP | Payload ] (skb->mark = 0)
阶段 2: TC Ingress -> skb->mark = 0x64 (身份注入)
阶段 3: TC Egress -> skb->_skb_refdst = [ VNI:100, Dst:1.1.1.1 ] (标记隧道)
阶段 4: 驱动封装 -> [ Outer_UDP | VXLAN | Inner_Packet ] (物理封装)
```

### 2.2 OVS 路径变迁

```text
阶段 1: OVS DP -> skb->cb[OVS_CB] = [ tun_id: 100 ] (存储在控制块)
阶段 2: Vport -> [ Outer_UDP | VXLAN | Inner_Packet ] (即时头部拷贝)
```

## 3. 拦截策略与全栈可观测性

- **身份标识**：eBPF 使用标准的 `skb->mark`；OVS 依赖私有结构体，导致 [[2026-03-08-deepflow-detailed-analysis-report|DeepFlow 可观测性]] 在 OVS 下读取难度更高。
- **执行效率**：eBPF 配合 **[[2025-12-16-dpdk-tx-offload-mbuf-fast-free|DPDK]]** 旁路技术，可支撑 100G 级别的安全过滤。

---

## 外部参考

- [Linux Kernel sk_buff 结构分析](https://elixir.bootlin.com/linux/latest/source/include/linux/skbuff.h)
