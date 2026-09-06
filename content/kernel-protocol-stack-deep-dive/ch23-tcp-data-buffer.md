---
title: "Kernel Protocol Stack 深度探索 (二十三)：TCP 数据与缓冲管理"
date: 2026-04-13
tags:
  [
    linux,
    kernel,
    networking,
    series,
    tcp,
    buffer,
    socket-buffer,
    receive-window,
    send-buffer,
    zero-copy,
  ]
description: "深入解析 TCP 数据缓冲管理——sk_buff 在 TCP 中的使用、发送/接收缓冲区、滑动窗口、拥塞控制数据结构、zero-copy 优化"
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
> 23. **第二十三章：TCP 数据与缓冲管理**

---

## 1. 概述：TCP 缓冲管理

TCP 在内核中使用 sk_buff 管理数据缓冲，实现：

- 发送数据缓冲：存储待发送的应用数据
- 接收数据缓冲：存储已接收待交付应用的数据
- 滑动窗口：控制数据流速
- 拥塞控制：防止网络过载

---

## 2. TCP Socket 结构

### 2.1 tcp_sock 核心字段

```c
// include/linux/tcp.h
struct tcp_sock {
    struct inet_connection_sock   inet_conn;

    // 序列号相关
    __u32   snd_nxt;              // 下一个要发送的序列号
    __u32   snd_una;              // 最早未确认的序列号
    __u32   snd_wnd;              // 发送窗口大小
    __u32   rcv_nxt;              // 下一个期望接收的序列号
    __u32   rcv_wnd;              // 接收窗口大小

    // 发送缓冲区
    struct {
        struct rb_root           out_of_order_queue;  // 乱序队列
        struct sk_buff_head      send_head;            // 发送队列
        int                      nonagle;              // Nagle 算法状态
    } tcp;

    // 带宽估计
    __u32   srtt;                 // 平滑 RTT
    __u32   mdev;                 // RTT 偏差
    __u32   mdev_max;             // 最大 RTT 偏差
    __u32   rttvar;               // RTT 方差

    // 拥塞控制
    u32     snd_cwnd;             // 拥塞窗口
    u32     snd_ssthresh;         // 慢启动阈值
    u32     bytes_acked;          // 已确认字节
    u32     bytes_received;       // 已接收字节
};
```

### 2.2 发送缓冲区结构

```c
// 发送队列（按序列号排序）
struct {
    struct sk_buff *head;        // 发送队列头
    int            len;          // 队列长度（字节）
    int            seq;          // 下一个序列号
} write_queue;

// 等待确认的段
struct sk_buff *tcp_send_head;

// 重新传输队列
struct sk_buff *tcp_retransmit_head;
```

### 2.3 接收缓冲区结构

```c
// 接收队列（已排序，按序列号）
struct {
    struct sk_buff *head;       // 接收队列头
    int             len;         // 队列长度（字节）
    struct sk_buff *next;        // 下一个要交付的包
} receive_queue;

// 乱序队列（Out-of-Order）
struct rb_root   out_of_order_queue;

// 紧急数据
struct {
    __u8    urgent_mode;         // URG 模式
    __u32   urgent_data;         // 紧急数据
} urgent;
```

---

## 3. 发送数据流程

### 3.1 应用数据到 sk_buff

```c
// net/ipv4/tcp.c - 发送数据
int tcp_sendmsg(struct sock *sk, struct msghdr *msg, size_t size)
{
    struct tcp_sock *tp = tcp_sk(sk);
    struct sk_buff *skb;
    int frag_size, copied = 0;

    while (msg->msg_iovlen > 0) {
        // 1. 获取要发送的数据
        struct iovec *iov = msg->msg_iov;
        size_t len = iov->iov_len;

        // 2. 查找或创建 sk_buff
        skb = tcp_write_queue_tail(sk);
        if (!skb || skb_has_frag_list(skb)) {
            // 需要新分配 skb
            skb = alloc_skb_fclone(len + MAX_TCP_HEADER, sk->sk_allocation);
            tcp_init_nondata_skb(skb, tp->write_seq, TCPHDR_ACK | TCPHDR_PSH);
            skb_entail(sk, skb);
        }

        // 3. 复制数据到 skb
        frag_size = min(len, skb_sh页可用(skb));
        if (copy_from_iter_full(skb_put(skb, frag_size), frag_size, &msg->msg_iter))
            copied += frag_size;
    }

    // 4. 触发发送
    tcp_push(sk, tp, flags, tp->write_seq - tp->snd_nxt, tp->mss_cache, tp->nonagle);

    return copied;
}
```

