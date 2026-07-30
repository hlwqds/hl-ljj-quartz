---
title: "DPDK 深度探索 ch37：TLS/DTLS 数据面加速——从 Record 加密到硬件卸载"
date: 2026-04-10 14:00:00
tags:
  [
    dpdk,
    tls,
    dtls,
    ssl,
    openssl,
    crypto,
    offload,
    session,
    aead,
    aes-gcm,
    rte-security,
    cryptodev,
    qat,
    lookaside,
  ]
description: "从 DPDK 工程视角解析 TLS/DTLS 加速：Record 层 AEAD 卸载、Lookaside Cryptodev 与 Inline rte_security、Session 管理、TLS 1.3 数据面差异、DTLS 抗重放、mTLS 控制面集成与性能测试方法"
---

# DPDK 深度探索 ch37：TLS/DTLS 数据面加速——从 Record 加密到硬件卸载

> [!info] 章节定位
> DPDK 深度探索系列 0. [[2026-04-09-dpdk-deep-dive-series-index|全栈学习路径总览]]
>
> 关联章节：
>
> - [[2026-04-09-dpdk-deep-dive-ch21-cryptodev|Cryptodev 框架]]
> - [[2026-04-09-dpdk-deep-dive-ch30-lookaside-crypto|Lookaside 加速——Cryptodev、QAT、IPsec]]
> - [[2026-04-09-dpdk-deep-dive-ch36-ipsec-deep-dive|IPsec 数据面——从 SA 状态机到硬件卸载]]
> - [[2026-04-09-dpdk-deep-dive-ch37-smartnic|SmartNIC 数据面——Representor、E-Switch 与硬件卸载]]

> [!abstract] 核心结论
> DPDK **不是 TLS 协议栈**，不做 handshake、不验证证书、不管理 session ticket。
>
> DPDK 对 TLS 的价值集中在 **TLS Record 层的 AEAD 加解密**：
>
> 1. **Lookaside**：通过 Cryptodev PMD（QAT、AESNI-MB 等）做 AES-GCM/ChaCha20-Poly1305，应用自行拼装 TLS Record；
> 2. **Inline**：通过 `rte_security` TLS_RECORD 协议会话，让 NIC 硬件直接处理整个 TLS Record（目前仅 Marvell CN10K 等少数设备支持）；
> 3. 应用仍需 OpenSSL/wolfSSL 完成 handshake、证书验证和密钥协商，然后把手 shake 产出的 key material 交给 DPDK 数据面；
> 4. Session cache、resumption、0-RTT 等状态管理全部由应用自己实现。

---

## 1. TLS 对 DPDK 意味着什么

### 1.1 TLS 处理的两个阶段

TLS 连接的处理可以明确分为两个阶段：

```text
控制面（Handshake）                 数据面（Record）
─────────────────────              ─────────────────
· 协商 cipher suite                · 每个包都要执行
· 证书验证                         · AEAD 加密/解密（AES-GCM 等）
· 密钥交换（ECDHE / RSA）          · 序列号递增
· 产出发送/接收密钥                 · Record header 组装/解析
· 1-2 RTT（TLS 1.2）               · 高吞吐、低延迟、每包都跑
· 1 RTT 或 0-RTT（TLS 1.3）
                                   ┌──────────────────────┐
· 低频（每连接 1 次）              │ ← DPDK 加速的就是这里  │
· CPU 密集但不频繁                 │    每秒可能百万次       │
                                   └──────────────────────┘
```

Handshake 偶尔发生，但 Record 层的 AEAD 操作每个包都要执行，这才是吞吐瓶颈。
DPDK 的价值在于用硬件加速或 CPU SIMD 加速把 Record 层的密码操作降到最低开销。

### 1.2 TLS 版本对数据面的影响

| 版本     | 年份 | 数据面 Cipher               | 对 DPDK 的影响                             |
| -------- | ---- | --------------------------- | ------------------------------------------ |
| TLS 1.0  | 1999 | CBC + HMAC                  | 不推荐，已废弃                             |
| TLS 1.1  | 2006 | CBC + HMAC                  | 不推荐，已废弃                             |
| TLS 1.2  | 2008 | AES-GCM、AES-CBC+HMAC       | GCM 是 AEAD，适合 cryptodev 卸载           |
| TLS 1.3  | 2018 | **仅 AEAD**（GCM/ChaCha20） | 数据面更简单统一，全是 AEAD                |
| DTLS 1.2 | 2012 | 同 TLS 1.2                  | Record header 多了 epoch + seq，需处理丢包 |

TLS 1.3 对 DPDK 是好消息：数据面只做 AEAD，没有 CBC + HMAC 的组合操作。
ChaCha20-Poly1305 在没有 AES 硬件加速的平台上（部分 ARM）是首选。

### 1.3 一个 TLS Record 的结构

无论 TLS 1.2 还是 1.3，应用数据传输阶段的 Record 格式相同：

```text
TLS Record（发送方向）：
┌──────────┬──────────┬──────────┬─────────────────────────┬─────────┐
│ ContentType│ Version  │  Length  │  AEAD Encrypted Payload │  Tag    │
│  1 byte   │ 2 bytes  │ 2 bytes  │      变长               │ 16 bytes│
│  (23=App) │ (0x0303) │          │                         │         │
└──────────┴──────────┴──────────┴─────────────────────────┴─────────┘
                                           │
                    ┌───────────────────────┘
                    ▼
              AEAD 输入：
              ┌───────────────────────────────────────────────┐
              │  Additional Authenticated Data (AAD)          │
              │  = seq_num(8) + type(1) + version(2) + len(2) │
              ├───────────────────────────────────────────────┤
              │  Plaintext                                    │
              │  = 实际应用数据                                │
              └───────────────────────────────────────────────┘
```

