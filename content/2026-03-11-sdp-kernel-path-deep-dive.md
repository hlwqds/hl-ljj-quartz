---
title: "内核透视：OVS 与 eBPF 路径下的身份打标与封装"
date: 2026-03-11
tags: [ebpf, ovs, skb, kernel, networking]
---

> [!abstract] 软件定义安全边界 (SDP) 深度系列
> 1. **[[2026-03-11-sdp-zero-trust-overview|1. 概论篇：SDP 与零信任的范式转移]]**
> 2. **[[2026-03-11-sdp-cloud-infrastructure-security|2. 基础设施篇：云底座的租户隔离与流量劫持]]**
> 3. **[[2026-03-11-sdp-kernel-path-deep-dive|3. 内核深度篇：OVS 与 eBPF 的路径博弈 (当前文章)]]**
> 4. **[[2026-03-11-sdp-application-identity-mtls|4. 应用身份篇：SPIFFE 与透明加密实施]]**
> 5. **[[2026-03-11-sdp-advanced-threat-defense|5. 防御进阶篇：应对容器逃逸与底座沦陷]]**

## 1. 深度透视：skb 在内核中的数据演变 (ASCII 版)

理解身份证明的物理实现，需要观察内核核心数据结构 `sk_buff` (skb) 在关键环节的字段变化。

### 1.1 eBPF 路径 (Lightweight)
```text
阶段 1: 租户发出 (Untagged)
[ Ethernet | IP | Payload ] 
   | 
   +--> skb->mark = 0
   +--> skb->data = Ethernet Header

阶段 2: 宿主机 TC Ingress (身份注入)
   +-- [ BPF 逻辑: TID = MapLookup(ifindex) ]
   +--> skb->mark = 0x64 (TID: 100)  <-- 【身份戳已盖】

阶段 3: 隧道准备 (Metadata Binding)
   +-- [ BPF 逻辑: bpf_skb_set_tunnel_key(VNI=skb->mark) ]
   +--> skb->_skb_refdst -> [ ip_tunnel_info ] <-- 【挂载隧道说明书】

阶段 4: 物理驱动 (延迟封装)
[ Outer_IP | UDP | VXLAN(VNI:100) | Ethernet | IP | Payload ]
   +--> skb->len += 50 Bytes
```

### 1.2 OVS 路径 (Heavyweight)
```text
阶段 1: OVS Datapath (流表匹配)
   +-- [ 逻辑: HashLookup(Match: tap0_Port) ]
   +--> skb->cb[OVS_CB] -> [ tun_id: 100 ] <-- 【存储在 OVS 私有块】

阶段 2: OVS Vport Encap (即时封装)
[ UDP | VXLAN(VNI:100) | Ethernet | IP | Payload ]
   +-- [ 动作: 内存重新分配并完成头部的即时拷贝 ]
```

## 2. 拦截图谱与执行效率
- **eBPF**：利用标准的 `skb->mark` 字段，支持 **[[2026-03-11-spa-c-implementation|XDP 极致阻断]]**。
- **OVS**：依赖私有的 `skb->cb`，增加了 **[[2026-03-08-deepflow-detailed-analysis-report|全栈可观测性]]** 的读取难度。

## 3. 延迟封装的技术精髓
将“安全决策”与“字节拼凑”解耦。配合 **[[2025-12-16-dpdk-tx-offload-mbuf-fast-free|DPDK MBUF 操作]]**，可实现 100G 级别的无损安全过滤。

---
## 外部参考
- [Linux Kernel sk_buff 结构分析](https://elixir.bootlin.com/linux/latest/source/include/linux/skbuff.h)
