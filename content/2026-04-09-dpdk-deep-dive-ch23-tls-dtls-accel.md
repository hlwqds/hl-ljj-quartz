---
title: "DPDK 深度探索 (二十三)：TLS/DTLS 加速与 Session 管理"
date: 2026-04-09
tags: [dpdk, series, tls, dtls, ssl, session, crypto, tls-record, handshake, security]
description: "深入理解 TLS/DTLS 协议与 DPDK 加速——记录层、握手流程、session 管理、rte_security TLS Record 卸载、Crypto 数据面与控制面分离"
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
│  │  (Network Layer)     │    │  (Transport Layer)  │                      │
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
│  - 典型应用: VoIP、WebRTC、VPN-over-UDP                                   │
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
│  │  3. 消息分片与重组 (Message Fragmentation)                           │ │
│  │     超大握手消息可以分片传输，接收端按偏移重组                        │ │
│  │                                                                      │ │
│  │  4. Epoch 机制                                                       │ │
│  │     每次 rekeying 切换 epoch，新旧 epoch 有独立序列号空间            │ │
│  │     丢弃旧 epoch 的记录（除重传窗口内的包）                          │ │
│  └─────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. TLS 记录层协议

### 2.1 TLS Record 格式

DPDK 在 `lib/net/rte_tls.h` 和 `lib/net/rte_dtls.h` 中定义了记录层头结构：

```c
// DPDK: lib/net/rte_tls.h
#define RTE_TLS_TYPE_CHANGE_CIPHER_SPEC  20
#define RTE_TLS_TYPE_ALERT               21
#define RTE_TLS_TYPE_HANDSHAKE           22
#define RTE_TLS_TYPE_APPDATA             23
#define RTE_TLS_TYPE_HEARTBEAT           24  // TLS 1.3

#define RTE_TLS_VERSION_1_2    0x0303
#define RTE_TLS_VERSION_1_3    0x0304

struct rte_tls_hdr {
    uint8_t type;           // Content Type (RTE_TLS_TYPE_*)
    rte_be16_t version;     // TLS Version
    rte_be16_t length;      // Payload length (最大 16384 = 2^14)
} __rte_packed;             // 总计 5 字节

// DPDK: lib/net/rte_dtls.h
#define RTE_DTLS_VERSION_1_2    0xFEFD  // 1.2 的按位取反
#define RTE_DTLS_VERSION_1_3    0xFEFC  // 1.3 的按位取反

struct rte_dtls_hdr {
    uint8_t type;           // Content Type (RTE_DTLS_TYPE_*)
    rte_be16_t version;     // DTLS Version
    uint16_t epoch;         // 计数器，每次 cipher state 变更时递增
    uint48_t sequence_number; // 48-bit 显式序列号
    rte_be16_t length;      // Payload length
} __rte_packed;             // 总计 13 字节
```

> [!note] TLS vs DTLS 记录头
> TLS 记录头 5 字节，DTLS 记录头 13 字节。DTLS 多了 epoch (2B) 和 sequence_number (6B)，
> 因为 UDP 没有可靠传输保证，需要显式序列号来处理乱序和重放。

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
│  │  + write_IV (4 bytes implicit, 来自 key material 派生)               │ │
│  │  + Sequence Number (64-bit, big-endian)                              │ │
│  │  ─────────────────────────────────────────────────────────────────── │ │
│  │  Nonce = write_IV[0..3] || seq_num[0..7]  (共 12 bytes)            │ │
│  │  ─────────────────────────────────────────────────────────────────── │ │
│  │  AAD (Additional Authenticated Data):                                │ │
│  │  [type(1)] [version(2)] [length(2)]  = 5 bytes                      │ │
│  │  ─────────────────────────────────────────────────────────────────── │ │
│  │  Output:  [Explicit IV (8 bytes)] [Ciphertext] [Tag (16 bytes)]      │ │
│  └──────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
│  TLS 1.3 AEAD:                                                            │
│  ─────────────────                                                        │
│                                                                             │
│  ┌──────────────────────────────────────────────────────────────────────┐ │
│  │  Key: traffic secret 派生的对称密钥                                   │ │
│  │  Nonce: explicit part (8 bytes) = seq_num XOR implicit_nonce         │ │
│  │  AAD: same as TLS 1.2                                                │ │
│  │  Tag: 16 bytes                                                       │ │
│  │  Record Layer 版本号固定为 0x0303 (TLS 1.2，兼容性)                   │ │
│  │  Content Type 被移入加密内部 (inner plaintext 末尾)                   │ │
│  └──────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
│  TLS 1.2 CBC+HMAC:                                                        │
│  ────────────────────                                                     │
│                                                                             │
│  ┌──────────────────────────────────────────────────────────────────────┐ │
│  │  mac = HMAC(mac_key, seq_num || type || version || length || pt)    │ │
│  │  pad = PKCS7_padding                                                │ │
│  │  plaintext = data || mac || pad                                     │ │
│  │  ciphertext = IV || AES-CBC(cipher_key, plaintext)                  │ │
│  └──────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
│  TLS 1.2 vs 1.3 记录层区别:                                               │
│  ──────────────────────────                                               │
│  ┌──────────────────────────┬──────────────────────────────────────────┐  │
│  │  TLS 1.2                  │  TLS 1.3                                 │  │
│  ├──────────────────────────┼──────────────────────────────────────────┤  │
│  │  IV: 4B implicit +       │  Nonce: 12B, seq_num XOR                │  │
│  │       8B explicit        │          implicit_nonce                   │  │
│  │  支持 AEAD + CBC+HMAC    │  仅支持 AEAD                             │  │
│  │  Content Type 在明文头   │  Content Type 在密文内部                  │  │
│  │  版本号: 实际版本        │  版本号: 固定 0x0303                     │  │
│  └──────────────────────────┴──────────────────────────────────────────┘  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

