---
title: "VPP 深入探讨 ch07：L3 转发与 IP Forwarding"
date: 2026-04-09 21:30:00
tags: [vpp, l3, ip-forwarding, fib, routing, arp, ndp, fib-lookup]
description: "深入解析 VPP L3 转发：FIB 表结构、路由查找算法、ARP/NDP 代理、负载均衡与 FIB 卸载"
---

# VPP 深入探讨 ch07：L3 转发与 IP Forwarding

> [!abstract] 核心要点
> VPP 的 L3 转发基于 FIB (Forwarding Information Base)。本章深入解析 FIB 表结构、路由查找算法 (LC-trie)、ARP/NDP 代理、负载均衡与硬件卸载。

## 1. L3 转发概述

### 1.1 L3 vs L2 转发

```
L2 转发：基于 MAC 地址，同一广播域内
L3 转发：基于 IP 地址，跨网络路由

┌─────────────────────────────────────────────────────────────┐
│                    L3 转发流程                              │
│                                                              │
│  收到 IP Packet                                              │
│       │                                                      │
│       ▼                                                      │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ 1. 检查 TTL                                             │  │
│  │ 2. 验证 IP Checksum                                    │  │
│  │ 3. 查找 FIB (最长前缀匹配)                             │  │
│  │ 4. TTL 减 1，重新计算 Checksum                         │  │
│  │ 5. 查找下一跳 MAC (ARP/NDP)                            │  │
│  │ 6. 转发到出口                                          │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 VPP IP 组件

```
┌─────────────────────────────────────────────────────────────┐
│                    VPP IP 组件                            │
│                                                              │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐       │
│  │   IP4      │  │   IP6      │  │   FIB      │       │
│  │  Forward   │  │  Forward   │  │  (Route)   │       │
│  └─────────────┘  └─────────────┘  └─────────────┘       │
│                                                              │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐       │
│  │   ARP      │  │   NDP      │  │   ICMP    │       │
│  │  Proxy     │  │  Proxy     │  │           │       │
│  └─────────────┘  └─────────────┘  └─────────────┘       │
└─────────────────────────────────────────────────────────────┘
```

## 2. FIB 表结构

### 2.1 FIB 条目

```c
// FIB 条目结构
typedef struct fib_entry_t {
    // 路由前缀
    ip46_prefix_t prefix;

    // 协议相关数据 (union)
    union {
        // 递归下一跳
        struct {
            u32 fib_index;        // 递归到的 FIB
            u32 entry_index;     // 递归到的 entry
        } recurse;

        // 递归下一跳信息
        struct {
            u32 adj_index;        // 邻接表索引
            u32 weight;          // ECMP 权重
        } next_hop;
    } fib_entry_proto;

    // 元数据
    u32 flags;
    u16 path_list_head_index;
    u8  prefixlen;

    // 统计
    u64 packet_count;
    u64 byte_count;
} fib_entry_t;

// FIB 标志
enum {
    FIB_ENTRY_FLAG_NONE            = 0,
    FIB_ENTRY_FLAG_CONNECTED       = (1 << 0),  // 直连路由
    FIB_ENTRY_FLAG_STATIC          = (1 << 1),  // 静态路由
    FIB_ENTRY_FLAG_DYNAMIC          = (1 << 2),  // 动态协议
    FIB_ENTRY_FLAG_RECURSIVE        = (1 << 3),  // 递归路由
    FIB_ENTRY_FLAG_MULTIPATH        = (1 << 4),  // ECMP
    FIB_ENTRY_FLAG_DROP             = (1 << 5),  // 黑洞路由
    FIB_ENTRY_FLAG_LOCAL            = (1 << 6),  // 本地路由
};
```

### 2.2 FIB 表

```c
// FIB 表（per address family）
typedef struct {
    // 表 ID（VRF）
    u32 table_id;

    // 地址族
    ip46_af_t af;

    // 路由条目数
    u32 fib_entry_n;

    // 路由表（LC-trie）
    lc_trie_t *fib_trie;

    // 全局 FIB（用于快速查找）
    fib_entry_t **fib_entry_by_prefix;
} fib_table_t;

// 全局 FIB 管理
struct fib_main_t {
    // IPv4 和 IPv6 表
    fib_table_t *fibs_by_vrf[2];

    // 默认表
    fib_table_t *default_fib;
};
```

### 2.3 LC-trie 查找算法

```
LC-trie (Level Compressed Trie)：

