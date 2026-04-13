---
title: "VPP 深入探讨 ch09：MPLS 与 L2VPN"
date: 2026-04-09 22:30:00
tags: [vpp, mpls, l2vpn, ldp, vpls, evpn, label-switching, mpls-tunnel]
description: "深入解析 VPP MPLS：标签交换、LFIB 表、LDP 协议、VPLS、EVPN 与 MPLS VPN"
---

# VPP 深入探讨 ch09：MPLS 与 L2VPN

> [!abstract] 核心要点
> VPP 支持完整的 MPLS 功能，包括标签交换、LDP、VPLS 和 EVPN。本章深入解析 MPLS 架构、LFIB 表、标签操作与 L2VPN 实现。

## 1. MPLS 概述

### 1.1 为什么需要 MPLS

```
传统 IP 路由 vs MPLS：

IP 路由（每跳查找）：
  Router A → IP Lookup → Router B → IP Lookup → Router C
                ↑                           ↑
           慢速查找 (最长前缀)          慢速查找

MPLS（标签交换）：
  Router A → Label Swap → Router B → Label Swap → Router C
                ↑                           ↑
           快速查找 (标签)              快速查找
           O(1) 复杂度                  O(1) 复杂度

优势：
  - 快速转发（无需解析完整 IP 头）
  - Traffic Engineering (TE)
  - VPN (L2VPN/L3VPN)
  - QoS (EXP bits)
```

### 1.2 MPLS 标签格式

```
┌─────────────────────────────────────────────────────────────┐
│                    MPLS Label (4 bytes)                     │
│                                                              │
│  ┌─────────────────────────────────────────────────────────┤
│  │  Label (20 bits)  |  EXP (3 bits)  |  BoS (1 bit) | TTL │
│  │  标签值            |  QoS/CoS       |  栈底      | TTL │
│  └─────────────────────────────────────────────────────────┘
│                                                              │
│  Label 范围：                                                │
│  - 0-15:     保留 (特殊标签)                                 │
│  - 16-1023:  用于 LDP/BGP                                  │
│  - 1024-2^20:  用于静态 LSP                                │
│                                                              │
│  BoS (Bottom of Stack):                                     │
│  - 1: 这是最后一个标签                                       │
│  - 0: 后面还有更多标签                                       │
└─────────────────────────────────────────────────────────────┘

MPLS 标签栈（嵌套）：
  ┌────┬────┬────┐
  │ L3 │ L2 │ L1 │  ← 最外层是 L1
  │ (B)│    │    │  ← BoS = 0 表示还有
  └────┴────┴────┘
       │
       ▼ BoS = 1
  ┌────────┐
  │ Payload│
  └────────┘
```

## 2. MPLS 架构

### 2.1 MPLS 组件

```
┌─────────────────────────────────────────────────────────────┐
│                    VPP MPLS 组件                           │
│                                                              │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐       │
│  │   MPLS     │  │    LDP      │  │    BGP      │       │
│  │  Input     │  │  ( signaling)│  │  (VPN/      │       │
│  │            │  │             │  │   EVPN)     │       │
│  └─────────────┘  └─────────────┘  └─────────────┘       │
│                                                              │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐       │
│  │   LFIB     │  │   MPLS     │  │   MPLS     │       │
│  │ (Label FIB)│  │   Output   │  │  GSO       │       │
│  └─────────────┘  └─────────────┘  └─────────────┘       │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 MPLS 标签操作

```c
// MPLS 标签操作类型
enum mpls_operation {
    MPLS_OP_PUSH,      // 压入标签
    MPLS_OP_POP,       // 弹出标签
    MPLS_OP_SWAP,      // 交换标签
    MPLS_OP_PHP,       // Penultimate Hop Popping
};

// MPLS 标签头
typedef struct {
    u32 label_exp_s_bos;  // label(20) | exp(3) | s(1) | ttl(8)
} mpls_unicast_header_t;

