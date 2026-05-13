---
title: "DPDK 深度探索 (十一)：Ether/IP/UDP 协议处理与 Checksum Offload"
date: 2026-04-09
tags: [dpdk, series, ether, ipv4, ipv6, udp, checksum, offload, header-parse]
description: "深入理解 DPDK 协议处理——Ethernet/IPv4/IPv6/UDP 头部结构、解析方法、checksum 计算、以及 NIC 硬件卸载机制"
---

> [!info] DPDK 深度探索系列
> 0. [[2026-04-09-dpdk-deep-dive-series-index|全栈学习路径总览]]
> 1-10. 前十章已完成
> 11. **第十一章：Ether/IP/UDP 协议处理与 Checksum Offload**

---

## 1. 概述：DPDK 的协议处理

DPDK 应用需要对接收到的数据包进行协议解析：

```c
// 典型数据包处理流程

// 1. 接收数据包
rte_eth_rx_burst(port_id, queue_id, pkts, 32);

// 2. 解析协议头部
for each mbuf in pkts:
    eth = rte_pktmbuf_mtod(m, struct rte_ether_hdr *);

    if (eth->ether_type == RTE_ETHER_TYPE_IPV4) {
        ip = (struct rte_ipv4_hdr *)(eth + 1);

        if (ip->next_proto_id == IPPROTO_UDP) {
            udp = (struct rte_udp_hdr *)(ip + 1);

            // 处理 UDP 负载
            process_udp_payload(m, udp);
        }
    }
```

### 1.1 常见协议类型

| Ether Type | 协议   | 说明                            |
| ---------- | ---- | ----------------------------- |
| 0x0800     | IPv4 | Internet Protocol v4          |
| 0x0806     | ARP  | Address Resolution Protocol   |
| 0x86DD     | IPv6 | Internet Protocol v6          |
| 0x8100     | VLAN | 802.1Q VLAN Tag               |
| 0x8847     | MPLS | Multiprotocol Label Switching |

---

## 2. Ethernet 头部处理

### 2.1 以太网头部结构

```c
// lib/net/rte_ether.h

struct rte_ether_hdr {
    struct rte_ether_addr dst_addr; // 目标 MAC 地址 (6 bytes)
    struct rte_ether_addr src_addr; // 源 MAC 地址   (6 bytes)
    rte_be16_t ether_type;          // EtherType/Length
} __rte_packed;

// EtherType 定义
#define RTE_ETHER_TYPE_IPV4   0x0800
#define RTE_ETHER_TYPE_IPV6   0x86DD
#define RTE_ETHER_TYPE_ARP    0x0806
#define RTE_ETHER_TYPE_VLAN   0x8100
#define RTE_ETHER_TYPE_QINQ   0x9100
#define RTE_ETHER_TYPE_PPPOE  0x8864

// VLAN 头部
struct rte_vlan_hdr {
    rte_be16_t vlan_tci;      // VLAN ID + PCP + CFI
    rte_be16_t eth_proto;     // 内部 EtherType
} __rte_packed;
```

### 2.2 解析以太网头部

```c
// 基本解析
static void
parse_ethernet(struct rte_mbuf *m)
{
    struct rte_ether_hdr *eth = rte_pktmbuf_mtod(m, struct rte_ether_hdr *);
    struct rte_ether_addr *src = &eth->src_addr;
    struct rte_ether_addr *dst = &eth->dst_addr;

    printf("SRC: %02X:%02X:%02X:%02X:%02X:%02X\n",
           src->addr_bytes[0], src->addr_bytes[1],
           src->addr_bytes[2], src->addr_bytes[3],
           src->addr_bytes[4], src->addr_bytes[5]);

    printf("DST: %02X:%02X:%02X:%02X:%02X:%02X\n",
           dst->addr_bytes[0], dst->addr_bytes[1],
           dst->addr_bytes[2], dst->addr_bytes[3],
           dst->addr_bytes[4], dst->addr_bytes[5]);

    // 解析 EtherType
    uint16_t ether_type = rte_be_to_cpu_16(eth->ether_type);

    switch (ether_type) {
    case RTE_ETHER_TYPE_IPV4:
        parse_ipv4(m, eth);
        break;
    case RTE_ETHER_TYPE_IPV6:
        parse_ipv6(m, eth);
        break;
    case RTE_ETHER_TYPE_VLAN:
        parse_vlan(m, eth);
        break;
    default:
        printf("Unknown EtherType: 0x%04x\n", ether_type);
    }
}
```

### 2.3 VLAN 解析

```c
// VLAN 头部解析
static void
parse_vlan(struct rte_mbuf *m, struct rte_ether_hdr *eth)
{
    struct rte_vlan_hdr *vlan = (struct rte_vlan_hdr *)(eth + 1);

    uint16_t vlan_tci = rte_be_to_cpu_16(vlan->vlan_tci);
    uint16_t vlan_id = vlan_tci & 0x0FFF;
    uint16_t vlan_pcp = (vlan_tci >> 13) & 0x07;

    printf("VLAN: id=%d, pcp=%d\n", vlan_id, vlan_pcp);

    // 解析内部 EtherType
    uint16_t inner_type = rte_be_to_cpu_16(vlan->eth_proto);

    if (inner_type == RTE_ETHER_TYPE_IPV4) {
        struct rte_ipv4_hdr *ip = (struct rte_ipv4_hdr *)(vlan + 1);
        parse_ipv4_header(ip);
    }
}
```

---

## 3. IPv4 头部处理

### 3.1 IPv4 头部结构

```c
// lib/net/rte_ip.h

struct rte_ipv4_hdr {
    uint8_t version_ihl;      // 版本 (4) + 首部长度 (5)
    uint8_t type_of_service; // TOS / DSCP
    rte_be16_t total_length; // 总长度
    rte_be16_t packet_id;    // 标识
    rte_be16_t fragment_offset; // 片偏移
    uint8_t time_to_live;    // TTL
    uint8_t next_proto_id;   // 协议号 (TCP=6, UDP=17)
    rte_be16_t hdr_checksum; // 首部校验和
    rte_be32_t src_addr;     // 源 IP
    rte_be32_t dst_addr;     // 目标 IP
} __rte_packed;

// 首部长度计算
// ihl = version_ihl & 0x0F
// header_len = ihl * 4 (字节)

// 协议号定义
#define IPPROTO_ICMP   1
#define IPPROTO_TCP    6
#define IPPROTO_UDP    17
#define IPPROTO_SCTP   132
```

### 3.2 解析 IPv4 头部

