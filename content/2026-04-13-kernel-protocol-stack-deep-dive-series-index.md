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
> 配合 [[2026-04-09-dpdk-deep-dive-series-index|DPDK 深度探索系列]] 和 [[2026-04-08-ebpf-deep-dive-series-index|eBPF 深度探索系列]]，构成"内核网络协议栈 → 用户态加速 → eBPF 可编程观测"的完整知识体系。

---

## Part I：基础框架 (Foundation)

理解 Linux 内核网络栈的核心数据结构与驱动框架。

| #   | 章节                                                         | 主题                       | 状态                                        |
| --- | ------------------------------------------------------------ | -------------------------- | ------------------------------------------- | --- |
| 1   | [[2026-04-13-kernel-protocol-stack-deep-dive-ch1-skbuff      | SK_buff 与数据包生命周期]] | sk_buff 结构、分配释放、克隆分片、DMA 交互  | ✅  |
| 2   | [[2026-04-13-kernel-protocol-stack-deep-dive-ch2-netdevice   | Netdevice 与网卡抽象]]     | net_device、驱动注册、发送接收路径、NAPI    | ✅  |
| 3   | [[2026-04-13-kernel-protocol-stack-deep-dive-ch3-ring-buffer | Ring Buffer 与 DMA]]       | 环形缓冲区、TX/RX 队列、page_pool、DMA 映射 | ✅  |
| 4   | [[2026-04-13-kernel-protocol-stack-deep-dive-ch4-softirq     | 软中断与 ksoftirqd]]       | 软中断上下文、net_rx_action、napi_poll      | ✅  |
| 5   | [[2026-04-13-kernel-protocol-stack-deep-dive-ch5-napi        | NAPI 与轮询模式]]          | NAPI 实现、dynirq、interrupt moderation     | ✅  |

---

## Part II：L2 链路层 (Data Link)

MAC 层、交换与虚拟网卡技术。

| #   | 章节                                                      | 主题                 | 状态                                      |
| --- | --------------------------------------------------------- | -------------------- | ----------------------------------------- | --- |
| 6   | [[2026-04-13-kernel-protocol-stack-deep-dive-ch6-ethernet | Ethernet 与 MAC 层]] | 以太网帧格式、MAC 地址学习、交换机基础    | ✅  |
| 7   | [[2026-04-13-kernel-protocol-stack-deep-dive-ch7-bridge   | 网桥与 Switchdev]]   | bridge 驱动、VLAN 过滤、switchdev offload | ✅  |
| 8   | [[2026-04-13-kernel-protocol-stack-deep-dive-ch8-vlan     | VLAN 与 802.1Q]]     | VLAN tag、trunk、QinQ、vlan_group         | ✅  |
| 9   | [[2026-04-13-kernel-protocol-stack-deep-dive-ch9-macvlan  | MACVLAN 与虚拟网卡]] | macvlan、macvtap、ipvlan、veth pair       | ✅  |
| 10  | [[2026-04-13-kernel-protocol-stack-deep-dive-ch10-bonding | Bonding 与 teamd]]   | 负载均衡、active-backup、LAG、LACP        | ✅  |

---

## Part III：L3 网络层 (Network)

IP 路由、转发、隧道与互联技术。

