---
title: "QUIC 深度探索 ch6 - QUIC 握手流程"
date: 2026-04-14
description: "深入解析 QUIC 握手的三个阶段：Initial 包、Handshake 包、0-RTT 包，密钥派生流程，以及与 TLS 1.3 的深度集成"
tags:
  - quic
  - series
  - handshake
  - tls
  - crypto
---

# QUIC 深度探索 ch6 - QUIC 握手流程

> [!tip] 本章内容
> 本章剖析 QUIC 握手的完整流程，涵盖 Initial/Handshake/0-RTT 三个包类型的发送时序、密钥派生层次、TLS 1.3 握手消息如何映射为 QUIC 帧，以及握手中的状态转换。

---

## 1. QUIC 握手的总体架构

QUIC 的握手设计融合了传输层连接建立与 TLS 1.3 握手，两者并行完成。传统 TCP+TLS 需要 2-RTT（TCP 三次握手 + TLS 1.3 握手），而 QUIC 将两者合并为**1-RTT**完成，理想情况下甚至可以达到**0-RTT**。

```
TCP + TLS 1.3 (2-RTT):
  Client          Server
    |─── SYN ────────>|
    |<── SYN+ACK ─────|
    |─── ACK ─────────>|
    |                  |  <- TCP 握手完成 (1-RTT)
    |─── ClientHello ──>|
    |<── ServerHello ───|
    |<── Finished ──────|
    |─── Finished ─────>|  <- TLS 握手完成 (2-RTT)

QUIC 1-RTT:
  Client          Server
    |─── Initial ────────>|
    |<── Initial ─────────|
    |<── Handshake ───────|
    |─── Handshake ───────>|  <- 1-RTT 完成
    |═══ 加密传输 ════════|
```

### 1.1 握手的三类数据包

QUIC 握手过程中涉及三种 Long Header 包：

| 包类型        | 加密级别               | 用途                     | 携带的 TLS 消息                                                           |
| ------------- | ---------------------- | ------------------------ | ------------------------------------------------------------------------- |
| **Initial**   | `ENCRYPTION_INITIAL`   | 交换加密参数、验证服务端 | ClientHello / ServerHello / EncryptedExtensions / Certificates / Finished |
| **Handshake** | `ENCRYPTION_HANDSHAKE` | 确认会话密钥、完成握手   | Finished                                                                  |
| **0-RTT**     | `ENCRYPTION_0-RTT`     | 早期数据传输（0-RTT）    | early_data                                                                |

> [!note] 加密级别定义
> QUIC 的加密级别（encryption level）与 TLS 1.3 的密钥阶段（key phase）对应：
>
> - `INITIAL`：初始级别，使用初始密钥（initial keys）
> - `HANDSHAKE`：握手级别，使用握手密钥
> - `0-RTT`：0-RTT 级别，使用 0-RTT 密钥
> - `1-RTT`：1-RTT 级别，使用应用数据密钥

---

## 2. Initial 包详解

Initial 包是客户端发送的第一个 QUIC 包，用于发起连接并携带 TLS ClientHello。

### 2.1 Initial 包格式

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+
|                          Long Header Packet                     |
+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+
| 0|1|1|          PP = 0x0           |      Connection ID Length   |
+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+
|                         Version = 0x00000001                    |
+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+
|            Destination Connection ID (SCID) (0..18)              |
+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+
|              Source Connection ID (DCID) (0..18)                 |
+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+
|                         Token (if present)                       |
+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+
|                           Packets NL                             |
+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+
|                          Payload...                              |
+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+
```

### 2.2 初始密钥的派生

QUIC 使用版本特有的初始密钥（Initial Keys）。服务端和客户端从连接 ID 和常量和派生初始密钥：

```
initial_secret = HKDF-Extract(
    salt = "QUIC draft version unknown" 或版本特定盐值,
    IKM  = Destination Connection ID
)

