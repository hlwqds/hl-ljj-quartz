---
title: "DPDK 深度探索 (九)：懒惰过期与 GC 机制"
date: 2026-04-09
tags: [dpdk, series, conntrack, lazy-expiry, gc, timer, garbage-collection]
description: "深入理解高性能网关中的定时器替代方案——懒惰过期（Lazy Expiration）、分片 GC（Sharded GC）、多层时间桶（Multi-level Time Bucket），以及用 DPDK 实现简化版连接跟踪的完整流程"
---

> [!info] DPDK 深度探索系列 0. [[dpdk-deep-dive|全栈学习路径总览]]
>
> 1. [[ch1-architecture-overview|第一章：架构概述——kernel bypass 原理与 DPDK 定位]]
> 2. [[ch2-uio-vfio-iommu|第二章：UIO/VFIO/IOMMU 用户态驱动框架]]
> 3. [[ch3-eal-initialization|第三章：EAL 初始化与 lcore 模型]]
> 4. [[ch4-hugepage-mempool|第四章：大页内存与 mempool 机制]]
> 5. [[ch5-mbuf-mechanism|第五章：Mbuf 结构与 Dynfield]]
> 6. [[ch6-ring-queue|第六章：Ring 无锁队列实现与性能分析]]
> 7. [[ch7-pmd-driver|第七章：PMD (Poll Mode Driver) 驱动架构]]
> 8. [[ch8-timer-wheel|第八章：rte_timer 软件定时器与 HTimer 实现]]
> 9. **第九章：懒惰过期与 GC 机制**

---

## 1. 概述

### 1.1 rte_timer 的局限

[[ch8-timer-wheel|第八章]]介绍了 `rte_timer` 的时间轮实现，适合几十到几千个定时器的场景。但高性能网关面临的是**百万级 per-flow 定时器**的需求：

```
场景：NAT 网关，100 万条并发连接

方案 A：每条连接一个 rte_timer
  struct rte_timer ≈ 40 字节
  100 万 × 40B = 40MB（仅定时器结构体）
  1000 万 × 40B = 400MB
  → 内存开销不可接受

方案 B：每条连接只记一个时间戳
  uint64_t last_seen = 8 字节
  100 万 × 8B = 8MB
  1000 万 × 8B = 80MB
  → 开销降低 5 倍
```

### 1.2 懒惰过期 + GC 的核心思想

```
rte_timer 模式（主动通知）:
  ┌──────────┐     超时了！      ┌──────────┐
  │ 定时器    │ ──────────────→ │ 执行回调  │
  │ (per-flow)│                  │ 清理资源  │
  └──────────┘                  └──────────┘
  每条流一个定时器，到期时主动通知

懒惰过期模式（被动检查）:
  ┌──────────┐     顺便看看      ┌──────────┐
  │ 收包路径  │ ──────────────→ │ 超时了？  │ → 是 → 清理
  │ (已有流量)│                  │ 更新时间戳│ → 否 → 继续
  └──────────┘                  └──────────┘
  没有定时器，收包时顺便检查时间戳

  ┌──────────┐     定期扫描      ┌──────────┐
  │ GC 线程  │ ──────────────→ │ 批量清理  │
  │ (后台)   │                  │ 过期条目  │
  └──────────┘                  └──────────┘
  没有流量的条目靠 GC 兜底
```

### 1.3 两种机制对比

| 维度           | rte_timer（时间轮）          | 懒惰过期 + GC                               |
| -------------- | ---------------------------- | ------------------------------------------- |
| **内存**       | 40B/flow（定时器结构体）     | 8B/flow（一个时间戳）                       |
| **定时精度**   | 精确到 tick                  | 精确到 GC 轮次或收包时机                    |
| **CPU 开销**   | O(1) per tick（分摊）        | O(1) per packet（收包路径） + O(n/N) per GC |
| **适合规模**   | 千~万级                      | 百万~千万级                                 |
| **实现复杂度** | DPDK 内置                    | 需要自行实现                                |
| **典型场景**   | LACP 心跳、TCP RTO、统计上报 | Conntrack、NAT、会话管理                    |

