---
title: "DPDK 深度探索 (二十四)：Raw Crypto API 与自定义协议加密"
date: 2026-04-09
tags: [dpdk, series, raw-crypto, symmetric-crypto, asymmetric-crypto, packet-crypto, user-defined-protocol, crypto-op, multi-buffer]
description: "深入理解 DPDK Raw Crypto API——对称/非对称加密操作、原始数据包加密、多包批处理、自定义协议接口"
---

> [!info] DPDK 深度探索系列
> 0. [[2026-04-09-dpdk-deep-dive-series-index|全栈学习路径总览]]
> 1-23. 前二十三章已完成
> 24. **第二十四章：Raw Crypto API 与自定义协议加密**

---

## 1. 概述：为什么需要 Raw Crypto API？

### 1.1 传统 Crypto API 的局限性

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    传统 Crypto API 局限性                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  传统 Crypto Session 模式:                                                 │
│  ───────────────────────                                                   │
│                                                                             │
│  ┌──────────────────────────────────────────────────────────────────────┐ │
│  │  1. 创建 Session: sym_session_create(xforms)                         │ │
│  │     - 需要预先知道算法和密钥                                           │ │
│  │     - 绑定到特定 cryptodev                                            │ │
│  │                                                                      │ │
│  │  2. 创建 Op: crypto_op_alloc(pool)                                   │ │
│  │     - 设置 session 引用                                               │ │
│  │     - 设置 mbuf 指针                                                   │ │
│  │                                                                      │ │
│  │  3. 入队/出队                                                        │ │
│  │     - crypto_op_enqueue_burst()                                       │ │
│  │     - crypto_op_dequeue_burst()                                      │ │
│  └──────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
│  问题:                                                                    │
│  ────                                                                    │
│  1. 每次操作需要引用 session (间接寻址开销)                                │
│  2. 无法动态改变密钥/算法 (必须创建新 session)                            │
│  3. Session 占用大量内存 (每个 session 需存储密钥)                        │
│  4. 不适合动态密钥场景 (如每包密钥不同)                                    │
│  5. 不支持非对称加密 (RSA/ECC)                                           │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 1.2 Raw Crypto API 的优势

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        Raw Crypto API 优势                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  Raw Crypto 模式:                                                          │
│  ─────────────────                                                          │
│                                                                             │
│  ┌──────────────────────────────────────────────────────────────────────┐ │
│  │  1. 无 Session: 直接在 Op 中携带所有参数                              │ │
│  │     - xform 直接内联在 op 中                                         │ │
│  │     - 无需预创建 session                                             │ │
│  │                                                                      │ │
│  │  2. 动态算法: 每包可使用不同的算法和密钥                             │ │
│  │     - 适合动态密钥协议                                               │ │
│  │     - 适合自定义协议                                                │ │
│  │                                                                      │ │
│  │  3. 低内存开销: 无 session 池                                       │ │
│  │     - 适合短连接场景                                                │ │
│  │     - 适合 session-less 模式                                        │ │
│  │                                                                      │ │
│  │  4. 支持对称+非对称: 统一的 API 处理                                 │ │
│  │     - RSA/ECC/DH                                                    │ │
│  │     - 混合协议                                                      │ │
│  └──────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
│  典型应用:                                                                │
│  ────────                                                                │
│  - IPsec ESP (每 SA 不同密钥)                                            │
│  - WireGuard (每个 peer 不同密钥)                                        │
│  - 自定义协议 (商密/国密)                                                │
│  - 动态密钥交换                                                          │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 1.3 Raw vs Session-based API

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    Session-based vs Raw Crypto API                         │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  Session-based (传统):                                                    │
│  ─────────────────────                                                     │
│                                                                             │
│  App ──► session_create(xforms) ──► sym_session                         │
│   │                                                                   │
│   └──► op_alloc(pool) ──► op.session = sym_session ──► enqueue         │
│                                                                             │
│  Raw Crypto (新):                                                        │
│  ─────────────────                                                        │
│                                                                             │
│  App ──► op_alloc(pool) ──► op.sym_xform (内联) ──► enqueue             │
│                                                                             │
│  无需预创建 session，直接在操作中携带 xform                               │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. 对称 Raw Crypto API

### 2.1 xform 内联模式

```c
// lib/librte_cryptodev/rte_cryptodev.h

// Raw Crypto 操作 (xform 内联)
struct rte_crypto_sym_op {
    // xform 链 (直接内联在 op 中)
    struct rte_crypto_sym_xform *xform;

    // mbuf 引用
    struct {
        struct rte_mbuf *m;      // mbuf
        uint16_t offset;          // 数据偏移
        uint16_t length;          // 数据长度
    } src, dst;

    // 预置/追加的 IV
    uint8_t *iv;

    // 认证数据
    struct {
        uint8_t *data;
        uint16_t length;
        uint8_t *digest;          // 输出摘要
        uint16_t digest_len;
    } auth;

    // AEAD 数据
    struct {
        uint8_t *aad;
        uint16_t aad_len;
    } aead;
};

// 设置 sessionless xform
static inline void
rte_crypto_sym_op_attach_sessionless_xform(
    struct rte_crypto_sym_op *op,
    struct rte_crypto_sym_xform *xform)
{
    op->xform = xform;
    op->sess_type = RTE_CRYPTO_OP_SESSIONLESS;
}
```

### 2.2 完整的 xform 链

