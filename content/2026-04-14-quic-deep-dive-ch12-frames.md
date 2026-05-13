---
title: "QUIC 深度探索 ch12 - 帧类型全览"
date: 2026-04-14
description: "全面解析 QUIC 的帧类型体系：Type 字段编码规则、各帧的二进制格式与语义，涵盖 PADDING/PING/ACK/RESET_STREAM/STOP_SENDING/CRYPTO/STREAM/DATA_BLOCKED 等全部帧类型"
tags:
  - quic
  - series
  - frames
  - wire-format
  - ack
  - stream
---

# QUIC 深度探索 ch12 - 帧类型全览

> [!tip] 本章内容
> 本章系统梳理 QUIC 帧类型体系，从 Type 编码规则入手，逐一解析 RFC 9000 定义的全部 24 种帧类型的二进制格式、字段语义、允许出现的包类型及常见使用场景。

---

## 1. 帧的基本结构

QUIC 数据包的有效负载（Payload）由零个或多个帧（Frame）串联而成。每个帧以一个可变长整数（Variable-Length Integer）标识帧类型：

```
帧的通用结构：

 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+
|   Frame Type  |  ← Variable-Length Integer（1/2/4/8 字节）
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|             Frame-specific Fields ...                         |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

### 1.1 可变长整数编码

QUIC 使用两位前缀（MSB）对整数的字节长度进行编码：

```
可变长整数（Variable-Length Integer）编码：

  Prefix  │ 字节数 │ 可编码范围
 ─────────┼────────┼──────────────────
  00      │  1     │  0 - 63
  01      │  2     │  64 - 16383
  10      │  4     │  16384 - 1073741823
  11      │  8     │  1073741824 - 4611686018427387903

示例：
  0x0a          = 10 (1 字节)
  0x4000        = 16384 (2 字节，0100 0000 0000 0000)
  0x80000000    = 大值 (4 字节)
```

### 1.2 帧对 ACK 触发性的分类

| 类型 | 说明 |
|------|------|
| ACK-eliciting | 包含此类帧的数据包必须触发对端发送 ACK |
| Non-ACK-eliciting | 包含此类帧的数据包不要求对端 ACK |

只含 ACK、PADDING 或 CONNECTION_CLOSE 的数据包为 Non-ACK-eliciting。

---

## 2. 帧类型编号总表

| 类型值（十六进制）| 帧名称 | ACK-eliciting | 可用包类型 |
|-----------------|--------|---------------|------------|
| 0x00 | PADDING | ✗ | IH01 |
| 0x01 | PING | ✓ | IH01 |
| 0x02-0x03 | ACK | ✗ | IH_1 |
| 0x04 | RESET_STREAM | ✓ | __01 |
| 0x05 | STOP_SENDING | ✓ | __01 |
| 0x06 | CRYPTO | ✓ | IH_1 |
| 0x07 | NEW_TOKEN | ✓ | ___1 |
| 0x08-0x0f | STREAM | ✓ | __01 |
| 0x10 | MAX_DATA | ✓ | __01 |
| 0x11 | MAX_STREAM_DATA | ✓ | __01 |
| 0x12-0x13 | MAX_STREAMS | ✓ | __01 |
| 0x14 | DATA_BLOCKED | ✓ | __01 |
| 0x15 | STREAM_DATA_BLOCKED | ✓ | __01 |
| 0x16-0x17 | STREAMS_BLOCKED | ✓ | __01 |
| 0x18 | NEW_CONNECTION_ID | ✓ | __01 |
| 0x19 | RETIRE_CONNECTION_ID | ✓ | __01 |
| 0x1a | PATH_CHALLENGE | ✓ | __01 |
| 0x1b | PATH_RESPONSE | ✓ | ___1 |
| 0x1c-0x1d | CONNECTION_CLOSE | ✗ | IH01 |
| 0x1e | HANDSHAKE_DONE | ✓ | ___1 |
| 0x30-0x31 | DATAGRAM（扩展） | ✓ | __01 |

> 包类型列：I=Initial, H=Handshake, 0=0-RTT, 1=1-RTT, _=不可用

---

## 3. 各帧类型详解

### 3.1 PADDING 帧（0x00）

```
PADDING 帧格式：
  +-+-+-+-+-+-+-+-+
  |0 0 0 0 0 0 0 0|  ← 单字节 0x00，可连续多个
  +-+-+-+-+-+-+-+-+
