---
title: "DPDK 深度探索 (二十一)：cryptodev 加密设备与 Crypto PMD"
date: 2026-04-09
tags: [dpdk, series, cryptodev, crypto-pmd, ipsec, aes, hardware-offload, cipher, auth]
description: "深入理解 DPDK cryptodev 框架——对称加密、AEAD、认证算法、Crypto PMD 驱动、IPsec 加速、NULL Crypto 驱动"
---

> [!info] DPDK 深度探索系列
> 0. [[2026-04-09-dpdk-deep-dive-series-index|全栈学习路径总览]]
> 1-19. 前十九章已完成
> 19b. [[2026-04-09-dpdk-deep-dive-ch19b-dpu-smartnic|第十九章补充：DPU/SmartNIC 基础]]
> 20. [[2026-04-09-dpdk-deep-dive-ch20-simd-avx512|第二十章：AVX512/SIMD 数据包处理向量化]]
> 21. **第二十一章：cryptodev 加密设备与 Crypto PMD**

---

## 1. 概述：为什么需要 Crypto PMD？

### 1.1 网络安全与加密

在数据中心网络中，IPsec 是最常见的传输层安全方案：

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        IPsec ESP 加密流程                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  未加密数据包:                                                             │
│  ┌──────────────────────────────────────────────────────────────────────┐ │
│  │ IP Header │ TCP Header │ HTTP Data (明文)                            │ │
│  └──────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
│  ESP 加密后:                                                               │
│  ┌──────────────────────────────────────────────────────────────────────┐ │
│  │ IP Hdr │ ESP Hdr │ IV │ Encrypted(TCP+Data) │ Pad │ NH │ ICV │       │ │
│  └──────────────────────────────────────────────────────────────────────┘ │
│                   └────── AES-GCM 加密 ──────┘                          │
│                                                   └─── 认证 ──┘      │
│                                                                             │
│  操作:                                                                     │
│  1. AES-GCM 加密 (AEAD: 加密 + 认证一步完成)                             │
│  2. IV/Nonce 生成                                                         │
│  3. IPsec ESP 头封装                                                     │
│                                                                             │
│  软件加密 64B 包: ~2-3 μs → 成为网络瓶颈                               │
│  硬件加密 64B 包: ~50-100 ns → 几乎无感                                   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 1.2 DPDK Crypto 架构

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        DPDK Crypto 架构                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌──────────────────────────────────────────────────────────────────────┐ │
│  │                      Application                                      │ │
│  │  ┌────────────────┐  ┌────────────────┐  ┌────────────────┐          │ │
│  │  │ IPsec GW      │  │ TLS 终端     │  │ WireGuard     │          │ │
│  │  │ (libipsec)   │  │ (OpenSSL)     │  │ (userspace)   │          │ │
│  │  └───────┬────────┘  └───────┬────────┘  └───────┬────────┘          │ │
│  └──────────┼────────────────────┼────────────────────┼──────────────────┘ │
│             └────────────────────┴────────────────────┘                     │
│                                  │                                           │
│                                  ▼                                           │
│  ┌──────────────────────────────────────────────────────────────────────┐ │
│  │                    DPDK Cryptodev Library                            │ │
│  │  (lib/cryptodev/)                                                     │ │
│  │                                                                       │ │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐│ │
│  │  │  Session    │  │   Queue     │  │  Enqueue    │  │  Dequeue    ││ │
│  │  │  Management │  │  Pair Setup │  │  / Dequeue  │  │             ││ │
│  │  └─────────────┘  └─────────────┘  └─────────────┘  └─────────────┘│ │
│  │                                                                       │
│  └──────────────────────────────────────────────────────────────────────┘ │
│                                  │                                           │
│                                  ▼                                           │
│  ┌──────────────────────────────────────────────────────────────────────┐ │
│  │                     Crypto PMD Drivers                                 │ │
│  │                                                                        │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐  │ │
│  │  │   NULL   │  │ AESNI-  │  │   QAT   │  │  OpenSSL │  │  DSW    │  │ │
│  │  │  (测试)  │  │   MB   │  │ (Intel) │  │  (SW)   │  │ (调度)  │  │ │
│  │  └─────────┘  └─────────┘  └─────────┘  └─────────┘  └─────────┘  │ │
│  │                                                                        │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐                             │ │
│  │  │  ARMv8  │  │   OCTEON│  │   CNDA   │                             │ │
│  │  │  (NEON)  │  │ (Marvell)│ │ (NVIDIA)│                             │ │
│  │  └─────────┘  └─────────┘  └─────────┘                             │ │
│  │                                                                        │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. cryptodev 核心 API

### 2.1 设备初始化

```c
#include <rte_cryptodev.h>
#include <rte_cryptodev_pmd.h>  // 用于 rte_cryptodev_get_dev_id()

// ─────────────────────────────────────────────────────────────────
// 1. 查找并配置 crypto 设备
// ─────────────────────────────────────────────────────────────────

// 查找支持 AES-GCM 的设备
uint8_t dev_id = rte_cryptodev_get_dev_id("crypto_aesni_mb");
if (dev_id == rte_cryptodev_count()) {
    printf("No AESNI-MB device found, trying any device\n");
    dev_id = 0;  // 使用第一个设备
}

// 获取设备信息
struct rte_cryptodev_info dev_info;
rte_cryptodev_info_get(dev_id, &dev_info);
printf("Driver: %s, max queue pairs: %u\n",
       dev_info.driver_name, dev_info.max_nb_queue_pairs);

// 配置设备 (注意: 没有 max_nb_sessions 参数，它在 info 中)
struct rte_cryptodev_config conf = {
    .socket_id = SOCKET_ID_ANY,
    .nb_queue_pairs = 1,
    .ff_disable = 0,  // 不禁用任何特性
};
int ret = rte_cryptodev_configure(dev_id, &conf);
if (ret < 0)
    rte_exit(EXIT_FAILURE, "Failed to configure crypto device\n");

// ─────────────────────────────────────────────────────────────────
// 2. 创建操作内存池 (存放 rte_crypto_op)
// ─────────────────────────────────────────────────────────────────

struct rte_mempool *op_mp = rte_crypto_op_pool_create(
    "crypto_op_pool",
    RTE_CRYPTO_OP_TYPE_SYMMETRIC,  // 对称加密操作
    1024,     // 最大操作数
    128,      // cache size
    0,        // private data size
    SOCKET_ID_ANY);

// ─────────────────────────────────────────────────────────────────
// 3. 创建会话内存池 (存放 crypto session)
// ─────────────────────────────────────────────────────────────────

// 获取会话需要的私有数据大小
unsigned session_size = rte_cryptodev_sym_get_private_session_size(dev_id);
unsigned max_sessions = dev_info.sym.max_nb_sessions;

struct rte_mempool *sess_mp = rte_mempool_create(
    "crypto_sess_pool",
    max_sessions,
    session_size + sizeof(void *),  // session + driver private data
    0,
    SOCKET_ID_ANY);

// ─────────────────────────────────────────────────────────────────
// 4. 设置队列对 (queue pair)
// ─────────────────────────────────────────────────────────────────

// 注意: mp 是 session mempool，不是 op mempool!
struct rte_cryptodev_qp_conf qp_conf = {
    .nb_descriptors = 256,
    .mp_session = sess_mp,
    .priority = 0,
};
ret = rte_cryptodev_queue_pair_setup(dev_id, 0, &qp_conf, SOCKET_ID_ANY);
if (ret < 0)
    rte_exit(EXIT_FAILURE, "Failed to setup queue pair\n");

// ─────────────────────────────────────────────────────────────────
// 5. 启动设备
// ─────────────────────────────────────────────────────────────────

ret = rte_cryptodev_start(dev_id);
if (ret < 0)
    rte_exit(EXIT_FAILURE, "Failed to start crypto device\n");
```

### 2.2 设备能力

```c
// 查询设备支持的算法
const struct rte_cryptodev_capabilities *cap;
while ((cap = rte_cryptodev_capabilities_get(dev_id, cap)) != NULL) {
    if (cap->op == RTE_CRYPTO_OP_TYPE_SYMMETRIC) {
        if (cap->sym.xform_type == RTE_CRYPTO_SYM_XFORM_CIPHER) {
            printf("Cipher: %s, key: %u-%u, iv: %u-%u\n",
                   cap->sym.cipher.algo, cap->sym.cipher.key_size.min,
                   cap->sym.cipher.key_size.max, cap->sym.cipher.iv_size.min,
                   cap->sym.cipher.iv_size.max);
        }
        if (cap->sym.xform_type == RTE_CRYPTO_SYM_XFORM_AEAD) {
            printf("AEAD: %s, key: %u-%u, digest: %u-%u\n",
                   cap->sym.aead.algo, cap->sym.aead.key_size.min,
                   cap->sym.aead.key_size.max, cap->sym.aead.digest_size.min,
                   cap->sym.aead.digest_size.max);
        }
    }
}

// 常用能力标志 (定义在 rte_cryptodev.h)
RTE_CRYPTODEV_FF_SYMMETRIC_CRYPTO      // 支持对称加密
RTE_CRYPTODEV_FF_ASYMMETRIC_CRYPTO     // 支持非对称加密
RTE_CRYPTODEV_FF_SYM_SESSIONLESS       // 支持 sessionless 模式
RTE_CRYPTODEV_FF_HW_ACCELERATED        // 硬件加速
RTE_CRYPTODEV_FF_CPU_AESNI             // CPU 支持 AES-NI
RTE_CRYPTODEV_FF_SECURITY_SESSIONS    // 安全会话 (用于 DOCSIS)
```

