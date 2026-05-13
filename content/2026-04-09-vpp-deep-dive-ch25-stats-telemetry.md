---
title: "VPP 深入探讨 ch25：统计与 Telemetry"
date: 2026-04-10 06:30:00
tags: [vpp, stats, telemetry, counter, histogram, segment, memory, stats-api]
description: "深入解析 VPP 统计与 Telemetry：Counter、Histogram、Stats Segment、Telemetry 命令与 API"
---

# VPP 深入探讨 ch25：统计与 Telemetry

> [!abstract] 核心要点
> VPP 提供完整的统计和遥测系统。本章深入解析 Counter、Histogram、Stats Segment、Telemetry 命令与 API。

## 1. 统计系统概述

### 1.1 Stats 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    VPP Stats 架构                          │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              Stats Segment (Shared Memory)            │  │
│  │                                                       │  │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐            │  │
│  │  │ Counters │  │ Histos  │  │ Scalars  │            │  │
│  │  └─────────┘  └─────────┘  └─────────┘            │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↑                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              VPP Main Process                          │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↑                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              Clients (vppctl, API, gRPC)              │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 Stats Socket

```bash
# Stats socket
ls -la /run/vpp/stats.sock

# 示例：
# srw-rw-- 1 root root /run/vpp/stats.sock

# Telemetry socket
ls -la /run/vpp/telemetry.sock
```

## 2. Counter

### 2.1 Counter 类型

```c
// vpp/stats.h

// 简单计数器
typedef struct {
    atomic_u64_t cl;    // 低 32 位
    atomic_u64_t ch;    // 高 32 位
} vl_counter_t;

// 组合计数器
typedef struct {
    vl_counter_t packets;
    vl_counter_t bytes;
} vl_simple_counter_t;

// 64 位计数器
typedef struct {
    atomic_u64_t value;
} vl_64_counter_t;
```

### 2.2 Counter 声明

```c
// 声明计数器
#define MY_N_COUNTERS 16

// 在 main 结构中
typedef struct {
    // 简单计数器
    vl_simple_counter_t interface_counters[MY_N_COUNTERS];

    // 64 位计数器
    vl_64_counter_t my_counter;
} my_main_t;

// 初始化计数器
static void
my_init_counters(my_main_t *pm)
{
    for (int i = 0; i < MY_N_COUNTERS; i++) {
        pm->interface_counters[i].packets.cl = 0;
        pm->interface_counters[i].packets.ch = 0;
        pm->interface_counters[i].bytes.cl = 0;
        pm->interface_counters[i].bytes.ch = 0;
    }
}
```

### 2.3 Counter 操作

```c
// 增加计数器
vl_simple_counter_t *c = &pm->interface_counters[if_index];

// 增加 packet 计数
vl_counter_add(&c->packets, 1);

// 增加字节计数
vl_counter_add(&c->bytes, buffer_length);

// 增加多个
vl_simple_counter_add(c, 1, buffer_length);

// 原子增加 64 位
vm->my_counter.value = vl_64_counter_add(vm->my_counter.value, delta);
```

## 3. Histogram

### 3.1 Histogram 用途

```
Histogram 用于延迟/大小分布：

┌─────────────────────────────────────────────────────────────┐
│                    Histogram 示例                          │
│                                                              │
│  Bucket 0: 0-100ns    ████████████████████ 10000           │
│  Bucket 1: 100-200ns  ████████████ 5000                   │
│  Bucket 2: 200-400ns  ████ 2000                            │
│  Bucket 3: 400-800ns  ██ 1000                             │
│  Bucket 4: 800ns+     █ 500                                │
│                                                              │
│  显示：                                                     │
│  - 平均延迟                                                │
│  - 百分位数 (p50, p95, p99)                               │
│  - 分布形状                                                │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 Histogram 声明

```c
// Histogram 宏
#define VLIB_HISTOGRAM_BUCKETS 32

// Histogram 结构
typedef struct {
    u64 buckets[VLIB_HISTOGRAM_BUCKETS];
    u64 min;
    u64 max;
    u64 total;
    u64 n;
} vlib_histogram_t;

