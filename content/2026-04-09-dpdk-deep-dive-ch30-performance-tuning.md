---
title: "DPDK 深度探索 (三十)：性能调优——Batching、RSS、Flow Director"
date: 2026-04-09
tags: [dpdk, series, performance, batching, rss, flow-director, optimization, receive-scaling, swx-pipeline]
description: "深入理解 DPDK 性能调优——Batching 策略、RSS (Receive Side Scaling)、Flow Director、队列优化、性能调优清单"
---

> [!info] DPDK 深度探索系列
> 0. [[2026-04-09-dpdk-deep-dive-series-index|全栈学习路径总览]]
> 1-29. 前二十九章已完成
> 30. **第三十章：性能调优——Batching、RSS、Flow Director**

---

## 1. 概述：性能调优金字塔

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        性能调优金字塔                                       │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│                              ▲                                              │
│                             /│\                                             │
│                            / │ \                                            │
│                           /  │  \                                           │
│                          /   │   \                                          │
│                         /────│────\                                         │
│                        /     │     \                                        │
│                       /      │      \                                       │
│                      ▼───────┴───────▼                                      │
│                                                                             │
│  L5: 算法/架构优化                                                         │
│  ────────────────────                                                      │
│  - 数据结构选择 (hash vs trie)                                            │
│  - 批处理流水线设计                                                        │
│  - 异步 vs 同步                                                           │
│                                                                             │
│  L4: 核亲和性/拓扑优化                                                      │
│  ───────────────────────                                                   │
│  - NUMA 亲和性 (Ch26)                                                      │
│  - lcore role 绑定 (Ch26)                                                  │
│  - HT/SMT 利用                                                             │
│                                                                             │
│  L3: 内存优化                                                             │
│  ─────────────                                                             │
│  - Cache 优化 (Ch25)                                                       │
│  - Hugepage (Ch2)                                                         │
│  - DMA/零拷贝 (Ch27)                                                       │
│                                                                             │
│  L2: 同步/锁优化                                                          │
│  ───────────────                                                           │
│  - Spinlock vs RCU (Ch28)                                                 │
│  - per-lcore 数据                                                         │
│  - 无锁数据结构                                                            │
│                                                                             │
│  L1: 基本配置优化                                                         │
│  ──────────────────                                                        │
│  - Batching (批量处理)                                                     │
│  - RSS (负载均衡)                                                          │
│  - Flow Director (流分类)                                                  │
│  - 队列/描述符大小                                                        │
│  - 中断 vs 轮询                                                            │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Batching (批量处理)

### 2.1 为什么需要 Batching

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        Batching 原理                                       │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  问题: 每次操作都有固定开销                                                  │
│  ────                                                                    │
│                                                                             │
│  单包处理:                                                                 │
│  ┌─────────────────────────────────────────────────────────────────────┐ │
│  │  for each packet:                                                  │ │
│  │      rx_burst(1 packet)    ← 函数调用 + 参数检查                   │ │
│  │      process(packet)       ← 小批量计算                              │ │
│  │      tx_burst(1 packet)    ← 函数调用 + 可能的锁                     │ │
│  └─────────────────────────────────────────────────────────────────────┘ │
│  总开销 = N × (rx_call + tx_call)                                         │
│                                                                             │
│  ─────────────────────────────────────────────────────────────────────────  │
│                                                                             │
│  批量处理:                                                                 │
│  ┌─────────────────────────────────────────────────────────────────────┐ │
│  │  rx_burst(batch)           ← 一次调用处理 N 包                      │ │
│  │  for each packet in batch: │                                        │ │
│  │      process(packet)       │                                        │ │
│  │  tx_burst(batch)           ← 一次调用发送 N 包                       │ │
│  └─────────────────────────────────────────────────────────────────────┘ │
│  总开销 = rx_call + tx_call + N × process                                 │
│                                                                             │
│  节省: (N-1) × (rx_call + tx_call)                                         │
│                                                                             │
│  ─────────────────────────────────────────────────────────────────────────  │
│                                                                             │
│  性能对比 (理论):                                                          │
│                                                                             │
│  假设:                                                                    │
│  - rx_call 耗时: 200 ns                                                   │
│  - tx_call 耗时: 200 ns                                                   │
│  - 每包处理: 50 ns                                                        │
│                                                                             │
│  单包 (64B包):                                                            │
│  - 总时间/包 = 200 + 50 + 200 = 450 ns                                    │
│  - 吞吐 = 2.2 Gp/s (每核)                                                │
│                                                                             │
│  批量 32:                                                                 │
│  - 总时间/包 = (200 + 50×32 + 200) / 32 = 56.25 ns                       │
│  - 吞吐 = 17.8 Gp/s (每核)                                               │
│                                                                             │
│  增益: ~8x                                                                │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 2.2 DPDK Burst  API

```c
// DPDK Burst API

// RX burst - 批量接收
uint16_t
rte_eth_rx_burst(uint16_t port_id, uint16_t queue_id,
                  struct rte_mbuf **rx_pkts, uint16_t nb_pkts);

// 参数:
//   port_id: 端口 ID
//   queue_id: 队列 ID
//   rx_pkts: mbuf 指针数组 (输出)
//   nb_pkts: 最大接收数量
// 返回: 实际接收数量

// TX burst - 批量发送
uint16_t
rte_eth_tx_burst(uint16_t port_id, uint16_t queue_id,
                  struct rte_mbuf **tx_pkts, uint16_t nb_pkts);

// 参数:
//   tx_pkts: mbuf 指针数组 (输入)
//   nb_pkts: 发送数量
// 返回: 实际发送数量

// 示例: 基本 burst 处理
#define RX_BURST_SIZE 32
#define TX_BURST_SIZE 32

struct rte_mbuf *rx_mbufs[RX_BURST_SIZE];
struct rte_mbuf *tx_mbufs[TX_BURST_SIZE];

static void
packet_process_loop(void *arg)
{
    uint16_t port_id = *(uint16_t *)arg;

    while (!quit) {
        // 批量接收
        uint16_t nb_rx = rte_eth_rx_burst(port_id, 0, rx_mbufs, RX_BURST_SIZE);

        if (nb_rx == 0)
            continue;

        // 处理
        uint16_t nb_tx = 0;
        for (uint16_t i = 0; i < nb_rx; i++) {
            if (process_packet(rx_mbufs[i]) == 0) {
                tx_mbufs[nb_tx++] = rx_mbufs[i];
            } else {
                rte_pktmbuf_free(rx_mbufs[i]);
            }
        }

        // 批量发送
        if (nb_tx > 0) {
            uint16_t sent = rte_eth_tx_burst(port_id, 0, tx_mbufs, nb_tx);

            // 释放未发送的
            for (uint16_t i = sent; i < nb_tx; i++) {
                rte_pktmbuf_free(tx_mbufs[i]);
            }
        }
    }
}
```

### 2.3 批量优化策略

