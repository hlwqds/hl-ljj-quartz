---
title: "DPDK 深度探索 (二十八)：多核同步——Spinlock、RCU、Memory Reorder"
date: 2026-04-09
tags:
  [
    dpdk,
    series,
    spinlock,
    rcu,
    memory-reorder,
    lock-free,
    mcs-lock,
    memory-barrier,
    synchronization,
    multicore,
  ]
description: "深入理解 DPDK 多核同步机制——Spinlock、MCS Lock、RCU 读写锁、Memory Reorder、Memory Barrier、CAS、ABA 问题"
---

> [!info] DPDK 深度探索系列 0. [[dpdk-deep-dive|全栈学习路径总览]]
> 1-27. 前二十七章已完成 28. **第二十八章：多核同步——Spinlock、RCU、Memory Reorder**

---

## 1. 概述：为什么需要同步

### 1.1 多核并发问题

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        多核并发数据竞争                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  问题: 多个 CPU 同时访问共享数据                                             │
│  ────                                                                    │
│                                                                             │
│  Core 0                           Core 1                                    │
│  ┌─────────────────┐           ┌─────────────────┐                      │
│  │ read x = 0      │           │ read x = 0      │                      │
│  │                 │           │                 │                      │
│  │ x = x + 1       │           │ x = x + 1       │                      │
│  │   │             │           │   │             │                      │
│  │   └──> 读x(0)   │           │   └──> 读x(0)   │                      │
│  │   └──> 加1      │           │   └──> 加1      │                      │
│  │   └──> 写x(1)   │           │   └──> 写x(1)   │                      │
│  │                 │           │                 │                      │
│  └─────────────────┘           └─────────────────┘                      │
│              │                         │                                   │
│              └────────┬────────────────┘                                    │
│                       ▼                                                    │
│                ┌─────────────┐                                            │
│                │ 最终 x = 1  │  (期望 x = 2!)                              │
│                │   竞争条件   │                                            │
│                └─────────────┘                                            │
│                                                                             │
│  竞争条件 (Race Condition):                                               │
│  ─────────────────────────                                                │
│  - 两个或更多线程同时访问共享资源                                           │
│  - 至少一个访问是写操作                                                   │
│  - 访问顺序不确定                                                         │
│                                                                             │
│  结果: 程序行为依赖于线程 调度顺序，不可预测                                │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 1.2 同步原语分类

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        同步原语分类                                         │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  1. 原子操作 (Atomic Operations)                                          │
│  ───────────────────────────────────                                        │
│  - 不可中断的读-改-写操作                                                   │
│  - 示例: 原子加、原子比较交换 (CAS)                                        │
│  - 用途: 计数器、简单标志                                                   │
│                                                                             │
│  2. 锁 (Locks)                                                            │
│  ───────────                                                                │
│  - 互斥锁: 一次只允许一个线程                                              │
│  - 读写锁: 读并发、写互斥                                                  │
│  - spinlock: 忙等待锁                                                      │
│  - 用途: 保护复杂数据结构                                                   │
│                                                                             │
│  3. 内存屏障 (Memory Barriers)                                            │
│  ───────────────────────────────                                            │
│  - 防止指令重排                                                             │
│  - 保证内存访问顺序                                                         │
│  - 用途: lock-free 算法                                                    │
│                                                                             │
│  4. RCU (Read-Copy-Update)                                                │
│  ─────────────────────                                                      │
│  - 读多写少场景的无锁读取                                                  │
│  - 延迟删除/更新                                                            │
│  - 用途: 路由表、监听者列表                                                │
│                                                                             │
│  5. 无锁数据结构 (Lock-Free)                                              │
│  ───────────────────────────                                                │
│  - 使用 CAS 实现线程安全                                                   │
│  - 避免锁的开销                                                             │
│  - 用途: 高性能队列、哈希表                                                │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Memory Reorder

### 2.1 编译器和 CPU 重排

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        Memory Reorder 问题                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  编译器重排 (Compiler Reorder):                                            │
│  ─────────────────────────────                                              │
│  编译器优化可能改变代码顺序以提高性能                                       │
│                                                                             │
│  源代码:                           可能重排为:                              │
│  ────────────                      ────────────                              │
│  data = 42;                        flag = true;   // flag 先于 data!        │
│  flag = true;                      data = 42;                              │
│  // 另一线程: 如果先看到 flag==true,                              │
│  // 可能 data 还是旧值                                          │
│                                                                             │
│  ─────────────────────────────────────────────────────────────────────────  │
│                                                                             │
│  CPU 重排 (CPU Reorder):                                                   │
│  ───────────────────                                                        │
│  CPU 执行流水线可能改变内存访问顺序                                         │
│                                                                             │
│  程序顺序:                          实际执行顺序:                            │
│  ────────────                         ────────────                          │
│  1. write x = 1                      1. write x = 1                       │
│  2. write y = 1                      2. write y = 1                       │
│  3. read  a = y                       3. read  a = y (有时 x 还未可见!)  │
│                                                                             │
│  原因: Store Buffer / Load Buffer / Write Combine / Cache                 │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 2.2 x86/x64 内存模型

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        x86/x64 内存模型                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  x86/x64 是 TSO (Total Store Order) 模型:                                 │
│  ─────────────────────────────────────────                                  │
│                                                                             │
│  保证:                                                                    │
│  - 同一 CPU: 指令按程序顺序执行 (有例外)                                    │
│  - stores 按顺序对其他 CPU 可见 (基本保证)                                 │
│  - loads 可以绕过之前的 stores (弱于 SC)                                   │
│                                                                             │
│  示例: Store Buffer 导致的问题                                             │
│  ────────────────────────────────                                           │
│                                                                             │
│  初始: x = 0, y = 0                                                        │
│                                                                             │
│  CPU 0:                      CPU 1:                                        │
│  store x = 1                 store y = 1                                   │
│  load  r1 = y                load  r2 = x                                  │
│                                                                             │
│  可能结果: r1 = 0, r2 = 0 (Store Buffer 导致)                             │
│  如果是 SC (Sequential Consistency): r1 和 r2 不能同时为 0                 │
│                                                                             │
│  ─────────────────────────────────────────────────────────────────────────  │
│                                                                             │
│  x86 mfence 指令:                                                         │
│  ──────────────────                                                        │
│  mfence: 刷新 Store Buffer，确保所有 store 在 load 之前                    │
│          清空 Load Buffer，确保后续 load 看到之前的 store                  │
│                                                                             │
│  使用场景:                                                                 │
│  - lock 前后的操作                                                         │
│  - 驱动和 DMA 之间的同步                                                   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 2.3 ARM/POWER 内存模型

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        ARM/POWER 内存模型                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ARM/POWER 是弱内存模型 (Weak Memory Model):                              │
│  ────────────────────────────────────────────                               │
│                                                                             │
│  允许更多重排:                                                             │
│  - Store 可以被延迟到更晚                                                   │
│  - Load 可以提前执行                                                       │
│  - 不同 CPU 可能看到不同的访问顺序                                          │
│                                                                             │
│  示例:                                             │
│  ──────                                             │
│                                                                             │
│  初始: x = 0, y = 0, r1 = r2 = r3 = r4 = 0                                 │
│                                                                             │
│  CPU 0:               CPU 1:               CPU 2:               CPU 3:    │
│  store x = 1          store y = 1           load r1 = x          load r2 = y│
│                        load r3 = x          store r4 = 1              │      │
│                                                                             │
│  可能结果 (弱内存模型): r1=1, r2=1, r3=0, r4=0                             │
│  (即使 CPU 0/1 先完成 store，CPU 2/3 可能看到不同顺序)                     │
│                                                                             │
│  ─────────────────────────────────────────────────────────────────────────  │
│                                                                             │
│  ARM/POWER 屏障指令:                                                      │
│  ─────────────────────                                                      │
│                                                                             │
│  ARM:   dmb sy   (数据内存屏障，所有 barrier)                               │
│         dmb st   (store barrier)                                           │
│         dmb ld   (load barrier)                                            │
│         dsb sy   (数据同步屏障，比 dmb 更强)                                │
│         isb     (指令同步屏障，冲洗流水线)                                  │
│                                                                             │
│  POWER: sync     (完整屏障)                                                │
│         lwsync  (轻量级同步，store->load 排序)                             │
│         eieio   (in-order execution, store->store)                        │
│         isync   (指令同步)                                                 │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Memory Barrier (内存屏障)

