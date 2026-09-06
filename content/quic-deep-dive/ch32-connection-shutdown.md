---
title: "QUIC 深度探索 ch32 - 连接关闭"
date: 2026-04-14
description: "深入解析 QUIC 连接关闭机制：CONNECTION_CLOSE 帧格式与错误码体系、GOAWAY 帧、优雅关闭与立即关闭、关闭过程中的状态转换与资源回收"
tags:
  - quic
  - series
  - connection-close
  - GOAWAY
  - error-codes
  - shutdown
---

# QUIC 深度探索 ch32 - 连接关闭

> [!tip] 本章内容
> 本章深入剖析 QUIC 连接关闭机制，涵盖 CONNECTION_CLOSE 帧的完整格式与错误码体系，GOAWAY 帧的语义，优雅关闭（Graceful Shutdown）与立即关闭（Immediate Close）的区别，以及关闭过程中的状态转换与资源回收策略。

---

## 1. 连接关闭概述

QUIC 提供了两种互补的关闭机制：

1. **优雅关闭**（Graceful Close）：通过 GOAWAY 帧通知对端即将关闭，允许正在进行的请求完成
2. **立即关闭**（Immediate Close）：通过 CONNECTION_CLOSE 帧立即终止连接

这两种机制服务于不同的场景：

- 优雅关闭：服务器维护、重配置、负载均衡
- 立即关闭：协议错误、攻击检测、应用程序强制终止

```
连接关闭类型对比：

+---------------------+  +----------------------+
|   优雅关闭           |  |    立即关闭           |
+---------------------+  +----------------------+
|  发送 GOAWAY         |  |  发送 CONNECTION_CLOSE|
|  等待活跃流完成       |  |  立即停止所有操作      |
|  最后关闭连接         |  |  3 PTO 后释放资源      |
+---------------------+  +----------------------+
|  使用场景：维护/重配置  |  |  使用场景：错误/攻击   |
+---------------------+  +----------------------+
```

---

## 2. CONNECTION_CLOSE 帧

### 2.1 帧格式

CONNECTION_CLOSE 帧有两种变体，分别用于不同的加密级别：

**Application 级别的 CONNECTION_CLOSE（0-RTT/1-RTT）**：

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
| 0x1c (帧类型)                                              |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                        Error Code (i)                        |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                        Frame Type (i)                        |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                   Reason Phrase Length (i)                   |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                        Reason Phrase (...)                   |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

**所有其他级别的 CONNECTION_CLOSE（Initial/Handshake）**：

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
| 0x1c 或 0x1d (帧类型)                                    |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                        Error Code (i)                        |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                   Reason Phrase Length (i)                   |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                        Reason Phrase (...)                   |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

### 2.2 字段说明

| 字段                 | 说明                                         |
| -------------------- | -------------------------------------------- |
| Frame Type           | 0x1c (Application), 0x1d (Initial/Handshake) |
| Error Code           | 错误码（见下节）                             |
| Frame Type           | 触发关闭的帧类型（仅 Application 级别）      |
| Reason Phrase Length | 可读错误原因的长度                           |
| Reason Phrase        | UTF-8 编码的可读错误原因                     |

### 2.3 发送规则

CONNECTION_CLOSE 的发送有严格规则：

1. **一个包只能携带一个 CONNECTION_CLOSE 帧**：防止错误信息丢失
2. **发送后进入 Draining 状态**：不再发送新数据
3. **ACK 仍需发送**：处理网络中的遗留包
4. **不同级别不能相互关闭**：Initial CONNECTION_CLOSE 不能关闭 Application 级别

```
CONNECTION_CLOSE 发送规则：

发送 CONNECTION_CLOSE 后：
  |
  | 1. 进入 Draining 状态
  | 2. 停止发送非 ACK 帧
  | 3. 继续接收和处理包（发送 ACK）
  | 4. 3 * PTO 后进入 Closed 状态
  v
```

---

## 3. 错误码体系

### 3.1 错误码分类

QUIC 定义了四类错误码，分别对应不同的错误场景：

