---
title: "RDMA 深度探索（八）：性能优化路线"
date: 2026-05-24
description: "建立 RDMA 性能优化路线图，覆盖 batching、inline、unsignaled WR、CQ 压力、NUMA、内存注册和测试方法。"
tags: [rdma, series, performance, numa, networking]
---

> [!info] RDMA 深度探索系列 0. [[index-2026-05-24|系列索引]] 7. [[ch7-completion-debugging|第七章：Completion 与调试]] 8. **第八章：性能优化路线**

# RDMA 深度探索（八）：性能优化路线

RDMA 程序跑通之后，下一步才是性能优化。不要在程序还不稳定时先做复杂优化，否则会把正确性问题和性能问题混在一起。

## 1. 先建立基线

优化前先用标准工具建立硬件基线：

```bash
ib_send_bw
ib_write_bw
ib_read_bw
ib_send_lat
ib_write_lat
ib_read_lat
```

自己的程序性能如果远低于 perftest，先查程序结构；如果 perftest 本身就不理想，先查硬件、链路、PCIe、NUMA 和网络配置。

## 2. Batch：减少每次处理的固定成本

一次只提交一个 WR、一次只 poll 一个 WC，逻辑简单，但固定成本高。

优化方向：

- 一次 post 多个 WR 链表。
- 一次 poll 多个 WC。
- 接收端批量补充 receive WR。

poll 多个 completion：

```c
struct ibv_wc wc[32];
int n = ibv_poll_cq(cq, 32, wc);
```

batch 的目标是摊薄函数调用、doorbell、cache miss 等成本。

## 3. Inline Send

小消息可以使用 inline send：

```c
wr.send_flags = IBV_SEND_SIGNALED | IBV_SEND_INLINE;
```

inline 的含义是把小数据直接放进 WQE，避免网卡再 DMA 读取本地 buffer。

适用场景：

- 小消息。
- 控制面消息。
- 延迟敏感路径。

限制：

- 大小受 QP capability 限制。
- 创建 QP 时需要配置 `max_inline_data`。
- 超过设备能力会失败。

## 4. Unsignaled WR

每条 signaled WR 都会产生 completion。高吞吐场景下，CQ 压力会很大。

优化方式是大部分 WR 不要 completion，每隔 N 条发一条 signaled WR：

```text
WR 1   unsignaled
WR 2   unsignaled
...
WR 64  signaled
```

好处：

- 降低 CQ 写入压力。
- 降低 poll 开销。

风险：

- 必须定期 signaled，否则无法回收资源和发现错误。
- 出错时定位更复杂。

入门程序先全部 signaled，性能优化阶段再改。

## 5. CQ 深度与 QP 深度

QP 和 CQ 深度要匹配工作负载。

如果 send queue 太小：

```text
ibv_post_send 可能失败，或者应用无法保持足够 outstanding WR。
```

如果 receive queue 太小：

```text
容易 RNR。
```

如果 CQ 太小：

```text
completion 溢出，后果严重。
```

经验做法：

- 初学阶段先开大一点。
- 稳定后根据最大 outstanding WR 和 poll 周期收敛。
- 对收发 CQ 分离，避免互相干扰。

## 6. NUMA 亲和

RDMA 网卡挂在某个 NUMA node 上。如果应用线程和内存分配在远端 NUMA node，性能会明显下降。

检查设备 NUMA：

```bash
cat /sys/class/infiniband/mlx5_0/device/numa_node
```

查看 PCIe 拓扑：

```bash
lspci -tv
numactl --hardware
```

优化方向：

- 工作线程绑到网卡所在 NUMA node。
- buffer 在本地 NUMA node 分配。
- CQ poll 线程和 QP 使用同一 NUMA node。

## 7. 内存注册成本

`ibv_reg_mr()` 不是轻量操作。它涉及页固定、权限建立和设备映射。

不要在热路径里频繁注册/注销 MR。

推荐模式：

```text
启动时注册大块内存
应用自己做 buffer 分配
退出时统一 deregister
```

如果业务必须动态内存管理，可以考虑：

- MR cache。
- hugepage。
- ODP，但先理解普通 MR。

## 8. RDMA Read 与 Write 的性能差异

RDMA Write 通常更容易获得高吞吐，因为发起端只负责推数据到远端。

RDMA Read 需要从远端拉数据，受并发 read credit、往返延迟和 `max_rd_atomic` 影响更明显。

如果业务允许，常见设计会倾向：

```text
数据面用 RDMA Write
控制面用 Send/Recv
少量 metadata 用 RDMA Read
```

这不是绝对规则，但适合作为初始设计。

## 9. 性能测试不要只看吞吐

至少同时看：

| 指标          | 说明                   |
| ------------- | ---------------------- |
| 平均延迟      | 常规请求成本           |
| P99/P999      | 尾延迟                 |
| 吞吐          | 单连接和多连接带宽     |
| CPU 占用      | 是否真的节省 CPU       |
| CQ poll 次数  | 是否 busy polling 过重 |
| retry / error | 是否有隐藏网络问题     |

高吞吐但 P999 很差，对很多低延迟业务没有意义。

## 10. 优化顺序建议

推荐顺序：

```text
1. 先用 perftest 建立硬件基线
2. 确认自己的程序 correctness 稳定
3. 调整 QP/CQ 深度
4. 批量 post 和批量 poll
5. 小消息启用 inline
6. 引入 unsignaled WR
7. 做 NUMA 亲和
8. 优化 MR 管理
9. 再考虑 SRQ、multi-QP、multi-thread
```

不要一开始就上所有优化。每次只改一个变量，并记录吞吐、延迟和 CPU。

## 11. 本章小结

RDMA 性能优化的关键不是某一个魔法参数，而是减少固定成本、降低 CQ 压力、让内存和线程靠近网卡，并避免在热路径里做昂贵操作。

入门阶段先做到：

- 程序稳定。
- completion 正确。
- 没有 RNR 和 retry。
- perftest 基线清楚。

在这个基础上再做 batch、inline、unsignaled 和 NUMA 优化，收益才可解释。
