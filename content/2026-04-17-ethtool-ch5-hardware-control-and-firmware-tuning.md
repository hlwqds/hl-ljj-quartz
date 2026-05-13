---
title: ethtool 深度系列 Ch5：硬件控制和固件调优
date: 2026-04-17 21:00:00
tags: [Network, ethtool, Ring Buffer, Interrupt Coalescing, Flow Control, Flow Director, Firmware]
description: 深入讲解 ethtool -G ring buffer、-C 中断合并、-A 流量控制、-N flow director（ntuple）、固件升级与诊断。
---

# ethtool 深度系列 Ch5：硬件控制和固件调优

## 1. Ring Buffer：数据的第一道缓存

### 1.1 Ring Buffer 原理

```
Ring Buffer = NIC 和驱动之间的 FIFO 队列

接收路径：
  NIC 收到包 → DMA → RX Ring Buffer → Driver 读取 → softirq

发送路径：
  Driver 写入 → TX Ring Buffer → NIC DMA → 网卡发送

Ring Buffer 大小 = 最大同时在"等"的包数
  - 大：允许瞬时 burst（不怕瞬时流量高峰），延迟高
  - 小：Burst 容易溢出丢包，但延迟低

为什么叫 Ring：
  固定大小的数组，首尾相连
  head pointer → driver 读取位置
  tail pointer → NIC 写入位置
  绕了一圈回来 = overflow
```

### 1.2 查看与修改

```bash
# 查看当前 ring buffer 大小
ethtool -g eth0

# output：
# Ring parameters for eth0:
# Pre-set maximums:
# RX:   4096            ← 最大 RX ring size
# RX Mini: 0
# RX Jumbo: 0
# TX:   4096            ← 最大 TX ring size
# Current hardware settings:
# RX:   256             ← 当前 RX ring size（太小！）
# RX Mini: 0
# RX Jumbo: 0
# TX:   256             ← 当前 TX（太小！）

# 设置更大的 ring buffer
ethtool -G eth0 rx 4096 tx 4096

# 验证
ethtool -g eth0

# 只增大 RX 或 TX
ethtool -G eth0 rx 2048
ethtool -G eth0 tx 2048
```

### 1.3 Ring Buffer 大小选择

```
选择依据：

场景 1：高速下载/上传（bulk transfer）
  → 大 ring buffer（4096）
  → 容忍 burst，允许高吞吐
  → 增加内存使用（每个 entry = ~2KB）

场景 2：低延迟交互（Redis/游戏/高频交易）
  → 小 ring buffer（256~512）
  → 包快速出队列，延迟低
  → burst 能力弱

场景 3：不确定场景（通用服务器）
  → 中等（1024~2048）
  → 平衡吞吐和延迟

内存占用估算：
  RX ring size = 4096，entry ~2KB
  内存占用 = 4096 × 2KB × N_queues
  8 队列 = 4096 × 2KB × 8 = 64MB
  → 合理，kernel 可以承受
```

### 1.4 rx-jumbo 和 rx-mini

```
部分网卡支持额外 buffer：

rx-jumbo：接收超过 MTU 但不是 jumbo frame 的包
  （1501~9000 字节之间的帧）

rx-mini：某些网卡的最小 fragment 缓存
  （主要是 ARM SoC 集成网卡）

通常：
  rx-jumbo 设置为 0 或 256
  rx-mini 设置为 0
  主要用 rx 和 tx 即可
```

---

## 2. Interrupt Coalescing：减少中断风暴

### 2.1 原理

```
无 coalescing：
  每个包 → 一个 IRQ → CPU 处理
  1Gbps 小包（64B）= 1.5M 中断/秒
  → CPU 100%，处理中断本身

Coalescing：
  把多个包合并成一次 IRQ
  等待 N 个包 或 M 微秒后，才触发一次 IRQ
  → 中断数降低 10-100x
  → CPU 节省

两种模式：
  1. 计数模式（rx-frames / tx-frames）
     收到 N 个包后触发一次 IRQ
     例如：rx-frames=64 → 凑够 64 个包才中断

  2. 延时模式（rx-usecs / tx-usecs）
     等待 N 微秒后触发一次 IRQ
     例如：rx-usecs=100 → 收到包后等 100us 再中断

组合：
  ethtool -C eth0 rx-usecs 50 rx-frames 64
  → 满足任一条件就中断（更激进）
```

