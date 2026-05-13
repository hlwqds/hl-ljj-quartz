---
title: "Kernel Protocol Stack 深度探索 (十七)：GRE 隧道协议"
date: 2026-04-13
tags: [linux, kernel, networking, series, tunnel, gre, vpn, encapsulation]
description: "深入解析 Linux GRE 隧道协议——GRE 头部结构、封装解封装流程、键值认证、PMTUD 分片问题、以及与 IPsec 的对比"
---

> [!info] Kernel Protocol Stack 深度探索系列
> 0. [[2026-04-13-kernel-protocol-stack-deep-dive-series-index|全栈学习路径总览]]
> 1. [[2026-04-13-kernel-protocol-stack-deep-dive-ch1-skbuff|第一章：sk_buff 与数据包生命周期]]
> 2. [[2026-04-13-kernel-protocol-stack-deep-dive-ch2-netdevice|第二章：Netdevice 与网卡抽象]]
> 3. [[2026-04-13-kernel-protocol-stack-deep-dive-ch3-ring-buffer|第三章：Ring Buffer 与 DMA]]
> 4. [[2026-04-13-kernel-protocol-stack-deep-dive-ch4-softirq|第四章：软中断与 ksoftirqd]]
> 5. [[2026-04-13-kernel-protocol-stack-deep-dive-ch5-napi|第五章：NAPI 与轮询模式]]
> 6. [[2026-04-13-kernel-protocol-stack-deep-dive-ch6-ethernet|第六章：Ethernet 与 MAC 层]]
> 7. [[2026-04-13-kernel-protocol-stack-deep-dive-ch7-bridge|第七章：网桥与 Switchdev]]
> 8. [[2026-04-13-kernel-protocol-stack-deep-dive-ch8-vlan|第八章：VLAN 与 802.1Q]]
> 9. [[2026-04-13-kernel-protocol-stack-deep-dive-ch9-macvlan|第九章：MACVLAN 与虚拟网卡]]
> 10. [[2026-04-13-kernel-protocol-stack-deep-dive-ch10-bonding|第十章：Bonding 与 teamd]]
> 11. [[2026-04-13-kernel-protocol-stack-deep-dive-ch11-ip-framing|第十一章：IP 协议封装]]
> 12. [[2026-04-13-kernel-protocol-stack-deep-dive-ch12-routing|第十二章：路由与 FIB]]
> 13. [[2026-04-13-kernel-protocol-stack-deep-dive-ch13-neighbor|第十三章：Neighbor 与 ARP]]
> 14. [[2026-04-13-kernel-protocol-stack-deep-dive-ch14-iptables|第十四章：iptables 基础]]
> 15. [[2026-04-13-kernel-protocol-stack-deep-dive-ch15-conntrack|第十五章：连接跟踪 Conntrack]]
> 16. [[2026-04-13-kernel-protocol-stack-deep-dive-ch16-nat|第十六章：NAT 与地址转换]]
> 17. **第十七章：GRE 隧道协议**

---

## 1. 概述：GRE 是什么

GRE（Generic Routing Encapsulation，通用路由封装）是由 Cisco 开发的隧道协议，最早于 1994 年在 RFC 1701 中定义。它可以将任意网络层协议封装在任意其他网络层协议之上，提供了一种通用的隧道机制。

**GRE 的核心特点：**

| 特性 | 说明 |
|------|------|
| 通用性 | 可封装多种协议（IP、IPv6、OSI、DECnet 等） |
| 简单高效 | 头部开销小，仅 4-24 字节 |
| 无加密 | 通常配合 IPsec 使用提供安全性 |
| 点对点隧道 | 需要两端配置相同的隧道参数 |
| 支持键值 | 可选 Key 字段用于隧道标识和认证 |
| 支持校验和 | 可选 Checksum 验证数据完整性 |

---

## 2. GRE 头部结构

### 2.1 基础 GRE 头部（无选项）

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|C| |K|S| Reserved0     | Version |         Protocol Type         |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

