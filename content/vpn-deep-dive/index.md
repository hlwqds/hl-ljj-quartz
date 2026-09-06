---
title: "VPN 与翻墙技术深度探索系列索引"
date: 2026-04-13
pin: true
description: "VPN 与翻墙技术全景深度探索——涵盖隧道协议(GRE/IPIP)、传统VPN(PPTP/L2TP/OpenVPN)、现代VPN(IPSec/WireGuard)、翻墙技术(Shadowsocks/V2Ray/Trojan/Clash)、零信任(SDP/ZTNA)，50+章节系统性解析"
tags:
  - vpn
  - series
  - networking
  - security
  - proxy
  - index
---

# VPN 与翻墙技术深度探索系列

> [!tip] 系列说明
> 本系列 50+ 篇文章，从 VPN 基础与翻墙原理出发，系统讲解隧道协议、传统 VPN、现代 VPN（IPSec/WireGuard）、翻墙技术（SS/V2Ray/Trojan/Clash）、远程接入与零信任，最终覆盖性能优化与安全加固。适合网络工程师、安全工程师和需要理解网络隧道的开发者。
>
> 配合 [[kernel-protocol-stack-deep-dive|Kernel Protocol Stack 系列]] 和 [[ebpf-deep-dive|eBPF 系列]]，构成完整的网络知识体系。

---

## Part I：基础概念 (Fundamentals)

理解 VPN 与翻墙的本质、分类与核心组件。

| #   | 章节                      | 主题             | 状态                                               |
| --- | ------------------------- | ---------------- | -------------------------------------------------- | --- |
| 1   | [[ch1-vpn-fundamentals    | VPN 与翻墙基础]] | VPN 定义、翻墙原理、GFW 简介、隧道模式             | 🚧  |
| 2   | [[ch2-tunnel-basics       | 隧道技术基础]]   | tun/tap 虚拟设备、隧道封装解封装、tunnel interface | ✅  |
| 3   | [[ch3-crypto-fundamentals | 密码学基础]]     | 对称加密(AES)、非对称加密(RSA/ECC)、DH、HMAC       | ✅  |
| 4   | [[ch4-authentication      | 身份认证基础]]   | PKI/CA、X.509 证书、PSK、RADIUS/LDAP               | ✅  |

---

## Part II：隧道协议 (Tunneling)

IP 层隧道技术，VPN 的基础构建块。

| #   | 章节               | 主题               | 状态                                 |
| --- | ------------------ | ------------------ | ------------------------------------ | --- |
| 5   | [[ch5-gre          | GRE 通用路由封装]] | GRE 头格式、键控 GRE、PMTUD、NHS     | ✅  |
| 6   | [[ch6-ipip         | SIT 隧道]]         | IP in IP、SIT、6to4/4to6/ISATAP      | ✅  |
| 7   | [[ch7-mpls-vpn     | MPLS VPN]]         | MPLS 标签、L3VPN (VRF)、L2VPN (VPLS) | ✅  |
| 8   | [[ch8-vxlan-tunnel | VXLAN 覆盖网络]]   | VXLAN 封装、VNI、VTEP、组播/unicast  | ✅  |

---

## Part III：传统 VPN 协议 (Legacy)

| #   | 章节                    | 主题              | 状态                                          |
| --- | ----------------------- | ----------------- | --------------------------------------------- | --- |
| 9   | [[ch9-pptp              | PPTP 点对点隧道]] | PPTP 历史、GRE 封装、MPPE 加密、已淘汰        | 🚧  |
| 10  | [[ch10-l2tp             | L2TP 第二层隧道]] | L2TP 控制消息、LAC/LNS、IPSec 配合            | 🚧  |
| 11  | [[ch11-openvpn          | OpenVPN 基础]]    | SSL VPN、TUN/TAP 模式、OpenSSL、easy-rsa      | 🚧  |
| 12  | [[ch12-openvpn-advanced | OpenVPN 高级]]    | tls-auth、compression、redirect-gateway       | 🚧  |
| 13  | [[ch13-ssl-vpn          | SSL VPN 技术]]    | SSL VPN 全路由/反向代理/端口转发、OpenConnect | 🚧  |

