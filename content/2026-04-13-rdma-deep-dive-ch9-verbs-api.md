---
title: "RDMA 深度探索 (九)：Verbs API 与 libibverbs"
date: 2026-04-13
tags: [rdma, series, libibverbs, verbs-api, ibv_post_send, polling, rdma-core]
description: "深入理解 libibverbs 核心 API：设备查询、QP 操作、Work Request 提交、Completion 轮询，以及 rdma-core 用户态接口"
---

> [!info] RDMA 深度探索系列
> 0. [[2026-04-13-rdma-deep-dive-series-index|全栈学习路径总览]]
> 1. [[2026-04-13-rdma-deep-dive-ch1-rdma-overview|第一章：RDMA 概述]]
> 2. [[2026-04-13-rdma-deep-dive-ch2-rdma-architecture|第二章：RDMA 架构]]
> 3. [[2026-04-13-rdma-deep-dive-ch3-infiniband|第三章：InfiniBand 架构]]
> 4. [[2026-04-13-rdma-deep-dive-ch4-roce|第四章：RoCE v1/v2]]
> 5. [[2026-04-13-rdma-deep-dive-ch5-iwarp|第五章：iWARP]]
> 6. [[2026-04-13-rdma-deep-dive-ch6-roce-vs-iwarp|第六章：RoCE vs iWARP 对比]]
> 7. [[2026-04-13-rdma-deep-dive-ch7-queue-pair|第七章：队列对 (QP)]]
> 8. [[2026-04-13-rdma-deep-dive-ch8-mr-pd|第八章：内存区域与保护域]]
> 9. **第九章：Verbs API**

---

## 1. libibverbs 概述

**libibverbs** 是 RDMA 编程的核心用户态库，提供了设备访问、内存管理、QP 操作等全套 API。它是 OFED (OpenFabrics Enterprise Distribution) 的一部分：

```
┌─────────────────────────────────────────────────────┐
│               RDMA 软件栈                            │
│                                                      │
│  ┌──────────────────────────────────────────────┐  │
│  │            用户态应用                          │  │
│  └──────────────────┬───────────────────────────┘  │
│                     │                               │
│  ┌──────────────────▼───────────────────────────┐  │
│  │         libibverbs (Verbs API)              │  │
│  │                                              │  │
│  │  ibv_open_device / ibv_create_qp           │  │
│  │  ibv_post_send / ibv_post_recv             │  │
│  │  ibv_poll_cq / ibv_reg_mr                   │  │
│  └──────────────────┬───────────────────────────┘  │
│                     │                               │
│  ┌──────────────────▼───────────────────────────┐  │
│  │         rdma-core (内核驱动接口)             │  │
│  └──────────────────┬───────────────────────────┘  │
│                     │                               │
│  ┌──────────────────▼───────────────────────────┐  │
│  │            Linux RDMA 子系统                  │  │
│  │  (mlx5, bnxt_re, i40iw, ocrdma ...)          │  │
│  └──────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

**rdma-core** 是更广泛的项目，包含 libibverbs + librdmacm + 内核驱动接口。

---

## 2. 设备发现与初始化

### 2.1 获取设备列表

```c
// 获取可用设备数量
int num_devices = ibv_get_device_list(NULL);
// 返回设备数组，最后一个元素为 NULL

struct ibv_device **device_list = ibv_get_device_list(NULL);
for (int i = 0; device_list[i] != NULL; i++) {
    printf("Device: %s\n", ibv_get_device_name(device_list[i]));
    // 例如: mlx5_0, bnxt_re0, i40iw0
}
ibv_free_device_list(device_list);
```

### 2.2 打开设备

```c
// 获取第一个设备（简化方式）
struct ibv_device *device = ibv_get_device_name(NULL); // 不推荐

// 标准方式
struct ibv_device **device_list = ibv_get_device_list(NULL);
struct ibv_device *device = device_list[0]; // 选择第一个设备

struct ibv_context *ctx = ibv_open_device(device);
if (!ctx) {
    fprintf(stderr, "无法打开设备\n");
    return -1;
}
```

### 2.3 查询设备能力

```c
struct ibv_device_attr_ex device_attr;
ibv_query_device_ex(ctx, NULL, &device_attr);

