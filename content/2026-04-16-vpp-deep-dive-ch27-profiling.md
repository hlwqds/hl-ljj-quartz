---
title: "VPP 深入探讨 ch27：性能剖析工具"
date: 2026-04-16 10:37:00
tags: [vpp, profiling, trace, benchmark, perf, stats, telemetry, performance]
description: "深入解析 VPP 性能剖析工具：trace、profile、benchmark、perf 集成与统计遥测"
---

# VPP 深入探讨 ch27：性能剖析工具

> [!abstract] 核心要点
> VPP 提供丰富的性能剖析工具。本章深入解析 trace 机制、profile 工具、benchmark 方法、perf 集成与统计遥测，帮助定位热点与性能瓶颈。

## 1. 性能剖析概述

### 1.1 剖析工具矩阵

```
┌─────────────────────────────────────────────────────────────┐
│                    VPP 性能剖析工具                          │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐  │
│  │                      Trace 系统                         │  │
│  │  - packet tracing (包追踪)                              │  │
│  │  - node trace (节点追踪)                                │  │
│  │  - capture buffer (抓包缓冲)                            │  │
│  └────────────────────────────────────────────────────────┘  │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐  │
│  │                     Profile 系统                        │  │
│  │  - CLI profiling                                       │  │
│  │  - time-based sampling                                 │  │
│  │  - cycle counter profiling                             │  │
│  └────────────────────────────────────────────────────────┘  │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐  │
│  │                     Benchmark 工具                       │  │
│  │  - pktgen (发包器)                                      │  │
│  │  - VPP self-tests                                      │  │
│  │  - loopback tests                                       │  │
│  └────────────────────────────────────────────────────────┘  │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐  │
│  │                     Telemetry                           │  │
│  │  - stats API                                           │  │
│  │  - telemetry CLI                                       │  │
│  │  - prometheus exporter                                 │  │
│  └────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 性能指标层次

| 层次         | 指标                       | 工具来源        |
| ------------ | -------------------------- | --------------- |
| **包级别**   | latency, jitter, drops     | trace + capture |
| **节点级别** | packets/sec, cycles/packet | CLI + stats     |
| **线程级别** | utilization, queue depth   | show threads    |
| **系统级别** | CPU%, cache miss           | perf + top      |

## 2. Trace 系统

### 2.1 Packet Trace

```bash
# 启用 packet trace（全局）
vppctl trace add dpdk-input 1000

# 在特定接口启用
vppctl trace add interface TenGigabitEthernet0/0/0 500

# 查看 trace 结果
vppctl show trace

# 清除 trace buffer
vppctl clear trace

# 保存 trace 到文件
vppctl trace save /tmp/trace.dat

# 限制 trace 缓冲区大小（启动时配置）
# startup.conf:
# api-trace {
#     size 1000000
# }
```

### 2.2 Node Trace

```bash
# 启用 node-level trace（追踪经过的节点）
vppctl trace node add

# 查看节点 trace 统计
vppctl show node trace

# 启用特定节点的详细 trace
vppctl set node trace ip4-lookup detail

# 运行时动态启用/禁用
vppctl node trace enable ip4-lookup
vppctl node trace disable ip4-lookup
```

### 2.3 Trace 内部实现

```c
// src/vpp/trace.c (伪代码)

typedef struct {
    u32    next_node_index;     // 下一个节点索引
    u32    prev_node_index;     // 上一个节点索引
    u64    enter_time;          // 进入节点时间戳
    u64    exit_time;           // 退出节点时间戳
    u32    packet_index;        // 包在 buffer 中的索引
    u32    trace_flags;         // trace 标志
} vlib_trace_node_t;

typedef struct {
    vlib_trace_node_t *nodes;   // 节点 trace 条目
    u32               max_nodes; // 最大节点数
    u32               current;   // 当前索引
    u8                enabled;   // 是否启用
} vlib_trace_main_t;

// 包追踪的核心函数
always_inline void
vlib_trace_packet (vlib_main_t *vm, vlib_node_runtime_t *node,
                   vlib_buffer_t *b, u32 next_node_index)
{
    vlib_trace_main_t *tm = &vm->trace_main;

    if (!tm->enabled)
        return;

    vlib_trace_node_t *t = &tm->nodes[tm->current++ % tm->max_nodes];
    t->prev_node_index = node->node_index;
    t->next_node_index = next_node_index;
    t->enter_time = clib_cpu_time_now();
    t->packet_index = vlib_get_buffer_index(vm, b);
}
```

### 2.4 Capture 功能

```bash
# 使用 vppctl 抓包
vppctl capture interface TenGigabitEthernet0/0/0 rx 100

