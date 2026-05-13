---
title: "Kernel Protocol Stack 深度探索 (二十一)：TCP 头部结构"
date: 2026-04-13
tags:
  [linux, kernel, networking, series, tcp, header, transmission-control-protocol, options, checksum]
description: "深入解析 TCP 协议头部——标准字段、选项、标志位、校验和计算、MSS/WS/TSopt/SACK/UTO 等选项详解"
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
> 21. **第二十一章：TCP 头部结构**

---

## 1. 概述：TCP 头部

TCP（Transmission Control Protocol，传输控制协议）是面向连接的可靠传输协议，提供：

- 面向连接：三次握手建立连接，四次挥手断开
- 可靠传输：确认、重传、序列号
- 流量控制：滑动窗口机制
- 拥塞控制：慢启动、拥塞避免、快速恢复

---

## 2. TCP 头部结构

### 2.1 标准 TCP 头部

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|          Source Port          |       Destination Port        |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                        Sequence Number                        |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                    Acknowledgment Number                      |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
| Offset |  Reserved   |U|A|P|R|S|F|            Window         |
|        |             |R|C|S|S|Y|I|                            |
|        |             |G|K|H|T|N|N|                            |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|           Checksum            |         Urgent Pointer        |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                    Options and Padding                        |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                             Data                              |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

### 2.2 字段说明

| 字段                  | 位宽 | 说明                             |
| --------------------- | ---- | -------------------------------- |
| Source Port           | 16   | 源端口号                         |
| Destination Port      | 16   | 目的端口号                       |
| Sequence Number       | 32   | 序列号，当前包的第一个字节编号   |
| Acknowledgment Number | 32   | 确认号，期望收到的下一个字节编号 |
| Data Offset           | 4    | TCP 头部长度（4 字节为单位）     |
| Reserved              | 6    | 保留字段，必须为 0               |
| Flags                 | 6    | URG/ACK/PSH/RST/SYN/FIN          |
| Window                | 16   | 接收窗口大小，流量控制           |
| Checksum              | 16   | 校验和                           |
| Urgent Pointer        | 16   | 紧急数据指针                     |
| Options               | 可变 | TCP 选项                         |

### 2.3 内核 TCP 头结构

```c
// include/uapi/linux/tcp.h
struct tcphdr {
    __be16  source;         // 源端口
    __be16  dest;           // 目的端口
    __be32  seq;            // 序列号
    __be32  ack_seq;        // 确认号
#if defined(__LITTLE_ENDIAN_BITFIELD)
    __u8    doff:4,         // 数据偏移（头部长度）
            res1:4;         // 保留
#elif defined(__BIG_ENDIAN_BITFIELD)
    __u8    res1:4,
            doff:4;
#endif
    __u8    fin:1,          // FIN 标志
            syn:1,          // SYN 标志
            rst:1,          // RST 标志
            psh:1,          // PSH 标志
            ack:1,          // ACK 标志
            urg:1,          // URG 标志
            ece:1,          // ECN Echo
            cwr:1;          // Congestion Window Reduced
    __be16  window;        // 窗口大小
    __sum16 check;         // 校验和
    __be16  urg_ptr;       // 紧急指针
};

// TCP 头部长度
#define TCP_MIN_HLEN     20
#define TCP_MAX_HLEN     60
```

---

## 3. TCP 标志位详解

### 3.1 六种标志位

| 标志 | 名称           | 说明                     |
| ---- | -------------- | ------------------------ |
| URG  | Urgent         | 紧急指针有效             |
| ACK  | Acknowledgment | 确认号有效               |
| PSH  | Push           | 催促接收，立即交付应用层 |
| RST  | Reset          | 重置连接                 |
| SYN  | Synchronize    | 同步序列号（建立连接）   |
| FIN  | Finish         | 结束连接                 |

### 3.2 ECN 标志位

| 标志 | 名称                      | 说明             |
| ---- | ------------------------- | ---------------- |
| ECE  | ECN-Echo                  | ECN 拥塞提醒回显 |
| CWR  | Congestion Window Reduced | 拥塞窗口已减小   |

