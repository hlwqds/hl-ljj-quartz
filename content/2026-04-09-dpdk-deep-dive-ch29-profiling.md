---
title: "DPDK 深度探索 (二十九)：Profiling——dpdk-procinfo、perf、火焰图"
date: 2026-04-09
tags: [dpdk, series, profiling, perf, flamegraph, dpdk-procinfo, benchmark, hotspot, latency, throughput]
description: "深入理解 DPDK 性能分析——dpdk-procinfo、perf、火焰图、热点分析、延迟分布、吞吐量瓶颈定位"
---

> [!info] DPDK 深度探索系列
> 0. [[2026-04-09-dpdk-deep-dive-series-index|全栈学习路径总览]]
> 1-28. 前二十八章已完成
> 29. **第二十九章：Profiling——dpdk-procinfo、perf、火焰图**

---

## 1. 概述：为什么需要 Profiling

### 1.1 性能优化的前提

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        性能优化方法论                                       │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  错误的做法:                                                               │
│  ──────────                                                                │
│  1. 猜测热点 (基于直觉)                                                   │
│  2. 优化猜测的热点代码                                                     │
│  3. 期望性能提升                                                           │
│                                                                             │
│  问题:                                                                    │
│  - 直觉经常出错                                                           │
│  - 可能优化了不常用的代码                                                  │
│  - 可能引入新问题                                                          │
│  - 无法量化优化效果                                                        │
│                                                                             │
│  ─────────────────────────────────────────────────────────────────────────  │
│                                                                             │
│  正确的做法:                                                               │
│  ───────────                                                                │
│                                                                             │
│  1. 测量 (Measure)                                                        │
│     - 使用 profiling 工具获取真实数据                                       │
│     - 确认热点位置和耗时                                                   │
│                                                                             │
│  2. 分析 (Analyze)                                                         │
│     - 理解瓶颈原因                                                         │
│     - 区分 CPU bound / Memory bound / I/O bound                          │
│                                                                             │
│  3. 优化 (Optimize)                                                        │
│     - 针对具体瓶颈采取行动                                                 │
│     - 每次只改一处                                                         │
│                                                                             │
│  4. 验证 (Verify)                                                         │
│     - 重新测量，确认优化效果                                               │
│     - 确认没有引入回归                                                     │
│                                                                             │
│  循环往复，直到达到性能目标                                                │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 1.2 性能指标

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        关键性能指标 (KPI)                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  吞吐量指标:                                                              │
│  ──────────                                                                │
│  - Packets Per Second (PPS): 包处理速率                                    │
│  - Bits Per Second (BPS): 比特处理速率                                     │
│  - Transactions Per Second (TPS): 事务处理速率                              │
│  - Operations Per Second (OPS): 操作处理速率                              │
│                                                                             │
│  延迟指标:                                                                │
│  ────────                                                                  │
│  - 平均延迟 (Mean Latency): 所有延迟的算术平均                             │
│  - P50/P90/P95/P99 延迟: 百分位数                                          │
│  - 最大延迟 (Max Latency): 观察到的最长延迟                                │
│  - 延迟抖动 (Jitter): 延迟的标准差                                          │
│                                                                             │
│  资源利用率:                                                               │
│  ──────────                                                                │
│  - CPU 利用率: 每个核心的使用率                                             │
│  - Memory Bandwidth: 内存带宽使用                                         │
│  - Cache Miss Rate: L1/L2/L3 未命中率                                      │
│  - Cycles Per Instruction (CPI): 每指令周期数                             │
│                                                                             │
│  效率指标:                                                                │
│  ────────                                                                  │
│  - Instructions Per Packet (IPP): 每包指令数                              │
│  - Cycles Per Packet (CPP): 每包周期数                                     │
│  - Cache Misses Per Packet (CMPP): 每包 Cache Miss 数                     │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. dpdk-procinfo

### 2.1 工具概述

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        dpdk-procinfo 工具                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  dpdk-procinfo 是 DPDK 自带的性能分析工具                                  │
│  ─────────────────────────────────────────────                              │
│                                                                             │
│  功能:                                                                    │
│  - 显示每个 lcore 的统计信息                                               │
│  - 显示每个 port 的统计信息                                                │
│  - 显示内存池使用情况                                                       │
│  - 显示 softnic 统计 (如果启用)                                            │
│  - 支持 stats reset                                                        │
│                                                                             │
│  位置:                                                                    │
│  - $RTE_SDK/build/app/proc_info                                            │
│                                                                             │
│  使用:                                                                    │
│  - dpdk-procinfo --help                                                   │
│  - dpdk-procinfo -l 0-3 -n 4 -- -p 0                                     │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 2.2 基本使用

