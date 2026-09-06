---
title: "DPDK 深度探索 ch38b：防火墙数据面——ACL、Conntrack、NAT 与硬件卸载"
date: 2026-04-10 14:30:00
tags: [dpdk, firewall, acl, conntrack, stateful, nat, rte-flow, dpi, ip-frag, offload]
description: "从 DPDK 工程视角解析防火墙数据面：rte_acl 五元组匹配与 SIMD 加速、连接追踪表设计、SNAT/DNAT 增量校验和、IP 分片重组、rte_flow 硬件卸载与软件回退"
---

# DPDK 深度探索 ch38b：防火墙数据面——ACL、Conntrack、NAT 与硬件卸载

> [!info] 章节定位
> 系列中已有 [[ch38-dpdk-ebpf|第三十八章：eBPF/XDP 与 DPDK 协同]]，
> 因此本文按 **ch38b 专题章**处理。
>
> 关联章节：
>
> - [[ch21-cryptodev|Cryptodev 框架]]
> - [[ch30-lookaside-crypto|Lookaside 加速——Cryptodev、QAT、IPsec]]
> - [[ch36-ipsec-deep-dive|IPsec 数据面——从 SA 状态机到硬件卸载]]
> - [[ch37-smartnic|SmartNIC 数据面——Representor、E-Switch 与硬件卸载]]
> - [[ch38-dpdk-ebpf|eBPF/XDP 与 DPDK 协同]]

> [!abstract] 核心结论
> 防火墙数据面的核心工作只有三步：**查规则 → 查/更新连接状态 → 执行动作**。
>
> 对 DPDK 工程而言，真正需要掌握的是：
>
> 1. `rte_acl` 如何通过用户定义的 field layout 和 SIMD（SSE/AVX2/AVX-512）
>    实现高吞吐五元组匹配；
> 2. 连接追踪表如何用 `rte_hash` 支撑百万级并发、如何做老化与超时管理；
> 3. NAT 的增量 checksum 更新和端口分配策略；
> 4. IP 分片为什么必须重组才能做有状态检测；
> 5. 什么规则适合卸载到 `rte_flow` 硬件，什么只能留在软件；
> 6. DPI（nDPI/Hyperscan）在 DPDK 防火墙中的集成方式和性能代价。

---

## 1. 防火墙数据面的处理流水线

### 1.1 核心处理步骤

```text
Packet In
    │
    ▼
┌─────────────────────────────────────────────┐
│  ① IP 分片检查                              │
│     分片包 → 重组（rte_ip_frag）             │
│     非分片 → 继续                            │
└─────────────┬───────────────────────────────┘
              │
              ▼
┌─────────────────────────────────────────────┐
│  ② Conntrack 查找                          │
│     5-tuple → rte_hash lookup               │
│     命中 → 已建立连接，跳过 ACL              │
│     未命中 → 新连接，进入 ACL 检查           │
└─────────────┬───────────────────────────────┘
              │
        ┌─────┴─────┐
        │ 新连接     │ 已建立
        ▼            ▼
┌──────────────┐ ┌──────────────────────────┐
│ ③ ACL 查找  │ │ ⑤ NAT 转换              │
│  rte_acl     │ │  修改 IP/Port            │
│  分类 + 策略 │ │  增量 checksum 更新       │
└──────┬───────┘ └────────────┬─────────────┘
       │                     │
  ┌────┴────┐                │
  │ permit  │ deny           │
  ▼         ▼                │
┌─────────────────┐         │
│ ④ 创建 conntrack│         │
│  写入 hash 表    │         │
└────────┬────────┘         │
         │                  │
         ▼                  ▼
┌─────────────────────────────────────────────┐
│  ⑥ 更新计数器 + 老新检查                     │
└─────────────┬───────────────────────────────┘
               │
               ▼
          Packet Out
```

### 1.2 无状态 vs 有状态

| 维度     | 无状态（ACL only）          | 有状态（ACL + Conntrack）                |
| -------- | --------------------------- | ---------------------------------------- |
| 处理依据 | 每个包独立判断              | 连接上下文                               |
| 性能     | 更高（无状态查找）          | 首包慢、后续包快（conntrack bypass ACL） |
| 内存     | 低（只有规则）              | 高（连接表、超时、计数器）               |
| 安全性   | 低（无法检测伪造的响应包）  | 高（只有合法连接的后续包被放行）         |
| 典型场景 | 边缘过滤、DDoS 防护、白名单 | 企业防火墙、网关、NAT                    |

生产防火墙几乎都是有状态的。无状态 ACL 通常作为前置过滤器，
在 conntrack 之前快速丢弃明显无效的流量。

---

## 2. rte_acl：DPDK 的规则匹配引擎

### 2.1 工作原理

`rte_acl` 不是简单的线性匹配，而是将规则编译为 **trie 结构**，
然后用 SIMD 指令（SSE/AVX2/AVX-512/NEON）并行遍历多条输入数据：

```text
规则编译阶段：
  rte_acl_add_rules()  →  添加原始规则
  rte_acl_build()      →  编译为 trie + 生成 SIMD 查找代码

运行时查找：
  输入数据（包的 5-tuple）
      │
      ▼
  ┌───────────────────────────────────┐
  │  SIMD 并行遍历 trie               │
  │  SSE: 8 条并行                    │
  │  AVX2: 16 条并行                  │
  │  AVX-512: 32 条并行               │
  └───────────────────────────────────┘
      │
      ▼
  匹配结果（最高优先级的 rule action）
```

### 2.2 定义规则字段

`rte_acl` 不预设字段格式，应用通过 `rte_acl_field_def` 数组定义自己的字段布局：