```c
// 策略 1: 动态批量大小

// 根据负载动态调整 burst size
#define MIN_BURST 16
#define MAX_BURST 64
#define BURST_THRESHOLD 0.8  // 80% 利用率时增加

static uint16_t
adaptive_rx_burst(uint16_t port_id, uint16_t queue,
                   struct rte_mbuf **mbufs, uint16_t max_burst)
{
    static __thread uint16_t current_burst = MAX_BURST;
    static __thread uint64_t last_check = 0;
    static __thread uint64_t hit_count = 0;

    uint64_t now = rte_rdtsc();

    // 每 1M cycles 检查一次
    if (now - last_check > 1000000) {
        if (hit_count > max_burst * BURST_THRESHOLD) {
            current_burst = RTE_MIN(current_burst + 8, MAX_BURST);
        } else {
            current_burst = RTE_MAX(current_burst - 8, MIN_BURST);
        }
        hit_count = 0;
        last_check = now;
    }

    uint16_t nb = rte_eth_rx_burst(port_id, queue, mbufs, current_burst);

    if (nb >= current_burst * BURST_THRESHOLD)
        hit_count += nb;

    return nb;
}

// 策略 2: Pipeline Batching

// 将处理分成多个阶段，每阶段批量处理
struct packet_batch {
    struct rte_mbuf *mbufs[64];
    uint16_t count;

    // 元数据
    uint16_t ports[64];
    uint8_t proto[64];
};

static void
batch_init(struct packet_batch *batch)
{
    batch->count = 0;
}

static void
batch_add(struct packet_batch *batch, struct rte_mbuf *m)
{
    batch->mbufs[batch->count++] = m;
}

static void
batch_process_stage1(struct packet_batch *batch)
{
    // Stage 1: 解析 header，分类
    for (int i = 0; i < batch->count; i++) {
        struct rte_mbuf *m = batch->mbufs[i];
        struct ether_hdr *eth = rte_pktmbuf_mtod(m, struct ether_hdr *);

        batch->ports[i] = m->port;

        if (eth->ether_type == rte_cpu_to_be_16(ETHER_TYPE_IPv4)) {
            struct ipv4_hdr *iph = (struct ipv4_hdr *)(eth + 1);
            batch->proto[i] = iph->next_proto_id;
        }
    }
}

static void
batch_process_stage2(struct packet_batch *batch)
{
    // Stage 2: 基于分类的处理
    for (int i = 0; i < batch->count; i++) {
        switch (batch->proto[i]) {
        case IPPROTO_TCP:
            process_tcp(batch->mbufs[i]);
            break;
        case IPPROTO_UDP:
            process_udp(batch->mbufs[i]);
            break;
        default:
            process_other(batch->mbufs[i]);
        }
    }
}

static void
batch_tx(struct packet_batch *batch)
{
    uint16_t sent = rte_eth_tx_burst(batch->ports[0], 0,
                                       batch->mbufs, batch->count);
    // 处理未发送
}

// 策略 3: Zero-Copy Batching

// 避免在批处理中复制
static void
zero_copy_batch_process(struct rte_mbuf **mbufs, uint16_t count)
{
    struct rte_mbuf *tx_bufs[64];
    uint16_t tx_count = 0;

    for (int i = 0; i < count; i++) {
        // 就地修改，不复制
        modify_in_place(mbufs[i]);

        if (should_forward(mbufs[i])) {
            tx_bufs[tx_count++] = mbufs[i];
        } else {
            rte_pktmbuf_free(mbufs[i]);
        }
    }

    if (tx_count > 0) {
        rte_eth_tx_burst(0, 0, tx_bufs, tx_count);
    }
}
```

### 2.4 Burst 调优参数

```bash
# burst size 设置 (testpmd)
./dpdk-testpmd -l 0-7 -n 4 -- -i \
    --rxq 4 --txq 4 \
    --rxd 512 --txd 512 \      # 描述符数量
    --burst 32 \               # burst 大小
    --mbuf-size 2048 \         # mbuf 数据区大小
    --max-pkt-len 9000         # 最大包长

# 推荐的 burst 设置
# 小包 (64-128B): burst=32, rxq=4-8
# 大包 (1500B+):  burst=16, rxq=2-4
# 混合:           burst=32, rxq=4

# rx/tx descriptors
# 更多描述符 = 更多 buffering，但更多内存占用
# 推荐: rxqd=512, txqd=512 (DPDK 默认)
```

---

## 3. RSS (Receive Side Scaling)

### 3.1 RSS 原理

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        RSS 原理                                            │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  问题: 单队列网卡成为瓶颈                                                    │
│  ────                                                                    │
│                                                                             │
│       ┌─────────────────────────────────────────────────┐                 │
│       │                    NIC                          │                 │
│       │                                                  │                 │
│       │    ┌──────────────────────────────────────┐   │                 │
│       │    │           RSS Indirection Table       │   │                 │
│       │    │  [0,1,2,3,0,1,2,3,0,1,2,3,...]        │   │                 │
│       │    └──────────────────────────────────────┘   │                 │
│       │                        │                         │                 │
│       │    ┌────────┬────────┬────────┬────────┐        │                 │
│       │    │        │        │        │        │        │                 │
│       │    ▼        ▼        ▼        ▼        │        │                 │
│       │  Queue0  Queue1   Queue2  Queue3      │        │                 │
│       └────┼────────┼────────┼────────┼────────┘        │                 │
│            │        │        │        │                 │                 │
│            ▼        ▼        ▼        ▼                 │                 │
│         ┌──────────────────────────────────────────┐   │                 │
│         │            CPU Core 分配                  │   │                 │
│         │  Core0 ← Queue0 | Core1 ← Queue1        │   │                 │
│         │  Core2 ← Queue2 | Core3 ← Queue3        │   │                 │
│         └──────────────────────────────────────────┘   │                 │
│                                                                             │
│  RSS 计算流程:                                                              │
│  ─────────────                                                              │
│                                                                             │
│  1. Toeplitz Hash 计算                                                    │
│     ┌─────────────────────────────────────────────────────────────────┐   │
│     │  Hash = Toeplitz(SecretKey, Tuple)                              │   │
│     │                                                                 │   │
│     │  Tuple = (src_ip, dst_ip, src_port, dst_port, protocol)       │   │
│     │                                                                 │   │
│     │  Result = 32-bit or 64-bit hash value                         │   │
│     └─────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  2. Indirection Table 映射                                                │
│     ┌─────────────────────────────────────────────────────────────────┐   │
│     │  Queue_Index = Hash & (Table_Size - 1)                         │   │
│     │                                                                 │   │
│     │  Table_Size 通常是 128 或 256                                  │   │
│     │  Table[i] 指定队列索引 (0 to N-1)                             │   │
│     └─────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  3. 多队列分发                                                             │
│     - 同一流的包 → 同一队列 (保持顺序)                                     │
│     - 不同流的包 → 不同队列 (负载均衡)                                     │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 3.2 RSS 配置

