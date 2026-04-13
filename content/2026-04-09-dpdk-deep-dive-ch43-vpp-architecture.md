---
title: "DPDK 第四十三章：VPP 架构与 vector packet processing"
date: 2026-04-09 17:20:00
tags: [dpdk, vpp, vector-packet-processing, fd.io, cisco]
description: "深入解析 VPP 架构：vector packet processing、node 图调度、plugin 机制、graph rewrite 与 DPDK 集成"
---

# DPDK 第四十三章：VPP 架构与 vector packet processing

> [!abstract] 核心要点
> VPP (Vector Packet Processing) 是 Cisco 开源的高性能数据包处理框架，采用向量批量处理替代逐包流水的设计。本章深入解析 VPP 核心架构、node 图调度、plugin 机制与 DPDK 集成。

## 1. VPP 概述

### 1.1 传统 Scalar vs Vector Processing

**Scalar Processing (传统 DPDK)**：
```
Packet 1 → [Parse] → [Lookup] → [Modify] → [Send] → Done
Packet 2 → [Parse] → [Lookup] → [Modify] → [Send] → Done
Packet 3 → [Parse] → [Lookup] → [Modify] → [Send] → Done
         (逐包处理，每包独立流水线)

CPU:     |████░░░░|████░░░░|████░░░░|  ← 分支预测失败、Cache miss 频繁
```

**Vector Processing (VPP)**：
```
[Packet 1, Packet 2, Packet 3, ..., Packet N] → [Batch Parse] → [Batch Lookup] → [Batch Modify] → [Batch Send]
         (向量处理，利用 SIMD 和缓存局部性)

CPU:     |████████████|  ← 一次循环处理多个包
```

### 1.2 VPP 性能优势

| 指标 | Scalar | Vector | 提升 |
|------|--------|--------|------|
| **每包开销** | ~100 cycles | ~10 cycles | 10x |
| **分支预测** | 每包一次 | 每向量一次 | 10x |
| **Cache 效率** | 差 | 高 | 5-10x |
| **吞吐** | ~10 Mpps/core | ~50 Mpps/core | 5x |

### 1.3 VPP 在 FD.io 的位置

```
FD.io (Linux Foundation)
├── VPP (Vector Packet Processing) ← 旗舰项目
├── Honeycomb (NETCONF/YANG 管理)
├── HC2 (VPP + OpenStack)
├── CNX (Cloud Native VPP)
└── Velacloud (WAN Optimization)
```

## 2. 核心架构

### 2.1 VPP Main Loop

```c
// vpp/src/vpp-api/custom_dump.c (伪代码)
int vpp_main_loop(vlib_main_t *vm)
{
    while (1) {
        // 1. 获取一组包 (vector)
        u32 n_packets = vlib_rx_vector_submit(vm, node, n_rx);

        if (n_packets == 0) {
            // 无包，轮询或休眠
            vlib_rx_wait(vm, node);
            continue;
        }

        // 2. 批量调度到 node 图
        vlib_node_runtime_sync(vm, node);

        // 3. 图遍历直到无更多调度
        while (vlib_num_pending_nodes(vm) > 0) {
            vlib_node_t *node = vlib_pending_node(vm);
            vlib_node_runtime_invoke(vm, node);
        }

        // 4. TX
        vlib_tx_vector_submit(vm, node, n_packets);
    }
}
```

### 2.2 Node 图结构

```
┌─────────────────────────────────────────────────────────────┐
│                      VPP Node Graph                          │
│                                                              │
│                    ┌──────────────────┐                      │
│                    │   device-input   │                      │
│                    │   (ethernet0)    │                      │
│                    └────────┬─────────┘                      │
│                             │                                 │
│         ┌───────────────────┼───────────────────┐            │
│         │                   │                   │            │
│         ▼                   ▼                   ▼            │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐     │
│  │   arp-input │    │  ip4-input  │    │  ip6-input  │     │
│  └──────┬──────┘    └──────┬──────┘    └──────┬──────┘     │
│         │                   │                   │            │
│         │              ┌────┴────┐              │            │
│         │              ▼         ▼              │            │
│         │       ┌───────────┐ ┌───────────┐      │            │
│         │       │ip4-lookup │ │ip4-rewrite│      │            │
│         │       └─────┬─────┘ └───────────┘      │            │
│         │             │                           │            │
│         │             └─────────┬─────────────────┘            │
│         │                       │                              │
│         ▼                       ▼                               │
│  ┌─────────────┐    ┌─────────────────────┐                   │
│  │interface-out│    │   ethernet-output    │                   │
│  └─────────────┘    └─────────────────────┘                   │
└─────────────────────────────────────────────────────────────┘
```

### 2.3 关键数据结构

