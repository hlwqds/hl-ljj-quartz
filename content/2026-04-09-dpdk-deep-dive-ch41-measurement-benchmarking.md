---
title: "DPDK 深度探索 ch41：性能测量与基准测试"
date: 2026-04-10 16:00:00
tags: [dpdk, benchmark, performance, measurement, profiling, latency, throughput]
description: "深入解析 DPDK 性能测量：吞吐量测试、延迟测量、CPU profiling、Cache 性能、基准测试工具"
---

# DPDK 深度探索 ch41：性能测量与基准测试

> [!abstract] 核心要点
> 性能优化始于精确测量。本章深入解析 DPDK 性能测试方法、基准测试工具、关键指标与数据采集。

## 1. 性能指标

### 1.1 核心指标

```
DPDK 关键性能指标：

┌─────────────────────────────────────────────────────────────┐
│                    性能指标体系                             │
│                                                              │
│  吞吐量 (Throughput):                                      │
│  - Mpps (Million packets per second)                      │
│  - Gbps (Gigabits per second)                             │
│  - 线速计算: 64B @ 10G = 14.88 Mpps                       │
│                                                              │
│  延迟 (Latency):                                           │
│  - 平均延迟 (μs)                                          │
│  - P50/P90/P99 延迟                                        │
│  - 抖动 (Jitter)                                           │
│                                                              │
│  资源利用率:                                               │
│  - CPU 利用率 (%)                                          │
│  - Cache miss rate                                        │
│  - Memory bandwidth                                       │
│                                                              │
│  丢包率 (Packet Loss):                                     │
│  - 接收丢包率                                              │
│  - 转发丢包率                                              │
│  - 背压信号                                                │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 吞吐量计算

```c
// 线速计算
// 10GE: 1,488,095 pps @ 64B (全双工)
// 10GE: 1,453,514 pps @ 64B (单向)

// 计算公式
uint64_t
line_rate_pps(uint32_t packet_size, uint32_t speed_mbps)
{
    // 以太网开销
    uint32_t overhead = 20;  // preamble(8) + IFG(12)
    uint32_t total_size = packet_size + overhead;

    // 比特/秒
    uint64_t bits_per_sec = speed_mbps * 1000000;

    // 包/秒 = 比特/秒 / (总字节 * 8)
    return bits_per_sec / (total_size * 8);
}

// 示例
printf("64B @ 10G: %lu pps\n", line_rate_pps(64, 10000));
// 输出: 14880952 pps

printf("1518B @ 10G: %lu pps\n", line_rate_pps(1518, 10000));
// 输出: 812743 pps
```

## 2. Testpmd

### 2.1 Testpmd 概述

```
Testpmd — DPDK 官方测试工具：

┌─────────────────────────────────────────────────────────────┐
│                    Testpmd 架构                            │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              Testpmd Application                      │  │
│  │                                                       │  │
│  │  - 轮询模式 (PMD)                                  │  │
│  │  - 可配置转发模式                                   │  │
│  │  - 实时统计                                        │  │
│  │  - Flow rules                                      │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              DPDK PMD (igb_uio/ vfio-pci)             │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 基本使用

```bash
# 启动 testpmd
sudo ./build/app/testpmd -l 0-3 -n 4 \
    -- -i \
    --burst=64 \
    --txpkts=64 \
    --rxd=512 \
    --txd=512 \
    --nb-cores=2

# 交互命令
testpmd> show port info all
testpmd> start
testpmd> show stats
testpmd> stop
testpmd> clear stats
```

### 2.3 转发模式

```bash
# 查看可用转发模式
testpmd> show fwd capabilities

# 常见转发模式
# 1. io (轮询 I/O)
testpmd> set fwd io

# 2. mac (MAC 地址交换)
testpmd> set fwd mac

# 3. macswap (MAC 交换)
testpmd> set fwd macswap

# 4. rxonly (仅接收)
testpmd> set fwd rxonly

# 5. txonly (仅发送)
testpmd> set fwd txonly

# 6. noisy (模拟噪声)
testpmd> set fwd noisy
```

