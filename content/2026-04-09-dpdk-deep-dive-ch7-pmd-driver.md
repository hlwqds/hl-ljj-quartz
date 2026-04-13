---
title: "DPDK 深度探索 (七)：PMD (Poll Mode Driver) 驱动架构"
date: 2026-04-09
tags: [dpdk, series, pmd, driver, ethdev, rx-burst, tx-burst, descriptor]
description: "深入理解 DPDK 网卡驱动的核心——PMD 驱动注册流程、ethdev 抽象层、收发包路径、描述符管理、以及 Intel ixgbe/i40e 驱动的具体实现"
---

> [!info] DPDK 深度探索系列
> 0. [[2026-04-09-dpdk-deep-dive-series-index|全栈学习路径总览]]
> 1. [[2026-04-09-dpdk-deep-dive-ch1-architecture-overview|第一章：架构概述——kernel bypass 原理与 DPDK 定位]]
> 2. [[2026-04-09-dpdk-deep-dive-ch2-uio-vfio-iommu|第二章：UIO/VFIO/IOMMU 用户态驱动框架]]
> 3. [[2026-04-09-dpdk-deep-dive-ch3-eal-initialization|第三章：EAL 初始化与 lcore 模型]]
> 4. [[2026-04-09-dpdk-deep-dive-ch4-hugepage-mempool|第四章：大页内存与 mempool 机制]]
> 5. [[2026-04-09-dpdk-deep-dive-ch5-mbuf-mechanism|第五章：Mbuf 结构与 Dynfield]]
> 6. [[2026-04-09-dpdk-deep-dive-ch6-ring-queue|第六章：Ring 无锁队列实现与性能分析]]
> 7. **第七章：PMD (Poll Mode Driver) 驱动架构**

---

## 1. 概述：什么是 PMD？

PMD (Poll Mode Driver) 是 DPDK 的用户态网卡驱动程序，运行在用户态，直接访问网卡硬件（通过 VFIO/UIO），无需内核驱动介入。

### 1.1 PMD vs Kernel Driver

| 维度 | Kernel NIC Driver | PMD (DPDK) |
|------|------------------|------------|
| **运行位置** | 内核态 | 用户态 |
| **访问方式** | 系统调用 | mmap BAR |
| **中断处理** | 硬件中断 | 轮询（Poll Mode） |
| **协议栈** | 内核 TCP/IP | 用户态或绕过 |
| **性能** | 受限于内核开销 | 线速（100G+） |
| **可控性** | 受限 | 完全控制 |

### 1.2 PMD 在 DPDK 架构中的位置

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           User Space                                    │
│                                                                          │
│  ┌─────────────────────────────────────────────────────────────────────┐ │
│  │                        Application                                   │ │
│  └─────────────────────────────────────────────────────────────────────┘ │
│                                    │                                     │
│  ┌─────────────────────────────────────────────────────────────────────┐ │
│  │                      ethdev (抽象层)                                 │ │
│  │                                                                      │ │
│  │   rte_eth_rx_burst() ───► PMD 回调                                  │ │
│  │   rte_eth_tx_burst() ───► PMD 回调                                  │ │
│  │   rte_eth_dev_configure() ───► PMD 回调                             │ │
│  │   rte_eth_dev_start() ───► PMD 回调                                 │ │
│  └─────────────────────────────────────────────────────────────────────┘ │
│                                    │                                     │
│  ┌─────────────────────────────────────────────────────────────────────┐ │
│  │                      PMD Drivers                                     │ │
│  │                                                                      │ │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐           │ │
│  │  │ ixgbe    │  │ i40e    │  │ virtio    │  │ mlx5     │           │ │
│  │  │ (Intel)  │  │ (Intel)  │  │ (QEMU)   │  │ (Mellanox)│           │ │
│  │  └──────────┘  └──────────┘  └──────────┘  └──────────┘           │ │
│  └─────────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
┌───────────────────────────────────▼─────────────────────────────────────┐
│                           Kernel Space                                   │
│                                                                          │
│                      vfio-pci / igb_uio                                 │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
┌───────────────────────────────────▼─────────────────────────────────────┐
│                           Hardware                                      │
│                                                                          │
│     ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐             │
│     │ ixgbe    │  │ i40e     │  │ virtio   │  │ mlx5     │             │
│     │ 82599    │  │ XL710    │  │ -net     │  │ ConnectX │             │
│     └──────────┘  └──────────┘  └──────────┘  └──────────┘             │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 2. ethdev 抽象层

### 2.1 ethdev 结构