> [!important] TLS 1.2 vs 1.3 记录层关键区别
> - TLS 1.2 的 IV 来自 key material 派生的 `write_IV`（不是 "traffic secret"——那是 TLS 1.3 的概念）
> - TLS 1.3 将 Content Type 移入密文内部（作为 inner plaintext 末尾字节），外部 Content Type 固定为 23 (application_data)
> - TLS 1.3 Record Layer 版本号固定写 `0x0303`（TLS 1.2），不再写实际版本号

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
│    │  ┌─────────────────────────┐  │                                         │
│    │  │ 双方计算 Pre-Master     │  │                                         │
│    │  │ Secret → Master Secret  │  │                                         │
│    │  │ → 派生所有 traffic keys │  │                                         │
│    │  └─────────────────────────┘  │                                         │
│    │                               │                                         │
│    │──── ClientKeyExchange ───────►│  预主密钥 (RSA 加密 或 DH 客户端参数)   │
│    │      (PremasterSecret)        │                                         │
│    │                               │                                         │
│    │──── ChangeCipherSpec ───────►│  通知切换到新密钥加密                   │
│    │──── [Encrypted] Finished ───►│  握手摘要验证 (用新密钥加密)            │
│    │                               │                                         │
│    │◄─── ChangeCipherSpec ─────────│  通知切换到新密钥加密                   │
│    │◄─── [Encrypted] Finished ─────│  握手摘要验证 (用新密钥加密)            │
│    │                               │                                         │
│    │══════ Application Data ══════│  使用 traffic keys 加密通信              │
│    │══════ (加密通道) ═════════════│                                         │
│    │                               │                                         │
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
│    │──── ClientHello ─────────────►│  supported_versions + key_share       │
│    │      + key_share (DH/PQC)     │  + supported_groups                   │
│    │                               │                                         │
│    │                         ┌─────┴─────┐                                  │
│    │                         │ 计算 Early   │                               │
│    │                         │ Secret      │                               │
│    │                         └─────┬─────┘                                  │
│    │                               │                                         │
│    │◄── ServerHello ───────────────│  selected_version + key_share          │
│    │      + key_share              │                                         │
│    │                               │  ┌──────────────────────────────┐      │
│    │                               │  │ 计算 Handshake Secret        │      │
│    │                               │  │ 派生 server_handshake_traffic │      │
│    │                               │  └──────────────────────────────┘      │
│    │◄── {EncryptedExtensions} ─────│  (用 server_hs_traffic key 加密)      │
│    │◄── {CertificateRequest} ──────│  (可选) 要求证书                       │
│    │◄── {server Certificate} ──────│                                         │
│    │◄── {server CertificateVerify} │                                         │
│    │◄── {server Finished} ─────────│                                         │
│    │                               │                                         │
│    │  ┌─────────────────────────┐  │                                         │
│    │  │ 计算 Master Secret      │  │                                         │
│    │  │ 派生 client/server      │  │                                         │
│    │  │ application_traffic_0   │  │                                         │
│    │  └─────────────────────────┘  │                                         │
│    │                               │                                         │
│    │──── {Certificate} ────────────►│  (可选) 客户端证书                     │
│    │──── {CertificateVerify} ─────►│                                         │
│    │──── {Finished} ──────────────►│                                         │
│    │                               │                                         │
│    │  ┌─────────────────────────┐  │                                         │
│    │  │ 派生 application        │  │                                         │
│    │  │ traffic_secret_1 (N+1) │  │                                         │
│    │  └─────────────────────────┘  │                                         │
│    │                               │                                         │
│    │══════ Application Data ══════│  使用 application_traffic_secret_N      │
│    │══════ (加密通道) ═════════════│                                         │
│    │                               │                                         │
│  TLS 1.3 密钥派生链:                                                       │
│  ───────────────────                                                       │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  Early Secret (0-RTT 可选)                                          │   │
│  │       │ HKDF-Extract + Derive-Secret                                │   │
│  │       ▼                                                             │   │
│  │  Handshake Secret  ← 在收到 ServerHello 后计算                      │   │
│  │       │ HKDF-Extract + Derive-Secret                                │   │
│  │       ├─► client/server_handshake_traffic_secret                    │   │
│  │       ▼                                                             │   │
│  │  Master Secret     ← 在收到 server Finished 后计算                  │   │
│  │       │ HKDF-Extract + Derive-Secret                                │   │
│  │       ├─► client/server_application_traffic_secret_0                │   │
│  │       ├─► resumption_master_secret (用于后续恢复)                   │   │
│  │       └─► exporter_master_secret                                    │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  TLS 1.3 改进:                                                             │
│  - 1-RTT (之前 2-RTT)                                                    │
│  - 0-RTT (Early Data, 但有重放风险)                                        │
│  - 前向保密 (必须使用 ECDHE/PQC)                                           │
│  - 移除 CBC+HMAC (仅 AEAD)                                                │
│  - 简化密码套件命名                                                        │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 3.3 握手消息结构

```c
// TLS Handshake 消息头 (概念结构，非 DPDK API)
// 注意: length 是 3 字节 (uint24)，C 语言中没有原生 uint24 类型

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

// Finished 消息 (verify_data 长度取决于哈希算法)
// SHA-256: 32 bytes → 截断为 12 bytes
// SHA-384: 48 bytes → 截断为 12 bytes
struct tls_finished {
    uint8_t verify_data[12];
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
│                (TLS 1.2: 2-RTT, TLS 1.3: 1-RTT)                          │
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
│                (客户端保存 ticket)                                          │
│                                                                             │
│  后续握手:                                                                 │
│  ClientHello(session_ticket=ticket) ──►                                   │
│                                    ◄── Finished                             │
│                (1-RTT, 无需发送证书)                                        │
│                                                                             │
│  0-RTT (TLS 1.3):                                                         │
│  ─────────────────                                                         │
│  ClientHello + EarlyData ──►  (使用之前保存的 PSK)                        │
│                            ◄── ServerHello + Finished                     │
│  (0-RTT，但服务端可能拒绝并回退到完整握手)                                 │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 4.2 Session State 结构

```c
// TLS Session 状态 (概念结构，非 DPDK API)
struct tls_session_state {
    // 协议版本
    uint16_t version;

    // 密码套件
    uint16_t cipher_suite;

    // Master Secret
    uint8_t master_secret[48];  // TLS 1.2: PRF 输出固定 48 字节

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