```bash
# 基本命令
dpdk-procinfo -l 0-7 -n 4 -- -p 0

# 参数说明:
# -l 0-7: lcore 0-7 运行
# -n 4: 4通道内存
# -p 0: 显示 port 0 统计

# 重置统计
dpdk-procinfo -l 0-7 -n 4 -- -p 0 --stats-reset

# 增量统计 (两次采样之间)
# 第一次采集
dpdk-procinfo -l 0-7 -n 4 -- -p 0 > /tmp/stats1.txt
sleep 10
# 第二次采集
dpdk-procinfo -l 0-7 -n 4 -- -p 0 > /tmp/stats2.txt
# 对比差异
```

### 2.3 输出解析

```
================================================================================
Lcore and Port Configuration
================================================================================
Lcore:
  0:   Socket 0, Core 0, 1 thread(s)
  1:   Socket 0, Core 1, 1 thread(s)
  2:   Socket 1, Core 8, 1 thread(s)
  3:   Socket 1, Core 9, 1 thread(s)

Port:
  0:   Intel XL710 (Driver: i40e)
       RX Queues: 4, TX Queues: 4
       Link: 40Gbps, Up

================================================================================
Lcore Statistics
================================================================================
Lcore 0:
  RX-packets: 14,523,456    TX-packets: 14,523,401
  RX-dropped: 0             TX-dropped: 45
  RX-bytes: 8,714,073,600   TX-bytes: 8,714,023,456
  Cycles: 123,456,789,012   Instructions: 246,913,578,024
  CPI: 0.500

Lcore 1:
  RX-packets: 14,523,512    TX-packets: 14,523,489
  RX-dropped: 0             TX-dropped: 23
  ...

================================================================================
Port Statistics
================================================================================
Port 0:
  RX-packets: 58,094,128    RX-missed: 0
  RX-badbytes: 0             RX-errors: 0
  TX-packets: 58,094,064    TX-errors: 0
  RX-bytes: 34,856,476,800  TX-bytes: 34,856,438,400
  TX-bytes: 34,856,438,400  RX-burst: 32    TX-burst: 32
  Average RX burst size: 31.2
  Average TX burst size: 31.5

================================================================================
Queue Statistics
================================================================================
Port 0, Queue 0:
  RX-packets: 14,523,532    RX-desc: 512
  RX-used-desc: 0            RX-avail-desc: 512
  TX-packets: 14,523,501    TX-desc: 512
  TX-used-desc: 8            TX-avail-desc: 504

================================================================================
Memory Statistics
================================================================================
Mbuf Pool: mbuf_pool_socket0
  Count: 16384    In Use: 8192    Free: 8192
  Memzone: socket 0
  Cache Size: 256

Mbuf Pool: mbuf_pool_socket1
  Count: 16384    In Use: 0       Free: 16384
  Memzone: socket 1

================================================================================
```

### 2.4 自定义统计

```c
// DPDK 统计 API

#include <rte_stats.h>
#include <rte_port_stats.h>

// 定义统计计数器
struct {
    uint64_t packets_processed;
    uint64_t bytes_processed;
    uint64_t errors;
    uint64_t latency_sum;
    uint64_t latency_count;
} __rte_cache_aligned stats;

// 初始化 stats
void
init_stats(void)
{
    memset(&stats, 0, sizeof(stats));
}

// 更新统计
static inline void
update_stats(uint64_t packets, uint64_t bytes, uint64_t errors, uint64_t latency)
{
    __atomic_fetch_add(&stats.packets_processed, packets, __ATOMIC_RELAXED);
    __atomic_fetch_add(&stats.bytes_processed, bytes, __ATOMIC_RELAXED);
    __atomic_fetch_add(&stats.errors, errors, __ATOMIC_RELAXED);
    __atomic_fetch_add(&stats.latency_sum, latency, __ATOMIC_RELAXED);
    __atomic_fetch_add(&stats.latency_count, 1, __ATOMIC_RELAXED);
}

// 获取统计
void
get_stats(uint64_t *packets, uint64_t *bytes, uint64_t *errors,
          uint64_t *avg_latency)
{
    *packets = __atomic_load_n(&stats.packets_processed, __ATOMIC_RELAXED);
    *bytes = __atomic_load_n(&stats.bytes_processed, __ATOMIC_RELAXED);
    *errors = __atomic_load_n(&stats.errors, __ATOMIC_RELAXED);

    uint64_t lat_sum = __atomic_load_n(&stats.latency_sum, __ATOMIC_RELAXED);
    uint64_t lat_cnt = __atomic_load_n(&stats.latency_count, __ATOMIC_RELAXED);

    *avg_latency = (lat_cnt > 0) ? (lat_sum / lat_cnt) : 0;
}

// Ethdev 统计 (自动收集)
struct rte_eth_stats eth_stats;

void
print_eth_stats(uint16_t port_id)
{
    rte_eth_stats_get(port_id, &eth_stats);

    printf("Port %d Statistics:\n", port_id);
    printf("  RX: %lu packets, %lu bytes, %lu errors\n",
           eth_stats.ipackets, eth_stats.ibytes, eth_stats.ierrors);
    printf("  TX: %lu packets, %lu bytes, %lu errors\n",
           eth_stats.opackets, eth_stats.obytes, eth_stats.oerrors);
    printf("  RX miss: %lu\n", eth_stats.rx_nombuf);
    printf("  RX burst: avg %.1f\n", eth_stats.ilibufsz);
}

// 重置统计
void
reset_stats(uint16_t port_id)
{
    rte_eth_stats_reset(port_id);
}
```

