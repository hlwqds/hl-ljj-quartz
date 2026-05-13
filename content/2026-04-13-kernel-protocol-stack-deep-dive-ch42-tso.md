---
title: "Kernel Protocol Stack 深度探索 (四十二)：TSO 与 UFO"
date: 2026-04-13
tags: [linux, kernel, networking, series, tso, ufo, tcp-segmentation-offload, udp-fragmentation-offload, gso, offload, checksum-offload]
description: "深入解析 TSO（TCP Segmentation Offload）与 UFO（UDP Fragmentation Offload）——两者的协作原理、TSO 分段机制、GSO 与 TSO 的关系、checksum offload、NETIF_F 标志详解，以及常见问题排查"
---

> [!info] Kernel Protocol Stack 深度探索系列
> 0. [[2026-04-13-kernel-protocol-stack-deep-dive-series-index|全栈学习路径总览]]
> 41. [[2026-04-13-kernel-protocol-stack-deep-dive-ch41-rss-rps|第四十一章：RSS 与 RPS]]
> 42. **第四十二章：TSO 与 UFO**
> 43. [[2026-04-13-kernel-protocol-stack-deep-dive-ch43-bpf-hook|第四十三章：Linux BPF 网络钩子]]
> 44. [[2026-04-13-kernel-protocol-stack-deep-dive-ch44-offload|第四十四章：硬件 offload]]
> 45. [[2026-04-13-kernel-protocol-stack-deep-dive-ch45-tuning|第四十五章：网络性能调优]]

---

## 1. TSO/UFO 概述

**TSO（TCP Segmentation Offload）** 和 **UFO（UDP Fragmentation Offload）** 是两种**硬件 offload** 机制，本质上是 GSO 的硬件实现版本。

- **TSO**：让网卡完成 TCP 分段——内核只需构造一个巨大的 TCP 包（含完整 payload），网卡自动切成多个 MSS 的帧
- **UFO**：让网卡完成 UDP 分片——内核构造一个巨大的 UDP 包，网卡自动按 MTU 分片

```
传统软件 GSO:
  内核构造多个小包 (MSS each) → 交给网卡 → 网卡发送

TSO 硬件 Offload:
  内核构造一个大包 (64KB+) → 交给网卡 → 网卡自己分段 → 发送多个帧
```

---

## 2. TSO 详解

### 2.1 TSO 的工作原理

TSO 将 TCP 分段的开销**从 CPU 移到网卡**：

```
发送 64KB TCP 数据：

无 TSO（软件 GSO）：
  CPU: 构造第 1 个 segment (MSS=1460, TCP/IP header)
  CPU: 构造第 2 个 segment (MSS=1460, TCP/IP header)
  CPU: 构造第 3 个 segment (MSS=1460, TCP/IP header)
  ...
  (44 个包，全部 CPU 处理)
  CPU: 44 次中断确认完成

有 TSO（硬件）：
  CPU: 构造 1 个超大 skb (64KB, TCP header + payload)
  CPU: 交给网卡
  网卡: 自动切成 44 个物理帧
  网卡: 44 次 DMA 发送
  CPU: 1 次中断确认完成
```

### 2.2 TSO 的前提条件

TSO 需要网卡硬件支持，并通过 `net_device->features` 通告：

```c
// include/linux/netdev_features.h

/* TSO 能力标志 */
NETIF_F_TSO      /* TSO for IPv4 */
NETIF_F_TSO6     /* TSO for IPv6 */
NETIF_F_TSO_ECN  /* TSO with ECN (Explicit Congestion Notification) */
```

TSO 触发条件（所有条件同时满足）：

```c
// 检查是否可以做 TSO
bool can_tso(struct sk_buff *skb, netdev_features_t features)
{
    // 1. features 中有 TSO 标志
    if (!(features & NETIF_F_TSO))
        return false;

    // 2. skb 是 IP 包（IPv4 或 IPv6）
    if (skb->protocol != htons(ETH_P_IP) &&
        skb->protocol != htons(ETH_P_IPV6))
        return false;

    // 3. skb_shinfo 包含 gso_type
    if (!skb_shinfo(skb)->gso_type & (SKB_GSO_TCPV4 | SKB_GSO_TCPV6))
        return false;

    // 4. skb 长度 > MSS（值得分片）
    if (skb->len <= skb_shinfo(skb)->gso_segs * tcp_mss(skb))
        return false;

    return true;
}
```

### 2.3 TSO 的 gso_type

```c
// include/linux/skbuff.h

/* TCP GSO 类型 */
SKB_GSO_TCPV4       /* TCP over IPv4 */
SKB_GSO_TCPV6       /* TCP over IPv6 */
SKB_GSO_UDP_TUNNEL  /* UDP 隧道 (如 VXLAN) */
SKB_GSO_FRAGLIST    /* Fragmentation list (多个 frag) */
```

### 2.4 TSO 与 GSO 的关系

GSO 是**软件层面的分片框架**，TSO 是**硬件层面的 GSO 实现**：

