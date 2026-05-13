---
title: "Kernel Protocol Stack 深度探索 (二十六)：UDP 协议实现"
date: 2026-04-13
tags:
  [linux, kernel, networking, series, udp, datagram, multicast, broadcast, checksum, pseudo-header]
description: "深入解析 UDP 协议实现——UDP 头部结构、校验和计算、multicast/broadcast、udp_sock 结构、 fragmentation"
---

> [!info] Kernel Protocol Stack 深度探索系列 0. [[2026-04-13-kernel-protocol-stack-deep-dive-series-index|全栈学习路径总览]]
>
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
> 17. [[2026-04-13-kernel-protocol-stack-deep-dive-ch17-gre|第十七章：GRE 隧道协议]]
> 18. [[2026-04-13-kernel-protocol-stack-deep-dive-ch18-vxlan|第十八章：VXLAN 虚拟可扩展局域网]]
> 19. [[2026-04-13-kernel-protocol-stack-deep-dive-ch19-geneve|第十九章：GENEVE 通用网络虚拟化封装]]
> 20. [[2026-04-13-kernel-protocol-stack-deep-dive-ch20-fib-rules|第二十章：FIB Rules 转发规则]]
> 21. [[2026-04-13-kernel-protocol-stack-deep-dive-ch21-tcp-headers|第二十一章：TCP 头部结构]]
> 22. [[2026-04-13-kernel-protocol-stack-deep-dive-ch22-tcp-states|第二十二章：TCP 状态机]]
> 23. [[2026-04-13-kernel-protocol-stack-deep-dive-ch23-tcp-data-buffer|第二十三章：TCP 数据与缓冲管理]]
> 24. [[2026-04-13-kernel-protocol-stack-deep-dive-ch24-tcp-congestion|第二十四章：TCP 拥塞控制]]
> 25. [[2026-04-13-kernel-protocol-stack-deep-dive-ch25-tcp-advanced|第二十五章：TCP 高级特性]]
> 26. **第二十六章：UDP 协议实现**

---

## 1. 概述：UDP 协议

UDP（User Datagram Protocol，用户数据报协议）是无连接的不可靠传输协议，与 TCP 相比：

- 无连接：无需三次握手直接发送数据
- 不可靠：不保证交付，不重传
- 无流量控制：无滑动窗口
- 无拥塞控制：无 cwnd/ssthresh

适用场景：

- DNS 查询（短请求/响应）
- VoIP/视频流（容忍丢包，注重低延迟）
- SNMP、DHCP
- 实时游戏
- QUIC（基于 UDP）

---

## 2. UDP 头部结构

### 2.1 头部格式

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|        Source Port           |      Destination Port         |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|          Length              |           Checksum            |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                             Data                             |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

| 字段             | 位宽 | 说明                    |
| ---------------- | ---- | ----------------------- |
| Source Port      | 16   | 源端口（可选，0=无）    |
| Destination Port | 16   | 目的端口（必填）        |
| Length           | 16   | UDP 头+数据长度（字节） |
| Checksum         | 16   | 校验和（0=未使用）      |

### 2.2 内核结构体

```c
// include/uapi/linux/udp.h
struct udphdr {
    __sum16    source;     // 源端口
    __sum16    dest;       // 目的端口
    __sum16    len;        // 长度
    __sum16    check;      // 校验和
};
```

---

## 3. udp_sock 结构

### 3.1 内核结构

```c
// include/net/udp.h
struct udp_sock {
    struct inet_connection_sock   inet;

    // 接收队列
    struct udp_table __rcu       *udptable;  // 全局 hash 表
    struct sk_buff_head    gorqueue;          // 接收队列（general receive queue）

    // 发送队列
    struct sk_buff_head   write_queue;       // 发送队列

    // 标志位
    int             bound_dev_if;            // 绑定的网卡 index
    u8              no_check6_tx:1;          // IPv6 不发送校验和
    u8              no_check6_rx:1;          // IPv6 不接收校验和
    u8              encap_type:2;            // 封装类型（GTP/UWP）
    u8              pf_after_bind:1;         // 绑定后的协议族

    // multicast
    struct ip_mc_socklist __rcu *mc_list;    // 多播组列表
    struct inet_reuseport *bind_ini;          // reuseport 端口复用
    __u32           mc_ifindex;               // 多播接口 index
    __u32           mc_ttl;                 // 多播 TTL
    __u32           rcv_ttl;                // 接收 TTL
    __u8            mc_loop:1;              // 本地回环
    __u8            recoup:1;               // 内存回收
    __u8            encap_enabled:1;        // 封装启用
};
```

