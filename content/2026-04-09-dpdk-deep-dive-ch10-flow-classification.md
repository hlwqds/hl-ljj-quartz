---
title: "DPDK 深度探索 (十)：Flow Classification 流量分类与 rte_flow"
date: 2026-04-09
tags: [dpdk, series, flow, rte_flow, RSS, ACL, Flow Director, match-action]
description: "深入理解 DPDK 流量分类——RSS 哈希分散、Flow Director 精确匹配、ACL 库加速五元组查找、以及 rte_flow 通用匹配动作框架"
---

> [!info] DPDK 深度探索系列
> 0. [[2026-04-09-dpdk-deep-dive-series-index|全栈学习路径总览]]
> 1-9. 前九章已完成
> 10. **第十章：Flow Classification 流量分类与 rte_flow**

---

## 1. 概述：为什么需要流量分类？

DPDK 处理百万级数据包时，需要识别"这是什么样的流量"：

| 场景 | 需求 |
|------|------|
| **多核负载均衡** | 将不同 flows 分散到不同 lcore 处理 |
| **服务质量 (QoS)** | 语音流量优先，游戏流量次之，普通流量普通处理 |
| **安全过滤** | 识别并阻断恶意流量 |
| **会话跟踪** | 同一个 flow 的包必须到同一个 lcore |
| **策略路由** | 特定流量走特定路径 |

### 1.1 流量分类技术全景

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        DPDK 流量分类技术栈                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  用户态分类                                                                 │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │                     rte_flow (通用匹配-动作框架)                      │  │
│  │  ┌────────────┐  ┌────────────┐  ┌────────────┐  ┌────────────┐    │  │
│  │  │ Pattern    │  │    Action  │  │   Flow     │  │   Table    │    │  │
│  │  │ Matching   │  │  Steering  │  │  Inspection │  │  Management│    │  │
│  │  └────────────┘  └────────────┘  └────────────┘  └────────────┘    │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
│  硬件卸载分类                                                               │
│  ┌────────────┐  ┌────────────┐  ┌────────────┐                           │
│  │ RSS        │  │ Flow       │  │   ACL      │                           │
│  │ (散列分散)  │  │ Director   │  │  (访问控制) │                           │
│  │            │  │ (精确匹配)  │  │            │                           │
│  └────────────┘  └────────────┘  └────────────┘                           │
│                                                                             │
│  软件分类                                                                  │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │                    librte_acl (Trie + NBFSM)                          │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. RSS (Receive Side Scaling)

### 2.1 RSS 原理

RSS 使用 Toeplitz 哈希算法，将数据包分散到多个队列：

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              RSS 哈希分散                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   输入 (Layer 3/4 Header)                                                  │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │  Src IP, Dst IP, Src Port, Dst Port, Protocol                     │  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│                                    │                                        │
│                                    ▼                                        │
│                         ┌──────────────────┐                              │
│                         │  Toeplitz Hash   │                              │
│                         │  (对称哈希)       │                              │
│                         └────────┬─────────┘                              │
│                                    │                                        │
│                                    ▼                                        │
│                         ┌──────────────────┐                              │
│                         │  Hash Value      │                              │
│                         │  (32-bit)        │                              │
│                         └────────┬─────────┘                              │
│                                    │                                        │
│                                    ▼                                        │
│   输出                         ┌──────────────────┐                       │
│   ┌─────────────────────────────────────────────────────────────────────┐│
│   │  queue_id = hash & (nb_queues - 1)                                  ││
│   │                                                                      ││
│   │  queue[0] ◄── hash = 0x1234...                                       ││
│   │  queue[1] ◄── hash = 0x5678...                                       ││
│   │  queue[2] ◄── hash = 0x9ABC...                                       ││
│   │  queue[3] ◄── hash = 0xDEF0...                                       ││
│   └─────────────────────────────────────────────────────────────────────┘│
│                                                                             │
│   特点：                                                                   │
│   - 同一 flow 的包 → 同一队列（保证顺序）                                   │
│   - 不同 flows → 均匀分散到各队列                                          │
│   - NIC 硬件自动完成，无需 CPU 介入                                        │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 2.2 RSS 配置