---

## 2. 懒惰过期原理

### 2.1 时间戳对比法

核心就是一个减法比较：

```c
struct conntrack_entry {
    uint32_t src_ip;
    uint32_t dst_ip;
    uint16_t src_port;
    uint16_t dst_port;
    uint8_t  proto;
    uint64_t last_seen;   // 最后活跃时间戳（TSC cycles）
    // 注意：没有 rte_timer
};

// 超时判断：一行代码
#define IS_EXPIRED(entry, now, timeout) \
    ((now) - (entry)->last_seen > (timeout))
```

为什么用 TSC（`rte_rdtsc()`）而不是 `clock_gettime()`？

```
rte_rdtsc():           ~20 个 CPU 周期（一条 rdtsc 指令）
clock_gettime():       ~200ns（系统调用，即使 vDSO 也有函数调用开销）

每秒处理 1000 万个包，每个包省 180ns：
  1000 万 × 180ns = 1.8 秒的 CPU 时间
```

### 2.2 收包路径上的懒惰过期

最常见的实现——**收包时顺便检查**，零额外遍历开销：

```c
// 收包处理主路径
static uint16_t
process_packets(struct rte_mbuf **pkts, uint16_t nb_pkts)
{
    uint64_t now = rte_rdtsc();
    struct conntrack_entry *ct;

    for (uint16_t i = 0; i < nb_pkts; i++) {
        // 1. 查找 conntrack 条目
        ct = conntrack_lookup(pkts[i]);

        if (ct == NULL) {
            // 新连接，创建条目
            ct = conntrack_create(pkts[i], now);
            continue;
        }

        // 2. 懒惰过期检查（就这一次比较，没有回调、没有级联）
        if (IS_EXPIRED(ct, now, TIMEOUT_CYCLES)) {
            conntrack_remove(ct);
            ct = conntrack_create(pkts[i], now);
        }

        // 3. 更新时间戳
        ct->last_seen = now;

        // 4. 正常处理包...
        forward_packet(pkts[i], ct);
    }
    return nb_pkts;
}
```

```
收包路径上的处理流程：

  收到包
    │
    ├─ 查哈希表 → 命中 → last_seen 超时？ ──→ 是 → 删除 + 重建
    │                         │
    │                         └── 否 → 更新 last_seen → 正常处理
    │
    └─ 未命中 → 创建新条目（last_seen = now）

  特点：只在有流量的连接上检查，没有流量的连接永远不会被检查到
  → 需要兜底
```

### 2.3 独立 GC 线程（兜底）

没有流量的"僵尸"连接需要靠 GC 清理：

```c
// 独立 lcore 跑 GC
static int
gc_lcore(void *arg)
{
    while (!quit) {
        conntrack_gc();        // 扫描一次
        rte_delay_us(100000);  // 100ms 后再扫（不忙等）
    }
    return 0;
}
```

### 2.4 两种触发的分工

```
                    有流量的连接                无流量的僵尸连接
                    ───────────                ──────────────
收包路径懒惰过期     ✓ 每包顺手检查              ✗ 没有包触发
独立 GC 线程        ✓ 也能清理                  ✓ 定期兜底清理

两者配合：
  收包路径：处理 99% 的活跃连接过期（零遍历开销）
  GC 线程：清理剩余 1% 的僵尸连接（定期遍历）
```

---

## 3. 全表 GC 扫描

### 3.1 最简单的 GC

```c
void
conntrack_gc(void)
{
    uint64_t now = rte_rdtsc();
    struct conntrack_entry *entry;
    uint32_t i;

    for (i = 0; i < conntrack_size; i++) {
        entry = &table[i];
        if (entry->used && IS_EXPIRED(entry, now, TIMEOUT_CYCLES)) {
            conntrack_remove(entry);
        }
    }
}
```

### 3.2 问题

