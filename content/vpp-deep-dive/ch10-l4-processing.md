---
title: "VPP 深入探讨 ch10：L4 TCP/UDP 处理"
date: 2026-04-09 23:00:00
tags: [vpp, l4, tcp, udp, session, connection-tracking, nat, stream]
description: "深入解析 VPP L4 处理：TCP Session 管理、连接跟踪、UDP Stream、NAT44/NAT64 与 L4 负载均衡"
---

# VPP 深入探讨 ch10：L4 TCP/UDP 处理

> [!abstract] 核心要点
> VPP 在 L4 层支持 TCP Session 管理、连接跟踪、NAT 和 UDP Stream 处理。本章深入解析 session 表、TCP 状态机、连接跟踪、NAT 实现与 L4 负载均衡。

## 1. L4 处理概述

### 1.1 VPP L4 组件

```
┌─────────────────────────────────────────────────────────────┐
│                    VPP L4 组件                             │
│                                                              │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐       │
│  │   TCP      │  │   UDP      │  │   SCTP     │       │
│  │  Session   │  │  Stream    │  │            │       │
│  └─────────────┘  └─────────────┘  └─────────────┘       │
│                                                              │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐       │
│  │  Connection │  │    NAT     │  │   ALG      │       │
│  │   Tracker   │  │            │  │  (FTP/SIP) │       │
│  └─────────────┘  └─────────────┘  └─────────────┘       │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 L4 处理流程

```
┌─────────────────────────────────────────────────────────────┐
│                    L4 Packet Processing                      │
│                                                              │
│  IP Input                                                    │
│       │                                                      │
│       ▼                                                      │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ Check Protocol                                         │  │
│  │ - TCP → TCP Input Node                                │  │
│  │ - UDP → UDP Input Node                                │  │
│  │ - ICMP → ICMP Input                                   │  │
│  └──────────────────────────────────────────────────────┘  │
│       │                                                      │
│       ▼                                                      │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ Connection Tracking (if enabled)                       │  │
│  │ - Look up session table                               │  │
│  │ - Create new session if needed                        │  │
│  └──────────────────────────────────────────────────────┘  │
│       │                                                      │
│       ▼                                                      │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ Protocol Specific Processing                         │  │
│  │ - TCP: State machine, retransmit, window             │  │
│  │ - UDP: Port forwarding, NAT                          │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

## 2. TCP Session 管理

### 2.1 TCP Session 结构

```c
// TCP Session (Connection)
typedef struct {
    // 5-tuple
    ip46_address_t src_ip;
    ip46_address_t dst_ip;
    u16 src_port;
    u16 dst_port;
    u8 protocol;  // TCP

    // 状态
    u8 state;
    u8 flags;

    // 序列号
    u32 snd_nxt;       // Next sequence to send
    u32 snd_una;       // Oldest unacked
    u32 snd_wnd;       // Send window
    u32 rcv_nxt;       // Next sequence expected
    u32 rcv_wnd;       // Receive window

    // 重传
    u32 rtx_timeout;
    u32 rtx_count;

    // Buffer
    u8 *rcv_buf;       // Receive buffer
    u32 rcv_buf_len;
    u32 rcv_buf_offset;

    // 定时器
    u32 established_time;
    u32 last_ack_time;

    // Session 管理
    u32 session_index;
    u8 thread_index;
} tcp_session_t;

// TCP 状态
enum tcp_state {
    TCP_STATE_CLOSED = 0,
    TCP_STATE_LISTEN,
    TCP_STATE_SYN_SENT,
    TCP_STATE_SYN_RECEIVED,
    TCP_STATE_ESTABLISHED,
    TCP_STATE_FIN_WAIT,
    TCP_STATE_CLOSE_WAIT,
    TCP_STATE_CLOSING,
    TCP_STATE_LAST_ACK,
    TCP_STATE_TIME_WAIT,
};
```

### 2.2 TCP Session 表