client_initial_secret = HKDF-Expand-Label(
    initial_secret, "client", "", 32
)
server_initial_secret = HKDF-Expand-Label(
    initial_secret, "server", "", 32
)
```

> [!warning] Initial 包安全问题
> RFC 9000 明确指出 Initial 包使用的密钥是"已知的"（well-known），不提供前向保密。因此 Initial 包可以被拥有盐值的第三方解密。敏感数据不应在 Initial 包中传输。

### 2.3 Initial 包携带的 CRYPTO 帧

Initial 包通过 CRYPTO 帧传输 TLS 消息。最常见的结构：

```
Initial Packet (
    long_header,
    type=0x0,
    version=0x00000001,
    destination_connection_id="client-generated",
    source_connection_id="server-provided (if known)",
    token="",  # 或 retry response token
    packet_number=0,
    frame: CRYPTO {
        offset=0,
        length=ClientHello bytes,
        data=ClientHello
    }
)
```

服务端响应的 Initial 包含多个 CRYPTO 帧，分别承载：

- **ServerHello**：协议版本、TLS 扩展、选定的密码套件
- **EncryptedExtensions**：服务端 QUIC 参数
- **Certificates**：证书
- **CertificateVerify**：签名验证
- **Finished**：握手确认

---

## 3. Handshake 包详解

Handshake 包在 Initial 包之后发送，用于完成密钥交换和握手确认。

### 3.1 Handshake 包的加密原理

Handshake 包使用从 Initial 包交换中派生的握手密钥（Handshake Keys）进行加密：

```
--> ClientHello
<-- ServerHello + EnryptedExtensions + Certificates + Finished

密钥派生:
  client_handshake_secret = Derive-Secret(
      master_secret, "client handshake", ServerHello... )
  server_handshake_secret = Derive-Secret(
      master_secret, "server handshake", ServerHello... )
```

### 3.2 Handshake 包携带的内容

Handshake 包主要携带 TLS Finished 消息，用于确认之前所有握手消息的完整性：

```
Handshake Packet (
    long_header,
    type=0x2,
    version=0x00000001,
    destination_connection_id="server's SCID",
    source_connection_id="client's SCID",
    packet_number=1,
    frame: CRYPTO {
        offset=0,
        data=Finished { verify_data }
    }
)
```

> [!note] 双向确认
> 客户端在收到服务端的 Finished 后发送自己的 Finished，服务端收到客户端的 Finished 后确认握手完成。这个双向确认保证双方都拥有相同的会话密钥。

---

## 4. 完整握手时序图

下面是一个完整的 QUIC 1-RTT 握手时序：

```
Client                                        Server
  |                                             |
  | 生成 client_random, dcid=cid_a               |
  | 发送 Initial[CRYPTO:ClientHello]             |
  |  包号=0, dcid=cid_a, scid=cid_b              |
  |                                             |
  | <-- 发送 Initial[CRYPTO:ServerHello]        |
  |      包号=0, CRYPTO:EncryptedExtensions      |
  |      CRYPTO:Certificates, CRYPTO:Finished    |
  |                                             |
  | [派生出 client 0-RTT key, client 1-RTT key] |
  |                                             |
  | 发送 Handshake[CRYPTO:Finished]              |
  |      (使用 handshake 密钥)                   |
  |                                             |
  | <-- 发送 Handshake[CRYPTO:Finished]         |
  |      (使用 handshake 密钥)                   |
  |                                             |
  | [完成密钥确认，进入 1-RTT 加密传输]           |
  |                                             |
  | ================================            |
  |         1-RTT 加密通道建立                   |
  | ================================            |
  |                                             |
  | 发送 1-RTT[STREAM:HTTP GET]                 |
  |  发送 1-RTT[HANDSHAKE_DONE]                 |
  |                                             |
```

### 4.1 密钥派生层次

QUIC/TLS 1.3 的密钥派生遵循以下层次：

```
                    TLS Master Secret / PSK
                          |
            +-------------+-------------+
            |                           |
      handshake_secret              early_secret
            |                           |
    +-------+-------+            +-------+-------+
    |               |            |               |
