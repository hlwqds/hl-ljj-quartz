---
title: "RDMA 第二十三章：内存优化——DMA、注册与缓存效率"
date: 2026-04-13
tags: [rdma, memory, dma, hugepage, mmu, cache, registration, lkey, rkey]
description: "详解 RDMA 内存优化：内存注册机制、DMA 引擎、hugepage 配置、MMU/IOMMU 影响、lkey/rkey 查找优化、cache 效率、内存带宽与 NUMA。"
---

> [!abstract] 核心要点
> RDMA 依赖高效的内存访问——HCA 通过 DMA 直接读写已注册内存。本章深入分析内存注册、DMA 引擎工作原理、hugepage 配置、IOMMU 影响、以及如何优化 lkey/rkey 查找和缓存效率，实现零拷贝数据路径。

---

## 1. RDMA 内存架构

### 1.1 为什么需要内存注册

```
RDMA 内存注册 (Memory Registration):

  ┌─────────────────────────────────────────────────────────────────────────────┐
  │  未注册内存                                                                  │
  │  ┌───────────────────────────────────────────────────────────────────────┐  │
  │  │                                                                         │  │
  │  │   应用虚拟地址空间                                                      │  │
  │  │   ┌─────────┐  ┌─────────┐  ┌─────────┐                             │  │
  │  │   │ malloc  │  │ malloc  │  │ malloc  │  物理地址不连续!              │  │
  │  │   │ 0x7f... │  │ 0x7a... │  │ 0x72... │  无法 DMA!                    │  │
  │  │   └─────────┘  └─────────┘  └─────────┘                               │  │
  │  │                                                                         │  │
  │  └───────────────────────────────────────────────────────────────────────┘  │
  └─────────────────────────────────────────────────────────────────────────────┘

  ┌─────────────────────────────────────────────────────────────────────────────┐
  │  注册后内存                                                                  │
  │  ┌───────────────────────────────────────────────────────────────────────┐  │
  │  │                                                                         │  │
  │  │   RDMA 内存区域 (Memory Region)                                        │  │
  │  │   ┌───────────────────────────────────────────────┐                   │  │
  │  │   │  物理连续的大块内存 (hugepage 或连续分配)      │                   │  │
  │  │   │  lkey/rkey 绑定到此区域                         │                   │  │
  │  │   │  DMA 可以安全访问                               │                   │  │
  │  │   └───────────────────────────────────────────────┘                   │  │
  │  │                                                                         │  │
  │  │   虚拟地址  0x7f...─────────────┐                                      │  │
  │  │                                 ↓                                      │  │
  │  │   物理地址  0x10000000 ───────────────────► HCA 可以访问                 │  │
  │  │                                 │                                      │  │
  │  │   虚拟地址  0x7a...─────► N/A (不可访问)                                 │  │
  │  │                                                                         │  │
  │  └───────────────────────────────────────────────────────────────────────┘  │
  └─────────────────────────────────────────────────────────────────────────────┘
```

### 1.2 内存注册过程

```c
// 内存注册流程
struct ibv_mr *mr;
struct ibv_pd *pd;

// 1. 分配大块、对齐内存
void *buf = memalign(4096, MR_SIZE);  // 4KB 对齐

// 2. 注册内存区域
mr = ibv_reg_mr(pd,                    // Protection Domain
                buf,                   // 虚拟地址
                MR_SIZE,               // 长度
                IBV_ACCESS_LOCAL_WRITE |   // 本地写权限
                IBV_ACCESS_REMOTE_WRITE |  // 远端写权限
                IBV_ACCESS_REMOTE_READ);   // 远端读权限

// 3. 获取 lkey 和 rkey
printf("lkey = 0x%x, rkey = 0x%x\n", mr->lkey, mr->rkey);

// 4. 在 WQE 中使用
struct ibv_sge sge = {
    .addr = (uintptr_t)buf,
    .length = MR_SIZE,
    .lkey = mr->lkey  // 使用注册的 key
};
```

### 1.3 内存注册开销

```
内存注册成本:

  ibv_reg_mr() 开销:
    - 系统调用 (可能数百微秒)
    - 更新 IOMMU 页表
    - 分配内部数据结构
    - 通知 HCA

  建议:
    - 预先注册大内存区域
    - 运行时避免频繁注册/注销
    - 复用已注册的 MR

  反面例子:
    for (int i = 0; i < 1000000; i++) {
        void *small = malloc(64);
        mr = ibv_reg_mr(pd, small, 64, ...);  // 每次都有大开销!
        ibv_dereg_mr(mr);
        free(small);
    }

  正面例子:
    mr = ibv_reg_mr(pd, large_buf, BIG_SIZE, ...);  // 一次注册
    for (int i = 0; i < 1000000; i++) {
        // 使用 mr 复用
    }
```

