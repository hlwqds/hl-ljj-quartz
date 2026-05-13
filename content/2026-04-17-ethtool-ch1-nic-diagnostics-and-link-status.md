---
title: ethtool 深度系列 Ch1：网卡诊断与链路状态
date: 2026-04-17 17:00:00
tags: [Network, ethtool, NIC, Ethernet, igb, ixgbe, i40e, mlx5, Link Negotiation]
description: 深入讲解 ethtool 查看网卡信息、链路状态协商、驱动固件版本、常见网卡型号对比，以及链路故障排查思路。
---

# ethtool 深度系列 Ch1：网卡诊断与链路状态

## 1. ethtool 在网络栈中的位置

```
物理层：光模块/电口/SFP+
       ↓
MAC 层：网卡芯片（处理 Ethernet frame）
       ↓
PCIe：  网卡 ↔ CPU 传输通道
       ↓
Driver：内核模块（igb/ixgbe/i40e/mlx5/virtio...）
       ↓
ethtool：用户态工具，调用 driver 的 ethtool_ops 回调
         ↕
    sysfs (/sys/class/net/eth0/)
    /proc/interrupts
    /proc/net/dev
```

```
ethtool 的本质是 driver 的"调试窗口"：
  - 每个 driver 实现了 ethtool_ops（struct ethtool_ops）
  - ethtool 命令 → sysfs → driver 回调 → 硬件寄存器
  - 驱动不实现某些 ops → ethtool 显示 "not reported" 或 operation not supported
```

> [!note]
> `ethtool -i` 看到的信息全部来自 driver，不是硬件本身。driver 报告什么就显示什么。

---

## 2. 查看网卡基本信息

### 2.1 ethtool（无选项）

```bash
# 最基础的查看（驱动+链路状态）
ethtool eth0

# 输出：
# Settings for eth0:
#     Supported ports: [ TP]
#     Supported link modes:   10baseT/Half 10baseT/Full
#                              100baseT/Half 100baseT/Full
#                              1000baseT/Full
#     Supported pause frame use: Symmetric
#     Supported FEC modes: Not reported
#     Speed: 1000Mb/s          ← 当前协商速率
#     Duplex: Full             ← 全双工
#     Port: Twisted Pair       ← 介质类型（电口）
#     PHYAD: 0
#     Transceiver: internal    ← 收发器（internal = 板载光模块）
#     Auto-negotiation: on      ← 自动协商开启
#     MDI-X: Unknown
#     Supports Wake-on: pumbag
#     Wake-on: d
#     Current message level: 0x00000007 (7)
#     Link detected: yes        ← 物理链路 UP
```

### 2.2 关键字段解读

| 字段                    | 含义                        | 排查价值                            |
| ----------------------- | --------------------------- | ----------------------------------- |
| `Speed`                 | 协商速率（可能 < 物理速率） | 协商成 100Mbps → 检查网线/光模块    |
| `Duplex`                | 半双工/全双工               | 半双工 → 协商问题或对端不支持全双工 |
| `Auto-negotiation`      | 是否开启自协商              | 关闭可能协商失败                    |
| `Port`                  | 介质类型                    | TP=电口，Fiber=光口                 |
| `Transceiver`           | 收发器位置                  | internal=板载，external=可插拔      |
| `Link detected`         | 链路是否 UP                 | no → 物理层断（光纤/网线/模块）     |
| `Wake-on`               | 远程唤醒支持                | 关闭可省电但无法远程开机            |
| `Current message level` | 驱动日志级别                | 0x07=Errors+Link+Probe              |

### 2.3 链路状态异常排查

```
场景 1: Speed 变成 100Mb/s（应该是 1Gb/s）
  → 检查顺序：
    1. ethtool eth0（看对端协商状态）
    2. 检查网线（8芯是否全通，千兆需要 8 芯）
    3. 换网线测试
    4. 查光模块（如果是光纤）

场景 2: Link detected: no
  → 光纤断了 / 网线没插 / 模块坏了 / 对端端口 shutdown
  → 解法：
    1. ip link set eth0 up（可能是软件 down）
    2. 检查光纤/网线
    3. 换模块测试
    4. ethtool -m eth0（查光模块功率）

场景 3: Duplex: Half（应该是 Full）
  → 通常是对端强制半双工，或 auto-neg 失败
  → 解法：两端都开自协商，或两端都强制同速率同双工
```

