---
title: "VPP 深入探讨：调度器、Vector 处理与图重配置"
date: 2026-04-09 18:00:00
tags: [vpp, vector-packet-processing, scheduler, graph, fd.io, cisco]
description: "深入解析 VPP 的核心机制：main loop 调度、vector batch 处理、node 图动态重配置、plugin 开发与性能优化"
---

# VPP 深入探讨：调度器、Vector 处理与图重配置

> [!abstract] 概述
> 本章在第四十三章基础上，深入探讨 VPP 的核心调度机制、vector packet processing 的实现细节、graph rewrite 动态重配置，以及 plugin 开发的实战指南。

## 1. VPP Main Loop 深度解析

### 1.1 完整的 Main Loop

```c
// src/vpp/main.c (简化版)
int vpp_main_loop(vlib_main_t *vm)
{
    // 1. 初始化
    vlib_node_runtime_t *node = vlib_get_node_runtime(vm, input_node_index);

    while (1) {
        // 2. 禁止中断（中断已在初始化时禁用）
        vlib_inhibit_irqs(vm);

        // 3. 处理 pending 图（上一轮调度遗留的）
        do {
            pending_node_index = vlib_get_next_pending_node(vm);

            if (pending_node_index == ~0) break;

            // 调度该 node
            vlib_node_t *n = vlib_get_node(vm, pending_node_index);
            vlib_node_runtime_t *nr = vlib_get_node_runtime(vm, pending_node_index);

            // 调用 node 函数
            vlib_node_runtime_invoke(vm, nr, 0);
        } while (1);

        // 4. 图遍历（直到没有更多 frame 调度）
        // 这一步是 VPP 的核心 - 图遍历

        // 5. RX burst
        u32 n_rx = vlib_rx_from_device(vm, node, frame);

        if (n_rx == 0) {
            // 无包，休眠或轮询
            vlib_rx_wait(vm, node);
            continue;
        }

        // 6. 批量调度第一个 node
        vlib_main_loop_physically_runtime(phys_cf, node, frame);

        // 7. 图遍历直到完成
        while (vlib_num_pending_nodes(vm) > 0) {
            // 处理所有 pending nodes
        }

        // 8. TX burst
        vlib_tx_burst(vm, node, frame);
    }
}
```

### 1.2 图遍历 (Graph Walk)

VPP 的核心在于**图遍历**：

```c
// 图遍历伪代码
static_always_inline void
vlib_main_loop_physically_runtime(cf_main_t *cf,
                                    vlib_node_runtime_t *node,
                                    vlib_frame_t *f)
{
    u32 node_runtime_index = node - vlib_mains[0]->node_main.node_runtimes;
    u32 node_index = node->node_index;

    // 物理层面调度第一个 node
    dispatch_node(cf, node_runtime_index, VLIB_FRAME_NO_AUGMENTATION, f);

    // 递归遍历整个图
    // 直到没有更多 pending nodes
    while (num_pending > 0) {
        for (int i = 0; i < num_pending; i++) {
            dispatch_node(cf, pending[i], flags, 0);
        }
    }
}

// dispatch_node 的核心
static_always_inline void
dispatch_node(cf_main_t *cf,
              u32 node_runtime_index,
              u32 flags,
              vlib_frame_t *f)
{
    vlib_main_t *vm = &vlib_global_main;
    vlib_node_main_t *nm = &vm->node_main;

    vlib_node_runtime_t *n = &nm->node_runtimes[node_runtime_index];

    // 调用 node 函数
    n->function(vm, n, f);

    // 检查是否有 frame 调度到 next nodes
    // 如果有，将它们加入 pending 列表
    vlib_next_frame_t *nf = n->next_frames;

    for (i = 0; i < n->n_next_nodes; i++) {
        vlib_next_frame_t *next = &nf[i];

        if (next->flags & VLIB_FRAME_PENDING) {
            // 调度到下一个 node
            pending[pending_count++] = next->node_runtime_index;
            next->flags &= ~VLIB_FRAME_PENDING;
        }
    }
}
```

### 1.3 时序图

