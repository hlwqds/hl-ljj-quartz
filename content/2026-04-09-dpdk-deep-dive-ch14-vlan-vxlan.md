---
title: "DPDK 深度探索 (十四)：VLAN/VXLAN 隧道与报头封装"
date: 2026-04-09
tags: [dpdk, series, vlan, vxlan, tunnel, qinq, vlan-offload, overlay-network]
description: "深入理解 DPDK 网络隧道——802.1Q VLAN、QinQ 双标签、VXLAN 封装格式、Overlay 网络、以及 tunnel offload 机制"
---

> [!info] DPDK 深度探索系列
> 0. [[2026-04-09-dpdk-deep-dive-series-index|全栈学习路径总览]]
> 1-13. 前十三章已完成
> 14. **第十四章：VLAN/VXLAN 隧道与报头封装**

---

## 1. 概述：隧道技术为什么重要？

### 1.1 VLAN vs VXLAN

| 特性 | VLAN | VXLAN |
|------|------|-------|
| **标识数量** | 4096 | 1600 万 (2^24) |
| **网络范围** | 本地（L2 broadcast domain） | 跨 L3 网络（Overlay） |
| **封装位置** | 交换机/路由器 | VTEP（隧道端点） |
| **头部开销** | 4 字节 | 50 字节（外部 Ethernet + IP + UDP + VXLAN） |
| **三层互通** | 需要 VLAN 间路由 | 天然跨三层 |

### 1.2 典型报文格式

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           报文封装层次                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  普通 Ethernet 包：                                                         │
│  ┌────────┬─────────┬────────┬───────────────────────────┐                   │
│  │ Ether │   IP   │  L4   │         Payload          │                   │
│  └────────┴─────────┴────────┴───────────────────────────┘                   │
│   14B      20B       20B           ...                                      │
│                                                                             │
│  VLAN 包 (802.1Q)：                                                         │
│  ┌────────┬───────┬────────┬─────────┬────────┬───────────────────────┐     │
│  │ Ether │ VLAN  │   IP   │   L4   │ Payload│                       │     │
│  └────────┴───────┴────────┴─────────┴────────┴───────────────────────┘     │
│   14B      4B       20B       20B         ...                                │
│                ↑                                                            │
│           EtherType=0x8100                                                 │
│                                                                             │
│  VXLAN 包 (Overlay)：                                                       │
│  ┌────────┬───────┬────────┬───────┬────────┬────────┬───────┬────────┐     │
│  │ Out    │ Out   │  Out  │  Out  │ VXLAN  │ Inner  │ Inner │Payload │     │
│  │ Ether │  IP   │  UDP  │Header │ Header │ Ether  │  IP   │        │     │
│  └────────┴───────┴────────┴───────┴────────┴────────┴───────┴────────┘     │
│   14B      20B      8B        50B       8B        14B      20B       ...     │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. VLAN (802.1Q)

### 2.1 VLAN 头部结构

```c
// lib/net/rte_ether.h

// VLAN 头部 (802.1Q)
struct rte_vlan_hdr {
    rte_be16_t vlan_tci;      // Tag Control Information
    rte_be16_t eth_proto;     // 内部 EtherType
} __rte_packed;

// TCI 结构
// ┌─────────────────────────────────────────────┐
// │ PCP (3) │ DEI (1) │     VLAN ID (12)        │
// │ 优先级   │ DROP Eligible │   VLAN 标识        │
// └─────────────────────────────────────────────┘

// PCP (Priority Code Point) - 帧优先级
#define VLAN_PCP_SHIFT    13
#define VLAN_PCP_MASK     0xE000

// DEI (Drop Eligibility Indicator)
#define VLAN_DEI_SHIFT    12
#define VLAN_DEI_MASK     0x1000

// VLAN ID
#define VLAN_ID_MASK      0x0FFF

// 常用 VLAN PCP 值
#define VLAN_PCP_BEST_EFFORT   0
#define VLAN_PCP_BACKGROUND    1
#define VLAN_PCP_EXCELLENT     2
#define VLAN_PCP_CONTROLLED     3
#define VLAN_PCP_VIDEO         4
#define VLAN_VOICE             5
#define VLAN_PCP_NETWORK       6
#define VLAN_PCP_HIGHEST       7
```

