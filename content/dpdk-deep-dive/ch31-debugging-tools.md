---
title: "DPDK 深度探索 (三十一)：调试工具——dpdk-devbind、ethtool"
date: 2026-04-09
tags: [dpdk, series, debugging, devbind, ethtool, pci, uio, vfio, network-driver, binding]
description: "深入理解 DPDK 调试工具——dpdk-devbind 设备绑定、ethtool 查看配置、PCI 设备管理、UIO/VFIO 驱动绑定、网络设备状态查看"
---

> [!info] DPDK 深度探索系列 0. [[dpdk-deep-dive|全栈学习路径总览]]
> 1-30. 前三十章已完成 31. **第三十一章：调试工具——dpdk-devbind、ethtool**

---

## 1. 概述：DPDK 调试工具生态

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        DPDK 调试工具生态                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  工具分类:                                                                │
│  ────────                                                                  │
│                                                                             │
│  1. 设备管理                                                               │
│     - dpdk-devbind.py      : 绑定/解绑 NIC 到不同驱动                     │
│     - lspci                  : 查看 PCI 设备                               │
│     - lsmod                  : 查看已加载内核模块                           │
│                                                                             │
│  2. 网络配置                                                               │
│     - ethtool                : NIC 配置、统计、offload 控制                 │
│     - ip/link                : 网络接口管理                                │
│     - ifconfig               : 接口配置 (legacy)                           │
│                                                                             │
│  3. DPDK 内部调试                                                          │
│     - rte_log                : 日志系统                                    │
│     - rte_trace              : 轻量级 trace                                │
│     - dpdk-proc-info         : 运行时统计查看                              │
│     - dpdk-telemetry         : JSON 格式运行时监控                         │
│     - dpdk-dumpcap           : 抓包 (推荐)                                │
│     - dpdk-pdump             : 抓包 (旧版)                                 │
│                                                                             │
│  4. 内核诊断                                                               │
│     - dmesg                   : 内核消息                                    │
│     - /proc/interrupts       : 中断分布                                    │
│     - /proc/softirqs         : 软中断统计                                  │
│     - /proc/net/stat/*       : 网络统计                                    │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. dpdk-devbind

### 2.1 工具概述

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        dpdk-devbind 工具                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  dpdk-devbind 是 DPDK 提供的设备绑定管理脚本                               │
│  ─────────────────────────────────────────────                              │
│                                                                             │
│  位置:                                                                    │
│  - $RTE_SDK/usertools/dpdk-devbind.py                                      │
│  - 或: dpdk-devbind --help                                                 │
│                                                                             │
│  核心功能:                                                                 │
│  - 查看 PCI 设备及其当前驱动                                               │
│  - 绑定设备到指定驱动 (UIO/VFIO)                                          │
│  - 解绑设备 (恢复到内核驱动)                                               │
│  - 查询设备状态                                                            │
│                                                                             │
│  支持驱动:                                                                 │
│  - igb_uio (传统 UIO + MSI)                                               │
│  - uio_pci_generic (内核 generic UIO)                                      │
│  - vfio-pci (现代 VFIO, 支持 IOMMU)                                       │
│  - 网络驱动: igb, ixgbe, i40e, mlx5, etc.                                │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 2.2 基本用法

```bash
# 查看帮助
dpdk-devbind --help

# 查看所有 PCI 设备状态
dpdk-devbind --status

# 输出示例:
# Network devices using DPDK-compatible driver
# ============================================
# 0000:82:00.0 'Ethernet 10G 2P X520' drv=igb_uio unused=ixgbe,vfio-pci
# 0000:82:00.1 'Ethernet 10G 2P X520' drv=igb_uio unused=ixgbe,vfio-pci

# Network devices using kernel driver
# =======================================
# 0000:04:00.0 'Ethernet I350' drv=igb unused=igb_uio,vfio-pci

# Other network devices
# ======================
# 0000:04:00.1 'Ethernet I350' drv=igb_uio unused=igb,vfio-pci

# 查看特定设备
dpdk-devbind --status 82:00.0

# 绑定到 VFIO-PCI (需要 IOMMU)
dpdk-devbind --bind=vfio-pci 82:00.0

# 绑定到 igb_uio
dpdk-devbind --bind=igb_uio 82:00.1

# 解绑设备 (恢复到内核驱动)
dpdk-devbind --bind=ixgbe 82:00.0

# 同时绑定多个设备
dpdk-devbind --bind=vfio-pci 82:00.0 82:00.1

# 强制绑定 (即使设备被占用)
dpdk-devbind --force 82:00.0
```

### 2.3 设备状态详解

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        PCI 设备状态解析                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  状态字段:                                                                 │
│  ────────                                                                  │
│                                                                             │
│  drv=<driver>        : 当前绑定的驱动                                       │
│  unused=<drivers>    : 可用但未使用的驱动列表                               │
│  unused=vfio-pci    : 支持 VFIO 但未绑定                                   │
│  unused=igb_uio     : 支持 igb_uio 但未绑定                                │
│                                                                             │
│  ─────────────────────────────────────────────────────────────────────────  │
│                                                                             │
│  查看详细 PCI 信息:                                                        │
│  ──────────────────                                                        │
│                                                                             │
│  lspci -vvv -s 82:00.0    # 详细 PCI 配置                                  │
│  lspci -xxx -s 82:00.0    # PCIe config space (原始)                       │
│  lspci -t                 # PCI 树拓扑                                      │
│                                                                             │
│  lspci -vvv -s 82:00.0 输出示例:                                           │
│  ────────────────────────────────────────                                   │
│  82:00.0 Ethernet controller: Intel ...                                    │
│      Subsystem: Intel ...                                                  │
│      Flags: bus master, fast devsel, latency 0, IRQ 16                     │
│      Memory at ... (prefetchable)                                          │
│      I/O ports at ...                                                      │
│      Capabilities: [a0] Express Endpoint                                   │
│                                                                             │
│  ─────────────────────────────────────────────────────────────────────────  │
│                                                                             │
│  查看设备驱动详情:                                                         │
│  ──────────────────                                                        │
│                                                                             │
│  ls /sys/bus/pci/drivers/igb_uio/    # igb_uio 已绑定设备                  │
│  ls /sys/bus/pci/drivers/vfio-pci/   # VFIO 已绑定设备                     │
│  cat /sys/bus/pci/devices/82:00.0/vendor    # vendor ID                    │
│  cat /sys/bus/pci/devices/82:00.0/device    # device ID                    │
│  cat /sys/bus/pci/devices/82:00.0/driver/unbind  # 解绑设备                │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 2.4 驱动绑定流程

```bash
# 完整绑定流程

# Step 1: 检查系统环境
cat /proc/cmdline | grep -i iommu    # 检查 IOMMU
dmesg | grep -i iommu                # 内核日志
cat /sys/class/iommu/group0/         # IOMMU 组

# Step 2: 加载驱动
# 传统方式 (无 IOMMU)
modprobe uio
modprobe igb_uio

# 现代方式 (VFIO, 推荐)
modprobe vfio
modprobe vfio-pci

# 如果需要启用 no-IOMMU 模式 (不安全)
echo 1 > /sys/module/vfio/parameters/enable_unsafe_noiommu_mode

# Step 3: 检查驱动是否加载
lsmod | grep -E "uio|igb_uio|vfio"

# Step 4: 绑定设备
# 检查当前状态
dpdk-devbind --status

# 绑定到 VFIO (推荐)
dpdk-devbind --bind=vfio-pci 82:00.0

# 如果 VFIO 失败，回退到 igb_uio
dpdk-devbind --bind=igb_uio 82:00.0

# Step 5: 验证绑定
dpdk-devbind --status
cat /sys/bus/pci/drivers/igb_uio/82:00.0  # 确认存在

# Step 6: 测试 DPDK 应用
./build/app/testpmd -l 0-3 -n 4 -- -i

# 如需解绑恢复内核驱动
dpdk-devbind --bind=ixgbe 82:00.0
```

### 2.5 VFIO vs igb_uio：选哪个

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     VFIO vs igb_uio 对比                                    │
├──────────────────┬──────────────────────────┬──────────────────────────────┤
│                  │  VFIO (vfio-pci)          │  igb_uio                     │
├──────────────────┼──────────────────────────┼──────────────────────────────┤
│ IOMMU 隔离       │ 支持，DMA 受 IOMMU 保护   │ 无隔离                       │
│ 安全性           │ 高                        │ 低                           │
│ 性能             │ 略低于 igb_uio            │ 略高 (无 IOMMU 开销)         │
│ 内核主线         │ 是                        │ 否 (out-of-tree)             │
│ VF 支持          │ SR-IOV VF 需要 VFIO       │ 不支持 VF                    │
│ 设备热迁移       │ 支持                      │ 不支持                       │
│ 推荐度           │ ★★★ 生产首选              │ ★★ 开发/测试可用             │
├──────────────────┴──────────────────────────┴──────────────────────────────┤
│                                                                             │
│  实际选择:                                                                  │
│  - 生产环境: VFIO + IOMMU (安全性和可维护性更重要)                          │
│  - 性能测试: 如果差 1-2% 对你很重要，可以对比 igb_uio                      │
│  - 虚拟化: 必须用 VFIO (SR-IOV / PCI passthrough)                         │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 2.6 IOMMU group 冲突排查

VFIO 绑定时，同一个 IOMMU group 里的所有设备必须同时绑定到 VFIO，否则会失败。

```bash
# 查看 IOMMU group
ls /sys/kernel/iommu_groups/

# 查看某个 group 里的设备
ls /sys/kernel/iommu_groups/1/devices/

# 查看网卡的 IOMMU group
readlink /sys/bus/pci/devices/82:00.0/iommu_group
# 输出: ../../kernel/iommu_groups/42

# 常见错误:
# "vfio_pci: group N is not viable"
# → 这个 group 里有其他设备还没绑定到 VFIO

# 解决:
# 1. 把同 group 的设备都绑到 VFIO
# 2. 或在 GRUB 加 iommu=pt (pass-through) 减少共享 group
# 3. 有些服务器 BIOS 可以调整 ACS 设置来拆分 group
```

### 2.7 常见问题排查

```bash
# 问题 1: VFIO 绑定失败
# ========================================
# 错误: "vfio_pci: Unable to open..."

# 原因: IOMMU 未启用或权限问题

# 解决:
dmesg | grep -E "DMAR|IOMMU"     # 检查 IOMMU 状态
cat /proc/cpuinfo | grep -i vmx  # 检查 VT-d

# 如果 IOMMU 问题，可以临时使用 no-IOMMU 模式
echo "options vfio enable_unsafe_noiommu_mode=1" >> /etc/modprobe.d/vfio.conf
modprobe -r vfio-pci vfio
modprobe vfio enable_unsafe_noiommu_mode=1

# 权限问题
ls -la /dev/vfio/               # 检查 /dev/vfio 权限
chown root:dpdk /dev/vfio/*     # 放入 dpdk 启动脚本

# ========================================
# 问题 2: 设备被内核驱动占用
# ========================================
# 错误: "Cannot bind to driver igb_uio: resource busy"

# 查看占用驱动
lsof /sys/bus/pci/devices/82:00.0/driver

# 解绑前先关闭网络接口
ip link set eth0 down

# 强制解绑
echo "82:00.0" > /sys/bus/pci/drivers/igb/unbind
dpdk-devbind --bind=igb_uio 82:00.0

# ========================================
# 问题 3: 驱动不兼容
# ========================================
# 错误: "No supported device found"

# 检查 NIC 型号是否被 DPDK 支持
lspci | grep -i ethernet
# i40e: Intel X710/XL710 (支持)
# ixgbe: Intel X520/X550 (支持)
# mlx5: Mellanox ConnectX (支持)
# ena: AWS ENA (支持)

# 检查 DPDK 版本支持的 NIC
grep -r "PCI_IDS" $RTE_SDK/drivers/net/*/mac*.c | head -20
```

---

## 3. ethtool

### 3.1 工具概述

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        ethtool 工具                                        │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ethtool 是 Linux 内核提供的 NIC 配置工具                                 │
│  ─────────────────────────────────────────                                  │
│                                                                             │
│  功能:                                                                    │
│  - 查看/设置 NIC 驱动参数                                                  │
│  - 查看/设置 offload 特性                                                  │
│  - 查看/设置 ring buffer 大小                                              │
│  - 查看/设置中断合并                                                        │
│  - 查看统计信息                                                             │
│  - 查看/设置 speed/duplex                                                  │
│  - 启动/停止网卡                                                            │
│                                                                             │
│  注意:                                                                    │
│  - DPDK 占用的 NIC 无法使用 ethtool (除非 DPDK 支持 telemetry)            │
│  - 需要先解绑 DPDK 才能用 ethtool 管理                                    │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 3.2 基本查看

```bash
# 查看 NIC 基本信息
ethtool eth0

