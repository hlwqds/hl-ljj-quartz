---
title: "DPDK 深度探索 ch40：RDMA 与 DPDK——RoCEv2、Verbs 与 Bifurcated Driver 融合"
date: 2026-04-09 16:50:00
tags: [dpdk, rdma, roce, iwarp, infiniband, mlx5, verbs, bifurcated, nvme-of, spdk]
description: "从 DPDK 工程视角解析 RDMA：RoCEv2/iWARP 协议栈、Verbs API、QP/MR/CQ 核心概念、mlx5 bifurcated driver 模型下 DPDK 与 RDMA 共存、NVMe-oF 存储加速与性能调优"
---

# DPDK 深度探索 ch40：RDMA 与 DPDK——RoCEv2、Verbs 与 Bifurcated Driver 融合

> [!info] 章节定位
> DPDK 深度探索系列 0. [[2026-04-09-dpdk-deep-dive-series-index|全栈学习路径总览]]
>
> 关联章节：
>
> - [[2026-04-09-dpdk-deep-dive-ch30-lookaside-crypto|Lookaside 加速——Cryptodev、QAT、IPsec]]
> - [[2026-04-09-dpdk-deep-dive-ch37-smartnic|SmartNIC 数据面——Representor、E-Switch 与硬件卸载]]
> - [[2026-04-09-dpdk-deep-dive-ch39-container-networking|容器网络与 DPDK——vhost-user、SR-IOV、AF_XDP]]

> [!abstract] 核心结论
> RDMA 和 DPDK 不是竞争关系，而是 **同一张网卡上的两种数据路径**：
>
> 1. **RDMA** 让应用直接读写远程内存（RDMA Read/Write），NIC 硬件完成数据搬运，
>    远端 CPU 不进入逐次数据搬运路径。适合存储（NVMe-oF）、分布式内存、AI 训练；
> 2. **DPDK** 让应用在用户态处理每个包（路由、ACL、NAT），CPU 完全控制数据路径。
>    适合网络功能、防火墙、LB；
> 3. **Bifurcated driver**（mlx5）让两者 **共享同一张 ConnectX 网卡**：
>    内核驱动管理 RDMA 和设备生命周期，DPDK PMD 通过 rdma-core/devx 访问数据路径；
> 4. 共存不等于资源隔离：两者仍共享链路、PCIe、内存带宽、NIC 队列和流表资源；
> 5. 选型不取决于"谁更快"，而取决于 **应用是处理包（DPDK），还是在已授权内存之间搬运数据（RDMA）**。

---

## 1. RDMA 核心概念

### 1.1 RDMA 做了什么

```text
传统 Socket 接收路径（典型情况）：
  App A                              App B
    │                                  │
    │ send(buf, len)                   │ recv(buf, len)
    ▼                                  ▼
  Kernel TCP/IP                      Kernel TCP/IP
    │ 用户缓冲区与 socket buffer 之间   │
    │ 通常发生 CPU 拷贝                 │
    ▼                                  ▼
  NIC ───────────────────────────── NIC

  CPU 参与：系统调用、TCP/IP 协议栈、缓冲管理和应用侧拷贝
  注意：具体拷贝次数取决于 sendfile、MSG_ZEROCOPY、io_uring、
        GRO/GSO 和网卡 offload，不能固定写成 4 次。

RDMA 传输：
  App A                              App B
    │ ibv_post_send(RDMA_WRITE)        │ （远端 CPU 不处理该次搬运）
    ▼                                  ▼
  NIC ──── DMA 直接到远程内存 ─────▶ NIC
    │                                  │
  远程 App B 的 buffer 被直接写入
  App B 需要通过协议约定、Write with Immediate、
  Send/Recv 或共享元数据得知新数据已经可用。

  数据路径：RNIC DMA 读取本地已注册内存，并写入远端已授权内存
  CPU 参与：创建资源、提交 WR、处理 CQE、错误恢复和业务同步
```

RDMA 所谓“零拷贝”是指避免应用缓冲区与内核 socket 缓冲区之间的传统 CPU 拷贝，
并不意味着没有 DMA、PCIe 事务、缓存一致性成本或应用控制逻辑。

### 1.2 RDMA 操作类型

| 操作                          | 方向        | 描述                           | 远端要求                      |
| ----------------------------- | ----------- | ------------------------------ | ----------------------------- |
| **RDMA Write**                | 本地 → 远程 | 写入远端 MR                    | 提前交换 `addr + rkey`        |
| **RDMA Write with Immediate** | 本地 → 远程 | 写数据并产生带立即数的接收完成 | 远端预先 post receive         |
| **RDMA Read**                 | 远程 → 本地 | 从远端 MR 读取到本地 MR        | 提前交换 `addr + rkey`        |
| **Send/Recv**                 | 双向        | 消息传递，由接收端提供落点     | 远端预先 post receive         |
| **Atomic**                    | 远程        | CAS、FetchAdd 等远程原子操作   | 硬件、QP 类型和 MR 权限均支持 |

RDMA Write/Read 是 **单边操作（one-sided）**：只有发起端知道发生了什么，
远端 CPU 不执行对应的 `recv()`。但远端应用仍要负责授权内存、交换 RKey、
定义数据所有权和可见性协议，这是 RDMA 编程最容易遗漏的部分。

### 1.3 核心对象

