---
title: "DPDK 性能调优实战：从瓶颈定位到修复"
date: 2026-05-29 12:00:00
tags: [dpdk, performance, practice, batching, RSS, NUMA, offload, profiling]
description: "对照 bad/good 两版代码，用 perf/xstats/ethtool 定位 DPDK 应用性能瓶颈，逐步修复"
---

# DPDK 性能调优实战：从瓶颈定位到修复

> 关联章节：[[ch30-performance-tuning|DPDK 深度探索 (三十)：性能调优]]
> 实战代码：`practice/dpdk_perf_tuning/`

## 1. 目标

本文不是理论，是**操作手册**。目标：

- 有一份故意写坏的 L2 转发程序 `bad_l2fwd.c`
- 用工具定位它为什么慢
- 对照 `good_l2fwd.c` 看每一步怎么修
- 最终掌握 DPDK 性能问题的定位流程

```
bad_l2fwd.c  →  perf/xstats/ethtool 定位瓶颈  →  对照 good_l2fwd.c 修复
     ↑                                                    │
     └──────── 故意制造 6 个典型性能陷阱 ─────────────────┘
```

## 2. 环境准备

### 2.1 硬件要求

- 至少 2 个 DPDK 可管理的网口（双口网卡即可）
- 8 核以上 CPU，建议 2 个 NUMA socket
- 1024+ 1GB hugepage

### 2.2 软件要求

```bash
# DPDK 24.11+
dpdk_version=$(cat /usr/local/include/dpdk/rte_version.h 2>/dev/null | grep RTE_VERSION | head -1)
echo "DPDK: $dpdk_version"

# perf
perf --version

# ethtool
ethtool --version 2>&1 | head -1

# 测试工具
iperf3 --version
```

### 2.3 编译实战代码

```bash
cd practice/dpdk_perf_tuning/

# 编译坏版本
meson setup build-bad -Dc_args="-DBAD_BUILD"
# 或直接:
gcc -o bad_l2fwd bad_l2fwd.c \
    -I/usr/local/include/dpdk \
    -lrte_eal -lrte_ethdev -lrte_mbuf -lrte_mempool \
    -Wl,--whole-archive -lrte_bus_pci -lrte_bus_vdev \
    -Wl,--no-whole-archive -lpthread -lnuma

# 编译好版本
gcc -o good_l2fwd good_l2fwd.c \
    -I/usr/local/include/dpdk \
    -lrte_eal -lrte_ethdev -lrte_mbuf -lrte_mempool \
    -Wl,--whole-archive -lrte_bus_pci -lrte_bus_vdev \
    -Wl,--no-whole-archive -lpthread -lnuma
```

## 3. 六个典型性能陷阱

### 陷阱 1：单包收发（没有 Batching）

**bad_l2fwd.c 中的代码：**

```c
// 每次只取 1 个包
while (!quit) {
    uint16_t nb = rte_eth_rx_burst(port_in, 0, &m, 1);  // burst=1
    if (nb == 0) continue;

    process(m);

    rte_eth_tx_burst(port_out, 0, &m, 1);  // 单包发
}
```

**为什么慢：**

```
每包开销:
  rx_burst():  函数调用 + 参数检查 + 读 RX ring + 写 doorbell  ≈ 200ns
  tx_burst():  函数调用 + 参数检查 + 写 TX ring + 写 doorbell  ≈ 200ns
  处理:        交换 MAC 地址                                    ≈ 50ns

单包总开销 = 200 + 50 + 200 = 450ns
32 包 = 32 × 450ns = 14.4μs

正确做法 (burst=32):
  1 次 rx_burst + 32 次处理 + 1 次 tx_burst = 200 + 32×50 + 200 = 2.0μs
  32 包总开销 = 2.0μs

节省: 14.4μs → 2.0μs = 7x 加速
```

**如何定位：**

