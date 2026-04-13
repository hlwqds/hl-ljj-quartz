---
title: "DPDK 深度探索 (二十一)：cryptodev 加密设备与 Crypto PMD"
date: 2026-04-09
tags: [dpdk, series, cryptodev, crypto-pmd, ipsec, aes, hardware-offload, cipher, auth]
description: "深入理解 DPDK cryptodev 框架——对称加密、非对称加密、认证算法、Crypto PMD 驱动、IPSec 加速、NULL Crypto 驱动"
---

> [!info] DPDK 深度探索系列
> 0. [[2026-04-09-dpdk-deep-dive-series-index|全栈学习路径总览]]
> 1-20. 前二十章已完成
> 21. **第二十一章：cryptodev 加密设备与 Crypto PMD**

---

## 1. 概述：为什么需要 Crypto PMD？

### 1.1 网络安全与加密

在数据中心网络中，IPsec 是最常见的传输层安全方案：

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        IPsec 加密流程                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  未加密数据包:                                                             │
│  ┌──────────────────────────────────────────────────────────────────────┐ │
│  │ IP Header │ TCP Header │ HTTP Data │                                  │ │
│  └──────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
│  ESP 加密后:                                                               │
│  ┌──────────────────────────────────────────────────────────────────────┐ │
│  │ IP Header │ ESP Header │ Encrypted TCP+Data │ ESP Trailer │ ESP Auth │ │
│  └──────────────────────────────────────────────────────────────────────┘ │
│                           └── 全部加密 ──┘    └── 可选 ICV ──┘              │
│                                                                             │
│  操作:                                                                     │
│  1. AES-CBC/AES-GCM 加密 (对称加密)                                       │
│  2. HMAC-SHA256 认证 (数据完整性)                                         │
│  3. IV/Nonce 生成                                                         │
│  4. IPsec 头封装                                                           │
│                                                                             │
│  每包额外处理: 3-5 μs (软件)                                              │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 1.2 软件加密瓶颈

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    软件加密瓶颈分析                                         │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  单核 AES-256-GCM 性能:                                                    │
│  ──────────────────────────                                                │
│                                                                             │
│  操作              周期复杂度        延迟 (GHz=3.0)                         │
│  ──────────────────────────────────────────────────────────────────────── │
│  Key Schedule      ~400 cycles      ~133 ns                                │
│  AES Encrypt       ~14 cycles/block  ~5 ns/block (16B)                    │
│  GHASH (GCM)       ~4 cycles/byte    ~1.3 ns/B                           │
│  SHA-256           ~14 cycles/byte   ~4.7 ns/B                           │
│                                                                             │
│  64B 包加密耗时:                                                          │
│  64B AES-256-GCM + HMAC-SHA256 ≈ 2000 cycles ≈ 667 ns                    │
│                                                                             │
│  但是! 网络处理本身也需要 ~200-300 cycles，包处理总共 ~1-2 μs              │
│  加密成为瓶颈!                                                            │
│                                                                             │
│  解决: Crypto PMD (硬件加速)                                              │
│  ──────────────────────────────                                            │
│                                                                             │
│  Intel QAT: ~40 Gbps AES-256-GCM                                          │
│  NVIDIA/Crypto: ~100 Gbps                                                 │
│  加速卡: 加密延迟 < 50 ns                                                 │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 1.3 DPDK Crypto 架构

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        DPDK Crypto 架构                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌──────────────────────────────────────────────────────────────────────┐ │
│  │                      Application                                      │ │
│  │  ┌────────────────┐  ┌────────────────┐  ┌────────────────┐          │ │
│  │  │ IPsec Stack    │  │ TLS/DTLS      │  │ WireGuard     │          │ │
│  │  │ (Libreswan)   │  │ (OpenSSL)     │  │ (userspace)   │          │ │
│  │  └───────┬────────┘  └───────┬────────┘  └───────┬────────┘          │ │
│  │          │                    │                    │                    │ │
│  └──────────┼────────────────────┼────────────────────┼──────────────────┘ │
│             │                    │                    │                     │
│             └────────────────────┴────────────────────┘                     │
│                                  │                                           │
│                                  ▼                                           │
│  ┌──────────────────────────────────────────────────────────────────────┐ │
│  │                    DPDK Cryptodev Library                            │ │
│  │  (lib/librte_cryptodev/)                                            │ │
│  │                                                                       │ │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐│ │
│  │  │  Session    │  │   Session   │  │    Ops      │  │   Sym      ││ │
│  │  │  Management │  │   Pool      │  │   Enqueue   │  │   Crypto   ││ │
│  │  └─────────────┘  └─────────────┘  └─────────────┘  └─────────────┘│ │
│  │                                                                       │ │
│  └───────────────────────────────────────────────────────────────────────┘ │
│                                  │                                           │
│                                  ▼                                           │
│  ┌───────────────────────────────────────────────────────────────────────┐ │
│  │                     Crypto PMD Drivers                                 │ │
│  │                                                                        │ │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐│ │
│  │  │   NULL     │  │   QAT       │  │  AESNI-MB   │  │  OpenSSL    ││ │
│  │  │  (Software) │  │  (Hardware) │  │  (SIMD)     │  │  (Software) ││ │
│  │  └─────────────┘  └─────────────┘  └─────────────┘  └─────────────┘│ │
│  │                                                                        │ │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐                   │ │
│  │  │   Armv8    │  │   SLAPI     │  │   CNDA      │                   │ │
│  │  │  (NEON)    │  │  (QAT)      │  │  (NVIDIA)   │                   │ │
│  │  └─────────────┘  └─────────────┘  └─────────────┘                   │ │
│  │                                                                        │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. cryptodev 核心 API

### 2.1 设备初始化

