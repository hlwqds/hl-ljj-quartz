---
title: QUIC & HTTP/3 深度探索 Ch2：连接建立与握手机制
date: 2026-05-08 09:00:00
tags: [QUIC, TLS 1.3, Handshake, Connection Establishment, Initial Packet, Handshake Packet, Crypto Frame, Key Derivation, 1-RTT, Certificate, Certificate Verify, Handshake States, TLS Messages, AEAD, QUIC Version, Retry]
description: QUIC & HTTP/3 深度探索 Ch2：QUIC 连接建立详细流程、TLS 1.3 与 QUIC 集成、密钥导出机制、握手状态机、1-RTT 与 0-RTT 详细解析。
---

# QUIC & HTTP/3 深度探索 Ch2：连接建立与握手机制

## 1. 概述

```
Ch2 连接建立与握手机制：

本章内容：
  1. TLS 1.3 快速回顾
  2. QUIC 握手设计
  3. Initial 包处理
  4. Handshake 包处理
  5. 密钥导出机制
  6. 握手状态机
  7. 1-RTT vs 0-RTT 详细对比
```

---

## 2. TLS 1.3 快速回顾

### 2.1 TLS 1.3 vs TLS 1.2

```
TLS 握手演进：

┌──────────────────────────────────────────────────────────────────────┐
│                        TLS 1.2 握手                                 │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   Client ──── ClientHello ──────────────────────────────────────►   │
│                    (支持的密码套件, 随机数)                          │
│                                                                      │
│              ◄─── ServerHello ──────────────────────────────────   │
│                    (选中的密码套件, 随机数)                          │
│              ◄─── Certificate ──────────────────────────────────   │
│                    (服务器证书链)                                     │
│              ◄─── ServerKeyExchange ───────────────────────────   │
│                    (DH 参数, 签名)                                   │
│              ◄─── ServerHelloDone ─────────────────────────────   │
│                                                                      │
│   Client ──── ClientKeyExchange ──────────────────────────────►   │
│                    (DH 客户端公开值)                                  │
│   Client ──── ChangeCipherSpec ──────────────────────────────►   │
│   Client ──── Finished ───────────────────────────────────────►   │
│                    (加密 Finished 消息)                              │
│                                                                      │
│              ◄─── ChangeCipherSpec ───────────────────────────   │
│              ◄─── Finished ────────────────────────────────────   │
│                                                                      │
│   Total: 2 RTT                                                     │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────┐
│                        TLS 1.3 握手                                 │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   Client ──── ClientHello ─────────────────────────────────────►   │
│                    (支持的密码套件, 随机数, DH 公开值)                │
│                                                                      │
│              ◄─── ServerHello ──────────────────────────────────   │
│                    (选中的密码套件, 随机数, DH 公开值)                │
│              ◄─── {EncryptedExtensions} ────────────────────────   │
│                    (服务器 EncryptedExtensions)                       │
│              ◄─── {Certificate} ───────────────────────────────   │
│                    (服务器证书)                                      │
│              ◄─── {CertificateVerify} ─────────────────────────   │
│                    (签名)                                            │
│              ◄─── {Finished} ──────────────────────────────────   │
│                    (所有消息加密发送)                                 │
│                                                                      │
│   Client ──── {Finished} ──────────────────────────────────────►   │
│                    (所有消息加密发送)                                 │
│                                                                      │
│   Total: 1 RTT                                                    │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

### 2.2 TLS 1.3 关键改进

```
TLS 1.3 关键改进：

┌──────────────────────────────────────────────────────────────────────┐
│                        TLS 1.3 改进                                  │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   1. 握手延迟                                                       │
│      · TLS 1.2: 2 RTT                                             │
│      · TLS 1.3: 1 RTT                                             │
│                                                                      │
│   2. 0-RTT                                                         │
│      · 恢复会话时，提前发送数据                                      │
│      · 0 RTT 延迟                                                   │
│      · 有重放风险                                                    │
│                                                                      │
│   3. 密钥共享                                                       │
│      · (EC)DHE 密钥交换必须                                        │
│      · 前向保密 (PFS)                                               │
│                                                                      │
│   4. 加密更多消息                                                   │
│      · 证书加密发送                                                 │
│      · 更多握手消息受保护                                           │
│                                                                      │
│   5. 简化密码套件                                                   │
│      · AES-128/256-GCM (AEAD)                                     │
│      · ChaCha20-Poly1305                                          │
│      · 256-bit hash (SHA-384)                                      │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 3. QUIC 握手设计

