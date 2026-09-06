---
title: "DPDK 深度探索 (二十七)：内存优化——DMA 引擎与零拷贝"
date: 2026-04-09
tags:
  [dpdk, series, dma, zero-copy, iova, virtio, vhost, memory, mbuf, direct-memory, indirect-mbuf]
description: "深入理解 DPDK 内存优化——DMA 引擎架构、零拷贝技术、IOVA 寻址、Virtio/Vhost DMA、mbuf DMA 映射、内存原语"
---

> [!info] DPDK 深度探索系列 0. [[dpdk-deep-dive|全栈学习路径总览]]
> 1-26. 前二十六章已完成 27. **第二十七章：内存优化——DMA 引擎与零拷贝**
> 延伸阅读：[[ch27a-vdpa-dsa-host-guest-accel|第二十七章补充：vDPA、DSA 与 Host/Guest 数据面卸载]]

---

## 1. 概述：为什么需要 DMA 和零拷贝

先纠正一个容易混淆的点：**DPDK 网络收发里的零拷贝，通常不是指“用 DMA 引擎替代
CPU memcpy”**。更准确地说：

```text
DPDK RX 零拷贝:
  NIC 直接 DMA 到应用预先放进 RX ring 的 mbuf data buffer
  应用拿到的是 mbuf 指针，不再从 kernel sk_buff 拷到用户 buffer

DPDK TX 零拷贝:
  应用把 mbuf 挂到 TX ring
  NIC 从 mbuf data buffer DMA 读出并发到 wire
  应用不再把 packet 内容拷到 kernel socket buffer

DMA copy engine:
  另一个硬件引擎，适合大块内存复制、vhost async copy、压缩/加密前后的搬运等
  它能释放 CPU，但它本身仍然是在“拷贝数据”
```

所以本章要分清两条线：

```text
零拷贝:
  目标是少搬数据，最好只传递 buffer ownership / descriptor

DMA copy offload:
  目标是必须搬数据时，让专门的 DMA engine 搬，CPU 只提交描述符和收 completion
```

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

### 1.3 DMA copy engine 不一定总比 CPU memcpy 快

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        DMA copy engine vs CPU memcpy                         │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  结论先行:                                                                 │
│  ─────────                                                                 │
│                                                                             │
│  小包 / 小块内存:                                                          │
│    CPU memcpy 往往更快，原因是提交 DMA 描述符、doorbell、completion         │
│    轮询都有固定开销。                                                       │
│                                                                             │
│  大块 / 批量内存:                                                          │
│    DMA copy engine 更有价值，尤其是可以异步提交、批量完成、释放 CPU。       │
│                                                                             │
│  DPDK 转发普通 packet:                                                     │
│    最优路径通常不是 RX mbuf -> DMA copy -> TX mbuf，                       │
│    而是直接转发同一个 mbuf，或者只改 header/metadata 后发送。               │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

工程上可以按这个顺序选：

| 场景                     | 优先方案                  | 原因                       |
| ------------------------ | ------------------------- | -------------------------- |
| L2/L3 转发               | 复用同一个 mbuf           | 真零拷贝，只转移 ownership |
| 少量 header 修改         | CPU 直接改 cache line     | 避免 DMA 提交/完成开销     |
| packet clone / multicast | indirect mbuf 或 refcnt   | 共享 payload，不复制数据   |
| 大块 buffer 复制         | dmadev / DSA / DMA engine | 异步批量搬运，释放 CPU     |
| vhost async copy         | dmadev + vhost async path | Host/Guest 内存搬运可卸载  |

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

### 3.1 VA、PA、IOVA 的关系

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
│  - 没有 IOMMU 地址转换时，DMA 设备通常使用物理地址                          │
│  - 内核可以直接使用                                                        │
│                                                                             │
│  IOVA:                                                                    │
│  ────                                                                    │
│  - I/O 设备在 DMA 描述符里看到的地址                                        │
│  - 可能等于物理地址，也可能是 IOMMU 管理的 I/O 虚拟地址                     │
│  - DPDK API 统一把它称为 rte_iova_t                                        │
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

IOVA 不是“总是由 IOMMU 翻译的地址”。它是设备侧用来 DMA 的地址抽象：

```text
IOVA as PA:
  IOVA 数值就是实际物理地址
  设备 DMA 描述符里写物理地址
  常见于 no-IOMMU、UIO、或某些 IOMMU passthrough 场景

IOVA as VA:
  IOVA 数值按进程虚拟地址布局分配
  EAL/VFIO 通过 IOMMU 建立 IOVA -> PA 映射
  设备 DMA 描述符里写 IOVA，IOMMU 负责翻译和权限检查
```

这个区别很关键。应用代码不应该假设“DMA 地址就是物理地址”：

```text
CPU 访问 packet:
  使用 rte_pktmbuf_mtod() 得到 VA

NIC / DMA engine 访问 packet:
  使用 rte_mbuf_data_iova() / rte_pktmbuf_iova() 得到 IOVA
```

### 3.2 IOVA 模式配置

