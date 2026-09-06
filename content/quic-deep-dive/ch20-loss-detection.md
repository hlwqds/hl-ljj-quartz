---
title: "QUIC 深度探索 ch20 - 丢包检测"
date: 2026-04-14
description: "深入解析 QUIC 的丢包检测机制：Timer-based 检测、ACK 触发检测、Probe Timeout (PTO)、逃逸窗口（Escape Origin）概念，以及丢包与重传的完整状态机"
tags:
  - quic
  - series
  - loss-detection
  - PTO
  - reliability
  - retransmission
---

# QUIC 深度探索 ch20 - 丢包检测

> [!tip] 本章内容
> 本章深入剖析 QUIC 的丢包检测机制，涵盖基于定时器（Timer-based）和基于 ACK 两大类检测方法，Probe Timeout (PTO) 的计算逻辑，逃逸窗口（Escape Origin）概念，以及丢包后重传处理的状态机转换。

---

## 1. QUIC 丢包检测概述

QUIC 继承了 TCP 的核心可靠性设计：检测丢包 → 触发重传。但 QUIC 在丢包检测上做了显著改进：

1. **多机制并行检测**：Timer-based + ACK feedback 双重机制
2. **Packet Number 空间无歧义**：不像 TCP 的 Sequence Number 会循环，QUIC 的 PN 严格递增
3. **明确的三路 ACK 触发**：每个包最多被 ACK 三次，减少 ACK 丢失导致的虚假重传
4. **独立 Packet Number Space**：不同加密阶段的包独立计数

```
QUIC 丢包检测机制：

+----------------------+     +----------------------+
|  Timer-based 检测    |     |   ACK 触发检测       |
|  (PTO Timer)         |     |   (ACK Feedback)     |
+----------------------+     +----------------------+
          |                            |
          v                            v
  - 超时未确认               - 收到更大 PN 的包
  - 触发 probe 重传          - 触发早期重传检测
          |                            |
          +---------------+------------+
                          v
                  +------------------+
                  |   丢包确认        |
                  |   → 重传数据      |
                  +------------------+
```

---

## 2. 基于 Timer 的检测 (Timer-based Detection)

### 2.1 Probe Timeout (PTO)

当一个包发送后，在合理时间内没有收到对应的 ACK，QUIC 会启动 PTO（Probe Timeout）。PTO 不是单纯的重传定时器，而是一个"探测超时"——超时后发送 probe 包来探测对端是否还活着，同时也能确认之前的数据是否被收到。

PTO 计算公式：

```
PTO = max(1.5 * RTT_var + RTT_smooth, min_timer)

其中：
  - RTT_smooth: 平滑后的 RTT 估计值
  - RTT_var: RTT 抖动（variance）
  - min_timer: 最小定时器值（通常 1ms）
```

RFC 9002 推荐的完整公式：

```python
pto = max(1.5 * kGranularity, max(min_rtt, 8 * max_rttvar)) * (1 + count)
```

其中 `count` 是连续超时次数，随超时次数增加 PTO 会指数退避。

### 2.2 PTO 与 TCP Retransmission Timeout 的区别

| 特性         | QUIC PTO             | TCP RTO              |
| ------------ | -------------------- | -------------------- |
| 最小值       | 1ms (kGranularity)   | 200ms-1000ms         |
| 退避策略     | 指数退避             | 指数退避             |
| 检测对象     | 单个包/Packet Number | 单个 Segment         |
| Probe 内容   | 新包或重传包         | 重传最老未确认段     |
| 连接状态影响 | 不直接导致连接关闭   | 连续超时导致连接死亡 |

### 2.3 PTO 触发后的行为

当 PTO 到期：

1. **发送 Probe 包**：可以发送新数据，或重传未确认的数据
2. **记录 PTO 计数**：`count += 1`，影响后续 PTO 计算
3. **不立即判定丢包**：PTO 只触发探测，不直接判定丢包
4. **收到 ACK 后重置**：`count = 0`

```
PTO 触发序列：

Sender                              Receiver
   |                                    |
   | --- [Data Packet #5] -----------> |
   |                                    |
   | .... PTO timer starts ....        |
   |                                    |
   | .... no ACK received ....         |
   |                                    |
   | --- [Probe Packet #6] ------->   |  <- PTO fires, send probe
   |                                    |
   | <---- [ACK #6, cum_ack=5] ------ |  <- ACK confirms #5 arrived
   |                                    |
   PTO count reset to 0                |
```

---

## 3. 基于 ACK 的检测 (ACK-based Detection)

### 3.1 累计确认（Cumulative Acknowledgment）

