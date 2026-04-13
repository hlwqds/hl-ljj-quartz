---
title: "VPP 深入探讨 ch15：IPsec 加密"
date: 2026-04-10 01:30:00
tags: [vpp, ipsec, cryptography, ikev2, esp, ah, crypto-engine, tls]
description: "深入解析 VPP IPsec：ESP/AH 协议、IKEv2 协商、crypto engine、硬件加速与 IPsec 隧道配置"
---

# VPP 深入探讨 ch15：IPsec 加密

> [!abstract] 核心要点
> IPsec 提供端到端加密。本章深入解析 ESP/AH 协议、IKEv2 协商、crypto engine、硬件加速与 IPsec 隧道配置。

## 1. IPsec 概述

### 1.1 IPsec 组件

```
┌─────────────────────────────────────────────────────────────┐
│                    IPsec 组件                              │
│                                                              │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐       │
│  │     AH      │  │    ESP      │  │    IKEv2    │       │
│  │ Authentication│ │ Encryption  │  │   Key      │       │
│  │   Header    │  │ +Auth       │  │  Exchange   │       │
│  └─────────────┘  └─────────────┘  └─────────────┘       │
│                                                              │
│  模式：                                                      │
│  - Transport Mode: 仅加密 payload                           │
│  - Tunnel Mode:   加密整个 IP 包                            │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 AH vs ESP

```
┌─────────────────────────────────────────────────────────────┐
│                    AH vs ESP                                │
│                                                              │
│  AH (Authentication Header):                               │
│  ┌─────────┬─────────┬─────────────────────────┐           │
│  │  Next   │  AH     │                         │           │
│  │  Header │  Length │     SPI + Sequence     │           │
│  └─────────┴─────────┴─────────────────────────┘           │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                 Authentication Data                   │   │
│  │                    (ICV)                              │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                              │
│  AH 提供：                                                   │
│  - 数据完整性验证                                           │
│  - 抗重放攻击                                               │
│  - 不加密数据                                               │
│                                                              │
│  ESP (Encapsulating Security Payload):                     │
│  ┌─────────┬─────────┬─────────────────────────┐           │
│  │  SPI    │ Sequence│                         │           │
│  └─────────┴─────────┴─────────────────────────┘           │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              Payload (加密)                          │   │
│  │                                                       │   │
│  └─────────────────────────────────────────────────────┘   │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              Authentication (可选)                   │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                              │
│  ESP 提供：                                                  │
│  - 数据机密性（加密）                                        │
│  - 数据完整性验证                                           │
│  - 抗重放攻击                                               │
└─────────────────────────────────────────────────────────────┘
```

## 2. ESP 协议

### 2.1 ESP 格式

```
┌─────────────────────────────────────────────────────────────┐
│                    ESP 封装格式                             │
│                                                              │
│  Tunnel Mode ESP:                                          │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  Outer IP Header                                      │  │
│  ├───────────────────────────────────────────────────────┤  │
│  │  ESP Header                                           │  │
│  │  ┌─────────┬─────────┐                              │  │
│  │  │   SPI   │ Sequence │                              │  │
│  │  └─────────┴─────────┘                              │  │
│  ├───────────────────────────────────────────────────────┤  │
│  │  Inner IP Header (加密)                               │  │
│  ├───────────────────────────────────────────────────────┤  │
│  │  TCP/UDP Header (加密)                                │  │
│  ├───────────────────────────────────────────────────────┤  │
│  │  Payload Data (加密)                                  │  │
│  ├───────────────────────────────────────────────────────┤  │
│  │  Padding + Pad Length + Next Header (加密)           │  │
│  ├───────────────────────────────────────────────────────┤  │
│  │  ESP Trailer                                          │  │
│  │  ┌───────────────────┐                               │  │
│  │  │ Auth Data (ICV)   │ ← 可选                         │  │
│  │  └───────────────────┘                               │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 ESP 处理

