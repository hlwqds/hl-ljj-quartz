---
title: "QUIC 深度探索 ch8 - 1-RTT 连接"
date: 2026-04-14
description: "深入解析 QUIC 1-RTT 连接的完整时序、密钥更新机制、密钥阶段（Key Phase）、1-RTT 与 0-RTT 的关键区别"
tags:
  - quic
  - series
  - 1-rtt
  - key-update
  - tls
---

# QUIC 深度探索 ch8 - 1-RTT 连接

> [!tip] 本章内容
> 本章深入解析 QUIC 1-RTT 连接的完整流程，包括密钥阶段的转换、密钥更新机制、1-RTT 数据传输、1-RTT 与 0-RTT 的核心区别，以及握手完成后的状态管理。

---

## 1. 什么是 1-RTT

1-RTT（One Round Trip Time）是 QUIC 的标准操作模式，客户端在发送第一个包后，等待服务端的响应（1 个 RTT），即可进入加密传输状态。

### 1.1 1-RTT vs 0-RTT 的本质区别

| 特性 | 1-RTT | 0-RTT |
|------|-------|-------|
| 是否需要 PSK | ❌ 否 | ✅ 是 |
| 首次连接 | ✅ 支持 | ❌ 不支持 |
| 前向保密 | ✅ 有 | ❌ 无 |
| 握手延迟 | 1-RTT | ~0.5-RTT |
| 重放风险 | 无 | 有 |

### 1.2 1-RTT 的密钥来源

1-RTT 密钥从完整的 TLS 1.3 握手密钥交换中派生，而非 PSK：

```
TLS 1.3 密钥交换（ECDHE）:

client_key_share (ECDH 私钥)  -->  用于派生共享密钥
          |
          v
    ECDH 密钥交换
          |
          v
    shared_secret (ECDH 公钥交换结果)
          |
          v
    Derive-Secret(master_secret, "client traffic secret", ServerHello...)
          |
          v
    application traffic secret
          |
          v
    1-RTT keys & IVs
```

---

## 2. 完整 1-RTT 握手时序

### 2.1 标准 1-RTT 握手（无 0-RTT）

```
Client                                               Server
  |                                                    |
  | 生成 ECDH 密钥对 (client_key_share)                |
  | 发送 Initial[CRYPTO: ClientHello]                  |
  |   + Key Share (ECDH 公钥)                          |
  |   + Supported Versions                             |
  |   + SCSV / ALPN                                    |
  |   + Session Ticket 请求                            |
  |                                                    |
  | <-- 发送 Initial[CRYPTO: ServerHello]              |
  |       + Key Share (ECDH 公钥)                      |
  |       + Supported Versions 确认                    |
  |       + CRYPTO: EncryptedExtensions                |
  |       + CRYPTO: Certificates                       |
  |       + CRYPTO: CertificateVerify                  |
  |       + CRYPTO: Finished                           |
  |                                                    |
  | [密钥派生]                                         |
  |   - 从 ServerKeyShare 派生 shared_secret           |
  |   - 从 shared_secret 派生 traffic secrets          |
  |   - 计算 ServerHello.verify_data 比对 Finished     |
  |                                                    |
  | 发送 Handshake[CRYPTO: Finished]                   |
  |   (使用 handshake 密钥加密)                       |
  |                                                    |
  | [密钥派生完成，切换到 1-RTT 密钥]                   |
  |                                                    |
  | ================================================   |
  |         1-RTT 加密通道建立完成                      |
  | ================================================   |
  |                                                    |
  | 发送 1-RTT[STREAM: HTTP GET]                       |
  | 发送 1-RTT[HANDSHAKE_DONE]                         |
  |                                                    |
  | <-- 1-RTT[STREAM: HTTP 200]                        |
  | <-- 1-RTT[ACK]                                     |
  |                                                    |
```

### 2.2 时间线分解

```
RTT 0:  发送 Initial[ClientHello + KeyShare] + (可选 0-RTT[数据])
         <--------------------------------------------
         接收 Initial[ServerHello + KeyShare + Finished]

RTT 1:  [密钥派生完成]
         发送 Handshake[Finished] (如果需要)
         进入 1-RTT 模式，发送应用数据
```

---

## 3. 密钥阶段（Key Phase）

### 3.1 什么是 Key Phase

QUIC 使用 **Key Phase (KP)** 来标识当前使用的密钥轮次。每次密钥更新后，Key Phase 翻转。这种设计允许接收端区分新旧密钥：