```c
// DPDK IOVA 模式

enum rte_iova_mode {
    RTE_IOVA_DC = 0,    // Don't Care (自动选择)
    RTE_IOVA_PA = 1,    // IOVA 数值使用物理地址
    RTE_IOVA_VA = 2,    // IOVA 数值使用虚拟地址布局，通常依赖 IOMMU 映射
};

// 查询当前 IOVA 模式
enum rte_iova_mode
rte_eal_iova_mode(void)
{
    return rte_eal_get_configuration()->iova_mode;
}

// EAL 参数: --iova-mode
/*
  --iova-mode pa: 强制使用 IOVA-as-PA
  --iova-mode va: 强制使用 IOVA-as-VA

  注意：
  - PA 模式不是“绝对没有 IOMMU”，但它要求 DPDK 能拿到真实物理地址。
  - VA 模式通常需要 VFIO/IOMMU，把用户态 hugepage 映射进设备 DMA 地址空间。
  - 具体能否使用取决于驱动、内核配置、IOMMU、安全策略和设备能力。
*/

// 检查是否使用 IOVA VA 模式
int
using_iova_va_mode(void)
{
    return rte_eal_iova_mode() == RTE_IOVA_VA;
}

// 普通 DPDK 内存：VA -> IOVA
rte_iova_t iova = rte_mem_virt2iova(ptr);

// mbuf 数据区：packet 起始位置的 IOVA
rte_iova_t pkt_iova = rte_pktmbuf_iova(m);

// mbuf data buffer 起始位置的 IOVA
rte_iova_t data_iova = rte_mbuf_data_iova(m);

if (iova == RTE_BAD_IOVA) {
    // 这块内存不能直接交给设备 DMA
}
```

### 3.3 IOVA 与 mbuf

```c
// mbuf 中和 DMA 相关的字段，示意，不是完整结构体

struct rte_mbuf {
    void       *buf_addr;  // CPU 访问 buffer 的虚拟地址
    rte_iova_t  buf_iova;  // 设备 DMA 访问 buffer 的 IOVA
    uint16_t    data_off;  // packet data 相对 buf_addr / buf_iova 的偏移

    uint16_t    data_len;
    uint32_t    pkt_len;
    uint16_t    nb_segs;
    struct rte_mbuf *next;
} __rte_cache_aligned;

// CPU 地址：给应用读写 packet 内容
void *data_va = rte_pktmbuf_mtod(m, void *);

// I/O 地址：给 NIC 或 DMA engine 写入描述符
rte_iova_t data_iova = rte_pktmbuf_iova(m);
```

`rte_mem_virt2iova(rte_pktmbuf_mtod(...))` 在概念上能说明 VA -> IOVA，但真实 PMD
更常用 mbuf 自带的 IOVA 字段，因为 mempool 创建时已经初始化好 `buf_iova`。这样
收发包热路径不用每次查 memseg。

```c
// DMA 友好的 mbuf 使用方式

struct rte_mbuf *m = rte_pktmbuf_alloc(mp);
if (m == NULL)
    return -ENOMEM;

char *data = rte_pktmbuf_append(m, len);
if (data == NULL) {
    rte_pktmbuf_free(m);
    return -ENOSPC;
}

// CPU 写 packet 内容
fill_packet(data, len);

// PMD 在填 TX descriptor 时使用 IOVA
rte_iova_t iova = rte_pktmbuf_iova(m);
if (iova == RTE_BAD_IOVA) {
    rte_pktmbuf_free(m);
    return -EIO;
}
```

这里容易误解成“mempool 初始化时返回了一整段连续 IOVA”。更准确地说：

```text
rte_pktmbuf_pool_create()
  -> 从 DPDK hugepage/memseg 内存里创建 mempool
  -> 把 mempool 切成很多 mbuf object
  -> 每个 mbuf object 后面带一个 data buffer
  -> mbuf 初始化时记录这个 data buffer 起点的 buf_iova

rte_pktmbuf_init()
  -> 作为 mempool object init callback 被调用
  -> 设置 m->buf_addr
  -> 设置 m->buf_iova = rte_mempool_virt2iova(m) + mbuf_size

rte_pktmbuf_iova(m)
  -> 返回 m->buf_iova + m->data_off
  -> 也就是当前 packet data 起点的设备侧地址
```

所以 PMD 填 TX/RX descriptor 时通常不需要临时做 VA -> IOVA 查询，而是直接使用 mbuf
里预先记录好的 IOVA。

但是，**整个 mempool 不保证是一整段连续 IOVA**：

```text
可能连续:
  某个 memseg / hugepage 内部通常连续
  使用 1GiB hugepage 时更容易得到大块连续 IOVA

不保证连续:
  mempool 可能跨多个 memseg
  多个 hugepage 之间的 PA/IOVA 不一定相邻
  IOVA-as-VA 模式下数值可能按 VA 布局连续，但底层 PA 仍由 IOMMU 映射
```

设备真正能用这些 IOVA，是因为 EAL/VFIO 在更早阶段已经把 DPDK hugepage 内存注册到
设备的 DMA 地址空间：

```text
EAL 初始化 hugepage
  -> 建立 memseg list
  -> VFIO/IOMMU map: IOVA -> PA
  -> mempool object 初始化: 保存每个 buffer 的 IOVA
  -> PMD 把 mbuf IOVA 写入 NIC descriptor
  -> NIC DMA 访问 IOVA，IOMMU 翻译到 PA
```

这里不是 DMA 设备“返回一个起始地址”。更准确的主语是 EAL/VFIO：