DPDK 在 Lookaside 模式下只负责 AEAD 加密/解密部分；应用需要自己组装 header、
维护序列号、构造 AAD。在 Inline 模式下，NIC 硬件处理整个 Record。

---

## 2. TLS 在 DPDK 中的两种加速路径

### 2.1 Lookaside vs Inline

```text
Lookaside TLS（最常见）：
═════════════════════════

  NIC ──收到 TLS Record──▶ 应用
                               │
                               ├─ 解析 TLS Record header
                               ├─ 提取 seq、构造 AAD
                               ├─ 构造 crypto op（AEAD decrypt）
                               └─ 提交到 Cryptodev PMD
                                      │
                                  ┌───▼───┐
                                  │  QAT  │  或 AESNI-MB / OpenSSL PMD
                                  │ AEAD  │
                                  └───┬───┘
                                      │
                               ◀── 拿到明文 mbuf


Inline TLS（少数硬件）：
═════════════════════════

  NIC（内置 TLS 引擎）
    │ 收到 TLS Record
    │ 硬件自动解密
    ▼
  应用 ◀── 拿到的已经是明文 mbuf（或解密后的数据）
```

### 2.2 选择标准

| 维度       | Lookaside                           | Inline                         |
| ---------- | ----------------------------------- | ------------------------------ |
| 硬件要求   | 任何 crypto PMD（QAT、AESNI-MB 等） | 特定 NIC（Marvell CN10K 为主） |
| 应用复杂度 | 高（自行拼装 Record、管理序列号）   | 低（硬件处理整个 Record）      |
| 灵活性     | 高（可组合不同 PMD 和算法）         | 低（受 NIC 固件限制）          |
| 延迟       | 多一次 CPU → PMD → CPU 往返         | 单次，NIC 内完成               |
| 成熟度     | 广泛部署，QAT 是生产首选            | 早期，硬件和驱动支持有限       |
| 适用场景   | 通用 TLS 网关、LB、代理             | 高吞吐 TLS 终端、DPU 场景      |

> [!warning] 不要高估 Inline TLS 的可用性
> 截至 DPDK 26.03，`rte_security` 的 `RTE_SECURITY_PROTOCOL_TLS_RECORD`
> 主要由 Marvell CN10K PMD 实现。常见 Intel E810、Mellanox ConnectX/BlueField
> **不支持** inline TLS Record 卸载。绝大多数生产部署使用 Lookaside。

---

## 3. Lookaside TLS：用 Cryptodev 做 AEAD

### 3.1 数据路径职责划分

在 Lookaside 模式下，应用和 Cryptodev 的分工：

```text
应用负责：                          Cryptodev PMD 负责：
────────────                        ──────────────────
· TLS Record header 解析/组装       · AEAD 加密/解密
· 序列号递增（每条 Record +1）      · GCM tag 生成/验证
· AAD 构造                          · 数据搬移（mbuf）
· IV 构造（TLS 1.2: explicit nonce  · （可能）DMA 到硬件
  + implicit nonce; TLS 1.3: 由
    seq 和 key 派生）
· key material 管理
```

应用拿到 handshake 产出的 key 后，创建 cryptodev session，然后对每个
Record 做一次 AEAD 操作。

### 3.2 Session 创建

```c
#include <rte_cryptodev.h>
#include <rte_security.h>

/*
 * TLS Record 使用 AEAD（AES-128-GCM 为例）。
 * key 和 salt 来自 handshake 产出的 key_material。
 *
 * TLS 1.2: key = server_write_key / client_write_key (16 bytes)
 *          salt = implicit nonce (4 bytes, 来自 key_block)
 * TLS 1.3: key = server/application traffic key (16 bytes)
 *          salt = iv (12 bytes, 来自 key 派生)
 */
struct rte_crypto_sym_xform aead_xform = {
    .type = RTE_CRYPTO_SYM_XFORM_AEAD,
    .aead = {
        .algo = RTE_CRYPTO_AEAD_AES128_GCM,
        .key = {
            .data = write_key,     /* 16 bytes, 来自 handshake */
            .length = 16,
        },
        .iv = {
            .data = iv_data,       /* 12 bytes */
            .length = 12,
        },
        .digest_length = 16,       /* GCM tag = 16 bytes */
        .aad_length = 13,          /* seq(8) + type(1) + ver(2) + len(2) */
        .op = RTE_CRYPTO_AEAD_OP_ENCRYPT,  /* 或 DECRYPT */
    },
};

/* 创建 session */
struct rte_cryptodev_sym_session *session;
session = rte_cryptodev_sym_session_create(dev_id, &aead_xform, session_pool);
if (session == NULL) {
    /* 检查：key 长度、算法是否被 PMD 支持、session pool 是否足够 */
    return -1;
}
```

### 3.3 Record 加密：构造 crypto op

