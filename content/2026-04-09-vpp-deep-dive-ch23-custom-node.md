---
title: "VPP 深入探讨 ch23：自定义 Node 开发"
date: 2026-04-10 05:30:00
tags: [vpp, node, vlib-node, packet-processing, graph, dispatch, custom]
description: "深入解析 VPP 自定义 Node：Node 类型、注册宏、dispatch 函数、next node 管理与性能优化"
---

# VPP 深入探讨 ch23：自定义 Node 开发

> [!abstract] 核心要点
> Node 是 VPP 数据包处理的基本单元。本章深入解析 Node 注册、类型、dispatch 函数、next node 管理和性能优化。

## 1. Node 概述

### 1.1 Node 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    VPP Graph Node                          │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │                    ip4-input                          │  │
│  │                                                       │  │
│  │  ┌──────────────────────────────────────────────┐   │  │
│  │  │             dispatch_function()                 │   │  │
│  │  │                                               │   │  │
│  │  │  for (each packet) {                         │   │  │
│  │  │      process_packet();                        │   │  │
│  │  │      determine_next_node();                   │   │  │
│  │  │  }                                            │   │  │
│  │  └──────────────────────────────────────────────┘   │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│              ┌──────────────────────────┐                   │
│              ↓                          ↓                   │
│        ┌──────────┐              ┌──────────┐              │
│        │ ip4-lookup│              │ ip4-local│              │
│        └──────────┘              └──────────┘              │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 Node 类型

```c
// vlib_node_type_t
typedef enum vlib_node_type_t {
    // 内部处理节点
    VLIB_NODE_TYPE_INTERNAL = 0,

    // 输入节点（从 NIC 接收）
    VLIB_NODE_TYPE_INPUT = 1,

    // 处理节点（在两个输入节点之间）
    VLIB_NODE_TYPE_PROCESS = 2,

    // 协处理节点（异步操作）
    VLIB_NODE_TYPE_PRE_INPUT = 3,
} vlib_node_type_t;
```

## 2. Node 注册

### 2.1 注册宏

```c
// my_node.c

// 节点声明
VLIB_REGISTER_NODE(my_custom_node) = {
    // 节点名称（必须唯一）
    .name = "my-custom-node",

    // 短名称（CLI 显示用）
    .short_name = "my",

    // 节点类型
    .type = VLIB_NODE_TYPE_INTERNAL,

    // 节点函数
    .function = my_custom_node_fn,

    // 错误定义
    .n_errors = MY_N_ERROR,
    .error_strings = my_error_strings,

    // 下一个节点
    .n_next_nodes = MY_N_NEXT,
    .next_nodes = {
        [MY_NEXT_OUTPUT] = "interface-output",
        [MY_NEXT_DROP] = "error-drop",
        [MY_NEXT_NEXT1] = "another-node",
    },

    // 运行时数据（可选）
    .runtime_data_bytes = sizeof(my_runtime_t),

    // 标志
    .flags = VLIB_NODE_FLAG_IS_DROP,
};
```

### 2.2 节点函数

```c
// 节点函数签名
uword
my_custom_node_fn(vlib_main_t *vm,
                  vlib_node_runtime_t *node,
                  vlib_frame_t *frame)
{
    // 获取输入 buffer 索引
    u32 *from = vlib_frame_vector_args(frame);
    u32 n_packets = frame->n_vectors;

    // 处理每个包
    for (u32 i = 0; i < n_packets; i++) {
        u32 bi = from[i];
        vlib_buffer_t *b = vlib_get_buffer(vm, bi);

        // 处理包
        u32 next_node = my_process(b);

        // 发送
        vlib_put_next_frame(vm, node, next_node, 1);
    }

    return n_packets;
}
```

## 3. Next Node 管理

### 3.1 Next Node 定义

```c
// my_node.h

// Next node 枚举
typedef enum {
    MY_NEXT_OUTPUT = 0,
    MY_NEXT_DROP = 1,
    MY_NEXT_NEXT1 = 2,
    MY_N_NEXT,  // 总数
} my_next_node_t;
```

### 3.2 发送到 Next Node