```
表大小: 1,048,576 (2^20)
每条比较: ~20ns（rdtsc + 比较）
全表扫描: 1M × 20ns = 20ms

如果每 100ms 扫一次：
  GC 占 CPU: 20ms / 100ms = 20%   ← 太多了！

如果表更大：
  16M 条目 × 20ns = 320ms         ← 不可接受
```

### 3.3 适用场景

全表扫描只适合**小规模或低频 GC**：

```
✓ 表 < 1 万条，每秒 GC 一次
✓ 不追求极致性能的管理/监控场景
✗ 百万级 conntrack，100ms 级 GC 周期
```

---

## 4. 分片 GC（Sharded GC）

### 4.1 核心思想

全表扫描太慢 → **把表切成 N 片，每次只扫 1 片**。

和第八章时间轮的级联有异曲同工之处——都是把一个大范围切成小块，每次只处理一块，分摊开销：

```
全表 GC:
  每次: 扫描 0 ~ 1M                          耗时 20ms
  100ms 扫一次

分片 GC（64 片）:
  第 1 次: 扫描   0 ~ 16K                    耗时 0.3ms
  第 2 次: 扫描 16K ~ 32K                    耗时 0.3ms
  ...
  第 64 次: 扫描 992K ~ 1M                   耗时 0.3ms
  第 65 次: 绕回，扫描 0 ~ 16K               耗时 0.3ms

  每 100ms 扫 1 片 = 64 × 100ms = 6.4 秒扫完全表
  但每次只花 0.3ms，CPU 占比: 0.3ms / 100ms = 0.3%  ← 可接受
```

### 4.2 分片推进过程

```
时间轴（每 100ms 推进一格）:

  t=0s     t=0.1s   t=0.2s   t=0.3s  ...  t=6.3s   t=6.4s
   │         │         │         │           │         │
   ▼         ▼         ▼         ▼           ▼         ▼
 ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐     ┌─────┐ ┌─────┐
 │shard│ │shard│ │shard│ │shard│ ... │shard│ │shard│
 │  0  │ │  1  │ │  2  │ │  3  │     │ 63  │ │  0  │ ← 绕回
 │扫描中│ │等待 │ │等待 │ │等待 │     │等待 │ │扫描中│
 └─────┘ └─────┘ └─────┘ └─────┘     └─────┘ └─────┘

  gc_cursor:  0  →  1  →  2  →  3  → ... →  63  →  0

  每个条目最坏情况：被 GC 扫到的延迟 = 64 × 100ms = 6.4 秒
  → 对于 30 秒超时的 conntrack，6.4 秒的延迟可以接受
```

### 4.3 实现

```c
#define GC_SHARDS          64
#define GC_INTERVAL_US     100000  // 100ms

static uint64_t gc_cursor = 0;

void
conntrack_gc_shard(void)
{
    uint64_t now = rte_rdtsc();
    uint32_t shard = gc_cursor++ & (GC_SHARDS - 1);
    uint32_t start = shard * (conntrack_size / GC_SHARDS);
    uint32_t end   = start + (conntrack_size / GC_SHARDS);

    for (uint32_t i = start; i < end; i++) {
        if (table[i].used && IS_EXPIRED(&table[i], now, TIMEOUT_CYCLES)) {
            conntrack_remove(&table[i]);
        }
    }
}

// GC 线程
static int
gc_lcore(void *arg)
{
    while (!quit) {
        conntrack_gc_shard();
        rte_delay_us(GC_INTERVAL_US);
    }
    return 0;
}
```

### 4.4 分片数量选择