```bash
# perf 看热点：rx_burst/tx_burst 调用次数异常多
sudo perf top -p $(pidof bad_l2fwd)

# 你会看到:
#   40%  rte_eth_rx_burst     ← 调用太频繁
#   35%  rte_eth_tx_burst     ← 同上
#    5%  memcpy               ← 陷阱 2
#    ...
```

**good_l2fwd.c 的修复：**

```c
#define BURST_SIZE 32

while (!quit) {
    uint16_t nb_rx = rte_eth_rx_burst(port_in, queue_id,
            rx_bufs, BURST_SIZE);  // 一次收 32 个
    if (nb_rx == 0) continue;

    for (uint16_t i = 0; i < nb_rx; i++)
        process(rx_bufs[i]);

    rte_eth_tx_burst(port_out, queue_id, tx_bufs, nb_tx);  // 一次发 32 个
}
```

---

### 陷阱 2：不必要的 memcpy

**bad_l2fwd.c 中的代码：**

```c
struct rte_ether_hdr *eth = rte_pktmbuf_mtod(m, struct rte_ether_hdr *);

char tmp[2048];
memcpy(tmp, eth, m->pkt_len);      // 把整个包复制到栈上
memcpy(eth, tmp, m->pkt_len);      // 再复制回来

// 然后才交换 MAC
```

**为什么慢：**

```
L2 转发只需要修改 12 字节 MAC 地址。
但 memcpy 复制了整个 packet（可能 1518 字节）。

1518 字节 = ~24 条 cache line
memcpy 触发 24 次 cache line load + 24 次 cache line store

实际需要修改的: 12 字节 = 不到 1 条 cache line
```

**如何定位：**

```bash
# perf 看到大量 memcpy 占比
sudo perf top -p $(pidof bad_l2fwd)

# 你会看到:
#   15%  memcpy               ← 陷阱 2 在这里
```

**good_l2fwd.c 的修复：**

```c
// 零拷贝：就地修改 MAC 地址，只碰 12 字节
struct rte_ether_hdr *eth = rte_pktmbuf_mtod(m, struct rte_ether_hdr *);
struct rte_ether_addr tmp;
rte_ether_addr_copy(&eth->dst_addr, &tmp);
rte_ether_addr_copy(&eth->src_addr, &eth->dst_addr);
rte_ether_addr_copy(&tmp, &eth->src_addr);
```

---

### 陷阱 3：单队列无 RSS

**bad_l2fwd.c 中的代码：**

```c
// port_conf 没有启用 RSS
struct rte_eth_conf port_conf = {0};  // 空 = 没有 RSS

// 只配 1 个队列
rte_eth_dev_configure(port, 1, 1, &port_conf);
```

**为什么慢：**

```
所有流量集中到 queue 0
只有一个 lcore 处理
其他 lcore 空闲

10Gbps 小包 (64B):
  线速 = 14.88 Mpps
  单核极限 ≈ 4-6 Mpps (取决于业务复杂度)
  结果: 只能到线速的 30-40%
```

**如何定位：**

```bash
# 查看队列分布
sudo perf top -p $(pidof bad_l2fwd)

# 只有一个线程在 100% CPU
# 其他线程完全空闲

# 用 top 看 CPU:
top -H -p $(pidof bad_l2fwd)
# 只有 thread 0 在 100%，其他都是 0%
```

**good_l2fwd.c 的修复：**

```c
struct rte_eth_conf port_conf = {
    .rxmode = {
        .mq_mode = RTE_ETH_MQ_RX_RSS,
    },
    .rx_adv_conf = {
        .rss_conf = {
            .rss_hf = RTE_ETH_RSS_IP | RTE_ETH_RSS_TCP | RTE_ETH_RSS_UDP,
        },
    },
};

uint16_t nb_rxq = 4;
uint16_t nb_txq = 4;
rte_eth_dev_configure(port, nb_rxq, nb_txq, &port_conf);
```

---

### 陷阱 4：NUMA 不对齐

**bad_l2fwd.c 中的代码：**

