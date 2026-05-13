---
title: 网络工具深度系列 Ch3：流量控制与队列管理
date: 2026-04-17 14:00:00
tags: [Network, tc, qdisc, QoS, Traffic Control, netem, HTB, fq_codel]
description: 深入讲解 tc 流量控制原理、qdisc 队列调度算法（HTB/PQ/WFQ）、netem 丢包/延迟模拟，以及 ingress 限速与整型。
---

# 网络工具深度系列 Ch3：流量控制与队列管理

## 1. tc 的本质：Linux 网络包调度框架

Linux 的流量控制（Traffic Control）是一个分层的队列调度框架：

```
发送路径：
  应用 → socket send buffer → TCP层 → IP层 → 路由 → netdev queue → 网卡驱动 → NIC

tc 作用在 netdev queue 层面：
  应用 → TCP → IP → [qdisc] → NIC driver → NIC

qdisc（Queueing Discipline）是 tc 的核心：
  - 控制包怎么排队、怎么发送
  - 可以限速、分优先级、模拟丢包/延迟
  - 可以 attach 到 interface 或 class
```

```
发送路径 (egress)：
  用户进程
    ↓
  TCP (transmit)
    ↓
  qdisc (attached to eth0)
    ├─ class 1:1 (HTB) → rate 10Mbps
    ├─ class 1:10 (HTB) → rate 100Mbps
    └─ class 1:20 (HTB) → rate 1000Mbps
    ↓
  NIC driver → 网卡
```

```
接收路径 (ingress)：
  NIC → 网卡驱动 → [ingress qdisc] → IP stack → TCP → socket buffer
```

> [!note]
> tc 主要工作在 **egress（发送方向）**。ingress 方向的流量控制需要 `ingress qdisc` + `gred`/`atm` 等工具，效果和限制都不同。

---

## 2. qdisc 层级结构

### 2.1 三类 qdisc

```
┌────────────────────────────────────────────────────────────┐
│                 qdisc 类型                                 │
├──────────────────┬──────────────────┬──────────────────────┤
│ 无类 qdisc       │ 有类 qdisc        │ 分类器 (classifier)   │
│ (classless)      │ (classful)       │                      │
├──────────────────┼──────────────────┼──────────────────────┤
│ pfifo_fast       │ HTB (分层令牌桶)  │ u32 (最常用)          │
│ prio (优先级)     │ CBQ (基于类)      │ fw (firewall mark)    │
│ fq_codel (延迟)   │ HFSC (实时)      │ route (基于路由)      │
│ netem (模拟)     │ sfq (公平队列)    │ basic (简单匹配)      │
│ choke (随机丢)   │ fq (公平队列)     │                      │
└──────────────────┴──────────────────┴──────────────────────┘
```

### 2.2 常用 qdisc 详解

```bash
# --- pfifo_fast（默认 qdisc）---
tc qdisc add dev eth0 root pfifo_fast

# 三个 band，数字越小优先级越高
# 格式：priority → band 0/1/2 → FIFO 队列
# band 0: 最高优先级（ToS 0x*0）
# band 1: 次优先级（ToS 0x*2）
# band 2: 默认（其他 ToS）

# --- prio（优先级队列）---
tc qdisc add dev eth0 root handle 1: prio bands 8
# 8 个 band，每个是纯 FIFO
# handle 1: 是 qdisc ID（major:minor）
# 默认 band 0 最高优先级

# --- fq_codel（默认 for 新版 kernel）---
# 抗 bufferbloat，智能丢包，保持低延迟
# Codel = Controlled Delay，监控队列延迟
# FQ = Fair Queueing，每个 flow 一个队列
sysctl net.core.default_qdisc
# 输出：fq_codel

# --- sfq（Stochastic Fair Queueing）---
tc qdisc add dev eth0 root handle 1: sfq perturb 10
# perturb: 每 10 秒换一次 hash（防止某 flow 长期占某队列）
# 每个 flow 一个 FIFO 队列（但实际上是 hash 分配）

# --- netem（网络模拟）---
tc qdisc add dev eth0 root netem delay 100ms 10ms distribution normal
# delay 100ms ± 10ms，正态分布
tc qdisc add dev eth0 root netem delay 100ms loss 0.1%
# 延迟 100ms + 丢包率 0.1%
tc qdisc add dev eth0 root netem corrupt 0.1%
# 0.1% 的包被随机翻转 bit（模拟网络损坏）

# --- choke（随机 early丢包）---
tc qdisc add dev eth0 root handle 1: choke limit 1000 min 100 max 300
# limit: 队列长度上限
# min/max: 丢包阈值（队列 > max 开始丢，< min 停止）
```

