---
title: "VPP 深入探讨 ch31：Graph 调优"
date: 2026-04-16 10:41:00
tags: [vpp, graph, node, hot-spot, dispatch, vector-processing, scheduling]
description: "深入解析 VPP Graph 调优：热点检测、dispatch 优化、图重配置、vector 处理调优与调度策略"
---

# VPP 深入探讨 ch31：Graph 调优

> [!abstract] 核心要点
> VPP 的 graph 数据平面是其高性能的核心。本章深入解析热点检测、dispatch 优化、图重配置机制、vector 处理调优与调度策略。

## 1. Graph 架构概述

### 1.1 Graph 数据平面

```
┌─────────────────────────────────────────────────────────────┐
│                    VPP Graph 数据平面                        │
│                                                              │
│   ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌─────┐  │
│   │dpdk-input│───→│ethernet- │───→│ ip4-     │───→│ ... │  │
│   │          │    │ input    │    │ lookup   │    │     │  │
│   └──────────┘    └──────────┘    └──────────┘    └─────┘  │
│        ↓                                       ↑              │
│        └───────────────────────────────────────┘              │
│                                                              │
│   ┌──────────────────────────────────────────────────────┐  │
│   │                    Graph Node Table                    │  │
│   │                                                      │  │
│   │  Node Name        Index   Next Nodes                 │  │
│   │  ─────────────────────────────────────────            │  │
│   │  dpdk-input        0      ethernet-input              │  │
│   │  ethernet-input    1      ip4-input, ip6-input       │  │
│   │  ip4-lookup        2      ip4-rewrite, error-drop    │  │
│   │  ...                                              │  │
│   └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 Node 类型

| 类型 | 描述 | 示例 |
|------|------|------|
| **Input** | 数据包入口点 | dpdk-input, ethernet-input |
| **Processing** | 包处理逻辑 | ip4-lookup, acl-plugin |
| **Output** | 包发送出口 | dpdk-output, interface-output |
| **Feature** | 可选的扩展功能 | ipsec-input, nat44-out |
| **Internal** | 内部辅助节点 | error-drop, interface-tx |

### 1.3 图结构

```c
// VPP graph 数据结构

// Node 定义
typedef struct vlib_node {
    char name[64];                // node 名称
    u32 index;                    // node 索引
    vlib_node_type_t type;        // node 类型
    vlib_node_function_t *function; // 处理函数
    
    // 边（next nodes）
    u16 *next_nodes;             // 指向下一个 node 的索引
    char **next_node_names;      // 下一个 node 的名称
    
    // 统计
    u64 total_packets;           // 处理的总包数
    u64 total_cycles;            // 总 CPU 周期
    u64 total_bytes;             // 总字节数
    
    // 调度
    u16 process_hint;            // 调度提示
    u8 state;                    // 运行状态
} vlib_node_t;

// Edge 定义
typedef struct {
    u32 from_node_index;         // 源 node
    u32 to_node_index;           // 目标 node
    u16 next_index;              // 边索引
} vlib_graph_edge_t;

// Graph 定义
typedef struct {
    vlib_node_t *nodes;          // 所有 node
    vlib_graph_edge_t *edges;    // 所有边
    u32 num_nodes;               // node 数量
    u32 num_edges;               // 边数量
} vlib_graph_t;
```

## 2. Dispatch 机制

### 2.1 Dispatch 流程

```
┌─────────────────────────────────────────────────────────────┐
│                   VPP Dispatch 流程                         │
│                                                              │
│   Worker Loop:                                              │
│   ┌────────────────────────────────────────────────────┐   │
│   │                                                     │   │
│   │   while (1) {                                       │   │
│   │     1. 从 rx 队列获取 batch                        │   │
│   │     2. 调用 node->function(b[0..n])                │   │
│   │     3. 根据返回的 next[] 分发到下一 node           │   │
│   │     4. 循环直到包处理完成                          │   │
│   │     5. 返回步骤 1                                  │   │
│   │   }                                                │   │
│   │                                                     │   │
│   └────────────────────────────────────────────────────┘   │
│                                                              │
│   Vector Processing:                                        │
│   ┌────────────────────────────────────────────────────┐   │
│   │                                                     │   │
│   │   Batch = [pkt0, pkt1, ..., pkt63]                 │   │
│   │                                                     │   │
│   │   Node 处理:                                        │   │
│   │   for i in 0..batch_size:                          │   │
│   │     result[i] = node_fn(buffer[i])                 │   │
│   │                                                     │   │
│   │   不按包处理，而是批量处理，减少函数调用开销        │   │
│   │                                                     │   │
│   └────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 Dispatch 函数实现