```c
// 只创建一个 mempool，不管 NUMA
struct rte_mempool *mp = rte_pktmbuf_pool_create("bad_pool",
        8191, 250, 0, RTE_MBUF_DEFAULT_BUF_SIZE, 0);
//                                                       ↑ 硬编码 socket 0

// 不管 port 在哪个 NUMA，都用这个 pool
port_init_bad(0, mp);
port_init_bad(1, mp);  // 如果 port 1 在 NUMA 1...
```

**为什么慢：**

```
假设:
  port 1 在 NUMA 1
  mempool 在 NUMA 0

每次 mbuf alloc:
  NUMA 1 的 CPU 访问 NUMA 0 的 hugepage → 跨 UPI/QPI

每次 rx_burst:
  NIC DMA 写到 pool 所在 NUMA 0 的 hugepage
  NUMA 1 的 CPU 读取 → 跨 NUMA

每包都有额外延迟:
  本地内存访问: ~80ns
  跨 NUMA 访问: ~130-150ns
  增加 50-70ns/包
```

**如何定位：**

```bash
# 查网卡 NUMA
cat /sys/class/net/eth0/device/numa_node
cat /sys/class/net/eth1/device/numa_node

# 查应用线程在哪个 NUMA
ps -T -p $(pidof bad_l2fwd) -o pid,tid,psr,comm

# perf 看 remote memory access
sudo perf stat -e 'uncore_imc/data_reads',\
  'uncore_imc/data_writes' -p $(pidof bad_l2fwd) -- sleep 5
```

**good_l2fwd.c 的修复：**

```c
// per-socket mempool
static struct rte_mempool *pools[RTE_MAX_NUMA_NODES];

static struct rte_mempool *
get_pool_for_socket(int socket_id)
{
    if (socket_id < 0) socket_id = 0;
    if (pools[socket_id]) return pools[socket_id];

    char name[64];
    snprintf(name, sizeof(name), "pool_s%d", socket_id);
    pools[socket_id] = rte_pktmbuf_pool_create(name,
            MBUF_POOL_SIZE, MBUF_CACHE_SIZE, 0,
            RTE_MBUF_DEFAULT_BUF_SIZE, socket_id);  // 对齐 NUMA
    return pools[socket_id];
}

// port 初始化时查 NUMA
int socket = rte_eth_dev_socket_id(port);
struct rte_mempool *mp = get_pool_for_socket(socket);
```

---

### 陷阱 5：没有开 offload

**bad_l2fwd.c 的表现：**

L2 转发不涉及 checksum，但如果应用做 L3/L4 处理，软件计算 checksum 会成为瓶颈。

```
软件 IPv4 checksum:
  遍历整个 IP header (20-60 字节) 做加法
  每包 ~30-50ns

软件 TCP checksum:
  遍历整个 TCP segment (可能 1460 字节)
  每包 ~200-500ns

硬件 checksum:
  网卡在 DMA 时自动完成
  CPU 开销 = 0
```

**如何定位：**

```bash
# perf 热点里有 csum 相关函数
sudo perf top -p $(pidof your_app)
# 如果看到 rte_ipv4_cksum / rte_ipv4_phdr_cksum 占比高
# → 考虑开 TX offload
```

**good_l2fwd.c 的修复：**

```c
// port 级别开启 offload
struct rte_eth_conf port_conf = {
    .txmode = {
        .offloads = RTE_ETH_TX_OFFLOAD_IPV4_CKSUM
                  | RTE_ETH_TX_OFFLOAD_UDP_CKSUM,
    },
};

// 发包时设置 mbuf ol_flags
m->ol_flags |= RTE_MBUF_F_TX_IPV4 |
               RTE_MBUF_F_TX_IP_CKSUM |
               RTE_MBUF_F_TX_UDP_CKSUM;
```

---

### 陷阱 6：printf 在数据面

**bad_l2fwd.c 中的代码：**

