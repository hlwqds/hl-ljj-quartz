---
title: "DPDK 深度探索 (十三)：GRO/GSO 通用卸载机制"
date: 2026-04-09
tags: [dpdk, series, gro, gso, generic-reassembly, generic-segmentation, offload, batch-processing]
description: "深入理解 GRO/GSO 通用卸载——将多个小包合并成大包（GRO）减少处理开销，或将大包拆分成小包（GSO）适配 MTU 限制"
---

> [!info] DPDK 深度探索系列 0. [[2026-04-09-dpdk-deep-dive-series-index|全栈学习路径总览]]
> 1-12. 前十二章已完成 13. **第十三章：GRO/GSO 通用卸载机制**

---

## 1. 概述：为什么需要 GRO/GSO？

### 1.1 小包问题

网络中小包（小于 MTU）会导致严重的性能问题：

| 问题                | 影响                                          |
| ------------------- | --------------------------------------------- |
| **协议栈处理开销**  | 每个包都要经过 ETH/IP/TCP header 解析         |
| **Header 处理占比** | 64 字节包，Header 占 40+ 字节（>60%）         |
| **Cache 效率低**    | 每个包独立处理，header 解析无法有效利用 Cache |
| **per-packet 开销** | mbuf 分配、hash 查找、flow 表匹配等固定成本   |

### 1.2 GRO 是硬件做的还是软件做的？

GRO 是纯软件，不要和硬件 LRO 混淆：

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  硬件 LRO vs 软件 GRO                                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  硬件 LRO (Large Receive Offload)                                           │
│  ────────────────────────────────                                           │
│                                                                             │
│  NIC 芯片内部合并，CPU 完全不参与：                                          │
│                                                                             │
│  网线 → NIC 芯片(合并) → DMA → 驱动 → 内核/应用                           │
│              ↑                                                              │
│           硬件在这里做合并                                                     │
│                                                                             │
│  问题：硬件不理解协议语义，可能合并不该合并的包                              │
│        导致 checksum 错误、TCP 状态混乱。Linux 默认关闭硬件 LRO。            │
│                                                                             │
│  软件 GRO (Generic Receive Offload)                                         │
│  ────────────────────────────────                                           │
│                                                                             │
│  CPU 在软件里合并，完全理解协议语义：                                        │
│                                                                             │
│  网线 → NIC → DMA → mbuf[0] ─┐                                           │
│  网线 → NIC → DMA → mbuf[1] ─┼─► GRO 函数(CPU) → 合并后的 mbuf           │
│  网线 → NIC → DMA → mbuf[2] ─┘                                               │
│                               ↑                                              │
│                         CPU 在这里做合并                                   │
│                                                                             │
│  优势：检查 seq/ack/flags，只合并安全的纯数据段。                            │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

DPDK 全程无内核、无 skb，数据路径只有 mbuf：

```
  NIC DMA → mbuf → rte_eth_rx_burst() → GRO(软件合并 mbuf) → 应用处理
```

### 1.3 DPDK 里 GRO 的收益在哪里？

Linux 内核用 GRO 是为了减少内核协议栈的函数调用。DPDK 本来就绕过了内核，所以收益不同：

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  Linux GRO 的收益（内核协议栈太重）                                          │
│                                                                             │
│  不用 GRO：每个包都走 ip_rcv → tcp_v4_rcv → ...（几十次函数调用）           │
│  用了 GRO：10 个包合并成 1 个，只走 1 次 → 省掉 90% 内核函数调用           │
├─────────────────────────────────────────────────────────────────────────────┤
│  DPDK GRO 的收益（没有内核，但仍有固定开销）                                  │
│                                                                             │
│  每个包不管多大，都要做这些固定操作：                                         │
│  ┌────────────────────────────────────────────────────────────────────┐     │
│  │  1. rte_pktmbuf_mtod() 读取 header                                │     │
│  │  2. 解析 ETH → IP → TCP（3 次指针运算 + 字节序转换）             │     │
│  │  3. rte_hash_lookup() 做 5-tuple 查找                           │     │
│  │  4. 取 payload 指针                                             │     │
│  └────────────────────────────────────────────────────────────────────┘     │
│                                                                             │
│  这些操作不管包是 64B 还是 1460B，开销一样。                               │
│  GRO 把 10 个 200B 小包合并，省了 9 次 header 解析 + 9 次 hash 查找。      │
│                                                                             │
│  具体场景：                                                                  │
│  - 小包多的场景（HTTP 短请求、大量短连接）：收益大                          │
│  - 大包为主（1460B 满载）：收益很小，可以不开                              │
│  - 转发/网关：合并后一次查路由、一次转发                                    │
│  - DPI/IDS：大包更容易匹配完整 payload 模式                                │
│  - KNI 回灌内核：减少向内核注入的包数                                      │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 1.4 GRO flush 时机

