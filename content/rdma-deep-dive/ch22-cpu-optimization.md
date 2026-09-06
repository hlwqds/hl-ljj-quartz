---
title: "RDMA 第二十二章：CPU 利用率优化——降低 RDMA 开销"
date: 2026-04-13
tags: [rdma, cpu, polling, interrupt, batch, numa, affinity, performance]
description: "详解 RDMA CPU 优化：轮询 vs 中断、batch polling、CPU 亲和性、NUMA 优化、减少系统调用、libibverbs 优化、CStates/P-States 节能管理。"
---

> [!abstract] 核心要点
> 尽管 RDMA 声称"零 CPU 参与"，但应用层仍需 CPU 管理队列、轮询完成、构造 WQE。本章深入分析如何降低 RDMA 的 CPU 开销，从轮询策略、批处理、NUMA 亲和性到 CPU 功耗管理，实现高效的数据平面操作。

---

## 1. RDMA 与 CPU 的关系

### 1.1 为什么 RDMA 仍需 CPU

RDMA 的"零 CPU 参与"指的是数据路径上不需要 CPU 介入控制：

```
RDMA 数据路径 vs 控制路径:

  数据路径 (Zero-CPU):
  ┌──────────────────────────────────────────────────────────────┐
  │                                                                │
  │  Application Buffer → HCA → Network → HCA → Remote Buffer   │
  │       (DMA)              ↑             (DMA)                  │
  │                          │                                    │
  │              HCA 直接读写内存，无需 CPU 介入                   │
  │                                                                │
  └──────────────────────────────────────────────────────────────┘

  控制路径 (需要 CPU):
  ┌──────────────────────────────────────────────────────────────┐
  │                                                                │
  │  WQE 构造:     CPU 构造 Work Request                           │
  │  队列管理:     CPU 更新 QP 状态                                │
  │  完成通知:     CPU 轮询 CQE 或处理中断                         │
  │  内存注册:     CPU 调用 ibv_reg_mr                            │
  │  连接管理:     CPU 处理 CM 事件                                │
  │                                                                │
  └──────────────────────────────────────────────────────────────┘
```

### 1.2 CPU 开销构成

```
RDMA CPU 开销分解:

  ┌─────────────────────────────────────────────────────────────────────────┐
  │  应用层 CPU 开销                                                        │
  │  ┌───────────────────────────────────────────────────────────────────┐  │
  │  │  1. 轮询开销 (60-70%)                                               │  │
  │  │     - 忙等待: 持续消耗 1 个 CPU 核心                               │  │
  │  │     - 自适应: 空闲时降低                                           │  │
  │  │                                                                   │  │
  │  │  2. WQE 构造 (15-20%)                                              │  │
  │  │     - 构造 Send/Recv Work Request                                  │  │
  │  │     - 设置 SGE (Scatter-Gather Entry)                             │  │
  │  │                                                                   │  │
  │  │  3. 完成处理 (10-15%)                                              │  │
  │  │     - 处理 CQE                                                    │  │
  │  │     - 更新应用状态                                                 │  │
  │  │                                                                   │  │
  │  │  4. 内存注册/查询 (5-10%)                                           │  │
  │  │     - lkey/rkey 验证                                              │  │
  │  │     - DMA 映射                                                    │  │
  │  └───────────────────────────────────────────────────────────────────┘  │
  └─────────────────────────────────────────────────────────────────────────┘

  典型 CPU 利用率 (100Gbps, 单流):
    - 忙等待轮询:  ~ 15-25% 单核
    - 批量轮询:    ~ 5-10% 单核
    - 中断模式:    ~ 2-5% 单核 (取决于负载)
```

---

## 2. 轮询策略

### 2.1 忙等待 vs 中断

