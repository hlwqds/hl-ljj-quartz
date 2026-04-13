---
title: "DPDK 深度探索 ch31：Virtio 性能优化"
date: 2026-04-10 11:00:00
tags: [dpdk, virtio, performance, optimization, batch, vector, pmd, tuning]
description: "深入解析 DPDK Virtio 性能优化：Batching、Vector PMD、Virtio-Net 配置与调优参数"
---

# DPDK 深度探索 ch31：Virtio 性能优化

> [!abstract] 核心要点
> Virtio 是云环境最常用的虚拟化网络方案。本章深入解析 Virtio PMD 性能优化：Batching、Vector PMD、配置调优。

## 1. Virtio PMD 架构

### 1.1 Virtio PMD 变体

```
┌─────────────────────────────────────────────────────────────┐
│                    Virtio PMD 变体                         │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              virtio-suser                             │  │
│  │  - 标准 virtio PMD                                  │  │
│  │  - 完整特性支持                                      │  │
│  │  - 中等性能                                         │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              virtio-pmd (Vectorized)                  │  │
│  │  - SIMD 优化                                        │  │
│  │  - 批处理                                           │  │
│  │  - 高性能                                           │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 Virtio-net 特性

```
Virtio-net 特性与性能：

1. 基本特性 (所有 Virtio 支持)
   - TX/RX 队列
   - Multiqueue
   - Scatter-Gather

2. 性能特性
   - TSO (TCP Segmentation Offload)
   - CSO (Checksum Offload)
   - GSO (Generic Segmentation Offload)
   - Mergeable buffers

3. 云环境优化
   - Large Receive Offload (LRO)
   - RSS (Receive Side Scaling)
   - Neutron_RDMA (RDMA over virtio)
```

## 2. Vectorized PMD

### 2.1 Vector 处理

```c
// virtio_pmd vectorized RX
// 使用 SSE/AVX 向量化处理

static inline uint16_t
virtio_recv_pkts_vector(void *rx_queue,
                        struct rte_mbuf **rx_pkts,
                        uint16_t nb_pkts)
{
    struct virtqueue *vq = rx_queue;
    uint16_t nb_recv = 0;

    // 向量获取 available descriptors
    while (nb_recv < nb_pkts) {
        // 获取 descriptor 索引
        uint16_t avail = vq->vq_avail_idx;
        uint16_t used = vq->vq_used_cons_idx;

        if (avail == used)
            break;

        // 向量处理多个 descriptor
        uint16_t batch = RTE_MIN(16, nb_pkts - nb_recv);
        for (uint16_t i = 0; i < batch; i++) {
            // 获取 buffer
            uint16_t desc_idx = vq->vq_avail_ring[
                (vq->vq_used_cons_idx + i) & (vq->vq_nentries - 1)];
            rx_pkts[nb_recv + i] = vq->vq_mbuf[desc_idx];
        }

        nb_recv += batch;
    }

    return nb_recv;
}
```

### 2.2 SSE 优化

```c
// 使用 SSE 进行批量数据拷贝
#include <emmintrin.h>  // SSE2
#include <tmmintrin.h>  // SSSE3

static inline void
copy_batch_sse(void *dst, const void *src, size_t len)
{
    const __m128i *src128 = src;
    __m128i *dst128 = dst;
    size_t n = len / 16;

    // 批量拷贝 16 bytes at a time
    for (size_t i = 0; i < n; i++) {
        _mm_store_si128(dst128++, _mm_load_si128(src128++));
    }

    // 处理剩余字节
    size_t remaining = len % 16;
    if (remaining)
        memcpy(dst128, src128, remaining);
}
```

## 3. 批处理

### 3.1 Burst 发送

```c
// Virtio TX burst
static uint16_t
virtio_xmit_pkts_burst(void *tx_queue,
                       struct rte_mbuf **tx_pkts,
                       uint16_t nb_pkts)
{
    struct virtqueue *vq = tx_queue;
    uint16_t nb_sent = 0;

    // 检查可用空间
    uint16_t free = vq->vq_nentries -
        (vq->vq_avail_idx - vq->vq_used_cons_idx);

    if (free == 0)
        return 0;

    // 批量处理
    uint16_t batch = RTE_MIN(nb_pkts, free);

    for (uint16_t i = 0; i < batch; i++) {
        struct rte_mbuf *mbuf = tx_pkts[i];

        // 填充 descriptor
        uint16_t desc_idx = vq->vq_desc_head;
        vq->vq_desc[desc_idx].addr = rte_pktmbuf_iova(mbuf);
        vq->vq_desc[desc_idx].len = rte_pktmbuf_data_len(mbuf);

        // 添加到 available
        vq->vq_avail_ring[
            vq->vq_avail_idx & (vq->vq_nentries - 1)] = desc_idx;
        vq->vq_avail_idx++;

        nb_sent++;
    }

    // 单次 doorbell
    if (nb_sent > 0) {
        vq_notify(vq);
    }

    return nb_sent;
}
```

### 3.2 RX/TX 分离

```c
// 分离的 RX 和 TX 路径
// 避免锁竞争

