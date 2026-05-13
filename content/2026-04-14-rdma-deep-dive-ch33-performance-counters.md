---
title: "RDMA 第三十三章：RDMA 性能计数器——PMU、perfmon 与 QoS 监控"
date: 2026-04-14
tags: [rdma, performance-counters, perfmon, PMU, QoS, monitoring, infiniband, roce]
description: "详解 RDMA 性能计数器体系：perfmon 工具、PMU 硬件计数器、端口统计、CQ 填充率、拥塞检测、QoS 带宽监控。"
---

> [!abstract] 核心要点
> RDMA 性能计数器是监控网络健康、诊断拥塞和优化性能的核心数据源。本章介绍 InfiniBand/RoCE 标准计数器体系、perfmon 工具使用、硬件 PMU 事件、以及关键性能指标的解读与应用场景。

---

## 1. 性能计数器体系

### 1.1 计数器层次

```
RDMA 性能计数器层次：

  ┌──────────────────────────────────────────────────────────────┐
  │  应用层计数器 (Software)                                      │
  │    CQ 填充率 | WQE 吞吐 | 往返延迟                           │
  ├──────────────────────────────────────────────────────────────┤
  │  传输层计数器 (Transport)                                     │
  │    Out-of-Seq | RNR NAK | Retransmit                        │
  ├──────────────────────────────────────────────────────────────┤
  │  网络层计数器 (Network)                                       │
  │    DLID | SL | 路由跳数                                       │
  ├──────────────────────────────────────────────────────────────┤
  │  链路层计数器 (Link)                                         │
  │    Symbol Error | Link Down | PFC pause                      │
  ├──────────────────────────────────────────────────────────────┤
  │  硬件 PMU 计数器 (Hardware)                                  │
  │    TX/RX 字节 | Packet | VL 统计                              │
  └──────────────────────────────────────────────────────────────┘
```

### 1.2 标准与厂商支持

- **InfiniBand**: 通过 Subnet Manager 查询端口属性，定义完整的端口计数器集合
- **RoCE/iWARP**: 通过 libibverbs 的 `ibv_query_port()` 获取统计
- **Mellanox**: `perfmon` + `mstflint` 工具，额外提供 ASIC 特有计数器
- **Intel (OmniPath)**: `opaextract` 工具集

---

## 2. perfmon 工具

### 2.1 perfmon 概述

`perfmon` 是 Mellanox OFED 提供的性能监控工具，可以实时读取和显示 RDMA 端口的统计计数器：

```bash
# 列出所有设备
$ perfmon -L

# 读取指定设备的端口计数器
$ perfmon -t mlx5_0

# 读取指定端口（通常是 1）
$ perfmon -t mlx5_0 -p 1

# 连续监控（每 2 秒刷新）
$ perfmon -t mlx5_0 -p 1 -i 2
```

### 2.2 perfmon 输出解读

```
$ perfmon -t mlx5_0 -p 1

Port Counters (mlx5_0:1)
==========================================
LinkWidth:                    4x (Active)
LinkSpeed:                    EDR (25Gb/s per lane)
------------------------------------------ Statistics ----------------------------------
Packets_Tx                     1234567890
Packets_Rx                     9876543210
Bytes_Tx                       1234567890123
Bytes_Rx                       9876543210123
------------------------------------------ Errors --------------------------------------
SymbolErrorCounter                   0
LinkErrorRecoveryCounter             0
PortRcvErrors                       12
PortRcvRemRouteErrors                0
PortXmitDiscards                    45
------------------------------------------ Flow Control ---------------------------------
PriorityXmitPause                    0
PriorityRcvPause                     0
PriorityXmitPauseDuration            0
PriorityRcvPauseDuration             0
------------------------------------------ QoS -----------------------------------------
VL15Dropped                          0
```

### 2.3 关键计数器解读

| 计数器 | 含义 | 健康阈值 |
|--------|------|----------|
| `SymbolErrorCounter` | 物理层符号错误数 | 长期为 0 |
| `LinkErrorRecoveryCounter` | 链路错误恢复次数 | < 10 / day |
| `PortRcvErrors` | 接收错误包数 | 持续增长 = 问题 |
| `PortRcvRemRouteErrors` | 远端路由错误 | = 0 |
| `PortXmitDiscards` | 发送丢弃数 | 持续增长 = 拥塞 |
| `PriorityXmitPause` | PFC 暂停帧发送数 | 反映拥塞程度 |
| `VL15Dropped` | VL15 丢弃数（关键！）| = 0（丢弃说明 PFC 未生效） |