---

## 3. HTB：有类 qdisc 的流量整形

### 3.1 HTB 原理

```
HTB = Hierarchical Token Bucket（分层令牌桶）

基本思想：
  - 有一个总带宽上限（eth0 的物理带宽）
  - 每个 class 分得一部分带宽
  - class 之间可以借带宽（ceiling vs rate）

token bucket 机制：
  - bucket 容量 = burst
  - 以 fixed rate 往 bucket 里加 token
  - 包要出去，必须有足够的 token（token 够才能发包）
  - 没有 token → 等待或丢弃
```

### 3.2 HTB 三层参数

```bash
# rate: 保证带宽（一定给你的）
# ceil: 最大带宽（share 时能借到的上限）
# burst: 桶容量（一次性可以突发多大）
# cburst: 突发上限（ceil 的桶容量）

tc qdisc add dev eth0 root handle 1: htb default 20

# class 1:1（根类，总带宽 = 100Mbps）
tc class add dev eth0 parent 1: classid 1:1 htb rate 100mbit burst 15k

# class 1:10（语音流量，高优先级）
tc class add dev eth0 parent 1:1 classid 1:10 htb rate 20mbit burst 15k ceil 100mbit
# rate 20mbit：保证 20Mbps
# ceil 100mbit：可以借到 100Mbps（如果其他 class 不用）

# class 1:20（普通流量，低优先级）
tc class add dev eth0 parent 1:1 classid 1:20 htb rate 80mbit burst 15k ceil 80mbit
# ceil = rate：不借，所以语音流借不到

# 给 class 1:10 加优先级
tc qdisc add dev eth0 parent 1:10 handle 10: sfq

# 给 class 1:20 加优先级
tc qdisc add dev eth0 parent 1:20 handle 20: sfq
```

### 3.3 优先级映射（fw vs u32）

```bash
# 方法 1：fw mark（iptables mark → class）
iptables -A POSTROUTING -t mangle -o eth0 -j MARK --set-mark 10
# 把出方向 eth0 的包 mark=10

tc filter add dev eth0 parent 1: protocol ip prio 1 handle 10 fw classid 1:10
# mark=10 → 送到 class 1:10

# 方法 2：u32（直接匹配包内容）
# 匹配 DSCP=EF（语音）
tc filter add dev eth0 parent 1: protocol ip prio 1 u32 \
    match ip tos 0xb8 0xff \
    classid 1:10

# 匹配目的 port 443
tc filter add dev eth0 parent 1: protocol ip prio 1 u32 \
    match ip dport 443 0xffff \
    classid 1:10
```

---

## 4. netem：网络损伤模拟

### 4.1 基本延迟

```bash
# 固定延迟
tc qdisc add dev eth0 root netem delay 100ms

# 随机延迟（uniform distribution）
tc qdisc add dev eth0 root netem delay 100ms 50ms
# 100ms ± 50ms（55ms~155ms 随机）

# 正态分布延迟（更真实）
tc qdisc add dev eth0 root netem delay 100ms 20ms distribution normal
# 平均 100ms，标准差 20ms

# 相关延迟（每包的延迟和前一个包相关，模拟链路层重传）
tc qdisc add dev eth0 root netem delay 100ms 10ms correlation 70
# 70% 相关性（下一包的延迟有 70% 取决于上一包）
```

