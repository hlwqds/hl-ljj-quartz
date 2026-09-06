---
title: "RDMA 深度探索（二）：verbs 对象模型"
date: 2026-05-24
description: "系统拆解 libibverbs 编程中的 PD、MR、CQ、QP、WR、WC、SGE，建立 RDMA 程序的对象关系图。"
tags: [rdma, series, libibverbs, linux, networking]
---

> [!info] RDMA 深度探索系列 0. [[index-2026-05-24|系列索引]]
>
> 1. [[ch1-overview|第一章：RDMA 是什么]]
> 2. **第二章：verbs 对象模型**
> 3. [[ch3-rxe-lab|第三章：Soft-RoCE/RXE 实验环境]]

# RDMA 深度探索（二）：verbs 对象模型

RDMA verbs 程序看起来复杂，主要是因为对象多。但这些对象之间的关系非常稳定。只要把关系图记住，后续看任何 `ibv_*` 代码都会轻松很多。

## 1. 总体对象关系

一个最小 RC verbs 程序可以抽象成：

```text
RDMA Device
  -> Context
      -> Protection Domain
          -> Memory Region
          -> Queue Pair
      -> Completion Queue
```

数据操作则是：

```text
buffer -> MR -> SGE -> WR -> QP -> CQ -> WC
```

也就是：

1. 应用准备一段 buffer。
2. 通过 `ibv_reg_mr()` 注册成 MR。
3. 用 SGE 描述这段内存。
4. 把 SGE 填进 WR。
5. 通过 QP 提交 WR。
6. 网卡完成后把 WC 放入 CQ。
7. 应用 poll CQ 读取结果。

## 2. Context：设备上下文

Context 来自打开 RDMA 设备：

```c
struct ibv_device **list = ibv_get_device_list(NULL);
struct ibv_context *ctx = ibv_open_device(list[0]);
```

它代表一个已经打开的 RDMA 设备，后续创建 PD、CQ、QP 都需要它。

常见错误是机器上有多个设备时直接使用 `list[0]`。实验可以这样写，生产程序应该允许用户指定设备名。

## 3. PD：Protection Domain

PD 是 Protection Domain，保护域。它的作用是把一组资源放在同一个权限域里。

```c
struct ibv_pd *pd = ibv_alloc_pd(ctx);
```

MR 和 QP 都挂在 PD 下。一个 QP 只能使用同一 PD 下的 MR key。这个约束可以避免错误 QP 使用不属于自己的内存区域。

入门阶段可以简单理解：

```text
同一个连接相关的 QP 和 MR 放在同一个 PD 里。
```

## 4. MR：Memory Region

MR 是注册给网卡访问的一段内存。

```c
void *buf = malloc(4096);

struct ibv_mr *mr = ibv_reg_mr(
    pd,
    buf,
    4096,
    IBV_ACCESS_LOCAL_WRITE
);
```

注册之后，MR 里最重要的是：

| 字段     | 作用             |
| -------- | ---------------- |
| `addr`   | 注册内存起始地址 |
| `length` | 注册长度         |
| `lkey`   | 本地访问 key     |
| `rkey`   | 远端访问 key     |

`lkey` 用于本地 WR 的 SGE。`rkey` 给远端使用，用于 RDMA Read/Write。

常见权限：

| 权限                       | 作用                   |
| -------------------------- | ---------------------- |
| `IBV_ACCESS_LOCAL_WRITE`   | 允许本地网卡写这段内存 |
| `IBV_ACCESS_REMOTE_WRITE`  | 允许远端 RDMA Write    |
| `IBV_ACCESS_REMOTE_READ`   | 允许远端 RDMA Read     |
| `IBV_ACCESS_REMOTE_ATOMIC` | 允许远端原子操作       |

接收 buffer 通常需要 `IBV_ACCESS_LOCAL_WRITE`。RDMA Write 的远端 buffer 需要 `IBV_ACCESS_REMOTE_WRITE`。

## 5. CQ：Completion Queue

CQ 是完成队列。网卡把完成结果写入 CQ，应用通过 `ibv_poll_cq()` 读取。

```c
struct ibv_cq *cq = ibv_create_cq(ctx, 128, NULL, NULL, 0);
```

第二个参数是 CQ 深度。它不是越小越好。如果 CQ 太小，完成事件可能溢出，程序行为会变得很难诊断。

轮询 CQ：

```c
struct ibv_wc wc;
int n = ibv_poll_cq(cq, 1, &wc);
```

`wc.status == IBV_WC_SUCCESS` 才表示操作成功完成。

## 6. QP：Queue Pair

QP 是 RDMA 通信端点，包含发送队列和接收队列：

```text
QP
  -> Send Queue
  -> Receive Queue
```

创建 QP 时要指定它使用哪个 CQ：

```c
struct ibv_qp_init_attr attr = {
    .send_cq = cq,
    .recv_cq = cq,
    .qp_type = IBV_QPT_RC,
    .cap = {
        .max_send_wr = 128,
        .max_recv_wr = 128,
        .max_send_sge = 1,
        .max_recv_sge = 1,
    },
};

struct ibv_qp *qp = ibv_create_qp(pd, &attr);
```

入门阶段使用 `IBV_QPT_RC`，也就是 Reliable Connection。

QP 创建出来后不能直接用，需要走状态机：

```text
RESET -> INIT -> RTR -> RTS
```

这个会在第四章详细讲。

## 7. SGE：Scatter/Gather Entry

SGE 描述一段本地内存：

```c
struct ibv_sge sge = {
    .addr = (uintptr_t)buf,
    .length = len,
    .lkey = mr->lkey,
};
```

一个 WR 可以带多个 SGE，用来描述分散的内存片段。入门阶段先用一个 SGE，降低复杂度。

## 8. WR：Work Request

WR 是提交给 QP 的任务。

发送类 WR：

```c
struct ibv_send_wr wr = {
    .wr_id = 1,
    .sg_list = &sge,
    .num_sge = 1,
    .opcode = IBV_WR_SEND,
    .send_flags = IBV_SEND_SIGNALED,
};
```

接收类 WR：

```c
struct ibv_recv_wr wr = {
    .wr_id = 2,
    .sg_list = &sge,
    .num_sge = 1,
};
```

`wr_id` 是应用自己放进去的标识。completion 回来时，WC 会带回相同的 `wr_id`，方便你知道是哪条 WR 完成。

## 9. WC：Work Completion

WC 是完成结果。

常用字段：

| 字段       | 作用                               |
| ---------- | ---------------------------------- |
| `wr_id`    | 对应提交时的 WR ID                 |
| `status`   | 成功或失败原因                     |
| `opcode`   | 完成的操作类型                     |
| `byte_len` | 接收到的数据长度，主要用于 receive |
| `qp_num`   | 相关 QP 编号                       |

注意：`ibv_post_send()` 返回 0 只表示 WR 成功提交到 QP，不表示网络操作完成。最终结果要看 WC。

## 10. 本章小结

verbs 对象模型可以压缩成一句话：

```text
把内存注册成 MR，用 SGE 描述 MR，用 WR 提交到 QP，再从 CQ 读取 WC。
```

后续章节所有代码都会围绕这条链路展开。下一章先搭建 RXE 实验环境，确保没有真实 RDMA 网卡时也能练习 verbs 程序。
