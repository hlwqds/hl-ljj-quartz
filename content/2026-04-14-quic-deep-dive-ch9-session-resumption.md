---
title: "QUIC 深度探索 ch9 - Session Resumption"
date: 2026-04-14
description: "深入解析 QUIC Session Resumption 机制：Session Ticket、状态复用、0-RTT vs 1-RTT 的重连权衡、RFC 5077 与 TLS 1.3 的结合"
tags:
  - quic
  - series
  - session-resumption
  - session-ticket
  - tls
---

# QUIC 深度探索 ch9 - Session Resumption

> [!tip] 本章内容
> 本章深入解析 QUIC Session Resumption 机制，包括 Session Ticket 的获取与使用、状态复用的流程、0-RTT 与 1-RTT 重连的对比，以及无状态会话恢复的实现。

---

## 1. Session Resumption 的背景

Session Resumption（会话恢复）是 TLS 1.3（及 TLS 1.2）的核心特性，允许客户端和服务器在建立新连接时复用之前会话的密钥材料，避免完整的握手流程。

### 1.1 为什么需要 Session Resumption

```
完整 TLS 握手（1-RTT）的开销：

- 2x ECDH 密钥交换计算（约 2-3ms）
- 证书链验证（约 5-10ms）
- 完整的 RSA/ECDSA 签名（约 1-2ms）
- 证书链传输（约 2-5KB）

Session Resumption 的优势：
- 避免密钥交换计算
- 无需传输证书链
- 减少握手延迟（0-RTT）
```

### 1.2 TLS Session Resumption 发展历程

| 版本    | 机制                        | 局限性                       |
| ------- | --------------------------- | ---------------------------- |
| TLS 1.2 | Session ID / Session Ticket | 无前向保密，有 replay 风险   |
| TLS 1.3 | PSK + Session Ticket        | 有 0-RTT，但存在 replay 风险 |

QUIC 使用 TLS 1.3 的 PSK 机制实现 Session Resumption。

---

## 2. Session Ticket 机制

### 2.1 什么是 Session Ticket

Session Ticket 是服务端在 TLS 会话结束时发送给客户端的加密状态块：

```
Session Ticket 内容（服务端加密）：
  struct {
      ProtocolVersion version;
      CipherSuite cipher_suite;
      uint32 ticket_lifetime;
      uint32 ticket_age_add;
      opaque ticket_nonce;
      opaque ticket;
      Extension extensions<0..2^16-1>;
  } State;
```

客户端在后续连接的 ClientHello 中携带此 Ticket。

### 2.2 Session Ticket 的获取

Session Ticket 通常在 TLS 握手完成后通过 NewSessionTicket 消息发送：

```
Server                                        Client
  |                                             |
  | ================================            |
  |          TLS 握手完成                        |
  | ================================            |
  |                                             |
  | <-- NewSessionTicket (ticket=enc_state)      |
  |     + ticket_lifetime (validity period)      |
  |     + ticket_age_add (obfuscation)           |
  |     + early_data indication (if enabled)    |
  |                                             |
  | [客户端保存 ticket]                          |
```

### 2.3 Session Ticket 的使用

客户端在新的连接中发送 ClientHello，携带 Session Ticket：

```
ClientHello {
    cipher_suites: [TLS_AES_128_GCM_SHA256, ...]
    extensions: {
        pre_shared_key: {
            identities: [
                { ticket=b"enc_state...", obfuscated_ticket_age=xxx }
            ]
            binder: HMAC-SHA256(binder_key, ClientHello.pad)
        }
    }
}
```

### 2.4 服务端验证 Session Ticket

```
服务端收到 ClientHello[pre_shared_key]:
1. 解密 ticket（使用 ticket_key）
2. 验证 ticket 版本、有效期、用途
3. 提取内部状态（cipher_suite, ALPN, etc.）
4. 派生出 PSK（基于 ticket_nonce 和 master_secret）
5. 确认身份并继续握手
```

---

## 3. QUIC 中的 Session Resumption

### 3.1 QUIC Session Ticket 扩展

RFC 9000 为 QUIC 定义了专用的 Session Ticket 参数：

```
Transport Parameters Extension:
  initial_max_data:  接收方向的最大数据量
  initial_max_stream_data_bidi_local:  本地发起的双向流窗口
  initial_max_stream_data_bidi_remote:  远端发起的双向流窗口
  initial_max_stream_data_unidi:         单向流窗口
  active_connection_id_limit:           有效 CID 数量
  quic_transport_params:               序列化后的传输参数
```

这些参数与 TLS Session Ticket 一起存储，确保重连时 QUIC 状态一致。

### 3.2 Session Resumption 的 0-RTT 流程