### 4.2 丢包

```bash
# 随机丢包（比例）
tc qdisc add dev eth0 root netem loss 0.1%
# 0.1% 的包随机丢失

# 突发丢包（更真实）
tc qdisc add dev eth0 root netem loss 0.1% 25%
# 0.1% 基础丢包率，25% 概率产生突发丢包
# 模拟：物理链路的干扰导致连续丢几个包

# 双向丢包（模拟对称网络损伤）
tc qdisc add dev eth0 root netem loss 0.5%
tc qdisc add dev lo root netem loss 0.5%
```

### 4.3 复制、损坏、重新排序

```bash
# 包复制（模拟网络反射/双路由）
tc qdisc add dev eth0 root netem duplicate 1%
# 1% 的包被发送两次

# 包损坏（随机 bit 翻转）
tc qdisc add dev eth0 root netem corrupt 0.1%
# 0.1% 的包随机翻转 1 bit

# 包重排序（模拟 BDP 大的链路）
tc qdisc add dev eth0 root netem delay 100ms reorder 25% 50%
# 25% 的包会重排（紧随其后的包可能先发出去）
# 50% 相关性（重排和前一个包有关）

# 组合：延迟 + 丢包 + 抖动（完整网络模拟）
tc qdisc add dev eth0 root netem \
    delay 100ms 20ms distribution normal \
    loss 0.1% \
    corrupt 0.01% \
    reorder 5%
```

### 4.4 模拟特定场景

```bash
# 卫星网络（高延迟 + 高抖动 + 低带宽）
tc qdisc add dev eth0 root handle 1: tbf rate 512kbit burst 1540 latency 700ms

# 移动网络（高丢包 + 高延迟）
tc qdisc add dev eth0 root netem delay 150ms 50ms loss 5% corrupt 0.1%

# 拥塞网络（高延迟 + 抖动 + 丢包）
tc qdisc add dev eth0 root netem delay 300ms 100ms distribution normal loss 2%

# 本地环回延迟（测试微服务）
tc qdisc add dev lo root netem delay 5ms
```

---

## 5. ingress qdisc：限速接收

### 5.1 ingress 的限制

```
ingress qdisc 和 egress 有本质区别：

egress（发送）：
  - tc 完全控制队列，可以丢包、延迟、整形
  - 可以 buffer（qdisc 本身有队列）
  - 完全可编程

ingress（接收）：
  - 包已经到 kernel 了，tc 只能分类/限速，不能延迟
  - 不能真正"队列"（只能 drop）
  - 用途：限制入带宽、防攻击（ policing）

 policing = 测量速率 + 超过则丢弃（不缓冲）
```

### 5.2 ingress 限速配置

```bash
# 步骤 1：在 ingress 口 attach qdisc
tc qdisc add dev eth0 ingress

# 步骤 2：添加 filter 限速
# 限制单个 IP 最大 10Mbps
tc filter add dev eth0 parent ffff: protocol ip prio 1 u32 \
    match ip src 10.0.0.50 0xffffffff \
    police rate 10mbit burst 100kbyte \
    drop flowid 1:10

# 解释：
# parent ffff: → ingress qdisc 的 handle（固定 ffff）
# police rate 10mbit → 限速 10Mbps
# burst 100kbyte → 允许的突发量
# drop → 超过就丢
# flowid 1:10 → 给这个流标记（可后续用 tc 统计）

# 步骤 3：多 IP 共享限额（用 shared tree）
tc qdisc add dev eth0 handle 1: root
tc filter add dev eth0 parent 1: protocol ip prio 1 u32 \
    match ip src 10.0.0.0/24 0xffffff00 \
    police rate 100mbit burst 1mbyte \
    drop
# 整个 /24 网段共享 100Mbps
```

### 5.3 fq_codel 和 ingress 冲突问题

