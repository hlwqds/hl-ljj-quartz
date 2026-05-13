---
title: "VPP 高级特性：QoS、ACL、癸酉技术与性能调优"
date: 2026-04-09 19:00:00
tags: [vpp, qos, acl, interface-queue, policer, shaper, traffic-management]
description: "深入 VPP 高级特性：QoS 队列、ACL 卸载、Interface Queue、Policer、Shaper 与流量整形"
---

# VPP 高级特性：QoS、ACL、癸酉技术与性能调优

> [!abstract] 概述
> 本章深入探讨 VPP 的高级网络特性：QoS 队列管理与整形、ACL 卸载、Interface Queue、Policer、Shaper 与流量整形技术。

## 1. QoS (Quality of Service)

### 1.1 QoS 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    VPP QoS 架构                             │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │                 Ingress QoS                          │  │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐             │  │
│  │  │ Mark    │  │ Policer │  │  Queue  │             │  │
│  │  │ (DSCP) │  │ (Rate)  │  │ (WFQ)   │             │  │
│  │  └─────────┘  └─────────┘  └─────────┘             │  │
│  └──────────────────────────────────────────────────────┘  │
│                            │                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │                 Egress QoS                            │  │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐             │  │
│  │  │ Shaper  │  │ Scheduler│  │  WFQ   │             │  │
│  │  │ (Rate)  │  │ (SP/PQ) │  │         │             │  │
│  │  └─────────┘  └─────────┘  └─────────┘             │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 QoS Source

```c
// QoS 源类型
enum qos_source_t {
    QOS_SOURCE_IPV4,         // IP DSCP
    QOS_SOURCE_IPV6,         // IPv6 Traffic Class
    QOS_SOURCE_MPLS,         // MPLS EXP
    QOS_SOURCE_VLAN,         // VLAN PCP
    QOS_SOURCE_ETHERNET,     // Ethernet
    QOS_SOURCE_L2TPV3,       // L2TPv3
    QOS_SOURCE_MAX,
};

// 从包头提取 QoS 标记
static_always_inline qos_bits_t
qos_bits_from_header(u8 source, vlib_buffer_t *b)
{
    ethernet_header_t *eth;
    ip4_header_t *ip4;
    ip6_header_t *ip6;

    switch (source) {
    case QOS_SOURCE_IPV4:
        ip4 = (ip4_header_t *)vlib_buffer_get_current(b);
        return (ip4->tos);

    case QOS_SOURCE_IPV6:
        ip6 = (ip6_header_t *)vlib_buffer_get_current(b);
        return (ip6->tc);

    case QOS_SOURCE_VLAN:
        eth = (ethernet_header_t *)vlib_buffer_get_current(b);
        return (eth->type >> 13);  // VLAN PCP

    default:
        return 0;
    }
}
```

### 1.3 QoS 标记

```c
// 设置 DSCP
static_always_inline void
qos_mark_ip(vlib_buffer_t *b, qos_bits_t dscp)
{
    ip4_header_t *ip = vlib_buffer_get_current(b);
    ip->tos = dscp;
    ip->checksum = ip4_header_checksum(ip);
}

// 设置 VLAN PCP
static_always_inline void
qos_mark_vlan(vlib_buffer_t *b, u8 pcp)
{
    ethernet_vlan_header_t *vlan =
        (ethernet_vlan_header_t *)vlib_buffer_get_current(b);

    vlan->type = (vlan->type & 0x1FFF) | (pcp << 13);
}
```

## 2. QoS 队列

### 2.1 多队列架构

```c
// Interface 支持多个 QoS 队列
struct vnet_hw_interface {
    // ...
    u32 output_node_index;           // 输出 node

    // QoS 配置
    qos_bits_t output_qos_classification;  // QoS 分类模式
    u32 output_qos_queue_id;               // 队列 ID
    struct qos_cos_values *cos_values;     // CoS 值映射

    // 多队列
    u32 *tx_queue_indices;          // TX 队列数组
};

// 队列数量
struct qos_queue {
    u32 queue_id;
    u32 size;                        // 队列深度
    u32 packets;                    // 当前包数
    u64 bytes;                      // 当前字节数
};
```