# 查看 capture 结果
vppctl show capture

# 导出为 pcap
vppctl capture save /tmp/capture.pcap

# 清除 capture buffer
vppctl clear capture
```

### 2.5 Trace 配置参数

```bash
# startup.conf 中的 trace 配置
unix {
    cli-listen /run/vpp/cli.sock
}

api-trace {
    size 1000000          # trace 条目数量
    maxlevel 3            # trace 详细级别
}

# 运行时查看 trace 统计
vppctl show api-trace stats
```

## 3. Profile 系统

### 3.1 CLI Profiling

```bash
# 启用 CLI profiling（采样）
vppctl profile on

# 执行命令后关闭 profiling
vppctl profile off

# 查看 profiling 结果
vppctl show profile

# 示例输出：
# Node           Cycles   Calls   ns/call
# ----------------------------------------
# dpdk-input     142335   100000  1423
# ethernet-input  89345   100000   893
# ip4-lookup      56789   100000   567
# ip4-rewrite     45321   100000   453
```

### 3.2 Time-based Profiling

```bash
# 启动时启用 time-based profiling
vpp -c /etc/vpp/startup.conf --profiling on

# 或者在运行时启用
vppctl set profiling on

# 查看采样结果
vppctl show profiling statistics

# 按节点排序
vppctl show profiling sort-by-cycles

# 按调用次数排序
vppctl show profiling sort-by-calls
```

### 3.3 Cycle Counter Profiling

```c
// 使用 cycle counter 进行精确 profiling
#include <vppinfra/cpu.h>

static u64
get_node_cycles (vlib_main_t *vm, u32 node_index)
{
    u64 start = clib_cpu_time_now();

    // 执行节点
    vlib_node_runtime_t *node =
        vlib_get_node_runtime(vm, node_index);

    u64 end = clib_cpu_time_now();

    return end - start;
}

// 在自定义节点中使用
static uword
my_custom_node_fn (vlib_main_t *vm, vlib_node_runtime_t *node,
                   vlib_buffer_t **b, n_next_nodes)
{
    u64 start_cycles = clib_cpu_time_now();

    // ... 执行逻辑 ...

    u64 end_cycles = clib_cpu_time_now();
    u64 cycles = end_cycles - start_cycles;

    // 更新统计
    vlib_node_stats_t *stats = &node->stats;
    stats->total_cycles += cycles;
    stats->invocations++;

    return next_node;
}
```

### 3.4 Performance Counters

```bash
# 查看 CPU 性能计数器
vppctl show hardware

# 示例输出：
# node0:
#   CPU-0: Intel(R) Xeon(R) Gold 6248 @ 2.5GHz
#   CPU features: aes,sse4_2,avx,avx2,avx512f,avx512dq
#
#   Performance counters:
#   Instructions: 1234567890
#   Cycles:        9876543210
#   Cache-misses:  123456
#   Branch-misses: 7890

# 启用硬件性能计数器
vppctl set hardware enable-pmu

# 查看 per-node 统计
vppctl show node stats

# Node 统计示例：
# Node          Input    Output   Drop    Punt
# ----------------------------------------------
# dpdk-input    100000   100000   0       0
# ethernet-input 99900   99900    100     0
# ip4-lookup    99800   99800    0       0
```

### 3.5 Memory Profiling

```bash
# 启用内存 profiling
vppctl set memory-trace on

# 查看内存使用
vppctl show memory

# 示例输出：
# Memory:
#   Heap size:    1024 MB
#   Used:          512 MB
#   Free:          512 MB
#   Allocations:   10000
#   Frees:         5000

# 查看 buffer 统计
vppctl show buffers

# Buffer 统计示例：
# Buffers:
#   Total:    65536
#   Used:     16384
#   Free:     49152
#   Size:     2048 bytes

# 启用 heap tracking
unix {
    heap-trace-size 100000
}
```

## 4. Benchmark 工具

### 4.1 VPP 集成测试

```bash
# 运行 VPP 单元测试
vpp_test

# 运行特定测试套件
vpp_test --suite=acl
vpp_test --suite=ipsec
vpp_test --suite=bridging

# 运行 benchmark 测试
vpp_bench

# 指定测试参数
vpp_bench --packets 1000000 --size 64 --threads 4

# 性能回归测试
vpp_bench --baseline /tmp/baseline.json --compare
```

### 4.2 pktgen 工具

```bash
# 启动 pktgen（独立的发包工具）
pktgen -c /etc/dpdk/pktgen.conf

