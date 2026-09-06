---
title: "QUIC 深度探索 ch7 - 0-RTT 连接"
date: 2026-04-14
description: "深入解析 QUIC 0-RTT 连接的前身今世：TLS PSK 预共享密钥机制、重放攻击风险、前向保密限制、0-RTT vs 1-RTT 的权衡"
tags:
  - quic
  - series
  - 0-rtt
  - tls
  - psk
---

# QUIC 深度探索 ch7 - 0-RTT 连接

> [!tip] 本章内容
> 本章解析 QUIC 0-RTT 连接的工作原理，包括 TLS PSK 机制、重放攻击的防护、0-RTT 的限制条件，以及与 1-RTT 的对比权衡。

---

## 1. 0-RTT 的核心思想

0-RTT（Zero Round Trip Time）是指客户端在握手的第一个往返内就开始发送应用数据，无需等待 TLS 握手完成。这是 QUIC 相对于 TCP+TLS 最大的性能优势之一。

### 1.1 传统 TLS 1.3 的时间线

```
TCP + TLS 1.3:

  RTT 0:    SYN -->
           <-- SYN+ACK
           ACK -->

  RTT 1:    ClientHello -->
           <-- ServerHello
           <-- EncryptedExtensions
           <-- Certificates
           <-- Finished

  RTT 2:    Finished -->
            [应用数据可用]

  总计: 2-RTT + 应用数据
```

### 1.2 QUIC 0-RTT 的时间线

```
QUIC 0-RTT:

  RTT 0:    Initial[ClientHello] + 0-RTT[应用数据]  -->
           <-- Initial[ServerHello...]
           <-- Handshake[Finished]

  RTT 1:    [应用数据已可解密]
            1-RTT[应用数据] -->

  总计: 0.5-RTT + 应用数据（理想情况）
```

### 1.3 关键前提：预共享密钥 PSK

0-RTT 的实现依赖于**预共享密钥**（Pre-Shared Key，PSK）。客户端和服务端在之前的会话中已经建立了共享密钥材料，本次连接直接复用。

```
之前会话:
  客户端 <----> 服务端
  建立 PSK（从 session ticket 派生）

本次连接:
  客户端 --> Initial[ClientHello + PSK 标识] + 0-RTT[应用数据]
  客户端 <-- Initial[ServerHello + PSK 使用确认]
  [解密 0-RTT 数据，发送 1-RTT 数据]
```

---

## 2. TLS PSK 机制详解

TLS 1.3 的 PSK 机制是 0-RTT 的基础。与传统 TLS 1.3 的 RSA/ECDHE 密钥交换不同，PSK 直接使用之前会话中协商的密钥材料。

### 2.1 PSK 的两种来源

| PSK 类型           | 来源                         | 用途                   |
| ------------------ | ---------------------------- | ---------------------- |
| **PSK (外部)**     | 外部配置或带外协商           | 分布式预共享密钥       |
| **PSK (会话恢复)** | Session Ticket 或 Session ID | 会话恢复，复用之前会话 |

QUIC 主要使用**会话恢复 PSK**（Session Resumption），通过 NewSessionTicket 消息分发。

### 2.2 PSK 密钥导出

TLS 1.3 中，PSK 经过 Binder 密钥派生后用于 0-RTT：

```
PSK --> HKDF-Extract --> base_prckey
                        |
                        v
              resumption_psk (用于 0-RTT traffic secret)
```

### 2.3 ClientHello 中的 PSK 标识

客户端在 ClientHello 的 `pre_shared_key` 扩展中指定要使用的 PSK：

```
Extension: pre_shared_key (tls13.pre_shared_key)
  TBD: (ignored)...

  PSKs: [
    PSK #0:
      identities: [
        4 bytes: ticket (session ticket ID)
        8 bytes: obfuscated_ticket_age
      ]
      obfuscated_ticket_age: 0
      binder: (HMAC-SHA256 based key)
  ]
```

### 2.4 PSK 绑定了什么

每个 PSK 都绑定了以下会话属性：