---

## 3. perf

### 3.1 perf 基础

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        perf 性能分析工具                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  perf 是 Linux 内核自带的性能分析工具                                      │
│  ─────────────────────────────────────────                                  │
│                                                                             │
│  安装:                                                                    │
│  ────                                                                    │
│  apt install linux-tools-common linux-tools-generic                       │
│  或                                                                    │
│  yum install perf                                                         │
│                                                                             │
│  常用命令:                                                                 │
│  ──────────                                                                │
│  perf list                 列出可用事件                                     │
│  perf stat                 统计计数                                         │
│  perf record               记录采样数据                                     │
│  perf report               显示报告                                         │
│  perf top                  实时热点                                         │
│  perf annotate             反汇编注释                                       │
│  perf script               导出采样数据                                     │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 3.2 perf stat 统计

```bash
# 基本统计
perf stat -e cycles,instructions,cache-references,cache-misses ./dpdk_app

# 指定事件
perf stat -e cycles,instructions -e branch-instructions -e branch-misses ./dpdk_app

# 列出所有可用事件
perf list

# 多核统计
perf stat -a -e cycles,instructions --per-core ./dpdk_app

# 输出示例
#  Performance counter stats for './dpdk_app':
#
#         123,456,789,012      cycles                           #    3.00 GHz
#         246,913,578,024      instructions                     #    2.00  insn per cycle
#          23,456,789,012      cache-references                 #   59.23 M/sec
#             123,456,789      cache-misses                     #    0.53% miss rate
#           1,234,567,890      branch-instructions               #    3.14 M/sec
#              12,345,678      branch-misses                    #    1.00% miss rate
#
#           41.234567890 seconds time elapsed
```

### 3.3 perf record/report

```bash
# 记录采样数据
perf record -g -e cycles,instructions ./dpdk_app

# 参数说明:
# -g: 记录调用链 (call graph)
# -e: 采样事件
# -F 99: 每秒99次采样 (默认4000)
# -a: 记录所有 CPU
# -C 0: 只记录 CPU 0

# 记录一段时间后 Ctrl+C 停止
# 生成 perf.data 文件

# 查看报告
perf report

# 查看调用链
perf report -g

# 按 symbol 排序
perf report -g --sort symbol

# 只看特定符号
perf report -s symbol --stdio

# 显示百分比
perf report --percent-limit 1  # 只显示 >1% 的

# 导出文本报告
perf report --stdio > /tmp/perf_report.txt
```

### 3.4 perf top 实时热点

```bash
# 实时显示热点 (类似 top)
perf top

# 参数:
# -e cycles: 采样 cycles
# -K: 隐藏内核符号
# -U: 隐藏用户符号
# -p <pid>: 只看特定进程
# -C <cpu>: 只看特定 CPU

# 示例: 只看用户空间热点
perf top -K -U

# 示例: 只看特定进程
perf top -p 1234
```

### 3.5 perf annotate

```bash
# 详细分析特定函数
perf annotate --symbol=<function_name>

# 示例
perf annotate --symbol=process_packet

# 输出
#  process_packet()    Percent |      Source Code & Disassembly
#  ----------------------------------------------------------------
#      0.00 :           push   %rbp
#      0.00 :           mov    %rsp,%rbp
#      0.00 :           sub    $0x20,%rsp
#      5.23 :           mov    (%rdi),%rax
#     10.45 :           add    $0x1,%rax
#     15.67 :           mov    %rax,(%rdi)
#      3.21 :           cmp    $0x100,%rax
#      2.11 :           jne   .L2
#     63.33 :           callq  0xffffffff81234567 <next_function>

# 查看汇编带源码
perf annotate -d <binary> --symbol=<func> --source
```

---

## 4. 火焰图 (Flame Graph)

