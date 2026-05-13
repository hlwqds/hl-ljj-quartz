---
title: "DPDK 深度探索 (十二)：TCP 协议栈实现与连接管理"
date: 2026-04-09
tags: [dpdk, series, tcp, connection, state-machine, sliding-window, congestion-control, socket]
description: "深入理解 DPDK 中的 TCP 处理——三次握手、连接状态机、滑动窗口、拥塞控制、TCP 选项解析、以及 socket API 封装"
---

> [!info] DPDK 深度探索系列
> 0. [[2026-04-09-dpdk-deep-dive-series-index|全栈学习路径总览]]
> 1-11. 前十一章已完成
> 12. **第十二章：TCP 协议栈实现与连接管理**

---

## 1. 概述：DPDK 中的 TCP

DPDK 本身**不提供完整的 TCP 协议栈**，但提供了构建 TCP 应用所需的基础设施：

| 组件                      | 说明                    |
| ----------------------- | --------------------- |
| **mbuf**                | 存储 TCP 段（segment）     |
| **Flow Classification** | 识别 TCP 连接，进行会话分发      |
| **rte_ring**            | 存储待发送/接收的 TCP segment |
| **rte_timer**           | RTT 定时器、重传定时器         |
| **cryptodev**           | TLS/DTLS 硬件卸载         |
| **KNI**                 | 与内核 TCP 栈交互           |

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        DPDK TCP 处理层次                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  应用层 (Your App)                                                         │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │  TCP Connection Manager (连接管理)                                    │  │
│  │  - 监听、连接建立、断开                                               │  │
│  │  - 序列号管理、状态机                                                 │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                    │                                        │
│ 传输层 (librte_net + Your Code)                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │  TCP Segment Processing (段处理)                                     │  │
│  │  - 头部解析、checksum 验证                                            │  │
│  │  - 滑动窗口、拥塞控制（需要自己实现）                                  │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                    │                                        │
│  数据报层 (DPDK PMD + rte_flow)                                             │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │  Packet I/O + Flow Steering                                          │  │
│  │  - 收发网络包                                                         │  │
│  │  - RSS/FDIR 负载均衡                                                  │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. TCP 头部结构

### 2.1 TCP 头部

```c
// lib/net/rte_tcp.h

struct rte_tcp_hdr {
    rte_be16_t src_port;       // 源端口
    rte_be16_t dst_port;       // 目标端口
    rte_be32_t sent_seq;        // 序列号（SYN 消耗一个序号）
    rte_be32_t recv_ack;        // 确认号（期望收到的下一个序列号）
    uint8_t  data_off;          // 数据偏移（Data Offset）| 保留
    uint8_t  tcp_flags;         // TCP flags (URG|ACK|PSH|RST|SYN|FIN)
    rte_be16_t rx_win;         // 接收窗口大小
    rte_be16_t cksum;          // TCP 校验和
    rte_be16_t tcp_urp;        // 紧急指针
} __rte_packed;

// TCP Flags
#define RTE_TCP_CWR_FLAG   0x80   // Congestion Window Reduced
#define RTE_TCP_ECE_FLAG   0x40   // ECN Echo
#define RTE_TCP_URG_FLAG   0x20   // Urgent
#define RTE_TCP_ACK_FLAG   0x10   // Acknowledge
#define RTE_TCP_PSH_FLAG   0x08   // Push
#define RTE_TCP_RST_FLAG   0x04   // Reset
#define RTE_TCP_SYN_FLAG   0x02   // Synchronize
#define RTE_TCP_FIN_FLAG   0x01   // Finish

// 数据偏移计算
#define TCP_HEADER_LEN(tcp_hdr) (((tcp_hdr)->data_off & 0xF0) >> 2)
```

### 2.2 TCP 选项

```c
// TCP 选项类型
enum {
    TCP_OPT_END     = 0,    // 选项结束
    TCP_OPT_NOP     = 1,    // 无操作（用于对齐）
    TCP_OPT_MSS     = 2,    // 最大段大小 (MSS)
    TCP_OPT_WSCALE  = 3,    // 窗口扩大因子
    TCP_OPT_SACKOK  = 4,    // SACK 允许
    TCP_OPT_SACK    = 5,    // SACK 选项
    TCP_OPT_TIMESTAMP = 8,  // 时间戳
    TCP_OPT_MD5     = 19,   // MD5 签名 (RFC 2385)
    TCP_OPT_MPO     = 30,   // Multipath TCP
};

// MSS 选项
struct tcp_opt_mss {
    uint8_t kind;
    uint8_t length;
    rte_be16_t mss;
};

// 窗口扩大因子选项
struct tcp_opt_wscale {
    uint8_t kind;
    uint8_t length;
    uint8_t shift;
};

// 时间戳选项
struct tcp_opt_timestamp {
    uint8_t kind;
    uint8_t length;
    rte_be32_t ts_value;    // TS Val: 本地时间戳
    rte_be32_t ts_ecr;      // TS Echo: 回显对端的时间戳
};
```

### 2.3 解析 TCP 头部

