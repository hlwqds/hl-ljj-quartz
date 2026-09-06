---
title: "DPDK 深度探索 (九)：KNI (Kernel NIC Interface) 用户态与内核通信"
date: 2026-04-09
tags: [dpdk, series, kni, kernel, netdev, ioctl, mbuf, virtio, rx-tx]
description: "深入理解 DPDK KNI 的实现——KNI 与 Linux 内核网络栈的集成、mbuf 与 sk_buff 转换、ioctl 控制通道、收发包路径、以及典型应用场景"
---

> [!warning] 历史草稿提示
> 这篇是早期 KNI 草稿，保留作历史参考。KNI 已在 DPDK 23.11 移除，系列索引中的正式章节请看
> [[ch15-kni-interface|第十五章：KNI 历史机制]]；
> 新项目优先看 [[ch15b-af-xdp|第十五章补充：AF_XDP —— KNI 的现代替代]]。

> [!info] DPDK 深度探索系列 0. [[dpdk-deep-dive|全栈学习路径总览]]
>
> 1. [[ch1-architecture-overview|第一章：架构概述——kernel bypass 原理与 DPDK 定位]]
> 2. [[ch2-uio-vfio-iommu|第二章：UIO/VFIO/IOMMU 用户态驱动框架]]
> 3. [[ch3-eal-initialization|第三章：EAL 初始化与 lcore 模型]]
> 4. [[ch4-hugepage-mempool|第四章：大页内存与 mempool 机制]]
> 5. [[ch5-mbuf-mechanism|第五章：Mbuf 结构、Dynfield]]
> 6. [[ch6-ring-queue|第六章：Ring 无锁队列实现与性能分析]]
> 7. [[ch7-pmd-driver|第七章：PMD (Poll Mode Driver) 驱动架构]]
> 8. [[ch8-timer-wheel|第八章：rte_timer 软件定时器]]
> 9. **第九章：KNI (Kernel NIC Interface) 用户态与内核通信**

---

## 1. 概述：为什么需要 KNI？

DPDK 通过 bypass 内核实现高性能，但这也带来了问题：

| 场景           | 问题                  | 解决             |
| -------------- | --------------------- | ---------------- |
| **管理流量**   | SSH/Console 无法到达  | KNI 提供控制面   |
| **内核协议栈** | 需要复用 Linux TCP/IP | KNI 桥接         |
| **硬件卸载**   | 有些处理必须在内核    | KNI 回传内核     |
| **调试**       | 无法用标准工具抓包    | KNI 支持 tcpdump |

### 1.1 KNI 在 DPDK 架构中的位置

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           KNI 架构全景                                        │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│    ┌────────────────────────────────────────────────────────────────────┐   │
│    │                         User Space                                 │   │
│    │                                                                    │   │
│    │  ┌──────────────────┐         ┌──────────────────┐                │   │
│    │  │   DPDK App       │         │   DPDK App       │                │   │
│    │  │   (数据面)        │         │   (控制面)        │                │   │
│    │  └────────┬─────────┘         └────────┬─────────┘                │   │
│    │           │                             │                          │   │
│    │           │ rte_kni_*                   │ ioctl                    │   │
│    │           ▼                             ▼                          │   │
│    │  ┌────────────────────────────────────────────────────────────┐   │   │
│    │  │                     librte_kni                             │   │   │
│    │  │  ┌────────┐  ┌────────┐  ┌────────┐  ┌────────┐           │   │   │
│    │  │  │alloc   │  │free    │  │tx_burst│  │rx_burst│           │   │   │
│    │  │  │kni     │  │kni     │  │        │  │        │           │   │   │
│    │  │  └────────┘  └────────┘  └────────┘  └────────┘           │   │   │
│    │  └────────────────────────────────────────────────────────────┘   │   │
│    │                              │                                     │   │
│    └──────────────────────────────┼────────────────────────────────────┘   │
│                                   │ /dev/kni                              │
│    ┌──────────────────────────────┼────────────────────────────────────┐   │
│    │                         Kernel Space                               │   │
│    │                                                                    │   │
│    │  ┌────────────────────────────────────────────────────────────┐   │   │
│    │  │                    kni.ko                                   │   │   │
│    │  │  ┌────────┐  ┌────────┐  ┌────────┐  ┌────────┐           │   │   │
│    │  │  │字符设备│  │netdev  │  │ethnavi │  │mbuf/   │           │   │   │
│    │  │  │/dev/kni│  │生成    │  │GSO/TSO │  │skb转换 │           │   │   │
│    │  │  └────────┘  └────────┘  └────────┘  └────────┘           │   │   │
│    │  └────────────────────────────────────────────────────────────┘   │   │
│    │                              │                                     │   │
│    │                              ▼                                     │   │
│    │  ┌────────────────────────────────────────────────────────────┐   │   │
│    │  │              Linux Kernel Network Stack                    │   │   │
│    │  │                                                            │   │   │
│    │  │  eth0 ←────────┐     ┌──────────► bond0 / bridge          │   │   │
│    │  │                │     │                                      │   │   │
│    │  │                └──►──┘                                      │   │   │
│    │  │                  kni0 (虚拟网卡)                            │   │   │
│    │  │                                                            │   │   │
│    │  └────────────────────────────────────────────────────────────┘   │   │
│    │                              │                                     │   │
│    └──────────────────────────────┼────────────────────────────────────┘   │
│                                   │                                        │
└───────────────────────────────────┼────────────────────────────────────────┘
                                    │
                                    ▼
                            Physical NIC (ixgbe/i40e)
