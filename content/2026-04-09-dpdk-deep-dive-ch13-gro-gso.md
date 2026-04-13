---
title: "DPDK 深度探索 (十三)：GRO/GSO 通用卸载机制"
date: 2026-04-09
tags: [dpdk, series, gro, gso, generic-reassembly, generic-segmentation, offload, batch-processing]
description: "深入理解 GRO/GSO 通用卸载——将多个小包合并成大包（GRO）减少处理开销，或将大包拆分成小包（GSO）适配 MTU 限制"
---

> [!info] DPDK 深度探索系列
> 0. [[2026-04-09-dpdk-deep-dive-series-index|全栈学习路径总览]]
> 1-12. 前十二章已完成
> 13. **第十三章：GRO/GSO 通用卸载机制**

---

## 1. 概述：为什么需要 GRO/GSO？

### 1.1 小包问题

网络中小包（小于 MTU）会导致严重的性能问题：

| 问题 | 影响 |
|------|------|
| **中断开销** | 每个包产生一次中断，1Mpps = 1M 次中断 |
| **协议栈处理开销** | 每个包都要经过协议栈处理 |
| **Header 处理占比** | 64 字节包，Header 占 40+ 字节（>60%） |
| **Cache 效率低** | 每个包的 header 处理无法有效利用 Cache |