---

## 3. 对称加密操作

### 3.1 加密与认证算法

```c
// 加密算法
enum rte_crypto_cipher_algorithm {
    RTE_CRYPTO_CIPHER_NULL,              // 无加密
    RTE_CRYPTO_CIPHER_3DES_CBC,          // 3DES CBC
    RTE_CRYPTO_CIPHER_3DES_ECB,          // 3DES ECB
    RTE_CRYPTO_CIPHER_AES_CBC,           // AES CBC
    RTE_CRYPTO_CIPHER_AES_CTR,           // AES CTR
    RTE_CRYPTO_CIPHER_AES_ECB,           // AES ECB
    RTE_CRYPTO_CIPHER_AES_XTS,           // AES XTS (磁盘加密)
    RTE_CRYPTO_CIPHER_AES_GCM,           // AES GCM (AEAD)
    RTE_CRYPTO_CIPHER_AES_CCM,           // AES CCM (AEAD)
    RTE_CRYPTO_CIPHER_CHACHA20_POLY1305,  // ChaCha20-Poly1305 (AEAD)
    RTE_CRYPTO_CIPHER_KASUMI_F8,         // KASUMI F8
    RTE_CRYPTO_CIPHER_SNOW3G_UEA2,       // SNOW 3G UEA2
    RTE_CRYPTO_CIPHER_ZUC_EEA3,          // ZUC EEA3
};

// 认证算法
enum rte_crypto_auth_algorithm {
    RTE_CRYPTO_AUTH_NULL,                 // 无认证
    RTE_CRYPTO_AUTH_SHA1_HMAC,           // HMAC-SHA1
    RTE_CRYPTO_AUTH_SHA_224_HMAC,        // HMAC-SHA224
    RTE_CRYPTO_AUTH_SHA_256_HMAC,        // HMAC-SHA256
    RTE_CRYPTO_AUTH_SHA_384_HMAC,        // HMAC-SHA384
    RTE_CRYPTO_AUTH_SHA_512_HMAC,        // HMAC-SHA512
    RTE_CRYPTO_AUTH_AES_CMAC,            // AES-CMAC
    RTE_CRYPTO_AUTH_AES_XCBC_MAC,        // AES-XCBC-MAC
    RTE_CRYPTO_AUTH_AES_GMAC,            // AES-GMAC (仅认证，不加密)
    RTE_CRYPTO_AUTH_SNOW3G_UIA2,         // SNOW 3G UIA2
    RTE_CRYPTO_AUTH_ZUC_EIA3,            // ZUC EIA3
    RTE_CRYPTO_AUTH_MD5_HMAC,            // HMAC-MD5 (已不推荐)
};
```

### 3.2 转换结构 (xform)

```c
// ─────────────────────────────────────────────────────────────────
// 重要: DPDK cryptodev 中数据通过 mbuf 内的 offset+length 引用，
// 不使用 raw 指针。IV 也是如此。
// ─────────────────────────────────────────────────────────────────

// 单一 cipher 转换
struct rte_crypto_cipher_xform {
    enum rte_crypto_cipher_operation op;  // ENCRYPT / DECRYPT
    enum rte_crypto_cipher_algorithm algo;

    uint8_t *key;          // 密钥数据 (指向用户提供的 buffer)
    uint16_t key_len;     // 密钥长度

    struct {
        uint16_t offset;  // IV 相对于 crypto_op 起始位置的偏移
        uint16_t length;  // IV 长度
    } iv;
    // 注意: 没有 iv 数据指针！IV 通过偏移量从 crypto_op 的
    // 附加空间或 mbuf 中读取
};

// 单一 auth 转换
struct rte_crypto_auth_xform {
    enum rte_crypto_auth_operation op;   // GENERATE / VERIFY
    enum rte_crypto_auth_algorithm algo;

    uint8_t *key;          // 认证密钥
    uint16_t key_len;
    uint32_t digest_len;  // 摘要长度 (SHA256=32, SHA1=20)
};

// AEAD 转换 (加密+认证合一: GCM, CCM, ChaCha20-Poly1305)
struct rte_crypto_aead_xform {
    enum rte_crypto_aead_operation op;   // ENCRYPT / DECRYPT
    enum rte_crypto_aead_algorithm algo;

    uint8_t *key;
    uint16_t key_len;

    struct {
        uint16_t offset;
        uint16_t length;
    } iv;

    uint32_t aad_len;     // AAD (Additional Authenticated Data) 长度
    uint32_t digest_len;  // 摘要长度
};

// 链式转换 (cipher + auth 分开)
struct rte_crypto_sym_xform {
    enum rte_crypto_sym_xform_type type;  // CIPHER / AUTH / AEAD

    union {
        struct rte_crypto_cipher_xform cipher;
        struct rte_crypto_auth_xform auth;
        struct rte_crypto_aead_xform aead;
    } x;

    struct rte_crypto_sym_xform *next;   // 链式: cipher → auth 或反向
};
```

---

## 4. 加密操作 (Crypto Operation)

### 4.1 操作结构

```c
// ─────────────────────────────────────────────────────────────────
// rte_crypto_op 是操作的总入口，包含 mbuf 引用和对称操作数据
// ─────────────────────────────────────────────────────────────────

struct rte_crypto_op {
    int status;             // 操作状态 (成功/失败/未处理)
    enum rte_crypto_op_type type;  // SYMMETRIC / ASYMMETRIC
    enum rte_crypto_op_sess_type sess_type;  // WITH_SESSION / SESSIONLESS

    // 源和目标 mbuf (对称操作数据在这里)
    struct rte_mbuf *symm_src;   // 源 mbuf
    struct rte_mbuf *symm_dst;   // 目标 mbuf (NULL = 原地操作)

    // 会话指针 (WITH_SESSION 模式)
    void *sym_session;

    // 用户私有数据
    void *userdata;

    // 对称操作数据 (flexible array member, 内联)
    struct rte_crypto_sym_op sym[];
};

// 对称操作数据
struct rte_crypto_sym_op {
    // 加密部分
    struct {
        struct {
            uint32_t offset;  // 相对于 mbuf 数据起始的偏移
            uint32_t length;  // 加密数据长度
        } data;
        struct {
            uint16_t offset;  // IV 偏移
            uint16_t length;  // IV 长度
        } iv;
    } cipher;

    // 认证部分
    struct {
        struct {
            uint32_t offset;  // 认证数据起始偏移
            uint32_t length;  // 认证数据长度
        } data;
        struct {
            uint32_t offset;  // 摘要偏移 (输出/验证)
            uint32_t length;  // 摘要长度
        } digest;
    } auth;

    // AEAD 部分 (GCM, CCM, ChaCha20-Poly1305)
    struct {
        struct {
            uint32_t offset;
            uint32_t length;
        } data;               // 明文/密文数据
        struct {
            uint32_t offset;
            uint32_t length;
        } aad;                // Additional Authenticated Data
        struct {
            uint32_t offset;
            uint32_t length;
        } digest;            // 认证标签
        struct {
            uint16_t offset;
            uint16_t length;
        } iv;
    } aead;
};

// 注意: 没有 raw data 指针！所有数据都通过 mbuf + offset 引用。
// 这是 DPDK cryptodev 的核心设计 — 数据始终在 mbuf 中，不需要额外拷贝。
```

### 4.2 操作状态

```c
enum rte_crypto_op_status {
    RTE_CRYPTO_OP_STATUS_NOT_PROCESSED,
    RTE_CRYPTO_OP_STATUS_SUCCESS,
    RTE_CRYPTO_OP_STATUS_AUTH_FAILED,      // 认证失败 (HMAC 验证不匹配)
    RTE_CRYPTO_OP_STATUS_INVALID_ARGS,
    RTE_CRYPTO_OP_STATUS_INVALID_SESSION,
    RTE_CRYPTO_OP_STATUS_ERROR,
};
```

### 4.3 操作池与分配

```c
// 分配单个操作
struct rte_crypto_op *op = rte_crypto_op_alloc(op_mpool,
                                               RTE_CRYPTO_OP_TYPE_SYMMETRIC);
if (!op) {
    // 处理分配失败
}

// 批量分配
struct rte_crypto_op *ops[32];
uint16_t nb_ops = rte_crypto_op_bulk_alloc(op_mpool, ops, 32, NULL);
if (nb_ops == 0) {
    // 处理分配失败
}

// 释放操作
rte_crypto_op_free(op);
// 批量释放
rte_crypto_op_bulk_free(ops, nb_ops);
```

---

## 5. 会话管理

### 5.1 创建与释放

