---
title: RDMA 第一章：RDMA 概述——零拷贝、零等待、零 CPU
date: 2026-04-13 18:00:00
tags:
  - rdma
  - networking
  - performance
  - zero-copy
  - overview
description: RDMA 核心价值：零拷贝、零 CPU 参与、内存直接访问。解析传统网络 vs RDMA 架构差异，延迟/带宽对比，三大协议分支。
---

# RDMA 第一章：RDMA 概述——零拷贝、零等待、零 CPU

> [!abstract] 核心要点
> RDMA（Remote Direct Memory Access）让两台服务器的内存可以直接通信，无需 CPU 参与数据拷贝。本章解析 RDMA 的核心价值：零拷贝（Zero-Copy）、零等待（Zero-Poll）、零 CPU（Zero-Copy CPU），并横向对比三大协议分支 InfiniBand、RoCE、iWARP。

---

## 1. 传统网络的问题：CPU 成了瓶颈

理解 RDMA 的价值，先从传统网络的问题说起。

### 1.1 数据路径中的 CPU 开销

传统 TCP/IP  socket 接收数据的路径：

```
Wire → NIC → Driver → Kernel (TCP/IP stack) → Socket Buffer → App
        ↑                                     ↑
      DMA                             CPU 复制（多次）
```

每一步都涉及 CPU：

| 步骤 | 问题 |
|------|------|
| **中断** | 网卡通知 CPU，context switch 成本高 |
| **复制** | NIC→Kernel、Kernel→User，各一次复制 |
| **协议处理** | TCP/IP checksum、排序、重组，CPU 全程参与 |
| **内存引用** | 数据在不同 memory domain 间映射 |

### 1.2 量化对比：延迟与 CPU 占用

| 指标 | 传统 TCP | RDMA |
|------|----------|------|
| **端到端延迟** | 10–100 μs | 0.5–5 μs |
| **CPU 占用** | 30–100% | < 5% |
| **吞吐量** | 受 CPU 限制 | 线速 (100/200/400 Gbps) |
| **数据复制次数** | 4+ 次 | 0 次（直接 DMA） |

对于 HPC、AI 训练、分布式存储等场景，CPU 本应专注计算，却被网络 I/O 拖累。RDMA 正是解决这个矛盾的技术。

---

## 2. RDMA 的核心价值

RDMA 的三个"零"：

### 2.1 零拷贝（Zero-Copy）

数据从源内存到目标内存，一条 DMA 路径直达，无需 CPU 在中间做内存拷贝：

```
传统：  Memory A → CPU → Kernel → NIC → Wire → NIC → Kernel → CPU → Memory B
                                                      (4+ 次复制)

RDMA： Memory A → NIC A → Wire → NIC B → Memory B
                    (直接 DMA，0 复制)
```

### 2.2 零 CPU 参与（Zero-CPU）

RDMA 操作在 RNIC（RDMA Network Interface Card）/HCA（Host Channel Adapter）上执行，应用只需要：

1. 提交 Work Request（WR）到队列对（Queue Pair）
2. 从 Completion Queue 轮询结果

CPU 在数据路径中完全不参与。

### 2.3 零等待（Kernel Bypass）

RDMA 完全绕过操作系统内核（kernel bypass），不调用 socket API，不经过 TCP/IP 协议栈：

```
传统 Socket：  App → glibc → Kernel (TCP/IP) → NIC
RDMA：          App → libibverbs → RNIC/HCA
```

---

## 3. RDMA 的三种协议

RDMA 不是单一协议，而是有一组协议栈。目前主流有三个分支：

| 协议 | 全称 | 底层网络 | 主要厂商 |
|------|------|----------|----------|
| **InfiniBand** | — | IB 网络（专用） | Mellanox（NVIDIA）、Intel |
| **RoCE** | RDMA over Converged Ethernet | Ethernet | Mellanox |
| **iWARP** | internet Wide Area RDMA Protocol | Ethernet | Intel、Chelsio、Cisco |

### 3.1 InfiniBand