```c
#include <rte_acl.h>

/* 字段索引 */
enum {
    PROTO_FIELD,
    SRC_FIELD,
    DST_FIELD,
    SRCP_FIELD,
    DSTP_FIELD,
    NUM_FIELDS,     /* 总字段数 */
};

/* 定义 IPv4 5-tuple 的字段布局 */
static const struct rte_acl_field_def ipv4_5tuple_defs[NUM_FIELDS] = {
    /* 协议： bitmask 类型，1 byte */
    {
        .type = RTE_ACL_FIELD_TYPE_BITMASK,
        .size = sizeof(uint8_t),
        .field_index = PROTO_FIELD,
        .input_index = 0,
        .offset = offsetof(struct rte_ipv4_hdr, next_proto_id),
    },
    /* 源 IP：mask 类型，4 bytes */
    {
        .type = RTE_ACL_FIELD_TYPE_MASK,
        .size = sizeof(uint32_t),
        .field_index = SRC_FIELD,
        .input_index = 1,
        .offset = offsetof(struct rte_ipv4_hdr, src_addr),
    },
    /* 目的 IP：mask 类型，4 bytes */
    {
        .type = RTE_ACL_FIELD_TYPE_MASK,
        .size = sizeof(uint32_t),
        .field_index = DST_FIELD,
        .input_index = 2,
        .offset = offsetof(struct rte_ipv4_hdr, dst_addr),
    },
    /* 源端口：range 类型，2 bytes */
    {
        .type = RTE_ACL_FIELD_TYPE_RANGE,
        .size = sizeof(uint16_t),
        .field_index = SRCP_FIELD,
        .input_index = 3,
        .offset = sizeof(struct rte_ipv4_hdr) +
                  offsetof(struct rte_tcp_hdr, src_port),
    },
    /* 目的端口：range 类型，2 bytes */
    {
        .type = RTE_ACL_FIELD_TYPE_RANGE,
        .size = sizeof(uint16_t),
        .field_index = DSTP_FIELD,
        .input_index = 3,
        .offset = sizeof(struct rte_ipv4_hdr) +
                  offsetof(struct rte_tcp_hdr, dst_port),
    },
};
```

字段类型说明：

| 类型                         | 含义                  | 示例             |
| ---------------------------- | --------------------- | ---------------- |
| `RTE_ACL_FIELD_TYPE_MASK`    | 前缀匹配（CIDR 掩码） | IP 地址 /24, /32 |
| `RTE_ACL_FIELD_TYPE_RANGE`   | 范围匹配              | 端口 1024-65535  |
| `RTE_ACL_FIELD_TYPE_BITMASK` | 位掩码匹配            | 协议类型         |

`input_index` 决定了哪些字段被组合到同一个输入字中，影响 SIMD 并行度。

### 2.3 创建和构建 ACL 上下文

```c
struct rte_acl_ctx *
acl_create_and_build(void)
{
    struct rte_acl_param param = {
        .name = "firewall_acl",
        .socket_id = rte_socket_id(),
        .rule_size = RTE_ACL_RULE_SZ(NUM_FIELDS),  /* 自动计算规则大小 */
        .max_rule_count = 10000,
    };

    struct rte_acl_ctx *ctx = rte_acl_create(&param);
    if (ctx == NULL)
        return NULL;

    /* 添加规则 */
    struct rte_acl_rule rules[] = {
        /* 规则 1：允许 TCP 到 10.0.0.0/8 的 443 端口 */
        {
            .field[PROTO_FIELD] = { .u8 = 6 },          /* TCP */
            .field[SRC_FIELD]   = { .u32 = 0 },         /* any */
            .field[DST_FIELD]   = { .u32 = IPv4(10,0,0,0) },
            .field[SRCP_FIELD]  = { .u16 = 0 },         /* any */
            .field[DSTP_FIELD]  = { .u16 = 443 },
            .priority = 100,
            .category_mask = 1,
            .data = { .usermeta = 1 },                   /* 1 = ALLOW */
        },
        /* 规则 2：拒绝所有 */
        {
            .field[PROTO_FIELD] = { .u8 = 0 },
            .field[SRC_FIELD]   = { .u32 = 0 },
            .field[DST_FIELD]   = { .u32 = 0 },
            .field[SRCP_FIELD]  = { .u16 = 0, .u16 = 0xFFFF },
            .field[DSTP_FIELD]  = { .u16 = 0, .u16 = 0xFFFF },
            .priority = 1,
            .category_mask = 1,
            .data = { .usermeta = 0 },                   /* 0 = DENY */
        },
    };

    rte_acl_add_rules(ctx, rules, RTE_DIM(rules));

    /* 构建 trie 索引 */
    struct rte_acl_config cfg = {
        .num_categories = 1,
        .num_fields = NUM_FIELDS,
        .defs = ipv4_5tuple_defs,
        .max_size = 0,  /* 不限制 trie 大小 */
    };

    /* rte_acl_build 必须在添加所有规则后调用 */
    int ret = rte_acl_build(ctx, &cfg);
    if (ret != 0) {
        /* 构建失败：检查规则冲突、字段定义 */
        rte_acl_free(ctx);
        return NULL;
    }

    /* 可选：选择 SIMD 分类方法 */
    rte_acl_set_ctx_classify(ctx, RTE_ACL_CLASSIFY_AVX2);

    return ctx;
}
```

### 2.4 批量查找

```c
/*
 * 批量 ACL 分类。
 * 输入：多个包的 5-tuple 数据
 * 输出：每包对应的最高优先级规则的 data.usermeta
 */
static inline uint32_t
acl_classify_burst(struct rte_acl_ctx *ctx,
                   struct rte_mbuf **mbufs, uint32_t nb_pkts,
                   uint32_t *results)
{
    const uint8_t *data[nb_pkts];

    for (uint32_t i = 0; i < nb_pkts; i++) {
        /* 指向 IP header 的起始位置 */
        struct rte_ipv4_hdr *ip = rte_pktmbuf_mtod_offset(
            mbufs[i], struct rte_ipv4_hdr *,
            sizeof(struct rte_ether_hdr));
        data[i] = (const uint8_t *)ip;
    }

    /*
     * categories = 1（只使用一个类别）
     * results[i] = 匹配规则的 data.usermeta 值
     * 返回 0 表示成功
     */
    return rte_acl_classify(ctx, data, results, nb_pkts, 1);
}
```

