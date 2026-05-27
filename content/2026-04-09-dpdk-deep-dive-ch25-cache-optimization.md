---
title: "DPDK 深度探索 (二十五)：Cache 优化：False Sharing 与预取"
date: 2026-04-09
tags: [dpdk, series, cache, false-sharing, prefetch, numa, memory, performance, mbuf, rte_ring]
description: "深入理解 CPU Cache 机制与 DPDK 性能优化——Cache 层次、False Sharing、预取策略、内存访问模式、Mbuf 缓存优化"
---

> [!info] DPDK 深度探索系列 0. [[2026-04-09-dpdk-deep-dive-series-index|全栈学习路径总览]]
> 1-24. 前二十四章已完成 25. **第二十五章：Cache 优化——False Sharing 与预取**

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
// Cache Line = 64 bytes (示意，非真实硬件结构)

struct cache_line {
    uint8_t data[64];               // 数据负载

    // Tag (用于匹配地址)
    uint64_t tag: 48;              // 物理地址的高位部分

    // 状态位
    uint8_t valid: 1;              // 有效位
    uint8_t dirty: 1;              // 脏位 (write-back)
    uint8_t lru: 6;                // LRU 替换信息
};

// 地址分解 (示意，具体位数取决于 cache 配置)
// ─────────────
// 物理地址: [tag][index][offset]
//           ?? bits  ?? bits  6 bits
//
// Cache 结构:
// - Offset: 6 bits (64 bytes per line)
// - Index:  取决于 cache 容量和关联性
// - Tag:    剩余位

// 直接映射缓存 (1-way)
struct direct_mapped_cache {
    struct cache_line sets[4096];  // 每组一行
};

// N-way 组相联缓存
struct set_associative_cache {
    struct cache_line sets[4096][8];  // 8-way
    uint8_t lru_state[4096][8];       // LRU 状态
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

    // 情况 3: 多核并发写同一 cache line → Coherence Traffic (见 False Sharing)
    // 注意: 这不是 Conflict Miss，而是缓存一致性协议引起的额外开销
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
│                    M ──► S (CPU0 将数据通过 interconnect 传给 CPU1)       │
│                                                                             │
│  CPU0 写 A ──► S ──► M (CPU0 发出 invalidate，CPU1 的 S → I)             │
│                                                                             │
│  总线嗅探: 每个核监听总线上的内存访问，发现冲突时响应                       │
│                                                                             │
│  写直达 vs 写回:                                                           │
│  ─────────────────                                                          │
│  Write-through: 每次写直达内存 (慢)                                        │
│  Write-back: 写回 cache，miss 时写回 (快，但复杂)                         │
│                                                                             │
│  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ │
│  MESI 核心规则 (理解多核性能的关键)                                         │
│  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ │
│                                                                             │
│  规则 1: 同一 Cache Line 可以有多个 Reader                                  │
│          → S (Shared) 状态可以多个核同时持有                                │
│                                                                             │
│  规则 2: 同一 Cache Line 只能有一个 Writer                                 │
│          → M (Modified) 状态必须独占                                       │
│          → 写入 = Cache Line Ownership Transfer                            │
│                                                                             │
│  核心洞察:                                                                 │
│  ─────────                                                                 │
│  "读" 是廉价的: 只需获得 S 状态，无需 invalidate 他人                      │
│  "写" 是昂贵的: 必须获得 M ownership，需要 invalidate 所有其他持有者       │
│  → 获得 M ownership 的代价远大于获得 S 状态                               │
│  → 写-写 共享比 读-写 共享的性能损害大得多                                │
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
│  问题 (写-写冲突):                                                        │
│  ────────────────                                                          │
│  CPU0 写 counter0 → CPU0 发出 RFO，获得 M                                 │
│  CPU1 写 counter1 → CPU1 发出 RFO → CPU0 的 M → I → CPU1 获得 M         │
│  CPU0 写 counter0 → CPU0 发出 RFO → CPU1 的 M → I → CPU0 获得 M         │
│  ... M ↔ I 疯狂 bouncing，每次写入都触发 ownership transfer               │
│                                                                             │
│  结果: 两个线程各自只修自己的变量，但性能下降 10-50x                       │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

> [!important] False Sharing 的本质是写写冲突，不是"访问同一变量"
> 硬件只看 Cache Line，不看字段。两个核频繁**写**同一个 Cache Line 的不同字段，
> 才会导致严重的性能问题。如果只是一个核写、其他核只读，影响小得多。

```
┌─────────────────────────────────────────────────────────────────────────────┐
│               写写冲突 vs 读写共享 — 性能差距巨大                           │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  场景 A: 写-写共享 (最糟糕)                                               │
│  ══════════════════════════                                                │
│                                                                             │
│  CPU0 写 counter0 ──► CPU0 获得 M ──► invalidate CPU1                    │
│  CPU1 写 counter1 ──► CPU1 获得 M ──► invalidate CPU0                    │
│  CPU0 写 counter0 ──► CPU0 获得 M ──► invalidate CPU1                    │
│  CPU1 写 counter1 ──► CPU1 获得 M ──► invalidate CPU0                    │
│                                                                             │
│  Cache Line 在两个核之间疯狂 bouncing:                                     │
│  CPU0: M ──► I ──► M ──► I ──► M ...                                     │
│  CPU1: I ──► M ──► I ──► M ──► I ...                                     │
│                                                                             │
│  每次写入都触发完整的 ownership transfer!                                  │
│  性能下降: 10-50x                                                          │
│                                                                             │
│  场景 B: 读-写共享 (较便宜)                                               │
│  ══════════════════════════                                                │
│                                                                             │
│  CPU0 写 counter ──► CPU0 获得 M                                          │
│  CPU1 读 counter  ──► CPU1 获得 S (数据从 CPU0 传过来)                   │
│  CPU0 写 counter ──► CPU0 获得 M (invalidate CPU1 的 S)                  │
│  CPU1 读 counter  ──► CPU1 获得 S (再次从 CPU0 传过来)                   │
│                                                                             │
│  只有写的那一方触发 invalidate                                            │
│  读的一方只需 S 状态，不需要 ownership transfer                           │
│  ownership 迁移频率大大降低                                                │
│  性能下降: ~2-3x (比写-写好一个数量级)                                    │
│                                                                             │
│  结论:                                                                     │
│  ──────                                                                    │
│  真正昂贵的不是"读"，而是"获得写权限 (M ownership)"                       │
│  避免多核频繁写同一个 Cache Line 才是关键                                 │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

> [!example] 实测：False Sharing 的性能影响
> 以下 Rust 示例对比了 8 个线程各自更新独立计数器时，有无 Cache Line 对齐的差异
> ([完整源码](https://github.com/hlwqds/hl-ljj-quartz/blob/v4/practice/cpu_cache/false_sharing/false_sharing.rs))：
>
> ```rust
> // Bad: 8 个 AtomicU64 紧挨着，多个线程的 counter 共享 Cache Line
> struct Bad {
>     counters: [AtomicU64; 8],  // 8 × 8B = 64B，刚好一个 Cache Line!
> }
>
> // Good: 每个 counter 独占一个 Cache Line
> #[repr(align(64))]
> struct Padded(AtomicU64);     // 8B 数据 + 56B padding = 64B
>
> struct Good {
>     counters: [Padded; 8],    // 每个 counter 独占一行
> }
> ```
>
> **实测结果 (8 threads, 100M iterations/thread)：**
>
> | 版本                   | 耗时      | 说明                                                    |
> | ---------------------- | --------- | ------------------------------------------------------- |
> | `Bad` (无 padding)     | **6.99s** | 8 个 counter 挤在 1 个 Cache Line 上，M↔I 疯狂 bouncing |
> | `Good` (cache aligned) | **0.66s** | 每个 counter 独占 Cache Line，无 False Sharing          |
>
> 差距约 **10x**，完全是 Cache Line bouncing 造成的——每个线程只写自己的变量，但硬件不认字段。

### 3.2 DPDK rte_ring 如何解决 False Sharing

> [!important] DPDK 已经解决了 rte_ring 的 False Sharing
> 现代 DPDK 的 `rte_ring` 通过 `RTE_CACHE_GUARD` 和 `__rte_cache_aligned` 将 producer
> 和 consumer 指针放在**不同的 Cache Line** 上，从根本上避免了 False Sharing。

先看一个**没有**做 Cache Line 分离的朴素环形队列（反面教材）：

```c
// 错误示例: 没有 Cache Line 分离的环形队列
// prod 和 cons 的 head/tail 紧挨着，在同一个 Cache Line 上

struct naive_ring {
    volatile uint32_t prod_head;    // 生产头  ┐
    volatile uint32_t prod_tail;    // 生产尾  ├─ 可能在同一 Cache Line
    volatile uint32_t cons_head;    // 消费头  ├─ producer 写时
    volatile uint32_t cons_tail;    // 消费尾  ┘─ consumer 的缓存失效!
    uint32_t size;
    uint32_t mask;
    void **ring;
};

// 问题: producer 更新 prod_tail 时，consumer 缓存中同一 Cache Line 失效
// 反之亦然。两个核虽然操作不同字段，却互相拖累
```

再看 DPDK 的**真实设计**（`lib/ring/rte_ring_core.h`）：

```c
// DPDK 真实的 rte_ring 结构 (简化展示)

struct rte_ring_headtail {
    volatile RTE_ATOMIC(uint32_t) head;  // prod/consumer head
    volatile RTE_ATOMIC(uint32_t) tail;  // prod/consumer tail
    union {
        enum rte_ring_sync_type sync_type;  // 同步模式
        uint32_t single;                    // deprecated: 单生产/消费标志
    };
};

struct rte_ring {
    char name[RTE_RING_NAMESIZE];
    int flags;
    const struct rte_memzone *memzone;
    uint32_t size;
    uint32_t mask;
    uint32_t capacity;

    RTE_CACHE_GUARD;  // ① 插入空 Cache Line 作为隔离

    // ② Producer 状态，独占一个 Cache Line
    union __rte_cache_aligned {
        struct rte_ring_headtail prod;        // 默认模式
        struct rte_ring_hts_headtail hts_prod; // Head-Tail Sync
        struct rte_ring_rts_headtail rts_prod; // Relaxed Tail Sync
    };

    RTE_CACHE_GUARD;  // ③ 再次插入空 Cache Line