```c
// ─────────────────────────────────────────────────────────────────
// DPDK session 需要从 mempool 分配 (不能 rte_zmalloc)
// ─────────────────────────────────────────────────────────────────

// 创建会话 (AES-256-GCM)
struct rte_crypto_sym_xform aead_xform = {
    .type = RTE_CRYPTO_SYM_XFORM_AEAD,
    .aead = {
        .algo = RTE_CRYPTO_AEAD_AES_GCM,
        .op = RTE_CRYPTO_AEAD_OP_ENCRYPT,
        .key_len = 32,  // AES-256
        .iv_len = 12,   // GCM 标准 nonce 长度
        .aad_len = 0,
        .digest_len = 16,
    },
    aead_xform.aead.key = (uint8_t *)test_key_256,
};
aead_xform.aead.iv.offset = 0;
aead_xform.aead.iv.length = 12;

// 创建 session (返回 void*，需要 mempool)
void *session = rte_cryptodev_sym_session_create(
    dev_id, &aead_xform, sess_mp);
if (session == NULL) {
    printf("Session creation failed\n");
}

// ─────────────────────────────────────────────────────────────────
// 链式 xform: AES-CBC + HMAC-SHA256 (先加密后认证)
// ─────────────────────────────────────────────────────────────────

struct rte_crypto_sym_xform cipher_xform = {
    .type = RTE_CRYPTO_SYM_XFORM_CIPHER,
    .cipher = {
        .algo = RTE_CRYPTO_CIPHER_AES_CBC,
        .op = RTE_CRYPTO_CIPHER_OP_ENCRYPT,
        .key_len = 32,
        .iv_len = 16,
    },
    .cipher.cipher.key = (uint8_t *)cipher_key,
    .cipher.iv.offset = 0,
    .cipher.iv.length = 16,
};

struct rte_crypto_sym_xform auth_xform = {
    .type = RTE_CRYPTO_SYM_XFORM_AUTH,
    .auth = {
        .algo = RTE_CRYPTO_AUTH_SHA_256_HMAC,
        .op = RTE_CRYPTO_AUTH_OP_GENERATE,
        .key_len = 32,
        .digest_len = 32,
    },
    .auth.auth.key = (uint8_t *)hmac_key,
};

// cipher → auth 链
cipher_xform.next = &auth_xform;
auth_xform.next = NULL;

void *session2 = rte_cryptodev_sym_session_create(
    dev_id, &cipher_xform, sess_mp);

// 释放会话
rte_cryptodev_sym_session_free(dev_id, session);
```

### 5.2 Sessionless 模式

```c
// Sessionless: 每次操作直接携带 xform，不需要预创建 session
// 适用场景: 动态密钥切换、少量操作

struct rte_crypto_op *op = rte_crypto_op_alloc(op_mp,
                                               RTE_CRYPTO_OP_TYPE_SYMMETRIC);
op->sess_type = RTE_CRYPTO_OP_SESSIONLESS;
op->sym->xform = &aead_xform;  // 直接挂 xform

// 注意: sessionless 模式每次都要解析 xform，有性能开销
// 生产环境推荐使用 session 模式
```

---

## 6. 操作入队/出队

### 6.1 加密流程

```c
// ─────────────────────────────────────────────────────────────────
// 完整的 AES-256-GCM 加密流程
// ─────────────────────────────────────────────────────────────────

static int
encrypt_packet(struct rte_mbuf *m, void *session,
                uint8_t dev_id, uint16_t qp_id,
                struct rte_mempool *op_mp)
{
    // 1. 分配 crypto op
    struct rte_crypto_op *op = rte_crypto_op_alloc(op_mp,
                                                   RTE_CRYPTO_OP_TYPE_SYMMETRIC);
    if (!op)
        return -ENOMEM;

    // 2. 绑定 mbuf 和 session
    op->symm_src = m;
    op->symm_dst = NULL;  // 原地加密 (in-place)
    op->sym_session = session;
    op->sess_type = RTE_CRYPTO_OP_WITH_SESSION;

    // 3. 设置 AEAD 参数
    // 加密整个 IP payload (跳过 IP 头和 ESP 头)
    uint32_t payload_offset = sizeof(struct ip_hdr) + sizeof(struct esp_hdr);
    uint32_t payload_len = rte_pktmbuf_pkt_len(m) - payload_offset;

    op->sym->aead.data.offset = payload_offset;
    op->sym->aead.data.length = payload_len;
    op->sym->aead.aad.offset = 0;     // AAD = IP header (明文)
    op->sym->aead.aad.length = sizeof(struct ip_hdr);
    op->sym->aead.digest.offset = rte_pktmbuf_pkt_len(m);  // digest 追加到 mbuf 末尾
    op->sym->aead.digest.length = 16;

    // 4. 入队
    struct rte_crypto_op *ops[1] = { op };
    uint16_t enqd = rte_cryptodev_enqueue_burst(dev_id, qp_id, ops, 1);
    if (enqd == 0) {
        rte_crypto_op_free(op);
        return -EBUSY;
    }

    return 0;
}

// ─────────────────────────────────────────────────────────────────
// 轮询完成 + 处理
// ─────────────────────────────────────────────────────────────────

static void
crypto_poll_loop(uint8_t dev_id, uint16_t qp_id, uint16_t port_id)
{
    struct rte_crypto_op *deq_ops[32];
    struct rte_mbuf *tx_pkts[32];

    while (!quit) {
        // 出队已完成的操作
        uint16_t nb_deq = rte_cryptodev_dequeue_burst(
            dev_id, qp_id, deq_ops, 32);

        if (nb_deq == 0) {
            // 无完成操作，继续轮询
            continue;
        }

        // 处理每个完成的操作
        uint16_t nb_tx = 0;
        for (uint16_t i = 0; i < nb_deq; i++) {
            struct rte_crypto_op *op = deq_ops[i];

            if (op->status == RTE_CRYPTO_OP_STATUS_SUCCESS) {
                tx_pkts[nb_tx++] = op->symm_src;
            } else {
                // 加密失败，释放 mbuf
                rte_pktmbuf_free(op->symm_src);
            }
            rte_crypto_op_free(op);
        }

        // 发送加密后的包
        if (nb_tx > 0) {
            rte_eth_tx_burst(port_id, 0, tx_pkts, nb_tx);
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
│  │                     rte_cryptodev 公共 API                                │ │
│  │  rte_cryptodev_configure / queue_pair_setup / enqueue_burst / ...    │ │
│  └──────────────────────────────────┬───────────────────────────────┘ │
│                                     │                                     │
│  ┌──────────────────────────────────┴───────────────────────────────┐ │
│  │                  dev_ops (函数指针表)                                │ │
│  │                                                                       │
│  │  int (*dev_configure)(dev, config);                                  │ │
│  │  int (*dev_start)(dev);                                              │ │
│  │  int (*queue_pair_setup)(dev, qp_id, qp_conf, socket_id);           │ │
│  │  int (*sym_session_create)(dev, sess, xforms, mp);                  │ │
│  │  unsigned (*sym_session_get_size)(dev);                             │ │
│  │  uint16_t (*enqueue_burst)(qp, ops, n);                            │ │
│  │  uint16_t (*dequeue_burst)(qp, ops, n);                            │ │
│  │  ...                                                                 │ │
│  └──────────────────────────────────┬───────────────────────────────┘ │
│                                     │                                     │
│  ┌──────────────────────────────────┴───────────────────────────────┐ │
│  │                     具体 PMD 实现                                    │ │
│  │                                                                       │
│  │  ┌─────────┐  ┌─────────────┐  ┌──────────┐  ┌───────────────┐  │ │
│  │  │ NULL    │  │ AESNI-MB    │  │   QAT    │  │   OpenSSL    │  │ │
│  │  │ (回环)  │  │ (x86 SIMD)  │  │ (硬件)  │  │   (SW)      │  │ │
│  │  └─────────┘  └─────────────┘  └──────────┘  └───────────────┘  │ │
│  │                                                                        │
│  │  ┌─────────┐  ┌─────────────┐  ┌──────────┐                        │ │
│  │  │ ARMv8   │  │ OCTEON TN   │  │  CNDA    │                        │ │
│  │  │ (ARM)   │  │ (Marvell)   │  │ (NVIDIA)│                        │ │
│  └──────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 7.2 NULL Crypto PMD

```c
// drivers/crypto/null/null_crypto_pmd.c
//
// NULL PMD: 不做任何实际加密，直接标记成功
// 用途: 功能测试、性能基准、开发调试

static uint16_t
null_crypto_pmd_enqueue_burst(void *qpair,
                               struct rte_crypto_op **ops,
                               uint16_t nb_ops)
{
    // 直接将所有操作标记为成功，不做任何加密/认证
    for (uint16_t i = 0; i < nb_ops; i++)
        ops[i]->status = RTE_CRYPTO_OP_STATUS_SUCCESS;

    return nb_ops;
}
```

### 7.3 AESNI-MB PMD (x86 SIMD 加速)

```
AESNI-MB (Multi-Buffer)
═══════════════════════════

  原理: 利用 Intel AES-NI 硬件指令 (AES-NI, PCLMULQDQ)
  Multi-Buffer 技术: 同时处理多个包的加密，提高指令级并行度

  ┌─────────────────────────────────────────────────────────────────┐
  │                                                                 │
  │  普通 AESNI:                                                     │
  │  ┌─────┐  ┌─────┐  ┌─────┐  ┌─────┐  ...  (逐包处理)      │
  │  │ pkt1│→│AES  │→│AES  │→│AES  │→│AES  │                     │
  │  └─────┘  └─────┘  └─────┘  └─────┘                           │
  │  问题: 每个包独立调用 AES 指令，指令间依赖导致流水线停顿     │
  │                                                                 │
  │  AESNI-MB:                                                     │
  │  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐      │
  │  │ pkt1 buf  │  │ pkt2 buf  │  │ pkt3 buf  │  │ pkt4 buf  │      │
  │  │ (16B)    │  │ (16B)    │  │ (16B)    │  │ (16B)    │      │
  │  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘      │
  │       └──────────┬────┴──────────┬────┴──────────┘            │
  │                  ▼                                               │
  │  ┌───────────────────────────────────────────┐                │
  │  │  Multi-Buffer AES-NI: 4 个包同时 AES         │                │
