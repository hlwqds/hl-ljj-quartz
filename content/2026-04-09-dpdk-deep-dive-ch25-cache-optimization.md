---
title: "DPDK 深度探索 (二十五)：Cache 优化：False Sharing 与预取"
date: 2026-04-09
tags: [dpdk, series, cache, false-sharing, prefetch, numa, memory, performance, mbuf, rte_ring]
description: "深入理解 CPU Cache 机制与 DPDK 性能优化——Cache 层次、False Sharing、预取策略、内存访问模式、Mbuf 缓存优化"
---

> [!info] DPDK 深度探索系列
> 0. [[2026-04-09-dpdk-deep-dive-series-index|全栈学习路径总览]]
> 1-24. 前二十四章已完成
> 25. **第二十五章：Cache 优化——False Sharing 与预取**

---

## 1. 概述：为什么 Cache 决定性能

### 1.1 性能金字塔

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            性能金字塔                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│                              CPU                                           │
│                           (cycles)                                         │
│                              │                                             │
│                    ┌────────┴────────┐                                    │
│                    │   Registers    │  < 1 ns (0.3 ns)                   │
│                    │    (bytes)     │  ~256B                            │
│                    └────────────────┘                                    │
│                              │                                             │
│                    ┌────────┴────────┐                                    │
│                    │     L1 Cache   │  ~1 ns (0.5-1 ns)                  │
│                    │    32-64 KB    │  4-8 cycles                       │
│                    └────────────────┘                                    │
│                              │                                             │
│                    ┌────────┴────────┐                                    │
│                    │     L2 Cache   │  ~3-4 ns                           │
│                    │   256KB-1MB    │  12-20 cycles                      │
│                    └────────────────┘                                    │
│                              │                                             │
│                    ┌────────┴────────┐                                    │
│                    │     L3 Cache   │  ~10-20 ns                         │
│                    │    8-64 MB     │  30-60 cycles                      │
│                    └────────────────┘                                    │
│                              │                                             │
│                    ┌────────┴────────┐                                    │
│                    │     Memory     │  ~80-120 ns                         │
│                    │    (DRAM)     │  200-300 cycles                     │
│                    └────────────────┘                                    │
│                              │                                             │
│                    ┌────────┴────────┐                                    │
│                    │   NVMe SSD     │  ~100 μs                           │
│                    └────────────────┘                                    │
│                              │                                             │
│                    ┌────────┴────────┐                                    │
│                    │      Disk      │  ~10 ms                            │
│                    └────────────────┘                                    │
│                                                                             │
│  数字说话:                                                                 │
│  - L1 Cache 访问比 Memory 快 100倍                                         │
│  - 一次 Cache Miss 可能浪费 200+ cycles                                     │
│  - DPDK 64B 包处理 200 cycles/M pkt → 一次 miss 就 100% 开销              │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 1.2 现代 CPU Cache 架构

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        多核 CPU Cache 架构                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐ │
│  │                        CPU Socket 0                                  │ │
│  │                                                                      │ │
│  │   ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐               │ │
│  │   │ Core 0  │  │ Core 1  │  │ Core 2  │  │ Core 3  │               │ │
│  │   │ L1d 32K │  │ L1d 32K │  │ L1d 32K │  │ L1d 32K │               │ │
│  │   │ L1i 32K │  │ L1i 32K │  │ L1i 32K │  │ L1i 32K │               │ │
│  │   │  L2 256K│  │  L2 256K│  │  L2 256K│  │  L2 256K│               │ │
│  │   └────┬────┘  └────┬────┘  └────┬────┘  └────┬────┘               │ │
│  │        └───────────┼───────────┼───────────┘                      │ │
│  │                      │           │                                   │ │
│  │              ┌───────┴───────────┴───────┐                         │ │
│  │              │         L3 Cache (Shared)   │                         │ │
│  │              │          8-16 MB            │                         │ │
│  │              └───────────┬───────────────┘                         │ │
│  └──────────────────────────┼──────────────────────────────────────────┘ │
│                             │                                              │
│                    ┌────────┴────────┐                                   │
│                    │   Memory Ctrl  │                                    │
│                    │   (DDR4/5)    │                                    │
│                    └────────┬────────┘                                   │
│                             │                                              │
│                    ┌────────┴────────┐                                   │
│                    │      DRAM        │                                   │
│                    │   64-256 GB     │                                   │
│                    └─────────────────┘                                   │
│                                                                             │
│  Cache Line: 64 bytes (现代 CPU 标准)                                      │
│  ─────────────────────────────────                                        │
│  - L1/L2: 64B line, 8-way associative                                    │
│  - L3: 64B line, 12-16 way associative                                  │
│  - 写入: write-back + write-allocate                                     │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Cache 映射与关联性

### 2.1 Cache Line 结构

```c
// Cache Line = 64 bytes

struct cache_line {
    uint8_t data[64];               // 数据负载

    // Tag (用于匹配地址)
    uint64_t tag: 48;              // 物理地址的高 48 位

    // 状态位
    uint8_t valid: 1;              // 有效位
    uint8_t dirty: 1;               // 脏位 (write-back)
    uint8_t lru: 6;                // LRU 替换信息
};

// 地址分解
// ─────────────
// 虚拟地址: [tag][index][offset]
//           48 bits  12 bits  6 bits
//
// Cache 结构:
// - Offset: 6 bits (64 bytes per line)
// - Index: 12 bits (2^12 = 4096 sets per cache)
// - Tag: 剩余位

// 直接映射缓存 (1-way)
struct direct_mapped_cache {
    struct cache_line sets[4096];  // 每组一行
};

// N-way 组相联缓存
struct set_associative_cache {
    struct cache_line sets[4096][8];  // 8-way
    uint8_t lru_state[4096][8];         // LRU 状态
};
```