```

---

## 2. KNI 核心数据结构

### 2.1 KNI 设备结构

```c
// lib/kni/rte_kni.h

struct rte_kni {
    char name[RTE_KNI_NAMESIZE];       // 设备名称 "kni0"

    struct rte_eth_dev *eth_dev;        // 关联的 ethdev (预留)

    // mbuf 内存池（用于 KNI 与内核的数据传输）
    struct rte_mempool *mbuf_pool;

    // FIFO 队列（用户态与内核共享）
    struct rte_kni_fifo *tx_q;          // 用户态发送队列（发给内核）
    struct rte_kni_fifo *rx_q;          // 用户态接收队列（从内核接收）
    struct rte_kni_fifo *alloc_q;       // 分配请求队列
    struct rte_kni_fifo *free_q;        // 释放请求队列

    // 上下文
    unsigned lcore_id;                   // 处理此 KNI 的 lcore
    uint16_t port_id;                   // 关联的物理端口

    // 配置
    struct rte_kni_conf conf;
};
```

### 2.2 KNI FIFO

```c
// lib/kni/rte_kni_fifo.h

// KNI 使用 ring 实现的无锁 FIFO
struct rte_kni_fifo {
    volatile uint32_t write_idx;        // 写索引
    volatile uint32_t read_idx;         // 读索引
    uint32_t size;                       // FIFO 大小（2^n）
    uint32_t mask;                       // size - 1

    void *buffer[];                     // 存储指针的数组
};

// 与 rte_ring 的区别：
// 1. 简化版本，只支持单生产者单消费者
// 2. 用于用户态和内核之间的高速数据传递
```

### 2.3 KNI ioctl 请求

```c
// lib/kni/rte_kni.h

// KNI 支持的 ioctl 命令
#define RTE_KNI_IOCTL_CREATE     _IOWR(0x10, 1, struct rte_kni_conf)
#define RTE_KNI_IOCTL_RELEASE    _IOWR(0x10, 2, unsigned int)
#define RTE_KNI_IOCTL_GET_INFO   _IOWR(0x10, 3, struct rte_kni_conf)
#define RTE_KNI_IOCTL_CONFIG     _IOWR(0x10, 4, struct rte_kni_conf)
#define RTE_KNI_IOCTL_CHANGE_MTU _IOWR(0x10, 5, unsigned int)
#define RTE_KNI_IOCTL_SET_MAC    _IOWR(0x10, 6, struct rte_ether_addr)

// 配置结构
struct rte_kni_conf {
    char name[RTE_KNI_NAMESIZE];       // KNI 设备名
    uint16_t port_id;                   // 关联的物理端口
    uint32_t tx_q_size;                 // TX 队列大小
    uint32_t rx_q_size;                 // RX 队列大小
    uint32_t alloc_q_size;              // 分配队列大小
    uint32_t free_q_size;               // 释放队列大小
    uint32_t mbuf_size;                 // mbuf 数据区大小
    struct rte_ether_addr mac_addr;     // MAC 地址
    uint16_t mtu;                       // MTU
};
```

---

## 3. KNI 创建流程

### 3.1 用户态 API

```c
// lib/kni/rte_kni.c

