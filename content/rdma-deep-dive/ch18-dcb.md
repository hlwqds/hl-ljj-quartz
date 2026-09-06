---
title: "RDMA 第十八章：DCB 数据中心桥接——RDMA 网络的完整框架"
date: 2026-04-13
tags: [rdma, roce, dcb, data-center-bridging, ieee-802.1q, ets, pfc, dcqx, dcbx, qos, ethernet]
description: "详解 DCB（Data Center Bridging）框架：IEEE 802.1Q 系列标准（Qbg(Qsz)、Qaz(Qatz)、Qau、Qbb）、ETS 带宽分配、PFC 流控、DCBX 协商，以及完整的 RoCE DCB 配置架构。"
---

> [!abstract] 核心要点
> DCB（Data Center Bridging，IEEE 802.1Q）是专为数据中心 Ethernet 设计的一套标准框架，涵盖带宽分配（ETS）、流控（PFC）、拥塞管理（ECN）、参数协商（DCBX）。理解 DCB，才能理解 RoCE 为什么需要这些协同工作的机制。

---

## 1. DCB 概述

### 1.1 为什么需要 DCB

传统 Ethernet 是"尽力而为"的网络，无法满足 RDMA 对无损、低延迟的要求：

```
传统 Ethernet 的问题：

  ┌─────────────────────────────────────────────────────────────────────┐
  │                                                                       │
  │   问题 1: 丢包                                                        │
  │     - 交换机缓冲区满 → 丢包                                           │
  │     - RDMA 对丢包敏感（重传代价高）                                    │
  │     - 解决: PFC 流控                                                  │
  │                                                                       │
  │   问题 2: 带宽争用                                                    │
  │     - 多流量共享同一链路                                               │
  │     - RDMA 流量被"饿死"                                               │
  │     - 解决: ETS 带宽保障                                              │
  │                                                                       │
  │   问题 3: 配置复杂性                                                  │
  │     - 交换机、网卡需要一致配置                                         │
  │     - 手动配置容易出错                                                 │
  │     - 解决: DCBX 自动协商                                             │
  │                                                                       │
  └─────────────────────────────────────────────────────────────────────┘
```

### 1.2 DCB 标准族

DCB 不是单一标准，而是一组 IEEE 802.1 系列标准的集合：

```
DCB 标准架构：

  IEEE 802.1Q - 桥接（Bridge）标准
    │
    ├── IEEE 802.1Qbb - Priority Flow Control (PFC)
    │      基于 802.3 MAC Control 的优先级反压
    │
    ├── IEEE 802.1Qaz - Enhanced Transmission Selection (ETS)
    │      带宽分配和优先级分组
    │
    ├── IEEE 802.1Qau - Congestion Notification (CN)
    │      端到端拥塞通知（类似 ECN，但更复杂）
    │
    └── IEEE 802.1Qaz - DCBX (DCB Exchange)
          通过 LLDP 协商 DCB 参数
```

### 1.3 DCB 在 OSI 模型中的位置

```
DCB 位置：

  ┌─────────────────────────────────────────────────────────────────────┐
  │                     OSI Model                                       │
  ├─────────────────────────────────────────────────────────────────────┤
  │  Layer 7 │ Application                                                │
  │  Layer 6 │ Presentation                                               │
  │  Layer 5 │ Session                                                    │
  │  Layer 4 │ Transport (RDMA Verbs, TCP)                               │
  │  Layer 3 │ Network (IP)                       ◄── ECN/CNG (802.1Qau)│
  │  Layer 2 │ Data Link (Ethernet)              ◄── PFC (802.1Qbb)    │
  │          │                                    ◄── ETS (802.1Qaz)     │
  │          │                                    ◄── DCBX (802.1Qaz)    │
  │  Layer 1 │ Physical (10/25/40/100/200/400GbE)                       │
  └─────────────────────────────────────────────────────────────────────┘

  DCB 是 L2 机制增强：
    - 在标准 Ethernet 帧格式基础上
    - 通过 VLAN tag PCP 字段标记优先级
    - 通过 MAC Control 帧传输 PFC
```

---

## 2. ETS（Enhanced Transmission Selection）

### 2.1 ETS 作用

