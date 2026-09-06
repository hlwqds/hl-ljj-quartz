---
title: "QUIC 深度探索 ch11 - 包类型详解"
date: 2026-04-14
description: "全面解析 QUIC 的包类型体系：Long Header（Initial/0-RTT/Handshake/Retry）与 Short Header（1-RTT）的二进制格式、字段语义、Version Negotiation 报文结构"
tags:
  - quic
  - series
  - packets
  - wire-format
  - long-header
  - short-header
---

# QUIC 深度探索 ch11 - 包类型详解

> [!tip] 本章内容
> 本章全面剖析 QUIC 的包类型体系，涵盖 Long Header 四种变体（Initial/0-RTT/Handshake/Retry）、Short Header（1-RTT）以及 Version Negotiation 报文的完整二进制格式与字段语义。

---

## 1. QUIC 包类型总览

QUIC 将数据包分为两大类：**Long Header 包**和 **Short Header 包**。两者通过第一个字节的最高位（Header Form bit）来区分。

```
第一字节结构：
  +--------+
  |Header  |  1 bit  ── 1 = Long Header, 0 = Short Header
  |Form    |
  +--------+
  |Fixed   |  1 bit  ── 必须为 1（QUIC v1），否则丢弃
  |Bit     |
  +--------+
  |其他字段|  6 bits ── 根据包类型不同而异
  +--------+
```

### 1.1 包类型分类

| 包类型              | Header Form | 加密级别                  | 用途                               |
| ------------------- | ----------- | ------------------------- | ---------------------------------- |
| Initial             | Long (1)    | Initial 密钥（HKDF 派生） | 握手第一轮 ClientHello/ServerHello |
| 0-RTT               | Long (1)    | 0-RTT 密钥                | 在握手完成前发送早期数据           |
| Handshake           | Long (1)    | Handshake 密钥            | 发送 Finished、加密扩展            |
| Retry               | Long (1)    | 无加密（完整性保护）      | 地址验证，要求客户端重试           |
| Version Negotiation | Long (1)    | 无加密                    | 服务端告知支持的版本               |
| 1-RTT               | Short (0)   | 1-RTT 密钥                | 握手完成后的所有应用数据           |

---

## 2. Long Header 包格式

### 2.1 Long Header 公共格式

所有 Long Header 包共享如下前缀结构（RFC 9000 §17.2）：

```
Long Header 公共格式（字节对齐）：

 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+
|1|1|T T|X X X X|   ← 第一字节：Header Form=1, Fixed Bit=1, Type(2bits), 类型特定字段(4bits)
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                         Version (32)                          |   ← QUIC 版本号
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
| DCID Len (8)  |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|               Destination Connection ID (0..160)              |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
| SCID Len (8)  |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                 Source Connection ID (0..160)                 |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|            Type-Specific Fields ...                           |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

字段说明：

| 字段               | 长度    | 说明                                         |
| ------------------ | ------- | -------------------------------------------- |
| Header Form        | 1 bit   | 必须为 1（Long Header）                      |
| Fixed Bit          | 1 bit   | 必须为 1，否则为无效包                       |
| Long Packet Type   | 2 bits  | 00=Initial, 01=0-RTT, 10=Handshake, 11=Retry |
| Type-Specific Bits | 4 bits  | 各包类型自定义                               |
| Version            | 32 bits | QUIC 版本（v1 = 0x00000001）                 |
| DCID Len           | 8 bits  | 目的 CID 长度（0-20 字节）                   |
| DCID               | 可变长  | Destination Connection ID                    |
| SCID Len           | 8 bits  | 源 CID 长度（0-20 字节）                     |
| SCID               | 可变长  | Source Connection ID                         |

### 2.2 Long Packet Type 编码

```
TT bits（第一字节 bit 4-5）:
  00 = Initial
  01 = 0-RTT
  10 = Handshake
  11 = Retry