```c
// 解析 TCP 选项
typedef struct {
    uint16_t mss;           // 最大段大小
    uint8_t wscale;         // 窗口扩大因子
    uint8_t sack_ok;        // SACK 是否允许
    uint8_t timestamp;      // 时间戳是否启用
    uint32_t ts_val;        // TS Val
    uint32_t ts_ecr;        // TS Echo
    uint32_t sack_blks[4][2]; // SACK blocks (最多 4 个, 每个 [left_edge, right_edge])
    uint8_t sack_count;       // SACK block 数量
} tcp_options_t;

static void
parse_tcp_options(const uint8_t *opt, uint8_t len, tcp_options_t *opts)
{
    memset(opts, 0, sizeof(*opts));
    opts->wscale = 0;  // 默认无窗口扩大

    uint8_t pos = 0;
    while (pos < len) {
        switch (opt[pos]) {
        case TCP_OPT_END:
            return;

        case TCP_OPT_NOP:
            pos++;
            break;

        case TCP_OPT_MSS: {
            if (pos + 4 <= len && opt[pos + 1] == 4) {
                opts->mss = rte_be_to_cpu_16(*(uint16_t *)(opt + pos + 2));
            }
            pos += opt[pos + 1];
            break;
        }

        case TCP_OPT_WSCALE:
            if (pos + 3 <= len && opt[pos + 1] == 3) {
                opts->wscale = opt[pos + 2];
                if (opts->wscale > 14) opts->wscale = 14;  // 最大 14
            }
            pos += opt[pos + 1];
            break;

        case TCP_OPT_TIMESTAMP:
            if (pos + 10 <= len && opt[pos + 1] == 10) {
                opts->timestamp = 1;
                opts->ts_val = rte_be_to_cpu_32(*(uint32_t *)(opt + pos + 2));
                opts->ts_ecr = rte_be_to_cpu_32(*(uint32_t *)(opt + pos + 6));
            }
            pos += opt[pos + 1];
            break;

        case TCP_OPT_SACKOK:
            if (pos + 2 <= len && opt[pos + 1] == 2) {
                opts->sack_ok = 1;
            }
            pos += opt[pos + 1];
            break;

        case TCP_OPT_SACK: {
            // SACK 选项: kind(1) + length(1) + n * [left(4) + right(4)]
            uint8_t sack_len = opt[pos + 1];
            uint8_t nblks = (sack_len - 2) / 8;  // 每个 block 8 字节
            if (nblks > 4) nblks = 4;            // RFC 最多 4 个
            opts->sack_count = nblks;
            for (uint8_t b = 0; b < nblks && pos + 2 + b * 8 + 8 <= len; b++) {
                opts->sack_blks[b][0] = rte_be_to_cpu_32(*(uint32_t *)(opt + pos + 2 + b * 8));
                opts->sack_blks[b][1] = rte_be_to_cpu_32(*(uint32_t *)(opt + pos + 6 + b * 8));
            }
            pos += sack_len;
            break;
        }

        default:
            // 未知选项，跳过
            if (pos + 1 < len) {
                pos += opt[pos + 1];
            } else {
                pos++;
            }
        }
    }
}

// 解析完整 TCP 头部
static void
parse_tcp(struct rte_mbuf *m, struct rte_tcp_hdr *tcp)
{
    uint16_t src_port = rte_be_to_cpu_16(tcp->src_port);
    uint16_t dst_port = rte_be_to_cpu_16(tcp->dst_port);
    uint32_t seq = rte_be_to_cpu_32(tcp->sent_seq);
    uint32_t ack = rte_be_to_cpu_32(tcp->recv_ack);
    uint8_t flags = tcp->tcp_flags;
    uint16_t window = rte_be_to_cpu_16(tcp->rx_win);
    uint8_t data_offset = TCP_HEADER_LEN(tcp);

    printf("TCP: %d -> %d, seq=%u, ack=%u, flags=%s%s%s%s%s%s, win=%d\n",
           src_port, dst_port, seq, ack,
           (flags & RTE_TCP_SYN_FLAG) ? "SYN " : "",
           (flags & RTE_TCP_ACK_FLAG) ? "ACK " : "",
           (flags & RTE_TCP_PSH_FLAG) ? "PSH " : "",
           (flags & RTE_TCP_FIN_FLAG) ? "FIN " : "",
           (flags & RTE_TCP_RST_FLAG) ? "RST " : "",
           window);

    // 解析选项
    if (data_offset > sizeof(struct rte_tcp_hdr)) {
        uint8_t opt_len = data_offset - sizeof(struct rte_tcp_hdr);
        tcp_options_t opts;
        parse_tcp_options((uint8_t *)(tcp + 1), opt_len, &opts);

        if (opts.mss)
            printf("  MSS=%d\n", opts.mss);
        if (opts.wscale)
            printf("  WScale=%d\n", opts.wscale);
        if (opts.timestamp)
            printf("  TS=%u,%u\n", opts.ts_val, opts.ts_ecr);
    }
}
```

---

## 3. TCP 连接状态机

### 3.1 状态定义

```c
// TCP 连接状态
enum tcp_state {
    TCP_STATE_CLOSED       = 0,
    TCP_STATE_LISTEN       = 1,    // 服务器：等待连接
    TCP_STATE_SYN_SENT      = 2,    // 客户端：已发送 SYN
    TCP_STATE_SYN_RECEIVED  = 3,    // 服务器：收到 SYN，已发 SYN+ACK
    TCP_STATE_ESTABLISHED   = 4,    // 连接已建立
    TCP_STATE_CLOSE_WAIT   = 5,    // 收到 FIN，等待应用关闭
    TCP_STATE_FIN_WAIT1    = 6,    // 已发 FIN，等待 ACK
    TCP_STATE_CLOSING      = 7,    // 同时关闭
    TCP_STATE_LAST_ACK     = 8,    // 等待最后的 ACK
    TCP_STATE_FIN_WAIT2    = 9,    // 收到 ACK，等待对方 FIN
    TCP_STATE_TIME_WAIT     = 10,   // 等待 2MSL 后关闭
};

static const char *tcp_state_str[] = {
    "CLOSED", "LISTEN", "SYN_SENT", "SYN_RCVD",
    "ESTABLISHED", "CLOSE_WAIT", "FIN_WAIT1", "CLOSING",
    "LAST_ACK", "FIN_WAIT2", "TIME_WAIT"
};
```

