---
title: "QUIC 深度探索 ch13 - STREAM 帧深度解析"
date: 2026-04-14
description: "深入剖析 QUIC STREAM 帧的二进制格式、Stream ID 编码规则、OFF/LEN/FIN 标志位语义、数据分片与重组、流状态机以及流量控制交互"
tags:
  - quic
  - series
  - stream
  - frames
  - flow-control
  - multiplexing
---

# QUIC 深度探索 ch13 - STREAM 帧深度解析

> [!tip] 本章内容
> 本章深入剖析 QUIC STREAM 帧的完整机制：Stream ID 的编码与语义、OFF/LEN/FIN 三个标志位的作用、数据分片与有序重组、Stream 状态机，以及 STREAM 帧与流量控制的交互关系。

---

## 1. STREAM 帧格式

STREAM 帧的类型值范围为 0x08-0x0f，低 3 位作为标志位，灵活控制可选字段的存在：

```
STREAM 帧类型字节（低 3 位为标志）：

  0 0 0 0 1 O F L
            │ │ └── LEN  bit (bit 0): 1=有 Length 字段, 0=数据延伸到包末
            │ └──── FIN  bit (bit 1): 1=此帧是 Stream 的最后一个帧
            └────── OFF  bit (bit 2): 1=有 Offset 字段, 0=Offset 隐式为 0

完整类型值映射：
  0x08 = 0b00001000 = OFF=0, FIN=0, LEN=0
  0x09 = 0b00001001 = OFF=0, FIN=0, LEN=1
  0x0a = 0b00001010 = OFF=0, FIN=1, LEN=0
  0x0b = 0b00001011 = OFF=0, FIN=1, LEN=1
  0x0c = 0b00001100 = OFF=1, FIN=0, LEN=0
  0x0d = 0b00001101 = OFF=1, FIN=0, LEN=1
  0x0e = 0b00001110 = OFF=1, FIN=1, LEN=0
  0x0f = 0b00001111 = OFF=1, FIN=1, LEN=1
```

### 1.1 完整 STREAM 帧格式

```
STREAM 帧（0x08-0x0f）：

 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+
| 0x08 to 0x0f  |   ← 帧类型（编码 O/F/L 标志）
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                        Stream ID (i)                          |   ← 必选
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                    [ Offset (i) ]                             |   ← 仅 OFF=1 时出现
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                    [ Length (i) ]                             |   ← 仅 LEN=1 时出现
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                      Stream Data (*)                          |   ← 必选
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

### 1.2 各字段说明

| 字段 | 是否可选 | 类型 | 说明 |
|------|---------|------|------|
| Stream ID | 必选 | Variable-length int | Stream 编号，标识所属流 |
| Offset | 可选（OFF=1 时有） | Variable-length int | 本帧数据在 Stream 中的起始字节偏移 |
| Length | 可选（LEN=1 时有） | Variable-length int | Stream Data 的字节长度 |
| Stream Data | 必选 | 字节序列 | 实际的应用层数据 |

> [!note] OFF=0 时 Offset 为 0
> 当 OFF=0 时，隐式 Offset=0，意味着该帧是此 Stream 的第一帧（从字节偏移 0 开始）。这节省了每个首帧的 Offset 字段开销。

> [!note] LEN=0 时数据到包末
> 当 LEN=0 时，Stream Data 从当前位置延续到 QUIC 包的末尾。这通常用于包内最后一个 STREAM 帧（省去 Length 字段）。

---

## 2. Stream ID 编码

### 2.1 Stream ID 的语义编码

Stream ID 是一个 62-bit 无符号整数，但低 2 位有特殊含义：

```
Stream ID 编码（低 2 位）：

  bit 0：发起方身份
    0 = 客户端发起的 Stream
    1 = 服务端发起的 Stream

  bit 1：流的方向
    0 = 双向 Stream（Bidirectional）
    1 = 单向 Stream（Unidirectional）

Stream ID 分类：
  0, 4, 8, ...    → 客户端发起的双向流
  1, 5, 9, ...    → 服务端发起的双向流
  2, 6, 10, ...   → 客户端发起的单向流
  3, 7, 11, ...   → 服务端发起的单向流