// MPLS Input Node
VLIB_NODE_FN(mpls_input_node)
{
    u32 *from = vlib_frame_vector_args(frame);
    u32 n_packets = frame->n_vectors;

    for (u32 i = 0; i < n_packets; i++) {
        vlib_buffer_t *b = vlib_get_buffer(vm, from[i]);

        // 获取 MPLS 头
        mpls_unicast_header_t *hdr =
            vlib_buffer_get_current(b);

        // 提取标签
        u32 label = (hdr->label_exp_s_bos >> 12);

        // 查找 LFIB
        lfib_entry_t *entry = lfib_lookup(label);

        if (!entry) {
            // 没有匹配，丢弃
            vlib_buffer_free(vm, &from[i], 1);
            continue;
        }

        // 执行标签操作
        switch (entry->op) {
        case MPLS_OP_POP:
            // 弹出 MPLS 头，发送到 IP/L2 输入
            vlib_buffer_advance(b, sizeof(*hdr));
            vlib_put_next_frame(vm, node, MPLS_NEXT_IP_INPUT, 1);
            break;

        case MPLS_OP_SWAP:
            // 交换标签
            hdr->label_exp_s_bos =
                (entry->out_label << 12) |
                (hdr->label_exp_s_bos & 0x000FF1000);  // 保留 EXP/TTL
            // 发送到下一跳
            vlib_put_next_frame(vm, node, MPLS_NEXT_OUTPUT, 1);
            break;

        case MPLS_OP_PHP:
            // Penultimate Hop Popping
            // 倒数第二跳直接弹出，发送 IP 到最后一跳
            vlib_buffer_advance(b, sizeof(*hdr));
            vlib_put_next_frame(vm, node, MPLS_NEXT_IP_INPUT, 1);
            break;
        }
    }

    return n_packets;
}
```

## 3. LFIB (Label FIB)

### 3.1 LFIB 表

```c
// LFIB 条目
typedef struct {
    u32 local_label;        // 本地标签
    u32 remote_label;       // 远程标签 (for swap)

    // 下一跳信息
    u32 next_hop_adj_index;  // 邻接索引

    // 操作
    enum mpls_operation op;

    // NHLFE (Next Hop Label Forwarding Entry)
    u32 nhlfe_index;

    // 统计
    u64 packet_count;
    u64 byte_count;
} lfib_entry_t;

// LFIB 表
struct mpls_main_t {
    // 基于标签的 hash 表
    uword *lfib_hash;

    // 标签范围
    u32 label_range_start;
    u32 label_range_end;

    // 统计
    u64 in_labels_processed;
    u64 out_labels_sent;
};
```

### 3.2 LFIB 查找

```c
// LFIB 查找（O(1) 基于 hash）
static inline lfib_entry_t *
lfib_lookup(u32 label)
{
    mpls_main_t *mm = &mpls_main;

    uword *p = hash_get(mm->lfib_hash, label);
    if (p) {
        return (lfib_entry_t *)*p;
    }
    return NULL;
}

// 批量查找优化
static inline void
lfib_lookup_batch(u32 *labels, u32 n, lfib_entry_t **results)
{
    for (u32 i = 0; i < n; i++) {
        results[i] = lfib_lookup(labels[i]);
    }
}
```

## 4. LDP (Label Distribution Protocol)

### 4.1 LDP 概述

```
LDP 用于在 MPLS 网络中分发标签：

┌─────────────────────────────────────────────────────────────┐
│                    LDP Session                             │
│                                                              │
│  Router A ──────────────────────────────────────── Router B │
│                                                              │
│  LDP Messages:                                              │
│  - Hello (UDP 224.0.0.202)                                │
│  - Initialization (TCP 646)                                │
│  - KeepAlive (TCP 646)                                     │
│  - Label Mapping (TCP 646)                                 │
│                                                              │
│  LDP LSP 建立：                                             │
│  1. A 分配标签 L1 给 10.0.0.0/8                            │
│  2. B 分配标签 L2 给 10.0.0.0/8                            │
│  3. A 告诉 B: "用 L2 发送到 10.0.0.0/8 的包"               │
│  4. B 告诉 A: "用 L1 发送到 10.0.0.0/8 的包"               │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 LDP 配置