### 3.1 屏障类型

```c
// 内存屏障类型

// 1. 完整屏障 (Full Barrier)
#define rte_mb() asm volatile("mfence" ::: "memory")

// 阻止所有类型的重排
// - 所有之前的 load/store 必须完成
// - 所有之后的 load/store 必须开始

// 2. 读屏障 (Read Barrier / Load Barrier)
#define rte_rmb() asm volatile("lfence" ::: "memory")

// - 所有之前的 load 必须完成
// - 之后的 load 不能提前

// 3. 写屏障 (Write Barrier / Store Barrier)
#define rte_wmb() asm volatile("sfence" ::: "memory")

// - 所有之前的 store 必须完成
// - 之后的 store 不能延后

// 跨平台 DPDK 实现
#ifdef RTE_ARCH_X86
    #define rte_mb()  asm volatile("mfence" ::: "memory")
    #define rte_wmb() asm volatile("sfence" ::: "memory")
    #define rte_rmb() asm volatile("lfence" ::: "memory")
#elif defined(RTE_ARCH_ARM64)
    #define rte_mb()  asm volatile("dmb sy" ::: "memory")
    #define rte_wmb() asm volatile("dmb sy" ::: "memory")  // ARM64 简化
    #define rte_rmb() asm volatile("dmb sy" ::: "memory")
#endif

// 编译器屏障 (阻止编译器重排，不阻止 CPU 重排)
#define rte_compiler_barrier() asm volatile("" ::: "memory")

// 应用场景
void
barrier_usage_examples(void)
{
    volatile int flag = 0;
    int data = 0;

    // 场景 1: 写数据，然后设置标志
    data = 42;                    // 写数据
    rte_wmb();                   // 确保数据在标志之前被写入
    flag = 1;                    // 设置标志

    // 场景 2: 读取标志，然后读取数据
    if (flag == 1) {            // 读取标志
        rte_rmb();              // 确保后续读在标志读之后
        use(data);              // 现在可以安全读取数据
    }

    // 场景 3: lock/unlock 之间的操作
    rte_mb();                   // lock 通常隐含完整屏障
    // 临界区操作
    rte_mb();                   // unlock 通常隐含完整屏障
}
```

### 3.2 C11/C++11 原子操作与屏障

```c
// C11 内存顺序模型

#include <stdatomic.h>

// 内存顺序级别 (从强到弱)
typedef enum {
    memory_order_relaxed,   // 无同步，仅原子性
    memory_order_consume,   // 数据依赖排序 (ARM)
    memory_order_acquire,   // 获取屏障
    memory_order_release,   // 释放屏障
    memory_order_acq_rel,   // 获取+释放
    memory_order_seq_cst,   // 顺序一致 (最强)
} memory_order;

// 示例 1: 顺序一致 (最安全，性能最低)
atomic_int counter_seq_cst = ATOMIC_VAR_INIT(0);

void
increment_seq_cst(void)
{
    atomic_fetch_add_explicit(&counter_seq_cst, 1, memory_order_seq_cst);
}

// 示例 2: Release-Acquire (lock-free 同步)
_Atomic(void *) shared_ptr = NULL;

void
producer(void)
{
    void *data = malloc(100);
    init_data(data);

    // release 屏障: 之前的写不能重排到 release 之后
    atomic_store_explicit(&shared_ptr, data, memory_order_release);
}

void
consumer(void)
{
    void *data;

    // acquire 屏障: 之后的读不能重排到 acquire 之前
    while ((data = atomic_load_explicit(&shared_ptr, memory_order_acquire)) == NULL)
        ; // spin

    use_data(data);  // 保证能看到 producer 中 init_data 的结果
}

// 示例 3: Release-Relaxed (仅原子性，无同步)
_Atomic uint64_t counter_relaxed = 0;

void
increment_relaxed(void)
{
    // 仅保证原子性，不保证跨线程可见顺序
    atomic_fetch_add_explicit(&counter_relaxed, 1, memory_order_relaxed);
}

// 示例 4: Acquire-Relaxed (消费依赖)
struct node {
    int data;
    struct node *next;
};

_Atomic(struct node *) head = NULL;

void
push(struct node *new_node)
{
    new_node->next = atomic_load(&head);
    atomic_store(&head, new_node);  // release
}

// consume 用于数据依赖链
struct node *
pop(void)
{
    struct node *node = atomic_load_explicit(&head, memory_order_consume);
    // 实际在 ARM 上，编译器发出 ldapr (load acquire-reserved)

    if (node)
        use(node->data);  // node->next 可能还未正确同步

    return node;
}
```

### 3.3 DPDK 原子操作

```c
// lib/eal/include/rte_atomic.h

// 基础原子类型
typedef struct {
    volatile int32_t cnt;
} rte_atomic32_t;

typedef struct {
    volatile int64_t cnt;
} rte_atomic64_t;

// 原子加
static inline int32_t
rte_atomic32_add(rte_atomic32_t *v, int32_t delta)
{
    return __atomic_add_fetch(&v->cnt, delta, __ATOMIC_ACQ_REL);
}

// 原子减
static inline int32_t
rte_atomic32_sub(rte_atomic32_t *v, int32_t delta)
{
    return __atomic_sub_fetch(&v->cnt, delta, __ATOMIC_ACQ_REL);
}

// 原子比较交换 (CAS)
static inline int
rte_atomic32_cmpxchg(rte_atomic32_t *v, int32_t old, int32_t new_val)
{
    return __atomic_compare_exchange_n(&v->cnt, &old, new_val, 0,
                                        __ATOMIC_ACQ_REL,
                                        __ATOMIC_RELAXED);
}

// 原子 64 位操作
static inline int64_t
rte_atomic64_add(rte_atomic64_t *v, int64_t delta)
{
    return __atomic_add_fetch(&v->cnt, delta, __ATOMIC_ACQ_REL);
}

// 64 位 CAS (有些平台需要特殊处理)
#ifdef RTE_ARCH_64
static inline int64_t
rte_atomic64_cmpxchg(rte_atomic64_t *v, int64_t old, int64_t new_val)
{
    return __atomic_compare_exchange_n(&v->cnt, &old, new_val, 0,
                                        __ATOMIC_ACQ_REL,
                                        __ATOMIC_RELAXED);
}
#else
// 32 位平台使用软件实现 (可能有锁)
#endif

// 典型使用模式: 引用计数
static inline uint16_t
rte_mbuf_refcnt_update(struct rte_mbuf *m, int16_t val)
{
    return rte_atomic16_add(&m->refcnt, val);
}

static inline uint16_t
rte_mbuf_refcnt_read(const struct rte_mbuf *m)
{
    return rte_atomic16_read(&m->refcnt);
}

static inline int
rte_mbuf_refcnt_test_and_set(struct rte_mbuf *m)
{
    return rte_atomic16_test_and_set(&m->refcnt);
}
```

