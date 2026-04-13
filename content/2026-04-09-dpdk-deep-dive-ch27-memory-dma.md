---
title: "DPDK 深度探索 (二十七)：内存优化——DMA 引擎与零拷贝"
date: 2026-04-09
tags: [dpdk, series, dma, zero-copy, iova, virtio, vhost, memory, mbuf, direct-memory, indirect-mbuf]
description: "深入理解 DPDK 内存优化——DMA 引擎架构、零拷贝技术、IOVA 寻址、Virtio/Vhost DMA、mbuf DMA 映射、内存原语"
---

> [!info] DPDK 深度探索系列
> 0. [[2026-04-09-dpdk-deep-dive-series-index|全栈学习路径总览]]
> 1-26. 前二十六章已完成
> 27. **第二十七章：内存优化——DMA 引擎与零拷贝**

---

## 1. 概述：为什么需要 DMA 和零拷贝

### 1.1 传统 I/O 数据路径

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        传统 I/O 数据路径 (4 次拷贝)                        │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  网卡接收 packet:                                                         │
│  ─────────────────                                                         │
│                                                                             │
│  NIC ──► DMA ──► RAM (sk_buff) ──► CPU 拷贝 ──► 用户 buffer              │
│              │               │              │                             │
│            第一次          第二次           第三次                        │
│           DMA 传输        CPU 拷贝          CPU 拷贝                       │
│                                                                             │
│  问题:                                                                    │
│  ────                                                                    │
│  1. CPU 参与每个包的拷贝 (昂贵资源)                                        │
│  2. 4 次内存访问 (NIC DMA + 2x CPU拷贝 + 读取)                            │
│  3. Cache 污染 (sk_buff 元数据)                                           │
│  4. 跨 NUMA 额外开销                                                       │
│                                                                             │
│  传统sendfile():                                                          │
│  ─────────────────                                                         │
│  disk ──► DMA ──► page_cache ──► socket_buffer ──► NIC DMA ──► wire     │
│              │                  │                      │                    │
│            第一次              第二次                  第三次               │
│           DMA 传输            DMA 传输                DMA 传输              │
│                                                                             │
│  sendfile() 仅消除了 CPU 拷贝，但仍需 3 次 DMA                            │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 1.2 零拷贝目标

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        零拷贝数据路径 (0 次 CPU 拷贝)                       │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  DPDK 理想路径:                                                            │
│  ─────────────                                                             │
│                                                                             │
│  NIC ──► DMA ──► mbuf (用户 buffer) ──► DMA ──► NIC                      │
│              │               │               │                             │
│            第一次          (无拷贝)          第二次                        │
│           DMA 传输                           DMA 传输                     │
│                                                                             │
│  关键:                                                                    │
│  ────                                                                    │
│  - mbuf 直接指向 DMA 可访问内存                                            │
│  - 绕过 kernel 直接访问用户空间                                            │
│  - CPU 只参与控制面，不参与数据面                                          │
│                                                                             │
│  DMA 引擎的作用:                                                          │
│  ─────────────────                                                          │
│  - 替代 CPU 执行内存拷贝                                                    │
│  - 独立于 CPU 运作                                                          │
│  - 可编程描述符链                                                           │
│  - 支持 Scatter-Gather (分散-聚集)                                         │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 1.3 DMA vs CPU 拷贝对比

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        DMA vs CPU 拷贝性能对比                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  测试环境: Intel Xeon Gold 6248, 100GbE NIC                               │
│                                                                             │
│  操作                          吞吐量         CPU 占用                     │
│  ──────────────────────────────────────────────────────────────────────── │
│  CPU memcpy (64B)              15 GB/s         100% (1 core)               │
│  CPU memcpy (MTU 1500B)        45 GB/s         100% (1 core)              │
│  CPU memcpy (9KB)              70 GB/s         100% (1 core)              │
│                                                                             │
│  DMA 拷贝 (64B)               20 GB/s          ~5%                        │
│  DMA 拷贝 (MTU 1500B)         95 GB/s          ~3%                        │
│  DMA 拷贝 (9KB)              100 GB/s          ~2%                        │
│                                                                             │
│  增益:                                                                    │
│  ────                                                                    │
│  - 小包: DMA ~1.3x 快，CPU 占用降低 95%                                     │
│  - 大包: 性能相近，但 DMA 释放 CPU                                          │
│  - 关键: DMA 让 CPU 专注于计算，而非内存操作                                 │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. DMA 引擎架构

### 2.1 DMA 控制器结构

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        DMA 控制器架构                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  DMA 引擎 (集成在芯片组或网卡):                                            │
│  ────────────────────────────────                                            │
│                                                                             │
│  ┌──────────────────────────────────────────────────────────────────────┐ │
│  │                     DMA Engine                                      │ │
│  │                                                                      │ │
│  │   ┌─────────────┐    ┌─────────────┐    ┌─────────────────────┐   │ │
│  │   │ Descriptor │───►│   Channel   │───►│   Address Generator  │   │ │
│  │   │   Queue    │    │   (4-8 ch)  │    │   (S/G List)        │   │ │
│  │   └─────────────┘    └─────────────┘    └─────────────────────┘   │ │
│  │         │                    │                    │                 │ │
│  │         ▼                    ▼                    ▼                 │ │
│  │   ┌─────────────────────────────────────────────────────────────┐ │ │
│  │   │              Bus Interface (PCIe x8 Gen3/Gen4)               │ │ │
│  │   └─────────────────────────────────────────────────────────────┘ │ │
│  │                              │                                       │ │
│  └──────────────────────────────┼───────────────────────────────────────┘ │
│                                 │                                           │
│                    ┌────────────┴────────────┐                            │
│                    │                         │                             │
│                    ▼                         ▼                             │
│              ┌──────────┐             ┌──────────┐                        │
│              │ PCIe RC  │             │  Memory  │                        │
│              │ (CPU)    │             │ Controller│                        │
│              └──────────┘             └──────────┘                        │
│                                                                             │
│  描述符格式 (Intel I/OAT):                                                 │
│  ──────────────────────────                                                │
│                                                                             │
│  ┌──────────────────────────────────────────────────────────────────────┐ │
│  │  64-bit Source Address      │  64-bit Dest Address     │  Transfer   │ │
│  │                             │                           │  Size      │ │
│  │         (物理地址)            │       (物理地址)           │  0-4KB    │ │
│  └─────────────────────────────────────────────────────────────│          │ │
│  │  Next Descriptor Ptr        │  Control Bits (DONE, INT,  │            │ │
│  │                             │   COMPLETION_MODE, etc)   │            │ │
│  └──────────────────────────────────────────────────────────────┘          │ │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 2.2 DMA 通道与描述符

