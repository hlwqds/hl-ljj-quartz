---
title: "QUIC 深度探索 ch14 - ACK 帧深度解析"
date: 2026-04-14
description: "深入剖析 QUIC ACK 帧的二进制格式：Largest Acknowledged、ACK Delay、ACK Ranges 的编码规则、ECN 计数字段、ACK 触发策略与重传机制的关系"
tags:
  - quic
  - series
  - ack
  - frames
  - reliability
  - loss-detection
---

# QUIC 深度探索 ch14 - ACK 帧深度解析

> [!tip] 本章内容
> 本章深入解析 QUIC ACK 帧的完整机制：Packet Number 空间的独立 ACK、ACK Ranges 编码、ACK Delay 精确时间测量、ECN 计数、ACK 触发策略，以及 ACK 帧与丢包检测算法的耦合关系。

---

## 1. ACK 帧的设计目标

QUIC ACK 帧相比 TCP ACK 有几个关键改进：

```
QUIC ACK vs TCP ACK 对比：

  TCP ACK 的局限性：
    ① 累积确认（Cumulative ACK）：只能确认连续范围
    ② ACK 延迟不精确：TCP 时间戳选项开销大，非强制
    ③ 单一 ACK 空间：握手和数据共用同一确认空间
    ④ 重传歧义：重传包 ACK 可能指向原始包或重传包

  QUIC ACK 的改进：
    ① SACK-like 范围确认：支持多个 ACK Ranges，精确报告乱序
    ② 精确 ACK Delay：专用字段报告接收方处理延迟
    ③ 独立 Packet Number 空间：Initial/Handshake/1-RTT 独立确认
    ④ 单调递增 PN：QUIC PN 从不复用，消除重传歧义
```

---

## 2. ACK 帧格式

### 2.1 ACK 帧格式（0x02，无 ECN）

```
ACK 帧格式（0x02）：

 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+
|      0x02      |   ← 帧类型
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                   Largest Acknowledged (i)                    |   ← 已收到的最大 PN
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                       ACK Delay (i)                           |   ← 接收方延迟（微秒单位）
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                    ACK Range Count (i)                        |   ← 额外 ACK Range 数量
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                    First ACK Range (i)                        |   ← 从 Largest Acked 向前连续确认的包数
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|            ACK Range [0..ACK Range Count-1]                   |
|              Gap (i) + Acked Range Length (i)                 |
|                         ...                                   |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

### 2.2 ACK 帧格式（0x03，含 ECN 计数）

```
ACK+ECN 帧格式（0x03）：

  [上述 0x02 所有字段]
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |                         ECT0 Count (i)                        |   ← ECN ECT(0) 标记的包数
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |                         ECT1 Count (i)                        |   ← ECN ECT(1) 标记的包数
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |                         ECNCE Count (i)                       |   ← ECN CE（拥塞体验）的包数
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

---

## 3. ACK Ranges 编码详解

ACK Ranges 是 ACK 帧中最复杂的部分，用于表达非连续的 Packet Number 集合。

### 3.1 编码原理

```
ACK Ranges 编码原理：

  核心思想：从 Largest Acknowledged 向下（向小）交替描述"已确认范围"和"间隔"。

  字段序列：
    Largest Acknowledged = L
    First ACK Range = R0          → 确认了 [L - R0, L]
    Gap 1 + ACK Range Length 1    → 跳过 Gap1+2 个 PN，再确认 Range1+1 个 PN
    ...
    Gap N + ACK Range Length N

  间隔计算（RFC 9000 §19.3.1）：
    smallest_in_range = largest - first_ack_range
    
    for each (Gap, AckRangeLen) in ack_ranges:
        largest = smallest_in_range - Gap - 2
        smallest = largest - AckRangeLen
        smallest_in_range = smallest
```

### 3.2 ACK Ranges 编码示例