### 3.1 QUIC 中的 TLS

```
QUIC 与 TLS 集成：

┌──────────────────────────────────────────────────────────────────────┐
│                        QUIC 中的 TLS                                 │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   QUIC 不直接使用 TLS，而是实现了 TLS 的功能：                        │
│                                                                      │
│   ┌──────────────────────────────────────────────────────────────┐  │
│   │                     QUIC                                      │  │
│   │  ┌────────────────────────────────────────────────────────┐ │  │
│   │  │              TLS 1.3 Record Layer                        │ │  │
│   │  │  (TLS message → QUIC frames → packets)                  │ │  │
│   │  └────────────────────────────────────────────────────────┘ │  │
│   │  ┌────────────────────────────────────────────────────────┐ │  │
│   │  │              QUIC Crypto Frames                        │ │  │
│   │  │  (TLS handshake data)                                  │ │  │
│   │  └────────────────────────────────────────────────────────┘ │  │
│   └──────────────────────────────────────────────────────────────┘  │
│                                                                      │
│   TLS 消息流：                                                      │
│   · TLS handshake messages → CRYPTO frames                        │
│   · CRYPTO frames → packets                                        │
│   · 每个 CRYPTO frame 有 offset 和 length                          │
│   · 类似于 TLS 的 records，但更细粒度                               │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

### 3.2 QUIC 握手包类型

```
QUIC 握手包：

┌──────────────────────────────────────────────────────────────────────┐
│                        QUIC 包类型与密钥                            │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   ┌──────────────────────────────────────────────────────────────┐  │
│   │                     Initial Packet                          │  │
│   │  密钥: Initial secrets → Initial keys                      │  │
│   │  内容: CRYPTO frames (ClientHello, etc.)                   │  │
│   │  认证: AEAD_AES_128_GCM                                     │  │
│   │  保护: 使用 initial secrets 导出密钥                        │  │
│   └──────────────────────────────────────────────────────────────┘  │
│                                                                      │
│   ┌──────────────────────────────────────────────────────────────┐  │
│   │                     0-RTT Packet                            │  │
│   │  密钥: 0-RTT keys (从 resumption master secret 导出)        │  │
│   │  内容: STREAM frames (early data)                          │  │
│   │  保护: 使用 0-RTT keys                                      │  │
│   └──────────────────────────────────────────────────────────────┘  │
│                                                                      │
│   ┌──────────────────────────────────────────────────────────────┐  │
│   │                   Handshake Packet                          │  │
│   │  密钥: Handshake keys (从 handshake traffic secret 导出)    │  │
│   │  内容: CRYPTO frames (ServerHello, etc.)                   │  │
│   │  保护: 使用 handshake keys                                 │  │
│   └──────────────────────────────────────────────────────────────┘  │
│                                                                      │
│   ┌──────────────────────────────────────────────────────────────┐  │
│   │               Short Header Packet                           │  │
│   │  密钥: 1-RTT keys (从 handshake 导出)                      │  │
│   │  内容: STREAM frames, ACK frames                          │  │
│   │  保护: 使用 1-RTT keys                                     │  │
│   └──────────────────────────────────────────────────────────────┘  │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 4. 详细握手流程

### 4.1 完整握手时序

