---
title: 网络工具深度系列 Ch4：网络诊断工具链
date: 2026-04-17 16:00:00
tags: [Network, traceroute, mtr, ping, netstat, ss, ethtool, ip, Diagnostic]
description: 深入讲解 traceroute/mtr 路由追踪、ping 延迟分析、ethtool 链路诊断、ip 命令路由追踪，以及常见故障排查思路与工具组合使用。
---

# 网络工具深度系列 Ch4：网络诊断工具链

## 1. 诊断工具分层模型

```
OSI 模型          工具层
─────────────────────────────
L7 应用层          curl / openssl s_client / nc
L4 传输层          ss / netstat / ncat / nmap -p
L3 网络层          ip / route / traceroute / mtr / ping
L2 链路层          ethtool / ip link / arp / ip neigh
L1 物理层          mii-tool / udev / lspci | grep net
```

> [!note]
> 排查问题的正确顺序：从下往上（先确认物理链路通畅，再查路由，再查端口），而不是直接 curl。

---

## 2. ping：延迟与可达性基础检测

### 2.1 ping 的原理

```
ping 使用 ICMP Echo Request/Reply：

客户端                          服务端
   │                               │
   │───── ICMP Echo Request ──────▶│
   │◀──── ICMP Echo Reply ─────────│

RTT (Round Trip Time) = t2 - t1
                        ↑
                   收到 Reply 的时间 - 发 Request 的时间

注意：ping 走的不是 TCP/UDP，是 ICMP
      有些防火墙会 block ICMP → ping 不通但服务正常
```

### 2.2 常用选项与输出解读

```bash
# 基础 ping
ping 8.8.8.8

# 输出：
# PING 8.8.8.8 (8.8.8.8) 56(84) bytes of data.
# 64 bytes from 8.8.8.8: icmp_seq=1 ttl=117 time=5.23 ms
# 64 bytes from 8.8.8.8: icmp_seq=2 ttl=117 time=5.31 ms
# 64 bytes from 8.8.8.8: icmp_seq=3 ttl=117 time=5.19 ms
# 64 bytes from 8.8.8.8: icmp_seq=4 ttl=117 time=5.25 ms

# ── 字段解释 ──
# 64 bytes:     包大小（56 数据 + 8 ICMP header）
# icmp_seq:     包序列号（丢包检测）
# ttl=117:      剩余寿命（每经过一个 router -1，到 0 丢弃）
# time=5.23ms:  RTT

# 持续 ping（-t 不停止，按 Ctrl+C 结束）
ping -t 8.8.8.8

# 指定包数和间隔
ping -c 10 -i 0.5 8.8.8.8   # 10 个包，间隔 0.5 秒

# 不解析 IP（-n 加速，高吞吐场景）
ping -n 8.8.8.8

# 指定包大小（-s，检测 MTU 问题）
ping -s 1472 10.0.0.1
# 1472 = MTU(1500) - IP(20) - ICMP(8)
# 如果丢包 → MTU 问题（可能路径上某节点禁了分片）

# 路由 record（-R，记录往返路径）
ping -R 8.8.8.8

# 快速失败（-W 1，每秒发一个，1s 不回就报超时）
ping -W 1 192.168.1.254
```

### 2.3 ping 的局限与坑

```bash
# 坑 1：ping 通不代表服务通（ICMP 优先级低）
# Web 服务开在 443，但 ping 8.8.8.8 能通，curl 443 可能丢

# 坑 2：ping 的 RTT 不代表 TCP 延迟
# ICMP 走的是 special queue，TCP 走的是 socket buffer queue
# 网络设备对 ICMP 和 TCP 的处理优先级不同

# 坑 3：ping 的 ttl 值被运营商篡改
traceroute 1.1.1.1  # 看真实 TTL
ping -t 1.1.1.1     # 看到的是运营商处理后的

# 坑 4：ping 不能检测丢包率（瞬时 vs 持续）
# 1% 丢包：ping 100 个包可能一个都没丢，看起来正常
# 应该用 mtr 或持续 ping + 统计
```

### 2.4 ping 统计脚本