```c
// lib/ethdev/rte_ethdev.h

struct rte_eth_dev {
    const char *name;                    // 设备名称 "eth_ixgbe_0"
    uint16_t device_index;               // 设备索引
    uint16_t port_id;                    // 端口 ID（应用程序使用）
    
    struct rte_eth_dev_data *data;       // 设备运行时数据
    const struct rte_eth_dev_ops *dev_ops; // 设备操作函数指针
    struct rte_eth_driver *driver;        // 指向驱动结构
    uint64_t extra_flags;                 // 驱动私有标志
    
    // 驱动特定数据（PMD 私有）
    void *process_private;
    
    enum rte_eth_dev_state state;        // 设备状态
};

struct rte_eth_dev_data {
    char name[RTE_ETH_NAME_MAX_LEN];    // 设备名
    void **rx_queues;                    // Rx 队列指针数组
    void **tx_queues;                    // Tx 队列指针数组
    uint16_t nb_rx_queues;               // Rx 队列数量
    uint16_t nb_tx_queues;               // Tx 队列数量
    
    struct rte_ether_addr *mac_addresses; // MAC 地址
    
    // 端口配置
    struct rte_eth_conf dev_conf;
    
    // 驱动私有数据
    void *dev_private;
};
```

### 2.2 dev_ops 函数指针表

```c
// lib/ethdev/rte_ethdev.h

struct rte_eth_dev_ops {
    /* 设备配置 */
    int (*dev_configure)(struct rte_eth_dev *dev);
    int (*dev_start)(struct rte_eth_dev *dev);
    int (*dev_stop)(struct rte_eth_dev *dev);
    int (*dev_close)(struct rte_eth_dev *dev);
    
    /* Rx 队列 */
    int (*rx_queue_setup)(struct rte_eth_dev *dev,
                           uint16_t rx_queue_id,
                           uint16_t nb_rx_desc,
                           unsigned int socket_id,
                           const struct rte_eth_rxconf *rx_conf,
                           struct rte_mempool *mp);
    void (*rx_queue_release)(struct rte_eth_dev *dev, uint16_t q_id);
    
    /* Tx 队列 */
    int (*tx_queue_setup)(struct rte_eth_dev *dev,
                           uint16_t tx_queue_id,
                           uint16_t nb_tx_desc,
                           unsigned int socket_id,
                           const struct rte_eth_txconf *tx_conf);
    void (*tx_queue_release)(struct rte_eth_dev *dev, uint16_t q_id);
    
    /* 收发包 */
    uint16_t (*rx_burst)(void *rxq,
                         struct rte_mbuf **rx_pkts,
                         uint16_t nb_pkts);
    uint16_t (*tx_burst)(void *txq,
                         struct rte_mbuf **tx_pkts,
                         uint16_t nb_pkts);
    
    /* 统计 */
    int (*stats_get)(struct rte_eth_dev *dev, 
                      struct rte_eth_stats *stats);
    int (*stats_reset)(struct rte_eth_dev *dev);
    
    /* 其他 */
    int (*link_update)(struct rte_eth_dev *dev, int wait_to_complete);
    int (*mac_addr_add)(struct rte_eth_dev *dev,
                          struct rte_ether_addr *addr,
                          uint32_t pool);
};
```

### 2.3 驱动注册宏

```c
// drivers/net/ixgbe/ixgbe_ethdev.c

// PMD 驱动描述符
static struct rte_eth_driver rte_ixgbe_pmd = {
    .driver_type = RTE_ETH_DEV_PCI,
    .drv_flags = RTE_ETH_DEV_AUTOFILLQUEUE,  // 自动填充队列
};

// 设备 ID 表
static const struct rte_pci_id rte_ixgbe_pmd_pci_id[] = {
    { RTE_PCI_DEVICE(IXGBE_VENDOR_ID, IXGBE_DEVICE_ID_82599) },
    { RTE_PCI_DEVICE(IXGBE_VENDOR_ID, IXGBE_DEVICE_ID_X540) },
    { RTE_PCI_DEVICE(IXGBE_VENDOR_ID, IXGBE_DEVICE_ID_XL710) },
    { RTE_PCI_DEVICE(IXGBE_VENDOR_ID, IXGBE_DEVICE_ID_82599_T3_LOM) },
    { .vendor_id = 0 },  // 结束标记
};

// 驱动初始化函数
static int
rte_ixgbe_pmd_init(const char *name,
                    const char *params)
{
    struct rte_eth_dev *eth_dev;
    
    // 1. 分配 eth_dev
    eth_dev = rte_eth_dev_allocate(name);
    if (eth_dev == NULL)
        return -ENOMEM;
    
    // 2. 绑定 PCI 设备
    eth_dev->device = &pci_dev->device;
    eth_dev->driver = &rte_ixgbe_pmd.driver;
    
    // 3. 设置 dev_ops
    eth_dev->dev_ops = &ixgbe_dev_ops;
    
    // 4. 设置回调函数（用于 ethdev 层调用 PMD）
    eth_dev->rx_pkt_burst = ixgbe_recv_pkts;
    eth_dev->tx_pkt_burst = ixgbe_xmit_pkts;
    
    return 0;
}

// PCI 驱动注册
RTE_PMD_REGISTER_PCI(net_ixgbe, rte_ixgbe_pmd);
RTE_PMD_REGISTER_PCI_TABLE(net_ixgbe, rte_ixgbe_pmd_pci_id);
```

