---
title: "DPDK 深度探索 (二十三)：TLS/DTLS 加速与 Session 管理"
date: 2026-04-09
tags: [dpdk, series, tls, dtls, ssl, openssl, session, crypto, ipsec, tls-record, handshake]
description: "深入理解 TLS/DTLS 协议与 DPDK 加速——记录层、握手流程、session 管理、TLS 卸载、Crypto 数据面与控制面分离"
---

> [!info] DPDK 深度探索系列
> 0. [[2026-04-09-dpdk-deep-dive-series-index|全栈学习路径总览]]
> 1-22. 前二十二章已完成
> 23. **第二十三章：TLS/DTLS 加速与 Session 管理**

---

## 1. 概述：TLS/DTLS 与 IPsec 的区别

### 1.1 TLS 在协议栈中的位置

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        TLS 在协议栈中的位置                                │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  传统协议栈:                                                               │
│  ──────────────                                                            │
│  ┌──────────┐                                                              │
│  │   HTTP   │  ────── Application Layer                                  │
│  ├──────────┤                                                              │
│  │   TLS    │  ────── Security Layer (在 TCP 和 HTTP 之间)               │
│  ├──────────┤                                                              │
│  │   TCP    │  ────── Transport Layer                                     │
│  ├──────────┤                                                              │
│  │   IP     │  ────── Network Layer                                       │
│  └──────────┘                                                              │
│                                                                             │
│  IPsec vs TLS:                                                             │
│  ──────────────                                                            │
│                                                                             │
│  ┌─────────────────────┐    ┌─────────────────────┐                      │
│  │      IPsec           │    │       TLS            │                      │
│  │  (Network Layer)     │    │  (Application Layer)│                      │
│  ├─────────────────────┤    ├─────────────────────┤                      │
│  │  保护整个 IP 包      │    │  保护应用数据        │                      │
│  │  对应用透明          │    │  应用感知            │                      │
│  │  ESP/AH 协议         │    │  TLS 1.2/1.3 协议    │                      │
│  │  透明网关            │    │  端到端加密          │                      │
│  └─────────────────────┘    └─────────────────────┘                      │
│                                                                             │
│  典型场景:                                                                 │
│  - IPsec: VPN、网关、站点到站点                                            │
│  - TLS: HTTPS、Web 服务的端到端安全                                        │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 1.2 TLS 协议层次

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            TLS 协议层次                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐ │
│  │                       TLS Handshake Protocol                        │ │
│  │   ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐               │ │
│  │   │  Client │ │  Server │ │  Client │ │  Server │               │ │
│  │   │  Hello  │ │  Hello  │ │  Cert   │ │  Cert   │               │ │
│  │   │         │ │         │ │  KeyEx  │ │  KeyEx  │               │ │
│  │   │         │ │         │ │  Finish │ │  Finish │               │ │
│  │   └─────────┘ └─────────┘ └─────────┘ └─────────┘               │ │
│  │       │            │            │            │                    │ │
│  │       └────────────┴────────────┴────────────┘                    │ │
│  │                          │                                          │ │
│  │       认证 + 密钥交换 + 加密参数协商                                │ │
│  └─────────────────────────────────────────────────────────────────────┘ │
│                                    │                                        │
│                                    ▼                                        │
│  ┌─────────────────────────────────────────────────────────────────────┐ │
│  │                       TLS Record Protocol                           │ │
│  │                                                                      │ │
│  │   ┌─────────────┐  ┌─────────────┐  ┌─────────────┐                │ │
│  │   │ Application │  │  Change     │  │   Alert     │                │ │
│  │   │    Data     │  │   Cipher    │  │             │                │ │
│  │   │  (HTTP/FTP) │  │   Spec      │  │             │                │ │
│  │   └──────┬──────┘  └──────┬──────┘  └──────┬──────┘                │ │
│  │          │                │                │                        │ │
│  │          └────────────────┴────────────────┘                         │ │
│  │                           │                                           │ │
│  │                           ▼                                           │ │
│  │   ┌───────────────────────────────────────────────────────────────┐  │ │
│  │   │                    MAC / Encryption                          │  │ │
│  │   │   AES-GCM / AES-CBC / ChaCha20-Poly1305                     │  │ │
│  │   └───────────────────────────────────────────────────────────────┘  │ │
│  │                                                                      │ │
│  └───────────────────────────────────────────────────────────────────────┘ │
│                                    │                                        │
│                                    ▼                                        │
│                         ┌─────────────────────┐                            │
│                         │       TCP           │                            │
│                         │   (可靠传输)        │                            │
│                         └─────────────────────┘                            │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 1.3 TLS vs DTLS

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            TLS vs DTLS                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  TLS (Transport Layer Security)                                           │
│  ─────────────────────────────────                                        │
│  - 基于 TCP (可靠传输)                                                      │
│  - 序列号隐式 (从 MAC 计算)                                                │
│  - 无重排序问题                                                            │
│  - 无握手超时                                                               │
│  - 典型应用: HTTPS (HTTP over TLS)                                        │
│                                                                             │
│  DTLS (Datagram TLS)                                                      │
│  ───────────────────────                                                   │
│  - 基于 UDP (不可靠传输)                                                    │
│  - 显式序列号 + Cookie 机制                                                │
│  - 处理包重排序、乱序、丢失                                                │
│  - 添加握手超时和重传                                                      │
│  - 典型应用: VoIP, VPN, WebRTC, DTLS-based IPsec                         │
│                                                                             │
│  DTLS 额外机制:                                                           │
│  ────────────────                                                         │
│  ┌─────────────────────────────────────────────────────────────────────┐ │
│  │  1. Cookie Exchange (防止 DoS)                                      │ │
│  │     ClientHello ──► Cookie=nonce                                   │ │
│  │                ◄─── HelloVerifyRequest                              │ │
│  │     ClientHello + Cookie ──►                                        │ │
│  │                                                                      │ │
│  │  2. 握手重传定时器                                                    │ │
│  │     丢失包 ──► 超时 ──► 重传                                         │ │
│  │                                                                      │ │
│  │  3. 消息跳跃 (Message Hop)                                          │ │
│  │     不连续的握手消息可以分片传输                                      │ │
│  │                                                                      │ │
│  │  4. 序列号风暴抑制                                                    │ │
│  │     每个 epoch 有独立的序列号空间                                      │ │
│  └─────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. TLS 记录层协议

