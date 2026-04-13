---
title: "DPDK 深度探索 ch37：TLS/DTLS 加速"
date: 2026-04-10 14:00:00
tags: [dpdk, tls, dtls, ssl, openssl, crypto, offload, session]
description: "深入解析 DPDK TLS/DTLS 加速：SSL/TLS 协议、OpenSSL 引擎、DPDK Crypto 与 mTLS 应用"
---

# DPDK 深度探索 ch37：TLS/DTLS 加速

> [!abstract] 核心要点
> TLS 是应用层安全标准。DPDK 可加速 TLS/DTLS 处理，本章深入解析 TLS 协议、OpenSSL 引擎、Cryptodev 集成与 mTLS 应用。

## 1. TLS 概述

### 1.1 TLS 协议栈

```
┌─────────────────────────────────────────────────────────────┐
│                    TLS 协议栈                               │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              Application Data                         │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              TLS Record Layer                         │  │
│  │                                                       │  │
│  │  ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐      │  │
│  │  │ Hand-  │ │ Change │ │Alert   │ │ App    │      │  │
│  │  │ shake  │ │Cipher  │ │        │ │ Data   │      │  │
│  │  └────────┘ └────────┘ └────────┘ └────────┘      │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              TCP/IP                                   │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 TLS 版本

| 版本 | 年份 | 状态 |
|------|------|------|
| SSL 2.0 | 1994 | 已废弃 |
| SSL 3.0 | 1996 | 已废弃 |
| TLS 1.0 | 1999 | 已废弃 |
| TLS 1.1 | 2006 | 已废弃 |
| TLS 1.2 | 2008 | 广泛使用 |
| TLS 1.3 | 2018 | 推荐使用 |

## 2. TLS Handshake

### 2.1 TLS 1.2 Handshake

```
┌─────────────────────────────────────────────────────────────┐
│                    TLS 1.2 Handshake                       │
│                                                              │
│  Client                              Server                 │
│    │                                    │                   │
│    │  ① ClientHello ─────────────────▶ │                   │
│    │        (支持的算法列表)             │                   │
│    │                                    │                   │
│    │  ② ◀─────────── ServerHello      │                   │
│    │        (选定的算法)               │                   │
│    │                                    │                   │
│    │  ③ ◀─────── Certificate         │                   │
│    │        (服务器证书)               │                   │
│    │                                    │                   │
│    │  ④ ◀── ServerKeyExchange        │                   │
│    │        (DH 参数)                  │                   │
│    │                                    │                   │
│    │  ⑤ ◀────── CertificateRequest  │  (可选)            │
│    │                                    │                   │
│    │  ⑥ ◀──────── ServerHelloDone   │                   │
│    │                                    │                   │
│    │  ⑦ ClientKeyExchange ──────────▶│                   │
│    │        (PreMasterSecret)         │                   │
│    │                                    │                   │
│    │  ⑧ ChangeCipherSpec ──────────▶│                   │
│    │  ⑨ Finished ──────────────────▶│                   │
│    │                                    │                   │
│    │  ⑩ ◀──────── ChangeCipherSpec │                   │
│    │  ⑪ ◀─────────── Finished      │                   │
│    │                                    │                   │
│    │ ═══════════ App Data ═══════════ │                   │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 TLS 1.3 简化握手

```
TLS 1.3 握手 (1-RTT):

Client                              Server
  │
  │  ClientHello
  │  (key_share)
  │──────────────────────────────▶│
  │                               │
  │                   ServerHello
  │                   (key_share)
  │                   {EncryptedExtensions}
  │                   {Certificate}
  │                   {CertificateVerify}
  │                   {Finished}
  │◀──────────────────────────────│
  │
  │  {Finished}
  │──────────────────────────────▶│
  │
  ═══════════════ App Data ═══════════════

TLS 1.3 vs 1.2:
  - 减少到 1-RTT (1.2 是 2-RTT)
  - 0-RTT 支持 (reconnection)
```

## 3. OpenSSL 引擎

### 3.1 OpenSSL 引擎架构

```
┌─────────────────────────────────────────────────────────────┐
│                    OpenSSL Engine                           │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              OpenSSL API                              │  │
│  │  - EVP interface                                    │  │
│  │  - SSL/TLS connection                               │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              Engine (软件实现)                         │  │
│  │  - openssl (默认)                                   │  │
│  │  - gost (俄罗斯算法)                                │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              Hardware (DPDK/Cryptodev)                │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 DPDK Engine

```bash
# 安装 DPDK crypto 引擎
cd dpdk
make -C crypto/dpaa2_sec install

# 配置 OpenSSL 使用 DPDK
# /etc/ssl/openssl.cnf
openssl_conf = openssl_init

[openssl_init]
engines = engine_section

[engine_section]
dpaa2_sec = dpaa2_sec_section

[dpaa2_sec_section]
dynamic_id = dynamic_section
default_algorithms = ALL
init = 1
```

### 3.3 OpenSSL + Cryptodev

```c
// OpenSSL 配置 Cryptodev
#include <openssl/engine.h>
#include <openssl/evp.h>

static int
setup_openssl_crypto(void)
{
    // 加载 DPDK 引擎
    ENGINE_load_dpdk();

    // 获取引擎
    ENGINE *e = ENGINE_by_id("dpdk");
    if (!e)
        return -1;

    // 初始化引擎
    if (!ENGINE_init(e))
        return -1;

    // 设置为默认
    ENGINE_set_default(e, ENGINE_METHOD_ALL);

    return 0;
}