```c
// 配置 RSS
struct rte_eth_conf conf = {
    .rxmode = {
        .mq_mode = RTE_ETH_MQ_RX_RSS,
        .offloads = DEV_RX_OFFLOAD_RSS_HASH,
    },
    .rx_adv_conf = {
        .rss_conf = {
            .rss_key = NULL,           // NULL = 使用默认 KEY
            .rss_key_len = 40,         // 40 字节
            .rss_hf = RTE_ETH_RSS_IP   // 哈希字段
                               | RTE_ETH_RSS_TCP
                               | RTE_ETH_RSS_UDP,
        },
    },
};

// RSS 哈希字段
#define RTE_ETH_RSS_IPV4        (1ULL << 2)
#define RTE_ETH_RSS_IPV6        (1ULL << 3)
#define RTE_ETH_RSS_IPV6_EXT    (1ULL << 4)
#define RTE_ETH_RSS_TCP         (1ULL << 5)
#define RTE_ETH_RSS_UDP         (1ULL << 6)
#define RTE_ETH_RSS_SCTP        (1ULL << 7)
#define RTE_ETH_RSS_TUNNEL      (1ULL << 8)  // VXLAN, GRE
#define RTE_ETH_RSS_L2_PAYLOAD  (1ULL << 15)
#define RTE_ETH_RSS_PORT        (1ULL << 16)
```

### 2.3 RSS 硬件实现

```c
// RSS Indirection Table (Intel NIC)

// indirection_table[128] 存储队列映射
// 哈希值的后 7 位 (hash & 127) 作为索引

static uint16_t
ixgbe_rss_hash(struct rte_mbuf *m, uint32_t *rss_hash)
{
    struct rte_ether_hdr *eth = rte_pktmbuf_mtod(m, struct rte_ether_hdr *);
    void *hdr;
    uint32_t hash;
    
    // 根据协议类型提取字段
    if (eth->ether_type == rte_cpu_to_be_16(RTE_ETHER_TYPE_IPV4)) {
        struct rte_ipv4_hdr *ip = (struct rte_ipv4_hdr *)(eth + 1);
        hdr = ip;
        
        if (ip->next_proto_id == IPPROTO_TCP) {
            struct rte_tcp_hdr *tcp = (struct rte_tcp_hdr *)((char *)ip + 
                            (ip->version_ihl & 0x0F) * 4);
            // 计算 4-tuple 哈希
            hash = rte_softrss_be(m->pkt_len ^ 
                        ((uint64_t)ip->src_addr << 32) ^
                        ((uint64_t)ip->dst_addr << 16) ^
                        ((uint64_t)tcp->src_port << 8) ^
                        tcp->dst_port,
                        toeplitz_key);
        }
    }
    
    // 存储哈希值到 mbuf
    m->hash.rss = hash;
    m->ol_flags |= PKT_RX_RSS_HASH;
    
    // 返回队列索引
    return ixgbe_queues[hash & (ixgbe_nb_queues - 1)];
}
```

---

## 3. Flow Director (精确匹配)

### 3.1 Flow Director 原理

Flow Director 是 Intel 特有的硬件功能，支持精确的五元组匹配：

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          Flow Director vs RSS                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  RSS (散列分散)                                                             │
│  ─────────────                                                             │
│  flow_key = hash(5-tuple)                                                  │
│  queue = hash & mask                                                       │
│                                                                             │
│  问题：                                                                   │
│  - 无法指定特定 flow 到特定队列                                            │
│  - 无法过滤特定 flow                                                       │
│  - 无法区分不同的 flows                                                    │
│                                                                             │
│  Flow Director (精确匹配)                                                  │
│  ───────────────────────                                                   │
│  flow_key = hash(5-tuple) 存储到 FDIR Table                                 │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                    Flow Director Table                               │   │
│  │  ┌──────────┬──────────┬──────────┬──────────┬──────────┬────────┐    │   │
│  │  │ Src IP  │ Dst IP  │Protocol  │ Src Port│ Dst Port│ Queue  │    │   │
│  │  ├──────────┼──────────┼──────────┼──────────┼──────────┼────────┤    │   │
│  │  │ 10.0.0.1│ 10.0.0.2│   TCP    │   80    │  12345  │   0    │    │   │
│  │  │ 10.0.0.3│ 10.0.0.4│   UDP    │   53    │  54321  │   1    │    │   │
│  │  │   *     │   *     │   *      │   *     │   *     │ drop   │    │   │
│  │  └──────────┴──────────┴──────────┴──────────┴──────────┴────────┘    │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  优势：                                                                   │
│  - 精确匹配特定 flow                                                        │
│  - 可以 DROP 特定流量                                                       │
│  - 支持 ACL 规则                                                            │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 3.2 Flow Director 配置