```c
// ESP 加密
static_always_inline void
esp_encrypt(vlib_buffer_t *b,
            esp_header_t *esp,
            ipsec_sa_t *sa)
{
    // 1. 生成 IV (如果需要)
    if (sa->crypto_algo->iv_size > 0) {
        generate_random_bytes(esp->iv, sa->crypto_algo->iv_size);
    }

    // 2. 加密 payload
    crypto_ops->encrypt(
        sa->crypto_algo,
        sa->key, sa->key_len,
        esp->iv,
        &esp->payload, esp->payload_len);

    // 3. 计算 ICV (如果启用)
    if (sa->integrity_algo) {
        crypto_ops->icv_compute(
            sa->integrity_algo,
            sa->integrity_key,
            esp, esp_full_len,
            esp->icv);
    }

    // 4. 递增 Sequence
    sa->seq++;
}

// ESP 解密
static_always_inline int
esp_decrypt(vlib_buffer_t *b,
            esp_header_t *esp,
            ipsec_sa_t *sa)
{
    // 1. 检查 Sequence (抗重放)
    if (!seq_check(sa, esp->sequence)) {
        return -1;  // 重放攻击
    }

    // 2. 验证 ICV (如果启用)
    if (sa->integrity_algo) {
        if (!icv_verify(sa, esp)) {
            return -1;  // 验证失败
        }
    }

    // 3. 解密
    crypto_ops->decrypt(
        sa->crypto_algo,
        sa->key, sa->key_len,
        esp->iv,
        &esp->payload, esp->payload_len);

    // 4. 更新 SA
    sa->seq = esp->sequence;
    sa->last_used = now;

    return 0;
}
```

## 3. IKEv2 协商

### 3.1 IKEv2 消息

```
┌─────────────────────────────────────────────────────────────┐
│                    IKEv2 交换                              │
│                                                              │
│  Phase 1 (ISAKMP SA):                                       │
│                                                              │
│  Initiator                                        Responder │
│     │                                                  │    │
│     │  HDR, SAi1, KEi, Ni          →                   │    │
│     │                                                  │    │
│     │                          ←  HDR, SAr1, KEr, Nr  │    │
│     │                                                  │    │
│     │  HDR, SK{IDi, CERT, AUTH}   →                   │    │
│     │                                                  │    │
│     │                          ←  HDR, SK{IDr, CERT}  │    │
│     │                                                  │    │
│     │  HDR, SK{AUTH, CP(t)}      →                   │    │
│     │                                                  │    │
│     │                          ←  HDR, SK{AUTH, CP(t)} │    │
│     │                                                  │    │
│     ================== CHILD SA ======================     │
│                                                              │
│  Phase 2 (CHILD SA / ESP SA):                               │
│                                                              │
│     │  HDR, SK{SA, TSi, TSr}      →                      │    │
│     │                                                  │    │
│     │                          ←  HDR, SK{SA, TSi, TSr}  │    │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 IKEv2 实现

```c
// IKEv2 SA
typedef struct {
    u8 spi[8];             // IKE SPI
    u8 cookies[2][8];       // 消息 Cookie

    // 加密算法
    u32 crypto_algo;
    u8 *crypto_key;

    // 完整性算法
    u32 integrity_algo;
    u8 *integrity_key;

    // DH 组
    u32 dh_group;
    u8 *dh_private;
    u8 *dh_public;

    // Nonces
    u8 *Ni;
    u8 *Nr;

    // 状态
    u8 state;
} ikev2_sa_t;

// IKEv2 协商处理
static void
ikev2_process_auth_request(ikev2_sa_t *sa,
                            ikev2_packet_t *pkt)
{
    // 1. 验证身份
    if (!ikev2_verify_auth(sa, pkt)) {
        ikev2_send_auth_failure(pkt);
        return;
    }

    // 2. 生成 DH 共享密钥
    u8 *shared_secret = dh_compute(
        sa->dh_private, pkt->dh_public, sa->dh_group);

    // 3. 派生密钥材料
    u8 *keymat = prf_plus(sa->prf_algo,
                         shared_secret,
                         sa->Ni, sa->Nr,
                         "Key generation for ESP SA");

    // 4. 创建 CHILD SA (ESP SA)
    ipsec_sa_t *esp_sa = ipsec_sa_create();
    esp_sa->crypto_algo = sa->esp_crypto;
    esp_sa->integrity_algo = sa->esp_integrity;
    memcpy(esp_sa->key, keymat, KEY_SIZE);

    // 5. 发送响应
    ikev2_send_auth_response(sa, esp_sa);
}
```

## 4. Crypto Engine

### 4.1 Crypto 操作抽象

```c
// Crypto 算法操作
struct crypto_alg_ops {
    // 加密
    int (*encrypt)(struct crypto_algo *algo,
                   u8 *key, u32 key_len,
                   u8 *iv,
                   u8 *src, u8 *dst, u32 len);

    // 解密
    int (*decrypt)(struct crypto_algo *algo,
                   u8 *key, u32 key_len,
                   u8 *iv,
                   u8 *src, u8 *dst, u32 len);

    // ICV 计算
    int (*icv_compute)(struct crypto_algo *algo,
                       u8 *key,
                       u8 *data, u32 len,
                       u8 *icv);