**1. 传输错误码（Transport Error Codes）— 0x0xxx**：

| 错误码 | 名称                      | 说明                             |
| ------ | ------------------------- | -------------------------------- |
| 0x0    | NO_ERROR                  | 无错误（用于 idle timeout 关闭） |
| 0x1    | INTERNAL_ERROR            | 内部实现错误                     |
| 0x2    | CONNECTION_REFUSED        | 连接被拒绝                       |
| 0x3    | FLOW_CONTROL_ERROR        | 流量控制错误                     |
| 0x4    | STREAM_LIMIT_ERROR        | 流数量超限                       |
| 0x5    | STREAM_STATE_ERROR        | 流状态错误（如已关闭的流写入）   |
| 0x6    | FINAL_SIZE_ERROR          | 最终大小错误                     |
| 0x7    | FRAME_ENCODING_ERROR      | 帧编码错误                       |
| 0x8    | TRANSPORT_PARAMETER_ERROR | 传输参数错误                     |
| 0x9    | CONNECTION_ID_LIMIT_ERROR | Connection ID 数量超限           |
| 0xa    | PROTOCOL_VIOLATION        | 协议违规                         |
| 0xb    | INVALID_TOKEN             | 无效的 Token                     |
| 0xc    | APPLICATION_ERROR         | 应用层错误                       |
| 0xd    | CRYPTO_BUFFER_EXCEEDED    | CRYPTO 缓冲区超限                |

**2. 加密错误码（CRYPTO Error Codes）— 0x1xxx**：

TLS 警报被映射到 QUIC 错误码，格式为 `0x1xxx`，其中 `xxx` 是 TLS 警报号。

| 错误码 | TLS 警报            | 说明             |
| ------ | ------------------- | ---------------- |
| 0x100  | handshake_failure   | 握手失败         |
| 0x101  | no_certificate      | 需要证书但未提供 |
| 0x102  | certificate_expired | 证书过期         |
| 0x103  | illegal_parameter   | 非法参数         |
| 0x106  | unknown_ca          | CA 未知          |
| 0x107  | decrypt_error       | 解密错误         |

**3. HTTP/3 错误码 — 0x2xxx**：

| 错误码 | 名称                          | 说明            |
| ------ | ----------------------------- | --------------- |
| 0x200  | H3_NO_ERROR                   | HTTP/3 无错误   |
| 0x201  | H3_GENERAL_PROTOCOL_ERROR     | 通用协议错误    |
| 0x202  | H3_INTERNAL_ERROR             | HTTP/3 内部错误 |
| 0x203  | H3_STREAM_CREATION_ERROR      | 流创建错误      |
| 0x205  | H3_CLOSED_CRITICAL_STREAM     | 关键流被关闭    |
| 0x206  | H3_FRAME_UNEXPECTED           | 意外的帧        |
| 0x207  | H3_FRAME_ERROR                | 帧错误          |
| 0x208  | H3_EXCESSIVE_LOAD             | 过度负载        |
| 0x20a  | H3_ID_ERROR                   | ID 错误         |
| 0x20b  | H3_SETTINGS_ERROR             | 设置错误        |
| 0x20c  | H3_STREAM_STATE_ERROR         | 流状态错误      |
| 0x20d  | H3_INCOMPLETE_STREAM          | 流不完整        |
| 0x20e  | H3_FRAME_ENCODING_ERROR       | 帧编码错误      |
| 0x20f  | H3_QPACK Decompression Failed | QPACK 解压失败  |

### 3.2 错误码选择指南

```
错误码选择决策树：

遇到错误
    |
    +-- 是协议层错误？
    |       |
    |       +-- 是 TLS/加密错误？ -> 使用 0x1xxx 系列
    |       |
    |       +-- 是传输参数/流量控制？ -> 使用 0x0xxx 系列
    |
    +-- 是应用层错误？
            |
            +-- 是 HTTP/3 错误？ -> 使用 0x2xxx 系列
            |
            +-- 是通用应用错误？ -> 使用 0xc (APPLICATION_ERROR)
```