```
分片越多 → 每次扫描越快 → 但扫完全表的周期越长

┌──────────┬───────────┬────────────┬──────────────┐
│ 分片数    │ 每次扫描   │ 每次耗时    │ 全表周期      │
│          │ 条目数     │ (1M 表)     │ (100ms/轮)    │
├──────────┼───────────┼────────────┼──────────────┤
│ 8        │ 131K      │ 2.6ms      │ 0.8s         │
│ 16       │ 65K       │ 1.3ms      │ 1.6s         │
│ 64       │ 16K       │ 0.3ms      │ 6.4s         │
│ 256      │ 4K        │ 0.08ms     │ 25.6s        │
├──────────┼───────────┼────────────┼──────────────┤
│ 推荐选择  │           │            │              │
│ 64       │ 16K       │ 0.3ms      │ 6.4s         │
└──────────┴───────────┴────────────┴──────────────┘

经验法则：
  全表周期 ≈ 超时时间的 1/5 ~ 1/3
  30s 超时 → 全表周期 6~10s → 64~128 片
```

---

## 5. 多层时间桶（Multi-level Time Bucket）

### 5.1 动机

分片 GC 均匀扫描所有条目，但大部分过期集中在**长期不活跃的条目**。如果能把条目按活跃程度分桶，GC 优先扫不活跃的桶，效率更高。

### 5.2 三层桶结构

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        三层时间桶                                           │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  Hot Bucket（活跃桶）                                                       │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │  最近 5 秒内活跃的条目                                                │    │
│  │  GC 不扫这个桶（几乎不会过期）                                        │    │
│  │  收包路径：更新 last_seen，刷新桶位置                                 │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│       │                                                                     │
│       │ 超过 5 秒没活跃，降级                                               │
│       ▼                                                                     │
│  Warm Bucket（温桶）                                                       │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │  5~30 秒前活跃的条目                                                 │    │
│  │  GC 每轮扫这个桶的一部分（可能有过期的）                              │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│       │                                                                     │
│       │ 超过 30 秒没活跃，降级                                              │
│       ▼                                                                     │
│  Cold Bucket（冷桶）                                                       │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │  30 秒以上没活跃的条目                                                │    │
│  │  GC 优先扫这个桶（大部分都应该过期了）                                │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 5.3 桶的晋升与降级

```
收包命中条目:
  last_seen = now
  │
  └─ 无条件放入 Hot Bucket（收到包说明活跃）

GC 扫描:
  扫 Cold Bucket → 过期的删除 → 未过期的留在 Cold
  扫 Warm Bucket → 过期的删除 → 未过期的留在 Warm
  检查 Hot Bucket → 超过 5s 没活跃的 → 降级到 Warm
  检查 Warm Bucket → 超过 30s 没活跃的 → 降级到 Cold
```

### 5.4 GC 策略

```
GC 每轮扫描分配:

  Cold: 60% 的扫描配额  ← 大部分条目该过期了，值得扫
  Warm: 30% 的扫描配额  ← 少量过期
  Hot:  10% 的扫描配额  ← 只做降级检查，不检查过期

  好处:
  - 大部分过期条目集中在 Cold，GC 集中火力清理
  - Hot 桶几乎不需要扫描，活跃条目不被打扰
  - 总扫描量不变，但有效清理率更高
```

### 5.5 实现

```c
#define HOT_TIMEOUT   (5  * hz)   // 5 秒
#define WARM_TIMEOUT  (30 * hz)   // 30 秒
#define COLD_TIMEOUT  (30 * hz)   // 30 秒（超过就删除）

// 每个 bucket 是一个简单的链表头
struct conntrack_bucket {
    struct conntrack_entry *head;
    struct conntrack_entry *tail;
    uint32_t count;
};

static struct conntrack_bucket buckets[3]; // 0=hot, 1=warm, 2=cold

// 收包时：移到 Hot
void
conntrack_touch(struct conntrack_entry *entry)
{
    // 从当前 bucket 摘下
    list_remove(entry);

    // 插入 Hot bucket 头部
    entry->last_seen = rte_rdtsc();
    list_push_head(&buckets[BUCKET_HOT], entry);
}

// GC：检查降级和过期
void
conntrack_gc_buckets(void)
{
    uint64_t now = rte_rdtsc();
    struct conntrack_entry *entry, *next;

    // Cold bucket: 删除过期的
    for (entry = buckets[BUCKET_COLD].head; entry != NULL; entry = next) {
        next = entry->next;
        if (IS_EXPIRED(entry, now, COLD_TIMEOUT_CYCLES))
            conntrack_remove(entry);
    }

    // Warm bucket: 删除过期的 + 降级到 Cold
    for (entry = buckets[BUCKET_WARM].head; entry != NULL; entry = next) {
        next = entry->next;
        if (IS_EXPIRED(entry, now, WARM_TIMEOUT_CYCLES)) {
            // 超过 30s，降级到 Cold
            list_remove(entry);
            list_push_tail(&buckets[BUCKET_COLD], entry);
        } else if (IS_EXPIRED(entry, now, COLD_TIMEOUT_CYCLES)) {
            conntrack_remove(entry);
        }
    }

    // Hot bucket: 只降级到 Warm
    for (entry = buckets[BUCKET_HOT].head; entry != NULL; entry = next) {
        next = entry->next;
        if (IS_EXPIRED(entry, now, HOT_TIMEOUT_CYCLES)) {
            // 超过 5s，降级到 Warm
            list_remove(entry);
            list_push_tail(&buckets[BUCKET_WARM], entry);
        }
    }
}
```

