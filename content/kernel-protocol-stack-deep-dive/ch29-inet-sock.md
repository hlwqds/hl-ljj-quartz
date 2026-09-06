---
title: "Kernel Protocol Stack 深度探索 (二十九)：Inet Socket 实现"
date: 2026-04-13
tags:
  [
    linux,
    kernel,
    networking,
    series,
    inet_sock,
    inet_connection_sock,
    struct sock,
    port-binding,
    reuseport,
    hash-table,
  ]
description: "深入解析 Inet Socket 内核实现——inet_sock 结构、inet_connection_sock、端口绑定、reuseport、ehash/bhash/ioremap hash 表"
---

> [!info] Kernel Protocol Stack 深度探索系列 0. [[kernel-protocol-stack-deep-dive|全栈学习路径总览]]
>
> 1. [[ch1-skbuff|第一章：sk_buff 与数据包生命周期]]
> 2. [[ch2-netdevice|第二章：Netdevice 与网卡抽象]]
> 3. [[ch3-ring-buffer|第三章：Ring Buffer 与 DMA]]
> 4. [[ch4-softirq|第四章：软中断与 ksoftirqd]]
> 5. [[ch5-napi|第五章：NAPI 与轮询模式]]
> 6. [[ch6-ethernet|第六章：Ethernet 与 MAC 层]]
> 7. [[ch7-bridge|第七章：网桥与 Switchdev]]
> 8. [[ch8-vlan|第八章：VLAN 与 802.1Q]]
> 9. [[ch9-macvlan|第九章：MACVLAN 与虚拟网卡]]
> 10. [[ch10-bonding|第十章：Bonding 与 teamd]]
> 11. [[ch11-ip-framing|第十一章：IP 协议封装]]
> 12. [[ch12-routing|第十二章：路由与 FIB]]
> 13. [[ch13-neighbor|第十三章：Neighbor 与 ARP]]
> 14. [[ch14-iptables|第十四章：iptables 基础]]
> 15. [[ch15-conntrack|第十五章：连接跟踪 Conntrack]]
> 16. [[ch16-nat|第十六章：NAT 与地址转换]]
> 17. [[ch17-gre|第十七章：GRE 隧道协议]]
> 18. [[ch18-vxlan|第十八章：VXLAN 虚拟可扩展局域网]]
> 19. [[ch19-geneve|第十九章：GENEVE 通用网络虚拟化封装]]
> 20. [[ch20-fib-rules|第二十章：FIB Rules 转发规则]]
> 21. [[ch21-tcp-headers|第二十一章：TCP 头部结构]]
> 22. [[ch22-tcp-states|第二十二章：TCP 状态机]]
> 23. [[ch23-tcp-data-buffer|第二十三章：TCP 数据与缓冲管理]]
> 24. [[ch24-tcp-congestion|第二十四章：TCP 拥塞控制]]
> 25. [[ch25-tcp-advanced|第二十五章：TCP 高级特性]]
> 26. [[ch26-udp|第二十六章：UDP 协议实现]]
> 27. [[ch27-raw-socket|第二十七章：RAW Socket 与 ICMP]]
> 28. [[ch28-socket-api|第二十八章：Socket API 概述]]
> 29. **第二十九章：Inet Socket 实现**

---

## 1. 概述

每个 IPv4 TCP/UDP socket 在内核中都用 `struct sock` 表示，并附加 inet 特定的字段形成 `struct inet_sock`。理解 `inet_sock` 的内存布局对于掌握端口绑定、hash 表查找、reuseport 等核心机制至关重要。

---

## 2. Socket 结构层次

### 2.1 从 sock 到 inet_sock

```
struct sock (通用 socket)
    │
    ├── struct inet_connection_sock (TCP 面向连接)
    │       │
    │       └── struct tcp_sock (TCP 具体实现)
    │
    ├── struct inet_sock (IPv4 特定)
    │       │
    │       └── struct udp_sock (UDP 具体实现)
    │
    └── 其他协议族（ipv6/unix）
```

