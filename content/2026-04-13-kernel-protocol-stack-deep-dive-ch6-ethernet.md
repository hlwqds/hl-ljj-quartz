---
title: "Kernel Protocol Stack 深度探索 (六)：Ethernet 与 MAC 层"
date: 2026-04-13
tags: [linux, kernel, networking, series, ethernet, mac, arp, switch, vlan]
description: "深入解析以太网技术——Ethernet 帧格式、MAC 地址与地址解析协议（ARP）、帧类型与协议识别、VLAN Tagging（802.1Q）、以及交换机基础与 MAC 地址学习"
---

> [!info] Kernel Protocol Stack 深度探索系列 0. [[2026-04-13-kernel-protocol-stack-deep-dive-series-index|全栈学习路径总览]]
>
> 1. [[2026-04-13-kernel-protocol-stack-deep-dive-ch1-skbuff|第一章：sk_buff 与数据包生命周期]]
> 2. [[2026-04-13-kernel-protocol-stack-deep-dive-ch2-netdevice|第二章：Netdevice 与网卡抽象]]
> 3. [[2026-04-13-kernel-protocol-stack-deep-dive-ch3-ring-buffer|第三章：Ring Buffer 与 DMA]]
> 4. [[2026-04-13-kernel-protocol-stack-deep-dive-ch4-softirq|第四章：软中断与 ksoftirqd]]
> 5. [[2026-04-13-kernel-protocol-stack-deep-dive-ch5-napi|第五章：NAPI 与轮询模式]]
> 6. **第六章：Ethernet 与 MAC 层**

---

## 1. 概述：以太网在网络栈中的位置

以太网（Ethernet）是目前局域网事实标准的链路层协议。它工作在 OSI 模型的第二层（数据链路层），负责相邻节点之间的帧传输。

**以太网在 Linux 网络栈中的位置：**

```
┌─────────────────────────────────────────────────────────────┐
│                    Ethernet Frame                           │
├──────────┬──────────┬──────────┬───────────┬────────────────┤
│  Preamble│   Dest   │   Src    │   Type/   │    Payload     │
│  (7B)    │   MAC    │   MAC    │   Length  │    (46-1500B)  │
│          │ (6B)     │ (6B)     │   (2B)    │                │
│          │          │          │           │   + 4B CRC      │
├──────────┴──────────┴──────────┴───────────┴────────────────┤
│                                                             │
│  L2 (Data Link)    ───────►  Ethernet / MAC / VLAN         │
│                                                             │
│  L3 (Network)      ───────►  IPv4 / IPv6 / ARP              │
│                                                             │
│  L4 (Transport)    ───────►  TCP / UDP / SCTP               │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## 2. 以太网帧格式详解

### 2.1 IEEE 802.3 vs Ethernet II

目前局域网主要使用两种帧格式：

**Ethernet II（最常用）：**

```
┌────────┬─────────────┬─────────────┬────────────────┬────────┬───────┐
│Preamble│  Dest MAC   │  Src MAC    │   EtherType    │ Data   │ CRC   │
│ 7 bytes│   6 bytes   │   6 bytes   │    2 bytes     │46-1500 │ 4B    │
│        │             │             │                │ bytes  │       │
└────────┴─────────────┴─────────────┴────────────────┴────────┴───────┘
         ◄────────────────────────── 14 bytes ──────────────────────►
```

**IEEE 802.3（带 LLC/SNAP）：**

```
┌────────┬─────────────┬─────────────┬──────────┬────────────────────┬────────┬───────┐
│Preamble│  Dest MAC   │  Src MAC    │   Length │     LLC+SNAP       │ Data  │ CRC   │
│ 7 bytes│   6 bytes   │   6 bytes   │  2 bytes │     8 bytes        │46-1500│ 4B    │
│        │             │             │          │                    │ bytes │       │
└────────┴─────────────┴─────────────┴──────────┴────────────────────┴────────┴───────┘
                                    ◄─── 802.2 LLC ───►