### 5.6 三种方案对比

```
┌────────────────────┬──────────────┬──────────────┬──────────────────┐
│                    │ 全表 GC      │ 分片 GC      │ 多层时间桶       │
├────────────────────┼──────────────┼──────────────┼──────────────────┤
│ 每轮扫描量          │ 全部 (n)     │ 1/64 (n/64)  │ 按比例分配        │
│ 有效清理率          │ 低（大部分未过期）│ 中（均匀扫） │ 高（集中扫冷桶）│
│ CPU 开销            │ 高            │ 低            │ 低且更精准      │
│ 实现复杂度          │ 简单          │ 简单          │ 中等            │
│ 适用规模            │ <1 万        │ 百万级        │ 百万~千万级     │
├────────────────────┼──────────────┼──────────────┼──────────────────┤
│ 推荐                │ 小规模/简单场景 │ 通用方案      │ 大规模/高性能   │
└────────────────────┴──────────────┴──────────────┴──────────────────┘
```

---

## 6. 实战：简化版 Conntrack

### 6.1 整体架构

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    简化版 Conntrack 架构                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │  数据面 lcore 0~5                                                    │    │
│  │                                                                      │    │
│  │  收包 → conntrack_lookup() → 懒惰过期检查 → 更新 last_seen → 转发   │    │
│  │                                                                      │    │
│  │  conntrack_lookup: rte_hash_lookup()                               │    │
│  │  超时判断: rdtsc() - last_seen > timeout                           │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │  管理面 lcore 6                                                      │    │
│  │                                                                      │    │
│  │  分片 GC 循环:                                                       │    │
│  │  while (!quit) {                                                     │    │
│  │      conntrack_gc_shard();   // 扫 1/64 片                          │    │
│  │      rte_delay_us(100000);     // 100ms 间隔                        │    │
│  │  }                                                                   │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │  共享数据结构                                                        │    │
│  │                                                                      │    │
│  │  rte_hash (five-tuple → entry*)                                     │    │
│  │  entry pool (rte_mempool)                                           │    │
│  │  entry[]: { five_tuple, last_seen, state }                          │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 6.2 数据结构

```c
#include <rte_hash.h>
#include <rte_mempool.h>
#include <rte_cycles.h>

// 五元组 key
struct conntrack_key {
    uint32_t src_ip;
    uint32_t dst_ip;
    uint16_t src_port;
    uint16_t dst_port;
    uint8_t  proto;
} __rte_packed;

// 连接跟踪条目
struct conntrack_entry {
    struct conntrack_key key;
    uint64_t last_seen;       // TSC 时间戳
    uint8_t  state;           // NEW / ESTABLISHED / CLOSING
    uint32_t bytes;           // 统计：字节数
    uint32_t packets;         // 统计：包数

    // 用于 GC 遍历（链表或数组索引）
    struct conntrack_entry *gc_next;
};

// 超时配置（cycles，通过 rte_get_timer_hz() 转换）
static uint64_t timeout_tcp_established;
static uint64_t timeout_tcpClosing;
static uint64_t timeout_udp;
```