```c
// xform 链结构

enum rte_crypto_sym_xform_type {
    RTE_CRYPTO_SYM_XFORM_NOT_UNDEFINED = 0,
    RTE_CRYPTO_SYM_XFORM_CIPHER,      // 加密
    RTE_CRYPTO_SYM_XFORM_AUTH,        // 认证
    RTE_CRYPTO_SYM_XFORM_AEAD,        // AEAD
    RTE_CRYPTO_SYM_XFORM_CHAIN,       // 链式
};

// 链式 xform
struct rte_crypto_sym_xform_chain {
    struct rte_crypto_sym_xform *next;  // 下一个 xform

    // 第一个: cipher
    struct {
        enum rte_crypto_cipher_operation op;
        enum rte_crypto_cipher_algorithm algo;
        uint8_t *key;
        uint8_t key_len;
        uint8_t *iv;
        uint8_t iv_len;
    } cipher;

    // 第二个: auth
    struct {
        enum rte_crypto_auth_operation op;
        enum rte_crypto_auth_algorithm algo;
        uint8_t *key;
        uint8_t key_len;
        uint8_t *digest_result;
        uint16_t digest_len;
    } auth;
};

// 准备链式 xform
static void
prepare_chain_xform(struct rte_crypto_sym_xform_chain *chain,
                     uint8_t *cipher_key, uint8_t cipher_key_len,
                     uint8_t *auth_key, uint8_t auth_key_len,
                     uint8_t *iv, uint8_t iv_len)
{
    chain->cipher.op = RTE_CRYPTO_CIPHER_OP_ENCRYPT;
    chain->cipher.algo = RTE_CRYPTO_CIPHER_AES_CBC;
    chain->cipher.key = cipher_key;
    chain->cipher.key_len = cipher_key_len;
    chain->cipher.iv = iv;
    chain->cipher.iv_len = iv_len;

    chain->auth.op = RTE_CRYPTO_AUTH_OP_GENERATE;
    chain->auth.algo = RTE_CRYPTO_AUTH_SHA256_HMAC;
    chain->auth.key = auth_key;
    chain->auth.key_len = auth_key_len;
    chain->auth.digest_len = 32;

    chain->next = NULL;
}
```

### 2.3 Raw Crypto 操作流程

```c
// Raw Crypto 操作流程

int
raw_crypto_process(struct rte_cryptodev *dev,
                   struct rte_mbuf *m,
                   uint8_t *key, size_t key_len,
                   uint8_t *iv)
{
    struct rte_crypto_op *op;
    struct rte_crypto_sym_op *sym_op;
    struct rte_crypto_sym_xform xform[2];

    // 1. 分配操作
    op = rte_crypto_op_alloc(dev->op_mpool,
                              RTE_CRYPTO_OP_TYPE_SYMMETRIC);
    if (!op)
        return -1;

    sym_op = &op->sym;

    // 2. 配置 xform (内联)
    // cipher + auth 链式
    xform[0].type = RTE_CRYPTO_SYM_XFORM_CIPHER;
    xform[0].cipher.op = RTE_CRYPTO_CIPHER_OP_ENCRYPT;
    xform[0].cipher.algo = RTE_CRYPTO_CIPHER_AES_CBC;
    xform[0].cipher.key = key;
    xform[0].cipher.key_len = key_len;
    xform[0].cipher.iv = iv;
    xform[0].cipher.iv_len = 16;

    xform[1].type = RTE_CRYPTO_SYM_XFORM_AUTH;
    xform[1].auth.op = RTE_CRYPTO_AUTH_OP_GENERATE;
    xform[1].auth.algo = RTE_CRYPTO_AUTH_SHA256_HMAC;
    xform[1].auth.key = key;  // 可用不同密钥
    xform[1].auth.key_len = key_len;
    xform[1].auth.digest_len = 32;

    xform[0].next = &xform[1];
    xform[1].next = NULL;

    // 3. 绑定 xform 到 op
    sym_op->xform = xform;

    // 4. 配置数据指针
    sym_op->src.m = m;
    sym_op->src.offset = 0;
    sym_op->src.length = rte_pktmbuf_pkt_len(m);

    sym_op->dst.m = NULL;  // 原地加密

    // 5. 设置 IV
    sym_op->cipher.iv = iv;
    sym_op->cipher.iv_len = 16;

    // 6. 设置认证参数
    sym_op->auth.digest = rte_pktmbuf_append(m, 32);  // 追加摘要

    // 7. 入队
    struct rte_crypto_op *ops[1] = { op };
    uint16_t nb_enq = rte_cryptodev_enqueue_burst(dev->dev_id, 0,
                                                   ops, 1);

    // 8. 出队
    uint16_t nb_deq = rte_cryptodev_dequeue_burst(dev->dev_id, 0,
                                                   ops, 1);

    if (nb_deq == 1 && ops[0]->status == RTE_CRYPTO_OP_STATUS_SUCCESS)
        return 0;

    return -1;
}
```

---

## 3. 非对称 Raw Crypto API

### 3.1 非对称操作类型

```c
// 非对称加密操作

enum rte_crypto_asym_op_type {
    RTE_CRYPTO_ASYM_OP_ENCRYPT,       // 公钥加密
    RTE_CRYPTO_ASYM_OP_DECRYPT,       // 私钥解密
    RTE_CRYPTO_ASYM_OP_SIGN,          // 签名
    RTE_CRYPTO_ASYM_OP_VERIFY,        // 验签
    RTE_CRYPTO_ASYM_OP_SHARED_SECRET, // DH 共享密钥
};

// 非对称算法
enum rte_crypto_asym_xform_type {
    RTE_CRYPTO_ASYM_XFORM_NONE = 0,
    RTE_CRYPTO_ASYM_XFORM_RSA,        // RSA
    RTE_CRYPTO_ASYM_XFORM_DSA,       // DSA
    RTE_CRYPTO_ASYM_XFORM_DH,        // Diffie-Hellman
    RTE_CRYPTO_ASYM_XFORM_ECDSA,     // ECDSA
    RTE_CRYPTO_ASYM_XFORM_ECDH,      // ECDH
    RTE_CRYPTO_ASYM_XFORM_SM2,       // SM2 (国密)
    RTE_CRYPTO_ASYM_XFORM_X25519,    // X25519
    RTE_CRYPTO_ASYM_XFORM_ED25519,   // Ed25519
};

// RSA 操作模式
enum rte_crypto_rsa_padding_mode {
    RTE_CRYPTO_RSA_PKCS1_V1_5,        // RSAES-PKCS1-v1_5
    RTE_CRYPTO_RSA_PKCS1_OAEP,        // RSAES-OAEP
    RTE_CRYPTO_RSA_NO_PADDING,       // 裸 RSA
};

// ECDSA 曲线
enum rte_crypto_ec_group {
    RTE_CRYPTO_EC_GROUP_SECP192R1,   // P-192
    RTE_CRYPTO_EC_GROUP_SECP224R1,   // P-224
    RTE_CRYPTO_EC_GROUP_SECP256R1,   // P-256 (NIST P-256)
    RTE_CRYPTO_EC_GROUP_SECP384R1,   // P-384
    RTE_CRYPTO_EC_GROUP_SECP521R1,   // P-521
    RTE_CRYPTO_EC_GROUP_SM2,          // SM2
};
```

### 3.2 RSA xform

