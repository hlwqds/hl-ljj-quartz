---
title: "QUIC 深度探索 ch23 - 拥塞控制概述"
date: 2026-04-14
description: "深入解析 QUIC 拥塞控制基础：慢启动（Slow Start）、拥塞避免（Congestion Avoidance）、CUBIC/Reno 算法、PRR（Proportional Rate Reduction）"
tags:
  - quic
  - series
  - congestion-control
  - cwnd
  - cubic
  - reno
  - slow-start
---

# QUIC 深度探索 ch23 - 拥塞控制概述

> [!tip] 本章内容
> 本章系统讲解 QUIC 拥塞控制的核心概念：拥塞窗口（cwnd）、慢启动、拥塞避免、CUBIC/Reno 算法、以及丢包后的恢复机制 PRR。

---

## 1. 拥塞控制概述

### 1.1 什么是拥塞

网络拥塞发生在**发送速率超过网络承载能力**时。中间路由器会：

- 丢弃数据包
- 增加排队延迟
- 导致链路利用率下降

```
拥塞示意图：

Sender                    Router                    Receiver
   |                         |                         |
   | ====== (100 Mbps) ======>|                         |
   |                         | ====== (10 Mbps) ======>|
   |                         |                         |
   |                         | [Buffer Full]          |
   |                         | [Dropping packets...]   |
   |                         |                         |
```

### 1.2 拥塞控制的目标

拥塞控制算法的目标：

1. **充分利用带宽**：尽量填满管道
2. **避免拥塞**：不让网络过载
3. **公平共享**：多个流公平竞争带宽
4. **快速响应**：检测变化并适应

### 1.3 拥塞控制 vs 流量控制

| 机制     | 控制目标       | 控制方 | 基于                 |
| -------- | -------------- | ------ | -------------------- |
| 拥塞控制 | 避免网络过载   | 发送方 | 网络反馈（丢包/RTT） |
| 流量控制 | 避免接收方过载 | 接收方 | 接收缓冲区           |

QUIC 同时实现了两种机制：

- **流量控制**：通过 MAX_DATA / MAX_STREAM_DATA（连接级和流级）
- **拥塞控制**：通过 cwnd 限制飞行中的数据量

---

## 2. 拥塞窗口 (cwnd)

### 2.1 概念

**拥塞窗口（cwnd）** 是发送方维护的一个变量，表示"在获得新 ACK 之前可以发送多少数据"。

```
飞行中的数据 (in-flight) = 已发送但未确认的数据

约束条件：
  in-flight <= cwnd
  in-flight <= receive_window (流量控制)
```

### 2.2 cwnd 与发送速率

发送速率大致等于：

```
sending_rate ≈ cwnd / RTT
```

如果 cwnd = 100 KB，RTT = 50 ms：

```
sending_rate = 100 KB / 50ms = 2 MB/s = 16 Mbps
```

### 2.3 cwnd 调整

cwnd 会根据网络状况动态调整：

- **增加**：网络正常，无丢包
- **减少**：检测到丢包或其他拥塞信号

```
拥塞窗口调整示意：

cwnd
  ^
  |            / 慢启动 (指数增长)
  |           /
  |          /
  |         /
  |--------
  |         \ 拥塞避免 (线性增长)
  |          \
  |           \
  +-------------------------> 时间
           ^
           |
        丢包发生，cwnd 减少
```

---

## 3. 慢启动 (Slow Start)

### 3.1 为什么需要慢启动

如果发送方一开始就以最大速率发送，会导致网络瞬间过载。慢启动让发送方"试探"网络容量，逐步增加速率。

### 3.2 RFC 9002 慢启动算法

```python
def slow_start(acked_bytes):
    if cwnd < ssthresh:
        # 慢启动阶段：每个 ACK 增加一个 MSS
        cwnd += acked_bytes
    else:
        # 进入拥塞避免
        congestion_avoidance(acked_bytes)
```

等价于：

```
cwnd += MSS for each ACK received
```

如果每个 ACK 确认一个 MSS（MSS = Max Segment Size），则：

- 1 个 RTT 内，cwnd 加倍
- cwnd 呈指数增长

### 3.3 慢启动终止条件

慢启动在以下情况终止：

1. `cwnd >= ssthresh`
2. 检测到丢包

### 3.4 慢启动示例

```
初始：cwnd = 1 MSS, ssthresh = 10 MSS

RTT 1: 发送 1 MSS, 收到 1 ACK → cwnd = 2 MSS
RTT 2: 发送 2 MSS, 收到 2 ACKs → cwnd = 4 MSS
RTT 3: 发送 4 MSS, 收到 4 ACKs → cwnd = 8 MSS
RTT 4: 发送 8 MSS, 收到 8 ACKs → cwnd = 10 MSS (达到 ssthresh)
RTT 5: 进入拥塞避免
```