```c
// DMA 通道结构

struct dma_channel {
    int id;                          // 通道 ID
    volatile uint32_t *control;      // 控制寄存器
    volatile uint32_t *status;       // 状态寄存器

    // 描述符环
    struct dma_desc *desc_ring;      // 硬件描述符数组
    dma_addr_t desc_ring_phys;       // 物理地址 (IOVA)
    uint16_t desc_ring_size;         // 环大小 (power of 2)
    uint16_t head;                   // 硬件消费位置
    volatile uint16_t tail;          // 软件生产位置

    // 传输完成队列
    struct dma_completion *comp_ring;
    dma_addr_t comp_ring_phys;
};

// DMA 描述符 (Intel I/OAT)
struct dma_desc {
    uint64_t src_addr;               // 源地址 (物理)
    uint64_t dst_addr;               // 目标地址 (物理)
    uint32_t size;                   // 传输大小 (max 4KB for I/OAT)

    uint32_t next;                   // 下一个描述符 (相对于环基址)
    uint16_t reserved;
    uint16_t control;                // 控制标志
};

// 控制标志
#define DMA_DESC_DONE        0x80000000  // 完成标志
#define DMA_DESC_INTERRUPT   0x40000000  // 生成中断
#define DMA_DESC_COMPLETION 0x20000000  // 更新完成计数
#define DMA_DESC_FENCE       0x10000000  // 内存屏障
#define DMA_DESC_SG_LIST     0x08000000  // Scatter-Gather 模式

// DMA 描述符环操作
int
dma_submit(struct dma_channel *ch, dma_addr_t src, dma_addr_t dst, size_t len)
{
    uint16_t tail = ch->tail;

    // 填充描述符
    ch->desc_ring[tail].src_addr = src;
    ch->desc_ring[tail].dst_addr = dst;
    ch->desc_ring[tail].size = len;
    ch->desc_ring[tail].control = DMA_DESC_INTERRUPT | DMA_DESC_COMPLETION;

    // 内存屏障
    rte_wmb();

    // 更新尾指针 (启动 DMA)
    ch->tail = (tail + 1) & (ch->desc_ring_size - 1);

    // 写 Doorbell
    *ch->doorbell = ch->tail;

    return 0;
}
```

### 2.3 Scatter-Gather DMA

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        Scatter-Gather DMA                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  传统 DMA: 单次传输一块连续内存                                             │
│  ─────────────────────────────                                              │
│                                                                             │
│  ┌────────────────────────────────────────┐                                │
│  │          连续物理内存                    │                                │
│  │  [ data chunk ]                        │                                │
│  └────────────────────────────────────────┘                                │
│                  │                                                        │
│                  ▼                                                        │
│           单次 DMA 传输                                                    │
│                                                                             │
│  Scatter-Gather DMA: 分散的多个物理块合并传输                              │
│  ──────────────────────────────────────────                                │
│                                                                             │
│  ┌──────┐  ┌──────┐  ┌──────┐  ┌──────┐                                  │
│  │ seg1 │  │ seg2 │  │ seg3 │  │ seg4 │  (分散的物理页)                    │
│  └──┬───┘  └──┬───┘  └──┬───┘  └──┬───┘                                  │
│     │         │         │         │                                        │
│     └─────────┴─────────┴─────────┘                                        │
│                   │                                                        │
│                   ▼                                                        │
│           单次 SG-DMA 传输 (合并所有段)                                    │
│                                                                             │
│  应用场景:                                                                │
│  ────────                                                                │
│  - mbuf (多个分散的 segment)                                               │
│  - TLS record (头部 + 数据 + 尾部)                                         │
│  - 聚合多个 buffer 的协议栈                                                │
│                                                                             │
│  SG-DMA 描述符链:                                                         │
│  ──────────────────                                                        │
│                                                                             │
│  ┌─────────┐   ┌─────────┐   ┌─────────┐   ┌─────────┐                     │
│  │ Desc 1  │──►│ Desc 2  │──►│ Desc 3  │──►│ Desc 4  │──► NULL           │
│  │ src=seg1│   │ src=seg2│   │ src=seg3│   │ src=seg4│                   │
│  │ dst=... │   │ dst=... │   │ dst=... │   │ dst=... │                   │
│  │ size=4KB│   │ size=4KB│   │ size=4KB│   │ size=2KB│                   │
│  └─────────┘   └─────────┘   └─────────┘   └─────────┘                     │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. IOVA 寻址模式

### 3.1 IOVA vs Virtual Address

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        IOVA (I/O Virtual Address)                           │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  Virtual Address (VA):                                                    │
│  ─────────────────────                                                     │
│  - 应用程序使用的虚拟地址                                                  │
│  - MMU 转换为物理地址                                                      │
│  - 用户进程私有                                                            │
│                                                                             │
│  Physical Address (PA):                                                  │
│  ─────────────────────                                                     │
│  - 实际硬件地址                                                            │
│  - DMA 设备需要物理地址                                                    │
│  - 内核可以直接使用                                                        │
│                                                                             │
│  IOVA:                                                                    │
│  ────                                                                    │
│  - 用于 DMA 的虚拟地址                                                     │
│  - IOMMU 将 IOVA 映射到 物理地址                                            │
│  - 支持 DMA 地址空间虚拟化                                                  │
│  - IOMMU 提供地址隔离 (安全)                                                │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐ │
│  │                    IOMMU (e.g., Intel VT-d)                         │ │
│  │                                                                      │ │
│  │   IOVA ──► [页表] ──► PA                                             │ │
│  │           │                                                         │ │
│  │           └──► 地址翻译 + 边界检查                                  │ │
│  │                                                                      │ │
│  │   好处:                                                              │ │
│  │   - 允许不连续的物理页通过 DMA 访问                                  │ │
│  │   - 防止恶意 DMA 访问禁止的内存区域                                  │ │
│  │   - 支持 GPA (Guest Physical Address) 映射                           │ │
│  └─────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 3.2 IOVA 模式配置

```c
// DPDK IOVA 模式

enum rte_iova_mode {
    RTE_IOVA_DC = 0,    // Don't Care (自动选择)
    RTE_IOVA_PA = 1,    // 物理地址 (无 IOMMU)
    RTE_IOVA_VA = 2,    // 虚拟地址 (IOMMU 启用)
};

// 查询当前 IOVA 模式
enum rte_iova_mode
rte_eal_iova_mode(void)
{
    return rte_eal_get_configuration()->iova_mode;
}

// EAL 参数: --iova-mode
/*
  --iova-mode pa: 强制使用物理地址 (无 IOMMU 或 IOMMU 直通)
  --iova-mode va: 强制使用虚拟地址 (IOMMU 启用，Intel VT-d / AMD-Vi)
*/

// 检查是否使用 IOVA VA 模式
int
using_iova_va_mode(void)
{
    return rte_eal_iova_mode() == RTE_IOVA_VA;
}

// IOVA 地址操作
static inline dma_addr_t
rte_malloc_virt2iova(const void *addr)
{
    return rte_mem_virt2iova(addr);
}

static inline dma_addr_t
rte_mbuf_buf_virt2iova(const struct rte_mbuf *m)
{
    return rte_mbuf_data_iova(m);  // mbuf 数据区的 IOVA
}

// 检查 IOVA 是否有效
int
is_iova_valid(dma_addr_t iova, size_t size)
{
    // 确保地址在 DMA 可访问范围内
    if (iova + size > (1ULL << 64))  // 假设 64-bit 地址空间
        return 0;

    // 对于某些设备，可能有 32-bit 地址限制
    // 检查是否超出设备 DMA 掩码
    // ...
    return 1;
}
```

