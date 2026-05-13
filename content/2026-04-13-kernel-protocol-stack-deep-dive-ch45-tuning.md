---
title: "Kernel Protocol Stack 深度探索 (四十五)：网络性能调优"
date: 2026-04-13
tags:
  [
    linux,
    kernel,
    networking,
    series,
    tuning,
    sysctl,
    ring-buffer,
    interrupt-coalescing,
    tcp-congestion,
    buffer-tuning,
  ]
description: "深入解析 Linux 网络性能调优——sysctl 参数、ring buffer 大小、interrupt coalescing、TCP 拥塞控制选择、内存分配优化，以及常见瓶颈的诊断与解决方法"
---

> [!info] Kernel Protocol Stack 深度探索系列 0. [[2026-04-13-kernel-protocol-stack-deep-dive-series-index|全栈学习路径总览]] 44. [[2026-04-13-kernel-protocol-stack-deep-dive-ch44-offload|第四十四章：硬件 offload]] 45. **第四十五章：网络性能调优**

---

## 1. 网络性能调优概述

网络性能调优涉及多个层面：

```
应用层:
  - Socket buffer 大小 (SO_SNDBUF/SO_RCVBUF)
  - 连接复用、零拷贝 (sendfile/splice)
  │
内核层:
  - TCP/UDP 参数 (sysctl)
  - NAPI batch 大小
  - RPS/RFS 配置
  - Memory pressure 配置
  │
设备驱动层:
  - Ring buffer 大小
  - Interrupt coalescing
  - RSS 队列数
  - Offload 开关
  │
硬件层:
  - 网卡型号选择
  - PCIe 带宽/NUMA 位置
  - SR-IOV 配置
```

---

## 2. sysctl 网络参数

### 2.1 TCP 参数

```bash
# 查看所有 TCP 参数
sysctl -a | grep -E '^(net\.ipv4\.tcp|net\.core\.tcp|net\.ipv4\.ip_local)'

# 推荐的调优参数（高带宽场景）
sysctl -w net.core.rmem_max=16777216          # 最大接收 buffer
sysctl -w net.core.rmem_default=16777216       # 默认接收 buffer
sysctl -w net.core.wmem_max=16777216           # 最大发送 buffer
sysctl -w net.core.wmem_default=16777216       # 默认发送 buffer
sysctl -w net.ipv4.tcp_rmem="4096 87380 16777216"   # min/default/max
sysctl -w net.ipv4.tcp_wmem="4096 65536 16777216"   # min/default/max
sysctl -w net.ipv4.tcp_congestion_control=cubic      # 拥塞算法
sysctl -w net.ipv4.tcp_slow_start_after_idle=0       # 空闲后不重置窗口
sysctl -w net.ipv4.tcp_timestamps=1                  # TCP 时间戳
sysctl -w net.ipv4.tcp_sack=1                        # 选择性 ACK
sysctl -w net.ipv4.tcp_window_scaling=1              # 窗口扩大
```

### 2.2 TCP buffer 计算原则

TCP buffer 应该足够大，以充分利用带宽：

```
带宽延迟积 (BDP) = bandwidth * RTT

例如: 10Gbps, RTT=1ms
BDP = 10Gbps * 1ms = 10G * 0.001 = 10Mb = 1.25MB

buffer 建议: BDP ~ 2-4x (考虑丢包重传)
推荐 buffer: 2.5MB - 5MB

如果 RTT 更大（如跨洲际），buffer 需要相应增大
```

### 2.3 连接跟踪与 NAT 参数

```bash
# 连接跟踪表大小（高并发 NAT 场景必须调大）
sysctl -w net.netfilter.nf_conntrack_max=1048576

# 查看当前连接数
cat /proc/sys/net/netfilter/nf_conntrack_count

# 连接跟踪超时（根据协议调整）
sysctl -w net.netfilter.nf_conntrack_tcp_timeout_established=7200
sysctl -w net.netfilter.nf_conntrack_tcp_timeout_time_wait=60
sysctl -w net.netfilter.nf_conntrack_tcp_timeout_close_wait=60
sysctl -w net.netfilter.nf_conntrack_tcp_timeout_fin_wait=60
```

### 2.4 其他关键参数

