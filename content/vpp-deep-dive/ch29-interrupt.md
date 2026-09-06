---
title: "VPP 深入探讨 ch29：中断与轮询模式"
date: 2026-04-16 10:39:00
tags: [vpp, interrupt, polling, adaptive, coalescing, dpdk, poll-mode-driver]
description: "深入解析 VPP 中断与轮询模式：interrupt-driven、poll-mode、adaptive、interrupt coalescing 与性能对比"
---

# VPP 深入探讨 ch29：中断与轮询模式

> [!abstract] 核心要点
> VPP 支持多种包接收模式：中断驱动、轮询、adaptive polling。本章深入解析各种模式的原理、配置、适用场景与性能对比。

## 1. 包接收模式概述

### 1.1 三种接收模式对比

```
┌─────────────────────────────────────────────────────────────┐
│                 VPP 包接收模式对比                           │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐  │
│  │              Interrupt-Driven (中断驱动)                │  │
│  │                                                        │  │
│  │  优点: CPU 空闲时功耗低                                  │  │
│  │  缺点: 中断开销大，高吞吐时性能差                        │  │
│  │  适用: 低速链路，轻量负载                                │  │
│  └────────────────────────────────────────────────────────┘  │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐  │
│  │              Poll Mode (轮询模式)                       │  │
│  │                                                        │  │
│  │  优点: 无中断延迟，吞吐高                                │  │
│  │  缺点: CPU 持续占用，功耗高                             │  │
│  │  适用: 高速链路，高吞吐场景                             │  │
│  └────────────────────────────────────────────────────────┘  │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐  │
│  │              Adaptive Poll (自适应轮询)                 │  │
│  │                                                        │  │
│  │  优点: 结合两者优点                                     │  │
│  │  缺点: 配置复杂                                         │  │
│  │  适用: 流量波动大的场景                                 │  │
│  └────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 模式选择决策

| 场景           | 推荐模式  | 原因             |
| -------------- | --------- | ---------------- |
| **< 1 Gbps**   | Interrupt | 低功耗，足够性能 |
| **1-10 Gbps**  | Adaptive  | 平衡功耗与性能   |
| **> 10 Gbps**  | Poll      | 最大吞吐量       |
| **流量波动大** | Adaptive  | 自动适应         |
| **NFV/Cloud**  | Poll      | 稳定低延迟       |

### 1.3 VPP 默认行为

```bash
# VPP 默认使用 Poll Mode（DPDK PMD）
# 因为大多数 NIC 默认配置为 interrupt suppression

# 查看当前中断状态
cat /proc/interrupts | grep -E 'eth|dpdk|vpp'

# 示例输出：
#  IRQ157  eth0-TxRx-0   123456  MSI-X  ...
#  IRQ158  eth0-TxRx-1   234567  MSI-X  ...
#  IRQ159  eth0-TxRx-2   345678  MSI-X  ...
```

## 2. Poll Mode Driver (PMD)

### 2.1 PMD 工作原理

```
┌─────────────────────────────────────────────────────────────┐
│                    Poll Mode Driver 工作流程                 │
│                                                              │
│  Worker Thread:                                             │
│  ┌──────────────────────────────────────────────────────┐   │
│  │                                                      │   │
│  │   while (1) {                                        │   │
│  │     // 1. 检查 RX 描述符                             │   │
│  │     if (desc->status == DESC_DONE) {                 │   │
│  │       // 2. 复制包数据到 mbuf                        │   │
│  │       process_packet(mbuf);                          │   │
│  │       desc->status = DESC_FREE;                      │   │
│  │     }                                               │   │
│  │                                                      │   │
│  │     // 3. 处理 TX 队列                               │   │
│  │     drain_tx_queue();                               │   │
│  │   }                                                 │   │
│  │                                                      │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                              │
│  NIC Hardware:                                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  RX Ring: [D][D][.][.][.][.][.][.]                   │   │
│  │           ↑                  ↑                        │   │
│  │        producer           consumer                    │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 PMD 配置

```bash
# startup.conf 中的 PMD 配置
dpdk {
    no-primary-fallback         # 不使用 primary 模式

    # RX/TX 队列大小
    dev default {
        num-rx-queues 4
        num-tx-queues 4
        rxq-size 1024
        txq-size 1024
    }
}

# 在特定接口上配置
dpdk {
    dev TenGigabitEthernet0/0/0 {
        num-rx-queues 4
        num-tx-queues 4
        rxq-size 2048
        txq-size 2048
    }
}
```