---

## 4. Spinlock

### 4.1 基础自旋锁

```c
// 基础自旋锁实现

struct rte_spinlock_t {
    volatile int locked;  // 0 = unlocked, 1 = locked
};

// 初始化
static inline void
rte_spinlock_init(rte_spinlock_t *sl)
{
    sl->locked = 0;
}

// 获取锁 (忙等待)
static inline void
rte_spinlock_lock(rte_spinlock_t *sl)
{
    // 使用 x86 xchg 指令 (原子交换)
    // while (xchg(&sl->locked, 1) == 1) pause();
    while (__atomic_test_and_set(&sl->locked, __ATOMIC_ACQUIRE)) {
        // pause 指令减少 CPU 功耗和竞争
        asm volatile("pause" ::: "memory");
    }
}

// 尝试获取锁 (非阻塞)
static inline int
rte_spinlock_trylock(rte_spinlock_t *sl)
{
    return !__atomic_test_and_set(&sl->locked, __ATOMIC_ACQUIRE);
}

// 释放锁
static inline void
rte_spinlock_unlock(rte_spinlock_t *sl)
{
    __atomic_clear(&sl->locked, __ATOMIC_RELEASE);
}

// 使用示例
rte_spinlock_t stats_lock = RTE_SPINLOCK_INITIALIZER;

void
update_stats(uint64_t packets, uint64_t bytes)
{
    rte_spinlock_lock(&stats_lock);

    total_packets += packets;
    total_bytes += bytes;

    rte_spinlock_unlock(&stats_lock);
}
```

### 4.2 MCS Lock (队列自旋锁)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        MCS Lock 原理                                        │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  问题: 基础自旋锁导致 Cache Line 竞争                                       │
│  ─────────────────────────────────                                          │
│                                                                             │
│  所有等待的 CPU 都尝试修改同一个 cache line (locked 标志)                  │
│  → 每次 unlock 都导致所有 waiting CPU 的 cache line 失效                    │
│  → "指定信号量"问题                                                         │
│                                                                             │
│  MCS Lock 解决方案:                                                        │
│  ──────────────────                                                        │
│                                                                             │
│  每个 CPU 有自己的节点，修改自己的 cache line                               │
│  通过链表形成队列                                                           │
│                                                                             │
│  Node 结构:                                                               │
│  ┌─────────────────────────────────────────────────────────────────────┐ │
│  │  struct mcs_node {                                                  │ │
│  │      volatile int locked;  // 是否有后继需要等待                     │ │
│  │      struct mcs_node *next; // 后继节点                             │ │
│  │  };                                                                  │ │
│  └─────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
│  MCS Lock 流程:                                                            │
│  ─────────────                                                             │
│                                                                             │
│  Thread A (CPU 0) 获取锁:                                                 │
│  ┌─────────────────────────────────────────────────────────────────────┐ │
│  │  Node A.next = NULL                                                │ │
│  │  Node *prev = atomic_set(&lock, Node A)  // swap                   │ │
│  │  if (prev == NULL) {                                               │ │
│  │      // 没有后继，获取锁成功                                         │ │
│  │  } else {                                                          │ │
│  │      prev->next = Node A      // 前驱指向我                        │ │
│  │      while (Node A.locked)     // 等待前驱解锁通知                  │ │
│  │          pause();                                                  │ │
│  │  }                                                                  │ │
│  └─────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
│  Thread B (CPU 1) 获取锁:                                                 │
│  ┌─────────────────────────────────────────────────────────────────────┐ │
│  │  Node B.next = NULL                                                │ │
│  │  Node *prev = atomic_set(&lock, Node B)                             │ │
│  │  // 此时 lock 指向 Node A                                           │ │
│  │  prev->next = Node B        // Node A->next = Node B               │ │
│  │  Node B.locked = 1           // 我需要等待                          │ │
│  │  while (Node B.locked)       // 等待                                 │ │
│  │      pause();                                                      │ │
│  │  // 被 Thread A 解锁唤醒                                           │ │
│  └─────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
│  Thread A 释放锁:                                                         │
│  ┌─────────────────────────────────────────────────────────────────────┐ │
│  │  if (Node A.next == NULL) {     // 没有后继？                        │ │
│  │      // CAS 将 lock 从 Node A 改为 NULL                            │ │
│  │      if (atomic_cmpxchg(&lock, Node A, NULL) == Node A) {          │ │
│  │          return;  // 成功，解锁完成                                  │ │
│  │      }                                                              │ │
│  │  }                                                                  │ │
│  │  // 有后继，唤醒它                                                  │ │
│  │  Node A.next->locked = 0;    // 通知后继                            │ │
│  └─────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
│  优势:                                                                    │
│  - 每个 CPU 只修改自己的 node                                               │
│  - unlock 只唤醒一个 CPU                                                   │
│  - 无 Cache Line 竞争                                                     │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 4.3 MCS Lock 实现

```c
// MCS Lock 实现 (DPDK 类似实现)

struct rte_mcs_lock {
    volatile struct rte_mcs_lock_node *tail;
} __attribute__((aligned(RTE_CACHE_LINE_SIZE)));

struct rte_mcs_lock_node {
    volatile struct rte_mcs_lock_node *next;
    volatile int locked;
};

// 获取锁
static inline void
rte_mcs_lock(struct rte_mcs_lock *l, struct rte_mcs_lock_node *node)
{
    node->next = NULL;

    // 将自己加到队尾，返回前一个尾节点
    struct rte_mcs_lock_node *prev =
        __atomic_exchange_n(&l->tail, node, __ATOMIC_ACQ_REL);

    if (prev != NULL) {
        // 前任存在，我需要等待
        prev->next = node;
        node->locked = 1;

        // 等待前驱解锁
        while (node->locked)
            asm volatile("pause" ::: "memory");
    }
}

// 释放锁
static inline void
rte_mcs_unlock(struct rte_mcs_lock *l, struct rte_mcs_lock_node *node)
{
    struct rte_mcs_lock_node *next = node->next;

    if (next == NULL) {
        // 我可能是最后一个，尝试移除自己
        if (__atomic_compare_exchange_n(&l->tail, &node, NULL, 0,
                                         __ATOMIC_RELEASE,
                                         __ATOMIC_RELAXED)) {
            // 成功，没有后继
            return;
        }

        // CAS 失败，有新节点加入，等待它设置 next
        while (node->next == NULL)
            asm volatile("pause" ::: "memory");

        next = node->next;
    }

    // 唤醒后继
    next->locked = 0;
}

// TLS 节点 (每线程一个)
__thread struct rte_mcs_lock_node mcs_node;

// 使用
rte_mcs_lock(&big_lock, &mcs_node);
// 临界区
rte_mcs_unlock(&big_lock, &mcs_node);
```

