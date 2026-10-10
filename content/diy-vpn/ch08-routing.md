---
title: "手写 VPN（八）：路由与全隧道——让整机流量走进去"
date: 2026-10-10 12:00:00
description: "路由章：split tunnel 与 full tunnel 的分野；改默认路由的经典死锁（去往对端公网的包也被吸进隧道）与两段式路由解法；服务端的 ip_forward + MASQUERADE（NAT 伪装）；DNS 泄漏为什么是全隧道的第一漏点；MTU/MSS 钳制的完整算术。全部命令可复现，配 mini-VPN 实验指南。"
tags: [vpn, network, routing, nat, dns, mtu, series]
---

> [!info] 手写 VPN 系列 0. [[diy-vpn|系列索引]] 1. [[ch01-vpn-anatomy|第一章]] … 7. [[ch07-minivpn|第七章]] 8. **第八章：路由与全隧道**

# 手写 VPN（八）：路由与全隧道——让整机流量走进去

第七章的 mini-VPN 只把 `10.7.0.0/24` 收进隧道——这叫 **split tunnel**（分流：只有目标网段走 VPN）。但 VPN 的经典用姿是 **full tunnel**（全隧道）：默认路由改道，整机流量无一例外走进隧道，在服务端再放归公网。这一章处理从 split 到 full 的全部工程陷阱：路由死锁（8.1）、服务端转发与 NAT（8.2）、DNS 泄漏（8.3）、MTU/MSS 的完整算术（8.4）。命令全部 Linux 可复现，也是 [[vpn-deep-dive|姊妹篇]]隧道章节的系统级补全。

---

## 8.1 默认路由改写的死锁与两段式解法

把默认路由指向 tun0 的第一反应是 `ip route replace default dev tun0`——然后隧道当场断气。死锁推理链条很干净：

```text
① 默认路由 → tun0：所有包进隧道，包括"隧道自己的外层 UDP 包"
② 外层包要去 B 的公网地址 → 查路由 → 走 tun0 → 被塞进隧道
③ 隧道靠外层包存在，外层包进了隧道 → 无限递归，链路饿死
```

解法是**两段式路由**（wg-quick 的 AllowedIPs = 0.0.0.0/0 时干的正是这个）：先给对端公网地址钉一条**更精确的主机路由**走原网关，再改默认路由：

```bash
ip route add B公网IP/32 via 原网关 dev eth0    # ① 例外条款：隧道外层包照走物理网卡
ip route replace default dev tun0              # ② 默认路由入隧道
# 路由匹配是最长前缀优先：/32 例外 > /0 默认，死锁解除
```

```text
改道后的完整通路（full tunnel 出向）：
应用 → any → tun0 → mini-vpn 加密 → UDP（走 /32 例外，从 eth0 出）→ B
B 端解密 → tun0 → 内核 forwarding → NAT → B 的公网网卡 → 真正目的地
```

## 8.2 服务端：ip_forward 与 NAT 伪装

包从 B 的 tun0 进来后要"替 A 出门"，内核得先肯转发、再会改头：

```bash
sysctl -w net.ipv4.ip_forward=1                    # ① 允许在接口间转发（默认关）
iptables -t nat -A POSTROUTING -s 10.7.0.0/24 -o eth0 -j MASQUERADE
                                                   # ② NAT 伪装：源地址 10.7.0.1 → B 的公网地址
```

MASQUERADE 就是 [[p2p-deep-dive|P2P 系列]]ch03 拆过的那张 NAT 映射表（conntrack），只不过这次我们自己当 NAT 盒子：A 的包以 B 的身份出门，回包按映射表还原送回 tun0。不开 ①，包到了 B 的内核直接 ICMP unreachable；不开 ②，回包永远找不到 10.7.0.1（私网地址在公网不可路由）——**两个开关各治一种"通了一半"**。

## 8.3 DNS 泄漏：全隧道的第一漏点

路由全改了，DNS 查询可能仍在裸奔：系统解析器若配的是本地运营商 DNS（或明文 UDP 53），查询走的是**进程直接发包**，某些配置下不守默认路由的规矩，或即便走了隧道、明文 DNS 在服务端出口也没加密——ISP 依然看得到你访问了哪些域名（内容加密、目录裸奔）。三种补法按彻底程度排：

1. 把 DNS 服务器指到隧道内（`10.7.0.1` 上自建 unbound/dnsmasq），查询全程走隧道；
2. 上加密 DNS（DoH/DoT，详见 [[vpn-deep-dive|姊妹篇]]的加密 DNS 章节）；
3. 检查工具：`dnsleaktest.com` 或抓包看 53 端口——**先测量再相信**。

## 8.4 MTU 与 MSS：把第七章的算术算完

ch07 定了 tun0 MTU 1420，full tunnel 下要再算两层：

- **外层再套外层**：如果服务端到目的地还有隧道/PPPoE，路径 MTU 继续缩水——`ping -M do -s 1392 目标` 二分探测真实 PMTU；
- **TCP 的 MSS 钳制**：TCP 握手时双方交换 MSS（一般是 MTU−40），隧道内内核看不到外层开销，会把 MSS 报得过大 → 大包依赖 ICMP "frag needed" 回执，而 ICMP 常被防火墙吞 → **网站大图加载不出但小页面正常**的玄学故障。一劳永逸的钳制：

```bash
iptables -t mangle -A FORWARD -i tun0 -p tcp --tcp-flags SYN,RST SYN \
  -j TCPMSS --clamp-mss-to-pmtu        # 转发路径上按 PMTU 钳 MSS
```

> [!note] 与 mini-VPN 的关系
> 本章命令是系统侧配置（路由/内核/防火墙），不属于 minivpn.c 的代码——这正是包级 VPN 的分工：**程序管隧道两端，系统管流量进出**。真实 WireGuard 亦然：内核管加密隧道，wg-quick 脚本干的全是本章这些活（`wg-quick up` 的源码读起来就是 8.1–8.4 的命令清单）。配套工程 ch07-minivpn 的 README 把这些命令按实验步骤整理成了 checklist。

## 8.5 小结

- split tunnel 只收目标网段；full tunnel 改默认路由，必须先用 /32 主机路由给对端公网地址开例外，否则隧道递归饿死。
- 服务端两开关：ip_forward 让内核肯转发，MASQUERADE 让出去的包以服务端身份出门（conntrack 就是那张 NAT 表）。
- DNS 泄漏 = 内容加密目录裸奔：DNS 进隧道、上 DoH/DoT、先测后信。
- MTU/MSS 双坑：外层叠加继续缩 PMTU；SYN 里的 MSS 报大会造成"小页正常大图卡死"，用 TCPMSS 钳制一劳永逸。
- 程序与系统的分工：minivpn.c 管隧道，路由表/NAT/防火墙管流量——wg-quick 的本质就是本章命令的脚本化。

至此一个功能完整的 VPN 站起来了。但拿它和 WireGuard 摆在一起对照，差距立刻可见——下一章逐项清点：前向保密、身份隐藏、DoS 防护、内核态性能，看真协议在每个维度上比我们的轮子多做了什么、为什么值得。[[ch09-wireguard-contrast|第九章：对照 WireGuard]]。