```c
// 发送单个包到 next node
static_always_inline u32
vlib_put_next_frame(vlib_main_t *vm,
                     vlib_node_runtime_t *node,
                     u32 next_node_index,
                     u32 buffer_index)
{
    vlib_frame_t *f;
    u32 *to;

    // 获取 frame
    f = vlib_get_frame_with_slot(
        vm,
        node->node_runtime.next_frame,
        next_node_index,
        VLIB_FRAME_NO_FREE);

    // 添加 buffer
    to = vlib_frame_vector_args(f);
    to[0] = buffer_index;
    f->n_vectors = 1;

    return next_node_index;
}

// 批量发送
static_always_inline void
vlib_buffer_enqueue_to_next(vlib_main_t *vm,
                             vlib_node_runtime_t *node,
                             u32 *buffers,
                             u32 n_buffers)
{
    for (u32 i = 0; i < n_buffers; i++) {
        u32 bi = buffers[i];
        vlib_buffer_t *b = vlib_get_buffer(vm, bi);
        u32 next = b->current_config_index;

        vlib_put_next_frame(vm, node, next, bi);
    }
}
```

### 3.3 动态 Next Node

```c
// 设置 next node
static_always_inline void
my_set_next_node(vlib_buffer_t *b, u32 next)
{
    b->current_config_index = next;
}

// 获取 next node
static_always_inline u32
my_get_next_node(vlib_buffer_t *b)
{
    return b->current_config_index;
}
```

## 4. 性能优化

### 4.1 批量处理

```c
// 优化的批量处理
VLIB_NODE_FN(my_optimized_node)
{
    u32 *from = vlib_frame_vector_args(frame);
    u32 n_packets = frame->n_vectors;

    u32 n_next[MY_N_NEXT] = {0};
    u32 bi_next[MY_N_NEXT][MAX_BURST];

    // 批量预取
    for (u32 i = 0; i < n_packets; i++) {
        if (i + 4 < n_packets) {
            vlib_buffer_t *b = vlib_get_buffer(vm, from[i + 4]);
            CLIB_PREFETCH(b, CLIB_CACHE_LINE_SIZE, LOAD);
        }

        // 处理当前包
        u32 bi = from[i];
        u32 next = my_process(vm, bi);

        // 收集
        u32 slot = bi_next[next]++;
        bi_next[next][slot] = bi;
    }

    // 批量发送到每个 next
    for (u32 i = 0; i < MY_N_NEXT; i++) {
        if (n_next[i] > 0) {
            vlib_put_next_frame(vm, node, i, n_next[i]);
        }
    }

    return n_packets;
}
```

### 4.2 预取优化

```c
// 包数据预取
static_always_inline void
prefetch_packet_data(vlib_buffer_t *b)
{
    // 预取包数据
    CLIB_PREFETCH(b->data, 128, LOAD);

    // 预取 buffer
    CLIB_PREFETCH(b, CLIB_CACHE_LINE_SIZE, LOAD);
}

// 两层预取
for (u32 i = 0; i < n_packets; i++) {
    // 预取下一个 buffer 的 metadata
    if (i + 1 < n_packets) {
        vlib_buffer_t *b_next = vlib_get_buffer(vm, from[i + 1]);
        CLIB_PREFETCH(b_next, 2 * CLIB_CACHE_LINE_SIZE, LOAD);
    }

    // 处理当前
    u32 bi = from[i];
    // ...
}
```

### 4.3 错误处理优化

```c
// 错误字符串
static const char *my_error_strings[] = {
#define _(n, s) s,
    foreach_my_error
#undef _
};

// 在处理中设置错误
static_always_inline void
my_set_error(vlib_buffer_t *b, my_error_t error)
{
    b->error = node->errors[error];
}

// 检查错误
if (PREDICT_TRUE(b->error == 0)) {
    // 正常路径
} else {
    // 错误路径
}
```

## 5. Input Node

### 5.1 Input Node 注册

```c
// input_node.c

VLIB_REGISTER_NODE(my_input_node) = {
    .name = "my-input",
    .type = VLIB_NODE_TYPE_INPUT,

    .n_errors = MY_INPUT_N_ERROR,
    .error_strings = my_input_error_strings,

    // 输入节点特有
    .flag_details = (
        "interrupt: process on interrupt"
        "polling: process on poll"
    ),

    .sibling_of = "interface-tx",  // 在调度中和谁一起
};
```

### 5.2 中断 + 轮询

```c
// 带中断的 input node
VLIB_NODE_FN(my_interrupt_node)
{
    // 检查是否被中断唤醒
    if (node->flags & VLIB_NODE_FLAG_INTERRUPT) {
        // 处理中断
        handle_interrupt(node);
    }

    // 检查是否有轮询工作
    if (node->flags & VLIB_NODE_FLAG_POLLING) {
        // 处理轮询
        n_packets = rte_eth_rx_burst(...);
    }

    return process_packets(vm, node, buffers, n_packets);
}
```

## 6. 运行时数据

### 6.1 运行时数据