| 字段 | 位宽 | 说明 |
|------|------|------|
| C (Checksum) | 1 | 校验和位，1 表示存在 Checksum+Reserved1 |
| K (Key) | 1 | 键值位，1 表示存在 Key 字段 |
| S (Sequence) | 1 | 序列号位，1 表示存在 Sequence Number |
| Reserved0 | 9 | 保留字段，必须为 0 |
| Version | 3 | GRE 版本号，必须为 0 |
| Protocol Type | 16 | 载荷协议类型（Ethernet Type） |

### 2.2 带选项的 GRE 头部

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|C| |K|S| Reserved0     | Version |         Protocol Type         |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|       Reserved1             |        Checksum (optional)       |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|            Key (optional, 32 bits)                            |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|         Sequence Number (optional, 32 bits)                   |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

### 2.3 常见协议类型

| Ethernet Type | 协议 |
|---------------|------|
| 0x0800 | IPv4 |
| 0x86DD | IPv6 |
| 0x6558 | Transparent Ethernet Bridging |
| 0x0200 | XNS IDP |
| 0xF800 | OSI |

### 2.4 内核 GRE 头结构

```c
// include/uapi/linux/if_tunnel.h
struct gre_base_hdr {
    __be16  flags;         // C|K|S|Reserved0
    __be16  protocol;      // Protocol Type
};

#define GRE_HEADER_LEN      4
#define GRE_CSUM            0x8000
#define GRE_KEY             0x2000
#define GRE_SEQ             0x1000
#define GRE_ACK             0x0080  // GRE in PPTP

struct gre_full_hdr {
    struct gre_base_hdr   base;
    __be16               csum;       // 可选
    __be16               reserved1;  // 固定为 0
    __be32               key;       // 可选
    __be32               seq;       // 可选
};
```

---

## 3. GRE 封装与解封装

### 3.1 封装流程（Encapsulation）

```
原始数据包:
+---------------+
|   IP Header   |  (原始目的 IP)
|   Payload     |
+---------------+

经过 GRE 隧道发送:
+---------------+---------------+---------------+
|   IP Header   |   GRE Header  |   Payload     |
|  (隧道端点 IP) |               | (原始 IP 包)  |
+---------------+---------------+---------------+
     外层 IP        GRE 头          原始数据
```

```c
// net/ipv4/gre_offload.c - GRE 封装
int gre_xmit(struct sk_buff *skb, struct net_device *dev)
{
    struct gre_base_hdr *greh;
    struct ip_tunnel *tunnel = netdev_priv(dev);
    __be16 protocol = skb->protocol;
    
    // 1. 准备 GRE 头部
    skb_pull(skb, ETH_HLEN);  // 移除以太网头
    
    greh = skb_push(skb, sizeof(struct gre_base_hdr));
    greh->flags = htons(tunnel->flags);
    greh->protocol = protocol;
    
    // 2. 如果配置了 key，添加 key
    if (tunnel->flags & GRE_KEY) {
        struct gre_full_hdr *full_hdr;
        full_hdr = skb_push(skb, sizeof(__be32));
        full_hdr->key = tunnel->o_key;
    }
    
    // 3. 添加外层 IP 头
    ip_tunnel_xmit(skb, dev, &tunnel->parms.iph);
    
    return NETDEV_TX_OK;
}
```

### 3.2 解封装流程（Decapsulation）

```c
// net/ipv4/gre_offload.c - GRE 接收处理
static struct sk_buff *gre_rcv(struct sk_buff *skb)
{
    struct gre_base_hdr *greh;
    struct gre_full_hdr *full_hdr;
    struct ip_tunnel *tunnel;
    __be16 flags, protocol;
    int hdr_len;
    
    // 1. 解析 GRE 头部
    greh = gre_hdr(skb);
    flags = ntohs(greh->flags);
    protocol = greh->protocol;
    
    // 2. 计算头部总长度
    hdr_len = sizeof(struct gre_base_hdr);
    if (flags & GRE_CSUM) hdr_len += 4;
    if (flags & GRE_KEY)  hdr_len += 4;
    if (flags & GRE_SEQ)  hdr_len += 4;
    
    // 3. 移除 GRE 头部
    skb_pull(skb, hdr_len);
    
    // 4. 根据 protocol 类型分发到对应协议栈
    switch (protocol) {
    case htons(ETH_P_IP):
        ip_protocol_deliver(skb, protocol);
        break;
    case htons(ETH_P_IPV6):
        ip6_protocol_deliver(skb, protocol);
        break;
    }
    
    return NULL;
}
```