```

**关键区别：**

| 特性             | Ethernet II                             | IEEE 802.3         |
| ---------------- | --------------------------------------- | ------------------ |
| Type/Length 字段 | EtherType (> 0x0600)                    | Length (<= 0x0600) |
| 协议识别         | EtherType 直接标识                      | 802.2 LLC 封装     |
| 常用协议         | IPv4(0x0800), ARP(0x0806), IPv6(0x86DD) | IPX, AppleTalk     |
| 兼容性           | 几乎所有设备                            | 传统设备           |

### 2.2 常用 EtherType

```c
// include/uapi/linux/if_ether.h
#define ETH_P_LOOP      0x0060      // 回路协议
#define ETH_P_PUP       0x0200      // PUP 协议
#define ETH_P_IP        0x0800      // IPv4
#define ETH_P_X25       0x0805      // X.25
#define ETH_P_ARP       0x0806      // 地址解析协议
#define ETH_P_BPQ       0x08F7      // G8BPQ AX.25
#define ETH_P_IEEE802154 0x0F3F     // IEEE 802.15.4
#define ETH_P_IPV6      0x86DD      // IPv6
#define ETH_P_MPLS_UC   0x8847      // MPLS 单播
#define ETH_P_MPLS_MC   0x8848      // MPLS 多播
#define ETH_P_PPP_DISC  0x8863      // PPPoE 发现
#define ETH_P_PPP_SES   0x8864      // PPPoE 会话
#define ETH_P_8021Q     0x8100      // VLAN 标签
#define ETH_P_8021AD    0x88A8      // Q-in-Q / 802.1ad
#define ETH_P_SLOW      0x8809      // LACP, STP
#define ETH_P_FCOE      0x8906      // Fibre Channel over Ethernet
#define ETH_P_IBOE      0x8915      // RDMA over Converged Ethernet
#define ETH_P_TIPC      0x88CA      // TIPC
```

### 2.3 以太网帧结构代码表示

```c
// include/uapi/linux/if_ether.h
struct ethhdr {
    unsigned char   h_dest[ETH_ALEN];    // 目标 MAC 地址 (6 bytes)
    unsigned char   h_source[ETH_ALEN];   // 源 MAC 地址 (6 bytes)
    __be16          h_proto;              // 协议类型 (2 bytes)
} __attribute__((packed));

// ETH_ALEN 定义
#define ETH_ALEN        6               // MAC 地址长度
#define ETH_HLEN        14              // Ethernet 头长度
#define ETH_ZLEN        60              // 最小帧长度 (不含 CRC)
#define ETH_FRAME_LEN   1514            // 最大帧长度 (不含 CRC)
#define ETH_FCS_LEN     4               // CRC 长度
#define ETH_DATA_LEN    1500            // 最大负载长度 (MTU)
#define ETH_MAX_LEN     1518            // 最大帧长度 (含 CRC)
```

---

## 3. MAC 地址详解

### 3.1 MAC 地址结构

MAC 地址是 48 位（6 字节）的唯一标识符：

```
┌─────────────────────────────────────────────────────────┐
│                    48-bit MAC Address                   │
├─────────┬─────────┬─────────┬─────────┬─────────┬────────┤
│ Byte 0  │ Byte 1  │ Byte 2  │ Byte 3  │ Byte 4  │ Byte 5 │
│ OUI[0]  │ OUI[1]  │ OUI[2]  │  NIC[0] │  NIC[1] │ NIC[2] │
└─────────┴─────────┴─────────┴─────────┴─────────┴────────┘
          ◄─────── 24-bit OUI (厂商标识) ────────►
                    ◄─────── 24-bit NIC (网卡ID) ──────►
```

**特殊地址：**

| 地址                | 用途                      |
| ------------------- | ------------------------- |
| `FF:FF:FF:FF:FF:FF` | 广播地址（所有主机）      |
| `01:00:5E:xx:xx:xx` | IPv4 多播地址（RFC 1112） |
| `01:80:C2:xx:xx:xx` | 链路本地多播（STP, LACP） |
| `33:33:xx:xx:xx:xx` | IPv6 多播地址             |
| `00:00:00:00:00:00` | 黑洞地址（未初始化）      |

### 3.2 MAC 地址类型

Linux 内核区分多种 MAC 地址类型：

```c
// include/linux/netdevice.h
enum netdev_mac_addr_type {
    NETDEV_HW_ADDR_T_NORMAL,        // 普通单播/多播
    NETDEV_HW_ADDR_T_UNICAST,       // 单播地址
    NETDEV_HW_ADDR_T_MULTICAST,     // 多播地址
    NETDEV_HW_ADDR_T_SOLlicitED,    // Solicited-node 多播地址
    NETDEV_HW_ADDR_T_ALL,           // 所有接口地址
    NETDEV_HW_ADDR_T_PERSISTENT,    // 永久地址
    NETDEV_HW_ADDR_T_NOCACHE,      // 非缓存地址
    NETDEV_HW_ADDR_T_UNICAST_IFTYPE, // 接口类型单播
};
```

### 3.3 MAC 地址管理 API

```c
// 获取网卡的 MAC 地址
static inline unsigned char *dev_addr(const struct net_device *dev)
{
    return dev->dev_addr;
}