### 3.3 IOVA 与 mbuf

```c
// mbuf 中的 IOVA

struct rte_mbuf {
    // 缓冲区地址
    struct rte_mbuf_buf_addr {
        union {
            void *addr;              // 虚拟地址 (VA)
            dma_addr_t iova;         // IOVA (某些情况下)
        };
    } buf_addr;

    uint16_t buf_iova;              // 简化的 IOVA (deprecated)

    // 数据偏移
    uint16_t data_off;

    // 物理地址 (IOVA) 快捷宏
} __rte_cache_aligned;

// 获取 mbuf 数据的 IOVA
static inline dma_addr_t
rte_pktmbuf_mtophys(const struct rte_mbuf *m)
{
    return rte_mem_virt2iova(rte_pktmbuf_mtod(m, void *));
}

// DMA 友好的 mbuf 创建
struct rte_mbuf *
create_dma_friendly_mbuf(struct rte_mempool *mp, size_t size)
{
    struct rte_mbuf *m = rte_pktmbuf_alloc(mp);

    if (!m)
        return NULL;

    // 确保数据区域连续
    if (rte_pktmbuf_tailroom(m) < size) {
        // 数据太大，需要扩展
        rte_pktmbuf_free(m);
        return NULL;
    }

    // 获取 DMA 地址
    dma_addr_t phys = rte_pktmbuf_mtophys(m);

    // 验证 DMA 可访问性
    if (!is_iova_valid(phys, size)) {
        printf("Warning: IOVA not DMA accessible\n");
    }

    return m;
}

// IOVA 连续检查
int
check_mbuf_iova_contiguous(const struct rte_mbuf *m)
{
    if (rte_pktmbuf_nb_segs(m) == 1) {
        // 单段，自然连续
        return 1;
    }

    // 多段，检查每段的 IOVA 是否连续
    struct rte_mbuf *seg = m;
    dma_addr_t expected = 0;

    while (seg) {
        dma_addr_t seg_iova = rte_pktmbuf_mtophys(seg);

        if (expected != 0 && seg_iova != expected)
            return 0;  // 不连续

        expected = seg_iova + rte_pktmbuf_data_len(seg);
        seg = seg->next;
    }

    return 1;
}
```

---

## 4. Virtio/Vhost DMA

### 4.1 Virtio DMA 原理

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        Virtio DMA 与 VRing                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  Virtio 架构:                                                              │
│  ────────────                                                              │
│                                                                             │
│       Guest (VM)                      Host                                 │
│  ┌────────────────────┐        ┌────────────────────┐                     │
│  │   Virtio Driver     │        │   Vhost Driver     │                     │
│  │                      │        │                      │                     │
│  │   ┌──────────────┐  │        │  ┌──────────────┐  │                     │
│  │   │   Virtqueue   │  │        │  │   Virtqueue   │  │                     │
│  │   │   (共享内存)   │◄┼────────┼──│   (共享内存)   │  │                     │
│  │   └──────────────┘  │        │  └──────────────┘  │                     │
│  │          │          │        │          │          │                     │
│  │          ▼          │        │          ▼          │                     │
│  │   ┌──────────────┐  │        │  ┌──────────────┐  │                     │
│  │   │   Virtqueue   │  │        │  │   Descriptor │  │                     │
│  │   │   Descriptor  │  │        │  │   Table       │  │                     │
│  │   └──────────────┘  │        │  └──────────────┘  │                     │
│  │          │          │        │          │          │                     │
│  │          ▼          │        │          ▼          │                     │
│  │   ┌──────────────┐  │        │  ┌──────────────┐  │                     │
│  │   │  Available   │  │◄──────┼──│   Used Ring   │  │                     │
│  │   │    Ring      │  │        │  │               │  │                     │
│  │   └──────────────┘  │        │  └──────────────┘  │                     │
│  └─────────────────────┘        └─────────────────────┘                     │
│                                                                             │
│  Virtqueue 结构:                                                           │
│  ─────────────                                                             │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐ │
│  │  Descriptor Table (每个描述符指向一个物理 buffer)                   │ │
│  │  ┌─────────┬─────────┬─────────┬─────────┐                        │ │
│  │  │ Desc 0  │ Desc 1  │ Desc 2  │ Desc N  │                        │ │
│  │  │ addr,len │ addr,len│ addr,len│ addr,len│                        │ │
│  │  │ next    │ next    │ next    │ next    │                        │ │
│  │  └─────────┴─────────┴─────────┴─────────┘                        │ │
│  └─────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐ │
│  │  Available Ring (Guest 写入，Host 读取)                             │ │
│  │  flags, idx, ring[0..15], used_event                               │ │
│  └─────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐ │
│  │  Used Ring (Host 写入，Guest 读取)                                  │ │
│  │  flags, idx, ring[0..15], avail_event                             │ │
│  └─────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 4.2 Vhost DMA 集成

```c
// Vhost DMA (DPDK vhost library)

// vhost DMA channel
struct vhost_dma_info {
    int dma_id;                     // DMA 引擎 ID
    uint8_t device_id;               // vhost 设备 ID

    struct dma_channel *ch;         // 关联的 DMA 通道

    // vhost 内存映射
    struct vhost_mem_region {
        uint64_t guest_phys_addr;   // Guest 物理地址
        uint64_t host_phys_addr;    // Host 物理地址
        uint64_t size;
        void *host_user_addr;       // Host 用户空间地址
    } regions[MAX_DMA_REGION];
    uint32_t nb_regions;
};

// 注册 DMA 设备
int
vhost_dma_device_register(int dma_id, uint8_t device_id)
{
    struct vhost_dma_info *dma = &vhost_dmas[dma_id];

    dma->dma_id = dma_id;
    dma->device_id = device_id;
    dma->ch = dma_channel_get(dma_id);

    return 0;
}

// 建立 GPA (Guest Physical Address) 到 HPA (Host Physical Address) 的映射
int
vhost_dma_map_gpa(uint8_t device_id,
                   uint64_t guest_phys_addr,
                   uint64_t host_phys_addr,
                   uint64_t size)
{
    int dev_idx = find_vhost_device(device_id);
    struct vhost_dma_info *dma = &vhost_dmas[dev_idx];

    struct vhost_mem_region *region = &dma->regions[dma->nb_regions++];

    region->guest_phys_addr = guest_phys_addr;
    region->host_phys_addr = host_phys_addr;
    region->size = size;

    printf("DMA: GPA %lx -> HPA %lx (size %lx)\n",
           guest_phys_addr, host_phys_addr, size);

    return 0;
}

// 执行跨 GPA 的 DMA 拷贝
int
vhost_dma_copy(int dma_id,
                uint64_t src_gpa, uint64_t dst_gpa,
                size_t len)
{
    struct vhost_dma_info *dma = &vhost_dmas[dma_id];

    // GPA -> HPA 转换
    uint64_t src_hpa = gpa_to_hpa(dma, src_gpa);
    uint64_t dst_hpa = gpa_to_hpa(dma, dst_gpa);

    if (!src_hpa || !dst_hpa) {
        printf("DMA: GPA translation failed\n");
        return -1;
    }

    // 提交 DMA 操作
    return dma_submit(dma->ch, src_hpa, dst_hpa, len);
}

// GPA 到 HPA 查找
static uint64_t
gpa_to_hpa(struct vhost_dma_info *dma, uint64_t gpa)
{
    for (uint32_t i = 0; i < dma->nb_regions; i++) {
        struct vhost_mem_region *r = &dma->regions[i];

        if (gpa >= r->guest_phys_addr &&
            gpa < r->guest_phys_addr + r->size) {
            return r->host_phys_addr + (gpa - r->guest_phys_addr);
        }
    }

    return 0;  // 未找到
}
```

