---
title: "VPP 深入探讨 ch05：Thread 模型与 Worker"
date: 2026-04-09 20:30:00
tags: [vpp, thread, worker, barrier, rcu, lockless, affinity, scheduling]
description: "深入解析 VPP Thread 模型：Main vs Workers、barrier 同步、RCU 锁less 设计、CPU affinity 与调度策略"
---

# VPP 深入探讨 ch05：Thread 模型与 Worker

> [!abstract] 核心要点
> VPP 的多线程模型是其高性能的关键。本章深入解析 Main 线程与 Worker 线程的角色、barrier 同步机制、RCU 锁less 设计、CPU affinity 配置与调度策略。

## 1. VPP Thread 模型概述

### 1.1 线程角色

```
┌─────────────────────────────────────────────────────────────┐
│                    VPP Thread 模型                         │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              Main Thread                               │  │
│  │  - VPP 初始化                                          │  │
│  │  - Plugin 加载                                         │  │
│  │  - 图配置/重配置                                       │  │
│  │  - 管理平面 (CLI/API)                                  │  │
│  │  - Worker 线程同步                                     │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              Worker Threads (n 个)                   │  │
│  │                                                       │  │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  │  │
│  │  │  Worker 0   │  │  Worker 1   │  │  Worker n   │  │  │
│  │  │  (lcore 1)  │  │  (lcore 2)  │  │  (lcore n) │  │  │
│  │  │              │  │              │  │             │  │  │
│  │  │  图遍历      │  │  图遍历      │  │  图遍历     │  │  │
│  │  │  packet     │  │  packet     │  │  packet     │  │  │
│  │  └─────────────┘  └─────────────┘  └─────────────┘  │  │
│  │                                                       │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              Interrupt Thread (可选)                  │  │
│  │  - 硬件中断处理                                        │  │
│  │  - 事件通知                                            │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 Main vs Worker 职责

| 职责            | Main Thread | Worker Threads |
| --------------- | ----------- | -------------- |
| **初始化**      | ✅ 完成     | ❌             |
| **Plugin 加载** | ✅ 完成     | ❌             |
| **图配置**      | ✅ 执行     | ❌             |
| **包处理**      | ❌          | ✅ 独占        |
| **CLI/API**     | ✅ 管理     | ❌             |
| **Worker 同步** | ✅ barrier  | ❌             |

## 2. Thread 初始化

### 2.1 启动配置

```bash
# /etc/vpp/startup.conf
cpu {
    # Main 线程运行的 CPU core
    main-core 0

    # Worker 线程运行的 CPU cores (逗号分隔或范围)
    corelist-workers 1-3

    # 或者指定特定 core
    # corelist-workers 1,3,5,7
}
```

### 2.2 初始化流程

```c
// src/vpp/main.c (伪代码)
int vpp_main(int argc, char **argv)
{
    // 1. 解析参数
    vlib_parse_args(argc, argv);

    // 2. 初始化 main thread
    vlib_main_t *vm = &vlib_global_main;
    vlib_main_init(vm);

    // 3. 注册 plugins
    vlib_plugin_main_init();

    // 4. 创建 worker threads
    if (num_workers > 0) {
        vlib_worker_threads_create(vm, num_workers);
    }

    // 5. 进入 main loop
    while (1) {
        // main thread 做轻量工作
        vlib_main_loop(vm);
    }
}

// Worker thread 入口
static void *
vpp_worker_thread(void *arg)
{
    vlib_worker_thread_t *w = arg;
    vlib_main_t *vm = w->vm;

    // 设置 CPU affinity
    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);
    CPU_SET(w->cpu_core, &cpuset);
    pthread_setaffinity_np(pthread_self(), sizeof(cpuset), &cpuset);

    // 等待 barrier
    vlib_worker_thread_barrier_sync(vm);

    // 进入 worker loop
    while (w->enabled) {
        vlib_worker_thread_loop(vm, w);
    }

    return NULL;
}
```

### 2.3 Worker 线程数据结构

```c
// vlib_worker_thread_t
typedef struct vlib_worker_thread_t {
    // 线程信息
    pthread_t thread;
    u32 thread_index;

    // 关联的 vlib_main_t
    vlib_main_t *vm;

    // CPU affinity
    u32 cpu_core;

    // 状态
    volatile u8 enabled;
    volatile u8 waiting;

    // Barrier 同步
    volatile u32 barrier_sync_count;

    // Per-thread 数据
    vlib_buffer_main_t *buffer_main;
    vlib_node_main_t *node_main;
} vlib_worker_thread_t;