# 输出示例:
# Settings for eth0:
#     Supported ports: [ TP ]
#     Supported link modes:   1000baseT/Full
#                             10000baseT/Full
#     Supported pause frame use: Symmetric
#     Supported FEC modes: Not reported
#     Advertised link modes:  1000baseT/Full
#                             10000baseT/Full
#     Advertised pause frame use: Symmetric
#     Advertised FEC modes: Not reported
#     Speed: 10000Mb/s
#     Duplex: Full
#     Port: Twisted Pair
#     PHYAD: 0
#     Transceiver: internal
#     Auto-negotiation: on
#     MDI-X: Unknown
#     Supports Wake-on: d
#     Wake-on: d
#     Current message level: 0x00000007 (7)
#     Link detected: yes

# 查看驱动信息
ethtool -i eth0

# 输出:
# driver: ixgbe
# version: 5.1.0-k
# firmware-version: 0x8000099d
# expansion-rom-version:
# bus-info: 0000:04:00.0
# supports-statistics: yes
# supports-test: yes
# supports-eeprom-access: yes
# supports-register-dump: yes
# supports-priv-flags: yes

# 查看 pause frame 配置
ethtool -a eth0

# 查看 offload 特性
ethtool -k eth0

# 输出:
# features for eth0:
# rx-checksumming: off [fixed]
# tx-checksumming: off
# tx-checksum-ipv4: off
# tx-checksum-ipv6: off
# tx-checksum-sctp: off
# scatter-gather: off
# tcp-segmentation-offload: off
# udp-fragmentation-offload: off
# generic-segmentation-offload: off
# generic-receive-offload: off
# large-receive-offload: off
# rx-vlan-offload: off
# tx-vlan-offload: off
# rx-vlan-filter: off
# rx-vlan-stag-filter: off
# rx-vlan-stag-hw-parse: off
# tx-vlan-stag-hw-parse: off
# ntuple-filters: off
# receive-hashing: off
# tx-nocache-copy: off
# loopback: off

