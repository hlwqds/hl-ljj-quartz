---
title: "VPN 技术深度探索 (十四)：IPSec 体系概述"
date: 2026-04-13
tags: [vpn, series, networking, security, ipsec, ah, esp, sa, sadb, tunnel-mode, transport-mode]
description: "IPSec 协议族全景解析——AH/ESP 协议头格式与作用、传输模式与隧道模式对比、安全关联(SA)与安全策略数据库(SADB/SPD)详解、Linux 内核 xfrm 子系统架构"
---

> [!info] VPN 技术深度探索系列
> 0. [[2026-04-13-vpn-deep-dive-series-index|全栈学习路径总览]]
> 1. [[2026-04-13-vpn-deep-dive-ch1-vpn-fundamentals|VPN 基础概念]]
> 2. [[2026-04-13-vpn-deep-dive-ch2-tunnel-basics|隧道技术基础]]
> 3. [[2026-04-13-vpn-deep-dive-ch3-crypto-fundamentals|密码学基础]]
> 4. [[2026-04-13-vpn-deep-dive-ch4-authentication|身份认证基础]]
> 13. [[2026-04-13-vpn-deep-dive-ch13-ssl-vpn|SSL VPN 技术]]
> **14. IPSec 体系概述（本章）**
> 15. [[2026-04-13-vpn-deep-dive-ch15-ipsec-ike|IKE 密钥交换]]
> 16. [[2026-04-13-vpn-deep-dive-ch16-ipsec-esp|AH 与 ESP 协议]]
> 17. [[2026-04-13-vpn-deep-dive-ch17-ipsec-policy|IPSec 策略配置]]
> 18. [[2026-04-13-vpn-deep-dive-ch18-ipsec-troubleshooting|IPSec 排错]]

---

## 1. 什么是 IPSec

**IPSec（Internet Protocol Security）** 是 IETF 制定的一套在 IP 层提供安全通信的协议族，主要由以下 RFC 规范定义：

| RFC | 内容 |
|-----|------|
| RFC 4301 | IPSec 安全架构 |
| RFC 4302 | AH（Authentication Header）协议 |
| RFC 4303 | ESP（Encapsulating Security Payload）协议 |
| RFC 7296 | IKEv2 密钥交换协议 |
| RFC 4306 | IKEv2（旧版，已被 7296 废止） |

IPSec 的三大目标：

```
机密性（Confidentiality）   —— ESP 加密报文内容
完整性（Integrity）         —— AH/ESP 校验防篡改
认证性（Authentication）    —— 验证通信双方身份
```

IPSec 不是单一协议，而是一个**协议套件**（Protocol Suite）：

```
┌─────────────────────────────────────────────────────┐
│                   IPSec Suite                        │
│  ┌───────────┐  ┌───────────┐  ┌──────────────────┐ │
│  │    AH     │  │    ESP    │  │   IKE / IKEv2    │ │
│  │ (Proto 51)│  │ (Proto 50)│  │  (UDP 500/4500)  │ │
│  └───────────┘  └───────────┘  └──────────────────┘ │
│  ┌─────────────────────────────────────────────────┐ │
│  │          SADB / SPD  (Security Database)        │ │
│  └─────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────┘
```

---

## 2. AH 与 ESP 协议头

### 2.1 AH（Authentication Header，IP 协议号 51）

AH 提供**数据完整性 + 源认证**，但**不加密**载荷内容。

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
| Next Header   |  Payload Len  |          RESERVED             |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                 Security Parameters Index (SPI)               |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                    Sequence Number Field                      |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                Authentication Data (ICV)                      |
|              变长，通常 96~256 位（HMAC-SHA256 = 256 bit）      |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

字段说明：

| 字段 | 说明 |
|------|------|
| Next Header | 被保护的上层协议（如 TCP=6、UDP=17、ESP=50） |
| Payload Len | AH 头长度（以 32 位为单位，减 2） |
| SPI | 安全参数索引，标识 SA |
| Sequence Number | 防重放序列号，从 1 递增 |
| ICV | 完整性校验值（Integrity Check Value），覆盖 IP 头不变字段 + 上层载荷 |

> [!warning] AH 与 NAT 不兼容
> AH 的 ICV 覆盖 IP 头中的源/目的地址字段，而 NAT 会修改这些字段，导致 ICV 验证失败。
> 因此 **AH 无法穿透 NAT**，实际部署中很少单独使用 AH。

### 2.2 ESP（Encapsulating Security Payload，IP 协议号 50）