# pktgen 配置示例
# /etc/dpdk/pktgen.conf：
# cores=0-3
# ports=2
# burst=64
# rate=100%
# size=64

# pktgen 命令
pktgen> set 0 rate 50           # 端口 0 发包率 50%
pktgen> set 0 size 128          # 包大小 128
pktgen> start 0                 # 开始发包
pktgen> stop 0                  # 停止
pktgen> show 0                   # 显示统计

# 创建发包流
pktgen> range 0 src ip 10.0.0.1 10.0.0.255
pktgen> range 0 dst ip 192.168.1.1 192.168.1.254
pktgen> pattern 0 random
```

### 4.3 Loopback 测试

```bash
# 创建 loopback 接口进行测试
vppctl create loopback interface
vppctl set interface state loop0 up

# 配置 IP
vppctl ip add loop0 10.0.0.1/24

# 创建自发自收流
vppctl set interface unnumbered loop0 use TenGigabitEthernet0/0/0

# 使用 VPP CLI 进行简单测试
vppctl exec "loopback filter"
```

### 4.4 自定义 Benchmark

```c
// 自定义 benchmark 代码
#include <vppinfra/cycle.h>

static_always_inline u64
benchmark_node (vlib_main_t *vm, u32 node_index, u32 n_packets)
{
    vlib_node_runtime_t *node = vlib_get_node_runtime(vm, node_index);

    u64 start = clib_cycles_now();

    // 执行节点 n_packets 次
    for (u32 i = 0; i < n_packets; i++) {
        vlib_buffer_t *b = vlib_get_buffer(vm, i);
        vlib_dispatch_node(vm, node, VLIB_NEXT_SINGLE_NODE, &b, 1);
    }

    u64 end = clib_cycles_now();

    return end - start;
}

// 运行 benchmark
void run_benchmark(vlib_main_t *vm)
{
    u32 node_index = ip4_lookup_node.index;
    u32 n_packets = 1000000;

    // Warm up
    benchmark_node(vm, node_index, 10000);

    // 正式测试
    u64 cycles = benchmark_node(vm, node_index, n_packets);

    fformat(stdout, "Cycles: %lu\n", cycles);
    fformat(stdout, "Cycles/packet: %lu\n", cycles / n_packets);
    fformat(stdout, "Packets/sec: %lu\n",
            (n_packets * CLIB_HZ) / cycles);
}
```

## 5. perf 集成

### 5.1 perf 安装与使用

```bash
# 安装 perf
apt-get install linux-tools-common linux-tools-$(uname -r)

# 查看 VPP 进程
ps aux | grep vpp

# 使用 perf record 采样
perf record -g -p <vpp_pid> -- sleep 60

# 查看采样结果
perf report

# 按 CPU 分析
perf record -g -a -- sleep 60
perf report --stdio

# 分析特定函数
perf record -g -p <vpp_pid> -e cycles -c 1000 -- filter=ip4_lookup
perf report --filter=ip4_lookup
```

### 5.2 perf 采样配置

```bash
# 采样硬件事件
perf record -g -e cycles,instructions,cache-misses,branch-misses -p <pid> -- sleep 30

# 使用火焰图采样
perf record -F 99 -g -p <pid> -- sleep 60
perf script | ./FlameGraph/stackcollapse-perf.pl | ./FlameGraph/flamegraph.pl > flame.svg

# 查看热点函数
perf top -p <pid> -n 20

# 示例输出：
# Overhead  Symbol
#   12.34%   ip4_lookup_process
#    8.56%   ethernet_input
#    7.23%   dpdk_rx
```

### 5.3 perf 与 VPP 集成

```bash
# 启动 VPP 时启用 perf
vpp --perf-stats

# 查看 VPP 暴露的 perf 统计
vppctl show perf-stats

# perf 统计输出示例：
# Node              Cycles/pkt   Instructions/pkt   Cache-miss/pkt
# ------------------------------------------------------------------
# dpdk-input         150          200                 0.5
# ethernet-input     80           120                 0.2
# ip4-lookup         200          350                 1.2
# ip4-rewrite        100          180                 0.3
```

### 5.4 Cache 分析

```bash
# 分析 cache miss
perf stat -e cache-references,cache-misses -p <pid>

# 分析 branch prediction
perf stat -e branch-instructions,branch-misses -p <pid>

# 分析 TLB miss
perf stat -e dTLB-loads,dTLB-misses -p <pid>