### 3.2 TCP 头部构建

```c
// net/ipv4/tcp_output.c - 构建 TCP 头
static int tcp_transmit_skb(struct sock *sk, struct sk_buff *skb, int clone_it,
                             gfp_t gfp_mask)
{
    struct tcp_sock *tp = tcp_sk(sk);
    struct tcphdr *th;

    // 1. 确保 skb 有足够空间
    skb_push(skb, sizeof(*th));
    skb_reset_transport_header(skb);

    // 2. 构建 TCP 头
    th = tcp_hdr(skb);
    th->source      = htons(sk->sk_num);
    th->dest        = htons(sk->sk_dport);
    th->seq         = htonl(tp->write_seq);
    th->ack_seq     = htonl(tp->rcv_nxt);
    th->window      = htons(tp->rcv_wnd);
    th->check       = 0;

    // 3. 设置 flags
    th->fin         = flags & TCPHDR_FIN;
    th->syn         = flags & TCPHDR_SYN;
    th->rst         = flags & TCPHDR_RST;
    th->psh         = flags & TCPHDR_PSH;
    th->ack         = flags & TCPHDR_ACK;
    th->urg         = flags & TCPHDR_URG;

    // 4. 计算校验和
    th->check = tcp_v4_check(skb->len, sk->sk_rcv_saddr,
                              sk->sk_daddr, csum_partial(th, th->doff * 4, 0));

    // 5. 发送
    return ip_queue_xmit(skb, &inet_sk(sk)->cork.fl);
}
```

### 3.3 数据发送流程图

```
应用层 write()
    |
    v
用户缓冲区 -> copy_to_sk() -> sk_buff (send queue)
    |
    v
tcp_push() -> 添加 TCP 头
    |
    v
ip_queue_xmit() -> 添加 IP 头
    |
    v
网卡驱动 -> DMA 发送
```

---

## 4. 接收数据流程

### 4.1 sk_buff 接收

```c
// net/ipv4/tcp_ipv4.c - TCP 接收入口
int tcp_v4_rcv(struct sk_buff *skb)
{
    struct sock *sk;

    // 1. 验证 TCP 头
    if (!tcp_v4_checksum_init(skb))
        goto discard;

    // 2. 查找对应的 socket
    sk = __inet_lookup_skb(&tcp_hashinfo, skb, th->source, th->dest);
    if (!sk)
        goto no_tcp_socket;

    // 3. 处理 TIME_WAIT
    if (sk->sk_state == TCP_TIME_WAIT)
        return tcp_timewait_state_process(sk, skb, th);

    // 4. 放入接收队列
    if (sk->sk_state == TCP_LISTEN) {
        // 监听 socket，交给 accept()
    } else {
        tcp_v4_do_rcv(sk, skb);
    }

    return 0;
}
```

### 4.2 数据包处理

```c
// net/ipv4/tcp_input.c - 数据包处理
static int tcp_rcv_established(struct sock *sk, struct sk_buff *skb)
{
    struct tcp_sock *tp = tcp_sk(sk);
    struct tcphdr *th = tcp_hdr(skb);
    int len = skb->len;
    u32 seq = ntohl(th->seq);
    u32 ack = ntohl(th->ack_seq);

    // 1. 更新 RTT
    if (th->ack && tp->lsndtime)
        tcp_ack_update_rtt(sk, ack, seq);

    // 2. 检查序列号
    if (seq != tp->rcv_nxt)
        goto out_of_order;

    // 3. 检查窗口
    if (th->window != tp->rcv_wnd)
        tcp_rcv_space_adjust(sk);

    // 4. 交付应用数据
    if (skb->len > 0) {
        __skb_pull(skb, th->doff * 4);
        tcp_queue_rcv(sk, skb, &tp->ucopy.task);
    }

    // 5. 发送 ACK
    tcp_send_ack(sk);

    return 0;

out_of_order:
    // 放入乱序队列
    tcp_data_queue(sk, skb);
}
```