```c
// 核心 dispatch 函数

always_inline u32
vlib_dispatch_node (vlib_main_t *vm, vlib_node_runtime_t *node,
                    vlib_next_node_runtime_t *next_runtime,
                    vlib_buffer_t **buffers, u32 n_buffers)
{
    u32 n_left = n_buffers;
    u32 next_index;
    vlib_buffer_t **to_next;
    
    while (n_left > 0) {
        // 确定下一个 node
        next_index = get_next_index(next_runtime, 0);
        
        // 获取下一个 node 的运行时信息
        vlib_node_runtime_t *next_node = 
            vlib_get_node_runtime(vm, next_index);
        
        // 分配输出 buffer
        to_next = vlib_get_next_buffer_buffers(vm, next_node, n_left);
        
        // 调用 node 函数
        u32 n_dispatched = next_node->function(vm, next_node, 
                                                buffers, to_next, n_left);
        
        // 更新统计
        next_node->stats.total_packets += n_dispatched;
        next_node->stats.total_cycles += get_cpu_cycles();
        
        n_left -= n_dispatched;
        buffers += n_dispatched;
    }
    
    return n_buffers;
}
```

### 2.3 Vector Dispatch 优化

```c
// Vector dispatch 优化 - 减少分支预测失败

always_inline u32
dispatch_vector (vlib_main_t *vm, vlib_node_runtime_t *node,
                 vlib_buffer_t **buffers, u32 n_buffers)
{
    // 批量获取 next indices
    u32 next_indices[256];
    
    // 单次调用获取所有 next
    node_get_next_nodes(node, buffers, n_buffers, next_indices);
    
    // 按 next 分组 buffers
    // 减少分支预测失败
    for (u32 i = 0; i < n_buffers; i++) {
        u32 next = next_indices[i];
        // 累计这个 next 的 buffers
        add_to_next_buffers(next, buffers[i]);
    }
    
    // 批量 dispatch 到每个 next
    // 一次调用分发所有相同 next 的 buffers
    for (u32 next = 0; next < num_nexts; next++) {
        u32 n = count_buffers_for_next(next);
        if (n > 0) {
            dispatch_to_node(vm, next, get_buffers(next), n);
        }
    }
    
    return n_buffers;
}
```

### 2.4 Batch 处理大小选择

```c
// Batch 大小与性能关系

typedef struct {
    u32 batch_size;
    u64 throughput;       // Mpps
    u64 cycles_per_packet;
} batch_benchmark_t;

batch_benchmark_t results[] = {
    {1,    5.0,  200},   // 无批量，开销大
    {8,    8.5,  120},
    {16,   10.2, 100},   // 典型值
    {32,   11.5,  95},
    {64,   12.8,  90},   // VPP 默认
    {128,  13.5,  88},
    {256,  14.0,  86},   // 最大收益递减
};

// 建议：
// - 默认使用 64（VPP 默认值）
// - 高吞吐场景可用 128-256
// - 延迟敏感场景用 16-32
```

## 3. 热点检测

### 3.1 识别热点 Node

```bash
# 查看所有 node 的统计
vppctl show node

# 示例输出：
# Node                Count        Avg     Total   Cycles/pkt
# ----------------------------------------------------------------
# dpdk-input          1234567890   64      789234567890  142
# ethernet-input      1234567890   64      789234567890   89
# ip4-lookup          1234567890   64      789234567890  456 ← 热点
# ip4-rewrite         1234567890   64      789234567890  123
# error-drop          12345        1       12345         100

# 按 cycles/pkt 排序
vppctl show node sort-by-cycles

# 查看详细统计
vppctl show node verbose

# 示例输出：
# Node: ip4-lookup
#   Function: ip4_rewrite_node_inline
#   Input: 1234567890 packets
#   Output: 1234567890 packets
#   Drops: 0
#   Cycles: 123456789000
#   Cycles/pkt: 100
```

