---
title: DPDK 2026 深度探索系列索引
date: 2026-04-09
pin: true
description: DPDK 深度探索全系列文章索引，涵盖从基础架构到大页内存、Ring 队列、PMD 驱动、Flow API、虚拟化加速、安全加密、性能优化的完整学习路径
tags:
  - dpdk
  - series
  - index
---

# DPDK 2026 深度探索系列

> [!tip] 系列说明
> 本系列约 50 篇文章，从 DPDK 基础架构出发，系统讲解 UIO/VFIO、大页内存、mbuf、Ring、无锁队列等核心机制，深入网络协议栈、虚拟化加速、安全加密领域，最终覆盖性能优化、工具调试和云原生部署。适合有网络基础和 Linux 内核认知的开发者系统性进阶。
>
> 标记 🚧 的章节内容尚待补全，后续会持续更新。

---

## Part I：基础原理 (Fundamentals)

掌握 DPDK 的核心架构——从 kernel bypass 到用户态驱动的完整运行机制。

| #   | 章节                                  | 主题                                     | 状态 |
| --- | ------------------------------------- | ---------------------------------------- | ---- |
| 1   | [[ch1-architecture-overview\|第一章]] | 架构概述：kernel bypass 原理与 DPDK 定位 | ✅   |
| 2   | [[ch2-uio-vfio-iommu\|第二章]]        | UIO/VFIO/IOMMU 用户态驱动框架            | ✅   |
| 3   | [[ch3-eal-initialization\|第三章]]    | EAL 初始化：rte_eal_init 与 lcore 模型   | ✅   |
| 4   | [[ch4-hugepage-mempool\|第四章]]      | 大页内存与 mempool 机制                  | ✅   |
| 5   | [[ch5-mbuf-mechanism\|第五章]]        | Mbuf 结构、Dynfield、Dynflag 详解        | ✅   |
| 6   | [[ch6-ring-queue\|第六章]]            | Ring 无锁队列实现与性能分析              | ✅   |
| 7   | [[ch7-pmd-driver\|第七章]]            | PMD (Poll Mode Driver) 驱动架构          | ✅   |
| 8   | [[ch8-timer-wheel\|第八章]]           | rte_timer 软件定时器与黄牛算法           | ✅   |
| 9   | [[ch9-lazy-expiry-gc\|第九章]]        | 懒惰过期与 GC 机制                       | ✅   |

---

## Part II：网络协议栈 (Network Stack)

深入 DPDK 的网络协议处理能力——从报文分类到 Flow 规则匹配。

| #   | 章节                                  | 主题                                        | 状态 |
| --- | ------------------------------------- | ------------------------------------------- | ---- |
| 9   | [[ch9-kni-interface\|第九章]]         | KNI (Kernel NIC Interface) 用户态与内核通信 | ✅   |
| 10  | [[ch10-flow-classification\|第十章]]  | Flow Classification 流量分类与 rte_flow     | ✅   |
| 11  | [[ch11-ether-ip-udp\|第十一章]]       | Ether/IP/UDP 协议处理与 checksum offload    | ✅   |
| 12  | [[ch12-tcp-protocol-stack\|第十二章]] | TCP 协议栈实现与连接管理                    | ✅   |
| 13  | [[ch13-gro-gso\|第十三章]]            | GRO/GSO 通用卸载机制                        | ✅   |
| 14  | [[ch14-vlan-vxlan\|第十四章]]         | VLAN/VXLAN 隧道与报头封装                   | ✅   |

---

## Part III：虚拟化与加速 (Virtualization & Acceleration)

DPDK 与虚拟化技术的深度融合——KNI、vhost、vDPA、向量加速。

| #   | 章节                                            | 主题                                        | 状态 |
| --- | ----------------------------------------------- | ------------------------------------------- | ---- |
| 15  | [[ch15-kni-interface\|第十五章]]                | KNI (Kernel NIC Interface) 用户态与内核通信 | ✅   |
| 15b | [[ch15b-af-xdp\|第十五章补充]]                  | AF_XDP —— KNI 的现代替代                    | ✅   |
| 16  | [[ch16-vhost-user\|第十六章]]                   | vhost-user 与 virtio 加速                   | ✅   |
| 16a | [[ch16a-ovs-dpdk-vhost-user-lab\|第十六章补充]] | OVS-DPDK 与 vhost-user 最小实战             | ✅   |
| 16b | [[ch33-cloud-hypervisor\|第十六章补充]]         | Cloud Hypervisor 与 DPDK 虚拟化路径         | ✅   |
| 17  | [[ch17-vhost-scsi\|第十七章]]                   | vhost-scsi 存储虚拟化                       | ✅   |
| 18  | [[ch18-ivshmem\|第十八章]]                      | IVSHMEM VM 间共享内存                       | ✅   |
| 19  | [[ch19-vdpa\|第十九章]]                         | vDPA 数据面加速与驱动                       | ✅   |
| 19b | [[ch19b-dpu-smartnic\|第十九章补充]]            | DPU/SmartNIC 基础                           | ✅   |
| 20  | [[ch20-simd-avx512\|第二十章]]                  | AVX512/SIMD 数据包处理向量化                | ✅   |

---

## Part IV：安全与加密 (Security & Crypto)

DPDK 的安全能力——cryptodev、IPsec、WireGuard 与硬件卸载。

