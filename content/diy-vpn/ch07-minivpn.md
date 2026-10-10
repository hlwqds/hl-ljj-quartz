---
title: "手写 VPN（七）：组装 mini-VPN——加密隧道 × TUN 双端"
date: 2026-10-10 12:00:00
description: "总装章：把前三章的零件（TUN、ChaCha20+HMAC 安全信封、帧格式）拼成双端可跑的 mini-VPN——架构图与数据通路的完整走读（TUN 读出 IP 包→加密封装→UDP→对端验章解密→写回 TUN）、密钥文件格式与双向分钥、select 主循环的分派顺序、keepalive 与会话恢复；静态密钥的局限清单交接给 ch09/ch10。Linux 真机实验指南（交叉编译验证入库）。"
tags: [vpn, tun, crypto, c, linux, series]
---

> [!info] 手写 VPN 系列 0. [[diy-vpn|系列索引]] 1. [[ch01-vpn-anatomy|第一章]] 2. [[ch02-udp-tunnel|第二章]] 3. [[ch03-tun-device|第三章]] 4. [[ch04-stream-cipher|第四章]] 5. [[ch05-mac-replay|第五章]] 6. [[ch06-key-exchange|第六章]] 7. **第七章：组装 mini-VPN**

# 手写 VPN（七）：组装 mini-VPN——加密隧道 × TUN 双端

零件全部到齐：N（ch02 的封装与帧纪律）、V（ch03 的 TUN）、P（ch04/05 的加密信封 + ch06 的密钥哲学）。这一章总装成 **mini-VPN**：两台 Linux 机器各跑一个进程，互相把对方变成 `10.7.0.x` 网段的"直连邻居"，中间隔着的是一条自己造的加密 UDP 隧道。代码不到 500 行（外加前面几章复用的 crypto 源文件），但它是本系列的枢纽——之后的路由（ch08）、对照（ch09）、生产化（ch10）全部围着它转。

---

## 7.1 架构：数据通路完整走一遍

```text
机器 A (10.7.0.1)                                机器 B (10.7.0.2)
┌─────────────────────────────┐                ┌─────────────────────────────┐
│ 应用 ping 10.7.0.2          │                │                             │
│   │ 路由表：10.7.0.0/24 → tun0                              │
│   ▼                         │                │                             │
│ TUN tun0 ──read()──▶ 裸 IP 包│                │ 裸 IP 包 ──write()──▶ TUN   │
│   │                         │   UDP 加密帧   │   ▲  内核当"tun0 收到包"    │
│   ▼ 加密封装：               │ ════════════▶ │   │                         │
│   [ctr][ChaCha20(IP包)][HMAC]│   （公网）     │ 验章 → 窗口 → 解密          │
│ UDP socket ──sendto()──▶ B:51820             │                             │
└─────────────────────────────┘                └─────────────────────────────┘
```

一个方向的完整旅程：`应用 → 路由表 → tun0 → read() 拿到裸 IP 包（ch03 的标本）→ 套安全信封（ch05 格式）→ UDP 发往对端 → 对端验章/查窗口/解密 → write() 注回自己的 tun0 → 对端内核上送 ICMP → echo reply 沿反方向再走一遍`。**两台内核都以为对面是同网段直连主机**——这就是 VPN 的全部魔法，而它的每个零件你都已经手写过。

## 7.2 组装细节：三个值得停下的决定

**帧格式 = ch05 安全信封，载荷换成 IP 包。** `[ctr(8)][ciphertext][tag(32)]`，密文里就是 TUN 读出的裸包。ch02 明文帧的 type/session 字段不需要了——TUN 模式下只有一种载荷（IP 包），"会话"由五元组（源/目的 UDP 端口 + 密钥身份）天然区分。这是隧道形态升级带来的简化：**代理式隧道要管会话表，包级隧道把会话交还给内核路由**。

**双向分钥，计数器独立。** 密钥文件里存 64 字节，KDF 派生两把：`send_key = SHA256(key ∥ "A→B")`、`recv_key = SHA256(key ∥ "B→A")`——两端配置互为镜像，各自用对方方向的钥收、自己方向的钥发。**两个方向各一个 64 位计数器从 1 起**（ch04 的纪律），永不初始化回零；进程重启 = 新密钥文件（静态密钥阶段的妥协，ch10 的改进清单第一项）。

