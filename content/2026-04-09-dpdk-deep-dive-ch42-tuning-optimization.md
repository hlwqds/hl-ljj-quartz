---
title: "DPDK 深度探索 ch42：性能调优策略"
date: 2026-04-10 16:30:00
tags: [dpdk, tuning, optimization, cpu, memory, network, cache, NUMA]
description: "深入解析 DPDK 性能调优：CPU 绑定、内存优化、网卡调优、Cache 优化、NUMA 配置与系统参数"
---

# DPDK 深度探索 ch42：性能调优策略

> [!abstract] 核心要点
> 性能调优是 DPDK 部署的关键。本章深入解析 CPU 绑定、内存优化、网卡配置、Cache 优化与系统参数调优。

## 1. 系统参数

### 1.1 BIOS 设置

```
BIOS 推荐设置：

┌─────────────────────────────────────────────────────────────┐
│                    BIOS 设置项                             │
│                                                              │
│  CPU:                                                      │
│  - 禁用 Hyper-Threading (追求低延迟)                       │
│  - 启用 Turbo Boost (追求高吞吐)                           │
│  - 设置 C-State: C0/C1 only                               │
│  - 禁用电源管理                                            │
│                                                              │
│  内存:                                                      │
│  - 启用 XMP 配置文件                                       │
│  - 锁定内存频率                                            │
│  - 启用 Node Interleaving: Disabled (NUMA)                │
│                                                              │
│  PCIe:                                                     │
│  - 设置 PCIe ASPM: Optimal                                │
│  - 禁用 L1 Sub-states (低延迟)                            │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 Kernel 参数

```bash
# /etc/default/grub
GRUB_CMDLINE_LINUX="isolcpus=1-15 hugepagesz=2M hugepages=4096 \
    intel_iommu=on iommu=pt \
    default_hugepagesz=2M \
    processor.max_cstate=1 \
    intel_idle.max_cstate=0 \
    nfsi.t5.timeout=0 \
    skew_tick=1"

# 更新 grub
sudo update-grub
sudo reboot
```

### 1.3 系统限制

```bash
# /etc/security/limits.conf
* soft nofile 1048576
* hard nofile 1048576
* soft memlock unlimited
* hard memlock unlimited
* soft core unlimited
* hard core unlimited

# /etc/sysctl.conf
# 网络
net.core.rmem_max=134217728
net.core.wmem_max=134217728
net.core.rmem_default=16777216
net.core.wmem_default=16777216
net.core.netdev_max_backlog=50000
net.core.somaxconn=4096

# IP 转发
net.ipv4.ip_forward=1
net.ipv4.conf.all.forwarding=1
net.ipv4.conf.default.forwarding=1
```

## 2. CPU 优化

### 2.1 CPU 绑定

```bash
# 查看 CPU 信息
lscpu

# 查看 NUMA
numactl --hardware

# CPU 绑定
sudo dpdk-testpmd -l 0-3 -n 4 -- \
    --master-lcore=0 \
    --lcores="(0-3)@(0-3)"
```

### 2.2 lcore 分配

```bash
# 4 核配置示例
# lcores = master@core0, worker1@core1, worker2@core2, worker3@core3
sudo dpdk-app -l 0-3 \
    --master-lcore 0 \
    --lcores '0@0,1@1,2@2,3@3'
```

### 2.3 避免同步

```c
// 错误: 跨核同步
uint32_t global_counter;  // ❌ 共享变量

// 正确: 每个核独立计数
struct per_lcore_counter {
    uint32_t count;
};

// 每个 lcore 独立
struct per_lcore_counter counters[RTE_MAX_LCORE];

uint32_t
get_lcore_id(void)
{
    return rte_lcore_id();
}

void
increment(void)
{
    counters[rte_lcore_id()].count++;  // ✅ 无锁
}
```

## 3. 内存优化

### 3.1 Hugepage

```bash
# 查看当前 hugepage
grep -i huge /proc/meminfo

# 配置 2M hugepage
echo 4096 > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages

# 配置 1G hugepage
echo 16 > /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages

# 挂载 hugepage
mkdir -p /mnt/hugepages
mount -t hugetlbfs nodev /mnt/hugepages

# 持久化配置 /etc/fstab
nodev /mnt/hugepages hugetlbfs defaults 0 0
```

### 3.2 内存分配

```c
// DPDK 内存分配
#include <rte_eal.h>
#include <rte_malloc.h>

// 分配对齐内存
void *
alloc_aligned(size_t size, size_t align)
{
    return rte_malloc_socket(NULL, size, align,
                            rte_socket_id());
}