│  │  │  指令级并行，流水线不空转                    │                │
  │  └───────────────────────────────────────────┘                │
  │                                                                 │
  │  性能: AVX2 下 AES-GCM ~25 Gbps/core (4-5x 普通AESNI)   │
  └─────────────────────────────────────────────────────────────────┘
```

### 7.4 Intel QAT PMD (硬件加速)

```
Intel QuickAssist Technology (QAT)
═══════════════════════════════

  QAT 是 Intel 的硬件加密加速卡 (PCIe 设备)
  主要用于虚拟化/云计算环境

  ┌─────────────────────────────────────────────────────────────────┐
  │                                                                 │
  │  Host CPU                                                      │
│  ┌───────────────────────────────────────────────────────────┐   │ │
  │  │  DPDK Crypto PMD (QAT 驱动)                              │   │ │
│  │  │  ┌─────────┐  ┌─────────┐  ┌─────────┐               │   │ │
│  │  │  │  op 编码 │  │  ring    │  │  session│               │   │ │
│  │  │  └────┬────┘  └────┬────┘  └────┬────┘               │   │ │
│  │  └───────┼───────────┼───────────┼──────────┘           │   │ │
  │          │           │           │                         │   │ │
  │          ▼           ▼           ▼                         │   │
  │  ┌───────┴───────────┴───────────┴───────────────────┐   │ │
│  │                  PCIe DMA                                   │   │ │
│  └───────────────────────────┬──────────────────────────────┘   │ │
│                             │                                  │    │
│  ┌──────────────────────────┴──────────────────────────────┐    │ │
│  │                    Intel QAT 硬件                          │    │ │
│  │                                                             │    │ │
│  │  ┌────────────────┐  ┌────────────────┐               │    │ │
│  │  │  Crypto 引擎   │  │  Compression  │               │    │ │
│  │  │  (AES/3DES/    │  │  (Deflate/    │               │    │ │ │
│ │  │   SHA/HMAC)    │  │   LZ4/ZSTD)   │               │    │ │
│  │  └────────────────┘  └────────────────┘               │    │ │
  │                                                             │    │ │
│  └─────────────────────────────────────────────────────────┘    │ │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘

  性能: ~40-70 Gbps AES-256-GCM (单卡)
  优势: CPU 几乎不参与加密，释放给业务
  劣势: 需要 QAT 硬件 (额外成本)
```

---

## 8. 完整使用示例: IPsec ESP

### 8.1 AES-GCM ESP 封装

```c
// IPsec ESP 头
struct esp_hdr {
    uint32_t spi;     // Security Parameter Index
    uint32_t seq;     // Sequence Number
} __rte_packed;

// AES-256-GCM ESP 加密完整流程
static struct rte_mbuf *
esp_encrypt_gcm(struct rte_mbuf *pkt, uint32_t spi, uint32_t seq,
                void *session, uint8_t dev_id, uint16_t qp_id,
                struct rte_mempool *op_mp)
{
    // 1. 分配 crypto op
    struct rte_crypto_op *op = rte_crypto_op_alloc(op_mp,
                                                   RTE_CRYPTO_OP_TYPE_SYMMETRIC);
    if (!op)
        return NULL;

    op->symm_src = pkt;
    op->symm_dst = NULL;  // in-place
    op->sym_session = session;

    // 2. 预置 IV 到 mbuf 头部空间
    // rte_pktmbuf_prepend 会在 mbuf 头部腾出空间
    uint8_t *iv_ptr = (uint8_t *)rte_pktmbuf_prepend(pkt, 12);
    if (!iv_ptr) {
        rte_crypto_op_free(op);
        return NULL;
    }
    // 生成随机 IV
    rte_rand(iv_ptr, 12);

    // 3. 追加 ICV (16 bytes) 到 mbuf 尾部
    uint8_t *icv = (uint8_t *)rte_pktmbuf_append(pkt, 16);
    if (!icv) {
        rte_pktmbuf_free(pkt);
        rte_crypto_op_free(op);
        return NULL;
    }

    // 4. 预置 ESP 头
    struct esp_hdr *esp = (struct esp_hdr *)rte_pktmbuf_prepend(pkt, sizeof(*esp));
    if (!esp) {
        rte_pktmbuf_free(pkt);
        rte_crypto_op_free(op);
        return NULL;
    }
    esp->spi = rte_cpu_to_be_32(spi);
    esp->seq = rte_cpu_to_be_32(seq);

    // 5. 设置 AEAD 参数
    // data = ESP payload (跳过 IP + ESP 头)
    op->sym->aead.data.offset = sizeof(struct ip_hdr) + sizeof(struct esp_hdr) + 12;
    op->sym->aead.data.length = rte_pktmbuf_pkt_len(pkt) -
        sizeof(struct ip_hdr) - sizeof(struct esp_hdr) - 12 - 16;
    // AAD = IP header (明文)
    op->sym->aead.aad.offset = 0;
    op->sym->aead.aad.length = sizeof(struct ip_hdr);
    // digest = ICV (已追加到 mbuf 尾部)
    op->sym->aead.digest.offset = rte_pktmbuf_pkt_len(pkt) - 16;
    op->sym->aead.digest.length = 16;

    // 6. 入队加密
    struct rte_crypto_op *ops[1] = { op };
    uint16_t enqd = rte_cryptodev_enqueue_burst(dev_id, qp_id, ops, 1);
    if (enqd == 0) {
        rte_crypto_op_free(op);
        return NULL;
    }

    return pkt;
}
```

### 8.2 解密与验证

```c
static int
esp_decrypt_gcm(struct rte_mbuf *pkt, void *session,
                uint8_t *expected_icv, uint8_t dev_id, uint16_t qp_id,
                struct rte_mempool *op_mp)
{
    // 1. 分配 crypto op
    struct rte_crypto_op *op = rte_crypto_op_alloc(op_mp,
                                                   RTE_CRYPTO_OP_TYPE_SYMMETRIC);
    if (!op)
        return -ENOMEM;

    op->symm_src = pkt;
    op->symm_dst = NULL;
    op->sym_session = session;

    // 2. 设置解密参数 (DECRYPT)
    // 注意: xform 中的 op 设为 DECRYPT，这里 op 参数不变
    op->sym->aead.data.offset = sizeof(struct ip_hdr) + sizeof(struct esp_hdr) + 12;
    op->sym->aead.data.length = rte_pktmbuf_pkt_len(pkt) -
        sizeof(struct ip_hdr) - sizeof(struct esp_hdr) - 12 - 16;
    op->sym->aead.aad.offset = 0;
    op->sym->aead.aad.length = sizeof(struct ip_hdr);
    // digest: 传入接收到的 ICV 用于验证
    op->sym->aead.digest.offset = rte_pktmbuf_pkt_len(pkt) - 16;
    op->sym->aead.digest.length = 16;

    // 3. 入队
    struct rte_crypto_op *ops[1] = { op };
    rte_cryptodev_enqueue_burst(dev_id, qp_id, ops, 1);

    // 4. 出队等待结果
    struct rte_crypto_op *deq_ops[1];
    uint16_t nb_deq = rte_cryptodev_dequeue_burst(dev_id, qp_id, deq_ops, 1);
    if (nb_deq == 0) {
        rte_crypto_op_free(op);
        return -EBUSY;
    }

    // 5. 检查结果
    int ret = 0;
    if (deq_ops[0]->status != RTE_CRYPTO_OP_STATUS_SUCCESS) {
        ret = -1;  // 认证失败或解密错误
    }

