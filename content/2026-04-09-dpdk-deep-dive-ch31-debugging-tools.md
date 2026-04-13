---
title: "DPDK 深度探索 (三十一)：调试工具——dpdk-devbind、ethool"
date: 2026-04-09
tags: [dpdk, series, debugging, devbind, ethtool, pci, uio, vfio, network-driver, binding]
description: "深入理解 DPDK 调试工具——dpdk-devbind 设备绑定、ethool 查看配置、PCI 设备管理、UIO/VFIO 驱动绑定、网络设备状态查看"
---

> [!info] DPDK 深度探索系列
> 0. [[2026-04-09-dpdk-deep-dive-series-index|全栈学习路径总览]]
> 1-30. 前三十章已完成
> 31. **第三十一章：调试工具——dpdk-devbind、ethool**

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
│     - pdump                  : 包抓取                                      │
│     - ethdump                 : 包转储                                      │
│     - procinfo               : 运行时统计 (Ch29)                           │
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

### 2.5 常见问题排查

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

# 修改 PCI 配置 (小心!)
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

### 5.1 内核网络诊断

```bash
# 查看中断分布
cat /proc/interrupts | grep -E "eth|ixgbe|i40e"

# 输出:
#  85:   123456   0   IR-PCI-MSI   edge   eth0-rx-0
#  86:   234567   0   IR-PCI-MSI   edge   eth0-tx-0
#  87:   345678   0   IR-PCI-MSI   edge   eth0-rx-1
# ...

# 设置 IRQ affinity
echo "1" > /proc/irq/85/smp_affinity
echo "2" > /proc/irq/86/smp_affinity

# 查看 softirqs
cat /proc/softirqs | head -20

# 输出:
#                    CPU0       CPU1       CPU2
#   HI:          123        234        345
#   TIMER:      12345      23456      34567
#   NET_TX:        12         23         34
#   NET_RX:     12345      23456      34567
# ...

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

### 5.2 DPDK 内部调试

```c
// DPDK 日志系统 (rte_log)

// 头文件
#include <rte_log.h>

// 设置日志级别
// EAL 选项: --log-level=<level>
// 级别: emergency(0), alert(1), critical(2), error(3), warning(4),
//       notice(5), info(6), debug(7)

int
setup_logging(void)
{
    // 全局日志级别
    rte_log_set_global_level(RTE_LOG_INFO);

    // 模块日志级别
    rte_log_set_level(RTE_LOG_DPdk, RTE_LOG_INFO);
    rte_log_set_level(RTE_LOG_PMD, RTE_LOG_DEBUG);

    return 0;
}

// 使用日志
RTE_LOG(INFO, EAL, "Initializing EAL with %d args\n", argc);
RTE_LOG(DEBUG, PMD, "TX packet on port %u queue %u\n", port_id, queue_id);
RTE_LOG(ERR, APP, "Failed to initialize port %u\n", port_id);

// 动态日志控制
int
set_module_log_level(const char *module, int level)
{
    struct rte_log_dynamic_reg {
        const char *name;
        uint32_t level;
    };

    // 运行时更改日志级别
    // 通过 EAL 选项: --log-level=pmd.net.ixgbe:debug
}

// DPDK trace (DPDK 20.11+)
#include <rte_trace.h>

// 启用 trace
// EAL 选项: --trace=.*

// 定义 trace point
RTE_TRACE_POINT(
    rte_pktmbuf_alloc,
    RTE_TRACE_POINT_ARGS(struct rte_mbuf *mbuf, uint16_t size),
    rte_trace_point_emit_ptr(mbuf);
    rte_trace_point_emit_uint16(size);
);

// 录制 trace
rte_pktmbuf_alloc_trace(mbuf, size);

// dump trace
// app --trace-dump=/tmp/trace.dat
```

### 5.3 pdump 抓包

```c
// DPDK pdump 工具

// pdump 启动需要 secondary 进程
// ./dpdk-pdump -- --pdump  stats:stats.txt,flows:flows.txt

// 在应用中启用 pdump
// EAL 参数: --vdev=net_pdump0

// 示例: 使用 pdump 抓包
int
enable_pdump(uint16_t port, uint16_t queue)
{
    struct rte_pdump_params params = {
        .port = port,
        .queue = queue,
        .filter = {
            .filtermask = RTE_PDUMP_FILTER_RX,
        },
        .ring = NULL,  // 使用默认 ring
    };

    return rte_pdump_enable(&params);
}

// 抓取特定端口/队列
rte_pdump_enable_by_deviceid("82:00.0", 0,
                               RTE_PDUMP_FILTER_RX,
                               NULL, NULL);