### 2.2 解析 VLAN

```c
// 解析 VLAN 头部
static void
parse_vlan(struct rte_ether_hdr *eth)
{
    struct rte_vlan_hdr *vlan = (struct rte_vlan_hdr *)(eth + 1);

    uint16_t tci = rte_be_to_cpu_16(vlan->vlan_tci);
    uint16_t vlan_id = tci & VLAN_ID_MASK;
    uint16_t pcp = (tci >> VLAN_PCP_SHIFT) & 0x07;
    uint16_t dei = (tci >> VLAN_DEI_SHIFT) & 0x01;

    printf("VLAN: id=%d, pcp=%d, dei=%d\n", vlan_id, pcp, dei);

    // 内部 EtherType
    uint16_t inner_etype = rte_be_to_cpu_16(vlan->eth_proto);

    if (inner_etype == RTE_ETHER_TYPE_IPV4) {
        struct rte_ipv4_hdr *ip = (struct rte_ipv4_hdr *)(vlan + 1);
        printf("  Inner: IPv4\n");
    } else if (inner_etype == RTE_ETHER_TYPE_IPV6) {
        printf("  Inner: IPv6\n");
    }
}

// 检查 EtherType 是否为 VLAN
static inline int
is_vlan_tagged(struct rte_ether_hdr *eth)
{
    return eth->ether_type == rte_cpu_to_be_16(RTE_ETHER_TYPE_VLAN);
}
```

### 2.3 QinQ (双层 VLAN)

```c
// QinQ - 双层 VLAN 标签
// 外层 VLAN（服务提供商）
// 内层 VLAN（客户）

struct rte_qinq_hdr {
    struct rte_vlan_hdr outer;   // 外层 VLAN
    struct rte_vlan_hdr inner;   // 内层 VLAN
} __rte_packed;

// QinQ EtherType
#define RTE_ETHER_TYPE_QINQ  0x9100

// 解析 QinQ
static void
parse_qinq(struct rte_ether_hdr *eth)
{
    struct rte_qinq_hdr *qinq = (struct rte_qinq_hdr *)(eth + 1);

    uint16_t outer_vlan = rte_be_to_cpu_16(qinq->outer.vlan_tci) & VLAN_ID_MASK;
    uint16_t inner_vlan = rte_be_to_cpu_16(qinq->inner.vlan_tci) & VLAN_ID_MASK;

    printf("QinQ: outer=%d, inner=%d\n", outer_vlan, inner_vlan);

    // 内层 EtherType
    uint16_t inner_etype = rte_be_to_cpu_16(qinq->inner.eth_proto);
}
```

### 2.4 VLAN Offload