### 3.2 热点函数识别

```bash
# 使用 perf 定位热点函数
perf top -p $(pidof vpp) -n 20

# 示例输出：
# Overhead  Symbol
#   15.34%   ip4_lookup inline
#   12.56%   fib_table_lookup
#    8.23%   ip4_rewrite_inline
#    7.45%   acl_match

# 使用 perf record 采样
perf record -g -p $(pidof vpp) -- sleep 30
perf report --stdio

# 输出示例：
# - 45.23% ip4_lookup
#    - 30.12% fib_table_lookup
#       - 20.10% hash_lookup
#    - 15.11% other
```

### 3.3 热点的常见原因

```
┌─────────────────────────────────────────────────────────────┐
│                 热点 Node 常见原因                           │
│                                                              │
│  1. 复杂查找（路由、ACL）                                     │
│     - FIB 表大                                               │
│     - ACL 规则多                                             │
│     - 未命中 cache                                           │
│                                                              │
│  2. 锁竞争                                                   │
│     - 共享数据结构的锁                                        │
│     - 非 NUMA-aware 的数据访问                               │
│                                                              │
│  3. Cache miss                                               │
│     - 数据结构大，未能全部放入 L1/L2                          │
│     - 随机访问模式                                           │
│                                                              │
│  4. 指令复杂度                                               │
│     - 分支多，预测失败                                        │
│     - 计算密集                                               │
└─────────────────────────────────────────────────────────────┘
```

### 3.4 热点分析工具

```c
// VPP 内置热点分析

// 在代码中添加统计点
#define HOTSPOT_TRACE(node_name, buffer) \
    do { \
        if (PREDICT_FALSE(vm->trace_enabled)) { \
            record_hotspot(node_name, clib_cpu_time_now()); \
        } \
    } while (0)

// 查看热点分布
vppctl show hotspot

# 示例输出：
# Hotspot Analysis:
# Node           Time(%)   Count     Avg cycles
# ip4-lookup     35.2%     1234567   456
# ip4-rewrite    22.1%     1234567   287
# acl-plugin     18.5%     1234567   240
# error-drop      5.2%     1234567   68
# others         19.0%     ...       ...

// 生成热点报告
vppctl show hotspot report

# 报告格式：
# Top hotspots by time:
# 1. ip4-lookup: 35.2% (建议优化路由查找)
# 2. ip4-rewrite: 22.1% (建议批处理)
# 3. acl-plugin: 18.5% (建议减少 ACL 规则)
```

## 4. 图重配置

### 4.1 图重配置机制

```
┌─────────────────────────────────────────────────────────────┐
│                   Graph 重配置流程                           │
│                                                              │
│   Trigger:                                                   │
│   - 接口 up/down                                             │
│   - 路由变化                                                 │
│   - 策略变化                                                 │
│   - CLI 配置变更                                             │
│                                                              │
│   ┌────────────────────────────────────────────────────┐   │
│   │                   Main Thread                       │   │
│   │                                                     │   │
│   │   1. 标记需要重新配置的图                           │   │
│   │   2. 生成新的图配置                                 │   │
│   │   3. 等待所有 worker 完成当前 batch                 │   │
│   │   4. 原子性切换图指针                               │   │
│   │   5. 释放旧图                                       │   │
│   │                                                     │   │
│   └────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 无锁重配置

```c
// VPP 使用 RCU (Read-Copy-Update) 实现无锁重配置

// 旧图（仍在使用）
vlib_graph_t *old_graph;

// 新图（配置完成）
vlib_graph_t *new_graph;

// 使用 RCU 原语
rcu_read_lock();

// 读取当前图的指针
vlib_graph_t *graph = vlib_get_graph();

rcu_read_unlock();

// 切换时使用原子操作
void
vpp_graph_reconfigure (vlib_graph_t *new_graph)
{
    // 等待所有正在读取的 reader 完成
    rcu_synchronize();
    
    // 原子性切换
    atomic_store(&vlib_global_graph, new_graph);
    
    // 释放旧图
    vlib_graph_free(old_graph);
}
```

### 4.3 重配置锁

```c
// VPP node 图重配置锁