---

## 4. GOAWAY 帧

### 4.1 GOAWAY 的语义

GOAWAY 用于优雅关闭，是 HTTP/2 和 QUIC/HTTP/3 中的重要机制。GOAWAY 不是关闭连接，而是通知对端：我已经决定关闭连接，但你可以在此之前完成正在进行的请求。

```
GOAWAY 语义：

Server 发送 GOAWAY：
  |
  | - 允许 ID < GOAWAY Stream ID 的流继续
  | - 禁止 ID >= GOAWAY Stream ID 的新流
  | - 等待活跃流完成后发送 CONNECTION_CLOSE
  v
```

### 4.2 帧格式

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
| 0x18 (帧类型)                                              |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                        Stream ID (i)                         |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                        Error Code (i)                        |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                   Reason Phrase Length (i)                  |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                        Reason Phrase (...)                   |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

### 4.3 GOAWAY 与 CONNECTION_CLOSE 的交互

```
优雅关闭流程：

1. Server 发送 GOAWAY（带 Stream ID）
   - Stream ID 标记了"最大允许的流 ID"

2. Client 收到 GOAWAY
   - 停止创建新流（ID >= GOAWAY.StreamID）
   - 等待活跃流完成

3. 所有活跃流完成后
   - Server 发送 CONNECTION_CLOSE
   - 连接进入 Draining 状态
```

### 4.4 0-RTT 与 GOAWAY

0-RTT 连接的特殊性在于数据可能在握手完成前发送。如果服务器在 0-RTT 阶段发送 GOAWAY，客户端必须丢弃 0-RTT 数据并重新开始 1-RTT 握手。

```
0-RTT + GOAWAY 场景：

Client                              Server
  |                                    |
  | --- [0-RTT Data] ----------------> |
  |                                    |
  | <-- [GOAWAY] --------------------- |  <- 服务器决定拒绝 0-RTT
  |                                    |
  | [丢弃 0-RTT 数据]                   |
  |                                    |
  | --- [Initial] [1-RTT] -----------> |  <- 重新开始 1-RTT
  |                                    |
```

---

## 5. 优雅关闭 vs 立即关闭

### 5.1 优雅关闭（Graceful Shutdown）

优雅关闭的典型场景：

- 服务器维护（无-downtime 重配置）
- 负载均衡器流量迁移
- 应用程序 graceful shutdown

```
优雅关闭流程：

1. 应用程序发起关闭请求
   |
   v
2. 发送 GOAWAY 帧（带 Stream ID = 最大活跃流 ID）
   |
   v
3. 等待所有活跃流完成
   - 接收完所有数据
   - 发送完所有数据
   - 收到对方的 STREAM COMPLETE
   |
   v
4. 发送 CONNECTION_CLOSE
   |
   v
5. 进入 Draining 状态（3 PTO）
   |
   v
6. 释放所有资源
```

### 5.2 立即关闭（Immediate Close）

立即关闭的典型场景：

- 检测到协议违规
- 加密握手失败
- 应用程序强制终止
- 遭受攻击（如泛洪攻击）

```
立即关闭流程：

1. 检测到错误
   |
   v
2. 发送 CONNECTION_CLOSE（立即）
   - 使用合适的错误码
   - 包含 Reason Phrase
   |
   v
3. 进入 Draining 状态
   - 停止发送新数据
   - 继续发送 ACK（处理网络遗留包）
   |
   v
4. 3 * PTO 后释放资源
```

### 5.3 关闭方式对比

| 特性         | 优雅关闭                  | 立即关闭            |
| ------------ | ------------------------- | ------------------- |
| 帧类型       | GOAWAY + CONNECTION_CLOSE | 仅 CONNECTION_CLOSE |
| 等待时间     | 等待活跃流完成            | 立即进入 Draining   |
| 资源释放     | 流完成即释放              | 3 \* PTO 后释放     |
| 典型用途     | 服务器维护                | 错误处理            |
| 对客户端影响 | 允许完成请求              | 强制断开            |