QUIC 的 ACK 帧携带 `largest_acknowledged`（累计确认的最大 PN）和 `ack_range` 列表。如果接收方收到 PN=n 的包但之前 PN=n-1 的包还没到，QUIC 不会直接确认 n，而是等待 n-1 到达或超时。

这与 TCP 的累计 ACK 类似，但 QUIC 的 Packet Number 空间是有限的，需要注意 `largest_acknowledged` 的语义。

### 3.2 早期重传检测 (Early Retransmit)

当收到一个 PN 远大于最大已确认 PN 的包时，可能意味着中间有包丢失了。

判断条件：

```
if (received_PN > largest_acked + N * reordering_threshold):
    # 触发早期重传
```

其中 N 是当前窗口中未确认包的数量，`reordering_threshold` 默认是 3（RFC 9002）。

### 3.3 丢包阈值检测 (Loss Threshold Detection)

QUIC 在以下条件满足时判定一个包丢失：

```
包 PN = p 丢失，当且仅当：

1. p < largest_acked（包 PN 小于最大已确认 PN）
2. 等待时间 > max(1.5 * RTT, min_timer)
3. 或：收到 3 个其他包的 ACK，且这些包的 PN > p
```

这就是"三路 ACK 触发"规则——如果收到 3 个后续包的 ACK，就能基本确定中间的包确实丢了。

### 3.4 三路 ACK 触发详解

RFC 9002 Section 6.2.1 定义了丢包判定：

```python
def detect_loss(pn):
    # 条件1: 包 PN 小于最大确认 PN
    if pn >= largest_acked:
        return False

    # 条件2: 包的发送时间 < (当前时间 - 逃逸窗口)
    if now - sent_time[pn] <= escape_origin:
        return False

    # 条件3: 收到 kAckPayloadEliding 个 PN > pn 的包的 ACK
    if count_acks_for_pns_greater_than(pn) >= 3:
        return True

    return False
```

---

## 4. 逃逸窗口 (Escape Origin)

逃逸窗口是 QUIC 丢包检测中的一个关键概念：它定义了一个时间窗口，在窗口内的包即使满足其他丢包条件，也不会被判定为丢失。

### 4.1 逃逸窗口的引入原因

网络包可能在网络中延迟（reordering），特别是：

- 多路径传输
- 网络拥塞导致排队
- 中间设备重排

如果仅凭"收到更大 PN 的 ACK"就判定丢包，会导致虚假重传。

### 4.2 逃逸窗口的计算

```
escape_origin = max(ack_delay, max(1.5 * RTT_var, kGranularity))

其中：
  - ack_delay: 对方报告的 ACK 延迟
  - RTT_var: RTT 抖动
  - kGranularity: 时间粒度（1ms）
```

逃逸窗口确保包有足够时间在网络中"绕路"后到达。

### 4.3 逃逸窗口与 PTO 的关系

```
时间线：

T=0: 发送包 PN=5
T=0+escape_origin: 包 PN=5 逃逸窗口结束
T=PTO: 如果还没收到 ACK，触发 PTO

如果 T=0+100ms 收到 PN=8 的 ACK：
  - 检查 PN=5 是否在逃逸窗口外
  - 如果是，且 PN=6,7 也都没确认 -> 判定 PN=5 丢失
```

---

## 5. 重传机制

### 5.1 何时重传

一旦包被判定丢失，QUIC 实现需要决定：

1. **重传相同数据**：在新的 Packet Number 下重传原始数据
2. **只重传头部**：某些情况下只重传头部信息
3. **撤销（Retire）**：如果数据已被上层确认，可以撤销重传

### 5.2 New Packet Number 语义

QUIC 要求重传时使用**新的 Packet Number**，这是与 TCP 的关键区别：

```
TCP 重传：
  Segment #100 (seq=1000) lost
  Retransmit: Segment #100 (seq=1000)  <- 相同 Sequence Number

QUIC 重传：
  Packet #5 (data=...) lost
  Retransmit: Packet #10 (data=...)  <- 新的 Packet Number
```

新 PN 的优势：

- **无歧义**：接收方不会混淆原始包和重传包
- **精确 RTT 测量**：重传包的 ACK 时间可以准确测量
- **避免虚假重传**：TCP 因为重传导致 Sequence Number 重复，容易被中间设备误解

### 5.3 PTO 与重传的关系

```
PTO 触发后的重传决策：

if PTO fires for packet PN:
    if new data to send:
        send new packet with new PN (piggyback lost data)
    else:
        send probe packet (new PN, no data or PING)
    count += 1
```

PTO 触发时，如果有新数据，优先发送新数据并捎带（Piggyback）未确认的数据。

