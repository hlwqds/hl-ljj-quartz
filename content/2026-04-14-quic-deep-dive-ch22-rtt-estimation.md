---
title: "QUIC 深度探索 ch22 - RTT 估算"
date: 2026-04-14
description: "深入解析 QUIC 的 RTT 估算机制：RTT 组成成分（min_rtt/smoothed_rtt/rttvar）、RTT 测量方法、ACK Delay 补偿、与拥塞控制的交互"
tags:
  - quic
  - series
  - rtt
  - latency
  - congestion-control
---

# QUIC 深度探索 ch22 - RTT 估算

> [!tip] 本章内容
> 本章深入剖析 QUIC 的 RTT（Round-Trip Time）估算机制，包括 RTT 组成成分、min_rtt/smoothed_rtt/rttvar 的计算公式、ACK Delay 补偿、以及 RTT 在丢包检测和拥塞控制中的应用。

---

## 1. RTT 概述

### 1.1 什么是 RTT

**RTT（Round-Trip Time）** 是网络往返延迟的度量：发送一个数据包到收到对应 ACK 所需的时间。

```
RTT 组成：

Sender                                                            Receiver
   |                                                                  |
   | --- [Data Packet] -----------------------------------------> |
   |                                                                  |
   |                    +---------------------+                      |
   |                    |   网络传输延迟       |                      |
   |                    |   (propagation)     |                      |
   |                    +---------------------+                      |
   |                                                                  |
   |                    +---------------------+                      |
   |                    |   排队/拥塞延迟      |                      |
   |                    |   (queuing)         |                      |
   |                    +---------------------+                      |
   |                                                                  |
   |                                                                  |
   | <-- [ACK] ----------------------------------------------------- |
   |                                                                  |
   |   +---------------------+                                        |
   |   |   ACK 处理延迟      |                                        |
   |   +---------------------+                                        |

RTT = T4 - T1 = 传输延迟 + 排队延迟 + 处理延迟
```

### 1.2 RTT 在 QUIC 中的重要性

RTT 是 QUIC 多个核心机制的基础：

1. **丢包检测**：PTO 和逃逸窗口的计算依赖 RTT
2. **拥塞控制**：慢启动阈值、cwnd 调整都基于 RTT
3. **带宽估算**：BDP = bandwidth × RTT
4. **超时设置**：各种定时器都以 RTT 为参考

---

## 2. RTT 的组成成分

### 2.1 传输延迟 (Transmission Delay)

数据包从发送到接收的时间：

```
transmission_delay = (packet_size) / bandwidth
```

在高速网络中，这个值很小，但在慢速网络（如卫星）中可能很大。

### 2.2 传播延迟 (Propagation Delay)

信号在介质中传播的时间，取决于物理距离和介质：

```
propagation_delay = distance / signal_speed
```

- 光纤：约 200,000 km/s
- 铜线：约 230,000 km/s
- 卫星：约 250-270 ms 单程（地球同步轨道）

### 2.3 排队延迟 (Queuing Delay)

包在中间设备（路由器、交换机）中排队等待的时间：

```
queuing_delay = sum(queuing_time_at_each_hop)
```

这是 RTT 变化的主要来源，也是拥塞的信号。

### 2.4 处理延迟 (Processing Delay)

接收方处理数据包并生成 ACK 的时间：

```
processing_delay = decode_time + crypto_time + ack_generation_time
```

在现代硬件上，这个值通常是微秒级。

---

## 3. RTT 测量方法

### 3.1 基本 RTT 采样

QUIC 通过 ACK 反馈来测量 RTT：

```
RTT_sample = ack_receive_time - packet_send_time
```

但这个值需要调整，因为：
- 发送方不知道对方何时生成 ACK
- ACK 可能被延迟发送（ACK Frequency）
- ACK 路径可能与数据路径不同

### 3.2 ACK Delay 补偿

ACK 帧包含 `ack_delay` 字段，告诉发送方接收方延迟了多久才发送 ACK：

```
adjusted_rtt = RTT_sample - ack_delay
```

这是关键：如果不减去 ACK 延迟，RTT 会被严重高估。

```
Example:

T=0:    发送 Data Packet #5
T=100ms: 接收方收到包
T=150ms: 接收方发送 ACK（延迟了 50ms）
T=200ms: 发送方收到 ACK

RTT_sample = 200ms - 0ms = 200ms
ack_delay = 50ms
adjusted_rtt = 200ms - 50ms = 150ms  <- 真实 RTT

如果不减去 ack_delay：
  RTT = 200ms（高估 33%）
```

### 3.3 多次采样的平滑

单次 RTT 采样有噪声，QUIC 使用以下变量维护平滑的 RTT 估计：

