---
title: "QUIC 深度探索 ch24 - BBR 拥塞控制"
date: 2026-04-14
description: "深入解析 BBR (Bottleneck Bandwidth and Round-trip propagation time) 拥塞控制算法：带宽延迟积、pacing gain、相位控制、cwnd 推导、与 CUBIC/Reno 的对比"
tags:
  - quic
  - series
  - bbr
  - congestion-control
  - pacing
  - bandwidth-estimation
---

# QUIC 深度探索 ch24 - BBR 拥塞控制

> [!tip] 本章内容
> 本章深入剖析 Google 开发的 BBR (Bottleneck Bandwidth and Round-trip propagation time) 拥塞控制算法：核心思想、带宽延迟积（BDP）、pacing gain、相位控制、cwnd 推导、以及与 CUBIC/Reno 的关键区别。

---

## 1. BBR 概述

### 1.1 背景

BBR（2016 年由 Google 发布）是继 CUBIC 之后的新一代拥塞控制算法。与 CUBIC/Reno 基于丢包进行拥塞检测不同，BBR 基于**显式带宽-延迟模型**进行拥塞控制。

核心观察：
- 丢包**不是**拥塞的最好信号
- 丢包时网络已经极度拥塞
- 应该测量**实际带宽**和**最小延迟**

### 1.2 BBR vs 传统算法

| 特性 | CUBIC/Reno | BBR |
|------|------------|-----|
| 拥塞信号 | 丢包 | 延迟 + 带宽模型 |
| cwnd 增长 | 丢包后减少，重新慢启动 | 基于带宽估计连续调整 |
| 队列建立 | 可能建立大队列 | 主动避免队列 |
| 带宽利用率 | 较低（保守） | 较高 |
| 公平性 | 好 | 较差（v1），改进中（v2） |

### 1.3 核心思想

BBR 的核心是维持两个关键变量的平衡：

```
BDP = bandwidth × min_rtt

其中：
  bandwidth = 测量到的瓶颈带宽
  min_rtt = 测量到的最小 RTT

cwnd = BDP = bandwidth × min_rtt
```

BBR 试图让飞行中的数据 ≈ BDP，既不过多（导致队列）也不过少（浪费带宽）。

---

## 2. BBR 的四个相位

### 2.1 相位概览

BBR 运行在一个状态机中，有四个主要相位：

```
BBR 状态机：

+---------------------+
|   STARTUP           |  快速探测带宽
+---------------------+
    | 达到满带宽
    v
+---------------------+
|   DRAIN             |  排出多余队列
+---------------------+
    | 队列清空
    v
+---------------------+
|   PROBE_BW          |  探测带宽（主要状态）
+---------------------+
    | 每 8-10 秒
    v
+---------------------+
|   PROBE_RTT         |  探测最小 RTT
+---------------------+
    | 200ms 后
    v
返回 PROBE_BW
```

### 2.2 STARTUP 相位

**目标**：快速探测瓶颈带宽。

```python
class BBR:
    def startup():
        if not filled_pipe:
            # 指数增长 pacing rate，直到带宽不再增长
            pacing_rate *= 2
            cwnd = pacing_rate * min_rtt
        else:
            # 带宽不再增长，进入 DRAIN
            filled_pipe = True
```

STARTUP 阶段：
- pacing_rate 指数增长（× 2 每 RTT）
- 类似 TCP 慢启动，但目标是探测带宽而非填满队列

### 2.3 DRAIN 相位

**目标**：排出 STARTUP 建立的过多队列。

```python
def drain():
    # 线性减少 pacing rate，排出队列
    pacing_rate -= (pacing_rate / 1.2)  # 约 8% 减少
    cwnd = pacing_rate * min_rtt
```

DRAIN 时间约为 STARTUP 时间的一半。

### 2.4 PROBE_BW 相位

**目标**：维持稳定状态，持续探测带宽变化。

这是 BBR 的**主要运行状态**。

```python
def probe_bw():
    # 8 个周期循环
    for cycle_idx in range(8):
        if cycle_idx == 2:  # 第三个周期
            pacing_gain = 1.25  # 略微增加，发包更多
        elif cycle_idx == 6:  # 第七个周期
            pacing_gain = 0.75  # 减少，探测是否有多余包
        else:
            pacing_gain = 1.0  # 正常
        
        pacing_rate = bandwidth * pacing_gain
        cwnd = max(bandwidth * min_rtt, 4 * MSS)
```

**PROBE_BW 相位循环**：

