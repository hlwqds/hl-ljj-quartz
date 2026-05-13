---
title: "RDMA 深度探索 (十五)：RDMA 多播 (Multicast)"
date: 2026-04-13
tags: [rdma, series, multicast, multicast-group, UD, ibv_attach_mc, multicast-rdma]
description: "详解 RDMA 多播机制、Multicast QP、Join/Leave 组播组、UD 多播实现，以及一对多通信的最佳实践"
---

> [!info] RDMA 深度探索系列 0. [[2026-04-13-rdma-deep-dive-series-index|全栈学习路径总览]]
>
> 1. [[2026-04-13-rdma-deep-dive-ch1-rdma-overview|第一章：RDMA 概述]]
> 2. [[2026-04-13-rdma-deep-dive-ch2-rdma-architecture|第二章：RDMA 架构]]
> 3. [[2026-04-13-rdma-deep-dive-ch3-infiniband|第三章：InfiniBand 架构]]
> 4. [[2026-04-13-rdma-deep-dive-ch4-roce|第四章：RoCE v1/v2]]
> 5. [[2026-04-13-rdma-deep-dive-ch5-iwarp|第五章：iWARP]]
> 6. [[2026-04-13-rdma-deep-dive-ch6-roce-vs-iwarp|第六章：RoCE vs iWARP 对比]]
> 7. [[2026-04-13-rdma-deep-dive-ch7-queue-pair|第七章：队列对 (QP)]]
> 8. [[2026-04-13-rdma-deep-dive-ch8-mr-pd|第八章：内存区域与保护域]]
> 9. [[2026-04-13-rdma-deep-dive-ch9-verbs-api|第九章：Verbs API]]
> 10. [[2026-04-13-rdma-deep-dive-ch10-ud-rc|第十章：UD vs RC 传输类型]]
> 11. [[2026-04-13-rdma-deep-dive-ch11-atomics|第十一章：RDMA 原子操作]]
> 12. [[2026-04-13-rdma-deep-dive-ch12-rdma-programming|第十二章：RDMA 编程起步]]
> 13. [[2026-04-13-rdma-deep-dive-ch13-rdma-read-write|第十三章：RDMA Send/Recv vs RDMA Read/Write]]
> 14. [[2026-04-13-rdma-deep-dive-ch14-rdma-server-client|第十四章：RDMA 客户端服务器]]
> 15. **第十五章：RDMA 多播**

---

## 1. RDMA 多播概述

### 1.1 什么是 RDMA 多播

RDMA 多播允许用一个 QP 同时向多个目标节点发送数据，类似于 IP 多播，但专为 RDMA 设计：

```
┌─────────────────────────────────────────────────────────────┐
│                  RDMA Unicast vs Multicast                  │
│                                                             │
│  Unicast:                                                    │
│  ┌─────────┐          ┌─────────┐                          │
│  │ Node A  │──────────►│ Node B  │  1:1 通信                │
│  └─────────┘          └─────────┘                          │
│                                                             │
│  Multicast:                                                  │
│  ┌─────────┐                                               │
│  │ Node A  │                                                │
│  │ (Sender)│                                                │
│  └────┬────┘                                               │
│       │                                                     │
│  ┌────┴────┬────────────┐                                  │
│  ▼         ▼            ▼                                   │
│ ┌────┐  ┌────┐      ┌────┐                                 │
│ │Node│  │Node│      │Node│  1:N 通信                       │
│ │ B  │  │ C  │      │ D  │  发送方只发送一次               │
│ └────┘  └────┘      └────┘  网络自动复制到所有接收者       │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 多播的限制

RDMA 多播有以下限制：

| 限制         | 说明                                          |
| ------------ | --------------------------------------------- |
| 仅 UD QP     | 多播只能在 Unreliable Datagram (UD) QP 上使用 |
| 仅 Send/Recv | UD 不支持 RDMA Read/Write，只能 Send/Recv     |
| 无可靠性保证 | UD 本身不可靠，丢包不重传                     |
| GID/LID 寻址 | 使用多播组 GID（IPv6 格式）                   |
| 硬件支持     | 需要交换机支持多播路由                        |

### 1.3 典型应用场景

| 场景           | 说明                   |
| -------------- | ---------------------- |
| 分布式键值存储 | 广播节点变更、路由更新 |
| MPI AllReduce  | 广播部分和、集合通信   |
| 集群发现       | 新节点加入时广播公告   |
| 分布式 Barrier | 同步点广播             |
| AI 训练        | 多 GPU AllGather 通信  |

---

## 2. 多播地址

### 2.1 IB 多播地址

InfiniBand 使用 GID (Global Identifier) 作为多播地址，格式为 IPv6：

```
IB 多播 GID 结构:

  ff12:8b00:0000:0000:0000:0000:xxxx:xxxx
  │└─┘│└──────────────────────────────┘└─┘
  │   │              │                   │
  │   │              │                   └── 多播组 ID (32 bits)
  │   │              │
  │   │              └────────────────── Scope (8 bits)
  │   │                                       (ff12 = link-local scope)
  │   └──────────────────────────────── Flags (8 bits) (ff = permanent)
  └────────────────────────────────── Reserved (8 bits) (ff)