    rte_crypto_op_free(deq_ops[0]);
    return ret;
}
```

---

## 9. 使用场景

### 9.1 场景 1：IPsec VPN Gateway（最典型）

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        IPsec VPN Gateway 完整数据流                          │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   Site A (10.0.1.0/24)                          Site B (10.0.2.0/24)          │
│                                                                             │
│   ┌──────────┐                          ┌──────────┐                        │
│   │ VM/Host  │                          │ VM/Host  │                        │
│   │ 明文 TCP  │                          │ 明文 TCP  │                        │
│   └────┬─────┘                          └────▲─────┘                        │
│        │                                     │                                 │
│        │ plaintext                           │ plaintext                        │
│        ▼                                     │                                 │
│   ┌────────────────────┐  encrypted    ┌────┴───────────────────┐           │
│   │  IPsec GW (DPDK)   │──────────────►│  IPsec GW (DPDK)       │           │
│   │                    │   over WAN    │                         │           │
│   │  ┌──────────────┐  │               │  ┌───────────────────┐  │           │
│   │  │ SPD (rte_acl)│  │               │  │ SPD (rte_acl)     │  │           │
│   │  │ 10.0.2.0/24  │  │               │  │ 10.0.1.0/24      │  │           │
│   │  │ → PROTECT    │  │               │  │ → PROTECT         │  │           │
│   │  └──────┬───────┘  │               │  └──────┬────────────┘  │           │
│   │         │          │               │         │               │           │
│   │         ▼          │               │         ▼               │           │
│   │  ┌──────────────┐  │               │  ┌───────────────────┐  │           │
│   │  │ SAD 查找     │  │               │  │ SAD 查找          │  │           │
│   │  │ SPI=0x1234   │  │               │  │ SPI=0x5678        │  │           │
│   │  │ AES-256-GCM  │  │               │  │ AES-256-GCM       │  │           │
│   │  └──────┬───────┘  │               │  └──────┬────────────┘  │           │
│   │         │          │               │         │               │           │
│   │         ▼          │               │         ▼               │           │
│   │  ┌──────────────┐  │  ┌─────────┐  │  ┌───────────────────┐  │           │
│   │  │ rte_ipsec    │  │  │  WAN    │  │  │ rte_ipsec         │  │           │
│   │  │ ESP 封装     │──┼─►│         │──┼─►│ ESP 解封装        │  │           │
│   │  │ 序列号管理   │  │  │         │  │  │ 抗重放检查        │  │           │
│   │  └──────┬───────┘  │  └─────────┘  │  └──────┬────────────┘  │           │
│   │         │          │               │         │               │           │
│   │         ▼          │               │         ▼               │           │
│   │  ┌──────────────┐  │               │  ┌───────────────────┐  │           │
│   │  │ cryptodev    │  │               │  │ cryptodev         │  │           │
│   │  │ AES-GCM 加密 │  │               │  │ AES-GCM 解密      │  │           │
│   │  │              │  │               │  │ + ICV 验证         │  │           │
│   │  │ ┌──────────┐ │  │               │  │ ┌──────────────┐  │  │           │
│   │  │ │AESNI-MB  │ │  │               │  │ │AESNI-MB/QAT  │  │  │           │
│   │  │ │   或 QAT  │ │  │               │  │ └──────────────┘  │  │           │
│   │  │ └──────────┘ │  │               │  └───────────────────┘  │           │
│   │  └──────────────┘  │               │                          │           │
│   └────────────────────┘               └──────────────────────────┘           │
│                                                                             │
│   加密后包结构:                                                              │
│   ┌─────────┬─────────┬────┬──────────────────────────┬─────┬──────┐          │
│   │Outer IP │ ESP Hdr │ IV │ Encrypted(InnerIP+TCP+Data)│ Pad │ ICV  │          │
│   │ 20B     │ 8B      │12B │                          │ 0-3 │ 16B  │          │
│   └─────────┴─────────┴────┴──────────────────────────┴─────┴──────┘          │
│   明文      明文      明文   ◄──── AES-256-GCM 加密范围 ────►  明文  认证     │
│                                                                             │
│   推荐硬件: QAT (40-70 Gbps) 或 AESNI-MB (20-25 Gbps/core)                 │
│   DPDK 示例: ipsec-secgw                                                    │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 9.2 场景 2：TLS 终端 / HTTPS 卸载

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        TLS 终端完整数据流                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   Client (浏览器)                     TLS Termination Proxy (DPDK)            │
│   ┌──────────┐                       ┌──────────────────────────┐             │
│   │ HTTP/2   │                       │                          │             │
│   │ GET /... │                       │  ┌────────────────────┐  │             │
│   └────┬─────┘                       │  │ TCP Stack (用户态) │  │             │
│        │                             │  └─────────┬──────────┘  │             │
│        │                             │            │             │             │
│        ▼                             │  ┌─────────▼──────────┐  │             │
│   ┌──────────┐   TLS 1.3 Record     │  │ TLS Record Layer   │  │             │
│   │ TLS Lib  │◄─────────────────────►│  │                    │  │             │
│   │          │   Content-Type:      │  │  ┌──────────────┐  │  │             │
│   │ 握手:    │   application_data   │  │  │ 每条 Record  │  │  │             │
│   │ X25519   │   加密:               │  │  │ = 1 个       │  │  │             │
│   │ ECDHE    │   AES-128-GCM        │  │  │ crypto_op    │  │  │             │
│   │ 数据:    │   ┌──────────────┐    │  │  └──────┬───────┘  │  │             │
│   │ GCM     │   │ Nonce(96bit) │    │  │         │          │  │             │
│   └──────────┘   │ Ciphertext   │    │  │  ┌──────▼───────┐  │  │             │
│                  │ Auth Tag 128b │    │  │  │ cryptodev    │  │  │             │
│                  └──────────────┘    │  │  │ AES-128-GCM  │  │  │             │
│                                     │  │  │ 批量解密     │  │  │             │
│                  TLS Record 结构:     │  │  └──────┬───────┘  │  │             │
│                  ┌─────────────────┐  │  │         │          │  │             │
│                  │ ContentType(1B) │  │  │  ┌──────▼───────┐  │  │             │
│                  │ Version(2B)     │  │  │  │ HTTP Parser  │  │  │             │
│                  │ Length(2B)      │  │  │  │ (明文)       │  │  │             │
│                  │ Encrypted(N)    │  │  │  └──────┬───────┘  │  │             │
│                  │ Tag(16B)        │  │  │         │          │  │             │
│                  └─────────────────┘  │  │  ┌──────▼───────┐  │  │             │
│                                     │  │  │ Backend App  │  │  │             │
│                  明文(5B)  密文         │  │  │ (Origin Srv) │  │  │             │
│                                     │  └────────────────────┘  │             │
│                                     └──────────────────────────┘             │
│                                                                             │
│   关键点:                                                                    │
│   - 对称加密走 cryptodev，非对称 (RSA/ECDHE) 走软件库                      │
│   - TLS 1.3 默认 AES-128-GCM，record 最大 16KB (1-2 个 mbuf)               │
│   - 批量处理: 一次 dequeue 多个 record 的解密结果                           │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 9.3 场景 3：5G UPF（用户面功能）

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        5G UPF 完整数据流                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   UE (手机)                                  Internet                      │
│   ┌──────────┐                              ┌──────────┐                   │
│   │ App Data │                              │ Srv Data │                   │
│   └────┬─────┘                              └────▲─────┘                   │
│        │                                         │                         │
│        │ gNB (基站)                              │                         │
│        ▼                                         │                         │
│   ┌─────────────────────────────────────────────────────────────────┐      │
│   │                      5G UPF (DPDK)                                │      │
│   │                                                                  │      │
│   │  ┌────────────────────────────────────────────────────────┐    │      │
│   │  │ ① GTP-U 解封装                                           │    │      │
│   │  │    IP(20B) │ UDP(8B) │ GTP-U Hdr(8B) │ Inner IP │ Data  │    │      │
│   │  └────────────────────────┬───────────────────────────────┘    │      │
│   │                           │                                      │      │
│   │  ┌────────────────────────▼───────────────────────────────┐    │      │
│   │  │ ② PDCP 解密 (空口加密，每用户一个 session)               │    │      │
│   │  │                                                          │    │      │
│   │  │  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐    │    │      │
│   │  │  │   SNOW 3G    │ │     ZUC      │ │  AES-128-CBC │    │    │      │
│   │  │  │  (欧洲标准)  │ │  (中国标准)  │ │  (备选)      │    │    │      │
│   │  │  │              │ │              │ │              │    │    │      │
│   │  │  │ cryptodev    │ │ cryptodev    │ │ cryptodev    │    │    │      │
│   │  │  │ session[UE1] │ │ session[UE2] │ │ session[UE3] │    │    │      │
│   │  │  └──────────────┘ └──────────────┘ └──────────────┘    │    │      │
│   │  │                                                          │    │      │
│   │  │  挑战: 100 万 UE → 100 万个 crypto session               │    │      │
│   │  │  方案: session pool + per-UE session lookup               │    │      │
│   │  └────────────────────────┬───────────────────────────────┘    │      │
│   │                           │                                      │      │
│   │  ┌────────────────────────▼───────────────────────────────┐    │      │
│   │  │ ③ N3 接口: IPsec ESP 加密 (UPF → SMF)                   │    │      │
│   │  │    AES-256-GCM，单个 SA，高吞吐                          │    │      │
│   │  └────────────────────────────────────────────────────────┘    │      │
│   │                                                                  │      │
│   └─────────────────────────────────────────────────────────────────┘      │
│                                                                             │
│   加密层次:                                                                  │
│   ┌──────────────────────────────────────────────────────────────────┐       │
│   │  Outer IP │ UDP │ GTP-U │ Inner IP │ TCP │ Payload             │       │
│   │  ◄── IPsec ESP 加密 ──►        ◄──── PDCP 加密 ────────────► │       │
│   │                                  (每用户独立算法+密钥)        │       │
│   └──────────────────────────────────────────────────────────────────┘       │
│                                                                             │
│   推荐硬件: QAT (需同时支持 SNOW 3G/ZUC/AES) 或 ARMv8 Crypto Extension       │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 9.4 场景 4：MACsec（数据中心东西向加密）

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        MACsec 完整数据流                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   ┌──────────┐                                              ┌──────────┐  │
│   │ Server A │                                              │ Server B │  │
│   │ VM: App  │                                              │ VM: App  │  │
│   └────┬─────┘                                              └────▲─────┘  │
│        │                                                         │          │
│        │ L2 Frame (Ethernet)                                     │          │
│        │                                                         │          │
│   ┌────▼─────────────────────────────────────────────────────────┴────┐   │
│   │                                                                 │   │
│   │  ┌── NIC A ────────────── Switch ───────────── NIC B ──────┐  │   │
│   │  │                                                        │  │   │
│   │  │  普通 Ethernet Frame:                                   │  │   │
│   │  │  ┌───────┬────────┬─────────┬──────────────────┐        │  │   │
│   │  │  │ DA(6B)│ SA(6B) │ EthType│  Payload         │        │  │   │
│   │  │  │       │        │ 0x0800 │  (IP+TCP+Data)  │        │  │   │
│   │  │  └───────┴────────┴─────────┴──────────────────┘        │  │   │
│   │  │                                                        │  │   │
│   │  │  MACsec 加密后 (Inline Crypto, CPU 不参与):             │  │   │
│   │  │  ┌───────┬────────┬─────────┬──────────────────┬───┐   │  │   │
│   │  │  │ DA    │  SA   │ EthType│  Encrypted Payload │ICV│   │  │   │
│   │  │  │       │        │ 0x88E5 │  (AES-GCM-128)    │16B│   │  │   │
│   │  │  └───────┴────────┴─────────┴──────────────────┴───┘   │  │   │
│   │  │          明文     明文    明文      ◄── 加密 ──►   认证  │  │   │
│   │  │                                                        │  │   │
│   │  │  注意: MACsec 用 rte_security 配置，不是直接用          │  │   │
│   │  │  cryptodev API。NIC 硬件自动完成加密/解密。              │  │   │
│   │  └────────────────────────────────────────────────────────┘  │   │
│   │                                                                 │   │
│   └─────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│   SecTag 结构 (IEEE 802.1AE):                                              │
│   ┌──────────┬──────────┬──────────┬──────────┬──────────┬──────────┐      │
│   │ TCI(1B)  │ AN(1B)   │ SL(1B)   │ PN(4B)   │ SCI(8B)  │ 密文... │      │
│   │ Short Format (6B)  ◄──── 明文 (用于 SA 查找) ────►  加密  │      │
│   └──────────┴──────────┴──────────┴──────────┴──────────┴──────────┘      │
│                                                                             │
│   适用 NIC: Intel E810, Mellanox ConnectX-6/7, Broadcom (支持 Inline Crypto)  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 9.5 场景选型指南

| 场景 | 推荐算法 | 推荐硬件 | 原因 |
|------|---------|---------|------|
| IPsec VPN | AES-256-GCM | QAT 或 AESNI-MB | GCM 是 AEAD，单次操作完成加密+认证 |
| TLS 终端 | AES-128-GCM | AESNI-MB | TLS 1.3 默认，128-bit 足够，密钥短更快 |
| 5G UPF | SNOW 3G / ZUC | QAT 或 ARMv8 | 无线标准要求，需要硬件加速 |
| WireGuard | ChaCha20-Poly1305 | AESNI-MB | ARM 平台性能优于 AES，x86 可选 |
| MACsec | AES-GCM-128 | Inline NIC | L2 加密，需要 NIC 硬件支持 |
| 磁盘加密 | AES-XTS | AESNI | 512B 扇区对齐，XTS 专为磁盘设计 |
| 功能测试 | NULL Crypto | 任意 | 不做实际加密，用于性能基准和功能验证 |

---

## 10. 完整使用流程

### 10.1 端到端处理流程图

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                  Cryptodev 完整使用流程 (AES-256-GCM 加密)                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─ 阶段 1: 初始化 ────────────────────────────────────────────────────┐  │
│  │                                                                     │  │
│  │  ① EAL 初始化                                                       │  │
│  │     rte_eal_init(argc, argv)                                        │  │
│  │              │                                                      │  │
│  │              ▼                                                      │  │
│  │  ② 发现 crypto 设备                                                │  │
│  │     dev_id = rte_cryptodev_get_dev_id("crypto_aesni_mb")            │  │
│  │     rte_cryptodev_info_get(dev_id, &info)                           │  │
│  │              │                                                      │  │
│  │              ▼                                                      │  │
│  │  ③ 配置设备                                                        │  │
│  │     rte_cryptodev_configure(dev_id, &conf)  // nb_queue_pairs=1    │  │
│  │              │                                                      │  │
│  │              ▼                                                      │  │
│  │  ④ 创建 session mempool                                            │  │
│  │     rte_mempool_create("sess_mp", max_sess, session_size, ...)      │  │
│  │              │                                                      │  │
│  │              ▼                                                      │  │
│  │  ⑤ 设置 queue pair                                                  │  │
│  │     rte_cryptodev_queue_pair_setup(dev_id, 0, &qp_conf, socket_id) │  │
│  │     // qp_conf.mp_session = sess_mp  ← 注意是 session pool         │  │
│  │              │                                                      │  │
│  │              ▼                                                      │  │
│  │  ⑥ 创建 op mempool                                                 │  │
│  │     rte_crypto_op_pool_create("op_mp", SYMMETRIC, 1024, ...)       │  │
│  │              │                                                      │  │
│  │              ▼                                                      │  │
│  │  ⑦ 启动设备                                                        │  │
│  │     rte_cryptodev_start(dev_id)                                     │  │
│  │              │                                                      │  │
│  │              ▼                                                      │  │
│  │  ⑧ 创建 crypto session                                             │  │
│  │     xform = { .type = AEAD, .aead.algo = AES_GCM, ... }            │  │
│  │     session = rte_cryptodev_sym_session_create(dev_id, &xform, mp) │  │
│  │                                                                     │  │
│  └─────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
│  ┌─ 阶段 2: 数据包处理循环 ────────────────────────────────────────────┐  │
│  │                                                                     │  │
│  │  ⑨ 收包: rte_eth_rx_burst(port, 0, pkts, 32)                     │  │
│  │              │                                                      │  │
│  │              ▼                                                      │  │
│  │  ⑩ 分配 crypto op                                                  │  │
│  │     op = rte_crypto_op_alloc(op_mp, SYMMETRIC)                     │  │
│  │     op->sym_session = session                                       │  │
│  │     op->symm_src = pkt              ← 源 mbuf                     │  │
│  │     op->symm_dst = NULL              ← 原地加密 (in-place)        │  │
│  │              │                                                      │  │
│  │              ▼                                                      │  │
│  │  ⑪ 设置加密参数                                                    │  │
│  │     op->sym->aead.data.offset = ...    ← 明文在 mbuf 中的偏移     │  │
│  │     op->sym->aead.data.length = ...    ← 明文长度                  │  │
│  │     op->sym->aead.aad.offset = ...     ← AAD 位置                 │  │
│  │     op->sym->aead.aad.length = ...     ← AAD 长度                 │  │
│  │     op->sym->aead.digest.offset = ...  ← ICV 写入位置             │  │
│  │     op->sym->aead.digest.length = 16   ← GCM ICV = 16 字节       │  │
│  │              │                                                      │  │
│  │              ▼                                                      │  │
│  │  ⑫ 批量入队                                                        │  │
│  │     nb_enq = rte_cryptodev_enqueue_burst(dev_id, qp_id, ops, n)   │  │
│  │     // 如果 PMD 是 AESNI-MB: 同步完成，可直接 dequeue               │  │
│  │     // 如果 PMD 是 QAT:    异步完成，需要轮询 dequeue              │  │
│  │              │                                                      │  │
│  │              ▼                                                      │  │
│  │  ⑬ 轮询出队                                                        │  │
│  │     nb_deq = rte_cryptodev_dequeue_burst(dev_id, qp_id, ops, n)   │  │
│  │              │                                                      │  │
│  │              ▼                                                      │  │
│  │  ⑭ 检查结果                                                        │  │
│  │     if (op->status == SUCCESS) → 转发加密后的包                    │  │
│  │     if (op->status == AUTH_FAILED) → 认证失败，丢弃                │  │
│  │              │                                                      │  │
│  │              ▼                                                      │  │
│  │  ⑮ 发送 + 释放                                                     │  │
│  │     rte_eth_tx_burst(port, 0, pkts, nb_tx)                        │  │
│  │     rte_crypto_op_free(op)          ← 归还 op 到 pool             │  │
│  │                                                                     │  │
│  └─────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
│  ┌─ 阶段 3: 清理 ──────────────────────────────────────────────────────┐  │
│  │                                                                     │  │
│  │  ⑯ rte_cryptodev_sym_session_free(dev_id, session)                 │  │
│  │  ⑰ rte_cryptodev_stop(dev_id)                                      │  │
│  │  ⑱ rte_mempool_free(op_mp)                                         │  │
│  │  ⑲ rte_mempool_free(sess_mp)                                       │  │
│  │                                                                     │  │
│  └─────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 10.2 mbuf 数据布局（加密前后）

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                 mbuf 数据布局: AES-256-GCM 加密 IPsec ESP                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  加密前 (原始 IP 包):                                                      │
│  ┌────────────────────────────────────────────────────────────────────┐   │
│  │ IP Header (20B) │ ESP Header (8B) │ TCP Header │ Payload          │   │
│  │ offset=0         │ offset=20        │ offset=28   │ offset=48       │   │
│  └────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  加密准备 (prepend IV + append ICV):                                       │
│  ┌────────────────────────────────────────────────────────────────────┐   │
│  │ IP Hdr │ ESP Hdr │ IV(12B) │ TCP Header │ Payload │ ICV(16B)      │   │
│  │ AAD ◄──────────►│  IV    │◄── data (加密) ──►│digest               │   │
│  │                │◄────────┤                 │◄────────┤              │   │
│  └────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  crypto_op 参数设置:                                                       │
│  ┌────────────────────────────────────────────────────────────────────┐   │
│  │ aead.aad.offset  = 0           (IP Header, 明文不加密)             │   │
│  │ aead.aad.length  = 20          (AAD = IP Header)                   │   │
│  │ aead.iv.offset   = 32          (IV 在 mbuf 中的位置)               │   │
│  │ aead.iv.length   = 12          (GCM nonce = 12 bytes)              │   │
│  │ aead.data.offset = 44          (TCP Header + Payload 起始)         │   │
│  │ aead.data.length = payload_len (加密数据长度)                       │   │
│  │ aead.digest.offset = pkt_len   (ICV 位置 = mbuf 尾部)              │   │
│  │ aead.digest.length = 16         (GCM tag = 16 bytes)               │   │
│  └────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  加密后:                                                                    │
│  ┌────────────────────────────────────────────────────────────────────┐   │
│  │ IP Hdr │ ESP Hdr │ IV(12B) │ Encrypted(TCP+Payload) │ ICV(16B)   │   │
│  │ 明文   │ 明文   │ 明文    │ 密文                    │ 认证标签    │   │
│  └────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  注意:                                                                      │
│  - AAD (Additional Authenticated Data) 参与认证计算但不加密               │
│  - IV 必须放在加密数据之前（GCM 要求）                                    │
│  - ICV 由 PMD 自动写入 digest.offset 指定的位置                          │
│  - 原地加密 (in-place): symm_dst = NULL，直接修改源 mbuf                  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 10.3 完整代码示例：批量 AES-GCM 加密

```c
#include <rte_cryptodev.h>
#include <rte_crypto.h>
#include <rte_mbuf.h>