```c
/*
 * 发送方向：明文 → 加密 TLS Record
 *
 * 输入 mbuf 布局：
 *   [TLS header (5)] [plaintext (N)]
 *
 * 输出 mbuf 布局：
 *   [TLS header (5)] [ciphertext (N)] [GCM tag (16)]
 */
static inline int
tls_record_encrypt(uint8_t dev_id, uint16_t qp_id,
                   struct rte_mbuf *mbuf,
                   struct rte_cryptodev_sym_session *session,
                   uint64_t seq_no, uint8_t content_type)
{
    struct rte_crypto_op *op;
    uint8_t aad[13];  /* AAD: seq(8) + type(1) + ver(2) + len(2) */
    uint16_t payload_len;

    op = rte_crypto_op_alloc(crypto_op_pool,
                             RTE_CRYPTO_OP_TYPE_SYMMETRIC);
    if (op == NULL)
        return -1;

    /* 关联 session */
    rte_crypto_op_attach_sym_session(op, session);

    /* 设置源 mbuf */
    op->sym->m_src = mbuf;

    /*
     * AEAD 操作范围：
     * - offset = 5（跳过 TLS header）
     * - length = 明文长度
     */
    payload_len = rte_pktmbuf_data_len(mbuf) - 5;
    op->sym->aead.data.offset = 5;
    op->sym->aead.data.length = payload_len;

    /* 构造 AAD */
    memset(aad, 0, sizeof(aad));
    /* seq_no: 8 bytes, network byte order */
    rte_memcpy(aad, &seq_no, 8);
    /* content_type: 1 byte */
    aad[8] = content_type;
    /* version: 0x03 0x03 (TLS 1.2) */
    aad[9] = 0x03;
    aad[10] = 0x03;
    /* length: 2 bytes, network byte order */
    aad[11] = (payload_len >> 8) & 0xFF;
    aad[12] = payload_len & 0xFF;

    op->sym->aead.aad.data = aad;
    op->sym->aead.aad.phys_addr = rte_malloc_virt2iova(aad);

    /* IV: TLS 1.2 中 implicit_nonce(4) + explicit_nonce(8) */
    /* explicit_nonce 放在 mbuf 的 header 之后、密文之前 */
    /* 这里假设 IV 已在 session 中设置了 implicit 部分 */
    op->sym->aead.iv.data = iv_data;
    op->sym->aead.iv.phys_addr = rte_malloc_virt2iova(iv_data);

    /* 提交到 cryptodev */
    uint16_t enq = rte_cryptodev_enqueue_burst(dev_id, qp_id, &op, 1);
    if (enq != 1) {
        rte_crypto_op_free(op);
        return -1;
    }

    return 0;
}
```

### 3.4 批量处理

TLS 网关通常需要同时处理大量连接。关键优化是批量提交：

```c
#define TLS_BURST_SIZE 32

static inline uint16_t
tls_records_encrypt_burst(uint8_t dev_id, uint16_t qp_id,
                          struct rte_mbuf **mbufs,
                          struct rte_cryptodev_sym_session **sessions,
                          int nb_pkts)
{
    struct rte_crypto_op *ops[TLS_BURST_SIZE];
    int n = RTE_MIN(nb_pkts, TLS_BURST_SIZE);
    int i, enqueued;

    for (i = 0; i < n; i++) {
        ops[i] = rte_crypto_op_alloc(crypto_op_pool,
                                     RTE_CRYPTO_OP_TYPE_SYMMETRIC);
        if (ops[i] == NULL)
            break;

        rte_crypto_op_attach_sym_session(ops[i], sessions[i]);
        ops[i]->sym->m_src = mbufs[i];
        /* ... 设置 aead 参数（同上单个示例） ... */
    }

    enqueued = rte_cryptodev_enqueue_burst(dev_id, qp_id, ops, i);

    /* 处理未入队的 ops */
    for (int j = enqueued; j < i; j++)
        rte_crypto_op_free(ops[j]);

    return enqueued;
}
```

> [!warning] 批量处理中的序列号
> 每条 TLS Record 的序列号必须严格递增。如果多个 Record 属于同一连接，
> 序列号必须在应用层正确分配。跨 burst 的序列号管理是应用的责任。

### 3.5 PMD 选择

| PMD              | 类型      | AEAD 算法                  | 典型吞吐        | 适用场景                |
| ---------------- | --------- | -------------------------- | --------------- | ----------------------- |
| **QAT**          | 硬件      | AES-GCM, AES-CCM, ChaCha20 | 25-50 Gbps      | 生产 TLS 网关、LB、代理 |
| **AESNI-MB**     | 软件 SIMD | AES-GCM, AES-CCM           | ~8 Gbps/core    | 无 QAT 时的软件加速     |
| **AESNI-GCM**    | 软件 SIMD | AES-GCM only               | ~10 Gbps/core   | 只需 GCM 的场景         |
| **OpenSSL PMD**  | 软件      | 全部 OpenSSL 支持的算法    | ~1.5 Gbps       | 功能验证、开发调试      |
| **ARMv8 Crypto** | 软件 SIMD | AES-GCM, AES-CBC           | 取决于平台      | ARM 服务器              |
| **CN10K**        | 硬件      | AES-GCM, ChaCha20          | 高（可 inline） | Marvell 生态            |

选择建议：

- **有 QAT 硬件**：首选 QAT，吞吐最高、CPU 释放最多
- **无专用硬件**：AESNI-MB（多算法）或 AESNI-GCM（只做 GCM 最快）
- **ARM 平台**：ARMv8 Crypto PMD
- **开发/验证**：OpenSSL PMD，功能最全但性能最低
- **Marvell CN10K**：可走 inline TLS，见下节

### 3.6 rte_tls.h：DPDK 定义的 Record 头

DPDK 提供了 TLS/DTLS Record header 的结构定义（`rte_tls.h`），
方便应用解析和组装 Record header：

```c
#include <rte_tls.h>

/* TLS Record Header（5 bytes） */
struct rte_tls_hdr {
    uint8_t type;           /* ContentType: 20=CCS, 21=Alert, 22=HS, 23=App */
    rte_be16_t version;     /* ProtocolVersion: 0x0303 (TLS 1.2) */
    rte_be16_t length;      /* payload 长度（不含 header 自身） */
} __rte_packed;

/* DTLS Record Header（13 bytes） */
struct rte_dtls_hdr {
    uint8_t type;
    rte_be16_t version;
    uint16_t epoch;         /* DTLS 特有：密钥切换计数器 */
    uint48_t seq_no;        /* DTLS 特有：6 字节序列号 */
    rte_be16_t length;
} __rte_packed;
```