### 2.1 TLS Record 格式

```c
// TLS Record 结构
struct tls_record {
    uint8_t type;              // Content Type
    uint16_t version;          // TLS Version (0x0301=TLS1.0, 0x0303=TLS1.2, 0x0304=TLS1.3)
    uint16_t length;           // Payload 长度 (最大 16384 = 2^14)
    uint8_t payload[];        // 加密/明文数据
};

// Content Types
enum tls_content_type {
    TLS_CHANGE_CIPHER_SPEC = 20,
    TLS_ALERT = 21,
    TLS_HANDSHAKE = 22,
    TLS_APPLICATION_DATA = 23,
    TLS_HEARTBEAT = 24,        // TLS 1.3
};

// TLS Versions
enum {
    TLS_1_0 = 0x0301,
    TLS_1_1 = 0x0302,
    TLS_1_2 = 0x0303,
    TLS_1_3 = 0x0304,
    DTLS_1_0 = 0xFEFF,
    DTLS_1_2 = 0xFEFD,
    DTLS_1_3 = 0x0304,  // DTLS 1.3 使用 TLS 1.3 版本号
};
```

### 2.2 TLS Record 加密流程

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        TLS Record 加密流程                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  TLS 1.2 AEAD (AES-GCM):                                                  │
│  ─────────────────────────────                                             │
│                                                                             │
│  ┌──────────────────────────────────────────────────────────────────────┐ │
│  │  Plaintext:  [Application Data]                                       │ │
│  │  + Implicit IV (来自 traffic secret)                                 │ │
│  │  + Sequence Number (64-bit, big-endian)                             │ │
│  │  ─────────────────────────────────────────────────────────────────── │ │
│  │  AAD (Additional Authenticated Data):                                │ │
│  │  [TLSRecord.type] [TLSRecord.version] [TLSRecord.length]             │ │
│  │  ─────────────────────────────────────────────────────────────────── │ │
│  │  Output:  [Nonce (12 bytes)] [Ciphertext] [Tag (16 bytes)]          │ │
│  └──────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
│  TLS 1.3 AEAD:                                                            │
│  ─────────────────                                                        │
│                                                                             │
│  ┌──────────────────────────────────────────────────────────────────────┐ │
│  │  Key: traffic secret 派生的对称密钥                                   │ │
│  │  Nonce: explicit part (8 bytes) = seq_num ^ implicit_nonce           │ │
│  │  AAD: same as TLS 1.2                                                │ │
│  │  Tag: 16 bytes                                                       │ │
│  └──────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
│  TLS 1.2 CBC+HMAC:                                                        │
│  ────────────────────                                                     │
│                                                                             │
│  ┌──────────────────────────────────────────────────────────────────────┐ │
│  │  mac = HMAC(cipher_key, seq_num || type || version || length || pt) │ │
│  │  pad = PKCS7_padding                                                │ │
│  │  plaintext = data || mac || pad                                     │ │
│  │  ciphertext = IV || AES(CBC, cipher_key, plaintext)               │ │
│  └──────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 2.3 TLS 记录层处理

```c
// TLS 记录层处理

struct tls_record_header {
    uint8_t type;
    uint16_t version;
    uint16_t length;
};

// 解析 TLS 记录
static inline int
tls_record_parse(const uint8_t *data, size_t len,
                  struct tls_record_header *hdr,
                  size_t *record_len)
{
    if (len < 5)
        return -1;  // 太小

    hdr->type = data[0];
    hdr->version = (data[1] << 8) | data[2];
    hdr->length = (data[3] << 8) | data[4];

    *record_len = 5 + hdr->length;

    if (len < *record_len)
        return -1;  // 数据不完整

    return 0;
}

// TLS 1.2 加密
static int
tls_record_encrypt(struct tls_context *ctx,
                    uint8_t type,
                    const uint8_t *plaintext, size_t pt_len,
                    uint8_t *ciphertext, size_t *ct_len)
{
    // 序列号
    uint64_t seq = ctx->tx_seq++;

    if (ctx->cipher_type == TLS_AEAD_GCM) {
        // AES-GCM 加密
        uint8_t nonce[12];
        memcpy(nonce, ctx->tx_iv, 4);  // implicit IV
        encode_be64(nonce + 4, seq);   // explicit part

        uint8_t aad[5] = {
            type,
            (ctx->version >> 8) & 0xFF,
            ctx->version & 0xFF,
            (pt_len >> 8) & 0xFF,
            pt_len & 0xFF
        };

        // AEAD 加密
        int ret = mbedtls_cipher_auth_encrypt(
            &ctx->cipher_ctx,
            nonce, 12,              // nonce
            aad, 5,                 // AAD
            plaintext, pt_len,      // input
            ciphertext + 8, ct_len, // output (+8 for nonce)
            ciphertext + pt_len + 8, 16); // tag

        // 写入 nonce
        memcpy(ciphertext, nonce, 8);
        *ct_len = pt_len + 8 + 16;

        return ret;
    }

    return -1;
}
```

---

## 3. TLS 握手协议