### 4.4 读写锁

```c
// 读写锁实现

struct rte_rwlock_t {
    volatile int32_t cnt;    // 正数: 读者数量，负数: 写者持有
};

// 读锁
static inline void
rte_rwlock_read_lock(rte_rwlock_t *rwl)
{
    int32_t old, new_val;

    do {
        old = rwl->cnt;
        new_val = old + 1;

        if (new_val > 0x7FFFFFFF)  // 溢出检查
            rte_panic("RWLock overflow\n");

    } while (!__atomic_compare_exchange_n(&rwl->cnt, &old, new_val, 0,
                                          __ATOMIC_ACQ_REL,
                                          __ATOMIC_RELAXED));
}

// 读锁尝试
static inline int
rte_rwlock_read_trylock(rte_rwlock_t *rwl)
{
    int32_t old = rwl->cnt;
    int32_t new_val;

    do {
        if (old < 0)  // 有写者
            return 0;

        new_val = old + 1;

    } while (!__atomic_compare_exchange_n(&rwl->cnt, &old, new_val, 0,
                                          __ATOMIC_ACQ_REL,
                                          __ATOMIC_RELAXED));

    return 1;
}

// 读锁解锁
static inline void
rte_rwlock_read_unlock(rte_rwlock_t *rwl)
{
    __atomic_fetch_sub(&rwl->cnt, 1, __ATOMIC_RELEASE);
}

// 写锁
static inline void
rte_rwlock_write_lock(rte_rwlock_t *rwl)
{
    int32_t old;

    do {
        old = 0;  // 期望无读者、无写者

    } while (!__atomic_compare_exchange_n(&rwl->cnt, &old, -1, 0,
                                          __ATOMIC_ACQ_REL,
                                          __ATOMIC_RELAXED));
}

// 写锁尝试
static inline int
rte_rwlock_write_trylock(rte_rwlock_t *rwl)
{
    int32_t old = 0;  // 期望无读者、无写者

    if (__atomic_compare_exchange_n(&rwl->cnt, &old, -1, 0,
                                     __ATOMIC_ACQ_REL,
                                     __ATOMIC_RELAXED))
        return 1;  // 成功获取写锁

    return 0;  // 有读者或写者
}

// 写锁解锁
static inline void
rte_rwlock_write_unlock(rte_rwlock_t *rwl)
{
    __atomic_store_n(&rwl->cnt, 0, __ATOMIC_RELEASE);
}

// 使用示例
rte_rwlock_t rwlock = RTE_RWLOCK_INITIALIZER;

// 读操作 (可并发)
void
read_routing_table(void)
{
    rte_rwlock_read_lock(&rwlock);

    for (int i = 0; i < num_entries; i++)
        use(route[i]);

    rte_rwlock_read_unlock(&rwlock);
}

// 写操作 (独占)
void
update_routing_table(struct route_entry *new_routes, int count)
{
    rte_rwlock_write_lock(&rwlock);

    memcpy(route, new_routes, count * sizeof(struct route_entry));

    rte_rwlock_write_unlock(&rwlock);
}
```

---

## 5. RCU (Read-Copy-Update)

> [!tip] RCU 原理与实现详解
>
> 本章聚焦于 DPDK RCU 的 API 和使用模式。如果想深入理解 RCU 的底层原理——包括 Linux 内核抢占机制如何决定 RCU 实现方式、Tree RCU 状态机、QSBR 的 token 机制、以及 Linux 与 DPDK RCU 的完整流程对比，请参阅：[[2026-05-27-rcu-deep-dive-linux-vs-dpdk|RCU 原理深度解析：Linux 内核与 DPDK 实现对比]]

### 5.1 RCU 原理

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        RCU 原理                                            │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  RCU 核心思想:                                                             │
│  ─────────────                                                              │
│  - 读者: 无锁、无原子操作、无内存屏障 (最快)                                │
│  - 写者: 延迟删除旧数据，直到所有读者离开临界区                              │
│                                                                             │
│  适用场景: 读多写少                                                         │
│  ───────────                                                                │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐ │
│  │                     RCU 保护的数据结构                               │ │
│  │                                                                      │ │
│  │   ┌─────────┐   ┌─────────┐   ┌─────────┐                           │ │
│  │   │  Node A │◄──│  Node B │◄──│  Node C │   (链表)                 │ │
│  │   └─────────┘   └────┬────┘   └─────────┘                           │ │
│  │                       │                                                │ │
│  │         ◄─── 读者指针 (不改变链表)                                    │ │
│  │                                                                      │ │
│  │   Writer 要删除 Node B:                                              │ │
│  │   1. 原子地改变指针，使 Node B 从链表中脱离                          │ │
│  │      ┌─────────┐         ┌─────────┐                                 │ │
│  │      │  Node A │◄─────────│  Node C │       (新链表)                  │ │
│  │      └─────────┘         └─────────┘                                 │ │
│  │              ▲                                                       │ │
│  │              │                                                        │ │
│  │       ┌─────────┐                                                    │ │
│  │       │  Node B │   (已脱离，但仍可能被旧读者持有)                   │ │
│  │       └─────────┘                                                    │ │
│  │                                                                      │ │
│  │   2. 等待所有旧读者完成 (Grace Period)                               │ │
│  │   3. 释放 Node B                                                     │ │
│  │                                                                      │ │
│  └─────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
│  关键概念: Grace Period                                                    │
│  ───────────────────                                                        │
│                                                                             │
│  - Grace Period = 所有在 RCU 读取开始前存在的读者都完成的时间窗口          │
│  - 在 Grace Period 结束 前，不能释放任何被删除的节点                      │
│  - 确保读者不会访问已释放的内存 (Use-After-Free)                         │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐ │
│  │  Time ──────────────────────────────────────────────────────────►   │ │
│  │                                                                      │ │
│  │  Delete B at t0                                                      │ │
│  │       │                                                              │ │
│  │       ▼                                                              │ │
│  │  ┌────────┐                                                         │ │
│  │  │ Readers can still hold reference to B before t0                │ │
│  │  └────────┘                                                         │ │
│  │       │                                                              │ │
│  │       ├──────────────────────────────────────────┤                   │ │
│  │       │  Grace Period (等待旧读者完成)           │                   │ │
│  │       ├──────────────────────────────────────────┤                   │ │
│  │       │                                                              │ │
│  │       ▼                                                              │ │
│  │  ┌────────┐                                                         │ │
│  │  │ At t1: All pre-t0 readers have exited. Free B!                  │ │
│  │  └────────┘                                                         │ │
│  │                                                                      │ │
│  └─────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 5.2 RCU 实现