```
ip_queue_xmit()
    │
    ├──► 检查网卡的 NETIF_F_TSO
    │       │
    │       ├──► 支持 → 走 TSO 路径：直接发大 skb 给网卡
    │       │
    │       └──► 不支持 → 走 GSO 软件分片：inet_gso_segment()
    │
    ▼
dev_hard_start_xmit()
```

### 2.5 TSO 发送流程

TSO 的发送路径：

```c
// net/ipv4/tcp_output.c
int tcp_sendmsg()
{
    // 数据积累在 socket 的 write queue
    // ...
    // 当数据量足够时，调用 tcp_push()
    tcp_push(sk, tp, ..., tp->mss_cache);
}

static void tcp_push(struct sock *sk, struct tcp_sock *tp, ...)
{
    // 设置 PUSH 标志
    // 调用 ip_queue_xmit()
    ip_queue_xmit(sk, skb);
}

int ip_queue_xmit(struct sock *sk, struct sk_buff *skb)
{
    // 填充 IP 头
    // ...
    // 检查是否 TSO
    if (skb->len > dst->dev->mtu &&
        dst->dev->features & NETIF_F_TSO) {
        // 设置 GSO type
        skb_shinfo(skb)->gso_type = SKB_GSO_TCPV4;
        skb_shinfo(skb)->gso_segs = DIV_ROUND_UP(skb->len, tcp_mss(skb));
    }

    // 走正常发送路径
    dev_queue_xmit(skb);
}
```

网卡驱动在 `dev_hard_start_xmit()` 中检查 TSO：

```c
// 驱动中的发送函数（如 igb）
netdev_tx_t igb_xmit_frame(struct sk_buff *skb)
{
    // 检查 TSO
    if (skb_shinfo(skb)->gso_type & SKB_GSO_TCP) {
        // 配置网卡 TSO 描述符
        // 只需要告诉网卡：大包的地址、长度、TCP 序列号起始值
        // 网卡自动处理后续分段
        return NETDEV_TX_OK;
    }

    // 非 TSO 路径：普通发送
    return igb_xmit_frame_non_tso(skb);
}
```

---

## 3. UFO 详解

### 3.1 UFO 的工作原理

UFO（UDP Fragmentation Offload）是 UDP 的硬件分片：

```
发送一个 8KB UDP 包（MTU=1500）：

无 UFO（软件分片）：
  内核: IP 层分片 (6 个 IP fragment)
  内核: 每个 fragment 都有完整的 IP 头 + UDP 头（开销大）

有 UFO（硬件）：
  内核: 构造 1 个大 UDP 包
  网卡: 自动按 1500 字节分片，只在第 1 片有完整 UDP 头
  网卡: DMA 发送
```

### 3.2 UFO 的前提条件

```c
// UFO 能力标志
NETIF_F_UFO        /* UDP Fragmentation Offload (IPv4) */
NETIF_F_UFO6       /* UDP Fragmentation Offload (IPv6) - 不常见 */
```

UFO 触发条件：

```c
bool can_ufo(struct sk_buff *skb, netdev_features_t features)
{
    // 1. UDP 协议
    if (ip_hdr(skb)->protocol != IPPROTO_UDP)
        return false;

    // 2. 设备支持 UFO
    if (!(features & NETIF_F_UFO))
        return false;

    // 3. skb 长度 > MTU
    if (skb->len <= dst->dev->mtu)
        return false;  // 不需要分片

    // 4. IP Don't Fragment 位为 0（允许分片）
    if (ip_hdr(skb)->frag_off & htons(IP_DF))
        return false;  // DF=1 不能 UFO

    return true;
}
```

### 3.3 UFO 与 IP 分片的区别

```
软件 IP 分片（不使用 UFO）：
  原始: UDP(8KB) + IP(20)
  第1片: IP(20) + UDP(8) + IP_FRAG(8) offset=0 more=1
  第2片: IP(20) + UDP(8)            offset=1480 more=1
  第3片: IP(20) + UDP(8)            offset=2960 more=1
  ...
  问题: 每个分片都有完整 IP 头，UDP 头只出现在第 1 片
        丢失任一片则整个 UDP 包丢失

UFO（硬件）：
  第1片: IP(20) + UDP(8) + data(1472)  ← 第 1 片有 UDP 头
  第2片: IP(20) + data(1500)
  ...
  网卡硬件处理，CPU 只需构造一次
```

---

## 4. Checksum Offload

### 4.1 Checksum Offload 与 TSO/UFO 的关系

TSO/UFO 分片后，每个帧需要正确的 TCP/UDP/IP checksum。Checksum offload 让网卡计算校验和：

```
TX Checksum Offload（L4）:
  CPU: 计算 pseudo header checksum（放在 TCP/UDP 头的 chksum 字段）
  CPU: 通知网卡：需要计算 TCP/UDP checksum
  网卡: DMA 时计算完整 checksum 并写入

TX Checksum Offload（L3）:
  CPU: IP 头 checksum = 0
  CPU: 通知网卡：需要计算 IP header checksum
  网卡: DMA 时计算 IP checksum
```