```
┌────────────────────────────────────────────────────────────────────┐
│                         VPP Main Loop                              │
│                                                                    │
│  ┌──────────────────────────────────────────────────────────────┐ │
│  │ 1. RX Burst (如 32/64/128 个包)                              │ │
│  │    ↓                                                         │ │
│  │    [pkt0, pkt1, pkt2, ..., pkt31] ← Vector (一次处理多个)    │ │
│  └──────────────────────────────────────────────────────────────┘ │
│                             ↓                                      │
│  ┌──────────────────────────────────────────────────────────────┐ │
│  │ 2. 调度到第一个 node (device-input)                          │ │
│  │    ↓ dispatch_node()                                          │ │
│  │    处理完返回 frame，frame 中包含要调度到 next nodes 的包     │ │
│  └──────────────────────────────────────────────────────────────┘ │
│                             ↓                                      │
│  ┌──────────────────────────────────────────────────────────────┐ │
│  │ 3. 图遍历（Graph Walk）                                       │ │
│  │                                                              │ │
│  │    device-input → ip4-input → ip4-lookup → ... → output      │ │
│  │          │             │             │              │       │ │
│  │          ↓             ↓             ↓              │       │ │
│  │    pending=[         pending=[    pending=[        │       │ │
│  │      ip4-input,      ip4-lookup,  output]           │       │ │
│  │      ...]                                            ]       │ │
│  │                                                              │ │
│  │    图遍历保证了包按顺序经过完整路径                          │ │
│  └──────────────────────────────────────────────────────────────┘ │
│                             ↓                                      │
│  ┌──────────────────────────────────────────────────────────────┐ │
│  │ 4. TX Burst                                                  │ │
│  │    一次性发送所有完成的包                                     │ │
│  └──────────────────────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────────────────────┘
```

## 2. Vector Processing 深入

### 2.1 标量 vs 向量处理

```
标量处理（传统方式）：
┌─────────────────────────────────────────────────────────────┐
│ Packet 1: [Parse] → [Lookup] → [Modify] → [Send]           │
│ Packet 2: [Parse] → [Lookup] → [Modify] → [Send]             │
│ Packet 3: [Parse] → [Lookup] → [Modify] → [Send]            │
│                                                              │
│ CPU 执行序列：                                               │
│  [Parse1] [Lookup1] [Modify1] [Send1]                        │
│            [Parse2] [Lookup2] [Modify2] [Send2]  ← 分支预测失败│
│                      [Parse3] [Lookup3] [Modify3] [Send3]   │
│                                  ↑ Cache miss                │
└─────────────────────────────────────────────────────────────┘

向量处理（VPP）：
┌─────────────────────────────────────────────────────────────┐
│ [Pkt1, Pkt2, Pkt3, ..., Pkt31] → Batch Parse               │
│                                   ↓ Batch Lookup             │
│                                   ↓ Batch Modify            │
│                                   ↓ Batch Send              │
│                                                              │
│ CPU 执行序列：                                               │
│  [Parse1-31]  ← 一次循环，缓存友好                          │
│  [Lookup1-31] ← 分支预测成功（31 个包走同一路径）            │
│  [Modify1-31] ← 数据并行                                    │
│  [Send1-31]                                                │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 Vector 处理的缓存优势

```c
// 标量处理：每次访问可能 miss
for (i = 0; i < n_packets; i++) {
    struct buffer *b = get_buffer(packets[i]);

    // 每次迭代都可能 cache miss
    // 因为 flow table entry 可能不在缓存中
    struct flow_entry *f = flow_lookup(b->src_ip, b->dst_ip);

    // 处理
    process(f, b);
}

// 向量处理：批量访问
u32 *indices = vlib_frame_vector_args(frame);
u32 n_packets = frame->n_vectors;

// 预取所有包头
for (i = 0; i < n_packets; i++) {
    prefetch(vlib_get_buffer(vm, indices[i]), PRELOAD_OFFSET);
}

// 批量处理
for (i = 0; i < n_packets; i++) {
    vlib_buffer_t *b = vlib_get_buffer(vm, indices[i]);
    // 命中！
    struct flow_entry *f = flow_lookup(b->src_ip, b->dst_ip);
    process(f, b);
}

