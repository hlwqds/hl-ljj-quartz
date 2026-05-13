---
title: "VPP 深入探讨 ch14：流量整形 Shaper"
date: 2026-04-10 01:00:00
tags: [shaper, traffic-shaping, token-bucket, gce, pce, dual-token-bucket]
description: "深入解析 VPP 流量整形：令牌桶、单速率双速率整形、GCE/PCE 实现、接口整形与突发流量管理"
---

# VPP 深入探讨 ch14：流量整形 Shaper

> [!abstract] 核心要点
> Shaper 通过缓冲和延迟发送来平滑流量。本章深入解析令牌桶算法、单速率/双速率整形、GCE (Generic Cell Algorithm)、接口整形与突发流量管理。

## 1. Shaper vs Policer

```
┌─────────────────────────────────────────────────────────────┐
│                    Shaper vs Policer                       │
│                                                              │
│  Policer:                                                   │
│  - 超过速率 → 直接丢弃                                      │
│  - 低延迟                                                    │
│  - 突发损失                                                  │
│  - 用于接入控制                                              │
│                                                              │
│  Shaper:                                                    │
│  - 超过速率 → 缓冲，稍后发送                                │
│  - 延迟增加                                                  │
│  - 平滑输出                                                  │
│  - 用于出口整形                                              │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Policer 输出:  ████████▓▓▓▓░░░░░                     │  │
│  │  Shaper 输出:   ████████████████                      │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

## 2. 令牌桶算法

### 2.1 单令牌桶

```
令牌桶原理：

桶容量 = BTS (Burst Size)
令牌填充速率 = CIR (Committed Information Rate)

┌─────────────────────────────────────────────────────────────┐
│                    单令牌桶 Shaper                          │
│                                                              │
│    ┌─────────────┐                                         │
│    │  Token      │ ← 持续以 CIR 速率添加                   │
│    │  Bucket     │                                         │
│    │             │                                         │
│    │  ┌───┐      │                                         │
│    │  │   │ B    │  ← 包到达，需要 B tokens                │
│    └─────────────┘                                         │
│                                                              │
│  包发送条件：tokens >= packet_size                          │
│                                                              │
│  如果 tokens < packet_size：                                │
│    - 等待 tokens 累积足够                                   │
│    - 或丢弃（取决于配置）                                    │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 实现

```c
// 单速率令牌桶 Shaper
struct shaper_single_rate {
    u64 cir;               // 承诺信息速率 (bytes/s)
    u64 cbs;               // 承诺突发大小 (bytes)

    u64 tokens;            // 当前令牌数
    u64 last_time;         // 上次更新时间
};

// 更新令牌
static inline void
shaper_single_update(struct shaper_single_rate *s)
{
    u64 now = clib_time_now();
    f64 dt = (now - s->last_time);  // 秒

    // 添加令牌
    u64 tokens_add = (u64)(s->cir * dt);
    s->tokens = clib_min(s->cbs, s->tokens + tokens_add);
    s->last_time = now;
}

// 尝试发送
static inline int
shaper_single_can_send(struct shaper_single_rate *s, u64 bytes)
{
    shaper_single_update(s);

    if (s->tokens >= bytes) {
        s->tokens -= bytes;
        return 1;  // 可以发送
    }
    return 0;  // 等待
}
```

## 3. 双令牌桶 (Dual Token Bucket)

### 3.1 算法

```
双令牌桶（用于 ATM 和 DiffServ）：

┌─────────────────────────────────────────────────────────────┐
│                    双令牌桶 Shaper                          │
│                                                              │
│  ┌─────────────┐     ┌─────────────┐                       │
│  │  CBS Bucket │     │  PBS Bucket │                       │
│  │  (承诺)     │     │  (峰值)     │                       │
│  │             │     │             │                       │
│  │  CIR tokens │     │  PIR tokens │                       │
│  └─────────────┘     └─────────────┘                       │
│         ↓                   ↓                              │
│      承诺速率             峰值速率                         │
│      (CIR)               (PIR)                           │
│                                                              │
│  规则：                                                      │
│  1. 同时满足 CBS 和 PBS → 绿色，发送                        │
│  2. 只满足 CBS → 黄色，丢弃或标记                          │
│  3. 都不满足 → 红色，丢弃                                  │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 实现

```c
// 双令牌桶 Shaper
struct shaper_dual_rate {
    u64 cir;               // 承诺信息速率 (bytes/s)
    u64 pir;               // 峰值信息速率 (bytes/s)
    u64 cbs;               // 承诺突发大小 (bytes)
    u64 pbs;               // 峰值突发大小 (bytes)

    u64 c_tokens;          // CBS 令牌
    u64 p_tokens;         // PBS 令牌
    u64 last_time;
};