GRO 不会无限等待合并，有两种触发条件决定何时把已合并的数据下发给应用：

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  GRO flush 的触发条件                                                       │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  1. 超时强制 flush（典型值 1~10ms）                                        │
│                                                                             │
│     flow 创建后开始计时，超时就输出已合并的包。                              │
│     不能无限等下去，否则延迟越来越大。                                      │
│                                                                             │
│     pkt1(t=0) ── pkt2(t=0.1ms) ── pkt3(t=0.3ms) ── ... ── timeout(5ms)│
│       └────────────────┬─────────────────────────────────┘                  │
│                        ▼                                                     │
│                    输出合并包                                               │
│                                                                             │
│  2. 合并条件不满足时立即 flush                                                │
│                                                                             │
│     新包和 flow 最后一个包无法合并：                                        │
│                                                                             │
│     pkt1: seq=100, len=200  ┐                                              │
│     pkt2: seq=300, len=200  ├─► 合并中                                     │
│     pkt3: seq=600, len=200  ← seq 跳过了 500，不连续！                     │
│       │                                                                     │
│       ▼                                                                     │
│     flush [pkt1+pkt2]，pkt3 成为新 flow 的首包                              │
│                                                                             │
│  其他触发条件：                                                              │
│  ────────────────────────────────────────────────────────────────────        │
│     - ACK 号变了（对端窗口变化）→ flush                                    │
│     - TCP flags 不一致 → flush                                             │
│     - 达到 flow 最大包数限制 → flush                                       │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 1.5 GRO 合并条件详解

GRO 只合并"连接建立后的纯数据段"，任何涉及窗口协商或连接状态变化的包都不合并：

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  为什么 SYN/FIN/RST 不能合并？                                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  SYN 携带三个"一次性"信息，合并后会丢失：                                   │
│                                                                             │
│  1. Window Scale 选项（只在 SYN 中协商一次）                                │
│     → rx_win 实际值 = rx_win << wscale                                     │
│     → 合并后 rx_win 取了数据包的值，窗口计算全错                             │
│     → 发送端以为接收窗口很小，吞吐量崩塌                                    │
│                                                                             │
│  2. SYN 占一个序列号（RFC 规定 SYN = 1 byte）                              │
│                                                                             │
│     客户端 ISN=100，服务端 ISN=300：                                        │
│     SYN(seq=100) → 下一个包从 101 开始                                     │
│     如果合并了 SYN 和 DATA(seq=101)，接收端按 seq=100 处理 200 字节          │
│     → 100 那个位置是 SYN 不是数据，payload 少了 1 字节                      │
│                                                                             │
│  3. MSS 选项（只在 SYN 中协商）                                             │
│                                                                             │
│  FIN 同理：占一个序列号，且表示连接关闭，必须立即处理。                      │
│  RST 同理：必须立即终止连接，不能延迟。                                     │
│                                                                             │
│  实际触发场景（防御性校验）：                                                │
│  ──────────────────────────────────────                                       │
│  - SYN 重传：第一个 SYN 丢了，重传 SYN 和数据包混在同一个 burst 里             │
│  - 网络乱序：迟到的 SYN 混入已建立连接的数据流                              │
│  - SYN Flood：大量伪造 SYN 和正常流量混在一起                                │
│                                                                             │
│  正常情况下 GRO 不会看到 SYN，检查是防止这些边界情况。                      │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 1.6 GRO vs GSO

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            GRO vs GSO                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  GRO (Generic Receive Offload)                                            │
│  ──────────────────────────────                                            │
│                                                                             │
│  接收方向：将多个同源小包合并成一个大包                                       │
│                                                                             │
│   packet[1]: TCP(src=80, seq=100, len=200)  ──┐                           │
│   packet[2]: TCP(src=80, seq=300, len=200)  ──┼──► merged TCP(len=600)     │
│   packet[3]: TCP(src=80, seq=500, len=200)  ──┘       seq=100             │
│                                                                             │
│   好处：减少协议栈处理次数 + 降低 per-packet 固定开销                          │
│                                                                             │
│  GSO (Generic Segmentation Offload)                                       │
│  ───────────────────────────────                                           │
│                                                                             │
│  发送方向：将一个大包拆分成多个小包                                         │
│                                                                             │
│   large TCP(len=9000) ──► packet[1](len=1460)                               │
│                      ──► packet[2](len=1460)                               │
│                      ──► packet[3](len=1460)                               │
│                      ──► packet[4](len=1460)                               │
│                      ──► packet[5](len=1200)                               │
│                                                                             │
│   好处：应用一次发送大数据，NIC 自动分片                                     │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 1.3 GRO/GSO 在 DPDK 中的位置

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         GRO/GSO 处理流程                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  接收方向 (GRO)                                                             │
│  ─────────────                                                             │
│                                                                             │
│  NIC ──► PMD Rx ──► Flow Classification ──► GRO Engine ──► App              │
│                    (RSS/FDIR)                    (合并后的大包)            │
│                                                                             │
│  发送方向 (GSO)                                                             │
│  ─────────────                                                             │
│                                                                             │
│  App ──► GSO Engine ──► PMD Tx ──► NIC                                     │
│         (拆分大包)         (多个小包)                                       │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. GRO 详解