```
场景：已收到包 0, 1, 2, 5, 6, 9（包 3, 4, 7, 8 丢失）

  Packet Numbers: 0 1 2 . . 5 6 . . 9
                  ↑ ↑ ↑     ↑ ↑     ↑
  
  编码过程（从最大 PN=9 向下）：
    Largest Acknowledged = 9
    First ACK Range = 0         → 确认 [9, 9]（只有 9 一个包）
    
    第一个 ACK Range：
      Gap = 1                   → 跳过 7, 8（Gap=1 表示 Gap+2=3 个中间 PN：7, 8 + 边界）
      ACK Range Length = 1      → 确认 [5, 6]（Length+1=2 个包）
    
    第二个 ACK Range：
      Gap = 1                   → 跳过 3, 4
      ACK Range Length = 2      → 确认 [0, 2]（Length+1=3 个包）
    
    ACK Range Count = 2

  最终 ACK 帧字段：
    Largest Acknowledged = 9
    ACK Delay = <测量值>
    ACK Range Count = 2
    First ACK Range = 0
    Gap[0] = 1,  ACK Range Length[0] = 1
    Gap[1] = 1,  ACK Range Length[1] = 2
```

### 3.3 ACK Ranges 解码

```python
def decode_ack_ranges(largest, first_ack_range, ack_ranges):
    """返回所有已确认的 Packet Number 集合"""
    acked = set()
    
    # First ACK Range：[largest - first_ack_range, largest]
    for pn in range(largest - first_ack_range, largest + 1):
        acked.add(pn)
    
    smallest = largest - first_ack_range
    
    for gap, ack_range_len in ack_ranges:
        # 跳过 gap + 2 个 PN（+2 是因为边界不含在 gap 内）
        largest = smallest - gap - 2
        smallest = largest - ack_range_len
        
        for pn in range(smallest, largest + 1):
            acked.add(pn)
    
    return acked
```

### 3.4 实际编码优化建议

```
ACK Range 数量优化：

  ① 维持最大 ACK Range 数量限制（避免 ACK 帧过大）
     → 建议最多 64 个 Range（约 500 字节）
  
  ② 旧的 ACK Range 可以逐步删除（已确认的就不需要重复 ACK）
  
  ③ ACK 帧本身不需要重传（Packet Number 单调递增，新 ACK 隐含历史信息）
```

---

## 4. Largest Acknowledged 字段

```
Largest Acknowledged 含义：

  接收方目前收到的最大 Packet Number。
  
  注意：
    ① 这是 PN 空间中实际收到的最大值，不是期望序号
    ② 对应 ACK 的包类型：
         ACK 在 Initial 包中 → 确认 Initial 包
         ACK 在 Handshake 包中 → 确认 Handshake 包
         ACK 在 1-RTT 包中 → 确认 1-RTT 包
    ③ 三个 PN 空间（Initial/Handshake/1-RTT）的 ACK 完全独立！
```

---

## 5. ACK Delay 字段

### 5.1 ACK Delay 的作用

ACK Delay 是接收方从收到 Largest Acknowledged 对应的数据包，到发出 ACK 帧之间的时间差：

```
ACK Delay 测量：

  t_recv  = 收到 PN=L 对应数据包的时间
  t_send  = 发出此 ACK 帧的时间
  
  ACK Delay（原始微秒值）= t_send - t_recv
  
  编码为帧中的值：
    ACK Delay（字段值）= ACK_Delay_raw / (2 ^ ack_delay_exponent)
    （ack_delay_exponent 是 transport parameter，默认为 3，即除以 8）

  解码：
    ACK_Delay_raw = ACK Delay（字段值） * (2 ^ ack_delay_exponent)
```

### 5.2 ACK Delay 在 RTT 估算中的作用

```
RTT 估算（RFC 9002 §5.1）：

  latest_rtt = 收到 ACK 时刻 - 对应包的发送时刻

  但 latest_rtt 包含了接收方的 ACK 处理延迟，需要扣除：

  adjusted_rtt = latest_rtt - ack_delay   （如果 ack_delay 合法）
  
  smoothed_rtt = (7/8) * smoothed_rtt + (1/8) * adjusted_rtt
  rttvar = (3/4) * rttvar + (1/4) * |smoothed_rtt - adjusted_rtt|

  注意：
    ① ack_delay > max_ack_delay（对端声明的最大延迟）时，只扣减 max_ack_delay
    ② ack_delay > latest_rtt 时，不扣减（可能是时钟问题）
```

### 5.3 max_ack_delay Transport Parameter

