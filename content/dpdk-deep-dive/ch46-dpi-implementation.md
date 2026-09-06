---
title: "DPDK 第四十六章：DPI 深度包检测实现"
date: 2026-04-09 17:35:00
tags: [dpdk, dpi, deep-packet-inspection, intrusion-detection, pattern-matching]
description: "深入解析基于 DPDK 的 DPI 系统设计：协议识别、模式匹配引擎、签名检测、并行处理与硬件卸载"
---

# DPDK 第四十六章：DPI 深度包检测实现

> [!abstract] 核心要点
> DPI (Deep Packet Inspection) 是网络安全和流量分析的核心技术。本章讲解基于 DPDK 的 DPI 系统设计：协议识别、模式匹配、签名检测与性能优化。

## 1. DPI 概述

### 1.1 什么是 DPI

DPI 超越传统包过滤，深入检查**包内容**：

```
L2/L3/L4 (传统检测)：
  Header: [Src IP] [Dst IP] [Src Port] [Dst Port] [Protocol]
  Payload: [Encrypted/Any]

L7 DPI：
  Header: [完整 L2-L7 Header]
  Payload: [HTTP/SMTP/DNS/FTP ...] ← 深度解析
          [恶意签名/URL 过滤/内容审计]
```

### 1.2 DPI 应用场景

| 场景                 | 功能           |
| -------------------- | -------------- |
| **IDS/IPS**          | 入侵检测/防御  |
| **防火墙**           | 应用层过滤     |
| **流量监控**         | 用户行为分析   |
| **QoS**              | 应用识别与限速 |
| **数据防泄漏 (DLP)** | 敏感数据检测   |
| **恶意软件检测**     | 病毒/木马识别  |

### 1.3 DPI vs 传统检测

| 维度         | 包过滤      | DPI              |
| ------------ | ----------- | ---------------- |
| **检测深度** | Header only | Header + Payload |
| **协议识别** | Port-based  | 特征分析         |
| **准确性**   | 低          | 高               |
| **性能开销** | 低          | 高               |
| **隐私问题** | 无          | 有（需合规）     |

## 2. 协议识别

### 2.1 Port-based vs Deep Detection

```c
// 传统 Port-based 识别
enum protocol {
    PROTO_UNKNOWN,
    PROTO_HTTP,
    PROTO_HTTPS,
    PROTO_DNS,
    PROTO_SSH,
};

static enum protocol
identify_by_port(uint16_t port)
{
    switch (port) {
    case 80:   return PROTO_HTTP;
    case 443:  return PROTO_HTTPS;
    case 53:   return PROTO_DNS;
    case 22:   return PROTO_SSH;
    default:   return PROTO_UNKNOWN;
    }
}

// Port-based 问题：
// - HTTP 可以跑在 8080
// - HTTPS 可以跑在 4433
// - P2P 协议使用随机端口
```

### 2.2 深度协议识别

```c
// HTTP 特征检测
static enum protocol
identify_http(struct rte_mbuf *pkt)
{
    uint8_t *data = rte_pktmbuf_mtod(pkt, uint8_t *);

    // 检查 HTTP 方法
    if (memcmp(data, "GET ", 4) == 0 ||
        memcmp(data, "POST ", 5) == 0 ||
        memcmp(data, "HEAD ", 5) == 0 ||
        memcmp(data, "PUT ", 4) == 0) {
        return PROTO_HTTP;
    }

    // 检查 HTTP 响应
    if (memcmp(data, "HTTP/", 5) == 0) {
        return PROTO_HTTP;
    }

    return PROTO_UNKNOWN;
}

// DNS 检测
static enum protocol
identify_dns(struct rte_mbuf *pkt)
{
    struct ipv4_hdr *ip = get_ip_header(pkt);
    if (ip->next_proto_id != IPPROTO_UDP) return PROTO_UNKNOWN;

    struct udp_hdr *udp = get_udp_header(ip);
    if (!udp) return PROTO_UNKNOWN;

    // DNS 端口 53，UDP
    if (rte_be_to_cpu_16(udp->dst_port) == 53 ||
        rte_be_to_cpu_16(udp->src_port) == 53) {
        return PROTO_DNS;
    }

    return PROTO_UNKNOWN;
}
```

### 2.3 状态机协议识别