typedef struct {
    u8 is_locked;           // 锁标志
    u32 owner_thread;       // 持有者线程
    u32 waiters;            // 等待者数量
} graph_reconfigure_lock_t;

// 获取重配置锁
always_inline int
vpp_graph_lock (void)
{
    graph_reconfigure_lock_t *lock = &reconfig_lock;
    
    // 使用 atomic compare-and-swap
    u32 prev = __sync_val_compare_and_swap(
        &lock->is_locked, 0, 1);
    
    if (prev == 0) {
        // 获取锁成功
        lock->owner_thread = os_get_thread_index();
        return 0;
    }
    
    // 锁已被持有
    lock->waiters++;
    return -1;
}

// 释放重配置锁
always_inline void
vpp_graph_unlock (void)
{
    graph_reconfigure_lock_t *lock = &reconfig_lock;
    
    lock->is_locked = 0;
    lock->owner_thread = 0;
}
```

### 4.4 重配置优化

```bash
# 减少图重配置的开销

# 批量配置
# 反面：
vppctl set interface state eth0 up
vppctl set interface state eth1 up
vppctl set interface state eth2 up

# 正面：一次配置多个接口
vppctl set interfaces state eth0,eth1,eth2 up

# 延迟配置
# 使用定时批量更新，而不是每次变更立即重配置

# 查看重配置统计
vppctl show graph reconfigure

# 示例输出：
# Graph reconfiguration stats:
#   Total reconfigs: 1234
#   Avg duration: 1.5ms
#   Max duration: 10ms
#   Lock contention: 0.1%
```

## 5. 调度优化

### 5.1 Worker 调度策略

```bash
# 查看当前调度配置
vppctl show threads

# 示例输出：
# Name          Type     CPU  Pin  Polls  Suspends
# vpp_main      active     0    y    1234        0
# vpp_worker_0  active     1    y  123456      100
# vpp_worker_1  active     2    y  123456      150
# vpp_worker_2  active     3    y  123456      200
# vpp_worker_3  active     4    y  123456       50

# Polls: 调度循环次数
# Suspends: 主动让出 CPU 次数（应该很少）

# 配置 worker 数量
vppctl set worker [0-3] enable

# 运行时调整 worker
vppctl set worker 4 disable
```

### 5.2 调度参数

```bash
# startup.conf 中的调度配置
cpu {
    main-core 0
    corelist-workers 1-7
    
    # 调度相关参数
    scheduler-policy round-robin   # SCHED_RR
    scheduler-priority 50          # 0-99，值越大优先级越高
}

# 或者在运行时查看
vppctl show scheduler

# 示例输出：
# Scheduler:
#   Policy: round-robin
#   Priority: 50
#   Max frame size: 1000
#   Workers: 4 active
```

### 5.3 动态调度

```c
// VPP 支持动态调整 worker 数量

static clib_error_t *
set_worker_count (vlib_main_t *vm, u32 count)
{
    if (count > vm->available_workers) {
        return clib_error_create("Not enough workers");
    }
    
    if (count > vm->current_workers) {
        // 增加 worker
        for (u32 i = vm->current_workers; i < count; i++) {
            vlib_worker_thread_create(vm, i);
        }
    } else if (count < vm->current_workers) {
        // 减少 worker（Graceful）
        for (u32 i = vm->current_workers - 1; i >= count; i--) {
            vlib_worker_thread_stop(vm, i);
        }
    }
    
    vm->current_workers = count;
    return 0;
}

// 按负载动态调整
void
adaptive_worker_adjustment (vlib_main_t *vm)
{
    f64 load = get_current_load();
    
    if (load > 0.9 && vm->current_workers < vm->max_workers) {
        // 负载高，增加 worker
        set_worker_count(vm, vm->current_workers + 1);
    } else if (load < 0.3 && vm->current_workers > vm->min_workers) {
        // 负载低，减少 worker（节能）
        set_worker_count(vm, vm->current_workers - 1);
    }
}
```

### 5.4 多图调度

```c
// VPP 支持多个 graph（per-interface）

typedef struct {
    vlib_graph_t *graph;           // 当前运行的图
    u32 interface_count;           // 接口数
    u32 worker_per_interface;      // 每个接口绑定的 worker
} vlib_multi_graph_t;