### 3.2 状态转换图

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           TCP 状态转换图                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│                                                                             │
│    CLOSED                                                               │   │
│       │                                                                  │   │
│       │ listen()                                                        │   │
│       ▼                                                                  │   │
│    LISTEN ───────┐                                                       │   │
│       │         │                                                       │   │
│       │ recv SYN│ send SYN+ACK                                          │   │
│       │         ▼                                                       │   │
│       │      SYN_RCVD ───┐                                              │   │
│       │         │        │                                              │   │
│       │         │ recv   │ send ACK                                     │   │
│       │         │ ACK    │                                              │   │
│       │         ▼        ▼                                              │   │
│       │      ESTABLISHED ◄──────┐                                        │   │
│       │         │               │                                        │   │
│       │         │               │                                        │   │
│       │         │ recv FIN      │ send FIN                               │   │
│       │         │ send ACK      │                                        │   │
│       │         ▼               │                                        │   │
│       │      CLOSE_WAIT         │                                        │   │
│       │         │               ▼                                        │   │
│       │         │            FIN_WAIT1 ────┬──────┐                    │   │
│       │         │               │          │      │                    │   │
│       │         │               │ recv     │      │ recv ACK           │   │
│       │         │               │ ACK      │      │                    │   │
│       │         │               ▼          │      ▼                    │   │
│       │         │            FIN_WAIT2     │   TIME_WAIT ──► CLOSED   │   │
│       │         │               │          │      ▲                   │   │
│       │         │               │          │      │                   │   │
│       │         │               │ recv     │      │ timeout            │   │
│       │         │               │ FIN      │      │ (2MSL)             │   │
│       │         │               │ send ACK │      │                   │   │
│       │         │               ▼          │      │                   │   │
│       │         │            CLOSING ───────┘      │                   │   │
│       │         │               │                 │                   │   │
│       │         │               │ recv ACK        │                   │   │
│       │         │               ▼                 │                   │   │
│       │         │            TIME_WAIT ───────────┘                   │   │
│       │         │               │                                       │   │
│       │         │               │ timeout                               │   │
│       │         │               │ (2MSL)                                │   │
│       │         │               ▼                                       │   │
│       │         │            CLOSED                                    │   │
│       │         │                                                     │   │
│       └─────────┘                                                     │   │
│                                                                             │
│    CLIENT:                                                               │   │
│    CLOSED ──► SYN_SENT ──► ESTABLISHED ──► FIN_WAIT1 ──► FIN_WAIT2 ──► │   │
│       ▲                                              │           │       │   │
│       └──────────────────────────────────────────────┘           │       │   │
│                                                     CLOSING       │       │   │
│                                                           ▼       │       │   │
│                                                        TIME_WAIT ─┘       │   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 3.3 连接控制块 (TCB)

```c
// TCP 连接控制块
struct tcp_conn {
    uint16_t local_port;          // 本地端口
    uint16_t remote_port;         // 远程端口
    uint32_t local_ip;            // 本地 IP
    uint32_t remote_ip;           // 远程 IP

    // 序列号
    uint32_t snd_nxt;             // 下一个要发送的序列号
    uint32_t snd_una;             // 最早未确认的序列号
    uint32_t snd_wnd;             // 发送窗口大小
    uint32_t snd_wnd_max;         // 最大发送窗口
    uint32_t snd_up;              // 发送紧急指针

    uint32_t rcv_nxt;             // 期望接收的下一个序列号
    uint32_t rcv_wnd;             // 接收窗口大小
    uint32_t rcv_wnd_max;         // 最大接收窗口（接收缓冲区大小）
    uint32_t rcv_up;              // 接收紧急指针

    // 状态
    enum tcp_state state;

    // 所属 listener（被动打开时）
    struct tcp_listener *listener;

    // 定时器
    struct rte_timer retransmit_timer;  // 重传定时器
    struct rte_timer keepalive_timer;   // 保活定时器
    struct rte_timer timewait_timer;    // TIME_WAIT 定时器

    // 性能参数
    uint16_t mss;                 // 最大段大小
    uint8_t  wscale;              // 窗口扩大因子
    uint32_t rtt;                 // 往返时间（微秒）
    uint32_t rttvar;              // RTT 偏差
    uint32_t srtt;                // 平滑 RTT
    uint32_t rto;                 // 重传超时（微秒）

    // 拥塞控制
    uint32_t cwnd;                // 拥塞窗口
    uint32_t ssthresh;            // 慢启动阈值
    uint8_t  cong_state;          // 拥塞状态
    uint32_t recovery_point;      // 快速恢复点
    uint32_t dup_ack_count;       // 重复 ACK 计数

    // 时间戳
    uint8_t  ts_on;               // 时间戳是否启用
    uint32_t ts_recent;           // 最近收到的时间戳
    uint32_t ts_lastack;          // 最后确认的时间戳

    // 发送缓冲区
    struct rte_mbuf *snd_buf;     // 待发送数据
    uint32_t snd_buf_len;

    // 接收缓冲区
    struct rte_mbuf *rcv_buf;     // 已接收数据
    uint32_t rcv_buf_len;

    // 关联的 socket（如果有）
    int socket_id;
};
```

---

## 4. 三次握手与连接建立

### 4.1 主动打开（客户端）