```

### 2.2 生成本地多播 GID

```c
#include <infiniband/verbs.h>
#include <infiniband/umad.h>

// 生成本地多播 GID
static void generate_multicast_gid(uint8_t scope, uint32_t group_id,
                                   union ibv_gid *gid) {
    // 格式: ff12::xxxx:xxxx
    gid->raw[0] = 0xff;
    gid->raw[1] = 0x12;
    gid->raw[2] = 0x00;  // flags
    gid->raw[3] = scope; // scope

    // 中间 8 bytes 为 0
    memset(&gid->raw[4], 0, 8);

    // 最后 4 bytes: group_id
    gid->raw[12] = (group_id >> 24) & 0xff;
    gid->raw[13] = (group_id >> 16) & 0xff;
    gid->raw[14] = (group_id >> 8) & 0xff;
    gid->raw[15] = group_id & 0xff;
}

// 示例
union ibv_gid multicast_gid;
generate_multicast_gid(0x02, 0x1234, &multicast_gid);
printf("Multicast GID: %02x:%02x:%02x:%02x:%02x:%02x:%02x:%02x..."
       "%02x:%02x:%02x:%02x:%02x:%02x:%02x:%02x\n",
       multicast_gid.raw[0], multicast_gid.raw[1], ...);
```

### 2.3 标准多播组查询

```bash
# 查看当前节点的多播 GID
$ ibv_global_gid
  0xfe80000000000000:0x7cfe45030fff7d66

# 加入多播组后，查询成员
$ ibv_mcgid
  dev: mlx5_0
  mgid: ff12::4b74:6c6f63616c

# 查询交换机多播路由
$ ibnetdiscover | grep multicast
```

---

## 3. UD 多播编程

### 3.1 多播 QP 架构

```
┌─────────────────────────────────────────────────────────────┐
│                  UD Multicast QP 架构                       │
│                                                             │
│  Node A (Sender)                                            │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ UD QP                                                   │  │
│  │  - 一个 QP 对应多个 AH (Address Handle)                │  │
│  │  - 每个 AH 包含目标 GID/LID                            │  │
│  └──────────────────────────────────────────────────────┘  │
│                          │                                   │
│            ┌─────────────┼─────────────┐                   │
│            │             │             │                    │
│            ▼             ▼             ▼                    │
│       ┌────────┐    ┌────────┐    ┌────────┐             │
│       │ AH→GID │    │ AH→GID │    │ AH→GID │             │
│       │ ff12::B│    │ ff12::C│    │ ff12::D│             │
│       └────────┘    └────────┘    └────────┘             │
│            │             │             │                    │
│            └─────────────┼─────────────┘                   │
│                          │                                   │
│            ibv_post_send(qp, &wr, &bad_wr)                  │
│                          │                                   │
│                          ▼                                   │
│              [网络交换机复制到所有组成员]                    │
│                          │                                   │
│                          ▼                                   │
│              ┌───────────┴───────────┐                     │
│              │                       │                      │
│              ▼                       ▼                      │
│         Node B                   Node C, D...              │
│      (已 Join MC)              (已 Join MC)                 │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 创建 UD QP 用于多播

