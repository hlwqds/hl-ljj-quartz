---
title: "RDMA 第十七章：ECN 拥塞通知——端到端拥塞管理"
date: 2026-04-13
tags: [rdma, roce, ecn, explicit-congestion-notification, tcp, ip, roce-ecn, cnp, qos]
description: "详解 ECN（Explicit Congestion Notification）机制：RFC 3168 IP ECN 原理、RoCE v2 CNP 包、ECN 域值、拥塞检测与降速算法，以及 PFC+ECN 协同工作的混合模式。"
---

> [!abstract] 核心要点
> ECN（Explicit Congestion Notification，RFC 3168）是 IP 层的端到端拥塞通知机制。与 PFC 的逐跳反压不同，ECN 通过在数据包上标记拥塞状态，让接收方通知发送方降速。RoCE v2 使用 ECN 实现拥塞控制，配合 PFC 构建完整的无损网络。

---

## 1. ECN 设计背景

### 1.1 为什么需要 ECN

PFC（上一章）在链路层通过 Pause 帧实现反压，但存在以下问题：

```
PFC 的局限性：

  1. 逐跳机制：每跳都需要处理 Pause，增加延迟
  2. 全局暂停：即使只拥塞一个流，也可能影响其他流
  3. Pause Storm：多跳反压可能形成风暴
  4. 颗粒度粗：按 Priority 暂停，无法区分不同流

  ECN 的设计目标：
    - 端到端拥塞通知（不逐跳）
    - 仅标记拥塞，不暂停链路
    - 发送方主动降速，避免丢包
```

### 1.2 ECN 的工作原理

```
ECN 端到端流程：

  发送方                                          接收方
    │                                                │
    │  1. 发送 ECN_CAPABLE 包 (ECT=1)                │
    │ ──────────────────────────────────────────────►│
    │                                                │
    │              Switch 检测到拥塞                 │
    │                    │                           │
    │                    ▼                           │
    │         ┌─────────────────────┐               │
    │         │ 标记 ECN=CE          │               │
    │         │ (Congestion         │               │
    │         │  Experienced)        │               │
    │         └─────────────────────┘               │
    │                    │                           │
    │◄──────────────────────────────────────────────│
    │  2. 接收 CE 标记的包                           │
    │                                                │
    │  3. 发送方降低发送速率                          │
    │ ──────────────────────────────────────────────►│
    │                                                │
    │  4. 接收方发送 CNP 通知拥塞事件                 │
    │ ◄──────────────────────────────────────────────│
    │                                                │
```

---

## 2. IP 层 ECN 原理

### 2.1 ECN 字段（RFC 3168）

ECN 使用 IP Header TOS 字段的低 2 位：

```
IP Header TOS 字节结构：

  ┌─────────────────────────────────────────────────────────────────┐
  │  TOS Byte (8 bits)                                              │
  │  ┌───────────────┬─────────────────┬───────────────────────────┤
  │  │ Precedence (5) │ ECN (2 bits)     │ Throughput (1 bit)       │
  │  └───────────────┴─────────────────┴───────────────────────────┘
  │                                     └── 原来 DiffServ 的低 2 位
  │
  │  ECN 字段 (RFC 3168)：                                           │
  │                                                                   │
  │   00 = Non-ECT (Not ECN-Capable Transport)                        │
  │       不支持 ECN，传统 IP 包                                       │
  │                                                                   │
  │   01 = ECT(0) (ECN-Capable Transport, codepoint 0)              │
  │   10 = ECT(1) (ECN-Capable Transport, codepoint 1)               │
  │       发送方设置，表示支持 ECN                                     │
  │                                                                   │
  │   11 = CE (Congestion Experienced)                               │
  │       网络设备设置，表示遇到拥塞                                   │
  └─────────────────────────────────────────────────────────────────┘
```

### 2.2 ECN 在 IPv4 和 IPv6 中