```c
// IPv4 解析
static void
parse_ipv4(struct rte_mbuf *m, struct rte_ether_hdr *eth)
{
    struct rte_ipv4_hdr *ip = (struct rte_ipv4_hdr *)(eth + 1);

    // 提取字段
    uint8_t version = (ip->version_ihl >> 4) & 0x0F;
    uint8_t ihl = ip->version_ihl & 0x0F;
    uint16_t total_length = rte_be_to_cpu_16(ip->total_length);
    uint8_t ttl = ip->time_to_live;
    uint8_t proto = ip->next_proto_id;

    // IP 地址转换
    uint8_t src_ip[4], dst_ip[4];
    rte_memcpy(src_ip, &ip->src_addr, 4);
    rte_memcpy(dst_ip, &ip->dst_addr, 4);

    printf("IPv%d: %d.%d.%d.%d -> %d.%d.%d.%d, proto=%d, ttl=%d\n",
           version,
           src_ip[0], src_ip[1], src_ip[2], src_ip[3],
           dst_ip[0], dst_ip[1], dst_ip[2], dst_ip[3],
           proto, ttl);

    // 根据协议继续解析
    if (proto == IPPROTO_UDP) {
        struct rte_udp_hdr *udp = (struct rte_udp_hdr *)((char *)ip + ihl * 4);
        parse_udp(m, udp);
    } else if (proto == IPPROTO_TCP) {
        struct rte_tcp_hdr *tcp = (struct rte_tcp_hdr *)((char *)ip + ihl * 4);
        parse_tcp(m, tcp);
    }
}

// IP 地址转字符串
static inline void
ipv4_addr_to_str(uint32_t ip, char *str, size_t len)
{
    snprintf(str, len, "%d.%d.%d.%d",
             (ip >> 0) & 0xFF,
             (ip >> 8) & 0xFF,
             (ip >> 16) & 0xFF,
             (ip >> 24) & 0xFF);
}
```

### 3.3 IPv4 校验和计算

```c
// RFC 791 IPv4 首部校验和算法
static uint16_t
ipv4_checksum(struct rte_ipv4_hdr *ip)
{
    uint32_t sum = 0;
    uint16_t *ptr = (uint16_t *)ip;
    uint8_t header_len = (ip->version_ihl & 0x0F) * 4;

    // 先将校验和字段置零
    ip->hdr_checksum = 0;

    // 按 16 位累加
    for (int i = 0; i < header_len / 2; i++) {
        sum += rte_be_to_cpu_16(ptr[i]);
    }

    // 回卷进位
    while (sum >> 16) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }

    return rte_cpu_to_be_16(~sum);
}

// 验证校验和
static int
verify_ipv4_checksum(struct rte_ipv4_hdr *ip)
{
    uint32_t sum = 0;
    uint16_t *ptr = (uint16_t *)ip;
    uint8_t header_len = (ip->version_ihl & 0x0F) * 4;

    for (int i = 0; i < header_len / 2; i++) {
        sum += rte_be_to_cpu_16(ptr[i]);
    }

    while (sum >> 16) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }

    return (sum == 0xFFFF) ? 0 : -1;  // 0 = 校验和正确
}
```

---

## 4. IPv6 头部处理

### 4.1 IPv6 头部结构

```c
// lib/net/rte_ip.h

struct rte_ipv6_hdr {
    uint32_t vtc_flow;        // 版本(4) + 流量类别(8) + 流标签(20)
    uint16_t payload_len;     // 负载长度
    uint8_t  proto;           // 下一个头部 (next proto)
    uint8_t  hop_limit;       // 跳限 (类似 TTL)
    uint8_t  src_addr[16];    // 源地址 (128-bit)
    uint8_t  dst_addr[16];   // 目标地址 (128-bit)
} __rte_packed;

// 版本 (4 bits) = 6
#define RTE_IPV6_HDR_FL_MASK       0x000FFFFF

// 流量类别 / DSCP (TC 位于 bit 27-20)
#define RTE_IPV6_HDR_DSCP_MASK     0x0FC00000
#define RTE_IPV6_HDR_ECN_MASK      0x00300000   // bit 21-20
#define RTE_IPV6_HDR_ECN_CE        0x00300000   // ECN CE = 11

// 扩展头部类型
#define IPPROTO_HOPOPTS   0    // 逐跳选项
#define IPPROTO_ROUTING   43   // 路由头
#define IPPROTO_FRAGMENT  44   // 分片头
#define IPPROTO_AH        51   // 认证头 (IPsec)
#define IPPROTO_ESP       52   // 加密载荷 (IPsec)
#define IPPROTO_NONE      59   // 无下一个头部
#define IPPROTO_DESTOPTS  60   // 目的选项
```

### 4.2 解析 IPv6 头部

```c
// IPv6 解析（需要处理扩展头）
static void
parse_ipv6(struct rte_mbuf *m, struct rte_ether_hdr *eth)
{
    struct rte_ipv6_hdr *ip6 = (struct rte_ipv6_hdr *)(eth + 1);

    // 提取版本
    uint8_t version = (rte_be_to_cpu_32(ip6->vtc_flow) >> 28) & 0x0F;

    // 提取流量类别
    uint8_t dscp = (rte_be_to_cpu_32(ip6->vtc_flow) >> 20) & 0x3F;

    // 提取流标签
    uint32_t flow_label = rte_be_to_cpu_32(ip6->vtc_flow) & RTE_IPV6_HDR_FL_MASK;

    // 负载长度
    uint16_t payload_len = rte_be_to_cpu_16(ip6->payload_len);

    // 跳限
    uint8_t hop_limit = ip6->hop_limit;

    // 下一个头部（协议）
    uint8_t next_proto = ip6->proto;

    printf("IPv6: version=%d, dscp=%d, flow_label=%u\n", version, dscp, flow_label);
    printf("      payload_len=%d, hop_limit=%d, next_proto=%d\n", payload_len, hop_limit, next_proto);

    // IP 地址转换
    char src_str[64], dst_str[64];
    ipv6_addr_to_str(ip6->src_addr, src_str, sizeof(src_str));
    ipv6_addr_to_str(ip6->dst_addr, dst_str, sizeof(dst_str));
    printf("      %s -> %s\n", src_str, dst_str);

    // 解析扩展头部
    parse_ipv6_extensions(m, ip6, next_proto);
}

// IPv6 扩展头部解析
static void
parse_ipv6_extensions(struct rte_mbuf *m,
                       struct rte_ipv6_hdr *ip6,
                       uint8_t next_proto)
{
    uint8_t *ptr = (uint8_t *)(ip6 + 1);
    size_t remaining = rte_be_to_cpu_16(ip6->payload_len);

    while (1) {
        switch (next_proto) {
        case IPPROTO_UDP:
            parse_udp(m, (struct rte_udp_hdr *)ptr);
            return;

        case IPPROTO_TCP:
            parse_tcp(m, (struct rte_tcp_hdr *)ptr);
            return;

        case IPPROTO_HOPOPTS:
        case IPPROTO_DESTOPTS:
        case IPPROTO_ROUTING: {
            struct rte_ipv6_opt_hdr *opt = (struct rte_ipv6_opt_hdr *)ptr;
            next_proto = opt->next_hdr;
            ptr += (opt->hdr_len + 1) * 8;
            remaining -= (opt->hdr_len + 1) * 8;
            break;
        }

        case IPPROTO_FRAGMENT: {
            printf("IPv6 fragment detected\n");
            return;
        }

        default:
            printf("Unknown IPv6 next header: %d\n", next_proto);
            return;
        }
    }
}

// IPv6 地址转字符串
static inline void
ipv6_addr_to_str(const uint8_t *addr, char *str, size_t len)
{
    snprintf(str, len,
             "%02x%02x:%02x%02x:%02x%02x:%02x%02x:%02x%02x:%02x%02x:%02x%02x:%02x%02x",
             addr[0], addr[1], addr[2], addr[3],
             addr[4], addr[5], addr[6], addr[7],
             addr[8], addr[9], addr[10], addr[11],
             addr[12], addr[13], addr[14], addr[15]);
}
```