```c
// HTTP 分流状态机
enum http_parse_state {
    HTTP_IDLE,
    HTTP_REQ_LINE,
    HTTP_REQ_HEADERS,
    HTTP_REQ_BODY,
    HTTP_RES_LINE,
    HTTP_RES_HEADERS,
    HTTP_RES_BODY,
    HTTP_DONE,
};

struct http_session {
    uint32_t src_ip, dst_ip;
    uint16_t src_port, dst_port;

    uint8_t state;
    uint8_t flags;

    // 解析上下文
    uint32_t content_length;
    uint32_t body_received;
};

// 流表
struct flow_table {
    struct rte_hash *hash;
    struct http_session sessions[MAX_SESSIONS];
};
```

## 3. 模式匹配引擎

### 3.1 朴素匹配

```c
// 简单字符串匹配 (O(n*m))
static int
naive_match(const uint8_t *data, uint32_t data_len,
            const uint8_t *pattern, uint32_t pat_len)
{
    if (pat_len > data_len) return -1;

    for (uint32_t i = 0; i <= data_len - pat_len; i++) {
        bool match = true;
        for (uint32_t j = 0; j < pat_len; j++) {
            if (data[i + j] != pattern[j]) {
                match = false;
                break;
            }
        }
        if (match) return i;
    }

    return -1;
}
```

### 3.2 AC 自动机 (Aho-Corasick)

AC 自动机是多模式匹配的最佳选择：

```c
// AC 自动机节点
struct ac_node {
    uint8_t c;                      // 字符
    struct ac_node *next[256];      // goto
    struct ac_node *fail;           // failure link
    struct ac_node *output;          // output link

    uint32_t pattern_id;            // 匹配的 pattern ID (-1 = none)
    uint32_t depth;
};

// 构建 AC 自动机
struct ac_automaton {
    struct ac_node *root;
    uint32_t num_nodes;
    struct rte_mempool *node_pool;
};

static void
ac_insert(struct ac_automaton *ac, const uint8_t *pattern,
          uint32_t pat_len, uint32_t id)
{
    struct ac_node *node = ac->root;

    for (uint32_t i = 0; i < pat_len; i++) {
        uint8_t c = pattern[i];

        if (node->next[c] == NULL) {
            node->next[c] = ac_alloc_node(ac, c);
        }
        node = node->next[c];
    }

    node->pattern_id = id;
}

// 构建 failure 函数
static void
ac_build_failure(struct ac_automaton *ac)
{
    // BFS 构建 failure links
    queue_t q;

    // root 的 failure = root
    ac->root->fail = ac->root;

    // 第一层的 failure = root
    for (c = 0; c < 256; c++) {
        if (ac->root->next[c]) {
            ac->root->next[c]->fail = ac->root;
            enqueue(&q, ac->root->next[c]);
        } else {
            ac->root->next[c] = ac->root;  // 虚拟边
        }
    }

    while (!queue_empty(&q)) {
        struct ac_node *v = dequeue(&q);

        for (c = 0; c < 256; c++) {
            struct ac_node *u = v->next[c];
            if (u == NULL) continue;

            struct ac_node *f = v->fail;
            while (f != f->next[c] && f->next[c] == NULL) {
                f = f->fail;
            }

            u->fail = f->next[c];
            if (u->fail->pattern_id >= 0) {
                u->output = u->fail;
            }

            enqueue(&q, u);
        }
    }
}

// AC 匹配
static int
ac_search(struct ac_automaton *ac, const uint8_t *data,
          uint32_t data_len, match_callback_t callback, void *ctx)
{
    struct ac_node *node = ac->root;
    int num_matches = 0;

    for (uint32_t i = 0; i < data_len; i++) {
        uint8_t c = data[i];

        while (node != node->next[c] && node->next[c] == NULL) {
            node = node->fail;
        }
        node = node->next[c];

        // 输出所有匹配
        struct ac_node *o = node;
        while (o != ac->root) {
            if (o->pattern_id >= 0) {
                callback(o->pattern_id, i - o->depth + 1, ctx);
                num_matches++;
            }
            o = o->output;
        }
    }

    return num_matches;
}
```

## 4. 签名检测

### 4.1 Snort 格式签名

