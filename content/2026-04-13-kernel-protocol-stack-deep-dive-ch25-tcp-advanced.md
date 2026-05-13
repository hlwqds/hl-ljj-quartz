---
title: "Kernel Protocol Stack 深度探索 (二十五)：TCP 高级特性"
date: 2026-04-13
tags: [linux, kernel, networking, series, tcp, sack, dsack, tfo, fast-open, mptcp, tcp-mark, time-stamp]
description: "深入解析 TCP 高级特性——SACK/DSACK 选择性确认、TFO TCP快速打开、MPTCP多路径传输、TCP mark、timestamp 等"
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
> 25. **第二十五章：TCP 高级特性**

---

## 1. 概述

本章覆盖 TCP 的高级扩展特性，包括 SACK（选择性确认）、DSACK（重复 SACK）、TFO（TCP Fast Open）、MPTCP（多路径 TCP）、TCP timestamp、UTO（User Timeout）等。这些特性大幅提升了 TCP 在复杂网络环境下的性能与可靠性。

---

## 2. SACK（选择性确认）

### 2.1 问题背景

标准 TCP 确认机制是累积确认（cumulative ACK），只能确认连续收到的最后一个字节。如果发生丢包，发送方只能重传所有未确认的数据，即使接收方已经成功缓存了部分数据。

```
示例：发送方发送 1-5000 字节，第 3000 字节丢失
标准ACK：只ACK 2999，发送方重传 3000-5000（但3000已收到）
SACK：ACK 4999，SACK 3000-5000（告诉发送方哪些已收到）
```

### 2.2 SACK 选项格式

```
TCP 头部选项：
Kind=4(SACK)  Length=Variable(10-40 bytes)

+---------------------------+
|  Kind=4  |  Length=10+N*8  |
+---------------------------+
|    左边界1（已接收）         |
+---------------------------+
|    右边界1（下一个期望）      |
+---------------------------+
|           ...              |
+---------------------------+
|    左边界N                  |
+---------------------------+
|    右边界N                  |
+---------------------------+
```

每个 SACK 块 = 8 字节（左右边界各 4 字节），最多 4 个块（40 字节选项）。

### 2.3 内核实现

```c
// include/net/tcp.h
struct tcp_sacktag_state {
    u32     reord;           // 重新排序距离
    u32     rack_stat;       // RACK 统计
    u32     flag;            // 标记状态
    u8      sack_ok;        // SACK OK 标志
};

// SACK 选项处理
static int tcp_sack_process(struct tcp_sock *tp, struct sk_buff *skb,
                            struct tcp_sacktag_state *state)
{
    struct tcp_sack_block *sp = &TCP_SKB_CB(skb)->sack;
    struct sk_buff *skb_it, *skb_it_prev;

    // 遍历所有 SACK 块
    for (i = 0; i < num_sacks; i++) {
        u32 start = ntohl(sp[i].start_seq);
        u32 end   = ntohl(sp[i].end_seq);

        // 更新接收缓存状态
        tcp_sack_update_ofo_queue(tp, start, end, &tp->sack_out);
    }
}
```

### 2.4 发送 SACK

```c
// net/ipv4/tcp_input.c
static void tcp_send_sack(struct sock *sk)
{
    struct tcp_sock *tp = tcp_sk(sk);
    struct sk_buff *skb;

    if (tp->opt.sack_ok && tp->eiserver) {
        // 构造 SACK 选项
        unsigned char *ptr = tp->opt.tcp_options;
        
        *ptr++ = TCPOPT_SACK;
        *ptr++ = (TCPOLEN_SACK + TCPOLEN_TSTAMP_ALIGNED);
        
        // 添加每个乱序块的边界
        for (skb_it = skb_peek(&tp->out_of_order_queue);
             skb_it != (struct sk_buff *)&tp->out_of_order_queue;
             skb_it = skb_queue_next(&tp->out_of_order_queue, skb_it)) {
            // 写入 SACK 块
        }
    }
}
```

---

## 3. DSACK（重复 SACK）

### 3.1 原理

DSACK 是 SACK 的扩展，用于报告重复接收的数据。当发送方收到 SACK 确认了它从未发送过的数据时，就知道发生了重复传输。

```
发送方重传字节 3000-3500（丢失后重传）
接收方：第1次收到 3000-3500（正常SACK）
        第2次收到 3000-3500（重复！） -> DSACK 通知
```

### 3.2 DSACK 选项

