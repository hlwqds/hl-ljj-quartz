---
title: ethtool 深度系列 Ch4：统计计数与瓶颈定位
date: 2026-04-17 20:00:00
tags: [Network, ethtool, NIC Statistics, nicstat, ifstat, rx_dropped, tx_dropped, Bottleneck]
description: 深入讲解 ethtool -S 统计计数器、逐字段含义、根因分析、nicstat/ifstat 监控工具，以及建立 NIC 性能基线的实战方法。
---

# ethtool 深度系列 Ch4：统计计数与瓶颈定位

## 1. 统计计数器的分层

```
NIC 统计计数器分三层：

Layer 1: NIC hardware counters（网卡硬件自己统计）
  → ethtool -S eth0 读取
  → rx_packets, rx_bytes, rx_dropped, rx_errors ...

Layer 2: netdev per-queue counters（每个队列的统计）
  → /sys/class/net/eth0/queues/tx-0/tx_packets ...
  → /sys/class/net/eth0/queues/rx-0/rx_packets ...

Layer 3: kernel network stack counters（协议栈统计）
  → /proc/net/snmp（IP/ICMP/TCP/UDP 统计）
  → /proc/net/netstat（详细协议统计）
  → /proc/net/dev（设备收发字节数）

理解分层才能准确诊断：
  rx_dropped 在 ethtool 有值，但在 /proc/net/dev 是 0
  → 说明丢包发生在网卡驱动层，不是 netdev 层
```

---

## 2. ethtool -S 详解

### 2.1 标准统计字段

```bash
# 查看所有统计（字段名因 driver 而异）
ethtool -S eth0

# output（igb 驱动示例）：
# NIC statistics:
#      rx_packets: 1234567890          ← RX 总包数
#      tx_packets: 9876543210          ← TX 总包数
#      rx_bytes: 1234567890000         ← RX 总字节数
#      tx_bytes: 9876543210000         ← TX 总字节数
#      rx_broadcast: 123456            ← 广播包
#      tx_broadcast: 234567
#      rx_multicast: 345678            ← 组播包
#      tx_multicast: 456789
#      rx_errors: 0                    ← RX 总错误数
#      tx_errors: 0                     ← TX 总错误数
#      tx_dropped: 0                   ← TX 丢包数
#      collisions: 0                   ← 半双工冲突次数
#      rx_length_errors: 0            ← 长度错误
#      rx_over_errors: 0               ← RX overrun（buffer 满）
#      rx_crc_errors: 0                ← CRC 校验失败
#      rx_frame_errors: 0             ← 帧对齐错误
#      rx_fifo_errors: 0              ← RX FIFO 错误
#      rx_missed_errors: 0            ← RX 漏收（buffer 满）
#      tx_aborted_errors: 0           ← TX 中止（RST/超时）
#      tx_carrier_errors: 0           ← 载波错误（线缆问题）
#      tx_fifo_errors: 0              ← TX FIFO 错误
#      tx_heartbeat_errors: 0         ← TX 心跳错误
#      tx_window_errors: 0            ← TX 窗口错误
#      rx_long_length_errors: 0       ← 长帧错误（Jumbo）
#      rx_short_length_errors: 0      ← 短帧错误
```

### 2.2 关键诊断字段

| 字段 | 含义 | 正常值 | 异常 → 原因 |
|------|------|--------|------------|
| `rx_dropped` | RX 在 NIC/driver 层丢包 | ≈ 0 | NIC buffer 满 |
| `tx_dropped` | TX 丢包 | ≈ 0 | driver 发送队列满 |
| `rx_over_errors` (or `rx_fifo_errors`) | RX FIFO overrun | 0 | 瞬时流量 > NIC 处理能力 |
| `rx_missed_errors` | RX missed（buffer 满） | 0 | 持续高速流量，buffer 不够 |
| `rx_crc_errors` | CRC 错误 | ≈ 0 | 光纤衰减/网线质量差 |
| `rx_frame_errors` | 帧对齐错误 | ≈ 0 | 物理层干扰 |
| `tx_carrier_errors` | 载波丢失 | 0 | 网线断开/模块损坏 |
| `collisions` | 半双工冲突 | 0 | 双工不匹配（对端强制半双工）|
| `tx_aborted_errors` | TX 中止 | 0 | 过多冲突或接口 down |
| `rx_long_length_errors` | 超长帧 | 0 | 对端发了 > MTU 的帧 |
| `rx_short_length_errors` | 超短帧 | 0 | 对端发了 < 最小帧的帧 |

### 2.3 Mellanox mlx5 统计