// 全局 worker threads 数组
vlib_worker_thread_t *vlib_worker_threads;
u32 num_workers;
```

## 3. Barrier 同步机制

### 3.1 为什么需要 Barrier

```
Barrier 的作用：同步 Main 和 Workers

场景：Main 需要修改图配置（如 set interface input node）

问题：
  Worker 0: 正在执行 ip4-input node
  Worker 1: 正在执行 ip4-lookup node
  Main:     修改 ip4-input 的 next_nodes

如果 Main 在 Workers 执行中途修改：
  → 数据竞争 (data race)
  → 包可能跑到错误的地方

解决方案：Barrier
  1. Main 说："我要修改图，所有 worker 停"
  2. Workers 完成当前 frame，进入等待
  3. Main 修改图
  4. Main 说："好了，继续"
  5. Workers 恢复执行
```

### 3.2 Barrier 实现

```c
// Barrier 同步变量
struct vlib_worker_thread_main_t {
    // Barrier 锁
    volatile u32 barrier_count;
    volatile u32 barrier_epoch;

    // Main 和 workers 共享的同步计数器
    volatile u32 main_loop_count;
    volatile u32 worker_handshake_count;
};

// Main 调用 barrier
void
vlib_worker_thread_barrier_sync(vlib_main_t *vm)
{
    vlib_worker_thread_main_t *wmt = &vm->worker_main;

    // 原子递增 barrier epoch
    __sync_fetch_and_add(&wmt->barrier_epoch, 1);

    // 等待所有 worker 到达 barrier
    while (wmt->barrier_count < num_workers) {
        // busy wait (应该很快)
        cpu_pause();
    }

    // 所有 workers 都到达了
    // Main 可以安全修改共享状态
}

// Worker 到达 barrier
void
vlib_worker_thread_barrier_hold(vlib_worker_thread_t *w)
{
    vlib_worker_thread_main_t *wmt = &w->vm->worker_main;

    // 增加到达计数
    u32 epoch = wmt->barrier_epoch;
    __sync_fetch_and_add(&wmt->barrier_count, 1);

    // 等待 Main 释放 barrier
    while (wmt->barrier_epoch == epoch) {
        // barrier 还没释放
        cpu_pause();
    }

    // Barrier 释放了，继续执行
}
```

### 3.3 Barrier 时序图

```
┌─────────────┬───────────────────────────────────────────────────────┐
│    Main     │                     Timeline                          │
├─────────────┼───────────────────────────────────────────────────────┤
│             │                                                       │
│ Barrier     │──┐                                                    │
│ Sync ───────┘  │ epoch++                                            │
│               │                                                     │
│ 等待中...     │ ◀── barrier_count < num_workers?                    │
│               │                                                     │
│               │                      ┌─────────────────────────────┤
│               │                      │ Worker 0: barrier_count++    │
│               │                      │ Worker 1: barrier_count++    │
│               │                      │ Worker 2: barrier_count++    │
│               │                      │ (all waiting in barrier)   │
│               │                      └─────────────────────────────┘
│               │                                                     │
│ 继续执行      │ ◀── barrier_count == num_workers                    │
│ (修改图)      │                                                     │
│               │                                                     │
│ Barrier       │──┐ epoch++                                         │
│ Release ──────┘  │                                                     │
│               │                                                     │
│               │                      ┌─────────────────────────────┤
│               │                      │ Workers: while (epoch==old) │
│               │                      │ (wait for new epoch)        │
│               │                      │ (continue processing)       │
│               │                      └─────────────────────────────┘
└───────────────┴───────────────────────────────────────────────────────┘
```

## 4. RCU (Read-Copy-Update) 锁less 设计

### 4.1 RCU 原理

```
RCU 的核心思想：读者无锁，写者延迟删除