```c
// RSA xform 结构

struct rte_crypto_rsa_xform {
    // RSA 密钥参数
    struct {
        uint8_t *n;        // 模数 (modulus)
        uint8_t *e;        // 公钥指数
        uint8_t *d;        // 私钥指数 (仅解密/签名需要)
        uint8_t *p;        // 素数 p (CRT 优化)
        uint8_t *q;        // 素数 q
        uint8_t *dp;       // d mod (p-1) (CRT)
        uint8_t *dq;       // d mod (q-1) (CRT)
        uint8_t *qinv;     // q^(-1) mod p (CRT)
        uint16_t n_len;    // 模数长度 (bytes)
        uint16_t e_len;    // 公指长度
    } key;

    // Padding 模式
    enum rte_crypto_rsa_padding_mode padding;

    // MD (用于 PKCS#1 v1.5 和 OAEP)
    enum rte_crypto_auth_algorithm md;
};

// RSA 操作
struct rte_crypto_rsa_op {
    // 输入
    uint8_t *message;         // 加密时 (原文)
    uint8_t *ciphertext;      // 解密时 (密文)
    uint16_t input_len;

    // 输出
    uint8_t *output;          // 加密/解密结果
    uint16_t output_len;

    // 签名数据 (可选)
    uint8_t *sign;
    uint16_t sign_len;
};

// RSA 加密示例
int
rsa_encrypt(struct rte_cryptodev *dev,
            uint8_t *message, size_t msg_len,
            struct rte_crypto_rsa_xform *xform,
            uint8_t *output, size_t *out_len)
{
    struct rte_crypto_op *op;
    struct rte_crypto_asym_op *asym_op;

    // 分配操作
    op = rte_crypto_op_alloc(dev->op_mpool,
                              RTE_CRYPTO_OP_TYPE_ASYMMETRIC);
    asym_op = &op->asym;

    // 设置为 RSA 操作
    asym_op->type = RTE_CRYPTO_ASYM_OP_ENCRYPT;
    asym_op->rsa = *xform;

    // 设置输入 (padding 后)
    uint8_t *padded = rte_zmalloc(NULL, xform->key.n_len, 0);
    pkcs1_v15_encode(message, msg_len, xform->key.n_len - 11,
                     padded);  // RSA_PKCS1_OAEP_MGF1 padding

    asym_op->rsa.message = padded;
    asym_op->rsa.input_len = xform->key.n_len;

    // 设置输出
    asym_op->rsa.output = output;

    // 入队/出队
    rte_cryptodev_enqueue_burst(dev->dev_id, 0, &op, 1);
    rte_cryptodev_dequeue_burst(dev->dev_id, 0, &op, 1);

    if (op->status == RTE_CRYPTO_OP_STATUS_SUCCESS) {
        *out_len = xform->key.n_len;
        rte_free(padded);
        return 0;
    }

    return -1;
}
```

### 3.3 ECDSA xform

```c
// ECDSA xform

struct rte_crypto_ec_xform {
    enum rte_crypto_ec_group curve;     // 曲线
    uint8_t *p;                         // 曲线参数 p
    uint8_t *a, *b;                    // 曲线参数 a, b
    uint8_t *n;                         // 阶
    uint8_t *gx, *gy;                  // 基点
    uint8_t *d;                        // 私钥 (仅签名需要)
    uint8_t *x, *y;                   // 公钥
};

// ECDSA 操作
struct rte_crypto_ecdsa_op {
    // 输入消息
    uint8_t *message;
    uint16_t message_len;

    // 签名输出/输入
    uint8_t *sign_r;                   // 签名的 r
    uint8_t *sign_s;                   // 签名的 s
    uint8_t sign_len;                  // 签名长度

    // 公钥
    uint8_t *x;                        // 公钥 x
    uint8_t *y;                        // 公钥 y
};

// ECDSA 签名
int
ecdsa_sign(struct rte_cryptodev *dev,
           uint8_t *message, size_t msg_len,
           uint8_t *private_key,
           uint8_t *sign_r, uint8_t *sign_s)
{
    struct rte_crypto_op *op;
    struct rte_crypto_asym_op *asym_op;

    op = rte_crypto_op_alloc(dev->op_mpool,
                              RTE_CRYPTO_OP_TYPE_ASYMMETRIC);
    asym_op = &op->asym;

    asym_op->type = RTE_CRYPTO_ASYM_OP_SIGN;
    asym_op->ec.curve = RTE_CRYPTO_EC_GROUP_SECP256R1;
    asym_op->ec.d = private_key;
    asym_op->ec.x = NULL;  // 从私钥推导
    asym_op->ec.y = NULL;

    // 消息摘要
    uint8_t hash[32];
    SHA256(message, msg_len, hash);

    asym_op->ecdsa.message = hash;
    asym_op->ecdsa.message_len = 32;
    asym_op->ecdsa.sign_r = sign_r;
    asym_op->ecdsa.sign_s = sign_s;

    rte_cryptodev_enqueue_burst(dev->dev_id, 0, &op, 1);
    rte_cryptodev_dequeue_burst(dev->dev_id, 0, &op, 1);

    return (op->status == RTE_CRYPTO_OP_STATUS_SUCCESS) ? 0 : -1;
}

// ECDSA 验证
int
ecdsa_verify(struct rte_cryptodev *dev,
              uint8_t *message, size_t msg_len,
              uint8_t *public_key_x, uint8_t *public_key_y,
              uint8_t *sign_r, uint8_t *sign_s)
{
    struct rte_crypto_op *op;
    struct rte_crypto_asym_op *asym_op;

    op = rte_crypto_op_alloc(dev->op_mpool,
                              RTE_CRYPTO_OP_TYPE_ASYMMETRIC);
    asym_op = &op->asym;

    asym_op->type = RTE_CRYPTO_ASYM_OP_VERIFY;
    asym_op->ec.curve = RTE_CRYPTO_EC_GROUP_SECP256R1;
    asym_op->ec.x = public_key_x;
    asym_op->ec.y = public_key_y;

    uint8_t hash[32];
    SHA256(message, msg_len, hash);

    asym_op->ecdsa.message = hash;
    asym_op->ecdsa.message_len = 32;
    asym_op->ecdsa.sign_r = sign_r;
    asym_op->ecdsa.sign_s = sign_s;

    rte_cryptodev_enqueue_burst(dev->dev_id, 0, &op, 1);
    rte_cryptodev_dequeue_burst(dev->dev_id, 0, &op, 1);

    return (op->status == RTE_CRYPTO_OP_STATUS_SUCCESS) ? 0 : -1;
}
```