```bash
# mlx5 驱动有自己的统计字段
ethtool -S eth0

# output（mlx5）：
# rx_packets: 1234567890
# tx_packets: 9876543210
# rx_bytes: 1234567890000
# tx_bytes: 9876543210000
# rx_buffer_full: 0                    ← RX buffer 满（重要！）
# rx_buffer_mismatch: 0
# rx_crc_errors: 0
# rx_dropped: 0
# tx_dropped: 0
# tx_errors: 0
# link_down_events: 0                ← 链路 down 次数
# lro_aggregated: 12345              ← GRO 合并了多少包
# lro_flushed: 12344                  ← GRO flush 了多少次
# lro_no_desc: 0                      ← GRO 因无 descriptor 失败
# out_of_buffer: 0                    ← 内存分配失败（重要！）
```

### 2.4 Intel i40e 统计

```bash
# i40e 驱动的统计
ethtool -S eth0 | grep -v ": 0$"

# output（只显示非零）：
# rx_packets: 1234567890
# rx_bytes: 9876543210000
# tx_packets: 8765432100
# tx_bytes: 7654321000000
# rx_dropped: 0
# tx_dropped: 0
# rx_errors: 0
# tx_errors: 0
# rx_discards: 0                      ← RX 丢包（重要！）
# rx_discards_no_buffer: 0            ← 因 buffer 不足丢包
# tx_discards: 0
# fd_sb_match: 12345                  ← flow director 命中次数
```

---

## 3. 丢包根因分析

### 3.1 rx_dropped 详解

```
rx_dropped 发生在哪？

NIC 收到包 → DMA 到 RAM → 驱动读取 → softirq → protocol stack

rx_dropped 可能的丢包点：

点 A: NIC 内部 buffer 满
  瞬时流量 > NIC 处理能力 → NIC 丢包
  → 增加 rx ring buffer (ethtool -G)

点 B: DMA 失败（内存不足）
  网卡尝试 DMA，但系统内存不足
  → 查 dmesg | grep "out of memory"

点 C: 驱动层丢包
  驱动在处理中发现问题（skb allocation failed）
  → 查 dmesg | grep "alloc_skb failed"

点 D: RSS queue overflow
  某个 RX queue 满了，其他 queue 空的
  → ethtool -S | grep "rx-0:" 确认哪个 queue 满
  → 增加队列数（ethtool -L）或调整 RSS hash

```

### 3.2 tx_dropped 详解

```
tx_dropped = 发送端丢包

发生原因：

1. socket send buffer 满
   应用 send() → TCP send buffer → driver queue → NIC
   如果应用发送太快，send buffer 满
   → TCP 拥塞控制减慢（这个不丢包）
   → 如果 UDP send buffer 满 → tx_dropped

2. driver TX queue 满
   瞬时发送 > NIC DMA 速度
   → tx_dropped 增加
   → 增加 TX ring buffer (ethtool -G eth0 tx 4096)

3. 网卡 link down
   网线断了，但内核还在发
   → tx_dropped 增加 + tx_carrier_errors 增加
```

### 3.3 丢包定位流程

```bash
# Step 1: 确认丢包在哪个 layer
echo "=== ethtool rx_dropped ===" && ethtool -S eth0 | grep dropped
echo "=== /proc/net/dev rx_dropped ===" && cat /proc/net/dev | grep eth0

# 如果 ethtool 有值，/proc/net/dev 是 0：
# → 丢包发生在 NIC/driver 层（硬丢包）
# 如果两边都有值：
# → 丢包发生在 netdev 层

# Step 2: 查 ring buffer
ethtool -g eth0
# 如果 current RX/TX 接近 maximum → buffer 满导致丢包
# 解法：ethtool -G eth0 rx 4096 tx 4096

# Step 3: 查中断 coalescing
ethtool -c eth0
# 如果 tx-usecs/rx-usecs = 0（关闭 coalescing）
# 瞬时大流量 → 每个包都中断 → CPU 处理不过来 → 丢包
# 解法：开启 coalescing（ethtool -C eth0 rx-usecs 50）

# Step 4: 查 RSS 是否均衡
ethtool -S eth0 | grep "^rx-[0-9]" | sort -t: -k2 -rn | head -5
# 某个 queue 远远高于其他 → hash 不均衡 → 队列溢出
```

### 3.4 监控脚本