```c
for (uint16_t i = 0; i < nb_rx; i++) {
    process(rx_bufs[i]);
    printf("fwd packet len=%u\n", m->pkt_len);  // 每包 printf
}
```

**为什么慢：**

```
printf 开销:
  1. 格式化字符串     ~100ns
  2. 写 stdout buffer ~50-200ns
  3. 可能触发 fflush  ~1-10μs (I/O 阻塞)
  4. 破坏 CPU pipeline 和 cache

如果 stdout 是终端 (isatty):
  每行输出可能触发终端刷新
  开销可达 10-100μs/包

14.88 Mpps × 10μs = 完全不可能
```

**如何定位：**

```bash
sudo perf top -p $(pidof bad_l2fwd)

# 热点里看到:
#   30%  __GI___libc_write    ← printf 导致的 I/O
#   10%  _IO_file_overflow
```

**good_l2fwd.c 的修复：**

```c
// per-lcore 统计计数器
struct lcore_stats {
    uint64_t rx_pkts;
    uint64_t tx_pkts;
    uint64_t dropped;
} __rte_cache_aligned;

static struct lcore_stats lcore_stats[RTE_MAX_LCORE];

// 数据面只更新计数器
stats->rx_pkts += nb_rx;

// 定期打印 (每秒一次)
uint64_t now = rte_rdtsc();
if (now - last_print > rte_get_timer_hz()) {
    printf("lcore %u: rx=%lu tx=%lu drop=%lu\n",
            rte_lcore_id(), stats->rx_pkts,
            stats->tx_pkts, stats->dropped);
    last_print = now;
}
```

## 4. 瓶颈定位完整流程

不是上来就 perf，而是**分层排查**：

```
Step 1: testpmd 基线
  │
  ├─ testpmd 能线速吗？
  │    YES → 瓶颈在你的应用代码
  │    NO  → 瓶颈在系统/网卡配置
  │
  ▼
Step 2: ethtool 看网卡统计
  │
  ├─ imissed 在增长？
  │    → CPU 处理不过来，包在 NIC RX ring 溢出
  │    → 优化方向: 增大队列、增加 lcore、减少处理耗时
  │
  ├─ rx_nombuf 在增长？
  │    → mempool 耗尽
  │    → 优化方向: 增大 pool、检查泄漏
  │
  ▼
Step 3: xstats 看详细统计
  │
  ├─ 各队列分布不均？
  │    → RSS 失效或 key 配错
  │
  ├─ TX 发不满？
  │    → tx_burst partial、mbuf 回收不及时
  │
  ▼
Step 4: perf 看热点
  │
  ├─ rx_burst/tx_burst 占比高
  │    → burst 太小或没开批量
  │
  ├─ memcpy 占比高
  │    → 不必要的复制
  │
  ├─ hash lookup 占比高
  │    → flow table 太大、cache miss
  │
  ├─ lock/atomic 占比高
  │    → 跨核共享状态
  │
  ├─ rte_ring 占比高
  │    → lcore 间传递太多
  │
  ▼
Step 5: NUMA 检查
  │
  ├─ 网卡 NUMA vs lcore NUMA
  ├─ mempool NUMA vs lcore NUMA
  └─ 跨 NUMA 就有额外开销
```

### 4.1 Step 1: testpmd 基线

```bash
# 先用 testpmd 确认硬件能力
sudo dpdk-testpmd -l 0-7 -n 4 \
  --socket-mem=4096,4096 \
  -- \
  --portmask=0x3 \
  --rxq=4 --txq=4 \
  --rxd=1024 --txd=1024 \
  --burst=32 \
  --forward-mode=io \
  --auto-start

# 在 testpmd 交互界面:
testpmd> show port stats all
testpmd> show port xstats all

# 如果 testpmd 都达不到线速，先修系统/网卡问题
# 如果 testpmd 能线速但你的应用不行，瓶颈在代码
```

### 4.2 Step 2: ethtool 网卡统计