    // ④ Consumer 状态，独占另一个 Cache Line
    union __rte_cache_aligned {
        struct rte_ring_headtail cons;
        struct rte_ring_hts_headtail hts_cons;
        struct rte_ring_rts_headtail rts_cons;
    };

    RTE_CACHE_GUARD;  // ⑤ ring[] 数据区之前再隔离
};
```

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                   rte_ring 的 Cache Line 布局                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  Cache Line 0: name, flags, size, mask, capacity                           │
│  ─────────────────────────────────────────────────────                     │
│  Cache Line 1: [RTE_CACHE_GUARD — 空，防止与 prod 冲突]                    │
│  ─────────────────────────────────────────────────────                     │
│  Cache Line 2: prod.head, prod.tail, sync_type    ← producer 独占         │
│  ─────────────────────────────────────────────────────                     │
│  Cache Line 3: [RTE_CACHE_GUARD — 空，防止 prod/cons 冲突]                 │
│  ─────────────────────────────────────────────────────                     │
│  Cache Line 4: cons.head, cons.tail, sync_type    ← consumer 独占         │
│  ─────────────────────────────────────────────────────                     │
│  Cache Line 5: [RTE_CACHE_GUARD — 空，防止与 ring[] 冲突]                  │
│  ─────────────────────────────────────────────────────                     │
│  Cache Line 6+: ring[0], ring[1], ...             ← 数据区                │
│                                                                             │
│  关键: producer 只频繁写 Cache Line 2                                     │
│        consumer 只频繁写 Cache Line 4                                     │
│        二者永远不会因为对方而触发 Cache Line 失效                          │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

> [!example] 实测：Ring 的 prod/cons 分离 Cache Line
> 以下 Rust 示例模拟了 DPDK ring 的核心结构，对比 prod/cons 在同一 Cache Line
> 和分离 Cache Line 的性能差异
> ([完整源码](https://github.com/hlwqds/hl-ljj-quartz/blob/v4/practice/cpu_cache/false_sharing/ring_false_sharing.rs))：
>
> ```rust
> // Bad: prod_head, prod_tail, cons_head, cons_tail 紧挨着
> struct BadRing {
>     prod_head: AtomicU64,  // ┐
>     prod_tail: AtomicU64,  // ├─ 全在同一 Cache Line，producer 写时 consumer 被迫失效
>     cons_head: AtomicU64,  // ├─ 反之亦然
>     cons_tail: AtomicU64,  // ┘
> }
>
> // Good: prod 和 cons 各自对齐到 Cache Line
> #[repr(align(64))]
> struct ProducerState { head: AtomicU64, tail: AtomicU64 }  // 独占一行
>
> #[repr(align(64))]
> struct ConsumerState { head: AtomicU64, tail: AtomicU64 }  // 独占一行
>
> struct GoodRing {
>     prod: ProducerState,  // producer 高频写这一行
>     cons: ConsumerState,  // consumer 高频写另一行
> }
> ```
>
> **实测结果 (4 producers + 4 consumers, 20M iterations/thread)：**
>
> | 版本                       | 耗时      | 说明                                                              |
> | -------------------------- | --------- | ----------------------------------------------------------------- |
> | `BadRing` (无分离)         | **26.5s** | producer 写 prod_tail 时 consumer 的 Cache Line 被反复 invalidate |
> | `GoodRing` (cache aligned) | **23.8s** | prod/cons 各占独立 Cache Line，ownership 迁移大幅减少             |
>
> Ring 场景下差距比纯 counter 小，因为 producer/consumer 还需要**读**对方的 tail（S 状态即可），
> 不像纯写-写那样每次都触发 invalidate。这正好印证了上面的分析：**写-写最差，读-写好很多**。

DPDK 还提供了多种同步模式，可在创建 ring 时选择：

```c
// lib/ring/rte_ring_core.h

enum rte_ring_sync_type {
    RTE_RING_SYNC_MT,     // 多线程安全 (默认模式，使用 CAS)
    RTE_RING_SYNC_ST,     // 单线程 (无锁，最快)
    RTE_RING_SYNC_MT_RTS, // 多线程 Relaxed Tail Sync (放宽尾同步)
    RTE_RING_SYNC_MT_HTS, // 多线程 Head-Tail Sync (头尾一起原子更新)
};

// 创建时可分别指定 enqueue/dequeue 侧同步模式
struct rte_ring *r = rte_ring_create("my_ring", 1024,
    rte_socket_id(),  // NUMA socket
    RING_F_MP_RTS_ENQ);  // 使用 RTS 模式入队
```

> [!tip] 什么时候用哪种同步模式？
>
> - `RTE_RING_SYNC_ST`：单生产者或单消费者侧使用，无锁最快
> - `RTE_RING_SYNC_MT`：通用多线程，使用 CAS
> - `RTE_RING_SYNC_MT_RTS`：多生产者/多消费者，放宽 tail 同步以避免在 tail 上自旋等待
> - `RTE_RING_SYNC_MT_HTS`：多生产者/多消费者，head/tail 作为 64 位原子变量一起更新

```
┌─────────────────────────────────────────────────────────────────────────────┐
│              rte_ring 四种同步模式详解                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ① RTE_RING_SYNC_ST — 单线程模式                                          │
│  ════════════════════════════                                               │
│                                                                             │
│  Producer (唯一):                    Consumer (唯一):                      │
│  ┌─────────────────────────────┐     ┌─────────────────────────────┐      │
│  │ 1. prod.head += n  (普通写) │     │ 1. cons.head += n  (普通写) │      │
│  │ 2. ring[slot] = data       │     │ 2. data = ring[slot]       │      │
│  │ 3. prod.tail = head (普通写)│     │ 3. cons.tail = head (普通写)│      │
│  └─────────────────────────────┘     └─────────────────────────────┘      │
│                                                                             │
│  零同步开销: 无 CAS、无 memory barrier、无自旋等待                        │
│  前提: 保证只有一个线程入队、一个线程出队                                 │
│                                                                             │
│  Ring 状态 (单线程模式，size=8):                                          │
│                                                                             │
│     prod.head = prod.tail = 5                                               │
│     cons.head = cons.tail = 2                                               │
│                                                                             │
│     Slot   [0]  [1]  [2]  [3]  [4]  [5]  [6]  [7]                         │
│           ┌────┬────┬────┬────┬────┬────┬────┬────┐                        │
│           │    │    │▓▓▓▓│▓▓▓▓│▓▓▓▓│    │    │    │                        │
│           └────┴────┴────┴────┴────┴────┴────┴────┘                        │
│                       ▲              ▲                                      │
│                   cons.tail=2    prod.tail=5                                │
│                                                                             │
│  区域说明:                                                                  │
│  ┌────┬────┐ ┌────┬────┬────┐ ┌────┬────┬────┐                            │
│  │ 已读 │ │ ▓▓数据▓▓ │ │  空闲  │                            │
│  │ 可复用│ │ 等待消费 │ │ 可写入 │                            │
│  └────┴────┘ └────┴────┴────┘ └────┴────┴────┘                            │
│   [0]  [1]    [2]  [3]  [4]    [5]  [6]  [7]                              │
│   ▲                                  ▲                                      │
│   └── cons.tail ────────── prod.tail ┘─►                                   │
│                                                                             │
│  单线程下 head 始终 == tail (没有并发操作，一步到位)                       │
│  consumer 只看 prod.tail=5，知道 slot 2~4 有数据可读                     │
│                                                                             │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ② RTE_RING_SYNC_MT — 标准多线程模式 (默认)                              │
│  ════════════════════════════════════════                                   │
│                                                                             │
│  多个 Producer 竞争入队 — 四步 CAS 协议:                                  │
│                                                                             │
│  Producer A:                          Producer B:                         │
│  ┌──────────────────────────────┐     ┌──────────────────────────────┐    │
│  │ ① CAS(prod.head, h, h+n)    │     │ ① CAS(prod.head, h, h+m)    │    │
│  │    成功! → 预留 slot h~h+n  │     │    失败! → 回到 ① 重试      │    │
│  │                              │     │ ①' CAS(prod.head, h', h'+m) │    │
│  │ ② ring[h..h+n] = data       │     │    成功! → 预留 h'~h'+m     │    │
│  │    (写入自己的 slot)         │     │                              │    │
│  │                              │     │ ② ring[h'..h'+m] = data     │    │
│  │ ③ 等待 prod.tail == h       │     │                              │    │
│  │    (等前面的 producer 完成)  │     │ ③ 等待 prod.tail == h'      │    │
│  │                              │     │    (等 A 先更新 tail!)       │    │
│  │ ④ prod.tail = h + n         │     │                              │    │
│  │    (轮到自己，更新 tail)     │     │ ④ prod.tail = h' + m        │    │
│  └──────────────────────────────┘     └──────────────────────────────┘    │
│                                                                             │
│  关键问题: Step ③ — 队头阻塞 (Head-of-Line Blocking)                    │
│  ════════════════════════════════════════════                               │
│                                                                             │
│  tail 必须按 CAS 成功的顺序更新:                                          │
│                                                                             │
│  时间 ─────────────────────────────────────────────────────────►          │
│                                                                             │
│  A: ─CAS─┤    慢写入...     ├─tail=4─┤                                    │
│  B: ───────CAS─┤ 快写入 ├──等 A tail──├─tail=8─┤                         │
│  C: ──────────────────CAS─┤ 写 ├────等 B tail────├─tail=12                │
│                          ▲                    ▲                             │
│                          │                    │                             │
│                     B 写完了但               C 也得等                      │
│                     必须等 A!                                              │
│                                                                             │
│  Ring 状态快照 (队头阻塞，size=16):                                       │
│                                                                             │
│  prod.head = 12  (A 预留 0-3, B 预留 4-7, C 预留 8-11)                  │
│  prod.tail = 0   (A 还没写完 → tail 卡住)                                │
│                                                                             │
│  Slot  [0]  [1]  [2]  [3]  [4]  [5]  [6]  [7]  [8]  [9]  [10] [11]      │
│       ┌────┬────┬────┬────┬────┬────┬────┬────┬────┬────┬────┬────┐      │
│       │ ?? │ ?? │ ?? │ ?? │▓D4▓│▓D5▓│▓D6▓│▓D7▓│    │    │    │    │      │
│       └────┴────┴────┴────┴────┴────┴────┴────┴────┴────┴────┴────┘      │
│        ▲    A 正在写入      ▲    B 已写完        ▲    C 还没写            │
│        │    (0-3)           │    (4-7)           │    (8-11)              │
│     tail=0              但 consumer              head=12                  │
│                          看不见!                                          │
│                                                                             │
│  各角色视角:                                                                │
│  ───────────                                                               │
│  Consumer:  看 prod.tail=0 → "没有数据可读"                               │
│  Producer B: 写完了 slot 4-7 → 等 prod.tail==4 → 但 A 还没更新 tail!     │
│  Producer A: 正在写 slot 0-3 → 写完才能更新 tail → 其他人才能动          │
│                                                                             │
│  虽然 B 的数据 (4-7) 已在 ring 中，但 tail=0 导致                        │
│  consumer 以为没有数据。这就是队头阻塞: A 卡住了所有人。                │
│                                                                             │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ③ RTE_RING_SYNC_MT_RTS — Relaxed Tail Sync                              │
│  ════════════════════════════════════════════                               │
│                                                                             │
│  解决 MT 模式的 tail 自旋等待: 写完者更新完成计数，最后完成者推进 tail    │
│  ════════════════════════════════════════════                               │
│                                                                             │
│  Producer A (CAS 获得 0-3, 写入慢):                                      │
│  ┌──────────────────────────────────────────────────────────┐             │
│  │ ① CAS(prod.head, h, h+n) → 成功                         │             │
│  │ ② ring[h..h+n] = data (写入中... 慢)                    │             │
│  │ ③ 更新 tail.cnt；若自己是最后完成者，则推进 tail.pos     │             │
│  └──────────────────────────────────────────────────────────┘             │
│                                                                             │
│  Producer B (CAS 获得 4-7, 写入快):                                      │
│  ┌──────────────────────────────────────────────────────────┐             │
│  │ ① CAS(prod.head, h', h'+m) → 成功                       │             │
│  │ ② ring[h'..h'+m] = data (写入完成! 快)                   │             │
│  │ ③ 更新 tail.cnt；A 未完成时不把 tail.pos 推过 A          │             │
│  └──────────────────────────────────────────────────────────┘             │
│                                                                             │
│  对比 MT vs RTS 时间线:                                                   │
│  ═════════════════════                                                     │
│                                                                             │
│  MT 模式 (严格顺序):                                                      │
│  A: ─CAS─┤     慢写入      ├──── tail=4 ────┤                            │
│  B: ───────CAS─┤ 快写 ├──────── 等 A ───────┤ tail=8 ──┤                │
│                     ▲                                                       │
│                     ╳ B 写完了但被 A 阻塞!                                │
│                                                                             │
│  RTS 模式 (relaxed tail update):                                          │
│  A: ─CAS(cnt=1)─┤     慢写入      ├──── tail.cnt=2, tail.pos=8 ──┤       │
│  B: ────────────CAS(cnt=2)─┤ 快写 ├──── tail.cnt=1, tail.pos=0 ──┤       │
│                                ▲                                            │
│                                ✓ B 不自旋等 A；但不会发布 A 前面的空洞     │
│                                                                             │
│  RTS 额外机制:                                                            │
│  ──────────────                                                            │
│  - head 和 tail 都携带 cnt/pos，使用 64-bit CAS 原子更新                  │
│  - 每个完成者都会推进 tail.cnt，表示一个 in-flight 操作完成               │
│  - 只有当 tail.cnt + 1 == head.cnt 时，说明当前线程是最后完成者           │
│    才把 tail.pos 推到 head.pos                                            │
│  - tail.pos 仍然表示 consumer 可见的连续完成边界，不允许跳过空洞          │
│                                                                             │
│  适用: 高竞争/过度订阅场景，多个 producer/consumer 频繁操作               │
│  代价: 每次操作需要额外一次 64-bit CAS，结构和推理更复杂                  │
│                                                                             │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ④ RTE_RING_SYNC_MT_HTS — Head-Tail Sync                                │
│  ════════════════════════════════════════════                               │
│                                                                             │
│  核心思想: head 和 tail 打包为 64 位原子变量                              │
│  ══════════════════════════════════════════                                 │
│                                                                             │
│         32 bits         │        32 bits                                   │
│  ┌─────────────────────┼─────────────────────┐                            │
│  │       head          │       tail           │  → 单个 uint64_t          │
│  └─────────────────────┼─────────────────────┘                            │
│          CAS 一次同时更新 head 和 tail                                     │
│                                                                             │
│  状态含义:                                                                 │
│  ──────────                                                                │
│  head == tail → 空闲 (idle)，没有操作进行                                 │
│  head >  tail → 操作进行中 (in-progress)                                  │
│                                                                             │
│  入队操作 (两步 CAS):                                                     │
│  ┌───────────────────────────────────────────────────────────────┐        │
│  │                                                               │        │
│  │  Step 1: 预留 slot                                           │        │
│  │  CAS(prod, {head=0, tail=0}, {head=n, tail=0})               │        │
│  │  → head 前进, tail 不动 → head != tail → "正在写"           │        │
│  │                                                               │        │
│  │  Step 2: 写入数据                                            │        │
│  │  ring[0..n] = data                                           │        │
│  │                                                               │        │
│  │  Step 3: 完成通知                                            │        │
│  │  CAS(prod, {head=n, tail=0}, {head=n, tail=n})               │        │
│  │  → tail 追上 head → head == tail → "写完了"                 │        │
│  │                                                               │        │
│  └───────────────────────────────────────────────────────────────┘        │
│                                                                             │
│  与 MT 的关键区别 — 严格串行化:                                          │
│  ═════════════════════════════════                                         │
│                                                                             │
│  MT 模式 (并行):                                                          │
│  A: ─CAS head─┤   write   ├───── tail ─────┤                             │
│  B: ───────────CAS head─┤   write   ├─tail─┤                             │
│     ← 两个 producer 可以同时写入不同 slot →                              │
│                                                                             │
│  HTS 模式 (串行):                                                         │
│  A: ─CAS{h,t}→{h+n,t}─┤ write ├─CAS{h+n,t}→{h+n,h+n}─                   │
│  B: ─────────────── 自旋等待 head==tail ──────────CAS─┤ write ├─CAS─      │
│     ← 同一时刻只有一个 producer 能操作 →                                 │
│                                                                             │
│  为什么需要串行?                                                           │
│  ────────────────                                                          │
│  ✓ 保证操作的严格顺序 (FIFO)                                              │
│  ✓ 适用于 ordered messaging、分布式 log                                   │
│  ✓ 更容易推理和调试 (同一时刻只有一个写者)                               │
│  ✗ 吞吐量低于 MT/RTS (无法并行写入)                                      │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

| 特性 | ST | MT | MT_RTS | MT_HTS |
|------|-----|-----|--------|--------|
| **同步机制** | 无 | CAS (32-bit) + tail 等待 | 2×64-bit CAS + relaxed tail | CAS (64-bit) |
| **原子操作/次** | 0 | 1 CAS + tail store | 2 CAS | 2 CAS |
| **并发写入** | N/A | 并行 | 并行 | 严格串行 |
| **tail 等待** | 无 | 有 (tail 按序自旋) | 避免自旋等待 | 无 (串行避免) |
| **吞吐量** | 最高 | 高 | 较高 | 较低 |
| **延迟确定性** | 确定 | 不确定 | 不确定 | 确定 |
| **适用场景** | SPSC | 通用 MPMC | 高竞争 MPMC | 顺序敏感 MPMC |

### 3.3 rte_mbuf 结构与 Cache

```c
// lib/mbuf/rte_mbuf_core.h — rte_mbuf 真实结构 (简化)

struct __rte_cache_aligned rte_mbuf {
    /* ── Cache Line 1: RX 路径热点字段 ── */
    void *buf_addr;           // 数据缓冲区的虚拟地址
    rte_iova_t buf_iova;      // 数据缓冲区的物理地址 (IOVA)

    union {
        uint64_t rearm_data[1]; // RX 描述符重整时批量写入
        struct {
            uint16_t data_off;  // 数据在缓冲区中的偏移
            RTE_ATOMIC(uint16_t) refcnt;  // 引用计数 (原子访问)
            uint16_t nb_segs;   // 分段数
            uint16_t port;      // 输入端口
        };
    };

    uint64_t ol_flags;        // 卸载特性标志

    union {
        void *rx_descriptor_fields1[24 / sizeof(void *)]; // RX 驱动批量填充
        struct {
            uint32_t packet_type;  // L2/L3/L4 类型
            uint32_t pkt_len;      // 总包长 (所有分段之和)
            uint16_t data_len;     // 当前段数据长度
            uint16_t vlan_tci;
            union {
                uint32_t rss;      // RSS 哈希
                struct { uint32_t lo, hi; } fdir;
                struct rte_mbuf_sched sched;
            } hash;
            uint16_t vlan_tci_outer;
            uint16_t buf_len;      // 缓冲区总长度
        };
    };

    /* ── Cache Line 2: TX 路径字段 ── */
    struct rte_mempool *pool;  // 所属内存池
    struct rte_mbuf *next;     // 下一个分段 (链表)

    union {
        uint64_t tx_offload;   // TX 卸载偏移量 (l2/l3/l4/tso 长度)
        struct {
            uint64_t l2_len:7;
            uint64_t l3_len:9;
            uint64_t l4_len:8;
            uint64_t tso_segsz:16;
            uint64_t outer_l3_len:9;
            uint64_t outer_l2_len:7;
        };
    };

    struct rte_mbuf_ext_shared_info *shinfo;
    uint16_t priv_size;
    uint16_t timesync;
    uint32_t dynfield1[9];
};
```

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    rte_mbuf 的 Cache Line 布局                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  Cache Line 1 (64B): RX 热路径                                             │
│  ┌──────────────────────────────────────────────────────────────────┐    │
│  │ buf_addr(8B) │ buf_iova(8B) │ data_off(2B) │ refcnt(2B) │       │    │
│  │ nb_segs(2B)  │ port(2B)     │ ol_flags(8B)  │ packet_type│ ...   │    │
│  └──────────────────────────────────────────────────────────────────┘    │
│                                                                             │
│  Cache Line 2 (64B): TX 路径 + 扩展                                       │
│  ┌──────────────────────────────────────────────────────────────────┐    │
│  │ pool(8B) │ next(8B) │ tx_offload(8B) │ shinfo(8B) │ priv_size │   │    │
│  │ ... dynamic fields ...                                            │    │
│  └──────────────────────────────────────────────────────────────────┘    │
│                                                                             │
│  关键设计:                                                                  │
│  - RX 驱动只写 Cache Line 1 (rearm_data 批量写入 8B)                     │
│  - 应用读 Cache Line 1 获取包数据，写 Cache Line 2 设置 TX 参数          │
│  - refcnt 更新虽然也在 Cache Line 1，但通过原子操作 + refcnt==1 快速路径 │
│    来降低开销                                                              │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

refcnt 更新的真实实现（`lib/mbuf/rte_mbuf.h`）：

```c
// 当 RTE_MBUF_REFCNT_ATOMIC 启用时 (默认)
static inline uint16_t
rte_mbuf_refcnt_update(struct rte_mbuf *m, int16_t value)
{
    // 快速路径: refcnt == 1 说明当前核是唯一持有者
    // 无需原子操作，直接修改
    if (likely(rte_mbuf_refcnt_read(m) == 1)) {
        ++value;
        rte_mbuf_refcnt_set(m, (uint16_t)value);
        return (uint16_t)value;
    }

    // 慢速路径: 多核共享，使用原子操作
    return __rte_mbuf_refcnt_update(m, value);
}

// __rte_mbuf_refcnt_update 内部使用 rte_atomic_fetch_add_explicit()
// 等价于 __atomic_add_fetch(&m->refcnt, value, memory_order_acq_rel)
```

> [!note] refcnt == 1 快速路径
> 这是 DPDK 的一个精妙设计：绝大多数情况下 mbuf 只被一个核持有，
> `rte_mbuf_refcnt_read(m) == 1` 的判断避免了昂贵的原子操作。
> 只有在 mbuf 被多个核共享（如广播、克隆）时才走原子路径。

### 3.4 解决 False Sharing 的通用方法

```c
// 方案 1: Cache Line 对齐 (DPDK 风格)

struct aligned_data {
    uint64_t counter;

    // 填充到 Cache Line 边界
    char pad[RTE_CACHE_LINE_SIZE - sizeof(uint64_t)];
} __rte_cache_aligned;

// 每个核使用独立的 Cache Line
struct percpu_counter {
    uint64_t value __rte_cache_aligned;  // 每个核独占一行
};

// 方案 2: 线程局部变量 (最简单)

static __thread uint64_t local_counter = 0;  // TLS (Thread Local Storage)

// 每个线程有独立的副本，不存在共享

// 方案 3: 批量聚合

struct batch_counter {
    uint32_t batch_index;
    uint64_t batch_sum;  // 本地累加，定期刷新
    char pad[RTE_CACHE_LINE_SIZE - sizeof(uint32_t) - sizeof(uint64_t)];
} __rte_cache_aligned;

// 每个核先在本地累加，定期刷新到全局
void
batch_counter_add(struct batch_counter *cnt, uint64_t val)
{
    cnt->batch_sum += val;
    cnt->batch_index++;

    // 每 N 次写入才刷新一次 (减少对全局变量的写入频率)
    if (cnt->batch_index == 64) {
        flush_to_global(cnt);
        cnt->batch_sum = 0;
        cnt->batch_index = 0;
    }
}

// 方案 4: 使用 per-lcore 数据结构 (DPDK 常用)

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

### 3.5 单写者原则 (Single Writer Principle)

> [!important] 现代高性能系统的核心设计原则
> **一个 Cache Line，尽量减少不同角色、不同核的高频写入。**
> 最理想是单写者；在多生产者/多消费者场景做不到单写者时，也要把写入按角色分区，
> 把冲突限制在同一类线程内部，避免 producer 和 consumer 跨角色互相写同一条 Cache Line。

可以把 ring 控制字段的冲突分成三层：

```text
1. 没有 Cache Line 分离:
   producer 和 consumer 都写同一条 control cache line
   => 跨角色写写冲突最严重

2. DPDK prod/cons 分离:
   producer group 写 prod line
   consumer group 写 cons line
   => 去掉 producer/consumer 跨角色写写 false sharing
   => 但 MP/MC 内部同角色竞争仍然存在

3. SP/SC 或 per-lcore 数据:
   每条热 cache line 尽量只有一个 writer
   => 最接近理想单写者模型
```

所以这里的重点不是“没有人写同一条 Cache Line”，而是**减少冲突维度**：
把一个 producer/consumer 混在一起的全局冲突，拆成 producer group 和 consumer group
各自内部的局部冲突。

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    单写者原则与 Cache Ownership 拓扑                        │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  DPDK rte_ring 的真正智慧: 写者分区，而不是完全没人竞争                    │
│  ═════════════════════════                                                 │
│                                                                             │
│  Producer:                                                                 │
│    producer group 高频写 prod Cache Line (head/tail)                      │
│    读  cons Cache Line (检查空闲空间)                                      │
│                                                                             │
│  Consumer:                                                                 │
│    consumer group 高频写 cons Cache Line (head/tail)                      │
│    读  prod Cache Line (检查可用数据)                                      │
│                                                                             │
│  SP/SC: 每个控制 Cache Line 近似只有 1 个 Writer                          │
│  MP/MC: 同一类线程内部仍会竞争，但 producer/consumer 不再跨角色互写       │
│         同一条控制 Cache Line                                             │
│                                                                             │
│  这才是 DPDK ring 快的重要原因——不是完全没有 CAS/竞争，                  │
│  而是把 Cache Line Ownership 冲突范围压小了                               │
│                                                                             │
│  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ │
│                                                                             │
│  不只是 DPDK，现代高性能系统普遍遵循这个原则:                              │
│                                                                             │
│  Linux per-cpu 变量:                                                       │
│    每个 CPU 独占一份变量副本 → 零 contention                              │
│                                                                             │
│  io_uring:                                                                 │
│    SQ (Submission Queue): 用户写，内核读 → 单写者                         │
│    CQ (Completion Queue): 内核写，用户读 → 单写者                         │
│                                                                             │
│  Go runtime scheduler:                                                     │
│    每个 P (processor) 有独立的 run queue → 单写者                         │
│                                                                             │
│  DPDK per-lcore 数据:                                                      │
│    每个 lcore 有独立的 mempool cache、统计计数器 → 单写者                 │
│                                                                             │
│  本质: 都在优化 Cache Ownership Topology                                   │
│  ─────────────────────────────────────                                     │
│  不是简单减少锁，不是算法复杂度优化                                        │
│  而是: 减少 cache line 在 CPU 之间不必要的迁移 (coherence traffic)        │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

> [!note] 现代 lock-free 真正优化的东西
> 很多人以为是"减少锁"，实际上更重要的是**减少 Cache Line Ownership Bouncing**。
> 一个设计良好的无锁数据结构，核心价值不在于 CAS 比 mutex 快多少，
> 而在于它把"谁写什么 Cache Line"设计得非常合理——冲突被限制在必要范围内，
> ownership 不再因为无关角色写同一条 Cache Line 而来回迁移。

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

`locality` 描述的是**时间局部性提示**，也就是这次预取的数据在使用后是否可能很快再次被访问。它不是应用层的缓存开关，也不是严格指定"必须放进 L1/L2/L3 哪一级 Cache"。编译器和 CPU 会根据这个提示选择合适的预取指令或缓存策略，最终行为仍取决于具体架构。

可以这样理解：

| locality | 含义 | 典型场景 |
|----------|------|----------|
| `0` | Non-temporal，用完即弃，尽量减少 cache 污染 | 流式拷贝、只读一次的数据 |
| `1` | 低时间局部性，后续复用概率较低 | 偶尔可能再访问的数据 |
| `2` | 中等时间局部性 | 有一定复用的数据 |
| `3` | 高时间局部性，倾向保留在 cache 中 | 循环中反复访问的热点数据 |

注意：真正访问数据仍然是普通的内存读写，`prefetch` 只是提前发出提示，不返回数据，也不改变程序语义。

```c
// 通用编译器内置预取
// __builtin_prefetch(addr, rw, locality)
// rw: 0 = read, 1 = write
// locality: 0-3, 时间局部性提示
//   0 = non-temporal，用完即弃，减少 cache 污染
//   3 = high temporal locality，后续可能复用，倾向保留在 cache

// 预取用于读取
void
prefetch_read_example(int *array, int n)
{
    for (int i = 0; i < n; i++) {
        // 预取后面的元素 (顺序访问)
        if (i + 16 < n)
            __builtin_prefetch(&array[i + 16], 0, 3);  // read, high locality

        // 处理当前元素
        process(array[i]);
    }
}

// 预取用于写入 (非 Temporal，减少 cache 污染)
void
prefetch_write_example(int *dst, int *src, int n)
{
    for (int i = 0; i < n; i++) {
        if (i + 16 < n) {
            // 预取源数据 (读)
            __builtin_prefetch(&src[i + 16], 0, 0);  // read, no locality

            // 预取目标位置 (写意图，提前获得可写 cache line)
            __builtin_prefetch(&dst[i + 16], 1, 0);  // write, no locality
        }

        dst[i] = process(src[i]);
    }
}

// x86 特定预取 (SSE/AVX intrinsics)
#include <xmmintrin.h>

// x86 预取 hint 示例: 表达期望的 cache 层级/保留策略，不是强制保证
_mm_prefetch(addr, _MM_HINT_T0);  // 预取到 L1
_mm_prefetch(addr, _MM_HINT_T1);  // 预取到 L2
_mm_prefetch(addr, _MM_HINT_T2);  // 预取到 L3
_mm_prefetch(addr, _MM_HINT_NTA); // 非 temporal (Non-Temporal)
```

### 4.3 DPDK 预取 API

DPDK 在 `lib/eal/include/generic/rte_prefetch.h` 中定义了跨平台的预取接口：

```c
// ── 基本预取 (读) ──
// 读预取的目标: 后面要 load 这条 cache line，提前把数据拉近。
// 它通常只需要可读副本；多核共享读时可以处于 Shared 状态，
// 不一定需要让其他核心的副本失效。

// T0 hint: 面向马上要用的数据，倾向预取到最靠近 CPU 的 cache 层级
static inline void rte_prefetch0(const volatile void *p);

// T1 hint: 面向稍后使用的数据，倾向放在较远 cache 层级，减少 L1 压力
static inline void rte_prefetch1(const volatile void *p);

// T2 hint: 面向更晚使用的数据，倾向放在更远 cache 层级
static inline void rte_prefetch2(const volatile void *p);

// NTA hint: non-temporal，数据用完即弃，尽量减少 cache 污染
static inline void rte_prefetch_non_temporal(const volatile void *p);

// ── 写预取 (实验性 API) ──
// 写预取的目标: 后面要 store 这条 cache line，提前为写入做准备。
// 写入通常需要当前核心获得独占/可修改 ownership (MESI 的 E/M 状态)。
// 如果其他核心也缓存了这条 line，真正获得写权限时可能触发 invalidate，
// 让其他核心的共享副本失效；写预取就是把这部分延迟尽量提前隐藏。
// 注意: 这仍然只是 hint，不保证 CPU 一定立即发起 invalidate。

// 写预取 T0 hint: 后面马上要写，倾向提前获得可写 cache line
static inline void rte_prefetch0_write(const void *p);

// 写预取 T1 hint: 后面稍后要写，倾向降低 L1 压力
static inline void rte_prefetch1_write(const void *p);

// 写预取 T2 hint: 后面更晚要写，倾向使用更远层级的提示
static inline void rte_prefetch2_write(const void *p);

// ── Cache Line 降级 (实验性 API) ──

// 将 Cache Line 从当前层级降级到更远的层级
// 适用于共享数据: 当前核用完后主动降级，方便其他核访问
static inline void rte_cldemote(const volatile void *p);
```

> [!note] 跨平台实现
> 这些函数在不同架构上有不同的实现：
>
> - x86: 使用 `prefetcht0`/`prefetcht1`/`prefetcht2`/`prefetchnta` 汇编指令
> - ARM: 使用 `PRFM PLDL1KEEP`/`PLDL2KEEP`/`PLDL3KEEP` 等指令
> - 写预取使用 `__builtin_prefetch(addr, 1, locality)` 实现

> [!important] 预取 hint 不是 Cache 管理命令
> `rte_prefetch0/1/2()` 和 `rte_prefetch_non_temporal()` 都只是给 CPU 的提示，
> 不是硬性命令。尤其注意两个常见误解：
>
> 1. **不是"某一级 Cache 满了就退到下一级"**  
>    Cache 满时通常发生的是替换/淘汰：CPU 选择一条旧 cache line 让位，
>    新 line 进入目标层级；被淘汰的旧 line 如果是脏的，再写回下一级或内存。
>    `T0/T1/T2/NTA` 影响的是 CPU 对预取位置、保留价值和替换压力的判断，
>    不是简单的逐级回退规则。
>
> 2. **"用完即弃"不是 CPU 维护的一次性状态**  
>    `non_temporal` 表示程序员认为这段数据时间局部性很低，
>    用完后短期内大概率不会再访问。CPU 不会记录"这个地址只能用一次"，
>    第二次访问仍然正常；如果 cache line 还在 cache 中就是 hit，
>    如果已经被替换掉就是 miss。
>
> 可以把 `rte_prefetch_non_temporal(p)` 理解为：
> "我等一下要访问 `p`，但它不像热点数据，不值得为了它挤掉 cache 里的长期有用数据。"

DPDK 还为 mbuf 提供了专用的预取函数（`lib/mbuf/rte_mbuf.h`）：

```c
// 预取 mbuf 的第一个 Cache Line (RX 热路径字段)
// 包括 buf_addr, buf_iova, data_off, refcnt, ol_flags 等
static inline void
rte_mbuf_prefetch_part1(struct rte_mbuf *m)
{
    rte_prefetch0(m);
}

// 预取 mbuf 的第二个 Cache Line (TX 路径字段)
// 包括 pool, next, tx_offload 等
// 仅当 Cache Line 大小为 64B 时有效
static inline void
rte_mbuf_prefetch_part2(struct rte_mbuf *m)
{
#if RTE_CACHE_LINE_SIZE == 64
    rte_prefetch0(RTE_PTR_ADD(m, RTE_CACHE_LINE_MIN_SIZE));
#else
    RTE_SET_USED(m);  // 更大的 Cache Line 已被 part1 覆盖
#endif
}
```

### 4.4 DPDK 中的预取模式

```c
// 模式 1: 批量接收 / Ring 出队时预取 mbuf
// 无论包来自 rte_eth_rx_burst 还是 rte_ring_dequeue_burst，
// 核心模式一样: 预取分散在内存中的 mbuf 对象本体。
// ring slot 本身是顺序访问，硬件预取器已覆盖，无需软件预取。

#define PREFETCH_OFFSET 4

// 通用模式: 给定 mbuf 数组，边预取边处理
static inline void
process_mbufs_with_prefetch(struct rte_mbuf **pkts, uint16_t nb_pkts)
{
    uint16_t i;

    // 预取前几个 mbuf 的 metadata 和包数据
    for (i = 0; i < PREFETCH_OFFSET && i < nb_pkts; i++) {
        rte_mbuf_prefetch_part1(pkts[i]);
        rte_prefetch0(rte_pktmbuf_mtod(pkts[i], const void *));
    }

    // 处理已预取的包，同时预取后续包
    for (i = 0; i < nb_pkts; i++) {
        if (i + PREFETCH_OFFSET < nb_pkts) {
            rte_mbuf_prefetch_part1(pkts[i + PREFETCH_OFFSET]);
            rte_prefetch0(rte_pktmbuf_mtod(pkts[i + PREFETCH_OFFSET],
                                            const void *));
        }

        // 处理 pkts[i] (此时已在 cache 中)
        process_packet(pkts[i]);
    }
}

// 用法 A: 从网卡接收
uint16_t nb_rx = rte_eth_rx_burst(port, queue, mbufs, BURST_SIZE);
process_mbufs_with_prefetch(mbufs, nb_rx);

// 用法 B: 从 ring 出队
uint16_t n = rte_ring_dequeue_burst(ring, (void **)pkts, BURST_SIZE, NULL);
process_mbufs_with_prefetch(pkts, n);

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

// 模式 3: LPM 路由查找预取 (反面教材!)
//
// 以下写法看似合理，实际上 prefetch 完全无效:
//   rte_prefetch0 发出预取
//   → 紧接着 rte_lpm_lookup 内部就访问 tbl24
//   → prefetch 需要 100+ cycles 才能完成，但 lookup 只有 ~20 cycles
//   → 数据还没到 cache 就被访问了，等于没预取
//
// 正确做法见 Section 4.5 的 lpm_lookup_bulk — 批量处理时
// 提前一轮预取下一批 IP 的 tbl24 entry，才有足够的预取窗口。

uint8_t
lpm_lookup_naive(struct rte_lpm *lpm, uint32_t ip)
{
    uint32_t tbl24_idx = ip >> 8;

    // 这条 prefetch 没用 — 和下面的 lookup 之间没有足够的计算来填满预取窗口
    rte_prefetch0(&lpm->tbl24[tbl24_idx]);

    uint8_t next_hop;
    int ret = rte_lpm_lookup(lpm, ip, &next_hop);

    if (ret == 0)
        return next_hop;

    return 0xFF;  // Not found
}
```

### 4.5 预取生效的三个必要条件

> [!important] 三个条件必须**同时满足**，预取才有意义

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                 预取生效的三个必要条件 (缺一不可)                           │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  条件 1: 单次操作足够重                                                    │
│  ═════════════════════                                                     │
│  prefetch 到真正使用之间必须有足够的 cycle 数 (通常 100-200 cycles)        │
│  如果操作太轻量，prefetch 还没完成数据就已经被用了 → 等于没预取          │
│                                                                             │
│  条件 2: 访问模式可预测                                                    │
│  ═════════════════════                                                     │
│  必须在访问数据之前就知道地址                                               │
│  顺序遍历、批量操作天然满足                                                 │
│  随机地址无法预取                                                           │
│                                                                             │
│  条件 3: 工作集超出 cache                                                  │
│  ═════════════════════                                                     │
│  如果数据本来就在 L1 里，预取指令纯属浪费 (约 5 cycles 开销)               │
│  只在工作集 > L1 (32-64KB) 时预取才有价值                                  │
│                                                                             │
│  三个条件的直觉:                                                           │
│  ─────────────────                                                         │
│  条件 1 决定了预取窗口够不够长 (能不能藏住延迟)                           │
│  条件 2 决定了能不能提前知道地址 (发不出 prefetch 就没意义)               │
│  条件 3 决定了数据是否真的不在 cache (cache hit 了还预取是浪费)           │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

用这三个条件审视上面的三个模式：

```
┌─────────────────────────────────────────────────────────────────────────────┐
│              三个模式的预取有效性分析                                       │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  模式 1: mbuf 批量预取 (process_mbufs_with_prefetch)                      │
│  ══════════════════════════════════════════════════════                     │
│                                                                             │
│  条件 1 ✓ process_packet 包含头部解析、查表、校验等，                      │
│          单包处理 200+ cycles，预取窗口充裕                                │
│  条件 2 ✓ mbuf 指针数组顺序遍历，地址已知                                 │
│  条件 3 ✓ 32 个 mbuf × (128B metadata + ~1500B 数据) ≈ 50KB，             │
│          远超 L1 的 32-64KB                                                │
│                                                                             │
│  结论: 三个条件全部满足，预取有效 ✓                                        │
│                                                                             │
│  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ │
│                                                                             │
│  模式 2: Flow Table 单条预取                                               │
│  ═════════════════════════════════════                                      │
│                                                                             │
│  条件 1 △ prefetch 和使用之间只有一个 hash 计算的距离:                    │
│          uint32_t bucket = flow_hash & tbl->mask;  // 几个 cycle           │
│          rte_prefetch0(entry);                     // 发出预取             │
│          // 立刻就访问 entry — 窗口太短!                                  │
│                                                                             │
│  条件 2 ✓ bucket 地址已知                                                 │
│  条件 3 ✓ Flow table 通常 > L1                                            │
│                                                                             │
│  结论: 条件 1 勉强，单条预取收益有限。                                    │
│        批量 flow 查找 (先预取所有 bucket，再逐个比较) 才有价值             │
│                                                                             │
│  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ │
│                                                                             │
│  模式 3: LPM 路由查找预取 — 实际无效!                                     │
│  ═════════════════════════════════════════════                              │
│                                                                             │
│  条件 1 ✗ rte_lpm_lookup 本身只有 ~20 cycles:                             │
│          uint32_t tbl24_idx = ip >> 8;       // 1 cycle                    │
│          rte_prefetch0(&lpm->tbl24[idx]);    // 发出预取                   │
│          rte_lpm_lookup(lpm, ip, &next_hop); // 内部立刻访问 tbl24        │
│          // 预取还没完成就访问了! 完全没有窗口                             │
│                                                                             │
│  条件 2 ✓ 索引可计算                                                      │
│  条件 3 △ tbl24 只有 16K entries × 4B = 64KB，可能在 L2/L3 命中          │
│                                                                             │
│  结论: 条件 1 不满足，预取无效。                                          │
│        rte_lpm_lookup 太轻量，来不及藏住内存延迟。                        │
│        正确做法: 在批量处理中提前一轮预取下一批 IP 的 tbl24 entry          │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

模式 3 的正确写法——批量 LPM 预取：

```c
// 正确: 批量路由查找，提前一轮预取
void
lpm_lookup_bulk(struct rte_lpm *lpm, uint32_t *ips, uint8_t *hops,
                uint16_t n)
{
    #define LPM_PREFETCH_AHEAD 4

    // 第一轮: 预取前几个 tbl24 entry
    for (int i = 0; i < LPM_PREFETCH_AHEAD && i < n; i++)
        rte_prefetch0(&lpm->tbl24[ips[i] >> 8]);

    // 主循环: 处理当前 IP 的同时预取后续
    for (int i = 0; i < n; i++) {
        if (i + LPM_PREFETCH_AHEAD < n)
            rte_prefetch0(&lpm->tbl24[ips[i + LPM_PREFETCH_AHEAD] >> 8]);

        // rte_lpm_lookup 此时访问的 tbl24 entry 已在 cache 中
        rte_lpm_lookup(lpm, ips[i], &hops[i]);
    }
}
```

### 4.6 预取无效场景对照表

| 场景 | 条件 1 (操作够重) | 条件 2 (模式可预测) | 条件 3 (超出 cache) | 结论 | 替代方案 |
|------|:-:|:-:|:-:|------|------|
| mbuf 批量预取 | ✓ 200+ cycles | ✓ 顺序遍历 | ✓ ~50KB | **有效** | — |
| Flow Table 批量预取 | ✓ 多条比较 | ✓ bucket 已知 | ✓ 表 > L1 | **有效** | 批量先预取所有 bucket |
| Flow Table 单条预取 | △ 窗口短 | ✓ | ✓ | **勉强** | 改为批量模式 |
| LPM 单条预取 | ✗ ~20 cycles | ✓ | △ 64KB | **无效** | 批量提前一轮预取 |
| Ring slot 预取 | ✓ | ✓ | ✗ 顺序在 cache | **无效** | 硬件预取器已覆盖 |
| 小数组遍历 (< 4KB) | ✓ | ✓ | ✗ 全在 L1 | **无效** | 无需优化 |
| 随机地址访问 | — | ✗ 无法预判 | — | **无效** | 减少随机性，改用 hash |
| 链表遍历 | ✓ | △ next 指针 | ✓ | **有效** | prefetch(node->next) |

> [!tip] 实测数据参考
>
> 以下为 DPDK 邮件列表和社区 benchmark 中的典型数据（具体数值因平台和配置而异）：
>
> | 场景 | 无预取 | 有预取 | 提升 |
> |------|--------|--------|------|
> | RX burst 32 pkts, 重处理 (parse + flow lookup) | ~45 Mpps | ~58 Mpps | **~29%** |
> | RX burst 32 pkts, 轻处理 (仅 len 统计) | ~72 Mpps | ~71 Mpps | **~0%** (负优化) |
> | LPM 单条查找 | ~48 Mlookups/s | ~47 Mlookups/s | **~0%** (窗口太短) |
> | LPM 批量查找 (32 IPs, prefetch ahead) | ~48 Mlookups/s | ~56 Mlookups/s | **~17%** |
>
> 关键发现：轻处理场景下预取反而略慢（预取指令的开销 > 收益），只有单次操作足够重时预取才有正收益。

### 4.7 非临时预取的使用场景

```c
// 大块数据只读一次 (如校验和计算、数据包复制到不同 NUMA 节点)
// 使用 rte_prefetch_non_temporal() 或 _mm_prefetch(addr, _MM_HINT_NTA)
// 避免将大量临时数据挤占 L1/L2 Cache
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

// AoS 访问：每个粒子的字段打包在一起
// 问题不是单个粒子的 x/y/z 不连续，而是只处理 x/y/z 时，
// CPU 仍会把 vx/vy/vz/mass 这些暂时用不到的字段一起加载进 Cache。
// 结构体越大，访问 p[i].x -> p[i+1].x 的跨度越大，跨 Cache Line 的概率越高。
void
update_particles_aos(struct particle_aos *p, int n)
{
    for (int i = 0; i < n; i++) {
        p[i].x += p[i].vx;  // 下一次 x 访问要跨过整个 struct
        p[i].y += p[i].vy;
        p[i].z += p[i].vz;
    }
}

// SoA 访问：同类字段连续存放
// x[i], x[i+1], x[i+2] 连续，vx[i], vx[i+1], vx[i+2] 也连续，
// 更利于硬件预取和 SIMD 批量处理。
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
//
// 注意：__rte_cache_aligned 不是单线程下的默认优化。
// 它主要用于避免跨线程 False Sharing、满足硬件/DMA 对齐要求，
// 或保证一个很热的小对象不会跨两个 Cache Line。
// 如果只是单线程顺序遍历普通结构体数组，强行 64B 对齐会降低 Cache 密度。

struct aligned_struct {
    uint64_t field1;        // 8 bytes
    uint32_t field2;        // 4 bytes
    // 4 bytes padding (自动填充)
    double field3;          // 8 bytes (对齐到 8)
    // 4 bytes padding
    uint64_t field4;        // 8 bytes
} __rte_cache_aligned;     // 对齐到 Cache Line

// 方案 3: 热点数据分离

struct packet_stats {
    // 频繁访问的字段 (热点) — 放在结构体开头
    uint64_t packet_count;
    uint64_t byte_count;
    uint32_t error_count;

    // 较少访问的字段 (冷点)
    uint64_t last_update_time;
    char ifname[32];
};

// DPDK 中很常见：把快路径频繁读取/写入的 metadata 放在结构体前部，
// 尽量让热点字段落在第一个 Cache Line；冷字段放后面，甚至拆到单独结构。
// rte_mbuf 就是典型例子：包长、数据偏移、offload 标志等快路径字段集中在前部。
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
        struct rte_ipv4_hdr *iph = rte_pktmbuf_mtod(pkts[i],
                                                     struct rte_ipv4_hdr *);
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
            rte_mbuf_prefetch_part1(pkts[j]);
            rte_prefetch0(rte_pktmbuf_mtod(pkts[j], const void *));
        }

        // 批量处理
        for (int j = i; j < batch_end; j++) {
            struct rte_ipv4_hdr *iph = rte_pktmbuf_mtod(pkts[j],
                                                         struct rte_ipv4_hdr *);

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
            rte_prefetch0((char *)src_data + offset + CACHE_LINE_LEN);
            rte_memcpy((char *)dst_data + offset,
                       (const char *)src_data + offset, CACHE_LINE_LEN);
            offset += CACHE_LINE_LEN;
            len -= CACHE_LINE_LEN;
        }

        if (len > 0)
            rte_memcpy((char *)dst_data + offset,
                       (const char *)src_data + offset, len);
    }
}
```

### 5.3 NUMA 感知内存访问

```c
// NUMA 感知优化

// DPDK 提供的 NUMA 查询 API
int socket_id = rte_socket_id();      // 当前 lcore 所在的 NUMA 节点
int nb_sockets = rte_socket_count();  // 系统中的 NUMA 节点数

// NUMA 感知 mbuf 分配 — 始终从本地 socket 分配
struct rte_mbuf *
numa_aware_mbuf_alloc(void)
{
    int socket_id = rte_socket_id();  // 当前 lcore 的 socket

    // 从本地 socket 的 pool 分配
    struct rte_mempool *mp = mbuf_pools[socket_id];

    return rte_pktmbuf_alloc(mp);
}

// NUMA 感知 mbuf 内存池创建
struct rte_mempool *
create_numa_mempool(const char *name, unsigned n, unsigned cache_size)
{
    // rte_pktmbuf_pool_create 是 pktmbuf pool 的推荐 wrapper，
    // 内部会设置正确的 private area、mbuf 初始化回调和 data room。
    return rte_pktmbuf_pool_create(
        name, n,
        cache_size,                  // per-lcore cache 大小
        0,                           // priv_size
        RTE_MBUF_DEFAULT_BUF_SIZE,   // data room, 含 RTE_PKTMBUF_HEADROOM
        rte_socket_id());            // 在本地 NUMA 节点分配
}

// 跨 NUMA 访问的代价
// ───────────────────
// 本地内存访问: ~80 ns
// 远程内存访问 (跨一个 QPI/UPI link): ~120-150 ns
// 远程内存访问 (跨多个 QPI/UPI link): ~150-200 ns
//
// 在 DPDK 中，正确做法是:
// - 每个 lcore 只使用本 socket 的内存池
// - 通过 rte_socket_id() 确定当前 lcore 的 NUMA 节点
// - 避免跨 NUMA 的 ring 传递 (或使用 RCU 等机制降低频率)
```

---

## 6. rte_ring 与 rte_mempool 优化

### 6.1 rte_ring 的 Cache 友好设计

如 Section 3.2 所示，rte_ring 的核心设计就是 Cache Line 隔离。这里补充说明 ring 数据区的访问模式：

```c
// Ring 数据区的顺序访问天然适合硬件预取
// 入队操作: 顺序写入 ring[head], ring[head+1], ...
// 出队操作: 顺序读取 ring[tail], ring[tail+1], ...
// CPU 硬件预取器自动识别这种线性模式，无需软件预取
//
// 真正需要软件预取的是 ring 中存放的对象本身 (如 mbuf)
// 因为对象物理上分散，硬件预取器无法预测

// 实际模式: 从 ring 出队后，预取 mbuf 再处理
#define BURST_SIZE 32
#define PREFETCH_AHEAD 4

static void
ring_dequeue_and_process(struct rte_ring *r)
{
    struct rte_mbuf *pkts[BURST_SIZE];

    // 批量出队 (ring 内部顺序访问，硬件预取器已覆盖)
    uint32_t n = rte_ring_dequeue_burst(r, (void **)pkts,
                                         BURST_SIZE, NULL);
    if (n == 0)
        return;

    // 预取出队对象的 mbuf metadata 和包数据
    // 这些对象在内存中分散，必须软件预取
    for (uint32_t i = 0; i < n; i++) {
        if (i + PREFETCH_AHEAD < n) {
            rte_mbuf_prefetch_part1(pkts[i + PREFETCH_AHEAD]);
            rte_prefetch0(rte_pktmbuf_mtod(pkts[i + PREFETCH_AHEAD],
                                            const void *));
        }

        // 此时 pkts[i] 的 metadata 和数据大概率已在 cache 中
        process_packet(pkts[i]);
    }

    rte_pktmbuf_free_bulk(pkts, n);
}
```

### 6.2 rte_mempool 优化

```c
// lib/mempool/rte_mempool.h

// ── rte_mempool 结构 (简化) ──
struct __rte_cache_aligned rte_mempool {
    char name[RTE_MEMPOOL_NAMESIZE];
    void *pool_data;           // 底层 ring (用于存储空闲对象指针)
    void *pool_config;
    const struct rte_memzone *mz;
    unsigned int flags;
    int socket_id;             // NUMA 节点
    uint32_t size;             // 内存池最大容量
    uint32_t cache_size;       // per-lcore cache 默认大小
    uint32_t elt_size;         // 每个元素的大小
    uint32_t header_size;      // 元素头部大小
    uint32_t trailer_size;     // 元素尾部大小
    unsigned private_data_size;
    int32_t ops_index;
    struct rte_mempool_cache *local_cache;  // per-lcore 缓存指针
    uint32_t populated_size;
    // ... (其他管理字段)
};

// ── per-lcore 缓存结构 ──
struct __rte_cache_aligned rte_mempool_cache {
    uint32_t size;         // cache 容量 (创建时指定)
    uint32_t flushthresh;  // 超过此阈值时自动刷新到 ring
    uint32_t len;          // 当前 cache 中的对象数

    // cache 对象指针数组 (可溢出到 2 倍容量)
    alignas(RTE_CACHE_LINE_SIZE)
    void *objs[RTE_MEMPOOL_CACHE_MAX_SIZE * 2];
};
```

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                   rte_mempool 的两级缓存架构                                │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  Lcore 0                Lcore 1                Lcore N                     │
│  ┌──────────────┐      ┌──────────────┐      ┌──────────────┐             │
│  │ local_cache  │      │ local_cache  │      │ local_cache  │             │
│  │ len: 32      │      │ len: 16      │      │ len: 64      │             │
│  │ objs[...]    │      │ objs[...]    │      │ objs[...]    │             │
│  └──────┬───────┘      └──────┬───────┘      └──────┬───────┘             │
│         │                     │                     │                      │
│         │ (cache 未命中时)     │                     │                      │
│         ▼                     ▼                     ▼                      │
│  ┌─────────────────────────────────────────────────────────────┐          │
│  │                    rte_ring (全局共享)                       │          │
│  │              空闲对象指针的环形队列                            │          │
│  │         [ptr0][ptr1][ptr2]...[ptrN]                         │          │
│  └─────────────────────────────────────────────────────────────┘          │
│         │                                                                   │
│         ▼                                                                   │
│  ┌─────────────────────────────────────────────────────────────┐          │
│  │               实际对象内存 (mbuf 数据区)                     │          │
│  │  [mbuf0][mbuf1][mbuf2]...[mbufN]                           │          │
│  └─────────────────────────────────────────────────────────────┘          │
│                                                                             │
│  关键: local_cache 是 per-lcore 的，不存在 False Sharing                     │
│        只有在 cache 未命中时才访问全局 ring (有锁/CAS)                      │
│        flushthresh 自动将多余对象归还 ring                                  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

```c
// per-lcore cache 的工作原理 (简化示意)

// 分配对象: 先从 local_cache 取
static inline void *
mempool_get_cached(struct rte_mempool *mp)
{
    // 获取当前 lcore 的 cache (存储在 TLS 中)
    struct rte_mempool_cache *c = rte_mempool_default_cache(mp,
                                                            rte_lcore_id());

    if (c == NULL || c->len == 0)
        return NULL;  // cache 空，需要从 ring 获取

    c->len--;
    void *obj = c->objs[c->len];

    // 预取下一个对象 (减少下次分配的 Cache Miss)
    if (c->len > 0)
        rte_prefetch0(c->objs[c->len - 1]);

    return obj;
}

// 释放对象: 先放回 local_cache
static inline void
mempool_put_cached(struct rte_mempool *mp, void *obj)
{
    struct rte_mempool_cache *c = rte_mempool_default_cache(mp,
                                                            rte_lcore_id());

    if (c == NULL)
        return;

    c->objs[c->len] = obj;
    c->len++;

    // 超过阈值时刷新到 ring (减少 ring 竞争)
    if (c->len >= c->flushthresh)
        rte_mempool_ops_enqueue_bulk(mp, c->objs,
                                     c->len - c->size, 0);
}

// DPDK 推荐的批量分配/释放 API
struct rte_mbuf *mbufs[32];

// 批量分配 (内部使用 local_cache)
rte_pktmbuf_alloc_bulk(mbuf_pool, mbufs, 32);

// 批量释放
rte_pktmbuf_free_bulk(mbufs, 32);
```

> [!tip] mempool cache 参数建议
>
> - `cache_size`: 建议 256-512 (IO 应用典型值)。过大会浪费内存，过小则频繁访问 ring
> - `flushthresh`: 默认为 `cache_size * 1.5`，即 cache 装到 150% 时自动刷新
> - 批量操作 (`_bulk` 后缀) 比逐个操作快 2-3x，因为减少了 local_cache 操作次数

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
// 简单的顺序读带宽测试
//
// 注意：这是粗略 micro-benchmark，用来观察 local/remote NUMA、
// cache-hot/cache-cold 场景的相对差异，不替代 STREAM/mbw/perf 等工具。

double
measure_read_bandwidth(void *addr, size_t size, int iterations)
{
    uint64_t start, end;
    volatile uint64_t sink = 0;  // 防止编译器优化掉读操作
    uint8_t *base = addr;

    start = rte_rdtsc();

    for (int iter = 0; iter < iterations; iter++) {
        // 按 Cache Line 步长遍历整个 buffer，并读完整条 64B Cache Line。
        for (size_t offset = 0; offset < size; offset += RTE_CACHE_LINE_SIZE) {
            uint64_t *line = (uint64_t *)(base + offset);

            sink += line[0];
            sink += line[1];
            sink += line[2];
            sink += line[3];
            sink += line[4];
            sink += line[5];
            sink += line[6];
            sink += line[7];
        }
    }

    end = rte_rdtsc();

    uint64_t total_bytes = (uint64_t)size * iterations;
    uint64_t cycles = end - start;

    // bandwidth = bytes / time; 用 GHz 换算: cycles / freq_ghz = ns
    // GB/s = total_bytes / (cycles / freq_ghz) / 1e9
    double freq_ghz = rte_get_tsc_hz() / 1e9;
    return (double)total_bytes * freq_ghz / cycles;
}

// DPDK 提供的内存信息查询
void
print_dpdk_memory_info(void)
{
    // 获取 NUMA 节点数
    int nb_sockets = rte_socket_count();
    printf("NUMA nodes: %d\n", nb_sockets);

    // 打印 EAL 管理的 hugepage/memseg 布局，可观察内存分布在哪些 socket。
    rte_dump_physmem_layout(stdout);
    rte_malloc_dump_stats(stdout, NULL);
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
        if (i + 4 < nb)
            rte_mbuf_prefetch_part1(pkts[i + 4]);
        if (i + 5 < nb)
            rte_mbuf_prefetch_part1(pkts[i + 5]);
        if (i + 6 < nb)
            rte_mbuf_prefetch_part1(pkts[i + 6]);
        if (i + 7 < nb)
            rte_mbuf_prefetch_part1(pkts[i + 7]);

        // 处理
        process_ipv4(rte_pktmbuf_mtod(pkts[i],   struct rte_ipv4_hdr *));
        process_ipv4(rte_pktmbuf_mtod(pkts[i+1], struct rte_ipv4_hdr *));
        process_ipv4(rte_pktmbuf_mtod(pkts[i+2], struct rte_ipv4_hdr *));
        process_ipv4(rte_pktmbuf_mtod(pkts[i+3], struct rte_ipv4_hdr *));
    }