```
周期索引:  0    1    2    3    4    5    6    7
pacing_gain: 1.0  1.0  1.25 1.0  1.0  1.0  0.75 1.0
                 ↑         ↑              ↑
              正常      加速         减速
```

### 2.5 PROBE_RTT 相位

**目标**：测量真实的 min_rtt。

```python
def probe_rtt():
    cwnd = 4 * MSS  # 最小 cwnd
    pacing_rate = bandwidth * 0.5
    # 保持 200ms，记录最小 RTT
    min_rtt = min(min_rtt, measured_rtt)
```

PROBE_RTT 持续 200ms，每 10 秒触发一次。

---

## 3. 带宽估计 (Bandwidth Estimation)

### 3.1 带宽采样

BBR 通过 ACK 反馈来测量带宽：

```python
def on_acked(packet, now):
    rtt = now - packet.send_time
    delivery_rate = packet.size / (ack_time - packet.send_time)
    
    # 跟踪最近 10 个 RTT 的最大带宽
    bandwidth_samples.append(delivery_rate)
    
    # 使用滑动窗口最大值
    if len(bandwidth_samples) >= N:
        bandwidth = max(bandwidth_samples[-N:])
```

### 3.2 带宽过滤

BBR 使用多个机制过滤带宽样本：

1. **窗口最大值**：取滑动窗口内的最大带宽
2. **不合理的样本过滤**：带宽不能超过物理链路速率
3. **RTT 加权**：RTT 较小时，带宽估计更可靠

### 3.3 带宽估计的稳定性

```
带宽采样示意：

RTT 1: delivery_rate = 90 Mbps
RTT 2: delivery_rate = 95 Mbps
RTT 3: delivery_rate = 85 Mbps  <- 暂时拥塞
RTT 4: delivery_rate = 100 Mbps
RTT 5: delivery_rate = 98 Mbps

BBR 使用 max(最近 N 个样本) = 100 Mbps
而不是平均值 93.6 Mbps
```

---

## 4. min_rtt 追踪

### 4.1 min_rtt 更新

```python
def update_min_rtt(rtt_sample):
    if rtt_sample < min_rtt:
        min_rtt = rtt_sample
    elif time_since_min_rtt > 10 seconds:
        # 定期探测更小的 RTT
        enter_probe_rtt()
```

### 4.2 min_rtt 过时问题

min_rtt 一旦设置，可能很长时间不变。但这不代表当前网络：
- 路由可能改变
- 拥塞可能导致实际 RTT 增加

这就是为什么 BBR 定期进入 PROBE_RTT 来重新测量。

---

## 5. pacing_rate 计算

### 5.1 pacing_rate 与 cwnd 的关系

BBR 使用 pacing_rate 来**平滑发送**：

```
pacing_rate = bandwidth * pacing_gain
cwnd = bandwidth * min_rtt * cwnd_gain
```

通常：
- `pacing_gain` 在 0.75 到 1.25 之间变化
- `cwnd_gain` 通常是 2.0（给 cwnd 一些余量）

### 5.2 pacing 的作用

pacing 防止突发：

```
无 pacing：
  cwnd = 100 packets
  发送方可能瞬间发完 100 个包 → 突发 100 包

有 pacing：
  pacing_rate = 100 packets / RTT
  发送方每 (RTT / 100) 发送一个包 → 平滑
```

### 5.3 pacing_rate 实现

```python
def get_next_send_time():
    inter_packet_delay = 1 / pacing_rate
    return now + inter_packet_delay
```

---

## 6. cwnd 推导

### 6.1 为什么需要 cwnd

即使 BBR 主要依赖 pacing_rate 限制发送，也需要 cwnd 作为**备用约束**：

1. **ACK 时钟**：cwnd 控制可以发送多少数据
2. **丢包恢复**：cwnd 限制重传
3. **突发容忍**：允许小的突发

### 6.2 BBR cwnd 公式

```python
cwnd = cwnd_gain * bandwidth * min_rtt
```

其中 `cwnd_gain` 通常是 2.0。

### 6.3 cwnd 约束

```python
def get_sendable():
    # 可以发送的数据量
    sendable = min(
        cwnd - in_flight,  # cwnd 约束
        pacing_rate * rtt,  # pacing 约束
        receive_window      # 流量控制约束
    )
    return max(0, sendable)
```

---

## 7. 与 CUBIC/Reno 的对比

### 7.1 拥塞信号

