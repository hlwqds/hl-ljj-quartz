---
title: "手写 VPN（二）：明文隧道——UDP 中继与用户态端口转发"
date: 2026-10-10 12:00:00
description: "动手写 VPN 的 N：帧格式设计（会话/序号/类型）、UDP 中继与会话表、select 多路复用、分块与 MTU 教训；为什么选 UDP 做外层载体（TCP-over-TCP 队头阻塞）；实测 curl 穿隧道取网页。结尾指出它是明文裸奔——交给第四、五章的加密零件。"
tags: [vpn, network, tunnel, udp, socket, c, series]
---

> [!info] 手写 VPN 系列 0. [[diy-vpn|系列索引]] 1. [[ch01-vpn-anatomy|第一章]] 2. **第二章：明文隧道**

# 手写 VPN（二）：明文隧道——UDP 中继与用户态端口转发

这一章先造 VPN 的 N（网络/封装）：**一个能用的明文隧道**——本地应用连 `127.0.0.1:13000`，流量被封装成 UDP 帧飞过中继，在对端还原成 TCP 连到真实目标。全程明文（抓包全裸），这正是下一批零件（ch04 加密、ch05 完整性）的装配底座。要回答的工程问题：帧格式怎么设计（2.1）、中继的会话表怎么管理（2.2）、一个进程怎么同时伺候多个 socket（2.3）、为什么外层载体选 UDP（2.4）。

---

## 2.1 帧格式：隧道的第一块骨头

隧道两端必须先对齐"一个 UDP 包里装什么"。我们的帧格式四个字段，够朴素也够真实（WireGuard 的帧同样是 `类型 + 接收方索引 + 计数器 + 载荷` 的极简组合，ch09 对照）：

```text
0        1        5        9
┌────────┬────────┬────────┬───────────────┐
│ type   │ session│ seq    │ payload       │   type: 1=OPEN 2=OPENACK 3=DATA 4=CLOSE
│ (1B)   │ (4B)   │ (4B)   │ (变长)        │   session: 中继侧的会话索引
└────────┴────────┴────────┴───────────────┘
OPEN 帧的 payload = 目标地址字符串 "host\0port\0"
DATA 帧的 payload = 该 TCP 流的一个分片（≤1200B，见 2.4 的 MTU 教训）
```

设计取舍值得逐条说：

- **type 放第一个字节**：收帧方一跳分支，调试时 hexdump 首字节即知帧种；
- **session 4 字节**：中继用它把 UDP 帧映射回对应的 TCP 连接——这就是中继侧的**会话表**键（2.2），本质是简化版的 NAT 映射表（[[p2p-deep-dive|P2P 系列]]ch03 拆过的那张表）；
- **seq 4 字节**：明文阶段它只用于日志对账；等 ch05 加上防重放窗口，它就是滑动窗口的计数器——**帧格式从第一天就给安全字段留位**，是协议设计的习惯；
- **CLOSE 帧**：TCP 优雅关闭要穿过隧道通知对端，否则中继的会话表只能靠超时回收。

## 2.2 中继：一张会话表 + 一把定时器

中继（relay）是隧道的服务端：监听一个 UDP 端口，收到 OPEN 就对目标发起 TCP 连接，之后双向搬运：

```text
  本地应用                中继 relay                     真实目标
    │ TCP                   │                              │
    ▼                       │                              │
  tclient ── OPEN(host:port) ─▶ relay 会话表[sid] ── TCP connect ──▶ 目标
           ◀─ OPENACK ──┤       │
           ── DATA #1 ──▶ sid=1 ├─ write ──▶ 目标
           ◀─ DATA #2 ──│ 读目标 ─┘
           ── CLOSE ───▶ sid=1 删除
```

会话表 `sessions[]`：`sid → { TCP socket, 客户端地址, 最近活跃时间 }`。回收靠两件事：CLOSE 帧即时删 + 30 秒无流量超时删——和 NAT 的映射老化一个逻辑（P2P 系列 ch03 的保活问题在这里同样存在：长连接要么自己发心跳，要么接受 30 秒后被回收重连）。

## 2.3 一个进程伺候所有 socket：select 多路复用

中继要同时等三类事件：UDP 来帧、任意一条 TCP 连接可读（对端数据要打包回客户端）、超时扫描。教科书做法是一个 `select()` 循环管住全部 fd：

```c
/* relay.c 主循环骨架（完整实现在配套工程） */
fd_set rfds;
for (;;) {
    FD_ZERO(&rfds);
    FD_SET(udp_sock, &rfds);              /* ① 新帧进来 */
    for (每个活跃会话 s)
        FD_SET(s->tcp, &rfds);            /* ② 某条 TCP 有数据要搬回客户端 */
    struct timeval tv = { 1, 0 };         /* ③ 每秒扫一次超时会话 */
    select(maxfd + 1, &rfds, NULL, NULL, &tv);

    if (FD_ISSET(udp_sock, &rfds))        /* 分派：UDP → 按 type 处理 */
        handle_frame(...);
    for (每个活跃会话 s)
        if (FD_ISSET(s->tcp, &rfds))      /* TCP 可读 → 包成 DATA 帧发回 */
            relay_tcp_to_udp(s);
    reap_expired_sessions();              /* 超时回收 */
}
```

