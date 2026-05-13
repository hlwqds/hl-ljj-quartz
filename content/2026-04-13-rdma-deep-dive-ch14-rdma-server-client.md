---
title: "RDMA 深度探索 (十四)：RDMA 客户端服务器实战"
date: 2026-04-13
tags: [rdma, series, echo-server, echo-client, rdma-cm, complete-example]
description: "从头实现一个完整的 RDMA echo 服务器和客户端，涵盖连接建立、内存注册、收发处理、错误处理，以及完整可编译运行的代码"
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
> 9. [[2026-04-13-rdma-deep-dive-ch9-verbs-api|第九章：Verbs API]]
> 10. [[2026-04-13-rdma-deep-dive-ch10-ud-rc|第十章：UD vs RC 传输类型]]
> 11. [[2026-04-13-rdma-deep-dive-ch11-atomics|第十一章：RDMA 原子操作]]
> 12. [[2026-04-13-rdma-deep-dive-ch12-rdma-programming|第十二章：RDMA 编程起步]]
> 13. [[2026-04-13-rdma-deep-dive-ch13-rdma-read-write|第十三章：RDMA Send/Recv vs RDMA Read/Write]]
> 14. **第十四章：RDMA 客户端服务器实战**

---

## 1. 系统架构

### 1.1 设计目标

本章节实现一个完整的 RDMA echo 系统：

```
┌─────────────────────────────────────────────────────────────┐
│                   RDMA Echo System                          │
│                                                             │
│  Server                                                      │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ 1. 监听连接 (rdma_cm_listener)                       │   │
│  │ 2. 接收连接请求                                       │   │
│  │ 3. Echo: 将收到的数据原样返回                         │   │
│  │ 4. 支持多个并发连接                                   │   │
│  └─────────────────────────────────────────────────────┘   │
│                              │                              │
│                              │ RC QP                        │
│                              ▼                              │
│  Client                                                      │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ 1. 连接到服务器                                       │   │
│  │ 2. 发送测试数据                                       │   │
│  │ 3. 接收 echo 响应                                     │   │
│  │ 4. 验证数据正确性                                     │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  端口: 20079                                                │
│  传输类型: RC (Reliable Connection)                         │
│  消息大小: 64B (默认), 可配置                                │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 文件结构

```
rdma-echo/
├── common.h          # 共享定义、结构体
├── server.c          # 服务器实现
├── client.c          # 客户端实现
└── Makefile          # 编译脚本
```

---

## 2. 共享定义 (common.h)

```c
#ifndef COMMON_H
#define COMMON_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <infiniband/verbs.h>
#include <rdma/rdma_cma.h>

#define PORT 20079
#define BUF_SIZE 4096
#define MAX_WR 128

// 消息类型
enum msg_type {
    MSG_TYPE_CONN_SETUP,    // 连接建立时的握手
    MSG_TYPE_ECHO_REQUEST,  // Echo 请求
    MSG_TYPE_ECHO_RESPONSE, // Echo 响应
    MSG_TYPE_DISCONNECT,    // 断开连接
};

// 连接设置消息 (private_data 交换)
struct conn_setup_msg {
    uint32_t qp_num;        // QP 编号
    uint32_t rkey;          // MR rkey
    uint64_t buf_addr;      // Buffer 地址
    uint32_t buf_size;      // Buffer 大小
};

// Echo 消息头
struct echo_msg {
    enum msg_type type;
    uint32_t seq;           // 序列号
    uint32_t data_len;      // 数据长度
};

// 连接上下文 (挂在 rdma_cm_id->context)
struct conn_context {
    // RDMA 资源
    struct ibv_pd *pd;
    struct ibv_qp *qp;
    struct ibv_cq *cq;
    struct ibv_mr *mr;

    // Buffer
    void *buf;
    int buf_size;

    // 对端信息
    struct conn_setup_msg peer_info;

    // 连接状态
    int connected;
    int disconnect_requested;
};