```c
// RSS 配置 API

#include <rte_ethdev.h>

// 启用 RSS
int
configure_rss(struct rte_port *port)
{
    struct rte_eth_conf port_conf = {
        .rxmode = {
            .mq_mode = RTE_ETH_MQ_RX_RSS,  // 启用 RSS
        },
        .rx_adv_conf = {
            .rss_conf = {
                .rss_key = NULL,  // NULL = 使用默认 key
                .rss_key_len = 40,  // 通常 40 字节
                .rss_hf = RTE_ETH_RSS_IP |           // IP 哈希
                          RTE_ETH_RSS_TCP |           // TCP 哈希
                          RTE_ETH_RSS_UDP |           // UDP 哈希
                          RTE_ETH_RSS_SCTP |          // SCTP
                          RTE_ETH_RSS_TUNNEL,        // Tunnel (VXLAN)
            },
        },
    };

    return rte_eth_dev_configure(port->id, rxq_count, txq_count, &port_conf);
}

// 设置 RSS key
int
set_rss_key(uint16_t port_id, uint8_t *key, uint8_t key_len)
{
    return rte_eth_dev_rss_hash_key_set(port_id, key, key_len);
}

// 设置 RSS hash 字段
int
set_rss_hash_fields(uint16_t port_id, uint64_t rss_hf)
{
    return rte_eth_dev_rss_hash_update(port_id, rss_hf);
}

// 获取 RSS 配置
int
get_rss_conf(uint16_t port_id, struct rte_eth_rss_conf *rss_conf)
{
    return rte_eth_dev_rss_conf_get(port_id, rss_conf);
}

// 设置 Indirection Table
int
set_rss_indirection_table(uint16_t port_id, uint16_t *table, uint16_t size)
{
    struct rte_eth_rss_indir_table_conf conf = {
        .table = table,
        .table_size = size,
    };

    return rte_eth_dev_rss_indir_table_update(port_id, &conf);
}

// 示例: 完整 RSS 配置
void
init_rss(uint16_t port_id, uint16_t nb_queues)
{
    // 1. 配置 RSS
    struct rte_eth_rss_conf rss_conf = {
        .rss_key = rss_key_default,  // 40 字节 secret key
        .rss_key_len = 40,
        .rss_hf = RTE_ETH_RSS_IP |
                  RTE_ETH_RSS_TCP |
                  RTE_ETH_RSS_UDP,
    };

    rte_eth_dev_configure(port_id, nb_queues, nb_queues, &(struct rte_eth_conf){
        .rxmode = {
            .mq_mode = RTE_ETH_MQ_RX_RSS,
        },
        .rx_adv_conf = {
            .rss_conf = rss_conf,
        },
    });

    // 2. 设置 indirection table (每个队列等权重)
    uint16_t reta_size = rte_eth_dev_info_get(port_id)->reta_size;
    uint16_t *reta = malloc(reta_size * sizeof(uint16_t));

    for (int i = 0; i < reta_size; i++) {
        reta[i] = i % nb_queues;
    }

    struct rte_eth_rss_indir_table_conf indir_conf = {
        .table = reta,
        .table_size = reta_size,
        .mask = (1ULL << nb_queues) - 1,  // nb_queues 位掩码
    };

    rte_eth_dev_rss_indir_table_update(port_id, &indir_conf);

    free(reta);
}

// 默认 RSS key (Intel 提供)
static uint8_t rss_key_default[40] = {
    0x6D, 0x5A, 0x6D, 0x5A, 0x6D, 0x5A, 0x6D, 0x5A,
    0x6D, 0x5A, 0x6D, 0x5A, 0x6D, 0x5A, 0x6D, 0x5A,
    0x6D, 0x5A, 0x6D, 0x5A, 0x6D, 0x5A, 0x6D, 0x5A,
    0x6D, 0x5A, 0x6D, 0x5A, 0x6D, 0x5A, 0x6D, 0x5A,
    0x6D, 0x5A, 0x6D, 0x5A, 0x6D, 0x5A, 0x6D, 0x5A,
};
```

### 3.3 RSS hash 处理

```c
// 处理 RSS hash

// 从 mbuf 获取 RSS hash
static inline uint32_t
get_rss_hash(struct rte_mbuf *m)
{
    return m->hash.rss;
}

// 从 mbuf 获取 RSS hash 类型
static inline uint32_t
get_rss_hash_type(struct rte_mbuf *m)
{
    return m->hash.fdir.hash;
}

// 示例: 基于 RSS hash 的负载均衡
void
rss_based_process(struct rte_mbuf **mbufs, uint16_t count)
{
    // RSS 已经将同一流的包分到同一队列
    // 这里按队列处理即可

    for (int i = 0; i < count; i++) {
        uint32_t flow_hash = get_rss_hash(mbufs[i]);

        // 可以使用 hash 做负载均衡
        uint16_t worker_id = flow_hash % num_workers;

        // 或者直接处理
        process_packet(mbufs[i]);
    }
}

// 示例: 基于 5-tuple 的流表查找
struct flow_entry {
    uint32_t src_ip;
    uint32_t dst_ip;
    uint16_t src_port;
    uint16_t dst_port;
    uint8_t proto;
    uint32_t action;
};

static struct flow_entry *
flow_lookup_by_mbuf(struct rte_mbuf *m, struct rte_hash *flow_table)
{
    struct ipv4_hdr *iph = rte_pktmbuf_mtod_offset(m, struct ipv4_hdr *,
                                                     sizeof(struct ether_hdr));
    struct tcp_hdr *tcph;
    struct udp_hdr *udph;

    struct flow_key key = {
        .src_ip = iph->src_addr,
        .dst_ip = iph->dst_addr,
    };

    if (iph->next_proto_id == IPPROTO_TCP) {
        tcph = (struct tcp_hdr *)((char *)iph + sizeof(*iph));
        key.src_port = tcph->src_port;
        key.dst_port = tcph->dst_port;
        key.proto = IPPROTO_TCP;
    } else if (iph->next_proto_id == IPPROTO_UDP) {
        udph = (struct udp_hdr *)((char *)iph + sizeof(*iph));
        key.src_port = udph->src_port;
        key.dst_port = udph->dst_port;
        key.proto = IPPROTO_UDP;
    }

    int32_t idx = rte_hash_lookup(flow_table, &key);

    if (idx >= 0) {
        return (struct flow_entry *)rte_hash_get_key(flow_table, idx);
    }

    return NULL;
}
```

### 3.4 常见 RSS 配置

```bash
# 查看 NIC RSS 支持
ethtool -x eth0

# 输出示例:
# RX flow hash indirection table for eth0:
# ...
# Preset value: 0x...

# 设置 RSS hash key
ethtool -X eth0 hfunc toeplitz西北  key 6d5a6d5a6d5a6d5a...

# 设置 indirection table
ethtool -X eth0 equal 4  # 4 个队列等权重

# 查看 RSS 配置
ethtool -n eth0

# DPDK RSS 配置选项
# RTE_ETH_RSS_IP         - IPv4/IPv6
# RTE_ETH_RSS_TCP        - TCP
# RTE_ETH_RSS_UDP        - UDP
# RTE_ETH_RSS_SCTP      - SCTP
# RTE_ETH_RSS_TUNNEL    - Tunnel (VXLAN, GRE)
# RTE_ETH_RSS_L2_PAYLOAD - L2 payload
# RTE_ETH_RSS_PORT      - 源/目标端口
# RTE_ETH_RSS_SVF       - Single VLAN filter
# RTE_ETH_RSS_DVF       - Double VLAN filter
```

---

## 4. Flow Director