// 克隆 MAC 地址列表
int dev_addr_del(struct net_device *dev, const unsigned char *addr,
                 unsigned char addr_type);

// 添加 MAC 地址
int dev_addr_add(struct net_device *dev, const unsigned char *addr,
                 unsigned char addr_type);

// 批量添加多播地址
int dev_mc_add(struct net_device *dev, const unsigned char *addr);
int dev_mc_add_excl(struct net_device *dev, const unsigned char *addr);
int dev_mc_del(struct net_device *dev, const unsigned char *addr);

// 刷新多播地址列表（驱动调用）
void dev_mc_flush(struct net_device *dev);
void dev_mc_destroy(struct net_device *dev);
```

---

## 4. eth_type_trans：协议识别

### 4.1 eth_type_trans 实现

当网卡驱动将 skb 送入协议栈时，必须调用 `eth_type_trans` 设置协议类型：

```c
// net/ethernet/eth.c
__be16 eth_type_trans(struct sk_buff *skb, struct net_device *dev)
{
    struct ethhdr *eth = (struct ethhdr *)skb->data;

    skb->mac_header = (unsigned char *)eth - skb->head;
    skb->protocol = eth->h_proto;  // 直接从帧提取 EtherType

    // 检查是否带 VLAN tag
    if (eth->h_proto == htons(ETH_P_8021Q) ||
        eth->h_proto == htons(ETH_P_8021AD)) {
        // 提取 VLAN 信息
        struct vlan_hdr *vlan = (struct vlan_hdr *)(eth + 1);
        __be16 vlan_proto = eth->h_proto;
        u16 vlan_id;

        vlan_id = ntohs(vlan->h_vlan_TCI) & VLAN_VID_MASK;
        __vlan_hwaccel_put_tag(skb, vlan_proto, vlan_id);

        // 提取内层协议类型
        skb->protocol = vlan->h_vlan_encapsulated_proto;
    }

    // 检查是否为桥接/本地环回
    if (unlikely(!compare_ether_addr(eth->h_dest, dev->dev_addr))) {
        // 目的 MAC = 本机 MAC（接收）
        skb->pkt_type = PACKET_HOST;
    } else if (eth->h_dest[0] & 1) {
        // 目的 MAC 是多播
        skb->pkt_type = PACKET_MULTICAST;
    } else {
        // 其他（混杂模式或其他 MAC）
        skb->pkt_type = PACKET_OTHERHOST;
    }

    return skb->protocol;
}
```

### 4.2 PACKET_TYPE 与协议注册

Linux 通过 `packet_type` 结构注册协议处理函数：

```c
// include/linux/netdevice.h
struct packet_type {
    __be16          type;           // EtherType
    struct net_device   *dev;       // NULL 表示所有设备
    int             (*func)(struct sk_buff *,
                           struct net_device *,
                           struct packet_type *,
                           struct net_device *);
    __u32           af_override;   // address family
    bool            (*id_match)(struct packet_type *ptype,
                                struct sock *sk);
    void            *af_packet_priv; // AF_PACKET 私有数据
    struct list_head list;
};
```

**协议注册示例：**

```c
// IPv4 注册
static struct packet_type ip_packet_type = {
    .type = htons(ETH_P_IP),
    .func = ip_rcv,
};

dev_add_pack(&ip_packet_type);

// IPv6 注册
static struct packet_type ipv6_packet_type = {
    .type = htons(ETH_P_IPV6),
    .func = ipv6_rcv,
};

dev_add_pack(&ipv6_packet_type);

// ARP 注册
static struct packet_type arp_packet_type = {
    .type = htons(ETH_P_ARP),
    .func = arp_rcv,
};

