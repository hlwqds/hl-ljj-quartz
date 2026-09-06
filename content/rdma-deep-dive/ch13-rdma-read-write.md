---
title: "RDMA 深度探索 (十三)：RDMA Send/Recv vs RDMA Read/Write"
date: 2026-04-13
tags: [rdma, series, send-recv, rdma-read, rdma-write, one-sided, two-sided, zero-copy]
description: "深入对比 RDMA 双边操作 (Send/Recv) 与单边操作 (RDMA Read/Write)，解析何时选用何种操作，以及性能差异的根源"
---

> [!info] RDMA 深度探索系列 0. [[rdma-deep-dive|全栈学习路径总览]]
>
> 1. [[ch1-rdma-overview|第一章：RDMA 概述]]
> 2. [[ch2-rdma-architecture|第二章：RDMA 架构]]
> 3. [[ch3-infiniband|第三章：InfiniBand 架构]]
> 4. [[ch4-roce|第四章：RoCE v1/v2]]
> 5. [[ch5-iwarp|第五章：iWARP]]
> 6. [[ch6-roce-vs-iwarp|第六章：RoCE vs iWARP 对比]]
> 7. [[ch7-queue-pair|第七章：队列对 (QP)]]
> 8. [[ch8-mr-pd|第八章：内存区域与保护域]]
> 9. [[ch9-verbs-api|第九章：Verbs API]]
> 10. [[ch10-ud-rc|第十章：UD vs RC 传输类型]]
> 11. [[ch11-atomics|第十一章：RDMA 原子操作]]
> 12. [[ch12-rdma-programming|第十二章：RDMA 编程起步]]
> 13. **第十三章：RDMA Send/Recv vs RDMA Read/Write**

---

## 1. 两种操作类型总览

### 1.1 术语定义

| 术语       | 英文      | 说明                                                       |
| ---------- | --------- | ---------------------------------------------------------- |
| 双边操作   | Two-sided | 需要收发双方参与，发送方 post Send WR，接收方 post Recv WR |
| 单边操作   | One-sided | 仅发送方参与，远端 CPU 无感知，像访问本地内存一样访问远端  |
| Send/Recv  | -         | 双边消息传递，接收方必须事先准备 Recv WR                   |
| RDMA Read  | -         | 单边读，从远端内存读取数据                                 |
| RDMA Write | -         | 单边写，向远端内存写入数据                                 |

```
┌─────────────────────────────────────────────────────────────┐
│                    双边操作 (Send/Recv)                      │
│                                                             │
│  Node A (Sender)              Node B (Receiver)             │
│  ┌─────────────────┐         ┌─────────────────┐           │
│  │ post_send(sg_list)│       │ post_recv(sg_list)│          │
│  └────────┬──────────┘         └────────┬──────────┘           │
│           │                             │                    │
│           │  ┌─────────────────────┐    │                    │
│           ├─►│  RDMA 网络传输      │───►│                    │
│           │  └─────────────────────┘    │                    │
│           │                             │                    │
│           ▼                             ▼                    │
│  ┌─────────────────┐         ┌─────────────────┐           │
│  │ 完成通知 (WC)    │         │ 数据写入 buffer  │           │
│  │                  │         │ 完成通知 (WC)    │           │
│  └─────────────────┘         └─────────────────┘           │
│                                                             │
│  特点：                                                     │
│  - 双方都需要参与（接收方必须准备 Recv WR）                  │
│  - 接收方 CPU 感知数据到达（可中断处理）                     │
│  - 类似传统网络 socket 语义                                  │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                    单边操作 (RDMA Read/Write)                │
│                                                             │
│  Node A (主动端)          RDMA 网络          Node B (被动端) │
│  ┌─────────────────┐                        ┌─────────────────┐
│  │ post_send(RDMA) │                        │ 无任何操作！     │
│  │ - remote_addr   │──────┬───────────────►│                 │
│  │ - rkey          │      │                │                 │
│  └────────┬──────────┘      │                └────────▲────────┘
│           │                 │                         │
│           ▼                 │                         │
│  ┌─────────────────┐         │                         │
│  │ 完成通知 (WC)    │         │                         │
│  └─────────────────┘         │                         │
│                                │                         │
│  直接读写远端内存，无须对方 CPU 参与                         │
│                                                             │
│  特点：                                                     │
│  - 远端 CPU 完全无感知                                      │
│  - 发送方控制整个数据流动                                    │
│  - 延迟更低（省去通知机制）                                  │
│  - 类似 DMA 引擎操作                                         │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 支持的操作类型

| QP 类型 | Send/Recv | RDMA Read | RDMA Write | Atomic |
| ------- | --------- | --------- | ---------- | ------ |
| RC      | ✅        | ✅        | ✅         | ✅     |
| UD      | ✅        | ❌        | ❌         | ❌     |
| UC      | ✅        | ❌        | ✅         | ❌     |

---

## 2. Send/Recv (双边操作)

### 2.1 工作原理

Send/Recv 是传统的消息传递模型：

```
时序图：

  Node A (Sender)              Node B (Receiver)
  post_recv() ──────────────►  Buffer 已准备
  (准备接收)

  post_send() ──────────────►  数据到达
       │                           │
       │                           ▼
       │                      数据写入 buffer
       │                      post_recv() 完成
       │                           │
       ◄───────────────────── ACK ─┘
  post_send() 完成