// 或者使用 SIMD 批量查找
simd_flow_lookup(indices, n_packets, results);
```

### 2.3 Prefetch 优化

```c
// VPP 使用的 prefetch 策略
static_always_inline void
prefetch_buffer_details(vlib_main_t *vm, u32 bi)
{
    vlib_buffer_t *b = vlib_get_buffer(vm, bi);

    // 预取包数据
    CLIB_PREFETCH(b->data, 64, STORE);

    // 预取元数据（如果跨缓存行）
    if (b->flags & BUFFER_FLAG_METADATA) {
        CLIB_PREFETCH(b->metadata, 64, STORE);
    }
}

// 两层预取：当前包 + 下一个包
for (u32 i = 0; i < n_packets; i++) {
    u32 bi = indices[i];

    // 预取当前包的详细数据
    prefetch_buffer_details(vm, bi);

    // 预取下一个包的元数据（更早阶段）
    if (i + 1 < n_packets) {
        prefetch(vlib_get_buffer(vm, indices[i + 1]), STORE);
    }

    // 处理当前包
    process_packet(vm, bi);
}
```

## 3. Node 图动态重配置

### 3.1 Graph Rewrite 原理

VPP 支持运行时修改 node 图：

```bash
# 默认：eth0 → device-input → ip4-input → ...
vpp# show interface
              Name               Idx    State  MTU (L3/IP4)
          GigabitEthernet0/8/0     1      up      9000/0/0

# 重定向 eth0 流量到我的自定义 node
vpp# set interface input node GigabitEthernet0/8/0 my-custom-node

# 现在的路径：eth0 → my-custom-node → ...
```

### 3.2 接口与 Node 的绑定

```c
// sw_interface 绑定到 node
struct sw_interface {
    u32 sw_if_index;
    u32 node_index;           // 输入 node

    // 输入队列
    struct {
        u32 next_index;       // 下一步的 node
        u32 prev_index;
    } input_next[];
};

// 调度接口输入
static_always_inline u32
vnet_interface_input(vlib_main_t *vm,
                    vlib_node_runtime_t *node,
                    vlib_frame_t *frame,
                    u32 sw_if_index)
{
    // 获取该接口的输入 node
    vnet_sw_interface_t *sw = vnet_get_sw_interface(vm, sw_if_index);

    // 设置 dispatch 的起点
    vlib_frame_no_append(frame);
    vlib_next_frame_main(vm) = sw->input_next[node->thread_index];

    // 返回调度
    return frame->n_vectors;
}
```

### 3.3 批量重配置

```c
// 批量设置多个接口的输入 node
int vnet_set_interface_input_node_multi(struct vlib_main_t *vm,
                                        u32 count,
                                        u32 *sw_if_indices,
                                        u32 node_index)
{
    for (u32 i = 0; i < count; i++) {
        u32 sw_if_index = sw_if_indices[i];

        // 更新绑定
        vnet_sw_interface_t *sw =
            vnet_get_sw_interface(vm, sw_if_index);
        sw->input_node_index = node_index;

        // 广播变化
        unix_dispatch_member(VMOV, sw_if_index, node_index);
    }

    // 同步所有 worker
    vlib_worker_thread_barrier_sync(vm);
    vlib_worker_thread_barrier_release(vm);

    return 0;
}
```

### 3.4 图重配置的原子性

```c
// 图重配置需要 barrier 同步
void vpp_set_interface_input_node(u32 sw_if_index, u32 node_index)
{
    // 1. 同步所有 worker 线程
    vlib_worker_thread_barrier_sync(vm);

    // 2. 修改图（在主线程中）
    vnet_sw_interface_t *sw =
        vnet_get_sw_interface(vm, sw_if_index);
    sw->input_node_index = node_index;

    // 3. 刷新接口的 buffered frames
    vnet_hw_interface_flush_frames(sw_if_index);

    // 4. 释放 barrier
    vlib_worker_thread_barrier_release(vm);
}
```

## 4. Plugin 开发实战

### 4.1 完整 Plugin 结构

```
my-vpp-plugin/
├── CMakeLists.txt
├── api/
│   ├── my_plugin.api              # API 定义文件
│   └── my_plugin.api_dump.c       # API 实现
├── my_plugin.c                    # 主文件 + 消息处理
├── node_foo.c                     # 自定义 node 1
├── node_bar.c                     # 自定义 node 2
├── node_test.c                    # 测试 node
└── test/
    └── test_my_plugin.py          # Python 测试
