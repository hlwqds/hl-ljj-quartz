---
title: "DPDK 深度探索 (二十四)：Raw Crypto API 与自定义协议加密"
date: 2026-04-09
tags:
  [
    dpdk,
    series,
    raw-crypto,
    symmetric-crypto,
    asymmetric-crypto,
    sessionless,
    crypto-op,
    xform,
    user-defined-protocol,
  ]
description: "深入理解 DPDK Sessionless Crypto API——xform 内联模式、对称/非对称加密操作、批量处理、自定义协议加密"
---

> [!info] DPDK 深度探索系列 0. [[2026-04-09-dpdk-deep-dive-series-index|全栈学习路径总览]]
> 1-23. 前二十三章已完成 24. **第二十四章：Raw Crypto API 与自定义协议加密**

---

## 1. 概述：为什么需要 Sessionless Crypto API？

### 1.1 Session-based 模式的局限性

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    Session-based 模式的局限性                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  Session-based 流程:                                                       │
│  ──────────────────                                                        │
│                                                                             │
│  ┌──────────────────────────────────────────────────────────────────────┐ │
│  │  1. 创建 Session:                                                   │ │
│  │     rte_cryptodev_sym_session_create(dev_id, xform, pool)            │ │
│  │     - 需要预先知道算法和密钥                                        │ │
│  │     - 绑定到特定 cryptodev + queue pair                              │ │
│  │     - Session 占用设备内存（存储密钥材料）                            │ │
│  │                                                                      │ │
│  │  2. 使用 Session:                                                    │ │
│  │     op = rte_crypto_op_alloc(pool, SYMMETRIC)                        │ │
│  │     op->sym->session = my_session                                   │ │
│  │     op->sym->m_src = mbuf                                           │ │
│  │     rte_cryptodev_enqueue_burst(dev_id, qp_id, &op, 1)              │ │
│  │                                                                      │ │
│  │  3. 回收 Session:                                                   │ │
│  │     rte_cryptodev_sym_session_free(session)                         │ │
│  └──────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
│  问题:                                                                    │
│  ────                                                                    │
│  1. 密钥变化需要销毁旧 session、创建新 session                            │
│  2. 每个 session 占用设备资源（存储密钥材料）                              │
│  3. 不适合每包不同密钥的场景                                               │
│  4. Session 创建/销毁有开销                                               │
│  5. 短连接场景（如 TLS session resumption）效率低                        │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 1.2 Sessionless 模式的优势

> [!important] 术语说明
> DPDK 官方文档中称此为 **"Sessionless crypto operation"**。
> 文中 "Raw Crypto" 指的是同一概念——跳过 session，直接在 op 中携带 xform。

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    Sessionless 模式优势                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  Sessionless 流程:                                                         │
│  ─────────────────                                                         │
│                                                                             │
│  App ──► op_alloc(pool) ──► op->sym->xform = xform ──► enqueue           │
│                                                                             │
│  无需预创建 session，直接在操作中携带 xform                               │
│                                                                             │
│  优势:                                                                    │
│  ──────                                                                    │
│  ┌──────────────────────────────────────────────────────────────────────┐ │
│  │  1. 动态密钥: 每个 op 可携带不同的 xform (密钥/算法)                │ │
│  │  2. 零 session 开销: 不占用设备 session 资源                         │ │
│  │  3. 简化代码: 不需要管理 session 生命周期                            │ │
│  │  4. 适合短连接: 每包/每连接使用不同密钥                              │ │
│  │  5. 对称+非对称统一: 同样的 sessionless 机制                         │ │
│  └──────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
│  典型应用场景:                                                             │
│  ──────────────                                                            │
│  - TLS Record 加密 (每个连接不同密钥)                                      │
│  - IPsec ESP (动态 SA 密钥更新)                                            │
│  - 自定义加密协议 (商密/国密 SM4)                                          │
│  - 密钥轮换频繁的场景                                                      │
│                                                                             │
│  代价:                                                                     │
│  ────                                                                     │
│  - PMD 每次需要解析 xform（额外 CPU 开销）                                │
│  - 密钥不能缓存在硬件中                                                   │
│  - 批量场景下 session-based 通常更快                                       │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 1.3 Session-based vs Sessionless 对比

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    Session-based vs Sessionless                            │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  Session-based:                                                            │
│  ───────────────                                                           │
│  ┌──────────┐    ┌───────────┐    ┌──────────┐    ┌─────────┐             │
│  │ xform    │───►│ session   │───►│  op      │───►│ enqueue │             │
│  │(算法+密钥)│   │(设备内存) │    │.session  │    │         │             │
│  └──────────┘    └───────────┘    └──────────┘    └─────────┘             │
│   创建一次        缓存在设备       复用 session     密钥已加载             │
│                                                                             │
│  Sessionless:                                                             │
│  ─────────────                                                            │
│  ┌──────────┐    ┌──────────┐    ┌─────────┐                             │
│  │ xform    │───►│  op      │───►│ enqueue │                             │
│  │(算法+密钥)│   │.xform    │    │         │                             │
│  └──────────┘    └──────────┘    └─────────┘                             │
│   每个 op          内联在 op      PMD 解析 xform                          │
│                                                                             │
│  选择建议:                                                                 │
│  ────────                                                                 │
│  ┌──────────────────────┬──────────────────────┐                          │
│  │  用 Session-based     │  用 Sessionless      │                          │
│  ├──────────────────────┼──────────────────────┤                          │
│  │  密钥固定 (如 VPN SA) │  密钥每包不同        │                          │
│  │  长连接/高吞吐        │  短连接/低连接数     │                          │
│  │  硬件加速 (QAT/IPU)   │  动态密钥轮换        │                          │
│  │  大量并发 session     │  原型开发/测试        │                          │
│  └──────────────────────┴──────────────────────┘                          │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. 对称 Sessionless Crypto API

### 2.1 rte_crypto_sym_op 结构

```c
// DPDK: lib/cryptodev/rte_crypto_sym.h

// 注意: aead / cipher+auth 在同一个 union 中 (共享内存，不能同时使用)
// cipher 和 auth 在同一个匿名结构体中 (支持 cipher+auth 链式操作)
// IV 不在 sym_op 中 —— 通过 crypto op 的 private data area 传递
struct rte_crypto_sym_op {
    // --- mbuf ---
    struct rte_mbuf *m_src;   // source mbuf
    struct rte_mbuf *m_dst;   // destination mbuf (NULL = in-place)

    // --- session 或 xform (union，二选一) ---
    union {
        void *session;                      // Session-based: session handle
        struct rte_crypto_sym_xform *xform;  // Sessionless: 直接携带 xform
    };

    // --- 操作参数 (一个 union，aead 和 cipher+auth 二选一) ---
    union {
        // AEAD 模式 (AES-GCM, ChaCha20-Poly1305 等)
        struct {
            struct { uint32_t offset; uint32_t length; } data;
            struct { uint8_t *data; rte_iova_t phys_addr; } digest;
            struct { uint8_t *data; rte_iova_t phys_addr; } aad;
        } aead;

        // Cipher + Auth 模式 (支持链式操作)
        struct {
            struct { struct { uint32_t offset; uint32_t length; } data; } cipher;
            struct {
                struct { uint32_t offset; uint32_t length; } data;
                struct { uint8_t *data; rte_iova_t phys_addr; } digest;
            } auth;
        };
    };
};
```