### 2.2 Cache Miss 类型

```c
// Cache Miss 三种类型

enum cache_miss_type {
    CACHE_MISS_COMPULSORY = 0,    // 首次访问必定 miss (cold start)
    CACHE_MISS_CAPACITY,          // working set 超出 cache 容量
    CACHE_MISS_CONFLICT,          // 组相联冲突替换
};

// Miss 代价
// ──────────
// Compulsory Miss: 无法避免，但可通过预取缓解
// Capacity Miss:   增加 cache 容量或优化数据布局
// Conflict Miss:   增加关联性或降低地址冲突

// 示例: mbuf 分配导致的 Miss
void
mbuf_cache_demo(void)
{
    struct rte_mbuf *m;

    // 情况 1: 首次分配 (Compulsory Miss)
    m = rte_pktmbuf_alloc(mbuf_pool);  // mbuf 可能不在 cache 中

    // 情况 2: 批量分配 (Capacity Miss)
    for (int i = 0; i < 1000; i++) {
        m = rte_pktmbuf_alloc(mbuf_pool);
        // 如果 pool 很大，可能每次都 miss
    }

    // 情况 3: 多核访问同一 cache line (Conflict Miss)
    // 见 False Sharing 章节
}
```

### 2.3 缓存一致性协议

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        MESI 缓存一致性协议                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  MESI 状态:                                                                │
│  ──────────                                                                │
│                                                                             │
│  M (Modified): 本核独占修改，该行已脏                                      │
│  E (Exclusive): 本核独占干净，无修改                                       │
│  S (Shared): 多核共享，干净                                               │
│  I (Invalid): 该行无效                                                     │
│                                                                             │
│  状态转换:                                                                 │
│  ──────────                                                                │
│                                                                             │
│  CPU0 读 A ──► I ──► E (独占干净)                                         │
│                                                                             │
│  CPU0 写 A ──► E ──► M (独占修改)                                         │
│                         │                                                 │
│  CPU1 也读 A ◄───────────┘                                                 │
│                    M ──► S (共享，CPU0 数据写回)                          │
│                                                                             │
│  CPU0 写 A ──► S ──► M (CPU1 变为 Invalid，数据从 CPU0 获取)             │
│                                                                             │
│  总线嗅探: 每个核监听总线上的内存访问，发现冲突时响应                       │
│                                                                             │
│  写直达 vs 写回:                                                           │
│  ─────────────────                                                          │
│  Write-through: 每次写直达内存 (慢)                                        │
│  Write-back: 写回 cache，miss 时写回 (快，但复杂)                         │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. False Sharing

### 3.1 什么是 False Sharing

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          False Sharing 示意图                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  场景: 两个核分别更新各自的数据                                             │
│  ─────────────────────────────────────                                     │
│                                                                             │
│  Cache Line (64 bytes):                                                    │
│  ┌────────────────────────────────────────────────────────────────────┐  │
│  │ [CPU0 counter: 8 bytes] │ [CPU1 counter: 8 bytes] │ [padding: 48B] │  │
│  └────────────────────────────────────────────────────────────────────┘  │
│                              ▲                                              │
│                              │                                              │
│                       同一 Cache Line                                       │
│                       两个核频繁修改                                         │
│                                                                             │
│  问题:                                                                    │
│  ────                                                                    │
│  CPU0 更新 counter0 → Cache Line 变为 M 态                                 │
│  CPU1 更新 counter1 → 同一 Cache Line，触发总线事务                        │
│                    → CPU0 的 M 态 Cache Line 必须写回                      │
│                    → CPU1 获得 S 态（共享）                                │
│  CPU0 再次更新 counter0 → 又触发总线事务                                   │
│                    → CPU1 的 Cache Line 变为 I                            │
│                    → 必须重新读取                                          │
│                                                                             │
│  结果: 两个线程各自只修自己的变量，但性能下降 10-50x                       │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 3.2 DPDK 中的 False Sharing 案例

```c
// DPDK rte_ring 的 False Sharing

struct rte_ring {
    // 队首/队尾指针 (每个 8 bytes)
    volatile uint32_t cons.head;    // 消费头
    volatile uint32_t cons.tail;     // 消费尾
    volatile uint32_t prod.head;    // 生产头
    volatile uint32_t prod.tail;    // 生产尾

    uint32_t flags;
    uint32_t size;
    uint32_t mask;
    void **ring;                   // 数据数组
};

// 问题: cons.tail 和 prod.tail 在同一 Cache Line
// 如果 producer 更新 prod.tail，consumer 的 Cache Line 失效

// 错误示例: 多核同时入队/出队
void
ring_false_sharing_example(struct rte_ring *r)
{
    // Core 0: producer
    for (int i = 0; i < 1000000; i++) {
        // 更新 prod.tail (触发 False Sharing)
        rte_ring_enqueue(r, (void *)(uintptr_t)i);
    }

    // Core 1: consumer
    for (int i = 0; i < 1000000; i++) {
        // 更新 cons.tail (触发 False Sharing)
        void *obj;
        rte_ring_dequeue(r, &obj);
    }
}

// 正确示例: 使用 rte_ring_sp / rte_ring_mc 分离
void
ring_no_false_sharing(struct rte_ring *r)
{
    // 分离的 ring: prod 和 cons 使用不同的数据结构
    // 但仍然是 False Sharing 热点

    // 更好的方案: 使用 aligned 结构
}

// 更好的设计: rte_ring 使用 cacheline 分离
struct rte_ring_rts {  // Real-Time Scatter
    // 每个字段单独对齐到 Cache Line
    RTE_ALIGN_CACHE volatile uint32_t prod.head;
    char pad0[64 - sizeof(uint32_t)];
    volatile uint32_t prod.tail;
    char pad1[64 - sizeof(uint32_t)];
    volatile uint32_t cons.head;
    char pad2[64 - sizeof(uint32_t)];
    volatile uint32_t cons.tail;
};
```

