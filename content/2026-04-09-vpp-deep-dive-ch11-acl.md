---
title: "VPP 深入探讨 ch11：ACL 架构与实现"
date: 2026-04-09 23:30:00
tags: [vpp, acl, access-control, l2-l4, macip, packet-filtering, security]
description: "深入解析 VPP ACL：L2-L4 ACL 架构、MACIP ACL、ACL 查找算法、硬件卸载与 ACL 日志"
---

# VPP 深入探讨 ch11：ACL 架构与实现

> [!abstract] 核心要点
> VPP ACL (Access Control List) 提供 L2-L4 包过滤能力。本章深入解析 ACL 架构、条目匹配算法、MACIP ACL、硬件卸载与 ACL 日志。

## 1. ACL 概述

### 1.1 ACL 类型

```
┌─────────────────────────────────────────────────────────────┐
│                    VPP ACL 类型                             │
│                                                              │
│  L2 ACL:                                                    │
│  - src/dst MAC 地址                                        │
│  - EtherType                                               │
│  - VLAN tag                                                 │
│                                                              │
│  L3 ACL:                                                    │
│  - src/dst IP 地址                                         │
│  - IP protocol                                              │
│  - ICMP type/code                                          │
│                                                              │
│  L4 ACL:                                                    │
│  - src/dst port (TCP/UDP)                                 │
│  - TCP flags                                               │
│  - DSCP                                                     │
│                                                              │
│  组合 ACL:                                                  │
│  - 5-tuple (src_ip, dst_ip, protocol, src_port, dst_port) │
│  - 应用层标记 (APP-tag)                                     │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 ACL 动作

```
┌─────────────────────────────────────────────────────────────┐
│                    ACL 动作                                 │
│                                                              │
│  permit:    允许包通过                                     │
│  deny:       丢弃包                                        │
│  permit+reflect: 允许并反射（用于带状态的 ACL）            │
│  permit+trap:   允许并发送 trap 到控制平面                 │
│  deny+trap:     丢弃并发送 trap                            │
└─────────────────────────────────────────────────────────────┘
```

## 2. ACL 架构

### 2.1 ACL 数据结构

```c
// ACL 条目
typedef struct {
    // L2
    u8 src_mac[6];
    u8 src_mac_mask[6];
    u8 dst_mac[6];
    u8 dst_mac_mask[6];
    u16 ether_type;
    u16 ether_type_mask;

    // L3
    u8 is_ip;                    // 0 = L2, 1 = IP
    ip46_address_t src_ip[2];    // IPv4/IPv6
    ip46_address_t src_ip_mask[2];
    ip46_address_t dst_ip[2];
    ip46_address_t dst_ip_mask[2];
    u8 proto;                    // TCP/UDP/ICMP/ANY
    u8 proto_mask;

    // L4
    u16 src_port_range[2];      // lo, hi
    u16 dst_port_range[2];

    // TCP flags
    u8 tcp_flags_mask;          // FIN/SYN/RST/PSH/ACK/URG
    u8 tcp_flags_value;

    // DSCP
    u8 dscp;
    u8 dscp_mask;

    // Action
    u8 is_permit;

    // Meta
    u32 hit_count;
    u32 id;                      // ACL ID
} acl_entry_t;

// ACL 表
typedef struct {
    u32 acl_id;
    u32 count;                   // 条目数
    acl_entry_t *entries;

    // 查找优化
    struct rte_hash *hash;       // 高速查找
    struct rte_acl_ctx *acl_ctx; // ACL 规则引擎
} acl_table_t;

// ACL Main
struct acl_main_t {
    acl_table_t *acls;
    u32 num_acls;

    // 统计
    u64 pkts_allowed;
    u64 pkts_denied;
    u64 bytes_allowed;
    u64 bytes_denied;
};
```

### 2.2 ACL 配置

```bash
# 创建 ACL
vpp# acl add permit ip
vpp# acl add deny tcp

# 应用 ACL 到接口
vpp# set interface input acl GigabitEthernet0/8/0 ip4 acl 10 in
vpp# set interface output acl GigabitEthernet0/8/0 ip4 acl 10 out

# 查看 ACL
vpp# show acl

