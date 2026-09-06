---
title: "RDMA 第十六章：PFC 流控——构建无损以太网"
date: 2026-04-13
tags: [rdma, roce, pfc, priority-flow-control, 无损网络, pause-frame, ethernet, dcb]
description: "详解 Priority Flow Control (PFC) 机制：IEEE 802.1Qbb 链路层流控、Priority 定义、Pause 帧格式、DCBX 协商、无损网络配置最佳实践。"
---

> [!abstract] 核心要点
> PFC（Priority Flow Control）是 IEEE 802.1Qbb 标准，在 Ethernet 链路层实现基于优先级的反压机制。通过 MAC Control Pause 帧，上游交换机在检测到下游缓冲区即将溢出时，可暂停特定优先级的流量，从而实现 RoCE 所要求的无损传输。

---

## 1. 为什么 RoCE 需要 PFC

### 1.1 Ethernet 的丢包问题

RoCE 运行在 Ethernet 上，而 Ethernet 本身是"尽力而为"的网络：

```
Ethernet 丢包场景：

  Switch Port Buffer
  ┌─────────────────────────────────────────────────────────────┐
  │                                                             │
  │  ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐         │
  │  │ 1   │ │ 2   │ │ 3   │ │ 4   │ │ 5   │ │ 6   │  ...     │
  │  │     │ │     │ │     │ │     │ │█████│ │     │         │
  │  │     │ │     │ │     │ │     │ │█████│ │     │         │
  │  │     │ │     │ │     │ │     │ │█████│ │     │         │
  │  └─────┘ └─────┘ └─────┘ └─────┘ └─────┘ └─────┘         │
  │                                       └── 缓冲区即将满     │
  │                                           └── 丢包!        │
  └─────────────────────────────────────────────────────────────┘
```

当缓冲区满时，交换机只能丢弃新到的数据包。对于 TCP，可以通过重传恢复；但 RDMA 对丢包极为敏感——丢包导致 WQE 超时和 QP 错误。

### 1.2 PFC vs 普通 Pause

IEEE 802.3 定义了全局 Pause 帧（MAC Control Pause），但它会暂停**所有**流量：

```
全局 Pause 帧问题：

  Port A ────► Switch ────► Port B
                    │
                    ├──► 收到 Pause(时间=T)
                    │    暂停 Port A 的所有流量
                    │    包括非 RDMA 流量（如 Management）
                    │
                    └──► RDMA 和其他协议"一损俱损"
```

PFC（Priority Flow Control）解决了这个问题——它基于 802.1Q VLAN PRIORITY 字段，对**特定优先级**实施反压：

```
PFC 机制：

  8 个 Priority Queue (0-7)
  ┌──────────────────────────────────────────────────────────────┐
  │ Priority 7 │ Priority 6 │ ... │ Priority 2 │ Priority 1 (RDMA)│
  │  Management │   Critical  │     │   Other   │    流量         │
  ├────────────┴────────────┴─────┴───────────┴──────────────────┤
  │                                                              │
  │  当 Priority 1 缓冲区满 → 发送 Pause(PRI=1)                   │
  │  其他优先级继续通行，不受影响                                  │
  └──────────────────────────────────────────────────────────────┘
```

---

## 2. PFC 协议详解

### 2.1 IEEE 802.1Qbb 标准

PFC 是 IEEE 802.1Qbb（Priority-based Flow Control）标准，于 2010 年发布。它在 IEEE 802.3 MAC Control 机制基础上，引入了基于优先级的反压。

### 2.2 PFC 帧格式

PFC 使用 Ethernet MAC Control 帧（EtherType = 0x8808）：

