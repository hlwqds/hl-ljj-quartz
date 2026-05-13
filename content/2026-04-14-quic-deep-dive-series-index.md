---
title: "QUIC 深度探索系列索引"
date: 2026-04-14
pin: true
description: "QUIC 深度探索全系列——从协议基础到落地实现，涵盖 Wire Format、多路复用、0-RTT 连接、拥塞控制、BBR/CUBIC、丢包检测、连接迁移、HTTP/3、QUIC 实现对比（lsquic/msquic/quiche/ngtcp2）、性能调优、DPDK+QUIC、移动网络优化，44+ 章节系统性解析"
tags:
  - quic
  - series
  - networking
  - performance
  - http3
  - protocol
---

# QUIC 深度探索系列

> [!tip] 系列说明
> 本系列约 44+ 篇文章，从 QUIC 的核心设计理念（传输层加密、多路复用、0-RTT）出发，系统讲解协议规范、帧结构、连接管理、拥塞控制、与 TCP/TLS/HTTP/2 的对比、落地实现（lsquic/msquic/quiche/ngtcp2）、性能优化、云原生部署与移动网络场景。适合网络协议开发者、Web 性能工程师、分布式系统架构师。
>
> 配合 [[2026-04-09-dpdk-deep-dive-series-index|DPDK 深度探索系列]]（用户态数据包处理）和 [[2026-04-13-rdma-deep-dive-series-index|RDMA 深度探索系列]]（超低延迟 RDMA），构成完整的"高性能网络"知识体系。

---

## Part I：QUIC 基础 (Fundamentals)

理解 QUIC 的设计理念、核心优势、与 TCP/TLS/HTTP/2 的本质区别。

| # | 章节 | 主题 | 状态 |
|---|------|------|------|
| 1 | [[2026-04-14-quic-deep-dive-ch1-quic-overview|QUIC 概述]] | 起源、IETF 标准化、与 TCP/TLS 对比、核心优势 | 🚧 |
| 2 | [[2026-04-14-quic-deep-dive-ch2-protocol-design|协议设计理念]] | 队头阻塞根治、连接迁移、0-RTT、加密独立性 | 🚧 |
| 3 | [[2026-04-14-quic-deep-dive-ch3-wire-format|Wire Format]] | 字段结构、包类型、Connection ID、Token | 🚧 |
| 4 | [[2026-04-14-quic-deep-dive-ch4-version-negotiation|版本协商]] | Version Negotiation 包、版本协商机制、回退策略 | 🚧 |
| 5 | [[2026-04-14-quic-deep-dive-ch5-connection-id|Connection ID]] | SCID/DCID、连接迁移、地址无关性、CID 路由 | 🚧 |

---

## Part II：连接建立 (Connection Establishment)

QUIC 握手的三阶段（加密传输 + 握手 + 0-RTT）。

| # | 章节 | 主题 | 状态 |
|---|------|------|------|
| 6 | [[2026-04-14-quic-deep-dive-ch6-handshake|QUIC 握手流程]] | Initial/Handshake/0-RTT 包、密钥派生、TLS 1.3 集成 | 🚧 |
| 7 | [[2026-04-14-quic-deep-dive-ch7-0-rtt|0-RTT 连接]] | 0-RTT 原理、重放攻击、前向保密、限制与约束 | 🚧 |
| 8 | [[2026-04-14-quic-deep-dive-ch8-1-rtt|1-RTT 连接]] | 完整握手时序、密钥更新、密钥phase | 🚧 |
| 9 | [[2026-04-14-quic-deep-dive-ch9-session-resumption|Session Resumption]] | Session Ticket、0-RTT vs 1-RTT、状态复用 | 🚧 |
| 10 | [[2026-04-14-quic-deep-dive-ch10-tls-integration|TLS 1.3 集成]] | TLS 消息与 QUIC 帧映射、密钥导出、AEAD | 🚧 |

---

## Part III：帧结构与报文 (Frames & Packets)

QUIC 各层帧的二进制格式与语义。

