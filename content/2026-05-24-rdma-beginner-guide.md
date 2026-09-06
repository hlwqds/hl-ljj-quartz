---
title: "RDMA 入门教程：从概念到第一个 verbs 程序"
date: 2026-05-24 00:00:00
description: "面向 Linux/C 工程师的 RDMA 入门指南，覆盖核心概念、实验环境、send/recv、RDMA Write/Read 和常见调试方法。"
tags: [rdma, networking, linux, performance]
---

# RDMA 入门教程：从概念到第一个 verbs 程序

> [!info] RDMA 深度探索系列
> 本文是单篇快速总览。系统化学习请从 [[index-2026-05-24|RDMA 深度探索系列索引]] 开始。

RDMA 的学习门槛不在“API 很多”，而在编程模型和普通 socket 完全不同。socket 程序通常围绕 `send()`、`recv()`、文件描述符和内核协议栈展开；RDMA 程序则围绕内存注册、队列、工作请求和完成事件展开。

本文面向已经熟悉 C 语言、Linux 和基本网络编程的读者。读完后，你应该能做到三件事：

1. 解释 RDMA 为什么低延迟、低 CPU 占用。
2. 看懂 RDMA verbs 程序里的 PD、MR、CQ、QP、WR、WC。
3. 按照固定流程写出最小 send/recv 程序，并继续扩展到 RDMA Write/Read。

本文默认从 RC，也就是 Reliable Connection 类型的 QP 入门。RC 最接近“可靠连接”的直觉，也是初学 verbs 编程最合适的起点。

## 1. RDMA 解决什么问题

传统 TCP 收发数据时，数据通常要经过应用、内核协议栈、网卡驱动和网卡。这个过程很通用，但在高性能场景里会带来几个成本：

- 数据在用户态和内核态之间拷贝。
- CPU 参与协议处理、包处理和唤醒。
- 系统调用和上下文切换增加延迟。
- 高吞吐时 CPU 容易被网络处理占满。

RDMA 的核心思想是：

> 让一台机器的网卡直接访问另一台机器已经授权的内存区域，并把完成结果通知应用。

这里有两个关键词。

第一个是“已经授权”。远端不能随便读写任意地址，应用必须先把一段内存注册给网卡，拿到访问 key。

第二个是“通知应用”。应用不是调用 `recv()` 等待内核返回数据，而是向网卡提交任务，然后从完成队列里轮询结果。

可以粗略对比：

| 模型       | 数据路径                                         | 应用接口                                    | CPU 参与度 |
| ---------- | ------------------------------------------------ | ------------------------------------------- | ---------- |
| TCP socket | 应用 -> 内核 -> 网卡 -> 网络 -> 内核 -> 应用     | `send()` / `recv()`                         | 较高       |
| RDMA       | 应用注册内存 -> 网卡直接搬运数据 -> 应用轮询完成 | `post_send()` / `post_recv()` / `poll_cq()` | 较低       |

RDMA 常见于分布式存储、HPC、数据库、参数服务器、NVMe-oF 和低延迟交易系统。

## 2. 先认识几种 RDMA 网络

RDMA 不是一种单独的网线或协议栈，常见实现有三类：

| 类型       | 说明                                       | 常见场景             |
| ---------- | ------------------------------------------ | -------------------- |
| InfiniBand | 原生 RDMA 网络，需要 IB 交换机和 HCA       | HPC、专用集群        |
| RoCE       | RDMA over Converged Ethernet，跑在以太网上 | 数据中心、高性能存储 |
| iWARP      | RDMA over TCP                              | 相对少见             |

RoCE 又分两类：

- RoCE v1：以太网二层协议，不跨三层路由。
- RoCE v2：基于 UDP/IP，可以跨三层网络。

如果只是学习 verbs 编程，可以先用 Soft-RoCE，也叫 RXE。它用软件模拟 RoCE 设备，不需要真正的 RDMA 网卡，但性能不能代表真实硬件。

## 3. RDMA 编程的核心对象

先不要急着写代码。RDMA verbs 程序里最常见的对象如下：

