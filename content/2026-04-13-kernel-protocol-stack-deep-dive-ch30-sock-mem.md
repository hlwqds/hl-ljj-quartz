---
title: "Kernel Protocol Stack 深度探索 (三十)：Socket 内存管理"
date: 2026-04-13
tags: [linux, kernel, networking, series, sock-mem, sk-mem-allocated, skb-mem-pressure, memory-pressure, slab, vmalloc]
description: "深入解析 Socket 内存管理——sk_buff 内存分配、sk_mem_under_memory_pressure、skb frag list、内存回收机制、slab allocator、vmalloc"
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
> 17. [[2026-04-13-kernel-protocol-stack-deep-dive-ch17-gre|第十七章：GRE 隧道协议]]
> 18. [[2026-04-13-kernel-protocol-stack-deep-dive-ch18-vxlan|第十八章：VXLAN 虚拟可扩展局域网]]
> 19. [[2026-04-13-kernel-protocol-stack-deep-dive-ch19-geneve|第十九章：GENEVE 通用网络虚拟化封装]]
> 20. [[2026-04-13-kernel-protocol-stack-deep-dive-ch20-fib-rules|第二十章：FIB Rules 转发规则]]
> 21. [[2026-04-13-kernel-protocol-stack-deep-dive-ch21-tcp-headers|第二十一章：TCP 头部结构]]
> 22. [[2026-04-13-kernel-protocol-stack-deep-dive-ch22-tcp-states|第二十二章：TCP 状态机]]
> 23. [[2026-04-13-kernel-protocol-stack-deep-dive-ch23-tcp-data-buffer|第二十三章：TCP 数据与缓冲管理]]
> 24. [[2026-04-13-kernel-protocol-stack-deep-dive-ch24-tcp-congestion|第二十四章：TCP 拥塞控制]]
> 25. [[2026-04-13-kernel-protocol-stack-deep-dive-ch25-tcp-advanced|第二十五章：TCP 高级特性]]
> 26. [[2026-04-13-kernel-protocol-stack-deep-dive-ch26-udp|第二十六章：UDP 协议实现]]
> 27. [[2026-04-13-kernel-protocol-stack-deep-dive-ch27-raw-socket|第二十七章：RAW Socket 与 ICMP]]
> 28. [[2026-04-13-kernel-protocol-stack-deep-dive-ch28-socket-api|第二十八章：Socket API 概述]]
> 29. [[2026-04-13-kernel-protocol-stack-deep-dive-ch29-inet-sock|第二十九章：Inet Socket 实现]]
> 30. **第三十章：Socket 内存管理**

---

## 1. 概述

Socket 内存管理是内核网络栈性能的关键因素。每个 socket 都需要内存用于：
- 发送缓冲区：待发送数据
- 接收缓冲区：已接收待读取数据
- 控制结构：sk_buff 元数据、socket 对象本身

Linux 通过 `sk_mem_under_memory_pressure` 机制在内存紧张时主动回收内存。

---

## 2. 内存相关结构

### 2.1 struct sock 中的内存字段

```c
// include/net/sock.h
struct sock {
    // ...
    struct proto           *sk_prot;          // 协议处理
    unsigned long         sk_rcvtimeo;      // 接收超时
    kuid_t                sk_uid;           // 用户 ID

    // 内存管理
    atomic_long_t         sk_rmem_alloc;    // 接收缓冲区已用
    struct sk_buff_head   sk_receive_queue; // 接收队列
    atomic_long_t         sk_wmem_alloc;    // 发送缓冲区已分配
    atomic_long_t         sk_omem_alloc;    // 其他内存
    struct sk_buff_head   sk_write_queue;   // 发送队列
    int                   sk_sndbuf;        // 发送缓冲区大小（sysctl）
    int                   sk_rcvbuf;        // 接收缓冲区大小（sysctl）
    void                  (*sk_memalloc)(void);

    // 内存压力
    int                   sk_wmem_queued;   // 已排队发送字节
    int                   sk_forward_alloc; // 预分配内存
    atomic_t              sk_drops;         // 丢包统计
    int                   sk_route_caps;    // 路由能力
    unsigned long         sk_mem_flags;     // 内存标志
    int                   sk_route_nocaps;  // 路由能力限制
    // ...
};
```

### 2.2 sk_mem_under_memory_pressure

