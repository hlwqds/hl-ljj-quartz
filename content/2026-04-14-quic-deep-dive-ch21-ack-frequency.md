---
title: "QUIC 深度探索 ch21 - ACK Frequency 帧"
date: 2026-04-14
description: "深入解析 QUIC ACK Frequency 帧：减少 ACK 开销、ACK decimation、带宽节省、接收端策略、与 ACK Frequency 相关的参数配置"
tags:
  - quic
  - series
  - ack-frequency
  - ack-elision
  - performance
---

# QUIC 深度探索 ch21 - ACK Frequency 帧

> [!tip] 本章内容
> 本章深入剖析 QUIC 的 ACK Frequency 帧（0x0x1a），了解如何通过控制接收方的 ACK 发送频率来减少 ACK 开销、提升带宽利用率，以及 ACK decimation 策略的实现细节。

---

## 1. ACK Frequency 的背景

### 1.1 传统 ACK 机制的问题

在 TCP 和早期 HTTP/3 实现中，接收方每收到一个数据包就立即发送 ACK。这种"每个包都 ACK"的策略存在几个问题：

1. **ACK 带宽浪费**：ACK 包本身占用网络带宽，特别是在高速网络中
2. **CPU 开销**：处理和发送 ACK 需要 CPU 周期
3. **拥塞窗口影响**：在慢启动阶段，频繁的 ACK 会导致 cwnd 快速增长
4. **移动网络问题**：在无线网络上，频繁的 ACK 交互增加耗电

### 1.2 QUIC 的改进

QUIC 引入 ACK Frequency 帧（RFC 9002 定义，但实际在 RFC 9000 之后被细化），允许接收方明确告知发送方："你希望我多久 ACK 一次"。这实现了：

- **发送方驱动**：发送方通过 ACK Frequency 帧告诉接收方"每 N 个包 ACK 一次"
- **带宽节省**：减少 ACK 包数量，节省上行带宽
- **延迟控制**：在延迟敏感场景可以要求更频繁的 ACK

---

## 2. ACK Frequency 帧格式

### 2.1 帧结构

```
ACK Frequency Frame {
  Type          = 0x1a (0b00011010),
  Sequence Num  (i),
  Ack-Eliciting Threshold (i),
  Update Max Ack Delay    (i),
  Ignore Order    (8 bits),
}
```

### 2.2 字段详解

#### Type (1 byte)

`0x1a` 是 ACK Frequency 帧的帧类型。

#### Sequence Number (variable-length integer)

- ACK Frequency 帧的序列号
- 每次发送新的 ACK Frequency 帧，序列号递增
- 用于接收方判断是否是更新的指令

#### Ack-Eliciting Threshold (variable-length integer)

这是最关键的字段：**要求对方在收到多少个 ack-eliciting 包之后发送 ACK**。

- 设置为 1：每个包都 ACK（传统行为）
- 设置为 2：每两个包 ACK 一次
- 设置为更大值：更少的 ACK

**Ack-eliciting 包**：需要对方确认的包，即那些发送后需要收到 ACK 的包。不是所有的包都是 ack-eliciting（例如某些 ACK 本身不需要被确认）。

#### Update Max Ack Delay (variable-length integer)

更新对端的最大 ACK 延迟期望值。这个值影响发送方计算 RTT 时的 offset。

#### Ignore Order (1 byte)

一个标志位：
- `0`：即使包乱序到达，也要发送 ACK
- `1`：乱序到达的包不触发 ACK，只有达到阈值才 ACK

---

## 3. ACK Frequency 工作原理

### 3.1 典型交互流程

```
Sender                              Receiver
   |                                    |
   | --- [STREAM #5] -----------------> |
   | --- [STREAM #6] -----------------> |
   | --- [STREAM #7] -----------------> |
   |                                    |
   | <-- [ACK_FREQUENCY: thresh=3] --- |  发送方请求每3个包ACK一次
   |                                    |
   | --- [STREAM #8] -----------------> |
   | --- [STREAM #9] -----------------> |
   | --- [STREAM #10] ----------------> |
   |                                    |
   | <-- [ACK #10] ------------------- |  收到3个包后ACK一次
   |                                    |
   | .... 重复模式 ....                 |
```

### 3.2 ACK Decimation

**ACK Decimation**（ACK 稀疏化）是指故意减少 ACK 频率的策略。ACK Frequency 帧使得接收方可以主动实施 ACK decimation。