```c
// TCP Session 表
struct tcp_main_t {
    // Session hash 表（按 5-tuple 索引）
    uword *session_hash;

    // Session 数组
    tcp_session_t *sessions;

    // 统计
    u64 tcp_session_count;
    u64 tcp_packets_in;
    u64 tcp_packets_out;
    u64 tcp_retransmits;

    // 配置
    u32 rcv_wnd_default;
    u32 snd_wnd_default;
    u32 connection_timeout;
    u32 retransmit_timeout;
};

// Session 查找
static inline tcp_session_t *
tcp_session_lookup(tcp_main_t *tm,
                   ip46_address_t *src_ip,
                   ip46_address_t *dst_ip,
                   u16 src_port,
                   u16 dst_port)
{
    u64 key = make_5tuple_key(src_ip, dst_ip, src_port, dst_port, IP_PROTOCOL_TCP);
    uword *p = hash_get(tm->session_hash, key);

    if (p) {
        return &tm->sessions[*p];
    }
    return NULL;
}
```

### 2.3 TCP 输入处理

```c
// TCP Input Node
VLIB_NODE_FN(tcp_input_node)
{
    u32 *from = vlib_frame_vector_args(frame);
    u32 n_packets = frame->n_vectors;

    for (u32 i = 0; i < n_packets; i++) {
        vlib_buffer_t *b = vlib_get_buffer(vm, from[i]);
        tcp_header_t *tcp = get_tcp_header(b);

        // 查找 session
        tcp_session_t *s = tcp_session_lookup(tm,
            &tcp->src_ip, &tcp->dst_ip,
            tcp->src_port, tcp->dst_port);

        if (!s) {
            // 新连接？检查是否是 SYN
            if (tcp->flags & TCP_FLAG_SYN &&
                !(tcp->flags & TCP_FLAG_ACK)) {
                // 处理 SYN
                s = tcp_handle_syn(b, tcp);
            } else {
                // 无效包，丢弃
                vlib_buffer_free(vm, &from[i], 1);
                continue;
            }
        }

        // TCP 状态机处理
        switch (s->state) {
        case TCP_STATE_LISTEN:
            // 被动打开，接收 SYN
            tcp_handle_syn_recv(s, tcp);
            break;

        case TCP_STATE_SYN_SENT:
            // 主动打开，等待 SYN-ACK
            tcp_handle_syn_ack(s, tcp);
            break;

        case TCP_STATE_ESTABLISHED:
            // 数据传输
            tcp_handle_data(s, tcp, b);
            break;

        case TCP_STATE_FIN_WAIT:
            // 等待远端 FIN
            tcp_handle_fin(s, tcp);
            break;

        // ... 其他状态
        }
    }

    return n_packets;
}
```

### 2.4 TCP 三次握手

```c
// 被动打开（Server）
static tcp_session_t *
tcp_handle_syn(vlib_buffer_t *b, tcp_header_t *tcp)
{
    // 创建新 session
    tcp_session_t *s = tcp_session_alloc();

    s->state = TCP_STATE_SYN_RECEIVED;
    s->src_ip = tcp->dst_ip;
    s->dst_ip = tcp->src_ip;
    s->src_port = tcp->dst_port;
    s->dst_port = tcp->src_port;

    // 生成 ISN
    s->rcv_nxt = tcp->seq_number + 1;

    // 发送 SYN-ACK
    tcp_send_syn_ack(s);

    return s;
}

// SYN-ACK 接收
static void
tcp_handle_syn_ack(tcp_session_t *s, tcp_header_t *tcp)
{
    // 验证 ACK
    if (tcp->ack_number != s->snd_nxt) {
        // 无效 ACK
        return;
    }

    s->state = TCP_STATE_ESTABLISHED;
    s->snd_una = tcp->ack_number;
    s->snd_wnd = tcp->window;

    // 发送 ACK
    tcp_send_ack(s);
}

// 主动打开（Client）
static void
tcp_connect(tcp_main_t *tm, ip46_address_t *dst, u16 port)
{
    // 创建 session
    tcp_session_t *s = tcp_session_alloc();

    s->state = TCP_STATE_SYN_SENT;
    s->dst_ip = *dst;
    s->dst_port = port;
    s->src_port = allocate_ephemeral_port();

    // 生成 ISN
    s->snd_nxt = generate_isn();

    // 发送 SYN
    tcp_send_syn(s);
}
```