### 2.1 GRO 工作原理

```c
// GRO 基本思想：
// 1. 相同 flow 的包（相同的 src_ip, dst_ip, src_port, dst_port, protocol）
// 2. 序列号连续（seq[i+1] == seq[i] + len[i]）
// 3. 可以合并到一个大的 mbuf chain 中

struct gro_key {
    uint32_t src_ip;
    uint32_t dst_ip;
    uint16_t src_port;
    uint16_t dst_port;
    uint8_t  proto;
};

// 合并条件
static int
can_merge(struct rte_mbuf *pkt1, struct rte_mbuf *pkt2)
{
    struct rte_ipv4_hdr *ip1 = get_ipv4_header(pkt1);
    struct rte_ipv4_hdr *ip2 = get_ipv4_header(pkt2);

    // TCP?
    if (ip1->next_proto_id == IPPROTO_TCP) {
        struct rte_tcp_hdr *tcp1 = get_tcp_header(pkt1);
        struct rte_tcp_hdr *tcp2 = get_tcp_header(pkt2);

        // GRO 只合并纯 ACK 数据段，拒绝 SYN/FIN/RST
        if (tcp1->tcp_flags & (RTE_TCP_SYN_FLAG | RTE_TCP_FIN_FLAG | RTE_TCP_RST_FLAG))
            return 0;
        if (tcp2->tcp_flags & (RTE_TCP_SYN_FLAG | RTE_TCP_FIN_FLAG | RTE_TCP_RST_FLAG))
            return 0;

        // 序列号连续：pkt2 的起始 seq == pkt1 的结束 seq（即 seq + payload_len）
        uint32_t seq1_end = rte_be_to_cpu_32(tcp1->sent_seq) +
                            rte_be_to_cpu_16(ip1->total_length) -
                            sizeof(struct rte_ipv4_hdr) -
                            sizeof(struct rte_tcp_hdr);
        uint32_t seq2 = rte_be_to_cpu_32(tcp2->sent_seq);

        // ACK 相同
        uint32_t ack1 = rte_be_to_cpu_32(tcp1->recv_ack);
        uint32_t ack2 = rte_be_to_cpu_32(tcp2->recv_ack);

        // TCP flags 相同（除了 PSH）
        uint8_t flags_mask = RTE_TCP_URG_FLAG | RTE_TCP_ACK_FLAG | RTE_TCP_PSH_FLAG;
        if ((tcp1->tcp_flags & flags_mask) != (tcp2->tcp_flags & flags_mask))
            return 0;

        return (seq2 == seq1_end) && (ack1 == ack2);
    }

    // UDP - 简化处理，只检查是否同源
    return ip1->src_addr == ip2->src_addr &&
           ip1->dst_addr == ip2->dst_addr;
}
```

### 2.2 GRO 表结构