### 2.2 队列调度

```c
// WFQ (Weighted Fair Queuing)
static u32
wfq_choose_next(vlib_main_t *vm, qos_main_t *qm)
{
    u32 min_packets = ~0;
    u32 chosen_queue = 0;

    for (i = 0; i < qm->n_queues; i++) {
        qos_queue_t *q = &qm->queues[i];

        if (q->packets == 0) continue;

        // 计算虚拟时间
        u64 virtual_time = q->virtual_time +
            (q->packets * q->weight);

        if (virtual_time < min_virtual_time) {
            min_virtual_time = virtual_time;
            chosen_queue = i;
        }
    }

    return chosen_queue;
}

// SP (Strict Priority) 调度
static u32
sp_choose_next(qos_main_t *qm)
{
    // 从高到低找第一个非空队列
    for (i = 0; i < qm->n_queues; i++) {
        if (qm->queues[i].packets > 0) {
            return i;  // 最高优先级非空队列
        }
    }
    return ~0;
}
```

## 3. Policer (流量限制)

### 3.1 单速率三色

```c
// 单速率三色 Policing (RFC 2697)
// 桶大小：CIR (Committed Information Rate)
//        PBS (Peak Burst Size)
//        CBS (Committed Burst Size)

struct policer_single_rate {
    u64 cir;           // 承诺速率 (bytes/s)
    u64 cbs;           // 承诺突发 (bytes)
    u64 ebs;           // 超额突发 (bytes)

    u64 last_time;     // 上次检查时间
    u64 committed;     // 承诺桶
    u64 excess;        // 超额桶
};

enum policer_color {
    POLICER_GREEN,     // 绿色 - 符合 CIR
    POLICER_YELLOW,    // 黄色 - 超出 CIR 但符合 PBS
    POLICER_RED,       // 红色 - 超出 PBS
};

// 单速率三色算法
static enum policer_color
policer_single_rate(vlib_main_t *vm,
                   struct policer_single_rate *p,
                   u32 pkts, u64 bytes)
{
    u64 now = vlib_time_now(vm);
    u64 time_delta = now - p->last_time;

    // 补充桶
    p->committed = clib_min(p->cbs,
                            p->committed + time_delta * p->cir / 1e9);
    p->excess = clib_min(p->ebs,
                         p->excess + time_delta * p->cir / 1e9);

    p->last_time = now;

    // 检查颜色
    if (bytes <= p->committed) {
        // 绿色
        p->committed -= bytes;
        return POLICER_GREEN;
    } else if (bytes <= p->committed + p->excess) {
        // 黄色
        p->excess -= (bytes - p->committed);
        p->committed = 0;
        return POLICER_YELLOW;
    } else {
        // 红色
        return POLICER_RED;
    }
}
```

### 3.2 双速率三色

```c
// 双速率三色 Policing (RFC 2698)
// 两个桶：CIR + PIR (Peak Information Rate)

struct policer_dual_rate {
    u64 cir;           // 承诺速率
    u64 pir;           // 峰值速率
    u64 cbs;           // 承诺突发
    u64 pbs;           // 峰值突发

    u64 committed;
    u64 peak;
    u64 last_time;
};

// 双速率三色算法
static enum policer_color
policer_dual_rate(vlib_main_t *vm,
                 struct policer_dual_rate *p,
                 u32 pkts, u64 bytes)
{
    u64 now = vlib_time_now(vm);
    u64 time_delta = now - p->last_time;

    // 补充桶
    p->committed = clib_min(p->cbs,
                            p->committed + time_delta * p->cir / 1e9);
    p->peak = clib_min(p->pbs,
                       p->peak + time_delta * p->pir / 1e9);

    p->last_time = now;

    // 检查
    if (bytes <= p->committed) {
        p->committed -= bytes;
        return POLICER_GREEN;
    } else if (bytes <= p->peak) {
        p->peak -= bytes;
        return POLICER_YELLOW;
    } else {
        return POLICER_RED;
    }
}
```