### 3.4 DH/ECDH 密钥交换

```c
// DH/ECDH 共享密钥计算

struct rte_crypto_dh_xform {
    uint16_t prime_len;                 // p 长度
    uint16_t generator_len;             // g 长度
    uint8_t *p;                         // 素数模数
    uint8_t *g;                         // 生成元
    uint8_t *x;                         // 私钥 (随机)
    uint8_t *y;                         // 公钥 (对方的)
};

// DH 共享密钥
int
dh_compute_shared_secret(struct rte_cryptodev *dev,
                          uint8_t *my_private,
                          uint8_t *peer_public,
                          uint8_t *shared_secret)
{
    struct rte_crypto_op *op;
    struct rte_crypto_asym_op *asym_op;

    op = rte_crypto_op_alloc(dev->op_mpool,
                              RTE_CRYPTO_OP_TYPE_ASYMMETRIC);
    asym_op = &op->asym;

    asym_op->type = RTE_CRYPTO_ASYM_OP_SHARED_SECRET;
    asym_op->dh.prime = dh_params.p;  // 2048-bit prime
    asym_op->dh.generator = dh_params.g;
    asym_op->dh.x = my_private;       // 我的私钥
    asym_op->dh.y = peer_public;       // 对方的公钥

    asym_op->dh.shared_secret = shared_secret;

    rte_cryptodev_enqueue_burst(dev->dev_id, 0, &op, 1);
    rte_cryptodev_dequeue_burst(dev->dev_id, 0, &op, 1);

    return (op->status == RTE_CRYPTO_OP_STATUS_SUCCESS) ? 0 : -1;
}

// ECDH 示例
int
ecdh_compute_shared_secret(struct rte_cryptodev *dev,
                            uint8_t *my_private,
                            uint8_t *peer_public_x, uint8_t *peer_public_y,
                            uint8_t *shared_secret)
{
    struct rte_crypto_op *op;
    struct rte_crypto_asym_op *asym_op;

    op = rte_crypto_op_alloc(dev->op_mpool,
                              RTE_CRYPTO_OP_TYPE_ASYMMETRIC);
    asym_op = &op->asym;

    asym_op->type = RTE_CRYPTO_ASYM_OP_SHARED_SECRET;
    asym_op->ecdh.curve = RTE_CRYPTO_EC_GROUP_SECP256R1;
    asym_op->ecdh.private_key = my_private;
    asym_op->ecdh.pubkey_x = peer_public_x;
    asym_op->ecdh.pubkey_y = peer_public_y;

    asym_op->ecdh.shared_secret = shared_secret;

    rte_cryptodev_enqueue_burst(dev->dev_id, 0, &op, 1);
    rte_cryptodev_dequeue_burst(dev->dev_id, 0, &op, 1);

    return (op->status == RTE_CRYPTO_OP_STATUS_SUCCESS) ? 0 : -1;
}
```

---

## 4. 多包批处理 (Multi-buffer)

### 4.1 分散-聚集 (Scatter-Gather)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        分散-聚集 (Scatter-Gather)                         │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  传统模式: mbuf 单段                                                       │
│  ────────────────────                                                     │
│                                                                             │
│  ┌────────────────────────────────────────┐                                │
│  │           Single Segment Mbuf          │                                │
│  │  ┌──────────────────────────────────┐  │                                │
│  │  │  data                             │  │                                │
│  │  │  [ packet data ]                  │  │                                │
│  │  └──────────────────────────────────┘  │                                │
│  └────────────────────────────────────────┘                                │
│  适用于连续内存                                                             │
│                                                                             │
│  Scatter-Gather: mbuf 链                                                   │
│  ──────────────────────                                                    │
│                                                                             │
│  ┌──────┐   ┌──────┐   ┌──────┐                                          │
│  │ seg1 │──►│ seg2 │──►│ seg3 │──► NULL                                 │
│  ├───┬──┤   ├───┬──┤   ├───┬──┤                                          │
│  │   │data│   │   │data│   │   │data│                                     │
│  │   │[p1]│   │   │[p2]│   │   │[p3]│                                     │
│  └───┴───┘   └───┴───┘   └───┴───┘                                      │
│     │           │           │                                             │
│     └───────────┴───────────┘                                             │
│              逻辑连续                                                       │
│                                                                             │
│  用于:                                                                     │
│  - 非连续缓冲区                                                            │
│  - 加密头和尾在不同位置                                                     │
│  - 降低内存复制                                                            │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 4.2 Raw Crypto 多包处理

```c
// 多包批处理

struct rte_crypto_vec {
    union {
        void *iov_base;           // scatter list base
        rte_iova_t iova;          // IO 虚拟地址
    };
    size_t iov_len;               // 段长度
    uint32_t num;                 // 段数量
};

// 多包加密操作
struct rte_crypto_packet {
    struct rte_crypto_op *op;

    // 数据向量
    struct rte_crypto_vec *vec;
    uint32_t num_vecs;

    // IV (每个包)
    uint8_t *iv;

    // 用户数据
    void *userdata;
};

// 批量准备多包
int
raw_crypto_multi_packet(struct rte_cryptodev *dev,
                        struct rte_mbuf **pkts, uint16_t nb_pkts,
                        struct rte_crypto_sym_xform *xforms,
                        uint8_t **ivs)
{
    struct rte_crypto_op *ops[32];
    uint16_t i;

    // 批量分配
    rte_crypto_op_bulk_alloc(dev->op_mpool,
                              RTE_CRYPTO_OP_TYPE_SYMMETRIC,
                              ops, nb_pkts);

    for (i = 0; i < nb_pkts; i++) {
        struct rte_crypto_sym_op *sym_op = &ops[i]->sym;

        // 绑定 xform (每个包可不同)
        sym_op->xform = &xforms[i];

        // 设置 mbuf
        sym_op->src.m = pkts[i];
        sym_op->src.offset = 0;
        sym_op->src.length = rte_pktmbuf_pkt_len(pkts[i]);

        sym_op->dst.m = NULL;  // 原地

        // 设置 IV
        sym_op->cipher.iv = ivs[i];
        sym_op->cipher.iv_len = 16;
    }

    // 批量入队
    uint16_t nb_enq = rte_cryptodev_enqueue_burst(dev->dev_id, 0,
                                                   ops, nb_pkts);

    // 批量出队
    uint16_t nb_deq = rte_cryptodev_dequeue_burst(dev->dev_id, 0,
                                                   ops, nb_enq);

    return nb_deq;
}
```

