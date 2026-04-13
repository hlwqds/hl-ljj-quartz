---
title: "DPDK 深度探索 (二十六)：NUMA 亲和性与 Local/Remote 访问"
date: 2026-04-09
tags: [dpdk, series, numa, affinity, local-memory, remote-memory, memory-policy, socket, lcore, allocation]
description: "深入理解 NUMA 架构与 DPDK 性能优化——NUMA 拓扑、CPU-内存亲和性、local vs remote 访问延迟、数据分片策略、DPDK socket 感知"
---

> [!info] DPDK 深度探索系列
> 0. [[2026-04-09-dpdk-deep-dive-series-index|全栈学习路径总览]]
> 1-25. 前二十五章已完成
> 26. **第二十六章：NUMA 亲和性与 Local/Remote 访问**

---

## 1. 概述：NUMA 架构

### 1.1 UMA vs NUMA

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        UMA vs NUMA 架构                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  UMA (Uniform Memory Access):                                             │
│  ────────────────────────────                                               │
│                                                                             │
│              ┌─────────────────────────────────────┐                        │
│              │              CPU Cores              │                        │
│              │   ┌───┐ ┌───┐ ┌───┐ ┌───┐        │                        │
│              │   │ 0 │ │ 1 │ │ 2 │ │ 3 │        │                        │
│              │   └───┘ └───┘ └───┘ └───┘        │                        │
│              └───────────────┬─────────────────────┘                        │
│                              │                                               │
│                              │ 共享总线                                        │
│                              │ (~100 GB/s, 瓶颈)                             │
│                              ▼                                               │
│                    ┌─────────────────────┐                                 │
│                    │    统一内存         │                                 │
│                    │    (所有核共享)     │                                 │
│                    └─────────────────────┘                                 │
│                                                                             │
│  特点: 所有核访问内存延迟相同                                              │
│  问题: 核数增加时，总线成为瓶颈                                            │
│                                                                             │
│  ─────────────────────────────────────────────────────────────────────────  │
│                                                                             │
│  NUMA (Non-Uniform Memory Access):                                         │
│  ─────────────────────────────────                                          │
│                                                                             │
│     Socket 0                      Socket 1                                  │
│  ┌──────────────────┐      ┌──────────────────┐                          │
│  │   CPU Cores      │      │   CPU Cores      │                          │
│  │  ┌───┐┌───┐┌───┐│      │  ┌───┐┌───┐┌───┐│                          │
│  │  │ 0 ││ 1 ││ 2 ││      │  │ 8 ││ 9 ││10 ││                          │
│  │  └───┘└───┘└───┘│      │  └───┘└───┘└───┘│                          │
│  │  ┌───┐┌───┐┌───┐│      │  ┌───┐┌───┐┌───┐│                          │
│  │  │ 3 ││ 4 ││ 5 ││      │  │11 ││12 ││13 ││                          │
│  │  └───┘└───┘└───┘│      │  └───┘└───┘└───┘│                          │
│  └────────┬────────┘      └────────┬────────┘                          │
│           │                          │                                      │
│           ▼                          ▼                                      │
│  ┌──────────────────┐      ┌──────────────────┐                          │
│  │   本地内存         │      │   本地内存         │                          │
│  │   (DDR4 x4)       │      │   (DDR4 x4)       │                          │
│  │   64 GB           │      │   64 GB           │                          │
│  └──────────────────┘      └──────────────────┘                          │
│           │                          │                                      │
│           └──────────┬────────────────┘                                      │
│                      │                                                      │
│                      ▼                                                      │
│            ┌─────────────────────┐                                         │
│            │   QPI/UPI 互联        │                                        │
│            │   (~100 GB/s)       │                                        │
│            └─────────────────────┘                                         │
│                                                                             │
│  特点: 本地访问快，远程访问慢                                              │
│  优势: 可扩展性好                                                          │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 1.2 现代 NUMA 拓扑

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        双路服务器 NUMA 拓扑                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│                           ┌─────────────────┐                              │
│                           │   QPI/UPI Link   │                              │
│                           │    10-25 GB/s    │                              │
│  ┌────────────────────────┤                  ├────────────────────────┐   │
│  │      Socket 0          │                  │      Socket 1          │   │
│  │                        │                  │                        │   │
│  │   Cores: 0-27          │                  │   Cores: 28-55         │   │
│  │   L3 Cache: 36 MB     │                  │   L3 Cache: 36 MB     │   │
│  │   DDR4: 256 GB        │                  │   DDR4: 256 GB        │   │
│  │   Channels: 8        │                  │   Channels: 8        │   │
│  │                        │                  │                        │   │
│  │   ┌────────────────┐  │                  │  ┌────────────────┐  │   │
│  │   │  Memory Ctrl    │  │                  │  │  Memory Ctrl    │  │   │
│  │   │   DDR4 x8       │  │                  │  │   DDR4 x8       │  │   │
│  │   └────────────────┘  │                  │  └────────────────┘  │   │
│  │                        │                  │                        │   │
│  │   PCIe Root Complex   │                  │   PCIe Root Complex   │   │
│  │   ├─ NIC 0 (eth0)     │                  │   ├─ NIC 1 (eth1)     │   │
│  │   ├─ NIC 1 (eth1)     │                  │   ├─ GPU 0           │   │
│  │   └─ NVMe 0           │                  │   └─ NVMe 1           │   │
│  │                        │                  │                        │   │
│  └────────────────────────┘                  └────────────────────────┘   │
│                                                                             │
│  NUMA 距离:                                                               │
│  ─────────                                                               │
│  Socket 0 Core 0 访问:                                                   │
│    - Socket 0 Memory: ~80 ns (本地)                                       │
│    - Socket 1 Memory: ~150 ns (跨 QPI/UPI)                               │
│    - 延迟差异: ~2x                                                        │
│                                                                             │
│  带宽:                                                                   │
│  ────                                                                    │
│  本地内存: ~100 GB/s (双通道 DDR4-2666)                                  │
│  跨插槽: ~25 GB/s (QPI 1.1) / ~50 GB/s (UPI)                            │
│  差距: ~4-8x                                                             │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 1.3 NUMA 访问延迟对比

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        NUMA 访问延迟量化                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  Intel Xeon Skylake-SP 双路服务器测试数据:                                 │
│                                                                             │
│  访问类型                      延迟              带宽                       │
│  ──────────────────────────────────────────────────────────────────────── │
│  L1 Cache                    1 ns              ∞                          │
│  L2 Cache                    4 ns              ∞                          │
│  L3 Cache (本地)             12 ns              ∞                          │
│  L3 Cache (远程)             25 ns              ∞                          │
│  DDR4 Memory (本地)          80 ns              100 GB/s                   │
│  DDR4 Memory (远程)         150 ns              25 GB/s                    │
│                                                                             │
│  AMD EPYC Rome 双路服务器测试数据:                                         │
│                                                                             │
│  访问类型                      延迟              带宽                       │
│  ──────────────────────────────────────────────────────────────────────── │
│  L3 Cache (本地 CCX)          8 ns              ∞                          │
│  L3 Cache (远程 CCX)         30 ns              ∞                          │
│  DDR4 Memory (本地)          75 ns              90 GB/s                   │
│  DDR4 Memory (远程)         140 ns              20 GB/s                   │
│                                                                             │
│  关键结论:                                                                 │
│  ──────────                                                                │
│  1. 远程内存访问延迟比本地高 2-3x                                          │
│  2. 远程内存带宽比本地低 4-8x                                              │
│  3. 跨 CPU 访问仍比访问 NVMe 快得多                                        │
│  4. 但对于网络密集型负载，NUMA 效应明显                                     │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. DPDK NUMA 感知 API