    // 处理剩余包
    for (; i < nb; i++) {
        process_ipv4(rte_pktmbuf_mtod(pkts[i], struct rte_ipv4_hdr *));
    }
}

// 模式 2: 分离热点和冷点
void
process_with_separation(struct rte_mbuf **pkts, int nb)
{
    enum { MAX_BATCH = 256 };
    struct rte_ipv4_hdr *headers[MAX_BATCH];
    uint16_t lengths[MAX_BATCH];

    for (int base = 0; base < nb; base += MAX_BATCH) {
        int count = RTE_MIN(nb - base, MAX_BATCH);

        // 提取热点数据到连续数组 (Cache 友好)
        for (int i = 0; i < count; i++) {
            headers[i] = rte_pktmbuf_mtod(pkts[base + i],
                                          struct rte_ipv4_hdr *);
            lengths[i] = rte_pktmbuf_pkt_len(pkts[base + i]);
        }

        // 处理连续数组 (全部在 Cache 中)
        for (int i = 0; i < count; i++) {
            process_header(headers[i], lengths[i]);
        }

        // 释放 mbuf (冷路径)
        for (int i = 0; i < count; i++) {
            rte_pktmbuf_free(pkts[base + i]);
        }
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
// DPDK 包处理流水线示例
//
// 前提：
// - RSS/flow director 保证同一个 flow 固定落到同一个 RX queue/lcore。
// - flow table 是 per-lcore 的，lookup/create 不需要跨 lcore 加锁。
// - flow_table_create() 应使用 mempool/cache，避免在热路径里做昂贵分配。
// - Flow table 预取只有在表较大、访问近似随机、工作集超出 Cache 时才可能有效。
//   如果 flow table 很小/cache-hot，或者使用 rte_hash bulk API，手工预取可能没有收益。

#define BATCH_SIZE 32
#define PKT_PREFETCH_OFFSET 4
#define FLOW_PREFETCH_OFFSET 8

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
    struct rte_mbuf *tx_pkts[BATCH_SIZE];
    struct flow_key keys[BATCH_SIZE];
    uint32_t hashes[BATCH_SIZE];
    struct flow_entry *flows[BATCH_SIZE];

    while (!quit) {
        // 1. 接收批量包
        uint16_t nb_rx = rte_eth_rx_burst(conf->port_id, conf->queue_id,
                                           pkts, BATCH_SIZE);

        if (nb_rx == 0)
            continue;

        // 2. 预热前几个包。预取不是为了马上使用，而是给内存访问留延迟窗口。
        // rte_mbuf_prefetch_part1() 预取 mbuf metadata，后面的 flow_key_extract() 会消费它。
        // rte_prefetch0(pkt data) 预取包头数据，用于解析五元组。
        for (int i = 0; i < PKT_PREFETCH_OFFSET && i < nb_rx; i++) {
            rte_mbuf_prefetch_part1(pkts[i]);
            rte_prefetch0(rte_pktmbuf_mtod(pkts[i], void *));
        }

        // 3. 解析当前包，同时预取未来包。
        // key/hash 保存下来，避免 flow lookup 时重复解析 packet header。
        for (int i = 0; i < nb_rx; i++) {
            if (i + PKT_PREFETCH_OFFSET < nb_rx) {
                rte_mbuf_prefetch_part1(pkts[i + PKT_PREFETCH_OFFSET]);
                rte_prefetch0(rte_pktmbuf_mtod(pkts[i + PKT_PREFETCH_OFFSET],
                                               void *));
            }

            flow_key_extract(pkts[i], &keys[i]);
            hashes[i] = flow_hash(&keys[i]);
        }

        // 4. Flow 查找。先预热前几个 flow bucket，后续循环滚动预取。
        // 这不是无条件优化：只有大表随机访问且 prefetch 距离足够时才值得保留。
        for (int i = 0; i < FLOW_PREFETCH_OFFSET && i < nb_rx; i++)
            flow_table_prefetch(conf->ft, hashes[i]);

        for (int i = 0; i < nb_rx; i++) {
            if (i + FLOW_PREFETCH_OFFSET < nb_rx)
                flow_table_prefetch(conf->ft, hashes[i + FLOW_PREFETCH_OFFSET]);

            flows[i] = flow_table_lookup(conf->ft, &keys[i], hashes[i]);
        }

        // 5. 批量处理，并只保留仍需发送的 mbuf。
        // 前面的 packet data 预取主要服务 flow_key_extract()。
        // 如果 process_with_flow() 还会深度读取 packet data/payload，
        // 应在这个循环里对 pkts[i + PKT_PREFETCH_OFFSET] 再做一次近距离预取。
        uint16_t nb_to_tx = 0;
        for (int i = 0; i < nb_rx; i++) {
            if (flows[i]) {
                // 命中 flow
                process_with_flow(pkts[i], flows[i]);
                tx_pkts[nb_to_tx++] = pkts[i];
            } else {
                // Miss flow (慢路径)
                flows[i] = flow_table_create(conf->ft, &keys[i], hashes[i]);
                if (flows[i]) {
                    process_with_flow(pkts[i], flows[i]);
                    tx_pkts[nb_to_tx++] = pkts[i];
                } else {
                    rte_pktmbuf_free(pkts[i]);
                    conf->stats.dropped++;
                }
            }
        }

        // 6. 发送
        uint16_t nb_tx = rte_eth_tx_burst(conf->port_id, conf->queue_id,
                                           tx_pkts, nb_to_tx);

        conf->stats.packets += nb_tx;
        for (uint16_t i = 0; i < nb_tx; i++)
            conf->stats.bytes += rte_pktmbuf_pkt_len(tx_pkts[i]);

        // 示例中直接释放未发送的包；生产代码可使用 rte_eth_tx_buffer/retry。
        for (uint16_t i = nb_tx; i < nb_to_tx; i++) {
            rte_pktmbuf_free(tx_pkts[i]);
            conf->stats.dropped++;
        }
    }
}
```

### 8.2 延迟测量

```c
// Cache / Memory 访问延迟测量
//
// 要点：
// - 不要每次访问都读 TSC，rdtsc 本身的开销会淹没 L1/L2 延迟。
// - 不要用独立随机索引 load/store，CPU 可能并行发出多个 miss。
// - 使用 pointer chasing，让下一次访问依赖上一次访问结果，
//   这样测到的是接近“单次依赖 load latency”的值。

struct latency_node {
    uint32_t next;
    uint8_t pad[RTE_CACHE_LINE_SIZE - sizeof(uint32_t)];
} __rte_cache_aligned;

// 通过调整 buffer 大小观察 L1 / L2 / L3 / DRAM 延迟。
// 例如：4KB 常驻 L1，256KB-1MB 观察 L2，几十 MB 观察 LLC/DRAM。
void
measure_cache_latency(void)
{
    // 32MB 不一定超出所有 CPU 的 L3，只能作为大工作集示例。
    size_t buf_size = 32 * 1024 * 1024;
    size_t n_lines = buf_size / sizeof(struct latency_node);
    struct latency_node *nodes = rte_zmalloc(NULL,
                                             n_lines * sizeof(*nodes),
                                             RTE_CACHE_LINE_SIZE);

    // 构造一个跨 cache line 的依赖访问链。
    // n_lines 为 2 的幂时，奇数 step 可以遍历所有 line。
    uint32_t step = 131071;
    for (uint32_t i = 0; i < n_lines; i++)
        nodes[i].next = (i + step) & (n_lines - 1);

    // 热身：建立页表映射，避免把首次缺页成本算进结果。
    volatile uint32_t idx = 0;
    for (uint64_t i = 0; i < n_lines; i++)
        idx = nodes[idx].next;

    uint64_t iterations = 10000000;
    uint64_t start = rte_rdtsc_precise();
    for (uint64_t i = 0; i < iterations; i++)
        idx = nodes[idx].next;
    uint64_t end = rte_rdtsc_precise();

    double avg_cycles = (double)(end - start) / iterations;
    double avg_ns = avg_cycles * 1e9 / rte_get_tsc_hz();

    printf("Dependent load latency (%zu MB working set):\n",
           buf_size / 1024 / 1024);
    printf("  Avg: %.2f cycles, %.2f ns\n", avg_cycles, avg_ns);

    rte_free(nodes);
}
```

---

## 9. 小结

本章核心要点：

1. **Cache 层次**：L1 (~1ns, 32-64KB) → L2 (~4ns, 256KB) → L3 (~15ns, 8-64MB) → Memory (~100ns)，访问延迟差距可达 100 倍。

2. **Cache Line**：64 bytes 为标准单位，空间局部性是优化的关键。

3. **MESI 协议**：Modified/Exclusive/Shared/Invalid 状态，总线嗅探保证一致性，写回比写直达更高效。

4. **False Sharing**：多个核修改同一 Cache Line 的不同变量，导致意外缓存失效，性能下降可达 10-50x。

5. **DPDK rte_ring 已解决 False Sharing**：通过 `RTE_CACHE_GUARD` + `__rte_cache_aligned` 将 producer/consumer 隔离到不同 Cache Line。

6. **False Sharing 通用解决方案**：Cache Line 对齐 (`__rte_cache_aligned`)、线程局部变量、批量聚合、per-lcore 数据结构。

7. **DPDK 预取 API**：`rte_prefetch0/1/2()` (读)、`rte_prefetch_non_temporal()` (非临时)、`rte_prefetch0_write/1_write/2_write()` (实验性写预取)、`rte_mbuf_prefetch_part1/part2()` (mbuf 专用)。

8. **预取策略**：顺序访问预取有效，随机访问无效；预取窗口需要 100-200 cycles 提前量；避免预取已在 L1 中的数据。

9. **数据布局**：SoA (结构数组) 比 AoS (数组结构) 更利于 Cache 预取和 SIMD；热点字段放结构体开头。

10. **NUMA 感知**：本地 socket 访问延迟远低于跨 socket 访问，DPDK 通过 `rte_socket_id()` 提供感知能力，始终从本地 socket 分配。

11. **rte_mempool 两级缓存**：per-lcore local_cache 无锁分配 + 全局 ring 作为后备，批量操作比逐个操作快 2-3x。

12. **性能分析**：使用 `perf stat`、`perf record` 分析 L1/L2/L3 Miss 率。

13. **MESI 核心规则**：同一 Cache Line 可多核共享读 (S)，但只能一个核写 (M)。"读"廉价——只需 S 状态；"写"昂贵——获得 M ownership 需要 invalidate 所有其他持有者。

14. **写写冲突是真正的杀手**：两个核频繁写同一 Cache Line 会导致 M↔I 疯狂 bouncing，性能下降 10-50x。而读写共享只下降 ~2-3x，因为读者只需 S 状态，不需要 ownership transfer。

15. **写者分区原则**：现代高性能系统会尽量让一个 Cache Line 只有一个高频 Writer；做不到时，也要把写入按角色或 CPU 分区，把冲突限制在必要范围内。DPDK ring、Linux per-cpu、io_uring、Go scheduler 本质都在优化 Cache Ownership Topology，而非简单算法复杂度。

16. **Cache Coherence Traffic 是真正的瓶颈**：现代多核性能很多时候瓶颈不是算力，而是 Cache Line 在 CPU 之间迁移的成本。DPDK ring 真正厉害的地方不是 CAS，而是它把"谁写什么 Cache Line"设计得非常合理。

**相关阅读**：

- [[2026-04-09-dpdk-deep-dive-ch25a-simd-vectorization|第二十五-A章：SIMD 向量化——单核里的数据并行]]
- [[2026-04-09-dpdk-deep-dive-ch25b-prefetch-deep-dive|第二十五-B章：预取技术——把内存等待变成后台工作]]

**下一篇预告**：[[2026-04-09-dpdk-deep-dive-ch26-numa-optimization|第二十六章]]将讲解 NUMA 亲和性优化——local/remote 访问、内存分配策略、多核调度。

---

> [!tip] 参考文献
>
> - Intel, "Intel 64 and IA-32 Architectures Optimization Reference Manual"
> - AMD, "AMD64 Architecture Programming Manual"
> - "What Every Programmer Should Know About Memory", Ulrich Drepper
> - DPDK Programmer's Guide — Memory, https://doc.dpdk.org/guides/prog_guide/
> - DPDK API — rte_prefetch.h, rte_mbuf.h, rte_ring_core.h, rte_mempool.h
