---
title: "Kernel Protocol Stack 深度探索 (四十)：GRO 与 GSO"
date: 2026-04-13
tags:
  [
    linux,
    kernel,
    networking,
    series,
    gro,
    gso,
    generic-receive-offload,
    generic-segmentation-offload,
    netdev,
    napi,
  ]
description: "深入解析 GRO（Generic Receive Offload）与 GSO（Generic Segmentation Offload）——两者的协作原理、dev_gro_receive 实现、GSO 分片机制、NETIF_F_GSO 标志、以及如何协同 NAPI 和 RPS 提升吞吐"
---

> [!info] Kernel Protocol Stack 深度探索系列 0. [[2026-04-13-kernel-protocol-stack-deep-dive-series-index|全栈学习路径总览]] 39. [[2026-04-13-kernel-protocol-stack-deep-dive-ch39-xdp-integration|第三十九章：XDP 与高性能网络处理]] 40. **第四十章：GRO 与 GSO** 41. [[2026-04-13-kernel-protocol-stack-deep-dive-ch41-rss-rps|第四十一章：RSS 与 RPS]] 42. [[2026-04-13-kernel-protocol-stack-deep-dive-ch42-tso|第四十二章：TSO 与 UFO]]

---

## 1. GRO/GSO 概述

**GSO（Generic Segmentation Offload）** 和 **GRO（Generic Receive Offload）** 是 Linux 内核中两套相互协作的 offload 机制，目标都是减少协议栈处理小包带来的 CPU 开销。

- **GSO**：发送方向——将大块数据在软件层面一次性封装好、分好片，再交给网卡发送，避免协议栈多次处理小段的开销
- **GRO**：接收方向——将网卡收到的同一条 TCP 流的小段合并成一个大包，再提交给协议栈，减少协议栈处理次数

```
发送方向（GSO）:
  应用数据（64KB）
       │
       ▼
  GSO 一次性分片（多个 MSS 的 TSO 包）
       │
       ▼
  网卡硬件（或驱动）直接发送，无需 CPU 再次干预

接收方向（GRO）:
  网卡 RX 队列（多个小段 TCP 包，同一 flow）
       │
       ▼
  GRO 合并成一个大 skb（完整 TCP 段）
       │
       ▼
  提交协议栈（一次处理代替多次）
```

### 1.1 为什么需要 GRO/GSO

以 TCP 为例：一个 bulk transfer 场景下，发送 1MB 数据，MTU=1500， MSS=1460。

没有 GSO 时，协议栈需要处理 1000 次左右的小包发送（skb 分配、IP 头填充、TCP 头填充、校验和计算等）。

有 GSO 时，协议栈只需处理 1 次，然后 GSO 负责拆分成多个物理帧，网卡硬件再逐个发送。类似地，接收方向多个小段合并后，协议栈的处理次数大幅降低。

---

## 2. GSO 详解

### 2.1 GSO 在协议栈的位置

GSO 的分片操作发生在**网络设备层**，位于 IP 层和网卡驱动之间：

```
TCP 层（发送）
    │
    ▼
ip_queue_xmit()  ← 路由查找、IP 头填充
    │
    ├──► [GSO 分片检查] ──► dev_hard_start_xmit()
    │                         │
    │                         ▼
    │                    网卡 TX 队列
    │
    ▼
返回 sock_wfree 回调
```

### 2.2 GSO 分片触发条件

GSO 是否分片由 `net_device` 的 `features` 和 `flags` 决定：

```c
// include/linux/netdevice.h

// 设备特性标志（features）
netdev_features_t features;  // 实际支持的能力

// 设备功能标志（wanted）
netdev_features_t wanted;     // 驱动想要的功能

// 设备标志
unsigned int        flags;   // IFF_* 标志
```

GSO 分片需要以下条件：

1. `features` 中包含 `NETIF_F_SG`（分散-聚集支持）
2. `features` 中包含 `NETIF_F_GSO` 或特定 GSO 类型（如 `NETIF_F_TSO`）
3. skb 长度 > mtu（需要分片）
4. 协议层设置了 `skb_shinfo(skb)->gso_type`

