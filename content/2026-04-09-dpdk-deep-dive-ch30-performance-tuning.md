---
title: "DPDK 深度探索 (三十)：性能调优——Batching、RSS、rte_flow 与队列设计"
date: 2026-04-09
tags: [dpdk, series, performance, batching, rss, rte-flow, queue, optimization, receive-scaling]
description: "深入理解 DPDK 性能调优：批处理、预取、RSS、RETA、rte_flow、队列描述符、offload、轮询与调优验证"
---

> [!info] DPDK 深度探索系列 0. [[2026-04-09-dpdk-deep-dive-series-index|全栈学习路径总览]]
> 1-29. 前二十九章已完成 30. **第三十章：性能调优——Batching、RSS、rte_flow 与队列设计**

---

## 1. 性能调优的主线

DPDK 性能问题通常不是某一个 API 慢，而是以下几件事叠加：

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         DPDK 数据面性能主线                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  1. 减少每包固定开销                                                        │
│     单包调用 RX/TX → burst 批量处理                                         │
│                                                                             │
│  2. 减少 cache miss                                                         │
│     mbuf / descriptor / flow table 尽量 NUMA 本地                            │
│     预取下一批包头和元数据                                                   │
│                                                                             │
│  3. 减少跨核共享                                                             │
│     每个 lcore 固定 RX queue / TX queue                                      │
│     per-lcore 统计和 per-lcore mempool cache                                │
│                                                                             │
│  4. 把分类下推给硬件                                                         │
│     RSS 做通用分流                                                           │
│     rte_flow 做精确规则：queue / rss / drop / mark                          │
│                                                                             │
│  5. 只开启有收益的 offload                                                   │
│     checksum / TSO / scatter / RSS hash                                      │
│     不需要的 offload 不开，避免 PMD 走慢路径                                 │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

本文使用现代 DPDK API 讲解，重点纠正几个容易混淆的点：

| 主题              | 正确做法                                                                            |
| ----------------- | ----------------------------------------------------------------------------------- |
| RSS hash 配置     | `rte_eth_dev_rss_hash_update()` / `rte_eth_dev_rss_hash_conf_get()`                 |
| RSS RETA 配置     | `rte_eth_dev_rss_reta_update()`，使用 `struct rte_eth_rss_reta_entry64`             |
| Flow Director     | 新代码使用 `rte_flow`，不要再使用旧 `rte_eth_fdir_*` 私有接口                       |
| IPv4/Ether 结构体 | `struct rte_ipv4_hdr`、`struct rte_ether_hdr`                                       |
| RX 中断           | 用 `rte_eth_dev_rx_intr_enable()` + `rte_eth_dev_rx_intr_ctl_q_get_fd()` 接入 epoll |
| link 事件         | 用 `rte_eth_dev_callback_register(..., RTE_ETH_EVENT_INTR_LSC, ...)`                |

---

## 2. Batching：先把固定开销摊薄

### 2.1 为什么 batch 是第一层优化

单包处理的问题是每个包都要付出函数调用、ring 状态检查、doorbell、分支判断等固定成本。

```
单包:

for each packet:
    rx_burst(1)      固定开销
    process(pkt)     业务开销
    tx_burst(1)      固定开销

批量:

rx_burst(32)         固定开销只付一次
for pkt in batch:
    process(pkt)
tx_burst(32)         固定开销只付一次
```

64B 小包场景下，batch 往往比单包路径重要得多。`rte_eth_rx_burst()` 和 `rte_eth_tx_burst()` 本身就是为这个模型设计的。

### 2.2 基础 burst loop

```c
#include <rte_ethdev.h>
#include <rte_mbuf.h>

#define BURST_SIZE 32

static inline void
free_unsent(struct rte_mbuf **pkts, uint16_t sent, uint16_t total)
{
    for (uint16_t i = sent; i < total; i++)
        rte_pktmbuf_free(pkts[i]);
}

static void
forward_loop(uint16_t rx_port, uint16_t tx_port, uint16_t queue_id)
{
    struct rte_mbuf *pkts[BURST_SIZE];

    while (!force_quit) {
        uint16_t nb_rx = rte_eth_rx_burst(rx_port, queue_id, pkts, BURST_SIZE);

        if (nb_rx == 0)
            continue;

        for (uint16_t i = 0; i < nb_rx; i++)
            process_packet(pkts[i]);

        uint16_t nb_tx = rte_eth_tx_burst(tx_port, queue_id, pkts, nb_rx);
        if (unlikely(nb_tx < nb_rx))
            free_unsent(pkts, nb_tx, nb_rx);
    }
}
```

注意点：

- `tx_burst()` 可能只发送一部分，未发送的 mbuf 必须由应用释放或重试。
- 每个 lcore 尽量使用独占队列，避免多个 lcore 共享同一个 queue。
- 小包常用 `BURST_SIZE=32` 或 `64`，大包可降到 `16`，最终以实测为准。

### 2.3 分阶段 batch

复杂业务不要每个包完整走完所有阶段，可以按阶段处理一批包：

```
RX batch
  │
  ├─ stage 1: 预取 packet header
  ├─ stage 2: 解析 L2/L3/L4
  ├─ stage 3: 查表 / 分类
  ├─ stage 4: 修改 header / 统计
  └─ TX batch
```

```c
#include <rte_ether.h>
#include <rte_ip.h>
#include <rte_prefetch.h>

static void
process_batch(struct rte_mbuf **pkts, uint16_t n)
{
    for (uint16_t i = 0; i < n && i < 4; i++)
        rte_prefetch0(rte_pktmbuf_mtod(pkts[i], void *));

    for (uint16_t i = 0; i < n; i++) {
        if (i + 4 < n)
            rte_prefetch0(rte_pktmbuf_mtod(pkts[i + 4], void *));

        struct rte_ether_hdr *eth =
            rte_pktmbuf_mtod(pkts[i], struct rte_ether_hdr *);

        if (eth->ether_type != rte_cpu_to_be_16(RTE_ETHER_TYPE_IPV4))
            continue;

        struct rte_ipv4_hdr *ip = (struct rte_ipv4_hdr *)(eth + 1);
        handle_ipv4(pkts[i], ip);
    }
}
```

预取不是越多越好。预取距离太近没有效果，太远会污染 cache。一般先从 `i + 4` 或 `i + 8` 开始测。

---

## 3. RSS：通用流量分摊

### 3.1 RSS 的作用

RSS (Receive Side Scaling) 用硬件 hash 把流量分发到多个 RX queue：

```
┌─────────────┐
│   Packet    │
│ 5-tuple     │
└──────┬──────┘
       │
       ▼
┌──────────────────────┐
│ NIC RSS hash          │
│ src/dst ip + port     │
└──────┬───────────────┘
       │ hash
       ▼
┌──────────────────────┐
│ RETA                 │
│ hash % reta_size     │
└──────┬───────────────┘
       │ queue id
       ▼
 RX queue 0/1/2/3...
```