```c
// VLAN offload 配置
struct rte_eth_conf conf = {
    .rxmode = {
        .mq_mode = RTE_ETH_MQ_RX_NONE,
        .offloads = DEV_RX_OFFLOAD_VLAN_FILTER |  // VLAN 过滤
                    DEV_RX_OFFLOAD_VLAN_STRIP,    // VLAN 剥离
    },
};

// VLAN 过滤 - 只接收特定 VLAN 的包
int
vlan_filter_enable(uint16_t port_id, uint16_t vlan_id)
{
    return rte_eth_dev_vlan_filter(port_id, vlan_id, 1);
}

// VLAN 剥离 - 自动去除 VLAN tag
int
vlan_strip_enable(uint16_t port_id)
{
    uint64_t offloads = DEV_RX_OFFLOAD_VLAN_STRIP;
    return rte_eth_dev_configure(port_id, nb_rxq, nb_txq, offloads);
}

// 在发送时插入 VLAN tag
int
vlan_insert(struct rte_mbuf *m, uint16_t vlan_id)
{
    struct rte_ether_hdr *eth = rte_pktmbuf_mtod(m, struct rte_ether_hdr *);

    // 移动 EtherType
    eth->ether_type = eth->dst_addr;
    rte_memcpy(eth->dst_addr.addr_bytes, eth->src_addr.addr_bytes, 6);
    rte_ether_addr_copy((struct rte_ether_addr *)((uint8_t *)eth + 6),
                        &eth->src_addr);

    // 插入 VLAN 头
    struct rte_vlan_hdr *vlan = (struct rte_vlan_hdr *)(eth + 1);
    vlan->vlan_tci = rte_cpu_to_be_16(vlan_id);
    vlan->eth_proto = rte_cpu_to_be_16(RTE_ETHER_TYPE_IPV4);

    // 更新 EtherType
    eth->ether_type = rte_cpu_to_be_16(RTE_ETHER_TYPE_VLAN);

    // 更新长度
    m->pkt_len += sizeof(struct rte_vlan_hdr);
    m->data_len += sizeof(struct rte_vlan_hdr);

    return 0;
}
```

---

## 3. VXLAN 详解

### 3.1 VXLAN 背景

VXLAN (Virtual eXtensible LAN) 是 RFC 7348 定义的一种 Overlay 网络技术：

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              VXLAN 架构                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│       ┌──────────────┐              ┌──────────────┐                      │
│       │    VM A      │              │    VM B      │                      │
│       │  10.0.0.1   │              │  10.0.0.2   │                      │
│       └──────┬───────┘              └──────┬───────┘                      │
│              │                              │                               │
│              │                              │                               │
│       ┌──────┴───────┐              ┌──────┴───────┐                      │
│       │    VTEP A   │◄────────────►│    VTEP B   │                      │
│       │ 172.16.0.1  │   UDP:4789   │  172.16.0.2  │                      │
│       └──────────────┘              └──────────────┘                      │
│              │                              │                               │
│              │      Underlay Network        │                               │
│              └──────────────────────────────┘                               │
│                                                                             │
│   VM A 和 VM B 在同一个 VXLAN (VNI=100)                                     │
│   即使它们在不同的物理网络中，也能直接通信                                    │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 3.2 VXLAN 头部结构

```c
// lib/net/rte_vxlan.h

// VXLAN 头部 (8 字节)
struct rte_vxlan_hdr {
    rte_be32_t vx_flags;        // Flags (8 bits) + Reserved (24 bits)
    rte_be32_t vx_vni;         // VXLAN Network Identifier (24 bits) + Reserved (8 bits)
} __rte_packed;

// VXLAN Flags
#define RTE_VXLAN_HDR_FLAGS(flags) ((flags) & 0xFF)
#define RTE_VXLAN_HDRflags_i_flag  0x08  // I 标志：VXLAN ID 有效

// 解析 VNI (VXLAN Network Identifier)
static inline uint32_t
vxlan_get_vni(struct rte_vxlan_hdr *vh)
{
    uint32_t vni_field = rte_be_to_cpu_32(vh->vx_vni);
    return (vni_field >> 8) & 0xFFFFFF;
}

// VXLAN UDP 目的端口 (IANA 分配)
#define RTE_VXLAN_PORT  4789

// VXLAN 头部示例
static void
parse_vxlan(struct rte_udp_hdr *udp)
{
    uint16_t dst_port = rte_be_to_cpu_16(udp->dst_port);

    if (dst_port == RTE_VXLAN_PORT) {
        struct rte_vxlan_hdr *vxlan = (struct rte_vxlan_hdr *)(udp + 1);

        uint8_t flags = vxlan->vx_flags[0];
        uint32_t vni = vxlan_get_vni(vxlan);

        printf("VXLAN: flags=0x%02x, vni=%d\n", flags, vni);

        if (flags & RTE_VXLAN_HDRflags_i_flag) {
            // VNI 有效
        }
    }
}
```