### 2.2 查看与修改

```bash
# 查看当前 coalescing 配置
ethtool -c eth0

# output：
# Coalesce parameters for eth0:
# Adaptive RX: off  TX: off
# RX Microsecond Bypass: off
# TX Microsecond Bypass: off
# rx-usecs: 0                 ← 关闭（每个包都中断）
# rx-frames: 0                ← 关闭
# rx-usecs-irq: 0             ← IRQ 处理时的 coalescing
# rx-frames-irq: 0
# TX Microseconds: 0
# TX Frames: 0
# TX-usecs-irq: 0
# TX-frames-irq: 0
# stats-block-usecs: 0
# pokeflag: 0
# rx-coalesce-usecs-high: 0
# rx-max-coalesced-frames-high: 0
# ...

# 开启延时模式（100us 合并）
ethtool -C eth0 rx-usecs 100 tx-usecs 100

# 开启计数模式（64帧合并）
ethtool -C eth0 rx-frames 64 tx-frames 64

# 组合（任一条件触发）
ethtool -C eth0 rx-usecs 100 rx-frames 64

# 关闭 coalescing
ethtool -C eth0 rx-usecs 0
```

### 2.3 Adaptive RX/TX

```
Adaptive coalescing = 动态调整 coalescing 参数

开启：
  ethtool -C eth0 adaptive-rx on adaptive-tx on

原理：
  - 流量低时：用小的 rx-usecs（低延迟）
  - 流量高时：用大的 rx-usecs（高吞吐）
  - kernel 自动检测流量模式

查看 adaptive 状态：
  ethtool -c eth0 | grep adaptive

适用场景：
  - 混合负载（低延迟 + 高吞吐混合）
  - 不确定流量特征
  - 通用服务器（不想手动调）

注意：
  Adaptive 可能导致延迟不稳定（低负载时突然来个大 burst）
  金融/游戏：关闭 adaptive，手动设置固定值
```

### 2.4 coalescing 与延迟的关系

```
延迟敏感场景（延迟 vs 吞吐）：

低延迟设置（Redis/游戏/Trading）：
  ethtool -C eth0 rx-usecs 20
  → 每个包最多等 20us 就上送
  → 延迟 < 20us
  → CPU 中断频率高

高吞吐设置（文件传输/备份）：
  ethtool -C eth0 rx-usecs 200 rx-frames 128
  → 等待 200us 或凑够 128 帧才中断
  → 延迟高，但 CPU 效率高

测量延迟：
  # 用 ping 或 scapy 测 RTT
  # 对比不同 coalescing 设置下的 RTT
  # 同时用 mpstat 看 CPU idle
```

---

## 3. Flow Control：Pause Frame

### 3.1 原理

```
Pause Frame（暂停帧）= IEEE 802.3x 流量控制

工作方式：
  接收方 buffer 快满了 → 发 Pause Frame 给发送方
  发送方收到 → 停止发送 N 微秒
  → 接收方 buffer 清空
  → 发送方恢复发送

格式：
  MAC DA = 0180c2000001（全地址 pause frame）
  MAC SA = 发送方 MAC
  EtherType = 0x8808
  Control opcode = 0x0001
  Pause timer = N × 512 bit times

全双工 vs 半双工：
  全双工：IEEE 802.3x（Pause Frame）
  半双工：背压（collision-based）
```

### 3.2 配置

```bash
# 查看当前 flow control 配置
ethtool -a eth0

# output：
# Pause parameters for eth0:
# Autonegotiate: yes          ← 自协商 pause 能力
# TX: enabled                 ← 可以发送 pause
# RX: enabled                 ← 可以接收并响应 pause

# 关闭 TX pause（不让对方暂停）
ethtool -A eth0 tx off

# 关闭 RX pause（不让本端暂停）
ethtool -A eth0 rx off

# 关闭所有 pause
ethtool -A eth0 tx off rx off

# 开启 symmetric pause（互相暂停）
ethtool -A eth0 tx on rx on

# 开启自协商（两端自动协商 pause 能力）
ethtool -A eth0 autoneg on

# 注意：两端都需要开 autoneg
# 如果一端强制 on，一端 off → 不工作
```