- 专用 IB 网络，需要 IB 网卡和 IB 交换机
- 延迟最低（~0.5 μs），带宽最高（EDR 100G, HDR 200G, NDR 400G）
- 拥有完整的传输层（含拥塞控制、原子操作）
- HPC、AI 训练首选（如 NVIDIA SuperPOD）

### 3.2 RoCE (RDMA over Converged Ethernet)

- 运行在标准 Ethernet 上，复用现有 DCB 基础设施
- **RoCE v1**：Ethernet Layer 2，只能在同属一个 VLAN 的节点间通信
- **RoCE v2**：UDP/IP Layer 3，可路由，端口 4791
- 需要无损网络（PFC + ECN）保证可靠性
- 云环境、HCI 超融合场景广泛使用

### 3.3 iWARP (internet Wide Area RDMA Protocol)

- 基于 TCP/UDP 传输，可以穿越路由器（理论上支持 WAN）
- 架构上更接近传统网络堆栈（DDP → RDMAP → MPA）
- 对网络质量要求低（TCP 自带可靠传输）
- 厂商支持相对较少

---

## 4. RDMA 延迟深度解析

RDMA 延迟约 1–5 μs，分解来看：

```
总延迟 ≈ 发送侧 DMA 延迟 + 传输延迟 + 接收侧 DMA 延迟
        ≈ 0.5–1 μs    +  光/电传输 + 0.5–1 μs
```

对比 TCP 的 10–100 μs：

| 延迟来源 | TCP | RDMA |
|----------|-----|------|
| 中断处理 | 1–5 μs | 0（轮询） |
| 数据复制 | 2–4 μs | 0 |
| 协议处理 | 5–20 μs | ~0.5 μs |
| 内存映射 | 1–5 μs | ~0.5 μs |

---

## 5. 典型应用场景

### 5.1 AI 训练

- NVIDIA GPUDirect RDMA：GPU 内存直接通过 RDMA 传输，绕过 CPU 和系统内存
- NCCL 集合通信：AllReduce、Broadcast 通过 RDMA 实现
- 大模型分布式训练：多机多卡间的高速数据交换

### 5.2 HPC 超算

- MPI（Message Passing Interface）over InfiniBand
- 天气预报、分子动力学、流体力学等科学计算

### 5.3 分布式存储

- NVMe-oF over RDMA：存储节点通过网络暴露 NVMe 设备
- Ceph、vSAN、ScaleIO 等超融合存储的后端网络

### 5.4 金融交易

- 超低延迟需求（微秒级），RDMA 替代传统 kernel bypass 技术

---

## 6. 三大协议快速一览

```
                    ┌──────────────────────────────────────┐
                    │              RDMA                   │
                    └──────────┬───────────────────┬──────┘
                               │                   │
              ┌────────────────▼─────┐  ┌──────────▼─────────┐
              │    InfiniBand        │  │   Ethernet         │
              │    (专用网络)         │  │   (标准网络)        │
              └──────────┬───────────┘  └──────┬──────┬───────┘
                         │                    │      │
               ┌─────────▼──────┐   ┌────────▼────┐  │  ┌────▼─────┐
               │    IB 物理层    │   │    RoCE    │  │  │  iWARP  │
               │   (自行设计)   │   │  v1 / v2   │  │  │  DDP/RDMAP│
               └────────────────┘   └────────────┘  │  └──────────┘
                                                    │
                                       ┌────────────▼──────────┐
                                       │  TCP / UDP 传输        │
                                       └────────────────────────┘
```

---

## 7. 总结

RDMA 通过三项核心技术实现高性能网络：

| 特性 | 效果 |
|------|------|
| **零拷贝** | 数据不经过 CPU 内存复制 |
| **零 CPU** | RNIC/HCA 自行处理传输 |
| **内核旁路** | 绕过 TCP/IP 协议栈 |

三种协议各有适用场景：

- **InfiniBand**：追求最低延迟、最高带宽，专用 HPC/AI 集群
- **RoCE**：利用现有 Ethernet，云和超融合场景
- **iWARP**：需要穿越路由器的场景，或对网络质量容忍度低的环境

> [!next] 下一章
> 第二章我们将深入 RDMA 架构，了解 RNIC/HCA、verbs 编程模型、队列对（QP）和内存区域（MR）等核心概念。