```c
// lib/ethdev/rte_fdir.h

// Flow Director 模式
enum rte_fdir_mode {
    RTE_FDIR_MODE_NONE        = 0,   // 关闭
    RTE_FDIR_MODE_PERFECT     = 1,   // 精确匹配（默认）
    RTE_FDIR_MODE_SIGNATURE   = 2,   // 签名模式（节省资源）
    RTE_FDIR_MODE_TB5         = 3,   // 5-tuple
    RTE_FDIR_MODE_TB4         = 4,   // 4-tuple
    RTE_FDIR_MODE_TB3         = 5,   // 3-tuple
    RTE_FDIR_MODE_IP_DA       = 6,   // IP dest only
    RTE_FDIR_MODE_UDP_SA      = 7,   // UDP src only
};

// Flow Director 过滤结构
struct rte_fdir_filter {
    rte_be32_t ip_spec;           // IPv4 源/目标地址
    rte_be32_t ip_mask;           // 地址掩码
    rte_be16_t port_spec;         // 端口
    rte_be16_t port_mask;         // 端口掩码
    uint8_t proto;                // 协议
    uint8_t proto_mask;           // 协议掩码
    uint16_t vlan_id;             // VLAN
    uint16_t vlan_mask;
    uint16_t flexbytes;           // 灵活字节
    uint16_t flex_mask;
};

// 添加 Flow Director 规则
int
rte_eth_dev_fdir_add(uint16_t port_id,
                      const struct rte_fdir_filter *filter,
                      enum rte_eth_fdir_behavior behavior,
                      uint8_t queue_index)
{
    struct rte_eth_dev *dev = &rte_eth_devices[port_id];
    return dev->dev_ops->fdir_add(dev, filter, behavior, queue_index);
}

// 行为定义
enum rte_eth_fdir_behavior {
    RTE_ETH_FDIR_ACCEPT = 0,       // 接收
    RTE_ETH_FDIR_DROP   = 1,       // 丢弃
    RTE_ETH_FDIR_PASS   = 2,       // 穿透（不匹配时）
    RTE_ETH_FDIR_QUEUE  = 3,        // 排队
    RTE_ETH_FDIR_PRIO   = 4,       // 优先级
};
```

### 3.3 Flow Director 使用示例

```c
// 示例：丢弃来自特定 IP 的 TCP 流量

struct rte_eth_fdir_filter filter = {
    .ip_spec = {
        .src_ip = RTE_IPV4(10, 0, 0, 1),
        .dst_ip = RTE_IPV4(0, 0, 0, 0),
    },
    .ip_mask = {
        .src_ip = 0xFFFFFFFF,
        .dst_ip = 0x00000000,
    },
    .port_spec = {
        .src = 0,
        .dst = 0,
    },
    .port_mask = {
        .src = 0,
        .dst = 0,
    },
    .proto = IPPROTO_TCP,
    .proto_mask = 0xFF,
};

// 添加 DROP 规则
int ret = rte_eth_dev_fdir_add(port_id,
                                 &filter,
                                 RTE_ETH_FDIR_DROP,
                                 0);  // queue 不适用于 DROP
if (ret < 0)
    rte_exit(EXIT_FAILURE, "Failed to add FDIR rule\n");

printf("Flow Director: Dropping TCP from 10.0.0.1\n");
```

---

## 4. librte_acl (访问控制列表)

### 4.1 ACL 库概述

当硬件分类不够用时，librte_acl 提供软件层面的高性能 ACL：

```c
// lib/librte_acl/rte_acl.h

// ACL 规则定义
struct rte_acl_rule {
    uint32_t data[40];  // 用户定义的数据（可存储 queue、action 等）
    
    /* 匹配字段 */
    struct {
        uint8_t type;    // RTE_ACL_FIELD_TYPE_*
        uint8_t size;    // 字段大小（字节）
        uint16_t offset; // 在数据包中的偏移
        uint32_t value;  // 值
        uint32_t mask;   // 掩码
    } field[RTE_ACL_MAX_FIELDS];
};

// 示例：定义 5-tuple 规则
struct my_rule {
    struct rte_acl_rule base;
    
    // 字段定义
    struct {
        struct rte_acl_field_def ipv4_src;
        struct rte_acl_field_def ipv4_dst;
        struct rte_acl_field_def sport;
        struct rte_acl_field_def dport;
        struct rte_acl_field_def proto;
    };
};
```

