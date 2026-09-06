---
title: "VPP 深入探讨 ch19：VPP + DPDK"
date: 2026-04-10 03:30:00
tags: [vpp, dpdk, pmd, buffer, zero-copy, hugepage, interrupt, polling]
description: "深入解析 VPP 与 DPDK 集成：PMD 驱动、buffer 映射、零拷贝、中断与轮询模式、性能调优"
---

# VPP 深入探讨 ch19：VPP + DPDK

> [!abstract] 核心要点
> VPP 使用 DPDK 作为其数据平面库。本章深入解析 DPDK PMD、buffer 映射、零拷贝机制、中断与轮询模式以及联合调优。

> [!tip] 延伸阅读
> VPP 和另一个 VPP/DPDK 应用之间通过共享内存交换 packet 时，常用 memif：
> [[ch19a-memif|VPP 深入探讨 ch19a：memif 内存接口]]

## 1. VPP + DPDK 概述

### 1.1 关系

```
┌─────────────────────────────────────────────────────────────┐
│                    VPP + DPDK 关系                        │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │                    VPP                                │  │
│  │                                                       │  │
│  │  - 图处理引擎                                         │  │
│  │  - Node 注册                                          │  │
│  │  - CLI/API                                           │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │                  VCL (VPP Communications Library)    │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │                    DPDK                               │  │
│  │                                                       │  │
│  │  - EAL (环境抽象层)                                    │  │
│  │  - Mbuf/Buffer                                       │  │
│  │  - Poll Mode Drivers (PMD)                           │  │
│  │  - Crypto PMD                                        │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 集成架构

```
┌─────────────────────────────────────────────────────────────┐
│                    VPP 数据路径                             │
│                                                              │
│  NIC                                                         │
│   ↓ DMA                                                      │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              DPDK PMD                                 │  │
│  │                                                       │  │
│  │  ┌──────────────────────────────────────────────┐   │  │
│  │  │        rte_mbuf (DPDK)                       │   │  │
│  │  └──────────────────────────────────────────────┘   │  │
│  └──────────────────────────────────────────────────────┘  │
│   ↓                                                          │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              VPP vlib_buffer                         │  │
│  │                                                       │  │
│  │  ┌──────────────────────────────────────────────┐   │  │
│  │  │        vlib_buffer_t (VPP)                    │   │  │
│  │  │        + packet data                           │   │  │
│  │  └──────────────────────────────────────────────┘   │  │
│  └──────────────────────────────────────────────────────┘  │
│   ↓                                                          │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              VPP Graph Nodes                          │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

## 2. PMD (Poll Mode Driver)

### 2.1 PMD 原理

```
PMD vs 中断驱动：

中断驱动：
  - NIC 收到包 → 中断 CPU → 读取包
  - 中断开销大，不适合高速网络

Poll Mode Driver：
  - CPU 不断轮询 NIC 寄存器
  - 无中断，零延迟
  - CPU 100% 利用率

┌─────────────────────────────────────────────────────────────┐
│                    PMD 轮询                                 │
│                                                              │
│  while (1) {                                                 │
│      // 轮询 RX                                            │
│      n = rte_eth_rx_burst(port, queue, bufs, MAX_BURST);   │
│      if (n > 0) {                                          │
│          process_packets(bufs, n);                          │
│      }                                                      │
│      // 轮询 TX completion                                 │
│      rte_eth_tx_burst_done_cleanup();                      │
│  }                                                          │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 VPP 中的 PMD

```c
// VPP PMD 初始化
static int
dpdk_port_init(u16 port_id, struct rte_eth_conf *conf)
{
    struct rte_eth_dev_info dev_info;

    // 获取设备信息
    rte_eth_dev_info_get(port_id, &dev_info);

    // 配置 RX 队列
    rte_eth_rx_queue_setup(
        port_id,
        rx_queue_id,           // 队列号
        RX_QUEUE_SIZE,          // 队列大小
        rte_eth_dev_socket_id(port_id),  // NUMA
        NULL,                   // rx_conf
        mb_pool->mbuf_pool);    // mbuf pool

    // 配置 TX 队列
    rte_eth_tx_queue_setup(
        port_id,
        tx_queue_id,
        TX_QUEUE_SIZE,
        rte_eth_dev_socket_id(port_id),
        NULL);

    // 启动端口
    rte_eth_dev_start(port_id);

    // 启用 promiscuous mode
    rte_eth_promiscuous_enable(port_id);

    return 0;
}
```

### 2.3 PMD 配置

```bash
# VPP startup.conf 配置 DPDK
dpdk {
    # 启用 DPDK
    dev default {
        # RX 队列大小
        num-rx-queues 1
        num-tx-queues 1
    }

    # 特定设备配置
    dev 0000:3d:00.0 {
        # 驱动
        name "GigabitEthernet"

        # 队列数
        num-rx-queues 4
        num-tx-queues 4

        # 关闭 checksum offload (如果不需要)
        # no-tx-checksum-offload
    }
}
```

## 3. Buffer 映射

### 3.1 mbuf 到 vlib_buffer 转换

```c
// DPDK mbuf
struct rte_mbuf {
    // mbuf 数据指针
    char *buf_addr;           // 缓冲区起始地址
    uint16_t data_off;        // 数据起始偏移
    uint32_t data_len;        // 数据长度