> [!warning] 常见误区
>
> - `rte_crypto_sym_op` 的 mbuf 字段是 `m_src` / `m_dst`，不是 `src.m` / `dst.m`
> - IV 不是 sym_op 的直接字段——它通过 crypto op 的 private data 传递
> - digest 和 aad 使用 `{ .data, .phys_addr }` 结构，不是简单指针
> - **aead 和 cipher+auth 在同一个 union 中**，不能同时使用。链式 cipher+auth
>   使用匿名结构体中的 `cipher` 和 `auth` 成员，它们共享同一个 union slot

### 2.2 rte_crypto_sym_xform 结构

```c
// DPDK: lib/cryptodev/rte_crypto_sym.h

// xform 类型
enum rte_crypto_sym_xform_type {
    RTE_CRYPTO_SYM_XFORM_NOT_SPECIFIED = 0,  // 占位/链接用
    RTE_CRYPTO_SYM_XFORM_AUTH,               // 认证 (HMAC 等)
    RTE_CRYPTO_SYM_XFORM_CIPHER,             // 加密 (AES-CBC 等)
    RTE_CRYPTO_SYM_XFORM_AEAD,               // AEAD (AES-GCM 等)
};

// xform 链结构
struct rte_crypto_sym_xform {
    struct rte_crypto_sym_xform *next;   // 下一个 xform (链式)
    enum rte_crypto_sym_xform_type type; // 当前 xform 类型

    union {
        struct rte_crypto_auth_xform auth;    // 认证参数
        struct rte_crypto_cipher_xform cipher; // 加密参数
        struct rte_crypto_aead_xform aead;    // AEAD 参数
    };
};

// 示例: cipher + auth 链式 (TLS 1.2 CBC+HMAC)
// xform_cipher.next = &xform_auth;
// xform_auth.next = NULL;
```

> [!note] 没有 CHAIN 类型
> `rte_crypto_sym_xform_type` 只有 4 个值。链式操作通过 `next` 指针实现，
> 不是通过一个单独的 `RTE_CRYPTO_SYM_XFORM_CHAIN` 类型。

### 2.3 Sessionless 操作流程

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    Sessionless 对称加密流程                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                                                                      │   │
│  │  1. 分配 crypto op                                                  │   │
│  │     op = rte_crypto_op_alloc(pool, RTE_CRYPTO_OP_TYPE_SYMMETRIC)   │   │
│  │     op->sess_type = RTE_CRYPTO_OP_SESSIONLESS  ← 关键设置          │   │
│  │                                                                      │   │
│  │  2. 设置 xform (内联在 op 中)                                       │   │
│  │     op->sym->xform = &my_xform                                    │   │
│  │                                                                      │   │
│  │  3. 设置 mbuf                                                       │   │
│  │     op->sym->m_src = mbuf                                          │   │
│  │     op->sym->m_dst = mbuf   (或 NULL = in-place)                    │   │
│  │                                                                      │   │
│  │  4. 设置操作参数 (根据 xform 类型)                                  │   │
│  │     AEAD:  op->sym->aead.data.offset / .length                      │   │
│  │     Cipher: op->sym->cipher.data.offset / .length                    │   │
│  │     Auth:   op->sym->auth.data.offset / .length                     │   │
│  │                                                                      │   │
│  │  5. 设置 IV (通过 private data area)                                │   │
│  │     iv_ptr = rte_crypto_op_ctod_offset(op, uint8_t *,               │   │
│  │                                         iv_offset)                  │   │
│  │     rte_memcpy(iv_ptr, my_iv, iv_len)                               │   │
│  │                                                                      │   │
│  │  6. 入队 → 出队                                                     │   │
│  │     rte_cryptodev_enqueue_burst(dev_id, qp_id, &op, 1)             │   │
│  │     rte_cryptodev_dequeue_burst(dev_id, qp_id, &op, 1)             │   │
│  │                                                                      │   │
│  │  7. 检查结果                                                        │   │
│  │     op->status == RTE_CRYPTO_OP_STATUS_SUCCESS ?                     │   │
│  │                                                                      │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 2.4 AEAD Sessionless 示例 (AES-128-GCM)

```c
// === AES-128-GCM Sessionless 加密示例 ===

int
aead_sessionless_encrypt(uint8_t dev_id, uint16_t qp_id,
                         struct rte_mempool *op_pool,
                         struct rte_mbuf *mbuf,
                         uint8_t *key, uint8_t *iv,
                         uint8_t *aad, uint16_t aad_len)
{
    struct rte_crypto_op *op;
    struct rte_crypto_sym_op *sym_op;

    // 1. 分配 crypto op
    op = rte_crypto_op_alloc(op_pool, RTE_CRYPTO_OP_TYPE_SYMMETRIC);
    if (op == NULL)
        return -ENOMEM;

    // 标记为 sessionless
    op->sess_type = RTE_CRYPTO_OP_SESSIONLESS;

    sym_op = op->sym;

    // 2. 准备 xform (栈上分配，生命周期覆盖 enqueue→dequeue)
    // 注意: xform 生命周期必须覆盖 enqueue→dequeue，不能用 static (多线程不安全)
    struct rte_crypto_sym_xform aead_xform;
    aead_xform.type = RTE_CRYPTO_SYM_XFORM_AEAD;
    aead_xform.next = NULL;
    aead_xform.aead.algo = RTE_CRYPTO_AEAD_AES_GCM;
    aead_xform.aead.op = RTE_CRYPTO_AEAD_OP_ENCRYPT;
    aead_xform.aead.key.data = key;
    aead_xform.aead.key.length = 16;     // AES-128
    aead_xform.aead.iv.offset = 0;       // IV 在 private data 中的偏移
    aead_xform.aead.iv.length = 12;      // GCM nonce = 12 bytes
    aead_xform.aead.digest_length = 16;  // GCM tag = 16 bytes
    aead_xform.aead.aad_length = aad_len;

    // 3. 绑定 xform
    sym_op->xform = &aead_xform;

    // 4. 设置 mbuf
    sym_op->m_src = mbuf;
    sym_op->m_dst = mbuf;  // in-place

    // 5. 设置 AEAD 数据位置
    sym_op->aead.data.offset = 0;
    sym_op->aead.data.length = rte_pktmbuf_pkt_len(mbuf);

    // 6. 设置 AAD 指针
    sym_op->aead.aad.data = aad;

    // 7. 追加空间用于 digest (tag)，并设置 digest 指针
    uint8_t *tag = (uint8_t *)rte_pktmbuf_append(mbuf, 16);
    if (tag == NULL) {
        rte_crypto_op_free(op);
        return -ENOBUFS;
    }
    sym_op->aead.digest.data = tag;

    // 8. 设置 IV (通过 op 的 private data)
    // private data offset = sizeof(rte_crypto_sym_op) 对齐到 8
    uint16_t iv_offset = sizeof(struct rte_crypto_sym_op);
    iv_offset = (iv_offset + 7) & ~7;  // 8-byte 对齐
    uint8_t *iv_ptr = rte_crypto_op_ctod_offset(op, uint8_t *, iv_offset);
    rte_memcpy(iv_ptr, iv, 12);

    // 9. 入队
    uint16_t nb_enq = rte_cryptodev_enqueue_burst(dev_id, qp_id, &op, 1);
    if (nb_enq != 1) {
        rte_crypto_op_free(op);
        return -EIO;
    }

    return 0;
}
```

