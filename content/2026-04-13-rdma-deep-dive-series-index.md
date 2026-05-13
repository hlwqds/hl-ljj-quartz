---
title: "RDMA 深度探索系列索引"
date: 2026-04-13
pin: true
description: "RDMA 深度探索全系列——从零拷贝原理到高性能网络，涵盖 InfiniBand/RoCE/iWARP 协议、verbs 编程、内存区域、队列对、RDMA CNI、云原生 RDMA、性能优化与调试，40+ 章节系统性解析"
tags:
  - rdma
  - series
  - networking
  - performance
  - infiniband
  - roce
  - index
---

# RDMA 深度探索系列

> [!tip] 系列说明
> 本系列约 40+ 篇文章，从 RDMA 核心价值（零拷贝、零 CPU 参与）出发，系统讲解 InfiniBand/RoCE/iWARP 三大协议、libibverbs 编程接口、内存区域与队列对管理、RDMA CNI 云原生部署、性能优化与故障诊断。适合 HPC、AI 训练、分布式存储、对超低延迟有需求的网络工程师和开发者。
>
> 配合 [[2026-04-09-dpdk-deep-dive-series-index|DPDK 深度探索系列]]（用户态数据包处理）和 [[2026-04-13-kernel-protocol-stack-deep-dive-series-index|Kernel Protocol Stack 系列]]（内核网络协议栈），构成完整的"高性能网络"知识体系。

---

## Part I：RDMA 基础 (Fundamentals)

理解 RDMA 的核心价值、架构与三种协议。

| # | 章节 | 主题 | 状态 |
|---|------|------|------|
| 1 | [[2026-04-13-rdma-deep-dive-ch1-rdma-overview|RDMA 概述]] | 零拷贝、零 CPU、RDMA 优势、延迟/带宽对比 | 🚧 |
| 2 | [[2026-04-13-rdma-deep-dive-ch2-rdma-architecture|RDMA 架构]] | RNIC/HCA/CMA、verbs 模型、为什么要用 RDMA | 🚧 |
| 3 | [[2026-04-13-rdma-deep-dive-ch3-infiniband|InfiniBand 架构]] | IB 协议栈、链路层、网络层、传输层、LID/GID | 🚧 |
| 4 | [[2026-04-13-rdma-deep-dive-ch4-roce|RoCE v1/v2]] | RoCE 协议栈、PFC 流控、DCB、ECN、与 IB 对比 | 🚧 |
| 5 | [[2026-04-13-rdma-deep-dive-ch5-iwarp|iWARP]] | iWARP 协议栈 (DDP/RDMAP/MPA)、TCP/UDP 封装 | 🚧 |
| 6 | [[2026-04-13-rdma-deep-dive-ch6-roce-vs-iwarp|RoCE vs iWARP 对比]] | 协议特性、硬件需求、网络要求、性能对比 | 🚧 |

---

## Part II：核心概念 (Core Concepts)

RDMA 编程的核心数据结构与概念。

| # | 章节 | 主题 | 状态 |
|---|------|------|------|
| 7 | [[2026-04-13-rdma-deep-dive-ch7-queue-pair|第七章：队列对 (QP)]] | QP 状态机、Send/Recv WR、 Completion Queue | ✅ |
| 8 | [[2026-04-13-rdma-deep-dive-ch8-mr-pd|第八章：内存区域与保护域]] | MR/MW、PA/VA、Rkey/Lkey、Memory Window | ✅ |
| 9 | [[2026-04-13-rdma-deep-dive-ch9-verbs-api|第九章：verbs API]] | libibverbs、ibv_post_send/recv、polling | ✅ |
| 10 | [[2026-04-13-rdma-deep-dive-ch10-ud-rc|第十章：UD vs RC]] | Unreliable Datagram / Reliable Connection | ✅ |
| 11 | [[2026-04-13-rdma-deep-dive-ch11-atomics|第十一章：RDMA 原子操作]] | Compare & Swap、Fetch & Add、原子语义 | ✅ |