```c
// GRO 表 - 存储待合并的 flow
#define GRO_MAX_FLOWS  16384
#define GRO_MAX_PKTS_PER_FLOW  64

struct gro_flow {
    struct gro_key key;

    // 合并后的数据
    struct rte_mbuf *head;     // 第一个包
    struct rte_mbuf *tail;     // 最后一个包
    uint16_t pkt_cnt;          // 包数量
    uint32_t total_len;        // 合并后总长度

    // TCP 序列号信息
    uint32_t seq;
    uint32_t ack;
    uint32_t last_seq;        // 最后一个包的序列号

    // 定时器（超时 flush）
    uint64_t created_at;
    uint32_t timeout_ms;

    // IPv4 ID
    uint16_t ip_id;

    // 活跃标志
    uint8_t active;
};

// GRO 引擎
struct gro_engine {
    struct gro_flow *flows;
    struct rte_hash *flow_table;  // key -> flow index
    uint32_t flow_count;

    // 配置
    uint32_t max_flows;
    uint16_t max_pkt_per_flow;
    uint32_t timeout_ms;
};
```

### 2.3 GRO 合并算法

```c
// 合并两个 TCP 包：将 pkt2 的数据追加到 pkt1（head）的 mbuf chain
// 注意：始终在 flow->head 上更新 IP/TCP 头部，因为头部只在第一个包上
static void
merge_two_tcp_packets(struct rte_mbuf *head, struct rte_mbuf *pkt)
{
    struct rte_ipv4_hdr *ip_head = get_ipv4_header(head);
    struct rte_tcp_hdr *tcp_head = get_tcp_header(head);
    struct rte_ipv4_hdr *ip_pkt = get_ipv4_header(pkt);
    struct rte_tcp_hdr *tcp_pkt = get_tcp_header(pkt);

    uint16_t tcp_hdr_len = (tcp_head->data_off >> 4) * 4;
    uint16_t data_len_pkt = rte_be_to_cpu_16(ip_pkt->total_length) -
                            sizeof(struct rte_ipv4_hdr) - tcp_hdr_len;

    // 1. 用 rte_pktmbuf_chain 正确维护 pkt_len / nb_segs
    rte_pktmbuf_chain(head, pkt);

    // 2. 更新 IP total_length（在 head 的头部上）
    uint16_t old_len = rte_be_to_cpu_16(ip_head->total_length);
    ip_head->total_length = rte_cpu_to_be_16(old_len + data_len_pkt);

    // 3. TCP seq 不变（保留第一个包的起始序列号）
    //    TCP flags: 保留最后一个包的 flags（如 PSH）
    tcp_head->tcp_flags = tcp_pkt->tcp_flags;

    // 4. IP header checksum 需要重新计算
    ip_head->hdr_checksum = 0;
    ip_head->hdr_checksum = ipv4_checksum(ip_head);

    // 5. TCP checksum 需要重新计算
    tcp_head->cksum = 0;
    tcp_head->cksum = tcp_checksum(ip_head, tcp_head);
}

// GRO 主循环
static void
gro_process(struct gro_engine *eng, struct rte_mbuf *pkt)
{
    struct gro_key key;
    extract_key(pkt, &key);

    // 查找或创建 flow
    int32_t idx = rte_hash_lookup(eng->flow_table, &key);
    struct gro_flow *flow;

    if (idx < 0) {
        // 新 flow
        idx = alloc_flow(eng);
        flow = &eng->flows[idx];
        init_flow(flow, &key, pkt);
        rte_hash_add_key(eng->flow_table, &key, &idx);
    } else {
        flow = &eng->flows[idx];

        // 检查是否超时（超时先 flush）
        if (get_time_ms() - flow->created_at > flow->timeout_ms) {
            gro_flush_flow(eng, flow);
            init_flow(flow, &key, pkt);
            return;
        }

        // 检查是否可以合并（用 flow->head 的头部做对比）
        if (can_merge(flow->head, pkt)) {
            // 始终合并到 flow->head，保证头部更新正确
            merge_two_tcp_packets(flow->head, pkt);
            flow->pkt_cnt++;
            flow->total_len += get_data_len(pkt);
            flow->tail = pkt;  // tail 记录最后一个 segment
            // 注意：不要 free(pkt)，它已通过 rte_pktmbuf_chain 链入 head
        } else {
            // 不能合并，flush 当前 flow 再重新开始
            gro_flush_flow(eng, flow);
            init_flow(flow, &key, pkt);
        }
    }
}

// flush 一个 flow，输出合并后的包
static void
gro_flush_flow(struct gro_engine *eng, struct gro_flow *flow)
{
    if (flow->pkt_cnt > 0 && flow->head) {
        enqueue_output(flow->head);
    }

    flow->pkt_cnt = 0;
    flow->head = NULL;
    flow->tail = NULL;
    flow->total_len = 0;
}
```