```

### 2.2 代码示例

```c
// ===== 接收端 =====
// 1. 准备接收 Buffer
struct ibv_sge sge = {
    .addr = (uint64_t)recv_buf,
    .length = BUF_SIZE,
    .lkey = mr->lkey,
};

struct ibv_recv_wr wr = {
    .wr_id = (uint64_t)1,
    .sg_list = &sge,
    .num_sge = 1,
};

ibv_post_recv(qp, &wr, &bad_wr);

// 2. 轮询完成
struct ibv_wc wc;
while (1) {
    int ne = ibv_poll_cq(cq, 1, &wc);
    if (ne > 0) {
        if (wc.status == IBV_WC_SUCCESS) {
            printf("Received %d bytes\n", wc.byte_len);
            break;
        }
    }
}

// ===== 发送端 =====
// 1. 填充发送数据
memcpy(send_buf, "Hello RDMA", 10);

// 2. Post Send WR
struct ibv_sge sge = {
    .addr = (uint64_t)send_buf,
    .length = 10,
    .lkey = mr->lkey,
};

struct ibv_send_wr wr = {
    .wr_id = (uint64_t)2,
    .opcode = IBV_WR_SEND,
    .sg_list = &sge,
    .num_sge = 1,
    .send_flags = IBV_SEND_SIGNALED,  // 需要完成通知
};

ibv_post_send(qp, &wr, &bad_wr);

// 3. 轮询发送完成
while (1) {
    int ne = ibv_poll_cq(cq, 1, &wc);
    if (ne > 0 && wc.status == IBV_WC_SUCCESS) {
        printf("Send completed\n");
        break;
    }
}
```

### 2.3 接收端未准备 Recv WR

如果接收端没有预先 post Recv WR：

```
┌─────────────────────────────────────────────────────────────┐
│                    RNR 错误 (Receiver Not Ready)            │
│                                                             │
│  Node A (Sender)              Node B (Receiver)             │
│  post_send() ──────────────►  ??? (没有 post_recv)          │
│       │                           │                         │
│       │                           ▼                         │
│       │                      [丢弃报文]                     │
│       │                           │                         │
│       ◄──────────────────── NAK (RNR) ─┘                    │
│  重传 (根据 retry_count 配置)                                │
│       │                                                     │
│       ▼                                                     │
│  可能最终失败: IBV_WC_RNR_RETRY_EXC_ERR                     │
└─────────────────────────────────────────────────────────────┘
```

处理方式：

```c
// 接收错误
if (wc.status == IBV_WC_RNR_RETRY_EXC_ERR) {
    printf("Receiver not ready, waiting...\n");
    // 重新 post_recv() 并等待重传
}

// 发送端也需要处理 RNR 错误（连接参数中的 retry_count）
```

---

## 3. RDMA Read (单边读)

### 3.1 工作原理

RDMA Read 像 DMA 一样从远端读取数据，远端 CPU 完全无感知：

```
Node A 读取 Node B 的 memory[0x1000..0x100F]

  Node A (主动端)                         Node B (被动端)
  ┌──────────────────┐                  ┌──────────────────┐
  │ 发起 RDMA Read:                         │                  │
  │   remote_addr = 0x1000                 │                  │
  │   rkey = B 的 rkey                      │                  │
  │   local_addr = A 的本地 buffer         │                  │
  └────────┬─────────┘                  └────────┬─────────┘
           │                                       │
           │  RDMA Read Request ──────────────────►│
           │  (包含: addr, rkey, len)              │ 无 CPU 中断
           │                                       ▼
           │                               [读取 memory]
           │                                       │
           │  RDMA Read Response ◄────────────────┤
           │  (携带数据)                           │
           │                                       │
           ▼                                       │
  数据已写入 A 的本地 buffer                          │
  WC 通知完成                                         │