### 2.2 inet_sock 结构

```c
// include/net/inet_sock.h
struct inet_sock {
    struct sock     sk;              // 基础 sock

#if defined(CONFIG_IP_MROUTE) || defined(CONFIG_IP_MROUTE_MODULE)
    struct ip_mc_socklist __rcu *mc_list;    // 多播组列表
    struct inet_vf_info __rcu *vf;           // VRF
#endif

    // 本地地址/端口
    __be32          inet_saddr;      // 源 IP 地址
    __be16          inet_sport;      // 源端口

    // 目的地址/端口
    __be32          inet_daddr;      // 目的 IP 地址
    __be16          inet_dport;      // 目的端口

    // IP 选项
    struct ip_options_rcu __rcu *inet_opt;   // IP 选项
    int             inet_num;        // 协议号

    // 服务类型
    __u8            inet_tos;        // Type of Service
    __u8            inet_ttl;        // TTL

    // 分片
    __u16           inet_id;         // IP ID 字段

    // 接收/发送分片队列
    struct inet_peer __rcu *inet_peer;       // 对方信息（用于分片重组）
    unsigned long   inet_rx_cookie;  // 接收 cookie

    // 地址混淆（用于透明代理）
    __be32          inet_saddr_orig;  // 原始源地址
    __u8            inet_rcv_saddr;  // 接收地址
    __u8            inet_snd_saddr;  // 发送地址

    // 分片标记
    __u16           inet_freebind;   // 空闲绑定
    __u16           inet_hopopts;    // 跳跃选项
    __u8            inet_is_local;   // 本地地址

    // 校验和
    __u16           transparent;      // 透明代理
    __u16           mc_loop;         // 多播回环
    __u16           mc_index;        // 多播接口索引
    __be32          mc_addr;         // 多播地址
};
```

### 2.3 inet_connection_sock 结构

```c
// include/net/inet_connection_sock.h
struct inet_connection_sock {
    struct inet_sock     icsk_inet;      // 嵌入的 inet_sock

    // TCP 特定
    struct inet_connection_sock_afinfo *icsk_af_ops; // 地址族操作
    struct request_sock_queue __aligned(8)icsk_queue; // 半连接/全连接队列
    struct inet_cork      icsk_cork;     // 挂起的调用

    // 重传定时器
    struct timer_list     icsk_retransmit_timer;
    struct timer_list     icsk_delack_timer;

    // 拥塞控制
    const struct tcp_congestion_ops *icsk_ca_ops;
    struct tcp_congestion_ops __rcu *icsk_ca_unclone_ops;
    void                (*icsk_ca_state)(struct sock *, const struct sk_buff *);
    void                (*icsk_ca_event)(struct sock *, enum tcp_ca_event);

    // RTT 估计
    u32                 icsk_ca_priv[16];
    u32                 icsk_mtup;      // Path MTU Discovery
    u32                 icsk_mtup_reordering;  // 分片重排序
    u32                 icsk_probes_out;  // keepalive 探测次数
    u32                 icsk_probes_tstamp; // 探测时间戳

    // RTO（Retransmission Timeout）
    unsigned long        icsk_timeout;
    __u8                icsk_ca_dst_locked; // 目标锁定
};
```

---

## 3. 端口绑定（Port Binding）

### 3.1 端口查找

当数据包到达时，内核需要根据 (proto, local_ip, local_port, remote_ip, remote_port) 找到对应的 socket。

```c
// net/ipv4/inet_hashtables.c
static inline struct sock *__inet4_lookup(struct net *net,
                                           struct hlist_nulls_head *list,
                                           struct sk_buff *skb, int doff,
                                           __be32 saddr, __be16 sport,
                                           __be32 daddr, __be16 dport,
                                           int dif, int sdif,
                                           struct sock *sk)
{
    struct sock *sk_result;

    // 遍历 hash 桶
    sk_nulls_for_each_rcu(sk, node, list) {
        if (sk->sk_family != PF_INET)
            continue;
        if (sk->sk_num != ntohs(dport))
            continue;
        if (sk->sk_rcv_saddr && sk->sk_rcv_saddr != daddr)
            continue;
        if (!skb->dev || !(sk->sk_bound_dev_if) ||
            sk->sk_bound_dev_if == dif ||
            sk->sk_bound_dev_if == sdif)
            sk_result = sk;
    }

    return sk_result;
}
```