ESP 提供**加密 + 数据完整性 + 源认证**，是 IPSec 部署的主流选择。

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|               Security Parameters Index (SPI)                |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                     Sequence Number                           |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|        ← 以上为 ESP Header，明文传输 →                         |
+===============================================================+
|                  Payload Data（加密部分）                      |
|                    + Padding + Pad Length                     |
|                    + Next Header                              |
+===============================================================+
|           ICV（完整性校验，仅覆盖 ESP Header + Payload）         |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

ESP 数据包结构（隧道模式）：

```
+----------+--------+--------+----------------------+--------+-----+
| 外层 IP头 | ESP头  | 内层IP头| TCP/UDP + 应用数据    | ESP尾  | ICV |
+----------+--------+--------+----------------------+--------+-----+
                   ←————————————— 加密范围 ———————————————→
           ←——————————————————— 认证范围 ————————————————————→
```

---

## 3. 传输模式 vs 隧道模式

IPSec 有两种封装模式，适用于不同的场景。

### 3.1 传输模式（Transport Mode）

在传输模式下，**只对 IP 载荷（TCP/UDP 等）进行保护**，IP 头保持原样（AH 模式）或被引用（ESP 模式）。

```
原始 IP 包：
+----------+------------------+
| IP 头    | TCP/UDP Payload  |
+----------+------------------+

AH 传输模式：
+----------+------+------------------+-----+
| IP 头    |  AH  | TCP/UDP Payload  | ICV |
+----------+------+------------------+-----+

ESP 传输模式：
+----------+------+------------------+------+-----+
| IP 头    | ESP头 | TCP/UDP Payload  | ESP尾 | ICV |
+----------+------+------------------+------+-----+
                  ←—————加密——————————→
           ←————————————认证范围————————————→
```

**适用场景**：端对端主机通信（Host-to-Host），如两台服务器之间的通信保护。

### 3.2 隧道模式（Tunnel Mode）

在隧道模式下，**整个原始 IP 包（包含 IP 头）被封装保护**，外层加新的 IP 头用于路由。

```
原始 IP 包：
+----------+------------------+
| IP 头    | TCP/UDP Payload  |
+----------+------------------+

ESP 隧道模式：
+----------+------+----------+------------------+------+-----+
| 外层IP头 | ESP头 | 原始IP头  | TCP/UDP Payload  | ESP尾 | ICV |
+----------+------+----------+------------------+------+-----+
                  ←——————————————加密——————————————→
           ←—————————————————认证范围——————————————————→
```

**适用场景**：
- 站点到站点 VPN（Site-to-Site）：两端 VPN 网关之间
- 远程接入 VPN（Remote Access）：客户端与 VPN 网关

### 3.3 模式对比

| 特性 | 传输模式 | 隧道模式 |
|------|---------|---------|
| IP 头保护 | 不保护（AH 认证但不封装） | 整个原始 IP 头被加密封装 |
| 报文开销 | 小（无外层 IP 头） | 大（新增外层 IP 头） |
| 源/目的地址 | 与通信端点相同 | 外层 IP 为网关地址 |
| 典型场景 | 主机到主机 | 网关到网关、客户端到网关 |
| NAT 穿透 | 困难（尤其 AH） | ESP + NAT-T 可以穿透 |

---

## 4. 安全关联（Security Association，SA）

### 4.1 SA 的概念

**SA（Security Association）** 是 IPSec 通信双方之间的**单向安全协议**，定义了：
- 使用哪种协议（AH 或 ESP）
- 使用哪种加密/认证算法
- 使用哪个密钥
- 密钥的有效期

> [!important] SA 是单向的
> 一次双向 IPSec 通信需要**两个 SA**（各自方向一个）。
> 如果同时使用 AH 和 ESP，则需要**四个 SA**。

### 4.2 SA 的标识（三元组）

每个 SA 由三元组唯一标识：

```
< SPI, 目的 IP 地址, 安全协议(AH/ESP) >
```

- **SPI（Security Parameters Index）**：32 位整数，与目的地址 + 协议联合唯一标识一个 SA
- **目的 IP 地址**：SA 终点（接收方 IP）
- **协议**：AH（51）或 ESP（50）

### 4.3 SA 的属性

```
SA 属性：
  - SPI: 0x12345678
  - 协议: ESP
  - 加密算法: AES-256-GCM
  - 认证算法: HMAC-SHA2-256-128（GCM 模式自带认证，此字段可省）
  - 加密密钥: <256 bit>
  - 认证密钥: <256 bit>
  - 序列号计数器: 当前值（防重放用）
  - 防重放窗口: 64 bit 滑动窗口
  - 生命期: 时间(3600s) 或 字节数(10GB)
  - 模式: 隧道 / 传输
  - 路径 MTU
```

---

## 5. 安全数据库（SADB 与 SPD）

IPSec 在内核中维护两个关键数据库。