| # | 章节 | 主题 | 状态 |
|---|------|------|------|
| 11 | [[2026-04-14-quic-deep-dive-ch11-packet-types|包类型详解]] | Initial/Handshake/Short Header、Long Header 变体 | 🚧 |
| 12 | [[2026-04-14-quic-deep-dive-ch12-frames|帧类型]] | PADDING/PING/ACK/CRYPTO/STREAM/DATA_BLOCKED | 🚧 |
| 13 | [[2026-04-14-quic-deep-dive-ch13-stream-frames|STREAM 帧]] | Stream ID/Off/Fin/Data 分片、流转控 | 🚧 |
| 14 | [[2026-04-14-quic-deep-dive-ch14-ack-frames|ACK 帧]] | ACK Ranges、ECN、Delay Time、触发重传 | 🚧 |
| 15 | [[2026-04-14-quic-deep-dive-ch15-crypto-frames|CRYPTO 帧]] | CRYPTO 数据流、TLS message boundary、offset | 🚧 |

---

## Part IV：多路复用与流量控制 (Multiplexing & Flow Control)

QUIC 如何在单一连接内实现高效的多 Stream 复用。

| # | 章节 | 主题 | 状态 |
|---|------|------|------|
| 16 | [[2026-04-14-quic-deep-dive-ch16-stream-multiplexing|Stream 多路复用]] | Stream ID、并发 Stream、帧交错 | 🚧 |
| 17 | [[2026-04-14-quic-deep-dive-ch17-flow-control|流量控制]] | Connection 级/Stream 级、窗口更新、WINDOW_UPDATE | 🚧 |
| 18 | [[2026-04-14-quic-deep-dive-ch18-connection-migration|连接迁移]] | CID 切换、地址验证、PATH_CHALLENGE/RESPONSE | 🚧 |
| 19 | [[2026-04-14-quic-deep-dive-ch19-head-of-line-blocking|队头阻塞]] | TCP HOL vs HTTP/2 HOL vs QUIC Stream HOL | 🚧 |

---

## Part V：丢包检测与拥塞控制 (Loss Detection & Congestion Control)

QUIC 的可靠性保证与拥塞控制算法实现。

| # | 章节 | 主题 | 状态 |
|---|------|------|------|
| 20 | [[2026-04-14-quic-deep-dive-ch20-loss-detection|丢包检测]] | Timer-based/PTO、ACK 触发、probe 机制 | 🚧 |
| 21 | [[2026-04-14-quic-deep-dive-ch21-ack-frequency|ACK Frequency]] | ACK Frequency 帧、减少 ACK 频率、带宽节省 | 🚧 |
| 22 | [[2026-04-14-quic-deep-dive-ch22-rtt-estimation|RTT 估算]] | RTT 组成、min_rtt/smoothed_rtt/rttvar | 🚧 |
| 23 | [[2026-04-14-quic-deep-dive-ch23-congestion-control|拥塞控制概述]] | 慢启动/拥塞避免/PRR、CUBIC/Reno | 🚧 |
| 24 | [[2026-04-14-quic-deep-dive-ch24-bbr|BBR]] | BBR 算法原理、pacing gain、cwnd 推导 | 🚧 |
| 25 | [[2026-04-14-quic-deep-dive-ch25-copa|COPA]] | Copa 算法、弹性速率、延迟敏感场景 | 🚧 |

---

## Part VI：HTTP/3 (HTTP over QUIC)

QUIC 最主要的落地场景：HTTP/3。

| # | 章节 | 主题 | 状态 |
|---|------|------|------|
| 26 | [[2026-04-14-quic-deep-dive-ch26-http3-overview|HTTP/3 概述]] | HTTP/3 需求、QPACK、QPACK 表 | 🚧 |
| 27 | [[2026-04-14-quic-deep-dive-ch27-qpack|QPACK 编码]] | 动态表/静态表、Indexed/Immediate/Literal | 🚧 |
| 28 | [[2026-04-14-quic-deep-dive-ch28-http-frames|HTTP 帧]] | HEADERS/DATA/SETTINGS/PRIORITY/GOAWAY | 🚧 |
| 29 | [[2026-04-14-quic-deep-dive-ch29-server-push|Server Push]] | Server Push 语义、推送流、取消推送 | 🚧 |
| 30 | [[2026-04-14-quic-deep-dive-ch30-h3-vs-h2|HTTP/2 vs HTTP/3]] | 队头阻塞、握手对比、部署策略 | 🚧 |

---

## Part VII：连接管理 (Connection Management)

连接状态机、关闭、地址验证、安全考量。

