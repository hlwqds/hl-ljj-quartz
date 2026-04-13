---
title: "DPDK 深度探索 ch39：DDoS 防护"
date: 2026-04-10 15:00:00
tags: [dpdk, ddos, syn-cookie, rate-limit, traffic-policing, flood, mitigation]
description: "深入解析 DPDK DDoS 防护：Syn Cookie、Rate Limiting、流量控制、异常检测与 DDoS 缓解策略"
---

# DPDK 深度探索 ch39：DDoS 防护

> [!abstract] 核心要点
> DDoS 攻击是网络安全的主要威胁。DPDK 可实现高性能 DDoS 防护，本章深入解析 Syn Cookie、流量限制、异常检测与缓解策略。

## 1. DDoS 概述

### 1.1 攻击类型

```
┌─────────────────────────────────────────────────────────────┐
│                    DDoS 攻击类型                            │
│                                                              │
│  体积攻击 (Volumetric):                                    │
│  - UDP Flood                                              │
│  - ICMP Flood                                             │
│  - Amplification (DNS, NTP, Memcached)                   │
│                                                              │
│  协议攻击 (Protocol):                                       │
│  - SYN Flood                                              │
│  - Ping of Death                                           │
│  - Smurf                                                   │
│                                                              │
│  应用层攻击 (Application):                                 │
│  - HTTP Flood                                             │
│  - Slowloris                                              │
│  - DNS Query Flood                                        │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 放大攻击

```
┌─────────────────────────────────────────────────────────────┐
│                    Amplification 攻击                       │
│                                                              │
│  DNS Amplification:                                         │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Attacker ──(50 bytes)──▶  DNS Server               │  │
│  │                                    │                   │  │
│  │                        响应 (~5000 bytes)            │  │
│  │  Attacker ◀─────────────────────────  Victim         │  │
│  │                                                     │  │
│  │  放大倍数: 100x                                      │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                              │
│  常见放大因子：                                             │
│  - DNS: 50-100x                                           │
│  - NTP: 500x                                              │
│  - Memcached: 10000-50000x                               │
└─────────────────────────────────────────────────────────────┘
```

## 2. SYN Flood 防护

### 2.1 Syn Cookie

```
┌─────────────────────────────────────────────────────────────┐
│                    SYN Cookie                              │
│                                                              │
│  传统 SYN Queue:                                           │
│  Server ◀─── SYN ──── Attacker (伪造源)                     │
│  Server ─── SYN-ACK ──▶ 受害者                            │
│  Server ─── SYN-ACK ──▶ 受害者                            │
│  ...                                                        │
│  Queue 耗尽                                                │
│                                                              │
│  SYN Cookie:                                               │
│  Server ◀─── SYN ──── Attacker                              │
│  Server 计算 cookie = f(src_ip, src_port, dst_ip,         │
│                        dst_port, timestamp, secret)        │
│  Server ─── SYN-ACK (cookie) ──▶ Attacker                  │
│  (不分配 Connection)                                        │
│  Attacker ─── ACK (cookie) ──▶ Server                       │
│  Server 验证 cookie                                        │
│  Server ────▶ Connection Established                       │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 Syn Cookie 实现

```c
// SYN Cookie 生成
uint32_t
generate_syn_cookie(uint32_t src_ip, uint16_t src_port,
                    uint32_t dst_ip, uint16_t dst_port,
                    uint32_t seq)
{
    // 秘钥
    static uint32_t secret[2];

    // 时间戳 (低 6 位)
    uint32_t ts = (time(NULL) >> 6) & 0x3F;

    // Cookie = hash(src_ip, src_port, dst_ip, dst_port, seq, ts, secret)
    uint32_t hash = jhash2((uint32_t[]){src_ip, dst_ip,
                     seq, ts, secret[0], secret[1]}, 6, 0);

    // 编码 ISN
    uint32_t isn = (hash & 0x7FFFE000) | ts;

    return isn;
}

// 验证 SYN Cookie
int
verify_syn_cookie(uint32_t src_ip, uint16_t src_port,
                  uint32_t dst_ip, uint16_t dst_port,
                  uint32_t seq, uint32_t ack)
{
    uint32_t expected_ack = generate_syn_cookie(src_ip, src_port,
                                                dst_ip, dst_port,
                                                ack - 1);

    // 验证 ACK
    if ((ack - 1) == expected_ack)
        return 0;  // 有效

    return -1;  // 无效
}
```

### 2.3 Synproxy