```bash
# 查看丢包
watch -n 1 "ethtool -S eth0 | grep -iE 'miss|drop|error|no_desc|alloc_fail'"

# 重点关注:
# rx_missed_errors    → NIC RX ring 溢出，CPU 来不及收
# rx_no_buffer        → mempool 分配失败
# rx_dropped          → 总丢包
```

### 4.3 Step 3: 应用内 xstats

```bash
# 用 dpdk-proc-info 查看详细统计
sudo dpdk-proc-info -- --xstats-name-prefix=rx_

# 或者在代码里打印:
# rte_eth_stats_get(port, &stats);
# printf("imissed=%lu\n", stats.imissed);
```

### 4.4 Step 4: perf 热点分析

```bash
# 实时热点
sudo perf top -p $(pidof your_app)

# 录制 30 秒
sudo perf record -F 999 -g -p $(pidof your_app) -- sleep 30
sudo perf report

# 看具体函数的开销
sudo perf annotate -p $(pidof your_app) memcpy
```

热点对照表：

| perf 热点                                | 含义         | 修复方向                    |
| ---------------------------------------- | ------------ | --------------------------- |
| `rte_eth_rx_burst` 占比异常高            | 调用太频繁   | 增大 burst size             |
| `rte_eth_tx_burst` 占比异常高            | 同上         | 增大 burst size             |
| `memcpy` / `rte_memcpy`                  | 不必要的复制 | 改用零拷贝、就地修改        |
| `rte_hash_lookup` / `rte_hash_add`       | 流表查找慢   | 减少 table 大小、优化 cache |
| `rte_ring_enqueue` / `dequeue`           | 跨核传递多   | 减少 lcore 间依赖           |
| `__rte_ring_do_enqueue_elem`             | ring 竞争    | 改用 per-lcore 结构         |
| `rte_pktmbuf_alloc` / `free`             | mempool 压力 | 增大 pool、检查泄漏         |
| `__libc_write` / `printf`                | 数据面 I/O   | 改用计数器                  |
| `spinlock` / `pthread_mutex`             | 锁竞争       | 改无锁结构或 per-lcore      |
| `rte_ipv4_cksum` / `rte_ipv4_phdr_cksum` | 软件checksum | 开硬件 offload              |

### 4.5 Step 5: NUMA 对齐检查

```bash
# 查网卡在哪个 NUMA
for iface in eth0 eth1; do
    echo "$iface NUMA: $(cat /sys/class/net/$iface/device/numa_node)"
done

# 查应用线程在哪个 NUMA
ps -T -p $(pidof your_app) -o pid,tid,psr,comm

# 用 perf 看 cache miss 和 remote access
sudo perf stat -e cache-misses,cache-references,\
  offcore_response.demand_data_rd.l3_hit.l3_hit_s \
  -p $(pidof your_app) -- sleep 10
```

### 4.6 自动诊断脚本

```bash
# 使用提供的诊断脚本
cd practice/dpdk_perf_tuning/
./diagnose.sh $(pidof your_app) eth0

# 输出:
# [14:30:01] CPU cycles: 1234567 | RX pps: 2456789 | TX pps: 2450000 | miss: 0 (0.00%)
# [14:30:03] CPU cycles: 1234000 | RX pps: 2478901 | TX pps: 2470000 | miss: 0 (0.00%)
# [14:30:05] CPU cycles: 1235000 | RX pps: 1234567 | TX pps: 1230000 | miss: 5000 (0.40%)
#                                                        ↑ throughput drop    ↑ miss 出现
```

## 5. bad vs good 对照表