### 3.1 TLS 1.2 握手流程

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      TLS 1.2 握手流程                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  Client                          Server                                      │
│    │                               │                                         │
│    │──── ClientHello ─────────────►│  客户端随机数 + 支持的密码套件          │
│    │      (Random, SessionID,      │                                         │
│    │       CipherSuites,          │                                         │
│    │       Compression, Exts)     │                                         │
│    │                               │                                         │
│    │◄─── ServerHello ──────────────│  服务器随机数 + 选中的密码套件           │
│    │      (Random, SessionID,      │                                         │
│    │       CipherSuite,           │                                         │
│    │       Compression)           │                                         │
│    │                               │                                         │
│    │◄─── Certificate ──────────────│  服务器证书链 (X.509)                    │
│    │                               │                                         │
│    │◄─── ServerKeyExchange ───────│  (仅当证书不足以密钥交换时)             │
│    │                               │  DH 参数 或 ECDHE 签名                  │
│    │                               │                                         │
│    │◄─── CertificateRequest ───────│  (可选) 要求客户端证书                  │
│    │                               │                                         │
│    │◄─── ServerHelloDone ─────────│                                         │
│    │                               │                                         │
│    │──── ClientKeyExchange ───────►│  预主密钥 (RSA 加密 或 DH 客户端参数)   │
│    │      (PremasterSecret)        │                                         │
│    │                               │                                         │
│    │  [双方计算 MasterSecret]      │                                         │
│    │                               │                                         │
│    │──── CertificateVerify ───────►│  (可选) 客户端证书验证签名              │
│    │      (签名)                   │                                         │
│    │                               │                                         │
│    │──── ChangeCipherSpec ───────►│  通知开始加密                          │
│    │──── Finished ────────────────►│  握手摘要验证                          │
│    │      (加密的握手哈希)         │                                         │
│    │                               │                                         │
│    │◄─── ChangeCipherSpec ─────────│  通知开始加密                          │
│    │◄─── Finished ───────────────│  握手摘要验证                          │
│    │                               │                                         │
│    │══════ Application Data ══════│  开始加密通信                          │
│    │══════ (加密通道) ═════════════│                                         │
│    │                               │                                         │
│                                                                             │
│  密码套件示例:                                                             │
│  TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256                                    │
│  TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384                                    │
│  TLS_RSA_WITH_AES_128_CBC_SHA                                            │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 3.2 TLS 1.3 握手流程

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      TLS 1.3 握手流程                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  Client                          Server                                      │
│    │                               │                                         │
│    │──── ClientHello ─────────────►│  支持的密码套件 + Key Share            │
│    │      + supported_versions     │                                         │
│    │      + key_share (PQC/DH)     │                                         │
│    │      + supported_groups       │                                         │
│    │                               │                                         │
│    │                         ┌─────┴─────┐                                  │
│    │                         │ 选择密码套件│                                  │
│    │                         │ 选择 DH 组 │                                  │
│    │                         └─────┬─────┘                                  │
│    │                               │                                         │
│    │◄── ServerHello ───────────────│  版本协商 + Key Share                  │
│    │      + key_share              │  (Early Secret 派生的密钥)            │
│    │      + supported_versions     │                                         │
│    │                               │                                         │
│    │◄── {EncryptedExtensions} ─────│  扩展加密 (非握手数据)                 │
│    │◄── {CertificateRequest} ──────│  (可选) 要求证书                       │
│    │◄── {server Certificate} ──────│  证书                                  │
│    │◄── {server CertificateVerify} │  签名                                  │
│    │◄── {server Finished} ─────────│  握手摘要                             │
│    │                               │                                         │
│    │  [双方计算 Handshake Secret]  │                                         │
│    │  [双方计算 Traffic Secret 0]  │                                         │
│    │                               │                                         │
│    │──── {Certificate} ────────────►│  客户端证书                           │
│    │──── {CertificateVerify} ─────►│  签名                                  │
│    │──── {Finished} ──────────────►│  握手摘要                             │
│    │                               │                                         │
│    │  [双方计算 Traffic Secret 1]  │                                         │
│    │                               │                                         │
│    │══════ Application Data ══════│  使用 Traffic Secret 1 加密           │
│    │══════ (加密通道) ═════════════│                                         │
│    │                               │                                         │
│                                                                             │
│  TLS 1.3 改进:                                                             │
│  - 1-RTT (之前 2-RTT)                                                    │
│  - 0-RTT (Early Data, 但有重放风险)                                        │
│  - 前向保密 (必须使用 ECHDE/PQC)                                           │
│  - 移除 CBC+HMAC (仅 AEAD)                                                │
│  - 简化密码套件命名                                                        │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 3.3 握手消息结构

```c
// TLS Handshake 消息头
struct tls_handshake_hdr {
    uint8_t msg_type;          // HandshakeType
    uint24 length;             // 消息长度
    uint8_t data[];            // 消息内容
};

// Handshake Types
enum {
    TLS_HANDSHAKE_CLIENT_HELLO = 1,
    TLS_HANDSHAKE_SERVER_HELLO = 2,
    TLS_HANDSHAKE_NEW_SESSION_TICKET = 4,
    TLS_HANDSHAKE_END_OF_EARLY_DATA = 5,
    TLS_HANDSHAKE_ENCRYPTED_EXTENSIONS = 8,
    TLS_HANDSHAKE_CERTIFICATE = 11,
    TLS_HANDSHAKE_CERTIFICATE_REQUEST = 13,
    TLS_HANDSHAKE_CERTIFICATE_VERIFY = 15,
    TLS_HANDSHAKE_FINISHED = 20,
};

// ClientHello 结构
struct tls_client_hello {
    uint16_t client_version;           // 客户端支持的最高版本
    uint8_t random[32];               // 客户端随机数
    uint8_t session_id_len;
    uint8_t session_id[32];
    uint16_t cipher_suites_len;
    uint16_t cipher_suites[];         // 支持的密码套件列表
    uint8_t compression_methods_len;
    uint8_t compression_methods[];
    // 扩展...
};

// Certificate 结构 (X.509)
struct tls_certificate {
    uint24 certs_length;
    // 证书链 (ASN.1 DER 编码)
    //   cert_length[3]
    //   cert_data[cert_length]
    //   cert_length[3]
    //   cert_data[cert_length]
    //   ...
};

// Finished 消息 (HMAC 握手摘要)
struct tls_finished {
    uint8_t verify_data[12];  // TLS 1.2 SHA-256
    // TLS 1.3: HKDF-Extract 后计算
};
```