```

### 4.2 API 定义文件

```bash
# my_plugin.api
definition {
    counter my_stats_counter;
};

define my_custom_msg {
    u32 client_index;
    u32 context;
    u32 flags;
    u8 data[64];
};

define my_custom_msg_reply {
    u32 context;
    i32 retval;
    u32 counter;
};

autoreply define my_custom_event {
    u32 counter;
};
```

### 4.3 Plugin 主文件

```c
// my_plugin.c
#include <vnet/plugin/plugin.h>
#include <vpp/api/message.h>
#include <vpp-api/client/vpe_msg_enum.h>

// 插件注册
VLIB_PLUGIN_REGISTER() = {
    .version = VPP_BUILD_VER,
    .description = "My Custom VPP Plugin",
    .version_hint = "my-plugin 1.0",
};

// 主结构
typedef struct {
    // 统计
    u64 packets_processed;
    u64 bytes_processed;

    // 路由表（示例）
    u32 *fib_table;
    uword *fib_hash;

    // 配置
    u32 flags;
} my_plugin_main_t;

my_plugin_main_t my_plugin_main;

// 消息处理函数
static void
vl_api_my_custom_msg_t_handler(vl_api_my_custom_msg_t *mp)
{
    my_plugin_main_t *pm = &my_plugin_main;

    // 处理消息
    u32 counter = ntohl(mp->counter);

    // 业务逻辑
    handle_custom_msg(mp->data, counter);

    // 回复
    vl_api_my_custom_msg_reply_t *rmp;
    rmp = vl_msg_api_alloc(sizeof(*rmp));
    rmp->_vl_msg_id = ntohs(VL_API_MY_CUSTOM_MSG_REPLY);
    rmp->context = mp->context;
    rmp->retval = 0;
    rp->counter = htonl(pm->packets_processed);

    vl_msg_api_send_msg(rmp, 1);  // 1 = channel id
}

// 统计 dump
static void
vl_api_my_stats_counter_t_handler(vl_api_my_stats_counter_t *mp)
{
    my_plugin_main_t *pm = &my_plugin_main;

    vl_api_my_custom_event_t *ep;
    ep = vl_msg_api_alloc(sizeof(*ep));
    ep->_vl_msg_id = htons(VL_API_MY_STATS_COUNTER);
    ep->counter = htonll(pm->packets_processed);

    vl_msg_api_send_msg(ep, 1);
}
```

### 4.4 自定义 Node

```c
// node_foo.c
#include <vnet/vnet.h>
#include <vlib/vlib.h>

// Node 函数声明
VLIB_REGISTER_NODE(my_foo_node) = {
    .function = my_foo_node_fn,
    .name = "my-foo",
    .short_name = "myfoo",
    .type = VLIB_NODE_TYPE_INTERNAL,

    // 输入边：可以从哪些 node 调度过来
    .input_nodes = {
        // 本例不需要输入 node（作为起点）
    },

    // 输出边
    .next_nodes = {
        [MY_FOO_NEXT_DROP] = "error-drop",
        [MY_FOO_NEXT_OUTPUT] = "interface-output",
    },
};

// 处理函数
static_always_inline u32
my_foo_process_inline(vlib_main_t *vm,
                       vlib_node_runtime_t *node,
                       vlib_frame_t *frame)
{
    u32 *from = vlib_frame_vector_args(frame);
    u32 n_packets = frame->n_vectors;
    u32 n_left = n_packets;

    // 批量处理
    while (n_left >= 4) {
        u32 bi0 = from[0];
        u32 bi1 = from[1];
        u32 bi2 = from[2];
        u32 bi3 = from[3];

        vlib_buffer_t *b0 = vlib_get_buffer(vm, bi0);
        vlib_buffer_t *b1 = vlib_get_buffer(vm, bi1);
        vlib_buffer_t *b2 = vlib_get_buffer(vm, bi2);
        vlib_buffer_t *b3 = vlib_get_buffer(vm, bi3);

        // 处理
        u32 next0 = process_single(vm, b0);
        u32 next1 = process_single(vm, b1);
        u32 next2 = process_single(vm, b2);
        u32 next3 = process_single(vm, b3);

        // 调度到下一 node
        vlib_buffer_advance(b0, next0);
        vlib_buffer_advance(b1, next1);
        vlib_buffer_advance(b2, next2);
        vlib_buffer_advance(b3, next3);

        // 更新统计
        vlib_node_increment_counter(vm, node->node_index,
                                    MY_FOO_ERROR_NONE,
                                    4);

        n_left -= 4;
        from += 4;
    }

    // 处理剩余的包
    while (n_left > 0) {
        u32 bi = from[0];
        vlib_buffer_t *b = vlib_get_buffer(vm, bi);

        u32 next = process_single(vm, b);
        vlib_buffer_advance(b, next);

        vlib_node_increment_counter(vm, node->node_index,
                                    MY_FOO_ERROR_NONE, 1);

        n_left--;
        from++;
    }

    return frame->n_vectors;
}
```

## 5. VPP 与 DPDK 集成

### 5.1 DPDK Poll Mode Driver

```c
// VPP 使用 DPDK PMD 作为接口驱动
// vpp/src/plugins/dpdk/device.c