```
max_ack_delay（transport parameter，默认 25ms）：

  接收方承诺的最大 ACK 延迟时间。发送方使用此值：
    ① PTO（Probe Timeout）计算
    ② RTT 估算中限制扣减的 ack_delay 上界

  设置建议：
    低延迟场景：max_ack_delay = 5ms（牺牲 CPU 换延迟）
    批量传输场景：max_ack_delay = 50ms（减少 ACK 频率）
```

---

## 6. ACK 触发策略

### 6.1 什么时候发送 ACK

```
ACK 触发规则（RFC 9000 §13.2）：

  规则 1：收到 ACK-eliciting 包后，不能延迟超过 max_ack_delay

  规则 2：每收到 2 个 ACK-eliciting 包，必须立即发送 ACK
            （防止 TCP Delayed ACK 类似的问题）

  规则 3：收到乱序包（检测到 gap）时，应立即发送 ACK
            （快速通知发送方丢包，触发重传）

  规则 4：握手期间应立即 ACK（不延迟）
            （加速握手完成）
```

### 6.2 ACK 频率扩展（ACK Frequency 帧）

RFC 草案定义了 ACK_FREQUENCY 帧，允许发送方控制接收方的 ACK 策略：

```
ACK_FREQUENCY 帧作用：

  发送方 → 接收方：
    "每收到 N 个 ACK-eliciting 包才需要发一次 ACK"
    "每隔 T 微秒至少发一次 ACK"

  应用场景：
    高吞吐量文件传输：N=10（减少 ACK 开销）
    视频会议：N=2, T=5000us（保持低延迟）
```

### 6.3 Non-ACK-eliciting 包不触发 ACK

```
ACK-eliciting vs Non-ACK-eliciting 包：

  Non-ACK-eliciting 包（不要求对端 ACK）：
    仅含 ACK 帧的包
    仅含 PADDING 帧的包
    仅含 CONNECTION_CLOSE 帧的包

  问题：如果发送方只发 Non-ACK-eliciting 包，如何知道链路畅通？
  解法：至少每 path_challenge_timeout 发一次 PING 帧（ACK-eliciting）
```

---

## 7. Packet Number Space 与 ACK 的关系

### 7.1 三个独立的 PN 空间

```
QUIC 的三个 Packet Number 空间：

  PN Space 1：Initial（Packet Number 从 0 开始）
  PN Space 2：Handshake（Packet Number 从 0 开始）
  PN Space 3：Application Data / 1-RTT（Packet Number 从 0 开始）

  ★ 每个空间的 ACK 完全独立！
  
  示例：
    收到 Initial Packet PN=5 → 发 ACK 在 Initial 包中，Largest Acked=5
    收到 Handshake Packet PN=3 → 发 ACK 在 Handshake 包中，Largest Acked=3
    收到 1-RTT Packet PN=100 → 发 ACK 在 1-RTT 包中，Largest Acked=100
```

### 7.2 PN 空间的关闭

```
PN 空间关闭时机：

  Initial PN Space：
    客户端发送第一个 Handshake 包后，可废弃 Initial 密钥
    服务端收到客户端 Handshake 包后，可废弃 Initial 密钥
    废弃后不再接受/发送 Initial 包

  Handshake PN Space：
    服务端：发送 HANDSHAKE_DONE 帧后废弃 Handshake 密钥
    客户端：收到 HANDSHAKE_DONE 帧后废弃 Handshake 密钥

  Application Data PN Space：
    连接关闭时废弃（CONNECTION_CLOSE 或超时）
```

---

## 8. ECN（显式拥塞通知）

### 8.1 QUIC 的 ECN 支持

QUIC 支持 IP 层的 ECN 标记（RFC 3168），通过 ACK 帧的 ECN 计数字段反馈给发送方：

```
ECN 标记（IP 头 TOS 字段的低 2 位）：

  00 = Not-ECT     ← 不支持 ECN
  01 = ECT(1)      ← 支持 ECN（Code Point 1）
  10 = ECT(0)      ← 支持 ECN（Code Point 0，更常用）
  11 = CE          ← 拥塞体验（Congestion Experienced），网络设备标记

QUIC 发送方：
  发送数据包时在 IP 头标记 ECT(0)（如果支持 ECN）

QUIC 接收方：
  统计收到的 ECT(0)、ECT(1)、CE 包数量
  在 ACK 帧（0x03）中报告 ECN 计数

QUIC 发送方（收到 ACK）：
  如果 CE 计数增加 → 触发拥塞控制（类似 TCP ECN）
```