| 概念       | 全称                            | 作用                              |
| ---------- | ------------------------------- | --------------------------------- |
| HCA / RNIC | Host Channel Adapter / RDMA NIC | 支持 RDMA 的网卡                  |
| Context    | Device Context                  | 打开 RDMA 设备后得到的上下文      |
| PD         | Protection Domain               | 资源隔离域，MR 和 QP 都挂在 PD 下 |
| MR         | Memory Region                   | 注册给网卡访问的一段内存          |
| CQ         | Completion Queue                | 完成队列，保存已完成 WR 的结果    |
| QP         | Queue Pair                      | 队列对，包含发送队列和接收队列    |
| WR         | Work Request                    | 应用提交给网卡的工作请求          |
| WC         | Work Completion                 | 网卡写入 CQ 的完成结果            |
| SGE        | Scatter/Gather Entry            | 描述一段本地内存的位置和长度      |

最重要的是 QP、MR、CQ。

QP 是通信端点。对 RC QP 来说，两端的 QP 需要互相连接，连接成功后才能通信。QP 里面有两个队列：

```text
QP = Send Queue + Receive Queue
```

MR 是注册过的内存。RDMA 不能直接操作任意 `malloc()` 出来的地址，必须先注册：

```text
普通内存 -> ibv_reg_mr() -> MR
```

注册后会得到两个 key：

| key    | 含义                       |
| ------ | -------------------------- |
| `lkey` | 本地网卡访问本地 MR 时使用 |
| `rkey` | 远端网卡访问这块 MR 时使用 |

CQ 是完成通知的地方。`ibv_post_send()` 成功只代表 WR 成功提交给网卡，不代表数据已经发送完成。真正完成要看 `ibv_poll_cq()` 返回的 WC。

## 4. RDMA 程序的生命周期

一个最小 RC verbs 程序通常按下面的流程走：

```text
1. 获取 RDMA 设备列表
2. 打开一个 RDMA 设备
3. 创建 Protection Domain
4. 创建 Completion Queue
5. 创建 Queue Pair
6. 分配 buffer 并注册 Memory Region
7. 通过额外通道交换连接信息
8. 修改 QP 状态：RESET -> INIT -> RTR -> RTS
9. 提交 receive WR
10. 提交 send / write / read WR
11. 轮询 CQ，读取完成结果
12. 销毁资源
```

第 7 步很容易被忽略：verbs 本身只负责数据面，不负责帮你交换连接信息。实际程序通常会先用 TCP socket 交换这些信息：

| 信息           | 作用                                   |
| -------------- | -------------------------------------- |
| QP number      | 标识远端 QP                            |
| LID / GID      | 标识远端端口地址                       |
| PSN            | Packet Sequence Number，RC 连接需要    |
| remote address | RDMA Read/Write 要访问的远端虚拟地址   |
| rkey           | RDMA Read/Write 访问远端 MR 的权限 key |

可以把 TCP socket 理解为“控制面”，把 RDMA QP 理解为“数据面”。

## 5. 实验环境准备

### 5.1 安装基础工具

Ubuntu / Debian 上常用：

```bash
sudo apt update
sudo apt install -y rdma-core ibverbs-utils perftest
```

openEuler / RHEL 系上常用：

```bash
sudo dnf install -y rdma-core libibverbs-utils perftest
```

安装后先检查设备：

```bash
ibv_devices
ibv_devinfo
rdma link
```

如果有真实 RDMA 网卡，`ibv_devices` 应该能看到类似 `mlx5_0` 的设备。

### 5.2 使用 Soft-RoCE 学习

没有 RDMA 网卡时，可以用 RXE 做学习实验。常见流程如下：

```bash
sudo modprobe rdma_rxe
ip link show
sudo rdma link add rxe0 type rxe netdev eth0
rdma link
ibv_devices
```

其中 `eth0` 要替换成你机器上真实存在的网卡名。

如果要删除 RXE 设备：

```bash
sudo rdma link delete rxe0
```

RXE 适合理解 verbs 编程流程，不适合做性能结论。

### 5.3 先跑 perftest

在写代码前，先用成熟工具验证环境。两台机器上分别运行：

```bash
ib_send_bw
```

另一台指定服务端 IP：