### 4.1 Flow Director 原理

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        Flow Director 原理                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  Flow Director (Intel 82599 及以上):                                       │
│  ────────────────────────────────────────                                   │
│  - 精确匹配 5-tuple (或更多字段)                                           │
│  - 将特定流导向特定队列                                                     │
│  - 支持 Action: 接收、丢弃、重定向                                          │
│  - 支持 Mask: 可配置哪些字段参与匹配                                        │
│                                                                             │
│  与 RSS 的区别:                                                            │
│  ─────────────                                                              │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐ │
│  │     RSS                    │  Flow Director                         │ │
│  ├─────────────────────────────────────────────────────────────────────┤ │
│  │  Hash-based 分散           │  Exact match 精确分流                  │ │
│  │  负载均衡                   │  QoS/安全                              │ │
│  │  自动                      │  手动配置                              │ │
│  │  所有流共享规则            │  每个流独立规则                       │ │
│  │  无需 CPU                  │  小量 CPU 配置                         │ │
│  └─────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
│  Flow Director 工作流程:                                                   │
│  ─────────────────────                                                      │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐ │
│  │  1. 添加 Flow Director 规则                                          │ │
│  │     - 指定 5-tuple (src_ip, dst_ip, src_port, dst_port, proto)    │ │
│  │     - 指定目标队列                                                   │ │
│  │     - 指定 Action (接收/丢弃)                                        │ │
│  └─────────────────────────────────────────────────────────────────────┘ │
│                              │                                              │
│                              ▼                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐ │
│  │  2. NIC 硬件匹配                                                     │ │
│  │     - 每个包在 hardware 中匹配规则                                   │ │
│  │     - 匹配成功 → 发送到指定队列                                     │ │
│  │     - 匹配失败 → 按 RSS/普通方式处理                                │ │
│  └─────────────────────────────────────────────────────────────────────┘ │
│                              │                                              │
│                              ▼                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐ │
│  │  3. 应用程序在特定队列处理特定流                                    │ │
│  │     - 队列 0: TCP 流量                                             │ │
│  │     - 队列 1: UDP 流量                                             │ │
│  │     - 队列 2: HTTP 流量                                             │ │
│  │     - 队列 3: 其他                                                 │ │
│  └─────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 4.2 Flow Director API

```c
// Flow Director API

#include <rte_ethdev.h>
#include <rte_flow.h>

// Flow Director 过滤器配置
struct rte_eth_fdir_flow {
    enum rte_eth_flow_type flow_type;
    union {
        struct rte_eth_ipv4_flow ipv4;
        struct rte_eth_ipv4_tcp_flow ipv4_tcp;
        struct rte_eth_ipv4_udp_flow ipv4_udp;
        struct rte_eth_ipv6_flow ipv6;
        struct rte_eth_ipv6_tcp_flow ipv6_tcp;
        struct rte_eth_ipv6_udp_flow ipv6_udp;
    };
};

// Flow Director mask
struct rte_eth_fdir_masks {
    uint16_t vlan_mask;
    uint16_t src_mask_ipv4;      // IPv4 源地址掩码
    uint16_t dst_mask_ipv4;      // IPv4 目标地址掩码
    uint32_t src_mask_ipv6;      // IPv6 源地址掩码
    uint32_t dst_mask_ipv6;      // IPv6 目标地址掩码
    uint16_t src_port_mask;      // 源端口掩码
    uint16_t dst_port_mask;      // 目标端口掩码
};

// 添加 Flow Director 规则
int
rte_eth_dev_fdir_add_perfect_filter(uint16_t port_id,
                                      struct rte_eth_fdir_filter *filter,
                                      uint16_t rx_queue,
                                      uint8_t soft_id,
                                      uint32_t flags);

// 删除 Flow Director 规则
int
rte_eth_dev_fdir_remove_perfect_filter(uint16_t port_id,
                                         struct rte_eth_fdir_filter *filter);

// 更新 Flow Director 规则
int
rte_eth_dev_fdir_update_perfect_filter(uint16_t port_id,
                                         struct rte_eth_fdir_filter *filter,
                                         uint16_t rx_queue,
                                         uint8_t soft_id);

// 配置 Flow Director masks
int
rte_eth_dev_fdir_set_masks(uint16_t port_id,
                             struct rte_eth_fdir_masks *masks);

// 示例: 添加 TCP 流规则
int
add_tcp_flow_rule(uint16_t port_id, uint32_t src_ip, uint32_t dst_ip,
                   uint16_t src_port, uint16_t dst_port, uint16_t rx_queue)
{
    struct rte_eth_fdir_filter filter = {
        .filter_type = RTE_ETH_FILTER_FDIR,
        .flow_type = RTE_ETH_FLOW_TYPE_TCPv4,
        .flow.tcp4_flow = {
            .src_ip = src_ip,
            .dst_ip = dst_ip,
            .src_port = src_port,
            .dst_port = dst_port,
        },
    };

    return rte_eth_dev_fdir_add_perfect_filter(port_id, &filter,
                                                 rx_queue, 0, 0);
}

// 示例: 添加 UDP 流规则
int
add_udp_flow_rule(uint16_t port_id, uint32_t src_ip, uint32_t dst_ip,
                   uint16_t src_port, uint16_t dst_port, uint16_t rx_queue)
{
    struct rte_eth_fdir_filter filter = {
        .filter_type = RTE_ETH_FILTER_FDIR,
        .flow_type = RTE_ETH_FLOW_TYPE_UDPv4,
        .flow.udp4_flow = {
            .src_ip = src_ip,
            .dst_ip = dst_ip,
            .src_port = src_port,
            .dst_port = dst_port,
        },
    };

    return rte_eth_dev_fdir_add_perfect_filter(port_id, &filter,
                                                 rx_queue, 0, 0);
}

// 示例: 添加丢弃规则
int
add_drop_rule(uint16_t port_id, uint32_t src_ip, uint32_t dst_ip)
{
    struct rte_eth_fdir_filter filter = {
        .filter_type = RTE_ETH_FILTER_FDIR,
        .flow_type = RTE_ETH_FLOW_TYPE_UDPv4,
        .flow.udp4_flow = {
            .src_ip = src_ip,
            .dst_ip = dst_ip,
            .src_port = 0,
            .dst_port = 0,
        },
    };

    // 特殊处理: rx_queue = -1 表示丢弃
    return rte_eth_dev_fdir_add_perfect_filter(port_id, &filter,
                                                 0xFFFF, 0, RTE_ETH_FDIR_NO_REPORT_QUEUE);
}
```

### 4.3 rte_flow API (现代 API)

