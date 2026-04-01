---
title: "云底座安全：服务商视角的租户隔离与流量劫持"
date: 2026-03-11
tags: [sdp, sdn, ebpf, vpc, cloud-provider]
---

> [!abstract] 软件定义安全边界 (SDP) 深度系列
>
> 1. **[[2026-03-11-sdp-zero-trust-overview|1. 概论篇：SDP 与零信任的范式转移]]**
> 2. **[[2026-03-11-sdp-cloud-infrastructure-security|2. 基础设施篇：云底座的租户隔离与流量劫持 (当前文章)]]**
> 3. **[[2026-03-11-sdp-kernel-path-deep-dive|3. 内核深度篇：OVS 与 eBPF 的路径博弈]]**
> 4. **[[2026-03-11-sdp-application-identity-mtls|4. 应用身份篇：SPIFFE 与透明加密实施]]**
> 5. **[[2026-03-11-sdp-advanced-threat-defense|5. 防御进阶篇：应对容器逃逸与底座沦陷]]**

## 1. 身份证明的三层技术形态

身份证明并不是一个孤立的字符串，而是贯穿协议栈不同层次的元数据。

| 层面       | 身份形式      | 存储位置              | 作用范围           |
| :--------- | :------------ | :-------------------- | :----------------- |
| **内核态** | `0xNN` (标记) | `skb->mark` (内存)    | 本地宿主机内部     |
| **网络层** | `VNI: 100`    | VXLAN Header (外层包) | 跨宿主机的物理网络 |
| **应用层** | `SPIFFE ID`   | X.509 证书 (TLS 扩展) | 全站逻辑链路       |

## 2. 物理锚定：Port-to-TID 绑定机制

服务商识别租户身份的最可靠手段是物理端口绑定。

- **不可伪造性**：由于拦截发生在数据包进入宿主机内核的“第一跳”，租户在包头内伪造源 IP 均无法欺骗物理接口绑定的身份。

## 3. 核心实现：IP 如何映射到 VNI？

- **(VNI + IP) 二元组查表**：利用 `BPF_MAP_TYPE_HASH` 实现 $O(1)$ 快速检索。
- **ARP 抑制 (ARP Suppression)**：宿主机拦截租户发出的所有 ARP 请求并代答。若目标不合法则保持静默，使恶意扫描工具因收不到响应而判定目标“主机下线”。

## 4. 动态同步：从编排到执行

1. **Orchestration**：云平台创建 VM/容器，Agent 获取网卡 `ifindex`。
2. **Injection**：Agent 调用 `bpf_map_update_elem` 将 `ifindex -> TID` 写入内核。
3. **Execution**：eBPF TC 钩子查表并将 TID 注入 `skb->mark`。参考：[[2026-03-08-deepflow-strategy-and-implementation|DeepFlow 策略下发机制]]。

## 5. 策略放行逻辑

放行指令会触发三层连锁：网络层激活 VNI 转发、身份层同步 **信任束 (Trust Bundle)**、应用层下发 L7 ACL。

---

## 外部参考

- [Cilium 租户隔离模型](https://cilium.io/blog/2021/05/11/cni-isolation/)