---

## 5. UDP 头部处理

### 5.1 UDP 头部结构

```c
// lib/net/rte_udp.h

struct rte_udp_hdr {
    rte_be16_t src_port;     // 源端口
    rte_be16_t dst_port;     // 目标端口
    rte_be16_t dgram_len;    // UDP 长度 (头部 + 数据)
    rte_be16_t dgram_cksum;  // UDP 校验和 (0 = 未使用)
} __rte_packed;

// 常见 UDP 端口
#define RTE_UDP_PORT_DNS         53
#define RTE_UDP_PORT_DHCP_CLIENT 68
#define RTE_UDP_PORT_DHCP_SERVER 67
#define RTE_UDP_PORT_VXLAN       4789
#define RTE_UDP_PORT_GENEVE      6081
#define RTE_UDP_PORT_GTP_U       2152   // GTP-U tunnel
```

### 5.2 解析 UDP 头部

```c
// UDP 解析
static void
parse_udp(struct rte_mbuf *m, struct rte_udp_hdr *udp)
{
    uint16_t src_port = rte_be_to_cpu_16(udp->src_port);
    uint16_t dst_port = rte_be_to_cpu_16(udp->dst_port);
    uint16_t len = rte_be_to_cpu_16(udp->dgram_len);
    uint16_t cksum = rte_be_to_cpu_16(udp->dgram_cksum);

    printf("UDP: %d -> %d, len=%d, cksum=%s\n",
           src_port, dst_port, len,
           cksum == 0 ? "none" : "present");

    // 检查校验和
    if (cksum != 0 && verify_udp_checksum(m, udp) != 0) {
        printf("UDP checksum error!\n");
        rte_pktmbuf_free(m);
        return;
    }

    // 解析负载
    uint8_t *payload = (uint8_t *)(udp + 1);
    size_t payload_len = len - sizeof(struct rte_udp_hdr);

    // 根据端口处理
    switch (dst_port) {
    case RTE_UDP_PORT_DNS:
        parse_dns(payload, payload_len);
        break;
    case RTE_UDP_PORT_VXLAN:
        parse_vxlan(payload, payload_len);
        break;
    default:
        printf("UDP payload type: %d\n", dst_port);
    }
}
```

### 5.3 UDP 校验和计算

```c
// UDP 伪头部（用于校验和计算，IPv4 版本）
struct udp_pseudo_header {
    uint32_t src_addr;     // 源 IP 地址 (4 bytes)
    uint32_t dst_addr;     // 目标 IP 地址 (4 bytes)
    uint8_t  zero;         // 置零
    uint8_t  proto;        // 协议号 (IPPROTO_UDP = 17)
    uint16_t udp_len;      // UDP 长度
} __rte_packed;

// UDP 校验和计算
static uint16_t
udp_checksum(struct rte_ipv4_hdr *ip, struct rte_udp_hdr *udp)
{
    uint32_t sum = 0;
    uint16_t *ptr;

    // 伪头部
    sum += (ip->src_addr >> 16) & 0xFFFF;
    sum += ip->src_addr & 0xFFFF;
    sum += (ip->dst_addr >> 16) & 0xFFFF;
    sum += ip->dst_addr & 0xFFFF;
    sum += IPPROTO_UDP;
    sum += udp->dgram_len;

    // UDP 头部和数据
    ptr = (uint16_t *)udp;
    uint16_t udp_len = rte_be_to_cpu_16(udp->dgram_len);
    for (int i = 0; i < udp_len / 2; i++) {
        sum += rte_be_to_cpu_16(ptr[i]);
    }
    if (udp_len & 1) {
        sum += ((uint8_t *)udp)[udp_len - 1] << 8;
    }

    // 回卷
    while (sum >> 16) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }

    return ~sum & 0xFFFF;
}
```

---

## 6. Checksum Offload 机制

### 6.1 什么是 Checksum Offload？

Checksum Offload 是 NIC 硬件帮忙计算校验和，避免 CPU 介入：

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        Checksum Offload 示意                                │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  未使用 Offload（软件计算）：                                               │
│  ──────────────────────────                                                 │
│                                                                             │
│  App ──────► 计算 checksum ──────► 发送                                    │
│             (CPU 介入，消耗 cycles)                                         │
│                                                                             │
│  使用 Offload（硬件计算）：                                                 │
│  ────────────────────────                                                   │
│                                                                             │
│  App ──────► 设置 ol_flags ──────► NIC 计算 ──────► 发送                   │
│             (标记让 NIC 计算)          (DMA 时自动计算)                     │
│                                                                             │
│  接收时：                                                                   │
│  ────────                                                                   │
│                                                                             │
│  NIC ──────► 计算 checksum ──────► 设置 ol_flags ──────► App               │
│  (DMA 时计算)       (标记 checksum 结果)                                    │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 6.2 发送端 Offload 配置

```c
// 配置发送 offload
struct rte_eth_conf conf = {
    .txmode = {
        .mq_mode = RTE_ETH_MQ_TX_NONE,
        .offloads = DEV_TX_OFFLOAD_IPV4_CKSUM |  // IPv4 checksum
                    DEV_TX_OFFLOAD_UDP_CKSUM  |  // UDP checksum
                    DEV_TX_OFFLOAD_TCP_CKSUM  |  // TCP checksum
                    DEV_TX_OFFLOAD_SCTP_CKSUM,   // SCTP checksum
    },
};

// 填充数据包时设置 ol_flags
struct rte_mbuf *m = rte_pktmbuf_alloc(mbuf_pool);

// 设置 IPv4 checksum offload
m->ol_flags |= RTE_MBUF_F_TX_IPV4;       // IPv4 头
m->ol_flags |= RTE_MBUF_F_TX_IP_CKSUM;   // 请求 IPv4 header checksum

// 或设置 UDP/TCP offload（互斥，不可同时设置）
m->ol_flags |= RTE_MBUF_F_TX_UDP_CKSUM;  // 请求 UDP checksum
// m->ol_flags |= RTE_MBUF_F_TX_TCP_CKSUM; // 请求 TCP checksum

// 设置隧道相关
m->ol_flags |= RTE_MBUF_F_TX_TUNNEL_VXLAN; // VXLAN 隧道

// 设置外层 IPv4 checksum
m->ol_flags |= RTE_MBUF_F_TX_OUTER_IPV4;     // 外层 IPv4
m->ol_flags |= RTE_MBUF_F_TX_OUTER_IP_CKSUM;
```