### 2.5 Cipher+Auth 链式 Sessionless 示例

```c
// === Cipher + Auth 链式 Sessionless 示例 (AES-CBC + HMAC-SHA256) ===

int
cipher_auth_sessionless_encrypt(uint8_t dev_id, uint16_t qp_id,
                                struct rte_mempool *op_pool,
                                struct rte_mbuf *mbuf,
                                uint8_t *cipher_key, uint8_t *auth_key,
                                uint8_t *iv)
{
    struct rte_crypto_op *op;
    struct rte_crypto_sym_op *sym_op;

    op = rte_crypto_op_alloc(op_pool, RTE_CRYPTO_OP_TYPE_SYMMETRIC);
    if (!op)
        return -ENOMEM;

    op->sess_type = RTE_CRYPTO_OP_SESSIONLESS;
    sym_op = op->sym;

    // 1. 准备 cipher xform (链的第一个)
    struct rte_crypto_sym_xform cipher_xform = {
        .type = RTE_CRYPTO_SYM_XFORM_CIPHER,
        .next = NULL,  // 暂时 NULL，后面链接
        .cipher = {
            .algo = RTE_CRYPTO_CIPHER_AES_CBC,
            .op = RTE_CRYPTO_CIPHER_OP_ENCRYPT,
            .iv.offset = 0,
            .iv.length = 16,
            .key.data = cipher_key,
            .key.length = 32,  // AES-256
        },
    };

    // 2. 准备 auth xform (链的第二个)
    struct rte_crypto_sym_xform auth_xform = {
        .type = RTE_CRYPTO_SYM_XFORM_AUTH,
        .next = NULL,
        .auth = {
            .algo = RTE_CRYPTO_AUTH_SHA256_HMAC,
            .op = RTE_CRYPTO_AUTH_OP_GENERATE,
            .key.data = auth_key,
            .key.length = 32,
            .digest_length = 32,
        },
    };

    // 3. 链接: cipher → auth
    cipher_xform.next = &auth_xform;

    // 4. 绑定链头
    sym_op->xform = &cipher_xform;

    // 5. 设置 mbuf
    sym_op->m_src = mbuf;
    sym_op->m_dst = mbuf;

    // 6. Cipher 数据范围 (整个 mbuf)
    sym_op->cipher.data.offset = 0;
    sym_op->cipher.data.length = rte_pktmbuf_pkt_len(mbuf);

    // 7. Auth 数据范围 (整个 mbuf)
    sym_op->auth.data.offset = 0;
    sym_op->auth.data.length = rte_pktmbuf_pkt_len(mbuf);

    // 8. Auth digest 输出位置
    uint8_t *digest = (uint8_t *)rte_pktmbuf_append(mbuf, 32);
    sym_op->auth.digest.data = digest;

    // 9. IV (通过 private data)
    uint16_t iv_offset = (sizeof(struct rte_crypto_sym_op) + 7) & ~7;
    uint8_t *iv_ptr = rte_crypto_op_ctod_offset(op, uint8_t *, iv_offset);
    rte_memcpy(iv_ptr, iv, 16);

    // 10. 入队
    uint16_t nb_enq = rte_cryptodev_enqueue_burst(dev_id, qp_id, &op, 1);
    if (nb_enq != 1) {
        rte_crypto_op_free(op);
        return -EIO;
    }

    return 0;
}
```

> [!note] xform 生命周期
> Sessionless 模式下，xform 必须在 `dequeue` 完成之前保持有效（不能被释放或修改）。
> 通常的做法是将 xform 放在栈上（同步等待场景）或预分配的内存池中（异步场景）。

---

## 3. 非对称 Sessionless Crypto API

### 3.1 非对称操作类型

```c
// DPDK: lib/cryptodev/rte_crypto_asym.h

// xform 类型
enum rte_crypto_asym_xform_type {
    RTE_CRYPTO_ASYM_XFORM_UNSPECIFIED = 0,
    RTE_CRYPTO_ASYM_XFORM_RSA,
    RTE_CRYPTO_ASYM_XFORM_DH,
    RTE_CRYPTO_ASYM_XFORM_DSA,
    RTE_CRYPTO_ASYM_XFORM_MODINV,   // 模逆
    RTE_CRYPTO_ASYM_XFORM_MODEX,    // 模幂
    RTE_CRYPTO_ASYM_XFORM_ECDSA,
    RTE_CRYPTO_ASYM_XFORM_ECDH,
    RTE_CRYPTO_ASYM_XFORM_ECPM,     // EC 点乘
    RTE_CRYPTO_ASYM_XFORM_ECFPM,    // EC Fp 点乘
    RTE_CRYPTO_ASYM_XFORM_SM2,
    RTE_CRYPTO_ASYM_XFORM_EDDSA,
};

// 操作类型
enum rte_crypto_asym_op_type {
    RTE_CRYPTO_ASYM_OP_ENCRYPT,
    RTE_CRYPTO_ASYM_OP_DECRYPT,
    RTE_CRYPTO_ASYM_OP_SIGN,
    RTE_CRYPTO_ASYM_OP_VERIFY,
    RTE_CRYPTO_ASYM_OP_SHARED_SECRET_COMPUTE,
};
```

### 3.2 rte_crypto_asym_op 结构

```c
// DPDK: lib/cryptodev/rte_crypto_asym.h

struct rte_crypto_asym_op {
    // session 或 xform (union，与对称类似)
    union {
        struct rte_cryptodev_asym_session *session;  // Session-based
        struct rte_crypto_asym_xform *xform;         // Sessionless
    };

    // 操作参数 (union，根据 xform 类型选择)
    union {
        struct rte_crypto_rsa_op_param rsa;
        struct rte_crypto_mod_op_param modex;
        struct rte_crypto_mod_op_param modinv;
        struct rte_crypto_dh_op_param dh;
        struct rte_crypto_ecdh_op_param ecdh;
        struct rte_crypto_dsa_op_param dsa;
        struct rte_crypto_ecdsa_op_param ecdsa;
        struct rte_crypto_ecpm_op_param ecpm;
        struct rte_crypto_sm2_op_param sm2;
        struct rte_crypto_eddsa_op_param eddsa;
    };

    uint16_t flags;  // RTE_CRYPTO_ASYM_FLAG_*
};
```