### 3.3 Flow Control 使用场景

```
适合用 flow control 的场景：
  - 存储网络（iSCSI/NFS）：避免因瞬时拥塞丢包
  - HPC 集群：节点间高速通信
  - 有无损网络（lossless fabric）：需要 DCB 配置

不适合/不应该用的场景：
  - 互联网接入：pause frame 会级联放大
    运营商网络里，A 给 B 发 pause → B 给 C 发 pause → ...
    → 网络大面积拥塞
  - 有丢包机制的业务（TCP）：pause 不如 TCP 拥塞控制高效
  - 无线/广域网：延迟高，pause 会饿死发送方

现代数据中心：
  - 用 Priority Flow Control (PFC, 802.1Qbb) 替代全局 pause
  - PFC 是按优先级（CoS）pause，不是全局
```

---

## 4. ntuple / Flow Director：硬件包分类

### 4.1 什么是 Flow Director

```
Flow Director = 网卡硬件按规则分类包（分流）

原理：
  传统 RSS：hash(src_ip, dst_ip, src_port, dst_port) → queue
           无法控制特定 flow 走哪个 queue

  Flow Director：用户指定规则
           "src_ip=10.0.0.1 AND dst_port=443 → queue 3"
           → 特定 flow 直接路由到指定 queue

用途：
  1. 把特定 flow 路由到特定 CPU（cache 友好）
  2. 把特定 flow 镜像到指定 queue（用于 IDS/监控）
  3. 把特定 flow 丢弃（ACL）
  4. 给特定 flow 分配更多资源

需要驱动支持：Intel (i40e, ixgbe) / Mellanox 支持
```

### 4.2 ethtool -N 配置

```bash
# 查看 ntuple 支持
ethtool -k eth0 | grep ntuple

# output：
# ntuple-filters: off [fixed]     ← 驱动不支持或被锁定

# 开启 ntuple（需要驱动支持）
ethtool -K eth0 ntuple on

# 添加 flow director 规则
# 格式：ethtool -N eth0 flow-type <type> [src-ip <IP> dst-ip <IP>] [src-port <port> dst-port <port>] [l4proto <proto>] <action>

# 例子 1：HTTP 流量（dst_port 80）→ 队列 1
ethtool -N eth0 flow-type tcp4 dst-port 80 action 1

# 例子 2：来自 10.0.0.1 的流量 → 队列 2
ethtool -N eth0 flow-type ipv4 src-ip 10.0.0.1 action 2

# 例子 3：到 10.0.0.50:443 的流量 → 队列 0（最高优先级）
ethtool -N eth0 flow-type tcp4 src-ip 10.0.0.50 dst-port 443 action 0

# 例子 4：丢弃来自 192.168.1.100 的 SSH 流量
ethtool -N eth0 flow-type tcp4 src-ip 192.168.1.100 dst-port 22 action -1
# action -1 = drop

# 查看已有规则
ethtool -n eth0

# output：
# 4 flow type rules:
#   flow filter: ip src-ip = 10.0.0.1 action: 2
#   flow filter: tcp4 dst-port = 80 action: 1
#   ...

# 清空所有规则
ethtool -N eth0 delete 0
# 或
ethtool --reset eth0 flags 0x00000001
# flags 0x00000001 = ntuple filters
```

### 4.3 Flow Director 的限制

```
限制 1：规则数量有限
  - Intel i350：8 条规则
  - Intel X540/82599：64 条规则
  - Intel XL710：128 条规则
  - Mellanox mlx5：4K~16K 条规则
  → 不适合海量 flow 的 ACL

限制 2：冲突
  - 如果 flow director 规则和 RSS hash 结果不一致
  - driver 可能无法同时工作
  → 某些 driver 会忽略 RSS，使用 flow director 规则

限制 3：只能做精确匹配
  - 不支持范围匹配（port 8000-9000 需要多条规则）
  - 不支持正则

适用场景：
  - IDS/IPS 把特定流量镜像到监控队列
  - 负载均衡器按用户指定规则分配 queue
  - 把特定高性能 flow 分到专属 queue
```

---

## 5. 固件升级与诊断

### 5.1 为什么升级固件

