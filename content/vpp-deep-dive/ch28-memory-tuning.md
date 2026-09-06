---
title: "VPP 深入探讨 ch28：Buffer 与 Memory 调优"
date: 2026-04-16 10:38:00
tags: [vpp, buffer, memory, mempool, cache, heap, hugepage, numa, tuning]
description: "深入解析 VPP Buffer 与 Memory 调优：heap 配置、cache 优化、hugepage 部署、NUMA 亲和性与性能调优"
---

# VPP 深入探讨 ch28：Buffer 与 Memory 调优

> [!abstract] 核心要点
> Buffer 与 Memory 是 VPP 高性能的基础。本章深入解析内存池配置、hugepage 使用、cache 优化、NUMA 亲和性与性能调优实战。

## 1. Memory 架构概述

### 1.1 VPP Memory 模型

```
┌─────────────────────────────────────────────────────────────┐
│                    VPP Memory 架构                           │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │                    System Memory                      │  │
│  │  ┌─────────────────────────────────────────────────┐  │  │
│  │  │              Hugepages (2MB/1GB)                 │  │  │
│  │  │                                                  │  │  │
│  │  │  ┌───────────┐  ┌───────────┐  ┌───────────┐  │  │  │
│  │  │  │   Buffer  │  │   Buffer  │  │   Buffer  │  │  │  │
│  │  │  │   Pool    │  │   Pool    │  │   Pool    │  │  │  │
│  │  │  └───────────┘  └───────────┘  └───────────┘  │  │  │
│  │  │                                                  │  │  │
│  │  │  ┌───────────┐  ┌───────────┐  ┌───────────┐  │  │  │
│  │  │  │   Heap    │  │   Heap    │  │   Heap    │  │  │  │
│  │  │  │   (mbuf)  │  │   (meta)  │  │   (data)  │  │  │  │
│  │  │  └───────────┘  └───────────┘  └───────────┘  │  │  │
│  │  └─────────────────────────────────────────────────┘  │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 Memory 类型

| 类型              | 用途       | 分配方式  | 特点               |
| ----------------- | ---------- | --------- | ------------------ |
| **Buffer Pool**   | 包数据存储 | DPDK mbuf | 固定大小，高性能   |
| **Heap**          | 动态分配   | glib      | 可变大小，碎片管理 |
| **Stats Segment** | 统计数据   | 共享内存  | 进程间共享         |
| **API Segment**   | API 消息   | 共享内存  | 进程间通信         |

### 1.3 Hugepage 优势

```
┌─────────────────────────────────────────────────────────────┐
│                 4KB Page vs Hugepage                        │
│                                                              │
│   4KB Page (标准)          2MB Hugepage                     │
│   ────────────            ─────────────                     │
│   └─── Page ────          ┌─────────────────┐              │
│       └─── Page ────      │   Hugepage      │              │
│           └─── Page ──── │                 │              │
│               └─── Page   │   2MB contiguous│              │
│                              │                 │              │
│   映射次数: N               └─────────────────┘              │
│   TLB Miss: 高              映射次数: 1                       │
│   内存访问: 间接            TLB Miss: 低                     │
│                              内存访问: 直接                   │
└─────────────────────────────────────────────────────────────┘
```

## 2. Buffer 配置

### 2.1 Buffer Pool 大小

```bash
# startup.conf 中的 buffer 配置
dpdk {
    socket-mem 1024,1024           # 每个 NUMA 节点分配 1GB
    no-huge                       # 使用 mmap 而非 hugepage（仅用于测试）
}

# 调整 buffer 数量（计算公式）
# num_buffers = (socket_mem / buffer_size) * 预留给流失效的倍数
# 例如：1024MB / 2048B = 524288，保留 2 倍 = 1048576

# 查看当前 buffer 统计
vppctl show buffers

# 示例输出：
# Buffer pools:
#   Pool 0 (numa 0):
#     Total:    262144
#     Used:     65536
#     Free:     196608
#     Size:     2048 bytes
```

### 2.2 Buffer 大小配置

```bash
# 在编译时配置默认 buffer 大小
# config.mk 文件
VPP default buffer size = 2048