---

## 4. Session 与 Session Ticket

### 4.1 Session Resumption

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        TLS Session Resumption                             │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  完整握手 (Full Handshake):                                                │
│  ──────────────────────────                                                │
│  ClientHello ──►                                                       │
│                ◄── ServerHello + Certificate + ...                      │
│                (2-RTT, ~150ms)                                            │
│                                                                             │
│  Session ID 复用:                                                         │
│  ───────────────────                                                       │
│  ClientHello(session_id=abc) ──►                                           │
│                                  ◄── ServerHello(session_id=abc)         │
│                                  ◄── [Certificate]                        │
│                                  ◄── Finished                             │
│                (1-RTT)                                                     │
│                                                                             │
│  Session Ticket (TLS 1.2):                                               │
│  ──────────────────────────                                                │
│  第一次握手:                                                               │
│  ClientHello ──►                                                       │
│                ◄── ServerHello                                           │
│                ◄── NewSessionTicket (加密的 session state)               │
│                ◄── Finished                                               │
│                (保存 ticket)                                               │
│                                                                             │
│  后续握手:                                                                 │
│  ClientHello(session_ticket=ticket) ──►                                   │
│                                    ◄── [HelloRetryRequest] (如果需要)    │
│                                    ◄── Finished                             │
│                (0-RTT 或 1-RTT)                                           │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 4.2 Session State 结构

```c
// TLS Session 状态
struct tls_session_state {
    // 协议版本
    uint16_t version;

    // 密码套件
    uint16_t cipher_suite;

    // Master Secret (从预主密钥派生)
    uint8_t master_secret[48];

    // Client/Server Random
    uint8_t client_random[32];
    uint8_t server_random[32];

    // Session ID
    uint8_t session_id[32];
    uint8_t session_id_len;

    // Traffic Keys (用于加密)
    uint8_t client_write_key[32];
    uint8_t server_write_key[32];
    uint8_t client_write_iv[12];
    uint8_t server_write_iv[12];
    uint8_t client_write_mac_key[32];
    uint8_t server_write_mac_key[32];

    // 序列号
    uint64_t client_seq;
    uint64_t server_seq;

    // 过期时间
    uint64_t expire_time;

    // 扩展状态 (TLS 1.3)
    uint8_t early_secret[32];
    uint8_t handshake_secret[32];
    uint8_t master_secret_tls13[48];
    uint8_t traffic_secret_client[32];
    uint8_t traffic_secret_server[32];
};

// Session Ticket (加密的 session state)
struct tls_session_ticket {
    uint8_t ticket_lifetime[4];     // 生命周期 (秒)
    uint8_t ticket_age[4];         // ticket 年龄 (可选)
    uint8_t ticket_nonce[32];     // 服务器提供的 nonce
    uint8_t ticket[];             // 加密的 session state
    // 加密: AES-GCM(SHA-256(ticket_key), nonce, session_state)
};

// Session 存储 (内存或外部存储)
struct tls_session_store {
    struct rte_hash *session_by_id;    // session_id -> session_state
    struct rte_hash *session_by_ticket; // ticket -> session_state

    // LRU 缓存
    struct tls_lru_cache *lru;

    // 配置
    size_t max_sessions;
    size_t max_session_size;
};
```

### 4.3 Session 管理 API

```c
// DPDK TLS Session API

// 创建 Session
struct tls_session *
tls_session_create(struct tls_context *ctx,
                    const struct tls_session_config *config)
{
    struct tls_session *sess;

    sess = rte_zmalloc(NULL, sizeof(*sess), RTE_CACHE_LINE_SIZE);
    if (!sess)
        return NULL;

    sess->ctx = ctx;
    sess->state = TLS_SESSION_STATE_INIT;

    // 生成 session_id
    rte_rand(sess->session_id, 32);
    sess->session_id_len = 32;

    // 创建 crypto session
    sess->crypto_session = rte_cryptodev_sym_session_create(
        ctx->crypto_dev_id, ctx->cipher_xform);

    // 注册到 session 存储
    tls_session_store_add(ctx->session_store, sess);

    return sess;
}

// Session Ticket 处理
int
tls_session_write_ticket(struct tls_session *sess,
                          uint8_t *ticket, size_t *ticket_len)
{
    struct tls_session_ticket *st;
    uint8_t *encrypted;
    size_t plain_len, enc_len;

    // 序列化 session state
    plain_len = tls_session_state_serialize(sess, &plain);

    // 生成 nonce
    uint8_t nonce[12];
    rte_rand(nonce, 12);

    // 加密 session state
    st = sess->ctx->ticket_cipher;
    enc_len = tls_gcm_encrypt(st->key, nonce,
                               plain, plain_len,
                               encrypted);

    // 构建 ticket
    encode_be32(ticket, sess->expire_time);
    encode_be32(ticket + 4, 0);  // ticket_age_estimate
    memcpy(ticket + 8, nonce, 12);
    memcpy(ticket + 20, encrypted, enc_len);

    *ticket_len = 20 + enc_len;

    return 0;
}

// Session Ticket 恢复
struct tls_session *
tls_session_from_ticket(struct tls_context *ctx,
                         const uint8_t *ticket, size_t ticket_len)
{
    // 解析 ticket
    uint32_t lifetime = decode_be32(ticket);
    uint8_t *nonce = (uint8_t *)ticket + 8;
    uint8_t *encrypted = (uint8_t *)ticket + 20;
    size_t enc_len = ticket_len - 20;

    // 检查过期
    if (is_expired(lifetime))
        return NULL;

    // 解密 session state
    uint8_t plain[1024];
    size_t plain_len = tls_gcm_decrypt(ctx->ticket_cipher->key, nonce,
                                       encrypted, enc_len, plain);

    // 反序列化
    struct tls_session *sess = tls_session_state_deserialize(plain);

    // 更新序列号 (TLS 1.3)
    sess->client_seq = 0;
    sess->server_seq = 0;

    // 重新派生 traffic keys
    tls13_derive_keys(sess);

    return sess;
}

// Session 查找
struct tls_session *
tls_session_lookup(struct tls_context *ctx,
                    const uint8_t *session_id, uint8_t len)
{
    return rte_hash_lookup_data(ctx->session_store->session_by_id,
                                 session_id);
}
```

