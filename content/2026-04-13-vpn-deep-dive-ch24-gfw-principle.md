---
title: "VPN 技术深度探索 (二十四)：GFW 工作原理"
date: 2026-04-13
tags: [vpn, series, gfw, censorship, dpi, firewall, china]
description: "中国防火长城（GFW）深度解析——DPI 深度包检测、关键字过滤、IP 封锁、DNS 污染、连接重置、SNI 过滤、TLS 指纹识别，了解审查系统的技术实现"
---

> [!info] VPN 技术深度探索系列
> 0. [[2026-04-13-vpn-deep-dive-series-index|全栈学习路径总览]]
> 1. [[2026-04-13-vpn-deep-dive-ch23-wireguard-cloud|WireGuard 云端方案]]
> 2. **第二十四章：GFW 工作原理**
> 3. [[2026-04-13-vpn-deep-dive-ch25-shadowsocks|第二十五章：Shadowsocks 原理]]
> 4. [[2026-04-13-vpn-deep-dive-ch26-shadowsocksr|第二十六章：ShadowsocksR]]

---

## 1. 概述：什么是 GFW？

**GFW（Great Firewall of China，中国国家防火墙）** 是中国人民解放军技术部队于 1990 年代末开始建设、2000 年代初正式投入使用的**国家级互联网审查系统**。其官方名称为"金盾工程"，但民间和学术文献中普遍称之为 Great Firewall。

GFW 的核心目标并非完全阻断互联网访问，而是**对特定内容的跨境流量进行过滤和干扰**。这决定了其技术架构：不是简单的"全阻断"，而是精准的"选择性干扰"。

```
GFW 审查层级架构：

┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│  第7层：应用层审查                                                │
│  ├─ HTTP/HTTPS 关键字过滤                                        │
│  ├─ DNS 污染与欺骗                                               │
│  └─ SNI（Server Name Indication）过滤                            │
│                                                                 │
│  第4层：传输层审查                                                │
│  ├─ TCP 连接重置（TCP RST）                                      │
│  ├─ TLS 指纹分析与握手干扰                                        │
│  └─ 协议特征识别（DPI）                                           │
│                                                                 │
│  第3层：网络层审查                                                │
│  ├─ IP 地址黑名单封锁                                             │
│  ├─ BGP 黑洞路由                                                 │
│  └─ 自治系统级封锁                                               │
│                                                                 │
│  支撑系统：                                                       │
│  ├─ 关键字词库（数十万条目，动态更新）                              │
│  ├─ TLS 证书指纹库                                               │
│  ├─ IP/域名 黑名单数据库                                          │
│  └─ 机器学习异常检测                                             │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 2. DPI 深度包检测

### 2.1 DPI 技术原理

**DPI（Deep Packet Inspection，深度包检测）** 是 GFW 最核心技术之一。与传统防火墙只检查 IP 头部和端口号不同，DPI 能够解析到数据包的应用层内容。

```
传统包过滤 vs DPI：

传统防火墙（Layer 3/4）：
┌─────────────────────────────────────────────────────────────────┐
│ IP Header        │  Transport Header  │  Payload              │
│ [Src IP]         │  [Src Port]        │  [应用数据]            │
│ [Dst IP]         │  [Dst Port]        │  (不解析)              │
└─────────────────────────────────────────────────────────────────┘

DPI 系统（Layer 7）：
┌─────────────────────────────────────────────────────────────────┐
│ IP Header        │  Transport Header  │  Application Layer    │
│ [Src IP]         │  [Src Port]        │  [HTTP/DNS/TLS...]    │
│ [Dst IP]         │  [Dst Port]        │  [完整内容解析]         │
└─────────────────────────────────────────────────────────────────┘
        ↓                    ↓                    ↓
   路由决策              状态追踪            内容过滤
```

### 2.2 HTTP 关键字过滤

对于未加密的 HTTP 流量，GFW 可以直接检测 HTTP Header 和 Body 中的关键字。当检测到敏感词时，GFW 会**注入伪造的 TCP RST 包**来切断连接。

```
HTTP 请求过滤流程：

正常请求：
Client ────────── SYN ──────────▶ Server
Client ◀──────── SYN+ACK ──────── Server
Client ────────── ACK ──────────▶ Server
Client ──── HTTP GET /fb ────────▶ Server  (包含 "facebook" 关键字)
                                  ↓
                              GFW DPI 检测到
                                  ↓
Client ◀─── TCP RST (from Server) ── Server  (GFW 注入的伪造包)
Client ──── HTTP GET /fb ────────▶ Server  (连接已断开)
                                  ↓
                              超时/连接失败

