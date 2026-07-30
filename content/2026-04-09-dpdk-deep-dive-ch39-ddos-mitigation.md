---
title: "DPDK 深度探索 ch39b：DDoS 防护数据面——从 rte_meter 到 SYN Proxy"
date: 2026-04-10 15:00:00
tags:
  [
    dpdk,
    ddos,
    syn-cookie,
    syn-proxy,
    rate-limit,
    rte-meter,
    srtcm,
    trtcm,
    bloom-filter,
    flowspec,
    xdp,
    policing,
  ]
description: "从 DPDK 工程视角解析 DDoS 防护数据面：rte_meter srTCM/trTCM 流量监管、Token Bucket、SYN Proxy 三次握手代理、Per-IP 限速、Bloom Filter 黑名单、rte_flow 硬件卸载与 XDP 前置过滤"
---

# DPDK 深度探索 ch39b：DDoS 防护数据面——从 rte_meter 到 SYN Proxy

> [!info] 章节定位
> 系列中已有 [[2026-04-09-dpdk-deep-dive-ch39-container-networking|第三十九章：容器网络与 DPDK]]，
> 因此本文按 **ch39b 专题章**处理。
>
> 关联章节：
>
> - [[2026-04-09-dpdk-deep-dive-ch38-firewall-dpdk|防火墙数据面——ACL、Conntrack、NAT 与硬件卸载]]
> - [[2026-04-09-dpdk-deep-dive-ch38-dpdk-ebpf|eBPF/XDP 与 DPDK 协同——AF_XDP PMD]]
> - [[2026-04-09-dpdk-deep-dive-ch30-lookaside-crypto|Lookaside 加速——Cryptodev、QAT、IPsec]]
> - [[2026-04-09-dpdk-deep-dive-ch37-smartnic|SmartNIC 数据面——Representor、E-Switch 与硬件卸载]]

> [!abstract] 核心结论
> DDoS 防护数据面的核心工作只有两种：**识别攻击流量** 和 **丢弃攻击流量**。
> DPDK 的价值在于：
>
> 1. **rte_meter**（srTCM/trTCM）提供了 RFC 2697/2698 标准的三色标记流量监管，
>    比手写 Token Bucket 更正确、更高效；
> 2. **SYN Proxy** 在 DPDK 中代理 TCP 三次握手，只有完成 Cookie 验证并通过后续策略的连接才转发到后端；
>    Cookie 验证证明的是源地址可达性，不等于证明对端不是攻击者；
> 3. **Per-IP 限速** 用 `rte_hash` + per-entry token bucket 支撑百万级源 IP 的独立限速；
> 4. **Bloom Filter** 用 O(1) 概率查找做 IP 黑名单，内存占用远低于 hash 表；
> 5. **rte_flow** 把 DROP 规则卸载到 NIC 硬件，攻击流量在网卡层就被丢弃，CPU 完全不参与；
> 6. **XDP 前置过滤** 在内核驱动层丢弃已知恶意流量，不到达 DPDK。

---

## 1. DDoS 攻击类型与 DPDK 防护策略

### 1.1 攻击分类

```text
体积攻击（Volumetric）：
═════════════════════════
  目标：填满链路带宽
  手段：UDP Flood、ICMP Flood、DNS/NTP/Memcached Amplification
  特征：大量包、大带宽、源 IP 可能伪造
  DPDK 对策：
    · rte_flow DROP（硬件丢弃）
    · Per-IP rate limiting（rte_meter + rte_hash）
    · Bloom filter 黑名单
    · XDP_DROP 前置过滤

协议攻击（Protocol）：
═════════════════════════
  目标：耗尽服务器连接资源
  手段：SYN Flood、Ping of Death、Smurf
  特征：包量不一定大，但每个包触发服务端状态分配
  DPDK 对策：
    · SYN Proxy（代理握手，验证后才转发）
    · SYN Cookie（无状态验证）
    · 连接数限制（per-IP）

应用层攻击（Application Layer）：
═════════════════════════
  目标：耗尽应用资源
  手段：HTTP Flood、Slowloris、DNS Query Flood
  特征：流量模式类似正常用户，难以用五元组区分
  DPDK 对策：
    · DPI 协议识别（nDPI）
    · 行为分析（EWMA 异常检测）
    · Challenge-Response（JS Challenge、CAPTCHA）
```

### 1.2 分层防护架构

```text
                      流量进入
                         │
                         ▼
              ┌─────────────────────┐
              │ Layer 0: NIC 硬件    │
              │ rte_flow DROP 规则   │  ← 已知恶意 IP 硬件丢弃
              │ rte_flow RSS 分流    │  ← 合法流量分配到多核
              └──────────┬──────────┘
                         │
                         ▼
              ┌─────────────────────┐
              │ Layer 1: XDP 过滤    │
              │ 内核驱动层 DROP      │  ← Bogon、已知攻击源
              └──────────┬──────────┘
                         │
                         ▼
              ┌─────────────────────┐
              │ Layer 2: DPDK 软件   │
              │ ACL 黑白名单         │  ← rte_acl 精确匹配
              │ Per-IP 限速         │  ← rte_hash + rte_meter
              │ Bloom filter 黑名单  │  ← O(1) 概率查找
              └──────────┬──────────┘
                         │
                         ▼
              ┌─────────────────────┐
              │ Layer 3: 协议防护    │
              │ SYN Proxy           │  ← 代理 TCP 握手
              │ 连接数限制           │  ← per-IP conn limit
              │ 异常检测            │  ← EWMA 基线偏差
              └──────────┬──────────┘
                         │
                         ▼
                    到达后端服务器
```

越早丢弃，CPU 和带宽节省越多。目标：**让 90%+ 的攻击流量在 Layer 0/1 就被丢弃。**

---

## 2. rte_meter：DPDK 内置的流量监管

### 2.1 三色标记模型

DPDK 的 `rte_meter` 库实现了 RFC 2697（srTCM）和 RFC 2698（trTCM）
两种三色标记：

