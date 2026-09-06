---
title: "QUIC 深度探索 ch31 - 连接状态机"
date: 2026-04-14
description: "深入解析 QUIC 连接状态机：Handshake/Confirmed/draining 状态及其转换、Packet Number Space 与状态映射、idle timeout、迁移状态与统计"
tags:
  - quic
  - series
  - connection-state
  - state-machine
  - handshake
  - draining
---

# QUIC 深度探索 ch31 - 连接状态机

> [!tip] 本章内容
> 本章深入剖析 QUIC 连接状态机，涵盖连接建立到关闭的完整生命周期：Handshake/Confirmed/draining 等核心状态，Packet Number Space 与状态映射关系，idle timeout 机制，以及连接迁移相关状态转换。

---

## 1. 状态机概述

QUIC 连接状态机比 TCP 复杂得多，原因在于 QUIC 在单一连接中引入了多个正交维度：

1. **加密级别**（Encryption Level）：Initial → Handshake → 0-RTT/1-RTT
2. ** Packet Number Space**（PN Space）：Initial / Handshake / Application Data
3. **连接阶段**（Connection Phase）：Handshake → Confirmed → Active → Draining
4. **地址状态**（Address State）：Verified / Unverified

---

## 2. 三大核心状态

### 2.1 Handshake 状态

Handshake 状态是连接建立的第一阶段，从客户端发送第一个 Initial 包开始，到服务器收到客户端的 Handshake 包为止。

进入 Handshake 状态的条件：

- 发送或接收 Initial 包
- 握手密钥尚未确认

在 Handshake 状态下：

- 可以发送 Initial 包和 Handshake 包
- 不能发送 1-RTT 包（密钥尚未派生）
- 接收到的 0-RTT 包被缓冲（不交付给应用层）

### 2.2 Confirmed 状态

Confirmed 状态表示加密握手已完成且得到确认。RFC 9000 定义了"Confirmed"的概念——当端点收到由 1-RTT 密钥保护的确认帧（CONFIRMED frame），或者收到对方发送的 1-RTT 包且该包被确认时，进入 Confirmed 状态。

进入 Confirmed 状态的条件（满足任一即可）：

1. 收到 Handshake 包确认
2. 收到由 1-RTT 密钥保护的确认帧
3. 发送或接收非-ACK 帧（表示握手完成）

Confirmed 状态的核心意义：

- 0-RTT 密钥的保密性（forward secrecy）已得到确认
- 可以安全地使用 0-RTT 数据
- 连接迁移时无需重新验证地址（已确认的地址无需再次验证）

### 2.3 Draining 状态

Draining 状态是连接关闭前的过渡状态。当连接即将终止，但还需要处理网络中仍在传输的包时，进入 Draining 状态。

在 Draining 状态下：

- 不再发送新数据包
- 仍然可以发送 ACK（处理仍在途中的包）
- 不交付任何新数据给应用层
- 持有连接相关的所有资源

Draining 状态的引入是为了优雅关闭（Graceful Shutdown），确保对端有机会收到 CONNECTION_CLOSE 通知。

---

## 3. Packet Number Space 与状态映射

QUIC 定义了三个独立的 Packet Number Space，每个空间有独立的包编号序列：

| PN Space          | 包含的包类型 | 加密密钥       | 用途         |
| ----------------- | ------------ | -------------- | ------------ |
| Initial Space     | Initial      | Initial 密钥   | 握手初始阶段 |
| Handshake Space   | Handshake    | Handshake 密钥 | 握手确认阶段 |
| Application Space | 0-RTT, 1-RTT | 1-RTT 密钥     | 数据传输     |

### 3.1 PN Space 与连接状态的关系

```
PN Space 与连接状态映射：

        +------------------------------------------------------+
        |               Connection State                        |
        |                                                      |
        |  +-------------+  +-------------+  +-------------+    |
        |  |   Initial   |  |  Handshake  |  |    App      |    |
        |  |   Space     |  |   Space     |  |   Space     |    |
        |  +-------------+  +-------------+  +-------------+    |
        |        |               |               |             |
        |        v               v               v             |
        |  Initial 密钥    Handshake 密钥   1-RTT 密钥        |
        |                                                      |
        +------------------------------------------------------+
```

### 3.2 各状态下的 PN Space 可用性

