---
title: "RDMA 深度探索 (七)：队列对 (Queue Pair)"
date: 2026-04-13
tags: [rdma, series, queue-pair, QP, work-request, completion-queue, verbs]
description: "深入理解 RDMA 队列对 (QP) 的状态机、Work Request 结构、Completion Queue 机制，以及 QP 与 CQ、PD 的关联"
---

> [!info] RDMA 深度探索系列 0. [[2026-04-13-rdma-deep-dive-series-index|全栈学习路径总览]]
>
> 1. [[2026-04-13-rdma-deep-dive-ch1-rdma-overview|第一章：RDMA 概述]]
> 2. [[2026-04-13-rdma-deep-dive-ch2-rdma-architecture|第二章：RDMA 架构]]
> 3. [[2026-04-13-rdma-deep-dive-ch3-infiniband|第三章：InfiniBand 架构]]
> 4. [[2026-04-13-rdma-deep-dive-ch4-roce|第四章：RoCE v1/v2]]
> 5. [[2026-04-13-rdma-deep-dive-ch5-iwarp|第五章：iWARP]]
> 6. [[2026-04-13-rdma-deep-dive-ch6-roce-vs-iwarp|第六章：RoCE vs iWARP 对比]]
> 7. **第七章：队列对 (Queue Pair)**

---

## 1. QP 是什么？

**Queue Pair (QP)** 是 RDMA 通信的基本单元，由两个队列组成：

```
┌─────────────────────────────────────────────────────────┐
│                     Queue Pair (QP)                       │
│  ┌──────────────────────┐    ┌──────────────────────┐   │
│  │    Send Queue        │    │    Receive Queue     │   │
│  │  (Work Requests)     │    │  (Work Requests)     │   │
│  │                      │    │                      │   │
│  │  [WR 0]              │    │  [WR 0]              │   │
│  │  [WR 1]              │    │  [WR 1]              │   │
│  │  [WR 2]              │    │  [WR 2]              │   │
│  │       ...            │    │       ...            │   │
│  └──────────────────────┘    └──────────────────────┘   │
└─────────────────────────────────────────────────────────┘
           │                              │
           ▼                              ▼
    ┌──────────────────┐          ┌──────────────────┐
    │  Completion Queue │          │  Completion Queue │
    │      (CQ)        │          │      (CQ)        │
    └──────────────────┘          └──────────────────┘
```

- **Send Queue**：存放发送端的 Work Request (WR)
- **Receive Queue**：存放接收端的 Work Request (WR)
- 每个 QP 关联一个 **Completion Queue (CQ)** 用于接收完成通知

QP 是 RDMAverbs 编程中最核心的数据结构。所有 RDMA 操作（Send/Recv、RDMA Read/Write、Atomic）都通过 QP 执行。

---

## 2. Work Request (WR) 与 Work Queue Entry (WQE)

### 2.1 基本结构

Work Request (WR) 是用户向队列提交的操作请求。硬件从队列中取出 WR 并执行。

```c
struct ibv_send_wr {
    uint64_t              wr_id;       // 用户自定义 ID，用于追踪
    struct ibv_send_wr   *next;        // 链表 next（多个 WR 可一次提交）
    struct ibv_sge       *sg_list;     // scatter/gather 数组
    int                    num_sge;     // sg_list 元素数量

    uint32_t              opcode;      // 操作类型
    int                    send_flags; // IBV_SEND_FENCE 等标志

    // RDMA 相关字段
    uint64_t              remote_addr; // 远端虚拟地址 (RDMA Read/Write)
    uint32_t              rkey;        // 远端 rkey (RDMA Read/Write)
    union {
        // Atomic 操作
        uint64_t          compare_add;
        uint64_t          swap;
    };

    // UD (Unreliable Datagram) 相关
    uint32_t              imm_data;    // 立即数
    union {
        struct {
            uint32_t      slid;        // 源 LID (接收时填充)
            uint32_t      dlid;        // 目的 LID (接收时填充)
        } grh;
    };
};

struct ibv_recv_wr {
    uint64_t              wr_id;
    struct ibv_recv_wr   *next;
    struct ibv_sge       *sg_list;
    int                    num_sge;
};
```