```c
// include/net/sock.h
static inline int sk_mem_under_memory_pressure(struct sock *sk)
{
    return atomic_read(&sk->sk_prot->memory_pressure);
}
```

当 `sk_mem_under_memory_pressure` 为非零值，表示系统内存紧张，socket 应减少内存分配。

---

## 3. Buffer 大小控制

### 3.1 sysctl 参数

```bash
# TCP 发送/接收缓冲区默认值
sysctl net.ipv4.tcp_rmem  # 接收：87380 87380 87380（min default max）
sysctl net.ipv4.tcp_wmem  # 发送：16384 16384 16384（min default max）

# UDP
sysctl net.ipv4.udp_rmem_min  # 默认 4096
sysctl net.ipv4.udp_wmem_min  # 默认 4096

# 全局 socket 内存限制
sysctl net.core.rmem_max  # 最大接收缓冲
sysctl net.core.wmem_max  # 最大发送缓冲
sysctl net.core.rmem_default  # 默认接收缓冲
sysctl net.core.wmem_default  # 默认发送缓冲
```

### 3.2 setsockopt 配置

```c
// 设置接收缓冲区
int rcvbuf = 256 * 1024;  // 256KB
setsockopt(sock, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));

// 获取接收缓冲区（实际值可能比请求值大）
int get_rcvbuf;
socklen_t len = sizeof(get_rcvbuf);
getsockopt(sock, SOL_SOCKET, SO_RCVBUF, &get_rcvbuf, &len);
```

### 3.3 SO_SNDBUF 和 SO_RCVBUF

```c
// net/core/sock.c
int sock_setsockopt(struct sock *sk, int level, int optname,
                    char *optval, int optlen)
{
    case SO_SNDBUF:
        sk->sk_sndbuf = val * 2;  // 内核加倍（用于头部和管理开销）
        break;
    case SO_RCVBUF:
        sk->sk_rcvbuf = val * 2;
        break;
}
```

内核实际分配的缓冲区是用户请求值的 2 倍，因为需要预留 sk_buff 头部和分片管理开销。

---

## 4. sk_buff 内存分配

### 4.1 分配函数

```c
// net/core/skbuff.c
struct sk_buff *alloc_skb(unsigned int size, gfp_t priority)
{
    struct sk_buff *skb;

    // 分配 skb 头部（kmalloc 或 slab）
    skb = kmalloc_node(skb_head_size + size, priority, node);
    if (!skb)
        return NULL;

    // 初始化
    skb->head = skb->data;
    skb->end = size;
    skb->len = 0;
    skb->cloned = 0;
    skb->truesize = size + sizeof(struct sk_buff);

    // 分配数据缓冲区（如果需要）
    if (size > 0) {
        skb_shinfo(skb)->frags[0].page = alloc_page(priority);
        if (!skb_shinfo(skb)->frags[0].page)
            goto no_data;
    }

    return skb;

no_data:
    kfree_skb(skb);
    return NULL;
}

// 分配专用 skb（用于高速路径）
struct sk_buff *alloc_skb_fclone(unsigned int size, gfp_t priority)
{
    // 从 skbuff_fclone_cache 分配（带 clone 标记）
}
```

### 4.2 缓存池

```c
// net/core/skbuff.c
// 专用 slab 缓存用于快速分配
struct kmem_cache *skbuff_head_cache __read_mostly;
struct kmem_cache *skbuff_fclone_cache __read_mostly;

// 初始化
void __init skbuff_init(void)
{
    skbuff_head_cache = KMEM_CACHE(sk_buff, SLAB_HWCACHE_ALIGN);
    skbuff_fclone_cache = KMEM_CACHE(sk_buff_fclone, SLAB_HWCACHE_ALIGN|SLAB_TYPESAFE_BY_RCU);
}
```

### 4.3 __alloc_skb

```c
// net/core/skbuff.c
static struct sk_buff *__alloc_skb(unsigned int size, gfp_t priority,
                                    int clone, int node)
{
    struct sk_buff *skb;

    // 从 slab 缓存分配
    if (clone)
        skb = kmem_cache_alloc_node(skbuff_fclone_cache, priority, node);
    else
        skb = kmem_cache_alloc_node(skbuff_head_cache, priority, node);

    if (!skb)
        return NULL;

    // 预留对齐空间
    skb->head = skb->data = skb->head_frag;
    skb->end = SKB_END_OF(skb_head_frag);
    skb->truesize = SKB_TRUESIZE(size);
    atomic_set(&skb->users, 1);

    return skb;
}
```