    // Scatter-gather
    uint16_t nb_segs;         // segment 数
    struct rte_mbuf *next;    // 下一个 segment
};

// VPP vlib_buffer (嵌入 rte_mbuf)
struct vlib_buffer_t {
    // 嵌入 DPDK mbuf
    struct rte_mbuf mb;

    // VPP 扩展
    u16 current_data;
    u16 current_length;
    // ...
};
```

### 3.2 Buffer 映射

```c
// VPP 从 mbuf 获取 buffer
static inline vlib_buffer_t *
vlib_buffer_from_mbuf(struct rte_mbuf *mb)
{
    // vlib_buffer_t 嵌入在 mbuf 之前
    return (vlib_buffer_t *)
        ((char *)mb - sizeof(vlib_buffer_t));
}

// VPP 获取 mbuf
static inline struct rte_mbuf *
vlib_buffer_to_mbuf(vlib_buffer_t *b)
{
    return &b->mb;
}

// 获取包数据指针
static inline void *
vlib_buffer_get_current(vlib_buffer_t *b)
{
    return (char *)b->mb.buf_addr + b->current_data;
}
```

### 3.3 Buffer Pool 共享

```c
// VPP 和 DPDK 共享 mbuf pool
static struct rte_mempool *
create_shared_mbuf_pool(void)
{
    struct rte_mempool *mp;

    // 创建 hugepage-backed pool
    mp = rte_pktmbuf_pool_create(
        "vpp_buffer_pool",
        POOL_SIZE,              // pool 大小
        CACHE_SIZE,            // per-lcore cache
        sizeof(vlib_buffer_t), // headroom
        DEFAULT_MBUF_SIZE,     // data room
        rte_socket_id());       // NUMA socket

    return mp;
}
```

## 4. 零拷贝

### 4.1 零拷贝层级

```
┌─────────────────────────────────────────────────────────────┐
│                    零拷贝层级                               │
│                                                              │
│  Level 0: 完整拷贝                                         │
│    NIC → Buffer → CPU → Buffer → NIC                      │
│                                                              │
│  Level 1: DMA 零拷贝                                        │
│    NIC DMA → Buffer → NIC DMA                             │
│               ↑                                              │
│           直接处理                                           │
│                                                              │
│  Level 2: 共享内存                                          │
│    Buffer 共享给多个 consumer (如 vhost-user)              │
│                                                              │
│  Level 3: 完全零拷贝                                        │
│    整个 packet buffer 直接传递，无拷贝                      │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 RX 零拷贝

```c
// RX 直接发送到 VPP graph
static inline u32
dpdk_rx_input(vlib_main_t *vm,
               vlib_node_runtime_t *node,
               u16 port_id,
               u16 queue_id)
{
    struct rte_mbuf *mbs[MAX_BURST];
    u32 bi[MAX_BURST];

    // 批量接收
    u16 n = rte_eth_rx_burst(port_id, queue_id, mbs, MAX_BURST);

    if (n == 0) return 0;

    // 转换 mbuf 到 buffer 索引
    for (int i = 0; i < n; i++) {
        bi[i] = vlib_buffer_from_mbuf(mbs[i])->buffer_pool_index;
    }

    // 添加到 graph
    vlib_buffer_enqueue_to_next(vm, node, bi, n);

    return n;
}
```

### 4.3 TX Buffer Reuse

```c
// TX buffer reuse
static inline void
dpdk_tx_buffer_reuse(vlib_main_t *vm,
                      struct rte_mbuf **mbs,
                      u16 n)
{
    // 如果 buffer 可以复用，直接放回 ring
    for (int i = 0; i < n; i++) {
        if (mbs[i]->pool == vm->mbuf_pool) {
            // 可以 reuse
            rte_mbuf_refcnt_update(mbs[i], -1);
            if (rte_mbuf_refcnt_read(mbs[i]) == 0) {
                // 没有引用，直接 reuse
                rte_mbuf_raw_alloc(mbs[i]);
            }
        }
    }
}
```

