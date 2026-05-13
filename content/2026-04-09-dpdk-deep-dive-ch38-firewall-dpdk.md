---
title: "DPDK 深度探索 ch38：防火墙加速"
date: 2026-04-10 14:30:00
tags: [dpdk, firewall, acl, stateless, stateful, conntrack, offload]
description: "深入解析 DPDK 防火墙：ACL、状态防火墙、连接追踪、NAT 与防火墙规则加速"
---

# DPDK 深度探索 ch38：防火墙加速

> [!abstract] 核心要点
> 防火墙是网络安全的基础。DPDK 可加速防火墙处理，本章深入解析 ACL、状态防火墙、连接追踪、NAT 与规则匹配。

## 1. 防火墙类型

### 1.1 无状态 vs 有状态

```
┌─────────────────────────────────────────────────────────────┐
│                    无状态防火墙                             │
│                                                              │
│  - 基于单个包的特征                                        │
│  - 源/目的 IP, 端口, 协议                                 │
│  - 不跟踪连接状态                                         │
│  - 简单快速                                               │
│                                                              │
│  示例规则：                                                │
│  deny tcp from any to any 22                              │
│                                                              │
├─────────────────────────────────────────────────────────────┤
│                    有状态防火墙                             │
│                                                              │
│  - 跟踪连接状态                                           │
│  - 基于会话决策                                           │
│  - 可以跟踪 TCP 状态                                      │
│  - 更智能但更复杂                                         │
│                                                              │
│  连接状态：                                                │
│  NEW → ESTABLISHED → RELATED → CLOSED                     │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 防火墙类型对比

| 特性         | 无状态 | 有状态 |
| ------------ | ------ | ------ |
| **性能**     | 极高   | 中     |
| **内存**     | 低     | 高     |
| **协议感知** | ❌     | ✅     |
| **TCP 状态** | ❌     | ✅     |
| **规则数**   | 多     | 少     |

## 2. ACL (Access Control List)

### 2.1 DPDK ACL

```c
// DPDK ACL 库
#include <rte_acl.h>

// ACL 规则
struct rte_acl_rule {
    struct rte_acl_ipv4vlan ipv4;

    // 协议
    uint8_t proto;              // TCP, UDP, ICMP

    // 端口范围
    uint16_t src_port_low;
    uint16_t src_port_high;
    uint16_t dst_port_low;
    uint16_t dst_port_high;

    // 动作
    uint8_t category_mask;     // 类别掩码
    uint32_t priority;         // 优先级
    int32_t action;            // PERMIT or DENY
};

// 创建 ACL 上下文
struct rte_acl_ctx *
create_acl_ctx(void)
{
    struct rte_acl_param param = {
        .name = "firewall_acl",
        .socket_id = 0,
        .rule_size = sizeof(struct rte_acl_rule),
        .max_rule_count = 1024,
    };

    struct rte_acl_ctx *ctx = rte_acl_create(&param);

    // 配置
    struct rte_acl_config cfg = {
        .num_categories = 1,
        .num_fields = RTE_ACL_IPV4VLAN_NUM_FIELDS,
    };

    rte_acl_config(ctx, &cfg);

    return ctx;
}
```

### 2.2 ACL 规则添加

```c
// 添加 ACL 规则
int
add_acl_rule(struct rte_acl_ctx *ctx)
{
    struct rte_acl_rule rules[] = {
        {
            // 允许 SSH
            .ipv4 = {
                .src = {.ip = 0, .mask = 0},
                .dst = {.ip = 0, .mask = 0},
            },
            .proto = 6,  // TCP
            .src_port_low = 22,
            .src_port_high = 22,
            .dst_port_low = 0,
            .dst_port_high = 65535,
            .priority = 10,
            .action = RTE_ACL_PERMIT,
        },
        {
            // 拒绝所有
            .ipv4 = {
                .src = {.ip = 0, .mask = 0},
                .dst = {.ip = 0, .mask = 0},
            },
            .proto = 0,  // ANY
            .src_port_low = 0,
            .src_port_high = 65535,
            .dst_port_low = 0,
            .dst_port_high = 65535,
            .priority = 1,
            .action = RTE_ACL_DENY,
        },
    };

    rte_acl_add_rules(ctx, rules, 2);

    // 构建 ACL
    rte_acl_build(ctx, NULL);

    return 0;
}
```

### 2.3 ACL 查询

```c
// ACL 查找
enum {
    CAT0 = 0,
};

int
acl_lookup(struct rte_acl_ctx *ctx,
           struct rte_mbuf *mbuf)
{
    struct rte_acl_ipv4vlan tripple;

    struct ipv4_hdr *ip = rte_pktmbuf_mtod(mbuf, struct ipv4_hdr *);

    // 填充搜索键
    tripple.field[RTE_ACL_IPV4VLAN_SRC_SRC_PORT].u32 =
        ip->src_addr;
    tripple.field[RTE_ACL_IPV4VLAN_DST].u32 =
        ip->dst_addr;
    tripple.field[RTE_ACL_IPV4VLAN_PROTO].u8 =
        ip->next_proto_id;