| 连接状态  | Initial Space  | Handshake Space | Application Space    |
| --------- | -------------- | --------------- | -------------------- |
| Handshake | 可用           | 可用            | 不可用（密钥未派生） |
| Confirmed | 不可用（关闭） | 不可用（关闭）  | 可用                 |
| Active    | 不可用         | 不可用          | 可用                 |
| Draining  | 不可用         | 不可用          | 仅接收 ACK           |

### 3.3 密钥派生与 PN Space 切换

在握手过程中，加密密钥逐步派生，PN Space 也随之切换：

```
握手过程中的 PN Space 切换：

时间 -->
----------------------------------------------------------------->

Client:  [Initial]  [Handshake]     [0-RTT] [1-RTT]
          +----------------------------------------------------------------+
                   |                 |
                   v                 v
Server:       [Initial]  [Handshake]  [1-RTT]
                        |
                        v
              Handshake Complete
              === 1-RTT keys confirmed ===

PN Space:   Initial -> Handshake -> Application (0-RTT, 1-RTT)
```

---

## 4. 状态转换详解

### 4.1 连接建立状态转换

```
连接建立完整状态转换图：

    +---------+                    +-----------+
    |  Init   |---发送 Initial--->| Handshake |
    +---------+                    +-----------+
                                  |         |
                                  |收到确认   |
                                  v         |
                           +-----------+    |
                           | Confirmed |    |
                           +-----------+    |
                                  |         |
                                  |发送/接收  |
                                  v         v
                           +-----------+
                           |  Active   |
                           +-----------+

状态转换触发条件：

Init -> Handshake:
  - 触发条件：发送第一个 UDP datagram 包含 Initial 包
  - 操作：生成 Connection ID，启动 PTO 定时器

Handshake -> Confirmed:
  - 触发条件：收到 Handshake 包 或 收到 1-RTT 包确认
  - 操作：清除 Initial/Handshake 密钥，派生 1-RTT 密钥

Confirmed -> Active:
  - 触发条件：发送或接收非 ACK 帧
  - 操作：启动 idle timeout 计时器
```

### 4.2 连接关闭状态转换

```
连接关闭状态转换：

    +-----------+       CONNECTION_CLOSE      +-----------+
    |  Active   |--------------------------->|  Draining  |
    +-----------+                            +-----------+
           |                                        |
           | 收到对方 CONNECTION_CLOSE              | idle timeout 到期
           v                                        v
    +-----------+                            +-----------+
    |  Draining |                            |  Closing  |
    +-----------+                            +-----------+
                                                    |
                                                    | 3 倍 PTO 后
                                                    v
                                             +-----------+
                                             |   Closed   |
                                             +-----------+
```

### 4.3 状态转换事件表

| 当前状态  | 事件                  | 目标状态  | 操作                  |
| --------- | --------------------- | --------- | --------------------- |
| Init      | 发送 Initial          | Handshake | 启动握手              |
| Handshake | 收到 Handshake 确认   | Confirmed | 派生 1-RTT 密钥       |
| Handshake | PTO 超时（多次）      | Closing   | 发送 CONNECTION_CLOSE |
| Confirmed | 发送数据帧            | Active    | 启动 idle timeout     |
| Active    | 收到 CONNECTION_CLOSE | Draining  | 停止发送新数据        |
| Active    | 应用请求关闭          | Draining  | 发送 CONNECTION_CLOSE |
| Draining  | idle timeout          | Closing   | 释放资源              |
| Closing   | 3 \* PTO              | Closed    | 完全关闭连接          |

---

## 5. Idle Timeout 机制

QUIC 的 idle timeout 是一个重要的连接管理机制。如果在一个时间窗口内没有任何包被发送或接收，连接将被判定为 idle 并自动关闭。

### 5.1 Idle Timeout 的计算

idle timeout 值在握手阶段协商：

```python
idle_timeout = min(local_idle_timeout, remote_idle_timeout)
```

双方各自声明自己能接受的最大空闲时间，最终取两者的较小值。HTTP/3 的默认 idle timeout 是 30 秒。

### 5.2 Idle Timeout 的触发条件

Idle timeout 只在 Active 状态下计时：

- 收到或发送非 ACK 帧时，重置 idle timeout 计时器
- ACK 帧不重置 idle timeout（防止 ACK 保持连接存活）
- 发送纯 ACK 包不重置 idle timeout