# 查看 ring buffer
ethtool -g eth0

# 输出:
# Ring parameters for eth0:
# Pre-set maximums:
# RX: 4096
# RX Mini: 0
# RX Jumbo: 0
# TX: 4096
# Current hardware settings:
# RX: 512
# RX Mini: 0
# RX Jumbo: 0
# TX: 512

# 查看 interrupt coalescing
ethtool -c eth0

# 输出:
# Coalesce parameters for eth0:
# rx-usecs: 0
# rx-frames: 0
# tx-usecs: 0
# tx-frames: 0
# rx-usecs-irq: 0
# rx-frames-irq: 0
# tx-usecs-irq: 0
# tx-frames-irq: 0
# stats-block-usecs: 0
# adaptive-rx: off
# adaptive-tx: off
# sample-interval: 0
# pkt-rate-low: 0
# rx-usecs-low: 0
# rx-frames-low: 0
# tx-usecs-low: 0
# tx-frames-low: 0
# pkt-rate-high: 0
# rx-usecs-high: 0
# rx-frames-high: 0
# tx-usecs-high: 0
# tx-frames-high: 0
```

### 3.3 配置设置

```bash
# 设置 Speed/Duplex
ethtool -s eth0 speed 10000 duplex full autoneg off

# 启用 Flow Control
ethtool -A eth0 rx on tx on