### 3.3 Mbuf 中的 False Sharing

```c
// DPDK mbuf 结构中的 False Sharing

struct rte_mbuf {
    // 热点字段 (频繁访问)
    volatile uint16_t refcnt;       // 引用计数 - CACHE_LINE_SIZE 边界
    volatile uint8_t nb_segs;       // 分段数
    volatile uint8_t pool;          // 来源 pool

    // 再次访问可能触发 False Sharing
    struct rte_mbuf_bufpool {
        void *pool;
        uint16_t buf_iova;
    } buf_addr;

    // 其他字段...
} __rte_cache_aligned;

// 问题: 如果多个核同时修改 refcnt
// refcnt 在同一 Cache Line 上的变量会被影响

// 解决方案: 使用原子操作
static inline uint16_t
rte_pktmbuf_refcnt_update(struct rte_mbuf *m, int16_t val)
{
    // 原子加，避免 False Sharing
    return __atomic_add_fetch(&m->refcnt, val, __ATOMIC_ACQ_REL);
}

// 但 refcnt 更新本身仍是热点

// 更深层次的问题: mbuf 释放时的 Cache 抖动
void
mbuf_free_batch(struct rte_mbuf **mbufs, int nb_mbufs)
{
    for (int i = 0; i < nb_mbufs; i++) {
        // 每个 mbuf 的 refcnt 在不同 Cache Line
        // 但如果它们来自同一个 pool...

        struct rte_mempool *mp = rte_mbuf_from_pool(mbufs[i]);

        // mpool 的 stats 可能是 False Sharing 热点
        // stats->put_common_count 在同一 Cache Line
    }
}
```

### 3.4 解决 False Sharing

```c
// 解决方案 1: Cache Line 对齐

struct aligned_data {
    uint64_t counter;

    // 填充到 Cache Line 边界
    char pad[64 - sizeof(uint64_t)];
} __attribute__((aligned(64)));

// 每个核使用独立的 Cache Line
struct percpu_counter {
    uint64_t ALIGNED(64) value;    // 每个核独占一行
};

// 解决方案 2: 线程局部变量 (最简单)

__thread uint64_t local_counter = 0;  // TLS (Thread Local Storage)

// 每个线程有独立的副本，不存在共享

// 解决方案 3: 批量聚合

struct batch_counter {
    // 批量计数，减少写入频率
    uint64_t batch_values[64] __attribute__((aligned(64)));
    uint32_t batch_index;
    char pad[64 - 64*8 - 4];  // 填满一行
};

// 每个核先在本地累加，定期刷新到全局
void
batch_counter_add(struct batch_counter *cnt, uint64_t val)
{
    uint32_t idx = cnt->batch_index & 63;
    cnt->batch_values[idx] = val;
    cnt->batch_index++;

    // 每 64 次写入才刷新一次
    if (idx == 63) {
        flush_batch_to_global(cnt);
    }
}

// 解决方案 4: 使用 RTE_LCORE_FOREACH 隔离

// 给每个 lcore 分配独立的数据结构
struct lcore_data {
    uint64_t packets_processed;
    uint64_t bytes_processed;
    uint64_t cycles_elapsed;
} __rte_cache_aligned;

// 在 lcore 回调中使用
static int
lcore_main(void *arg)
{
    struct lcore_data *data = &lcore_data[rte_lcore_id()];

    // 每个 lcore 独立访问自己的数据
    // 不会触发 False Sharing
    while (!quit) {
        data->packets_processed++;
        // ...
    }
}
```

---

## 4. 预取 (Prefetch)

### 4.1 预取原理

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            预取原理                                         │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  时间局部性 (Temporal Locality):                                           │
│  ───────────────────────────                                               │
│  最近访问的数据可能很快再次访问                                             │
│  → 已加载到 Cache 的数据会保留                                             │
│                                                                             │
│  空间局部性 (Spatial Locality):                                            │
│  ───────────────────────────                                               │
│  访问某个地址后，很可能访问相邻地址                                         │
│  → 加载一个 Cache Line (64 bytes)                                          │
│                                                                             │
│  预取时机:                                                                 │
│  ────────                                                                  │
│                                                                             │
│  程序执行:                                                                 │
│  ──────────                                                                │
│                                                                             │
│  ──► 计算 ──► 计算 ──► 内存访问 ──► 计算 ──► 计算 ──► 内存访问 ──►         │
│        │         │           │             │           │                 │
│        │         │           │             │           │                 │
│        │    预取窗口    预取的数据到达        │    预取窗口                  │
│        │      (100+ cycles)         │           │                             │
│                                                                             │
│  预取发挥作用的条件:                                                        │
│  1. 计算和内存访问可以重叠                                                  │
│  2. 预取提前足够的周期 (通常 100-200 cycles)                                │
│  3. 数据访问模式可预测                                                     │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 4.2 软件预取指令