struct rte_kni *
rte_kni_alloc(struct rte_mempool *mbuf_pool,
               const struct rte_kni_conf *conf,
               struct rte_kni_ops *ops)
{
    struct rte_kni *kni;
    int ret;

    // 1. 参数检查
    if (conf == NULL || mbuf_pool == NULL)
        return NULL;

    // 2. 分配 KNI 设备
    kni = rte_zmalloc("kni",
                       sizeof(struct rte_kni),
                       RTE_CACHE_LINE_SIZE);
    if (kni == NULL)
        return NULL;

    // 3. 复制配置
    memcpy(&kni->conf, conf, sizeof(*conf));
    kni->mbuf_pool = mbuf_pool;

    // 4. 分配 FIFO 队列
    kni->tx_q = rte_malloc(NULL,
                             sizeof(struct rte_kni_fifo) +
                             conf->tx_q_size * sizeof(void *),
                             RTE_CACHE_LINE_SIZE);
    // ... 类似分配其他队列

    // 5. 初始化 FIFO
    kni_fifo_init(kni->tx_q, conf->tx_q_size);
    kni_fifo_init(kni->rx_q, conf->rx_q_size);
    kni_fifo_init(kni->alloc_q, conf->alloc_q_size);
    kni_fifo_init(kni->free_q, conf->free_q_size);

    // 6. 打开 /dev/kni 设备
    kni->kni_fd = open("/dev/kni", O_RDWR);
    if (kni->kni_fd < 0) {
        ret = -errno;
        goto fail;
    }

    // 7. 发送 ioctl 创建内核 netdev
    ret = ioctl(kni->kni_fd, RTE_KNI_IOCTL_CREATE, conf);
    if (ret < 0) {
        goto fail;
    }

    return kni;

fail:
    rte_kni_free(kni);
    return NULL;
}
```

### 3.2 内核态处理

```c
// kernel/linux-kni/kni_net.c

static long
kni_ioctl(struct file *file, unsigned int cmd, unsigned long arg)
{
    switch (cmd) {
    case RTE_KNI_IOCTL_CREATE:
        return kni_ioctl_create(arg);
    case RTE_KNI_IOCTL_RELEASE:
        return kni_ioctl_release(arg);
    case RTE_KNI_IOCTL_GET_INFO:
        return kni_ioctl_get_info(arg);
    case RTE_KNI_IOCTL_CHANGE_MTU:
        return kni_ioctl_change_mtu(arg);
    case RTE_KNI_IOCTL_SET_MAC:
        return kni_ioctl_set_mac(arg);
    default:
        return -EINVAL;
    }
}

