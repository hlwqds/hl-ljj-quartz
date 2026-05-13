---
title: "QUIC 深度探索 ch10 - TLS 1.3 集成"
date: 2026-04-14
description: "深入解析 QUIC 与 TLS 1.3 的深度集成：TLS 消息如何映射为 QUIC 帧、AEAD 密钥导出、不同的密钥交换机制、TLS 1.3 vs TLS 1.2 的差异"
tags:
  - quic
  - series
  - tls
  - quic-tls
  - crypto
---

# QUIC 深度探索 ch10 - TLS 1.3 集成

> [!tip] 本章内容
> 本章深入解析 QUIC 与 TLS 1.3 的深度集成机制，包括 TLS 消息到 QUIC CRYPTO 帧的映射、AEAD 密钥导出流程、TLS 1.3 与 TLS 1.2 在 QUIC 中的差异，以及密钥层级与派生过程。

---

## 1. QUIC 与 TLS 集成的设计原则

### 1.1 为什么 QUIC 要集成 TLS

传统的网络协议栈中，TLS 作为应用层协议运行在 TCP 之上：

```
OSI 模型（传统）：
  Application Layer    (HTTP)
  TLS Layer            (TLS 1.3)
  TCP Layer            (传输层)
  IP Layer            (网络层)

QUIC 的设计：
  Application Layer    (HTTP/3)
  QUIC + TLS Layer    (QUIC + TLS 1.3 深度集成)
  UDP Layer           (无连接 UDP)
  IP Layer            (网络层)
```

### 1.2 集成的核心目标

```
集成设计目标：
1. 消除 TLS 记录层：TLS 消息直接映射为 QUIC CRYPTO 帧
2. 并行加密与传输：握手期间即可发送加密数据
3. 统一的密钥层级：握手密钥、0-RTT 密钥、1-RTT 密钥统一派生
4. 传输与加密解耦：TLS 负责密钥派生，QUIC 负责加密传输
```

### 1.3 TLS 1.3 vs TLS 1.2 in QUIC

| 特性 | TLS 1.3 | TLS 1.2 |
|------|---------|---------|
| 握手模式 | 1-RTT/0-RTT | 2-RTT + Resumption |
| 密钥交换 | ECDHE（提供前向保密） | RSA（无前向保密） |
| 证书用途 | 认证 + 签名 | 仅认证 |
| QUIC 支持 | ✅ 完全支持 | ⚠️ 已废弃（RFC 8999） |

> [!warning] TLS 1.2 在 QUIC 中已被废弃
> RFC 8999 明确指出：QUIC 必须使用 TLS 1.3，不再支持 TLS 1.2。这确保了前向保密和现代加密标准。

---

## 2. TLS 消息到 QUIC 帧的映射

### 2.1 映射的总体架构

```
TLS Record Layer (传统 TLS)
  └── TLSMessage (握手消息)
        └── Record ( fragmentation)

QUIC + TLS 1.3
  └── CRYPTO frame (QUIC 层)
        └── TLSMessage (无 fragmentation，offset 机制替代)
```

### 2.2 TLS 1.3 消息到 QUIC 包类型的对应

| TLS 1.3 消息 | QUIC 包类型 | CRYPTO 帧阶段 |
|--------------|------------|--------------|
| ClientHello | Initial | initial_number_space |
| ServerHello | Initial | initial_number_space |
| EncryptedExtensions | Initial | initial_number_space |
| Certificates | Initial | initial_number_space |
| CertificateVerify | Initial | initial_number_space |
| Finished | Initial / Handshake | handshake_number_space |
| NewSessionTicket | 1-RTT | application_number_space |

### 2.3 TLS 握手流程中的 QUIC 帧序列

```
Client                                               Server
  |                                                    |
  | 发送 Initial[                                     |
  |   CRYPTO(frame, offset=0): ClientHello           |
  | ]                                                  |
  |                                                    |
  | <-- 发送 Initial[                                  |
  |   CRYPTO(frame, offset=0): ServerHello           |
  |   CRYPTO(frame, offset=xxx): EncryptedExtensions  |
  |   CRYPTO(frame, offset=yyy): Certificates         |
  |   CRYPTO(frame, offset=zzz): CertificateVerify   |
  |   CRYPTO(frame, offset=www): Finished            |
  | ]                                                  |
  |                                                    |
  | 发送 Handshake[                                    |
  |   CRYPTO(frame, offset=0): Finished               |
  | ]                                                  |
  |                                                    |
  | ================================                  |
  |         密钥确认完成                                |
  | ================================                  |
  |                                                    |
  | 发送 1-RTT[                                        |
  |   CRYPTO(frame, offset=0): NewSessionTicket       |
  |   STREAM(frame): HTTP GET                         |
  | ]                                                  |
```