| # | 章节 | 主题 | 状态 |
|---|------|------|------|
| 31 | [[2026-04-14-quic-deep-dive-ch31-state-machine|连接状态机]] | Handshake/Confirmed/draining、状态转换 | ✅ |
| 32 | [[2026-04-14-quic-deep-dive-ch32-connection-shutdown|连接关闭]] | CONNECTION_CLOSE、GOAWAY、错误码体系 | ✅ |
| 33 | [[2026-04-14-quic-deep-dive-ch33-address-validation|地址验证]] | PATH_CHALLENGE/RESPONSE、Retry、Preferred Address | ✅ |
| 34 | [[2026-04-14-quic-deep-dive-ch34-packetization|Packetization]] | MTU/MSS、分片策略、PMTUD | ✅ |

---

## Part VIII：落地实现 (Implementations)

主流 QUIC 库深度对比与性能分析。

| # | 章节 | 主题 | 状态 |
|---|------|------|------|
| 35 | [[2026-04-14-quic-deep-dive-ch35-msquic|Microsoft msquic]] | 微软实现、架构、UWP/WinRT 集成 | ✅ |
| 36 | [[2026-04-14-quic-deep-dive-ch36-quiche|Cloudflare quiche]] | Rust 实现、tokio 集成、curl 集成 | ✅ |
| 37 | [[2026-04-14-quic-deep-dive-ch37-lsquic|lsquic]] | LiteSpeed quic、LiteSpeed 产品线 | ✅ |
| 38 | [[2026-04-14-quic-deep-dive-ch38-ngtcp2|ngtcp2]] | ngtcp2 + libngtcp2 + libssl、C++ | ✅ |
| 39 | [[2026-04-14-quic-deep-dive-ch39-go-quic|Go QUIC]] | quic-go、quicly、Go 生态 | ✅ |
| 40 | [[2026-04-14-quic-deep-dive-ch40-impl-comparison|实现对比]] | 性能对比（throughput/latency）、特性矩阵 | ✅ |

---

## Part IX：性能优化与部署 (Performance & Deployment)

生产环境部署与极致性能调优。

| # | 章节 | 主题 | 状态 |
|---|---|---|---|
| 41 | [[2026-04-14-quic-deep-dive-ch41-tuning|性能调优]] | 内核参数、bbr sysctl、pacing_rate 调优 | ✅ |
| 42 | [[2026-04-14-quic-deep-dive-ch42-dpdk-quic|DPDK + QUIC]] | 用户态 QUIC、DPDK 集成、加速 | ✅ |
| 43 | [[2026-04-14-quic-deep-dive-ch43-proxy|代理与负载均衡]] | QUIC 代理、负载均衡器、Anycast | ✅ |
| 44 | [[2026-04-14-quic-deep-dive-ch44-mobile|Mobile 场景]] | 移动网络切换、慢启动优化、电量节省 | ✅ |

---

## Part X：高级话题与未来 (Advanced & Future)

前沿技术与协议演进。

| # | 章节 | 主题 | 状态 |
|---|------|------|------|
| 45 | [[2026-04-14-quic-deep-dive-ch45-datagram|QUIC Datagram]] | DATAGRAM 帧、无序传输、实时光 | 🚧 |
| 46 | [[2026-04-14-quic-deep-dive-ch46-multipath|多路径 QUIC]] | MPQUIC、并行多路径、耦合拥控 | 🚧 |
| 47 | [[2026-04-14-quic-deep-dive-ch47-quic-vpn|QUIC VPN]] | QUIC 隧道代理、WireGuard vs QUIC | 🚧 |
| 48 | [[2026-04-14-quic-deep-dive-ch48-wireshark|Wireshark 抓包]] | QUIC 过滤器、WireShark 解密 TLS、明文调试 | 🚧 |
| 49 | [[2026-04-14-quic-deep-dive-ch49-future|QUIC 未来]] | 标准演进 (RFC 9000)、IETF 方向 | 🚧 |

---

## 相关系列

- [[2026-04-09-dpdk-deep-dive-series-index|DPDK 深度探索系列]] — 用户态数据包处理
- [[2026-04-13-rdma-deep-dive-series-index|RDMA 深度探索系列]] — 超低延迟 RDMA
- [[2026-04-13-vpn-deep-dive-series-index|VPN 与翻墙系列]] — 隧道与加密通信
- [[2026-04-08-ebpf-deep-dive-series-index|eBPF 深度探索系列]] — 内核可编程观测