ETS 解决带宽分配问题：如何保证关键流量获得必要的带宽？

```
ETS vs 严格优先级：

  严格优先级的问题：
    - Priority 7 流量永远优先
    - 可能"饿死"低优先级流量
    - 带宽无法保障

  ETS 方案：
    - 将 Priority 分组为 Traffic Class (TC)
    - 每个 TC 有最小带宽保证
    - 剩余带宽按比例分享
```

### 2.2 ETS 架构

```
ETS 架构：

  Priority 0 ──┐
  Priority 1 ──┤
  Priority 2 ──┼──► TC 0 ──► 带宽: 50% (保证)
  Priority 3 ──┤             (RoCE 流量)
  ──────────────┤
  Priority 4 ──┼──► TC 1 ──► 带宽: 30% (保证)
  ──────────────┤             (存储流量)
  Priority 5 ──┼──► TC 2 ──► 带宽: 20% (保证)
  Priority 6 ──┤             (其他)
  Priority 7 ──┘

  当某 TC 空闲时：
    剩余带宽按各 TC 权重分配
```

### 2.3 ETS 配置参数

```
ETS TLV 参数：

  ┌───────────────────────────────────────────────────────────────────────┐
  │  ETS Configuration TLV                                                │
  ├───────────────────────────────────────────────────────────────────────┤
  │  Willing: 1 bit (是否愿意接受其他设备的配置)                            │
  │  CBS: 1 bit (Credit-Based Shaper, 未来扩展)                            │
  │  Reseved: 6 bits                                                      │
  ├───────────────────────────────────────────────────────────────────────┤
  │  CBS (Credit-Based Shaper): 8 bits per TC (0=not supported)            │
  ├───────────────────────────────────────────────────────────────────────┤
  │  TC_Bandwidth: 8 × 8 bits                                             │
  │    每个 TC 的带宽百分比 (0-100%)                                       │
  ├───────────────────────────────────────────────────────────────────────┤
  │  TSA (Traffic Selection Algorithm): 8 × 8 bits                       │
  │    00: Strict Priority                                                │
  │    01: Credit-Based Shaper (CBS)                                     │
  │    10: Enhanced Transmission Selection (ETS)                         │
  │    11: Reserved                                                       │
  └───────────────────────────────────────────────────────────────────────┘
```

### 2.4 ETS 配置示例

```bash
# Mellanox 交换机配置 ETS
switch # configure terminal
switch (config) # dcb ets
switch (config-dcb-ets)# enable
switch (config-dcb-ets)# priority-group 0 bandwidth 50 pg=0
switch (config-dcb-ets)# priority-group 1 bandwidth 30 pg=1
switch (config-dcb-ets)# priority-group 2 bandwidth 20 pg=2

# 设置 priority → group 映射
switch (config-dcb-ets)# priority-map 0,1,2,3→pg0
switch (config-dcb-ets)# priority-map 4,5→pg1
switch (config-dcb-ets)# priority-map 6,7→pg2

# ethtool 配置 ETS
$ ethtool --show-ethtool eth0
$ ethtool --set-ethtool eth0 speed 100000 duplex full autoneg on

# 查看带宽分配
$ ethtool --show-phy-tunable eth0 | grep -i bw
```

---

## 3. PFC 与 ETS 的协同

### 3.1 Priority → TC → PG 映射

RoCE 配置通常采用以下映射策略：

```
推荐 RoCE DCB 配置：

  ┌─────────────────────────────────────────────────────────────────────────┐
  │  Priority 0 → TC 0 → PG 0 → 带宽 10%  (Best Effort, 无 PFC)            │
  │  Priority 1 → TC 1 → PG 1 → 带宽 0%   (保留)                            │
  │  Priority 2 → TC 2 → PG 2 → 带宽 10%  (其他流量)                         │
  │  Priority 3 → TC 3 → PG 3 → 带宽 80%  (RoCE, 启用 PFC + ECN)           │
  │  Priority 4-7 → TC 4-7 → PG 4-7 → 带宽 0%  (保留)                       │
  └─────────────────────────────────────────────────────────────────────────┘

  关键点：
    - RoCE 使用 Priority 3 (PCP=3)
    - PG 3 启用 PFC 和 ECN
    - PG 3 分配 80% 带宽保证
    - PG 0 用于非 RDMA 流量
```