### 4.1 火焰图原理

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        火焰图原理                                          │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  火焰图 (Flame Graph) 由 Brendan Gregg 发明                               │
│  ─────────────────────────────────────────────────                          │
│                                                                             │
│  结构:                                                                    │
│  ────                                                                    │
│  - Y 轴: 调用栈深度 (从上到下是调用关系)                                   │
│  - X 轴: 采样比例 (宽度表示该函数占用的 CPU 时间比例)                      │
│  - 每块: 一个函数帧                                                        │
│  - 顶层: 叶子函数 (CPU 热点)                                               │
│  - 底层: 入口函数 (main 等)                                                │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐ │
│  │                                                                    │ │
│  │                     [main]                                         │ │
│  │                     ├──[process_packet]  15%                      │ │
│  │                     │   ├──[parse_header]  8%                      │ │
│  │                     │   ├──[lookup_flow]   5%                      │ │
│  │                     │   └──[update_stats]   2%                      │ │
│  │                     │                                                │ │
│  │                     ├──[rx_burst]         10%                      │ │
│  │                     │   └──[recv_from_nic]  10%                      │ │
│  │                     │                                                │ │
│  │                     └──[tx_burst]          8%                       │ │
│  │                         └──[send_to_nic]   8%                       │ │
│  │                                                                    │ │
│  └─────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
│  解读:                                                                    │
│  ────                                                                    │
│  - 越宽的函数 = 越热 (占用更多 CPU)                                        │
│  - 顶层是 CPU 直接消耗的地方                                               │
│  - 从顶层往下看可以找到调用路径                                            │
│  - 消除宽顶 = 优化关键路径                                                │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 4.2 生成火焰图

```bash
# 1. 安装火焰图工具
git clone https://github.com/brendangregg/FlameGraph.git
export PATH=$PATH:~/FlameGraph

# 2. 收集 perf 数据
perf record -F 99 -a -g -- ./dpdk_app
# 或者
perf record -F 99 -a -g -p <pid> -- sleep 30

# 3. 转换为火焰图数据
perf script > /tmp/perf.unfold

# 4. 处理栈折叠
./stackcollapse-perf.pl /tmp/perf.unfold > /tmp/perf.folded

# 5. 生成火焰图
./flamegraph.pl /tmp/perf.folded > /tmp/perf.svg

# 6. 查看 (浏览器打开)
firefox /tmp/perf.svg

# 如果 perf 记录了内核和用户空间，需要过滤
# 只看用户空间
perf script --no-inline | ./stackcollapse-perf.pl | ./flamegraph.pl > /tmp/user_flame.svg

# 只看内核空间
perf script -k /tmp/vmlinux | ./stackcollapse-perf.pl | ./flamegraph.pl > /tmp/kernel_flame.svg
```

### 4.3 DPDK 应用火焰图

```bash
#!/bin/bash
# dpdk_flamegraph.sh - DPDK 应用火焰图采集脚本

APP=$1
DURATION=${2:-30}
OUTPUT=${3:-/tmp/dpdk}

if [ -z "$APP" ]; then
    echo "Usage: $0 <app> [duration] [output]"
    exit 1
fi

# 获取应用 PID
APP_CMD=$(basename $APP)
PID=$(pgrep -f "$APP_CMD" | head -1)

if [ -z "$PID" ]; then
    echo "Application not running"
    exit 1
fi

echo "Recording flame graph for PID $PID for ${DURATION}s..."

# 记录 perf
perf record -F 99 -a -g -p $PID -- sleep $DURATION &

# 等待一段时间后终止记录
sleep $DURATION
kill -INT %1 2>/dev/null

# 处理数据
perf script > ${OUTPUT}.unfold
./FlameGraph/stackcollapse-perf.pl ${OUTPUT}.unfold > ${OUTPUT}.folded

# 生成火焰图
./FlameGraph/flamegraph.pl ${OUTPUT}.folded > ${OUTPUT}.svg

echo "Flame graph saved to ${OUTPUT}.svg"
```

### 4.4 火焰图解读

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        火焰图解读指南                                       │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  正常火焰图特征:                                                           │
│  ───────────────                                                           │
│  - 平顶 (Flat top): 说明该函数是热点                                        │
│  - 宽顶 (Wide top): 说明多个调用共享该函数                                  │
│  - 左右对称: 调用分布均匀                                                   │
│                                                                             │
│  问题模式:                                                                │
│  ────────                                                                  │
│                                                                             │
│  1. 尖刺 (Spike): 单个调用链特别长                                          │
│     可能原因: 递归、深度调用、锁等待                                        │
│                                                                             │
│  2. 宽底 (Wide base): main 函数下有很多分支                                 │
│     可能原因: 程序逻辑复杂、事件驱动框架                                    │
│                                                                             │
│  3. 断层 (Gap): 某些层缺失                                                  │
│     可能原因: 库函数、动态链接、内核                                        │
│                                                                             │
│  4. 梳状 (Comb): 重复的垂直模式                                            │
│     可能原因: 循环中的函数调用                                              │
│                                                                             │
│  优化方向:                                                                │
│  ────────                                                                  │
│  - 消除宽顶: 优化热点函数                                                  │
│  - 扁平化调用链: 内联减少调用                                              │
│  - 缩短梳状: 循环优化                                                      │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 5. 延迟分析

### 5.1 延迟测量方法