---

## 2. DMA 引擎

### 2.1 DMA 工作原理

```
DMA (Direct Memory Access) 流程:

  ┌──────────────────────────────────────────────────────────────────────────────┐
  │  HCA DMA 引擎                                                                │
  │                                                                              │
  │   应用缓冲区                                                                  │
  │   ┌──────────────────────────────────────────────────────────────────────┐    │
  │   │  buf[] = {data};                                                      │    │
  │   └──────────────────────────────────────────────────────────────────────┘    │
  │           │                                                                   │
  │           │ WQE 提交 (ibv_post_send)                                         │
  │           ↓                                                                   │
  │   ┌─────────────────┐                                                       │
  │   │   HCA DMA 引擎   │  ← 读取 SGE，获取 addr/lkey                          │
  │   │                   │  ← 使用 lkey 验证权限                                │
  │   │  DMA read:        │  ← 从系统内存读取数据                                │
  │   │    buf → TX FIFO  │                                                      │
  │   └─────────────────┘                                                       │
  │           │                                                                   │
  │           │ PCIe 传输                                                        │
  │           ↓                                                                   │
  │   ┌─────────────────┐                                                       │
  │   │   Network        │  ← 发送到网络                                          │
  │   └─────────────────┘                                                       │
  │                                                                              │
  └──────────────────────────────────────────────────────────────────────────────┘

  关键点:
    - DMA 操作无需 CPU 介入
    - HCA 直接访问物理内存
    - 需要物理连续的内存区域
```

### 2.2 IOMMU 的影响

```
IOMMU (Input-Output Memory Management Unit):

  无 IOMMU (传统):
  ┌──────────────────────────────────────────────────────────────────────┐
  │  HCA 直接访问物理地址                                                  │
  │  ┌────────────┐         ┌────────────────────┐                      │
  │  │   HCA      │  ────►  │  Physical Memory   │                      │
  │  │            │  PA     │  任何物理地址       │                      │
  │  └────────────┘         └────────────────────┘                      │
  │                                                                         │
  │  优点: 简单、低延迟                                                      │
  │  缺点: 安全风险 (HCA 可以访问任何物理内存)                               │
  └──────────────────────────────────────────────────────────────────────┘

  有 IOMMU (现代服务器):
  ┌──────────────────────────────────────────────────────────────────────┐
  │  HCA 通过 IOMMU 访问                                                    │
  │  ┌────────────┐         ┌────────────────────┐                      │
  │  │   HCA      │  ────►  │     IOMMU         │  ────►  Physical     │
  │  │            │  IOVA   │  (VT-d, AMD-Vi)   │       Memory        │
  │  └────────────┘         └────────────────────┘                      │
  │                                                                         │
  │  优点: 安全隔离、支持虚拟化                                              │
  │  缺点: 地址转换开销 (~10-50 ns)                                         │
  └──────────────────────────────────────────────────────────────────────┘

  对 RDMA 的影响:
    - 每次 DMA 需要 IOMMU 查询
    - 可通过禁用 IOMMU 或使用 passthrough 优化
```

### 2.3 IOMMU 配置与优化

```bash
# 检查 IOMMU 状态
$ dmesg | grep -e "DMAR" -e "IOMMU"
[    0.123456] DMAR: IOMMU enabled

# 检查是否启用
$ cat /proc/cmdline | grep iommu
intel_iommu=on iommu=pt

# iommu=pt (passthrough) 优化:
#   - 虚拟机使用 IOMMU passthrough
#   - 减少地址转换开销
#   - 仍保持安全隔离

# 完全禁用 (不推荐，生产环境有安全风险)
# 在 grub cmdline: intel_iommu=off

# VFIO IOMMU 优化
$ modprobe vfio
$ modprobe vfio_iommu_type1
```

---

## 3. HugePages

### 3.1 为什么使用 HugePages