### 2.3 GSO 类型

```c
// include/linux/netdev_features.h

/* GSO 类型 */
NETIF_F_GSO           /* 基础 GSO 能力，所有 offload 的总开关 */
NETIF_F_TSO           /* TCP Segmentation Offload (IPv4) */
NETIF_F_TSO6          /* TCP Segmentation Offload (IPv6) */
NETIF_F_UFO           /* UDP Fragmentation Offload */
NETIF_F_GSO_ROBUST    /* 设备声称的 GSO 分片可靠传输 */
NETIF_F_GSO_UDP_TUNNEL /* UDP 隧道 GSO */
```

### 2.4 GSO 分片实现流程

GSO 的核心函数是 `inet_gso_segment()`（对 TCP）或 `udp6_ufo_fragment()`（对 UDPv6）：

```c
// net/ipv4/af_inet.c
static struct sk_buff *inet_gso_segment(struct sk_buff *skb,
                                         netdev_features_t features)
{
    struct sk_buff *segs = ERR_PTR(-EINVAL);
    struct iphdr *iph = ip_hdr(skb);
    // ... 检查 gso_type

    switch (iph->protocol) {
    case IPPROTO_TCP:
        segs = tcp_gso_segment(skb, features);
        break;
    case IPPROTO_UDP:
        segs = udp4_ufo_segment(skb, features);
        break;
    }
    return segs;
}
```

`tcp_gso_segment()` 的核心逻辑：

```c
// net/ipv4/tcp_output.c
struct sk_buff *tcp_gso_segment(struct sk_buff *skb,
                                 netdev_features_t features)
{
    struct sk_buff *segs;
    struct tcphdr *th;
    struct tcp_skb_cb *tcb;
    unsigned int len;

    // 1. 计算每个分片的长度（按 MSS 对齐）
    th = tcp_hdr(skb);
    tcb = TCP_SKB_CB(skb);
    len = skb->len - th->doff * 4;

    // 2. 如果设备不支持 TSO，退回到 GSO 软件分片
    if (!(features & NETIF_F_TSO))
        return __tcp_maybe_split_segment(skb, len);

    // 3. 构造每个分片（复制 IP 头，调整 TCP 序列号）
    segs = tcp_v4_segment(skb, mss);
    return segs;
}
```

### 2.5 GSO 软件分片

如果网卡不支持硬件 TSO/GSO，内核的 GSO 代码会进行**软件分片**：

```c
static struct sk_buff *__tcp_maybe_split_segment(struct sk_buff *skb,
                                                   unsigned int mss)
{
    struct sk_buff *seg;
    struct tcphdr *th;
    unsigned int len, per_seg;

    th = tcp_hdr(skb);
    len = skb->len - (th->doff * 4);
    per_seg = len;  // 实际按 MSS 计算

    // 逐段分片，每段都包含完整的 TCP/IP 头
    while (len > mss) {
        seg = skb_clone(skb, GFP_ATOMIC);
        // 调整 seg 的 len、TCP 序列号、checksum
        // ...
    }
    return seg;
}
```

---

## 3. GRO 详解

### 3.1 GRO 在协议栈的位置

GRO 位于网络设备层和协议栈之间，在 NAPI 收包路径上被调用：

```
网卡硬件 RX
    │
    ▼
NAPI poll (net_rx_action)
    │
    ▼
GRO (dev_gro_receive)  ← 合并同 flow 的小包
    │
    ▼
netif_receive_skb_internal()
    │
    ├──► RPS (如果启用) → 软中断分发到其他 CPU
    │
    ▼
协议栈（IP 层 → TCP 层）
```

### 3.2 GRO 合并策略

GRO 的合并不是简单的 concat，而是按 **flow** 聚合。flow 的识别基于 L2/L3/L4 头部字段：

```c
// net/core/dev.c - GRO 哈希键
struct gro_recvburs {
    __be32          src_ip;
    __be32          dst_ip;
    __be16          src_port;
    __be16          dst_port;
    __u8            protocol;      // IP 协议 (TCP/UDP)
    __u8            encap_depth;   // 隧道封装深度
};
```

不同协议有不同的合并规则：