### 2.2 Scatter/Gather Entry (SGE)

SGE 允许一次描述多个内存片段，减少 memcpy：

```c
struct ibv_sge {
    uint64_t  addr;   // 内存地址
    uint32_t  length; // 长度
    uint32_t  lkey;   // 本地 lkey（已注册内存的密钥）
};
```

示例：使用 SGE 发送一个 64B 头部 + 1400B 载荷（无需额外拷贝）：

```
┌─────────────────────────────────────────────────────┐
│ sg_list[0]: addr=header_buf,  length=64,   lkey=x   │
│ sg_list[1]: addr=payload_buf, length=1400, lkey=y  │
└─────────────────────────────────────────────────────┘
 Hardware 直接从两个分散的内存区域读取，组成单一报文
```

### 2.3 Opcode 类型

| Opcode                        | 操作              | 方向      | 语义                                |
| ----------------------------- | ----------------- | --------- | ----------------------------------- |
| `IBV_WR_SEND`                 | 发送              | Two-sided | 发送数据，接收方必须已 post Recv WR |
| `IBV_WR_SEND_WITH_IMM`        | 发送+立即数       | Two-sided | 发送数据 + 32bit 立即数             |
| `IBV_WR_RDMA_READ`            | RDMA Read         | One-sided | 从远端读取（远端 CPU 无感知）       |
| `IBV_WR_RDMA_WRITE`           | RDMA Write        | One-sided | 写入远端内存（远端 CPU 无感知）     |
| `IBV_WR_RDMA_WRITE_WITH_IMM`  | RDMA Write+立即数 | One-sided | 写入 + 立即数                       |
| `IBV_WR_ATOMIC_CMP_AND_SWP`   | CAS               | One-sided | 原子比较并交换                      |
| `IBV_WR_ATOMIC_FETCH_AND_ADD` | Fetch & Add       | One-sided | 原子 Fetch & Add                    |

---

## 3. Completion Queue (CQ)

### 3.1 CQ 机制

Completion Queue (CQ) 存放 Work Completion (WC)，即 WR 执行结果的通知：

```c
struct ibv_wc {
    uint64_t           wr_id;      // 对应 WR 的 wr_id
    enum ibv_wc_status status;     // 状态：成功或错误码
    enum ibv_wc_opcode opcode;     // 操作类型
    uint32_t           vendor_err; // 厂商特定错误
    uint32_t           byte_len;   // 实际传输字节数

    union {
        uint32_t      imm_data;   // 接收到的立即数 (network byte order)
        uint32_t      invalidated_rkey; // Atomic 操作后失效的 rkey
    };

    uint16_t           qp_num;     // QP 编号
    /* ... 其他字段 ... */
};
```

### 3.2 Polling 模式

RDMA 应用通常轮询 CQ 而非使用中断（降低延迟）：

```c
// 阻塞轮询
struct ibv_wc wc;
int ne = ibv_poll_cq(cq, 1, &wc);
if (ne > 0) {
    if (wc.status == IBV_WC_SUCCESS) {
        printf("WR %lu 完成，传输 %u 字节\n", wc.wr_id, wc.byte_len);
    } else {
        printf("错误: %s\n", ibv_wc_status_str(wc.status));
    }
}
```

### 3.3 轮询 vs 中断

| 特性     | Polling              | 中断               |
| -------- | -------------------- | ------------------ |
| 延迟     | 微秒级（无中断开销） | 毫秒级（中断处理） |
| CPU 占用 | 持续占用一个 core    | 按需唤醒           |
| 吞吐     | 高（适合高频场景）   | 低（适合低频场景） |
| 能耗     | 高                   | 低                 |
| 典型场景 | HPC、AI 训练         | 通用存储、网络     |