// 为每个接口创建独立图
void
create_per_interface_graphs (vlib_main_t *vm, u32 num_interfaces)
{
    for (u32 i = 0; i < num_interfaces; i++) {
        vlib_graph_t *g = vlib_graph_create();
        
        // 为这个接口配置专属路径
        configure_interface_graph(g, i);
        
        // 绑定到特定 worker
        bind_graph_to_worker(g, i % vm->current_workers);
        
        multi_graphs[i] = g;
    }
}

// 调度时选择对应接口的图
always_inline vlib_graph_t *
select_graph (vlib_main_t *vm, vlib_buffer_t *b)
{
    u32 sw_if_index = vnet_buffer(b)->sw_if_index[VLIB_RX];
    
    return multi_graphs[sw_if_index % num_interfaces];
}
```

## 6. Vector 处理调优

### 6.1 Vector 大小

```bash
# 配置 vector 大小
# startup.conf:
dpdk {
    # Vector 大小（默认 64）
    uvector-size 64
}

# 或者运行时调整
vppctl set vector-size 128

# 查看 vector 统计
vppctl show vector

# 示例输出：
# Vector stats:
#   Current size: 64
#   Avg fill: 85%
#   Dispatches: 1234567890
#   Avg dispatch: 54.4
```

### 6.2 Vector 与 Batch 关系

```
┌─────────────────────────────────────────────────────────────┐
│           Vector Size vs Batch Size                         │
│                                                              │
│   Vector Size: 每次处理的最大包数                           │
│   Batch Size: 每次 dispatch 的包数                          │
│                                                              │
│   配置组合:                                                  │
│   Vector 64 + Batch 64  → 典型配置，最佳平衡               │
│   Vector 128 + Batch 64 → 高吞吐，低延迟稍差               │
│   Vector 64 + Batch 32  → 低延迟，高吞吐稍差                │
│   Vector 256 + Batch 256 → 极限吞吐，延迟不稳定             │
└─────────────────────────────────────────────────────────────┘
```

### 6.3 Vector 处理优化

```c
// 向量化处理示例 - 批量计算

always_inline void
vector_process_packets (vlib_main_t *vm, vlib_buffer_t **buffers, 
                        u32 n_buffers)
{
    // 批量获取包数据指针
    ip4_header_t *ip_headers[256];
    u32 *dst_ips[256];
    
    for (u32 i = 0; i < n_buffers; i++) {
        ip_headers[i] = vlib_buffer_get_current(buffers[i]);
        dst_ips[i] = &ip_headers[i]->dst_address.as_u32;
    }
    
    // SIMD 批量处理
    // 假设处理函数：ip4_lookup_batch(dst_ips[], results[], n)
    
    ip4_lookup_batch(dst_ips, results, n_buffers);
    
    // 批量分发
    for (u32 i = 0; i < n_buffers; i++) {
        u32 next_node = results[i].next_node;
        vlib_buffer_t *b = buffers[i];
        
        vlib_dispatch_to_node(vm, next_node, &b, 1);
    }
}

// 更好的方式 - 减少分支
always_inline void
optimized_vector_process (vlib_main_t *vm, vlib_buffer_t **buffers,
                          u32 n_buffers, u32 next_node_count)
{
    // 按 next 分组，而不是逐包分发
    u32 buffers_by_next[16][256];
    u32 count_by_next[16] = {0};
    
    // 一次遍历分组
    for (u32 i = 0; i < n_buffers; i++) {
        u32 next = get_next_node(buffers[i]);
        buffers_by_next[next][count_by_next[next]++] = buffers[i];
    }
    
    // 批量分发到每个 next
    for (u32 n = 0; n < next_node_count; n++) {
        if (count_by_next[n] > 0) {
            vlib_dispatch_batch(vm, n, buffers_by_next[n], 
                               count_by_next[n]);
        }
    }
}
```

### 6.4 Prefetch 优化

```c
// Vector 处理中的 prefetch

always_inline void
prefetch_packets (vlib_buffer_t **buffers, u32 n)
{
    // 预取接下来的几个包
    for (u32 i = 0; i < n - 4; i += 4) {
        // 预取 buffer 元数据
        prefetch_L1(buffers[i + 4], offsetof(vlib_buffer_t, flags));
        // 预取包数据到 L2
        prefetch_L2(vlib_buffer_get_current(buffers[i + 4]));
    }
}