| #   | 章节                                                         | 主题                   | 状态                                          |
| --- | ------------------------------------------------------------ | ---------------------- | --------------------------------------------- | --- |
| 11  | [[2026-04-13-kernel-protocol-stack-deep-dive-ch11-ip-framing | IP 协议封装]]          | IPv4/IPv6 头部、checksum、分片重组            | ✅  |
| 12  | [[2026-04-13-kernel-protocol-stack-deep-dive-ch12-routing    | Routing 与 FIB]]       | 路由查找、fib_table、路由缓存历史             | ✅  |
| 13  | [[2026-04-13-kernel-protocol-stack-deep-dive-ch13-neighbor   | Neighbor 与 ARP]]      | ARP/NDP、neigh_table、Gratuitous ARP          | ✅  |
| 14  | [[2026-04-13-kernel-protocol-stack-deep-dive-ch14-iptables   | iptables 基础框架]]    | Netfilter 钩子、tables/chains/rules、扩展匹配 | ✅  |
| 15  | [[2026-04-13-kernel-protocol-stack-deep-dive-ch15-conntrack  | 连接跟踪 Conntrack]]   | nf_conntrack、状态机、NAT 辅助                | ✅  |
| 16  | [[2026-04-13-kernel-protocol-stack-deep-dive-ch16-nat        | NAT 与地址转换]]       | SNAT/DNAT、端口复用、conntrack NAT            | ✅  |
| 17  | [[2026-04-13-kernel-protocol-stack-deep-dive-ch17-gre        | GRE 隧道]]             | GRE 封装、tap/tun、IP隧道                     | ✅  |
| 18  | [[2026-04-13-kernel-protocol-stack-deep-dive-ch18-vxlan      | VXLAN 覆盖网络]]       | VXLAN 封装、VTEP、组播/unicast                | ✅  |
| 19  | [[2026-04-13-kernel-protocol-stack-deep-dive-ch19-geneve     | GENEVE 与 OVN]]        | GENEVE 通用封装、OVN 逻辑网络                 | ✅  |
| 20  | [[2026-04-13-kernel-protocol-stack-deep-dive-ch20-fib-rules  | FIB Rules 与策略路由]] | ip rule、基于 fwmark 的策略路由               | ✅  |

---

## Part IV：L4 传输层 (Transport)

TCP/UDP 协议实现与连接管理。

| #   | 章节                                                              | 主题                 | 状态                              |
| --- | ----------------------------------------------------------------- | -------------------- | --------------------------------- | --- |
| 21  | [[2026-04-13-kernel-protocol-stack-deep-dive-ch21-tcp-headers     | TCP 协议实现 (上)]]  | TCP 头部、选项、状态机            | ✅  |
| 22  | [[2026-04-13-kernel-protocol-stack-deep-dive-ch22-tcp-states      | TCP 协议实现 (中)]]  | 连接建立/断开、三次握手、四次挥手 | ✅  |
| 23  | [[2026-04-13-kernel-protocol-stack-deep-dive-ch23-tcp-data-buffer | TCP 协议实现 (下)]]  | 数据传输、滑动窗口、重传机制      | ✅  |
| 24  | [[2026-04-13-kernel-protocol-stack-deep-dive-ch24-tcp-congestion  | TCP 拥塞控制]]       | Reno/CUBIC/BBR、拥塞窗口、慢启动  | ✅  |
| 25  | [[2026-04-13-kernel-protocol-stack-deep-dive-ch25-tcp-advanced    | TCP 高级特性]]       | SACK、DSACK、TFO、fast open       | ✅  |
| 26  | [[2026-04-13-kernel-protocol-stack-deep-dive-ch26-udp             | UDP 协议实现]]       | UDP 头部、multicast、校验和       | ✅  |
| 27  | [[2026-04-13-kernel-protocol-stack-deep-dive-ch27-raw-socket      | RAW Socket 与 ICMP]] | RAW 套接字、ICMP、路由控制消息    | ✅  |

---

## Part V：Socket 层 (Socket)

POSIX socket API 与内核实现。

| #   | 章节                                                          | 主题                 | 状态                                  |
| --- | ------------------------------------------------------------- | -------------------- | ------------------------------------- | --- |
| 28  | [[2026-04-13-kernel-protocol-stack-deep-dive-ch28-socket-api  | Socket API 概述]]    | socket/connect/send/recv、文件描述符  | ✅  |
| 29  | [[2026-04-13-kernel-protocol-stack-deep-dive-ch29-inet-sock   | Inet Socket 实现]]   | struct sock、inet_sock、端口复用      | ✅  |
| 30  | [[2026-04-13-kernel-protocol-stack-deep-dive-ch30-sock-mem    | Socket 内存管理]]    | sk_wmem_alloc、skb mem pressure、回收 | ✅  |
| 31  | [[2026-04-13-kernel-protocol-stack-deep-dive-ch31-netlink     | Netlink 通信机制]]   | netlink 协议族、rtnetlink、genetlink  | ✅  |
| 32  | [[2026-04-13-kernel-protocol-stack-deep-dive-ch32-unix-socket | Unix Domain Socket]] | AF_UNIX、UDS 通信、ancillary data     | ✅  |