```c
// rte_flow API (DPDK 18.11+, 推荐)

#include <rte_flow.h>

// Flow 属性
struct rte_flow_attr {
    uint32_t group;       // Flow group (0-15)
    uint32_t priority;    // 优先级 (0 = 最高)
    uint32_t attr;         // RTE_FLOW_ATTR_*
};

// Flow 匹配模式
struct rte_flow_pattern {
    enum rte_flow_item_type type;
    union {
        struct rte_flow_item_ipv4 ipv4;
        struct rte_flow_item_ipv6 ipv6;
        struct rte_flow_item_tcp tcp;
        struct rte_flow_item_udp udp;
        struct rte_flow_item_eth eth;
        struct rte_flow_item_vlan vlan;
    };
};

// Flow 动作
struct rte_flow_action {
    enum rte_flow_action_type type;
    union {
        struct rte_flow_action_queue {
            uint16_t index;  // 队列索引
        } queue;
        struct rte_flow_action_drop {
            // 无字段，丢弃
        } drop;
        struct rte_flow_action_passthru {
            // 继续正常处理
        } passthru;
    };
};

// 创建 Flow
struct rte_flow *
rte_flow_create(uint16_t port_id,
                 const struct rte_flow_attr *attr,
                 const struct rte_flow_pattern *pattern,
                 const struct rte_flow_action *actions,
                 struct rte_flow_error *error);

// 验证 Flow 规则是否支持
int
rte_flow_validate(uint16_t port_id,
                   const struct rte_flow_attr *attr,
                   const struct rte_flow_pattern *pattern,
                   const struct rte_flow_action *actions,
                   struct rte_flow_error *error);

// 销毁 Flow
int
rte_flow_destroy(uint16_t port_id,
                  struct rte_flow *flow,
                  struct rte_flow_error *error);

// 刷新所有 Flow
int
rte_flow_flush(uint16_t port_id, struct rte_flow_error *error);

// 示例: 将 TCP 流量导向特定队列
struct rte_flow *
create_tcp_to_queue_flow(uint16_t port_id, uint16_t queue_id,
                          uint32_t src_ip, uint32_t dst_ip,
                          uint16_t src_port, uint16_t dst_port)
{
    struct rte_flow_attr attr = {
        .group = 0,      // 默认 group
        .priority = 0,   // 高优先级
        .ingress = 1,    // 入口流量
    };

    // 匹配模式
    struct rte_flow_pattern pattern[] = {
        {
            .type = RTE_FLOW_ITEM_TYPE_ETH,
            .spec = &(struct rte_flow_item_eth){
                .type = 0x0800,  // IPv4
            },
            .mask = &(struct rte_flow_item_eth){
                .type = 0xFFFF,
            },
        },
        {
            .type = RTE_FLOW_ITEM_TYPE_IPV4,
            .spec = &(struct rte_flow_item_ipv4){
                .hdr = {
                    .src_addr = src_ip,
                    .dst_addr = dst_ip,
                },
            },
            .mask = &(struct rte_flow_item_ipv4){
                .hdr = {
                    .src_addr = 0xFFFFFFFF,
                    .dst_addr = 0xFFFFFFFF,
                },
            },
        },
        {
            .type = RTE_FLOW_ITEM_TYPE_TCP,
            .spec = &(struct rte_flow_item_tcp){
                .hdr = {
                    .src_port = src_port,
                    .dst_port = dst_port,
                },
            },
            .mask = &(struct rte_flow_item_tcp){
                .hdr = {
                    .src_port = 0xFFFF,
                    .dst_port = 0xFFFF,
                },
            },
        },
        {
            .type = RTE_FLOW_ITEM_TYPE_END,
        },
    };

    // 动作
    struct rte_flow_action actions[] = {
        {
            .type = RTE_FLOW_ACTION_TYPE_QUEUE,
            .conf = &(struct rte_flow_action_queue){
                .index = queue_id,
            },
        },
        {
            .type = RTE_FLOW_ACTION_TYPE_END,
        },
    };

    // 验证
    if (rte_flow_validate(port_id, &attr, pattern, actions, NULL) != 0) {
        return NULL;
    }

    // 创建
    return rte_flow_create(port_id, &attr, pattern, actions, NULL);
}

// 示例: 丢弃特定 UDP 流
struct rte_flow *
create_udp_drop_flow(uint16_t port_id, uint32_t dst_ip, uint16_t dst_port)
{
    struct rte_flow_attr attr = {
        .group = 0,
        .priority = 0,
        .ingress = 1,
    };

    struct rte_flow_pattern pattern[] = {
        {
            .type = RTE_FLOW_ITEM_TYPE_ETH,
            .spec = &(struct rte_flow_item_eth){ .type = 0x0800 },
            .mask = &(struct rte_flow_item_eth){ .type = 0xFFFF },
        },
        {
            .type = RTE_FLOW_ITEM_TYPE_IPV4,
            .spec = &(struct rte_flow_item_ipv4){
                .hdr = { .dst_addr = dst_ip },
            },
            .mask = &(struct rte_flow_item_ipv4){
                .hdr = { .dst_addr = 0xFFFFFFFF },
            },
        },
        {
            .type = RTE_FLOW_ITEM_TYPE_UDP,
            .spec = &(struct rte_flow_item_udp){
                .hdr = { .dst_port = dst_port },
            },
            .mask = &(struct rte_flow_item_udp){
                .hdr = { .dst_port = 0xFFFF },
            },
        },
        {
            .type = RTE_FLOW_ITEM_TYPE_END,
        },
    };

    struct rte_flow_action actions[] = {
        {
            .type = RTE_FLOW_ACTION_TYPE_DROP,
        },
        {
            .type = RTE_FLOW_ACTION_TYPE_END,
        },
    };

    if (rte_flow_validate(port_id, &attr, pattern, actions, NULL) != 0) {
        return NULL;
    }

    return rte_flow_create(port_id, &attr, pattern, actions, NULL);
}

// 示例: 负载均衡 (RSS + Flow Director)
struct rte_flow *
create_rss_flow(uint16_t port_id, uint16_t *queues, int nb_queues)
{
    struct rte_flow_attr attr = {
        .group = 0,
        .priority = 1,  // 低于精确匹配
        .ingress = 1,
    };

    // 匹配所有 IPv4
    struct rte_flow_pattern pattern[] = {
        {
            .type = RTE_FLOW_ITEM_TYPE_ETH,
            .spec = &(struct rte_flow_item_eth){ .type = 0x0800 },
            .mask = &(struct rte_flow_item_eth){ .type = 0xFFFF },
        },
        {
            .type = RTE_FLOW_ITEM_TYPE_IPV4,
            .spec = NULL,  // 匹配所有
            .mask = NULL,
        },
        {
            .type = RTE_FLOW_ITEM_TYPE_END,
        },
    };

    struct rte_flow_action_rss rss_conf = {
        .types = RTE_ETH_RSS_IP | RTE_ETH_RSS_TCP | RTE_ETH_RSS_UDP,
        .key_len = 40,
        .queue_num = nb_queues,
        .queue = queues,
    };

    struct rte_flow_action actions[] = {
        {
            .type = RTE_FLOW_ACTION_TYPE_RSS,
            .conf = &rss_conf,
        },
        {
            .type = RTE_FLOW_ACTION_TYPE_END,
        },
    };

    if (rte_flow_validate(port_id, &attr, pattern, actions, NULL) != 0) {
        return NULL;
    }

    return rte_flow_create(port_id, &attr, pattern, actions, NULL);
}
```

---

## 5. 队列优化

