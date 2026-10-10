---
title: "P2P 网络深度解析（四）：NAT 穿透——打洞、STUN/TURN 与 ICE"
date: 2026-10-10 12:00:00
description: "把 ch03 的类型学变成武器：UDP 打洞的完整时序（为什么双方同时发包就能互穿）、对称 NAT 的端口预测与生日攻击、STUN 协议报文解剖（magic cookie 与 XOR-MAPPED-ADDRESS）、TURN 中继的代价账本、ICE 把一切编排成候选对逐一试探的框架。这套体系是 WebRTC 与 Tailscale 每天跑几十亿次的连接基建。"
tags: [p2p, network, nat, stun, turn, ice, webrtc, series]
---

> [!info] P2P 网络深度解析系列 0. [[p2p-deep-dive|系列索引]] 1. [[ch01-p2p-overview|第一章]] 2. [[ch02-first-peer-direct-connect|第二章]] 3. [[ch03-nat-fundamentals|第三章]] 4. **第四章：NAT 穿透——打洞、STUN/TURN 与 ICE**

# P2P 网络深度解析（四）：NAT 穿透——打洞、STUN/TURN 与 ICE

第三章的结论是：NAT 的映射行为决定了直连的可行域。这一章把可行域变成日常：**打洞的精确时序**（4.1）、**STUN 协议怎么把你的公网面孔告诉你**（4.2）、**对称 NAT 的端口预测赌博与生日攻击加成**（4.3）、**TURN 中继的代价账本**（4.4）、**ICE 把所有可能性编排成一次自动化的尝试**（4.5）。读完它，"连接失败，走了 TURN 兜底"这句话背后的每一层你都应能拆到底。

---

## 4.1 打洞：让双方的 NAT 同时创建互相指向的映射

### 1. 核心思想

NAT 映射由出站流量创建，而过滤规则放行"被联系过的对端"。那么让 A、B **在同一时刻互相向对方的公网映射发包**：A 的包让 B 的 NAT 记下"A 是合法对端"，B 的包让 A 的 NAT 同样放行——两个方向的映射都建好了，后续流量双向畅通。这就是 UDP 打洞（hole punching），前提是双方先从公网引路服务器（rendezvous server）交换地址情报：

```text
     A（家宽NAT-A）          S（公网引路服务器）           B（家宽NAT-B）
        │── ①register(A) ──────▶│◀───── ②register(B) ──────│
        │                        │                          │
        │◀─ ③"B=198.51.100.9:50001"─── ④"A=203.0.113.7:40001" ─▶│
        │                        │                          │
   ⑤ A → 198.51.100.9:50001  ─────────────────────▶ B的NAT：（源A，凭③后B也发了）放行 ✅
        │                                              │
   ⑥ B → 203.0.113.7:40001   ◀─────────────────────  A的NAT：放行 ✅
        │◀═════════════ ⑦ 此后 P2P 直连，S 不再参与 ═══════════▶│
```

时序上 ⑤⑥ 几乎同时发生（引路服务器在 ③④ 里约定"收到情报立即开打"）。第一个包大概率**被丢**（对端映射还没建），但丢弃这个动作本身就是创建己方映射的过程——两三个来回后洞就通了。丢包不是失败，是施工。

### 2. 一个容易忽略的细节：必须用同一个 socket

第三章实验里 `stun` 命令查到的映射，只在**发起查询的那个本地端口**上有效。打洞的纪律是：**探测公网面孔的 socket、交换情报时登记的 socket、向对端开打的 socket，必须是同一个**——EIM 的"映射全网一致"指的是该本地端点的映射，换了端口等于换了面孔。所有工程化的打洞实现（libwebrtc、libp2p、Tailscale 的 magicsock）都把"一个候选地址 = 一个专用 socket"焊死在架构里。

### 3. 过滤行为决定洞的精度

- 双方都是 EIF（全锥）：甚至不需要同步，一方直接向对方旧映射发包就能入。
- 双方是 APDF（端口受限锥）：⑤⑥ 必须精确互指对方的映射端口，引路服务器给的情报要准（好在 EIM 语义下它准）。
- 一方对称：3.4 节已推导，情报失真，基本打不通 → 4.3 的赌博或 4.4 的中继。

> [!note] TCP 打洞：存在，但脆弱
> 同一时刻双向 SYN 交错（simultaneous open），在 TCP 标准里被定义为同时打开而非冲突，双方进入 SYN_SENT→ESTABLISHED 的特殊路径，部分 EIM 型 NAT 对 TCP 也放行——这就是 TCP 打洞的原理。但它对时序更敏感、很多 NAT 对 TCP 实现的是地址相关映射、且中间盒（防火墙/IDS）常把双向 SYN 判为异常，工程上远不如 UDP 可靠。WebRTC ICE-TCP 只是候选补充，主力永远是 UDP。