关键特征：
├─ GFW 注入了伪造的 TCP RST 包（源 IP 伪装成 Server）
├─ RST 包紧跟在敏感请求之后（毫秒级延迟）
└─ 正常 Server 也会收到请求（因为连接已被切断）
```

### 2.3 TCP 连接重置（TCP RST Injection）

TCP RST 是 GFW 最常用的干扰手段。当 GFW 检测到敏感流量时，会向通信双方**同时注入 TCP RST 包**，伪装成对方发送的断开连接请求。

```
TCP RST 攻击原理：

正常 TCP 连接：
Client ──────────────────────────────▶ Server
         [Src Port: 54321, Seq: 1000]
         
Client ◀───────────────────────────────── Server
         [Dst Port: 54321, Seq: 2000, ACK: 1001]

GFW 注入 TCP RST 后：

Client ◀── TCP RST ────────────────────── Server
         [伪装成 Server 发送]
         [Src: Server IP, Dst: Client IP]
         [Src Port: 80, Dst Port: 54321]
         [Seq: 2000 + 1, RST Flag=1]

Server ◀── TCP RST ────────────────────── Client
         [伪装成 Client 发送]
         [Src: Client IP, Dst: Server IP]
         [Src Port: 54321, Dst Port: 80]
         [Seq: 1001, RST Flag=1]

结果：双方都认为对方要求断开连接，连接被强制终止
```

**TCP RST 包特征：**
- TTL 通常设置为 64 或 128（与真实 Server 的 TTL 不同）
- IP ID 可能为 0（GFW 生成的包特征）
- Window Size 通常为 0

---

## 3. DNS 污染与欺骗

### 3.1 DNS 污染原理

GFW 在 DNS 层面实施**污染（DNS Poisoning/DNS Spoofing）**，当用户查询被封锁域名的 IP 时，返回**错误的 IP 地址**或**不返回任何结果**。

```
DNS 污染原理：

正常 DNS 查询（example.com 未被封锁）：
Client ──── DNS Query: example.com ──────▶ DNS Resolver
Client ◀─── DNS Response: 93.184.216.34 ── DNS Resolver

被封锁域名的 DNS 查询（facebook.com）：
Client ──── DNS Query: facebook.com ─────▶ DNS Resolver
                                        │
                                        ↓
                                   GFW DPI 检测
                                        │
Client ◀─── DNS Response: 8.7.8.8 ────── DNS Resolver
         (GFW 伪造的响应，返回错误 IP)
         
真实响应被 GFW 丢弃或延迟到无法使用
```

### 3.2 DNS 污染技术细节

DNS 污染有多种实现方式：

```
DNS 污染实现方式：

方式1：实时伪造响应
├─ GFW 检测到敏感域名的 DNS 查询
├─ 立即向 Client 发送伪造的 DNS 响应
└─ 真实响应被丢弃（来不及到达 Client）

方式2：DNS 缓存污染
├─ 在权威 DNS 服务器响应前注入
├─ 污染递归 DNS 服务器的缓存
└─ 后续查询直接返回错误结果

方式3：DNS 抢答
├─ GFW 比真实 DNS 响应更快到达
├─ 使用更小的 UDP 端口（53）
└─ Client 接受首先到达的响应
```

### 3.3 DNS 污染的识别

```
DNS 污染识别方法：

1. 解析结果比对：
   ├─ 查询被封锁域名
   ├─ 对比多个 DNS 服务器（国内 vs 国外）
   └─ 结果不同说明可能被污染

2. TTL 检查：
   ├─ 正常 DNS 响应 TTL 通常 300-3600
   ├─ GFW 伪造响应 TTL 通常 300 或 600
   └─ 异常的短 TTL 可能指示污染

3. 响应时间分析：
   ├─ 正常 DNS 响应：20-100ms（递归查询）
   ├─ GFW 伪造响应：< 5ms（GFW 就在旁边）
   └─ 极快响应可能是伪造的
```

---

## 4. IP 封锁与 BGP 黑洞

### 4.1 IP 黑名单封锁

最简单的封锁方式是将目标 IP 地址加入黑名单，在骨干网路由器上配置 ACL 丢弃发往/来自这些 IP 的数据包。

```
IP 封锁架构：

