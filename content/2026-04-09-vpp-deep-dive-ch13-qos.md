---
title: "VPP 深入探讨 ch13：QoS 队列与调度"
date: 2026-04-10 00:30:00
tags: [vpp, qos, quality-of-service, scheduling, wfq, sp, wrr, queue, dscp]
description: "深入解析 VPP QoS：队列管理、SP/WFQ/WRR 调度算法、DSCP 映射、QoS 标记与 WRED"
---

# VPP 深入探讨 ch13：QoS 队列与调度

> [!abstract] 核心要点
> QoS 是保证网络服务质量的关键。本章深入解析 VPP 队列管理、SP/WFQ/WRR 调度算法、DSCP 映射、QoS 标记与 WRED。

## 1. QoS 概述

### 1.1 QoS 组件

```
┌─────────────────────────────────────────────────────────────┐
│                    QoS 组件                                │
│                                                              │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐       │
│  │ Classification│  │  Marking    │  │  Policing   │       │
│  │ (分类)      │  │  (标记)     │  │  (限速)     │       │
│  └─────────────┘  └─────────────┘  └─────────────┘       │
│                                                              │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐       │
│  │  Queuing    │  │ Scheduling  │  │  Shaping    │       │
│  │  (队列)     │  │  (调度)     │  │  (整形)     │       │
│  └─────────────┘  └─────────────┘  └─────────────┘       │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 QoS 模型

```
Ingress QoS (输入)：
  包 → Classifier → Marker → Policer → Queue

Egress QoS (输出)：
  Queue → Scheduler → Shaper → NIC
```

## 2. 队列管理

### 2.1 队列结构

```c
// QoS 队列
typedef struct {
    // 队列标识
    u32 queue_id;
    u32 interface_id;

    // 队列参数
    u32 size;              // 队列大小（包数）
    u32 size_bytes;        // 队列大小（字节）

    // 统计
    u64 packets;
    u64 bytes;
    u64 drops;             // 队列满导致的丢弃
    u64 mark;              // ECN 标记

    // 状态
    volatile u32 head;     // 队首
    volatile u32 tail;     // 队尾
    u32 *buffers;          // 包 buffer 索引数组
} qos_queue_t;

// 多队列支持
struct qos_bitmap {
    qos_queue_t queues[8];  // 8 个队列
    u32 num_queues;
};
```

### 2.2 队列操作

```c
// 入队
static inline int
qos_enqueue(qos_queue_t *q, u32 bi)
{
    u32 head = q->head;
    u32 next = (head + 1) % q->size;

    if (next == q->tail) {
        // 队列满，丢弃
        q->drops++;
        vlib_buffer_free(vm, bi);
        return -1;
    }

    q->buffers[head] = bi;
    q->head = next;
    q->packets++;
    q->bytes += vlib_buffer_length_in_chain(vm, bi);

    return 0;
}

// 出队
static inline int
qos_dequeue(qos_queue_t *q, u32 *bi)
{
    if (q->tail == q->head) {
        // 队列空
        return -1;
    }

    *bi = q->buffers[q->tail];
    q->tail = (q->tail + 1) % q->size;
    q->packets--;

    return 0;
}
```

## 3. 调度算法

### 3.1 SP (Strict Priority)

```
SP (Strict Priority) 调度：

高优先级队列优先，直到为空才服务低优先级

队列优先级：Q7 > Q6 > Q5 > Q4 > Q3 > Q2 > Q1 > Q0

┌─────────────────────────────────────────────────────────────┐
│                    SP 调度                                  │
│                                                              │
│  Q7: [■■■■■■■■■■]     ← 完全服务                           │
│  Q6: [■■■■■■]        ← Q7 空后服务                         │
│  Q5: [■■■■]           ← Q6 Q7 空后服务                     │
│  ...                                                        │
│  Q0: [■■]              ← 所有高优先级空后                   │
└─────────────────────────────────────────────────────────────┘

优点：简单，保证最高优先级延迟
缺点：可能饿死低优先级
```

```c
// SP 调度
static inline u32
sched_sp(qos_queue_t *queues, u32 n_queues)
{
    // 从最高优先级开始
    for (int i = n_queues - 1; i >= 0; i--) {
        if (queues[i].head != queues[i].tail) {
            // 队列非空
            u32 bi;
            qos_dequeue(&queues[i], &bi);
            return bi;
        }
    }
    return ~0;  // 所有队列空
}
```

### 3.2 WFQ (Weighted Fair Queuing)

```
WFQ 调度：

按权重比例分配带宽

权重配置：
  Q0: weight 1  →  10% 带宽
  Q1: weight 2  →  20% 带宽
  Q2: weight 3  →  30% 带宽
  Q3: weight 4  →  40% 带宽