```

### 2.2 Stream ID 分配规则

```
Stream ID 分配示例（客户端视角）：

  客户端发起双向流：   0, 4, 8, 12, ...（每次 +4）
  客户端发起单向流：   2, 6, 10, 14, ...（每次 +4）
  服务端发起双向流：   1, 5, 9, 13, ...（由服务端分配，客户端只读）
  服务端发起单向流：   3, 7, 11, 15, ...（由服务端分配，客户端只读）

Stream ID 大小规则：
  发起方必须按顺序使用 Stream ID（不能跳过）
  Stream ID = 4 表示同方向已打开了 ID 0 的 Stream（或在限制范围内）
```

### 2.3 HTTP/3 的 Stream ID 约定

```
HTTP/3 对 QUIC Stream 的使用：

  Stream 0 (双向，客户端发起)：HTTP/3 Request Stream（第一个请求）
  Stream 4 (双向，客户端发起)：HTTP/3 Request Stream（第二个请求）
  ...
  
  Stream 2 (单向，客户端发起)：HTTP/3 Control Stream（发送 SETTINGS 帧）
  Stream 3 (单向，服务端发起)：HTTP/3 Control Stream（服务端 SETTINGS）
  Stream 6 (单向，客户端发起)：QPACK Encoder Stream
  Stream 7 (单向，服务端发起)：QPACK Encoder Stream
  Stream 10 (单向，客户端发起)：QPACK Decoder Stream
  Stream 11 (单向，服务端发起)：QPACK Decoder Stream
```

---

## 3. Stream 状态机

### 3.1 发送方状态机

```
QUIC Stream 发送方状态机（RFC 9000 §3.1）：

          打开 Stream（本端发起）
                 │
                 ▼
         ┌─────────────┐
         │    Ready    │  ← 已创建，等待发送数据
         └──────┬──────┘
                │  发送 STREAM 帧 (非 FIN)
                ▼
         ┌─────────────┐
         │    Send     │  ← 正在发送数据
         └──────┬──────┘
                │  发送最后一个 STREAM 帧 (FIN=1)
                ▼
         ┌─────────────┐
         │  Data Sent  │  ← 所有数据已发出，等待 ACK
         └──────┬──────┘
                │  所有数据均被 ACK
                ▼
         ┌─────────────┐
         │  Data Rcvd  │  ← 终止状态（发送完成）
         └─────────────┘

  任意状态 → Reset Sent（发送 RESET_STREAM 帧）→ Reset Rcvd
```

### 3.2 接收方状态机

```
QUIC Stream 接收方状态机（RFC 9000 §3.2）：

         对端打开 Stream（收到 STREAM 帧）
                 │
                 ▼
         ┌─────────────┐
         │    Recv     │  ← 正在接收数据
         └──────┬──────┘
                │  收到 FIN bit
                ▼
         ┌─────────────┐
         │  Size Known │  ← 知道 Stream 总长度，等待乱序数据补全
         └──────┬──────┘
                │  所有数据收到并交付给应用
                ▼
         ┌─────────────┐
         │  Data Rcvd  │  ← 终止状态（接收完成）
         └─────────────┘

         │收到 RESET_STREAM
                ▼
         ┌─────────────┐
         │ Reset Rcvd  │  → Reset Read（应用层读到错误）
         └─────────────┘
```

---

## 4. 数据分片与重组

### 4.1 为什么需要分片

```
数据分片必要性：

  应用层写入数据大小 >> QUIC 包能容纳的大小
  
  示例：发送 100 KB HTTP/3 Response Body：
  
    Packet 1 (1200 bytes):
      STREAM(id=0, offset=0,    len=1150, FIN=0, data=...)
    
    Packet 2 (1200 bytes):
      STREAM(id=0, offset=1150, len=1150, FIN=0, data=...)
    
    ...
    
    Packet 87 (450 bytes):
      STREAM(id=0, offset=99750, len=250, FIN=1, data=...)
```

### 4.2 乱序重组

QUIC 保证 Stream 内的字节有序交付（Stream-level ordering），即使底层数据包乱序到达：

```
乱序重组示例：

  发出顺序：  Pkt1(offset=0)    Pkt2(offset=1150)  Pkt3(offset=2300)
  到达顺序：  Pkt1(offset=0)    Pkt3(offset=2300)  Pkt2(offset=1150)
  
  接收端缓冲区：
    [offset=0,    1150 bytes]  ← 已交付给应用
    [offset=1150, 空缺]        ← 等待 Pkt2
    [offset=2300, 1150 bytes]  ← 缓存，等待补全
  
  Pkt2 到达后：
    [offset=0,    3450 bytes]  ← 全部交付给应用