# 示例输出：
#  Performance counter stats for 'vpp' process:
#
#     1,234,567    cache-references       # 123.45 M/sec
#        12,345    cache-misses           #   1.00% of all cache refs
#
#     5,678,901    branch-instructions    # 567.89 M/sec
#        56,789    branch-misses          #   1.00% mispred rate
```

## 6. Telemetry 与监控

### 6.1 Telemetry 命令

```bash
# 连接 telemetry socket
vppctl telemetry

# 或者使用 UNIX socket
socat - UNIX-CONNECT:/run/vpp/telemetry.sock

# 基本 telemetry 命令
telemetry> show node
telemetry> show memory
telemetry> show buffers
telemetry> show interface
telemetry> show errors

# 综合统计
telemetry> show runtime

# 示例输出：
# Node                Count        Avg vector    Total vec   Cycles/pkt
# -----------------------------------------------------------------------
# dpdk-input          12345678    64            78923456    142
# ethernet-input      12345678    64            78923456    89
# ip4-lookup          12234567    64            77787654    201
```

### 6.2 Stats API

```bash
# 查看 stats socket
ls -la /run/vpp/stats.sock

# 使用 vpp-api-ctl 查看统计
vpp-api-ctl stats

# 格式化输出
vpp-api-ctl stats --pretty

# 示例输出：
# {
#   "/sys/node/0/lcore/1/counter": {...},
#   "/vpp/interface": {...},
#   "/vpp/node": {...}
# }
```

### 6.3 Prometheus 集成

```bash
# 启用 Prometheus exporter（在 startup.conf 中）
# prometheus {
#     port 9090
#     interface-stats on
#     node-stats on
# }

# 查看 metrics
curl http://localhost:9090/metrics

# 示例 metrics：
# vpp_interface_rx_packets_total{interface="TenGigabitEthernet0/0/0"} 1234567
# vpp_interface_tx_packets_total{interface="TenGigabitEthernet0/0/0"} 2345678
# vpp_node_cycles_total{node="ip4-lookup"} 9876543
```

### 6.4 自定义监控

```c
// 自定义指标收集
#include <vpp/api/stats.h>

static clib_error_t *
my_plugin_get_stats (vlib_main_t *vm, api_main_t *am)
{
    // 遍历所有节点统计
    vlib_node_main_t *nm = &vm->node_main;

    fformat(stdout, "Node Statistics:\n");
    fformat(stdout, "Node              Packets    Bytes      Drops\n");

    vec_foreach(node, nm->nodes)
    {
        if (node->type == VLIB_NODE_TYPE_INTERNAL)
        {
            fformat(stdout, "%-16s %-10lu %-10lu %-10lu\n",
                    node->name,
                    node->total_packets,
                    node->total_bytes,
                    node->total_drops);
        }
    }

    return 0;
}
```

## 7. 热点检测实战

### 7.1 热点分析流程

```
┌─────────────────────────────────────────────────────────────┐
│                    热点检测流程                              │
│                                                              │
│  1. 初步定位                                                │
│     └─ perf top -p <pid> → 发现热点函数                     │
│                                                              │
│  2. 深入分析                                                │
│     └─ vppctl trace → 定位热点节点                          │
│                                                              │
│  3. 细粒度分析                                              │
│     └─ perf record -g → 函数内热点指令                      │
│                                                              │
│  4. 验证                                                      │
│     └─ benchmark → 确认优化效果                             │
└─────────────────────────────────────────────────────────────┘
```

### 7.2 常见热点场景

| 场景         | 热点位置   | 优化方法                  |
| ------------ | ---------- | ------------------------- |
| **路由查找** | ip4_lookup | 启用快速查找，批量查      |
| **ACL 匹配** | acl_plugin | 使用 ACL 索引，减少规则数 |
| **加密**     | ipsec esp  | 使用 crypto engine 加速   |
| **NAT**      | nat44      | 连接表优化，批量操作      |
| **QOS**      | qos标记    | 简化队列层级              |

### 7.3 优化示例

```bash
# 启用节点级别的追踪
vppctl trace add ip4-lookup 10000

# 查看追踪结果
vppctl show trace

# 启用详细统计
vppctl show node stats verbose