```c
// 精确延迟测量

#include <rte_cycles.h>

// 时间戳计数器 (TSC) - 最高精度
uint64_t
get_cycles(void)
{
    uint32_t low, high;
    asm volatile("rdtsc" : "=a"(low), "=d"(high));
    return ((uint64_t)high << 32) | low;
}

// 延迟测量宏
#define LATENCY_START()   uint64_t _lat_start = rte_rdtsc()
#define LATENCY_END()     (rte_rdtsc() - _lat_start)

// 高精度延迟统计
struct latency_stats {
    uint64_t count;
    uint64_t min;
    uint64_t max;
    uint64_t sum;
    uint64_t bins[32];  // 直方图 bins
};

static inline void
latency_record(struct latency_stats *s, uint64_t cycles)
{
    s->sum += cycles;
    s->count++;
    s->min = (cycles < s->min) ? cycles : s->min;
    s->max = (cycles > s->max) ? cycles : s->max;

    // 直方图 (指数分布)
    int bin = 63 - __builtin_clzll(cycles);
    if (bin < 0) bin = 0;
    if (bin >= 32) bin = 31;
    s->bins[bin]++;
}

// 计算百分位数
uint64_t
latency_percentile(struct latency_stats *s, int percentile)
{
    if (s->count == 0) return 0;

    uint64_t target = s->count * percentile / 100;
    uint64_t cumulative = 0;

    for (int i = 0; i < 32; i++) {
        cumulative += s->bins[i];
        if (cumulative >= target)
            return (1ULL << i);  // bin 的上界
    }

    return s->max;
}

// 打印延迟统计
void
print_latency_stats(const char *name, struct latency_stats *s)
{
    if (s->count == 0) {
        printf("%s: no data\n", name);
        return;
    }

    printf("%s Latency Stats:\n", name);
    printf("  Count:   %lu\n", s->count);
    printf("  Min:     %.2f us\n", s->min * 1e6 / rte_get_timer_hz());
    printf("  Max:     %.2f us\n", s->max * 1e6 / rte_get_timer_hz());
    printf("  Mean:    %.2f us\n", s->sum * 1e6 / (s->count * rte_get_timer_hz()));
    printf("  P50:     %.2f us\n", latency_percentile(s, 50) * 1e6 / rte_get_timer_hz());
    printf("  P90:     %.2f us\n", latency_percentile(s, 90) * 1e6 / rte_get_timer_hz());
    printf("  P95:     %.2f us\n", latency_percentile(s, 95) * 1e6 / rte_get_timer_hz());
    printf("  P99:     %.2f us\n", latency_percentile(s, 99) * 1e6 / rte_get_timer_hz());
}
```

### 5.2 端到端延迟测量

```c
// 端到端延迟测量

struct pkt_ctx {
    uint64_t enqueue_time;
    uint16_t seq;
    void *user_data;
};

// 发送时记录时间戳
void
send_with_timestamp(struct rte_mbuf *m, uint16_t seq)
{
    struct pkt_ctx *ctx = rte_pktmbuf_prepend(m, sizeof(struct pkt_ctx));
    ctx->enqueue_time = rte_rdtsc();
    ctx->seq = seq;

    rte_eth_tx_burst(port_id, queue_id, &m, 1);
}

// 接收时计算延迟
void
recv_with_latency(struct rte_mbuf **mbufs, uint16_t count)
{
    uint64_t now = rte_rdtsc();
    static struct latency_stats rx_latency;

    for (int i = 0; i < count; i++) {
        struct pkt_ctx *ctx = rte_pktmbuf_mtod(mbufs[i], struct pkt_ctx *);

        uint64_t latency = now - ctx->enqueue_time;
        latency_record(&rx_latency, latency);

        // 提取数据
        rte_pktmbuf_adj(mbufs[i], sizeof(struct pkt_ctx));

        // 处理数据包
        process_packet(mbufs[i]);
    }
}

// 抖动 (Jitter) 计算
struct jitter_calc {
    uint64_t last_time;
    int64_t sum_squares;
    uint64_t count;
};

static inline void
jitter_record(struct jitter_calc *j, uint64_t current)
{
    if (j->last_time != 0) {
        int64_t diff = (int64_t)(current - j->last_time);
        j->sum_squares += diff * diff;
        j->count++;
    }
    j->last_time = current;
}

double
jitter_calculate(struct jitter_calc *j)
{
    if (j->count < 2) return 0;
    double mean = sqrt((double)j->sum_squares / j->count);
    return mean;
}
```

### 5.3 DPDK Latency 工具

```bash
# 使用 dpdk-test-latency 测试工具
./build/app/dpdk-test-latency

# testpmd 延迟模式
./build/app/dpdk-testpmd -l 0-3 -n 4 -- --latency  # 启用延迟统计

# procinfo 显示延迟
dpdk-procinfo -l 0-3 -n 4 -- -p 0 --latency-stats
```

---

## 6. perf 高级用法

### 6.1 硬件事件采样

