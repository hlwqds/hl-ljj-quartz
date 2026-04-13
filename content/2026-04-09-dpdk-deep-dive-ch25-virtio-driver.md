---
title: "DPDK 深度探索 ch25：Virtio 驱动"
date: 2026-04-10 08:00:00
tags: [dpdk, virtio, vhost, vm, para-virtualization, pmd, scatter-gather]
description: "深入解析 DPDK Virtio PMD：virtio 原理、virtqueue、城镇化、合并写入、vhost-user 协同"
---

# DPDK 深度探索 ch25：Virtio 驱动

> [!abstract] 核心要点
> Virtio 是面向虚拟机的半虚拟化设备框架。DPDK virtio PMD 提供高性能 virtio 设备驱动，本章深入解析 virtqueue 机制、城镇化流程、多队列支持。

## 1. Virtio 概述

### 1.1 为什么需要 Virtio

```
全虚拟化 vs 半虚拟化：

全虚拟化 (QEMU 默认):
  Guest OS → 模拟硬件设备 → Hypervisor → 真实硬件
                ↑
            复杂模拟，效率低

半虚拟化 (Virtio):
  Guest OS → Virtio 驱动 → Virtqueue → Hypervisor → 真实硬件
                ↑                    ↑
            简化为 ring buffer      高效

性能对比 (近似值):
  - e1000 (模拟): ~0.5 Gbps
  - virtio-net:   ~10 Gbps
  - vhost-user:   ~15-20 Gbps
```

### 1.2 Virtio vs 其他 VM 网络方案

| 方案 | 架构 | 性能 | 复杂度 |
|------|------|------|--------|
| **e1000** | 软件模拟 | 低 | 低 |
| **virtio-net** | 半虚拟化 | 中 | 中 |
| **vhost-net** | kernel 加速 | 高 | 中 |
| **vhost-user** | 用户态加速 | 最高 | 高 |

## 2. Virtqueue 架构

### 2.1 Virtqueue 结构

```
┌─────────────────────────────────────────────────────────────┐
│                    Virtqueue                               │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │                  Descriptor Table                      │  │
│  │  ┌────────┬────────┬────────┬────────┐              │  │
│  │  │ Desc 0 │ Desc 1 │ Desc 2 │ Desc 3 │ ...        │  │
│  │  └────────┴────────┴────────┴────────┘              │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                              │
│  ┌───────────────────┐    ┌───────────────────┐              │
│  │  Available Ring  │    │     Used Ring     │              │
│  │  (Guest → Host) │    │   (Host → Guest) │              │
│  │                   │    │                   │              │
│  │ flags            │    │ flags              │              │
│  │ idx              │    │ idx                │              │
│  │ ring[0..15]     │    │ ring[0..15]       │              │
│  │ used_event       │    │ avail_event       │              │
│  └───────────────────┘    └───────────────────┘              │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 Descriptor

```c
// Virtio descriptor (16 bytes)
struct virtq_desc {
    uint64_t addr;      // 缓冲区地址 (GPA)
    uint32_t len;       // 缓冲区长度
    uint16_t flags;     // NEXT, WRITE, INDIRECT
    uint16_t next;      // 下一个 descriptor (如果 NEXT)
};

// Flags
#define VIRTQ_DESC_F_NEXT       1  // 链表中下一个
#define VIRTQ_DESC_F_WRITE       2  // 只写 (Host → Guest)
#define VIRTQ_DESC_F_INDIRECT    4  // 间接描述符
```

### 2.3 Available 和 Used Ring

```c
// Available Ring (Guest 写入，Host 读取)
struct virtq_avail {
    uint16_t flags;
    uint16_t idx;       // Guest 写入下一个位置
    uint16_t ring[QUEUE_SIZE];  // descriptor 索引
    uint16_t used_event;  // Guest 通知阈值
};