```
固件 = 网卡自己的软件（跑在网卡芯片上的程序）

固件负责：
  - 网卡初始化
  - 协议处理（TSO/GRO/offload 实现）
  - PHY/MAC 配置
  - RSS hash 计算
  - Flow director 规则
  - 安全漏洞修复

升级固件的理由：
  1. 安全：Intel AMT漏洞、侧信道漏洞（需要补丁固件）
  2. Bug修复：特定包大小丢包、offload bug
  3. 新功能：新的 offload 能力
  4. 性能：提升 GRO 合并效率、降低延迟
  5. 兼容性：新 CPU/新 kernel 支持
```

### 5.2 Mellanox 固件管理

```bash
# 查看固件信息
ethtool -i eth0 | grep firmware

# output：
# firmware-version: 14.32.1010 (stored in FLASH)

# Mellanox flint 工具管理固件
# 安装（CentOS）：
wget http://www.mellanox.com/downloads/ofed/mlnx-ofed-5.50/mlnxofedinstall
./mlnxofedinstall

# 查看固件详情
flint -d /dev/mst/mt4123 q

# 查看可写区（VPD）
flint -d /dev/mst/mt4123 dc

# 升级固件
flint -d /dev/mst/mt4123 -i fw-ConnectX6-rel.mlnx burn

# 参数：
# -i: 新固件文件
# burn: 写入 FLASH（需要 -y 确认）
# -y: 自动确认

# ⚠️ 警告：升级固件有风险，可能导致网卡砖掉
# 1. 确保电源稳定（不要断电）
# 2. 确认固件版本兼容（型号、board ID）
# 3. 备份当前固件：
flint -d /dev/mst/mt4123 r original_fw.mlnx

# 如果升级后有问题，回滚：
flint -d /dev/mst/mt4123 -i original_fw.mlnx burn
```

### 5.3 Intel 固件更新

```bash
# Intel 网卡用 NVMUpdate 工具
# 下载：https://downloadcenter.intel.com/

# 查看当前 NVM 版本
ethtool -i eth0 | grep firmware-version

# NVMUpdate（需要下载对应型号的工具）
# 1. 确认型号：
lspci -nn | grep -i ethernet

# 2. 下载对应工具：
# X550/X540 → NVMUpdatePkg_v18_6.zip
# i350/i210 → NVMUpdatePkg_v16_12.zip

# 3. 解压并运行
./nvmupdate64e -c nvmupdate.cfg
# -c: 配置（自动扫描）

# 4. 更新（需要解冻 NVM）
# 有些 Intel 网卡在启动时 freeze NVM
# 需要先解冻：
echo 1 > /sys/bus/pci/devices/0000:01:00.0/nvm_update

# ⚠️ Intel 固件更新同样有风险
# 正确流程：
#   1. 备份当前 NVM
#   2. 确认新固件与网卡型号匹配
#   3. 断电重插测试
#   4. 在线更新（有些驱动支持热更新）
```

### 5.4 固件诊断

```bash
# 查看网卡诊断信息
ethtool -t eth0

# output：
# The test result is PASS
# The test extra info are do not provided

# 离线测试（更全面，需要 link down）
ethtool -t eth0 offline

# output：
# off line test : pass
# link test : pass
# registers test : pass
# memory test : pass
# EEPROM test : pass

# Mellanox 诊断（mlxspan/mstflint）
mstflint -d /dev/mst/mt4123 q

# output：
# Image type:       FS3
# Device ID:        4099
# Description:      ConnectX-6 Dx
# PSID:             MT_0000000010
# ROM version:      14.32.1010
# Configurations:   Management: yes, Ethernet: yes

# 查看 PCI 链路状态（确认协商速率）
lspci -vvv -s 01:00.0 | grep -E "LnkSta|LnkCap2|LnkSta2"

# output：
# LnkSta: Speed 8GT/s, Width x8, TrErr- Train- SlotClkReq-
# LnkSta2: Current De-emphasis Level: -3.5dB, equalization_complete+

# Speed: 8GT/s x8 = PCIe Gen3 x8 = ~8GT/s（实际 ~7.9GB/s = ~63Gbps）
# 如果 Width x4 → 带宽减半（可能是槽位问题）
```

### 5.5 PCIe 链路问题