```text
IOVA-as-PA:
  memseg 的 IOVA 起点通常就是这段 hugepage 的物理地址起点

IOVA-as-VA:
  EAL 选择/使用一段 IOVA 地址范围
  VFIO 把这段 IOVA range 映射到进程里的 hugepage 内存

共同点:
  memseg 记录 base VA、base IOVA、len
  object/mbuf 的 IOVA = memseg base IOVA + (object VA - memseg base VA) + data buffer offset
```

DMA 设备本身通常只在 TX/RX descriptor 里看到最终的 IOVA 地址。它不会参与
`rte_pktmbuf_pool_create()` 里每个 mbuf 的 `buf_iova` 初始化。

那 IOVA 到底从哪里来？答案是：**DPDK 按当前 IOVA 模式自己决定这个数值，然后让
VFIO/IOMMU 接受这个映射**。

```text
VFIO_IOMMU_MAP_DMA 不是“请内核分配一个 IOVA”
而是“请内核把我给你的 iova 映射到这段 user vaddr”
```

概念上类似：

```c
struct vfio_iommu_type1_dma_map map = {
    .vaddr = user_va,
    .iova  = dpdk_chosen_iova,
    .size  = len,
    .flags = VFIO_DMA_MAP_FLAG_READ | VFIO_DMA_MAP_FLAG_WRITE,
};

ioctl(vfio_container_fd, VFIO_IOMMU_MAP_DMA, &map);
```

`dpdk_chosen_iova` 的来源取决于模式：

```text
IOVA-as-PA:
  DPDK 找到 hugepage 对应的物理地址 PA
  memseg->iova = PA
  descriptor 里写的 IOVA 数值就是 PA

IOVA-as-VA:
  DPDK 直接使用这段内存的 VA 数值作为 IOVA 数值
  memseg->iova = memseg->addr
  然后通过 VFIO 告诉 IOMMU:
    把 iova=这个 VA 数值 映射到 vaddr=这段用户态 hugepage
```

所以 VA 模式下最容易理解成：

```text
user VA:
  0x7f00_0000_0000

DPDK 选择的 IOVA:
  0x7f00_0000_0000

VFIO/IOMMU 建立:
  IOVA 0x7f00_0000_0000 -> backing physical pages
```

这就是为什么叫 IOVA-as-VA：设备看到的 DMA 地址数值长得像用户态虚拟地址，但设备并
不是在走 CPU MMU；它走的是 IOMMU 的 I/O 页表。

还要注意：IOVA 地址空间不是全局唯一的，它属于某个 VFIO container / IOMMU domain。

```text
同一个 VFIO container / 同一个 IOMMU domain:
  IOVA range 不能重叠
  如果已经 map 了 0x1000_0000 - 0x100f_ffff
  再 map 一个重叠 range，VFIO_IOMMU_MAP_DMA 通常会失败

不同 VFIO container / 不同 IOMMU domain:
  IOVA 数值可以相同
  因为它们使用不同的 IOMMU page table
```

这和进程虚拟地址很像：

```text
Process A:
  VA 0x400000 -> A 的物理页

Process B:
  VA 0x400000 -> B 的物理页
```

地址数值一样，但页表不同，所以不冲突。DMA 也是类似：

```text
Device A:
  requester ID = 0000:3b:10.1
  IOVA 0x7f00_0000_0000
  -> IOMMU domain A
  -> PA A

Device B:
  requester ID = 0000:5e:00.1
  IOVA 0x7f00_0000_0000
  -> IOMMU domain B
  -> PA B
```

IOMMU 会根据设备的 requester ID 找到对应的 domain/page table，再在这个 domain 里
翻译 IOVA。因此：

```text
同一个 domain 内:
  IOVA 不能重叠

不同 domain 间:
  IOVA 数值可以重叠

同一个 VFIO group:
  通常必须作为同一个隔离单元管理
  不能被两个互不信任的应用分别独立控制
```

如果是 UIO/no-IOMMU 或 IOVA-as-PA，descriptor 里的 IOVA 数值通常就是物理地址；如果
是 VFIO/IOMMU + IOVA-as-VA，descriptor 里的 IOVA 是 IOMMU 地址空间里的地址。

`buf_iova` 很多并不代表给 IOMMU 建了很多独立映射。它只是每个 mbuf 里缓存的一个
地址值：

```text
IOMMU 映射粒度:
  通常按 memseg / hugepage / DMA map region 建立映射

mbuf 粒度:
  每个 mbuf 只保存一个落在这些已映射区域里的 buf_iova
```

所以 100 万个 mbuf 会有 100 万个 `buf_iova` 字段，但它们通常都落在少量 hugepage
映射范围内：

```text
hugepage region:
  IOVA 0x100000000 - 0x180000000  已映射给设备

mbuf 0 buf_iova:
  0x100001000

mbuf 1 buf_iova:
  0x100003800

mbuf N buf_iova:
  0x17fff000
```

真正消耗 IOMMU/DMA 地址空间的是被映射的 DPDK 内存总量和映射碎片度，不是 mbuf
数量本身。可能出问题的场景通常是：