### 4.2 Checksum Offload 标志

```c
// NETIF_F 特性标志
NETIF_F_IP_CSUM      /* IPv4 TCP/UDP checksum offload */
NETIF_F_IPV6_CSUM     /* IPv6 TCP/UDP checksum offload */
NETIF_F_HW_CSUM       /* 通用 checksum offload (L3+L4) */
NETIF_F_SG            /* 分散-聚集 DMA */
```

### 4.3 TSO + Checksum Offload 的特殊情况

TSO 场景下，TCP checksum 的处理比较特殊：

```
标准 checksum 计算：
  TCP checksum = ~(pseudo_header_sum + TCP header + payload)

TSO 场景：
  TCP checksum 不使用 pseudo header 方式
  而是在每个 segment 中填写正确的序列号范围
  网卡计算 "partial checksum"：
    partial = ~(src_ip + dst_ip + length + protocol + TCP header)
  最终 checksum = partial + segment payload checksum
```

---

## 5. TSO/UFO 配置与调试

### 5.1 查看 offload 状态

```bash
# 查看网卡 offload 特性（ethtool -k 是 --show-offload 的别名）
ethtool -k eth0

# 关键输出：
# tcp-segmentation-offload: on       # TSO
#      [fixed]                       # 可能是固定开启的
# udp-fragmentation-offload: off    # UFO（部分驱动支持）
# scatter-gather: on                 # SG，需要 TSO/UFO
# tcp-header-split: off             # Header Split mode
#     [fixed]                       # 部分网卡支持，将 header/data 分开 DMA
```

### 5.2 启用/禁用 TSO

```bash
# 禁用 TSO（调试用）
ethtool -K eth0 tso off

# 启用 TSO
ethtool -K eth0 tso on

# 禁用 UFO（通常默认关闭）
ethtool -K eth0 ufo off
```

### 5.3 TSO 统计

```bash
# 查看 TSO 统计
ethtool -S eth0 | grep -i tso

# 输出示例：
# tx_tso_frames: 123456        # TSO 帧数
# tx_tso_bytes: 1234567890     # TSO 总字节数
# tx_tso_fallback: 123         # TSO 失败回退次数（硬件不支持时走 GSO）
```

### 5.4 TSO vs 软件 GSO 的性能对比

| 场景 | 软件 GSO | TSO (硬件) |
|------|---------|-----------|
| CPU 开销 | 高（逐个分片） | 极低（一次构造） |
| 最大吞吐 | ~5-10 Gbps（取决于 CPU） | 线速（40/100 Gbps） |
| 分片灵活性 | 完全可控 | 受网卡限制 |

---

## 6. 常见问题

### 6.1 TSO 导致的问题

**问题 1：TSO 包太大导致 DMA 失败**

某些网卡对 TSO skb 有最大大小限制（如 64KB）。内核通过 `NETIF_F_GSO_MAX_SIZE` 通告：

```bash
# 查看 TSO 最大分片大小
ethtool -g eth0

# 输出示例：
# rx-max: 16384  (RX 最大 ring size)
# tx-max: 16384  (TX 最大 ring size)
```

**问题 2：TSO + VLAN 的问题**

某些旧网卡在 TSO 时不能正确处理 VLAN tag。可以通过禁用 VLAN offload 临时解决：

```bash
ethtool -K eth0 vlan-offload off
```

**问题 3：TSO 计数器不增长但实际有发送**

某些驱动不使用 TSO 统计，而是通过软件 GSO 回退。检查 `tx_tso_fallback` 是否为 0。

### 6.2 UFO 的限制

UFO 在生产环境中**很少使用**，原因：

1. UDP 分片丢失任意一片，整个 UDP 包就失效
2. 大多数 UDP 应用（如 QUIC、DNS）在应用层自己做分片
3. 很多网卡不支持 UFO

### 6.3 TSO 与 GRO 的协同

TSO 发送的多个分段，接收端通过 GRO 合并：

```
发送端（TSO）:
  应用 64KB → TSO 分 44 个帧 → 网卡发送

接收端（GRO）:
  44 个帧 → GRO 合并成 1 个大 skb → 协议栈处理
```

这就是为什么禁用 GRO 会显著增加高速 TCP 传输的 CPU 占用。

---

## 7. 总结

| 机制 | 协议 | 方向 | 实现层 | 关键标志 |
|------|------|------|--------|---------|
| **TSO** | TCP | 发送 | 网卡硬件 | NETIF_F_TSO |
| **UFO** | UDP | 发送 | 网卡硬件 | NETIF_F_UFO |
| **GSO** | 通用 | 发送 | 内核软件 | NETIF_F_GSO |
| **GRO** | 通用 | 接收 | 内核软件 | NETIF_F_GRO |

TSO/UFO 的本质是**将分片开销卸载到网卡**，让 CPU 只需构造一次大包，大幅降低高速网络下的 CPU 负载。配合 GRO 使用，可以实现几乎零软件开销的 bulk data 传输。