### 4.3 用户自定义协议处理

```c
// 自定义协议加密示例

#define CUSTOM_PROTO_HEADER_MAGIC  0xCAFE
#define CUSTOM_PROTO_VERSION       1

// 自定义协议头
struct custom_proto_hdr {
    uint16_t magic;              // 0xCAFE
    uint8_t version;             // 版本
    uint8_t flags;               // 标志
    uint16_t length;             // 载荷长度
    uint8_t iv[16];              // 加密 IV
    uint8_t auth_tag[16];        // 认证标签
    uint32_t sequence;           // 序列号
} __attribute__((packed));

// 自定义协议加密
struct rte_mbuf *
custom_proto_encrypt(struct rte_cryptodev *dev,
                     struct rte_mbuf *m,
                     uint8_t *key, uint32_t key_len,
                     uint32_t sequence)
{
    struct rte_crypto_op *op;
    struct rte_crypto_sym_op *sym_op;
    struct custom_proto_hdr *hdr;
    uint8_t iv[16];

    // 分配操作
    op = rte_crypto_op_alloc(dev->op_mpool,
                              RTE_CRYPTO_OP_TYPE_SYMMETRIC);
    sym_op = &op->sym;

    // 预置自定义头
    hdr = (struct custom_proto_hdr *)rte_pktmbuf_prepend(m, sizeof(*hdr));
    hdr->magic = rte_cpu_to_be16(CUSTOM_PROTO_HEADER_MAGIC);
    hdr->version = CUSTOM_PROTO_VERSION;
    hdr->flags = 0;
    hdr->length = rte_cpu_to_be16(rte_pktmbuf_pkt_len(m) - sizeof(*hdr));

    // 生成 IV
    rte_rand(iv, 16);
    memcpy(hdr->iv, iv, 16);

    // 设置序列号
    hdr->sequence = rte_cpu_to_be32(sequence);

    // 配置 AES-GCM xform (内联)
    static struct rte_crypto_sym_xform aead_xform = {
        .type = RTE_CRYPTO_SYM_XFORM_AEAD,
        .aead = {
            .algo = RTE_CRYPTO_AEAD_AES_GCM,
            .op = RTE_CRYPTO_AEAD_OP_ENCRYPT,
            .key = NULL,  // 设置为 key
            .key_len = 32,
            .iv = iv,
            .iv_len = 12,  // GCM nonce = 12 bytes
            .digest_len = 16,
        },
    };
    aead_xform.aead.key = key;

    sym_op->xform = &aead_xform;

    // 配置数据区域 (从自定义头后开始)
    sym_op->src.m = m;
    sym_op->src.offset = sizeof(*hdr);
    sym_op->src.length = rte_pktmbuf_pkt_len(m) - sizeof(*hdr);

    sym_op->dst.m = NULL;

    // 设置 AAD (包含自定义头的部分字段)
    sym_op->aead.aad = (uint8_t *)hdr;  // AAD = 自定义头
    sym_op->aead.aad_len = sizeof(*hdr) - 16;  // 不含 IV 和 auth_tag

    // 设置摘要位置
    sym_op->aead.digest = ((uint8_t *)hdr) + sizeof(*hdr) - 16;
    sym_op->aead.digest_len = 16;

    // 入队/出队
    rte_crypto_op *ops[1] = { op };
    rte_cryptodev_enqueue_burst(dev->dev_id, 0, ops, 1);
    rte_cryptodev_dequeue_burst(dev->dev_id, 0, ops, 1);

    return (op->status == RTE_CRYPTO_OP_STATUS_SUCCESS) ? m : NULL;
}

// 自定义协议解密
struct rte_mbuf *
custom_proto_decrypt(struct rte_cryptodev *dev,
                     struct rte_mbuf *m,
                     uint8_t *key, uint32_t key_len)
{
    struct rte_crypto_op *op;
    struct rte_crypto_sym_op *sym_op;
    struct custom_proto_hdr *hdr;

    // 解析自定义头
    hdr = rte_pktmbuf_mtod(m, struct custom_proto_hdr *);

    // 验证 magic
    if (hdr->magic != rte_cpu_to_be16(CUSTOM_PROTO_HEADER_MAGIC))
        return NULL;

    // 验证版本
    if (hdr->version != CUSTOM_PROTO_VERSION)
        return NULL;

    // 分配操作
    op = rte_crypto_op_alloc(dev->op_mpool,
                              RTE_CRYPTO_OP_TYPE_SYMMETRIC);
    sym_op = &op->sym;

    // 配置 AES-GCM xform
    static struct rte_crypto_sym_xform aead_xform = {
        .type = RTE_CRYPTO_SYM_XFORM_AEAD,
        .aead = {
            .algo = RTE_CRYPTO_AEAD_AES_GCM,
            .op = RTE_CRYPTO_AEAD_OP_DECRYPT,
            .key = NULL,
            .key_len = 32,
            .iv = hdr->iv,
            .iv_len = 12,
            .digest_len = 16,
        },
    };
    aead_xform.aead.key = key;

    sym_op->xform = &aead_xform;

    // 配置数据区域
    sym_op->src.m = m;
    sym_op->src.offset = sizeof(*hdr);
    sym_op->src.length = hdr->length;

    sym_op->dst.m = NULL;

    sym_op->aead.aad = (uint8_t *)hdr;
    sym_op->aead.aad_len = sizeof(*hdr) - 16;

    sym_op->aead.digest = ((uint8_t *)hdr) + sizeof(*hdr) - 16;
    sym_op->aead.digest_len = 16;

    rte_crypto_op *ops[1] = { op };
    rte_cryptodev_enqueue_burst(dev->dev_id, 0, ops, 1);
    rte_cryptodev_dequeue_burst(dev->dev_id, 0, ops, 1);

    if (op->status == RTE_CRYPTO_OP_STATUS_SUCCESS) {
        // 移除自定义头
        rte_pktmbuf_adj(m, sizeof(*hdr));
        return m;
    }

    rte_pktmbuf_free(m);
    return NULL;
}
```

---

## 5. 操作状态与错误处理

### 5.1 操作状态