    if (ip->next_proto_id == 6) {  // TCP
        struct tcp_hdr *tcp =
            (struct tcp_hdr *)(ip + 1);
        tripple.field[RTE_ACL_IPV4VLAN_SRC_SRC_PORT].u16 =
            tcp->src_port;
        tripple.field[RTE_ACL_IPV4VLAN_DST_DST_PORT].u16 =
            tcp->dst_port;
    }

    // 查找
    uint32_t results[1];
    int category = CAT0;

    rte_acl_lookup(ctx, &tripple, results, category, 1);

    return results[0] == RTE_ACL_PERMIT ? 0 : -1;
}
```

## 3. 连接追踪 (Conntrack)

### 3.1 连接状态

```
┌─────────────────────────────────────────────────────────────┐
│                    TCP 连接状态                             │
│                                                              │
│  CLOSED ──▶ LISTEN ──▶ SYN_RECEIVED ──▶ ESTABLISHED        │
│                 ↑         │                   │              │
│                 │         ↓                   ↓              │
│                 └───── SYN_SENT ────▶ CLOSE_WAIT           │
│                                       │     │               │
│                                       ↓     ↓               │
│                                    LAST_ACK ──▶ CLOSED       │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                    防火墙连接状态                           │
│                                                              │
│  NEW:        第一个包 (SYN)                                │
│  ESTABLISHED: 双向会话中                                    │
│  RELATED:     关联新连接 (FTP data, ICMP error)            │
│  INVALID:     无法识别的包                                  │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 连接追踪表

```c
// 连接追踪条目
struct conntrack_entry {
    uint32_t src_ip;
    uint32_t dst_ip;
    uint16_t src_port;
    uint16_t dst_port;
    uint8_t proto;              // TCP, UDP, ICMP

    // 方向
    enum conntrack_state {
        CT_NONE,
        CT_NEW,
        CT_ESTABLISHED,
        CT_RELATED,
        CT_INVALID,
    } state;

    // TCP 特定
    uint8_t tcp_state;
    uint32_t tcp_seq_syn;
    uint32_t tcp_seq_ack;

    // 超时
    uint64_t last_seen;
    uint32_t timeout;
};

// 连接追踪表
struct conntrack_table {
    struct rte_hash *connections;
};

// 查找连接
struct conntrack_entry *
conntrack_lookup(struct conntrack_table *ct,
                 uint32_t src_ip, uint32_t dst_ip,
                 uint16_t src_port, uint16_t dst_port,
                 uint8_t proto)
{
    struct ct_key key = {
        .src_ip = src_ip,
        .dst_ip = dst_ip,
        .src_port = src_port,
        .dst_port = dst_port,
        .proto = proto,
    };

    return rte_hash_lookup_data(ct->connections, &key);
}
```

### 3.3 连接更新

```c
// 处理 TCP 包
int
process_tcp_packet(struct conntrack_table *ct,
                    struct rte_mbuf *mbuf,
                    struct tcp_hdr *tcp)
{
    uint32_t src_ip, dst_ip;
    uint16_t src_port, dst_port;

    // 解析 IP 和端口
    parse_ip_tcp(mbuf, &src_ip, &dst_ip,
                  &src_port, &dst_port);

    // 查找连接
    struct conntrack_entry *entry =
        conntrack_lookup(ct, src_ip, dst_ip,
                        src_port, dst_port, IPPROTO_TCP);

    if (!entry) {
        // 新连接
        if (tcp->tcp_flags & RTE_TCP_SYN_FLAG &&
            !(tcp->tcp_flags & RTE_TCP_ACK_FLAG)) {
            // SYN, 新建连接
            entry = conntrack_create(ct, src_ip, dst_ip,
                                      src_port, dst_port);
            entry->state = CT_NEW;
            entry->tcp_state = TCP_SYN_SENT;
        } else {
            return -1;  // 丢弃
        }
    } else {
        // 更新状态
        switch (entry->tcp_state) {
        case TCP_SYN_SENT:
            if (tcp->tcp_flags & RTE_TCP_SYN_FLAG &&
                tcp->tcp_flags & RTE_TCP_ACK_FLAG) {
                entry->tcp_state = TCP_ESTABLISHED;
                entry->state = CT_ESTABLISHED;
            }
            break;
        // ...
        }
    }

    return 0;
}
```

## 4. NAT (网络地址转换)

### 4.1 NAT 类型

```
┌─────────────────────────────────────────────────────────────┐
│                    NAT 类型                                 │
│                                                              │
│  SNAT (源 NAT):                                             │
│  内部 ──────────────────────────────── 外部                  │
│  10.0.0.2:12345 ────▶ 203.0.113.10:54321                  │
│                                                              │
│  DNAT (目标 NAT):                                           │
│  外部 ──────────────────────────────── 内部                  │
│  203.0.113.10:80 ────▶ 10.0.0.2:80                        │
│                                                              │
│  PAT (端口地址转换):                                        │
│  多个内部 ─────────────────────────▶ 单个外部                 │
│  10.0.0.2:80 ────▶ 203.0.113.10:80                        │
│  10.0.0.3:80 ────▶ 203.0.113.10:80                        │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 NAT 表

```c
// NAT 条目
struct nat_entry {
    uint32_t orig_ip;           // 原始 IP
    uint16_t orig_port;         // 原始端口