### 3.2 完整 DCB 配置流程

```
DCB 配置流程：

  1. 启用 DCB
  2. 配置 ETS (带宽分配)
  3. 配置 PFC (流控优先级)
  4. 配置 DCBX (协商)
  5. 验证配置
```

### 3.3 配置脚本

```bash
#!/bin/bash
# roce_dcb_setup.sh - Mellanox 网卡 DCB 配置

INTERFACE=eth0
ROCE_PRIO=3
ROCE_PG=3

echo "=== RoCE DCB Configuration ==="

# 1. 重置 DCB 配置
ethtool --set-dcb ${INTERFACE} off 2>/dev/null

# 2. 启用 DCB
echo "Enabling DCB..."
ethtool --set-dcb ${INTERFACE} forward on

# 3. 设置 Priority → PG 映射
# Priority 3 → PG 3
# 其他 Priority → PG 0
ethtool --set-prio-group ${INTERFACE} \
    prio2pg 0:0,1:0,2:0,3:${ROCE_PG},4:0,5:0,6:0,7:0

# 4. 设置 PG 带宽
# PG 3: 80%, PG 0: 20%
ethtool --set-prio-group ${INTERFACE} \
    pg-bw 0:20,3:80

# 5. 启用 PFC (仅 RoCE Priority)
ethtool --set-pfc ${INTERFACE} \
    rx ${ROCE_PRIO} on tx ${ROCE_PRIO} on

# 6. 启用 DCBX (自动协商)
ethtool --set-dcbx ${INTERFACE} mode 2  # IEEE 802.1Qaz

# 7. 验证
echo ""
echo "=== DCB Status ==="
ethtool --show-dcb ${INTERFACE}
ethtool --show-pfc ${INTERFACE}
ethtool --show-dcbx ${INTERFACE}

# 8. 保存配置
ethtool -s ${INTERFACE} save
```

---

## 4. DCBX 详解

### 4.1 DCBX 工作原理

DCBX 通过 LLDP（Link Layer Discovery Protocol）传输 DCB 参数：

```
DCBX 架构：

  ┌───────────────────────────────────────────────────────────────────────┐
  │                                                                        │
  │   Host NIC                                      Switch Port           │
  │   ┌─────────────────┐                        ┌─────────────────┐      │
  │   │    DCBX Agent   │◄──── LLDP (0x88CC) ──►│    DCBX Agent   │      │
  │   └────────┬────────┘                        └────────┬────────┘      │
  │            │                                             │              │
  │   ┌────────┴────────┐                        ┌────────┴────────┐      │
  │   │ ETS Config TLV   │                        │ ETS Config TLV  │      │
  │   │ PFC Config TLV   │                        │ PFC Config TLV  │      │
  │   │ APP TLV         │                        │ APP TLV         │      │
  │   └─────────────────┘                        └─────────────────┘      │
  │                                                                        │
  └───────────────────────────────────────────────────────────────────────┘

  DCBX 功能：
    - 发现对端 DCB 能力
    - 协商共同配置
    - 检测配置变化
```

### 4.2 DCBX TLV 类型

```
IEEE 802.1Qaz DCBX TLV：

  ┌─────────────────────────────────────────────────────────────────────────┐
  │  DCBX TLV Header (5 bytes)                                             │
  │  ┌──────────┬──────────┬──────────┬──────────┬──────────┐            │
  │  │ Type(7)  │ Reserved │    Length (12 bits)      │            │
  │  └──────────┴──────────┴──────────┴──────────┴──────────┘            │
  ├─────────────────────────────────────────────────────────────────────────┤
  │  Sub-TLVs:                                                             │
  │                                                                        │
  │  Type 0: End TLV (3 bytes)                                             │
  │                                                                        │
  │  Type 1: IEEE 802.1Qaz ETS Configuration TLV                           │
  │    - Willing, CBS, Max TCs                                            │
  │    - Priority Assignment Table (8 entries)                            │
  │    - TC Bandwidth Table (8 entries)                                   │
  │    - TSA Assignment Table (8 entries)                                 │
  │                                                                        │
  │  Type 2: IEEE 802.1Qaz ETS Recommendation TLV                         │
  │    - 对端推荐的 ETS 配置                                               │
  │                                                                        │
  │  Type 3: IEEE 802.1Qaz PFC Configuration TLV                           │
  │    - Willing, MBC, PFC Enable (8 bits)                                │
  │    - RFC 2474 没有 PFC 前缀                                            │
  │                                                                        │
  │  Type 4: APP TLV (Application Priority)                                │
  │    - 选择使用哪个 Priority                                              │
  │    - Protocol ID (0x8915 for RoCE v1, 0xFFFF for FCoE)                 │
  │                                                                        │
  └─────────────────────────────────────────────────────────────────────────┘
```