```bash
ib_send_bw 192.168.1.10
```

再测试 RDMA Write：

```bash
ib_write_bw
ib_write_bw 192.168.1.10
```

如果 perftest 都跑不通，先不要写自己的程序。先排查设备、网络、权限和 GID 配置。

## 6. 第一个程序：send/recv

入门建议先写 send/recv，不要一开始写 RDMA Write。原因是 send/recv 更像消息通信，调试起来更直观。

send/recv 的基本规则是：

```text
接收端必须先 post_recv，发送端再 post_send。
```

如果接收端没有提前准备 receive WR，发送端可能遇到 RNR，也就是 Receiver Not Ready。

### 6.1 接收端流程

接收端要做的事情：

```text
1. 创建 RDMA 资源
2. 注册接收 buffer
3. 和发送端交换 QP 信息
4. 把 QP 切到 RTS
5. post_recv
6. poll CQ
7. 从 buffer 读取收到的数据
```

伪代码如下：

```c
char recv_buf[4096];

struct ibv_mr *mr = ibv_reg_mr(
    pd,
    recv_buf,
    sizeof(recv_buf),
    IBV_ACCESS_LOCAL_WRITE
);

struct ibv_sge sge = {
    .addr = (uintptr_t)recv_buf,
    .length = sizeof(recv_buf),
    .lkey = mr->lkey,
};

struct ibv_recv_wr wr = {
    .wr_id = 1,
    .sg_list = &sge,
    .num_sge = 1,
};

struct ibv_recv_wr *bad_wr = NULL;
int ret = ibv_post_recv(qp, &wr, &bad_wr);
```

注意：接收 buffer 的 MR 权限需要 `IBV_ACCESS_LOCAL_WRITE`，因为网卡要把收到的数据写入本地内存。

### 6.2 发送端流程

发送端要做的事情：

```text
1. 创建 RDMA 资源
2. 注册发送 buffer
3. 和接收端交换 QP 信息
4. 把 QP 切到 RTS
5. post_send
6. poll CQ
```

伪代码如下：

```c
char send_buf[] = "hello rdma";

struct ibv_mr *mr = ibv_reg_mr(
    pd,
    send_buf,
    sizeof(send_buf),
    0
);

struct ibv_sge sge = {
    .addr = (uintptr_t)send_buf,
    .length = sizeof(send_buf),
    .lkey = mr->lkey,
};

struct ibv_send_wr wr = {
    .wr_id = 2,
    .sg_list = &sge,
    .num_sge = 1,
    .opcode = IBV_WR_SEND,
    .send_flags = IBV_SEND_SIGNALED,
};

struct ibv_send_wr *bad_wr = NULL;
int ret = ibv_post_send(qp, &wr, &bad_wr);
```

`IBV_SEND_SIGNALED` 表示这条 WR 完成后需要在 CQ 里产生完成事件。初学阶段建议先全部加上，方便调试。

### 6.3 轮询完成队列

两端都需要轮询 CQ：

```c
struct ibv_wc wc;

while (1) {
    int n = ibv_poll_cq(cq, 1, &wc);
    if (n < 0) {
        /* poll failed */
        break;
    }
    if (n == 0) {
        continue;
    }
    if (wc.status != IBV_WC_SUCCESS) {
        /* print wc.status */
        break;
    }
    break;
}
```

初学时一定要打印 `wc.status`、`wc.opcode` 和 `wc.wr_id`。很多 RDMA 问题不是 `post_send()` 时报错，而是在 completion 里报错。

## 7. QP 状态转换

RC QP 不能创建后直接使用，必须经过状态转换：

```text
RESET -> INIT -> RTR -> RTS
```

每个状态需要设置不同字段。

### 7.1 INIT

INIT 表示 QP 已经绑定到本地端口，准备参与通信。

常见需要设置：

```text
qp_state = IBV_QPS_INIT
pkey_index = 0
port_num = 1
qp_access_flags = 访问权限
```

如果后续要支持 RDMA Read/Write，需要设置：

```text
IBV_ACCESS_REMOTE_READ
IBV_ACCESS_REMOTE_WRITE
```

### 7.2 RTR