# 查看 ACL 统计
vpp# show acl stats
```

## 3. ACL 查找

### 3.1 线性查找

```c
// 简单线性查找（ACL 条目少时）
static inline int
acl_match_linear(acl_entry_t *e, vlib_buffer_t *b,
                 ethernet_header_t *eth, ip4_header_t *ip)
{
    // L2 检查
    if (e->ether_type_mask) {
        if (!mac_match(&eth->src_address, e->src_mac, e->src_mac_mask))
            return 0;
        if (!mac_match(&eth->dst_address, e->dst_mac, e->dst_mac_mask))
            return 0;
        if ((eth->ether_type & e->ether_type_mask) !=
            (e->ether_type & e->ether_type_mask))
            return 0;
    }

    // L3 检查
    if (e->is_ip) {
        if (!ip_match(ip->src_address, e->src_ip, e->src_ip_mask))
            return 0;
        if (!ip_match(ip->dst_address, e->dst_ip, e->dst_ip_mask))
            return 0;
        if (!proto_match(ip->protocol, e->proto, e->proto_mask))
            return 0;
    }

    // L4 检查
    if (e->proto == IP_PROTO_TCP ||
        e->proto == IP_PROTO_UDP) {
        tcp_header_t *tcp = get_tcp_header(ip);
        if (!port_match(tcp->src_port, e->src_port_range))
            return 0;
        if (!port_match(tcp->dst_port, e->dst_port_range))
            return 0;
    }

    return 1;  // 匹配
}
```

### 3.2 DPDK ACL (rte_acl)

```c
// 使用 DPDK ACL 库加速查找
struct rte_acl_ctx *
acl_build_dpi_acl(acl_table_t *acl)
{
    struct rte_acl_config cfg = {0};
    struct rte_acl_field fields[24];
    int field_count = 0;

    // 配置字段（24 字节 IPv4 5-tuple）
    // field 0: src IPv4 (1 byte)
    // field 1: src IPv4 (2 bytes)
    // field 2: src IPv4 (1 byte)
    // field 3: dst IPv4 (1 byte)
    // field 4: dst IPv4 (2 bytes)
    // field 5: dst IPv4 (1 byte)
    // field 6: src port (2 bytes)
    // field 7: dst port (2 bytes)
    // field 8: proto (1 byte)

    cfg.num_fields = field_count;
    cfg.num_categories = 1;

    struct rte_acl_ctx *ctx = rte_acl_create(&cfg);

    // 添加规则
    for (i = 0; i < acl->count; i++) {
        struct rte_acl_rule rule = convert_to_rte_acl_rule(&acl->entries[i]);
        rte_acl_add_rules(ctx, &rule, 1);
    }

    // 构建
    rte_acl_build(ctx, &cfg);

    return ctx;
}

// ACL 查找
static inline int
acl_lookup_dpi(acl_table_t *acl, vlib_buffer_t *b)
{
    struct rte_mbuf *pkt = mb;

    // 构造 ACL 查找 key
    uint8_t key[64];
    ip4_header_t *ip = get_ip_header(b);
    tcp_udp_header_t *tcp = get_tcpudp_header(ip);

    key[0] = (ip->src_address >> 24) & 0xFF;
    key[1] = (ip->src_address >> 16) & 0xFF;
    key[2] = (ip->src_address >> 8) & 0xFF;
    key[3] = ip->src_address & 0xFF;
    // ... 填充其他字段

    // 执行查找
    int result = rte_acl_match(acl->acl_ctx, key);

    return result;
}
```

## 4. MACIP ACL

### 4.1 MACIP ACL 格式

```
MACIP ACL 格式（用于 L2 安全）：

┌─────────────────────────────────────────────────────────────┐
│                    MACIP ACL Entry                          │
│                                                              │
│  ┌─────────────────────────────────────────────────────────┤
│  │  src MAC (6 bytes)    │  src MAC Mask (6 bytes)       │  │
│  ├─────────────────────────────────────────────────────────┤
│  │  dst MAC (6 bytes)    │  dst MAC Mask (6 bytes)       │  │
│  ├─────────────────────────────────────────────────────────┤
│  │  EtherType (2 bytes)  │  EtherType Mask (2 bytes)    │  │
│  ├─────────────────────────────────────────────────────────┤
│  │  src IP (4/16 bytes)  │  src IP Prefix (1 byte)       │  │
│  ├─────────────────────────────────────────────────────────┤
│  │  dst IP (4/16 bytes)  │  dst IP Prefix (1 byte)       │  │
│  ├─────────────────────────────────────────────────────────┤
│  │  Protocol (1 byte)     │  Action (1 byte)              │  │
│  └─────────────────────────────────────────────────────────┘
└─────────────────────────────────────────────────────────────┘
```

### 4.2 MACIP 配置

```bash
# 创建 MACIP ACL
vpp# macip acl add permit aa:bb:cc:dd:ee:ff ff:ff:ff:ff:ff:ff 10.0.0.0/24

# 应用到接口
vpp# set interface l2 macip acl GigabitEthernet0/8/0 macip_acl 10 in