---

## 5. 内存回收机制

### 5.1 skb 释放

```c
// net/core/skbuff.c
void kfree_skb(struct sk_buff *skb)
{
    if (atomic_dec_and_test(&skb->users)) {
        if (likely(skb->head))
            __kfree_skb(skb);
    }
}

static void __kfree_skb(struct sk_buff *skb)
{
    // 释放 frag 页面
    skb_release_data(skb);

    // 释放 skb 头部
    kmem_cache_free(skbuff_head_cache, skb);
}

static void skb_release_data(struct sk_buff *skb)
{
    if (skb_shinfo(skb)->frag_list) {
        // 释放 frag list
        kfree_skb(skb_shinfo(skb)->frag_list);
    }

    // 释放页面
    for (int i = 0; i < MAX_SKB_FRAGS; i++) {
        if (skb_shinfo(skb)->frags[i].page)
            put_page(skb_shinfo(skb)->frags[i].page);
    }
}
```

### 5.2 内存压力下的回收

```c
// net/core/sock.c
static int sk_under_memory_pressure(struct sock *sk)
{
    if (atomic_read(&sk->sk_prot->memory_pressure))
        return 1;
    return 0;
}

// 回收 socket 的 forward_alloc
void sk_mem_reclaim(struct sock *sk)
{
    int amount = sk->sk_forward_alloc >> PAGE_SHIFT;

    if (amount > 0) {
        __sk_mem_reclaim(sk, amount);
        sk->sk_forward_alloc -= amount << PAGE_SHIFT;
    }
}

// 网络命名空间的内存压力
void sk_update_memory_pressure(struct net *net, struct sock *sk)
{
    struct proto *prot = sk->sk_prot;

    if (atomic_read(&prot->memory_pressure)) {
        sk_mem_reclaim(sk);
    }
}
```

### 5.3 sk_mem_fraction（内存占比）

每个 socket 有 `sk_mem_fraction` 指定占总内存的比例（分母很大，默认 1/1，即 100%）：

```c
// 减少 socket 发送缓冲区
if (sk_under_memory_pressure(sk))
    sk->sk_sndbuf >>= 1;  // 减半
```

---

## 6. TCP 内存管理

### 6.1 TCP 内存限制

```c
// net/ipv4/tcp_output.c
int tcp_sendmsg(struct sock *sk, struct msghdr *msg, size_t size)
{
    // 检查发送缓冲区空间
    while (size > 0) {
        int copy = min_t(int, size, 
                        min(sk->sk_sndbuf - sk->sk_wmem_queued,
                            MAX_TCP_HEADER));

        if (copy <= 0) {
            // 等待内存
            wait_for_memory(sk, &timeo);
            continue;
        }

        // 分配 skb 并复制数据
        skb = tcp_transmit_skb(sk, copy, &msg->msg_iov, &sg);
        if (skb)
            break;
    }
}
```

### 6.2 tcp_rmem

```c
// net/ipv4/tcp_ipv4.c
struct proto tcp_prot = {
    .name              = "TCP",
    .obj_size          = sizeof(struct tcp_sock),
    .sysctl_mem        = sysctl_tcp_mem,        // 全局 TCP 内存限制
    .sysctl_rmem       = sysctl_tcp_rmem,       // 接收缓冲区限制
    .sysctl_wmem       = sysctl_tcp_wmem,       // 发送缓冲区限制
    .max_header        = MAX_TCP_HEADER,
    .memory_pressure   = &tcp_memory_pressure,
    .enter_memory_pressure = tcp_enter_memory_pressure,
};
```

### 6.3 tcp_memory_pressure

```c
// net/ipv4/tcp_input.c
int tcp_memory_pressure;

void tcp_enter_memory_pressure(struct sock *sk)
{
    if (!tcp_memory_pressure) {
        tcp_memory_pressure = 1;
        // 更新所有 TCP socket 的状态
        for (struct tcp_sock *tp = tcp_sk(sk); tp; tp = tcp_sk(next)) {
            sk_mem_reclaim(sk);
        }
    }
}
```

---

## 7. UDP 内存管理

### 7.1 UDP socket 内存

```c
// net/ipv4/udp.c
struct proto udp_prot = {
    .name           = "UDP",
    .obj_size       = sizeof(struct udp_sock),
    .sysctl_mem     = sysctl_udp_mem,
    .sysctl_rmem    = sysctl_udp_rmem_min,
    .sysctl_wmem    = sysctl_udp_wmem_min,
    .enter_memory_pressure = sk_enter_memory_pressure,
};
```