---

## 3. 驱动与硬件信息

### 3.1 ethtool -i（驱动详情）

```bash
ethtool -i eth0

# output：
# driver: igb
# version: 5.13.0
# firmware-version: 1.5.4
# bus-info: 0000:01:00.0
# supports-statistics: yes
# supports-test: yes
# supports-eeprom-access: yes
# supports-register-domic: yes
# supports-priv-flags: no

# ── 字段解释 ──
# driver:        内核模块名（igb=Intel 千兆，ixgbe=万兆，i40e=万兆，mlx5=Mellanox）
# version:       驱动版本
# firmware-version: 网卡固件（网卡自己的 firmware，很重要！）
# bus-info:      PCIe 位置（定位机框哪个槽位）
# supports-*:    驱动支持哪些高级特性
```

### 3.2 常见网卡型号对比

```
Intel 网卡家族：

igb（Gigabit Ethernet）
  - 型号：I350 / I210 / I211
  - PCIe：PCIe v2.1 x4
  - 速率：1GbE
  - 驱动：igb（Linux 内置）
  - 特点：最常见的千兆网卡，虚拟化支持好

ixgbe（10 Gigabit Ethernet）
  - 型号：X550 / X540 / 82599
  - PCIe：PCIe v3.0 x8
  - 速率：10GbE
  - 驱动：ixgbe（Linux 内置）
  - 特点：数据中心常见，支持 SR-IOV

i40e（40 Gigabit Ethernet）
  - 型号：XL710 / X710
  - PCIe：PCIe v3.0 x8
  - 速率：40GbE
  - 驱动：i40e（Linux 内置）
  - 特点：新一代 40G，支持 RSS + DCB

ice（100 Gigabit Ethernet）
  - 型号：E800 系列
  - PCIe：PCIe v4.0 x16
  - 速率：100GbE
  - 驱动：ice
  - 特点：最新一代 Intel网卡

Mellanox（NVIDIA）：

mlx5（ConnectX 系列）
  - 型号：ConnectX-5 / ConnectX-6 / ConnectX-7
  - PCIe：PCIe v4.0 x16
  - 速率：100/200/400GbE
  - 驱动：mlx5_core + mlx5_ib
  - 特点：InfiniBand+Ethernet 双模，SHAMPO，RDMA

虚拟网卡：

virtio（KVM 半虚拟化）
  - 速率：10GbE（模拟）
  - 驱动：virtio_net（Linux 内置）
  - 特点：无 RSS（老版本），virtio-net 自带 multiqueue

vmxnet3（VMware）
  - 速率：10GbE
  - 驱动：vmxnet3
  - 特点：VMware Tools 需要安装，高性能

山海/Guest：

tg3（Broadcom Tigator3）
  - 常见于 Dell PowerEdge 服务器
  - 稳定，驱动成熟

bnx2/bnx2x（Broadcom QLogic）
  - bnx2: 1GbE
  - bnx2x: 10GbE+
```

### 3.3 PCIe 定位故障硬件

```bash
# bus-info 告诉你在哪个 PCIe 槽位
ethtool -i eth0 | grep bus-info
# bus-info: 0000:01:00.0

# 解读：
# 0000:01:00.0
# bus:slot:func
# 0000 = PCI domain（通常是 0）
# 01 = PCIe bus number
# 00 = slot（物理槽位）
# 0 = function（网卡上的第几个口）

# lspci 可以反向定位
lspci | grep -i ethernet
# 01:00.0 Ethernet controller: Intel Corporation I350 Gigabit ...

# lspci -D（显示完整地址）
lspci -D | grep -i 01:00

# 定位后：
# 01:00.0 → 对应机框前面板的 Port 1
# 01:00.1 → 对应机框前面板的 Port 2（双口网卡）
```

### 3.4 光模块信息（ethtool -m）