DSACK 使用 SACK 选项，但携带一个特殊含义：
- 第一个 SACK 块的左边界 > 右边界（不合法，正常 SACK 无此情况）

实际上 DSACK 在第一个 SACK 块中填充接收到的重复数据范围。

### 3.3 内核实现

```c
// net/ipv4/tcp_input.c
static void tcp_process_dsack(struct tcp_sock *tp, struct sk_buff *skb)
{
    if (TCP_SKB_CB(skb)->sack.is_dSACK) {
        tp->dsack_segs++;

        // DSACK 触发的重传不降低 ssthresh
        if (before(TCP_SKB_CB(skb)->seq, tp->retrans_out)) {
            tp->retrans_stamp = 0;
            tp->undo_marker = tp->snd_nxt;
        }
    }
}
```

---

## 4. TFO（TCP Fast Open）

### 4.1 原理

TFO 允许在 SYN 包中携带数据，节省一个 RTT。在三次握手期间就可以发送应用数据。

```
传统 TCP：
  SYN ---->
  <---- SYN-ACK
  <---- ACK
  ---- data --->   // 1 RTT 延迟后才开始发送

TFO：
  SYN + data ---->
  <---- SYN-ACK + ACK
  ---- data --->   // 0 RTT 延迟
```

### 4.2 TFO Cookie

为了安全，TFO 使用 Cookie 机制防止放大攻击：

```c
// net/ipv4/tcp_fastopen.c
struct tcp_fastopen_cookie {
    u8      len;         // Cookie 长度
    u8      val[16];     // Cookie 值（加密）
};

// 服务端验证 Cookie
static int tcp_fastopen_cookie_gen(struct request_sock *req,
                                   struct tcp_fastopen_cookie *foc)
{
    struct sock *sk = req->listener;
    u32 key = tcp_fastopen_key;
    u64 hash;

    // 生成加密 Cookie
    hash = md5hash(key, req->ir_addr, req->ir_port);
    foc->len = 8;
    memcpy(foc->val, &hash, foc->len);
    return foc->len;
}
```

### 4.3 setsockopt 启用

```c
#include <netinet/tcp.h>

int sock = socket(AF_INET, SOCK_STREAM, 0);

// 启用 TFO 客户端
int val = 1;
setsockopt(sock, IPPROTO_TCP, TCP_FASTOPEN_CONNECT, &val, sizeof(val));

// 或者使用 IPSTACK 风格的 API
// 在 connect() 调用前启用
val = 1;
setsockopt(sock, IPPROTO_TCP, TCP_FASTOPEN, &val, sizeof(val));
```

### 4.4 内核处理流程

```c
// net/ipv4/tcp_input.c
static int tcp_rcv_fast_open_synack(struct sock *sk, struct sk_buff *skb,
                                   struct tcphdr *th)
{
    struct tcp_sock *tp = tcp_sk(sk);
    struct tcp_fastopen_cookie foc;
    struct fastopen_req *req;

    // 验证 Cookie
    tcp_fastopen_cookie_parse(th->doff * 4, tcp_ptr(skb), &foc);
    if (foc.len >= 0) {
        tcp_ao_parse_synack(sk, &foc);
    }

    // 处理 SYN 中的数据
    tcp_data_queue_ofo(sk, skb);

    // 发送 ACK（不等待数据处理完成）
    tcp_send_ack(sk);
}
```

---

## 5. TCP Timestamp

### 5.1 原理

Timestamp 选项用于：
- RTTM（Round Trip Time Measurement）：精确测量 RTT
- PAWS（Protection Against Wrapped Sequence numbers）：防止序列号回绕

### 5.2 选项格式

```
Kind=8  Length=10
+---------------------------+
|  Kind=8  |  Length=10     |
+---------------------------+
|      TSval (4 bytes)      |
+---------------------------+
|      TSecr (4 bytes)      |
+---------------------------+
```

### 5.3 内核实现

```c
// include/net/tcp.h
struct tcp_options_received {
    u32     tstampok;      // Timestamp OK 标志
    u32     saw_tstamp;    // 收到有效 timestamp
    u32     rcv_tsval;    // 接收的 TSval
    u32     rcv_tsecr;    // 接收的 TSecr
};

// RTT 计算
static void tcp_rcv_rtt_update(struct tcp_sock *tp, u32 seq_rtt_us)
{
    s32 delta = seq_rtt_us - (tp->rcv_rtt_us >> 3);
    tp->rcv_rtt_us += delta >> 3;

    // RTTVAR 更新
    tp->rcv_rtt_var = (abs(delta) + tp->rcv_rtt_var) >> 1;
}
```