> [!info] rte_acl 的性能特性
> `rte_acl` 的查找复杂度与规则数不是线性关系，而是取决于 trie 的深度。
> 实测参考值（单核，AVX2）：
>
> | 规则数 | 查找速率       |
> | ------ | -------------- |
> | 1K     | ~30M lookups/s |
> | 10K    | ~15M lookups/s |
> | 100K   | ~5M lookups/s  |
>
> SIMD 分类方法可通过 `rte_acl_set_ctx_classify()` 选择，
> 也可以让 DPDK 自动选择最优实现。

### 2.5 Category 机制

`rte_acl` 支持 **多类别同时分类**：一条规则可以属于多个类别（通过 `category_mask` 位掩码），
查找时一次返回多个类别各自匹配的最高优先级结果。

```text
应用场景：
  Category 0: 安全策略（permit/deny）
  Category 1: QoS 分类（gold/silver/bronze）
  Category 2: 审计/日志（log/no-log）

一条规则可以同时设置：
  category_mask = 0b111  → 属于全部三个类别
  data.usermeta = { .category_data[0] = ALLOW,
                    .category_data[1] = GOLD,
                    .category_data[2] = LOG }

一次 rte_acl_classify 调用返回三个类别各自的匹配结果。
```

### 2.6 规则热更新

规则更新流程：

```text
1. 创建新的 ACL 上下文或克隆当前上下文
2. 添加新规则 / 移除旧规则
3. rte_acl_build() 重新编译
4. 原子切换（RCU 或双缓冲）：
   · 旧上下文继续服务正在处理的包
   · 新包使用新上下文
   · 旧上下文引用归零后释放
```

`rte_acl_build()` 可能耗时较长（取决于规则数），不应在数据面热路径中调用。

---

## 3. 连接追踪（Conntrack）

### 3.1 为什么需要 Conntrack

无状态防火墙只看单个包的五元组，无法区分：

- 这是一个合法的 TCP 连接的后续包（应该放行）
- 还是一个伪造的响应包（应该丢弃）

Conntrack 维护连接状态表，让后续包可以 **跳过 ACL 查找直接放行**：

```text
首包（新连接）：
  ACL 查找 → 规则匹配 → 创建 conntrack 条目 → 执行动作

后续包（已建立连接）：
  Conntrack 查找 → 命中 → 直接放行（跳过 ACL）
  比首包路径快得多
```

### 3.2 连接状态

```text
防火墙视角的连接状态：

TCP：
  SYN       → NEW         （第一个 SYN 包）
  SYN+ACK   → ESTABLISHED  （三次握手完成）
  FIN/RST   → CLOSING      （开始关闭）
  双向 FIN  → CLOSED       （完全关闭，可清理）

UDP：
  首个包    → NEW
  响应包    → ESTABLISHED  （看到反向流量）
  超时      → CLOSED

ICMP：
  Request   → NEW
  Reply     → ESTABLISHED
  超时      → CLOSED
```

### 3.3 Conntrack 表实现

```c
#include <rte_hash.h>
#include <rte_jhash.h>

/* 连接 key：双向 5-tuple（用较小的 IP 作为正向） */
struct ct_key {
    uint32_t src_addr;
    uint32_t dst_addr;
    uint16_t src_port;
    uint16_t dst_port;
    uint8_t  proto;
    uint8_t  pad[3];
} __rte_packed;

/* 连接状态 */
enum ct_state {
    CT_NONE = 0,
    CT_NEW,
    CT_ESTABLISHED,
    CT_RELATED,
    CT_CLOSING,
};

/* TCP 子状态 */
enum ct_tcp_state {
    TCP_CLOSED = 0,
    TCP_SYN_SENT,
    TCP_SYN_RECV,
    TCP_ESTABLISHED,
    TCP_FIN_WAIT,
    TCP_CLOSE_WAIT,
    TCP_LAST_ACK,
    TCP_TIME_WAIT,
};

/* 连接条目 */
struct ct_entry {
    /* 正向 key */
    struct ct_key forward;
    /* 反向 key（用于双向查找） */
    struct ct_key reverse;

    enum ct_state state;
    enum ct_tcp_state tcp_state[2];  /* 正向和反向 */

    /* 超时 */
    uint64_t last_seen;      /* tsc 时间戳 */
    uint32_t timeout_sec;    /* 超时秒数 */

    /* 方向标志 */
    uint8_t seen_syn : 1;
    uint8_t seen_synack : 1;
    uint8_t seen_fin : 2;    /* 正向/反向各 1 bit */
    uint8_t seen_rst : 2;

    /* 计数器 */
    uint64_t pkts[2];        /* 正向/反向包数 */
    uint64_t bytes[2];       /* 正向/反向字节 */

    /* 关联的动作 */
    uint32_t action;         /* 允许/拒绝/跳转 */
} __rte_cache_aligned;
```

### 3.4 创建 Conntrack 表

```c
#define CT_MAX_CONNECTIONS (1 << 20)  /* 1M 连接 */

struct ct_table {
    struct rte_hash *hash;
    struct ct_entry *entries;
    struct rte_mempool *entry_pool;
    uint32_t max_entries;
};

struct ct_table *
ct_table_create(unsigned int socket_id)
{
    struct ct_table *tbl = rte_malloc_socket(NULL, sizeof(*tbl),
                                             0, socket_id);

    struct rte_hash_parameters hp = {
        .name = "ct_hash",
        .entries = CT_MAX_CONNECTIONS,
        .reserved = 0,
        .key_len = sizeof(struct ct_key),
        .hash_func = rte_jhash,
        .hash_func_init_val = 0,
        .socket_id = socket_id,
        .extra_flag = RTE_HASH_EXTRA_FLAGS_RW_CONCURRENCY
                    | RTE_HASH_EXTRA_FLAGS_EXT_TABLE,
    };

    tbl->hash = rte_hash_create(&hp);
    if (tbl->hash == NULL) {
        rte_free(tbl);
        return NULL;
    }

    tbl->max_entries = CT_MAX_CONNECTIONS;
    return tbl;
}
```