### 5.1 SADB（Security Association Database，安全关联数据库）

SADB 存储所有活跃的 SA 条目，相当于 IPSec "加密会话表"。

```
SADB 示例（ip xfrm state 输出）：
src 192.168.1.1 dst 192.168.2.1
    proto esp spi 0xc4a2f3b1 reqid 1 mode tunnel
    replay-window 32 flag af-unspec
    auth-trunc hmac(sha256) 0xabcdef...  128
    enc cbc(aes) 0x123456...
    encap type espinudp sport 4500 dport 4500
    lifetime config:
      limit: soft (bytes 0, packets 0) hard (bytes 0, packets 0)
      limit: soft (add 1080s, use 1080s) hard (add 1200s, use 1200s)
    lifetime current:
      bytes 0, packets 0
      add 2026-04-13 10:00:00 use -
    stats:
      replay-window 0 replay 0 failed 0
```

### 5.2 SPD（Security Policy Database，安全策略数据库）

SPD 定义了**对哪些流量应用 IPSec**，以及**如何处理**（三种动作）：

```
DISCARD   —— 丢弃匹配的流量
BYPASS    —— 不做 IPSec 处理，直接转发
PROTECT   —— 应用 IPSec 处理（指向某个 SA）
```

SPD 条目匹配依据（选择符 Selector）：
- 源/目的 IP 地址（可含前缀）
- 协议（TCP/UDP/ICMP 等）
- 源/目的端口
- 方向（入站/出站）

```
SPD 示例（ip xfrm policy 输出）：
src 10.0.1.0/24 dst 10.0.2.0/24
    dir out priority 2000
    tmpl src 192.168.1.1 dst 192.168.2.1
        proto esp reqid 1 mode tunnel

src 10.0.2.0/24 dst 10.0.1.0/24
    dir in priority 2000
    tmpl src 192.168.2.1 dst 192.168.1.1
        proto esp reqid 1 mode tunnel
```

### 5.3 出站处理流程

```
应用发送报文
     ↓
查询 SPD（匹配源/目的 IP + 协议 + 端口）
     ↓
    BYPASS ──────────────────────────→ 直接发送
     ↓
    DISCARD ─────────────────────────→ 丢弃
     ↓
    PROTECT
     ↓
查询 SADB（是否有匹配的活跃 SA？）
     ├── 有 SA ──→ 用 SA 加密/认证报文 → 发送
     └── 无 SA ──→ 触发 IKE 协商（IKE Daemon）
                         ↓
                   协商完成，建立 SA
                         ↓
                   加密/认证报文 → 发送
```

### 5.4 入站处理流程

```
收到 IPSec 报文（AH/ESP）
     ↓
读取 SPI + 目的 IP + 协议 → 查询 SADB
     ↓
    找不到 SA ──→ 丢弃（或发 ICMP 不可达）
     ↓
    找到 SA ──→ 解密/验证 ICV
     ↓
    验证失败 ──→ 丢弃（记录告警）
     ↓
    验证通过 ──→ 防重放窗口检查
     ↓
    重放 ──→ 丢弃
     ↓
    正常 ──→ 解封装得到内层报文
     ↓
查询 SPD 入站策略（验证收到的报文符合策略）
     ↓
    通过 ──→ 交给上层协议栈
```

---

## 6. Linux 内核 xfrm 子系统

Linux 内核通过 **xfrm（eXtensible Framework）** 子系统实现 IPSec。

### 6.1 xfrm 架构

```
用户空间
  ├── strongSwan / Libreswan / racoon（IKE 守护进程）
  ├── ip xfrm（iproute2 工具）
  └── setkey（ipsec-tools）
         ↓ Netlink（AF_KEY / XFRM）
内核空间
  ├── xfrm_core（核心框架）
  ├── xfrm_state（SA 管理）
  ├── xfrm_policy（SPD 管理）
  ├── xfrm_input（入站解封装）
  ├── xfrm_output（出站封装）
  └── 转换模块
        ├── esp4 / esp6
        ├── ah4 / ah6
        └── ipcomp4（IP 压缩）
```

### 6.2 常用 ip xfrm 命令

查看 SADB：
```bash
ip xfrm state
ip xfrm state list
```

查看 SPD：
```bash
ip xfrm policy
ip xfrm policy list
```

查看 xfrm 统计：
```bash
ip xfrm monitor    # 实时监控 SA/policy 变化
cat /proc/net/xfrm_stat
```