```c
// 主动打开连接
static struct tcp_conn *
tcp_conn_connect(uint32_t local_ip, uint16_t local_port,
                 uint32_t remote_ip, uint16_t remote_port)
{
    struct tcp_conn *conn = rte_malloc("tcp_conn", sizeof(struct tcp_conn), 0);
    if (!conn)
        return NULL;

    memset(conn, 0, sizeof(*conn));

    // 初始化连接
    conn->local_ip = local_ip;
    conn->local_port = local_port;
    conn->remote_ip = remote_ip;
    conn->remote_port = remote_port;

    // 初始序列号（使用随机数）
    conn->snd_nxt = rte_rand();
    conn->snd_una = conn->snd_nxt;
    conn->rcv_nxt = 0;

    conn->mss = 1460;  // 默认 MSS
    conn->wscale = 0;
    conn->state = TCP_STATE_SYN_SENT;

    // 发送 SYN（seq=snd_nxt, ack=0, 无数据）
    send_tcp_segment(conn, RTE_TCP_SYN_FLAG, conn->snd_nxt, 0, NULL, 0);

    // 启动重传定时器
    rte_timer_reset(&conn->retransmit_timer,
                    RTE_TIMER_PER_SEC,    // 1 秒后触发
                    SINGLE,
                    rte_lcore_id(),
                    retransmit_callback,
                    conn);

    return conn;
}

// 发送 TCP 段
static int
send_tcp_segment(struct tcp_conn *conn,
                 uint8_t flags,
                 uint32_t seq, uint32_t ack,
                 const void *data, uint16_t len)
{
    uint8_t opt_len = 0;

    // 计算选项长度（SYN 段携带 MSS + WSCALE + TIMESTAMP）
    if (flags & RTE_TCP_SYN_FLAG) {
        opt_len = 4 + 3 + 1 + 2 + 10;  // MSS(4) + NOP(1)+WSCALE(3) + NOP(2)+TS(10)
        // 对齐到 4 字节: 4+4+12 = 20 → 已对齐
    }

    uint16_t tcp_hdr_len = sizeof(struct rte_tcp_hdr) + opt_len;
    uint16_t pkt_len = sizeof(struct rte_ether_hdr) + sizeof(struct rte_ipv4_hdr)
                     + tcp_hdr_len + len;

    struct rte_mbuf *m = rte_pktmbuf_alloc(mbuf_pool);
    if (!m)
        return -1;

    rte_pktmbuf_append(m, pkt_len);

    // 准备头部空间
    struct rte_ether_hdr *eth = rte_pktmbuf_mtod(m, struct rte_ether_hdr *);
    struct rte_ipv4_hdr *ip = (struct rte_ipv4_hdr *)(eth + 1);
    struct rte_tcp_hdr *tcp = (struct rte_tcp_hdr *)(ip + 1);

    // Ethernet
    eth->ether_type = rte_cpu_to_be_16(RTE_ETHER_TYPE_IPV4);
    // ... 设置 MAC 地址

    // IPv4
    ip->version_ihl = (4 << 4) | 5;
    ip->type_of_service = 0;
    ip->total_length = rte_cpu_to_be_16(sizeof(struct rte_ipv4_hdr) + tcp_hdr_len + len);
    ip->packet_id = 0;
    ip->fragment_offset = 0;
    ip->time_to_live = 64;                              // TTL 必须设置
    ip->next_proto_id = IPPROTO_TCP;
    ip->src_addr = conn->local_ip;
    ip->dst_addr = conn->remote_ip;
    ip->hdr_checksum = 0;                               // 留零，NIC 计算

    // TCP
    tcp->src_port = rte_cpu_to_be_16(conn->local_port);
    tcp->dst_port = rte_cpu_to_be_16(conn->remote_port);
    tcp->sent_seq = rte_cpu_to_be_32(seq);
    tcp->recv_ack = rte_cpu_to_be_32(ack);
    tcp->data_off = ((tcp_hdr_len / 4) << 4);           // 数据偏移（单位 4 字节）
    tcp->tcp_flags = flags;
    tcp->rx_win = rte_cpu_to_be_16(conn->rcv_wnd);
    tcp->cksum = 0;                                     // 留零，NIC 计算

    // 填写 TCP 选项
    if (flags & RTE_TCP_SYN_FLAG) {
        uint8_t *opt = (uint8_t *)(tcp + 1);

        // MSS 选项 (4 bytes)
        opt[0] = TCP_OPT_MSS;
        opt[1] = 4;
        *(uint16_t *)(opt + 2) = rte_cpu_to_be_16(conn->mss);

        // NOP + WSCALE 选项 (4 bytes)
        opt[4] = TCP_OPT_NOP;
        opt[5] = TCP_OPT_WSCALE;
        opt[6] = 3;
        opt[7] = 0;  // 无窗口扩大（简化）

        // NOP + NOP + TIMESTAMP 选项 (12 bytes)
        opt[8]  = TCP_OPT_NOP;
        opt[9]  = TCP_OPT_NOP;
        opt[10] = TCP_OPT_TIMESTAMP;
        opt[11] = 10;
        // 使用 TSC 转换为毫秒级时间戳
        uint64_t ts_ms = rte_rdtsc() / (rte_get_tsc_hz() / 1000);
        *(uint32_t *)(opt + 12) = rte_cpu_to_be_32((uint32_t)ts_ms);
        *(uint32_t *)(opt + 16) = rte_cpu_to_be_32(conn->ts_recent);
    }

    // 复制数据（从选项之后的位置开始，避免覆盖选项）
    if (data && len > 0) {
        rte_memcpy((uint8_t *)(tcp + 1) + opt_len, data, len);
    }

    // 设置 offload flags
    m->ol_flags |= RTE_MBUF_F_TX_IPV4
                 | RTE_MBUF_F_TX_IP_CKSUM
                 | RTE_MBUF_F_TX_TCP_CKSUM;
    m->l2_len = sizeof(struct rte_ether_hdr);
    m->l3_len = sizeof(struct rte_ipv4_hdr);
    m->l4_len = tcp_hdr_len;

    // 发送
    return rte_eth_tx_burst(port_id, queue_id, &m, 1);
}
```

### 4.2 被动打开（服务器）

