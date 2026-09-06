---
title: "Kernel Protocol Stack 深度探索系列索引"
date: 2026-04-13
pin: true
description: "Linux 内核网络协议栈完整学习路径——从 sk_buff 到 Netfilter，涵盖 L2/L3/L4、Socket、隧道、offload 等 45 章节的系统性深度解析"
tags:
  - linux
  - kernel
  - networking
  - series
  - index
---

# Kernel Protocol Stack 深度探索系列

> [!tip] 系列说明
> 本系列 45 篇文章，从 Linux 内核网络栈最底层的数据结构 sk_buff 出发，系统讲解网卡驱动、Netdevice、软中断、Ring Buffer、L2/L3/L4 协议实现、Socket API、Netfilter 全套框架，最终覆盖隧道、offload 与性能优化。适合有一定网络基础的开发者系统性进阶。
>
> 配合 [[dpdk-deep-dive|DPDK 深度探索系列]] 和 [[ebpf-deep-dive|eBPF 深度探索系列]]，构成"内核网络协议栈 → 用户态加速 → eBPF 可编程观测"的完整知识体系。

---

## Linux 内核网络栈自顶向下总图

下面以常见 Linux 6.x IPv4 主路径为基线。图中省略了大量错误处理、分片、隧道、
IPsec、namespace、VRF 和硬件 offload 分支，但保留了排障时最重要的层次和钩子。

```text
┌────────────────────────────────────────────────────────────────────────────┐
│                             用户空间                                       │
│                                                                            │
│  application                                                              │
│  connect / accept / sendmsg / recvmsg / read / write / epoll               │
└────────────────────────────────────┬───────────────────────────────────────┘
                                     │ system call
                                     ▼
┌────────────────────────────────────────────────────────────────────────────┐
│                         VFS 与 Socket API                                   │
│                                                                            │
│  file descriptor → struct socket → struct sock                             │
│  sock_sendmsg / sock_recvmsg / socket lookup / wait queue                  │
└───────────────────────┬───────────────────────────────────▲────────────────┘
                        │ TX                                │ RX
                        ▼                                   │
┌────────────────────────────────────────────────────────────────────────────┐
│                           L4 传输层                                         │
│                                                                            │
│  TCP: tcp_sendmsg → send queue → congestion/retransmit → tcp_write_xmit    │
│       tcp_v4_rcv → socket lookup → TCP state machine → receive queue       │
│                                                                            │
│  UDP: udp_sendmsg → udp_send_skb                                           │
│       udp_rcv → socket lookup → receive queue                              │
└───────────────────────┬───────────────────────────────────▲────────────────┘
                        │                                   │
                        ▼                                   │
┌────────────────────────────────────────────────────────────────────────────┐
│                            L3 IP 层                                         │
│                                                                            │
│  本机发送: route selected → ip_local_out → [NF LOCAL_OUT] → output         │
│  本地接收: route/input → [NF LOCAL_IN] → ip_local_deliver                  │
│  路由转发: [NF PRE_ROUTING] → FIB → ip_forward → [NF FORWARD]              │
│  发出前:   [NF POST_ROUTING] → fragmentation/GSO → neighbor                │
│                                                                            │
│  conntrack / DNAT / SNAT 通常挂在上述 Netfilter hook 上                    │
└───────────────────────┬───────────────────────────────────▲────────────────┘
                        │                                   │
                        ▼                                   │
┌────────────────────────────────────────────────────────────────────────────┐
│                       邻居、L2 与虚拟设备层                                 │
│                                                                            │
│  ARP/NDP → neighbour table → Ethernet header                               │
│  bridge / VLAN / bonding / veth / macvlan / tunnel / namespace             │
│                                                                            │
│  TX: dev_queue_xmit → TC egress → qdisc → netdev TX queue                  │
│  RX: netif_receive_skb → TC ingress → rx_handler → L2/L3 protocol handler  │
└───────────────────────┬───────────────────────────────────▲────────────────┘
                        │                                   │
                        ▼                                   │
┌────────────────────────────────────────────────────────────────────────────┐
│                         Netdevice 与驱动                                    │
│                                                                            │
│  TX: ndo_start_xmit → map DMA → TX descriptor → doorbell                   │
│  RX: IRQ → schedule NAPI → driver poll → XDP → build skb → GRO             │
└───────────────────────┬───────────────────────────────────▲────────────────┘
                        │                                   │
                        ▼                                   │
┌────────────────────────────────────────────────────────────────────────────┐
│                           NIC 硬件                                          │
│                                                                            │
│  TX/RX ring ─ DMA ─ RSS ─ checksum/TSO/LRO offload ─ physical wire          │
└────────────────────────────────────────────────────────────────────────────┘
```