手工添加 SA（调试用）：
```bash
# 出站 SA
ip xfrm state add \
  src 192.168.1.1 dst 192.168.2.1 \
  proto esp spi 0x12345678 \
  mode tunnel \
  auth hmac\(sha256\) 0x$(openssl rand -hex 32) \
  enc cbc\(aes\) 0x$(openssl rand -hex 32)

# 入站 SA（方向相反）
ip xfrm state add \
  src 192.168.2.1 dst 192.168.1.1 \
  proto esp spi 0x87654321 \
  mode tunnel \
  auth hmac\(sha256\) 0x$(openssl rand -hex 32) \
  enc cbc\(aes\) 0x$(openssl rand -hex 32)
```

手工添加 SPD 策略：
```bash
# 出站策略
ip xfrm policy add \
  src 10.0.1.0/24 dst 10.0.2.0/24 \
  dir out \
  tmpl src 192.168.1.1 dst 192.168.2.1 \
  proto esp mode tunnel

# 入站策略
ip xfrm policy add \
  src 10.0.2.0/24 dst 10.0.1.0/24 \
  dir in \
  tmpl src 192.168.2.1 dst 192.168.1.1 \
  proto esp mode tunnel

# forward 策略（网关场景需要）
ip xfrm policy add \
  src 10.0.2.0/24 dst 10.0.1.0/24 \
  dir fwd \
  tmpl src 192.168.2.1 dst 192.168.1.1 \
  proto esp mode tunnel
```

---

## 7. SA 生命周期管理

### 7.1 软/硬生命期（Soft/Hard Lifetime）

IPSec SA 有两个生命期阈值：

```
软生命期（Soft Lifetime）：
  触发 IKE 重新协商新 SA（REKEY），
  旧 SA 继续使用直到新 SA 就绪。

硬生命期（Hard Lifetime）：
  SA 强制删除，超过此限制的报文被丢弃。
```

典型配置（strongSwan）：
```
ikelifetime = 1h      # IKE SA 生命期
lifetime = 30m        # IPSec SA 生命期
margintime = 5m       # 提前 5 分钟触发重协商
rekeyfuzz = 100%      # 随机扰动（防止多节点同时重协商）
```

### 7.2 PFS（Perfect Forward Secrecy）

PFS 要求每次重新协商 IPSec SA 时都进行**新的 DH 密钥交换**，而不复用 IKE 阶段的密钥材料。

```
无 PFS：IPSec SA 密钥 = f(IKE 主密钥)
         若 IKE 主密钥泄露，所有 IPSec SA 密钥均可推导

有 PFS：IPSec SA 密钥 = f(新 DH 交换)
         每次重协商产生全新密钥，互相独立
```

strongSwan 配置启用 PFS：
```
esp_proposals = aes256gcm128-modp2048
#                               ↑ DH group → 启用 PFS
```

---

## 8. IPSec 算法套件

现代推荐算法组合（2024+）：

| 功能 | 推荐算法 | 避免使用 |
|------|---------|---------|
| 加密 | AES-256-GCM（AEAD） | DES、3DES、RC4 |
| 完整性 | SHA-256/384/512 | MD5、SHA-1 |
| DH 密钥交换 | ECDH P-256/P-384、modp3072+ | DH group 1/2/5 |
| PRF | PRF-HMAC-SHA256 | PRF-HMAC-MD5 |

> [!tip] 优先使用 AEAD 算法
> **AES-GCM（Galois/Counter Mode）** 是 AEAD（同时认证加密）算法，一次操作完成加密和认证，比 AES-CBC + HMAC 更高效，且无 padding oracle 攻击风险。
> Linux 内核和现代硬件（AES-NI）对 AES-GCM 有良好支持。

---

## 9. 本章小结

```
IPSec 核心概念速查：

协议：
  AH  (51) = 认证（不加密），与 NAT 不兼容
  ESP (50) = 加密 + 认证（推荐），支持 NAT-T

模式：
  传输模式 = 保护 IP 载荷，适合 Host-to-Host
  隧道模式 = 封装整个 IP 包，适合 GW-to-GW

数据库：
  SADB = 存储 SA（密钥、算法、序列号）
  SPD  = 存储策略（匹配流量、指定动作）

SA 标识：< SPI, 目的 IP, 协议 > 三元组

Linux 工具：
  ip xfrm state   = 查看/管理 SADB
  ip xfrm policy  = 查看/管理 SPD
  ip xfrm monitor = 实时监控
```

下一章将深入讲解 IKE（Internet Key Exchange）协议——IPSec 的自动密钥协商机制。

---

## 参考资料

- RFC 4301: Security Architecture for the Internet Protocol
- RFC 4302: IP Authentication Header
- RFC 4303: IP Encapsulating Security Payload (ESP)
- RFC 4307: Cryptographic Algorithms for Use in the Internet Key Exchange Version 2
- Linux Kernel Documentation: Documentation/networking/ipsec.rst
- strongSwan Documentation: https://docs.strongswan.org/