# 在运行时调整（需要重启）
# startup.conf
buffers {
    default data size 2048
    numberof buffers 262144
}
```

### 2.3 Buffer 配置计算

```c
// 计算 optimal buffer 数量
// 考虑因素：
// 1. 接口 RX 队列深度
// 2. 每个 worker 的突发能力
// 3. 流表大小
// 4. 丢包容忍度

// 示例计算
#define RX_QUEUE_SIZE 256
#define NUM_WORKERS 4
#define BURST_SIZE 64
#define RESERVE_FACTOR 2

// 每个 worker 需要的 buffer 数
buffers_per_worker = RX_QUEUE_SIZE * RESERVE_FACTOR + BURST_SIZE;

// 总 buffer 数
total_buffers = buffers_per_worker * NUM_WORKERS;

// 考虑接口数量
total_buffers *= num_interfaces;

// 考虑包大小变化（MTU）
// 标准 MTU 1500 + headers = ~2KB
// Jumbo frame 9000 + headers = ~9KB

#define DEFAULT_BUFFER_SIZE 2048
#define JUMBO_BUFFER_SIZE 9216

// 使用大 MTU 时需要更多 buffer
if (mtu > 1500) {
    total_buffers *= (JUMBO_BUFFER_SIZE / DEFAULT_BUFFER_SIZE);
}
```

### 2.4 Buffer 分配策略

```c
// vlib_buffer.h 中的 buffer 配置

// Buffer 默认参数
#define VLIB_BUFFER_DEFAULT_SIZE 2048
#define VLIB_BUFFER_DATA_SIZE (VLIB_BUFFER_DEFAULT_SIZE - sizeof(vlib_buffer_t))

// 多线程 buffer 分配
always_inline void *
vlib_buffer_alloc (vlib_main_t *vm, u32 n_buffers)
{
    return clib_buffer_pool_get(vm->buffer_pool, n_buffers);
}

// 批量分配 buffer
always_inline u32 *
vlib_buffer_alloc_multi (vlib_main_t *vm, u32 n_buffers)
{
    u32 *indices = clib_buffer_pool_get_multi(vm->buffer_pool, n_buffers);
    return indices;
}

// Buffer 释放
always_inline void
vlib_buffer_free (vlib_main_t *vm, u32 *buffers, u32 n_buffers)
{
    clib_buffer_pool_put_multi(vm->buffer_pool, buffers, n_buffers);
}
```

## 3. Memory Pool 调优

### 3.1 Mempool 配置

```bash
# startup.conf 中的 mempool 配置
dpdk {
    log_level debug

    # Mempool cache size
    mbuf_pool_size 262144
    mbuf_cache_size 256

    # 启用内存池跟踪
    trace heap
}
```

### 3.2 Mempool 选择

```c
// 根据包大小选择合适的 mempool

// 小包 (< 128B) - 频繁分配/释放
static mbuf_pool_t *
get_small_packet_pool (vlib_main_t *vm, u32 socket)
{
    return vlib_mempool_small_packets[socket];
}

// 中包 (128B - 2KB)
static mbuf_pool_t *
get_medium_packet_pool (vlib_main_t *vm, u32 socket)
{
    return vlib_mempool_medium_packets[socket];
}

// 大包 (> 2KB)
static mbuf_pool_t *
get_large_packet_pool (vlib_main_t *vm, u32 socket)
{
    return vlib_mempool_large_packets[socket];
}
```

### 3.3 NUMA-aware Mempool

```c
// NUMA 感知的内存池分配

// 创建 NUMA 本地内存池
static mbuf_pool_t *
create_numa_pool (u32 socket_id, u32 pool_size, u32 buffer_size)
{
    mbuf_pool_create_args_t args = {
        .socket_id = socket_id,
        .pool_size = pool_size,
        .buffer_size = buffer_size,
        .flags = MP_MAP_HUGE_PAGE | MP_CACHE_SZ,
    };

    return mbuf_pool_create(&args);
}