### 3.2 SO_REUSEADDR

允许绑定到已存在的地址（即使 TIME_WAIT）：

```c
// net/core/sock.c
int sock_setsockopt(struct sock *sk, int level, int optname,
                     char *optval, int optlen)
{
    case SO_REUSEADDR:
        sk->sk_reuse = !!val;
        break;
}
```

### 3.3 SO_REUSEPORT

允许多个 socket 绑定到同一端口，内核通过 hash 实现负载均衡：

```c
struct sock_reuseport {
    struct hlist_nulls_head    hlist;     // 同一端口的所有 socket
    spinlock_t                 lock;
    int                        max_socks;  // 最大 socket 数
    int                        num_socks;  // 当前 socket 数
    struct bpf_prog_array __rcu *prog;    // BPF 选择器
};
```

### 3.4 内核 hash 表结构

```
TCP/UDP hash 表：
┌─────────────────────────────────────────────────────┐
│                  ehash (established connections)    │
│  slot: [sock1] ──► [sock2] ──► NULL               │
│  slot: [sock3] ──► NULL                            │
├─────────────────────────────────────────────────────┤
│                  bhash (bound sockets)               │
│  slot: [sock:port 80] ──► [sock:port 8080] ──► NULL│
├─────────────────────────────────────────────────────┤
│                  ioremap (IPv4 only)                │
│  slot: [sock:port 8000] ──► NULL                    │
└─────────────────────────────────────────────────────┘
```

---

## 4. TCP Socket 监听与accept

### 4.1 监听队列

```c
// include/net/inet_connection_sock.h
struct request_sock_queue {
    struct request_sock *rskq_accept_head;    // accept 队列头
    struct request_sock *rskq_accept_tail;    // accept 队列尾
    struct fastopen_queue *fastopenq;          // Fast Open 队列
    u8                      rskq_racing:1;    // 竞争标志
};
```

### 4.2 listen() 流程

```c
// net/ipv4/inet_stream.c
int inet_listen(struct socket *sock, int backlog)
{
    struct sock *sk = sock->sk;

    // 检查状态
    if (sk->sk_state != TCP_CLOSE)
        return -EISCONN;

    // 设置 backlog
    sk->sk_max_backlog = backlog;
    sk->sk_state = TCP_LISTEN;

    // 分配端口（如果尚未绑定）
    if (!inet_rcv_saddr(sk, 0))
        inet_bind_hash(sk);

    return 0;
}
```

### 4.3 accept() 流程

```c
// net/ipv4/inet_stream.c
struct sock *inet_accept(struct sock *sk, int flags, int *err)
{
    struct sock *newsk;
    struct connection_request *req;

    // 从 accept 队列取一个已完成连接
    newsk = inet_csk_reqsk_queue_remove(sk, NULL, req, flags);
    if (!newsk)
        return NULL;

    // 如果是半连接队列请求，转移到全连接队列
    req = reqsk_queue_remove(sk, &req, &newsk);
    return newsk;
}
```

---

## 5. Socket Hash 查找

### 5.1 TCP ESTABLISHED 查找