---

## 3. CRYPTO 帧与 TLS Message Boundary

### 3.1 TCP TLS Record 的问题

传统 TLS 使用 Record 层合并多个握手消息：

```
TLS Record (TCP):
  结构：[content_type(1) | protocol_version(2) | length(2) | data]
  合并：多个 TLS 消息可合并为一个 Record
  分片：Record 可能被 TCP 分片

问题：
- TCP 队头阻塞：一个 Record 的分片丢失阻塞整个 TLS 握手
- 消息边界模糊：接收端需重组才能解析 TLS 消息
```

### 3.2 QUIC CRYPTO 帧的解决方案

```
QUIC CRYPTO Frame:
  结构：[type(1) | offset(VarInt) | length(VarInt) | data]
  分片：一个 TLS 消息可分成多个 CRYPTO 帧
  重组：接收端按 offset 排序重组

优势：
- 独立分片：CRYPTO 帧丢失只影响该帧，不阻塞其他帧
- 精确边界：offset + length 精确标识消息边界
- 无队头阻塞：乱序到达也能处理
```

### 3.3 CRYPTO 帧的分片示例

```
ClientHello 总长度: 3000 bytes

包1 (Initial #0):
  CRYPTO { offset=0,    length=1200, data=ClientHello[0:1200] }

包2 (Initial #1):
  CRYPTO { offset=1200, length=1200, data=ClientHello[1200:2400] }

包3 (Initial #2):
  CRYPTO { offset=2400, length=600,  data=ClientHello[2400:3000] }

接收端重组后：
  ClientHello { offset=0, length=3000, data=完整 ClientHello }
```

---

## 4. AEAD 密钥导出

### 4.1 QUIC 使用的 AEAD

| AEAD 类型 | 密钥长度 | Nonce 长度 | 用途 |
|-----------|----------|-----------|------|
| AEAD_AES_128_GCM | 128 bits | 96 bits | 推荐的最低要求 |
| AEAD_AES_256_GCM | 256 bits | 96 bits | 更强安全性 |
| AEAD_CHACHA20_POLY1305 | 256 bits | 96 bits | 可选 |

### 4.2 密钥导出层次

TLS 1.3 的密钥导出使用 HKDF：

```
HKDF (HMAC-based Key Derivation Function):

HKDF-Extract(salt, IKM) -> PRK (Pseudo-Random Key)
HKDF-Expand-Label(PRK, label, context, length) -> OKM (Output Key Material)
```

### 4.3 QUIC 密钥导出流程

```
基础：TLS handshake 产生 master_secret

master_secret
    |
    +--> Derive-Secret(master_secret, "client hello", ...)
    |    = client_hello_secret
    |
    +--> Derive-Secret(master_secret, "server hello", ...)
         = server_hello_secret
              |
              v
         HKDF-Expand-Label(server_hello_secret, "quic key", "", 16)
              |  -> client_conn_id_0RTT_key / server_conn_id_0RTT_key
              v
         HKDF-Expand-Label(server_hello_secret, "quic iv", "", 12)
              |  -> client_conn_id_0RTT_iv / server_conn_id_0RTT_iv
              v
         HKDF-Expand-Label(server_hello_secret, "quic hp", "", 16)
              |  -> client_conn_id_0RTT_header_protection_key
              v
         ...
```

### 4.4 Header Protection

除了 payload 加密，QUIC 还使用 Header Protection（HP）保护包头：

```
Header Protection 机制：
1. 从 traffic secret 派生 hp_key
2. 使用 hp_key 和 packet_number 生成 mask
3. 用 mask 混淆包头的 5 bytes（第一字节 + 4字节包号）

解混淆：
1. 从密钥派生 hp_key
2. 用 hp_key 和 packet_number 生成 mask
3. 恢复包头

hp_key 派生：
  HKDF-Expand-Label(traffic_secret, "quic hp", "", 16)
```

### 4.5 加密流程图

```
发送端:
  payload_frames
       |
       v
  [构建明文 payload]
       |
       v
  AEAD-Encrypt(payload, key, nonce, aad)
       |
       v
  ciphertext + auth_tag
       |
       v
  [混淆包头 (Header Protection)]
       |
       v
  Short/Long Header Packet (发送)

接收端:
  Short/Long Header Packet (接收)
       |
       v
  [解混淆包头]
       |
       v
  AEAD-Decrypt(ciphertext, key, nonce, aad)
       |
       v
  payload_frames
```

---

## 5. TLS 1.3 的四种密钥交换模式

### 5.1 (EC)DHE 密钥交换

TLS 1.3 主要使用 (Elliptic Curve) Diffie-Hellman Exchange：