```

### 3.2 代码示例

```c
// RDMA Read 前需要知道远端信息（通过连接建立时交换获得）
struct peer_info {
    uint32_t qp_num;
    uint32_t rkey;          // 远端的 rkey
    uint64_t remote_addr;   // 远端 buffer 地址
};

// RDMA Read 操作
void rdma_read(struct ibv_qp *qp, struct peer_info *peer,
               void *local_buf, struct ibv_mr *local_mr) {

    struct ibv_sge sge = {
        .addr = (uint64_t)local_buf,
        .length = 64,
        .lkey = local_mr->lkey,
    };

    struct ibv_send_wr wr = {
        .wr_id = 100,
        .opcode = IBV_WR_RDMA_READ,
        .sg_list = &sge,
        .num_sge = 1,
        .send_flags = IBV_SEND_SIGNALED,

        // RDMA Read 特定字段
        .rdma.remote_addr = peer->remote_addr,  // 远端地址
        .rdma.rkey = peer->rkey,                 // 远端 rkey
    };

    struct ibv_send_wr *bad_wr;
    ibv_post_send(qp, &wr, &bad_wr);
}

// 轮询完成
void wait_for_completion(struct ibv_cq *cq) {
    struct ibv_wc wc;
    while (1) {
        int ne = ibv_poll_cq(cq, 1, &wc);
        if (ne > 0) {
            if (wc.status == IBV_WC_SUCCESS && wc.wr_id == 100) {
                printf("RDMA Read completed, %d bytes\n", wc.byte_len);
                break;
            }
        }
    }
}
```

### 3.3 读取大块数据

RDMA Read 可以一次性读取大块数据（受 MTU 限制）：

```c
// 分段读取大块数据
size_t read_large_block(struct peer_info *peer,
                        void *local_buf, size_t size) {
    const size_t CHUNK = 1024 * 1024;  // 1MB per operation
    size_t total = 0;

    while (total < size) {
        size_t chunk = (size - total > CHUNK) ? CHUNK : (size - total);

        struct ibv_sge sge = {
            .addr = (uint64_t)(local_buf + total),
            .length = chunk,
            .lkey = local_mr->lkey,
        };

        struct ibv_send_wr wr = {
            .opcode = IBV_WR_RDMA_READ,
            .sg_list = &sge,
            .num_sge = 1,
            .rdma.remote_addr = peer->remote_addr + total,
            .rdma.rkey = peer->rkey,
        };

        ibv_post_send(qp, &wr, &bad_wr);
        wait_for_completion(cq);
        total += chunk;
    }

    return total;
}
```

---

## 4. RDMA Write (单边写)

### 4.1 工作原理

RDMA Write 向远端内存写入数据，同样不需要远端 CPU 参与：

```
Node A 写入 Node B 的 memory[0x2000..0x200F]

  Node A (主动端)                         Node B (被动端)
  ┌──────────────────┐                  ┌──────────────────┐
  │ 发起 RDMA Write:                        │                  │
  │   remote_addr = 0x2000                 │                  │
  │   rkey = B 的 rkey                      │                  │
  │   data = "Hello..."                     │                  │
  └────────┬─────────┘                  └────────┬─────────┘
           │                                       │
           │  RDMA Write Request ──────────────────►│
           │  (包含: addr, rkey, data)              │ 无 CPU 中断
           │                                       ▼
           │                               [写入 memory]
           │                                       │
           │  [可选: ACK]                          │
           │                                       │
           ▼                                       │
  WC 通知完成 (单边，无须对方响应)                       │
```

### 4.2 代码示例

```c
// RDMA Write
void rdma_write(struct ibv_qp *qp, struct peer_info *peer,
                void *local_buf, struct ibv_mr *local_mr,
                uint64_t remote_offset, size_t len) {

    struct ibv_sge sge = {
        .addr = (uint64_t)local_buf,
        .length = len,
        .lkey = local_mr->lkey,
    };

    struct ibv_send_wr wr = {
        .wr_id = 200,
        .opcode = IBV_WR_RDMA_WRITE,
        .sg_list = &sge,
        .num_sge = 1,
        .send_flags = IBV_SEND_SIGNALED,

        .rdma.remote_addr = peer->remote_addr + remote_offset,
        .rdma.rkey = peer->rkey,
    };

    struct ibv_send_wr *bad_wr;
    ibv_post_send(qp, &wr, &bad_wr);
}
```

### 4.3 RDMA Write with Immediate

带立即数的 RDMA Write，可用于通知远端数据已写入：

```c
// 写入数据 + 发送通知
void rdma_write_with_imm(struct ibv_qp *qp, struct peer_info *peer,
                         void *local_buf, size_t len, uint32_t imm) {

    struct ibv_send_wr wr = {
        .opcode = IBV_WR_RDMA_WRITE_WITH_IMM,
        .sg_list = &sge,
        .num_sge = 1,
        .imm_data = imm,  // 立即数 (网络字节序)

        .rdma.remote_addr = peer->remote_addr,
        .rdma.rkey = peer->rkey,
    };

    ibv_post_send(qp, &wr, &bad_wr);
}

