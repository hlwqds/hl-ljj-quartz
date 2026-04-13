---
title: "DPDK 第四十五章：DPDK L4/L7 负载均衡器设计"
date: 2026-04-09 17:30:00
tags: [dpdk, load-balancer, l4, l7, nat, session, forwarding]
description: "深入解析基于 DPDK 的负载均衡器设计：L4 NAT/LVS 模式、L7 HTTP 负载均衡、会话保持、Health Check 与高可用"
---

# DPDK 第四十五章：DPDK L4/L7 负载均衡器设计

> [!abstract] 核心要点
> 负载均衡器是 DPDK 最典型的应用场景之一。本章讲解基于 DPDK 的 L4 NAT 负载均衡器和 L7 HTTP 负载均衡器的架构设计与实现。

## 1. 负载均衡器概述

### 1.1 分类

| 类型 | 层 | 说明 |
|------|---|------|
| **L4 NAT** | 传输层 | 基于 IP + Port 做 NAT 转发 |
| **L4 LB** | 传输层 | 基于 Connection 做负载分配 |
| **L7 HTTP** | 应用层 | 基于 HTTP URL/Cookie 做路由 |
| **GSLB** | DNS 层 | 全局负载，跨数据中心 |

### 1.2 L4 vs L7

```
L4 负载均衡：
  Client → VIP:80 → LB → Backend:Port
           (仅修改 IP/Port)

L7 负载均衡：
  Client → VIP:80 → LB → [Parse HTTP] → Backend:8080/path
           (需要解析 HTTP Header)
```

## 2. L4 NAT 负载均衡器

### 2.1 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    L4 NAT Load Balancer                     │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │                   VIP (Virtual IP)                   │   │
│  │                   203.0.113.10:80                     │   │
│  └────────────────────────┬─────────────────────────────┘   │
│                           │                                  │
│  ┌────────────────────────▼─────────────────────────────┐   │
│  │                   NAT Table                           │   │
│  │  203.0.113.10:80 ↔ 10.0.0.1:8080                    │   │
│  │  203.0.113.10:80 ↔ 10.0.0.2:8080                    │   │
│  │  203.0.113.10:80 ↔ 10.0.0.3:8080                    │   │
│  └────────────────────────┬─────────────────────────────┘   │
│                           │                                  │
│         ┌─────────────────┼─────────────────┐              │
│         ▼                 ▼                 ▼              │
│  ┌─────────────┐   ┌─────────────┐   ┌─────────────┐     │
│  │  Backend 1  │   │  Backend 2  │   │  Backend 3  │     │
│  │ 10.0.0.1    │   │ 10.0.0.2    │   │ 10.0.0.3    │     │
│  │   :8080     │   │   :8080     │   │   :8080     │     │
│  └─────────────┘   └─────────────┘   └─────────────┘     │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 核心数据结构

```c
// NAT 表项
struct nat_entry {
    uint32_t vip;          // Virtual IP
    uint16_t vport;        // Virtual Port
    uint32_t rip;          // Real (Backend) IP
    uint16_t rport;        // Real Port
    uint8_t proto;          // TCP/UDP

    // 元数据
    uint64_t last_active;   // 最后活跃时间
    uint16_t idle_timeout; // 空闲超时
    uint8_t  state;         // 会话状态
};

// 连接跟踪
struct conntrack_entry {
    uint32_t src_ip;
    uint16_t src_port;
    uint32_t dst_ip;
    uint16_t dst_port;
    uint8_t  proto;

    uint32_t nat_ip;       // NAT 后的 IP
    uint16_t nat_port;

    uint64_t start_time;
    uint32_t flags;
};
```

### 2.3 数据包处理