| #   | 章节                                | 主题                            | 状态 |
| --- | ----------------------------------- | ------------------------------- | ---- |
| 21  | [[ch21-cryptodev\|第二十一章]]      | cryptodev 加密设备与 Crypto PMD | ✅   |
| 22  | [[ch22-ipsec-fullflow\|第二十二章]] | IPsec 完整处理流程与 SAD/SPD    | ✅   |
| 23  | [[ch23-tls-dtls-accel\|第二十三章]] | TLS/DTLS 加速与 session 管理    | ✅   |
| 24  | [[ch24-raw-crypto-api\|第二十四章]] | Raw Crypto API 与自定义协议加密 | ✅   |

---

## Part V：性能优化 (Performance Optimization)

DPDK 极致性能的工程实践——Cache、NUMA、同步机制与 profiling。

| #   | 章节                                                | 主题                                    | 状态 |
| --- | --------------------------------------------------- | --------------------------------------- | ---- |
| 25  | [[ch25-cache-optimization\|第二十五章]]             | Cache 优化：false sharing 与预取        | ✅   |
| 26  | [[ch26-numa-optimization\|第二十六章]]              | NUMA 亲和性与 local/remote 访问         | ✅   |
| 27  | [[ch27-memory-dma\|第二十七章]]                     | 内存优化：DMA 引擎与零拷贝              | ✅   |
| 27a | [[ch27a-vdpa-dsa-host-guest-accel\|第二十七章补充]] | vDPA、DSA 与 Host/Guest 数据面卸载      | ✅   |
| 28  | [[ch28-multicore-sync\|第二十八章]]                 | 多核同步：spinlock、RCU、memory reorder | ✅   |
| 29  | [[ch29-profiling\|第二十九章]]                      | Profiling：dpdk-procinfo、perf、火焰图  | ✅   |
| 30  | [[ch30-performance-tuning\|第三十章]]               | 性能调优：batching、RSS、flow director  | ✅   |

---

## Part VI：工具与调试 (Tools & Debugging)

DPDK 生态工具链——testpmd、pktgen、debug 技巧与诊断方法。

| #   | 章节                                    | 主题                                | 状态 |
| --- | --------------------------------------- | ----------------------------------- | ---- |
| 31  | [[ch31-debugging-tools\|第三十一章]]    | 调试工具：dpdk-devbind、ethtool     | ✅   |
| 32  | [[ch32-pktgen\|第三十二章]]             | pktgen 流量生成与测试场景           | ✅   |
| 33  | [[ch33-debug-techniques\|第三十三章]]   | 调试技巧：日志、assert、crash 分析  | ✅   |
| 34  | [[ch34-ethtool-comparison\|第三十四章]] | dpdk-procinfo vs ethtool vs netstat | ✅   |

---

## Part VII：新兴技术与架构 (Emerging Tech)

DPDK 与前沿技术的融合——P4、SR-IOV、智能网卡、DOCA、云原生。

| #   | 章节                                      | 主题                                 | 状态 |
| --- | ----------------------------------------- | ------------------------------------ | ---- |
| 35  | [[ch35-sr-iov\|第三十五章]]               | SR-IOV 与 VF 管理机制                | ✅   |
| 35a | [[ch32-sriov-vf\|第三十五章补充]]         | SR-IOV 与 VF 实战补充                | ✅   |
| 36  | [[ch36-p4-dpdk\|第三十六章]]              | P4 可编程数据面与 behavioral model   | ✅   |
| 37  | [[ch37-smartnic\|第三十七章]]             | 智能网卡：IPU/DPU、Capsule、Barefoot | ✅   |
| 38  | [[ch38-dpdk-ebpf\|第三十八章]]            | DPDK + eBPF：XDP 与 AF_XDP 协同      | ✅   |
| 39  | [[ch39-container-networking\|第三十九章]] | 容器网络：DPDK-CNI、OVS-DPDK         | ✅   |
| 40  | [[ch40-rdma-dpdk\|第四十章]]              | RDMA vs DPDK：RoCE/iWARP 对比与融合  | ✅   |
| 41  | [[ch41-doca-comparison\|第四十一章]]      | NVIDIA DOCA 与 DPU 编程框架          | ✅   |
| 42  | [[ch42-cloud-native\|第四十二章]]         | 云原生 DPDK：VPP、service mesh       | ✅   |

---

## Part VIII：实际案例 (Case Studies)

基于 DPDK 的实际项目实现——VPP、负载均衡器、DPI、NAT。

| #   | 章节                                    | 主题                                | 状态 |
| --- | --------------------------------------- | ----------------------------------- | ---- |
| 43  | [[ch43-vpp-architecture\|第四十三章]]   | VPP 架构与 vector packet processing | ✅   |
| 44  | [[ch44-openvswitch\|第四十四章]]        | OpenVSwitch：OVS-DPDK vs OVS-kernel | ✅   |
| 45  | [[ch45-load-balancer\|第四十五章]]      | DPDK L4/L7 负载均衡器设计           | ✅   |
| 46  | [[ch46-dpi-implementation\|第四十六章]] | DPI 深度包检测实现                  | ✅   |
| 47  | [[ch47-nat-implementation\|第四十七章]] | NAT 实现：CGNAT、NAT444             | ✅   |

---

## 相关资源

- [[2025-10-29-openeuler-dpdk\|OpenEuler DPDK 环境配置]]
- [[2025-12-09-dpdk-mem\|DPDK 内存管理]]
- [[2026-01-04-dpdk_flow_template_guide\|Flow Template 使用指南]]
- [[2026-03-31-kvm-dpdk-performance-optimization\|KVM+DPDK 性能优化]]

---

_DPDK 系列持续更新中，欢迎订阅关注。_