### 2.3 PMD 性能参数

```bash
# 查看 PMD 统计
vppctl show hardware

# 示例输出：
# Interface: TenGigabitEthernet0/0/0
#   driver: i40e
#   RX queues: 4
#   RX desc: 1024 per queue
#   TX queues: 4
#   TX desc: 1024 per queue
#
#   Queue stats:
#   Queue 0: packets=12345678, drops=0, errors=0
#   Queue 1: packets=23456789, drops=10, errors=0
```

### 2.4 队列深度影响

```c
// 队列大小与吞吐关系

typedef struct {
    u32 queue_size;      // 队列深度
    u32 burst_size;      // 批次大小
    u64 throughput;      // 吞吐量 (Mpps)
    u64 latency;         // 延迟 (ns)
    u32 drop_rate;       // 丢包率 (%)
} queue_benchmark_t;

// 基准测试结果
queue_benchmark_t results[] = {
    {256,   32, 12.5,  500,  0.1},
    {512,   64, 14.2,  450,  0.05},
    {1024,  64, 14.8,  420,  0.01},
    {2048,  64, 15.0,  400,  0.0},
};

// 分析：
// - 队列太小：burst 时丢包
// - 队列太大：内存占用高，latency 增加
// - 推荐：1024-2048，平衡性能与资源
```

## 3. Interrupt-Driven 模式

### 3.1 中断机制

```bash
# 启用 MSI-X 中断
# 查看 NIC 中断能力
ethtool -i eth0

# 示例输出：
# driver: i40e
# version: 2.13.12
# firmware-version: 8.4 0x8000a49a
# expansion-rom-version:
# bus-info: 0000:1a:00.0
# supports-statistics: yes
# supports-test: yes
# supports-eeprom-access: yes
# supports-register-dump: yes
# supports-priv-flags: yes

# 查看中断调节
ethtool -c eth0

# 示例输出：
# Coalesce parameters for eth0:
# rx-usecs: 20
# rx-frames: 5
# tx-usecs: 20
# tx-frames: 5
```

### 3.2 中断配置

```bash
# 启用 interrupt-driven 模式（与 poll 模式二选一）

# 方式1: 通过 ethtool 配置
ethtool -C eth0 rx-usecs 100 rx-frames 10

# 方式2: 在 startup.conf 中配置
unix {
    # 禁用 polling，使用中断
    no poll-on-intr
}

# 方式3: 运行时切换
vppctl set interface poll-interrupt TenGigabitEthernet0/0/0 disable
```

### 3.3 中断负载评估

```bash
# 查看中断频率
cat /proc/interrupts | grep -E 'eth0|dpdk0'

# 示例（poll 模式下）：
# CPU0: 12345678 irq/eth0-TxRx-0
# CPU1: 23456789 irq/eth0-TxRx-1

# 计算每包中断数
# 中断数 / 包数 = 每包中断次数

# 如果每包一次中断，说明是纯 interrupt 模式
# 如果中断数 << 包数，说明是 interrupt coalescing

# 监控中断速率
watch -n 1 'cat /proc/interrupts | grep eth0'
```

### 3.4 中断亲和性

```bash
# 配置中断亲和性 - 将特定队列的中断绑定到特定 CPU
# 这需要系统级配置，不在 VPP 控制范围内

# 查看当前中断亲和性
cat /proc/irq/157/smp_affinity

# 设置中断亲和性
echo 1 > /proc/irq/157/smp_affinity_list   # 绑定到 CPU 0-3
echo 2 > /proc/irq/158/smp_affinity_list   # 绑定到 CPU 4-7

# 或者使用 taskset
taskset -c 0-3 -p 157

# 推荐：将 NIC 中断绑定到运行 worker 的 CPU
```

## 4. Interrupt Coalescing

### 4.1 Coalescing 原理

```
┌─────────────────────────────────────────────────────────────┐
│                 Interrupt Coalescing                        │
│                                                              │
│  Without coalescing:           With coalescing:              │
│  ─────────────────────         ──────────────────           │
│  IRQ → packet → IRQ → packet   IRQ → batch → IRQ → batch    │
│  ↑    ↑      ↑    ↑            ↑        ↑     ↑        ↑    │
│  中断  中断   中断  中断         中断     中断   中断     中断  │
│                                                              │
│  Rate: 10M irq/s              Rate: 100K irq/s             │
│                                                              │
│  结论: 合并中断可大幅减少 CPU 中断负载                       │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 Coalescing 参数

```bash
# RX coalescing 参数
ethtool -C eth0 \
    rx-usecs 50 \         # 50us 后触发中断（时间触发）
    rx-frames 32          # 收到 32 帧后触发（帧数触发）