```text
设备 DMA mask 很小:
  例如只能寻址 32-bit DMA 地址空间

映射了过多 DPDK 内存:
  hugepage 总量接近或超过设备/IOMMU aperture

外部内存非常碎:
  产生大量 VFIO DMA map entry / IOMMU page table entry

多进程/多设备重复映射:
  每个 IOMMU domain 都要维护自己的映射视图
```

多段 mbuf 不要求整个 packet 的 IOVA 连续。NIC TX 通常使用多个 descriptor 或
scatter-gather 能力发送多段 packet；前提是设备和 PMD 支持 multi-seg，并且队列配置
允许对应 offload。

```c
if (rte_pktmbuf_is_contiguous(m)) {
    // 一个 segment，一个 data pointer，一个 IOVA
} else {
    // 多 segment，需要 PMD/NIC 支持多段 TX/RX
    for (struct rte_mbuf *seg = m; seg != NULL; seg = seg->next) {
        rte_iova_t seg_iova = rte_pktmbuf_iova(seg);
        uint16_t seg_len = rte_pktmbuf_data_len(seg);
        // 每个 segment 对应一个 descriptor 或 S/G entry
    }
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

vhost DMA 这里也要避免一个误解：业务应用通常不会自己手写一套 `GPA -> IOVA` 表，
再直接驱动 DMA engine。真实路径一般由 DPDK vhost library 管理 virtqueue 和 guest
memory table，必要时通过 async path 把 copy offload 给 dmadev。

vhost-user 进程通常先拿到的是 **Guest physical address（GPA）到 Host userspace
virtual address（HVA）** 的映射。是否能得到 Host physical address（HPA），以及 DMA
engine 该使用 HPA 还是 IOVA，取决于 VFIO/IOMMU 和 DPDK 的 IOVA 模式。

更稳妥的流程是：

```text
virtqueue descriptor:
  addr = GPA

vhost memory table:
  GPA -> HVA

DMA copy engine:
  HVA -> IOVA
  把 IOVA 写入 DMA descriptor

IOMMU:
  IOVA -> PA
```

所以代码里写 `gpa_to_hpa()` 只能当作早期/简化模型。现代 DPDK/vhost async copy 更应
理解为 `GPA -> HVA -> IOVA`。

从职责分工看：

```text
DPDK vhost library:
  解析 virtqueue
  管理 guest memory table
  做 GPA -> HVA
  管理 async in-flight packets

dmadev / DSA:
  执行 Host mbuf 和 Guest buffer 之间的 memory-to-memory copy

应用 / OVS-DPDK / VPP:
  配置 vhost async channel
  提交 async enqueue/dequeue
  poll completion
  处理完成后的 mbuf 生命周期和 used ring 更新
```

更完整的 Host/Guest 硬件卸载路径可以看：
[[ch27a-vdpa-dsa-host-guest-accel|第二十七章补充：vDPA、DSA 与 Host/Guest 数据面卸载]]。

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

这里的 `rte_eth_rx_burst()` 不是“封装了一次 DMA copy 调用”。更准确地说：

```text
队列初始化时:
  PMD 创建 RX descriptor ring
  PMD 分配一批 mbuf
  PMD 把每个 mbuf 的 IOVA 写入 RX descriptor
  NIC 知道“收到包以后 DMA 写到这些地址”

包到达时:
  NIC 自己执行 DMA
  把 packet 写入某个 RX descriptor 指向的 mbuf buffer
  NIC 更新 descriptor 状态

应用调用 rte_eth_rx_burst():
  PMD 轮询 RX descriptor
  找到已经完成 DMA 的 descriptor
  返回对应 mbuf 指针
  再补充新的空 mbuf 给 RX ring
```

所以 RX 的 DMA 是 NIC 数据面异步发生的；`rte_eth_rx_burst()` 的主要工作是收割已经
完成的 descriptor，而不是临时发起一次 DMA。

### 5.2 零拷贝发送 (Zero-Copy TX)

```c
// DPDK 零拷贝发送

// TX mbuf 直接传输 (无拷贝)
uint16_t
zero_copy_tx(uint16_t port_id, struct rte_mbuf **mbufs, uint16_t nb)
{
    uint16_t nb_sent = rte_eth_tx_burst(port_id, 0, mbufs, nb);

    // 已成功入队的 mbuf: ownership 转交给 PMD/NIC，应用程序不应再访问或释放
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
    rte_mbuf_refcnt_update(m, 1);
    return m;
}

static inline void
mbuf_put_ref(struct rte_mbuf *m)
{
    // 实际代码通常直接 rte_pktmbuf_free()，由 DPDK 处理 direct/indirect/refcnt
    rte_pktmbuf_free(m);
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

    // 重新发送同一个 mbuf。调用成功后 ownership 转交给 PMD。
    return zero_copy_tx(port_id, &m, 1);
}
```

TX 的关键不是“发送成功后驱动立刻释放 mbuf”。更准确的生命周期是：

```text
应用调用 rte_eth_tx_burst()
  -> 成功入队的 mbuf ownership 转给 PMD
  -> NIC 完成 DMA 读之后，PMD 在后续清理 TX descriptor 时释放/回收 mbuf
  -> 未入队的 mbuf 仍归应用所有，应用必须重试或释放
