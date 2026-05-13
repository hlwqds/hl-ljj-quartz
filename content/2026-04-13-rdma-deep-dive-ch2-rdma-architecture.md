---
title: "RDMA 第二章：RDMA 架构——RNIC/HCA、verbs 与队列对"
date: 2026-04-13 18:30:00
tags: [rdma, architecture, hca, rnic, verbs, queue-pair, cm]
description: "深入 RDMA 架构：RNIC/HCA 硬件架构、libibverbs 编程模型、Queue Pair 队列对、Connection Manager 连接管理、内存区域与保护域。"
---

# RDMA 第二章：RDMA 架构——RNIC/HCA、verbs 与队列对

> [!abstract] 核心要点
> 本章解析 RDMA 软件和硬件架构：RNIC/HCA 的内部结构、libibverbs 编程接口、Queue Pair（QP）队列对模型、Connection Manager（CM）连接管理，以及 Memory Region（MR）内存区域概念。

---

## 1. RDMA 硬件架构：RNIC 与 HCA

### 1.1 术语区分

| 术语 | 全称 | 说明 |
|------|------|------|
| **RNIC** | RDMA Network Interface Card | Ethernet RDMA 网卡（RoCE/iWARP） |
| **HCA** | Host Channel Adapter | InfiniBand 专用通道适配器 |
| **TCA** | Target Channel Adapter | HCA 的目标侧（IB 规范术语） |

实际使用中，RNIC 和 HCA 常被混用，都指"支持 RDMA 的网卡"。

### 1.2 RNIC/HCA 内部架构

```
┌──────────────────────────────────────────────────────────────┐
│                        RNIC / HCA                            │
│                                                              │
│  ┌────────────┐    ┌─────────────┐    ┌──────────────────┐   │
│  │  PCIe Bar  │    │  DMA Engine │    │  Queue Pair (QP) │   │
│  │  (配置)    │    │  (数据搬运)  │    │  ──────────────  │   │
│  └────────────┘    └─────────────┘    │  Send Queue      │   │
│                                        │  Receive Queue   │   │
│  ┌────────────┐    ┌─────────────┐    │  Completion Q    │   │
│  │  Protection│    │  Checksum/ │    └──────────────────┘   │
│  │  Engine   │    │  Atomic     │                           │
│  └────────────┘    └─────────────┘                           │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │               Transmit/Receive Engine                  │   │
│  └──────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────┘
          ↑ PCIe                     ↑ 物理层 (IB/Ethernet)
```

**核心组件**：

- **DMA Engine**：直接内存访问引擎，负责 RNIC 和系统内存之间的数据搬运
- **Queue Pair (QP)**：RDMA 操作的核心数据结构，包含 Send Queue、Receive Queue、Completion Queue
- **Protection Engine**：验证内存访问权限（确保只能访问已注册的内存区域）
- **Checksum & Atomic**：校验和计算与原子操作（Fetch & Add、Compare & Swap）

### 1.3 PCIe 角色

RNIC 作为 PCIe 设备，系统内存对 RNIC 是可直接寻址的（通过 DMA）。CPU 只需要向 RNIC 写入 Work Request（WR），RNIC 自己完成 DMA 操作。

---

## 2. verbs 编程模型

RDMA 编程接口标准是 **libibverbs**（用户态 API），由 OFED（OpenFabrics Enterprise Distribution）提供。

### 2.1 核心对象

```
PD (Protection Domain)
    │
    ├── QP (Queue Pair) × N
    │     ├── SQ (Send Queue)
    │     ├── RQ (Receive Queue)
    │     └── CQ (Completion Queue)
    │
    ├── MR (Memory Region)
    │     └── rkey / lkey
    │
    └── AH (Address Handle)  [for UD]
```

| 对象 | 英文 | 作用 |
|------|------|------|
| **PD** | Protection Domain | 将 QP、MR 等资源分组，隔离不同应用的访问权限 |
| **QP** | Queue Pair | 发送/接收请求的队列对 |
| **CQ** | Completion Queue | 异步接收操作完成通知 |
| **MR** | Memory Region | 已注册、可被 RDMA 访问的内存区域 |
| **AH** | Address Handle | 目的地地址信息（用于 UD QP） |
| **MW** | Memory Window | 内存窗口，提供更灵活的远程访问控制 |

### 2.2 ibv_post_send 流程

应用程序提交一个 Send Work Request：

```c
struct ibv_send_wr wr = {
    .sg_list    = &sge,        // Scatter-Gather 列表
    .num_sge    = 1,
    .opcode     = IBV_WR_RDMA_WRITE,
    .wr.rdma    = { .remote_addr = remote_addr, .rkey = remote_rkey },
};

ibv_post_send(qp, &wr, &bad_wr);  // 同步返回
```

RNIC 收到 WR 后：
1. 通过 DMA 读取本地内存中的发送数据
2. 通过网络传输到对端
3. 完成后，生成 Work Completion 放入 CQ

### 2.3 两种操作模式

| 模式 | 英文 | 说明 | CPU 参与 |
|------|------|------|----------|
| **Send/Recv** | Two-sided | 需要两端参与，接收方必须 post_recv | 双方都要 |
| **RDMA Read/Write** | One-sided | 单侧操作，读取端无需对端 CPU 参与 | 仅发送端 |

---

## 3. 队列对（Queue Pair）

### 3.1 QP 状态机

QP 是 RDMA 连接的核心，每个 QP 有一个状态机：