### 1.2 GRO vs GSO

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
│   好处：减少中断 + 减少协议栈处理次数                                        │
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

        // 序列号连续
        uint32_t seq1_end = rte_be_to_cpu_32(tcp1->sent_seq) +
                            rte_be_to_cpu_16(ip1->total_length) -
                            sizeof(struct rte_ipv4_hdr) -
                            sizeof(struct rte_tcp_hdr);
        uint32_t seq2 = rte_be_to_cpu_32(tcp2->sent_seq);

        // ACK 相同
        uint32_t ack1 = rte_be_to_cpu_32(tcp1->recv_ack);
        uint32_t ack2 = rte_be_to_cpu_32(tcp2->recv_ack);

        // IP ID 递增（用于 IPv4 分片重组）
        uint16_t id1 = rte_be_to_cpu_16(ip1->packet_id);
        uint16_t id2 = rte_be_to_cpu_16(ip2->packet_id);

        return (seq2 == seq1_end + 1) &&
               (ack1 == ack2) &&
               (id2 > id1);
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
// 合并两个 TCP 包
static struct rte_mbuf *
merge_two_tcp_packets(struct rte_mbuf *pkt1, struct rte_mbuf *pkt2)
{
    struct rte_ipv4_hdr *ip1 = get_ipv4_header(pkt1);
    struct rte_ipv4_hdr *ip2 = get_ipv4_header(pkt2);
    struct rte_tcp_hdr *tcp1 = get_tcp_header(pkt1);
    struct rte_tcp_hdr *tcp2 = get_tcp_header(pkt2);

    // pkt2 的数据追加到 pkt1
    uint16_t data_len1 = rte_be_to_cpu_16(ip1->total_length) -
                         sizeof(struct rte_ipv4_hdr) -
                         sizeof(struct rte_tcp_hdr);
    uint16_t data_len2 = rte_be_to_cpu_16(ip2->total_length) -
                         sizeof(struct rte_ipv4_hdr) -
                         sizeof(struct rte_tcp_hdr);

    // pkt1 扩展 total_length
    uint16_t new_len = rte_be_to_cpu_16(ip1->total_length) + data_len2;
    ip1->total_length = rte_cpu_to_be_16(new_len);

    // pkt1 追加 pkt2 的数据
    // 方式1：mbuf chain
    struct rte_mbuf *last_seg = rte_pktmbuf_lastseg(pkt1);
    last_seg->next = pkt2;
    pkt1->pkt_len += data_len2;
    pkt1->nb_segs++;

    // 更新 TCP seq
    uint32_t new_seq = rte_be_to_cpu_32(tcp1->sent_seq) + data_len1 + data_len2;
    tcp1->sent_seq = rte_cpu_to_be_32(new_seq);

    // TCP flags: 保留最后一个包的 flags
    tcp1->tcp_flags = tcp2->tcp_flags;

    // 更新 IP ID（递增）
    ip1->packet_id = rte_cpu_to_be_16(rte_be_to_cpu_16(ip1->packet_id) + 1);

    // IP header checksum 需要重新计算
    ip1->hdr_checksum = 0;
    ip1->hdr_checksum = ipv4_checksum(ip1);

    // TCP checksum 需要重新计算
    tcp1->cksum = 0;
    tcp1->cksum = tcp_checksum(ip1, tcp1);

    return pkt1;
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

        // 检查是否可以合并
        if (can_merge(flow->tail, pkt)) {
            flow->tail = merge_two_tcp_packets(flow->tail, pkt);
            flow->pkt_cnt++;
            flow->total_len += get_data_len(pkt);
            rte_pktmbuf_free(pkt);  // 合并后释放原包
        } else {
            // 不能合并，超时或达到限制，flush 这个 flow
            gro_flush_flow(eng, flow);

            // 重新开始
            init_flow(flow, &key, pkt);
        }

        // 检查是否超时
        if (get_time_ms() - flow->created_at > flow->timeout_ms) {
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
        // 将 flow->head 加入输出队列
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
    // 支持的协议
    uint8_t enable_tcp:1;      // TCP GSO
    uint8_t enable_udp:1;      // UDP GSO
    uint8_t enable_sctp:1;     // SCTP GSO

    // 每个包的最多分段数
    uint16_t max_segs_per_pkt;

    // 输出队列
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
    uint16_t tcp_hdr_len = sizeof(struct rte_tcp_hdr);
    uint16_t data_len = rte_be_to_cpu_16(ip->total_length) -
                        ip_hdr_len - tcp_hdr_len;

    if (data_len <= mss - tcp_hdr_len) {
        // 不需要分片，整个包直接发送
        seg_pkts[0] = pkt;
        return 1;
    }

    // 计算分片数
    uint16_t payload_per_seg = mss - tcp_hdr_len;
    uint16_t nb_segments = (data_len + payload_per_seg - 1) / payload_per_seg;

    if (nb_segments > nb_segs)
        return -1;  // 空间不足

    // 分割
    uint16_t sent_seq = rte_be_to_cpu_32(tcp->sent_seq);
    uint8_t *data = (uint8_t *)(tcp + 1);
    uint16_t offset = 0;

    for (int i = 0; i < nb_segments; i++) {
        uint16_t copy_len = (data_len - offset >= payload_per_seg) ?
                             payload_per_seg : (data_len - offset);

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
        seg->ol_flags |= PKT_TX_IPV4 | PKT_TX_IP_CKSUM | PKT_TX_TCP_CKSUM;

        seg_pkts[i] = seg;
        offset += copy_len;
    }

    // 释放原始包
    rte_pktmbuf_free(pkt);

    return nb_segments;
}
```

### 3.4 UDP GSO 实现

```c
// UDP GSO (Fragmentation)
// UDP GSO 通常用于隧道协议如 VXLAN，将大包分成多个小包

static int
udp_gso_segment(struct rte_mbuf *pkt,
                uint16_t mss,
                struct rte_mbuf **seg_pkts,
                uint16_t nb_segs)
{
    struct rte_ipv4_hdr *outer_ip = get_outer_ipv4_header(pkt);
    struct rte_udp_hdr *udp = get_udp_header(pkt);
    struct rte_ipv4_hdr *inner_ip = get_inner_ipv4_header(pkt);

    uint16_t outer_hdr_len = sizeof(struct rte_ipv4_hdr) +
                              sizeof(struct rte_udp_hdr);
    uint16_t payload_len = rte_be_to_cpu_16(udp->dgram_len) -
                            sizeof(struct rte_udp_hdr);

    uint16_t max_payload = mss - outer_hdr_len - sizeof(struct rte_ipv4_hdr);
    uint16_t nb_segments = (payload_len + max_payload - 1) / max_payload;

    if (nb_segments > nb_segs)
        return -1;

    uint16_t offset = 0;
    uint16_t inner_id = rte_be_to_cpu_16(inner_ip->packet_id);

    for (int i = 0; i < nb_segments; i++) {
        uint16_t copy_len = (payload_len - offset >= max_payload) ?
                             max_payload : (payload_len - offset);

        struct rte_mbuf *seg = rte_pktmbuf_alloc(gso_mbuf_pool);

        // 复制外层 header
        struct rte_ether_hdr *eth = rte_pktmbuf_mtod(seg, struct rte_ether_hdr *);
        struct rte_ipv4_hdr *ip_new = (struct rte_ipv4_hdr *)(eth + 1);
        struct rte_udp_hdr *udp_new = (struct rte_udp_hdr *)(ip_new + 1);
        struct rte_ipv4_hdr *inner_ip_new = (struct rte_ipv4_hdr *)(udp_new + 1);

        // 复制整个原始包头部
        rte_memcpy(eth, rte_pktmbuf_mtod(pkt, struct rte_ether_hdr *),
                   outer_hdr_len + sizeof(struct rte_ipv4_hdr));

        // 修改外层 IP
        ip_new->total_length = rte_cpu_to_be_16(outer_hdr_len +
                          sizeof(struct rte_ipv4_hdr) + copy_len);
        ip_new->packet_id = rte_cpu_to_be_16(
                            rte_be_to_cpu_16(outer_ip->packet_id) + i);
        ip_new->fragment_offset = rte_cpu_to_be_16(
                                  i == 0 ? 0 : 0x2000);  // MF flag except last
        ip_new->hdr_checksum = 0;

        // 修改 UDP 长度
        udp_new->dgram_len = rte_cpu_to_be_16(sizeof(struct rte_udp_hdr) +
                                               sizeof(struct rte_ipv4_hdr) +
                                               copy_len);

        // 修改内层 IP
        inner_ip_new->total_length = rte_cpu_to_be_16(
                                      sizeof(struct rte_ipv4_hdr) + copy_len);
        inner_ip_new->packet_id = rte_cpu_to_be_16(inner_id + i);
        inner_ip_new->fragment_offset = rte_cpu_to_be_16(
                                         i == 0 ? 0 : (offset / 8));
        inner_ip_new->hdr_checksum = 0;

        // 复制数据
        uint8_t *inner_data = (uint8_t *)(inner_ip_new + 1);
        uint8_t *src_data = (uint8_t *)(inner_ip + 1) + offset;
        rte_memcpy(inner_data, src_data, copy_len);

        seg->pkt_len = outer_hdr_len + sizeof(struct rte_ipv4_hdr) + copy_len;
        seg->data_len = seg->pkt_len;

        seg_pkts[i] = seg;
        offset += copy_len;
    }

    rte_pktmbuf_free(pkt);
    return nb_segments;
}
```

---

## 4. DPDK GRO/GSO 库

### 4.1 librte_gro 库

```c
// DPDK 提供了 GRO 库：lib/gro

#include <rte_gro.h>

// GRO 参数
struct rte_gro_param {
    uint64_t timeout;        // 超时时间（纳秒）
    uint16_t max_flow_num;   // 最大 flow 数
    uint16_t max_pkt_per_flow;  // 每个 flow 最大包数
};

// GRO 上下文
struct rte_gro_ctx *gro_ctx;

// 创建 GRO 上下文
gro_ctx = rte_gro_create(PORT_ID, &param);

// 合并接收到的包
static uint16_t
gro_process(struct rte_mbuf **pkts, uint16_t nb_pkts)
{
    struct rte_gro_ctx *ctx = gro_ctx;

    // RTE_GRO_TCP_IPV4: TCPv4 合并
    // RTE_GRO_TCP_IPV6: TCPv6 合并
    // RTE_GRO_UDP_IPV4: UDPv4 合并
    // RTE_GRO_VXLAN: VXLAN 合并

    return rte_gro_process(ctx, pkts, nb_pkts,
                           RTE_GRO_TCP_IPV4);
}

// 检查哪些包被合并了（返回合并后的大包索引）
static int
gro_reassemble(struct rte_mbuf **pkts, uint16_t nb_pkts)
{
    return rte_gro_reassemble(pkts, nb_pkts, gro_ctx);
}

// 销毁
rte_gro_destroy(gro_ctx);
```

### 4.2 librte_gso 库

```c
// DPDK 提供了 GSO 库：lib/gso

#include <rte_gso.h>

// GSO 上下文
struct rte_gso_ctx {
    struct rte_mempool *mbuf_pool;
    uint16_t max_segs_per_pkt;
    uint16_t mss;           // 最大段大小
    uint8_t enable_tcp:1;
    uint8_t enable_udp:1;
};

// 创建 GSO 上下文
struct rte_gso_ctx *
rte_gso_create(const char *name, struct rte_mempool *mp)
{
    struct rte_gso_ctx *ctx = rte_zmalloc(NULL, sizeof(*ctx), 0);
    ctx->mbuf_pool = mp;
    ctx->max_segs_per_pkt = 64;
    return ctx;
}

// TCP GSO
int
rte_gso_tcp4_segment(struct rte_gso_ctx *ctx,
                     struct rte_mbuf *pkt,
                     uint16_t mss,
                     struct rte_mbuf **pkts,
                     uint16_t nb_pkts)
{
    // 实现 TCP 分段
}

// UDP GSO
int
rte_gso_udp4_segment(struct rte_gso_ctx *ctx,
                      struct rte_mbuf *pkt,
                      uint16_t mss,
                      struct rte_mbuf **pkts,
                      uint16_t nb_pkts)
{
    // 实现 UDP 分段
}

// 使用示例
static void
gso_example(struct rte_mbuf *large_pkt)
{
    struct rte_gso_ctx *gso_ctx = get_gso_ctx();
    struct rte_mbuf *segments[64];
    uint16_t nb_segments;

    nb_segments = rte_gso_tcp4_segment(gso_ctx,
                                        large_pkt,
                                        1460,  // MSS
                                        segments,
                                        64);

    if (nb_segments > 0) {
        // 发送所有 segments
        rte_eth_tx_burst(port_id, queue_id, segments, nb_segments);
    }
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
    uint16_t nb_gro = rte_gro_process(gro_ctx, pkts, nb_pkts,
                                       RTE_GRO_TCP_IPV4);

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
        uint16_t nb_segs;

        nb_segs = rte_gso_tcp4_segment(gso_ctx,
                                       response_pkt,
                                       mss,
                                       segments,
                                       64);

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
    uint16_t nb_merged = rte_gro_process(gro_ctx, pkts, nb_pkts,
                                          RTE_GRO_TCP_IPV4);

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

| 场景 | 无 GRO | 有 GRO | 提升 |
|------|--------|--------|------|
| **中断次数** | 1Mpps = 1M 中断 | 合并后 ~100K 中断 | 10x |
| **协议栈处理** | 1Mpps 包处理 | 100K flow 处理 | 10x |
| **小包占比 70%** | 100% header 处理 | 70% 合并 | ~3x |
| **延迟** | 每包立即处理 | 等待合并（~1ms） | +1ms |

### 6.2 GSO 性能收益

| 场景 | 无 GSO | 有 GSO | 提升 |
|------|--------|--------|------|
| **应用发送** | 逐包发送 | 一次大发送 | 减少系统调用 |
| **MTU=1500** | 应用处理分片 | NIC 硬件分片 | CPU 节省 |
| **隧道协议** | VXLAN 9000 包 | 自动分片 | 兼容性 |

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

7. **UDP GSO**：用于隧道协议（VXLAN）分片，需要处理内外层 IP。

8. **DPDK GRO/GSO 库**： librte_gro 和 librte_gso 提供标准实现。

9. **应用场景**：高性能 Web 服务器（GRO 接收、GSO 发送）、防火墙/IDS（GRO 合并检测）。

10. **性能收益**：GRO 减少 10x 中断，GSO 减少应用分片开销。

**下一篇预告**：[[2026-04-09-dpdk-deep-dive-ch14-vlan-vxlan|第十四章]]将讲解 VLAN/VXLAN 隧道——802.1Q VLAN 标签、VXLAN 封装格式、Overlay 网络与 DPDK 实现。

---

> [!tip] 参考文献
> - Intel, "Generic Segmentation Offload", https://doc.dpdk.org/guides/prog_guide/generic_segmentation_offload.html
> - Intel, "Generic Receive Offload", https://doc.dpdk.org/guides/prog_guide/generic_receive_offload.html
> - RFC 793, "TCP"
> - RFC 7348, "VXLAN"