```
Client                                               Server
  |                                                    |
  | [使用保存的 Session Ticket]                         |
  |                                                    |
  | 发送 Initial[                                      |
  |   CRYPTO: ClientHello[                            |
  |     + pre_shared_key: {identities: [ticket]}     |
  |     + key_share: (ECDH 公钥，用于完整握手)          |
  |   ]                                                |
  |   + 0-RTT[应用数据]                                |
  |                                                    |
  | <-- Initial[CRYPTO: ServerHello]                  |
  |       + pre_shared_key (selected)                |
  |       + key_share (新 ECDH 公钥)                   |
  |       + EncryptedExtensions                       |
  |       + Finished                                  |
  |       + NewSessionTicket (新 ticket)              |
  |                                                    |
  | <-- Handshake[CRYPTO: Finished]                  |
  |                                                    |
  | [派生出新密钥，确认新 session ticket]                |
  |                                                    |
  | 发送 1-RTT[应用数据]                               |
  |                                                    |
```

### 3.3 为什么仍需要 key_share

TLS 1.3 的 Session Resumption **仍然需要 ECDHE 密钥交换**，原因：

```
PSK 用途：
- 派生出 0-RTT 密钥（用于重连时快速发送数据）
- 派生出 1-RTT 密钥

但 PSK 本身不提供前向保密（除非结合 ECDHE）

TLS 1.3 的设计：
- 0-RTT: 使用 PSK 派生的密钥（无前向保密）
- 1-RTT: 使用 PSK + ECDHE 派生的密钥（有前向保密）
```

因此，即使使用 Session Resumption，客户端仍需要在 ClientHello 中携带 key_share。

---

## 4. 0-RTT vs 1-RTT Session Resumption

### 4.1 两种恢复方式对比

| 特性           | 0-RTT Resumption   | 1-RTT Resumption |
| -------------- | ------------------ | ---------------- |
| 握手延迟       | ~0.5-RTT           | 1-RTT            |
| 前向保密       | ❌ 无              | ✅ 有            |
| 可发送数据时机 | 握手期间           | 握手完成后       |
| 实现复杂度     | 高                 | 低               |
| 重放风险       | ⚠️ 有              | ✅ 无            |
| 适用场景       | 重复连接、幂等请求 | 安全性敏感场景   |

### 4.2 1-RTT Resumption 的标准流程

```
Client                                               Server
  |                                                    |
  | [使用保存的 Session Ticket]                         |
  |                                                    |
  | 发送 Initial[                                      |
  |   CRYPTO: ClientHello[                            |
  |     + pre_shared_key: {identities: [ticket]}      |
  |     + key_share: (ECDH 公钥)                      |
  |   ]                                                |
  |                                                    |
  | <-- Initial[CRYPTO: ServerHello]                  |
  |       + key_share (新 ECDH 公钥)                   |
  |       + EncryptedExtensions                       |
  |       + Finished                                  |
  |                                                    |
  | [基于 PSK + ECDHE 派生 1-RTT 密钥]                  |
  |                                                    |
  | 发送 Handshake[CRYPTO: Finished]                  |
  |                                                    |
  | [握手确认完成]                                     |
  |                                                    |
  | ================================                  |
  |         1-RTT 通道建立                             |
  | ================================                  |
  |                                                    |
  | 发送 1-RTT[应用数据]                               |
  |                                                    |
```

### 4.3 选型建议

**使用 0-RTT Resumption**：

- 重复连接到同一服务端
- 请求幂等（GET、只读 API）
- 对延迟极度敏感
- 数据安全性要求相对较低

**使用 1-RTT Resumption**：

- 安全性要求高的场景
- 包含敏感状态变更的请求
- 首次连接（无 Session Ticket）
- 不确定的场景（fallback）

---

## 5. 无状态会话恢复

### 5.1 有状态 vs 无状态

| 类型   | 服务端存储           | Ticket 内容             |
| ------ | -------------------- | ----------------------- |
| 有状态 | 会话在服务端内存     | 会话 ID（需服务端查询） |
| 无状态 | 会话在 Ticket 中加密 | 完整状态（自包含）      |

### 5.2 无状态 Session Ticket 结构

```
Ticket 内容（加密）：
  struct {
      opaque iv[12];           // AEAD nonce
      opaque encrypted[...];   // 加密状态
      opaque tag[16];         // AEAD tag
      uint16 length;           // encrypted 长度
  } SessionTicket;

加密状态：
  State {
      ProtocolVersion version;
      CipherSuite cipher_suite;
      uint32 ticket_lifetime;
      uint32 ticket_age_add;
      opaque ticket_nonce;
      opaque ticket;
      uint8 ticket_flags;
      uint16 sessid_len;
      opaque sessid;
      QUIC_transport_parameters;
      TLS_transport_parameters;
  }
```