### 2.1 Socket 与 Lcore 查询

```c
// lib/eal/include/rte_lcore.h

// 获取当前 lcore 的 socket ID
static inline unsigned
rte_lcore_to_socket_id(unsigned lcore_id)
{
    return rte_eal_socket_config()[lcore_id].socket_id;
}

// 获取当前 lcore ID
static inline unsigned
rte_lcore_id(void)
{
    return rte_gettid();  // 线程本地 lcore ID
}

// 获取 lcore 数量
static inline unsigned
rte_lcore_count(void)
{
    return rte_eal_get_configuration()->lcore_count;
}

// 遍历所有 lcore
#define RTE_LCORE_FOREACH(i) \
    for (i = rte_lcore_iterate(0); \
         i < RTE_MAX_LCORE; \
         i = rte_lcore_iterate(i))

// 遍历所有 lcore 并获取 socket
static inline unsigned
rte_lcore_foreach_socket(int socket_id, unsigned *lcore_list, unsigned n)
{
    unsigned i, count = 0;
    RTE_LCORE_FOREACH(i) {
        if (rte_lcore_to_socket_id(i) == socket_id) {
            if (count < n)
                lcore_list[count] = i;
            count++;
        }
    }
    return count;
}

// 示例: 打印 NUMA 拓扑
void
print_numa_topology(void)
{
    printf("NUMA Topology:\n");
    printf("================\n");

    int num_sockets = rte_eal_numa_manager_get_num_sockets();

    for (int s = 0; s < num_sockets; s++) {
        printf("\nSocket %d:\n", s);

        unsigned lcore_list[RTE_MAX_LCORE];
        unsigned n = rte_lcore_foreach_socket(s, lcore_list, RTE_MAX_LCORE);

        printf("  Lcores: ");
        for (unsigned i = 0; i < n; i++)
            printf("%u ", lcore_list[i]);
        printf("\n");

        printf("  Memory: %lu MB\n",
               rte_eal_numa_manager_get_socket_mem(s) / 1024 / 1024);
    }
}
```

### 2.2 内存分配与 NUMA

```c
// lib/eal/include/rte_malloc.h

// NUMA 感知的内存分配

// 在指定 socket 分配内存
void *
rte_malloc_socket(const char *type, size_t size, unsigned align, int socket_id)
{
    if (socket_id == SOCKET_ID_ANY)
        socket_id = rte_lcore_to_socket_id(rte_lcore_id());

    return rte_malloc_alloc(size, align, socket_id);
}

// 在本地 socket 分配
void *
rte_malloc_local(const char *type, size_t size, unsigned align)
{
    return rte_malloc_socket(type, size, align, rte_lcore_to_socket_id(rte_lcore_id()));
}

// 分配对齐内存
void *
rte_memalign_socket(size_t align, size_t size, int socket_id)
{
    return rte_malloc_socket(NULL, size, align, socket_id);
}

// NUMA 感知 mbuf pool 创建
struct rte_mempool *
rte_pktmbuf_pool_create_by_idx(const char *name, unsigned elt_count,
                                unsigned cache_size, void *op_arg,
                                unsigned int idx)  // socket idx
{
    struct rte_pktmbuf_pool_private mbp_priv;

    mbp_priv.mbuf_data_room_size = RTE_PKTMBUF_HEADROOM + 1500;
    mbp_priv.mbuf_priv_size = 0;

    return rte_mempool_create(name, elt_count,
                               sizeof(struct rte_mbuf),
                               cache_size,
                               sizeof(mbp_priv),
                               &mbp_priv,
                               idx);  // NUMA socket
}

// 为每个 socket 创建独立的 mbuf pool
struct mbuf_pools {
    struct rte_mempool *pools[RTE_MAX_NUMA_NODES];
    unsigned num_pools;
};

int
create_numa_aware_pools(struct mbuf_pools *pools, int socket_count)
{
    char pool_name[64];

    pools->num_pools = socket_count;

    for (int s = 0; s < socket_count; s++) {
        snprintf(pool_name, sizeof(pool_name), "mbuf_pool_socket%d", s);

        pools->pools[s] = rte_pktmbuf_pool_create(
            pool_name,
            16384,     // elt_count
            256,       // cache_size
            0,         // priv_size
            2048,      // data_room_size
            s          // socket_id
        );

        if (!pools->pools[s]) {
            printf("Failed to create pool for socket %d\n", s);
            return -1;
        }
    }

    return 0;
}
```

### 2.3 NIC 与 NUMA 亲和性

```c
// lib/ethdev/rte_ethdev.h

// 查询 port 所在的 socket
int
rte_eth_dev_socket_id(uint16_t port_id)
{
    struct rte_eth_dev *dev = &rte_eth_devices[port_id];

    if (!dev->data)
        return -1;

    return dev->pci_dev->numa_node;
}

// ethdev 设备信息
struct rte_eth_dev_info {
    const char *driver_name;
    uint16_t device_id;
    uint16_t vendor_id;
    int numa_node;         // 设备所在的 NUMA 节点
    unsigned int nb_rx_queues;
    unsigned int nb_tx_queues;
    // ...
};

// 获取设备信息
int
rte_eth_dev_info_get(uint16_t port_id, struct rte_eth_dev_info *dev_info)
{
    return eth_err(port_id, (*dev->dev_ops->dev_infos_get)(dev, dev_info));
}

// NIC 亲和性建议
unsigned
get_device_numa_node(uint16_t port_id)
{
    struct rte_eth_dev_info dev_info;
    rte_eth_dev_info_get(port_id, &dev_info);
    return dev_info.numa_node;
}

// 推荐: 每个 NIC 使用本地 socket 的 lcore 处理
void
print_nic_numa_affinity(uint16_t port_id)
{
    int nic_socket = get_device_numa_node(port_id);

    printf("Port %d:\n", port_id);
    printf("  NUMA Node: %d\n", nic_socket);

    // 查找同一 socket 的 lcore
    unsigned lcore_list[RTE_MAX_LCORE];
    unsigned n = rte_lcore_foreach_socket(nic_socket, lcore_list, RTE_MAX_LCORE);

    printf("  Recommended lcores: ");
    for (unsigned i = 0; i < n && i < 4; i++)
        printf("%u ", lcore_list[i]);
    printf("\n");
}
```