```bash
# 核心网络参数
sysctl -w net.core.netdev_max_backlog=50000      # RX queue 长度
sysctl -w net.core.somaxconn=65535               # listen() backlog
sysctl -w net.core.busy_poll=50                  # busy polling (低延迟场景)
sysctl -w net.core.busy_read=50                  # busy polling RX
sysctl -w net.core.default_qdisc=fq              # 默认 qdisc (公平队列)
sysctl -w net.ipv4.tcp_no_metrics_save=1         # 不保存连接指标（每次重建）

# IP 层参数
sysctl -w net.ipv4.ip_forward=1                 # 开启转发
sysctl -w net.ipv4.conf.all.rp_filter=0          # 关闭严格反向路径过滤
sysctl -w net.ipv4.conf.default.rp_filter=0
sysctl -w net.ipv4.tcp_syncookies=1             # 抗 SYN flood
```

### 2.5 持久化配置

```bash
# 将配置写入 /etc/sysctl.d/99-network-tuning.conf
cat > /etc/sysctl.d/99-network-tuning.conf << 'EOF'
# TCP Buffer
net.core.rmem_max = 16777216
net.core.rmem_default = 16777216
net.core.wmem_max = 16777216
net.core.wmem_default = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# Connection tracking
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_tcp_timeout_established = 7200

# Core networking
net.core.netdev_max_backlog = 50000
net.core.somaxconn = 65535
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = cubic

# Memory pressure
net.core.rmem_compress = 1
net.core.netdev_budget = 600
EOF

# 应用配置
sysctl -p /etc/sysctl.d/99-network-tuning.conf
```

---

## 3. Ring Buffer 调优

### 3.1 RX/TX Ring Buffer

Ring buffer 是网卡与内核之间的数据缓冲：

```
网卡 DMA ──► RX Ring Buffer (skb 指针数组) ──► NAPI poll ──► 协议栈
协议栈   ──► TX Ring Buffer (skb 指针数组) ──► 网卡 DMA ──► 线缆
```

### 3.2 查看 Ring Buffer 大小

```bash
# 查看当前 ring 大小
ethtool -g eth0

# 输出示例：
# Ring parameters for eth0:
# Pre-set maximums:
# RX:   4096
# RX Mini:  0
# RX Jumbo:  0
# TX:   4096
# Current hardware settings:
# RX:   2048
# TX:   2048
```

### 3.3 调整 Ring Buffer

```bash
# 增大 ring buffer（高吞吐/低延迟场景）
ethtool -G eth0 rx 4096 tx 4096

# 减小 ring buffer（降低延迟，但可能丢包）
ethtool -G eth0 rx 256 tx 256
```

### 3.4 Ring Buffer 与丢包

Ring buffer 满时，新包被丢弃（RX）或应用阻塞（TX）。通过 `ethtool -S` 查看：

```bash
# 查看丢包统计
ethtool -S eth0 | grep -E 'drop|error|miss'

# 关键指标：
# rx_fifo_errors    # RX ring 满导致的丢包
# tx_fifo_errors    # TX ring 满导致的丢包
# rx_missed_errors  # DMA 内存分配失败
# rx_no_dma_resources # SR-IOV 场景下 DMA 资源不足
```

---

## 4. Interrupt Coalescing 调优

### 4.1 什么是 Interrupt Coalescing

Interrupt Coalescing（中断合并）将多个包合并成一次中断，减少中断次数和 CPU 开销：

```
无 coalescing:
  包1 ──► IRQ ──► 包2 ──► IRQ ──► 包3 ──► IRQ
  CPU 处理: 3 次中断

有 coalescing:
  包1 ──► 包2 ──► 包3 ──► (timer expires) ──► IRQ
  CPU 处理: 1 次中断
  代价: 增加延迟
```

### 4.2 ethtool 配置

```bash
# 查看当前的 coalescing 设置
ethtool -c eth0

# 输出示例：
# Coalesce parameters for eth0:
# rx-usecs: 50         # 每 50us 产生一次 RX 中断（或达到 pkts）
# rx-frames: 0         # 0=不使用 frame 计数触发
# tx-usecs: 50
# tx-frames: 0

# 调优：降低延迟
ethtool -C eth0 rx-usecs 20 tx-usecs 20

# 调优：提高吞吐（减少中断）
ethtool -C eth0 rx-usecs 100 rx-frames 128

# 自适应 coalescing（部分网卡支持）
ethtool -C eth0 adaptive-rx on adaptive-tx on
```

### 4.3 Coalescing 参数选择

| 场景              | rx-usecs | 特点                       |
| ----------------- | -------- | -------------------------- |
| **超低延迟**      | 1-10     | 几乎无合并，CPU 负载高     |
| **低延迟**        | 20-50    | 轻微增加延迟，大幅降低 CPU |
| **均衡**          | 50-100   | 典型生产环境               |
| **高吞吐**        | 100-200  | 大量合并，CPU 最省         |
| **bulk transfer** | 200+     | 最大吞吐                   |