```

---

## 3. Initial 包

### 3.1 Initial 包格式

Initial 包用于发送握手的第一轮消息（ClientHello/ServerHello），使用从 Destination CID 派生的 Initial 密钥加密。

```
Initial 包格式：

 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+
|1|1|0|0|R R P P|   ← Long Header, Type=00(Initial), R=保留, PP=Packet Number长度
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                         Version (32)                          |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
| DCID Len (8)  |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|               Destination Connection ID (0..160)              |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
| SCID Len (8)  |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                 Source Connection ID (0..160)                 |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                         Token Length (i)                    ...| ← Variable-length integer
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                            Token (*)                        ...|
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                           Length (i)                        ...|
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                    Packet Number (8/16/24/32)                  |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                          Payload (*)                        ...|
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

### 3.2 Initial 包特有字段

| 字段          | 长度              | 说明                                                 |
| ------------- | ----------------- | ---------------------------------------------------- |
| Token Length  | 可变长整数        | Token 字段的字节长度                                 |
| Token         | Token Length 字节 | Retry Token 或地址验证 Token（客户端初始连接时为空） |
| Length        | 可变长整数        | Packet Number + Payload 的总长度                     |
| Packet Number | 1-4 字节          | 通过 PP bits 编码长度                                |
| Payload       | 加密负载          | AEAD 加密的帧数据 + Tag                              |

### 3.3 Initial 密钥派生

Initial 包的加密密钥由 DCID 派生，所有 QUIC v1 实现使用相同的 salt：

```
QUIC v1 Initial Salt:
  38762cf7f55934b34d179ae6a4c80cadccbb7f0a

Initial Secret = HKDF-Extract(salt, DCID)
client_initial_secret = HKDF-Expand-Label(Initial_Secret, "client in", "", hash.length)
server_initial_secret = HKDF-Expand-Label(Initial_Secret, "server in", "", hash.length)

client_key = HKDF-Expand-Label(client_initial_secret, "quic key", "", 16)
client_iv  = HKDF-Expand-Label(client_initial_secret, "quic iv",  "", 12)
client_hp  = HKDF-Expand-Label(client_initial_secret, "quic hp",  "", 16)
```

> [!note] 安全性说明
> Initial 包的加密密钥是公开已知的（由 DCID + 固定 salt 派生），因此 Initial 包不提供机密性保护，只防止被无意中的中间件修改（完整性保护）。真正的机密性从 Handshake 包开始。

### 3.4 Packet Number 编码（PP bits）

```
PP bits 编码：
  00 → 1 字节 Packet Number（范围 0-127）
  01 → 2 字节 Packet Number
  10 → 3 字节 Packet Number
  11 → 4 字节 Packet Number

注意：PP bits 本身在发送前通过 Header Protection 加密！
```

---

## 4. 0-RTT 包

### 4.1 0-RTT 包格式

0-RTT 包格式与 Initial 包几乎相同，但无 Token 字段，并使用 0-RTT 密钥加密：

```
0-RTT 包格式：

 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+
|1|1|0|1|R R P P|   ← Long Header, Type=01(0-RTT), R=保留, PP=PN长度
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                         Version (32)                          |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
| DCID Len (8)  |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|               Destination Connection ID (0..160)              |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
| SCID Len (8)  |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                 Source Connection ID (0..160)                 |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                           Length (i)                        ...|
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                    Packet Number (8/16/24/32)                  |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                          Payload (*)                        ...|
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

### 4.2 0-RTT 使用约束

```
0-RTT 数据的使用限制：
  ✓ 可以发送应用层数据（STREAM、DATAGRAM 帧）
  ✗ 不能发送 ACK 帧（可能导致重放攻击）
  ✗ 不能发送 CONNECTION_CLOSE 帧
  ✗ 不能更改连接级参数（transport parameters）
  ✗ 不能使用新的 Connection ID
