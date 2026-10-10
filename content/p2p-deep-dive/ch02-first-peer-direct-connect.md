---
title: "P2P 网络深度解析（二）：第一个 P2P 程序——局域网直连与对等发现"
date: 2026-10-10 12:00:00
description: "动手章：用 C + BSD socket 写一个对称的 UDP 聊天程序（同一份代码两端等价，体会'peer'的含义）、UDP 广播发现局域网同伴、把文件拆成块做请求-数据块协议——这是 BitTorrent 分片传输的微缩雏形。最后把程序拿到互联网上跑，精准复现'连不上'的困境，交给第三章的 NAT。"
tags: [p2p, network, socket, c, series]
---

> [!info] P2P 网络深度解析系列 0. [[p2p-deep-dive|系列索引]] 1. [[ch01-p2p-overview|第一章：什么是 P2P]] 2. **第二章：第一个 P2P 程序——局域网直连与对等发现**

# P2P 网络深度解析（二）：第一个 P2P 程序——局域网直连与对等发现

这一章全部是动手：**写一个没有"服务端"的 UDP 聊天程序**（体会代码对称性如何消解 C/S 身份）、**用广播发现局域网里的同伴**（P2P 的第 0 号问题：找到彼此）、**把文件拆成块传输**（所有 P2P 文件系统的原子操作）。所有代码在两台同一局域网的机器（或两个网络命名空间）上可直接运行。章末我们把程序原样搬到互联网上，看它在哪一行卡死——那个卡点就是后两章的主角 NAT。

前置知识：UDP/TCP socket 基础 API。想深入传输层内部机制的（pbuf、UDP PCB 匹配、TCP 状态机），见 [[lwip-deep-dive|lwIP 深度解析系列]]的 [[ch10-udp-pcb-layers|第十章：UDP]] 与 [[ch11-tcp-state-machine|第十一章：TCP 状态机]]——本章站在"用 socket 写对等逻辑"的应用视角。

---

## 2.1 对称性：peer 的代码里没有 accept

### 1. 先看 C/S 的代码形状

写一个 UDP 服务端要 `socket → bind(端口) → recvfrom`，客户端 `socket → sendto`——两份代码，两种身份。而 P2P 程序的第一性原理是：**一份代码，两种能力同时具备**。看对等聊天程序 `peer.c` 的骨架（C + BSD socket，完整可编译版本见本节末的配套实验）：

```c
/* peer.c —— 同一份代码在两台机器上运行，命令行参数给出自己的端口与对端地址 */
struct ctx c = { 0 };
c.sock = socket(AF_INET, SOCK_DGRAM, 0);
bind(c.sock, (struct sockaddr *)&me, sizeof me);   /* 我的端口 */
thread_start(receiver, &c);                        /* 线程：永远在收 */

while (fgets(line, sizeof line, stdin)) {          /* 主线程：随时在发 */
    if (!strcmp(line, "quit")) break;
    send_all(&c, line);                            /* 发给同伴表里每个人 */
}

/* 接收线程：一个 UDP socket 既收又发，收到谁的包谁就进同伴表 */
static void receiver(void *arg)
{
    struct ctx *c = arg;
    for (;;) {
        int n = recvfrom(c->sock, buf, sizeof buf - 1, 0, &from, &fl);
        if (n <= 0)
            continue;                 /* 超时/被打断：继续等 */
        add_peer(c, from);            /* 陌生对端自动入表：对等网络的"发现" */
        printf("<%s:%u> %s\n", inet_ntoa(from.sin_addr), ntohs(from.sin_port), buf);
    }
}
```

A 机运行 `./peer 12000 192.168.1.20:12001`，B 机运行 `./peer 12001 192.168.1.10:12000`——没有 listen/accept 的握手仪式，没有谁是权威。**UDP socket 是天然的对称端点**：bind 之后既能收也能发，"客户端""服务端"的区别只剩下谁先发第一条消息。

### 2. 对称性为什么重要

这份代码的可扩展性体现在一个细节上：`dst` 是列表的话，它就是一个最小群聊——每个 peer 维护一张同伴表，收到消息还可以转发给其他同伴（这行代码加上就是 ch05 泛洪的胚胎）。C/S 模型里"广播给所有人"要服务器维护连接池逐个推送；P2P 里每个节点只对自己的同伴表负责，**消息分发的能力随节点数自动增长**——这正是 ch01 可扩展性账本的代码形态。

> [!note] 为什么选 UDP 起步而不是 TCP
> TCP 的 listen/accept 模型把"谁是服务端"焊死在了 API 里（ch04 会讲 TCP 打洞如何绕过这一点，代价高昂）；UDP 没有任何方向预设，是对等连接的最小摩擦载体。真实系统两者都用：BitTorrent 数据传输走 TCP（可靠有序，省心），DHT 与打洞探测走 UDP（无连接、可广播）；WebRTC 的媒体走类 UDP 的 SRTP。载体选择本身没有教条，只有权衡。

