---
title: "Kernel Protocol Stack 深度探索 (二十四)：TCP 拥塞控制"
date: 2026-04-13
tags:
  [
    linux,
    kernel,
    networking,
    series,
    tcp,
    congestion-control,
    cwnd,
    ssthresh,
    reno,
    cubic,
    bbr,
    slow-start,
    fast-retransmit,
  ]
description: "深入解析 TCP 拥塞控制算法——慢启动、拥塞避免、快速重传、拥塞窗口管理、Reno/CUBIC/BBR 算法对比"
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
> 24. **第二十四章：TCP 拥塞控制**

---

## 1. 概述：拥塞控制

TCP 拥塞控制是防止网络过载的核心机制，通过动态调整发送速率来匹配网络容量。与流量控制（flow control，接收方 buffer 限制）不同，拥塞控制针对的是网络路径上的拥塞状态。

核心变量：

- **snd_cwnd（Congestion Window）**：拥塞窗口，发送方允许发送的未确认字节数
- **snd_ssthresh（Slow Start Threshold）**：慢启动阈值，区分慢启动和拥塞避免阶段

---

## 2. 拥塞控制状态机

```
                  loss event
                     │
                     ▼
              ┌──────────────┐
              │  IP路由改变   │
              └──────┬───────┘
                     │
                     ▼
         ┌───────────────────────┐
         │ snd_cwnd = min(snd_cwnd/2, MSS)
         │ snd_ssthresh = snd_cwnd
         └───────────────────────┘
                     │
          ┌────────┴────────┐
          ▼                 ▼
    ┌──────────┐      ┌──────────────┐
    │  慢启动   │      │  拥塞避免     │
    │(slow start)│    │(congestion avoidance)│
    └────┬─────┘      └──────┬───────┘
         │                   │
         │ snd_cwnd >= ssthresh
         └─────────┬──────────┘
                   ▼
            ┌──────────────┐
            │ 拥塞避免模式  │
            └──────────────┘
```

---

## 3. 慢启动（Slow Start）

当连接建立或从丢包恢复时，TCP 从慢启动阶段开始。

### 3.1 算法规则

```
INIT: snd_cwnd = 1 MSS (通常为 ~1460 bytes)
       snd_ssthresh =65535 bytes (或默认值)

for each ACK received:
    if snd_cwnd < snd_ssthresh:
        snd_cwnd += MSS  // 指数增长
    else:
        // 进入拥塞避免
        snd_cwnd += MSS * MSS / snd_cwnd
```

每收到一个 ACK，snd_cwnd 增加一个 MSS。假设 MSS=1460，初始 cwnd=1460：

- 第1个 ACK：cwnd=2920（+1460）
- 第2个 ACK：cwnd=4380（+1460）
- 第3个 ACK：cwnd=5840（+1460）

指数增长直到达到 ssthresh。

### 3.2 内核实现

```c
// net/ipv4/tcp_cong.c / net/ipv4/tcp_cubic.c
void tcp_slow_start(struct tcp_sock *tp)
{
    if (tp->snd_cwnd < tp->snd_ssthresh) {
        int added = min(tp->snd_cwnd, tp->mss_cache);
        tp->snd_cwnd += added;
    }
}
```

### 3.3 ssthresh 初始值

```c
// net/ipv4/tcp_input.c
void tcp_init_cwnd(struct tcp_sock *tp, struct rhlist_head *head)
{
    struct tcp_sock *tpi;

    // 从路由缓存获取初始窗口
    tp->snd_cwnd = min(tcp_default_init_cwnd(sk->sk_route_cache),
                       dst_metric(&rt->dst, RTAX_INITCWND));
    tp->snd_ssthresh = dst_metric(&rt->dst, RTAX_INITRWND);
    if (!tp->snd_ssthresh)
        tp->snd_ssthresh = dst_metric_advmss(&rt->dst);
}
```

Linux 默认 init_cwnd 从路由缓存获取，早期为 10（MSS），现代内核使用 TCP_CONGESTION 控制。

---

## 4. 拥塞避免（Congestion Avoidance）

当 `snd_cwnd >= snd_ssthresh` 时，进入拥塞避免阶段。