---

## Part IV：IPSec VPN

企业 VPN 事实标准。

| #   | 章节 | 主题                         | 状态             |
| --- | ---- | ---------------------------- | ---------------- | --------------------------------------- | --- |
|     | 14   | [[ch14-ipsec-overview        | IPSec 体系概述]] | AH/ESP、传输/隧道模式、SA、SADB         | ✅  |
|     | 15   | [[ch15-ipsec-ike             | IKE 密钥交换]]   | IKEv1 主模式/野蛮模式、IKEv2、DPD       | ✅  |
|     | 16   | [[ch16-ipsec-esp             | AH 与 ESP 协议]] | ESP 加密认证、AH 完整性、防重放         | ✅  |
|     | 17   | [[ch17-ipsec-policy          | IPSec 策略配置]] | ip xfrm、SPD、SAD、route-based VPN      | ✅  |
|     | 18   | [[ch18-ipsec-troubleshooting | IPSec 排错]]     | strongSwan/Charon、nat-traversal、debug | ✅  |

---

## Part V：WireGuard 现代 VPN

现代 VPN 的标杆，极简高效安全。

| #   | 章节                      | 主题                 | 状态                                   |
| --- | ------------------------- | -------------------- | -------------------------------------- | --- |
| 19  | [[ch19-wireguard-protocol | WireGuard 协议详解]] | 协议头、握手过程、Cookie、keepalive    | ✅  |
| 20  | [[ch20-wireguard-crypto   | WireGuard 密码学]]   | ChaCha20-Poly1305、Curve25519、BLAKE2s | ✅  |
| 21  | [[ch21-wireguard-kernel   | WireGuard 内核实现]] | device.c、peer.c、timers、allowedips   | ✅  |
| 22  | [[ch22-wireguard-config   | WireGuard 配置部署]] | wg-quick、wg show、nat 穿透、endpoint  | ✅  |
| 23  | [[ch23-wireguard-cloud    | WireGuard 云端方案]] | Tailscale、ZeroTier、NetBird、Cloud WG | ✅  |

---

## Part VI：翻墙技术 (GFW Bypass)

墙外互联网访问技术——原理、实现与生态。

| #   | 章节 | 主题                 | 状态               |
| --- | ---- | -------------------- | ------------------ | -------------------------------------------- | --- |
|     | 24   | [[ch24-gfw-principle | GFW 工作原理]]     | DPI、关键字过滤、IP 封锁、DNS 污染、连接重置 | ✅  |
|     | 25   | [[ch25-shadowsocks   | Shadowsocks 原理]] | SOCKS5 代理、AEAD 加密、插件系统、obfs混淆   | ✅  |
|     | 26   | [[ch26-shadowsocksr  | ShadowsocksR]]     | 协议混淆、TicketAuth、迷耦合、对抗 GFW       | ✅  |
|     | 27   | [[ch27-v2ray         | V2Ray 技术体系]]   | VMess/VLESS 协议、WebSocket/TLS/CDN 伪装     | ✅  |
|     | 28   | [[ch28-trojan        | Trojan 协议]]      | TLS 伪装、Trojan-Go、WebSocket               | ✅  |
|     | 29   | [[ch29-xray          | Xray 核心]]        | VLESS+XTLS、Trojan-Go、Reality 协议          | ✅  |
|     | 30   | [[ch30-clash         | Clash 生态]]       | Clash/Premium/Meta、规则分流、订阅制         | ✅  |
|     | 31   | [[ch31-tls-cdn       | TLS 伪装与 CDN]]   | TLS 前端、CDN 混淆、域前置 (Domain Fronting) | ✅  |
|     | 32   | [[ch32-tor-network   | Tor 网络]]         | 洋葱路由、Onion Proxy、TOR 浏览器            | ✅  |

---