    // 序列号
    uint64_t client_seq;
    uint64_t server_seq;

    // 过期时间
    uint64_t expire_time;

    // TLS 1.3 扩展状态 (均为 32 字节，HKDF 输出)
    uint8_t early_secret[32];
    uint8_t handshake_secret[32];
    uint8_t master_secret_tls13[32];    // TLS 1.3 master secret = 32 bytes
    uint8_t resumption_master_secret[32];
};

// Session Ticket (加密的 session state)
// 格式由 RFC 5077 / TLS 1.3 定义
struct tls_session_ticket {
    uint8_t ticket_lifetime[4];     // 生命周期 (秒)
    uint8_t ticket_age_add[4];     // 用于计算 obfuscated ticket age
    uint8_t ticket_nonce[32];     // 服务器提供的 nonce
    uint8_t ticket[];             // 加密的 session state
    // 加密方式: AES-GCM(ticket_key, nonce, session_state)
};
```

> [!warning] TLS 1.2 vs 1.3 Master Secret 大小
> - TLS 1.2: `master_secret` 固定 48 字节（PRF 输出）
> - TLS 1.3: `master_secret` 32 字节（HKDF-Extract 输出）

### 4.3 DPDK 环境下的 Session 管理

DPDK 本身不提供 TLS Session 管理 API。应用需要自行实现 session 的
创建、查找、恢复逻辑。典型做法是用 `rte_hash` 或 `rte_ring` 构建 session 缓存：

```c
// === 应用层 Session 管理 (非 DPDK 内置 API，仅供参考) ===

// Session 查找示例 — 使用 rte_hash
// rte_hash_lookup_data 返回 key 的位置索引 (int32_t)，不是直接返回指针
int32_t pos = rte_hash_lookup_data(hash, session_id, (void **)&sess);
if (pos < 0) {
    // session 不存在，需要完整握手
}

// Session 缓存管理
struct session_cache {
    struct rte_hash *by_id;       // session_id → session_state
    struct rte_ring *lru_ring;    // LRU 淘汰队列
    size_t max_sessions;
};
```

> [!note] DPDK 不提供 TLS Session API
> 与 IPsec SA（`rte_ipsec_sa`）不同，DPDK 没有内置的 TLS Session 管理。
> 所有 TLS session 逻辑需要应用自行实现。DPDK 提供的只是：
> - `rte_hash` / `rte_ring` 等通用数据结构用于构建 session 缓存
> - `rte_cryptodev` 用于加速加密运算
> - `rte_security` (部分硬件) 用于 TLS Record 卸载

---

## 5. TLS/DTLS 加速架构

### 5.1 DPDK 提供的 TLS 加速能力

> [!important] DPDK 没有内置 TLS/DTLS 协议栈
> DPDK **不**提供完整的 TLS/DTLS 协议实现。DPDK 只提供三个层次的加速接口：
> 1. **Cryptodev**：加密算法加速（AES-GCM、ChaCha20 等）
> 2. **rte_security TLS Record**：TLS 记录层卸载（部分硬件支持）
> 3. **OpenSSL PMD**：用 OpenSSL 做软件加密的 PMD 驱动

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    DPDK TLS 加速三层架构                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  应用层 (用户实现):                                                        │
│  ──────────────────                                                        │
│  ┌──────────────────────────────────────────────────────────────────────┐ │
│  │                    TLS 协议栈 (用户实现)                             │ │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐            │ │
│  │  │ Handshake│  │  Record  │  │ Session  │  │   X509   │            │ │
│  │  │  Engine  │  │  Layer   │  │  Store   │  │   Cert   │            │ │
│  │  └────┬─────┘  └────┬─────┘  └──────────┘  └──────────┘            │ │
│  │       │             │                                                 │ │
│  │       │ 握手密钥    │ Record 加解密                                   │ │
│  │       │             │                                                 │ │
│  │  ┌────┴─────────────┴────────────────────────────────────────────┐   │ │
│  │  │              两种加速路径 (二选一)                             │   │ │
│  │  │                                                              │   │ │
│  │  │  路径 A: rte_security TLS Record (硬件卸载)                   │   │ │
│  │  │  ┌──────────────────────────────────────────────────────┐     │   │ │
│  │  │  │ rte_security_session_create()                        │     │   │ │
│  │  │  │ → RTE_SECURITY_PROTOCOL_TLS_RECORD                   │     │   │ │
│  │  │  │ → 硬件自动处理: 加密/解密/序列号/IV                    │     │   │ │
│  │  │  │ → 支持设备: Marvell CN10K 等                          │     │   │ │
│  │  │  └──────────────────────────────────────────────────────┘     │   │ │
│  │  │                                                              │   │ │
│  │  │  路径 B: rte_cryptodev (仅加密加速)                         │   │ │
│  │  │  ┌──────────────────────────────────────────────────────┐     │   │ │
│  │  │  │ rte_crypto_op + AEAD                                   │     │   │ │
│  │  │  │ → 仅加速加密/解密运算                                  │     │   │ │
│  │  │  │ → 应用自己管理: 序列号/IV/Record 拼装                  │     │   │ │
│  │  │  │ → 支持设备: QAT/AESNI-MB/OpenSSL PMD/ARMv8 等          │     │   │ │
│  │  │  └──────────────────────────────────────────────────────┘     │   │ │
│  │  └──────────────────────────────────────────────────────────────┘   │ │
│  └──────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
│  DPDK 层:                                                                  │
│  ─────────                                                               │
│  ┌──────────────────────────────────────────────────────────────────────┐ │
│  │  ┌─────────────────────────────────┐  ┌─────────────────────────┐   │ │
│  │  │  rte_security (TLS Record)      │  │  rte_cryptodev           │   │ │
│  │  │  仅 Record 层卸载               │  │  通用加密加速            │   │ │
│  │  └──────────────┬──────────────────┘  └───────────┬─────────────┘   │ │
│  └─────────────────┼─────────────────────────────────┼─────────────────┘ │
│                    │                                 │                     │
│  ┌─────────────────┼─────────────────────────────────┼─────────────────┐ │
│  │  硬件/软件驱动  ▼                                 ▼                  │ │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐  │ │
│  │  │  CN10K  │  │  QAT    │  │AESNI-MB │  │OpenSSL  │  │ ARMv8   │  │ │
│  │  │(TLS卸载)│  │(加密)   │  │(加密)   │  │PMD(加密)│  │(加密)   │  │ │
│  │  └─────────┘  └─────────┘  └─────────┘  └─────────┘  └─────────┘  │ │
│  └─────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 5.2 数据面与控制面分离

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    TLS 数据面与控制面分离                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  控制面 (Control Plane) — 频率低，延迟不敏感:                              │
│  ────────────────────────────────────────────                               │
│  - TLS 握手协议处理 (ClientHello/ServerHello/...)                           │
│  - Session 建立/恢复 (Session ID / Session Ticket)                         │
│  - 证书验证 (X.509 证书链)                                                 │
│  - 密钥交换 (ECDHE/RSA)                                                    │
│  - 密钥派生 (HKDF / PRF)                                                   │
│  - 可在 CPU 上用 OpenSSL/wolfSSL 等库处理                                   │
│                                                                             │
│  数据面 (Data Plane) — 频率高，延迟敏感:                                   │
│  ─────────────────────────────────────────                                  │
│  - TLS Record 加密/解密 (AEAD 操作)                                        │
│  - 序列号管理 (每个 Record 递增)                                            │
│  - Record 头拼装/解析                                                       │
│  - 可卸载到 DPDK cryptodev 或 rte_security                                 │
│                                                                             │
│  ┌──────────────────────────────────────────────────────────────────────┐ │
│  │                        控制面                                         │ │
│  │  ┌────────────┐  ┌────────────┐  ┌────────────┐                     │ │
│  │  │ 握手处理   │  │ Session 管理│  │ 证书验证   │                     │ │
│  │  │ (OpenSSL/ │  │ (rte_hash/ │  │ (X509/    │                     │ │
│  │  │  wolfSSL) │  │  rte_ring) │  │  libcert) │                     │ │
│  │  └─────┬──────┘  └─────┬──────┘  └─────┬──────┘                     │ │
│  └────────┼────────────────┼────────────────┼────────────────────────┘ │
│           │                │                │                              │
│           │ traffic keys   │ Session State  │ 证书                        │
│           ▼                ▼                ▼                              │
│  ┌──────────────────────────────────────────────────────────────────────┐ │
│  │                     数据面 (DPDK)                                    │ │
│  │                                                                      │ │
│  │  路径 A: rte_security TLS Record 卸载                                │ │
│  │  ┌──────────────────────────────────────────────────────────────┐   │ │
│  │  │  输入 mbuf → 硬件自动: Record 头处理 + AEAD + 序列号         │   │ │
│  │  │  → 输出 mbuf (已加密/已解密的完整 TLS Record)                │   │ │
│  │  └──────────────────────────────────────────────────────────────┘   │ │
│  │                                                                      │ │
│  │  路径 B: rte_cryptodev 加密加速                                      │ │
│  │  ┌──────────────────────────────────────────────────────────────┐   │ │
│  │  │  应用拼装 Record → cryptodev AEAD → 应用拼装输出              │   │ │
│  │  │  (序列号、IV、AAD 由应用管理)                                  │   │ │
│  │  └──────────────────────────────────────────────────────────────┘   │ │
│  └──────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 6. DPDK TLS Record 加速实现

### 6.1 路径 A: rte_security TLS Record 卸载

部分硬件（如 Marvell CN10K）支持通过 `rte_security` 卸载整个 TLS Record 层处理。
DPDK 在 `lib/security/rte_security.h` 中定义了相关结构：

```c
// DPDK: lib/security/rte_security.h