```
TLS 1.3 ECDHE 流程：

Client:
  生成 (P-256/X25519/...) 密钥对
  client_key_share = ECDH private key + public key
  发送 ClientHello { key_share: client_key_share }

Server:
  生成 ECDH 密钥对 (或重用)
  server_key_share = ECDH private key + public key
  shared_secret = ECDH(client_key_share, server_key_share)
  发送 ServerHello { key_share: server_key_share }

双方：
  shared_secret → Derive-Secret(..., "shared_secret") → traffic secret
```

### 5.2 PSK (Pre-Shared Key) 模式

```
TLS 1.3 PSK 流程：

Client:
  有之前会话的 PSK
  发送 ClientHello {
    pre_shared_key: { identities: [PSK ticket] }
  }

Server:
  验证 PSK 有效
  derive PSK binder_key
  发送 ServerHello {
    pre_shared_key: { selected_identity: 0 }
  }

双方：
  PSK → early_secret → traffic secret (0-RTT) 或 → 1-RTT
```

### 5.3 PSK + (EC)DHE 混合模式

TLS 1.3 推荐使用 PSK + ECDHE 混合：

```
TLS 1.3 PSK + ECDHE 流程：

Client:
  发送 ClientHello {
    pre_shared_key: { identities: [PSK ticket] },
    key_share: { ECDH 公钥 }  // 仍需 ECDH
  }

Server:
  验证 PSK
  执行 ECDH 密钥交换
  combined = PSK + shared_secret
  derive traffic secret

结果：
- 0-RTT: 使用 PSK 派生的密钥
- 1-RTT: 使用 PSK + ECDHE 派生的密钥（有前向保密）
```

### 5.4 0-RTT vs 1-RTT 密钥差异

```
0-RTT 密钥派生：
  early_secret = HKDF-Extract(PSK, salt)
  0-RTT traffic secret = HKDF-Expand-Label(early_secret, "quic 0rtt", ...)
  0-RTT keys = AEAD-Key(0-RTT traffic secret)
  0-RTT IV = AEAD-IV(0-RTT traffic secret)

1-RTT 密钥派生：
  handshake_secret = HKDF-Extract(master_secret, "tls13 derived")
  server_handshake traffic secret = Derive-Secret(handshake_secret, "s hs")
  client_handshake traffic secret = Derive-Secret(handshake_secret, "c hs")
  
  // 收到 ServerHello 后：
  application traffic secret = Derive-Secret(
      master_secret, "c ap", ServerHello...)

  1-RTT keys = AEAD-Key(application traffic secret)
  1-RTT IV = AEAD-IV(application traffic secret)
```

---

## 6. TLS 消息与 QUIC 包号空间

### 6.1 包号空间的独立性

QUIC 的三个包号空间（Initial / Handshake / Application）独立运作：

```
包号空间隔离：

Initial 包号空间：
  - 包号: 0, 1, 2, ...
  - 加密: Initial keys (well-known)
  - 携带: ClientHello, ServerHello, Finished

Handshake 包号空间：
  - 包号: 0, 1, 2, ...
  - 加密: Handshake keys (从 ServerHello 派生)
  - 携带: Finished (确认)

Application 包号空间：
  - 包号: 0, 1, 2, ...
  - 加密: 1-RTT / 0-RTT keys
  - 携带: 应用数据, NewSessionTicket
```

### 6.2 包号重置与连续性

```
包号连续性规则：
- 每个包号空间内的包号单调递增
- 包号不能重置为 0（除非是长连接断开后重连）
- 包号长度（1/2/4 字节）取决于包数量

包号重置场景（仅限连接迁移）：
- 客户端可以切换到新的 Connection ID
- 新 Connection ID 的包号空间可以重新从 0 开始
- 但同一 Connection ID 下包号必须连续
```

---

## 7. TLS 1.3 与 TLS 1.2 的密钥派生差异

### 7.1 TLS 1.2 的密钥派生

TLS 1.2 使用伪随机函数（PRF）派生密钥：

```
TLS 1.2 密钥派生：
  master_secret = PRF(
      pre_master_secret,
      "master secret",
      ClientHello.random + ServerHello.random
  )[48 bytes]

  key_block = PRF(
      master_secret,
      "key expansion",
      ServerHello.random + ClientHello.random
  )

  key_block 拆分：
    client_write_MAC_key[20]
    server_write_MAC_key[20]
    client_write_key[32]  // AES-256
    server_write_key[32]
    client_write_IV[4]
    server_write_IV[4]
```

### 7.2 TLS 1.3 的密钥派生

TLS 1.3 使用 HKDF：