```c
// lib/librte_cryptodev/rte_cryptodev.h

// cryptodev 设备配置
struct rte_cryptodev_config {
    int socket_id;                    // NUMA 节点
    uint16_t max_nb_queue_pairs;     // 最大队列对数
    uint32_t max_nb_sessions;        // 最大会话数
    uint32_t ff_disable;             // 功能标志禁用
};

// 设备信息
struct rte_cryptodev_info {
    const char *driver_name;          // 驱动名
    const char *device_name;         // 设备名
    uint8_t driver_id;                // 驱动 ID

    // 设备能力
    uint64_t feature_flags;          // RTE_CRYPTODEV_FF_* 标志
    struct rte_cryptodev_capabilities *capabilities;

    // 队列配置
    uint16_t max_nb_queue_pairs;
    uint16_t max_nb_sessions;

    // 缓冲区对齐
    uint8_t min_mbuf_headroom;
    uint8_t min_mbuf_tailroom;
};

// 初始化 cryptodev
int
rte_cryptodev_configure(uint8_t dev_id,
                        const struct rte_cryptodev_config *config)
{
    struct rte_cryptodev *dev = &rte_cryptodev[dev_id];

    // 检查设备存在
    if (!dev->attached)
        return -EINVAL;

    // 配置驱动
    return dev->dev_ops->dev_configure(dev, config);
}

// 启动设备
int
rte_cryptodev_start(uint8_t dev_id)
{
    struct rte_cryptodev *dev = &rte_cryptodev[dev_id];
    return dev->dev_ops->dev_start(dev);
}
```

### 2.2 队列对管理

```c
// 队列对配置
struct rte_cryptodev_qp_conf {
    uint32_t nb_descriptors;         // 描述符数量
    struct rte_crypto_op_pool *mpool; // 操作内存池
    uint8_t *mp_pool;                // 私有 mbuf 池
};

// 队列信息
struct rte_cryptodev_qp_info {
    uint16_t queue_id;
    struct rte_mempool *mpool;
};

// 配置发送队列
int
rte_cryptodev_txq_setup(uint8_t dev_id,
                        uint16_t tx_queue_id,
                        uint16_t nb_desc,
                        uint32_t mp_pool_id)
{
    struct rte_cryptodev *dev = &rte_cryptodev[dev_id];
    struct rte_crypto_qp_ops *ops = dev->dev_ops;

    return ops->tx_q_setup(dev, tx_queue_id, nb_desc, mp_pool_id);
}

// 配置接收队列
int
rte_cryptodev_rxq_setup(uint8_t dev_id,
                        uint16_t rx_queue_id,
                        uint16_t nb_desc,
                        uint32_t mp_pool_id);
```

### 2.3 设备能力

```c
// 设备能力类型
enum rte_cryptodev_type {
    RTE_CRYPTODEV_TYPE_CPU,         // 软件 (NULL, AESNI-MB, OpenSSL)
    RTE_CRYPTODEV_TYPE_IOVA_AS VA, // hardware (QAT, NVIDIA)
    RTE_CRYPTODEV_TYPE_ANY,         // 任意
};

// 对称加密能力
struct rte_cryptodev_symmetric_capability {
    enum rte_crypto_op_type op;      // 操作类型
    enum rte_crypto_asym_xform_type asym_xform; // 非对称

    // 算法能力
    struct {
        enum rte_crypto_cipher_algorithm cipher;
        enum rte_crypto_auth_algorithm auth;
        uint32_t key_size;           // 支持的密钥大小
        uint32_t iv_size;            // IV 大小
    } sym;
};

// 常用能力标志
#define RTE_CRYPTODEV_FF_SYMMETRIC_CRYPTO        (1ULL << 0)
#define RTE_CRYPTODEV_FF_ASYMMETRIC_CRYPTO       (1ULL << 1)
#define RTE_CRYPTODEV_FF_SYM_SESSIONless         (1ULL << 2)
#define RTE_CRYPTODEV_FF_CPU_SSE                 (1ULL << 3)
#define RTE_CRYPTODEV_FF_CPU_AVX                 (1ULL << 4)
#define RTE_CRYPTODEV_FF_CPU_AVX2                (1ULL << 5)
#define RTE_CRYPTODEV_FF_CPU_AVX512              (1ULL << 6)
#define RTE_CRYPTODEV_FF_CPU_AESNI               (1ULL << 7)
#define RTE_CRYPTODEV_FF_HW_ACCELERATED          (1ULL << 8)

// 检查能力
const struct rte_cryptodev_capabilities *
rte_cryptodev_cap_get(uint8_t dev_id);

int
rte_cryptodev_sym_capability_has_session(const struct rte_cryptodev *dev,
                                         const struct rte_cryptodev_sym_capability *cap);
```

---

## 3. 对称加密操作

### 3.1 加密算法

```c
// 对称加密算法
enum rte_crypto_cipher_algorithm {
    RTE_CRYPTO_CIPHER_NULL,           // 无加密
    RTE_CRYPTO_CIPHER_3DES_CBC,       // 3DES CBC
    RTE_CRYPTO_CIPHER_3DES_ECB,       // 3DES ECB
    RTE_CRYPTO_CIPHER_AES_CBC,        // AES CBC
    RTE_CRYPTO_CIPHER_AES_CTR,        // AES CTR
    RTE_CRYPTO_CIPHER_AES_ECB,        // AES ECB
    RTE_CRYPTO_CIPHER_AES_XTS,        // AES XTS (磁盘加密)
    RTE_CRYPTO_CIPHER_AES_GCM,        // AES GCM
    RTE_CRYPTO_CIPHER_AES_CCM,        // AES CCM
    RTE_CRYPTO_CIPHER_CHACHA20_POLY1305, // ChaCha20-Poly1305
    RTE_CRYPTO_CIPHER_KASUMI_F8,      // KASUMI
    RTE_CRYPTO_CIPHER_SNOW3G_UEA2,    // SNOW 3G
    RTE_CRYPTO_CIPHER_ZUC_EEA3,       // ZUC
};

// 密钥大小
enum {
    AES_128_KEY_SIZE = 16,
    AES_192_KEY_SIZE = 24,
    AES_256_KEY_SIZE = 32,
};
```

### 3.2 认证算法