#define BURST_SIZE    32
#define MAX_QP_DESC   256
#define MAX_SESSIONS  1024

// ── 全局状态 ──
static uint8_t crypto_dev_id;
static uint16_t crypto_qp_id;
static void *crypto_session;
static struct rte_mempool *op_mp;
static struct rte_mempool *sess_mp;

// ── 阶段 1: 初始化 ──
static int
crypto_init(void)
{
    // 1. 查找 crypto 设备
    crypto_dev_id = rte_cryptodev_get_dev_id("crypto_aesni_mb");
    if (crypto_dev_id == rte_cryptodev_count()) {
        printf("AESNI-MB not found, falling back to first device\n");
        crypto_dev_id = 0;
    }

    // 2. 获取设备信息
    struct rte_cryptodev_info dev_info;
    rte_cryptodev_info_get(crypto_dev_id, &dev_info);

    // 3. 配置设备
    struct rte_cryptodev_config conf = {
        .socket_id = SOCKET_ID_ANY,
        .nb_queue_pairs = 1,
    };
    int ret = rte_cryptodev_configure(crypto_dev_id, &conf);
    if (ret < 0)
        return -1;

    // 4. 创建 session mempool
    unsigned session_size =
        rte_cryptodev_sym_get_private_session_size(crypto_dev_id);
    sess_mp = rte_mempool_create("sess_mp",
        RTE_MIN(dev_info.sym.max_nb_sessions, MAX_SESSIONS),
        session_size, 0, 0, SOCKET_ID_ANY);

    // 5. 设置 queue pair
    struct rte_cryptodev_qp_conf qp_conf = {
        .nb_descriptors = MAX_QP_DESC,
        .mp_session = sess_mp,
    };
    ret = rte_cryptodev_queue_pair_setup(
        crypto_dev_id, 0, &qp_conf, SOCKET_ID_ANY);
    if (ret < 0)
        return -1;

    // 6. 创建 op mempool
    op_mp = rte_crypto_op_pool_create("op_mp",
        RTE_CRYPTO_OP_TYPE_SYMMETRIC, 1024, 128, 0, SOCKET_ID_ANY);

    // 7. 启动设备
    rte_cryptodev_start(crypto_dev_id);

    // 8. 创建加密 session (AES-256-GCM)
    uint8_t key[32] = { /* 256-bit key */ };
    struct rte_crypto_sym_xform xform = {
        .type = RTE_CRYPTO_SYM_XFORM_AEAD,
        .aead = {
            .algo = RTE_CRYPTO_AEAD_AES_GCM,
            .op = RTE_CRYPTO_AEAD_OP_ENCRYPT,
            .key.data = key,
            .key.length = 32,
            .iv.offset = 0,
            .iv.length = 12,
            .aad_length = 20,      // IP header 作为 AAD
            .digest_length = 16,
        },
    };

    crypto_session = rte_cryptodev_sym_session_create(
        crypto_dev_id, &xform, sess_mp);
    if (!crypto_session)
        return -1;

    return 0;
}