### 4.1 算法规则

```
for each ACK received:
    // 线性增长（每个 RTT 增加 1 MSS）
    snd_cwnd += MSS * MSS / snd_cwnd
```

每个 ACK 确认 k 字节时，只增加 `k * MSS / snd_cwnd`。一个 RTT 下来，总共增加约 1 MSS。

### 4.2 内核实现

```c
// net/ipv4/tcp_input.c
void tcp_cong_avoid(struct tcp_sock *tp, u32 ack, u32 in_flight)
{
    if (tp->snd_cwnd < tp->snd_ssthresh) {
        tcp_slow_start(tp);  // 慢启动
    } else {
        // 拥塞避免：线性增长
        tcp_reno_avoid(tp, ack, in_flight);
    }
}

// net/ipv4/tcp_cong.c (Reno 实现)
void tcp_reno_avoid(struct tcp_sock *tp, u32 ack, u32 in_flight)
{
    u32 delta;

    delta = tcp_skb_in_flight(tp, tcp_write_queue_next(sk, tp->retransmit_head));
    delta *= tp->mss_cache;
    tp->snd_cwnd += delta / tp->snd_cwnd;
}
```

---

## 5. 快速重传与快速恢复（Fast Retransmit / Fast Recovery）

当发送方连续收到 3 个重复 ACK（dupack），认为数据包丢失但网络仍连通，执行快速重传。

### 5.1 标准流程

```
1. 收到第1个 dupack：snd_cwnd 减半（ssthresh = snd_cwnd/2），但继续发送新数据
2. 收到第2、3个 dupack：继续重传丢失段
3. 收到新数据的 ACK：退出快速恢复，snd_cwnd = ssthresh
```

### 5.2 内核实现

```c
// net/ipv4/tcp_input.c
static int tcp_process_loss(struct sock *sk, int flag)
{
    struct tcp_sock *tp = tcp_sk(sk);
    struct sk_buff *sq;

    if (flag & FLAG_DATA_LOST) {
        // 快速重传：ssthresh 设为 cwnd/2
        tcp_enter_cwr(sk, 0);
        return -1;
    }

    if (tp->frto) {
        // F-RTO 支持
        ...
    }

    // 检查是否进入快速恢复
    if (tp->snd_cwnd > tp->bytes_acked + tp->retrans_out * tp->mss_cache)
        tcp_enter_loss(sk, 0);
    return 0;
}

// 进入拥塞避免/快速恢复
static void tcp_enter_cwr(struct sock *sk, int cwr)
{
    struct tcp_sock *tp = tcp_sk(sk);

    tp->prior_ssthresh = tp->snd_ssthresh;
    tp->snd_ssthresh = tcp_bound_to_half_wnd(tp, tp->snd_cwnd);
    tp->snd_cwnd = tp->snd_ssthresh;
    tp->snd_cwnd_cnt = 0;
    tp->high_seq = tp->snd_nxt;
    tp->snd_cwnd_stamp = tcp_time_stamp;
    tp->undo_marker = tp->snd_nxt;  // 用于 DSACK 恢复
    INET_ECN_dance(tp->inet_conn.sk, skb);
}
```

---

## 6. Reno 算法

Reno 是最经典的拥塞控制算法，包含：

- 慢启动
- 拥塞避免
- 快速重传
- 快速恢复

### 6.1 丢包后的处理

```
1. 连续3个dupack：
   - ssthresh = snd_cwnd / 2
   - snd_cwnd = ssthresh + 3 * MSS
   - 重传丢失段

2. 超时：
   - ssthresh = snd_cwnd / 2
   - snd_cwnd = 1 MSS
   - 重新进入慢启动
```

超时比连续 dupack 更严重（可能网络完全断开），所以 cwnd 降到 1 MSS。

---

## 7. CUBIC 算法

CUBIC（Linux 默认）是 BIC 算法的改进，使用三次多项式函数调整 cwnd。

### 7.1 核心思想

```
W(t) = C * (t - K)^3 + Wmax

其中：
- C = 0.4（缩放因子）
- t = 从丢包后经过的时间（RTT）
- K = (Wmax / C)^(1/3)
- Wmax = 丢包前的 cwnd
```