```text
srTCM（Single Rate Three Color Marker）—— RFC 2697：
  参数：CIR（承诺速率）、CBS（承诺突发）、EBS（超额突发）
  · 绿色：在 CBS 内 → 正常转发
  · 黄色：超过 CBS 但在 EBS 内 → 可标记/降级
  · 红色：超过 EBS → 丢弃

trTCM（Two Rate Three Color Marker）—— RFC 2698：
  参数：CIR（承诺速率）、PIR（峰值速率）、CBS、PBS
  · 绿色：低于 CIR → 正常转发
  · 黄色：在 CIR 和 PIR 之间 → 可标记
  · 红色：超过 PIR → 丢弃
```

### 2.2 srTCM 配置与使用

```c
#include <rte_meter.h>

/*
 * srTCM 示例：
 * 限制每个源 IP 到 10 Mbps，允许 8KB 突发。
 *
 * CIR = 10 Mbps = 10,000,000 bits/s = 1,250,000 bytes/s
 * CBS = 8192 bytes
 * EBS = 8192 bytes
 */

/* 1. 定义 profile（多个 meter 共享同一 profile） */
struct rte_meter_srtcm_params srtcm_params = {
    .cir = 1250000,   /* 10 Mbps in bytes/s */
    .cbs = 8192,      /* Committed Burst Size */
    .ebs = 8192,      /* Excess Burst Size */
};

struct rte_meter_srtcm_profile srtcm_profile;
int ret = rte_meter_srtcm_profile_init(&srtcm_profile, &srtcm_params);
if (ret != 0)
    return -1;  /* 检查：参数是否合法 */

/* 2. 初始化 meter 实例（per-flow 或 per-IP） */
struct rte_meter_srtcm meter;
ret = rte_meter_srtcm_config(&meter, &srtcm_profile);
if (ret != 0)
    return -1;

/* 3. 对每个包执行 metering */
static inline enum rte_meter_color
meter_packet(struct rte_meter_srtcm *mtr,
             const struct rte_meter_srtcm_profile *prof,
             uint64_t time, uint32_t pkt_len)
{
    /*
     * color_blind_check: 不考虑包的先验颜色
     * color_aware_check: 考虑包已有的颜色（从上游 meter 继承）
     *
     * time: 当前时间，以 CPU cycles 为单位
     * pkt_len: 包长度（字节）
     *
     * 返回：RTE_METER_GREEN / RTE_METER_YELLOW / RTE_METER_RED
     */
    return rte_meter_srtcm_color_blind_check(mtr, prof, time, pkt_len);
}

/* 4. 根据颜色执行动作 */
static inline int
policer_action(enum rte_meter_color color, struct rte_mbuf *mbuf)
{
    switch (color) {
    case RTE_METER_GREEN:
        return 0;  /* 转发 */
    case RTE_METER_YELLOW:
        /* 可选：标记 DSCP、降低优先级、或直接转发 */
        return 0;
    case RTE_METER_RED:
        /* 丢弃 */
        rte_pktmbuf_free(mbuf);
        return -1;
    default:
        return -1;
    }
}
```

### 2.3 trTCM（双速率）

```c
/*
 * trTCM 示例：
 * CIR = 10 Mbps（承诺速率，绿色）
 * PIR = 50 Mbps（峰值速率，超过则红色）
 */
struct rte_meter_trtcm_params trtcm_params = {
    .cir = 1250000,    /* 10 Mbps */
    .pir = 6250000,    /* 50 Mbps */
    .cbs = 8192,
    .pbs = 32768,      /* 峰值突发更大 */
};

struct rte_meter_trtcm_profile trtcm_profile;
rte_meter_trtcm_profile_init(&trtcm_profile, &trtcm_params);

struct rte_meter_trtcm meter;
rte_meter_trtcm_config(&meter, &trtcm_profile);

/* 使用 */
enum rte_meter_color color =
    rte_meter_trtcm_color_blind_check(&meter, &trtcm_profile,
                                       rte_rdtsc(), pkt_len);
```

> [!info] rte_meter vs 手写 Token Bucket
> `rte_meter` 比手写 Token Bucket 的优势：
>
> - **RFC 标准合规**：srTCM 符合 RFC 2697，trTCM 符合 RFC 2698
> - **Profile 共享**：多个 meter 实例共享同一个 profile 配置，减少内存
> - **优化实现**：DPDK 内部针对 cache 友好性优化
> - **颜色传递**：支持 color-aware 模式，多级 policing 可以级联
> - **与 QoS 框架集成**：可以和 rte_sched / TM 配合使用

### 2.4 Per-IP 流量监管

将 rte_meter 和 rte_hash 结合，为每个源 IP 维护独立的 meter：

```c
/* Per-IP meter 条目 */
struct ip_meter_entry {
    struct rte_meter_srtcm meter;
    uint64_t last_seen;
    uint64_t pkts_green;
    uint64_t pkts_yellow;
    uint64_t pkts_red;
} __rte_cache_aligned;

struct ip_meter_table {
    struct rte_hash *hash;
    struct rte_mempool *entry_pool;
    const struct rte_meter_srtcm_profile *profile;
    uint32_t max_entries;
};

/* Per-IP metering */
static inline int
ip_meter_check(struct ip_meter_table *tbl,
               uint32_t src_ip, uint32_t pkt_len,
               struct rte_mbuf *mbuf)
{
    struct ip_meter_entry *entry;
    int ret = rte_hash_lookup_data(tbl->hash, &src_ip, (void **)&entry);

    if (ret < 0) {
        /* 新 IP：创建 meter 条目 */
        entry = rte_mempool_get(tbl->entry_pool, (void **)&entry);
        if (entry == NULL)
            return -1;  /* 池满，丢弃 */

        rte_meter_srtcm_config(&entry->meter, tbl->profile);
        memset(&entry->pkts_green, 0, sizeof(*entry) -
               offsetof(struct ip_meter_entry, pkts_green));

        rte_hash_add_key_data(tbl->hash, &src_ip, entry);
    }

    entry->last_seen = rte_rdtsc();

    enum rte_meter_color color =
        rte_meter_srtcm_color_blind_check(&entry->meter,
                                           tbl->profile,
                                           rte_rdtsc(), pkt_len);

    switch (color) {
    case RTE_METER_GREEN:
        entry->pkts_green++;
        return 0;   /* 放行 */
    case RTE_METER_YELLOW:
        entry->pkts_yellow++;
        return 0;   /* 可选：放行或标记 */
    case RTE_METER_RED:
        entry->pkts_red++;
        rte_pktmbuf_free(mbuf);
        return -1;  /* 丢弃 */
    }

    return -1;
}
```