### 5.1 队列数量选择

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        队列数量选择                                         │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  考虑因素:                                                                 │
│  ────────                                                                  │
│                                                                             │
│  1. CPU 核心数量                                                           │
│     - 每个队列通常绑定一个 lcore                                           │
│     - 队列数 ≤ lcore 数                                                    │
│                                                                             │
│  2. NIC 能力                                                               │
│     - 1G NIC: 通常 4-8 队列                                                │
│     - 10G NIC: 通常 16-32 队列                                             │
│     - 40G/100G NIC: 64+ 队列                                               │
│                                                                             │
│  3. 流量特征                                                               │
│     - 流数量: 更多流 = 更多队列                                             │
│     - 流大小: 大流可能独占队列                                              │
│                                                                             │
│  4. 软件开销                                                               │
│     - 每队列有独立 Rx/Tx descriptors                                      │
│     - 内存占用 = nb_queues × queue_size × desc_size                       │
│                                                                             │
│  推荐配置:                                                                 │
│  ──────────                                                                │
│                                                                             │
│  NIC         CPU Cores    Rx Queues    Tx Queues    每队列 Descriptor     │
│  ──────────────────────────────────────────────────────────────────────── │
│  10G          4            4            4            512                   │
│  10G          8            8            8            512                   │
│  40G          8            8            8            512                   │
│  40G          16           16           16           512                   │
│  100G         16           16           16           512                   │
│  100G         32           32           32           512                   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 5.2 描述符大小

```c
// 描述符大小配置

struct rte_eth_conf conf = {
    .rxmode = {
        .mq_mode = RTE_ETH_MQ_RX_RSS,
    },
};

struct rte_eth_dev_info dev_info;
rte_eth_dev_info_get(port_id, &dev_info);

// rx_desc_best: NIC 支持的最大值
// tx_desc_best: NIC 支持的最大值

// 配置描述符数量
int
configure_descriptors(uint16_t port_id, uint16_t nb_rx_desc, uint16_t nb_tx_desc)
{
    struct rte_eth_conf conf = {
        .rx_adv_conf = {
            .rss_conf = {
                .rss_key = NULL,
                .rss_hf = RTE_ETH_RSS_IP,
            },
        },
    };

    return rte_eth_dev_configure(port_id, rxq_count, txq_count, &conf);
}

// 设置每队列描述符数
int
setup_queues(uint16_t port_id)
{
    struct rte_eth_rxq_conf rxq_conf = {
        .rx_thresh = {
            .pthresh = 8,    // 预取阈值
            .hthresh = 8,    // 主机阈值
            .wthresh = 0,    // 写回阈值
        },
        .rx_free_thresh = 32,   // 批量释放 mbuf
        .rx_drop_en = 0,        // 不丢弃
    };

    struct rte_eth_txq_conf txq_conf = {
        .tx_thresh = {
            .pthresh = 32,   // 预取阈值
            .hthresh = 32,   // 主机阈值
            .wthresh = 0,    // 写回阈值
        },
        .tx_free_thresh = 32,   // 释放描述符阈值
        .tx_rs_thresh = 0,      // RS 阈值 (0 = 自动)
    };

    for (int i = 0; i < rxq_count; i++) {
        rte_eth_rx_queue_setup(port_id, i, nb_rx_desc,
                                 rte_eth_dev_socket_id(port_id),
                                 &rxq_conf,
                                 mbuf_pool[rte_eth_dev_socket_id(port_id)]);
    }

    for (int i = 0; i < txq_count; i++) {
        rte_eth_tx_queue_setup(port_id, i, nb_tx_desc,
                                 rte_eth_dev_socket_id(port_id),
                                 &txq_conf);
    }
}

// 阈值调优
void
tune_thresholds(void)
{
    // Rx thresholds
    // pthresh: 预取多少 descriptor
    // hthresh: 触发 DMA 的阈值
    // wthresh: 写回阈值 (0 = 每包)

    // 推荐:
    // 小包: pthresh=8, hthresh=8 (低延迟)
    // 大包: pthresh=16, hthresh=16 (高吞吐)

    // Tx thresholds
    // pthresh: 预取多少 free descriptor
    // hthresh: 触发 DMA 的阈值
    // wthresh: 写回阈值

    // tx_free_thresh: 多少 TX descriptor 后释放 mbuf
    // tx_rs_thresh: 多少 TX descriptor 后设置 RS (报告状态)
}
```

### 5.3 多队列分配策略

```c
// 多队列分配策略

// 策略 1: RSS (自动负载均衡)
void
allocate_rss_queues(uint16_t port_id)
{
    int num_cores = rte_lcore_count();
    int num_queues = num_cores;

    // RSS 会自动将流分散到各队列
    // 应用程序无需关心队列分配
}

// 策略 2: Flow Director (按流定向)
void
allocate_fdir_queues(uint16_t port_id)
{
    // 队列分配
    // 队列 0: 管理/控制流量
    // 队列 1: TCP 流量
    // 队列 2: UDP 流量
    // 队列 3: 其他

    // 添加 Flow Director 规则
    add_tcp_flow_rule(port_id, 0, 0, 0, 80, 1);  // HTTP → 队列 1
    add_tcp_flow_rule(port_id, 0, 0, 0, 443, 1); // HTTPS → 队列 1
    add_udp_flow_rule(port_id, 0, 0, 0, 53, 2);   // DNS → 队列 2
}

// 策略 3: Core 绑定 (NUMA 感知)
void
allocate_numa_queues(uint16_t port_id)
{
    int numa = rte_eth_dev_socket_id(port_id);

    // 分配本地 lcore
    unsigned *lcores = malloc(sizeof(unsigned) * num_queues);
    int count = 0;

    unsigned lcore_id;
    RTE_LCORE_FOREACH(lcore_id) {
        if (rte_lcore_to_socket_id(lcore_id) == numa && count < num_queues) {
            lcores[count++] = lcore_id;
        }
    }

    // 按 lcore 分配队列
    for (int i = 0; i < count; i++) {
        printf("Queue %d → lcore %d\n", i, lcores[i]);
    }
}

// 策略 4: 动态队列调度
struct queue_scheduler {
    uint16_t current;
    uint16_t *queues;
    uint16_t count;
};

static void
round_robin_next(struct queue_scheduler *s)
{
    s->current = (s->current + 1) % s->count;
}

static uint16_t
get_next_queue(struct queue_scheduler *s)
{
    uint16_t q = s->queues[s->current];
    round_robin_next(s);
    return q;
}
```

---

## 6. 中断与轮询

### 6.1 轮询 vs 中断

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        轮询 vs 中断                                        │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  轮询 (Polling):                                                           │
│  ───────────                                                                │
│  - CPU 持续检查 NIC 是否有包                                                │
│  - 优点: 低延迟、无中断开销                                                  │
│  - 缺点: CPU 占用高 (100%)                                                  │
│  - 适用: 高吞吐、短包、持续流量                                              │
│                                                                             │
│  中断 (Interrupt):                                                         │
│  ───────────                                                                │
│  - NIC 有包时触发中断                                                       │
│  - 优点: CPU 空闲时无开销                                                   │
│  - 缺点: 中断处理延迟高、开销大                                              │
│  - 适用: 低流量、稀疏流量                                                   │
│                                                                             │
│  混合模式 (Adaptive):                                                      │
│  ─────────────────                                                          │
│  - 正常: 轮询                                                                │
│  - 空闲一段时间: 切换到中断                                                  │
│  - 中断唤醒: 切回轮询                                                        │
│                                                                             │
│  性能对比:                                                                 │
│  ──────────                                                                │
│                                                                             │
│  模式           CPU 利用率    延迟      吞吐                              │
│  ──────────────────────────────────────────────────────────────────────── │
│  纯轮询          100%         < 1us    100% (最高)                       │
│  混合轮询        50-80%       1-10us   95-99%                            │
│  传统中断        5-20%        10-100us  70-85%                            │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 6.2 中断配置