```

因此 `rte_eth_tx_burst()` 返回后，应用只能处理 `[nb_sent, nb)` 这段未发送 mbuf；
不能再读写 `[0, nb_sent)` 这段已经交给 PMD 的 mbuf。

TX 也是同样的模型：`rte_eth_tx_burst()` 不是把 packet 复制到 NIC，而是把 mbuf 的
IOVA 写入 TX descriptor：

```text
应用调用 rte_eth_tx_burst():
  PMD 把 mbuf IOVA / len / offload metadata 写入 TX descriptor
  PMD 更新 TX tail / doorbell

之后:
  NIC 根据 TX descriptor 里的 IOVA 发起 DMA read
  从 mbuf buffer 读 packet
  发到 wire
  PMD 后续回收已经完成的 mbuf
```

所以 ethdev RX/TX 确实依赖 DMA，但它是 **NIC descriptor ring 驱动的 packet DMA**，
不是 `rte_dma_copy()` 这种 **DMA engine memory copy**。

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

// 创建 indirect mbuf (零拷贝共享)，示意代码
struct rte_mbuf *
clone_packet(struct rte_mbuf *m, struct rte_mempool *clone_pool)
{
    // DPDK API 会分配 indirect mbuf 并 attach 到原始 mbuf
    return rte_pktmbuf_clone(m, clone_pool);
}

// Indirect mbuf 生命周期
void
indirect_mbuf_demo(void)
{
    // 原始 mbuf
    struct rte_mbuf *original = rte_pktmbuf_alloc(mbuf_pool);
    // ... 填充数据 ...

    // 创建 indirect mbuf (零拷贝)
    struct rte_mbuf *clone = rte_pktmbuf_clone(original, clone_pool);

    // 两个 mbuf 共享同一个 buffer
    // 修改 clone 的数据会影响 original

    // 使用完毕后释放
    rte_pktmbuf_free(clone);    // 释放 clone (引用计数 -1)
    rte_pktmbuf_free(original); // 原始 buffer 被实际释放
}

// 如果已经有一个 indirect mbuf mi，也可以显式 attach 到 direct mbuf m
// 注意：真实 DPDK API 返回 void，不是返回新 mbuf。
rte_pktmbuf_attach(mi, m);
rte_pktmbuf_detach(mi);
```

`rte_pktmbuf_attach()` 不是“传入一个 mbuf 然后返回 clone”的 API。真实常用方式是：

```text
rte_pktmbuf_clone(original, clone_pool):
  分配 indirect mbuf
  attach 到 original
  增加引用计数
  返回 clone

rte_pktmbuf_attach(indirect, direct):
  把已经分配好的 indirect mbuf attach 到 direct mbuf
```

### 5.4 零拷贝场景示例

```c
// 场景 1: Packet clone，用于镜像、组播、重传等

struct rte_mbuf *
packet_clone(struct rte_mbuf *m, struct rte_mempool *clone_pool)
{
    // 共享原始 payload，不复制 packet data
    return rte_pktmbuf_clone(m, clone_pool);
}

// 场景 2: 从头部剥离字段，通常只调整 data_off / data_len

struct rte_mbuf *
strip_tunnel_header(struct rte_mbuf *m, uint16_t header_len)
{
    if (rte_pktmbuf_adj(m, header_len) == NULL)
        return NULL;

    return m;
}

// 场景 3: 添加小头部，优先使用 headroom；如果 headroom 不够才需要新 mbuf/拷贝

struct rte_mbuf *
prepend_header(struct rte_mbuf *m, const void *hdr, uint16_t hdr_len)
{
    void *p = rte_pktmbuf_prepend(m, hdr_len);
    if (p == NULL)
        return NULL;

    rte_memcpy(p, hdr, hdr_len);
    return m;
}
```

这些例子背后的原则是：

```text
能改 metadata 就不改 payload；
能复用 mbuf 就不复制 packet；
必须复制时再考虑 CPU memcpy 或 dmadev；
不能手工乱改 indirect mbuf 的 buf_addr/head/refcnt，优先使用 DPDK API。
```

IP 分片、VLAN 插入、封装/解封装都可能涉及协议校验和、offload 标志、多段 mbuf 和
headroom/tailroom。真实工程里不要只靠手工移动指针，应该结合 DPDK 提供的 mbuf API、
ethdev offload 能力和协议栈库来做。

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
// 现代 DPDK 使用 dmadev API，而不是旧的 rte_ioat_* 示例 API。
// 下面是核心调用顺序示意：

int
dmadev_copy_one(int dev_id, uint16_t vchan,
                rte_iova_t dst, rte_iova_t src, uint32_t len)
{
    int ring_idx;
    uint16_t last_idx;
    bool has_error = false;

    // 1. enqueue copy operation
    ring_idx = rte_dma_copy(dev_id, vchan, src, dst, len, 0);
    if (ring_idx < 0)
        return ring_idx;

    // 2. doorbell: 让硬件开始处理之前 enqueue 的操作
    rte_dma_submit(dev_id, vchan);

    // 3. poll completion
    while (rte_dma_completed(dev_id, vchan, 1, &last_idx, &has_error) == 0)
        rte_pause();

    return has_error ? -EIO : 0;
}