---

## 3. PCI 设备探测

### 3.1 EAL PCI 探测流程

```
rte_eal_init()
    │
    └─► rte_bus_pci_scan()
            │
            └─► for each PCI device:
                    │
                    ├─► match with registered drivers
                    │
                    └─► driver.probe()
                            │
                            ├─► ixgbe_pci_probe()  ← 驱动特定探测
                            │
                            └─► rte_eth_dev_allocate()
                                    │
                                    └─► 创建 eth_dev 结构
```

### 3.2 ixgbe_pci_probe

```c
// drivers/net/ixgbe/ixgbe_ethdev.c

static int
ixgbe_pci_probe(struct rte_pci_driver *pci_drv,
                  struct rte_pci_device *pci_dev)
{
    struct rte_eth_dev *eth_dev;
    int ret;
    
    // 1. 创建设备
    eth_dev = rte_eth_dev_allocate(pci_dev->device.name);
    if (eth_dev == NULL) {
        ret = -ENOMEM;
        goto out;
    }
    
    // 2. 填充设备信息
    eth_dev->device = &pci_dev->device;
    eth_dev->driver = &rte_ixgbe_pmd.driver;
    eth_dev->intr_handle = pci_dev->intr_handle;
    
    // 3. 映射 PCI BAR
    ret = ixgbe_map_pci_bar(eth_dev);
    if (ret != 0)
        goto out;
    
    // 4. 初始化硬件
    ret = ixgbe_hw_init(eth_dev);
    if (ret != 0)
        goto out;
    
    // 5. 分配队列
    ret = ixgbe_alloc_queues(eth_dev);
    if (ret != 0)
        goto out;
    
    // 6. 设置回调
    eth_dev->rx_pkt_burst = ixgbe_recv_pkts;
    eth_dev->tx_pkt_burst = ixgbe_xmit_pkts;
    eth_dev->dev_ops = &ixgbe_dev_ops;
    
    printf("ixgbe: %s found\n", eth_dev->name);
    
out:
    return ret;
}
```

---

## 4. Rx/Tx 队列设置

### 4.1 rx_queue_setup

```c
// 应用程序调用
int
rte_eth_rx_queue_setup(uint16_t port_id,
                        uint16_t rx_queue_id,
                        uint16_t nb_rx_desc,
                        unsigned int socket_id,
                        const struct rte_eth_rxconf *conf,
                        struct rte_mempool *mp)
{
    struct rte_eth_dev *dev;
    int ret;
    
    dev = &rte_eth_devices[port_id];
    
    // 调用 PMD 的 rx_queue_setup
    ret = dev->dev_ops->rx_queue_setup(dev,
                                        rx_queue_id,
                                        nb_rx_desc,
                                        socket_id,
                                        conf,
                                        mp);
    return ret;
}

// ixgbe 实现
static int
ixgbe_rx_queue_setup(struct rte_eth_dev *dev,
                       uint16_t rx_queue_id,
                       uint16_t nb_rx_desc,
                       unsigned int socket_id,
                       const struct rte_eth_rxconf *conf,
                       struct rte_mempool *mp)
{
    struct ixgbe_rx_queue *q;
    uint16_t max_pkt_len;
    
    // 1. 分配队列结构
    q = rte_zmalloc_socket("rxq",
                            sizeof(struct ixgbe_rx_queue),
                            RTE_CACHE_LINE_SIZE,
                            socket_id);
    
    // 2. 分配 DMA 描述符数组
    //    描述符存储在连续的大页内存中
    uint64_t desc_size = nb_rx_desc * sizeof(union ixgbe_adv_rx_desc);
    q->rx_ring = rte_malloc_socket(NULL,
                                     desc_size,
                                     RTE_CACHE_LINE_SIZE,
                                     socket_id);
    
    // 3. 保存 mempool（用于分配 mbuf）
    q->mp = mp;
    
    // 4. 填充 DMA 描述符（与 mbuf 关联）
    //    每个描述符指向一个 mbuf 数据缓冲区
    for (int i = 0; i < nb_rx_desc; i++) {
        struct rte_mbuf *m = rte_pktmbuf_alloc(mp);
        m->data_off = RTE_PKTMBUF_HEADROOM;
        
        // 获取 mbuf 的 IOVA 地址（DMA 地址）
        q->rx_ring[i].read.hdr_addr = rte_mbuf_data_iova_default(m);
        q->rx_ring[i].read.pkt_addr = rte_mbuf_data_iova_default(m);
        
        // 保存 mbuf 指针（用于接收后填充数据）
        q->sw_ring[i] = m;
    }
    
    // 5. 配置 SRR (Split and Receive) 寄存器
    //    告诉 NIC 如何处理接收的数据
    
    // 6. 保存到 dev_data
    dev->data->rx_queues[rx_queue_id] = q;
    
    return 0;
}
```