### 6.3 接收端 Offload 配置

```c
// 配置接收 offload
struct rte_eth_conf conf = {
    .rxmode = {
        .mq_mode = RTE_ETH_MQ_RX_NONE,
        .offloads = DEV_RX_OFFLOAD_IPV4_CKSUM |  // IPv4 checksum
                    DEV_RX_OFFLOAD_UDP_CKSUM  |  // UDP checksum
                    DEV_RX_OFFLOAD_TCP_CKSUM  |  // TCP checksum
                    DEV_RX_OFFLOAD_SCTP_CKSUM |
                    DEV_RX_OFFLOAD_OUTER_IPV4_CKSUM,
    },
};

// 接收后检查 ol_flags
struct rte_mbuf *m = rte_eth_rx_burst(port_id, queue_id, &m, 1);

if (m->ol_flags & RTE_MBUF_F_RX_IP_CKSUM_GOOD) {
    printf("IPv4 checksum: GOOD\n");
} else if (m->ol_flags & RTE_MBUF_F_RX_IP_CKSUM_BAD) {
    printf("IPv4 checksum: BAD\n");
}

if (m->ol_flags & RTE_MBUF_F_RX_L4_CKSUM_GOOD) {
    printf("L4 checksum: GOOD\n");
} else if (m->ol_flags & RTE_MBUF_F_RX_L4_CKSUM_BAD) {
    printf("L4 checksum: BAD\n");
}

// RSS hash
if (m->ol_flags & RTE_MBUF_F_RX_RSS_HASH) {
    printf("RSS hash: 0x%x\n", m->hash.rss);
}
```

### 6.4 实战：Offload 下发后代码怎么变？

启用 Offload 后，应用代码的变化核心就两点：**TX 不再手动算 checksum，改设 ol_flags**；**RX 不再逐包验证，改查 ol_flags 直接丢弃**。下面用转发场景做完整对比。

#### 6.4.1 发送端：构建并转发一个 IPv4/UDP 包

**关闭 Offload 时（纯软件）**，发送前必须手动计算两层 checksum：

```c
// ---- 软件模式：TX 发送一个 IPv4/UDP 包 ----
static int
tx_send_software(struct rte_mempool *mpool, uint16_t port, uint16_t queue,
                 uint32_t src_ip, uint32_t dst_ip,
                 uint16_t src_port, uint16_t dst_port,
                 const void *data, uint16_t data_len)
{
    struct rte_mbuf *m = rte_pktmbuf_alloc(mpool);
    if (!m) return -ENOMEM;

    uint16_t pkt_len = sizeof(struct rte_ether_hdr)
                     + sizeof(struct rte_ipv4_hdr)
                     + sizeof(struct rte_udp_hdr)
                     + data_len;

    char *pkt = rte_pktmbuf_append(m, pkt_len);

    // 1. 填充 Ethernet 头
    struct rte_ether_hdr *eth = (struct rte_ether_hdr *)pkt;
    rte_ether_addr_copy(&local_mac, &eth->src_addr);
    rte_ether_addr_copy(&dst_mac, &eth->dst_addr);
    eth->ether_type = rte_cpu_to_be_16(RTE_ETHER_TYPE_IPV4);

    // 2. 填充 IPv4 头
    struct rte_ipv4_hdr *ip = (struct rte_ipv4_hdr *)(eth + 1);
    ip->version_ihl = 0x45;
    ip->type_of_service = 0;
    ip->total_length = rte_cpu_to_be_16(pkt_len - sizeof(struct rte_ether_hdr));
    ip->packet_id = 0;
    ip->fragment_offset = 0;
    ip->time_to_live = 64;
    ip->next_proto_id = IPPROTO_UDP;
    ip->src_addr = src_ip;
    ip->dst_addr = dst_ip;
    ip->hdr_checksum = 0;
    ip->hdr_checksum = ipv4_checksum(ip);  // <-- CPU 手动计算

    // 3. 填充 UDP 头
    struct rte_udp_hdr *udp = (struct rte_udp_hdr *)(ip + 1);
    udp->src_port = rte_cpu_to_be_16(src_port);
    udp->dst_port = rte_cpu_to_be_16(dst_port);
    uint16_t udp_len = sizeof(struct rte_udp_hdr) + data_len;
    udp->dgram_len = rte_cpu_to_be_16(udp_len);
    udp->dgram_cksum = udp_checksum(ip, udp);  // <-- CPU 手动计算

    // 4. 拷贝负载
    rte_memcpy((char *)(udp + 1), data, data_len);

    // 5. 发送（ol_flags 全部为 0，NIC 不做任何 checksum）
    rte_eth_tx_burst(port, queue, &m, 1);
    return 0;
}
```

**开启 Offload 后**，checksum 计算全部交给 NIC，代码简洁很多：

```c
// ---- 硬件 Offload 模式：TX 发送同样一个 IPv4/UDP 包 ----
static int
tx_send_offload(struct rte_mempool *mpool, uint16_t port, uint16_t queue,
                uint32_t src_ip, uint32_t dst_ip,
                uint16_t src_port, uint16_t dst_port,
                const void *data, uint16_t data_len)
{
    struct rte_mbuf *m = rte_pktmbuf_alloc(mpool);
    if (!m) return -ENOMEM;

    uint16_t pkt_len = sizeof(struct rte_ether_hdr)
                     + sizeof(struct rte_ipv4_hdr)
                     + sizeof(struct rte_udp_hdr)
                     + data_len;

    char *pkt = rte_pktmbuf_append(m, pkt_len);

    // 1. 填充 Ethernet 头（不变）
    struct rte_ether_hdr *eth = (struct rte_ether_hdr *)pkt;
    rte_ether_addr_copy(&local_mac, &eth->src_addr);
    rte_ether_addr_copy(&dst_mac, &eth->dst_addr);
    eth->ether_type = rte_cpu_to_be_16(RTE_ETHER_TYPE_IPV4);

    // 2. 填充 IPv4 头
    struct rte_ipv4_hdr *ip = (struct rte_ipv4_hdr *)(eth + 1);
    ip->version_ihl = 0x45;
    ip->type_of_service = 0;
    ip->total_length = rte_cpu_to_be_16(pkt_len - sizeof(struct rte_ether_hdr));
    ip->packet_id = 0;
    ip->fragment_offset = 0;
    ip->time_to_live = 64;
    ip->next_proto_id = IPPROTO_UDP;
    ip->src_addr = src_ip;
    ip->dst_addr = dst_ip;
    ip->hdr_checksum = 0;              // <-- 留零即可，NIC 会填

    // 3. 填充 UDP 头
    struct rte_udp_hdr *udp = (struct rte_udp_hdr *)(ip + 1);
    udp->src_port = rte_cpu_to_be_16(src_port);
    udp->dst_port = rte_cpu_to_be_16(dst_port);
    uint16_t udp_len = sizeof(struct rte_udp_hdr) + data_len;
    udp->dgram_len = rte_cpu_to_be_16(udp_len);
    udp->dgram_cksum = 0;              // <-- 留零即可，NIC 会填

    // 4. 拷贝负载（不变）
    rte_memcpy((char *)(udp + 1), data, data_len);

    // 5. 设置 ol_flags —— 这是唯一的变化
    m->ol_flags |= RTE_MBUF_F_TX_IPV4 | RTE_MBUF_F_TX_IP_CKSUM;
    m->ol_flags |= RTE_MBUF_F_TX_UDP_CKSUM;

    // 设置 L2/L3/L4 头部长度，NIC 需要这些信息定位各层
    m->l2_len = sizeof(struct rte_ether_hdr);
    m->l3_len = sizeof(struct rte_ipv4_hdr);
    m->l4_len = sizeof(struct rte_udp_hdr);

    rte_eth_tx_burst(port, queue, &m, 1);
    return 0;
}
```