# TX coalescing 参数
ethtool -C eth0 \
    tx-usecs 50 \
    tx-frames 32

# 两种触发方式：
# 1. 时间触发：超过 rx-usecs 未处理
# 2. 帧数触发：累积超过 rx-frames 未处理
# 触发条件：满足任一即触发中断

# 查看当前配置
ethtool -c eth0
```

### 4.3 最优 Coalescing 配置

```c
// 不同场景的推荐 coalescing 配置

typedef struct {
    u32 rx_usecs;    // RX 中断延迟 (us)
    u32 rx_frames;   // RX 帧数阈值
    u32 tx_usecs;    // TX 中断延迟 (us)
    u32 tx_frames;   // TX 帧数阈值
    char *scenario;  // 适用场景
} coalescing_config_t;

coalescing_config_t configs[] = {
    // 低延迟场景
    {10,   1,  10,   1,  "低延迟(< 100us)"},

    // 平衡场景
    {50,   16, 50,   16, "平衡(推荐默认值)"},

    // 高吞吐场景
    {100,  64, 100,  64, "高吞吐"},

    // 超高吞吐
    {200,  256, 200, 256, "极限吞吐"},
};

// 选择建议：
// - 延迟敏感：降低 usecs
// - 吞吐敏感：提高 frames
// - 最佳实践：从 {50, 16} 开始调优
```

### 4.4 动态调整

```bash
# 基于流量动态调整 coalescing
# 需要脚本配合

#!/bin/bash
# adaptive_coalescing.sh

while true; do
    # 获取当前流量
    RX_PPS=$(cat /sys/class/net/eth0/statistics/rx_packets)

    # 计算变化
    if [ $RX_PPS -gt 1000000 ]; then
        # 高流量，减少中断
        ethtool -C eth0 rx-usecs 200 rx-frames 64
    elif [ $RX_PPS -gt 100000 ]; then
        # 中流量，平衡设置
        ethtool -C eth0 rx-usecs 50 rx-frames 16
    else
        # 低流量，降低延迟
        ethtool -C eth0 rx-usecs 10 rx-frames 1
    fi

    sleep 1
done
```

## 5. Adaptive Poll Mode

### 5.1 自适应轮询原理

```
┌─────────────────────────────────────────────────────────────┐
│               Adaptive Poll Mode 状态机                      │
│                                                              │
│   ┌─────────┐  流量 > 阈值   ┌─────────────┐                │
│   │  IDLE   │ ───────────→ │ POLLING_LOW  │                │
│   │ (中断)  │               │  (慢轮询)    │                │
│   └─────────┘               └─────────────┘                │
│        ↑                         │                          │
│        │                         │ 流量 > 阈值               │
│        │                         ↓                          │
│        │                   ┌─────────────┐                  │
│        │ 低流量            │ POLLING_HIGH│                  │
│        └────────────────── │  (快轮询)   │                  │
│                            └─────────────┘                  │
│                                                              │
│   阈值配置:                                                │
│   - enter-polling: 流量 > 10000 pps                         │
│   - exit-polling:  流量 < 1000 pps                          │
│   - polling-interval: IDLE=1s, LOW=10ms, HIGH=100us         │
└─────────────────────────────────────────────────────────────┘
```

### 5.2 Adaptive 配置

```bash
# startup.conf 中的 adaptive 配置
dpdk {
    # 启用 adaptive poll mode
    adaptive-poll on

    # 轮询间隔（纳秒）
    # 高速: 100us = 100000ns
    # 低速: 10ms = 10000000ns
    poll-sleep-us 100000

    # 流量阈值
    adaptive-poll-threshold {
        min-packets 10000      # 进入 polling 的流量阈值
        max-packets 100000     # 完全 polling 的流量阈值
    }
}

# 运行时调整
vppctl set adaptive-poll enable
vppctl set adaptive-poll threshold 10000
vppctl set adaptive-poll sleep-us 100000
```

### 5.3 VPP Adaptive 实现

```c
// VPP adaptive poll 实现

