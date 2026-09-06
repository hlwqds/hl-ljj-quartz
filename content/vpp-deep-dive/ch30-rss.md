---
title: "VPP 深入探讨 ch30：RSS 与多队列"
date: 2026-04-16 10:40:00
tags: [vpp, rss, receive-side-scaling, multi-queue, symmetric-rss, hash, queue]
description: "深入解析 VPP RSS 与多队列：Receive Side Scaling、对称哈希、多队列配置、负载均衡与性能优化"
---

# VPP 深入探讨 ch30：RSS 与多队列

> [!abstract] 核心要点
> RSS (Receive Side Scaling) 是多核系统下提升吞吐的关键技术。本章深入解析 RSS 原理、对称哈希、多队列配置、负载均衡与性能优化。

## 1. RSS 概述

### 1.1 RSS 架构

```
┌─────────────────────────────────────────────────────────────┐
│                       RSS 架构                               │
│                                                              │
│              NIC Hardware                                    │
│    ┌──────────────────────────────────────────────────┐    │
│    │                                                   │    │
│    │  ┌─────────┐   ┌─────────┐   ┌─────────┐        │    │
│    │  │ Queue 0 │   │ Queue 1 │   │ Queue n │        │    │
│    │  │   (CPU 0)│   │ (CPU 1) │   │ (CPU n) │        │    │
│    │  └─────────┘   └─────────┘   └─────────┘        │    │
│    │                                                   │    │
│    │  RSS HASH Table:                                 │    │
│    │  hash(src_ip, dst_ip, src_port, dst_port)        │    │
│    │       ↓                                          │    │
│    │  queue_index = hash % num_queues                │    │
│    │                                                   │    │
│    └──────────────────────────────────────────────────┘    │
│                           ↓                                 │
│              ┌────────────────────────────────────┐        │
│              │         RX Descriptor Ring          │        │
│              └────────────────────────────────────┘        │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 RSS vs 多队列区别

| 特性           | RSS               | 多队列（静态） |
| -------------- | ----------------- | -------------- |
| **分发策略**   | 基于 5-tuple 哈希 | 固定绑定       |
| **负载均衡**   | 自动              | 手动配置       |
| **对称性**     | 可能不对称        | N/A            |
| **CPU 利用率** | 高                | 中             |
| **配置复杂度** | 中                | 低             |
| **适用场景**   | 通用              | 确定性延迟     |

### 1.3 VPP RSS 支持

```bash
# 查看 VPP RSS 支持
vppctl show hardware

# 示例输出：
# Interface: TenGigabitEthernet0/0/0
#   NIC: Intel X710
#   RX queues: 8
#   RSS: enabled
#   RSS indirection table: 64 entries
#   RSS hash: IP 4-tuple + L4 ports
```

## 2. RSS 哈希算法

### 2.1 哈希字段

```bash
# RSS 哈希可以使用的字段
#
# 1. IP 2-tuple (src_ip, dst_ip)
# 2. IP 3-tuple (src_ip, dst_ip, proto)
# 3. IP 4-tuple (src_ip, dst_ip, src_port, dst_port)
# 4. VLAN + 4-tuple

# 查看当前哈希配置
ethtool -x eth0

# 示例输出：
# RX flow hash indirection table:
# HW function idx: 0x0
# ...
#
# RSS hash configuration:
#   IP src:  Y
#   IP dst:  Y
#   L4 src port:  Y
#   L4 dst port:  Y
```

### 2.2 对称 vs 非对称 RSS

```
┌─────────────────────────────────────────────────────────────┐
│            对称 RSS vs 非对称 RSS                           │
│                                                              │
│   对称 RSS:                                                  │
│   packet(A→B) → queue 0                                    │
│   packet(B→A) → queue 0  ✓ 同一队列                        │
│                                                              │
│   非对称 RSS:                                                │
│   packet(A→B) → queue 0                                    │
│   packet(B→A) → queue 3  ✗ 不同队列（连接分裂）            │
│                                                              │
│   VPP 需要对称 RSS 保证双向流量走同一 worker               │
└─────────────────────────────────────────────────────────────┘
```

### 2.3 对称哈希实现

```c
// 对称哈希实现 - 确保双向流量走同一队列