```c
// RCU 基本操作

#include <rte_rcu.h>

// RCU 变量
struct rte_rcu_cfg {
    int dummy;  // 占位
} __rte_cache_aligned;

// 替代方案: 使用 DPDK 提供的 rte_rcu_qsbr

// 创建 RCU QSBR (Quiescent-State-Based RCU)
struct rte_rcu_qsbr *
rte_rcu_qsbr_create(unsigned int socket_id, unsigned int num_threads)
{
    struct rte_rcu_qsbr *v;

    v = rte_malloc_socket(NULL, sizeof(*v) +
                           num_threads * sizeof(struct rte_rcu_qsbr_var),
                           RTE_CACHE_LINE_SIZE,
                           socket_id);

    v->max_threads = num_threads;
    v->num_threads = 0;

    return v;
}

// RCU 线程注册
void
rte_rcu_qsbr_thread_register(struct rte_rcu_qsbr *v, unsigned int thread_id)
{
    // 初始化线程的 quiescent state 计数器
    memset(&v->var[thread_id], 0, sizeof(struct rte_rcu_qsbr_var));
    __atomic_fetch_add(&v->num_threads, 1, __ATOMIC_RELAXED);
}

// RCU 读取开始 (每个读者必须调用)
static inline void
rte_rcu_qsbr_lock(struct rte_rcu_qsbr *v, unsigned int thread_id)
{
    // 记录进入临界区
    v->var[thread_id].cnt = __atomic_load_n(&v->token, __ATOMIC_ACQUIRE);
}

// RCU 读取结束 (每个读者必须调用)
static inline void
rte_rcu_qsbr_unlock(struct rte_rcu_qsbr *v, unsigned int thread_id)
{
    // 标记 quiescent state
    __atomic_store_n(&v->var[thread_id].cnt,
                      __atomic_load_n(&v->token, __ATOMIC_ACQUIRE),
                      __ATOMIC_RELEASE);
}

// 同步等待 (写者调用，等待所有读者)
void
rte_rcu_qsbr_synchronize(struct rte_rcu_qsbr *v)
{
    unsigned int i;

    // 1. 增加 token 版本号
    __atomic_fetch_add(&v->token, 1, __ATOMIC_RELEASE);

    // 2. 等待所有线程的计数落后于新 token
    for (i = 0; i < v->max_threads; i++) {
        while (v->var[i].cnt != v->token)
            rte_pause();
    }
}

// RCU 释放 (延迟删除)
void
rte_rcu_qsbr_free(struct rte_rcu_qsbr *v, void *ptr)
{
    // 可以使用 rte_ring 或简单链表存储待释放对象
    // 在 synchronize 后释放
    rte_free(ptr);
}
```

### 5.3 RCU 使用示例

```c
// RCU 保护路由表

struct route_entry {
    uint32_t ip;
    uint32_t mask;
    uint32_t gateway;
    uint16_t ifindex;
    struct rte_rcu_qsbr_entry rcu;  // RCU 同步
} __rte_cache_aligned;

// 全局路由表
struct route_table {
    struct rte_rcu_qsbr *rcu;
    struct rte_ring *routes;        // 存储 route_entry* 的 ring
    rte_rwlock_t lock;               // 配合写操作
};

// 全局变量
struct route_table g_rt;
struct route_entry *g_routes[1024];  // 指针数组

// 初始化
int
route_table_init(void)
{
    g_rt.rcu = rte_rcu_qsbr_create(rte_socket_id(), RTE_MAX_LCORE);
    g_rt.routes = rte_ring_create("route_updates", 1024, rte_socket_id(), 0);

    rte_rwlock_init(&g_rt.lock);

    return 0;
}

// 读取路由 (无锁)
struct route_entry *
route_lookup(uint32_t ip)
{
    // 读取锁 (读者)
    rte_rcu_qsbr_lock(g_rt.rcu, rte_lcore_id());

    struct route_entry *entry = NULL;

    // 遍历路由表
    for (int i = 0; i < 1024; i++) {
        struct route_entry *e = g_routes[i];
        if (e && (ip & e->mask) == (e->ip & e->mask)) {
            if (!entry || e->mask > entry->mask)
                entry = e;
        }
    }

    rte_rcu_qsbr_unlock(g_rt.rcu, rte_lcore_id());

    return entry;
}

// 更新路由 (使用 RCU)
int
route_update(struct route_entry *new_entry)
{
    struct route_entry *old_entry = NULL;
    int index = -1;

    // 1. 找到要更新的槽位
    rte_rwlock_write_lock(&g_rt.lock);

    for (int i = 0; i < 1024; i++) {
        if (g_routes[i] && g_routes[i]->ip == new_entry->ip) {
            old_entry = g_routes[i];
            index = i;
            break;
        }
    }

    if (index == -1) {
        // 新插入
        for (int i = 0; i < 1024; i++) {
            if (g_routes[i] == NULL) {
                index = i;
                break;
            }
        }
    }

    if (index == -1) {
        rte_rwlock_write_unlock(&g_rt.lock);
        return -1;
    }

    // 原子替换指针
    rte_wmb();  // 确保在替换前完成更新
    g_routes[index] = new_entry;

    rte_rwlock_write_unlock(&g_rt.lock);

    // 2. 等待 RCU Grace Period
    if (old_entry)
        rte_rcu_qsbr_synchronize(g_rt.rcu);

    // 3. 释放旧条目
    if (old_entry) {
        // 可以放入待释放队列，稍后释放
        rte_ring_sp_enqueue(g_rt.routes, old_entry);
    }

    return 0;
}

// 后台释放线程
static int
route_free_thread(void *arg)
{
    void *entry;

    while (!quit) {
        if (rte_ring_sc_dequeue(g_rt.routes, &entry) == 0) {
            rte_free(entry);
        }
    }

    return 0;
}
```

### 5.4 DPDK rte_rcu_qsbr API