always_inline void
process_with_prefetch (vlib_main_t *vm, vlib_buffer_t **buffers,
                       u32 n_buffers)
{
    // 预取
    prefetch_packets(buffers, n_buffers);
    
    // 处理当前 batch
    for (u32 i = 0; i < n_buffers; i++) {
        process_single_packet(buffers[i]);
    }
}

// 深度预取（超前进度）
always_inline void
deep_prefetch (vlib_main_t *vm, vlib_buffer_t **buffers,
               u32 n_buffers, u32 ahead)
{
    for (u32 i = 0; i < n_buffers; i += ahead) {
        if (i + ahead < n_buffers) {
            // 预取 ahead 位置
            prefetch_L2(vlib_buffer_get_current(buffers[i + ahead]));
            prefetch_L2(vnet_buffer(buffers[i + ahead]));
        }
    }
}
```

## 7. 图调优实战

### 7.1 常见调优场景

| 场景 | 优化方法 | 效果 |
|------|----------|------|
| **高吞吐** | 增加 vector size，批处理 | +20% 吞吐 |
| **低延迟** | 减少 vector size，预取 | -30% 延迟 |
| **CPU 利用不均** | 重新分配 worker | 负载均衡 |
| **频繁重配置** | 批量配置，延迟生效 | -50% 重配置 |
| **热点集中** | 优化热点 node，增加 cache | +15% 性能 |

### 7.2 调优脚本

```bash
#!/bin/bash
# tune_graph.sh - 图调优脚本

set -e

echo "=== VPP Graph Tuning ==="

# 1. 查看当前配置
echo "Current graph configuration:"
vppctl show graph 2>/dev/null | head -20

# 2. 查看热点
echo -e "\nHot spots:"
vppctl show node | sort -k5 -rn | head -10

# 3. 调整 vector size（根据场景）
if [ "$1" == "throughput" ]; then
    echo "Optimizing for throughput..."
    vppctl set vector-size 256
elif [ "$1" == "latency" ]; then
    echo "Optimizing for latency..."
    vppctl set vector-size 16
else
    echo "Using default vector-size 64"
    vppctl set vector-size 64
fi

# 4. 调整 worker 数量
echo -e "\nAdjusting workers..."
CURRENT_WORKERS=$(vppctl show threads | grep -c vpp_worker)
echo "Current workers: $CURRENT_WORKERS"

# 如果 CPU 利用率不均，增加 worker
# if [ $CPU_IMBALANCE -gt 20 ]; then
#     vppctl set worker $((CURRENT_WORKERS + 1)) enable
# fi

# 5. 查看调优后效果
echo -e "\nAfter tuning:"
vppctl show node | head -10
```

### 7.3 图配置建议

```bash
# 高性能配置示例
# /etc/vpp/high-performance.conf

# CPU 配置
cpu {
    main-core 0
    corelist-workers 1-15
    scheduler-policy fifo
    scheduler-priority 50
}

# Buffer 配置
dpdk {
    socket-mem 8192,8192
    mbuf-pool-size 1048576
}

# Vector 配置
buffers {
    default data size 2048
    numberof buffers 524288
}

# Graph 配置
graph {
    vector-size 128
    node-sync on
    reconfigure-lock-timeout 1000
}

# 调度配置
scheduling {
    max-frame-duration 1000000  # 1ms
    max-frame-packets 256
}
```

### 7.4 性能监控

```bash
# 实时监控图性能
watch -n 1 'echo "=== Node Stats ===" && vppctl show node | head -20'

# 监控 dispatch 效率
watch -n 1 'echo "=== Dispatch Stats ===" && vppctl show dispatch'

# 监控 vector 使用
watch -n 1 'echo "=== Vector Stats ===" && vppctl show vector'

# 综合监控脚本
#!/bin/bash
while true; do
    clear
    echo "=== VPP Graph Monitor ==="
    date
    echo ""
    echo "Top Nodes by Cycles:"
    vppctl show node | sort -k5 -rn | head -5
    echo ""
    echo "Workers:"
    vppctl show threads | grep worker
    echo ""
    echo "Vector:"
    vppctl show vector | head -5
    sleep 2