```

用途：
- 填充数据包到最小 UDP 大小（防止路径 MTU 探测失败）
- 使数据包看起来一样大（减少流量指纹）
- 使 Initial 包填满到 1200 字节（RFC 9000 §14.1 要求）

```
Initial 包填充规则：
  客户端发送的第一个 Initial 包至少需要 1200 字节（PMTU 要求）
  若 ClientHello 数据不足 1200 字节，则用 PADDING 帧填满
```

### 3.2 PING 帧（0x01）

```
PING 帧格式：
  +-+-+-+-+-+-+-+-+
  |0 0 0 0 0 0 0 1|  ← 单字节 0x01
  +-+-+-+-+-+-+-+-+
```

用途：
- 心跳保活（保持 NAT 映射不超时）
- 强制对端发送 ACK（探测对端是否在线）
- 探测路径（与 PATH_CHALLENGE 配合）

### 3.3 ACK 帧（0x02 / 0x03）

ACK 帧是最复杂的帧类型之一，详见 ch14。简要格式：

```
ACK 帧格式（0x02 无 ECN，0x03 有 ECN）：
  +-+-+-+-+-+-+-+-+
  |   0x02 / 0x03  |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |                   Largest Acknowledged (i)                    |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |                       ACK Delay (i)                           |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |                    ACK Range Count (i)                        |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |                       First ACK Range (i)                     |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |                       [ ACK Ranges... ]                       |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |            [ ECN Counts (仅 0x03) ]                           |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

### 3.4 RESET_STREAM 帧（0x04）

用于单向终止一个 Stream（发送方丢弃该 Stream 的数据）：

```
RESET_STREAM 帧格式：
  +-+-+-+-+-+-+-+-+
  |      0x04      |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |                        Stream ID (i)                          |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |                  Application Protocol Error Code (i)          |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |                        Final Size (i)                         |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

| 字段 | 说明 |
|------|------|
| Stream ID | 要重置的 Stream 编号 |
| Application Protocol Error Code | 上层应用错误码（如 HTTP/3 定义的错误码） |
| Final Size | 发送方声明的该 Stream 数据总字节数（即使未发完） |

### 3.5 STOP_SENDING 帧（0x05）

用于请求对端停止发送某个 Stream 的数据（接收方发出）：

```
STOP_SENDING 帧格式：
  +-+-+-+-+-+-+-+-+
  |      0x05      |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |                        Stream ID (i)                          |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |                  Application Protocol Error Code (i)          |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

### 3.6 CRYPTO 帧（0x06）

用于传输 TLS 握手消息，详见 ch15。

```
CRYPTO 帧格式：
  +-+-+-+-+-+-+-+-+
  |      0x06      |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |                          Offset (i)                           |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |                          Length (i)                           |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |                      Crypto Data (*)                          |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

### 3.7 NEW_TOKEN 帧（0x07）

服务端发送给客户端，用于下次连接建立时的地址验证（免去 Retry 往返）：

```
NEW_TOKEN 帧格式：
  +-+-+-+-+-+-+-+-+
  |      0x07      |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |                     Token Length (i)                          |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |                          Token (*)                            |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

### 3.8 STREAM 帧（0x08-0x0f）

用于承载应用层字节流数据，详见 ch13。类型值的低 3 位是标志位：

```
STREAM 帧类型编码：
  0 0 0 0 1 O F L
             │ │ └── LEN bit：是否有 Length 字段
             │ └──── FIN bit：是否是 Stream 的最后一帧
             └────── OFF bit：是否有 Offset 字段
```

### 3.9 MAX_DATA 帧（0x10）

连接级流量控制：更新接收端愿意接收的总字节数上限：

```
MAX_DATA 帧格式：
  +-+-+-+-+-+-+-+-+
  |      0x10      |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |                      Maximum Data (i)                         |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

### 3.10 MAX_STREAM_DATA 帧（0x11）

Stream 级流量控制：更新某个 Stream 的接收数据上限：

```
MAX_STREAM_DATA 帧格式：
  +-+-+-+-+-+-+-+-+
  |      0x11      |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |                        Stream ID (i)                          |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |                   Maximum Stream Data (i)                     |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

### 3.11 MAX_STREAMS 帧（0x12 / 0x13）

更新对端可以并发打开的 Stream 数量上限：

```
MAX_STREAMS 帧格式：
  +-+-+-+-+-+-+-+-+
  | 0x12 or 0x13  |   ← 0x12=双向Stream限制, 0x13=单向Stream限制
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |                   Maximum Streams (i)                         |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

### 3.12 DATA_BLOCKED 帧（0x14）

发送方被连接级流量控制阻塞，通知接收方更新 MAX_DATA：

```
DATA_BLOCKED 帧格式：
  +-+-+-+-+-+-+-+-+
  |      0x14      |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |                    Maximum Data (i)                           |  ← 当前阻塞在哪个限制
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