CUBIC 特点：

- 在 Wmax 附近停留较长时间（稳定点）
- 快速增长到 Wmax，然后缓慢增加
- 丢包后重新开始，对丢包不敏感

### 7.2 内核实现

```c
// net/ipv4/tcp_cubic.c
struct tcp_congestion_ops tcp_cubic = {
    .flags      = TCP_CONG_NON_RESTRICTED,
    .name       = "cubic",
    .owner      = THIS_MODULE,

    .init       = bictcp_init,
    .ssthresh   = bictcp_ssthresh,
    .cong_avoid = bictcp_update,
    .set_state  = bictcp_state,

    .undo_cwnd  = bictcp_undo_cwnd,
    .pkts_acked = bictcp_acked,
};

static void bictcp_init(struct sock *sk)
{
    struct tcp_sock *tp = tcp_sk(sk);
    struct bictcp *bictp = inet_csk_ca(sk);

    bictp->btcp_last_hdr = 0;
    bictp->btcp_last_ack = 0;
    bictp->btcp_delay = 0;
    bictp->btcp_lo_thresh = 0;
    bictp->btcp_hi_thresh = 0;
    bictp->btcp_rtt_win_sxp = tcp_jiffies32;
    bictp->btcp_cwnd_stamp = tcp_jiffies32;
    bictp->origin_point = tp->snd_cwnd;

    // 初始化 Hystart
    if (sysctl_tcp_congestion_control_legacy != Hystart_NAME)
        hystart_enable = sysctl_tcp_hystart;
}

static u32 bictcp_ssthresh(struct sock *sk)
{
    const struct tcp_sock *tp = tcp_sk(sk);
    struct bictcp *bictp = inet_csk_ca(sk);

    if (hystart) {
        // Hystart：丢包时重新探测
        bictp->btcp_hi_thresh = tp->snd_cwnd;
        bictp->btcp_lo_thresh = tp->snd_cwnd;
    }
    bictp->origin_point = tp->snd_cwnd;
    bictp->ack_cnt = 0;
    bictp->tcp_cwnd_cnt = 0;

    return max((tp->snd_cwnd * Hystart_threshold) >> 1, 2U);
}
```

### 7.3 CUBIC 窗口曲线

```
cwnd
  ^
  │            ╭──╮
  │           ╱    ╲          <- Wmax 附近停留
  │          ╱      ╲
  │         ╱        ╲
  │        ╱          ╲
  │───────╱────────────╲───────> time
  │      │              │
  │      Wmax           K
  │
```

---

## 8. BBR 算法

BBR（Bottleneck Bandwidth and Round-trip propagation time）是基于模型的拥塞控制，由 Google 提出。

### 8.1 核心思想

BBR 不依赖丢包来检测拥塞，而是主动估计：

- **BDP（Bottleneck Bandwidth and RTT）**：`BDP = bandwidth * RTT`
- 目标：让 cwnd 接近 BDP

### 8.2 四阶段状态机

```
         ┌──────────────┐
         │  STARTUP     │  快速增长到带宽峰值
         │ (探测带宽)    │
         └──────┬───────┘
                │ 带宽不再增长
                ▼
         ┌──────────────┐
         │  DRAIN       │  排出队列（cwnd 降到 BDP）
         │ (排出队列)    │
         └──────┬───────┘
                │ 队列排空
                ▼
         ┌──────────────┐
         │  PROBE_BW    │  周期性地探测更大带宽
         │ (探测带宽)    │
         └──────┬───────┘
                │ RTT 周期性膨胀
                ▼
         ┌──────────────┐
         │  PROBE_RTT    │  短暂降低 cwnd 测 RTT
         └──────────────┘
```

### 8.3 内核实现

