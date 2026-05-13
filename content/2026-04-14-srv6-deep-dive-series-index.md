---
title: "SRv6 深度探索系列索引"
date: 2026-04-14
pin: true
description: "SRv6 (Segment Routing over IPv6) 深度探索全系列——从 MPLS 演进到 SD-WAN、云骨干网，涵盖 SRv6 基础、Segment 列表、SRH、SRv6 VPN、FlexAlgo、网络编程、云厂商实践、性能优化与故障诊断，40+ 章节系统性解析"
tags:
  - srv6
  - series
  - networking
  - segment-routing
  - sdn
  - ipv6
  - mpls
---

# SRv6 深度探索系列

> [!tip] 系列说明
> 本系列约 40+ 篇文章，从 MPLS 的演进历史出发，系统讲解 SRv6（Segment Routing over IPv6）的核心概念、SRH 扩展头、网络编程能力、SRv6 VPN、云骨干网部署、FlexAlgo 流量工程、SRv6 与 SR-MPLS 的对比、云厂商（阿里云/华为云/AWS）实践、性能优化与故障诊断。适合网络工程师、SD-WAN 架构师、云网络开发者。
>
> 配合 [[2026-04-13-vpn-deep-dive-series-index|VPN 与翻墙系列]]（隧道与加密通信）和 [[2026-04-14-quic-deep-dive-series-index|QUIC 系列]]（传输层协议），构成完整的"现代网络协议"知识体系。

---

## Part I：Segment Routing 基础 (Fundamentals)

从 MPLS 到 SR 的演进，理解 SR 的核心价值。

| #   | 章节                                           | 主题                   | 状态                                                 |
| --- | ---------------------------------------------- | ---------------------- | ---------------------------------------------------- | --- |
| 1   | [[2026-04-14-srv6-deep-dive-ch1-mpls-evolution | MPLS 演进]]            | MPLS 标签交换、RSVP-TE、LDP、为什么需要 SR           | 🚧  |
| 2   | [[2026-04-14-srv6-deep-dive-ch2-sr-overview    | Segment Routing 概述]] | SR 核心概念、Segment/Segment List、Source Routing    | 🚧  |
| 3   | [[2026-04-14-srv6-deep-dive-ch3-sr-mpls        | SR-MPLS]]              | SR-MPLS 原理、Prefix-SID/Node-SID/Adj-SID            | 🚧  |
| 4   | [[2026-04-14-srv6-deep-dive-ch4-srv6-origin    | SRv6 起源]]            | 为什么需要 SRv6、IPv6 原生优势、与 SR-MPLS 对比      | 🚧  |
| 5   | [[2026-04-14-srv6-deep-dive-ch5-sid            | Segment IDentifier]]   | SID 结构、Locator/Function/Argument、End/End.X/End.T | 🚧  |

---

## Part II：SRv6 协议详解 (Protocol)

SRv6 的二进制格式与各层协议。

| #   | 章节                                               | 主题            | 状态                                                  |
| --- | -------------------------------------------------- | --------------- | ----------------------------------------------------- | --- |
| 6   | [[2026-04-14-srv6-deep-dive-ch6-ipv6-extension     | IPv6 扩展头]]   | 逐跳选项/目标选项/路由头、Extension Header 排序       | 🚧  |
| 7   | [[2026-04-14-srv6-deep-dive-ch7-srh                | SRH 详解]]      | Segment Routing Header、Segment List、Segment Entries | 🚧  |
| 8   | [[2026-04-14-srv6-deep-dive-ch8-srv6-packet        | SRv6 报文结构]] | 外层 IPv6、SRH、载荷、MTU 处理                        | 🚧  |
| 9   | [[2026-04-14-srv6-deep-dive-ch9-srv6-behaviors     | SRv6 Behavior]] | End/End.X/End.T/End.DX2/End.DX6/End.DT4/End.DT6       | 🚧  |
| 10  | [[2026-04-14-srv6-deep-dive-ch10-srv6-microprogram | SRv6 微程序]]   | uSID/uN/uDT、网络编程组合、转发平面                   | 🚧  |

---

## Part III：SRv6 转发机制 (Forwarding)

SRv6 的数据平面转发原理。