```c
// x86 预取指令

// 编译 intrinsic
#include <x86intrin.h>

// PREFETCHh (数据预取)
// __builtin_prefetch(addr, rw, locality)
// rw: 0 = read, 1 = write
// locality: 0-3, 0 = 无 temporal, 3 = 最高 temporal

// 预取用于读取
void
prefetch_read_example(int *array, int n)
{
    for (int i = 0; i < n; i++) {
        // 预取下一个元素 (如果顺序访问)
        if (i + 16 < n)
            __builtin_prefetch(&array[i + 16], 0, 3);  // read, high locality

        // 处理当前元素
        process(array[i]);
    }
}

// 预取用于写入 (非Temporal, 减少 cache 污染)
void
prefetch_write_example(int *dst, int *src, int n)
{
    for (int i = 0; i < n; i++) {
        // 预取源数据 (读)
        __builtin_prefetch(&src[i + 16], 0, 0);  // read, no locality

        // 预取目标位置 (写，避免 dirty cache line)
        __builtin_prefetch(&dst[i + 16], 1, 0);  // write, no locality

        dst[i] = process(src[i]);
    }
}

// 软件预取到 L1
static inline void
prefetch_to_l1(const void *addr)
{
    _mm_prefetch(addr, _MM_HINT_T0);
}

// 软件预取到 L2 (减少 L1 污染)
static inline void
prefetch_to_l2(const void *addr)
{
    _mm_prefetch(addr, _MM_HINT_T1);
}

// 软件预取到 L3 (仅部分 CPU 支持)
static inline void
prefetch_to_l3(const void *addr)
{
    _mm_prefetch(addr, _MM_HINT_T2);
}

// ARM 预取指令
// #include <arm_neon.h>
// __pld(addr)      // preload data
// __pldx(addr)     // preload data exclusive
```

### 4.3 DPDK 预取 API

```c
// lib/eal/include/rte_prefetch.h

// DPDK 预取封装

// 预取读 (无变更)
static inline void
rte_prefetch0(const void *addr)
{
    asm volatile("prefetcht0 %0" : : "m" (*(const void *)addr));
}

static inline void
rte_prefetch1(const void *addr)
{
    asm volatile("prefetcht1 %0" : : "m" (*(const void *)addr));
}

static inline void
rte_prefetch2(const void *addr)
{
    asm volatile("prefetcht2 %0" : : "m" (*(const void *)addr));
}

// 预取并声明写权限
static inline void
rte_prefetch_with_write(const void *addr)
{
    // x86 没有直接的预取写指令，需要结合其他操作
    _mm_prefetch(addr, _MM_HINT_T0);
}

// DPDK mbuf 预取
static inline void
rte_pktmbuf_prefetch_pkt(struct rte_mbuf *m)
{
    // 预取 mbuf 本身 (metadata)
    rte_prefetch0(m);

    // 预取数据缓冲区 (第一个 cache line)
    const void *buf_addr = rte_pktmbuf_mtod(m, const void *);
    rte_prefetch0(buf_addr);
}

// 预取多个 mbuf
static inline void
rte_pktmbuf_prefetch_pkt_bulk(struct rte_mbuf **mbufs, int nb)
{
    int i;

    // 预取前 4 个 mbuf 的 metadata
    for (i = 0; i < 4 && i < nb; i++)
        rte_prefetch0(mbufs[i]);

    // 预取前 4 个 mbuf 的数据
    for (i = 0; i < 4 && i < nb; i++) {
        if (mbufs[i])
            rte_prefetch0(rte_pktmbuf_mtod(mbufs[i], const void *));
    }
}
```

### 4.4 DPDK 中的预取模式

```c
// 模式 1: 批量接收时预取

uint16_t
dpdk_eth_rx_prefetch(uint16_t port_id, uint16_t queue_id,
                      struct rte_mbuf **mbufs, uint16_t nb_pkts)
{
    uint16_t i;

    // 预取 mbuf 描述符
    for (i = 0; i < PREFETCH_OFFSET && i < nb_pkts; i++) {
        rte_prefetch0(mbufs[i]);
    }

    // 处理已预取的包，同时预取后续包
    for (i = 0; i < nb_pkts; i++) {
        if (i + PREFETCH_OFFSET < nb_pkts)
            rte_prefetch0(mbufs[i + PREFETCH_OFFSET]);

        // 处理 mbufs[i] (此时已在 cache 中)
        process_packet(mbufs[i]);
    }
}

// 模式 2: Flow Table 查找预取

struct flow_entry {
    uint32_t flow_id;
    uint8_t action;
    uint8_t next_hop;
    uint16_t metadata;
};

struct flow_entry *
flow_table_lookup(struct flow_table *tbl, uint32_t flow_hash)
{
    uint32_t bucket = flow_hash & tbl->mask;
    struct flow_entry *entry = &tbl->entries[bucket];

    // 预取可能匹配 entry 的 cache line
    rte_prefetch0(entry);

    // 检查 4 个可能的 entry (4-way set assoc)
    for (int i = 0; i < 4; i++) {
        if (entry[i].flow_id == flow_hash) {
            return &entry[i];
        }
    }

    return NULL;
}

// 模式 3: Ring 操作预取

void
ring_enqueue_prefetch(struct rte_ring *r, void **obj_table, uint32_t n)
{
    uint32_t head = r->prod.head;
    uint32_t mask = r->mask;
    void **ring = r->ring;

    // 预取要写入的位置
    for (uint32_t i = 0; i < 8 && i < n; i++) {
        uint32_t idx = (head + i) & mask;
        rte_prefetch0(&ring[idx]);
    }

    // 入队
    for (uint32_t i = 0; i < n; i++) {
        uint32_t idx = (head + i) & mask;
        ring[idx] = obj_table[i];

        // 预取下一个
        if (i + 8 < n)
            rte_prefetch0(&ring[(head + i + 8) & mask]);
    }
}

// 模式 4: LPM 路由查找预取

struct lpm_table {
    struct lpm_rule *rules;
    uint8_t *tbl8;
};

uint8_t
lpm_lookup(struct lpm_table *tbl, uint32_t ip)
{
    // 查找步骤 1: 查主表
    uint32_t tbl24_idx = ip >> 8;
    uint8_t depth = tbl->tbl24[tbl24_idx].depth;

    if (depth == 0)
        return 0xFF;  // Not found

    // 预取 tbl8 (如果需要)
    if (depth > 24) {
        uint32_t tbl8_idx = tbl->tbl24[tbl24_idx].tbl8;
        rte_prefetch0(&tbl->tbl8[tbl8_idx]);
    }

    // ... 继续查找
}
```