RSS 解决的是**大量普通流量的粗粒度均衡**。如果需要把特定 VIP、端口、租户精确打到某个队列，应使用 `rte_flow`。

### 3.2 RSS 本质上就是 rte_flow 的一种 action

很多教程把"全局 RSS"和 `rte_flow` 说成两个独立机制，容易误导。实际上：

**RSS 是 `rte_flow` 的一种 action，和 QUEUE、DROP 同级：**

```c
RTE_FLOW_ACTION_TYPE_QUEUE    // 匹配 → 固定到一个 queue
RTE_FLOW_ACTION_TYPE_RSS      // 匹配 → 在一组 queue 内 hash 均衡
RTE_FLOW_ACTION_TYPE_DROP     // 匹配 → 丢弃
RTE_FLOW_ACTION_TYPE_MARK     // 匹配 → 打标记
RTE_FLOW_ACTION_TYPE_COUNT    // 匹配 → 硬件计数
RTE_FLOW_ACTION_TYPE_SECURITY // 匹配 → 安全卸载 (IPsec/TLS)
```

所谓"全局 RSS"（通过 `port_conf.rss_conf` 配置），本质就是一条**低优先级的 catch-all 默认规则**：

```
网卡硬件里的 match-action pipeline:

规则 1: match VLAN 100    → action RSS queues {0,1}
规则 2: match VLAN 200    → action RSS queues {2,3}
规则 3: match 黑名单 IP   → action DROP
...
默认规则: match * (所有)   → action RSS queues {0,1,2,3}
                              ↑ 这就是 port_conf.rss_conf 配的
```

所以完整图是这样的：

```
所有流量进入 NIC
    │
    ▼
rte_flow match table（网卡硬件执行）
    │
    ├─ VIP 10.0.0.10:443
    │     └─ action QUEUE 0              精确指定一个 queue
    │
    ├─ 租户 A / VLAN 100
    │     └─ action RSS queues {0,1}     这类流量只在 0,1 内 hash 均衡
    │
    ├─ 租户 B / VLAN 200
    │     └─ action RSS queues {2,3}     这类流量只在 2,3 内 hash 均衡
    │
    ├─ 黑名单 IP
    │     └─ action DROP                 包在网卡里直接丢弃，CPU 看不到
    │
    └─ 没有命中任何规则
          └─ action RSS queues {0,1,2,3} 这就是 port_conf 配的"全局 RSS"
```

关键理解：

```
rte_flow QUEUE:
  匹配 → 固定到一个 queue
  最精确，没有均衡
  适用: VIP、特定服务必须由特定核处理

rte_flow RSS:
  匹配 → 在指定 queue set 内 hash 均衡
  精确分类 + 组内均衡
  适用: 某类流量需要隔离但不能只用一个核

port_conf "全局 RSS":
  没被任何规则命中的流量 → 所有队列 hash 均衡
  最粗粒度的 catch-all
  适用: 普通流量不需要特殊处理
```

两种配置入口，同一个硬件机制：

```
port_conf.rss_conf:
  配置简单，启动时设一次
  所有流量共用一张 RETA
  不能区分流量类型

rte_flow_create():
  灵活，可以动态添加/删除规则
  每条规则可以指定不同的 queue set
  可以按 pattern 区分流量
  消耗硬件 flow table 资源（TCAM/SRAM）
```

### 3.3 隧道流量为什么会 RSS 失衡

普通 L4 流量通常直接 RSS 就够了，因为不同连接的五元组不同：

```
client1:1234 → VIP:443
client2:2345 → VIP:443
client3:3456 → VIP:443

外层五元组都不同
→ RSS hash 分散
→ queue 0/1/2/3 比较均匀
```

全隧道/封装流量就不一样：

```
Gateway A → Gateway B
  outer src_ip = A
  outer dst_ip = B
  outer UDP port = 4500 / 4789 / 6081

隧道内部有成千上万条连接:
  client1 → server1
  client2 → server2
  client3 → server3

但 NIC 默认 RSS 只看到外层:
  A:4500 → B:4500
  A:4500 → B:4500
  A:4500 → B:4500

hash 结果一样或高度集中
→ 全部进同一个 queue
→ 单核打满，其他核空闲
```

解决顺序：

```
1. 优先看网卡的 RSS hash type 是否支持隧道内层

   某些网卡配置了 RTE_ETH_RSS_VXLAN / RTE_ETH_RSS_GENEVE 等 hash type 后，
   默认 RSS 就能自动解析隧道并对 inner 5-tuple 做 hash。
   这时候不需要 rte_flow，直接配好 rss_hf 就行。

2. 如果网卡能解 inner 但默认不做 → 用 rte_flow 显式指定

   有些网卡需要显式规则才能对隧道流量启用 inner RSS：
     match outer UDP dst port 4789 / Geneve / NVGRE
     action RSS queues {0,1,2,3}, level=inner

   也可以用 rte_flow 把隧道流量限制在特定 queue group 内：
     match VXLAN → RSS queues {4,5,6,7}
     其他流量 → RSS queues {0,1,2,3}

3. 如果网卡完全不支持 inner RSS → 只能软件兜底

   所有隧道包先集中到一个 queue，软件解封装后按 inner 5-tuple 分发。
   能均衡后续业务处理，但入口 lcore 仍然是瓶颈。
```

场景 1 和场景 2 的区别：

```
场景 1: 网卡默认 inner RSS 自动生效

  配置:
    rss_conf.rss_hf = RTE_ETH_RSS_VXLAN | RTE_ETH_RSS_TCP;

  效果:
    NIC 收到 VXLAN 包 → 自动解析 inner → 用 inner 5-tuple hash
    不需要 rte_flow
    所有队列统一参与均衡

场景 2: 网卡能解 inner 但需要 rte_flow 显式触发

  配置:
    rte_flow: match VXLAN → action RSS level=inner queues {4,5,6,7}

  效果:
    VXLAN 流量只在 queue 4-7 内均衡（可以和普通流量隔离）
    需要 rte_flow_validate() 确认支持

场景 3: 需要隔离隧道和普通流量到不同队列组

  配置:
    rte_flow: match VXLAN → RSS queues {4,5,6,7} level=inner
    默认 RSS → queues {0,1,2,3}

  效果:
    隧道流量不占用普通流量的队列
    两类流量互不干扰
```

`rte_flow` 的 RSS action 支持 `level` 字段，可请求对指定封装层级做 hash：

```c
struct rte_flow_action_rss rss = {
    .level = 2,              /* 请求 inner 层级，具体语义取决于 PMD */
    .types = RTE_ETH_RSS_TCP,
    .queue_num = nb_queues,
    .queue = queues,
};
```

是否真的支持要以当前 PMD 的 `rte_flow_validate()` 为准。

硬件 inner RSS 成功时：