```bash
# CPU 周期 (默认)
perf record -e cycles ./app

# 指令数
perf record -e instructions ./app

# 分支预测
perf record -e branch-instructions ./app
perf record -e branch-misses ./app

# Cache 分析
perf record -e cache-references ./app
perf record -e cache-misses ./app
perf record -e L1-dcache-loads ./app
perf record -e L1-dcache-load-misses ./app

# TLB 分析
perf record -e dTLB-loads ./app
perf record -e dTLB-load-misses ./app

# 内存访问
perf record -e memory-loads ./app
perf record -e memory-stores ./app

# 组合采样
perf record -e cycles,instructions,cache-misses,branch-misses ./app

# 指定 Hardware PMU 事件 (需要 Intel PT 等)
perf list | grep -i hardware
```

### 6.2 软件事件

```bash
# 上下文切换
perf record -e context-switches ./app

# CPU 迁移
perf record -e cpu-migrations ./app

# 页面错误
perf record -e page-faults ./app

# 周期内停顿
perf record -e cpu-clock ./app
perf record -e task-clock ./app

# 队列长度 (需要内核支持)
perf record -e skb:consume_skb ./app  # 网络包队列
```

### 6.3 多线程分析

```bash
# 记录所有 CPU
perf record -a -g ./app

# 按线程分组
perf record -a -g --per-thread ./app

# 按 CPU 分组
perf record -a -g --per-core ./app

# 查看 per-thread 报告
perf report --no-children --sort comm

# 查看线程合并后的热点
perf report --sort symbol,comm
```

### 6.4 KPTI/内核分析

```bash
# 由于 KPTI (内核页表隔离)，用户空间采样需要单独处理
# 现代 perf 可以处理

# 记录
perf record -F 99 -a -g -- ./app

# 内核符号 (需要 vmlinux)
perf report -k /boot/vmlinux-$(uname -r)

# 如果没有 vmlinux，可以只分析用户空间
perf report --no-kernel

# 或者安装 debug symbols
apt install linux-image-$(uname -r)-dbgsym
```

---

## 7. 热点定位实战

### 7.1 典型瓶颈定位流程

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        热点定位流程                                        │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  Step 1: 确定目标                                                         │
│  ───────────                                                                │
│  - 吞吐量是否达标? (目标 PPS)                                             │
│  - 延迟是否满足? (目标 P99)                                                │
│  - 哪个指标最重要?                                                         │
│                                                                             │
│  Step 2: 宏观分析                                                         │
│  ─────────────                                                              │
│  - perf stat 查看整体 CPI、Cache Miss Rate                                 │
│  - 如果 CPI > 2，可能有内存瓶颈                                             │
│  - 如果 Cache Miss 高，定位具体哪个 Cache 层级                             │
│                                                                             │
│  Step 3: 微觀分析                                                         │
│  ─────────────                                                              │
│  - perf record + report 定位热点函数                                       │
│  - perf top 实时观察                                                       │
│  - 火焰图直观展示调用关系                                                  │
│                                                                             │
│  Step 4: 函数级分析                                                       │
│  ──────────────────                                                        │
│  - perf annotate 查看热点函数的汇编                                        │
│  - 确认是计算瓶颈还是内存访问瓶颈                                           │
│  - 可能的优化: 内联、算法优化、缓存优化                                    │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 7.2 常见瓶颈模式

```c
// 模式 1: Cache Miss 热点

void
bad_hash_lookup(uint32_t key)
{
    // 每次访问都可能 cache miss
    for (int i = 0; i < TABLE_SIZE; i++) {
        if (table[i].key == key) {  // 随机访问
            return table[i].value;
        }
    }
}

// 优化: 使用 RCU + 预取
void
good_hash_lookup(uint32_t key)
{
    uint32_t hash = hash_func(key);
    struct entry *e = &table[hash];

    rte_prefetch0(e);  // 预取

    if (e->key == key) {
        return e->value;
    }
}

// 模式 2: 锁竞争

rte_spinlock_t lock = RTE_SPINLOCK_INITIALIZER;

void
contended_update(void)
{
    rte_spinlock_lock(&lock);  // 所有线程竞争
    shared_data++;
    rte_spinlock_unlock(&lock);
}

// 优化: per-lcore 数据 + 批量合并
__thread uint64_t local_counter = 0;

void
per_core_update(void)
{
    local_counter++;  // 无锁

    // 定期合并
    if (local_counter > THRESHOLD) {
        rte_spinlock_lock(&lock);
        shared_data += local_counter;
        rte_spinlock_unlock(&lock);
        local_counter = 0;
    }
}

// 模式 3: 分支预测失败

int
bad_packet_classify(struct rte_mbuf *m)
{
    struct ipv4_hdr *iph = ...;

    if (iph->next_proto_id == IPPROTO_TCP) {  // 80% 是 TCP
        return classify_tcp(m);
    } else if (iph->next_proto_id == IPPROTO_UDP) {
        return classify_udp(m);
    } else if (iph->next_proto_id == IPPROTO_ICMP) {
        return classify_icmp(m);
    }
    return classify_other(m);
}

// 优化: likelihood hint
int
good_packet_classify(struct rte_mbuf *m)
{
    struct ipv4_hdr *iph = ...;

    if (__builtin_expect(iph->next_proto_id == IPPROTO_TCP, 1)) {
        return classify_tcp(m);
    } else if (__builtin_expect(iph->next_proto_id == IPPROTO_UDP, 0)) {
        return classify_udp(m);
    }
    return classify_other(m);
}

// 模式 4: 函数调用开销

double
bad_compute(void)
{
    return sqrt(sin(x) * cos(x) + exp(log(y)));
}

// 优化: 减少函数调用，内联
static inline double
fast_sqrt(double x)
{
    // 手写或编译器内联
}

// 或使用查表
static const double lut[1024] = {...};
```