# 设置 Ring Buffer 大小
ethtool -G eth0 rx 2048 tx 2048

# 设置 interrupt coalescing (降低延迟)
ethtool -C eth0 rx-usecs 0 tx-usecs 0

# 设置 interrupt coalescing (提高吞吐)
ethtool -C eth0 rx-usecs 100 tx-usecs 100

# 启用 adaptive RX/TX coalescing (自动调整)
ethtool -C eth0 adaptive-rx on adaptive-tx on

# 关闭所有 offload (DPDK 场景通常这样做)
ethtool -K eth0 gro off gso off tso off ufo off

# 启用特定 offload
ethtool -K eth0 tx-checksum-ipv4 on tx-checksum-ipv6 on

# 查看 Wake-on-LAN
ethtool eth0 | grep Wake

# 设置 WoL (唤醒网络)
ethtool -s eth0 wol g   # 启用 magic packet wake

# 开启端口
ip link set eth0 up

# 关闭端口
ip link set eth0 down
```

### 3.4 统计信息

```bash
# 查看详细统计
ethtool -S eth0

# 输出示例:
# stats for eth0:
#     tx_packets: 1234567890
#     rx_packets: 9876543210
#     tx_bytes:   12345678901234
#     rx_bytes:   98765432109876
#     tx_packets: 0
#     rx_crc_errors: 0
#     rx_fifo_errors: 0
#     rx_missed_errors: 0
#     tx_aborted_errors: 0
#     tx_carrier_errors: 0
#     tx_fifo_errors: 0
#     tx_heartbeat_errors: 0
#     tx_window_errors: 0
#     rx_length_errors: 0
#     rx_over_errors: 0
#     rx_frame_errors: 0
#     rx_primed: 0
#     rx_dropped: 0
#     tx_dropped: 0

# 对比两次统计 (计算增量)
# 第一次
ethtool -S eth0 > /tmp/stats1.txt
sleep 10
# 第二次
ethtool -S eth0 > /tmp/stats2.txt
# 对比
diff /tmp/stats1.txt /tmp/stats2.txt

# 查看端口统计 (简单)
ip -s link show eth0

# 查看详细网络统计
netstat -i
cat /proc/net/dev
cat /proc/net/snmp
```

---

## 4. lspci 与 PCI 诊断

### 4.1 lspci 基础

```bash
# 查看所有 PCI 设备
lspci

# 查看网络设备 (详细)
lspci | grep -i ethernet

# 查看设备详情
lspci -vvv -s 82:00.0

# -v: verbose
# -vv: very verbose
# -vvv: very very verbose (最大详情)
# -s <addr>: 只显示指定设备
# -d <vendor:device>: 只显示指定 vendor/device

# 查看 PCIe 特定信息
lspci -xxx -s 82:00.0  # 原始 config space

# 查看 PCI tree
lspci -t

# 输出:
# -[0000:00]-+-00.0
#            +-01.0-[04]----00.0-[05]----00.0
#            ...
#            \-82.0-[82]----00.0
#                         \-00.1

# 查看设备能力
lspci -v -s 82:00.0 | grep -i capability

# 输出:
# Capabilities: [a0] Express Endpoint
# Capabilities: [a4] Subsystem Device
# Capabilities: [bc8] Resizable BAR
```

### 4.2 PCI 调试

```bash
# 检查 PCI 设备存在
lspci -s 82:00.0 -d

# 查看 PCI 配置空间 (工具)
setpci -s 82:00.0 COMMAND.l      # 读取 Command register
setpci -s 82:00.0 STATUS.l       # 读取 Status register
setpci -s 82:00.0 4.W            # 读取某个 word