---

## 4. QP 状态机

QP 是有状态的，状态转换遵循 InfiniBand 规范：

```
                  ┌─────────────────────────────────────────┐
                  │                                         │
                  ▼                                         │
    ┌─────────┐   CREATE   ┌─────────────────────────────┐  │
    │  RESET  │ ─────────► │         INIT                │  │
    └─────────┘            │                             │  │
                          │  INIT → RTR (Ready to Receive) │ │
    RST ←──────────────────┴─────────────────────────────┘  │
                                                          │
                           RTR → RTS (Ready to Send)      │
                                                          │
    ┌──────────────────────────────────────────────────┐  │
    │                     RTS                           │  │
    │  ←── Error / Timeout                              │  │
    │                                                  │  │
    │  RTS → SQ_DRAINED → SQE (Send Queue Empty)      │  │
    │  SQE → RTS                                        │  │
    └──────────────────────────────────────────────────┘  │
                           │                    ▲
                           │ RTS → ERROR        │
                           ▼                    │
    ┌────────────────────────────────────────┐    │
    │              ERROR                      │────┘
    └────────────────────────────────────────┘

    特殊状态：
    ┌─────────┐   DRAIN   ┌────────────┐   DRAIN   ┌──────────┐
    │  RTS    │ ────────► │ SQ_DRAINED │ ────────► │ SQE      │
    └─────────┘           └────────────┘           └──────────┘
```

### 4.1 各状态说明

| 状态         | 说明                           | 可执行操作       |
| ------------ | ------------------------------ | ---------------- |
| `RESET`      | QP 初始状态，队列为空          | 创建、销毁       |
| `INIT`       | 已初始化，尚未准备收发         | Modify QP to RTR |
| `RTR`        | Ready to Receive，已准备好接收 | Modify QP to RTS |
| `RTS`        | Ready to Send，可以发送 WQE    | 正常收发         |
| `SQ_DRAINED` | 发送队列已排空                 | 等待 ACK/NACK    |
| `SQE`        | Send Queue Error               | Recovery         |
| `ERROR`      | 错误状态                       | 销毁或 Reset     |

### 4.2 典型状态转换代码

```c
// 1. 创建 QP
struct ibv_qp *qp = ibv_create_qp(pd, &qp_init_attr);

// 2. INIT → RTR
qp_attr.qp_state        = IBV_QPS_RTR;
qp_attr.path_mtu        = IBV_MTU_4096;
qp_attr.dest_qp_num     = remote_qp_num;  // 对方 QP 号
qp_attr.rq_psn          = 0;
qp_attr.max_dest_rd_atomic = 16;
ibv_modify_qp(qp, &qp_attr, IBV_QP_STATE | IBV_QP_AV |
              IBV_QP_PATH_MTU | IBV_QP_DEST_QPN | IBV_QP_RQ_PSN |
              IBV_QP_MAX_DEST_RD_ATOMIC);

// 3. RTR → RTS
qp_attr.qp_state        = IBV_QPS_RTS;
qp_attr.sq_psn          = 0;
qp_attr.max_rd_atomic   = 16;
ibv_modify_qp(qp, &qp_attr, IBV_QP_STATE | IBV_QP_SQ_PSN |
              IBV_QP_MAX_RD_ATOMIC);
```

---

## 5. QP 与其他对象的关系

```
┌───────────────────────────────────────────────────────────────┐
│                        Protection Domain (PD)                  │
│  ┌─────────────┐  ┌─────────────┐  ┌────────────────────┐    │
│  │  QP 1       │  │  QP 2       │  │  Memory Region 1   │    │
│  │  Send Q     │  │  Send Q     │  │  (MR)              │    │
│  │  Recv Q     │  │  Recv Q     │  │  lkey=rkey         │    │
│  │  ↕ CQ 1     │  │  ↕ CQ 2     │  │                    │    │
│  └─────────────┘  └─────────────┘  └────────────────────┘    │
│         │                │                                    │
│         └────────┬───────┘                                    │
│                  │ shared by PD                               │
└──────────────────┼────────────────────────────────────────────┘
                   │
┌──────────────────┼────────────────────────────────────────────┐
│            HCA (Host Channel Adapter)                         │
│  所有 QP 共享 HCA 的硬件资源：端口、QP 上下文、硬件队列        │
└──────────────────────────────────────────────────────────────┘
```