// 分配 memory pool
struct rte_mempool *
create_mempool(const char *name, int socket_id)
{
    return rte_pktmbuf_pool_create(
        name,                 // 名称
        8192,                 // 对象数
        256,                  // cache per lcore
        0,                    // private data size
        2048,                 // data room size
        socket_id             // NUMA socket
    );
}
```

### 3.3 NUMA 优化

```c
// NUMA-aware 内存分配
struct rte_mempool *
create_numa_aware_mempool(int nb_mbuf)
{
    struct rte_mempool *mp[RTE_MAX_NUMA_NODES];
    int nb_sockets = rte_socket_count();

    // 每个 NUMA 节点创建 pool
    for (int s = 0; s < nb_sockets; s++) {
        char name[32];
        snprintf(name, sizeof(name), "mbuf_pool_%d", s);

        mp[s] = rte_pktmbuf_pool_create(
            name,
            nb_mbuf / nb_sockets,
            256,
            0,
            RTE_MBUF_DEFAULT_BUF_SIZE,
            s  // NUMA socket
        );
    }

    return mp[0];  // 返回 primary
}

// 获取本地 socket
int
get_local_socket(void)
{
    return rte_socket_id();
}
```

## 4. 网卡优化

### 4.1 网卡中断

```bash
# 查看网卡中断
cat /proc/interrupts | grep eth

# 禁用网卡的 IRQ 合并
ethtool -C eth0 rx-usecs 0 rx-frames 1
ethtool -C eth0 tx-usecs 0 tx-frames 1

# 绑定 RSS 中断到特定核
for i in $(cat /proc/interrupts | grep eth0 | awk '{print $1}'); do
    echo "set $i 4"
done | sudo sh

# 查看网卡队列
ethtool -l eth0
```

### 4.2 RSS 配置

```c
// RSS 配置
#include <rte_ethdev.h>

int
configure_rss(struct rte_flow_conf *conf)
{
    struct rte_eth_rss_conf rss_conf = {
        .rss_key = rss_key_default,  // 40B key
        .rss_key_len = 40,
        .rss_hf = ETH_RSS_TCP |      // TCP RSS
                   ETH_RSS_UDP |      // UDP RSS
                   ETH_RSS_IP |        // IP RSS
                   ETH_RSS_VLAN,       // VLAN RSS
    };

    rte_eth_dev_rss_hash_update(port_id, &rss_conf);

    return 0;
}
```

### 4.3 Flow Control

```c
// Flow Control 配置
int
configure_flow_control(uint16_t port_id)
{
    struct rte_eth_fc_conf fc_conf = {
        .mode = RTE_FC_PAUSE,       // 暂停模式
        .high_water = 64,            // 高水位
        .low_water = 32,             // 低水位
        .pause_time = 0x100,         // 暂停时间
        .send_xon = 1,               // 发送 XON
        .mac_fc_mode = RTE_FC_NONE,
    };

    return rte_eth_dev_flow_ctrl_set(port_id, &fc_conf);
}
```

## 5. Cache 优化

### 5.1 Cache 层次

```
┌─────────────────────────────────────────────────────────────┐
│                    CPU Cache 层次                           │
│                                                              │
│  L1d: 32KB per core, ~1ns, ~10 cycles                      │
│  L1i: 32KB per core, ~1ns, ~10 cycles                      │
│                                                              │
│  L2:  256KB per core, ~3ns, ~15 cycles                     │
│                                                              │
│  L3:  Shared per socket, ~10ns, ~50 cycles                 │
│                                                              │
│  DRAM: ~100ns, ~200 cycles                                  │
│                                                              │
│  Cache line: 64 bytes                                       │
│  缓存未命中时，整个 cache line 加载                          │
└─────────────────────────────────────────────────────────────┘
```

### 5.2 内存对齐

```c
// 结构体对齐
struct __rte_cache_aligned packet_header {
    uint32_t flags;          // 4 bytes
    uint32_t seq;            // 4 bytes
    uint64_t timestamp;      // 8 bytes
    uint8_t  data[52];       // padded to 64 bytes
} __rte_cache_aligned;

// 数组对齐
struct rte_mbuf *pkts[32] __rte_aligned(64);

// 避免 false sharing
struct {
    uint32_t counter_a;  // 写入 core A
    uint32_t counter_b;  // 写入 core B
    uint32_t counter_c;  // 写入 core C
} __rte_cache_aligned;  // 避免跨核 false sharing
```

### 5.3 预取优化

```c
// 预取优化
struct packet {
    uint32_t flags;
    uint8_t data[128];
};

int
process_packets(struct rte_mbuf **pkts, int nb_pkts)
{
    for (int i = 0; i < nb_pkts; i++) {
        struct packet *pkt = rte_pktmbuf_mtod(pkts[i], struct packet *);

        // 预取下一个包
        if (i + 1 < nb_pkts) {
            struct packet *next =
                rte_pktmbuf_mtod(pkts[i+1], struct packet *);
            rte_prefetch0(next);
        }

        // 处理当前包
        process_packet(pkt);
    }

    return 0;
}
```

## 6. 批处理优化

### 6.1 Burst 处理

```c
// 批量接收
#define BURST_SIZE 32