**差异一目了然**：

```
┌────────────────────────────┬──────────────────────┬──────────────────────┐
│            对比项           │    软件计算           │    硬件 Offload       │
├────────────────────────────┼──────────────────────┼──────────────────────┤
│ IPv4 hdr_checksum 填写     │ ipv4_checksum(ip)    │ 0（留零）             │
│ UDP dgram_cksum 填写       │ udp_checksum(ip,udp) │ 0（留零）             │
│ ol_flags 设置              │ 无需设置              │ IPV4+IP_CKSUM+UDP_CKSUM │
│ l2/l3/l4_len 设置          │ 无需设置              │ 必须设置              │
│ CPU 开销                   │ 每包 ~50-100 cycles  │ 几乎为零              │
│ 吞吐量影响 (10Mpps)        │ 浪费 ~0.5-1 GHz      │ 无影响                │
└────────────────────────────┴──────────────────────┴──────────────────────┘
```

> **关键点**：开启 Offload 后必须设置 `m->l2_len`、`m->l3_len`、`m->l4_len`。NIC 根据这些偏移量定位各层头部来计算 checksum。漏设任一项会导致 NIC 计算出错误的 checksum。

#### 6.4.2 接收端：转发时直接利用 RX Offload 结果

RX Offload 的价值在于：**网卡已经帮你验过了，应用只需要看 flag 决定丢弃还是转发**。

```c
// ---- RX 接收 + 转发：利用硬件 checksum 校验结果 ----
static uint16_t
rx_forward(struct rte_mbuf **pkts, uint16_t nb_pkts,
           uint16_t src_port, uint16_t src_queue,
           uint16_t dst_port, uint16_t dst_queue)
{
    struct rte_mbuf *tx_pkts[nb_pkts];
    uint16_t tx_count = 0;

    for (uint16_t i = 0; i < nb_pkts; i++) {
        struct rte_mbuf *m = pkts[i];

        // 硬件已经校验过 checksum，直接检查 flag
        if (m->ol_flags & RTE_MBUF_F_RX_IP_CKSUM_BAD) {
            printf("Drop: bad IP checksum\n");
            rte_pktmbuf_free(m);
            continue;
        }
        if (m->ol_flags & RTE_MBUF_F_RX_L4_CKSUM_BAD) {
            printf("Drop: bad L4 checksum\n");
            rte_pktmbuf_free(m);
            continue;
        }

        // checksum 全部正确，直接转发（无需重新校验）
        // 如果要修改包内容（如 NAT），需要重新请求 TX offload
        tx_pkts[tx_count++] = m;
    }

    if (tx_count > 0)
        rte_eth_tx_burst(dst_port, dst_queue, tx_pkts, tx_count);

    return tx_count;
}
```

**对比没有 RX Offload 的情况**：

```c
// ---- 没有 RX Offload：必须逐包软件校验 ----
static uint16_t
rx_forward_no_offload(struct rte_mbuf **pkts, uint16_t nb_pkts,
                      uint16_t dst_port, uint16_t dst_queue)
{
    struct rte_mbuf *tx_pkts[nb_pkts];
    uint16_t tx_count = 0;

    for (uint16_t i = 0; i < nb_pkts; i++) {
        struct rte_mbuf *m = pkts[i];
        struct rte_ether_hdr *eth = rte_pktmbuf_mtod(m, struct rte_ether_hdr *);

        if (eth->ether_type != rte_cpu_to_be_16(RTE_ETHER_TYPE_IPV4)) {
            tx_pkts[tx_count++] = m;  // 非 IPv4 直接转发
            continue;
        }

        struct rte_ipv4_hdr *ip = (struct rte_ipv4_hdr *)(eth + 1);

        // 每个包都要 CPU 校验 IP checksum
        if (verify_ipv4_checksum(ip) != 0) {
            printf("Drop: bad IP checksum\n");
            rte_pktmbuf_free(m);
            continue;
        }

        // 每个包都要 CPU 校验 UDP/TCP checksum
        if (ip->next_proto_id == IPPROTO_UDP) {
            struct rte_udp_hdr *udp = (struct rte_udp_hdr *)
                ((char *)ip + (ip->version_ihl & 0x0F) * 4);
            if (udp->dgram_cksum != 0 &&
                verify_udp_checksum(m, udp) != 0) {
                printf("Drop: bad UDP checksum\n");
                rte_pktmbuf_free(m);
                continue;
            }
        }

        tx_pkts[tx_count++] = m;
    }

    if (tx_count > 0)
        rte_eth_tx_burst(dst_port, dst_queue, tx_pkts, tx_count);

    return tx_count;
}
```

**RX Offload 的核心差异**：省掉了 `verify_ipv4_checksum()` 和 `verify_udp_checksum()` 两次 CPU 遍历。在 10Mpps 场景下，这相当于节省了大约 1-2 GHz 的 CPU 时间。

#### 6.4.3 转发中修改包内容：RX→TX Offload 衔接

转发场景中最常见的坑：**收到包后修改了头部（NAT、修改 TTL 等），必须重新请求 TX Offload**，不能"白嫖"RX 的校验结果。