将路由表压缩成 trie 结构，减少节点数

示例路由表：
  10.0.0.0/8
  10.1.0.0/16
  10.1.1.0/24
  10.2.0.0/16
  192.168.1.0/24

LC-trie 结构：
           [root]
           /    \
        [10]    [192]
         |       |
       [0.0]   [168]
        / \      |
    [1.0] [2.0] [1]
      |
    [1.0/24]

特点：
- 高压缩比（适合大规模路由表）
- 查找复杂度：O(k)，k = 深度（通常 < 32）
- 支持前缀最长匹配
```

### 2.4 FIB 查找实现

```c
// FIB 查找（最长前缀匹配）
static inline fib_entry_t *
fib_table_lookup(fib_table_t *fib, ip46_address_t *addr)
{
    lc_trie_t *trie = fib->fib_trie;
    u32 prefix_len = 0;
    fib_entry_t *result = NULL;

    // 从根节点开始
    lc_trie_node_t *node = trie->root;
    lc_trie_node_t *current = node;

    // 逐层遍历
    for (int i = 0; i < 128; i++) {
        if (!node) break;

        // 获取当前比特
        int bit = get_bit(addr, i);

        // 检查是否有子节点
        if (node->child[bit]) {
            node = node->child[bit];
            prefix_len = i + 1;

            // 检查这个节点是否有 fib entry
            if (node->fib_entry) {
                result = node->fib_entry;
            }
        } else {
            // 没有更长的匹配，停止
            break;
        }
    }

    // 如果没找到精确匹配，返回默认路由（0.0.0.0/0）
    if (!result && trie->default_route) {
        result = trie->default_route;
    }

    return result;
}
```

## 3. 路由查找流程

### 3.1 IP4 Input Node

```c
// IP4 Input Node
VLIB_NODE_FN(ip4_input_node)
{
    u32 *from = vlib_frame_vector_args(frame);
    u32 n_packets = frame->n_vectors;

    for (u32 i = 0; i < n_packets; i++) {
        vlib_buffer_t *b = vlib_get_buffer(vm, from[i]);
        ip4_header_t *ip = vlib_buffer_get_current(b);

        // 1. 检查 IP 版本
        if (ip->version != 4) {
            // 不是 IPv4，转发错误
            b->error = IP4_ERROR_BAD_VERSION;
            next_index = IP4_INPUT_NEXT_ERROR;
            continue;
        }

        // 2. TTL 检查
        if (ip->ttl == 0) {
            // TTL 耗尽，发送 ICMP
            b->error = IP4_ERROR_TTL_EXPIRED;
            next_index = IP4_INPUT_NEXT_ICMP_ERROR;
            continue;
        }

        // 3. Checksum 验证
        if (ip4_header_checksum(ip) != 0) {
            b->error = IP4_ERROR_BAD_CHECKSUM;
            next_index = IP4_INPUT_NEXT_DROP;
            continue;
        }

        // 4. 查找 FIB
        fib_entry_t *fib_entry = fib_table_lookup4(fib, &ip->dst_address);

        if (!fib_entry) {
            // 没有匹配路由，丢弃
            b->error = IP4_ERROR_NO_ROUTE;
            next_index = IP4_INPUT_NEXT_DROP;
            continue;
        }

        // 5. 检查是否是本地交付
        if (fib_entry->flags & FIB_ENTRY_FLAG_LOCAL) {
            // 发送到本地
            next_index = IP4_INPUT_NEXT_LOOKUP;
            // ... 本地处理
        } else {
            // 转发
            next_index = IP4_INPUT_NEXT_REWRITE;
        }

        // 保存 fib entry 索引到 buffer
        b->flow_id = fib_entry_index;
    }

    return n_packets;
}
```

### 3.2 TTL 和 Checksum 处理

```c
// TTL 减 1 并更新 Checksum
static_always_inline void
ip4_ttl_checksum_update(ip4_header_t *ip)
{
    // TTL 减 1
    ip->ttl--;

    // Checksum 调整（比重新计算快）
    // RFC 1624: HC = ~HC + ~m + m'
    // 其中 m 是旧值，m' 是新值
    u32 hc = ~ip->checksum;
    u32 old_ttl = ip->ttl + 1;  // 旧值

    u32 sum = hc + (~old_ttl & 0xFFFF) + ip->ttl;
    sum = (sum >> 16) + (sum & 0xFFFF);
    sum = (sum >> 16) + sum;

    ip->checksum = ~sum;
}