```c
// 认证算法
enum rte_crypto_auth_algorithm {
    RTE_CRYPTO_AUTH_NULL,             // 无认证
    RTE_CRYPTO_AUTH_SHA1_HMAC,       // HMAC-SHA1
    RTE_CRYPTO_AUTH_SHA_224_HMAC,    // HMAC-SHA224
    RTE_CRYPTO_AUTH_SHA_256_HMAC,    // HMAC-SHA256
    RTE_CRYPTO_AUTH_SHA_384_HMAC,    // HMAC-SHA384
    RTE_CRYPTO_AUTH_SHA_512_HMAC,    // HMAC-SHA512
    RTE_CRYPTO_AUTH_AES_CMAC,        // AES-CMAC
    RTE_CRYPTO_AUTH_AES_XCBC_MAC,    // AES-XCBC-MAC
    RTE_CRYPTO_AUTH_AES_GCM,         // AES-GCM (combined)
    RTE_CRYPTO_AUTH_AES_GMAC,        // AES-GMAC
    RTE_CRYPTO_AUTH_CHACHA20_POLY1305, // ChaCha20-Poly1305
    RTE_CRYPTO_AUTH_SNOW3G_UIA2,     // SNOW 3G
    RTE_CRYPTO_AUTH_ZUC_EIA3,        // ZUC
    RTE_CRYPTO_AUTH_MD5_HMAC,        // HMAC-MD5
};
```

### 3.3 转换结构 (xform)

```c
// 加密转换 (cipher only)
struct rte_crypto_cipher_xform {
    enum rte_crypto_cipher_operation op;  // encrypt / decrypt
    enum rte_crypto_cipher_algorithm algo;

    uint8_t *key;                          // 密钥
    uint8_t key_len;                       // 密钥长度
    uint8_t *iv;                           // IV (可选)
    uint8_t iv_len;                        // IV 长度
};

// 认证转换 (auth only)
struct rte_crypto_auth_xform {
    enum rte_crypto_auth_operation op;     // generate / verify
    enum rte_crypto_auth_algorithm algo;

    uint8_t *key;                          // 密钥
    uint8_t key_len;                       // 密钥长度
    uint32_t digest_len;                   // 摘要长度
};

// 联合转换 (AEAD)
struct rte_crypto_aead_xform {
    enum rte_crypto_aead_operation op;     // encrypt / decrypt
    enum rte_crypto_aead_algorithm algo;

    uint8_t *key;                          // 密钥
    uint8_t key_len;                       // 密钥长度
    uint8_t *iv;                           // IV/Nonce
    uint8_t iv_len;                        // IV 长度
    uint8_t *aad;                          // AAD (additional authenticated data)
    uint32_t aad_len;                      // AAD 长度
    uint32_t digest_len;                   // 摘要长度
};

// 链式转换 (cipher + auth)
struct rte_crypto_sym_xform {
    enum rte_crypto_sym_xform_type type;   // cipher / auth / aead / chain

    union {
        struct rte_crypto_cipher_xform cipher;
        struct rte_crypto_auth_xform auth;
        struct rte_crypto_aead_xform aead;
    } x;

    struct rte_crypto_sym_xform *next;    // 下一个转换 (链式)
};
```

---

## 4. 加密操作 (Crypto Operation)

### 4.1 操作结构

```c
// 加密操作结构
struct rte_crypto_op {
    enum rte_crypto_op_type type;          // 操作类型

    // 状态
    volatile uint8_t status;               // 操作状态
    uint8_t sess_type;                     // sessionless / with_session

    // mbuf 引用
    struct rte_mbuf *m_src;               // 源 mbuf
    struct rte_mbuf *m_dst;               // 目标 mbuf (可为 NULL = 原地)

    // 会话
    struct rte_cryptodev_sym_session *session;

    // 读取的 xform (sessionless)
    struct rte_crypto_sym_xform *sym_xform;

    // 用户数据
    void *userdata;

    // 联合头部
    struct rte_crypto_sym_op sym[0];
} __rte_cache_aligned;

// 对称加密操作数据
struct rte_crypto_sym_op {
    // ─────────────────────────────────────────────────────────────────
    // 加密部分
    // ─────────────────────────────────────────────────────────────────
    struct {
        struct {
            uint8_t *data;                 // 数据地址
            uint16_t length;               // 数据长度
            uint16_t offset;               // mbuf 内偏移
        } src, dst;

        uint8_t *iv;                      // IV 地址
        uint16_t iv_len;                  // IV 长度
        uint16_t iv_offset;               // mbuf 内 IV 偏移
    } cipher;

    // ─────────────────────────────────────────────────────────────────
    // 认证部分
    // ─────────────────────────────────────────────────────────────────
    struct {
        struct {
            uint8_t *data;                 // 数据地址
            uint16_t length;               // 数据长度
            uint16_t offset;              // mbuf 内偏移
        } src;

        uint8_t *digest;                  // 摘要地址 (输出/验证)
        uint16_t length;                  // 摘要长度
        uint16_t offset;                  // mbuf 内偏移
    } auth;

    // ─────────────────────────────────────────────────────────────────
    // AEAD 部分 (GCM, CCM, ChaCha20-Poly1305)
    // ─────────────────────────────────────────────────────────────────
    struct {
        struct {
            uint8_t *data;
            uint16_t length;
            uint16_t offset;
        } src, dst;

        uint8_t *iv;                      // Nonce
        uint8_t *aad;                     // Additional Auth Data
        uint16_t aad_len;
        uint8_t *digest;
    } aead;
};
```

### 4.2 操作状态

```c
// 操作状态
enum rte_crypto_op_status {
    RTE_CRYPTO_OP_STATUS_NOT_PROCESSED = 0,
    RTE_CRYPTO_OP_STATUS_SUCCESS,
    RTE_CRYPTO_OP_STATUS_AUTH_FAILED,     // 认证失败
    RTE_CRYPTO_OP_STATUS_INVALID_ARGS,
    RTE_CRYPTO_OP_STATUS_INVALID_SESSION,
    RTE_CRYPTO_OP_STATUS_ERROR,
};
```