```c
// 服务器监听
struct tcp_listener {
    uint16_t port;
    struct rte_ring *accept_queue;   // 已完成的连接
    struct rte_hash *conn_table;     // 连接表（5-tuple -> conn）
};

// 创建监听
static struct tcp_listener *
tcp_listen(uint16_t port)
{
    struct tcp_listener *l = rte_malloc("tcp_listener", sizeof(*l), 0);
    memset(l, 0, sizeof(*l));

    l->port = port;
    l->accept_queue = rte_ring_create("accept_q", 1024, SOCKET_ID_ANY, 0);
    l->conn_table = create_conn_table();

    return l;
}

// 处理入站 SYN
static void
handle_syn(struct rte_mbuf *m,
           struct rte_ipv4_hdr *ip,
           struct rte_tcp_hdr *tcp,
           struct tcp_listener *listener)
{
    uint32_t remote_ip = ip->src_addr;
    uint32_t local_ip = ip->dst_addr;
    uint16_t remote_port = rte_be_to_cpu_16(tcp->src_port);
    uint16_t local_port = rte_be_to_cpu_16(tcp->dst_port);

    // 检查是否是我们的监听端口
    if (local_port != listener->port)
        return;

    // 创建新连接
    struct tcp_conn *conn = rte_malloc("tcp_conn", sizeof(struct tcp_conn), 0);
    memset(conn, 0, sizeof(*conn));

    conn->local_ip = local_ip;
    conn->local_port = local_port;
    conn->remote_ip = remote_ip;
    conn->remote_port = remote_port;
    conn->rcv_nxt = rte_be_to_cpu_32(tcp->sent_seq) + 1;
    conn->snd_nxt = rte_rand();
    conn->snd_una = conn->snd_nxt;
    conn->state = TCP_STATE_SYN_RECEIVED;

    // 解析 TCP 选项获取 MSS
    parse_tcp_options_in_syn(tcp, conn);

    // 添加到连接表
    add_to_conn_table(listener->conn_table, conn);

    // 发送 SYN+ACK
    send_tcp_segment(conn, RTE_TCP_SYN_FLAG | RTE_TCP_ACK_FLAG,
                     conn->snd_nxt, conn->rcv_nxt, NULL, 0);
    conn->snd_nxt++;  // SYN 消耗一个序号
}
```

### 4.3 三次握手状态机

```c
// 处理入站 TCP 段
static void
tcp_input(struct tcp_conn *conn, struct rte_mbuf *m,
          struct rte_tcp_hdr *tcp)
{
    uint32_t seq = rte_be_to_cpu_32(tcp->sent_seq);
    uint32_t ack = rte_be_to_cpu_32(tcp->recv_ack);
    uint8_t flags = tcp->tcp_flags;

    switch (conn->state) {
    case TCP_STATE_SYN_SENT:
        if ((flags & RTE_TCP_ACK_FLAG) && (flags & RTE_TCP_SYN_FLAG)) {
            // 收到 SYN+ACK
            conn->rcv_nxt = seq + 1;
            conn->snd_una = ack;
            conn->state = TCP_STATE_ESTABLISHED;

            // 停止 SYN 重传定时器
            rte_timer_stop(&conn->retransmit_timer);

            // 发送 ACK
            send_ack(conn);

            // 通知应用连接已建立
            notify_connected(conn);
        } else if ((flags & RTE_TCP_ACK_FLAG) && !(flags & RTE_TCP_SYN_FLAG)) {
            // 收到纯 ACK（SYN+ACK 丢失，只收到对端的 ACK）
            if (ack > conn->snd_una) {
                conn->snd_una = ack;
                conn->state = TCP_STATE_ESTABLISHED;
                notify_connected(conn);
            }
        }
        break;

    case TCP_STATE_SYN_RECEIVED:
        if (flags & RTE_TCP_ACK_FLAG) {
            // 收到第三次握手的 ACK
            if (ack >= conn->snd_una) {
                conn->snd_una = ack;
                conn->state = TCP_STATE_ESTABLISHED;

                // 将连接放入 accept 队列
                rte_ring_enqueue(conn->listener->accept_queue, conn);
            }
        }
        break;

    case TCP_STATE_ESTABLISHED:
        // 正常数据传输
        handle_data(conn, m, tcp, seq, flags);
        break;

    // ... 其他状态处理
    }
}
```

---

## 5. 滑动窗口机制

### 5.1 发送窗口

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           TCP 发送窗口                                       │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  已确认        已发送未确认           可发送                不可发送           │
│    │               │                   │                    │                │
│    ▼               ▼                   ▼                    ▼                │
│ ┌─────┬───────────┬───────────────────┬────────────────────┐               │
│ │     │           │                   │                    │               │
│ │ SND │  SND.NXT  │    SND.UNA        │     SND.WND        │               │
│ │ .UNA│           │                   │                    │               │
│ └─────┴───────────┴───────────────────┴────────────────────┘               │
│     0           1000          2000                  3000          4000     │
│                                                                             │
│  SND.UNA: 最早未确认的序列号                                                │
│  SND.NXT: 下一个要发送的序列号                                               │
│  SND.WND: 发送窗口大小                                                      │
│                                                                             │
│  可用窗口 = SND.UNA + SND.WND - SND.NXT                                    │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 5.2 接收窗口

```c
// 滑动窗口管理
struct tcp_window {
    uint32_t rcv_nxt;             // 期望收到的下一个序列号
    uint32_t rcv_wnd;             // 接收窗口大小
    uint32_t rcv_wnd_max;        // 最大窗口（接收缓冲区大小）

    // 接收缓冲区（有序数据）
    uint8_t *rcv_buf;
    uint32_t rcv_buf_len;
    uint32_t rcv_buf_used;

    // 失序队列
    struct rte_mbuf *out_of_order_queue;
};

// 更新接收窗口
static void
update_rcv_wnd(struct tcp_window *wnd)
{
    wnd->rcv_wnd = wnd->rcv_wnd_max - wnd->rcv_buf_used;

    // 窗口不能为零（Zero Window Problem）
    // 发送 ZWP (Zero Window Probe) 定期探测
}

// 检查是否可以接收数据
static int
can_accept_data(struct tcp_window *wnd, uint32_t seq, uint32_t len)
{
    uint32_t seq_end = seq + len;

    // 数据必须在窗口内
    if (seq < wnd->rcv_nxt) {
        // 重复数据（已接收）
        return 0;
    }

    if (seq > wnd->rcv_nxt + wnd->rcv_wnd) {
        // 超出窗口（不能接收）
        return 0;
    }

    return 1;  // 可以接收
}

// 接收数据
static int
receive_data(struct tcp_window *wnd, uint32_t seq,
             const uint8_t *data, uint32_t len)
{
    if (seq == wnd->rcv_nxt) {
        // 有序数据：直接放入接收缓冲区
        copy_to_rcv_buf(wnd, data, len);
        wnd->rcv_nxt += len;

        // 检查失序队列，看是否有数据可以交付
        deliver_ordered_data(wnd);
    } else {
        // 失序数据：放入失序队列
        add_to_out_of_order_queue(wnd, seq, data, len);
    }

    update_rcv_wnd(wnd);
    return 0;
}
```