```text
┌─────────────────────────────────────────────────────┐
│               Protection Domain (PD)                │
│   安全隔离边界，同一 PD 内的 MR 和 QP 可以互访       │
│                                                      │
│   ┌──────────────┐  ┌──────────────┐                │
│   │ MR (Memory   │  │ QP (Queue    │                │
│   │  Region)     │  │  Pair)       │                │
│   │              │  │              │                │
│   │ LKey: 本地访问│  │ Send Queue   │                │
│   │ RKey: 远程访问│  │ Receive Queue│                │
│   │              │  │              │                │
│   │ addr + len   │  │ QPN: QP 编号  │                │
│   │ (已注册的内存)  │  │ Port, GID    │                │
│   └──────────────┘  └──────┬───────┘                │
│                            │                         │
│                     ┌──────▼───────┐                 │
│                     │ CQ (Completion│                 │
│                     │  Queue)      │                 │
│                     │              │                 │
│                     │ 操作完成事件  │                 │
│                     │ (成功/失败)   │                 │
│                     └──────────────┘                 │
└─────────────────────────────────────────────────────┘
```

| 对象     | 作用                                                   |
| -------- | ------------------------------------------------------ |
| **PD**   | 保护域，隔离 MR 和 QP 的访问权限                       |
| **MR**   | 注册的内存区域，NIC 获得 DMA 映射和访问权限            |
| **QP**   | 通信端点，包含发送队列（SQ）和接收队列（RQ）           |
| **CQ**   | 完成队列，操作完成后产生 CQE（Completion Queue Entry） |
| **AH**   | 地址句柄（UD 类型），描述远端地址                      |
| **LKey** | 本地访问密钥，NIC 访问本地 MR 时使用                   |
| **RKey** | 远程访问密钥，远端 NIC 访问此 MR 时使用（放在 WR 中）  |

### 1.4 传输类型

| 类型   | 连接性 | 可靠性 | Send/Recv | RDMA Write | RDMA Read/Atomic | 典型场景              |
| ------ | ------ | ------ | --------- | ---------- | ---------------- | --------------------- |
| **RC** | 1:1    | 可靠   | 支持      | 支持       | 支持             | 存储、RPC、分布式系统 |
| **UC** | 1:1    | 不可靠 | 支持      | 支持       | 不支持           | 少见、容忍丢包的写入  |
| **UD** | 1:多   | 不可靠 | 支持      | 不支持     | 不支持           | 发现、控制面、组播    |

RC 是生产环境最常见的类型。这里的“可靠”由 RDMA transport 提供：
序列号、ACK/NAK、重传和有序交付并不会因为 RoCEv2 使用 UDP 封装而消失。

---

## 2. RoCE v2 vs iWARP

### 2.1 协议栈对比

```text
InfiniBand（原生 IB 网络）：
  ┌──────────────────────┐
  │  IB Transport        │  RDMA Read/Write/Send
  ├──────────────────────┤
  │  IB Network Layer    │  GRH, 路由
  ├──────────────────────┤
  │  IB Link Layer       │  专用 IB 链路
  └──────────────────────┘

RoCE v2（基于 UDP/IP 的以太网）：
  ┌──────────────────────┐
  │  RDMA Transport      │  RC/UC/UD、ACK/NAK、重传
  ├──────────────────────┤
  │  UDP (dst 4791)      │  ← UDP 作为可路由封装
  │  IP                  │
  ├──────────────────────┤
  │  Ethernet            │
  └──────────────────────┘
  工程重点：拥塞控制、缓冲管理、QoS 和丢包恢复

iWARP（基于 TCP 的以太网）：
  ┌──────────────────────┐
  │  RDMAP               │  RDMA 操作语义
  ├──────────────────────┤
  │  DDP (直接数据放置)   │
  │  MPA (帧对齐)         │
  ├──────────────────────┤
  │  TCP                 │  ← 自带可靠性
  │  IP                  │
  ├──────────────────────┤
  │  Ethernet            │
  └──────────────────────┘
  依赖 TCP 的可靠传输和拥塞控制
```

### 2.2 关键差异

| 维度         | RoCE v2                      | iWARP                    | InfiniBand            |
| ------------ | ---------------------------- | ------------------------ | --------------------- |
| 底层传输     | UDP/IP（port 4791）          | TCP/IP                   | 专用 IB 链路          |
| 网络要求     | 对拥塞、丢包和 QoS 配置敏感  | 标准可路由 IP 网络       | 专用 IB Fabric        |
| 路由         | L3 可路由                    | L3 可路由                | IB 子网内，GID 路由   |
| 性能关注点   | 低延迟、硬件重传与拥塞控制   | TCP 状态与实现开销       | Fabric 拓扑与交换能力 |
| 可用链路速率 | 取决于 RNIC 和以太网代际     | 取决于 RNIC 和以太网代际 | 取决于 IB 代际        |
| 拥塞控制     | 常见为 ECN + DCQCN，PFC 可选 | TCP 拥塞控制             | IB Fabric 机制        |
| 硬件示例     | ConnectX、E810、Broadcom 等  | E810、Chelsio 等         | NVIDIA IB HCA         |

> [!warning] RoCEv2 不是“UDP 所以不重传”
> UDP 只是 RoCEv2 的网络封装。RC QP 自身仍有可靠传输、ACK/NAK 和硬件重传。
> 但重传会放大尾延迟，并可能在拥塞时造成吞吐抖动，因此生产网络仍要控制丢包和队列积压。

### 2.3 RoCE 网络设计：不要只会打开 PFC

常见生产设计是：

1. **ECN + DCQCN**：在队列持续增长前反馈拥塞，让发送端主动降速；
2. **PFC**：只对承载 RoCE 的优先级启用，作为短时突发的保护手段，而不是主要拥塞控制；
3. **ETS/DCBX**：为 RDMA 与普通以太网流量分配优先级和带宽，并保证端到端映射一致；
4. **MTU、DSCP/PCP、GID 和路由一致性**：任一跳配置不一致都可能表现为连接失败或性能波动；
5. **监控重传、ECN 标记和 PFC pause**：只看应用吞吐无法判断问题在主机、交换机还是 RNIC。