```
QUIC 完整握手：

┌──────────────────────────────────────────────────────────────────────┐
│                        QUIC 握手时序                                 │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   Client                              Server                        │
│   ──────                              ──────                        │
│                                                                      │
│   [派生出 Initial keys]                                                │
│   Initial[                              │
│     CRYPTO[                             │
│       ch={                               │
│         version,                          │
│         client_random,                   │
│         cipher_suites,                   │
│         extensions,                      │
│         key_share (Y*g^x),              │
│         early_data extension            │
│       }                                  │
│     ]                                    │
│   ] ────────────────────────────────────────────────────────────►  │
│                                                                      │
│   0-RTT[                                                        │
│     STREAM[data]                                                │
│   ] (optional) ────────────────────────────────────────────────►   │
│                                                                      │
│         ◄────────────────────────────────────────── Initial[        │
│                                                           CRYPTO[   │
│                                                             sh={    │
│                                                               sv,   │
│                                                               cs,   │
│                                                               key_share │
│                                                             },      │
│                                                             trs,    │
│                                                             ct,     │
│                                                             cv      │
│                                                           }         │
│                                                           ]         │
│                                                           ]         │
│         ◄────────────────────────────────────────── Handshake[      │
│                                                           CRYPTO[  │
│                                                             sfin    │
│                                                           ]         │
│                                                           ]         │
│   [派生出 Handshake keys]                                        │
│   Initial[ACK] ────────────────────────────────────────────────►   │
│                                                                      │
│   Handshake[                                            │
│     CRYPTO[                                              │
│       cf={                                                │
│         client_random,                                    │
│         key_share (X*g^y),                               │
│         {encrypted_extensions}                            │
│       }                                                   │
│     ]                                                     │
│   ] ───────────────────────────────────────────────────►          │
│   Handshake[ACK] ───────────────────────────────────────────►        │
│                                                                      │
│   [派生出 1-RTT keys]                                              │
│   1-RTT[STREAM[data]] ──────────────────────────────────────►     │
│                                                                      │
│         ◄────────────────────────────── 1-RTT[STREAM[data]]         │
│         ◄────────────────────────────── Handshake_DONE              │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘

缩写说明：
  ch = ClientHello
  sh = ServerHello
  cf = CertificateFrame
  cv = CertificateVerify
  trs = transcript hash
  sfin = Finished
  sv = server_random
  cs = cipher_suite
```

### 4.2 Initial 包处理

```c
// QUIC Initial 包处理伪代码

struct initial_packet {
    // Long Header
    u8  packet_type = 0b00;  // Initial
    u8  reserved;
    u32 version;
    u8  dest_conn_id_len;
    u8  dest_conn_id[dest_conn_id_len];
    u8  src_conn_id_len;
    u8  src_conn_id[src_conn_id_len];
    u32 length;  // payload + packet number + auth tag
    u32 packet_number;  // 变长编码

    // Payload (加密)
    u8  payload[];  // CRYPTO frames
};

// Initial 包必须至少 1200 bytes
// (抗放大攻击要求)

int process_initial_packet(struct connection *conn,
                          struct initial_packet *pkt) {
    // 1. 解析 packet header
    parse_header(pkt);

    // 2. 验证版本
    if (pkt->version != supported_version) {
        // 发送 Version Negotiation
        send_version_negotiation(conn, pkt);
        return -1;
    }

    // 3. 导出 Initial keys
    derive_initial_keys(pkt->dest_conn_id);

    // 4. 解密 payload
    decrypt_payload(pkt);

    // 5. 处理 CRYPTO frames
    for each frame in pkt->payload:
        if frame.type == CRYPTO:
            process_crypto_frame(frame);

    // 6. 验证 handshake
    if (handshake_complete()) {
        // 派生 handshake keys
        derive_handshake_keys();

        // 派生 1-RTT keys
        derive_1rtt_keys();
    }

    return 0;
}
```

### 4.3 TLS 消息处理

```c
// QUIC CRYPTO frame 处理

struct crypto_frame {
    u8  type = 0x06;  // CRYPTO
    u64 offset;        // crypto 流中的偏移
    u64 length;        // 数据长度
    u8  data[length];  // TLS message data
};

// QUIC crypto 流是单向 ordered stream
// 类似于 TLS handshake 消息序列

struct crypto_stream {
    u8  *buffer;
    size_t buffer_len;
    size_t highest_offset;
    // 等待缺失的数据
};

// 处理 CRYPTO frame
int process_crypto_frame(struct connection *conn,
                         struct crypto_frame *frame) {
    // 1. 检查 offset
    if (frame->offset > conn->crypto_stream.highest_offset) {
        // 缓存 frame，等待中间数据
        cache_crypto_frame(conn, frame);
        return 0;
    }

    // 2. 检查是否有 gap
    if (has_gap(conn->crypto_stream, frame)) {
        // 等待缺失数据
        cache_crypto_frame(conn, frame);
        return 0;
    }

    // 3. 处理完整的数据
    append_to_stream(&conn->crypto_stream, frame);

    // 4. 尝试提取 TLS messages
    while (has_complete_tls_message(conn->crypto_stream)) {
        struct tls_message *msg = extract_tls_message(&conn->crypto_stream);

        // 5. 送入 TLS state machine
        tls_process_message(conn->tls, msg);
    }

    return 0;
}
```