```
tunnel packet
    │
    ▼
NIC parser
    │
    ├─ 解析 outer tunnel
    ├─ 解析 inner 5-tuple
    │
    ▼
RSS(inner 5-tuple)
    │
    ├─ queue 0 → lcore 0
    ├─ queue 1 → lcore 1
    ├─ queue 2 → lcore 2
    └─ queue 3 → lcore 3
```

硬件做不了时的软件兜底：

```
所有隧道包先进入 queue 0
    │
    ▼
lcore 0 解封装 / 解密 / 解析 inner
    │
    ▼
hash(inner 5-tuple)
    │
    ├─ enqueue 到 worker 0
    ├─ enqueue 到 worker 1
    ├─ enqueue 到 worker 2
    └─ enqueue 到 worker 3
```

这个兜底方案的代价：

- 入口 lcore 仍然要收所有隧道包，可能先被打满。
- mbuf 已经落在入口 queue 的 mempool/cache 路径上。
- 转给其他 worker 后会产生跨核 cache line 迁移。
- 如果跨 NUMA，还会有远端内存访问。

IPsec 全隧道更特殊：

| 场景                    | RSS 能看到什么               | 结果                       |
| ----------------------- | ---------------------------- | -------------------------- |
| 普通网卡收 ESP          | outer IP + SPI，inner 是密文 | 无法基于 inner 5-tuple RSS |
| 多 SA/SPI               | SPI 不同                     | 可以按 SPI 粗分流          |
| NIC inline IPsec        | NIC 解密后看到 inner         | 可做 inner RSS，效果最好   |
| 软件/QAT lookaside 解密 | CPU 解密后才看到 inner       | 只能软件分发               |

所以普通非隧道流量通常 RSS 就够了；全隧道流量优先找硬件 inner RSS / inline 解密能力，硬件做不了时才用软件负载均衡。

### 3.4 配置 RSS

```c
#include <rte_ethdev.h>

static int
configure_port_with_rss(uint16_t port_id, uint16_t nb_rxq, uint16_t nb_txq)
{
    struct rte_eth_dev_info dev_info;
    int ret = rte_eth_dev_info_get(port_id, &dev_info);
    if (ret != 0)
        return ret;

    uint64_t rss_hf = RTE_ETH_RSS_IP | RTE_ETH_RSS_TCP | RTE_ETH_RSS_UDP;
    rss_hf &= dev_info.flow_type_rss_offloads;

    uint64_t rx_offloads = 0;
    if (dev_info.rx_offload_capa & RTE_ETH_RX_OFFLOAD_RSS_HASH)
        rx_offloads |= RTE_ETH_RX_OFFLOAD_RSS_HASH;

    struct rte_eth_conf port_conf = {
        .rxmode = {
            .mq_mode = RTE_ETH_MQ_RX_RSS,
            .offloads = rx_offloads,
        },
        .rx_adv_conf = {
            .rss_conf = {
                .rss_key = NULL,       /* PMD 使用默认 key */
                .rss_key_len = 0,
                .rss_hf = rss_hf,
            },
        },
    };

    return rte_eth_dev_configure(port_id, nb_rxq, nb_txq, &port_conf);
}
```

关键点：

- `rss_key=NULL` 表示让 PMD 使用默认 key。不要假设所有 PMD 默认 key 都一样。
- `rss_hf` 必须与 `dev_info.flow_type_rss_offloads` 做交集，否则可能配置失败。
- `RTE_ETH_RX_OFFLOAD_RSS_HASH` 让 PMD 在 mbuf 中填 `hash.rss` 和 `RTE_MBUF_F_RX_RSS_HASH`。

### 3.5 更新 RSS hash 配置

现代 DPDK 没有 `rte_eth_dev_rss_hash_key_set()` 这种 API。更新 key 和 hash 字段都通过 `rte_eth_dev_rss_hash_update()`。

```c
static int
update_rss_key(uint16_t port_id, uint8_t *key, uint8_t key_len, uint64_t rss_hf)
{
    struct rte_eth_rss_conf conf = {
        .rss_key = key,
        .rss_key_len = key_len,
        .rss_hf = rss_hf,
    };

    return rte_eth_dev_rss_hash_update(port_id, &conf);
}

static int
query_rss_conf(uint16_t port_id, uint8_t *key_buf, uint8_t key_buf_len,
               struct rte_eth_rss_conf *out)
{
    out->rss_key = key_buf;
    out->rss_key_len = key_buf_len;
    return rte_eth_dev_rss_hash_conf_get(port_id, out);
}
```

查询 RSS key 时，`rss_key_len` 至少要等于 `dev_info.hash_key_size`，否则即使 API 返回成功，结果也可能不可靠。

### 3.6 配置 RETA

RETA (Redirection Table) 决定 hash 桶到 queue 的映射。现代 DPDK 使用 `struct rte_eth_rss_reta_entry64`，每 64 个 entry 一组。

```c
#include <rte_malloc.h>

static int
set_reta_round_robin(uint16_t port_id, uint16_t nb_rxq)
{
    struct rte_eth_dev_info dev_info;
    int ret = rte_eth_dev_info_get(port_id, &dev_info);
    if (ret != 0)
        return ret;

    uint16_t reta_size = dev_info.reta_size;
    if (reta_size == 0)
        return -ENOTSUP;

    uint16_t groups = RTE_ALIGN_CEIL(reta_size, RTE_ETH_RETA_GROUP_SIZE) /
                      RTE_ETH_RETA_GROUP_SIZE;

    struct rte_eth_rss_reta_entry64 *reta =
        rte_zmalloc(NULL, groups * sizeof(*reta), 0);
    if (reta == NULL)
        return -ENOMEM;

    for (uint16_t i = 0; i < reta_size; i++) {
        uint16_t group = i / RTE_ETH_RETA_GROUP_SIZE;
        uint16_t idx = i % RTE_ETH_RETA_GROUP_SIZE;

        reta[group].mask |= RTE_BIT64(idx);
        reta[group].reta[idx] = i % nb_rxq;
    }

    ret = rte_eth_dev_rss_reta_update(port_id, reta, reta_size);
    rte_free(reta);
    return ret;
}
```

这段代码替代旧文档中的 `rte_eth_rss_indir_table_conf` / `rte_eth_dev_rss_indir_table_update()`，那些不是当前 ethdev RSS RETA API。

### 3.7 使用 mbuf 中的 RSS hash

```c
#include <rte_mbuf.h>

static inline uint32_t
mbuf_rss_hash(const struct rte_mbuf *m)
{
    if (m->ol_flags & RTE_MBUF_F_RX_RSS_HASH)
        return m->hash.rss;

    return 0; /* 硬件没有提供 RSS hash，应用可自行计算 */
}
```

不要把 RSS hash 当成安全 hash。它的用途是负载均衡，不是身份认证或防攻击。

---

## 4. rte_flow：精确分类与硬件规则

### 4.1 Flow Director 与 rte_flow 的关系