这些只是 header 定义，DPDK 不提供完整的 TLS Record 层实现。
应用仍然需要自己处理序列号、AEAD 参数和 Record 组装。

---

## 4. Inline TLS：rte_security TLS_RECORD

### 4.1 工作原理

Inline TLS 让 NIC 硬件直接处理 TLS Record 层：

```text
发送方向（加密）：
  应用 ──明文 mbuf──▶ NIC
                         │ rte_security TLS_RECORD session
                         │ 硬件自动：
                         │   1. 添加 TLS Record header
                         │   2. AEAD 加密
                         │   3. 添加 GCM tag
                         ▼
                       wire（完整 TLS Record）

接收方向（解密）：
  wire ──TLS Record──▶ NIC
                         │ rte_security TLS_RECORD session
                         │ 硬件自动：
                         │   1. 解析 TLS Record header
                         │   2. AEAD 解密 + tag 验证
                         │   3. 去掉 header 和 tag
                         ▼
                       应用 ◀── 明文 mbuf
```

### 4.2 Session 配置

```c
#include <rte_security.h>

/*
 * Inline TLS 需要创建 rte_security session，
 * 指定 RTE_SECURITY_PROTOCOL_TLS_RECORD。
 */
struct rte_security_session_conf sess_conf = {
    .action_type = RTE_SECURITY_ACTION_TYPE_INLINE_PROTOCOL,
    .protocol = RTE_SECURITY_PROTOCOL_TLS_RECORD,
    .tls_record = {
        .ver = RTE_SECURITY_VERSION_TLS_1_2,  /* 或 TLS_1_3 / DTLS_1_2 */
        .type = RTE_SECURITY_TLS_SESS_TYPE_WRITE,  /* 或 READ */
        .tls_1_2 = {
            .seq_no = 0,          /* 初始序列号 */
            .imp_nonce = { ... }, /* implicit nonce (4 bytes) */
        },
    },
    .crypto_xform = &aead_xform,  /* AEAD 配置 */
};

/* 创建 security session */
struct rte_security_session *sec_sess;
sec_sess = rte_security_session_create(ctx, &sess_conf, sess_pool);
```

### 4.3 TLS 1.3 特有参数

TLS 1.3 的 Record 层与 1.2 有细微差异：

```c
struct rte_security_session_conf sess_conf_13 = {
    .action_type = RTE_SECURITY_ACTION_TYPE_INLINE_PROTOCOL,
    .protocol = RTE_SECURITY_PROTOCOL_TLS_RECORD,
    .tls_record = {
        .ver = RTE_SECURITY_VERSION_TLS_1_3,
        .type = RTE_SECURITY_TLS_SESS_TYPE_WRITE,
        .tls_1_3 = {
            .seq_no = 0,
            .imp_nonce = { ... },   /* 12 bytes IV, 来自 key 派生 */
            .min_payload_len = 0,    /* TLS 1.3 record 的最小 payload */
        },
    },
    .crypto_xform = &aead_xform,
};
```

### 4.4 硬件支持现状

| 平台             | TLS Record Inline | 支持版本              | 备注                                     |
| ---------------- | ----------------- | --------------------- | ---------------------------------------- |
| Marvell CN10K    | ✅                | TLS 1.2/1.3, DTLS 1.2 | 目前最完整的 inline TLS 实现             |
| Intel E810       | ❌                | —                     | 支持 IPsec inline，不支持 TLS            |
| NVIDIA ConnectX  | ❌                | —                     | 支持 IPsec inline，不支持 TLS            |
| NVIDIA BlueField | ❌                | —                     | DOCA 有 TLS 库，但非 rte_security inline |

> [!warning] Inline TLS 不等于 IPsec Inline
> 很多 NIC 支持 IPsec inline offload（通过 `rte_security` 的
> `RTE_SECURITY_PROTOCOL_IPSEC`），但 **不支持 TLS Record inline**。
> 这是两个不同的 security protocol，硬件实现也不同。
> 购买硬件前必须确认具体的 security protocol 支持。

---

## 5. TLS Session 管理：DPDK 不做的事

### 5.1 DPDK 不提供的 TLS 功能

这是一个容易产生误解的关键点。下表列出了 TLS 功能中 DPDK **不负责**的部分：

| 功能                   | 谁来做                           | DPDK 的角色                  |
| ---------------------- | -------------------------------- | ---------------------------- |
| TLS Handshake          | OpenSSL / wolfSSL / mbedTLS      | 无                           |
| 证书验证               | OpenSSL / 应用                   | 无                           |
| Cipher suite 协商      | OpenSSL                          | 无                           |
| Key 派生（PRF/HKDF）   | OpenSSL                          | 接收 handshake 产出的 key    |
| Session ticket 管理    | OpenSSL / 应用                   | 无                           |
| Session resumption     | OpenSSL / 应用                   | 无                           |
| 0-RTT early data 处理  | OpenSSL / 应用                   | 无                           |
| TLS Record header 组装 | 应用（lookaside）/ NIC（inline） | lookaside 模式下应用自行处理 |
| 序列号管理             | 应用（lookaside）/ NIC（inline） | lookaside 模式下应用自行处理 |
| AEAD 加解密            | Cryptodev PMD / NIC inline       | **这是 DPDK 做的事**         |