```bash
#!/bin/bash
# ping_stat.sh — 持续 ping 并统计丢包和延迟
TARGET=${1:-8.8.8.8}
COUNT=100

ping -c $COUNT $TARGET | tail -1
# 输出：rtt min/avg/max/mdev = 5.19/5.25/5.31/0.05 ms

# 更详细的统计
ping -c $COUNT $TARGET | awk -F'[= ]' '
    /packets transmitted/ {sent=$1; received=$4; lost=$6}
    /rtt min/ {split($8,a,"/"); print "Sent="sent" Recv="received" Lost="$lost"% Avg="$8"ms"}
'
```

---

## 3. traceroute / mtr：路由追踪

### 3.1 traceroute 原理

```
traceroute 使用 TTL 探测：

TTL=1 → 第一跳 router 收到，返回 ICMP Time Exceeded
TTL=2 → 第二跳 router 收到，返回 ICMP Time Exceeded
...
TTL=N → 到达目的地，返回 ICMP Echo Reply（端口不可达或回显）

UDP traceroute（默认）：
  发 UDP 包到 高端口（33434+）
  中间 router → ICMP Time Exceeded（ttl expired）
  目的 host → ICMP Port Unreachable（端口不可达）

ICMP traceroute（-I）：
  发 ICMP Echo，与 ping 相同
  更准确但容易被 block

TCP traceroute（-T，使用 TCP SYN）：
  发 TCP SYN 到 目标端口
  穿透防火墙能力强（常用 -p 443 探 HTTPS 路径）
  需要目的 host 回 SYN-ACK（而非 ICMP Unreachable）
```

### 3.2 常用选项

```bash
# UDP traceroute（默认）
traceroute 8.8.8.8

# ICMP traceroute（更准确，但可能被 block）
traceroute -I 8.8.8.8

# TCP traceroute（穿透防火墙，常用 443 端口）
traceroute -T -p 443 8.8.8.8

# 指定源 IP（多网卡时用）
traceroute -s 10.0.0.50 8.8.8.8

# 指定最大跳数（默认 30）
traceroute -m 20 8.8.8.8

# 不解析 IP（加速）
traceroute -n 8.8.8.8

# 指定包大小（MTU 问题检测）
traceroute -l 1472 8.8.8.8

# 指定每跳探测次数（默认 3）
traceroute -q 1 8.8.8.8   # 每跳只发 1 个包（快）
traceroute -q 5 8.8.8.8   # 每跳发 5 个包（更准）

# 跳过反向 DNS 解析（-n）+ 使用 IP v6（-6）
traceroute -6 ipv6.google.com
```

### 3.3 mtr：实时路由追踪 + 统计

```bash
# mtr = traceroute + ping（每跳持续探测）
mtr 8.8.8.8

# 输出（实时刷新）：
# HOST: myhost       Loss%   Snt   Last   Avg  Best  Wrst StDev
# 1. gateway.local   0.0%    10    0.3   0.4   0.2   1.2   0.2
# 2. 10.0.0.1        0.0%    10    1.2   1.5   1.1   2.1   0.3
# 3. 72.14.215.85    0.0%    10    5.3   5.4   5.1   5.8   0.2
# 4. 8.8.8.8         0.0%    10    5.2   5.3   5.1   5.6   0.1

# ── 字段解释 ──
# Loss%: 丢包率（该 hop 丢包多少）
# Snt:   发送包数
# Last:  最近一次 RTT
# Avg:   平均 RTT
# Best:  最佳 RTT
# Wrst:  最差 RTT
# StDev: 标准差（抖动越大，StDev 越大）

# mtr 的优势：
# 1. 实时持续更新（不是等 traceroute 跑完）
# 2. 丢包率可视化（一眼看出哪跳有问题）
# 3. 统计信息（Avg/Wrst/StDev 比 traceroute 丰富）

# mtr 常用选项
mtr -n 8.8.8.8           # 不做 DNS 解析（快）
mtr -c 20 8.8.8.8        # 只发 20 个包然后退出
mtr -r 8.8.8.8           # report 模式（-c 配合，输出统计后退出）
mtr -b 8.8.8.8           # 同时显示 IP 和 hostname
mtr -i 0.5 8.8.8.8       # 发包间隔 0.5 秒
mtr -w 8.8.8.8           # 宽报表格（显示 AS 号等）

# 生成报告（用于发报告）
mtr --report 8.8.8.8 > mtr_report.txt

# mtr 与 traceroute 的选择
# mtr：实时查看、定位问题（哪个 hop 在丢包）
# traceroute：一次性记录、保存证据（发给网络工程师）
```