### 4.2 ACL 构建流程

```c
// 1. 创建 ACL 上下文
struct rte_acl_ctx *acl_ctx;
struct rte_acl_param acl_param = {
    .name = "my_acl",
    .socket_id = SOCKET_ID_ANY,
    .rule_size = sizeof(struct my_rule),
    .max_rule_count = 1024,
};

acl_ctx = rte_acl_create(&acl_param);
if (!acl_ctx) {
    // 创建失败
}

// 2. 添加规则
struct my_rule rule = {
    .data = { .category_mask = 1, .priority = 1, .action = DROP },
    .field = {
        // src_ip: 偏移 12 字节，4 字节，掩码 255.255.255.0
        { .type = RTE_ACL_FIELD_TYPE_MASK, .offset = 12, .size = 4,
          .value = RTE_IPV4(10, 0, 0, 0), .mask = RTE_IPV4(255, 255, 255, 0) },
        // dst_ip, sport, dport, proto...
    },
};

rte_acl_add(acl_ctx, (struct rte_acl_rule *)&rule);

// 3. 构建 AC 结构（NBFSM + Trie）
struct rte_acl_config build_config = {
    .num_categories = 1,           // 单一类别
    .num_fields = 5,               // 5 个字段
    .defs = {
        { .type = RTE_ACL_FIELD_TYPE_MASK, .offset = 12, .size = 4 },
        { .type = RTE_ACL_FIELD_TYPE_MASK, .offset = 16, .size = 4 },
        { type = RTE_ACL_FIELD_TYPE_RANGE, .offset = 20, .size = 2 }, // sport
        { type = RTE_ACL_FIELD_TYPE_RANGE, .offset = 22, .size = 2 }, // dport
        { .type = RTE_ACL_FIELD_TYPE_BITMASK, .offset = 23, .size = 1 },
    },
};

rte_acl_build(acl_ctx, &build_config);
```

### 4.3 ACL 查找

```c
// 查找数据包匹配哪个规则
uint32_t results[1];  // 只查找最优匹配

int
classify_packet(struct rte_acl_ctx *acl_ctx,
                 struct rte_mbuf *m)
{
    uint8_t buffer[128];
    struct rte_ether_hdr *eth = rte_pktmbuf_mtod(m, struct rte_ether_hdr *);
    
    // 提取要匹配的字段到 buffer
    struct rte_ipv4_hdr *ip = (struct rte_ipv4_hdr *)(eth + 1);
    memcpy(buffer + 12, &ip->src_addr, 4);
    memcpy(buffer + 16, &ip->dst_addr, 4);
    
    if (ip->next_proto_id == IPPROTO_TCP) {
        struct rte_tcp_hdr *tcp = (struct rte_tcp_hdr *)((char *)ip + 
                        (ip->version_ihl & 0x0F) * 4);
        *(uint16_t *)(buffer + 20) = tcp->src_port;
        *(uint16_t *)(buffer + 22) = tcp->dst_port;
        buffer[23] = IPPROTO_TCP;
    }
    
    // 执行查找
    int ret = rte_acl_classify(acl_ctx,
                                &buffer,  // 输入
                                results,   // 输出
                                1,         // 只查一条
                                RTE_ACL_CLASSIFY_DEFAULT);
    
    if (ret == 0) {
        uint32_t action = results[0] & 0xFF;
        return action;
    }
    
    return 0;  // 无匹配
}
```

### 4.4 ACL 内部实现：NBFSM

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     NBFSM (Non-deterministic Finite State Machine)          │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  示例规则：                                                                 │
│  Rule 1: src_ip=10.0.0.0/24, action=ACCEPT                                  │
│  Rule 2: src_ip=10.0.1.0/24, action=DROP                                    │
│                                                                             │
│  NBFSM 构建：                                                               │
│                                                                             │
│     ┌────────┐                                                            │
│     │ START  │                                                            │
│     └───┬────┘                                                            │
│         │ 10.0.x.x                                                        │
│         ▼                                                                  │
│     ┌────────┐                                                            │
│     │  Match │                                                            │
│     │  10.0. │                                                            │
│     └───┬────┘                                                            │
│         │                                                                  │
│    ┌────┴────┐                                                            │
│    │         │                                                            │
│    ▼         ▼                                                            │
│  ┌────┐   ┌────┐                                                         │
│  │R1: │   │R2: │                                                         │
│  │0.x │   │1.x │                                                         │
│  └──┬─┘   └──┬─┘                                                         │
│     │       │                                                             │
│     ▼       ▼                                                             │
│  ┌──────────────┐                                                        │
│  │ R1 Match     │   ───► Action: ACCEPT                                  │
│  │ (last byte)  │                                                        │
│  └──────────────┘                                                        │
│                  ┌──────────────┐                                        │
│                  │ R2 Match     │   ───► Action: DROP                     │
│                  │ (last byte)  │                                        │
│                  └──────────────┘                                        │
│                                                                             │
│  NBFSM → DFASM (确定性化) → Trie 结构优化                                  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 5. rte_flow 通用匹配-动作框架