---

## Part III：RDMA 编程实战 (Programming)

从零开始编写 RDMA 应用。

| # | 章节 | 主题 | 状态 |
|---|------|------|------|
|| 12 | [[2026-04-13-rdma-deep-dive-ch12-rdma-programming|RDMA 编程起步]] | rdma-core、CM API、连接建立、内存注册 | ✅ |
|| 13 | [[2026-04-13-rdma-deep-dive-ch13-rdma-read-write|RDMA Send/Recv vs RDMA]] | RDMA Read/Write、One-sided vs Two-sided | ✅ |
|| 14 | [[2026-04-13-rdma-deep-dive-ch14-rdma-server-client|RDMA 客户端服务器]] | 完整 RDMA echo server/client 示例 | ✅ |
|| 15 | [[2026-04-13-rdma-deep-dive-ch15-rdma-multicast|RDMA 多播]] | Multicast QP、Join/Leave、UD 多播 | ✅ |

---

## Part IV：网络配置与调优 (Configuration)

交换机配置、PFC、ECN、拥塞控制。

| # | 章节 | 主题 | 状态 |
|---|------|------|------|
| 16 | [[2026-04-13-rdma-deep-dive-ch16-pfc|PFC 流控]] | Priority Flow Control、DCBX、无损网络配置 | ✅ |
| 17 | [[2026-04-13-rdma-deep-dive-ch17-ecn|ECN 拥塞通知]] | Explicit Congestion Notification、ECN 位、拥塞管理 | ✅ |
| 18 | [[2026-04-13-rdma-deep-dive-ch18-dcb|DCB 数据中心桥接]] | DCBX、ETS、PFC、DCB 架构 | ✅ |
| 19 | [[2026-04-13-rdma-deep-dive-ch19-ras-tools|RDMA 配置工具]] | perftest、ibstat、ibdevinfo、rping、ucmatose | ✅ |

---

## Part V：性能优化 (Performance)

极致性能的工程实践。

| # | 章节 | 主题 | 状态 |
|---|------|------|------|
| 20 | [[2026-04-13-rdma-deep-dive-ch20-latency|Latency 优化]] | 延迟构成、微秒级优化、基准测试 | 🚧 |
| 21 | [[2026-04-13-rdma-deep-dive-ch21-bandwidth|Bandwidth 优化]] | 带宽利用率、Max Burst、inline data | 🚧 |
| 22 | [[2026-04-13-rdma-deep-dive-ch22-cpu-optimization|CPU 利用率优化]] | 轮询 vs 中断、batch polling、NUMA | 🚧 |
| 23 | [[2026-04-13-rdma-deep-dive-ch23-mem-optimization|内存优化]] | DMA 引擎、hugepage、cache 效率 | 🚧 |

---

## Part VI：云原生 RDMA (Cloud Native)

Kubernetes 环境下的 RDMA 部署。

| # | 章节 | 主题 | 状态 |
|---|------|------|------|
| 24 | [[2026-04-13-rdma-deep-dive-ch24-rdma-cni|RDMA CNI]] | RDMA CNI 插件、IPoIB、主机网络 | ✅ |
| 25 | [[2026-04-13-rdma-deep-dive-ch25-k8s-rdma|Kubernetes RDMA]] | RDMA Device Plugin、Device CRD、调度 | ✅ |
| 26 | [[2026-04-13-rdma-deep-dive-ch26-sriov-rdma|SR-IOV + RDMA]] | SR-IOV 虚拟化、VF 分配、MAC VLAN | ✅ |
| 27 | [[2026-04-13-rdma-deep-dive-ch27-cni-comparison|CNI 对比]] | RDMA CNI vs host-device vs ipvlan | ✅ |

---

## Part VII：RDMA 与 AI/HPC (AI & HPC)

RDMA 在 AI 训练和超算中的应用。