```c
// Synproxy 状态
struct synproxy {
    // 连接表
    struct rte_hash *conn_table;

    // Syncookie
    uint32_t secret[2];

    // 统计
    uint64_t syn_cookies_sent;
    uint64_t syn_cookies_verified;
    uint64_t connections_established;
};

// 处理 SYN
int
synproxy_handle_syn(struct synproxy *sp,
                    struct rte_mbuf *mbuf)
{
    struct tcp_hdr *tcp = get_tcp_header(mbuf);
    struct ip_hdr *ip = get_ip_header(mbuf);

    // 生成 syncookie
    uint32_t cookie = generate_syn_cookie(
        ip->src_addr, tcp->src_port,
        ip->dst_addr, tcp->dst_port,
        tcp->sent_seq);

    // 发送 SYN-ACK with cookie
    send_synack(mbuf, cookie);

    // 记录半开连接
    struct half_open_key key = {
        .src_ip = ip->src_addr,
        .dst_ip = ip->dst_addr,
        .src_port = tcp->src_port,
        .dst_port = tcp->dst_port,
        .sent_seq = tcp->sent_seq,
        .cookie = cookie,
    };

    rte_hash_add(sp->conn_table, &key, sizeof(key));

    return 0;
}

// 处理 ACK
int
synproxy_handle_ack(struct synproxy *sp,
                     struct rte_mbuf *mbuf)
{
    struct tcp_hdr *tcp = get_tcp_header(mbuf);

    // 验证 cookie
    int valid = verify_syn_cookie(
        ip->src_addr, tcp->src_port,
        ip->dst_addr, tcp->dst_port,
        tcp->sent_seq, tcp->recv_ack);

    if (!valid)
        return -1;

    // 完成连接
    complete_connection(mbuf);

    return 0;
}
```

## 3. Rate Limiting

### 3.1 Token Bucket

```
Token Bucket 算法：

┌─────────────────────────────────────────────────────────────┐
│                    Token Bucket                             │
│                                                              │
│    Bucket (容量 = B)                                       │
│    ┌──────────────────┐                                     │
│    │ ████████████████ │◀─── 补充 tokens (速率 R)            │
│    │ ████████████████ │                                     │
│    │ ████████████████ │────▶ 发送 packet (消耗 1 token)   │
│    │ ████████████████ │                                     │
│    └──────────────────┘                                     │
│                                                              │
│  参数：                                                     │
│  - B: Bucket 大小                                          │
│  - R: 补充速率 (packets/second)                            │
│                                                              │
│  效果：                                                     │
│  - 允许突发 (最多 B packets)                               │
│  - 限制平均速率                                            │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 Token Bucket 实现

```c
struct token_bucket {
    uint64_t tokens;       // 当前 token
    uint64_t rate;        // 补充速率 (tokens/sec)
    uint64_t bucket_size; // 桶大小
    uint64_t last_update; // 上次更新时间
};

int
token_bucket_init(struct token_bucket *tb,
                   uint64_t rate, uint64_t bucket_size)
{
    tb->tokens = bucket_size;
    tb->rate = rate;
    tb->bucket_size = bucket_size;
    tb->last_update = rte_rdtsc();

    return 0;
}

int
token_bucket_consume(struct token_bucket *tb)
{
    uint64_t now = rte_rdtsc();
    uint64_t elapsed = now - tb->last_update;

    // 补充 tokens
    uint64_t tokens_to_add = (elapsed * tb->rate) / rte_get_tsc_hz();
    tb->tokens = RTE_MIN(tb->bucket_size, tb->tokens + tokens_to_add);
    tb->last_update = now;

    // 检查
    if (tb->tokens > 0) {
        tb->tokens--;
        return 0;  // 允许
    }

    return -1;  // 拒绝
}
```

### 3.3 CAR (Committed Access Rate)

```c
// 双桶 CAR (PIR/ CIR)
struct car {
    // 承诺桶 (CIR)
    struct token_bucket committed;

    // 峰值桶 (PIR)
    struct token_bucket peak;

    uint64_t cir;  // Committed Information Rate
    uint64_t pir;  // Peak Information Rate
    uint64_t cbs;  // Committed Burst Size
    uint64_t pbs;  // Peak Burst Size
};

enum policing_action {
    POLICE_GREEN,    // 绿色：通过
    POLICE_YELLOW,    // 黄色：标记
    POLICE_RED,       // 红色：丢弃
};

enum policing_action
policing_action(struct car *c)
{
    // 检查承诺桶
    if (token_bucket_consume(&c->committed) == 0) {
        return POLICE_GREEN;
    }

    // 检查峰值桶
    if (token_bucket_consume(&c->peak) == 0) {
        return POLICE_YELLOW;
    }

    return POLICE_RED;
}
```

## 4. 异常检测

### 4.1 统计异常

```c
// EWMA (Exponentially Weighted Moving Average)
struct ewma {
    double avg;      // 当前平均值
    double factor;   // 衰减因子
};

double
ewma_update(struct ewma *e, uint64_t value)
{
    e->avg = e->factor * e->avg + (1 - e->factor) * value;
    return e->avg;
}

// 检测异常
int
detect_anomaly(struct ewma *pkt_rate, uint64_t current)
{
    double expected = ewma_update(pkt_rate, current);

    // 如果当前值远大于预期，检测为异常
    if (current > expected * 10) {
        return 1;  // 异常
    }

    return 0;
}
```

### 4.2 连接数限制

```c
// 每 IP 连接数限制
struct conn_limit {
    uint32_t src_ip;
    uint32_t active_conns;
    uint64_t last_seen;
};

struct conn_limit_table {
    struct rte_hash *by_ip;
    uint32_t max_conns_per_ip;
};