---

## 5. 密钥导出机制

### 5.1 Initial Secrets

```
Initial Secret 导出：

┌──────────────────────────────────────────────────────────────────────┐
│                        Initial Secret                               │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   HKDF-Extract-SHA256(                                              │
│     salt = "QUIC v1" or client dst_conn_id,                        │
│     IKM = client hello + server hello (transcript)                 │
│   ) → initial_secret                                               │
│                                                                      │
│   或使用更简单的定义：                                               │
│                                                                      │
│   initial_salt = 0xafbfec289993d3c9592a400459fba2a8b28c67e3d36     │
│   initial_secret = HKDF-Extract(initial_salt, dst_conn_id)        │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘

Initial Keys 导出：

  client_initial_secret = TLS-Exporter(
      "QUIC client inither initial secret",
      32
  )

  server_initial_secret = TLS-Exporter(
      "QUIC server inither initial secret",
      32
  )

  client_initial_key = HKDF-Expand-Label(
      client_initial_secret,
      "quic key",
      "",
      16
  )

  client_initial_iv = HKDF-Expand-Label(
      client_initial_secret,
      "quic iv",
      "",
      12
  )

  client_initial_hp = HKDF-Expand-Label(  // header protection
      client_initial_secret,
      "quic hp",
      "",
      16
  )
```

### 5.2 密钥派生流程

```
QUIC 密钥派生树：

┌──────────────────────────────────────────────────────────────────────┐
│                        密钥派生                                     │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│                        PSK (Pre-Shared Key)                        │
│                            or                                       │
│                    ClientHello.random                               │
│                            │                                        │
│                            ▼                                        │
│                   Handshake Secrets                                 │
│                            │                                        │
│              ┌─────────────┴─────────────┐                         │
│              │                           │                         │
│              ▼                           ▼                         │
│      Client Handshake           Server Handshake                    │
│        Secret                    Secret                             │
│              │                           │                         │
│              ▼                           ▼                         │
│      Client Handshake           Server Handshake                    │
│        Traffic Secret            Traffic Secret                      │
│              │                           │                         │
│       ┌──────┴──────┐             ┌──────┴──────┐                   │
│       │             │             │             │                   │
│       ▼             ▼             ▼             ▼                   │
│   Client HSK    Client HSK    Server HSK   Server HSK              │
│   Key/IV        HP Key        Key/IV       HP Key                  │
│                                                                      │
│   Client Handshake Secret ──────────────────────────────►             │
│            │                                                        │
│            ▼                                                        │
│      Derived Secret                                                 │
│            │                                                        │
│            ▼                                                        │
│     1-RTT Client Traffic Secret                                     │
│            │                                                        │
│     ┌──────┴──────┐                                                │
│     ▼             ▼                                                │
│ 1-RTT Key    1-RTT IV    1-RTT HP Key                              │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

### 5.3 密钥更新

```
密钥更新 (Key Update):

┌──────────────────────────────────────────────────────────────────────┐
│                        密钥更新流程                                  │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   触发条件：                                                        │
│   · 发送了一定数量的包后                                          │
│   · 接收到对方的 KEY_UPDATE frame                                  │
│                                                                      │
│   更新流程：                                                        │
│                                                                      │
│   Sender:                                                         │
│   1. 生成新的 traffic secret                                        │
│   2. 导出新的 key, iv, hp                                          │
│   3. 使用新密钥加密后续包                                           │
│   4. 发送 KEY_UPDATE frame                                         │
│                                                                      │
│   Receiver:                                                       │
│   1. 收到 KEY_UPDATE frame                                         │
│   2. 切换到新密钥                                                   │
│   3. 使用新密钥解密                                                │
│   4. 导出下一代的密钥（用于解密下一个 UPDATE）                       │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘

KEY_UPDATE Frame:

  Type: 0x18 (short header) or 0x07 (long header)

  ┌────────────────────────────────────────────────────────────┐
  │  Type                                                        │
  │  Operation: 0x01 = UPDATE, 0x02 = ACKNOWLEDGE               │
  │  Sequence Number: varint                                    │
  └────────────────────────────────────────────────────────────┘