### 5.3 窗口扩大因子

```c
// 窗口扩大因子（Window Scaling）
// RFC 7323

// 发送端：实际窗口 = rcv_wnd << wscale
static uint32_t
calculate_send_window(uint16_t rcv_wnd, uint8_t wscale)
{
    return ((uint32_t)rcv_wnd) << wscale;
}

// 设置窗口扩大因子
static void
tcp_enable_window_scaling(struct tcp_conn *conn)
{
    // 双方都需要在 SYN 时发送窗口扩大选项
    // 才能使用窗口扩大

    // 连接建立后，发送窗口按以下公式计算：
    // - 本端发送窗口 = 本端接收窗口 << 本端 wscale
    // - 对端发送窗口 = 对端接收窗口 << 本端 wscale

    conn->snd_wnd = conn->rcv_wnd << conn->wscale;
    conn->snd_wnd_max = conn->rcv_wnd_max << conn->wscale;
}
```

---

## 6. 拥塞控制

### 6.1 拥塞控制状态机

```c
// 拥塞控制状态
enum tcpCongState {
    TCP_CONG_OPEN,         // 正常拥塞控制
    TCP_CONG_DISORDER,     // 疑似拥塞（收到重复 ACK）
    TCP_CONG_CWR,          // 拥塞窗口已减小
    TCP_CONG_RECOVERY,     // 快速恢复
    TCP_CONG_LOSS,         // 超时导致的丢包
};

// 拥塞控制算法接口
struct tcp_cong_ops {
    void (*init)(struct tcp_conn *conn);
    void (*on_ack)(struct tcp_conn *conn, uint32_t ack_seq);
    void (*on_loss)(struct tcp_conn *conn);
    void (*on_timeout)(struct tcp_conn *conn);
    uint32_t (*cwnd)(struct tcp_conn *conn);
};
```

### 6.2 标准 TCP 拥塞控制

```c
// 标准 TCP 拥塞控制实现

// 初始化
static void
tcp_cong_init(struct tcp_conn *conn)
{
    conn->cwnd = TCP_INIT_CWND * conn->mss;       // 初始窗口
    conn->ssthresh = TCP_INFINITE_SSTHRESH;      // 初始阈值
    conn->cong_state = TCP_CONG_OPEN;
}

// 慢启动 (Slow Start)
static void
tcp_slow_start(struct tcp_conn *conn)
{
    // 每收到一个 ACK，cwnd 增加一个 MSS
    conn->cwnd += conn->mss;

    // 达到阈值后进入拥塞避免
    if (conn->cwnd >= conn->ssthresh) {
        conn->cong_state = TCP_CONG_OPEN;
    }
}

// 拥塞避免 (Congestion Avoidance)
static void
tcp_cong_avoid(struct tcp_conn *conn)
{
    // 每收到一个 ACK，cwnd 增加 MSS*MSS/cwnd
    uint32_t add = (conn->mss * conn->mss) / conn->cwnd;
    if (add < 1)
        add = 1;
    conn->cwnd += add;
}

// 收到 ACK 时的处理
static void
tcp_cong_on_ack(struct tcp_conn *conn, uint32_t ack_seq)
{
    if (ack_seq > conn->snd_una) {
        // 新的确认：有数据被确认，更新窗口
        conn->snd_una = ack_seq;
        conn->dup_ack_count = 0;  // 重置重复 ACK 计数

        if (conn->cong_state == TCP_CONG_RECOVERY) {
            // 快速恢复中，检查是否恢复完毕
            if (ack_seq >= conn->recovery_point) {
                conn->cong_state = TCP_CONG_OPEN;
            }
        }

        if (conn->cong_state == TCP_CONG_OPEN) {
            if (conn->cwnd < conn->ssthresh) {
                tcp_slow_start(conn);
            } else {
                tcp_cong_avoid(conn);
            }
        }
    } else if (ack_seq == conn->snd_una) {
        // 重复 ACK：没有新数据被确认
        conn->dup_ack_count++;
        tcp_fast_retransmit(conn, conn->dup_ack_count);
    }
}

// 快速重传
static void
tcp_fast_retransmit(struct tcp_conn *conn, uint32_t dup_acks)
{
    if (dup_acks >= 3 && conn->cong_state == TCP_CONG_OPEN) {
        // 触发快速重传
        // 不等超时，直接重传

        uint32_t flight = conn->snd_nxt - conn->snd_una;
        conn->ssthresh = flight / 2;
        if (conn->ssthresh < 2 * conn->mss)
            conn->ssthresh = 2 * conn->mss;

        conn->cwnd = conn->ssthresh + 3 * conn->mss;  // 3 个 dup ACKs
        conn->recovery_point = conn->snd_nxt;
        conn->cong_state = TCP_CONG_RECOVERY;

        retransmit_segment(conn);
    }
}

// 超时处理
static void
tcp_cong_on_timeout(struct tcp_conn *conn)
{
    // 超时说明可能有严重拥塞

    conn->ssthresh = conn->cwnd / 2;
    if (conn->ssthresh < 2 * conn->mss)
        conn->ssthresh = 2 * conn->mss;

    conn->cwnd = conn->mss;  // 回到初始窗口
    conn->cong_state = TCP_CONG_LOSS;

    // 重传最早的未确认段
    retransmit_segment(conn);
}
```

### 6.3 RTT 测量与 RTO 计算