### 4.2 Rx 描述符结构

```c
// drivers/net/ixgbe/ixgbe_rxtx.h

// 82599 接收描述符（16 字节）
typedef union {
    struct {
        __le64 pkt_addr;     // 数据包缓冲区的物理地址
        __le64 hdr_addr;     // 头部缓冲区的物理地址
    } read;
    
    struct {
        __le32 data_error;   // 接收错误状态
        __le32 rsss;         // RSS hash 结果
    } qw1;
} __rte_packed union ixgbe_adv_rx_desc;

// 接收描述符状态
struct ixgbe_adv_rx_desc {
    volatile uint64_t pkt_addr;    // DMA 地址
    volatile uint64_t hdr_addr;    // Header 地址
};
```

### 4.3 Rx 描述符环

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    Rx 描述符环（与 mbuf 关联）                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   rx_ring (DMA 内存)              sw_ring (mbuf 指针数组)                    │
│                                                                             │
│   ┌──────────────────┐           ┌──────────────────┐                     │
│   │ desc[0]          │           │ mbuf[0]          │                     │
│   │  .pkt_addr ──────┼───────────┼─► buf_iova       │                     │
│   │  .hdr_addr       │           │  .data_off=128   │                     │
│   └──────────────────┘           └──────────────────┘                     │
│   ┌──────────────────┐           ┌──────────────────┐                     │
│   │ desc[1]          │           │ mbuf[1]          │                     │
│   │  .pkt_addr ──────┼───────────┼─► buf_iova       │                     │
│   │  .hdr_addr       │           │  .data_off=128   │                     │
│   └──────────────────┘           └──────────────────┘                     │
│   ┌──────────────────┐           ┌──────────────────┐                     │
│   │ desc[2]          │           │ mbuf[2]          │                     │
│   │  .pkt_addr ──────┼───────────┼─► buf_iova       │                     │
│   │  .hdr_addr       │           │  .data_off=128   │                     │
│   └──────────────────┘           └──────────────────┘                     │
│          ...                             ...                              │
│                                                                             │
│   DMA 流程：                                                                 │
│   1. NIC 读取 desc[i].pkt_addr                                              │
│   2. DMA 将数据包写入该物理地址（mbuf 数据区）                                │
│   3. NIC 更新 desc[i].status (DD 位)                                        │
│   4. 驱动读取 DD 位，读取 mbuf 数据                                          │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 5. 收包流程 (rx_burst)

### 5.1 ethdev 层

```c
// lib/ethdev/rte_eth_rx_burst

uint16_t
rte_eth_rx_burst(uint16_t port_id,
                  uint16_t queue_id,
                  struct rte_mbuf **rx_pkts,
                  uint16_t nb_pkts)
{
    struct rte_eth_dev *dev;
    
    dev = &rte_eth_devices[port_id];
    
    // 调用 PMD 的 rx_burst 函数指针
    return (*dev->rx_pkt_burst)(
        dev->data->rx_queues[queue_id],
        rx_pkts,
        nb_pkts);
}
```

### 5.2 ixgbe_recv_pkts 实现