```
PFC Pause 帧结构：

┌─────────────────────────────────────────────────────────────────────────────┐
│  Ethernet Header                                                            │
│  ┌──────────┬──────────┬────────────┬────────────┐                         │
│  │ Dest MAC │ Src MAC  │ EtherType  │ VLAN Tag   │  ← 可选 VLAN             │
│  │ (01:80:C2:00:00:01) │ (0x8808)   │ (0x8100)   │                          │
│  └──────────┴──────────┴────────────┴────────────┘                         │
├─────────────────────────────────────────────────────────────────────────────┤
│  MAC Control Protocol                                                        │
│  ┌────────────┬────────────────────────────────────────────────────────────┐│
│  │ Opcode     │  Length (0x0001)                                           ││
│  │ (0x0101)   │                                                            ││
│  └────────────┴────────────────────────────────────────────────────────────┘│
├─────────────────────────────────────────────────────────────────────────────┤
│  PFC Payload (48 bytes)                                                     │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │  Priority Enable Vector (2 bytes)                                      │ │
│  │   bit[N] = 1 表示对 Priority N 启用 PFC                                │ │
│  ├────────────────────────────────────────────────────────────────────────┤ │
│  │  Time Table (16 × 2 bytes)                                             │ │
│  │   每个 Priority 一个 pause_time 值                                      │ │
│  │   Time[0] = Priority 0 暂停时间                                         │ │
│  │   Time[1] = Priority 1 暂停时间                                         │ │
│  │   ...                                                                   │ │
│  │   Time[7] = Priority 7 暂停时间                                         │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
├─────────────────────────────────────────────────────────────────────────────┤
│  Ethernet CRC (4 bytes)                                                      │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 2.3 Pause Time 字段

Pause Time 以**512 bit time**为单位，最大值 0xFFFF：

```
Pause Time 计算：

  pause_time × 512 bit_time / 端口速率

  例如：100Gbps 端口，pause_time = 0xFFFF
    = 65535 × 512 / 100,000,000,000
    ≈ 336.4 μs

  典型配置：
    - 端口速率 100Gbps
    - 链路距离 100m
    - pause_time ≈ 0xC000 (约 250μs)
```

### 2.4 Priority Enable Vector

```
Priority Enable Vector (2 bytes, bitfield)：

  Bit:  15 14 13 12 11 10  9  8  7  6  5  4  3  2  1  0
  Val: [0][0][0][0][0][0][0][0][0][0][0][0][1][1][1][1]

  当 bit[N] = 1 时，Time[N] 才有效

  示例：仅对 Priority 2-4 启用 PFC
    Enable Vector = 0x001C (二进制 0000 0000 0001 1100)
```

---

## 3. PFC 与 VLAN Priority

### 3.1 802.1Q VLAN PRIORITY 映射

PFC 的优先级来源于 802.1Q VLAN tag 中的 PRIORITY 字段（3 bits，0-7）：

```
802.1Q VLAN Tag 结构：

  ┌─────────────────────────────────────────────────────────────────┐
  │  TPID (2B) │  TCI (2B)                                          │
  │  (0x8100)  │  ┌─────────┬──────────┐                          │
  │            │  │ Priority│   VLAN ID │                          │
  │            │  │ (3 bits)│  (12 bits)│                          │
  │            │  │ PCP     │           │                          │
  │            │  └─────────┴──────────┘                          │
  └─────────────────────────────────────────────────────────────────┘

  PCP (Priority Code Point) → 映射到 traffic_class

  IEEE 802.1Qbb 定义 8 个 traffic class (TC)，对应 Priority 0-7
```

### 3.2 RDMA 流量的 Priority 规划

典型的 RoCE DCB 配置：

```
Priority → Traffic Class 映射（RoCE 常用）：

  Priority 0 → TC 0  (Best Effort - 其他流量)
  Priority 1 → TC 1  (RoCE v2 流量 - 启用 PFC)
  Priority 2 → TC 2  (iSCSI, NFS)
  Priority 3 → TC 3  (Management)
  Priority 4-7 → TC 4-7 (保留)

  Mellanox 推荐的 RoCE 配置：
    - Priority 3 (PCP=3) 用于 RoCE
    - dcbx 对 Priority 3 启用 PFC
```

### 3.3 配置示例：ethtool 设置 Priority

```bash
# 查看当前 DCB 状态
$ ethtool --show-dcb eth0
  Priority Traffic Class:
    Priority 0: TC 0
    Priority 1: TC 1
    ...
    Priority 3: TC 3