```c
// RTT 测量
static void
tcp_update_rtt(struct tcp_conn *conn, uint32_t rtt_sample)
{
    if (conn->srtt == 0) {
        // 第一次测量
        conn->srtt = rtt_sample;
        conn->rttvar = rtt_sample / 2;
    } else {
        // 平滑 RTT
        conn->srtt = (7 * conn->srtt + rtt_sample) / 8;
        // RTT 偏差
        int32_t diff = rtt_sample - conn->srtt;
        if (diff < 0) diff = -diff;
        conn->rttvar = (3 * conn->rttvar + diff) / 4;
    }

    // RTO = srtt + 4 * rttvar
    conn->rto = conn->srtt + 4 * conn->rttvar;

    // RTO 边界
    if (conn->rto < TCP_RTO_MIN)
        conn->rto = TCP_RTO_MIN;
    if (conn->rto > TCP_RTO_MAX)
        conn->rto = TCP_RTO_MAX;
}

// 使用时间戳选项计算 RTT
static void
tcp_parse_timestamp_for_rtt(struct tcp_conn *conn, struct rte_tcp_hdr *tcp)
{
    if (!(tcp->tcp_flags & RTE_TCP_ACK_FLAG))
        return;

    uint8_t *opt = (uint8_t *)(tcp + 1);
    uint8_t opt_len = TCP_HEADER_LEN(tcp) - sizeof(struct rte_tcp_hdr);

    for (uint8_t i = 0; i < opt_len;) {
        if (opt[i] == TCP_OPT_TIMESTAMP) {
            uint32_t ts_val = rte_be_to_cpu_32(*(uint32_t *)(opt + i + 2));
            uint32_t ts_ecr = rte_be_to_cpu_32(*(uint32_t *)(opt + i + 6));

            // TS.Ecr 是对端对我们发送的 TS.Val 的回显
            // RTT = 本地当前时间 - TS.Ecr
            uint64_t now = rte_get_timer_cycles();
            uint32_t rtt = now - ts_ecr;

            tcp_update_rtt(conn, rtt);
            return;
        }

        if (opt[i] == TCP_OPT_NOP)
            i++;
        else if (opt[i] == TCP_OPT_END)
            break;
        else
            i += opt[i + 1] ? opt[i + 1] : 1;
    }
}
```

---

## 7. 连接关闭

### 7.1 四次挥手

```c
// 主动关闭连接
static void
tcp_conn_close(struct tcp_conn *conn)
{
    switch (conn->state) {
    case TCP_STATE_ESTABLISHED:
        // 发送 FIN
        send_tcp_segment(conn, RTE_TCP_FIN_FLAG | RTE_TCP_ACK_FLAG,
                         conn->snd_nxt, conn->rcv_nxt, NULL, 0);
        conn->snd_nxt++;
        conn->state = TCP_STATE_FIN_WAIT1;
        break;

    case TCP_STATE_CLOSE_WAIT:
        // 应用已经调用 close()
        send_tcp_segment(conn, RTE_TCP_FIN_FLAG | RTE_TCP_ACK_FLAG,
                         conn->snd_nxt, conn->rcv_nxt, NULL, 0);
        conn->snd_nxt++;
        conn->state = TCP_STATE_LAST_ACK;
        break;

    default:
        break;
    }
}

// 处理入站 FIN
static void
handle_fin(struct tcp_conn *conn, struct rte_tcp_hdr *tcp)
{
    uint8_t flags = tcp->tcp_flags;
    uint32_t seq = rte_be_to_cpu_32(tcp->sent_seq);
    uint32_t ack = rte_be_to_cpu_32(tcp->recv_ack);

    switch (conn->state) {
    case TCP_STATE_ESTABLISHED:
        // 收到对端的 FIN
        conn->rcv_nxt = seq + 1;
        send_ack(conn);

        // 通知应用对端关闭
        notify_peer_closed(conn);

        conn->state = TCP_STATE_CLOSE_WAIT;
        break;

    case TCP_STATE_FIN_WAIT1:
        conn->rcv_nxt = seq + 1;
        send_ack(conn);

        if (flags & RTE_TCP_ACK_FLAG) {
            // FIN + ACK → 直接进入 TIME_WAIT
            conn->snd_una = ack;
            conn->state = TCP_STATE_TIME_WAIT;
            start_timewait_timer(conn);
        } else {
            // FIN without ACK → CLOSING（同时关闭）
            conn->state = TCP_STATE_CLOSING;
        }
        break;

    case TCP_STATE_FIN_WAIT2:
        // 收到对端的 FIN，回复 ACK → TIME_WAIT
        conn->rcv_nxt = seq + 1;
        send_ack(conn);

        conn->state = TCP_STATE_TIME_WAIT;
        start_timewait_timer(conn);
        break;

    case TCP_STATE_CLOSING:
        // 同时关闭：收到 ACK → TIME_WAIT
        conn->snd_una = ack;
        conn->rcv_nxt = seq + 1;
        send_ack(conn);

        conn->state = TCP_STATE_TIME_WAIT;
        start_timewait_timer(conn);
        break;

    case TCP_STATE_LAST_ACK:
        // 收到最后的 ACK → CLOSED
        conn->snd_una = ack;
        conn->state = TCP_STATE_CLOSED;
        destroy_conn(conn);
        break;
    }
}

// TIME_WAIT 定时器
static void
timewait_callback(struct rte_timer *tm, void *arg)
{
    struct tcp_conn *conn = arg;
    conn->state = TCP_STATE_CLOSED;
    destroy_conn(conn);
}
```

---

## 8. TCP Socket 封装

### 8.1 基本 Socket API