```c
// vlib_buffer_t - VPP 包缓冲区
typedef struct {
    // 通用头
    u32 magic;

    // 包数据指针
    u8 *data;
    u32 current_data;  // 当前解析位置

    // 长度信息
    u16 rx_hash;
    u16 rx_hash_protocol;
    u32 flags;
    u32 error;

    // 元数据
    u32 flow_id;
    u16 ip_frag;
    u16 ip6_expire;

    // 可变头空间 (headroom)
    u32 prepend_header_data;

    // 包头（inline，避免额外指针）
    ethernet_header_t ethernet;
    ip4_header_t ip4;
    tcp_udp_header_t l4;
} vlib_buffer_t;

// vlib_node_t - 图节点
typedef struct vlib_node {
    char *name;                           // 节点名称
    u32 index;                            // 全局索引

    // 输入边 (哪些节点可以调度到本节点)
    uword *input_by_thread;

    // 运行时状态
    vlib_node_runtime_t runtime[];       // per-thread 运行时
} vlib_node_t;

// vlib_frame_t - 包向量容器
typedef struct {
    u32 n_vectors;        // 包数量
    u32 flags;

    // 包索引数组（物理上紧接着 frame 头）
    u32 scalars[];
    // u32 buffers[];  // 包索引在后面的可变数组
} vlib_frame_t;
```

## 3. Node 实现

### 3.1 Node 注册

```c
// 定义 node 的输入类型
VLIB_NODE_FN(my_node_fn) (vlib_main_t *vm,
                          vlib_node_runtime_t *node,
                          vlib_frame_t *frame)
{
    u32 *from, n_packets;

    from = vlib_frame_vector_args(frame);
    n_packets = frame->n_vectors;

    // 向量处理：一次性处理所有包
    for (u32 i = 0; i < n_packets; i++) {
        u32 bi = from[i];
        vlib_buffer_t *b = vlib_get_buffer(vm, bi);

        // 处理逻辑...
        process_packet(b);
    }

    return n_packets;  // 传递给下一节点
}

// 注册 node（静态初始化）
VLIB_REGISTER_NODE(my_node) = {
    .function = my_node_fn,
    .name = "my-node",
    .short_name = "mynode",
    .node_fn_flags = VLIB_NODE_FLAG_NONE,

    .input_nodes = VLIB_NODE_FN(my_node),
    .n_next_nodes = 1,

    // 下一个节点名称
    .next_nodes = {
        [0] = "interface-output",
    },
};
```

### 3.2 多 next（分支）

```c
// 定义多个输出边
VLIB_REGISTER_NODE(ip4_lookup_node) = {
    .name = "ip4-lookup",
    .function = ip4_lookup_fn,
    .vector_size = 4,

    .n_next_nodes = IP4_LOOKUP_N_NEXT,

    .next_nodes = {
        [IP4_LOOKUP_NEXT_DROP] = "error-drop",
        [IP4_LOOKUP_NEXT_REWRITE] = "ip4-rewrite",
        [IP4_LOOKUP_NEXT_ARP] = "arp",
        [IP4_LOOKUP_NEXT_ICMP_ERROR] = "icmp-error",
    },
};

// 调度到不同 next
switch (result) {
    case RESULT_DROP:
        next_index = IP4_LOOKUP_NEXT_DROP;
        break;
    case RESULT_LOCAL:
        next_index = IP4_LOOKUP_NEXT_REWRITE;
        break;
    case RESULT_GARP:
        next_index = IP4_LOOKUP_NEXT_ARP;
        break;
}

// 使用 vlib_set_next_frame 调度
vlib_next_frame_t *nf;
vlib_get_next_frame(vm, node, next_index, &nf);

// 将包索引写入下一节点的 frame
nf->n_vectors += n_to_schedule;
nf->vectors[] = buffer_indices[];

// 提交帧
vlib_put_next_frame(vm, node, next_index, nf);
```

### 3.3 Graph Rewrite

VPP 支持动态修改 node 图：

```bash
# 将 eth0 的流量重定向到 my-node
vpp# set interface input node eth0 my-node

# 恢复默认
vpp# set interface input node eth0 GigabitEthernet0/8/0

# 查看当前配置
vpp# show hardware
vpp# show node
```

## 4. Plugin 机制

### 4.1 Plugin 结构

```
plugin/
├── CMakeLists.txt
├── vpp-plugin-dpdk.conf         # 插件描述
├── api/
│   ├── my_plugin.api             # API 定义
│   └── my_plugin.api_dump.c      # API 实现
├── my_plugin.c                   # 主实现
├── node1.c                       # 自定义 node
├── node2.c
└── test/
    └── test_my_plugin.c
```

### 4.2 Plugin 初始化