---

## 4. 拥塞避免 (Congestion Avoidance)

### 4.1 拥塞避免算法

当 cwnd 达到 ssthresh 后，进入拥塞避免阶段：

```python
def congestion_avoidance(acked_bytes):
    # 每个 RTT 只增加约 1 MSS
    cwnd += MSS * acked_bytes / cwnd
```

这意味着 cwnd 呈**线性增长**，而不是指数增长。

### 4.2 为什么线性增长

进入拥塞避免意味着网络已经接近饱和。线性增长可以：

- 更精细地探测带宽上限
- 避免突然的拥塞

---

## 5. 丢包响应：乘法减少 (Multiplicative Decrease)

### 5.1 丢包检测后的行为

当检测到丢包时，QUIC 拥塞控制会：

```python
if loss_detected:
    ssthresh = cwnd * beta
    cwnd = initial_cwnd  # 或 ssthresh
```

其中 `beta` 通常是 0.5（TCP Reno）或 0.7（CUBIC）。

这就是**乘法减少（Multiplicative Decrease, MD）**：

- cwnd 突然减少到某个值
- 然后重新开始慢启动或拥塞避免

### 5.2 CUBIC vs Reno 的区别

| 特性       | Reno     | CUBIC          |
| ---------- | -------- | -------------- |
| MD 因子    | 0.5      | 0.7            |
| 恢复策略   | 快速恢复 | CUBIC 窗口函数 |
| 稳定性     | 一般     | 更好（更平滑） |
| 带宽利用率 | 较低     | 较高           |

---

## 6. CUBIC 算法

### 6.1 CUBIC 背景

CUBIC（TCP CUBIC）是 Linux 默认的 TCP 拥塞控制算法，比 Reno 更适合高带宽网络。

核心思想：

- 丢包后快速减少 cwnd
- 然后用 CUBIC 函数缓慢增长
- 到达 Wmax 后再次降低（如果继续丢包）

### 6.2 CUBIC 窗口函数

```
W(t) = C * (t - K)^3 + Wmax

其中：
  C = 0.4（缩放因子）
  t = 从丢包后经过的时间
  K = cubic_root((Wmax * beta) / C)  # 到达 Wmax 所需时间
  Wmax = 丢包前的 cwnd
  beta = 0.7
```

### 6.3 CUBIC 相位

```
CUBIC 窗口变化：

cwnd
  ^
  |                    *  Wmax
  |                 *        *
  |              *              *
  |           *                  (重新丢包)
  |        *
  |     *
  |   *
  +------------------------------------> t
   丢包   K   Wmax - beta*Wmax
```

1. **Steep Increase**：快速接近 Wmax
2. **Probe**：在 Wmax 附近徘徊
3. **Steep Decrease**：再次接近 Wmax 后，如果没丢包

### 6.4 CUBIC 实现

```python
class CUBIC:
    def __init__(self):
        self.cwnd = initial_cwnd
        self.ssthresh = float('inf')
        self.Wmax = self.cwnd
        self.K = 0
        self.epoch_start = 0
        self.C = 0.4
        self.beta = 0.7

    def update(self, acked_bytes, now):
        if self.cwnd < self.ssthresh:
            # 慢启动
            self.cwnd += acked_bytes
        else:
            # CUBIC 拥塞避免
            t = now - self.epoch_start
            W_cubic = self.C * (t - self.K)**3 + self.Wmax

            # 还要考虑线性增长的平滑版本
            W_est = self.Wmax + (acked_bytes / self.cwnd)

            self.cwnd = min(W_cubic, W_est)

    def on_loss(self):
        self.Wmax = self.cwnd
        self.cwnd = self.cwnd * self.beta
        self.ssthresh = self.cwnd
        self.K = cubic_root((self.Wmax * (1 - self.beta)) / self.C)
        self.epoch_start = now
```

---

## 7. Reno 算法

### 7.1 Reno 背景

TCP Reno 是 TCP 拥塞控制的经典算法，引入"快速恢复"。

### 7.2 Reno 状态机

```
                    丢包
    +----------------------------------+
    |                                  |
    v                                  |
+---------------------+                |
|     SLOW START      |                |
+---------------------+                |
    | cwnd >= ssthresh |                |
    v                                  |
+---------------------+                |
| CONGESTIVE AVOIDANCE|                |
+---------------------+                |
    | loss detected                   |
    v                                  |
+---------------------+                |
|    FAST RECOVERY    |                |
+---------------------+                |
    | ACK all outstanding             |
    v                                  |
+---------------------+                |
| CONGESTIVE AVOIDANCE|----------------+
+---------------------+
```

### 7.3 快速恢复

Reno 在快速恢复阶段：