PFC 配置不当会带来 pause storm、head-of-line blocking，甚至死锁风险。
现代硬件和部分部署可以运行在有损网络上，但是否关闭 PFC 应基于 RNIC 能力、
拥塞算法、交换网络缓冲和实际压测，而不是把“无损”或“有损”当成固定教条。

---

## 3. Verbs API：RDMA 的编程接口

### 3.1 libibverbs vs librdmacm

```text
libibverbs (ibv_*)：
  · 低层 verbs 操作
  · 创建 QP、MR、CQ
  · Post Send/Recv
  · 轮询 CQ
  · 不处理连接建立

librdmacm (rdma_*)：
  · 高层连接管理
  · 地址解析（IP → GID）
  · 连接建立（类似 TCP connect/accept）
  · 内部调用 libibverbs
  · 适合快速开发 RDMA 应用

典型用法：
  用 librdmacm 解析地址并建立连接
  用 CM private data 或应用控制面交换 addr、rkey 等元数据
  用 libibverbs 做数据传输（RDMA Read/Write）
```

### 3.2 完整 RDMA RC 连接流程

下面的代码是对象关系示意，不是可直接运行的完整程序。使用 RDMA CM 时，
通常由 `rdma_create_qp()` 把 CM ID、PD、CQ 和 QP 关联起来；
如果直接使用 `ibv_create_qp()`，应用还要自行交换 QPN、PSN、GID/LID 等参数，
并手动完成 `RESET → INIT → RTR → RTS` 状态迁移。

```c
#include <infiniband/verbs.h>
#include <rdma/rdma_cma.h>

/*
 * RDMA RC 连接建立流程：
 *
 * Server                          Client
 *   │                                │
 *   │ rdma_create_id()              │ rdma_create_id()
 *   │ rdma_bind_addr()              │
 *   │ rdma_listen()                 │
 *   │                                │ rdma_resolve_addr()
 *   │                                │ rdma_resolve_route()
 *   │                                │ rdma_connect()
 *   │ rdma_get_request()            │
 *   │ rdma_accept()                 │
 *   │                                │
 *   │ ═══ 连接建立完成 ═══           │
 */

/* 1. 创建 PD 和 CQ */
struct ibv_pd *pd = ibv_alloc_pd(context);
struct ibv_cq *cq = ibv_create_cq(context, 1024, NULL, NULL, 0);

/* 2. 注册 Memory Region */
void *buffer;  /* 普通页、hugepage 或其他可注册内存 */
struct ibv_mr *mr = ibv_reg_mr(pd, buffer, buf_size,
    IBV_ACCESS_LOCAL_WRITE |
    IBV_ACCESS_REMOTE_WRITE |
    IBV_ACCESS_REMOTE_READ);

/* mr->lkey = 本地访问密钥
 * mr->rkey = 远程访问密钥（告诉远端，远端用此 key 访问此 buffer）
 * mr->addr = buffer 的虚拟地址
 */

/* 3. 创建 QP (RC 模式) */
struct ibv_qp_init_attr qp_init = {
    .send_cq = cq,
    .recv_cq = cq,
    .cap = {
        .max_send_wr = 256,     /* 发送队列深度 */
        .max_recv_wr = 256,     /* 接收队列深度 */
        .max_send_sge = 4,      /* 每个 WR 最多 4 个 SG entry */
        .max_recv_sge = 4,
        .max_inline_data = 64,  /* inline 数据最大字节数 */
    },
    .qp_type = IBV_QPT_RC,     /* Reliable Connected */
};
struct ibv_qp *qp = ibv_create_qp(pd, &qp_init);

/* 4. 修改 QP 状态：RESET → INIT → RTR → RTS */
/* RDMA CM 可协助建立连接；纯 verbs 模式需调用 ibv_modify_qp() */
```

### 3.3 RDMA Write（单边操作）

```c
/*
 * RDMA Write：将本地数据写入远程内存。
 * 远端 CPU 不执行对应的 recv()，但应用仍需管理授权和通知。
 *
 * 前提：已经通过带外机制交换了远端的 addr 和 rkey。
 */
static inline int
rdma_write(struct ibv_qp *qp, struct ibv_mr *local_mr,
           uint64_t remote_addr, uint32_t remote_rkey,
           uint32_t len)
{
    struct ibv_sge sge = {
        .addr = (uint64_t)local_mr->addr,
        .length = len,
        .lkey = local_mr->lkey,
    };

    struct ibv_send_wr wr = {
        .wr_id = 1,             /* 用户自定义 ID，完成时返回 */
        .next = NULL,           /* 链式 WR 时指向下一个 */
        .sg_list = &sge,
        .num_sge = 1,
        .opcode = IBV_WR_RDMA_WRITE,
        .send_flags = IBV_SEND_SIGNALED,  /* 请求完成通知 */
        .wr = {
            .rdma = {
                .remote_addr = remote_addr,  /* 远端 MR 的虚拟地址 */
                .rkey = remote_rkey,         /* 远端 MR 的 RKey */
            },
        },
    };

    struct ibv_send_wr *bad_wr;
    return ibv_post_send(qp, &wr, &bad_wr);
}

/* 轮询完成事件 */
static inline int
poll_completion(struct ibv_cq *cq)
{
    struct ibv_wc wc;
    int n = ibv_poll_cq(cq, 1, &wc);

    if (n > 0) {
        if (wc.status != IBV_WC_SUCCESS) {
            /* 操作失败：检查 wc.status 和 wc.vendor_err */
            return -1;
        }
        return 0;  /* 成功 */
    }
    return 1;  /* 还没有完成 */
}
```

`ibv_post_send()` 返回成功只表示 WR 已经进入发送队列，不表示数据已经到达远端。
应用必须以 CQE 为完成边界，并根据 `wc.status`、`wc.opcode` 和 `wc.vendor_err`
处理远端访问错误、重试耗尽、QP 错误等情况。