```c
// Snort 规则示例
// alert tcp $HOME_NET any -> $EXTERNAL_NET 80 (msg:"MALWARE malware.exe"; \
//    content:"GET /malware.exe"; http_uri; sid:1000001; rev:1;)

// 解析 Snort 规则
struct signature {
    uint32_t sid;                    // Signature ID
    uint8_t protocol;                // TCP/UDP/ICMP/IP
    uint8_t direction;                // -> / <- / <>
    uint32_t src_net, src_mask;
    uint32_t dst_net, dst_mask;
    uint16_t src_port_low, src_port_high;
    uint16_t dst_port_low, dst_port_high;

    // 检测选项
    struct detection_option *options;
    uint32_t num_options;
};

struct detection_option {
    uint8_t type;                    // content, http_uri, etc.
    uint8_t negation;
    uint32_t offset, depth;
    uint8_t *pattern;
    uint32_t pattern_len;
};
```

### 4.2 HTTP 签名检测

```c
// HTTP URI 签名
static int
detect_http_uri(struct dpi_context *ctx, struct rte_mbuf *pkt,
                struct signature *sig)
{
    // 获取 HTTP payload
    uint8_t *payload;
    uint32_t payload_len = get_http_uri(pkt, &payload);
    if (payload_len == 0) return 0;

    // 遍历签名
    for (int i = 0; i < sig->num_options; i++) {
        struct detection_option *opt = &sig->options[i];

        switch (opt->type) {
        case OPT_CONTENT:
            if (memmem(payload, payload_len,
                       opt->pattern, opt->pattern_len)) {
                return 1;  // 匹配
            }
            break;

        case OPT_HTTP_URI:
            // HTTP URI 规范化
            if (http_uri_normalize(payload, payload_len)) {
                if (memmem(normalized, norm_len,
                           opt->pattern, opt->pattern_len)) {
                    return 1;
                }
            }
            break;

        case OPT_PCRE:
            if (pcre_match(opt->pcre, payload, payload_len)) {
                return 1;
            }
            break;
        }
    }

    return 0;
}
```

## 5. 并行处理

### 5.1 Flow-based 并行

```c
// Flow 分配到 Worker
static uint16_t
get_worker_for_flow(struct rte_hash *flow_hash,
                     uint32_t src_ip, uint16_t src_port,
                     uint32_t dst_ip, uint16_t dst_port)
{
    struct flow_key key = {
        .src_ip = src_ip,
        .src_port = src_port,
        .dst_ip = dst_ip,
        .dst_port = dst_port,
    };

    uint32_t hash = rte_hash_hash(flow_hash, &key);

    // 确保同一 flow 总是分配到同一 worker
    return hash % num_workers;
}

// Worker 线程处理
static int
worker_loop(void *arg)
{
    struct worker_context *ctx = arg;
    uint16_t worker_id = ctx->worker_id;

    while (ctx->running) {
        // 从各自的 RX 队列收包
        uint16_t nb_rx = rte_eth_rx_burst(ctx->port_id,
                                          worker_id,  // 队列绑定 worker
                                          ctx->pkts, MAX_PKT_BURST);

        for (uint16_t i = 0; i < nb_rx; i++) {
            process_dpi(ctx, ctx->pkts[i]);
        }

        // TX
        uint16_t nb_tx = rte_eth_tx_burst(ctx->port_id,
                                          worker_id,
                                          ctx->pkts, nb_rx);
    }

    return 0;
}
```

### 5.2 批量处理优化

```c
// 批量 AC 搜索
static void
ac_search_batch(struct ac_automaton *ac,
                struct rte_mbuf **pkts, uint16_t nb_pkts,
                match_callback_t callback, void *ctx)
{
    for (uint16_t i = 0; i < nb_pkts; i++) {
        struct rte_mbuf *pkt = pkts[i];
        uint8_t *data = rte_pktmbuf_mtod(pkt, uint8_t *);
        uint32_t len = rte_pktmbuf_pktlen(pkt);

        ac_search(ac, data, len, callback, ctx);
    }

    // 或者 SIMD 批量处理
    // SIMD_AC_batch_search(ac, pkts, nb_pkts, callback, ctx);
}
```

## 6. 硬件卸载

### 6.1 NDRNG/RegEx 卸载