// 获取本地内存池
static mbuf_pool_t *
get_local_pool (vlib_main_t *vm)
{
    u32 current_socket = vlib_get_current_socket();
    return vm->mempools_by_socket[current_socket];
}

// 在多socket系统中配置
void
configure_multi_socket_pools (vlib_main_t *vm)
{
    u32 num_sockets = sysconf(_SC_NPROCESSORS_ONLN);

    for (u32 s = 0; s < num_sockets; s++) {
        // 每个 socket 创建独立内存池
        vm->mempools_by_socket[s] = create_numa_pool(
            s,
            262144,  // pool size
            2048     // buffer size
        );
    }
}
```

### 3.4 内存池性能优化

```c
// 内存池 cache 优化

// 使用 per-thread cache 减少锁竞争
typedef struct {
    u32    *cached_buffers;
    u32     cache_len;
    u32     cache_max;
} thread_local_buffer_cache_t;

// Per-thread cache 操作
always_inline u32
buffer_cache_alloc (thread_local_buffer_cache_t *cache)
{
    if (cache->cache_len == 0) {
        // 从全局池补充
        refill_cache(cache, 256);
    }

    return cache->cached_buffers[--cache->cache_len];
}

always_inline void
buffer_cache_free (thread_local_buffer_cache_t *cache, u32 buffer_index)
{
    if (cache->cache_len == cache->cache_max) {
        // 释放到全局池
        flush_cache(cache);
    }

    cache->cached_buffers[cache->cache_len++] = buffer_index;
}

// 批量操作优化
always_inline u32 *
buffer_cache_alloc_multi (thread_local_buffer_cache_t *cache, u32 n)
{
    while (cache->cache_len < n) {
        refill_cache(cache, 256);
    }

    u32 *indices = &cache->cached_buffers[cache->cache_len - n];
    cache->cache_len -= n;
    return indices;
}
```

## 4. Hugepage 配置

### 4.1 Hugepage 部署

```bash
# 检查当前 hugepage 使用
cat /proc/meminfo | grep -i huge

# 示例输出：
# HugePages_Total:     1024
# HugePages_Free:        512
# Hugepages_Free:        512
# HugePageSize:       2048 kB

# 配置 2MB hugepage
echo 1024 > /proc/sys/vm/nr_hugepages

# 配置 1GB hugepage（需要 kernel 支持）
echo 4 > /proc/sys/vm/nr_hugepages
mkdir -p /mnt/hugepages_1GB
mount -t hugetlbfs -o pagesize=1GB none /mnt/hugepages_1GB

# 永久配置 (/etc/sysctl.conf)
echo "vm.nr_hugepages = 1024" >> /etc/sysctl.conf
echo "vm.hugetlb_shm_group = 0" >> /etc/sysctl.conf
sysctl -p
```

### 4.2 VPP Hugepage 配置

```bash
# startup.conf 中的 hugepage 配置
unix {
    # 使用 2MB hugepage（每个 2MB，共 2GB）
    hugefile /mnt/hugepages
    nohuge
}

# 或者使用默认路径
unix {
    # VPP 默认会在 /mnt/hugepages 寻找 hugepage
    # 如果不存在，使用普通 page
}

# 检查 hugepage 使用
vppctl show memory

# 示例输出：
# Memory:
#   Total:     4096 MB
#   Hugepages:  2048 MB (1024 x 2MB)
#   Heap:      1024 MB
#   Buffers:   1024 MB (262144 x 4096)
```

### 4.3 多进程 Hugepage 共享

```bash
# 创建共享 hugepage 区域（多个 VPP 实例共享）
mkdir -p /mnt/hugepages_shared
mount -t hugetlbfs none /mnt/hugepages_shared

# 配置文件权限
chown root:vpp /mnt/hugepages_shared
chmod 1775 /mnt/hugepages_shared