| 协议         | 合并条件                                                |
| ------------ | ------------------------------------------------------- |
| **TCP**      | 序列号连续、flag 兼容（PSH+ACK 可以合并，FIN/RST 不行） |
| **UDP**      | 5 元组完全一致即可合并                                  |
| **UDP 隧道** | 外层 5 元组一致 + 内层 payload 长度一致                 |
| **GRE**      | 外层一致，内层 key 一致                                 |

### 3.3 dev_gro_receive 实现

GRO 的核心函数 `dev_gro_receive()` 在 `net/core/dev.c` 中：

```c
// net/core/dev.c
gro_result_t dev_gro_receive(struct napi_struct *napi, struct sk_buff *skb)
{
    gro_result_t ret;
    struct packet_offload *ptype;
    netdev_features_t features;

    // 1. 检查是否启用 GRO
    if (!(napi->flags & NAPI_GRO_FLUSH) &&
        skb->dev->features & NETIF_F_GRO) {
        // 2. 查找/创建 flow hash entry
        struct gro_list *gro_list = &napi->gro_hash[hash];
        skb = napi_gro_receive(napi, skb);
    }

    if (skb)
        ret = netif_receive_skb(skb);  // 合并后提交协议栈
    return ret;
}
```

`napi_gro_receive()` 实现了实际的合并逻辑：

```c
// net/core/dev.c
struct sk_buff *napi_gro_receive(struct napi_struct *napi, struct sk_buff *skb)
{
    struct sk_buff *p;
    unsigned int hash;

    // 1. 计算 flow hash
    hash = skb_get_hash(skb);

    // 2. 在 gro_hash 链表查找匹配的 skb
    list_for_each_entry(p, &napi->gro_hash[hash].list, list) {
        if (gro_match(p, skb)) {
            // 3. 调用协议特定的 merge 函数
            skb = ptype->callbacks.gro_receive(p, skb);
            goto done;
        }
    }

    // 4. 没有匹配，创建一个新的 flow entry
    skb_list_add(skb, &napi->gro_hash[hash].list);
done:
    return skb;
}
```

### 3.4 TCP GRO 合并

TCP 的 GRO 合并由 `tcp4_gro_receive()` 实现：

```c
// net/ipv4/tcp_offload.c
struct sk_buff *tcp4_gro_receive(struct list_head *head, struct sk_buff *skb)
{
    struct tcphdr *th = tcp_hdr(skb);
    struct sk_buff *p;

    // 检查所有已合并的 segment
    list_for_each_entry(p, head, list) {
        struct tcphdr *th2 = tcp_hdr(p);

        // 合并条件：序列号连续、ACK 匹配、flag 兼容
        if (tcp_v4_check(first_seq, th2->ack_seq, ...) == 0 &&
            (th2->doff * 4 == th->doff * 4) &&
            tcp_gro_check(p, th)) {
            // 将新 segment 的 data 合入 p
            skb_gro_recv(p, skb);
            return p;
        }
    }
    return NULL;  // 无法合并，创建新 flow
}
```

合并后的 skb 在 `skb_gro_recv()` 中完成 data 的 memcpy：

```c
// include/linux/skbuff.h
static inline struct sk_buff *skb_gro_recv(struct sk_buff *p, struct sk_buff *skb)
{
    unsigned int headlen = p->len - p->data_len;  // linear part 长度
    void *data;

    // 保持 p 的 skb，追加 skb 的数据到 p 的 frag list
    if (headlen <= skb->len) {
        // 将 skb->data 的 headlen 字节追加到 p 的 tail
        memcpy(p->tail, skb->data, headlen);
        p->tail += headlen;
        p->len += headlen;
    }
    // skb 的剩余部分进入 frag_list
    skb->next = p->next;
    list_move(&skb->list, &p->list);
    return p;
}
```

---

## 4. GRO/GSO 协同工作

GRO 和 GSO 通常成对使用，构成一条**大 OFFLOAD 流水线**：

