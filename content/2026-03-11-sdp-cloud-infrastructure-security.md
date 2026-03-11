---
title: "云底座安全：服务商视角的租户隔离与流量劫持"
date: 2026-03-11
tags: [sdp, sdn, ebpf, vpc, cloud-provider]
---

> [!abstract] 软件定义安全边界 (SDP) 深度系列
> 1. **[[2026-03-11-sdp-zero-trust-overview|1. 概论篇：SDP 与零信任的范式转移]]**
> 2. **[[2026-03-11-sdp-cloud-infrastructure-security|2. 基础设施篇：云底座的租户隔离与流量劫持 (当前文章)]]**
> 3. **[[2026-03-11-sdp-kernel-path-deep-dive|3. 内核深度篇：OVS 与 eBPF 的路径博弈]]**
> 4. **[[2026-03-11-sdp-application-identity-mtls|4. 应用身份篇：SPIFFE 与透明加密实施]]**
> 5. **[[2026-03-11-sdp-advanced-threat-defense|5. 防御进阶篇：应对容器逃逸与底座沦陷]]**

## 1. 物理锚定：Port-to-TID 绑定机制
作为服务商，识别租户身份的最可靠手段是物理绑定。
- **机制**：宿主机在创建虚拟网卡时，将内核索引 `ifindex` 与全局租户 ID (`TID`) 关联并存入 **BPF Map**。
- **不可伪造性**：由于拦截发生在流量离开租户环境的“第一跳”，租户无法通过修改 VM 内的源 IP 或进程名来欺骗宿主机。

## 2. 核心实现：IP 如何映射到 VNI？
在 IP 地址可能重叠的多租户环境下，映射遵循以下原则：
- **(VNI + IP) 二元组查表**：利用 `BPF_MAP_TYPE_HASH` 实现 $O(1)$ 快速检索。
- **ARP 抑制 (ARP Suppression)**：宿主机拦截所有非法的 ARP 请求，使恶意扫描在二层网络即由于“收不到响应”而失效。

## 3. 动态同步：控制面与数据面的联动
1. **编排阶段 (Orchestration)**：云平台下发指令创建网卡。
2. **注入阶段 (Injection)**：Agent 将 `ifindex -> TID` 写入内核 BPF Map。
3. **执行阶段 (Execution)**：eBPF TC 钩子实时查表并将 TID 注入 `skb->mark`。
- **参考**：类似于 **[[2026-03-08-deepflow-strategy-and-implementation|DeepFlow 策略下发机制]]**。

## 4. 策略放行逻辑
“允许访问”指令在底座会触发三层连锁反应：
- **网络层**：激活 VNI Peering 路由。
- **身份层**：同步双向 CA 根证书（Trust Bundle）。
- **应用层**：下发精细化 L7 ACL 策略至 Sidecar 或 Ztunnel。

---
## 外部参考
- [Cilium 租户隔离模型](https://cilium.io/blog/2021/05/11/cni-isolation/)