#endif // COMMON_H
```

---

## 3. 服务器实现 (server.c)

### 3.1 初始化 RDMA 资源

```c
#include "common.h"

// 全局变量
static struct rdma_event_channel *g_ec = NULL;
static struct rdma_cm_id *g_listener = NULL;
static struct conn_context *g_conn_ctx = NULL;

// 分配 Connection Context
static struct conn_context *alloc_conn_context(struct rdma_cm_id *id) {
    struct conn_context *ctx = calloc(1, sizeof(*ctx));
    if (!ctx) return NULL;

    // 1. 分配 Protection Domain
    ctx->pd = ibv_alloc_pd(id->verbs);
    if (!ctx->pd) {
        free(ctx);
        return NULL;
    }

    // 2. 创建 CQ
    ctx->cq = ibv_create_cq(id->verbs, MAX_WR * 2, NULL, NULL, 0);
    if (!ctx->cq) {
        ibv_dealloc_pd(ctx->pd);
        free(ctx);
        return NULL;
    }

    // 3. 创建 QP
    struct ibv_qp_init_attr qp_attr = {
        .send_cq = ctx->cq,
        .recv_cq = ctx->cq,
        .cap = {
            .max_send_wr = MAX_WR,
            .max_recv_wr = MAX_WR,
            .max_send_sge = 1,
            .max_recv_sge = 1,
        },
        .qp_type = IBV_QPT_RC,
    };

    ctx->qp = ibv_create_qp(ctx->pd, &qp_attr);
    if (!ctx->qp) {
        ibv_destroy_cq(ctx->cq);
        ibv_dealloc_pd(ctx->pd);
        free(ctx);
        return NULL;
    }

    // 4. 分配并注册内存
    ctx->buf_size = BUF_SIZE;
    ctx->buf = aligned_alloc(sysconf(_SC_PAGESIZE), ctx->buf_size);
    if (!ctx->buf) {
        ibv_destroy_qp(ctx->qp);
        ibv_destroy_cq(ctx->cq);
        ibv_dealloc_pd(ctx->pd);
        free(ctx);
        return NULL;
    }

    ctx->mr = ibv_reg_mr(ctx->pd, ctx->buf, ctx->buf_size,
                         IBV_ACCESS_LOCAL_WRITE |
                         IBV_ACCESS_REMOTE_READ |
                         IBV_ACCESS_REMOTE_WRITE);
    if (!ctx->mr) {
        free(ctx->buf);
        ibv_destroy_qp(ctx->qp);
        ibv_destroy_cq(ctx->cq);
        ibv_dealloc_pd(ctx->pd);
        free(ctx);
        return NULL;
    }

    // 5. 预先 post Recv WR (准备接收第一条消息)
    post_recv(ctx);

    ctx->connected = 0;
    return ctx;
}

// 释放 Connection Context
static void free_conn_context(struct conn_context *ctx) {
    if (!ctx) return;

    if (ctx->mr) ibv_dereg_mr(ctx->mr);
    if (ctx->buf) free(ctx->buf);
    if (ctx->qp) ibv_destroy_qp(ctx->qp);
    if (ctx->cq) ibv_destroy_cq(ctx->cq);
    if (ctx->pd) ibv_dealloc_pd(ctx->pd);

    free(ctx);
}
```

### 3.2 Post Recv/Send WR

```c
// Post Recv WR
static int post_recv(struct conn_context *ctx) {
    struct ibv_sge sge = {
        .addr = (uint64_t)ctx->buf,
        .length = ctx->buf_size,
        .lkey = ctx->mr->lkey,
    };

    struct ibv_recv_wr wr = {
        .wr_id = (uint64_t)ctx,
        .sg_list = &sge,
        .num_sge = 1,
    };

    struct ibv_recv_wr *bad_wr;
    return ibv_post_recv(ctx->qp, &wr, &bad_wr);
}