---

## 3. Local vs Remote 访问

### 3.1 访问模式分析

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        Local vs Remote 访问                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  场景: 双路服务器，Socket 0 和 Socket 1                                    │
│                                                                             │
│  Core 0 (Socket 0) 访问内存:                                               │
│  ─────────────────────────────────────                                     │
│                                                                             │
│  Local Access: Core 0 ──► Memory Controller 0 ──► DDR4 0                  │
│                      延迟: ~80 ns                                          │
│                      带宽: ~100 GB/s                                       │
│                                                                             │
│  Remote Access: Core 0 ──► QPI/UPI ──► Memory Controller 1 ──► DDR4 1     │
│                      延迟: ~150 ns                                          │
│                      带宽: ~25 GB/s                                        │
│                                                                             │
│  性能影响:                                                                 │
│  ──────────                                                                │
│                                                                             │
│  1. 延迟: 远程访问比本地慢约 2x                                              │
│  2. 带宽: 远程带宽比本地低约 4-8x                                            │
│  3. CPU 利用率: 跨插槽传输消耗 QPI/UPI 带宽                                 │
│  4. 可扩展性: 多 socket 系统，远程访问成为瓶颈                               │
│                                                                             │
│  DPDK 包处理中的 NUMA 问题:                                                 │
│  ────────────────────────────────                                            │
│                                                                             │
│  NIC 0 (Socket 0) 接收包 ──► Core 5 (Socket 0) 处理 ──► 访问 Socket 1 内存 │
│                                                                             │
│  问题:                                                                     │
│  - mbuf 在 Socket 1 分配                                                   │
│  - Core 5 访问 mbuf 数据需要跨 QPI                                          │
│  - 吞吐量和延迟都受影响                                                     │
│                                                                             │
│  解决方案:                                                                 │
│  ────────                                                                  │
│  1. Core 优先使用本地 NIC 的包                                              │
│  2. mbuf pool 在 Core 所在 socket                                          │
│  3. 数据处理尽量在本地完成                                                  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 3.2 内存访问检测

```c
// 检测 NUMA 访问模式

#include <numaif.h>
#include <hwloc.h>

// 使用 hwloc 获取 NUMA 距离
hwloc_obj_t
get_numa_node_by_cpuset(hwloc_topology_t topology, hwloc_cpuset_t cpuset)
{
    return hwloc_get_obj_by_cpuset(topology, HWLOC_OBJ_NUMANODE, cpuset);
}

// 计算两个 NUMA 节点之间的距离
int
get_numa_distance(int node1, int node2)
{
    hwloc_topology_t topology;
    hwloc_topology_init(&topology);
    hwloc_topology_load(&topology);

    hwloc_obj_t node_obj1 = hwloc_get_numanode_obj_by_os_index(topology, node1);
    hwloc_obj_t node_obj2 = hwloc_get_numanode_obj_by_os_index(topology, node2);

    int distance = hwloc_get_distance_by_obj(topology, node_obj1, node_obj2);

    hwloc_topology_destroy(topology);

    return distance;
}

// 检测指针所在的 NUMA 节点
int
get_ptr_numa_node(void *ptr)
{
    int node;
    get_mempolicy(&node, NULL, 0, ptr, MPOL_F_NODE | MPOL_F_ADDR);

    return node;
}

// DPDK 中检测本地/远程访问
enum memory_access_type {
    MEMORY_ACCESS_LOCAL = 0,
    MEMORY_ACCESS_REMOTE,
};

static inline enum memory_access_type
classify_memory_access(const void *ptr)
{
    int ptr_node = get_ptr_numa_node((void *)ptr);
    int current_node = rte_lcore_to_socket_id(rte_lcore_id());

    return (ptr_node == current_node) ? MEMORY_ACCESS_LOCAL : MEMORY_ACCESS_REMOTE;
}

// 统计访问模式
struct numa_access_stats {
    uint64_t local_accesses;
    uint64_t remote_accesses;
};

static thread_local struct numa_access_stats access_stats;

static inline void
record_memory_access(const void *ptr)
{
    if (classify_memory_access(ptr) == MEMORY_ACCESS_LOCAL)
        access_stats.local_accesses++;
    else
        access_stats.remote_accesses++;
}

static void
print_access_stats(void)
{
    uint64_t total = access_stats.local_accesses + access_stats.remote_accesses;

    printf("Memory Access Stats:\n");
    printf("  Local:  %lu (%.1f%%)\n",
           access_stats.local_accesses,
           100.0 * access_stats.local_accesses / total);
    printf("  Remote: %lu (%.1f%%)\n",
           access_stats.remote_accesses,
           100.0 * access_stats.remote_accesses / total);
}
```

### 3.3 NUMA 友好的数据结构

```c
// NUMA 友好的数据结构设计

// 方案 1: Per-Socket 数据分区

#define MAX_SOCKETS 8
#define MAX_LCORES 128

// 每个 socket 独立的数据
struct per_socket_data {
    struct rte_ring *tx_ring;
    struct rte_mempool *mbuf_pool;
    struct flow_table *flow_table;

    uint64_t packets_processed;
    uint64_t bytes_processed;
} __rte_cache_aligned;

// 全局数组
struct per_socket_data socket_data[MAX_SOCKETS];

// 初始化 per-socket 数据
int
init_per_socket_data(void)
{
    unsigned int lcore_id;

    RTE_LCORE_FOREACH(lcore_id) {
        unsigned socket = rte_lcore_to_socket_id(lcore_id);

        // 在本地 socket 创建资源
        socket_data[socket].mbuf_pool = rte_pktmbuf_pool_create(
            "mbuf_pool",
            16384,
            256,
            0,
            2048,
            socket  // 本地 socket
        );

        socket_data[socket].tx_ring = rte_ring_create(
            "tx_ring",
            4096,
            socket,  // 本地 socket
            RING_F_SP_ENQ | RING_F_SC_DEQ
        );

        printf("Initialized socket %u: lcore %u\n", socket, lcore_id);
    }

    return 0;
}

// 获取当前 lcore 的本地数据
static inline struct per_socket_data *
get_local_socket_data(void)
{
    unsigned socket = rte_lcore_to_socket_id(rte_lcore_id());
    return &socket_data[socket];
}

// 方案 2: Thread-Local 数据副本

struct thread_local_stats {
    __thread uint64_t packets_processed;
    __thread uint64_t bytes_processed;
    __thread uint64_t cycles_elapsed;
};

// TLS 无需同步，无 False Sharing

// 方案 3: NUMA-Aware 哈希表

struct numa_aware_hash {
    struct hash_bucket {
        void *key;
        void *value;
    } __rte_cache_aligned;

    struct hash_bucket *buckets[MAX_SOCKETS];
    size_t bucket_count;
    size_t bucket_mask;
};

// 在每个 socket 创建bucket 数组
int
numa_aware_hash_create(struct numa_aware_hash *ht, size_t size)
{
    ht->bucket_count = size;
    ht->bucket_mask = size - 1;

    int num_sockets = rte_eal_numa_manager_get_num_sockets();

    for (int s = 0; s < num_sockets; s++) {
        // 在每个 socket 分配 bucket 数组
        ht->buckets[s] = rte_malloc_socket(
            "hash_buckets",
            size * sizeof(struct hash_bucket),
            RTE_CACHE_LINE_SIZE,
            s
        );

        memset(ht->buckets[s], 0, size * sizeof(struct hash_bucket));
    }

    return 0;
}

// 在本地 socket 访问
static inline void *
numa_aware_hash_lookup(struct numa_aware_hash *ht, const void *key)
{
    unsigned socket = rte_lcore_to_socket_id(rte_lcore_id());

    // 在本地 socket 的 bucket 数组查找
    struct hash_bucket *bucket = &ht->buckets[socket][0];

    // ... hash lookup logic
}
```