老资料里常见的 Flow Director 私有接口已经不适合新代码：

```
旧路径:
  rte_eth_fdir_* / rte_eth_dev_fdir_*   已被现代 rte_flow 模型取代

现代路径:
  pattern + action

  pattern: ETH / VLAN / IPV4 / TCP / UDP / VXLAN ...
  action:  QUEUE / RSS / DROP / MARK / COUNT / SECURITY ...
```

`rte_flow` 的好处是统一。不同网卡 PMD 可以暴露不同能力，但上层 API 是同一个。

### 4.2 rte_flow / RSS / queue / lcore / NUMA 的配合

性能上真正有价值的是：**包 DMA 到内存之前，就已经由硬件决定进入哪个 RX queue**。

这几层的关系是：

```
流量分类规则  →  RX Queue  →  lcore  →  NUMA-local mempool
rte_flow/RSS     硬件队列      CPU核      mbuf内存
```

完整路径如下：

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                   硬件分流的正确路径：包进 CPU 前已经选好队列               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  NIC port 在 NUMA 0                                                          │
│                                                                             │
│  ┌──────────────┐                                                           │
│  │  Wire packet │                                                           │
│  └──────┬───────┘                                                           │
│         │                                                                   │
│         ▼                                                                   │
│  ┌──────────────────────────────┐                                           │
│  │ NIC parser / match pipeline   │                                          │
│  │ - RSS hash                    │                                          │
│  │ - rte_flow match table        │                                          │
│  └──────┬───────────────────────┘                                           │
│         │                                                                   │
│         │  硬件动作: QUEUE / RSS                                            │
│         ▼                                                                   │
│  ┌────────────┬────────────┬────────────┬────────────┐                     │
│  │ RX queue 0 │ RX queue 1 │ RX queue 2 │ RX queue 3 │                     │
│  │ pool N0    │ pool N0    │ pool N0    │ pool N0    │                     │
│  └─────┬──────┴─────┬──────┴─────┬──────┴─────┬──────┘                     │
│        │            │            │            │                            │
│        ▼            ▼            ▼            ▼                            │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐                       │
│  │ lcore 0 │  │ lcore 1 │  │ lcore 2 │  │ lcore 3 │                       │
│  │ NUMA 0  │  │ NUMA 0  │  │ NUMA 0  │  │ NUMA 0  │                       │
│  └─────────┘  └─────────┘  └─────────┘  └─────────┘                       │
│                                                                             │
│  结果: packet / mbuf / RX ring / lcore 都在同一个 NUMA 节点                 │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

`rte_flow` 和 RSS 的典型组合是：

```
所有流量进入 NIC
    │
    ▼
rte_flow match
    │
    ├── tenant A / VLAN 100 / VIP A
    │       │
    │       ▼
    │     RSS to queues {0,1}
    │       ├── queue 0 → lcore 0 → mempool NUMA 0
    │       └── queue 1 → lcore 1 → mempool NUMA 0
    │
    ├── tenant B / VLAN 200 / VIP B
    │       │
    │       ▼
    │     RSS to queues {2,3}
    │       ├── queue 2 → lcore 2 → mempool NUMA 0
    │       └── queue 3 → lcore 3 → mempool NUMA 0
    │
    └── bad traffic
            │
            ▼
          DROP
```

这里 `rte_flow` 做粗分类，RSS 做组内均衡，queue 和 lcore 做固定绑定。

如果一个连接不走硬件 `rte_flow`，而是先落到默认 RSS queue，再由软件转给目标 worker，就会变成这样：

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                  软件后置分流：逻辑上能转发，但性能代价已经发生             │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  目标: 连接 C 应该由 lcore 3 处理                                           │
│                                                                             │
│  实际路径:                                                                  │
│                                                                             │
│  NIC 收到连接 C 的包                                                        │
│      │                                                                      │
│      ├─ 没有命中 rte_flow 规则                                              │
│      │                                                                      │
│      ├─ 默认 RSS 把包打到 queue 0                                           │
│      │                                                                      │
│      ├─ DMA 到 queue 0 的 RX ring                                           │
│      │  mbuf 来自 queue 0 绑定的 mempool                                    │
│      │                                                                      │
│      ▼                                                                      │
│  lcore 0 收到包                                                             │
│      │                                                                      │
│      ├─ 软件解析 header                                                     │
│      ├─ 查连接表: 发现连接 C 应该归 lcore 3                                  │
│      │                                                                      │
│      └─ 把 mbuf 指针 enqueue 到 lcore 3 的 software ring                    │
│             │                                                               │
│             ▼                                                               │
│        lcore 3 读取这个 mbuf                                                │
│        但 packet 数据和 mbuf 元数据可能仍在 queue 0 / NUMA 0 的 cache 路径   │
│                                                                             │
│  代价:                                                                      │
│  - lcore 0 白白解析了一次包                                                  │
│  - lcore 0 和 lcore 3 之间多一次 ring 传递                                   │
│  - mbuf cache line 在两个 core 之间迁移                                      │
│  - 如果 lcore 3 在另一个 NUMA 节点，每包都可能跨 NUMA 读数据                 │
│  - 后续同一连接的包如果仍然没有硬件规则，会持续重复这个代价                 │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

所以 `rte_flow -> QUEUE/RSS` 的价值不是“软件里给包贴一个队列号”，而是让 NIC 在 DMA 前就把包放到正确 RX queue。软件 fallback 可以用于兼容和控制面，但不能当高性能数据面的主路径。

实战原则：

1. 每个 NUMA socket 建自己的 mempool。
2. 每个 RX queue 绑定本 NUMA mempool。
3. 每个 RX queue 由固定同 NUMA lcore 轮询。
4. RSS 做默认均衡，`rte_flow` 做 VIP、tenant、隧道、端口等精确 steering。
5. `rte_flow_validate()` / `rte_flow_create()` 失败时要明确降级，并降低性能预期。

### 4.3 TCP dst port 到指定队列

下面规则把 IPv4 TCP 目的端口 `dst_port` 的流量导向 `queue_id`。