---

## 2.2 对等发现：局域网里怎么找到对方

上面我们手写了对方的 IP。真实的 P2P 程序第一个要解决的问题是：**同网段里的 peer 怎么互相看见？** 没有服务器发名单，那就问整个网络。

### 1. UDP 广播：向所有人喊话

UDP 广播把目的地址设为子网广播地址（如 `192.168.1.255`），同一二层网络内所有主机都能收到：

```c
/* discover.c —— 协议就两条文本报文：广播喊话 HELLO，单播回应 HERE */
int on = 1;
setsockopt(c.sock, SOL_SOCKET, SO_BROADCAST, (const char *)&on, sizeof on);
/* 默认禁止广播，显式打开——很多人第一次写广播程序就栽在这里 */

snprintf(hello, sizeof hello, "HELLO %s\n", name);
sendto(c.sock, hello, strlen(hello), 0, &bc, sizeof bc);  /* 向 255.255.255.255 喊话 */

/* 接收线程：HELLO → 回 HERE；HERE → 记入同伴表 */
if (strcmp(cmd, "HELLO") == 0)
    sendto(c.sock, here, strlen(here), 0, &from, fl);     /* 谁喊话我应谁 */
note_peer(&c, from, name);                                /* 这张表 = 路由表第 0 版 */
```

两台机器同时跑这段代码，各自打印出对方——**发现协议的雏形就这两步：广播 HELLO + 单播回应**。工业级方案（mDNS/Bonjour、SSDP）是这个模式加上了 TTL、去重、组播地址与冲突消解，骨架完全一致。Chord/Kademlia 里"找新节点"的 bootstrap 问题（ch06/ch07）在局域网的解法也是它，在互联网上的解法则换成知名 bootstrap 节点或路由器缓存。

### 2. 发现之后：记住同伴，拓扑开始生长

把每次发现到的同伴存进 `peers = {}` 字典，一个最原始的**路由表**就诞生了。此时把 2.1 聊天程序的 `dst` 换成遍历 `peers`，你得到一个自动组网的群聊——这个"同伴表"会一路进化成本系列的骨架概念：Gnutella 的邻居表（ch05）、Chord 的 finger table（ch06）、Kademlia 的 k-bucket（ch07）。

```text
  ┌──────┐ peers=[B]   ┌──────┐
  │  A   │◀───────────▶│  B   │      广播一轮后：
  └──────┘             └──────┘      每个 peer 都有一张"我看见过谁"的表
       ▲ peers=[B,C]     ▲ peers=[A,C]     ← 这张表 = 路由表的第 0 版
       │                 │
  ┌──────┐ peers=[A,B]   │
  │  C   │◀──────────────┘
  └──────┘
```

---

## 2.3 分块传输：P2P 文件系统的原子操作

### 1. 为什么要分块

单条 TCP 直传整文件（`scp` 干的事）无法多源并行：文件在 10 个 peer 手里各有 80%，你想从每个人手里拿它缺的那部分——前提是**文件被切成带编号的块**。分块带来四个革命性性质：

1. **多源并行**：不同块从不同 peer 并行下载，带宽叠加。
2. **边下边传**：拿到块 3 的瞬间就能把它传给需要块 3 的人（BitTorrent 的生命线）。
3. **部分可用**：即使没有任何一个 peer 拥有完整文件，网络整体仍可能拼出全文件。
4. **完整性可校验**：每块一个哈希，坏一块只需重下那块，不用重来。

### 2. 最小实现：请求-数据块协议

在 2.1 的框架上加两条消息类型，就是一个微缩 BitTorrent。协议四条文本报文（摘自 `filecast.c`）：

```c
/* HELLO                 →  接收方开场，请求元数据            */
/* META <n> <sha1>\n     ←  发送方报总块数与整文件 SHA-1      */
/* GET  <i>\n            →  请求第 i 块                       */
/* DATA <i> <bytes>      ←  第 i 块内容（≤1024B）             */

/* 发送端（拥有文件的一方）：请求哪块就回哪块 */
if (strncmp(buf, "GET ", 4) == 0) {
    int i = atoi(buf + 4);
    int hl = snprintf(head, sizeof head, "DATA %d ", i);
    memcpy(pkt, head, hl);
    memcpy(pkt + hl, blob + (long)i * BLOCK, len);
    sendto(s, pkt, hl + len, 0, &from, fl);
}

/* 接收端（拼图的一方）：缺哪块要哪块，丢了就再要 */
while (got < nblocks) {
    for (int i = 0; i < nblocks; i++)
        if (!blocks[i]) {
            snprintf(req, sizeof req, "GET %d", i);   /* 重发缺失请求 */
            sendto(s, req, strlen(req), 0, &dst, sizeof dst);
        }
    n = recvfrom(s, buf, sizeof buf, 0, &from, &fl);  /* 收一块拼一块 */
    if (n > 0 && strncmp(buf, "DATA ", 5) == 0) { /* …解析块号与载荷，blocks[i] = … */ }
}
```