### 3.3 VXLAN 完整封装

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           VXLAN 报文完整格式                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   Outer Ethernet Header                                                    │
│   ┌──────────┬───────────┬────────────┐                                    │
│   │ DMAC    │  SMAC     │ EtherType  │  0x0800 (IPv4)                       │
│   └──────────┴───────────┴────────────┘                                    │
│        6B          6B           2B                                            │
│                                                                             │
│   Outer IP Header                                                          │
│   ┌────────────────┬──────────────┬────────────┐                           │
│   │ Src=172.16.0.1 │ Dst=172.16.0.2│ Proto=17   │  UDP                       │
│   └────────────────┴──────────────┴────────────┘                           │
│         4B                4B           1B                                     │
│                                                                             │
│   Outer UDP Header                                                         │
│   ┌──────────┬──────────────┬────────────────┐                              │
│   │ SrcPort  │ DstPort=4789 │ UDP Checksum   │                              │
│   └──────────┴──────────────┴────────────────┘                              │
│       2B            2B              2B                                        │
│                                                                             │
│   VXLAN Header                                                             │
│   ┌──────────┬────────────────────────┐                                     │
│   │ Flags   │    VNI (24-bit)        │                                     │
│   └──────────┴────────────────────────┘                                     │
│       1B              3B                                                      │
│                                                                             │
│   Inner Ethernet Header                                                    │
│   ┌──────────┬───────────┬────────────┐                                    │
│   │ DMAC    │  SMAC     │ EtherType  │                                    │
│   └──────────┴───────────┴────────────┘                                    │
│        6B          6B           2B                                            │
│                                                                             │
│   Original Payload (VM to VM)                                              │
│   ┌──────────┬───────────┬────────┬───────────┐                             │
│   │ IP      │   TCP    │ ...    │ Payload   │                             │
│   └──────────┴───────────┴────────┴───────────┘                             │
│                                                                             │
│   Total Overhead: 50 bytes (14 + 20 + 8 + 8)                                │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 3.4 VXLAN 封装实现

```c
// VXLAN 封装函数
static struct rte_mbuf *
vxlan_encap(struct rte_mbuf *pkt,
            uint32_t src_ip, uint32_t dst_ip,
            uint16_t src_port, uint32_t vni)
{
    struct rte_mbuf *encap = rte_pktmbuf_alloc(mbuf_pool);
    if (!encap)
        return NULL;

    // 准备头部空间 (14 + 20 + 8 + 8 = 50 bytes)
    char *head = rte_pktmbuf_prepend(encap, 50);
    if (!head) {
        rte_pktmbuf_free(encap);
        return NULL;
    }

    // 填充 Outer Ethernet
    struct rte_ether_hdr *outer_eth = (struct rte_ether_hdr *)head;
    // ... 设置 DMAC, SMAC, ether_type = 0x0800

    // 填充 Outer IP
    struct rte_ipv4_hdr *outer_ip = (struct rte_ipv4_hdr *)(outer_eth + 1);
    outer_ip->version_ihl = (4 << 4) | 5;
    outer_ip->total_length = rte_cpu_to_be_16(20 + 8 + 8 + rte_pktmbuf_pkt_len(pkt));
    outer_ip->ttl = 64;
    outer_ip->next_proto_id = IPPROTO_UDP;
    outer_ip->src_addr = src_ip;
    outer_ip->dst_addr = dst_ip;

    // 填充 Outer UDP
    struct rte_udp_hdr *outer_udp = (struct rte_udp_hdr *)(outer_ip + 1);
    outer_udp->src_port = rte_cpu_to_be_16(src_port);
    outer_udp->dst_port = rte_cpu_to_be_16(RTE_VXLAN_PORT);
    outer_udp->dgram_len = rte_cpu_to_be_16(8 + 8 + rte_pktmbuf_pkt_len(pkt));

    // 填充 VXLAN Header
    struct rte_vxlan_hdr *vxlan = (struct rte_vxlan_hdr *)(outer_udp + 1);
    vxlan->vx_flags[0] = RTE_VXLAN_HDRflags_i_flag;
    vxlan->vx_flags[1] = 0;
    vxlan->vx_flags[2] = 0;
    vxlan->vx_flags[3] = 0;
    // VNI: 3 bytes + reserved 1 byte
    vxlan->vx_vni = rte_cpu_to_be_32(vni << 8);

    // 链接原始包
    encap->next = pkt;
    encap->pkt_len = 50 + rte_pktmbuf_pkt_len(pkt);
    encap->nb_segs = pkt->nb_segs + 1;

    // 设置 offload
    encap->ol_flags |= PKT_TX_IPV4 | PKT_TX_IP_CKSUM | PKT_TX_UDP_CKSUM;

    return encap;
}
```