---

## 3. 硬件 PMU 计数器

### 3.1 什么是 PMU

Performance Monitoring Unit (PMU) 是网卡上的专用硬件计数器引擎，可以同时采样多个硬件事件：

```bash
# Mellanox 的 PMU 事件示例
# 通过 perfquery 查询扩展计数器

$ perfquery -L 1 mlx5_0 1        # 读取本地端口计数器
$ perfquery -G 1 mlx5_0 1        # 读取远端端口计数器
```

### 3.2 常用 PMU 事件

```bash
# TX/RX 吞吐量事件
$ perfquery -x 0x11 mlx5_0 1     # PortXmitData
$ perfquery -x 0x12 mlx5_0 1     # PortRcvData
$ perfquery -x 0x13 mlx5_0 1     # PortXmitPackets
$ perfquery -x 0x14 mlx5_0 1     # PortRcvPackets

# 错误相关事件
$ perfquery -x 0x20 mlx5_0 1     # PortRcvErrors
$ perfquery -x 0x28 mlx5_0 1     # PortXmitDiscards

# 拥塞相关事件
$ perfquery -x 0x31 mlx5_0 1     # PortRcvConstraintErrors
$ perfquery -x 0x32 mlx5_0 1     # PortXmitConstraintErrors
```

### 3.3 PMU 采样模式

```bash
# 创建 PMU 采样会话（每 100ms 采样一次）
$ perfmon -c -e tx_bytes,rx_bytes,tx_packets,rx_packets -i 100ms

# 周期性读取（用于 Grafana 等监控）
$ while true; do
    perfquery -x 0x11 mlx5_0 1
    sleep 1
  done | tee throughput.log
```

---

## 4. QoS 监控

### 4.1 QoS 计数器

当 RDMA 网络配置了 QoS（多优先级、ETS），需要监控每个 TC/PG 的统计：

```bash
# Mellanox 工具查看 QoS 统计
$ mst_qos_report -d mlx5_0

# 查看每个优先级队列的统计
$ ethtool -S mlx5_0 | grep prio

# 示例输出：
# tx_prio_0: 1234567890
# tx_prio_1: 987654321
# rx_prio_0: 1111111111
# rx_prio_1: 999999999
```

### 4.2 拥塞检测

拥塞会导致以下计数器持续增长：

```bash
# 检测拥塞的计数器序列

# 1. 交换机端口发送暂停帧（说明下游设备拥塞）
$ perfquery | grep PriorityXmitPause

# 2. 交换机端口发送丢包（缓冲区满）
$ perfquery | grep PortXmitDiscards

# 3. 端到端重试次数
$ perfquery | grep UnicastNumpktsRetrans
$ perfquery | grep MulticastNumpktsRetrans

# 4. RNR (Receiver Not Ready) NAK
$ perfquery | grep RcvRemoteAccessErrors
```

### 4.3 带宽利用率监控

```bash
# 监控链路带宽利用率（通过计数器差分计算）

# 读取起点
$ t1=$(perfquery -x 0x11 mlx5_0 1 | grep -i bytes)

# 等待一秒
$ sleep 1

# 读取终点
$ t2=$(perfquery -x 0x11 mlx5_0 1 | grep -i bytes)

# 带宽(MB/s) = (t2 - t1) / 1024 / 1024

# 或使用 iperf3 测试实际带宽
$ ib_send_bw -d mlx5_0
$ ib_write_bw -d mlx5_0
```

---

## 5. 性能基线与告警

### 5.1 建立性能基线

```bash
# 建立基线（在集群健康时执行）
$ perfquery -G 1 mlx5_0 1 > baseline_healthy_$(date +%Y%m%d).log

# 基线应包含：
# - 无负载时的链路速率
# - 正常错误计数
# - 正常拥塞指标

# 当问题出现时，与基线对比
$ diff baseline_healthy.log current.log
```

### 5.2 关键告警阈值

```
关键指标告警阈值：

  ┌─────────────────────────────────────────────────────────────┐
  │  指标                    告警阈值          严重阈值        │
  ├─────────────────────────────────────────────────────────────┤
  │  SymbolErrorCounter      > 0/day         > 100/day        │
  │  LinkErrorRecovery       > 1/day         > 10/day         │
  │  PortRcvErrors           持续增长         > 1000/hour      │
  │  PortXmitDiscards        持续增长         > 1000/hour      │
  │  VL15Dropped            > 0              > 0              │
  │  PriorityXmitPause       频繁触发         > 10000/min      │
  │  RNRRetryExceeded        频繁触发         > 100/min        │
  └─────────────────────────────────────────────────────────────┘
```