### 4.3 VDPA (vhost Data Path Acceleration)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        VDPA 架构                                           │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  VDPA: vhost Data Path Acceleration                                        │
│  ─────────────────────────────────                                          │
│  - 将 virtqueue 数据路径卸载到硬件                                          │
│  - 减少 VM exit 次数                                                        │
│  - 支持 Virtio-net 和 Virtio-blk                                           │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐ │
│  │                    VDPA Device (e.g., BlueField-2)                  │ │
│  │                                                                      │ │
│  │   ┌──────────────────────────────────────────────────────────────┐ │ │
│  │   │               Data Path Accelerator                          │ │ │
│  │   │                                                              │ │ │
│  │   │   ┌──────────┐    ┌──────────┐    ┌──────────┐              │ │ │
│  │   │   │ Virtqueue│───►│   DMA    │───►│  Packet  │              │ │ │
│  │   │   │ Parser   │    │  Engine  │    │ Process  │              │ │ │
│  │   │   └──────────┘    └──────────┘    └──────────┘              │ │ │
│  │   │        │                                              │         │ │ │
│  │   │        └──────────────────────────────────────────────┘         │ │ │
│  │   │                        Memory Table                             │ │ │
│  │   └──────────────────────────────────────────────────────────────┘ │ │
│  │                              │                                        │ │
│  └──────────────────────────────┼────────────────────────────────────────┘ │
│                                 │ PCIe                                     │
└─────────────────────────────────┼───────────────────────────────────────────┘
                                  │
                                  ▼
                    ┌─────────────────────────────┐
                    │      VM (Linux/Windows)      │
                    │                              │
                    │   Virtio Driver (生成本地    │
                    │   virtqueue 描述符)          │
                    │                              │
                    └──────────────────────────────┘

VDPA 工作流程:
1. VM 中的 Virtio driver 创建 virtqueue (GPA)
2. 驱动更新 Available Ring
3. VDPA 硬件检测到更新，直接 DMA 访问 VM 内存
4. VDPA 硬件处理数据包，更新 Used Ring
5. VM 无需 VM exit (零中断)
```

---

## 5. 零拷贝技术

### 5.1 零拷贝接收 (Zero-Copy RX)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        零拷贝接收流程                                       │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  传统 (内核 + copy):                                                       │
│  ────────────────────                                                      │
│                                                                             │
│  NIC ──► DMA ──► sk_buff (kernel) ──► copy ──► 用户 buffer               │
│                                                                             │
│  DPDK 零拷贝:                                                              │
│  ─────────────                                                             │
│                                                                             │
│  NIC ──► DMA ──► mbuf (用户空间 hugepage)                                 │
│                                                                             │
│  关键:                                                                    │
│  - NIC 直接 DMA 到用户空间内存                                             │
│  - 无需 kernel 参与                                                         │
│  - 无 CPU copy                                                             │
│                                                                             │
│  DPDK rx_mbuf 机制:                                                        │
│  ────────────────────                                                      │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐ │
│  │  rte_eth_rx_burst()                                                │ │
│  │                                                                      │ │
│  │  1. NIC 硬件描述符环: [addr, addr, addr, ...]                      │ │
│  │                        ↑                                              │ │
│  │                    mbuf 数据地址 (IOVA)                             │ │
│  │                                                                      │ │
│  │  2. NIC DMA 将包写入 mbuf                                           │ │
│  │                                                                      │ │
│  │  3. rte_eth_rx_burst 返回 mbuf 指针数组                             │ │
│  │     (应用程序直接获得数据，无拷贝)                                   │ │
│  │                                                                      │ │
│  └─────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
│  零拷贝条件:                                                               │
│  - mbuf 内存必须在 DMA 可访问范围                                           │
│  - 使用 IOVA (非虚拟地址)                                                 │
│  - NIC 驱动支持 (igb_uio / vfio-pci)                                     │
│  - IOMMU 启用时需要正确的 IOVA 映射                                        │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 5.2 零拷贝发送 (Zero-Copy TX)

```c
// DPDK 零拷贝发送

// TX mbuf 直接传输 (无拷贝)
uint16_t
zero_copy_tx(uint16_t port_id, struct rte_mbuf **mbufs, uint16_t nb)
{
    uint16_t nb_sent = rte_eth_tx_burst(port_id, 0, mbufs, nb);

    // 发送成功: mbuf 由 NIC 驱动管理，应用程序不应释放
    // 发送失败: 需要释放 mbuf

    if (nb_sent < nb) {
        // 释放未发送的 mbuf
        for (uint16_t i = nb_sent; i < nb; i++) {
            rte_pktmbuf_free(mbufs[i]);
        }
    }

    return nb_sent;
}

// mbuf 引用计数管理
static inline struct rte_mbuf *
mbuf_get_ref(struct rte_mbuf *m)
{
    // 增加引用计数
    rte_pktmbuf_refcnt_update(m, 1);
    return m;
}

static inline void
mbuf_put_ref(struct rte_mbuf *m)
{
    // 减少引用计数，为0时释放
    if (rte_pktmbuf_refcnt_update(m, -1) == 0) {
        rte_pktmbuf_free(m);
    }
}

// 零拷贝场景: 修改后重新发送
int
zero_copy_resend(uint16_t port_id, struct rte_mbuf *m)
{
    // 修改 mbuf 内容 (例如: 更新 IP 头 TTL)
    struct ipv4_hdr *iph = rte_pktmbuf_mtod(m, struct ipv4_hdr *);
    iph->time_to_live--;

    // 重新计算校验和
    iph->hdr_checksum = 0;
    iph->hdr_checksum = rte_ipv4_cksum(iph);

    // 重新发送 (同一 mbuf)
    return zero_copy_tx(port_id, &m, 1);
}
```

### 5.3 Indirect mbuf 与零拷贝

```c
// Indirect mbuf 实现零拷贝共享

// indirect mbuf 结构
struct rte_mbuf {
    // ... 主要 mbuf 字段 ...

    struct rte_mbuf *next;           // 指向下一个 segment

    // indirect mbuf 专用
    struct rte_mbuf *head;           // 指向原始 mbuf (self-referencing)
    void *buf_addr;                  // 指向原始 buffer
};