RTR 是 Ready To Receive，表示 QP 已经知道远端是谁，可以接收远端数据。

常见需要设置：

```text
qp_state = IBV_QPS_RTR
path_mtu
dest_qp_num
rq_psn
max_dest_rd_atomic
min_rnr_timer
ah_attr
```

其中 `dest_qp_num`、远端 LID/GID、PSN 都需要通过控制面交换。

### 7.3 RTS

RTS 是 Ready To Send，表示 QP 可以发送。

常见需要设置：

```text
qp_state = IBV_QPS_RTS
timeout
retry_cnt
rnr_retry
sq_psn
max_rd_atomic
```

如果 QP 状态没有切对，后面的 `post_send()` 和 completion 很容易出现难懂的错误。

## 8. RDMA Write 和 RDMA Read

send/recv 跑通后，再看 RDMA 真正特别的地方：一端可以主动读写另一端内存。

### 8.1 RDMA Write

RDMA Write 的含义是：

```text
本端网卡把本地 buffer 的数据写入远端指定内存地址。
```

远端应用不需要提前 `post_recv()`。但远端必须提前注册内存，并把 `remote address` 和 `rkey` 通过控制面告诉本端。

本端 WR 需要带上：

```c
wr.opcode = IBV_WR_RDMA_WRITE;
wr.wr.rdma.remote_addr = remote_addr;
wr.wr.rdma.rkey = remote_rkey;
```

远端 MR 注册时必须允许远程写：

```c
IBV_ACCESS_LOCAL_WRITE | IBV_ACCESS_REMOTE_WRITE
```

典型流程：

```text
server 注册 buffer
server 把 addr + rkey 发给 client
client 注册本地 buffer
client 发起 RDMA Write
server 的 buffer 内容被网卡直接改写
```

### 8.2 RDMA Read

RDMA Read 的含义是：

```text
本端网卡从远端指定内存地址读取数据到本地 buffer。
```

本端 WR 需要带上：

```c
wr.opcode = IBV_WR_RDMA_READ;
wr.wr.rdma.remote_addr = remote_addr;
wr.wr.rdma.rkey = remote_rkey;
```

远端 MR 注册时必须允许远程读：

```c
IBV_ACCESS_REMOTE_READ
```

本地接收数据的 buffer 需要注册成本地 MR，并提供本地 `lkey`。

### 8.3 send/recv 和 read/write 的区别

| 操作       | 是否需要远端 post_recv | 是否需要 remote addr + rkey | 语义       |
| ---------- | ---------------------- | --------------------------- | ---------- |
| Send/Recv  | 需要                   | 不需要                      | 消息传递   |
| RDMA Write | 不需要                 | 需要                        | 写远端内存 |
| RDMA Read  | 不需要                 | 需要                        | 读远端内存 |

刚入门时可以这样理解：

- Send/Recv 是“我发一条消息给你”。
- RDMA Write 是“我把数据写到你授权给我的地址”。
- RDMA Read 是“我从你授权给我的地址读数据”。

## 9. 常见错误和排查方法

RDMA 程序调试难度比 socket 高。建议从第一天就养成打印关键状态的习惯。

### 9.1 没有提前 post_recv

现象：

```text
发送端 completion 失败，常见 RNR 相关错误。
```

原因：

```text
RC send 需要接收端提前准备 receive WR。
```

解决：

```text
连接建立完成后，接收端先 post_recv，再通知发送端发送。
```

### 9.2 MR 权限不够

现象：

```text
RDMA Write/Read completion 失败。
```

排查：

```text
检查远端 MR 是否带了 IBV_ACCESS_REMOTE_WRITE 或 IBV_ACCESS_REMOTE_READ。
检查本地 buffer 是否注册，并使用正确 lkey。
```

### 9.3 remote address 或 rkey 错误

现象：

```text
completion 返回权限或访问错误。
```

排查：

```text
打印 remote address 和 rkey。
确认地址来自远端注册过的 MR。
确认没有把本端地址当作远端地址。
```

### 9.4 GID index 选错

RoCE 环境里 GID 很重要。现象可能是 QP 切换成功，但通信失败。

排查命令：