```c
// 简化的 TCP Socket API 封装
struct tcp_socket {
    struct tcp_conn *conn;        // 连接（如果是客户端或已连接）
    struct tcp_listener *listener; // 监听者（如果是服务器）

    int role;  // 0 = 未初始化, 1 = client, 2 = server
};

// 创建 socket
struct tcp_socket *tcp_socket(void)
{
    struct tcp_socket *s = rte_malloc("tcp_socket", sizeof(*s), 0);
    memset(s, 0, sizeof(*s));
    return s;
}

// 绑定
int tcp_bind(struct tcp_socket *s, uint16_t port)
{
    if (s->role == 0) {
        s->listener = tcp_listen(port);
        s->role = 2;
    }
    return 0;
}

// 监听
int tcp_listen_on(struct tcp_socket *s, int backlog)
{
    // backlog = pending 连接队列长度
    return 0;
}

// 接受连接
struct tcp_socket *tcp_accept(struct tcp_socket *s)
{
    struct tcp_conn *conn;
    if (rte_ring_dequeue(s->listener->accept_queue, (void **)&conn) == 0) {
        struct tcp_socket *new_s = tcp_socket();
        new_s->conn = conn;
        new_s->role = 1;
        return new_s;
    }
    return NULL;
}

// 连接
int tcp_connect(struct tcp_socket *s, uint32_t ip, uint16_t port)
{
    s->conn = tcp_conn_connect(local_ip, local_port, ip, port);
    s->role = 1;
    // 等待连接建立（可能需要非阻塞轮询）
    return 0;
}

// 发送
ssize_t tcp_send(struct tcp_socket *s, const void *buf, size_t len)
{
    // 检查 snd_wnd 是否有空间
    // 将数据放入发送缓冲区
    // 触发发送
}

// 接收
ssize_t tcp_recv(struct tcp_socket *s, void *buf, size_t len)
{
    // 从 rcv_buf 复制数据到用户 buf
}

// 关闭
int tcp_close(struct tcp_socket *s)
{
    if (s->conn) {
        tcp_conn_close(s->conn);
    }
    rte_free(s);
}
```

---

## 9. 性能优化

### 9.1 批量处理

```c
// 批量接收 TCP 段
static void
tcp_recv_batch(struct rte_mbuf **pkts, uint16_t nb_pkts)
{
    for (int i = 0; i < nb_pkts; i++) {
        struct rte_mbuf *m = pkts[i];
        struct rte_ether_hdr *eth = rte_pktmbuf_mtod(m, struct rte_ether_hdr *);
        struct rte_ipv4_hdr *ip = (struct rte_ipv4_hdr *)(eth + 1);
        struct rte_tcp_hdr *tcp = (struct rte_tcp_hdr *)(ip + 1);

        // 查找对应的连接
        struct tcp_conn *conn = find_conn(ip->src_addr, tcp->src_port,
                                           ip->dst_addr, tcp->dst_port);
        if (conn) {
            tcp_input(conn, m, tcp);
        }
    }
}

// 批量发送
static uint16_t
tcp_send_batch(struct tcp_conn **conns, uint16_t nb_conns)
{
    struct rte_mbuf *pkts[32];  // 批量大小

    for (int i = 0; i < nb_conns && i < 32; i++) {
        pkts[i] = prepare_tcp_segment(conns[i]);
    }

    return rte_eth_tx_burst(port_id, queue_id, pkts, nb_conns);
}
```

### 9.2 连接表优化

```c
// 使用 DPDK rte_hash 做 5-tuple 查找
static struct rte_hash *
create_conn_table(void)
{
    struct rte_hash_parameters params = {
        .name = "tcp_conn_table",
        .entries = 65536,           // 最大连接数
        .key_len = sizeof(struct tcp_flow_key),
        .hash_func = rte_jhash,
        .socket_id = SOCKET_ID_ANY,
    };

    return rte_hash_create(&params);
}

// 5-tuple key
struct tcp_flow_key {
    uint32_t src_ip;
    uint32_t dst_ip;
    uint16_t src_port;
    uint16_t dst_port;
    uint8_t  proto;
};

// 快速查找连接
static struct tcp_conn *
lookup_conn(struct rte_hash *tbl, struct rte_ipv4_hdr *ip, struct rte_tcp_hdr *tcp)
{
    struct tcp_flow_key key = {
        .src_ip = ip->src_addr,
        .dst_ip = ip->dst_addr,
        .src_port = rte_be_to_cpu_16(tcp->src_port),
        .dst_port = rte_be_to_cpu_16(tcp->dst_port),
        .proto = IPPROTO_TCP,
    };

    int32_t ret = rte_hash_lookup(tbl, &key);
    if (ret >= 0)
        return conn_table[ret];

    return NULL;
}
```

---

## 10. 小结

本章核心要点：

1. **TCP 头部结构**：源/目端口、序列号、确认号、偏移+保留+flags、窗口、校验和、紧急指针、选项。

2. **TCP 选项**：MSS（最大段大小）、WSCALE（窗口扩大）、TIMESTAMP（时间戳）、SACK（选择确认）。

3. **连接状态机**：CLOSED → LISTEN → SYN_RCVD → ESTABLISHED → CLOSE_WAIT → ... 以及客户端的 SYN_SENT 路径。

4. **三次握手**：主动端发 SYN(SYN_SENT) → 被动端回 SYN+ACK(SYN_RCVD) → 主动端回 ACK(ESTABLISHED)。

5. **滑动窗口**：SND.UNA/SND.NXT/SND.WND 跟踪发送状态，RCV.NXT/RCV.WND 跟踪接收状态。

6. **拥塞控制**：慢启动（cwnd += MSS）、拥塞避免（cwnd += MSS*MSS/cwnd）、快速重传（3 dup ACKs）、超时回退。

7. **RTT 测量**：使用时间戳选项精确测量，RTO = SRTT + 4*RTTVAR。

8. **四次挥手**：FIN_WAIT1 → FIN_WAIT2 → TIME_WAIT → CLOSED。

9. **Socket 封装**：bind/listen/accept/connect/send/recv/close。

10. **性能优化**：批量处理、rte_hash 连接表查找。

**下一篇预告**：[[2026-04-09-dpdk-deep-dive-ch13-gro-gso|第十三章]]将讲解 GRO/GSO 通用卸载——将多个小包合并成大包（GRO）或将一个大包拆分成多个小包（GSO）。

---

> [!tip] 参考文献
> - RFC 793, "Transmission Control Protocol"
> - RFC 2581, "TCP Congestion Control"
> - RFC 7323, "TCP Extensions for High Speed"
> - RFC 9293, "TCP"