dev_add_pack(&arp_packet_type);
```

---

## 5. VLAN Tagging（802.1Q）

### 5.1 VLAN 帧格式

IEEE 802.1Q 在 Ethernet 帧中插入 4 字节 VLAN tag：

```
┌─────────────┬─────────────┬──────────┬──────────────┬────────────────┐
│ Dest MAC    │  Src MAC    │ VLAN Tag │  EtherType   │    Payload     │
│   6B        │    6B       │   4B     │    2B        │   46-1500B     │
└─────────────┴─────────────┴──────────┴──────────────┴────────────────┘
                                                   ◄───── 14+4=18B ───►
```

**VLAN Tag 结构：**

```c
// include/linux/if_vlan.h
struct vlan_hdr {
    __be16  h_vlan_TCI;       // Tag Control Information (2B)
    __be16  h_vlan_encapsulated_proto;  // 内部 EtherType (2B)
};

struct vlan_ethhdr {
    unsigned char   h_dest[ETH_ALEN];
    unsigned char   h_source[ETH_ALEN];
    __be16          h_vlan_proto;
    __be16          h_vlan_TCI;
    __be16          h_vlan_encapsulated_proto;
};

// VLAN Tag Control Information (TCI)
struct {
    __u16   PCP:3,       // Priority Code Point (802.1p QoS)
            DEI:1,       // Drop Eligibility Indicator
            VID:12;      // VLAN ID (0-4095)
};
```

### 5.2 VLAN 在内核中的处理

**VLAN 是网卡驱动的"叠加"——不改变硬件行为，只是软件解析：**

```c
// net/8021q/vlan.c
static int vlan_dev_tx(struct sk_buff *skb, struct net_device *dev)
{
    struct vlan_dev_priv *vlan = vlan_dev_priv(dev);
    u16 vlan_id = vlan->vlan_id;

    // 剥除 VLAN tag（TX 时）
    if (skb->vlan_tci & VLAN_TAG_PRESENT) {
        skb->vlan_tci = 0;
        skb->protocol = eth_type_trans(skb, skb->dev);
    }

    // 交给物理网卡发送
    return dev_queue_xmit(skb);
}

// net/8021q/vlan_rx.c
static rx_handler_result_t vlan_rx_handler(struct sk_buff **pskb)
{
    struct vlan_group *grp;
    struct vlan_dev_priv *vlan;
    struct sk_buff *skb = *pskb;
    struct net_device *dev;
    u16 vlan_id;

    // 从 skb 提取 VLAN tag
    if (skb->vlan_tci & VLAN_TAG_PRESENT)
        vlan_id = vlan_tci & VLAN_VID_MASK;
    else
        vlan_id = 0;

    // 查找对应的 VLAN 设备
    grp = rcu_dereference(skb->dev->vlan_group);
    dev = vlan_group_get_device(grp, vlan_id);

    if (dev) {
        // 将 skb 送到 VLAN 设备
        skb->dev = dev;
        return RX_HANDLER_ANOTHER;
    }

    return RX_HANDLER_PASS;
}
```

### 5.3 VLAN 配置

```bash
# 创建 VLAN 接口
ip link add link eth0 name eth0.100 type vlan id 100

# 或使用 vconfig（传统方式）
vconfig add eth0 100

# 配置 IP
ip addr add 192.168.100.1/24 dev eth0.100
ip link set eth0.100 up

# 查看 VLAN 信息
ip -d link show eth0.100
cat /proc/net/vlan/config

# 删除 VLAN
ip link delete eth0.100
```

---

## 6. ARP：地址解析协议

### 6.1 ARP 协议格式

ARP 解决"IP 地址 → MAC 地址"的映射问题：

```c
// include/uapi/linux/if_arp.h
struct arphdr {
    __be16      ar_hrd;         // 硬件类型 (ARPHRD_ETHER = 1)
    __be16      ar_pro;         // 协议类型 (ETH_P_IP = 0x0800)
    unsigned char   ar_hln;      // 硬件地址长度 (ETH_ALEN = 6)
    unsigned char   ar_pln;      // 协议地址长度 (4 for IPv4)
    __be16      ar_op;          // 操作码 (ARPOP_REQUEST/REPLY)