```c
// net/ipv4/tcp_bbr.c
struct tcp_congestion_ops tcp_bbr = {
    .flags      = TCP_CONG_NON_RESTRICTED,
    .name       = "bbr",
    .owner      = THIS_MODULE,

    .init       = bbr_init,
    .ssthresh   = bbr_ssthresh,
    .cong_avoid = bbrCongBbr,
    .set_state  = bbr_set_state,
    .undo_cwnd  = bbr_undo_cwnd,
    .pkts_acked = bbr_pkts_acked,
    .cwnd_event = bbr_cwnd_event,

    .get_info   = bbr_get_info,
    .set_cong_control = bbr_set_cong_control,
};

// BBR 拥塞避免
static void bbrCongBbr(struct sock *sk, u32 ack, u32 in_flight)
{
    struct tcp_sock *tp = tcp_sk(sk);
    struct bbr *bbr = inet_csk_ca(sk);
    u32 cwnd;
    u64 bw;

    bbr->min_rtt = min(bbr->min_rtt, tp->srtt_us >> 3);
    bw = bbr->bw * (u64)tp->mss_cache;

    // 根据 BDP 调整 cwnd
    cwnd = min(div_u64(bw * bbr->min_rtt, USEC_PER_SEC),
               2 * tp->mss_cache * bbr->min_rtt);
    tp->snd_cwnd = max(cwnd, 2 * tp->mss_cache);
}
```

### 8.4 BBR vs Reno/CUBIC

| 特性       | Reno/CUBIC       | BBR              |
| ---------- | ---------------- | ---------------- |
| 拥塞信号   | 丢包             | 带宽 + RTT       |
| 队列行为   | 队列满后丢包     | 主动排空队列     |
| 带宽利用率 | 中等（队列缓冲） | 高（无队列堆积） |
| RTT        | 较高             | 较低             |
| 公平性     | 较好             | 激进（抢占）     |

---

## 9. Hystart（混合启动）

Hystart 是附着在 CUBIC/Reno 上的早期探测机制，在慢启动阶段检测排队延迟。

### 9.1 原理

当 RTT 明显增加时，提前退出慢启动，避免造成网络缓冲。

```c
// net/ipv4/tcp_cubic.c
static void bictcp_update(struct bictcp *ca, u32 cur_ack, u32 cur_rtt)
{
    if (hystart && before(cur_ack, ca->btcp_last_hdr)) {
        // 检测 RTT 增长
        if (cur_rtt > (ca->btcp_last_rtt + (ca->btcp_last_rtt >> 1))) {
            ca->btcp_hi_thresh = tcp_snd_cwnd(tp);
            ca->btcp_lo_thresh = tp->snd_cwnd;
            tp->snd_ssthresh = ca->btcp_lo_thresh;
        }
        ca->btcp_last_rtt = cur_rtt;
    }
}
```

---

## 10. ECN（显式拥塞通知）

ECN 允许路由器在 IP 头标记拥塞，接收方在 TCP ACK 中通知发送方。

### 10.1 工作流程

```
发送方 --正常包--> 路由器（拥塞）--CE标记--> 接收方
                      │                      │
                      ▼                      ▼
              IP 头ECT位设为1          TCP ECE 标志置1
                                              │
                                              ▼
                                        发送方降低 cwnd
```

### 10.2 内核实现

```c
// net/ipv4/tcp_input.c
static bool tcp_process_ecn(struct sock *sk, struct sk_buff *skb)
{
    struct tcp_sock *tp = tcp_sk(sk);
    struct tcphdr *th = tcp_hdr(skb);
    struct inet_connection_sock *icsk = inet_csk(sk);

    // 处理 ECE
    if (th->ece && !th->crc && sock_net(sk)->ipv4.sysctl_tcp_ecn) {
        if (!tp->ecn_ok && !sysctl_tcp_ecn_ok) {
            // 第一次 ECN 通知：进入 CWR
            tp->ecn_ok = 1;
            tp->ecn_cwr = 1;
            icsk->icsk_ca_ops->set_state(sk, TCP_CA_Open);
            tcp_enter_cwr(sk, 1);
            return true;
        } else if (tp->ecn_ok) {
            // 后续 ECN 通知
            tp->ecn_cwr = 1;
        }
    }
    return false;
}
```

---

## 11. 拥塞控制算法切换

### 11.1 sysctl 接口

```bash
# 查看当前算法
sysctl net.ipv4.tcp_congestion_control

# 切换算法
sysctl -w net.ipv4.tcp_congestion_control=cubic
sysctl -w net.ipv4.tcp_congestion_control=reno
sysctl -w net.ipv4.tcp_congestion_control=bbr
```