```bash
#!/bin/bash
# monitor_nic_stats.sh — 监控 NIC 丢包/错误

IFACE=${1:-eth0}
INTERVAL=${2:-5}

echo "监控 $IFACE，每 ${INTERVAL}s 采样..."
echo "按 Ctrl+C 退出"
echo ""

while true; do
    DATE=$(date +"%Y-%m-%d %H:%M:%S")

    # ethtool -S 抓取
    STATS=$(ethtool -S $IFACE 2>/dev/null)
    RX_PKTS=$(echo "$STATS" | grep "^     rx_packets:" | awk '{print $2}')
    TX_PKTS=$(echo "$STATS" | grep "^     tx_packets:" | awk '{print $2}')
    RX_DROP=$(echo "$STATS" | grep "^     rx_dropped:" | awk '{print $2}')
    TX_DROP=$(echo "$STATS" | grep "^     tx_dropped:" | awk '{print $2}')
    RX_ERR=$(echo "$STATS" | grep "^     rx_errors:" | awk '{print $2}')
    TX_ERR=$(echo "$STATS" | grep "^     tx_errors:" | awk '{print $2}')
    RX_OVER=$(echo "$STATS" | grep "^rx_over_errors:" | awk '{print $2}')

    # 计算 PPS
    echo "[$DATE] RX=$RX_PKTS TX=$TX_PKTS | RX_drop=$RX_DROP TX_drop=$TX_DROP | ERR=$RX_ERR/$TX_ERR"

    # 如果有丢包或错误，打印警告
    if [ "$RX_DROP" != "0" ] || [ "$TX_DROP" != "0" ] || [ "$RX_ERR" != "0" ]; then
        echo "^^^ ⚠️  WARNING: 丢包或错误 detected ^^^"
    fi

    sleep $INTERVAL
done
```

---

## 4. nicstat：NIC 吞吐监控工具

### 4.1 安装与基础使用

```bash
# 安装
# Debian/Ubuntu:
apt install nicstat

# CentOS/RHEL:
yum install nicstat
# 或从源码编译：https://sourceforge.net/projects/nicstat/

# 基础用法（每秒打印一次）
nicstat 1

# output：
# Time      Int     rKB/s   wKB/s   rPk/s   wPk/s   rAvs   wAvs  %Util  Sat
# 10:00:01  eth0    10234.5  2048.3    1200    800    1500  1500    8.2    0.0
# 10:00:02  eth0    10240.0  2048.0    1201    799    1500  1500    8.2    0.0

# 字段解释：
# rKB/s:  RX KB/s
# wKB/s:  TX KB/s
# rPk/s:  RX 包/s（PPS）
# wPk/s:  TX 包/s
# rAvs:   平均 RX 包大小
# wAvs:   平均 TX 包大小
# %Util:  网卡利用率（相对于协商速率）
# Sat:    Saturation（饱和度，0.0=不饱和）
```

### 4.2 常用选项

```bash
# 打印 Mbit/s（而非 KB/s）
nicstat -M 1

# 只看某个接口
nicstat -i eth0 1

# 打印汇总（不按接口分）
nicstat -s 1
# output:
# Time   rKB/s   wKB/s   rPk/s   wPk/s  %Util  Sat
# all    20480.0  4096.0  2400    1600   20.5   0.0

# 持续监控并输出到文件
nicstat 1 >> /var/log/nicstat.log &

# 历史分析（从日志读取）
nicstat -f /var/log/nicstat.log -p

# 打印所有统计（包括 %iid——每接口的 Idle）
nicstat -a 1
```

### 4.3 nicstat 瓶颈判断

```
nicstat 输出判断：

%Util 高（> 80%），Sat = 0：
  → 网卡带宽用满了（正常，高吞吐场景）
  → 解法：换更高速网卡（10G → 25G → 100G）

%Util 不高，Sat > 0：
  → 网卡无法处理当前流量（可能是 CPU 瓶颈）
  → 解法：关闭 offload，增加 CPU 亲和性

%Util 高，Sat 高：
  → 网卡饱和（真的瓶颈在网卡）
  → 解法：
    1. ethtool -S 看丢包
    2. 增加 ring buffer（ethtool -G）
    3. 调整 coalescing（ethtool -C）
    4. 确认 RSS 负载均衡
```

---

## 5. ifstat：实时吞吐监控

### 5.1 安装与使用

```bash
# 安装
# Debian/Ubuntu:
apt install ifstat

# 基本用法（每 1 秒打印一次）
ifstat 1

# output：
#       eth0       eth1
# rKB/s  rKB/s   rKB/s  wKB/s
# 1024.5  0.00    0.00  512.0
# 1025.0  0.00    0.00  510.0
# ...

# 查看所有接口
ifstat -a 1

# 只看 eth0 和 bond0
ifstat -i eth0,bond0 1

# 带宽显示（bits/s 而非 bytes/s）
ifstat -b 1
# eth0       eth1
# kbps       kbps
# 8196.0     0.00
# 8200.0     0.00
```