# 多个 VPP 实例配置
# Instance 1:
unix {
    hugefile /mnt/hugepages_shared/vpp1
    uid 1000
    gid 1000
}

# Instance 2:
unix {
    hugefile /mnt/hugesites_shared/vpp2
    uid 1001
    gid 1001
}
```

### 4.4 1GB Hugepage（高级）

```bash
# 1GB hugepage 配置（需要 CPU 支持）
# 检查 CPU 支持
grep -E '(pdpe1gb|huge)' /proc/cpuinfo

# 配置 1GB hugepage
echo 4 > /proc/sys/vm/nr_hugepages
mkdir -p /mnt/hugepages_1GB
mount -t hugetlbfs -o pagesize=1G none /mnt/hugepages_1GB

# VPP 配置
unix {
    hugefile /mnt/hugepages_1GB/vpp_hugepage
    # 或者使用 symlink
    # hugefile /dev/hugepages/vpp
}

# 内存分配示例（4GB = 4 x 1GB page）
# startup.conf:
dpdk {
    socket-mem 4096
}
```

## 5. Cache 优化

### 5.1 CPU Cache 结构

```
┌─────────────────────────────────────────────────────────────┐
│                    CPU Cache 层次结构                        │
│                                                              │
│   Core 0          Core 1          Core 2          Core 3    │
│   ┌───────┐       ┌───────┐       ┌───────┐       ┌───────┐ │
│   │  L1   │       │  L1   │       │  L1   │       │  L1   │ │
│   │ 32KB  │       │ 32KB  │       │ 32KB  │       │ 32KB  │ │
│   └───────┘       └───────┘       └───────┘       └───────┘ │
│       ↑               ↑               ↑               ↑     │
│   ┌───────┐       ┌───────┐       ┌───────┐       ┌───────┐ │
│   │  L2   │       │  L2   │       │  L2   │       │  L2   │ │
│   │ 256KB │       │ 256KB │       │ 256KB │       │ 256KB │ │
│   └───────┘       └───────┘       └───────┘       └───────┘ │
│       ↑               ↑               ↑               ↑     │
│   ┌─────────────────────────────────────────────────────┐   │
│   │                    L3 Cache (Shared)                  │   │
│   │                       32MB                           │   │
│   └─────────────────────────────────────────────────────┘   │
│                           ↑                                  │
│   ┌─────────────────────────────────────────────────────┐   │
│   │                    Main Memory                       │   │
│   └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 5.2 Cache Miss 类型

| 类型           | 原因           | 影响     | 解决方法              |
| -------------- | -------------- | -------- | --------------------- |
| **Compulsory** | 首次访问       | 无法避免 | 预取                  |
| **Capacity**   | 工作集 > cache | 高       | 增加 cache/减少工作集 |
| **Conflict**   | hash 冲突      | 中       | 调整数据布局          |
| **Coherence**  | 多核一致       | 低       | 使用私有数据          |

### 5.3 Buffer 布局优化

```c
// 优化 buffer 数据布局，减少 cache miss

// 优化前：跨 cache line 边界
typedef struct {
    vlib_buffer_t buffer;        // 64B
    u8 packet_data[1972];         // 跨越多个 cache line
} vlib_buffer_data_t;

// 优化后：对齐到 cache line
typedef struct {
    vlib_buffer_t buffer;        // 64B, cache line 边界对齐
    u8 padding[128];              // 填充到下一个 cache line
    u8 packet_data[1792];          // 2KB，cache line 对齐
} __attribute__((aligned(64))) aligned_buffer_t;

// DMA 内存对齐
always_inline void *
dma_alloc_aligned (u32 size, u32 align)
{
    void *ptr;
    if (posix_memalign(&ptr, align, size) != 0)
        return 0;
    return ptr;
}

// Buffer DMA 描述符对齐
typedef struct {
    u64 addr;          // 必须对齐到 16 字节（ARM）或 8 字节（x86）
    u32 len;
    u16 reserved;
    u16 flags;
} __attribute__((aligned(16))) dma_desc_t;
```