---

## Part VI：Netfilter 与安全 (Netfilter & Security)

防火墙、QoS 与内核网络安全框架。

| #   | 章节                                                                  | 主题                    | 状态                                             |
| --- | --------------------------------------------------------------------- | ----------------------- | ------------------------------------------------ | --- |
| 33  | [[2026-04-13-kernel-protocol-stack-deep-dive-ch33-netfilter-hook      | Netfilter 框架详解]]    | 5 个钩子点、NF_HOOK 宏、注册机制、NFPROTO_NETDEV | ✅  |
| 34  | [[2026-04-13-kernel-protocol-stack-deep-dive-ch34-iptables-ext        | iptables 扩展]]         | conntrack/hashlimit/string/recent/ipset 扩展     | ✅  |
| 35  | [[2026-04-13-kernel-protocol-stack-deep-dive-ch35-qos                 | Linux QoS 与流量控制]]  | tc/qdisc/HTB/CAKE/FQ-CoDel/eBPF cls_bpf          | ✅  |
| 36  | [[2026-04-13-kernel-protocol-stack-deep-dive-ch36-nftables            | nftables 新一代防火墙]] | nftables 语法、set/map、flowtable、原子更新      | ✅  |
| 37  | [[2026-04-13-kernel-protocol-stack-deep-dive-ch37-conntrack-internals | Conntrack 内部机制]]    | conntrack 哈希表、超时、GC、ALG、ctnetlink       | ✅  |
| 38  | [[2026-04-13-kernel-protocol-stack-deep-dive-ch38-nat-deep            | NAT 深度解析]]          | NAT 类型、端口冲突、fullcone/hairpin/seq-adjust  | ✅  |
| 39  | [[2026-04-13-kernel-protocol-stack-deep-dive-ch39-xdp-integration     | XDP 与高性能处理]]      | XDP hook、AF_XDP 零拷贝、DDoS 防护               | ✅  |

---

## Part VII：高级特性与优化 (Advanced)

offload、GSO/GRO 与性能调优。

| #   | 章节                                                       | 主题                 | 状态                               |
| --- | ---------------------------------------------------------- | -------------------- | ---------------------------------- | --- |
| 40  | [[2026-04-13-kernel-protocol-stack-deep-dive-ch40-gro-gso  | GRO 与 GSO]]         | Generic GRO/GSO、dev_gro_receive   | ✅  |
| 41  | [[2026-04-13-kernel-protocol-stack-deep-dive-ch41-rss-rps  | RSS 与 RPS]]         | Receive Side Scaling、softirq 分布 | ✅  |
| 42  | [[2026-04-13-kernel-protocol-stack-deep-dive-ch42-tso      | TSO 与 UFO]]         | TCP Segmentation Offload、UFO      | ✅  |
| 43  | [[2026-04-13-kernel-protocol-stack-deep-dive-ch43-bpf-hook | Linux BPF 网络钩子]] | TC BPF、XDP BPF、cls_bpf           | ✅  |
| 44  | [[2026-04-13-kernel-protocol-stack-deep-dive-ch44-offload  | 硬件 Offload]]       | 智能网卡、flow director、RDMA      | ✅  |
| 45  | [[2026-04-13-kernel-protocol-stack-deep-dive-ch45-tuning   | 网络性能调优]]       | sysctl 参数、队列长度、拥塞参数    | ✅  |

---

## 相关系列

- [[2026-04-09-dpdk-deep-dive-series-index|DPDK 深度探索系列]] — 用户态数据包处理（47 章节）
- [[2026-04-08-ebpf-deep-dive-series-index|eBPF 深度探索系列]] — 内核可编程观测（42+ 章节）
- [[2026-04-09-vpp-deep-dive-series-index|VPP 深度探索系列]] — Vector Packet Processing（26 章节）