```
PSK {
  ticket_nonce: 新 ticket 时的随机数
  ticket: session ticket
  ticket_age: ticket 的有效时长
  ticket_extensions: 额外参数（如 alpn, quic_params）
  base_key: 密钥材料
}
```

这些属性确保 PSK 不能被用于不同参数的新连接。

---

## 3. 0-RTT 数据包的发送

### 3.1 0-RTT 包格式

0-RTT 包使用 Long Header，包类型为 `0x0c`（draft 版本中）或 `0x0d`（RFC 9000）：

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+
| 0|1|1|      PP = 0x0c/d       |      Connection ID Length   |
+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+
|                         Version = 0x00000001                    |
+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+
|            Destination Connection ID (SCID)                      |
+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+
|              Source Connection ID (DCID)                          |
+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+
|                         Payload...                                |
+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+
```

### 3.2 0-RTT 包与 Initial 包并行

客户端可以在单个 UDP 数据报中发送 Initial + 0-RTT：

```
UDP Datagram:
  ├── Initial Packet (long header, type=0x0)
  │     └── CRYPTO frame: ClientHello (TLS 1.3)
  └── 0-RTT Packet (long header, type=0x0c)
        └── STREAM frame: HTTP request body (POST data)
```

这种并行发送是 QUIC 0-RTT 性能优势的关键——无需等待 Initial ACK 即可发送 0-RTT 数据。

### 3.3 0-RTT 密钥的派生

0-RTT 密钥从 PSK 派生的 early secret 获得：

```
early_secret = HKDF-Extract(
    PSK,  # 来自 session ticket 的密钥材料
    salt = "QUIC 0-RTT" 或 "tls13 derived" + 0x17
)

0-RTT write secret = HKDF-Expand-Label(
    early_secret, "quic 0rtt", "", 32
)
0-RTT write IV    = HKDF-Expand-Label(
    early_secret, "quic 0rtt iv", "", 12
)
```

---

## 4. 0-RTT 数据的解密

### 4.1 解密的时序

```
Client 发送 0-RTT 数据

Server 收到 Initial[ClientHello + PSK id]
  └── 验证 PSK，派生 0-RTT 密钥
  └── 解密 0-RTT 包

Server 发送 Initial[ServerHello + use_spsk]
  └── 确认使用 PSK

Client 收到 Initial[ServerHello]
  └── 派生 0-RTT 密钥
  └── 解密早期数据的 ACK
```

### 4.2 0-RTT 数据与 1-RTT 数据的区别

| 特性     | 0-RTT 数据              | 1-RTT 数据                          |
| -------- | ----------------------- | ----------------------------------- |
| 加密密钥 | PSK 派生的 early secret | master secret 派生的 traffic secret |
| 解密时机 | 服务端收到 Initial 后   | 收到对端 Finished 后                |
| 前向保密 | ❌ 无前向保密           | ✅ 有前向保密                       |
| 重放风险 | ⚠️ 存在（见下节）       | ✅ 无                               |

### 4.3 重放攻击的防护

0-RTT 数据理论上可以被攻击者重放（Replay Attack），因为攻击者可能截获之前的 0-RTT 包并在后续重新发送。

TLS 1.3 的防护机制是要求 PSK 必须与 ServerHello 中的 `psk_selectors` 匹配：

```
ServerHello
  extension: pre_shared_key
    selected_identity: 1   <-- 指定使用哪个 PSK
```

同时，服务端需要实现**重放缓存**（Replay Cache），记录最近使用过的 PSK binder。

> [!warning] 重放攻击的实际风险
> 0-RTT 重放攻击的实际影响取决于应用场景：
>
> - **幂等请求**（如 GET）：风险低
> - **非幂等请求**（如 POST/PUT/DELETE）：风险高，需要应用层保护
> - **支付/金融交易**：禁止使用 0-RTT

### 4.4 RFC 9000 的限制

RFC 9000 对 0-RTT 数据有明确的限制：

```
A server MUST remember the keying material required to decrypt
the 0-RTT protected data (i.e., the 0-RTT keys) until it has
received the client's Handshake messages or until it is
certain that the connection attempt has failed.