static_always_inline u32
symmetric_hash (u32 src_ip, u32 dst_ip, u16 src_port, u16 dst_port)
{
    u32 hash;

    // 确保 src_ip <= dst_ip（按数值排序）
    if (src_ip > dst_ip) {
        swap(src_ip, dst_ip);
        swap(src_port, dst_port);
    }

    // TOEPLITZ 哈希（Intel 常用）
    // 或者使用其他对称哈希算法

    hash = (src_ip & 0x0000FFFF) ^
           (dst_ip >> 16) ^
           src_port ^
           (dst_port << 1);

    return hash;
}

// 应用到 RSS indirection table
static_always_inline u32
get_rss_queue (u32 hash, u32 num_queues)
{
    return hash % num_queues;
}

// 使用示例
u32
get_packet_queue (vlib_buffer_t *b)
{
    ip4_header_t *ip = vlib_buffer_get_current(b);
    tcp_header_t *tcp = (tcp_header_t *)(ip + 1);

    u32 hash = symmetric_hash(
        ip->src_address.as_u32,
        ip->dst_address.as_u32,
        tcp->src_port,
        tcp->dst_port
    );

    return hash % num_workers;
}
```

### 2.4 Toeplitz 哈希

```c
// Toeplitz 哈希实现（常见于 Intel NIC）

#define RSS_KEY_SIZE 40

static const u8 toeplitz_key[RSS_KEY_SIZE] = {
    // Intel 推荐的默认 RSS key
    0x6D, 0x5A, 0x56, 0xDA, 0x25, 0x5B, 0xAB, 0xFF,
    0xF6, 0x42, 0x3F, 0xD1, 0x2C, 0xC1, 0x6D, 0x34,
    0xE4, 0x8A, 0xA2, 0x4A, 0x6B, 0x7B, 0xD0, 0x68,
    0x2F, 0xF8, 0x07, 0x53, 0x86, 0x0D, 0xD2, 0x2F,
    0x4D, 0x5F, 0x6E, 0x1E, 0xE5, 0x77, 0x47, 0x8C,
};

static_always_inline u32
toeplitz_hash (const void *data, int len)
{
    const u8 *bytes = data;
    u32 hash = 0;

    for (int i = 0; i < len; i++) {
        // 将数据位与 key 位异或
        for (int bit = 0; bit < 8; bit++) {
            if (bytes[i] & (1 << bit)) {
                hash ^= ((u32 *)toeplitz_key)[i * 8 + bit];
            }
        }
    }

    return hash;
}

// 计算 5-tuple RSS hash
static_always_inline u32
rss_5tuple_hash (ip4_header_t *ip, l4_header_t *l4)
{
    struct {
        u32 src_ip;
        u32 dst_ip;
        u16 src_port;
        u16 dst_port;
        u8  proto;
    } __attribute__((packed)) tuple;

    tuple.src_ip = ip->src_address.as_u32;
    tuple.dst_ip = ip->dst_address.as_u32;
    tuple.src_port = l4->src_port;
    tuple.dst_port = l4->dst_port;
    tuple.proto = ip->protocol;

    return toeplitz_hash(&tuple, sizeof(tuple));
}
```

## 3. 多队列配置

### 3.1 队列数量配置

```bash
# startup.conf 中的多队列配置
dpdk {
    # 为所有接口设置默认队列数
    dev default {
        num-rx-queues 4
        num-tx-queues 4
    }
}

# 为特定接口设置
dpdk {
    dev TenGigabitEthernet0/0/0 {
        num-rx-queues 8
        num-tx-queues 8
    }

    dev TenGigabitEthernet0/0/1 {
        num-rx-queues 4
        num-tx-queues 4
    }
}
```

### 3.2 队列与 CPU 绑定

```bash
# 查看当前 CPU 映射
vppctl show threads

# 示例输出：
# Name          Type     CPU  Pin  Polls  Suspends
# vpp_main      active     0    y    1234        0
# vpp_worker_0  active     1    y    5678        0
# vpp_worker_1  active     2    y    5678        0
# vpp_worker_2  active     3    y    5678        0
# vpp_worker_3  active     4    y    5678        0

# 队列绑定配置（通过系统 IRQ 亲和性）
# 查看当前 IRQ 绑定
cat /proc/interrupts | grep -E 'eth0|dpdk'