### 2.4 GRO 超时处理

```c
// GRO 定时 flush（需要定期调用）
static void
gro_timeout(struct gro_engine *eng)
{
    uint64_t now = get_time_ms();

    for (int i = 0; i < eng->flow_count; i++) {
        struct gro_flow *flow = &eng->flows[i];

        if (!flow->active || flow->pkt_cnt == 0)
            continue;

        if (now - flow->created_at > flow->timeout_ms) {
            gro_flush_flow(eng, flow);
        }
    }
}
```

---

## 3. GSO 详解

### 3.1 GSO 工作原理

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                             GSO 拆分示意                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  输入大包 (9000 bytes)                                                     │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │ Eth │ IP │ TCP │                    DATA (8960 bytes)                │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
│                                    │                                        │
│                                    ▼                                        │
│                          ┌──────────────────┐                              │
│                          │    GSO Engine    │                              │
│                          │                  │                              │
│                          │  MSS = 1460      │                              │
│                          │  9000 / 1460 = 6 │                              │
│                          │  6 segments + 1  │                              │
│                          └────────┬─────────┘                              │
│                                   │                                        │
│         ┌─────────────────────────┼─────────────────────────┐               │
│         ▼                         ▼                         ▼               │
│  ┌──────────────┐         ┌──────────────┐         ┌──────────────┐        │
│  │ Eth │ IP │ TCP │       │ Eth │ IP │ TCP │       │ Eth │ IP │ TCP │        │
│  │seq=100       │         │seq=1461      │         │seq=2922      │        │
│  │DATA (1460)   │         │DATA (1460)   │         │DATA (1460)   │        │
│  └──────────────┘         └──────────────┘         └──────────────┘        │
│                                                                             │
│         ┌─────────────────────────┐─────────────────────────┐               │
│         ▼                         ▼                         ▼               │
│  ┌──────────────┐         ┌──────────────┐         ┌──────────────┐        │
│  │ Eth │ IP │ TCP │       │ Eth │ IP │ TCP │       │ Eth │ IP │ TCP │        │
│  │seq=4383      │         │seq=5844      │         │seq=6745      │        │
│  │DATA (1460)   │         │DATA (1460)   │         │DATA (560)    │        │
│  └──────────────┘         └──────────────┘         └──────────────┘        │
│                                                                             │
│  总共 7 个 segments                                                        │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 3.2 GSO 数据结构

```c
// GSO 分割请求
struct gso_segment {
    struct rte_mbuf *pkt;      // 原始大包
    uint16_t mss;              // 最大段大小
    uint16_t nb_segs;          // 分割数量
    uint16_t seg_offset;       // 当前处理偏移
};

// GSO 引擎
struct gso_engine {
    uint16_t max_segs_per_pkt;  // 每个包的最多分段数
    struct rte_ring *output_ring;
};
```

### 3.3 TCP GSO 实现