# 设置 Priority 3 → TC 3
$ ethtool --set-prio-ring eth0 3 tx 3

# 查看端口 PFC 配置
$ ethtool --show-pfc eth0
  Priority |  TX |  RX
  ---------|-----|-----
    0      | OFF | OFF
    1      | OFF | OFF
    2      | OFF | OFF
    3      | ON  | ON   ← RoCE 流量

# 启用 Priority 3 的 PFC
$ ethtool --set-pfc eth0 forward 3 rx 3 tx on
```

---

## 4. DCBX 协商

### 4.1 DCBX 简介

DCBX（Data Center Bridging Exchange，IEEE 802.1Qaz）是用于在链路两端自动协商 DCB 参数的协议。它让交换机和网卡自动交换 PFC、ETS 等配置。

```
DCBX 架构：

  Host NIC                                    Switch Port
  ┌─────────────────────────────────────────┬───────────────────────┐
  │  DCBX Agent                              │  DCBX Agent           │
  │  ┌─────────────────────────────────┐    │                       │
  │  │ LLDP (用于传输 DCB 参数)         │◄──►│  LLDP                 │
  │  └─────────────────────────────────┘    │                       │
  │  │                                       │                       │
  │  │  ┌────────┐ ┌────────┐ ┌────────┐   │                       │
  │  │  │   PFC  │ │   ETS  │ │  APP   │   │                       │
  │  │  │ Config │ │ Config │ │ TLV    │   │                       │
  │  │  └────────┘ └────────┘ └────────┘   │                       │
  │  └─────────────────────────────────────┘                       │
  └─────────────────────────────────────────┴───────────────────────┘
```

### 4.2 DCBX TLV 类型

```
DCBX 使用 LLDP (Link Layer Discovery Protocol) 承载 TLV：

  ┌──────────────────────────────────────────────────────────────────────┐
  │  DCBX TLV Types                                                      │
  ├──────────────────────────────────────────────────────────────────────┤
  │  Type 127: Vendor-specific                                           │
  │    - CEE (Cisco, Intel, etc.) 格式                                   │
  │    - IEEE 802.1Qaz (DCBX) 格式                                       │
  ├──────────────────────────────────────────────────────────────────────┤
  │  IEEE 802.1Qaz Sub-TLVs:                                             │
  │    - 4: ETS Configuration TLV                                       │
  │    - 5: ETS Recommendation TLV                                      │
  │    - 6: PFC Configuration TLV                                        │
  │    - 7: Application Priority TLV                                     │
  └──────────────────────────────────────────────────────────────────────┘
```

### 4.3 DCBX 模式

```
DCBX 两种模式：

  1. CEE 模式（传统）
     - Intel, Broadcom 等厂商使用
     - 支持 Dell, Cisco 交换机

  2. IEEE 802.1Qaz 模式（标准）
     - 现代交换机推荐
     - 与标准 DCBX 兼容

  自动协商：
    - 两侧交换 DCBX TLV
    - 协商使用共同支持的模式
    - 协商失败则使用默认配置（通常 PFC OFF）
```

### 4.4 配置 DCBX

```bash
# 查看 DCBX 状态
$ ethtool --show-dcbx eth0
  DCBX version: IEEE 802.1Qaz (auto)
  Errored: OK

# 手动设置 DCBX 模式
# mode: 0=auto, 1=CEE, 2=IEEE
$ ethtool --set-dcbx eth0 mode 2

# 启用 DCBX
$ ethtool --set-dcb eth0 forward on

# 验证 DCBX 协商结果
$ ethtool --show-dcb eth0
  DCB mode: enabled
  Priority Group:
    PG0: prio 0,1,2,3,4,5,6,7
    bandwidth: 100%
    strict: 0
  Priority:
    Priority 0: TC 0
    Priority 1: TC 0
    ...
```

---

## 5. PFC 配置实践

### 5.1 交换机侧配置

#### Mellanox Spectrum 交换机

```bash
# 进入配置模式
switch # configure terminal