| 陷阱     | bad_l2fwd.c        | good_l2fwd.c        | 性能差异 |
| -------- | ------------------ | ------------------- | -------- |
| Batching | `rx_burst(1)`      | `rx_burst(32)`      | ~7x      |
| memcpy   | 2048 字节复制      | 12 字节 MAC 交换    | ~3x      |
| 多队列   | 1 queue            | 4 queue + RSS       | ~4x      |
| NUMA     | 1 个 pool 硬编码   | per-socket pool     | ~1.5x    |
| offload  | 无                 | TX checksum offload | 视场景   |
| printf   | 每包 printf        | 计数器 + 定期打印   | ~10x+    |
| **综合** | **单核 ~3-5 Mpps** | **4核 ~30-50 Mpps** | **~10x** |

## 6. 实战练习建议

### 练习 1：对比 bad 和 good

```bash
# 1. 跑 bad_l2fwd，用 perf 记录
sudo ./bad_l2fwd -l 0 -n 4 --
sudo perf record -F 999 -g -p $(pidof bad_l2fwd) -- sleep 30
sudo perf report

# 2. 跑 good_l2fwd，同样 perf 记录
sudo ./good_l2fwd -l 0-3 -n 4 --
sudo perf record -F 999 -g -p $(pidof good_l2fwd) -- sleep 30
sudo perf report

# 3. 对比热点分布
```

### 练习 2：逐步修复

不要直接看 good_l2fwd.c，而是从 bad_l2fwd.c 开始，每次只修一个陷阱：

```
第 1 轮: 修 Batching (burst 1→32)
  → perf 看 rx_burst/tx_burst 占比下降
  → PPS 提升

第 2 轮: 去 memcpy
  → perf 看 memcpy 占比消失
  → PPS 提升

第 3 轮: 开 RSS + 多队列
  → top 看多核同时工作
  → 总 PPS 大幅提升

第 4 轮: NUMA 对齐
  → perf stat 看 cache miss 下降
  → 尾延迟降低

第 5 轮: 去 printf
  → perf 看 __libc_write 消失
  → PPS 提升

第 6 轮: 开 offload (如果做 L3/L4)
  → perf 看 checksum 函数消失
  → PPS 提升
```

### 练习 3：用 testpmd 做对照

```bash
# testpmd 是"最优参考实现"
# 你的应用 PPS 不应该低于 testpmd 太多

# 1. testpmd 基线
sudo dpdk-testpmd -l 0-3 -n 4 -- --rxq=4 --txq=4 --burst=32 --forward-mode=io --auto-start

# 2. 你的应用
sudo ./good_l2fwd -l 0-3 -n 4 --

# 3. 对比:
# testpmd 4核 IO forwarding: ~90-100 Mpps (64B)
# good_l2fwd 4核 L2 forward:  ~70-90 Mpps (64B)
# bad_l2fwd 1核:               ~3-5 Mpps (64B)
```

## 7. 常见问题

### Q: imissed 一直在增长怎么办？

```
imissed = NIC RX ring 溢出 = 包到了但 CPU 没及时收走

排查:
  1. burst size 太小? → 增到 32-64
  2. 处理耗时太长? → perf 看哪个函数占时间
  3. 队列太少? → 增加 RX queue + lcore
  4. RX desc 太少? → 增到 1024-2048
```

### Q: 多核不均衡怎么办？

```
排查:
  1. 查 RSS 是否生效: ethtool -x eth0
  2. 查各队列包量: xstats 按 queue 分
  3. 如果是隧道流量 → 参考 [[ch30-performance-tuning|ch30 3.3 隧道 RSS 失衡]]
  4. 考虑用 rte_flow 做精确分流
```

### Q: perf 看到大量 cache miss 怎么办？

```
排查:
  1. 数据结构是否跨 cache line? → __rte_cache_aligned
  2. 是否跨 NUMA 访问? → 对齐 NUMA
  3. 是否随机访问大表? → 改用更紧凑的数据结构
  4. 是否有多余的读? → 减少不必要字段访问
```

---

> 参考：
>
> - [[ch30-performance-tuning|DPDK 深度探索 (三十)：性能调优]]
> - DPDK Sample Application Guide: L2 Forwarding
> - DPDK Programmer's Guide: Performance Optimization
> - Intel DPDK Performance Reports