### 4.5 自适应预取

```c
// 自适应预取策略

enum prefetch_strategy {
    PREFETCH_NONE = 0,
    PREFETCH_T0,          // 软件预取到 L1
    PREFETCH_T1,          // 软件预取到 L2
    PREFETCH_T2,          // 软件预取到 L3
    PREFETCH_HW,         // 硬件预取 (CPU 自动)
};

// 基于访问模式的启发式预取

static enum prefetch_strategy
adaptive_prefetch_strategy(const void *addr, size_t size, int is_sequential)
{
    if (!is_sequential)
        return PREFETCH_NONE;  // 随机访问不预取

    if (size < 64)
        return PREFETCH_T0;  // 小访问，预取到 L1

    if (size < 256)
        return PREFETCH_T1;  // 中等访问，预取到 L2

    return PREFETCH_T2;  // 大访问，预取到 L3
}

// 预取函数指针
typedef void (*prefetch_fn_t)(const void *addr);

static prefetch_fn_t
get_prefetch_fn(enum prefetch_strategy strategy)
{
    switch (strategy) {
    case PREFETCH_T0: return (prefetch_fn_t)_mm_prefetch_t0;
    case PREFETCH_T1: return (prefetch_fn_t)_mm_prefetch_t1;
    case PREFETCH_T2: return (prefetch_fn_t)_mm_prefetch_t2;
    default: return NULL;
    }
}
```

---

## 5. 内存访问模式优化

### 5.1 数据布局

```c
// 数据布局影响 Cache 命中率

// 方案 1: 数组结构 (AoS) vs 结构数组 (SoA)

struct particle_aos {
    double x, y, z;
    double vx, vy, vz;
    double mass;
};

struct particle_soa {
    double x[1024], y[1024], z[1024];
    double vx[1024], vy[1024], vz[1024];
    double mass[1024];
};

// AoS 访问 (不利于 SIMD 和顺序访问)
void
update_particles_aos(struct particle_aos *p, int n)
{
    for (int i = 0; i < n; i++) {
        p[i].x += p[i].vx;  // x, y, z 可能不在同一 Cache Line
        p[i].y += p[i].vy;
        p[i].z += p[i].vz;
    }
}

// SoA 访问 (有利于 Cache 预取和 SIMD)
void
update_particles_soa(struct particle_soa *p, int n)
{
    for (int i = 0; i < n; i++) {
        p->x[i] += p->vx[i];  // 顺序访问 x 数组
        p->y[i] += p->vy[i];  // 顺序访问 y 数组
        p->z[i] += p->vz[i];
    }
}

// 方案 2: 结构对齐和填充

struct aligned_struct {
    uint64_t field1;        // 8 bytes
    uint32_t field2;        // 4 bytes
    // 4 bytes padding (自动填充)
    double field3;          // 8 bytes (对齐到 8)
    // 4 bytes padding
    uint64_t field4;        // 8 bytes
} __attribute__((aligned(64)));  // 对齐到 Cache Line

// 方案 3: 热点数据分离

struct packet_stats {
    // 频繁访问的字段 (热点)
    uint64_t packet_count;
    uint64_t byte_count;
    uint32_t error_count;

    // 较少访问的字段 (冷点)
    uint64_t last_update_time;
    char ifname[32];
};

// 将热点字段放在结构体开头，保证在同一 Cache Line
```

### 5.2 批量内存操作

```c
// 批量内存操作减少 Cache Miss

// 错误: 逐个处理
void
process_packets_bad(struct rte_mbuf **pkts, int nb_pkts)
{
    for (int i = 0; i < nb_pkts; i++) {
        // 每个包单独处理
        struct ipv4_hdr *iph = rte_pktmbuf_mtod(pkts[i], struct ipv4_hdr *);
        process_ipv4(iph);
        rte_pktmbuf_free(pkts[i]);
    }
}

// 正确: 批量缓存友好处理
void
process_packets_good(struct rte_mbuf **pkts, int nb_pkts)
{
    int i;

    // 分批处理，每批预取
    #define BATCH_SIZE 32

    for (i = 0; i < nb_pkts; i += BATCH_SIZE) {
        int batch_end = RTE_MIN(i + BATCH_SIZE, nb_pkts);

        // 批量预取 mbuf
        for (int j = i; j < batch_end; j++) {
            rte_prefetch0(pkts[j]);
        }

        // 批量处理
        for (int j = i; j < batch_end; j++) {
            struct ipv4_hdr *iph = rte_pktmbuf_mtod(pkts[j], struct ipv4_hdr *);

            // 处理 (可能触发 Cache Miss，但预取减少等待)
            process_ipv4(iph);

            // 批量释放
            rte_pktmbuf_free(pkts[j]);
        }
    }
}

// 使用 rte_memcpy 批量拷贝
void
bulk_copy(struct rte_mbuf **src, struct rte_mbuf **dst, int nb)
{
    #define CACHE_LINE_LEN 64

    for (int i = 0; i < nb; i++) {
        void *src_data = rte_pktmbuf_mtod(src[i], void *);
        void *dst_data = rte_pktmbuf_mtod(dst[i], void *);
        size_t len = rte_pktmbuf_pkt_len(src[i]);

        // 优化拷贝: 每次处理一个 Cache Line
        size_t offset = 0;
        while (len >= CACHE_LINE_LEN) {
            rte_prefetch0(src_data + offset);
            rte_prefetch0(dst_data + offset);
            rte_memcpy(dst_data + offset, src_data + offset, CACHE_LINE_LEN);
            offset += CACHE_LINE_LEN;
            len -= CACHE_LINE_LEN;
        }

        if (len > 0)
            rte_memcpy(dst_data + offset, src_data + offset, len);
    }
}
```