```c
// drivers/net/ixgbe/ixgbe_rxtx.c

uint16_t
ixgbe_recv_pkts(void *rx_queue,
                  struct rte_mbuf **rx_pkts,
                  uint16_t nb_pkts)
{
    struct ixgbe_rx_queue *q = rx_queue;
    union ixgbe_adv_rx_desc *rx_ring = q->rx_ring;
    struct rte_mbuf **sw_ring = q->sw_ring;
    
    uint16_t nb_rx = 0;
    uint16_t next_dd;
    uint16_t current_dd;
    
    // 1. 获取当前的 consumer index
    next_dd = q->rx_tail;
    
    // 2. 批量处理
    //    通常 nb_pkts = 32（优化后的 batch size）
    while (nb_rx < nb_pkts) {
        union ixgbe_adv_rx_desc *desc;
        struct rte_mbuf *m;
        
        desc = &rx_ring[next_dd];
        
        // 3. 检查 DD (Descriptor Done) 位
        //    NIC 写入数据后设置 DD 位
        if (!(desc->wb.upper.status_error & 
              rte_cpu_to_le_32(IXGBE_RXDADV_STAT_DD)))
            break;  // 没有更多完成的数据包
        
        // 4. 获取对应的 mbuf
        m = sw_ring[next_dd];
        
        // 5. 更新 mbuf 元数据
        m->data_len = rte_cpu_to_le_16(desc->wb.upper.length);
        m->pkt_len = m->data_len;
        m->port = q->port_id;
        
        // 6. 解析 RSS hash（如果启用）
        if (desc->wb.lower.status_error & 
            IXGBE_RXDADV_STAT_RSS_HASH) {
            m->ol_flags |= PKT_RX_RSS_HASH;
            m->hash.rss = rte_cpu_to_le_32(
                desc->wb.lower.hi_dword.rss);
        }
        
        // 7. 检查 Checksum 卸载
        if (desc->wb.lower.status_error & 
            IXGBE_RXDADV_STAT_IPCS) {
            if (!(desc->wb.lower.status_error & 
                  IXGBE_RXDADV_ERR_IPE))
                m->ol_flags |= PKT_RX_IP_CKSUM_GOOD;
        }
        if (desc->wb.lower.status_error & 
            IXGBE_RXDADV_STAT_L4CS) {
            if (!(desc->wb.lower.status_error & 
                  IXGBE_RXDADV_ERR_L4E))
                m->ol_flags |= PKT_RX_L4_CKSUM_GOOD;
        }
        
        // 8. 检查 VLAN
        if (desc->wb.upper.vlan) {
            m->ol_flags |= PKT_RX_VLAN;
            m->vlan_tci = rte_cpu_to_le_16(
                desc->wb.upper.vlan);
        }
        
        // 9. 分配新的 mbuf 填充描述符（重新填充）
        struct rte_mbuf *new_m = rte_pktmbuf_alloc(q->mp);
        new_m->data_off = RTE_PKTMBUF_HEADROOM;
        
        // 更新描述符的 DMA 地址
        rx_ring[next_dd].read.pkt_addr = 
            rte_mbuf_data_iova_default(new_m);
        rx_ring[next_dd].read.hdr_addr = 0;
        
        // 保存新 mbuf
        sw_ring[next_dd] = new_m;
        
        // 10. 将完成的 mbuf 放入输出数组
        rx_pkts[nb_rx++] = m;
        
        // 11. 移动指针（绕回）
        next_dd++;
        if (next_dd == q->nb_rx_desc)
            next_dd = 0;
    }
    
    // 12. 更新 consumer index
    q->rx_tail = next_dd;
    
    // 13. 写入 EOP + RS 位（通知 NIC 描述符已消费）
    ixgbe_release_rx_desc(q, next_dd);
    
    return nb_rx;
}
```