| 变量 | 含义 | 用途 |
|------|------|------|
| `min_rtt` | 观察到的最小 RTT | 网络底噪估计 |
| `smoothed_rtt` | 指数加权移动平均 | 当前 RTT 估计 |
| `rttvar` | RTT 抖动（variance） | RTT 波动程度 |

---

## 4. min_rtt 计算

### 4.1 概念

`min_rtt` 是记录观察到的最小 RTT 值。它代表网络的**底噪**——即使网络完全不拥塞，也不可能低于这个值。

### 4.2 计算规则

```python
min_rtt = min(min_rtt, adjusted_rtt_sample)
```

一旦 `min_rtt` 被设置，它**永远不会增加**（除非通过特定机制重置）。

### 4.3 为什么需要 min_rtt

1. **PTO 计算**：逃逸窗口基于 min_rtt 计算
2. **拥塞检测**：如果当前 RTT 远大于 min_rtt，说明存在拥塞
3. **带宽估计**：可用带宽可能受 min_rtt 限制

### 4.4 min_rtt 的局限性

`min_rtt` 可能在以下情况下过时：
- 网络路径改变（连接迁移）
- 网络条件根本性改变
- 初始测量不准确

解决方案：实现可以定期"衰减"min_rtt，或在检测到路径变化时重置。

---

## 5. smoothed_rtt 计算

### 5.1 指数加权移动平均 (EWMA)

`smoothed_rtt` 使用 EWMA 来平滑 RTT 测量：

```
smoothed_rtt = (1 - alpha) * smoothed_rtt + alpha * sample_rtt

其中 alpha = 0.125（RFC 9002 推荐值）
```

展开后：
```
smoothed_rtt = smoothed_rtt + 0.125 * (sample_rtt - smoothed_rtt)
```

这意味着新样本只影响 12.5%，提供平滑效果。

### 5.2 伪代码实现

```python
def update_smoothed_rtt(rttvar, sample_rtt):
    if first_sample:
        smoothed_rtt = sample_rtt
        rttvar = sample_rtt / 2
    else:
        # RFC 9002 公式
        error = sample_rtt - smoothed_rtt
        smoothed_rtt = smoothed_rtt + (0.125 * error)
        
        # rttvar 也会被更新（见下一节）
        rttvar = rttvar + (0.25 * abs(error) - rttvar)
```

### 5.3 smoothed_rtt 的用途

- **PTO 计算**：`pto = 1.5 * rttvar + smoothed_rtt`
- **拥塞判断**：如果 `current_rtt > 4 * smoothed_rtt`，可能存在拥塞
- **日志和监控**：报告连接质量

---

## 6. rttvar (RTT Variance) 计算

### 6.1 概念

`rttvar`（RTT Variance）是 RTT 的抖动/方差估计。它反映了 RTT 的波动程度。

### 6.2 RFC 9002 公式

```python
rttvar = rttvar + beta * (abs(smoothed_rtt - sample_rtt) - rttvar)

其中 beta = 0.25
```

### 6.3 为什么需要 rttvar

RTT 波动在网络中很常见：
- 路由器队列长度变化
- 无线信号干扰
- 网络拥塞程度变化

`rttvar` 让我们知道 RTT 的"不确定性"，用于：
- **PTO 计算**：更大的 rttvar → 更长的 PTO
- **丢包判定**：RTT 突然变化可能意味着丢包

### 6.4 初始值

第一次测量 RTT 时，RFC 9002 建议：

```python
rttvar = sample_rtt / 2
smoothed_rtt = sample_rtt
```

这样初始 PTO 至少是 1.5 × RTT。

---

## 7. PTO 计算中的 RTT

### 7.1 Probe Timeout (PTO)

PTO 是 QUIC 丢包检测的关键定时器：

```python
# RFC 9002 PTO 计算
pto = max(1.5 * kGranularity, max(min_rtt, 8 * max_rttvar)) * (1 + count)

其中：
  kGranularity = 1ms
  min_rtt = 最小观察 RTT
  max_rttvar = 最大 RTT 抖动（实现可能使用 rttvar）
  count = 连续 PTO 触发次数
```

### 7.2 PTO 退避

每次 PTO 触发后，`count` 增加，PTO 指数退避：

```
count = 0: PTO = base_value
count = 1: PTO = 2 * base_value
count = 2: PTO = 4 * base_value
...
```

### 7.3 RTT 在逃逸窗口中的作用

逃逸窗口（Escape Origin）确保包有足够时间到达：

```python
escape_origin = max(ack_delay, max(1.5 * rttvar, kGranularity))
```

---

## 8. RTT 异常处理

### 8.1 异常值过滤

RTT 样点可能因为以下原因异常：
- ACK 延迟报告不准确
- 网络重排序
- 中间设备干扰

常见过滤策略：