### 3.4 RDMA Read（单边操作）

```c
/*
 * RDMA Read：从远程内存读取数据到本地。
 * 与 RDMA Write 方向相反，opcode 不同，其余类似。
 */
static inline int
rdma_read(struct ibv_qp *qp, struct ibv_mr *local_mr,
          uint64_t remote_addr, uint32_t remote_rkey,
          uint32_t len)
{
    struct ibv_sge sge = {
        .addr = (uint64_t)local_mr->addr,
        .length = len,
        .lkey = local_mr->lkey,
    };

    struct ibv_send_wr wr = {
        .wr_id = 2,
        .next = NULL,
        .sg_list = &sge,
        .num_sge = 1,
        .opcode = IBV_WR_RDMA_READ,    /* 唯一区别 */
        .send_flags = IBV_SEND_SIGNALED,
        .wr = {
            .rdma = {
                .remote_addr = remote_addr,
                .rkey = remote_rkey,
            },
        },
    };

    struct ibv_send_wr *bad_wr;
    return ibv_post_send(qp, &wr, &bad_wr);
}
```

### 3.5 完成、可见性与通知是三件事

RDMA 程序必须明确区分：

```text
post WR 成功
  → 只说明请求已提交

本地 CQE 成功
  → 说明该操作按 transport 语义完成

远端应用开始消费数据
  → 还需要应用层通知和所有权协议
```

对于普通 RDMA Write，远端不会自动获得一个“新消息已到达”的 CQE。
常见通知方式包括：

- RDMA Write with Immediate；
- Write 完成后再发送一条 Send 消息；
- 写入数据后更新带版本号的 doorbell/metadata；
- 由远端轮询一个约定的状态字。

不要仅用一个裸 flag 代替协议。需要定义数据写入顺序、状态字更新顺序、
缓冲区何时可复用，以及连接失败后的恢复方式。

### 3.6 RKey 是能力凭据，不是普通标识符

远端地址和 RKey 共同授予对 MR 的访问能力。工程上应遵循：

- 只注册需要暴露的最小内存范围；
- 只授予实际需要的 `REMOTE_READ`、`REMOTE_WRITE` 或 `REMOTE_ATOMIC` 权限；
- 不在日志、无认证控制面或不可信租户之间泄露 `addr + rkey`；
- 会话结束后撤销 MR/MW，长连接场景考虑轮换 Memory Window；
- 把 `IBV_WC_REM_ACCESS_ERR` 等远端访问错误作为安全和协议异常处理。

---

## 4. DPDK 与 RDMA 共存：Bifurcated Driver

### 4.1 mlx5 的 Bifurcated Driver 模型

这是理解 DPDK + RDMA 融合的关键。NVIDIA ConnectX 网卡使用
**bifurcated driver**（分叉驱动）模型：

```text
┌──────────────────────────────────────────────────────┐
│                   用户态                               │
│                                                       │
│  ┌──────────────┐  ┌──────────────┐  ┌────────────┐ │
│  │ DPDK 应用    │  │ RDMA 应用    │  │ SPDK 存储  │ │
│  │ mlx5 PMD     │  │ libibverbs   │  │ NVMe-oF    │ │
│  │ (收发以太网包)│  │ (RDMA R/W)   │  │ (块存储)   │ │
│  └──────┬───────┘  └──────┬───────┘  └─────┬──────┘ │
│         │                 │                 │         │
│  ┌──────▼─────────────────▼─────────────────▼──────┐ │
│  │           rdma-core / devx                      │ │
│  │   用户态库，提供 verbs 和设备访问接口            │ │
│  └──────────────────────┬─────────────────────────┘ │
└─────────────────────────┼───────────────────────────┘
                          │
┌─────────────────────────▼───────────────────────────┐
│                    内核态                              │
│                                                       │
│  ┌─────────────────────────────────────────────────┐ │
│  │           mlx5_core + mlx5_ib                    │ │
│  │  · 管理设备生命周期和固件                         │ │
│  │  · 提供 netdev 与 RDMA verbs 内核支持             │ │
│  │  · 注册为内核网络接口（eth0）                     │ │
│  │  · 管理 PCI 资源和中断                           │ │
│  └──────────────────────┬──────────────────────────┘ │
└─────────────────────────┼───────────────────────────┘
                          │
┌─────────────────────────▼───────────────────────────┐
│           NVIDIA ConnectX (PCIe)                     │
│  ┌──────────┐  ┌──────────┐  ┌──────────────┐      │
│  │ Ethernet │  │ RDMA     │  │ Flow Steering│      │
│  │ Queues   │  │ Transport│  │ / E-Switch   │      │
│  └──────────┘  └──────────┘  └──────────────┘      │
└─────────────────────────────────────────────────────┘
```

关键点：

- **mlx5_core 驱动不卸载**——不像 VFIO 模型那样从内核解绑
- DPDK mlx5 PMD 通过 **rdma-core / devx** 接口在用户态访问硬件
- RDMA 应用通过 **libibverbs** 访问同一设备
- DPDK、内核 netdev 和 RDMA 可以同时存在，具体流量归属由硬件 steering 和队列配置决定

DPDK 文档中的 bifurcated driver 首先描述的是：同一设备上的部分以太网流量进入
内核 netdev，另一些流量进入用户态 PMD。RDMA 共存建立在同一个基础上：
mlx5 内核驱动和 RDMA 设备保持存在，而 DPDK PMD 不要求独占 PCI 设备。

### 4.2 为什么不是 VFIO 模式