> [!tip] 🧪 配套实验：p2p-labs/ch04-hole-punch
> 本节三步时序的可运行版本：rendezvous（引路服务器，只换情报不转数据）+ punch（登记重试 → 收 PEER 情报 → PUNCH/PONG 互射 → 直连聊天 + 3s keepalive）。三进程实测毫秒级时序全记录（alice 重试登记 5 次 → bob 到场配对 → 254ms 收到施工包 → 洞通）。源码直达：[punch.c（代码浏览）](/static/code/#/p2p-labs/ch04-hole-punch/punch.c)、[完整工程](/static/code/#/p2p-labs/ch04-hole-punch/README.md)、[GitHub 源](https://github.com/hlwqds/hl-ljj-quartz/tree/v4/practice/p2p-labs/ch04-hole-punch)。

---

## 4.2 STUN：你的公网面孔查询协议

STUN（Session Traversal Utilities for NAT，RFC 5389/8489）名字里有 session，其实是家族工具箱里最简单的一件：**从公网服务器的视角回答"你从我这里看你是谁"**。

### 1. 报文解剖

一次 Binding 事务：客户端从打洞专用 socket 发 Binding Request，服务器回 Binding Response，携带 XOR-MAPPED-ADDRESS 属性——即服务器观察到的客户端公网 ip:port：

```text
Binding Request (20 字节头)
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|0 0|     STUN Message Type     |         Message Length        |
|         Magic Cookie 0x2112A442 （固定，识别 STUN 流量）        |
|                     Transaction ID （96 位随机，匹配请求响应）  |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

Binding Response
  ... 同上头部 ...
  XOR-MAPPED-ADDRESS: 地址与 magic cookie 异或后编码（防中间盒篡改明文地址）
  其他属性: SOFTWARE, FINGERPRINT ...
```

设计上值得三看：**Transaction ID** 让请求响应在 UDP 丢包重发下可匹配；**magic cookie** 固定值既是版本标识又参与地址异或编码（历史上防 NAT ALG "好心"改写地址字段）；**同一事务跑在应用自己的端口上**——所以查到的地址就是打洞要用的地址，天然满足 4.1 的纪律。

### 2. STUN 在体系里的位置

STUN 只做两件事：**反射你的公网地址**（srflx candidate 的来源）和**充当连通性检查的探针**（ICE 的 Binding 事务复用它）。它不转发数据、不维护会话——那是 TURN 的活。

---

## 4.3 对称 NAT：端口预测与生日攻击

对称 NAT 摧毁了情报的可靠性，但没有封死所有路。观察运营商级设备的外部分配行为：新映射的端口往往是**顺序递增**的（40001, 40002, 40003…）。于是策略变成赌博：

1. A、B 各自向 S 发 N 个探测包（从 N 个不同本地端口），S 观察 A 侧端口序列，推算"再开一个映射大概率的端口区间"；
2. B 从多个端口向预测区间**扇形开火**，赌中 A 即将分配的端口；
3. 成功率由概率保证：对端 NAT 的候选端口窗口 W、我方打出 K 发，命中概率近似生日问题——Ford、Srisuresh 与 Kegel 在 2005 年的经典论文里给出系统测量，**UDP 打洞（含预测技巧）总体成功率约 82%**。

这类技巧在 WebRTC 标准化时被评估过，因过于依赖分配规律且对第三方端口误伤而未进入 ICE 核心，但在学术原型与部分 P2P 软件（早期 Skype 的某些路径）中真实存在。工程上更常见的处理是：**对称 NAT 直接归入"打洞失败"，走中继**——把 18% 的长尾交给 4.4。

> [!tip] 真实世界的成功率结构
> 把人群按 NAT 行为分层：双方皆 EIM（多数家用场景）→ 打洞近乎必成；一方对称 → 概率急剧下降；双方对称/双 CGNAT 叠加 → 基本无解。行业经验值大致是"UDP 直连 75%–85%，剩余走中继"——Skype 时代如此，今天的视频会议与 Tailscale 也仍然如此。**中继不是失败的耻辱，而是设计好的兜底**。

---

## 4.4 TURN：打洞失败时的中继兜底

TURN（Traversal Using Relays around NAT，RFC 5766/8656）是最后一个字母的诚实：**绕**。客户端向 TURN 服务器申请一个**中继端口（allocation）**，之后所有对端流量都经它转发：

```text
   A ⇄ NAT-A ⇄ ═══════ TURN 服务器（公网） ═══════ ⇄ NAT-B ⇄ B
                          A 的数据 → 转给 B；B 的数据 → 转给 A
```

代价账本一目了然：**延迟加一跳、带宽双倍计费、服务器成本回到中心化模型**。TURN 用两个机制缓解滥用：客户端必须为每个对端创建 **Permission**（基于 IP 的白名单，防被当开放代理）；高频小包流可升级为 **Channel 绑定**（4 字节通道头替代 36+ 字节的 STUN 头，省开销）。

设计哲学回到 ch01 的判别标准：**控制平面可以中心化**（引路、情报交换、中继分配都便宜），**数据平面尽力去中心化**（能直连绝不过中继），中继是数据平面最后让步的那 15%。Tailscale 的 DERP 中继、Cloudflare 的 TURN 集群、每一家视频会议厂商的基础设施账单，都是这个让步的实体部分。

---

## 4.5 ICE：把一切编排成一次自动尝试

到此手上的零件：host 地址（本机各网卡）、srflx 地址（STUN 反射）、relay 地址（TURN 分配）、引路服务器、打洞时序。**ICE（Interactive Connectivity Establishment，RFC 8445）**是把这些零件排成一张表并自动跑完的框架：

### 1. 三步流程

```text
① 收集 candidates
   host:    192.168.1.20:5000          （本网段，最高优先级——同 LAN 直连）
   srflx:   203.0.113.7:40001          （STUN 反射，第二优先级）
   relay:   74.x.x.x:39000             （TURN 分配，垫底）
② 经信令通道与对端交换（SDP offer/answer 携带，ch09 展开）
③ 构成候选对，按优先级排序，逐一做 STUN 连通性检查：
   host↔host → host↔srflx → srflx↔srflx → … → 任何↔relay
   每对候选：双方互发 Binding Request（带 ice-ufrag/pwd 凭据）
   第一个双向通的成为"选中对"，其余做备份（nomination 机制）
```

### 2. 三个设计精髓

- **角色分工 controlling/controlled**：双方同时打洞时由 tie-breaker 决出主从，避免双选中冲突——分布式系统里"谁拍板"问题的微缩解法。
- **连通性检查即保活**：选中后的周期性 Binding 事务同时兼任 ICE consent（RFC 7675，探活与防地址劫持）和 NAT 映射保活（ch03 的映射寿命问题），一石三鸟。
- **失败是常态不是异常**：ICE 从不预测哪个候选对会通，它只保证**穷举的顺序合理**。这与 ch03 的教训呼应：不要静态判断 NAT，要在运行时试探。

### 3. 在今天的基础设施里认出它

WebRTC（ch09）的连接建立就是 ICE 的最大规模部署；Tailscale 把同一套思想做进 WireGuard 的 UDP 之上（disco 探测 + DERP 兜底），[[2026-03-12-wireguard-protocol-deep-dive|WireGuard 协议深度解析]]覆盖了其加密层，[[2025-12-02-easytier-learn-rust1|EasyTier 学习笔记]]则是开源 P2P mesh 里的同门实现。

## 4.6 小结

- 打洞 = 双方同时向对方公网映射发包，让两台 NAT 各自创建指向对方的映射；首包被丢是施工不是失败；探测、登记、开打必须用同一个本地 socket。
- STUN 是公网面孔的查询协议：Binding 事务 + XOR-MAPPED-ADDRESS，同时兼任 ICE 的连通性探针；TCP 打洞存在但脆弱，UDP 是主战场。
- 对称 NAT 的出路是端口预测（生日攻击式扇形开火，总体成功率约 82% 的经典测量），工程实践更常直接走中继。
- TURN 的本质是把数据平面的中心化作为最后让步：Permission 防滥用、Channel 省开销，带宽与延迟是它的账单。
- ICE 的编排哲学：收集（host/srflx/relay）→ 交换 → 候选对按优先级穷举试探 → 选中后检查兼保活；**不预测，只试探**。
- 连接问题至此全线打通：两台机器无论躲在什么 NAT 后面，都有一条成本递增的路径可连（直连 < 打洞 < 中继）。

但两台机器的世界太小了。真实的 P2P 网络要面对的是：一百万个节点，谁也不认识谁，谁也记不住所有人——"找到持有某份数据的节点"本身成了分布式系统问题。[[ch05-unstructured-p2p-search|第五章：非结构化 P2P——Gnutella、泛洪与超级节点]]从这个问题的最笨解法开始。