### 3.5 VXLAN 解封装

```c
// VXLAN 解封装
static struct rte_mbuf *
vxlan_decap(struct rte_mbuf *pkt)
{
    struct rte_ether_hdr *outer_eth = rte_pktmbuf_mtod(pkt, struct rte_ether_hdr *);
    struct rte_ipv4_hdr *outer_ip = (struct rte_ipv4_hdr *)(outer_eth + 1);
    struct rte_udp_hdr *outer_udp = (struct rte_udp_hdr *)(outer_ip + 1);
    struct rte_vxlan_hdr *vxlan = (struct rte_vxlan_hdr *)(outer_udp + 1);

    // 验证 VXLAN 标志
    if (!(vxlan->vx_flags[0] & RTE_VXLAN_HDRflags_i_flag)) {
        return NULL;  // 不是有效的 VXLAN 包
    }

    // 提取 VNI
    uint32_t vni = vxlan_get_vni(vxlan);
    printf("VXLAN VNI: %d\n", vni);

    // 移除外层头部 (14 + 20 + 8 + 8 = 50 bytes)
    rte_pktmbuf_adj(pkt, 50);

    // 现在是原始的 Ethernet 包
    struct rte_ether_hdr *inner_eth = rte_pktmbuf_mtod(pkt, struct rte_ether_hdr *);
    printf("Inner: %02x:%02x:%02x:%02x:%02x:%02x -> %02x:%02x:%02x:%02x:%02x:%02x\n",
           inner_eth->src_addr.addr_bytes[0], inner_eth->src_addr.addr_bytes[1],
           inner_eth->src_addr.addr_bytes[2], inner_eth->src_addr.addr_bytes[3],
           inner_eth->src_addr.addr_bytes[4], inner_eth->src_addr.addr_bytes[5],
           inner_eth->dst_addr.addr_bytes[0], inner_eth->dst_addr.addr_bytes[1],
           inner_eth->dst_addr.addr_bytes[2], inner_eth->dst_addr.addr_bytes[3],
           inner_eth->dst_addr.addr_bytes[4], inner_eth->dst_addr.addr_bytes[5]);

    return pkt;
}
```

---

## 4. VXLAN Flow 规则

### 4.1 使用 rte_flow 匹配 VXLAN