```

### 4.3 重传与不可变性原则

```
QUIC STREAM 重传规则：

  ① 丢包检测后，发送方重传 Stream 数据
  ② 重传的数据必须使用相同的 Stream ID 和 Offset
  ③ 重传的数据可以分在不同的 STREAM 帧中（只要覆盖相同字节范围）
  ④ 重传包使用新的 Packet Number（QUIC 不重用 PN）

错误案例（禁止）：
  原始帧：STREAM(id=0, offset=100, len=500)
  重传帧：STREAM(id=0, offset=100, len=200)  + STREAM(id=0, offset=300, len=300)
  ← 允许！只要数据内容相同，可以改变分片方式

错误案例（严格禁止）：
  重传时修改数据内容 → 接收方检测到 Final Size 冲突 → FINAL_SIZE_ERROR
```

---

## 5. FIN 标志与 Stream 终止

### 5.1 FIN bit 的语义

```
FIN bit 含义：

  FIN=1 表示：此帧携带的是 Stream 的最后一段数据，发送方不再发送更多数据

  FIN 帧的 Offset + Length = Stream 的 Final Size（总字节数）
  
  示例：
    STREAM(id=0, offset=9900, len=100, FIN=1)
    → Stream 0 的 Final Size = 9900 + 100 = 10000 字节

  空 FIN：允许发送空 Data 且 FIN=1，表示已发完
    STREAM(id=0, offset=10000, len=0, FIN=1)
    → 表示 Stream 0 共 10000 字节，无额外数据
```

### 5.2 RESET_STREAM vs FIN

```
正常关闭 vs 强制重置：

  正常关闭（FIN）：
    发送方：发送最后一个 STREAM 帧，FIN=1
    接收方：等待所有字节收到，交付给应用
    语义：数据完整传输完毕

  强制重置（RESET_STREAM）：
    发送方：发送 RESET_STREAM 帧，携带错误码和 Final Size
    接收方：丢弃已缓存的数据，通知应用发生错误
    语义：传输中断，数据可能不完整
    
  对端请求停止（STOP_SENDING）：
    接收方：发送 STOP_SENDING 帧，请求发送方停止
    发送方：响应 RESET_STREAM（应用层决定是否停止）
```

---

## 6. 流量控制与 STREAM 帧

### 6.1 双层流量控制

```
QUIC 流量控制的两个维度：

  连接级（Connection-level）：
    控制整个连接上所有 Stream 的累计接收字节数
    限制：connection_max_data（initial_max_data transport parameter）
    更新：MAX_DATA 帧

  Stream 级（Stream-level）：
    控制单个 Stream 的接收字节数
    限制：stream_max_data（initial_max_stream_data transport parameter）
    更新：MAX_STREAM_DATA 帧
```

### 6.2 流量控制的信用计算

```
发送方流量控制信用：

  可发送字节数 = min(
    connection_send_window,     ← 连接级可用窗口
    stream_send_window          ← Stream 级可用窗口
  )

  connection_send_window = max_data_limit - bytes_sent_on_all_streams
  stream_send_window = stream_max_data - bytes_sent_on_stream

示例：
  initial_max_data = 100000
  initial_max_stream_data_bidi_local = 50000
  
  Stream 0 发送了 30000 字节：
    connection_send_window = 100000 - 30000 = 70000
    stream_0_send_window = 50000 - 30000 = 20000
    实际可发 = min(70000, 20000) = 20000 字节
```

### 6.3 流控死锁预防

```
流控死锁场景（应避免）：

  Client 端：等待 MAX_DATA 更新才能继续发送
  Server 端：等待 Client 发送数据才能处理并更新 MAX_DATA
  → 死锁！

解决方案：
  ① 接收方在应用层消费数据后及时发送 MAX_DATA / MAX_STREAM_DATA
  ② 实现上通常在接收窗口消耗 50% 时即发送更新
  ③ 发送方检测到被阻塞时发送 DATA_BLOCKED 帧通知接收方