## Part VII：代理协议 (Proxy Protocols)

各种代理协议的深度解析。

| #   | 章节               | 主题            | 状态                                  |
| --- | ------------------ | --------------- | ------------------------------------- | --- |
| 33  | [[ch33-socks-proxy | SOCKS 协议]]    | SOCKS4/5、握手过程、UDP ASSOCIATE     | ✅  |
| 34  | [[ch34-http-proxy  | HTTP Proxy]]    | CONNECT 方法、HTTPS 代理、TRACE       | ✅  |
| 35  | [[ch35-gost        | gost 代理工具]] | go-shadowsocks2、负载均衡、chain 代理 | ✅  |

---

## Part VIII：远程接入与零信任 (Zero Trust)

从传统 VPN 到零信任网络。

| #   | 章节                    | 主题               | 状态                                        |
| --- | ----------------------- | ------------------ | ------------------------------------------- | --- |
| 36  | [[ch36-sdp-architecture | SDP 软件定义边界]] | Controller/Gateway/Client 三角架构、Darknet | 🚧  |
| 37  | [[ch37-ztna             | 零信任网络 ZTNA]]  | BeyondCorp、ZTNA vs VPN、身份优先           | 🚧  |
| 38  | [[ch38-spiffe           | SPIFFE 身份体系]]  | SPIFFE ID、SVID、Workload API               | 🚧  |
| 39  | [[ch39-mtls             | mTLS 双向认证]]    | mTLS 流程、证书管理、Istio 实现             | 🚧  |
| 40  | [[ch40-wireguard-ztn    | WireGuard 零信任]] | WireGuard + nftables、基于身份的分段        | 🚧  |

---

## Part IX：云原生 VPN (Cloud Native)

Kubernetes 与云环境下的网络方案。

| #   | 章节                     | 主题                  | 状态                                             |
| --- | ------------------------ | --------------------- | ------------------------------------------------ | --- |
| 41  | [[ch41-k8s-vpn           | Kubernetes VPN 方案]] | CNI VPN 方案、Cluster Federation、Direct Peering | 🚧  |
| 42  | [[ch42-cilium-encryption | Cilium 流量加密]]     | CiliumClusterWideEncryption、WireGuard、CIP      | 🚧  |
| 43  | [[ch43-subnet-router     | Subnet Router 模式]]  | WireGuard 路由模式、boringtun                    | 🚧  |

---

## Part X：性能与安全 (Performance & Security)

VPN 与翻墙工具的性能优化与安全加固。

| #   | 章节                     | 主题             | 状态                                  |
| --- | ------------------------ | ---------------- | ------------------------------------- | --- |
| 44  | [[ch44-ipsec-offload     | IPSec 硬件卸载]] | Intel QAT、CAAM、cloud-hw-offload     | ✅  |
| 45  | [[ch45-wireguard-perf    | WireGuard 性能]] | 性能基准 (throughput/latency)、批处理 | ✅  |
| 46  | [[ch46-proxy-perf        | 翻墙协议性能]]   | Shadowsocks/V2Ray/Trojan 性能对比     | ✅  |
| 47  | [[ch47-vpn-hardening     | VPN 安全加固]]   | 证书固定、密钥轮换、漏铜扫描、防重放  | ✅  |
| 48  | [[ch48-detection-defense | GFW 检测与防御]] | 流量特征识别、被动/主动检测、对抗策略 | ✅  |
| 49  | [[ch49-vpn-benchmark     | VPN 基准测试]]   | 性能测试方法论、CPU 开销对比          | ✅  |
| 50  | [[ch50-future-vpn        | VPN 未来趋势]]   | 量子安全、后量子密码、协议趋势        | ✅  |

---

## 相关系列

- [[kernel-protocol-stack-deep-dive|Kernel Protocol Stack 系列]] — 内核网络协议栈
- [[dpdk-deep-dive|DPDK 深度探索系列]] — 用户态数据包处理
- [[ebpf-deep-dive|eBPF 深度探索系列]] — 内核可编程观测