// 创建 indirect mbuf (零拷贝共享)
struct rte_mbuf *
rte_pktmbuf_attach(const struct rte_mbuf *m)
{
    struct rte_mbuf *m_new;

    // 从 pool 分配新的 mbuf (只有 meta，无数据拷贝)
    m_new = rte_pktmbuf_alloc(m->pool);

    if (!m_new)
        return NULL;

    // 设置 indirect 字段
    m_new->head = (struct rte_mbuf *)m;  // 指向原始
    m_new->buf_addr = m->buf_addr;       // 共享 buffer

    // 复制数据指针
    m_new->data_off = m->data_off;
    m_new->pkt_len = m->pkt_len;
    m_new->data_len = m->data_len;

    // 增加原始 mbuf 引用计数
    rte_pktmbuf_refcnt_update((struct rte_mbuf *)m, 1);

    return m_new;
}

// 附加原始数据到 indirect mbuf
static inline int
pktmbuf_attach(struct rte_mbuf *m, const struct rte_mbuf *m_old)
{
    if (rte_pktmbuf_refcnt_update(m_old, 1) == 0)
        return -ENOBUFS;

    m->head = m_old;
    m->buf_addr = rte_pktmbuf_mtod(m_old, void *);
    m->data_off = m_old->data_off;
    m->pkt_len = m_old->pkt_len;
    m->data_len = m_old->data_len;

    return 0;
}

// Indirect mbuf 生命周期
void
indirect_mbuf_demo(void)
{
    // 原始 mbuf
    struct rte_mbuf *original = rte_pktmbuf_alloc(mbuf_pool);
    // ... 填充数据 ...

    // 创建 indirect mbuf (零拷贝)
    struct rte_mbuf *clone = rte_pktmbuf_attach(original);

    // 两个 mbuf 共享同一个 buffer
    // 修改 clone 的数据会影响 original

    // 使用完毕后释放
    rte_pktmbuf_free(clone);    // 释放 clone (引用计数 -1)
    rte_pktmbuf_free(original); // 原始 buffer 被实际释放
}

// detach 操作
static inline void
pktmbuf_detach(struct rte_mbuf *m)
{
    struct rte_mbuf *m_old = m->head;

    // 减少原始 mbuf 引用计数
    if (rte_pktmbuf_refcnt_update(m_old, -1) == 0) {
        // 原始 mbuf 已被释放
        // 可能需要释放原始 buffer
    }

    m->head = m;
}
```

### 5.4 零拷贝场景示例

```c
// 场景 1: Packet 复制 (copy on write)

struct rte_mbuf *
cow_copy(const struct rte_mbuf *m)
{
    struct rte_mbuf *new_m = rte_pktmbuf_alloc(m->pool);

    if (!new_m)
        return NULL;

    // 如果原始 mbuf 只被引用一次，直接共享
    if (rte_pktmbuf_refcnt_read(m) == 1) {
        // 无需拷贝，返回原始 mbuf
        rte_pktmbuf_free(new_m);
        return rte_pktmbuf_clone(m);  // 克隆 (引用计数 +1)
    }

    // 引用计数 > 1，需要真正拷贝
    void *src = rte_pktmbuf_mtod(m, void *);
    void *dst = rte_pktmbuf_mtod(new_m, void *);

    size_t len = rte_pktmbuf_pkt_len(m);

    // DMA 拷贝 (零拷贝 API)
    dma_copy(rte_pktmbuf_mtophys(new_m),
             rte_pktmbuf_mtophys(m),
             len);

    new_m->pkt_len = len;
    new_m->data_len = len;

    return new_m;
}

// 场景 2: VLAN 剥离/添加 (zero-copy header manipulation)

struct rte_mbuf *
strip_vlan_tag(const struct rte_mbuf *m)
{
    // 创建一个 indirect mbuf，跳过 VLAN tag
    struct rte_mbuf *clone = rte_pktmbuf_attach(m);

    if (!clone)
        return NULL;

    // 调整数据指针和长度
    // 假设 VLAN tag 在 Ethernet header 中
    clone->data_off = m->data_off + 4;  // 跳过 4 字节 VLAN
    clone->pkt_len -= 4;
    clone->data_len -= 4;

    return clone;
}

struct rte_mbuf *
add_vlan_tag(const struct rte_mbuf *m, uint16_t vlan_id)
{
    struct rte_mbuf *clone = rte_pktmbuf_alloc(m->pool);

    if (!clone)
        return NULL;

    // 在 headroom 中插入 VLAN tag
    void *headroom = rte_pktmbuf_prepend(clone, 4);
    if (!headroom) {
        rte_pktmbuf_free(clone);
        return NULL;
    }

    // 拷贝 Ethernet header
    struct ether_hdr *eth = rte_pktmbuf_mtod(m, struct ether_hdr *);
    memcpy(headroom, eth, 14);

    // 修改 VLAN tag
    struct vlan_hdr *vh = (struct vlan_hdr *)((char *)headroom + 14);
    vh->vlan_tci = rte_cpu_to_be_16(vlan_id);

    // 拷贝其余数据
    void *payload = rte_pktmbuf_mtod(m, void *) + 14;
    size_t payload_len = rte_pktmbuf_pkt_len(m) - 14;
    memcpy((char *)headroom + 18, payload, payload_len);

    clone->pkt_len = m->pkt_len + 4;
    clone->data_len = m->data_len + 4;

    return clone;
}

// 场景 3: IP 分片 (zero-copy fragmentation)

struct rte_mbuf **
zero_copy_fragment(struct rte_mbuf *m, uint16_t mtu)
{
    struct rte_mbuf **fragments;
    uint16_t num_frags;
    uint16_t offset = 0;
    uint16_t remaining;

    if (rte_pktmbuf_pkt_len(m) <= mtu) {
        // 无需分片
        fragments = malloc(sizeof(*fragments));
        fragments[0] = m;
        return fragments;
    }

    // 计算分片数
    remaining = rte_pktmbuf_pkt_len(m);
    num_frags = (remaining + mtu - 1) / mtu;

    fragments = malloc(num_frags * sizeof(*fragments));

    for (uint16_t i = 0; i < num_frags; i++) {
        uint16_t frag_size = RTE_MIN(mtu, remaining);

        // 创建 indirect mbuf 指向原始数据的各个部分
        fragments[i] = rte_pktmbuf_alloc(m->pool);

        // 设置 indirect mbuf 的数据区域
        fragments[i]->head = m;  // 指向原始
        fragments[i]->buf_addr = (char *)m->buf_addr + m->data_off + offset;
        fragments[i]->data_off = 0;
        fragments[i]->pkt_len = frag_size;
        fragments[i]->data_len = frag_size;

        // 增加原始 mbuf 引用计数
        rte_pktmbuf_refcnt_update(m, 1);

        offset += frag_size;
        remaining -= frag_size;
    }

    return fragments;
}
```

---

## 6. 内存原语与 DMA 操作

### 6.1 DPDK 内存原语

```c
// lib/eal/include/rte_memory.h