> [!warning] 非对称 op 没有 `type` 字段
> `rte_crypto_asym_op` 没有 `type` 字段。操作类型在具体的 op param 中指定，
> 例如 `rsa.op_type = RTE_CRYPTO_ASYM_OP_ENCRYPT`。

### 3.3 RSA Sessionless 示例

```c
// DPDK RSA xform
struct rte_crypto_rsa_xform {
    rte_crypto_uint n;     // 模数 (modulus)
    rte_crypto_uint e;     // 公钥指数

    enum rte_crypto_rsa_priv_key_type key_type;
    struct {
        rte_crypto_uint d;              // 私钥指数
        struct rte_crypto_rsa_priv_key_qt qt;  // CRT 优化参数
    };

    struct rte_crypto_rsa_padding padding;  // padding 配置
};

// DPDK RSA op param
struct rte_crypto_rsa_op_param {
    enum rte_crypto_asym_op_type op_type;  // 操作类型

    rte_crypto_param message;   // 输入: 明文 (加密/签名)
    rte_crypto_param cipher;    // 输入: 密文 (解密) / 输出: 密文 (加密)
    rte_crypto_param sign;      // 输入/输出: 签名
};
```

```c
// === RSA Sessionless 加密示例 ===

int
rsa_sessionless_encrypt(uint8_t dev_id, uint16_t qp_id,
                        struct rte_mempool *op_pool,
                        uint8_t *message, uint16_t msg_len,
                        uint8_t *modulus, uint16_t mod_len,
                        uint8_t *pub_exp, uint16_t exp_len,
                        uint8_t *output)
{
    struct rte_crypto_op *op;
    struct rte_crypto_asym_op *asym_op;

    op = rte_crypto_op_alloc(op_pool, RTE_CRYPTO_OP_TYPE_ASYMMETRIC);
    if (!op)
        return -ENOMEM;

    op->sess_type = RTE_CRYPTO_OP_SESSIONLESS;
    asym_op = op->asym;

    // 1. 准备 RSA xform
    struct rte_crypto_rsa_xform rsa_xform = {
        .n = { .data = modulus, .length = mod_len },
        .e = { .data = pub_exp, .length = exp_len },
        .key_type = RTE_RSA_KEY_TYPE_EXP,
        .padding = {
            .hash = RTE_CRYPTO_AUTH_SHA256,
            .type = RTE_CRYPTO_RSA_PADDING_PKCS1_5,
        },
    };

    // 2. 绑定 xform
    asym_op->xform = &rsa_xform;

    // 3. 设置操作参数
    asym_op->rsa.op_type = RTE_CRYPTO_ASYM_OP_ENCRYPT;
    asym_op->rsa.message.data = message;
    asym_op->rsa.message.length = msg_len;
    asym_op->rsa.cipher.data = output;
    asym_op->rsa.cipher.length = mod_len;  // RSA 密文长度 = 模数长度

    // 4. 入队/出队
    uint16_t nb_enq = rte_cryptodev_enqueue_burst(dev_id, qp_id, &op, 1);
    if (nb_enq != 1) {
        rte_crypto_op_free(op);
        return -EIO;
    }

    // 等待完成
    struct rte_crypto_op *result_op = NULL;
    while (result_op == NULL)
        rte_cryptodev_dequeue_burst(dev_id, qp_id, &result_op, 1);

    if (result_op->status == RTE_CRYPTO_OP_STATUS_SUCCESS)
        return 0;

    rte_crypto_op_free(result_op);
    return -EIO;
}
```

### 3.4 ECDSA Sessionless 示例

```c
// DPDK EC xform (用于 ECDSA/ECDH/EC 等椭圆曲线操作)
struct rte_crypto_ec_xform {
    enum rte_crypto_curve_id curve_id;  // 曲线 (P-256, P-384 等)
    rte_crypto_uint pkey;               // 私钥
    struct rte_crypto_ec_point q;       // 公钥 (x, y)
};

// DPDK ECDSA op param
struct rte_crypto_ecdsa_op_param {
    enum rte_crypto_asym_op_type op_type;  // SIGN 或 VERIFY
    rte_crypto_param message;               // 输入消息哈希
    rte_crypto_uint k;                      // 随机数 k (NULL = PMD 生成)
    rte_crypto_uint r;                      // 签名 r 分量
    rte_crypto_uint s;                      // 签名 s 分量
};

// === ECDSA Sessionless 签名示例 ===

int
ecdsa_sessionless_sign(uint8_t dev_id, uint16_t qp_id,
                       struct rte_mempool *op_pool,
                       uint8_t *hash_msg, uint16_t hash_len,
                       uint8_t *priv_key, uint16_t key_len,
                       uint8_t *sign_r, uint8_t *sign_s)
{
    struct rte_crypto_op *op = rte_crypto_op_alloc(
        op_pool, RTE_CRYPTO_OP_TYPE_ASYMMETRIC);
    if (!op)
        return -ENOMEM;

    op->sess_type = RTE_CRYPTO_OP_SESSIONLESS;
    struct rte_crypto_asym_op *asym_op = op->asym;

    // 1. EC xform (包含私钥和曲线)
    struct rte_crypto_ec_xform ec_xform = {
        .curve_id = RTE_CRYPTO_EC_GROUP_SECP256R1,
        .pkey = { .data = priv_key, .length = key_len },
    };

    asym_op->xform = &ec_xform;

    // 2. ECDSA 操作参数
    asym_op->ecdsa.op_type = RTE_CRYPTO_ASYM_OP_SIGN;
    asym_op->ecdsa.message.data = hash_msg;
    asym_op->ecdsa.message.length = hash_len;
    asym_op->ecdsa.k.data = NULL;  // PMD 自动生成随机数 k

    // 输出: 签名 r 和 s
    asym_op->ecdsa.r.data = sign_r;
    asym_op->ecdsa.r.length = 32;  // P-256 签名分量 32 bytes
    asym_op->ecdsa.s.data = sign_s;
    asym_op->ecdsa.s.length = 32;

    // 3. 入队/出队
    rte_cryptodev_enqueue_burst(dev_id, qp_id, &op, 1);

    struct rte_crypto_op *result = NULL;
    while (!result)
        rte_cryptodev_dequeue_burst(dev_id, qp_id, &result, 1);

    return (result->status == RTE_CRYPTO_OP_STATUS_SUCCESS) ? 0 : -EIO;
}
```

### 3.5 DH/ECDH 密钥交换