# 启用 DCB
switch (config) # dcb enable

# 配置 ETS
switch (config) # dcb ets enable
switch (config) # dcb ets priority-map 0,1,2,3,4,5,6,7
switch (config) # dcb ets bandwidth 100,0,0,0,0,0,0,0

# 配置 PFC（对 Priority 3 启用）
switch (config) # dcb pfc enable
switch (config) # dcb pfc priority-map 3
switch (config) # dcb pfc mode on

# 保存配置
switch (config) # write memory
```

#### Cisco Nexus 交换机

```bash
# 启用 DCB
switch# configure terminal
switch(config)# feature dcbxp
switch(config)# feature priority

# 创建 DCB class-map
switch(config)# class-map type network-qos match-any roce
switch(config-cmap-nq)# match cos 3
switch(config-cmap-nq)# exit

# 配置 policy-map
switch(config)# policy-map type network-qos roce_pfc
switch(config-pmap-nq)# class roce
switch(config-pmap-nq-c)# pause pfc-cos 3
switch(config-pmap-nq-c)# exit
switch(config-pmap-nq)# exit

# 应用到端口
switch(config)# interface Ethernet 1/1
switch(config-if)# switchport mode trunk
switch(config-if)# spanning-tree bpdufilter enable
switch(config-if)# service-policy type network-qos input roce_pfc
```

### 5.2 网卡侧配置

#### Mellanox OFED

```bash
# 查看当前 PFC 状态
$ mlnx_qos -d eth0

# 启用 Priority 3 的 PFC
$ mlnx_qos -i eth0 -p 3

# 完整配置脚本
#!/bin/bash
# roce_pfc_setup.sh

INTERFACE=eth0
PRIORITY=3

# 启用 DCBX
ethtool --set-dcbx ${INTERFACE} mode 2

# 设置 VLAN PCP → Priority 映射
# RoCE 使用 PCP=3
ethtool --set-vlan-prio-map ${INTERFACE} 3:${PRIORITY}

# 启用 PFC
ethtool --set-pfc ${INTERFACE} rx ${PRIORITY} on tx ${PRIORITY} on

# 验证
echo "PFC Configuration:"
ethtool --show-pfc ${INTERFACE}
```

#### Intel (irdma)

```bash
# 查看 DCB 状态
$ irdma_show dcbd eth0

# 启用 DCBX 自动协商
$ irdma_set dcbd -d eth0 -m auto

# 手动设置 PFC
$ irdma_set pfc -d eth0 -p 3 -e 1
```

### 5.3 内核 sysfs 配置

```bash
# 通过 sysfs 查看/配置 PFC
$ cat /sys/class/net/eth0/device/sriov/0/pfc_enable
0

# 启用 PFC (需要 root)
# echo 8 > /sys/class/net/eth0/device/sriov/0/pfc_enable
# 对所有 Priority (0-7) 启用

# 查看每个队列的 PFC 状态
$ cat /sys/class/net/eth0/queues/tx-3/tx_pfc_use
```

---

## 6. PFC 调优与故障排除

### 6.1 Pause Time 调优

Pause Time 过短会导致频繁 Pause/Resume，增加开销；过长会导致链路利用率下降：

```
Pause Time 优化原则：

  考虑因素：
    - 端口速率（100G/200G/400G）
    - 链路距离（光纤长度）
    - 交换机缓冲区大小
    - 期望的最大停顿时延

  计算公式：
    pause_time ≥ (2 × 链路单向延迟) × 端口速率 / 512

  示例：
    - 链路距离：100m（光纤约 500ns/米）
    - 单向延迟：50μs
    - 端口速率：100Gbps
    - 最小 pause_time = 2 × 50μs × erfps / 512
                     ≈ 100μs / 512bit_time
                     ≈ 0x2000