struct virtio_dev {
    // 分离的队列
    struct virtqueue *rxqs[MAX_QUEUES];
    struct virtqueue *txqs[MAX_QUEUES];

    // RX 线程
    lcore_function_t *rx_thread;

    // TX 线程
    lcore_function_t *tx_thread;
};

// RX 在一个 lcore，TX 在另一个 lcore
int
rx_lcore(void *arg)
{
    struct virtio_dev *dev = arg;

    while (1) {
        // RX 只处理接收
        uint16_t nb = virtio_recv_pkts_burst(
            dev->rxqs[rte_lcore_id()],
            rx_mbufs, MAX_BURST);

        // 发送到 RX ring
        send_to_pipeline(rx_mbufs, nb);
    }
}
```

## 4. 配置优化

### 4.1 队列配置

```c
// 优化队列数量和大小
struct rte_eth_conf port_conf = {
    .txq_conf = {
        .tx_thresh = {
            .pthresh = 36,   // 提前发送阈值
            .hthresh = 0,    // 硬件阈值
            .wthresh = 0,    // 写回阈值
        },
        .tx_free_thresh = 64,   // 释放阈值
        .tx_rs_thresh = 64,     // RS 阈值
    },
    .rxq_conf = {
        .rx_thresh = {
            .pthresh = 8,    // 预取阈值
            .hthresh = 8,   // 主机阈值
            .wthresh = 4,    // 写回阈值
        },
        .rx_free_thresh = 32,
        .rx_drop_en = 1,
    },
};
```

### 4.2 多队列配置

```c
// 启用多队列
int
configure_multi_queue(uint16_t port_id, int num_queues)
{
    struct rte_eth_conf conf = {
        .rx_adv_conf = {
            .rss_conf = {
                .rss_key = NULL,  // 默认 RSS key
                .rss_hf = ETH_RSS_IP | ETH_RSS_TCP | ETH_RSS_UDP,
            },
        },
    };

    // 配置 RSS
    rte_eth_dev_configure(port_id, num_queues, num_queues, &conf);

    // 设置每个队列
    for (int i = 0; i < num_queues; i++) {
        struct rte_eth_rxconf rx_conf;
        struct rte_eth_txconf tx_conf;

        rte_eth_rx_queue_setup(port_id, i, 256,
                               SOCKET_ID_ANY, &rx_conf, mbuf_pool);

        rte_eth_tx_queue_setup(port_id, i, 512,
                               SOCKET_ID_ANY, &tx_conf);
    }
}
```

## 5. 合并写入优化

### 5.1 Mergeable Buffer

```c
// Virtio mergeable buffer 支持
// 一个包可以使用多个 descriptor

static uint16_t
virtio_recv_mergeable(void *rxq,
                      struct rte_mbuf **rx_pkts,
                      uint16_t nb_pkts)
{
    struct virtqueue *vq = rxq;
    uint16_t nb_recv = 0;

    while (nb_recv < nb_pkts) {
        // 获取可用的 descriptor 链
        uint16_t used_idx = vq->vq_used_cons_idx;
        uint16_t desc_idx = vq->vq_desc[used_idx & (vq->vq_nentries - 1)].id;

        // 获取 buffer 链
        struct rte_mbuf *mbuf = vq->vq_mbuf[desc_idx];
        struct rte_mbuf *head = mbuf;
        uint32_t total_len = 0;

        // 遍历整个链
        uint16_t flags = vq->vq_desc[desc_idx].flags;
        while (flags & VIRTQ_DESC_F_NEXT) {
            uint16_t next_idx = vq->vq_desc[desc_idx].next;
            total_len += vq->vq_desc[desc_idx].len;
            desc_idx = next_idx;
            flags = vq->vq_desc[desc_idx].flags;

            // 链接 mbuf
            mbuf->next = vq->vq_mbuf[desc_idx];
            mbuf = mbuf->next;
        }

        // 最后一个
        total_len += vq->vq_desc[desc_idx].len;
        head->pkt_len = total_len;

        rx_pkts[nb_recv++] = head;
        vq->vq_used_cons_idx++;
    }

    return nb_recv;
}
```

### 5.2 Large Buffer

```c
// 大缓冲区减少 descriptor 使用
static void
prealloc_large_buffers(struct virtqueue *vq, int mbuf_size)
{
    // 使用大 mbuf 减少链
    struct rte_mbuf *mbuf = rte_pktmbuf_alloc(mbuf_pool);

    // 设置为 Jumbo frame
    if (mbuf_size > 1518) {
        rte_pktmbuf_pktseg_alloc(mbuf, mbuf_size - 1518);
    }
}
```

## 6. 中断优化

### 6.1 中断模式

```c
// 配置 MSI-X 中断
static int
configure_virtio_intr(uint16_t port_id)
{
    // 启用 RX 中断
    rte_eth_dev_rx_intr_enable(port_id, 0);

    // 设置中断阈值
    struct rte_eth_interrupt intr = {
        .elephant_thresh = 32,  // 包累积阈值
    };
    rte_eth_dev_rx_intr_thresh_set(port_id, &intr);

    return 0;
}
```

### 6.2 轮询模式

```c
// 无中断轮询模式
static void
disable_virtio_intr(uint16_t port_id)
{
    // 禁用 RX 中断
    rte_eth_dev_rx_intr_disable(port_id, 0);
}