```
IPv4 Header（20 bytes）：

  ┌─────────────────────────────────────────────────────────────────────┐
  │ Ver=4 │ IHL │  DSCP + ECN  │  Total Length                        │
  │       │     │  (TOS byte)  │                                       │
  ├─────────────────────────────────────────────────────────────────────┤
  │                             │                                     │
  │         ...                 │ ECN: 2 bits (在 TOS 字段低 2 位)    │
  └─────────────────────────────────────────────────────────────────────┘

IPv6 Header（40 bytes）：

  ┌─────────────────────────────────────────────────────────────────────┐
  │ Ver │ Traffic Class (8 bits)                                       │
  │     │  ┌─────────────────────────────────────────────────────────┐ │
  │     │  │  DSCP (6 bits) │ ECN (2 bits)                          │ │
  │     │  └─────────────────────────────────────────────────────────┘ │
  └─────────────────────────────────────────────────────────────────────┘

  注：IPv6 的 Traffic Class 等价于 IPv4 的 Type of Service
```

### 2.3 ECN 标记的传输层封装

ECN 最终需要被传输层识别。RoCE v2 使用 UDP，TCP 支持 ECN：

```
TCP ECN（RFC 3168）：

  ┌─────────────────────────────────────────────────────────────────────┐
  │  TCP Header                                                        │
  │  ┌────────┬────────┬────────┬────────┬────────┬────────┐          │
  │  │Source  │ Dest   │ Sequence │ ...  │ Flags  │CWR|ECE| │  ← ECN flags
  │  │Port    │ Port   │ Number   │      │        │CWR|ECE| │    in TCP
  │  └────────┴────────┴────────┴────────┴────────┴────────┘          │
  │                                                                   │
  │  TCP ECN Flags:                                                   │
  │    ECE (ECN-Echo): 接收方通知发送方收到 CE 标记                     │
  │    CWR (Congestion Window Reduced): 发送方确认已降低速率            │
  │                                                                   │
  └─────────────────────────────────────────────────────────────────────┘

RoCE v2 ECN：

  - RoCE v2 使用 UDP，ECN 标记在 IP 层
  - UDP 本身不处理 ECN，由 RoCE 传输层处理
  - RoCE v2 定义 CNP (Congestion Notification Packet) 进行拥塞通知
```

---

## 3. RoCE v2 ECN 实现

### 3.1 RoCE v2 CNP

RoCE v2 定义了专门的拥塞通知包——CNP（Congestion Notification Packet）：

```
RoCE v2 CNP 格式：

  ┌───────────────────────────────────────────────────────────────────────┐
  │  Ethernet Header (14 bytes)                                           │
  ├───────────────────────────────────────────────────────────────────────┤
  │  IP Header (20/40 bytes)                                              │
  │    ECN = 11 (CE) or ECT marking                                       │
  ├───────────────────────────────────────────────────────────────────────┤
  │  UDP Header (8 bytes)                                                 │
  │    Src Port = 某个 ephemeral port                                     │
  │    Dst Port = 4791 (RoCE v2)                                          │
  ├───────────────────────────────────────────────────────────────────────┤
  │  RoCE v2 CNP Header                                                    │
  │  ┌─────────────────────────────────────────────────────────────────┐ │
  │  │  BTH Opcode = 0xC0                                               │ │
  │  │  Reserved                                                        │ │
  │  │  Congestion Info (16 bytes)                                      │ │
  │  │    - QPN (QP Number, 24 bits)                                    │ │
  │  │    - Reserved                                                    │ │
  │  │    - Flags                                                        │ │
  │  │    - SL (Service Level, 4 bits)                                  │ │
  │  └─────────────────────────────────────────────────────────────────┘ │
  ├───────────────────────────────────────────────────────────────────────┤
  │  ICRC (4 bytes)                                                       │
  ├───────────────────────────────────────────────────────────────────────┤
  │  Ethernet CRC (4 bytes)                                               │
  └───────────────────────────────────────────────────────────────────────┘
```

### 3.2 CNP 触发条件

```
CNP 生成条件：

  接收方在以下情况生成 CNP：
    1. 收到带 ECN CE 标记的 RoCE v2 数据包
    2. 该包的 QP 启用了 ECN 支持

  CNP 生成逻辑：
    if (received_packet.ECN == CE && qp.ecn_enabled) {
        send_cnp(qp);
    }

  注意：
    - CNP 本身不带 payload，仅 42-66 字节
    - CNP 通过与数据包相同的 QP 发回发送方
    - CNP 有最小间隔限制（避免 CNP 风暴）
```

### 3.3 RoCE v2 ECN 标记规则