## 3. 连接跟踪 (Connection Tracking)

### 3.1 CT 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    Connection Tracking                       │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │                   Session Table                       │  │
│  │                                                       │  │
│  │  (192.168.1.10:5000, 10.0.0.1:80, TCP) → ESTABLISHED│  │
│  │  (10.0.0.1:80, 192.168.1.10:5000, TCP) → ESTABLISHED│  │
│  │  (10.0.0.2:53, 192.168.1.10:1000, UDP) → ALIVE      │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                              │
│  CT 状态：                                                   │
│  - NEW: 新连接                                              │
│  - ESTABLISHED: 已有连接                                    │
│  - RELATED: 关联连接 (如 ICMP error)                       │
│  - INVALID: 无效包                                          │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 CT Session

```c
// CT Session
typedef struct {
    // 原始 5-tuple
    ip46_address_t orig_src_ip;
    ip46_address_t orig_dst_ip;
    u16 orig_src_port;
    u16 orig_dst_port;
    u8 orig_proto;

    // NAT 后的值（如果有）
    ip46_address_t nat_src_ip;
    ip46_address_t nat_dst_ip;
    u16 nat_src_port;
    u16 nat_dst_port;

    // 状态
    u8 state;
    u8 flags;

    // 元数据
    u64 last_update_time;
    u32 timeout;
    u32 mark;           // 标记（用于 policy）
    u32 accounting;     // 统计信息

    // ALG 相关
    void *alg_data;
} ct_session_t;

// CT 查找
static inline ct_session_t *
ct_session_lookup(ct_main_t *cm,
                 ip46_address_t *src_ip,
                 ip46_address_t *dst_ip,
                 u16 src_port,
                 u16 dst_port,
                 u8 proto)
{
    u64 key = make_5tuple_key(src_ip, dst_ip, src_port, dst_port, proto);

    uword *p = hash_get(cm->session_hash, key);
    if (p) {
        return &cm->sessions[*p];
    }
    return NULL;
}
```

### 3.3 CT 配置

```bash
# 启用连接跟踪
vpp# set connection tracking enable

# 配置超时
vpp# set connection tracking timeout tcp-established 3600
vpp# set connection tracking timeout udp 60

# 查看连接跟踪
vpp# show connection tracking
```

## 4. NAT (Network Address Translation)

### 4.1 NAT44

```c
// NAT44 Session
typedef struct {
    // 内部地址
    ip4_address_t inside_ip;
    u16 inside_port;

    // 外部地址
    ip4_address_t outside_ip;
    u16 outside_port;

    // 状态
    u8 state;
    u64 create_time;
    u64 last_active_time;

    // 计数
    u64 packets;
    u64 bytes;
} nat44_session_t;

// NAT44 处理
static_always_inline void
nat44_inbound(vlib_buffer_t *b, ip4_header_t *ip, tcp_udp_header_t *tcp)
{
    // 查找 NAT session
    nat44_session_t *s = nat44_session_lookup(&nat_main,
        ip->dst_address, tcp->dst_port);

    if (s) {
        // DNAT: 修改目的地址
        ip->dst_address = s->inside_ip;
        tcp->dst_port = s->inside_port;

        // 重新计算 checksum
        ip4_ttl_checksum_update(ip);
        // TCP/UDP checksum 调整
    } else {
        // 没有 session，检查是否允许
        // DROP or FORWARD
    }
}

static_always_inline void
nat44_outbound(vlib_buffer_t *b, ip4_header_t *ip, tcp_udp_header_t *tcp)
{
    // SNAT: 修改源地址
    nat44_session_t *s = nat44_session_lookup(&nat_main,
        ip->src_address, tcp->src_port);

    if (s) {
        // SNAT
        ip->src_address = s->outside_ip;
        tcp->src_port = s->outside_port;

        // 调整 checksum
    }
}
```