值得记住的坑：**Windows 的 select 只接受 socket，不接受普通文件描述符**——所以 stdin 没法一起 select（[[p2p-deep-dive|P2P 系列]] ch02 的 net_compat.h 用线程解决过同一问题）。本工程全是 socket，select 干净够用。

## 2.4 两个必踩的坑：MTU 与 TCP-over-TCP

**MTU 教训**：DATA 帧的 payload 上限我们定 1200B，不是拍脑袋——以太网路径 MTU 1500，扣掉 IP/UDP 头 28B，再给将来的加密外衣（ch05 的 nonce+MAC 至少 40B）留量。UDP 包超过路径 MTU 会被 IP 分片，**分片丢一片整包皆输**，而 UDP 没有重传——隧道吞吐会神秘坍塌。所以用户态先把流切成安全小块，这个数字每个真实 VPN 都在调（WireGuard 默认 TUN MTU 1420，同一道算术）。

**为什么外层是 UDP 不是 TCP**：把 TCP 流装进 TCP 隧道（TCP-over-TCP）是性能灾难——内外两层各自重传、各自拥塞控制，外层丢包触发外层重传时，内层又超时重传，放大为**拥塞 meltdown**。[[quic-deep-dive|QUIC 系列]]用整章论证过这件事，结论一致：需要可靠性的用户态隧道应该在 UDP 上**自己**建一层受控可靠性，而不是嵌套内核 TCP。本系列的明文隧道先不管内层可靠性（透传 TCP，可靠性由内层 TCP 自己保证），这正是 WireGuard/OpenVPN-UDP 的同款选择。

## 2.5 实测：curl 穿隧道

配套工程 `vpn-labs/ch02-udp-relay` 的完整闭环（详见其 run.log）：本地起一个 HTTP 服务 → 中继监听 UDP :13001 → tclient 在 :13000 收本地 TCP、封装成 UDP 帧发中继 → curl 指向 :13000 取回网页。中继日志里能逐帧对账：OPEN → OPENACK → DATA #1…#n → CLOSE，字节数与 HTTP 响应一致——**封装、转发、会话管理三件事全部工作**。

```text
$ curl -s http://127.0.0.1:13000/ | head -3
<!DOCTYPE HTML>...              ← 网页穿过隧道回来了
relay 日志: session=1 OPEN 127.0.0.1:8000 → 1
            session=1 DATA in=118B out=2768B   ← 一进一出对账
            session=1 CLOSE（30s 后超时回收）
```

同时抓包（Wireshark 过滤 `udp.port==13001`）你会看到 DATA 帧明文可见——HTTP 头、HTML 全裸。这就是下一部分的靶子。

> [!tip] 🧪 配套实验：vpn-labs/ch02-udp-relay
> 本章隧道的完整可编译实现：tclient（本地 TCP → UDP 帧封装）+ relay（会话表 + select 多路复用 + 超时回收），C11 零依赖。实测 curl 穿隧道取回 HTTP 页面，帧级日志对账。源码直达：[relay.c（代码浏览）](/static/code/#/vpn-labs/ch02-udp-relay/relay.c)、[tclient.c](/static/code/#/vpn-labs/ch02-udp-relay/tclient.c)、[完整工程](/static/code/#/vpn-labs/ch02-udp-relay/README.md)、[GitHub 源](https://github.com/hlwqds/hl-ljj-quartz/tree/v4/practice/vpn-labs/ch02-udp-relay)。

## 2.6 小结

- 隧道的第一块骨头是帧格式：type/session/seq/payload 四字段，session 是中继会话表的键，seq 从第一天就为防重放留位。
- 中继 = 会话表 + select 多路复用 + 超时回收；会话表本质是用户态 NAT 映射表，保活与老化问题同源。
- DATA 分块上限由路径 MTU 倒推（1500 − 28 − 加密余量），UDP 超 MTU 分片即吞吐坍塌。
- 外层选 UDP：TCP-over-TCP 双重重传是拥塞灾难，可靠性由内层协议自己负责——与 WireGuard/QUIC 同款决策。
- 实测闭环：curl 穿隧道取网页成功；抓包同时暴露一切——明文裸奔是下一部分的存在理由。

隧道通了，但它现在只是个"把包装进包"的搬运工。下一章先认识 VPN 的 V——TUN 虚拟网卡：内核怎么凭空造一块网卡、路由表怎么把包骗进去、用户态从哪里读到裸 IP 包。[[ch03-tun-device|第三章：TUN 虚拟网卡]]。
