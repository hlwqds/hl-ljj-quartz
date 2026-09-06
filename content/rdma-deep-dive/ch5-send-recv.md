---
title: "RDMA 深度探索（五）：Send/Recv 消息通信"
date: 2026-05-24
description: "通过 Send/Recv 理解 RDMA 的消息通信语义、post_recv 先行规则、SGE/WR 构造和 completion 处理。"
tags: [rdma, series, libibverbs, send-recv, linux]
---

> [!info] RDMA 深度探索系列 0. [[index-2026-05-24|系列索引]] 4. [[ch4-rc-qp-lifecycle|第四章：RC QP 生命周期]] 5. **第五章：Send/Recv 消息通信** 6. [[ch6-read-write|第六章：RDMA Read/Write]]

# RDMA 深度探索（五）：Send/Recv 消息通信

Send/Recv 是最适合入门的 RDMA 数据操作。它不是 RDMA 最独特的能力，但它能帮助你把 MR、SGE、WR、QP、CQ 串起来。

## 1. Send/Recv 的基本规则

最重要的规则：

```text
接收端必须先 post_recv，发送端才能安全 post_send。
```

原因是 RC send 的数据需要落到远端已经提交的 receive WR 中。如果远端没有可用 receive WR，发送端可能遇到 RNR，也就是 Receiver Not Ready。

## 2. 接收端准备 buffer

接收端先准备一块 buffer：

```c
char recv_buf[4096] = {0};
```

然后注册 MR：

```c
struct ibv_mr *recv_mr = ibv_reg_mr(
    pd,
    recv_buf,
    sizeof(recv_buf),
    IBV_ACCESS_LOCAL_WRITE
);
```

接收 buffer 需要 `IBV_ACCESS_LOCAL_WRITE`，因为网卡会把收到的数据写入这段本地内存。

## 3. 构造 receive WR

SGE 描述接收 buffer：

```c
struct ibv_sge sge = {
    .addr = (uintptr_t)recv_buf,
    .length = sizeof(recv_buf),
    .lkey = recv_mr->lkey,
};
```

receive WR 引用这个 SGE：

```c
struct ibv_recv_wr wr = {
    .wr_id = 100,
    .sg_list = &sge,
    .num_sge = 1,
};

struct ibv_recv_wr *bad_wr = NULL;
int ret = ibv_post_recv(qp, &wr, &bad_wr);
```

`wr_id` 是应用自定义的 ID。completion 里会带回来。

## 4. 发送端准备 buffer

发送端准备字符串：

```c
char send_buf[] = "hello rdma";
```

注册 MR：

```c
struct ibv_mr *send_mr = ibv_reg_mr(
    pd,
    send_buf,
    sizeof(send_buf),
    0
);
```

发送 buffer 如果只是被本地网卡读取，通常不需要 `IBV_ACCESS_LOCAL_WRITE`。

## 5. 构造 send WR

```c
struct ibv_sge sge = {
    .addr = (uintptr_t)send_buf,
    .length = sizeof(send_buf),
    .lkey = send_mr->lkey,
};

struct ibv_send_wr wr = {
    .wr_id = 200,
    .sg_list = &sge,
    .num_sge = 1,
    .opcode = IBV_WR_SEND,
    .send_flags = IBV_SEND_SIGNALED,
};

struct ibv_send_wr *bad_wr = NULL;
int ret = ibv_post_send(qp, &wr, &bad_wr);
```

`IBV_SEND_SIGNALED` 表示这条 WR 完成后要产生 completion。入门阶段建议所有 WR 都加上，方便观察。

## 6. 轮询 CQ

发送端和接收端都应该 poll CQ。

```c
static int poll_one(struct ibv_cq *cq, struct ibv_wc *wc)
{
    while (1) {
        int n = ibv_poll_cq(cq, 1, wc);
        if (n < 0) {
            return -1;
        }
        if (n == 0) {
            continue;
        }
        return 0;
    }
}
```

检查结果：

```c
struct ibv_wc wc;

if (poll_one(cq, &wc) == 0) {
    if (wc.status != IBV_WC_SUCCESS) {
        fprintf(stderr, "wc failed: status=%d\n", wc.status);
    }
}
```

接收端的 WC 中，`byte_len` 表示收到的数据长度。

## 7. Send/Recv 的时序

推荐时序：

```text
server 创建资源
client 创建资源
双方交换 QP 连接信息
双方 QP -> RTS
server post_recv
server 通知 client 可以发送
client post_send
client poll send completion
server poll recv completion
server 读取 recv_buf
```

如果没有“server 通知 client 可以发送”这一步，client 可能在 server `post_recv()` 之前发送，导致 RNR。

## 8. Send/Recv 适合做什么

Send/Recv 适合：

- 小消息。
- 控制面消息。
- 交换 `addr + rkey`。
- 通知远端某个 RDMA Write 已经完成。

对于大数据搬运，通常会使用 RDMA Write/Read。

## 9. 常见错误

### 9.1 忘记 post_recv

表现：

```text
发送端 completion 失败，可能出现 RNR retry exceeded。
```

解决：

```text
接收端提前 post_recv，并确保 receive queue 深度足够。
```

### 9.2 receive buffer 太小

如果发送长度超过接收 SGE 长度，completion 会失败。初学时建议接收 buffer 先开大一点，并打印 `wc.byte_len`。

### 9.3 没有 signaled completion

如果 send WR 没有 `IBV_SEND_SIGNALED`，发送端可能 poll 不到 completion。这不是一定错误，但会让初学调试困难。

## 10. 本章小结

Send/Recv 的核心链路是：

```text
recv side: reg_mr -> post_recv -> poll_cq -> read buffer
send side: reg_mr -> post_send -> poll_cq
```

下一章进入 RDMA 的核心能力：不依赖远端 `post_recv()`，直接读写远端授权内存。