### 4.2 NAT64

```c
// NAT64 处理（IPv6 → IPv4）
static_always_inline void
nat64_input(vlib_buffer_t *b, ip6_header_t *ip6, tcp_udp_header_t *tcp)
{
    // 查找 NAT64 session
    nat64_session_t *s = nat64_session_lookup(&nat64_main,
        &ip6->dst_address);

    if (s) {
        // IPv6 → IPv4 转换
        ip4_header_t *ip4 = translate_ipv6_to_ipv4(ip6);

        // 设置 IPv4 源地址
        ip4->src_address = s->ipv4_address;

        // 发送到 IPv4 网络
    }
}
```

### 4.3 NAT 配置

```bash
# 配置 NAT44
vpp# nat44 add interface address GigabitEthernet0/8/0

# 添加静态映射
vpp# nat44 add static mapping tcp inside 192.168.1.10 80 outside 203.0.113.1 8080

# 启用 NAT44
vpp# set interface nat44 in GigabitEthernet0/8/0 out GigabitEthernet0/8/1

# 查看 NAT
vpp# show nat44
vpp# show nat44 sessions
```

## 5. UDP Stream 处理

### 5.1 UDP Stream 特性

```
UDP vs TCP：

TCP：
  - 面向连接
  - 可靠传输
  - 拥塞控制
  - 流量控制

UDP：
  - 无连接
  - 不可靠
  - 无拥塞控制
  - 适合实时应用

UDP Stream:
  - VPP 对 UDP 的流表抽象
  - 支持 session 超时
  - 支持负载均衡
```

### 5.2 UDP Stream Session

```c
// UDP Stream Session
typedef struct {
    // 5-tuple
    ip46_address_t src_ip;
    ip46_address_t dst_ip;
    u16 src_port;
    u16 dst_port;

    // 状态
    u64 last_seen;
    u32 timeout;

    // 统计
    u64 packets;
    u64 bytes;
} udp_stream_session_t;
```

### 5.3 UDP 负载均衡

```c
// UDP 负载均衡（基于 hash）
static_always_inline void
udp_lb(vlib_buffer_t *b, ip4_header_t *ip, udp_header_t *udp)
{
    // 计算 hash
    u32 hash = 0;
    hash ^= ip->src_address.data_u32;
    hash ^= ip->dst_address.data_u32;
    hash ^= udp->src_port;
    hash ^= udp->dst_port;

    // 选择后端
    u32 backend_idx = hash % num_backends;
    backend_t *backend = &backends[backend_idx];

    // 修改目的地址
    ip->dst_address = backend->ip;
    udp->dst_port = backend->port;

    // 调整 checksum
    udp->checksum = 0;
}
```

## 6. L4 负载均衡

### 6.1 L4 LB 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    L4 Load Balancer                          │
│                                                              │
│  Client                                                     │
│     │                                                       │
│     │ TCP SYN                                               │
│     ▼                                                       │
│  ┌──────────────────────────────────────────────────────┐  │
│  │                   VIP: 203.0.113.10:80               │  │
│  └──────────────────────────────────────────────────────┘  │
│     │                                                       │
│     ▼                                                       │
│  ┌──────────────────────────────────────────────────────┐  │
│  │                   Load Balancer                       │  │
│  │                                                       │  │
│  │  1. 接收 SYN                                         │  │
│  │  2. 选择后端 (RR/LC/Hash)                           │  │
│  │  3. 创建 session                                    │  │
│  │  4. 转发到后端                                      │  │
│  └──────────────────────────────────────────────────────┘  │
│     │                                                       │
│     │ TCP SYN                                              │
│     ▼                                                       │
│  ┌──────────────────────────────────────────────────────┐  │
│  │                Backend 1 (10.0.0.1:8080)              │  │
│  │                Backend 2 (10.0.0.2:8080)              │  │
│  │                Backend 3 (10.0.0.3:8080)              │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 6.2 DSR (Direct Server Return)