### 5.3 NUMA 感知内存访问

```c
// NUMA 感知优化

#include <numa.h>
#include <numaif.h>

// 查询当前线程的 NUMA 节点
int
get_current_numa_node(void)
{
    return numa_node_of_cpu(sched_getcpu());
}

// NUMA 感知 mbuf 分配
struct rte_mbuf *
numa_aware_mbuf_alloc(void)
{
    int socket_id = rte_socket_id();  // 当前 lcore 的 socket

    // 从本地 socket 的 pool 分配
    struct rte_mempool *mp = mbuf_pools[socket_id];

    return rte_pktmbuf_alloc(mp);
}

// NUMA 感知内存预取
void
numa_aware_prefetch(const void *addr)
{
    int node = numa_node_of_addr(addr);

    if (node == get_current_numa_node()) {
        // 本地访问，预取到 L1
        rte_prefetch0(addr);
    } else {
        // 远程访问，预取到本地 Cache (如果值得)
        // 远程访问延迟约 100ns，本地约 80ns
        // 只有大块数据传输才值得
        rte_prefetch1(addr);
    }
}

// 批量 NUMA 数据传输
void
numa_bulk_transfer(void *dst, const void *src, size_t size, int dst_node)
{
    // 使用非统一内存访问优化传输
    void *local_dst;

    if (numa_node_of_addr(dst) != dst_node) {
        // 目标不在本地，先分配本地内存
        local_dst = numa_alloc_onnode(size, dst_node);
        memcpy(local_dst, src, size);
        memcpy(dst, local_dst, size);
        numa_free(local_dst, size);
    } else {
        // 直接传输
        memcpy(dst, src, size);
    }
}
```

---

## 6. rte_ring 与 rte_mempool 优化

### 6.1 rte_ring 的 Cache 友好设计

```c
// lib/ring/rte_ring.h 中的优化

// Producer/Consumer 分离减少竞争
struct rte_ring {
    // 写入侧 (producer)
    volatile uint32_t prod.head;
    volatile uint32_t prod.tail;

    // 读取侧 (consumer)
    volatile uint32_t cons.head;
    volatile uint32_t cons.tail;

    // ...
};

// 无锁入队 (一次 CAS)
static inline int
__rte_ring_mp_do_enqueue(struct rte_ring *r, void * const *obj_table,
                         unsigned int n, enum rte_ring_queue_behavior behavior)
{
    uint32_t prod_head, prod_next;
    uint32_t cons_tail;
    uint32_t free_entries;

    // 获取当前 producer head
    prod_head = r->prod.head;

    // 内存屏障保证顺序
    rte_smp_rmb();

    // 计算可用空间
    cons_tail = r->cons.tail;
    free_entries = (r->mask + 1) + cons_tail - prod_head;

    if (n > free_entries)
        return 0;

    // 预取将要写入的 slot
    for (unsigned int i = 0; i < n; i++)
        rte_prefetch0(&r->ring[(prod_head + i) & r->mask]);

    // 更新 producer head
    prod_next = prod_head + n;

    // CAS 更新 (原子操作)
    if (rte_atomic32_cmpset(&r->prod.head, prod_head, prod_next))
        break;

    // 失败则重试
}

// 批量预取优化入队
static inline void
__rte_ring_do_enqueue_prefetch(struct rte_ring *r, uint32_t prod_head, int n)
{
    for (int i = 0; i < RTE_RING_QUARTER_SIZE && i < n; i++)
        rte_prefetch0(&r->ring[(prod_head + i) & r->mask]);
}
```

### 6.2 rte_mempool 优化

```c
// lib/mempool/rte_mempool.h

// mbuf pool 与 cache
struct rte_mempool {
    // ...
    uint32_t cache_size;                  // per-lcore cache 大小
    struct rte_mempool_cache *cache[];    // per-lcore cache

    // 背靠背对象存储 (减少 Cache Miss)
    void *rg[0];                          // ring 对象
};

// Per-lcore object cache
struct rte_mempool_cache {
    uint32_t len;                         // cache 中对象数
    void *objs[cache_size];               // 对象指针
};

// 从 local cache 获取 (无锁)
static inline void *
mempool_get_from_cache(struct rte_mempool *mp)
{
    struct rte_mempool_cache *c = &mp->cache[rte_lcore_id()];

    if (c->len == 0)
        return NULL;

    c->len--;
    void *obj = c->objs[c->len];

    // 预取下一个
    if (c->len > 0)
        rte_prefetch0(c->objs[c->len - 1]);

    return obj;
}

// 批量获取 (触发 global pool 获取)
static inline int
mempool_get_bulk(struct rte_mempool *mp, void **obj_table, unsigned int n)
{
    // 先从 local cache 获取
    struct rte_mempool_cache *c = &mp->cache[rte_lcore_id()];

    // 如果 cache 有足够对象
    if (c->len >= n) {
        for (unsigned int i = 0; i < n; i++) {
            // 批量预取
            if (i < 8)
                rte_prefetch0(c->objs[c->len - 1 - i]);
        }

        memcpy(obj_table, &c->objs[c->len - n], n * sizeof(void *));
        c->len -= n;
        return 0;
    }

    // cache 不足，从 global ring 获取
    return mempool_get_from_ring(mp, obj_table, n);
}
```

---

## 7. 性能分析与调优

### 7.1 perf 工具