| #   | 章节                                         | 主题            | 状态                                              |
| --- | -------------------------------------------- | --------------- | ------------------------------------------------- | --- |
| 11  | [[2026-04-14-srv6-deep-dive-ch11-forwarding  | SRv6 转发流程]] | PSP/USP/ST Flavor、Upper HL / Lower HL、HL=0 处理 | 🚧  |
| 12  | [[2026-04-14-srv6-deep-dive-ch12-srv6-vanity | SRv6 Vanity]]   | 压缩 SID、uSID 格式、uN/uSF/uA                    | 🚧  |
| 13  | [[2026-04-14-srv6-deep-dive-ch13-ti-lfa      | TI-LFA]]        | Topology-Independent LFA、SRv6 快速收敛           | 🚧  |
| 14  | [[2026-04-14-srv6-deep-dive-ch14-sr-policy   | SR Policy]]     | SR Policy、Candidate Path、Optimization Objective | 🚧  |

---

## Part IV：SRv6 VPN (VPN)

SRv6 在 VPN 场景的应用。

| #   | 章节                                           | 主题            | 状态                               |
| --- | ---------------------------------------------- | --------------- | ---------------------------------- | --- |
| 15  | [[2026-04-14-srv6-deep-dive-ch15-srv6-vpn      | SRv6 VPN 概述]] | SRv6 VPN 架构、与 MPLS VPN 对比    | 🚧  |
| 16  | [[2026-04-14-srv6-deep-dive-ch16-srv6-evpn     | SRv6 EVPN]]     | EVPN + SRv6、ESI、LACP、DF选举     | 🚧  |
| 17  | [[2026-04-14-srv6-deep-dive-ch17-srv6-vpn-vpls | SRv6 VPLS]]     | VPLS over SRv6、MAC 学习、泛洪抑制 | 🚧  |
| 18  | [[2026-04-14-srv6-deep-dive-ch18-srv6-ioam     | SRv6 IOAM]]     | In-situ OAM、随流检测、Telemetry   | 🚧  |

---

## Part V：流量工程 (Traffic Engineering)

SRv6 的流量工程能力。

| #   | 章节                                               | 主题          | 状态                                            |
| --- | -------------------------------------------------- | ------------- | ----------------------------------------------- | --- |
| 19  | [[2026-04-14-srv6-deep-dive-ch19-flex-algo         | FlexAlgo]]    | Flexible Algorithm、IGP 算法约束、延迟/带宽优先 | ✅  |
| 20  | [[2026-04-14-srv6-deep-dive-ch20-sr-te             | SR-TE]]       | SR-TE 隧道、路径计算、PCE/ PCC                  | ✅  |
| 21  | [[2026-04-14-srv6-deep-dive-ch21-steering          | 流量导向]]    | 流量导向、LFA/RLFA/TI-LFA、ECMP                 | ✅  |
| 22  | [[2026-04-14-srv6-deep-dive-ch22-sr-traffic-matrix | SR 流量矩阵]] | 流量矩阵测量、TE 优化、自动调优                 | ✅  |

---

## Part VI：SD-WAN 与云骨干 (Cloud)

SRv6 在 SD-WAN 和云骨干网的应用。

| #   | 章节                                           | 主题            | 状态                                          |
| --- | ---------------------------------------------- | --------------- | --------------------------------------------- | --- |
| 23  | [[2026-04-14-srv6-deep-dive-ch23-sdwan         | SRv6 SD-WAN]]   | SD-WAN 架构、CPE/Zscaler/Palo Alto 集成       | 🚧  |
| 24  | [[2026-04-14-srv6-deep-dive-ch24-alibaba-cloud | 阿里云 SRv6]]   | 阿里云 ENS、SRv6 骨干网、全球互联             | 🚧  |
| 25  | [[2026-04-14-srv6-deep-dive-ch25-huawei-cloud  | 华为云 SRv6]]   | 华为云云骨干、Imaster NCE、Campus             | 🚧  |
| 26  | [[2026-04-14-srv6-deep-dive-ch26-aws-srv6      | AWS SRv6]]      | AWS Direct Connect + SRv6、TGW、Route Manager | 🚧  |
| 27  | [[2026-04-14-srv6-deep-dive-ch27-multi-cloud   | SRv6 多云互联]] | Multi-Cloud 架构、端到端 SRv6、统一控制面     | 🚧  |

---

## Part VII：SRv6 配置与运维 (Operations)

IOS XR / Junos / Linux 配置实战。