### 5.4 sysctl 控制

```bash
# 启用 timestamps
sysctl -w net.ipv4.tcp_timestamps = 1

# 查看
sysctl net.ipv4.tcp_timestamps
```

---

## 6. 窗口缩放（Window Scaling）

### 6.1 原理

TCP 头部窗口字段只有 16 位，最大窗口 65535 字节。对于高带宽长延迟网络（如 10GbE，RTT=1ms，BDP=10MB），远远不够。

窗口缩放通过在 SYN/SYN-ACK 中协商一个缩放因子来解决。

### 6.2 缩放因子

```
实际窗口 = 头部窗口 << 缩放因子

缩放因子 = 0-14
- 缩放因子 0：窗口不变
- 缩放因子 7：最大窗口 65535 << 7 = 8MB
- 缩放因子 14：最大窗口 65535 << 14 = 1GB
```

### 6.3 内核实现

```c
// net/ipv4/tcp_input.c
static void tcp_parse_options(const struct sk_buff *skb,
                              struct tcp_options_received *opt)
{
    // ... 解析各选项 ...

    if (opt->wscale_ok) {
        tp->rcv_wnd_shaping = opt->rcv_wnd;
        tp->rcv_ssthresh = min(tp->rcv_ssthresh, (u32)(TCP_INIT_CWND * opt->rcv_wnd));
    }
}
```

### 6.4 sysctl 配置

```bash
# 启用窗口缩放
sysctl -w net.ipv4.tcp_window_scaling = 1

# 设置最大缩放因子（默认 7）
sysctl -w net.ipv4.tcp_adv_win_scale = 7
```

---

## 7. MPTCP（多路径 TCP）

### 7.1 概念

MPTCP 允许在多个路径上同时传输数据，提供：
- 更高的吞吐量（多路径聚合）
- 容错性（一条路径断开不影响连接）
- 更好的资源利用

### 7.2 架构

```
应用层
    │
    ▼
MPTCP 层（多路径调度）
    │
    ├──────────────────────────────┐
    ▼                              ▼
子流1（子连接）              子流2（子连接）
    │                              │
    ▼                              ▼
普通TCP                         普通TCP
```

### 7.3 内核支持

```c
// net/mptcp/mptcp.c
struct mptcp_sock {
    struct sock         sk;          // 顶层 socket
    struct list_head    join_list;   // 子流列表
    __u64               mptcp_token; // MPTCP 连接标识
    __u32              mptcp_loc_token; // 本地 token
    __u64               mptcp_rem_key;   // 远端密钥
    struct sock         *master;     // 主 subflow
};

static const struct inet_connection_sock_ops mptcp_sock_ops = {
    .icsk_send_head     = mptcp_send_head,
    .icsk_queue_tail    = mptcp_queue_tail,
    .icsk_sendmsg       = mptcp_sendmsg,
    .icsk_recvmsg       = mptcp_recvmsg,
};
```

---

## 8. TCP User Timeout（UTO）

### 8.1 原理

UTO 允许应用指定连接空闲多久后认为对端不可达。

```
UTO 计时器 = 用户指定超时
  - 收到任何数据重置计时器
  - 超时后：发送 keepalive 或直接关闭
```

### 8.2 setsockopt 配置

```c
#include <netinet/tcp.h>

struct tcp_user_timeout {
    u32     timeout;    // 超时时间（毫秒）
    u32     flags;      // TCP_UTO_*
};

// 启用 UTO，5分钟超时
struct tcp_user_timeoututo = { .timeout = 300000, .flags = TCP_UTO_ACTIVE };
setsockopt(sock, IPPROTO_TCP, TCP_USER_TIMEOUT, &uto, sizeof(uto));
```

---

## 9. TCP MD5 Signature（TCP-AO）

### 9.1 概述

TCP MD5 Signature（RFC 2385）和后续的 TCP Authentication Option（TCP-AO，RFC 5925）用于在 TCP 头部添加消息认证码，防止中间人攻击。

### 9.2 内核实现