```c
#include <infiniband/verbs.h>
#include <rdma/rdma_cma.h>

struct mc_context {
    struct ibv_context *verbs_ctx;
    struct ibv_pd *pd;
    struct ibv_cq *cq;
    struct ibv_qp *qp;           // UD QP
    struct ibv_mr *mr;
    void *buf;

    union ibv_gid multicast_gid;
    uint16_t multicast_lid;
};

// 创建 UD QP
static struct mc_context *create_mc_qp(struct ibv_context *verbs_ctx) {
    struct mc_context *ctx = calloc(1, sizeof(*ctx));
    if (!ctx) return NULL;

    ctx->verbs_ctx = verbs_ctx;

    // 分配 PD
    ctx->pd = ibv_alloc_pd(verbs_ctx);
    if (!ctx->pd) goto error;

    // 创建 CQ
    ctx->cq = ibv_create_cq(verbs_ctx, 256, NULL, NULL, 0);
    if (!ctx->cq) goto error;

    // 创建 UD QP
    struct ibv_qp_init_attr qp_attr = {
        .send_cq = ctx->cq,
        .recv_cq = ctx->cq,
        .cap = {
            .max_send_wr = 128,
            .max_recv_wr = 128,
            .max_send_sge = 1,
            .max_recv_sge = 1,
        },
        .qp_type = IBV_QPT_UD,  // 注意：UD 类型
    };

    ctx->qp = ibv_create_qp(ctx->pd, &qp_attr);
    if (!ctx->qp) goto error;

    // 初始化 QP (INIT 状态)
    struct ibv_qp_attr attr = {
        .qp_state = IBV_QPS_INIT,
        .pkey_index = 0,
        .port_num = 1,
        .qp_access_flags = IBV_ACCESS_REMOTE_WRITE,
        .qkey = 0x111111,  // Q_Key
    };

    int ret = ibv_modify_qp(ctx->qp, &attr,
                          IBV_QP_STATE | IBV_QP_PKEY_INDEX |
                          IBV_QP_PORT | IBV_QP_ACCESS_FLAGS |
                          IBV_QP_QKEY);
    if (ret) goto error;

    // 分配 buffer 并注册
    ctx->buf = aligned_alloc(sysconf(_SC_PAGESIZE), 4096);
    ctx->mr = ibv_reg_mr(ctx->pd, ctx->buf, 4096,
                         IBV_ACCESS_LOCAL_WRITE);
    if (!ctx->mr) goto error;

    return ctx;

error:
    // 清理资源
    if (ctx->mr) ibv_dereg_mr(ctx->mr);
    if (ctx->buf) free(ctx->buf);
    if (ctx->qp) ibv_destroy_qp(ctx->qp);
    if (ctx->cq) ibv_destroy_cq(ctx->cq);
    if (ctx->pd) ibv_dealloc_pd(ctx->pd);
    free(ctx);
    return NULL;
}
```

### 3.3 加入/离开多播组

```c
// 加入多播组
static int join_multicast_group(struct mc_context *ctx) {
    // 生成多播 GID
    generate_multicast_gid(0x02, 0x0001, &ctx->multicast_gid);

    // 查询多播 LID (需要通过 SA 查询)
    // 简化：使用已知 LID 或通过 ibv_query_multicast_gid
    ctx->multicast_lid = 0xC000;  // 多播 LID 范围

    // 将 QP 加入多播组
    int ret = ibv_attach_qp_to_mc(ctx->qp,
                                  &ctx->multicast_gid,
                                  ctx->multicast_lid);
    if (ret) {
        fprintf(stderr, "Failed to join multicast group: %d\n", ret);
        return ret;
    }

    printf("Joined multicast group\n");
    printf("  GID: %02x%02x:%02x%02x:%02x%02x:%02x%02x:..."
           "%02x%02x:%02x%02x:%02x%02x:%02x%02x\n",
           ctx->multicast_gid.raw[0], ctx->multicast_gid.raw[1], ...);

    return 0;
}

// 离开多播组
static int leave_multicast_group(struct mc_context *ctx) {
    int ret = ibv_detach_qp_from_mc(ctx->qp,
                                    &ctx->multicast_gid,
                                    ctx->multicast_lid);
    if (ret) {
        fprintf(stderr, "Failed to leave multicast group\n");
        return ret;
    }

    printf("Left multicast group\n");
    return 0;
}
```

### 3.4 发送多播消息