传统锁：
  Reader: lock() → read() → unlock()
  Writer: lock() → modify() → unlock()
  问题：读者也需要等待

RCU：
  Reader: read() (no lock!)
  Writer: modify() → 延迟删除旧数据

写入流程：
  1. 复制数据结构
  2. 修改副本
  3. 原子替换指针
  4. 等待所有旧读者完成（宽限期）
  5. 释放旧数据
```

### 4.2 VPP 中的 RCU 使用

```c
// VPP 使用 RCU 保护 FIB (Forwarding Information Base)

// FIB 条目
struct fib_entry {
    u32 fib_index;
    ip46_address_t prefix;
    u32 prefix_len;

    // 路由信息
    u32 next_hop;
    u32 weight;

    // RCU 头
    struct rcu_head rcu;
};

// RCU 保护的指针
struct fib_table {
    // RCU 保护的路由表
    struct fib_entry **fib_entries;

    // 原子指针
    _Atomic(struct fib_entry **) entries_acl;

    u32 num_entries;
};

// 读者：无锁读取
static inline fib_entry_t *
fib_entry_lookup(struct fib_table *ft, ip46_address_t *addr)
{
    // RCU 读不需要锁
    rcu_read_lock();

    struct fib_entry **entries = rcu_dereference(ft->entries_acl);

    // 在 entries 中查找
    fib_entry_t *entry = binary_search(entries, ft->num_entries, addr);

    rcu_read_unlock();

    return entry;
}

// 写者：修改并延迟删除
static void
fib_entry_update(struct fib_table *ft,
                 ip46_address_t *addr,
                 u32 next_hop)
{
    // 1. 分配新条目
    fib_entry_t *new_entry = clib_alloc(sizeof(*new_entry));
    new_entry->next_hop = next_hop;

    // 2. 原子替换
    rcu_assign_pointer(ft->entries_acl, new_entry);

    // 3. 等待宽限期（所有旧读者完成）
    synchronize_rcu();

    // 4. 释放旧条目
    if (old_entry) {
        clib_free(old_entry);
    }
}
```

### 4.3 VPP 中的其他无锁结构

```c
// VPP 还使用其他无锁技术：

// 1. 原子操作
static inline u32
vlib_get_pending_node_count(vlib_main_t *vm)
{
    return __atomic_load_n(&vm->node_main.pending_node_count,
                          __ATOMIC_ACQUIRE);
}

// 2. Lock-free queue (SPSC)
struct vlib_frame_queue {
    u32 *bufs;
    volatile u32 head;
    volatile u32 tail;
    u32 size;
};

// 单生产者单消费者队列
static inline u32
vlib_frame_queue_push(struct vlib_frame_queue *q, u32 *bufs, u32 n)
{
    u32 head = q->head;

    // 等待空间
    while ((head - q->tail) >= q->size)
        cpu_pause();

    // 写入数据
    for (u32 i = 0; i < n; i++) {
        q->bufs[(head + i) & (q->size - 1)] = bufs[i];
    }

    // 内存屏障
    __atomic_thread_fence(__ATOMIC_RELEASE);

    // 更新 head
    q->head = head + n;

    return n;
}
```

## 5. CPU Affinity 配置

### 5.1 NUMA 感知布局

```
NUMA 系统中的 VPP 线程布局：