**select 的分派顺序：先 UDP 后 TUN。** 主循环 `select(tun_fd, udp_sock)`，两个就绪时的处理顺序有讲究：先收 UDP（腾空对端来包、推进窗口），再读 TUN 打包发送——**优先消化入向**能避免本机发送队列在突发时顶满。keepalive 每 10 秒发一帧空载荷（ctr 照常推进，窗口照常滑动），兼做 NAT 映射保活（[[p2p-deep-dive|P2P 系列]]ch03 的老朋友）。

## 7.3 跑起来：真机实验指南

```bash
# 编译（Linux 本机或交叉验证：zig cc --target x86_64-linux）
zig cc -O2 -o minivpn minivpn.c chacha20.c sha256.c hmac.c

# 两台机器各一份密钥文件（64B 随机；scp 之——静态密钥的分发即 ch06 的教训现场）
head -c 64 /dev/urandom > vpn.key

# A 机：./minivpn --tun tun0 --key vpn.key --peer B公网:51820 --addr 10.7.0.1/24 --port 51820
# B 机：./minivpn --tun tun0 --key vpn.key --peer A公网:51820 --addr 10.7.0.2/24 --port 51820
#   程序内部自动完成：tun_open → 配地址/MTU 1420 → 主循环

A$ ping 10.7.0.2        # 第一颗 ICMP 包就是 7.1 通路的验收
A$ tcpdump -i eth0 udp port 51820 -X   # 外层只见密文与 HMAC，IP 包内容全隐
```

配套工程 `vpn-labs/ch07-minivpn` 的 `--hexdump` 模式是 ch03 的观察实验（读 TUN 打印 IP 头逐字段），`--loopback` 模式在单机上自环验证加解密通路（tun 读出→封包→解包→比对）。本仓环境无 Linux 真机，以 `zig cc --target x86_64-linux` 交叉编译验证入库，运行输出待真机回填（先成文后实跑惯例）。

> [!tip] 🧪 配套实验：vpn-labs/ch07-minivpn
> mini-VPN 双端完整实现：TUN 读写、安全信封收发、双向分钥、select 主循环、keepalive、`--hexdump`/`--loopback` 观察模式。Linux 真机实验指南见工程 README（含路由/NAT/排错）。源码直达：[minivpn.c（代码浏览）](/static/code/#/vpn-labs/ch07-minivpn/minivpn.c)、[完整工程](/static/code/#/vpn-labs/ch07-minivpn/README.md)、[GitHub 源](https://github.com/hlwqds/hl-ljj-quartz/tree/v4/practice/vpn-labs/ch07-minivpn)。

## 7.4 静态密钥的局限：交接清单

mini-VPN 能跑，但按 ch06 的标准它欠着三笔债，全部记入后两章的议程：

| 债              | 后果                       | 谁来还           |
| --------------- | -------------------------- | ---------------- |
| 密钥静态、无 DH | 无前向保密：泄钥=历史全解  | ch09（Noise）    |
| 密钥手工分发    | 换钥要人跑腿，规模上不去   | ch10（密钥管理） |
| 无身份认证机制  | 拿到密钥文件的任何人都能连 | ch09/ch10        |

还有一笔性能债（用户态 TUN 的上下文切换）也留给 ch09 的对照账本。

## 7.5 小结

- mini-VPN = TUN（V）+ 安全信封（P）+ UDP 隧道（N）的总装：应用 → 路由 → tun0 → 加密 → 公网 → 解密 → 对端 tun0，两台内核互认直连邻居。
- 三个组装决定：包级隧道不需要会话表（会话交还内核）；双向分钥 + 独立计数器永不回零；select 先消化入向。
- keepalive 一石二鸟：NAT 保活 + 窗口推进；MTU 1420 从第一天写进启动配置。
- 静态密钥欠三笔债（前向保密、分发、认证）——正是 ch09 对照 WireGuard 的差距清单。
- `--hexdump`/`--loopback` 两个观察模式把 ch03 的协议标本实验和加解密通路自检内置进工程。

链路通了，下一章把网撒大：让**整台机器**的流量（不止 10.7.0.0/24）都走进隧道——默认路由改写的死锁陷阱、NAT 伪装、DNS 泄漏、MSS 钳制，路由层的四个经典坑一次踩明。[[ch08-routing|第八章：路由与全隧道]]。