### 3.4 读懂 mtr/traceroute 的输出

```
典型输出解读：

正常：
  1. gateway    0.3ms  -  local LAN gateway
  2. 10.0.0.1   1.2ms  -  ISP border router
  3. 72.14.215.  4.5ms -  ISP backbone
  4. 8.8.8.8    5.2ms -  Google DNS

有丢包（某一跳 Loss% > 0）：
  1. gateway    0.0%   -  local OK
  2. 10.0.0.1   0.0%   -  OK
  3. 72.14.215. 15.0%  -  ⚠️ ISP 内部丢包 15%！
  4. 8.8.8.8    15.0%  -  延续（同上）

有延迟（某跳 Last/Avg 突然跳高）：
  1. gateway    0.3ms  -  正常
  2. 10.0.0.1   0.8ms  -  正常
  3. 72.14.215. 50ms   -  ⚠️ 突然跳到 50ms（可能跨运营商）
  4. 108.170.   51ms   -  延续
  5. 8.8.8.8    52ms   -  延续

超时（* * *）：
  3. * * *              -  ⚠️ 路由过滤/防火墙 block ICMP
  → 服务仍然可能可达，traceroute 到不了不代表 ping 不通
  → 用 traceroute -T -p 443 或 mtr -T 强制 TCP 探测

延迟抖动大（StDev 高）：
  1. gateway    0.3ms  StDev 0.2 -  local 很稳定
  2. 10.0.0.1   5.2ms  StDev 12.5 -  ⚠️ 抖动大（可能拥塞）
```

---

## 4. ip 命令：路由与邻居

### 4.1 路由表

```bash
# 查看路由
ip route
# 或
route -n

# 输出：
# default via 10.0.0.1 dev eth0 proto dhcp src 10.0.0.50 metric 100
# 10.0.0.0/24 dev eth0 proto kernel scope link src 10.0.0.50 metric 100
# default → 默认路由（0.0.0.0/0），所有未知目的走这里
# dev eth0 → 从 eth0 发出
# proto dhcp → 通过 DHCP 学来的
# src 10.0.0.50 → 源 IP（出方向用这个 IP 作为 src）
# metric 100 → 路由优先级（越小越优先）

# 查看详细路由（所有 table）
ip route show table all

# 查看某个目标的路由
ip route get 8.8.8.8
# 输出：8.8.8.8 via 10.0.0.1 dev eth0 src 10.0.0.50 uid 0
# 解释：去 8.8.8.8 → 经由 10.0.0.1（gateway）→ 从 eth0 发出 → 源 IP 10.0.0.50

# 查看多路径路由（ECMP）
ip route get 10.0.0.100
# 可能显示：10.0.0.100 via 10.0.0.1 dev eth0
# 再执行一次：10.0.0.100 via 10.0.0.2 dev eth0
# 说明两条路径交替使用（负载均衡）

# 添加静态路由
ip route add 192.168.1.0/24 via 10.0.0.1 dev eth0
ip route add 192.168.1.0/24 via 10.0.0.1 dev eth0 metric 10

# 删除路由
ip route del 192.168.1.0/24

# 修改默认路由
ip route replace default via 192.168.1.1 dev eth1 metric 50

# 添加默认路由（黑洞路由，防泄漏）
ip route add default via 127.0.0.1 dev lo
# 数据包发到 127.0.0.1 → 本地 loopback（丢包）
# 常用于：服务下线后，防止流量路由到旧 IP
```

### 4.2 邻居表（ARP/NDP）

```bash
# 查看 ARP 表
ip neigh show

# 输出：
# 10.0.0.1 dev eth0 lladdr 00:11:22:33:44:55 REACHABLE
# 10.0.0.50 dev eth0 lladdr 00:11:22:33:44:66 DELAY
# 192.168.1.1 dev eth1 lladdr 00:11:22:33:44:77 STALE

# ── 状态解释 ──
# REACHABLE: 有效，mac 地址已知，不需要再 ARP
# STALE: 过期，mac 地址可能变了，需要验证
# DELAY: 等待 ARP 回复（STALE 后进入 DELAY）
# PROBE: 正在探测
# PERMANENT: 手动配置，永不过期

# 手动添加 ARP entry（永久）
ip neigh add 10.0.0.1 lladdr 00:11:22:33:44:55 dev eth0 nud permanent

# 删除 ARP entry
ip neigh del 10.0.0.1 dev eth0

# 清除所有 STALE entries（重启网络时用）
ip neigh flush all

# 查看某个 IP 的 MAC 地址
ip neigh show 10.0.0.1

# 清空某个 IP 的 ARP cache（强制重新 ARP）
ip neigh del 10.0.0.1 dev eth0 && ping -c1 10.0.0.1
```