```
轮询模式对比:

  ┌────────────────────────────────────────────────────────────────────────┐
  │  忙等待 (Busy Polling)                                                 │
  │  ├────────────────────────────────────────────────────────────────────┤
  │  │  优点:                                                             │  │
  │  │    - 最低延迟 (无中断开销)                                          │  │
  │  │    - 可预测的响应时间                                               │  │
  │  │                                                                   │  │
  │  │  缺点:                                                             │  │
  │  │    - 持续占用 CPU 核心                                              │  │
  │  │    - 空闲时浪费电力                                                 │  │
  │  │    - 扩展性差 (N 连接需要 N 核心)                                   │  │
  │  │                                                                   │  │
  │  │  适用: 低延迟应用、高带宽测试                                        │  │
  │  └────────────────────────────────────────────────────────────────────┘
  │
  ├────────────────────────────────────────────────────────────────────────┐
  │  中断模式 (Interrupt)                                                  │
  ├────────────────────────────────────────────────────────────────────┤
  │  优点:                                                             │  │
  │    - CPU 效率高 (空闲时不消耗)                                        │  │
  │    - 良好的扩展性                                                     │  │
  │                                                                   │  │
  │  缺点:                                                             │  │
  │    - 中断处理延迟 (通常 1-10 μs)                                     │  │
  │    - 中断处理开销                                                     │  │
  │    - 频繁中断可能降低性能                                             │  │
  │                                                                   │  │
  │  适用: 延迟不敏感、低带宽、多连接场景                                 │  │
  │  └────────────────────────────────────────────────────────────────────┘
  │
  ├────────────────────────────────────────────────────────────────────────┐
  │  自适应轮询 (Adaptive Polling)                                        │
  ├────────────────────────────────────────────────────────────────────┤
  │  策略:                                                              │  │
  │    - 短时间忙等待                                                     │  │
  │    - 如果没有完成，切换到睡眠                                         │  │
  │    - 平衡延迟和 CPU 效率                                              │  │
  │                                                                   │  │
  │  示例:                                                             │  │
  │    for (int i = 0; i < MAX_POLLS; i++) {                            │  │
  │        ret = ibv_poll_cq(cq, 1, &wc);                              │  │
  │        if (ret > 0) return;                                        │  │
  │    }                                                                │  │
  │    usleep(0);  // 让出 CPU                                           │  │
  │                                                                   │  │
  │  适用: 生产环境推荐                                                   │  │
  │  └────────────────────────────────────────────────────────────────────┘
  └────────────────────────────────────────────────────────────────────────┘
```

### 2.2忙等待实现

```c
// 纯忙等待轮询 - 最低延迟
static inline int busy_poll_cq(struct ibv_cq *cq) {
    struct ibv_wc wc;
    int ret;

    while (1) {
        ret = ibv_poll_cq(cq, 1, &wc);
        if (ret > 0) {
            return wc.status == IBV_WC_SUCCESS ? 0 : -1;
        }
        // CPU 持续检查，无睡眠
        cpu_relax();
    }
}

// 使用 CPU 暂停指令 (PAUSE) 的优化版本
static inline int pause_poll_cq(struct ibv_cq *cq) {
    struct ibv_wc wc;
    int ret;

    while (1) {
        ret = ibv_poll_cq(cq, 1, &wc);
        if (ret > 0) {
            return wc.status == IBV_WC_SUCCESS ? 0 : -1;
        }
        // PAUSE 指令降低功耗，不完全让出 CPU
        __asm__ volatile ("pause" ::: "memory");
    }
}

// 编译时使用 -O3 优化
// gcc -O3 -march=native -o app app.c
```

### 2.3 批量轮询

```c
// 批量轮询 - 更高吞吐，更低 CPU 开销
#define BATCH_SIZE 32

int batch_poll_cq(struct ibv_cq *cq) {
    struct ibv_wc wc[BATCH_SIZE];
    int n, processed = 0;

    while (1) {
        n = ibv_poll_cq(cq, BATCH_SIZE, wc);
        if (n > 0) {
            for (int i = 0; i < n; i++) {
                process_wc(&wc[i]);
            }
            processed += n;
        }

        // 如果一次 poll 满了，继续轮询
        if (n == BATCH_SIZE) {
            continue;
        }

        // 否则退出，让应用继续
        break;
    }

    return processed;
}

// 在高带宽场景下，批量处理减少函数调用开销
// 相比单条轮询，CPU 开销降低 30-50%
```

### 2.4 自适应轮询