---

## 6. 关闭过程中的状态转换

### 6.1 完整关闭状态机

```
连接关闭状态转换完整图：

     Active                              Draining
       |                                    |
       | GOAWAY + CONNECTION_CLOSE          | idle timeout / 错误
       v                                    |
  +-----------+                            |
  | Draining  |                            |
  +-----------+                            |
       |                                    |
       | 收到 CONNECTION_CLOSE + ACK       |
       v                                    |
  +-----------+                            |
  |  Closing  | <--------------------------+
  +-----------+      3 * PTO timer
       |
       | timer expires
       v
  +-----------+
  |  Closed   |
  +-----------+
```

### 6.2 双端关闭不对称

QUIC 允许两端独立关闭：

```
双端独立关闭：

Client 发送 CONNECTION_CLOSE：
  - Client 进入 Draining
  - Server 仍可发送数据（Server -> Client 方向）
  - 最终 Server 也发送 CONNECTION_CLOSE

这与 TCP 的四次挥手不同，QUIC 可以更快速关闭。
```

### 6.3 0-RTT 连接的特殊关闭

0-RTT 连接的关闭有额外复杂性：

1. **0-RTT 数据被拒绝**：
   - 服务器发送 GOAWAY + REJECTED
   - 客户端丢弃 0-RTT 数据
   - 重新发起 1-RTT 握手

2. **0-RTT 重放检测**：
   - 如果 0-RTT 数据被检测为重放
   - 服务器发送 CONNECTION_CLOSE + 0x103 (unexpected_message)

---

## 7. 资源回收

### 7.1 连接关闭后的资源清理

进入 Closed 状态后，必须释放以下资源：

```python
def cleanup_connection():
    # 1. 定时器资源
    cancel_timer(idle_timer)
    cancel_timer(PTO_timer)
    cancel_timer(keepalive_timer)

    # 2. 流资源
    for stream in active_streams:
        stream.close()
    clear_stream_state()

    # 3. 连接状态
    clear_connection_keys()
    clear_pn_space_states()

    # 4. 内存资源
    release_crypto_buffer()
    release_flow_control_window()

    # 5. 网络资源
    close_socket()
    release_port()
```

### 7.2 状态持久化（Session Ticket）

对于可恢复的连接，服务器可以在关闭前生成 Session Ticket：

```
Session Ticket 生成流程：

1. 连接处于 Active 状态
2. 应用程序请求会话恢复
3. 服务器生成 NewSessionTicket
4. 客户端保存 Ticket
5. 连接关闭
6. 下次连接时，客户端发送 Ticket
7. 服务器恢复连接状态
```

### 7.3 连接关闭与 HTTP/3

HTTP/3 层的关闭会触发 QUIC 层的 CONNECTION_CLOSE：

```python
def http3_close(error_code=H3_NO_ERROR):
    # 1. 发送 HTTP/3 GOAWAY
    send GOAWAY with error_code

    # 2. 关闭所有流
    for stream in active_streams:
        send RESET_STREAM on stream

    # 3. 发送 QUIC CONNECTION_CLOSE
    send CONNECTION_CLOSE with
        frame_type = 0x0  # 表示无触发帧
        error_code = error_code
```

---

## 8. 小结

本章深入解析了 QUIC 连接关闭机制：

1. **CONNECTION_CLOSE 帧**：两种变体（Application/Initial-Handshake），携带错误码和 Reason Phrase

2. **错误码体系**：传输错误（0x0xxx）、加密错误（0x1xxx）、HTTP/3 错误（0x2xxx）

3. **GOAWAY 帧**：优雅关闭机制，允许活跃流完成后关闭

4. **优雅关闭 vs 立即关闭**：分别服务于维护和错误处理场景

5. **资源回收**：进入 Closed 状态后必须释放所有资源

理解连接关闭机制对于构建健壮的 QUIC 实现至关重要。下一章我们将讨论地址验证——QUIC 连接安全的核心机制。