### 4.3 链路管理

```bash
# 查看所有网卡（等同于 ifconfig）
ip link show

# 查看具体网卡
ip link show eth0

# 启用/禁用网卡
ip link set eth0 up
ip link set eth0 down

# 设置 MAC 地址（测试用）
ip link set eth0 address 00:11:22:33:44:55

# 设置 MTU（巨帧优化）
ip link set eth0 mtu 9000

# 创建 vlan 子接口
ip link add link eth0 name eth0.100 type vlan id 100
ip addr add 10.0.100.0/24 dev eth0.100
ip link set eth0.100 up

# 创建 veth pair（容器/namespace 互联）
ip link add veth0 type veth peer name veth0-peer
ip link set veth0-peer up

# 给网卡加多个 IP
ip addr add 10.0.0.50/24 dev eth0
ip addr add 192.168.1.50/24 dev eth0
# 查看：
ip addr show eth0
```

### 4.4 网络 namespace

```bash
# 创建 namespace
ip netns add ns1

# 查看 namespace 列表
ip netns list

# 在 namespace 里执行命令
ip netns exec ns1 ip link show
ip netns exec ns1 ip addr add 10.0.0.1/24 dev eth0
ip netns exec ns1 ping 8.8.8.8

# 创建 veth pair 并移入 namespace
ip link add veth0 type veth peer name veth0-peer
ip link set veth0-peer netns ns1
ip addr add 10.0.0.50/24 dev veth0
ip link set veth0 up
ip netns exec ns1 ip addr add 10.0.0.1/24 dev veth0-peer
ip netns exec ns1 ip link set veth0-peer up

# 删除 namespace
ip netns del ns1

# namespace 切换（进入 ns1 的网络 namespace）
nsenter -t $(cat /var/run/netns/ns1) -n bash
# exit 后回到 host namespace
```

---

## 5. ethtool：网卡与链路诊断

### 5.1 基本信息

```bash
# 查看网卡基本信息
ethtool eth0

# 输出：
# Settings for eth0:
#     Supported ports: [ TP ]
#     Supported link modes:   10baseT/Half 10baseT/Full
#                             100baseT/Half 100baseT/Full
#                             1000baseT/Full
#     Supported pause frame use: Symmetric
#     Supported FEC modes: Not reported
#     Speed: 1000Mb/s              ← 当前速率
#     Duplex: Full                  ← 全双工
#     Port: Twisted Pair
#     PHYAD: 0
#     Transceiver: internal
#     Auto-negotiation: on
#     MDI-X: Unknown
#     Supports Wake-on: pumbag
#     Wake-on: d
#     Current message level: 0x00000007 (7)
#     Link detected: yes            ← 链路 UP
```

### 5.2 驱动和硬件信息

```bash
# 查看驱动信息
ethtool -i eth0

# output:
# driver: igb
# version: 5.13.0
# firmware-version: 1.5.4
# expansion-rom-version:
# bus-info: 0000:01:00.0
# supports-statistics: yes
# supports-test: yes
# supports-eeprom-access: yes
# supports-register-domic: yes
# supports-priv-flags: no

# 诊断硬件（自检，需要驱动支持）
ethtool -t eth0
# 离线测试（需要拔网线）需要 -t eth0 offline

# 查看 pause frame（流量控制）配置
ethtool -a eth0
```

### 5.3 统计信息