### 5.1 rte_flow 概述

rte_flow 是 DPDK 20.11+ 引入的通用流规则 API，抽象了硬件能力：

```c
// lib/ethdev/rte_flow.h

// 流规则组成
struct rte_flow {
    struct rte_flow_attr attr;           // 规则属性
    struct rte_flow_pattern *pattern;   // 匹配模式
    struct rte_flow_action *actions;     // 执行动作
};

// 属性
struct rte_flow_attr {
    uint32_t group;          // 流表组
    uint32_t priority;       // 优先级（0 最高）
    uint32_t ingress;         // 入口流量
    uint32_t egress;          // 出口流量
    uint32_t transfer;       // 转移（switch domain）
    uint32_t reserved;       // 保留
};
```

### 5.2 模式项 (Pattern Items)

```c
// 匹配模式定义

// Ethernet
RTE_FLOW_ITEM_TYPE_ETH   // 匹配 Ethernet 头部
//  example: dst_mac = xx:xx:xx:xx:xx:xx

// VLAN
RTE_FLOW_ITEM_TYPE_VLAN  // 匹配 VLAN tag

// IPv4/IPv6
RTE_FLOW_ITEM_TYPE_IPV4  // 匹配 IPv4
RTE_FLOW_ITEM_TYPE_IPV6  // 匹配 IPv6
//  example: src_addr = 10.0.0.1

// TCP/UDP/SCTP
RTE_FLOW_ITEM_TYPE_TCP   // 匹配 TCP
RTE_FLOW_ITEM_TYPE_UDP   // 匹配 UDP
RTE_FLOW_ITEM_TYPE_SCTP  // 匹配 SCTP
//  example: src_port = 80

// 隧道
RTE_FLOW_ITEM_TYPE_VXLAN       // 匹配 VXLAN
RTE_FLOW_ITEM_TYPE_GRE         // 匹配 GRE
RTE_FLOW_ITEM_TYPE_NVGRE       // 匹配 NVGRE

// 原始数据
RTE_FLOW_ITEM_TYPE_raw   // 匹配原始字节

// 通配符
RTE_FLOW_ITEM_TYPE_END   // 模式结束

// 模式示例：匹配 UDP 流量
static const struct rte_flow_item pattern[] = {
    { .type = RTE_FLOW_ITEM_TYPE_ETH },
    { .type = RTE_FLOW_ITEM_TYPE_IPV4 },
    { .type = RTE_FLOW_ITEM_TYPE_UDP },
    { .type = RTE_FLOW_ITEM_TYPE_END },
};
```

### 5.3 动作 (Actions)