### 一句话理解

```text
发送：进程把字节交给 socket，协议栈把字节变成 skb，路由决定出口，
      邻居子系统补二层头，qdisc 决定发送时机，驱动把 descriptor 交给 NIC。

接收：NIC 把帧 DMA 到内存，NAPI 批量取包，XDP/TC/L2/L3 逐层分类，
      路由决定本地接收还是转发，传输层找到 socket，进程最终读走数据。
```

### 本机发送函数链

TCP 和 UDP 在 L4 内部不同，进入 IP 层后逐步汇合：

```text
userspace
  sendmsg()/write()
    │
    ▼
sock_sendmsg()
  │
  ├─ TCP
  │   tcp_sendmsg()
  │     → copy/attach data to write queue
  │     → tcp_push()
  │     → tcp_write_xmit()
  │     → tcp_transmit_skb()
  │     → ip_queue_xmit()
  │
  └─ UDP
      udp_sendmsg()
        → ip_make_skb()
        → udp_send_skb()
        → ip_send_skb()
              │
              ▼
          ip_local_out()
              │
              ├─ Netfilter LOCAL_OUT
              ▼
          dst_output() / ip_output()
              │
              ├─ Netfilter POST_ROUTING
              ▼
          ip_finish_output()
              → neighbour output / ARP-NDP
              → dev_queue_xmit()
              → TC egress
              → qdisc enqueue/dequeue
              → dev_hard_start_xmit()
              → driver ndo_start_xmit()
              → TX ring / DMA / NIC
              → wire
```

注意：

- `sendmsg()` 成功通常只表示数据进入内核发送路径，不代表对端已经收到；
- TCP 可能因为 cork、Nagle、拥塞窗口、发送窗口或 pacing 暂缓真正发包；
- GSO/TSO 下一个大 `skb` 可能到驱动或 NIC 才被切成多个线速报文；
- loopback、本机目的地址和虚拟设备可能不会到达物理 NIC。

### 本地接收函数链

```text
wire
  → NIC receives frame
  → DMA into RX buffer
  → MSI-X interrupt
  → napi_schedule()
  → NET_RX_SOFTIRQ / net_rx_action()
  → driver napi poll()
  → XDP
      ├─ XDP_DROP
      ├─ XDP_TX
      ├─ XDP_REDIRECT
      └─ XDP_PASS
  → napi_gro_receive() / GRO
  → netif_receive_skb()
  → __netif_receive_skb_core()
      ├─ packet taps: AF_PACKET / tcpdump
      ├─ TC ingress
      ├─ rx_handler: bridge/bond/macvlan 等
      └─ protocol handler
  → ip_rcv()
  → Netfilter PRE_ROUTING
  → ip_rcv_finish()
  → FIB input route
  → ip_local_deliver()
  → Netfilter LOCAL_IN
  → ip_local_deliver_finish()
      ├─ tcp_v4_rcv()
      │   → socket lookup
      │   → TCP state/sequence processing
      │   → socket receive queue
      │
      └─ udp_rcv()
          → socket lookup
          → socket receive queue
  → wake up process / epoll readiness
  → recvmsg()/read()
```

这里有三个重要边界：