```bash
# 使用 perf 分析 Cache 性能

# 基础统计
perf stat -e cycles,instructions,L1-dcache-loads,L1-dcache-misses,L1-dcache-load-misses ./dpdk_app

# 高级 Cache 分析
perf stat -e cache-references,cache-misses,branch-misses \
         -e L1-dcache-load-misses,L1-dcache-loads \
         -e L1-icache-load-misses,L1-icache-loads \
         ./dpdk_app

# 使用 PMU 计数器
perf record -e cpu/event=0x08,umask=0x01,name=L1D_REPLACEMENT/ \
            -e cpu/event=0x08,umask=0x02,name=L1D_WB_REPLACEMENT/ \
            ./dpdk_app

perf report --stdio

# 火焰图
perf record -F 99 -g ./dpdk_app
perf script | ./FlameGraph/stackcollapse-perf.pl | ./FlameGraph/flamegraph.pl > cache.svg
```

### 7.2 内存带宽分析

```c
// 内存带宽分析

#include <emmintrin.h>

// 检测内存带宽
struct memory_bandwidth {
    uint64_t cycles;
    uint64_t bytes;
};

// 简单带宽测试
double
measure_memory_bandwidth(void *addr, size_t size, int iterations)
{
    uint64_t start, end;

    start = __rdtsc();

    for (int i = 0; i < iterations; i++) {
        // 顺序读取
        _mm_stream_load_si128((__m128i *)addr);
    }

    end = __rdtsc();

    uint64_t cycles = end - start;
    double bandwidth_gbps = (double)size * iterations / cycles / 1e9;

    return bandwidth_gbps;
}

// DPDK 提供的带宽统计
void
print_dpdk_memory_stats(void)
{
    struct rte_mem_config *mcfg = rte_eal_get_configuration()->mem_config;

    printf("Memory channels: %d\n", mcfg->nchannel);
    printf("NUMA nodes: %d\n", mcfg->numa_count);

    // 每个 socket 的内存
    for (int i = 0; i < mcfg->numa_count; i++) {
        printf("Socket %d: %lu MB\n", i,
               mcfg->memseg[i].len / 1024 / 1024);
    }
}
```

### 7.3 Cache 友好的代码模式

```c
// 模式 1: 热点循环展开
void
process_hot_loop_unrolled(struct rte_mbuf **pkts, int nb)
{
    int i;

    // 每次处理 4 个包，减少循环开销
    for (i = 0; i < nb - 3; i += 4) {
        // 预取 4 个包
        rte_prefetch0(pkts[i + 4]);
        rte_prefetch0(pkts[i + 5]);
        rte_prefetch0(pkts[i + 6]);
        rte_prefetch0(pkts[i + 7]);

        // 处理
        process_ipv4(rte_pktmbuf_mtod(pkts[i], struct ipv4_hdr *));
        process_ipv4(rte_pktmbuf_mtod(pkts[i+1], struct ipv4_hdr *));
        process_ipv4(rte_pktmbuf_mtod(pkts[i+2], struct ipv4_hdr *));
        process_ipv4(rte_pktmbuf_mtod(pkts[i+3], struct ipv4_hdr *));
    }

    // 处理剩余包
    for (; i < nb; i++) {
        process_ipv4(rte_pktmbuf_mtod(pkts[i], struct ipv4_hdr *));
    }
}

// 模式 2: 分离热点和冷点
void
process_with_separation(struct rte_mbuf **pkts, int nb)
{
    struct ipv4_hdr *headers[256];
    uint16_t lengths[256];

    // 提取热点数据到连续数组 (Cache 友好)
    for (int i = 0; i < nb; i++) {
        headers[i] = rte_pktmbuf_mtod(packets[i], struct ipv4_hdr *);
        lengths[i] = rte_pktmbuf_pkt_len(packets[i]);
    }

    // 处理连续数组 (全部在 Cache 中)
    for (int i = 0; i < nb; i++) {
        process_header(headers[i], lengths[i]);
    }

    // 释放 mbuf (冷路径)
    for (int i = 0; i < nb; i++) {
        rte_pktmbuf_free(packets[i]);
    }
}

// 模式 3: 使用 restrict 提示编译器无别名
void
copy_with_restrict(uint64_t *restrict dst, const uint64_t *restrict src, int n)
{
    // 编译器知道 dst 和 src 不重叠，可以更激进优化
    for (int i = 0; i < n; i++)
        dst[i] = src[i];
}
```

---

## 8. 完整使用示例

### 8.1 DPDK Packet Processing Pipeline

```c
// 优化后的 DPDK 包处理流水线

#define BATCH_SIZE 32
#define PREFETCH_OFFSET 8

struct lcore_conf {
    uint16_t port_id;
    uint16_t queue_id;

    // 统计 (per-lcore，避免 False Sharing)
    struct {
        uint64_t packets;
        uint64_t bytes;
        uint64_t dropped;
    } stats __rte_cache_aligned;

    // Flow table (per-lcore)
    struct flow_table *ft;
};

static void
pkt_processing_pipeline(struct lcore_conf *conf)
{
    struct rte_mbuf *pkts[BATCH_SIZE];
    struct flow_entry *flows[BATCH_SIZE];

    while (!quit) {
        // 1. 接收批量包
        uint16_t nb_rx = rte_eth_rx_burst(conf->port_id, conf->queue_id,
                                           pkts, BATCH_SIZE);

        if (nb_rx == 0)
            continue;

        // 2. 预取包数据
        for (int i = 0; i < PREFETCH_OFFSET && i < nb_rx; i++) {
            rte_prefetch0(pkts[i]);
            rte_prefetch0(rte_pktmbuf_mtod(pkts[i], void *));
        }

        // 3. Flow 查找 (预取 Flow Table Entry)
        for (int i = 0; i < nb_rx; i++) {
            if (i + PREFETCH_OFFSET < nb_rx) {
                uint32_t hash = flow_hash(pkts[i + PREFETCH_OFFSET]);
                flow_table_prefetch(conf->ft, hash);
            }

            flows[i] = flow_table_lookup(conf->ft, pkts[i]);
        }

        // 4. 批量处理
        for (int i = 0; i < nb_rx; i++) {
            if (flows[i]) {
                // 命中 flow
                process_with_flow(pkts[i], flows[i]);
                conf->stats.packets++;
                conf->stats.bytes += rte_pktmbuf_pkt_len(pkts[i]);
            } else {
                // Miss flow (慢路径)
                flows[i] = flow_table_create(pkts[i]);
                if (flows[i])
                    process_with_flow(pkts[i], flows[i]);
                else
                    rte_pktmbuf_free(pkts[i]);

                conf->stats.dropped++;
            }
        }

        // 5. 发送
        uint16_t nb_tx = rte_eth_tx_burst(conf->port_id, conf->queue_id,
                                           pkts, nb_rx);

        // 释放未发送的包
        for (uint16_t i = nb_tx; i < nb_rx; i++) {
            rte_pktmbuf_free(pkts[i]);
        }
    }
}
```