### 5.2 与 OpenSSL 的集成模式

典型的集成架构：

```text
                    控制面                           数据面
          ┌────────────────────┐        ┌──────────────────────────┐
          │     OpenSSL        │        │      DPDK 应用            │
          │                    │        │                          │
          │  · SSL_CTX 配置    │        │  · 从 NIC 收包           │
          │  · 证书加载        │        │  · 解析 TLS Record hdr   │
          │  · SSL_accept()    │───────▶│  · 构造 AEAD op          │
          │  · SSL_connect()   │ key +  │  · 提交 Cryptodev        │
          │  · 密钥协商        │ salt   │  · 获取明文              │
          │                    │        │  · 业务处理              │
          └────────────────────┘        │  · 明文 → AEAD 加密      │
                                        │  · 组装 TLS Record       │
                                        │  · 发送到 NIC            │
                                        └──────────────────────────┘
```

集成步骤：

1. **Handshake**：用 OpenSSL 完成 TLS handshake（或通过 proxy 完成）
2. **提取 key material**：从 OpenSSL 的 `SSL` 对象中提取
   `client_write_key`、`server_write_key`、IV/salt
3. **创建 DPDK session**：用这些 key 创建 cryptodev session
4. **数据面**：后续 Record 层处理全部在 DPDK 中完成

### 5.3 Session Cache 实现框架

如果需要支持大量并发 TLS 连接，应用需要自己实现 session cache：

```c
/*
 * 简单的 TLS session cache 框架。
 * 生产环境需要考虑：并发安全、老化、内存限制。
 */
#include <rte_hash.h>
#include <rte_jhash.h>
#include <rte_mempool.h>

struct tls_session_entry {
    uint64_t session_id;                        /* TLS session ID */
    struct rte_cryptodev_sym_session *crypto_sess; /* Cryptodev session */
    uint8_t write_key[16];                      /* 当前 write key */
    uint8_t read_key[16];                       /* 当前 read key */
    uint64_t write_seq;                         /* 发送序列号 */
    uint64_t read_seq;                          /* 接收序列号 */
    rte_be32_t src_ip;
    rte_be16_t src_port;
    rte_be32_t dst_ip;
    rte_be16_t dst_port;
    uint64_t last_used;                         /* 用于 LRU 老化 */
};

#define MAX_TLS_SESSIONS 65536

struct tls_session_cache {
    struct rte_hash *hash;          /* session_id → index */
    struct tls_session_entry *entries;
    struct rte_mempool *entry_pool;
    uint32_t count;
    uint32_t capacity;
};

/* 创建 cache */
struct tls_session_cache *
tls_session_cache_create(void)
{
    struct rte_hash_parameters hp = {
        .name = "tls_sessions",
        .entries = MAX_TLS_SESSIONS,
        .key_len = sizeof(uint64_t),
        .hash_func = rte_jhash,
        .hash_func_init_val = 0,
        .socket_id = rte_socket_id(),
    };

    struct tls_session_cache *cache = rte_malloc(NULL, sizeof(*cache), 0);
    cache->hash = rte_hash_create(&hp);
    cache->entries = rte_malloc(NULL,
        sizeof(struct tls_session_entry) * MAX_TLS_SESSIONS, 0);
    cache->count = 0;
    cache->capacity = MAX_TLS_SESSIONS;

    return cache;
}

/* 查找 session */
static inline struct tls_session_entry *
tls_session_lookup(struct tls_session_cache *cache, uint64_t session_id)
{
    int idx = rte_hash_lookup(cache->hash, &session_id);
    if (idx < 0)
        return NULL;
    return &cache->entries[idx];
}
```

> [!info] Session resumption 与 key 更新
> TLS 1.3 的 KeyUpdate 和 session resumption 会产生新的 key material。
> 应用必须在 key 更新时销毁旧的 cryptodev session 并用新 key 创建新的。
> 这个生命周期管理是应用的责任，DPDK 不跟踪 key 状态。

---

## 6. TLS 1.3 对数据面的影响

### 6.1 Record 层变化

TLS 1.3 相对 1.2 在数据面有几个关键差异：

| 方面             | TLS 1.2                      | TLS 1.3                                |
| ---------------- | ---------------------------- | -------------------------------------- |
| Cipher 类型      | AEAD 或 CBC+HMAC             | **仅 AEAD**                            |
| IV 构造          | implicit(4) + explicit(8)    | 由 per-record nonce 派生（XOR iv+seq） |
| AAD 格式         | seq(8)+type(1)+ver(2)+len(2) | 同 TLS 1.2（向后兼容）                 |
| ContentType 外层 | 明文                         | **加密后**（内层 type 可能不同）       |
| Key 更新         | 无内置机制                   | KeyUpdate 消息，需重新创建 session     |
| 0-RTT            | 不支持                       | 支持（early data，有重放风险）         |

### 6.2 IV 构造差异

TLS 1.2 和 1.3 的 IV 构造方式不同，这直接影响 cryptodev 的 IV 参数：

```text
TLS 1.2：
  nonce = implicit_nonce(4) || explicit_nonce(8)
  explicit_nonce 每条 Record 递增，放入 Record 中明文传输

TLS 1.3：
  per-record nonce = left_pad(seq, 12) XOR client_write_iv(12)
  seq 每条 Record 递增
  没有显式的 nonce 字段——接收方自己用 seq 和 IV 算出来
```

在 lookaside 模式下，应用必须按版本正确构造 IV：

- TLS 1.2：把 12 字节完整 nonce 传给 cryptodev
- TLS 1.3：用 `seq XOR iv` 算出 per-record nonce，传给 cryptodev