### 5.4 Prefetch 优化

```c
// Software prefetch 示例

always_inline void
prefetch_buffer_data (vlib_buffer_t *b)
{
    // 预取包数据到 L1 cache
    prefetch(buffer_data, VLIB_BUFFER_DATA_SIZE / 64);
}

always_inline void
process_with_prefetch (vlib_main_t *vm, vlib_buffer_t **buffers, u32 n)
{
    u32 i;

    // Prefetch 接下来要处理的 buffer
    for (i = 0; i < n - 4; i += 4) {
        // 预取 buffer 元数据到 L1
        prefetch_L1(buffers[i + 4]);
        // 预取包数据到 L2
        prefetch_L2(buffer_data(buffers[i + 4]));
    }

    // 处理当前 batch
    for (i = 0; i < n; i++) {
        vlib_buffer_t *b = buffers[i];

        // 处理包数据...
        process_packet(b);

        // 释放 buffer
        vlib_buffer_free(vm, 1);
    }
}

// 使用 CLIB prefetch 宏
#define PREFETCH(addr, level)  __builtin_prefetch(addr, 0, level)

// Prefetch levels:
// 0 = temporal, no intention to write
// 1 = temporal, intention to write
// 2 = non-temporal, streaming
// 3 = non-temporal, collecting
```

### 5.5 False Sharing 避免

```c
// 避免 false sharing - 确保不同线程的数据在不同 cache line

// 优化前：False sharing
typedef struct {
    u64 counter;           // 被多个线程更新
    u64 padding[7];        // 不够，仍在同一 cache line
} shared_data_t;

// 问题：thread 0 和 thread 1 更新不同 counter
// 但 cache line 256B 被两个 core 竞争

// 优化后：Padding 到 cache line 大小
typedef struct {
    u64 counter;
    u8 padding[64 - sizeof(u64)];  // 填充到 cache line
} __attribute__((aligned(64))) thread_local_counter_t;

// 每个线程使用独立的 cache line
thread_local_counter_t counters[16];

// 确保 atomic 操作不会引入 false sharing
always_inline void
increment_counter_safely (u32 thread_id, u64 value)
{
    // 使用原子操作，且确保 aligned
    __sync_fetch_and_add(&counters[thread_id].counter, value);
}
```

## 6. NUMA 优化

### 6.1 NUMA 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    NUMA 架构示例（2 Socket）                  │
│                                                              │
│        Socket 0                    Socket 1                   │
│    ┌──────────────┐          ┌──────────────┐              │
│    │   CPU 0-7    │          │   CPU 8-15   │              │
│    │   Cores      │          │   Cores      │              │
│    └──────┬───────┘          └──────┬───────┘              │
│           │                          │                       │
│    ┌──────┴───────┐          ┌──────┴───────┐              │
│    │    L3 Cache  │          │    L3 Cache  │              │
│    │     32MB     │          │     32MB     │              │
│    └──────┬───────┘          └──────┬───────┘              │
│           │                          │                       │
│    ┌──────┴───────┐          ┌──────┴───────┐              │
│    │    DDR        │          │    DDR        │              │
│    │   64GB        │          │   64GB        │              │
│    │   Local       │          │   Local       │              │
│    └───────────────┘          └───────────────┘              │
│           │                          │                       │
│           └──────────┬───────────────┘                       │
│                      │                                       │
│              ┌───────┴───────┐                               │
│              │  QPI/UPI      │                               │
│              │  Interconnect │                               │
│              └───────────────┘                               │
└─────────────────────────────────────────────────────────────┘
```

### 6.2 VPP NUMA 配置

```bash
# startup.conf 配置
dpdk {
    socket-mem 1024,1024              # 为每个 socket 分配 1GB
    socket-limit 1024,1024            # 每个 socket 的限制
}

# CPU 亲和性配置
cpu {
    main-core 0                       # Main 线程在 socket 0
    corelist-workers 1-7,9-15         # Worker 分布在两个 socket
}