// TLS Record 支持的协议版本
enum rte_security_tls_version {
    RTE_SECURITY_VERSION_TLS_1_2,   // TLS 1.2
    RTE_SECURITY_VERSION_TLS_1_3,   // TLS 1.3
    RTE_SECURITY_VERSION_DTLS_1_2,  // DTLS 1.2
};

// Session 类型: 读 (解密) 或 写 (加密)
enum rte_security_tls_sess_type {
    RTE_SECURITY_TLS_SESS_TYPE_READ,   // Decrypt & digest verification
    RTE_SECURITY_TLS_SESS_TYPE_WRITE,  // Encrypt & digest generation
};

// TLS Record 卸载配置
struct rte_security_tls_record_xform {
    enum rte_security_tls_version ver;
    enum rte_security_tls_sess_type type;
    struct rte_security_tls_record_sess_options options;
    struct rte_security_tls_record_lifetime life;

    union {
        // TLS 1.2 参数
        struct {
            uint64_t seq_no;                                    // 起始序列号
            uint8_t imp_nonce[RTE_SECURITY_TLS_1_2_IMP_NONCE_LEN]; // 隐式 nonce
        } tls_1_2;

        // TLS 1.3 参数
        struct {
            uint64_t seq_no;                                    // 起始序列号
            uint8_t imp_nonce[RTE_SECURITY_TLS_1_3_IMP_NONCE_LEN]; // 隐式 nonce
            uint32_t min_payload_len;                           // 最小 payload 长度
        } tls_1_3;

        // DTLS 1.2 参数
        struct {
            uint16_t epoch;                                     // epoch 值
            uint64_t seq_no;                                    // 48-bit 起始序列号
            uint8_t imp_nonce[RTE_SECURITY_DTLS_1_2_IMP_NONCE_LEN];
            uint32_t ar_win_sz;                                 // 反重放窗口大小
        } dtls_1_2;
    };
};

// 创建 security session 时使用:
// session_conf.protocol = RTE_SECURITY_PROTOCOL_TLS_RECORD;
// session_conf.tls_record = { .ver = RTE_SECURITY_VERSION_TLS_1_3, ... };
// session_conf.crypto_xform = &aead_xform;  // 附带加密 transform
```

**使用 rte_security TLS Record 的完整流程：**

```c
// === rte_security TLS Record 卸载示例 (伪代码) ===