```c
// include/net/tcp_ao.h
struct tcp_ao {
    struct tcp_ao_key   *keys;       // 密钥列表
    u8                  maclen;     // MAC 长度
    u8                  keylen;     // 密钥长度
    u8                  snd_secret; // 发送密钥
    u8                  rcv_secret; // 接收密钥
};

// 计算 MAC
static void tcp_ao_compute_mac(struct tcp_ao *ao,
                                struct tcphdr *th,
                                union tcp_addr *saddr,
                                union tcp_addr *daddr,
                                char *mac)
{
    struct {
        struct tcphdr   th;
        u32             saddr, daddr;
    } __attribute__((packed)) buffer;

    buffer.th = *th;
    buffer.saddr = saddr->in4.s_addr;
    buffer.daddr = daddr->in4.s_addr;

    // HMAC-MD5/SHA1 计算
    hmac_buffer(ao->hash_algo, ao->maclen, buffer, sizeof(buffer), mac);
}
```

---

## 10. TCP Keepalive

### 10.1 原理

TCP Keepalive 定期在空闲连接上发送探测包，检测对端是否存活。

```
空闲时间 > keepalive_time：
  发送 keepalive probe
  如果没有响应，重试 keepalive_probes 次
  每次重试间隔 keepalive_intvl
  全部失败后关闭连接
```

### 10.2 sysctl 参数

```bash
# 空闲多久后开始发送 keepalive（默认 2 小时）
sysctl -w net.ipv4.tcp_keepalive_time = 7200

# 重试间隔（默认 75 秒）
sysctl -w net.ipv4.tcp_keepalive_intvl = 75

# 重试次数（默认 9 次）
sysctl -w net.ipv4.tcp_keepalive_probes = 9
```

### 10.3 setsockopt 配置

```c
#include <netinet/tcp.h>

int sock = socket(AF_INET, SOCK_STREAM, 0);

// 设置 keepalive
int val = 1;
setsockopt(sock, SOL_SOCKET, SO_KEEPALIVE, &val, sizeof(val));

// 设置空闲时间
int idle = 300;  // 5 分钟
setsockopt(sock, IPPROTO_TCP, TCP_KEEPIDLE, &idle, sizeof(idle));

// 设置重试间隔
int intvl = 30;
setsockopt(sock, IPPROTO_TCP, TCP_KEEPINTVL, &intvl, sizeof(intvl));

// 设置重试次数
int cnt = 5;
setsockopt(sock, IPPROTO_TCP, TCP_KEEPCNT, &cnt, sizeof(cnt));
```

---

## 11. TCP quick-ack

### 11.1 原理

quick-ack 模式延迟发送 ACK，让应用层有机会捎带确认。

```c
// 启用 quick-ack
int val = 1;
setsockopt(sock, IPPROTO_TCP, TCP_QUICKACK, &val, sizeof(val));

// 禁用 quick-ack（延迟确认）
val = 0;
setsockopt(sock, IPPROTO_TCP, TCP_QUICKACK, &val, sizeof(val));
```

---

## 12. TCP NoDelay（Nagle 算法）

### 12.1 Nagle 算法

Nagle 算法合并小数据包，减少小包数量。

```
Nagle 规则：
- 如果有未确认的数据（send buffer 非空），则等待
- 如果没有未确认数据，立即发送
- 如果有未确认数据，且数据 < MSS，等待 ACK 后再发送
```

### 12.2 禁用 Nagle

```c
#include <netinet/tcp.h>

int flag = 1;
setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, &flag, sizeof(flag));
```

---

## 13. TCP_CORK（阻止部分发送）

### 13.1 原理

TCP_CORK 让内核等待数据达到一定大小再发送，避免发送过小的数据包。

```c
// 启用 cork（直到数据凑满 MSS 或 explicit uncork）
int val = 1;
setsockopt(sock, IPPROTO_TCP, TCP_CORK, &val, sizeof(val));

// 取消 cork，强制发送
val = 0;
setsockopt(sock, IPPROTO_TCP, TCP_CORK, &val, sizeof(val));
```

---

## 14. 总结

| 特性 | RFC | 用途 | 内核默认值 |
|------|-----|------|-----------|
| SACK | RFC 2017 | 选择性确认，改进重传 | 启用 |
| DSACK | RFC 3465 | 检测重复传输 | 启用 |
| TFO | RFC 7413 | 减少连接延迟 | 客户端启用 |
| Timestamp | RFC 7323 | RTTM + PAWS | 启用 |
| Window Scaling | RFC 7323 | 扩大窗口 | 启用 |
| MPTCP | RFC 8684 | 多路径传输 | 可选模块 |
| Keepalive | - | 空闲检测 | 2小时空闲 |
| TCP-AO | RFC 5925 | 安全认证 | 可选 |

这些高级特性让 TCP 能够适应从低俗拨号到 100GbE 的各种网络环境，是现代互联网的基石。