// 使用 OpenSSL TLS
int
tls_connection(SSL_CTX *ctx, int fd)
{
    SSL *ssl = SSL_new(ctx);
    SSL_set_fd(ssl, fd);

    // 使用硬件加速
    SSL_set_cipher_list(ssl, "AES256-GCM-SHA384");

    // TLS 握手
    if (SSL_accept(ssl) <= 0)
        return -1;

    // 发送数据
    SSL_write(ssl, data, len);

    return 0;
}
```

## 4. DTLS

### 4.1 DTLS vs TLS

```
DTLS (Datagram TLS)：

┌─────────────────────────────────────────────────────────────┐
│                    TLS vs DTLS                             │
│                                                              │
│  TLS:                                                       │
│  - 基于 TCP                                                │
│  - 顺序可靠                                               │
│  - 重传机制                                               │
│                                                              │
│  DTLS:                                                      │
│  - 基于 UDP                                                │
│  - 可能丢包                                               │
│  - 可能乱序                                               │
│  - 需要处理                                              │
│                                                              │
│  应用：                                                     │
│  - DTLS: VoIP, VPN, WebRTC                               │
│  - TLS: HTTP, SMTP, etc.                                 │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 DTLS 处理

```c
// DTLS 记录
struct dtls_record {
    uint8_t type;           // content type
    uint16_t version;        // DTLS version
    uint16_t epoch;          // 计数器
    uint48_t sequence_number;// 序列号
    uint16_t length;         // 长度
    uint8_t fragments[];    // 数据
};
```

## 5. mTLS

### 5.1 mTLS 流程

```
┌─────────────────────────────────────────────────────────────┐
│                    mTLS 双向认证                           │
│                                                              │
│  Client                              Server                 │
│    │                                    │                   │
│    │  ① ClientHello ─────────────────▶ │                   │
│    │                                    │                   │
│    │  ② ◀─────── ServerCertificate    │                   │
│    │                                    │                   │
│    │  ③ ClientCertificate ────────────▶│  (客户端证书)      │
│    │                                    │                   │
│    │  ④ CertificateVerify ────────────▶│  (签名验证)        │
│    │                                    │                   │
│    │  ⑤ ◀────────── ServerHello      │                   │
│    │  ⑥ ◀────── CertificateRequest  │  (请求客户端证书)   │
│    │  ⑦ ◀──────── ServerHelloDone   │                   │
│    │                                    │                   │
│    │  ⑧ ClientKeyExchange ──────────▶│                   │
│    │  ⑨ ◀─────────── Finished      │                   │
│    │                                    │                   │
│    ═══════════════ App Data ══════════════════           │
└─────────────────────────────────────────────────────────────┘
```

### 5.2 证书验证

```c
// 证书验证
int
verify_certificate(X509 *cert, X509_STORE *ca_store)
{
    // 创建验证上下文
    X509_STORE_CTX *ctx = X509_STORE_CTX_new();

    X509_STORE_CTX_init(ctx, ca_store, cert, NULL);

    // 验证链
    if (X509_verify_cert(ctx) <= 0) {
        int err = X509_STORE_CTX_get_error(ctx);
        fprintf(stderr, "Certificate verify failed: %s\n",
                X509_verify_cert_error_string(err));
        X509_STORE_CTX_free(ctx);
        return -1;
    }

    X509_STORE_CTX_free(ctx);
    return 0;
}
```

## 6. 性能优化

### 6.1 TLS 性能

```
TLS 处理开销：

1. Handshake
   - RSA/ECDHE 密钥交换
   - 证书验证
   - ~1-10ms (软件)
   - ~0.1-1ms (硬件)

2. Record Layer
   - AES-GCM 加密
   - SHA256 HMAC
   - ~10-20 cycles/byte (软件)
   - ~1-2 cycles/byte (硬件)
```

### 6.2 批量处理

```c
// TLS 批量加密
int
tls_batch_encrypt(struct rte_mbuf **mbufs, int n)
{
    struct rte_crypto_op *ops[32];

    // 批量分配 op
    for (int i = 0; i < n && i < 32; i++) {
        ops[i] = rte_crypto_op_alloc(crypto_pool,
            RTE_CRYPTO_OP_TYPE_SYMMETRIC);

        ops[i]->sym->session = tls_session;
        ops[i]->sym->m_src = mbufs[i];

        // 设置加密参数
        ops[i]->sym->cipher.data.offset = TLS_HEADER_LEN;
        ops[i]->sym->cipher.data.length =
            rte_pktmbuf_data_len(mbufs[i]) - TLS_HEADER_LEN;
    }

    // 批量提交
    uint16_t nb_enq = rte_cryptodev_enqueue_burst(dev_id,
        0, ops, n);

    return nb_enq;
}
```

## 7. 总结

TLS 加速：

```
┌─────────────────────────────────────────────────────────────┐
│                    TLS 加速方案                             │
│                                                              │
│  1. Cryptodev 卸载                                          │
│     - QAT AES-NI                                           │
│     - OpenSSL 引擎                                         │
│                                                              │
│  2. Session 复用                                            │
│     - TLS Session Tickets                                 │
│     - 避免完整握手                                         │
│                                                              │
│  3. 批量处理                                                │
│     - 聚合多个 record                                     │
│     - Pipeline                                             │
│                                                              │
│  4. 0-RTT (TLS 1.3)                                        │
│     - Early data                                           │
│     - 重放风险需注意                                       │
└─────────────────────────────────────────────────────────────┘
```

性能对比：

| 方案 | handshake/s | throughput |
|------|-------------|------------|
| **OpenSSL (软件)** | ~500 | ~1 Gbps |
| **AESNI** | ~2000 | ~5 Gbps |
| **QAT** | ~5000 | ~20 Gbps |

---

## 参考资源

- [OpenSSL](https://www.openssl.org/)
- [RFC 5246 (TLS 1.2)](https://tools.ietf.org/html/rfc5246)
- [RFC 8446 (TLS 1.3)](https://tools.ietf.org/html/rfc8446)
