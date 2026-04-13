---
title: "VPP 深入探讨 ch12：Policer 流量限制"
date: 2026-04-10 00:00:00
tags: [vpp, policer, rate-limiting, traffic-police, single-rate, dual-rate, meter]
description: "深入解析 VPP Policer：单速率三色、双速率三色、RFC 2697/2698 实现、swp3/rate-limit 与流量控制"
---

# VPP 深入探讨 ch12：Policer 流量限制

> [!abstract] 核心要点
> Policer 是流量速率控制的核心组件。本章深入解析单速率三色（RFC 2697）、双速率三色（RFC 2698）、令牌桶算法与 VPP Policer 实现。

## 1. Policer 概述

### 1.1 为什么需要 Policer

```
Policer vs Shaper：

Policer (流量限制器)：
  - 丢弃超过速率的包
  - 低延迟
  - 可能造成突发损失
  - 用于接入控制

Shaper (流量整形器)：
  - 缓冲超过速率的包，稍后发送
  - 延迟增加
  - 平滑流量
  - 用于出口整形
```

### 1.2 颜色模式

```
┌─────────────────────────────────────────────────────────────┐
│                    三色标记 (Three Color Marker)            │
│                                                              │
│  Green (绿色)：                                             │
│  - 包符合承诺速率 (CIR)                                     │
│  - 正常转发                                                 │
│                                                              │
│  Yellow (黄色)：                                            │
│  - 包超过承诺但符合峰值 (PIR)                               │
│  - 降级转发 (如降低优先级)                                  │
│                                                              │
│  Red (红色)：                                               │
│  - 包超过峰值速率                                          │
│  - 丢弃                                                   │
└─────────────────────────────────────────────────────────────┘
```

## 2. 单速率三色 (RFC 2697)

### 2.1 算法原理

```
单速率三色使用两个桶：
- C 桶 (Committed): 大小 CBS
- E 桶 (Excess):   大小 EBS

┌─────────────────────────────────────────────────────────────┐
│                    单速率三色算法                           │
│                                                              │
│  桶状态：                                                   │
│  C: committed tokens                                        │
│  E: excess tokens                                           │
│                                                              │
│  包到达 (大小 B)：                                           │
│                                                              │
│  if (B <= C) {                                             │
│      C -= B;                                                │
│      return GREEN;                                         │
│  }                                                          │
│  else if (B <= C + E) {                                   │
│      E -= B;                                               │
│      return YELLOW;                                        │
│  }                                                          │
│  else {                                                    │
│      return RED;                                           │
│  }                                                          │
│                                                              │
│  桶补充 (每时间单位)：                                       │
│    C = min(CBS, C + CIR * dt)                              │
│    E = min(EBS, E + CIR * dt)                              │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 实现代码

```c
// 单速率三色 Policer
struct policer_single_rate {
    // 配置
    u64 cir;           // 承诺信息速率 (bytes/s)
    u64 cbs;           // 承诺突发大小 (bytes)
    u64 ebs;           // 超额突发大小 (bytes)

    // 状态
    u64 C;             // C 桶当前值
    u64 E;             // E 桶当前值
    u64 last_time;     // 上次更新时间
};

// 单速率三色处理
static inline enum policer_color
policer_single_rate(struct policer_single_rate *p, u64 B)
{
    u64 now = clib_cpu_time_now();
    f64 dt = (now - p->last_time) / 1e9;

    // 补充令牌
    u64 C_add = (u64)(dt * p->cir);
    u64 E_add = (u64)(dt * p->cir);  // 和 CIR 一样补充到 E

    p->C = clib_min(p->cbs, p->C + C_add);
    p->E = clib_min(p->ebs, p->E + E_add);
    p->last_time = now;

    // 检查颜色
    if (B <= p->C) {
        // 绿色
        p->C -= B;
        return POLICER_COLOR_GREEN;
    }

    if (B <= p->C + p->E) {
        // 黄色
        p->E -= (B - p->C);
        p->C = 0;
        return POLICER_COLOR_YELLOW;
    }

    // 红色
    return POLICER_COLOR_RED;
}
```

## 3. 双速率三色 (RFC 2698)

### 3.1 算法原理

```
双速率三色使用两个桶：
- C 桶 (Committed): 大小 CBS，速率 CIR
- P 桶 (Peak):      大小 PBS，速率 PIR