### 6.3 初始化

```c
#define CONNTRACK_MAX_ENTRIES (1 << 20)  // 1048576

static struct rte_hash *ct_hash;
static struct rte_mempool *ct_pool;

void
conntrack_init(void)
{
    struct rte_hash_parameters params = {
        .name = "conntrack",
        .entries = CONNTRACK_MAX_ENTRIES,
        .key_len = sizeof(struct conntrack_key),
        .hash_func = rte_hash_crc,
        .socket_id = rte_socket_id(),
    };

    ct_hash = rte_hash_create(&params);
    if (ct_hash == NULL)
        rte_exit(EXIT_FAILURE, "Failed to create conntrack hash");

    // 条目从 mempool 分配（复用第三章的 mempool 机制）
    ct_pool = rte_mempool_create("ct_pool",
        CONNTRACK_MAX_ENTRIES,
        sizeof(struct conntrack_entry),
        128,   // cache size
        0,     // private data
        NULL, NULL,   // mp_init, mp_init_arg
        NULL, NULL,   // obj_init, obj_init_arg
        rte_socket_id(), 0);
    if (ct_pool == NULL)
        rte_exit(EXIT_FAILURE, "Failed to create conntrack mempool");

    // 超时转换：秒 → TSC cycles
    uint64_t hz = rte_get_timer_hz();
    timeout_tcp_established = 30 * hz;  // TCP established: 30s
    timeout_tcpClosing    = 10 * hz;  // TCP closing: 10s
    timeout_udp           = 30 * hz;  // UDP: 30s
}
```

### 6.4 收包路径（懒惰过期）

```c
static struct conntrack_entry *
conntrack_process(struct rte_mbuf *pkt)
{
    struct conntrack_key key;
    struct conntrack_entry *entry;
    uint64_t now = rte_rdtsc();
    uint64_t timeout;
    int ret;

    // 1. 从包中提取五元组
    extract_five_tuple(pkt, &key);

    // 2. 查找
    ret = rte_hash_lookup_data(ct_hash, &key, (void **)&entry);

    if (ret >= 0 && entry != NULL) {
        // 命中：检查是否过期
        switch (entry->key.proto) {
        case IPPROTO_UDP: timeout = timeout_udp; break;
        case IPPROTO_TCP: timeout = timeout_tcp_established; break;
        default:          timeout = timeout_udp; break;
        }

        if (now - entry->last_seen > timeout) {
            // 过期：删除旧条目
            rte_hash_del_key(ct_hash, &key);
            rte_mempool_put(ct_pool, entry);
            // fall through: 创建新条目
            goto create;
        }

        // 未过期：更新时间戳和统计
        entry->last_seen = now;
        entry->packets++;
        entry->bytes += pkt->pkt_len;
        return entry;
    }

create:
    // 3. 未命中或过期重建：分配新条目
    if (rte_mempool_get(ct_pool, (void **)&entry) != 0) {
        // pool 耗尽，触发紧急 GC
        conntrack_gc_emergency();
        return NULL;
    }

    rte_memcpy(&entry->key, &key, sizeof(key));
    entry->last_seen = now;
    entry->state = CT_NEW;
    entry->bytes = pkt->pkt_len;
    entry->packets = 1;
    entry->gc_next = NULL;

    // 插入哈希表
    ret = rte_hash_add_key_data(ct_hash, &key, entry);
    if (ret < 0) {
        rte_mempool_put(ct_pool, entry);
        return NULL;
    }

    return entry;
}
```

### 6.5 分片 GC 实现