1. **XDP 早于 `skb` 主路径**：native XDP 通常在驱动 NAPI poll 中操作 RX buffer；
2. **GRO 会改变包的观察形态**：协议栈看到的 `skb` 数量可能少于线上的报文数；
3. **tcpdump 不是最早观察点**：包可能在 XDP 或更早的硬件规则中被丢弃。

### 三层转发函数链

目的地址不是本机且允许转发时，不进入本地 socket：

```text
NIC RX
  → NAPI / GRO
  → netif_receive_skb()
  → ip_rcv()
  → Netfilter PRE_ROUTING
      └─ DNAT / conntrack may run here
  → FIB input route
  → ip_forward()
  → Netfilter FORWARD
  → ip_forward_finish()
  → dst_output() / ip_output()
  → Netfilter POST_ROUTING
      └─ SNAT / masquerade may run here
  → neighbour output
  → dev_queue_xmit()
  → qdisc / driver / TX ring
  → next hop
```

二层 bridge 转发与三层 IP 转发不同。bridge 可以在 L2 根据 FDB 直接选择出口，
只有需要进入 IP 层、路由、本机协议栈或 bridge netfilter 时才走相应的 L3 路径。

### 五个 Netfilter IPv4 钩子

```text
incoming wire
      │
      ▼
 PRE_ROUTING
      │
      ▼
 route decision
      │
      ├─ local destination → LOCAL_IN → local process
      │
      └─ forwarding       → FORWARD ─────────┐
                                             │
local process → LOCAL_OUT ───────────────────┤
                                             ▼
                                       POST_ROUTING
                                             │
                                             ▼
                                        outgoing wire
```

更准确地看：

| 数据路径       | 经过的主要 IPv4 hook                   |
| -------------- | -------------------------------------- |
| 外部到本机     | `PRE_ROUTING → LOCAL_IN`               |
| 本机到外部     | `LOCAL_OUT → POST_ROUTING`             |
| 外部经本机转发 | `PRE_ROUTING → FORWARD → POST_ROUTING` |

### 处理上下文速查

| 阶段                     | 常见执行上下文         | 关键约束                                |
| ------------------------ | ---------------------- | --------------------------------------- |
| `sendmsg()` 到协议栈发送 | 进程上下文             | 可以睡眠，但持锁区和热路径应短          |
| 硬中断处理               | hardirq                | 只确认事件并调度 NAPI，不能做重活       |
| NAPI/接收协议栈          | softirq 或 NAPI thread | 不能随意睡眠，受 budget/time limit 约束 |
| `ksoftirqd/N`            | 内核线程               | softirq 负载过高时接管，延迟可能上升    |
| socket 数据读取          | 进程上下文             | 无数据时阻塞，或由 epoll 通知           |

### 排障时从哪一层开始

```text
应用是否产生/消费数据
  → socket 状态与队列
  → TCP/UDP 统计
  → 路由与策略路由
  → Netfilter/conntrack/NAT
  → neighbor/ARP/NDP
  → qdisc/TC
  → netdev 统计
  → NAPI/softirq/CPU
  → driver ring/descriptor
  → NIC/链路/交换机
```

自顶向下适合回答“应用为什么不通”；自底向上适合回答“网卡收到的包去了哪里”。
实际排障通常需要在中间选一个可观测点，例如 socket、Netfilter counter、
TC、tcpdump 或驱动统计，然后向两侧缩小范围。

---

## Part I：基础框架 (Foundation)

理解 Linux 内核网络栈的核心数据结构与驱动框架。

| #   | 章节              | 主题                       | 状态                                        |
| --- | ----------------- | -------------------------- | ------------------------------------------- | --- |
| 1   | [[ch1-skbuff      | SK_buff 与数据包生命周期]] | sk_buff 结构、分配释放、克隆分片、DMA 交互  | ✅  |
| 2   | [[ch2-netdevice   | Netdevice 与网卡抽象]]     | net_device、驱动注册、发送接收路径、NAPI    | ✅  |
| 3   | [[ch3-ring-buffer | Ring Buffer 与 DMA]]       | 环形缓冲区、TX/RX 队列、page_pool、DMA 映射 | ✅  |
| 4   | [[ch4-softirq     | 软中断与 ksoftirqd]]       | 软中断上下文、net_rx_action、napi_poll      | ✅  |
| 5   | [[ch5-napi        | NAPI 与轮询模式]]          | NAPI 实现、dynirq、interrupt moderation     | ✅  |