```c
// DPDK 中断配置

#include <rte_ethdev.h>
#include <rte_interrupts.h>

// 启用中断模式
int
configure_interrupt_mode(uint16_t port_id)
{
    // EAL 中启用
    // ./app --interrupt-mode

    // 或者代码中请求
    rte_eth_errata_rte_eth_interrupt();

    return 0;
}

// 设置 RX 中断
int
enable_rx_interrupt(uint16_t port_id, uint16_t queue_id)
{
    // 启用队列中断
    int ret = rte_eth_dev_rx_intr_enable(port_id, queue_id);
    if (ret != 0) {
        printf("Failed to enable RX interrupt\n");
        return ret;
    }

    return 0;
}

// 禁用 RX 中断
int
disable_rx_interrupt(uint16_t port_id, uint16_t queue_id)
{
    return rte_eth_dev_rx_intr_disable(port_id, queue_id);
}

// 设置中断回调
int
setup_interrupt_callback(uint16_t port_id)
{
    // 获取 interrupt handle
    struct rte_intr_handle *intr_handle =
        rte_eth_dev_get_intr_handle(port_id);

    // 注册中断事件回调
    rte_intr_callback_register(intr_handle,
                                 RTE_ETH_EVENT_INTR_LSC,
                                 lsc_event_callback,
                                 (void *)(uintptr_t)port_id);

    // 注册队列中断回调
    rte_intr_rx_manageability(intr_handle);

    return 0;
}

// LSC (Link Status Change) 回调
static int
lsc_event_callback(void *arg)
{
    uint16_t port_id = (uint16_t)(uintptr_t)arg;
    struct rte_eth_link link;

    rte_eth_link_get_nowait(port_id, &link);

    if (link.link_status) {
        printf("Port %d: Link Up\n", port_id);
    } else {
        printf("Port %d: Link Down\n", port_id);
    }

    return 0;
}

// 混合模式实现
void
hybrid_polling_loop(uint16_t port_id)
{
    struct rte_mbuf *mbufs[32];
    uint64_t last_rx_time = rte_rdtsc();
    int interrupt_mode = 0;

    while (!quit) {
        // 轮询接收
        uint16_t nb_rx = rte_eth_rx_burst(port_id, 0, mbufs, 32);

        if (nb_rx > 0) {
            // 有包处理
            for (int i = 0; i < nb_rx; i++)
                process_packet(mbufs[i]);

            last_rx_time = rte_rdtsc();

            // 如果之前是中断模式，切换回轮询
            if (interrupt_mode) {
                disable_rx_interrupt(port_id, 0);
                interrupt_mode = 0;
            }
        } else {
            // 无包
            uint64_t idle_time = rte_rdtsc() - last_rx_time;

            // 空闲超过 1 秒，切换到中断模式
            if (!interrupt_mode && idle_time > rte_get_timer_hz()) {
                enable_rx_interrupt(port_id, 0);
                interrupt_mode = 1;
            }

            // 中断模式下让出 CPU
            if (interrupt_mode) {
                rte_delay_us(100);  // 睡一会
            }
        }
    }
}
```

---

## 7. 完整调优清单

### 7.1 系统级调优

```bash
#!/bin/bash
# system_tuning.sh - 系统级性能调优

# 1. BIOS 设置
# ─────────────
# - 禁用 SpeedStep / Cool'n'Quiet
# - 启用 C-State (但 C1E 建议关闭)
# - 启用 Virtualization (VT-d)
# - 关闭无关的 CPU 核心

# 2. GRUB 参数
# ─────────────
cat >> /etc/default/grub << 'EOF'
GRUB_CMDLINE_LINUX="default_hugepagesz=1G hugepagesz=1G hugepages=64 intel_iommu=on iommu=pt isolcpus=1-15 nohz_full=1-15 rcu_nocbs=1-15 irqaffinity=1-15"
EOF

update-grub2
reboot

# 3. 透明大页 (慎用)
# ─────────────
# echo never > /sys/kernel/mm/transparent_hugepage/enabled
# echo never > /sys/kernel/mm/transparent_hugepage/defrag

# 4. CPU 隔离
# ─────────────
for cpu in 1 2 3 4 5 6 7; do
    echo 0 > /sys/devices/system/cpu/cpu$cpu/online
done

# 5. 中断亲和性
# ─────────────
for irq in $(cat /proc/interrupts | grep eth | awk '{print $1}' | tr -d :); do
    echo "3" > /proc/irq/$irq/smp_affinity
done

# 6. 关闭 ASLR
# ─────────────
echo 0 > /proc/sys/kernel/randomize_va_space

# 7. 调整网络 buffer
# ─────────────
sysctl -w net.core.rmem_max=16777216
sysctl -w net.core.wmem_max=16777216
sysctl -w net.core.netdev_max_backlog=8192
```

### 7.2 NIC 调优

```bash
#!/bin/bash
# nic_tuning.sh - NIC 级调优

ETHDEV=eth0

# 1. 关闭 GRO (Generic Receive Offload)
ethtool -K $ETHDEV gro off

# 2. 关闭 LRO (Large Receive Offload)
ethtool -K $ETHDEV lro off

# 3. 关闭 TSO (TCP Segmentation Offload)
ethtool -K $ETHDEV tso off

# 4. 关闭 GSO (Generic Segmentation Offload)
ethtool -K $ETHDEV gso off

# 5. 关闭 UFO (UDP Fragmentation Offload)
ethtool -K $ETHDEV ufo off

# 6. 启用 Flow Control (根据场景)
ethtool -A $ETHDEV rx on tx on

# 7. 设置 ring buffer
ethtool -G $ETHDEV rx 4096 tx 4096

# 8. 设置中断合并
ethtool -C $ETHDEV rx-usecs 0 tx-usecs 0  # 最小延迟

# 9. 查看设置
ethtool -i $ETHDEV
ethtool -S $ETHDEV
ethtool -k $ETHDEV  # offload 状态
ethtool -c $ETHDEV   # coalesce 状态
```

### 7.3 DPDK 应用调优