┌─────────────────────────────────────────────────────────────────┐
│                      中国骨干网（ChinaNet/CERNET）               │
│                                                                 │
│    ┌──────────┐    ┌──────────┐    ┌──────────┐                │
│    │ Router 1 │    │ Router 2 │    │ Router 3 │  ...           │
│    │ ACL deny │    │ ACL deny │    │ ACL deny │                │
│    │ 8.8.8.8  │    │ 1.1.1.1  │    │ X.X.X.X  │                │
│    └──────────┘    └──────────┘    └──────────┘                │
│          ↓              ↓              ↓                      │
│    国际出口      国际出口      国际出口                         │
└─────────────────────────────────────────────────────────────────┘

封锁粒度：
├─ /32（单 IP）：精确封锁特定服务器
├─ /24（256 IP）：封锁整个 IP 段
└─ AS 级别：封锁整个自治系统
```

### 4.2 BGP 黑洞路由

对于大规模封锁，GFW 采用 **BGP 黑洞（Blackhole Routing）** 技术。通过广播特定路由的 blackhole 路由，将目标 IP 段的流量引导到黑洞路由器并丢弃。

```
BGP 黑洞原理：

正常 BGP 路由：
┌────────┐         ┌────────┐         ┌────────┐
│ AS 64496│────────▶│ AS X   │────────▶│ AS 15169│
│(国内)  │  BGP   │(运营商)│  BGP  │(Google) │
└────────┘         └────────┘         └────────┘

被封锁后（黑洞路由）：
┌────────┐         ┌────────┐         ┌────────┐
│ AS 64496│───────▶│ AS X   │──┐   ┌─▶│ AS 15169│
│(国内)  │  BGP   │(运营商)│  │   │  └────────┘
└────────┘         └────────┘  │   │
                               │   │
                          ┌────┴──┴───┐
                          │ 黑洞路由   │
                          │ (丢弃包)  │
                          └───────────┘

路由配置示例：
router bgp 64496
  aggregate-address 93.184.216.0/24 suppress-map blackhole
  !
  route-map blackhole permit 10
    match ip address blackhole-list
  !
  ip route 93.184.216.0/24 null0 blackhole
```

### 4.3 自治系统级封锁

更高级的封锁是在 BGP 层面直接断开与特定 AS 的连接。这会导致整个 AS 的所有 IP 都无法访问。

```
AS 级封锁效果：

目标：封锁 Cloudflare (AS 13335)

封锁前：
Client ──▶ 国内路由器 ──▶ 国际出口 ──▶ Cloudflare (AS 13335)

封锁后（对等会话断开）：
Client ──▶ 国内路由器 ──✗ 国际出口
                     │
                     └─▶ BGP 会话已断开
                     └─▶ 所有流量被丢弃

影响范围：
├─ Cloudflare 所有 IP（包括 CDN 节点）
├─ 使用 Cloudflare 的所有网站
└─ 误伤大量无辜网站
```

---

## 5. SNI 与 TLS 指纹检测

### 5.1 SNI（Server Name Indication）

SNI 是 TLS 握手中的扩展字段，用于指示客户端要访问的域名。在 TLS 握手的第一个 ClientHello 包中，以明文形式传输。

```
SNI 在 TLS 握手中的位置：

TCP 握手完成后：

Client ──── TLS ClientHello ────────────────────────────────────▶ Server
           │                                                       
           │ Extension: server_name                               
           │   server_name: "facebook.com"  (明文！)              
           │                                                       
Server ◀─── TLS ServerHello + Certificate ─────────────────────── Client
           │                                                       
           │ Certificate 中包含域名                               
           │                                                       

GFW 可以解析 ClientHello 中的 SNI 字段：
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│  ClientHello 抓包示例（16进制）：                                │
│                                                                 │
│  01 00 00 dc 03 03  ... 0a 00 08 00 06 00 17 00 18 00 19     │
│  00 00 05 00 05 01 00 00 00 00 00 0d 00 1a 00 18 00 00 15     │
│  61 6c 6c 6f 77 2e 66 61 63 65 62 6f 6f 6b 2e 63 6f 6d 00     │
│  │                                                        │
│  │  SNI Extension: "allow.facebook.com"                    │
│  │                                                        │
│  └───────────────────────────────────────────────────────▶    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 5.2 TLS 指纹识别

GFW 不仅检测 SNI，还会分析 TLS ClientHello 的**指纹特征**，包括：
- 支持的密码套件列表及其顺序
- 支持的 TLS 扩展及其顺序
- elliptic_curves 列表
- ec_point_formats 列表
- GREASE 值
- TLS Version