// 双令牌桶处理
static inline enum shaper_color
shaper_dual_rate_check(struct shaper_dual_rate *s, u64 bytes)
{
    u64 now = clib_time_now();
    f64 dt = (now - s->last_time);

    // 补充令牌
    s->c_tokens = clib_min(s->cbs,
                           s->c_tokens + (u64)(s->cir * dt));
    s->p_tokens = clib_min(s->pbs,
                           s->p_tokens + (u64)(s->pir * dt));
    s->last_time = now;

    // 检查
    if (bytes <= s->c_tokens && bytes <= s->p_tokens) {
        // 绿色
        s->c_tokens -= bytes;
        s->p_tokens -= bytes;
        return SHAPER_GREEN;
    }

    if (bytes <= s->p_tokens) {
        // 黄色
        s->p_tokens -= bytes;
        return SHAPER_YELLOW;
    }

    // 红色
    return SHAPER_RED;
}
```

## 4. GCE (Generic Cell Algorithm)

### 4.1 ATM GCE

```
GCE 用于 ATM 网络，将变长包分割成 48 字节 cells：

┌─────────────────────────────────────────────────────────────┐
│                    ATM Cell (53 bytes)                      │
│                                                              │
│  Header (5 bytes):                                          │
│  ┌─────────┬─────────┬─────────┬─────────┬─────────┐       │
│  │ VPI/VCI │  PT    │  CLP   │  HEC   │               │       │
│  └─────────┴─────────┴─────────┴─────────┴─────────┘       │
│                                                              │
│  Payload (48 bytes):                                        │
│  ┌───────────────────────────────────────────────────────┐  │
│  │                                                       │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘

GCE 整形：确保所有 VCs 公平共享链路带宽
```

### 4.2 GCE 实现

```c
// GCE 调度器
struct gce_scheduler {
    u32 num_vcs;           // VC 数量
    u64 link_rate;         // 链路速率 (cells/s)
    u64 cell_time;         // 发送一个 cell 的时间 (ns)

    // 每个 VC 的状态
    struct vc_state {
        u64 credit;        // 当前信用
        u64 last_time;     // 上次服务时间
        int active;         // 是否有数据
    } *vc_states;
};

// GCE 调度
static inline u32
gce_schedule(struct gce_scheduler *g)
{
    u64 now = clib_time_now();
    u32 selected_vc = ~0;

    // 找到信用最高的 VC
    u64 max_credit = 0;

    for (u32 i = 0; i < g->num_vcs; i++) {
        struct vc_state *vc = &g->vc_states[i];

        // 更新信用
        if (vc->active) {
            u64 elapsed = now - vc->last_time;
            vc->credit += elapsed * vc->rate / 1e9;
            vc->last_time = now;
        }

        if (vc->active && vc->credit >= g->cell_time) {
            if (vc->credit > max_credit) {
                max_credit = vc->credit;
                selected_vc = i;
            }
        }
    }

    // 发送一个 cell
    if (selected_vc != ~0) {
        g->vc_states[selected_vc].credit -= g->cell_time;
    }

    return selected_vc;
}
```

## 5. 接口整形

### 5.1 接口 Shaper

```c
// 接口级别的 Shaper
struct interface_shaper {
    u64 rate;               // 整形速率 (bps)
    u64 burst;             // 突发大小 (bytes)

    u64 tokens;
    u64 last_time;

    // 实际使用的调度器
    struct shaper_single_rate shaper;
};

// 接口整形处理
static inline int
interface_can_send(struct interface_shaper *s, u64 bytes)
{
    // 更新令牌
    u64 now = clib_time_now();
    f64 dt = (now - s->last_time);
    u64 tokens_add = (u64)(s->rate * dt / 8);  // bytes

    s->tokens = clib_min(s->burst, s->tokens + tokens_add);
    s->last_time = now;

    if (s->tokens >= bytes) {
        s->tokens -= bytes;
        return 1;
    }
    return 0;
}
```

### 5.2 配置

```bash
# 配置接口整形
vpp# set interface rate GigabitEthernet0/8/0 \
    rate 1000000000 \      # 1 Gbps
    burst 125000           # 1 ms burst (125 KB)

# 查看接口整形
vpp# show interface rate GigabitEthernet0/8/0
```

## 6. 层次化整形

### 6.1 HTB (Hierarchical Token Bucket)

```
HTB 允许层次化的流量整形：

┌─────────────────────────────────────────────────────────────┐
│                    HTB 层次结构                             │
│                                                              │
│                    Root (1 Gbps)                           │
│                    /    |    \                              │
│                   /     |     \                             │
│          Class A   Class B   Class C                        │
│          (400M)   (300M)   (300M)                         │
│           / \        |        |                             │
│          /   \       |        |                             │
│       Flow1 Flow2  Flow3    Flow4                           │
│       (200M) (200M) (300M)   (300M)                        │
└─────────────────────────────────────────────────────────────┘