typedef enum {
    ADAPTIVE_IDLE,        // 等待中断
    ADAPTIVE_POLL_SLOW,   // 慢速轮询（低功耗）
    ADAPTIVE_POLL_FAST,   // 快速轮询（高吞吐）
} adaptive_mode_t;

typedef struct {
    adaptive_mode_t  mode;
    u64             last_poll_time;
    u64             poll_interval;     // 轮询间隔（ns）
    u64             idle_threshold;    // 进入 idle 的阈值
    u64             poll_threshold;   // 开始轮询的阈值
    u32             packets_per_sec;   // 当前 pps
} adaptive_poll_main_t;

always_inline void
adaptive_poll_loop (vlib_main_t *vm)
{
    adaptive_poll_main_t *apm = &vm->adaptive_poll;
    u64 now = clib_cpu_time_now();

    // 根据当前模式确定下次轮询时间
    if (apm->mode == ADAPTIVE_IDLE) {
        // 等待中断唤醒或超时
        if (now - apm->last_poll_time > 1e9) { // 1s
            apm->mode = ADAPTIVE_POLL_SLOW;
            apm->poll_interval = 10e6;  // 10ms
        }
    } else if (apm->mode == ADAPTIVE_POLL_SLOW) {
        // 慢速轮询
        if (now - apm->last_poll_time > apm->poll_interval) {
            process_poll_batch(vm);
            apm->last_poll_time = now;
        }

        // 流量持续高，切换到快速轮询
        if (apm->packets_per_sec > apm->poll_threshold) {
            apm->mode = ADAPTIVE_POLL_FAST;
            apm->poll_interval = 100e3; // 100us
        }
    } else if (apm->mode == ADAPTIVE_POLL_FAST) {
        // 快速轮询
        if (now - apm->last_poll_time > apm->poll_interval) {
            process_poll_batch(vm);
            apm->last_poll_time = now;
        }

        // 流量降低，返回慢速或 idle
        if (apm->packets_per_sec < apm->idle_threshold) {
            apm->mode = ADAPTIVE_POLL_SLOW;
            apm->poll_interval = 10e6; // 10ms
        }
    }
}
```

### 5.4 自适应阈值调优

```bash
# 查看自适应模式统计
vppctl show adaptive-poll

# 示例输出：
# Adaptive Poll Status:
#   Mode: POLL_FAST
#   Packets/sec: 150000
#   Poll interval: 100us
#   Last poll: 50us ago
#   Total polls: 1234567890
#   Total interrupts: 1234

# 调优建议：
# - 如果 interrupts 很少 → 流量确实持续高，可固定 poll mode
# - 如果 interrupts 很多 → 流量波动大，adaptive 效果好

# 根据实际测量调整阈值
# 如果流量持续 > 100K pps，考虑固定为 poll mode
vppctl set adaptive-poll threshold min 50000 max 200000
```

## 6. 性能对比分析

### 6.1 延迟对比

```
┌─────────────────────────────────────────────────────────────┐
│                 延迟对比（64B 包）                           │
│                                                              │
│   Mode              Avg Latency   P99 Latency   Max Latency │
│   ──────────────────────────────────────────────────────── │
│   Interrupt (no IC)  5us           20us          100us      │
│   Interrupt (IC)     50us          80us          200us     │
│   Adaptive           15us          40us          150us     │
│   Poll (busy)        5us           10us          30us       │
│                                                              │
│   结论: Poll 模式延迟最低且最稳定                            │
└─────────────────────────────────────────────────────────────┘
```

### 6.2 吞吐对比

```
┌─────────────────────────────────────────────────────────────┐
│                 吞吐对比（10Gbps NIC）                       │
│                                                              │
│   Mode              Throughput   CPU%    Efficiency         │
│   ──────────────────────────────────────────────────────── │
│   Interrupt         4.5 Gbps     15%     0.30 Gbps/CPU      │
│   Poll              9.8 Gbps     85%     0.12 Gbps/CPU      │
│   Adaptive          9.5 Gbps     60%     0.16 Gbps/CPU      │
│                                                              │
│   结论: 高吞吐场景.poll 模式效率最高                          │
└─────────────────────────────────────────────────────────────┘
```

### 6.3 功耗对比

```
┌─────────────────────────────────────────────────────────────┐
│                 功耗对比（相对值）                           │
│                                                              │
│   Mode              Idle Power   Active Power   Score       │
│   ──────────────────────────────────────────────────────── │
│   Interrupt         100%         120%          ★★★★☆       │
│   Poll              100%         180%          ★★★☆☆       │
│   Adaptive          100%         140%          ★★★★★        │
│                                                              │
│   结论: Adaptive 平衡功耗与性能                              │
└─────────────────────────────────────────────────────────────┘
```

### 6.4 选择决策树

```
                    开始
                      │
                      ▼
            ┌─ 吞吐需求 > 10Gbps? ─┐
            │                       │
            ▼ (Yes)                ▼ (No)
        使用 Poll              ┌─ 延迟敏感? ─┐
                               │              │
                               ▼ (Yes)       ▼ (No)
                           Adaptive      ┌─ 流量稳定? ─┐
                                        │              │
                                        ▼ (Yes)       ▼ (No)
                                   Interrupt      Adaptive