printf("最大 QP 数量: %d\n", device_attr.orig_attr.max_qp);
printf("最大 CQ 数量: %d\n", device_attr.orig_attr.max_cq);
printf("最大 MR 数量: %d\n", device_attr.orig_attr.max_mr);
printf("最大 SGE 数量: %d\n", device_attr.orig_attr.max_sge);
printf("最大 Inline Data: %d\n", device_attr.orig_attr.max_inline_data);
printf("物理端口数: %d\n", device_attr.orig_attr.phys_port_cnt);
```

---

## 3. Protection Domain 与 CQ

### 3.1 创建 PD

```c
struct ibv_pd *pd = ibv_alloc_pd(ctx);
if (!pd) {
    fprintf(stderr, "PD 创建失败\n");
    return -1;
}
```

### 3.2 创建 CQ

```c
struct ibv_cq *cq = ibv_create_cq(ctx,   // 设备 context
                                   128,   // CQ 容量（最小 1）
                                   NULL,  // 上下文（Completion 回调时传回）
                                   NULL,  // 异步事件 Completion Channel
                                   0);    // 竞争向量（通常为 0）
if (!cq) {
    fprintf(stderr, "CQ 创建失败\n");
    return -1;
}
```

### 3.3 轮询 CQ

```c
struct ibv_wc wc;
int ne = ibv_poll_cq(cq, 1, &wc);  // 最多取 1 个 Completion

if (ne < 0) {
    perror("Poll CQ 失败");
} else if (ne > 0) {
    if (wc.status == IBV_WC_SUCCESS) {
        printf("WR %lu 完成，opcode=%d, byte_len=%u\n",
               wc.wr_id, wc.opcode, wc.byte_len);
    } else {
        fprintf(stderr, "WC 错误: %s (status=%d)\n",
                ibv_wc_status_str(wc.status), wc.status);
    }
}
```

---

## 4. 创建 QP

### 4.1 完整流程

```c
// 1. 分配 CQ
struct ibv_cq *send_cq = ibv_create_cq(ctx, 128, NULL, NULL, 0);
struct ibv_cq *recv_cq = ibv_create_cq(ctx, 128, NULL, NULL, 0);

// 2. 初始化 QP 属性
struct ibv_qp_init_attr qp_init_attr = {
    .send_cq = send_cq,
    .recv_cq = recv_cq,
    .qp_context = NULL,
    .cap = {
        .max_send_wr  = 128,
        .max_recv_wr  = 128,
        .max_send_sge = 16,
        .max_recv_sge = 16,
        .max_inline_data = 64,  // 小数据内联（不额外 DMA）
    },
    .qp_type = IBV_QPT_RC,  // Reliable Connection
};

struct ibv_qp *qp = ibv_create_qp(pd, &qp_init_attr);
if (!qp) {
    perror("QP 创建失败");
    return -1;
}

// 3. 修改 QP 状态：RESET → INIT
struct ibv_qp_attr attr = {
    .qp_state        = IBV_QPS_INIT,
    .qp_access_flags = IBV_ACCESS_REMOTE_READ |
                       IBV_ACCESS_REMOTE_WRITE |
                       IBV_ACCESS_LOCAL_WRITE,
    .port_num        = 1,
};

ibv_modify_qp(qp, &attr,
    IBV_QP_STATE | IBV_QP_ACCESS_FLAGS | IBV_QP_PORT);

// 4. 修改 QP 状态：INIT → RTR (Ready to Receive)
memset(&attr, 0, sizeof(attr));
attr.qp_state    = IBV_QPS_RTR;
attr.path_mtu    = IBV_MTU_4096;
attr.dest_qp_num = remote_qp_num;  // 对端 QP 号
attr.rq_psn      = 0;
attr.max_dest_rd_atomic = 16;
attr.min_rnr_timer = 12;

ibv_modify_qp(qp, &attr,
    IBV_QP_STATE | IBV_QP_AV | IBV_QP_PATH_MTU |
    IBV_QP_DEST_QPN | IBV_QP_RQ_PSN |
    IBV_QP_MAX_DEST_RD_ATOMIC | IBV_QP_MIN_RNR_TIMER);

// 5. 修改 QP 状态：RTR → RTS (Ready to Send)
attr.qp_state    = IBV_QPS_RTS;
attr.sq_psn      = 0;
attr.timeout     = 14;
attr.retry_cnt   = 7;
attr.rnr_retry   = 7;
attr.max_rd_atomic = 16;

ibv_modify_qp(qp, &attr,
    IBV_QP_STATE | IBV_QP_SQ_PSN | IBV_QP_TIMEOUT |
    IBV_QP_RETRY_CNT | IBV_QP_RNR_RETRY |
    IBV_QP_MAX_QP_RD_ATOMIC);
```

---

## 5. Post Send / Post Recv

### 5.1 Post Recv (接收方准备缓冲区)

```c
// 必须先 post Recv WR，接收到的数据才能写入内存
struct ibv_sge sg_list = {
    .addr   = (uint64_t)recv_buf,
    .length = BUFFER_SIZE,
    .lkey   = mr->lkey,
};

struct ibv_recv_wr wr = {
    .wr_id   = 12345,  // 用于追踪
    .sg_list = &sg_list,
    .num_sge = 1,
};