```

### 6.2 常见问题与解决

| 问题         | 原因                 | 解决方案                        |
| ------------ | -------------------- | ------------------------------- |
| PFC 不生效   | DCBX 协商失败        | 检查两端 DCBX 模式是否匹配      |
| 网络丢包     | PFC 未覆盖所有链路   | 确认所有交换机端口都启用了 PFC  |
| 链路利用率低 | Pause Time 过短      | 增加 pause_time 值              |
| Pause Storm  | PFC 过度触发         | 调整阈值或启用 ECN 替代部分 PFC |
| 死锁         | PFC 配置错误导致环路 | 正确配置 PFC + 检查 STP         |

### 6.3 验证 PFC 配置

```bash
# 1. 检查网卡是否支持 PFC
$ ethtool -i eth0 | grep -i "pfc\|dcb"
  supports-priv-flags: pfc-tokens
  ...

# 2. 验证交换机端配置
switch# show dcb pfc

# 3. 抓包验证 Pause 帧
$ tcpdump -i eth0 -c 10 'ether[20:2] == 0x8808'
  listening on eth0, link-type EN10MB
  15:30:01.234567 Pause (pid=3) 0x0C00
  15:30:01.245678 Pause (pid=3) 0x0800

# 4. 检查 Mellanox 计数器
$ show_pfc_counters
$ mstflint -d eth0 qos where

# 5. 端到端验证
$ ibv_rc_pingpong -d mlx5_0 -g 0
# 确保 UD/RC 流在启用 PFC 的 Priority 上传输
```

---

## 7. PFC 局限性

### 7.1 Pause Storm（反压风暴）

当多个交换机端口同时触发 PFC 时，可能形成反压环路：

```
Pause Storm 场景：

  Server A ──► Switch 1 ──► Switch 2 ──► Server B
                  ▲            │
                  │            ▼
                  └───── Pause ─┘

  问题：
    - Switch 1 收到 Server A 的流量过多 → 发 Pause
    - Switch 2 收到 Switch 1 的 Pause → 向上游发 Pause
    - 可能形成多跳反压链路
```

**解决方案**：限制 PFC 的跳数（Hop-to-hop），或使用 ECN + PFC 混合模式。

### 7.2 Head-of-Line Blocking

PFC 按 Priority 暂停时，同一队列后面的包会被阻塞：

```
HoL Blocking：

  Queue: [包A][包B][包C][包D] → 目标是不同目的地
                │
                ├──► 目标 1 缓冲区满
                │    → 对整个队列发 Pause
                │
                ├──► 包B、C、D 虽然目标是 2、3、4
                     但被包A 阻塞，无法发送
```

### 7.3 PFC 与 RoCE v2 的演进

随着 ECN（下一章内容）成熟，部分场景开始用 ECN 替代 PFC：

- ECN 是端到端的（而非逐跳）
- 不需要 Pause 帧，避免 Pause Storm
- 但 ECN 需要网络设备支持 ECN 标记

现代 RoCE 配置通常采用 **ECN + PFC** 混合模式：

- ECN 处理轻度拥塞（端到端）
- PFC 处理极端拥塞（最后手段）

---

## 8. 总结

```
PFC 关键要点：

  1. 作用：链路层基于优先级的反压，防止缓冲区溢出丢包
  2. 标准：IEEE 802.1Qbb，EtherType 0x8808，Opcode 0x0101
  3. 优先级：8 个 Priority，对应 802.1Q PCP 字段
  4. 配置：通常 Priority 3 用于 RoCE 流量
  5. 协商：DCBX（IEEE 802.1Qaz）自动协商两端配置
  6. 调优：pause_time 需要根据链路距离和速率计算
  7. 局限：Pause Storm、HoL Blocking，需要与 ECN 配合

  配置检查清单：
    □ 网卡和交换机都启用 DCBX
    □ RoCE 流量使用独立 Priority（如 Priority 3）
    □ 该 Priority 在所有交换机端口都启用 PFC
    □ Pause Time 足够覆盖链路往返延迟
    □ 验证 Pause 帧是否正常发送/接收
```

---

> [!info] 下章预告
> 第十七章将介绍 **ECN（Explicit Congestion Notification）**——IP 层的拥塞通知机制，与 PFC 协同实现 RoCE 无损网络。