# 查看 NUMA 统计
vppctl show numa

# 示例输出：
# NUMA 0:
#   Memory:    1024 MB allocated
#   Buffers:   262144
#   Workers:    4 (cores 1-4)
#   RX queues: 4
#
# NUMA 1:
#   Memory:    1024 MB allocated
#   Buffers:   262144
#   Workers:    4 (cores 9-12)
#   RX queues: 4
```

### 6.3 NUMA-aware 分配

```c
// NUMA-aware 内存分配

// 在指定 socket 创建内存池
static void *
numa_alloc (u32 socket, u32 size)
{
    void *ptr;

    if (socket == 0) {
        ptr = mmap(NULL, size, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS | MAP_HUGETLB,
                   -1, 0);
    } else {
        // 为特定 socket 创建内存
        ptr = mmap(NULL, size, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS | MAP_HUGETLB,
                   -1, 0);
    }

    // 绑定到 NUMA node
    set_mempolicy(MMPOLICY_BIND, &socket, 1);

    return ptr;
}

// 获取本地 socket
always_inline u32
vlib_get_current_socket (void)
{
    return os_get_current_numa_node();
}

// Buffer 分配时选择正确 socket
always_inline u32 *
vlib_buffer_alloc_on_socket (vlib_main_t *vm, u32 n, u32 socket)
{
    if (socket == vlib_get_current_socket()) {
        // 本地分配，最快
        return vlib_buffer_alloc(vm, n);
    } else {
        // 远程分配，有延迟
        return vlib_buffer_alloc_remote(vm, n, socket);
    }
}

// 分配策略：优先本地，备选远程
always_inline u32 *
smart_buffer_alloc (vlib_main_t *vm, u32 n_buffers, u32 preferred_socket)
{
    u32 *indices;

    // 首先尝试本地分配
    indices = vlib_buffer_alloc_on_socket(vm, n_buffers, preferred_socket);

    if (indices)
        return indices;

    // 本地不足，尝试远程
    for (u32 s = 0; s < num_sockets; s++) {
        if (s == preferred_socket)
            continue;

        indices = vlib_buffer_alloc_on_socket(vm, n_buffers, s);
        if (indices)
            return indices;
    }

    return 0; // 分配失败
}
```

### 6.4 多队列 NUMA 分布

```bash
# 为每个 NUMA node 配置 RX 队列
# startup.conf:
dpdk {
    dev default {
        # RX 队列数 = CPU cores per socket
        num-rx-queues 4
        num-tx-queues 4

        # 启用 RSS
        rxq-size 1024
        txq-size 1024
    }
}

# 查看接口队列分布
vppctl show hardware

# 示例输出：
# Interface: TenGigabitEthernet0/0/0
#   NUMA node: 0
#   RX queues: 4 (queue 0-3 on core 1-4)
#   TX queues: 4 (queue 0-3 on core 1-4)
#
# Interface: TenGigabitEthernet0/1/0
#   NUMA node: 1
#   RX queues: 4 (queue 0-3 on core 9-12)
#   TX queues: 4 (queue 0-3 on core 9-12)
```

## 7. 内存调优实战

### 7.1 典型调优场景

| 场景             | 问题         | 解决方案         |
| ---------------- | ------------ | ---------------- |
| **高吞吐丢包**   | Buffer 不足  | 增加 buffer 数量 |
| **延迟抖动**     | Cache miss   | 优化数据布局     |
| **内存碎片**     | 长期运行     | 使用 hugepage    |
| **跨 NUMA 访问** | 远端内存延迟 | 亲和性配置       |

### 7.2 调优命令参考

```bash
# 查看当前内存配置
vppctl show memory
vppctl show buffers
vppctl show numa

# 运行时调整 buffer（需要插件支持）
vppctl set buffer count 524288

# 查看内存池统计
vppctl show memory-pools

# 示例输出：
# Memory pools:
#   buffer-pool-0 (socket 0):
#     size: 262144, free: 196608, used: 65536
#   buffer-pool-1 (socket 1):
#     size: 262144, free: 200000, used: 62144