// Step 1: 查询设备 TLS Record 能力
const struct rte_security_capability *cap;
while ((cap = rte_security_capabilities_get(sec_ctx)) != NULL) {
    if (cap->protocol == RTE_SECURITY_PROTOCOL_TLS_RECORD &&
        cap->tls_record.ver == RTE_SECURITY_VERSION_TLS_1_3 &&
        cap->tls_record.type == RTE_SECURITY_TLS_SESS_TYPE_WRITE)
        break;
}

// Step 2: 创建 security session
struct rte_security_session_conf sess_conf = {
    .protocol = RTE_SECURITY_PROTOCOL_TLS_RECORD,
    .tls_record = {
        .ver = RTE_SECURITY_VERSION_TLS_1_3,
        .type = RTE_SECURITY_TLS_SESS_TYPE_WRITE,
        .tls_1_3 = {
            .seq_no = 0,
            .imp_nonce = { /* 从握手派生的隐式 nonce */ },
            .min_payload_len = 0,
        },
    },
    .crypto_xform = &aead_xform,  // AEAD transform (AES-128-GCM 等)
};

void *sec_session = rte_security_session_create(sec_ctx, &sess_conf, sess_pool);

// Step 3: 处理数据包
// 对于 inline crypto: 直接设置 mbuf 的 ol_flags 即可
// 对于 lookaside: 通过 rte_crypto_op 提交到 cryptodev
```

> [!note] rte_security TLS Record 支持情况
> 截至 DPDK 24.x，TLS Record 卸载仅 Marvell CN10K 系列硬件支持。
> 大多数硬件只能通过路径 B（rte_cryptodev）加速加密运算。

### 6.2 路径 B: rte_cryptodev 加密加速

这是最通用的方式，适用于所有支持 AEAD 的 cryptodev。应用自行管理
Record 头、序列号、IV 拼装，仅将加密运算提交给 cryptodev：

```c
// === rte_cryptodev TLS Record 加速示例 ===

// TLS Record 加密 (数据面热点路径)
static int
tls_record_encrypt_aead(struct tls_conn *conn,
                        struct rte_mbuf *mbuf,
                        uint8_t content_type)
{
    struct rte_crypto_op *op;
    struct rte_crypto_sym_op *sym_op;
    uint64_t seq = conn->tx_seq++;
    uint8_t nonce[12];
    uint8_t aad[5];

    // 1. 构建 Nonce (TLS 1.2: IV[0..3] || seq_num)
    memcpy(nonce, conn->write_iv, 4);       // implicit IV (4 bytes)
    nonce[4] = (seq >> 56) & 0xFF;
    nonce[5] = (seq >> 48) & 0xFF;
    nonce[6] = (seq >> 40) & 0xFF;
    nonce[7] = (seq >> 32) & 0xFF;
    nonce[8] = (seq >> 24) & 0xFF;
    nonce[9] = (seq >> 16) & 0xFF;
    nonce[10] = (seq >> 8) & 0xFF;
    nonce[11] = seq & 0xFF;

    // 2. 构建 AAD (TLS Record 头: type + version + length)
    aad[0] = content_type;
    aad[1] = (conn->version >> 8) & 0xFF;
    aad[2] = conn->version & 0xFF;
    uint16_t pt_len = rte_pktmbuf_pkt_len(mbuf);
    aad[3] = (pt_len >> 8) & 0xFF;
    aad[4] = pt_len & 0xFF;

    // 3. 分配 crypto op
    op = rte_crypto_op_alloc(conn->op_pool, RTE_CRYPTO_OP_TYPE_SYMMETRIC);
    if (op == NULL)
        return -ENOMEM;

    sym_op = op->sym;

    // 4. 设置源/目标 mbuf
    sym_op->m_src = mbuf;
    sym_op->m_dst = mbuf;  // in-place 加密

    // 5. 附加 session
    rte_crypto_op_attach_sym_session(op, conn->crypto_session);

    // 6. 设置 AEAD 参数
    sym_op->aead.data.offset = 0;         // 数据在 mbuf 中的偏移
    sym_op->aead.data.length = pt_len;    // 明文长度

    // 7. 设置 IV (nonce)
    // rte_crypto_sym_op 的 IV 通过 rte_crypto_op 附带的 private data 传递
    // 或通过 sym_op 的 iv 字段 (取决于 DPDK 版本)

    // 8. 设置 AAD
    // AAD 的设置方式取决于 PMD:
    //   - 有的通过 mbuf 的 rte_pktmbuf_attach_extbuf
    //   - 有的通过 crypto op 的附加数据区
    //   以下为概念展示:
    uint8_t *iv_ptr = rte_crypto_op_ctod_offset(op, uint8_t *,
                                                 sizeof(struct rte_crypto_sym_op));
    rte_memcpy(iv_ptr, nonce, 12);

    // 9. 提交到 cryptodev (批量)
    // 实际使用中应批量提交，而非单条
    return 0;
}