```c
// 支持的动作

RTE_FLOW_ACTION_TYPE_END           // 结束
RTE_FLOW_ACTION_TYPE_PASSTHRU      // 穿透
RTE_FLOW_ACTION_TYPE_DROP          // 丢弃
RTE_FLOW_ACTION_TYPE_QUEUE         // 排队到特定队列
RTE_FLOW_ACTION_TYPE_RSS           // RSS
RTE_FLOW_ACTION_TYPE_PHY_PORT     // 物理端口
RTE_FLOW_ACTION_TYPE_VOID          // 空动作
RTE_FLOW_ACTION_TYPE_MARK          // 标记（添加 ID）
RTE_FLOW_ACTION_TYPE_COUNT         // 计数
RTE_FLOW_ACTION_TYPE_SET_MAC_SRC   // 修改源 MAC
RTE_FLOW_ACTION_TYPE_SET_MAC_DST   // 修改目标 MAC
RTE_FLOW_ACTION_TYPE_SET_IPV4_SRC  // 修改源 IP
RTE_FLOW_ACTION_TYPE_SET_IPV4_DST  // 修改目标 IP
RTE_FLOW_ACTION_TYPE_SET_TP_SRC    // 修改源端口
RTE_FLOW_ACTION_TYPE_SET_TP_DST    // 修改目标端口
RTE_FLOW_ACTION_TYPE_OF_POP_VLAN   // 弹出 VLAN
RTE_FLOW_ACTION_TYPE_OF_PUSH_VLAN  // 插入 VLAN
RTE_FLOW_ACTION_TYPE_JUMP          // 跳转到其他流表组
RTE_FLOW_ACTION_TYPE_METER         // 流量计量
RTE_FLOW_ACTION_TYPE_SECURITY      // 安全处理

// 动作示例：丢弃所有 TCP 流量
static const struct rte_flow_action actions[] = {
    { .type = RTE_FLOW_ACTION_TYPE_DROP },
    { .type = RTE_FLOW_ACTION_TYPE_END },
};

// 动作示例：标记并排队
static const struct rte_flow_action actions[] = {
    {
        .type = RTE_FLOW_ACTION_TYPE_MARK,
        .conf = &(struct rte_flow_action_mark) { .id = 42 },
    },
    {
        .type = RTE_FLOW_ACTION_TYPE_QUEUE,
        .conf = &(struct rte_flow_action_queue) { .index = 3 },
    },
    { .type = RTE_FLOW_ACTION_TYPE_END },
};
```

### 5.4 完整示例

```c
// 示例 1：匹配特定 UDP 流量并指定队列

static int
setup_flow_redirect(uint16_t port_id, uint16_t queue_id)
{
    struct rte_flow_attr attr = {
        .ingress = 1,     // 入方向
        .priority = 0,   // 高优先级
    };
    
    // 匹配模式：dst=10.0.0.1 且 dst_port=80
    struct rte_flow_item pattern[] = {
        {
            .type = RTE_FLOW_ITEM_TYPE_IPV4,
            .mask = &rte_flow_item_ipv4_mask,
            .spec = &(struct rte_flow_item_ipv4) {
                .hdr = {
                    .dst_addr = RTE_IPV4(10, 0, 0, 1),
                },
            },
        },
        {
            .type = RTE_FLOW_ITEM_TYPE_UDP,
            .mask = &rte_flow_item_udp_mask,
            .spec = &(struct rte_flow_item_udp) {
                .hdr = {
                    .dst_port = rte_cpu_to_be_16(80),
                },
            },
        },
        {
            .type = RTE_FLOW_ITEM_TYPE_END,
        },
    };
    
    // 动作：排队到指定队列
    struct rte_flow_action actions[] = {
        {
            .type = RTE_FLOW_ACTION_TYPE_QUEUE,
            .conf = &(struct rte_flow_action_queue) {
                .index = queue_id,
            },
        },
        {
            .type = RTE_FLOW_ACTION_TYPE_END,
        },
    };
    
    // 创建流规则
    struct rte_flow *flow = rte_flow_create(port_id,
                                              &attr,
                                              pattern,
                                              actions,
                                              &error);
    if (!flow) {
        printf("Flow creation failed: %s\n", error.message);
        return -1;
    }
    
    return 0;
}

// 示例 2：使用 RSS 分散负载

static int
setup_flow_rss(uint16_t port_id)
{
    struct rte_flow_attr attr = {
        .ingress = 1,
    };
    
    struct rte_flow_item pattern[] = {
        { .type = RTE_FLOW_ITEM_TYPE_ETH },
        { .type = RTE_FLOW_ITEM_TYPE_IPV4 },
        { .type = RTE_FLOW_ITEM_TYPE_END },
    };
    
    // RSS 配置
    uint16_t queues[] = { 0, 1, 2, 3 };
    struct rte_flow_action_rss rss_conf = {
        .func = RTE_ETH_HASH_FUNCTION_DEFAULT,
        .level = 0,
        .types = RTE_ETH_RSS_IP | RTE_ETH_RSS_UDP,
        .key_len = 40,
        .queue_num = 4,
        .queue = queues,
    };
    
    struct rte_flow_action actions[] = {
        {
            .type = RTE_FLOW_ACTION_TYPE_RSS,
            .conf = &rss_conf,
        },
        { .type = RTE_FLOW_ACTION_TYPE_END },
    };
    
    return rte_flow_create(port_id, &attr, pattern, actions, &error) != NULL;
}

// 示例 3：VLAN 流量镜像

static int
setup_flow_mirror(uint16_t port_id, uint16_t mirror_port)
{
    struct rte_flow_attr attr = {
        .ingress = 1,
        .group = 1,  // 使用 group 1
    };
    
    // 匹配特定 VLAN
    struct rte_flow_item pattern[] = {
        { .type = RTE_FLOW_ITEM_TYPE_ETH },
        {
            .type = RTE_FLOW_ITEM_TYPE_VLAN,
            .mask = &rte_flow_item_vlan_mask,
            .spec = &(struct rte_flow_item_vlan) {
                .tci = rte_cpu_to_be_16(100),  // VLAN 100
            },
        },
        { .type = RTE_FLOW_ITEM_TYPE_IPV4 },
        { .type = RTE_FLOW_ITEM_TYPE_END },
    };
    
    // 动作：发送到镜像端口
    struct rte_flow_action actions[] = {
        {
            .type = RTE_FLOW_ACTION_TYPE_PHY_PORT,
            .conf = &(struct rte_flow_action_phy_port) {
                .original = 1,  // 保留原始端口
                .index = mirror_port,
            },
        },
        { .type = RTE_FLOW_ACTION_TYPE_END },
    };
    
    return rte_flow_create(port_id, &attr, pattern, actions, &error) != NULL;
}
```