```c
// DPDK DH xform — 只有 p 和 g，私钥在 op param 中
struct rte_crypto_dh_xform {
    rte_crypto_uint p;  // 素数模数
    rte_crypto_uint g;  // 生成元
};

// DPDK DH op param
struct rte_crypto_dh_op_param {
    enum rte_crypto_asym_ke_type ke_type;  // 操作类型
    rte_crypto_uint priv_key;               // 私钥 (输入)
    rte_crypto_uint pub_key;                // 公钥 (输入: 对方的 / 输出: 生成的)
    rte_crypto_uint shared_secret;          // 共享密钥 (输出)
};

// === DH Sessionless 共享密钥计算 ===

int
dh_sessionless_compute(uint8_t dev_id, uint16_t qp_id,
                       struct rte_mempool *op_pool,
                       uint8_t *prime_p, uint16_t p_len,
                       uint8_t *generator, uint16_t g_len,
                       uint8_t *my_priv, uint16_t priv_len,
                       uint8_t *peer_pub, uint16_t pub_len,
                       uint8_t *shared_secret, uint16_t *ss_len)
{
    struct rte_crypto_op *op = rte_crypto_op_alloc(
        op_pool, RTE_CRYPTO_OP_TYPE_ASYMMETRIC);
    if (!op) return -ENOMEM;

    op->sess_type = RTE_CRYPTO_OP_SESSIONLESS;
    struct rte_crypto_asym_op *asym_op = op->asym;

    // 1. DH xform
    struct rte_crypto_dh_xform dh_xform = {
        .p = { .data = prime_p, .length = p_len },
        .g = { .data = generator, .length = g_len },
    };
    asym_op->xform = &dh_xform;

    // 2. DH 操作参数
    asym_op->dh.ke_type = RTE_CRYPTO_ASYM_KE_SHARED_SECRET_COMPUTE;
    asym_op->dh.priv_key = { .data = my_priv, .length = priv_len };
    asym_op->dh.pub_key = { .data = peer_pub, .length = pub_len };
    asym_op->dh.shared_secret = { .data = shared_secret, .length = p_len };

    // 3. 入队/出队
    rte_cryptodev_enqueue_burst(dev_id, qp_id, &op, 1);

    struct rte_crypto_op *result = NULL;
    while (!result)
        rte_cryptodev_dequeue_burst(dev_id, qp_id, &result, 1);

    if (result->status == RTE_CRYPTO_OP_STATUS_SUCCESS) {
        *ss_len = asym_op->dh.shared_secret.length;
        return 0;
    }
    return -EIO;
}
```

---

## 4. 批量处理与 Scatter-Gather

### 4.1 mbuf 多段 (Scatter-Gather)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    Scatter-Gather 与 Crypto                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  单段 mbuf (连续内存):                                                     │
│  ──────────────────────                                                    │
│  ┌────────────────────────────────────────┐                                │
│  │           Single Segment Mbuf          │                                │
│  │  ┌──────────────────────────────────┐  │                                │
│  │  │  [   data: offset .. length   ]  │  │                                │
│  │  └──────────────────────────────────┘  │                                │
│  └────────────────────────────────────────┘                                │
│  crypto_op: cipher.data.offset = 14, .length = 1024                       │
│                                                                             │
│  多段 mbuf (Scatter-Gather):                                               │
│  ──────────────────────────                                                │
│  ┌──────┐   ┌──────┐   ┌──────┐                                          │
│  │ seg0 │──►│ seg1 │──►│ seg2 │──► NULL                                 │
│  ├──────┤   ├──────┤   ├──────┤                                          │
│  │ hdr  │   │ data │   │ tag  │                                          │
│  │[14B] │   │[1KB] │   │[16B] │                                          │
│  └──────┘   └──────┘   └──────┘                                          │
│                                                                             │
│  DPDK cryptodev 支持跨段操作:                                              │
│  cipher.data.offset = 14          (从 mbuf 第 14 字节开始)                │
│  cipher.data.length = 1024        (处理 1024 字节)                         │
│  → PMD 自动跨 seg1 的边界处理 (如果数据跨段)                              │
│                                                                             │
│  注意: 不是所有 PMD 都支持跨段操作                                         │
│  - QAT: 支持 (DMA scatter-gather)                                         │
│  - AESNI-MB: 部分支持 (可能需要连续内存)                                  │
│  - OpenSSL PMD: 取决于实现                                                │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 4.2 批量 Sessionless 处理

```c
// === 批量 Sessionless AEAD 加密 ===

// 前提: 每个包可能有不同的密钥 (sessionless 的核心价值)

#define MAX_BURST 32

struct per_packet_key {
    uint8_t key[16];     // AES-128 密钥
    uint8_t iv[12];      // GCM nonce
    uint16_t key_id;     // 密钥 ID
};

uint16_t
batch_sessionless_encrypt(uint8_t dev_id, uint16_t qp_id,
                          struct rte_mempool *op_pool,
                          struct rte_mbuf **mbufs,
                          struct per_packet_key *keys,
                          uint16_t nb_pkts)
{
    struct rte_crypto_op *ops[MAX_BURST];
    struct rte_crypto_sym_xform xforms[MAX_BURST];
    uint16_t i, nb_enq, nb_deq = 0;

    // 1. 为每个包准备独立的 crypto op + xform
    for (i = 0; i < nb_pkts && i < MAX_BURST; i++) {
        ops[i] = rte_crypto_op_alloc(op_pool, RTE_CRYPTO_OP_TYPE_SYMMETRIC);
        if (ops[i] == NULL)
            break;

        ops[i]->sess_type = RTE_CRYPTO_OP_SESSIONLESS;

        // 每个 op 绑定自己的 xform (密钥不同)
        xforms[i].type = RTE_CRYPTO_SYM_XFORM_AEAD;
        xforms[i].next = NULL;
        xforms[i].aead.algo = RTE_CRYPTO_AEAD_AES_GCM;
        xforms[i].aead.op = RTE_CRYPTO_AEAD_OP_ENCRYPT;
        xforms[i].aead.key.data = keys[i].key;
        xforms[i].aead.key.length = 16;
        xforms[i].aead.iv.offset = 0;
        xforms[i].aead.iv.length = 12;
        xforms[i].aead.digest_length = 16;

        ops[i]->sym->xform = &xforms[i];
        ops[i]->sym->m_src = mbufs[i];
        ops[i]->sym->m_dst = mbufs[i];
        ops[i]->sym->aead.data.offset = 0;
        ops[i]->sym->aead.data.length = rte_pktmbuf_pkt_len(mbufs[i]);

        // 追加 tag 空间
        uint8_t *tag = (uint8_t *)rte_pktmbuf_append(mbufs[i], 16);
        if (tag)
            ops[i]->sym->aead.digest.data = tag;

        // 设置 IV
        uint16_t iv_off = (sizeof(struct rte_crypto_sym_op) + 7) & ~7;
        uint8_t *iv_ptr = rte_crypto_op_ctod_offset(ops[i], uint8_t *, iv_off);
        rte_memcpy(iv_ptr, keys[i].iv, 12);
    }

    // 2. 批量入队 (非阻塞)
    nb_enq = rte_cryptodev_enqueue_burst(dev_id, qp_id, ops, i);
    if (nb_enq < i)
        RTE_LOG(WARNING, USER1, "Enqueued %u/%u ops\n", nb_enq, i);

    // 3. 批量出队 (非阻塞，可能需要多次轮询)
    while (nb_deq < nb_enq) {
        nb_deq += rte_cryptodev_dequeue_burst(dev_id, qp_id,
                                                &ops[nb_deq],
                                                nb_enq - nb_deq);
    }

    // 4. 处理结果
    uint16_t success = 0;
    for (i = 0; i < nb_deq; i++) {
        if (ops[i]->status == RTE_CRYPTO_OP_STATUS_SUCCESS) {
            success++;
        } else {
            rte_pktmbuf_free(ops[i]->sym->m_src);
            ops[i]->sym->m_src = NULL;
        }
        rte_crypto_op_free(ops[i]);
    }

    return success;
}
```