client_handshake  server_handshake  client_early  server_early
    |               |            |               |
    |               |            |               |
    v               v            v               v
client_handshake  server_handshake  client_0rtt  (服务端不使用)
traffic secret   traffic secret
    |               |
    v               v
client_handshake  server_handshake
 keys & ivs       keys & ivs
    |               |
    v               v
 application_data_secret (双向共享)
    |
    v
 1-RTT keys & ivs (双向使用)
```

---

## 5. TLS 消息到 QUIC 帧的映射

TLS 1.3 的握手消息通过 QUIC CRYPTO 帧传输，而不是直接封装在 TLS 记录层中。这是 QUIC 与 TLS 集成的核心不同点。

### 5.1 映射关系

| TLS 1.3 消息        | QUIC 帧类型 | 所在包类型           |
| ------------------- | ----------- | -------------------- |
| ClientHello         | CRYPTO      | Initial              |
| ServerHello         | CRYPTO      | Initial              |
| EncryptedExtensions | CRYPTO      | Initial              |
| Certificates        | CRYPTO      | Initial              |
| CertificateVerify   | CRYPTO      | Initial              |
| Finished            | CRYPTO      | Initial 或 Handshake |
| NewSessionTicket    | CRYPTO      | 1-RTT                |

### 5.2 为什么不用 TLS 记录层

传统 TLS over TCP 的记录层将多个 TLS 消息合并为一个分段：

```
TLS Record: AppData | fragment1 | fragment2
```

QUIC 使用独立的 CRYPTO 帧流实现相同的效果：

```
Initial Packet [
    CRYPTO(frame, offset=0, data=ClientHello[0:1200]),
    CRYPTO(frame, offset=1200, data=ClientHello[1200:])
]
```

### 5.3 CRYPTO 帧的 Offset 机制

CRYPTO 帧通过 `offset` 字段实现 TLS 消息的分片重组，解决了 TCP 的队头阻塞问题：

```
ClientHello 长度 = 3000 bytes

包1: CRYPTO(offset=0,    length=1200, data=ClientHello[0:1200])
包2: CRYPTO(offset=1200, length=1200, data=ClientHello[1200:2400])
包3: CRYPTO(offset=2400, length=600,  data=ClientHello[2400:3000])
```

接收端按 offset 排序重组，即使包乱序也能正确处理。

---

## 6. 连接状态转换

QUIC 握手期间，连接状态经历以下转换：

```
                           +--> CLOSED <--+
                           |              |
  INITIAL                  |              |  <-- 收到 CLOSE_INITIATE frame
  + 发送/接收 Initial      |              |
  |                        v              |
  +--> HANDSHAKE  <--------+              |  <-- 接收 CONNECTION_CLOSE
  |  发送/接收 Handshake                 |
  |                        +--> DRAINING  |  <-- 进入 draining 状态
  +--> CONFIRMED  <--------+              |
  |  收到 1-RTT 数据                     |
  |                                      |
  +--> 1-RTT 状态  <---------------------+
  |  加密传输可用