```
       ┌─────────┐
       │  RESET  │  ← 初始化状态
       └────┬────┘
            │ ibv_modify_qp(IBV_QPS_INIT)
            ▼
       ┌─────────┐
       │  INIT   │  ← QP 已创建，等待本地特性配置
       └────┬────┘
            │ ibv_modify_qp(IBV_QPS_RTR)
            ▼
       ┌─────────┐
       │   RTR   │  ← Ready to Receive（接收就绪）
       └────┬────┘
            │ ibv_modify_qp(IBV_QPS_RTS)
            ▼
       ┌─────────┐
       │   RTS   │  ← Ready to Send（发送就绪）
       └────┬────┘
            │ ...
            ▼
       ┌─────────┐
       │  ERROR  │  ← 出错时进入
       └─────────┘
```

### 3.2 Queue Pair 类型

| 类型 | 全称 | 可靠性 | 场景 |
|------|------|--------|------|
| **RC** | Reliable Connection | 可靠连接，保证送达 | HPC、AI 训练（主要使用） |
| **UC** | Unreliable Connection | 不可靠连接 | 很少用 |
| **UD** | Unreliable Datagram | 不可靠数据报，无连接 | 多播、 broadcast |
| **RD** | Reliable Datagram | 可靠数据报 | 在 InfiniBand 中有，RoCE/iWARP 不支持 |

---

## 4. 内存区域（Memory Region）

### 4.1 为什么需要注册内存

RDMA 设备不能随意访问任意虚拟内存。应用程序必须先将内存"注册"为 Memory Region（MR），告诉 RNIC：

- 物理地址是什么
- 大小是多少
- 访问权限（本地读/写、远程读/写）

注册后的 MR 会被分配 **Lkey**（本地 key）和 **Rkey**（远程 key），用于后续 RDMA 操作。

### 4.2 零拷贝的物理基础

MR 注册后，RNIC 获得物理页的连续地址列表（page list）。这使得 DMA 操作可以直接访问物理内存，实现真正的零拷贝。

```
Virtual Address → Registered PA List → RNIC DMA → Wire → Remote PA
```

### 4.3 Memory Window（内存窗口）

MW 提供更动态的远程访问能力——可以在不重新注册内存的情况下，更新远程可访问的地址范围：

```
MW 绑定到 MR：一个 MR 可以有多个 MW
MW 可以改变远程地址范围（re-MW）
```

---

## 5. Connection Manager (CM)

### 5.1 为什么需要 CM

RDMA QP 的连接建立涉及交换 GID、LID、QPN 等信息，这需要一个控制面握手协议——**Connection Manager (CM)**。

CM 支持两种 API：
- **CM ID**：面向连接的 RC/UC 类型的连接管理
- **rdma_cm**：更现代的 API，同时支持 RDMA 和传统 IP

### 5.2 连接建立流程

```
Client                                  Server
  │                                        │
  │ ---- rdma_resolve_addr() ──────────→  │  解析目标地址
  │ ---- rdma_create_id() ────────────→   │  创建 CM ID
  │                                        │
  │ ---- rdma_connect() ─────────────→    │  交换 QPN, GID, PSN
  │ ←── rdma_accept() ─────────────────── │  接收方响应
  │ ←── rdma_establish() ───────────────  │  连接建立
  │                                        │
  │  ===== RDMA data transfer =====        │  开始 RDMA 操作
```

---

## 6. RDMA 操作类型

### 6.1 Send / Receive（双侧操作）

```
发送端：ibv_post_send (opcode=IBV_WR_SEND)
接收端：ibv_post_recv (提前 post buffer)
```

接收端必须提前"预约"接收缓冲区，否则数据到来时无处存放（通常返回错误）。

### 6.2 RDMA Write（单侧写）

```
发送端直接写入对端内存，无需对端 CPU 参与：
ibv_post_send (opcode=IBV_WR_RDMA_WRITE,
               remote_addr=0x1000, rkey=xxx)
```

### 6.3 RDMA Read（单侧读）

```
发送端直接从对端内存读取数据：
ibv_post_send (opcode=IBV_WR_RDMA_READ,
               remote_addr=0x1000, rkey=xxx)
```

### 6.4 Atomic Operations

| 操作 | 说明 |
|------|------|
| **Fetch & Add** | 读取远程值，加上本地值，写回 |
| **Compare & Swap (CAS)** | 如果远程值等于比较值，则交换 |

原子操作用于分布式锁、计数器等场景。

---

## 7. 完整软件栈

```
┌────────────────────────────────────────┐
│        User Space (App)               │
│   rdma-core / libibverbs / librdmacm  │
├────────────────────────────────────────┤
│        Kernel (ib_core, rdma_cm)      │
├────────────────────────────────────────┤
│        Driver (mlx5, qedr, etc.)      │
├────────────────────────────────────────┤
│        RNIC / HCA (Mellanox, Intel)  │
└────────────────────────────────────────┘
```

---

## 8. 总结

RDMA 架构的核心抽象：

| 组件 | 作用 |
|------|------|
| **QP** | RDMA 操作的基本单元，状态机管理连接生命周期 |
| **MR** | 零拷贝的物理基础，注册内存获取 DMA 访问权限 |
| **PD** | 隔离不同应用/用户间的 RDMA 资源 |
| **CQ** | 异步事件通知，轮询完成的工作请求 |
| **CM** | 控制面，负责连接建立与拆除 |

> [!next] 下一章
> 第三章我们聚焦 InfiniBand，深入解析 IB 协议栈的链路层、网络层、传输层，以及 LID/GID 地址机制。