```
常见 TLS 客户端指纹：

Chrome 浏览器：
├─ JA3 Hash: a8ff3a8bf2eb2a3bc9a8b4eb8b6f8c66
├─ 特征：支持 100+ 密码套件，包含 GREASE
└─ SNI：正常域名

Shadowsocks (go-shadowsocks2)：
├─ JA3 Hash: 不同版本不同
├─ 特征：固定密码套件顺序
└─ SNI：墙外服务器域名（敏感！）

curl：
├─ JA3 Hash: 95a9e0cc2a0d9e1b1c1e0e1f2d3c4b5a
├─ 特征：简洁的密码套件列表
└─ SNI：正常

V2Ray：
├─ JA3 Hash: 可自定义
├─ 特征：模拟浏览器行为
└─ SNI：可使用域前置
```

### 5.3 JA3/JA3S 指纹

**JA3（JA3c/JA3s）** 是用于生成 TLS 指纹的算法：

```
JA3c（客户端指纹）计算：

提取 ClientHello 中的字段：
├─ TLS Version
├─ Cipher Suites (按出现顺序)
├─ Extensions (按类型顺序)
└─ Elliptic Curves

计算 MD5 哈希：
JA3c = MD5(TLSVersion + CipherSuites + Extensions + EllipticCurves)

示例：
TLSVersion:     0303 (TLS 1.2)
CipherSuites:  13019302c02bc02cc0309c02fc030cca8c02cc030cca8c0acc02cc09c02c
               1302c0301301130213021300c02cc0aac0acc023c02fc02bc024c026c028
               c0a8c09ec07c0acc0adc023c027c025c026c0eec0d4c05ac0a4c05ec0a2
               c0a6c0a0c094c090c0acc08ac086c0aac08e9cc084c098c096c0a3c09fc085
               c08dc089c0a1c09dc08bc08f9ec07ec076c072c07ac07cc0a8c07dc0a5
Extensions:    0005000f000a33776861332d38302e342e312d6e6f6e2d70726f78792d746c
               73000d000800060317030100ff0100010000000000000000000000000000
               000000000000000000000000000000000000000000000000000000000000
               000000000000000000000000000000000000000000000000000000000000
               000000000000000000000000000000000000000000000000000000000000
               000000000000000000000000000000000000000000000000000000000000
               00000000

JA3c = MD5("303:100...000:0005...") = "a8ff3a8bf2eb2a3bc9a8b4eb8b6f8c66"
```

---

## 6. GFW 的检测与对抗策略

### 6.1 流量特征识别

GFW 使用**被动 DPI** 技术识别各种翻墙协议的流量特征：

```
常见翻墙协议的特征：

Shadowsocks（未混淆）：
├─ 端口：常用 8388
├─ 特征：固定 4 字节长度头 + 加密数据
└─ 识别方式：数据包大小分布异常

Shadowsocks（obfs 混淆）：
├─ HTTP 混淆：伪装成 HTTP 请求
└─ TLS 混淆：伪装成 TLS ClientHello

V2Ray（VMess）：
├─ 端口：常用 10086
├─ 特征：自定义加密协议，动态端口
└─ 识别方式：流量行为分析

WireGuard：
├─ 端口：常用 51820
├─ 特征：固定格式 UDP 包，Cookie 机制
└─ 识别方式：数据包大小 + 握手模式
```

### 6.2 主动探测与封锁

GFW 还会使用**主动探测（Active Probing）** 技术：向疑似翻墙服务器的 IP 发送探测包，分析响应特征。

```
主动探测流程：

┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│  1. 可疑 IP 识别                                                 │
│     ├─ 被动 DPI 发现异常流量                                     │
│     ├─ 举报系统上报                                              │
│     └─ 扫描系统发现                                              │
│                                                                 │
│  2. 主动探测发送                                                 │
│     ├─ 发送伪造的客户端请求                                       │
│     ├─ 发送特制的协议探测包                                       │
│     └─ 测试响应是否符合预期协议                                   │
│                                                                 │
│  3. 响应分析                                                     │
│     ├─ 协议指纹匹配                                              │
│     ├─ 行为特征分析                                              │
│     └─ 决定是否加入封锁名单                                       │
│                                                                 │
│  4. 封锁执行                                                     │
│     ├─ IP 黑名单                                                 │
│     ├─ 域名黑名单                                                │
│     └─ 证书/指纹黑名单                                            │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 6.3 对抗 GFW 的技术演进

翻墙技术与 GFW 的对抗经历了多个阶段：

```
翻墙技术演进史：

第一代（2000年代初）：
├─ HTTP Proxy（直接翻墙）
├─ Telnet/SSH 隧道
└─ 特点：明文传输，容易检测