// IPv6 Hop Limit 处理
static_always_inline void
ip6_hop_limit_update(ip6_header_t *ip6)
{
    ip6->hop_limit--;
    // IPv6 没有 checksum（使用 pseudo-header）
}
```

## 4. ARP 与邻居发现

### 4.1 ARP 表

```c
// ARP 条目
typedef struct {
    ip4_address_t ip4;          // IP 地址
    u8 mac[6];                  // MAC 地址
    u32 sw_if_index;            // 接口
    u8 state;                   // 状态
    u32 last_update;            // 最后更新
} arp_entry_t;

// ARP 状态
enum arp_state {
    ARP_STATE_DYNAMIC,          // 动态学习
    ARP_STATE_STATIC,           // 静态配置
    ARP_STATE_RESOLVED,         // 已解析
    ARP_STATE_PENDING,          // 等待解析
};
```

### 4.2 ARP 请求

```c
// 发送 ARP 请求
static void
arp_request(vlib_main_t *vm, ip4_address_t ip, u32 sw_if_index)
{
    vlib_buffer_t *b = vlib_buffer_alloc(vm, 1);
    if (!b) return;

    // 构造 ARP 请求
    ethernet_header_t *eth = vlib_buffer_put_uninit(b, sizeof(ethernet_header_t) + sizeof(arp_header_t));

    // Ethernet 头
    memset(eth->dst_address, 0xFF, 6);  // 广播
    eth->src_address = hw_interface->mac_address;
    eth->type = rte_cpu_to_be_16(ETHERNET_TYPE_ARP);

    // ARP 头
    arp_header_t *arp = (arp_header_t *)(eth + 1);
    arp->hw_type = rte_cpu_to_be_16(1);         // Ethernet
    arp->proto_type = rte_cpu_to_be_16(0x0800);  // IP
    arp->hw_len = 6;
    arp->proto_len = 4;
    arp->opcode = rte_cpu_to_be_16(ARP_REQUEST);
    memcpy(arp->src_hw_address, hw_interface->mac_address, 6);
    arp->src_proto_address = local_ip;
    memset(arp->dst_hw_address, 0, 6);
    arp->dst_proto_address = ip;

    // 发送到网络
    vlib_put_next_frame(vm, node, ARP_NEXT_OUTPUT, 1);
}
```

### 4.3 ARP 代理

```c
// ARP 代理配置
static int
arp_proxy_enable(u32 sw_if_index, ip4_address_t *start, ip4_address_t *end)
{
    arp_proxy_t *proxy = clib_alloc(sizeof(*proxy));
    proxy->sw_if_index = sw_if_index;
    proxy->start = *start;
    proxy->end = *end;

    vec_add1(arp_proxies, proxy);
    return 0;
}

// ARP 代理处理
static_always_inline int
arp_proxy_lookup(vlib_buffer_t *b, ip4_address_t *ip)
{
    // 检查是否在代理范围内
    for (int i = 0; i < vec_len(arp_proxies); i++) {
        arp_proxy_t *p = &arp_proxies[i];

        if (ip_in_range(ip, &p->start, &p->end)) {
            // 返回代理的 MAC
            return p->sw_if_index;
        }
    }
    return -1;
}
```

## 5. ECMP 与负载均衡

### 5.1 ECMP 类型

```
VPP 支持多种 ECMP 模式：

1. Round Robin (默认)
2. Random
3. Hash (基于 5-tuple)
4. L4 Hash (基于 src/dst port)
```

### 5.2 ECMP 哈希

```c
// ECMP 哈希计算
static inline u32
ip4_ecmp_hash(ip4_header_t *ip, udp_header_t *udp)
{
    // 5-tuple hash
    u32 hash = 0;

    // Source IP
    hash = ip->src_address.data_u32;

    // Destination IP
    hash ^= ip->dst_address.data_u32;

    // Layer 4 ports (如果存在)
    if (udp) {
        hash ^= udp->src_port;
        hash ^= udp->dst_port;
    }

    // 或者只用 src/dst IP (faster)
    // hash = ip->src_address.data_u32 ^ ip->dst_address.data_u32;

    return hash;
}