```bash
# 查看光模块详细信息（SFP/QSFP）
ethtool -m eth0

# output（Intel X710 万兆光口）：
# Elanter Ixia: 06-SFPP-SR
#        SFP+ module detected
#        Connector: LC
#        Supported link modes: 1000baseKX/Full, 10000baseSR/Full
#        Transmission media: Multi-mode 50um (OM3)
#        Wavelength: 850nm
#        Dual CDR: On
#        Diagnostic header: 0x96
#        Temperature: 35.21 C
#        Voltage: 3.29 V
#        Current: 7.2 mA
#        TX power: -2.1 dBm
#        RX power: -3.4 dBm

# 关键诊断指标：
# Temperature: 温度（过高 → 模块老化/散热差，正常 < 50°C）
# Voltage: 电压（异常 → 供电问题）
# TX power: 发送功率（低于 -7dBm → 模块发射弱/光纤衰减）
# RX power: 接收功率（低于灵敏度阈值 → 丢包）

# 检查光功率是否在正常范围
# 常见光模块：
#   OM3 多模 850nm SR：TX: -5~-1dBm，RX: > -7.5dBm
#   SMF 1310nm LR：TX: -5~0dBm，RX: > -8dBm
#   SMF 1550nm ER：TX: 0~4dBm，RX: > -8dBm

# 如果 RX power 太低：
#   - 光纤距离超出模块支持
#   - 光纤弯折/熔接损耗大
#   - 对端 TX 功率衰减
```

---

## 4. 链路协商：为什么 Speed 会变

### 4.1 Auto-negotiation 原理

```
Auto-negotiation（AN）是两端交换"能力帧"：

设备 A（支持 100M Full / 1G Full）        设备 B（支持 10M/100M/1G Full）
     │                                          │
     │─────── FLP（Fast Link Pulse）──────────▶│
     │◀─────── FLP ────────────────────────────│
     │                                          │
     A 告诉 B：我的能力 [100M Full, 1G Full]
     B 告诉 A：我的能力 [10M, 100M Full, 1G Full]
     │
     ↓
两端取最高公共能力：1G Full
```

```
为什么会出现协商成 100Mbps？

常见原因：
  1. 一端强制 100M Full，一端开自协商
     → 自协商那端会降级匹配对端
     → 解法：两端都开 AN，或两端都强制同一速率

  2. 网线只通 4 芯（百兆只需要 4 芯）
     → 即使两端都支持 1G，中间网线只接了 4 芯
     → 解法：换 8 芯网线或检查布线

  3. 光模块不兼容（光模块带不带 AN？）
     → 有些 SFP 模块强制 1G 不支持协商
     → 解法：换模块，或强制两端速率

  4. 驱动/hardware bug
     → 某些廉价网卡 AN 实现有 bug
     → 解法：关闭 AN，强制同速率
```

### 4.2 强制链路参数

```bash
# 强制速率 + 双工（关闭自动协商）
ethtool -s eth0 speed 1000 duplex full autoneg off

# 开启自动协商
ethtool -s eth0 autoneg on

# 强制特定速率（排查时用）
ethtool -s eth0 speed 100 duplex full autoneg off
# 如果 100M 也协商不上 → 物理层问题

# 检查结果
ethtool eth0 | grep -E "Speed|Duplex|Auto"

# 配置持久化（ethtool -s 临时生效，重启失效）
# Debian/Ubuntu：
# /etc/network/interfaces
# iface eth0 inet static
#     ...
#     post-up ethtool -s eth0 speed 1000 duplex full autoneg on

# RHEL/CentOS：
# /etc/sysconfig/network-scripts/ifcfg-eth0
# ETHTOOL_OPTS="speed 1000 duplex full autoneg on"
```

### 4.3 对端信息（ethtool -a）

```bash
# 查看 pause frame（流量控制）配置
ethtool -a eth0

# output：
# Pause parameters for eth0:
# Autonegotiate: yes
# TX: enabled
# RX: enabled

# ── 含义 ──
# TX enabled: 本端可以发送 pause frame（让对端暂停发送）
# RX enabled: 本端可以接收并处理 pause frame
# Autonegotiate: 是否和对端协商 pause frame

# 关闭 pause frame（通常禁用，降低延迟）
ethtool -A eth0 tx off rx off

# 开启 symmetric pause（双方互等）
ethtool -A eth0 tx on rx on

# 查看结果
ethtool -a eth0
```

---

## 5. 网卡硬件测试

### 5.1 ethtool -t（自检）

```bash
# 在线测试（不需要拔网线，但只测部分功能）
ethtool -t eth0

# output（正常）：
# The test result is PASS
# The test extra info are not provided

# 如果失败：
# The test result is FAIL

# 离线测试（需要断开连接，测更全面）
ethtool -t eth0 offline

# output（离线模式）：
# off line test : pass
# Link test : pass
# registers test : pass
# memory test : pass

# 测试哪几项取决于 driver 和网卡型号
# mlx5 支持：loopback test, register test, SRAM test
# igb 支持：link test, registers test
# virtio 不支持自检
```