static int
kni_ioctl_create(unsigned long arg)
{
    struct kni_dev *kni;
    struct rte_kni_conf conf;

    // 1. 复制用户配置
    if (copy_from_user(&conf, (void __user *)arg, sizeof(conf)))
        return -EFAULT;

    // 2. 分配 kni_dev 结构
    kni = kzalloc(sizeof(struct kni_dev), GFP_KERNEL);
    if (!kni)
        return -ENOMEM;

    // 3. 创建 netdev (虚拟网卡)
    kni->net_dev = alloc_etherdev(sizeof(struct kni_mgmt));
    if (!kni->net_dev) {
        kfree(kni);
        return -ENOMEM;
    }

    // 4. 设置 netdev_ops
    kni->net_dev->netdev_ops = &kni_netdev_ops;
    kni->net_dev->ethtool_ops = &kni_ethtool_ops;

    // 5. 设置 MAC 和 MTU
    memcpy(kni->net_dev->dev_addr, conf.mac_addr.addr, ETH_ALEN);
    kni->net_dev->mtu = conf.mtu;

    // 6. 注册 netdev
    register_netdev(kni->net_dev);

    // 7. 建立用户态与内核态共享内存
    //    使用 mmap 将 FIFO 映射到用户态
    kni->tx_q = kni_alloc_fifo(kni, conf.tx_q_size);
    kni->rx_q = kni_alloc_fifo(kni, conf.rx_q_size);

    return 0;
}
```

### 3.3 创建流程图

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        KNI 设备创建流程                                       │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  用户态 (DPDK App)              内核态 (kni.ko)           Linux             │
│  ────────────────────           ───────────────           ────────          │
│                                                                             │
│  rte_kni_alloc()                                            ┌───────────┐   │
│       │                                                      │ alloc_    │   │
│       │ 1. 分配 rte_kni                                      │ netdev()  │   │
│       │                                                     └─────┬─────┘   │
│       │ 2. 分配 FIFO (tx_q, rx_q)                                  │        │
│       │      (用户态内存)                                          │        │
│       │                                                            ▼        │
│       │ 3. open("/dev/kni")              ioctl(CREATE)      ┌───────────┐   │
│       ├────────────────────────────────────────────────────►│ kni_ioctl │   │
│       │                                                            │        │
│       │                                                            ▼        │
│       │ 4. mmap() 将 FIFO 映射到           mmap()              ┌───────────┐ │
│       ├──────────────────────────────────────────────────────►│ create    │ │
│       │                                                      │ netdev    │ │
│       │                                                      └─────┬─────┘ │
│       │                                                            │       │
│       │                                                            ▼       │
│       │ 5. 等待内核-netdev up                register_netdev()  ┌───────┐ │
│       │◄───────────────────────────────────────────────────────│ eth0   │ │
│       │                                                            │ kni0   │ │
│       │                                                            └───────┘ │
│       │                                                               │     │
│       ▼                                                               ▼     │
│  ┌──────────────┐                                                ┌──────────┐│
│  │ kni->tx_q   │◄─────── 共享内存映射 ──────────────────────────│ tx_q    ││
│  │ kni->rx_q   │─────── 共享内存映射 ──────────────────────────►│ rx_q    ││
│  │ kni->alloc_q│       (mmap)                                   │ alloc_q ││
│  │ kni->free_q │                                                │ free_q  ││
│  └──────────────┘                                                └─────────┘│
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 4. 收发包路径

### 4.1 用户态发包 (Tx to Kernel)

```c
// 用户态发送数据包到内核

uint16_t
rte_kni_tx_burst(struct rte_kni *kni,
                   struct rte_mbuf **mbufs,
                   uint16_t count)
{
    uint16_t i;
    struct rte_mbuf *m;

    for (i = 0; i < count; i++) {
        m = mbufs[i];

        // 1. 从 alloc_q 获取一个 mbuf（替换用）
        //    因为我们要发送 mbuf，需要补充一个到 alloc_q
        struct rte_mbuf *new_m = kni_fifo_get(kni->alloc_q);
        if (new_m == NULL) {
            // 没有可用 mbuf，跳过
            continue;
        }

        // 2. 将要发送的 mbuf 放入 tx_q
        kni_fifo_put(kni->tx_q, m);

        // 3. 触发内核处理（发送中断）
        //    使用 virtio 或 UIO 中断机制通知内核
        kni_trigger_interrupt(kni);
    }

    return i;
}
```

### 4.2 内核态接收 (netif_rx)

```c
// kernel/linux-kni/kni_net.c

static int
kni_net_rx(struct kni_dev *kni)
{
    struct rte_mbuf *m;
    struct sk_buff *skb;
    uint32_t len;

    // 1. 从 rx_q 读取 mbuf（用户态发送过来的）
    while ((m = kni_fifo_get(kni->rx_q)) != NULL) {
        // 2. mbuf → sk_buff 转换
        skb = mbuf_to_skb(m);
        if (!skb) {
            rte_pktmbuf_free(m);
            continue;
        }

        // 3. 设置网络包信息
        skb->dev = kni->net_dev;
        skb->protocol = eth_type_trans(skb, ski->net_dev);

        // 4. 送入 Linux 网络栈
        netif_rx(skb);

        // 5. 将 mbuf 放入 free_q（归还给用户态）
        kni_fifo_put(kni->free_q, m);
    }

    return 0;
}

// mbuf → sk_buff 转换
static struct sk_buff *
mbuf_to_skb(const struct rte_mbuf *m)
{
    struct sk_buff *skb;
    struct rte_mbuf *seg;

    // 1. 分配 skb
    skb = alloc_skb(m->pkt_len + LL_RESERVED_SPACE(skb->dev), GFP_ATOMIC);
    if (!skb)
        return NULL;

    // 2. 复制数据
    seg = m;
    skb_put(skb, seg->data_len);
    skb_copy_to_linear_data(skb, rte_pktmbuf_mtod(seg, void *), seg->data_len);

    // 3. 处理分片
    while ((seg = seg->next)) {
        skb_put(skb, seg->data_len);
        skb_copy_to_linear_data_offset(skb, skb->len - seg->data_len,
                                        rte_pktmbuf_mtod(seg, void *),
                                        seg->data_len);
    }

    // 4. 设置 meta 信息
    skb->pkt_type = PACKET_HOST;
    skb_reset_mac_header(skb);

    return skb;
}
```

### 4.3 内核态发包 (Tx to User)

```c
// kernel/linux-kni/kni_net.c