```
问题：fq_codel 不能 attach 到 ingress

原因：fq_codel 是 Egress qdisc（假设有控制发送），ingress 是接收路径

解决：用 ingress 的 police 或 tc-filter + action gact
```

---

## 6. filter 与 action 组合

### 6.1 分类器链

```bash
# filter 层级
# parent 1: → attach 到 class 1: 下
tc filter add dev eth0 parent 1: protocol ip prio 1 \
    u32 match ip dport 443 0xffff \
    classid 1:10

# 优先级：prio 1 > prio 2，先匹配
# 没有匹配的包 → default class (htb default 20)
```

### 6.2 常用 action

```bash
# drop（丢弃）
tc filter add dev eth0 parent 1: protocol ip prio 1 u32 \
    match ip src 192.168.1.100 0xffffffff \
    action drop

# pass（放行）
tc filter add dev eth0 parent 1: protocol ip prio 1 u32 \
    match ip dport 22 0xffff \
    action pass

# police（限速）
tc filter add dev eth0 parent 1: protocol ip prio 1 u32 \
    match ip src 10.0.0.0/24 \
    action police rate 50mbit burst 100kbyte drop

# redirect（重定向到其他设备）
# 配合 veth pair 可以把包送到另一个 namespace
tc filter add dev eth0 parent 1: protocol ip prio 1 u32 \
    match ip dport 8080 0xffff \
    action mirred egress redirect dev veth0

# skbedit（修改 mark）
tc filter add dev eth0 parent 1: protocol ip prio 1 u32 \
    match ip src 10.0.0.1 \
    action skbedit mark 100
```

### 6.3 组合：一个完整的 QoS 配置

```bash
#!/bin/bash
# 文件名：qos_setup.sh

# 清空现有 qdisc
tc qdisc del dev eth0 root 2>/dev/null

# 1. attach HTB
tc qdisc add dev eth0 root handle 1: htb default 20

# 2. 创建根类（物理带宽 = 1000Mbps）
tc class add dev eth0 parent 1: classid 1:1 htb rate 1000mbit burst 1m

# 3. 创建子类
# 语音：保证 100Mbps，最多借 900Mbps
tc class add dev eth0 parent 1:1 classid 1:10 htb rate 100mbit burst 1m ceil 900mbit prio 1

# 视频：保证 300Mbps，最多借 700Mbps
tc class add dev eth0 parent 1:1 classid 1:20 htb rate 300mbit burst 1m ceil 700mbit prio 2

# 普通：保证 100Mbps，不借
tc class add dev eth0 parent 1:1 classid 1:30 htb rate 100mbit burst 1m ceil 100mbit prio 3

# 背景：保证 50Mbps，不借
tc class add dev eth0 parent 1:1 classid 1:40 htb rate 50mbit burst 1m ceil 50mbit prio 4

# 4. 每个 class attach SFQ（公平队列）
tc qdisc add dev eth0 parent 1:10 handle 10: sfq perturb 10
tc qdisc add dev eth0 parent 1:20 handle 20: sfq perturb 10
tc qdisc add dev eth0 parent 1:30 handle 30: sfq perturb 10
tc qdisc add dev eth0 parent 1:40 handle 40: sfq perturb 10

# 5. 添加 filter
# DSCP EF (46) → 语音 (1:10)
tc filter add dev eth0 parent 1: protocol ip prio 1 u32 \
    match ip tos 0xb8 0xff \
    classid 1:10

# DSCP AF41 (34) → 视频 (1:20)
tc filter add dev eth0 parent 1: protocol ip prio 2 u32 \
    match ip tos 0x88 0xff \
    classid 1:20

# 端口 80/443 → 普通流量 (1:30)
tc filter add dev eth0 parent 1: protocol ip prio 3 u32 \
    match ip dport 80 0xffff \
    classid 1:30
tc filter add dev eth0 parent 1: protocol ip prio 3 u32 \
    match ip dport 443 0xffff \
    classid 1:30

# 其他 → 背景流量 (1:40)
# (implicitly default 20)
```