```c
#include <rte_flow.h>
#include <rte_ether.h>
#include <rte_tcp.h>

static struct rte_flow *
create_tcp_dst_port_to_queue(uint16_t port_id, uint16_t dst_port,
                             uint16_t queue_id)
{
    struct rte_flow_error error;

    struct rte_flow_attr attr = {
        .ingress = 1,
    };

    struct rte_flow_item_eth eth_spec = {
        .hdr.ether_type = rte_cpu_to_be_16(RTE_ETHER_TYPE_IPV4),
    };
    struct rte_flow_item_eth eth_mask = {
        .hdr.ether_type = RTE_BE16(0xffff),
    };

    struct rte_flow_item_tcp tcp_spec = {
        .hdr.dst_port = rte_cpu_to_be_16(dst_port),
    };
    struct rte_flow_item_tcp tcp_mask = {
        .hdr.dst_port = RTE_BE16(0xffff),
    };

    struct rte_flow_item pattern[] = {
        {
            .type = RTE_FLOW_ITEM_TYPE_ETH,
            .spec = &eth_spec,
            .mask = &eth_mask,
        },
        {
            .type = RTE_FLOW_ITEM_TYPE_IPV4,
        },
        {
            .type = RTE_FLOW_ITEM_TYPE_TCP,
            .spec = &tcp_spec,
            .mask = &tcp_mask,
        },
        {
            .type = RTE_FLOW_ITEM_TYPE_END,
        },
    };

    struct rte_flow_action_queue queue = {
        .index = queue_id,
    };
    struct rte_flow_action actions[] = {
        {
            .type = RTE_FLOW_ACTION_TYPE_QUEUE,
            .conf = &queue,
        },
        {
            .type = RTE_FLOW_ACTION_TYPE_END,
        },
    };

    if (rte_flow_validate(port_id, &attr, pattern, actions, &error) != 0) {
        printf("flow validate failed: %s\n",
               error.message ? error.message : "unknown");
        return NULL;
    }

    return rte_flow_create(port_id, &attr, pattern, actions, &error);
}
```

### 4.4 特定流量做 RSS

`QUEUE` 是精确打到一个队列，`RSS` 是命中特定 pattern 后再在一组队列内分流。

```c
static struct rte_flow *
create_ipv4_tcp_rss_flow(uint16_t port_id, const uint16_t *queues,
                         uint32_t nb_queues)
{
    struct rte_flow_error error;

    struct rte_flow_attr attr = {
        .ingress = 1,
    };

    struct rte_flow_item_eth eth_spec = {
        .hdr.ether_type = rte_cpu_to_be_16(RTE_ETHER_TYPE_IPV4),
    };
    struct rte_flow_item_eth eth_mask = {
        .hdr.ether_type = RTE_BE16(0xffff),
    };

    struct rte_flow_item pattern[] = {
        {
            .type = RTE_FLOW_ITEM_TYPE_ETH,
            .spec = &eth_spec,
            .mask = &eth_mask,
        },
        {
            .type = RTE_FLOW_ITEM_TYPE_IPV4,
        },
        {
            .type = RTE_FLOW_ITEM_TYPE_TCP,
        },
        {
            .type = RTE_FLOW_ITEM_TYPE_END,
        },
    };

    struct rte_flow_action_rss rss = {
        .types = RTE_ETH_RSS_TCP,
        .queue_num = nb_queues,
        .queue = queues,
    };
    struct rte_flow_action actions[] = {
        {
            .type = RTE_FLOW_ACTION_TYPE_RSS,
            .conf = &rss,
        },
        {
            .type = RTE_FLOW_ACTION_TYPE_END,
        },
    };

    if (rte_flow_validate(port_id, &attr, pattern, actions, &error) != 0) {
        printf("rss flow validate failed: %s\n",
               error.message ? error.message : "unknown");
        return NULL;
    }

    return rte_flow_create(port_id, &attr, pattern, actions, &error);
}
```

### 4.5 drop 和 count

硬件 drop 适合丢弃明确不需要进入 CPU 的流量，比如黑名单、异常端口、攻击流量。

```c
struct rte_flow_action actions[] = {
    { .type = RTE_FLOW_ACTION_TYPE_DROP },
    { .type = RTE_FLOW_ACTION_TYPE_END },
};
```

很多 PMD 支持 `COUNT`，但不是所有规则组合都支持。生产代码必须先 `rte_flow_validate()`，失败时降级到软件路径。

---

## 5. 队列、描述符和 NUMA

### 5.1 队列数怎么选

```
常见模型:

1 lcore : 1 RX queue : 1 TX queue

┌────────┐     ┌──────────┐     ┌────────┐
│ queue0 │ ──> │ lcore 0  │ ──> │ txq0   │
│ queue1 │ ──> │ lcore 1  │ ──> │ txq1   │
│ queue2 │ ──> │ lcore 2  │ ──> │ txq2   │
│ queue3 │ ──> │ lcore 3  │ ──> │ txq3   │
└────────┘     └──────────┘     └────────┘
```

经验规则：

- 队列数不要超过实际处理 lcore 数，否则只是在制造空轮询。
- 一个队列不要被多个 lcore 轮询，除非 PMD 明确支持并且你愿意承担同步成本。
- 端口所在 NUMA 节点上的 lcore 优先处理该端口。

### 5.2 主动外发时如何选择 lcore 和 TX queue

转发程序的回包通常可以继承 RX owner：哪个 lcore 收到连接，哪个 lcore 负责后续处理和发包。

主动外发不一样。比如 DPDK 应用自己作为客户端发起连接，第一包不是从 RX queue 进来的，就没有现成的 owner。此时应用需要自己做一次归属分配：

```
主动外发 flow
    │
    ▼
route lookup
    │
    ├─ 决定 tx_port
    │
    ▼
tx_port 所在 NUMA
    │
    ├─ 选择同 NUMA 的 lcore 集合
    │
    ├─ 选择同 NUMA 的 mempool
    │
    ▼
5-tuple hash
    │
    ├─ 在候选 lcore 里选 owner_lcore
    │
    ▼
owner_lcore
    │
    ├─ 使用它独占的 tx_queue
    └─ 后续这个 flow 的发送都交回这个 owner
```

完整关系如下：

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         主动外发的推荐归属模型                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  应用要主动连接 203.0.113.10:443                                            │
│                                                                             │
│  1. 路由查找                                                                │
│     dst_ip=203.0.113.10 → tx_port 0                                         │
│                                                                             │
│  2. 查询网卡 NUMA                                                           │
│     rte_eth_dev_socket_id(port 0) → NUMA 0                                  │
│                                                                             │
│  3. 只在 NUMA 0 的 lcore 中选择 owner                                       │
│                                                                             │
│     NUMA 0 lcore set:                                                       │
│       lcore 0 → tx_queue 0 → mempool N0                                     │
│       lcore 1 → tx_queue 1 → mempool N0                                     │
│       lcore 2 → tx_queue 2 → mempool N0                                     │
│       lcore 3 → tx_queue 3 → mempool N0                                     │
│                                                                             │
│  4. 使用 5-tuple hash 选一个稳定 owner                                      │
│                                                                             │
│       hash(src_ip, dst_ip, src_port, dst_port, proto) % 4 = 2               │
│                                                                             │
│       → owner_lcore = lcore 2                                                │
│       → tx_queue = 2                                                        │
│       → mbuf pool = mempool N0                                              │
│                                                                             │
│  5. 后续这个 flow 的所有发送都走 lcore 2                                    │
│                                                                             │
│       lcore 2: rte_eth_tx_burst(port 0, queue 2, pkts, n)                  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

可以把主动外发的归属信息记录在 flow/session 里：