---

## 5. TLS/DTLS 加速架构

### 5.1 加速架构设计

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        TLS/DTLS 加速架构                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌──────────────────────────────────────────────────────────────────────┐ │
│  │                     Application                                       │ │
│  │  ┌────────────────┐  ┌────────────────┐  ┌────────────────┐          │ │
│  │  │  HTTPS Server  │  │   TLS Proxy    │  │ DTLS VPN       │          │ │
│  │  └───────┬────────┘  └───────┬────────┘  └───────┬────────┘          │ │
│  └──────────┼───────────────────┼───────────────────┼───────────────────┘ │
│             │                   │                   │                      │
│  ┌──────────┼───────────────────┼───────────────────┼───────────────────┐ │
│  │          ▼                   ▼                   ▼                    │ │
│  │   ┌─────────────────────────────────────────────────────────────┐     │ │
│  │   │              DPDK TLS/DTLS Stack                            │     │ │
│  │   │  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐    │     │ │
│  │   │  │ Handshake│  │  Record  │  │ Session  │  │   X509   │    │     │ │
│  │   │  │  Engine  │  │  Layer   │  │  Store   │  │   Cert   │    │     │ │
│  │   │  └──────────┘  └──────────┘  └──────────┘  └──────────┘    │     │ │
│  │   │                                                              │     │ │
│  │   │  ┌──────────────────────────────────────────────────────┐   │     │ │
│  │   │  │           Crypto Operations                          │   │     │ │
│  │   │  │   AEAD (AES-GCM) │ CBC │ ChaCha20-Poly1305         │   │     │ │
│  │   │  └──────────────────────────────────────────────────────┘   │     │ │
│  │   │                                                              │     │ │
│  │   └───────────────────────────────────────────────────────────────┘     │ │
│  │                                  │                                       │ │
│  └──────────────────────────────────┼───────────────────────────────────────┘ │
│                                     ▼                                          │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │                     cryptodev / Crypto PMD                           │ │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐    │ │
│  │  │  QAT   │  │AESNI-MB │  │OpenSSL │  │   DSW   │  │ ARMv8   │    │ │
│  │  └─────────┘  └─────────┘  └─────────┘  └─────────┘  └─────────┘    │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 5.2 数据面与控制面分离

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    TLS 数据面与控制面分离                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  控制面 (Control Plane):                                                   │
│  ───────────────────────                                                   │
│  - TLS 握手协议处理                                                         │
│  - Session 建立/恢复                                                        │
│  - 证书验证                                                                 │
│  - 密钥交换 (ECDH/RSA)                                                     │
│  - Session Ticket 加解密                                                   │
│  - 频率较低，延迟不敏感                                                     │
│  - 可在 CPU 处理                                                           │
│                                                                             │
│  数据面 (Data Plane):                                                     │
│  ───────────────────                                                       │
│  - TLS Record 加密/解密                                                    │
│  - Application Data 处理                                                   │
│  - 序列号维护                                                               │
│  - 频率极高，延迟敏感                                                        │
│  - 可卸载到 Crypto PMD                                                     │
│                                                                             │
│  ┌──────────────────────────────────────────────────────────────────────┐ │
│  │                        控制面                                         │ │
│  │  ┌────────────┐  ┌────────────┐  ┌────────────┐                     │ │
│  │  │ 握手处理   │  │ Session 管理│  │ 证书验证   │                     │ │
│  │  │ (OpenSSL) │  │            │  │ (X509_store)│                    │ │
│  │  └─────┬──────┘  └─────┬──────┘  └─────┬──────┘                     │ │
│  └────────┼────────────────┼────────────────┼────────────────────────┘ │
│           │                │                │                              │
│           │ 密钥材料        │ Session State  │ 证书                        │
│           ▼                ▼                ▼                              │
│  ┌──────────────────────────────────────────────────────────────────────┐ │
│  │                     数据面 (DPDK)                                    │ │
│  │  ┌────────────┐  ┌────────────┐  ┌────────────┐                   │ │
│  │  │ Record 加密 │  │  Session    │  │ 密钥材料    │                   │ │
│  │  │ (cryptodev)│  │  (mbuf)    │  │ (DMA)      │                   │ │
│  │  └────────────┘  └────────────┘  └────────────┘                   │ │
│  └──────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 6. TLS 记录层实现

### 6.1 TLS Context