### 8.2 ECN 计数字段

```
ECN 计数字段（累积值）：

  ECT0 Count = 所有已收到的 ECT(0) 标记包的累计数量
  ECT1 Count = 所有已收到的 ECT(1) 标记包的累计数量
  ECNCE Count = 所有已收到的 CE 标记包的累计数量

注意：这些是累积计数器（单调递增），不是差值！
发送方需要用前后两次 ACK 的差值来计算本轮的 CE 增量。

ECN 验证（RFC 9000 §13.4.2）：
  若 ECT0 Count + ECNCE Count < 发送的 ECT(0) 包数 → ECN 可能被路径丢弃
  若检测失败 → 回退到非 ECN 模式
```

---

## 9. ACK 帧的限制与注意事项

### 9.1 ACK 帧不可重传

```
ACK 帧的特殊性：

  ① ACK 帧本身被丢失时，不需要重传！
     → 因为新的 ACK 帧会包含更完整的确认信息（Largest Acked ≥ 旧值）

  ② ACK 帧不占用流量控制窗口
     → ACK 帧不算在 Max Data 限制内

  ③ 但 ACK 帧占用发送方的拥塞控制窗口（cwnd）
     → 不像 TCP，QUIC 的 ACK 数据包也受 cwnd 约束
     （实现上通常把 ACK-only 包排除在 cwnd 外）
```

### 9.2 ACK 帧的 Packet Number 截断

```
PN 截断安全性：

  实现通常只用 1-4 字节编码 Packet Number（PP bits），而不是完整的 62-bit 值。

  接收方通过"包号推断（Packet Number Reconstruction）"恢复完整 PN：
    candidate = (expected_pn & ~pn_mask) | truncated_pn
    如果与 expected_pn 差距过大，尝试 candidate ± pn_mask

  安全要求：
    PN 的有效窗口不能超过 2^(bit_length-1) 个包
    → 4 字节 PN 允许最大 2^31 ≈ 2B 个包的窗口
    → 1 字节 PN 只允许最大 128 个包的窗口（不推荐用于高带宽场景）
```

---

## 10. 完整 ACK 帧解析示例

```
原始字节（十六进制）：
  02 09 10 01 00

解析过程：
  02          → 帧类型 0x02（ACK，无 ECN）
  09          → Largest Acknowledged = 9（可变长 1 字节）
  10          → ACK Delay = 16（乘以 2^ack_delay_exponent=3 得 128 微秒）
  01          → ACK Range Count = 1（有 1 个额外 ACK Range）
  00          → First ACK Range = 0（确认范围 [9, 9]）

  ACK Range [0]：
  02          → Gap = 2（跳过 PN 6, 7 两个包，+2 所以实际跨越 PN 6, 7）
  02          → ACK Range Length = 2（确认 3 个包）
              → 从 9 - 0 - 2 - 2 - 1 = 4 开始，到 4 + 2 = 6... 

  等等，让我重新计算：
  smallest_in_prev_range = 9 - 0 = 9
  Gap = 2：largest_next = 9 - 2 - 2 = 5
  AckRangeLen = 2：smallest_next = 5 - 2 = 3
  → 确认范围 [3, 5]

  最终确认的 PN：{9} ∪ {3, 4, 5} = {3, 4, 5, 9}
  丢失的 PN：6, 7, 8（在 5 和 9 之间的间隔）
```

---

## 小结

QUIC ACK 帧的设计体现了对 TCP 确认机制的系统性改进：

- **ACK Ranges** 精确描述乱序接收情况，替代 TCP 的累积 ACK
- **ACK Delay** 字段使 RTT 估算更精确，减少不必要的重传
- **独立 PN 空间** 使 Initial/Handshake/1-RTT 的确认完全解耦
- **ECN 支持** 通过 CE 计数反馈网络拥塞信号，替代丢包触发拥塞控制
- **ACK 不重传** 机制减少了确认开销，新 ACK 天然包含旧 ACK 的信息

下一章将转向 CRYPTO 帧，解析 TLS 握手消息如何通过 CRYPTO 数据流传输。