---

## 3. Token Bucket：当 rte_meter 不够灵活时

### 3.1 Token Bucket 原理

```text
Token Bucket：

  Token 以固定速率 R 注入桶中
  桶容量上限为 B（允许突发 B 个包）
  每个包消耗 1 个 token
  桶空时拒绝

  ┌────────────────────────┐
  │  tokens: ████████      │◀─── 补充速率 R (tokens/sec)
  │  capacity: B           │────▶ 每包消耗 1 token
  │  桶满时停止注入         │     桶空时拒绝
  └────────────────────────┘

  vs rte_meter srTCM：
  Token Bucket = 单桶模型（只有一个桶）
  srTCM = 双桶模型（CBS 桶 + EBS 桶），可以区分黄/红
```

### 3.2 DPDK 中的高效实现

```c
/*
 * 基于 TSC 的高精度 Token Bucket。
 * 所有时间运算使用 rte_rdtsc()，避免系统调用。
 */
struct token_bucket {
    uint64_t tokens;          /* 当前 token 数 */
    uint64_t burst;           /* 桶容量（最大 token 数） */
    uint64_t rate;            /* 补充速率（tokens/sec） */
    uint64_t last_refill;     /* 上次补充时间（TSC） */
} __rte_cache_aligned;

static inline void
token_bucket_init(struct token_bucket *tb,
                  uint64_t rate, uint64_t burst)
{
    tb->tokens = burst;
    tb->burst = burst;
    tb->rate = rate;
    tb->last_refill = rte_rdtsc();
}

/*
 * 尝试消耗 n 个 token。
 * 返回 0 = 成功，-1 = 不足（不消耗）。
 */
static inline int
token_bucket_consume(struct token_bucket *tb, uint64_t n)
{
    uint64_t now = rte_rdtsc();
    uint64_t elapsed = now - tb->last_refill;
    uint64_t tsc_hz = rte_get_tsc_hz();

    /* 计算补充的 token 数 */
    uint64_t new_tokens = (elapsed * tb->rate) / tsc_hz;
    tb->tokens = RTE_MIN(tb->burst, tb->tokens + new_tokens);
    tb->last_refill = now;

    /* 检查并消耗 */
    if (tb->tokens >= n) {
        tb->tokens -= n;
        return 0;
    }
    return -1;  /* 不足 */
}
```

### 3.3 Per-IP Token Bucket 表

```c
#define MAX_RATE_LIMITED_IPS (1 << 20)  /* 1M IPs */

struct ip_rate_entry {
    struct token_bucket tb;
    uint64_t last_seen;
} __rte_cache_aligned;

struct ip_rate_table {
    struct rte_hash *hash;
    struct rte_mempool *entry_pool;
    uint64_t default_rate;     /* 默认速率 */
    uint64_t default_burst;    /* 默认突发 */
};

/* 检查 per-IP 限速 */
static inline int
ip_rate_check(struct ip_rate_table *tbl,
              uint32_t src_ip, struct rte_mbuf *mbuf)
{
    struct ip_rate_entry *entry;
    int ret = rte_hash_lookup_data(tbl->hash, &src_ip, (void **)&entry);

    if (ret < 0) {
        /* 新 IP：创建 entry */
        if (rte_mempool_get(tbl->entry_pool, (void **)&entry) != 0)
            return -1;  /* 池满 */

        token_bucket_init(&entry->tb, tbl->default_rate, tbl->default_burst);
        entry->last_seen = rte_rdtsc();

        if (rte_hash_add_key_data(tbl->hash, &src_ip, entry) != 0) {
            rte_mempool_put(tbl->entry_pool, entry);
            return -1;
        }
    }

    entry->last_seen = rte_rdtsc();

    /* 消耗 1 个 token */
    return token_bucket_consume(&entry->tb, 1);
}
```

---

## 4. Bloom Filter：O(1) 概率黑名单

### 4.1 为什么用 Bloom Filter

Per-IP rate limiting 用 `rte_hash` 可以精确查找，但当黑名单 IP 数量达到百万级时，
hash 表内存开销很大。Bloom Filter 用 **概率查找** 换取空间效率：

| 方案           | 查找复杂度 | 100 万 IP 内存 | 有误判吗 |
| -------------- | ---------- | -------------- | -------- |
| `rte_hash`     | O(1)       | ~100 MB        | 无       |
| Bloom Filter   | O(1)       | ~2 MB          | 有假阳性 |
| Counting Bloom | O(1)       | ~4 MB          | 有假阳性 |

Bloom Filter 的保证是单向的：

- 只要某一位为 `0`，该 IP **一定没有被加入这个 Bloom Filter**；
- 如果所有相关位都为 `1`，该 IP 只是**可能存在**，需要用 `rte_hash` 等精确结构二次验证。

第一条结论成立的前提是：查询和写入使用相同的位图、参数和哈希函数，位图没有损坏，
并且没有使用普通 Bloom Filter 不支持的删除操作。在并发更新场景中，还要保证新版本位图已经正确发布给查询核。

因此，“一定不在”只表示可以跳过**精确黑名单查询**，不能直接等价为“该包安全”或“无条件放行”；
后续的限速、SYN Proxy、异常检测等策略仍然需要执行。假阳性则意味着少量不在黑名单中的 IP
会进入精确查找，但不会在二级查询后被误封。

### 4.2 Bloom Filter 实现