### 4.3 操作池

```c
// 创建加密操作池
struct rte_mempool *
rte_crypto_op_pool_create(const char *name,
                          enum rte_crypto_op_type type,
                          unsigned nb_elts,
                          unsigned cache_size,
                          uint16_t priv_size,
                          int socket_id)
{
    struct rte_crypto_op_pool_private *priv;

    // 计算元素大小
    size_t elt_size = sizeof(struct rte_crypto_op);
    if (type == RTE_CRYPTO_OP_TYPE_SYMMETRIC)
        elt_size += sizeof(struct rte_crypto_sym_op);

    // 创建 mempool
    struct rte_mempool *mp = rte_mempool_create(
        name, nb_elts, elt_size,
        cache_size, priv_size,
        NULL, NULL, NULL, NULL,
        socket_id, 0);

    // 设置私有数据
    priv = rte_mempool_get_priv(mp);
    priv->pool_type = type;

    return mp;
}

// 获取操作
static inline struct rte_crypto_op *
rte_crypto_op_alloc(struct rte_mempool *mpool,
                    enum rte_crypto_op_type type)
{
    struct rte_crypto_op *op;

    op = __rte_mempool_get(mpool);
    if (op) {
        op->type = type;
        op->status = RTE_CRYPTO_OP_STATUS_NOT_PROCESSED;
    }

    return op;
}
```

---

## 5. 会话管理

### 5.1 会话结构

```c
// 对称加密会话
struct rte_cryptodev_sym_session {
    void *driver_id;                      // 驱动特定数据
    uint8_t sess_type;                    // 会话类型

    // 转换链表
    struct rte_crypto_sym_xform *xform_chain;

    // 会话数据 (驱动特定，可变大小)
    uint8_t sess_private_data[];
};

// 获取会话大小
int
rte_cryptodev_sym_get_session_private_size(uint8_t dev_id)
{
    struct rte_cryptodev *dev = &rte_cryptodev[dev_id];
    return dev->dev_ops->sym_session_get_size(dev);
}

// 创建会话
struct rte_cryptodev_sym_session *
rte_cryptodev_sym_session_create(uint8_t dev_id,
                                  struct rte_crypto_sym_xform *xforms)
{
    struct rte_cryptodev *dev = &rte_cryptodev[dev_id];
    struct rte_cryptodev_sym_session *session;

    // 分配会话
    size_t size = rte_cryptodev_sym_get_session_private_size(dev_id);
    session = rte_zmalloc(NULL, sizeof(*session) + size, 0);

    // 初始化会话
    int ret = dev->dev_ops->sym_session_init(dev, session, xforms);
    if (ret < 0) {
        rte_free(session);
        return NULL;
    }

    return session;
}

// 释放会话
int
rte_cryptodev_sym_session_free(uint8_t dev_id,
                               struct rte_cryptodev_sym_session *sess)
{
    struct rte_cryptodev *dev = &rte_cryptodev[dev_id];
    return dev->dev_ops->sym_session_clear(dev, sess);
}
```

### 5.2 会话less 操作

```c
// 不使用会话的操作 (每次指定 xform)
// 适合动态密钥场景

// 准备 sessionless 操作
struct rte_crypto_op *
prepare_sessionless_op(struct rte_cryptodev *dev,
                       struct rte_mbuf *m,
                       uint8_t *key, uint8_t key_len,
                       uint8_t *iv)
{
    // 分配操作
    struct rte_crypto_op *op = rte_crypto_op_alloc(dev->op_mpool,
                                                    RTE_CRYPTO_OP_TYPE_SYMMETRIC);
    if (!op)
        return NULL;

    // 设置为 sessionless
    op->sess_type = RTE_CRYPTO_OP_SESSIONLESS;
    op->sym_xform = alloca(sizeof(struct rte_crypto_sym_xform));

    // 配置 AES-GCM
    op->sym_xform->type = RTE_CRYPTO_SYM_XFORM_AEAD;
    op->sym_xform->aead.algo = RTE_CRYPTO_AEAD_AES_GCM;
    op->sym_xform->aead.op = RTE_CRYPTO_AEAD_OP_ENCRYPT;
    op->sym_xform->aead.key = key;
    op->sym_xform->aead.key_len = key_len;
    op->sym_xform->aead.iv = iv;
    op->sym_xform->aead.iv_len = 12;  // GCM nonce = 12 bytes
    op->sym_xform->aead.digest_len = 16;
    op->sym_xform->aead.aad_len = 0;

    // 绑定 mbuf
    op->m_src = m;
    op->m_dst = NULL;  // 原地加密

    // 配置加密参数
    op->sym->cipher.src.offset = 0;
    op->sym->cipher.src.length = rte_pktmbuf_pkt_len(m);
    op->sym->cipher.iv = iv;
    op->sym->cipher.iv_len = 12;

    // 配置认证参数
    op->sym->auth.src.offset = 0;
    op->sym->auth.src.length = rte_pktmbuf_pkt_len(m);
    op->sym->auth.digest_len = 16;
    op->sym->auth.digest = rte_pktmbuf_append(m, 16);

    return op;
}
```

---

## 6. 操作入队/出队

### 6.1 对称加密入队