# 监控内存变化
watch -n 1 'vppctl show memory'
```

### 7.3 性能影响评估

```c
// 评估内存配置对性能的影响

typedef struct {
    u64 allocation_time;       // 分配耗时
    u64 free_time;            // 释放耗时
    u64 local_access;          // 本地访问次数
    u64 remote_access;        // 远程访问次数
    u64 cache_misses;         // Cache miss 数
} memory_perf_stats_t;

// 测试不同配置的性能
void
benchmark_memory_config (vlib_main_t *vm, memory_config_t *config)
{
    memory_perf_stats_t stats = {0};

    // 测试分配性能
    u64 start = clib_cpu_time_now();
    u32 *buffers = vlib_buffer_alloc(vm, 10000);
    u64 alloc_time = clib_cpu_time_now() - start;

    // 测试释放性能
    start = clib_cpu_time_now();
    vlib_buffer_free(vm, buffers, 10000);
    u64 free_time = clib_cpu_time_now() - start;

    // 输出结果
    fformat(stdout, "Allocation: %lu cycles\n", alloc_time);
    fformat(stdout, "Free: %lu cycles\n", free_time);
    fformat(stdout, "Cycles/packet: %lu\n", (alloc_time + free_time) / 10000);
}

// 调优建议生成
void
generate_tuning_recommendations (vlib_main_t *vm)
{
    u64 buffer_miss_rate = get_buffer_miss_rate();
    u64 cache_miss_rate = get_cache_miss_rate();

    if (buffer_miss_rate > 0.1) {
        fformat(stdout, "建议: 增加 buffer 数量\n");
        fformat(stdout, "  当前: %u buffers\n", get_buffer_count());
        fformat(stdout, "  建议: %u buffers\n", get_buffer_count() * 2);
    }

    if (cache_miss_rate > 0.05) {
        fformat(stdout, "建议: 优化数据布局\n");
        fformat(stdout, "  - 使用 prefetch\n");
        fformat(stdout, "  - 对齐数据结构\n");
    }
}
```

### 7.4 配置模板

```bash
# high-performance.conf - 高性能配置

# Memory 配置
dpdk {
    socket-mem 4096,4096           # 8GB total (2 socket)
    hugefile /mnt/hugepages
    mbuf_pool_size 524288          # 双倍 buffer
    mbuf_cache_size 512
}

# Buffer 配置
buffers {
    default data size 2048
    numberof buffers 524288
    availability-depth 256
}

# NUMA 配置
cpu {
    main-core 0
    corelist-workers 1-7,9-15
}

# Cache 配置
unix {
    exec-policy static        # 避免动态分配
    default heap size 512M
}

# 调优建议
# 1. 对于 10Gbps 流量：buffer 数量 >= 262144
# 2. 对于 40Gbps 流量：buffer 数量 >= 524288
# 3. 对于 100Gbps 流量：buffer 数量 >= 1048576
```

## 8. 内存泄漏检测

### 8.1 泄漏检测工具

```bash
# 使用 valgrind 检测内存泄漏（慢，仅用于测试）
valgrind --leak-check=full vpp

# 使用 address sanitizer（更快）
export VPP_HEAPCHECK=strict
vpp

# VPP 内置 heap 追踪
unix {
    heap-trace on
    heap-size 512M
}

# 查看 heap 使用
vppctl show memory verbose

# 示例输出：
# Heap:
#   Size: 512 MB
#   Used: 256 MB (50.0%)
#   Allocations: 10000
#   Frees: 9000
#   Leak suspected: 100 allocations
```

### 8.2 常见泄漏模式

```c
// 常见内存泄漏模式

// 1. API 消息未释放
void leak_example_1 (api_main_t *am)
{
    vl_api_registration_t *reg;

    // 分配消息
    vlapi_create_message(&reg->pool, &msg);

    // 忘记释放
    // vlapi_free_message(msg);  // ← 缺少这行

    return;
}