```

---

## 5. Handshake 包

### 5.1 Handshake 包格式

Handshake 包用于发送 TLS 1.3 握手的后续消息（Certificate、CertificateVerify、Finished），使用 Handshake 密钥加密：

```
Handshake 包格式：

 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+
|1|1|1|0|R R P P|   ← Long Header, Type=10(Handshake), R=保留, PP=PN长度
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                         Version (32)                          |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
| DCID Len (8)  |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|               Destination Connection ID (0..160)              |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
| SCID Len (8)  |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                 Source Connection ID (0..160)                 |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                           Length (i)                        ...|
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                    Packet Number (8/16/24/32)                  |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                          Payload (*)                        ...|
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

### 5.2 Handshake 包的密钥派生

```
Handshake 密钥派生（RFC 8446 §7.1 Key Schedule）：

  Handshake_Secret = HKDF-Extract(Early_Secret, DHE)
  client_hs_secret = HKDF-Expand-Label(HS, "c hs traffic", transcript, hash.length)
  server_hs_secret = HKDF-Expand-Label(HS, "s hs traffic", transcript, hash.length)

  client_hs_key = HKDF-Expand-Label(client_hs_secret, "quic key", "", 16)
  client_hs_iv  = HKDF-Expand-Label(client_hs_secret, "quic iv",  "", 12)
  client_hs_hp  = HKDF-Expand-Label(client_hs_secret, "quic hp",  "", 16)
```

---

## 6. Retry 包

### 6.1 Retry 包格式

Retry 包由服务端发送，要求客户端携带服务端生成的 Retry Token 重新发起 Initial 包，用于源地址验证：

```
Retry 包格式：

 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+
|1|1|1|1|Unused |   ← Long Header, Type=11(Retry), Unused bits（必须忽略）
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                         Version (32)                          |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
| DCID Len (8)  |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|               Destination Connection ID (0..160)              |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
| SCID Len (8)  |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                 Source Connection ID (0..160)                 |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                        Retry Token (*)                      ...|  ← 不定长
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                   Retry Integrity Tag (128)                    |  ← 16 字节固定
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

### 6.2 Retry Integrity Tag

Retry 包无 Packet Number，不使用 AEAD 加密，但有 **Retry Integrity Tag**（128 bit）防止伪造：

```
Retry Pseudo-Packet（用于计算 Integrity Tag）：
  ┌─────────────────────────────────────────┐
  │ ODCID Len  │ ODCID （原始客户端 DCID）   │
  │ Retry Header 字段                        │
  │ Retry Token                              │
  └─────────────────────────────────────────┘

Retry Integrity Tag = AES-128-GCM(
  key  = 0xbe0c690b9f66575a1d766b54e368c84e,
  iv   = 0x461599d35d632bf2239825bb,
  AAD  = Retry Pseudo-Packet,
  data = ""
)
```

### 6.3 Retry 流程

```
Retry 地址验证流程：

Client                          Server
  |                                |
  |── Initial (DCID=S1, Token=空) →|
  |                                | 服务端需要地址验证
  |← Retry (ODCID=S1, Token=T1)  ──|
  |                                |
  |── Initial (DCID=S2, Token=T1) →|  ← 携带 Retry Token
  |                                | 验证 Token，建立连接
  |                                |
```

---

## 7. Version Negotiation 包

### 7.1 Version Negotiation 格式

当服务端不支持客户端请求的 QUIC 版本时，发送 Version Negotiation 包：

```
Version Negotiation 包格式：

 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+
|1|Unused (7)   |   ← Header Form=1（Long），其余 7 bits 随机（防止中间件解析）
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                          Version (32) = 0                     |   ← 版本字段必须为 0x00000000
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
| DCID Len (8)  |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|               Destination Connection ID (0..2040)             |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
| SCID Len (8)  |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                 Source Connection ID (0..2040)                 |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                    Supported Version 1 (32)                    |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                    Supported Version 2 (32)                    |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                           ...                                  |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