### 5.3 Rx 完整流程图

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           Rx 收包完整流程                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  1. 初始化阶段                                                              │
│     ┌─────────────────────────────────────────────────────────────────┐     │
│     │  rx_queue_setup()                                              │     │
│     │    - 分配 rx_ring (DMA 描述符数组)                              │     │
│     │    - 分配 sw_ring (mbuf 指针数组)                              │     │
│     │    - 填充每个描述符指向 mbuf 的 IOVA                           │     │
│     │    - 配置 NIC Rx registers                                      │     │
│     └─────────────────────────────────────────────────────────────────┘     │
│                                                                             │
│  2. NIC DMA 阶段                                                            │
│     ┌─────────────────────────────────────────────────────────────────┐     │
│     │  NIC 从 PCIe BAR 读取 Rx 描述符                                  │     │
│     │  NIC DMA 将接收到的数据包写入 desc.pkt_addr (mbuf 数据区)        │     │
│     │  NIC 更新描述符状态 (DD=1, length, checksum status, etc.)       │     │
│     └─────────────────────────────────────────────────────────────────┘     │
│                                                                             │
│  3. 驱动轮询阶段                                                            │
│     ┌─────────────────────────────────────────────────────────────────┐     │
│     │  rte_eth_rx_burst()                                             │     │
│     │    │                                                            │     │
│     │    ├─► ixgbe_recv_pkts()                                        │     │
│     │    │                                                            │     │
│     │    │  while (!DD) { ... }  // 轮询 DD 位                       │     │
│     │    │                                                            │     │
│     │    │  for each DD desc:                                        │     │
│     │    │    - 读取 mbuf 元数据                                      │     │
│     │    │    - 解析 RSS hash / checksum / VLAN                     │     │
│     │    │    - 填充 mbuf ol_flags                                   │     │
│     │    │    - 重新填充描述符 (分配新 mbuf)                          │     │
│     │    │                                                            │     │
│     │    └─► 返回 rx_pkts[]                                           │     │
│     └─────────────────────────────────────────────────────────────────┘     │
│                                                                             │
│  4. 应用处理阶段                                                            │
│     ┌─────────────────────────────────────────────────────────────────┐     │
│     │  for each mbuf in rx_pkts:                                     │     │
│     │    - 检查 ol_flags                                             │     │
│     │    - 解析 Ethernet / IP / UDP / TCP header                    │     │
│     │    - 处理负载                                                   │     │
│     │    - rte_pktmbuf_free(mbuf)                                    │     │
│     └─────────────────────────────────────────────────────────────────┘     │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 6. 发包流程 (tx_burst)

### 6.1 tx_queue_setup

```c
// ixgbe_tx_queue_setup 实现
static int
ixgbe_tx_queue_setup(struct rte_eth_dev *dev,
                       uint16_t tx_queue_id,
                       uint16_t nb_tx_desc,
                       unsigned int socket_id,
                       const struct rte_eth_txconf *conf)
{
    struct ixgbe_tx_queue *q;
    
    // 1. 分配队列结构
    q = rte_zmalloc_socket("txq",
                            sizeof(struct ixgbe_tx_queue),
                            RTE_CACHE_LINE_SIZE,
                            socket_id);
    
    // 2. 分配 Tx 描述符环（必须是 2^n）
    uint64_t desc_size = nb_tx_desc * sizeof(union ixgbe_adv_tx_desc);
    q->tx_ring = rte_malloc_socket(NULL,
                                    desc_size,
                                    RTE_CACHE_LINE_SIZE,
                                    socket_id);
    
    // 3. 分配 ctx_ring（存储 TX context）
    q->ctx_ring = rte_malloc_socket(...);
    
    // 4. 初始化 Free Threshold
    q->free_thresh = (conf->tx_free_thresh) ?
                      conf->tx_free_thresh : nb_tx_desc / 4;
    
    // 5. 初始化 RS Threshold
    q->rs_thresh = (conf->tx_rs_thresh) ?
                    conf->tx_rs_thresh : nb_tx_desc / 4;
    
    // 6. 保存到 dev_data
    dev->data->tx_queues[tx_queue_id] = q;
    
    return 0;
}
```

### 6.2 ixgbe_xmit_pkts 实现

```c
// drivers/net/ixgbe/ixgbe_rxtx.c

uint16_t
ixgbe_xmit_pkts(void *tx_queue,
                  struct rte_mbuf **tx_pkts,
                  uint16_t nb_pkts)
{
    struct ixgbe_tx_queue *q = tx_queue;
    union ixgbe_adv_tx_desc *tx_ring = q->tx_ring;
    struct rte_mbuf *m;
    
    uint16_t nb_tx = 0;
    uint16_t tx_head = q->tx_head;
    uint16_t tx_tail = q->tx_tail;
    
    while (nb_tx < nb_pkts) {
        m = tx_pkts[nb_tx];
        
        // 1. 检查可用描述符
        uint16_t used = (tx_head >= tx_tail) ?
                         tx_head - tx_tail :
                         q->nb_tx_desc - tx_tail + tx_head;
        
        // 需要 1 个描述符（单 segment）
        if (used >= q->nb_tx_desc - 1)
            break;
        
        // 2. 获取当前描述符
        union ixgbe_adv_tx_desc *desc = &tx_ring[tx_head];
        
        // 3. 填充描述符
        desc->read.buffer_addr = rte_mbuf_data_iova(m);
        desc->read.cmd_type_len = 
            IXGBE_ADVTXD_DCMD_DEXT |  // 扩展描述符
            IXGBE_ADVTXD_DCMD_EOP |   // 包结束
            IXGBE_ADVTXD_DCMD_RS |    // 报告状态
            m->data_len;              // 数据长度
        
        // 4. 设置 offload 信息
        if (m->ol_flags & PKT_TX_IPV4) {
            desc->read.olinfo_status |=
                IXGBE_ADVTXD_IPSEC_L4_TYPE;
        }
        if (m->ol_flags & PKT_TX_L4_CKSUM) {
            desc->read.olinfo_status |=
                IXGBE_ADVTXD_L4T_SCTP << 
                IXGBE_ADVTXD_L4T_SHIFT;
        }
        
        // 5. 保存 mbuf 指针（发送完成后释放）
        q->sw_ring[tx_head] = m;
        
        nb_tx++;
        tx_head++;
        if (tx_head == q->nb_tx_desc)
            tx_head = 0;
    }
    
    // 6. 更新 tx_head
    q->tx_head = tx_head;
    
    // 7. 写入 doorbell，通知 NIC
    IXGBE_PCI_REG_WRITE(tx_tail + q->tail_db, tx_head);
    
    return nb_tx;
}
```

