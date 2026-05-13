---
title: "DPDK 第三十四章：dpdk-procinfo vs ethtool vs netstat 网络诊断工具对比"
date: 2026-04-09 15:44:00
tags: [dpdk, ethtool, netstat, debugging, network, monitoring]
description: "深入对比 DPDK procinfo、ethtool、netstat 三大网络诊断工具的用法、适用场景与输出解读"
---

# DPDK 第三十四章：dpdk-procinfo vs ethtool vs netstat 网络诊断工具对比

> [!abstract] 核心要点
> 本章对比 Linux 生态中三个核心网络诊断工具：DPDK 自带的 `dpdk-procinfo`、标准网卡工具 `ethtool`、传统网络状态工具 `netstat/ss`。理解各工具的能力边界，才能在调试时选对武器。

## 1. 工具定位概述

| 工具              | 来源       | 定位                   | 适用场景                   |
| ----------------- | ---------- | ---------------------- | -------------------------- |
| **ethtool**       | Linux 内核 | 网卡硬件配置与状态查询 | 物理网卡驱动参数、协商速率 |
| **netstat/ss**    | Linux 内核 | Socket 连接状态        | TCP/UDP 连接数、端口监听   |
| **dpdk-procinfo** | DPDK       | DPDK 端口统计与性能    | DPDK 轮询模式、队列统计    |

**关键区别**：DPDK 应用程序通常**绕过内核网络栈**，因此 `ethtool` 和 `netstat` **看不到** DPDK 端口的流量。

## 2. ethtool 详解

### 2.1 基础用法

```bash
# 查看网卡基本信息
ethtool <interface>

# 示例
ethtool eth0

# 输出示例：
# Settings for eth0:
#     Supported ports: [ TP ]
#     Supported link modes: 1000baseT/Full
#                         10000baseT/Full
#     Supported pause frame use: Symmetric
#     Speed: 10000Mb/s           # 当前速率
#     Duplex: Full               # 双工模式
#     Port: Twisted Pair
#     PHYAD: 0
#     Transceiver: internal
#     Auto-negotiation: on
#     MDI-X: off
#     Supports Wake-on: pumbg
#     Wake-on: d
#     Current message level: 0x00000007 (7)
#     Link detected: yes
```

### 2.2 驱动信息

```bash
# 查看驱动详情
ethtool -i <interface>

# 示例
ethtool -i eth0

# 输出：
# driver: i40e
# version: 3.15.3
# firmware-version: 9.40 0x8000a483
# expansion-rom-version:
# bus-info: 0000:3d:00.0
# supports-statistics: yes
# supports-test: yes
# supports-eeprom-access: s
# supports-register-dump: yes
# supports-priv-flags: yes
```

### 2.3 统计信息

```bash
# 查看详细统计（-S 需要驱动支持）
ethtool -S <interface>

# 示例（Intel i40e 驱动）
ethtool -S eth0

# 输出：
# Statistics for eth0:
#     rx_packets: 1234567890
#     tx_packets: 9876543210
#     rx_bytes: 999999999999
#     tx_bytes: 888888888888
#     rx_errors: 0
#     tx_errors: 0
#     rx_dropped: 1234
#     tx_dropped: 0
#     multicast: 5678
#     collisions: 0
#     rx_length_errors: 0
#     rx_over_errors: 0
#     rx_crc_errors: 0
#     rx_frame_errors: 0
#     rx_fifo_errors: 0
#     rx_missed_errors: 0
#     tx_aborted_errors: 0
#     tx_carrier_errors: 0
#     tx_fifo_errors: 0
#     tx_heartbeat_errors: 0
#     tx_window_errors: 0
```

### 2.4 网卡配置