```c
// 入队单个操作
uint16_t
rte_cryptodev_enqueue_burst(uint8_t dev_id,
                             uint16_t qp_id,
                             struct rte_crypto_op **ops,
                             uint16_t nb_ops)
{
    struct rte_cryptodev *dev = &rte_cryptodev[dev_id];
    struct rte_cryptodev_qp *qp = &dev->qp[qp_id];

    uint16_t enqueued = 0;

    for (uint16_t i = 0; i < nb_ops; i++) {
        struct rte_crypto_op *op = ops[i];

        // 验证操作
        if (validate_op(dev, op) < 0) {
            op->status = RTE_CRYPTO_OP_STATUS_INVALID_ARGS;
            continue;
        }

        // 处理操作
        if (dev->feature_flags & RTE_CRYPTODEV_FF_SYM_SESSIONLESS) {
            process_sessionless_op(qp, op);
        } else {
            process_session_op(qp, op);
        }

        enqueued++;
    }

    // 提交到硬件 (如果有)
    if (dev->dev_ops->qp_send)
        dev->dev_ops->qp_send(qp, enqueued);

    return enqueued;
}

// 批量入队宏
#define RTE_CRYPTODEV_BURST_MAX 32

static inline uint16_t
rte_cryptodev_enqueue_pkts(uint8_t dev_id,
                           uint16_t qp_id,
                           struct rte_crypto_op **ops,
                           uint16_t nb_ops)
{
    return rte_cryptodev_enqueue_burst(dev_id, qp_id, ops, nb_ops);
}
```

### 6.2 对称加密出队

```c
// 出队完成的操作
uint16_t
rte_cryptodev_dequeue_burst(uint8_t dev_id,
                             uint16_t qp_id,
                             struct rte_crypto_op **ops,
                             uint16_t nb_ops)
{
    struct rte_cryptodev *dev = &rte_cryptodev[dev_id];
    struct rte_cryptodev_qp *qp = &dev->qp[qp_id];

    uint16_t dequeued = 0;

    // 从硬件接收 (如果有)
    if (dev->dev_ops->qp_recv) {
        dequeued = dev->dev_ops->qp_recv(qp, ops, nb_ops);
    } else {
        // 软件驱动: 直接从软件队列取出
        dequeued = software_dequeue(qp, ops, nb_ops);
    }

    // 处理完成的操作
    for (uint16_t i = 0; i < dequeued; i++) {
        struct rte_crypto_op *op = ops[i];

        // 验证认证结果 (如果需要)
        if (op->sym->auth.digest) {
            if (verify_digest(op) < 0) {
                op->status = RTE_CRYPTO_OP_STATUS_AUTH_FAILED;
            }
        }
    }

    return dequeued;
}

// 轮询循环
static void
crypto_worker(struct rte_cryptodev *dev, uint16_t qp_id)
{
    struct rte_crypto_op *ops[32];
    uint16_t nb_dequeued;

    while (!quit) {
        // 出队完成的包
        nb_dequeued = rte_cryptodev_dequeue_burst(dev->dev_id, qp_id,
                                                   ops, 32);
        if (nb_dequeued == 0)
            continue;

        // 处理完成的操作
        for (uint16_t i = 0; i < nb_dequeued; i++) {
            struct rte_crypto_op *op = ops[i];

            if (op->status == RTE_CRYPTO_OP_STATUS_SUCCESS) {
                // 发送到网络
                rte_eth_tx_burst(port_id, 0, &op->m_src, 1);
            } else {
                // 错误处理
                rte_pktmbuf_free(op->m_src);
            }

            // 归还操作到池
            rte_crypto_op_free(op);
        }
    }
}
```

---

## 7. Crypto PMD 驱动

### 7.1 PMD 架构

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        Crypto PMD 驱动架构                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌──────────────────────────────────────────────────────────────────────┐ │
│  │                     rte_cryptodev API                                │ │
│  │  (全局表: rte_cryptodev[MAX_CRYPTODEV])                             │ │
│  └──────────────────────────────────────────────────────────────────────┘ │
│                                    │                                         │
│  ┌────────────────────────────────────────────────────────────────────┐ │
│  │                     虚拟 PMD 层                                      │ │
│  │  (函数指针表: dev_ops)                                              │ │
│  │                                                                       │ │
│  │  typedef struct rte_cryptodev_ops {                                 │ │
│  │      int (*dev_configure)(...);                                     │ │
│  │      int (*dev_start)(...);                                         │ │
│  │      int (*dev_stop)(...);                                          │ │
│  │      int (*dev_close)(...);                                          │ │
│  │      int (*queue_pair_setup)(...);                                   │ │
│  │      int (*queue_pair_release)(...);                                 │ │
│  │      int (*sym_session_create)(...);                                │ │
│  │      int (*sym_session_init)(...);                                  │ │
│  │      int (*sym_session_clear)(...);                                 │ │
│  │      int (*sym_session_get_size)(...);                              │ │
│  │      uint16_t (*dequeue_burst)(...);                                │ │
│  │      uint16_t (*enqueue_burst)(...);                                │ │
│  │  } rte_cryptodev_ops;                                                │ │
│  │                                                                       │ │
│  └──────────────────────────────────────────────────────────────────────┘ │
│                                    │                                         │
│  ┌────────────────────────────────────────────────────────────────────┐ │
│  │                     物理 PMD 实现                                    │ │
│  │                                                                        │ │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐  │ │
│  │  │ NULL   │  │ AESNI- │  │  QAT   │  │ OpenSSL │  │  DSW   │  │ │
│  │  │ Crypto │  │   MB   │  │ Driver │  │  Driver │  │ Driver │  │ │
│  │  └─────────┘  └─────────┘  └─────────┘  └─────────┘  └─────────┘  │ │
│  │                                                                        │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 7.2 NULL Crypto PMD (软件回环)

```c
// drivers/crypto/null/null_crypto_pmd.c

// NULL PMD 配置
struct null_crypto_pmd_conf {
    const char *name;
    struct rte_cryptodev_capabilities capabilities[];
};

// NULL PMD 私有数据
struct null_crypto_pmd_private {
    uint8_t max_nb_sessions;
};

// NULL 加密处理
static uint16_t
null_crypto_pmd_sym_enqueue_burst(struct rte_cryptodev *dev,
                                   struct rte_crypto_qp *qp,
                                   struct rte_crypto_op **ops,
                                   uint16_t nb_ops)
{
    for (uint16_t i = 0; i < nb_ops; i++) {
        struct rte_crypto_op *op = ops[i];
        struct rte_crypto_sym_op *sym_op = op->sym;

        // NULL 加密: 不做任何处理，直接标记成功
        // (用于测试)

        // 处理加密
        if (sym_op->cipher.data.length > 0) {
            // 如果需要验证密钥，这里检查
            // 不做任何实际的加密操作
        }

        // 处理认证
        if (sym_op->auth.data.length > 0) {
            // 生成假的认证标签 (全零)
            // 或者复制输入的标签
        }

        op->status = RTE_CRYPTO_OP_STATUS_SUCCESS;
    }

    // 完成操作
    return nb_ops;
}
```