```
Key Phase 0:  使用初始 1-RTT 密钥
Key Phase 1:  密钥更新后使用新密钥
Key Phase 0:  再次更新后翻转回 0
```

### 3.2 Key Phase 在包头中的编码

Short Header 包的第一个半字节（nibble）包含 Key Phase 和 Connection ID 长度：

```
Short Header Packet (1-RTT):
  0                   1
  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5
+--+--+--+--+--+--+--+--+--+--+--+
| 0|1|    DCID L    |  KP  |  R  |
+--+--+--+--+--+--+--+--+--+--+--+

R = Reserved (2 bits)
KP = Key Phase (1 bit)
DCID L = Destination Connection ID Length (6 bits)
```

### 3.3 接收端如何选择密钥

接收端需要同时持有旧密钥和新密钥，直到确认对端已切换：

```
接收端逻辑:

if (packet.pn_space == application):
    if (kp_bit == current_kp):
        decrypt_with(current_key)
    else:
        decrypt_with(previous_key)
```

### 3.4 密钥更新的触发

密钥更新可以是主动的（发送端决定）或被动的（基于数据量或时间）：

```
触发密钥更新的条件（典型实现）：
- 已传输超过 2^20 字节（约 1MB）
- 自上次密钥更新已超过 24 小时
- 收到对方的 KEY_UPDATE 信号
```

---

## 4. 密钥更新流程

### 4.1 发送端主动更新

```
发送端更新密钥:
1. 生成新的 traffic_secret (基于旧密钥 + HKDF)
2. 派生新的 1-RTT keys & IVs
3. 翻转 Key Phase bit
4. 使用新密钥加密后续包

CRYPTO frame 携带 KEY_UPDATE 信号:
  NEW_TOKEN {
    key_phase = new_kp
  }
```

### 4.2 接收端处理

```
接收端处理密钥更新:
1. 收到新的 Key Phase bit
2. 派生新密钥（使用相同的 HKDF 逻辑）
3. 同时持有新旧两套密钥
4. 使用新密钥解密后续包
5. 旧密钥在一定时间后丢弃
```

### 4.3 确认机制

接收端需要确认密钥更新已被对方收到：

```
发送端                                        接收端
  |                                             |
  | [密钥更新]                                  |
  | 发送 1-RTT[KP=1, 应用数据]                  |
  | <-- 1-RTT[KP=0, ACK]                        |
  |   [接收端仍使用 KP=0 密钥]                   |
  |                                             |
  | [确认密钥已更新]                             |
  | 继续使用 KP=1 发送                           |
```

### 4.4 包号防重放

密钥更新后，新旧密钥的包号空间保持连续，但每个包使用当前密钥加密：

```
密钥更新前：
  KP=0, PN=100, 使用 key0 加密

密钥更新后：
  KP=1, PN=101, 使用 key1 加密
```

---

## 5. 1-RTT 数据包格式

### 5.1 Short Header Packet

1-RTT 数据包使用 Short Header：

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+
| 0|1|          DCID L       |  KP  |  R  |       Packet Number   |
+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+
|                    Destination Connection ID                     |
+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+
|                      [Protected Payload]                        |
+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+
|                      [Authentication Tag]                       |
+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+
```

### 5.2 加密保护

1-RTT 数据包使用 **AEAD_AES_128_GCM** 或 **AEAD_AES_256_GCM** 进行加密：

```
加密过程:
1. 构建明文 payload (帧序列)
2. 生成 packet number nonce (包号填充到 12 bytes)
3. 生成 auth tag（通过 AAD 中的 header 进行验证）
4. 输出: ciphertext + auth tag

AEAD 参数:
- AEAD_AES_128_GCM: 128-bit key + 96-bit nonce + 128-bit tag
- AEAD_AES_256_GCM: 256-bit key + 96-bit nonce + 128-bit tag
```

### 5.3 Additional Authenticated Data (AAD)

QUIC 的 AAD 是包头的未加密部分，用于防包头篡改：

```
AAD (for 1-RTT Short Header Packet):
  Byte 0: 0x0? | DCID len | KP | R
  Bytes 1..N: Destination Connection ID
  Last 4 bytes: Packet Number (truncated)