```bash
show_gids
ibv_devinfo
rdma link
```

RoCE v2 通常需要选择对应 IPv4/IPv6 地址的 GID index。

### 9.5 `post_send()` 成功但没有完成事件

可能原因：

- 没有设置 `IBV_SEND_SIGNALED`。
- poll 的 CQ 不是这个 QP 绑定的 CQ。
- QP 状态不对。
- WR 卡在重试，最终才报错。

入门阶段建议所有 send WR 都加 `IBV_SEND_SIGNALED`。

## 10. 推荐学习路线

RDMA 入门不要追求一次理解所有特性。建议按下面顺序推进：

```text
1. 用 ibv_devices / ibv_devinfo 确认环境
2. 跑通 ib_send_bw / ib_write_bw
3. 阅读并运行 rc_pingpong 类示例
4. 自己实现最小 send/recv
5. 在 send/recv 基础上加入 RDMA Write
6. 再加入 RDMA Read
7. 学习 rdma_cm，减少手写连接管理代码
8. 学习 SRQ、inline、unsignaled completion、batching 等优化
```

进阶主题可以后面再看：

| 主题            | 价值                             |
| --------------- | -------------------------------- |
| `rdma_cm`       | 简化连接管理                     |
| SRQ             | 多 QP 共享接收队列，减少内存消耗 |
| Inline Send     | 小消息减少一次 DMA               |
| Unsignaled WR   | 降低 CQ 压力                     |
| Atomic          | 远程原子操作                     |
| ODP             | 按需分页注册内存                 |
| UCX / libfabric | 更高层通信框架                   |

## 11. 一张速查表

| 你想做什么       | verbs 里的动作                                |
| ---------------- | --------------------------------------------- |
| 使用 RDMA 设备   | `ibv_get_device_list()` + `ibv_open_device()` |
| 隔离资源         | `ibv_alloc_pd()`                              |
| 让网卡能访问内存 | `ibv_reg_mr()`                                |
| 创建完成队列     | `ibv_create_cq()`                             |
| 创建通信端点     | `ibv_create_qp()`                             |
| 提交接收请求     | `ibv_post_recv()`                             |
| 提交发送请求     | `ibv_post_send()`                             |
| 等待完成         | `ibv_poll_cq()`                               |
| 写远端内存       | `IBV_WR_RDMA_WRITE`                           |
| 读远端内存       | `IBV_WR_RDMA_READ`                            |

## 12. 小练习

练习 1：环境验证

```text
使用 ibv_devices 和 ibv_devinfo 确认本机 RDMA 设备。
如果没有硬件，配置 RXE 并让 ibv_devices 能看到 rxe 设备。
```

练习 2：跑通带宽测试

```text
在两台机器或两个环境之间跑通 ib_send_bw。
再跑 ib_write_bw，记录吞吐和延迟。
```

练习 3：最小 send/recv

```text
接收端提前 post_recv。
发送端发送字符串 "hello rdma"。
接收端 poll CQ 后打印 buffer 内容。
```

练习 4：RDMA Write

```text
接收端注册一块 buffer，并把 addr + rkey 发给发送端。
发送端使用 IBV_WR_RDMA_WRITE 写入远端 buffer。
接收端等待一段时间后打印 buffer，确认内容变化。
```

练习 5：故意制造错误

```text
去掉 IBV_ACCESS_REMOTE_WRITE，观察 RDMA Write 的 completion 错误。
去掉接收端 post_recv，观察 send/recv 的错误行为。
去掉 IBV_SEND_SIGNALED，观察 CQ 是否还能收到完成事件。
```

## 13. 总结

RDMA 入门要抓住四条主线：

1. 所有数据操作都围绕注册内存展开。
2. QP 是通信端点，CQ 是完成通知。
3. verbs 只管数据面，连接信息通常要自己交换。
4. `post_*` 成功不等于操作完成，completion 才是最终结果。

只要把 PD、MR、CQ、QP、WR、WC 这组概念串起来，RDMA verbs 程序就不再神秘。下一步最值得做的是：先跑通 `rc_pingpong`，再自己手写一个最小 send/recv，最后把它改造成 RDMA Write demo。