```
标准页面 vs HugePages:

  标准页面 (4KB):
    - 大部分 Linux 系统的默认页面大小
    - 16K 页表项 / GB 内存
    - TLB Miss 频繁
    - 内存碎片

  HugePages (2MB 或 1GB):
    - 更大的页面大小
    - TLB 条目更少
    - 减少 TLB Miss
    - 适合大内存 RDMA 应用

  TLB Miss 开销:
    - L1 TLB miss: ~4 cycles
    - L2 TLB miss: ~10 cycles
    - Page walk:   ~100-200 cycles

  示例:
    注册 128GB 内存:
      4KB 页面: 需要 32M 页表项，TLB 无法容纳
      2MB HugePage: 需要 64K 页表项，大幅减少
```

### 3.2 配置 HugePages

```bash
# 查看当前 hugepage 配置
$ cat /proc/meminfo | grep -i huge
AnonHugePages:         0 kB
ShmemHugePages:        0 kB
HugePages_Total:       64
HugePages_Free:        64
HugePages_Rsvd:        0
HugePages_Surp:        0
Hugepagesize:       2048 kB

# 配置 64 个 2MB hugepages (共 128MB)
$ echo 64 > /proc/sys/vm/nr_hugepages

# 配置 16 个 1GB hugepages (需要 1GB 页支持)
# echo 16 > /proc/sys/vm/nr_hugepages
# mount -t hugetlbfs hugetlbfs /mnt/huge

# 持久化配置 (/etc/sysctl.conf)
# vm.nr_hugepages = 64

# 验证
$ cat /proc/meminfo | grep -i huge
HugePages_Total:       64
HugePages_Free:        64
Hugepagesize:       2048 kB
```

### 3.3 使用 HugePages 分配内存

```c
// 方法 1: 使用 posix_memalign (推荐)
#define PAGE_SIZE (2 * 1024 * 1024)  // 2MB
void *buf;
posix_memalign(&buf, PAGE_SIZE, MR_SIZE);

// 方法 2: 使用 mmap /dev/hugepages
int fd = open("/dev/hugepages", O_RDWR);
void *buf = mmap(NULL, MR_SIZE, PROT_READ | PROT_WRITE,
                MAP_PRIVATE | MAP_ANONYMOUS, fd, 0);

// 方法 3: 使用 shmget (System V 共享内存)
key_t key = ftok("/dev/null", 1);
int shmid = shmget(key, MR_SIZE, IPC_CREAT | SHM_HUGETLB | 0666);
void *buf = shmat(shmid, NULL, 0);

// 方法 4: 直接使用 hugepage 文件系统
mkdir -p /mnt/huge
mount -t hugetlbfs none /mnt/huge
void *buf = mmap(NULL, MR_SIZE, PROT_READ | PROT_WRITE,
                MAP_PRIVATE, fd, 0);

// 注册为 RDMA 内存
struct ibv_mr *mr = ibv_reg_mr(pd, buf, MR_SIZE,
                               IBV_ACCESS_LOCAL_WRITE |
                               IBV_ACCESS_REMOTE_WRITE);
```

### 3.4 transparent_hugepage

```bash
# 检查 transparent hugepage 状态
$ cat /sys/kernel/mm/transparent_hugepage/enabled
[always] madvise never

# transparent_hugepage 的问题:
#   - 内存可能随时被拆分
#   - 影响内存注册的稳定性
#   - 对 RDMA 不友好

# 推荐配置: madvise 或 never
$ echo madvise > /sys/kernel/mm/transparent_hugepage/enabled
$ echo madvise > /sys/kernel/mm/transparent_hugepage/defrag

# 禁用 (最稳定但最浪费内存)
$ echo never > /sys/kernel/mm/transparent_hugepage/enabled
```

---

## 4. lkey/rkey 查找优化

### 4.1 lkey/rkey 查找过程

```
lkey/rkey 查找流程:

  WQE 提交时:
  ┌──────────────────────────────────────────────────────────────────────────┐
  │                                                                           │
  │  1. 应用构造 SGE: {addr, length, lkey}                                    │
  │                                                                           │
  │  2. HCA 验证 lkey:                                                        │
  │     - 遍历已注册的 MR 表                                                   │
  │     - 比较 lkey 值                                                        │
  │     - 验证访问权限                                                        │
  │                                                                           │
  │  3. 如果找到匹配的 MR:                                                    │
  │     - 获取物理地址 (VA → PA)                                              │
  │     - 执行 DMA                                                            │
  │                                                                           │
  │  4. 如果未找到:                                                           │
  │     - CQE 报告错误 (IBV_WC_LOC_QP_OP_ERR)                                │
  │                                                                           │
  └──────────────────────────────────────────────────────────────────────────┘

  查找复杂度: O(n) 遍历当前 PD 的 MR 列表
  优化: 保持较少的 MR，或使用 MR 缓存
```