    // 后面紧跟：
    // ar_sha (发送者 MAC)
    // ar_sip (发送者 IP)
    // ar_tha (目标 MAC)
    // ar_tip (目标 IP)
};
```

**ARP 操作码：**

```c
#define ARPOP_REQUEST    1      // ARP 请求（谁有 192.168.1.1？）
#define ARPOP_REPLY      2      // ARP 响应（192.168.1.1 是 aa:bb:cc:dd:ee:ff）
#define ARPOP_RREQUEST   3      // RARP 请求
#define ARPOP_RREPLY     4      // RARP 响应
#define ARPOP_InREQUEST  5      // InARP 请求
#define ARPOP_InREPLY    6      // InARP 响应
#define ARPOP_NAK        7      // ARP NAK
```

### 6.2 ARP 在内核中的实现

```c
// net/ipv4/arp.c
int arp_rcv(struct sk_buff *skb, struct net_device *dev,
            struct packet_type *pt, struct net_device *orig_dev)
{
    struct arphdr *arp;
    struct rtable *rt;
    unsigned char *arp_ptr;
    __be32 sip, tip;

    // 1. 检查是否是我们关心的 EtherType/IP 组合
    if (arp->ar_pro != htons(ETH_P_IP))
        goto drops;  // 只处理 IPv4 ARP

    // 2. 检查 ARP 长度是否正确
    if (skb->len < sizeof(struct arphdr) + 4 * ETH_ALEN)
        goto drops;

    // 3. 提取 ARP 信息
    arp_ptr = (unsigned char *)(arp + 1);
    memcpy(&sha, arp_ptr, ETH_ALEN);        // 发送者 MAC
    arp_ptr += ETH_ALEN;
    memcpy(&sip, arp_ptr, 4);                // 发送者 IP
    arp_ptr += 4;
    memcpy(&tha, arp_ptr, ETH_ALEN);         // 目标 MAC
    arp_ptr += 4;
    memcpy(&tip, arp_ptr, 4);                // 目标 IP

    // 4. 处理 ARP 包
    if (arp->ar_op == htons(ARPOP_REQUEST)) {
        // ARP 请求：IP 在本机接口上？
        if (inet_addrype(tip) == RTN_LOCAL)
            arp_send(ARPOP_REPLY, ETH_P_ARP, sip, dev, tip, sha, dev->dev_addr, sha);
    }

    // 5. 学习发送者 MAC -> IP 映射
    neigh_update(neigh, sha, NUD_STALE, ...);

    kfree_skb(skb);
    return 0;
}

// ARP 表操作
struct neighbour *neigh_lookup(struct neigh_table *tbl, const void *pkey, struct net_device *dev);
int neigh_update(struct neighbour *neigh, const u8 *lladdr, u8 new, ...);
```

### 6.3 ARP 表管理

```bash
# 查看 ARP 表
ip neigh show

# 或
arp -a

# 静态添加 ARP 条目
ip neigh add 192.168.1.100 lladdr aa:bb:cc:dd:ee:ff dev eth0

# 删除 ARP 条目
ip neigh del 192.168.1.100 dev eth0

# 查看 ARP 统计
ip -s neigh show
```

---

## 7. 交换机基础与 MAC 学习

### 7.1 MAC 地址学习原理

交换机维护一个 MAC 地址表（FIB），基于源地址学习：

```c
struct net_bridge_fdb_entry {
    struct hlist_node   hlist;      // 哈希表链表节点
    struct net_bridge_port   *dst;   // 所属端口
    unsigned char       addr[6];     // MAC 地址
    unsigned short      vlan_id;     // VLAN ID
    unsigned char       is_local;    // 是否本地生成
    unsigned char       is_static;   // 是否静态配置
    unsigned long       updated;     // 最后更新时间
    unsigned long       used;
    struct rcu_head     rcu;
};
```

**MAC 学习流程：**

```c
// net/bridge/br_fdb.c
static void br_fdb_update(struct net_bridge *br, struct net_bridge_port *source,
                          const unsigned char *addr, u16 vid)
{
    struct hlist_head *head = &br->hash[MAC(addr)];
    struct net_bridge_fdb_entry *fdb;

    // 查找现有条目
    fdb = fdb_find(head, addr, vid);
    if (likely(fdb)) {
        // 更新：如果来源端口不同，更新出口
        if (likely(fdb->dst == source))
            fdb->used = jiffies;
        else {
            // MAC 漂移：从旧端口移到新端口
            fdb->dst = source;
            fdb->updated = jiffies;
        }
    } else {
        // 学习新 MAC：添加到 FDB
        fdb = kmalloc(sizeof(*fdb), GFP_ATOMIC);
        if (likely(fdb)) {
            memcpy(fdb->addr, addr, ETH_ALEN);
            fdb->dst = source;
            fdb->vlan_id = vid;
            fdb->updated = fdb->used = jiffies;
            hlist_add_head_rcu(&fdb->hlist, head);
            br->fdb_insert_count++;
        }
    }
}
```

### 7.2 交换机转发逻辑

```
Incoming Frame:
    │
    ▼