### 3.3 VPP Policer Node

```c
// VPP policer node
VLIB_REGISTER_NODE(policer_node) = {
    .function = policer_node_fn,
    .name = "policer",
    .type = VLIB_NODE_TYPE_INTERNAL,

    .input_nodes = {
        [POLICER_INPUT_NEXT_VALID] = "interface-output",
        [POLICER_INPUT_NEXT_DROP] = "error-drop",
    },
};

// policer 配置
struct policer_config {
    u64 cir;           // bytes/s
    u64 pir;           // bytes/s (0 = single rate)
    u64 cbs;
    u64 ebs;
    u64 pbs;

    enum policer_type {
        POLICER_TYPE_SINGLE_RATE,
        POLICER_TYPE_DUAL_RATE,
    } type;

    enum policer_action {
        POLICER_ACTION_NONE,
        POLICER_ACTION_DROP,
        POLICER_ACTION_MARK,
        POLICER_ACTION_TRANSPARENT,
    } actions[3];  // per color
};
```

## 4. ACL (Access Control List)

### 4.1 ACL 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    VPP ACL 架构                            │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │                    ACL Table                          │  │
│  │  ┌────────────────────────────────────────────────┐  │  │
│  │  │ ACL #1: deny tcp src 10.0.0.0/8 dst 0.0.0.0/0 │  │  │
│  │  │ ACL #2: permit ip src 0.0.0.0/0 dst 0.0.0.0/0 │  │  │
│  │  └────────────────────────────────────────────────┘  │  │
│  └──────────────────────────────────────────────────────┘  │
│                            │                                 │
│  ┌──────────────────────────────────────────────────────┐  │
│  │                 ACL Lookup (L2-L4)                    │  │
│  │  - 5-tuple hash                                      │  │
│  │  - MAC (L2) / IP (L3/L4)                             │  │
│  │  - Per-interface ACL binding                        │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 ACL 条目结构

```c
// ACL 条目
struct acl_entry {
    // L2
    u8 src_mac[6];
    u8 dst_mac[6];
    u16 ethertype_mask;

    // L3
    u8 is_ip;              // 0 = ether, 1 = IP
    ip46_address_t src_ip;
    ip46_address_t dst_ip;
    u32 src_ip_prefix_len;
    u32 dst_ip_prefix_len;

    // L4
    u8 proto;             // TCP/UDP/ICMP/ANY
    u16 src_port_lo;
    u16 src_port_hi;
    u16 dst_port_lo;
    u16 dst_port_hi;

    // Action
    u8 is_permit;
    u8 is_allow;

    // Meta
    u32 hit_count;
};

// ACL 表
struct acl_table {
    u32 table_id;
    vec_t(acl_entry) entries;

    // 查找优化
    struct rte_hash *hash;
    struct rte_mempool *entry_pool;
};
```

### 4.3 ACL 查找

```c
// ACL 匹配
static int
acl_match_entry(acl_entry_t *e, vlib_buffer_t *b,
                ethernet_header_t *eth, ip4_header_t *ip)
{
    // L2 检查
    if (e->ethertype_mask) {
        if ((eth->type & e->ethertype_mask) !=
            (e->ethertype & e->ethertype_mask)) {
            return 0;  // 不匹配
        }
    }

    // L3 检查
    if (e->is_ip) {
        // 源 IP
        if (!ip_in_range(ip->src_addr, &e->src_ip, e->src_ip_prefix_len)) {
            return 0;
        }
        // 目的 IP
        if (!ip_in_range(ip->dst_addr, &e->dst_ip, e->dst_ip_prefix_len)) {
            return 0;
        }
    }

    // L4 检查
    if (e->proto != 0 && e->proto != ip->protocol) {
        return 0;
    }

    return 1;  // 匹配
}

// 查找 ACL
static int
acl_lookup(acl_table_t *t, vlib_buffer_t *b)
{
    // 解析包头
    ethernet_header_t *eth = vlib_buffer_get_current(b);
    ip4_header_t *ip = (ip4_header_t *)(eth + 1);

    // 遍历所有条目
    for (int i = 0; i < vec_len(t->entries); i++) {
        if (acl_match_entry(&t->entries[i], b, eth, ip)) {
            return i;  // 返回匹配的条目索引
        }
    }

    return -1;  // 无匹配 = deny
}
```