```bash
# 查看详细统计
ethtool -S eth0

# 关键字段解释：
# rx_packets / tx_packets      收/发包数
# rx_bytes / tx_bytes          收/发字节数
# rx_errors / tx_errors        收/发错误数
# rx_dropped / tx_dropped      收/发丢包数（重要！）
# rx_overrun / tx_carrier      超限/载波错误
# collisions                   冲突（半双工时才有）

# 关键诊断指标：
# rx_dropped 非 0 → kernel 缓冲区满（增加 rx buffer）
# tx_dropped 非 0 → 网卡发送队列满（增加 tx queue len）
# collisions 非 0 → 双工不匹配或网络拥塞
# tx_errors 非 0 → 坏帧或 driver 问题

# 监控统计变化（用于诊断突发问题）
ethtool -S eth0 | grep -E "rx_dropped|tx_dropped|errors"
```

### 5.4 offload 功能

```bash
# 查看 offload 功能
ethtool -k eth0

# output:
# tcp-segment-offload: on
# scatter-gather: on
# generic-segment-offload: on
# generic-receive-offload: on   ← GRO（重要！）
# rx-checksumming: on
# tx-checksumming: ipv4
# tx-checksumming: ipv6
# tx-checksum-ipv4: on
# tx-checksum-ipv6: on
# tcp-tso: on                   ← TSO（重要！）
# udp-fragmentation-offload: on
# generic-segment-offload: on

# 关闭 offload（排查问题时用）
ethtool -K eth0 gro off tso off gso off
# 关闭后性能下降，但问题更容易定位

# 开启/关闭 checksum offload
ethtool -K eth0 tx-checksum-ip-non-fragment on

# 关闭 GRO（某些抓包场景需要）
ethtool -K eth0 gro off
# tcpdump 抓的包会更"原始"（不经过 GRO 合并）
```

### 5.5 队列与 RSS

```bash
# 查看多队列配置
ethtool -l eth0
# Combined 8 → 8 个队列（RSS）

# 配置队列数
ethtool -L eth0 combined 4

# 查看每个队列的统计
ethtool -S eth0 | grep -E "tx-[0-9]|rx-[0-9]"

# 查看队列 CPU 绑定
cat /proc/interrupts | grep eth0

# 设置队列 CPU 亲和性（优化网络性能）
# 16 核：每个队列绑定一个 CPU
for i in {0..7}; do
    echo $i > /proc/irq/$(cat /proc/interrupts | grep eth0-Tx-$i | awk '{print $1}')/smp_affinity
done
```

### 5.6 带宽限速（ethtool）

```bash
# 设置端口速率（强制 1Gbps，关闭 auto-neg）
ethtool -s eth0 speed 1000 duplex full autoneg off

# 设置 pause frame（流控）
ethtool -A eth0 tx on rx on

# 查看巨帧配置
ethtool -g eth0
# output:
# Ring parameters for eth0:
# Pre-set maximums:
# RX:   4096
# TX:   4096
# Current hardware settings:
# RX:   256          ← 当前 rx ring size
# TX:   256          ← 当前 tx ring size

# 调大半夜 buffer
ethtool -G eth0 rx 4096 tx 4096
```

---

## 6. nc / ncat：瑞士军刀

### 6.1 端口扫描

```bash
# 快速扫描单个端口
nc -zv 10.0.0.1 443
# output: Connection to 10.0.0.1 443 port [tcp/https] succeeded!

# 扫描端口范围
nc -zv 10.0.0.1 80-90

# UDP 扫描（-u）
nc -zuv 10.0.0.1 53

# 扫描多个端口（one-liner）
for port in 22 80 443 3306 6379; do
    nc -zv -w 2 10.0.0.1 $port 2>&1 | grep -E "succeeded|failed"
done
```

### 6.2 连接测试（替代 telnet）

```bash
# 测试 TCP 端口连通性（替代 telnet）
nc -v 10.0.0.1 80

# 测试 HTTPS + SNI
nc -v 10.0.0.1 443

# 测试 HTTP keep-alive
echo -e "GET / HTTP/1.1\r\nHost: example.com\r\nConnection: keep-alive\r\n\r\n" | nc 10.0.0.1 80

# 测试 QUIC/UDP（-u）
nc -v -u 10.0.0.1 443
```

### 6.3 代理与隧道