| #   | 章节                                        | 主题            | 状态                                      |
| --- | ------------------------------------------- | --------------- | ----------------------------------------- | --- |
| 28  | [[2026-04-14-srv6-deep-dive-ch28-ios-xr     | Cisco IOS XR]]  | IOS XR SRv6 配置、IS-IS/SR、End.DT4       | 🚧  |
| 29  | [[2026-04-14-srv6-deep-dive-ch29-junos      | Juniper Junos]] | Junos SRv6 配置、EVPN/VXLAN 集成          | 🚧  |
| 30  | [[2026-04-14-srv6-deep-dive-ch30-linux-srv6 | Linux SRv6]]    | Linux SRv6 支持、iproute2、srPT、功能验证 | 🚧  |
| 31  | [[2026-04-14-srv6-deep-dive-ch31-bgp-srv6   | BGP SRv6]]      | BGP L2/B3 族、SRv6 VPN、Route Target      | 🚧  |
| 32  | [[2026-04-14-srv6-deep-dive-ch32-spring     | SPRING]]        | SPRING/SR 使能、IGP 集成、BGP 集成        | 🚧  |

---

## Part VIII：故障诊断 (Troubleshooting)

SRv6 网络的排错与监控。

| #   | 章节                                        | 主题              | 状态                                     |
| --- | ------------------------------------------- | ----------------- | ---------------------------------------- | --- |
| 33  | [[2026-04-14-srv6-deep-dive-ch33-srv6-debug | SRv6 排错]]       | 常见错误、Segment 失效、TTL 处理         | ✅  |
| 34  | [[2026-04-14-srv6-deep-dive-ch34-srv6-trace | SRv6 traceroute]] | SRv6 traceroute、Path Tracing、Telemetry | ✅  |
| 35  | [[2026-04-14-srv6-deep-dive-ch35-srv6-perf  | 性能监控]]        | SRv6 开销、MTU / Fragment、吞吐量测试    | ✅  |
| 36  | [[2026-04-14-srv6-deep-dive-ch36-srv6-tools | SRv6 工具]]       | Wireshark/Scapy、SRv6 过滤器、模拟器     | ✅  |

---

## Part IX：高级话题 (Advanced)

SRv6 高级特性与新技术。

| #   | 章节                                               | 主题               | 状态                                           |
| --- | -------------------------------------------------- | ------------------ | ---------------------------------------------- | --- |
| 37  | [[2026-04-14-srv6-deep-dive-ch37-srv6-security     | SRv6 安全]]        | SRv6 安全威胁、ACL、IPSec 加密                 | ✅  |
| 38  | [[2026-04-14-srv6-deep-dive-ch38-srv6-security-rfc | SRv6 SAVAL/uRPF]]  | Source Address Validation、uRPF、Anti-spoofing | ✅  |
| 39  | [[2026-04-14-srv6-deep-dive-ch39-srv6-ipsec        | SRv6 + IPsec]]     | SRv6 + IPsec、加密节点、Full-Stack 安全        | ✅  |
| 40  | [[2026-04-14-srv6-deep-dive-ch40-srv6-perf         | SRv6 Performance]] | SRv6 转发性能、HW vs SW、TCAM                  | ✅  |

---

## Part X：对比与演进 (Comparison)

SRv6 与其他技术的对比及未来趋势。

| #   | 章节 | 主题                                               | 状态                |
| --- | ---- | -------------------------------------------------- | ------------------- | -------------------------------------- | --- |
|     | 41   | [[2026-04-14-srv6-deep-dive-ch41-srv6-vs-mpls      | SRv6 vs SR-MPLS]]   | SR-MPLS vs SRv6、选型决策树            | ✅  |
|     | 42   | [[2026-04-14-srv6-deep-dive-ch42-srv6-vs-vxlan     | SRv6 vs VXLAN]]     | SRv6 + EVPN vs VXLAN、Overlay/Underlay | ✅  |
|     | 43   | [[2026-04-14-srv6-deep-dive-ch43-srv6-vs-wireguard | SRv6 vs WireGuard]] | SRv6 加密 vs WireGuard、场景对比       | ✅  |
|     | 44   | [[2026-04-14-srv6-deep-dive-ch44-srv6-vs-sdwan     | SRv6 vs SD-WAN]]    | 传统 SD-WAN vs SRv6-based SD-WAN       | ✅  |
|     | 45   | [[2026-04-14-srv6-deep-dive-ch45-srv6-future       | SRv6 未来]]         | IETF 标准化、SRv6+QUIC、网络编程趋势   | ✅  |

---

## 相关系列

- [[2026-04-13-vpn-deep-dive-series-index|VPN 与翻墙系列]] — 隧道与加密通信
- [[2026-04-14-quic-deep-dive-series-index|QUIC 系列]] — 传输层协议
- [[2026-04-09-dpdk-deep-dive-series-index|DPDK 深度探索系列]] — 用户态数据包处理
- [[2026-04-13-rdma-deep-dive-series-index|RDMA 深度探索系列]] — 超低延迟 RDMA