### 4.3 乱序包处理

```c
// 乱序包处理
static void tcp_data_queue(struct sock *sk, struct sk_buff *skb)
{
    struct tcp_sock *tp = tcp_sk(sk);
    struct rb_node **p, *parent;
    int seq = TCP_SKB_CB(skb)->seq;

    // 检查是否可以合并
    if (tcp_try_coalesce(sk, tp->receive_queue.prev, skb)) {
        kfree_skb(skb);
        return;
    }

    // 插入红黑树（按序列号排序）
    p = &tp->out_of_order_queue.rb_node;
    while (*p) {
        struct sk_buff *cur = rb_entry(*p, struct sk_buff, rbnode);
        if (seq < TCP_SKB_CB(cur)->seq)
            p = &(*p)->rb_left;
        else
            p = &(*p)->rb_right;
    }
    rb_link_node(&skb->rbnode, parent, p);
    rb_insert_color(&skb->rbnode, &tp->out_of_order_queue);

    // 尝试交付已排序的数据
    tcp_rcv_nxt_update(sk, tp->rcv_nxt);
}
```

---

## 5. 滑动窗口

### 5.1 窗口结构

```
发送方视角：
|------------|-----------|------------------------|
0         snd_una      snd_nxt                   snd_max
           |           |                           |
           |   已发送未确认  |   可发送（窗口内）         |  不能发送（窗口外）

接收方视角：
|------------------|------------------------------|
0               rcv_nxt                     rcv_nxt + rcv_wnd
                 |                                 |
                 | 已接收已交付    | 可接收（窗口内）     | 不能接收
```

### 5.2 窗口更新

```c
// 接收窗口更新
static void tcp_rcv_space_adjust(struct sock *sk)
{
    struct tcp_sock *tp = tcp_sk(sk);
    int rcv_wnd;

    rcv_wnd = (tp->rcv_wq.wmem_queued - tp->rcv_qlen) ?: tp->rcv_wnd;

    // 更新通告窗口
    if (rcv_wnd > tp->rcv_wnd) {
        tp->rcv_wnd = rcv_wnd;
        tcp_send_ack(sk);  // 立即发送窗口更新
    }
}
```

### 5.3 零窗口

```c
// 接收缓冲区满，发送零窗口
if (sk->sk_rcvbuf <= sk->sk_rcv_qlen) {
    tp->rcv_wnd = 0;
    tcp_send_ack(sk);
}

// 发送方收到零窗口后停止发送
if (th->window == 0) {
    tp->snd_wnd = 0;
    // 启动零窗口探测定时器
    inet_csk_reset_xmit_timer(sk, ICSK_TIME_PROBE0, ...);
}
```

---

## 6. 拥塞控制数据结构

### 6.1 拥塞窗口

```c
// include/linux/tcp.h
struct tcp_sock {
    // 拥塞控制相关
    u32     snd_cwnd;             // 拥塞窗口大小
    u32     snd_cwnd_cnt;         // 窗口内已发送字节
    u32     snd_cwnd_clamp;       // 窗口上限
    u32     snd_ssthresh;         // 慢启动阈值

    // 快速恢复相关
    u32     high_seq;             // 最高发送序列号
    u32     retrans_stamp;        // 重传时间戳
    u32     undo_marker;          // 恢复点标记

    // RTT 相关
    u32     srtt;                 // 平滑 RTT
    u32     mdev;                 // RTT 偏差
    u32     mdev_max;             // 最大 RTT 偏差
    u32     rttvar;               // RTT 方差
    u32     rtt_seq;              // RTT 采样序列号

    // 带宽估计
    u32     snd_bw;               // 估计带宽
    u32     snd_bw_est;          // 平滑带宽
};
```