This prevents a client from sending 0-RTT data that might be
decrypted by an attacker who obtained the keying material
through a previous connection.
```

---

## 5. 0-RTT 与 1-RTT 的权衡

### 5.1 性能对比

| 指标         | 0-RTT    | 1-RTT | 差异            |
| ------------ | -------- | ----- | --------------- |
| 首次连接延迟 | 1-RTT    | 1-RTT | 相同            |
| 后续连接延迟 | ~0.5-RTT | 1-RTT | 0-RTT 减少 50%+ |
| 前向保密     | ❌       | ✅    | 1-RTT 更安全    |
| 重放风险     | ⚠️       | ✅    | 1-RTT 更安全    |
| 实现复杂度   | 中       | 低    | 1-RTT 更简单    |

### 5.2 适用场景

**适合 0-RTT 的场景**：

- 已有会话恢复的重复连接
- 幂等请求
- 对延迟敏感且数据重要性相对较低的场景（如视频首帧加载）

**不适合 0-RTT 的场景**：

- 首次连接
- 包含敏感状态变更的非幂等请求
- 对安全性要求极高的场景

### 5.3 HTTP/3 中的 0-RTT

HTTP/3 允许在 0-RTT 中发送 HTTP 请求，但有限制：

```
HTTP/3 0-RTT 限制：
- 可以发送请求（GET、POST 等）
- 不可以发送 SETTINGS（除非之前已确认）
- 不可以发送 GOAWAY
- 不可以发送 NEW_TOKEN
```

---

## 6. 0-RTT 的状态管理

### 6.1 服务端状态

服务端需要为 0-RTT 记忆以下状态：

```
struct EarlyDataState {
    psk_identity:      // PSK 标识
    0rtt_keys:         // 0-RTT 解密密钥
    0rtt_decrypted:    // 已解密的 0-RTT 数据
    handshake_keys:    // Handshake 加密密钥（用于解密 Finished）
}
```

### 6.2 客户端状态

客户端在收到服务端的 NewSessionTicket 后，保存会话状态：

```
struct ResumptionState {
    ticket:            // Session Ticket
    ticket_nonce:      // 随机数
    session_key:       // 密钥材料
    quic_params:       // QUIC 参数
    h3_params:         // HTTP/3 参数
    expiry:            // Ticket 超时时间
}
```

---

## 7. 0-RTT 与连接迁移

0-RTT 连接不支持连接迁移（Connection Migration），因为 0-RTT 密钥绑定在初始路径（Initial 包发送的地址）上。

```
连接迁移的限制：

0-RTT 状态下：    ❌ 不允许连接迁移
1-RTT 状态下：    ✅ 允许连接迁移
```

RFC 9000 规定：

> An endpoint MUST NOT initiate connection migration for a connection that has not yet been established.

---

## 8. 0-RTT 失败的降级处理

当 0-RTT 连接尝试失败时（如 PSK 无效、服务端拒绝等），客户端应自动降级到 1-RTT：

```
降级触发条件：
- 服务端返回 INVALID_TOKEN 错误
- 服务端未携带 pre_shared_key 扩展
- PSK binder 验证失败
- 服务端发送 HelloRetryRequest

降级流程：
1. 清除 0-RTT 密钥状态
2. 重新派生 1-RTT 密钥
3. 使用 1-RTT 重发 0-RTT 数据（或部分重发）
```

---

## 9. 小结与参考

### 核心要点

1. **0-RTT 依赖 PSK**：需要之前会话的密钥材料
2. **0-RTT 密钥派生**：从 PSK 派生的 early secret 获得
3. **重放风险**：0-RTT 数据可能被重放，需要应用层防护
4. **无前向保密**：PSK 被盗取后历史 0-RTT 数据可解密
5. **降级机制**：0-RTT 失败时可降级到 1-RTT
6. **不支持连接迁移**：0-RTT 状态下不能改变地址

### 参考资料

- [RFC 9001 - QUIC TLS](https://www.rfc-editor.org/rfc/rfc9001#section-5)
- [RFC 8446 - TLS 1.3](https://www.rfc-editor.org/rfc/rfc8446#section-4)
- [0-RTT Wireshark Analysis](https://wiki.wireshark.org/QUIC#0-RTT)