// Post Send WR
static int post_send(struct conn_context *ctx, void *data, size_t len,
                     enum msg_type type, uint32_t seq) {
    struct echo_msg *msg = (struct echo_msg *)ctx->buf;
    msg->type = type;
    msg->seq = seq;
    msg->data_len = len;

    if (data && len > 0) {
        memcpy(ctx->buf + sizeof(struct echo_msg), data, len);
    }

    struct ibv_sge sge = {
        .addr = (uint64_t)ctx->buf,
        .length = sizeof(struct echo_msg) + len,
        .lkey = ctx->mr->lkey,
    };

    struct ibv_send_wr wr = {
        .wr_id = (uint64_t)ctx,
        .opcode = IBV_WR_SEND,
        .sg_list = &sge,
        .num_sge = 1,
        .send_flags = IBV_SEND_SIGNALED,
    };

    struct ibv_send_wr *bad_wr;
    return ibv_post_send(ctx->qp, &wr, &bad_wr);
}
```

### 3.3 QP 状态转换

```c
// 将 QP 从 INIT 转换到 RTR
static int qp_init_to_rtr(struct conn_context *ctx, uint32_t remote_qpn) {
    struct ibv_qp_attr attr = {
        .qp_state = IBV_QPS_RTR,
        .path_mtu = IBV_MTU_4096,
        .rq_psn = 0,
        .dest_qp_num = remote_qpn,
        .max_dest_rd_atomic = 16,
        .min_rnr_timer = 12,
    };

    int ret = ibv_modify_qp(ctx->qp, &attr,
                           IBV_QP_STATE |
                           IBV_QP_AV |
                           IBV_QP_PATH_MTU |
                           IBV_QP_DEST_QPN |
                           IBV_QP_RQ_PSN |
                           IBV_QP_MAX_DEST_RD_ATOMIC |
                           IBV_QP_MIN_RNR_TIMER);
    return ret;
}

// 将 QP 从 RTR 转换到 RTS
static int qp_rtr_to_rts(struct conn_context *ctx) {
    struct ibv_qp_attr attr = {
        .qp_state = IBV_QPS_RTS,
        .sq_psn = 0,
        .max_rd_atomic = 16,
        .timeout = 14,
        .retry_cnt = 7,
        .rnr_retry = 7,
    };

    int ret = ibv_modify_qp(ctx->qp, &attr,
                           IBV_QP_STATE |
                           IBV_QP_SQ_PSN |
                           IBV_QP_MAX_RD_ATOMIC |
                           IBV_QP_TIMEOUT |
                           IBV_QP_RETRY_CNT |
                           IBV_QP_RNR_RETRY);
    return ret;
}
```

### 3.4 Echo 处理

```c
// 处理收到的 Echo 请求
static void handle_echo_request(struct conn_context *ctx) {
    struct echo_msg *msg = (struct echo_msg *)ctx->buf;

    printf("Server: Echo request seq=%u, len=%u\n",
           msg->seq, msg->data_len);

    // 发送 Echo 响应 (原样返回数据)
    post_send(ctx,
              ctx->buf + sizeof(struct echo_msg),
              msg->data_len,
              MSG_TYPE_ECHO_RESPONSE,
              msg->seq);
}

// 处理收到的 Echo 响应
static void handle_echo_response(struct conn_context *ctx) {
    struct echo_msg *msg = (struct echo_msg *)ctx->buf;

    printf("Server: Echo response seq=%u, len=%u\n",
           msg->seq, msg->data_len);
}
```

### 3.5 事件循环

```c
// 轮询 CQ
static void poll_cq(struct conn_context *ctx) {
    struct ibv_wc wc;
    int ne;

    while (!ctx->disconnect_requested) {
        ne = ibv_poll_cq(ctx->cq, 1, &wc);
        if (ne < 0) {
            fprintf(stderr, "Poll CQ failed\n");
            break;
        }

        if (ne == 0)
            continue;

        if (wc.status != IBV_WC_SUCCESS) {
            fprintf(stderr, "WC status error: %s\n",
                    ibv_wc_status_str(wc.status));
            break;
        }

        struct echo_msg *msg = (struct echo_msg *)ctx->buf;

        switch (msg->type) {
        case MSG_TYPE_ECHO_REQUEST:
            handle_echo_request(ctx);
            post_recv(ctx);  // 重新 post recv
            break;

        case MSG_TYPE_ECHO_RESPONSE:
            handle_echo_response(ctx);
            post_recv(ctx);  // 重新 post recv
            break;

        default:
            fprintf(stderr, "Unknown message type: %d\n", msg->type);
            post_recv(ctx);
            break;
        }
    }
}