### 6.3 0-RTT Early Data

TLS 1.3 的 0-RTT 允许客户端在握手完成前发送数据，这对数据面有影响：

```text
普通 1-RTT：                      0-RTT：
Client                Server      Client                Server
  │ ClientHello ──────▶│           │ ClientHello ──────▶│
  │                    │           │ + Early Data ─────▶│  ← 使用旧 key
  │ ◀── ServerHello ──│           │ ◀── ServerHello ──│
  │ ◀── App Data ─────│           │ ◀── App Data ─────│
  │ ── App Data ──────▶│           │ ── App Data ─────▶│  ← 使用新 key
```

0-RTT 的数据面注意点：

- **重放风险**：0-RTT early data 可能被网络重放，应用必须自行防重放（幂等、
  一次性 token、时间窗口等）
- **Key 切换**：0-RTT 用旧 PSK 派生的 key，handshake 完成后切换到新 key，
  需要销毁旧 cryptodev session 并创建新的
- **DPDK 不管理 key 生命周期**：key 切换时机由应用和 OpenSSL 协调

---

## 7. DTLS 在 DPDK 中的特殊处理

### 7.1 DTLS vs TLS Record 格式

DTLS 运行在 UDP 之上，Record header 比 TLS 多了 epoch 和 sequence_number：

```text
TLS Record Header（5 bytes）：         DTLS Record Header（13 bytes）：
┌──────────┬─────────┬─────────┐      ┌──────────┬─────────┬─────────┬──────────────┬─────────┐
│ type     │ version │ length  │      │ type     │ version │ epoch   │ seq_number   │ length  │
│ 1 byte   │ 2 bytes │ 2 bytes │      │ 1 byte   │ 2 bytes │ 2 bytes │ 6 bytes      │ 2 bytes │
└──────────┴─────────┴─────────┘      └──────────┴─────────┴─────────┴──────────────┴─────────┘
```

epoch 标识密钥切换，每次 rekey 后 epoch +1。seq_number 在每个 epoch 内递增。

### 7.2 DTLS 特有的数据面问题

| 问题          | 说明                                                 | 应用处理                        |
| ------------- | ---------------------------------------------------- | ------------------------------- |
| 丢包          | UDP 不保证交付，AEAD 可能因缺包而无法解密后续 Record | 需要重传机制或跳过              |
| 乱序          | UDP 不保证顺序，seq 可能乱序到达                     | 需要缓冲和重排序                |
| 抗重放        | 攻击者可重放 UDP 包                                  | 需要滑动窗口检查 seq            |
| MTU 限制      | UDP 不能分片，TLS Record 不能超过 PMTU               | 需要分片和重组                  |
| 连接 ID (CID) | DTLS 1.2 扩展 / DTLS 1.3 标准功能                    | 可能在 Record header 中增加 CID |

### 7.3 DTLS 抗重放窗口

DTLS 的抗重放窗口是应用必须实现的功能（DPDK 不提供）：

```c
/*
 * DTLS 抗重放滑动窗口。
 * 参考 RFC 6347 Section 4.1.2.6。
 */
#define DTLS_REPLAY_WINDOW_SIZE 64

struct dtls_replay_window {
    uint64_t bitmap;          /* 位图：bit i = seq (max_seq - i) 是否已收到 */
    uint64_t max_seq;         /* 当前最大已接收 seq */
    uint16_t epoch;           /* 当前 epoch */
};

static inline int
dtls_replay_check(struct dtls_replay_window *win,
                  uint16_t epoch, uint64_t seq)
{
    /* epoch 不匹配 → 需要特殊处理（rekey 或旧 epoch） */
    if (epoch != win->epoch)
        return -1;

    /* 太旧的包，落在窗口之外 */
    if (seq + DTLS_REPLAY_WINDOW_SIZE <= win->max_seq)
        return 0;  /* 丢弃 */

    /* 重放检测 */
    uint64_t diff = seq - win->max_seq;
    if (diff > 0) {
        /* 新 seq，右移窗口 */
        win->bitmap <<= diff;
        win->max_seq = seq;
        win->bitmap |= 1;
        return 1;  /* 接受 */
    }

    /* 在窗口内，检查是否已收到 */
    if (win->bitmap & (1ULL << (-diff)))
        return 0;  /* 重放，丢弃 */

    win->bitmap |= (1ULL << (-diff));
    return 1;  /* 接受 */
}
```

### 7.4 DTLS 在 rte_security 中的支持

DTLS 1.2 的 inline offload 通过 `rte_security` 的 TLS_RECORD 协议支持：

```c
struct rte_security_session_conf dtls_conf = {
    .action_type = RTE_SECURITY_ACTION_TYPE_INLINE_PROTOCOL,
    .protocol = RTE_SECURITY_PROTOCOL_TLS_RECORD,
    .tls_record = {
        .ver = RTE_SECURITY_VERSION_DTLS_1_2,
        .type = RTE_SECURITY_TLS_SESS_TYPE_READ,
        .dtls_1_2 = {
            .seq_no = 0,
            .epoch = 0,
            .imp_nonce = { ... },
        },
    },
    .crypto_xform = &aead_xform,
};
```

> [!info] DTLS 的 inline offload 更有价值
> DTLS 的抗重放、分片、乱序处理在软件中开销很大。如果 NIC 能 inline 处理
> DTLS Record（包括解密和重放检查），可以显著减轻 CPU 负担。
> 但目前支持 DTLS inline 的硬件同样非常有限。

---

## 8. mTLS：控制面事务，不影响数据面

### 8.1 mTLS 握手流程