```

> [!tip] HANDSHAKE 与 CONFIRMED 状态
> **HANDSHAKE** 状态：正在完成 TLS 握手，尚未确认客户端和服务端的 0-RTT 密钥是否可用。
> **CONFIRMED** 状态：收到对端发送的 Handshake 包并确认其完整性，0-RTT 密钥已被对端确认可用。此前的 QUIC 实现中曾有"1-RTT"状态，后被 CONFIRMED 替代。

---

## 7. 包号空间与加密级别

QUIC 的三个包类型分别对应三个独立的包号空间（Packet Number Space）：

| 包类型      | 包号空间                   | 加密级别           | 密钥来源             |
| ----------- | -------------------------- | ------------------ | -------------------- |
| Initial     | `initial_number_space`     | Initial keys       | 派生于 SCID          |
| Handshake   | `handshake_number_space`   | Handshake keys     | 派生于 ServerHello   |
| 0-RTT/1-RTT | `application_number_space` | 0-RTT / 1-RTT keys | 派生于 master secret |

每个包号空间从 0 开始独立计数。这意味着同一个 Connection ID 下可能有三个包号都为 0 的包，分别属于三个不同的包号空间。

> [!warning] 包号空间隔离的意义
> 包号空间隔离防止了不同加密级别的包之间的混淆攻击。即使攻击者能够重放某个包，也不可能将其插入到错误的密钥级别中。

---

## 8. 重传与确认机制

握手过程中丢包的处理：

```
场景：客户端 Initial 包丢失

Client                          Server
  |                               |
  | Initial[ClientHello] -X->     |  (丢失)
  |                               |
  | [等待 ACK，超时后重传]          |
  |                               |
  | Initial[ClientHello] ───────> |  (重传)
  | [收到 Initial ACK 后，发送     |
  |   Handshake 包]               |
```

### 8.1 握手的超时与重传

QUIC 对握手包使用独立的超时与重传策略：

- **Initial 包超时**：首次超时通常为 `2 * kGranularity`（约 1ms），后续超时时间指数退避
- **Handshake 包超时**：使用 PTO（Probe Timeout）机制触发 probe 包发送
- **重传触发**：包丢失或 ACK 超时触发重传

### 8.2 丢包对握手延迟的影响

| 丢包位置                      | 影响           | 延迟增加           |
| ----------------------------- | -------------- | ------------------ |
| 第一个 Initial                | 1-RTT 延迟加倍 | +1 RTT             |
| 服务端 Initial（ServerHello） | 握手无法完成   | +2 RTT（超时重传） |
| Handshake 包                  | 密钥确认延迟   | +1 RTT（probe）    |

---

## 9. 握手中的地址验证

QUIC 在握手期间进行地址验证，防止放大攻击和地址欺骗。

### 9.1 客户端地址验证

服务端可以在 Initial 包中携带 Token（无状态 Cookie），后续连接中的 Initial 包必须携带此 Token：

```
首次连接（无 Token）:
  Client  --> Initial[ClientHello, SCID=cid_a]
  Server  <-- Initial[Token="cookie", SCID=cid_b]

后续连接（携带 Token）:
  Client  --> Initial[ClientHello, Token="cookie", SCID=cid_c]
  Server  <-- Initial[...]
```

### 9.2 PATH_CHALLENGE 与 PATH_RESPONSE

握手完成后，QUIC 使用 PATH_CHALLENGE/RESPONSE 帧进行路径验证：

```
Client                          Server
  |                               |
  | 发送 1-RTT PATH_CHALLENGE     |
  |  (随机数据 R)                 |
  |                               |
  | <-- 1-RTT PATH_RESPONSE(R)   |
  |    验证成功，路径有效          |
```

---

## 10. 小结与参考

本章的核心要点：

1. **三阶段握手**：Initial → Handshake → 1-RTT，每阶段使用不同密钥
2. **密钥派生**：TLS master secret 派生出多个级别的手shake traffic secret 和 application traffic secret
3. **CRYPTO 帧**：TLS 消息通过 CRYPTO 帧传输，支持 offset 分片
4. **包号空间隔离**：三个独立包号空间防止混淆攻击
5. **握手机制**：超时重传、PTO、地址验证

### 参考资料

- [RFC 9000 - QUIC: A UDP-Based Multiplexed and Secure Transport](https://www.rfc-editor.org/rfc/rfc9000)
- [RFC 9001 - QUIC TLS](https://www.rfc-editor.org/rfc/rfc9001)
- [RFC 8446 - TLS 1.3](https://www.rfc-editor.org/rfc/rfc8446)
- [QUIC-Wireshark dissector](https://github.com/quicwg/wireshark)