// DPDK 接口初始化
static int
dpdk_device_init(vnet_main_t *vnm, vnet_hw_interface_t *hw)
{
    struct rte_mempool *mp = dpdk_mempool_get(hw->dev_instance);

    // 创建 rx/tx queues
    for (i = 0; i < nb_rx_queues; i++) {
        int ret = rte_eth_rx_queue_setup(
            hw->dev_instance, i,
            nb_desc,  // 通常 1024
            rte_eth_dev_socket_id(hw->dev_instance),
            &rx_conf,  // RX 配置
            mp);       // mbuf pool
    }

    // 启动设备
    rte_eth_dev_start(hw->dev_instance);

    // 获取 mac 地址
    rte_eth_macaddr_get(hw->dev_instance,
                        (struct ether_addr *)hw->hw_address);
}

// DPDK RX burst
static_always_inline u32
dpdk_rx(vlib_main_t *vm, vlib_node_runtime_t *node,
         u32 queue_id)
{
    u16 nb_rx = rte_eth_rx_burst(port_id, queue_id,
                                  pkts, MAX_PKT_BURST);

    // 转换为 VPP buffer
    for (i = 0; i < nb_rx; i++) {
        bi = dpdk_pktmbuf_to_buffer(pkts[i], bpool);
        from[i] = bi;
    }

    // 返回 frame
    vlib_put_next_frame(vm, node, next_index, nb_rx);
}
```

### 5.2 Buffer 管理

```c
// VPP Buffer vs DPDK mbuf
// VPP 在 DPDK mbuf 基础上添加了自己的头

// +---------------------------------------------------+
// | DPDK mbuf (struct rte_mbuf)                      |
// |   - 包数据指针                                     |
// |   - 长度                                          |
// |   - metdata (mbuf 私有数据)                        |
// +---------------------------------------------------+
// | VPP buffer (struct vlib_buffer_t)  ← 嵌入在 mbuf  |
// |   - current_data (解析偏移)                        |
// |   - flags                                         |
// |   - 包头（inline，避免指针 chasing）               |
// +---------------------------------------------------+
// | 包数据                                            |
// |   - L2 Header (ethernet)                         |
// |   - L3 Header (ip)                               |
// |   - L4 Header (tcp/udp)                         |
// |   - Payload...                                   |
// +---------------------------------------------------+