┌─────────────────────────────────────────────────────────────┐
│                    双速率三色算法                           │
│                                                              │
│  桶状态：                                                   │
│  C: committed tokens                                        │
│  P: peak tokens                                             │
│                                                              │
│  包到达 (大小 B)：                                           │
│                                                              │
│  if (B > P) {                                               │
│      return RED;                                            │
│  }                                                          │
│                                                              │
│  if (B > C) {                                               │
│      if (B <= P) {                                         │
│          P -= B;                                           │
│          return YELLOW;                                    │
│      }                                                      │
│  }                                                          │
│                                                              │
│  C -= B;                                                    │
│  return GREEN;                                             │
│                                                              │
│  桶补充：                                                   │
│    C = min(CBS, C + CIR * dt)                              │
│    P = min(PBS, P + PIR * dt)                              │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 实现代码

```c
// 双速率三色 Policer
struct policer_dual_rate {
    // 配置
    u64 cir;           // 承诺信息速率 (bytes/s)
    u64 pir;           // 峰值信息速率 (bytes/s)
    u64 cbs;           // 承诺突发大小 (bytes)
    u64 pbs;           // 峰值突发大小 (bytes)

    // 状态
    u64 C;             // C 桶
    u64 P;             // P 桶
    u64 last_time;
};

// 双速率三色处理
static inline enum policer_color
policer_dual_rate(struct policer_dual_rate *p, u64 B)
{
    u64 now = clib_cpu_time_now();
    f64 dt = (now - p->last_time) / 1e9;

    // 补充令牌
    p->C = clib_min(p->cbs, p->C + (u64)(dt * p->cir));
    p->P = clib_min(p->pbs, p->P + (u64)(dt * p->pir));
    p->last_time = now;

    // 检查
    if (B > p->P) {
        // 红色
        return POLICER_COLOR_RED;
    }

    if (B > p->C) {
        // 黄色
        p->P -= B;
        return POLICER_COLOR_YELLOW;
    }

    // 绿色
    p->C -= B;
    return POLICER_COLOR_GREEN;
}
```

## 4. Policer 配置

### 4.1 CLI 配置

```bash
# 创建单速率三色 Policer
vpp# policer add single-rate name p1 \
    cir 1000000 \        # 1 Gbps
    cbs 1000000 \        # 1 MB committed burst
    ebs 1000000 \        # 1 MB excess burst
    conform-action transmit \
    exceed-action set-dscp af11 \
    violate-action drop

# 创建双速率三色 Policer
vpp# policer add dual-rate name p2 \
    cir 500000000 \      # 500 Mbps
    pir 1000000000 \     # 1 Gbps peak
    cbs 500000 \         # 500 KB committed
    pbs 1000000 \        # 1 MB peak
    conform-action transmit \
    exceed-action set-dscp af12 \
    violate-action drop

# 应用到接口
vpp# set interface input policer GigabitEthernet0/8/0 p1
```

### 4.2 Policer 参数计算

```
带宽和突发大小计算：

CIR (bytes/s) = bps / 8

例如：1 Gbps
  CIR = 1,000,000,000 / 8 = 125,000,000 bytes/s

突发大小建议：
  CBS = CIR * 1.5ms ~ 5ms
  EBS = CBS (单速率) 或 PBS = PIR * 1.5ms ~ 5ms (双速率)

例如：1 Gbps, 1ms 突发
  CBS = 125,000,000 * 0.001 = 125,000 bytes = 125 KB
```

## 5. Policer Action

### 5.1 Action 类型

```c
// Policer Action
enum policer_action_type {
    POLICER_ACTION_TRANSMIT,       // 发送
    POLICER_ACTION_DROP,            // 丢弃
    POLICER_ACTION_SET_DSCP,        // 设置 DSCP
    POLICER_ACTION_SET_PCP,         // 设置 VLAN PCP
    POLICER_ACTION_MARK,            // 标记颜色
    POLICER_ACTION_REMARK,          // 重标记
};

// Action 配置
typedef struct {
    enum policer_action_type type;
    union {
        u8 dscp;           // SET_DSCP
        u8 pcp;            // SET_PCP
        u8 color;          // MARK
    } data;
} policer_action_t;
```

### 5.2 Action 处理