```

---

## 7. 单向 Stream vs 双向 Stream

### 7.1 双向 Stream

```
双向 Stream（Bidirectional）：
  两端都可以发送数据（类似 TCP 全双工）
  
  Stream 0（客户端发起双向）：
    客户端 → 服务端：请求数据
    服务端 → 客户端：响应数据
  
  适用场景：HTTP/3 Request/Response
```

### 7.2 单向 Stream

```
单向 Stream（Unidirectional）：
  只有发起方可以发送数据，对端只能接收
  
  Stream 2（客户端发起单向）：
    客户端 → 服务端：HTTP/3 Control Stream（SETTINGS 帧等）
    服务端 → 客户端：不可发送
  
  适用场景：
    ① HTTP/3 Control Streams
    ② QPACK Encoder/Decoder Streams
    ③ Server Push（服务端单向推送）
```

### 7.3 流量控制参数的分离

单向和双向 Stream 有独立的流控参数：

| Transport Parameter | 适用场景 |
|---------------------|---------|
| initial_max_stream_data_bidi_local | 本端发起双向流的初始发送窗口 |
| initial_max_stream_data_bidi_remote | 对端发起双向流的初始接收窗口 |
| initial_max_stream_data_uni | 所有单向流的初始窗口（收发共用） |
| initial_max_streams_bidi | 可并发的双向流数量上限 |
| initial_max_streams_uni | 可并发的单向流数量上限 |

---

## 8. STREAM 帧的实际抓包

```
Wireshark 过滤与字段解析：

  # 仅显示 STREAM 帧
  quic.frame_type >= 0x08 && quic.frame_type <= 0x0f

  # 解析特定字段
  tshark -r cap.pcap -Y quic -T fields \
    -e quic.stream.stream_id \
    -e quic.stream.offset \
    -e quic.stream.length \
    -e quic.stream.fin

十六进制示例（STREAM 帧 0x0d，OFF=1/FIN=0/LEN=1）：

  0d                   ← 帧类型（OFF=1, FIN=0, LEN=1）
  00                   ← Stream ID = 0（可变长 1 字节）
  40 64                ← Offset = 100（可变长 2 字节：0x40 前缀=2B）
  44 b0                ← Length = 1200（0x44b0 解码：0b01 prefix → 2 字节，value=0x04b0=1200）
  [1200 字节数据]       ← Stream Data
```

---

## 9. 性能优化建议

### 9.1 帧的打包策略

```
发包优化：

  ① 尽量合并多个 Stream 的数据到一个包
     → 减少 UDP 包数量，提高吞吐
  
  ② 优先使用 LEN=0 省去 Length 字段（包内最后一帧）
     → 节省 1-2 字节
  
  ③ 第一帧省去 Offset（OFF=0，隐式为 0）
     → 节省 1-2 字节
  
  ④ 使用最小可变长整数编码 Stream ID 和 Offset
     → 小 Stream ID（<64）使用 1 字节，大 ID 使用 2-8 字节
```

### 9.2 避免流控阻塞

```
流控调优建议：

  ① 增大 initial_max_data（默认 64KB 通常不够高带宽场景）
     → 建议设置为 BDP（带宽延迟积）的 4-8 倍
  
  ② 及时更新窗口（收到 50% 数据时即发 MAX_DATA）
     → 防止发送方饥饿
  
  ③ 高并发场景适当增大 initial_max_streams_bidi
     → HTTP/3 每个请求一个 Stream，1000 并发请求需 1000 个流
```

---

## 小结

STREAM 帧是 QUIC 应用数据传输的核心：

- **Stream ID 低 2 位**编码了发起方（客户端/服务端）和方向（双向/单向）
- **OFF/FIN/LEN 标志位**灵活控制可选字段的存在与否，优化常用场景的编码
- **分片与重组**：发送方自由分片，接收方通过 Offset 实现有序重组
- **FIN 标志**显式标记 Stream 结束，Final Size 不可修改
- **双层流控**：连接级 MAX_DATA + Stream 级 MAX_STREAM_DATA 共同限制发送速率

下一章将深入 ACK 帧，解析其 Range 编码、ECN 计数与延迟时间字段。