```c
struct flow_owner {
    uint16_t tx_port;
    uint16_t tx_queue;
    unsigned owner_lcore;
    int socket_id;
    struct rte_mempool *mp;
};

static struct flow_owner
assign_outgoing_flow(const struct five_tuple *ft)
{
    uint16_t tx_port = route_lookup(ft->dst_ip);
    int socket = rte_eth_dev_socket_id(tx_port);
    if (socket < 0)
        socket = 0;

    const struct lcore_set *set = &lcores_on_socket[socket];
    unsigned idx = hash_five_tuple(ft) % set->count;
    unsigned owner = set->lcores[idx];

    return (struct flow_owner) {
        .tx_port = tx_port,
        .tx_queue = lcore_to_txq[owner],
        .owner_lcore = owner,
        .socket_id = socket,
        .mp = mempool_on_socket[socket],
    };
}
```

发包时有两种情况：

```
当前 lcore == owner_lcore
    │
    └─ 直接 rte_eth_tx_burst(tx_port, tx_queue, ...)

当前 lcore != owner_lcore
    │
    └─ 不要直接抢 owner 的 tx_queue
       把 mbuf 指针 enqueue 到 owner_lcore 的 tx_ring
       由 owner_lcore 统一 tx_burst
```

错误模型如下：

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           主动外发选错的代价                                │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  tx_port 0 在 NUMA 0                                                         │
│  但应用在 NUMA 1 的 lcore 20 上分配 mbuf 并直接发包                         │
│                                                                             │
│  lcore 20 (NUMA 1)                                                           │
│      │                                                                      │
│      ├─ 从 NUMA 1 mempool 分配 mbuf                                          │
│      ├─ 写 packet buffer                                                     │
│      └─ rte_eth_tx_burst(port 0, queue 0, mbuf)                              │
│             │                                                               │
│             ▼                                                               │
│        NIC port 0 (NUMA 0) 通过 DMA 读取 NUMA 1 内存                         │
│                                                                             │
│  结果:                                                                      │
│  - lcore 访问远端 NIC descriptor / doorbell                                  │
│  - NIC DMA 读取远端 NUMA 内存                                                │
│  - cache line 跨 socket 迁移                                                 │
│  - 多 lcore 共享 TX queue 时还可能产生同步竞争                               │
│                                                                             │
│  通常不会功能错误，但吞吐和尾延迟会变差。                                   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

主动外发的原则就是：**先根据路由选 port，再根据 port 的 NUMA 选 lcore/mempool/TX queue，最后用 5-tuple hash 保证同一连接稳定归属同一个 lcore。**

### 5.3 描述符设置

```c
static int
setup_queues(uint16_t port_id, uint16_t nb_rxq, uint16_t nb_txq,
             uint16_t nb_rxd, uint16_t nb_txd,
             struct rte_mempool **pools_by_socket)
{
    struct rte_eth_dev_info dev_info;
    int ret = rte_eth_dev_info_get(port_id, &dev_info);
    if (ret != 0)
        return ret;

    ret = rte_eth_dev_adjust_nb_rx_tx_desc(port_id, &nb_rxd, &nb_txd);
    if (ret != 0)
        return ret;

    int socket_id = rte_eth_dev_socket_id(port_id);
    unsigned int setup_socket = socket_id < 0 ? SOCKET_ID_ANY : (unsigned int)socket_id;
    unsigned int pool_socket = socket_id < 0 ? 0 : (unsigned int)socket_id;

    struct rte_eth_rxconf rxq_conf = dev_info.default_rxconf;
    rxq_conf.offloads = 0;
    rxq_conf.rx_free_thresh = 32;
    rxq_conf.rx_drop_en = 1;

    struct rte_eth_txconf txq_conf = dev_info.default_txconf;
    txq_conf.offloads = 0;
    txq_conf.tx_free_thresh = 32;
    txq_conf.tx_rs_thresh = 32;

    for (uint16_t q = 0; q < nb_rxq; q++) {
        ret = rte_eth_rx_queue_setup(port_id, q, nb_rxd, setup_socket,
                                     &rxq_conf, pools_by_socket[pool_socket]);
        if (ret != 0)
            return ret;
    }

    for (uint16_t q = 0; q < nb_txq; q++) {
        ret = rte_eth_tx_queue_setup(port_id, q, nb_txd, setup_socket, &txq_conf);
        if (ret != 0)
            return ret;
    }

    return 0;
}
```

描述符不是越大越好：

| 参数             | 太小             | 太大                           |
| ---------------- | ---------------- | ------------------------------ |
| RX desc          | 突发流量容易丢包 | 占内存、cache 压力大、延迟变高 |
| TX desc          | 短 burst 容易堵  | mbuf 回收滞后，内存占用升高    |
| `rx_free_thresh` | 频繁回收描述符   | 回收滞后                       |
| `tx_rs_thresh`   | 写回频繁         | 完成通知滞后                   |

常用起点：`rxq=core_count`、`txq=core_count`、`rxd=1024`、`txd=1024`。小包极限压测可以试 `2048`，低延迟场景可以试 `512`。

### 5.4 NUMA 对齐

```c
static unsigned
pick_lcores_on_port_socket(uint16_t port_id, unsigned *lcores, unsigned max_lcores)
{
    int socket = rte_eth_dev_socket_id(port_id);
    unsigned n = 0;

    RTE_LCORE_FOREACH_WORKER(lcore_id) {
        if (socket >= 0 && rte_lcore_to_socket_id(lcore_id) != socket)
            continue;

        lcores[n++] = lcore_id;
        if (n == max_lcores)
            break;
    }

    return n;
}
```

跨 NUMA 的代价很真实：

```
NIC DMA 到 socket 0 hugepage
        │
        ▼
socket 1 lcore 读取 mbuf 和 packet
        │
        └─ 每包都跨 UPI/QPI 访问内存，吞吐下降且尾延迟上升
```

---

## 6. Offload：只打开你真的使用的能力

### 6.1 offload 是什么

offload 就是**让网卡硬件代劳某些工作**，而不是 CPU 做完再交给网卡。

```
没有 offload:

CPU 构建包头 → CPU 计算 checksum → CPU 拷贝到 NIC buffer → NIC 发送
                   ↑
               这步可以卸载给网卡


有 TX checksum offload:

CPU 构建包头 (checksum 填 0) → CPU 填 l2_len/l3_len → NIC 发送时自动算 checksum
                                                       ↑
                                                   硬件完成
```

### 6.2 offload 不是总开关，是一组 bit flag

offload 不是 `ON/OFF` 一个总开关，而是**每个能力一个 bit**，按需组合：

```c
// 不是这样:
offloads = ON;   // 全开
offloads = OFF;  // 全关

// 而是这样，每个 bit 控制一个能力:
uint64_t rx_offloads =
    RTE_ETH_RX_OFFLOAD_IPV4_CKSUM      // bit: 硬件验证 IPv4 checksum
  | RTE_ETH_RX_OFFLOAD_TCP_CKSUM       // bit: 硬件验证 TCP checksum
  | RTE_ETH_RX_OFFLOAD_RSS_HASH;       // bit: 硬件把 RSS hash 写入 mbuf
```