### 5.2 组合监控

```bash
# nicstat + ifstat + pidstat 组合（全面诊断）
watch -n1 '
echo "=== NIC 吞吐 ===" && nicstat 1 2>/dev/null | head -3;
echo "";
echo "=== softirq ===" && cat /proc/softirqs | grep NET;
echo "";
echo "=== 网卡队列 ===" && ethtool -S eth0 | grep -E "^rx-[0-9]|tx_dropped" | head -10;
'

# 输出：
# === NIC 吞吐 ===
# eth0    2048.0  512.0   1200   600   10.0   0.0
# === softirq ===
# NET_RX: CPU0 1234  CPU1 2345  CPU2 3456  CPU3 4567
# === 网卡队列 ===
# rx-0: 1234567
# rx-1: 2345678
```

---

## 6. /proc/net/snmp 与 netstat

### 6.1 IP/TCP 统计

```bash
cat /proc/net/snmp

# output：
# Ip: Forwarding DefaultTTL InReceives InHdrErrors InAddrErrors ForwDatagrams InUnknownProtos InDiscards InDelivers OutRequests OutDiscards OutNoRoutes ReasmTimeout ReasmOKs ReasmFails ...
# Ip: 1 64 1234567890 0 0 987654 0 0 1234567890 8765432100 0 1000 12345 67890 0
# ...
# Tcp: RtoAlgorithm RtoMin RtoMax MaxConn ActiveOpens PassiveOpens AttemptFails EstabResets CurrEstab InSegs OutSegs RetransSegs InErrs OutRsts
# Tcp: 1 200 120000 -1 123 456 10 5 100 1234567890 9876543210 12345 0 10

# 关键 TCP 字段：
# ActiveOpens:   主动建立的连接数（client）
# PassiveOpens:  被动建立的连接数（server LISTEN）
# AttemptFails:  连接建立失败
# EstabResets:   连接被 RST 重置
# CurrEstab:     当前 ESTABLISHED 连接数
# RetransSegs:   重传段数（重要！）
# InErrs:        入方向错误
# OutRsts:       出方向 RST
```

### 6.2 网络性能关键指标

```
RetransSegs（TCP 重传）：
  正常：< 0.1% 的包
  异常：> 1% → 网络丢包或拥塞

  计算重传率：
    RetransSegs / OutSegs = 重传比例

  排查：
    1. traceroute/mtr 看哪跳丢包
    2. ethtool -S | grep rx_dropped
    3. ping 看 RTT 抖动

CurrEstab（当前 ESTABLISHED）：
  突然变 0 → 服务挂了
  突然很高 → 连接泄漏（没 close）

InDelivers vs InReceives：
  InDelivers ≈ InReceives（差异 = 丢包/错误）
  如果差异大 → 查 InHdrErrors/InDiscards

OutRequests vs OutDiscards：
  OutDiscards 非 0 → 路由有问题
```

### 6.3 netstat 扩展统计

```bash
cat /proc/net/netstat

# 输出两列：一列是名字，一列是值
# 名字和值交替
# 用 awk 解析：

# 打印 TCP 统计
cat /proc/net/netstat | grep TcpExt | awk '{print $1}' | tr '\n' '|'
# 把 key 和 value 对应上
awk 'NR==FNR {keys=$0; next} NR==FNR+1 {for(i=1;i<=NF;i++) print keys[i], "=", $i}' /proc/net/netstat /proc/net/netstat | grep TcpExt

# 找所有非零的 TCP 扩展统计
awk '/TcpExt/ {for(i=1;i<=NF;i++) {getline; if($i!=0) print $1"="$i}}' /proc/net/netstat
```

---

## 7. 实战：建立 NIC 性能基线

### 7.1 基线测试流程