### 8.2 延迟测量

```c
// Cache 友好的延迟测量

struct latency_measure {
    uint64_t total_cycles;
    uint64_t min_cycles;
    uint64_t max_cycles;
    uint64_t samples;
};

static inline void
latency_add_sample(struct latency_measure *m, uint64_t cycles)
{
    m->total_cycles += cycles;
    if (cycles < m->min_cycles || m->samples == 0)
        m->min_cycles = cycles;
    if (cycles > m->max_cycles)
        m->max_cycles = cycles;
    m->samples++;
}

static inline double
latency_avg_ns(struct latency_measure *m, double cpu_freq_ghz)
{
    if (m->samples == 0)
        return 0;
    return (double)m->total_cycles / m->samples / cpu_freq_ghz;
}

// 使用 TSC 测量
static inline uint64_t
rdtsc_ordered(void)
{
    uint32_t lo, hi;
    __asm__ __volatile__ (
        "lfence\n\t"
        "rdtsc\n\t"
        "lfence\n\t"
        : "=a" (lo), "=d" (hi)
    );
    return ((uint64_t)hi << 32) | lo;
}

// 测量内存访问延迟
void
measure_memory_latency(void)
{
    struct latency_measure m = {0};
    int *array = rte_malloc(NULL, 4096 * sizeof(int), 64);
    int *ptr = array;

    // 热身
    for (int i = 0; i < 1000; i++)
        *ptr++;

    // 测量
    for (int i = 0; i < 100000; i++) {
        uint64_t start = rdtsc_ordered();
        *ptr = i;
        uint64_t end = rdtsc_ordered();

        latency_add_sample(&m, end - start);

        // 步长 64 bytes (一个 Cache Line)
        ptr = (int *)((char *)ptr + 64);
        if (ptr >= (int *)((char *)array + 4096))
            ptr = array;
    }

    printf("Cache access latency:\n");
    printf("  Min: %lu cycles\n", m.min_cycles);
    printf("  Max: %lu cycles\n", m.max_cycles);
    printf("  Avg: %.2f ns\n", latency_avg_ns(&m, 3.0));  // 假设 3GHz

    rte_free(array);
}
```

---

## 9. 小结

本章核心要点：

1. **Cache 层次**：L1 (~1ns, 32-64KB) → L2 (~4ns, 256KB) → L3 (~15ns, 8-64MB) → Memory (~100ns)，访问延迟差距可达 100 倍。

2. **Cache Line**：64 bytes 为标准单位，空间局部性是优化的关键。

3. **MESI 协议**：Modified/Exclusive/Shared/Invalid 状态，总线嗅探保证一致性，写回比写直达更高效。

4. **False Sharing**：多个核修改同一 Cache Line 的不同变量，导致意外缓存失效，性能下降可达 10-50x。

5. **False Sharing 解决**：Cache Line 对齐、线程局部变量、批量聚合、per-lcore 数据结构。

6. **软件预取**：`__builtin_prefetch()` / `_mm_prefetch()`，T0/T1/T2 不同层级。

7. **DPDK 预取**：`rte_prefetch0/1/2()`、`rte_pktmbuf_prefetch_pkt()`。

8. **预取策略**：顺序访问预取有效，随机访问无效；预取窗口需要 100-200 cycles 提前量。

9. **数据布局**：SoA (结构数组) 比 AoS (数组结构) 更利于 Cache 预取和 SIMD。

10. **NUMA 感知**：本地 socket 访问延迟远低于跨 socket 访问，DPDK 提供 socket 感知的内存分配。

11. **rte_ring/rte_mempool**：使用 per-lcore cache 减少锁竞争，批量预取优化吞吐量。

12. **性能分析**：使用 `perf stat`、`perf record` 分析 L1/L2/L3 Miss 率。

**下一篇预告**：[[2026-04-09-dpdk-deep-dive-ch26-numa-optimization|第二十六章]]将讲解 NUMA 亲和性优化——local/remote 访问、内存分配策略、多核调度。

---

> [!tip] 参考文献
> - Intel, "Intel 64 and IA-32 Architectures Optimization Reference Manual"
> - AMD, "AMD64 Architecture Programming Manual"
> - "What Every Programmer Should Know About Memory", Ulrich Drepper
> - Intel, "DPDK Performance Optimization", https://doc.dpdk.org/guides/prog_guide/perf_opt.html
> - "False Sharing", https://www.justsoftwaresolutions.co.uk/threading/false-sharing.html
> - "Software Prefetching", https://software.intel.com/security-psirt