```

---

## 6. 握手状态机

### 6.1 客户端状态机

```
QUIC 客户端握手状态机：

┌──────────────────────────────────────────────────────────────────────┐
│                        客户端状态                                   │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   States:                                                         │
│   · Handshake starts with Initial packet containing ClientHello    │
│   · State advances when handshake messages are confirmed           │
│   · Handshake is complete when handshake has been confirmed       │
│                                                                      │
│   Initial ▼ Handshake Complete ▼ Confirmed                         │
│      │            │              │                                  │
│      │            │              │                                  │
│      ▼            ▼              ▼                                  │
│   ┌────────┐  ┌──────────┐  ┌──────────┐                           │
│   │ Start  │──►│ Handshake│──►│ Complete │                         │
│   └────────┘  └──────────┘  └──────────┘                           │
│      │            │              │                                  │
│      │            │              │                                  │
│      ▼            ▼              ▼                                  │
│   Cannot       Can send      Can send                             │
│   send any    0-RTT,        1-RTT,                               │
│   1-RTT       Handshake    1-RTT,                               │
│               packets      handshake confirmed                   │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘

状态转换：

  Start → Handshake:
    发送 Initial 包 (ClientHello)
    派生出 Initial keys
    接收 ServerHello

  Handshake → Complete:
    接收到 ServerFinished
    派生出 1-RTT keys
    Handshake packets acked

  Complete → Confirmed:
    handshakeconfirmed 事件触发
    确认握手完成
```

### 6.2 服务端状态机

```
QUIC 服务端握手状态机：

┌──────────────────────────────────────────────────────────────────────┐
│                        服务端状态                                   │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   States:                                                         │
│   · Handshake starts with Initial packet containing ServerHello    │
│   · State advances when handshake messages are confirmed           │
│   · Handshake is complete when handshake has been confirmed        │
│                                                                      │
│   Initial ▼ Handshake Complete ▼ Confirmed                         │
│      │            │              │                                  │
│      │            │              │                                  │
│      ▼            ▼              ▼                                  │
│   ┌────────┐  ┌──────────┐  ┌──────────┐                           │
│   │ Stateli│──►│ Handshake│──►│ Complete │                         │
│   └────────┘  └──────────┘  └──────────┘                           │
│      │            │              │                                  │
│      │            │              │                                  │
│      ▼            ▼              ▼                                  │
│   Cannot       Can send      Can send                             │
│   receive     0-RTT,        1-RTT,                               │
│   1-RTT       Handshake     handshake confirmed                   │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

### 6.3 状态转换图

```
完整状态转换图：

┌──────────────────────────────────────────────────────────────────────┐
│                    QUIC 握手状态转换                                │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   Client                              Server                        │
│   ──────                              ──────                        │
│   STATE_START ──────────────────────────────► Initial              │
│                                                                      │
│         ◄──────────────────────────────────── STATE_RECVD          │
│                                                                      │
│   Initial_Key_Derived                                          │
│         │                                                        │
│         ▼                                                        │
│   STATE_HANDSHAKE                                                │
│         │                                                        │
│         │ Handshake_Key_Derived                                   │
│         ▼                                                        │
│   STATE_HANDSHAKE_COMPLETE                                       │
│         │                                                        │
│         │ Handshake_Confirmed                                     │
│         ▼                                                        │
│   STATE_CONFIRMED                                                │
│                                                                      │
│         │                                                        │
│         │ 1RTT_Key_Derived                                        │
│         ▼                                                        │
│   Can send/receive 1-RTT data                                    │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘

关键事件：

  Initial_Key_Derived:
    - 从 ClientHello 派生出 Initial keys
    - 可以解密 Initial 包

  Handshake_Key_Derived:
    - 从 ServerHello 派生出 Handshake keys
    - 可以解密 Handshake 包

  State_Handshake_Complete:
    - 收到 ServerFinished
    - 派生出 1-RTT keys
    - 可以发送 1-RTT 数据

  Handshake_Confirmed:
    - 握手消息被确认
    - 不再需要处理 0-RTT 包
```

---

## 7. 1-RTT vs 0-RTT 详细对比

### 7.1 0-RTT 原理