struct ibv_recv_wr *bad_wr;
int ret = ibv_post_recv(qp, &wr, &bad_wr);
if (ret) {
    fprintf(stderr, "Post Recv 失败: %d\n", ret);
}
```

### 5.2 Post Send (发送方触发发送)

```c
struct ibv_sge sg_list = {
    .addr   = (uint64_t)send_buf,
    .length = msg_size,
    .lkey   = mr->lkey,
};

struct ibv_send_wr wr = {
    .wr_id      = 67890,
    .sg_list    = &sg_list,
    .num_sge    = 1,
    .opcode     = IBV_WR_SEND,
    .send_flags = IBV_SEND_SIGNALED,  // 完成后产生 CQE
};

struct ibv_send_wr *bad_wr;
int ret = ibv_post_send(qp, &wr, &bad_wr);
if (ret) {
    fprintf(stderr, "Post Send 失败: %d\n", ret);
}
```

### 5.3 RDMA Read/Write 操作

```c
// RDMA Read（从远端读取，本地 recv_buf 接收）
struct ibv_send_wr wr = {
    .wr_id       = 111,
    .sg_list     = &local_sge,    // 本地内存（接收数据）
    .num_sge     = 1,
    .opcode      = IBV_WR_RDMA_READ,
    .remote_addr = remote_addr,   // 远端虚拟地址
    .rkey        = remote_rkey,   // 远端 rkey
    .send_flags  = IBV_SEND_SIGNALED,
};

// RDMA Write（写入远端）
struct ibv_send_wr wr = {
    .wr_id       = 222,
    .sg_list     = &local_sge,    // 本地数据（发送出去）
    .num_sge     = 1,
    .opcode      = IBV_WR_RDMA_WRITE,
    .remote_addr = remote_addr,
    .rkey        = remote_rkey,
    .send_flags  = IBV_SEND_SIGNALED,
};

// RDMA Write with Immediate（写入 + 带立即数通知）
struct ibv_send_wr wr = {
    .wr_id       = 333,
    .opcode      = IBV_WR_RDMA_WRITE_WITH_IMM,
    .imm_data    = 0x12345678,   // 网络字节序立即数
    ...
};
```

### 5.4 批量提交

```c
// 一次提交多个 WR（链接成一个链表）
struct ibv_send_wr wr_list[3];

wr_list[0] = (struct ibv_send_wr){
    .wr_id = 1,
    .opcode = IBV_WR_SEND,
    .next = &wr_list[1],
    ...
};
wr_list[1] = (struct ibv_send_wr){
    .wr_id = 2,
    .opcode = IBV_WR_SEND,
    .next = &wr_list[2],
    ...
};
wr_list[2] = (struct ibv_send_wr){
    .wr_id = 3,
    .opcode = IBV_WR_SEND,
    .next = NULL,
    ...
};

struct ibv_send_wr *bad_wr;
ibv_post_send(qp, wr_list, &bad_wr);
// bad_wr 指向第一个失败的 WR
```

---

## 6. 内存注册

```c
struct ibv_mr *mr = ibv_reg_mr(pd,        // Protection Domain
                               buf,       // 内存起始地址
                               size,      // 长度
                               IBV_ACCESS_LOCAL_WRITE  |
                               IBV_ACCESS_REMOTE_WRITE |
                               IBV_ACCESS_REMOTE_READ);
if (!mr) {
    perror("内存注册失败");
    return -1;
}

printf("MR created: lkey=0x%x, rkey=0x%x\n", mr->lkey, mr->rkey);
```

---

## 7. 完整示例：RDMA Send/Recv

```c
#include <infiniband/verbs.h>
#include <rdma/rdma_cma.h>  // RDMA CM 连接建立