```python
def filter_rtt_sample(sample_rtt):
    # 过滤掉明显不合理的值
    if sample_rtt < min_rtt:
        return None  # 不可能小于 min_rtt
    
    # 过滤掉过大的值（可能是时钟问题）
    if sample_rtt > 100 * min_rtt:
        return None
    
    # 过滤掉与当前估计差异太大的值
    if abs(sample_rtt - smoothed_rtt) > 4 * rttvar:
        return None  # 可能是异常值
    
    return sample_rtt
```

### 8.2 虚假 RTT 样点

在以下情况下，RTT 测量可能不准确：
- ACK Frequency 设置过高（延迟很久才 ACK）
- 数据包和 ACK 走了不同路径
- 负载均衡器导致路径变化

### 8.3 RTT 与拥塞的关系

RTT 突然增加通常是拥塞的信号：

```
正常网络：
  RTT = 20ms ± 5ms（轻微波动）

拥塞开始：
  RTT = 20ms → 50ms → 100ms（持续增长）

丢包即将发生：
  RTT 可能会短暂回落（队列清空）
  然后突然增加到超时阈值
```

---

## 9. RTT 在拥塞控制中的应用

### 9.1 慢启动阈值 (ssthresh)

慢启动阶段，cwnd 以指数速度增长：

```
cwnd += bytes_acked for each ACK
```

何时退出慢启动？
- `cwnd >= ssthresh`，或
- 检测到丢包

`ssthresh` 的初始值可能是：
- 一个固定大值（如 65535 bytes）
- 基于带宽估算：`ssthresh = bandwidth * min_rtt`

### 9.2 CUBIC 中的 RTT

CUBIC 算法使用 RTT 来调整窗口：

```python
# CUBIC 窗口计算
W_cubic(t) = C * (t - K)^3 + W_max

其中 K = cubic_root((W_max * beta) / C)
```

RTT 间接影响 CUBIC——RTT 越大，拥塞响应应该越保守。

### 9.3 BBR 中的 RTT

BBR 使用 RTT 作为**最小延迟的估计**：

```
BBR 算法：
  min_rtt = min(min_rashed_rtt, observed_rtt)
  pacing_rate = cwnd / min_rtt
```

BBR 试图保持 min_rtt 附近的 RTT，远离拥塞区域。

---

## 10. 连接迁移中的 RTT

### 10.1 路径变化检测

当连接迁移发生时（地址变化），RTT 需要重新评估：

1. **PATH_CHALLENGE/RESPONSE**：探测新路径
2. **测量新路径的 RTT**
3. **重置相关状态**

### 10.2 RTT 状态重置

连接迁移后，以下状态可能需要调整：

```python
if path_change_detected:
    # 保留 min_rtt（因为它代表最坏情况）
    # 但要重新评估 smoothed_rtt
    smoothed_rtt = new_measured_rtt
    rttvar = new_measured_rtt / 2
```

### 10.3 迁移期间 RTT 测量

```
T=0: 发送 PATH_CHALLENGE 到新地址
T=50ms: 收到 PATH_RESPONSE
新路径 RTT ≈ 50ms

如果 min_rtt = 20ms（旧路径）：
  新路径 RTT 比 min_rtt 高 30ms
  可能需要调整拥塞参数
```

---

## 11. 实际实现注意事项

### 11.1 时钟精度

QUIC 实现需要高精度的计时：

- **发送时间**：在包发送时记录
- **接收 ACK 时间**：使用系统 monotonic clock
- **精度要求**：最好微秒级，至少毫秒级

### 11.2 ACK 延迟报告

接收方如何决定 `ack_delay`？

```python
def compute_ack_delay():
    # 基于 ACK Frequency 设置
    if ack_frequency_enabled:
        delay = time_since_last_ack
    else:
        delay = 0  # 每包 ACK，无额外延迟
    
    # 但不能超过 max_ack_delay
    delay = min(delay, max_ack_delay)
    
    return delay
```

### 11.3 调试 RTT 问题

抓包时观察：

```
STREAM Frame:
  Stream ID: 0
  Offset: 0
  Length: 1000
  [Sent at T1]

ACK Frame:
  Largest Acknowledged: 5
  Ack Delay: 12ms
  [Received at T2]
  
RTT = T2 - T1 - 12ms
```

---

## 12. 小结

RTT 估算是 QUIC 传输性能的基础：

1. **min_rtt**：网络底噪，永不增加
2. **smoothed_rtt**：EWMA 平滑后的 RTT 估计
3. **rttvar**：RTT 抖动程度
4. **ACK Delay 补偿**：确保 RTT 测量准确

理解 RTT 的各个组成部分对于调试 QUIC 性能和理解丢包检测/拥塞控制至关重要。下一章我们将进入拥塞控制的核心，探讨 CUBIC/Reno 等经典算法。