```c
// 发送多播消息
static int send_multicast(struct mc_context *ctx, void *data, size_t len) {
    // 创建 Address Handle (AH) 指向多播组
    struct ibv_ah_attr ah_attr = {
        .dgid = ctx->multicast_gid,      // 多播 GID
        .dlid = ctx->multicast_lid,       // 多播 LID
        .sl = 0,                          // Service Level
        .src_path_bits = 0,
        .port_num = 1,
    };

    struct ibv_ah *ah = ibv_create_ah(ctx->pd, &ah_attr);
    if (!ah) {
        fprintf(stderr, "Failed to create AH\n");
        return -1;
    }

    // 准备发送数据
    memcpy(ctx->buf, data, len);

    struct ibv_sge sge = {
        .addr = (uint64_t)ctx->buf,
        .length = len,
        .lkey = ctx->mr->lkey,
    };

    // UD Send WR
    struct ibv_send_wr wr = {
        .wr_id = 1,
        .opcode = IBV_WR_SEND,
        .sg_list = &sge,
        .num_sge = 1,
        .send_flags = IBV_SEND_SIGNALED,
        .wr.ud = {
            .ah = ah,                      // 多播 AH
            .qkey = 0x111111,              // Q_Key
            .qp_num = 0,                   // 多播时为 0
        },
    };

    struct ibv_send_wr *bad_wr;
    int ret = ibv_post_send(ctx->qp, &wr, &bad_wr);

    // AH 在 Send 完成前必须保持有效
    if (ret == 0) {
        // 等待完成
        struct ibv_wc wc;
        while (1) {
            int ne = ibv_poll_cq(ctx->cq, 1, &wc);
            if (ne > 0) {
                if (wc.status == IBV_WC_SUCCESS) {
                    printf("Multicast sent: %zu bytes\n", len);
                } else {
                    fprintf(stderr, "Send failed: %s\n",
                            ibv_wc_status_str(wc.status));
                }
                break;
            }
        }
    }

    ibv_destroy_ah(ah);
    return ret;
}
```

### 3.5 接收多播消息

```c
// 接收多播消息
static int recv_multicast(struct mc_context *ctx) {
    struct ibv_sge sge = {
        .addr = (uint64_t)ctx->buf,
        .length = 4096,
        .lkey = ctx->mr->lkey,
    };

    struct ibv_recv_wr wr = {
        .wr_id = 2,
        .sg_list = &sge,
        .num_sge = 1,
    };

    struct ibv_recv_wr *bad_wr;
    return ibv_post_recv(ctx->qp, &wr, &bad_wr);
}

// 处理收到的消息
static void handle_recv(struct mc_context *ctx) {
    struct ibv_wc wc;

    int ne = ibv_poll_cq(ctx->cq, 1, &wc);
    if (ne > 0 && wc.status == IBV_WC_SUCCESS) {
        if (wc.opcode == IBV_WC_RECV) {
            printf("Received multicast from LID %u, %d bytes\n",
                   wc.slid, wc.byte_len);

            // UD 接收可以从 wc.src_qp 和 wc.slid 知道发送者
            printf("Source QP: %u\n", wc.src_qp);

            // 处理数据
            printf("Data: %.*s\n", wc.byte_len, (char *)ctx->buf);

            // 重新 post recv
            recv_multicast(ctx);
        }
    }
}
```

---

## 4. 完整示例：多播广播服务器

### 4.1 场景描述

构建一个多播广播服务器，多个客户端加入同一个多播组，服务器广播消息：

```
┌─────────────────────────────────────────────────────────────┐
│                  多播广播系统                               │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              Multicast Group: ff12::1                │   │
│  │                                                       │   │
│  │  Server ──── Multicast ────► [Group] ────► Client 1 │   │
│  │                               │           ────► Client 2 │   │
│  │                               │           ────► Client 3 │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  流程:                                                      │
│  1. Server 创建 UD QP                                       │
│  2. Server ibv_attach_qp_to_mc(ff12::1)                    │
│  3. Clients 加入多播组 (ibv_attach_qp_to_mc)                │
│  4. Server ibv_post_send (自动发送到所有组成员)             │
│  5. Clients 收到广播消息                                    │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 广播服务器代码

```c
#include "common.h"

#define MC_GROUP_ID 0x0001
#define MSG_SIZE 256