// ECMP 选择
static inline u32
ecmp_select_next_hop(fib_entry_t *fib_entry, u32 hash)
{
    // 获取下一跳数量
    u32 n_paths = fib_entry->n_paths;

    if (n_paths == 1) {
        return 0;
    }

    // 加权选择
    if (fib_entry->flags & FIB_ENTRY_FLAG_WEIGHTED) {
        // 根据权重选择
        u32 total_weight = fib_entry->total_weight;
        u32 h = hash % total_weight;

        // ... 遍历找对应的路径
        return path_index;
    }

    // 普通 ECMP
    return hash % n_paths;
}
```

### 5.3 Per-flow 负载均衡

```
Per-flow 负载均衡确保同一流走同一路径：

Flow = (src_ip, dst_ip, src_port, dst_port, protocol)

┌─────────────────────────────────────────────────────────────┐
│                    Per-flow 负载均衡                        │
│                                                              │
│  Flow 1: (10.0.0.1, 20.0.0.1, 1000, 80, TCP)               │
│           Hash = 12345 % 4 = 1 → Path 1                     │
│                                                              │
│  Flow 2: (10.0.0.2, 20.0.0.1, 2000, 80, TCP)               │
│           Hash = 54321 % 4 = 2 → Path 2                     │
│                                                              │
│  Flow 3: (10.0.0.1, 20.0.0.1, 1001, 80, TCP)  ← 不同 port  │
│           Hash = 12346 % 4 = 0 → Path 0                     │
└─────────────────────────────────────────────────────────────┘
```

## 6. IPv6 转发

### 6.1 IPv6 FIB

```c
// IPv6 查找类似 IPv4，但地址 128 位
static inline fib_entry_t *
fib6_table_lookup(fib_table_t *fib6, ip6_address_t *addr)
{
    // 128 位遍历
    for (int i = 0; i < 128; i++) {
        // 类似 IPv4 的 trie 查找
    }
}
```

### 6.2 NDP (Neighbor Discovery Protocol)

```c
// NDP 邻居请求
typedef struct {
    u8 type;              // 135 = Neighbor Solicitation
    u8 code;
    u16 checksum;
    u32 reserved;
    ip6_address_t target;  // 请求的 IP
    // Options...
} nd_neighbor_solicitation_t;

// NDP 邻居通告
typedef struct {
    u8 type;              // 136 = Neighbor Advertisement
    u8 code;
    u16 checksum;
    u8 flags;
    u8 reserved[3];
    ip6_address_t target;   // 通告的 IP
    // Options: LLADDR (MAC)
} nd_neighbor_advertisement_t;
```

## 7. FIB 卸载

### 7.1 硬件卸载概述

```
VPP 可以将 FIB 表卸载到硬件：

┌─────────────────────────────────────────────────────────────┐
│                    FIB 卸载                                 │
│                                                              │
│  VPP FIB (软件) ──────── 硬件 FIB (NIC/switch)              │
│                                                              │
│  适合场景：                                                   │
│  - 大型 FIB (millions of routes)                           │
│  - 硬件快速查找                                              │
│  - 释放 CPU                                                  │
└─────────────────────────────────────────────────────────────┘
```

### 7.2 ACL 卸载

```bash
# 配置 FIB 卸载
vpp# set ip flow offload enable
vpp# set interface feature arc ip4-multicast gigabitEthernet0/8/0 enable
```

## 8. 总结

VPP L3 转发核心组件：

| 组件          | 功能          | 关键算法     |
| ------------- | ------------- | ------------ |
| **FIB**       | 路由表        | LC-trie      |
| **IP4 Input** | IPv4 输入处理 | TTL/Checksum |
| **IP6 Input** | IPv6 输入处理 | Hop Limit    |
| **ARP**       | IPv4 邻居解析 | 动态/静态    |
| **NDP**       | IPv6 邻居解析 | 邻居通告     |
| **Rewrite**   | 封装处理      | L2 头写入    |
| **ECMP**      | 负载均衡      | Hash 选择    |

查找流程：

```
IP Packet
    ↓
TTL/Checksum 检查
    ↓
FIB Lookup (LC-trie)
    ↓
选择 Path (ECMP 或单一)
    ↓
ARP/NDP Lookup (获取下一跳 MAC)
    ↓
L2 Rewrite (封装)
    ↓
Output
```

---

## 参考资源

- [VPP IP 文档](https://wiki.fd.io/view/VPP/IP)
- [RFC 1812 - Requirements for IP Routers](https://tools.ietf.org/html/rfc1812)
- [LC-trie 论文](https://citeseerx.ist.psu.edu/viewdoc/summary?doi=10.1.1.32.8918)