### 7.2 UDP 接收队列

```c
// net/ipv4/udp.c
static int udp_queue_rcv_skb(struct sock *sk, struct sk_buff *skb)
{
    struct udp_sock *up = udp_sk(sk);

    // 检查内存
    if (atomic_read(&sk->sk_rmem_alloc) > sk->sk_rcvbuf) {
        atomic_inc(&sk->sk_drops);
        return -ENOMEM;
    }

    // 放入接收队列
    skb_set_owner_r(skb, sk);
    __skb_queue_tail(&sk->sk_receive_queue, skb);

    // 唤醒等待进程
    sk->sk_data_ready(sk);

    return 0;
}
```

---

## 8. 内存统计

### 8.1 /proc 接口

```bash
# 查看全局 socket 内存统计
cat /proc/net/sockstat

# 示例输出
sockets: 1234
memory:    123456    (MB allocated)
tcpsmb:    65536    (MB in use)
udpsmb:    16384    (MB in use)
tcpext:    0
```

### 8.2 /proc/net/sockstat

```
sockets: 12345         - 已分配 socket 总数
memory: 655360 KB      - 总内存使用
tcpsmb: 524288 KB     - TCP socket 内存
udpsmb: 131072 KB     - UDP socket 内存
```

### 8.3 ss 命令

```bash
# 查看 socket 内存使用
ss -m

# 示例输出
State      Recv-Q  Send-Q  Local Address:Port   Peer Address:Port
ESTAB      0       0       10.0.0.1:443         10.0.0.2:54321
         skmem:(r0,rb0,t0,tb0,0,0,0,0,0,0,0,0,0,0)
         skmem:(r0,rb0,t0,tb0,0,0,0,0,0,0,0,0,0,0)
```

---

## 9. VMalloc 与 Slab

### 9.1 skb 分配器选择

```c
// net/core/skbuff.c
static inline struct sk_buff *alloc_skb(unsigned int size, gfp_t priority)
{
    struct sk_buff *skb;

    if (size <= SKB_HEAD_SIZE) {
        // 小 buffer：从 per-CPU 缓存分配
        skb = __alloc_skb_from_pool(size, priority);
    } else if (size <= PAGE_SIZE) {
        // 中等 buffer：从 buddy system 分配
        skb = __alloc_skb_page(size, priority);
    } else {
        // 大 buffer：使用 vmalloc
        skb = __alloc_skb_vmalloc(size, priority);
    }
}
```

### 9.2 per-CPU skb 缓存

```c
// net/core/skbuff.c
struct skb_tailwake {
    struct sk_buff  *head;
    struct sk_buff  *tail;
    int              len;
};

DEFINE_PER_CPU(struct skb_tailwake, skb_wake_queue);

// 快速路径：直接从 per-CPU 队列取
static struct sk_buff *skb_dequeue_direct(struct skb_tailwake *q)
{
    struct sk_buff *skb = q->head;
    if (likely(skb)) {
        q->head = skb->next;
        q->len--;
        if (!q->head)
            q->tail = NULL;
        skb->next = NULL;
    }
    return skb;
}
```

### 9.3 Memory reclaim 路径

```
系统内存紧张
    │
    ▼
buddy system 触发 watermark[LOW]
    │
    ▼
try_to_free_pages()
    │
    ├──► shrink_inactive_list()  // 回收页缓存
    │
    ├──► shrink_node_slabs()     // 回收 slab 缓存
    │
    └──► sk_mem_under_memory_pressure = 1  // 通知 socket
              │
              ▼
         减少 socket 缓冲区
         回收 forward_alloc
```

---

## 10. 总结

| 机制 | 说明 |
|------|------|
| sk_rcvbuf/sk_sndbuf | 用户配置的缓冲区大小 |
| sk_rmem_alloc/sk_wmem_alloc | 实际已分配内存 |
| sk_forward_alloc | 预分配内存 |
| sk_mem_under_memory_pressure | 内存压力标志 |
| skb head/cache | slab 缓存分配 |
| vmalloc | 大 buffer 分配 |

Socket 内存管理通过 sysctl 参数、slab 缓存、per-CPU 队列和内存压力回收机制，确保网络栈在内存受限环境下仍能稳定运行。