static netdev_tx_t
kni_net_xmit(struct sk_buff *skb, struct net_device *dev)
{
    struct kni_dev *kni = netdev_priv(dev);
    struct rte_mbuf *m;

    // 1. 检查 rx_q 是否有空间
    if (kni_fifo_free_count(kni->rx_q) < 1) {
        // 队列满，丢弃
        dev->stats.tx_dropped++;
        dev_kfree_skb(skb);
        return NETDEV_TX_OK;
    }

    // 2. sk_buff → mbuf 转换
    m = skb_to_mbuf(skb);
    if (!m) {
        dev_kfree_skb(skb);
        return NETDEV_TX_OK;
    }

    // 3. 放入 rx_q（用户态将从此队列读取）
    kni_fifo_put(kni->rx_q, m);

    // 4. 更新统计
    dev->stats.tx_packets++;
    dev->stats.tx_bytes += skb->len;

    // 5. 通知用户态（有数据到达）
    //    写入 doorbell 或发送信号
    kni_user_trigger_interrupt(kni);

    return NETDEV_TX_OK;
}

// sk_buff → mbuf 转换
static struct rte_mbuf *
skb_to_mbuf(const struct sk_buff *skb)
{
    struct rte_mbuf *m, *prev;
    struct skb_shared_info *shinfo;
    uint32_t data_len;

    // 1. 从 free_q 获取 mbuf
    m = kni_fifo_get(kni->free_q);
    if (!m)
        return NULL;

    // 2. 复制数据
    data_len = skb->len;
    rte_memcpy(rte_pktmbuf_mtod(m, void *),
                skb->data,
                data_len);

    // 3. 设置 mbuf 元数据
    m->data_len = data_len;
    m->pkt_len = data_len;

    // 4. 处理分片
    shinfo = skb_shinfo(skb);
    if (shinfo->nr_frags) {
        // 有分片，需要构建 mbuf 链
        // ... 处理分片数据
    }

    // 5. 释放 skb
    dev_kfree_skb((struct sk_buff *)skb);

    return m;
}
```

### 4.4 用户态收包 (Rx from Kernel)

```c
// 用户态从内核接收数据包