```c
// ---- NAT 场景：修改 dst IP 后重新请求 TX checksum ----
static int
nat_and_forward(struct rte_mbuf *m, uint32_t new_dst_ip,
                uint16_t dst_port, uint16_t dst_queue)
{
    struct rte_ether_hdr *eth = rte_pktmbuf_mtod(m, struct rte_ether_hdr *);
    struct rte_ipv4_hdr *ip = (struct rte_ipv4_hdr *)(eth + 1);
    struct rte_udp_hdr *udp = (struct rte_udp_hdr *)
        ((char *)ip + (ip->version_ihl & 0x0F) * 4);

    // 1. RX 校验结果已经由硬件标记，可以直接检查
    if (m->ol_flags & (RTE_MBUF_F_RX_IP_CKSUM_BAD |
                       RTE_MBUF_F_RX_L4_CKSUM_BAD))
        return -EINVAL;  // 直接丢弃

    // 2. 修改目标 IP（NAT 转换）
    ip->dst_addr = new_dst_ip;

    // 3. 修改了 IP 头 → IPv4 checksum 必须重算
    ip->hdr_checksum = 0;  // 清零让 NIC 填

    // 4. 修改了 IP 地址 → UDP 伪头部变了 → L4 checksum 必须重算
    udp->dgram_cksum = 0;  // 清零让 NIC 填

    // 5. 设置 TX offload flags（关键！不能省）
    m->ol_flags &= ~RTE_MBUF_F_TX_L4_MASK;  // 清除旧的 L4 flag
    m->ol_flags |= RTE_MBUF_F_TX_IPV4
                 | RTE_MBUF_F_TX_IP_CKSUM
                 | RTE_MBUF_F_TX_UDP_CKSUM;

    // 6. 确保 l2/l3/l4_len 正确
    m->l2_len = sizeof(struct rte_ether_hdr);
    m->l3_len = sizeof(struct rte_ipv4_hdr);
    m->l4_len = sizeof(struct rte_udp_hdr);

    rte_eth_tx_burst(dst_port, dst_queue, &m, 1);
    return 0;
}
```

> **踩坑提醒**：
> - 从 RX 收到的 mbuf 上可能残留 `RTE_MBUF_F_RX_*` 标志，这些是**只读**的，不影响 TX。但旧的 TX L4 flag（如果 mbuf 被复用）必须清除，否则 NIC 可能用错误的编码。
> - `RTE_MBUF_F_TX_L4_MASK` 用于清除 bit 52-53 上的旧 L4 checksum 编码。
> - 如果只改了 IP 头（如 TTL 递减）但没改 IP 地址，UDP checksum 不受影响，可以不重算 L4。

### 6.5 Offload ol_flags 详解

```c
// lib/mbuf/rte_mbuf_core.h

// ============ 接收端 ol_flags ============

// VLAN / RSS
#define RTE_MBUF_F_RX_VLAN          (1ULL << 0)   // VLAN tag 存在
#define RTE_MBUF_F_RX_RSS_HASH      (1ULL << 1)   // RSS hash 有效

// IP checksum 状态（使用 bit 4 和 bit 7 组合编码）
#define RTE_MBUF_F_RX_IP_CKSUM_UNKNOWN  0          // 未知
#define RTE_MBUF_F_RX_IP_CKSUM_BAD     (1ULL << 4) // IP checksum 错误
#define RTE_MBUF_F_RX_IP_CKSUM_GOOD    (1ULL << 7) // IP checksum 正确
#define RTE_MBUF_F_RX_IP_CKSUM_NONE    ((1ULL << 4) | (1ULL << 7))

// L4 checksum 状态（使用 bit 3 和 bit 8 组合编码）
#define RTE_MBUF_F_RX_L4_CKSUM_UNKNOWN  0          // 未知
#define RTE_MBUF_F_RX_L4_CKSUM_BAD     (1ULL << 3) // L4 checksum 错误
#define RTE_MBUF_F_RX_L4_CKSUM_GOOD    (1ULL << 8) // L4 checksum 正确
#define RTE_MBUF_F_RX_L4_CKSUM_NONE    ((1ULL << 3) | (1ULL << 8))

// 外部 IP header checksum
#define RTE_MBUF_F_RX_OUTER_IP_CKSUM_BAD (1ULL << 5)

// ============ 发送端 ol_flags ============

// L4 checksum（互斥，共用 bit 52-53，编码为 0/1/2/3）
#define RTE_MBUF_F_TX_L4_NO_CKSUM   (0ULL << 52)  // 不计算 L4
#define RTE_MBUF_F_TX_TCP_CKSUM     (1ULL << 52)  // 计算 TCP checksum
#define RTE_MBUF_F_TX_SCTP_CKSUM    (2ULL << 52)  // 计算 SCTP checksum
#define RTE_MBUF_F_TX_UDP_CKSUM     (3ULL << 52)  // 计算 UDP checksum

// IP checksum
#define RTE_MBUF_F_TX_IP_CKSUM      (1ULL << 54)  // 计算 IPv4 header checksum

// 网络层标识
#define RTE_MBUF_F_TX_IPV4          (1ULL << 55)  // 发送 IPv4
#define RTE_MBUF_F_TX_IPV6          (1ULL << 56)  // 发送 IPv6

// 隧道类型（共用 bit 45-48，编码为 0x0-0xF）
#define RTE_MBUF_F_TX_TUNNEL_VXLAN  (0x1ULL << 45)
#define RTE_MBUF_F_TX_TUNNEL_GRE    (0x2ULL << 45)
#define RTE_MBUF_F_TX_TUNNEL_IPIP   (0x3ULL << 45)
#define RTE_MBUF_F_TX_TUNNEL_GENEVE (0x4ULL << 45)

// 外层头部（隧道场景）
#define RTE_MBUF_F_TX_OUTER_IP_CKSUM (1ULL << 58) // 外层 IPv4 checksum
#define RTE_MBUF_F_TX_OUTER_IPV4     (1ULL << 59)  // 外层 IPv4
#define RTE_MBUF_F_TX_OUTER_IPV6     (1ULL << 60)  // 外层 IPv6
```

---

## 7. 协议解析辅助函数

### 7.1 DPDK 提供的解析库

```c
// librte_net 提供的高级解析函数

#include <rte_net.h>

// 解析整个数据包，获取协议信息
uint32_t
rte_net_get_ptype(const struct rte_mbuf *m,
                   struct rte_net_hdr_lens *hdr_lens,
                   uint32_t layers)
{
    // 返回数据包类型 (RTE_PTYPE_*)
    // 设置 hdr_lens 各个协议头的长度
    // layers: 指定需要解析的层级掩码
}

// 常用数据包类型
enum {
    RTE_PTYPE_L2_ETHER,
    RTE_PTYPE_L2_ETHER_VLAN,
    RTE_PTYPE_L3_IPV4,
    RTE_PTYPE_L3_IPV6,
    RTE_PTYPE_L4_TCP,
    RTE_PTYPE_L4_UDP,
    RTE_PTYPE_L4_SCTP,
    RTE_PTYPE_TUNNEL_VXLAN,
    RTE_PTYPE_TUNNEL_GRE,
    // ...
};

// 示例
struct rte_net_hdr_lens hdr_lens = {0};
uint32_t ptype = rte_net_get_ptype(m, &hdr_lens, RTE_PTYPE_ALL_MASK);

printf("Packet type: 0x%x\n", ptype);
printf("  L2: %d bytes\n", hdr_lens.l2_len);
printf("  L3: %d bytes\n", hdr_lens.l3_len);
printf("  L4: %d bytes\n", hdr_lens.l4_len);
printf("  Tunnel: %d bytes\n", hdr_lens.tunnel_len);
```

### 7.2 快速检查协议类型