// ── 阶段 2: 批量加密 ──
static uint16_t
crypto_encrypt_burst(struct rte_mbuf *pkts[], uint16_t nb_pkts)
{
    struct rte_crypto_op *ops[BURST_SIZE];
    uint16_t nb_prep = 0;

    // 为每个包分配 op 并设置参数
    for (uint16_t i = 0; i < nb_pkts; i++) {
        struct rte_crypto_op *op = rte_crypto_op_alloc(
            op_mp, RTE_CRYPTO_OP_TYPE_SYMMETRIC);
        if (!op)
            break;

        op->sym_session = crypto_session;
        op->symm_src = pkts[i];
        op->symm_dst = NULL;  // in-place

        // AES-GCM 参数
        // data: 跳过 IP(20B) + ESP(8B) + IV(12B) = 40B
        op->sym->aead.data.offset = 40;
        op->sym->aead.data.length = rte_pktmbuf_pkt_len(pkts[i]) - 40 - 16;

        // AAD: IP header (20 bytes, 明文)
        op->sym->aead.aad.offset = 0;
        op->sym->aead.aad.length = 20;

        // ICV: mbuf 尾部
        op->sym->aead.digest.offset = rte_pktmbuf_pkt_len(pkts[i]) - 16;
        op->sym->aead.digest.length = 16;

        ops[nb_prep++] = op;
    }

    if (nb_prep == 0)
        return 0;

    // 批量入队
    uint16_t nb_enq = rte_cryptodev_enqueue_burst(
        crypto_dev_id, crypto_qp_id, ops, nb_prep);

    // 轮询出队 (同步 PMD 如 AESNI-MB 通常一次 dequeue 就能拿到全部)
    uint16_t nb_deq = 0;
    while (nb_deq < nb_enq) {
        nb_deq += rte_cryptodev_dequeue_burst(
            crypto_dev_id, crypto_qp_id, &ops[nb_deq], nb_enq - nb_deq);
    }

    // 处理结果
    uint16_t nb_ok = 0;
    for (uint16_t i = 0; i < nb_deq; i++) {
        if (ops[i]->status == RTE_CRYPTO_OP_STATUS_SUCCESS) {
            pkts[nb_ok++] = ops[i]->symm_src;
        } else {
            rte_pktmbuf_free(ops[i]->symm_src);
        }
        rte_crypto_op_free(ops[i]);
    }

    // 处理未入队的 op
    for (uint16_t i = nb_enq; i < nb_prep; i++)
        rte_crypto_op_free(ops[i]);

    return nb_ok;
}

// ── 阶段 2: 批量解密 ──
static uint16_t
crypto_decrypt_burst(struct rte_mbuf *pkts[], uint16_t nb_pkts)
{
    struct rte_crypto_op *ops[BURST_SIZE];
    uint16_t nb_prep = 0;

    for (uint16_t i = 0; i < nb_pkts; i++) {
        struct rte_crypto_op *op = rte_crypto_op_alloc(
            op_mp, RTE_CRYPTO_OP_TYPE_SYMMETRIC);
        if (!op)
            break;

        op->sym_session = crypto_session;
        op->symm_src = pkts[i];
        op->symm_dst = NULL;

        // 解密参数与加密相同 (session 中 xform.op = DECRYPT)
        op->sym->aead.data.offset = 40;
        op->sym->aead.data.length = rte_pktmbuf_pkt_len(pkts[i]) - 40 - 16;
        op->sym->aead.aad.offset = 0;
        op->sym->aead.aad.length = 20;
        op->sym->aead.digest.offset = rte_pktmbuf_pkt_len(pkts[i]) - 16;
        op->sym->aead.digest.length = 16;

        ops[nb_prep++] = op;
    }

    if (nb_prep == 0)
        return 0;

    uint16_t nb_enq = rte_cryptodev_enqueue_burst(
        crypto_dev_id, crypto_qp_id, ops, nb_prep);

    uint16_t nb_deq = 0;
    while (nb_deq < nb_enq) {
        nb_deq += rte_cryptodev_dequeue_burst(
            crypto_dev_id, crypto_qp_id, &ops[nb_deq], nb_enq - nb_deq);
    }

    uint16_t nb_ok = 0;
    for (uint16_t i = 0; i < nb_deq; i++) {
        if (ops[i]->status == RTE_CRYPTO_OP_STATUS_SUCCESS) {
            pkts[nb_ok++] = ops[i]->symm_src;
        } else {
            // AUTH_FAILED = 密文被篡改或密钥不匹配
            rte_pktmbuf_free(ops[i]->symm_src);
        }
        rte_crypto_op_free(ops[i]);
    }

    for (uint16_t i = nb_enq; i < nb_prep; i++)
        rte_crypto_op_free(ops[i]);

    return nb_ok;
}