```
0-RTT 原理：

┌──────────────────────────────────────────────────────────────────────┐
│                        0-RTT 数据                                    │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   前提：客户端有之前会话的 PSK (Pre-Shared Key)                       │
│                                                                      │
│   原理：                                                            │
│   · PSK 用于派生 0-RTT 密钥                                        │
│   · 密钥在首次往返中即可使用                                        │
│   · 无需等待 ServerHello                                           │
│                                                                      │
│   0-RTT 包结构：                                                    │
│   ┌────────────────────────────────────────────────────────────┐     │
│   │  Long Header (Type = 0b01, 0-RTT)                        │     │
│   │  Connection ID                                           │     │
│   │  Packet Number                                           │     │
│   │  ─────────────────────────────────────────────────────── │     │
│   │  CRYPTO/STREAM frames (使用 0-RTT keys 加密)            │     │
│   └────────────────────────────────────────────────────────────┘     │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘

0-RTT 重放风险：

  攻击场景：
  1. 攻击者录制 0-RTT 包
  2. 稍后重放给服务器
  3. 服务器误认为是合法的 0-RTT 请求

  影响：
  · GET 请求可能重复执行
  · POST 等非幂等请求有风险
  · 缓存污染攻击

  缓解措施：
  · HTTP/3: 0-RTT 只发送 idempotent 请求
  · TLS: 机制防止重放
  · 客户端: 谨慎使用 0-RTT
```

### 7.2 1-RTT vs 0-RTT 对比

```
1-RTT vs 0-RTT：

┌──────────────────────────────────────────────────────────────────────┐
│                        对比表                                        │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   特性              │  1-RTT              │  0-RTT              │
│   ──────────────────┼─────────────────────┼──────────────────────│
│   延迟              │  1 RTT              │  0 RTT              │
│   可发送数据        │  ServerHello 后     │  立即可发            │
│   前向保密          │  ✓ (DH)            │  ✗ (仅 PSK)         │
│   重放风险          │  无                 │  有                 │
│   服务器状态        │  无状态             │  有状态 (anti-replay)│
│   适用场景          │  首次连接          │  恢复会话           │
│   密钥来源          │  (EC)DHE           │  PSK                │
│   安全性            │  高                │  中 (依赖 PSK)      │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────┐
│                        握手流程对比                                   │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   1-RTT:                                                          │
│   Client ── Initial[CH] ───────────────────────────────────────►   │
│         ◄── Initial[SH] ────────────────────────────────────────   │
│         ◄── Handshake[SFIN] ────────────────────────────────────   │
│   Client ── Handshake[CF] ────────────────────────────────────►   │
│   Client ── 1-RTT[data] ──────────────────────────────────────►   │
│   Total: 1 RTT                                                    │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   0-RTT (with 1-RTT fallback):                                    │
│   Client ── Initial[CH+0RTT] ──────────────────────────────────►   │
│   Client ── 0-RTT[data] ──────────────────────────────────────►   │
│         ◄── Initial[SH] ────────────────────────────────────────   │
│         ◄── Handshake[SFIN] ────────────────────────────────────   │
│   Client ── Handshake[CF] ────────────────────────────────────►   │
│   Client ── 1-RTT[data] ──────────────────────────────────────►   │
│   Total: 1 RTT (with 0-RTT data)                                  │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   0-RTT Rejected:                                                 │
│   Client ── Initial[CH+0RTT] ──────────────────────────────────►   │
│   Client ── 0-RTT[data] ──────────────────────────────────────►   │
│         ◄── Initial[SH + HelloRetryRequest] ────────────────────   │
│   Client ── Initial[CH] ───────────────────────────────────────►   │
│         ◄── Initial[SH] ────────────────────────────────────────   │
│         ◄── Handshake[SFIN] ────────────────────────────────────   │
│   Total: 2 RTT                                                    │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

### 7.3 PSK 管理

```
PSK (Pre-Shared Key) 管理：

┌──────────────────────────────────────────────────────────────────────┐
│                        PSK 类型                                      │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   PSK 种类：                                                        │
│   · External PSK (PSK 直接分享)                                    │
│   · Resumption PSK (从之前会话恢复)                                 │
│   · PSK with (EC)DHE (混合模式)                                     │
│                                                                      │
│   QUIC 主要使用 Resumption PSK：                                    │
│   · 从 TLS session ticket 导出                                    │
│   · 存储在客户端                                                    │
│   · 用于快速恢复会话                                                │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘

Session Ticket 结构：

  struct session_ticket {
      u32 ticket_lifetime;       // 票据有效期
      u32 ticket_age_add;       // 用于混淆 ticket age
      u32 ticket_nonce;         // 防重放
      u8  ticket[];             // ticket 数据
      // 包含:
      // - resumption_master_secret
      // - client_random
      // - cipher_suite
      // - server's config
  }

PSK 导出流程：

  1. 服务器在 Finished 消息中发送 session ticket
  2. 客户端存储 ticket 和相关参数
  3. 下次连接时，客户端在 ClientHello 中包含 PSK
  4. 服务器验证 PSK，恢复会话状态
```

---

## 8. Retry 机制

### 8.1 Retry 流程

```
Retry 机制 (抗放大攻击):

┌──────────────────────────────────────────────────────────────────────┐
│                        Retry 流程                                    │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   Client ─── Initial[CH, dst_conn_id=X] ──────────────────────►     │
│                    (X 是客户端选择的 CID)                            │
│                                                                      │
│              ◄─── Initial[RETRY, token=Y]                        │
│                    (服务端的 Retry Token)                            │
│                                                                      │
│   Client ─── Initial[CH, dst_conn_id=Z, token=Y] ──────────────►   │
│                    (Z 是新 CID，token 来自 Retry)                   │
│                    (服务端验证 token)                                │
│                                                                      │
│              ◄─── Initial[SH]                                      │
│              ◄─── Handshake[SFIN]                                  │
│                                                                      │
│   Client ─── Handshake[CF] ──────────────────────────────────────►  │
│   Client ─── 1-RTT[data] ──────────────────────────────────────►   │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘

Retry Token 格式：

  struct retry_token {
      u64   odci;        // Original Dest Connection ID
      u64   expiry;      // 过期时间
      u8    random[];    // 随机数据
      u8    auth_tag[];  // 认证标签
  }

  服务端验证：
  1. 解密 token
  2. 检查 expiry
  3. 检查 odci 是否匹配
  4. 验证认证标签
```

### 8.2 验证流程

```c
// Retry Token 验证伪代码

bool validate_retry_token(struct connection *conn,
                          struct retry_token *token) {
    // 1. 检查 expiry
    if (current_time() > token->expiry) {
        return false;  // Token 过期
    }

    // 2. 检查 Original Dest CID
    if (token->odci != conn->original_dst_conn_id) {
        return false;  // CID 不匹配，可能是重放
    }

    // 3. 验证认证标签
    if (!verify_auth_tag(token)) {
        return false;  // 认证失败
    }

    // 4. 检查是否已使用（anti-replay）
    if (is_token_used(token)) {
        return false;  // 已使用
    }

    // 5. 标记为已使用
    mark_token_used(token);

    return true;
}
```

---

## 9. 小结

```
QUIC Ch2 总结：

TLS 1.3 集成：
  · QUIC 内嵌 TLS 1.3 功能
  · TLS messages → CRYPTO frames → packets
  · 不使用 TLS records，直接处理 TLS messages

密钥派生：
  · Initial secrets → Initial keys (握手开始)
  · Handshake secrets → Handshake keys
  · 1-RTT secrets → 1-RTT keys
  · PSK → 0-RTT keys

握手状态机：
  · 客户端: Start → Handshake → Complete → Confirmed
  · 服务端: Stateliest → Handshake → Complete → Confirmed

1-RTT vs 0-RTT:
  · 1-RTT: 首次连接，使用 DH 密钥交换，有前向保密
  · 0-RTT: 恢复会话，使用 PSK，无前向保密，有重放风险

Retry 机制：
  · 防止放大攻击
  · 服务端发送 Retry Token
  · 客户端在下一次 Initial 中包含 Token

下一章预告：
  Ch3: 流控与拥塞控制
  - QUIC 流控机制
  - 拥塞控制算法
  - 丢包检测
  - RTT 测量
```

---

## 延伸阅读

- RFC 9001: Using TLS to Secure QUIC
- RFC 8446: TLS 1.3
- draft-ietf-quic-tls: QUIC/TLS interface
- RFC 9002: QUIC Loss Detection and Congestion Control
- TLS 1.3 handshake: https://tls13.ulfheim.net/
- 0-RTT analysis: https://eprint.iacr.org/2019/1175