```text
其他常见 DPDK PMD 的 VFIO 模式：
  厂商内核驱动解绑 → vfio-pci 绑定 → DPDK 独占 PCI function
  · RDMA 不可用（内核驱动不在了）
  · 网络接口消失
  · 不适合需要 RDMA 的场景

Bifurcated 模式（mlx5）：
  mlx5_core 保持 → DPDK PMD 通过 devx 共享设备
  · RDMA 正常工作
  · 网络接口存在
  · DPDK 和 RDMA 各处理各的流量
```

> [!warning] 使用 DPDK mlx5 PMD 时不要照搬 VFIO 绑定流程
> mlx5 PMD 的正常模型要求设备继续由 mlx5 内核驱动管理。
> 如果把对应 PCI function 从 mlx5 驱动解绑并交给 `vfio-pci`，
> 该 function 上依赖内核 RDMA 设备和 netdev 的能力将不可用。
>
> 使用 DPDK mlx5 PMD 时，设备应该保持在 `mlx5_core` 驱动下，
> DPDK 通过 rdma-core/devx 用户态接口访问硬件。

### 4.3 验证 Bifurcated 模式

```bash
# 查看设备驱动（应该是 mlx5_core，不是 vfio-pci）
dpdk-devbind.py --status | grep mlx

# 查看 RDMA 设备
ibv_devinfo
# hca_id: mlx5_0
# transport: InfiniBand (原生或 RoCE)
# fw_ver: xx.xx.xxxx
# node_guid: xxxx:xxxx:xxxx:xxxx

# 查看以太网接口
ip link show | grep mlx

# 测试 RDMA 功能
ib_write_bw -d mlx5_0        # RDMA Write 带宽测试
ib_write_lat -d mlx5_0       # RDMA Write 延迟测试
ib_send_bw -d mlx5_0         # Send 带宽测试

# 同时运行 DPDK 应用
dpdk-testpmd -l 0-3 -a 0000:08:00.0 -- -i
```

仅看到 DPDK 和 RDMA 进程都能启动，不代表共存配置已经正确。还要验证：

- DPDK flow 是否意外截获了内核控制流量；
- RoCE 数据面是否使用预期的 netdev、GID index 和 traffic class；
- 两类工作负载同时加压时，是否争用链路、PCIe、内存带宽或 NIC queue context；
- DPDK 停止/重启端口时，硬件 flow 规则是否被清空并正确恢复。

### 4.4 共存不等于互不干扰

RDMA transport 在硬件中执行，不占用 DPDK PMD 的逐包处理核，但两者仍共享：

| 共享资源         | 可能表现                                    | 控制手段                           |
| ---------------- | ------------------------------------------- | ---------------------------------- |
| 链路带宽         | RDMA 大流量挤压普通以太网流量               | ETS、限速、流量分类                |
| NIC 队列与上下文 | QP、CQ、Rx/Tx queue 数量触及设备上限        | 容量规划、查询 device capabilities |
| PCIe             | 双向 DMA 接近平台上限                       | NUMA 对齐、PCIe 拓扑检查           |
| 内存带宽/LLC     | DPDK 轮询与 RDMA DMA 互相造成缓存和带宽压力 | 核隔离、NUMA 本地内存、实测        |
| Flow table       | 大量 `rte_flow` 规则消耗 steering 资源      | 规则预算、监控创建失败和老化       |

因此，共存验收必须包含“分别运行”和“同时运行”两组基准。

---

## 5. RDMA 性能特征

### 5.1 不要直接比较“RDMA 延迟”和“DPDK 延迟”

```text
RDMA latency benchmark:
  应用提交 WR → RNIC 执行远程内存操作 → CQE 返回

DPDK forwarding benchmark:
  包到达 Rx queue → CPU 解析/处理 → Tx queue 发出

TCP request/response benchmark:
  应用 API → 内核协议栈 → 对端应用 → 响应返回
```

三者的起点、终点和业务语义不同。把不同厂商宣传材料中的单向延迟放到同一张表，
会得到看似精确但无法指导选型的结论。正确做法是先定义：

- 单向还是往返；
- 消息大小和队列深度；
- 单 QP 还是多 QP；
- inline、signaled interval 和 CQ moderation；
- MTU、NUMA、CPU 频率、PCIe 代际和链路速率；
- 报告平均值还是 P50/P99/P99.9。

### 5.2 用 perftest 建立 RDMA 基线

先用相同硬件和拓扑分别测 latency、message rate 和 bandwidth：

```bash
# 服务端
ib_write_lat -d mlx5_0 -F -x <gid-index>

# 客户端
ib_write_lat -d mlx5_0 -F -x <gid-index> <server-ip>

# 64 KiB 持续带宽；服务端先启动同样的命令但不带 server-ip
ib_write_bw -d mlx5_0 -F -x <gid-index> \
  --report_gbits -s 65536 -q 4 -D 30 <server-ip>

# 对比 Read 和 Send/Recv
ib_read_bw ...
ib_send_bw ...
```

测试前记录：

```bash
ibv_devinfo
rdma link show
ethtool -i <netdev>
ethtool <netdev>
numactl --hardware
lspci -s <BDF> -vv
```

`gid-index`、命令参数和工具版本必须进入测试报告，否则结果难以复现。

### 5.3 吞吐瓶颈的判断顺序

```text
小消息：
  doorbell / WQE / CQE / PCIe transaction rate
  → 优先看 message rate、inline、batch 和 unsignaled 策略

大消息：
  link bandwidth / PCIe bandwidth / memory bandwidth
  → 优先看 Gbit/s、NUMA、PCIe width/speed 和多 QP 扩展

尾延迟抖动：
  retransmission / congestion / PFC pause / CPU scheduling
  → 结合 RNIC、交换机和主机计数器定位
```

CPU 利用率也必须说明计量口径。busy polling 会把一个核显示为 100%，
但这不等于每字节 CPU 成本高；中断模式可能显示较低平均利用率，却带来更高尾延迟。
建议同时报告：