```bash
# 关闭自动协商
ethtool -s eth0 speed 10000 duplex full autoneg off

# 设置 Wake-on-LAN
ethtool -s eth0 wol g

# 开启端口 rx/tx checksum offload
ethtool -K eth0 rx on tx on

# 查看/设置 ring buffer 大小
ethtool -g eth0
# 接收 ring：
# Pre-set maximums:
# RX:  4096
# RX Mini: 0
# RX Jumbo: 0
# TX:  4096
# Current hardware settings:
# RX:  512
# TX:  512

ethtool -G eth0 rx 1024 tx 1024
```

### 2.5 对 DPDK 端口的限制

```bash
# DPDK 端口绑定到 igb_uio/vfio-pci 后，ethtool 可能无法访问
ethtool eth0
# Cannot get driver information: No such device

# 原因：DPDK 独占了网卡，内核驱动不参与收发包
```

## 3. netstat 详解

### 3.1 基础用法

```bash
# 查看所有连接
netstat -a

# 查看 TCP 连接
netstat -at

# 查看 UDP 连接
netstat -au

# 查看监听端口
netstat -l

# 查看端口对应的进程
netstat -tp

# 显示统计摘要
netstat -s
```

### 3.2 输出解读

```bash
$ netstat -tuln

Active Internet connections (only servers)
Proto Recv-Q Send-Q Local Address           Foreign Address         State
tcp        0      0 0.0.0.0:22              0.0.0.0:*               LISTEN
tcp        0      0 127.0.0.1:631           0.0.0.0:*               LISTEN
tcp        0      0 0.0.0.0:443             0.0.0.0:*               LISTEN
tcp        0      0 0.0.0.0:8080             0.0.0.0:*               LISTEN
udp        0      0 0.0.0.0:68              0.0.0.0:*
udp        0      0 0.0.0.0:4789            0.0.0.0:*

# 字段说明：
# Proto: 协议 (tcp/udp/raw)
# Recv-Q: 接收队列中的字节数
# Send-Q: 发送队列中的字节数
# Local Address: 本地 IP:Port
# Foreign Address: 远端 IP:Port
# State: 连接状态 (LISTEN/ESTABLISHED/等)
```

### 3.3 连接状态统计

```bash
$ netstat -an | awk '/^tcp/ {print $6}' | sort | uniq -c
     12 LISTEN
      1 ESTABLISHED
     45 TIME_WAIT
     23 CLOSE_WAIT

# 快速统计连接数
$ netstat -an | grep ESTABLISHED | wc -l
```

### 3.4 路由表

```bash
# 查看路由表
netstat -r

# Kernel IP routing table
Destination     Gateway         Genmask         Flags   MSS Window  irtt Iface
0.0.0.0         192.168.1.1     0.0.0.0         UG        0 0          0 eth0
192.168.1.0     0.0.0.0         255.255.255.0   U         0 0          0 eth0
```

### 3.5 对 DPDK 的局限性

```bash
# DPDK 应用创建的"连接"不在内核维护
netstat -an | grep 8080
# 如果应用是纯 DPDK 实现，这里看不到

# 只有使用内核网络栈的进程才会出现在 netstat 中
```

## 4. ss 命令（netstat 的现代替代）

### 4.1 基础用法

```bash
# 查看所有连接（比 netstat 快）
ss -a

# 查看 TCP 连接
ss -t

# 查看 UDP 连接
ss -u

# 查看监听端口
ss -l

# 显示进程信息
ss -t -p

# 详细输出
ss -tunapl
```

### 4.2 输出对比

```bash
$ ss -tunapl

Netid  State   Recv-Q  Send-Q   Local Address:Port     Peer Address:Port   Process
tcp    LISTEN  0       128      0.0.0.0:22              0.0.0.0:*           users:(("sshd",pid=1234,fd=3))
tcp    LISTEN  0       511      0.0.0.0:443             0.0.0.0:*           users:(("nginx",pid=5678,fd=6))
tcp    ESTAB   0       0        192.168.1.10:22         192.168.1.100:54321 users:(("sshd",pid=7890,fd=4))
udp    UNCONN  0       0        0.0.0.0:68              0.0.0.0:*           users:(("dhclient",pid=1111,fd=5))
```