```c
/*
 * 固定大小的 Bloom Filter，适用于 IP 黑名单。
 * 使用 rte_hash_crc 作为哈希函数。
 */
#define BLOOM_SIZE_BITS    (1 << 24)  /* 16M bits = 2MB */
#define BLOOM_NUM_HASHES   8
#define BLOOM_BITMAP_WORDS (BLOOM_SIZE_BITS / 32)

struct bloom_filter {
    uint32_t bitmap[BLOOM_BITMAP_WORDS];  /* 2MB 位图 */
    uint32_t count;                        /* 已添加元素数 */
} __rte_cache_aligned;

/* 添加 IP 到 Bloom Filter */
static inline void
bloom_add(struct bloom_filter *bf, uint32_t ip)
{
    for (uint32_t i = 0; i < BLOOM_NUM_HASHES; i++) {
        uint32_t hash = rte_hash_crc(&ip, sizeof(ip), i);
        uint32_t bit = hash % BLOOM_SIZE_BITS;
        uint32_t word = bit / 32;
        uint32_t offset = bit % 32;
        bf->bitmap[word] |= (1U << offset);
    }
    bf->count++;
}

/*
 * 检查 IP 是否可能在黑名单中。
 * 返回 0 = 一定不在，1 = 可能在（需要二次验证）。
 */
static inline int
bloom_may_contain(const struct bloom_filter *bf, uint32_t ip)
{
    for (uint32_t i = 0; i < BLOOM_NUM_HASHES; i++) {
        uint32_t hash = rte_hash_crc(&ip, sizeof(ip), i);
        uint32_t bit = hash % BLOOM_SIZE_BITS;
        uint32_t word = bit / 32;
        uint32_t offset = bit % 32;
        if (!(bf->bitmap[word] & (1U << offset)))
            return 0;  /* 一定不在 */
    }
    return 1;  /* 可能在 */
}
```

### 4.3 与精确查找配合

```text
两级查找架构：

  收到包 → Bloom Filter 查找
              │
              ├─ 一定不在 (返回 0) → 跳过精确黑名单查询
              │                         继续执行限速、SYN Proxy 等策略
              │
              └─ 可能在 (返回 1) → rte_hash 精确查找
                                      │
                                      ├─ 确实在黑名单 → 丢弃
                                      └─ 假阳性 → 继续执行后续策略
```

```c
/* 两级黑名单检查 */
static inline int
blacklist_check(const struct bloom_filter *bf,
                struct rte_hash *exact_hash,
                uint32_t src_ip)
{
    /* 第一级：Bloom Filter */
    if (!bloom_may_contain(bf, src_ip))
        return 0;  /* 一定不在黑名单，跳过精确查询 */

    /* 第二级：精确查找（处理假阳性） */
    return rte_hash_lookup(exact_hash, &src_ip) >= 0 ? 1 : 0;
}
```

Bloom Filter 能提升多少性能，不能用固定的“99.9%”描述。设：

- `h`：查询流量中，源 IP 确实在黑名单里的比例；
- `p`：Bloom Filter 对非黑名单 IP 的假阳性率。

那么进入二级精确查找的比例约为：

```text
P(exact lookup) = h + (1 - h) × p
```

被 Bloom Filter 省掉的精确查找比例约为：

```text
R(saved lookup) = (1 - h) × (1 - p)
```

例如 `h = 1%`、`p = 1%` 时，约 `1.99%` 的查询进入 `rte_hash`，
即省掉约 `98.01%` 的精确查找。但这不代表端到端吞吐一定提升 `98.01%`：
Bloom Filter 本身也要执行多次哈希和位图访问。只有当精确表较大、缓存未命中较多，
或二级查询位于共享内存、远端 KV/数据库时，预过滤收益才会明显；
如果 `rte_hash` 很小且常驻缓存，Bloom Filter 反而可能增加开销，应以目标流量分布做基准测试。

---

## 5. SYN Proxy：代理 TCP 三次握手

### 5.1 SYN Proxy 原理

SYN Proxy 是防御伪造源地址 SYN Flood 的有效手段。DPDK 作为代理，
**代替后端服务器完成三次握手**，只把完成握手并通过后续策略的连接转发给后端：

```text
没有 SYN Proxy（后端服务器承受 SYN Flood）：
  Attacker ──── SYN ────▶ Server（分配内存，half-open 队列耗尽）
  Attacker ──── SYN ────▶ Server（分配内存...）
  ...
  正常用户 ──── SYN ────▶ Server（队列满，拒绝服务）

有 SYN Proxy（DPDK 在前端代理握手）：
  伪造源 IP 的攻击者 ── SYN ──▶ DPDK SYN Proxy
                                DPDK 回 SYN-ACK（用 cookie，不分配内存）
                                攻击者收不到 SYN-ACK，无法构造正确 ACK
                                无有效 ACK → 不为半开连接分配状态

  正常用户 ──── SYN ────▶ DPDK SYN Proxy
                          DPDK 回 SYN-ACK（带 cookie）
                          正常用户 ── ACK ──▶ DPDK（验证 cookie）
                          验证通过 → 继续执行限速等策略 → 转发到后端

  使用真实可达 IP 的攻击者也能收到 SYN-ACK 并返回正确 ACK，
  因而可能通过 Cookie 验证；SYN Proxy 不能单独识别这类攻击者。
```

### 5.2 SYN Cookie 生成与验证

客户端返回第三次握手 ACK 时，`acknowledgment number - 1` 就是代理在 SYN-ACK 中发送的 ISN，
也就是 Cookie。代理用连接四元组、时间窗口和服务端密钥重新计算 Cookie；匹配说明发送方知道
代理返回的 ISN。对于无法收到 SYN-ACK 的离路径伪造源 IP 攻击者，这个值难以猜中。

但验证成功只证明：该 ACK 来自能够收到 SYN-ACK 的端点，或来自能观察该流量的路径参与者。
它不证明对端是正常用户，也不证明后续请求无害。