// 主事件循环
static void event_loop(struct rdma_event_channel *ec) {
    struct rdma_cm_event *event = NULL;

    while (rdma_get_cm_event(ec, &event) == 0) {
        struct rdma_cm_id *id = event->id;
        enum rdma_cm_event_type type = event->id->event;

        switch (type) {
        case RDMA_CM_EVENT_CONNECT_REQUEST: {
            printf("Connect request received\n");

            // 分配连接上下文
            struct conn_context *ctx = alloc_conn_context(id);
            if (!ctx) {
                fprintf(stderr, "Failed to allocate context\n");
                rdma_reject(id, NULL, 0);
                break;
            }

            id->context = ctx;
            g_conn_ctx = ctx;

            // 获取客户端信息
            struct conn_setup_msg *client_info =
                (struct conn_setup_msg *)event->param.conn.private_data;

            // 修改 QP 到 INIT
            struct ibv_qp_attr attr = {
                .qp_state = IBV_QPS_INIT,
                .pkey_index = 0,
                .port_num = 1,
                .qp_access_flags = IBV_ACCESS_REMOTE_READ |
                                   IBV_ACCESS_REMOTE_WRITE,
            };
            ibv_modify_qp(ctx->qp, &attr,
                         IBV_QP_STATE |
                         IBV_QP_PKEY_INDEX |
                         IBV_QP_PORT |
                         IBV_QP_ACCESS_FLAGS);

            // 准备服务器端信息
            struct conn_setup_msg server_info = {
                .qp_num = ctx->qp->qp_num,
                .rkey = ctx->mr->rkey,
                .buf_addr = (uint64_t)ctx->buf,
                .buf_size = ctx->buf_size,
            };

            // 接受连接
            struct rdma_conn_param conn_param = {
                .private_data = &server_info,
                .private_data_len = sizeof(server_info),
                .responder_resources = 16,
                .initiator_depth = 16,
            };

            rdma_accept(id, &conn_param);
            rdma_ack_cm_event(event);
            break;
        }

        case RDMA_CM_EVENT_ESTABLISHED: {
            printf("Connection established\n");
            struct conn_context *ctx = (struct conn_context *)id->context;
            ctx->connected = 1;

            // 开始轮询 CQ
            poll_cq(ctx);

            rdma_ack_cm_event(event);
            break;
        }

        case RDMA_CM_EVENT_DISCONNECTED: {
            printf("Disconnected\n");
            struct conn_context *ctx = (struct conn_context *)id->context;
            ctx->disconnect_requested = 1;

            rdma_disconnect(id);
            rdma_ack_cm_event(event);

            free_conn_context(ctx);
            g_conn_ctx = NULL;
            rdma_destroy_id(id);
            break;
        }

        default:
            rdma_ack_cm_event(event);
            break;
        }
    }
}
```

### 3.6 服务器主函数

```c
int main(int argc, char *argv[]) {
    struct sockaddr_in addr;
    int ret;

    // 创建事件通道
    g_ec = rdma_create_event_channel();
    if (!g_ec) {
        fprintf(stderr, "Failed to create event channel\n");
        return 1;
    }

    // 创建监听 ID
    ret = rdma_create_id(g_ec, &g_listener, NULL, RDMA_PS_TCP);
    if (ret) {
        fprintf(stderr, "Failed to create ID\n");
        return 1;
    }

    // 绑定地址
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(PORT);
    addr.sin_addr.s_addr = INADDR_ANY;

    ret = rdma_bind_addr(g_listener, (struct sockaddr *)&addr);
    if (ret) {
        fprintf(stderr, "Failed to bind address\n");
        return 1;
    }

    // 开始监听
    ret = rdma_listen(g_listener, 10);
    if (ret) {
        fprintf(stderr, "Failed to listen\n");
        return 1;
    }

    printf("RDMA Echo Server listening on port %d\n", PORT);

    // 进入事件循环
    event_loop(g_ec);

    // 清理
    rdma_destroy_id(g_listener);
    rdma_destroy_event_channel(g_ec);

    return 0;
}
```

---

## 4. 客户端实现 (client.c)

### 4.1 初始化

```c
#include "common.h"