// Used Ring (Host 写入，Guest 读取)
struct virtq_used {
    uint16_t flags;
    uint16_t idx;       // Host 写入下一个位置
    struct virtq_used_elem {
        uint32_t id;    // descriptor index
        uint32_t len;   // 写入的字节数
    } ring[QUEUE_SIZE];
    uint16_t avail_event;  // Host 通知阈值
};
```

## 3. DPDK Virtio PMD

### 3.1 Virtio PMD 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    DPDK Virtio PMD                          │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │                Application                             │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              rte_eth_rx_burst() / tx_burst()          │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              virtio_dev_rx_queue()                    │  │
│  │              virtio_dev_tx_queue()                    │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              Virtqueue 操作                           │  │
│  │  - 读写 descriptor                                   │  │
│  │  - 更新 available/used ring                         │  │
│  │  - 内存映射                                          │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 初始化

```c
// virtio_init_device()
static int
virtio_init_device(struct virtio_hw *hw, uint16_t nb_queues)
{
    // 1. 获取设备特性
    uint64_t features = VIRTIO_PMD_features;
    virtio_set_features(hw, features);

    // 2. 获取 Virtqueue 数量
    uint16_t q_num = vtpci_get_queue_size(hw, VIRTIO_PCI_QUEUE);

    // 3. 分配 Virtqueue
    hw->vq = malloc(sizeof(struct virtqueue) * nb_queues);
    for (int i = 0; i < nb_queues; i++) {
        hw->vq[i] = virtio_alloc_queue(hw, i, q_num);
    }

    // 4. 通知 Host
    VIRTIO_PCI_queue_sel = queue_index;
    VIRTIO_PCI_queue_pfn = phys_addr >> VIRTIO_PCI_QUEUE_ADDR_SHIFT;
}
```

## 4. 接收流程 (城镇化)

### 4.1 RX 城镇化

```
┌─────────────────────────────────────────────────────────────┐
│                    Virtio RX 城镇化                         │
│                                                              │
│  1. Host 填充 descriptor (缓冲区)                           │
│     ↓                                                        │
│  2. 更新 Used Ring                                          │
│     ↓                                                        │
│  3. 发送 Virtqueue 中断 (optional)                          │
│     ↓                                                        │
│  4. Guest 读取 Available Ring                               │
│     ↓                                                        │
│  5. 处理数据包                                              │
│     ↓                                                        │
│  6. 释放 descriptor，追加到 Used Ring                       │
│     ↓                                                        │
│  7. 发送 Kick 中断通知 Host                                  │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 RX Burst 实现

```c
// virtio_recv_pkts()
static uint16_t
virtio_recv_pkts(void *rx_queue,
                 struct rte_mbuf **rx_pkts,
                 uint16_t nb_pkts)
{
    struct virtqueue *vq = rx_queue;
    uint16_t nb_recv = 0;

    // 1. 获取可用 descriptor
    uint16_t last = vq->vq_used_cons_idx;
    uint16_t avail = *(volatile uint16_t *)vq->vq_avail_idx;

    while (vq->vq_used_cons_idx != avail &&
           nb_recv < nb_pkts) {
        // 2. 获取 used element
        uint32_t idx = vq->vq_used_cons_idx & (vq->vq_nentries - 1);
        uint32_t desc_idx = vq->vq_used_phys[idx].id;
        uint32_t len = vq->vq_used_phys[idx].len;

        // 3. 获取 mbuf
        struct rte_mbuf *mbuf = vq->vq_mbuf[desc_idx];

        // 4. 填充数据
        void *data = (void *)(uintptr_t)vq->vq_descx[desc_idx].addr;
        rte_pktmbuf_data_len(mbuf) = len;
        rte_memcpy(rte_pktmbuf_mtod(mbuf, void *),
                   data, len);

        rx_pkts[nb_recv++] = mbuf;

        vq->vq_used_cons_idx++;
    }

    // 5. 更新 used event
    vq->vq_used_event_idx = vq->vq_used_cons_idx - 1;

    return nb_recv;
}
```

## 5. 发送流程

### 5.1 TX 发送