uint16_t
rte_kni_rx_burst(struct rte_kni *kni,
                   struct rte_mbuf **mbufs,
                   uint16_t count)
{
    uint16_t i;
    struct rte_mbuf *m;

    for (i = 0; i < count; i++) {
        // 1. 从 rx_q 读取 mbuf（内核发送过来的）
        m = kni_fifo_get(kni->rx_q);
        if (m == NULL)
            break;

        mbufs[i] = m;
    }

    // 2. 将用完的 mbuf 归还到 free_q
    //    这样内核可以重用
    for (int j = 0; j < i; j++) {
        kni_fifo_put(kni->free_q, mbufs[j]);
    }

    return i;
}
```

### 4.5 完整数据流

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     KNI 完整收发包流程                                       │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ═══════════════════════════ 用户态 → 内核态 ═══════════════════════════     │
│                                                                             │
│  DPDK App                                          Linux Kernel             │
│  ────────                                          ────────────             │
│                                                    ┌───────────────┐        │
│  ┌──────────┐      ┌──────────┐                  │ kni0          │        │
│  │ mbuf     │ ───► │ tx_q     │ ──── tx ────────►│ netif_rx()   │        │
│  │ (pkt)    │      │ (FIFO)   │                  │               │        │
│  └──────────┘      └──────────┘                  └───────┬───────┘        │
│       │                                          │               │         │
│       │ 1. rte_kni_tx_burst()                    │               ▼         │
│       │    将 mbuf 放入 tx_q                      │         ┌───────────┐  │
│       │    触发内核中断                            │         │ Linux     │  │
│       │                                           │         │ TCP/IP    │  │
│       │                                           │         │ Stack     │  │
│       │                                           │         └───────────┘  │
│       ▼                                           ▼               │         │
│  ┌──────────┐      ┌──────────┐                  ┌───────────────┐        │
│  │ alloc_q  │ ◄─── │ 补充 mbuf│                  │ kni_net_rx() │        │
│  │ (FIFO)   │      │ 归还     │                  │  mbuf→skb     │        │
│  └──────────┘      └──────────┘                  └───────────────┘        │
│                                                                             │
│  ═══════════════════════════ 内核态 → 用户态 ═══════════════════════════     │
│                                                                             │
│  Linux Kernel                                       DPDK App                │
│  ────────────                                       ────────                 │
│                                                    ┌───────────────┐        │
│  ┌───────────────┐                                │ kni0          │        │
│  │ TCP/IP        │                                │ rte_kni_      │        │
│  │ Stack         │ ────► skb ────► kni_net_xmit()│ rx_burst()    │        │
│  └───────────────┘                                └───────┬───────┘        │
│       │                                                   │                 │
│       │                                                   ▼                 │
│       ▼                                           ┌───────────────┐        │
│  ┌───────────────┐      ┌──────────┐              │ rx_q          │        │
│  │ skb → mbuf    │ ───►│ rx_q     │              │ (FIFO)        │        │
│  │ 转换           │      │ (FIFO)   │              └───────┬───────┘        │
│  └───────────────┘      └──────────┘                      │                 │
│                                                           ▼                 │
│                                                    ┌───────────────┐        │
│                                                    │ mbuf 处理     │        │
│                                                    │ (DPDK App)    │        │
│                                                    └───────────────┘        │
│       │                                                    ▲                │
│       │ 归还 mbuf                                          │                │
│       ▼                                                    │                │
│  ┌───────────────┐      ┌──────────┐              ┌───────────────┐        │
│  │ mbuf → skb    │ ◄─── │ free_q   │              │ mbuf 放入     │        │
│  │ 转换           │      │ (FIFO)   │              │ free_q        │        │
│  └───────────────┘      └──────────┘              └───────────────┘        │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 5. 控制通道 (ioctl)

### 5.1 MTU 变更

```c
// 用户态请求修改 MTU
int
rte_kni_set_mtu(uint16_t port_id, uint16_t mtu)
{
    int fd = open("/dev/kni", O_RDWR);
    int ret;

    struct rte_kni_conf conf = {
        .port_id = port_id,
        .mtu = mtu,
    };

    ret = ioctl(fd, RTE_KNI_IOCTL_CHANGE_MTU, &conf);
    close(fd);

    return ret;
}

// 内核态处理
static int
kni_ioctl_change_mtu(unsigned long arg)
{
    struct rte_kni_conf conf;
    struct kni_dev *kni;

    if (copy_from_user(&conf, (void __user *)arg, sizeof(conf)))
        return -EFAULT;

    kni = kni_get(conf.name);
    if (!kni)
        return -EINVAL;

    // 调用内核 API 修改 MTU
    int ret = dev_set_mtu(kni->net_dev, conf.mtu);

    return ret;
}
```

### 5.2 MAC 地址变更

```c
// 用户态请求修改 MAC
int
rte_kni_set_mac(uint16_t port_id, struct rte_ether_addr *mac)
{
    int fd = open("/dev/kni", O_RDWR);
    int ret;

    struct rte_kni_conf conf = {
        .port_id = port_id,
    };
    memcpy(conf.mac_addr.addr, mac, ETH_ALEN);

    ret = ioctl(fd, RTE_KNI_IOCTL_SET_MAC, &conf);
    close(fd);

    return ret;
}

// 内核态处理
static int
kni_ioctl_set_mac(unsigned long arg)
{
    struct rte_kni_conf conf;
    struct kni_dev *kni;

    if (copy_from_user(&conf, (void __user *)arg, sizeof(conf)))
        return -EFAULT;

    kni = kni_get(conf.name);
    if (!kni)
        return -EINVAL;

    // 修改 MAC 地址
    memcpy(kni->net_dev->dev_addr, conf.mac_addr.addr, ETH_ALEN);
    eth_commit_mac_addr_change(kni->net_dev, conf.mac_addr.addr);

    return 0;
}
```

---

## 6. 内存映射 (mmap)

### 6.1 用户态 mmap

```c
// lib/kni/rte_kni.c