### 3.3 常见组合

| 组合        | 含义             |
| ----------- | ---------------- |
| SYN         | 连接建立请求     |
| SYN+ACK     | 同意建立连接     |
| ACK         | 确认             |
| FIN         | 关闭连接请求     |
| FIN+ACK     | 同意关闭连接     |
| RST         | 突然重置（错误） |
| PSH+ACK     | 数据尽快交付     |
| PSH+ACK+URG | 紧急数据         |

---

## 4. TCP 选项

### 4.1 选项格式

```
+---------+---------+-------------------+
|  Kind   | Length  |     Value         |
| (1 byte)| (1 byte)| (Length-2 bytes)  |
+---------+---------+-------------------+
```

**结束选项（Kind=0）：** 用于分隔多个选项，必须出现在选项列表末尾。

**无操作选项（Kind=1）：** 用于对齐，不强制使用。

### 4.2 常见选项

| Kind | 名称           | 长度 | 说明           |
| ---- | -------------- | ---- | -------------- |
| 0    | End of Options | 1    | 选项列表结束   |
| 1    | NOP            | 1    | 无操作，对齐用 |
| 2    | MSS            | 4    | 最大报文段大小 |
| 3    | Window Scale   | 3    | 窗口扩大因子   |
| 4    | SACK Permitted | 2    | 支持 SACK      |
| 5    | SACK           | 可变 | 选择性确认     |
| 8    | Timestamps     | 10   | 时间戳         |
| 28   | UTO            | 4    | 用户超时       |
| 29   | AO             | 可变 | 认证选项       |

### 4.3 MSS 选项（Kind=2）

```c
// Maximum Segment Size
struct tcp_options_mss {
    __u8    kind;           // 2
    __u8    length;         // 4
    __be16  mss;            // MSS 值
};

// 典型值：1460（1500 MTU - 20 IP - 20 TCP）
// 本端通告的 MSS 是本端能接收的最大段
```

### 4.4 Window Scale 选项（Kind=3）

```c
// Window Scaling
struct tcp_options_ws {
    __u8    kind;           // 3
    __u8    length;         // 3
    __u8    shift;          // 移位值（0-14）
};

// Shift 范围：0-14，最大窗口 = 65535 * 2^shift
// shift=0:  65535 bytes
// shift=7:  8 MB
// shift=14: 1 GB
```

### 4.5 SACK 选项（Kind=4, 5）

```c
// SACK Permitted (建立连接时)
struct tcp_options_sack_permitted {
    __u8    kind;           // 4
    __u8    length;         // 2
};

// SACK Block (Kind=5)
struct tcp_options_sack {
    __u8    kind;           // 5
    __u8    length;         // 可变（8 + 8*n）
    __be32  left_edge[];    // 左边界
    __be32  right_edge[];   // 右边界
};

// 示例：两个 SACK 块
// Kind=5, Length=18
// left=1000, right=1500
// left=2000, right=2500
```

### 4.6 Timestamps 选项（Kind=8）

```c
// Timestamps
struct tcp_options_ts {
    __u8    kind;           // 8
    __u8    length;         // 10
    __be32  ts_val;         // 时间戳值
    __be32  ts_ecr;         // 时间戳回显
};

// 功能：
// 1. RTTM (Round-Trip Time Measurement)
// 2. PAWS (Protection Against Wrapped Sequence Numbers)
// 3. 时间戳回显用于 RTT 计算
```

### 4.7 内核选项解析