```c
// 快速判断 EtherType（不解析整个头）
static inline uint16_t
get_ether_type(struct rte_mbuf *m)
{
    struct rte_ether_hdr *eth = rte_pktmbuf_mtod(m, struct rte_ether_hdr *);
    return eth->ether_type;
}

// 检查是否是 VLAN 包
static inline int
is_vlan_packet(struct rte_mbuf *m)
{
    uint16_t ether_type = get_ether_type(m);
    return ether_type == rte_cpu_to_be_16(RTE_ETHER_TYPE_VLAN);
}

// 获取 L3 头部指针（跳过 VLAN）
static inline void *
get_l3_header(struct rte_mbuf *m)
{
    struct rte_ether_hdr *eth = rte_pktmbuf_mtod(m, struct rte_ether_hdr *);

    if (eth->ether_type == rte_cpu_to_be_16(RTE_ETHER_TYPE_VLAN)) {
        struct rte_vlan_hdr *vlan = (struct rte_vlan_hdr *)(eth + 1);
        return vlan + 1;
    }

    return eth + 1;
}

// 获取 L4 头部指针（给定 L3 头）
static inline void *
get_l4_header(void *l3_header, uint8_t proto)
{
    struct rte_ipv4_hdr *ip = l3_header;

    if ((ip->version_ihl >> 4) == 4) {
        uint8_t ihl = ip->version_ihl & 0x0F;
        return (uint8_t *)ip + ihl * 4;
    } else {
        // IPv6
        return parse_ipv6_next_header(ip);
    }
}
```

---

## 8. 实际应用示例

### 8.1 UDP 回显服务器

```c
// UDP 回显服务器
static void
udp_echo_server(struct rte_mbuf *m)
{
    struct rte_ether_hdr *eth = rte_pktmbuf_mtod(m, struct rte_ether_hdr *);
    struct rte_ipv4_hdr *ip = (struct rte_ipv4_hdr *)(eth + 1);
    struct rte_udp_hdr *udp = (struct rte_udp_hdr *)(ip + 1);

    uint16_t src_port = rte_be_to_cpu_16(udp->src_port);
    uint16_t dst_port = rte_be_to_cpu_16(udp->dst_port);

    // 交换源和目标 IP
    uint32_t src_ip = ip->src_addr;
    ip->src_addr = ip->dst_addr;
    ip->dst_addr = src_ip;

    // 递减 TTL（避免回显包无限路由）
    ip->time_to_live--;

    // 重新计算 IPv4 校验和
    ip->hdr_checksum = 0;
    ip->hdr_checksum = ipv4_checksum(ip);

    // 交换 UDP 端口
    udp->src_port = udp->dst_port;
    udp->dst_port = rte_cpu_to_be_16(src_port);

    // 交换 MAC 地址
    struct rte_ether_addr tmp_mac;
    rte_ether_addr_copy(&eth->src_addr, &tmp_mac);
    rte_ether_addr_copy(&eth->dst_addr, &eth->src_addr);
    rte_ether_addr_copy(&tmp_mac, &eth->dst_addr);

    // IP 和 UDP 长度不变（负载相同），发送
    rte_eth_tx_burst(port_id, queue_id, &m, 1);
}
```

### 8.2 IP 分片处理

```c
// 检查 IP 分片
static int
is_ip_fragment(struct rte_ipv4_hdr *ip)
{
    uint16_t frag_offset = rte_be_to_cpu_16(ip->fragment_offset);
    return frag_offset & (RTE_IPV4_HDR_MF_FLAG | RTE_IPV4_HDR_OFFSET_MASK);
}

// 获取 IP 分片偏移
static uint16_t
get_ip_fragment_offset(struct rte_ipv4_hdr *ip)
{
    uint16_t frag_offset = rte_be_to_cpu_16(ip->fragment_offset);
    return frag_offset & RTE_IPV4_HDR_OFFSET_MASK;
}

// 判断是否是最后一个分片
static int
is_last_fragment(struct rte_ipv4_hdr *ip)
{
    uint16_t frag_offset = rte_be_to_cpu_16(ip->fragment_offset);
    return !(frag_offset & RTE_IPV4_HDR_MF_FLAG);
}
```

### 8.3 性能优化：批量校验的向量化

#### 8.3.1 标量版本：慢在哪？

回顾 3.3 节的标量校验和验证，它的核心循环是这样的：

```c
// 标量版本：逐个 16-bit word 累加
static int verify_ipv4_checksum(struct rte_ipv4_hdr *ip)
{
    uint32_t sum = 0;
    uint16_t *ptr = (uint16_t *)ip;
    uint8_t header_len = (ip->version_ihl & 0x0F) * 4;

    for (int i = 0; i < header_len / 2; i++) {   // 循环 10 次（20 字节 header）
        sum += rte_be_to_cpu_16(ptr[i]);           // 每次只加 1 个 word
    }
    while (sum >> 16)                              // 回卷进位
        sum = (sum & 0xFFFF) + (sum >> 16);

    return (sum == 0xFFFF) ? 0 : -1;
}
```

**慢的原因**：IPv4 header 20 字节 = 10 个 16-bit word。每次循环 CPU 只加 1 个数，循环 10 次。加上每次循环还有 `rte_be_to_cpu_16()` 字节序转换，一共大约 **25-30 条指令**。

```
标量执行过程（一次加一个）：

  第 1 轮:  sum += word[0]       ─┐
  第 2 轮:  sum += word[1]        │ 串行，必须等上一轮结束
  第 3 轮:  sum += word[2]        │
  ...                            │
  第 10 轮: sum += word[9]       ─┘  → 回卷 → 比较 0xFFFF

  CPU 像一个人数硬币：一次拿一枚，数 10 枚需要 10 步。
```

#### 8.3.2 AVX2 版本：快在哪？

AVX2 是 Intel 的 SIMD 指令集。SIMD = Single Instruction Multiple Data，一条指令同时处理多个数据。

**核心思想**：普通 CPU 寄存器 64-bit，一次加 1 个 32-bit 数。AVX2 寄存器 256-bit，一次加 **8 个** 32-bit 数。

```
AVX2 执行过程（一次加八个）：

  第 1 轮:  sum += [word0 word1 word2 word3 word4 word5 word6 word7]  ← 一条指令！
  第 2 轮:  sum += word[8] + word[9]                                   ← 剩余 2 个
           → 水平折叠（把 8 个槽位的值合并成 1 个）
           → 回卷 → 比较 0xFFFF

  CPU 像 8 个人同时数硬币：一次拿 8 枚，1 步就数完了。
```

下面是完整的 AVX2 实现，逐行注释：