```
DSR 模式：后端直接回复客户端，绕过 LB

┌─────────────────────────────────────────────────────────────┐
│                    DSR 流程                                 │
│                                                              │
│  1. Client → SYN → LB                                       │
│  2. LB → SYN → Backend (修改 dst MAC)                      │
│  3. Backend → SYN-ACK → Client (直接回复)                  │
│  4. Client → ACK → LB → Backend                            │
│  5. Client → Data → LB → Backend                           │
│  6. Backend → Data → Client (直接回复)                     │
└─────────────────────────────────────────────────────────────┘
```

### 6.3 L4 LB 配置

```bash
# 创建 L4 LB
vpp# lbl4 create vip tcp 203.0.113.10:80

# 添加后端
vpp# lbl4 add server tcp 203.0.113.10:80 10.0.0.1:8080
vpp# lbl4 add server tcp 203.0.113.10:80 10.0.0.2:8080

# 配置算法
vpp# lbl4 set algorithm tcp 203.0.113.10:80 round-robin

# 查看 L4 LB
vpp# show lbl4
```

## 7. ALG (Application Layer Gateway)

### 7.1 FTP ALG

```c
// FTP PORT 命令解析
static int
ftp_alg_parse_port(const char *cmd, ftp_alg_data_t *data)
{
    // FTP PORT 格式: h1,h2,h3,h4,p1,p2
    // IP = h1.h2.h3.h4
    // Port = p1*256 + p2

    int h1, h2, h3, h4, p1, p2;
    sscanf(cmd, "PORT %d,%d,%d,%d,%d,%d", &h1, &h2, &h3, &h4, &p1, &p2);

    data->ip = (h1 << 24) | (h2 << 16) | (h3 << 8) | h4;
    data->port = (p1 << 8) | p2;

    return 0;
}

// FTP 数据通道处理
static void
ftp_alg_handle_data_channel(u32 ftp_session_index,
                            ip46_address_t *cli_ip,
                            u16 cli_port)
{
    // 创建关联的数据连接 session
    ct_session_t *data_conn = ct_session_alloc();

    // 配置为 RELATED 状态
    data_conn->state = CT_STATE_RELATED;
    data_conn->orig_src_ip = *cli_ip;
    data_conn->orig_src_port = cli_port;
    // ...
}
```

### 7.2 SIP ALG

```c
// SIP ALG 处理
static void
sip_alg_handle_invite(ct_session_t *s, u8 *data, u32 len)
{
    // 解析 SIP INVITE
    sip_invite_t *inv = sip_parse_invite(data, len);

    // 修改 Contact 头中的 IP 地址
    sip_modify_contact(inv, s->nat_src_ip);

    // 处理 SDP 中的 IP
    sip_modify_sdp(inv, s->nat_src_ip);

    // 记录 Call-ID 用于后续关联
    s->alg_data = strdup(inv->call_id);
}
```

## 8. 总结

L4 处理核心组件：

| 组件            | 功能         | 关键点               |
| --------------- | ------------ | -------------------- |
| **TCP Session** | TCP 连接管理 | 状态机、序列号、窗口 |
| **CT**          | 连接跟踪     | session 表、超时     |
| **NAT44/64**    | 地址转换     | SNAT/DNAT session    |
| **UDP Stream**  | UDP 流管理   | 超时、统计           |
| **L4 LB**       | 负载均衡     | DSR、算法            |
| **ALG**         | 应用层网关   | FTP、SIP             |

TCP 状态机：

```
CLOSED → SYN_SENT → ESTABLISHED → FIN_WAIT → CLOSED
   ↑         ↓
   └─ LISTEN ← SYN_RECEIVED ←──────┘
                    ↓
              CLOSE_WAIT → LAST_ACK → CLOSED
```

---

## 参考资源

- [RFC 793 - TCP](https://tools.ietf.org/html/rfc793)
- [RFC 4960 - SCTP](https://tools.ietf.org/html/rfc4960)
- [VPP NAT](https://wiki.fd.io/view/VPP/NAT)
- [VPP Connection Tracking](https://wiki.fd.io/view/VPP/Connection_Tracking)