### 5.2 寄存器查看（ethtool -d）

```bash
# 读取网卡寄存器（driver 支持的情况下）
ethtool -d eth0

# output（igb）：
# ...（大量 16 进制寄存器 dump）
# PHY Registers (0x00..0x1F):
#   0x0000: 0x1140
#   0x0001: 0x796d
#   ...

# 用途：
#   - 网卡 driver 开发者调试
#   - 高级故障排查（PHY 状态寄存器）
#   - 确认 driver 正确访问硬件

# 如果不支持：
# operation not supported
```

### 5.3 获取 PHY/MAC 固件版本（型号）

```bash
# 抓取网卡详细信息
ethtool -e eth0

# EEPROM 内容（前 N bytes）
# 包含：
#   - 网卡 MAC 地址
#   - 型号/PN（Part Number）
#   - 序列号
#   - 固件版本

# 更友好的方式：
ethtool -i eth0
# driver firmware-version 已经给出摘要

# Mellanox 专用：查看 adapter info
# ethtool -m mlx50（mlx5 系列专用格式）
```

---

## 6. 网卡型号与选购

### 6.1 按场景选网卡

| 场景          | 推荐网卡                           | 理由                     |
| ------------- | ---------------------------------- | ------------------------ |
| 通用服务器    | Intel i350 / i210                  | 驱动成熟，稳定           |
| 虚拟化宿主机  | Intel i350 + SR-IOV                | 支持 PCI-SIG SR-IOV      |
| 25GbE 网络    | Mellanox ConnectX-5 / Intel XXV710 | 性价比最高的 25G         |
| 100GbE 网络   | Mellanox ConnectX-6                | 当前主流 100G            |
| RDMA/存储     | Mellanox ConnectX                  | 原生 InfiniBand + RoCE   |
| KVM 虚拟机    | virtio-net（半虚拟化）             | Linux 内置，无需额外驱动 |
| VMware 虚拟机 | vmxnet3                            | VMware Tools 配合        |

### 6.2 虚拟网卡（KVM/libvirt）传递物理网卡

```bash
# 场景：想把物理网卡直接给虚拟机用（SR-IOV）
# 需要在 host 上启用 SR-IOV

# 1. 查看网卡是否支持 SR-IOV
lspci -vvv -s 01:00.0 | grep -i "SR-IOV"
# Capabilities: [e0] Vital Product Data
# 如果有 "SR-IOV" 行，说明支持

# 2. 启用 SR-IOV（临时）
echo 8 > /sys/bus/pci/devices/0000:01:00.0/sriov_numvfs
# 8 = 虚拟功能（VF）数量

# 3. 查看 VF
lspci | grep -i "Virtual Function"
# 01:00.2 Virtual Function: Intel Corporation ...
# 01:00.3 Virtual Function: Intel Corporation ...

# 4. 把 VF 分配给虚拟机
virsh attach-device vm1 /tmp/vf.xml --persistent
# <interface type='hostdev' managed='yes'>
#   <source>
#     <address domain='0x0000' bus='0x01' slot='0x00' function='0x2'/>
#   </source>
# </interface>

# 注意：VF 分配后，物理网卡（PF）的 RSS 队列会减少
# 因为每个 VF 占用了部分硬件资源
```

---

## 7. 实战：链路故障排查案例

### 7.1 案例 1：服务器上不了万兆，协商成千兆

```bash
# Step 1：确认链路状态
ethtool eth0
# Speed: 1000Mb/s（应该是 10000Mb/s）
# Port: Twisted Pair → 万兆用铜缆/光口，电口最大 1G

# 如果 Port 是 Twisted Pair：物理上不可能跑万兆
# 解法：换光口网卡 + 光模块

# 如果 Port 是 Fiber，但 Speed 是 1000Mb/s：
# → 检查模块型号

# Step 2：检查模块
ethtool -m eth0
# 假设模块是 10G SR，但显示只支持 1000baseKX/Full
# → 模块型号错误（插了千兆模块进万兆口）
# → 换 10G 模块

# Step 3：检查对端协商
# 如果对端强制 100M：
#   ethtool -s swp1 speed 10000 duplex full autoneg off
# （Mellanox switch 用 mlxconfig 强制）
```