```bash
# 简单 HTTP 代理（nc 作为中转）
# 机器 A（内网）无法直接访问外网
# 机器 B（有外网 IP）作为代理

# 机器 A：
nc -v proxy.example.com 8080

# 发送 HTTP CONNECT 请求
# CONNECT google.com:443 HTTP/1.1
# 然后 nc 变成透明隧道

# 端口转发（替代 iptables）
nc -l -p 8080 -c "nc remote.example.com 22"
# 访问本机 8080 → 被转发到 remote.example.com:22

# 传输文件（简单替代 scp）
# 机器 A（发送）：
nc -l 9999 < file.tar.gz

# 机器 B（接收）：
nc A_IP 9999 > file.tar.gz

# 加密传输（ncat）
ncat --ssl -l 9999 < file.tar.gz
ncat --ssl A_IP 9999 > file.tar.gz
```

### 6.4 UDP 测试

```bash
# UDP 客户端
echo "hello" | nc -u 10.0.0.1 53

# UDP 服务端（监听）
nc -ul 9999

# UDP 端口扫描
nc -zuv 10.0.0.1 53

# 测试 DNS
echo -e "example.com" | nc -u -w 2 8.8.8.8 53
```

---

## 7. nmap：端口与服务探测

### 7.1 基础扫描

```bash
# 扫描单个 IP 的常见端口（-F：快速，只扫常见 100 个）
nmap -F 10.0.0.1

# 扫描所有 TCP 端口（-p-）
nmap -p- 10.0.0.1

# 扫描指定端口
nmap -p 22,80,443,3306 10.0.0.1

# 扫描 UDP 端口（-sU）
nmap -sU -p 53,67,68 10.0.0.1

# 不做 ping（-Pn，防火墙禁 ping 时用）
nmap -Pn 10.0.0.1

# 快速返回（-T5，最快但容易被 block）
nmap -T5 -F 10.0.0.1

# 隐蔽扫描（-sS，TCP SYN，不建立完整连接）
nmap -sS 10.0.0.1
# 发送 SYN，收到 SYN-ACK → port open
# 收到 RST → port closed
# 无响应 → filtered
```

### 7.2 服务版本检测

```bash
# 版本检测（-sV，显示服务版本）
nmap -sV 10.0.0.1

# output：
# PORT    STATE  SERVICE  VERSION
# 22/tcp  open   ssh      OpenSSH 8.9
# 80/tcp  open   http     Apache httpd 2.4.52
# 443/tcp open   https    nginx 1.22

# 操作系统检测（-O，需要 root）
nmap -O 10.0.0.1

# 脚本扫描（--script，常用）
nmap --script vuln 10.0.0.1       # 漏洞扫描
nmap --script http-title 10.0.0.1  # 爬网站 title
nmap --script dns-zone-transfer -p 53 -Pn 10.0.0.1  # DNS zone transfer
```

### 7.3 常用扫描组合

```bash
# 全面扫描（端口+版本+OS+脚本，-A = -O -sV --script）
nmap -A 10.0.0.1

# 快速本地网络探测（/24）
nmap -sn 10.0.0.0/24
# -sn：不扫描端口，只发现主机（ping sweep）

# 服务指纹 + 默认脚本
nmap -sC 10.0.0.1

# 探测内网存活性（用 ACK 穿透防火墙）
nmap -sA 10.0.0.1

# 扫描结果保存（-oA：所有格式）
nmap -oA scan_result 10.0.0.1
# 输出：scan_result.xml / scan_result.gnmap / scan_result.nmap
```

---

## 8. 故障排查实战流程

### 8.1 场景：服务访问不通

```
排查步骤：

Step 1: ping 确认可达性
  ping -c 3 10.0.0.1
  ✅ 能 ping 通 → 网络层 OK，继续 Step 2
  ❌ 不能 ping 通 → 物理层/路由问题 → 检查链路、光纤、ARP

Step 2: traceroute 看路由
  traceroute -T -p 443 10.0.0.1
  看哪一跳超时/丢包

Step 3: telnet/nc 确认端口
  nc -zv 10.0.0.1 443
  ✅ 连上 → 服务层 OK
  ❌ 拒绝 → 防火墙 block 或服务没开

Step 4: ss 确认服务在监听
  ss -tlnapl | grep :443
  看输出，确认服务绑在哪个 IP:port

Step 5: iptables 查防火墙规则
  iptables -L -n -v | grep 443
  确认 INPUT chain 是否有 DROP/REJECT

Step 6: ethtool 查链路状态
  ethtool eth0
  看 Speed/Duplex/Link detected
  ✅ Speed: 1000Mb/s, Link: yes → 物理层 OK
  ❌ Speed 变成 100Mb/s → 可能是光模块/光纤问题
```