- 每秒操作数或 Gbit/s；
- 每百万操作消耗的 CPU 时间；
- CQ polling 核与业务核分别占用多少；
- P50、P99、P99.9 延迟；
- RNIC 重传、ECN、pause 和错误计数。

---

## 6. NVMe-oF：RDMA 的典型应用

### 6.1 NVMe over Fabrics 架构

```text
NVMe-oF 把 NVMe 块存储命令通过 RDMA 传到远端：

  Initiator (客户端)                     Target (存储服务器)
  ┌─────────────────┐                   ┌─────────────────┐
  │ NVMe 驱动       │                   │ SPDK NVMe-oF    │
  │ (本地块设备)     │                   │ Target          │
  └────────┬────────┘                   └────────┬────────┘
           │                                     │
    NVMe-oF RDMA 传输                     NVMe 命令处理
           │                                     │
  ┌────────▼───────────────────────────────────▼────────┐
  │                    RDMA (RoCEv2)                     │
  │   NVMe 命令 → RDMA Send                              │
  │   数据传输 → RDMA Read/Write                          │
  └──────────────────────────────────────────────────────┘

  控制 capsule 通常通过 Send/Recv 传递；
  数据 payload 根据命令方向和传输协议，通过 RDMA Read/Write 搬运。
```

### 6.2 性能特征

NVMe-oF 的端到端结果不能只由 RNIC 型号推导。至少受以下因素影响：

- 后端 SSD 数量、介质延迟和 RAID/striping 方式；
- host queue 数、queue depth、I/O size 和读写比例；
- target poll group 与 SSD/RNIC 的 NUMA 位置；
- SPDK buffer cache、I/O unit size 和 max I/O size；
- 网络拥塞、重传、MTU 和 PCIe 拓扑。

对比 RDMA 与 TCP transport 时，必须使用同一批 SSD、相同 fio job、相同 queue depth
和相同 CPU 绑定，并同时报告 IOPS、带宽、平均延迟与高分位延迟。

### 6.3 SPDK 与 RDMA

SPDK（Storage Performance Development Kit）是 NVMe-oF target 的主流实现：

```text
SPDK + RDMA 数据路径：

  Initiator 发送 NVMe Read 命令
      │
      ▼ (RDMA Send)
  SPDK Target
      │
      ├─ 从 SSD 读取数据到 target buffer
      │
      └─ 通过 RDMA Write 将数据直接写入 initiator 内存
         （initiator CPU 不参与数据搬运）

  SPDK 的 I/O 数据路径主要运行在用户态，并常用轮询减少调度开销。
  设备发现、内存映射、RDMA verbs 和系统资源管理仍依赖内核基础设施。
```

最小 target 配置流程如下，参数需要根据实际 bdev 和网络修改：

```bash
# 编译时启用 RDMA
./configure --with-rdma
make -j

# 启动 target
build/bin/nvmf_tgt

# 创建 RDMA transport
scripts/rpc.py nvmf_create_transport -t RDMA \
  -u 8192 -i 131072 -c 8192

# 创建 subsystem、namespace 和 listener
scripts/rpc.py nvmf_create_subsystem nqn.2026-04.io.example:cnode1 \
  -a -s SPDK00000000000001
scripts/rpc.py nvmf_subsystem_add_ns \
  nqn.2026-04.io.example:cnode1 <bdev-name>
scripts/rpc.py nvmf_subsystem_add_listener \
  nqn.2026-04.io.example:cnode1 \
  -t rdma -a <target-ip> -s 4420
```

---

## 7. RDMA 性能调优

### 7.1 调优参数

| 参数                | 作用                                    | 调整原则                                       |
| ------------------- | --------------------------------------- | ---------------------------------------------- |
| **max_inline_data** | 小消息复制进 WQE，减少一次 NIC DMA read | 查询设备能力，对小消息 A/B 测试                |
| **Signaled 比例**   | 控制 CQE 数量和发送队列回收粒度         | 保证可回收 SQ，按延迟与吞吐折中                |
| **WR batching**     | 一次提交 WR 链，减少 doorbell/MMIO      | 批量过大会增加排队延迟                         |
| **max_send_wr**     | 控制在途请求和流水线深度                | 不超过设备能力，结合 queue depth 测试          |
| **MTU**             | 影响分包、效率和错误敏感度              | 端到端一致；区分 Ethernet MTU 与 IB active MTU |
| **NUMA 对齐**       | 减少跨 socket DMA 和内存访问            | RNIC、内存、polling core 尽量同一 NUMA node    |
| **Hugepage**        | 减少页表/MR 数量，便于大内存池管理      | 推荐用于大池，但不是 `ibv_reg_mr()` 硬性要求   |
| **MR cache / ODP**  | 降低频繁注册和撤销的控制面成本          | 长生命周期池用 MR cache，按硬件能力评估 ODP    |

### 7.2 Inline Data

```c
/*
 * Inline Data：小消息直接嵌入 WQE（Work Queue Entry），
 * 不需要额外的 DMA 操作。
 *
 * 适用场景：消息长度不超过创建 QP 时实际协商出的
 * max_inline_data。收益取决于消息大小、WQE 布局和 PCIe 压力。
 */
struct ibv_send_wr wr = {
    .sg_list = &sge,
    .num_sge = 1,
    .opcode = IBV_WR_SEND,
    .send_flags = IBV_SEND_INLINE,   /* 启用 inline */
    /* 数据直接从 sge.addr 拷贝到 WQE 中 */
};
```

Inline 会把数据从应用缓冲区复制到 WQE，因此并非“完全没有拷贝”。
它省掉的是 RNIC 对 payload buffer 的额外 DMA read。消息变大后，
WQE 占用和 CPU memcpy 成本可能抵消收益。