```c
// 使用 rte_flow 匹配 VXLAN 流量
static int
vxlan_flow_create(uint16_t port_id)
{
    struct rte_flow_attr attr = {
        .ingress = 1,
        .priority = 0,
    };

    // 匹配模式：外层 IP + UDP + VXLAN VNI
    struct rte_flow_item pattern[] = {
        // 外层 Ethernet
        {
            .type = RTE_FLOW_ITEM_TYPE_ETH,
            .mask = &rte_flow_item_eth_mask,
        },
        // 外层 IPv4
        {
            .type = RTE_FLOW_ITEM_TYPE_IPV4,
            .mask = &rte_flow_item_ipv4_mask,
            .spec = &(struct rte_flow_item_ipv4) {
                .hdr = {
                    .dst_addr = 0xFFFFFFFF,  // 匹配目标 IP
                },
            },
        },
        // 外层 UDP
        {
            .type = RTE_FLOW_ITEM_TYPE_UDP,
            .mask = &rte_flow_item_udp_mask,
            .spec = &(struct rte_flow_item_udp) {
                .hdr = {
                    .dst_port = rte_cpu_to_be_16(RTE_VXLAN_PORT),
                },
            },
        },
        // VXLAN (DPDK 23.11+)
        {
            .type = RTE_FLOW_ITEM_TYPE_VXLAN,
            .mask = &rte_flow_item_vxlan_mask,
            .spec = &(struct rte_flow_item_vxlan) {
                .hdr = {
                    .vx_vni = rte_cpu_to_be_32(0xFFFFFF << 8),  // 匹配 VNI
                },
            },
        },
        // 内层 Ethernet
        {
            .type = RTE_FLOW_ITEM_TYPE_ETH,
            .mask = &rte_flow_item_eth_mask,
        },
        // 内层 IPv4
        {
            .type = RTE_FLOW_ITEM_TYPE_IPV4,
            .mask = &rte_flow_item_ipv4_mask,
        },
        {
            .type = RTE_FLOW_ITEM_TYPE_END,
        },
    };

    // 动作：排队到 queue 0
    struct rte_flow_action actions[] = {
        {
            .type = RTE_FLOW_ACTION_TYPE_QUEUE,
            .conf = &(struct rte_flow_action_queue) { .index = 0 },
        },
        {
            .type = RTE_FLOW_ACTION_TYPE_END,
        },
    };

    return rte_flow_create(port_id, &attr, pattern, actions, &error);
}
```

### 4.2 NVGRE 封装

```c
// NVGRE (Network Virtualization using GRE)
// RFC 7637 - 另一种 Overlay 封装

struct rte_nvgre_hdr {
    uint8_t flags[4];       // 0000 0001 = 0x00 00 00 01 (版本 + 协议 type)
    uint8_t proto_type[2];  // 0x08 00 (IPv4)
    uint8_t vsid[3];        // Virtual Subnet ID (24 bits)
    uint8_t flow_id;        // Flow ID
} __rte_packed;

// NVGRE 对比 VXLAN
// - VXLAN: UDP 封装，端口 4789
// - NVGRE: GRE 封装，协议类型 0x6558
// - NVGRE: 不需要 UDP 校验
```

### 4.3 GENEVE 封装

```c
// GENEVE (Generic Network Virtualization Encapsulation)
// RFC 8926 - VXLAN 的后继者

struct rte_geneve_hdr {
    uint8_t ver_opt_len;    // Version (2) + Options Length (6)
    uint8_t protocol_type;   // 0x65 = VXLAN compat
    rte_be16_t vni;         // Virtual Network Identifier
    uint8_t reserved;
} __rte_packed;

// GENEVE 特点
// - 可扩展选项 (TLV)
// - 支持 IPv4 和 IPv6 封装
// - UDP 封装 (6081)
```

---

## 5. GENEVE vs VXLAN vs VLAN 对比

### 5.1 特性对比表

| 特性 | VLAN | VXLAN | GENEVE |
|------|------|-------|--------|
| **ID 空间** | 4096 | 1600 万 | 1600 万 |
| **封装位置** | L2 交换机 | VTEP | VTEP |
| **外层协议** | - | UDP | UDP |
| **Header 大小** | 4B | 8B | 8B+ |
| **L2 扩展** | 本地 | 跨 L3 | 跨 L3 |
| **可扩展性** | 无 | 固定 | TLV 选项 |
| **硬件支持** | 广泛 | 较好 | 一般 |

### 5.2 选型指南

```c
// 选型决策树

if (需要 > 4096 个隔离网络) {
    // 使用 VXLAN 或 GENEVE
    if (需要可扩展选项) {
        // GENEVE - 适合 SDN 控制器
    } else {
        // VXLAN - 更广泛的硬件支持
    }
} else {
    // 使用 VLAN - 简单高效
}
```

---

## 6. Tunnel Offload

### 6.1 Tunnel Offload 配置