```c
// 自适应轮询 - 平衡延迟和 CPU 效率
#define SHORT_BURST_POLLS 1000
#define SLEEP_USECS 10

int adaptive_poll_cq(struct ibv_cq *cq) {
    static _Thread_local int idle_count = 0;
    struct ibv_wc wc;
    int ret;

    // 短时间忙等待
    for (int i = 0; i < SHORT_BURST_POLLS; i++) {
        ret = ibv_poll_cq(cq, 1, &wc);
        if (ret > 0) {
            idle_count = 0;
            return (wc.status == IBV_WC_SUCCESS) ? 0 : -1;
        }
    }

    // 没有完成，累积 idle 计数
    idle_count++;

    // 持续 idle，进入睡眠模式
    if (idle_count > 10) {
        usleep(SLEEP_USECS);
        idle_count = 0;  // 醒来后重置
    }

    return 0;  // 无完成
}

// 另一种实现: epoll 混合
int epoll_hybrid_poll(int epfd, struct ibv_cq *cq, int timeout_ms) {
    struct epoll_event ev;
    struct ibv_wc wc;

    // 先尝试轮询
    int ret = ibv_poll_cq(cq, 1, &wc);
    if (ret > 0) {
        return ret;
    }

    // 没有完成，使用 epoll 等待
    // 需要配合 ibv_async_fd 转换为 epoll fd
    int fd = ibv_get_async_event_fd(cq);
    struct epoll_event event = {0};
    event.events = EPOLLIN;
    epoll_ctl(epfd, EPOLL_CTL_ADD, fd, &event);

    ret = epoll_wait(epfd, &ev, 1, timeout_ms);
    if (ret > 0) {
        // 有异步事件，再次轮询 CQ
        return ibv_poll_cq(cq, 1, &wc);
    }

    return 0;
}
```

---

## 3. CPU 亲和性

### 3.1 为什么 CPU 亲和性重要

```
CPU 缓存效应:

  L1 Cache:   ~1 ns,   32-64 KB
  L2 Cache:   ~4 ns,   256 KB - 1 MB
  L3 Cache:   ~15 ns,  8-64 MB
  Memory:     ~100 ns

  RDMA 操作涉及:
    - WQE 数据: 应在 L1/L2 缓存中
    - CQE 数据: 频繁访问
    - 内存注册表: 查找 lkey/rkey

  如果线程在不同 CPU 核心间迁移:
    - 缓存失效
    - 内存延迟增加
    - 延迟不稳定
```

### 3.2 绑定 RDMA 线程到 CPU

```bash
# 使用 taskset 绑定
$ taskset -c 0-7 ./rdma_server

# 使用 cgroup 隔离
$ cgcreate -g cpuset:/rdma
$ cgset -r cpuset.cpus=0-7 /rdma
$ cgset -r cpuset.mems=0 /rdma  # NUMA node 0
$ cgexec -g cpuset:/rdma ./rdma_server

# 使用 numactl
$ numactl --cpunodebind=0 --membind=0 ./rdma_server
```

### 3.3 编程中的 CPU 亲和性

```c
#include <sched.h>
#include <pthread.h>

void set_cpu_affinity(int cpu_core) {
    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);
    CPU_SET(cpu_core, &cpuset);

    pthread_t current_thread = pthread_self();
    if (pthread_setaffinity_np(current_thread, sizeof(cpu_set_t), &cpuset) != 0) {
        perror("pthread_setaffinity_np");
    }
}

void set_thread_affinity(pthread_t thread, int cpu_core) {
    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);
    CPU_SET(cpu_core, &cpuset);

    pthread_setaffinity_np(thread, sizeof(cpu_set_t), &cpuset);
}

// 为每个 RX 线程分配独立 CPU 核心
void setup_worker_threads(int num_threads) {
    pthread_t threads[64];
    int cpu_core = 0;

    for (int i = 0; i < num_threads; i++) {
        pthread_create(&threads[i], NULL, worker_loop, NULL);
        set_thread_affinity(threads[i], cpu_core++);
    }
}
```

### 3.4 独占 CPU 核

```bash
# 隔离 CPU 核心给 RDMA 使用 (Linux)
# 在 GRUB cmdline 添加: isolcpus=0-7

# 或者运行时隔离
$ echo 0-7 > /sys/devices/system/cpu/cpu0/cpulist

# 验证隔离
$ cat /sys/devices/system/cpu/cpu*/online
$ grep . /sys/devices/system/cpu/cpu*/topology/thread_siblings_list | sort -u
```