┌─────────────────────────────────────────────────────────────┐
│                    WFQ 调度                                  │
│                                                              │
│  时间片循环：                                                │
│  Q0: 1/10 → Q1: 1/5 → Q2: 3/10 → Q3: 2/5 → Q0: 1/10 ...   │
│                                                              │
│  保证每个流至少获得其权重比例的带宽                          │
└─────────────────────────────────────────────────────────────┘
```

```c
// WFQ 调度
struct wfq_sched {
    u32 quantum;           // 每轮发送的字节数
    u32 weight[8];        // 每个队列的权重
    u32 credit[8];         // 每个队列的信用
    u32 current;           // 当前服务的队列
};

// WFQ 轮转
static inline u32
sched_wfq(wfq_sched_t *s, qos_queue_t *queues, u32 n)
{
    for (int round = 0; round < n; round++) {
        u32 q = s->current;

        // 增加信用
        s->credit[q] += s->quantum * s->weight[q];

        if (queues[q].head != queues[q].tail) {
            // 有包要发送
            u32 bi = queues[q].buffers[queues[q].tail];
            u32 pkt_len = vlib_buffer_length_in_chain(vm, bi);

            if (s->credit[q] >= pkt_len) {
                // 信用足够，发送
                s->credit[q] -= pkt_len;
                qos_dequeue(&queues[q], &bi);

                // 移动到下一个队列
                s->current = (s->current + 1) % n;
                return bi;
            }
        }

        // 移动到下一个队列
        s->current = (s->current + 1) % n;
    }

    return ~0;  // 没有可服务的包
}
```

### 3.3 WRR (Weighted Round Robin)

```
WRR 调度：

按权重发送包数，不是按字节

权重配置（包数）：
  Q0: 10 包  →  10%
  Q1: 20 包  →  20%
  Q2: 30 包  →  30%
  Q3: 40 包  →  40%

┌─────────────────────────────────────────────────────────────┐
│                    WRR 调度                                  │
│                                                              │
│  每轮：                                                      │
│  Q0 发送 min(weight[0], 队列长度)                         │
│  Q1 发送 min(weight[1], 队列长度)                         │
│  Q2 发送 min(weight[2], 队列长度)                         │
│  Q3 发送 min(weight[3], 队列长度)                         │
└─────────────────────────────────────────────────────────────┘

优点：实现简单
缺点：不能保证精确的字节级公平
```

### 3.4 DRR (Deficit Round Robin)

```
DRR 调度：

WRR + deficit counter，解决包大小不一致问题

┌─────────────────────────────────────────────────────────────┐
│                    DRR 调度                                  │
│                                                              │
│  quantum = 每个队列每轮允许发送的字节数                      │
│  deficit = quantum + carry                                  │
│                                                              │
│  如果 deficit >= packet_size，发送                          │
│  否则 deficit += quantum，等待下一轮                        │
└─────────────────────────────────────────────────────────────┘
```

## 4. DSCP 映射

### 4.1 DSCP 值

```
DSCP (Differentiated Services Code Point)：

AF (Assured Forwarding):
  - AFxy: x=类别 (1-4), y=丢弃优先级 (1-3)
  - AF11 (001010) = 10
  - AF21 (010010) = 18
  - AF41 (100010) = 34

EF (Expedited Forwarding):
  - EF (101110) = 46

┌─────────────────────────────────────────────────────────────┐
│                    DSCP → 队列映射                           │
│                                                              │
│  DSCP 0 (BE)       → Queue 0 (最低)                        │
│  DSCP 10-18 (AF)  → Queue 1-3                              │
│  DSCP 46 (EF)      → Queue 7 (最高)                        │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 DSCP 配置

```bash
# 配置 DSCP 到队列映射
vpp# set qos dscp mapping 0 0   # BE → Q0
vpp# set qos dscp mapping 10 1  # AF11 → Q1
vpp# set qos dscp mapping 12 1  # AF12 → Q1
vpp# set qos dscp mapping 14 2  # AF13 → Q2
vpp# set qos dscp mapping 46 7  # EF → Q7

# 查看映射
vpp# show qos dscp
```

### 4.3 DSCP 重标记

```bash
# 在接口上重标记 DSCP
vpp# set interface qos dscp GigabitEthernet0/8/0 rewrite ef
```

## 5. QoS 队列配置

### 5.1 接口队列配置

```bash
# 配置接口队列数
vpp# set interface queue GigabitEthernet0/8/0 rx-queue 4
vpp# set interface queue GigabitEthernet0/8/0 tx-queue 8

# 配置每个队列
vpp# set interface tx-queue GigabitEthernet0/8/0 queue 0 \
    size 1024 \
    weight 1 \
    algorithm sp

# 配置 WFQ
vpp# set interface tx-queue GigabitEthernet0/8/0 queue 0 \
    size 1024 \
    weight 10 \
    algorithm wfq

# 查看队列
vpp# show interface queue GigabitEthernet0/8/0
```

### 5.2 QoS 全局配置