```c
// TLS Context (每个连接一个)
struct tls_context {
    // 协议版本
    uint16_t version;

    // 密码套件
    uint16_t cipher_suite;
    const struct tls_cipher_suite *cipher;

    // Crypto session
    void *crypto_session;
    uint8_t crypto_dev_id;

    // Session
    struct tls_session *session;
    struct tls_session_store *session_store;

    // Traffic keys
    uint8_t client_write_key[32];
    uint8_t server_write_key[32];
    uint8_t client_write_iv[12];
    uint8_t server_write_iv[12];

    // 序列号
    uint64_t client_seq;
    uint64_t server_seq;

    // 状态机
    enum tls_state {
        TLS_STATE_INIT = 0,
        TLS_STATE_HANDSHAKE,
        TLS_STATE_ESTABLISHED,
        TLS_STATE_CLOSING,
        TLS_STATE_CLOSED,
    } state;

    // DTLS 特定
    uint16_t epoch;              // 当前时期
    uint8_t cookie[32];         // DTLS cookie
};

// TLS 1.3 Context 扩展
struct tls13_context {
    // TLS 1.3 密钥派生
    uint8_t early_secret[32];    // Early data secret
    uint8_t binder_key[32];      // Early data binder key

    uint8_t handshake_secret[32];
    uint8_t master_secret[48];

    uint8_t client_handshake_secret[32];
    uint8_t server_handshake_secret[32];

    uint8_t client_traffic_secret[32];
    uint8_t server_traffic_secret[32];

    uint8_t exporter_master_secret[48];
    uint8_t resumption_master_secret[48];

    // 0-RTT
    int early_data_accepted;
    uint8_t early_data_secret[32];
};
```

### 6.2 TLS 加密操作

```c
// TLS 记录加密 (数据面热点)

static inline int
tls_record_encrypt(struct tls_context *ctx,
                    uint8_t content_type,
                    const uint8_t *plaintext, size_t pt_len,
                    uint8_t *ciphertext, size_t *ct_len)
{
    uint64_t seq = ctx->client_seq++;
    uint8_t nonce[12];
    uint8_t aad[5];

    // 构建 Nonce (TLS 1.2 GCM)
    // IV = implicit_iv (4 bytes) || explicit_iv (8 bytes)
    memcpy(nonce, ctx->client_write_iv, 4);
    encode_be64(nonce + 4, seq);

    // 构建 AAD
    aad[0] = content_type;
    aad[1] = (ctx->version >> 8) & 0xFF;
    aad[2] = ctx->version & 0xFF;
    aad[3] = (pt_len >> 8) & 0xFF;
    aad[4] = pt_len & 0xFF;

    // 调用 cryptodev
    struct rte_crypto_op *op;
    struct rte_crypto_sym_op *sym_op;

    op = rte_crypto_op_alloc(ctx->op_mpool,
                              RTE_CRYPTO_OP_TYPE_SYMMETRIC);
    sym_op = op->sym;

    // 设置加密参数
    sym_op->aead.src.offset = 0;
    sym_op->aead.src.length = pt_len;
    sym_op->aead.digest = ciphertext + 5 + pt_len;  // tag 位置
    sym_op->aead.digest_len = 16;

    // 发送并等待
    rte_cryptodev_enqueue_burst(ctx->crypto_dev_id, 0, &op, 1);
    rte_cryptodev_dequeue_burst(ctx->crypto_dev_id, 0, &op, 1);

    // 写入 record 头
    ciphertext[0] = content_type;
    ciphertext[1] = (ctx->version >> 8) & 0xFF;
    ciphertext[2] = ctx->version & 0xFF;
    ciphertext[3] = (pt_len >> 8) & 0xFF;
    ciphertext[4] = pt_len & 0xFF;

    // Nonce 放在密文前 (TLS 1.2)
    memcpy(ciphertext + 5, nonce, 8);

    *ct_len = pt_len + 5 + 8 + 16;  // header + nonce + ciphertext + tag

    return 0;
}
```

### 6.3 TLS/DTLS 批量处理

```c
// TLS 批量加密 (优化数据面吞吐)

// 批量 TLS 记录加密
static inline uint16_t
tls_encrypt_batch(struct tls_context *ctx,
                  struct rte_mbuf **pkts_in,
                  struct rte_mbuf **pkts_out,
                  uint16_t nb_pkts)
{
    struct rte_crypto_op *ops[32];
    uint16_t i;

    // 准备批量操作
    for (i = 0; i < nb_pkts && i < 32; i++) {
        struct rte_mbuf *m = pkts_in[i];

        ops[i] = rte_crypto_op_alloc(ctx->op_mpool,
                                      RTE_CRYPTO_OP_TYPE_SYMMETRIC);

        // 设置参数
        setup_aead_op(ops[i], m, ctx);

        // 绑定 mbuf
        ops[i]->m_src = m;
    }

    // 批量入队
    uint16_t nb_enq = rte_cryptodev_enqueue_burst(ctx->crypto_dev_id,
                                                    0, ops, i);

    // 批量出队
    uint16_t nb_deq = rte_cryptodev_dequeue_burst(ctx->crypto_dev_id,
                                                   0, ops, nb_enq);

    // 处理完成的操作
    for (i = 0; i < nb_deq; i++) {
        if (ops[i]->status == RTE_CRYPTO_OP_STATUS_SUCCESS) {
            pkts_out[i] = ops[i]->m_src;
        } else {
            // 错误处理
            rte_pktmbuf_free(ops[i]->m_src);
            pkts_out[i] = NULL;
        }

        rte_crypto_op_free(ops[i]);
    }

    return nb_deq;
}

// DTLS 批量处理 (带序列号管理)
static inline uint16_t
dtls_encrypt_batch(struct dtls_context *ctx,
                    struct rte_mbuf **pkts_in,
                    struct rte_mbuf **pkts_out,
                    uint16_t nb_pkts)
{
    uint16_t i, j;

    // 按 epoch 分组
    struct rte_mbuf *group_by_epoch[2][32];
    uint16_t nb_epoch[2] = {0, 0};

    for (i = 0; i < nb_pkts; i++) {
        uint16_t epoch = ctx->epoch;
        if (epoch < 2)
            group_by_epoch[epoch][nb_epoch[epoch]++] = pkts_in[i];
    }

    // 分别处理每个 epoch
    for (j = 0; j < 2; j++) {
        if (nb_epoch[j] > 0) {
            tls_encrypt_batch(ctx, group_by_epoch[j],
                              &pkts_out[nb_deq], nb_epoch[j]);
        }
    }

    return nb_deq;
}
```