### 4.2 MR 缓存

```c
// Mellanox HCA 支持 MR 缓存 (LLC 缓存 lkey/rkey)
// 检查是否启用
$ cat /sys/class/infiniband/mlx5_0/params/mr_cache
name             size         current     max
MLX5_MSIC_MR     512          100         512

# 当 MR 数量超过缓存大小时:
#   - 新的 MR 查找变慢
#   - 可能触发缓存驱逐

// 最佳实践: 保持 MR 数量 < 缓存大小
// 通常每个进程 100-500 个 MR 足够
```

### 4.3 减少 lkey/rkey 查找开销

```c
// 策略 1: 使用单个大 MR
#define MR_SIZE (1UL << 30)  // 1GB
void *buf = allocate_1gb();
mr = ibv_reg_mr(pd, buf, MR_SIZE, ...);  // 单个 MR 覆盖所有内存

// 策略 2: 批量使用相同 MR
struct ibv_mr *shared_mr = ibv_reg_mr(pd, shared_buf, SHARED_SIZE, ...);

for (int i = 0; i < 1000; i++) {
    // 所有操作使用同一个 lkey
    struct ibv_sge sge = {
        .addr = (uintptr_t)(shared_buf + i * ELEMENT_SIZE),
        .length = ELEMENT_SIZE,
        .lkey = shared_mr->lkey
    };
    // ...
}

// 策略 3: 避免频繁创建/销毁 MR
// 预分配固定数量的 MR 池
struct mr_pool {
    struct ibv_mr *mrs[MAX_MRS];
    int count;
};

struct mr_pool *create_mr_pool(struct ibv_pd *pd, int max_mrs) {
    struct mr_pool *pool = calloc(1, sizeof(*pool));

    for (int i = 0; i < max_mrs; i++) {
        void *buf = memalign(4096, MR_SIZE);
        pool->mrs[i] = ibv_reg_mr(pd, buf, MR_SIZE,
                                 IBV_ACCESS_LOCAL_WRITE);
    }
    pool->count = max_mrs;
    return pool;
}
```

---

## 5. NUMA 与内存带宽

### 5.1 内存带宽瓶颈

```
内存带宽限制:

  现代 CPU 内存带宽:
    - DDR4-3200 4通道: ~100 GB/s
    - DDR5-4800 4通道: ~150 GB/s

  RDMA 操作消耗内存带宽:
    - DMA 读: HCA 从内存读取
    - DMA 写: HCA 写入内存

  全双工 100Gbps RDMA:
    - 理论需求: 12.5 GB/s × 2 = 25 GB/s
    - 占 DDR4 4通道的 25%
    - 通常不是瓶颈

  但在高带宽 (400Gbps+) 或多流时:
    - 内存带宽可能成为瓶颈
    - NUMA 配置影响显著
```

### 5.2 NUMA 内存分配策略

```bash
#!/bin/bash
# 查看内存带宽
$ dmidecode -t memory | grep -E "Speed|Type"
$ numactl --hardware

# 查看当前内存带宽
$ while true; do
    awk '/^Node/ {node=$2} /MemBand/ {print "Node"node": "$2" MB/s"}' \
        /proc/12345/numa_meminfo 2>/dev/null || true
    sleep 1
  done
```

```c
// NUMA 感知内存分配
#include <numa.h>

void *numa_alloc_local(size_t size) {
    int node = numa_node_of_cpu(sched_getcpu());  // 当前 CPU 的 NUMA
    return numa_alloc_onnode(size, node);
}

// 分配在 HCA 所在 NUMA
void *alloc_for_hca(const char *device, size_t size) {
    char path[256];
    int hca_node;

    // 获取 HCA 的 NUMA 节点
    snprintf(path, sizeof(path),
             "/sys/class/infiniband/%s/device/numa_node", device);
    FILE *f = fopen(path, "r");
    if (!f) return NULL;
    fscanf(f, "%d", &hca_node);
    fclose(f);

    // 在 HCA 所在节点分配
    return numa_alloc_onnode(size, hca_node);
}

// numactl 命令行方式
// numactl --membind=0 --localalloc ./rdma_app
```

---

## 6. 内存对齐与 DMA 对齐

### 6.1 对齐要求