```bash
#!/bin/bash
# nic_baseline.sh — 建立 NIC 性能基线

IFACE=${1:-eth0}
TARGET_IP=${2:-8.8.8.8}

echo "=========================================="
echo "  NIC Performance Baseline for $IFACE"
echo "=========================================="

# 1. 网卡配置
echo -e "\n[1] 网卡配置"
echo "=== ethtool ===" && ethtool $IFACE | grep -E "Speed|Duplex|Auto|Link"
echo "=== Offload ===" && ethtool -k $IFACE | grep -E "on|off" | head -15
echo "=== Ring Buffer ===" && ethtool -g $IFACE
echo "=== Coalescing ===" && ethtool -c $IFACE
echo "=== Queue Num ===" && ethtool -l $IFACE

# 2. 基线统计（清零后测）
echo -e "\n[2] 清零后统计（iperf3 测完后看变化）"
ethtool -S $IFACE | grep -E "dropped|errors|RX|TX" | head -30 > /tmp/before.txt
echo "保存到 /tmp/before.txt"

# 3. 当前队列分布
echo -e "\n[3] 队列统计"
ethtool -S $IFACE | grep -E "^rx-[0-9]" | awk -F': ' '{sum[$1]+=$2} END {for(q in sum) printf "%s: %d\n", q, sum[q]}' | sort

# 4. 软中断分布
echo -e "\n[4] softirq 分布"
cat /proc/softirqs | grep NET | awk '{print $1, $NF}'

# 5. 网卡利用率（用 mpstat 辅助）
echo -e "\n[5] CPU 利用率（参考）"
mpstat -P ALL 1 3 | grep -E "CPU|all" | head -6

# 6. ping 延迟基线
echo -e "\n[6] 延迟基线"
ping -c 20 $TARGET_IP | tail -1

echo -e "\n=========================================="
echo "基线建立完成"
echo "建议：用 iperf3 压测后再运行一遍，对比 ethtool -S 的 dropped/errors"
echo "=========================================="
```

### 7.2 对比分析（压测前后）

```bash
#!/bin/bash
# compare_stats.sh — 对比两次统计

BEFORE=/tmp/before.txt
AFTER=/tmp/after.txt

# 抓取当前状态
ethtool -S eth0 > $AFTER

echo "=== 变化统计 ==="
echo "(格式：指标 = 变化量)"

# 用 diff 对比
diff $BEFORE $AFTER | grep "^<" | while read line; do
    metric=$(echo "$line" | sed 's/< //')
    # 找对应的 AFTER
    after_val=$(grep "$(echo $metric | awk '{print $1}')" $AFTER | awk '{print $2}')
    before_val=$(echo "$metric" | awk '{print $2}')
    metric_name=$(echo $metric | awk '{print $1}')
    echo "$metric_name: $before_val → $after_val (delta=$((after_val - before_val)))"
done

# 关键告警
echo ""
echo "=== 告警 ==="
cat $AFTER | grep -E "dropped:[^0]|errors:[^0]" | while read line; do
    val=$(echo $line | awk '{print $2}')
    if [ "$val" != "0" ]; then
        echo "⚠️  $line"
    fi
done
```

### 7.3 常见瓶颈场景

```
场景 1：吞吐不达标（iperf3 远低于协商速率）
  → 检查 %Util（nicstat）
  → 如果 Util 很低 → CPU 瓶颈（关闭 offload）
  → 如果 Util 很高 → 网卡带宽瓶颈（升级链路）

场景 2：延迟抖动大
  → ethtool -S | grep rx_missed_errors
  → 如果有值 → buffer 不够，丢包导致重传
  → 调大 ring buffer（ethtool -G）

场景 3：单核 CPU 100%，其他核空闲
  → RSS 没工作，或队列数 = 1
  → ethtool -l eth0 看队列数
  → /proc/interrupts 看 IRQ 分布

场景 4：tcp retransmit 高
  → 先确认丢包在哪：ethtool -S | grep rx_dropped
  → 如果 rx_dropped = 0 → 丢包在网络中间（traceroute）
  → 如果 rx_dropped > 0 → 网卡 buffer 满（增加 ring buffer）
```

---

## 8. 小结

```
三层计数器：
  ethtool -S   → NIC + driver 层
  /proc/net/snmp → IP/TCP/UDP 协议栈层
  /proc/net/dev → netdev 层

rx_dropped 根因：
  - NIC buffer 满 → ethtool -G 增大
  - RSS 不均衡 → ethtool -l / -X 调整
  - CPU 处理不过来 → RPS + irq affinity

tx_dropped 根因：
  - send buffer 满（UDP）→ 应用层处理
  - driver TX queue 满 → ethtool -G 增大
  - link down → 检查链路

监控工具：
  nicstat    → %Util + Sat（判断瓶颈在哪）
  ifstat     → 实时 rKB/s / wKB/s
  mpstat     → CPU 利用率（判断 CPU 瓶颈）
  /proc/softirqs → 各 CPU 的 softirq 负载

基线建立：
  清零统计 → 压测 → 对比 → 确认瓶颈方向
```

---

## 延伸阅读

- `man ethtool` — ethtool -S / -g / -C 选项
- nicstat 源码: https://sourceforge.net/projects/nicstat/
- Kernel doc: `Documentation/networking/snmp_counter/` — 各 stat 含义
- Kernel doc: `Documentation/networking/bonding/` — bonding 统计
- `/proc/net/snmp` 和 `/proc/net/netstat` — 各字段详解