```

## 7. 混合模式部署

### 7.1 多接口差异化配置

```bash
# 高速接口使用 poll，低速使用 interrupt

# startup.conf
dpdk {
    # 默认使用 interrupt
    default driver-config interrupt

    # 特定接口配置
    dev TenGigabitEthernet0/0/0 {
        poll-mode              # 10G，使用 poll
        num-rx-queues 4
    }

    dev TenGigabitEthernet0/1/0 {
        interrupt-mode         # 1G，使用 interrupt
        num-rx-queues 1
    }
}
```

### 7.2 动态切换

```bash
# 根据时间切换模式（白天 poll，夜间节能）

#!/bin/bash
# mode_switch.sh

while true; do
    HOUR=$(date +%H)

    if [ $HOUR -ge 8 ] && [ $HOUR -lt 20 ]; then
        # 白天：高性能模式
        vppctl set interface poll-mode TenGigabitEthernet0/0/0 enable
        ethtool -C eth0 rx-usecs 100 rx-frames 64
    else
        # 夜间：节能模式
        vppctl set interface poll-mode TenGigabitEthernet0/0/0 disable
        ethtool -C eth0 rx-usecs 20 rx-frames 5
    fi

    sleep 3600
done
```

### 7.3 Per-core 模式

```c
// 不同 worker 使用不同模式

typedef struct {
    u8   poll_mode_enabled;
    u8   interrupt_enabled;
    u32  queue_id;
    u64  poll_interval;
} worker_config_t;

worker_config_t worker_configs[] = {
    // Worker 0-3: Poll mode，高吞吐
    {1, 0, 0, 100000},   // 100us
    {1, 0, 1, 100000},
    {1, 0, 2, 100000},
    {1, 0, 3, 100000},

    // Worker 4-5: Adaptive，混合负载
    {1, 1, 4, 1000000},   // 1ms，adaptive
    {1, 1, 5, 1000000},

    // Worker 6: Interrupt-only，低优先级
    {0, 1, 6, 0},         // pure interrupt
};
```

## 8. 中断优化实战

### 8.1 常见问题排查

```bash
# 问题1: 中断风暴（interrupt storm）
# 现象：CPU 100%，中断计数极高
# 解决：启用 coalescing

ethtool -C eth0 rx-usecs 50 rx-frames 32

# 问题2: 丢包
# 现象：interface 显示 drops
# 排查：
vppctl show interface TenGigabitEthernet0/0/0
cat /sys/class/net/eth0/statistics/rx_dropped

# 解决：增加队列深度或 coalescing 参数
ethtool -G eth0 rx 2048
ethtool -C eth0 rx-usecs 100 rx-frames 64

# 问题3: 延迟抖动
# 现象：延迟不稳定，标准差大
# 排查：检查 coalescing 参数
# 解决：降低 rx-usecs 或 rx-frames
```

### 8.2 优化脚本

```bash
#!/bin/bash
# optimize_interrupts.sh - 自动优化中断参数

set -e

INTERFACE=${1:-eth0}

echo "=== Interrupt Optimization for $INTERFACE ==="

# 备份当前配置
ethtool -c $INTERFACE > /tmp/ethtool_backup.txt

# 测试不同配置
configs=(
    "10:1 20:1"      # 超低延迟
    "50:16 50:16"    # 平衡
    "100:32 100:32"  # 高吞吐
    "200:64 200:64"  # 极限吞吐
)

best_config=""
best_throughput=0