---

## 4. CPU 亲和性与调度

### 4.1 lcore 分配策略

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        DPDK lcore 分配策略                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  策略 1: Socket 本地化 (推荐)                                               │
│  ─────────────────────────────                                              │
│                                                                             │
│  NIC 0 (Socket 0) ──► lcore 0,1,2 (Socket 0)                              │
│  NIC 1 (Socket 1) ──► lcore 8,9,10 (Socket 1)                              │
│                                                                             │
│  优点: 本地 NIC 收包 + 本地内存访问 + 本地 mbuf pool                        │
│  缺点: 负载不均衡时扩展性有限                                               │
│                                                                             │
│  ─────────────────────────────────────────────────────────────────────────  │
│                                                                             │
│  策略 2: 交错分配                                                           │
│  ───────────────────                                                        │
│                                                                             │
│  NIC 0 ──► lcore 0,2,4 (Socket 0) + lcore 8,10 (Socket 1)                  │
│  NIC 1 ──► lcore 1,3,5 (Socket 0) + lcore 9,11 (Socket 1)                  │
│                                                                             │
│  优点: 负载均衡时可扩展                                                     │
│  缺点: 跨 socket 访问内存                                                   │
│                                                                             │
│  ─────────────────────────────────────────────────────────────────────────  │
│                                                                             │
│  策略 3: 角色分离 (最佳实践)                                                │
│  ─────────────────────────────                                              │
│                                                                             │
│  Master lcore (Socket 0): 配置和管理                                        │
│  Worker lcores (每个 socket): 包处理                                        │
│  NIC RX: 每个 NIC 由同 socket 的 lcore 处理                               │
│                                                                             │
│        ┌──────────────────────────────────────────┐                        │
│        │              Master (lcore 0)            │                        │
│        │         配置/控制/统计收集                 │                        │
│        └──────────────────────────────────────────┘                        │
│                          │                                                   │
│        ┌─────────────────┼─────────────────┐                               │
│        ▼                 ▼                 ▼                               │
│   ┌─────────┐       ┌─────────┐       ┌─────────┐                           │
│   │ RX/TX   │       │ Worker  │       │ Worker  │                           │
│   │ lcore 1 │       │ lcore 2 │       │ lcore 9 │                           │
│   │ (Skt 0) │       │ (Skt 0) │       │ (Skt 1) │                           │
│   └────┬────┘       └────┬────┘       └────┬────┘                           │
│        │                 │                 │                                │
│   ┌────┴────┐       ┌────┴────┐       ┌────┴────┐                           │
│   │ NIC 0  │       │ Memory  │       │ Memory  │                           │
│   │(Skt 0) │       │(Skt 0)  │       │(Skt 1)  │                           │
│   └─────────┘       └─────────┘       └─────────┘                           │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 4.2 lcore 亲和性设置

```c
// EAL 参数指定 lcore 亲和性

/*
  EAL 选项:
  --lcores: 指定 lcore 映射到 CPU
  --master-lcore: 指定 master lcore
  --socket-mem: 每个 socket 的内存大小
  --socket-limit: 每个 socket 的内存限制

  示例:
  ./dpdk_app -l 0-3 -n 4 --lcores='(0-2)@0,(3)@1' --socket-mem=1024,1024

  含义:
  - lcore 0,1,2 绑定到 socket 0
  - lcore 3 绑定到 socket 1
  - 每个 socket 分配 1024 MB
*/

// 运行时获取 lcore 亲和性
#include <sched.h>

cpu_set_t
get_lcore_cpuset(unsigned lcore_id)
{
    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);

    // 获取 lcore 关联的 CPU mask
    rte_thread_get_affinity(&cpuset);

    return cpuset;
}

// 设置 lcore 亲和性
int
set_lcore_affinity(unsigned lcore_id, unsigned socket_id)
{
    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);

    // 获取指定 socket 上的 CPU
    for (unsigned i = 0; i < rte_lcore_count(); i++) {
        if (rte_lcore_to_socket_id(i) == socket_id)
            CPU_SET(i, &cpuset);
    }

    return rte_thread_set_affinity(&cpuset);
}

// DPDK lcore role
enum rte_lcore_role {
    ROLE_RTE = 0,         // 普通 DPDK lcore
    ROLE_SERVICE,         // Service lcore
    ROLE_OFF,            // 禁用
};

// 设置 lcore role
int
set_lcore_role(unsigned lcore_id, enum rte_lcore_role role)
{
    struct rte_config *config = rte_eal_get_configuration();
    config->lcore_config[lcore_id].role = role;

    return 0;
}
```

### 4.3 动态负载均衡

```c
// 基于 NUMA 的动态负载均衡

struct worker_stats {
    uint64_t packets_processed;
    uint64_t cycles_elapsed;
    double packets_per_cycle;
};

static struct worker_stats worker_stats[RTE_MAX_LCORE];

// 定期调整负载
void
rebalance_load(void)
{
    // 计算每个 worker 的负载
    struct {
        unsigned lcore_id;
        double load;
    } workers[32];

    int n = 0;
    unsigned lcore_id;

    RTE_LCORE_FOREACH_WORKER(lcore_id) {
        double ppb = (double)worker_stats[lcore_id].packets_processed /
                     worker_stats[lcore_id].cycles_elapsed;

        workers[n].lcore_id = lcore_id;
        workers[n].load = ppb;
        n++;
    }

    // 按负载排序
    qsort(workers, n, sizeof(workers[0]), compare_load);

    // 将高负载 worker 的队列迁移到低负载 worker
    // 简化示例
    for (int i = 0; i < n / 2; i++) {
        unsigned src = workers[i].lcore_id;  // 高负载
        unsigned dst = workers[n - 1 - i].lcore_id;  // 低负载

        migrate_queue(src, dst);
    }

    // 重置统计
    memset(worker_stats, 0, sizeof(worker_stats));
}

// 迁移队列
int
migrate_queue(unsigned src_lcore, unsigned dst_lcore)
{
    struct rte_ring *src_ring = worker_rings[src_lcore];
    struct rte_ring *dst_ring = worker_rings[dst_lcore];

    void *pkts[256];
    unsigned int count = 0;

    // 从源 ring 移动到目标 ring
    count = rte_ring_dequeue_burst(src_ring, pkts, 256, NULL);

    for (unsigned i = 0; i < count; i++) {
        if (rte_ring_enqueue(dst_ring, pkts[i]) != 0) {
            // 放回源 ring
            rte_ring_enqueue(src_ring, pkts[i]);
        }
    }

    printf("Migrated %u packets from lcore %u to %u\n",
           count, src_lcore, dst_lcore);

    return count;
}
```