// 批量 TLS Record 加密
static uint16_t
tls_encrypt_batch(struct tls_conn *conn,
                  struct rte_mbuf **pkts,
                  struct rte_crypto_op **ops,
                  uint16_t nb_pkts)
{
    uint16_t i, nb_enq, nb_deq;

    // 1. 为每个包准备 crypto op
    for (i = 0; i < nb_pkts && i < 32; i++) {
        ops[i] = rte_crypto_op_alloc(conn->op_pool,
                                      RTE_CRYPTO_OP_TYPE_SYMMETRIC);
        if (ops[i] == NULL)
            break;

        // 设置源 mbuf
        ops[i]->sym->m_src = pkts[i];
        ops[i]->sym->m_dst = pkts[i];  // in-place

        // 附加 session
        rte_crypto_op_attach_sym_session(ops[i], conn->crypto_session);

        // 设置 AEAD 参数
        ops[i]->sym->aead.data.offset = 0;
        ops[i]->sym->aead.data.length = rte_pktmbuf_pkt_len(pkts[i]);

        // 设置 IV、AAD (省略，同上)
    }

    // 2. 批量入队 (非阻塞)
    nb_enq = rte_cryptodev_enqueue_burst(conn->crypto_dev_id, 0,
                                          ops, i);
    if (nb_enq < i)
        RTE_LOG(WARNING, USER1, "Only enqueued %u/%u ops\n", nb_enq, i);

    // 3. 批量出队 (非阻塞，可能需要多次轮询)
    nb_deq = 0;
    do {
        nb_deq += rte_cryptodev_dequeue_burst(conn->crypto_dev_id, 0,
                                                &ops[nb_deq], nb_enq - nb_deq);
    } while (nb_deq < nb_enq);

    // 4. 处理结果
    for (i = 0; i < nb_deq; i++) {
        if (ops[i]->status == RTE_CRYPTO_OP_STATUS_SUCCESS) {
            // 加密成功，拼装 TLS Record 头 + explicit IV
            tls_record_header_build(ops[i]->sym->m_src, conn);
        } else {
            // 加密失败
            rte_pktmbuf_free(ops[i]->sym->m_src);
            ops[i]->sym->m_src = NULL;
        }
        rte_crypto_op_free(ops[i]);
    }

    return nb_deq;
}
```

> [!warning] m_src 字段位置
> `rte_crypto_op` 没有直接的 `m_src` 字段。mbuf 通过 `op->sym->m_src` 访问，
> 不是 `op->m_src`。这是常见的 API 误用点。

---

## 7. OpenSSL 与 DPDK 的集成方式

### 7.1 集成架构

DPDK **没有**提供官方的 OpenSSL Engine 或 OpenSSL Provider。
但有两种常见的集成模式：

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    OpenSSL 与 DPDK 集成方式                                │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  模式 A: 控制面用 OpenSSL，数据面用 DPDK cryptodev (推荐)                  │
│  ────────────────────────────────────────────────────────────               │
│                                                                             │
│  ┌──────────────────────────────────────────────────────────────────────┐ │
│  │  TLS 应用                                                            │ │
│  │  ┌─────────────────────────┐  ┌─────────────────────────────┐       │ │
│  │  │  控制面 (OpenSSL)       │  │  数据面 (DPDK cryptodev)    │       │ │
│  │  │                         │  │                              │       │ │
│  │  │  - TLS 握手             │  │  - AEAD 加密/解密            │       │ │
│  │  │  - 证书验证             │  │  - 批量处理                  │       │ │
│  │  │  - 密钥派生             │  │  - 高吞吐                    │       │ │
│  │  │  - Session 管理         │  │  - 硬件加速 (QAT/AESNI)     │       │ │
│  │  └────────────┬────────────┘  └─────────────┬───────────────┘       │ │
│  │               │ traffic keys                │                         │ │
│  │               └──────────────┬──────────────┘                         │ │
│  │                              ▼                                        │ │
│  │               ┌──────────────────────────────┐                        │ │
│  │               │  密钥材料同步 (握手结果       │                        │ │
│  │               │  → 创建 cryptodev session)   │                        │ │
│  │               └──────────────────────────────┘                        │ │
│  └──────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
│  模式 B: OpenSSL PMD (软件加密)                                            │
│  ─────────────────────────────────                                        │
│                                                                             │
│  ┌──────────────────────────────────────────────────────────────────────┐ │
│  │  DPDK OpenSSL PMD 驱动                                               │ │
│  │                                                                      │ │
│  │  作用: 将 OpenSSL 的加密能力封装为 DPDK cryptodev PMD                │ │
│  │  位置: drivers/crypto/openssl/                                       │ │
│  │  本质: 软件加密，使用 CPU (AES-NI 指令)                              │ │
│  │                                                                      │ │
│  │  适用场景:                                                           │ │
│  │  - 开发/测试环境，没有 QAT 硬件                                     │ │
│  │  - 需要利用 OpenSSL 3.0 Provider 加速                                │ │
│  │  - 功能验证（OpenSSL 支持最全的算法）                                │ │
│  └──────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
│  模式 C: 自定义 OpenSSL Provider (高级)                                    │
│  ──────────────────────────────────────                                    │
│                                                                             │
│  ┌──────────────────────────────────────────────────────────────────────┐ │
│  │  自定义 OpenSSL 3.0 Provider                                         │ │
│  │                                                                      │ │
│  │  OpenSSL 3.0 引入 Provider 机制替代旧的 Engine API:                  │ │
│  │  - ENGINE API 已废弃 (deprecated)                                    │ │
│  │  - 新的 Provider API (OSSL_PROVIDER)                                 │ │
│  │  - 可以将 DPDK cryptodev 封装为 OpenSSL Provider                    │ │
│  │                                                                      │ │
│  │  注意: DPDK 官方不提供此 Provider，需要应用自行实现                  │ │
│  │  参考: https://www.openssl.org/docs/man3.0/man7/provider.html       │ │
│  └──────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 7.2 OpenSSL PMD 的使用

DPDK 内置的 OpenSSL PMD 是一个**软件加密驱动**，它将 OpenSSL 库的
加密能力封装为 cryptodev 接口，方便应用在不更换代码的情况下切换加密后端：

```c
// === OpenSSL PMD 初始化 ===

// 获取 OpenSSL PMD 设备 ID
int crypto_dev_id = rte_cryptodev_get_dev_id("crypto_openssl0");
if (crypto_dev_id < 0) {
    // OpenSSL PMD 未启动，可能需要添加 vdev
    // 启动参数: --vdev "crypto_openssl0"
    return -ENODEV;
}

// OpenSSL PMD 支持的算法:
// - AES-CBC / AES-CTR / AES-GCM / AES-CCM
// - 3DES-CBC
// - HMAC-SHA1 / HMAC-SHA256 / HMAC-SHA384 / HMAC-SHA512
// - ChaCha20-Poly1305
// - RSA (sign/verify/encrypt/decrypt)
// - ECDSA / ECDH
// - MD5 / SHA1 / SHA224 / SHA256 / SHA384 / SHA512

// 使用方式与硬件 PMD 完全相同 — 这就是 PMD 抽象的价值:
struct rte_cryptodev_config conf = {
    .socket_id = rte_socket_id(),
    .nb_queue_pairs = 1,
    .ff_disable = 0,
};
rte_cryptodev_configure(crypto_dev_id, &conf);
rte_cryptodev_queue_pair_setup(crypto_dev_id, 0, &qp_conf,
                                rte_socket_id());