1. 收到每个重复 ACK，cwnd += MSS
2. 发送一个新数据包（如果 cwnd 允许）
3. 当所有丢失包被确认，退出快速恢复

```python
def on_duplicate_ack():
    if in_fast_recovery:
        cwnd += MSS
        send_packet()
    else:
        enter_fast_recovery()
```

---

## 8. Proportional Rate Reduction (PRR)

### 8.1 PRR 背景

PRR（RFC 6937）是现代 TCP 的恢复算法，在丢包后更平滑地减少发送速率。

### 8.2 PRR 目标

PRR 旨在：

- 丢包后不要突然停止发送
- 也不要突然发送太多

### 8.3 PRR 算法

```python
def prr_update(acked_bytes, snd_cwnd, snd_ssthresh):
    # PRR-Recovery 算法
    limit = max(snd_ssthresh, (snd_cwnd * beta) + acked_bytes)

    # 允许发送的数据量
    prr_allowance = limit - pipesize

    return min(prr_allowance, total_bytes_acked)
```

### 8.4 PRR 与 QUIC

QUIC 实现可以采用类似的策略：

- 丢包后平滑减少发送速率
- 避免"急刹车"或"突发"

---

## 9. QUIC 的拥塞控制灵活性

### 9.1 可插拔的拥塞控制

QUIC 的一大优势是**拥塞控制算法可替换**：

```
QUIC 拥塞控制接口：

interface CongestionControl:
    def on_packet_sent(packet)
    def on_acked(packet)
    def on_loss_detected(packet)
    def get_cwnd() -> int
    def get_pacing_rate() -> int
```

### 9.2 常见 QUIC 拥塞控制算法

| 算法   | 描述               | 适用场景 |
| ------ | ------------------ | -------- |
| Cubic  | 默认，Linux 标准   | 通用     |
| Reno   | 简单，快速恢复     | 低带宽   |
| BBR    | 基于模型，延迟敏感 | 数据中心 |
| Copa   | 弹性速率           | 视频     |
| SCREAM | 实时多媒体         | 交互式   |

### 9.3 QUIC 的优势

与 TCP 相比，QUIC 的拥塞控制优势：

1. **独立于 OS**：用户空间实现，更新不需要内核升级
2. **Connection 级**：每个 QUIC 连接独立拥塞控制
3. **0-RTT**：新连接可以直接使用之前的 cwnd 估计
4. **Spin Bit**：可用于被动带宽估计

---

## 10. 丢包后的恢复策略

### 10.1 恢复阶段

丢包后，QUIC 进入恢复状态：

```
Recovery 状态：

丢包检测
    |
    v
+------------------------+
| In Recovery?           |
+------------------------+
    |
    | No → 进入恢复状态
    v
+------------------------+
| - 记录丢包数            |
| - 限制新数据发送        |
| - 等待丢失包被确认      |
+------------------------+
    |
    | 所有丢失包确认
    v
退出恢复状态
```

### 10.2 恢复期间的 cwnd

恢复期间的 cwnd 调整：

```python
if in_recovery:
    # PRR 风格：平滑减少
    cwnd = cwnd - bytes_lost + acked_bytes
else:
    # 正常拥塞控制
    normal_cwnd_calculation()
```

### 10.3 PTO 与恢复

PTO（Probe Timeout）触发后：

1. 发送 probe 包
2. 如果 probe 被确认 → 退出恢复
3. 如果 probe 超时 → 继续恢复

---

## 11. 拥塞控制的监控

### 11.1 关键指标

QUIC 连接应该监控：

| 指标        | 含义         | 正常范围       |
| ----------- | ------------ | -------------- |
| cwnd        | 当前拥塞窗口 | 取决于连接状态 |
| ssthresh    | 慢启动阈值   | 取决于历史     |
| in_flight   | 飞行中的字节 | <= cwnd        |
| pacing_rate | 发送速率     | <= bandwidth   |

### 11.2 丢包率计算

```python
loss_rate = lost_packets / total_sent_packets

# 通常用滑动窗口计算
loss_rate = lost_in_window / sent_in_window
```

### 11.3 带宽估计

```python
bandwidth = delivered_bytes / ack_rtt

# delivered_bytes = 最新 ACK 确认的字节 - 之前 ACK 确认的字节
```

---

## 12. 小结

本章介绍了 QUIC 拥塞控制的基础：

1. **cwnd**：拥塞窗口，限制飞行中的数据
2. **慢启动**：指数增长，快速探测带宽
3. **拥塞避免**：线性增长，精细调整
4. **乘法减少**：丢包后快速减少 cwnd
5. **CUBIC**：更平滑的窗口函数
6. **PRR**：丢包后平滑恢复

QUIC 的可插拔架构允许实现不同的拥塞控制算法。下一章我们将深入 BBR——Google 开发的基于延迟的拥塞控制算法。