---

## Part II：L2 链路层 (Data Link)

MAC 层、交换与虚拟网卡技术。

| #   | 章节           | 主题                 | 状态                                      |
| --- | -------------- | -------------------- | ----------------------------------------- | --- |
| 6   | [[ch6-ethernet | Ethernet 与 MAC 层]] | 以太网帧格式、MAC 地址学习、交换机基础    | ✅  |
| 7   | [[ch7-bridge   | 网桥与 Switchdev]]   | bridge 驱动、VLAN 过滤、switchdev offload | ✅  |
| 8   | [[ch8-vlan     | VLAN 与 802.1Q]]     | VLAN tag、trunk、QinQ、vlan_group         | ✅  |
| 9   | [[ch9-macvlan  | MACVLAN 与虚拟网卡]] | macvlan、macvtap、ipvlan、veth pair       | ✅  |
| 10  | [[ch10-bonding | Bonding 与 teamd]]   | 负载均衡、active-backup、LAG、LACP        | ✅  |

---

## Part III：L3 网络层 (Network)

IP 路由、转发、隧道与互联技术。

| #   | 章节              | 主题                   | 状态                                          |
| --- | ----------------- | ---------------------- | --------------------------------------------- | --- |
| 11  | [[ch11-ip-framing | IP 协议封装]]          | IPv4/IPv6 头部、checksum、分片重组            | ✅  |
| 12  | [[ch12-routing    | Routing 与 FIB]]       | 路由查找、fib_table、路由缓存历史             | ✅  |
| 13  | [[ch13-neighbor   | Neighbor 与 ARP]]      | ARP/NDP、neigh_table、Gratuitous ARP          | ✅  |
| 14  | [[ch14-iptables   | iptables 基础框架]]    | Netfilter 钩子、tables/chains/rules、扩展匹配 | ✅  |
| 15  | [[ch15-conntrack  | 连接跟踪 Conntrack]]   | nf_conntrack、状态机、NAT 辅助                | ✅  |
| 16  | [[ch16-nat        | NAT 与地址转换]]       | SNAT/DNAT、端口复用、conntrack NAT            | ✅  |
| 17  | [[ch17-gre        | GRE 隧道]]             | GRE 封装、tap/tun、IP隧道                     | ✅  |
| 18  | [[ch18-vxlan      | VXLAN 覆盖网络]]       | VXLAN 封装、VTEP、组播/unicast                | ✅  |
| 19  | [[ch19-geneve     | GENEVE 与 OVN]]        | GENEVE 通用封装、OVN 逻辑网络                 | ✅  |
| 20  | [[ch20-fib-rules  | FIB Rules 与策略路由]] | ip rule、基于 fwmark 的策略路由               | ✅  |

---

## Part IV：L4 传输层 (Transport)

TCP/UDP 协议实现与连接管理。

| #   | 章节                   | 主题                 | 状态                              |
| --- | ---------------------- | -------------------- | --------------------------------- | --- |
| 21  | [[ch21-tcp-headers     | TCP 协议实现 (上)]]  | TCP 头部、选项、状态机            | ✅  |
| 22  | [[ch22-tcp-states      | TCP 协议实现 (中)]]  | 连接建立/断开、三次握手、四次挥手 | ✅  |
| 23  | [[ch23-tcp-data-buffer | TCP 协议实现 (下)]]  | 数据传输、滑动窗口、重传机制      | ✅  |
| 24  | [[ch24-tcp-congestion  | TCP 拥塞控制]]       | Reno/CUBIC/BBR、拥塞窗口、慢启动  | ✅  |
| 25  | [[ch25-tcp-advanced    | TCP 高级特性]]       | SACK、DSACK、TFO、fast open       | ✅  |
| 26  | [[ch26-udp             | UDP 协议实现]]       | UDP 头部、multicast、校验和       | ✅  |
| 27  | [[ch27-raw-socket      | RAW Socket 与 ICMP]] | RAW 套接字、ICMP、路由控制消息    | ✅  |