---

## 7. 队列监控与调优

### 7.1 查看统计

```bash
# 查看 qdisc 状态
tc -s qdisc show dev eth0

# output:
# qdisc htb 1: root refcnt 2 r2q 10
#  sent 123456789 bytes dev eth0
#  backlog 0b 0p

# 查看 class 统计
tc -s class show dev eth0

# output:
# class htb 1:10 parent 1:1 leaf 10:
#  rate 100Mbit ceil 900Mbit burst 128000b/8 mpu 0b
#  cstats: backlog 0b 0p 0 over 0
#  qstats: backlog 0b 0p 0 drops 0 over 0
#  sent 9876543210 bytes
#  qlen 0
#  children: 1

# 查看 filter 统计
tc -s filter show dev eth0

# 统计丢包
tc -s filter show dev eth0 | grep -A5 "police"

# 快速查看当前 qdisc 配置
tc qdisc show
tc class show
tc filter show
```

### 7.2 调优参数

```bash
# 1. 调整接口的 txqueuelen（NIC 硬件队列长度）
ip link set eth0 txqueuelen 1000
# 默认 1000，高带宽链路可以调大（10000+）

# 2. 调整 generic qdisc（net.core.default_qdisc）
sysctl -w net.core.default_qdisc=fq_codel
# or
sysctl -w net.core.default_qdisc=fq

# 3. 调整 tcp_limit_output_bytes（TCP 突发能力）
sysctl -w net.ipv4.tcp_limit_output_bytes=16384
# 调大可以提升单连接吞吐，但增加 bufferbloat

# 4. 调整 socket buffer（发送端）
sysctl -w net.core.wmem_max=8388608
sysctl -w net.core.wmem_default=262144

# 5. 调整 egress 队列的 fq_codel 参数
tc qdisc replace dev eth0 root fq_codel \
    limit 10000 \
    flows 1024 \
    target 5ms \
    interval 100ms \
    ecn
# limit: 队列长度上限
# flows: flow 数量（哈希桶大小）
# target: 目标延迟
# interval: codel 间隔
# ecn: 开启 ECN（不丢包而是标记）
```

### 7.3 常见问题排查

```bash
# 问题：大量丢包
# 排查：队列满了？
tc -s qdisc show dev eth0 | grep -i drop
# backlog 非 0 → 队列满

# 解法 1：扩大队列
tc qdisc replace dev eth0 root handle 1: pfifo_fast

# 解法 2：限速（不要超过链路带宽）
tc class replace dev eth0 parent 1:1 classid 1:1 htb rate 950mbit

# 问题：延迟抖动严重
# 排查：bufferbloat（大队列 + 高吞吐）
# 解法：用 fq_codel（自动控制队列长度）
tc qdisc replace dev eth0 root fq_codel

# 问题：高并发下某些流饿死
# 排查：SFQ perturb 太长
# 解法：调小 perturb 或换 HTB + 公平共享

# 问题：tc 配置后不生效
# 排查：检查 root handle 是否正确
tc qdisc show | grep -i eth0
# 确认 eth0 已经有 qdisc attach

# 解法：先 del，再 add
tc qdisc del dev eth0 root
tc qdisc add dev eth0 root handle 1: htb
```

---

## 8. 实战：完整限速配置

### 8.1 场景：给容器限带宽

```bash
# eth0 是 host 侧网口
# veth100 是容器侧

# 步骤 1：容器 eth0 用 ifb（中间转发）
ip link add name ifb-veth100 type ifb
ip link set ifb-veth100 up

# 步骤 2：把 veth100 的流量 redirect 到 ifb-veth100
tc qdisc add dev veth100 handle ffff: ingress
tc filter add dev veth100 parent ffff: protocol ip prio 1 u32 \
    match u32 0 \
    action mirred egress redirect dev ifb-veth100

# 步骤 3：在 ifb-veth100 上做 egress 限速
tc qdisc add dev ifb-veth100 root handle 1: htb
tc class add dev ifb-veth100 parent 1: classid 1:1 htb rate 100mbit
tc class add dev ifb-veth100 parent 1:1 classid 1:10 htb rate 100mbit ceil 100mbit
tc qdisc add dev ifb-veth100 parent 1:10 handle 10: sfq

# 现在容器发出的流量最大 100Mbps
```