static struct mc_context {
    struct ibv_context *verbs_ctx;
    struct ibv_pd *pd;
    struct ibv_cq *cq;
    struct ibv_qp *qp;
    struct ibv_mr *mr;
    void *buf;
    union ibv_gid mc_gid;
} ctx;

static void generate_mc_gid(uint8_t scope, uint32_t group_id,
                            union ibv_gid *gid) {
    memset(gid, 0, sizeof(*gid));
    gid->raw[0] = 0xff;
    gid->raw[1] = 0x12;
    gid->raw[3] = scope;
    gid->raw[15] = group_id & 0xff;
    gid->raw[14] = (group_id >> 8) & 0xff;
}

static int init_rdma() {
    // 获取设备
    struct ibv_device **list = ibv_get_device_list(NULL);
    if (!list) return -1;

    ctx.verbs_ctx = ibv_open_device(list[0]);
    ibv_free_device_list(list);
    if (!ctx.verbs_ctx) return -1;

    // PD, CQ, QP (UD)
    ctx.pd = ibv_alloc_pd(ctx.verbs_ctx);
    ctx.cq = ibv_create_cq(ctx.verbs_ctx, 128, NULL, NULL, 0);

    struct ibv_qp_init_attr qp_attr = {
        .send_cq = ctx.cq,
        .recv_cq = ctx.cq,
        .cap = { .max_send_wr = 128, .max_recv_wr = 128,
                 .max_send_sge = 1, .max_recv_sge = 1 },
        .qp_type = IBV_QPT_UD,
    };
    ctx.qp = ibv_create_qp(ctx.pd, &qp_attr);

    // INIT
    struct ibv_qp_attr attr = {
        .qp_state = IBV_QPS_INIT,
        .pkey_index = 0,
        .port_num = 1,
        .qp_access_flags = 0,
        .qkey = 0x111111,
    };
    ibv_modify_qp(ctx.qp, &attr,
                  IBV_QP_STATE | IBV_QP_PKEY_INDEX |
                  IBV_QP_PORT | IBV_QP_ACCESS_FLAGS | IBV_QP_QKEY);

    // Buffer
    ctx.buf = aligned_alloc(sysconf(_SC_PAGESIZE), 4096);
    ctx.mr = ibv_reg_mr(ctx.pd, ctx.buf, 4096, IBV_ACCESS_LOCAL_WRITE);

    // 生成多播 GID
    generate_mc_gid(0x02, MC_GROUP_ID, &ctx.mc_gid);

    // 加入多播组
    ibv_attach_qp_to_mc(ctx.qp, &ctx.mc_gid, 0xC001);

    // Post Recv
    struct ibv_sge sge = {
        .addr = (uint64_t)ctx.buf,
        .length = 4096,
        .lkey = ctx.mr->lkey,
    };
    struct ibv_recv_wr wr = { .sg_list = &sge, .num_sge = 1 };
    struct ibv_recv_wr *bad;
    ibv_post_recv(ctx.qp, &wr, &bad);

    return 0;
}

static int broadcast_message(const char *msg) {
    size_t len = strlen(msg);
    memcpy(ctx.buf, msg, len);

    // 创建 AH 指向多播组
    struct ibv_ah_attr ah_attr = {
        .dgid = ctx.mc_gid,
        .dlid = 0xC001,
        .sl = 0,
        .port_num = 1,
    };
    struct ibv_ah *ah = ibv_create_ah(ctx.pd, &ah_attr);

    struct ibv_sge sge = {
        .addr = (uint64_t)ctx.buf,
        .length = len,
        .lkey = ctx.mr->lkey,
    };

    struct ibv_send_wr wr = {
        .opcode = IBV_WR_SEND,
        .sg_list = &sge,
        .num_sge = 1,
        .send_flags = IBV_SEND_SIGNALED,
        .wr.ud = { .ah = ah, .qkey = 0x111111, .qp_num = 0 },
    };

    struct ibv_send_wr *bad;
    ibv_post_send(ctx.qp, &wr, &bad);

    // 等待完成
    struct ibv_wc wc;
    while (ibv_poll_cq(ctx.cq, 1, &wc) == 0) usleep(1);

    ibv_destroy_ah(ah);
    printf("Broadcast sent: %s\n", msg);
    return 0;
}