```
RDMA 内存对齐要求:

  最小对齐:
    - IB 标准: 1 byte (基本)
    - HCA 通常要求: 4 bytes 或更高
    - 最佳实践: 64 bytes (Cache line 对齐)

  DMA 对齐优化:
    - 未对齐的访问触发多次 DMA 传输
    - 对齐访问更高效

  示例:
    64B 对齐: DMA 一次完成
    1B 对齐:  DMA 可能需要多次传输
```

### 6.2 对齐的内存分配

```c
// 对齐的内存分配
#define ALIGNMENT 64

void *aligned_alloc_1m(size_t size) {
    void *buf;

    // 64 字节对齐
    if (posix_memalign(&buf, ALIGNMENT, size) != 0) {
        return NULL;
    }

    return buf;
}

// 验证对齐
void check_alignment(void *ptr) {
    printf("Pointer: %p, Alignment: %ld\n",
           ptr, (uintptr_t)ptr % ALIGNMENT);
}

// 使用 SSE/AVX 优化内存访问
#include <immintrin.h>

void memcpy_avx(void *dst, const void *src, size_t size) {
    __m256i *d = (__m256i *)dst;
    __m256i *s = (__m256i *)src;
    size_t count = size / sizeof(__m256i);

    for (size_t i = 0; i < count; i++) {
        _mm256_store_si256(&d[i], _mm256_load_si256(&s[i]));
    }
}
```

---

## 7. 内存注册最佳实践

### 7.1 预注册策略

```c
// 预注册大内存池
struct mr_pool {
    struct ibv_mr *mr;
    void *buf;
    size_t size;
};

struct mr_pool *create_mr_pool(struct ibv_pd *pd, size_t per_mr_size,
                                int num_mrs) {
    struct mr_pool *pool = malloc(sizeof(*pool) * num_mrs);

    for (int i = 0; i < num_mrs; i++) {
        // 分配对齐内存
        if (posix_memalign(&pool[i].buf, 2097152, per_mr_size) != 0) {
            // 处理错误
        }

        // 预注册
        pool[i].mr = ibv_reg_mr(pd, pool[i].buf, per_mr_size,
                                IBV_ACCESS_LOCAL_WRITE |
                                IBV_ACCESS_REMOTE_WRITE |
                                IBV_ACCESS_REMOTE_READ);
        pool[i].size = per_mr_size;
    }

    return pool;
}

// 使用池中的 MR
struct ibv_mr *get_mr(struct mr_pool *pool, int idx) {
    return pool[idx].mr;
}

// 销毁池
void destroy_mr_pool(struct mr_pool *pool, int num_mrs) {
    for (int i = 0; i < num_mrs; i++) {
        ibv_dereg_mr(pool[i].mr);
        free(pool[i].buf);
    }
    free(pool);
}
```

### 7.2 注册标志位

```c
// IBV_ACCESS_* 标志位组合

// 基本组合 (本地应用)
mr = ibv_reg_mr(pd, buf, size,
                IBV_ACCESS_LOCAL_WRITE);

// RDMA Read 权限
mr = ibv_reg_mr(pd, buf, size,
                IBV_ACCESS_LOCAL_WRITE |
                IBV_ACCESS_REMOTE_READ);

// RDMA Write 权限
mr = ibv_reg_mr(pd, buf, size,
                IBV_ACCESS_LOCAL_WRITE |
                IBV_ACCESS_REMOTE_WRITE);

// 完全权限
mr = ibv_reg_mr(pd, buf, size,
                IBV_ACCESS_LOCAL_WRITE |
                IBV_ACCESS_REMOTE_WRITE |
                IBV_ACCESS_REMOTE_READ |
                IBV_ACCESS_MW_BIND);  // Memory Window

// 零拷贝发送 (需要远端读取权限)
mr = ibv_reg_mr(pd, buf, size,
                IBV_ACCESS_LOCAL_WRITE |
                IBV_ACCESS_REMOTE_READ);  // 发送后远端可读

// 注意: 权限越少越好，减少安全风险
```

---

## 8. 内存效率监控

### 8.1 监控工具

```bash
# 查看内存注册状态
$ ibv_devinfo -v -d mlx5_0 | grep -E "max_mr|mr_lkey"
  max_mr:     16777216
  max_mr_size: 0xffffffffffffffff
  max_lkey:   0xffffffff
  max_rkey:   0xffffffff

# 查看当前注册的 MR 数量
$ cat /sys/class/infiniband/mlx5_0/ports/1/mr_table_size

# 查看 DMA 引擎状态 (Mellanox)
$ mstflint -d mlx5_0 qos where

# 查看内存带宽
$ perf stat -e uncore_imc_0/cas_count_read/,uncore_imc_0/cas_count_write/ \
    -a ./rdma_app
```