// 内存屏障
#define rte_mb()    asm volatile("mfence" ::: "memory")
#define rte_wmb()   asm volatile("sfence" ::: "memory")
#define rte_rmb()   asm volatile("lfence" ::: "memory")

// 内存预取 (已在 Ch25 讨论)
#define rte_prefetch0(addr)   asm volatile("prefetcht0 %0" : : "m" (*(const void *)(addr)))

// 原子操作
#define rte_atomic_xchg(addr, val) \
    __atomic_exchange_n(addr, val, __ATOMIC_ACQ_REL)

#define rte_atomic_add(addr, val) \
    __atomic_add_fetch(addr, val, __ATOMIC_ACQ_REL)

// DMA 友好的内存比较交换
static inline int
rte_atomic32_cmpset(volatile uint32_t *dst, uint32_t exp, uint32_t val)
{
    return __atomic_compare_exchange_n(dst, &exp, val, 0,
                                        __ATOMIC_ACQ_REL,
                                        __ATOMIC_RELAXED);
}

// 字节序操作
static inline uint16_t
rte_bswap16(uint16_t x)
{
    return ((x & 0x00ff) << 8) | ((x & 0xff00) >> 8);
}

static inline uint32_t
rte_bswap32(uint32_t x)
{
    return __builtin_bswap32(x);
}

static inline uint64_t
rte_bswap64(uint64_t x)
{
    return __builtin_bswap64(x);
}
```

### 6.2 DMA 拷贝操作

```c
// DMA 拷贝封装

// 同步 DMA 拷贝 (阻塞直到完成)
int
dma_memcpy_sync(dma_addr_t dst, dma_addr_t src, size_t len)
{
    struct dma_channel *ch = get_dma_channel(0);

    // 提交 DMA 请求
    dma_submit(ch, src, dst, len);

    // 等待完成
    dma_wait_completion(ch);

    return 0;
}

// 异步 DMA 拷贝 (非阻塞)
struct dma_job {
    dma_addr_t dst;
    dma_addr_t src;
    size_t len;
    volatile int status;  // 0=pending, 1=complete, -1=error
};

struct dma_job *
dma_memcpy_async(dma_addr_t dst, dma_addr_t src, size_t len)
{
    static struct dma_job jobs[256];
    static int job_idx = 0;

    struct dma_job *job = &jobs[job_idx++ & 255];

    job->dst = dst;
    job->src = src;
    job->len = len;
    job->status = 0;

    struct dma_channel *ch = get_dma_channel(job_idx & 3);

    dma_submit(ch, src, dst, len);

    // 记录 job 以便后续查询
    return job;
}

// 轮询完成状态
int
dma_memcpy_poll(struct dma_job *job)
{
    if (job->status == 0) {
        // 检查完成队列
        // ...
    }
    return job->status;
}

// DPDK 提供的 DMA memcpy (使用 I/OAT)
int
rte_ioat_memcpy(uint16_t ioat_id,
                 dma_addr_t dst, dma_addr_t src, size_t len)
{
    struct rte_ioat_xor *ioat = &rte_ioat[ioat_id];

    // 添加描述符
    rte_ioat_xor_submit(ioat, src, dst, len, 0);

    // 强制提交
    rte_ioat_do_xor(ioat_id);

    return 0;
}
```

### 6.3 高性能内存操作

```c
// 高性能内存操作技巧

// 1. 非对齐访问优化
void
unaligned_copy_opt(void *dst, const void *src, size_t len)
{
    uint64_t *d64 = (uint64_t *)dst;
    const uint64_t *s64 = (const uint64_t *)src;

    // 头部非对齐字节
    size_t head = (uintptr_t)dst & 7;
    if (head) {
        char *d = (char *)dst;
        const char *s = (const char *)src;

        for (size_t i = 0; i < head && i < len; i++)
            d[i] = s[i];

        d64 = (uint64_t *)((char *)dst + head);
        s64 = (uint64_t *)((const char *)src + head);
        len -= head;
    }

    // 主体 8 字节拷贝
    size_t body = len & ~7;
    for (size_t i = 0; i < body; i += 8)
        *d64++ = *s64++;

    // 尾部字节
    if (len & 7) {
        const char *s = (const char *)s64;
        char *d = (char *)d64;

        for (size_t i = 0; i < (len & 7); i++)
            d[i] = s[i];
    }
}

// 2. 批量内存预取
void
bulk_prefetch(const void **ptrs, int count)
{
    for (int i = 0; i < count; i++) {
        if (i + 8 < count)
            rte_prefetch0(ptrs[i + 8]);
        // 处理当前
        process(ptrs[i]);
    }
}

// 3. Cache 行对齐拷贝
void
cache_line_copy(void *dst, const void *src, size_t len)
{
    uint64_t *d64 = RTE_PTR_ALIGN_CEIL(dst, 8);
    uint64_t *s64 = RTE_PTR_ALIGN_FLOOR(src, 8);

    // 头部对齐
    size_t head = (uintptr_t)d64 - (uintptr_t)dst;
    if (head) {
        memcpy(dst, src, head);
        d64 = (uint64_t *)((char *)dst + head);
        s64 = (uint64_t *)((char *)src + head);
        len -= head;
    }

    // Cache line (64B) 批量拷贝
    for (size_t i = 0; i < len; i += 64) {
        _mm_store_si128((__m128i *)d64,
                        _mm_load_si128((const __m128i *)s64));
        d64 += 8;
        s64 += 8;
    }

    // 尾部
    size_t tail = len & 63;
    if (tail)
        memcpy(d64, s64, tail);
}

// 4. DMA 友好的批量处理
int
dma_bulk_process(dma_addr_t *dsts, dma_addr_t *srcs, size_t *lens, int count)
{
    struct dma_channel *ch = get_primary_dma_channel();

    for (int i = 0; i < count; i++) {
        // 预提交
        if (i + 1 < count)
            dma_prefetch(ch, srcs[i + 1], dsts[i + 1], lens[i + 1]);

        // 提交当前
        dma_submit(ch, srcs[i], dsts[i], lens[i]);
    }

    // 等待全部完成
    dma_wait_all(ch);

    return count;
}
```

---

## 7. 完整使用示例

### 7.1 DMA + mbuf 零拷贝流水线

```c
// DMA 加速的包处理流水线

#define MAX_DMA_CHANNELS 8
#define DMA_BURST_SIZE 32

struct dma_pipeline {
    // DMA 通道
    struct dma_channel *dma_ch[MAX_DMA_CHANNELS];
    int num_channels;

    // 描述符环
    struct dma_desc *desc_rings[MAX_DMA_CHANNELS];
    dma_addr_t desc_ring_phys[MAX_DMA_CHANNELS];

    // 预分配的 mbuf 用于 DMA 传输
    struct rte_mempool *dma_mbuf_pool;

    // 工作线程
    unsigned lcore_id;
};