```c
#include <rte_hash_crc.h>
#include <rte_random.h>

/*
 * SYN Cookie 实现（参考 Linux kernel 方案）。
 *
 * Cookie 编码： MSS_index(3) | timestamp(5) | hash(24)
 * 总计 32 bits，放在 SYN-ACK 的 ISN（Initial Sequence Number）中。
 *
 * 优点：不需要为半开连接分配任何内存。
 * 缺点：丢失了 MSS 等协商选项（只能用默认值）。
 */

/* 秘钥：定期轮换 */
static uint32_t syncookie_secret[2];

/* 时间窗口：64 秒（cookie 在 64 秒内有效） */
#define SYNCOOKIE_TSC_SHIFT 26  /* 约 67 秒 @ 2GHz */

/* MSS 表（编码为 3-bit index） */
static const uint16_t mss_table[8] = {
    536, 1300, 1440, 1460, 576, 1220, 1400, 1480
};

/* 生成 SYN Cookie */
static inline uint32_t
generate_syn_cookie(uint32_t src_ip, uint16_t src_port,
                    uint32_t dst_ip, uint16_t dst_port,
                    uint32_t tcp_seq, uint16_t mss)
{
    /* 时间戳（低 5 bits，约 67 秒粒度） */
    uint32_t ts = (rte_rdtsc() >> SYNCOOKIE_TSC_SHIFT) & 0x1F;

    /* MSS index（3 bits） */
    uint32_t mss_idx = 0;
    for (uint32_t i = 0; i < 8; i++) {
        if (mss_table[i] <= mss)
            mss_idx = i;
    }

    /* Hash：包含连接四元组 + 时间戳 + 秘钥 */
    uint32_t data[3] = { src_ip ^ dst_ip, src_port, dst_port };
    uint32_t hash = rte_hash_crc(data, sizeof(data),
                                  (ts << 24) | syncookie_secret[ts & 1]);

    /* 编码 cookie */
    return (mss_idx << 29) | (ts << 24) | (hash & 0x00FFFFFF);
}

/* 验证 SYN Cookie */
static inline int
verify_syn_cookie(uint32_t src_ip, uint16_t src_port,
                  uint32_t dst_ip, uint16_t dst_port,
                  uint32_t cookie)
{
    /* 提取时间戳 */
    uint32_t ts = (cookie >> 24) & 0x1F;
    uint32_t current_ts = (rte_rdtsc() >> SYNCOOKIE_TSC_SHIFT) & 0x1F;

    /* 时间窗口检查（允许 1 个窗口的偏差） */
    if (ts != current_ts && ts != ((current_ts - 1) & 0x1F))
        return -1;  /* 过期 */

    /* 重新计算 hash 验证 */
    uint32_t data[3] = { src_ip ^ dst_ip, src_port, dst_port };
    uint32_t expected_hash = rte_hash_crc(data, sizeof(data),
                                           (ts << 24) | syncookie_secret[ts & 1]);

    if ((cookie & 0x00FFFFFF) != (expected_hash & 0x00FFFFFF))
        return -1;  /* 无效 */

    return 0;  /* 有效 */
}
```

> [!warning] 示例代码的安全边界
> 上面的 `rte_hash_crc` 代码用于解释 Cookie 编解码流程，不是生产级认证实现。
> CRC 不是密码学 MAC；生产实现应使用带密钥的密码学 PRF/MAC，覆盖连接四元组、客户端 ISN、
> 时间窗口和需要恢复的 TCP 选项，并实现密钥轮换、过期窗口及重放处理。

### 5.3 SYN Proxy 状态机

```text
SYN Proxy 状态机（DPDK 侧）：

  收到 SYN（从客户端）：
    → 生成 SYN Cookie
    → 发送 SYN-ACK（ISN = cookie）给客户端
    → 不分配任何状态（无内存消耗）
    → 状态：等待 ACK

  收到 ACK（从客户端）：
    → 验证 cookie（从 ACK 的 acknowledgment number 反推）
    → 有效：
        → 仅确认源地址可达且对端完成握手
        → 执行 Per-IP 限速、连接数上限、信誉与异常检测
        → 策略通过后，发送 SYN 到后端服务器（发起真实连接）
        → 创建 proxy conntrack entry
        → 状态：ESTABLISHING（等待后端 SYN-ACK）
    → 无效：
        → 静默丢弃

  收到 SYN-ACK（从后端服务器）：
    → 发送 ACK 给后端（完成握手）
    → 发送 ACK 给客户端（确认三次握手）
    → 状态：ESTABLISHED（后续包双向转发）

  后续包：
    → 查 conntrack → 双向转发
```

```c
/* SYN Proxy 连接状态 */
enum synproxy_state {
    SP_CLOSED,
    SP_SYN_RECEIVED,    /* 收到 SYN，已回 SYN-ACK */
    SP_ESTABLISHING,    /* 客户端 ACK 验证通过，正在和后端握手 */
    SP_ESTABLISHED,     /* 双向握手完成，正常转发 */
};

/* SYN Proxy 条目 */
struct synproxy_entry {
    uint32_t client_ip, server_ip;
    uint16_t client_port, server_port;
    enum synproxy_state state;
    uint32_t client_isn;   /* 客户端的 ISN */
    uint32_t proxy_isn;    /* Proxy 的 ISN（= cookie） */
    uint32_t server_isn;   /* 服务器的 ISN */
    uint64_t last_seen;
};
```

> [!info] SYN Cookie vs SYN Proxy
> **SYN Cookie** 只解决了"不分配半开连接内存"的问题。
> **SYN Proxy** 更进一步：DPDK 完全代理握手，后端服务器只看到已完成前端握手并通过策略的连接。
> “Cookie 验证通过”是可达性证明，不是安全身份或非攻击证明；真实 IP 的僵尸网络、
> 连接耗尽攻击和应用层 HTTP Flood 仍可能通过，因此必须叠加限速、连接配额、信誉和 L7 检测。
>
> SYN Proxy 的额外代价：
>
> - 需要维护 proxy conntrack（已建立的代理连接）
> - 需要处理序列号偏移（proxy ISN ≠ server ISN）
> - 需要处理 TCP 窗口和 MSS 协商

---

## 6. 硬件卸载：rte_flow 做 DDoS 防护

### 6.1 NIC 硬件丢弃

```text
软件丢弃 vs 硬件丢弃：

  软件丢弃（DPDK 收到后 rte_pktmbuf_free）：
    NIC → DMA → DPDK → 解析 → 查表 → 丢弃
    代价：已经占用了 DMA 带宽、PCIe 带宽、CPU 周期

  硬件丢弃（rte_flow DROP）：
    NIC → 硬件规则匹配 → 丢弃（包不离开网卡）
    代价：几乎为零
```

### 6.2 黑名单 IP 硬件 DROP