```c
// DPDK RCU QSBR API

#include <rte_rcu_qsbr.h>

// 创建 RCU variable
struct rte_rcu_qsbr *
rte_rcu_qsbr_create(unsigned int socket_id, unsigned int max_threads);

// 释放 RCU variable
void
rte_rcu_qsbr_free(struct rte_rcu_qsbr *v);

// 注册线程
void
rte_rcu_qsbr_thread_register(struct rte_rcu_qsbr *v, unsigned int thread_id);

// 报告 quiescent state (在读临界区之间调用)
void
rte_rcu_qsbr_quiescent(struct rte_rcu_qsbr *v, unsigned int thread_id);

// 同步等待 (阻塞直到 Grace Period)
void
rte_rcu_qsbr_synchronize(struct rte_rcu_qsbr *v);

// 批量同步
void
rte_rcu_qsbr_synchronize_bulk(struct rte_rcu_qsbr *v, unsigned int n);

// 检查是否所有线程都处于 quiescent state
int
rte_rcu_qsbr_check(struct rte_rcu_qsbr *v, int wait);

// 完整使用示例
struct {
    struct rte_rcu_qsbr *rcu;
    struct route_entry *entries[65536];
    rte_spinlock_t lock;
} routing_table;

int
init_routing_table(void)
{
    // 创建 RCU
    routing_table.rcu = rte_rcu_qsbr_create(rte_socket_id(), RTE_MAX_LCORE);

    rte_spinlock_init(&routing_table.lock);

    // 注册所有 lcore
    unsigned int lcore_id;
    RTE_LCORE_FOREACH(lcore_id) {
        rte_rcu_qsbr_thread_register(routing_table.rcu, lcore_id);
    }

    return 0;
}

// 读取路径
struct route_entry *
lookup_route(uint32_t ip)
{
    struct route_entry *entry = NULL;

    // 读取开始
    rte_rcu_qsbr_lock(routing_table.rcu, rte_lcore_id());

    // 遍历查找 (读取旧指针，但不会被释放)
    for (int i = 0; i < 65536; i++) {
        if (routing_table.entries[i] &&
            (ip & routing_table.entries[i]->mask) == routing_table.entries[i]->ip) {
            entry = routing_table.entries[i];
            break;
        }
    }

    // 读取结束
    rte_rcu_qsbr_unlock(routing_table.rcu, rte_lcore_id());

    return entry;
}

// 更新路径 (延迟删除)
int
update_route(uint32_t ip, uint32_t gateway)
{
    struct route_entry *old = NULL;
    struct route_entry *new;

    // 分配新的 entry
    new = rte_malloc(NULL, sizeof(*new), 0);
    new->ip = ip;
    new->gateway = gateway;

    rte_spinlock_lock(&routing_table.lock);

    // 原子替换
    int index = ip % 65536;
    old = routing_table.entries[index];
    routing_table.entries[index] = new;

    rte_spinlock_unlock(&routing_table.lock);

    // 等待 Grace Period
    if (old) {
        rte_rcu_qsbr_synchronize(routing_table.rcu);
        rte_free(old);  // 现在可以安全释放
    }

    return 0;
}

// 后台线程定期报告 quiescent state
static int
rcu_update_thread(void *arg)
{
    unsigned int lcore_id = rte_lcore_id();

    while (!quit) {
        // 在每个循环迭代之间报告 quiescent state
        rte_rcu_qsbr_quiescent(routing_table.rcu, lcore_id);

        rte_delay_ms(10);
    }

    return 0;
}
```

---

## 6. Lock-Free 数据结构

### 6.1 CAS (Compare-And-Swap)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        CAS 原理                                             │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  CAS 操作:                                                                │
│  ─────────                                                                 │
│                                                                             │
│  bool CAS(ptr, old_val, new_val) {                                        │
│      if (*ptr == old_val) {           // 比较                              │
│          *ptr = new_val;              // 交换                               │
│          return true;                 // 成功                              │
│      }                                                                     │
│      return false;                    // 失败                               │
│  }                                                                          │
│                                                                             │
│  特性:                                                                    │
│  - 原子性: 由硬件保证                                                       │
│  - 乐观锁: 不阻塞，失败 重试                                                │
│  - 存在 ABA 问题: 原子比较无法检测值从 A→B→A 的中间变化                    │
│                                                                             │
│  ─────────────────────────────────────────────────────────────────────────  │
│                                                                             │
│  x86 实现 (lock cmpxchg):                                                 │
│  ─────────────────────────                                                 │
│                                                                             │
│  lock cmpxchg [dest], src   ; if (EAX == dest) { dest = src; ZF = 1; }   │
│                               ; else { EAX = dest; ZF = 0; }              │
│                                                                             │
│  CAS vs 锁:                                                               │
│  ──────────                                                                │
│                                                                             │
│  锁: 悲观策略，假设冲突                             │
│  CAS: 乐观策略，假设少冲突，失败重试                 │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐ │
│  │  Lock:                                                              │ │
│  │      lock();                                                         │ │
│  │      // 临界区                                                       │ │
│  │      unlock();                                                      │ │
│  │                                                                      │ │
│  │  CAS:                                                               │ │
│  │      do {                                                           │ │
│  │          old = *ptr;                                                │ │
│  │          new = old + 1;                                            │ │
│  │      } while (!CAS(ptr, old, new));  // 失败则重试                   │ │
│  │                                                                      │ │
│  └─────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
│  ABA 问题:                                                                │
│  ──────                                                                   │
│                                                                             │
│  问题: 指针从 A -> B -> A 变化，CAS 无法区分                                │
│  解决: 使用双宽度 CAS (DCAS) 或 tag/版本号                                  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 6.2 无锁队列

```c
// Lock-Free SPSC Queue (单生产者单消费者)

struct rte_ring_lf {
    volatile struct node *head;   // 消费者指针
    volatile struct node *tail;   // 生产者指针
} __attribute__((aligned(RTE_CACHE_LINE_SIZE)));

struct node {
    void *data;
    volatile struct node *next;
};

// 无锁入队 (仅生产者调用)
int
rte_ring_lf_enqueue(struct rte_ring_lf *r, void *data)
{
    struct node *node = rte_malloc(NULL, sizeof(*node), 0);
    node->data = data;
    node->next = NULL;

    struct node *prev = __atomic_exchange_n(&r->tail, node, __ATOMIC_ACQ_REL);

    // 将新节点链接到前一个节点
    __atomic_store_n(&prev->next, node, __ATOMIC_RELEASE);

    return 0;
}

// 无锁出队 (仅消费者调用)
void *
rte_ring_lf_dequeue(struct rte_ring_lf *r)
{
    struct node *head = r->head;
    struct node *next = __atomic_load_n(&head->next, __ATOMIC_ACQUIRE);

    if (next == NULL)
        return NULL;  // 队列空

    void *data = next->data;

    // 移动 head
    r->head = next;

    // 释放旧节点 (可以在后续释放)
    rte_free(head);

    return data;
}

// MPMC (多生产者多消费者) 版本更复杂
// 需要使用 CAS 而不是 exchange
```

### 6.3 ABA 问题与解决

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        ABA 问题                                            │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  CAS 只检查"值是否相同"，不检查"是否经历了变化"                          │
│                                                                             │
│  场景: 无锁栈 pop，初始 top → A → B → C                                   │
│                                                                             │
│  Thread 1 要 pop:                                                          │
│  ─────────────────                                                          │
│  ① 读 top = A              ← 记住 old_val = A                            │
│  ② 读 A->next = B          ← 准备把 top 改成 B                            │
│                                                                             │
│  ⚡ 此时被中断，Thread 2 介入                                              │
│                                                                             │
│  Thread 2 做了一堆操作:                                                    │
│  ──────────────────────                                                     │
│  pop A → top = B                                                           │
│  pop B → top = C         ← B 被 free 了!                                  │
│  push A → top → A → C   ← A 又回来了!                                     │
│                                                                             │
│  Thread 1 恢复:                                                            │
│  ──────────────                                                             │
│  ③ CAS(&top, old_val=A, new=B)                                             │
│     top 现在是 A? 是的! → CAS 成功 ✅                                      │
│     把 top 改成 B                                                          │
│                                                                             │
│  ❌ 但 B 已经被 pop 掉并释放了!                                            │
│  → top → B (已释放的内存) → use-after-free                                │
│                                                                             │
│  本质: 值经历了 A→B→A 的变化，但 CAS 只看到"A=A"就认为没变               │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