```
┌─────────────────────────────────────────────────────────────┐
│                    Virtio TX 发送                          │
│                                                              │
│  1. Guest 准备 mbuf 数据                                    │
│     ↓                                                        │
│  2. 查找空闲 descriptor(s)                                 │
│     ↓                                                        │
│  3. 填充 descriptor (addr, len, flags)                     │
│     ↓                                                        │
│  4. 追加 descriptor索引到 Available Ring                    │
│     ↓                                                        │
│  5. 更新 idx                                                │
│     ↓                                                        │
│  6. 发送 Kick (写 VIRTIO_PCI_QUEUE_NOTIFY)                 │
│     ↓                                                        │
│  7. Host 处理后，更新 Used Ring                            │
└─────────────────────────────────────────────────────────────┘
```

### 5.2 TX Burst 实现

```c
// virtio_xmit_pkts()
static uint16_t
virtio_xmit_pkts(void *tx_queue,
                 struct rte_mbuf **tx_pkts,
                 uint16_t nb_pkts)
{
    struct virtqueue *vq = tx_queue;
    uint16_t nb_sent = 0;

    // 1. 检查可用空间
    uint16_t free_entries = vq->vq_nentries -
        (vq->vq_avail_idx - vq->vq_used_cons_idx);

    if (free_entries == 0)
        return 0;

    while (nb_sent < nb_pkts && free_entries > 0) {
        struct rte_mbuf *mbuf = tx_pkts[nb_sent];

        // 2. 分配 descriptor
        uint16_t desc_idx = virtqueue_endchain(vq);

        // 3. 填充 descriptor
        void *data = rte_pktmbuf_mtod(mbuf, void *);
        uint32_t data_len = rte_pktmbuf_data_len(mbuf);

        vq->vq_descx[desc_idx].addr = (uintptr_t)data;
        vq->vq_descx[desc_idx].len = data_len;
        vq->vq_descx[desc_idx].flags = VIRTQ_DESC_F_NEXT;

        // 4. 更新 available ring
        vq->vq_avail_ring[
            vq->vq_avail_idx & (vq->vq_nentries - 1)] = desc_idx;
        vq->vq_avail_idx++;

        nb_sent++;
        free_entries--;
    }

    // 5. 发送 kick
    if (nb_sent > 0) {
        virtqueue_notify(vq);
    }

    return nb_sent;
}
```

## 6. 多队列支持

### 6.1 多队列配置

```c
// 配置多队列
int
virtio_dev_multiq_config(uint16_t port_id, uint16_t nb_queues)
{
    struct rte_eth_dev *dev = &rte_eth_devices[port_id];
    struct virtio_hw *hw = dev->data->dev_private;

    // 分配多个 TX/RX queue pair
    for (int i = 0; i < nb_queues; i++) {
        // RX queue
        snprintf(dev->data->rx_queues[i],
                sizeof(struct virtqueue *));
        hw->vq[i].rx = virtio_alloc_queue(hw, i * 2, q_size);

        // TX queue
        hw->vq[i].tx = virtio_alloc_queue(hw, i * 2 + 1, q_size);
    }

    // 通知 Guest
    VIRTIO_PCI_MQ_config = nb_queues;
}
```

### 6.2 队列选择

```c
// RSS 多队列
static inline uint16_t
virtio_recv_pkts_mq(void *rx_queue,
                    struct rte_mbuf **rx_pkts,
                    uint16_t nb_pkts)
{
    // 基于 RSS hash 选择队列
    struct virtqueue *vq = rx_queue;
    uint16_t q_idx = vq->queue_idx;

    // 处理多队列
    return virtio_recv_pkts(rx_queue, rx_pkts, nb_pkts);
}
```

## 7. 合并写入 (Mergeable)

### 7.1 Scatter-Gather 列表

```c
// Virtio 支持多 descriptor 链
// 用于大包/非连续内存

// Example: 1500B 包分成多个 segment
// Desc 0: | header | (offset 0, len 64)  |
// Desc 1: | data1  | (offset 64, len 512) |
// Desc 2: | data2  | (offset 576, len 924)|

struct {
    struct virtq_desc desc[3];
    // desc[0].flags = NEXT, addr=header, len=64
    // desc[1].flags = NEXT | WRITE, addr=data1, len=512
    // desc[2].flags = WRITE, addr=data2, len=924
};
```