```

### 5.4 网络状态检查脚本

```bash
#!/bin/bash
# check_nic_status.sh - NIC 状态检查脚本

ETH=${1:-eth0}

echo "=============================================="
echo " NIC Status Check: $ETH"
echo "=============================================="

echo ""
echo "--- Device Info ---"
ethtool -i $ETH 2>/dev/null || echo "ethtool failed (device may be DPDK-bound)"

echo ""
echo "--- Link Status ---"
ethtool $ETH 2>/dev/null | grep -E "Speed|Duplex|Link|Auto-neg"

echo ""
echo "--- Offload Features ---"
ethtool -k $ETH 2>/dev/null | grep -E "on|off"

echo ""
echo "--- Ring Buffers ---"
ethtool -g $ETH 2>/dev/null

echo ""
echo "--- Interrupt Coalescing ---"
ethtool -c $ETH 2>/dev/null | grep -E "usecs|frames|adaptive"

echo ""
echo "--- Statistics ---"
ethtool -S $ETH 2>/dev/null | grep -E "packets|bytes|errors|dropped" | head -20

echo ""
echo "--- PCI Info ---"
lspci -vvv -s $(cat /sys/class/net/$ETH/device/../vendor 2>/dev/null | sed 's/0x//'):$(cat /sys/class/net/$ETH/device/../device 2>/dev/null | sed 's/0x//') 2>/dev/null | head -30

echo ""
echo "--- Driver Binding ---"
ls -la /sys/class/net/$ETH/device/driver 2>/dev/null
cat /sys/class/net/$ETH/device/driver/module 2>/dev/null

echo ""
echo "--- Interrupt Affinity ---"
for irq in $(grep -E "$ETH" /proc/interrupts | awk '{print $1}' | tr -d :); do
    echo "IRQ $irq: $(cat /proc/irq/$irq/smp_affinity 2>/dev/null)"
done

echo ""
echo "--- Socket Buffer ---"
cat /proc/sys/net/core/rmem_max
cat /proc/sys/net/core/wmem_max
cat /proc/sys/net/core/rmem_default
cat /proc/sys/net/core/wmem_default

echo ""
echo "--- Network Errors ---"
ip -s link show $ETH | grep -E "errors|dropped|overrun|carrier"
```

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
   $ ./dpdk-procinfo -l 0-7 -n 4 -- -p 0
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
   $ ./dpdk-procinfo -- -p 0

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

2. **绑定流程**：检查 IOMMU → 加载驱动 (igb_uio/vfio-pci) → dpdk-devbind 绑定 → 验证。

3. **VFIO 优于 igb_uio**：VFIO 支持 IOMMU 隔离，更安全，性能更好。

4. **常见绑定问题**：VFIO 权限、IOMMU 未启用、设备被占用、驱动不兼容。

5. **ethtool**：Linux NIC 配置工具，查看/设置 offload、ring buffer、中断合并、speed/duplex。

6. **DPDK 占用时 ethtool 限制**：DPDK 占用的 NIC 无法用 ethtool 管理，需先解绑。

7. **lspci**：PCI 设备诊断，查看配置空间 BAR、链路状态、能力寄存器。

8. **内核网络诊断**：`/proc/interrupts` (中断分布)、`/proc/softirqs` (软中断)、`/proc/net/snmp` (网络统计)。

9. **DPDK rte_log**：日志系统，支持模块级别控制，`RTE_LOG()` 宏，`--log-level` EAL 选项。

10. **DPDK trace** (20.11+)：`RTE_TRACE_POINT()` 定义跟踪点，`--trace` EAL 选项启用录制。

11. **pdump**：DPDK 内置抓包工具，需要 secondary 进程。

12. **调试脚本**：自动化检查 NIC 状态、PCI 信息、中断亲和、socket buffer。

13. **实战案例**：NIC 绑定权限问题 (chown/chmod)、mbuf pool 耗尽 (增大 pool)、性能低于预期 (HugePage/透明大页)。

**下一篇预告**：[[2026-04-09-dpdk-deep-dive-ch32-traffic-generator|第三十二章]]将讲解流量生成——dpdk-pktgen、TRex。

---

> [!tip] 参考文献
> - DPDK documentation, "Getting Started Guide", https://doc.dpdk.org/guides/linux_gsg/
> - DPDK, "Device Binding Tool", https://doc.dpdk.org/guides/tools/devbind.html
> - Linux ethtool man page, `man ethtool`
> - Linux lspci man page, `man lspci`
> - Intel, "DPDK Performance Tuning Guide"
> - "Debugging DPDK Applications", https://doc.dpdk.org/guides/proguide/debugging.html