常见 RX offload：

| bit          | 含义                                    | 什么时候开           |
| ------------ | --------------------------------------- | -------------------- |
| `IPV4_CKSUM` | 硬件验证入包 IPv4 checksum              | 做路由/防火墙/转发时 |
| `TCP_CKSUM`  | 硬件验证入包 TCP checksum               | L4 处理时            |
| `UDP_CKSUM`  | 硬件验证入包 UDP checksum               | UDP 场景             |
| `VLAN_STRIP` | 硬件自动剥离 VLAN tag                   | 做 VLAN 终结时       |
| `RSS_HASH`   | 硬件把 RSS hash 写入 `mbuf->hash.rss`   | 用 RSS 时必须开      |
| `SCATTER`    | 允许一个包分散在多个 mbuf (jumbo frame) | 大包场景             |
| `TIMESTAMP`  | 硬件打时间戳写入 mbuf                   | 精确延迟测量时       |

常见 TX offload：

| bit          | 含义                       | 什么时候开     |
| ------------ | -------------------------- | -------------- |
| `IPV4_CKSUM` | 硬件计算发包 IPv4 checksum | 几乎总开       |
| `TCP_CKSUM`  | 硬件计算发包 TCP checksum  | 几乎总开       |
| `UDP_CKSUM`  | 硬件计算发包 UDP checksum  | UDP 场景       |
| `TCP_TSO`    | TCP 大段分段卸载           | 大段发送时     |
| `MULTI_SEGS` | 允许跨多个 mbuf 发送       | jumbo frame 时 |

### 6.3 两层配置：port-level 和 queue-level

offload 配置分两层，最终效果是**两层取并集**：

```
port-level offloads
  rte_eth_conf.rxmode.offloads
  rte_eth_conf.txmode.offloads
  │
  │ 在 rte_eth_dev_configure() 时设置
  │ 声明这个端口的所有队列共享的能力
  │
  └── 每个 queue 继承 port-level 设置
      │
      + queue-level offloads
        rte_eth_rxconf.offloads
        rte_eth_txconf.offloads
        │
        │ 在 rte_eth_rx_queue_setup() 时设置
        │ 可以额外补充 port-level 没开的能力
        │
        └── 最终 = port-level | queue-level
```

```c
// port-level: 所有队列共享的能力
struct rte_eth_conf port_conf = {
    .rxmode = {
        .offloads = RTE_ETH_RX_OFFLOAD_IPV4_CKSUM
                  | RTE_ETH_RX_OFFLOAD_TCP_CKSUM
                  | RTE_ETH_RX_OFFLOAD_RSS_HASH,
    },
    .txmode = {
        .offloads = RTE_ETH_TX_OFFLOAD_IPV4_CKSUM
                  | RTE_ETH_TX_OFFLOAD_TCP_CKSUM
                  | RTE_ETH_TX_OFFLOAD_TCP_TSO,
    },
};
rte_eth_dev_configure(port, nb_rxq, nb_txq, &port_conf);

// queue-level: 某个队列额外启用 scatter
struct rte_eth_rxconf rxq_conf = {
    .offloads = RTE_ETH_RX_OFFLOAD_SCATTER,  // 额外能力
};
rte_eth_rx_queue_setup(port, queue_id, ..., &rxq_conf, mp);
// 这个 queue 最终 = port_offloads | RTE_ETH_RX_OFFLOAD_SCATTER
```

### 6.4 开之前先查硬件能力

不是所有网卡都支持所有 offload。**开之前必须查 `dev_info` 确认**：

```c
struct rte_eth_dev_info dev_info;
rte_eth_dev_info_get(port_id, &dev_info);

// 查看支持哪些
printf("RX offload capa: 0x%lx\n", dev_info.rx_offload_capa);
printf("TX offload capa: 0x%lx\n", dev_info.tx_offload_capa);

// 检查某个能力
if (dev_info.tx_offload_capa & RTE_ETH_TX_OFFLOAD_TCP_TSO) {
    // 网卡支持 TSO，可以开
}

// 如果你开了一个网卡不支持的能力，rte_eth_dev_configure() 会失败
```

推荐做法：用 `dev_info.default_rxconf` 和 `dev_info.default_txconf` 作为起点，只修改你确定需要的能力。

### 6.2 checksum offload

TX checksum offload 不是只配置端口就完了，发送每个 mbuf 时也要填 header 长度和 `ol_flags`。

```c
#include <rte_ip.h>
#include <rte_udp.h>

static void
prepare_ipv4_udp_tx_cksum(struct rte_mbuf *m)
{
    struct rte_ether_hdr *eth = rte_pktmbuf_mtod(m, struct rte_ether_hdr *);
    struct rte_ipv4_hdr *ip = (struct rte_ipv4_hdr *)(eth + 1);
    struct rte_udp_hdr *udp = (struct rte_udp_hdr *)((char *)ip + sizeof(*ip));

    m->l2_len = sizeof(struct rte_ether_hdr);
    m->l3_len = sizeof(struct rte_ipv4_hdr);

    ip->hdr_checksum = 0;
    udp->dgram_cksum = rte_ipv4_phdr_cksum(ip, RTE_MBUF_F_TX_UDP_CKSUM);

    m->ol_flags |= RTE_MBUF_F_TX_IPV4 |
                   RTE_MBUF_F_TX_IP_CKSUM |
                   RTE_MBUF_F_TX_UDP_CKSUM;
}
```

如果 `m->l2_len` / `m->l3_len` 没填，很多 PMD 无法知道从哪里开始计算 checksum。

---

## 7. 轮询、中断与混合模式

### 7.1 数据面默认用轮询

DPDK 的核心假设是 poll mode：

```
while (1) {
    nb_rx = rte_eth_rx_burst(...);
    if (nb_rx)
        process(nb_rx);
}
```

高吞吐时轮询是正确选择，因为避免了中断、唤醒、调度、cache 冷启动。

### 7.2 低流量可以用 RX interrupt

RX interrupt 适合低流量、省电、控制面队列，不适合极限数据面。

现代 ethdev 的常见用法是把 RX queue fd 接入 epoll：

```c
#include <sys/epoll.h>
#include <rte_ethdev.h>

static int
wait_rx_queue(uint16_t port_id, uint16_t queue_id, int epfd)
{
    int fd = rte_eth_dev_rx_intr_ctl_q_get_fd(port_id, queue_id);
    if (fd < 0)
        return fd;

    struct epoll_event ev = {
        .events = EPOLLIN,
        .data.u32 = queue_id,
    };

    if (epoll_ctl(epfd, EPOLL_CTL_ADD, fd, &ev) < 0)
        return -errno;

    int ret = rte_eth_dev_rx_intr_enable(port_id, queue_id);
    if (ret != 0)
        return ret;

    struct epoll_event events[16];
    ret = epoll_wait(epfd, events, RTE_DIM(events), 1000);

    rte_eth_dev_rx_intr_disable(port_id, queue_id);
    return ret;
}
```