> [!info] rte_hash 并发选项
>
> - `RTE_HASH_EXTRA_FLAGS_RW_CONCURRENCY`：支持多线程并发读写，
>   内部使用读写锁或 per-bucket 锁
> - `RTE_HASH_EXTRA_FLAGS_EXT_TABLE`：使用扩展表，减少 hash 冲突导致的性能下降
> - 如果是单线程处理，不要加这些 flag，会带来额外开销

### 3.5 查找与更新

```c
/*
 * 连接查找：先查正向，再查反向。
 * 返回条目指针和方向标志（0=正向命中, 1=反向命中）。
 */
static inline struct ct_entry *
ct_lookup(struct ct_table *tbl,
           const struct ct_key *fwd_key,
           const struct ct_key *rev_key,
           int *dir)
{
    void *data = NULL;

    /* 先查正向 */
    int ret = rte_hash_lookup_data(tbl->hash, fwd_key, &data);
    if (ret >= 0) {
        *dir = 0;
        return (struct ct_entry *)data;
    }

    /* 再查反向 */
    ret = rte_hash_lookup_data(tbl->hash, rev_key, &data);
    if (ret >= 0) {
        *dir = 1;
        return (struct ct_entry *)data;
    }

    return NULL;  /* 新连接 */
}

/*
 * 创建新连接条目。
 * 注意：失败时返回 NULL（hash 表满）。
 */
static inline struct ct_entry *
ct_create(struct ct_table *tbl,
          const struct ct_key *fwd_key,
          const struct ct_key *rev_key,
          uint32_t action)
{
    struct ct_entry *entry = rte_zmalloc_socket(
        NULL, sizeof(*entry), 0, rte_socket_id());
    if (entry == NULL)
        return NULL;

    entry->forward = *fwd_key;
    entry->reverse = *rev_key;
    entry->state = CT_NEW;
    entry->action = action;
    entry->last_seen = rte_rdtsc();

    /* 设置默认超时 */
    switch (fwd_key->proto) {
    case IPPROTO_TCP: entry->timeout_sec = 60;  break;
    case IPPROTO_UDP: entry->timeout_sec = 30;  break;
    case IPPROTO_ICMP: entry->timeout_sec = 10; break;
    default: entry->timeout_sec = 60; break;
    }

    /* 用正向 key 插入 hash 表 */
    int ret = rte_hash_add_key_data(tbl->hash, fwd_key, entry);
    if (ret < 0) {
        rte_free(entry);
        return NULL;
    }

    return entry;
}
```

### 3.6 TCP 状态更新

```c
/*
 * 根据 TCP flags 更新连接状态。
 * 简化版：生产环境需要完整的 TCP 状态机。
 */
static inline void
ct_tcp_update(struct ct_entry *entry, int dir,
              struct rte_tcp_hdr *tcp)
{
    uint8_t flags = tcp->tcp_flags;
    uint64_t now = rte_rdtsc();

    entry->last_seen = now;
    entry->pkts[dir]++;
    entry->bytes[dir] += 1;  /* 简化，实际需要包长度 */

    /* SYN */
    if ((flags & RTE_TCP_SYN_FLAG) && !(flags & RTE_TCP_ACK_FLAG)) {
        if (dir == 0) {
            entry->seen_syn = 1;
            entry->tcp_state[0] = TCP_SYN_SENT;
        }
    }
    /* SYN+ACK */
    else if ((flags & RTE_TCP_SYN_FLAG) && (flags & RTE_TCP_ACK_FLAG)) {
        if (dir == 1 && entry->seen_syn) {
            entry->seen_synack = 1;
            entry->state = CT_ESTABLISHED;
            entry->tcp_state[0] = TCP_ESTABLISHED;
            entry->tcp_state[1] = TCP_ESTABLISHED;
            entry->timeout_sec = 300;  /* ESTABLISHED 超时更长 */
        }
    }
    /* FIN */
    else if (flags & RTE_TCP_FIN_FLAG) {
        entry->seen_fin |= (1 << dir);
        if (entry->seen_fin == 0x3) {  /* 双向 FIN */
            entry->state = CT_CLOSING;
            entry->timeout_sec = 10;    /* 短超时等待最后 ACK */
        }
    }
    /* RST */
    else if (flags & RTE_TCP_RST_FLAG) {
        entry->seen_rst |= (1 << dir);
        entry->state = CT_CLOSING;
        entry->timeout_sec = 5;
    }
}
```

### 3.7 连接老化

```c
/*
 * 连接老化：遍历 hash 表，清理超时条目。
 *
 * 策略：不要每次遍历全表，而是每次只扫描一部分（增量老化）。
 * 每次调用扫描 total / ITER_BUCKETS 个 bucket。
 */
#define CT_AGING_BUCKETS_PER_CALL 1024

void
ct_aging(struct ct_table *tbl, uint64_t tsc_hz)
{
    uint32_t next = 0;
    const void *key;
    void *data;
    uint64_t now = rte_rdtsc();

    /* rte_hash_iterate 遍历条目 */
    while (rte_hash_iterate(tbl->hash, &key, &data, &next) >= 0) {
        struct ct_entry *entry = (struct ct_entry *)data;

        uint64_t elapsed = (now - entry->last_seen) * 1000 / tsc_hz;
        if (elapsed > (uint64_t)entry->timeout_sec * 1000) {
            /* 超时，删除连接 */
            rte_hash_del_key(tbl->hash, key);
            rte_free(entry);
        }

        /* 限制每次扫描的条目数，避免阻塞过久 */
        if (next > CT_AGING_BUCKETS_PER_CALL)
            break;
    }
}
```