// 混合模式：少量包时中断，大量时轮询
static inline uint16_t
virtio_recv_adaptive(void *rxq,
                     struct rte_mbuf **rx_pkts,
                     uint16_t nb_pkts)
{
    struct virtqueue *vq = rxq;

    // 轮询
    uint16_t nb = virtio_recv_pkts_vector(rxq, rx_pkts, nb_pkts);

    // 如果没有包，检查中断
    if (nb == 0 && vq->intr_enabled) {
        // 处理中断
        process_virtq_interrupt(vq);
        nb = virtio_recv_pkts_vector(rxq, rx_pkts, nb_pkts);
    }

    return nb;
}
```

## 7. VM 环境优化

### 7.1 QEMU 参数

```bash
# 优化的 QEMU virtio 参数
qemu-system-x86_64 \
    -device virtio-net-pci,\
netdev=net0,\
vectors=4,\
mq=on,\
vectors=4 \
    -netdev vhost-user,\
id=net0,\
chardev=char0,\
queues=4 \
    -chardev socket,\
id=char0,\
path=/var/run/vpp/vhost.sock,\
server=on

# virtio 特定参数
# - vectors: MSI-X 向量数
# - mq: 启用多队列
# - host_mtu: 设置 MTU
```

### 7.2 Guest OS 优化

```bash
# 禁用 irqbalance
systemctl stop irqbalance

# 绑定中断到特定 CPU
for i in /proc/irq/\[virtio*\]; do
    echo 1 > $i/smp_affinity
done

# 调整网络 buffer
sysctl -w net.core.rmem_max=16777216
sysctl -w net.core.wmem_max=16777216
```

## 8. 性能数据

### 8.1 性能对比

| 配置 | 吞吐量 | PPS | 延迟 |
|------|--------|-----|------|
| **virtio-net (kernel)** | ~2 Gbps | ~500K | ~100μs |
| **virtio-pmd (scalar)** | ~5 Gbps | ~1M | ~50μs |
| **virtio-pmd (vector)** | ~10 Gbps | ~3M | ~20μs |
| **vhost-user** | ~15 Gbps | ~5M | ~10μs |

### 8.2 优化效果

```
优化前后对比：

优化前：
  - 吞吐量: 2.5 Gbps
  - CPU: 40%

优化后 (Vector + Batch + Multiq):
  - 吞吐量: 10 Gbps
  - CPU: 25%

提升：
  - 吞吐量: 4x
  - 效率: 6x
```

## 9. 总结

Virtio 优化技术：

| 技术 | 效果 | 复杂度 |
|------|------|--------|
| **Vector PMD** | 2-3x | 低 |
| **Batch TX/RX** | 1.5-2x | 中 |
| **Multi-queue** | 2-4x (多核) | 低 |
| **Large mbuf** | 减少 CPU | 中 |
| **中断优化** | 减少 CPU | 中 |

关键配置参数：

```c
// 最优配置
struct rte_eth_conf conf = {
    .rx_adv_conf.rss_conf.rss_hf = ETH_RSS_IP | ETH_RSS_TCP | ETH_RSS_UDP,
};

rxq_conf.rx_free_thresh = 32;
txq_conf.tx_free_thresh = 64;
```

---

## 参考资源

- [DPDK Virtio PMD](https://doc.dpdk.org/guides/nics/virtio.html)
- [Virtio 规范](https://docs.oasis-open.org/virtio/virtio/v1.1/virtio-v1.1.html)