### 6.2 拥塞控制算法接口

```c
// net/ipv4/tcp_cong.c
struct tcp_congestion_ops {
    char            name[TCP_CA_NAME_MAX];

    // 初始化
    void (*init)(struct sock *sk);

    // 清理
    void (*release)(struct sock *sk);

    // 慢启动
    u32  (*ssthresh)(struct sock *sk);

    // 拥塞避免
    void (*cong_avoid)(struct sock *sk, u32 ack, u32 acked);

    // 重传超时
    u32  (*recalc_ssthresh)(struct sock *sk);

    // 处理 ACK
    void (*state)(struct sock *sk, u8 new_state);

    // 取消拥塞
    void (*undo_cwnd)(struct sock *sk);

    // CWR 状态
    void (*cwnd_event)(struct sock *sk, enum tcp_ca_event ev);

    // 带宽采样
    u32  (*bkup_sa)(const struct sock *sk);
    u32  (*bkup_sk)(const struct sock *sk);
};
```

### 6.3 常用算法

```bash
# 查看可用拥塞控制算法
sysctl net.ipv4.tcp_available_congestion_control

# 示例输出：cubic reno

# 查看当前算法
sysctl net.ipv4.tcp_congestion_control

# 切换算法
sysctl -w net.ipv4.tcp_congestion_control=cubic
```

---

## 7. Socket 缓冲区调优

### 7.1 缓冲区大小

```bash
# 查看当前缓冲区大小
ss -tm

# 发送缓冲区
sysctl net.ipv4.tcp_wmem
# 格式：min default max
# 默认：4096 16384 4194304

# 接收缓冲区
sysctl net.ipv4.tcp_rmem
# 格式：min default max
# 默认：4096 131072 6291456

# 全局最大
sysctl net.core.rmem_max
sysctl net.core.wmem_max
```

### 7.2 自动调优

```bash
# 启用自动调优
sysctl -w net.ipv4.tcp_moderate_rcvbuf=1

# 读取当前值
cat /proc/sys/net/ipv4/tcp_moderate_rcvbuf
```

### 7.3 手动设置

```bash
# 为特定连接设置缓冲区
# 使用 setsockopt
# SO_RCVBUF 和 SO_SNDBUF

# 示例：设置 4MB 缓冲区
echo 4194304 > /proc/sys/net/core/rmem_default
echo 4194304 > /proc/sys/net/core/wmem_default

# 限制单连接最大缓冲区
echo 16777216 > /proc/sys/net/core/rmem_max
echo 16777216 > /proc/sys/net/core/wmem_max
```

---

## 8. Zero-Copy 优化

### 8.1 sendfile 与 TCP

```c
// 使用 sendfile 实现零拷贝
// 用户空间不直接访问数据
#include <sys/sendfile.h>

int fd = open("file", O_RDONLY);
sendfile(socket_fd, fd, NULL, file_size);

// 内核路径：file -> page cache -> socket buffer -> NIC
// 避免了 user space copy
```

### 8.2 splice 与 TCP

```c
// 使用 splice 实现零拷贝
int pipefd[2];
pipe(pipefd);

// 文件到管道
splice(fd, NULL, pipefd[1], NULL, size, SPLICE_F_MOVE);

// 管道到 socket
splice(pipefd[0], NULL, sockfd, NULL, size, SPLICE_F_MOVE);
```

### 8.3 MSG_ZEROCOPY

```c
// 内核 4.18+ 支持 MSG_ZEROCOPY
int sockfd = socket(AF_INET, SOCK_STREAM, 0);

// 启用 zerocopy
int val = 1;
setsockopt(sockfd, SOL_SOCKET, SO_ZEROCOPY, &val, sizeof(val));

// 发送时使用 MSG_ZEROCOPY
sendto(sockfd, buf, len, MSG_ZEROCOPY, ...);

// 等待通知
struct sock_extended_err *ee;
recvmsg(sockfd, &msg, MSG_ERRQUEUE);
```