### 5.5 流表组 (Flow Group)

```c
// 流表组用于分层管理流规则

// Group 0: 默认规则
//   - 所有流量 RSS 到多个队列
//   - 普通处理

// Group 1: 高优先级规则
//   - 特定流量 DROP
//   - 特定流量 QUEUE 到专用队列
//   - 特定流量 镜像到分析端口

// Group 2: 安全规则
//   - DDoS 防护
//   - 异常流量检测

// 规则匹配顺序：
// 1. 按 group 优先级匹配（group 0 最低，group 31 最高）
// 2. 同 group 内按 priority 匹配
// 3. 匹配到则执行动作，不再继续匹配

// 示例：多组配置
static void
setup_flow_groups(uint16_t port_id)
{
    // Group 0: 默认 RSS
    create_rss_flow(port_id, 0, 0, queues, nb_queues);
    
    // Group 1: 特殊流量
    create_drop_flow(port_id, 1, 1, bad_ip);
    create_mirror_flow(port_id, 1, 1, monitor_port);
    
    // Group 2: 紧急拦截
    create_rate_limit_flow(port_id, 2, 2, ddos_ip);
}
```

---

## 6. 性能对比

### 6.1 各技术性能对比

| 技术 | 吞吐量 | 延迟 | 灵活性 | 适用范围 |
|------|--------|------|--------|----------|
| **RSS** | 线速 | ~0 | 低 | 负载均衡 |
| **Flow Director** | 线速 | ~0 | 中 | Intel NIC 精确匹配 |
| **librte_acl** | ~50-100 Mpps | ~50ns | 高 | 软件分类/复杂规则 |
| **rte_flow** | 取决于底层 | 取决于底层 | 高 | 通用 API |

### 6.2 选型指南

```c
// 选型决策树

if (需要负载均衡) {
    // RSS
    选择 RSS，按 5-tuple 分散到多个队列
}
else if (硬件支持 && 规则简单) {
    // Flow Director
    添加 FDIR 规则到 NIC
}
else if (规则复杂 || 需要跨 NIC) {
    // rte_flow (抽象层)
    使用 rte_flow_create()
}
else if (需要软件分类) {
    // librte_acl
    构建 ACL 分类器
}
else {
    // 组合使用
    RSS 做负载均衡 + rte_flow 做精确控制
}
```

---

## 7. 实际应用场景

### 7.1 负载均衡器

```c
// 场景：DPDK 做负载均衡，将请求分散到多个后端

// 1. RSS 做基础负载均衡
struct rte_flow_action_rss rss_conf = {
    .types = RTE_ETH_RSS_IP | RTE_ETH_RSS_L4,
    .queue_num = nb_queues,
    .queue = queues,
};

// 2. 额外规则处理特定流量
//    - 管理流量 → 管理队列 (queue 0)
//    - 视频流量 → 视频队列 (queue 1-3)
//    - 普通流量 → 普通队列 (queue 4-7)

static int
setup_lb_flows(uint16_t port_id)
{
    // 管理流量 - 高优先级
    struct rte_flow_item pattern_mgmt[] = {
        { .type = RTE_FLOW_ITEM_TYPE_IPV4,
          .spec = &(struct rte_flow_item_ipv4) {
              .hdr = { .dst_addr = RTE_IPV4(10, 0, 0, 254) } } },
        { .type = RTE_FLOW_ITEM_TYPE_TCP,
          .spec = &(struct rte_flow_item_tcp) {
              .hdr = { .dst_port = rte_cpu_to_be_16(22) } } },
        { .type = RTE_FLOW_ITEM_TYPE_END },
    };
    
    struct rte_flow_action actions_mgmt[] = {
        { .type = RTE_FLOW_ACTION_TYPE_QUEUE, .conf = &(struct rte_flow_action_queue){0} },
        { .type = RTE_FLOW_ACTION_TYPE_END },
    };
    
    rte_flow_create(port_id, &(struct rte_flow_attr){.ingress=1,.priority=1},
                    pattern_mgmt, actions_mgmt, &error);
    
    // ... 类似处理其他流量类型
}
```

