---
title: "终极纵深防御：应对容器逃逸与底座沦陷"
date: 2026-03-11
tags: [security, container-escape, tee, tdx, microvm]
---

> [!abstract] 软件定义安全边界 (SDP) 深度系列
>
> 1. **[[2026-03-11-sdp-zero-trust-overview|1. 概论篇：SDP 与零信任的范式转移]]**
> 2. **[[2026-03-11-sdp-cloud-infrastructure-security|2. 基础设施篇：云底座的租户隔离与流量劫持]]**
> 3. **[[2026-03-11-sdp-kernel-path-deep-dive|3. 内核深度篇：OVS 与 eBPF 的路径博弈]]**
> 4. **[[2026-03-11-sdp-application-identity-mtls|4. 应用身份篇：SPIFFE 与透明加密实施]]**
> 5. **[[2026-03-11-sdp-advanced-threat-defense|5. 防御进阶篇：应对容器逃逸与底座沦陷 (当前文章)]]**

## 1. 租户沦陷后的四层阻断机制

若租户 A 被攻破，其嗅探（Sniffing）尝试将在以下层级被化解：

- **物理层 (VNI 隔离)**：宿主机虚拟交换机精准投递，非法租户收不到任何非授权物理流量。
- **协议层 (mTLS/PFS)**：基于 TLS 1.3 配合 PFS，黑客面对 [[2025-11-27-capture-ssl|加密流]] 只能看到乱码。
- **系统层 (eBPF 归因)**：利用 **[[2026-03-08-deepflow-detailed-analysis-report|DeepFlow eBPF]]** 识别进程异常扫描指纹并触发自动熔断。
- **底座层 (Attestation)**：远程完整性度量确保内核未被篡改。

## 2. 全路径攻防博弈矩阵：明文安全性的终极验证

| 攻击边界       | 典型手段                      | 基础设施级拦截手段                                         |
| :------------- | :---------------------------- | :--------------------------------------------------------- |
| **同一宿主机** | 邻居租户混杂模式嗅探          | **VNI 逻辑隔离**：精准转发，使嗅探器处于“盲视”状态。       |
| **物理线缆**   | 交换机镜像/光纤窃听           | **全链路加密**：在离开物理机前强制封装进 IPsec/WireGuard。 |
| **租户内部**   | 恶意应用绕过 Sidecar 直接发包 | **eBPF 强制劫持**：在内核 Socket 层强制流量重定向。        |
| **宿主机内核** | 容器逃逸并利用 eBPF 嗅探      | **机密计算与安全沙箱**：利用 Intel TDX 实现硬件内存加密。  |

## 3. 终极防线：机密计算 (Confidential Computing)

应对“宿主机完全沦陷”：

- **硬件加密**：利用 **Intel TDX** / AMD SEV 对租户内存进行硬件级加密。
- **效果**：即便黑客拥有宿主机最高权限并读取物理内存（`/dev/mem`），看到的也全是随机数，TLS 密钥与敏感数据得到了物理级的隔离保护。

---

## 外部参考

- [Intel TDX 技术白皮书](https://www.intel.com/content/www/us/en/developer/articles/technical/intel-trust-domain-extensions.html)
