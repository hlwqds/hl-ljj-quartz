---
title: "手写 VPN（三）：TUN 虚拟网卡——让 IP 包流进用户态"
date: 2026-10-10 12:00:00
description: "VPN 的 V：Linux /dev/net/tun 的 TUNSETIFF 原理（内核与用户态之间的文件描述符队列）、TUN 与 TAP 的分界（L3 vs L2）、路由表怎么把包骗进虚拟网卡、读出来的是什么（裸 IP 包逐字段）、Windows 的 wintun 对照、MTU 之坑。附 tun_open 的 C 实现与 hexdump 实验——第七章组装 mini-VPN 的地基。"
tags: [vpn, network, tun, linux, kernel, series]
---

> [!info] 手写 VPN 系列 0. [[diy-vpn|系列索引]] 1. [[ch01-vpn-anatomy|第一章]] 2. [[ch02-udp-tunnel|第二章]] 3. **第三章：TUN 虚拟网卡**

# 手写 VPN（三）：TUN 虚拟网卡——让 IP 包流进用户态

第二章的隧道搬运的是"应用交出来的字节流"；包级 VPN 搬运的是"内核交出来的 IP 包"。中间的传送门就是 **TUN 设备**：一块由你的程序喂养的虚拟网卡。这一章拆它：TUN 是什么、怎么打开（3.1）、路由表怎么把包骗进去（3.2）、从它里面读出来的是什么（3.3）、TAP/wintun 两个近亲（3.4）、MTU 这个必踩的坑（3.5）。代码是 Linux 的（TUN 是 Linux/Unix 的原生设施），Windows 侧在 3.4 对照 wintun——本章代码全部进入第七章的 mini-VPN 工程。

---

## 3.1 TUN 的本体：内核与用户态之间的一条队列

TUN（network TUNnel）是内核提供的一个**虚拟网络设备 + 字符设备的配对**。`/dev/net/tun` 打开一个 fd，用 ioctl 把它绑定到一块新建的虚拟网卡（比如 `tun0`）之后，这台设备呈现两个面孔：

```text
  内核视角                          用户态视角（你的 VPN 程序）
  ┌──────────────────┐             ┌──────────────────┐
  │  一块普通网卡 tun0 │   ┌───────▶ │ fd = open("/dev/net/tun")
  │  有 IP、有路由、   │   │ 队列    │ write(fd, ip_packet)  → 包从 tun0 "发出"
  │  收发 IP 包       │◀──┘        │ read(fd, buf)         → 包是内核要经 tun0 送出的
  └──────────────────┘             └──────────────────┘
```

- 内核要把包"发给" `10.7.0.0/24`（路由表指向 tun0）→ 包进入设备队列 → 你的程序 `read()` 拿到**完整的裸 IP 包**（从版本/头长字段开始）；
- 你的程序 `write()` 一个 IP 包 → 内核当作"tun0 收到了一帧" → 交给协议栈处理（本地是 10.7.0.1 就上送，要转发就走 forwarding 路径）。

打开它的标准序列只有十几行：

```c
/* tun_open() —— 第七章 mini-VPN 同款（VPN 的 V，从这十几行开始） */
int tun_open(const char *name)        /* name 如 "tun0"，内核按需创建 */
{
    int fd = open("/dev/net/tun", O_RDWR);
    struct ifreq ifr = { 0 };
    ifr.ifr_flags = IFF_TUN | IFF_NO_PI;   /* L3 设备；不要 4 字节包信息前缀 */
    strncpy(ifr.ifr_name, name, IFNAMSIZ - 1);
    ioctl(fd, TUNSETIFF, &ifr);            /* 绑定/创建虚拟网卡 */
    return fd;                             /* 此后 read/write 的都是裸 IP 包 */
}
```

`IFF_NO_PI` 值得一提：不加它，每个包前会多 4 字节通道信息头（packet information）——TAP 桥接场景有用，L3 隧道用不上，WireGuard 也不带它。

## 3.2 路由表：把包骗进 TUN 的那只手

网卡本身只是个出入口，**流量进来靠路由表**。给 tun0 配上 `10.7.0.1/24`、再把去往对端网段的静态路由指向它，内核的选路就开始"上当"：

```bash
ip addr add 10.7.0.1/24 dev tun0 && ip link set tun0 up
ip route add 10.7.0.0/24 dev tun0        # 或对端网段：ip route add 192.168.8.0/24 dev tun0
ping 10.7.0.2                            # 内核查表 → 包进 tun0 → 你的程序 read() 到 ICMP 包
```

这正是 VPN "对应用透明"的机关：应用以为自己在和一个普通网段通信，实际每个包都掉进了你的用户态程序。第八章把这张网撒得更大——改默认路由让**整机**流量都进来（全隧道），以及随之而来的死锁问题（路由表把去往对端公网地址的包也吸进来，隧道自己断了）。