```c
// my_plugin.c
#include <vnet/plugin/plugin.h>

// 插件注册
VLIB_PLUGIN_REGISTER() = {
    .version = VPP_BUILD_VER,
    .description = "My DPDK Plugin",
};

// 插件初始化函数
clib_error_t *my_plugin_init(vlib_main_t *vm)
{
    my_plugin_main_t *pm = &my_plugin_main;

    // 初始化资源
    pm->my_table = hash_create(0, sizeof(uword));

    return 0;
}

// 清理函数
clib_error_t *my_plugin_exit(vlib_main_t *vm)
{
    my_plugin_main_t *pm = &my_plugin_main;
    hash_free(pm->my_table);
    return 0;
}

// 使用 VLIB_PLUGIN_INIT 宏
VLIB_PLUGIN_INIT() = {
    .init_function = my_plugin_init,
    .exit_function = my_plugin_exit,
};
```

### 4.3 插件配置

```bash
# /etc/vpp/startup.conf
unix {
    cli-listen /run/vpp/cli.sock
    cli-no-pager
}

dpdk {
    dev 0000:3d:00.0
    dev 0000:3d:00.1

    # 插件目录
    plugin /usr/lib/vpp_plugins/
    plugin dpdk_plugin.so { disable }
    plugin my_plugin.so { enable }
}
```

## 5. DPDK 集成

### 5.1 VPP + DPDK

```bash
# 启动 VPP（使用 DPDK 驱动）
vpp unix { cli-listen /run/vpp/cli.sock }
dpdk {
    dev 0000:3d:00.0
    dev 0000:3d:00.1
    uio-driver igb_uio
}
```

### 5.2 VPP 节点 vs DPDK PMD

| 组件 | VPP | DPDK PMD |
|------|-----|-----------|
| **线程模型** | per-thread lcore | per-thread lcore |
| **发包方式** | vlib_frame | rte_mbuf |
| **Buffer 管理** | vlib_buffer pool | rte_mempool |
| **接口抽象** | vnet_sw_interface | rte_ethdev |

### 5.3 内存管理

```c
// VPP 使用 hugepage 内存
// 通过 vlib_buffer_pool_create 创建

// Buffer 头空间（headroom）用于封装
// +----------------+------------------+---------------------+
// |   Pre-header   |   Buffer data   |   Trailer (optional)|
// |   (headroom)   |                  |                     |
// +----------------+------------------+---------------------+
// |<-------- current_data ---------->|
// |<---------- data_len ------------>|

// 典型的 prepend（添加外层头）
vlib_buffer_reset(b);
vlib_buffer_advance(b, -sizeof(vxlan_header_t));
```

## 6. 实际案例：负载均衡器

### 6.1 L2/L3 LB 实现

```c
// lb_node.c
VLIB_NODE_FN(lb_node) (vlib_main_t *vm,
                        vlib_node_runtime_t *node,
                        vlib_frame_t *frame)
{
    u32 *from = vlib_frame_vector_args(frame);
    u32 n_packets = frame->n_vectors;
    u32 n_left = n_packets;

    while (n_left > 0) {
        u32 bi = from[n_packets - n_left];
        vlib_buffer_t *b = vlib_get_buffer(vm, bi);

        // 解析 IP
        ip4_header_t *ip = vlib_buffer_get_current(b);

        // NAT: 修改目的地址
        ip->dst_address = lb_backend_ip;

        // 重新计算 checksum
        ip->checksum = ip4_header_checksum(ip);

        // 查找下一跳 MAC
        lb_arp_t *arp_entry = hash_get(lb_arp_table, ip->dst_address);
        ethernet_header_t *eth = vlib_buffer_get_current(b) - sizeof(ethernet_header_t);

        // 修改 MAC
        memcpy(eth->dst_address, arp_entry->mac, 6);

        n_left--;
    }

    // 发送到 output
    vlib_put_next_frame(vm, node, LB_NEXT_OUTPUT, frame);
}
```

## 7. 性能调优

### 7.1 Buffer 调整

```bash
# /etc/vpp/startup.conf
buffers {
    # 增加 buffer 数量（默认 16384）
    default heap size 64M
    # 每个接口的 buffer 数量
    per-thread caches 256
}
```

### 7.2 线程亲和

```bash
# 绑定 worker 到特定 CPU
vpp# set threading mode circular 4

# 或者使用 explicit affinity
vpp# set thread [worker 0] cpu [core 1]
vpp# set thread [worker 1] cpu [core 3]
```

## 8. 总结

VPP 的核心设计哲学：

1. **Vector Processing**：批量处理包，利用缓存和分支预测
2. **Graph Scheduling**：灵活的 node 图，支持动态重配置
3. **Plugin 架构**：可插拔，易于扩展
4. **DPDK 集成**：VPP = DPDK + 丰富协议栈

---

## 参考资源

- [FD.io VPP 官方文档](https://fd.io/)
- [VPP GitHub](https://github.com/FDio/vpp)
- [VPP 代码结构](https://wiki.fd.io/view/VPP/Source_Code_Organization)
