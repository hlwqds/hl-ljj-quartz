---
title: "DPDK 深度探索 ch30：Lookaside 加速"
date: 2026-04-10 10:30:00
tags: [dpdk, lookaside, crypto, ipsec, qat, aesni, cryptodev, offload]
description: "深入解析 DPDK Lookaside 加速：密码处理卸载、QAT、AES-NI、Cryptodev 与 IPsec 集成"
---

# DPDK 深度探索 ch30：Lookaside 加速

> [!abstract] 核心要点
> Lookaside 加速将加密/压缩等计算密集操作卸载到硬件。本章深入解析 DPDK Cryptodev、QAT 卸载、AES-NI 与 IPsec 集成。

## 1. Lookaside 概述

### 1.1 什么是 Lookaside

```
Lookaside (边带加速) vs Inline 加速：

Inline 加速:
  数据路径直接经过硬件处理
  - 优点：低延迟
  - 缺点：硬件需要参与所有数据包处理

Lookaside 加速:
  主机 CPU 处理主体数据
  特定操作 (加密/认证) 卸载到协处理器
  - 优点：灵活，CPU 仍控制数据路径
  - 缺点：需要数据往返

┌─────────────────────────────────────────────────────────────┐
│                    Lookaside 架构                           │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              Crypto Device (QAT/AES-NI)                │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↑                                │
│                      Crypto Request                          │
│                            ↑                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              CPU (Data Path)                           │  │
│  │  - 包处理                                            │  │
│  │  - 调用加密                                          │  │
│  │  - 继续处理                                          │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 Lookaside vs Inline

| 特性       | Lookaside   | Inline           |
| ---------- | ----------- | ---------------- |
| **位置**   | 协处理器    | NIC 内           |
| **灵活性** | 高          | 低               |
| **延迟**   | 中 (~1-5μs) | 低 (~100ns)      |
| **吞吐量** | 高          | 最高             |
| **适用**   | IPsec, TLS  | WireGuard, IPsec |

## 2. DPDK Cryptodev

### 2.1 Cryptodev 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    DPDK Cryptodev 架构                      │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              Application                               │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              rte_cryptof.h                            │  │
│  │  - Crypto Operations                                │  │
│  │  - Session Management                                │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              Cryptodev PMD                           │  │
│  │                                                       │  │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐          │  │
│  │  │ QAT PMD  │  │ AESNI   │  │ OPENSSL │          │  │
│  │  │          │  │ PMD     │  │ PMD     │          │  │
│  │  └──────────┘  └──────────┘  └──────────┘          │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 设备初始化

```c
#include <rte_cryptodev.h>

// 初始化 Cryptodev
int
crypto_init(void)
{
    // 探测可用设备
    int ret = rte_cryptodev_probe_pmd();
    if (ret < 0) {
        fprintf(stderr, "Failed to probe cryptodev\n");
        return -1;
    }

    // 获取设备数量
    uint8_t dev_count = rte_cryptodev_count();
    printf("Found %d crypto devices\n", dev_count);

    // 配置设备
    uint8_t dev_id = 0;
    struct rte_cryptodev_config conf = {
        .socket_id = 0,
        .nb_queue_pairs = 4,
        .ff_cap = rte_cryptodev_get_feature_flags(dev_id),
    };

    ret = rte_cryptodev_configure(dev_id, &conf);
    if (ret < 0) {
        fprintf(stderr, "Failed to configure cryptodev\n");
        return -1;
    }

    // 启动设备
    rte_cryptodev_start(dev_id);

    return 0;
}
```

### 2.3 可用设备

```bash
# 查看可用加密设备
dpdk-test-crypto

# 示例输出：
# Crypto device enumeration:
#   QAT: Crypto device [0]qat_0
#   AESNI: Crypto device [1]aes_0
#   ARM: Crypto device [2]arm64_0

# 绑定设备
dpdk-devbind --bind=igb_uio 0000:3d:00.1
```

## 3. Crypto 操作

### 3.1 操作结构

```c
// Crypto 操作
struct rte_crypto_op {
    // 操作状态
    enum rte_crypto_op_status status;
    uint8_t type;

    // 物理地址
    phys_addr_t phys_addr;

    // Session
    struct rte_cryptodev_sym_session *session;

    // 操作参数
    union {
        struct rte_crypto_sym_op sym;
    } __rte_cache_aligned;
} __rte_cache_aligned;

// 对称操作
struct rte_crypto_sym_op {
    // mbuf
    struct rte_mbuf *m_src;
    struct rte_mbuf *m_dst;

    // 加密参数
    struct {
        uint8_t *data;      // 密钥
        uint16_t length;
    } cipher;

    // 认证参数
    struct {
        uint8_t *data;
        uint16_t length;
        uint16_t offset;
    } auth;