### 7.3 Signaled vs Unsignaled Completions

```text
每次操作都请求完成通知（IBV_SEND_SIGNALED）：
  · 每次操作产生一个 CQE
  · 可精确跟踪每个操作
  · CQE 处理开销大（cache miss + 轮询）

每 N 次操作请求一次完成通知：
  · 大部分操作不产生 CQE（unsignaled）
  · 每 N 次发一个 signaled WR
  · 用后续 signaled completion 推进发送队列回收边界
  · 错误可能让 QP 进入 error state，不能只按成功路径回收
  · N 没有通用值，必须小于可用 SQ 深度并经过压测

  代码模式：
  if ((counter % SIGNAL_INTERVAL) == 0)
      wr.send_flags = IBV_SEND_SIGNALED;
  else
      wr.send_flags = 0;
```

只发送 unsignaled WR 而从不处理 completion，最终会耗尽发送队列。
生产实现应追踪 outstanding WR、completion 边界和 QP error，并在销毁资源前
确保所有仍引用 buffer、AH、MR 的 WR 已经完成或被 flush。

### 7.4 Memory Registration：普通页也能注册

`ibv_reg_mr()` 并不要求地址来自 hugepage。真正的约束是：

- provider 能为该地址范围建立 DMA 映射；
- 进程拥有足够的 `RLIMIT_MEMLOCK` 或相应权限；
- MR 数量、页表和 MKey 没有超过设备/驱动限制；
- buffer 生命周期长于所有引用它的 WR。

检查 locked-memory 限制：

```bash
ulimit -l
cat /proc/<pid>/limits | grep -i locked
```

大规模内存池使用 hugepage 往往更高效，因为页数更少、注册元数据更少，
但按请求频繁 `ibv_reg_mr()`/`ibv_dereg_mr()` 通常比是否使用 hugepage 更致命。

### 7.5 SoftRoCE（RXE）：无硬件时的 RDMA

```bash
# 加载 SoftRoCE 模块
sudo modprobe rdma_rxe

# 在以太网接口上创建虚拟 RDMA 设备
sudo rdma link add rxe_eth0 type rxe netdev eth0

# 验证
rdma link show
ibv_devinfo
# 现在应该能看到 rxe_eth0

# 可以用 ibv_* 工具测试（但性能远低于硬件）
ib_write_bw -d rxe_eth0 -s 65536

# 删除
sudo rdma link delete rxe_eth0
```

RXE 的价值是验证 RDMA CM、QP 状态机、MR/RKey、WR/WC 和错误处理逻辑。
它走软件协议实现，性能和硬件能力不能代表 RNIC；不要用固定倍数推导生产结果，
也不要假定所有 opcode 能力都与目标硬件完全一致。

### 7.6 上线前检查清单

```text
主机：
  [ ] firmware、kernel、rdma-core、DPDK 版本组合受支持
  [ ] RNIC 与 polling core、内存位于期望 NUMA node
  [ ] memlock、hugepage/MR 策略、QP/CQ 容量已规划
  [ ] GID index、RoCE mode、MTU、DSCP/PCP 已记录

网络：
  [ ] 所有跳的 MTU 和 traffic class 映射一致
  [ ] ECN/DCQCN 参数经过拥塞压测
  [ ] 若启用 PFC，仅作用于目标优先级，并验证 pause storm 风险
  [ ] ECMP 不会让双向路径进入未配置的队列或链路

应用：
  [ ] RKey 权限最小化，断连后撤销授权
  [ ] CQE error、QP error、超时和重连路径经过故障注入
  [ ] buffer 生命周期与 completion 边界一致
  [ ] 单独负载和 DPDK+RDMA 混合负载都已测试
```

---

## 8. RDMA 与 DPDK 选型

### 8.1 决策框架

```text
你的应用做什么？
    │
    ├── 处理每个包（路由、ACL、NAT、LB）
    │     │
    │     └── DPDK
    │         每个包需要 CPU 参与，做解析和决策
    │
    ├── 搬运大块内存（存储、分布式内存、AI 参数同步）
    │     │
    │     └── RDMA
    │         CPU 不逐字节处理 payload，RNIC 直接 DMA
    │
    └── 两者都要（超融合节点：网络 + 存储）
          │
          └── DPDK + RDMA 共存
              mlx5 bifurcated driver
              同一张网卡，两条数据路径
```

### 8.2 选型对比

| 维度             | DPDK                           | RDMA                               |
| ---------------- | ------------------------------ | ---------------------------------- |
| 编程范式         | 包处理（每个包过 CPU）         | 已授权内存之间的数据搬运           |
| API              | rte_ethdev / rte_mbuf          | libibverbs / librdmacm             |
| 性能指标         | Mpps、Gbps、每包 cycles、延迟  | Mops、Gbps、CQE 与尾延迟           |
| CPU 参与         | 轮询、解析和逐包处理           | 提交、完成、同步和错误恢复         |
| 适用场景         | 网关、LB、防火墙、vSwitch      | NVMe-oF、分布式存储、AI 训练       |
| 典型硬件         | 任何 NIC                       | ConnectX / E810 / Chelsio          |
| 编程复杂度       | 中（熟悉的以太网模型）         | 高（QP 状态机、MR 注册）           |
| 灵活性           | 高（完全可编程）               | 低（硬件限制操作类型）             |
| 与内核协议栈共存 | 取决于 PMD；mlx5 可 bifurcated | 通过 RDMA 内核子系统与用户态 verbs |

---

## 9. 常见问题与排障