┌─────────────────────────────────────────────────────────────┐
│                   NUMA Node 0                              │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ CPU 0: VPP Main Thread                             │   │
│  │ CPU 1: VPP Worker 0                                │   │
│  │ CPU 2: VPP Worker 1                                │   │
│  │ CPU 3: VPP Worker 2                                │   │
│  │                                                     │   │
│  │ Memory: 16GB DDR4                                  │   │
│  │ NIC:   eth0 (PCIe 3.0 x4)                         │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                   NUMA Node 1                              │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ CPU 4: VPP Worker 3                                │   │
│  │ CPU 5: VPP Worker 4                                │   │
│  │                                                     │   │
│  │ Memory: 16GB DDR4                                  │   │
│  │ NIC:   eth1 (PCIe 3.0 x4)                         │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘

最佳实践：
- Main thread 在 Node 0 (优先)
- Workers 绑定到本地 NUMA 的 CPUs
- Buffer pool 使用本地 NUMA memory
- NIC 驱动使用本地 CPUs 轮询
```

### 5.2 Affinity 配置命令

```bash
# 在 startup.conf 中配置
cpu {
    main-core 0
    corelist-workers 1-3,5
}

# 或者使用 CLI 动态调整
vpp# set threading mode primary 4
vpp# set thread [worker 0] cpu 1
vpp# set thread [worker 1] cpu 2

# 查看当前配置
vpp# show thread
Thread 0 (main): state=running, cpu=[0]
Thread 1 (worker 0): state=running, node=interface-tx, cpu=[1]
Thread 2 (worker 1): state=running, node=interface-tx, cpu=[2]
```

### 5.3 驱动与 CPU 绑定

```bash
# DPDK 驱动的 CPU 亲和
# /etc/vpp/startup.conf
dpdk {
    # 绑定到特定 lcore（可选）
    # 这个选项让 DPDK PMD 使用特定 CPU
    # lcores 0-3
}
```

## 6. Worker Loop 详解

### 6.1 Worker Loop 伪代码

```c
// Worker 线程的主循环
static void *
vlib_worker_thread_loop(void *arg)
{
    vlib_worker_thread_t *w = arg;
    vlib_main_t *vm = w->vm;

    // 等待 main thread 初始化完成
    vlib_worker_thread_barrier_sync(vm);

    while (w->enabled) {
        // 1. 处理 pending frames
        //    (其他 worker 调度过来的包)
        process_pending_frames(vm, w);

        // 2. 处理本地 RX 队列
        //    (本 worker 专属 RX 队列的包)
        process_rx_queue(vm, w);

        // 3. 如果没有工作，可以休眠
        if (no_work) {
            vlib_worker_thread_wait(vm);
        }
    }

    return NULL;
}
```

### 6.2 跨 Worker 帧传递

```c
// Worker A 将帧传递给 Worker B

// Worker A 端：发送到远程 worker 的队列
static inline void
vlib_put_next_frame_remote(vlib_main_t *vm,
                           vlib_node_runtime_t *node,
                           u32 next_index,
                           u32 *buffers,
                           u32 n_buffers,
                           u32 target_worker)
{
    // 获取目标 worker 的 frame queue
    vlib_frame_queue_t *fq =
        vlib_get_frame_queue(target_worker);

    // 加入队列
    vlib_frame_queue_push(fq, buffers, n_buffers);
}

// Worker B 端：从队列接收
static inline u32
vlib_get_next_frame_remote(vlib_main_t *vm,
                           vlib_worker_thread_t *w,
                           u32 node_index,
                           u32 **buffers)
{
    vlib_frame_queue_t *fq =
        vlib_get_frame_queue(w->thread_index);

    // 从队列取出
    u32 n = vlib_frame_queue_pop(fq, buffers);

    return n;
}
```

### 6.3 Work Stealing

```
Work Stealing：当一个 worker 没有工作时，从其他 worker 偷任务

┌─────────────────────────────────────────────────────────────┐
│                  Work Stealing 示例                          │
│                                                              │
│  Worker 0: [包1][包2][包3][  空  ] → 偷取 Worker 2 的包     │
│  Worker 1: [包4][包5][  空  ][  空  ]                      │
│  Worker 2: [包6][  空  ][  空  ][  空  ] → 被偷走 2 个包   │
│                                                              │
│  结果：                                                      │
│  Worker 0: [包1][包2][包3][包6]  ← 偷来的                    │
│  Worker 1: [包4][包5]                                       │
│  Worker 2: [包6]           ← 剩下的                          │
└─────────────────────────────────────────────────────────────┘