> [!warning] xform 生命周期 (批量场景)
> 批量场景中，所有 `xforms[]` 数组必须在整个 `dequeue` 完成前保持有效。
> 上面的例子中 `xforms` 在栈上分配，因为 `dequeue` 是同步轮询完成的。
> 如果使用异步回调模式，需要将 xform 放在堆上或 pool 中。

---

## 5. 自定义协议加密

### 5.1 自定义协议场景

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    自定义协议加密场景                                       │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  场景: 需要非标准加密协议，DPDK 没有专门的卸载支持                        │
│  例如:                                                                     │
│  - 国密 SM4 (中国国家标准)                                                  │
│  - 自定义帧格式 (私有协议)                                                 │
│  - 多层加密 (ESP + 应用层 MAC)                                             │
│  - 非 IPsec 的 VPN 协议                                                   │
│                                                                             │
│  Sessionless 的优势:                                                       │
│  ─────────────────                                                         │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  1. 灵活选择算法: 每包可以用 SM4 或 AES-GCM                        │   │
│  │  2. 自定义帧格式: 不受 IPsec/TLS Record 结构限制                    │   │
│  │  3. 动态密钥: 支持密钥轮换、per-flow 密钥                           │   │
│  │  4. 快速原型: 不需要实现 session 管理逻辑                           │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 5.2 自定义协议加密示例

```c
// === 自定义协议: 自定义头 + AES-128-GCM 加密 ===

// 自定义协议头 (24 字节)
struct custom_proto_hdr {
    uint16_t magic;          // 0xCAFE
    uint8_t  version;        // 协议版本
    uint8_t  flags;          // 标志位
    uint16_t length;         // 载荷长度
    uint32_t sequence;       // 序列号
    uint8_t  iv[12];         // GCM nonce
    uint8_t  reserved[4];    // 保留
} __rte_packed;

#define CUSTOM_HDR_SIZE  sizeof(struct custom_proto_hdr)  // 24 bytes
#define CUSTOM_TAG_SIZE  16  // GCM tag

// 加密: 在 mbuf 前插入自定义头，对载荷做 AEAD 加密
struct rte_mbuf *
custom_proto_encrypt(uint8_t dev_id, uint16_t qp_id,
                     struct rte_mempool *op_pool,
                     struct rte_mbuf *payload,        // 明文载荷
                     uint8_t *key,                     // 加密密钥
                     uint32_t sequence)                // 序列号
{
    struct rte_crypto_op *op;
    struct rte_crypto_sym_op *sym_op;
    struct custom_proto_hdr *hdr;
    uint8_t nonce[12];

    // 1. 前插自定义头
    hdr = (struct custom_proto_hdr *)rte_pktmbuf_prepend(payload, CUSTOM_HDR_SIZE);
    if (hdr == NULL)
        return NULL;

    hdr->magic = rte_cpu_to_be_16(0xCAFE);
    hdr->version = 1;
    hdr->flags = 0;
    hdr->sequence = rte_cpu_to_be_32(sequence);
    hdr->length = rte_cpu_to_be_16(rte_pktmbuf_pkt_len(payload) - CUSTOM_HDR_SIZE);

    // 2. 生成 nonce (简单示例: sequence-based)
    memset(nonce, 0, sizeof(nonce));
    rte_memcpy(nonce, &sequence, 4);

    // 保存 nonce 到头部
    rte_memcpy(hdr->iv, nonce, 12);

    // 3. 追加 tag 空间
    uint8_t *tag = (uint8_t *)rte_pktmbuf_append(payload, CUSTOM_TAG_SIZE);
    if (tag == NULL) {
        rte_pktmbuf_adj(payload, CUSTOM_HDR_SIZE);
        return NULL;
    }

    // 4. 分配 crypto op
    op = rte_crypto_op_alloc(op_pool, RTE_CRYPTO_OP_TYPE_SYMMETRIC);
    if (op == NULL) {
        rte_pktmbuf_adj(payload, CUSTOM_HDR_SIZE + CUSTOM_TAG_SIZE);
        return NULL;
    }

    op->sess_type = RTE_CRYPTO_OP_SESSIONLESS;
    sym_op = op->sym;

    // 5. xform: AES-128-GCM
    struct rte_crypto_sym_xform aead_xform = {
        .type = RTE_CRYPTO_SYM_XFORM_AEAD,
        .next = NULL,
        .aead = {
            .algo = RTE_CRYPTO_AEAD_AES_GCM,
            .op = RTE_CRYPTO_AEAD_OP_ENCRYPT,
            .key.data = key,
            .key.length = 16,
            .iv.offset = 0,
            .iv.length = 12,
            .digest_length = CUSTOM_TAG_SIZE,
            .aad_length = CUSTOM_HDR_SIZE - 12,  // AAD = 头部前 12 字节
        },
    };

    sym_op->xform = &aead_xform;
    sym_op->m_src = payload;
    sym_op->m_dst = payload;  // in-place

    // 6. 数据范围: 跳过头部，加密载荷
    sym_op->aead.data.offset = CUSTOM_HDR_SIZE;
    sym_op->aead.data.length = rte_be_to_cpu_16(hdr->length);

    // 7. AAD: 自定义头的前 12 字节 (magic + version + flags + length + sequence)
    sym_op->aead.aad.data = (uint8_t *)hdr;

    // 8. Digest (tag) 位置
    sym_op->aead.digest.data = tag;

    // 9. IV
    uint16_t iv_off = (sizeof(struct rte_crypto_sym_op) + 7) & ~7;
    uint8_t *iv_ptr = rte_crypto_op_ctod_offset(op, uint8_t *, iv_off);
    rte_memcpy(iv_ptr, nonce, 12);

    // 10. 入队
    uint16_t nb_enq = rte_cryptodev_enqueue_burst(dev_id, qp_id, &op, 1);
    if (nb_enq != 1) {
        rte_crypto_op_free(op);
        return NULL;
    }

    // 11. 等待完成 (同步)
    struct rte_crypto_op *result = NULL;
    while (!result)
        rte_cryptodev_dequeue_burst(dev_id, qp_id, &result, 1);

    if (result->status == RTE_CRYPTO_OP_STATUS_SUCCESS) {
        rte_crypto_op_free(result);
        return payload;
    }

    rte_crypto_op_free(result);
    return NULL;
}
```

### 5.3 自定义协议解密