- **PD (Protection Domain)**：隔离资源，QP 只能访问同一 PD 内的 MR
- **CQ**：可以多个 QP 共享一个 CQ（节省资源），或每个 QP 独立 CQ
- **MR**：QP 通过 lkey/rkey 访问已注册内存

---

## 6. 实际使用示例

### 6.1 创建 QP 完整流程

```c
// 分配 CQ
struct ibv_cq *cq = ibv_create_cq(ctx, 128, NULL, NULL, 0);

// 创建 QP
struct ibv_qp_init_attr qp_attr = {
    .send_cq = cq,
    .recv_cq = cq,
    .cap     = {
        .max_send_wr  = 128,
        .max_recv_wr  = 128,
        .max_send_sge = 16,
        .max_recv_sge = 16,
    },
    .qp_type = IBV_QPT_RC,  // Reliable Connection
};
struct ibv_qp *qp = ibv_create_qp(pd, &qp_attr);

// Post Recv WR (接收侧准备)
struct ibv_recv_wr recv_wr = {
    .wr_id   = 1,
    .sg_list = &sge,
    .num_sge = 1,
};
ibv_post_recv(qp, &recv_wr, &bad_wr);

// Post Send WR (发送侧触发)
struct ibv_send_wr send_wr = {
    .wr_id   = 2,
    .opcode  = IBV_WR_SEND,
    .sg_list = &sge,
    .num_sge = 1,
    .send_flags = IBV_SEND_SIGNALED,  // 需要 CQE 通知
};
ibv_post_send(qp, &send_wr, &bad_wr);
```

### 6.2 ibv_post_send 标志位

| 标志                 | 说明                                     |
| -------------------- | ---------------------------------------- |
| `IBV_SEND_FENCE`     | 之前的所有 Send WR 必须在此之前完成      |
| `IBV_SEND_SIGNALED`  | 产生 Completion（更新 CQ）               |
| `IBV_SEND_SOLICITED` | 使用Solicited 事件（对方收到时产生通知） |
| `IBV_SEND_INLINE`    | 数据内联在 WQE 中（不额外 DMA）          |

---

## 7. 多 QP 架构

高性能应用通常为每个连接分配独立 QP：

```
┌─────────────────────────────────────────────────────┐
│              单进程多 QP 架构                       │
│                                                      │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐             │
│  │ QP 0    │  │ QP 1    │  │ QP 2    │  ...       │
│  │ ↕ CQ 0  │  │ ↕ CQ 1  │  │ ↕ CQ 2  │             │
│  └─────────┘  └─────────┘  └─────────┘             │
│     连接 0      连接 1       连接 2                  │
│                                                      │
│  每个 QP 独立轮询，减少锁竞争                         │
└─────────────────────────────────────────────────────┘
```

SR-IOV 虚拟化场景下，一个物理网卡可虚拟出多个 VF，每个 VF 包含独立 QP 集合。

---

## 8. 常见问题

**Q: QP 数量有限制吗？**
A: 有。HCA 通常支持 1K~16K 个 QP（取决于硬件）。创建过多 QP 会耗尽硬件资源。

**Q: 为什么需要多个 CQ？**
A: 分离发送/接收完成通知，允许独立处理发送完成和接收事件，减少事件处理复杂度。

**Q: QP 的 sq_psn 和 rq_psn 是什么？**
A: Packet Sequence Number (PSN)，用于可靠传输的顺序保证。每个 QP 有独立的 send PSN 和 receive PSN。