```c
// TCP GSO 主函数
static int
tcp_gso_segment(struct rte_mbuf *pkt,
                uint16_t mss,
                struct rte_mbuf **seg_pkts,
                uint16_t nb_segs)
{
    struct rte_ipv4_hdr *ip = get_ipv4_header(pkt);
    struct rte_tcp_hdr *tcp = get_tcp_header(pkt);

    // 检查是否有足够的空间
    uint16_t ip_hdr_len = sizeof(struct rte_ipv4_hdr);
    uint16_t tcp_hdr_len = (tcp->data_off >> 4) * 4;  // 支持 TCP 选项
    uint16_t data_len = rte_be_to_cpu_16(ip->total_length) -
                        ip_hdr_len - tcp_hdr_len;

    // MSS 定义：最大 TCP payload（不含 TCP 头），直接比较
    if (data_len <= mss) {
        // 不需要分片，整个包直接发送
        seg_pkts[0] = pkt;
        return 1;
    }

    // 计算分片数：每段 payload = mss
    uint16_t nb_segments = (data_len + mss - 1) / mss;

    if (nb_segments > nb_segs)
        return -1;  // 空间不足

    // 分割
    uint16_t sent_seq = rte_be_to_cpu_32(tcp->sent_seq);
    uint8_t *data = (uint8_t *)(tcp + 1);
    uint16_t offset = 0;

    for (int i = 0; i < nb_segments; i++) {
        uint16_t copy_len = (data_len - offset >= mss) ?
                             mss : (data_len - offset);

        // 创建新的 mbuf
        struct rte_mbuf *seg = rte_pktmbuf_alloc(gso_mbuf_pool);
        if (!seg) {
            // 清理已分配的
            for (int j = 0; j < i; j++)
                rte_pktmbuf_free(seg_pkts[j]);
            return -ENOMEM;
        }

        // 复制 header
        struct rte_ether_hdr *eth = rte_pktmbuf_mtod(seg, struct rte_ether_hdr *);
        struct rte_ipv4_hdr *ip_new = (struct rte_ipv4_hdr *)(eth + 1);
        struct rte_tcp_hdr *tcp_new = (struct rte_tcp_hdr *)(ip_new + 1);

        rte_memcpy(eth, rte_pktmbuf_mtod(pkt, struct rte_ether_hdr *),
                   sizeof(struct rte_ether_hdr) + ip_hdr_len + tcp_hdr_len);

        // 修改 IP
        ip_new->total_length = rte_cpu_to_be_16(ip_hdr_len + tcp_hdr_len + copy_len);
        ip_new->packet_id = rte_cpu_to_be_16(rte_be_to_cpu_16(ip->packet_id) + i);
        ip_new->frag_offset = 0;  // 不分片
        ip_new->hdr_checksum = 0;

        // 修改 TCP
        tcp_new->sent_seq = rte_cpu_to_be_32(sent_seq + offset);
        tcp_new->data_off = (tcp_hdr_len / 4) << 4;

        if (i < nb_segments - 1) {
            tcp_new->tcp_flags = RTE_TCP_PSH_FLAG | RTE_TCP_ACK_FLAG;
        } else {
            tcp_new->tcp_flags = tcp->tcp_flags;  // 保留 FIN 等
        }

        // 复制数据
        uint8_t *seg_data = (uint8_t *)(tcp_new + 1);
        rte_memcpy(seg_data, data + offset, copy_len);

        // 设置 mbuf
        seg->pkt_len = sizeof(struct rte_ether_hdr) + ip_hdr_len +
                       tcp_hdr_len + copy_len;
        seg->data_len = seg->pkt_len;

        // 设置 offload
        seg->ol_flags |= RTE_MBUF_F_TX_IPV4
                       | RTE_MBUF_F_TX_IP_CKSUM
                       | RTE_MBUF_F_TX_TCP_CKSUM;
        seg->l2_len = sizeof(struct rte_ether_hdr);
        seg->l3_len = ip_hdr_len;
        seg->l4_len = tcp_hdr_len;

        seg_pkts[i] = seg;
        offset += copy_len;
    }

    // 释放原始包
    rte_pktmbuf_free(pkt);

    return nb_segments;
}
```

---

## 4. DPDK GRO/GSO 库

### 4.1 librte_gro 库

```c
// DPDK GRO 库：lib/gro

#include <rte_gro.h>

// GRO 类型标志
#define RTE_GRO_TCP_IPV4             (1ULL << 0)  // TCP/IPv4
#define RTE_GRO_IPV4_VXLAN_TCP_IPV4 (1ULL << 1)  // VxLAN TCP/IPv4
#define RTE_GRO_UDP_IPV4             (1ULL << 2)  // UDP/IPv4
#define RTE_GRO_TCP_IPV6             (1ULL << 4)  // TCP/IPv6

// GRO 参数（用于创建上下文或传入 burst 函数）
struct rte_gro_param {
    uint64_t gro_types;          // 期望的 GRO 类型掩码
    uint16_t max_flow_num;        // 最大 flow 数
    uint16_t max_item_per_flow;   // 每个 flow 最大包数
    uint16_t socket_id;           // NUMA socket
};

// 方式 1：创建持久 GRO 上下文（适合有状态的场景）
void *gro_ctx = rte_gro_ctx_create(&param);
// ... 处理包 ...
rte_gro_ctx_destroy(gro_ctx);

// 方式 2：无状态 burst 合并（最常用）
// 同一 burst 内的包如果能合并就直接合并，不需要上下文
uint16_t nb_after = rte_gro_reassemble_burst(pkts, nb_pkts, &param);
// nb_after <= nb_pkts，合并后的包在 pkts 数组前部

// 应用示例
static void
app_rx_gro(struct rte_mbuf **pkts, uint16_t nb_pkts)
{
    struct rte_gro_param param = {
        .gro_types = RTE_GRO_TCP_IPV4,
        .max_flow_num = 4096,
        .max_item_per_flow = 32,
    };

    uint16_t nb_after = rte_gro_reassemble_burst(pkts, nb_pkts, &param);

    // nb_after 个包需要处理（前 nb_after 个是合并后的大包）
    for (uint16_t i = 0; i < nb_after; i++) {
        process_packet(pkts[i]);
    }
}
```