# 修改 PCI 配置 (危险! 可能导致设备不可用)
# 除非你完全理解 PCI 配置空间，否则不要执行下面的命令
setpci -s 82:00.0 COMMAND.l=0x7 # 启用 memory, I/O, bus master

# 查看 BAR (Base Address Register)
lspci -v -s 82:00.0 | grep -i bar

# 输出:
# Memory at fbe00000 (64-bit, prefetchable) [size=16M]
# Memory at fb800000 (64-bit, prefetchable) [size=4M]
# I/O ports at e000 [size=32]

# 直接访问 BAR
cat /sys/bus/pci/devices/82:00.0/resource0    # BAR0
cat /sys/bus/pci/devices/82:00.0/resource2    # BAR2

# 查看 MSI/MSI-X 中断
lspci -v -s 82:00.0 | grep -i message

# 输出:
# Capabilities: [70] MSI-X: Enable+ Count=64 Masked-
# IRQ: 16
# Flags: +;

# 查看链路状态
cat /sys/bus/pci/devices/82:00.0/link_state
lspci -vvv -s 82:00.0 | grep -i width

# 输出:
# LnkSta: Speed 8GT/s, Width x8, TrErr- ...
# LnkCtl: ...
```

---

## 5. 其他调试工具

### 5.1 内核中断诊断

DPDK 数据面是轮询模式，收发包不产生中断。**但查看 `/proc/interrupts` 仍然有意义：目的是确认无关中断没有落在 DPDK 数据面核心上。**

```
DPDK 用 lcore 2-7 跑数据面:

CPU 0,1: 管理核心，承载内核中断、ssh、系统服务
CPU 2-7: DPDK 数据面，干净无中断

如果 /proc/interrupts 显示 CPU2-7 上有中断:
  → 这些中断会打断 DPDK 轮询循环
  → 刷 cache、破坏流水线
  → 造成延迟抖动
  → 需要把它们赶到 CPU 0,1
```

```bash
# 查看中断分布，关注 DPDK 核心上是否有无关中断
# 假设 DPDK 用 CPU 2-7
cat /proc/interrupts | head -1
#            CPU0  CPU1  CPU2  CPU3  CPU4  CPU5  CPU6  CPU7

# 查看是否有中断落在 DPDK 核心
cat /proc/interrupts | awk 'NR==1 || ($3+$4+$5+$6+$7+$8) > 0 {print}'

# 把 DPDK 核心的中断全部赶到管理核心
for irq in $(cut -f1 -d: /proc/interrupts | tr -d ' '); do
    echo "3" > /proc/irq/$irq/smp_affinity 2>/dev/null
    # 3 = 0b11 = CPU 0 和 CPU 1
done

# 更好的做法: 在 GRUB 里一次性配置
# irqaffinity=0,1  把所有默认中断绑定到 CPU 0,1
# isolcpus=2-15    把 CPU 2-15 从内核调度器隔离
# nohz_full=2-15   减少时钟中断
# rcu_nocbs=2-15   RCU 回调迁移到其他核

# 查看 softirqs (确认 NET_RX/NET_TX 不在 DPDK 核心上)
cat /proc/softirqs

# 查看网络统计
cat /proc/net/snmp

# 查看网络接口错误
ip -s link show eth0
ip -s -s link show eth0  # 更详细

# 查看路由表
ip route show
route -n

# 查看 ARP 表
ip neigh show
arp -an

# 查看 conntrack 表 (NAT/防火墙状态)
cat /proc/net/nf_conntrack | head
conntrack -L  # 需要 conntrack-tools
```

### 5.2 DPDK 日志系统 (rte_log)

```c
// 头文件
#include <rte_log.h>

// 日志级别 (从高到低):
// RTE_LOG_EMERG   (1)  紧急
// RTE_LOG_ALERT   (2)  警报
// RTE_LOG_CRIT    (3)  严重
// RTE_LOG_ERR     (4)  错误
// RTE_LOG_WARNING (5)  警告
// RTE_LOG_NOTICE  (6)  通知
// RTE_LOG_INFO    (7)  信息
// RTE_LOG_DEBUG   (8)  调试

// ──────────────────────────────────────
// 设置日志级别
// ──────────────────────────────────────

// 全局日志级别
rte_log_set_global_level(RTE_LOG_INFO);

// 按模块设置 (EAL 选项或代码)
rte_log_set_level(RTE_LOGTYPE_EAL, RTE_LOG_INFO);

// 运行时通过 EAL 参数控制:
// --log-level=lib.eal:info
// --log-level=pmd.net.mlx5:debug
// --log-level=user1:debug

// ──────────────────────────────────────
// 动态注册日志类型
// ──────────────────────────────────────

// 在应用中注册自己的日志类型
RTE_LOG_REGISTER_DEFAULT(my_app_logtype, RTE_LOG_INFO);

// 使用:
RTE_LOG(INFO, MY_APP, "Initializing port %u\n", port_id);
RTE_LOG(ERR, MY_APP, "Failed to allocate mbuf\n");
RTE_LOG(DEBUG, MY_APP, "packet len=%u on queue %u\n", m->pkt_len, q);