特点：
- 父类可以借带宽给子类
- 保证每个子类的最小带宽
- 限制每个子类的最大带宽
```

### 6.2 HTB 实现

```c
// HTB 类
struct htb_class {
    u32 class_id;
    u32 parent_id;          // 父类

    // 速率
    u64 rate;               // 承诺速率 (ceil)
    u64 ceil;               // 最大速率
    u64 quantum;            // 调度量

    // 令牌桶
    u64 tokens;
    u64 buffer;             // 缓冲区大小
    u64 last_time;

    // 统计
    u64 packets_sent;
    u64 bytes_sent;

    // 子类
    u32 *children;
};

// HTB 调度
static inline u32
htb_schedule(struct htb_class *root, u64 now)
{
    // 1. 更新所有令牌桶
    htb_update_all(root, now);

    // 2. 从根开始调度
    return htb_schedule_class(root);
}

static inline u32
htb_schedule_class(struct htb_class *c)
{
    // 检查是否有子类需要服务
    for (int i = 0; i < vec_len(c->children); i++) {
        struct htb_class *child = &classes[c->children[i]];

        if (child->tokens > 0) {
            // 子类有信用，调度它
            if (vec_len(child->children) > 0) {
                return htb_schedule_class(child);
            } else {
                // 叶节点，发送包
                child->tokens -= child->quantum;
                return child->class_id;
            }
        }
    }

    // 没有子类需要服务
    return ~0;
}
```

### 6.3 HTB 配置

```bash
# 创建 HTB 根类
vpp# qos shaper create root rate 1000000000

# 添加子类
vpp# qos shaper add-class root class 1 rate 400000000
vpp# qos shaper add-class root class 2 rate 300000000
vpp# qos shaper add-class root class 3 rate 300000000

# 添加叶子类
vpp# qos shaper add-class 1 class 11 rate 200000000
vpp# qos shaper add-class 1 class 12 rate 200000000

# 绑定到接口
vpp# set interface shaper GigabitEthernet0/8/0 root
```

## 7. 突发流量管理

### 7.1 突发允许

```
突发流量原因：
- TCP 突发
- 包队列突发
- 微流突发

突发参数设置：

Burst (bytes) = Rate (bytes/s) × Time (s)

1 ms burst @ 1 Gbps = 125,000 bytes
10 ms burst @ 1 Gbps = 1,250,000 bytes

建议：
- CBS = Rate × 1-5 ms
- PBS = Rate × 5-10 ms
```

### 7.2 突发吸收

```
突发处理策略：

1. 完全吸收：
   - 突发 < buffer → 完全吸收
   - 无丢包

2. 部分吸收：
   - 突发 > buffer → 部分通过
   - 超出部分限速

3. 完全丢弃：
   - 突发 > buffer → 全部丢弃
   - 用于流量限制

┌─────────────────────────────────────────────────────────────┐
│                    突发吸收示意                             │
│                                                              │
│  Buffer                                                      │
│  ████████████                                                │
│  ████████████                                                │
│  ████████████                                                │
│  ████████████                                                │
│  ████████████                                                │
│  ████████████ 突发                                           │
│  ████████████ ████████                                       │
│  ████████████ ████████████████                               │
│  ████████████ ████████████████████████████                   │
│  ───────────────────────────────────────────────────────    │
│              Time                                            │
└─────────────────────────────────────────────────────────────┘
```

## 8. 总结

Shaper 类型对比：

| 类型       | 令牌桶 | 用途       |
| ---------- | ------ | ---------- |
| **单速率** | 1      | 简单限速   |
| **双速率** | 2      | PIR + CIR  |
| **HTB**    | 层次   | 层次化 QoS |
| **GCE**    | 信用   | ATM        |

令牌桶参数计算：

```
CIR (bytes/s) = bps / 8
CBS (bytes) = CIR × burst_time
PIR (bytes/s) = peak_bps / 8
PBS (bytes) = PIR × burst_time
```

Shaper vs Policer：

```
Policer:  速率 > CIR → 丢弃 → 延迟不变
Shaper:   速率 > CIR → 缓冲 → 延迟增加，但平滑
```

---

## 参考资源

- [RFC 1990 - PFIFO](https://tools.ietf.org/html/rfc1990)
- [HTB Linux](https://docs.kernel.org/en/latest/networking/sch_htb.html)
- [VPP QoS Shaper](https://wiki.fd.io/view/VPP/QoS_Shaper)