// ── 主循环 ──
static void
main_loop(uint16_t port_rx, uint16_t port_tx)
{
    struct rte_mbuf *rx_pkts[BURST_SIZE];
    struct rte_mbuf *tx_pkts[BURST_SIZE];

    while (!force_quit) {
        // 收包
        uint16_t nb_rx = rte_eth_rx_burst(port_rx, 0, rx_pkts, BURST_SIZE);
        if (nb_rx == 0)
            continue;

        // 批量加密
        uint16_t nb_enc = crypto_encrypt_burst(rx_pkts, nb_rx);

        // 发送
        uint16_t nb_tx = rte_eth_tx_burst(port_tx, 0, tx_pkts, nb_enc);
        for (uint16_t i = nb_tx; i < nb_enc; i++)
            rte_pktmbuf_free(tx_pkts[i]);
    }
}

// ── 阶段 3: 清理 ──
static void
crypto_cleanup(void)
{
    rte_cryptodev_sym_session_free(crypto_dev_id, crypto_session);
    rte_cryptodev_stop(crypto_dev_id);
    // mempool 由 EAL 统一释放，此处不需要手动 free
}
```

### 10.4 同步 vs 异步 PMD 的区别

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                   同步 PMD vs 异步 PMD 处理模式                            │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  同步 PMD (AESNI-MB, OpenSSL, NULL)                                        │
│  ═════════════════════════════════════════                                 │
│                                                                             │
│  CPU Thread:                                                               │
│  ┌────────┐   ┌──────────────┐   ┌──────────────┐   ┌────────┐          │
│  │enqueue │──►│ CPU 直接加密  │──►│ 结果写回 mbuf│──►│dequeue │          │
│  │burst() │   │ (当前线程)    │   │              │   │burst() │          │
│  └────────┘   └──────────────┘   └──────────────┘   └────────┘          │
│                                                                             │
│  特点: enqueue 内部同步完成加密，dequeue 立即可取                           │
│  适合: 对延迟敏感的场景，单线程处理                                        │
│                                                                             │
│  ─────────────────────────────────────────────────────────────────────     │
│                                                                             │
│  异步 PMD (QAT, NVIDIA DOCA)                                               │
│  ═════════════════════════════════                                          │
│                                                                             │
│  CPU Thread:                  Hardware:                                    │
│  ┌────────┐                 ┌──────────────────────┐                      │
│  │enqueue │──DMA ring ────►│  QAT Crypto Engine   │                      │
│  │burst() │   (不阻塞，立即  │  (后台并行加密)      │                      │
│  └────────┘    返回)         └──────────┬───────────┘                      │
│       │                                   │                              │
│       │                    加密完成后硬件写回                          │
│       │                                   │                              │
│       │                                   ▼                              │
│  ┌────────┐                 ┌──────────┴───────────┐                      │
│  │dequeue │◄──DMA ring ────│  结果已写回 mbuf    │                      │
│  │burst() │   (不阻塞)       └──────────────────────┘                      │
│  └────────┘                                                              │
│       │                                                                     │
│       ▼                                                                     │
│  检查返回值 nb_deq == 0 ? ──► 还没完成，稍后再 poll                      │
│                       ──► nb_deq > 0 ? ──► 拿到结果，处理                            │
│                                                                             │
│  ⚠ dequeue_burst() 不是阻塞调用:                                          │
│  ┌───────────────────────────────────────────────────────────────────┐    │
│  │  while (nb_deq < nb_enq) {      // 不是 sleep/阻塞！            │    │
│  │      nb_deq += rte_cryptodev_dequeue_burst(...);  // busy-wait    │    │
│  │  }                             // CPU 空转等待硬件完成       │    │
│  │                                                                   │    │
│  │  如果不想空转 CPU，应该:                                        │    │
│  │  - 先处理其他队列/任务，过一会再来 poll                       │    │
│  │  - 或使用 rte_timer / eventdev 做延迟 poll                        │    │
│  └───────────────────────────────────────────────────────────────────┘    │
│                                                                             │
│  ─────────────────────────────────────────────────────────────────────     │
│                                                                             │
│  CPU Crypto PMD (RTE_SECURITY_ACTION_TYPE_CPU_CRYPTO)                       │
│  ══════════════════════════════════════════════════════════               │
│                                                                             │
│  特点: 不经过 enqueue/dequeue，直接在 CPU 上执行加密                        │
│  API: rte_ipsec_pkt_cpu_prepare() + rte_ipsec_pkt_process()               │
│  适合: 低延迟场景，绕过 cryptodev ring 开销                                │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 11. 性能对比

### 11.1 Crypto PMD 性能参考

> [!note] 数据来源说明
> 以下数据为典型量级参考。实际性能取决于 CPU 型号、包大小分布、是否 in-place 操作等因素。

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        Crypto PMD 性能对比 (AES-256-GCM)                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  PMD               类型       单核吞吐量    CPU 利用率    效率 (Gbps/Core)   │
│  ──────────────────────────────────────────────────────────────────────────── │
│  NULL Crypto       软件       0 (pass)      ~0%           -                  │
│  OpenSSL          软件       8-10 Gbps     ~85%          ~10               │
│  AESNI-MB (AVX2)   SIMD      20-25 Gbps    ~75%          ~30               │
│  AESNI-MB (AVX512) SIMD      30-40 Gbps    ~70%          ~50               │
│  QAT GEN3          硬件      40-70 Gbps    ~15%          ~300              │
│  NVIDIA DOCA       硬件      80-100 Gbps   ~10%          ~800              │
│                                                                             │
│  IPsec ESP 吞吐 (AES-256-GCM, 含 IPsec 封装开销):                        │
│  ──────────────────────────────────────────────────────────────────────── │
│  软件 (OpenSSL)        5-8 Gbps                                               │
│  AESNI-MB (AVX2)      15-25 Gbps                                              │
│  QAT (2x40GbE)        60-80 Gbps                                              │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 11.2 优化建议

| 优化项 | 说明 | 效果 |
|--------|------|------|
| **批量入队** | 每次 enqueue 32+ 操作 | 减少调用开销 |
| **In-place 加密** | `symm_dst = NULL` | 避免 mbuf 拷贝 |
| **连续 mbuf** | 单 segment mbuf | 减少 scatter/gather |
| **会话复用** | 同一 SA 复用 session | 避免 session 创建开销 |
| **硬件选择** | QAT/NVIDIA 加速卡 | 10-50x 提升 |
| **AES-GCM** | 用 AEAD 代替 CBC+HMAC | 一次操作完成加密+认证 |

---

## 12. 小结

本章核心要点：

1. **背景**：IPsec/TLS 加密是网络瓶颈，软件 AES-GCM ~2-3 μs/包，硬件加速 ~50-100 ns/包。

2. **DPDK Crypto 架构**：cryptodev 抽象层 + Crypto PMD 驱动栈（NULL/AESNI-MB/QAT/OpenSSL）。

3. **设备 API**：`rte_cryptodev_configure` → `queue_pair_setup`（注意第四参数是 session mempool）→ `start`。能力查询用 `rte_cryptodev_capabilities_get`。

4. **数据引用**：所有加密/认证数据通过 **mbuf + offset/length** 引用，不用 raw 指针。这是 DPDK cryptodev 的核心设计。

5. **xform 结构**：`cipher_xform`/`auth_xform`/`aead_xform`，可链式组合（cipher→auth）。IV 通过 `{offset, length}` 指定位置。

6. **操作结构**：`rte_crypto_op` 内含 `symm_src`/`symm_dst`（mbuf 引用）和内联的 `rte_crypto_sym_op`（cipher/auth/aead 数据）。

7. **会话管理**：session 从 mempool 分配（`rte_cryptodev_sym_session_create` 需要 dev_id + xforms + mempool），释放需要 dev_id + session。

8. **PMD 驱动**：NULL（测试）、AESNI-MB（x86 SIMD）、QAT（Intel 硬件）、OpenSSL（软件回退）、ARMv8（ARM NEON）。

9. **使用场景**：IPsec VPN（最典型，AES-GCM）、TLS 终端卸载、5G UPF（SNOW 3G/ZUC）、MACsec（L2 加密）、WireGuard（ChaCha20-Poly1305）。

10. **完整流程**：初始化（发现设备 → 配置 → 创建 session/OP pool → 启动）→ 数据包处理（分配 op → 设置参数 → 批量 enqueue → 轮询 dequeue → 检查结果 → 发送）→ 清理。

11. **PMD 模式**：同步 PMD（AESNI-MB，enqueue 内完成加密）vs 异步 PMD（QAT，硬件后台加密）vs CPU Crypto（绕过 ring 直接加密）。

12. **性能**：AESNI-MB ~25 Gbps/core，QAT ~70 Gbps，NVIDIA DOCA ~100 Gbps。

**上一篇**：[[2026-04-09-dpdk-deep-dive-ch20-simd-avx512|第二十章：AVX512/SIMD 数据包处理向量化]]

**下一篇预告**：[[2026-04-09-dpdk-deep-dive-ch22-ipsec-fullflow|第二十二章]]将讲解 IPsec 全流程实现——从 SA 建立到 ESP 收发的完整代码。

---

> [!tip] 参考文献
> - DPDK, "Cryptodev Library", https://doc.dpdk.org/guides/prog_guide/cryptodev_lib.html
> - DPDK, "AESNI-MB PMD", https://doc.dpdk.org/guides/cryptodevs/aesni_mb.html
> - DPDK, "QAT PMD", https://doc.dpdk.org/guides/cryptodevs/qat.html
> - DPDK, "IPsec Security Gateway", https://doc.dpdk.org/guides/sample_app_ug/ipsec_secgw.html