```c
// 解决方案: tagged pointer — 把指针和版本号打包到一起
// 每次 CAS 时不仅比较指针，还比较版本号
// 版本号每次修改 +1，即使指针回到相同的值，版本号也不同

// 64 位系统，指针低 48 位有效，高 16 位用作版本号
typedef uint64_t tagged_ptr_t;

static inline tagged_ptr_t
make_tagged(void *ptr, uint16_t tag)
{
    return ((uint64_t)tag << 48) | ((uint64_t)ptr & 0x0000FFFFFFFFFFFF);
}

static inline void *
tagged_ptr(tagged_ptr_t tp)
{
    return (void *)(tp & 0x0000FFFFFFFFFFFF);
}

static inline uint16_t
tagged_tag(tagged_ptr_t tp)
{
    return (uint16_t)(tp >> 48);
}

bool
tagged_cas(_Atomic(tagged_ptr_t) *dst, tagged_ptr_t old, tagged_ptr_t new_val)
{
    return __atomic_compare_exchange_n(dst, &old, new_val, 0,
                                       __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE);
}

// 使用 tagged pointer 的 lock-free stack
struct lf_stack {
    _Atomic(tagged_ptr_t) top;
};

void
push(struct lf_stack *s, void *data)
{
    tagged_ptr_t new_top, old_top;
    struct node *new_node;

    old_top = atomic_load(&s->top);
    new_node = create_node(data, tagged_ptr(old_top));
    uint16_t new_tag = tagged_tag(old_top) + 1;
    new_top = make_tagged(new_node, new_tag);

    while (!tagged_cas(&s->top, old_top, new_top)) {
        // CAS 失败，重试
        old_top = atomic_load(&s->top);
        new_node->next = tagged_ptr(old_top);
        new_tag = tagged_tag(old_top) + 1;
        new_top = make_tagged(new_node, new_tag);
    }
}

void *
pop(struct lf_stack *s)
{
    tagged_ptr_t old_top, new_top;

    do {
        old_top = atomic_load(&s->top);
        if (tagged_ptr(old_top) == NULL)
            return NULL;  // 空

        struct node *node = tagged_ptr(old_top);
        uint16_t new_tag = tagged_tag(old_top) + 1;
        new_top = make_tagged(node->next, new_tag);

    } while (!tagged_cas(&s->top, old_top, new_top));

    void *data = node->data;
    free(node);

    return data;
}

// 回到上面的 ABA 场景，使用 tagged pointer 后:
//
// 初始:  top = (A, version=0)
//
// Thread 1:
//   ① 读 top = (A, v=0)       ← 记住 old = (A, v=0)
//   ② 准备 new = (B, v=1)
//
// Thread 2:
//   pop A  → top = (B, v=1)
//   pop B  → top = (C, v=2)
//   push A → top = (A, v=3)   ← A 回来了，但版本号变了!
//
// Thread 1 恢复:
//   ③ CAS(&top, (A, v=0), (B, v=1))
//      top 现在是 (A, v=3)
//      (A, v=0) != (A, v=3)   ← 版本号不同!
//      → CAS 失败 ❌ → 重试 ✅
```

---

## 7. 完整示例

### 7.1 多核统计收集

```c
// 多核友好的统计收集器

struct stats_counter {
    _Atomic uint64_t packets;
    _Atomic uint64_t bytes;
    _Atomic uint64_t errors;
};

// 每个 lcore 的本地计数器 (避免 False Sharing)
struct local_stats {
    uint64_t packets;
    uint64_t bytes;
    uint64_t errors;
};

// 全局聚合
struct global_stats {
    uint64_t packets;
    uint64_t bytes;
    uint64_t errors;
    rte_spinlock_t lock;
};

struct global_stats g_stats;
_Atomic uint64_t g_sync_count = 0;

// TLS: 每个 lcore 的本地统计 (避免 False Sharing)
static __thread struct local_stats local = {0, 0, 0};

// 收集本地统计
void
collect_local_stats(void)
{
    // 增加本地计数 (无锁)
    for (int i = 0; i < 1000; i++) {
        local.packets++;
        local.bytes += 64;
    }

    // 定期刷新到全局
    uint64_t sync = atomic_fetch_add(&g_sync_count, 1, memory_order_relaxed);

    if (sync % 1000 == 0) {
        // 批量刷新
        rte_spinlock_lock(&g_stats.lock);
        g_stats.packets += local.packets;
        g_stats.bytes += local.bytes;
        g_stats.errors += local.errors;
        rte_spinlock_unlock(&g_stats.lock);

        // 重置本地计数
        local.packets = 0;
        local.bytes = 0;
        local.errors = 0;
    }
}
```

### 7.2 读写分离的 Flow Table

```c
// 使用 RCU 的 Flow Table

#define MAX_FLOWS 65536

struct flow_key {
    uint32_t src_ip;
    uint32_t dst_ip;
    uint16_t src_port;
    uint16_t dst_port;
    uint8_t proto;
};

struct flow_entry {
    struct flow_key key;
    uint32_t action;
    uint64_t last_used;
    struct rte_rcu_qsbr_entry rcu;
};

struct flow_table {
    struct rte_rcu_qsbr *rcu;
    struct flow_entry *entries[MAX_FLOWS];
    rte_spinlock_t lock;
    uint32_t count;
};

// RCU 保护的 flow lookup
struct flow_entry *
flow_lookup(struct flow_table *ft, struct flow_key *key)
{
    uint32_t hash = flow_hash(key);
    uint32_t idx = hash % MAX_FLOWS;

    // RCU 读取
    rte_rcu_qsbr_lock(ft->rcu, rte_lcore_id());

    struct flow_entry *entry = ft->entries[idx];

    // 检查匹配
    if (entry && entry->key.src_ip == key->src_ip &&
            entry->key.dst_ip == key->dst_ip &&
            entry->key.src_port == key->src_port &&
            entry->key.dst_port == key->dst_port &&
            entry->key.proto == key->proto) {

        entry->last_used = rte_get_tsc_cycles();
        rte_rcu_qsbr_unlock(ft->rcu, rte_lcore_id());
        return entry;
    }

    rte_rcu_qsbr_unlock(ft->rcu, rte_lcore_id());
    return NULL;
}

// Flow 更新
int
flow_update(struct flow_table *ft, struct flow_key *key, uint32_t action)
{
    uint32_t hash = flow_hash(key);
    uint32_t idx = hash % MAX_FLOWS;
    struct flow_entry *old_entry = NULL;

    rte_spinlock_lock(&ft->lock);

    if (ft->entries[idx]) {
        old_entry = ft->entries[idx];
    }

    struct flow_entry *new_entry = rte_malloc(NULL, sizeof(*new_entry), 0);
    new_entry->key = *key;
    new_entry->action = action;
    new_entry->last_used = rte_get_tsc_cycles();

    // 原子替换
    rte_wmb();
    ft->entries[idx] = new_entry;
    ft->count++;

    rte_spinlock_unlock(&ft->lock);

    // 等待 RCU Grace Period
    if (old_entry) {
        rte_rcu_qsbr_synchronize(ft->rcu);
        rte_free(old_entry);
    }

    return 0;
}
```