---

## 7. OpenSSL 集成

### 7.1 OpenSSL Engine

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        OpenSSL Engine 架构                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  OpenSSL 标准流程:                                                         │
│  ─────────────────                                                         │
│  Application ──► OpenSSL libssl ──► Software Crypto (AES-NI)              │
│                                                                             │
│  OpenSSL Engine 流程:                                                     │
│  ─────────────────────                                                     │
│  Application ──► OpenSSL libssl ──► Engine ──► DPDK cryptodev           │
│                                                    │                       │
│                                                    ▼                       │
│                                              QAT/AESNI-MB                  │
│                                                                             │
│  Engine API:                                                               │
│  ──────────                                                                │
│  ENGINE_load_builtin_engines();                                            │
│  ENGINE_load_dynamic();                                                    │
│  ENGINE *e = ENGINE_by_id("dpdk");                                        │
│  ENGINE_init(e);                                                           │
│  EVP_PKEY *pkey = ENGINE_load_private_key(e, " DPDK:0", ...);            │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 7.2 OpenSSL + DPDK Engine

```c
// OpenSSL Engine 实现 (伪代码)

// Engine 初始化
static int
dpdk_engine_init(ENGINE *e)
{
    // 初始化 DPDK EAL
    static char *dpdk_args[] = {
        "dpdk",
        "-l", "0-3",
        "--master-lcore", "0",
    };

    rte_eal_init(4, dpdk_args);

    // 初始化 cryptodev
    uint8_t crypto_dev = rte_cryptodev_get_dev_id("crypto_qat");
    rte_cryptodev_configure(crypto_dev, &conf);
    rte_cryptodev_start(crypto_dev);

    return 1;
}

// 密码方法
static const EVP_CIPHER *dpdk_get_cipher(int nid, int key_len)
{
    if (nid == NID_aes_256_gcm && key_len == 32)
        return &dpdk_aes_256_gcm;
    return NULL;
}

// 摘要方法
static const EVP_MD *dpdk_get_digest(int nid)
{
    if (nid == NID_sha256)
        return &dpdk_sha256;
    return NULL;
}

// 密钥导出
static int
dpdk_load_private_key(ENGINE *e, const char *key_id,
                       UI_METHOD *ui_method, void *callback_data)
{
    // 使用 DPDK 处理 RSA/ECDH 私钥操作
    return dpdk_pkey_method_new(key_id);
}

// Engine 命令
static int
dpdk_engine_ctrl(ENGINE *e, int cmd, long i, void *p, void (*f)())
{
    switch (cmd) {
    case DPDK_CMD_CRYPTO_DEV:
        // 设置 cryptodev ID
        return 1;
    case DPDK_CMD_QUEUE_PAIR:
        // 设置队列对
        return 1;
    }
    return 0;
}

// 注册 Engine
static int
bind_helper(ENGINE *e)
{
    if (!ENGINE_set_id(e, "dpdk") ||
        !ENGINE_set_destroy_function(e, dpdk_engine_destroy) ||
        !ENGINE_set_init_function(e, dpdk_engine_init) ||
        !ENGINE_set_ciphers(e, dpdk_get_cipher) ||
        !ENGINE_set_digests(e, dpdk_get_digest) ||
        !ENGINE_set_load_privkey_function(e, dpdk_load_private_key) ||
        !ENGINE_set_ctrl_function(e, dpdk_engine_ctrl)) {
        return 0;
    }

    return 1;
}
```

---

## 8. 完整使用示例

### 8.1 TLS Proxy