    // IV
    uint8_t *iv_ptr;
    uint16_t iv_len;
};
```

### 3.2 Session

```c
// 创建 Session
struct rte_cryptodev_sym_session *
create_aes_session(uint8_t dev_id)
{
    // AES-CBC 加密 + HMAC 认证
    struct rte_crypto_sym_xform cipher = {
        .type = RTE_CRYPTO_SYM_XFORM_CIPHER,
        .cipher = {
            .algo = RTE_CRYPTO_CIPHER_AES_CBC,
            .key = {0x00, 0x01, ...},  // 128-bit key
            .key_len = 16,
            .iv_len = 16,
        },
    };

    struct rte_crypto_sym_xform auth = {
        .type = RTE_CRYPTO_SYM_XFORM_AUTH,
        .auth = {
            .algo = RTE_CRYPTO_AUTH_SHA256,
            .key = {0x00, 0x02, ...},
            .key_len = 32,
            .digest_len = 16,
        },
    };

    // 链接 xform
    cipher.next = &auth;
    auth.next = NULL;

    // 创建 session
    struct rte_cryptodev_sym_session *session;
    session = rte_cryptodev_sym_session_create(dev_id, &cipher);

    return session;
}
```

### 3.3 加密/解密

```c
// 加密包
int
encrypt_packet(uint8_t dev_id,
               struct rte_cryptodev_sym_session *session,
               struct rte_mbuf *mbuf)
{
    // 分配 crypto op
    struct rte_crypto_op *op = rte_crypto_op_alloc(NULL,
        RTE_CRYPTO_OP_TYPE_SYMMETRIC);
    if (!op)
        return -1;

    // 设置 session
    op->sym->session = session;

    // 设置 mbuf
    op->sym->m_src = mbuf;

    // 设置 IV
    uint8_t iv[16];
    generate_random_iv(iv, 16);
    op->sym->cipher.iv_ptr = iv;
    op->sym->cipher.iv_len = 16;

    // 设置加密参数
    op->sym->cipher.data.offset = 0;
    op->sym->cipher.data.length = rte_pktmbuf_data_len(mbuf);

    // 提交到设备
    uint16_t nb_enqueued = rte_cryptodev_enqueue_burst(dev_id,
        0, &op, 1);

    // 等待完成
    uint16_t nb_dequeued = rte_cryptodev_dequeue_burst(dev_id,
        0, &op, 1, 0);

    return (nb_dequeued == 1) ? 0 : -1;
}
```

## 4. QAT 卸载

### 4.1 QAT 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    Intel QAT 架构                           │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              QAT Device (PCIe)                        │  │
│  │                                                       │  │
│  │  ┌──────────────────────────────────────────────┐   │  │
│  │  │  QAT Hardware                                  │   │  │
│  │  │                                               │   │  │
│  │  │  - Symmetric Crypto (AES/DES/HMAC)           │   │  │
│  │  │  - Hash (SHA/MD5)                            │   │  │
│  │  │  - Compression (Deflate)                      │   │  │
│  │  │  - RSA/EC/DH (Public Key)                     │   │  │
│  │  └──────────────────────────────────────────────┘   │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 QAT PMD

```c
// QAT 设备初始化
int
qat_init(void)
{
    // QAT 驱动自动发现
    // 无需手动加载

    // 查看设备
    uint8_t qat_count = rte_cryptodev_count();
    for (int i = 0; i < qat_count; i++) {
        const char *name = rte_cryptodev_get_name(i);
        printf("Crypto device %d: %s\n", i, name);
    }

    return 0;
}
```

### 4.3 QAT vs AESNI 软件

| 特性         | QAT          | AESNI (软件) |
| ------------ | ------------ | ------------ |
| **CPU 使用** | 极低         | 高           |
| **吞吐量**   | ~40 Gbps     | ~5 Gbps      |
| **延迟**     | ~1-2μs       | ~100ns       |
| **功耗**     | 高           | 低           |
| **成本**     | 需要额外硬件 | 集成在 CPU   |

## 5. AES-NI

### 5.1 AESNI PMD

```c
// AESNI-MB 软件 PMD
// 使用 CPU AES-NI + SSE/AVX 指令

#include <rte_crypto_aesni_mb.h>

// 创建设备
uint8_t dev_id = rte_cryptodev_find_dev_id("AESNI_MB");
if (dev_id == RTE_CRYPTO_MAX_DEVS)
    return -1;

// 性能对比
// AESNI-MB: ~3-5 Gbps per core
// QAT: ~10-40 Gbps per device
```

### 5.2 GCM 模式

```c
// AES-GCM 加密
struct rte_crypto_sym_xform gcm = {
    .type = RTE_CRYPTO_SYM_XFORM_AEAD,
    .aead = {
        .algo = RTE_CRYPTO_AEAD_AES_GCM,
        .key = {0x00, 0x01, 0x02, ...},
        .key_len = 32,  // 256-bit
        .iv_len = 12,   // GCM IV
        .digest_len = 16,
    },
};
```

## 6. IPsec 集成

### 6.1 IPsec 卸载

```
┌─────────────────────────────────────────────────────────────┐
│                    IPsec Lookaside                         │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              Crypto Device (QAT/AESNI)               │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↑                                │
│                    Crypto Request                          │
│                            ↑                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              DPDK IPsec Library                       │  │
│  │                                                       │  │
│  │  - SA Management                                    │  │
│  │  - Tunnel/Transport                                 │  │
│  │  - ESP/AH                                          │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 6.2 IPsec 配置