```c
// 节点运行时数据结构
typedef struct {
    u32 my_state;
    u64 packets_processed;
    u32 flags;
} my_runtime_t;

// 注册时指定大小
VLIB_REGISTER_NODE(my_stateful_node) = {
    .name = "my-stateful",
    .function = my_stateful_node_fn,
    .runtime_data_bytes = sizeof(my_runtime_t),
    // ...
};

// 获取运行时数据
static_always_inline my_runtime_t *
my_get_runtime(vlib_node_runtime_t *node)
{
    return (my_runtime_t *)node->runtime_data;
}
```

## 7. 完整示例

### 7.1 基本 Node

```c
// my_basic_node.c
#include <vpp/vpp.h>

// 错误定义
#define MY_N_ERROR 2
static const char *my_error_strings[] = {
#define _(a,b) b,
    foreach_my_error
#undef _
};

// Next node
typedef enum {
    MY_NEXT_OUTPUT = 0,
    MY_NEXT_DROP,
    MY_NEXT,
} my_next_t;

// 节点声明
VLIB_REGISTER_NODE(my_basic_node) = {
    .name = "my-basic",
    .function = my_basic_node_fn,
    .vector_size = sizeof(u32),

    .n_errors = MY_N_ERROR,
    .error_strings = my_error_strings,

    .n_next_nodes = MY_NEXT,
    .next_nodes = {
        [MY_NEXT_OUTPUT] = "interface-output",
        [MY_NEXT_DROP] = "error-drop",
    },
};

// 节点函数
uword
my_basic_node_fn(vlib_main_t *vm,
                  vlib_node_runtime_t *node,
                  vlib_frame_t *frame)
{
    u32 *from = vlib_frame_vector_args(frame);
    u32 n_packets = frame->n_vectors;

    for (u32 i = 0; i < n_packets; i++) {
        vlib_buffer_t *b = vlib_get_buffer(vm, from[i]);

        // 处理包
        if (PREDICT_TRUE(my_can_process(b))) {
            vlib_put_next_frame(vm, node, MY_NEXT_OUTPUT, from[i]);
        } else {
            b->error = node->errors[MY_ERROR_DROP];
            vlib_put_next_frame(vm, node, MY_NEXT_DROP, from[i]);
        }
    }

    return n_packets;
}
```

### 7.2 有状态的 Node

```c
// my_stateful_node.c

// 运行时数据
typedef struct {
    u64 total_packets;
    u32 last_counter;
} my_stateful_runtime_t;

// 节点
VLIB_REGISTER_NODE(my_stateful_node) = {
    .name = "my-stateful",
    .function = my_stateful_node_fn,
    .runtime_data_bytes = sizeof(my_stateful_runtime_t),
    // ...
};

uword
my_stateful_node_fn(vlib_main_t *vm,
                    vlib_node_runtime_t *node,
                    vlib_frame_t *frame)
{
    my_stateful_runtime_t *rt = (void *)node->runtime_data;
    u32 *from = vlib_frame_vector_args(frame);
    u32 n_packets = frame->n_vectors;

    rt->total_packets += n_packets;

    // 处理
    for (u32 i = 0; i < n_packets; i++) {
        // ...
    }

    return n_packets;
}
```

## 8. 总结

Node 架构：

```
┌─────────────────────────────────────────────────────────────┐
│                    Node 处理流程                            │
│                                                              │
│  Input Frame                                                │
│       ↓                                                      │
│  vlib_frame_vector_args() → buffer indices                 │
│       ↓                                                      │
│  for each packet {                                          │
│      process_packet()                                       │
│      determine_next()                                       │
│      vlib_put_next_frame()                                  │
│  }                                                          │
│       ↓                                                      │
│  Output Frames → Next Nodes                                  │
└─────────────────────────────────────────────────────────────┘
```

Node 类型：

| 类型          | 用途     | 特点        |
| ------------- | -------- | ----------- |
| **INPUT**     | NIC 接收 | 与 NIC 绑定 |
| **INTERNAL**  | 处理     | 中间节点    |
| **PROCESS**   | 异步     | 可中断      |
| **PRE_INPUT** | 协处理   | 高优先级    |

性能技巧：

```
1. 批量处理 - 减少函数调用
2. 预取数据 - 隐藏内存延迟
3. 减少分支 - 使用 PREDICT_TRUE/FALSE
4. 内联热点 - inline 关键字
5. 缓存友好 - 顺序访问内存
```

---

## 参考资源

- [VPP Node](https://wiki.fd.io/view/VPP/Graph_and_Packet_Processing)
- [VPP Node Registration](https://wiki.fd.io/view/VPP/How_to_Register_a_Node)
