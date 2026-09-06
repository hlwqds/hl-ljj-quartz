---
title: "RDMA 深度探索（一）：从内核网络栈到远程直接内存访问"
date: 2026-05-24
description: "理解 RDMA 的问题背景、数据路径、和 socket/DPDK/XDP 的差异，为后续 verbs 编程建立正确模型。"
tags: [rdma, series, networking, linux, performance]
---

> [!info] RDMA 深度探索系列 0. [[index-2026-05-24|系列索引]]
>
> 1. **第一章：从内核网络栈到远程直接内存访问**
> 2. [[ch2-verbs-objects|第二章：verbs 对象模型]]
> 3. [[ch3-rxe-lab|第三章：Soft-RoCE/RXE 实验环境]]

# RDMA 深度探索（一）：从内核网络栈到远程直接内存访问

RDMA 的完整名称是 Remote Direct Memory Access，直译是远程直接内存访问。它的关键不是“网络更快”，而是让网卡能够在应用授权后直接搬运两端内存中的数据，减少 CPU、内核协议栈和数据拷贝的参与。

## 1. 传统 socket 路径的问题

普通 TCP socket 的接收路径大致如下：

```text
NIC
  -> DMA 到内核 buffer
  -> 硬中断 / NAPI poll
  -> sk_buff 分配与协议栈处理
  -> TCP 重组、拥塞控制、socket buffer
  -> 应用调用 recv()
  -> 数据从内核拷贝到用户态 buffer
```

这条路径的优点是通用、稳定、语义清晰。缺点是在高性能场景里成本明显：

- 每个包都要经过内核协议栈。
- 应用和内核之间有系统调用和上下文切换。
- 数据可能经历多次 cache miss 和内存拷贝。
- CPU 既要处理业务逻辑，又要处理网络协议。

当网络从 10G 走到 25G、100G、200G 后，CPU 往往先成为瓶颈。

## 2. RDMA 改变的是数据路径

RDMA 程序启动时，应用会先把一段内存注册给网卡。注册之后，网卡知道这段内存可以被本地或远端访问，并通过 key 控制权限。

RDMA Write 的路径可以简化成：

```text
应用准备本地 buffer
  -> 本地 RNIC DMA 读取本地 buffer
  -> 网络传输
  -> 远端 RNIC DMA 写入远端已注册 buffer
  -> 完成事件进入 CQ
```

远端 CPU 不一定参与这次数据搬运。远端应用甚至不需要提前调用 `recv()`。这就是 RDMA 在低延迟和低 CPU 占用场景里的核心价值。

## 3. RDMA 不是“更快的 socket”

初学 RDMA 最常见的误解，是把它当成更快版本的 `send()` / `recv()`。

socket 编程的基本对象是文件描述符：

```text
fd -> send/recv -> 内核负责协议和缓冲区
```

RDMA verbs 编程的基本对象是队列和内存注册：

```text
MR + QP + CQ -> post WR -> poll WC
```

这意味着应用要自己承担更多工作：

- 自己管理 buffer 生命周期。
- 自己注册内存并保存 key。
- 自己交换连接信息。
- 自己 poll completion 判断操作是否真正完成。
- 自己处理接收队列不足、重试失败、权限错误等问题。

换句话说，RDMA 用更复杂的编程模型换取更短的数据路径。

## 4. 三种常见 RDMA 网络

| 类型       | 说明                         | 特点                       |
| ---------- | ---------------------------- | -------------------------- |
| InfiniBand | 原生 RDMA 网络               | 低延迟、专用生态、HPC 常见 |
| RoCE       | RDMA over Converged Ethernet | 数据中心常见，可复用以太网 |
| iWARP      | RDMA over TCP                | 基于 TCP，生态相对小       |

RoCE 又分 RoCE v1 和 RoCE v2：

- RoCE v1 是二层协议，不跨三层路由。
- RoCE v2 使用 UDP/IP 封装，可以跨三层网络。

实际数据中心里，RoCE v2 很常见，但它对网络配置更敏感，尤其是 PFC、ECN、MTU、GID index 等。

## 5. RDMA 与 DPDK、XDP 的区别

RDMA、DPDK、XDP 都常被放在高性能网络语境里讨论，但它们解决的问题不同。

| 技术 | 核心目标         | 编程位置               | 典型用途                      |
| ---- | ---------------- | ---------------------- | ----------------------------- |
| RDMA | 远程内存直接访问 | 用户态 verbs / rdma_cm | 存储、HPC、数据库、低延迟 RPC |
| DPDK | 用户态高速包处理 | 用户态 PMD             | 网关、负载均衡、DPI、虚拟交换 |
| XDP  | 内核早期包处理   | 驱动/内核 eBPF hook    | 丢包、防护、转发、负载均衡    |

简单判断：

- 你要直接读写远端内存，优先看 RDMA。
- 你要自己处理每个包，优先看 DPDK。
- 你要在内核入口快速过滤或转发，优先看 XDP。

## 6. RDMA 的基本操作类型

入门阶段重点掌握四类操作：

| 操作       | 语义         | 是否需要远端 post_recv |
| ---------- | ------------ | ---------------------- |
| Send       | 发送一条消息 | 需要                   |
| Recv       | 接收一条消息 | 本端提交               |
| RDMA Write | 写远端内存   | 不需要                 |
| RDMA Read  | 读远端内存   | 不需要                 |

Send/Recv 是消息语义，适合入门和控制消息。

RDMA Write/Read 是内存语义，需要远端提前告诉你：

```text
remote address + rkey
```

这两个值代表远端授权给你的内存窗口。没有它们，本端不能发起远程读写。

## 7. 本章小结

RDMA 的核心价值是缩短数据路径，并把一部分传统内核网络栈承担的工作交给应用和网卡。学习 RDMA 要从一开始就接受三个事实：

1. RDMA 程序围绕内存和队列，不围绕文件描述符。
2. `post_send()` 只是提交任务，completion 才代表完成。
3. 远程内存访问必须经过显式授权，核心凭据是 `remote address + rkey`。

下一章进入 verbs 对象模型，重点拆解 PD、MR、CQ、QP、WR、WC 这些看起来抽象但实际非常固定的对象。