```c
// 启用 Tunnel offload
struct rte_eth_conf conf = {
    .rxmode = {
        .offloads = DEV_RX_OFFLOAD_VLAN_STRIP |
                    DEV_RX_OFFLOAD_TUNNEL_UDP,   // 隧道 UDP 解封装
    },
    .txmode = {
        .offloads = DEV_TX_OFFLOAD_VLAN_INSERT |
                    DEV_TX_OFFLOAD_VXLAN_TNL_TSO |  // VXLAN TSO
                    DEV_TX_OFFLOAD_GRE_TNL_TSO,     // GRE TSO
    },
};
```

### 6.2 Tunnel TSO (TCP Segmentation Offload)

```c
// Tunnel TSO - 在隧道外层保持 offload，内部署 MSS 分段
// 发送时：App → GSO → TSO (outer header offload) → NIC
// 接收时：NIC → RSO (Remote Split Offload) → GRO → App

static void
tunnel_tso_example(struct rte_mbuf *pkt, uint16_t mss)
{
    // 假设 pkt 包含完整的 VXLAN 包
    // 我们想要对内部 TCP 进行 TSO

    struct rte_ether_hdr *outer_eth = rte_pktmbuf_mtod(pkt, struct rte_ether_hdr *);
    struct rte_ipv4_hdr *outer_ip = (struct rte_ipv4_hdr *)(outer_eth + 1);
    struct rte_udp_hdr *outer_udp = (struct rte_udp_hdr *)(outer_ip + 1);
    struct rte_vxlan_hdr *vxlan = (struct rte_vxlan_hdr *)(outer_udp + 1);
    struct rte_ether_hdr *inner_eth = (struct rte_ether_hdr *)(vxlan + 1);
    struct rte_ipv4_hdr *inner_ip = (struct rte_ipv4_hdr *)(inner_eth + 1);
    struct rte_tcp_hdr *inner_tcp = (struct rte_tcp_hdr *)(inner_ip + 1);

    // 设置 TSO 参数
    // MSS 应用于内部 TCP
    uint16_t inner_data_len = rte_be_to_cpu_16(inner_ip->total_length) -
                               sizeof(struct rte_ipv4_hdr) -
                               sizeof(struct rte_tcp_hdr);

    if (inner_data_len > mss) {
        // 需要 TSO
        pkt->ol_flags |= PKT_TX_TUNNEL_VXLAN;
        pkt->tso_segsz = mss;  // MSS 大小
    }
}
```

---

## 7. 实际应用示例

### 7.1 OVS-DPDK VXLAN 转发

```c
// OVS-DPDK 中 VXLAN 转发逻辑
static void
vxlan_forward(struct rte_mbuf *pkt, uint32_t vni, uint32_t dst_vtep_ip)
{
    // 1. 解封装（如果是 VXLAN 包）
    if (is_vxlan_packet(pkt)) {
        pkt = vxlan_decap(pkt);
    }

    // 2. 查找路由（基于内部 IP）
    struct rte_ipv4_hdr *inner_ip = get_inner_ip(pkt);
    struct route_entry *rt = lookup_route(inner_ip->dst_addr);

    // 3. 封装到目标 VTEP
    if (rt->is_remote) {
        uint32_t src_vtep = get_local_vtep_ip(rt->src_net);
        uint16_t udp_src = hash5tuple(inner_ip) & 0xFFFF;

        struct rte_mbuf *encap = vxlan_encap(pkt,
                                              src_vtep,
                                              rt->remote_vtep,
                                              udp_src,
                                              rt->vni);
        // 发送
        rte_eth_tx_burst(port_id, 0, &encap, 1);
    } else {
        // 本地转发
        rte_eth_tx_burst(port_id, 0, &pkt, 1);
    }
}
```

### 7.2 多租户 VLAN + VXLAN