### 3.13 STREAM_DATA_BLOCKED 帧（0x15）

发送方被 Stream 级流量控制阻塞：

```
STREAM_DATA_BLOCKED 帧格式：
  +-+-+-+-+-+-+-+-+
  |      0x15      |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |                        Stream ID (i)                          |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |                 Maximum Stream Data (i)                       |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

### 3.14 STREAMS_BLOCKED 帧（0x16 / 0x17）

发送方无法打开新 Stream（受并发限制）：

```
STREAMS_BLOCKED 帧格式：
  +-+-+-+-+-+-+-+-+
  | 0x16 or 0x17  |   ← 0x16=双向, 0x17=单向
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |                   Maximum Streams (i)                         |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

### 3.15 NEW_CONNECTION_ID 帧（0x18）

提供新的 Connection ID，用于连接迁移：

```
NEW_CONNECTION_ID 帧格式：
  +-+-+-+-+-+-+-+-+
  |      0x18      |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |                      Sequence Number (i)                      |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |                        Retire Prior To (i)                    |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |  Length (8)   |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |                    Connection ID (8..160)                     |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |               Stateless Reset Token (128)                     |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

| 字段 | 说明 |
|------|------|
| Sequence Number | CID 的序列号，用于去重 |
| Retire Prior To | 序列号小于此值的 CID 应被 RETIRE_CONNECTION_ID |
| Length | CID 长度（1-20 字节）|
| Connection ID | 新的 CID 值 |
| Stateless Reset Token | 128-bit 无状态重置 Token（用于 Stateless Reset） |

### 3.16 RETIRE_CONNECTION_ID 帧（0x19）

废弃不再使用的 Connection ID：

```
RETIRE_CONNECTION_ID 帧格式：
  +-+-+-+-+-+-+-+-+
  |      0x19      |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |                      Sequence Number (i)                      |   ← 要废弃的 CID 的序号
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

### 3.17 PATH_CHALLENGE 帧（0x1a）

路径验证：发送一个随机数，等待对端回复 PATH_RESPONSE：

```
PATH_CHALLENGE 帧格式：
  +-+-+-+-+-+-+-+-+
  |      0x1a      |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |                         Data (64)                             |   ← 8 字节随机数
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

### 3.18 PATH_RESPONSE 帧（0x1b）

回应 PATH_CHALLENGE，回显相同的 Data 字段：

```
PATH_RESPONSE 帧格式：
  +-+-+-+-+-+-+-+-+
  |      0x1b      |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |                         Data (64)                             |   ← 与 PATH_CHALLENGE 相同的 8 字节
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

### 3.19 CONNECTION_CLOSE 帧（0x1c / 0x1d）

关闭连接，携带错误码和错误原因：

```
CONNECTION_CLOSE 帧格式：
  +-+-+-+-+-+-+-+-+
  | 0x1c or 0x1d  |   ← 0x1c=QUIC层错误, 0x1d=应用层错误
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |                       Error Code (i)                          |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |  [Frame Type (i)]  ← 仅 0x1c 有此字段（导致错误的帧类型）
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |                    Reason Phrase Length (i)                    |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |                      Reason Phrase (*)                        |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

常用错误码：

| 错误码 | 名称 | 含义 |
|--------|------|------|
| 0x00 | NO_ERROR | 正常关闭 |
| 0x01 | INTERNAL_ERROR | 内部错误 |
| 0x02 | CONNECTION_REFUSED | 连接被拒绝 |
| 0x03 | FLOW_CONTROL_ERROR | 流量控制违规 |
| 0x04 | STREAM_LIMIT_ERROR | Stream 数量超限 |
| 0x05 | STREAM_STATE_ERROR | Stream 状态错误 |
| 0x06 | FINAL_SIZE_ERROR | Final Size 不一致 |
| 0x07 | FRAME_ENCODING_ERROR | 帧编码错误 |
| 0x08 | TRANSPORT_PARAMETER_ERROR | 传输参数错误 |
| 0x0a | PROTOCOL_VIOLATION | 协议违规 |
| 0x0e | CRYPTO_ERROR | TLS 错误（高 8 位为 TLS Alert 码）|

### 3.20 HANDSHAKE_DONE 帧（0x1e）

服务端向客户端发送，表示握手已完成（仅服务端发）：

```
HANDSHAKE_DONE 帧格式：
  +-+-+-+-+-+-+-+-+
  |      0x1e      |   ← 单字节
  +-+-+-+-+-+-+-+-+