> [!warning] Conntrack 表容量规划
> 每个连接条目约 128-256 bytes。1M 连接需要：
>
> - hash 表本身：~64MB
> - 连接条目：~256MB
> - 总计：~320MB
>
> hash 表的 `entries` 参数应设为预估最大连接数的 1.5-2 倍以降低冲突率。
> `rte_hash` 查找率在负载超过 80% 后会显著下降。

---

## 4. NAT：地址转换与增量 Checksum

### 4.1 NAT 与 Conntrack 的关系

NAT 表通常和 Conntrack 表绑定：每个 conntrack 条目包含 NAT 信息：

```text
Conntrack Entry:
  forward key:   10.0.0.2:12345 → 93.184.216.34:80
  reverse key:   93.184.216.34:80 → 10.0.0.2:12345

  NAT Info (SNAT):
  forward: src 10.0.0.2:12345 → 203.0.113.10:54321
  reverse: dst 203.0.113.10:54321 → 10.0.0.2:12345
```

这样做的好处：NAT 转换信息随连接创建时确定，后续包只需查 conntrack 表。

### 4.2 增量 Checksum 更新

NAT 修改了 IP 地址和/或端口，必须更新 L3/L4 checksum。
关键优化：**不需要重新计算整个 checksum，只需增量更新差值**。

```c
/*
 * 增量 checksum 更新。
 *
 * RFC 1624: HC' = ~(~HC + ~m + m')
 * 其中 HC 是旧 checksum，m 是旧值，m' 是新值。
 *
 * 对于 16-bit 值的替换：
 */
static inline uint16_t
cksum_update_16(uint16_t cksum, uint16_t old_val, uint16_t new_val)
{
    uint32_t sum;

    /* 减去旧值，加上新值 */
    sum = (~cksum & 0xFFFF) + (~old_val & 0xFFFF) + new_val;

    /* 处理进位 */
    sum = (sum & 0xFFFF) + (sum >> 16);
    sum = (sum & 0xFFFF) + (sum >> 16);

    return ~sum;
}

/* 32-bit IP 地址替换（拆为两个 16-bit 操作） */
static inline uint16_t
cksum_update_32(uint16_t cksum, uint32_t old_ip, uint32_t new_ip)
{
    cksum = cksum_update_16(cksum, old_ip & 0xFFFF, new_ip & 0xFFFF);
    cksum = cksum_update_16(cksum, (old_ip >> 16) & 0xFFFF,
                            (new_ip >> 16) & 0xFFFF);
    return cksum;
}

/*
 * SNAT 处理：修改源 IP 和源端口。
 * 同时更新 IP header checksum 和 TCP/UDP checksum。
 */
static inline void
snat_process(struct rte_ipv4_hdr *ip, void *l4_hdr,
             uint32_t new_src_ip, uint16_t new_src_port)
{
    uint32_t old_src_ip = ip->src_addr;
    uint16_t old_src_port;
    uint8_t proto = ip->next_proto_id;

    /* 1. 更新 IP header checksum */
    ip->hdr_checksum = cksum_update_32(ip->hdr_checksum,
                                        old_src_ip, new_src_ip);

    /* 2. 更新源 IP */
    ip->src_addr = new_src_ip;

    /* 3. 更新 L4 checksum 和端口 */
    if (proto == IPPROTO_TCP) {
        struct rte_tcp_hdr *tcp = (struct rte_tcp_hdr *)l4_hdr;
        old_src_port = tcp->src_port;

        /* TCP checksum 中包含 IP 地址（伪头部） */
        tcp->cksum = cksum_update_32(tcp->cksum, old_src_ip, new_src_ip);
        tcp->cksum = cksum_update_16(tcp->cksum, old_src_port, new_src_port);

        tcp->src_port = new_src_port;
    } else if (proto == IPPROTO_UDP) {
        struct rte_udp_hdr *udp = (struct rte_udp_hdr *)l4_hdr;
        old_src_port = udp->src_port;

        udp->dgram_cksum = cksum_update_32(udp->dgram_cksum,
                                            old_src_ip, new_src_ip);
        udp->dgram_cksum = cksum_update_16(udp->dgram_cksum,
                                            old_src_port, new_src_port);

        udp->src_port = new_src_port;
    }
}
```

> [!info] 增量 vs 全量 Checksum
> 全量计算 L4 checksum 需要遍历整个 L4 payload（使用 `rte_ipv4_udptcp_cksum()`）。
> 对于大包（1400 bytes），这可能是几十个周期的遍历。
> 增量更新只需 4 次算术运算（IP + port），性能提升明显。
>
> 但注意：如果 mbuf 支持 `PKT_TX_OFFLOAD_IPV4_CKSUM` 和
> `PKT_TX_OFFLOAD_TCP_CKSUM`，可以让 NIC 硬件计算 checksum，
> 软件完全不需要处理。

### 4.3 端口分配策略

```text
NAT 端口分配是性能关键路径：

策略 1：顺序分配
  next_port++ % range
  · 优点：简单，缓存友好
  · 缺点：连接关闭后端口立即被复用，可能和延迟包冲突

策略 2：随机分配
  rte_rand() % range
  · 优点：避免端口复用冲突
  · 缺点：随机数生成开销，缓存不友好

策略 3：分段哈希（推荐）
  port = hash(src_ip, src_port, proto, secret) % range
  · 优点：同一内网地址总是映射到相同端口范围，便于调试
  · 缺点：需要处理碰撞

策略 4：Bitmap 分配
  每 64 个端口用一个 uint64_t bitmap
  · 优点：O(1) 分配和释放
  · 缺点：大端口范围（65535）需要约 1KB bitmap

端口范围：通常使用 1024-65535，约 64K 端口。
如果只有一个外部 IP，最多 64K 并发 NAT 连接（TCP/UDP 各自独立）。
```

---

## 5. IP 分片处理

### 5.1 为什么防火墙需要处理分片

有状态防火墙 **必须** 处理 IP 分片：