```
交换机 ECN 标记（RED with ECN）：

  交换机在检测到队列拥塞时，使用 AQM（Active Queue Management）：

    ┌───────────────────────────────────────────────────────────────┐
    │                    Queue Length                               │
    │    0 ──────────── MinThresh ──────────── MaxThresh ───── 100% │
    │    │                 │                      │                 │
    │    │    ECT mark     │   Probabilistic      │     CE mark    │
    │    │    (no ECN)     │   ECN mark           │     (force)    │
    │    │                 │   (ECT→CE)           │                 │
    │    └─────────────────┴──────────────────────┴─────────────────┘
    │                                                                   │
    │  配置参数：                                                        │
    │    - MinThresh: 开始 ECN 标记的阈值                                │
    │    - MaxThresh: 100% 强制 CE 标记的阈值                           │
    │    - MaxLen: 队列最大长度                                          │
    │    - Algorithm: RED (Random Early Detection) with ECN             │
    └───────────────────────────────────────────────────────────────────┘
```

---

## 4. ECN 降速算法

### 4.1 DCQCN（Differential ECN for RDMA over Converged Ethernet）

RoCE v2 使用 DCQCN（Differential ECN）作为拥塞控制算法：

```
DCQCN 算法概述：

  DCQCN 是专门为 RoCE 设计的 ECN 反馈控制算法：
    - 基于 DCQCN（Dong Lab, Cornell）和
      TIMELY（Google）算法的结合
    - 发送方根据 CNP 反馈调整发送速率
    - 支持高速网络（100G/200G/400G）

  关键参数：
    - Target rate: 目标发送速率
    - Min rate: 最小速率（不能低于此值）
    - Max rate: 最大速率（由 NIC 速率决定）
    - Alpha: 平滑因子，控制响应速度
```

### 4.2 DCQCN 状态机

```
DCQCN 降速/提速状态机：

  ┌──────────────────────────────────────────────────────────────────────┐
  │                                                                       │
  │   ┌──────────┐     CNP 收到      ┌──────────────┐                   │
  │   │   Hyper  │◄─────(拥塞)──────│    Fast      │                    │
  │   │  (高速)  │                   │   Recovery   │                    │
  │   │          │     定时器到期     │              │                    │
  │   │  Rate    │──────────────────►│  Rate *= 0.5 │                    │
  │   │ = Max    │                   │  (降半)       │                    │
  │   └──────────┘                   └──────────────┘                    │
  │        │                                 ▲                          │
  │        │                                 │                          │
  │        │      没有新 CNP                 │                          │
  │        │      (拥塞缓解)                 │                          │
  │        │                                 │                          │
  │        ▼                                 │                          │
  │   ┌──────────┐     线性提速        ┌──────────────┐                   │
  │   │  Additive│────────────────────►│  Additive    │                   │
  │   │  Increase│     Rate += α      │  Increase    │                   │
  │   │          │     (每 T/2)       │              │                   │
  │   └──────────┘                    └──────────────┘                    │
  │                                                                       │
  │   速率更新公式：                                                       │
  │     降速：Rate = Rate × 0.5                                           │
  │     提速：Rate = Rate + α × (MaxRate - Rate)                          │
  │           其中 α 是小常数（如 0.001）                                  │
  │                                                                       │
  └──────────────────────────────────────────────────────────────────────┘
```

### 4.3 参数配置

```bash
# Mellanox OFED 配置 ECN 参数
$ ethtool --show-ecn eth0
  ECN configuration:
    rx_ecn_ok: off
    rx_ecn_ce: on
    tx_ecn_ce: off

# 启用 ECN
$ ethtool --set-ecn eth0 enable

# 设置 ECN 参数（如果驱动支持）
$ sysctl -w net.ipv4.tcp_ecn=1

# Mellanox DCQCN 参数（mlnx_qos）
$ mlnx_qos -i eth0 -g 50  # 设置 DCQCN alpha gain
$ mlnx_qos -i eth0 -r 1000000  # 设置最小速率 (Mbps)
```

### 4.4 速率计算示例

```
DCQCN 速率调整示例：

  初始状态：
    - MaxRate = 100 Gbps
    - CurrentRate = 100 Gbps
    - Alpha = 0.001

  T=0: 收到 CNP（拥塞）
    CurrentRate = 100 × 0.5 = 50 Gbps

  T=1,2,3: 没有新 CNP（进入 Additive Increase）
    CurrentRate += Alpha × (MaxRate - CurrentRate)
               = 50 + 0.001 × (100 - 50)
               = 50.05 Gbps
    (每 T/2 执行一次)

  T=10: 再次收到 CNP
    CurrentRate = 50.05 × 0.5 ≈ 25.025 Gbps

  稳定后的行为：
    - 持续拥塞：速率持续下降至 MinRate
    - 拥塞缓解：速率逐渐恢复到 MaxRate
```