```c
#define GC_SHARDS      64
#define GC_INTERVAL_US 100000   // 100ms

static uint64_t gc_cursor = 0;

void
conntrack_gc_shard(void)
{
    uint64_t now = rte_rdtsc();
    uint32_t shard = gc_cursor++ & (GC_SHARDS - 1);

    // 遍历哈希表的对应分片
    const void *next_key;
    void *next_data;
    uint32_t iter = 0;
    uint32_t count = 0;
    uint32_t expired = 0;

    // rte_hash_iterate 遍历所有条目
    // 注意：实际实现中可以用 rte_hash 的内部数组按分片范围遍历
    // 这里简化为全表遍历 + 分片跳过
    while (rte_hash_iterate(ct_hash, &next_key, &next_data, &iter) >= 0) {
        struct conntrack_entry *entry = next_data;

        // 简单分片：用 hash(key) % GC_SHARDS 判断是否属于当前分片
        uint32_t entry_shard = rte_hash_crc(next_key, sizeof(struct conntrack_key), 0)
                               & (GC_SHARDS - 1);
        if (entry_shard != shard)
            continue;

        count++;

        uint64_t timeout;
        switch (entry->key.proto) {
        case IPPROTO_UDP: timeout = timeout_udp; break;
        case IPPROTO_TCP: timeout = timeout_tcp_established; break;
        default:          timeout = timeout_udp; break;
        }

        if (now - entry->last_seen > timeout) {
            rte_hash_del_key(ct_hash, next_key);
            rte_mempool_put(ct_pool, entry);
            expired++;
        }
    }

    if (expired > 0) {
        RTE_LOG(DEBUG, CT, "GC shard %u: scanned %u, expired %u\n",
                shard, count, expired);
    }
}

// 紧急 GC（pool 耗尽时调用）
void
conntrack_gc_emergency(void)
{
    uint64_t now = rte_rdtsc();
    const void *next_key;
    void *next_data;
    uint32_t iter = 0;
    uint32_t freed = 0;

    while (rte_hash_iterate(ct_hash, &next_key, &next_data, &iter) >= 0) {
        struct conntrack_entry *entry = next_data;
        if (now - entry->last_seen > timeout_udp) {
            rte_hash_del_key(ct_hash, next_key);
            rte_mempool_put(ct_pool, entry);
            freed++;
            if (freed >= 1024) break;  // 每次最多释放 1024 个
        }
    }
}
```

### 6.6 GC 线程启动

```c
static int
gc_lcore(void *arg)
{
    RTE_LOG(INFO, CT, "GC lcore %u started\n", rte_lcore_id());

    while (!force_quit) {
        conntrack_gc_shard();
        rte_delay_us(GC_INTERVAL_US);
    }

    return 0;
}

// main 中启动
int main(int argc, char **argv)
{
    // ... EAL init, port init ...

    conntrack_init();

    // 数据面 lcore
    rte_eal_mp_remote_launch(pkt_process_lcore, NULL, SKIP_MAIN);

    // GC lcore（用最后一个 lcore）
    rte_eal_remote_launch(gc_lcore, NULL, gc_lcore_id);

    rte_eal_mp_wait_lcore();
    return 0;
}
```

---

## 7. 与 rte_timer 的对比分析

### 7.1 内存对比

```
假设：100 万条并发连接

rte_timer 方案:
  struct rte_timer:  ~40 字节/flow
  100 万 × 40B = 40MB
  额外：4 级时间轮 = 4 × 64 × 8B = 2KB

懒惰过期方案:
  uint64_t last_seen: 8 字节/flow
  100 万 × 8B = 8MB
  额外：哈希表开销 ≈ 16MB（rte_hash 内部）

节省: 40MB → 8MB，降低 80%
```

### 7.2 CPU 开销对比

```
假设：每秒 1000 万包，100 万条连接

rte_timer 方案:
  timer_manage: 每次调 O(1)，但每条流需要一个 rte_timer_reset
  包路径: conntrack_lookup + rte_timer_reset = ~100ns/包
  timer_manage: 1000 万次/s × 10ns = 100ms/s

懒惰过期方案:
  包路径: conntrack_lookup + 一次比较 = ~80ns/包
  GC: 每 100ms 扫 1/64 表 = 0.3ms，CPU 占比 0.3%
  总计: ~800ms/s（包路径） + 3ms/s（GC） = 803ms/s

rte_timer 包路径多出的开销:
  1000 万 × 20ns = 200ms/s（rte_timer_reset 调用）
```