| # | 章节 | 主题 | 状态 |
|---|------|------|------|
| 28 | [[2026-04-13-rdma-deep-dive-ch28-nccl|NCCL 与 RDMA]] | NCCL 集合通信、RDMA 传输、GPU Direct RDMA | 🚧 |
| 29 | [[2026-04-13-rdma-deep-dive-ch29-gpu-direct|GPU Direct RDMA]] | GPU Memory、PCIe P2P、NVLink + RDMA | 🚧 |
| 30 | [[2026-04-13-rdma-deep-dive-ch30-mlperf|MLPerf RDMA]] | AI 训练基准、AllReduce、Ring/Pair 策略 | 🚧 |
| 31 | [[2026-04-13-rdma-deep-dive-ch31-hpc|HPC 集群]] | MPI + RDMA、InfiniBand 集群、Lustre | 🚧 |

---

## Part VIII：故障诊断与调试 (Troubleshooting)

RDMA 网络的排错与监控。

| # | 章节 | 主题 | 状态 |
|---|------|------|------|
| 32 | [[2026-04-13-rdma-deep-dive-ch32-debug|故障诊断]] | ibdiagnet、ibnetdiscover、错误码分析 | 🚧 |
| 33 | [[2026-04-13-rdma-deep-dive-ch33-performance-counters|性能计数器]] | perfmon、PMU、QoS 监控 | 🚧 |
| 34 | [[2026-04-13-rdma-deep-dive-ch34-network-validation|网络验证]] | 链路验证、拥塞测试、一致性检查 | 🚧 |
| 35 | [[2026-04-13-rdma-deep-dive-ch35-common-issues|常见问题]] | PKEY 错误、GID 问题、LID 冲突 | 🚧 |

---

## Part IX：高级话题 (Advanced)

RDMA 高级特性与新技术。

| # | 章节 | 主题 | 状态 |
|---|------|------|------|
| 36 | [[2026-04-13-rdma-deep-dive-ch36-shared-rx-ring|共享接收队列]] | SRQ、Shared Receive Queue、内存效率 | 🚧 |
| 37 | [[2026-04-13-rdma-deep-dive-ch37-extended-atomics|扩展原子操作]] | Extended Atomics、FV、OMO | 🚧 |
| 38 | [[2026-04-13-rdma-deep-dive-ch38-rdma-cxl|CXL 与 RDMA]] | CXL Cache Coherent、RDMA over CXL | 🚧 |
| 39 | [[2026-04-13-rdma-deep-dive-ch39-roce-v3|RoCE v3]] | 多路径 RoCE (MRMP)、AI-Eye ECN | 🚧 |

---

## Part X：行业应用与对比 (Industry)

RDMA 在各行业的应用与对比。

| # | 章节 | 主题 | 状态 |
|---|------|------|------|
| 40 | [[2026-04-13-rdma-deep-dive-ch40-storage|RDMA 存储]] | NVMe-oF、SFST、RDMA 文件系统 | 🚧 |
| 41 | [[2026-04-13-rdma-deep-dive-ch41-tcp-vs-rdma|TCP vs RDMA]] | 性能/成本/复杂度对比、适用场景 | 🚧 |
| 42 | [[2026-04-13-rdma-deep-dive-ch42-dpdk-vs-rdma|DPDK vs RDMA]] | DPDK 适用场景、RDMA vs Kernel Bypass | 🚧 |
| 43 | [[2026-04-13-rdma-deep-dive-ch43-future|RDMA 未来趋势]] | CNDP/ODP、可编程网络、端侧智能 | 🚧 |

---

## 相关系列

- [[2026-04-09-dpdk-deep-dive-series-index|DPDK 深度探索系列]] — 用户态数据包处理
- [[2026-04-13-kernel-protocol-stack-deep-dive-series-index|Kernel Protocol Stack 系列]] — 内核网络协议栈
- [[2026-04-13-vpn-deep-dive-series-index|VPN 与翻墙系列]] — 隧道与加密通信
- [[2026-04-08-ebpf-deep-dive-series-index|eBPF 深度探索系列]] — 内核可编程观测