---

## 5. TCP 拥塞控制调优

### 5.1 可用拥塞控制算法

```bash
# 查看可用的拥塞控制算法
sysctl net.ipv4.tcp_available_congestion_control

# 输出: reno cubic bbr
# bbr 需要内核编译时启用
```

### 5.2 常见算法对比

| 算法      | 适用场景           | 特点                           |
| --------- | ------------------ | ------------------------------ |
| **cubic** | 通用（默认）       | 丢包驱动，pkt retransmit       |
| **bbr**   | 高带宽高延迟、跨国 | 基于模型，BDP 探测，不依赖丢包 |
| **reno**  | 简单/老系统        | 经典，但效率低                 |
| **htcp**  | 高带宽             | 快速收敛                       |

### 5.3 BBR 配置

```bash
# 启用 BBR
sysctl -w net.ipv4.tcp_congestion_control=bbr
sysctl -w net.core.default_qdisc=fq          # BBR 推荐 FQ qdisc

# BBR 参数调优
sysctl -w net.ipv4.tcp_bbr_low_latency=0     # 吞吐优先

# 查看 BBR 状态
sysctl net.ipv4.tcp_congestion_control
```

### 5.4 高并发连接调优

```bash
# TIME_WAIT 复用
sysctl -w net.ipv4.tcp_tw_reuse=1

# 关闭 sync flood protection（高并发测试时）
sysctl -w net.ipv4.tcp_syncookies=0

# 增加本地端口范围
sysctl -w net.ipv4.ip_local_port_range="1024 65535"

# 增加最大连接跟踪
sysctl -w net.netfilter.nf_conntrack_max=2097152
```

---

## 6. NAPI 与 Softirq 调优

### 6.1 NAPI budget

NAPI poll 的 budget 控制每次软中断处理的最大包数：

```bash
# 查看默认 budget（通常 300）
cat /proc/sys/net/core/netdev_budget

# 增加 budget（高吞吐场景）
sysctl -w net.core.netdev_budget=600
sysctl -w net.core.netdev_budget=1000

# 调整 softirq 时间片
sysctl -w net.core.netdev_weight=64    # 每次 budget 处理更多包
```

### 6.2 CPU 亲和性

```bash
# 将 softirq 绑定到特定 CPU（配合 irqbalance）
# 在 /etc/default/irqbalance 中设置
# IRQBalance 不是禁止，是智能均衡

# 对于 latency 敏感的应用，手动绑定：
# 1. 查看 eth0 的 IRQ
grep eth0 /proc/interrupts | awk '{print $1}' | cut -d: -f1
# 2. 绑定到 CPU 0
echo 1 > /proc/irq/72/smp_affinity
```

### 6.3 busy polling

```bash
# 启用 socket busy polling（极低延迟场景）
sysctl -w net.core.busy_poll=50
sysctl -w net.core.busy_read=50

# 在应用代码中使用
int flag = 50;  // SO_BUSY_POLL
setsockopt(sockfd, SOL_SOCKET, SO_BUSY_POLL, &flag, sizeof(flag));

# 代价：增加 CPU 占用，空闲时也在 polling
```

---

## 7. 内存与 skb 调优

### 7.1 skb 内存压力

```bash
# skb 内存压力配置
sysctl -w net.core.rmem_compress=1         # 压缩 skb 缓存
sysctl -w net.core.netdev_mem_allocator=1  # 使用 slab allocator

# 查看 skb 内存使用
cat /proc/net/sockstat

# 输出示例：
# SOCK: inuse 12345 orphan 0 tw 123 alloc 456 mem 789
```

### 7.2 \_page_pool（RX）

page_pool 是内核 4.6+ 引入的内存分配优化，用于 RX path：

```bash
# page_pool 参数（通过 sysfs，如果驱动支持）
ls /sys/class/net/eth0/device/page_pool/

cat /sys/class/net/eth0/device/page_pool/alloc_stats
cat /sys/class/net/eth0/device/page_pool/ring_stats
```

### 7.3 Memory pressure 与丢包

```bash
# 查看网络层的内存压力
cat /proc/net/netstat | grep -E 'TcpExt Mem|NetDev Rx'

# 查看 socket 内存分配
ss -s

# 输出：
# Total: 534 (kernel 0)
# TCP: 123 (estab 100, closed 10, orphaned 5, synrecv 8)
# 内存: kernel 123456 bytes
```