---

## 5. ECN 与 PFC 协同工作

### 5.1 混合模式架构

现代 RoCE 网络通常采用 PFC + ECN 混合模式：

```
PFC + ECN 协同架构：

  ┌─────────────────────────────────────────────────────────────────────┐
  │                                                                       │
  │   拥塞检测                                                           │
  │       │                                                               │
  │       ├──► 轻度拥塞 ──► ECN 标记 ──► CNP ──► 发送方降速              │
  │       │         (端到端，不发 Pause 帧)                               │
  │       │                                                               │
  │       └──► 重度拥塞 ──► PFC Pause ──► 链路暂停                       │
  │                 (逐跳反压，避免丢包)                                 │
  │                                                                       │
  │   分层策略：                                                          │
  │     ECN: 第一道防线，处理突发拥塞                                    │
  │     PFC: 最后手段，处理极端拥塞（如 incast）                          │
  │                                                                       │
  └─────────────────────────────────────────────────────────────────────┘
```

### 5.2 配置示例

```bash
# Mellanox 交换机：同时启用 ECN 和 PFC
switch # configure terminal

# 启用 ECN
switch (config) # dcb ecn
switch (config) # dcb ecn enable
switch (config) # dcb ecn min-threshold 100
switch (config) # dcb ecn max-threshold 300

# 启用 PFC（用于极端情况）
switch (config) # dcb pfc enable
switch (config) # dcb pfc priority-map 3

# 网卡侧配置
$ ethtool --set-ecn eth0 enable
$ ethtool --set-pfc eth0 rx 3 on tx 3 on
```

### 5.3 拥塞检测算法

```
ECN 队列管理算法（RED with ECN）：

  队列长度与标记概率关系：

    P_mark
      │
  100% ├────────────────────────────────────────────────
      │                      ╱
      │                    ╱
      │                  ╱
      │                ╱
      │              ╱
      │            ╱
      │          ╱
      │        ╱
      │      ╱
      │    ╱
      │  ╱
      │╱
      └──────────────────────────────────────────────► Queue Length
          MinThresh              MaxThresh

  当队列 > MinThresh 时，开始 ECN 概率标记
  当队列 > MaxThresh 时，100% 标记为 CE
```

---

## 6. ECN 配置与验证

### 6.1 交换机配置

#### Mellanox Spectrum

```bash
# 配置 ECN（RED with ECN）
switch # configure terminal
switch (config) # ecn
switch (config-ecn) # min-threshold 100
switch (config-ecn) # max-threshold 1000
switch (config-ecn) # probability 100
switch (config-ecn) # enable

# 验证 ECN 配置
switch # show ecn
switch # show queue ecn-stats
```

#### Cisco Nexus

```bash
# 配置 ECN
switch# configure terminal
switch(config)# class-map type qos match-any roce
switch(config-cmap-qos)# match cos 3
switch(config-cmap-qos)# exit

switch(config)# policy-map type qos roce_qos
switch(config-pmap-qos)# class roce
switch(config-pmap-qos-c)# set qos-group 3
switch(config-pmap-qos-c)# set ecn 0-1000 100
switch(config-pmap-qos-c)# exit

switch(config)# interface Ethernet 1/1
switch(config-if)# service-policy type qos input roce_qos
```

### 6.2 网卡配置

```bash
# Linux 内核 ECN 配置
# /etc/sysctl.conf

# 启用 IP 层 ECN
net.ipv4.tcp_ecn = 1
net.ipv6.ecn_enable = 1

# RoCE ECN 参数
net.core.roce_ecn_enable = 1
net.core.roce_cnp_timeout = 50   # CNP 超时 (微秒)
net.core.roce_cnp_dscp = 0        # CNP DSCP 值

# 应用更改
$ sysctl -p

# ethtool 查看 ECN 状态
$ ethtool --show-ecn eth0

# 启用 ECN
$ ethtool --set-ecn eth0 enable
```

### 6.3 验证 ECN 工作