// PMD 的日志类型由驱动自己注册，通过 EAL 参数控制:
// --log-level=pmd.net.ixgbe:debug    // 只开 ixgbe PMD 的 debug
// --log-level=pmd.net.*:info         // 所有 PMD 用 info 级别
```

### 5.3 DPDK trace (20.11+)

DPDK trace 提供轻量级的 instrumentation，可以在不显著影响性能的情况下记录事件。

```c
#include <rte_trace_point.h>

// ──────────────────────────────────────
// 定义 trace point (通常在头文件中)
// ──────────────────────────────────────

// RTE_TRACE_POINT(名称, 参数列表, 字段emit)
RTE_TRACE_POINT(
    my_app_rx_burst,
    RTE_TRACE_POINT_ARGS(uint16_t port, uint16_t queue, uint16_t nb),
    rte_trace_point_emit_u16(port);
    rte_trace_point_emit_u16(queue);
    rte_trace_point_emit_u16(nb);
)

// ──────────────────────────────────────
// 注册 trace point (在 C 文件中)
// ──────────────────────────────────────

RTE_TRACE_POINT_REGISTER(my_app_rx_burst, "my_app.rx_burst")

// ──────────────────────────────────────
// 在代码中调用 (内联函数，零开销或极低开销)
// ──────────────────────────────────────

my_app_rx_burst(port_id, queue_id, nb_rx);

// ──────────────────────────────────────
// 启用和录制
// ──────────────────────────────────────

// EAL 参数:
// --trace=.*                    // 启用所有 trace point
// --trace=my_app.*              // 只启用 my_app 的
// --trace-dir=/tmp/trace        // 输出目录
```

### 5.4 dpdk-proc-info：运行时统计查看

`dpdk-proc-info` 以 secondary 进程方式连接到运行中的 DPDK 应用，读取统计信息。

```bash
# 查看端口基本统计
dpdk-proc-info -- -p 0x3

# 查看扩展统计 (xstats)
dpdk-proc-info -- -p 0x3 --xstats

# 只看特定前缀的 xstats
dpdk-proc-info -- -p 0x3 --xstats-name-prefix=rx_

# 查看 mempool 信息
dpdk-proc-info -- -p 0x3 --mempool

# 查看 RSS RETA
dpdk-proc-info -- -p 0x3 --rss-hash

# 导出 xstats 到文件 (定时采集)
dpdk-proc-info -- -p 0x3 --xstats --xstats-reset
```

在应用内获取 xstats：

```c
// 获取 xstats 名称和值
int nb_xstats = rte_eth_xstats_get(port_id, NULL, 0);
struct rte_eth_xstat *xstats = calloc(nb_xstats, sizeof(*xstats));
rte_eth_xstats_get(port_id, xstats, nb_xstats);

// 获取 xstat 名称
struct rte_eth_xstat_name *names = calloc(nb_xstats, sizeof(*names));
rte_eth_xstats_get_names(port_id, names, nb_xstats);

// 打印所有 xstats
for (int i = 0; i < nb_xstats; i++)
    printf("%s: %"PRIu64"\n", names[i].name, xstats[i].value);

// 按 ID 获取单个 xstat
uint64_t val;
rte_eth_xstats_get_by_id(port_id, &xstat_id, &val, 1);

// 重置 xstats
rte_eth_xstats_reset(port_id);
```

### 5.5 dpdk-telemetry：现代运行时监控

DPDK 21.11+ 引入了 telemetry 接口，通过 UNIX socket 提供 JSON 格式的运行时数据。比 `dpdk-proc-info` 更灵活。

```bash
# DPDK 应用需要启用 telemetry (默认启用)
# EAL 参数: --telemetry

# 使用 dpdk-telemetry 客户端
dpdk-telemetry

# 连接后可以执行命令:
--> /ethdev/list
{"status": "OK", "data": [0, 1]}

--> /ethdev/stats,0
{"status": "OK", "data": {"ipackets": 12345, "opackets": 67890, ...}}

--> /ethdev/xstats,0
{"status": "OK", "data": {"rx_good_packets": 12345, ...}}

--> /mempool/list
{"status": "OK", "data": ["mbuf_pool_socket0"]}

--> /mempool/stats,mbuf_pool_socket0
{"status": "OK", "data": {"avail": 7800, "in_use": 391, ...}}

# 也可以直接用 curl/socat
echo -e "/ethdev/stats,0\nquit" | socat - UNIX-CONNECT:/run/dpdk/rte/dpdk_telemetry.v2
```

### 5.6 pdump 和 dpdk-dumpcap 抓包

DPDK 提供两种抓包工具。`dpdk-dumpcap`（推荐）替代了旧的 `dpdk-pdump`。

```
架构:

Primary 进程 (你的 DPDK 应用)
    │
    │  调用 rte_pdump_init()  ← 必须显式调用
    │
    ├─ IPC socket
    │
    ▼