```c
// 应用 Policer Action
static inline void
policer_apply_action(vlib_buffer_t *b,
                     enum policer_color color,
                     policer_action_t *actions)
{
    switch (color) {
    case POLICER_COLOR_GREEN:
        if (actions[POLICER_COLOR_GREEN].type == POLICER_ACTION_TRANSMIT)
            return;  // 正常发送
        break;

    case POLICER_COLOR_YELLOW:
        if (actions[POLICER_COLOR_YELLOW].type == POLICER_ACTION_SET_DSCP) {
            ip4_header_t *ip = get_ip_header(b);
            ip->tos = actions[POLICER_COLOR_YELLOW].data.dscp << 2;
            // 重新计算 checksum
        }
        break;

    case POLICER_COLOR_RED:
        if (actions[POLICER_COLOR_RED].type == POLICER_ACTION_DROP) {
            vlib_buffer_free(vm, &bi, 1);
        }
        break;
    }
}
```

## 6. Policer Node

### 6.1 Policer Node 实现

```c
// Policer Node
VLIB_NODE_FN(policer_node)
{
    u32 *from = vlib_frame_vector_args(frame);
    u32 n_packets = frame->n_vectors;

    for (u32 i = 0; i < n_packets; i++) {
        vlib_buffer_t *b = vlib_get_buffer(vm, from[i]);

        // 获取包大小
        u64 B = vlib_buffer_length_in_chain(vm, b);

        //Policer 处理
        enum policer_color color = policer_lookup(policer, B);

        // 应用 action
        policer_apply_action(b, color, policer->actions);

        if (color == POLICER_COLOR_GREEN) {
            vlib_put_next_frame(vm, node, POLICER_NEXT_PERMIT, 1);
        } else if (color == POLICER_COLOR_YELLOW) {
            vlib_put_next_frame(vm, node, POLICER_NEXT_PERMIT, 1);
        } else {
            vlib_put_next_frame(vm, node, POLICER_NEXT_DROP, 1);
        }
    }

    return n_packets;
}

// Policer 查找
static inline enum policer_color
policer_lookup(struct policer *p, u64 B)
{
    if (p->type == POLICER_TYPE_SINGLE_RATE) {
        return policer_single_rate(&p->single, B);
    } else {
        return policer_dual_rate(&p->dual, B);
    }
}
```

## 7. swp3 (Aggregate) Policer

### 7.1 swp3 概念

```
Aggregate (swp3) Policer：
- 多个流共享一个 policer
- 总速率受限
- 用于流量聚合控制

例如：
  - 10 个用户共享 1 Gbps
  - 每个用户最大 100 Mbps
  - 聚合最大 1 Gbps
```

### 7.2 swp3 配置

```bash
# 创建 swp3 policer
vpp# policer add swp3 name agg1 \
    rate 1000000000 \      # 1 Gbps
    burst 125000           # 125 KB

# 将多个流绑定到同一个 swp3
vpp# set interface input policer GigabitEthernet0/8/0.1 agg1
vpp# set interface input policer GigabitEthernet0/8/0.2 agg1
vpp# set interface input policer GigabitEthernet0/8/0.3 agg1
```

## 8. 性能优化

### 8.1 批量处理

```c
// 批量 Policer 处理
static inline void
policer_batch(struct policer *p,
               u32 *buffers, u32 n,
               enum policer_color *results)
{
    for (u32 i = 0; i < n; i++) {
        vlib_buffer_t *b = vlib_get_buffer(vm, buffers[i]);
        u64 B = vlib_buffer_length_in_chain(vm, b);
        results[i] = policer_lookup(p, B);
    }
}
```

### 8.2 时间优化

```c
// 使用 ticks 代替真实时间
static inline u64
policer_time_update(struct policer *p)
{
    // VPP 提供高精度时间
    u64 now = clib_cpu_time_now();
    f64 dt = (now - p->last_time) / p->ticks_per_second;
    return (u64)(dt * p->cir);
}
```

## 9. 总结

Policer 类型对比：

| 类型 | RFC | 桶 | 用途 |
|------|-----|-----|------|
| **单速率三色** | 2697 | C + E | 单速率限制 |
| **双速率三色** | 2698 | C + P | 峰值+承诺 |
| **swp3** | N/A | 聚合 | 流量聚合 |

三色动作建议：

| 颜色 | 建议动作 |
|------|----------|
| **Green** | 正常转发 |
| **Yellow** | 降级 DSCP/PHP |
| **Red** | 丢弃 |

Policer vs Shaper：

```
Policer:  超过速率 → 丢弃
Shaper:   超过速率 → 缓冲等待
```

---

## 参考资源

- [RFC 2697 - srTCM](https://tools.ietf.org/html/rfc2697)
- [RFC 2698 - trTCM](https://tools.ietf.org/html/rfc2698)
- [VPP Policer](https://wiki.fd.io/view/VPP/Policer)