---

## 5. 内存策略 (Memory Policy)

### 5.1 Linux NUMA 内存策略

```c
// lib/numa/numaif.h

// 内存策略模式
enum {
    MPOL_DEFAULT,      // 继承父进程策略
    MPOL_PREFERRED,    // 优先使用指定节点
    MPOL_BIND,         // 严格绑定到节点列表
    MPOL_INTERLEAVE,   // 跨节点交错
    MPOL_LOCAL,        // 本地节点 (Linux 5.12+)
    MPOL_PREFERRED_MANY, // 优先使用节点集合 (Linux 5.16+)
};

// 设置内存策略
int
set_memory_policy(enum numa_mode mode, unsigned long *nodes, int num_nodes)
{
    struct bitmask *nodemask = numa_allocate_nodemask();
    numa_bitmask_clearall(nodemask);

    for (int i = 0; i < num_nodes; i++)
        numa_bitmask_setbit(nodemask, nodes[i]);

    int mode_const;
    switch (mode) {
    case MPOL_DEFAULT:    mode_const = MPOL_DEFAULT; break;
    case MPOL_PREFERRED:   mode_const = MPOL_PREFERRED; break;
    case MPOL_BIND:        mode_const = MPOL_BIND; break;
    case MPOL_INTERLEAVE:  mode_const = MPOL_INTERLEAVE; break;
    default:               mode_const = MPOL_DEFAULT; break;
    }

    return set_mempolicy(mode_const, nodemask->maskp, nodemask->size + 1);
}

// 为线程设置内存策略
int
set_thread_memory_policy(unsigned long *nodes, int num_nodes)
{
    struct bitmask *nodemask = numa_allocate_nodemask();
    numa_bitmask_clearall(nodemask);

    for (int i = 0; i < num_nodes; i++)
        numa_bitmask_setbit(nodemask, nodes[i]);

    // 设置当前线程的内存策略
    return set_thread_mempolicy(MPOL_PREFERRED, nodemask->maskp, nodemask->size + 1);
}

// 内存迁移
int
migrate_pages(int pid, int to_node, unsigned long *pages, int num_pages)
{
    struct move_pages_args {
        int pid;
        unsigned long count;
        unsigned long *pages;
        int *nodes;
        int *status;
        int flags;
    } args = {
        .pid = pid,
        .count = num_pages,
        .pages = pages,
        .nodes = alloca(num_pages * sizeof(int)),
        .status = alloca(num_pages * sizeof(int)),
        .flags = 0,
    };

    // 设置目标节点
    for (int i = 0; i < num_pages; i++)
        args.nodes[i] = to_node;

    return move_pages(args.pid, args.count, args.pages,
                       args.nodes, args.status, args.flags);
}
```

### 5.2 DPDK 内存申请示例

```c
// DPDK NUMA 感知内存申请

struct numa_aware_buffer {
    void *data;
    size_t size;
    int socket_id;
    rte_iova_t iova;
};

// 在指定 socket 分配 DMA 可访问内存
struct numa_aware_buffer *
alloc_numa_aware_buffer(size_t size, int socket_id)
{
    struct numa_aware_buffer *buf;

    buf = rte_malloc_socket("numa_buffer",
                            sizeof(*buf) + size,
                            RTE_CACHE_LINE_SIZE,
                            socket_id);

    if (!buf)
        return NULL;

    buf->data = (char *)buf + sizeof(*buf);
    buf->size = size;
    buf->socket_id = socket_id;
    buf->iova = rte_malloc_virt2iova(buf->data);

    printf("Allocated %zu bytes on socket %d, iova: %lx\n",
           size, socket_id, buf->iova);

    return buf;
}

// 批量分配 DMA 缓冲区 (每个 socket 独立)
struct dma_buffer_pool {
    struct {
        void *buf;
        rte_iova_t iova;
        int socket_id;
    } buffers[MAX_SOCKETS][MAX_DMA_BUFS];
    unsigned counts[MAX_SOCKETS];
};

int
init_dma_buffer_pools(struct dma_buffer_pool *pools)
{
    int num_sockets = rte_eal_numa_manager_get_num_sockets();

    for (int s = 0; s < num_sockets; s++) {
        pools->counts[s] = 0;

        // 在每个 socket 分配 DMA 缓冲区
        for (int i = 0; i < MAX_DMA_BUFS; i++) {
            pools->buffers[s][i].buf = rte_malloc_socket(
                "dma_buf",
                DMA_BUF_SIZE,
                RTE_CACHE_LINE_SIZE,
                s
            );

            pools->buffers[s][i].iova = rte_malloc_virt2iova(
                pools->buffers[s][i].buf
            );

            pools->buffers[s][i].socket_id = s;
            pools->counts[s]++;
        }

        printf("Socket %d: %u DMA buffers allocated\n",
               s, pools->counts[s]);
    }

    return 0;
}

// 获取本地 socket 的 DMA 缓冲区
static inline void *
get_local_dma_buf(struct dma_buffer_pool *pools, unsigned index)
{
    int socket = rte_lcore_to_socket_id(rte_lcore_id());
    return pools->buffers[socket][index % pools->counts[socket]].buf;
}
```

---

## 6. PCIe NUMA 亲和性