int
dmadev_copy_burst(int dev_id, uint16_t vchan,
                  struct rte_mbuf **srcs, struct rte_mbuf **dsts,
                  unsigned int nb, uint32_t len)
{
    for (unsigned int i = 0; i < nb; i++) {
        rte_iova_t src = rte_pktmbuf_iova(srcs[i]);
        rte_iova_t dst = rte_pktmbuf_iova(dsts[i]);

        if (rte_dma_copy(dev_id, vchan, src, dst, len, 0) < 0)
            return -ENOSPC;
    }

    rte_dma_submit(dev_id, vchan);

    uint16_t last_idx;
    bool has_error = false;
    unsigned int done = 0;

    while (done < nb) {
        done += rte_dma_completed(dev_id, vchan, nb - done,
                                  &last_idx, &has_error);
        if (has_error)
            return -EIO;
    }

    return 0;
}
```

`rte_dma_copy()` 只负责把操作放入 DMA 设备队列；`rte_dma_submit()` 才是通知硬件开始
处理；`rte_dma_completed()` / `rte_dma_completed_status()` 用来回收完成结果。这个
模型和 ethdev 的 `rte_eth_tx_burst()` 不一样，不能把旧的 I/OAT 私有 API 当成通用写法。

### 6.3 高性能内存操作

这一节原来容易让人误会成“手写一个更快的 memcpy”。在 DPDK 数据面里，通常不要从
手写 memcpy 开始优化。更重要的顺序是：

```text
1. 能不拷贝就不拷贝
   RX mbuf 直接转发到 TX
   clone 用 indirect mbuf
   prepend/adj 只改 metadata

2. 必须 CPU 读写时，让 CPU 更容易命中 cache
   预取下一批 mbuf/header
   只碰必要的 cache line
   避免跨 NUMA 访问

3. 必须大块复制时，再考虑 rte_memcpy() 或 dmadev
   小包拷贝通常 CPU 更划算
   大块、批量、异步 copy 才适合 DMA engine
```

#### 6.3.1 预取：提前把下一批数据拉进 cache

DPDK PMD 一次通常收一批包：

```c
struct rte_mbuf *pkts[32];
uint16_t nb_rx = rte_eth_rx_burst(port_id, queue_id, pkts, 32);
```

如果处理当前包时，顺手预取后面几个包的 mbuf/header，CPU 真正处理它们时可能已经
不用等内存：

```c
for (uint16_t i = 0; i < nb_rx; i++) {
    if (i + 4 < nb_rx) {
        rte_prefetch0(pkts[i + 4]);
        rte_prefetch0(rte_pktmbuf_mtod(pkts[i + 4], void *));
    }

    struct rte_ether_hdr *eth =
        rte_pktmbuf_mtod(pkts[i], struct rte_ether_hdr *);

    process_l2_l3_header(eth);
}
```

这里的意思不是“预取一定更快”。它只在访问模式稳定、批量处理、内存延迟成为瓶颈时有
价值。预取太近没用，预取太远会污染 cache。

#### 6.3.2 对齐：让 CPU 少跨 cache line

现代 CPU 以 cache line 为单位搬数据，常见是 64 字节。DPDK 结构体经常做 cache line
对齐，是为了减少一个 hot field 横跨两个 cache line 的情况。

```text
理想情况:
  一个常用结构体字段落在同一个 cache line 内

坏情况:
  一个字段或一组 hot fields 横跨两个 cache line
  CPU 需要多取一条 cache line
```

DPDK 里常见写法：

```c
struct my_queue {
    uint16_t head;
    uint16_t tail;
    uint16_t size;
    uint16_t mask;
} __rte_cache_aligned;
```

这不是为了“让 DMA 更快”，而是为了让 CPU 处理队列、descriptor、mbuf metadata 时更少
cache miss。

#### 6.3.3 拷贝：优先用库函数，不要手写危险 memcpy

普通 packet 转发不应该走：

```text
RX mbuf -> copy 到新 mbuf -> TX
```

更好的路径通常是：

```text
RX mbuf -> 改 header/checksum/offload metadata -> TX
```

如果确实必须复制：

```c
void *src = rte_pktmbuf_mtod(src_mbuf, void *);
void *dst = rte_pktmbuf_mtod(dst_mbuf, void *);

rte_memcpy(dst, src, len);
```

不要轻易手写这类代码：

```c
uint64_t *d64 = dst;
uint64_t *s64 = src;
*d64++ = *s64++;
```

原因是边界条件很多：

```text
src/dst 是否对齐？
len 是否小于 8？
src/dst 是否重叠？
是否跨 cache line？
是否跨 page？
编译器是否能生成更好的向量化代码？
```

DPDK 的 `rte_memcpy()` 和编译器内建 `memcpy()` 已经会处理很多平台细节。只有在非常
明确的热点路径里，才值得进一步写 SIMD/非临时写入等专用版本。

#### 6.3.4 DMA copy：批量提交才有意义

如果已经决定用 dmadev，重点不是“单个 copy 怎么写得漂亮”，而是减少 doorbell 和
completion 开销：

```text
低效:
  copy 1 个
  submit 1 次
  poll 1 次

更合理:
  enqueue 32 个 copy
  submit 1 次
  批量 poll completion
```

也就是说：

```text
CPU memcpy 优化:
  关注 cache、对齐、预取、NUMA

DMA copy 优化:
  关注 batch、submit、completion、IOVA 可访问性、NUMA