```c
// L4 NAT 处理函数
static inline void
process_packet_nat(struct rte_mbuf *pkt,
                   struct nat_entry *entry,
                   uint16_t *tx_queue_id)
{
    // 获取网络头
    struct ether_hdr *eth = rte_pktmbuf_mtod(pkt, struct ether_hdr *);
    struct ipv4_hdr *ip = (struct ipv4_hdr *)(eth + 1);
    struct tcpudp_hdr *tcp = (struct tcpudp_hdr *)((char *)ip + sizeof(struct ipv4_hdr));

    // 修改目的地址 (DNAT)
    ip->dst_addr = rte_cpu_to_be_32(entry->rip);
    tcp->dst_port = rte_cpu_to_be_16(entry->rport);

    // 重新计算 checksum
    ip->hdr_checksum = 0;
    ip->hdr_checksum = rte_ipv4_cksum(ip);

    // TCP checksum 需要完整 L4
    tcp->cksum = 0;
    tcp->cksum = rte_ipv4_udptcp_cksum(ip, tcp);

    // 查找对应的 MAC（ARP 或预先配置）
    struct arp_entry *arp = arp_lookup(entry->rip);
    memcpy(eth->dst_addr, arp->mac, 6);

    // 释放 NAT 引用
    nat_entry_put(entry);
}
```

### 2.4 负载均衡算法

```c
// 1. Round Robin
struct backend *
select_backend_rr(struct lb_context *ctx)
{
    ctx->next_backend = (ctx->next_backend + 1) % ctx->num_backends;
    return &ctx->backends[ctx->next_backend];
}

// 2. Least Connections
struct backend *
select_backend_lc(struct lb_context *ctx)
{
    struct backend *best = NULL;
    uint32_t min_conn = UINT32_MAX;

    for (int i = 0; i < ctx->num_backends; i++) {
        if (ctx->backends[i].active &&
            ctx->backends[i].num_conn < min_conn) {
            best = &ctx->backends[i];
            min_conn = best->num_conn;
        }
    }
    return best;
}

// 3. Source IP Hash
struct backend *
select_backend_hash(struct lb_context *ctx, uint32_t src_ip)
{
    uint32_t hash = rte_hash_hash(ctx->ip_hash_ctx, &src_ip);
    uint32_t idx = hash % ctx->num_backends;
    return &ctx->backends[idx];
}

// 4. Consistent Hash
struct backend *
select_backend_consistent_hash(struct lb_context *ctx, uint32_t src_ip)
{
    uint64_t key = ((uint64_t)src_ip << 32) | (src_ip ^ 0xFFFFFFFF);
    return (struct backend *)rte_ring_lookup(ctx->consistent_ring, key);
}
```

## 3. L7 HTTP 负载均衡器