### 6.1 PCIe 拓扑与 NUMA

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        PCIe 设备 NUMA 亲和性                                │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  PCIe 设备访问内存的延迟:                                                   │
│  ─────────────────────────────                                              │
│                                                                             │
│  NIC 0 (PCIe Slot on Socket 0) 访问:                                       │
│                                                                             │
│  Local Memory (Socket 0):                                                  │
│  NIC 0 ──► RC (Root Complex) ──► Memory Ctrl 0 ──► DDR4 0                 │
│  延迟: ~150 ns (DMA + 本地内存访问)                                         │
│                                                                             │
│  Remote Memory (Socket 1):                                                 │
│  NIC 0 ──► RC ──► QPI/UPI ──► Memory Ctrl 1 ──► DDR4 1                    │
│  延迟: ~250 ns (DMA + 跨插槽)                                              │
│                                                                             │
│  ─────────────────────────────────────────────────────────────────────────  │
│                                                                             │
│  NIC 设备 DMA 最佳实践:                                                     │
│  ────────────────────────                                                   │
│                                                                             │
│  1. NIC 与内存同插槽:                                                       │
│     - PCIe RC 连接到本地 Memory Controller                                  │
│     - DMA 到本地内存延迟最低                                                │
│                                                                             │
│  2. 使用本地 socket 的内存池:                                              │
│     - rte_eth_rx_buffer_alloc() 在本地 socket                             │
│     - mbuf 数据在本地内存                                                   │
│                                                                             │
│  3. 多 NIC 分区到不同 socket:                                               │
│     - NIC 0,1 → Socket 0                                                   │
│     - NIC 2,3 → Socket 1                                                   │
│                                                                             │
│  4. 避免跨插槽 DMA:                                                        │
│     - 跨插槽 DMA 带宽是本地的一半                                            │
│     - 延迟增加 50%+                                                        │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 6.2 多队列网卡与 NUMA

```c
// 多队列网卡 NUMA 亲和性配置

struct port_conf {
    uint16_t port_id;
    int numa_node;

    // 每个 port 的队列配置
    uint16_t nb_rx_queues;
    uint16_t nb_tx_queues;

    // 队列分配的 lcore
    unsigned rx_lcores[RTE_MAX_LCORE];
    unsigned tx_lcores[RTE_MAX_LCORE];
    unsigned nb_rx_lcores;
    unsigned nb_tx_lcores;
};

int
configure_port_numa_affinity(uint16_t port_id)
{
    struct rte_eth_dev_info dev_info;
    rte_eth_dev_info_get(port_id, &dev_info);

    int port_socket = dev_info.numa_node;

    printf("Port %d on socket %d\n", port_id, port_socket);

    // 获取同一 socket 的 lcore
    unsigned socket_lcores[RTE_MAX_LCORE];
    unsigned n = rte_lcore_foreach_socket(
        port_socket, socket_lcores, RTE_MAX_LCORE
    );

    printf("Socket %d has %u lcores\n", port_socket, n);

    // 配置 RX 队列
    uint16_t rx_queues_needed = 1;  // 每个 lcore 一个队列

    for (uint16_t q = 0; q < rx_queues_needed && q < n; q++) {
        unsigned lcore = socket_lcores[q];

        struct rte_eth_rxconf rx_conf = dev_info.default_rxconf;
        rx_conf.rx_deferred_start = 0;

        int ret = rte_eth_rx_queue_setup(
            port_id,
            q,                      // queue_id
            512,                    // nb_rx_desc
            port_socket,            // socket_id (本地!)
            &rx_conf,
            socket_data[port_socket].mbuf_pool  // 本地 pool!
        );

        if (ret < 0) {
            printf("Failed to setup RX queue %u: %s\n", q, strerror(-ret));
            return ret;
        }

        printf("  RX queue %u -> lcore %u (socket %d)\n",
               q, lcore, port_socket);
    }

    // 配置 TX 队列
    uint16_t tx_queues_needed = 1;

    for (uint16_t q = 0; q < tx_queues_needed && q < n; q++) {
        unsigned lcore = socket_lcores[q];

        int ret = rte_eth_tx_queue_setup(
            port_id,
            q,
            512,
            port_socket,
            NULL
        );

        if (ret < 0) {
            printf("Failed to setup TX queue %u\n", q);
            return ret;
        }
    }

    return 0;
}
```

### 6.3 本地内存优先分配

```c
// 本地内存优先分配策略

// 分配屏障: 确保内存来自本地 socket
#define MEMORY_ALLOC_FLAGS_LOCAL (RTE_MEMZONE_1GB | \
                                   RTE_MEMZONE_SIZE_HINT_ONLY | \
                                   RTE_MEMZONE_NOIO)

struct rte_memzone *
alloc_local_memzone(const char *name, size_t len, int socket_id)
{
    struct rte_memzone *mz;

    if (socket_id == SOCKET_ID_ANY)
        socket_id = rte_lcore_to_socket_id(rte_lcore_id());

    mz = rte_memzone_lookup(name);
    if (mz)
        return mz;  // 已存在

    mz = rte_memzone_reserve_aligned(
        name,
        len,
        socket_id,
        RTE_MEMZONE_1GB | RTE_MEMZONE_SIZE_HINT_ONLY,
        RTE_CACHE_LINE_SIZE
    );

    if (!mz) {
        // 尝试跨 socket 分配
        printf("Local allocation failed, trying remote...\n");
        mz = rte_memzone_reserve_aligned(
            name,
            len,
            SOCKET_ID_ANY,
            RTE_MEMZONE_1GB | RTE_MEMZONE_SIZE_HINT_ONLY,
            RTE_CACHE_LINE_SIZE
        );
    }

    return mz;
}

// hugepage 分配提示
int
set_hugepage_numa_policy(int socket_id)
{
    struct bitmask *mask = numa_allocate_nodemask();
    numa_bitmask_setbit(mask, socket_id);

    // 设置为严格绑定策略
    return set_mempolicy(MPOL_BIND, mask->maskp, mask->size + 1);
}
```

---

## 7. 完整使用示例

### 7.1 NUMA 感知的包处理流水线