```

> [!note] HANDSHAKE_DONE 的作用
> 客户端在收到 HANDSHAKE_DONE 后才能废弃 Handshake 密钥，并确认握手完成。这防止了一种攻击：攻击者在服务端未确认握手完成前伪造 Finished 消息。

### 3.21 DATAGRAM 帧（0x30 / 0x31，RFC 9221 扩展）

无序、无可靠性保证的数据报帧（类似 UDP over QUIC）：

```
DATAGRAM 帧格式：
  +-+-+-+-+-+-+-+-+
  | 0x30 or 0x31  |   ← 0x30=无 Length 字段（到包末）, 0x31=有 Length 字段
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |              [ Length (i) ]  ← 仅 0x31 有此字段
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
  |                      Datagram Data (*)                        |
  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

---

## 4. 帧类型设计原则

### 4.1 帧的幂等性

QUIC 要求帧的重传行为是安全的。接收端必须能够处理重复接收的帧：

```
幂等性规则：
  ✓ PADDING/PING：幂等（无状态影响）
  ✓ ACK：幂等（相同 ACK 发多次无副作用）
  ✓ MAX_DATA：幂等（接收更大的值才更新窗口）
  ✓ STREAM：幂等（通过 Offset 去重）
  ✓ CRYPTO：幂等（通过 Offset 去重）
  ✓ CONNECTION_CLOSE：幂等（连接已关闭则忽略）
```

### 4.2 帧的包类型约束

```
包类型对帧的约束：
  Initial 包：只能含 PADDING, PING, ACK, CRYPTO, CONNECTION_CLOSE(0x1c)
  Handshake 包：只能含 PADDING, PING, ACK, CRYPTO, CONNECTION_CLOSE(0x1c)
  0-RTT 包：可含 STREAM, DATAGRAM, MAX_DATA 等，但不能含 ACK
  1-RTT 包：可含所有帧类型
```

### 4.3 Extension Frames（扩展帧）

QUIC 支持通过扩展帧增加新功能，扩展帧的类型值通过 IANA 注册。已标准化的扩展帧：

| 类型值 | 帧名称 | 来源 RFC |
|--------|--------|---------|
| 0x30-0x31 | DATAGRAM | RFC 9221 |
| 0xbaba05 | ACK_FREQUENCY | draft-ietf |
| 0x02 (扩展) | ACK + ECN | RFC 9000 §19.3.2 |

---

## 5. 帧解析流程（伪代码）

```python
def parse_quic_payload(data: bytes, packet_type: PacketType):
    pos = 0
    frames = []
    
    while pos < len(data):
        frame_type, consumed = decode_varint(data[pos:])
        pos += consumed
        
        if frame_type == 0x00:
            # PADDING — skip all consecutive 0x00
            while pos < len(data) and data[pos] == 0x00:
                pos += 1
            frames.append(PaddingFrame())
        
        elif frame_type == 0x01:
            frames.append(PingFrame())
        
        elif frame_type in (0x02, 0x03):
            frame, consumed = parse_ack_frame(data[pos:], has_ecn=(frame_type == 0x03))
            pos += consumed
            frames.append(frame)
        
        elif 0x08 <= frame_type <= 0x0f:
            has_off = bool(frame_type & 0x04)
            has_len = bool(frame_type & 0x02)
            has_fin = bool(frame_type & 0x01)
            frame, consumed = parse_stream_frame(data[pos:], has_off, has_len, has_fin)
            pos += consumed
            frames.append(frame)
        
        else:
            frame, consumed = parse_generic_frame(frame_type, data[pos:])
            pos += consumed
            frames.append(frame)
    
    return frames
```

---

## 小结

本章系统梳理了 QUIC 帧类型体系的全貌：

- **连接管理类帧**：NEW_CONNECTION_ID / RETIRE_CONNECTION_ID / PATH_CHALLENGE / PATH_RESPONSE 支撑连接迁移
- **流量控制类帧**：MAX_DATA / MAX_STREAM_DATA / MAX_STREAMS / DATA_BLOCKED / STREAM_DATA_BLOCKED / STREAMS_BLOCKED 构成双层流量控制体系
- **数据传输类帧**：STREAM / CRYPTO / DATAGRAM 承载实际数据
- **连接关闭类帧**：CONNECTION_CLOSE / HANDSHAKE_DONE 管理连接生命周期

后续章节将对其中最重要的三类帧（STREAM、ACK、CRYPTO）进行深度剖析。