---

## 4. NUMA 优化

### 4.1 NUMA 对 CPU 效率的影响

```
NUMA 内存延迟:

  本地内存访问:    ~100 ns
  远程内存访问:    ~300-500 ns (3-5x 更慢)

  RDMA 场景:
    - HCA 通常连接到一个 NUMA 节点
    - 如果进程在远程 NUMA，内存访问更慢
    - 注册内存在远程时，lkey/rkey 查询变慢
```

### 4.2 NUMA 感知编程

```c
#include <numa.h>
#include <numaif.h>

// 查询当前 CPU 所在的 NUMA 节点
int get_current_numa_node(void) {
    return numa_node_of_cpu(sched_getcpu());
}

// 查询 HCA 连接的 NUMA 节点
int get_hca_numa_node(const char *device) {
    char path[256];
    int node;

    snprintf(path, sizeof(path),
             "/sys/class/infiniband/%s/device/numa_node", device);

    FILE *f = fopen(path, "r");
    if (!f) return 0;

    fscanf(f, "%d", &node);
    fclose(f);
    return node;
}

// NUMA 感知的内存注册
struct ibv_mr *numa_aware_reg_mr(struct ibv_pd *pd, void *addr, size_t size) {
    int hca_node = get_hca_numa_node("mlx5_0");
    int mem_node = get_membind_node(addr, size);

    if (hca_node != mem_node) {
        // 内存不在 HCA 所在 NUMA
        // 可能需要重新分配
        printf("Warning: memory on node %d, HCA on node %d\n",
               mem_node, hca_node);
    }

    return ibv_reg_mr(pd, addr, size, IBV_ACCESS_LOCAL_WRITE);
}

// NUMA 感知的进程调度
void numa_aware_sched(const char *device) {
    int hca_node = get_hca_numa_node(device);

    // 绑定当前进程到 HCA 所在的 NUMA
    struct bitmask *mask = numa_allocate_nodemask();
    numa_bitmask_setbit(mask, hca_node);

    numa_bind(mask);
    numa_free_nodemask(mask);

    printf("Current process bound to NUMA node %d\n", hca_node);
}
```

### 4.3 完整 NUMA 配置脚本

```bash
#!/bin/bash
# numa_rdma_setup.sh - NUMA 感知的 RDMA 配置

DEV=${1:-mlx5_0}

echo "=== NUMA Configuration for RDMA ==="

# 1. 找到 HCA 所在的 NUMA 节点
echo "[1] HCA NUMA Node:"
HCA_NODE=$(cat /sys/class/infiniband/${DEV}/device/numa_node 2>/dev/null || echo "0")
echo "  Device ${DEV} is on NUMA node ${HCA_NODE}"

# 2. 找到 HCA 的 PCIe 地址
echo "[2] PCIe Info:"
PCI=$(ls -la /sys/class/infiniband/${DEV}/device/ 2>/dev/null | grep pci | awk '{print $9}')
echo "  PCIe: ${PCI}"

# 3. 检查 PCIe 带宽
echo "[3] PCIe Bandwidth:"
lspci -vvv -s ${PCI} 2>/dev/null | grep -E "LnkSta|LnkCtl" | head -4

# 4. 找到 NUMA 节点上的 CPU 核心
echo "[4] NUMA Node ${HCA_NODE} CPUs:"
if [ -d "/sys/devices/system/node/node${HCA_NODE}" ]; then
    cat /sys/devices/system/node/node${HCA_NODE}/cpulist
fi

# 5. 推荐的任务绑定
echo "[5] Recommended Configuration:"
echo "  numactl --cpunodebind=${HCA_NODE} --membind=${HCA_NODE}"
echo "  taskset -c \$(cat /sys/devices/system/node/node${HCA_NODE}/cpulist)"
```

---

## 5. 减少系统调用

### 5.1 批量操作