> [!important] Version Negotiation 的安全性
> Version Negotiation 包不受完整性保护，存在降级攻击风险。QUIC v1 通过在 Handshake 中验证版本来防范此类攻击。

---

## 8. Short Header（1-RTT）包

### 8.1 Short Header 格式

握手完成后，所有数据包都使用 Short Header（1-RTT）格式，以减少开销：

```
Short Header（1-RTT）包格式：

 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+
|0|1|S|R|R|K|P P|   ← Header Form=0(Short), Fixed=1, Spin=S, R=保留, Key Phase=K, PP=PN长度
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|               Destination Connection ID (0..160)              |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                    Packet Number (8/16/24/32)                  |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                          Payload (*)                        ...|
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

### 8.2 Short Header 各字段解析

| 字段                      | 位数 | 说明                                            |
| ------------------------- | ---- | ----------------------------------------------- |
| Header Form               | 1    | 0 = Short Header                                |
| Fixed Bit                 | 1    | 必须为 1                                        |
| Spin Bit (S)              | 1    | 用于被动 RTT 测量（RFC 9000 §17.4）             |
| Reserved (R)              | 2    | 必须为 0，AEAD 后验证                           |
| Key Phase (K)             | 1    | 标识当前使用哪一组 1-RTT 密钥（密钥更新时翻转） |
| Packet Number Length (PP) | 2    | PN 编码长度（00=1B, 01=2B, 10=3B, 11=4B）       |
| DCID                      | 可变 | 目的 CID，长度由对端 transport_parameters 决定  |
| Packet Number             | 1-4  | AEAD 保护前明文（但被 Header Protection 加密）  |
| Payload                   | 可变 | AEAD 加密的帧数据                               |

> [!note] Short Header 没有 Version 字段和 SCID 字段
> Short Header 通过 DCID 路由，省略了版本号（连接建立时已协商）和 SCID（接收端无需知道发送端 CID）。

### 8.3 Spin Bit

Spin Bit 允许网络中间件（如交换机、路由器）被动测量端到端 RTT，无需解密数据包：

```
Spin Bit RTT 测量原理：

  Client                     Server
    │  Spin=0 ──────────────→  │
    │            ← Spin=0   ───│  (服务端回显对端 Spin)
    │  Spin=1 ──────────────→  │  (客户端在收到 Spin=0 后翻转)
    │            ← Spin=1   ───│
    │                          │

网络设备观察 Spin bit 翻转间隔 = 端到端 RTT
```

### 8.4 Key Phase 与密钥更新

```
Key Phase bit 与密钥更新：

  初始状态：Key Phase = 0，使用 Keys[0]

  密钥更新触发条件：
    ① 定期刷新（如每 N 个包或每 T 秒）
    ② 发送方将 Key Phase 翻转为 1，使用 Keys[1]
    ③ 接收方检测到 Key Phase 变化，尝试用 Keys[1] 解密
    ④ 解密成功 → 确认密钥更新，发送 ACK

  新密钥派生：
    New_Secret = HKDF-Expand-Label(current_secret, "quic ku", "", hash.length)
    New_Key = HKDF-Expand-Label(New_Secret, "quic key", "", 16)
    New_IV  = HKDF-Expand-Label(New_Secret, "quic iv",  "", 12)
```

---

## 9. Header Protection（包头保护）

### 9.1 为什么需要 Header Protection

AEAD 只保护 Payload，但 Packet Number 和某些 Header bits（PP bits、Key Phase）对重放攻击和流量分析敏感，因此 QUIC 引入了 **Header Protection**（HP）。

### 9.2 Header Protection 算法

```
Header Protection 加密流程（发送端）：

1. 从 AEAD 加密后的密文中取 Sample（16 字节）：
     Sample = ciphertext[4 - PN_Len : 4 - PN_Len + 16]
     （PN_Len 是 Packet Number 字节数）