static struct rdma_event_channel *g_ec = NULL;
static struct rdma_cm_id *g_conn_id = NULL;
static struct conn_context *g_ctx = NULL;
static struct conn_setup_msg g_server_info;

static struct conn_context *alloc_client_context() {
    struct conn_context *ctx = calloc(1, sizeof(*ctx));
    if (!ctx) return NULL;

    ctx->pd = ibv_alloc_pd(g_conn_id->verbs);
    if (!ctx->pd) {
        free(ctx);
        return NULL;
    }

    ctx->cq = ibv_create_cq(g_conn_id->verbs, MAX_WR * 2, NULL, NULL, 0);
    if (!ctx->cq) {
        ibv_dealloc_pd(ctx->pd);
        free(ctx);
        return NULL;
    }

    struct ibv_qp_init_attr qp_attr = {
        .send_cq = ctx->cq,
        .recv_cq = ctx->cq,
        .cap = {
            .max_send_wr = MAX_WR,
            .max_recv_wr = MAX_WR,
            .max_send_sge = 1,
            .max_recv_sge = 1,
        },
        .qp_type = IBV_QPT_RC,
    };

    ctx->qp = ibv_create_qp(ctx->pd, &qp_attr);
    if (!ctx->qp) {
        ibv_destroy_cq(ctx->cq);
        ibv_dealloc_pd(ctx->pd);
        free(ctx);
        return NULL;
    }

    ctx->buf_size = BUF_SIZE;
    ctx->buf = aligned_alloc(sysconf(_SC_PAGESIZE), ctx->buf_size);
    if (!ctx->buf) {
        ibv_destroy_qp(ctx->qp);
        ibv_destroy_cq(ctx->cq);
        ibv_dealloc_pd(ctx->pd);
        free(ctx);
        return NULL;
    }

    ctx->mr = ibv_reg_mr(ctx->pd, ctx->buf, ctx->buf_size,
                         IBV_ACCESS_LOCAL_WRITE |
                         IBV_ACCESS_REMOTE_READ |
                         IBV_ACCESS_REMOTE_WRITE);
    if (!ctx->mr) {
        free(ctx->buf);
        ibv_destroy_qp(ctx->qp);
        ibv_destroy_cq(ctx->cq);
        ibv_dealloc_pd(ctx->pd);
        free(ctx);
        return NULL;
    }

    return ctx;
}