```c
#include <immintrin.h>

static inline int
verify_ipv4_cksum_avx2(const struct rte_ipv4_hdr *ip)
{
    const uint32_t *w = (const uint32_t *)ip;
    uint8_t ihl = ip->version_ihl & 0x0F;
    uint32_t nw32 = ihl * 2;  // 20 字节 header → 10 个 16-bit word → 5 个 32-bit word

    // ── 第 1 步：把 5 个 32-bit word 一次性加载到 256-bit 寄存器 ──
    //
    // __m256i 是 256-bit 寄存器，能装 8 个 uint32_t
    // _mm256_loadu_si256 从内存加载 32 字节到寄存器
    // IPv4 header 只有 20 字节，寄存器后半部分是"垃圾数据"，没关系，
    // 后面折叠时会正确处理
    __m256i data = _mm256_loadu_si256((const __m256i *)w);
    //
    // 寄存器状态：[w0 | w1 | w2 | w3 | w4 | 垃圾 | 垃圾 | 垃圾]

    // ── 第 2 步：把 8 个槽位累加成 1 个值（水平折叠） ──
    //
    // _mm256_extracti128_si256(v, 0/1) → 取寄存器的高/低 128-bit 半段
    // 相当于把 256-bit 切成两半
    __m128i lo = _mm256_extracti128_si256(data, 0);  // [w0 | w1 | w2 | w3]
    __m128i hi = _mm256_extracti128_si256(data, 1);  // [w4 | 垃圾 | 垃圾 | 垃圾]

    // _mm_add_epi32: 4 个 uint32_t 同时相加
    __m128i s = _mm_add_epi32(lo, hi);
    // 状态：[w0+w4 | w1+垃圾 | w2+垃圾 | w3+垃圾]

    // 问题：我们只要 w0+w4（第一个槽位），后面三个是垃圾+垃圾
    // 解决：用 _mm_srli_si128 把第一个槽位移到后面，加到第一个位置

    // _mm_srli_si128(s, 8): 整个 128-bit 右移 8 字节 = 2 个 uint32_t
    // 移动前: [A | B | C | D]  →  移动后: [0 | 0 | A | B]
    s = _mm_add_epi32(s, _mm_srli_si128(s, 8));
    // 状态：[A+C | B+D | C+0 | D+0]

    s = _mm_add_epi32(s, _mm_srli_si128(s, 4));
    // 状态：[A+C+E+G | ...]  → 第一个槽位就是我们要的总和

    // _mm_cvtsi128_si32: 取 128-bit 寄存器的最低 32-bit → 普通 uint32_t
    uint32_t sum = _mm_cvtsi128_si32(s);

    // ── 第 3 步：回卷进位（和标量版本一样） ──
    while (sum >> 16)
        sum = (sum & 0xFFFF) + (sum >> 16);

    return (sum == 0xFFFF) ? 0 : -1;
}
```

#### 8.3.3 指令数对比

```
┌─────────────────────────────┬──────────────────┬──────────────────┐
│           操作              │   标量版本        │   AVX2 版本       │
├─────────────────────────────┼──────────────────┼──────────────────┤
│ 字节序转换 rte_be_to_cpu_16  │ 10 次            │ 0 次（见下方说明） │
│ 加法指令                    │ 10 条 add        │ 4 条 add（SIMD）  │
│ 回卷进位                    │ 1-2 次           │ 1-2 次           │
│ 总指令数（大约）             │ ~25 条           │ ~8 条            │
├─────────────────────────────┼──────────────────┼──────────────────┤
│ 20 字节 header 单次校验      │ ~15 cycles       │ ~8 cycles        │
│ 吞吐提升                    │ 基准 1x          │ ~1.5-2x          │
└─────────────────────────────┴──────────────────┴──────────────────┘
```

> **为什么不需要 `rte_be_to_cpu_16()`？** 标量版本必须逐个转换字节序，因为要在 CPU 通用寄存器里运算。AVX2 版本直接把原始内存按 32-bit 加载，不做任何字节序转换——因为 Internet Checksum 算法有一个特性：**验证时字节序不影响结果**。无论你用 big-endian 还是 little-endian 去加，回卷后的值一样是 0xFFFF。这省掉了全部 10 次字节序转换。

#### 8.3.4 更大的收益在 UDP/TCP 校验和

IPv4 header 只有 20 字节，AVX2 的收益有限（寄存器 32 字节，一半空着）。**真正的收益在计算 UDP/TCP 校验和**，因为要覆盖整个 payload（可能几百到几千字节）：

```
校验和范围      标量循环次数    AVX2 循环次数    加速比
─────────────  ────────────  ─────────────  ──────
IPv4 header    10            1              ~1.5x
UDP + 64B 数据  42            3              ~3x
UDP + 1400B    702           44             ~5x
TCP + 1400B    702           44             ~5x
```

payload 越大，AVX2 的加速比越接近理论值 8x（256-bit / 32-bit = 8 路并行）。

#### 8.3.5 实战建议

> 在实际 DPDK 项目中，软件校验和只是 fallback。**优先使用硬件 Offload**（6.4 节），让 NIC 算 checksum，CPU 完全不参与。只有在以下场景才需要软件 AVX2 校验：
>
> - 虚拟机 / 容器中 NIC 不支持 checksum offload
> - 需要校验 tunnel 内层包（外层 offload 无法覆盖）
> - DPDK 转发设备自身需要验证入向包（而非信任网卡）
>
> 生产代码可以直接调用 DPDK 内置的 `rte_ipv4_cksum()` / `rte_ipv4_udptcp_cksum()`，这些函数内部已经做了 SIMD 优化。

---

## 9. 小结

本章核心要点：

1. **Ethernet 头部**：dst/src MAC + EtherType，EtherType 标识上层协议（IPv4/IPv6/VLAN）。

2. **IPv4 头部**：版本+IHL+TOS+长度+ID+偏移+TTL+协议+校验和+源/目 IP，首部长度以 4 字节为单位。

3. **IPv6 头部**：固定 40 字节，无校验和，支持扩展头（逐跳/路由/分片/认证/加密/目的选项）。

4. **UDP 头部**：源端口+目端口+长度+校验和，校验和计算包含伪头部。

5. **Checksum Offload**：发送端设置 ol_flags 让 NIC 硬件计算，接收端检查 ol_flags 判断校验和状态。

6. **ol_flags 详解**：RX 端使用 `RTE_MBUF_F_RX_IP/L4_CKSUM_GOOD/BAD`（组合编码），TX 端 L4 checksum 互斥（`RTE_MBUF_F_TX_TCP/UDP/SCTP_CKSUM` 共用 bit 52-53），隧道类型同样共用 bit 45-48 编码。

7. **DPDK 解析库**：rte_net_get_ptype() 可快速获取数据包类型和各层头部长度。

8. **性能优化**：批量处理 + AVX2 向量化校验和（256-bit 寄存器一次累加 8 x 32-bit word，水平折叠后回卷进位）。

**下一篇预告**：[[2026-04-09-dpdk-deep-dive-ch12-tcp-protocol-stack|第十二章]]将深入讲解 TCP 协议栈——SYN/ACK/FIN 三次握手、连接状态机、滑动窗口、拥塞控制、以及 DPDK 对 TCP 的处理。

---

> [!tip] 参考文献
> - Intel, "DPDK Packet Framework", https://doc.dpdk.org/guides/prog_guide/packet_framework.html
> - RFC 791, "Internet Protocol"
> - RFC 768, "User Datagram Protocol"
> - RFC 2460, "Internet Protocol Version 6 (IPv6)"