```c
// DPDK 应用调优清单

// 1. EAL 参数
// ─────────────
/*
  --lcores 0-3              : lcore 分配
  --master-lcore 0          : 主 lcore
  -m 1024                   : 内存 (MB)
  --socket-mem 1024,1024    : 每 socket 内存
  --huge-dir /mnt/huge      : hugepage 目录
  --file-prefix dpdk        : 共享内存前缀
  --proc-type auto          : 多进程模式
  -n 4                      : 内存通道数
  --rxd 512 --txd 512       : 描述符数
  --burst 32                : burst 大小
  --txq 4 --rxq 4           : 队列数
*/

// 2. 内存池配置
#define MBUF_CACHE_SIZE 256
#define MBUF_POOL_SIZE (nb_ports * nb_queues * 1024 + 8192)

struct rte_mempool *
create_mbuf_pool(unsigned socket_id)
{
    char name[64];
    snprintf(name, sizeof(name), "mbuf_pool_socket%d", socket_id);

    return rte_pktmbuf_pool_create(
        name,
        MBUF_POOL_SIZE,
        MBUF_CACHE_SIZE,
        0,
        RTE_MBUF_DEFAULT_BUF_SIZE,
        socket_id);
}

// 3. 队列配置优化
struct rte_eth_rxq_conf rxq_conf = {
    .rx_thresh = {
        .pthresh = 8,
        .hthresh = 8,
        .wthresh = 0,  // 每包写回，最小延迟
    },
    .rx_free_thresh = 32,   // 批量释放
    .rx_drop_en = 0,
};

struct rte_eth_txq_conf txq_conf = {
    .tx_thresh = {
        .pthresh = 32,
        .hthresh = 32,
        .wthresh = 16,      // 批量写回
    },
    .tx_free_thresh = 32,
    .tx_rs_thresh = 32,
};

// 4. RSS + Flow Director 组合
void
optimize_rss_fdir(uint16_t port_id)
{
    // 启用 RSS
    struct rte_eth_rss_conf rss_conf = {
        .rss_key = NULL,
        .rss_hf = RTE_ETH_RSS_IP | RTE_ETH_RSS_TCP | RTE_ETH_RSS_UDP,
    };

    // Flow Director 优先规则
    // 队列 0: 管理流量 (SSH)
    add_fdir_rule(port_id, "10.0.0.1", "10.0.0.100", 0, 22, 0);

    // 队列 1: HTTP
    add_fdir_rule(port_id, 0, 0, 0, 80, 1);
    add_fdir_rule(port_id, 0, 0, 0, 443, 1);

    // 其他: RSS
    uint16_t queues[] = {2, 3, 4, 5};
    create_rss_flow(port_id, queues, 4);
}

// 5. 延迟优化
void
optimize_latency(uint16_t port_id)
{
    // 关闭 tx_checksum
    // 让硬件计算 checksum

    // 使用局部数据
    __thread struct thread_local_ctx ctx;

    // 避免跨 NUMA 访问
    if (rte_lcore_to_socket_id(rte_lcore_id()) !=
        rte_eth_dev_socket_id(port_id)) {
        printf("Warning: NUMA mismatch\n");
    }
}

// 6. 吞吐优化
void
optimize_throughput(uint16_t port_id)
{
    // 增大 burst size
    #define BURST_SIZE 64

    // 增大 descriptor
    #define DESC_SIZE 1024

    // 批量处理
    struct rte_mbuf *batch[BURST_SIZE];

    // 异步发送 (启用 TX offload)
    uint16_t nb_tx = rte_eth_tx_burst(port_id, 0, batch, BURST_SIZE);
}
```

### 7.4 调优验证

```bash
# 验证脚本

#!/bin/bash
# verify_tuning.sh

echo "=== System Info ==="
uname -a
cat /proc/cpuinfo | grep "model name" | head -1
cat /proc/meminfo | grep Huge

echo "=== Hugepages ==="
cat /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages
grep -r . /sys/kernel/mm/hugepages/hugepages-*/nr_hugepages

echo "=== CPU Isolation ==="
cat /sys/devices/system/cpu/cpu*/online | head -20

echo "=== NIC Info ==="
ethtool -i eth0 2>/dev/null || echo "No eth0"

echo "=== IRQ Affinity ==="
for irq in $(cat /proc/interrupts | grep -i eth | awk '{print $1}' | tr -d :); do
    echo "IRQ $irq: $(cat /proc/irq/$irq/smp_affinity 2>/dev/null)"
done

echo "=== Network Offloads ==="
ethtool -k eth0 2>/dev/null

echo "=== Ring Buffers ==="
ethtool -g eth0 2>/dev/null

echo "=== Interrupt Coalescing ==="
ethtool -c eth0 2>/dev/null

echo "=== Running DPDK App ==="
pgrep -a dpdk || echo "No DPDK app running"
```

---

## 8. 小结

本章核心要点：

1. **性能调优金字塔**：L5 算法/架构 → L4 核亲和性 → L3 内存 → L2 同步 → L1 基本配置，层层递进。

2. **Batching 原理**：批量处理减少函数调用开销，目标是用相同 overhead 处理更多包。

3. **DPDK Burst API**：`rte_eth_rx_burst()` 和 `rte_eth_tx_burst()`，一次调用处理多个包。

4. **批量优化策略**：动态批量大小 (自适应)、Pipeline Batching (分阶段)、Zero-Copy Batching (避免复制)。

5. **Burst 调优参数**：burst size (16-64)、descriptor 数量 (512-1024)、mbuf 大小。

6. **RSS 原理**：Toeplitz Hash + Indirection Table，将流散列到不同队列，保持同流保序。

7. **RSS 配置**：`RTE_ETH_MQ_RX_RSS` 模式、hash fields (IP/TCP/UDP)、自定义 key。

8. **Flow Director**：精确 5-tuple 匹配，将特定流导向特定队列，支持丢弃动作。

9. **rte_flow API**：现代 DPDK Flow API，支持 Pattern + Action，更灵活强大。

10. **队列数量选择**：CPU 核心数、NIC 能力、流量特征、内存占用的权衡。

11. **描述符阈值调优**：pthresh/hthresh/wthresh，小包低延迟 vs 大包高吞吐。

12. **轮询 vs 中断**：纯轮询低延迟但 CPU 100%，中断空闲省 CPU 但延迟高，混合模式取平衡。

13. **自适应混合模式**：正常轮询，空闲超时切换中断，中断唤醒切回轮询。

14. **系统级调优**：BIOS 设置、GRUB hugepage、CPU 隔离、中断亲和、ASLR。

15. **NIC 调优**：关闭 GRO/LRO/TSO/GSO、Flow Control、Ring buffer、中断合并。

16. **调优验证**：Hugepage 配置、CPU 隔离、IRQ affinity、offload 状态检查。

**篇后语**：

DPDK 深度探索系列 (1-30) 至此完成。系列涵盖了 DPDK 核心知识点：EAL 抽象、mbuf 内存管理、Poll Mode Driver、队列与描述符、Flow Classification、虚拟化 (Virtio/vhost)、加速库 (ACL/Hash/LCore)、CPU 优化 (Cache/NUMA)、内存模型、同步原语、Profiling 与调优。后续章节将继续深入高级主题，包括：安全加密 (IPSec)、性能基准测试、高级队列管理、云原生部署等。

---

> [!tip] 参考文献
> - Intel, "Data Plane Development Kit Performance Tuning Guide"
> - Intel, "Intel 82599 10GbE Controller Datasheet" (RSS/Flow Director)
> - DPDK Flow API, https://doc.dpdk.org/guides/prog_guide/rte_flow.html
> - DPDK RSS, https://doc.dpdk.org/guides/prog_guide/rss.html
> - DPDK Flow Director, https://doc.dpdk.org/guides/prog_guide/flow_agent.html
> - "DPDK Performance Optimization", https://doc.dpdk.org/guides-16.04/proGuide/13_perf_opt.html
> - "DPDK Optimization Techniques", Intel