### 3.3 数据流图

```mermaid
flowchart LR
    subgraph "隧道入口"
        APP["应用数据"]
        INNER_IP["原始 IP 包"]
        GRE_ENCAP["GRE 封装"]
        OUTER_IP["外层 IP 头"]
    end
    
    subgraph "网络传输"
        INTERNET["Internet"]
    end
    
    subgraph "隧道出口"
        OUTER_IP_R["外层 IP 头"]
        GRE_DECAP["GRE 解封装"]
        INNER_IP_R["原始 IP 包"]
        APP_R["应用数据"]
    end
    
    APP --> INNER_IP --> GRE_ENCAP --> OUTER_IP --> INTERNET
    INTERNET --> OUTER_IP_R --> GRE_DECAP --> INNER_IP_R --> APP_R
```

---

## 4. Linux GRE 配置

### 4.1 创建 GRE 隧道

```bash
# 使用 ip tunnel 创建点对点 GRE 隧道
# 隧道端点 A
ip tunnel add gre0 mode gre remote 10.0.0.2 local 10.0.0.1

# 设置隧道 IP
ip addr add 192.168.100.1/30 dev gre0
ip link set gre0 up

# 端点 B 配置
ip tunnel add gre0 mode gre remote 10.0.0.1 local 10.0.0.2
ip addr add 192.168.100.2/30 dev gre0
ip link set gre0 up

# 验证隧道
ip tunnel show
ip addr show gre0
ping 192.168.100.2
```

### 4.2 GRE over IPv6

```bash
# GRE 隧道 over IPv6
ip -6 tunnel add gre0 mode gre remote 2001:db8::2 local 2001:db8::1 \
    dev eth0
ip -6 addr add 192.168.100.1/64 dev gre0
ip link set gre0 up
```

### 4.3 带 Key 的 GRE 隧道

```bash
# 创建带 key 认证的 GRE 隧道
ip tunnel add gre0 mode gre key 0x12345678 \
    remote 10.0.0.2 local 10.0.0.1

# 查看 key
ip tunnel show gre0
```

### 4.4 查看隧道统计

```bash
# 查看 GRE 隧道接口统计
ip -s tunnel show gre0

# 示例输出
gre0: gre/ip  remote 10.0.0.2  local 10.0.0.1  ttl inherit
    RX: packets    bytes        errors   dropped  overrun   mcast
        1000       102400       0        0        0         0
    TX: packets    bytes        errors   dropped  carrier  coll
        2000       204800       0        0        0        0
```

---

## 5. GRE 与 IP 分片

### 5.1 PMTUD 问题

GRE 封装增加了额外的头部（通常 4-24 字节），可能导致数据包超过 MTU：

```
原始包: 1500 bytes (IP header + payload)
GRE 封装: +20 bytes (外层 IP) + 4-24 bytes (GRE header)
总计: 1524-1544 bytes
```

当封装后的数据包超过 Path MTU 时，会触发 ICMP "Fragmentation Needed" 消息。如果中间路由器或防火墙丢弃了此 ICMP，隧道会 "黑洞"，无法通信。

### 5.2 解决方案

```bash
# 方案 1：设置合理的 MTU
ip link set gre0 mtu 1400

# 方案 2：启用 Path MTU Discovery
sysctl -w net.ipv4.conf.gre0.mtu = 1400

# 方案 3：配置 TCP MSSClamp
iptables -A FORWARD -p tcp --tcp-flags SYN,RST SYN \
    -j TCPMSS --clamp-mss-to-pmtu
```

### 5.3 内核分片处理

```c
// net/ipv4/gre_offload.c - GRE 分片处理
static netdev_tx_t gre_xmit(struct sk_buff *skb, struct net_device *dev)
{
    // 1. 检查 MTU
    if (skb->len > dev->mtu + dev->hard_header_len) {
        // 启用分片
        skb->dev = dev;
        return dev_hard_start_xmit(skb, dev);
    }
    
    // 2. 封装和发送
    gre_xmit2(skb, dev);
    return NETDEV_TX_OK;
}
```