```
传统模式（每包 ACK）：
  数据包:  1  -->   2  -->   3  -->   4  -->   5  -->
  ACK:         <1>      <2>      <3>      <4>      <5>

ACK Decimation（每3包ACK）：
  数据包:  1  -->   2  -->   3  -->   4  -->   5  -->   6  -->
  ACK:                                          <6>

ACK 只在收到第6个包时发送，确认了1-6的所有包
```

### 3.3 带宽节省计算

假设：
- 链路带宽：10 Gbps
- 包大小：1400 bytes
- 每包 ACK：每个数据方向需要 1 个 ACK
- ACK 大小：约 50 bytes（带 ACK Frequency 协商）

**无 ACK Frequency（每包 ACK）**：
```
ACK 带宽开销 = 50 / (1400 + 50) ≈ 3.4%
```

**每 100 包 ACK 一次**：
```
ACK 带宽开销 = 50 / (100 * 1400 + 50) ≈ 0.0036%
```

显著节省了 ACK 方向的带宽。

---

## 4. 发送方如何使用 ACK Frequency

### 4.1 发送策略

发送方根据当前网络状况决定 ACK Frequency 参数：

| 场景 | Ack-Eliciting Threshold | 理由 |
|------|-------------------------|------|
| 慢启动 | 1（每包 ACK） | 需要快速探测带宽 |
| 稳定传输 | 2-10 | 减少 ACK 开销 |
| 高速网络 | 50-100 | ACK 带宽占比高 |
| 延迟敏感 | 1 | 需要快速反馈 |
| 丢包恢复 | 1 | 需要快速检测二次丢包 |

### 4.2 动态调整

发送方可以随时发送新的 ACK Frequency 帧来调整：

```
初始阶段（握手后）：
  ACK_FREQUENCY: thresh=2

探测到高带宽后：
  ACK_FREQUENCY: thresh=50

检测到丢包：
  ACK_FREQUENCY: thresh=1  <- 快速恢复

进入稳态：
  ACK_FREQUENCY: thresh=10
```

---

## 5. 接收方如何处理 ACK Frequency

### 5.1 接收方状态机

```
接收方 ACK 状态机：

状态：WAITING_FOR_PACKETS
  |
  | 收到 ack-eliciting 包
  | packet_count++
  |
  | packet_count >= threshold OR timer_expires
  v
+------------------------+
| SEND_ACK               |
| - 发送 ACK             |
| - packet_count = 0     |
+------------------------+
  |
  v
(返回 WAITING_FOR_PACKETS)
```

### 5.2 定时器约束

除了包计数阈值，接收方还受 `max_ack_delay` 限制：

- 即使没达到包阈值，延迟也不能超过 `max_ack_delay`
- `max_ack_delay` 由发送方通过 ACK Frequency 帧的 `Update Max Ack Delay` 字段更新

```
if (time_since_last_ack >= max_ack_delay):
    send_ack()
```

### 5.3 乱序包处理

`Ignore Order` 标志影响乱序包的处理：

```
Ignore Order = 0（默认）:
  收到乱序包 → 立即发送 ACK（不等待阈值）
  
Ignore Order = 1:
  收到乱序包 → 等待阈值达到才 ACK
```

对于延迟敏感应用，建议 `Ignore Order = 0`。

---

## 6. ACK Frequency 与丢包检测的交互

### 6.1 ACK 频率对丢包检测的影响

减少 ACK 频率会带来一个挑战：**发送方收到 ACK 的速度变慢**，这会影响：

1. **RTT 测量的及时性**：RTT 样点减少
2. **丢包检测速度**：三路 ACK 触发变慢
3. **拥塞控制响应**：cwnd 调整变慢

### 6.2 优化策略

**自适应 ACK Frequency**：

```python
def compute_ack_frequency():
    if loss_detected:
        return 1  # 丢包时，ACK 频率恢复到每包 ACK
    elif pacing_rate > threshold:
        return max(1, pacing_rate // some_value)
    else:
        return default_threshold
```

**带宽延迟积（BDP）考虑**：

```
在高 BDP 链路（卫星、跨洲）：
  - 链路上可能有 100+ 个包在飞行
  - 减少 ACK 不影响丢包检测（飞行包足够多）
  
在低 BDP 链路（数据中心）：
  - 链路上可能只有几个包
  - 减少 ACK 会显著影响检测速度
```

---

## 7. ACK Frequency 与 1-RTT 延迟

### 7.1 RTT 计算的准确性

当 ACK 被延迟时，RTT 测量会受到影响：