### 6.3 Tx 描述符结构

```c
// drivers/net/ixgbe/ixgbe_rxtx.h

// 82599 发送描述符（16 字节）
typedef union {
    struct {
        __le64 buffer_addr;      // 数据缓冲区的物理地址
        __le64 cmd_type_len;      // 命令和长度
    } read;
    
    struct {
        __le32 dw[4];
    } w32;
} __rte_packed union ixgbe_adv_tx_desc;

// cmd_type_len 字段定义
#define IXGBE_ADVTXD_DCMD_EOP    (1ULL << 24)  // End of Packet
#define IXGBE_ADVTXD_DCMD_RS     (1ULL << 23)  // Report Status
#define IXGBE_ADVTXD_DCMD_DEXT   (1ULL << 22)  // Descriptor Extension
#define IXGBE_ADVTXD_DCMD_VLE    (1ULL << 20)  // VLAN Insertion
#define IXGBE_ADVTXD_DCMD_IFCS   (1ULL << 18)  // Insert FCS
```

---

## 7. 常见 PMD 驱动

### 7.1 Intel 驱动

| 驱动 | 设备 | 特点 |
|------|------|------|
| **igb** | 82575, 82576 | 1G NIC |
| **ixgbe** | 82598, 82599, X540 | 10G NIC |
| **i40e** | XL710, X710 | 10G/40G NIC |
| **ice** | E800, E810 | 100G, Advanced Vector |

### 7.2 虚拟化驱动

| 驱动 | 设备 | 特点 |
|------|------|------|
| **virtio** | QEMU/KVM virtio-net | 虚拟化通用驱动 |
| **vmxnet3** | VMware | ESXi 虚拟网卡 |
| **bnxt** | Broadcom | 融合网卡 |

### 7.3 其他厂商

| 驱动 | 厂商 | 特点 |
|------|------|------|
| **mlx5** | NVIDIA/Mellanox | 100G+, RDMA, Verbs |
| **nfp** | Netronome | 智能网卡 |
| **sfc** | Solarflare | 低延迟 |

---

## 8. virtio PMD 详解

### 8.1 virtio 概述

virtio 是 QEMU/KVM 虚拟机的标准半虚拟化网络驱动，比纯软件模拟快得多：

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         virtio-net 架构                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│                        Guest (VM)                           Host           │
│  ┌─────────────────────────────────────────────────────┐  ┌──────────────┐ │
│  │  DPDK + virtio PMD                                  │  │  QEMU/KVM    │ │
│  │                                                     │  │              │ │
│  │  ┌──────────┐      ┌──────────┐      ┌──────────┐  │  │  virtio-net  │ │
│  │  │  App      │ ───► │ virtio   │ ───► │ vring    │  │  │  backend     │ │
│  │  │          │      │ PMD      │      │ (shared  │  │  │              │ │
│  │  │          │ ◄─── │          │ ◄─── │ memory)  │  │  │              │ │
│  │  └──────────┘      └──────────┘      └──────────┘  │  │              │ │
│  └─────────────────────────────────────────────────────┘  └──────────────┘ │
│                              │                                    │         │
│                              │     vhost-user (AF_VSOCK)        │         │
│                              └──────────────────────────────────►│         │
│                                                                        │         │
│                          ┌──────────────┐                              │         │
│                          │   Physical   │                              │         │
│                          │     NIC      │                              │         │
│                          └──────────────┘                              │         │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 8.2 virtio 描述符环