```c
// 批量提交 WQE - 减少系统调用
struct ibv_send_wr wr_array[32];
struct ibv_sge sge_array[32];
struct ibv_send_wr *bad_wr;

for (int i = 0; i < 32; i++) {
    // 构造 WQE，但不立即提交
    wr_array[i].opcode = IBV_WR_SEND;
    wr_array[i].sg_list = &sge_array[i];
    wr_array[i].num_sge = 1;
    wr_array[i].next = (i < 31) ? &wr_array[i+1] : NULL;
}

// 一次系统调用提交所有 WQE
ibv_post_send(qp, &wr_array[0], &bad_wr);

// 对比:
//   非批量: 32 次 ibv_post_send = 32 次系统调用
//   批量:   1 次 ibv_post_send  = 1 次系统调用
```

### 5.2 预注册内存

```c
// 预注册大内存区域，避免运行时注册
#define MR_SIZE (128 * 1024 * 1024)  // 128MB

char *prealloc_buffer(void) {
    char *buf = malloc(MR_SIZE);
    if (!buf) return NULL;

    // 预注册
    struct ibv_mr *mr = ibv_reg_mr(pd, buf, MR_SIZE,
                                   IBV_ACCESS_LOCAL_WRITE |
                                   IBV_ACCESS_REMOTE_WRITE |
                                   IBV_ACCESS_REMOTE_READ);

    if (!mr) {
        free(buf);
        return NULL;
    }

    printf("Registered MR: lkey=0x%x, size=%d MB\n", mr->lkey, MR_SIZE/1024/1024);
    return buf;
}

// 运行时使用预注册的 lkey
void fast_send(struct ibv_qp *qp, struct ibv_mr *mr, char *buf, int size) {
    struct ibv_send_wr wr = {
        .opcode = IBV_WR_SEND,
        .sg_list = &(struct ibv_sge){
            .addr = (uintptr_t)buf,
            .length = size,
            .lkey = mr->lkey  // 使用预注册的 lkey
        },
        .num_sge = 1,
    };
    ibv_post_send(qp, &wr, NULL);
}
```

### 5.3 避免不必要的 ibv_poll_cq 调用

```c
// 使用事件驱动代替频繁轮询
struct ibv_comp_channel *channel;
struct ibv_cq *cq;

// 创建完成通道
channel = ibv_create_comp_channel(ctx);

// 创建关联的 CQ
cq = ibv_create_cq(ctx, 128, NULL, channel, 0);

// 等待完成事件（阻塞）
struct ibv_cq *ev_cq;
void *ev_ctx;
int ret = ibv_get_cq_event(channel, &ev_cq, &ev_ctx);
if (ret == 0) {
    // 有完成事件，轮询 CQ
    struct ibv_wc wc;
    while (ibv_poll_cq(cq, 1, &wc) > 0) {
        process_wc(&wc);
    }
    ibv_ack_cq_events(cq, 1);
}

// 优势:
//   - 避免无意义的轮询
//   - CPU 可以休眠
//   - 适合低带宽、多连接场景
```

---

## 6. CPU 功耗管理

### 6.1 C-States

```
CPU C-States (节能状态):

  C0: 工作状态 (100% 性能)
  C1: Halt (50% 节省)
  C2: 停止时钟 (70% 节省)
  C3: 深度睡眠 (80% 节省, 唤醒慢)
  C6: 更深睡眠 (90% 节省)
  C7: 最深睡眠

  问题:
    - 从 C3/C6 唤醒需要 1-10 μs
    - RDMA 期望的延迟 < 5 μs
    - 如果 CPU 进入 C3，延迟会增加

  解决方案:
    - 禁用深层 C-states
    - 使用 performance governor
```

### 6.2 P-States (动态频率)

```
CPU P-States (频率状态):

  P0: 最高频率 (100% 性能)
  P1: 降低 10-20%
  P2: 降低 20-30%
  ...
  P15: 最低频率

  问题:
    - 频率切换延迟 ~100 μs
    - 高频率 = 高延迟
    - 动态调频影响性能稳定性

  解决方案:
    - 使用 performance governor
    - 锁定最高频率
```

### 6.3 配置 CPU 功耗策略