### 4.3 DCBX 协商模式

```
DCBX 协商行为：

  模式 1: Auto-Mode
    - 一方为 Willing，另一方为非 Willing
    - Willing 方接受对端配置
    - 典型: 网卡为 Willing，交换机为非 Willing

  模式 2: Manual-Mode
    - 双方都是非 Willing
    - 使用本地手动配置
    - 需要两端手动配置一致

  模式 3: CEE Mode (Legacy)
    - 使用 Cisco CEE 格式
    - 用于与传统设备兼容
```

### 4.4 APP TLV 与 RoCE

APP TLV 告诉对端哪个应用使用哪个 Priority：

```
APP TLV 结构：

  ┌─────────────────────────────────────────────────────────────────────────┐
  │  APP TLV                                                              │
  │  ┌──────────┬──────────────┬──────────────┬──────────────────────────┐  │
  │  │ Type=4   │    Length    │  Reserved    │    Selector (8 bits)   │  │
  │  ├──────────┴──────────────┴──────────────┴──────────────────────────┤  │
  │  │  Protocol ID (16 bits)                                            │  │
  │  ├───────────────────────────────────────────────────────────────────┤  │
  │  │  Priority Map (8 bits) - 哪些 Priority 使用此应用                 │  │
  │  └───────────────────────────────────────────────────────────────────┘  │
  │                                                                         │
  │  RoCE APP TLV:                                                         │
  │    - Selector: 2 (IEEE 802.1Q)                                        │
  │    - Protocol ID: 0x8915 (RoCE v1 Ethertype) 或 0xFFFF               │
  │    - Priority Map: bit3 = 1 (Priority 3)                             │
  │                                                                         │
  └─────────────────────────────────────────────────────────────────────────┘
```

### 4.5 DCBX 配置

```bash
# 查看 DCBX 状态
$ ethtool --show-dcbx eth0
  DCBX version: IEEE 802.1Qaz (auto)

# 设置 DCBX 模式
# mode: 0=auto, 1=CEE, 2=IEEE
$ ethtool --set-dcbx eth0 mode 2

# 交换机侧配置 DCBX
switch # configure terminal
switch (config) # dcbx version ieee
switch (config) # dcbx feature ETS enable
switch (config) # dcbx feature PFC enable
switch (config) # dcbx feature APP enable
switch (config) # dcbx willing on  # 允许接受对端配置

# 验证协商结果
$ ethtool --show-dcb eth0
```

---

## 5. 完整 DCB 配置方案

### 5.1 Mellanox 交换机完整配置

```bash
# Mellanix SX switch (Spectrum OS)

# 进入全局配置
switch # configure terminal

# 启用 DCB
switch (config) # dcb enable

# 配置 QoS profile (用于 RoCE)
switch (config) # qos profile roce
switch (config-qos-roce) # ets
switch (config-qos-roce) #   priority-group 0 bandwidth 10
switch (config-qos-roce) #   priority-group 1 bandwidth 90
switch (config-qos-roce) #   priority-group 0 priority-map 0,1,2
switch (config-qos-roce) #   priority-group 1 priority-map 3
switch (config-qos-roce) # pfc
switch (config-qos-roce) #   priority 3 enable
switch (config-qos-roce) # exit

# 应用到端口
switch (config) # interface 1/1-1/32
switch (config-if) # switchport mode trunk
switch (config-if) # switchport trunk allowed vlan all
switch (config-if) # qos profile roce
switch (config-if) # dcbx mode ieee
switch (config-if) # no shutdown

# 保存
switch (config) # write memory
```