```text
攻击场景：
  攻击者将 TCP header 分到第二个分片中
  → 第一个分片只包含 IP header，没有 TCP 端口信息
  → ACL 无法匹配端口规则
  → 如果防火墙不重组，只能放行或全部丢弃

正常场景：
  大包被 MTU 分片（如 UDP 1500 → 两个 800 字节分片）
  → 后续分片没有 L4 header
  → conntrack 无法匹配端口
  → 必须重组后才能正确处理
```

### 5.2 rte_ip_frag 库

```c
#include <rte_ip_frag.h>

/*
 * 创建分片重组表。
 * max_entries: 最大同时重组的分片组数
 * max_frags_per_entry: 每组最大分片数
 */
struct rte_ip_frag_tbl *
create_frag_table(unsigned int socket_id)
{
    struct rte_ip_frag_tbl *tbl;

    /* frag_iterations: 每次调用老化扫描的条目数 */
    tbl = rte_ip_frag_table_create(
        1 << 16,        /* max_entries: 64K 重组组 */
        16,             /* max_frags_per_entry */
        1 << 17,        /* entries: hash 表大小（≥ 2 × max_entries） */
        0,              /* frag_iterations: 老化频率 */
        socket_id);

    return tbl;
}

/*
 * 处理 IP 分片。
 * 返回值：
 *   非 NULL → 重组完成，返回完整包的 mbuf
 *   NULL 且 mbuf 不变 → 还需要更多分片
 *   NULL 且 mbuf 被释放 → 分片无效或超时
 */
struct rte_mbuf *
process_fragment(struct rte_ip_frag_tbl *frag_tbl,
                 struct rte_mbuf *mbuf,
                 struct rte_ip_frag_death_row *death_row)
{
    struct rte_ipv4_hdr *ip = rte_pktmbuf_mtod_offset(
        mbuf, struct rte_ipv4_hdr *,
        sizeof(struct rte_ether_hdr));

    /* 只处理分片包 */
    if (rte_ipv4_frag_pkt_is_fragmented(ip)) {
        struct rte_mbuf *reassembled;

        /* 尝试重组 */
        reassembled = rte_ipv4_frag_reassemble_packet(
            frag_tbl, death_row, mbuf, rte_rdtsc(), ip);

        if (reassembled == NULL) {
            /* 还没重组完（等更多分片）或失败 */
            return NULL;
        }

        /* 重组完成，用完整包继续处理 */
        return reassembled;
    }

    /* 非分片包，直接返回 */
    return mbuf;
}

/*
 * 定期调用老化函数，清理超时的分片。
 */
void
frag_aging(struct rte_ip_frag_tbl *tbl)
{
    struct rte_ip_frag_death_row death_row;

    /* 清理超时和过多的分片 */
    rte_ip_frag_free_death_row(&death_row, 0);

    /* 增量老化 */
    rte_ip_frag_table_del_expired_entries(tbl, &death_row, rte_rdtsc());
}
```

> [!warning] 分片重组的 DoS 风险
> 攻击者可以发送大量不完整的分片（只有第一个分片，没有后续分片），
> 耗尽重组表的内存。
>
> 缓解措施：
>
> - 限制每个源 IP 的并发重组数
> - 设置较短的分片超时（通常 5-10 秒）
> - 监控重组表使用率，超限后丢弃新分片
> - 在 ACL 中直接丢弃非法分片（重叠、偏移异常）

---

## 6. 硬件卸载：rte_flow 做防火墙

### 6.1 什么规则适合卸载

| 适合硬件卸载              | 适合软件处理            |
| ------------------------- | ----------------------- |
| 大流量稳定规则的 DROP/RSS | 有状态检测（conntrack） |
| 5-tuple 精确匹配 + DROP   | 复杂协议解析            |
| VLAN/VxLAN 隧道分类       | 应用层检测（DPI）       |
| 固定前缀的 IP 过滤        | 动态规则（频繁变化）    |
| 端口范围过滤              | 需要修改包内容的规则    |
| 高优先级安全白名单/黑名单 | 日志和审计              |

### 6.2 用 rte_flow 创建硬件 ACL 规则

```c
#include <rte_flow.h>

/*
 * 创建一条硬件 DROP 规则：
 * 匹配所有到 192.168.1.0/24 的 TCP 22 端口流量并丢弃。
 */
struct rte_flow *
create_hw_acl_drop(uint16_t port_id, struct rte_flow_error *error)
{
    struct rte_flow_attr attr = {
        .group = 0,
        .priority = 10,        /* 数值越小优先级越高 */
        .ingress = 1,
    };

    /* Pattern: IPv4 + TCP dst port 22 + dst IP 192.168.1.0/24 */
    struct rte_flow_item_ipv4 ipv4_spec = {
        .hdr.dst_addr = RTE_IPV4(192, 168, 1, 0),
    };
    struct rte_flow_item_ipv4 ipv4_mask = {
        .hdr.dst_addr = RTE_IPV4(255, 255, 255, 0),  /* /24 */
    };
    struct rte_flow_item_tcp tcp_spec = {
        .hdr.dst_port = rte_cpu_to_be_16(22),
    };
    struct rte_flow_item_tcp tcp_mask = {
        .hdr.dst_port = 0xFFFF,
    };

    struct rte_flow_item pattern[] = {
        { .type = RTE_FLOW_ITEM_TYPE_IPV4,
          .spec = &ipv4_spec, .mask = &ipv4_mask },
        { .type = RTE_FLOW_ITEM_TYPE_TCP,
          .spec = &tcp_spec, .mask = &tcp_mask },
        { .type = RTE_FLOW_ITEM_TYPE_END },
    };

    /* Action: DROP */
    struct rte_flow_action actions[] = {
        { .type = RTE_FLOW_ACTION_TYPE_DROP },
        { .type = RTE_FLOW_ACTION_TYPE_END },
    };

    return rte_flow_create(port_id, &attr, pattern, actions, error);
}

/*
 * 创建带计数的规则：
 * 丢弃并计数，用于监控硬件规则命中率。
 */
struct rte_flow *
create_hw_acl_count_drop(uint16_t port_id,
                         struct rte_flow_error *error)
{
    /* ... 同上 pattern ... */

    struct rte_flow_action_count count_cfg = {
        .shared = 0,     /* 专用 counter */
        .id = 0,         /* counter ID */
    };

    struct rte_flow_action actions[] = {
        { .type = RTE_FLOW_ACTION_TYPE_COUNT, .conf = &count_cfg },
        { .type = RTE_FLOW_ACTION_TYPE_DROP },
        { .type = RTE_FLOW_ACTION_TYPE_END },
    };

    /* rte_flow_create(...); */
}

/* 查询计数器 */
void
query_hw_acl_counter(uint16_t port_id, struct rte_flow *flow)
{
    struct rte_flow_query_count query = { .reset = 1 };
    struct rte_flow_action action = { .type = RTE_FLOW_ACTION_TYPE_COUNT };

    rte_flow_query(port_id, flow, &action, &query, NULL);
    /* query.hits = 命中次数, query.bytes = 命中字节数 */
}
```