    // ICV 验证
    int (*icv_verify)(struct crypto_algo *algo,
                      u8 *key,
                      u8 *data, u32 len,
                      u8 *expected_icv);
};
```

### 4.2 支持的算法

```c
// 支持的加密算法
enum crypto_algo {
    CRYPTO_ALGO_AES_CBC_128,
    CRYPTO_ALGO_AES_CBC_192,
    CRYPTO_ALGO_AES_CBC_256,
    CRYPTO_ALGO_AES_GCM_128,
    CRYPTO_ALGO_AES_GCM_192,
    CRYPTO_ALGO_AES_GCM_256,
    CRYPTO_ALGO_3DES_CBC,
    CRYPTO_ALGO_CHACHA20_POLY1305,
};

// 支持的完整性算法
enum integrity_algo {
    INTEGRITY_ALGO_SHA1_96,    // HMAC-SHA1 (truncated)
    INTEGRITY_ALGO_SHA256_128, // HMAC-SHA256 (truncated)
    INTEGRITY_ALGO_SHA384_192, // HMAC-SHA384 (truncated)
    INTEGRITY_ALGO_SHA512_256, // HMAC-SHA512 (truncated)
};
```

### 4.3 OpenSSL 集成

```c
// 使用 OpenSSL 的实现
static int
openssl_encrypt_aes_cbc(crypto_algo_t *algo,
                        u8 *key, u32 key_len,
                        u8 *iv,
                        u8 *src, u8 *dst, u32 len)
{
    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    const EVP_CIPHER *cipher;

    switch (key_len) {
    case 16: cipher = EVP_aes_128_cbc(); break;
    case 24: cipher = EVP_aes_192_cbc(); break;
    case 32: cipher = EVP_aes_256_cbc(); break;
    default: return -1;
    }

    EVP_DecryptInit_ex(ctx, cipher, NULL, key, iv);
    EVP_DecryptUpdate(ctx, dst, &len, src, len);
    EVP_DecryptFinal_ex(ctx, dst + len, &len);

    EVP_CIPHER_CTX_free(ctx);
    return 0;
}
```

## 5. IPsec 配置

### 5.1 IKEv2 Profile

```bash
# 创建 IKEv2 profile
vpp# ipsecikev2 profile add name profile1

# 配置认证
vpp# ipsecikev2 profile set name profile1 \
    auth method rsa-sig \
    certificate my_cert \
    key my_key

# 配置加密算法
vpp# ipsecikev2 profile set name profile1 \
    encryption aes-gcm-256 \
    integrity sha512 \
    dh-group 20

# 配置本地/远程 ID
vpp# ipsecikev2 profile set name profile1 \
    local-id fqdn gateway.example.com \
    remote-id ipv4 203.0.113.1
```

### 5.2 IPsec SA

```bash
# 创建 IPsec SA
vpp# ipsec sa add name sa1 \
    esp encryption aes-gcm-256 \
    esp integrity sha512 \
    local-spi 1000 \
    remote-spi 2000 \
    tunnel local 203.0.113.10 remote 203.0.113.1

# 静态 SPI 配置
vpp# ipsec sa add name sa1 \
    esp aes-gcm-256 \
    local-spi 0x1000 \
    remote-spi 0x2000 \
    crypto-key hex 0123456789abcdef... \
    integrity-key hex abcdef0123456789...
```

### 5.3 IPsec 隧道

```bash
# 创建 IPsec tunnel
vpp# ipsec tunnel add name tunnel1 \
    remote 203.0.113.1 \
    local 203.0.113.10 \
    sa sa1

# 将 tunnel 绑定到接口
vpp# set interface ip addr ipsec_tunnel0 10.0.0.1/24

# 查看 IPsec
vpp# show ipsec
vpp# show ipsec sa
vpp# show ipsec tunnel
```

## 6. 硬件加速

### 6.1 Crypto Engine 抽象

```
VPP 通过抽象层支持硬件加速：

┌─────────────────────────────────────────────────────────────┐
│                    Crypto 抽象层                             │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              VPP IPsec                                │  │
│  └──────────────────────────────────────────────────────┘  │
│                         ↓                                    │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              Crypto Ops (软件)                        │  │
│  └──────────────────────────────────────────────────────┘  │
│                         ↓                                    │
│  ┌──────────────┬────────────────┬────────────────────┐   │
│  │  OpenSSL     │  Intel QuickAssist│  Cavium NITROX │   │
│  │  (AES-NI)   │   (QAT)        │    (Via)          │   │
│  └──────────────┴────────────────┴────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 6.2 Intel QAT 加速