### 8.2 场景：访问慢（延迟高）

```
排查步骤：

Step 1: ping + mtr 定位问题跳
  ping -c 20 目标IP
  mtr 目标IP
  看哪一跳延迟最高

Step 2: 分析丢包率
  mtr 目标IP
  Loss% > 0% → 那一跳有问题

Step 3: 检查 MTU（Fragmentation）
  ping -s 1472 目标IP   # 不丢包 → MTU 正常
  ping -s 9000 目标IP   # 丢包 → PMTUD 问题
  解法：检查路径 MTU discovery 或手动设 mtu

Step 4: 分析 TCP 握手延迟
  curl -w "@curl-format.txt" -o /dev/null -s https://目标IP
  或用 ss -tim 分析 TCP retransmit

Step 5: 检查 QoS / 队列长度
  tc -s qdisc show dev eth0
  看是否有大量 backlog / drops
```

### 8.3 场景：DNS 解析问题

```
排查步骤：

Step 1: nslookup / dig 看解析结果
  dig example.com
  看 ANSWER SECTION 是否正确返回 IP

Step 2: 指定 DNS 服务器
  dig @8.8.8.8 example.com
  用 Google DNS 排除运营商 DNS 问题

Step 3: trace DNS 解析路径
  dig +trace example.com
  看从根服务器开始的完整解析过程

Step 4: 检查 resolv.conf
  cat /etc/resolv.conf
  看 nameserver 配置是否正确

Step 5: 排查 ndots
  # /etc/resolv.conf
  options ndots:2
  # 导致 foo 变成 foo.default.svc.cluster.local（内部域名）
  # 如果内网 DNS 不存在 → 解析失败

Step 6: 检查 DNS 缓存
  systemd-resolve --statistics
  或
  nscd -g
```

### 8.4 场景：带宽不达标（限速相关）

```
排查步骤：

Step 1: ethtool 确认链路速率
  ethtool eth0 | grep Speed
  ✅ 1Gbps → 物理链路 OK
  ❌ 100Mbps → 网线/光模块/协商问题

Step 2: iperf3 测带宽基准
  # server 端：
  iperf3 -s
  
  # client 端：
  iperf3 -c serverIP -R   # -R：下行
  iperf3 -c serverIP      # 上行

Step 3: 检查 QoS 限速
  tc qdisc show dev eth0
  tc class show dev eth0
  确认是否有 tc 规则在限速

Step 4: 检查 bonding/LACP 配置
  cat /proc/net/bonding/bond0
  如果 bonding mode=1（主备）→ 只有一条 active
  如果 bonding mode=4（LACP）→ 确认协商成功

Step 5: 检查 TCP 拥塞控制算法
  sysctl net.ipv4.tcp_congestion_control
  换成 bbr：
  sysctl -w net.ipv4.tcp_congestion_control=bbr
```

---

## 9. 小结

```
诊断工具选择：

ping:           快速确认可达性（ICMP）
traceroute:     一次性路由记录（发给网络工程师）
mtr:            持续观察哪跳在丢包/抖动（自用）
ip route:       确认路由路径，多路径 ECMP
ip neigh:       确认 ARP/NDP，排查 mac 地址问题
ip link:        链路 up/down，vlan/bridge 配置
ip netns:       namespace 隔离问题
ethtool:        链路速率/双工/offload/RSS/统计
nc/ncat:        端口连通性，代理隧道，文件传输
nmap:           端口+服务+OS+漏洞探测
ss:             连接状态（取代 netstat）
tcpdump:        抓包分析（详见 Ch2）
tc:             限速/QoS（详见 Ch3）

排查流程：
  物理层 → 链路层 → 网络层 → 传输层 → 应用层
  ping → arp → ip route → nc -z → curl
```

---

## 延伸阅读

- `man ip` — ip 命令完整手册
- `man ethtool` — ethtool 完整选项
- `man traceroute` — traceroute 选项
- `man mtr` — mtr 选项
- `man nmap` — nmap 完整文档
- `man nc` — netcat 瑞士军刀用法
- Wireshark: https://wiki.wireshark.org/
- iproute2 文档: https://www.kernel.org/pub/linux/utils/net/iproute2/