done
```

## 8. 图调试

### 8.1 图可视化

```bash
# 生成图 DOT 文件
vppctl show graph dot > /tmp/vpp_graph.dot

# 转换为 PNG
dot -Tpng /tmp/vpp_graph.dot > /tmp/vpp_graph.png

# 查看特定路径
vppctl trace path ip4-input to interface-output

# 示例输出：
# Path: ip4-input → ip4-lookup → ip4-rewrite → interface-output
# 
# Nodes in path:
#   0. ip4-input (count: 123456)
#   1. ip4-lookup (count: 123456)
#   2. ip4-rewrite (count: 123456)
#   3. interface-output (count: 123456)
```

### 8.2 图完整性检查

```bash
# 检查图完整性
vppctl show graph check

# 示例输出：
# Graph integrity check:
#   Nodes: 123
#   Edges: 456
#   Valid: yes
#   Warnings: 0
#   Errors: 0

# 检查孤立节点
vppctl show graph orphans

# 示例输出：
# Orphan nodes (no input):
#   - error-drop (expected, no input needed)
#   - interface-tx (expected, no input needed)

# 检查缺失的 next
vppctl show graph validate

# 示例输出：
# Graph validation:
#   Missing next for node ip4-lookup: 2 occurrences
#   Dead ends: 5
```

### 8.3 图统计

```bash
# 详细图统计
vppctl show graph stats

# 示例输出：
# Graph Statistics:
#   Total nodes: 123
#   Active nodes: 100
#   Total edges: 456
#   Active edges: 400
#   
#   Node type distribution:
#     Input: 5
#     Output: 10
#     Feature: 20
#     Internal: 88
#   
#   Top nodes by dispatch count:
#     1. dpdk-input: 1234567890
#     2. ethernet-input: 1234567890
#     3. ip4-lookup: 1234567890
```

### 8.4 常见图问题

| 问题 | 症状 | 解决 |
|------|------|------|
| **图断裂** | 包在中间消失 | 检查 node next 配置 |
| **循环** | 包无法结束，处理多次 | 检查图结构 |
| **过深** | 延迟高 | 优化路径，减少中间 node |
| **过浅** | 功能缺失 | 添加必要的处理 node |
| **热点** | 某个 node 占比高 | 优化热点 node 或增加 worker |

## 9. 总结

```
┌─────────────────────────────────────────────────────────────┐
│                  Graph 调优总结                             │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐  │
│  │                    核心概念                            │  │
│  │                                                        │  │
│  │  Graph: VPP 的数据包处理图，node 通过 edge 连接          │  │
│  │  Dispatch: 包在 node 之间分发的机制                     │  │
│  │  Vector: 批量处理，减少函数调用开销                     │  │
│  │  重配置: 运行时修改图结构，使用 RCU 无锁切换            │  │
│  └────────────────────────────────────────────────────────┘  │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐  │
│  │                    调优方向                            │  │
│  │                                                        │  │
│  │  热点检测: vppctl show node → 按 cycles/pkt 排序        │  │
│  │  Vector 大小: 吞吐优先 256，延迟优先 16                 │  │
│  │  Worker 数量: 与队列数匹配，本地 NUMA                   │  │
│  │  重配置: 批量配置，减少锁竞争                           │  │
│  └────────────────────────────────────────────────────────┘  │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐  │
│  │                    最佳实践                            │  │
│  │                                                        │  │
│  │  1. 生产环境使用固定 vector size（64-128）               │  │
│  │  2. 定期检查热点，优化占 80% 时间的前 3 个 node          │  │
│  │  3. 避免频繁图重配置，使用批量配置                     │  │
│  │  4. Worker 绑定到本地 NUMA，减少跨 socket 访问          │  │
│  └────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

---

> [!tip] 最佳实践
> 1. 热点检测是调优的第一步，优先优化耗时最多的 node
> 2. Vector size 64 是最佳平衡点，高吞吐可用 128-256
> 3. Graph 重配置使用无锁 RCU，避免长时间锁等待
> 4. Prefetch 在 vector 处理中效果显著，优先处理热点 node

> [!warning] 注意事项
> - 调优时注意测量效果，避免过早优化
> - 图结构变更需要考虑向后兼容性
> - 调试时启用 trace 会显著影响性能
> - 生产环境修改图配置应在维护窗口进行