```bash
#!/bin/bash
# cpu_performance_setup.sh - RDMA 性能友好的 CPU 配置

echo "=== CPU Performance Configuration ==="

# 1. 设置 CPU governor 为 performance
for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo performance > $cpu
done

# 2. 验证 governor 设置
echo "[1] CPU Governor:"
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor

# 3. 禁用 Turbo Boost (可选，更稳定的基准测试)
# echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo

# 4. 禁用 C-states (通过 grub)
# 在 GRUB cmdline 添加: processor.max_cstate=1 intel_idle.max_cstate=1

# 5. 验证 C-state
echo "[2] CPU C-State:"
cat /sys/devices/system/cpu/cpu0/cpuidle/state0/name
cat /sys/devices/system/cpu/cpu0/cpuidle/state0/disable

# 6. 禁用 transparent hugepage (THP)
echo "[3] Transparent HugePage:"
echo madvise > /sys/kernel/mm/transparent_hugepage/enabled
echo madvise > /sys/kernel/mm/transparent_hugepage/defrag

# 7. 验证
echo "[4] Final Configuration:"
cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor | sort -u
grep -E "Model|CPU MHz" /proc/cpuinfo | head -4
```

### 6.4 编程中的功耗管理

```c
#include <cpufreq.h>

// 编程方式锁定 CPU 频率
void lock_cpu_frequency(int cpu, unsigned long freq_khz) {
    char path[256];
    FILE *f;

    // 设置为 userspace governor
    snprintf(path, sizeof(path),
             "/sys/devices/system/cpu/cpu%d/cpufreq/scaling_governor", cpu);
    f = fopen(path, "w");
    fprintf(f, "userspace");
    fclose(f);

    // 设置频率
    snprintf(path, sizeof(path),
             "/sys/devices/system/cpu/cpu%d/cpufreq/scaling_setspeed", cpu);
    f = fopen(path, "w");
    fprintf(f, "%lu", freq_khz);
    fclose(f);
}

// 防止 CPU 进入深度睡眠
void prevent_deep_sleep(void) {
    // 通过 msr-tools 或直接写 MSR
    // 设置 PLATFORM_INFO[15:8] = 0 (禁用 C6)

    // 或者使用 tuna 工具
    // system("tuna -C 0-7 -I -V power/*:0");
}
```

---

## 7. 中断优化

### 7.1 中断亲和性

```bash
# 查看 Mellanox HCA 的 IRQ
$ grep -i mlx5 /proc/interrupts | head -20
  CPU0   CPU1   CPU2   CPU3 ...
 123:   12345   2345   3456   4567  ...   mlx5-async
 124:   34567  12345  23456  12345 ...   mlx5-comp-0
 125:   23456  34567  12345  23456 ...   mlx5-comp-1

# 设置 IRQ 亲和性 (irqbalance 服务应关闭)
$ cat /proc/irq/124/smp_affinity
$ echo 1 > /proc/irq/124/smp_affinity_list  # 绑定到 CPU 0

# 或者使用 irqbalance
$ systemctl stop irqbalance
```

### 7.2 多队列中断

```bash
# 查看网卡的多队列状态
$ ethtool -l eth0
Channel parameters for eth0:
Pre-set maximums:
RX:              0
TX:              0
Other:           0
Combined:        16
Current hardware channel parameters:
RX:              0
TX:              0
Other:           0
Combined:        4

# 设置更多队列
$ ethtool -L eth0 combined 16
```

### 7.3 中断合并

```c
// RDMA CQ 事件合并
struct ibv_cq_init_attr cq_attr = {
    .cqe = 128,
    .comp_vector = 0,       // 中断向量
    .cq_flags = 0,         // 可设置 IBV_CQ_FLAGS_TIMESTAMP_COMPLETION
};

// 创建 CQ 时指定合并参数
// 注意: libibverbs 目前不支持细粒度合并控制
// 中断合并通常在驱动层配置

// Mellanox 驱动配置:
$ echo 1 > /sys/module/mlx5_core/parameters/poll_rq_affinity
```

---

## 8. CPU 开销监控

### 8.1 使用 perf 监控