```c
// net/ipv4/inet_hashtables.c
static inline struct sock *__inet4_lookup_established(...)
{
    struct inet_ehash_bucket *head;
    u32 port, saddr, daddr;
    u16 sport, dport;

    port = ntohs(dport);
    saddr = saddr; daddr = daddr;
    sport = ntohs(sport);

    // 计算 hash 槽
    unsigned int hash = inet_ehashfn(daddr, dport, saddr, sport,
                                     net_hash_mix(net));
    head = &tcp_hashinfo.ehash[hash & (tcp_hashinfo.ehash_mask)];

    // 遍历桶
    sk_nulls_for_each_rcu(sk, node, &head->chain) {
        if (sk->sk_hash != hash)
            continue;
        if (sk->sk_family != PF_INET)
            continue;
        // 检查地址/端口匹配
        if (sk->sk_daddr != daddr || sk->sk_dport != dport)
            continue;
        if (sk->sk_rcv_saddr != saddr && sk->sk_rcv_saddr)
            continue;
        // 匹配！
    }
}
```

### 5.2 UDP 查找

```c
// net/ipv4/udp.c
static inline struct sock *__udp4_lib_lookup(...)
{
    unsigned int hash = udp_hashfn(daddr, dport, saddr, sport);
    struct hlist_nulls_head *h = &udptable->hash[hash & udptable->mask];

    sk_nulls_for_each_rcu(sk, node, h) {
        if (sk->sk_num != ntohs(dport))
            continue;
        if (sk->sk_rcv_saddr && sk->sk_rcv_saddr != daddr)
            continue;
        if (sk->sk_family == AF_INET &&
            inet_rcv_saddr(sk, saddr))
            return sk;
    }
}
```

---

## 6. sk_port 端口选择

### 6.1 自动端口分配

当应用程序 bind() 时 port=0，内核自动分配一个可用端口：

```c
// net/ipv4/inet_csk.c
int inet_csk_get_port(struct sock *sk, unsigned short snum)
{
    struct inet_hashinfo *hinfo = sk->sk_prot->h.hashinfo;
    struct inet_bind_hashbucket *head;
    struct inet_bind_bucket *tb;

    // 查找已有端口或分配新桶
    if (!snum) {
        int low = sysctl_local_port_range[0];
        int high = sysctl_local_port_range[1];

        for (snum = low; snum <= high; snum++) {
            if (inet_is_local_reserved_port(snum))
                continue;
            head = &hinfo->bhash[inet_bind_bucketno(snum)];
            // 检查端口是否可用
        }
    }
}
```

### 6.2 sysctl 端口范围

```bash
# 本地端口分配范围
cat /proc/sys/net/ipv4/ip_local_port_range
# 输出：32768 60999

# 修改范围
sysctl -w net.ipv4.ip_local_port_range="10000 65535"
```

---

## 7. Socket 状态转换

### 7.1 TCP 状态机

```
TCP_CLOSE
    │
    │ connect()
    ▼
TCP_SYN_SENT ────────────────────────────────► TCP_SYN_RECV
    │                                              │
    │◄────────────────────────────────────────     │
    │              SYNACK                          │
    │                                              │
    │              accept()                        ▼
    ▼                                      TCP_ESTABLISHED
TCP_CLOSE_WAIT ◄───────────────────────────► TCP_ESTABLISHED
    │                                              │
    │ close()                                     │ close()
    ▼                                              ▼
TCP_FIN_WAIT1 ◄───────────────────────────► TCP_CLOSE_WAIT
    │              FIN                              │
    ▼                                              ▼
TCP_CLOSING ◄───────────────────────────► TCP_LAST_ACK
    │              ACK
    ▼
TCP_TIME_WAIT ──► (2MSL) ──► TCP_CLOSE
```

### 7.2 状态查看

```bash
# ss -s 显示 socket 统计
# ss -t 显示 TCP socket
# ss -u 显示 UDP socket

# 示例
ss -t state established
```

---

## 8. 总结

| 结构                        | 说明             |
| --------------------------- | ---------------- |
| struct sock                 | 基础 socket 结构 |
| struct inet_sock            | IPv4 特定字段    |
| struct inet_connection_sock | TCP 面向连接扩展 |
| struct tcp_sock             | TCP 具体实现     |
| struct udp_sock             | UDP 具体实现     |

端口绑定通过 hash 表高效查找，SO_REUSEADDR 和 SO_REUSEPORT 提供了灵活的端口复用机制。