---

## 4. 发送路径

### 4.1 udp_sendmsg

```c
// net/ipv4/udp.c
int udp_sendmsg(struct sock *sk, struct msghdr *msg, size_t len)
{
    struct udp_sock *up = udp_sk(sk);
    struct inet_sock *inet = inet_sk(sk);
    struct udp_datagram_req ureq;
    struct flowi4 fl4;

    // 查找路由
    if (msg->msg_flags & MSG_OOB) {
        // 简化路径
        ipc.opt = rcu_dereference(inet->inet_opt);
        dst = ip_route_newconnect(sk, (union sockaddr *)&usin, len, &fl4);
    } else {
        // 标准路径
        ipc.sockaddr = (union sockaddr *)&usin;
        ipc.addr = inet->inet_saddr;
        ipc.opt = rcu_dereference(inet->inet_opt);

        err = ip_route_output_flow(sock_net(sk), &fl4, sk);
        if (err)
            goto out;
    }

    // 构造 UDP 头
    struct udphdr *uh = skb_push(skb, sizeof(*uh));
    uh->source = inet->inet_sport;
    uh->dest = usin.sin_port;
    uh->len = htons(len + sizeof(struct udphdr));
    uh->check = 0;  // 稍后计算

    // 计算校验和（可选）
    if (sk->sk_no_check_tx == 0) {
        // IPv4：伪头部校验和
        uh->check = udp_csum(fl4.saddr, fl4.daddr, len + sizeof(*uh), skb);
        if (uh->check == 0)
            uh->check = CSUM_MANGLED_0;
    }

    // 发送到 IP 层
    err = ip_send_skb(sock_net(sk), skb);
}
```

### 4.2 校验和计算（伪头部）

```c
// net/ipv4/udp.c
static __sum16 udp_csum(__be32 saddr, __be32 daddr, __u32 len,
                         struct sk_buff *skb)
{
    struct udp_skb_head {
        __sum16 csum;
        __wsum temp;
    } uh;

    // 伪头部
    uh.csum = 0;
    uh.temp = csum_partial(skb->data, len, 0);

    return csum_tcpudp_magic(saddr, daddr, len, IPPROTO_UDP, uh.temp);
}

// 伪头部结构（不实际传输，仅用于校验）
struct pseudo_header {
    __be32  saddr;
    __be32  daddr;
    __u8    zero;
    __u8    protocol;   // IPPROTO_UDP = 17
    __u16   len;         // UDP 长度
} __packed;
```

---

## 5. 接收路径

### 5.1 UDP 数据包接收流程

```
NIC 硬中断
    │
    ▼
IP 层（ip_rcv）
    │
    ▼
UDP 层（udp_rcv）
    │
    ├─► 查找 socket（hash 表 lookup）
    │
    ├─► 校验和验证
    │
    └─► 放入 socket 接收队列
```

### 5.2 udp_rcv

```c
// net/ipv4/udp.c
int udp_rcv(struct sock *sk, struct sk_buff *skb)
{
    struct udp_sock *up = udp_sk(sk);
    struct sock *sk2;
    struct udphdr *uh;
    unsigned short ulen;
    struct rtable *rt;
    bool slow;

    // 查找目的端口对应的 socket
    sk2 = __udp4_lib_lookup(dev_net(skb->dev), ip_hdr(skb)->daddr,
                           uh->dest, ip_hdr(skb)->saddr,
                           uh->source, skb->dev->ifindex,
                           udp_table);

    if (!sk2) {
        // 无 socket 匹配，发送 ICMP Port Unreachable
        icmp_send(skb, ICMP_DEST_UNREACH, ICMP_PORT_UNREACH, 0);
        kfree_skb(skb);
        return 0;
    }

    // 进入 socket 接收路径
    skb_drop_dst(skb);
    skb->dev = NULL;

    return __udp4_lib_rcv(sk, skb, uh->len, udp_table);
}
```

### 5.3 socket 查找

```c
// net/ipv4/udp.c
static inline struct sock *__udp4_lib_lookup(struct net *net,
                                              __be32 saddr, __u16 sport,
                                              __be32 daddr, __u16 dport,
                                              int dif, struct udp_table *h)
{
    struct sock *sk;
    struct hlist_nulls_node *node;

    // udp_table 按 (local_addr, local_port, remote_addr, remote_port) 哈希
    unsigned int hash = udp_hashfn(daddr, dport, saddr, sport);
    unsigned int slot = hash & (h->mask);

    // 遍历 hash 桶
    sk_nulls_for_each_rcu(sk, node, &h->hash[slot]) {
        if (sk->sk_state == UDP_UTUNNEL) {
            // 封装类型（VXLAN/Geneve 等）
            continue;
        }
        if (sk->sk_family == PF_INET &&
            inet_rcv_saddr(sk, daddr) &&
            sk->sk_num == ntohs(dport))
            return sk;
    }

    // 查找失败
    return NULL;
}
```