```bash
# 启用 LDP
vpp# mpls ldp enable

# 配置 LDP 邻居
vpp# ldp neighbor 10.0.0.2

# 配置 LDP 标签范围
vpp# ldp label local 1000-1999

# 查看 LDP
vpp# show mpls ldp
vpp# show mpls ldp neighbor
vpp# show mpls ldp bindings
```

### 4.3 LDP 实现

```c
// LDP 标签分发
static void
ldp_send_label_mapping(fib_prefix_t *prefix, u32 local_label)
{
    ldp_packet_t *pkt = ldp_alloc_packet();

    // 填充消息
    pkt->type = LDP_TYPE_LABEL_MAPPING;
    pkt->msg_id = ++ldp_msg_id_counter;

    // FEC 元素
    pkt->fec.prefix = *prefix;
    pkt->fec.type = LDP_FEC_WILDCARD;  // 通用 FEC

    // 标签
    pkt->label = local_label;

    // 发送
    ldp_send_to_peer(peer, pkt);
}

// LDP 标签接收
static void
ldp_recv_label_mapping(ldp_packet_t *pkt, peer_t *peer)
{
    // 添加到 LFIB
    lfib_entry_t *entry = lfib_entry_alloc();
    entry->local_label = pkt->local_label;  // 远程标签
    entry->remote_label = pkt->label;
    entry->op = MPLS_OP_SWAP;
    entry->next_hop_adj_index = peer->adj_index;

    // 安装到 LFIB
    lfib_add(entry);

    // 如果是递归路由，可能需要触发新的标签分发
    ldp_resolve_fec(pkt->fec);
}
```

## 5. L2VPN

### 5.1 L2VPN 类型

```
L2VPN 两种模式：

VPLS (Virtual Private LAN Service)：
  - 模拟 LAN (多站点以太网)
  - MAC 学习在提供商网络中
  - 类似 Ethernet

L2VPN (Kompella/pseudowire)：
  - 点到点连接
  - 不需要 MAC 学习
  - 更简单
```

### 5.2 VPLS 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    VPLS 架构                               │
│                                                              │
│  Site A ───────┐                                            │
│                 │     ┌──────────────────────┐              │
│  Site B ────────┼────▶│      Provider       │              │
│                 │     │                      │              │
│  Site C ────────┘     │   ┌──────────────┐  │              │
│                       │   │    VPLS      │  │              │
│                       │   │   Bridge     │  │              │
│                       │   │   Domain     │  │              │
│                       │   └──────┬───────┘  │              │
│                       │          │          │              │
│                       └──────────┼──────────┘              │
│                                  │                          │
│                    Label Switch Path (MPLS)                 │
└─────────────────────────────────────────────────────────────┘
```

### 5.3 VPLS 配置

```bash
# 创建 VPLS 实例
vpp# create bridge-domain 10

# 添加 VPLS 接口（伪线）
vpp# create l2vpnPseudowire name pw1
vpp# set l2vpnPseudowire bridge-domain 10 pw pw1

# 配置 LDP 信令
vpp# l2vpn pw static

# 查看 VPLS
vpp# show vpls
vpp# show l2vpn
```

## 6. EVPN (Ethernet VPN)

### 6.1 EVPN vs VPLS

```
EVPN vs VPLS：

VPLS：
  - 控制平面：LDP 或 BGP
  - 数据平面：MAC 学习通过洪泛
  - 收敛慢，有环路风险

EVPN：
  - 控制平面：BGP EVPN
  - 数据平面：MAC 通过 BGP 分发
  - 快速收敛，无洪泛

┌─────────────────────────────────────────────────────────────┐
│                    EVPN 架构                               │
│                                                              │
│  Control Plane (BGP EVPN):                                  │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Site A: MAC-A → BGP EVPN → Provider BGP           │  │
│  │  Site B: BGP EVPN → MAC-A → Route to Site A       │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                              │
│  Data Plane:                                                │
│  - 基于 MPLS 或 VXLAN                                      │
│  - 无需洪泛学习 MAC                                         │
└─────────────────────────────────────────────────────────────┘
```

### 6.2 BGP EVPN 消息

```c
// EVPN Route Types
enum evpn_route_type {
    EVPN_ROUTE_TYPE_EAD,      // Ethernet Auto-Discovery
    EVPN_ROUTE_TYPE_MAC_IP,   // MAC/IP Advertisement
    EVPN_ROUTE_TYPE_INC,      // Inclusive Multicast
    EVPN_ROUTE_TYPE_ETH_SEG,  // Ethernet Segment
};