### 4.4 ACL Node

```c
VLIB_REGISTER_NODE(acl_node) = {
    .function = acl_node_fn,
    .name = "acl",
    .type = VLIB_NODE_TYPE_INTERNAL,

    .input_nodes = {
        [ACL_NEXT_PERMIT] = "interface-output",
        [ACL_NEXT_DENY] = "error-drop",
    },
};

static uword
acl_node_fn(vlib_main_t *vm, vlib_node_runtime_t *node,
            vlib_frame_t *frame)
{
    u32 *from = vlib_frame_vector_args(frame);
    u32 n_packets = frame->n_vectors;
    u32 n_left = n_packets;

    while (n_left > 0) {
        u32 bi = from[n_packets - n_left];
        vlib_buffer_t *b = vlib_get_buffer(vm, bi);

        // 查找 ACL
        int match = acl_lookup(acl_table, b);

        if (match >= 0 && acl_table->entries[match].is_permit) {
            // 允许
            next_index = ACL_NEXT_PERMIT;
        } else {
            // 拒绝
            next_index = ACL_NEXT_DENY;
        }

        n_left--;
    }

    return n_packets;
}
```

## 5. 流量整形 (Shaping)

### 5.1 令牌桶整形

```c
// 令牌桶 Shaper
struct shaper {
    u64 rate;             // 速率 (bytes/s)
    u64 burst;            // 突发大小
    u64 tokens;           // 当前令牌数
    u64 last_update;      // 上次更新时间
};

static_always_inline void
shaper_add_tokens(struct shaper *s, u64 bytes)
{
    u64 now = vlib_time_now(NULL);
    u64 elapsed = now - s->last_update;

    // 补充令牌
    s->tokens = clib_min(s->burst,
                          s->tokens + elapsed * s->rate / 1e9);
    s->last_update = now;
}

static_always_inline int
shaper_can_send(struct shaper *s, u64 bytes)
{
    if (s->tokens >= bytes) {
        s->tokens -= bytes;
        return 1;  // 可以发送
    }
    return 0;  // 整形
}
```

### 5.2 WFQ 加权整形

```c
// 多队列 WFQ + 整形
struct wfq_shaper {
    // 每个队列的整形器
    struct shaper *shapers;

    // 权重
    u32 *weights;

    // 调度
    u64 *virtual_time;
};

// WFQ + 整形调度
static u32
wfq_shaper_schedule(wfq_shaper_t *wfq)
{
    // 找最小虚拟时间的队列
    u32 min_idx = 0;
    u64 min_vt = ~0;

    for (i = 0; i < wfq->n_queues; i++) {
        if (wfq->shapers[i].tokens == 0) {
            continue;  // 整形中，跳过
        }

        if (wfq->virtual_time[i] < min_vt) {
            min_vt = wfq->virtual_time[i];
            min_idx = i;
        }
    }

    // 更新虚拟时间
    u64 delta = wfq->shapers[min_idx].tokens / wfq->weights[min_idx];
    wfq->virtual_time[min_idx] += delta;

    return min_idx;
}
```

## 6. 接口队列管理

### 6.1 Interface Queue

```c
// 接口队列配置
struct vnet_hw_interface {
    // ...
    u32 tx_queue_push;           // TX 队列
    u32 tx_queue_pop;           // TX 队列

    // 队列参数
    u32 queue_size;             // 队列深度
    u32 tx_start;
    u32 tx_end;
};

// 设置接口队列
int vnet_hw_interface_set_tx_queue(vlib_main_t *vm,
                                   u32 hw_if_index,
                                   u32 queue_id)
{
    vnet_hw_interface_t *hw =
        vnet_get_hw_interface(vm, hw_if_index);

    hw->tx_queue_push = queue_id;
    hw->tx_queue_pop = queue_id;

    // 绑定到 interface-output node
    vnet_hw_interface_set_output_node(vm, hw_if_index,
                                      interface_tx_node.index);

    return 0;
}
```