# 示例显示热点节点：
# Node            Input    Output   Drop    Cycles/pkt
# --------------------------------------------------------
# ip4-lookup      500000   498000   2000    456  ← 热点
# ip4-rewrite      498000   498000   0       123
```

```c
// 优化热点节点代码
static_always_inline uword
optimized_ip4_lookup (vlib_main_t *vm, vlib_node_runtime_t *node,
                      vlib_buffer_t **b, int n_buffers)
{
    u32 *next = vlib_next_args(vm, node);
    u32 *from = vlib_buffer_args(b);

    // 批量处理 - 减少函数调用开销
    u32 n_left = n_buffers;
    u32 processed = 0;

    while (n_left > 0) {
        // 每次处理一批，减少循环开销
        u32 batch_size = clib_min(n_left, 256);

        // 批量路由查找
        for (u32 i = 0; i < batch_size; i++) {
            // 单个包处理
            vlib_buffer_t *buf = vlib_get_buffer(vm, from[i]);
            ip4_header_t *ip = vlib_buffer_get_current(buf);

            // 快速查找（使用缓存）
            fib_lookup_t lookup = ip4_fib_lookup_fast(ip->dst_address);

            next[i] = lookup.next_node_index;
        }

        // 批量分发
        vlib_dispatch_batch(vm, node, next, batch_size);

        processed += batch_size;
        n_left -= batch_size;
    }

    return processed;
}
```

## 8. 性能基准测试

### 8.1 基准测试配置

```bash
# 测试拓扑
#
#     pktgen ──→ VPP ──→ VPP (loopback)
#              TenGigabitEthernet0/0/0
#              TenGigabitEthernet0/0/1

# 配置 loopback
vppctl create loopback interface
vppctl set interface state loop0 up
vppctl ip add loop0 10.0.0.1/24

# 配置接口
vppctl set interface state TenGigabitEthernet0/0/0 up
vppctl ip route add 192.168.1.0/24 via TenGigabitEthernet0/0/1
```

### 8.2 吞吐测试

```bash
# 在 pktgen 端
pktgen> set 0 dst ip 192.168.1.100
pktgen> set 0 size 64
pktgen> set 0 rate 100
pktgen> start 0

# 在 VPP 端查看统计
vppctl show interface TenGigabitEthernet0/0/0

# 示例输出：
# Interface: TenGigabitEthernet0/0/0
#   Link speed: 10 Gbps
#   RX: 1234567890 bytes  12345678 packets  0 drops
#   TX: 1234567890 bytes  12345678 packets  0 errors
```

### 8.3 延迟测试

```bash
# 使用 VPP 内置延迟测试
vppctl exec "loopback filter delay-test 1000"

# 使用硬件时间戳测量延迟
vppctl set interface timestamp TenGigabitEthernet0/0/0 enable

# 查看延迟统计
vppctl show interface TenGigabitEthernet0/0/0

# 延迟输出示例：
# Interface: TenGigabitEthernet0/0/0
#   Average latency: 5.2 us
#   Min latency: 2.1 us
#   Max latency: 12.8 us
#   P50 latency: 4.8 us
#   P99 latency: 9.2 us
```

## 9. 总结

```
┌─────────────────────────────────────────────────────────────┐
│                    VPP 性能剖析工具总结                        │
│                                                              │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐     │
│  │   Trace      │  │   Profile    │  │   Benchmark   │     │
│  │   包级追踪    │  │   热点分析    │  │   性能测试    │     │
│  ├──────────────┤  ├──────────────┤  ├──────────────┤     │
│  │ trace add    │  │ profile on   │  │ pktgen       │     │
│  │ show trace   │  │ show profile │  │ vpp_bench    │     │
│  │ capture      │  │ perf top     │  │ loopback     │     │
│  └──────────────┘  └──────────────┘  └──────────────┘     │
│                                                              │
│  ┌──────────────┐  ┌──────────────┐                        │
│  │   Telemetry  │  │   perf       │                        │
│  │   监控集成    │  │   CPU分析    │                        │
│  ├──────────────┤  ├──────────────┤                        │
│  │ telemetry    │  │ perf record  │                        │
│  │ show runtime │  │ perf report  │                        │
│  │ prometheus   │  │ flamegraph   │                        │
│  └──────────────┘  └──────────────┘                        │
└─────────────────────────────────────────────────────────────┘
```

---

> [!tip] 最佳实践
>
> 1. 日常监控使用 Telemetry，异常时启用 Trace
> 2. perf 用于深度热点分析，配合火焰图直观展示
> 3. 定期运行 benchmark 建立性能基准，便于回归检测
> 4. 多核测试时，确保 CPU affinity 正确配置

> [!warning] 注意事项
>
> - Trace 会显著影响性能，仅在排查问题时启用
> - perf 采样需要 root 权限
> - 高频率采样可能引入测量误差