### 8.2 内存压力测试

```c
// 内存带宽测试
#include <stdio.h>
#include <string.h>
#include <emmintrin.h>

#define SIZE (128 * 1024 * 1024)  // 128MB

void bandwidth_test(char *buf) {
    uint64_t start, end;
    double time_sec;
    double bw_gbps;

    // 写带宽测试
    memset(buf, 0xFF, SIZE);

    start = __rdtsc();
    for (int i = 0; i < 1000; i++) {
        for (size_t j = 0; j < SIZE; j += 64) {
            _mm_store_si128((__m128i *)(buf + j),
                           _mm_set1_epi32(i));
        }
    }
    end = __rdtsc();

    // 计算带宽
    size_t total_bytes = SIZE * 1000ULL;
    time_sec = (end - start) / 2.9e9;  // 假设 2.9 GHz
    bw_gbps = (total_bytes / 1e9) / time_sec;

    printf("Memory bandwidth: %.2f GB/s\n", bw_gbps);
}
```

---

## 9. 常见内存问题

### 9.1 问题排查

| 问题 | 症状 | 解决方案 |
|------|------|---------|
| MR 注册失败 | ibv_reg_mr 返回 NULL | 增加 hugepages；检查权限 |
| lkey 错误 | CQE status = LOC_QP_OP_ERR | 验证 lkey 正确 |
| DMA 错误 | 传输数据不正确 | 检查对齐；验证内存已注册 |
| 内存不足 | ENOMEM | 增加 hugepages；减少 MR 数量 |
| 性能下降 | 带宽低于预期 | 检查 NUMA；使用 hugepages |

### 9.2 内存优化 checklist

```
RDMA 内存优化要点:

  [ ] 内存注册
  [ ]   - 预注册大内存区域
  [ ]   - 使用 hugepages (2MB 或 1GB)
  [ ]   - 减少 MR 数量 (< 缓存大小)
  [ ]   - 复用已注册的 MR
  [ ]
  [ ] 对齐
  [ ]   - 64 字节对齐 (cache line)
  [ ]   - DMA 对齐访问
  [ ]
  [ ] NUMA
  [ ]   - 内存分配在 HCA 所在 NUMA
  [ ]   - 使用 numactl --membind
  [ ]   - numa_alloc_onnode()
  [ ]
  [ ] HugePages
  [ ]   - 预先配置足够 hugepages
  [ ]   - 关闭 transparent_hugepage
  [ ]   - 使用 posix_memalign 或 /dev/hugepages
  [ ]
  [ ] IOMMU
  [ ]   - 使用 iommu=pt (passthrough)
  [ ]   - 避免禁用 IOMMU (安全风险)
  [ ]
  [ ] 权限
  [ ]   - 只授予必要的权限
  [ ]   - 避免过度授权
```

---

## 10. 总结

### 10.1 内存效率关键指标

```
RDMA 内存效率:

  内存注册延迟:
    - 单次 ibv_reg_mr: 100-500 μs
    - 预注册可消除运行时开销

  内存带宽利用率:
    - 单流 100Gbps: ~12.5 GB/s (物理带宽足够)
    - 多流可能触及内存带宽限制

  MR 数量:
    - 推荐: < 512 个 MR / PD
    - MR 缓存: 硬件自动优化

  页面大小影响:
    - 4KB: TLB miss 频繁
    - 2MB: TLB 效率提升 512x
    - 1GB: 最大效率 (需硬件支持)
```

### 10.2 最佳配置参考

```
HPC/AI 训练内存配置:

  /proc/sys/vm/nr_hugepages = 32768  # 64GB hugepages
  transparent_hugepage = never
  iommu = pt
  numactl = --membind=<hca_node>

  应用:
    - 预注册 64GB+ 内存池
    - 使用 2MB 对齐
    - 避免运行时 MR 创建

  预期效果:
    - TLB miss < 0.1%
    - DMA 效率 > 98%
    - 内存延迟稳定
```

这四章覆盖了 RDMA 性能优化的核心方面：延迟（微秒级优化）、带宽（线速达成）、CPU（降低开销）、内存（DMA 效率）。结合前几章的网络配置（PFC/ECN），构成了完整的 RDMA 性能优化知识体系。