### 6.3 Group/Priority 级联

```text
rte_flow 的 Group 和 Priority 可以实现规则级联：

Group 0（最高优先级，硬件快速过滤）:
  Priority 0:  DROP known-bad IPs        ← 硬件直接丢弃
  Priority 1:  DROP invalid TCP flags    ← 硬件直接丢弃
  Priority 2:  RSS to queue 0-3         ← 合法流量分配到软件队列
  Default:     JUMP to group 1           ← 其余进入下一级

Group 1（软件处理）:
  Priority 0:  MARK + QUEUE for DPI     ← 需要深度检测的流量
  Default:     PORT_ID → pass           ← 默认放行

这种两级架构让大部分流量在 Group 0 就被硬件处理，
只有需要深度检测的流量才进入软件路径。
```

### 6.4 硬件 ACL 的局限

| 局限              | 说明                                                 |
| ----------------- | ---------------------------------------------------- |
| 规则数量有限      | 通常几千到几万条，受 TCAM/SRAM 容量限制              |
| 不支持 conntrack  | 硬件无法做有状态检测，只能做无状态匹配               |
| 更新延迟高        | `rte_flow_create/destroy` 需要与固件交互，可能毫秒级 |
| 模式限制          | 不是所有 pattern/action 组合都被硬件支持             |
| 不同 NIC 能力不同 | Intel E810 和 Mellanox ConnectX 支持的模式不同       |
| 优先级实现差异    | 有些 NIC 不支持 group/priority 或有限制              |

---

## 7. DPI 集成：应用层检测

### 7.1 为什么需要 DPI

五元组 ACL 无法识别：

- HTTP 请求中的恶意路径
- 特定应用协议（P2P、游戏、即时通信）
- 加密流量中的 SNI（TLS ClientHello）
- 数据泄露模式

DPI（Deep Packet Inspection）在 L4 之上做应用层协议识别和内容检测。

### 7.2 nDPI：协议识别