```c
// virtio 驱动使用 vring（虚拟队列）

struct vring_desc {
    uint64_t addr;     // 缓冲区物理地址
    uint32_t len;      // 缓冲区长度
    uint16_t flags;    // VRING_DESC_F_NEXT 等
    uint16_t next;     // 下一个描述符（chained）
};

// Rx vring 结构
struct virtnet_rx {
    struct vring_desc *desc;     // 描述符数组
    struct vring_avail *avail;   // 可用环
    struct vring_used *used;     // 已用环
    
    // 与 ixgbe 不同：描述符是"引用"而非"拥有"
    // 驱动写入 addr，hypervisor DMA 读取/写入
};
```

---

## 9. 驱动性能优化

### 9.1 Batch Processing

```c
// 优化：批量处理减少函数调用开销
// 原始：逐个处理
for (int i = 0; i < nb_rx; i++) {
    rte_pktmbuf_free(pkts[i]);  // 多次函数调用
}

// 优化：批量释放
rte_mbuf_raw_free_bulk(pkts, nb_rx);  // 一次函数调用
```

### 9.2 预取优化

```c
// 预取下一个要处理的描述符
static inline uint16_t
ixgbe_recv_pkts(void *rxq, struct rte_mbuf **rx_pkts, uint16_t nb_pkts)
{
    // 预取前 4 个 mbuf
    for (int i = 0; i < 4 && i < nb_rx; i++) {
        rte_prefetch0(rx_pkts[i]);
    }
    
    // 处理...
}
```

### 9.3 NIC Offload 配置

```c
// 启用 NIC 硬件卸载
struct rte_eth_conf port_conf = {
    .rxmode = {
        .mq_mode = RTE_ETH_MQ_RX_NONE,
        .offloads = DEV_RX_OFFLOAD_IPV4_CKSUM |
                    DEV_RX_OFFLOAD_UDP_CKSUM  |
                    DEV_RX_OFFLOAD_TCP_CKSUM  |
                    DEV_RX_OFFLOAD_VLAN       |
                    DEV_RX_OFFLOAD_JUMBO_FRAME,
    },
    .txmode = {
        .mq_mode = RTE_ETH_MQ_TX_NONE,
        .offloads = DEV_TX_OFFLOAD_IPV4_CKSUM |
                    DEV_TX_OFFLOAD_UDP_CKSUM  |
                    DEV_TX_OFFLOAD_TCP_CKSUM  |
                    DEV_TX_OFFLOAD_VLAN_INSERT|
                    DEV_TX_OFFLOAD_TCP_TSO,
    },
};
```

---

## 10. 小结

本章核心要点：

1. **PMD 架构**：用户态网卡驱动，通过 VFIO/UIO 直接访问硬件，绕过内核网络栈。

2. **ethdev 抽象**：统一的设备操作接口（dev_ops + 函数指针），应用程序无需关心具体驱动实现。

3. **PCI 探测**：EAL 扫描 PCI 总线，匹配驱动，调用驱动的 probe 函数初始化设备。

4. **Rx 队列设置**：分配 DMA 描述符环，每个描述符关联一个 mbuf，NIC DMA 写入数据。

5. **Tx 队列设置**：分配描述符环，mbuf 在发送完成后通过 free threshold 释放。

6. **收包流程**：轮询 DD 位 → 读取元数据 → 填充 ol_flags → 重新填充描述符 → 返回 mbuf 数组。

7. **发包流程**：填充描述符 → 保存 mbuf 指针 → 写入 doorbell → NIC DMA + 发送。

8. **virtio**：半虚拟化驱动，使用 vring 共享内存，QEMU 作为 backend。

**下一篇预告**：[[2026-04-09-dpdk-deep-dive-ch8-timer-wheel|第八章]]将深入讲解 DPDK 软件定时器——rte_timer 的 HTimer 实现、wheel & level 桶算法、以及在 DPDK 应用中的使用场景。

---

> [!tip] 参考文献
> - Intel, "DPDK Poll Mode Driver", https://doc.dpdk.org/guides/prog_guide/poll_mode_drv.html
> - Intel, "DPDK ethdev API", https://doc.dpdk.org/rte_ethdev_8h.html
> - "ixgbe/ixgbe_rxtx.c source code", https://github.com/DPDK/dpdk/blob/main/drivers/net/ixgbe/ixgbe_rxtx.c
> - "Virtio specification", https://docs.oasis-open.org/virtio/virtio/v1.1/virtio-v1.1.pdf