### 7.3 AESNI-MB PMD (SIMD 加速)

```c
// drivers/crypto/aesni_mb/aesni_mb_pmd.c

// AESNI-MB 私有数据
struct aesni_mb_private {
    // IMB 库句柄
    IMB_MGR *mb_mgr;

    // 会话数据
    struct aesni_mb_session *sessions;
    uint16_t max_nb_sessions;
};

// AESNI-MB 支持的算法
static const struct rte_cryptodev_capabilities aesni_mb_capabilities[] = {
    {
        .op = RTE_CRYPTO_OP_TYPE_SYMMETRIC,
        .sym = {
            .xform_type = RTE_CRYPTO_SYM_XFORM_AEAD,
            .aead = {
                .algo = RTE_CRYPTO_AEAD_AES_CCM,
                .key_size = { 16, },
                .iv_len = { 13, },
                .digest_len = { 16, },
                .aad_len = { 32, 36, },
            },
        },
    },
    {
        .op = RTE_CRYPTO_OP_TYPE_SYMMETRIC,
        .sym = {
            .xform_type = RTE_CRYPTO_SYM_XFORM_CIPHER,
            .cipher = {
                .algo = RTE_CRYPTO_CIPHER_AES_CBC,
                .key_size = { 16, 24, 32, },
                .iv_len = { 16, },
            },
        },
    },
    // ... 更多算法
};

// 处理 AES-CBC-HMAC
static int
aesni_mb_process_crypto_op(struct rte_crypto_op *op,
                            struct aesni_mb_session *sess)
{
    struct rte_mbuf *m_src = op->m_src;
    uint8_t *src = rte_pktmbuf_mtod(m_src, uint8_t *);
    uint8_t *dst = (op->m_dst) ? rte_pktmbuf_mtod(op->m_dst, uint8_t *) : src;

    // 获取密钥
    struct aes_key *key = &sess->cipher_key;

    if (sess->cipher_mode == IMB_CIPHER_CBC) {
        // AES-CBC 加密 (使用 IMBNI 库内部实现)
        IMB_AES128_CBC_ENC(mb_mgr, key, iv, src, dst, len);
    }

    if (sess->auth_mode == IMB_AUTH_SHA256_HMAC) {
        // HMAC-SHA256 认证
        uint8_t *digest = op->sym->auth.digest;
        IMB_SHA256_HMAC(mb_mgr, key, src, len, digest);
    }

    return 0;
}
```

### 7.4 QAT PMD (硬件加速)

```c
// drivers/crypto/qat/qat_pmd.c

// QAT 加密会话
struct qat_sym_session {
    // QAT ICP 句柄
    void *qat_sess;                    // ICP_SYM_SESSION

    // 密钥
    uint8_t cipher_key[32];
    uint8_t auth_key[64];

    // QAT 服务 ID
    enum qat_service_type service;
    uint32_t cd_phys_addr;             // 描述符列表物理地址
};

// 创建 QAT 会话
static int
qat_sym_session_create(uint8_t dev_id,
                        struct rte_cryptodev_sym_session *sess,
                        struct rte_crypto_sym_xform *xforms)
{
    struct qat_sym_dev_ctx *ctx = dev->dev_private;

    // 分析 xform 链
    struct rte_crypto_sym_xform *xform = xforms;
    while (xform) {
        switch (xform->type) {
        case RTE_CRYPTO_SYM_XFORM_CIPHER:
            // 配置 QAT 密码服务
            qat_cipher_init_session(ctx, sess, &xform->cipher);
            break;
        case RTE_CRYPTO_SYM_XFORM_AUTH:
            // 配置 QAT 认证服务
            qat_auth_init_session(ctx, sess, &xform->auth);
            break;
        case RTE_CRYPTO_SYM_XFORM_AEAD:
            // 配置 QAT AEAD 服务 (GCM)
            qat_aead_init_session(ctx, sess, &xform->aead);
            break;
        }
        xform = xform->next;
    }

    // 在 QAT 硬件中创建会话
    return qat_sym_session_setup(ctx->qat_dev, sess);
}

// QAT 处理
static uint16_t
qat_pmd_sym_enqueue_burst(void *qp,
                           struct rte_crypto_op **ops,
                           uint16_t nb_ops)
{
    struct qat_qp *qat_qp = qp;
    struct qat_poll_mode *pm = &qat_qp->pm;

    uint16_t nb_enqueued = 0;

    for (uint16_t i = 0; i < nb_ops; i++) {
        struct rte_crypto_op *op = ops[i];

        // 构建 QAT 描述符
        struct qat_sym_op *qat_op = qat_qp->op + qat_qp->op_tail;

        // 填充 QAT 密码描述符
        qat_fill_sym_desc(qat_op, op);

        // 提交到 QAT
        qat_qp->tail = (qat_qp->tail + 1) % qat_qp->nb_desc;

        nb_enqueued++;
    }

    // 门铃
    QAT_PMD_WRITE_tail(qat_qp->bar, qat_qp->tail);

    return nb_enqueued;
}
```

---

## 8. 完整使用示例

### 8.1 简单加密/解密