```c
/*
 * 为黑名单 IP 创建 rte_flow DROP 规则。
 * 包在 NIC 硬件层就被丢弃，不经过 DMA。
 */
struct rte_flow *
create_blacklist_drop(uint16_t port_id, uint32_t src_ip,
                      struct rte_flow_error *error)
{
    struct rte_flow_attr attr = {
        .group = 0,
        .priority = 0,   /* 最高优先级 */
        .ingress = 1,
    };

    struct rte_flow_item_ipv4 ipv4_spec = {
        .hdr.src_addr = src_ip,
    };
    struct rte_flow_item_ipv4 ipv4_mask = {
        .hdr.src_addr = 0xFFFFFFFF,  /* 精确匹配 */
    };

    struct rte_flow_item pattern[] = {
        { .type = RTE_FLOW_ITEM_TYPE_IPV4,
          .spec = &ipv4_spec, .mask = &ipv4_mask },
        { .type = RTE_FLOW_ITEM_TYPE_END },
    };

    struct rte_flow_action actions[] = {
        { .type = RTE_FLOW_ACTION_TYPE_COUNT },  /* 计数 */
        { .type = RTE_FLOW_ACTION_TYPE_DROP },
        { .type = RTE_FLOW_ACTION_TYPE_END },
    };

    return rte_flow_create(port_id, &attr, pattern, actions, error);
}
```

### 6.3 Group 分级过滤

```text
利用 rte_flow 的 Group 和 Priority 实现分层：

Group 0（最高优先级，硬件层处理）：
  Priority 0: DROP blacklisted IPs         ← 硬件直接丢弃
  Priority 1: DROP bogon sources           ← RFC 5735 保留地址
  Priority 2: DROP invalid TCP flags       ← SYN+FIN, SYN+RST 等
  Priority 3: COUNT + RSS to queues 0-7    ← 合法流量分配到软件队列
  Default:   JUMP to Group 1

Group 1（软件处理）：
  Priority 0: Per-IP rate limiting（DPDK rte_meter）
  Priority 1: SYN Proxy（TCP SYN）
  Priority 2: Normal forwarding
```

### 6.4 硬件规则的限制

| 限制              | 说明                                                |
| ----------------- | --------------------------------------------------- |
| 规则数量          | 通常几千到几万条，受 TCAM/SRAM 限制                 |
| 动态更新延迟      | rte_flow_create/destroy 毫秒级，不适合逐包更新      |
| 不支持复杂状态    | 只能做无状态匹配，无法做 conntrack 或 rate limiting |
| Pattern 限制      | 不是所有 NIC 都支持任意 pattern 组合                |
| Per-IP 限速不支持 | 硬件没有 per-IP token bucket（部分 SmartNIC 除外）  |

> [!warning] 硬件 DROP 规则要谨慎
> rte_flow DROP 规则在硬件层丢弃包，**无法在软件层看到这些包**。
> 这意味着：
>
> - 黑名单误加合法 IP → 该 IP 完全无法通信，且软件层面看不到
> - 必须同时设置 COUNT action，定期查询硬件计数器监控命中率
> - 黑名单更新需要创建/删除 rte_flow，有延迟——不能替代实时检测

---

## 7. BGP Flowspec：与上游路由器协同

### 7.1 为什么需要上游协同

当 DDoS 流量超过入口链路带宽时，不管 DPDK 有多快都无济于事——
管道已经满了。必须在 **上游路由器** 就丢弃攻击流量。

BGP Flowspec（RFC 5575）允许向路由器下发匹配规则和动作：

```text
                    BGP Flowspec
  分析平台 ──────────────────▶ 上游路由器
  "src_ip=1.2.3.4           "收到规则"
   dst_port=80               匹配 src_ip=1.2.3.4
   action=discard"            → 丢弃（不再转发到下游）

                             DPDK 服务器
  上游路由器 ──────────────▶ （看不到攻击流量了）
  转发非攻击流量              只处理合法流量
```

### 7.2 Flowspec 到 rte_flow 的转换

```c
/*
 * 将 BGP Flowspec 规则转换为 DPDK rte_flow 规则。
 *
 * BGP Flowspec 支持的匹配条件：
 *   · 目的/源 IP 前缀
 *   · IP 协议
 *   · 源/目的端口（或端口范围）
 *   · TCP flags
 *   · 包长度
 *   · DSCP
 *
 * 支持的动作：
 *   · discard
 *   · rate-limit（转发但限速）
 *   · redirect（重定向到特定 VRF）
 *   · mark（设置 DSCP）
 */

/* 将 Flowspec 的 src/dst prefix 转为 rte_flow */
static struct rte_flow *
flowspec_to_rte_flow(uint16_t port_id,
                     uint32_t src_ip, uint8_t src_prefix_len,
                     uint32_t dst_ip, uint8_t dst_prefix_len,
                     uint8_t proto,
                     uint16_t dst_port,
                     int action_drop,
                     struct rte_flow_error *error)
{
    struct rte_flow_attr attr = {
        .group = 1,       /* Flowspec 使用独立 group */
        .priority = 100,
        .ingress = 1,
    };

    /* 计算掩码 */
    uint32_t src_mask = src_prefix_len ?
        ~((1U << (32 - src_prefix_len)) - 1) : 0;
    uint32_t dst_mask = dst_prefix_len ?
        ~((1U << (32 - dst_prefix_len)) - 1) : 0;

    struct rte_flow_item_ipv4 ipv4_spec = {
        .hdr.src_addr = src_ip,
        .hdr.dst_addr = dst_ip,
        .hdr.next_proto_id = proto,
    };
    struct rte_flow_item_ipv4 ipv4_mask = {
        .hdr.src_addr = src_mask,
        .hdr.dst_addr = dst_mask,
        .hdr.next_proto_id = proto ? 0xFF : 0,
    };

    struct rte_flow_item pattern[4] = {0};
    int pi = 0;

    pattern[pi].type = RTE_FLOW_ITEM_TYPE_IPV4;
    pattern[pi].spec = &ipv4_spec;
    pattern[pi].mask = &ipv4_mask;
    pi++;

    /* 如果指定了目的端口 */
    if (dst_port && (proto == IPPROTO_TCP || proto == IPPROTO_UDP)) {
        /* 添加 TCP/UDP 端口匹配 */
        pi++;
    }

    pattern[pi].type = RTE_FLOW_ITEM_TYPE_END;

    struct rte_flow_action actions[3] = {0};
    int ai = 0;

    actions[ai++].type = RTE_FLOW_ACTION_TYPE_COUNT;

    if (action_drop)
        actions[ai++].type = RTE_FLOW_ACTION_TYPE_DROP;
    else
        actions[ai++].type = RTE_FLOW_ACTION_TYPE_QUEUE;  /* 重定向 */

    actions[ai].type = RTE_FLOW_ACTION_TYPE_END;

    return rte_flow_create(port_id, &attr, pattern, actions, error);
}
```