```bash
# 监控 RDMA 应用的 CPU 开销
$ perf stat -e cpu-clock,task-clock,context-switches ./rdma_app

# 监控特定 CPU 核心
$ perf stat -C 0 -e cpu-clock ./rdma_app

# 监控缓存命中率
$ perf stat -e cache-references,cache-misses ./rdma_app

# 使用火焰图
$ perf record -F 99 -a -g ./rdma_app
$ perf script | stackvis-grov > flame.svg
```

### 8.2 使用 top/htop

```bash
# 监控 RDMA 进程的 CPU 使用
$ top -H -p $(pgrep -f rdma_app)

# 使用 pidstat
$ pidstat -p $(pgrep -f rdma_app) 1
Linux 5.4.0 (hostname)  04/13/2026  _x86_64_  (8 CPU)

10:30:45 AM   PID   %usr %usr   %guest %wait   %CPU   CPU  Command
10:30:46 AM  12345  12.34  0.00    0.00    0.00   12.34     0  rdma_app
10:30:46 AM  12346  15.67  0.00    0.00    0.00   15.67     1  rdma_app
```

### 8.3 RDMA 特定计数

```bash
# 使用 perfmon 监控 RDMA 计数器
$ perf stat -e 'rdma_ib0/*/' -a ./rdma_app

# 查看 ibv_devinfo 中的计数器
$ ibv_devinfo -v -d mlx5_0 | grep -E "port_cnt|max_qp"

# 使用 rdma stat 命令
$ rdma stat -j -d mlx5_0
```

---

## 9. CPU 优化 checklist

### 9.1 快速优化指南

```
RDMA CPU 优化要点:

  [ ] 轮询策略
  [ ]   - 高性能: 忙等待 PAUSE 指令
  [ ]   - 生产环境: 批量轮询
  [ ]   - 低带宽: 自适应轮询 + 中断
  [ ]
  [ ] CPU 亲和性
  [ ]   - 绑定到独立 CPU 核心
  [ ]   - 独占 CPU 核 (isolcpus)
  [ ]   - 避免核心迁移
  [ ]
  [ ] NUMA 亲和性
  [ ]   - 进程和内存在 HCA 所在 NUMA
  [ ]   - 使用 numactl --membind
  [ ]
  [ ] 功耗管理
  [ ]   - performance governor
  [ ]   - 禁用深层 C-states
  [ ]   - 锁定最高频率
  [ ]
  [ ] 系统配置
  [ ]   - 关闭 transparent hugepage
  [ ]   - 隔离 Mellanox IRQ 到独立 CPU
  [ ]   - 关闭 irqbalance
  [ ]
  [ ] 代码优化
  [ ]   - 批量提交 WQE
  [ ]   - 预注册大内存区域
  [ ]   - 减少不必要的 ibv_poll_cq 调用
```

### 9.2 典型 CPU 开销参考

```
RDMA CPU 开销参考 (单流, 100Gbps):

  忙等待轮询:    15-25% 单核
  批量轮询(32):   5-10% 单核
  自适应轮询:     3-7% 单核 (取决于负载)
  中断模式:       2-5% 单核 (取决于负载)

  8 流并行:
    忙等待:       100%+ (超过单核)
    批量轮询:     40-60% (需要 1-2 核)
    中断模式:     15-30% (1 核足够)

  结论:
    - 高带宽单流: 批量轮询最好
    - 多流: 每流独立核心或共享核心
    - 低带宽: 中断或自适应轮询
```

---

## 10. 总结

### 10.1 优化策略选择

```
场景                     推荐策略
─────────────────────────────────────────────────────────────────
HPC 基准测试              忙等待 + 独占核心 + performance governor
AI 训练 (多节点)          批量轮询 + 多线程 + NUMA 亲和
分布式存储                批量轮询 + 中断混合 + 自适应
低延迟交易                忙等待 + 最低延迟配置
云计算/多租户             自适应轮询 + 中断模式
```

### 10.2 关键配置参数

```
/proc/sys/kernel 参数:
  transparent_hugepage = madvise
  sched_min_granularity_ns = 10000

/sys/devices/system/cpu/cpu*/cpufreq/:
  scaling_governor = performance

/sys/module/mlx5_core/parameters/:
  poll_rq_affinity = 2  (自适应轮询)
```

下一章我们将讨论内存优化，最大化 DMA 效率和缓存利用率。