```

---

## 7. 完整使用示例

### 7.1 正常 RX/TX 不需要手动调用 DMA copy

普通 DPDK 转发路径里，应用不需要自己“关联 DMA engine”。NIC 的 RX/TX DMA 已经由
PMD、descriptor ring 和 mbuf IOVA 串起来了：

```text
RX:
  PMD 把空 mbuf 的 IOVA 放进 RX descriptor
  NIC 收包后 DMA write 到 mbuf
  rte_eth_rx_burst() 返回已经写好的 mbuf

TX:
  应用把同一个 mbuf 交给 rte_eth_tx_burst()
  PMD 把 mbuf 的 IOVA 放进 TX descriptor
  NIC DMA read 这个 mbuf 并发包
```

所以最常见的零拷贝转发循环是：

```c
static int
forward_loop(void *arg)
{
    struct rte_mbuf *pkts[32];

    while (!quit) {
        uint16_t nb_rx = rte_eth_rx_burst(rx_port, rx_queue, pkts, 32);
        if (nb_rx == 0)
            continue;

        for (uint16_t i = 0; i < nb_rx; i++) {
            update_ttl(pkts[i]);
            update_checksum_or_offload_flags(pkts[i]);
        }

        uint16_t nb_tx = rte_eth_tx_burst(tx_port, tx_queue, pkts, nb_rx);

        for (uint16_t i = nb_tx; i < nb_rx; i++)
            rte_pktmbuf_free(pkts[i]);
    }

    return 0;
}
```

这个循环里没有 `rte_dma_copy()`，因为 packet data 没有被复制到新的 TX buffer。
ownership 变化是：

```text
NIC RX ring
  -> rte_eth_rx_burst()
  -> application
  -> rte_eth_tx_burst()
  -> NIC TX ring
```

前面那个“RX mbuf -> DMA copy -> TX mbuf”的写法，只适合说明 **dmadev 如何做
memory-to-memory copy**，不适合作为普通 packet forwarding 示例。只有在这些场景里
才考虑单独的 DMA copy engine：

```text
必须保留原始 RX mbuf，同时生成另一份 packet
跨 VM / vhost / 进程内存域搬运数据
需要把 payload 整理到连续 buffer
做大块批量内存复制，CPU 有更重要的包处理任务
```

如果只是转发、路由、NAT、简单改头，直接复用 mbuf 才是更自然的 DPDK 路径。

### 7.2 Vhost DMA 到底在解决什么

vhost 场景和物理 NIC 转发不一样。它的一端是 DPDK/OVS/VPP 里的 mbuf，另一端是 VM
里的 virtqueue buffer：

```text
Host DPDK / OVS / VPP:
  mbuf buffer

Guest VM:
  virtqueue descriptor 指向 guest memory
```

如果没有硬件 vDPA，很多 vhost-user 数据路径本质上要在两类内存之间搬数据：

```text
Guest TX:
  VM virtio driver 把 packet 放在 guest buffer
  vhost 后端读取 guest buffer
  拷贝/组装成 host mbuf
  交给 OVS-DPDK / VPP / NIC

Guest RX:
  Host 收到 packet，存在 mbuf
  vhost 后端找到 guest 提供的空 buffer
  把 packet 拷贝进 guest buffer
  更新 used ring
```

这时候的 copy 不是普通物理网卡 TX/RX 的 copy，而是 **Host mbuf 和 Guest memory 之间
的 memory-to-memory copy**。如果这类 copy 成为瓶颈，就可以考虑用 dmadev/DSA 之类
的 DMA copy engine 做异步拷贝。

但真实工程里通常不是业务应用自己手写一套 `GPA -> IOVA` 表和 DMA 队列。更常见的是：

```text
DPDK vhost library:
  解析 virtqueue
  管理 guest memory table
  做 GPA -> HVA 转换
  支持 async copy callback / DMA backend

dmadev / DSA:
  负责真正的 memory-to-memory copy

应用 / OVS-DPDK / VPP:
  配置 vhost async path
  poll completion
  继续处理 packet
```

所以更准确的层次是：

```text
普通 NIC RX/TX:
  PMD + NIC descriptor ring 组织 packet DMA
  应用不需要单独调用 dmadev

vhost-user software backend:
  vhost library 组织 virtqueue 和 guest memory
  如果需要 copy，可以把 copy offload 给 dmadev

vDPA / virtio 硬件卸载:
  硬件直接理解 virtqueue
  进一步减少 host software copy
```

可以把 vhost DMA 理解成：

```text
不是“发包必须自己组织 DMA”
而是“vhost software backend 需要在 guest memory 和 host mbuf 之间搬数据时，
可以把这段搬运交给 DMA copy engine”
```

一个简化路径如下：

```text
Guest RX:
  Host mbuf
    -> vhost 找到 guest empty descriptor
    -> GPA -> HVA -> IOVA
    -> dmadev copy: host mbuf IOVA -> guest buffer IOVA
    -> vhost 更新 used ring
    -> guest virtio driver 收到 packet
```

如果用的是 vDPA，路径会变成：

```text
virtqueue
  -> vDPA device / SmartNIC / DPU
  -> hardware 直接 DMA guest memory