int main() {
    // 1. 打开设备
    struct ibv_device **list = ibv_get_device_list(NULL);
    struct ibv_context *ctx = ibv_open_device(list[0]);
    struct ibv_pd *pd = ibv_alloc_pd(ctx);

    // 2. 创建 CQ
    struct ibv_cq *cq = ibv_create_cq(ctx, 128, NULL, NULL, 0);

    // 3. 创建 QP
    struct ibv_qp_init_attr qp_attr = {
        .send_cq = cq, .recv_cq = cq,
        .cap = { .max_send_wr = 32, .max_recv_wr = 32,
                 .max_send_sge = 1, .max_recv_sge = 1 },
        .qp_type = IBV_QPT_RC,
    };
    struct ibv_qp *qp = ibv_create_qp(pd, &qp_attr);

    // 4. 注册内存
    char *buf = malloc(4096);
    struct ibv_mr *mr = ibv_reg_mr(pd, buf, 4096,
                    IBV_ACCESS_LOCAL_WRITE |
                    IBV_ACCESS_REMOTE_WRITE);

    // 5. 状态转换（建立连接后执行）
    // modify_qp(qp, RESET→INIT→RTR→RTS);

    // 6. Post Recv WR（准备接收缓冲区）
    struct ibv_sge sge = { .addr = (uint64_t)buf, .length = 4096, .lkey = mr->lkey };
    struct ibv_recv_wr recv_wr = { .wr_id = 1, .sg_list = &sge, .num_sge = 1 };
    struct ibv_recv_wr *bad_recv;
    ibv_post_recv(qp, &recv_wr, &bad_recv);

    // 7. Post Send WR
    struct ibv_send_wr send_wr = {
        .wr_id = 2,
        .opcode = IBV_WR_SEND,
        .sg_list = &sge,
        .num_sge = 1,
        .send_flags = IBV_SEND_SIGNALED,
    };
    struct ibv_send_wr *bad_send;
    ibv_post_send(qp, &send_wr, &bad_send);

    // 8. 轮询 CQ
    struct ibv_wc wc;
    while (1) {
        int ne = ibv_poll_cq(cq, 1, &wc);
        if (ne > 0) {
            if (wc.status == IBV_WC_SUCCESS) {
                printf("完成: wr_id=%lu, len=%u\n", wc.wr_id, wc.byte_len);
            } else {
                printf("错误: %s\n", ibv_wc_status_str(wc.status));
            }
            break;
        }
        // 可加 usleep 或 busy-wait
    }

    // 9. 清理
    ibv_dereg_mr(mr);
    ibv_destroy_qp(qp);
    ibv_destroy_cq(cq);
    ibv_dealloc_pd(pd);
    ibv_close_device(ctx);
    ibv_free_device_list(list);

    return 0;
}
```

编译：
```bash
gcc -o rdma_app rdma_app.c -libverbs -lrdmacm
```

---

## 8. 异步事件处理

除了轮询，CQ 还可以配合 Async Event Channel 使用中断模式：

```c
// 创建带事件通知的 CQ
struct ibv_comp_channel *channel = ibv_create_comp_channel(ctx);
struct ibv_cq *cq = ibv_create_cq(ctx, 128, NULL, channel, 0);

// 等待事件（可替代忙轮询）
struct ibv_cq *ev_cq;
void *ev_ctx;
ibv_get_cq_event(channel, &ev_cq, &ev_ctx);
ibv_ack_cq_events(ev_cq, 1);

// 然后轮询该 CQ
```

---

## 9. 常见错误码

| WC Status | 说明 |
|-----------|------|
| `IBV_WC_SUCCESS` | 成功 |
| `IBV_WC_LOC_LEN_ERR` | 本地长度错误 |
| `IBV_WC_LOC_QP_OP_ERR` | QP 操作错误（未正确初始化） |
| `IBV_WC_WR_FLUSH_ERR` | WR 在 Flush 状态（QP 进入 ERROR） |
| `IBV_WC_MW_BIND_ERR` | Memory Window 绑定错误 |
| `IBV_WC_REM_ACCESS_ERR` | 远端访问错误（rkey 无效） |
| `IBV_WC_REM_INV_REQ_ERR` | 远端无效请求错误 |
| `IBV_WC_RETRY_EXC_ERR` | 重试超时（网络或远端故障） |
| `IBV_WC_RNR_RETRY_EXC_ERR` | RNR 错误（接收方未 Post Recv WR） |

---

## 10. 性能相关的 API 参数

| 参数 | 影响 |
|------|------|
| `max_inline_data` | 小数据直接放在 WQE 中，省去额外 DMA（降低延迟） |
| `max_send_wr / max_recv_wr` | 批量能力，影响吞吐 |
| `send_flags = IBV_SEND_SIGNALED` | 每 N 个 WR 才产生一次 CQE（减少 overhead） |

---

## 11. 常见问题

**Q: ibv_post_send 返回成功，但远端没收到数据？**
A: Post Send 成功只意味着 WR 已入队，不代表完成。必须等待 CQE（Completion）才确认传输成功。

**Q: 如何知道对端收到了数据？**
A: Reliable Connection 下，HCA 自动确认，不需要应用层介入。如果超时未收到 ACK，HCA 会重传。

**Q: 为什么 Post Send 失败？**
A: 常见原因：QP 状态不是 RTS（Ready to Send）、队列已满（超出 max_send_wr）、SG list 超过 max_send_sge。

**Q: 如何选择 IBV_QPT_RC 还是 IBV_QPT_UD？**
A: RC (Reliable Connection)：可靠、有序、连接导向，适合大多数场景。UD (Unreliable Datagram)：无连接、不可靠、无序，适合多播或简单广播。