```bash
# 创建 QoS 配置文件
vpp# qos profile create profile1

# 配置调度器
vpp# qos profile profile1 scheduler wrr \
    queue 0 weight 1 \
    queue 1 weight 2 \
    queue 2 weight 3 \
    queue 3 weight 4

# 应用到接口
vpp# set interface qos profile GigabitEthernet0/8/0 output profile1
```

## 6. WRED (Weighted Random Early Detection)

### 6.1 RED 原理

```
RED (Random Early Detection)：

当队列平均长度超过阈值时，随机丢弃包

- min_threshold: 开始丢弃
- max_threshold: 强制丢弃
- max_p: 最大丢弃概率

┌─────────────────────────────────────────────────────────────┐
│                    WRED 丢弃曲线                            │
│                                                              │
│  丢弃率                                                     │
│    100%├────────────────────────────────                    │
│        │                       ████                         │
│     P% ├────────────────────────████                        │
│        │                   ████                             │
│        │               ████                                 │
│        │           ████                                     │
│          min        avg        max                         │
│       threshold   threshold   threshold                    │
└─────────────────────────────────────────────────────────────┘
```

### 6.2 WRED 实现

```c
// WRED 状态
struct wred {
    // 阈值（字节）
    u32 min_threshold;
    u32 max_threshold;
    u32 max_p;             // 最大丢弃概率 (0-100)

    // 队列参数
    u32 weight;            // 队列长度 EWMA 权重

    // 状态
    u32 avg_queue_len;     // 平均队列长度
    u32 count;             // 包计数
};

// WRED 处理
static inline int
wred_drop(struct wred *w, u32 queue_len)
{
    // 计算平均队列长度 (EWMA)
    w->avg_queue_len =
        (w->avg_queue_len * (100 - w->weight) +
         queue_len * w->weight) / 100;

    if (w->avg_queue_len < w->min_threshold) {
        // 不丢弃
        return 0;
    }

    if (w->avg_queue_len >= w->max_threshold) {
        // 强制丢弃
        w->count = 0;
        return 1;
    }

    // 计算丢弃概率
    u32 p = w->max_p *
            (w->avg_queue_len - w->min_threshold) /
            (w->max_threshold - w->min_threshold);

    if (++w->count * p >= 100) {
        w->count = 0;
        return 1;
    }

    return 0;
}
```

### 6.3 DSCP 感知的 WRED

```c
// 每 DSCP 值的 WRED 配置
struct wred_dscp {
    u32 dscp;
    u32 min_threshold;
    u32 max_threshold;
    u32 max_p;
};

// 根据 DSCP 选择 WRED
static inline struct wred *
wred_for_dscp(struct wred_dscp *wreds, u8 dscp)
{
    for (int i = 0; i < vec_len(wreds); i++) {
        if (wreds[i].dscp == dscp) {
            return &wreds[i].state;
        }
    }
    return NULL;  // 默认
}
```

## 7. QoS 配置示例

### 7.1 VoIP + Web + Background

```
场景：
  - VoIP (EF): 优先转发，延迟 < 5ms
  - Web (AF21): 保证带宽
  - Background (BE): 尽力而为

配置：
  Queue 7: VoIP (EF) - SP, 无限带宽
  Queue 4: Web (AF21) - WFQ, weight 30
  Queue 0: Background (BE) - WFQ, weight 10
```

```bash
# 配置
vpp# set qos dscp mapping 46 7    # EF → Q7
vpp# set qos dscp mapping 18 4    # AF21 → Q4
vpp# set qos dscp mapping 0 0     # BE → Q0

# 设置 Q7 为 SP
vpp# set interface tx-queue GigabitEthernet0/8/0 queue 7 algorithm sp

# 设置 Q4, Q0 为 WFQ
vpp# set interface tx-queue GigabitEthernet0/8/0 queue 4 weight 30
vpp# set interface tx-queue GigabitEthernet0/8/0 queue 0 weight 10
```

## 8. 总结

调度算法对比：

| 算法 | 优点 | 缺点 | 适用场景 |
|------|------|------|----------|
| **SP** | 低延迟保证 | 可能饿死低优先级 | 实时业务 |
| **WFQ** | 公平带宽分配 | 实现复杂 | 多媒体 |
| **WRR** | 实现简单 | 不保证字节公平 | 负载均衡 |
| **DRR** | 字节级公平 | 仍有不公平 | 混合流量 |

QoS 最佳实践：

```
1. 分类：使用 DSCP/CoS 标记
2. 标记：在网络边界标记，内部信任
3. 限速：入口 Policer 控制
4. 调度：出口按优先级调度
5. 整形：出口限速平滑流量
```

---

## 参考资源

- [RFC 2474 - DSCP](https://tools.ietf.org/html/rfc2474)
- [RFC 2597 - AF PHB](https://tools.ietf.org/html/rfc2597)
- [RFC 3246 - EF PHB](https://tools.ietf.org/html/rfc3246)
- [VPP QoS](https://wiki.fd.io/view/VPP/QoS)