int main() {
    init_rdma();

    // 广播测试消息
    broadcast_message("Hello Multicast Group!");
    sleep(1);
    broadcast_message("RDMA Multicast is working!");

    // 离开多播组
    ibv_detach_qp_from_mc(ctx.qp, &ctx.mc_gid, 0xC001);

    return 0;
}
```

### 4.3 客户端代码

```c
#include "common.h"

#define MC_GROUP_ID 0x0001

static struct {
    struct ibv_context *verbs_ctx;
    struct ibv_pd *pd;
    struct ibv_cq *cq;
    struct ibv_qp *qp;
    struct ibv_mr *mr;
    void *buf;
    union ibv_gid mc_gid;
} ctx;

static void generate_mc_gid(uint8_t scope, uint32_t group_id,
                            union ibv_gid *gid) {
    memset(gid, 0, sizeof(*gid));
    gid->raw[0] = 0xff;
    gid->raw[1] = 0x12;
    gid->raw[3] = scope;
    gid->raw[15] = group_id & 0xff;
    gid->raw[14] = (group_id >> 8) & 0xff;
}

static int init_rdma() {
    struct ibv_device **list = ibv_get_device_list(NULL);
    ctx.verbs_ctx = ibv_open_device(list[0]);
    ibv_free_device_list(list);

    ctx.pd = ibv_alloc_pd(ctx.verbs_ctx);
    ctx.cq = ibv_create_cq(ctx.verbs_ctx, 128, NULL, NULL, 0);

    struct ibv_qp_init_attr qp_attr = {
        .send_cq = ctx.cq,
        .recv_cq = ctx.cq,
        .cap = { .max_send_wr = 128, .max_recv_wr = 128,
                 .max_send_sge = 1, .max_recv_sge = 1 },
        .qp_type = IBV_QPT_UD,
    };
    ctx.qp = ibv_create_qp(ctx.pd, &qp_attr);

    struct ibv_qp_attr attr = {
        .qp_state = IBV_QPS_INIT,
        .pkey_index = 0,
        .port_num = 1,
        .qkey = 0x111111,
    };
    ibv_modify_qp(ctx.qp, &attr,
                  IBV_QP_STATE | IBV_QP_PKEY_INDEX |
                  IBV_QP_PORT | IBV_QP_QKEY);

    ctx.buf = aligned_alloc(sysconf(_SC_PAGESIZE), 4096);
    ctx.mr = ibv_reg_mr(ctx.pd, ctx.buf, 4096, IBV_ACCESS_LOCAL_WRITE);

    generate_mc_gid(0x02, MC_GROUP_ID, &ctx.mc_gid);
    ibv_attach_qp_to_mc(ctx.qp, &ctx.mc_gid, 0xC001);

    // Post Recv
    struct ibv_sge sge = {
        .addr = (uint64_t)ctx.buf,
        .length = 4096,
        .lkey = ctx.mr->lkey,
    };
    struct ibv_recv_wr wr = { .sg_list = &sge, .num_sge = 1 };
    struct ibv_recv_wr *bad;
    ibv_post_recv(ctx.qp, &wr, &bad);

    return 0;
}

static void recv_loop() {
    printf("Waiting for multicast messages...\n");

    while (1) {
        struct ibv_wc wc;
        int ne = ibv_poll_cq(ctx.cq, 1, &wc);

        if (ne > 0 && wc.status == IBV_WC_SUCCESS) {
            if (wc.opcode == IBV_WC_RECV) {
                printf("Received (%d bytes): %.*s\n",
                       wc.byte_len, wc.byte_len, (char *)ctx.buf);

                // 重新 post recv
                struct ibv_sge sge = {
                    .addr = (uint64_t)ctx.buf,
                    .length = 4096,
                    .lkey = ctx.mr->lkey,
                };
                struct ibv_recv_wr wr = { .sg_list = &sge, .num_sge = 1 };
                struct ibv_recv_wr *bad;
                ibv_post_recv(ctx.qp, &wr, &bad);
            }
        }

        usleep(1000);
    }
}