### 7.3 精度对比

```
rte_timer:
  精度 = timer_manage 调用间隔
  如果主循环 1μs 调一次 → 精度 1μs
  到期时立即执行回调

懒惰过期:
  精度取决于两个因素:
    1. 收包路径：有包来才能检查，没有包就无法检查
    2. GC 线程：最坏延迟 = 全表周期（分片数 × GC 间隔）
       64 片 × 100ms = 6.4s

  对于 conntrack 场景：30s 超时，6.4s 延迟完全可接受
  对于 TCP RTO 场景：毫秒级超时，6.4s 延迟不可接受 → 用 rte_timer
```

### 7.4 选型指南

```
┌──────────────────────────┬───────────────────┬───────────────────────────┐
│ 场景                     │ 推荐方案           │ 原因                      │
├──────────────────────────┼───────────────────┼───────────────────────────┤
│ Conntrack / NAT 会话管理  │ 懒惰过期 + 分片 GC │ 百万级 flow，秒级精度够用  │
│ TCP 重传 (RTO)           │ rte_timer          │ 毫秒级精度，需要立即回调    │
│ LACP 心跳                │ rte_timer          │ 数量少，需要精确周期触发    │
│ ARP 表老化               │ 懒惰过期 + GC      │ 数万条，分钟级精度          │
│ 统计上报                 │ rte_timer          │ 周期触发，数量极少          │
│ IPsec SA 重密钥          │ rte_timer          │ 数量中等，需要精确定时      │
│ 防火墙规则超时           │ 懒惰过期 + GC      │ 数百万条规则，秒级精度      │
│ 链路聚合 (Bonding)       │ rte_timer          │ 端口级，数量极少            │
└──────────────────────────┴───────────────────┴───────────────────────────┘

简单判断标准:
  数量 > 10 万 + 精度要求 ≥ 1 秒 → 懒惰过期 + GC
  数量 < 1 万  或 精度要求 < 1 秒 → rte_timer
  两者都有                           → 混合使用
```

---

## 8. 小结

本章核心要点：

1. **rte_timer 的局限**：per-flow 场景下每个 `rte_timer` 结构体 40 字节，百万级连接内存开销不可接受。

2. **懒惰过期原理**：不设定时器，只记 `last_seen` 时间戳，收包时顺便比较是否超时。零额外遍历开销，但有"僵尸连接"无法清理的问题。

3. **全表 GC**：最简单的兜底方案，O(n) 扫描，适合小规模。

4. **分片 GC**：把表切成 N 片，每次扫 1 片，分摊到 O(1)。和第八章的时间轮级联有异曲同工之妙——都是"切碎了慢慢来"。

5. **多层时间桶**：按活跃程度分桶，GC 优先扫冷桶，提高有效清理率。

6. **Conntrack 实战**：基于 `rte_hash` + `rte_mempool` + TSC 时间戳 + 分片 GC 的完整实现。

7. **选型**：百万级 + 秒级精度用懒惰过期，少量 + 毫秒级精度用 rte_timer，两者可混合使用。

**核心思想**：懒惰过期不是"偷懒不做"，而是**把过期检查嵌入到已有的执行路径中**，用 O(1) 的比较替代 O(n) 的定时器管理。GC 是兜底机制，用分摊的方式控制开销。两者配合，用最小的代价实现百万级连接的超时管理。

---

> [!tip] 参考文献
>
> - Linux Netfilter conntrack: https://www.kernel.org/doc/html/latest/networking/nf_conntrack-sysctl.html
> - "Cuckoo Switching: Hash Table Design for DPDK", https://dpdk.org/doc/guides/prog_guide/hash_lib.html
> - VPP (Vector Packet Processor) connection tracking design
> - Intel, "DPDK Hash Library", https://doc.dpdk.org/guides/prog_guide/hash_lib.html