---

## 8. 性能与最佳实践

### 8.1 同步原语性能对比

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        同步原语性能对比                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  延迟 (获取锁/执行同步操作):                                               │
│  ─────────────────────────────────────────                                  │
│                                                                             │
│  操作                              x86     ARM64                            │
│  ──────────────────────────────────────────────────────────────────────── │
│  atomic add (无冲突)              5 ns     10 ns                           │
│  CAS (无冲突)                    10 ns     20 ns                           │
│  CAS (竞争)                      50 ns    100 ns                           │
│  Spinlock (无冲突)               15 ns     30 ns                           │
│  Spinlock (竞争, 2线程)         500 ns    800 ns                           │
│  Spinlock (竞争, 8线程)        5000 ns   8000 ns                           │
│  MCS Lock (竞争)                 80 ns    150 ns                           │
│  RWLock 读 (无冲突)              5 ns     10 ns                            │
│  RWLock 写 (无冲突)              15 ns     30 ns                            │
│  RCU quiescent state            <1 ns     <2 ns                           │
│  Memory barrier (mfence)        30 ns     50 ns                           │
│                                                                             │
│  ─────────────────────────────────────────────────────────────────────────  │
│                                                                             │
│  选择指南:                                                                 │
│  ────────                                                                  │
│                                                                             │
│  简单计数器:           atomic_fetch_add                                     │
│  热点数据 (短临界区):  spinlock (避免 Long hold time)                      │
│  长临界区:            mutex (os sleep)                                     │
│  读多写少:            rte_rwlock 或 RCU                                    │
│  复杂数据结构:        rte_rwlock 或 RCU                                    │
│  高并发队列:          rte_ring (lock-free)                                 │
│  无锁算法:            CAS + memory barrier                                 │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┫
```

### 8.2 常见错误

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        同步常见错误                                         │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  错误 1: 遗漏内存屏障                                                       │
│  ─────────────────────                                                      │
│  x = 1;           // 写                                                     │
│  flag = 1;       // 写                                                     │
│  // 缺少 wmb()                                                   │
│                                                                             │
│  // 另一线程:                                                             │
│  if (flag == 1)  // 读 flag                                               │
│      use(x);     // 读 x (可能 x=0!)                                      │
│                                                                             │
│  ─────────────────────────────────────────────────────────────────────────  │
│                                                                             │
│  错误 2: 错误的屏障 类型                                                    │
│  ────────────────────────                                                  │
│                                                                             │
│  x = 1;                                                                     │
│  // 使用 rmb() 而不是 wmb()                                               │
│  rmb();          // rmb() 只保证 load，不保证之前 store 完成              │
│  flag = 1;                                                                   │
│                                                                             │
│  ─────────────────────────────────────────────────────────────────────────  │
│                                                                             │
│  错误 3: 在锁外面访问受保护的数据                                           │
│  ────────────────────────────────                                          │
│                                                                             │
│  spinlock_lock(&lock);                                                    │
│  // 操作 A                                                                │
│  spinlock_unlock(&lock);                                                 │
│  // 操作 B (可能用到被操作 A 改变的数据，引入竞争)                         │
│                                                                             │
│  ─────────────────────────────────────────────────────────────────────────  │
│                                                                             │
│  错误 4: 自定义原子操作 缺少屏障                                            │
│  ────────────────────────────────                                           │
│                                                                             │
│  // 看似原子的操作                                                        │
│  int fetch_add(int *ptr) {                                                 │
│      int old = *ptr;     // 非原子读!                                       │
│      *ptr = old + 1;     // 非原子写!                                       │
│      return old;                                                             │
│  }                                                                          │
│                                                                             │
│  应该使用 __atomic_fetch_add()                                            │
│                                                                             │
│  ─────────────────────────────────────────────────────────────────────────  │
│                                                                             │
│  错误 5: ABA 问题导致 数据结构损坏                                          │
│  ────────────────────────────────                                          │
│                                                                             │
│  // stack pop 可能返回已释放的节点                                        │
│  // 解决: 使用 tagged pointer 或版本号                                     │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 9. 小结

本章核心要点：

1. **Memory Reorder**：编译器优化和 CPU 流水线可能重排指令，导致可见性问题和竞争条件。

2. **x86 TSO 模型**：Store Buffer 导致弱于 SC 的语义，Load 可以绕过之前的 Store。

3. **ARM/POWER 弱内存模型**：允许更多重排，需要显式内存屏障。

4. **Memory Barrier 类型**：`rte_mb()` (完整)、`rte_rmb()` (读)、`rte_wmb()` (写)。

5. **C11 内存顺序**：`seq_cst` (最强) > `acq_rel` > `acquire`/`release` > `relaxed` (最弱)。

6. **DPDK 原子操作**：`__atomic_*` intrinsics，支持各种内存顺序。

7. **Spinlock**：忙等待锁，`mfence` + `xchg` 实现，避免在临界区长时间持有。

8. **MCS Lock**：队列自旋锁，每个 CPU 修改自己的节点，消除 Cache Line 竞争。

9. **读写锁**：`rte_rwlock_t`，读者增加计数，写者获取独占访问。

10. **RCU 原理**：读多写少场景的无锁读取，延迟删除直到 Grace Period。

11. **RCU 实现**：rte_rcu_qsbr，quiescent state 报告，`synchronize()` 等待 Grace Period。

12. **CAS (Compare-And-Swap)**：乐观锁，适合低冲突场景，需要处理 ABA 问题。

13. **ABA 问题解决**：tagged pointer 或版本号。

14. **Lock-Free 数据结构**：SPSC Queue 等使用 atomic exchange，MPMC 需要 CAS。

15. **同步原语选择**：简单计数用原子操作，短临界区用 spinlock，读多写少用 RCU 或读写锁。

**下一篇预告**：[[ch29-profiling|第二十九章]]将讲解 Profiling——dpdk-procinfo、perf、火焰图。

---

> [!tip] 参考文献
>
> - Intel, "Intel 64 and IA-32 Architectures Software Developer's Manual, Vol. 3A"
> - ARM, "ARM Architecture Reference Manual, ARMv8"
> - "Memory Barriers: a Hardware View", Paul McKenney
> - "Is Parallel Programming Hard?" Paul McKenney
> - "The Art of Multiprocessor Programming", Herlihy & Shavit
> - Intel, "DPDK Synchronization Primitives", https://doc.dpdk.org/guides/prog_guide/env_abstraction_layer.html
> - "RCU in the Linux Kernel", https://www.kernel.org/doc/html/latest/RCU/
> - [[2026-05-27-rcu-deep-dive-linux-vs-dpdk|RCU 原理深度解析：Linux 内核与 DPDK 实现对比]]
> - [[2026-05-27-linux-kernel-context-scheduling-preemption|Linux 内核上下文、调度与抢占：完整图解]]