---

## 6. 丢包检测状态机

QUIC 的丢包检测可以建模为一个状态机：

```
状态：Sent(Packet N)
  |
  | 发送 Packet N
  v
+---------------------------+
|  WAITING_ACK              |
|  - 等待 ACK 或判定丢失     |
+---------------------------+
  |
  | 收到 ACK for PN >= N
  | (cumulative or specific)
  v
  [包确认，标记为 delivered]

  |
  | 满足丢包条件：
  | - PN < largest_acked - reordering_threshold
  | - OR count_acks >= 3
  | - OR PTO timeout
  v
+---------------------------+
|  LOST                     |
|  - 标记为丢失             |
|  - 触发重传               |
|  - 通知拥塞控制           |
+---------------------------+
```

---

## 7. ACK 帧与丢包检测的交互

### 7.1 ACK 触发规则

接收方在以下情况必须发送 ACK：

1. **收到乱序包**：包的 PN > expected_PN
2. **所有包**：在 Initial/Handshake 阶段，每个包都要 ACK
3. **1-RTT 阶段**：每收到 2 个包至少 ACK 一个，或等待 ack_delay
4. **ECN 拥塞通知**：收到 CE 标记的包

### 7.2 ACK Delay 与丢包检测

发送方在计算 RTT 和 PTO 时，需要考虑对方的 ACK Delay：

```python
ack_receive_time = now
packet_send_time = ack_delay_field  # 从 ACK 帧中提取

adjusted_rtt = ack_receive_time - packet_send_time - ack_delay
```

如果忽略 ack_delay，会导致 RTT 估计偏大，PTO 过长。

---

## 8. 各 Packet Number Space 的丢包检测

QUIC 有三个独立的 Packet Number Space：

### 8.1 Initial Space

- 每个 Initial 包都必须被 ACK
- 使用固定 RTT 估算（假设 1s 或实际测量）
- Initial 包丢失 → 重传新的 Initial 包（新 PN）

### 8.2 Handshake Space

- Handshake 包确认后，Initial Space 可以丢弃
- Handshake 包丢失 → 触发 PTO，重传 Handshake 包
- 1-RTT 包开始后，Handshake Space 重要性下降

### 8.3 Application Data Space (1-RTT)

- 主要的工作空间
- 丢包检测最复杂，涉及：
  - 三路 ACK 触发
  - PTO 探测
  - 早期重传检测
- 丢包直接影响拥塞控制窗口

---

## 9. 丢包检测与拥塞控制的关系

丢包检测是拥塞控制的触发器：

```
丢包事件
    |
    v
+------------------+
| 拥塞控制响应      |
+------------------+
    |
    +---> 减少拥塞窗口 (CUBIC/Reno)
    +---> 记录拥塞事件
    +---> 可能进入恢复状态
    |
    v
重新计算 cwnd
```

不同的拥塞控制算法对丢包的反应不同：

- **CUBIC/Reno**：丢包 → 乘法减少（MD）cwnd
- **BBR**：丢包 → 降低 pacing rate，但不减少 cwnd
- **Copa**：丢包 → 增加目标延迟

---

## 10. 实际实现注意事项

### 10.1 虚假重传的避免

QUIC 实现需要小心避免虚假重传：

1. **足够的逃逸窗口**：给乱序包足够时间到达
2. **PTO 不能太激进**：PTO 设置过短会导致大量虚假重传
3. **ACK 计数准确性**：确保正确计算后续包的 ACK 数量

### 10.2 丢包检测的性能影响

- **检测太慢**：应用层延迟增加（等待重传）
- **检测太快**：虚假重传浪费带宽
- **PTO 太短**：探测风暴
- **PTO 太长**：恢复延迟

### 10.3 调试丢包检测

抓包时注意以下字段：

```
QUIC packet {
  Header: Packet Number = N
  Frames: [CRYPTO, STREAM, ...]
}

ACK Frame {
  Largest Acknowledged: M
  ACK Delay: value
  ACK Range: [...]
}
```

如果 `M >> N`，且 N 未被确认，可能是丢包了。

---

## 11. 小结

QUIC 的丢包检测机制是其可靠性的核心：

1. **Timer-based (PTO)**：处理完全没有反馈的情况
2. **ACK-based (三路触发)**：利用接收方反馈快速检测
3. **逃逸窗口**：防止虚假重传
4. **New PN 重传**：避免重传歧义

理解丢包检测是理解 QUIC 拥塞控制的基础——下一章我们将讨论如何通过 ACK Frequency 帧优化 ACK 行为，进一步提升检测效率和带宽利用率。