```c
// AES-256-CBC + HMAC-SHA256 加密

#include <rte_cryptodev.h>
#include <rte_malloc.h>

struct test_crypto {
    uint8_t dev_id;
    uint16_t qp_id;
    struct rte_cryptodev_sym_session *session;
    struct rte_mempool *op_mpool;
};

// 初始化
int
test_crypto_init(struct test_crypto *tc)
{
    // 查找 AESNI-MB 或 QAT 设备
    uint8_t dev_count = rte_cryptodev_count();
    uint8_t dev_id = RTE_CRYPTO_MAX_DEVS;

    for (uint8_t i = 0; i < dev_count; i++) {
        struct rte_cryptodev_info info;
        rte_cryptodev_info_get(i, &info);

        // 查找支持 AES-CBC 的设备
        if (info.feature_flags & RTE_CRYPTODEV_FF_SYMMETRIC_CRYPTO) {
            dev_id = i;
            break;
        }
    }

    if (dev_id == RTE_CRYPTO_MAX_DEVS) {
        printf("No crypto device found\n");
        return -1;
    }

    tc->dev_id = dev_id;

    // 配置设备
    struct rte_cryptodev_config conf = {
        .socket_id = SOCKET_ID_ANY,
        .max_nb_queue_pairs = 1,
        .max_nb_sessions = 1024,
    };
    rte_cryptodev_configure(dev_id, &conf);

    // 设置队列对
    tc->op_mpool = rte_crypto_op_pool_create(
        "crypto_op_pool",
        RTE_CRYPTO_OP_TYPE_SYMMETRIC,
        128, 0, 0, SOCKET_ID_ANY);

    rte_cryptodev_queue_pair_setup(dev_id, 0, 32, tc->op_mpool);
    rte_cryptodev_start(dev_id);

    tc->qp_id = 0;

    // 创建会话
    struct rte_crypto_sym_xform xforms[2] = {
        {
            .type = RTE_CRYPTO_SYM_XFORM_CIPHER,
            .cipher = {
                .op = RTE_CRYPTO_CIPHER_OP_ENCRYPT,
                .algo = RTE_CRYPTO_CIPHER_AES_CBC,
                .key = test_key_256,
                .key_len = 32,
                .iv_len = 16,
            },
        },
        {
            .type = RTE_CRYPTO_SYM_XFORM_AUTH,
            .auth = {
                .op = RTE_CRYPTO_AUTH_OP_GENERATE,
                .algo = RTE_CRYPTO_AUTH_SHA256_HMAC,
                .key = test_hmac_key,
                .key_len = 32,
                .digest_len = 32,
            },
        },
    };
    xforms[0].next = &xforms[1];
    xforms[1].next = NULL;

    tc->session = rte_cryptodev_sym_session_create(dev_id, xforms);

    return 0;
}

// 加密数据包
int
test_encrypt(struct test_crypto *tc, struct rte_mbuf *m)
{
    // 分配操作
    struct rte_crypto_op *op = rte_crypto_op_alloc(tc->op_mpool,
                                                    RTE_CRYPTO_OP_TYPE_SYMMETRIC);
    if (!op)
        return -1;

    // 重置操作
    memset(op, 0, sizeof(*op));
    op->m_src = m;
    op->session = tc->session;

    // 设置加密参数
    op->sym->cipher.src.offset = 0;
    op->sym->cipher.src.length = rte_pktmbuf_pkt_len(m);
    op->sym->cipher.iv = rte_pktmbuf_prepend(m, 16);  // 预置 IV
    op->sym->cipher.iv_len = 16;

    // 生成随机 IV
    rte_rand(op->sym->cipher.iv, 16);

    // 设置认证参数
    op->sym->auth.src.offset = 0;
    op->sym->auth.src.length = rte_pktmbuf_pkt_len(m);
    op->sym->auth.digest = rte_pktmbuf_append(m, 32);  // 追加摘要
    op->sym->auth.digest_len = 32;

    // 入队
    struct rte_crypto_op *ops[1] = { op };
    uint16_t nb_enq = rte_cryptodev_enqueue_burst(tc->dev_id, tc->qp_id,
                                                   ops, 1);

    if (nb_enq == 0) {
        rte_crypto_op_free(op);
        return -1;
    }

    return 0;
}

// 解密数据包
int
test_decrypt(struct test_crypto *tc, struct rte_mbuf *m,
              uint8_t *iv, uint8_t *digest)
{
    struct rte_crypto_op *op = rte_crypto_op_alloc(tc->op_mpool,
                                                    RTE_CRYPTO_OP_TYPE_SYMMETRIC);
    if (!op)
        return -1;

    op->m_src = m;
    op->session = tc->session;

    op->sym->cipher.src.offset = 0;
    op->sym->cipher.src.length = rte_pktmbuf_pkt_len(m) - 32;  // 减去摘要
    op->sym->cipher.iv = iv;
    op->sym->cipher.iv_len = 16;

    op->sym->auth.src.offset = 0;
    op->sym->auth.src.length = rte_pktmbuf_pkt_len(m) - 32;
    op->sym->auth.digest = digest;
    op->sym->auth.digest_len = 32;

    // 入队
    struct rte_crypto_op *ops[1] = { op };
    rte_cryptodev_enqueue_burst(tc->dev_id, tc->qp_id, ops, 1);

    // 出队
    struct rte_crypto_op *deq_ops[1];
    uint16_t nb_deq = rte_cryptodev_dequeue_burst(tc->dev_id, tc->qp_id,
                                                   deq_ops, 1);

    if (nb_deq == 0)
        return -1;

    if (deq_ops[0]->status != RTE_CRYPTO_OP_STATUS_SUCCESS)
        return -1;

    rte_crypto_op_free(deq_ops[0]);
    return 0;
}
```

### 8.2 IPsec ESP 加密