for config in "${configs[@]}"; do
    IFS=' ' read -r rx tx <<< "$config"

    ethtool -C $INTERFACE rx-usecs ${rx%%:*} rx-frames ${rx##*:} \
                                   tx-usecs ${tx%%:*} tx-frames ${tx##*:}

    sleep 2

    # 测试吞吐
    throughput=$(cat /sys/class/net/$INTERFACE/statistics/rx_bytes)
    sleep 5
    throughput=$((($(cat /sys/class/net/$INTERFACE/statistics/rx_bytes) - throughput) / 5))

    echo "Config $config: $throughput bytes/s"

    if [ $throughput -gt $best_throughput ]; then
        best_throughput=$throughput
        best_config=$config
    fi
done

echo "Best config: $best_config ($best_throughput bytes/s)"

# 应用最佳配置
IFS=' ' read -r rx tx <<< "$best_config"
ethtool -C $INTERFACE rx-usecs ${rx%%:*} rx-frames ${rx##*:} \
                               tx-usecs ${tx%%:*} tx-frames ${tx##*:}
```

### 8.3 监控脚本

```bash
#!/bin/bash
# monitor_poll_mode.sh - 监控轮询效率

INTERFACE=${1:-eth0}

while true; do
    # 获取统计
    rx_packets=$(cat /sys/class/net/$INTERFACE/statistics/rx_packets)
    tx_packets=$(cat /sys/class/net/$INTERFACE/statistics/tx_packets)
    rx_bytes=$(cat /sys/class/net/$INTERFACE/statistics/rx_bytes)

    # 获取中断统计
    irq=$(cat /proc/interrupts | grep $INTERFACE | awk '{print $2}')

    sleep 1

    # 计算速率
    rx_pps=$(( $(cat /sys/class/net/$INTERFACE/statistics/rx_packets) - rx_packets ))
    tx_pps=$(( $(cat /sys/class/net/$INTERFACE/statistics/tx_packets) - tx_packets ))
    rx_bps=$(( $(cat /sys/class/net/$INTERFACE/statistics/rx_bytes) - rx_bytes ))

    # 显示
    clear
    echo "=== $INTERFACE Stats ==="
    echo "RX: $rx_pps pps ($((rx_bps * 8 / 1000000)) Mbps)"
    echo "TX: $tx_pps pps"
    echo "Interrupts: $irq"

    # 判断模式是否合适
    if [ $rx_pps -gt 500000 ]; then
        echo "Mode: Poll (high throughput)"
    elif [ $rx_pps -gt 10000 ]; then
        echo "Mode: Adaptive (moderate)"
    else
        echo "Mode: Interrupt (low load)"
    fi
done
```

## 9. 总结

```
┌─────────────────────────────────────────────────────────────┐
│                 中断与轮询模式总结                            │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐  │
│  │                   模式选择指南                          │  │
│  │                                                        │  │
│  │  < 1 Gbps   → Interrupt (低功耗)                      │  │
│  │  1-10 Gbps  → Adaptive (平衡)                         │  │
│  │  > 10 Gbps  → Poll (最大吞吐)                         │  │
│  │  流量波动大  → Adaptive (自动适应)                     │  │
│  └────────────────────────────────────────────────────────┘  │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐  │
│  │                   关键参数                              │  │
│  │                                                        │  │
│  │  Coalescing:  rx-usecs (50-200), rx-frames (16-64)    │  │
│  │  Adaptive:    阈值 10K-100K pps                         │  │
│  │  Queue:      深度 512-2048                            │  │
│  └────────────────────────────────────────────────────────┘  │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐  │
│  │                   性能优化方向                          │  │
│  │                                                        │  │
│  │  降低延迟:  减少 coalescing 参数                       │  │
│  │  提高吞吐:  增加 poll 比例，禁用中断                   │  │
│  │  降低功耗:  启用 adaptive，夜间切换模式                 │  │
│  └────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

---

> [!tip] 最佳实践
>
> 1. 生产环境根据实际流量选择合适模式
> 2. 高吞吐场景使用 Poll Mode + 大队列
> 3. 流量波动场景使用 Adaptive 自动切换
> 4. Interrupt 模式务必启用 coalescing

> [!warning] 注意事项
>
> - 纯 Interrupt 模式在高吞吐下会导致中断风暴
> - Poll 模式持续占用 CPU，适合独占场景
> - Coalescing 参数需要根据实际流量调优
> - 混合模式部署时注意资源竞争