第二代（2005-2010）：
├─ PPTP/L2TP VPN
├─ OpenVPN
└─ 特点：被 GFW 识别并封锁

第三代（2010-2015）：
├─ Shadowsocks（影梭）
├─ 特点：轻量级 SOCKS5 代理，AEAD 加密
└─ 后续：obfs 混淆插件

第四代（2015-2020）：
├─ ShadowsocksR（协议混淆）
├─ V2Ray（VMess/VLESS）
└─ 特点：TLS 伪装、CDN 混淆

第五代（2020至今）：
├─ Trojan（TLS 伪装）
├─ Xray（VLESS+XTLS/Reality）
├─ Tuic / Hysteria
└─ 特点：深度 TLS 伪装、CDN 规避

技术趋势：
├─ 协议混淆：模拟正常 TLS 流量
├─ CDN 规避：域前置、IP 隐蔽
├─ 协议升级：TLS 1.3、HTTP/3 (QUIC)
└─ 去特征化：去除协议指纹
```

---

## 7. GFW 的局限性与漏洞

### 7.1 审查盲区

GFW 虽然强大，但存在一些技术和架构上的限制：

```
GFW 局限性：

1. 资源限制：
   ├─ 无法对所有跨境流量进行深度检测
   ├─ 只能抽样检测或按需检测
   └─ 高速链路可能绕过细粒度检测

2. 加密流量检测困难：
   ├─ TLS 1.3 加密了 SNI 和扩展
   ├─ ECH（Encrypted Client Hello）进一步加密
   └─ 只能通过 DNS 或 IP 层面间接检测

3. CDN 保护：
   ├─ 正常 CDN 流量难以区分
   ├─ 封锁 CDN IP 会误伤大量正常网站
   └─ 域前置技术利用这一特点

4. 实时性限制：
   ├─ 新协议出现到被识别有时间差
   ├─ 协议快速迭代使检测系统滞后
   └─ 0day 协议短期内无法检测
```

### 7.2 可利用的漏洞

```
GFW 漏洞利用策略：

1. 协议模拟：
   ├─ 模拟正常 HTTPS 流量
   ├─ 使用真实 TLS 证书
   └─ 协议头完全兼容浏览器

2. CDN 隐蔽：
   ├─ 使用正常网站的 CDN
   ├─ 域前置（Domain Fronting）
   └─ IP 快速切换

3. 流量分散：
   ├─ 多端口负载均衡
   ├─ 快速协议切换
   └─ 协议混淆

4. 连接复用：
   ├─ 长连接减少握手次数
   ├─ 连接池减少新连接
   └─ 降低被发现概率
```

---

## 8. 总结：理解 GFW 是对抗的前提

理解 GFW 的工作原理对于设计和部署有效的翻墙方案至关重要。核心要点：

```
GFW 审查手段总结：

┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│  被动检测（Passive Detection）：                                   │
│  ├─ DPI 深度包检测                                               │
│  ├─ 关键字过滤（HTTP）                                            │
│  ├─ SNI 检测（HTTPS）                                             │
│  ├─ TLS 指纹分析（JA3/JA3S）                                       │
│  └─ DNS 污染                                                      │
│                                                                 │
│  主动干扰（Active Interference）：                                 │
│  ├─ TCP RST 注入                                                  │
│  ├─ 连接超时设置                                                  │
│  ├─ BGP 黑洞路由                                                 │
│  └─ 主动探测                                                      │
│                                                                 │
│  封锁执行（Blocking）：                                           │
│  ├─ IP 黑名单                                                    │
│  ├─ 域名黑名单                                                    │
│  ├─ AS 级别封锁                                                  │
│  └─ 自治系统对等断开                                               │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘

有效翻墙的关键：
1. 协议层面：使用 TLS 伪装，模拟正常 HTTPS 流量
2. 传输层面：使用 CDN 或代理中转，隐藏真实 IP
3. 特征层面：去除协议指纹，使用标准 TLS 库
4. 架构层面：分散部署，快速切换，冗余备份
```

理解 GFW 的技术原理不是为了规避审查，而是为了设计更安全、更健壮的网络通信系统。在企业环境中，这些知识对于防御类似的网络攻击和构建安全架构同样重要。

---

## 参考资料

1. Cladwell, R. (2012). "The Great Firewall of China." Master's Thesis, MIT
2. Wright, J., et al. (2012). "Towards a Global View of Internet Censorship." ACM SIGCOMM Workshop
3. FIF (2023). "Internet Censorship in China: A Survey of Technologies and Policies."
4. Anonymous Author (2018). "GFW 技术分析报告."