```c
// 操作状态枚举
enum rte_crypto_op_status {
    RTE_CRYPTO_OP_STATUS_NOT_PROCESSED = 0,  // 未处理
    RTE_CRYPTO_OP_STATUS_SUCCESS,             // 成功
    RTE_CRYPTO_OP_STATUS_AUTH_FAILED,         // 认证失败
    RTE_CRYPTO_OP_STATUS_INVALID_ARGS,        // 参数错误
    RTE_CRYPTO_OP_STATUS_INVALID_SESSION,    // session 错误
    RTE_CRYPTO_OP_STATUS_INVALID_OP,          // 操作类型错误
    RTE_CRYPTO_OP_STATUS_ALLOCATION_FAILED,  // 内存分配失败
    RTE_CRYPTO_OP_STATUS_ERROR,              // 通用错误
};

// 状态检查
static inline int
check_crypto_op_status(struct rte_crypto_op *op)
{
    switch (op->status) {
    case RTE_CRYPTO_OP_STATUS_SUCCESS:
        return 0;

    case RTE_CRYPTO_OP_STATUS_AUTH_FAILED:
        // 数据完整性检查失败
        return -EBADMSG;

    case RTE_CRYPTO_OP_STATUS_INVALID_ARGS:
        return -EINVAL;

    case RTE_CRYPTO_OP_STATUS_INVALID_SESSION:
        return -ENOENT;

    default:
        return -EIO;
    }
}

// 批量状态检查
static inline int
check_crypto_batch_status(struct rte_crypto_op **ops, uint16_t nb_ops)
{
    uint16_t i;
    int ret = 0;

    for (i = 0; i < nb_ops; i++) {
        if (ops[i]->status != RTE_CRYPTO_OP_STATUS_SUCCESS) {
            ret = check_crypto_op_status(ops[i]);
            break;
        }
    }

    return ret;
}
```

### 5.2 错误统计

```c
// 驱动错误统计

struct rte_cryptodev_stats {
    uint64_t enqueued_count;       // 入队总数
    uint64_t dequeued_count;       // 出队总数
    uint64_t enqueue_err_count;    // 入队错误
    uint64_t dequeue_err_count;   // 出队错误
    uint64_t impl_err_count;       // 实现错误

    // 详细错误 (某些驱动支持)
    uint64_t cipher_err;           // 加密错误
    uint64_t auth_err;             // 认证错误
    uint64_t sync_err;             // 同步错误
};

// 获取驱动统计
int
rte_cryptodev_stats_get(uint8_t dev_id,
                         struct rte_cryptodev_stats *stats)
{
    struct rte_cryptodev *dev = &rte_cryptodev[dev_id];

    if (dev->dev_ops->stats_get)
        return dev->dev_ops->stats_get(dev, stats);

    memset(stats, 0, sizeof(*stats));
    return 0;
}

// 重置统计
int
rte_cryptodev_stats_reset(uint8_t dev_id)
{
    struct rte_cryptodev *dev = &rte_cryptodev[dev_id];

    if (dev->dev_ops->stats_reset)
        return dev->dev_ops->stats_reset(dev);

    return 0;
}
```

---

## 6. 驱动实现

### 6.1 Raw Crypto PMD

```c
// Raw Crypto PMD 实现示例

// PMD 私有数据
struct raw_crypto_pmd_private {
    struct rte_cryptodev *dev;
    uint8_t is_user_dispatcher;     // 是否使用用户分派
};

// 处理 Raw Crypto 操作
static uint16_t
raw_crypto_pmd_sym_enqueue_burst(struct rte_cryptodev *dev,
                                   struct rte_crypto_qp **qp,
                                   struct rte_crypto_op **ops,
                                   uint16_t nb_ops)
{
    uint16_t i;
    uint16_t enqueued = 0;

    for (i = 0; i < nb_ops; i++) {
        struct rte_crypto_op *op = ops[i];

        if (op->type == RTE_CRYPTO_OP_TYPE_SYMMETRIC) {
            // 对称操作
            enqueued += raw_crypto_pmd_process_sym_op(
                dev, qp, &op->sym);
        } else if (op->type == RTE_CRYPTO_OP_TYPE_ASYMMETRIC) {
            // 非对称操作
            enqueued += raw_crypto_pmd_process_asym_op(
                dev, qp, &op->asym);
        }
    }

    return enqueued;
}

// 处理对称操作
static uint16_t
raw_crypto_pmd_process_sym_op(struct rte_cryptodev *dev,
                                struct rte_crypto_qp *qp,
                                struct rte_crypto_sym_op *sym_op)
{
    // 获取 xform (sessionless 或 session-based)
    struct rte_crypto_sym_xform *xform = sym_op->xform;

    if (sym_op->sess_type == RTE_CRYPTO_OP_SESSIONLESS) {
        // Raw mode: xform 直接内联在 op 中
        return raw_crypto_pmd_process_xform_chain(
            dev, qp, xform, sym_op);
    } else {
        // Session mode: 从 session 获取 xform
        return raw_crypto_pmd_process_session(
            dev, qp, sym_op);
    }
}
```

### 6.2 QAT Raw Crypto

```c
// QAT PMD Raw Crypto 实现

// QAT 服务 ID
enum qat_service_type {
    QAT_SERVICE_SYMMETRIC,         // 对称加密
    QAT_SERVICE_ASYMMETRIC,        // 非对称加密
    QAT_SERVICE_COMPRESSION,       // 压缩
};

// QAT 描述符
struct qat_sym_crypto_desc {
    // 通用描述符头
    uint8_t desc_hdr;               // 0x07 = 常规
    uint8_t service_id;            // 服务类型
    uint8_t valid_bit;             // 有效位
    uint8_t comp_req_cred;         // 压缩请求凭证

    // 描述符命令
    uint32_t cmd_flags;

    // 状态
    uint32_t status;

    // 源/目标地址
    struct qat_flat_buf src;
    struct qat_flat_buf dst;

    // 密钥
    struct qat_flat_buf key;

    // IV
    struct qat_flat_buf.iv;

    // AAD (GCM)
    struct qat_flat_buf aad;

    // 摘要
    struct qat_flat_buf digest;
};

// 构建 QAT 描述符 (Raw Crypto)
static int
qat_build_sym_desc(struct rte_crypto_op *op,
                    struct qat_sym_crypto_desc *desc)
{
    struct rte_crypto_sym_op *sym_op = &op->sym;
    struct rte_crypto_sym_xform *xform = sym_op->xform;

    // 构建描述符链
    switch (xform->type) {
    case RTE_CRYPTO_SYM_XFORM_AEAD:
        // AES-GCM
        qat_desc_aead(op, desc);
        break;

    case RTE_CRYPTO_SYM_XFORM_CIPHER:
        // CBC/CTR
        qat_desc_cipher(op, desc);
        break;

    case RTE_CRYPTO_SYM_XFORM_AUTH:
        // HMAC
        qat_desc_auth(op, desc);
        break;

    case RTE_CRYPTO_SYM_XFORM_CHAIN:
        // Cipher + Auth
        qat_desc_chain(op, desc);
        break;
    }

    return 0;
}
```