---

## 6. GRE 与 Netfilter

### 6.1 GRE 协议注册

```c
// net/netfilter/nf_conntrack_proto_gre.c
static struct nf_conntrack_l4proto nf_conntrack_gre = {
    .l3proto        = AF_INET,
    .l4proto       = IPPROTO_GRE,
    .name          = "gre",
    
    // GRE 不像 TCP/UDP 有端口，需要特殊处理
    .pkt_to_tuple  = gre_pkt_to_tuple,
    .invert_tuple  = gre_invert_tuple,
    
    // GRE 跟踪需要解析 Key 字段
    .new           = gre_new,
    .packet        = gre_packet,
    .destroy       = gre_destroy,
};
```

### 6.2 iptables 过滤 GRE

```bash
# 允许 GRE 入站（PPTP 服务器场景）
iptables -A INPUT -p gre -j ACCEPT

# 基于 key 过滤 GRE 隧道
iptables -A INPUT -p gre --key 0x12345678 -j ACCEPT
iptables -A INPUT -p gre --key ! 0x12345678 -j DROP

# 基于隧道源/目的过滤
iptables -A INPUT -p gre -s 10.0.0.1 -j ACCEPT
```

---

## 7. GRE 与其他隧道对比

### 7.1 隧道协议对比表

| 特性 | GRE | VXLAN | GENEVE | IPsec Tunnel |
|------|-----|-------|--------|--------------|
| 封装位置 | IP 层 | UDP 层 | UDP 层 | IP 层 |
| 头部开销 | 4-24B | 50B | 40-60B | 50-70B |
| 隧道标识 | 32-bit Key | 24-bit VNI | 24-bit VNI | SPI |
| 组播支持 | 是 | 是 | 是 | 否 |
| 自动发现 | 否 | 否 | 是（OVS） | IKEv2 |
| 硬件卸载 | 有限 | 广泛 | 有限 | 广泛 |
| 标准 | RFC 1701 | RFC 7348 | IETF Draft | RFC 4301 |

### 7.2 典型使用场景

| 场景 | 推荐协议 |
|------|----------|
| 点对点简单隧道 | GRE |
| 跨公网的加密隧道 | GRE + IPsec |
| 数据中心 VXLAN | VXLAN |
| 多租户网络虚拟化 | GENEVE |
| 站点间 VPN | IPsec Tunnel Mode |

---

## 8. 高级配置示例

### 8.1 GRE 隧道路由

```bash
# 通过 GRE 隧道添加默认路由
ip route add default via 192.168.100.2 dev gre0

# 通过 GRE 隧道访问特定网络
ip route add 10.8.0.0/16 via 192.168.100.2 dev gre0
```

### 8.2 GRE 隧道与 bonding

```bash
# 在 bonding 接口上运行 GRE
ip link add bond0 type bond miimon 100 mode active-backup
ip link set eth0 master bond0
ip link set eth1 master bond0
ip link set bond0 up

# 在 bond0 上创建 GRE
ip tunnel add gre0 mode gre remote 10.0.0.2 local 10.0.0.1 \
    dev bond0
```

### 8.3 GRE 隧道监控

```bash
# 使用 ip monitor 监控隧道状态
ip monitor all

# 使用 tcpdump 抓取 GRE 包
tcpdump -i eth0 gre

# 查看 GRE 隧道接口详情
ip -d link show gre0
```

---

## 9. 总结

GRE 是一种轻量级、通用的隧道协议，适合：
- 点对点简单隧道
- 封装多种网络层协议
- 与 IPsec 结合提供加密传输

**关键要点：**
1. GRE 头部结构简单，开销小（4-24 字节）
2. 可选 Key、Sequence、Checksum 提供额外功能
3. 需要注意 MTU 和 PMTUD 问题
4. GRE 本身不加密，通常配合 IPsec 使用
5. Linux 原生支持 `ip tunnel` 命令配置