## 5. 中断与轮询

### 5.1 自适应模式

```
Adaptive Interrupt + Poll：

┌─────────────────────────────────────────────────────────────┐
│                    自适应模式                               │
│                                                              │
│  低流量：                                                    │
│    → 中断模式 (省 CPU)                                      │
│    ↓                                                         │
│  流量增加：                                                  │
│    → 混合模式 (中断 + 轮询)                                 │
│    ↓                                                         │
│  高流量：                                                    │
│    → 全轮询 (最高性能)                                      │
└─────────────────────────────────────────────────────────────┘
```

### 5.2 中断配置

```bash
# 启用中断模式
dpdk {
    dev 0000:3d:00.0 {
        interrupt  # 启用中断
        intr-conf rx  # RX 中断
    }
}
```

### 5.3 混合模式实现

```c
// 混合模式
static inline void
hybrid_mode_rx(struct dpdk_device *dev)
{
    if (dev->interrupt_mode) {
        // 检查中断
        if (dev->intr_count > 0) {
            // 有中断，处理
            process_packets(dev);
            dev->intr_count = 0;
        } else if (dev->poll_mode) {
            // 也进行少量轮询
            u16 n = rte_eth_rx_burst(...);
            if (n > 0) process_packets(...);
        }
    } else {
        // 全轮询
        u16 n = rte_eth_rx_burst(...);
        process_packets(...);
    }
}
```

## 6. 性能调优

### 6.1 RX/TX Burst 大小

```bash
# VPP 配置 burst 大小
vpp# set interface rx burst 32
vpp# set interface tx burst 32

# 建议：
# - 小 burst：低延迟，但 CPU 开销高
# - 大 burst：高吞吐，但延迟增加
# - 典型值：32-64
```

### 6.2 NUMA 优化

```bash
# 查看 NUMA
lstopo

# 配置每个 socket 的 hugepage 和内存
dpdk {
    socket-mem 1024,1024  # Socket 0: 1GB, Socket 1: 1GB
}
```

### 6.3 队列配置

```bash
# 建议配置
dpdk {
    dev default {
        # RX 队列数 = CPU 核心数
        num-rx-queues 4

        # TX 队列数 = CPU 核心数
        num-tx-queues 4

        # 队列大小
        rx-queue-size 1024
        tx-queue-size 1024
    }
}
```

## 7. 联合优化

### 7.1 VPP + DPDK 参数

```
VPP 和 DPDK 联合调优参数：

┌─────────────────────────────────────────────────────────────┐
│                    联合参数                                  │
│                                                              │
│  Hugepage: 2MB x 1024 = 2GB per socket                      │
│  Buffer pool: 131072 buffers per socket                     │
│  RX queues: 4 per port                                      │
│  TX queues: 4 per port                                       │
│  Burst size: 32                                              │
│  Worker threads: 3                                          │
│                                                              │
│  预期性能：                                                  │
│  - 64B packets: ~10-15 Mpps                                 │
│  - 1400B packets: ~5-8 Gbps                                 │
└─────────────────────────────────────────────────────────────┘
```

### 7.2 监控

```bash
# VPP 显示 DPDK 统计
vpp# show hardware

# 示例输出：
# GigabitEthernet0/8/0
#   Driver: i40e
#   RX queues: 4
#   TX queues: 4
#   RX packets: 1000000000
#   TX packets: 999999999
#   RX errors: 0
#   TX errors: 0

# DPDK stats
vpp# show dpdk dev stats
```

## 8. 总结

VPP + DPDK 架构：

```
NIC (DMA) → DPDK PMD → rte_mbuf → vlib_buffer → VPP Graph → ...
                         ↓
                  Hugepage Memory
```

关键优化点：

| 组件          | 优化       | 效果          |
| ------------- | ---------- | ------------- |
| **Hugepage**  | 2MB x 1024 | 减少 TLB miss |
| **Burst**     | 32-64      | 平衡吞吐/延迟 |
| **Queues**    | 4-8        | 多核扩展      |
| **NUMA**      | 本地分配   | 减少跨 NUMA   |
| **Zero-copy** | mbuf 共享  | 减少拷贝      |

DPDK 提供：

- 高效的内存管理
- 轮询模式驱动
- 跨平台抽象

VPP 提供：

- 高层图处理
- 协议栈
- 管理接口

---

## 参考资源

- [DPDK 文档](https://doc.dpdk.org/)
- [VPP DPDK](https://wiki.fd.io/view/VPP/DPDK_Front_Panel_Operations)
- [DPDK Performance](https://doc.dpdk.org/guides/prog_guide/perf_opt.html)