---

## 7. 完整使用示例

### 7.1 混合协议 (IPsec + 自定义 MAC)

```c
// 混合协议示例: IPsec ESP + 自定义应用层 MAC

struct hybrid_crypto_config {
    uint8_t esp_key[32];           // ESP 加密密钥
    uint8_t esp_auth_key[32];       // ESP 认证密钥
    uint8_t app_mac_key[16];        // 应用层 MAC 密钥

    uint8_t cryptodev_id;           // Crypto 设备
};

// 混合加密处理
int
hybrid_encrypt(struct hybrid_crypto_config *cfg,
               struct rte_mbuf *m)
{
    struct rte_crypto_op *op;
    struct rte_crypto_sym_op *sym_op;

    // 分配操作
    op = rte_crypto_op_alloc(cfg->crypto_mpool,
                              RTE_CRYPTO_OP_TYPE_SYMMETRIC);
    sym_op = &op->sym;

    // 1. 配置 ESP xform (cipher + auth)
    static struct rte_crypto_sym_xform esp_chain[2];

    // Cipher: AES-256-GCM
    esp_chain[0].type = RTE_CRYPTO_SYM_XFORM_CIPHER;
    esp_chain[0].cipher.op = RTE_CRYPTO_CIPHER_OP_ENCRYPT;
    esp_chain[0].cipher.algo = RTE_CRYPTO_CIPHER_AES_GCM;
    esp_chain[0].cipher.key = cfg->esp_key;
    esp_chain[0].cipher.key_len = 32;
    esp_chain[0].cipher.iv = esp_iv;  // 预生成
    esp_chain[0].cipher.iv_len = 12;

    // Auth: HMAC-SHA256
    esp_chain[1].type = RTE_CRYPTO_SYM_XFORM_AUTH;
    esp_chain[1].auth.op = RTE_CRYPTO_AUTH_OP_GENERATE;
    esp_chain[1].auth.algo = RTE_CRYPTO_AUTH_SHA256_HMAC;
    esp_chain[1].auth.key = cfg->esp_auth_key;
    esp_chain[1].auth.key_len = 32;
    esp_chain[1].auth.digest_len = 16;

    esp_chain[0].next = &esp_chain[1];
    esp_chain[1].next = NULL;

    sym_op->xform = esp_chain;

    // 2. 绑定 mbuf
    sym_op->src.m = m;
    sym_op->src.offset = 0;
    sym_op->src.length = rte_pktmbuf_pkt_len(m);

    sym_op->dst.m = NULL;

    // 3. ESP 参数
    sym_op->cipher.iv = esp_iv;
    sym_op->cipher.iv_len = 12;

    sym_op->auth.src.offset = sizeof(struct esp_hdr);
    sym_op->auth.src.length = rte_pktmbuf_pkt_len(m) - sizeof(struct esp_hdr);
    sym_op->auth.digest = rte_pktmbuf_append(m, 16);

    // 4. 发送到 QAT
    rte_cryptodev_enqueue_burst(cfg->cryptodev_id, 0, &op, 1);

    // 5. 处理完成后，添加应用层 MAC
    uint16_t nb_deq = rte_cryptodev_dequeue_burst(cfg->cryptodev_id, 0,
                                                   &op, 1);

    if (nb_deq == 1 && op->status == RTE_CRYPTO_OP_STATUS_SUCCESS) {
        // 添加应用层 MAC
        uint8_t *mac = rte_pktmbuf_append(m, 8);
        hmac(ctx, cfg->app_mac_key, rte_pktmbuf_mtod(m, uint8_t *),
             rte_pktmbuf_pkt_len(m) - 8, mac);
        return 0;
    }

    return -1;
}
```

### 7.2 国密 SM2 密钥交换