// 接收端：接收 IMM 数据
// 接收端收到 IBV_WC_RECV_RDMA_WITH_IMM，此时imm_data 有效
```

---

## 5. 性能对比

### 5.1 延迟对比

```
单边 vs 双边延迟对比 (典型 ConnectX-7, 100Gb/s)

┌──────────────────────────────────────────────────────────────┐
│  Send/Recv (双边):                                            │
│                                                              │
│  Client          Server                                       │
│    │─── SEND ────────►│  ~1.5μs                             │
│    │◄── ACK ──────────│                                      │
│                                                              │
│  总延迟: ~1.5μs (单向)                                         │
│                                                              │
├──────────────────────────────────────────────────────────────┤
│  RDMA Read (单边):                                            │
│                                                              │
│  Client          Server                                       │
│    │─── RDMA READ ───►│  ~1.2μs (更低的延迟)                  │
│    │◄── DATA ─────────│                                      │
│                                                              │
│  总延迟: ~1.2μs (单向)                                         │
│                                                              │
├──────────────────────────────────────────────────────────────┤
│  RDMA Write (单边):                                           │
│                                                              │
│  Client          Server                                       │
│    │─── RDMA WRITE ─►│  ~1.0μs (最低延迟)                   │
│    │    (带数据)      │                                      │
│    │◄── [ACK 可选] ───│                                      │
│                                                              │
│  总延迟: ~1.0μs (单向)                                         │
└──────────────────────────────────────────────────────────────┘

注意：以上为微秒级估算，实际延迟受网络距离、拥塞、CPU 等因素影响
```

### 5.2 CPU 参与度对比

| 特性       | Send/Recv        | RDMA Read        | RDMA Write       |
| ---------- | ---------------- | ---------------- | ---------------- |
| 发送方 CPU | 参与 (post_send) | 参与 (post_send) | 参与 (post_send) |
| 接收方 CPU | 参与 (处理到达)  | **不参与**       | **不参与**       |
| 中断/回调  | 双方都需要       | 仅发送方         | 仅发送方         |
| 内存拷贝   | 1次 (用户→内核)  | 0次 (DMA 直通)   | 0次 (DMA 直通)   |

### 5.3 带宽利用率

```
带宽利用率对比 (100Gb/s InfiniBand)

RDMA Write:  接近 100% (单边，无 ACK 等待)
RDMA Read:   ~70-80% (需要请求+响应 round-trip)
Send/Recv:   ~60-70% (双边确认开销)

理想场景: 大块顺序传输
  RDMA Write >>> RDMA Read > Send/Recv
```

---

## 6. 何时使用何种操作

### 6.1 决策树

```
                    需要通信
                       │
                       ▼
           ┌───────────────────────┐
           │ 数据传输需要远端感知吗？│
           └───────────────────────┘
                    │
          ┌─────────┴─────────┐
          │ Yes                │ No
          ▼                    ▼
    Send/Recv            单边操作
          │
          ▼
    ┌─────────────────┐
    │ 需要广播/多播吗？ │
    └─────────────────┘
          │
    ┌─────┴─────┐
    │ Yes       │ No
    ▼           ▼
    UD        RC
```

### 6.2 典型场景

| 场景               | 推荐操作   | 原因                         |
| ------------------ | ---------- | ---------------------------- |
| HPC MPI AllReduce  | RDMA Write | 高带宽、低延迟、无须远端感知 |
| AI 训练 NCCL       | RDMA Write | GPU 数据直接传输             |
| 分布式键值存储 PUT | Send/Recv  | 需要远端确认写入成功         |
| 分布式键值存储 GET | RDMA Read  | 只读操作，远端无感知         |
| 分布式锁           | Atomic     | 原子操作保证一致性           |
| 批量数据传输       | RDMA Write | 最大化带宽利用率             |

### 6.3 实际应用：HPC 场景

```
AI 训练中的数据传输：

  GPU 0 ─────── RDMA Write ──────► GPU 1
   │                                  │
   │◄─────── RDMA Write ◄────────────│
   │                                  │
   │◄─────── RDMA Write ◄────────────│
   │                                  │
   ◄──────── Ring AllReduce ─────────►