| 现象                      | 可能原因                                         | 排查方向                                   |
| ------------------------- | ------------------------------------------------ | ------------------------------------------ |
| `ibv_post_send` 返回错误  | QP 状态、WR/SGE 参数或 SQ 资源错误               | 看返回 errno、QP state、device capability  |
| CQE 为远端访问错误        | RKey、地址、权限或 MR 生命周期错误               | 检查 `wc.status/vendor_err` 与控制面元数据 |
| RDMA 连接建立失败         | GID/RoCE mode、路由、MTU、防火墙或 CM 配置不一致 | `rdma link`、`ibv_devinfo`、抓 CM 流量     |
| RDMA Write 性能低于预期   | queue depth、NUMA、PCIe、重传或 batch 不合适     | perftest 分层测试并检查硬件计数器          |
| RoCEv2 尾延迟抖动         | 拥塞、重传、ECN/PFC 参数或 pause storm           | RNIC + 交换机计数器联合分析                |
| DPDK 和 RDMA 冲突         | 设备绑到了 vfio-pci                              | `dpdk-devbind.py --status` 确认驱动        |
| CQ 轮询 CPU 占用高        | QP 过多、CQE 太大、没有批量处理                  | 减少 QP 数、合用 CQ、批量 poll             |
| MR 注册失败               | memlock、权限、地址范围或设备 MR/MKey 上限       | `ulimit -l`、日志、device capability       |
| `rdma link add` 失败      | `rdma_rxe` 未加载或 netdev 不支持                | `modprobe rdma_rxe`、检查内核日志          |
| NVMe-oF 延迟高            | SSD、NUMA、queue depth、transport 或拥塞         | 用 fio/SPDK 指标逐层拆分                   |
| ConnectX 上 DPDK 收不到包 | Bifurcated 模式下需要正确的 flow steering        | 检查 rte_flow 或 RSS 配置                  |

常用观测命令：

```bash
rdma resource show
rdma statistic show
ethtool -S <netdev>
cat /sys/class/infiniband/<device>/ports/<port>/counters/*
dmesg --level=err,warn
```

---

## 10. 总结

```text
RDMA 与 DPDK 的核心关系：

  同一张网卡，两条数据路径：
  ┌──────────────────────────────────────────┐
  │          NVIDIA ConnectX                 │
  │                                          │
  │  以太网包 → DPDK mlx5 PMD（CPU 处理）    │
  │  RDMA 操作 → RNIC 执行数据搬运          │
  │                                          │
  │  共享：mlx5_core 驱动 + rdma-core        │
  │  分离：各自的数据路径和 API               │
  └──────────────────────────────────────────┘

  DPDK：处理包 → 路由、ACL、NAT、LB
  RDMA：搬运内存 → NVMe-oF、分布式存储、AI 训练
  融合：Bifurcated driver 让两者在硬件层共存
```

关键要点：

1. **RDMA 不是更快的 DPDK**——RDMA 是内存访问范式，DPDK 是包处理范式
2. **RDMA Write/Read 是单边操作**——远端 CPU 不执行逐次接收，但应用仍需通知和所有权协议
3. **Bifurcated driver 是融合的关键**——mlx5_core 不卸载，DPDK 和 RDMA 共享设备
4. **RoCEv2 的 RC 仍然可靠重传**——PFC 不是协议硬要求，ECN、拥塞控制和监控更关键
5. **Memory Registration 是授权边界**——hugepage 常有收益，但不是注册内存的硬性条件
6. **NVMe-oF 是 RDMA 的典型应用**——端到端性能仍由 SSD、队列、NUMA 和网络共同决定
7. **SoftRoCE 适合功能验证**——不能用它推导硬件 RNIC 的性能和完整能力
8. **选型看应用类型**——包处理用 DPDK，内存搬运用 RDMA；ConnectX 同 PF 共存可用 bifurcated 模型

> **最重要的一点：DPDK 和 RDMA 不是"选哪个"的问题，而是"你的应用做什么"的问题。处理包用 DPDK，搬运内存用 RDMA，超融合节点两者共存。**

---

## 参考资料

### RDMA

- [rdma-core：libibverbs](https://github.com/linux-rdma/rdma-core/blob/master/Documentation/libibverbs.md)
- [rdma-core：librdmacm](https://github.com/linux-rdma/rdma-core/blob/master/Documentation/librdmacm.md)
- [`ibv_post_send(3)`](https://man7.org/linux/man-pages/man3/ibv_post_send.3.html)
- [`ibv_reg_mr(3)`](https://man7.org/linux/man-pages/man3/ibv_reg_mr.3.html)
- [`rdma-link(8)`](https://man7.org/linux/man-pages/man8/rdma-link.8.html)
- [InfiniBand Trade Association Specifications](https://www.infinibandta.org/ibta-specifications-download/)

### RoCE

- [NVIDIA RoCE Documentation](<https://docs.nvidia.com/networking/display/MLNXENv23101190LTS/RDMA+over+Converged+Ethernet+(RoCE)>)
- [RFC 5040 — A Remote Direct Memory Access Protocol Specification](https://datatracker.ietf.org/doc/html/rfc5040)
- [RFC 5041 — Direct Data Placement over Reliable Transports](https://datatracker.ietf.org/doc/html/rfc5041)
- [RFC 5044 — Marker PDU Aligned Framing for TCP](https://datatracker.ietf.org/doc/html/rfc5044)

### DPDK mlx5

- [DPDK mlx5 PMD](https://doc.dpdk.org/guides-26.03/nics/mlx5.html)
- [DPDK Linux Drivers Guide](https://doc.dpdk.org/guides-26.03/linux_gsg/linux_drivers.html)
- [rdma-core GitHub](https://github.com/linux-rdma/rdma-core)

### SPDK / NVMe-oF

- [SPDK Documentation](https://spdk.io/doc/)
- [SPDK NVMe-oF Target](https://spdk.io/doc/nvmf.html)
- [NVM Express Specifications](https://nvmexpress.org/specifications/)