| 方面 | CUBIC/Reno | BBR |
|------|------------|-----|
| 主要信号 | 丢包 | 延迟 |
| 次要信号 | RTT 变化 | 丢包（但晚于延迟） |
| 响应 | 乘法减少 cwnd | 调整 pacing_rate |

### 7.2 队列建立

```
CUBIC：
  倾向于在瓶颈处建立大队列
  RTT 持续较高
  
BBR：
  主动避免队列
  RTT 接近 min_rtt
```

### 7.3 带宽利用率

```
理想吞吐量 vs 实际吞吐量：

        CUBIC/Reno     BBR
高 BDP:  60-70%        90%+
中 BDP:  70-80%        90%+
低 BDP:  80-90%        90%+
```

BBR 在高带宽延迟积（BDP）网络中优势明显。

### 7.4 公平性

BBR v1 的一个问题是公平性：
- BBR 流可能抢占 CUBIC 流的带宽
- 多个 BBR 流可能振荡

BBR v2 改进了这些问题。

---

## 8. BBR 在 QUIC 中的实现

### 8.1 QUIC 的 BBR 支持

多个 QUIC 实现支持 BBR：
- **quiche** (Cloudflare)
- **msquic** (Microsoft)
- **ngtcp2**

### 8.2 实现注意事项

```python
class BBRQuicCC:
    def __init__(self):
        self.state = BBRState()
        self.bandwidth = 0
        self.min_rtt = inf
        self.cwnd = 4 * MSS
        self.pacing_rate = 0
    
    def on_packet_sent(self, packet):
        self.packets_in_flight += packet.size
        self.schedule_next_send()
    
    def on_acked(self, ack):
        self.update_bandwidth(ack)
        self.update_rtt(ack)
        self.adapt_state()
        self.adjust_cwnd()
        self.adjust_pacing()
    
    def on_loss(self, lost_packets):
        # BBR 对丢包不减少 cwnd
        # 但会更新状态
        pass
```

### 8.3 与 TCP BBR 的差异

QUIC BBR 实现可能与 TCP BBR 有细微差异：
- Packet Number 空间不同
- ACK 机制不同（QUIC 有 ACK Frequency）
- 连接迁移处理不同

---

## 9. BBR 的局限性

### 9.1 丢包敏感场景

BBR 不把丢包作为主要拥塞信号，在某些场景下可能过于激进：
- 无线网络（有天然丢包）
- 高度拥塞的网络

### 9.2 公平性问题

BBR v1 可能对其他流不公平：
- 抢占带宽
- 饿死 CUBIC 流

BBR v2 通过引入 ECN 支持和更保守的增益来改善。

### 9.3 慢网络

在极慢的网络（调制解调器、卫星）：
- min_rtt 很大（500ms+）
- BDP 计算不准确
- pacing_rate 可能过低

---

## 10. BBR 调优参数

### 10.1 可调参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| startup_gain | 2.77 | STARTUP 阶段增益 |
| drain_gain | 0.75 | DRAIN 阶段增益 |
| probe_bw_gain | [1.25, 0.75, 1.0, ...] | PROBE_BW 循环增益 |
| cwnd_gain | 2.0 | cwnd 相对 BDP 的增益 |
| min_pipe | 4 MSS | 最小 cwnd |

### 10.2 场景化调优

**数据中心**：
```
min_rtt 很小（<1ms）
bandwidth 很高
→ 可以降低 cwnd_gain
```

**卫星网络**：
```
min_rtt 很大（500ms+）
bandwidth 中等
→ pacing_rate 可能需要调整
```

---

## 11. BBR 版本演进

### 11.1 BBR v1 (2016)

初始版本，存在公平性问题。

### 11.2 BBR v1alpha/v1beta

Google 内部改进版本。

### 11.3 BBR v2 (2019)

BBR v2 改进：
- 支持 ECN（Explicit Congestion Notification）
- 更公平的带宽共享
- 更精确的拥塞检测

### 11.4 BBR v3

最新版本，整合了 v2 的改进。

---

## 12. 小结

BBR 是一种基于模型的拥塞控制算法：

1. **核心公式**：`cwnd = bandwidth × min_rtt`（BDP）
2. **四个相位**：STARTUP → DRAIN → PROBE_BW → PROBE_RTT
3. **pacing**：平滑发送速率，避免突发
4. **优势**：高带宽利用率，避免队列建立
5. **局限**：公平性问题，丢包敏感场景表现

BBR 代表了"基于模型"拥塞控制的方向，与传统的"基于丢包"算法形成对比。下一章我们将讨论 COPA——另一种强调弹性速率的拥塞控制算法。