---

## 8. 异常检测：EWMA 基线偏差

### 8.1 流量基线建立

```c
/*
 * EWMA（指数加权移动平均）用于建立流量基线。
 *
 * 适用于：
 *   · 每秒 SYN 包数量
 *   · 每秒新连接数量
 *   · 每源 IP 的包速率
 *   · 总体 PPS/BPS
 *
 * 原理：
 *   baseline(t) = α × sample(t) + (1 - α) × baseline(t-1)
 *   α 越大，对变化越敏感（0.1 = 慢响应，0.5 = 快响应）
 */

struct ewma_baseline {
    double value;
    double alpha;
    uint32_t sample_count;
} __rte_cache_aligned;

static inline void
ewma_init(struct ewma_baseline *e, double alpha)
{
    e->value = 0.0;
    e->alpha = alpha;
    e->sample_count = 0;
}

static inline double
ewma_update(struct ewma_baseline *e, double sample)
{
    if (e->sample_count == 0)
        e->value = sample;
    else
        e->value = e->alpha * sample + (1.0 - e->alpha) * e->value;
    e->sample_count++;
    return e->value;
}

/*
 * 异常检测：
 * 当当前采样值显著偏离基线时触发告警。
 *
 * threshold_multiplier：基线的倍数，超过则判定异常
 *   例如 5.0 = 当前值超过基线 5 倍
 * min_samples：最少需要多少个采样才能开始检测
 *   避免初始阶段误报
 */
static inline int
detect_anomaly(const struct ewma_baseline *e,
               double current, double threshold_multiplier,
               uint32_t min_samples)
{
    if (e->sample_count < min_samples)
        return 0;  /* 采样不足，不检测 */

    if (current > e->value * threshold_multiplier)
        return 1;  /* 异常 */

    return 0;
}
```

### 8.2 多维度检测

```c
/*
 * 同时监控多个维度，任一维度异常都触发防护。
 */
struct ddos_detector {
    /* 全局指标 */
    struct ewma_baseline pps;           /* 每秒包数 */
    struct ewma_baseline syn_rate;       /* 每秒 SYN 数 */
    struct ewma_baseline new_conn_rate;  /* 每秒新连接数 */

    /* Per-IP 指标 */
    struct ewma_baseline per_ip_pps;     /* 单 IP 平均 PPS */

    /* 阈值 */
    double pps_threshold;          /* PPS 基线倍数 */
    double syn_threshold;          /* SYN 率基线倍数 */
    double conn_threshold;         /* 连接率基线倍数 */
};

/* 定期调用（例如每秒一次） */
static inline int
ddos_detect_tick(struct ddos_detector *det,
                 double current_pps,
                 double current_syn_rate,
                 double current_new_conn)
{
    int anomaly = 0;

    ewma_update(&det->pps, current_pps);
    ewma_update(&det->syn_rate, current_syn_rate);
    ewma_update(&det->new_conn_rate, current_new_conn);

    /* SYN Flood 检测 */
    if (detect_anomaly(&det->syn_rate, current_syn_rate,
                        det->syn_threshold, 30)) {
        anomaly |= 1;  /* SYN Flood 告警 */
    }

    /* 体积攻击检测 */
    if (detect_anomaly(&det->pps, current_pps,
                        det->pps_threshold, 30)) {
        anomaly |= 2;  /* 体积攻击告警 */
    }

    /* 连接耗尽检测 */
    if (detect_anomaly(&det->new_conn_rate, current_new_conn,
                        det->conn_threshold, 30)) {
        anomaly |= 4;  /* 连接耗尽告警 */
    }

    return anomaly;
}
```

---

## 9. XDP 前置过滤

### 9.1 XDP 和 DPDK 的协同

XDP 在内核驱动层做最早期包处理，适合在 DPDK 之前过滤掉已知恶意流量：

```text
  NIC → XDP (内核驱动层)
          │
          ├─ XDP_DROP: 已知攻击源、Bogon、无效包
          │             ← 在这里丢弃，不到达 DPDK
          │
          └─ XDP_PASS / XDP_REDIRECT
                │
                ▼
          DPDK 数据面（rte_meter / SYN Proxy / 异常检测）
```

详细 XDP 内容见 [[2026-04-09-dpdk-deep-dive-ch38-dpdk-ebpf|ch38：eBPF/XDP 与 DPDK 协同]]。

### 9.2 XDP DDoS 过滤程序