### 4.3 高级过滤

```bash
# 查看特定状态
ss state established

# 查看特定端口
ss sport = :443 or dport = :443

# 查看来自特定 IP 的连接
ss src 192.168.1.100

# 内存使用统计
ss -m
```

## 5. dpdk-procinfo 详解

### 5.1 工具定位

`dpdk-procinfo` 是 DPDK 自带的应用程序，用于：

- 查看 DPDK 端口的详细统计
- 分析 lcore 负载分布
- 报告队列级统计
- 支持 `-live` 实时监控

### 5.2 安装与启动

```bash
# 通常在 DPDK 构建目录中
./usertools/dpdk-procinfo.py --help

# 或编译后的二进制
dpdk-procinfo -h
```

### 5.3 基础用法

```bash
# 查看所有 DPDK 端口的统计
sudo ./dpdk-procinfo -m 0a:00.0

# -m: 显示 Mbuf 统计
# 指定 PCI 地址

# 实时监控（默认 5 秒刷新）
sudo ./dpdk-procinfo -- --interactive
```

### 5.4 输出解读

```bash
$ sudo ./dpdk-procinfo -m 0a:00.0

DPDK INFO (03:00.0:0a:00.0)

=== Port 0 stats ===
RX:
  packers: 1,234,567,890
  bytes:   999,999,999,999
  errors:  0
  nombuf:  123                 # Mbuf 耗尽次数
TX:
  packers: 987,654,321,0
  bytes:   888,888,888,888
  errors:  0

=== Queue Stats ===
RX Queue 0:
  desc: 1024 (used: 0)
  bytes: 123,456,789
RX Queue 1:
  desc: 1024 (used: 512)       # 队列深度
  bytes: 456,789,012

TX Queue 0:
  desc: 1024 (used: 0)
  bytes: 789,012,345

=== LCore Stats ===
LCore 0: Running, 0.00% idle
  RX: 1,234,567 pps
  TX: 1,234,567 pps
```

### 5.5 实时监控模式

```bash
# 启动交互模式
sudo ./dpdk-procinfo -- -i

# procinfo> 命令行交互
help                    # 显示帮助
port <id> stats         # 显示端口统计
lcore                   # 显示 lcore 负载
quit                    # 退出

# 指定刷新间隔
sudo ./dpdk-procinfo -- -i --interval=1  # 1秒刷新
```

### 5.6 与 DPDK 应用结合

```bash
# 可以附加到运行中的 DPDK 进程
sudo ./dpdk-procinfo -- \
    --proc-type=auto \
    --file-prefix=myapp \
    -m 0a:00.0

# 输出 JSON 格式（便于脚本处理）
sudo ./dpdk-procinfo -- -m 0a:00.0 --json
```

## 6. 对比总结

### 6.1 功能矩阵

| 功能              | ethtool | netstat/ss | dpdk-procinfo |
| ----------------- | ------- | ---------- | ------------- |
| **物理网卡配置**  | ✅      | ❌         | ❌            |
| **网卡速率/双工** | ✅      | ❌         | ❌            |
| **Ring buffer**   | ✅      | ❌         | ❌            |
| **端口统计**      | ✅      | ❌         | ✅            |
| **TCP/UDP 连接**  | ❌      | ✅         | ❌            |
| **Socket 状态**   | ❌      | ✅         | ❌            |
| **DPDK lcore**    | ❌      | ❌         | ✅            |
| **Mbuf 统计**     | ❌      | ❌         | ✅            |
| **队列深度**      | 部分    | ❌         | ✅            |
| **实时监控**      | ❌      | ❌         | ✅            |

### 6.2 选型指南