// Post Recv (客户端也需要准备接收)
static int post_recv(struct conn_context *ctx) {
    struct ibv_sge sge = {
        .addr = (uint64_t)ctx->buf,
        .length = ctx->buf_size,
        .lkey = ctx->mr->lkey,
    };

    struct ibv_recv_wr wr = {
        .wr_id = (uint64_t)ctx,
        .sg_list = &sge,
        .num_sge = 1,
    };

    struct ibv_recv_wr *bad_wr;
    return ibv_post_recv(ctx->qp, &wr, &bad_wr);
}
```

### 4.2 发送 Echo 请求

```c
static int send_echo_request(struct conn_context *ctx,
                               void *data, size_t len, uint32_t seq) {
    struct echo_msg *msg = (struct echo_msg *)ctx->buf;
    msg->type = MSG_TYPE_ECHO_REQUEST;
    msg->seq = seq;
    msg->data_len = len;

    if (data && len > 0) {
        memcpy(ctx->buf + sizeof(struct echo_msg), data, len);
    }

    struct ibv_sge sge = {
        .addr = (uint64_t)ctx->buf,
        .length = sizeof(struct echo_msg) + len,
        .lkey = ctx->mr->lkey,
    };

    struct ibv_send_wr wr = {
        .opcode = IBV_WR_SEND,
        .sg_list = &sge,
        .num_sge = 1,
        .send_flags = IBV_SEND_SIGNALED,
    };

    struct ibv_send_wr *bad_wr;
    return ibv_post_send(ctx->qp, &wr, &bad_wr);
}