```c
// net/ipv4/tcp_input.c - TCP 选项解析
static void tcp_parse_options(struct sock *sk, struct sk_buff *skb,
                              struct tcp_request_sock *treq,
                              bool want_cookie)
{
    struct tcphdr *th = tcp_hdr(skb);
    struct inet_connection_sock *icsk = inet_csk(sk);
    int length = th->doff * 4 - TCP_MIN_HLEN;
    unsigned char *ptr = (unsigned char *)(th + 1);

    while (length > 0) {
        int opcode = *ptr++;
        int opsize;

        switch (opcode) {
        case TCPOPT_EOL:
            return;
        case TCPOPT_NOP:
            length--;
            continue;
        case TCPOPT_MSS:
            opsize = *(ptr + 1);
            if (opsize == TCPOLEN_MSS) {
                __u16 mss = ntohs(*(__be16 *)ptr);
                tcp_mss_update(sk, mss, ...);
            }
            break;
        case TCPOPT_WINDOW:
            opsize = *(ptr + 1);
            if (opsize == TCPOLEN_WINDOW) {
                icsk->icsk_ack.rcv_wscale = *(unsigned char *)ptr;
            }
            break;
        case TCPOPT_SACK:
            // 解析 SACK 选项
            break;
        case TCPOPT_TIMESTAMP:
            // 解析时间戳
            break;
        }
        ptr += opsize;
        length -= opsize;
    }
}
```

---

## 5. 校验和计算

### 5.1 TCP 校验和范围

```
+-----------------+------------------+------------------+
|  Pseudo Header  |   TCP Header     |     Data         |
|   (12 bytes)    |  (variable)     |   (variable)     |
+-----------------+------------------+------------------+
```

### 5.2 Pseudo Header 结构

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                         Source Address                        |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                       Destination Address                    |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|  Zero  | Proto |            TCP Length                       |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

### 5.3 校验和算法

```c
// 计算 TCP 校验和
__sum16 tcp_v4_check(int len, __be32 saddr, __be32 daddr,
                     __sum16 base)
{
    return csum_tcpudp_nofold(saddr, daddr, len, IPPROTO_TCP, base);
}

// 完整校验和计算
static __sum16 tcp_checksum_complete(struct sk_buff *skb)
{
    // 包括 pseudo header + tcp header + data
    return __skb_checksum_complete(skb);
}
```

### 5.4 校验和验证

```c
// net/ipv4/tcp_ipv4.c - 接收时校验
int tcp_v4_do_rcv(struct sock *sk, struct sk_buff *skb)
{
    // 硬件校验和验证
    if (skb->ip_summed == CHECKSUM_UNNECESSARY) {
        // 网卡已验证，跳过
    } else if (skb_csum_unnecessary(skb)) {
        // 其他方式验证
    } else {
        // 内核软件验证
        if (tcp_checksum_complete(skb))
            goto csum_error;
    }
    return tcp_queue_rcv(sk, skb, skb, &tcp_header_manager);
}
```

---

## 6. TCP 选项实战

### 6.1 查看连接选项

```bash
# 查看当前连接的 TCP 选项
cat /proc/net/tcp

# 使用 ss 查看详细信息
ss -i

# 示例输出
State      Recv-Q Send-Q Local Address:Port  Peer Address:Port
ESTAB      0      0      10.0.0.1:22          10.0.0.2:45678
         ts sack wscale:7,7 rtt:0.5/1
         mss:1448 pmtu:1500 rcvmss:1448 advmss:1448
```

### 6.2 抓包分析

```bash
# 抓取 SYN 包查看选项
tcpdump -i eth0 'tcp[tcpflags] == tcp-syn' -v

# 详细输出
# 18:00:00.123456 IP 10.0.0.1.45678 > 10.0.0.2.22: Flags [S],
#     seq 12345, win 65535, options [mss 1460, sackOK,
#     TS val 100 ecr 0, nop, wscale 7], length 0
```

### 6.3 调整 TCP 选项

```bash
# 启用时间戳
sysctl -w net.ipv4.tcp_timestamps=1

# 启用 SACK
sysctl -w net.ipv4.tcp_sack=1

# 启用窗口扩大
sysctl -w net.ipv4.tcp_window_scaling=1

# 查看当前配置
sysctl net.ipv4.tcp_timestamps
sysctl net.ipv4.tcp_sack
sysctl net.ipv4.tcp_window_scaling
```

---

## 7. 序列号与确认号

### 7.1 序列号作用