// 从 DPDK mbuf 获取 VPP buffer
static inline vlib_buffer_t *
dpdk_pktmbuf_to_buffer(struct rte_mbuf *pkt, vlib_buffer_pool_t *pool)
{
    vlib_buffer_t *b = (vlib_buffer_t *)pkt->buf_addr;

    // 初始化 VPP buffer
    b->flags = 0;
    b->current_data = 0;
    b->total_length_not_including_first_buffer = 0;
    b->original_sw_if_index = VLNET_BUFFER_L2_NO_REUSE;

    // 设置包数据指针
    b->data = rte_pktmbuf_mtod(pkt, u8 *);
    b->data_len = pkt->data_len;

    return b;
}
```

### 5.3 零拷贝优化

```c
// VPP 支持 TX buffer 复用（零拷贝）
static_always_inline void
dpdk_eth_output_copy_template(vlib_main_t *vm,
                               vlib_buffer_t *b,
                               u32 tx_queue_id)
{
    // 如果 buffer 可复用，直接使用 template
    if (b->flags & BUFFER_L2_NO_REUSE) {
        // 需要复制
        struct rte_mbuf *pkt = rte_pktmbuf_copy(
            orig_mbuf, mbuf_pool, 0, (u16)-1);
        rte_eth_tx_burst(port, tx_queue_id, &pkt, 1);
    } else {
        // 直接发送（零拷贝）
        // template buffer 被标记，TX 驱动会处理
        rte_eth_tx_burst(port, tx_queue_id,
                         (struct rte_mbuf **)&b, 1);
    }
}
```

## 6. 性能调优

### 6.1 Buffer 调优

```bash
# 调整 buffer 数量和大小
# /etc/vpp/startup.conf
buffers {
    # 每个接口的 buffer 数量
    default data-size 2048

    # 全局 buffer 池大小
    default heap size 1G

    # 每个接口的 buffer 缓存
    per-node cache size 512
}

# CLI 调整
vpp# set buffers size 4096
vpp# set buffers preallocated 16384
```

### 6.2 线程与亲和

```bash
# 查看线程
vpp# show thread
Thread 0 (main): state=running, cpu=[main]
Thread 1 (workers 0): state=waiting, node=interface-tx
Thread 2 (workers 1): state=running

# 设置 worker 数量
vpp# set workers 0 1-3

# 设置 CPU 亲和
vpp# set thread [worker 0] cpu 4
vpp# set thread [worker 1] cpu 6

# 禁用超线程
vpp# set threading mode primary 4
```

### 6.3 内存调优

```bash
# hugepage 配置
# /etc/vpp/startup.conf
unix {
    # hugepage 路径
    hugepath /dev/hugepages

    # 启动前预分配
    startupmlock
}

dpdk {
    # 内存配置
    socketmem 2048,2048  # 每个 socket 2GB

    # uio 驱动
    uio-driver uio_pci_generic
}
```

### 6.4 图跟踪调试

```bash
# 启用图跟踪
vpp# trace add device-input 100

# 查看 trace
vpp# show trace

# 跟踪特定 node
vpp# trace add ip4-input 50

# 清除 trace
vpp# clear trace

# 调试帧
vpp# show frame [node-name]
```

## 7. 常见问题与调试

### 7.1 包丢失分析

```bash
# 检查接口统计
vpp# show interface GigabitEthernet0/8/0

# 检查 errors
vpp# show errors

# 检查 node 统计
vpp# show node
vpp# show node [node-name] statistics

# 检查 drop 原因
vpp# show buffers
vpp# show hardware
```

### 7.2 内存泄漏检测

```c
// VPP 内存跟踪
vpp# show memory
vpp# show memory-locals

// API 内存
vpp# api memory

// 插件内存
vpp# api plugins
```

### 7.3 性能剖析

```bash
# 时间剖析
vpp# profile on
# 运行测试
vpp# profile off
vpp# show profile

# VPP trace
vpp# trace add dpdk-input 1000
vpp# show trace

# Time 查看
vpp# show time
```

## 8. 总结

VPP 的核心设计哲学：

1. **Vector Processing**：批量处理，利用缓存和分支预测
2. **Graph Scheduling**：灵活的 node 图，动态可重配置
3. **Plugin 架构**：可插拔，与 DPDK 深度集成
4. **零拷贝**：TX buffer 复用，最小化复制

关键性能点：

| 优化项       | 方法                    | 收益       |
| ------------ | ----------------------- | ---------- |
| **缓存**     | Vector batch + prefetch | 减少 miss  |
| **分支预测** | Batch 同路径处理        | 减少 stall |
| **内存复制** | Buffer reuse            | 零拷贝     |
| **锁竞争**   | Per-thread 图遍历       | 无锁       |

---

## 参考资源

- [FD.io VPP Wiki](https://wiki.fd.io/view/VPP)
- [VPP 代码仓库](https://github.com/FDio/vpp)
- [VPP 开发文档](https://docs.fd.io/vpp/)
- [VPP Plugin 教程](https://wiki.fd.io/view/VPP/How_To_Write_A_VPP_Plugin)