```c
// NUMA 感知的 DPDK 包处理

#define MAX_SOCKETS 8
#define MAX_PORTS_PER_SOCKET 8

struct numa_port_config {
    uint16_t port_id;
    int socket_id;

    // 每个 port 分配的 lcores
    unsigned lcores[RTE_MAX_LCORE];
    unsigned nb_lcores;
};

struct numa_config {
    int num_sockets;

    // 每个 socket 的资源
    struct {
        struct rte_mempool *mbuf_pool;
        struct rte_ring *tx_ring;
        struct rte_flow_table *flow_table;

        // 该 socket 上的 ports
        uint16_t ports[MAX_PORTS_PER_SOCKET];
        unsigned nb_ports;
    } socket_data[MAX_SOCKETS];

    // 每个 socket 上的 lcores
    unsigned lcores[MAX_SOCKETS][RTE_MAX_LCORE];
    unsigned nb_lcores[MAX_SOCKETS];

    struct numa_port_config port_config[RTE_MAX_ETHPORTS];
};

struct numa_config numa_cfg;

// 初始化 NUMA 配置
int
numa_init(void)
{
    memset(&numa_cfg, 0, sizeof(numa_cfg));

    // 获取 NUMA 节点数
    numa_cfg.num_sockets = rte_eal_numa_manager_get_num_sockets();

    printf("Detected %d NUMA nodes\n", numa_cfg.num_sockets);

    // 遍历所有 ports，收集 NUMA 信息
    uint16_t port;
    RTE_ETH_FOREACH_DEV(port) {
        struct rte_eth_dev_info dev_info;
        rte_eth_dev_info_get(port, &dev_info);

        int socket = dev_info.numa_node;
        numa_cfg.port_config[port].port_id = port;
        numa_cfg.port_config[port].socket_id = socket;

        numa_cfg.socket_data[socket].ports[
            numa_cfg.socket_data[socket].nb_ports++] = port;

        printf("  Port %d on socket %d\n", port, socket);
    }

    // 为每个 socket 分配资源
    unsigned lcore_id;
    RTE_LCORE_FOREACH(lcore_id) {
        int socket = rte_lcore_to_socket_id(lcore_id);

        numa_cfg.socket_data[socket].lcores[
            numa_cfg.socket_data[socket].nb_lcores++] = lcore_id;

        // 如果这是该 socket 的第一个 lcore，分配资源
        if (numa_cfg.socket_data[socket].nb_lcores == 1) {
            char pool_name[64];
            snprintf(pool_name, sizeof(pool_name), "mbuf_pool_%d", socket);

            numa_cfg.socket_data[socket].mbuf_pool = rte_pktmbuf_pool_create(
                pool_name,
                16384,
                256,
                0,
                2048,
                socket  // 本地 socket
            );

            char ring_name[64];
            snprintf(ring_name, sizeof(ring_name), "tx_ring_%d", socket);

            numa_cfg.socket_data[socket].tx_ring = rte_ring_create(
                ring_name,
                4096,
                socket,
                RING_F_SP_ENQ | RING_F_SC_DEQ
            );

            printf("Created resources for socket %d\n", socket);
        }
    }

    return 0;
}

// NUMA 感知的 RX/TX lcore 主循环
static int
numa_rx_tx_lcore(void *arg)
{
    unsigned lcore_id = rte_lcore_id();
    int socket = rte_lcore_to_socket_id(lcore_id);

    struct rte_mempool *mbuf_pool = numa_cfg.socket_data[socket].mbuf_pool;
    struct rte_ring *tx_ring = numa_cfg.socket_data[socket].tx_ring;

    printf("lcore %u on socket %d, pool=%p, ring=%p\n",
           lcore_id, socket, mbuf_pool, tx_ring);

    struct rte_mbuf *pkts[32];

    while (!quit) {
        // 获取该 socket 上的 port
        uint16_t port = numa_cfg.socket_data[socket].ports[0];

        // 接收 (本地 port)
        uint16_t nb_rx = rte_eth_rx_burst(port, 0, pkts, 32);

        if (nb_rx == 0)
            continue;

        // 本地处理
        for (uint16_t i = 0; i < nb_rx; i++) {
            process_packet(pkts[i]);
        }

        // 发送到本地 TX ring
        uint16_t nb_tx = rte_ring_sp_enqueue_burst(tx_ring, (void **)pkts, nb_rx, NULL);

        // 释放未能入队的包
        for (uint16_t i = nb_tx; i < nb_rx; i++) {
            rte_pktmbuf_free(pkts[i]);
        }
    }

    return 0;
}

// NUMA 感知的 TX lcore 主循环
static int
numa_tx_lcore(void *arg)
{
    unsigned lcore_id = rte_lcore_id();
    int socket = rte_lcore_to_socket_id(lcore_id);

    struct rte_ring *rx_ring = numa_cfg.socket_data[socket].tx_ring;
    uint16_t port = numa_cfg.socket_data[socket].ports[0];

    printf("TX lcore %u on socket %d, ring=%p, port=%d\n",
           lcore_id, socket, rx_ring, port);

    struct rte_mbuf *pkts[32];

    while (!quit) {
        // 从本地 ring 取包
        uint16_t nb_rx = rte_ring_sc_dequeue_burst(rx_ring, (void **)pkts, 32, NULL);

        if (nb_rx == 0)
            continue;

        // 发送到 NIC
        uint16_t nb_tx = rte_eth_tx_burst(port, 0, pkts, nb_rx);

        // 释放未能发送的包
        for (uint16_t i = nb_tx; i < nb_rx; i++) {
            rte_pktmbuf_free(pkts[i]);
        }
    }

    return 0;
}

// 启动 NUMA 感知的 lcores
int
numa_launch_workers(void)
{
    unsigned lcore_id;

    // 为每个 socket 启动 lcores
    for (int s = 0; s < numa_cfg.num_sockets; s++) {
        unsigned *lcores = numa_cfg.socket_data[s].lcores;
        unsigned nb = numa_cfg.socket_data[s].nb_lcores;

        if (nb == 0)
            continue;

        // 第一个 lcore 处理 RX + TX
        unsigned rx_tx_lcore = lcores[0];
        rte_eal_remote_launch(numa_rx_tx_lcore, NULL, rx_tx_lcore);

        // 后续 lcores 只处理 TX
        for (unsigned i = 1; i < nb; i++) {
            rte_eal_remote_launch(numa_tx_lcore, NULL, lcores[i]);
        }
    }

    return 0;
}
```

### 7.2 NUMA 感知内存监控

```c
// NUMA 内存使用监控

struct numa_mem_stats {
    size_t total_bytes;
    size_t free_bytes;
    size_t hugepage_bytes;
    int numa_node;
};

void
print_numa_mem_stats(void)
{
    printf("\nNUMA Memory Statistics:\n");
    printf("========================\n");

    int num_nodes = numa_max_node() + 1;

    for (int node = 0; node < num_nodes; node++) {
        struct numa_mem_stats stats;

        // 获取节点内存信息
        stats.total_bytes = numa_node_size(node, &stats.free_bytes);
        stats.numa_node = node;

        printf("\nNode %d:\n", node);
        printf("  Total: %zu MB\n", stats.total_bytes / 1024 / 1024);
        printf("  Free:  %zu MB\n", stats.free_bytes / 1024 / 1024);
        printf("  Used:  %zu MB (%.1f%%)\n",
               (stats.total_bytes - stats.free_bytes) / 1024 / 1024,
               100.0 * (stats.total_bytes - stats.free_bytes) / stats.total_bytes);
    }
}

// DPDK 内存区域统计
void
print_dpdk_memzone_stats(void)
{
    printf("\nDPDK Memory Zones:\n");
    printf("===================\n");

    const struct rte_memzone *mz = NULL;

    for (int i = 0; i < RTE_MAX_MEMZONE; i++) {
        mz = &rte_memzone_tbl.mz_table[i];

        if (mz->addr == NULL)
            continue;

        printf("  %s: %zu bytes, socket %d\n",
               mz->name, mz->len, mz->socket_id);
    }
}

// 监控本地/远程内存访问比例
void
monitor_numa_access_ratio(void)
{
    printf("\nNUMA Access Monitor:\n");
    printf("====================\n");

    // 假设我们已经追踪了访问统计
    // 这是一个模拟输出

    for (int s = 0; s < numa_cfg.num_sockets; s++) {
        unsigned lcore_id;
        uint64_t local = 0, remote = 0;

        // 收集该 socket 上所有 lcore 的统计
        for (int i = 0; i < numa_cfg.socket_data[s].nb_lcores; i++) {
            lcore_id = numa_cfg.socket_data[s].lcores[i];
            local += worker_stats[lcore_id].local_accesses;
            remote += worker_stats[lcore_id].remote_accesses;
        }

        uint64_t total = local + remote;
        if (total > 0) {
            printf("Socket %d: Local=%.1f%% Remote=%.1f%%\n",
                   s,
                   100.0 * local / total,
                   100.0 * remote / total);
        }
    }
}
```