```c
// 多租户网络架构：VLAN 隔离租户，VXLAN 提供租户内扩展

// 租户 A: VLAN 100, VXLAN VNI 10000
// 租户 B: VLAN 200, VXLAN VNI 20000

struct tenant_config {
    uint16_t vlan_id;
    uint32_t vxlan_vni;
    uint32_t tenant_ip_base;
};

// 配置 tenant flows
static void
setup_tenant_flows(uint16_t port_id, struct tenant_config *tenant)
{
    // 1. VLAN 过滤 - 只接收该租户的 VLAN 包
    rte_eth_dev_vlan_filter(port_id, tenant->vlan_id, 1);

    // 2. rte_flow - 匹配 VLAN + 内部 IP，添加 VXLAN 封装
    struct rte_flow_attr attr = { .ingress = 1, .priority = 0 };

    struct rte_flow_item pattern[] = {
        { .type = RTE_FLOW_ITEM_TYPE_ETH },
        {
            .type = RTE_FLOW_ITEM_TYPE_VLAN,
            .spec = &(struct rte_flow_item_vlan) {
                .tci = rte_cpu_to_be_16(tenant->vlan_id),
            },
        },
        {
            .type = RTE_FLOW_ITEM_TYPE_IPV4,
            .spec = &(struct rte_flow_item_ipv4) {
                .hdr = {
                    .dst_addr = rte_cpu_to_be_32(tenant->tenant_ip_base),
                    .dst_mask = rte_cpu_to_be_32(0xFFFFFF00),
                },
            },
        },
        { .type = RTE_FLOW_ITEM_TYPE_END },
    };

    struct rte_flow_action actions[] = {
        {
            .type = RTE_FLOW_ACTION_TYPE_PHY_PORT,
            .conf = &(struct rte_flow_action_phy_port) {
                .original = 1,
                .index = 0,  // 物理端口
            },
        },
        { .type = RTE_FLOW_ACTION_TYPE_END },
    };

    rte_flow_create(port_id, &attr, pattern, actions, &error);
}
```

---

## 8. 小结

本章核心要点：

1. **VLAN (802.1Q)**：4 字节头部，TCI 包含 PCP(3位) + DEI(1位) + VLAN ID(12位)，共 4096 个 VLAN。

2. **QinQ**：双层 VLAN，外层服务提供商，内层客户，EtherType 0x9100。

3. **VLAN Offload**：VLAN filter（过滤）、VLAN strip（剥离接收）、VLAN insert（发送插入）。

4. **VXLAN**：Overlay 封装，50 字节开销（14+20+8+8），VNI 24 位 = 1600 万网络。

5. **VXLAN 头部**：8 字节，Flags(1B) + VNI(3B) + Reserved(4B)，I 标志表示 VNI 有效。

6. **VXLAN 封装/解封装**：添加/移除 outer Ethernet + IP + UDP + VXLAN header。

7. **rte_flow 匹配 VXLAN**：外层 IP/UDP + VXLAN VNI + 内层 Ethernet/IP。

8. **NVGRE vs GENEVE**：NVGRE 用 GRE 封装（无 UDP），GENEVE 支持 TLV 扩展选项。

9. **Tunnel Offload**：VXLAN TSO、GRE TSO，保持外层 offload 的同时对内部 TCP 分段。

10. **选型**：VLAN（≤4096 网络，简单场景）vs VXLAN/GENEVE（大规模多租户，跨 L3）。

**下一篇预告**：[[2026-04-09-dpdk-deep-dive-ch15-kni-interface|第十五章]]将讲解 KNI（Kernel NIC Interface）—— DPDK 与 Linux 内核网络栈的桥梁，实现用户态与内核的零拷贝通信。

---

> [!tip] 参考文献
> - IEEE 802.1Q, "IEEE Standard for Local and Metropolitan Area Networks"
> - RFC 7348, "VXLAN: A Framework for Overlaying Virtualized Layer 2 Networks"
> - RFC 7637, "NVGRE: Network Virtualization Using Generic Routing Encapsulation"
> - RFC 8926, "GENEVE: Generic Network Virtualization Encapsulation"