双向 TLS（mTLS）要求客户端也提供证书，但这是 **handshake 阶段的控制面事务**：

```text
Client                               Server
  │                                     │
  │  ① ClientHello ─────────────────▶ │
  │                                     │
  │  ② ◀──── ServerHello              │
  │  ③ ◀──── Certificate              │  服务器证书
  │  ④ ◀──── CertificateRequest       │  要求客户端提供证书
  │                                     │
  │  ⑤ Certificate ──────────────────▶│  客户端证书
  │  ⑥ CertificateVerify ───────────▶│  签名验证
  │                                     │
  │  ⑦ Finished ◀────────────────────│
  │  ⑧ Finished ────────────────────▶│
  │                                     │
  │  ═══ App Data（Record AEAD）═══   │  ← DPDK 加速从这里开始
```

### 8.2 对数据面的影响

mTLS 对 DPDK 数据面 **没有额外影响**：

- 数据面的 AEAD 操作与单向 TLS 完全相同
- 证书验证在 handshake 阶段由 OpenSSL 完成，不经过 DPDK
- 双向认证不增加 Record 层的处理量

但 mTLS 对 **性能有间接影响**：

| 因素           | 影响                                         |
| -------------- | -------------------------------------------- |
| 客户端证书验证 | 增加 handshake 延迟和 CPU 开销（验证证书链） |
| 证书大小       | 大证书增加 handshake 传输量                  |
| 连接建立频率   | 短连接场景下 mTLS 开销更明显                 |
| 缓解措施       | Session resumption 减少完整 handshake 次数   |

### 8.3 Session Resumption

Session resumption 是降低 mTLS 开销的关键手段：

```text
完整握手（2-RTT）:                  Resumption（0-RTT 或 1-RTT）:
Client          Server              Client          Server
  │               │                   │               │
  │ ── Hello ────▶│                   │ ── Hello ────▶│  + PSK
  │               │                   │               │  + early data (0-RTT)
  │ ◀── Certs ──│                   │ ◀── Hello ───│
  │ ◀── CertReq ─│                   │               │  ← 跳过证书交换
  │ ── Cert ────▶│                   │               │
  │ ── Verify ──▶│                   │ ═══ App Data ═│
  │               │                   │               │
  │ ═══ App Data ═│                   │               │
```

在 DPDK 场景下，resumption 意味着：

- **Session cache** 命中后可跳过完整握手
- **Pre-shared key (PSK)** 可直接创建 cryptodev session，无需等待 handshake
- **0-RTT** 允许在 handshake 完成前就开始 AEAD 处理（但有重放风险）

---

## 9. 性能测试

### 9.1 dpdk-test-crypto-perf

DPDK 自带的 `dpdk-test-crypto-perf` 工具可以测试 TLS 相关的 AEAD 算法性能：

```bash
# 测试 AES-128-GCM（TLS 1.2/1.3 最常用 cipher）
./dpdk-test-crypto-perf -l 0-3 -- \
    --devtype crypto_qat \
    --optype aead \
    --aead-algo aes-128-gcm \
    --aead-key-sz 16 \
    --aead-iv-sz 12 \
    --aead-op encrypt \
    --aead-aad-sz 13 \
    --digest-sz 16 \
    --total-ops 10000000 \
    --burst-size 32 \
    --buffer-sz 64,256,1024,1400 \
    --ptest throughput

# 测试 ChaCha20-Poly1305（TLS 1.3，ARM 平台常用）
./dpdk-test-crypto-perf -l 0-3 -- \
    --devtype crypto_aesni_mb \
    --optype aead \
    --aead-algo chacha20-poly1305 \
    --aead-key-sz 32 \
    --aead-iv-sz 12 \
    --aead-op encrypt \
    --aead-aad-sz 13 \
    --digest-sz 16 \
    --total-ops 1000000 \
    --ptest throughput
```

### 9.2 性能参考数据

以下数据基于不同硬件平台的典型结果，实际性能取决于具体 SKU、频率、PCIe 带宽和负载：

| 平台               | AEAD 算法         | 包大小 | 吞吐（Gbps） | 操作/s（Kops） | CPU 占用 |
| ------------------ | ----------------- | ------ | ------------ | -------------- | -------- |
| QAT (Gen4)         | AES-128-GCM       | 1400   | 40-50        | ~3500          | ~15%     |
| QAT (Gen4)         | AES-256-GCM       | 1400   | 35-45        | ~3000          | ~15%     |
| AESNI-MB (单核)    | AES-128-GCM       | 1400   | 6-8          | ~500           | ~90%     |
| AESNI-GCM (单核)   | AES-128-GCM       | 1400   | 8-10         | ~700           | ~90%     |
| OpenSSL PMD (单核) | AES-128-GCM       | 1400   | 1-2          | ~100           | ~100%    |
| ARMv8 Crypto       | AES-128-GCM       | 1400   | 4-6          | ~350           | ~90%     |
| QAT (Gen4)         | ChaCha20-Poly1305 | 1400   | 取决于版本   | —              | —        |
| AESNI-MB (单核)    | ChaCha20-Poly1305 | 1400   | 4-6          | ~350           | ~90%     |

> [!warning] 性能数据仅供参考
> 以上数据来自公开基准测试和厂商白皮书，实际数字取决于：
>
> - 具体 CPU 型号和频率
> - QAT SKU（8950 vs C627/C62x）
> - PCIe 带宽和 NUMA 位置
> - 并发连接数和 session 复用率
> - burst size 和队列配置
>
> 必须在自己的硬件上用 `dpdk-test-crypto-perf` 实测。

### 9.3 调优要点