注意接收端那个"超时后回到循环头**重发全部缺失请求**"的结构：UDP 会丢包，接收端用**重试**自愈——这是不可靠传输之上自建可靠性的最小形态（TCP 在内核里做的也是这件事，见 [[lwip-deep-dive|lwIP 系列]]的 [[ch12-tcp-reliability-flow-control|第十二章：TCP 可靠性]]；BitTorrent 在 TCP 之上还要再做一层 piece 级校验，因为 TCP 的校验和挡不住磁盘错误和恶意 peer，ch08 详述）。

### 3. 给它加上哈希

真实系统在分发前把每块的 SHA-1 列表随元数据发布（BitTorrent 的 pieces 字段，ch08 拆解）。接收端每收到一块先验哈希，不匹配即丢弃重请求——**永远不要信任网络另一端**，这个原则在 ch10 会反复回响。

> [!tip] 🧪 配套实验：p2p-labs/ch02-lan-direct
> 本章三个程序（peer 聊天 / discover 发现 / filecast 分块传输）的完整可编译实现——C11 + BSD socket，本机实测 100000B 随机文件分 98 块传输、SHA-1 对账一致。源码直达：[peer.c（代码浏览）](/static/code/#/p2p-labs/ch02-lan-direct/peer.c)、[filecast.c](/static/code/#/p2p-labs/ch02-lan-direct/filecast.c)、[完整工程](/static/code/#/p2p-labs/ch02-lan-direct/README.md)、[GitHub 源](https://github.com/hlwqds/hl-ljj-quartz/tree/v4/practice/p2p-labs/ch02-lan-direct)。

---

## 2.4 实验：把程序搬到互联网上

现在做本章最重要的实验。把 `peer` 原样部署到两台**不同网络**的机器上（家里笔记本 + 云服务器，或两台分别在不同 WiFi 的手机热点后的电脑），把 `<对端IP>` 换成对方的外网地址：

```text
本机（家宽，192.168.1.20）                    云主机（公网 47.x.x.x:12001）
$ ./peer 12000 47.x.x.x:12001
> hello?
>                                            （云主机侧）$ ./peer 12001 192.168.1.20:12000
                                              ← sendto 成功返回，但对端什么也收不到
```

现象分两个方向，值得分别品味：

1. **家宽 → 云主机：能通**。云主机有公网 IP，家宽 NAT 对出站流量自动放行回包，这正是你平时访问任何网站的模式（C/S 的"S"必须有公网地址的原因）。
2. **云主机 → 家宽：不通**。发往 `192.168.1.20` 的包根本出不了云主机的网关（私网地址在公网不可路由）；即便你填的是家宽的公网 IP，包到了家那头的路由器也被丢弃——**路由器不知道该转给内网哪台机器**。

用 `tcpdump`/Wireshark 在两边同时抓包看 UDP 12000，你会亲眼看到单向性：一边只有出站，另一边只有进站，永远对不上。这个"路由器挡住了主动入户的包"的东西，就是 NAT（Network Address Translator）。

```text
      家庭路由器（NAT盒）
内网 192.168.1.20 ──▶ ┌─────────┐ ──▶ 公网 47.x.x.x     出站：改写源地址，记忆映射 ✅
内网 192.168.1.20 ◀── │   NAT   │ ◀── 公网 47.x.x.x     入站：查映射表，查无此映射 → 丢弃 ❌
                      └─────────┘
```

## 2.5 小结

- 对称性是 P2P 代码的形状特征：一份代码同时具备收发能力，UDP socket 天然如此；TCP 的 accept 模型则把 C/S 身份焊进了 API。
- 对等发现三步走：广播 HELLO → 单播回应 → 记入同伴表；这张同伴表是 Gnutella 邻居表、Chord finger table、Kademlia k-bucket 的共同祖先。
- 分块是 P2P 文件系统的原子操作：多源并行、边下边传、部分可用、按块校验——四性质全部来自"块"这个切分，ch08 的 BitTorrent 是它的完成态。
- 不可靠传输之上用"请求-重试"自建可靠性，是最小可用的传输层策略；真实系统在块级再加哈希校验，防丢更防恶意。
- 互联网上的实验精准复现了 P2P 的历史困境：出站能通、入站被拦——拦住它的盒子就是 NAT，它是 2000 年代 P2P 差点死掉的原因，也是今天所有实时互联（WebRTC/Tailscale）要解决的第一题。

下一章拆开这个盒子：NAT 到底怎么改写地址、映射表长什么样、四种 NAT 类型各自的行为差异——这些行为模型决定了你的打洞策略能不能成功。[[ch03-nat-fundamentals|第三章：NAT——P2P 的头号敌人]]。