### 5.2 Cisco Nexus 交换机配置

```bash
# Cisco Nexus 9000

# 启用 DCB 功能
switch# configure terminal
switch(config)# feature dcbxp
switch(config)# feature priority

# 创建 QoS policy
switch(config)# class-map type network-qos match-any roce
switch(config-cmap-nq)# match cos 3
switch(config-cmap-nq)# exit

# 配置 policy
switch(config)# policy-map type network-qos roce-policy
switch(config-pmap-nq)# class roce
switch(config-pmap-nq-c)# pause pfc-cos 3
switch(config-pmap-nq-c)# set cos 3
switch(config-pmap-nq-c)# exit
switch(config-pmap-nq)# class type network-qos class-default
switch(config-pmap-nq-c)# mls qos
switch(config-pmap-nq-c)# exit
switch(config-pmap-nq)# exit

# 配置 ETS
switch(config)# policy-map type qos roce-qos
switch(config-pmap-qos)# class roce
switch(config-pmap-qos-c)# set qos-group 3
switch(config-pmap-qos-c)# set dscp 3
switch(config-pmap-qos-c)# exit
switch(config-pmap-qos)# exit

# 应用到端口
switch(config)# interface Ethernet1/1-1/32
switch(config-if)# switchport mode trunk
switch(config-if)# spanning-tree bpdufilter enable
switch(config-if)# service-policy type network-qos input roce-policy
switch(config-if)# service-policy type qos input roce-qos
switch(config-if)# dcbx mode ieee
```

### 5.3 Broadcom 交换机配置

```bash
# Broadcom DNOS (Dell, etc.)

# 启用 DCB
switch# configure
switch(config)# dcb enable

# 配置 ETS
switch(config)# dcb ets
switch(config-dcb-ets)# priority-group 0 bandwidth 10
switch(config-dcb-ets)# priority-group 1 bandwidth 90
switch(config-dcb-ets)# priority 0-2 group 0
switch(config-dcb-ets)# priority 3 group 1
switch(config-dcb-ets)# priority 4-7 group 0
switch(config-dcb-ets)# exit

# 配置 PFC
switch(config)# dcb pfc
switch(config-dcb-pfc)# priority 3 enable
switch(config-dcb-pfc)# exit

# 启用 DCBX
switch(config)# dcbx enable
switch(config)# dcbx mode ieee

# 应用到端口
switch(config)# interface 1/1
switch(config-if)# dcbx enable
switch(config-if)# dcbx ieee enable
```

### 5.4 端到端验证

```bash
# 1. 验证网卡 DCB 状态
$ dcbtool show dcbd eth0
$ ethtool --show-dcb eth0

# 2. 验证交换机端口
switch# show dcb

# 3. 抓包验证 VLAN PCP
$ tcpdump -i eth0 -e -c 10 'vlan'
  0x8100, vlan 100, ptype 0x8915, prio 3

# 4. 验证 PFC Pause 帧
$ tcpdump -i eth0 -enn 'ether[20:2] == 0x8808'

# 5. 端到端 RDMA 测试
$ perftest -d mlx5_0 -z -F ecn
$ ibv_rc_pingpong -d mlx5_0 -g 0
```

---

## 6. DCB 故障排除

### 6.1 常见问题

| 问题          | 原因                      | 解决方案                   |
| ------------- | ------------------------- | -------------------------- |
| DCBX 协商失败 | 模式不匹配（CEE vs IEEE） | 统一为 IEEE 802.1Qaz       |
| PFC 不生效    | DCBX 未协商成功           | 检查 LLDP 是否启用         |
| 带宽分配无效  | ETS 配置不一致            | 两端 ETS 配置必须匹配      |
| RoCE 丢包     | PFC 未覆盖所有链路        | 确认所有交换机端口启用 PFC |
| Pause Storm   | 多跳 PFC 配置不当         | 限制 PFC 范围，配合 ECN    |

### 6.2 调试命令