### 8.2 场景：保障 SSH/登录流量

```bash
# SSH (port 22) 的包优先于其他所有流量

# 步骤 1：建 prio qdisc（三个 band）
tc qdisc add dev eth0 root handle 1: prio bands 3

# 步骤 2：SSH → band 0 (最高)
tc filter add dev eth0 parent 1: protocol ip prio 1 u32 \
    match ip dport 22 0xffff \
    class 1:1

# 步骤 3：其他 TCP → band 1
tc filter add dev eth0 parent 1: protocol ip prio 2 u32 \
    match ip protocol 6 0xff \
    class 1:2

# 步骤 4：其他流量 → band 2
# (implicitly default)

# 步骤 5：band 0 用 FIFO，band 1/2 用 SFQ
tc qdisc add dev eth0 parent 1:1 handle 10: pfifo
tc qdisc add dev eth0 parent 1:2 handle 20: sfq
tc qdisc add dev eth0 parent 1:3 handle 30: sfq
```

### 8.3 场景：双向限速

```bash
# 需要双向限速（上传 + 下载）
# 用 ifb 做 ingress 限速

# e.g., 服务器 eth0 限制下载 100Mbps，上传 50Mbps

# egress (下载) 限速：
tc qdisc add dev eth0 root handle 1: htb
tc class add dev eth0 parent 1: classid 1:1 htb rate 100mbit
tc class add dev eth0 parent 1:1 classid 1:10 htb rate 100mbit
tc qdisc add dev eth0 parent 1:10 handle 10: sfq

# ingress (上传) 限速：
# 需要一个 ifb 设备
ip link add name ifb-eth0 type ifb
ip link set ifb-eth0 up

# 把 eth0 的 ingress 流量 redirect 到 ifb-eth0
tc qdisc add dev eth0 ingress
tc filter add dev eth0 parent ffff: protocol ip prio 1 u32 \
    match u32 0 action mirred egress redirect dev ifb-eth0

# 在 ifb-eth0 上限速
tc qdisc add dev ifb-eth0 root handle 2: htb
tc class add dev ifb-eth0 parent 2: classid 2:1 htb rate 50mbit
tc class add dev ifb-eth0 parent 2:1 classid 2:10 htb rate 50mbit
tc qdisc add dev ifb-eth0 parent 2:10 handle 20: sfq
```

---

## 9. 小结

```
tc 三件事：qdisc（队列）→ class（分类）→ filter（匹配）

qdisc：
  pfifo_fast: 默认，简单 FIFO
  fq_codel: 抗 bufferbloat，智能丢包
  netem: 网络损伤模拟
  HTB: 有类，整形，限速

filter：
  u32: 最灵活，匹配 L3/L4 头
  fw: 配合 iptables mark
  police: 限速 action

限速方向：
  egress: 直接 attach qdisc
  ingress: 需要 ifb + redirect

网络模拟：
  delay: 延迟
  loss/corrupt: 丢包/损坏
  duplicate: 复制
  reorder: 重排
  组合: netem 支持多参数叠加

调优：
  net.core.default_qdisc = fq_codel/fq
  txqueuelen 调大
  fq_codel 参数: limit/flows/target/interval/ecn
```

---

## 延伸阅读

- `man tc` — tc 完整手册
- `man tc-htb` — HTB qdisc 参数
- `man tc-netem` — netem 参数
- `man tc-fq_codel` — fq_codel 参数
- Linux Advanced Routing & Traffic Control (LARTC): https://lartc.org/
- iproute2 文档: https://www.kernel.org/pub/linux/utils/net/iproute2/