```

---

## 6. 1-RTT 数据的传输

### 6.1 帧序列

1-RTT 数据包中可以包含多个帧的序列：

```
1-RTT Packet [
    STREAM frame (Stream ID=0, offset=0, data="GET / HTTP/1.1")
    PING frame
    ACK frame (delay=100us, ack_ranges=[...])
    CONNECTION_CLOSE frame (error_code=0x0)
]
```

### 6.2 最重要帧：STREAM

STREAM 帧是 QUIC 传输应用数据的核心机制：

```
STREAM Frame {
    Stream ID:    32 bits
    Offset:       64 bits (var-int)
    Data Length:  16 bits (optional)
    Data:         variable
}
```

### 6.3 流控与 1-RTT

1-RTT 阶段需要进行流控（Flow Control）：

```
Connection-Level 流控:
  - MAX_DATA: 连接级窗口
  - DATA_BLOCKED: 发送端因流控暂停

Stream-Level 流控:
  - MAX_STREAM_DATA: 流级窗口
  - STREAM_DATA_BLOCKED: 单流因流控暂停
```

---

## 7. HANDSHAKE_DONE 帧

### 7.1 意义

HANDSHAKE_DONE 是服务端发送的一个 1-RTT 帧，通知客户端握手已完成：

```
HANDSHAKE_DONE frame {
    type = 0x1e
}
```

### 7.2 发送时机

服务端在以下条件满足后发送 HANDSHAKE_DONE：

```
1. 收到客户端的 Handshake[Finished]
2. 成功验证 Finished 的完整性
3. 已派生出 1-RTT 密钥
4. 准备接受 1-RTT 应用数据
```

### 7.3 客户端的响应

客户端收到 HANDSHAKE_DONE 后：

```
1. 确认服务端已完成握手
2. 进入完整工作状态
3. 可以关闭握手状态相关资源
4. 准备发送高优先级请求
```

---

## 8. 1-RTT 与连接确认状态

### 8.1 handshakeConfirmed 状态

RFC 9000 定义了 handshake confirmed 状态：

> A QUIC connection is "handshake confirmed" when the client has received and verified the server's Handshake packets, and the server has received and verified the client's Handshake packets.

### 8.2 1-RTT 前的包处理

在 1-RTT 连接完全确认前，客户端仍需处理握手包：

```
在 handshake confirmed 之前：
- 仍需处理对端的 Initial/Handshake 包
- 可能收到旧密钥加密的包
- 0-RTT 数据已确认（如果使用了 0-RTT）

在 handshake confirmed 之后：
- 进入完全 1-RTT 状态
- 无需再处理握手包（除非是 Retry）
- 连接迁移功能激活
```

---

## 9. 1-RTT 连接状态机

```
                                    0-RTT 状态（可选）
                                        |
                                        v
INITIAL -----> HANDSHAKE -----> CONFIRMED -----> 1-RTT
  |               |                |              |
  |               |                |              |
  v               v                v              v
 DRAINING      DRAINING         DRAINING       DRAINING
  |               |                |              |
  v               v                v              v
 CLOSED         CLOSED           CLOSED         CLOSED
```

### 9.1 各状态支持的包类型

| 状态 | Initial | Handshake | 0-RTT | 1-RTT |
|------|---------|-----------|-------|-------|
| INITIAL | ✅ | ❌ | ❌ | ❌ |
| HANDSHAKE | ✅ | ✅ | ❌ | ❌ |
| CONFIRMED | ✅ | ✅ | ✅ | ✅ |
| 1-RTT | ❌ | ❌ | ❌ | ✅ |

---

## 10. 小结与参考

### 核心要点

1. **1-RTT 密钥派生**：基于 ECDHE 密钥交换，有前向保密
2. **Key Phase 翻转**：每次密钥更新翻转 KP bit，接收端需同时持有新旧密钥
3. **Short Header**：1-RTT 使用 Short Header，包头更紧凑
4. **AEAD 加密**：使用 AES-GCM 系列，提供加密和完整性保护
5. **HANDSHAKE_DONE**：服务端通知客户端握手完成
6. **握手确认**：CONFIRMED 状态后进入完整 1-RTT 操作

### 1-RTT 与 0-RTT 对比

| 特性 | 1-RTT | 0-RTT |
|------|-------|-------|
| 密钥来源 | ECDHE 完整握手 | PSK 复用 |
| 前向保密 | ✅ | ❌ |
| 首次连接 | ✅ | ❌ |
| 重放风险 | 无 | 有 |
| 延迟 | 1-RTT | ~0.5-RTT |
| 状态复杂度 | 低 | 高 |

### 参考资料

- [RFC 9000 - QUIC: A UDP-Based Multiplexed and Secure Transport](https://www.rfc-editor.org/rfc/rfc9000)
- [RFC 9001 - QUIC TLS](https://www.rfc-editor.org/rfc/rfc9001)
- [draft-ietf-quic-tls-17](https://tools.ietf.org/html/draft-ietf-quic-tls-17)