### 5.3 Ticket 加密机制

```
服务端加密 Ticket：
1. 生成随机 IV (12 bytes)
2. 构建 State 明文
3. 使用 AEAD_AES_128_GCM 加密：
   ciphertext = AES-GCM(key=tkp_key, nonce=IV, plaintext=State)
4. 输出: IV || ciphertext || tag

服务端解密 Ticket：
1. 提取 IV
2. 使用 AEAD 解密验证
3. 解析 State
4. 验证 lifetime、版本等
```

---

## 6. Session Resumption 的限制

### 6.1 时间限制

Session Ticket 有有效期限制：

```
ticket_lifetime:  Ticket 的最大有效期（通常 24-48 小时）
实际有效期:       min(ticket_lifetime, 7 days)
过期后:           需重新完整握手
```

### 6.2 单向性

Session Resumption 是单向的：

- 客户端可以随时使用 Session Ticket 重连
- 服务端不能"推送"新 Session Ticket 给客户端
- Session Ticket 可以更新（每次连接可获取新 ticket）

### 6.3 参数一致性

Session Resumption 要求参数一致性：

```
参数一致性要求：
- ALPN 必须匹配
- QUIC 版本必须兼容
- 传输参数可以更新（允许扩展）
- 证书链可能变化（服务端证书更新）
```

如果参数不一致，服务端会拒绝 PSK 并降级到完整握手。

### 6.4 0-RTT 数据限制

即使使用 Session Resumption，以下操作不能在 0-RTT 中发送：

```
禁止在 0-RTT 中发送：
- HTTP/3 SETTINGS（首次）
- HTTP/3 GOAWAY
- HTTP/3 NEW_TOKEN
- 任何会改变连接状态的帧（除了 STREAM）
```

---

## 7. 连接迁移与 Session Resumption

### 7.1 连接迁移不破坏 Session Resumption

```
场景：
1. 客户端在网络 A 建立连接，获取 Session Ticket
2. 连接迁移到网络 B（CID 改变）
3. 客户端使用 Session Ticket 重连

结果：
- Session Ticket 仍然有效
- PSK 仍可用于 0-RTT/1-RTT
- 但 CID 可能已更新
```

### 7.2 CID 变化的影响

Session Ticket 中不包含 CID：

- CID 是路径标识，不是会话标识
- Session Ticket 绑定的是会话密钥材料，不是地址
- 重连时生成新的 CID

---

## 8. Session Resumption 实现要点

### 8.1 客户端实现

```
客户端 Session Resumption 状态管理：

struct QUICClient {
    SessionState[] sessions;  // 多个可能的 session

    // 保存 session
    on session_resume(ticket, state, params):
        sessions.append({
            ticket: ticket,
            state: state,  // 包含密钥材料
            params: params,
            created: now()
        })

    // 选择 session 重连
    select_session(server_name):
        for s in sessions:
            if s.matches(server_name) and not_expired(s):
                return s
        return None  // 降级到完整握手
}
```

### 8.2 服务端实现

```
服务端 Session Resumption 验证：

on ClientHello(pre_shared_key):
    for identity in pre_shared_key.identities:
        if decrypt_ticket(identity.ticket, key=tkp_key):
            state = parse_state(identity.ticket)
            if state.valid(server_name, version, lifetime):
                derive_psk(state)
                return (PSK, state.params)
    return None  // 拒绝 PSK，完整握手
```

---

## 9. 小结与参考

### 核心要点

1. **Session Ticket**：自包含的加密状态块，包含密钥材料和传输参数
2. **PSK 机制**：TLS 1.3 PSK 结合 ECDHE，提供 0-RTT/1-RTT 重连
3. **0-RTT Resumption**：快速重连，无前向保密，有重放风险
4. **1-RTT Resumption**：安全重连，有前向保密，需 1-RTT 延迟
5. **无状态实现**：Session Ticket 携带完整状态，服务端无需存储
6. **参数一致性**：ALPN、版本等必须匹配，否则降级

### 参考资料

- [RFC 9000 - QUIC: A UDP-Based Multiplexed and Secure Transport](https://www.rfc-editor.org/rfc/rfc9000)
- [RFC 9001 - QUIC TLS](https://www.rfc-editor.org/rfc/rfc9001#section-4)
- [RFC 8446 - TLS 1.3](https://www.rfc-editor.org/rfc/rfc8446#section-4)
- [RFC 5077 - TLS Session Resumption without Server-Side State](https://www.rfc-editor.org/rfc/rfc/rfc5077)