### 6.2 队列操作

```bash
# CLI 配置
vpp# set interface queue GigabitEthernet0/8/0 rx 1024 tx 512

# 查看队列状态
vpp# show interface queue GigabitEthernet0/8/0
```

## 7. 性能调优

### 7.1 Buffer 调优

```bash
# 调整全局 buffer 大小
vpp# set buffers size 4096

# 预分配 buffer
vpp# set buffers preallocated 32768

# 查看 buffer 使用
vpp# show buffers
```

### 7.2 中断 vs 轮询

```bash
# 启用中断模式
vpp# set interface mode interrupt GigabitEthernet0/8/0

# 切换回轮询
vpp# set interface mode polling GigabitEthernet0/8/0

# 自适应模式
vpp# set interface mode adaptive GigabitEthernet0/8/0
```

### 7.3 RSS (Receive Side Scaling)

```bash
# 启用 RSS
vpp# set interface RSS GigabitEthernet0/8/0 enable

# 配置 RSS 队列
vpp# set interface RSS GigabitEthernet0/8/0 queues 4

# 查看 RSS 配置
vpp# show interface RSS GigabitEthernet0/8/0
```

## 8. 实际案例：流量管理器

### 8.1 完整实现

```c
// 流量管理器 - 综合使用 QoS/ACL/Policer
struct traffic_manager {
    // ACL 表
    acl_table_t *acl_table;

    // Policer
    struct policer_dual_rate *policers;

    // QoS
    qos_source_t qos_source;
    struct qos_rewrite *qos_rw;

    // Shaper per interface
    struct shaper *interface_shapers;
};

static_always_inline uword
traffic_manager_node_fn(vlib_main_t *vm,
                        vlib_node_runtime_t *node,
                        vlib_frame_t *frame)
{
    u32 *from = vlib_frame_vector_args(frame);
    u32 n_packets = frame->n_vectors;

    for (u32 i = 0; i < n_packets; i++) {
        u32 bi = from[i];
        vlib_buffer_t *b = vlib_get_buffer(vm, bi);

        // 1. ACL 检查
        if (acl_lookup(tm->acl_table, b) < 0) {
            // 拒绝
            vlib_buffer_free(vm, &bi, 1);
            continue;
        }

        // 2. Policer
        enum policer_color color =
            policer_dual_rate(vm, tm->policer, 1,
                              vlib_buffer_length_in_chain(vm, b));

        if (color == POLICER_RED) {
            // 丢弃
            vlib_buffer_free(vm, &bi, 1);
            continue;
        }

        // 3. QoS 标记
        qos_bits_t dscp = qos_bits_from_header(tm->qos_source, b);
        qos_mark_ip(b, dscp);

        // 4. 发送到输出
        vlib_put_next_frame(vm, node, TM_NEXT_OUTPUT, &bi, 1);
    }

    return n_packets;
}
```

## 9. 总结

| 特性                | 用途       | 位置    |
| ------------------- | ---------- | ------- |
| **Policer**         | 流量限制   | Ingress |
| **ACL**             | 访问控制   | Ingress |
| **QoS Mark**        | 优先级标记 | Ingress |
| **Shaper**          | 流量整形   | Egress  |
| **WFQ**             | 公平调度   | Egress  |
| **Interface Queue** | 队列管理   | Egress  |

VPP 高级特性组合可以构建复杂的流量管理系统：

1. **Ingress**：ACL → Policer → QoS Mark
2. **Egress**：WFQ → Shaper → Interface Queue

---

## 参考资源

- [VPP QoS](https://wiki.fd.io/view/VPP/QoS)
- [VPP ACL](https://wiki.fd.io/view/VPP/ACL)
- [VPP Policer](https://wiki.fd.io/view/VPP/Policer)
- [RFC 2697 - Single Rate Three Color Marker](https://tools.ietf.org/html/rfc2697)
- [RFC 2698 - Dual Rate Three Color Marker](https://tools.ietf.org/html/rfc2698)