---

## 6. UDP Socket 特殊标志

### 6.1 UDP_NO_CHECK

```c
// 创建 UDP socket 时禁用校验和
int sock = socket(AF_INET, SOCK_DGRAM, 0);
int no_check = 1;
setsockopt(sock, SOL_SOCKET, UDP_NO_CHECK, &no_check, sizeof(no_check));
```

### 6.2 UDP Segment Offload

```c
// 启用 UDP 分片卸载
int val = 1;
setsockopt(sock, SOL_SOCKET, SO_NO_CHECK, &val, sizeof(val));
// 等价于 setsockopt(sock, IPPROTO_UDP, UDP_NO_CHECK, ...)
```

---

## 7. Broadcast（广播）

### 7.1 广播类型

| 类型               | 地址                  | 说明              |
| ------------------ | --------------------- | ----------------- |
| Limited Broadcast  | 255.255.255.255       | 只在同一 LAN 传播 |
| Directed Broadcast | NetworkID.255.255.255 | 发送到特定网络    |
| Subnet Broadcast   | SubnetID + 全1        | 只在子网内传播    |

### 7.2 绑定广播地址

```c
int sock = socket(AF_INET, SOCK_DGRAM, 0);

// 允许发送广播
int broadcast = 1;
setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &broadcast, sizeof(broadcast));

// 绑定到广播地址
struct sockaddr_in addr;
memset(&addr, 0, sizeof(addr));
addr.sin_family = AF_INET;
addr.sin_addr.s_addr = htonl(INADDR_ANY);  // 或 255.255.255.255
bind(sock, (struct sockaddr *)&addr, sizeof(addr));
```

### 7.3 内核处理

```c
// net/ipv4/udp.c
static int udp_sendmsg(struct sock *sk, struct msghdr *msg, size_t len)
{
    // ...
    if (msg->msg_flags & MSG_BROADCAST) {
        // 设置 SO_BROADCAST 标志
        sk->skbroadcast = 1;
    }

    if (msg->msg_flags & MSG_MULTICAST) {
        // 多播处理
        ip_mc_hold(sk, msg, len);
    }
}
```

---

## 8. Multicast（多播）

### 8.1 多播地址

IPv4 多播地址范围：224.0.0.0 - 239.255.255.255

```
224.0.0.0 - 224.0.0.255：本地链路多播（永不出路由器）
224.0.1.0 - 238.255.255.255：全球范围多播
239.0.0.0 - 239.255.255.255：管理权限多播
```

### 8.2 加入多播组

```c
#include <netinet/in.h>

struct ip_mreq mreq;
mreq.imr_multiaddr.s_addr = inet_addr("239.255.255.250");
mreq.imr_interface.s_addr = htonl(INADDR_ANY);

int sock = socket(AF_INET, SOCK_DGRAM, 0);
setsockopt(sock, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, sizeof(mreq));

// IPv6
struct ipv6_mreq mreq6;
mreq6.ipv6mr_multiaddr = in6addr_addof("ff02::1");
mreq6.ipv6mr_interface = 0;
setsockopt(sock, IPPROTO_IPV6, IPV6_ADD_MEMBERSHIP, &mreq6, sizeof(mreq6));
```

### 8.3 内核实现

```c
// net/ipv4/udp.c
int ip_mc_hold(struct sock *sk, struct msghdr *msg, size_t len)
{
    struct udp_sock *up = udp_sk(sk);
    struct ip_mc_socklist *iml;

    // 分配多播组列表项
    iml = kmalloc(sizeof(*iml), GFP_KERNEL);
    iml->multiaddr = msg->msg_addr;
    iml->ifindex = msg->msg_ifindex;
    iml->sfslot = IP_MC_SF_LAST;

    // 添加到 mc_list
    rcu_assign_pointer(up->mc_list, iml);

    // 更新路由缓存
    ip_mc_inc_group(udp_net(up), msg->msg_addr, msg->msg_ifindex);
}
```

### 8.4 多播路由