## 3.3 读出来的是什么：裸 IP 包逐字段

`read(tun_fd)` 给你的就是线缆上 IP 包的原样。拿一个 ICMP echo 看看（mini-VPN 工程的 hexdump 模式干的就是这个）：

```text
45 00 00 54  a1 b2 00 00  40 01 xx xx  0a 07 00 01  0a 07 00 02
│  │  │  │   │         │   │  │  │     │         │   │
│  │  │  └─ 总长 84B    │  └─ TTL=64   └─ 源 10.7.0.1   └─ 目的 10.7.0.2
│  │  └─ DS 字段        └─ 分片=0   协议=1(ICMP)
│  └─ 总头长 20B（4×5）
└─ 版本 4
后面 64B 是 ICMP 头（08 00 = echo request）+ 数据
```

注意两个推论：其一，**你的程序拿到的包没有以太网头**（IFF_TUN 是 L3 设备，以太网帧头由内核在真实网卡上收发时才存在）；其二，第七章往隧道里封的就是这整个字节串，对端 `write()` 回它自己的 TUN——**TUN 之间搬运的是"IP 包的标本"，两头内核都感觉对面是台直连的主机**。

## 3.4 两个近亲：TAP 与 wintun

- **TAP（IFF_TAP）**：L2 模式，读写的是**带以太网帧头**的完整帧，用于桥接场景（OpenVPN 的 bridge 模式、虚拟交换机）。分界一句话：TUN 搬 IP 包（三层），TAP 搬以太帧（二层）。包级 VPN 几乎全用 TUN——少 14 字节头、不用管 ARP。
- **Windows wintun**：Windows 没有内置 TUN，WireGuard 团队写了 wintun 驱动（层 3，语义与 TUN 对齐：读写裸 IP 包），API 是几行 DLL 调用。语义同构意味着**同一份 mini-vpn.c 换上 wintun 适配层就能在 Windows 跑**——这正是我们把 TUN 访问单独封装成 `tun_open()`/`tun_read()`/`tun_write()` 三个函数的原因（第七章的 net 分层）。

## 3.5 MTU：TUN 世界的主要暗坑

虚拟网卡的 MTU 默认 1500，但**隧道内的包还要套加密外衣再过公网**：1500（内层 IP）+ 外层 UDP/IP 头 + 加密帧头 > 路径 MTU 1500 → 内层大包要么被外层 IP 分片（UDP 无重传，丢一片全完），要么卡在队列里发不出去。解法很干脆：**把 tun0 的 MTU 调小**，让内层包从源头就小到能塞进外层：

```bash
ip link set tun0 mtu 1420     # 1500 − 20(IP) − 8(UDP) − ~52(加密帧头/余量)
```

WireGuard 默认 1420、OpenVPN 默认 1500-减配置值，全是这道算术。TCP 流量还会叠加 MSS 钳制问题（第八章路由章统一算这笔账）。

> [!note] 本章代码在哪
> tun_open/hexdump 的完整可编译版本在配套工程 `vpn-labs/ch07-minivpn`（与第七章共用，`--hexdump` 模式即 3.3 的观察实验）。该工程面向 Linux 真机：本仓以 `zig cc --target x86_64-linux` 交叉编译验证入库，运行输出待真机回填——沿用本仓「先成文后实跑」惯例（同 [[embedded-basics|嵌入式硬件基础]]系列的无板先行版）。

## 3.6 小结

- TUN = 内核里的虚拟网卡 + 用户态 fd 的配对：read 拿到内核要发出的裸 IP 包，write 把包注入内核，配对靠 `/dev/net/tun` + TUNSETIFF。
- 流量进 TUN 靠路由表（那只"骗包的手"）：目的网段指向 tun0，应用即无感知；全隧道 = 改默认路由，第八章处理随之而来的回环死锁。
- IFF_TUN 是 L3（无以太网头），TAP 是 L2（带帧头，桥接用）；Windows 的 wintun 语义同构 TUN，封装成 tun_open/tun_read/tun_write 三函数即可跨平台。
- MTU 必须预先调小（1500 − 外层头 − 加密余量 ≈ 1420），否则内层大包触发外层分片，吞吐坍塌。
- VPN 与代理的分水岭就在这块网卡：代理要求应用配合，TUN 对应用完全透明。

V（虚拟）已经认识，N（网络/封装）第二章就通了，现在整条隧道裸奔的只剩 P（专用）。下一章开始三连发：先手写 ChaCha20 流加密——从 XOR 为什么必然被破讲起，到 RFC 8439 的 quarter round 怎么转。[[ch04-stream-cipher|第四章：从 XOR 到 ChaCha20]]。