### 2.4 吞吐量测试

```bash
# 设置流量
testpmd> set txpkts 64,64,64,64,64  # 5 * 64B = 320B
testpmd> set txsplit on

# 设置速率
testpmd> set rates 50  # 50% 线速

# 设置连续流
testpmd> set corelist 0-3
testpmd> set tx 0

# 运行测试
testpmd> start

# 查看统计
testpmd> show port stats all
testpmd> show fwd stats all
```

## 3. Pktgen

### 3.1 Pktgen 简介

```
Pktgen — DPDK 流量生成器：

- 基于 Lua 脚本
- 实时配置
- 多流支持
- 精确速率控制

项目地址：https://pktgen-dpdk.readthedocs.io/
```

### 3.2 基本使用

```bash
# 启动 pktgen
sudo ./build/pktgen -l 0-5 -n 4 \
    -- -P -m [1-2:3-5].0

# 交互命令
pktgen> set 0 rate 100
pktgen> set 0 size 64
pktgen> start 0

# 查看统计
pktgen> stats 0
pktgen> pps 0
```

### 3.3 Lua 脚本

```lua
-- pktgen.lua
-- 发送 UDP 流

-- 配置端口 0
pktgen.set("0", "rate", 100)
pktgen.set("0", "size", 64)
pktgen.set("0", "proto", "udp")

-- 配置源/目的 MAC
pktgen.mac.src("0", "00:00:00:00:00:01")
pktgen.mac.dst("0", "00:00:00:00:00:02")

-- 配置 IP
pktgen.ip.src("0", "10.0.0.1", 256)  -- 256 flows
pktgen.ip.dst("0", "192.168.0.1", 256)

-- 配置端口
pktgen.udp.port.src("0", 1234, 1000)
pktgen.udp.port.dst("0", 5678, 100)

-- 开始发送
pktgen.start("0")

-- 打印统计
while true do
    pktgen.delay(1000)
    pktgen.stats(0)
end
```

## 4. Latency 测量

### 4.1 软件延迟测量

```c
// DPDK 软件延迟测量
#include <rte_cycles.h>

struct latency_stats {
    uint64_t min_latency;
    uint64_t max_latency;
    uint64_t total_latency;
    uint64_t count;

    // 百分位
    uint64_t latencies[10000];  // 采样
};

int
measure_latency(struct latency_stats *stats,
                struct rte_mbuf *pkt,
                uint64_t start_tsc)
{
    uint64_t end_tsc = rte_rdtsc();

    // 计算延迟 (CPU cycles → nanoseconds)
    uint64_t latency_ns = (end_tsc - start_tsc) *
                          1000000000 / rte_get_tsc_hz();

    // 更新统计
    if (stats->count == 0 || latency_ns < stats->min_latency)
        stats->min_latency = latency_ns;

    if (stats->count == 0 || latency_ns > stats->max_latency)
        stats->max_latency = latency_ns;

    stats->total_latency += latency_ns;
    stats->count++;

    return 0;
}
```

### 4.2 Packet RTT 测量

```c
// Wire-Speed Latency (环回测试)
int
measure_rtt_loopback(uint16_t port_id,
                     struct latency_stats *stats,
                     int duration_sec)
{
    uint64_t start_time = rte_get_timer_cycles();
    uint64_t end_time = start_time + rte_get_timer_hz() * duration_sec;

    uint64_t tx_count = 0;
    uint64_t rx_count = 0;

    // 轮询直到超时
    while (rte_get_timer_cycles() < end_time) {
        // 发送
        uint16_t nb_tx = rte_eth_tx_burst(port_id, 0, &pkt, 1);
        if (nb_tx > 0) {
            uint64_t tx_tsc = rte_rdtsc();
            tx_count++;
        }

        // 接收 (环回)
        uint16_t nb_rx = rte_eth_rx_burst(port_id, 0, &pkt, 1);
        if (nb_rx > 0) {
            uint64_t rx_tsc = rte_rdtsc();
            rx_count++;

            // 更新延迟
            uint64_t latency = rx_tsc - tx_tsc;
            // ... 更新统计
        }
    }

    return 0;
}
```