struct dma_pipeline *
dma_pipeline_create(int num_channels)
{
    struct dma_pipeline *p = rte_malloc(NULL, sizeof(*p), 0);

    p->num_channels = num_channels;
    p->lcore_id = rte_lcore_id();

    // 分配 DMA 通道
    for (int i = 0; i < num_channels; i++) {
        p->dma_ch[i] = dma_channel_open(i);
        p->desc_rings[i] = rte_malloc(NULL,
                                       DMA_DESC_COUNT * sizeof(struct dma_desc),
                                       RTE_CACHE_LINE_SIZE);
        p->desc_ring_phys[i] = rte_mem_virt2iova(p->desc_rings[i]);
    }

    // 创建 DMA 友好的 mbuf pool
    char pool_name[64];
    snprintf(pool_name, sizeof(pool_name), "dma_pool_lcore%u", p->lcore_id);

    p->dma_mbuf_pool = rte_pktmbuf_pool_create(
        pool_name,
        16384,
        256,
        0,
        2048,
        rte_lcore_to_socket_id(p->lcore_id)
    );

    return p;
}

// DMA 辅助的包处理
int
dma_assisted_copy(struct dma_pipeline *p,
                   struct rte_mbuf *src, struct rte_mbuf *dst)
{
    int ch_id = p->lcore_id % p->num_channels;
    struct dma_channel *ch = p->dma_ch[ch_id];

    // 获取物理地址
    dma_addr_t src_phys = rte_pktmbuf_mtophys(src);
    dma_addr_t dst_phys = rte_pktmbuf_mtophys(dst);

    size_t len = rte_pktmbuf_pkt_len(src);

    // 验证 DMA 可访问性
    if (!is_iova_valid(src_phys, len) || !is_iova_valid(dst_phys, len)) {
        // 回退到 CPU 拷贝
        void *src_v = rte_pktmbuf_mtod(src, void *);
        void *dst_v = rte_pktmbuf_mtod(dst, void *);
        rte_memcpy(dst_v, src_v, len);
        return 0;
    }

    // 提交 DMA
    dma_submit(ch, src_phys, dst_phys, len);

    // 等待完成
    while (!(ch->desc_ring[ch->head].control & DMA_DESC_DONE)) {
        // spin or yield
        rte_pause();
    }

    // 更新 mbuf 元数据
    dst->pkt_len = len;
    dst->data_len = len;

    return 0;
}

// DMA 批量处理
int
dma_batch_copy(struct dma_pipeline *p,
                struct rte_mbuf **srcs, struct rte_mbuf **dsts,
                int nb)
{
    int ch_id = p->lcore_id % p->num_channels;
    struct dma_channel *ch = p->dma_ch[ch_id];

    // 批量提交
    for (int i = 0; i < nb; i++) {
        dma_addr_t src_phys = rte_pktmbuf_mtophys(srcs[i]);
        dma_addr_t dst_phys = rte_pktmbuf_mtophys(dsts[i]);
        size_t len = rte_pktmbuf_pkt_len(srcs[i]);

        dma_submit(ch, src_phys, dst_phys, len);
    }

    // 批量等待
    int completed = 0;
    int timeout = 1000;

    while (completed < nb && timeout-- > 0) {
        for (int i = 0; i < nb; i++) {
            uint16_t idx = (ch->head + completed) & (ch->desc_ring_size - 1);

            if (ch->desc_ring[idx].control & DMA_DESC_DONE) {
                // 更新 mbuf
                dsts[completed]->pkt_len = rte_pktmbuf_pkt_len(srcs[completed]);
                dsts[completed]->data_len = dsts[completed]->pkt_len;
                completed++;
            }
        }
    }

    return completed;
}

// 主处理循环
static int
dma_processing_loop(void *arg)
{
    struct dma_pipeline *p = arg;
    struct rte_mbuf *rx_mbufs[32];
    struct rte_mbuf *tx_mbufs[32];

    printf("DMA pipeline on lcore %u\n", p->lcore_id);

    while (!quit) {
        // 接收
        uint16_t nb_rx = rte_eth_rx_burst(0, 0, rx_mbufs, 32);

        if (nb_rx == 0)
            continue;

        // 处理: TTL 更新等 (CPU 操作)
        for (int i = 0; i < nb_rx; i++) {
            update_ttl(rx_mbufs[i]);
        }

        // DMA 拷贝到 TX buffer
        for (int i = 0; i < nb_rx; i++) {
            struct rte_mbuf *tx = rte_pktmbuf_alloc(p->dma_mbuf_pool);
            dma_assisted_copy(p, rx_mbufs[i], tx);
            rte_pktmbuf_free(rx_mbufs[i]);  // 释放 RX mbuf
            tx_mbufs[i] = tx;
        }

        // 发送
        uint16_t nb_tx = rte_eth_tx_burst(0, 0, tx_mbufs, nb_rx);

        // 释放未发送的
        for (uint16_t i = nb_tx; i < nb_rx; i++) {
            rte_pktmbuf_free(tx_mbufs[i]);
        }
    }

    return 0;
}
```

### 7.2 Vhost DMA 应用

```c
// Vhost DMA 用于 VM 内存访问加速

struct vhost_dma_session {
    int dma_id;
    uint8_t device_id;

    // GPA -> HPA 映射
    struct gpa_to_hpa {
        uint64_t gpa;
        uint64_t hpa;
        size_t size;
    } mappings[64];
    uint32_t nb_mappings;

    // DMA 通道
    struct dma_channel *ch;
};

struct vhost_dma_session *
vhost_dma_session_create(int dma_id, uint8_t device_id)
{
    struct vhost_dma_session *s = rte_malloc(NULL, sizeof(*s), 0);

    s->dma_id = dma_id;
    s->device_id = device_id;
    s->ch = dma_channel_open(dma_id);
    s->nb_mappings = 0;

    printf("Created vhost DMA session: dma_id=%d, device_id=%d\n",
           dma_id, device_id);

    return s;
}

// 添加内存映射
int
vhost_dma_session_add_mapping(struct vhost_dma_session *s,
                                uint64_t gpa, uint64_t hpa, size_t size)
{
    if (s->nb_mappings >= 64) {
        printf("Too many mappings\n");
        return -1;
    }

    s->mappings[s->nb_mappings].gpa = gpa;
    s->mappings[s->nb_mappings].hpa = hpa;
    s->mappings[s->nb_mappings].size = size;
    s->nb_mappings++;

    printf("Added mapping: GPA %lx -> HPA %lx (size %zx)\n",
           gpa, hpa, size);

    return 0;
}

// 执行 VM 内存 DMA 访问
int
vhost_dma_vm_copy(struct vhost_dma_session *s,
                   uint64_t gpa_src, uint64_t gpa_dst,
                   size_t len)
{
    // 查找映射
    uint64_t hpa_src = gpa_resolve(s, gpa_src);
    uint64_t hpa_dst = gpa_resolve(s, gpa_dst);

    if (!hpa_src || !hpa_dst) {
        printf("Failed to resolve GPA\n");
        return -1;
    }

    // 执行 DMA
    return dma_submit(s->ch, hpa_src, hpa_dst, len);
}