不要使用不存在的 `rte_eth_dev_get_intr_handle()`。ethdev 提供的是 RX queue interrupt 控制接口和事件 callback 接口。

### 7.3 link 状态事件

link 变化不是 RX 数据包中断，应该用 ethdev callback：

```c
static int
link_event_cb(uint16_t port_id, enum rte_eth_event_type type,
              void *param, void *ret_param)
{
    struct rte_eth_link link;

    RTE_SET_USED(param);
    RTE_SET_USED(ret_param);

    if (type != RTE_ETH_EVENT_INTR_LSC)
        return 0;

    rte_eth_link_get_nowait(port_id, &link);
    printf("port %u link %s speed %u\n",
           port_id, link.link_status ? "up" : "down", link.link_speed);
    return 0;
}

static int
register_link_callback(uint16_t port_id)
{
    return rte_eth_dev_callback_register(port_id, RTE_ETH_EVENT_INTR_LSC,
                                         link_event_cb, NULL);
}
```

---

## 8. 调优验证路线

### 8.1 先用 testpmd 定基线

```bash
sudo dpdk-testpmd -l 0-7 -n 4 \
  --socket-mem=4096,4096 \
  -- \
  --portmask=0x3 \
  --rxq=4 --txq=4 \
  --rxd=1024 --txd=1024 \
  --burst=32 \
  --forward-mode=io \
  --auto-start
```

验证顺序：

1. 单端口 RX drop 是否为 0。
2. 双端口 forwarding 是否达到线速。
3. 调整 `--burst`、`--rxd`、`--txd` 看吞吐和延迟变化。
4. 再引入自己的业务逻辑，否则无法判断瓶颈是在 PMD 还是业务代码。

### 8.2 看端口统计和 xstats

```c
static void
print_basic_stats(uint16_t port_id)
{
    struct rte_eth_stats s;

    if (rte_eth_stats_get(port_id, &s) != 0)
        return;

    printf("port %u ipackets=%" PRIu64 " opackets=%" PRIu64
           " imissed=%" PRIu64 " ierrors=%" PRIu64 " oerrors=%" PRIu64 "\n",
           port_id, s.ipackets, s.opackets, s.imissed,
           s.ierrors, s.oerrors);
}
```

`imissed` 上升通常说明 RX ring 来不及收，可能是：

- RX queue 太少。
- lcore 不够或处理逻辑太慢。
- NUMA 不匹配。
- burst 太小。
- mempool 缓冲不足。

### 8.3 perf 观察热点

```bash
sudo perf top -p $(pidof your_dpdk_app)

sudo perf record -F 999 -g -p $(pidof your_dpdk_app) -- sleep 30
sudo perf report
```

热点判断：

| 热点                     | 常见含义                     |
| ------------------------ | ---------------------------- |
| PMD rx/tx 函数           | 包量很高，可能是正常热点     |
| hash lookup              | flow table 太大或 cache miss |
| memcpy                   | 发生了不必要复制             |
| rte_pktmbuf_alloc/free   | mempool 压力或每包分配过多   |
| spinlock / atomic        | 跨核共享状态                 |
| rte_ring enqueue/dequeue | lcore 间传递太多             |

### 8.4 系统设置检查

```bash
# CPU 隔离、nohz_full、rcu_nocbs 是否生效
cat /proc/cmdline

# hugepage
grep Huge /proc/meminfo
find /dev/hugepages -maxdepth 1 -type f | wc -l

# NUMA
lscpu | grep -E 'NUMA|Socket|CPU\\(s\\)'
cat /sys/class/net/$IFACE/device/numa_node

# IRQ affinity，数据面核心不应承载无关中断
cat /proc/interrupts | grep -i "$IFACE"

# 网卡 offload 能力
ethtool -k $IFACE
```

生产部署时，DPDK 数据面核心通常配合：

```text
isolcpus=2-15 nohz_full=2-15 rcu_nocbs=2-15 irqaffinity=0,1
```

这些不是默认开启，需要作为内核启动参数配置。

---

## 9. 常见调优决策表

| 现象              | 优先检查                               | 常见修复                                                 |
| ----------------- | -------------------------------------- | -------------------------------------------------------- |
| 小包 PPS 不够     | batch、队列数、NUMA、cache miss        | `BURST_SIZE=32/64`，每核独占队列                         |
| `imissed` 增长    | RX ring、处理耗时、mempool             | 增加队列/lcore，增大 `rxd`，优化业务路径                 |
| TX 发不满         | `tx_burst` partial、TX desc、mbuf 回收 | 处理未发送 mbuf，调 `txd/tx_free_thresh`                 |
| 多核不均衡        | RSS key、RETA、流量 hash 字段          | 查 `hash.rss`，重配 RETA，必要时用 `rte_flow`            |
| 低延迟抖动        | 中断、调度、跨 NUMA、频率变化          | CPU 隔离、固定频率、NUMA 本地化                          |
| CPU 高但吞吐低    | memcpy、锁、跨核 ring                  | 零拷贝、per-lcore 状态、减少跨核传递                     |
| rte_flow 下发失败 | PMD 能力不支持                         | `rte_flow_validate()` 打印 `error.message`，降级软件路径 |

---

## 10. 小结

1. DPDK 性能调优先从 batch、队列、NUMA 和 cache miss 开始，不要一上来调复杂参数。
2. RSS 负责通用分流，`rte_flow` 负责精确分类，两者可以组合使用。
3. 现代 DPDK 应使用 `rte_flow`，不要再写旧 Flow Director 私有 API。
4. RETA 的正确 API 是 `rte_eth_dev_rss_reta_update()`，数据结构是 `struct rte_eth_rss_reta_entry64`。
5. RX interrupt 是低流量/控制面工具，不是高 PPS 数据面的默认选择。
6. offload 需要硬件能力、端口配置、mbuf `ol_flags` 和 header length 同时正确，缺一不可。
7. 所有调优都要先用 testpmd 建基线，再用 stats/xstats/perf 定位瓶颈。

实战练习见 [[2026-05-29-dpdk-performance-tuning-practice|DPDK 性能调优实战]]，包含 bad/good 对照代码和完整的瓶颈定位流程。

---

> 参考：
>
> - [[2026-05-29-dpdk-performance-tuning-practice|DPDK 性能调优实战]]
> - DPDK Programmer's Guide: Poll Mode Driver
> - DPDK Programmer's Guide: RSS
> - DPDK Programmer's Guide: Generic flow API (`rte_flow`)
> - DPDK API: `rte_ethdev.h`, `rte_flow.h`, `rte_mbuf_core.h`
> - Intel DPDK Performance Reports and testpmd user guide