```c
// Intel NDRNG (Network Dictionary Lookup)
#include <ndrng.h>

struct ndrng_pattern {
    uint8_t *pattern;
    uint32_t pattern_len;
    uint32_t id;
};

static int
setup_ndrng(struct dpi_context *ctx,
            struct ndrng_pattern *patterns, uint32_t num)
{
    struct ndrng_conf ndrng_conf = {
        .num_patterns = num,
        .mode = NDRNG_MODE_DPI,
    };

    ctx->ndrng = ndrng_create(&ndrng_conf);

    for (uint32_t i = 0; i < num; i++) {
        ndrng_add_pattern(ctx->ndrng,
                          patterns[i].pattern,
                          patterns[i].pattern_len,
                          patterns[i].id);
    }

    ndrng_enable(ctx->ndrng);
    return 0;
}

// 使用 NDRNG 检测
static int
detect_with_ndrng(struct dpi_context *ctx, struct rte_mbuf *pkt)
{
    struct ndrng_job *job = ndrng_alloc_job(ctx->ndrng);

    ndrng_job_set_buf(job,
                      rte_pktmbuf_mtod(pkt, void *),
                      rte_pktmbuf_pktlen(pkt));

    ndrng_submit(ctx->ndrng, job);
    ndrng_process(ctx->ndrng);

    // 获取结果
    struct ndrng_result *result = ndrng_get_result(job);

    if (result->num_matches > 0) {
        for (int i = 0; i < result->num_matches; i++) {
            // 处理匹配
            handle_match(result->matches[i].pattern_id);
        }
    }

    ndrng_free_job(job);
    return result->num_matches;
}
```

## 7. 实际案例：IDS/IPS

### 7.1 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    DPI-based IDS                            │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │                    Packet Capture                    │   │
│  │                 (AF_XDP / DPDK)                      │   │
│  └────────────────────────┬─────────────────────────────┘   │
│                           │                                  │
│  ┌────────────────────────▼─────────────────────────────┐   │
│  │                  Flow Dissector                       │   │
│  │              (L2-L4 Header Parse)                     │   │
│  └────────────────────────┬─────────────────────────────┘   │
│                           │                                  │
│  ┌────────────────────────▼─────────────────────────────┐   │
│  │                  Protocol ID                         │   │
│  │            (Port / Deep Inspection)                  │   │
│  └────────────────────────┬─────────────────────────────┘   │
│                           │                                  │
│  ┌────────────────────────▼─────────────────────────────┐   │
│  │                  Pattern Match                        │   │
│  │               (AC / NDRNG / RegEx)                    │   │
│  └────────────────────────┬─────────────────────────────┘   │
│                           │                                  │
│  ┌────────────────────────▼─────────────────────────────┐   │
│  │                  Alert / Drop                        │   │
│  │             (Log / Block / Pass)                     │   │
│  └───────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 7.2 完整处理流程

```c
static enum dpi_action
process_packet_ids(struct dpi_context *ctx, struct rte_mbuf *pkt)
{
    // 1. 解析 L2-L4
    struct ether_hdr *eth = rte_pktmbuf_mtod(pkt, struct ether_hdr *);
    if (eth->ether_type != rte_cpu_to_be_16(RTE_ETHER_TYPE_IPV4)) {
        return DPI_PASS;
    }

    struct ipv4_hdr *ip = (struct ipv4_hdr *)(eth + 1);

    // 2. 获取 payload
    uint32_t payload_len = rte_pktmbuf_pktlen(pkt) -
                           (sizeof(*eth) + sizeof(*ip));
    uint8_t *payload = (uint8_t *)(ip + 1);

    // 3. 协议识别
    enum protocol proto = identify_protocol(ip, payload, payload_len);

    // 4. 签名匹配
    struct signature **sigs = get_signatures_for_proto(proto);

    for (int i = 0; sigs[i] != NULL; i++) {
        if (match_signature(sigs[i], ip, payload, payload_len)) {
            // 5. 触发告警
            alert(ctx->ids_alert_queue, sigs[i], pkt);

            if (sigs[i]->action == SIG_DROP) {
                return DPI_DROP;
            }
        }
    }

    return DPI_PASS;
}
```

## 8. 总结

DPI 系统设计要点：

1. **协议识别**：Port-based + Deep inspection 结合
2. **模式匹配**：AC 自动机是多模式匹配首选
3. **签名格式**：兼容 Snort/Suricata 规则
4. **并行处理**：Flow-based + Batch 优化
5. **硬件卸载**：NDRNG/RegEx 加速

---

## 参考资源

- [Snort 规则](https://www.snort.org/rules)
- [Suricata IDS](https://suricata.io/)
- [Intel NDRNG](https://www.intel.com/content/www/us/en/products/docs/network-io/programmable-standard-network/ndrng-product-brief.html)