### 4.2 librte_gso 库

```c
// DPDK GSO 库：lib/gso

#include <rte_gso.h>

// GSO 上下文
struct rte_gso_ctx {
    struct rte_mempool *direct_pool;   // 存放 segment header 的 mbuf pool
    struct rte_mempool *indirect_pool; // 存放 indirect mbuf（指向原始包数据）
    uint64_t flag;                     // 控制标志（如 RTE_GSO_FLAG_IPID_FIXED）
    uint32_t gso_types;                // GSO 类型（使用 RTE_ETH_TX_OFFLOAD_*_TSO）
    uint16_t gso_size;                 // 最大 segment 大小（含 header）
};

// 唯一的 GSO 入口函数（TCP/UDP 都走这个）
int rte_gso_segment(struct rte_mbuf *pkt,
                    const struct rte_gso_ctx *ctx,
                    struct rte_mbuf **pkts_out,
                    uint16_t nb_pkts_out);
// 返回值：输出 segment 数量；0 = 不需要分片；负值 = 错误

// 使用示例
static void
gso_example(struct rte_mbuf *large_pkt)
{
    // 初始化 GSO 上下文
    struct rte_gso_ctx ctx = {
        .direct_pool = gso_direct_pool,   // 需提前创建
        .indirect_pool = gso_indirect_pool,
        .gso_types = RTE_ETH_TX_OFFLOAD_TCP_TSO,
        .gso_size = 1514,                 // Eth + IP + TCP + MSS(1460)
    };

    // 设置输入包的 ol_flags（告诉 GSO 库这是什么类型的包）
    large_pkt->ol_flags |= RTE_MBUF_F_TX_TCP_SEG | RTE_MBUF_F_TX_IPV4;

    struct rte_mbuf *segments[64];
    int nb_segments = rte_gso_segment(large_pkt, &ctx, segments, 64);

    if (nb_segments > 0) {
        rte_eth_tx_burst(port_id, queue_id, segments, nb_segments);
    }
    // 注意：rte_gso_segment 不会释放输入包，需要应用自己释放
    rte_pktmbuf_free(large_pkt);
}
```

---

## 5. 实际应用场景

### 5.1 高性能 Web 服务器

```c
// 使用 GRO 优化 HTTP 服务器接收
static void
http_server_rx(struct rte_mbuf **pkts, uint16_t nb_pkts)
{
    // GRO 合并
    struct rte_gro_param param = {
        .gro_types = RTE_GRO_TCP_IPV4,
        .max_flow_num = 4096,
        .max_item_per_flow = 32,
    };
    uint16_t nb_gro = rte_gro_reassemble_burst(pkts, nb_pkts, &param);

    // nb_gro 个合并后的大包
    for (int i = 0; i < nb_gro; i++) {
        struct rte_mbuf *m = pkts[i];

        // 解析 HTTP 请求
        struct rte_ipv4_hdr *ip = get_ipv4_header(m);
        struct rte_tcp_hdr *tcp = get_tcp_header(m);
        char *http_data = (char *)(tcp + 1);

        // 处理请求
        handle_http_request(m, http_data);
    }

    // 处理未被合并的包（仍然在 pkts 数组中）
    for (int i = nb_gro; i < nb_pkts; i++) {
        handle_packet(pkts[i]);
    }
}

// 使用 GSO 优化响应发送
static void
http_server_tx(struct rte_mbuf *response_pkt, uint16_t mss)
{
    // 检查是否需要 GSO
    uint16_t total_len = rte_pktmbuf_pkt_len(response_pkt);

    if (total_len > mss) {
        // 需要分片
        struct rte_mbuf *segments[64];

        response_pkt->ol_flags |= RTE_MBUF_F_TX_TCP_SEG | RTE_MBUF_F_TX_IPV4;
        int nb_segs = rte_gso_segment(response_pkt, &gso_ctx,
                                       segments, 64);

        rte_eth_tx_burst(port_id, queue_id, segments, nb_segs);
    } else {
        // 直接发送
        rte_eth_tx_burst(port_id, queue_id, &response_pkt, 1);
    }
}
```