```c
// QAT 设备
struct qat_device {
    int fd;                    // /dev/crypto_qat
    u32 num_engines;          // QAT 引擎数

    // 作业队列
    struct qat_queue {
        u32 head;
        u32 tail;
        u32 size;
        struct qat_job *jobs;
    } *queues;
};

// QAT 加密操作
static int
qat_encrypt(struct qat_device *dev,
            u8 *key, u32 key_len,
            u8 *iv,
            u8 *src, u8 *dst, u32 len)
{
    // 1. 分配 QAT 作业
    struct qat_job *job = qat_alloc_job(dev);

    // 2. 配置作业
    job->cmd = QAT_CMD_ENCRYPT;
    job->cipher_algo = QAT_ALGO_AES_GCM;
    job->key = key;
    job->iv = iv;
    job->src = src;
    job->dst = dst;
    job->len = len;

    // 3. 提交到 QAT
    qat_submit_job(dev, job);

    // 4. 等待完成（或使用轮询）
    qat_wait_done(job);

    return 0;
}
```

### 6.3 AES-NI

```
AES-NI 是 CPU 内置的加密指令集：

指令：
- AESENC: 执行一轮 AES 加密
- AESENCLAST: 最后一轮
- AESDEC: 执行一轮 AES 解密
- AESDECLAST: 最后一轮解密
- AESKEYGENASSIST: 密钥扩展

性能（单核）：
- AES-128-GCM: ~3 GB/s
- AES-256-GCM: ~2.5 GB/s

VPP 自动检测并使用 AES-NI
```

## 7. NAT-T (NAT Traversal)

### 7.1 NAT-T 原理

```
NAT-T 允许 ESP 穿越 NAT：

问题：ESP 没有端口号，NAT 无法关联进出流量

解决：UDP 封装 ESP

┌─────────────────────────────────────────────────────────────┐
│                    NAT-T 封装                               │
│                                                              │
│  正常 ESP:                                                  │
│  [IP][ESP][Payload]                                        │
│                                                              │
│  NAT-T ESP:                                                 │
│  [IP][UDP:4500][ESP][Payload]                              │
│                      ↑                                      │
│                 NAT-T 标记                                  │
│                                                              │
│  NAT-T 使用 UDP 端口 4500                                  │
└─────────────────────────────────────────────────────────────┘
```

### 7.2 NAT-T 配置

```bash
# 启用 NAT-T
vpp# ipsec nat-t enable

# 配置 NAT-T 端口
vpp# set ipsec nat-t port 4500

# 查看 NAT-T
vpp# show ipsec nat-t
```

## 8. 性能调优

### 8.1 多核扩展

```
IPsec 性能瓶颈：
- 加密计算 (CPU bound)
- 密钥查找 (Memory bound)
- 包重组 (Latency)

多核扩展：
- 每个 worker 独立 SA
- SA 绑定到特定 CPU
- RSS 分散加密负载
```

### 8.2 配置优化

```bash
# 使用 AES-GCM (比 CBC+HMAC 快)
vpp# ipsec sa set name sa1 \
    esp encryption aes-gcm-256 \
    esp integrity none  # GCM 自带认证

# 启用批量处理
vpp# ipsec select buffer-size 64

# 查看 IPsec 统计
vpp# show ipsec stats
```

## 9. 总结

IPsec 组件：

| 组件 | 功能 | 关键点 |
|------|------|--------|
| **AH** | 认证 | 数据完整性，无加密 |
| **ESP** | 加密+认证 | 加密 payload，可选 ICV |
| **IKEv2** | 密钥交换 | 自动密钥管理 |
| **NAT-T** | NAT 穿越 | UDP 封装 |

ESP 模式：

```
Transport Mode:
  [IP][ESP][Data]         ← 仅加密 payload

Tunnel Mode:
  [New IP][ESP][Old IP][Data]  ← 加密整个包
```

加密算法选择：

```
推荐：
- AES-GCM-256: 加密+认证，最安全
- ChaCha20-Poly1305: 移动设备省电

避免：
- 3DES: 慢，有弱点
- AES-CBC: 需要单独 HMAC
```

---

## 参考资源

- [RFC 4303 - ESP](https://tools.ietf.org/html/rfc4303)
- [RFC 7296 - IKEv2](https://tools.ietf.org/html/rfc7296)
- [VPP IPsec](https://wiki.fd.io/view/VPP/IPsec)
- [Intel AES-NI](https://www.intel.com/content/www/us/en/architecture-and-technology/advanced-encryption-standard-aes/data-protection-aes-architecture-book.html)
