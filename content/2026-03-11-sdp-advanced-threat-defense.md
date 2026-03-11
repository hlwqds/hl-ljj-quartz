---
title: "终极纵深防御：应对容器逃逸与底座沦陷"
date: 2026-03-11
tags: [security, container-escape, tee, tdx, microvm]
---

> [!abstract] 软件定义安全边界 (SDP) 深度系列
> 1. **[[2026-03-11-sdp-zero-trust-overview|1. 概论篇：SDP 与零信任的范式转移]]**
> 2. **[[2026-03-11-sdp-cloud-infrastructure-security|2. 基础设施篇：云底座的租户隔离与流量劫持]]**
> 3. **[[2026-03-11-sdp-kernel-path-deep-dive|3. 内核深度篇：OVS 与 eBPF 的路径博弈]]**
> 4. **[[2026-03-11-sdp-application-identity-mtls|4. 应用身份篇：SPIFFE 与透明加密实施]]**
> 5. **[[2026-03-11-sdp-advanced-threat-defense|5. 防御进阶篇：应对容器逃逸与底座沦陷 (当前文章)]]**

## 1. 租户沦陷后的四层拦截机制
即使租户环境被攻破，零信任架构通过以下防线确保嗅探（Sniffing）失效：
- **物理层**：利用 **[[2026-03-11-sdp-cloud-infrastructure-security|VNI 二层隔离]]**，非法租户根本收不到其他租户的数据包。
- **协议层**：全量 **mTLS** 配合前向安全性（PFS），嗅探者面对 [[2025-11-27-capture-ssl|加密流]] 只能看到乱码。
- **系统层**：利用 **[[2026-03-08-deepflow-detailed-analysis-report|DeepFlow eBPF]]** 识别异常扫描指纹并自动熔断。
- **底座层**：远程完整性度量（Attestation）确保内核未被篡改。

## 2. 全路径攻防矩阵：明文安全性的终极验证

| 攻击位置 | 攻击手段 | 基础设施级拦截手段 |
| :--- | :--- | :--- |
| **同一宿主机** | 邻居租户混杂模式嗅探 | **VNI 逻辑隔离**：宿主机虚拟交换机精准投递。 |
| **物理链路** | 交换机镜像/光纤窃听 | **隧道加密**：离开物理机前强制封装进 IPsec/WireGuard。 |
| **租户内部** | 恶意应用绕过 Sidecar | **eBPF 强制劫持**：在内核 Socket 层强制流量重定向。 |
| **宿主机内核** | 容器逃逸并利用 eBPF 嗅探 | **安全沙箱 (MicroVM) 与 TEE**：硬件内存加密与独立内核。 |

## 3. 终极防线：机密计算 (TEE)
应对“宿主机完全沦陷”：
- **硬件加密**：利用 **Intel TDX** / AMD SEV 实现 CPU 级别的内存加密。
- **效果**：即便黑客拥有宿主机 Root 权限并读取物理内存，看到的也是随机数，实现了连云厂商也无法偷窥数据的“绝对零信任”。

---
## 外部参考
- [Intel TDX 技术白皮书](https://www.intel.com/content/www/us/en/developer/articles/technical/intel-trust-domain-extensions.html)