// EVPN MAC/IP Advertisement
typedef struct {
    // RD (Route Distinguisher)
    u64 rd;

    // ESI (Ethernet Segment Identifier)
    u8 esi[10];

    // MAC Address
    u8 mac[6];

    // IP Address (可选)
    ip46_address_t ip;

    // MPLS Label
    u32 label;
} evpn_mac_ip_t;

// BGP EVPN 处理
static void
evpn_recv_mac_ip_advert(evpn_mac_ip_t *adv)
{
    // 添加到本地 MAC 表
    mac_entry_t *entry = mac_table_add(adv->mac);
    entry->esi = adv->esi;
    entry->label = adv->label;

    // 安装到 LFIB
    lfib_add(adv->mac, adv->label);
}
```

### 6.3 EVPN 配置

```bash
# 配置 BGP EVPN
vpp# set ip table 0
vpp# router bgp 65001
vpp#  neighbor 10.0.0.2 remote-as 65002
vpp#  address-family l2vpn evpn
vpp#   neighbor 10.0.0.2 activate

# 配置 EVPN 实例
vpp# evpn create
vpp# evpn add-instance

# 配置 EVI (EVPN Instance)
vpp# evpn attach

# 查看 EVPN
vpp# show evpn
vpp# show evpn mac
vpp# show evpn arp
```

## 7. MPLS Traffic Engineering

### 7.1 RSVP-TE

```
RSVP-TE 用于建立带约束的 LSP：

┌─────────────────────────────────────────────────────────────┐
│                    RSVP-TE LSP                            │
│                                                              │
│  Path:  A ──▶ B ──▶ C ──▶ D                                │
│         │              │                                    │
│         └──────────────┘                                    │
│           Traffic Engineering Path                          │
│                                                              │
│  RSVP-TE Messages:                                          │
│  - Path (带宽请求)                                          │
│  - Resv (预留确认)                                         │
│  - PathErr (错误)                                           │
│  - ResvErr (错误)                                          │
└─────────────────────────────────────────────────────────────┘
```

### 7.2 TE 配置

```bash
# 配置 RSVP-TE
vpp# mpls traffic-eng enable

# 创建 TE LSP
vpp# mpls traffic-eng lsp add lsp1
vpp# set mpls traffic-eng lsp lsp1 path explicit path1

# 配置带宽
vpp# set mpls traffic-eng lsp lsp1 bandwidth 100M

# 查看 TE
vpp# show mpls traffic-eng
vpp# show mpls traffic-eng lsp
```

## 8. 总结

MPLS 核心概念：

| 组件 | 功能 | 关键点 |
|------|------|--------|
| **LFIB** | 标签转发表 | O(1) hash 查找 |
| **LDP** | 标签分发 | UDP hello + TCP session |
| **BGP EVPN** | EVPN 控制平面 | MAC 通过 BGP 学习 |
| **VPLS** | 模拟 LAN | LDP 信令 + MAC 学习 |
| **RSVP-TE** | 流量工程 | 带约束的 LSP |

标签操作：

```
PUSH:   [Label N][Label N-1]...[Label 1] → [Label M][Label N]...[Label 1]
POP:    [Label N][Label N-1]...[Label 1] → [Label N-1]...[Label 1] (BoS)
SWAP:   [Label N] → [Label M]
PHP:    [Label N][Label 1] (倒数第二跳) → [Label 1] (最后一跳)
```

---

## 参考资源

- [MPLS RFC 3031](https://tools.ietf.org/html/rfc3031)
- [LDP RFC 5036](https://tools.ietf.org/html/rfc/rfc5036)
- [EVPN RFC 7432](https://tools.ietf.org/html/rfc7432)
- [VPLS RFC 4762](https://tools.ietf.org/html/rfc4762)