```c
// === 自定义协议解密 ===

struct rte_mbuf *
custom_proto_decrypt(uint8_t dev_id, uint16_t qp_id,
                     struct rte_mempool *op_pool,
                     struct rte_mbuf *pkt,           // 收到的加密包
                     uint8_t *key)                    // 解密密钥
{
    struct rte_crypto_op *op;
    struct rte_crypto_sym_op *sym_op;
    struct custom_proto_hdr *hdr;

    // 1. 解析自定义头
    hdr = rte_pktmbuf_mtod(pkt, struct custom_proto_hdr *);

    if (rte_be_to_cpu_16(hdr->magic) != 0xCAFE)
        return NULL;

    uint16_t payload_len = rte_be_to_cpu_16(hdr->length);

    // 2. 分配 crypto op
    op = rte_crypto_op_alloc(op_pool, RTE_CRYPTO_OP_TYPE_SYMMETRIC);
    if (!op) return NULL;

    op->sess_type = RTE_CRYPTO_OP_SESSIONLESS;
    sym_op = op->sym;

    // 3. xform: AES-128-GCM 解密
    struct rte_crypto_sym_xform aead_xform = {
        .type = RTE_CRYPTO_SYM_XFORM_AEAD,
        .next = NULL,
        .aead = {
            .algo = RTE_CRYPTO_AEAD_AES_GCM,
            .op = RTE_CRYPTO_AEAD_OP_DECRYPT,
            .key.data = key,
            .key.length = 16,
            .iv.offset = 0,
            .iv.length = 12,
            .digest_length = CUSTOM_TAG_SIZE,
            .aad_length = CUSTOM_HDR_SIZE - 12,
        },
    };

    sym_op->xform = &aead_xform;
    sym_op->m_src = pkt;
    sym_op->m_dst = pkt;

    // 4. 数据范围
    sym_op->aead.data.offset = CUSTOM_HDR_SIZE;
    sym_op->aead.data.length = payload_len;

    // 5. AAD
    sym_op->aead.aad.data = (uint8_t *)hdr;

    // 6. Digest (tag) — 在 mbuf 尾部
    sym_op->aead.digest.data = rte_pktmbuf_mtod_offset(pkt, uint8_t *,
                            CUSTOM_HDR_SIZE + payload_len);

    // 7. IV
    uint16_t iv_off = (sizeof(struct rte_crypto_sym_op) + 7) & ~7;
    uint8_t *iv_ptr = rte_crypto_op_ctod_offset(op, uint8_t *, iv_off);
    rte_memcpy(iv_ptr, hdr->iv, 12);

    // 8. 入队/出队
    rte_cryptodev_enqueue_burst(dev_id, qp_id, &op, 1);

    struct rte_crypto_op *result = NULL;
    while (!result)
        rte_cryptodev_dequeue_burst(dev_id, qp_id, &result, 1);

    if (result->status == RTE_CRYPTO_OP_STATUS_SUCCESS) {
        // 去掉头部和 tag
        rte_pktmbuf_adj(pkt, CUSTOM_HDR_SIZE);
        rte_pktmbuf_trim(pkt, CUSTOM_TAG_SIZE);
        rte_crypto_op_free(result);
        return pkt;
    }

    // GCM 认证失败
    rte_crypto_op_free(result);
    rte_pktmbuf_free(pkt);
    return NULL;
}
```

---

## 6. 操作状态与错误处理

### 6.1 操作状态

```c
// DPDK: lib/cryptodev/rte_crypto.h

enum rte_crypto_op_status {
    RTE_CRYPTO_OP_STATUS_SUCCESS,          // 成功
    RTE_CRYPTO_OP_STATUS_NOT_PROCESSED,    // 未处理
    RTE_CRYPTO_OP_STATUS_AUTH_FAILED,      // 认证失败 (tag 不匹配)
    RTE_CRYPTO_OP_STATUS_INVALID_SESSION,  // 无效 session
    RTE_CRYPTO_OP_STATUS_INVALID_ARGS,     // 无效参数
    RTE_CRYPTO_OP_STATUS_ERROR,            // 通用错误
};
```

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    错误状态处理                                            │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  状态                含义                   处理方式                      │
│  ─────────────────────────────────────────────────────────────             │
│  SUCCESS             操作成功               继续处理                     │
│  NOT_PROCESSED       尚未处理               继续轮询                     │
│  AUTH_FAILED         认证失败 (tag 不匹配)  丢弃包 (可能攻击)            │
│  INVALID_SESSION     session 无效          重建 session                 │
│  INVALID_ARGS        参数错误               检查 mbuf/xform             │
│  ERROR               其他错误               记录日志，丢弃              │
│                                                                             │
│  AUTH_FAILED 是最常见的数据面错误:                                         │
│  - AES-GCM 解密时 tag 不匹配                                             │
│  - HMAC 验证失败                                                          │
│  - 原因: 数据被篡改、密钥不匹配、序列号错误                               │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 6.2 设备统计

```c
// DPDK: lib/cryptodev/rte_cryptodev.h

struct rte_cryptodev_stats {
    uint64_t enqueued_count;      // 入队总数
    uint64_t dequeued_count;      // 出队总数
    uint64_t enqueue_err_count;   // 入队失败数
    uint64_t dequeue_err_count;   // 出队失败数
};

// 获取统计
rte_cryptodev_stats_get(dev_id, &stats);
// 重置统计
rte_cryptodev_stats_reset(dev_id);
```

---

## 7. 国密 SM2/SM4 支持

### 7.1 SM4 对称加密

DPDK 通过 cryptodev 支持 SM4 对称加密（属于 cipher 操作）：

```c
// SM4 Sessionless 加密示例

struct rte_crypto_sym_xform sm4_xform = {
    .type = RTE_CRYPTO_SYM_XFORM_CIPHER,
    .next = NULL,
    .cipher = {
        .algo = RTE_CRYPTO_CIPHER_SM4_ECB,  // 或 SM4_CBC, SM4_CTR, SM4_GCM
        .op = RTE_CRYPTO_CIPHER_OP_ENCRYPT,
        .key.data = sm4_key,
        .key.length = 16,  // SM4 密钥固定 128 bits
        .iv.offset = 0,
        .iv.length = 16,  // SM4 block size = 16 bytes
    },
};

// 使用方式与 AES 完全相同 — PMD 抽象了算法差异
op->sym->xform = &sm4_xform;
op->sym->cipher.data.offset = 0;
op->sym->cipher.data.length = pkt_len;
```

### 7.2 SM2 非对称加密

SM2 在 DPDK 中使用 `rte_crypto_ec_xform`（椭圆曲线 xform）和
`rte_crypto_sm2_op_param`（SM2 操作参数）：