# 设置队列 0-3 绑定到 CPU 1-4
echo 2 > /proc/irq/157/smp_affinity_list  # queue 0 → CPU 1
echo 4 > /proc/irq/158/smp_affinity_list  # queue 1 → CPU 2
echo 8 > /proc/irq/159/smp_affinity_list  # queue 2 → CPU 3
echo 16 > /proc/irq/160/smp_affinity_list # queue 3 → CPU 4
```

### 3.3 运行时调整

```bash
# 运行时查看 RSS 配置
vppctl show rss

# 示例输出：
# RSS Configuration:
#   Enabled: yes
#   Hash function: Toeplitz
#   Hash fields: IP 4-tuple
#   Number of queues: 4
#   Indirection table: 64 entries
#
#   Queue mapping:
#     Queue 0: worker 0 (CPU 1)
#     Queue 1: worker 1 (CPU 2)
#     Queue 2: worker 2 (CPU 3)
#     Queue 3: worker 3 (CPU 4)

# 修改 RSS 队列数
vppctl set rss queues 8

# 修改 RSS 哈希字段
vppctl set rss hash ip4-tuple
vppctl set rss hash ip5-tuple

# 查看 RSS indirection table
vppctl show rss-table

# 示例输出：
# RSS Indirection Table (64 entries):
# 0x00: queue 0, 0x01: queue 0, 0x02: queue 1, 0x03: queue 1
# 0x04: queue 2, 0x05: queue 2, 0x06: queue 3, 0x07: queue 3
# ...
```

### 3.4 队列统计

```bash
# 查看 per-queue 统计
vppctl show interface TenGigabitEthernet0/0/0 queue-stats

# 示例输出：
# Interface: TenGigabitEthernet0/0/0
#
# RX Queue 0:
#   Packets: 12345678
#   Bytes: 987654321
#   Drops: 0
#   Errors: 0
#
# RX Queue 1:
#   Packets: 23456789
#   Bytes: 876543210
#   Drops: 10
#   Errors: 0
#
# ...

# 负载均衡分析
# 如果某个队列明显比其他队列多，说明 RSS 不均衡
```

## 4. RSS 负载均衡

### 4.1 均衡性评估

```bash
# 检查 RSS 均衡性
# 收集所有队列的包数

queues=(0 1 2 3 4 5 6 7)
stats=()

for q in "${queues[@]}"; do
    pkts=$(cat /sys/class/net/eth0/queues/rx-$q/packets)
    stats+=($pkts)
done

# 计算平均值和标准差
sum=0
for s in "${stats[@]}"; do
    sum=$((sum + s))