    uint32_t translated_ip;     // 转换后 IP
    uint16_t translated_port;   // 转换后端口

    uint8_t proto;              // TCP, UDP

    uint64_t last_used;         // 最后使用时间
    uint32_t timeout;           // 超时
};

// NAT 表
struct nat_table {
    struct rte_hash *by_internal;  // 内部 → NAT
    struct rte_hash *by_external;  // 外部 → 内部
};

// SNAT
int
snat_process(struct nat_table *nat,
             struct rte_mbuf *mbuf)
{
    struct ip_hdr *ip = rte_pktmbuf_mtod(mbuf, struct ip_hdr *);
    uint32_t src_ip = ip->src_addr;
    uint16_t src_port = get_src_port(mbuf);

    // 查找 NAT 条目
    struct nat_entry *entry =
        nat_lookup_internal(nat, src_ip, src_port, ip->next_proto_id);

    if (!entry) {
        // 分配新的外部 IP:Port
        entry = nat_allocate(nat, src_ip, src_port,
                             ip->next_proto_id);
    }

    // 修改源地址
    ip->src_addr = entry->translated_ip;
    set_src_port(mbuf, entry->translated_port);

    // 更新校验和
    update_ip_checksum(ip);
    update_transport_checksum(mbuf);

    return 0;
}
```

## 5. 规则匹配优化

### 5.1 Trie 结构

```
┌─────────────────────────────────────────────────────────────┐
│                    Patricia Trie (Radix Tree)              │
│                                                              │
│                      ┌─────┐                               │
│                      │ROOT │                               │
│                      └──┬──┘                               │
│                    ┌───┴───┐                              │
│                    ▼       ▼                               │
│                  0/       \1                              │
│               ┌─────┐   ┌─────┐                           │
│               │ /16  │   │ /24  │                           │
│               └──┬──┘   └──┬──┘                           │
│                  │        │                                │
│                  │        ▼                                │
│                  │     ┌─────┐                             │
│                  │     │/28  │                             │
│                  │     └──┬──┘                             │
│                  ▼        │                                │
│               ...        ▼                                │
│                      ┌─────┐                             │
│                      │ /32 │ (leaf)                       │
│                      └─────┘                             │
└─────────────────────────────────────────────────────────────┘
```

### 5.2 DPDK Flow

```c
// DPDK Flow 规则
struct rte_flow *
create_firewall_flow(uint16_t port_id,
                     uint32_t src_ip, uint32_t src_mask,
                     uint32_t dst_ip, uint32_t dst_mask,
                     uint16_t port)
{
    struct rte_flow_attr attr = {
        .ingress = 1,
        .priority = 1,
    };

    struct rte_flow_item pattern[] = {
        {
            .type = RTE_FLOW_ITEM_TYPE_IPV4,
            .spec = & (struct rte_flow_item_ipv4) {
                .hdr = {
                    .src_addr = src_ip,
                    .dst_addr = dst_ip,
                },
            },
            .mask = & (struct rte_flow_item_ipv4) {
                .hdr = {
                    .src_addr = src_mask,
                    .dst_addr = dst_mask,
                },
            },
        },
        {
            .type = RTE_FLOW_ITEM_TYPE_TCP,
            .spec = & (struct rte_flow_item_tcp) {
                .hdr = {
                    .src_port = 0,
                    .dst_port = port,
                },
            },
            .mask = & (struct rte_flow_item_tcp) {
                .hdr = {
                    .src_port = 0,
                    .dst_port = 0xFFFF,
                },
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

    return rte_flow_create(port_id, &attr, pattern, actions, error);
}
```

## 6. 总结

防火墙架构：

```
┌─────────────────────────────────────────────────────────────┐
│                    防火墙数据路径                           │
│                                                              │
│  Packet                                                     │
│     ↓                                                        │
│  ① ACL Lookup (无状态规则)                                  │
│     ↓                                                        │
│  ② Conntrack (连接状态)                                     │
│     ↓                                                        │
│  ③ NAT (地址转换)                                          │
│     ↓                                                        │
│  ④ Action (permit/deny)                                   │
└─────────────────────────────────────────────────────────────┘
```

性能优化：

| 技术                 | 效果             |
| -------------------- | ---------------- |
| **ACL (DPDK)**       | ~50M rules/s     |
| **Conntrack (DPDK)** | ~10M connections |
| **NAT (DPDK)**       | ~10 Gbps         |

---

## 参考资源

- [DPDK ACL](https://doc.dpdk.org/guides/prog_guide/acl_lib.html)
- [DPDK Flow](https://doc.dpdk.org/guides/prog_guide/rte_flow.html)
- [Linux Conntrack](http://conntrack-tools.netfilter.org/)