```bash
# 1. 检查 LLDP 是否工作
$ lldpctl show
$ lldptool -t -i eth0 -V IEEE8021QAZ

# 2. 查看 DCBX 收到的 TLV
$ dcbtool get dcbx-app eth0
$ dcbtool get dcbx-pfc eth0
$ dcbtool get dcbx-ets eth0

# 3. 检查 ECN/PFC 统计
$ ethtool -S eth0 | grep -E "pfc|ecn|pause"

# 4. Mellanox 诊断
$ mlnx_qos -d eth0          # 显示 DCB 配置
$ mlnx_qos -f eth0          # 显示流分类
$ mstflint -d eth0 qos show # 显示 QoS 状态

# 5. 交换机端调试
switch# show dcbx
switch# show dcb pfc
switch# show dcb ets
switch# show interface queue
switch# show mac address-table | include RoCE
```

### 6.3 DCB 与 RoCE 性能调优

```
DCB 调优参数：

  1. PFC 阈值
    - rx-pfc-priority-threshold: 接收缓冲区阈值
    - tx-pfc-priority-threshold: 发送缓冲区阈值
    - 建议: 根据链路速率和距离调整

  2. ECN 阈值
    - ecn-min-threshold: 开始 ECN 标记
    - ecn-max-threshold: 强制 CE 标记
    - 建议: Min=20%, Max=80% 缓冲区

  3. ETS 带宽
    - RoCE PG 带宽 ≥ 实际使用带宽
    - 留有余量应对突发

  4. CNP 参数
    - cnp_dscp: CNP 的 DSCP 值
    - cnp_timeout: CNP 超时
```

---

## 7. DCB 标准演进

### 7.1 IEEE 802.1Qau 拥塞通知

IEEE 802.1Qau 定义了另一种拥塞通知机制，与 ECN 类似但更复杂：

```
802.1Qau vs ECN：

  ┌─────────────────────────────────────────────────────────────────────────┐
  │  802.1Qau (CN)                                                        │
  │    - 端到端拥塞通知                                                    │
  │    - 支持量化反馈 (Quantized Feedback)                                 │
  │    - 可与 ECN 共存                                                      │
  │    - 尚未广泛部署                                                      │
  ├─────────────────────────────────────────────────────────────────────────┤
  │  ECN (RFC 3168)                                                        │
  │    - IP 层标记                                                         │
  │    - RoCE v2 使用                                                     │
  │    - 已广泛部署                                                        │
  └─────────────────────────────────────────────────────────────────────────┘
```

### 7.2 未来趋势：PFC-free RoCE

随着网络设备对 ECN 支持越来越好，部分厂商开始探索 **PFC-free RoCE**：

```
PFC-free RoCE 方案：

  - 纯 ECN 拥塞控制
  - 避免 PFC 的 Pause Storm 问题
  - 需要：
    1. 交换机精确 ECN 标记
    2. 端到端 ECN 支持
    3. 快速收敛的拥塞算法

  当前限制：
    - 极端拥塞（incast）时仍需 PFC
    - 兼容性考虑
    - 实际部署仍以 PFC+ECN 为主
```

---

## 8. 总结

```
DCB 关键要点：

  1. DCB 是一组 IEEE 802.1Q 标准，构成为 RoCE 提供无损 Ethernet 的基础
  2. 核心组件：
     - ETS (802.1Qaz): 带宽分配和优先级分组
     - PFC (802.1Qbb): 基于优先级的链路层流控
     - DCBX (802.1Qaz): 参数自动协商
     - ECN/CN: 拥塞通知
  3. RoCE 典型配置：
     - Priority 3 用于 RoCE
     - 启用 PFC + ECN
     - 80%+ 带宽分配给 RoCE
  4. DCBX 协商两端 DCB 参数，保证一致性
  5. 未来趋势：PFC-free RoCE，但短期内 PFC+ECN 仍是主流

  配置检查清单：
    □ 交换机和网卡都启用 DCB
    □ ETS 配置一致（带宽分配）
    □ RoCE 流量 Priority 启用 PFC
    □ DCBX 协商成功
    □ ECN 阈值合理配置
    □ 端到端配置验证通过
```

---

> [!info] 下章预告
> 第十九章将介绍 **RDMA 配置工具**——perftest、ibstat、ibdevinfo、rping、ucmatose 等常用工具的使用方法和场景。
