---
title: "RDMA 深度探索（四）：RC QP 生命周期"
date: 2026-05-24
description: "解释 Reliable Connection QP 从 RESET 到 INIT、RTR、RTS 的状态转换，以及需要交换的 qpn、psn、lid/gid 等连接信息。"
tags: [rdma, series, libibverbs, qp, networking]
---

> [!info] RDMA 深度探索系列 0. [[index-2026-05-24|系列索引]] 3. [[ch3-rxe-lab|第三章：Soft-RoCE/RXE 实验环境]] 4. **第四章：RC QP 生命周期** 5. [[ch5-send-recv|第五章：Send/Recv]]

# RDMA 深度探索（四）：RC QP 生命周期

RC QP 创建出来后不能直接通信。它必须按状态机从 RESET 走到 INIT，再走到 RTR，最后到 RTS。

```text
RESET -> INIT -> RTR -> RTS
```

理解这条状态机，是写 verbs 程序的关键。

## 1. 为什么需要状态转换

QP 是通信端点，但刚创建时它还不知道：

- 使用哪个本地端口。
- 是否允许远端读写。
- 远端 QP number 是多少。
- 远端地址是 LID 还是 GID。
- 初始 PSN 是多少。
- 重试、RNR、超时参数怎么设置。

状态转换就是逐步把这些信息填进去。

## 2. 连接信息交换

verbs 不负责连接管理。最常见做法是先用 TCP socket 交换 RDMA 连接信息。

RC QP 至少需要交换：

| 字段    | 说明                               |
| ------- | ---------------------------------- |
| `qpn`   | QP number，远端 QP 编号            |
| `psn`   | Packet Sequence Number，初始包序号 |
| `lid`   | InfiniBand 本地标识                |
| `gid`   | RoCE 常用，全局标识                |
| `rkey`  | RDMA Read/Write 需要的远端 key     |
| `vaddr` | RDMA Read/Write 需要的远端地址     |

send/recv 只需要连接级信息，不需要 `rkey` 和 `vaddr`。RDMA Read/Write 才需要远端内存信息。

## 3. RESET -> INIT

INIT 表示 QP 已经绑定到本地端口，并声明本地访问能力。

典型字段：

```c
struct ibv_qp_attr attr = {
    .qp_state = IBV_QPS_INIT,
    .pkey_index = 0,
    .port_num = port_num,
    .qp_access_flags =
        IBV_ACCESS_REMOTE_READ |
        IBV_ACCESS_REMOTE_WRITE |
        IBV_ACCESS_REMOTE_ATOMIC,
};

int flags =
    IBV_QP_STATE |
    IBV_QP_PKEY_INDEX |
    IBV_QP_PORT |
    IBV_QP_ACCESS_FLAGS;

ibv_modify_qp(qp, &attr, flags);
```

如果你只做 send/recv，可以不打开 remote read/write 权限。但入门 demo 通常会后续扩展到 RDMA Write，所以可以先预留。

## 4. INIT -> RTR

RTR 是 Ready To Receive。进入 RTR 之前，本端必须知道远端 QP 和路径信息。

典型字段：

```c
struct ibv_qp_attr attr = {
    .qp_state = IBV_QPS_RTR,
    .path_mtu = IBV_MTU_1024,
    .dest_qp_num = remote_qpn,
    .rq_psn = remote_psn,
    .max_dest_rd_atomic = 1,
    .min_rnr_timer = 12,
};
```

还需要设置 `ah_attr`，也就是 address handle 属性。InfiniBand 常用 LID，RoCE 常用 GID。

简化理解：

```text
RTR = 我知道远端是谁，也知道怎么把包发到它那里。
```

## 5. RTS -> Ready To Send

RTS 是 Ready To Send。进入 RTS 后，QP 才能发送 WR。

典型字段：

```c
struct ibv_qp_attr attr = {
    .qp_state = IBV_QPS_RTS,
    .timeout = 14,
    .retry_cnt = 7,
    .rnr_retry = 7,
    .sq_psn = local_psn,
    .max_rd_atomic = 1,
};
```

几个参数含义：

| 字段            | 说明                                   |
| --------------- | -------------------------------------- |
| `timeout`       | ACK 超时时间编码值                     |
| `retry_cnt`     | 传输失败重试次数                       |
| `rnr_retry`     | Receiver Not Ready 重试次数            |
| `sq_psn`        | 本端发送队列初始 PSN                   |
| `max_rd_atomic` | 本端可发起的并发 RDMA Read/Atomic 数量 |

入门阶段常见配置是 `retry_cnt = 7`、`rnr_retry = 7`，降低因为暂时没 post_recv 导致实验失败的概率。

## 6. 状态转换顺序建议

一个可靠的连接建立流程：

```text
两端创建资源
两端创建 QP
两端交换 qpn / psn / lid or gid
两端 RESET -> INIT
两端 INIT -> RTR
两端 RTR -> RTS
接收端 post_recv
发送端 post_send
```

如果是 send/recv，建议接收端在通知发送端之前先 `post_recv()`。

如果是 RDMA Write/Read，还需要额外交换：

```text
remote address + rkey
```

## 7. 常见错误

### 7.1 `ibv_modify_qp()` 返回失败

排查：

- `flags` 是否包含了对应字段。
- `port_num` 是否正确。
- `path_mtu` 是否被设备支持。
- RoCE 环境下 GID 是否设置正确。
- `dest_qp_num` 是否来自远端，而不是本端。

### 7.2 QP 到 RTS 了但通信失败

可能原因：

- 远端还没进入 RTS。
- 远端没有 post_recv。
- PSN 交换错。
- GID index 选错。
- CQ poll 的不是这个 QP 绑定的 CQ。

### 7.3 远端地址和 rkey 交换时机错误

`rkey` 和地址来自 MR。必须在远端 `ibv_reg_mr()` 成功之后再交换。MR 释放后，之前交换出去的 rkey 和地址都不能再使用。

## 8. 本章小结

RC QP 的状态转换可以记成：

```text
INIT：绑定本地端口和权限
RTR：填入远端接收路径
RTS：设置本端发送参数
```

下一章写第一个真正的数据操作：Send/Recv。它会复用本章的 QP 生命周期，并引入 `ibv_post_recv()`、`ibv_post_send()` 和 `ibv_poll_cq()`。