### 4.3 百分位计算

```c
// 计算百分位
void
calculate_percentiles(struct latency_stats *stats,
                      double *percentiles)
{
    // 假设 latencies[] 已填充
    qsort(stats->latencies, stats->count, sizeof(uint64_t),
          compare_uint64);

    for (int i = 0; i < 10; i++) {
        double p = (i + 1) * 10;  // 10%, 20%, ..., 90%, 99%
        size_t idx = (stats->count * p / 100) - 1;
        percentiles[i] = stats->latencies[idx];
    }
}

// 打印延迟分布
void
print_latency_histogram(struct latency_stats *stats)
{
    printf("Latency Histogram:\n");
    printf("  Min:    %lu ns\n", stats->min_latency);
    printf("  Avg:    %lu ns\n",
           stats->total_latency / stats->count);
    printf("  Max:    %lu ns\n", stats->max_latency);
    printf("  P50:    %lu ns\n", stats->latencies[stats->count * 50 / 100]);
    printf("  P90:    %lu ns\n", stats->latencies[stats->count * 90 / 100]);
    printf("  P99:    %lu ns\n", stats->latencies[stats->count * 99 / 100]);
    printf("  P99.9:  %lu ns\n",
           stats->latencies[stats->count * 999 / 1000]);
}
```

## 5. CPU Profiling

### 5.1 perf 工具

```bash
# 使用 perf 分析 DPDK 应用
# 1. 启动 DPDK 应用
sudo ./my_dpdk_app -l 0-3

# 2. 另一个终端 attach perf
sudo perf top -p <pid>

# 3. 记录
sudo perf record -F 99 -p <pid> -g -- sleep 30

# 4. 分析
sudo perf report
```

### 5.2 Cache Miss 分析

```bash
# Cache miss 分析
perf stat -e cache-references,cache-misses,bus-cycles \
    -p <pid> sleep 10

# 示例输出:
#   1,234,567,890 cache-references
#     123,456,789 cache-misses  (10.0% miss rate)
#   9,876,543,210 bus-cycles

# TLB miss 分析
perf stat -e dTLB-loads,dTLB-load-misses,dTLB-stores,dTLB-store-misses \
    -p <pid> sleep 10

# 指令分析
perf stat -e instructions,cycles,branches,branch-misses \
    -p <pid> sleep 10
```

### 5.3 DPDK 统计

```c
// DPDK 统计 API
#include <rte_ethdev.h>
#include <rte_per_lcore.h>

// 端口统计
void
show_port_stats(uint16_t port_id)
{
    struct rte_eth_stats stats;

    rte_eth_stats_get(port_id, &stats);

    printf("Port %u stats:\n", port_id);
    printf("  RX: %lu packets (%lu bytes)\n",
           stats.ipackets, stats.ibytes);
    printf("  TX: %lu packets (%lu bytes)\n",
           stats.opackets, stats.obytes);
    printf("  RX missed: %lu\n", stats.imissed);
    printf("  RX errors: %lu\n",
           stats.ierrors);
    printf("  TX errors: %lu\n",
           stats.oerrors);
    printf("  RX no mbuf: %lu\n", stats.rx_nombuf);
}

// 扩展统计
void
show_port_xstats(uint16_t port_id)
{
    struct rte_eth_xstat *xstats;
    int nb_xstats;

    nb_xstats = rte_eth_xstats_get(port_id, NULL, 0);
    xstats = malloc(sizeof(struct rte_eth_xstat) * nb_xstats);
    rte_eth_xstats_get(port_id, xstats, nb_xstats);

    for (int i = 0; i < nb_xstats; i++) {
        printf("  %s: %lu\n",
               rte_eth_xstat_name_get(port_id, i),
               xstats[i].value);
    }

    free(xstats);
}
```

## 6. 基准测试流程

### 6.1 测试设计