```
发送端:
  应用 (write/sendfile)
      │
      ▼
  TCP 滑动窗口（可能包含 64KB+ 数据）
      │
      ▼
  ip_queue_xmit → [GSO] → 分成多个 MSS 的 TCP 包
      │
      ▼
  网卡硬件发送（TSO 进一步卸载，或软件 GSO 分片）

接收端:
  网卡硬件或驱动（多个 TCP 段，序列号连续）
      │
      ▼
  GRO → 合并成一个大 TCP 段（64KB+）
      │
      ▼
  TCP 协议栈（一次 deliver_data 代替多次）
```

### 4.1 GRO 与 TSO 的关系

**TSO（TCP Segmentation Offload）** 是硬件 GSO——网卡接过软件 GSO 的活，直接在硬件层面完成 TCP 分段。

```
软件 GSO（Generic）:
  skb (large) → 内核 ip_queue_xmit → 分片后交给网卡 → 网卡逐帧发送

硬件 TSO（Offload）:
  skb (large) → 内核直接交给网卡 → 网卡自己完成 TCP 分段
```

两者的 flags：

```c
// TSO 需要网卡支持
NETIF_F_TSO      /* IPv4 TCP */
NETIF_F_TSO6     /* IPv6 TCP */

// 接收方向，GRO 对应 TSO
NETIF_F_GRO      /* Generic Receive Offload */
```

### 4.2 查看 GRO/GSO 状态

```bash
# 查看网卡 offload 特性
ethtool -k eth0

# 输出示例：
# tcp-segmentation-offload: on
# generic-segmentation-offload: on
# generic-receive-offload: on
# large-receive-offload: on

# 查看 GRO 统计
ethtool -S eth0 | grep -i gro

# rx_gro_packets: 123456    # GRO 合并处理的总包数
# rx_gro_dropped: 12        # GRO 合并失败丢弃的包数
```

---

## 5. GRO 限制与调试

### 5.1 GRO 不能合并的情况

- **TCP RST/FIN**：这两个 flag 标识连接结束，不能与后续数据合并
- **TCP ECE/CWR**：拥塞相关的 flag 变化会中断合并
- **IP Don't Fragment 位被设置**：分片包的 DF 位会导致 GRO 拒绝合并
- **TTL/ToS 不同**：同一 flow 内 TTL 或 Type of Service 变化
- **TCP timestamp 选项不一致**：同一 flow 的 timestamp 必须连续

### 5.2 GRO 内存压力

GRO 在 NAPI poll 期间维护一个 `gro_hash[]` 表。如果一个 flow 的包太多，gro_list 会膨胀，内核通过 `gro_flush_timeelapsed()` 强制 flush：

```c
// net/core/dev.c
static void gro_flush_timeelapsed(struct napi_struct *napi)
{
    struct sk_buff *skb;

    // 每 2ms（可配置）强制 flush 超过 3 个包的 gro_list
    // 避免单个 flow 占用过多内存
    list_for_each_entry(skb, &napi->gro_hash[i].list, list) {
        if (NAPI_GRO_CB(skb)->count > 3)
            napi_gro_complete(skb);
    }
}
```

### 5.3 禁用/启用 GRO

```bash
# 禁用 GRO（调试用）
ethtool -K eth0 gro off

# 启用 GRO
ethtool -K eth0 gro on

# 对特定协议禁用 GRO（通过 sysctl）
sysctl -w net.core.gro_normal_batch=1  # 减少每次 batch 大小
```

---

## 6. 总结

| 机制    | 方向 | 作用                              | 位置               |
| ------- | ---- | --------------------------------- | ------------------ |
| **GSO** | 发送 | 将大块数据分片后再交给网卡        | IP 层和网卡之间    |
| **GRO** | 接收 | 合并同 flow 的小段再提交协议栈    | NAPI 和协议栈之间  |
| **TSO** | 发送 | GSO 的硬件实现，网卡完成 TCP 分段 | 网卡硬件           |
| **LRO** | 接收 | GRO 的旧版本（已被 gro 取代）     | 网卡驱动（已废弃） |

GSO/GRO 的核心价值在于**减少协议栈处理次数**——通过 batch processing 的思路，让 CPU 在一次中断或一次 poll 中处理尽可能多的同 flow 数据，是现代高速网络不可或缺的基础设施。