### 7.3 DPDK 特定优化

```c
// DPDK 热点优化示例

// 问题: 频繁的 rte_pktmbuf_free 调用
void
bad_free(struct rte_mbuf *m)
{
    rte_pktmbuf_free(m);  // 函数调用开销
}

// 优化: 批量释放
void
good_free_bulk(struct rte_mbuf **mbufs, int count)
{
    for (int i = 0; i < count; i++) {
        // 只在必要时调用
        if (mbufs[i] != NULL) {
            rte_pktmbuf_free(mbufs[i]);
        }
    }
}

// 问题: 频繁的 ring enqueue/dequeue
void
bad_ring_op(struct rte_ring *r, void *obj)
{
    rte_ring_enqueue(r, obj);  // 单个操作，锁开销大
}

// 优化: 批量操作
int
good_ring_op_bulk(struct rte_ring *r, void **objs, int count)
{
    return rte_ring_enqueue_bulk(r, objs, count, NULL);
}

// 问题: mbuf 数据复制
void
bad_copy(struct rte_mbuf *m, void *data, size_t len)
{
    void *dst = rte_pktmbuf_mtod(m, void *);
    memcpy(dst, data, len);  // CPU 拷贝
}

// 优化: 直接使用原始指针
void
good_direct_use(struct rte_mbuf *m, void *data, size_t len)
{
    // 假设 data 已经在正确位置
    m->data_off = 0;
    m->pkt_len = len;
    m->data_len = len;
}

// 问题: 每次都查询 flow table
uint32_t
bad_flow_lookup(struct flow_table *ft, struct flow_key *key)
{
    return rte_hash_lookup(ft->hash, key);  // hash 计算 + 查找
}

// 优化: 使用 bloom filter 预检
int
good_flow_lookup(struct bloom_filter *bf, struct flow_table *ft,
                 struct flow_key *key)
{
    if (!bloom_filter_check(bf, key)) {  // 快速否定
        return -1;
    }
    return rte_hash_lookup(ft->hash, key);  // 确认查找
}
```

---

## 8. 性能测试框架

### 8.1 benchmark 框架

```c
// DPDK 性能测试框架

struct benchmark_config {
    const char *name;
    uint32_t iterations;
    uint32_t warmup_iterations;
    uint64_t start_time;
    uint64_t end_time;
};

struct benchmark_result {
    double mean;
    double stddev;
    double min;
    double max;
    double percentile[99];  // P1-P99
};

// 基准测试宏
#define BENCHMARK(name, fn, iterations) \
    do { \
        struct benchmark_config cfg = { #name, iterations, 10 }; \
        struct benchmark_result result; \
        benchmark_run(&cfg, fn, &result); \
        benchmark_print(&cfg, &result); \
    } while (0)

// 运行基准测试
void
benchmark_run(struct benchmark_config *cfg,
               void (*fn)(void *), void *arg,
               struct benchmark_result *result)
{
    uint64_t times[cfg->iterations];
    uint64_t sum = 0, sum2 = 0;

    // 预热
    for (uint32_t i = 0; i < cfg->warmup_iterations; i++) {
        fn(arg);
    }

    // 正式测量
    for (uint32_t i = 0; i < cfg->iterations; i++) {
        uint64_t start = rte_rdtsc();
        fn(arg);
        uint64_t end = rte_rdtsc();

        times[i] = end - start;
    }

    // 统计分析
    result->min = times[0];
    result->max = times[0];

    for (uint32_t i = 0; i < cfg->iterations; i++) {
        sum += times[i];
        sum2 += times[i] * times[i];
        if (times[i] < result->min) result->min = times[i];
        if (times[i] > result->max) result->max = times[i];
    }

    double n = cfg->iterations;
    result->mean = sum / n;
    double variance = (sum2 - sum * sum / n) / n;
    result->stddev = sqrt(variance);

    // 计算百分位数
    qsort(times, cfg->iterations, sizeof(uint64_t), cmp_uint64);

    for (int p = 1; p <= 99; p++) {
        uint32_t idx = (uint32_t)(n * p / 100);
        result->percentile[p - 1] = times[idx];
    }
}

// 打印结果
void
benchmark_print(struct benchmark_config *cfg, struct benchmark_result *result)
{
    double hz = rte_get_timer_hz();

    printf("\n=== Benchmark: %s ===\n", cfg->name);
    printf("Iterations: %u\n", cfg->iterations);
    printf("Mean:       %.2f us\n", result->mean * 1e6 / hz);
    printf("StdDev:     %.2f us\n", result->stddev * 1e6 / hz);
    printf("Min:        %.2f us\n", result->min * 1e6 / hz);
    printf("Max:        %.2f us\n", result->max * 1e6 / hz);
    printf("P50:        %.2f us\n", result->percentile[49] * 1e6 / hz);
    printf("P90:        %.2f us\n", result->percentile[89] * 1e6 / hz);
    printf("P95:        %.2f us\n", result->percentile[94] * 1e6 / hz);
    printf("P99:        %.2f us\n", result->percentile[98] * 1e6 / hz);
}

// 使用示例
static void
test_hash_lookup(void *arg)
{
    static uint32_t keys[1000];
    static int idx = 0;

    uint32_t key = keys[idx++ % 1000];
    rte_hash_lookup(hash_table, &key);
}

void
run_benchmarks(void)
{
    // 初始化
    init_hash_table();

    BENCHMARK("Hash Lookup", test_hash_lookup, 10000);
}
```