| 作用     | 说明               |
| -------- | ------------------ |
| 可靠性   | 确认已接收的数据   |
| 有序性   | 检测乱序           |
| 流量控制 | 配合窗口大小       |
| 连接建立 | SYN 占用一个序列号 |
| 连接关闭 | FIN 占用一个序列号 |

### 7.2 ISN（Initial Sequence Number）

```c
// net/ipv4/tcp.c - ISN 生成
static __u32 tcp_v4_init_sequence(struct sk_buff *skb)
{
    // 使用 MD5 混合生成 ISN
    return secure_tcp_isn((__force __be32)ip_hdr(skb)->saddr,
                          (__force __be32)ip_hdr(skb)->daddr,
                          tcp_hdr(skb)->source,
                          tcp_hdr(skb)->dest);
}

// 防止序列号预测攻击
// ISN = M + F(local_ip, local_port, remote_ip, remote_port, secret)
```

### 7.3 ACK 确认机制

```
发送方:
  序列号 1000，发送 100 字节数据
  序列号 1100，发送 100 字节数据
  序列号 1200，发送 100 字节数据

接收方:
  ACK 1200  # 表示已接收 1200 之前的所有数据
```

### 7.4 选择性确认（SACK）

```
丢包场景（丢失 1100-1199）：

正常 ACK：
  接收方 ACK 1100  # 只能确认到丢失前

SACK：
  接收方 ACK 1200
  接收方 SACK (1200, 1300)  # 告知已收到后续数据
  发送方只重传 1100-1199
```

---

## 8. 窗口机制

### 8.1 窗口大小字段

```
窗口大小字段：16 bits
最大值：65535 bytes

启用 Window Scaling 后：
实际窗口 = 窗口字段 * 2^shift
```

### 8.2 窗口扩大因子

```bash
# 内核支持的最大 shift
sysctl net.ipv4.tcp_window_scaling

# 查看当前连接的实际窗口
ss -tm

# 示例
# mem: rss(，活动连接内存) rmem(接收缓冲) wmem(发送缓冲)
# skmem:(r0,rb131072,t0,tb16384,w0,z131459424,wb0)
# 131072 = 128KB 接收窗口（默认）
```

### 8.3 窗口更新

```c
// 当接收缓冲区变化时，更新窗口
void tcp_rcv_space_adjust(struct sock *sk)
{
    int rcv_wnd = tcp_receive_window(sk);
    struct tcp_sock *tp = tcp_sk(sk);

    // 发送窗口更新（不含 ACK）
    if (rcv_wnd > tp->rcv_wnd)
        tp->rcv_wnd = rcv_wnd;
}
```

---

## 9. 紧急指针

### 9.1 URG 机制

```c
// 紧急数据：用于带外数据（Out-of-Band）
// 例如：TCP 连接中断信号

struct {
    URG=1,          // URG 标志置位
    Urgent Pointer=15,  // 指向紧急数据结束位置
} tcp_header;

// 紧急数据位置：seq = ack_seq + urgent_ptr
```

### 9.2 使用场景

```bash
# 紧急数据示例
# 客户端发送中断信号（Ctrl+C）
send(sock, "^C", 2, MSG_OOB);

# 接收端收到 URG 通知
# 可以通过 socket OOB 机制接收
recv(sock, buffer, size, MSG_OOB);
```

---

## 10. 总结

TCP 头部结构要点：

**固定字段（20 字节）：**

1. 源/目的端口（各 2 字节）
2. 序列号（4 字节）
3. 确认号（4 字节）
4. 数据偏移 + 保留 + 标志（2 字节）
5. 窗口大小（2 字节）
6. 校验和 + 紧急指针（4 字节）

**关键选项：**

1. MSS：协商最大报文段
2. Window Scale：扩展窗口
3. SACK：选择性确认
4. Timestamps：RTT 测量

**重要机制：**

1. 序列号用于可靠传输和有序交付
2. 校验和覆盖 Pseudo Header + TCP 头 + 数据
3. 窗口机制实现流量控制
4. URG 用于带外数据