```c
// net/ipv4/ipmr.c
int ip_mroute_setsockopt(struct sock *sk, int optname, char *optval, int optlen)
{
    struct mr_table *mrt;

    switch (optname) {
    case MRT_INIT:
        // 初始化多播路由
        break;
    case MRT_ADD_MFC:
        // 添加多播路由条目
        break;
    case MRT_DEL_MFC:
        // 删除多播路由条目
        break;
    }
}
```

---

## 9. UDP 与 IPv6

### 9.1 IPv6 UDP 校验和

IPv6 必须进行校验和验证（IPv4 可选）。

```c
// net/ipv6/udp.c
static inline void udp6_csum(struct sk_buff *skb, struct in6_addr *saddr,
                              struct in6_addr *daddr, __u16 len)
{
    struct udp_skb_head {
        __sum16 csum;
        __wsum temp;
    } uh;

    uh.csum = 0;
    uh.temp = csum_partial(skb->data, len, 0);

    return csum_ipv6_magic(saddr, daddr, len, IPPROTO_UDP, uh.temp);
}
```

### 9.2 UDP-Lite

UDP-Lite（RFC 3828）使用"不完整校验和"，只校验头部和部分数据。

```c
// net/ipv4/udp.c
int udplite_sendmsg(struct sock *sk, struct msghdr *msg, size_t len)
{
    // 类似 udp_sendmsg，但校验和覆盖长度可配置
    struct udp_sock *up = udp_sk(sk);
    up->len = msg->msg_controllen;  // 设置校验覆盖长度
}
```

---

## 10. UDP 封装（Encap）

### 10.1 UDP 封装类型

UDP 常用于隧道协议的传输层：

- VXLAN（UDP 端口 4789）
- Geneve（UDP 端口 6081）
- GENEVE（UDP 封装）
- GTP（GPRS Tunneling Protocol）

### 10.2 内核实现

```c
// net/ipv4/udp.c
static int udp_encap_enable(struct sock *sk)
{
    struct udp_sock *up = udp_sk(sk);

    switch (up->encap_type) {
    case UDP_ENCAP_VXLAN:
        // VXLAN 处理
        break;
    case UDP_ENCAP_GENEVE:
        // Geneve 处理
        break;
    case UDP_ENCAP_GTP:
        // GTP 处理
        break;
    }
}
```

---

## 11. 连接式 UDP（Connected UDP）

### 11.1 connect 对 UDP 的作用

UDP 调用 connect() 不建立连接，而是记录对端地址：

```c
int sock = socket(AF_INET, SOCK_DGRAM, 0);
struct sockaddr_in remote;
remote.sin_family = AF_INET;
remote.sin_port = htons(53);
remote.sin_addr.s_addr = inet_addr("8.8.8.8");

// 连接到 DNS 服务器
connect(sock, (struct sockaddr *)&remote, sizeof(remote));

// 后续 send/recv 不需指定地址
send(sock, query, len, 0);  // 自动使用 connect 的地址
recv(sock, response, sizeof(response), 0);
```

### 11.2 查找已连接 socket

```c
// net/ipv4/udp.c
struct sock *udp4_lib_lookup_conn(struct net *net, __be32 saddr, __be16 sport,
                                   __be32 daddr, __u16 dport)
{
    // 使用 (saddr, sport, daddr, dport) 精确匹配
    unsigned int hash = udp_hashfn(daddr, dport, saddr, sport);
    // 遍历匹配
}
```

---

## 12. /proc 接口

```bash
# 查看 UDP 统计
cat /proc/net/snmp | grep Udp

# 示例输出
Udp: InDatagrams NoPorts InErrors OutDatagrams RcvbufErrors SndbufErrors
Udp: 1234567 23456 0 9876543 0 0

# 查看 UDP socket 详情
cat /proc/net/udp

# 示例输出
 sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode ref pointer drops
  529: 00000000:0035 00000000:0000 0001 00000000:00000000 00:00000000     0 0 12345 0 100000000 2 0000000000000000 0
  785: 0100007F:0035 00000000:0000 0001 00000000:00000000 00:00000000     0 0 54321 0 100000001 2 0000000000000000 0
```

---

## 13. 总结

| 特性       | 说明                 |
| ---------- | -------------------- |
| 无连接     | 直接发送，无需握手   |
| 不可靠     | 无 ACK、无重传       |
| 无流量控制 | 可能丢包、重复       |
| 校验和     | IPv4 可选，IPv6 必选 |
| Broadcast  | 255.255.255.255      |
| Multicast  | 224.0.0.0/4 组播地址 |
| 封装       | VXLAN/Geneve/GTP     |

UDP 是许多重要协议的基础（DNS、QUIC、视频流），在内核网络栈中扮演关键角色。