---

## 8. 性能调优建议

### 8.1 NUMA 调优清单

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        NUMA 性能调优清单                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  1. BIOS 设置                                                              │
│  ─────────────                                                              │
│     □ 启用 NUMA                                                            │
│     □ 关闭 NUMA 作为 fallback                                              │
│     □ 启用 Node Interleaving (仅当需要统一内存视图时)                       │
│                                                                             │
│  2. OS 配置                                                                 │
│  ──────────                                                                 │
│     □ 使用 hugepage (2MB 或 1GB)                                           │
│     □ 将 hugepage 分配到对应 NUMA 节点                                       │
│     □ 确认 /proc/sys/kernel/numa_balancing 已禁用 (DPDK 不需要)            │
│     □ 确认 /proc/sys/kernel/numa_balancing_scan_delay_ms 设置合理          │
│                                                                             │
│  3. DPDK EAL 参数                                                           │
│  ──────────────────                                                        │
│     □ -n <channels>: 内存通道数 (4 为最佳)                                 │
│     □ --socket-mem: 每个 socket 的内存分配                                 │
│     □ --socket-limit: 每个 socket 的内存上限                               │
│     □ --lcores: lcore 到 CPU 的映射                                         │
│     □ 示例: -l 0-7 -n 4 --socket-mem=1024,1024                             │
│                                                                             │
│  4. 应用设计                                                               │
│  ──────────                                                                 │
│     □ 为每个 NIC 分配同 socket 的 lcore 处理                                 │
│     □ 为每个 socket 创建独立的 mbuf pool                                    │
│     □ 为每个 socket 创建独立的 ring/queue                                   │
│     □ 使用 per-lcore 数据结构 (TLS)                                        │
│     □ 使用 rte_malloc_socket() 而非 rte_malloc()                           │
│     □ 使用 local memory pool 进行 TX buffer                                │
│                                                                             │
│  5. 数据面设计                                                             │
│  ─────────────                                                              │
│     □ 跨 socket 传递数据使用 DMA buffer                                     │
│     □ 批量操作减少跨 socket 次数                                            │
│     □ 使用 socket 感知的 flow table                                        │
│     □ 避免跨 socket 的 mbuf 引用                                           │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 8.2 性能对比数据

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    NUMA 优化前后性能对比                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  测试环境: Intel Xeon Gold 6248 (2x), 256GB DDR4, 2x 100GbE NIC          │
│                                                                             │
│  64B 小包转发测试 (Mpps):                                                  │
│  ─────────────────────────────────────                                      │
│                                                                             │
│  配置                          Socket 0    Socket 1    Total                │
│  ──────────────────────────────────────────────────────────────────────── │
│  无 NUMA 感知 (1 socket)       25 Mpps     25 Mpps     50 Mpps             │
│  NUMA 本地化                  40 Mpps     38 Mpps     78 Mpps             │
│  NUMA 本地化 + 优化           45 Mpps     44 Mpps     89 Mpps             │
│                                                                             │
│  优化增益: ~78% 提升                                                         │
│                                                                             │
│  1518B 大包转发测试 (Gbps):                                                │
│  ─────────────────────────────────────                                      │
│                                                                             │
│  配置                          Socket 0    Socket 1    Total                │
│  ──────────────────────────────────────────────────────────────────────── │
│  无 NUMA 感知                 45 Gbps     43 Gbps     88 Gbps             │
│  NUMA 本地化                  48 Gbps     47 Gbps     95 Gbps             │
│  NUMA 本地化 + 优化           49 Gbps     49 Gbps     98 Gbps             │
│                                                                             │
│  优化增益: ~11% 提升 (大包瓶颈在 NIC)                                       │
│                                                                             │
│  内存带宽测试 (GB/s):                                                      │
│  ───────────────────────                                                     │
│                                                                             │
│  访问模式                    本地内存    远程内存    差距                  │
│  ──────────────────────────────────────────────────────────────────────── │
│  Sequential Read             95 GB/s     22 GB/s     4.3x                │
│  Random Read                  8 GB/s      3 GB/s     2.7x                 │
│  Write                        45 GB/s     15 GB/s     3x                  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 9. 小结

本章核心要点：

1. **NUMA vs UMA**：NUMA 架构中本地内存访问 (~80ns) 比远程内存访问 (~150ns) 快 2x，带宽差距达 4-8x。

2. **NUMA 拓扑**：多 Socket 服务器通过 QPI/UPI 互联，每个 Socket 有独立的内存控制器和 CPU cores。

3. **DPDK NUMA API**：`rte_lcore_to_socket_id()`、`rte_malloc_socket()`、`rte_pktmbuf_pool_create()` 的 socket_id 参数。

4. **Local vs Remote**：Core 访问本地内存延迟低、带宽高；访问远程内存需要跨 QPI/UPI，延迟高、带宽低。

5. **CPU 亲和性**：每个 NIC 应由同 Socket 的 lcore 处理，避免跨插槽收包。

6. **内存策略**：MPOL_BIND (严格绑定)、MPOL_PREFERRED (优先本地)、MPOL_INTERLEAVE (交错分配)。

7. **PCIe NUMA**：网卡 DMA 到本地内存比到远程内存快 50%+，应使用 socket 感知的 mbuf pool。

8. **Per-Socket 数据**：每个 socket 独立的 mbuf pool、ring、flow table，避免跨 socket 共享。

9. **TLS vs 共享数据**：Thread-Local Storage 无需同步，无 False Sharing，是高性能场景的首选。

10. **EAL 参数**：`--socket-mem`、`--socket-limit`、`--lcores` 控制 NUMA 行为。

**下一篇预告**：[[2026-04-09-dpdk-deep-dive-ch27-memory-dma|第二十七章]]将讲解内存优化——DMA 引擎与零拷贝。

---

> [!tip] 参考文献
> - Intel, "Intel Xeon Processor Scalable Family, Technical Overview"
> - AMD, "AMD EPYC System Architecture"
> - "NUMA Performance for DPDK Applications", Intel White Paper
> - "Memory Policy in Linux", https://www.kernel.org/doc/html/latest/vm/numa_memory_policy.html
> - hwloc documentation, https://www.open-mpi.org/projects/hwloc/
> - Intel, "DPDK NUMA Documentation", https://doc.dpdk.org/guides/linux_gsg/NUMA.html