done
avg=$((sum / ${#stats[@]}))

# 计算方差
variance=0
for s in "${stats[@]}"; do
    diff=$((s - avg))
    variance=$((variance + diff * diff))
done
variance=$((variance / ${#stats[@]}))

# 标准差
stddev=$(echo "sqrt($variance)" | bc)

# 均衡性指标（越小越均衡）
balance_ratio=$(echo "scale=4; $stddev / $avg" | bc)

echo "Average: $avg, StdDev: $stddev, Balance: $balance_ratio"

# 判断标准：
# balance_ratio < 0.1: 良好
# balance_ratio < 0.2: 可接受
# balance_ratio >= 0.2: 不均衡，需要调整
```

### 4.2 不均衡原因

```
┌─────────────────────────────────────────────────────────────┐
│                 RSS 不均衡常见原因                            │
│                                                              │
│  1. Hash 冲突                                                │
│     - 大量流映射到同一队列                                    │
│     - 解决：更换 RSS key                                     │
│                                                              │
│  2. 流数量少于队列数                                          │
│     - 只有几条活跃流，分布不均                                │
│     - 解决：等待流数量增加，或减少队列数                      │
│                                                              │
│  3. Indirection table 配置不当                               │
│     - 某些队列被映射多次                                      │
│     - 解决：重新配置 indirection table                       │
│                                                              │
│  4. 非对称流量模式                                            │
│     - 单向大流（如视频流）分布不均                            │
│     - 解决：使用flow-based 负载均衡                          │
└─────────────────────────────────────────────────────────────┘
```

### 4.3 Indirection Table 调优

```bash
# 查看当前 indirection table
ethtool -x eth0

# 示例：
# RX flow hash indirection table:
# 0: 0  1: 1  2: 2  3: 3
# 4: 0  5: 1  6: 2  7: 3
# ...

# 设置 indirection table（每个队列出现相同次数）
# 8 队列，64 entries，每个队列 8 次
for i in $(seq 0 63); do
    queue=$((i % 8))
    echo $queue > /sys/class/net/eth0/queues/rx-$i/rps_cpus
done

# 或者使用脚本
python3 << 'EOF'
import os

num_queues = 8
table_size = 64
entries_per_queue = table_size // num_queues

for i in range(table_size):
    queue = i // entries_per_queue
    with open(f'/sys/class/net/eth0/queues/rx-{i}/rps_cpus', 'w') as f:
        f.write(str(1 << queue))
EOF
```

### 4.4 更换 RSS Key

```bash
# 生成新的 RSS key
openssl rand -hex 40 > /tmp/new_rss_key.txt

# 应用新 key
ethtool -X eth0 key $(cat /tmp/new_rss_key.txt)

# 验证
ethtool -x eth0

# 注意：更换 RSS key 会暂时影响流量分发
# 确保在维护窗口操作
```

## 5. VPP RSS 实现

### 5.1 RSS 数据结构

```c
// VPP RSS 实现

typedef struct {
    u8   enabled;              // RSS 是否启用
    u32  hash_function;         // 哈希函数
    u8   hash_fields;          // 哈希字段 mask
    u32  num_queues;           // 队列数量
    u16  indirection_table[64]; // indirection table
    u8   key[40];              // RSS key
} rss_config_t;

// 每个 worker 的 RSS 信息
typedef struct {
    u32   queue_id;           // 绑定的 RX 队列
    u64   packets_processed;  // 处理的包数
    u64   bytes_processed;    // 处理的字节数
} worker_rss_info_t;
```

### 5.2 RSS 初始化

```c
// RSS 初始化代码

static clib_error_t *
rss_init (vnet_main_t *vnm, vlib_main_t *vm)
{
    rss_config_t *rss = &rss_main;

    // 从 NIC 读取 RSS 能力
    rss->num_queues = vnet_hw_interface_get_rx_queue_count();

    // 读取当前 RSS key
    if (dpdk_get_rss_key(sw_if_index, rss->key, sizeof(rss->key)) != 0) {
        // 使用默认 key
        memcpy(rss->key, default_toeplitz_key, sizeof(default_toeplitz_key));
    }

    // 初始化 indirection table
    for (int i = 0; i < 64; i++) {
        rss->indirection_table[i] = i % rss->num_queues;
    }

    // 启用 RSS
    rss->enabled = 1;
    rss->hash_fields = RSS_HASH_FIELDS_5_TUPLE;

    return 0;
}
```

### 5.3 RSS 包分发

```c
// RSS 包分发逻辑

always_inline u32
rss_dispatch (vlib_main_t *vm, vlib_buffer_t **b, u32 n_buffers)
{
    vlib_buffer_t *buf;
    u32 queue_indices[8];
    u32 n_per_queue[8] = {0};
    u32 *to_next[8];

    // 收集每个包应该去的队列
    for (u32 i = 0; i < n_buffers; i++) {
        buf = b[i];
        ip4_header_t *ip = vlib_buffer_get_current(buf);

        u32 hash = rss_calculate_hash(ip, buf);
        u32 queue = hash % rss_main.num_queues;

        queue_indices[i] = queue;
        n_per_queue[queue]++;
    }

    // 分配每个队列的输出缓冲
    for (u32 q = 0; q < rss_main.num_queues; q++) {
        if (n_per_queue[q] > 0) {
            // 分配连续的 buffer 区域给这个队列
            to_next[q] = vlib_buffer_alloc(vm, n_per_queue[q]);
        }
    }

    // 按队列分发包
    for (u32 i = 0; i < n_buffers; i++) {
        u32 q = queue_indices[i];
        vlib_buffer_copy_args_t args = {
            .src = b[i],
            .dst = to_next[q]++
        };
        vlib_buffer_copy(vm, &args);
    }

    // 分发到各 worker
    for (u32 q = 0; q < rss_main.num_queues; q++) {
        if (n_per_queue[q] > 0) {
            // 发送到 worker q 的 graph
            dispatch_to_node(vm, worker_node[q], to_next[q], n_per_queue[q]);
        }
    }

    return n_buffers;
}
```

### 5.4 RSS 与 VPP Node 集成

```c
// 在 dpdk-input node 中使用 RSS

VLIB_NODE_FUNCTION_MULTIARCH(dpdk_input_node)
{
    vlib_buffer_t *bufs[VLIB_FRAME_SIZE], **b = bufs;
    u32 n_rx, n_left;
    u32 nexts[VLIB_FRAME_SIZE];

    // 从 NIC 接收包
    n_rx = dpdk_rx_queue_pop(vm, rx_queue_id, b, VLIB_FRAME_SIZE);

    if (n_rx == 0)
        return 0;

    // 应用 RSS
    if (rss_enabled) {
        u32 *hash_values = vec_allocate(n_rx);

        for (u32 i = 0; i < n_rx; i++) {
            hash_values[i] = rss_calculate_hash_for_buffer(b[i]);
        }

        // 按队列分类
        rss_classify_and_dispatch(vm, b, nexts, hash_values, n_rx);

        vec_free(hash_values);
    } else {
        // 非 RSS 模式：所有包发送到同一队列
        for (u32 i = 0; i < n_rx; i++) {
            nexts[i] = 0; // 默认 next
        }
    }

    // 分发到下一节点
    vlib_dispatch(vm, b, nexts, n_rx);

    return n_rx;
}
```

## 6. Flow-Aware 负载均衡

### 6.1 Flow-based vs Packet-based

```
┌─────────────────────────────────────────────────────────────┐
│              Flow-based vs Packet-based                    │
│                                                              │
│   Packet-based (RSS):                                        │
│   packet 1 → queue 0                                        │
│   packet 2 → queue 1                                        │
│   packet 3 → queue 2                                        │
│   问题：同一 flow 的包可能分散到不同队列                     │
│                                                              │
│   Flow-based:                                               │
│   flow A (packets 1,3,5...) → queue 0                       │
│   flow B (packets 2,4,6...) → queue 1                       │
│   优点：同一 flow 的包有序处理                               │
└─────────────────────────────────────────────────────────────┘
```

### 6.2 VPP Flow-based 均衡

```bash
# 启用 flow-based 负载均衡
vppctl set load-balance flow-based

# 查看 flow 统计
vppctl show flow

# 示例输出：
# Flow-based LB:
#   Active flows: 50000
#   Flow table size: 131072
#
#   Flow distribution:
#     Queue 0: 12500 flows
#     Queue 1: 12500 flows
#     Queue 2: 12500 flows
#     Queue 3: 12500 flows
```

### 6.3 Flow Table 配置

```bash
# startup.conf 中的 flow table 配置
dpdk {
    # Flow table 大小
    flow-table-size 131072

    # Flow timeout (秒)
    flow-timeout 300
}

# 或者运行时配置
vppctl set flow table-size 262144
vppctl set flow timeout 600
```

### 6.4 Flow-based 实现

```c
// Flow table 数据结构

typedef struct {
    u32   flow_id;           // flow hash
    u32   queue_id;          // 分配的队列
    u64   last_seen;         // 上次包时间
    u64   packet_count;      // 包计数
    u64   byte_count;        // 字节计数
    u8    state;             // ACTIVE/TIMEOUT
} flow_entry_t;

typedef struct {
    flow_entry_t *entries;
    u32          table_size;
    u32          active_flows;
    u32          hash_mask;
} flow_table_t;

// Flow lookup
always_inline flow_entry_t *
flow_lookup (flow_table_t *ft, vlib_buffer_t *b)
{
    ip4_header_t *ip = vlib_buffer_get_current(b);

    // 计算 flow hash (5-tuple)
    u32 hash = symmetric_hash(
        ip->src_address.as_u32,
        ip->dst_address.as_u32,
        get_l4_src_port(b),
        get_l4_dst_port(b),
        ip->protocol
    );

    // 查找 flow table
    u32 index = hash & ft->hash_mask;

    // 检查是否命中
    if (ft->entries[index].flow_id == hash) {
        return &ft->entries[index];
    }

    // Flow 不存在，创建新 flow
    return flow_create(ft, hash, b);
}

// Flow 创建
always_inline flow_entry_t *
flow_create (flow_table_t *ft, u32 hash, vlib_buffer_t *b)
{
    u32 index = hash & ft->hash_mask;

    // 选择最少使用的队列
    u32 queue = select_least_loaded_queue();

    // 创建 flow entry
    flow_entry_t *entry = &ft->entries[index];
    entry->flow_id = hash;
    entry->queue_id = queue;
    entry->last_seen = clib_time_now();
    entry->packet_count = 1;
    entry->state = FLOW_ACTIVE;

    ft->active_flows++;

    return entry;
}
```

## 7. 多队列性能优化

### 7.1 队列数选择

```bash
# 选择队列数的考虑因素

# 1. CPU 核心数
# 建议：队列数 = CPU 核心数（或略少）

# 2. NIC 能力
# 查看 NIC 支持的最大队列数
ethtool -l eth0

# 示例输出：
# Channel parameters for eth0:
# Pre-set maximums:
# RX:    16
# TX:    16
# Other:    0
# Combined:  16

# Current: 8 queues

# 3. 流量特征
# 小包多 → 更多队列，减少锁竞争
# 大流多 → 适当队列，配合 flow-based LB
```

### 7.2 队列调度优化

```c
// 队列调度优化示例

typedef struct {
    u32 queue_id;
    u64 packets;
    u64 bytes;
    u64 last_poll_time;
} queue_stats_t;

queue_stats_t queue_stats[16];

// 公平轮询调度
always_inline u32
fair_poll_scheduler (void)
{
    static u32 current_queue = 0;

    // 找到下一个有数据的队列
    for (u32 attempt = 0; attempt < num_queues; attempt++) {
        u32 q = (current_queue + attempt) % num_queues;

        if (queue_stats[q].packets > 0) {
            current_queue = (q + 1) % num_queues;
            return q;
        }
    }

    // 没有队列有数据，等待
    return 0xFFFFFFFF;
}

// 加权公平队列调度
always_inline u32
weighted_fair_scheduler (u32 weights[])
{
    static u32 current_queue = 0;
    static u32 *credits = NULL;

    // 初始化
    if (credits == NULL) {
        credits = vec_allocate(num_queues);
        for (u32 i = 0; i < num_queues; i++) {
            credits[i] = weights[i];
        }
    }

    // 找到有 credits 的队列
    for (u32 attempt = 0; attempt < num_queues; attempt++) {
        u32 q = (current_queue + attempt) % num_queues;

        if (credits[q] > 0) {
            credits[q]--;
            current_queue = (q + 1) % num_queues;
            return q;
        }
    }

    // 重置 credits
    for (u32 i = 0; i < num_queues; i++) {
        credits[i] = weights[i];
    }

    return 0;
}
```

### 7.3 中断负载均衡

```bash
# 脚本：自动均衡中断到 CPU

#!/bin/bash
# balance_irqs.sh

INTERFACE=$1
NUM_QUEUES=8

# 获取 CPU 数量
NUM_CPUS=$(nproc)

echo "Balancing $NUM_QUEUES queues across $NUM_CPUS CPUs"

for ((q=0; q<NUM_QUEUES; q++)); do
    # 计算目标 CPU
    CPU=$((q % NUM_CPUS))

    # 获取 IRQ 号
    IRQ=$(grep -m 1 "$INTERFACE.*queue-$q" /proc/interrupts | awk '{print $1}' | tr -d ':')

    if [ -n "$IRQ" ]; then
        # 设置 CPU 亲和性
        MASK=$((1 << CPU))
        echo "Queue $q (IRQ $IRQ) → CPU $CPU (mask $MASK)"
        echo $MASK > /proc/irq/$IRQ/smp_affinity_list
    fi
done

echo "Done. Check /proc/interrupts to verify."
```

### 7.4 NUMA 感知分布

```bash
# 查看 NUMA 节点
lscpu | grep -E 'NUMA|Node'

# 查看 NIC 所在的 NUMA
cat /sys/class/net/eth0/device/numa_node

# 配置 RSS 只使用本地 CPU
# 假设 NIC 在 NUMA 0

# 获取 NUMA 0 的 CPU 列表
CPUS_NUMA0=$(ls /sys/devices/system/node/node0/cpu* | grep -oE 'cpu[0-9]+' | sed 's/cpu//' | tr '\n' ',' | sed 's/,$//')

# 配置 RPS（Receive Packet Steering）
for q in /sys/class/net/eth0/queues/rx-*; do
    echo $CPUS_NUMA0 > $q/rps_cpus
done

# 验证
for q in /sys/class/net/eth0/queues/rx-*; do
    echo "Queue $(basename $q): $(cat $q/rps_cpus)"
done
```

## 8. RSS 故障排除

### 8.1 常见问题

| 问题               | 症状               | 解决                                 |
| ------------------ | ------------------ | ------------------------------------ |
| **RSS 不均衡**     | 某个队列包数明显多 | 更换 RSS key，重配 indirection table |
| **连接分裂**       | TCP 重传多         | 确认使用对称 RSS                     |
| **丢包**           | 队列 drop 计数器高 | 增加队列深度                         |
| **CPU 利用率不均** | 部分 CPU 100%      | 重新分配队列亲和性                   |
| **哈希冲突**       | 大量流走同一队列   | 使用 flow-based LB                   |

### 8.2 诊断命令

```bash
# 1. 检查 RSS 状态
ethtool -S eth0 | grep -i rss

# 2. 检查队列统计
for q in $(seq 0 7); do
    echo "Queue $q: $(cat /sys/class/net/eth0/queues/rx-$q/packets)"
done

# 3. 检查中断分布
cat /proc/interrupts | grep eth0 | awk '{print $1, $NF}'

# 4. 检查 CPU 利用率
mpstat -P ALL 1

# 5. 抓包分析 flow 分布
tcpdump -i eth0 -c 10000 -enn | awk '{print $5}' | sort | uniq -c | sort -rn | head
```

### 8.3 修复步骤

```bash
#!/bin/bash
# fix_rss.sh - 修复 RSS 问题

set -e

INTERFACE=${1:-eth0}

echo "=== RSS Diagnostics & Fix ==="

# Step 1: 收集当前状态
echo "1. Current RSS config:"
ethtool -x $INTERFACE | head -20

# Step 2: 生成新的 RSS key
echo "2. Generating new RSS key..."
openssl rand -hex 40 > /tmp/new_rss_key

# Step 3: 应用新 key
echo "3. Applying new RSS key..."
ethtool -X $INTERFACE key $(cat /tmp/new_rss_key)

# Step 4: 重新配置 indirection table（均匀分布）
echo "4. Reconfiguring indirection table..."
NUM_QUEUES=$(ethtool -l $INTERFACE | grep "RX:" | head -1 | awk '{print $3}')
echo "Using $NUM_QUEUES queues"

# 5. 等待流量稳定
echo "5. Waiting 30s for traffic to stabilize..."
sleep 30

# 6. 验证
echo "6. Verifying balance..."
for q in $(seq 0 $((NUM_QUEUES-1))); do
    echo "Queue $q: $(cat /sys/class/net/$INTERFACE/queues/rx-$q/packets)"
done

echo "=== Done ==="
```

## 9. 总结

```
┌─────────────────────────────────────────────────────────────┐
│                  RSS 与多队列总结                            │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐  │
│  │                    关键概念                            │  │
│  │                                                        │  │
│  │  RSS: NIC 根据哈希自动分发包到队列                      │  │
│  │  对称 RSS: 双向流量走同一队列（VPP 必须）               │  │
│  │  多队列: 多个 RX/TX 队列，绑定到不同 CPU                │  │
│  └────────────────────────────────────────────────────────┘  │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐  │
│  │                    配置原则                            │  │
│  │                                                        │  │
│  │  队列数 ≈ CPU 核心数                                   │  │
│  │  队列绑定到本地 NUMA 的 CPU                            │  │
│  │  使用对称哈希（5-tuple）                               │  │
│  │  监控均衡性，不均衡时调整                              │  │
│  └────────────────────────────────────────────────────────┘  │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐  │
│  │                    优化方向                            │  │
│  │                                                        │  │
│  │  高吞吐: 增加队列数，启用 poll mode                     │  │
│  │  低延迟: 减少队列深度，使用 interrupt coalescing       │  │
│  │  均衡性: 定期更换 RSS key，检查 indirection table      │  │
│  └────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

---

> [!tip] 最佳实践
>
> 1. 队列数建议设置为 CPU 核心数（或略少）
> 2. 确保 RSS 是对称的，否则 TCP 连接会分裂
> 3. 定期检查队列均衡性，单队列包数不应超过平均值 20%
> 4. NUMA 场景下，确保队列绑定到 NIC 所在 socket 的 CPU

> [!warning] 注意事项
>
> - RSS 不均衡时先检查流量是否足够多（流数 >> 队列数）
> - 更换 RSS key 会短暂影响流量分布
> - 队列绑定需要系统级配置，VPP 自身不管理 IRQ 亲和性
> - Flow-based LB 会消耗更多内存，需要权衡