rte_cryptodev_start(crypto_dev_id);

// 后续使用 rte_crypto_op + enqueue/dequeue，与硬件 PMD 完全一致
```

> [!warning] OpenSSL Engine vs Provider
> - OpenSSL 3.0 已**废弃** Engine API（`ENGINE_by_id()`、`ENGINE_init()` 等）
> - 新代码应使用 **Provider API**（`OSSL_PROVIDER`）
> - DPDK **不提供** OpenSSL Engine 或 Provider，OpenSSL PMD 是反向的（OpenSSL → DPDK）

---

## 8. 完整使用示例：TLS 终止代理

### 8.1 架构总览

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      TLS 终止代理 (TLS Termination)                        │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  Client ──TLS──► [TLS Proxy] ──HTTP──► Backend Server                     │
│                                                                             │
│  ┌──────────────────────────────────────────────────────────────────────┐ │
│  │                     TLS Proxy 数据流                                 │ │
│  │                                                                      │ │
│  │  ┌────────┐     ┌───────────────────┐     ┌────────────────────┐    │ │
│  │  │ Client │     │   TLS Proxy       │     │  Backend Server   │    │ │
│  │  │        │     │                   │     │                    │    │ │
│  │  │ HTTPS  │────►│ 1. 接收 TLS Record│     │                    │    │ │
│  │  │        │     │ 2. 解密 Record    │     │                    │    │ │
│  │  │        │     │    (cryptodev)    │────►│ 3. HTTP 明文       │    │ │
│  │  │        │     │ 3. 转发明文       │     │                    │    │ │
│  │  │        │◄────│ 4. 加密 Response  │     │                    │    │ │
│  │  │        │     │    (cryptodev)    │◄────│ 5. HTTP Response   │    │ │
│  │  │        │     │ 5. 发送 TLS Record│     │                    │    │ │
│  │  └────────┘     └───────────────────┘     └────────────────────┘    │ │
│  │                                                                      │ │
│  │  握手流程 (控制面):                                                  │ │
│  │  ┌─────────────────────────────────────────────────────────────┐   │ │
│  │  │  ClientHello → OpenSSL 处理握手 → 派生 traffic keys         │   │ │
│  │  │  → 创建 cryptodev session → 后续用 DPDK 做数据面加密       │   │ │
│  │  └─────────────────────────────────────────────────────────────┘   │ │
│  └──────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 8.2 初始化代码

```c
// === TLS 终止代理初始化 ===

struct tls_proxy {
    uint16_t listen_port;
    uint32_t backend_ip;
    uint16_t backend_port;

    // DPDK 资源
    uint8_t crypto_dev_id;
    uint16_t port_id;              // ethdev port
    struct rte_mempool *mbuf_pool;
    struct rte_mempool *op_pool;
    struct rte_mempool *sess_pool;

    // Session 缓存
    struct rte_hash *session_hash;
};

int
tls_proxy_init(struct tls_proxy *proxy)
{
    struct rte_cryptodev_config dev_conf = {
        .socket_id = rte_socket_id(),
        .nb_queue_pairs = 4,
        .ff_disable = 0,
    };

    // 配置 cryptodev
    // 注意: rte_cryptodev_config 没有 max_nb_sessions 字段
    // session 数量由 sess_pool 的大小决定
    rte_cryptodev_configure(proxy->crypto_dev_id, &dev_conf);

    // 创建 crypto op pool
    proxy->op_pool = rte_crypto_op_pool_create(
        "tls_proxy_ops",
        RTE_CRYPTO_OP_TYPE_SYMMETRIC,
        4096,       // nb_elts
        64,         // cache_size
        0,          // priv_size
        rte_socket_id());

    // 创建 session pool
    proxy->sess_pool = rte_cryptodev_sym_session_pool_create(
        "tls_proxy_sess",
        16384,      // max nb sessions
        0,          // session private data size
        0,          // cache size
        rte_socket_id());

    // 创建 mbuf pool
    proxy->mbuf_pool = rte_pktmbuf_pool_create(
        "tls_proxy_mbuf",
        8192, 256, 0,
        RTE_MBUF_DEFAULT_BUF_SIZE,
        rte_socket_id());

    // 创建 session hash 表
    struct rte_hash_parameters hash_params = {
        .name = "tls_sessions",
        .entries = 16384,
        .key_len = 32,        // session_id 长度
        .hash_func = rte_jhash,
        .hash_func_init_val = 0,
        .socket_id = rte_socket_id(),
    };
    proxy->session_hash = rte_hash_create(&hash_params);

    return 0;
}
```

### 8.3 数据面处理主循环

```c
// === TLS 终止代理数据面 ===

// 解析 TLS Record 头 (使用 DPDK 的 rte_tls_hdr)
static inline int
tls_parse_record(const uint8_t *data, size_t len,
                 struct rte_tls_hdr *hdr)
{
    if (len < sizeof(*hdr))
        return -1;

    rte_memcpy(hdr, data, sizeof(*hdr));
    hdr->version = rte_be_to_cpu_16(hdr->version);
    hdr->length = rte_be_to_cpu_16(hdr->length);

    if (len < sizeof(*hdr) + hdr->length)
        return -1;  // 数据不完整

    return 0;
}