# 查看 MACIP ACL
vpp# show macip acl
```

## 5. 接口 ACL 绑定

### 5.1 ACL 绑定点

```
┌─────────────────────────────────────────────────────────────┐
│                    ACL 绑定点                               │
│                                                              │
│  Ingress (输入 ACL):                                        │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ NIC → ACL (input) → L2 Input → L3 Input → ...      │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                              │
│  Egress (输出 ACL):                                         │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ ... → L3 Output → L2 Output → ACL (output) → NIC   │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                              │
│  绑定类型：                                                  │
│  - per-interface (每个接口)                                 │
│  - per-VRF (每个虚拟路由表)                                │
│  - per-BD (每个桥接域)                                     │
└─────────────────────────────────────────────────────────────┘
```

### 5.2 ACL Node

```c
// ACL Input Node
VLIB_NODE_FN(acl_inacl_node)
{
    u32 *from = vlib_frame_vector_args(frame);
    u32 n_packets = frame->n_vectors;

    for (u32 i = 0; i < n_packets; i++) {
        vlib_buffer_t *b = vlib_get_buffer(vm, from[i]);

        // 获取接口 ACL
        acl_table_t *acl = sw_if_index_to_acl(sw_if_index);

        if (!acl) {
            // 没有 ACL，允许所有
            vlib_put_next_frame(vm, node, ACL_NEXT_PERMIT, ...);
            continue;
        }

        // 查找 ACL
        int match = acl_lookup(acl, b);

        if (match >= 0) {
            acl_entry_t *e = &acl->entries[match];
            e->hit_count++;

            if (e->is_permit) {
                vlib_put_next_frame(vm, node, ACL_NEXT_PERMIT, ...);
            } else {
                if (e->trap) {
                    // 发送 trap
                    acl_send_trap(b, e);
                }
                vlib_put_next_frame(vm, node, ACL_NEXT_DENY, ...);
            }
        } else {
            // 无匹配，默认 deny
            vlib_put_next_frame(vm, node, ACL_NEXT_DENY, ...);
        }
    }

    return n_packets;
}
```

## 6. ACL 日志与统计

### 6.1 ACL 日志

```c
// ACL Log (通过 Netlink 发送)
typedef struct {
    u8 action;               // permit/deny
    u8 src_mac[6];
    u8 dst_mac[6];
    u32 src_ip;
    u32 dst_ip;
    u16 src_port;
    u16 dst_port;
    u8 proto;
    u64 timestamp;
} acl_log_entry_t;

// ACL 日志处理
static void
acl_log_packet(acl_entry_t *e, vlib_buffer_t *b)
{
    if (!(e->log)) return;

    acl_log_entry_t log;
    log.action = e->is_permit;

    // 填充日志数据
    // ...

    // 发送到日志子系统
    acl_netlink_send_log(&log);
}
```

### 6.2 ACL 统计

```bash
# 查看 ACL 统计
vpp# show acl stats

# 示例输出：
# ACL 10: 1000 packets, 500000 bytes permitted
# ACL 10: 50 packets, 25000 bytes denied
# ACL 20: 2000 packets, 1000000 bytes permitted

# 重置统计
vpp# clear acl stats
```

## 7. 硬件卸载

### 7.1 ACL 卸载概述

```
VPP ACL 可以卸载到硬件：

┌─────────────────────────────────────────────────────────────┐
│                    ACL 硬件卸载                              │
│                                                              │
│  软件 ACL:                                                   │
│  - 灵活性高                                                  │
│  - 适合复杂规则                                              │
│  - 性能有限                                                  │
│                                                              │
│  硬件 ACL (TCAM):                                           │
│  - 线速转发                                                 │
│  - 规则数量受限                                              │
│  - 适合简单规则                                             │
│                                                              │
│  混合模式：                                                  │
│  - 简单规则 → 硬件                                          │
│  - 复杂规则 → 软件                                          │
└─────────────────────────────────────────────────────────────┘
```

### 7.2 硬件卸载配置

```bash
# 启用 ACL 卸载
vpp# set acl hw offload enable

# 配置卸载规则
vpp# acl add permit tcp src 10.0.0.0/24 dst 20.0.0.0/24 src-port 80 dst-port *

# 查看卸载状态
vpp# show acl hw offload
```

## 8. 总结

VPP ACL 核心设计：

| 组件 | 功能 | 实现 |
|------|------|------|
| **ACL Entry** | 单条规则 | L2-L4 字段匹配 |
| **ACL Table** | 规则集合 | rte_acl 或线性查找 |
| **ACL Lookup** | 包分类 | DPDK ACL 库 |
| **MACIP ACL** | L2 安全 | MAC + IP 组合 |
| **Hardware Offload** | TCAM | 硬件加速 |

查找流程：

```
Packet
    ↓
查找接口绑定的 ACL
    ↓
按顺序遍历 ACL 条目
    ↓
第一个匹配的条目 → 执行动作
    ↓
无匹配 → 默认 deny (或 permit)
```

---

## 参考资源

- [VPP ACL](https://wiki.fd.io/view/VPP/ACL)
- [DPDK ACL](https://doc.dpdk.org/guides/prog_guide/acl_lib.html)
- [Linux netfilter](https://www.netfilter.org/)