```c
// IPsec SA
struct rte_ipsec_sa {
    uint32_t spi;
    uint32_t src_ip;
    uint32_t dst_ip;

    // 加密参数
    enum rte_crypto_cipher_algorithm cipher_algo;
    uint8_t cipher_key[32];

    // 认证参数
    enum rte_crypto_auth_algorithm auth_algo;
    uint8_t auth_key[64];
};

// IPsec 安全策略
struct rte_ipsec_sp {
    uint32_t src_ip;
    uint32_t dst_ip;
    uint16_t src_port;
    uint16_t dst_port;
    uint8_t proto;  // ESP(50), AH(51)

    struct rte_ipsec_sa *sa;
};
```

### 6.3 IPsec 处理

```c
// 加密 IPsec 包
int
ipsec_encap(struct rte_ipsec_sa *sa,
             struct rte_mbuf *mbuf,
             uint8_t dev_id)
{
    // 添加 ESP 头
    struct rte_esp_hdr *esp =
        (struct rte_esp_hdr *)rte_pktmbuf_prepend(mbuf,
            sizeof(struct rte_esp_hdr) + sa->iv_len);

    // 设置 SPI
    esp->spi = sa->spi;

    // 设置序列号
    esp->seq = rte_atomic32_add_return(&sa->seq, 1);

    // 加密
    return encrypt_packet(dev_id, sa->session, mbuf);
}

// 解密 IPsec 包
int
ipsec_decap(struct rte_ipsec_sa *sa,
             struct rte_mbuf *mbuf,
             uint8_t dev_id)
{
    // 解密
    return decrypt_packet(dev_id, sa->session, mbuf);

    // 移除 ESP 头
    rte_pktmbuf_adj(mbuf, sizeof(struct rte_esp_hdr) + sa->iv_len);
}
```

## 7. 性能优化

### 7.1 批量处理

```c
// 批量加密
int
encrypt_batch(uint8_t dev_id,
              struct rte_cryptodev_sym_session *session,
              struct rte_mbuf **mbufs,
              int count)
{
    struct rte_crypto_op *ops[32];
    int i;

    // 分配 ops
    for (i = 0; i < count && i < 32; i++) {
        ops[i] = rte_crypto_op_alloc(NULL, RTE_CRYPTO_OP_TYPE_SYMMETRIC);
        ops[i]->sym->session = session;
        ops[i]->sym->m_src = mbufs[i];
    }

    // 批量提交
    uint16_t nb_enq = rte_cryptodev_enqueue_burst(dev_id, 0, ops, i);

    // 等待完成
    uint16_t nb_deq = rte_cryptodev_dequeue_burst(dev_id, 0, ops, i, 0);

    return nb_deq;
}
```

### 7.2 零拷贝

```c
// 使用 SGL (Scatter-Gather List) 避免拷贝
struct rte_crypto_vec {
    uint64_t iova;      // IOVA 地址
    uint32_t len;       // 长度
};

int
encrypt_sgl(uint8_t dev_id,
            struct rte_cryptodev_sym_session *session,
            struct rte_mbuf *mbuf)
{
    // 获取 mbuf 的 SGL
    int n = rte_pktmbuf_data_len(mbuf);
    struct rte_crypto_vec vec[RTE_MAX_SEGS];
    int n_vec = rte_pktmbuf_to_vec(mbuf, vec, RTE_MAX_SEGS);

    // 设置 SGL 操作
    struct rte_crypto_sym_op *op;
    op->sym->m_src = NULL;  // 使用 SGL
    op->sym->vec = vec;
    op->sym->num_vecs = n_vec;
}
```

## 8. 总结

Cryptodev 架构：

```
┌─────────────────────────────────────────────────────────────┐
│                    Cryptodev 数据流                         │
│                                                              │
│  App: mbuf → crypto_op → Cryptodev → mbuf (encrypted)      │
│                  ↓                                          │
│           QAT / AESNI / OPENSSL                            │
└─────────────────────────────────────────────────────────────┘
```

卸载方案对比：

| 方案        | 吞吐量       | CPU 开销 | 延迟   |
| ----------- | ------------ | -------- | ------ |
| **QAT**     | ~40 Gbps     | 极低     | ~1-2μs |
| **AESNI**   | ~5 Gbps/core | 高       | ~100ns |
| **OpenSSL** | ~2 Gbps/core | 很高     | ~200ns |

IPsec 性能 (AES-256-GCM)：

| 方案            | 吞吐量       | CPS   |
| --------------- | ------------ | ----- |
| **内核 (xfrm)** | ~2-3 Gbps    | ~500K |
| **DPDK (软件)** | ~5 Gbps/core | ~1M   |
| **DPDK + QAT**  | ~20-40 Gbps  | ~5M   |

---

## 参考资源

- [DPDK Cryptodev](https://doc.dpdk.org/guides/cryptodevs/)
- [Intel QAT](https://www.intel.com/content/www/us/en/products/docs/accelerators/quick-assistance-technology.html)
- [DPDK IPsec](https://doc.dpdk.org/guides/prog_guide/ipsec_lib.html)