### 7.2 案例 2：光纤链路 RX power 低，丢包

```bash
# 监控光功率
watch -n5 'ethtool -m eth0 | grep -E "power|Temperature"'

# 假设 RX power = -10.2 dBm（低于 -7.5dBm 灵敏度）
# → 丢包

# 排查步骤：
# 1. 检查光纤长度是否超出模块支持
#    SR 模块：OM3 300m，SR4 100m
#    LR 模块：10km
#    如果距离超了 → 换长距离模块

# 2. 检查光纤熔接点/连接器损耗
#    用光功率计测链路损耗

# 3. 检查对端 TX 功率
#    找工程确认对端光功率是否正常

# 4. 如果是临时现象（温度升高后功率下降）
#    → 光模块散热差 → 换模块或加散热片
```

### 7.3 案例 3：ethtool 显示 "operation not supported"

```bash
# 常见原因：
# 1. 虚拟网卡不支持某些操作
ethtool -i eth0
# driver: virtio_net
# virtio-net 支持：-S (统计), -k (offload), -i (驱动信息)
# virtio-net 不支持：-r (强制速率), -A (pause frame), -C (coalescing)

# 2. 容器内（namespace）没有权限
#    某些 ethtool 操作需要 CAP_NET_ADMIN
#    解法：--privileged 或 --cap-add=NET_ADMIN

# 3. 网卡被 bonding 使用
#    解法：从 bonding 移除：
#    echo -eth0 > /sys/class/net/bond0/bonding/slaves

# 4. 网卡被 team 使用
#    解法：拆散 team

# 查看 ethtool 支持的操作（-i 显示 supports-*）
ethtool -i eth0
# supports-statistics: yes
# supports-test: yes
# supports-eeprom-access: yes
# supports-register-domic: yes
# supports-priv-flags: no

# 如果 supports-statistics: no → ethtool -S 不工作
```

### 7.4 案例 4：Mellanox 网卡固件版本过旧

```bash
# ethtool -i mlx5_0
# firmware-version: 14.32.1010

# 查最新固件版本：
# https://network.nvidia.com/products/adapter-ethernet-broadband/adapter-ethernet-mellanox/
# 假设最新是 16.35.3500

# 升级固件（Mellanox flint）
flint -d /dev/mst/mt4123 -i fw-ConnectX6-rel.mlnx -y full

# 升级后需要重启网卡：
# modprobe -r mlx5_core && modprobe mlx5_core

# 确认：
ethtool -i mlx5_0 | grep firmware-version

# 为什么重要？
#   新固件修复 bug + 支持新功能（e.g., improved RoCE performance）
#   安全漏洞修复（Intel PSU 漏洞补丁通过固件分发）
```

---

## 8. 小结

```
ethtool 基础命令：
  ethtool eth0              基本信息（Speed/Duplex/Port/Link）
  ethtool -i eth0           驱动+固件版本
  ethtool -m eth0           光模块功率+型号
  ethtool -a eth0           Pause frame 配置
  ethtool -S eth0           统计计数（Ch4 详讲）
  ethtool -k eth0           Offload 状态（Ch2 详讲）
  ethtool -l eth0           RSS 队列数（Ch3 详讲）
  ethtool -g eth0           Ring buffer 大小（Ch5 详讲）
  ethtool -C eth0           Interrupt coalescing（Ch5 详讲）
  ethtool -t eth0           硬件自检
  ethtool -d eth0           寄存器 dump（debug）

链路问题三步排查：
  1. ethtool eth0 → Speed/Duplex/Link detected
  2. ethtool -m eth0 → 光功率/模块型号
  3. lspci | grep eth → PCIe 识别正常？

常见 Speed 降级原因：
  - 网线只通 4 芯 → 换 8 芯
  - 模块型号错 → 换正确模块
  - 一端强制/一端协商 → 两端一致
  - 光功率低 → 检查光纤+对端功率
```

---

## 延伸阅读

- `man ethtool` — ethtool 完整选项
- Intel 网卡驱动文档: https://www.intel.com/content/www/us/en/support/articles/000005779/ethernet-products.html
- Mellanox DOCA SDK: https://docs.nvidia.com/doca/
- Linux Ethernet driver 源码: `drivers/net/ethernet/intel/`
- PCIe SR-IOV: https://www.kernel.org/doc/html/latest/networking/switchdev.html