// 等待指定 wr_id 的 Completion
static int wait_for_completion(struct conn_context *ctx, uint64_t wr_id) {
    struct ibv_wc wc;

    while (1) {
        int ne = ibv_poll_cq(ctx->cq, 1, &wc);
        if (ne < 0) {
            fprintf(stderr, "Poll CQ failed\n");
            return -1;
        }

        if (ne == 0)
            continue;

        if (wc.status != IBV_WC_SUCCESS) {
            fprintf(stderr, "WC failed: %s\n",
                    ibv_wc_status_str(wc.status));
            return -1;
        }

        if (wc.wr_id == wr_id) {
            return 0;
        }
    }
}
```

### 4.3 客户端主循环

```c
int main(int argc, char *argv[]) {
    struct sockaddr_in addr;
    int ret;

    if (argc != 2) {
        fprintf(stderr, "Usage: %s <server_ip>\n", argv[0]);
        return 1;
    }

    // 创建事件通道
    g_ec = rdma_create_event_channel();
    if (!g_ec) {
        fprintf(stderr, "Failed to create event channel\n");
        return 1;
    }

    // 创建连接 ID
    ret = rdma_create_id(g_ec, &g_conn_id, NULL, RDMA_PS_TCP);
    if (ret) {
        fprintf(stderr, "Failed to create ID\n");
        return 1;
    }

    // 解析地址
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(PORT);
    inet_pton(AF_INET, argv[1], &addr.sin_addr);

    printf("Connecting to %s:%d\n", argv[1], PORT);

    // 解析地址和路由
    ret = rdma_resolve_addr(g_conn_id, NULL, (struct sockaddr *)&addr, 2000);
    if (ret) {
        fprintf(stderr, "Failed to resolve address\n");
        return 1;
    }

    // 分配客户端上下文
    g_ctx = alloc_client_context();
    if (!g_ctx) {
        fprintf(stderr, "Failed to allocate context\n");
        return 1;
    }

    g_conn_id->context = g_ctx;

    // 修改 QP 到 INIT
    struct ibv_qp_attr attr = {
        .qp_state = IBV_QPS_INIT,
        .pkey_index = 0,
        .port_num = 1,
        .qp_access_flags = IBV_ACCESS_REMOTE_READ | IBV_ACCESS_REMOTE_WRITE,
    };
    ibv_modify_qp(g_ctx->qp, &attr,
                  IBV_QP_STATE | IBV_QP_PKEY_INDEX |
                  IBV_QP_PORT | IBV_QP_ACCESS_FLAGS);

    // 准备客户端信息
    struct conn_setup_msg client_info = {
        .qp_num = g_ctx->qp->qp_num,
        .rkey = g_ctx->mr->rkey,
        .buf_addr = (uint64_t)g_ctx->buf,
        .buf_size = g_ctx->buf_size,
    };

    // 发起连接
    struct rdma_conn_param conn_param = {
        .private_data = &client_info,
        .private_data_len = sizeof(client_info),
        .responder_resources = 16,
        .initiator_depth = 16,
    };

    ret = rdma_connect(g_conn_id, &conn_param);
    if (ret) {
        fprintf(stderr, "Failed to connect\n");
        return 1;
    }

    // 事件循环
    struct rdma_cm_event *event = NULL;
    while (rdma_get_cm_event(g_ec, &event) == 0) {
        enum rdma_cm_event_type type = event->id->event;

        switch (type) {
        case RDMA_CM_EVENT_ADDR_RESOLVED:
            printf("Address resolved\n");
            rdma_ack_cm_event(event);
            break;

        case RDMA_CM_EVENT_ROUTE_RESOLVED:
            printf("Route resolved\n");
            rdma_ack_cm_event(event);
            break;

        case RDMA_CM_EVENT_CONNECT_RESPONSE: {
            printf("Connection response received\n");
            struct conn_setup_msg *server_info =
                (struct conn_setup_msg *)event->param.conn.private_data;

            // 保存服务器信息
            g_server_info = *server_info;
            printf("Server: QP=%u, rkey=0x%x, addr=0x%lx\n",
                   server_info->qp_num,
                   server_info->rkey,
                   (unsigned long)server_info->buf_addr);

            rdma_ack_cm_event(event);

            // 修改 QP 到 RTR
            struct ibv_qp_attr attr = {
                .qp_state = IBV_QPS_RTR,
                .path_mtu = IBV_MTU_4096,
                .rq_psn = 0,
                .dest_qp_num = server_info->qp_num,
                .max_dest_rd_atomic = 16,
                .min_rnr_timer = 12,
            };
            ibv_modify_qp(g_ctx->qp, &attr,
                         IBV_QP_STATE | IBV_QP_AV |
                         IBV_QP_PATH_MTU | IBV_QP_DEST_QPN |
                         IBV_QP_RQ_PSN | IBV_QP_MAX_DEST_RD_ATOMIC |
                         IBV_QP_MIN_RNR_TIMER);

            // 修改 QP 到 RTS
            struct ibv_qp_attr attr2 = {
                .qp_state = IBV_QPS_RTS,
                .sq_psn = 0,
                .max_rd_atomic = 16,
                .timeout = 14,
                .retry_cnt = 7,
                .rnr_retry = 7,
            };
            ibv_modify_qp(g_ctx->qp, &attr2,
                         IBV_QP_STATE | IBV_QP_SQ_PSN |
                         IBV_QP_MAX_RD_ATOMIC | IBV_QP_TIMEOUT |
                         IBV_QP_RETRY_CNT | IBV_QP_RNR_RETRY);

            g_ctx->connected = 1;
            break;
        }

        case RDMA_CM_EVENT_ESTABLISHED: {
            printf("Connection established!\n");
            rdma_ack_cm_event(event);

            // Post Recv
            post_recv(g_ctx);

            // 发送测试消息
            char test_data[] = "Hello RDMA Echo!";
            printf("Sending echo request: \"%s\"\n", test_data);

            send_echo_request(g_ctx, test_data, strlen(test_data), 1);
            wait_for_completion(g_ctx, (uint64_t)g_ctx);

            // 接收响应
            while (1) {
                int ne = ibv_poll_cq(g_ctx->cq, 1, &wc);
                if (ne > 0 && wc.status == IBV_WC_SUCCESS) {
                    struct echo_msg *msg =
                        (struct echo_msg *)g_ctx->buf;
                    if (msg->type == MSG_TYPE_ECHO_RESPONSE) {
                        char *echo_data =
                            g_ctx->buf + sizeof(struct echo_msg);
                        printf("Received echo response: \"%.*s\"\n",
                               msg->data_len, echo_data);
                    }
                    break;
                }
            }

            printf("Test completed successfully!\n");

            // 断开连接
            rdma_disconnect(g_conn_id);
            break;
        }

        case RDMA_CM_EVENT_DISCONNECTED:
            printf("Disconnected\n");
            rdma_ack_cm_event(event);
            rdma_destroy_id(g_conn_id);
            goto cleanup;

        default:
            rdma_ack_cm_event(event);
            break;
        }
    }

cleanup:
    free_conn_context(g_ctx);
    rdma_destroy_event_channel(g_ec);

    return 0;
}
```

---

## 5. 编译与运行

### 5.1 Makefile

```makefile
CC = gcc
CFLAGS = -Wall -O2 -g
LDFLAGS = -libverbs -lrdmacm -lpthread