static int
kni_mmap(struct rte_kni *kni)
{
    void *addr;

    // 1. mmap tx_q
    addr = mmap(0,
                 kni->tx_q_size * sizeof(void *) +
                 sizeof(struct rte_kni_fifo),
                 PROT_READ | PROT_WRITE,
                 MAP_SHARED,
                 kni->kni_fd,
                 0);
    if (addr == MAP_FAILED)
        return -ENOMEM;
    kni->tx_q = addr;

    // 2. mmap rx_q
    addr = mmap(0,
                 kni->rx_q_size * sizeof(void *) +
                 sizeof(struct rte_kni_fifo),
                 PROT_READ | PROT_WRITE,
                 MAP_SHARED,
                 kni->kni_fd,
                 1);
    // ...

    // 3. mmap alloc_q
    // 4. mmap free_q

    return 0;
}
```

### 6.2 内核态 mmap

```c
// kernel/linux-kni/kni_net.c

static int
kni_mmap(struct file *file, struct vm_area_struct *vma)
{
    unsigned long pfn;
    unsigned long start = vma->vm_start;
    unsigned long size = vma->vm_end - vma->vm_start;

    // 获取物理地址
    unsigned long phys_addr = virt_to_phys(kni->tx_q);

    // 映射到用户态
    pfn = phys_addr >> PAGE_SHIFT;
    if (remap_pfn_range(vma, start, pfn, size, PAGE_SHARED))
        return -EAGAIN;

    return 0;
}
```

---

## 7. 典型应用场景

### 7.1 控制面与管理流量

```c
// 场景：DPDK 处理数据流量，但需要 SSH 管理

// 1. 创建 KNI 设备，关联到物理端口
struct rte_kni_conf conf = {
    .name = "kni0",
    .port_id = 0,
    .tx_q_size = 256,
    .rx_q_size = 256,
    .mtu = 1500,
};
conf.mac_addr = // 从物理端口获取或手动设置

struct rte_kni *kni = rte_kni_alloc(mbuf_pool, &conf, NULL);

// 2. 配置 Linux 侧的 IP
//    在宿主机执行: ip addr add 192.168.1.1/24 dev kni0
//                  ip link set kni0 up

// 3. SSH 流量通过 KNI 进入 Linux 内核栈
//    数据流量通过 DPDK PMD 直接处理
```

### 7.2 DHCP 响应

```c
// 场景：VNF 需要响应 DHCP 请求

// 在 DPDK App 中：
// 1. 监听 DHCP 端口（67/68）
void
dhcp_handler(struct rte_kni *kni)
{
    struct rte_mbuf *mbufs[32];
    uint16_t nb = rte_kni_rx_burst(kni, mbufs, 32);

    for (int i = 0; i < nb; i++) {
        struct rte_ipv4_hdr *ip =
            rte_pktmbuf_mtod_offset(mbufs[i], struct rte_ipv4_hdr *,
                                    sizeof(struct rte_ether_hdr));
        struct rte_udp_hdr *udp =
            rte_pktmbuf_mtod_offset(mbufs[i], struct rte_udp_hdr *,
                                    sizeof(struct rte_ether_hdr) +
                                    sizeof(struct rte_ipv4_hdr));

        if (udp->src_port == rte_cpu_to_be_16(68) &&
            udp->dst_port == rte_cpu_to_be_16(67)) {
            // DHCP 请求，构造响应
            struct rte_mbuf *resp = build_dhcp_response(mbufs[i]);
            rte_kni_tx_burst(kni, &resp, 1);
        } else {
            // 其他流量，转发到 DPDK 处理
            process_packet(mbufs[i]);
        }
    }
}
```

### 7.3 与 Linux Bridge 集成

```c
// 场景：DPDK 端口作为 bridge 成员

// 宿主机配置：
//   ip link add br0 type bridge
//   ip link set enp0s1 master br0    # 物理网卡
//   ip link set kni0 master br0       # KNI 虚拟网卡
//   ip link set br0 up

// 效果：
//   - 从 enp0s1 进入的广播/未知单播 → bridge → kni0
//   - 从 kni0 进入的流量 → bridge → enp0s1 (如果已知MAC)
//   - 其他流量由 DPDK App 通过 PMD 处理