```bash
# 1. 检查 ECN 计数器
$ ethtool -S eth0 | grep -i ecn
  rx_ecn_ce: 12345        # 收到 CE 标记的包数
  tx_ecn_ce: 678          # 发送的 CE 标记包数

# 2. 抓包验证 ECN 标记
$ tcpdump -i eth0 -c 10 'ip[1] & 0x03 == 0x03'
  # 过滤 ECN CE 标记的 IP 包

# 3. 使用 ibdevinfo 查看 ECN 支持
$ ibv_devinfo -v | grep -i ecn

# 4. Mellanox perftest 测试 ECN
$ perftest -d mlx5_0 -z -F ecn
  # -z: 使用 ECN
  # -F ecn: 强制 ECN 模式

# 5. 检查 RoCE CNP
$ tcpdump -i eth0 'udp port 4791' -v | grep CNP
```

---

## 7. ECN 故障排除

### 7.1 ECN 不工作常见原因

| 问题             | 原因                  | 解决方案                                  |
| ---------------- | --------------------- | ----------------------------------------- |
| 收到 CE 但无 CNP | 网卡 ECN 未启用       | 启用 ECN: `ethtool --set-ecn eth0 enable` |
| 发送方未降速     | CNP 未到达发送方      | 检查防火墙、交换机 ACL                    |
| ECN 标记率 0%    | 交换机 ECN 未启用     | 配置交换机的 ECN/RED 参数                 |
| 丢包但无 ECN     | 拥塞超过 ECN 处理能力 | 检查 ECN 阈值或启用 PFC                   |
| DCQCN 不收敛     | 参数配置不当          | 调整 alpha、timer 参数                    |

### 7.2 ECN 性能问题

```
ECN 性能调优：

  1. ECN 阈值设置
    - MinThresh: 过低 → 正常流量被标记
    - MinThresh: 过高 → 拥塞时已来不及
    - 建议: 缓冲区大小的 20-30%

  2. CNP 速率限制
    - 避免 CNP 风暴
    - 通常限制每 QP 最小间隔 ~50μs

  3. 降速参数
    - Alpha (提速因子): 影响收敛速度
    - 典型值: 0.001 ~ 0.01
```

### 7.3 调试命令

```bash
# 查看 Mellanox DCQCN 统计
$ cat /sys/kernel/debug/mlx5/mlx5_0/ecn_stats
  cnps_generated: 12345
  cnp_ignored: 12
  cnp_received: 67890

# 查看网卡 ECN 队列统计
$ ethtool -S eth0 | grep -E "ecn|ce_"

# 抓包分析 ECN 交互
$ tcpdump -i eth0 -enn 'ip[1] & 0x03 == 0x03' -c 100
  # 捕获 CE 标记的包

# 检查 CNP 是否到达发送方
$ tcpdump -i eth0 'udp port 4791 and ip[1] & 0x03 == 0x03' -v
```

---

## 8. 总结

```
ECN 关键要点：

  1. 作用：IP 层端到端拥塞通知，避免丢包
  2. 标准：RFC 3168，使用 IP TOS 低 2 位
     - 00 = Non-ECT, 01/10 = ECT, 11 = CE
  3. RoCE v2：使用 CNP（Opcode 0xC0）进行拥塞通知
  4. DCQCN：RoCE 专用降速算法，基于 ECN 反馈调整速率
  5. 协同工作：ECN 处理轻度拥塞，PFC 处理重度拥塞
  6. 配置：需要交换机和网卡同时支持 ECN

  ECN vs PFC：

  ┌─────────────┬─────────────────────┬─────────────────────┐
  │             │        PFC          │         ECN         │
  ├─────────────┼─────────────────────┼─────────────────────┤
  │ 层次        │ 链路层 (L2)         │ 网络层 (L3)         │
  │ 机制        │ Pause 帧反压         │ CE 标记 + CNP      │
  │ 范围        │ 逐跳                 │ 端到端              │
  │ 影响        │ 暂停整个链路         │ 仅影响拥塞流        │
  │ 复杂度      │ 需所有设备配置       │ 端点 + 交换机支持   │
  │ 适用        │ 重度拥塞、最后手段   │ 轻度拥塞、第一防线  │
  └─────────────┴─────────────────────┴─────────────────────┘
```

---

> [!info] 下章预告
> 第十八章将介绍 **DCB（Data Center Bridging）**——IEEE 数据中心桥接标准框架，整合 ETS、PFC、DCBX 等组件构成完整的 RDMA 网络基础设施。