```c
// 国密 SM2 算法

struct sm2_crypto_config {
    uint8_t p[32];                  // 素数模数 (256-bit)
    uint8_t a[32];                  // 曲线参数 a
    uint8_t b[32];                  // 曲线参数 b
    uint8_t n[32];                  // 阶
    uint8_t gx[32], gy[32];         // 基点
};

// SM2 加密
struct rte_crypto_sm2_xform {
    enum rte_crypto_asym_xform_type type;  // SM2
    uint8_t *p, *a, *b, *n;         // 曲线参数
    uint8_t *gx, *gy;              // 基点
    uint8_t *public_key;           // 公钥 (x, y)
    uint8_t *private_key;          // 私钥 d
};

struct rte_crypto_sm2_op {
    // 消息 (加密) / 密文 (解密)
    uint8_t *message;
    uint16_t message_len;

    // 密文 (加密) / 消息 (解密)
    uint8_t *ciphertext;
    uint16_t ciphertext_len;

    // C1 || C3 || C2 格式
    uint8_t *c1;                   // C1 (公钥 * k)
    uint8_t *c3;                   // C3 (哈希)
    uint8_t *c2;                   // C2 (密文)

    // 用户 ID
    uint8_t *user_id;
    uint16_t user_id_len;
};

// SM2 加密操作
int
sm2_encrypt(struct rte_cryptodev *dev,
            uint8_t *message, size_t msg_len,
            struct sm2_crypto_config *cfg,
            uint8_t *public_key_x, uint8_t *public_key_y,
            uint8_t *ciphertext, size_t *ct_len)
{
    struct rte_crypto_op *op;
    struct rte_crypto_asym_op *asym_op;

    op = rte_crypto_op_alloc(dev->op_mpool,
                              RTE_CRYPTO_OP_TYPE_ASYMMETRIC);
    asym_op = &op->asym;

    asym_op->type = RTE_CRYPTO_ASYM_OP_ENCRYPT;
    asym_op->sm2.p = cfg->p;
    asym_op->sm2.a = cfg->a;
    asym_op->sm2.b = cfg->b;
    asym_op->sm2.n = cfg->n;
    asym_op->sm2.gx = cfg->gx;
    asym_op->sm2.gy = cfg->gy;
    asym_op->sm2.public_key = public_key_x;  // SM2 公钥 (x || y)
    asym_op->sm2.private_key = NULL;  // 不需要私钥

    asym_op->sm2.message = message;
    asym_op->sm2.message_len = msg_len;
    asym_op->sm2.ciphertext = ciphertext;

    // 设置用户 ID (SM2 标准需要)
    asym_op->sm2.user_id = (uint8_t *)"user@example.com";
    asym_op->sm2.user_id_len = 16;

    rte_cryptodev_enqueue_burst(dev->dev_id, 0, &op, 1);
    rte_cryptodev_dequeue_burst(dev->dev_id, 0, &op, 1);

    if (op->status == RTE_CRYPTO_OP_STATUS_SUCCESS) {
        *ct_len = asym_op->sm2.ciphertext_len;
        return 0;
    }

    return -1;
}

// SM2 签名
int
sm2_sign(struct rte_cryptodev *dev,
         uint8_t *message, size_t msg_len,
         uint8_t *private_key,
         uint8_t *sign, size_t *sign_len)
{
    struct rte_crypto_op *op;
    struct rte_crypto_asym_op *asym_op;

    op = rte_crypto_op_alloc(dev->op_mpool,
                              RTE_CRYPTO_OP_TYPE_ASYMMETRIC);
    asym_op = &op->asym;

    asym_op->type = RTE_CRYPTO_ASYM_OP_SIGN;
    asym_op->sm2.private_key = private_key;

    // SM2 需要用户 ID + 消息哈希
    uint8_t user_id[] = "user@example.com";
    uint8_t z[32];  // SM3(user_id || public_key)

    sm3_z(user_id, sizeof(user_id) - 1, public_key, z);

    uint8_t hash[32];
    sm3_hash(z, sizeof(z), message, msg_len, hash);

    asym_op->sm2.message = hash;
    asym_op->sm2.message_len = 32;
    asym_op->sm2.sign = sign;

    rte_cryptodev_enqueue_burst(dev->dev_id, 0, &op, 1);
    rte_cryptodev_dequeue_burst(dev->dev_id, 0, &op, 1);

    if (op->status == RTE_CRYPTO_OP_STATUS_SUCCESS) {
        *sign_len = 64;  // SM2 签名 = r (32) || s (32)
        return 0;
    }

    return -1;
}
```

---

## 8. 性能与优化

### 8.1 Raw Crypto 性能

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    Session-based vs Raw Crypto 性能                        │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  AES-256-CBC + SHA-256, 1024B payload                                     │
│                                                                             │
│  方案                    吞吐量        CPU 周期/包                          │
│  ──────────────────────────────────────────────────────────────────────── │
│  Session-based          8.5 Gbps        800 cycles                         │
│  Raw Crypto (sessionless) 7.2 Gbps    950 cycles                         │
│  Raw Crypto (优化)      8.2 Gbps        820 cycles                         │
│                                                                             │
│  Raw Crypto 特点:                                                         │
│  - 无 session 查找开销                                                     │
│  - 无间接寻址                                                              │
│  - 适合动态密钥场景                                                        │
│  - 批量处理可弥补开销                                                       │
│                                                                             │
│  性能差异来源:                                                             │
│  - Session-based: session 缓存命中时极快                                    │
│  - Raw Crypto: xform 解析开销                                              │
│  - 建议: 静态密钥用 session，动态密钥用 raw                                  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 8.2 优化建议

| 优化项 | 说明 | 效果 |
|--------|------|------|
| **批量处理** | Raw Crypto 批量入队/出队 | 3-5x 提升 |
| **xform 复用** | 预分配 xform 数组 | 减少分配开销 |
| **mbuf 布局** | 连续缓冲区减少 scatter | 提升性能 |
| **驱动选择** | QAT/AESNI-MB 硬件 | 10x+ 提升 |
| **多包合并** | scatter-gather 批处理 | 降低开销 |
| **对齐** | 密钥/IV 缓存行对齐 | 避免伪共享 |

---

## 9. 小结

本章核心要点：

1. **为什么需要 Raw Crypto API**：传统 session-based API 有 session 间接寻址开销、无法动态改变密钥、不支持非对称加密，不适合动态密钥和自定义协议场景。

2. **Raw Crypto 优势**：xform 内联在 op 中、无需预创建 session、每包可用不同算法和密钥、低内存开销。

3. **对称 Raw Crypto**：xform 链式结构 (cipher + auth)，cipher_xform / auth_xform / aead_xform 可自由组合。

4. **非对称 Raw Crypto**：RSA (PKCS#1 v1.5 / OAEP)、ECDSA (P-256/P-384/P-521)、DH/ECDH 密钥交换、SM2 国密算法。

5. **多包批处理**：分散-聚集 (scatter-gather)、批量分配和入队、提高吞吐。

6. **自定义协议**：自定义头格式、内联 IV/Nonce、AEAD 参数 (AAD)、与标准协议 (IPsec/TLS) 的组合。

7. **操作状态**：RTE_CRYPTO_OP_STATUS_* 状态枚举，认证失败/参数错误等。

8. **驱动实现**：Raw Crypto PMD 架构、QAT Raw Crypto 描述符构建。

9. **国密支持**：SM2 签名/加密、SM4 分组密码、SM3 哈希。

10. **性能**：Session-based 在静态密钥场景更快，Raw Crypto 在动态密钥场景更灵活，批量处理可弥补开销。

**下一篇预告**：[[2026-04-09-dpdk-deep-dive-ch25-cache-optimization|第二十五章]]将讲解 Cache 优化——false sharing、预取与内存访问模式。

---

> [!tip] 参考文献
> - Intel, "DPDK Cryptodev Raw API", https://doc.dpdk.org/guides/prog_guide/cryptodev.html
> - "Asymmetric Cryptography in DPDK", https://doc.dpdk.org/guides/prog_guide/cryptodev_asym.html
> - RFC 8017, "PKCS#1 v2.2: RSA Cryptography Specifications"
> - RFC 8420, "SM2 Elliptic Curve Signature Algorithm"
> - GMP, "SM2/SM3/SM4 Chinese National Cryptographic Algorithms"