```

这也是为什么 vhost DMA 应该放在“特殊场景”里，而不是和普通 DPDK RX/TX 混为一谈。

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
│  判断 DMA copy engine 是否值得用:                                          │
│  ───────────────────────────                                               │
│                                                                             │
│  1. 单次 copy 大小是否足够大？小包可能被提交/完成开销吞掉收益。             │
│  2. 是否能批量 enqueue，再统一 submit？                                     │
│  3. CPU 是否真的有更重要的 packet 处理逻辑要做？                            │
│  4. 源/目标内存是否在 DMA device 可访问的 IOVA 空间里？                     │
│  5. DMA device 和内存是否在同一个 NUMA socket？                             │
│  6. completion 轮询是否会抵消释放 CPU 的收益？                              │
│                                                                             │
│  IOVA 模式选择:                                                            │
│  ─────────────                                                             │
│                                                                             │
│  PA: 直接、兼容老设备/老部署，但需要能获取物理地址，隔离能力弱。             │
│  VA: 更适合 VFIO/IOMMU 隔离，地址空间更灵活，但依赖平台和内核配置。          │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 8.2 常见问题与解决

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        DMA 常见问题与解决                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  问题 1: 把 VA 当成 DMA 地址                                                │
│  ─────────────────────────                                                  │
│  原因: CPU 指针和设备 IOVA 是两套地址语义                                  │
│  解决: mbuf 用 rte_pktmbuf_iova()，普通 DPDK 内存用 rte_mem_virt2iova()     │
│                                                                             │
│  问题 2: 多段 mbuf 不能发送                                                 │
│  ────────────────────────────────                                           │
│  原因: 设备/PMD/队列没有启用 multi-seg 或 S/G 能力                          │
│  解决: 配置对应 offload，或 rte_pktmbuf_linearize()                         │
│                                                                             │
│  问题 3: 跨 NUMA DMA                                                       │
│  ─────────────────────                                                      │
│  原因: DMA 访问远程 socket 内存                                            │
│  解决: 使用本地 socket 内存 pool                                            │
│                                                                             │
│  问题 4: Cache 一致性                                                       │
│  ────────────────                                                           │
│  原因: DMA 写入后 CPU 过早读取，或 CPU 改写后没有正确同步给设备             │
│  解决: 使用 DPDK/PMD 提供的 barrier、doorbell 和 completion 语义             │
│                                                                             │
│  问题 5: DMA 完成延迟                                                      │
│  ──────────────────                                                         │
│  原因: batch 太小、completion 轮询策略不合适、设备/NUMA 放置不合理          │
│  解决: 批量 enqueue/submit，调 completion polling，按 NUMA 绑定内存和线程   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 9. 小结

本章核心要点：

1. **传统 I/O 路径**：4 次拷贝 (NIC DMA → sk_buff → 用户 buffer → TX DMA)，CPU 参与每个包的拷贝。

2. **零拷贝目标**：尽量避免复制 packet data，优先传递 mbuf ownership 或共享 buffer。

3. **DMA copy engine**：适合必须搬运大块数据或 vhost async copy 的场景，不等于零拷贝本身。

4. **IOVA (I/O Virtual Address)**：设备侧 DMA 地址抽象，可能是 PA，也可能通过 IOMMU 映射到 PA。

5. **DPDK IOVA 模式**：`RTE_IOVA_PA` 和 `RTE_IOVA_VA` 表示 IOVA 数值如何分配，不应简单等同于“IOMMU 开/关”。

6. **Virtio/Vhost DMA**：vhost 从 virtqueue descriptor 取 GPA，经 vhost memory table 找到 HVA，再转换成 DMA engine 可用的 IOVA。

7. **VDPA (vhost Data Path Acceleration)**：将 virtqueue 处理卸载到硬件，减少 VM exit 次数。

8. **零拷贝接收**：DPDK mbuf 直接映射用户空间内存，NIC DMA 直接写入，零拷贝。

9. **零拷贝发送**：`rte_eth_tx_burst()` 直接传输 mbuf，应用程序无需拷贝。

10. **Indirect mbuf**：零拷贝共享原始数据，通过引用计数管理生命周期。

11. **零拷贝场景**：Packet clone、组播/镜像、头部 prepend/adj、封装/解封装。

12. **DMA 友好设计**：正确使用 IOVA、多段 mbuf/offload、批量提交、跨 NUMA 避免。

**下一篇预告**：[[ch28-multicore-sync|第二十八章]]将讲解多核同步——Spinlock、RCU、Memory Reorder。

---

> [!tip] 参考文献
>
> - Intel, "Intel I/O Acceleration Technology", https://www.intel.com/content/www/us/en/architecture-and-technology/io-acceleration.html
> - "DMA Engine in Linux Kernel", https://www.kernel.org/doc/html/latest/driver-api/dmaengine/
> - "Virtio Spec", https://docs.oasis-open.org/virtio/virtio/v1.1/virtio-v1.1.pdf
> - "vHost/Virtio DMA Backend", https://www.kernel.org/doc/html/latest/virt/vhost/vhost.html
> - DPDK, "DMA Device Library", https://doc.dpdk.org/guides/prog_guide/dmadev.html
> - DPDK, "Mbuf API Reference", https://doc.dpdk.org/api/rte__mbuf_8h.html
> - "Zero-copy networking", https://lwn.net/Articles/21944/