### 7.2 合并写入处理

```c
// 处理合并写入的包
static struct rte_mbuf *
virtio_merge_mbuf(struct virtqueue *vq, uint32_t desc_idx)
{
    struct rte_mbuf *mbuf = rte_pktmbuf_alloc(mbuf_pool);
    struct rte_mbuf *head = mbuf;

    uint32_t idx = desc_idx;
    uint16_t flags = vq->vq_descx[idx].flags;

    while (flags & VIRTQ_DESC_F_NEXT) {
        // 拷贝数据
        void *data = (void *)(uintptr_t)vq->vq_descx[idx].addr;
        uint32_t len = vq->vq_descx[idx].len;

        rte_memcpy(rte_pktmbuf_append(mbuf, len), data, len);

        idx = vq->vq_descx[idx].next;
        flags = vq->vq_descx[idx].flags;
    }

    // 最后一个
    void *data = (void *)(uintptr_t)vq->vq_descx[idx].addr;
    uint32_t len = vq->vq_descx[idx].len;
    rte_memcpy(rte_pktmbuf_append(mbuf, len), data, len);

    return head;
}
```

## 8. 性能优化

### 8.1 预分配 Buffer

```c
// Virtio mbuf 预分配
static int
virtio_recv_prep(struct virtqueue *vq)
{
    // 预分配 mbuf 填满 RX queue
    for (int i = 0; i < vq->vq_nentries; i++) {
        struct rte_mbuf *mbuf = rte_pktmbuf_alloc(mbuf_pool);

        // 设置 DMA 地址
        vq->vq_descx[i].addr = rte_pktmbuf_iova(mbuf);
        vq->vq_descx[i].len = mbuf->buf_len;
        vq->vq_descx[i].flags = VIRTQ_DESC_F_WRITE;

        // 保存 mbuf 引用
        vq->vq_mbuf[i] = mbuf;
    }

    // 更新 available ring
    for (int i = 0; i < vq->vq_nentries; i++) {
        vq->vq_avail_ring[i] = i;
    }
    vq->vq_avail_idx = vq->vq_nentries;
}
```

### 8.2 中断优化

```c
// MSI-X vs IRQ
// MSI-X 性能更好，配置更复杂

// 禁用中断，轮询模式
static void
virtio_dev_rxq_intr_enable(struct rte_eth_dev *dev,
                            uint16_t qid)
{
    // 启用中断
    vtpci_set_queue_notify(hw, qid, 1);
}

// 禁用中断，轮询模式
static void
virtio_dev_rxq_intr_disable(struct rte_eth_dev *dev,
                             uint16_t qid)
{
    // 禁用中断，使用轮询
    vtpci_set_queue_notify(hw, qid, 0);
}
```

## 9. 总结

Virtio 架构：

```
┌─────────────────────────────────────────────────────────────┐
│                    Virtio 数据路径                          │
│                                                              │
│  Guest OS                                                   │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ virtio-net driver                                    │  │
│  │                                                       │  │
│  │  TX: mbuf → Descriptor → Available Ring → Kick     │  │
│  │  RX: Available Ring → Descriptor → mbuf ← Used Ring│  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│  Virtqueue (shared memory)                                 │
│                            ↓                                │
│  Host (QEMU / VPP / vhost-user)                           │
└─────────────────────────────────────────────────────────────┘
```

关键特性：

| 特性 | 说明 |
|------|------|
| **Virtqueue** | Descriptor + Available + Used 三环 |
| **城镇化** | 无需模拟 mmio，并发性能高 |
| **多队列** | RSS 分散负载 |
| **Scatter-Gather** | 支持大包 |
| **Vhost-user** | 用户态加速 |

---

## 参考资源

- [Virtio 规范](https://docs.oasis-open.org/virtio/virtio/v1.1/virtio-v1.1.html)
- [DPDK virtio PMD](https://doc.dpdk.org/guides/nics/virtio.html)
