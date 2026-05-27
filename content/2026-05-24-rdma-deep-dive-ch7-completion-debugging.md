---
title: "RDMA 深度探索（七）：Completion Queue 与调试方法"
date: 2026-05-24
description: "围绕 CQ/WC 讲解 RDMA 操作完成语义、常见错误码、RNR、权限错误、GID 问题和系统化排查方法。"
tags: [rdma, series, debugging, libibverbs, linux]
---

> [!info] RDMA 深度探索系列
> 0. [[2026-05-24-rdma-deep-dive-series-index|系列索引]]
> 6. [[2026-05-24-rdma-deep-dive-ch6-read-write|第六章：RDMA Read/Write]]
> 7. **第七章：Completion Queue 与调试方法**
> 8. [[2026-05-24-rdma-deep-dive-ch8-performance-roadmap|第八章：性能优化路线]]

# RDMA 深度探索（七）：Completion Queue 与调试方法

RDMA 调试的第一原则是：不要只看 `ibv_post_send()` 的返回值。`post` 成功只表示 WR 被提交到 QP，真正的执行结果在 Completion Queue 里。

## 1. Completion 的语义

发送端：

```text
ibv_post_send() == 0
```

只代表 WR 进入发送队列。

真正完成要看：

```c
struct ibv_wc wc;
int n = ibv_poll_cq(cq, 1, &wc);
```

并且必须检查：

```c
wc.status == IBV_WC_SUCCESS
```

如果 `status` 不是成功，`opcode`、`byte_len` 等字段不一定都有有效语义。

## 2. 为什么有时 poll 不到 completion

常见原因：

| 原因 | 说明 |
| --- | --- |
| 没有 `IBV_SEND_SIGNALED` | unsignaled WR 不产生 send completion |
| poll 错了 CQ | QP 绑定的 CQ 和当前 poll 的 CQ 不是同一个 |
| QP 没到 RTS | WR 没有真正执行 |
| 操作还在重试 | 例如 RNR 或网络丢包 |
| CQ 深度不够 | completion 溢出会造成严重问题 |

入门阶段建议：所有 send WR 都加 `IBV_SEND_SIGNALED`。

## 3. 常见 WC 状态

不同版本头文件里的枚举值可能略有差异，但常见状态包括：

| 状态 | 常见原因 |
| --- | --- |
| `IBV_WC_SUCCESS` | 操作成功 |
| `IBV_WC_LOC_LEN_ERR` | 本地 SGE 长度或接收 buffer 长度不匹配 |
| `IBV_WC_LOC_PROT_ERR` | 本地内存权限或 lkey 错误 |
| `IBV_WC_WR_FLUSH_ERR` | QP 进入错误态后，队列中 WR 被 flush |
| `IBV_WC_RETRY_EXC_ERR` | 重试次数耗尽，可能远端不可达 |
| `IBV_WC_RNR_RETRY_EXC_ERR` | 远端没有 receive WR，RNR 重试耗尽 |
| `IBV_WC_REM_ACCESS_ERR` | 远端访问权限错误，常见于 rkey 或 MR 权限问题 |

打印错误时至少输出：

```text
wr_id
status
opcode
vendor_err
qp_num
byte_len
```

## 4. RNR：Receiver Not Ready

RNR 是 Send/Recv 入门最常见问题。

触发条件：

```text
发送端 post_send 时，远端没有可用 receive WR。
```

解决方案：

- 建立连接后，接收端先 post_recv。
- receive queue 深度要覆盖可能的并发消息。
- 消费一个 receive completion 后，及时补充新的 receive WR。
- 调大 `rnr_retry` 只能缓解，不能替代正确的 receive 管理。

## 5. 权限错误

RDMA Read/Write 相关错误很多都来自 MR 权限。

检查表：

```text
本地 SGE 使用的 lkey 是否来自本地 MR？
远端 rkey 是否来自远端 MR？
RDMA Write 的远端 MR 是否有 REMOTE_WRITE？
RDMA Read 的远端 MR 是否有 REMOTE_READ？
本地接收 RDMA Read 数据的 buffer 是否有 LOCAL_WRITE？
MR 是否已经 deregister？
```

权限错误不要靠猜，直接打印：

```text
local addr
local lkey
remote addr
remote rkey
mr length
access flags
```

## 6. QP 状态错误

通信失败时确认 QP 状态：

```c
struct ibv_qp_attr attr;
struct ibv_qp_init_attr init_attr;

ibv_query_qp(qp, &attr, IBV_QP_STATE, &init_attr);
```

如果 QP 进入 ERR，队列里尚未完成的 WR 可能返回 `IBV_WC_WR_FLUSH_ERR`。

这时不要继续往这个 QP 上叠加操作。先记录错误现场，再销毁重建。

## 7. RoCE GID 问题

RoCE 下常见现象：

```text
设备能看到
QP 能创建
状态能切到 RTS
但通信失败或 retry exceeded
```

排查：

```bash
show_gids
ibv_devinfo -v
rdma link
ip addr
```

程序里建议把 GID index 做成命令行参数，并在启动时打印：

```text
device
port
gid_index
gid
qpn
psn
```

## 8. 最小日志模板

RDMA demo 至少打印：

```text
local:
  device
  port
  lid/gid
  qpn
  psn
  buffer addr
  lkey/rkey

remote:
  lid/gid
  qpn
  psn
  remote addr
  rkey

completion:
  wr_id
  status
  opcode
  vendor_err
  byte_len
```

这些信息能解决大部分初学阶段问题。

## 9. 推荐排查顺序

```text
1. ibv_devices 是否看到设备
2. perftest 是否跑通
3. QP 是否成功到 RTS
4. 接收端是否提前 post_recv
5. post_send 是否返回 0
6. poll_cq 是否有 completion
7. wc.status 是否成功
8. addr/rkey/lkey/权限是否匹配
9. RoCE GID/MTU/网络是否正确
```

不要跳过 perftest。如果 perftest 都不通，优先排环境，而不是改自己的 verbs 代码。

## 10. 本章小结

RDMA 调试要围绕 completion 和状态机展开：

- `post` 成功不是完成。
- `wc.status` 是最终结果。
- RNR 通常是 receive WR 管理问题。
- 权限错误通常是 MR access flags、lkey、rkey、remote addr 问题。
- RoCE 失败经常和 GID、MTU、网络配置有关。

下一章进入性能优化，讨论 batch、inline、unsignaled completion、NUMA 和 CQ 压力。