// 2. buffer 未归还
void leak_example_2 (vlib_main_t *vm, u32 *buffers, u32 n)
{
    vlib_buffer_t *b;

    for (u32 i = 0; i < n; i++) {
        b = vlib_get_buffer(vm, buffers[i]);
        // 处理 buffer
        process_buffer(b);

        // 某些条件下未释放
        if (should_drop(b)) {
            continue;  // ← buffer 泄漏
        }
    }

    return;
}

// 正确做法：确保所有路径都释放
void no_leak_example (vlib_main_t *vm, u32 *buffers, u32 n)
{
    for (u32 i = 0; i < n; i++) {
        vlib_buffer_t *b = vlib_get_buffer(vm, buffers[i]);

        if (should_drop(b)) {
            vlib_buffer_free(vm, 1);  // ← 明确释放
            continue;
        }

        process_buffer(b);
        vlib_buffer_free(vm, 1);
    }
}
```

### 8.3 内存调试技术

```c
// VPP 内置内存调试

// 启用内存追踪
void
enable_memory_debug (vlib_main_t *vm)
{
    vm->heap_trace = 1;
    vm->buffer_trace = 1;
}

// 追踪 buffer 分配
always_inline u32 *
trace_buffer_alloc (vlib_main_t *vm, char *file, int line, u32 n)
{
    u32 *indices = vlib_buffer_alloc(vm, n);

    if (vm->buffer_trace) {
        fformat(stderr, "%s:%d: allocated %u buffers\n", file, line, n);
        for (u32 i = 0; i < n; i++) {
            fformat(stderr, "  buffer[%u] index %u\n", i, indices[i]);
        }
    }

    return indices;
}

// 使用宏包装
#define vlib_buffer_alloc(vm, n) \
    trace_buffer_alloc(vm, __FILE__, __LINE__, n)

// 验证 buffer 状态
always_inline void
validate_buffer (vlib_buffer_t *b)
{
    ASSERT(b->magic == VLIB_BUFFER_MAGIC);
    ASSERT(b->ref_count > 0);
    ASSERT(b->ref_count < 1000);
}
```

## 9. 总结

```
┌─────────────────────────────────────────────────────────────┐
│                 Buffer 与 Memory 调优总结                     │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐ │
│  │                     Buffer 优化                        │ │
│  │  - 数量：满足接口队列深度 × 突发系数                    │ │
│  │  - 大小：根据 MTU 选择 2KB/4KB/9KB                      │ │
│  │  - 分配：NUMA 本地优先                                  │ │
│  └────────────────────────────────────────────────────────┘ │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐ │
│  │                    Heap 优化                            │ │
│  │  - 使用 hugepage：减少 TLB miss                         │ │
│  │  - 避免碎片：批量分配释放                               │ │
│  │  - 监控泄漏：定期检查                                   │ │
│  └────────────────────────────────────────────────────────┘ │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐ │
│  │                    Cache 优化                           │ │
│  │  - Prefetch：提前加载数据                               │ │
│  │  - 对齐：避免 false sharing                             │ │
│  │  - 批量：减少函数调用开销                               │ │
│  └────────────────────────────────────────────────────────┘ │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐ │
│  │                    NUMA 优化                           │ │
│  │  - socket 内存绑定                                      │ │
│  │  - worker 亲和性                                       │ │
│  │  - 队列分布匹配                                        │ │
│  └────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

---

> [!tip] 最佳实践
>
> 1. 生产环境必须使用 hugepage，2MB 起步，1GB 最佳
> 2. Buffer 数量保守配置为计算值的 2 倍
> 3. NUMA 配置时，确保内存分配在本地 socket
> 4. 定期监控内存使用，检测泄漏

> [!warning] 注意事项
>
> - Buffer 过少导致丢包，过多浪费内存
> - Hugepage 过小会导致 TLB miss 增加
> - 跨 NUMA 访问会有显著延迟惩罚
> - Debug 模式会禁用某些优化