int main() {
    init_rdma();
    recv_loop();
    return 0;
}
```

---

## 5. 多播与可靠性

### 5.1 UD 多播的限制

UD 多播本身是不可靠的：

| 问题       | 影响               |
| ---------- | ------------------ |
| 丢包不重传 | 消息可能丢失       |
| 无序到达   | 可能乱序           |
| 无连接     | 任何发送者都可以发 |

### 5.2 提高可靠性的方法

```
┌─────────────────────────────────────────────────────────────┐
│              提高多播可靠性的策略                             │
│                                                             │
│  1. 应用层重传                                               │
│     - 发送端定期重发                                          │
│     - 接收端检测丢包（序列号）                                │
│     - 简单但有效                                              │
│                                                             │
│  2. 分层多播                                                  │
│     - 使用可靠 RC QP 在节点间中继                             │
│     - 减少网络多播跳数                                        │
│                                                             │
│  3. NACK/ACK 机制                                            │
│     - 接收端回复 NACK 请求重传                                │
│     - 需要额外基础设施                                        │
│                                                             │
│  4. 冗余发送                                                  │
│     - 发送多个副本                                            │
│     - 浪费带宽但简单                                          │
└─────────────────────────────────────────────────────────────┘
```

### 5.3 应用层序列号示例

```c
struct mc_message {
    uint32_t seq;           // 序列号
    uint32_t total;         // 总分片数
    uint32_t fragment;      // 当前分片
    char data[1000];
};

// 发送端
static void send_with_seq(struct mc_context *ctx,
                           struct mc_message *msg) {
    // 将序列号写入消息
    msg->seq = atomic_fetch_add(&g_seq, 1);
    memcpy(ctx->buf, msg, sizeof(*msg));
    send_multicast(ctx, ctx->buf, sizeof(*msg));
}

// 接收端
static int is_duplicate(uint32_t seq) {
    static uint32_t last_seq = 0;
    if (seq <= last_seq) {
        return 1;  // 重复或乱序
    }
    last_seq = seq;
    return 0;
}
```

---

## 6. 多播与 RoCE

### 6.1 RoCEv2 多播

RoCE v2 使用 UDP 封装，多播通过 IP 多播实现：

```
┌─────────────────────────────────────────────────────────────┐
│              RoCEv2 Multicast                               │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐  │
│  │ IP Header                                            │  │
│  │   Destination IP: 239.x.x.x (IP 多播地址)           │  │
│  ├─────────────────────────────────────────────────────┤  │
│  │ UDP Header                                           │  │
│  │   Destination Port: 4791 (RoCE v2)                   │  │
│  ├─────────────────────────────────────────────────────┤  │
│  │ IB BTH (Base Transport Header)                      │  │
│  │   DETH (Dest Extended Transport Header)              │  │
│  │     Q_Key: 0x111111                                   │  │
│  └─────────────────────────────────────────────────────┘  │
│                                                             │
│  多播路由由 IP 层处理                                        │
└─────────────────────────────────────────────────────────────┘
```

### 6.2 PFC 与多播

多播流量也需要 PFC 流控，否则会丢包：

```bash
# 检查多播组是否配置了正确的 PC
# 在交换机上配置多播的 PFC
enable
configure
interface Ethernet 1/1
  dcb priority-flow-control mode on
  dcb priority-flow-control priority 3 auto
  # 多播通常使用 priority 3
end
```

---

## 7. 常见问题

**Q: 多播只能用 UD QP？**
A: 是的。RC QP 是点对点可靠连接，不支持多播。UD 是唯一支持多播的 QP 类型。

**Q: ibv_attach_qp_to_mc 失败？**
A: 检查：1) QP 必须是 UD 类型；2) GID 是否有效；3) HCA 是否支持多播；4) 交换机是否配置了多播路由。

**Q: 多播消息没有收到？**
A: 检查：1) 是否已调用 ibv_attach_qp_to_mc；2) Q_Key 是否匹配；3) 是否 post 了 Recv WR；4) PFC 流控是否配置。

**Q: 可以同时加入多个多播组吗？**
A: 可以。每个 QP 可以通过多次 ibv_attach_qp_to_mc 加入多个多播组（受硬件限制，通常 8-32 个）。

**Q: 多播的带宽效率如何？**
A: 理论效率很高（发送一份，网络复制），但受限于交换机复制能力和 PFC 流控争用。

**Q: iWARP 支持多播吗？**
A: iWARP 基于 TCP，IP 多播需要应用层模拟，效率不如 IB/RoCE 原生多播。