### 3.1 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    L7 HTTP Load Balancer                     │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │                   VIP:80                              │   │
│  └────────────────────────┬─────────────────────────────┘   │
│                           │                                  │
│  ┌────────────────────────▼─────────────────────────────┐   │
│  │                  HTTP Parser                           │   │
│  │  - Parse Request Line                                 │   │
│  │  - Parse Headers                                      │   │
│  │  - Route based on: URL/Cookie/Header                   │   │
│  └────────────────────────┬─────────────────────────────┘   │
│                           │                                  │
│  ┌────────────────────────▼─────────────────────────────┐   │
│  │                  Backend Pool                          │   │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐             │   │
│  │  │ /api/*   │  │ /static/*│  │  /      │             │   │
│  │  │ → B1,B2  │  │ → B3,B4  │  │ → B1-B4 │             │   │
│  │  └──────────┘  └──────────┘  └──────────┘             │   │
│  └───────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 HTTP 解析

```c
// HTTP 请求解析状态机
enum http_parser_state {
    HTTP_INIT,
    HTTP_METHOD,
    HTTP_URL,
    HTTP_VERSION,
    HTTP_HEADER_KEY,
    HTTP_HEADER_VALUE,
    HTTP_BODY,
    HTTP_DONE,
};

struct http_parser {
    uint8_t state;
    uint16_t method_len;
    uint16_t url_len;
    uint16_t host_len;

    char method[16];
    char url[256];
    char host[64];
    char cookie[256];
    char *body;

    uint32_t content_length;
    uint32_t body_read;
};

static inline int
parse_http_request(struct rte_mbuf *pkt, struct http_parser *parser)
{
    uint8_t *data = rte_pktmbuf_mtod(pkt, uint8_t *);
    uint16_t len = rte_pktmbuf_pktlen(pkt);

    for (uint16_t i = 0; i < len && parser->state != HTTP_DONE; i++) {
        char c = data[i];

        switch (parser->state) {
        case HTTP_INIT:
            parser->state = HTTP_METHOD;
            parser->method[0] = c;
            parser->method_len = 1;
            break;

        case HTTP_METHOD:
            if (c == ' ') {
                parser->method[parser->method_len] = '\0';
                parser->state = HTTP_URL;
                parser->url_len = 0;
            } else {
                parser->method[++parser->method_len] = c;
            }
            break;

        case HTTP_URL:
            if (c == ' ') {
                parser->url[parser->url_len] = '\0';
                parser->state = HTTP_VERSION;
            } else {
                parser->url[parser->url_len++] = c;
            }
            break;

        // ... 其他状态处理
        }
    }

    return (parser->state == HTTP_DONE) ? 0 : -1;
}
```

### 3.3 L7 路由规则

```c
// 路由规则
struct l7_route_rule {
    enum {
        L7_RULE_PREFIX,    // URL 前缀
        L7_RULE_EXACT,     // 精确匹配
        L7_RULE_REGEX,     // 正则匹配
        L7_RULE_HEADER,    // Header 匹配
        L7_RULE_COOKIE,    // Cookie 匹配
    } type;

    char *pattern;         // 匹配模式
    struct backend_pool *pool;  // 目标 pool
};

// URL 路由
static struct backend *
route_l7_request(struct http_parser *parser)
{
    // 检查规则优先级
    for (int i = 0; i < num_rules; i++) {
        struct l7_route_rule *rule = &rules[i];

        switch (rule->type) {
        case L7_RULE_PREFIX:
            if (strncmp(parser->url, rule->pattern,
                        strlen(rule->pattern)) == 0) {
                return select_backend(rule->pool);
            }
            break;

        case L7_RULE_HEADER:
            if (strcmp(parser->host, rule->pattern) == 0) {
                return select_backend(rule->pool);
            }
            break;

        case L7_RULE_COOKIE:
            if (match_cookie(parser->cookie, rule->pattern)) {
                return select_backend(rule->pool);
            }
            break;
        }
    }

    // 默认 pool
    return select_backend(&default_pool);
}
```

## 4. 会话保持 (Session Persistence)

### 4.1 基于 Cookie

```c
// 插入 cookie
static void
insert_sticky_cookie(struct rte_mbuf *pkt,
                     struct backend *backend,
                     uint32_t conn_id)
{
    // 在 HTTP 响应中插入 Set-Cookie
    char cookie_header[128];
    snprintf(cookie_header, sizeof(cookie_header),
             "Set-Cookie: LBID=%08x; Path=/; Max-Age=3600\r\n",
             conn_id);

    // 修改包，插入 Header
    insert_http_header(pkt, cookie_header);
}
```

### 4.2 基于 Source IP

```c
// Source IP Hash 会话保持
static struct backend *
get_sticky_backend(struct lb_context *ctx, uint32_t src_ip)
{
    // 查找已有的映射
    struct sticky_entry *entry;
    HASH_FIND(hh, ctx->sticky_table, &src_ip,
              sizeof(src_ip), entry);

    if (entry) {
        return entry->backend;
    }

    // 新建映射
    struct backend *b = select_backend(ctx);
    entry = rte_malloc(NULL, sizeof(*entry), 0);
    entry->src_ip = src_ip;
    entry->backend = b;

    HASH_ADD(hh, ctx->sticky_table, src_ip,
             sizeof(src_ip), entry);

    return b;
}
```

## 5. Health Check

### 5.1 健康检查类型

| 类型 | 说明 | 频率 |
|------|------|------|
| **TCP Connect** | 尝试三次握手 | 5-30s |
| **HTTP GET** | GET /health | 5-30s |
| **HTTPS** | TLS 握手 | 5-30s |
| **Ping** | ICMP | 1-10s |
| **TCP Half-Open** | SYN + RST | 1-10s |

### 5.2 健康检查实现

```c
// 健康检查线程
static void
health_check_thread(void *arg)
{
    struct lb_context *ctx = arg;

    while (ctx->running) {
        // 遍历所有 backend
        for (int i = 0; i < ctx->num_backends; i++) {
            struct backend *b = &ctx->backends[i];

            // 发送探测
            int healthy = false;

            switch (b->check_type) {
            case HEALTH_TCP:
                healthy = check_tcp(b->ip, b->port);
                break;
            case HEALTH_HTTP:
                healthy = check_http(b->ip, b->port, b->check_path);
                break;
            case HEALTH_HTTPS:
                healthy = check_https(b->ip, b->port);
                break;
            }

            // 更新状态
            if (healthy != b->healthy) {
                b->healthy = healthy;
                b->last_change = rte_get_tsc_Hz();

                // 触发告警
                if (!healthy) {
                    RTE_LOG(WARNING, LB,
                            "Backend %s:%d is DOWN\n",
                            inet_ntoa(b->ip), b->port);
                }
            }
        }

        rte_delay_ms(ctx->check_interval);
    }
}

// TCP 健康检查
static int
check_tcp(uint32_t ip, uint16_t port)
{
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) return -1;

    struct sockaddr_in addr;
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    addr.sin_addr.s_addr = ip;

    // 设置超时
    struct timeval tv = { .tv_sec = 3, .tv_usec = 0 };
    setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    int ret = connect(sock, (struct sockaddr *)&addr, sizeof(addr));
    close(sock);

    return (ret == 0) ? true : false;
}
```

## 6. 高可用

### 6.1 VRRP/Keepalived

```c
// VRRP 状态
enum vrrp_state {
    VRRP_STATE_BACKUP,
    VRRP_STATE_MASTER,
};

// 发送 VRRP advertisement
static void
send_vrrp_advert(struct lb_context *ctx)
{
    struct rte_mbuf *pkt = rte_pktmbuf_alloc(ctx->mbuf_pool);

    // 构造 VRRP packet (IP proto 112)
    struct ipv4_hdr *ip = rte_pktmbuf_mtod(pkt, struct ipv4_hdr *);
    ip->dst_addr = rte_cpu_to_be_32(224.0.0.18);  // VRRP multicast

    struct vrrp_hdr *vrrp = (struct vrrp_hdr *)(ip + 1);
    vrrp->version_type = 0x21;  // VRRPv2, Advertisement
    vrrp->vrid = ctx->vrid;
    vrrp->priority = ctx->priority;  // 100 = master, 80 = backup
    vrrp->adv_int = htons(1);  // 1 second

    // 发送到 NIC
    rte_eth_tx_burst(ctx->tx_port, 0, &pkt, 1);
}
```

### 6.2 故障切换

```c
// 检测 master 故障
static void
check_vrrp_master(void *arg)
{
    struct lb_context *ctx = arg;
    uint64_t last_advert = ctx->last_master_advert;

    while (ctx->running) {
        uint64_t now = rte_get_tsc_ms();

        if (ctx->state == VRRP_STATE_BACKUP) {
            // 检查 master 是否存活
            if (now - last_advert > 3000) {  // 3 秒无 advert
                // Master 故障，切换
                become_master(ctx);
            }
        }

        rte_delay_ms(100);
    }
}
```

## 7. 性能优化

### 7.1 连接复用

```c
// TCP 连接池 (避免每次都新建连接)
struct connection_pool {
    struct rte_ring *free_conns;
    struct rte_hash *active_conns;
};

static int
reuse_connection(struct lb_context *ctx,
                 uint32_t src_ip, uint16_t src_port,
                 uint32_t dst_ip, uint16_t dst_port)
{
    struct conn_key key = { src_ip, src_port, dst_ip, dst_port };

    struct connection *conn;
    HASH_FIND(hh, ctx->active_conns, &key,
              sizeof(key), conn);

    if (conn && conn->backend->healthy) {
        // 复用已有连接
        conn->last_use = rte_get_tsc_Hz();
        return 0;
    }

    return -1;  // 需要新建连接
}
```

## 8. 总结

DPDK 负载均衡器设计要点：

1. **L4 vs L7**：L4 简单高效，L7 灵活
2. **NAT 表**：高效查找是关键（hash/RCU）
3. **负载算法**：RR/LC/Hash/Consistent Hash
4. **会话保持**：Cookie/Source IP
5. **健康检查**：多协议探测
6. **高可用**：VRRP 故障切换

---

## 参考资源

- [DPDK Load Balancer 示例](https://doc.dpdk.org/guides/sample_app_ug/link_status_polling.html)
- [Zen Load Balancer](https://github.com/blueperf/loadbalancer)