Secondary 进程 (dpdk-dumpcap / dpdk-pdump)
    │
    ├─ rte_pdump_enable() 请求抓包
    │   Primary 把 mbuf 复制到 ring
    │
    ▼
  写 pcap/pcapng 文件
```

```bash
# 1. Primary 进程必须初始化 pdump
# 在你的 DPDK 应用启动时调用:
rte_pdump_init(NULL);

# 或者用 testpmd (自带 pdump init):
dpdk-testpmd -l 0-3 -n 4 -- -i --port-topology=chained

# 2. 用 dpdk-dumpcap 抓包 (推荐)
dpdk-dumpcap -w /tmp/capture.pcapng

# 3. 用 tcpdump 分析
tcpdump -nr /tmp/capture.pcapng

# 旧的 dpdk-pdump (兼容)
dpdk-pdump -- --pdump 'port=0,queue=*,rx-dev=/tmp/rx.pcap,tx-dev=/tmp/tx.pcap'
```

应用内编程接口：

```c
#include <rte_pdump.h>

// 初始化 (primary 进程)
rte_pdump_init(NULL);

// 启用抓包 (secondary 进程)
struct rte_ring *ring = rte_ring_create("pdump_ring", 8192, socket, RING_F_SP_HK);
struct rte_mempool *mp = rte_pktmbuf_pool_create("pdump_mp", 8191, 250, 0,
        RTE_MBUF_DEFAULT_BUF_SIZE, socket);

// 抓 port 0 的 RX 和 TX
rte_pdump_enable(0, RTE_PDUMP_ALL_QUEUES,
                 RTE_PDUMP_FLAG_RXTX,
                 ring, mp, NULL);

// 从 ring 读取抓到的包
struct rte_mbuf *pkts[32];
uint16_t n = rte_ring_dequeue_burst(ring, (void **)pkts, 32, NULL);
for (uint16_t i = 0; i < n; i++) {
    // 处理 pkts[i]
    rte_pktmbuf_free(pkts[i]);
}

// 停止抓包
rte_pdump_disable(0, RTE_PDUMP_ALL_QUEUES, RTE_PDUMP_FLAG_RXTX);
```

注意：pdump 会复制 mbuf，**不适合在高性能数据面开启**，仅用于调试。

### 5.7 网络状态检查脚本

---

## 6. 调试实战案例

### 6.1 案例：NIC 无法绑定到 DPDK

```
问题描述:
─────────────────────────────────────
执行 dpdk-devbind --bind=vfio-pci 82:00.0 失败
错误: "Unable to open /dev/vfio/XX: Permission denied"

诊断步骤:
─────────────────────────────────────

1. 检查 VFIO 是否加载
   $ lsmod | grep vfio
   vfio_pci  12345  0
   vfio_iommu_type1  23456  1
   vfio  34567  2  [vfio_pci vfio_iommu_type1]

2. 检查 /dev/vfio 权限
   $ ls -la /dev/vfio/
   crw-rw---- 1 root root  10,  63  /dev/vfio/vfio
   crw-rw---- 1 root root 239,  0  /dev/vfio/vfio0
   crw-rw---- 1 root root 239,  1  /dev/vfio/vfio1

   当前用户不在 root 组

3. 检查 IOMMU 状态
   $ dmesg | grep -i iommu
   [    0.123456] DMAR: IOMMU enabled

4. 检查用户权限
   $ groups
   $USER : $USER disk lpadmin

   解决方案: 将用户加入 vfio 组或使用 root