// 在 main 中
typedef struct {
    vlib_histogram_t latency_hist;
    vlib_histogram_t packet_size_hist;
} my_main_t;
```

### 3.3 Histogram 操作

```c
// 记录值
void
vlib_histogram_add(vlib_histogram_t *h, u64 value)
{
    // 找到合适的 bucket
    u32 bucket = clz(value) - 1;

    if (bucket >= VLIB_HISTOGRAM_BUCKETS)
        bucket = VLIB_HISTOGRAM_BUCKETS - 1;

    // 更新 bucket
    __sync_fetch_and_add(&h->buckets[bucket], 1);

    // 更新统计
    u64 old_min = __sync_fetch_and_min(&h->min, value);
    u64 old_max = __sync_fetch_and_max(&h->max, value);
    __sync_fetch_and_add(&h->total, value);
    __sync_fetch_and_add(&h->n, 1);
}

// 记录延迟
void
my_record_latency(my_main_t *pm, u64 latency_ns)
{
    vlib_histogram_add(&pm->latency_hist, latency_ns);
}
```

## 4. Stats Segment

### 4.1 Stats Segment

```c
// Stats segment 是共享内存
// 默认大小：64MB
// 位置：/dev/hugepages/vpp.stats

// 访问 stats segment
#include <vpp/stats/stats.h>

// 获取 stats segment
vpp_stats_main_t *sm = vpp_stats_get_main();

// 访问统计
vlib_simple_counter_main_t *cm = &interface_main.rx_counters;
u64 packets = cm->counters[thread_index][counter_index];
```

### 4.2 注册统计

```c
// 在节点中
VLIB_REGISTER_NODE(my_node) = {
    // ...
};

// 在节点中收集统计
static uword
my_node_fn(vlib_main_t *vm,
           vlib_node_runtime_t *node,
           vlib_frame_t *frame)
{
    // 收集到节点统计
    node->counters[node->n_packets_treated]++;
    node->counters[node->n_packets_dropped]++;

    return frame->n_vectors;
}
```

## 5. Telemetry

### 5.1 Telemetry 命令

```bash
# Telemetry socket
vppctl -s /run/vpp/telemetry.sock

# 或者通过 API
vpp# telemetry

# 基本命令
vpp# telemetry show

# 示例输出：
# Node thread-0 vector-rate 0.0
# Node ip4-lookup vector-rate 100.0
# Node ethernet-input vector-rate 100.0
```

### 5.2 Telemetry 输出

```bash
# 查看接口统计
vpp# show interface
GigabitEthernet0/8/0 (up)
  RX: packets 1000000 bytes 64000000
     errors 0 drops 0
  TX: packets 1000000 bytes 64000000
     errors 0 drops 0

# 查看内存
vpp# show memory
Total: 2048 MB
Used: 1024 MB (50%)
Hugepages: 1024 MB
```

### 5.3 Telemetry API

```python
# Python Telemetry
from vpp_papi import VPP

vpp = VPP("/run/vpp/telemetry.sock")

# 获取统计
stats = vpp.telemetry.get_stats()

# 获取节点信息
nodes = stats['node']
for node in nodes:
    print(f"{node['name']}: vectors {node['vectors']}")

# 获取内存
memory = stats['memory']
print(f"Total: {memory['total']} MB")
```

## 6. Stats API

### 6.1 C Stats API

```c
// 获取 stats segment
#include <vpp/stats.h>

// 连接到 stats segment
int
vpp_stats_connect(vlib_main_t *vm,
                  const char *socket_name,
                  int socket_priority)
{
    // 打开 socket
    int fd = open(socket_name, O_RDWR);

    // 映射到内存
    void *sm = mmap(NULL, stats_size,
                    PROT_READ | PROT_WRITE,
                    MAP_SHARED,
                    fd, 0);

    return 0;
}

// 读取计数器
u64
my_get_rx_packets(vlib_main_t *vm, u32 if_index)
{
    vlib_interface_main_t *im = &vnet_interface_main;
    return im->rx_packets[if_index];
}
```

### 6.2 gRPC Stats

```protobuf
// stats.proto
syntax = "proto3";

service Stats {
    // 获取统计
    rpc Dump (StatsRequest) returns (StatsResponse);

    // 流式统计
    rpc Stream (StatsRequest) returns (stream StatsResponse);
}