// 数据面主循环
void
tls_proxy_run(struct tls_proxy *proxy)
{
    struct rte_mbuf *pkts[MAX_PKT_BURST];
    struct rte_crypto_op *ops[MAX_PKT_BURST];

    while (!force_quit) {
        // 1. 接收数据包
        uint16_t nb_rx = rte_eth_rx_burst(proxy->port_id, 0,
                                           pkts, MAX_PKT_BURST);
        if (nb_rx == 0)
            continue;

        // 2. 按连接分组，准备 crypto op
        uint16_t nb_ops = 0;
        for (uint16_t i = 0; i < nb_rx; i++) {
            struct rte_tls_hdr tls_hdr;
            uint8_t *pkt_data = rte_pktmbuf_mtod(pkts[i], uint8_t *);

            if (tls_parse_record(pkt_data,
                                  rte_pktmbuf_pkt_len(pkts[i]),
                                  &tls_hdr) < 0) {
                rte_pktmbuf_free(pkts[i]);
                continue;
            }

            if (tls_hdr.type == RTE_TLS_TYPE_APPDATA) {
                // 应用数据 — 准备解密
                struct tls_conn *conn = find_connection(proxy, pkts[i]);
                if (conn == NULL) {
                    rte_pktmbuf_free(pkts[i]);
                    continue;
                }

                ops[nb_ops] = rte_crypto_op_alloc(proxy->op_pool,
                                          RTE_CRYPTO_OP_TYPE_SYMMETRIC);
                ops[nb_ops]->sym->m_src = pkts[i];
                ops[nb_ops]->sym->m_dst = pkts[i];
                rte_crypto_op_attach_sym_session(ops[nb_ops],
                                                  conn->crypto_session);

                // 设置 AEAD 参数 (跳过 5 字节 TLS Record 头)
                ops[nb_ops]->sym->aead.data.offset = sizeof(struct rte_tls_hdr);
                ops[nb_ops]->sym->aead.data.length = tls_hdr.length;

                nb_ops++;
            } else {
                // 握手消息 — 交给控制面处理
                handle_handshake(proxy, pkts[i]);
            }
        }

        if (nb_ops == 0)
            continue;

        // 3. 批量提交解密 (非阻塞)
        uint16_t nb_enq = rte_cryptodev_enqueue_burst(
            proxy->crypto_dev_id, 0, ops, nb_ops);

        // 4. 批量收集结果 (非阻塞轮询)
        uint16_t nb_deq = 0;
        while (nb_deq < nb_enq) {
            nb_deq += rte_cryptodev_dequeue_burst(
                proxy->crypto_dev_id, 0,
                &ops[nb_deq], nb_enq - nb_deq);
        }

        // 5. 处理解密结果
        for (uint16_t i = 0; i < nb_deq; i++) {
            if (ops[i]->status == RTE_CRYPTO_OP_STATUS_SUCCESS) {
                // 解密成功 → 去掉 TLS Record 头，转发明文到后端
                rte_pktmbuf_adj(ops[i]->sym->m_src, sizeof(struct rte_tls_hdr));
                forward_to_backend(proxy, ops[i]->sym->m_src);
            } else {
                rte_pktmbuf_free(ops[i]->sym->m_src);
            }
            rte_crypto_op_free(ops[i]);
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
| **Session Ticket** | 无状态 session 存储，支持分布式 | 水平扩展 |
| **批量加密** | 批量提交 crypto op 到 cryptodev | 3-5x 提升吞吐 |
| **硬件卸载** | QAT/AESNI-MB 加速 AEAD | 10x+ 提升 |
| **数据面/控制面分离** | 握手用 OpenSSL，加密用 DPDK | 最佳效率 |
| **Early Data (0-RTT)** | TLS 1.3 首包无延迟 | 首请求零延迟 |
| **in-place 加密** | `m_src == m_dst`，减少拷贝 | 降低内存带宽 |

---

## 10. 小结

本章核心要点：

1. **TLS vs IPsec**：TLS 工作在传输层（TCP 之上），对应用可见；IPsec 工作在网络层，对应用透明。

2. **TLS 1.2 vs 1.3**：1.3 将握手从 2-RTT 降为 1-RTT（0-RTT 可选），移除 CBC+HMAC 仅保留 AEAD，将 Content Type 移入密文内部。

3. **DTLS**：基于 UDP 的 TLS，记录头 13 字节（含 epoch + 48-bit 序列号），处理包丢失、乱序、Cookie 交换和重传。

4. **TLS 记录层**：TLS 头 5 字节（type + version + length），DTLS 头 13 字节。DPDK 提供 `rte_tls_hdr` 和 `rte_dtls_hdr` 定义。

5. **TLS 握手**：ClientHello/ServerHello → Certificate → KeyExchange → Finished。TLS 1.3 密钥派生链：Early Secret → Handshake Secret → Master Secret。

6. **Session Resumption**：Session ID 或 Session Ticket 机制避免完整握手。TLS 1.3 支持 0-RTT Early Data。

7. **DPDK 不提供 TLS 协议栈**：DPDK 提供三层 TLS 加速能力——`rte_cryptodev`（加密加速）、`rte_security TLS Record`（记录层卸载，仅部分硬件支持）、OpenSSL PMD（软件加密）。

8. **控制面/数据面分离**：握手用 OpenSSL/wolfSSL（CPU），Record 加密用 DPDK cryptodev（硬件）。握手完成后将 traffic keys 同步到 cryptodev session。

9. **OpenSSL 集成**：OpenSSL 3.0 废弃了 Engine API，改用 Provider API。DPDK 不提供官方 OpenSSL Engine/Provider。

10. **性能**：QAT 可达 50 Gbps，AESNI-MB 可达 8 Gbps/core。批量提交 crypto op + in-place 加密是关键优化手段。

**下一篇预告**：[[2026-04-09-dpdk-deep-dive-ch24-raw-crypto-api|第二十四章]]将讲解 Raw Crypto API 与自定义协议加密——灵活加密接口设计。

---

> [!tip] 参考文献
> - RFC 5246, "The Transport Layer Security (TLS) Protocol Version 1.2"
> - RFC 8446, "The Transport Layer Security (TLS) Protocol Version 1.3"
> - RFC 6347, "Datagram Transport Layer Security Version 1.2"
> - RFC 9147, "The Datagram Transport Layer Security (DTLS) Protocol Version 1.3"
> - RFC 5077, "Transport Layer Security (TLS) Session Resumption"
> - RFC 8446 Appendix A, "Key Derivation" (TLS 1.3 密钥派生)
> - DPDK, "Cryptodev Library", https://doc.dpdk.org/guides/prog_guide/cryptodev.html
> - DPDK, "Security Library", https://doc.dpdk.org/guides/prog_guide/rte_security.html
> - OpenSSL 3.0, "Provider API", https://www.openssl.org/docs/man3.0/man7/provider.html
> - DPDK source: `lib/net/rte_tls.h`, `lib/net/rte_dtls.h`, `lib/security/rte_security.h`