```
问题：DPDK 应用性能下降
         │
         ▼
是否使用了内核网络栈？
    │
    ├─ 是 ──► ethtool（检查硬件）+ ss（检查连接）
    │
    └─ 否（DPDK 轮询）──► dpdk-procinfo（检查队列/Mbuf）

问题：连接数异常
         │
         ▼
TCP/UDP 连接？
    │
    ├─ 是 ──► ss -tunapl（快速定位）
    │
    └─ 内核看不到 ──► DPDK 应用内部状态

问题：网卡丢包
         │
         ▼
ethtool -S eth0（看驱动层）
    │
    ├─ errors > 0 ──► 硬件问题
    │
    └─ errors = 0 ──► dpdk-procinfo（看 Mbuf 耗尽）
```

### 6.3 典型诊断流程

```bash
# 场景：网络应用吞吐量突然下降

# 1. 先用 ss 快速检查连接状态
ss -s
# 输出：Estab: 1000, TimeWait: 5000

# 2. 检查是否是内核瓶颈
netstat -s | grep -i error

# 3. 用 ethtool 检查物理网卡
ethtool -S eth0
# 看到 rx_errors, rx_dropped

# 4. 如果是 DPDK 应用，用 dpdk-procinfo
sudo ./dpdk-procinfo -m 0a:00.0
# 看到 nombuf > 0，说明 Mbuf pool 太小

# 5. 结合判断：
# - ss 显示连接正常
# - ethtool 无 errors
# - dpdk-procinfo nombuf > 0
# 结论：Mbuf pool 配置不足
```

## 7. 脚本集成示例

### 7.1 定期监控脚本

```bash
#!/bin/bash
# monitor.sh - 定期监控网络状态

INTERVAL=5
LOGFILE="/var/log/network_monitor.log"

while true; do
    echo "=== $(date) ===" >> $LOGFILE

    # ethtool 统计
    ethtool -S eth0 >> $LOGFILE 2>&1

    # ss 连接统计
    ss -s >> $LOGFILE

    # 如果有 DPDK 端口，也检查
    if command -v dpdk-procinfo &> /dev/null; then
        sudo ./usertools/dpdk-procinfo.py -m 0a:00.0 >> $LOGFILE 2>&1
    fi

    sleep $INTERVAL
done
```

### 7.2 告警脚本

```bash
#!/bin/bash
# alert.sh - 异常告警

# 检查 DPDK Mbuf 耗尽
NOMBUF=$(sudo ./dpdk-procinfo -m 0a:00.0 2>/dev/null | \
         grep "nombuf" | awk '{print $2}')

if [ "$NOMBUF" -gt 100 ]; then
    echo "ALERT: Mbuf exhaustion detected: $NOMBUF" | \
        mail -s "DPDK Alert" admin@example.com
fi

# 检查网卡 errors
ETH_ERRORS=$(ethtool -S eth0 2>/dev/null | grep errors | awk '{sum+=$2} END {print sum}')
if [ "$ETH_ERRORS" -gt 0 ]; then
    echo "ALERT: NIC errors: $ETH_ERRORS" | \
        mail -s "NIC Alert" admin@example.com
fi
```

## 8. 总结

| 工具              | 核心能力                         | 使用时机             |
| ----------------- | -------------------------------- | -------------------- |
| **ethtool**       | 物理网卡配置、协商参数、硬件统计 | 链路故障、速率异常   |
| **netstat/ss**    | Socket 连接、端口监听、路由      | 连接数异常、端口冲突 |
| **dpdk-procinfo** | DPDK 队列、lcore、Mbuf           | DPDK 应用性能问题    |

**最佳实践**：三个工具配合使用，先用 `ss` 快速定位网络层，再用 `ethtool` 检查物理层，最后用 `dpdk-procinfo` 深入 DPDK 内部。

---

## 参考资源

- [ethtool 手册](https://www.kernel.org/pub/software/network/ethtool/)
- [ss 命令详解](https://www.firewall.cx/linux-toolkit/networking-tools/linux-ss-command.php)
- [dpdk-procinfo 官方文档](https://doc.dpdk.org/guides/tools/proc_info.html)