### 7.2 DDoS 防护

```c
// 场景：检测并阻断异常流量

static int
setup_ddos_protection(uint16_t port_id)
{
    // 1. 统计每个 IP 的流量
    struct rte_flow_action_count count_conf = {
        .id = 0,  // 统计 ID
    };
    
    struct rte_flow_item pattern_count[] = {
        { .type = RTE_FLOW_ITEM_TYPE_IPV4 },
        { .type = RTE_FLOW_ITEM_TYPE_END },
    };
    
    struct rte_flow_action actions_count[] = {
        { .type = RTE_FLOW_ACTION_TYPE_COUNT, .conf = &count_conf },
        { .type = RTE_FLOW_ACTION_TYPE_PASSTHRU },  // 继续处理
        { .type = RTE_FLOW_ACTION_TYPE_END },
    };
    
    rte_flow_create(port_id, &(struct rte_flow_attr){.ingress=1,.group=2},
                    pattern_count, actions_count, &error);
    
    // 2. 读取统计，超过阈值的 DROP
    //    (在定时器中检查 rate，超过 10000 pps 则添加 DROP 规则)
    
    // 3. DROP 规则
    struct rte_flow_item pattern_drop[] = {
        { .type = RTE_FLOW_ITEM_TYPE_IPV4,
          .spec = &(struct rte_flow_item_ipv4) {
              .hdr = { .src_addr = attacker_ip } } },
        { .type = RTE_FLOW_ITEM_TYPE_END },
    };
    
    struct rte_flow_action actions_drop[] = {
        { .type = RTE_FLOW_ACTION_TYPE_DROP },
        { .type = RTE_FLOW_ACTION_TYPE_END },
    };
    
    rte_flow_create(port_id, &(struct rte_flow_attr){.ingress=1,.priority=0},
                    pattern_drop, actions_drop, &error);
}
```

---

## 8. 小结

本章核心要点：

1. **RSS 哈希分散**：基于 5-tuple 的 Toeplitz 哈希，将流量均匀分散到多队列，保证同一 flow 在同一队列处理。

2. **Flow Director**：Intel 硬件支持的精确匹配，支持 DROP、QUEUE 等动作，适合 DDoS 防护、流量过滤。

3. **librte_acl**：软件层面的 ACL 库，使用 NBFSM + Trie 结构，支持复杂规则匹配（如 CIDR 范围）。

4. **rte_flow**：DPDK 统一的匹配-动作框架，抽象了底层硬件差异，支持 Pattern + Action 组合。

5. **Pattern Items**：ETH、VLAN、IPv4/IPv6、TCP/UDP/SCTP、隧道协议等。

6. **Actions**：DROP、QUEUE、RSS、MARK、COUNT、修改 Header 等。

7. **Flow Group**：分层管理流规则，支持多级优先级。

8. **选型**：负载均衡选 RSS，简单精确匹配选 FDIR，复杂规则选 rte_flow 或 librte_acl。

**下一篇预告**：[[2026-04-09-dpdk-deep-dive-ch11-hyper-scan|第十一章]]将深入讲解 hyperscan 数据库 ——向量化匹配、霍夫曼压缩、以及在入侵检测中的应用。

---

> [!tip] 参考文献
> - Intel, "DPDK Flow API", https://doc.dpdk.org/guides/prog_guide/rte_flow.html
> - Intel, "RSS and Flow Director", https://doc.dpdk.org/guides/prog_guide/rte_ethdev.html
> - "librte_acl", https://doc.dpdk.org/guides/prog_guide/acl_lib.html
> - "Hyperscan", https://www.intel.com/content/www/us/en/developer/articles/technical/introduction-hyperscan.html