### 5.3 监控脚本示例

```bash
#!/bin/bash
# RDMA 监控脚本（周期性检查）

DEV="mlx5_0"
PORT=1
LOG="/var/log/rdma_monitor.log"

while true; do
    ts=$(date +%Y-%m-%dT%H:%M:%S)

    # 读取关键计数器
    err=$(perfquery -x 0x20 $DEV $PORT 2>/dev/null | awk '/PortRcvErrors/{print $2}')
    disc=$(perfquery -x 0x28 $DEV $PORT 2>/dev/null | awk '/PortXmitDiscards/{print $2}')
    pause=$(perfquery -x 0x35 $DEV $PORT 2>/dev/null | awk '/PriorityXmitPause/{print $2}')

    echo "$ts ERR=$err DISC=$disc PAUSE=$pause" >> $LOG

    # 告警（超过阈值）
    if [ ! -z "$err" ] && [ $err -gt 100 ]; then
        echo "ALERT: PortRcvErrors > 100 on $DEV" | logger -t rdma-alert
    fi

    sleep 60
done
```

---

## 6. 应用层性能监控

### 6.1 CQ 填充率

在应用层，可以通过 Completion Queue 的填充情况判断性能：

```c
// 应用层监控 CQ 填充率
// 监控最佳实践

struct ibv_cq *cq;
struct ibv_comp_channel *ch;

// 设置通知阈值
ibv_req_notify_cq(cq, 0);  // CQ 至少有 1 个条目时通知

// 监控延迟（通过 CQE 时间戳）
struct ibv_wc wc;
uint64_t t1 = get_time_ns();

ibv_poll_cq(cq, 1, &wc);

uint64_t latency_ns = get_time_ns() - t1;
printf("CQ poll latency: %lu ns\n", latency_ns);
```

### 6.2 WQE 未完成计数

```c
// 监控未完成的 Work Request
uint32_t outstanding_wr = atomic_load(&qp->sq.maxOutstanding);

// 当 outstanding_wr 接近上限时，说明吞吐量瓶颈
```

### 6.3 端到端延迟测量

```bash
# 使用 perftest 测量延迟
# 双向延迟测试
$ ib_send_lat -d mlx5_0 -s 64

# RDMA Write 延迟
$ ib_write_lat -d mlx5_0 -s 64

# 使用 rping 测量 socket over RDMA 延迟
$ rping -sv -a 192.168.1.100 -p 12345 &
$ rping -cv -a 192.168.1.100 -p 12345
```

---

## 7. perfmon 高级功能

### 7.1 自定义计数器集

```bash
# 创建自定义计数器集（选择关注的事件）
$ perfmon --create-group MyGroup \
    -e PortXmitData \
    -e PortRcvData \
    -e PortXmitDiscards \
    -e PriorityXmitPause

# 监控这个组
$ perfmon -g MyGroup -t mlx5_0 -i 1

# 保存和恢复配置
$ perfmon --save-config myconfig.txt
$ perfmon --load-config myconfig.txt
```

### 7.2 远端端口统计

```bash
# 通过 SA 查询远端节点的端口统计
$ perfquery -G 1 mlx5_0 1
# -G: 查询远端（通过 GID 索引）

# 结合 ibnetdiscover 获取所有节点 GID
$ ibnetdiscover | grep "Node"
```

### 7.3 历史数据分析

```bash
# 将计数器输出导入时序数据库（如 Prometheus）
# 脚本：收集 perfquery 输出，格式化，推送

#!/bin/bash
for dev in $(ibv_devinfo | grep 'hca_id' | awk '{print $2}'); do
    for port in 1 2; do
        metrics=$(perfquery -t $dev -p $port)
        # 解析并推送至 Prometheus Pushgateway
        push_to_prometheus $dev $port $metrics
    done
done
```

---

## 8. 小结

- **perfmon 是 RDMA 性能监控的核心工具**，提供实时端口统计、错误计数和 QoS 指标
- **关键错误计数器**：SymbolError、LinkErrorRecovery、PortRcvErrors、PortXmitDiscards，任何持续增长都需关注
- **拥塞检测**：PriorityXmitPause 和 VL15Dropped 是 RoCE 拥塞的早期信号
- **PMU 采样**支持细粒度的吞吐量和延迟监控，适合性能调优
- **基线 + 阈值**是监控体系的基础，无基线则无法判断异常