VPP 的 Work Stealing 实现：
- 当本地 RX 队列为空时触发
- 从高负载的 worker 偷取 half 的包
- 减少负载不均衡
```

## 7. 性能调优

### 7.1 Worker 数量选择

```bash
# 经验法则：
# - 2-4 workers 通常足够
# - 取决于 NIC 队列数量
# - 考虑 NUMA 拓扑

# 查看可用 CPU
lscpu

# 查看 NIC 队列
ethtool -l eth0

# 示例：4 核 CPU，2 NIC 端口各 4 队列
# 配置：
#   main-core 0
#   corelist-workers 1-3
```

### 7.2 超线程 (Hyper-Threading)

```bash
# 超线程的影响：
# - 同一物理核心的两个逻辑核心共享执行单元
# - 对网络 IO 密集型可能有益
# - 对 CPU 密集型可能反而降低性能

# 启用超线程
# 假设物理核心 0,1,2,3，超线程后逻辑核心 0-7
cpu {
    main-core 0
    corelist-workers 1-7  # 包括超线程核心
}

# 禁用超线程（推荐用于计算密集型）
cpu {
    main-core 0
    corelist-workers 1,3,5,7  # 只用奇数核心
}
```

### 7.3 中断亲和

```bash
# 将 NIC 中断绑定到特定 CPU
# 减少跨 CPU 中断处理开销

# 查看当前中断亲和
cat /proc/interrupts | grep eth0

# 设置中断亲和 (需要 root)
# echo 2 > /proc/irq/XXX/smp_affinity
# (2 = binary 0010 = CPU 1)

# VPP 自动处理 DPDK 中断亲和
# 但可以手动配置
dpdk {
    dev 0000:3d:00.0 {
        interrupt  # 启用中断模式
    }
}
```

## 8. 常见问题

### 8.1 Worker 不工作

```bash
# 检查 worker 状态
vpp# show thread

# 应该看到：
# Thread 1 (worker 0): state=running
# Thread 2 (worker 1): state=running

# 如果是 waiting，检查：
# 1. NIC 是否正确配置
# 2. RX 队列是否存在
# 3. 图是否正确连接
```

### 8.2 负载不均衡

```bash
# 检查每个 worker 的负载
vpp# show node

# 示例输出：
# Name                Count     Vectors   Suspends
# interface-input      10000     50000     0
# ip4-input           9000      45000     0
# ip4-lookup          9000      45000     0
# ...

# 如果某个 worker 明显少，检查：
# 1. RSS 配置
# 2. Flow 分布
# 3. Work stealing 是否启用
```

## 9. 总结

VPP Thread 模型核心设计：

| 组件               | 设计           | 优势               |
| ------------------ | -------------- | ------------------ |
| **Main Thread**    | 管理平面       | 配置变更、API 处理 |
| **Worker Threads** | 数据平面       | 线性扩展、多核并行 |
| **Barrier Sync**   | Main ↔ Workers | 安全的配置变更     |
| **RCU**            | 锁less 读取    | 高效并发           |
| **Work Stealing**  | 动态负载均衡   | 减少空闲           |
| **CPU Affinity**   | NUMA 感知      | 最小化延迟         |

```
Thread 协作流程：

Main Thread:
  启动 Workers ──→ Barrier Sync ──→ 配置管理
                    ▲                   │
                    │                   │
 Worker Threads:    │                   │
  图遍历 ◀──────────┘                   │
  包处理 ◀──────────────────────────────┘
```

---

## 参考资源

- [VPP Worker Threads](https://wiki.fd.io/view/VPP/VPP_and_Multi-Worker_Support)
- [RCU 论文](https://www.rdrop.com/users/paulmck/RCU/)
- [Linux Kernel RCU](https://www.kernel.org/doc/Documentation/RCU/)