// 解析 GPA 到 HPA
static uint64_t
gpa_resolve(struct vhost_dma_session *s, uint64_t gpa)
{
    for (uint32_t i = 0; i < s->nb_mappings; i++) {
        if (gpa >= s->mappings[i].gpa &&
            gpa < s->mappings[i].gpa + s->mappings[i].size) {
            return s->mappings[i].hpa + (gpa - s->mappings[i].gpa);
        }
    }
    return 0;
}

// Virtio-net VM 数据路径加速
int
vhost_net_accelerate(struct vhost_dma_session *s,
                      struct virtio_net_hdr *hdr,
                      uint64_t gpa_buf, size_t buf_len)
{
    // 1. 准备 Virtio-net header
    struct virtio_net_hdr local_hdr;
    memcpy(&local_hdr, hdr, sizeof(local_hdr));

    // 2. DMA header 到 VM
    uint64_t hdr_gpa = gpa_buf - sizeof(local_hdr);
    uint64_t hdr_hpa = gpa_resolve(s, hdr_gpa);

    dma_submit(s->ch, rte_mem_virt2iova(&local_hdr), hdr_hpa, sizeof(local_hdr));

    // 3. DMA 数据 buffer (已在正确位置，由 VM 提供)

    // 4. 更新 virtqueue (Used Ring)
    // ...

    return 0;
}
```

---

## 8. 性能与调优

### 8.1 DMA 性能指标

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        DMA 性能调优参数                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  关键参数:                                                                 │
│  ────────                                                                  │
│                                                                             │
│  1. 描述符环大小                                                           │
│     - 影响: 并行度、内存占用                                               │
│     - 建议: 128-1024 (power of 2)                                          │
│                                                                             │
│  2. DMA burst 大小                                                         │
│     - 影响: 每次提交批量大小                                                │
│     - 建议: 32-64 描述符/batch                                              │
│                                                                             │
│  3. 完成轮询间隔                                                           │
│     - 影响: 延迟 vs CPU 利用率                                             │
│     - 建议: 使用中断或自适应轮询                                            │
│                                                                             │
│  性能数据 (Intel I/OAT, DMA 拷贝):                                         │
│  ───────────────────────────────────────────                               │
│                                                                             │
│  传输大小      吞吐量        延迟        CPU 占用                          │
│  ──────────────────────────────────────────────────────────────────────── │
│  64B           8 GB/s       50 ns        < 5%                             │
│  256B          15 GB/s      60 ns        < 3%                             │
│  1KB           25 GB/s      80 ns        < 2%                             │
│  4KB           35 GB/s      200 ns       < 1%                             │
│  64KB          50 GB/s      2 us          < 1%                             │
│  1MB           55 GB/s      20 us         < 1%                             │
│                                                                             │
│  IOVA 模式对比:                                                            │
│  ────────────                                                              │
│                                                                             │
│  模式              DMA 吞吐        CPU 占用      安全性                   │
│  ──────────────────────────────────────────────────────────────────────── │
│  PA (无 IOMMU)      100%           100%          低                       │
│  VA (IOMMU)         95%            105%          高                        │
│                                                                             │
│  (VA 模式稍有开销，但提供内存保护和地址虚拟化)                              │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 8.2 常见问题与解决

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        DMA 常见问题与解决                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  问题 1: DMA 地址不连续                                                    │
│  ─────────────────────────                                                  │
│  原因: mbuf 分散在多个 segment                                              │
│  解决: 使用 indirect mbuf 或 SG-DMA                                        │
│                                                                             │
│  问题 2: IOVA 超出设备 DMA 掩码                                             │
│  ────────────────────────────────                                           │
│  原因: 32-bit 设备无法访问 4GB 以上内存                                     │
│  解决: 使用 DMA contiguous memory allocator                                │
│                                                                             │
│  问题 3: 跨 NUMA DMA                                                       │
│  ─────────────────────                                                      │
│  原因: DMA 访问远程 socket 内存                                            │
│  解决: 使用本地 socket 内存 pool                                            │
│                                                                             │
│  问题 4: Cache 一致性                                                       │
│  ────────────────                                                           │
│  原因: DMA 和 CPU 同时 访问同一 cache line                                  │
│  解决: 使用 non-temporal stores (_mm_stream_si128)                        │
│                                                                             │
│  问题 5: DMA 完成延迟                                                      │
│  ──────────────────                                                         │
│  原因: 轮询太频繁或中断太慢                                                 │
│  解决: 自适应轮询、中毒扩散 (optimistic spinning)                          │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 9. 小结

本章核心要点：

1. **传统 I/O 路径**：4 次拷贝 (NIC DMA → sk_buff → 用户 buffer → TX DMA)，CPU 参与每个包的拷贝。

2. **零拷贝目标**：消除 CPU 拷贝，让 DMA 引擎执行数据移动，CPU 只参与控制面。

3. **DMA 引擎架构**：描述符环、通道、Scatter-Gather，支持独立于 CPU 的内存拷贝。

4. **IOVA (I/O Virtual Address)**：用于 DMA 的虚拟地址，IOMMU 将 IOVA 映射到物理地址，支持地址空间虚拟化和安全隔离。

5. **DPDK IOVA 模式**：`RTE_IOVA_PA` (物理地址，无 IOMMU) 和 `RTE_IOVA_VA` (虚拟地址，IOMMU 启用)。

6. **Virtio/Vhost DMA**：vhost 在 Host 空间直接访问 VM 内存 (GPA)，通过内存映射转换为 HPA。

7. **VDPA (vhost Data Path Acceleration)**：将 virtqueue 处理卸载到硬件，减少 VM exit 次数。

8. **零拷贝接收**：DPDK mbuf 直接映射用户空间内存，NIC DMA 直接写入，零拷贝。

9. **零拷贝发送**：`rte_eth_tx_burst()` 直接传输 mbuf，应用程序无需拷贝。

10. **Indirect mbuf**：零拷贝共享原始数据，通过引用计数管理生命周期。

11. **零拷贝场景**：Packet 复制 (copy-on-write)、VLAN 操作、IP 分片。

12. **DMA 友好设计**：IOVA 连续性检查、mbuf segment 合并、跨 NUMA 避免。

**下一篇预告**：[[2026-04-09-dpdk-deep-dive-ch28-multicore-sync|第二十八章]]将讲解多核同步——Spinlock、RCU、Memory Reorder。

---

> [!tip] 参考文献
> - Intel, "Intel I/O Acceleration Technology", https://www.intel.com/content/www/us/en/architecture-and-technology/io-acceleration.html
> - "DMA Engine in Linux Kernel", https://www.kernel.org/doc/html/latest/driver-api/dmaengine/
> - "Virtio Spec", https://docs.oasis-open.org/virtio/virtio/v1.1/virtio-v1.1.pdf
> - "vHost/Virtio DMA Backend", https://www.kernel.org/doc/html/latest/virt/vhost/vhost.html
> - Intel, "DPDK DMA Documentation", https://doc.dpdk.org/guides/prog_guide/dma.html
> - "Zero-copy networking", https://lwn.net/Articles/21944/