### 8.4 page flip vs DMA

```
传统方式：
  Disk -> DMA -> RAM -> CPU copy -> RAM -> DMA -> NIC
                    (消耗 CPU)

Zero-copy 方式：
  Disk -> DMA -> RAM -> DMA -> NIC
                    (无 CPU 参与)
```

---

## 9. 重传管理

### 9.1 超时重传

```c
// net/ipv4/tcp_timer.c - 重传超时
static void tcp_retransmit_timer(struct sock *sk)
{
    struct tcp_sock *tp = tcp_sk(sk);

    // RTO 超时，重传最早的段
    if (tp->packets_out == 0)
        return;

    // 指数退避
    inet_csk(sk)->icsk_rto = min(sk->sk_rcv_saddr * 2, TCP_RTO_MAX);

    // 重传
    tcp_retransmit_skb(sk, tcp_write_queue_head(sk));

    // 更新慢启动阈值
    tp->snd_ssthresh = tcp_current_ssthresh(sk);
    tp->snd_cwnd = tp->snd_ssthresh;
}
```

### 9.2 快速重传

```c
// 收到 3 个重复 ACK，触发快速重传
if (th->ack == tp->snd_una && th->dupack >= 3) {
    // 快速重传
    tcp_xmit_retransmit_queue(sk);

    // 进入快速恢复
    tp->high_seq = tp->snd_nxt;
    tp->frto_counter = 0;
    tcp_enter_recovery(sk);
}
```

---

## 10. 内存管理

### 10.1 sk_wmem_alloc

```c
// 发送缓冲区内存分配
static int tcp_sendmsg(struct sock *sk, struct msghdr *msg, size_t size)
{
    struct tcp_sock *tp = tcp_sk(sk);
    int limit;

    // 检查内存限制
    if (sk->sk_wmem_alloc + size > sk->sk_sndbuf) {
        // 等待内存释放或发送确认
        wait_for_memory(sk);
    }

    // 分配 skb
    skb = alloc_skb_fclone(size + MAX_TCP_HEADER, sk->sk_allocation);

    // 更新计数
    sk->sk_wmem_alloc += skb->truesize;
    tp->write_bytes += size;
}
```

### 10.2 内存压力处理

```c
// 内存压力时
static void tcp_prune_ofo_queue(struct sock *sk)
{
    struct tcp_sock *tp = tcp_sk(sk);
    struct rb_node *node;

    // 丢弃乱序队列中最老的包
    node = rb_first(&tp->out_of_order_queue);
    if (node) {
        struct sk_buff *skb = rb_entry(node, struct sk_buff, rbnode);
        rb_erase(node, &tp->out_of_order_queue);
        kfree_skb(skb);
    }
}
```

### 10.3 缓冲区监控

```bash
# 查看 TCP 内存使用
cat /proc/net/sockstat

# 查看特定连接缓冲区
ss -tm dst 10.0.0.1

# 查看内存压力
cat /proc/net/netstat | grep -i "tcp_mem"
```

---

## 11. 总结

TCP 缓冲管理要点：

**核心数据结构：**

1. sk_buff 链表管理发送/接收队列
2. 红黑树管理乱序包
3. 滑动窗口控制数据流
4. 拥塞窗口防止网络过载

**关键流程：**

1. send() -> sk_buff -> 发送队列 -> 添加 TCP 头 -> 发送
2. 接收 -> 验证 -> 按序排列 -> 交付应用
3. 乱序包放入 out_of_order_queue
4. 重传队列管理丢失数据

**性能优化：**

1. 缓冲区自动调优
2. Zero-copy（sendfile/splice/MSG_ZEROCOPY）
3. 内存压力时丢包保流
4. 拥塞控制算法选择

**调优参数：**

1. tcp_rmem / tcp_wmem：单连接缓冲区
2. tcp_moderate_rcvbuf：自动调优
3. tcp_congestion_control：拥塞算法
4. SO_RCVBUF / SO_SNDBUF：应用层设置