all: server client

server: server.o
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)

client: client.o
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)

%.o: %.c common.h
	$(CC) $(CFLAGS) -c -o $@ $<

clean:
	rm -f server client *.o

.PHONY: all clean
```

### 5.2 运行

```bash
# 编译
make

# 终端 1: 启动服务器
./server
RDMA Echo Server listening on port 20079

# 终端 2: 运行客户端
./client 192.168.1.100
Connecting to 192.168.1.100:20079
Address resolved
Route resolved
Connection response received
Server: QP=12, rkey=0x12345678, addr=0x7f...
Connection established!
Sending echo request: "Hello RDMA Echo!"
Received echo response: "Hello RDMA Echo!"
Test completed successfully!
Disconnected
```

---

## 6. 扩展练习

### 6.1 使用 RDMA Write 实现 Echo

将 Send/Recv 替换为 RDMA Write，利用单边操作的低延迟优势：

```c
// 客户端：使用 RDMA Write 发送数据
void rdma_write_echo_request(struct conn_context *ctx,
                              void *data, size_t len, uint32_t seq) {
    // 准备消息头
    struct echo_msg *msg = (struct echo_msg *)ctx->buf;
    msg->type = MSG_TYPE_ECHO_REQUEST;
    msg->seq = seq;
    msg->data_len = len;
    memcpy(ctx->buf + sizeof(struct echo_msg), data, len);

    // RDMA Write 到服务器 buffer
    struct ibv_sge sge = {
        .addr = (uint64_t)ctx->buf,
        .length = sizeof(struct echo_msg) + len,
        .lkey = ctx->mr->lkey,
    };

    struct ibv_send_wr wr = {
        .opcode = IBV_WR_RDMA_WRITE,
        .sg_list = &sge,
        .num_sge = 1,
        .send_flags = IBV_SEND_SIGNALED,
        .rdma.remote_addr = g_server_info.buf_addr,
        .rdma.rkey = g_server_info.rkey,
    };

    ibv_post_send(ctx->qp, &wr, &bad_wr);
}
```

### 6.2 支持多并发连接

修改服务器使用数组管理多个连接：

```c
#define MAX_CONNECTIONS 64

static struct conn_context *g_connections[MAX_CONNECTIONS];
static int g_num_connections = 0;

static int find_free_slot() {
    for (int i = 0; i < MAX_CONNECTIONS; i++) {
        if (!g_connections[i])
            return i;
    }
    return -1;
}
```

---

## 7. 常见问题

**Q: 连接建立后立即断开？**
A: 检查 private_data 是否正确传递；检查 QP 状态机转换是否正确；确保 post_recv 已调用。

**Q: wc.status 返回 REMOTE_ACCESS_ERROR？**
A: 远端 rkey 无效或权限不足；检查 MR 注册时的 access_flags。

**Q: ibv_post_send 返回 EAGAIN？**
A: QP 的 send queue 满了（max_send_wr 限制），需要等待之前的 WR 完成后再发送。

**Q: 如何调试 RDMA 程序？**
A: 使用 `ibv_devinfo` 检查设备状态；`ibstat` 检查端口；`rdma` 命令查看连接状态；在关键路径打印 QP/CQ 状态。

**Q: 为什么客户端需要 post_recv？**
A: 即使使用 RDMA Write，服务器也可能发送响应（如错误消息、确认）；同时 RC QP 的接收队列需要维护。