```bash
# 查看 PCIe 链路协商状态
lspci -vvv -s 01:00.0 | grep "LnkSta"

# 正常（Gen3 x8）：
# LnkSta: Speed 8GT/s, Width x8, TrErr- ...

# 降级（Gen3 x4）：
# LnkSta: Speed 8GT/s, Width x4, ...
# → 带宽只有一半！

# 降级（Gen2 x8）：
# LnkSta: Speed 5GT/s, Width x8, ...
# → 带宽只有一半，且是 Gen2

# 原因：
#   - 插槽接触不良
#   - 网卡或主板不支持 Gen3
#   - 网卡功耗超过插槽供电能力

# 解法：
#   1. 换插槽
#   2. 更新主板 BIOS
#   3. 确认网卡和主板兼容性
```

---

## 6. 完整调优配置脚本

```bash
#!/bin/bash
# optimize_nic.sh — 网卡完整调优

IFACE=${1:-eth0}
PROFILE=${2:-throughput}  # throughput | latency | balanced

echo "Optimizing $IFACE with profile: $PROFILE"

case $PROFILE in
throughput)
    echo "=== 吞吐量优先 ==="
    # 大 ring buffer
    ethtool -G ${IFACE} rx 4096 tx 4096
    # 适度 coalescing（平衡吞吐和延迟）
    ethtool -C ${IFACE} rx-usecs 100 rx-frames 128
    # 开启所有 offload
    ethtool -K ${IFACE} tso on gso on gro on
    ;;

latency)
    echo "=== 延迟优先 ==="
    # 小 ring buffer
    ethtool -G ${IFACE} rx 256 tx 256
    # 低延迟 coalescing
    ethtool -C ${IFACE} rx-usecs 20 adaptive-rx on
    # 开启 TSO/GSO（分片交给硬件）
    ethtool -K ${IFACE} tso on gso on gro on
    # 关闭 GRO（GRO 增加延迟）
    ethtool -K ${IFACE} gro off
    ;;

balanced)
    echo "=== 平衡模式 ==="
    ethtool -G ${IFACE} rx 2048 tx 2048
    ethtool -C ${IFACE} rx-usecs 50 adaptive-rx on
    ethtool -K ${IFACE} tso on gso on gro on
    ;;
esac

# 确认配置
echo ""
echo "=== 最终配置 ==="
echo "--- Ring Buffer ---"
ethtool -g ${IFACE}
echo "--- Coalescing ---"
ethtool -c ${IFACE} | grep -E "Adaptive|rx-usecs|rx-frames"
echo "--- Offload ---"
ethtool -k ${IFACE} | grep -E "tso|gso|gro" | head -5
echo "--- Status ---"
ethtool ${IFACE} | grep -E "Speed|Duplex|Auto|Link"
```

---

## 7. 小结

```
Ring Buffer（ethtool -G）：
  rx/tx 缓冲区大小
  吞吐优先 → 大（4096）
  延迟优先 → 小（256）

Interrupt Coalescing（ethtool -C）：
  rx-usecs: 等待 N us 后中断
  rx-frames: 凑够 N 帧后中断
  adaptive: 动态调整

Flow Control（ethtool -A）：
  tx/rx pause frame
  存储/HPC 场景用
  互联网/无线场景不用

Flow Director（ethtool -N）：
  硬件 ACL / flow 分流
  规则数有限（几十到几千条）
  适合监控/IDS，不适合海量 ACL

固件：
  Mellanox: flint 工具
  Intel: NVMUpdate
  升级有风险，备份 + 确认型号 + 不断电

调优顺序：
  1. ethtool -l 确认队列数
  2. ethtool -G 调整 ring buffer
  3. ethtool -C 调整 coalescing
  4. ethtool -K 调整 offload
  5. /proc/interrupts 确认 IRQ 分布
  6. iperf3 + nicstat 验证效果
```

---

## 延伸阅读

- `man ethtool` — ethtool -G / -C / -A / -N 选项
- Intel NIC NVMUpdate: https://downloadcenter.intel.com/
- Mellanox Firmware Tools ( flint ): https://docs.nvidia.com/networking/category/firmwaretools
- IEEE 802.3x Pause Frame: https://standards.ieee.org/
- IEEE 802.1Qbb Priority Flow Control: https://1.ieee802.org/
- Kernel doc: `Documentation/networking/flow_control.txt`