```
TLS 1.3 密钥派生：
  master_secret = HKDF-Extract(
      ECDH shared secret 或 PSK,
      "tls13 shared secret"
  )

  traffic_secret = Derive-Secret(
      master_secret,
      "traffic secret",  // 标签
      transcript_hash    // H(ClientHello...ServerHello)
  )

  keys = HKDF-Expand-Label(traffic_secret, "quic key", "", 16)
  iv = HKDF-Expand-Label(traffic_secret, "quic iv", "", 12)
```

### 7.3 关键差异总结

| 特性 | TLS 1.2 | TLS 1.3 |
|------|---------|---------|
| 密钥材料 | RSA encrypted PMS / ECDH | ECDH / PSK |
| 派生函数 | PRF (MD5/SHA-256) | HKDF (HMAC-SHA-256) |
| 前向保密 | ❌ (RSA) / ✅ (ECDH) | ✅ (必须) |
| 0-RTT | ❌ | ✅ (PSK) |
| 握手轮数 | 2-RTT | 1-RTT |
| 证书用途 | 加密 PMS | 仅认证 |

---

## 8. 实战：TLS 1.3 握手在 QUIC 中的完整时序

```
Client                                               Server
  |                                                    |
  | [TLS 1.3 握手开始]                                 |
  |                                                    |
  | CRYPTO[ClientHello]                                |
  |   + supported_versions: [v1]                      |
  |   + key_share: P-256/X25519 公钥                    |
  |   + pre_shared_key: [session ticket] (如果有)       |
  |   + supported_alpns: [h3, h3-29]                  |
  |                                                    |
  | <-- CRYPTO[ServerHello]                           |
  |       + version: v1                                |
  |       + key_share: P-256/X25519 公钥                 |
  |       + pre_shared_key: (selected identity)         |
  |                                                    |
  | <-- CRYPTO[EncryptedExtensions]                   |
  |       + quic_transport_params: [max_data, etc.]    |
  |       + alpn: h3                                   |
  |                                                    |
  | <-- CRYPTO[Certificates]                           |
  |       + certificate (X.509)                        |
  |       + certificate_extensions                     |
  |                                                    |
  | <-- CRYPTO[CertificateVerify]                     |
  |       + signature: RSA/ECDSA(handshake_hash)       |
  |                                                    |
  | <-- CRYPTO[Finished]                              |
  |       + verify_data: HMAC(master_secret, hash)      |
  |                                                    |
  | [TLS 状态机: ServerHelloDone]                      |
  | [密钥派生: master_secret, traffic secrets]          |
  | [验证 Finished.verify_data]                        |
  |                                                    |
  | CRYPTO[Finished]                                  |
  |   + verify_data: HMAC(master_secret, hash)          |
  |                                                    |
  | [TLS 状态机: Connected]                            |
  | [密钥派生: application traffic secrets]             |
  | [进入 1-RTT 加密传输]                               |
  |                                                    |
  | CRYPTO[NewSessionTicket] (later)                   |
  |   + ticket: 加密状态                               |
  |   + ticket_lifetime: 86400                         |
  |                                                    |
```

---

## 9. 小结与参考

### 核心要点

1. **TLS 1.3 强制集成**：QUIC 必须使用 TLS 1.3（TLS 1.2 已废弃）
2. **CRYPTO 帧替代 TLS Record**：TLS 消息通过 CRYPTO 帧传输，支持 offset 分片
3. **AEAD + Header Protection**：payload 加密 + 包头混淆保护
4. **HKDF 密钥派生**：统一的密钥导出框架（HKDF-Extract + HKDF-Expand-Label）
5. **包号空间隔离**：Initial / Handshake / Application 三空间独立
6. **PSK + ECDHE 混合**：0-RTT 使用 PSK，1-RTT 使用 PSK+ECDHE（提供前向保密）

### QUIC + TLS 1.3 集成的优势

| 传统 TLS over TCP | QUIC + TLS 1.3 |
|------------------|----------------|
| TLS Record 分片阻塞 | CRYPTO 帧无队头阻塞 |
| 2-RTT 握手 | 1-RTT 握手 |
| 无 0-RTT | 0-RTT 支持（PSK） |
| 密钥需 TCP 重传 | 包号空间独立加密 |
| 无连接迁移 | CID 支持连接迁移 |

### 参考资料

- [RFC 9000 - QUIC: A UDP-Based Multiplexed and Secure Transport](https://www.rfc-editor.org/rfc/rfc9000)
- [RFC 9001 - QUIC TLS](https://www.rfc-editor.org/rfc/rfc9001)
- [RFC 8446 - TLS 1.3](https://www.rfc-editor.org/rfc/rfc8446)
- [RFC 8999 - QUIC Version 1 Must Use TLS 1.3](https://www.rfc-editor.org/rfc/rfc8999)
- [IETF QUIC Working Group](https://datatracker.ietf.org/wg/quic/about/)