---

## Part V：Socket 层 (Socket)

POSIX socket API 与内核实现。

| #   | 章节               | 主题                 | 状态                                  |
| --- | ------------------ | -------------------- | ------------------------------------- | --- |
| 28  | [[ch28-socket-api  | Socket API 概述]]    | socket/connect/send/recv、文件描述符  | ✅  |
| 29  | [[ch29-inet-sock   | Inet Socket 实现]]   | struct sock、inet_sock、端口复用      | ✅  |
| 30  | [[ch30-sock-mem    | Socket 内存管理]]    | sk_wmem_alloc、skb mem pressure、回收 | ✅  |
| 31  | [[ch31-netlink     | Netlink 通信机制]]   | netlink 协议族、rtnetlink、genetlink  | ✅  |
| 32  | [[ch32-unix-socket | Unix Domain Socket]] | AF_UNIX、UDS 通信、ancillary data     | ✅  |

---

## Part VI：Netfilter 与安全 (Netfilter & Security)

防火墙、QoS 与内核网络安全框架。

| #   | 章节                       | 主题                    | 状态                                             |
| --- | -------------------------- | ----------------------- | ------------------------------------------------ | --- |
| 33  | [[ch33-netfilter-hook      | Netfilter 框架详解]]    | 5 个钩子点、NF_HOOK 宏、注册机制、NFPROTO_NETDEV | ✅  |
| 34  | [[ch34-iptables-ext        | iptables 扩展]]         | conntrack/hashlimit/string/recent/ipset 扩展     | ✅  |
| 35  | [[ch35-qos                 | Linux QoS 与流量控制]]  | tc/qdisc/HTB/CAKE/FQ-CoDel/eBPF cls_bpf          | ✅  |
| 36  | [[ch36-nftables            | nftables 新一代防火墙]] | nftables 语法、set/map、flowtable、原子更新      | ✅  |
| 37  | [[ch37-conntrack-internals | Conntrack 内部机制]]    | conntrack 哈希表、超时、GC、ALG、ctnetlink       | ✅  |
| 38  | [[ch38-nat-deep            | NAT 深度解析]]          | NAT 类型、端口冲突、fullcone/hairpin/seq-adjust  | ✅  |
| 39  | [[ch39-xdp-integration     | XDP 与高性能处理]]      | XDP hook、AF_XDP 零拷贝、DDoS 防护               | ✅  |

---

## Part VII：高级特性与优化 (Advanced)

offload、GSO/GRO 与性能调优。

| #   | 章节            | 主题                 | 状态                               |
| --- | --------------- | -------------------- | ---------------------------------- | --- |
| 40  | [[ch40-gro-gso  | GRO 与 GSO]]         | Generic GRO/GSO、dev_gro_receive   | ✅  |
| 41  | [[ch41-rss-rps  | RSS 与 RPS]]         | Receive Side Scaling、softirq 分布 | ✅  |
| 42  | [[ch42-tso      | TSO 与 UFO]]         | TCP Segmentation Offload、UFO      | ✅  |
| 43  | [[ch43-bpf-hook | Linux BPF 网络钩子]] | TC BPF、XDP BPF、cls_bpf           | ✅  |
| 44  | [[ch44-offload  | 硬件 Offload]]       | 智能网卡、flow director、RDMA      | ✅  |
| 45  | [[ch45-tuning   | 网络性能调优]]       | sysctl 参数、队列长度、拥塞参数    | ✅  |

---

## 相关系列

- [[dpdk-deep-dive|DPDK 深度探索系列]] — 用户态数据包处理（47 章节）
- [[ebpf-deep-dive|eBPF 深度探索系列]] — 内核可编程观测（42+ 章节）
- [[vpp-deep-dive|VPP 深度探索系列]] — Vector Packet Processing（26 章节）