// DPDK App 不感知 bridge：
//   - 物理网卡的流量直接 DMA 到 DPDK mbuf
//   - 需要 Linux 处理的（ARP/Broadcast/DHCP）通过 KNI
```

---

## 8. 性能分析

### 8.1 KNI vs 纯 DPDK

```c
// 性能对比

// 纯 DPDK (KNI bypass)
// ─────────────────────
// 吞吐量：100G 线速 (64B packets)
// 延迟：~100ns
// CPU 占用：极低

// KNI (内核参与)
// ──────────────
// 吞吐量：~5-10 Gbps (受限于内核网络栈)
// 延迟：~10-50us (syscall + 内核处理)
// CPU 占用：较高

// 何时使用 KNI：
// 1. 控制面流量 (SSH, SNMP, 调试)
// 2. 需要内核协议的流量 (DHCP, DNS)
// 3. 无法在用户态实现的协议
```

### 8.2 Batch 处理优化

```c
// KNI 也支持批量操作提升性能

// 原始：逐包处理
for (int i = 0; i < nb; i++) {
    rte_kni_tx_burst(kni, &mbufs[i], 1);  // 多次系统调用
}

// 优化：批量处理
rte_kni_tx_burst(kni, mbufs, nb);  // 一次处理多个包

// 内核侧也会批量处理：
static int
kni_net_rx(struct kni_dev *kni)
{
    struct rte_mbuf *m;
    int nb = 0;
    struct sk_buff *skbs[32];

    // 批量从 rx_q 读取
    while ((m = kni_fifo_get(kni->rx_q)) != NULL && nb < 32) {
        skbs[nb] = mbuf_to_skb(m);
        nb++;
    }

    // 批量提交到网络栈
    for (int i = 0; i < nb; i++) {
        netif_rx(skbs[i]);
    }
}
```

---

## 9. KNI 限制与替代方案

### 9.1 KNI 的局限性

| 限制               | 说明                           |
| ------------------ | ------------------------------ |
| **单核瓶颈**       | 所有 KNI 流量由单个 lcore 处理 |
| **同步开销**       | FIFO + 中断通知机制有延迟      |
| **内存复制**       | mbuf ↔ skb 转换有开销          |
| **不支持 GSO/TSO** | 需要额外处理                   |

### 9.2 替代方案

| 方案             | 描述                          | 适用场景           |
| ---------------- | ----------------------------- | ------------------ |
| **VIRTIO**       | 虚拟化标准接口，virtio-net    | 虚拟机通信         |
| **AF_XDP**       | 直接访问 XDP，绕过内核        | 高性能数据包捕获   |
| **Rdma**         | 远程直接内存访问              | 跨主机高速通信     |
| **用户态协议栈** | DPDK 内置 Failsafe/Terminator | 需要完全用户态控制 |

---

## 10. 小结

本章核心要点：

1. **KNI 定位**：DPDK 与 Linux 内核网络栈的桥梁，用于控制面和管理流量。

2. **架构组成**：用户态 librte_kni + 内核态 kni.ko + 虚拟 netdev。

3. **核心数据结构**：rte_kni（管理设备）、rte_kni_fifo（共享队列）、rte_kni_conf（配置）。

4. **创建流程**：用户态分配 FIFO → ioctl CREATE → 内核创建 netdev → mmap 共享内存。

5. **发包路径**：用户态 rte_kni_tx_burst → tx_q → 内核 netif_rx → Linux 栈。

6. **收包路径**：内核 kni_net_xmit → rx_q → 用户态 rte_kni_rx_burst。

7. **mbuf ↔ skb 转换**：KNI 的主要开销来源。

8. **应用场景**：控制面流量、DHCP/DNS 响应、Linux Bridge 集成。

9. **性能**：比纯 DPDK 慢 10-100x，仅用于控制面。

**下一篇预告**：[[ch10-flow-classification|第十章]]将深入讲解 DPDK 流量分类——Flow Director、ACL 库、RSS 哈希、以及基于 rte_flow 的通用匹配动作框架。

---

> [!tip] 参考文献
>
> - Intel, "DPDK KNI Guide", https://doc.dpdk.org/guides/prog_guide/kernel_nic_interface.html
> - "KNI source code", https://github.com/DPDK/dpdk/tree/main/lib/kni
> - "kni.ko source code", https://github.com/DPDK/dpdk/tree/main/kernel/linux/kni
> - "AF_XDP vs KNI", https://doc.dpdk.org/guides/prog_guide/af_xdp.html