### 5.2 防火墙/IDS

```c
// 防火墙使用 GRO 合并流量，便于检测
static void
firewall_process(struct rte_mbuf **pkts, uint16_t nb_pkts)
{
    // GRO 合并
    struct rte_gro_param gro_param = {
        .gro_types = RTE_GRO_TCP_IPV4,
        .max_flow_num = 4096,
        .max_item_per_flow = 32,
    };
    uint16_t nb_merged = rte_gro_reassemble_burst(pkts, nb_pkts, &gro_param);

    // 合并后更容易检测完整流量的特征
    for (int i = 0; i < nb_merged; i++) {
        if (detect_attack(pkts[i])) {
            // 检测到攻击，添加 DROP 规则
            add_drop_flow_rule(pkts[i]);
            rte_pktmbuf_free(pkts[i]);
            pkts[i] = NULL;
        }
    }

    // 转发未攻击的包
    forward_packets(pkts, nb_merged);
}
```

---

## 6. 性能对比

### 6.1 GRO 性能收益

| 场景             | 无 GRO           | 有 GRO                            | 提升       |
| ---------------- | ---------------- | --------------------------------- | ---------- |
| **中断次数**     | 1Mpps = 1M 中断  | 合并后 ~100K 中断                 | 10x        |
| **协议栈处理**   | 1Mpps 包处理     | 100K flow 处理                    | 10x        |
| **小包占比 70%** | 100% header 处理 | 70% 合并                          | ~3x        |
| **延迟**         | 每包立即处理     | burst 内零延迟，超时 flush 有延迟 | 通常零延迟 |

### 6.2 GSO 性能收益

| 场景         | 无 GSO        | 有 GSO       | 提升         |
| ------------ | ------------- | ------------ | ------------ |
| **应用发送** | 逐包发送      | 一次大发送   | 减少系统调用 |
| **MTU=1500** | 应用处理分片  | NIC 硬件分片 | CPU 节省     |
| **隧道协议** | VXLAN 9000 包 | 自动分片     | 兼容性       |

### 6.3 选型指南

```
何时使用 GRO？
- 高吞吐量场景（>100Kpps）
- 延迟不敏感（可以接受 ~1ms 合并延迟）
- 大量小包（Web、视频流量）

何时使用 GSO？
- 应用需要发送大数据块
- 需要适配不同 MTU
- 隧道协议封装

何时组合使用？
- 接收端：GRO（合并小包）
- 发送端：GSO（拆分大包）
- 中间转发：GRO + GSO
```

---

## 7. 小结

本章核心要点：

1. **GRO 原理**：合并相同 flow 的连续包，减少中断和处理开销。

2. **GRO 合并条件**：同 5-tuple、TCP 序列号连续、ACK 相同、IP ID 递增。

3. **GRO 数据结构**：gro_flow 存储合并状态，gro_key 用于查找，timeout 防止无限等待。

4. **GRO 算法**：查找 flow → 检查可合并 → 合并或 flush → 检查超时。

5. **GSO 原理**：将大包拆分成多个 MSS 大小的 segment。

6. **TCP GSO**：修改序列号、IP ID、TCP flags、重新计算 checksum。

7. **DPDK GRO/GSO 库**： librte_gro 和 librte_gso 提供标准实现。

8. **应用场景**：高性能 Web 服务器（GRO 接收、GSO 发送）、防火墙/IDS（GRO 合并检测）。

9. **性能收益**：GRO 减少 10x 中断，GSO 减少应用分片开销。

**下一篇预告**：[[2026-04-09-dpdk-deep-dive-ch14-vlan-vxlan|第十四章]]将讲解 VLAN/VXLAN 隧道——802.1Q VLAN 标签、VXLAN 封装格式、Overlay 网络与 DPDK 实现。

---

> [!tip] 参考文献
>
> - Intel, "Generic Segmentation Offload", https://doc.dpdk.org/guides/prog_guide/generic_segmentation_offload.html
> - Intel, "Generic Receive Offload", https://doc.dpdk.org/guides/prog_guide/generic_receive_offload.html
> - RFC 793, "TCP"
> - RFC 7348, "VXLAN"