### 8.2 DPDK 测试应用

```bash
# 使用 dpdk-testpmd 测试吞吐
./build/app/dpdk-testpmd -l 0-7 -n 4 -- -i \
    --forward-mode=io \
    --rxd 512 --txd 512 \
    --burst 32 \
    --txq 4 --rxq 4

# 测试链路
start
show port stats all
set fwd macswap
clear port stats all

# 使用 dpdk-test-acl 测试 ACL
./build/app/dpdk-test-acl -l 0-3 -n 4 --

# 使用 dpdk-test-eventdev 测试事件框架
./build/app/dpdk-test-eventdev -l 0-7 -n 4 --
```

---

## 9. 小结

本章核心要点：

1. **性能优化方法论**：测量 → 分析 → 优化 → 验证的循环，避免猜测热点。

2. **关键性能指标**：吞吐量 (PPS/BPS)、延迟 (P50/P90/P99)、资源利用率 (CPU/Cache/Memory)、效率 (IPP/CPP)。

3. **dpdk-procinfo**：DPDK 自带工具，显示 lcore/port/queue/mempool 统计，支持增量统计对比。

4. **perf stat**：统计硬件事件 (cycles、instructions、cache-misses)、软件事件 (context-switches)，按 CPU/core 分组。

5. **perf record/report**：采样分析热点函数、调用链，支持指定事件和采样频率。

6. **perf top**：实时显示热点，类似 top 命令。

7. **perf annotate**：查看热点函数的汇编代码，定位具体指令瓶颈。

8. **火焰图**： Brendan Gregg 发明的可视化工具，X 轴是采样比例，Y 轴是调用栈深度，直观展示 CPU 时间分布。

9. **生成火焰图**：`perf record` → `perf script` → `stackcollapse-perf.pl` → `flamegraph.pl`。

10. **延迟测量**：TSC 高精度计时器、延迟统计结构 (min/max/mean/percentile)、直方图、抖动计算。

11. **perf 高级用法**：硬件 PMU 事件 (cache-misses、branch-misses)、软件事件 (context-switches)、多线程分析。

12. **热点定位流程**：宏观分析 (CPI/Cache) → 微观分析 (perf/火焰图) → 函数级分析 (annotate)。

13. **常见瓶颈模式**：Cache Miss (预取优化)、锁竞争 (per-lcore + 批量合并)、分支预测失败 (`__builtin_expect`)、函数调用开销 (内联/查表)。

14. **benchmark 框架**：预热、多次测量、统计分析 (mean/stddev/percentile)。

**下一篇预告**：[[2026-04-09-dpdk-deep-dive-ch30-performance-tuning|第三十章]]将讲解性能调优——Batching、RSS、Flow Director。

---

> [!tip] 参考文献
> - Brendan Gregg, "Systems Performance: Enterprise and the Cloud", 2nd Edition
> - Brendan Gregg, "BPF Performance Tools" (火焰图章节)
> - Intel, "Intel VTune Profiler User Guide"
> - Linux perf wiki, https://perf.wiki.kernel.org/
> - "FlameGraph", https://github.com/brendangregg/FlameGraph
> - Intel, "DPDK Profiling Guide", https://doc.dpdk.org/guides/proguide/profiling.html
> - "perf Examples", https://www.brendangregg.com/perf.html
