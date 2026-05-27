---
title: "RDMA 深度探索（六）：RDMA Read/Write 远程内存语义"
date: 2026-05-24
description: "解释 RDMA Read/Write 的远程内存访问语义，以及 remote address、rkey、MR 权限和完成事件的关系。"
tags: [rdma, series, libibverbs, memory, networking]
---

> [!info] RDMA 深度探索系列
> 0. [[2026-05-24-rdma-deep-dive-series-index|系列索引]]
> 5. [[2026-05-24-rdma-deep-dive-ch5-send-recv|第五章：Send/Recv]]
> 6. **第六章：RDMA Read/Write**
> 7. [[2026-05-24-rdma-deep-dive-ch7-completion-debugging|第七章：Completion 与调试]]

# RDMA 深度探索（六）：RDMA Read/Write 远程内存语义

RDMA Read/Write 是 RDMA 最有代表性的能力：一端可以直接读写另一端已经授权的内存区域，远端应用不需要为每次数据搬运提前 `post_recv()`。

## 1. 和 Send/Recv 的区别

| 操作 | 远端是否需要 post_recv | 是否需要 `remote_addr + rkey` | 典型语义 |
| --- | --- | --- | --- |
| Send/Recv | 需要 | 不需要 | 消息通信 |
| RDMA Write | 不需要 | 需要 | 写远端内存 |
| RDMA Read | 不需要 | 需要 | 读远端内存 |

Send/Recv 的接收位置由远端 receive WR 决定。

RDMA Read/Write 的远端位置由本端 WR 里的 `remote_addr` 和 `rkey` 决定。

## 2. remote address 和 rkey

远端要先注册 MR：

```c
char remote_buf[4096];

struct ibv_mr *mr = ibv_reg_mr(
    pd,
    remote_buf,
    sizeof(remote_buf),
    IBV_ACCESS_LOCAL_WRITE |
    IBV_ACCESS_REMOTE_WRITE |
    IBV_ACCESS_REMOTE_READ
);
```

然后把下面信息发给对端：

```text
remote_addr = (uintptr_t)remote_buf
rkey = mr->rkey
```

对端拿到这两个值后，才能发起 RDMA Write/Read。

这两个值不是“普通参数”，而是远程内存访问能力的一部分。泄露 `addr + rkey` 就等于把这段 MR 暴露给对端。

## 3. RDMA Write

RDMA Write 把本地 buffer 写入远端 MR。

本地 buffer：

```c
char local_buf[] = "write from client";

struct ibv_mr *local_mr = ibv_reg_mr(
    pd,
    local_buf,
    sizeof(local_buf),
    0
);
```

构造 WR：

```c
struct ibv_sge sge = {
    .addr = (uintptr_t)local_buf,
    .length = sizeof(local_buf),
    .lkey = local_mr->lkey,
};

struct ibv_send_wr wr = {
    .wr_id = 300,
    .sg_list = &sge,
    .num_sge = 1,
    .opcode = IBV_WR_RDMA_WRITE,
    .send_flags = IBV_SEND_SIGNALED,
};

wr.wr.rdma.remote_addr = remote_addr;
wr.wr.rdma.rkey = remote_rkey;
```

提交：

```c
struct ibv_send_wr *bad_wr = NULL;
int ret = ibv_post_send(qp, &wr, &bad_wr);
```

completion 成功表示本端知道这次 RDMA Write 已经完成。远端不会自动收到一条 receive completion。

## 4. RDMA Read

RDMA Read 从远端 MR 读取数据到本地 buffer。

本地 buffer 需要允许本地写：

```c
char local_buf[4096];

struct ibv_mr *local_mr = ibv_reg_mr(
    pd,
    local_buf,
    sizeof(local_buf),
    IBV_ACCESS_LOCAL_WRITE
);
```

构造 WR：

```c
struct ibv_sge sge = {
    .addr = (uintptr_t)local_buf,
    .length = sizeof(local_buf),
    .lkey = local_mr->lkey,
};

struct ibv_send_wr wr = {
    .wr_id = 400,
    .sg_list = &sge,
    .num_sge = 1,
    .opcode = IBV_WR_RDMA_READ,
    .send_flags = IBV_SEND_SIGNALED,
};

wr.wr.rdma.remote_addr = remote_addr;
wr.wr.rdma.rkey = remote_rkey;
```

远端 MR 必须有 `IBV_ACCESS_REMOTE_READ` 权限。

## 5. 远端如何知道 Write 已经发生

RDMA Write 不会在远端生成 receive completion。远端如果需要知道数据到了，常见做法有三种：

1. Write 完成后，再 Send 一条小消息通知远端。
2. 写入一个带状态字段的数据结构，远端轮询状态。
3. 使用带 immediate data 的 RDMA Write with Immediate。

入门阶段建议使用第一种：

```text
client RDMA Write data
client Send "done"
server Recv "done"
server 读取 buffer
```

这样语义最清楚。

## 6. 内存生命周期

远端把 `addr + rkey` 发出去之后，必须保证：

- MR 没有 deregister。
- buffer 没有 free。
- buffer 没有被复用成别的含义。
- 权限符合对端操作。

否则对端 RDMA 操作可能失败，甚至写到你逻辑上不再期望的位置。

## 7. 常见错误

### 7.1 本地 buffer 没有注册

WR 的 SGE 必须使用注册过的 MR 的 `lkey`。不能随便填一个普通指针。

### 7.2 远端权限不够

RDMA Write 需要远端 MR 有：

```text
IBV_ACCESS_REMOTE_WRITE
```

RDMA Read 需要远端 MR 有：

```text
IBV_ACCESS_REMOTE_READ
```

### 7.3 把本地地址当远端地址

`remote_addr` 必须是远端进程中注册 MR 的虚拟地址。它通常通过 TCP 或 Send/Recv 从远端发过来。

### 7.4 期待远端自动有 completion

RDMA Write/Read 的 completion 出现在发起端 CQ。远端不会因为被写而自动产生 receive completion。

## 8. 本章小结

RDMA Read/Write 的核心是：

```text
远端注册 MR -> 交换 addr + rkey -> 本端提交 RDMA WR -> 本端 poll completion
```

这也是 RDMA 和普通消息通信最本质的差别：数据落点不由远端 receive WR 决定，而由本端持有的远端内存授权决定。