int
process_burst(uint16_t port_id)
{
    struct rte_mbuf *pkts[BURST_SIZE];

    // 批量接收
    uint16_t nb_rx = rte_eth_rx_burst(
        port_id, 0,           // 端口, 队列
        pkts, BURST_SIZE       // 缓冲区, 大小
    );

    if (nb_rx == 0)
        return 0;

    // 批量处理
    for (int i = 0; i < nb_rx; i++) {
        process_packet(pkts[i]);
    }

    // 批量发送
    uint16_t nb_tx = rte_eth_tx_burst(
        port_id, 0,
        pkts, nb_rx
    );

    // 释放未发送的 mbuf
    if (nb_tx < nb_rx) {
        for (int i = nb_tx; i < nb_rx; i++) {
            rte_pktmbuf_free(pkts[i]);
        }
    }

    return nb_rx;
}
```

### 6.2 Pipeline 优化

```c
// 多阶段 pipeline
struct pipeline {
    struct rte_ring *stage1_ring;
    struct rte_ring *stage2_ring;
    struct rte_ring *stage3_ring;
};

int
stage1(void *arg)
{
    struct pipeline *p = arg;
    struct rte_mbuf *pkts[BURST_SIZE];

    while (1) {
        uint16_t nb_rx = rte_eth_rx_burst(port_id, 0, pkts, BURST_SIZE);

        if (nb_rx > 0) {
            // 解析
            for (int i = 0; i < nb_rx; i++) {
                parse_header(pkts[i]);
            }

            // 发送到下一阶段
            rte_ring_sp_enqueue_bulk(p->stage1_ring, (void **)pkts, nb_rx);
        }
    }
}

int
stage2(void *arg)
{
    struct pipeline *p = arg;
    struct rte_mbuf *pkts[BURST_SIZE];

    while (1) {
        uint16_t nb_deq = rte_ring_sc_dequeue_bulk(
            p->stage1_ring, (void **)pkts, BURST_SIZE);

        if (nb_deq > 0) {
            // 查找流
            for (int i = 0; i < nb_deq; i++) {
                lookup_flow(pkts[i]);
            }

            rte_ring_sp_enqueue_bulk(p->stage2_ring, (void **)pkts, nb_deq);
        }
    }
}
```

## 7. 调优清单

### 7.1 完整调优检查表

```
DPDK 调优检查表：

□ BIOS 设置
  □ CPU: 禁用 C-states, Turbo Boost (低延迟)
  □ 内存: XMP 配置, NUMA 节点隔离
  □ PCIe: ASPM 禁用

□ 系统配置
  □ hugepages: 2M 或 1G
  □ isolcpus: 隔离 CPU 核心
  □ nohz_full: 减少计时器中断

□ DPDK 配置
  □ master-lcore: 专用管理核
  □ lcores: 分配 worker 核
  □ socket-mem: 每个节点内存

□ 网卡配置
  □ RSS: 启用多队列
  □ Flow Control: 根据需要启用
  □ Interrupt: 轮询模式

□ 应用优化
  □ Burst 处理
  □ 无锁算法
  □ Cache 对齐
  □ 预取
```

### 7.2 性能目标

| 配置 | 低延迟目标 | 高吞吐目标 |
|------|-----------|-----------|
| **延迟** | < 5 μs | < 20 μs |
| **CPU** | 每核专注 | 多核扩展 |
| **Hugepage** | 1G | 2M |
| **Cache** | 完全热 | 局部热 |
| **Turbo** | 禁用 | 启用 |

## 8. 总结

调优层次：

```
┌─────────────────────────────────────────────────────────────┐
│                    调优优先级                               │
│                                                              │
│  1. 系统层 (最大影响)                                        │
│     BIOS → Kernel → hugepages                             │
│                                                              │
│  2. 架构层                                                  │
│     NUMA → CPU binding → Cache                           │
│                                                              │
│  3. 驱动层                                                  │
│     RSS → Flow Control → Queue 配置                       │
│                                                              │
│  4. 应用层 (最小影响)                                        │
│     Burst → Prefetch → 无锁                               │
└─────────────────────────────────────────────────────────────┘
```

性能收益预估：

| 优化项 | 收益 | 难度 |
|--------|------|------|
| **Hugepage** | 10-30% | 低 |
| **CPU 绑定** | 20-50% | 低 |
| **NUMA 优化** | 20-40% | 中 |
| **Burst 处理** | 50-100% | 低 |
| **Cache 优化** | 10-30% | 中 |
| **预取优化** | 5-15% | 高 |

---

## 参考资源

- [DPDK Performance Optimization](https://doc.dpdk.org/guides/prog_guide/perf_opt.html)
- [Intel Optimization Guide](https://software.intel.com/en-us/optimization-manual)
- [Linux Real-Time](https://wiki.linuxfoundation.org/realtime/documentation)