```
基准测试流程：

┌─────────────────────────────────────────────────────────────┐
│                    测试设计                                 │
│                                                              │
│  1. 确定测试目标                                            │
│     - 吞吐量 (Throughput)                                  │
│     - 延迟 (Latency)                                       │
│     - 资源效率 (Efficiency)                                │
│                                                              │
│  2. 选择测试场景                                            │
│     - 单流 / 多流                                          │
│     - 固定包大小 / 混合                                     │
│     - 突发流量 / 稳定流量                                  │
│                                                              │
│  3. 控制变量                                                │
│     - CPU 核心数                                            │
│     - 内存通道                                              │
│     - NIC 队列数                                            │
└─────────────────────────────────────────────────────────────┘
```

### 6.2 测试脚本

```python
#!/usr/bin/env python3
"""DPDK Benchmark Script"""

import subprocess
import time
import re

class DPDKBenchmark:
    def __init__(self, app_path):
        self.app_path = app_path
        self.results = []

    def run_test(self, test_name, duration=10):
        """运行单个测试"""
        # 启动 testpmd
        cmd = [
            self.app_path,
            "-l", "0-3",
            "--",
            "--burst=64",
            "--txpkts=64",
            "--forward-mode=io"
        ]

        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE)

        time.sleep(2)  # 等待启动

        # 发送开始命令
        proc.stdin.write(b"start\n")
        proc.stdin.flush()

        # 等待测试时间
        time.sleep(duration)

        # 获取统计
        proc.stdin.write(b"show port stats all\n")
        proc.stdin.flush()
        time.sleep(1)

        # 停止
        proc.stdin.write(b"quit\n")
        proc.wait()

        return self.parse_output(proc.stdout.read())

    def parse_output(self, output):
        """解析输出"""
        results = {}

        for line in output.decode().split('\n'):
            # 解析 RX/TX packets
            m = re.search(r'RX-packets: (\d+)', line)
            if m:
                results['rx_packets'] = int(m.group(1))

            m = re.search(r'TX-packets: (\d+)', line)
            if m:
                results['tx_packets'] = int(m.group(1))

        return results

    def generate_report(self):
        """生成报告"""
        print("=" * 60)
        print("DPDK Benchmark Report")
        print("=" * 60)

        for result in self.results:
            print(f"\nTest: {result['name']}")
            print(f"  Throughput: {result['pps']:.2f} Mpps")
            print(f"  Latency: {result['latency_avg']:.2f} μs")
            print(f"  Latency P99: {result['latency_p99']:.2f} μs")

if __name__ == "__main__":
    bench = DPDKBenchmark("./build/app/testpmd")
    bench.run_test("64B packets")
    bench.generate_report()
```

## 7. 总结

性能测试金字塔：

```
┌─────────────────────────────────────────────────────────────┐
│                    性能测试金字塔                           │
│                                                              │
│                      ┌─────────┐                           │
│                     │  基准   │  ← 真实业务流量             │
│                    └─────────┘                              │
│                   ┌───────────┐                              │
│                  │ 集成测试   │  ← 多组件交互               │
│                 └───────────┘                              │
│                ┌─────────────┐                              │
│               │  单元测试    │  ← 微基准测试                │
│              └─────────────┘                                │
└─────────────────────────────────────────────────────────────┘
```

关键指标：

| 指标 | 优秀 | 良好 | 差 |
|------|------|------|-----|
| **延迟 (64B)** | < 5 μs | 5-20 μs | > 20 μs |
| **吞吐量** | > 10 Gbps | 5-10 Gbps | < 5 Gbps |
| **CPU 效率** | > 10 Mpps/core | 5-10 Mpps/core | < 5 Mpps/core |
| **Cache miss** | < 5% | 5-15% | > 15% |

---

## 参考资源

- [DPDK Testpmd](https://doc.dpdk.org/guides/testpmd_app_ug/)
- [Pktgen](https://pktgen-dpdk.readthedocs.io/)
- [perf Manual](https://perf.wiki.kernel.org/)