[nDPI](https://github.com/ntop/nDPI) 是开源的 DPI 库，可识别 300+ 协议：

```text
DPDK + nDPI 集成模式：

  NIC → DPDK RX
          │
          ▼
     Conntrack 查找
          │
          ├─ 新连接 → nDPI 协议识别 → 记录协议类型到 conntrack
          │            │
          │            ├─ HTTP → 检查 URL/Host
          │            ├─ DNS  → 检查域名
          │            ├─ TLS → 提取 SNI
          │            └─ Unknown → 标记待观察
          │
          └─ 已建立 → 直接用 conntrack 中的协议类型做策略
                       （首包识别，后续包不需要重复检测）
```

性能：nDPI 在单核上约 1-2 Gbps（取决于规则数和流量类型）。

### 7.3 Hyperscan/Vectorscan：正则匹配

[Hyperscan](https://github.com/VectorCamp/vectorscan)（Intel 开源，Vectorscan 是社区分支）
提供高性能正则匹配：

```text
适用场景：
  · HTTP URL 过滤（匹配恶意路径模式）
  · DGA 域名检测（随机子域名）
  · 数据泄露防护（信用卡号、SSN 模式）
  · IDS 规则匹配（Snort/Suricata 兼容）

性能：
  · 单核 10-20 Gbps（取决于正则复杂度）
  · 支持流式扫描（跨包匹配）

集成模式：
  DPDK 收包 → 重组 → 解析 L7 payload → Hyperscan 匹配 → 策略决策
```

### 7.4 DPI 在防火墙流水线中的位置

```text
                    DPI 不是对每个包都做

首包（新连接）：
  ┌───────────┐    ┌──────────┐    ┌──────────┐
  │ Conntrack │───▶│  nDPI    │───▶│ 协议类型  │
  │ 新建      │    │ 识别协议 │    │ 写回 CT   │
  └───────────┘    └──────────┘    └──────────┘

后续包（已建立连接）：
  ┌───────────┐    ┌──────────┐
  │ Conntrack │───▶│ 协议类型 │───▶ 直接做策略
  │ 命中      │    │ 已知     │    （不再调 DPI）
  └───────────┘    └──────────┘

只在首包调用 DPI，后续包通过 conntrack 缓存协议类型。
这样 DPI 的性能开销被摊薄到连接数而非包数。
```

---

## 8. 完整数据面流水线

```text
Packet In
    │
    ▼
┌─────────────────────────────┐
│ 1. Parse L2/L3/L4           │
│    提取 5-tuple              │
└─────────────┬───────────────┘
              │
              ▼
┌─────────────────────────────┐
│ 2. IP Fragment Check        │
│    分片 → rte_ip_frag 重组   │
│    非分片 → 继续              │
└─────────────┬───────────────┘
              │
              ▼
┌─────────────────────────────┐
│ 3. Conntrack Lookup (rte_hash)│
│    命中 + ESTABLISHED        │
│      → 跳到 step 6           │
│    未命中                    │
│      → 继续到 step 4         │
└─────────────┬───────────────┘
              │
              ▼
┌─────────────────────────────┐
│ 4. ACL Lookup (rte_acl)     │
│    DENY → 丢弃              │
│    PERMIT → 继续             │
└─────────────┬───────────────┘
              │
              ▼
┌─────────────────────────────┐
│ 5. Create Conntrack Entry   │
│    + DPI Protocol Detect    │
│    (首包才调用 nDPI)         │
└─────────────┬───────────────┘
              │
              ▼
┌─────────────────────────────┐
│ 6. NAT (if needed)          │
│    SNAT/DNAT                │
│    增量 checksum 更新        │
└─────────────┬───────────────┘
              │
              ▼
┌─────────────────────────────┐
│ 7. Update Counters          │
│    + TCP State Machine      │
│    + Timeout Refresh        │
└─────────────┬───────────────┘
              │
              ▼
         Packet Out
```

---

## 9. 性能优化要点

### 9.1 数据结构选择

| 功能         | 推荐数据结构         | 原因                               |
| ------------ | -------------------- | ---------------------------------- |
| ACL 规则匹配 | `rte_acl`            | SIMD 加速 trie 查找，支持范围/掩码 |
| 连接追踪表   | `rte_hash`           | O(1) 查找，支持并发和扩展表        |
| NAT 端口分配 | Bitmap 或 per-IP 池  | O(1) 分配和释放                    |
| 分片重组     | `rte_ip_frag`        | 内置老化，和 hash 表集成           |
| 统计计数器   | per-lcore + 定期聚合 | 避免原子操作开销                   |

### 9.2 热路径优化

```text
1. Conntrack 命中路径是最热的路径
   · 已建立连接的后续包不经过 ACL
   · 确保 rte_hash lookup 在 cache 中
   · 考虑 per-lcore conntrack 分区减少锁竞争

2. 批量处理
   · rte_acl_classify 支持批量查找
   · 批量更新 conntrack 计数器
   · 批量执行 NAT 转换

3. 避免 per-packet 动态内存分配
   · conntrack 条目从预分配 pool 中获取
   · 不要在数据面调用 rte_malloc/rte_zmalloc

4. NUMA 对齐
   · hash 表和 conntrack 条目在 NIC 所在 NUMA node
   · ACL 上下文在处理 lcore 所在 NUMA node

5. Checksum offload
   · 如果 NIC 支持 TX checksum offload，
     NAT 转换后不需要软件更新 checksum
   · 设置 mbuf 的 ol_flags：
     PKT_TX_IPV4 | PKT_TX_IP_CKSUM | PKT_TX_TCP_CKSUM
```

### 9.3 硬件 + 软件分层

```text
最优架构：硬件做粗粒度过滤，软件做细粒度检测

NIC (rte_flow):
  · DROP known-bad IP ranges       ← 硬件直接丢弃，零 CPU
  · DROP invalid TCP flag combos   ← 硬件直接丢弃
  · RSS 合法流量到多个 queue       ← 多核并行

DPDK Software:
  · Conntrack (rte_hash)           ← 状态检测
  · ACL (rte_acl)                  ← 新连接规则匹配
  · NAT                            ← 地址转换
  · DPI (首包)                     ← 协议识别

性能分配：
  硬件处理 80-90% 的包（DROP + RSS）
  软件只处理 10-20% 的包（新连接 + 复杂检测）
```

---

## 10. 总结

```text
DPDK 防火墙数据面的核心：

规则匹配：    rte_acl
              用户定义字段 + SIMD trie + category 多分类

连接追踪：    rte_hash
              双向 5-tuple + 状态机 + 老化

地址转换：    增量 checksum
              NAT 信息绑定 conntrack + 端口分配策略

分片处理：    rte_ip_frag
              重组后才能做有状态检测

硬件卸载：    rte_flow
              粗粒度 DROP/RSS 在 NIC，细粒度检测在软件

应用检测：    nDPI / Hyperscan
              首包识别，缓存到 conntrack
```

关键要点：

1. **`rte_acl` 不是线性匹配**——它编译为 SIMD 加速的 trie，查找速率与规则数非线性关系
2. **Conntrack 是性能关键**——大部分包应走 conntrack 命中路径，跳过 ACL
3. **NAT 用增量 checksum**——不要全量重算，4 次算术运算搞定 IP+Port 替换
4. **IP 分片必须重组**——否则有状态防火墙无法工作
5. **硬件做粗、软件做细**——rte_flow 处理 DROP/RSS，软件做 conntrack/ACL/DPI
6. **DPI 只在首包调用**——协议类型缓存到 conntrack，后续包不重复检测

> **防火墙数据面最重要的设计决策不是"用什么算法"，而是"哪些包走快速路径（conntrack bypass），哪些包必须走慢速路径（ACL + DPI）"。快速路径的比例决定整体吞吐。**

---

## 参考资料

### DPDK 官方文档

- [DPDK ACL Library](https://doc.dpdk.org/guides-26.03/prog_guide/acl_lib.html)
- [DPDK Hash Library](https://doc.dpdk.org/guides-26.03/prog_guide/hash_lib.html)
- [DPDK IP Fragmentation Library](https://doc.dpdk.org/guides-26.03/prog_guide/ip_fragment_reassembly_lib.html)
- [DPDK Generic Flow API](https://doc.dpdk.org/guides-26.03/prog_guide/ethdev/flow_offload.html)
- [DPDK Checksum Functions](https://doc.dpdk.org/guides-26.03/prog_guide/ipv4_frag_reassemble_lib.html)

### 开源项目

- [nDPI — Deep Packet Inspection](https://github.com/ntop/nDPI)
- [Vectorscan — Portable Hyperscan](https://github.com/Vectorcamp/vectorscan)
- [dpdk-acl-guide examples](https://doc.dpdk.org/guides-26.03/sample_app_ug/l3_forward_access_ctrl.html)

### RFC

- [RFC 1624 — Incremental Checksum Update](https://tools.ietf.org/html/rfc1624)
- [RFC 793 — TCP Checksum](https://tools.ietf.org/html/rfc793)