---

## 8. 性能诊断工具

### 8.1 常用诊断命令

```bash
# 1. 查看网络接口统计
ip -s link show eth0

# 2. 查看详细网卡统计（ethtool -S）
ethtool -S eth0

# 3. 查看 softirq 分布
cat /proc/softirqs | grep NET_RX

# 4. 查看 TCP 状态统计
cat /proc/net/snmp
cat /proc/net/netstat

# 5. 查看连接跟踪表
cat /proc/sys/net/netfilter/nf_conntrack_count
cat /proc/sys/net/netfilter/nf_conntrack_max

# 6. 查看 socket 统计
ss -s
ss -ti src 192.168.1.1
```

### 8.2 性能基准测试

```bash
# 使用 iperf3 测试吞吐
# Server:
iperf3 -s -i 1
# Client:
iperf3 -c <server_ip> -t 30 -P 8

# 使用 netperf 测试延迟
netserver -D
netperf -H <server_ip> -l 10 -t TCP_RR -- -r 100,100

# 使用 pktgen 测试包率（内核自带）
modprobe pktgen
pgset -m eth0
pgset -d eth0
pgset -r 10
pgset -n 1000000000
pgset -s 64
pgset -d <dst_ip>
pgset -t             # 开始发送
```

### 8.3 瓶颈定位流程

```
1. CPU 100% softirq?
   → 检查 RSS/RPS 配置
   → 检查 interrupt coalescing
   → 考虑 XDP/offload

2. 网卡丢包 (ethtool -S rx_drop)?
   → 增加 ring buffer (ethtool -G)
   → 检查 interrupt coalescing (可能太高)
   → 减少 netdev_budget

3. 应用延迟高?
   → 启用 busy polling
   → 使用 SO_ZEROCOPY
   → 调小 socket buffer（减少排队）
   → 考虑 eBPF/XDP

4. TCP 重传多?
   → 检查网络拥塞
   → 更换拥塞控制算法 (bbr)
   → 增加 buffer
   → 检查 MTU/MSS
```

---

## 9. 生产环境推荐配置

### 9.1 高吞吐服务器 (Web 服务器、存储)

```bash
# /etc/sysctl.d/99-high-throughput.conf
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.core.netdev_max_backlog = 50000
net.core.somaxconn = 65535
net.ipv4.tcp_congestion_control = cubic
net.core.default_qdisc = fq
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_timestamps = 1

# Ring buffer
ethtool -G eth0 rx 4096 tx 4096

# Interrupt coalescing
ethtool -C eth0 rx-usecs 50 tx-usecs 50
```

### 9.2 低延迟服务器 (HFT、实时交易)

```bash
# /etc/sysctl.d/99-low-latency.conf
net.core.busy_poll = 50
net.core.busy_read = 50
net.core.netdev_max_backlog = 1000
net.core.somaxconn = 65535
net.ipv4.tcp_low_latency = 1

# 禁用 GRO（低延迟场景 GRO 可能增加延迟）
ethtool -K eth0 gro off

# Interrupt coalescing（极低）
ethtool -C eth0 rx-usecs 10 tx-usecs 10

# Ring buffer（低延迟可能需要更小的 buffer 以减少排队）
ethtool -G eth0 rx 256 tx 256
```

### 9.3 NFV/路由器

```bash
# /etc/sysctl.d/99-nfv.conf
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
net.netfilter.nf_conntrack_max = 2097152
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.core.netdev_max_backlog = 65535

# 启用 RPS（如果 RSS 不足）
for i in /sys/class/net/eth0/queues/rx-*; do
    echo ff > $i/rps_cpus
done

# large MTU（减少分片）
ip link set eth0 mtu 9000
```

---

## 10. 总结

网络性能调优的核心原则：

1. **先测量，后调优**：使用 `ethtool -S`、`/proc/softirqs`、`ss` 等工具定位瓶颈
2. **理解 BDP**：buffer 大小应与带宽延迟积匹配
3. **平衡延迟与吞吐**：interrupt coalescing 越高，吞吐越好但延迟越大
4. **offload优先**：启用 TSO/GRO/RSS 等硬件 offload 是最有效的优化
5. **避免过度调优**：生产环境的默认值通常是合理的，只在有明确瓶颈时才调整

调优顺序建议：**硬件 offload → ring buffer → interrupt coalescing → sysctl 参数 → 应用层优化**