```c
// TLS Proxy 示例 (终止 TLS，转发明文)

// TLS Proxy 配置
struct tls_proxy_config {
    uint16_t listen_port;           // 监听端口 (TLS)
    uint16_t backend_port;          // 后端端口 (明文)
    uint32_t backend_ip;            // 后端 IP

    uint8_t crypto_dev_id;         // Crypto 设备
    struct tls_session_store *session_store;

    uint8_t *cert_file;            // 证书
    uint8_t *key_file;             // 私钥
};

// TLS Proxy 处理
struct tls_proxy {
    struct tls_proxy_config config;

    struct rte_ring *tx_ring;      // 发送队列
    struct rte_mempool *crypto_op_pool;
    struct rte_mempool *mbuf_pool;
};

int
tls_proxy_init(struct tls_proxy *proxy)
{
    // 初始化 cryptodev
    rte_cryptodev_configure(proxy->config.crypto_dev_id,
                             &(struct rte_cryptodev_config){
                                .socket_id = 0,
                                .max_nb_queue_pairs = 4,
                                .max_nb_sessions = 16384,
                             });

    // 创建 session store
    proxy->config.session_store = tls_session_store_create(
        16384,  /* max sessions */
        4096   /* max session size */
    );

    // 创建 mbuf pool
    proxy->mbuf_pool = rte_pktmbuf_pool_create(
        "tls_proxy_mbuf",
        8192,
        256,
        0,
        RTE_MBUF_DEFAULT_BUF_SIZE,
        SOCKET_ID_ANY);

    // 创建 crypto op pool
    proxy->crypto_op_pool = rte_crypto_op_pool_create(
        "tls_proxy_crypto",
        RTE_CRYPTO_OP_TYPE_SYMMETRIC,
        4096, 64, 0,
        SOCKET_ID_ANY);

    return 0;
}

// TLS 终止处理
static void
tls_terminate(struct tls_proxy *proxy,
              struct rte_mbuf *pkt,
              struct tls_context **ctx_out)
{
    // 解析 TLS Record
    struct tls_record_header hdr;
    if (tls_record_parse(rte_pktmbuf_mtod(pkt, uint8_t *),
                          rte_pktmbuf_pkt_len(pkt),
                          &hdr, &rec_len) < 0) {
        // 错误
        return;
    }

    if (hdr.type == TLS_HANDSHAKE) {
        // 握手处理
        struct tls_handshake_hdr *hs = (void *)(hdr + 1);

        switch (hs->msg_type) {
        case TLS_HANDSHAKE_CLIENT_HELLO:
            // 处理 ClientHello
            handle_client_hello(proxy, pkt);
            break;

        case TLS_HANDSHAKE_FINISHED:
            // 握手完成
            handle_finished(proxy, pkt);
            break;
        }
    } else if (hdr.type == TLS_APPLICATION_DATA) {
        // 应用数据，解密
        struct tls_context *ctx = proxy->current_ctx;

        // 解密
        uint8_t *plaintext = tls_record_decrypt(ctx, hdr.payload);

        // 发送到后端
        send_to_backend(proxy, plaintext, pt_len);
    }
}

// 主循环
int
tls_proxy_run(struct tls_proxy *proxy)
{
    struct rte_mbuf *pkts[MAX_PKT_BURST];
    struct tls_context *ctx;

    while (!quit) {
        // 接收 TLS 连接
        uint16_t nb_rx = rte_eth_rx_burst(proxy->port_id, 0,
                                           pkts, MAX_PKT_BURST);

        for (uint16_t i = 0; i < nb_rx; i++) {
            tls_terminate(proxy, pkts[i], &ctx);

            // 更新统计
            proxy->stats.pkts++;
            proxy->stats.bytes += rte_pktmbuf_pkt_len(pkts[i]);
        }

        // 处理后端响应
        // ...

        // 加密并发送
        if (proxy->tx_count > 0) {
            tls_encrypt_batch(proxy->current_ctx,
                              proxy->tx_pkts,
                              proxy->tx_pkts,
                              proxy->tx_count);
            rte_eth_tx_burst(proxy->port_id, 0,
                            proxy->tx_pkts, proxy->tx_count);
        }
    }
}
```

---

## 9. 性能与优化

### 9.1 TLS 性能数据

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        TLS 性能对比                                        │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  AES-256-GCM, TLS 1.3, 1514B MTU                                          │
│                                                                             │
│  方案                  吞吐量        CPU 利用率    连接数/秒                │
│  ──────────────────────────────────────────────────────────────────────── │
│  OpenSSL (1 core)      1.5 Gbps        100%         15,000               │
│  AESNI-MB (1 core)     8 Gbps          80%          80,000               │
│  QAT (1x40GbE)        25 Gbps          15%         200,000               │
│  QAT (2x40GbE)        50 Gbps          10%         400,000               │
│  HW TLS (IPU)         100 Gbps         5%         1,000,000              │
│                                                                             │
│  TLS Handshake:                                                         │
│  ──────────────                                                          │
│  Full Handshake (RSA):    ~150ms (软件)                                  │
│  Full Handshake (ECDHE):  ~50ms (软件)                                    │
│  Session Resumption:        ~5ms                                          │
│  0-RTT (TLS 1.3):           ~1ms (有重放风险)                            │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 9.2 优化建议

| 优化项 | 说明 | 效果 |
|--------|------|------|
| **Session Resumption** | 复用 session 避免完整握手 | 30x 降低延迟 |
| **Session Ticket** | 分布式 session 存储 | 无状态扩展 |
| **批量加密** | 批量处理记录层 | 3-5x 提升吞吐 |
| **硬件卸载** | QAT/IPU 加速 | 10x+ 提升 |
| **数据面/控制面分离** | 握手在 CPU，加密在硬件 | 最佳效率 |
| **Early Data (0-RTT)** | TLS 1.3 0-RTT | 首个请求无延迟 |

---

## 10. 小结

本章核心要点：

1. **TLS vs IPsec**：TLS 工作在应用层 (TCP 和 HTTP 之间)，对应用透明；IPsec 工作在网络层，保护整个 IP 包。

2. **TLS 1.2 vs 1.3**：1.3 将握手从 2-RTT 降为 1-RTT (0-RTT 可选)，移除 CBC+HMAC，仅保留 AEAD。

3. **DTLS**：基于 UDP 的 TLS，处理包丢失、乱序、重排序，加入 Cookie 交换和重传机制。

4. **TLS 记录层**：5 字节头 (type+version+length) + AEAD 加密，序列号隐式或显式。

5. **TLS 握手**：ClientHello/ServerHello → Certificate → KeyExchange → Finished。

6. **Session Resumption**：Session ID 或 Session Ticket 机制，避免完整握手，降低延迟。

7. **Session Ticket**：加密的 session state，可存储在外部，支持无状态恢复。

8. **加速架构**：控制面处理握手，数据面处理记录层加密，分离效率。

9. **OpenSSL Engine**：通过 Engine 接口将 DPDK cryptodev 集成到 OpenSSL。

10. **性能**：QAT 可达 50 Gbps，硬件 IPU 可达 100 Gbps，Session Resumption 可降低 30x 延迟。

**下一篇预告**：[[2026-04-09-dpdk-deep-dive-ch24-raw-crypto-api|第二十四章]]将讲解 Raw Crypto API 与自定义协议加密——灵活加密接口设计。

---

> [!tip] 参考文献
> - RFC 5246, "TLS 1.2"
> - RFC 8446, "TLS 1.3"
> - RFC 6347, "DTLS 1.2"
> - RFC 9009, "DTLS 1.3"
> - Intel, "DPDK Cryptodev", https://doc.dpdk.org/guides/prog_guide/cryptodev.html
> - "OpenSSL Engine", https://www.openssl.org/docs/man1.1.1/man3/ENGINE_add.html