2. 使用 HP Key 生成掩码：
     mask = AES-128-ECB(hp_key, Sample)    ← 对于 AES-128-GCM/AES-256-GCM
     mask = ChaCha20-block(hp_key, 0, Sample[4:])  ← 对于 ChaCha20-Poly1305

3. 应用掩码：
     first_byte ^= mask[0] & 0x0f      ← Short Header: 低 5 bits
     first_byte ^= mask[0] & 0x1f      ← Long Header:  低 4 bits
     packet_number[i] ^= mask[1 + i]   ← 对每个 PN 字节 XOR

Header Protection 解密流程（接收端）：
  逆向执行上述步骤（XOR 是自逆操作）
```

---

## 10. QUIC 包聚合（Coalescing）

QUIC 允许在单个 UDP 数据报中聚合多个 QUIC 包（Coalescing），以减少 UDP 包数量：

```
UDP 数据报聚合示例（Initial + Handshake）：

┌──────────────────────────────────┐
│  UDP Header                      │
├──────────────────────────────────┤
│  QUIC Initial Packet             │  ← Long Header, Type=Initial
│  (ClientHello CRYPTO frame)      │
│  Length = 500                    │
├──────────────────────────────────┤
│  QUIC Handshake Packet           │  ← Long Header, Type=Handshake
│  (Certificate CRYPTO frame)      │
│  Length = 900                    │
├──────────────────────────────────┤
│  QUIC 1-RTT Packet               │  ← Short Header (如有)
└──────────────────────────────────┘

规则：
  ① 接收方必须按顺序解析每个包
  ② 每个 Long Header 包必须包含 Length 字段（用于定位下一个包的起点）
  ③ 最后一个包（Short Header）不需要 Length 字段
```

---

## 11. 包类型与加密级别对应关系

```
包类型 ─────────────────→ 加密级别 ──────────────────→ 可携带的帧类型

Initial           →  Initial Keys       →  PADDING, PING, ACK, CRYPTO, CONNECTION_CLOSE
0-RTT             →  0-RTT Keys         →  STREAM, DATAGRAM, PADDING, PING, ...(no ACK)
Handshake         →  Handshake Keys     →  PADDING, PING, ACK, CRYPTO, CONNECTION_CLOSE
Retry             →  无（Integrity Tag） →  无帧（Token + Tag）
1-RTT (Short)     →  1-RTT Keys         →  所有帧类型
```

---

## 12. 实际抓包分析

```
Wireshark 过滤器：
  quic                        ← 所有 QUIC 流量
  quic.header_form == 1       ← 仅 Long Header 包
  quic.long.packet_type == 0  ← 仅 Initial 包
  quic.long.packet_type == 2  ← 仅 Handshake 包

tshark 解析示例：
  tshark -r capture.pcap -Y quic -T fields \
    -e quic.header_form \
    -e quic.long.packet_type \
    -e quic.dcid \
    -e quic.scid
```

---

## 小结

| 包类型       | Type bits           | 有 Token | 有 SCID | 有 Length | 加密算法                    |
| ------------ | ------------------- | -------- | ------- | --------- | --------------------------- |
| Initial      | 00                  | ✓        | ✓       | ✓         | AES-128-GCM（Initial Keys） |
| 0-RTT        | 01                  | ✗        | ✓       | ✓         | 0-RTT Keys                  |
| Handshake    | 10                  | ✗        | ✓       | ✓         | Handshake Keys              |
| Retry        | 11                  | Token    | ✓       | ✗         | Integrity Tag 仅            |
| 1-RTT        | N/A（Short Header） | ✗        | ✗       | ✗         | 1-RTT Keys                  |
| Version Neg. | N/A                 | ✗        | ✓       | ✗         | 无                          |

下一章将深入介绍 QUIC 的帧类型体系，包括每种帧的二进制格式与发送语义。