5. 修复:
   $ sudo chown root:vfio /dev/vfio/*
   $ sudo chmod 660 /dev/vfio/*

   或者将用户加入 vfio 组:
   $ sudo usermod -a -G vfio $USER
   $ logout  # 重新登录
```

### 6.2 案例：数据包丢包严重

```
问题描述:
─────────────────────────────────────
DPDK 应用运行时丢包
perf 显示 RX-dropped 增加

诊断步骤:
─────────────────────────────────────

1. 检查 mbuf pool 大小
   $ dpdk-proc-info -l 0-7 -n 4 -- -p 0
   Mbuf Pool: mbuf_pool_socket0
     Count: 16384    In Use: 16384    Free: 0

   问题: mbuf pool 耗尽!

2. 增大 mbuf pool
   # 初始公式:
   # pool_size = nb_ports * nb_queues * nb_rxd * 2 + overhead
   # 对于 2 ports, 4 queues, 512 rxd:
   # = 2 * 4 * 512 * 2 + 8192 = 16384 + 8192 = 24576

   修改应用，增加 pool 大小到 32768

3. 检查 RX ring 配置
   $ ethtool -g eth0
   Ring parameters for eth0:
   Current hardware settings:
   RX: 512

   如果 rxd 太小，增加到 1024 或 2048

4. 检查 NIC 统计
   $ ethtool -S eth0 | grep -i drop

   常见丢包原因:
   - rx_dropped: mbuf 不足
   - rx_fifo_errors: FIFO 溢出
   - rx_missed_errors: NIC 内部 buffer 满

5. 检查 CPU 负载
   $ top
   # 是否 CPU 100%?
   # 如果是，增加 worker lcore

6. 检查 NUMA
   # 确保 NIC 和内存同在一个 NUMA node
   $ cat /sys/bus/pci/devices/82:00.0/numa_node
   1
   $ cat /sys/devices/system/node/node1/meminfo | head -5
   Node 1: OK
```

### 6.3 案例：性能低于预期

```
问题描述:
─────────────────────────────────────
理论 10G 线速，实际只能跑 6G

诊断步骤:
─────────────────────────────────────

1. 确认 link speed
   $ ethtool eth0
   Speed: 10000Mb/s - 确认是 10G

2. 检查 offload 设置
   $ ethtool -k eth0 | grep -E "tso|gso|gro|lro"

   场景: 混用内核和 DPDK 可能导致问题

3. 检查 burst size
   # perf top 观察 rx_burst 是否批量接收

4. 检查是否为单核瓶颈
   $ perf stat -e cycles ./dpdk_app
   # 观察 CPI (cycles per instruction)
   # CPI > 2 说明有内存瓶颈

5. 检查 RSS 配置
   $ dpdk-proc-info -- -p 0

   # 确认 RSS 分布在多个队列
   # 确认应用从多个队列读取

6. 检查 CPU 频率
   $ cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq
   # 可能被 throttled (温度、功耗)

7. 检查大页使用
   $ cat /proc/meminfo | grep Huge
   AnonHugePages:         0 kB  <-- 问题! 应该有很多大页
   HugePages_Total:      64
   HugePages_Free:        0
   Hugepagesize:    1048576 kB

8. 关闭透明大页
   # echo never > /sys/kernel/mm/transparent_hugepage/enabled
   # echo never > /sys/kernel/mm/transparent_hugepage/defrag
```

---

## 7. 小结

本章核心要点：

1. **dpdk-devbind**：DPDK 设备绑定管理脚本，支持绑定/解绑 NIC 到 UIO/VFIO 驱动。

2. **VFIO 优于 igb_uio**：VFIO 支持 IOMMU 隔离，在内核主线，SR-IOV 必须用 VFIO。igb_uio 是 out-of-tree 模块，生产环境不推荐。

3. **IOMMU group**：同 group 的设备必须同时绑定 VFIO，否则会失败。可通过 `readlink /sys/bus/pci/devices/xxx/iommu_group` 查看。

4. **绑定流程**：检查 IOMMU → 加载驱动 (vfio-pci) → dpdk-devbind 绑定 → 验证。

5. **常见绑定问题**：VFIO 权限、IOMMU 未启用、IOMMU group 冲突、设备被占用、驱动不兼容。

6. **ethtool**：Linux NIC 配置工具，查看/设置 offload、ring buffer、中断合并、speed/duplex。DPDK 占用的 NIC 无法用 ethtool。

7. **lspci**：PCI 设备诊断，查看配置空间 BAR、链路状态、能力寄存器。`setpci` 可修改配置空间但危险，除非完全理解否则不要用。

8. **rte_log**：日志系统，使用 `RTE_LOG_REGISTER_DEFAULT()` 注册自定义类型，`--log-level=EAL:info` 控制。旧的 `RTE_LOGTYPE_PMD` 已移除，PMD 日志由驱动自行注册。

9. **rte_trace** (20.11+)：`RTE_TRACE_POINT()` 定义 trace point，`--trace=.*` EAL 选项启用。

10. **dpdk-proc-info**：secondary 进程方式读取运行中应用的 stats/xstats/mempool 信息。

11. **dpdk-telemetry** (21.11+)：通过 UNIX socket 提供 JSON 格式数据，比 proc-info 更灵活。

12. **dpdk-dumpcap**：推荐抓包工具，替代旧版 dpdk-pdump。Primary 进程需调用 `rte_pdump_init()`。pdump 会复制 mbuf，仅用于调试。

13. **pdump API**：`rte_pdump_enable(port, queue, flags, ring, mp, NULL)`，不是传入 struct。

14. **xstats API**：`rte_eth_xstats_get()` 获取详细统计，可按名称前缀过滤。

15. **实战案例**：NIC 绑定权限问题 (chown/chmod)、mbuf pool 耗尽 (增大 pool)、性能低于预期 (HugePage/透明大页)。

**下一篇预告**：[[ch32-pktgen|第三十二章]]将讲解流量生成——pktgen 流量生成与测试场景。

---

> [!tip] 参考文献
>
> - DPDK documentation, "Getting Started Guide", https://doc.dpdk.org/guides/linux_gsg/
> - DPDK, "Device Binding Tool", https://doc.dpdk.org/guides/tools/devbind.html
> - Linux ethtool man page, `man ethtool`
> - Linux lspci man page, `man lspci`
> - Intel, "DPDK Performance Tuning Guide"
> - "Debugging DPDK Applications", https://doc.dpdk.org/guides/proguide/debugging.html