┌─────────────────────────────────────┐
│  检查目的 MAC 是否为广播/多播       │
│    │                                │
│    ├─ 是 ──► 洪泛到所有端口（除入口）│
│    │                                │
│    └─ 否 ─► 在 MAC 表中查找         │
│              │                      │
│              ├─ 找到 ─► 转发到对应端口│
│              │    (除入口)           │
│              │                      │
│              └─ 未找到 ─► 洪泛       │
└─────────────────────────────────────┘
```

```c
// net/bridge/br_forward.c
static void __br_forward(const struct net_bridge_port *to,
                         struct sk_buff *skb)
{
    struct net_device *indev = skb->dev;

    // 设置出口设备
    skb->dev = to->dev;

    // 更新统计
    to->dev->stats.tx_packets++;
    to->dev->stats.tx_bytes += skb->len;

    // 发送到出口
    __br_dispatch(skb, to);
}

static void __br_dispatch(struct net_bridge_port *src,
                           struct sk_buff *skb)
{
    struct net_bridge *br = src->br;
    struct net_bridge_fdb_entry *fdb;
    const unsigned char *dest = eth_hdr(skb)->h_dest;

    // 多播/广播：洪泛
    if (is_multicast_ether_addr(dest)) {
        br_flood_forward(src, skb);
        return;
    }

    // 单播：MAC 表查找
    fdb = br_fdb_find(br, dest, skb->vlan_id);
    if (fdb && fdb->dst != src) {
        // 已知单播：转发到特定端口
        br_forward(fdb->dst, skb);
    } else {
        // 未知单播：洪泛
        br_flood_forward(src, skb);
    }
}
```

### 7.3 网桥配置

```bash
# 创建网桥
ip link add br0 type bridge

# 将接口加入网桥
ip link set eth0 master br0
ip link set eth1 master br0

# 或使用传统 brctl
brctl addbr br0
brctl addif br0 eth0
brctl addif br0 eth1

# 配置 IP（作为三层接口）
ip addr add 192.168.1.1/24 dev br0
ip link set br0 up

# 查看 MAC 表
bridge fdb show

# 查看 STP 状态
bridge -d link show

# 查看网桥配置
brctl show
bridge vlan show
```

---

## 8. 小结与下章预告

本章深入解析了以太网与 MAC 层的核心技术：

1. **帧格式**：Ethernet II 与 IEEE 802.3 的区别、EtherType
2. **MAC 地址**：48-bit 地址结构、多播地址、地址管理 API
3. **协议识别**：`eth_type_trans` 与 packet_type 注册
4. **VLAN**：802.1Q tag 格式、TCI 结构、VLAN 在内核中的处理
5. **ARP**：地址解析协议格式、内核实现、ARP 表管理
6. **交换机基础**：MAC 学习、FDB 表、洪泛与转发逻辑

**下章（网桥与 Switchdev）** 将深入讲解 Linux 网桥的高级特性——VLAN 过滤、STP 生成树协议、switchdev offload 模式、以及 br_netfilter 如何与 Netfilter 集成。

---

## 参考资料

- `include/uapi/linux/if_ether.h` — 以太网常量定义
- `include/uapi/linux/if_arp.h` — ARP 协议格式
- `include/linux/if_vlan.h` — VLAN 定义
- `net/ethernet/eth.c` — eth_type_trans 实现
- `net/ipv4/arp.c` — ARP 协议实现
- `net/bridge/br_fdb.c` — MAC 地址学习
- `net/bridge/br_forward.c` — 转发逻辑
- IEEE 802.3 — 以太网标准
- IEEE 802.1Q — VLAN tagging 标准