// 检查连接数
int
check_conn_limit(struct conn_limit_table *t, uint32_t src_ip)
{
    struct conn_limit *limit = rte_hash_lookup(t->by_ip, &src_ip);

    if (!limit) {
        // 新 IP，创建条目
        struct conn_limit new = {
            .src_ip = src_ip,
            .active_conns = 1,
            .last_seen = rte_rdtsc(),
        };
        rte_hash_add(t->by_ip, &src_ip, sizeof(src_ip), &new);
        return 0;
    }

    if (limit->active_conns >= t->max_conns_per_ip) {
        return -1;  // 拒绝
    }

    limit->active_conns++;
    limit->last_seen = rte_rdtsc();

    return 0;
}
```

## 5. Flow 跟踪

### 5.1 Flow 统计

```c
// Flow 统计
struct flow_stats {
    uint32_t packet_count;
    uint32_t byte_count;
    uint64_t first_seen;
    uint64_t last_seen;
    uint32_t flags;
};

// Flow 跟踪
struct flow_tracker {
    struct rte_hash *flows;
    uint32_t max_flows;
    uint64_t timeout;
};

// 添加 Flow
int
flow_add(struct flow_tracker *t,
         uint32_t src_ip, uint32_t dst_ip,
         uint16_t src_port, uint16_t dst_port,
         uint8_t proto)
{
    struct flow_key key = {
        .src_ip = src_ip,
        .dst_ip = dst_ip,
        .src_port = src_port,
        .dst_port = dst_port,
        .proto = proto,
    };

    struct flow_stats *stats;
    int ret = rte_hash_lookup_data(t->flows, &key, (void **)&stats);

    if (ret < 0) {
        // 新 Flow
        struct flow_stats new_stats = {
            .packet_count = 1,
            .byte_count = 0,
            .first_seen = rte_rdtsc(),
            .last_seen = rte_rdtsc(),
        };

        rte_hash_add(t->flows, &key, sizeof(key), &new_stats);
    } else {
        // 更新
        stats->packet_count++;
        stats->last_seen = rte_rdtsc();
    }

    return 0;
}
```

## 6. 缓解策略

### 6.1 分层防护

```
┌─────────────────────────────────────────────────────────────┐
│                    分层 DDoS 缓解                           │
│                                                              │
│  Layer 1: 边缘过滤                                           │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  - ACL 过滤                                       │  │
│  │  - Bogon 过滤                                    │  │
│  │  - Known bad IPs                                 │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│  Layer 2: 协议层                                            │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  - SYN Cookie                                      │  │
│  │  - Rate Limiting                                   │  │
│  │  - Connection Limits                               │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│  Layer 3: 应用层                                            │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  - Challenge-Response                             │  │
│  │  - JavaScript Challenge                           │  │
│  │  - CAPTCHA                                         │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 6.2 黑洞路由

```c
// 黑洞路由
void
add_blackhole_route(uint32_t ip)
{
    char cmd[256];
    // 添加 null route (黑洞)
    snprintf(cmd, sizeof(cmd),
             "ip route add blackhole %s/32", inet_ntoa(ip));
    system(cmd);
}

// FlowSpec
struct rte_flow *
create_flowspec_drop(uint32_t src_ip)
{
    struct rte_flow_attr attr = {
        .ingress = 1,
    };

    struct rte_flow_item pattern[] = {
        {
            .type = RTE_FLOW_ITEM_TYPE_IPV4,
            .spec = & (struct rte_flow_item_ipv4) {
                .hdr.src_addr = src_ip,
            },
            .mask = & (struct rte_flow_item_ipv4) {
                .hdr.src_addr = UINT32_MAX,
            },
        },
        {
            .type = RTE_FLOW_ITEM_TYPE_END,
        },
    };

    struct rte_flow_action actions[] = {
        {
            .type = RTE_FLOW_ACTION_TYPE_DROP,
        },
        {
            .type = RTE_FLOW_ITEM_TYPE_END,
        },
    };

    return rte_flow_create(port_id, &attr, pattern, actions, NULL);
}
```

## 7. 总结

DDoS 防护架构：

```
┌─────────────────────────────────────────────────────────────┐
│                    DPDK DDoS 防护                          │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Rate Limiter ───▶ Token Bucket                     │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  SYN Proxy ────▶ Syn Cookie                        │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Connection Tracker ───▶ Connection Limits          │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Flow Tracker ───▶ Anomaly Detection                │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  ACL / Flowspec ───▶ Blackhole                     │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

性能指标：

| 功能 | 性能 |
|------|------|
| **Rate Limiting** | ~100M pps |
| **SYN Cookie** | ~50M CPS |
| **Flow Tracking** | ~10M flows |
| **ACL** | ~50M rules |

---

## 参考资源

- [Syncookies](https://en.wikipedia.org/wiki/SYN_cookies)
- [DPDK Flow](https://doc.dpdk.org/guides/prog_guide/rte_flow.html)
- [RFC 4987 (SYN Flood)](https://tools.ietf.org/html/rfc4987)