```c
// xdp_ddos_filter.bpf.c
// 内核层 DDoS 前置过滤：丢弃已知恶意流量
#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/tcp.h>
#include <bpf/bpf_helpers.h>

/* 黑名单 IP map（由用户态从 DPDK 异常检测结果更新） */
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 65536);
    __type(key, __u32);       /* src IP */
    __type(value, __u8);     /* 1 = blacklisted */
} blacklist SEC(".maps");

/* Per-IP 包计数（SYN 包） */
struct {
    __uint(type, BPF_MAP_TYPE_LRU_HASH);
    __uint(max_entries, 65536);
    __type(key, __u32);
    __type(value, __u64);     /* SYN count */
} syn_counter SEC(".maps");

SEC("xdp")
int xdp_ddos_filter(struct xdp_md *ctx)
{
    void *data = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;

    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end)
        return XDP_PASS;

    if (eth->h_proto != __builtin_bswap16(0x0800))
        return XDP_PASS;

    struct iphdr *ip = (void *)(eth + 1);
    if ((void *)(ip + 1) > data_end)
        return XDP_PASS;

    /* 1. 黑名单检查 */
    __u8 *blocked = bpf_map_lookup_elem(&blacklist, &ip->saddr);
    if (blocked && *blocked)
        return XDP_DROP;

    /* 2. SYN Flood 简单检测：per-IP SYN 计数 */
    if (ip->protocol == 6) { /* TCP */
        struct tcphdr *th = (void *)ip + (ip->ihl * 4);
        if ((void *)(th + 1) > data_end)
            return XDP_PASS;

        /* 只处理 SYN 包（不含 ACK） */
        if ((th->syn) && !(th->ack)) {
            __u64 *count = bpf_map_lookup_elem(&syn_counter, &ip->saddr);
            if (count) {
                *count += 1;
                /* 超过阈值：丢弃并加入黑名单 */
                if (*count > 1000) {  /* 1000 SYN/秒 */
                    __u8 val = 1;
                    bpf_map_update_elem(&blacklist, &ip->saddr, &val, BPF_ANY);
                    return XDP_DROP;
                }
            } else {
                __u64 init = 1;
                bpf_map_update_elem(&syn_counter, &ip->saddr, &init, BPF_ANY);
            }
        }
    }

    return XDP_PASS;
}

char _license[] SEC("license") = "GPL";
```

---

## 10. 完整 DDoS 防护流水线

```text
Packet In
    │
    ▼
┌──────────────────────────────┐
│ Layer 0: NIC Hardware        │
│ rte_flow DROP (blacklist)    │  ← 硬件丢弃已知攻击源
│ rte_flow RSS                 │  ← 合法流量分配到多核
└──────────────┬───────────────┘
               │
               ▼
┌──────────────────────────────┐
│ Layer 1: XDP Pre-filter      │
│ Bogon / blacklisted IP DROP  │  ← 内核层丢弃
│ Per-IP SYN count limit       │
└──────────────┬───────────────┘
               │
               ▼
┌──────────────────────────────┐
│ Layer 2: DPDK Processing     │
│                               │
│  ┌─── Bloom Filter ────────┐ │
│  │ Blacklisted IP check    │ │  ← O(1) 概率查找
│  │ + rte_hash 验证         │ │
│  └─────────────────────────┘ │
│               │               │
│  ┌─── rte_meter ──────────┐  │
│  │ Per-IP rate limiting    │  │  ← srTCM 三色标记
│  │ GREEN → pass            │  │
│  │ YELLOW → mark           │  │
│  │ RED → drop              │  │
│  └─────────────────────────┘  │
│               │               │
│  ┌─── SYN Proxy ──────────┐  │
│  │ TCP SYN → cookie reply  │  │  ← 无状态握手
│  │ ACK → verify cookie     │  │
│  │ Valid → policy → backend│  │
│  └─────────────────────────┘  │
│               │               │
│  ┌─── Anomaly Detect ────┐   │
│  │ EWMA baseline          │   │  ← 基线偏差检测
│  │ Auto-blacklist         │   │  ← 超阈值自动加黑名单
│  └─────────────────────────┘  │
└──────────────┬───────────────┘
               │
               ▼
          后端服务器
```

---

## 11. 总结

```text
DPDK DDoS 防护的核心模型：

流量监管：  rte_meter (srTCM/trTCM)
            RFC 标准、三色标记、Profile 共享

限速：      Token Bucket + rte_hash
            Per-IP 独立限速、百万级源 IP

黑名单：    Bloom Filter + rte_hash
            两级查找：概率过滤 + 精确验证

SYN 防护：  SYN Proxy + SYN Cookie
            过滤伪造源 SYN、隔离后端半开连接资源

硬件卸载：  rte_flow DROP
            NIC 硬件丢弃、CPU 零参与

上游协同：  BGP Flowspec → rte_flow
            链路满时在上游丢弃

异常检测：  EWMA 基线偏差
            自动发现新攻击、自动加黑名单

前置过滤：  XDP DROP
            内核驱动层丢弃、不到达 DPDK
```

关键要点：

1. **越早丢弃越好**——硬件 DROP > XDP DROP > 软件 DROP
2. **rte_meter 比手写 Token Bucket 更标准**——RFC 合规、Profile 共享、与 QoS 集成
3. **Bloom Filter 是预过滤器**——未命中可跳过精确黑名单查询，命中仍需二次验证
4. **SYN Cookie 不保存半开连接**——不需要为每个 SYN 维护独立连接状态
5. **Cookie 验证不是攻击判决**——它证明源地址可达，真实 IP 攻击者仍可能通过
6. **硬件 DROP 规则要监控**——用 COUNT action 跟踪命中率，防止误封
7. **上游协同应对带宽耗尽**——BGP Flowspec 让路由器在入口丢弃
8. **EWMA 自动适应**——基线自动学习，不用手动设阈值

> **DDoS 防护最重要的设计不是单个算法有多快，而是"多少流量在到达软件之前就被丢弃了"。硬件层和内核层丢弃的比例决定整体防护能力。**

---

## 参考资料

### DPDK

- [DPDK rte_meter Library](https://doc.dpdk.org/guides-26.03/prog_guide/qos_framework.html)
- [DPDK QoS Framework](https://doc.dpdk.org/guides-26.03/prog_guide/qos_framework.html)
- [DPDK Generic Flow API](https://doc.dpdk.org/guides-26.03/prog_guide/ethdev/flow_offload.html)
- [DPDK Hash Library](https://doc.dpdk.org/guides-26.03/prog_guide/hash_lib.html)

### RFC

- [RFC 2697 — srTCM](https://tools.ietf.org/html/rfc2697)
- [RFC 2698 — trTCM](https://tools.ietf.org/html/rfc2698)
- [RFC 4987 — TCP SYN Flooding](https://tools.ietf.org/html/rfc4987)
- [RFC 5575 — BGP Flowspec](https://tools.ietf.org/html/rfc5575)

### XDP / eBPF

- [XDP Documentation](https://www.kernel.org/doc/html/latest/networking/xdp.html)
- [[2026-04-09-dpdk-deep-dive-ch38-dpdk-ebpf|ch38：eBPF/XDP 与 DPDK 协同]]