message StatsRequest {
    // 可选过滤器
    string pattern = 1;
}

message StatsResponse {
    repeated Counter counters = 1;
    repeated Histogram histograms = 2;
}
```

## 7. 完整示例

### 7.1 计数器收集

```c
// my_stats.c

// 定义计数器
#define MY_N_IFACES 16

// Main 结构
typedef struct {
    // RX 计数器
    vl_simple_counter_t rx_counters[MY_N_IFACES];
    // TX 计数器
    vl_simple_counter_t tx_counters[MY_N_IFACES];
    // 64 位计数器
    vl_64_counter_t total_bytes;
    // 延迟直方图
    vlib_histogram_t latency_hist;
} my_stats_main_t;

my_stats_main_t my_stats_main;

// 初始化
static void
my_stats_init(void)
{
    my_stats_main_t *sm = &my_stats_main;

    // 初始化计数器
    for (int i = 0; i < MY_N_IFACES; i++) {
        sm->rx_counters[i].packets.cl = 0;
        sm->rx_counters[i].bytes.cl = 0;
    }

    // 初始化直方图
    sm->latency_hist.min = ~0;
    sm->latency_hist.max = 0;
    sm->latency_hist.total = 0;
    sm->latency_hist.n = 0;
}

// 记录 RX
void
my_record_rx(u32 if_index, u32 len)
{
    my_stats_main_t *sm = &my_stats_main;
    vl_simple_counter_add(&sm->rx_counters[if_index], 1, len);
}

// 记录延迟
void
my_record_latency(u64 latency)
{
    my_stats_main_t *sm = &my_stats_main;
    vlib_histogram_add(&sm->latency_hist, latency);
}
```

### 7.2 CLI 显示统计

```c
// CLI 命令显示统计
VLIB_CLI_COMMAND(my_show_stats_command, static) = {
    .path = "show my stats",
    .function = my_show_stats_fn,
};

static clib_error_t *
my_show_stats_fn(vlib_main_t *vm,
                 vlib_cli_command_t *cmd,
                 unformat_input_t *input)
{
    my_stats_main_t *sm = &my_stats_main;

    vlib_cli_output(vm, "My Plugin Statistics:");
    vlib_cli_output(vm, "====================");

    // 显示直方图
    vlib_cli_output(vm, "\nLatency Histogram:");
    vlib_histogram_print(vm, &sm->latency_hist);

    return NULL;
}

// 打印直方图
static void
vlib_histogram_print(vlib_main_t *vm, vlib_histogram_t *h)
{
    u64 total = 0;
    for (int i = 0; i < VLIB_HISTOGRAM_BUCKETS; i++) {
        total += h->buckets[i];
    }

    vlib_cli_output(vm, "Total samples: %lld", total);
    vlib_cli_output(vm, "Min: %lld, Max: %lld, Avg: %lld",
                   h->min, h->max,
                   total > 0 ? h->total / total : 0);

    // 显示 bucket
    for (int i = 0; i < VLIB_HISTOGRAM_BUCKETS; i++) {
        if (h->buckets[i] > 0) {
            vlib_cli_output(vm, "  Bucket %d: %lld",
                          i, h->buckets[i]);
        }
    }
}
```

## 8. 总结

Stats 架构：

```
┌─────────────────────────────────────────────────────────────┐
│                    Stats 数据流                            │
│                                                              │
│  Node 处理包                                                │
│       ↓                                                      │
│  Counter += n                                               │
│       ↓                                                      │
│  Stats Segment (共享内存)                                     │
│       ↓                                                      │
│  Client 读取 (vppctl/API/gRPC)                              │
└─────────────────────────────────────────────────────────────┘
```

Counter 类型：

| 类型                 | 用途          | 特点     |
| -------------------- | ------------- | -------- |
| **Simple Counter**   | 32+32 位      | 避免溢出 |
| **64 Counter**       | 64 位         | 单值     |
| **Combined Counter** | packet + byte | 双计数   |

Telemetry 用途：

```
- 实时监控
- 调试
- 性能分析
- 告警
```

---

## 参考资源

- [VPP Stats](https://wiki.fd.io/view/VPP/Stats_and_Telemetry)
- [VPP Telemetry](https://wiki.fd.io/view/VPP/Telemetry)