### 11.2 setsockopt 接口

```c
#include <netinet/tcp.h>

int sock = socket(AF_INET, SOCK_STREAM, 0);

// 获取当前算法
char name[256];
socklen_t len = sizeof(name);
getsockopt(sock, IPPROTO_TCP, TCP_CONGESTION, name, &len);

// 设置为 BBR
setsockopt(sock, IPPROTO_TCP, TCP_CONGESTION, "bbr", 4);
```

### 11.3 内核算法注册

```c
// net/ipv4/tcp_cong.c
static int __init tcp_cong_register(void)
{
    // 注册 Reno（基础算法）
    tcp_register_congestion_control(&tcp_reno);

    // 注册 CUBIC（默认）
    tcp_register_congestion_control(&tcp_cubic);

    // 注册 BBR
    tcp_register_congestion_control(&tcp_bbr);

    return 0;
}
```

---

## 12. 计时器与重传

### 12.1 重传计时器

```c
// net/ipv4/tcp_timer.c
static void tcp_retransmit_timer(struct sock *sk)
{
    struct tcp_sock *tp = tcp_sk(sk);

    if (tp->fastopen && !tp->fastopen_fail) {
        // Fast Open 重传
        tcp_fastopen_synack_timer(sk);
        return;
    }

    // 超时：进入损耗状态
    if (!tp->packets_out)
        goto out;

    tp->retrans_out++;

    // 拥塞控制
    if (tcp_retransmit_skb(sk, tcp_write_queue_head(sk)) > 0) {
        // 重传失败，继续计时
        sk_reset_timer(sk, &tp-> retrans_timer, jiffies + HZ/2);
        goto out;
    }

    tcp_enter_loss(sk, 1);  // 进入 loss 状态
    tcp_retransmit_timer_start(sk, TCP_RTO_MS);
}
```

### 12.2 RTO 计算

```c
// net/ipv4/tcp_input.c
void tcp_set_rto(struct tcp_sock *tp, const u32 rtt)
{
    // SRTT（平滑 RTT）
    tp->srtt = (tp->srtt >> 3) + rtt;
    // RTTVAR（偏差）
    tp->mdev = ((tp->mdev >> 2) + abs((s32)(rtt - tp->srtt))) >> 2;
    tp->mdev_max = max(tp->mdev, tp->mdev_max);
    tp->rttvar = tp->mdev;
    tp->rtt_seq = tp->snd_nxt;

    // RTO = SRTT + 4 * RTTVAR
    inet_csk(sk)->icsk_rto = (tp->srtt >> 3) + (tp->rttvar >> 2);
}
```

---

## 13. 调试接口

### 13.1 /proc 接口

```bash
# 查看所有可用算法
cat /proc/sys/net/ipv4/tcp_available_congestion_control

# 查看当前使用
cat /proc/sys/net/ipv4/tcp_congestion_control

# 查看拥塞窗口历史
cat /proc/net/snmp | grep TcpExt

# 查看各算法统计
cat /proc/net/netstat | grep TcpExt
```

### 13.2 ss 命令

```bash
# 查看连接使用的拥塞算法
ss -i

# 示例输出
State      Recv-Q  Send-Q   Local Address:Port   Peer Address:Port
ESTAB      0       0        10.0.0.1:443        10.0.0.2:54321
    cubic wscale:7,7 rto:200 rtt:10/20 ato:40 cwnd:10
```

---

## 14. 总结

| 算法    | 拥塞信号  | 特点                                  |
| ------- | --------- | ------------------------------------- |
| Reno    | 丢包      | 简单有效，TCP 基础算法                |
| CUBIC   | 丢包      | Linux 默认，三次多项式，Wmax 附近稳定 |
| BBR     | 带宽+RTT  | Google 开发，无队列，高带宽利用率     |
| Hystart | RTT 增长  | CUBIC 附件，提前退出慢启动            |
| ECN     | IP ECN 位 | 显式通知，不依赖丢包                  |

拥塞控制是 TCP 最重要的特性之一，决定了网络利用率和公平性。现代内核默认使用 CUBIC，但在特定场景（长肥管道、高延迟链路）BBR 有明显优势。