```text
1. NUMA 对齐
   QAT 设备、cryptodev queue pair、session pool、mbuf pool
   必须在同一个 NUMA node，否则跨 node 访问会严重降低性能。

2. Queue Pair 数量
   QAT 通常支持多个 queue pair。
   数量 = 活跃 lcore 数或并发连接分组数。
   不要超过设备最大 qp 数。

3. Burst Size
   典型值 16-64。
   过小：每次 enqueue/dequeue 开销占比大。
   过大：延迟增加，内存占用高。
   需要实测找到拐点。

4. Session Pool 大小
   预估最大并发 TLS 连接数 × 2（读写各一个 session）。
   加上余量（20-30%）用于 key 更新期间的临时 session。

5. Buffer 大小
   测试不同 buffer 大小（64、256、1024、1400）的组合。
   小包场景 ops/s 高但 Gbps 低，大包场景反之。
   实际流量 mix 决定最终性能。

6. Headroom/Tailroom
   mbuf 的 headroom 需要容纳 TLS Record header（5 bytes）。
   Tailroom 需要容纳 GCM tag（16 bytes）。
   如果 mbuf 空间不足，加密后会触发分段或拷贝。
```

---

## 10. 常见问题与排障

| 现象                        | 可能原因                                        | 排查方向                                |
| --------------------------- | ----------------------------------------------- | --------------------------------------- |
| GCM tag 验证失败            | AAD 构造错误、序列号不一致、IV 错误             | 打印 AAD 字节对比 Wireshark 抓包        |
| 吞吐远低于预期              | NUMA 不对齐、burst 太小、qp 配置不足            | 检查 `rte_cryptodev_info`、lcore 位置   |
| Session 创建失败            | pool 不足、算法不支持、key 长度错误             | 检查 PMD capability、session pool 大小  |
| 解密后明文乱码              | key 或 IV 与对端不匹配                          | 确认 handshake key 正确传入 cryptodev   |
| TLS 1.3 解密失败但 1.2 正常 | IV 构造方式不同（seq XOR iv vs explicit nonce） | 检查 IV 计算逻辑                        |
| 大量连接时内存不足          | session pool 不够、mbuf pool 不够               | 预估连接数 × 每 session 内存，调大 pool |
| QAT dequeue 返回 0          | enqueue 太快、qp 满了、设备故障                 | 检查 qp depth、设备状态、重启 QAT       |
| DTLS 特定 seq 解密失败      | 乱序或丢包导致 seq 不连续                       | 检查抗重放窗口、UDP 重传                |
| Inline TLS session 创建失败 | 硬件不支持、PMD 未实现                          | 确认 NIC 型号和 PMD capability          |

---

## 11. 总结

TLS 加速在 DPDK 中的核心模型：

```text
Handshake（控制面）：       Record AEAD（数据面）：
  OpenSSL / wolfSSL           Cryptodev PMD / rte_security
  · 证书验证                  · AES-GCM / ChaCha20-Poly1305
  · 密钥协商                  · lookaside（QAT/AESNI）或 inline（CN10K）
  · cipher suite 选择          · 应用拼装 Record（lookaside）
  · key material 派生         · 硬件拼装 Record（inline）
        │                                    │
        └────── key + salt ─────────────────┘
```

关键要点：

1. **DPDK 加速的是 AEAD，不是整个 TLS**。Handshake、证书、密钥协商留给 OpenSSL
2. **Lookaside 是主流**：QAT 是生产首选，AESNI-MB 是无硬件时的备选
3. **Inline TLS 支持有限**：目前主要是 Marvell CN10K，常见 x86 NIC 不支持
4. **应用管理序列号和 Record 组装**：这是 lookaside 模式下最易出错的部分
5. **Session cache 是应用的责任**：DPDK 不提供 TLS session 管理
6. **TLS 1.3 对数据面更友好**：AEAD-only，但 IV 构造和 key 更新逻辑不同
7. **DTLS 有额外的抗重放和乱序负担**：软件实现需要滑动窗口

> **选型时最重要的问题不是"DPDK 能不能加速 TLS"，而是"我的硬件支持哪种加速模式，应用需要承担多少 Record 层管理工作"。**

---

## 参考资料

### DPDK 官方文档

- [DPDK Cryptodev Framework](https://doc.dpdk.org/guides-26.03/prog_guide/cryptodev_lib.html)
- [DPDK rte_security](https://doc.dpdk.org/guides-26.03/prog_guide/rte_security.html)
- [DPDK TLS Header (rte_tls.h)](https://doc.dpdk.org/guides-26.03/api/rte__tls_8h.html)
- [DPDK Crypto Performance Application](https://doc.dpdk.org/guides-26.03/tools/cryptoperf.html)

### RFC

- [RFC 5246 — TLS 1.2](https://tools.ietf.org/html/rfc5246)
- [RFC 8446 — TLS 1.3](https://tools.ietf.org/html/rfc8446)
- [RFC 6347 — DTLS 1.2](https://tools.ietf.org/html/rfc6347)
- [RFC 5116 — AEAD](https://tools.ietf.org/html/rfc5116)

### PMD 文档

- [Intel QAT PMD](https://doc.dpdk.org/guides-26.03/cryptodevs/qat.html)
- [AESNI-MB PMD](https://doc.dpdk.org/guides-26.03/cryptodevs/aesni_mb.html)
- [AESNI-GCM PMD](https://doc.dpdk.org/guides-26.03/cryptodevs/aesni_gcm.html)
- [OpenSSL PMD](https://doc.dpdk.org/guides-26.03/cryptodevs/openssl.html)
- [Marvell CNXK Security](https://doc.dpdk.org/guides-26.03/platform/cnxk.html)