```c
// IPsec ESP 加密

struct esp_hdr {
    uint32_t spi;
    uint32_t seq;
};

struct esp_tailer {
    uint8_t pad_len;
    uint8_t next_header;
    uint16_t pad[5];
};

// AES-GCM 加密
struct rte_crypto_aead_xform *
prepare_esp_aead_xform(const uint8_t *key)
{
    static struct rte_crypto_aead_xform aead = {
        .algo = RTE_CRYPTO_AEAD_AES_GCM,
        .op = RTE_CRYPTO_AEAD_OP_ENCRYPT,
        .key = (uint8_t *)key,
        .key_len = 32,  // AES-256
        .iv_len = 12,   // GCM nonce
        .digest_len = 16,
    };
    return &aead;
}

// ESP 加密函数
struct rte_mbuf *
esp_encrypt(struct rte_mbuf *pkt,
            uint32_t spi,
            uint32_t seq,
            struct rte_cryptodev_sym_session *sess,
            struct rte_mempool *op_pool,
            uint8_t dev_id,
            uint16_t qp_id)
{
    // 分配操作
    struct rte_crypto_op *op = rte_crypto_op_alloc(op_pool,
                                                    RTE_CRYPTO_OP_TYPE_SYMMETRIC);
    if (!op)
        return NULL;

    // 填充 ESP 头
    struct esp_hdr *esp = (struct esp_hdr *)rte_pktmbuf_prepend(pkt, sizeof(*esp));
    esp->spi = rte_cpu_to_be_32(spi);
    esp->seq = rte_cpu_to_be_32(seq);

    // 追加 ESP trailer
    struct esp_tailer *tail = (struct esp_tailer *)rte_pktmbuf_append(pkt, sizeof(*tail));
    tail->pad_len = 0;
    tail->next_header = IPPROTO_IPV6;

    // 设置加密参数
    op->m_src = pkt;
    op->session = sess;

    // 加密: ESP payload (IP 包)
    op->sym->aead.src.offset = sizeof(*esp);
    op->sym->aead.src.length = rte_pktmbuf_pkt_len(pkt) - sizeof(*esp);
    op->sym->aead.digest = rte_pktmbuf_append(pkt, 16);  // ICV
    op->sym->aead.digest_len = 16;
    op->sym->aead.iv_len = 12;

    // 生成 ESP IV (Salt + Counter)
    uint8_t *iv = rte_pktmbuf_prepend(pkt, 12);
    rte_rand(iv, 12);  // 实际应该用正确的 IV

    // 入队
    struct rte_crypto_op *ops[1] = { op };
    rte_cryptodev_enqueue_burst(dev_id, qp_id, ops, 1);

    return pkt;
}
```

---

## 9. 性能与优化

### 9.1 Crypto PMD 性能对比

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        Crypto PMD 性能对比                                │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  AES-256-GCM 加密 (单核)                                                   │
│  ───────────────────────────────                                           │
│                                                                             │
│  PMD               吞吐量        CPU 利用率    效率 (Gbps/Core)            │
│  ──────────────────────────────────────────────────────────────────────── │
│  NULL Crypto       0 (baseline)     0%           -                          │
│  OpenSSL           8 Gbps          85%          9.4 Gbps                    │
│  AESNI-MB (AVX2)   25 Gbps         80%          31 Gbps                    │
│  AESNI-MB (AVX512) 40 Gbps         75%          53 Gbps                    │
│  QAT (GEN3)        70 Gbps         15%          466 Gbps                    │
│  NVIDIA BlueField  100 Gbps        10%          1000 Gbps                   │
│                                                                             │
│  IPsec ESP (AES-256-GCM) 隧道                                                  │
│  ─────────────────────────────────────────                                 │
│                                                                             │
│  配置                  吞吐量        包处理 (64B)                           │
│  ──────────────────────────────────────────────────────────────────────── │
│  软件 (OpenSSL)        5 Gbps          7.5 Mpps                            │
│  AESNI-MB (AVX2)      20 Gbps         30 Mpps                             │
│  QAT (2x40GbE)       80 Gbps         120 Mpps                            │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 9.2 优化建议

| 优化项 | 说明 | 效果 |
|--------|------|------|
| **批量入队** | 每次入队 32+ 操作 | 减少同步开销 |
| **异步轮询** | 无锁轮询完成队列 | 降低延迟 |
| **mbuf 布局** | 连续缓冲区减少 scatter | 提升性能 |
| **会话复用** | 避免每次创建会话 | 降低开销 |
| **硬件选择** | QAT/NVIDIA 加速卡 | 10x+ 提升 |
| **对齐** | 缓存行对齐操作 | 避免伪共享 |

---

## 10. 小结

本章核心要点：

1. **背景**：IPsec/TLS 加密是网络瓶颈，软件加密 ~1-2 μs，硬件加速 < 50ns。

2. **DPDK Crypto 架构**：cryptodev 抽象层 + Crypto PMD 驱动栈 (NULL/AESNI-MB/QAT/OpenSSL)。

3. **设备 API**：rte_cryptodev_configure/start/queue_pair_setup，设备能力查询。

4. **对称加密算法**：AES-CBC/CTR/GCM、3DES、ChaCha20-Poly1305、ZUC 等。

5. **认证算法**：HMAC-SHA*、AES-CMAC、GCM/GMAC、Poly1305 等。

6. **转换结构 (xform)**：cipher_xform、auth_xform、aead_xform，可链式组合。

7. **操作结构**：rte_crypto_op + rte_crypto_sym_op，mbuf 绑定，状态跟踪。

8. **会话管理**：rte_cryptodev_sym_session_create/free，会话 vs sessionless 模式。

9. **PMD 驱动**：虚拟 ops 表 + 物理实现，NULL (测试)、AESNI-MB (SIMD)、QAT (硬件)。

10. **性能**：QAT 可达 70 Gbps AES-256-GCM，NVIDIA BlueField 可达 100 Gbps。

**下一篇预告**：[[2026-04-09-dpdk-deep-dive-ch22-telemetry|第二十二章]]将讲解 DPDK Telemetry 与性能分析——系统可观测性实现。

---

> [!tip] 参考文献
> - Intel, "DPDK Cryptodev", https://doc.dpdk.org/guides/prog_guide/cryptodev.html
> - Intel, "AESNI-MB PMD", https://doc.dpdk.org/guides/cryptodevs/aesni_mb.html
> - Intel, "QAT PMD", https://doc.dpdk.org/guides/cryptodevs/qat.html
> - "IPsec and DPDK", https://doc.dpdk.org/guides/howto/ipsec_secgw.html