```
场景：thresh=10，每 10 个包 ACK 一次

发送包 #1 at T=0
接收包 #10 at T=100ms
发送 ACK at T=100ms

计算 RTT：
  RTT_sample = 100ms - ack_delay_field
  
如果 ack_delay_field = 50ms（对方延迟了 50ms 才发 ACK）：
  RTT_sample = 100ms - 50ms = 50ms  <- 正确

如果 ack_delay_field 报告不准确：
  RTT_sample 会有偏差
```

### 7.2 平滑 RTT 的保护

由于 RTT 样点减少，单个 RTT 异常值的影响更大。QUIC 实现应该：

1. **更多依赖平滑后的 RTT**（`smoothed_rtt`）
2. **过滤异常 RTT 样点**
3. **使用 `min_rtt` 作为下界**

---

## 8. 实际实现注意事项

### 8.1 RFC 9000 vs RFC 9002

ACK Frequency 帧的定义在 RFC 9000 中，但详细的行为规范在 RFC 9002 中。需要注意：

- ACK Frequency 是连接级的设置
- 每个方向的 ACK Frequency 独立设置
- 新连接需要重新协商

### 8.2 与 ACK Range 的关系

ACK Frequency 控制**何时**发送 ACK，而 ACK 帧中的 `ack_range` 字段控制**确认哪些包**：

```
ACK Frame {
  Largest Acknowledged: 100
  ACK Delay: 5ms
  ACK Range: [
    (ack_count=5, gap=0),    # 100-104 确认
    (ack_count=10, gap=5),   # 95-84 确认
    ...
  ]
}
```

ACK Frequency 不影响 ACK Range 的编码。

### 8.3 0-RTT 和 Initial 包

ACK Frequency 帧不能在 0-RTT 包中发送（因为 0-RTT 是在握手完成前发送的早期数据）。Initial 和 Handshake 包的行为由实现决定，通常每个包都需要 ACK。

---

## 9. ACK Frequency 配置示例

### 9.1 保守配置（低延迟优先）

```python
ack_frequency = {
    'thresh': 1,           # 每包 ACK
    'max_ack_delay': 25ms, # 最大 ACK 延迟 25ms
    'ignore_order': False  # 乱序包也 ACK
}
```

适用场景：
- 实时游戏
- 视频会议
- 交互式应用

### 9.2 激进配置（高吞吐优先）

```python
ack_frequency = {
    'thresh': 100,         # 每 100 包 ACK
    'max_ack_delay': 100ms,
    'ignore_order': True   # 乱序包不额外触发 ACK
}
```

适用场景：
- 大文件下载
- 视频流媒体
- 批量数据传输

### 9.3 自适应配置

```python
def adaptive_ack_frequency(state):
    if state.loss_events > 0:
        return {'thresh': 1}
    elif state.bandwidth > 1_Gbps:
        return {'thresh': max(10, state.in_flight // 100)}
    else:
        return {'thresh': 2}
```

---

## 10. 性能对比

### 10.1 吞吐量对比

模拟场景：1 Gbps 链路，包大小 1400 bytes

| ACK 策略 | ACK 包/秒 | ACK 带宽开销 | 有效吞吐 |
|----------|-----------|-------------|----------|
| 每包 ACK | 89,286 | 3.4% | 966 Mbps |
| 每 10 包 ACK | 8,929 | 0.34% | 997 Mbps |
| 每 100 包 ACK | 893 | 0.034% | 999.7 Mbps |

### 10.2 延迟对比

| ACK 策略 | 平均 RTT 反馈延迟 | 丢包检测延迟 |
|----------|------------------|--------------|
| 每包 ACK | 0.5 ms | ~1 RTT |
| 每 10 包 ACK | 5 ms | ~1-2 RTT |
| 每 100 包 ACK | 50 ms | ~2-3 RTT |

在丢包率高的网络中，频繁 ACK 可以更快检测二次丢包。

---

## 11. 小结

ACK Frequency 帧是 QUIC 的一个关键优化：

1. **发送方控制**：发送方通过帧告知接收方期望的 ACK 频率
2. **带宽节省**：减少 ACK 开销，特别是在高速网络中效果显著
3. **灵活性**：可针对不同场景（低延迟/高吞吐）调整策略
4. **丢包检测权衡**：减少 ACK 频率会稍微增加丢包检测延迟

ACK Frequency 帧使得 QUIC 可以在延迟敏感和高吞吐场景之间灵活切换，这是 TCP 无法提供的优化能力。下一章我们将讨论 RTT 估算——这是丢包检测和拥塞控制的基础。