```
Idle Timeout 行为：

Active 状态：
  |
  | 发送/接收非 ACK 帧 -> 重置计时器
  |
  | 无活动达到 idle_timeout -> CONNECTION_CLOSE
  |   (错误码：NO_ERROR，错误原因：idle timeout)
  |
  v

计时器重置事件（重置 idle timer）：
  - STREAM 帧
  - CRYPTO 帧
  - PING 帧
  - 任何非 ACK 的帧

计时器不复位事件（不重置 idle timer）：
  - ACK 帧
  - 纯 ACK 包
```

### 5.3 Idle Timeout 与连接迁移

在连接迁移场景中，idle timeout 的行为值得注意：

- 迁移成功后，立即重置 idle timeout 计时器
- PATH_CHALLENGE/PATH_RESPONSE 包不重置 idle timeout（这些包属于地址验证）
- 迁移未确认时（旧路径），idle timeout 仍然对旧路径计时

---

## 6. 连接统计与状态查询

QUIC 实现通常提供连接统计信息，用于监控连接状态和调试。

### 6.1 核心统计指标

```python
class QUICConnectionStats:
    # 状态统计
    state: str                      # 当前状态
    packets_sent: int               # 已发送包数
    packets_received: int           # 已接收包数
    bytes_sent: int                 # 已发送字节数
    bytes_received: int             # 已接收字节数

    # RTT 统计
    estimated_rtt: float            # 当前 RTT 估计
    min_rtt: float                  # 最小 RTT
    max_rtt: float                  # 最大 RTT

    # 丢包统计
    packets_lost: int               # 检测到的丢包数
    PTO_count: int                  # PTO 触发次数

    # 流统计
    streams_opened: int             # 已打开的流数
    streams_closed: int             # 已关闭的流数
```

### 6.2 各状态下的统计行为

| 状态      | packets_sent        | packets_received    | 说明        |
| --------- | ------------------- | ------------------- | ----------- |
| Handshake | Initial + Handshake | Initial + Handshake | 仅握手包    |
| Confirmed | 0-RTT + 1-RTT       | 0-RTT + 1-RTT       | 仅数据面包  |
| Active    | 1-RTT               | 1-RTT               | 仅 1-RTT 包 |
| Draining  | 仅 ACK              | 任意包              | 仅响应包    |

---

## 7. 状态机的实现考量

### 7.1 状态存储

QUIC 连接状态机需要在内存中维护以下信息：

```python
class QUICConnectionState:
    def __init__(self):
        # 基本状态
        self.state = "init"
        self.pn_space = {
            "initial": PacketNumberSpace(),
            "handshake": PacketNumberSpace(),
            "application": PacketNumberSpace(),
        }

        # 密钥状态
        self.encryption_levels = {
            "initial": EncryptionLevel.Initial,
            "handshake": EncryptionLevel.Handshake,
            "application": EncryptionLevel.OneRTT,
        }

        # 超时状态
        self.idle_timeout = 30.0
        self.idle_timer = None
        self.PTO_timer = None
        self.PTO_count = 0

        # 地址状态
        self.address_verified = False
        self.migration_state = "disconnected"
```

### 7.2 状态转换的原子性

QUIC 状态转换必须保证原子性，防止部分状态更新导致协议不一致：

- 状态转换和状态相关操作（如发送特定类型的包）必须在同一个锁的保护下
- 密钥切换时，必须同时更新加密状态和 PN Space
- CONNECTION_CLOSE 发送后，不应再修改连接状态

### 7.3 状态机与调试

生产环境中，状态机调试是关键能力：

```python
def log_state_transition(old_state, new_state, event):
    logger.info(
        f"QUIC state transition: {old_state} --({event})--> {new_state}",
        extra={
            "connection_id": self.connection_id,
            "timestamp": time.time(),
            "pn_space": self.current_pn_space,
            "packet_number": self.current_packet_number,
        }
    )
```

---

## 8. 小结

本章深入解析了 QUIC 连接状态机的完整设计：

1. **三大核心状态**：Handshake → Confirmed → Active → Draining，每个状态都有明确的进入条件和退出条件

2. **Packet Number Space**：三个独立空间（Initial/Handshake/Application）保证了不同加密阶段的包编号互不干扰

3. **Idle Timeout**：通过精细的计时器重置规则，防止连接被虚假保持

4. **状态转换原子性**：实现时需要保证状态转换的完整性，避免中间状态暴露

连接状态机是 QUIC 协议正确运转的基础，理解它对于调试连接问题、优化性能、正确实现协议至关重要。下一章我们将讨论连接关闭的完整流程和错误码体系。