特点：
- 数据直接从 GPU 内存发出 (需要 GPU Direct RDMA)
- 无须对端 CPU/GPU 参与数据传输
- 极低延迟保证训练迭代速度
```

### 6.4 实际应用：存储场景

```
分布式存储写入：

  Node A                          Node B
  ┌────────────────┐             ┌────────────────┐
  │  Put(Key, Value)               │                │
  │                │             │                │
  │ RDMA Write ─────────────────────►写入本地内存   │
  │                │             │                │
  │                │    Send/Recv (确认)           │
  │◄──────────────────────────────────────────────│
  │  ACK: OK                          │           │
  └────────────────┘             └────────────────┘

写入：RDMA Write (高速) + Send/Recv (确认)
读取：RDMA Read (高速)
```

---

## 7. 混合使用

### 7.1 同时使用多种操作

实际应用中经常混合使用多种操作：

```c
// 连接上下文
struct conn_ctx {
    struct ibv_qp *qp;
    struct peer_info *peer;
    struct ibv_mr *local_mr;
    struct ibv_mr *remote_mr;  // 远端 MR 信息
};

// 发送控制消息 (Send/Recv)
void send_control_msg(struct conn_ctx *ctx, enum msg_type type) {
    struct control_msg msg = { .type = type };
    post_send(ctx->qp, &msg, sizeof(msg));
}

// 传输大数据块 (RDMA Write)
void transfer_data(struct conn_ctx *ctx, void *buf, size_t len) {
    rdma_write(ctx->qp, ctx->peer, buf, ctx->local_mr, 0, len);
}

// 读取元数据 (RDMA Read)
void read_metadata(struct conn_ctx *ctx, struct metadata *meta) {
    rdma_read(ctx->qp, ctx->peer, meta, ctx->local_mr,
              ctx->peer->metadata_offset, sizeof(*meta));
}
```

### 7.2 流水线优化

```
时间 ─────────────────────────────────────────────────────►

    RDMA Write #1 ──────────────────────────────────────────►
                   RDMA Write #2 ────────────────────────────►
                                  RDMA Write #3 ────────────►

    [多个 WR 可以同时 in-flight，最大化带宽利用率]

    CQ 通知 #1:   ●
    CQ 通知 #2:       ●
    CQ 通知 #3:           ●
```

```c
// 批量 post 多个 WR
struct ibv_send_wr wr_list[16];
struct ibv_send_wr *bad_wr;

for (int i = 0; i < 16; i++) {
    wr_list[i].wr_id = i;
    wr_list[i].opcode = IBV_WR_RDMA_WRITE;
    wr_list[i].sg_list = &sges[i];
    wr_list[i].num_sge = 1;
    wr_list[i].rdma.remote_addr = peer->addr + i * CHUNK;
    wr_list[i].rdma.rkey = peer->rkey;

    if (i < 15)
        wr_list[i].next = &wr_list[i + 1];
    else
        wr_list[i].next = NULL;
}

// 一次提交所有 WR
ibv_post_send(qp, &wr_list[0], &bad_wr);
```

---

## 8. 常见问题

**Q: RDMA Read 延迟为什么比 Write 高？**
A: Read 需要两次网络交互（请求+响应），而 Write 只需要一次（直接发送数据，可选 ACK）。这是可靠传输层的本质差异。

**Q: Send/Recv 的 Recv WR 必须预先 post 吗？**
A: 对于 RC QP 是的。如果没有 post Recv WR，发送方会收到 RNR NACK 并重试。对于 UD，丢包后不会重传。

**Q: 单边操作能否保证原子性？**
A: 单独的 RDMA Write 不保证原子性。如果需要原子操作，使用 Atomic (Fetch&Add/CAS)。多个 RDMA Write 的顺序需要应用层控制。

**Q: 什么情况下 Send/Recv 比 RDMA Write 更好？**
A: 当需要远端 CPU 感知并处理到达的数据时（如触发回调、更新元数据）；当需要确认数据已送达时（WC 通知）；当使用 UD 多播时。

**Q: 可以同时读写同一个远端 buffer 吗？**
A: 可以，但需要应用层同步（如分布式锁）。硬件不提供端到端的读写顺序保证，除非使用 Atomic 操作。