```c
// DPDK: lib/cryptodev/rte_crypto_asym.h

// SM2 操作参数
struct rte_crypto_sm2_op_param {
    enum rte_crypto_asym_op_type op_type;  // SIGN 或 VERIFY
    enum rte_crypto_auth_algorithm hash;   // 使用的哈希算法

    rte_crypto_param message;   // 输入消息
    rte_crypto_param cipher;    // 密文 (加密输出 / 解密输入)
    rte_crypto_param sign;      // 签名 (r || s)
    rte_crypto_param pct;       // C1 || C3 || C2 密文组件
    rte_crypto_param id;        // 用户 ID (SM2 特有)
};

// SM2 使用 EC xform (曲线由 curve_id 指定)
struct rte_crypto_ec_xform sm2_xform = {
    .curve_id = RTE_CRYPTO_EC_GROUP_SM2,
    .pkey = { .data = priv_key, .length = 32 },
    // 公钥通过 q.x, q.y 设置
    .q = {
        .x = { .data = pub_key_x, .length = 32 },
        .y = { .data = pub_key_y, .length = 32 },
    },
};

// SM2 签名
asym_op->xform = &sm2_xform;
asym_op->sm2.op_type = RTE_CRYPTO_ASYM_OP_SIGN;
asym_op->sm2.hash = RTE_CRYPTO_AUTH_SM3;
asym_op->sm2.message.data = hash_msg;
asym_op->sm2.message.length = 32;
asym_op->sm2.sign.data = sign_output;
asym_op->sm2.sign.length = 64;  // r (32B) || s (32B)
asym_op->sm2.id.data = (uint8_t *)"1234567812345678";
asym_op->sm2.id.length = 16;
```

> [!note] SM2 没有独立的 xform 结构
> SM2 使用通用的 `rte_crypto_ec_xform`，通过 `curve_id = RTE_CRYPTO_EC_GROUP_SM2`
> 指定。SM2 特有的参数（用户 ID、C1/C2/C3 格式）在 `rte_crypto_sm2_op_param` 中。

---

## 8. 性能与优化

### 8.1 Session-based vs Sessionless 性能

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    Session-based vs Sessionless 性能                        │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  AES-256-GCM, 1024B payload                                               │
│                                                                             │
│  方案                    吞吐量        CPU 周期/包                          │
│  ──────────────────────────────────────────────────────────────────────── │
│  Session-based          8.5 Gbps        800 cycles                         │
│  Sessionless             7.2 Gbps        950 cycles                         │
│                                                                             │
│  性能差异来源:                                                             │
│  ──────────────                                                           │
│  - Session-based: 密钥已加载到硬件 session 中，op 只需引用 session ID    │
│  - Sessionless: PMD 每次需要解析 xform + 加载密钥 → 额外 ~150 cycles     │
│  - 差异在 QAT 等硬件上更明显 (密钥 DMA 传输)                              │
│  - AESNI-MB (软件 PMD) 差异较小 (密钥直接在 CPU 寄存器加载)              │
│                                                                             │
│  选择建议:                                                                 │
│  ────────                                                                 │
│  ┌──────────────────────┬──────────────────────┐                          │
│  │  静态密钥 → Session  │  动态密钥 → Sessionless│                          │
│  │  (快 ~15%)           │  (灵活)              │                          │
│  └──────────────────────┴──────────────────────┘                          │
│                                                                             │
│  批量处理可弥补 sessionless 开销:                                          │
│  - 32 条批量: sessionless 吞吐接近 session-based                         │
│  - 64 条批量: 差异 < 5%                                                   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 8.2 优化建议

| 优化项             | 说明                                   | 适用场景     |
| ------------------ | -------------------------------------- | ------------ |
| **批量入队**       | 一次 enqueue 32-64 条 op               | 所有场景     |
| **xform 预分配**   | 使用 pool 而非栈分配 xform             | 异步/高并发  |
| **in-place 加密**  | `m_src == m_dst`，减少拷贝             | 大包场景     |
| **IV 偏移对齐**    | `iv_offset` 对齐到 8 字节              | 所有场景     |
| **密钥缓存行对齐** | 避免伪共享                             | 多核并行     |
| **混合模式**       | 静态密钥用 session，动态用 sessionless | 密钥混合场景 |

---

## 9. 小结

本章核心要点：

1. **Sessionless vs Session-based**：Sessionless 模式将 xform（算法+密钥）直接内联在 crypto op 中，跳过 session 创建。代价是每次需要 PMD 解析 xform（~150 cycles 额外开销）。

2. **rte_crypto_sym_op 结构**：`m_src` / `m_dst`（不是 `src.m`），AEAD/cipher/auth 三个 union 提供数据偏移和 digest/aad/iv 访问。IV 通过 op 的 private data 传递。

3. **rte_crypto_sym_xform**：只有 4 种类型（NOT_SPECIFIED、AUTH、CIPHER、AEAD），通过 `next` 指针链式组合，没有 CHAIN 类型。

4. **对称 Sessionless**：设置 `op->sess_type = RTE_CRYPTO_OP_SESSIONLESS`，绑定 `op->sym->xform`。xform 必须在 dequeue 完成前保持有效。

5. **非对称操作**：`rte_crypto_asym_op` 通过 union 访问不同算法的 op param（rsa、ecdsa、dh、ecdh、sm2 等）。op 没有 `type` 字段——操作类型在具体 param 的 `op_type` 中指定。

6. **RSA**：xform 使用 `rte_crypto_uint`（`{data, length}`）而非裸指针。私钥分 `EXP`（指数）和 `QT`（CRT 五元组）两种模式。

7. **ECDSA/ECDH/DH**：xform 通过 `rte_crypto_ec_xform.curve_id` 指定曲线。DH xform 只含 p 和 g，私钥/公钥在 op param 中。ECDSA 的随机数 k 可由 PMD 自动生成。

8. **SM2/SM4**：SM4 作为 cipher 算法使用（SM4_ECB/CBC/CTR/GCM）。SM2 使用通用的 `rte_crypto_ec_xform` + `rte_crypto_sm2_op_param`，没有独立的 SM2 xform。

9. **批量处理**：批量入队 32-64 条 op 可弥补 sessionless 的开销。Scatter-Gather mbuf 支持（取决于 PMD）。

10. **性能选择**：静态密钥用 session（快 ~15%），动态密钥用 sessionless（灵活）。混合场景可两者并存。

**下一篇预告**：[[2026-04-09-dpdk-deep-dive-ch25-cache-optimization|第二十五章]]将讲解 Cache 优化——false sharing、预取与内存访问模式。

---

> [!tip] 参考文献
>
> - DPDK, "Cryptodev Library", https://doc.dpdk.org/guides/prog_guide/cryptodev.html
> - DPDK, "Asymmetric Cryptography", https://doc.dpdk.org/guides/prog_guide/cryptodev_asym.html
> - DPDK source: `lib/cryptodev/rte_crypto_sym.h`, `lib/cryptodev/rte_crypto_asym.h`, `lib/cryptodev/rte_crypto.h`
> - RFC 8017, "PKCS#1 v2.2: RSA Cryptography Specifications"
> - GB/T 32907-2016, "SM4 Block Cipher Algorithm" (国密 SM4)
> - GB/T 32918-2016, "SM2 Elliptic Curve Public Key Cryptography" (国密 SM2)
