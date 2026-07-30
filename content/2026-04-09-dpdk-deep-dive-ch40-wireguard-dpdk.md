---
title: "DPDK 深度探索 ch40：WireGuard 加速——Noise Protocol、密钥推导与 DPDK 数据面实现"
date: 2026-04-10 15:30:00
tags:
  [
    dpdk,
    wireguard,
    noise-protocol,
    crypto,
    chacha20-poly1305,
    curve25519,
    vpn,
    graph-pipeline,
    cryptodev,
  ]
description: "从 DPDK 工程视角解析 WireGuard：Noise_IKpsk2 握手、CHAIN_KEY 密钥推导链、Cookie DoS 防护、密钥轮换、DPDK graph pipeline 加速架构与 cryptodev 卸载"
---

# DPDK 深度探索 ch40：WireGuard 加速——Noise Protocol、密钥推导与 DPDK 数据面实现

> [!info] 章节定位
> DPDK 深度探索系列 0. [[2026-04-09-dpdk-deep-dive-series-index|全栈学习路径总览]]
>
> 关联章节：
>
> - [[2026-04-09-dpdk-deep-dive-ch30-lookaside-crypto|Lookaside 加速——Cryptodev、QAT、IPsec]]
> - [[2026-04-09-dpdk-deep-dive-ch37-smartnic|SmartNIC 数据面——Representor、E-Switch 与硬件卸载]]
> - [[2026-04-09-dpdk-deep-dive-ch40-rdma-dpdk|RDMA 与 DPDK——RoCEv2、Verbs 与 Bifurcated Driver]]

> [!abstract] 核心结论
> WireGuard 是现代 VPN 协议的标杆，~4000 行代码实现了完整的加密隧道。
> 从 DPDK 工程视角来看：
>
> 1. **协议层**：基于 Noise_IKpsk2 模式，通过 3 次 ECDH（Curve25519）+ CHAIN_KEY 密钥链
>    推导出会话密钥，天然前向保密；
> 2. **加密层**：ChaCha20-Poly1305 AEAD 提供机密性+完整性，DPDK cryptodev 框架
>    可将加密卸载到 QAT/ISA-L/AESNI-MB 等硬件加速器；
> 3. **数据面加速**：通过 DPDK graph pipeline（`rte_graph`）将 WireGuard 拆分为
>    分类 → 头处理 → 加解密 → 转发 四个 node，单节点可达 **40 Gbps / 6.2 Mpps**；
> 4. **当前局限**：DPDK 上游尚未合并原生 WireGuard PMD，生产环境主要依赖
>    VPP WireGuard plugin 或自研 pipeline。

---

## 1. WireGuard 协议概述

### 1.1 WireGuard 是什么

WireGuard 是一种现代、简洁、高性能的 VPN 协议，2016 年由 Jason Donenfeld 发起，
2020 年合入 Linux 5.6 内核主线。其核心设计哲学是 **极简主义**：

```text
WireGuard 设计哲学：

┌──────────────────────────────────────────────────────────┐
│  简单 (Simple)                                            │
│  ├── ~4000 行内核代码 (vs OpenVPN ~100K, IPsec ~500K)     │
│  ├── 单一协议，单一端口 UDP 51820                           │
│  ├── 无路由协商、无时间协商、无状态机                        │
│  └── 配置即接口: wg0 + [Peer] + AllowedIPs                 │
│                                                              │
│  快速 (Fast)                                                │
│  ├── ChaCha20-Poly1305 (SIMD 加速)                         │
│  ├── Curve25519 ( Montgomery ladder)                         │
│  └── 内核零拷贝路径                                          │
│                                                              │
│  安全 (Secure)                                              │
│  ├── Noise_IKpsk2 (正式可证安全)                            │
│  ├── 完整前向保密 (每次握手 ~120s 轮换)                      │
│  ├── Cookie DoS 防护                                         │
│  └── 滑动窗口抗重放 (~2000 包窗口)                           │
│                                                              │
│  审计友好 (Audit-Friendly)                                  │
│  ├── 代码量小 → 完整审计可行                                  │
│  ├── 密码学原语少 → 攻击面小                                │
│  └── 无遗留兼容包袱                                          │
└──────────────────────────────────────────────────────────┘
```

### 1.2 与 OpenVPN / IPsec 对比

| 维度       | WireGuard         | OpenVPN                   | IPsec             |
| ---------- | ----------------- | ------------------------- | ----------------- | ------------------ |
| **代码量** | ~4,000 行         | ~100,000 行               | ~500,000 行       |
| **协议栈** | 单一 UDP 协议     | TLS + 自定义              | IKE + ESP/AH      |
| **端口**   | UDP 51820         | TCP/UDP 可变              | UDP 500 + ESP     |
| **加密**   | ChaCha20-Poly1305 | AES-256-GCM 等            | AES-CBC/GCM 等    |
| >          | **密钥交换**      | Curve25519 (Noise)        | RSA/ECDH (TLS)    | DH/ECDH (IKE)      |
| >          | **前向保密**      | ✅ 每次握手               | ✅ 可配置         | ✅ DHE 模式        |
| >          | **DoS 防护**      | Cookie 机制               | TLS 重协商        | IKEv2 Cookie       |
| >          | **MTU 开销**      | 80 字节 (UDP + WG header) | ~60 字节          | ~70 字节           |
| >          | **NAT 穿越**      | 原生 (UDP)                | 需配置            | 需 NAT-T           |
| >          | **配置复杂度**    | 极低 (一个 INI 文件)      | 高 (CA/证书/配置) | 极高 (SA/SPD 策略) |

### 1.3 WireGuard 架构全景

```text
WireGuard 架构分层：

┌─────────────────────────────────────────────────────────────┐
│                    用户应用层                               │
│         ping / ssh / curl / 应用流量                         │
├─────────────────────────────────────────────────────────────┤
│                    网络接口层                               │
│         wg0 (虚拟网络接口)                                   │
│         ├── AllowedIPs 路由表 (Cryptokey Routing)           │
│         └── 将匹配流量送入 WireGuard 处理                   │
├─────────────────────────────────────────────────────────────┤
│                    WireGuard 协议层                         │
│         ┌─────────────┐    ┌─────────────┐                │
│         │  握手管理    │    │  传输加解密   │                │
│         │  Noise_IK    │    │  ChaCha20-   │                │
│         │  Curve25519  │    │  Poly1305    │                │
│         │  Timer/Rekey │    │  Counter     │                │
│         └─────────────┘    └─────────────┘                │
├─────────────────────────────────────────────────────────────┤
│                    传输层                                   │
│         UDP 51820                                           │
├─────────────────────────────────────────────────────────────┤
│                    IP 网络层                                │
│         互联网 (任意 IP 网络)                               │
└─────────────────────────────────────────────────────────────┘

DPDK 加速场景下，协议层 + 传输层 + IP 网络层全部在用户态完成。
```

---

## 2. Noise Protocol Framework

### 2.1 Noise 框架概述

WireGuard 的握手协议基于 [Noise Protocol Framework](https://noiseprotocol.org/)，
一个经过形式化验证的密钥协商框架。Noise 的核心思想是：

```text
Noise Protocol 设计原则：

1. 模式驱动 (Pattern-Driven)
   - 用简洁的符号描述握手模式
   - 每个符号代表一次 DH 运算或密钥交换

2. 密码学敏捷性 (Crypto Agility)
   - 可替换底层原语 (Curve25519 → 其他曲线)
   - WireGuard 固定使用 Curve25519 + ChaCha20-Poly1305 + BLAKE2s
   - 不做协商 → 减少攻击面

3. 形式化安全证明 (Formal Security Proof)
   - 每个模式都有明确的安全模型
   - EuroS&P 2019 的独立审计证明 WireGuard 实现正确
```

### 2.2 Noise_IKpsk2 模式解析

WireGuard 使用 **Noise_IKpsk2** 模式。名称解码：

| 字符    | 含义                                           |
| ------- | ---------------------------------------------- |
| **I**   | Initiator 的静态公钥是**已知的**（预先配置）   |
| **K**   | Responder 的静态公钥也是**已知的**（预先配置） |
| **psk** | 握手中混入一个**预共享密钥 (Pre-Shared Key)**  |
| **2**   | PSK 在握手第二阶段（Response）混入             |

```text
Noise_IKpsk2 握手模式：

符号说明：
  →    : Initiator 发送
  ←    : Responder 发送
  e    : 生成并发送临时 (ephemeral) 公钥
  s    : 发送静态 (static) 公钥
  ee   : 两个临时公钥的 DH:  DH(e_i_priv, e_r_pub)
  se   : Initiator 临时 × Responder 静态: DH(e_i_priv, s_r_pub)
  es   : Responder 临时 × Initiator 静态: DH(e_r_priv, s_i_pub)

Initiator                              Responder
  │                                        │
  │  → e, se                               │
  │  发送临时公钥 e_i                        │
  │  DH(e_i_priv, s_r_pub) ← se            │
  │                                        │
  │            ← e, ee, s, es, psk        │
  │  发送临时公钥 e_r                        │
  │  DH(e_r_priv, e_i_pub) ← ee            │
  │  发送静态公钥 s_r（加密的）← s           │
  │  DH(e_r_priv, s_i_pub) ← es            │
  │  混入预共享密钥 ← psk                    │
  │                                        │
  │  ═══ transport data ═════════════════   │
  │  双向加密通信开始                         │
```

关键观察：

- **3 次 DH 运算**：`se`、`ee`、`es`，每次都混入 CHAIN_KEY
- **Initiator 不发送静态公钥明文**：静态公钥 s_i 在 Response 阶段
  才被 Responder 用 `es` 的密钥加密保护
- **PSK 提供额外保障**：即使 Curve25519 被破解，PSK 仍提供
  对称密钥层的安全

### 2.3 WireGuard 握手消息格式

```text
WireGuard 握手消息 1：Handshake Initiation (Type = 1)

┌──────────────────────────────────────────────────────────┐
│  Field           │  Size    │  Description                │
├──────────────────┼──────────┼─────────────────────────────┤
│  Type             │  4 B     │  消息类型 = 1                │
│  Sender           │  4 B     │  Initiator 的本地 index     │
│  Ephemeral        │  32 B    │  Initiator 临时公钥 e_i      │
│  Encrypted:       │  48 B    │  用 temp_key 加密:          │
│    ├─ Static       │  32 B   │    Initiator 静态公钥 s_i   │
│    ├─ Timestamp    │  12 B    │    TAIA64 时间戳            │
│    └─ Padding      │  4 B    │    随机填充                  │
│  MAC1             │  16 B    │  Responder 公钥的 MAC       │
│  MAC2             │  16 B    │  Cookie MAC (可选)          │
├──────────────────┼──────────┼─────────────────────────────┤
│  Total            │  148 B   │                            │
└──────────────────┴──────────┴─────────────────────────────┘

WireGuard 握手消息 2：Handshake Response (Type = 2)

┌──────────────────────────────────────────────────────────┐
│  Field           │  Size    │  Description                │
├──────────────────┼──────────┼─────────────────────────────┤
│  Type             │  4 B     │  消息类型 = 2                │
│  Sender           │  4 B     │  Responder 的本地 index      │
│  Receiver        │  4 B     │  Initiator 的 index (回显)  │
│  Ephemeral        │  32 B    │  Responder 临时公钥 e_r      │
│  Encrypted:       │  32 B    │  用 temp_key 加密:          │
│    ├─ Empty        │  0 B    │    无载荷 (空的)             │
│    └─ Padding      │  16 B    │    随机填充                  │
│  MAC1             │  16 B    │  Initiator 公钥的 MAC       │
│  MAC2             │  16 B    │  Cookie MAC (可选)          │
├──────────────────┼──────────┼─────────────────────────────┤
│  Total            │  124 B   │                            │
└──────────────────┴──────────┴─────────────────────────────┘

WireGuard 传输数据：Transport Data (Type = 4)

┌──────────────────────────────────────────────────────────┐
│  Field           │  Size    │  Description                │
├──────────────────┼──────────┼─────────────────────────────┤
│  Type             │  4 B     │  消息类型 = 4                │
│  Receiver        │  4 B     │  目标 peer 的 index           │
│  Counter         │  8 B     │  单调递增包序号               │
│  Encrypted:       │          │  ChaCha20-Poly1305 加密:     │
│    ├─ Inner IP    │  var     │    原始 IP 包                │
│    └─ Tag         │  16 B    │    Poly1305 认证标签         │
└──────────────────┴──────────┴─────────────────────────────┘

WireGuard Cookie Reply (Type = 3)

┌──────────────────────────────────────────────────────────┐
│  Field           │  Size    │  Description                │
├──────────────────┼──────────┼─────────────────────────────┤
│  Type             │  4 B     │  消息类型 = 3                │
│  Receiver        │  4 B     │  Initiator 的 index          │
│  Nonce           │  24 B    │  随机 nonce                   │
│  Cookie           │  32 B    │  加密的 cookie (XOR 伪装)     │
│  MAC1             │  16 B    │  Initiator 公钥的 MAC        │
├──────────────────┼──────────┼─────────────────────────────┤
│  Total            │  80 B    │                            │
└──────────────────┴──────────┴─────────────────────────────┘
```

---

## 3. 密钥推导：CHAIN_KEY 与 KDF

这是 WireGuard 安全性的核心。理解 CHAIN_KEY 的演化过程，
才能真正理解 WireGuard 为什么安全。

### 3.1 密钥推导函数 (KDF)

WireGuard 基于 **HMAC-BLAKE2s** 实现密钥推导（简化版 HKDF，RFC 5869），
定义了三个变体：

```text
KDF 定义：
  KDF1(K, input) → (new_K)              返回 1 个值：新 CHAIN_KEY
  KDF2(K, input) → (new_K, key1)         返回 2 个值：新 CHAIN_KEY + 一个密钥
  KDF3(K, input) → (new_K, key1, key2)   返回 3 个值：新 CHAIN_KEY + 两个密钥

实现原理：
  HMAC_K(input || 0x01) → new_K        (新的 CHAIN_KEY)
  HMAC_K(input || 0x02) → key1          (第一个密钥)
  HMAC_K(input || 0x03) → key2          (第二个密钥)
```

> **为什么不用标准 HKDF？** WireGuard 使用 BLAKE2s 替代 SHA-256，
> 减少一次 HMAC 调用。BLAKE2s 的 HMAC 等价于 `H(key || message)` 模式。

### 3.2 握手过程 CHAIN_KEY 演化

```text
CHAIN_KEY 演化全程（从初始化到传输密钥）：

阶段 0：初始化
────────────────
  hash      = BLAKE2s("Noise_IKpsk2_25519_ChaChaPoly_BLAKE2s")
  CHAIN_KEY = BLAKE2s(hash)

  ──→ CHAIN_KEY₀

阶段 1：Handshake Initiation (Initiator → Responder)
────────────────
  步骤 1: Initiator 生成临时密钥对 e_i
  ─────────────────────────────
  (CHAIN_KEY₁, temp_key₁) = KDF2(CHAIN_KEY₀, HASH(e_i.pub))

  步骤 2: 将 Initiator 静态公钥写入消息（用于后续 hash 追踪）
  ─────────────────────────────
  hash = HASH(hash || s_i.pub)

  步骤 3: 第一次 DH — DH(e_i.priv, s_r.pub) = se
  ─────────────────────────────
  (CHAIN_KEY₂, _) = KDF1(CHAIN_KEY₁, DH(e_i.priv, s_r.pub))

  使用 temp_key₁ 加密: [s_i.pub || timestamp || padding]
  ──→ 发送 Handshake Initiation
         ──→ CHAIN_KEY₂

阶段 2：Handshake Response (Responder → Initiator)
────────────────
  步骤 4: Responder 生成临时密钥对 e_r
  ─────────────────────────────
  hash = HASH(hash || e_r.pub)
  (CHAIN_KEY₃, temp_key₂) = KDF2(CHAIN_KEY₂, HASH(e_r.pub))

  步骤 5: 第二次 DH — DH(e_r.priv, s_i.pub) = es
  ─────────────────────────────
  (CHAIN_KEY₄, temp_key₃) = KDF2(CHAIN_KEY₃, DH(e_r.priv, s_i.pub))

  步骤 6: 第三次 DH — DH(e_r.priv, e_i.pub) = ee
  ─────────────────────────────
  (CHAIN_KEY₅, temp_key₄) = KDF2(CHAIN_KEY₄, DH(e_r.priv, e_i.pub))

  步骤 7: 混入预共享密钥 (PSK)
  ─────────────────────────────
  (CHAIN_KEY₆, temp_key₅) = KDF2(CHAIN_KEY₅, psk)

  使用 temp_key₅ 加密: [empty payload || padding]
  ──→ 发送 Handshake Response
         ──→ CHAIN_KEY₆

阶段 3：推导传输密钥
────────────────
  (CHAIN_KEY_final, send_key, recv_key) = KDF3(CHAIN_KEY₆, "")

  Initiator 视角:
    send_key → 用于加密发送的数据
    recv_key → 用于解密接收的数据

  Responder 视角 (对称互换):
    send_key → 用于加密发送的数据
    recv_key → 用于解密接收的数据
```

### 3.3 CHAIN_KEY 的安全保证

```text
CHAIN_KEY 安全特性：

密钥隔离 (Key Separation)
┌──────────────────────────────────────────────────────────┐
│  CHAIN_KEY₀                                              │
│     │ KDF(+DH_se)                                          │
│     ▼                                                     │
│  CHAIN_KEY₁                                              │
│     │ KDF(+DH_es)                                          │
│     ▼                                                     │
│  CHAIN_KEY₂                                              │
│     │ KDF(+DH_ee)                                          │
│     ▼                                                     │
│  CHAIN_KEY₃                                              │
│     │ KDF(+PSK)                                            │
│     ▼                                                     │
│  CHAIN_KEY_final → KDF3 → (send_key, recv_key)           │
│                                                            │
│  每个 DH 的输出都通过 HMAC 链混入，                         │
│  任何一个 DH 结果都无法单独控制最终密钥。                      │
└──────────────────────────────────────────────────────────┘

完整前向保密 (Perfect Forward Secrecy)
  - e_i / e_r 每次握手随机生成，用完即弃
  - 即使静态私钥泄露，历史会话密钥仍然安全
  - 3 次 ECDH + PSK 双重保障

抗密钥泄露假想 (Post-Compromise Security)
  - 如果静态私钥泄露，只要 PSK 未泄露
  - 攻击者无法解密 PSK 混入之前的通信
  - 后续握手会自动恢复安全性（新临时密钥）
```

---

## 4. 加密原语

### 4.1 ChaCha20-Poly1305 AEAD

```text
ChaCha20-Poly1305 组合：

┌──────────────────────────────────────────────────────────┐
│  ChaCha20 (流加密)                                        │
│  ├── 256-bit 密钥                                         │
│  ├── 96-bit nonce (12 字节)                              │
│  │     └── WireGuard 中: 4 B zero padding + 8 B counter │
│  ├── 20 rounds (8 quarter-rounds × 2 + diagonal)         │
│  └── 输出: 与明文等长的密钥流，XOR 即完成加密              │
│                                                            │
│  Poly1305 (消息认证码)                                     │
│  ├── 128-bit tag (16 字节)                                │
│  ├── One-time key (从 ChaCha20 前 64 字节派生)            │
│  └── 覆盖: AD (可选) + ciphertext                         │
│                                                            │
│  AEAD 组合:                                               │
│  1. ChaCha20(key, nonce, counter=0) → poly_key (前32字节)  │
│  2. ChaCha20(key, nonce, counter=1) → keystream           │
│  3. plaintext XOR keystream → ciphertext                  │
│  4. Poly1305(poly_key, AD || ciphertext) → tag            │
│  5. 输出: ciphertext || tag                               │
└──────────────────────────────────────────────────────────┘
```

### 4.2 ChaCha20 核心实现

```c
/* ChaCha20 Quarter Round — 4 个 32-bit 字的混合 */
static inline void
chacha20_quarter_round(uint32_t *a, uint32_t *b,
                        uint32_t *c, uint32_t *d)
{
    *a += *b; *d ^= *a; *d = ROTL32(*d, 16);
    *c += *d; *b ^= *c; *b = ROTL32(*b, 12);
    *a += *b; *d ^= *a; *d = ROTL32(*d, 8);
    *c += *d; *b ^= *c; *b = ROTL32(*b, 7);
}

/* ChaCha20 Block — 生成 64 字节密钥流 */
static void
chacha20_block(uint32_t state[16], uint8_t output[64])
{
    uint32_t working[16];
    memcpy(working, state, 64);

    /* 20 rounds = 10 iterations (奇数: column, 偶数: diagonal) */
    for (int i = 0; i < 10; i++) {
        /* Column round */
        chacha20_quarter_round(&working[0], &working[4],
                               &working[8],  &working[12]);
        chacha20_quarter_round(&working[1], &working[5],
                               &working[9],  &working[13]);
        chacha20_quarter_round(&working[2], &working[6],
                               &working[10], &working[14]);
        chacha20_quarter_round(&working[3], &working[7],
                               &working[11], &working[15]);
        /* Diagonal round */
        chacha20_quarter_round(&working[0], &working[5],
                               &working[10], &working[15]);
        chacha20_quarter_round(&working[1], &working[6],
                               &working[11], &working[12]);
        chacha20_quarter_round(&working[2], &working[7],
                               &working[8],  &working[13]);
        chacha20_quarter_round(&working[3], &working[4],
                               &working[9],  &working[14]);
    }

    /* state += working (add original state back) */
    for (int i = 0; i < 16; i++) {
        uint32_t val = state[i] + working[i];
        memcpy(output + i * 4, &val, 4);
    }
}

/*
 * 初始 state 布局 (32 字节):
 *   state[0..3]  = "expand 32-byte k" (常量)
 *   state[4..11] = 256-bit key
 *   state[12]    = counter (low 32 bits)
 *   state[13]    = counter (high 32 bits, WireGuard 中为 0)
 *   state[14..15] = nonce (96-bit, 占 2 个 word)
 *
 * WireGuard nonce 构造:
 *   [0x00 0x00 0x00 0x00] || counter (8 bytes)
 *   前 4 字节为零，后 8 字节为 packet counter
 */
```

### 4.3 Curve25519 密钥交换

```c
#include <sodium.h>

/*
 * Curve25519 (X25519) — Montgomery 椭圆曲线 Diffie-Hellman
 *
 * 为什么选 Curve25519 而不是 NIST P-256：
 * 1. 常量时间: Montgomery ladder 天然抗时序攻击
 * 2. 无特殊点: P-256 有 cofactor 问题，Curve25519 cofactor=8 但安全
 * 3. 速度快: 比 P-256 快约 2-3x
 * 4. 侧信道安全: 设计目标之一就是抗侧信道
 */

/* 生成 Curve25519 密钥对 */
int
wg_generate_keypair(uint8_t public_key[32], uint8_t private_key[32])
{
    /* 随机生成 32 字节私钥 */
    randombytes_buf(private_key, 32);

    /* Clamp: 强制满足 Curve25519 要求 */
    private_key[0]  &= 248;   /* 清除低 3 位 */
    private_key[31] &= 127;   /* 清除最高位 */
    private_key[31] |= 64;    /* 设置次高位 */

    /* 计算公钥: scalar multiplication of base point */
    crypto_scalarmult_base(public_key, private_key);

    return 0;
}

/* 共享密钥计算: DH(priv, peer_pub) → shared_secret */
int
wg_compute_shared_secret(uint8_t shared[32],
                         const uint8_t private_key[32],
                         const uint8_t peer_public[32])
{
    int rc = crypto_scalarmult(shared, private_key, peer_public);
    if (rc != 0) {
        /* 全零结果意味着对方公钥无效 (小阶元素) */
        return -1;
    }
    return 0;
}
```

### 4.4 AEAD 加密封装

```c
/*
 * WireGuard AEAD 加密
 *
 * nonce 构造 (12 字节):
 *   [0x00 0x00 0x00 0x00] || packet_counter (8 bytes big-endian)
 *
 * AD (Additional Data): 无
 *   WireGuard 传输数据不使用 AD，认证仅覆盖密文 + tag
 */
int
wg_aead_encrypt(uint8_t *dst, const uint8_t *src, size_t src_len,
                const uint8_t key[32], uint64_t counter)
{
    /* 构造 12 字节 nonce */
    uint8_t nonce[12] = {0};
    rte_memcpy(nonce + 4, &counter, 8);  /* big-endian counter */

    /* 加密 + 认证 (输出 = ciphertext || tag) */
    int ret = crypto_aead_chacha20poly1305_ietf_encrypt(
        dst, &out_len,
        src, src_len,       /* plaintext */
        NULL, 0,             /* no AD */
        NULL,                /* no secret nonce */
        nonce, key);

    /* 返回 src_len + 16 (tag) */
    return src_len + 16;
}

/*
 * WireGuard AEAD 解密
 * 返回 0 成功，-1 失败 (tag 不匹配或密钥错误)
 */
int
wg_aead_decrypt(uint8_t *dst, const uint8_t *src, size_t src_len,
                const uint8_t key[32], uint64_t counter)
{
    if (src_len < 16) return -1;  /* 至少要有 tag */

    uint8_t nonce[12] = {0};
    rte_memcpy(nonce + 4, &counter, 8);

    return crypto_aead_chacha20poly1305_ietf_decrypt(
        dst, &out_len,
        NULL, 0,
        src, src_len,
        NULL, nonce, key);
}
```

---

## 5. WireGuard 关键机制

### 5.1 Cryptokey Routing（AllowedIPs）

WireGuard 不使用传统路由协议协商隧道，而是用 **Cryptokey Routing**：

```text
Cryptokey Routing 原理：

核心概念：每个 Peer 绑定一组 AllowedIPs，
         出站流量根据目标 IP 查找 Peer，
         入站流量根据源 IP 验证 Peer。

配置示例：
┌──────────────────────────────────────────────────────────┐
│  [Interface]                                               │
│  PrivateKey = <server_private_key>                        │
│  Address = 10.0.0.1/24                                    │
│  ListenPort = 51820                                        │
│                                                            │
│  [Peer]                                                    │
│  PublicKey = <peer_a_public_key>                           │
│  AllowedIPs = 10.0.0.2/32    ← Peer A 的隧道 IP             │
│  Endpoint = 203.0.113.1:51820                               │
│                                                            │
│  [Peer]                                                    │
│  PublicKey = <peer_b_public_key>                           │
│  AllowedIPs = 10.0.0.3/32    ← Peer B 的隧道 IP             │
│              192.168.100.0/24 ← Peer B 后面的子网            │
│  Endpoint = 198.51.100.1:51820                              │
└──────────────────────────────────────────────────────────┘

路由查找：
  目标 10.0.0.2    → 匹配 Peer A → 用 Peer A 的会话密钥加密
  目标 10.0.0.3    → 匹配 Peer B → 用 Peer B 的会话密钥加密
  目标 192.168.100.5 → 匹配 Peer B → 转发到 Peer B
  目标 8.8.8.8     → 无匹配     → 不走 WireGuard，走正常路由

DPDK 实现中，AllowedIPs 查找使用 rte_lpm (IPv4) 或 rte_lpm6 (IPv6)。
```

### 5.2 Cookie DoS 防护

WireGuard 通过 **MAC1 + MAC2 + Cookie** 三层机制防御 DoS 攻击：

```text
DoS 防护机制：

┌──────────────────────────────────────────────────────────┐
│  第一层：MAC1 — 廉价过滤 (始终检查)                        │
│  ├── 用 Responder 静态公钥派生的 MAC key 计算消息认证码     │
│  ├── 验证成本: 一次 BLAKE2s (~几 ns)                       │
│  ├── 失败: 静默丢弃，不创建任何状态                         │
│  └── 通过: 继续下一步                                      │
│                                                            │
│  第二层：速率检测 (仅 Responder 端)                         │
│  ├── 跟踪最近的握手 initiation 速率                         │
│  ├── 超过阈值 → 进入 "under load" 模式                     │
│  └── 正常运行时不要求 Cookie                                │
│                                                            │
│  第三层：MAC2 + Cookie — 可信证明 (仅 under load 时检查)   │
│  ├── Responder 发送 Cookie Reply (Type 3)                  │
│  │   - Cookie = MAC(Initiator_IP, changing_secret)          │
│  │   - 用 Initiator 公钥加密，只有合法持有者能使用           │
│  ├── Cookie 有效期: 2 分钟                                 │
│  ├── changing_secret 每 2 分钟轮换                          │
│  └── Initiator 重发请求时带上有效 MAC2 → 通过验证            │
└──────────────────────────────────────────────────────────┘

握手流程 (DoS 场景)：

  Initiator                        Responder
    │                                  │
    │  Handshake Init + MAC1           │
    │ ──────────────────────────────▶  │
    │                                  │ (under load 检测)
    │  Cookie Reply (Type 3)           │
    │ ◀──────────────────────────────  │
    │                                  │
    │  Handshake Init + MAC1 + MAC2    │
    │ ──────────────────────────────▶  │
    │                                  │ (MAC2 验证通过)
    │  Handshake Response              │
    │ ◀──────────────────────────────  │
    │                                  │
```

### 5.3 密钥轮换与定时器

```text
WireGuard 定时器体系：

┌──────────┬──────────────┬───────────────────────────────────┐
│  常量      │  值          │  作用                               │
├──────────┼──────────────┼───────────────────────────────────┤
│ REKEY    │ ~120 秒       │  主动流量下，每 ~120s 发起新握手     │
│ _AFTER   │              │  推导新的传输密钥                    │
│ _TIME    │              │                                    │
├──────────┼──────────────┼───────────────────────────────────┤
│ REKEY    │ 2^64-2^16-1  │  单个密钥对可加密的最大消息数          │
│ _AFTER   │ (~1.84×10¹⁹) │  实际中时间触发先到                   │
│ _MESSAGES│              │                                    │
├──────────┼──────────────┼───────────────────────────────────┤
│ REJECT   │ 180 秒       │  绝对截止时间                       │
│ _AFTER   │              │  180s 内无有效握手 → 会话硬拒绝       │
│ _TIME    │              │  必须完全重新建立                     │
├──────────┼──────────────┼───────────────────────────────────┤
│ REKEY    │ 5 秒         │  握手无响应重试间隔                  │
│ _TIMEOUT │ + jitter     │  含随机抖动，指数退避                │
├──────────┼──────────────┼───────────────────────────────────┤
│ KEEPALIVE│ 10 秒         │  PersistentKeepalive 间隔          │
│ _INTERVAL│              │  防止 NAT 映射过期                   │
├──────────┼──────────────┼───────────────────────────────────┤
│ COOKIE   │ 120 秒       │  Cookie 密钥轮换间隔                 │
│ _REFRESH │              │                                    │
└──────────┴──────────────┴───────────────────────────────────┘

密钥轮换时序：

  Time:  0s ───── 120s ───── 240s ───── 360s
         │  Session 1 │  Session 2 │  Session 3  │
         │            │  (rekey)    │  (rekey)    │
         │            │             │             │
         │  reject 截止线在 180s:                        │
         │  如果 Session 1 的 Response 丢失，            │
         │  180s 后 Session 1 被硬拒绝                   │

  Transport 阶段密钥更新：
    每发送/接收一个包:
      CHAIN_KEY = KDF1(CHAIN_KEY, "")
      → 产生新的 per-packet 加密密钥
      → 即使包 counter 被猜到，密钥也不同
```

### 5.4 抗重放：滑动窗口

```text
滑动窗口抗重放机制：

基本原理:
  每个传输包携带 64-bit 单调递增 counter
  接收端维护:
    - greatest_counter: 历史最大 counter
    - bitmap: ~2000 个 bit，记录窗口内的已接收 counter

验证算法:
  收到 packet with counter N:
  ┌──────────────────────────────────────────────────────┐
  │  if N > greatest_counter:                             │
  │      ACCEPT                                          │
  │      greatest_counter = N                             │
  │      滑动窗口右移                                     │
  │                                                       │
  │  elif (greatest_counter - 2000) < N <= greatest_counter:│
  │      if N 未在 bitmap 中:                              │
  │          ACCEPT, 标记 bitmap[N]                       │
  │      else:                                            │
  │          REJECT (重放攻击)                             │
  │                                                       │
  │  else:  // N 太旧，超出窗口                            │
  │      REJECT                                           │
  └──────────────────────────────────────────────────────┘

为什么选 ~2000？
  - 容忍合理的 UDP 包乱序（多路径路由、网络拥塞）
  - 窗口外的包太旧，重放概率极低
  - 每次密钥轮换 (~120s) counter 归零，窗口自动重置

双重保护:
  1. Counter + 滑动窗口 → 同一会话内的抗重放
  2. 密钥轮换 (~120s) → 跨会话的抗重放（旧密钥已失效）
```

---

## 6. DPDK WireGuard 实现

### 6.1 实现路线概述

DPDK 上游目前**没有原生的 WireGuard PMD**。生产环境有三种主流实现路径：

```text
DPDK WireGuard 实现路线：

路线 1: DPDK graph pipeline（自研）
├── 基于 rte_graph 将 WireGuard 拆分为多个 node
├── 加密通过 rte_cryptodev 卸载（软件或硬件）
├── 代表: MDPI 2024 论文，TikTok VPN 框架
└── 性能: ~40 Gbps / 6.2 Mpps（软件加密）

路线 2: VPP WireGuard plugin
├── VPP 作为 packet processing framework
├── WireGuard 作为 VPP graph node
├── 加密通过 VPP crypto node → DPDK cryptodev → QAT
├── 代表: Intel Builders Guide, slowbootkernelhacks
└── 性能: ~100 Gbps（QAT 硬件加速 ChaCha20）

路线 3: 混合模式 (KNI/netlink)
├── 数据面: DPDK 处理传输加密/解密
├── 控制面: 内核 WireGuard 模块处理握手
├── 通过 KNI 或 netlink 与内核交互
└── 优势: 复用内核成熟的握手实现，减少开发量

本章重点讲解路线 1 的架构设计。
```

### 6.2 graph pipeline 架构

```text
DPDK graph pipeline WireGuard 架构:

┌──────────────────────────────────────────────────────────┐
│                     Application                          │
├──────────────────────────────────────────────────────────┤
│                 rte_graph Pipeline                       │
│                                                            │
│  ┌───────────┐  ┌───────────┐  ┌───────────┐  ┌────────┐│
│  │ eth_rx    │  │ wg_classify│  │ wg_decrypt │  │ ip_fwd ││
│  │ node      │→│ node       │→│ node       │→│ node   ││
│  │           │  │           │  │           │  │        ││
│  │ NIC PMD   │  │ UDP 51820?│  │ ChaCha20-  │  │ FIB    ││
│  │ rx_burst  │  │ parse hdr  │  │ Poly1305  │  │ lookup ││
│  │           │  │ peer lookup│  │ counter    │  │ route  ││
│  │           │  │           │  │ verify     │  │        ││
│  └───────────┘  └───────────┘  └─────┬─────┘  └───┬────┘│
│                                       │            │      │
│  ┌───────────┐  ┌───────────┐  ┌─────▼─────┐  ┌───▼────┐│
│  │ eth_tx    │  │ wg_encrypt │  │ crypto_dev │  │ eth_tx ││
│  │ node      │←│ node       │←│ enqueue   │←│ node   ││
│  │           │  │           │  │           │  │        ││
│  │ NIC PMD   │  │ prepend    │  │ AESNI-MB  │  │ NIC    ││
│  │ tx_burst  │  │ wg header  │  │ QAT       │  │ PMD    ││
│  │           │  │ ChaCha20   │  │ or SW     │  │        ││
│  └───────────┘  └───────────┘  └───────────┘  └────────┘│
│                                                            │
├──────────────────────────────────────────────────────────┤
│                 DPDK Libraries                            │
│  rte_mbuf | rte_ring | rte_hash | rte_graph | rte_cryptodev│
└──────────────────────────────────────────────────────────┘
```

### 6.3 WireGuard 设备与 Peer 数据结构

```c
/* WireGuard 设备 — 对应一个 wg0 接口 */
struct wg_device {
    uint16_t            port_id;        /* DPDK 端口 */

    /* 密钥对 */
    uint8_t             private_key[32]; /* Curve25519 私钥 */
    uint8_t             public_key[32];  /* Curve25519 公钥 */

    /* Peer 表 — 用 rte_hash 存储 */
    struct rte_hash     *peer_table;    /* public_key → peer */
    struct wg_peer      **peers;
    uint32_t            num_peers;

    /* AllowedIPs 路由 — 用 rte_lpm 存储 */
    struct rte_lpm      *lpm_v4;        /* IPv4 AllowedIPs */
    struct rte_lpm6     *lpm_v6;        /* IPv6 AllowedIPs */

    /* index 分配器 */
    uint32_t            next_index;

    /* Cookie 保护 */
    uint8_t             cookie_secret[32];
    uint64_t            cookie_birth;   /* secret 生成时间 */
};

/* WireGuard Peer — 对应配置中的一个 [Peer] */
struct wg_peer {
    uint32_t            index;          /* 本地 index */
    uint8_t             public_key[32]; /* Peer 公钥 */
    uint8_t             preshared_key[32]; /* PSK (可选) */

    /* 端点 */
    uint32_t            endpoint_ip;
    uint16_t            endpoint_port;

    /* 当前会话密钥 (双向) */
    struct wg_session {
        uint8_t         send_key[32];   /* 发送方向密钥 */
        uint8_t         recv_key[32];   /* 接收方向密钥 */
        uint64_t        send_counter;   /* 发送计数器 */
        uint64_t        recv_counter;   /* 接收计数器 (greatest) */
        uint64_t        *recv_bitmap;   /* ~2000 bit 滑动窗口 */
        uint64_t        session_birth;  /* 会话创建时间 */
        int             is_valid;       /* 会话是否有效 */
    } session;

    /* 对称密钥: Initiator/Responder 视角互换 */
    /* 本端作为 Initiator 时 send_key = Ci, recv_key = Cr */
    /* 本端作为 Responder 时 send_key = Cr, recv_key = Ci */
};
```

### 6.4 入站处理（解密路径）

```c
/*
 * WireGuard 入站处理 — graph node 实现
 *
 * 处理流程:
 *   1. 解析 WG header → 获取 type, receiver index
 *   2. 根据 type 分发: handshake vs transport
 *   3. 传输数据: 验证 counter → 解密 → 转发
 */
static uint16_t
wg_rx_node_process(struct rte_graph *graph,
                   struct rte_node *node,
                   void **objs, uint16_t nb_objs)
{
    struct rte_mbuf **pkts = (struct rte_mbuf **)objs;

    for (uint16_t i = 0; i < nb_objs; i++) {
        struct rte_mbuf *pkt = pkts[i];
        struct wg_header *hdr = rte_pktmbuf_mtod(pkt, struct wg_header *);

        uint32_t type = rte_be_to_cpu_32(hdr->type);
        uint32_t receiver = rte_be_to_cpu_32(hdr->receiver);

        switch (type) {
        case WG_MSG_HANDSHAKE_INIT:
            /* 握手包 → 交给控制面处理 (通常非 graph 路径) */
            wg_handshake_enqueue(pkt);
            break;

        case WG_MSG_HANDSHAKE_RESP:
            wg_handshake_enqueue(pkt);
            break;

        case WG_MSG_TRANSPORT_DATA:
            if (wg_decrypt_and_forward(pkt, receiver) != 0) {
                /* 解密失败 / 重放 / 认证失败 → 丢弃 */
                rte_pktmbuf_free(pkt);
            }
            break;

        default:
            rte_pktmbuf_free(pkt);
        }
    }

    return nb_objs;
}

/*
 * 传输数据解密
 */
static int
wg_decrypt_and_forward(struct rte_mbuf *mbuf, uint32_t receiver_idx)
{
    struct wg_device *wg = /* ... */;

    /* 1. 查找 peer */
    struct wg_peer *peer = wg_find_peer_by_index(wg, receiver_idx);
    if (!peer || !peer->session.is_valid)
        return -1;

    /* 2. 解析传输头 */
    struct wg_transport_hdr *thdr =
        rte_pktmbuf_mtod(mbuf, struct wg_transport_hdr *);
    uint64_t counter = rte_be_to_cpu_64(thdr->counter);

    /* 3. 抗重放检查: 滑动窗口 */
    if (!wg_replay_check(&peer->session, counter))
        return -1;

    /* 4. 解密: 去掉 WG header → 剩余为 ciphertext + tag */
    uint8_t *ciphertext = (uint8_t *)(thdr + 1);
    size_t cipher_len = rte_pktmbuf_data_len(mbuf)
                        - sizeof(struct wg_transport_hdr);

    /*
     * 5. 提交到 cryptodev (异步)
     *    或直接调用软件解密 (同步)
     */
    int ret = crypto_aead_chacha20poly1305_ietf_decrypt(
        ciphertext,          /* plaintext 输出 (原地解密) */
        ciphertext,          /* ciphertext 输入 */
        cipher_len,          /* length (包含 tag) */
        NULL, 0,             /* no AD */
        mbuf,                /* nonce 从 header 构造 */
        peer->session.recv_key);

    if (ret != 0) {
        /* Poly1305 tag 验证失败 */
        return -1;
    }

    /* 6. 更新 counter 和 bitmap */
    wg_replay_advance(&peer->session, counter);

    /* 7. 去掉 WG 传输头，暴露内层 IP 包 */
    rte_pktmbuf_adj(mbuf, sizeof(struct wg_transport_hdr));
    /* 去掉 Poly1305 tag (16 bytes) */
    rte_pktmbuf_trim(mbuf, 16);

    /* 8. 送入 IP 转发 node */
    /* ... */

    return 0;
}
```

### 6.5 出站处理（加密路径）

```c
/*
 * WireGuard 出站处理 — graph node 实现
 *
 * 处理流程:
 *   1. 查目标 IP 的 AllowedIPs → 找到 peer
 *   2. 构造 WG 传输头 (type=4, receiver, counter)
 *   3. 加密内层 IP 包
 *   4. 封装 UDP + IP → 送入 tx node
 */
static uint16_t
wg_tx_node_process(struct rte_graph *graph,
                   struct rte_node *node,
                   void **objs, uint16_t nb_objs)
{
    struct rte_mbuf **pkts = (struct rte_mbuf **)objs;

    for (uint16_t i = 0; i < nb_objs; i++) {
        struct rte_mbuf *pkt = pkts[i];

        if (wg_encrypt_and_send(pkt) != 0)
            rte_pktmbuf_free(pkt);
    }

    return nb_objs;
}

static int
wg_encrypt_and_send(struct rte_mbuf *mbuf)
{
    struct wg_device *wg = /* ... */;
    struct ipv4_hdr *iph = rte_pktmbuf_mtod(mbuf, struct ipv4_hdr *);

    /* 1. AllowedIPs 路由查找 → 找到目标 peer */
    struct wg_peer *peer = wg_route_lookup(wg, iph->dst_addr);
    if (!peer || !peer->session.is_valid)
        return -1;

    /* 2. 检查会话是否过期 */
    if (wg_session_expired(&peer->session)) {
        /* 触发 rekey */
        wg_initiate_handshake(wg, peer);
        return -1;  /* 本包丢弃，等待新会话建立 */
    }

    /* 3. 预分配空间: WG transport header (16B) + Poly1305 tag (16B) */
    if (rte_pktmbuf_prepend(mbuf,
            sizeof(struct wg_transport_hdr) + 16) == NULL)
        return -1;

    /* 4. 填充 WG 传输头 */
    struct wg_transport_hdr *thdr =
        rte_pktmbuf_mtod(mbuf, struct wg_transport_hdr *);
    thdr->type = rte_cpu_to_be_32(WG_MSG_TRANSPORT_DATA);
    thdr->receiver = rte_cpu_to_be_32(peer->index);
    thdr->counter = rte_cpu_to_be_64(peer->session.send_counter);

    uint8_t *plaintext = (uint8_t *)(thdr + 1);
    size_t plain_len = rte_pktmbuf_data_len(mbuf)
                       - sizeof(struct wg_transport_hdr) - 16;

    /* 5. 加密 (原地: plaintext → ciphertext + tag) */
    int ret = crypto_aead_chacha20poly1305_ietf_encrypt(
        plaintext,          /* ciphertext 输出 */
        plaintext,          /* plaintext 输入 */
        plain_len,          /* 明文长度 */
        NULL, 0,             /* no AD */
        NULL,                /* no secret nonce */
        /* nonce 从 counter 构造: [0x00×4 || counter BE] */
        peer->session.send_key);

    if (ret != 0)
        return -1;

    /* 6. 更新发送计数器 */
    peer->session.send_counter++;

    /* 7. 外层封装: 添加 UDP(51820) + IP header → eth_tx node */
    wg_encapsulate(mbuf, peer);

    return 0;
}
```

### 6.6 cryptodev 加速集成

```c
/*
 * DPDK cryptodev 集成 WireGuard 的关键配置
 *
 * WireGuard 需要:
 *   - ChaCha20-Poly1305 IETF (AEAD)
 *   - Curve25519 (非对称密钥交换，仅握手时使用)
 *
 * 支持的 cryptodev PMD:
 *   - AESNI-MB (Intel): ChaCha20 + Poly1305 VPCLMULQDQ 加速
 *   - QAT (Intel QuickAssist): 硬件卸载 ChaCha20-Poly1305
 *   - OCTEON TXT (Marvell): 硬件加速
 *   - OpenSSL SW (通用): 纯软件后备
 */
static int
wg_crypto_dev_init(struct wg_device *wg)
{
    uint8_t cdev_id;
    struct rte_cryptodev_info dev_info;

    /* 查找支持 ChaCha20-Poly1305 的设备 */
    cdev_id = rte_cryptodev_find_dev(
        RTE_CRYPTO_AEAD_CHACHA20_POLY1305);

    if (cdev_id == RTE_CDEV_ID_INVALID) {
        /* 后备: 创建软件 cryptodev (OpenSSL) */
        rte_vdev_init("crypto_openssl", NULL);
        cdev_id = rte_cryptodev_find_dev(
            RTE_CRYPTO_AEAD_CHACHA20_POLY1305);
    }

    rte_cryptodev_info_get(cdev_id, &dev_info);

    /* 配置 queue pair */
    struct rte_cryptodev_config conf = {
        .nb_queue_pairs = 1,
        .socket_id = rte_socket_id(),
    };
    rte_cryptodev_configure(cdev_id, &conf);

    /* 设置 session mempool */
    struct rte_cryptodev_qp_conf qp_conf = {
        .nb_descriptors = 2048,
        .mp_session = rte_cryptodev_sym_session_pool_create(
            "wg_sess_mp", 256, 0, 0, SOCKET_ID_ANY),
    };

    rte_cryptodev_queue_pair_setup(cdev_id, 0, &qp_conf,
        rte_cryptodev_socket_id(cdev_id));
    rte_cryptodev_start(cdev_id);

    /* 预创建 AEAD session (避免 per-packet 开销) */
    struct rte_crypto_sym_xform aead_xform = {
        .type = RTE_CRYPTO_SYM_XFORM_AEAD,
        .aead = {
            .algo = RTE_CRYPTO_AEAD_CHACHA20_POLY1305,
            .op = RTE_CRYPTO_AEAD_OP_ENCRYPT,
            .key.length = 32,
            .iv.length = 12,
            .digest_length = 16,
        },
    };

    wg->crypto_session = rte_cryptodev_sym_session_create(
        wg->session_pool, &aead_xform, cdev_id);

    return 0;
}

/*
 * 批量加密 — 使用 rte_crypto_op 队列
 * 一次提交多个包的加密操作，cryptodev PMD 批量处理
 */
static uint16_t
wg_encrypt_batch(struct rte_mbuf **mbufs, uint16_t nb_pkts,
                 struct wg_peer *peer)
{
    struct rte_crypto_op *ops[nb_pkts];
    /* 填充 op → 提交 cryptodev → 轮询完成 → 回收 mbufs */
    /* ... 具体实现依赖 rte_cryptodev_enqueue_burst */
    return processed;
}
```

---

## 7. 性能对比与优化

### 7.1 各实现性能数据

| 实现方案                      | 吞吐量    | 包速率    | 加密方式      | CPU 利用率     |
| ----------------------------- | --------- | --------- | ------------- | -------------- |
| **内核 WireGuard**            | 5-10 Gbps | ~1 Mpps   | 软件加密      | ~30% (4 cores) |
| **DPDK graph + SW crypto**    | ~40 Gbps  | ~6.2 Mpps | 软件 ChaCha20 | ~80% (单核)    |
| **VPP + DPDK + QAT**          | ~100 Gbps | ~15 Mpps  | QAT 硬件加速  | ~40%           |
| **DPDK + AESNI-MB**           | ~50 Gbps  | ~8 Mpps   | SIMD 指令加速 | ~60%           |
| **IPsec (AES-128-GCM, 硬件)** | ~100 Gbps | ~15 Mpps  | NIC 硬件卸载  | ~20%           |

> **数据来源**: MDPI Electronics 2024 论文、Intel Builders Guide、社区基准测试。

### 7.2 性能瓶颈分析

```text
WireGuard 数据面性能瓶颈:

┌──────────────────────────────────────────────────────────┐
│  瓶颈 1: ChaCha20 加密 (最大开销)                           │
│  ├── ChaCha20 比 AES-GCM 慢约 2-3x (无 NIC 硬件卸载)     │
│  ├── AES-GCM 有 NIC 内置的 IPSec/SSL 卸载                  │
│  └── 优化: QAT 卸载 / AESNI-MB SIMD / AVX-512             │
│                                                            │
│  瓶颈 2: 密钥轮换开销                                       │
│  ├── 每 ~120s 需要新握手 → 3 次 ECDH (Curve25519)          │
│  ├── Curve25519 计算约 100μs/次 × 3 = 300μs               │
│  └── 占比极低 (<0.01%)，不影响数据面吞吐                   │
│                                                            │
│  瓶颈 3: 抗重放检查                                         │
│  ├── 每包需要 bitmap 查找和更新                             │
│  ├── 64-bit counter 比较操作很快                           │
│  └── 可用 rte_bitmap 批量处理                               │
│                                                            │
│  瓶颈 4: AllowedIPs 路由查找                                │
│  ├── rte_lpm 查找约 10ns/rule                              │
│  ├── Peer 数量通常较少 (< 1000)                            │
│  └── 不是主要瓶颈                                          │
│                                                            │
│  瓶颈 5: mbuf 操作 (header prepend/adj)                   │
│  ├── 加密出站: prepend 32B (header + tag)                  │
│  ├── 解密入站: adj + trim 32B                              │
│  └── 零拷贝设计下影响极小                                   │
└──────────────────────────────────────────────────────────┘
```

### 7.3 DPDK 优化策略

| 优化点       | 策略                                        | 效果                                                 |
| ------------ | ------------------------------------------- | ---------------------------------------------------- | --------------------- |
| **批量加密** | 使用 `rte_cryptodev_enqueue_burst` 批量提交 | 提高 IPC，减少 per-op 开销                           |
| >            | **会话复用**                                | 预创建 `rte_crypto_sym_session`，per-packet 直接使用 | 避免每包创建 session  |
| >            | **SIMD 加速**                               | 使用 AESNI-MB PMD 的 ChaCha20 实现 (VPCLMULQDQ)      | 单核加密吞吐提升 3-5x |
| >            | **零拷贝**                                  | 原地加密解密，避免 `rte_pktmbuf_copy`                | 减少 memcpy 开销      |
| >            | **NUMA 感知**                               | mbuf pool 和 cryptodev 在同一 NUMA node              | 减少跨 NUMA 访问      |
| >            | **握手分离**                                | 握手处理在独立线程/核心，不影响数据面                | 避免握手阻塞转发路径  |
| >            | **QAT 卸载**                                | ChaCha20-Poly1305 卸载到 Intel QAT                   | CPU 释放，吞吐翻倍    |

---

## 8. WireGuard vs IPsec in DPDK

### 8.1 协议层面对比

| 维度         | WireGuard                | IPsec (ESP)                             |
| ------------ | ------------------------ | --------------------------------------- | ---------------------------------- |
| **加密算法** | ChaCha20-Poly1305 (固定) | AES-CBC/GCM, ChaCha20-Poly1305 (可协商) |
| **密钥交换** | Curve25519 (Noise_IK)    | DH/ECDH (IKEv2)                         |
| >            | **NAT 穿越**             | 原生 (UDP 封装)                         | 需 NAT-T (UDP 4500)                |
| >            | **重放保护**             | 滑动窗口 (~2000)                        | 滑动窗口 (可配置)                  |
| >            | **MTU 开销**             | 80 B (UDP + WG header)                  | ESP: ~40 B, UDP-ESP: ~60 B         |
| >            | **握手消息**             | 148 + 124 = 272 B (两次)                | IKEv2: 多次交互，>1 KB             |
| >            | **DPDK 支持**            | 无原生 PMD，需自研                      | 原生 IPsec library + inline crypto |
| >            | **硬件卸载**             | 无 NIC 原生卸载                         | ConnectX/IXIA 内置 ESP 卸载        |

### 8.2 工程选型建议

```text
选型决策树：

  需求: 高性能 VPN 加密隧道
    │
    ├── 需要 NIC 硬件卸载？ (100+ Gbps)
    │     └── YES → IPsec (ESP inline crypto)
    │                ConnectX MLX5 内置 ESP 卸载，
    │                无需 CPU 参与加密
    │
    ├── 需要 DPI/中间设备兼容？
    │     └── YES → IPsec (行业标准)
    │                企业防火墙普遍支持 IPsec
    │
    ├── 追求最简配置和运维？
    │     └── YES → WireGuard
    │                一个 INI 文件搞定，
    │                无需 CA/证书/SPI/SA 管理
    │
    └── 需要 DPDK 数据面处理？
          ├── 已有 VPP 基础设施 → VPP WireGuard plugin
          ├── 纯 DPDK 自研 → graph pipeline + cryptodev
          └── 通用 VPN 网关 → IPsec library (成熟稳定)
```

---

## 9. 总结

```text
WireGuard + DPDK 知识框架：

协议层
├── Noise_IKpsk2 握手: 3 次 ECDH + PSK
├── CHAIN_KEY 密钥链: HMAC-BLAKE2s 渐进式密钥推导
└── 前向保密: 每 ~120s 临时密钥轮换

加密层
├── ChaCha20-Poly1305: AEAD 加密 + 认证
├── Curve25519: Montgomery ladder ECDH
└── DPDK cryptodev: QAT/AESNI-MB/软件卸载

安全机制
├── Cookie DoS 防护: MAC1 + MAC2 + encrypted cookie
├── 滑动窗口抗重放: ~2000 包窗口
└── Cryptokey Routing: AllowedIPs 精确路由

数据面加速
├── DPDK graph pipeline: 分类 → 解密 → 转发 / 路由 → 加密 → 发送
├── 批量加密: rte_cryptodev enqueue_burst
└── 性能目标: 40+ Gbps (SW) / 100 Gbps (QAT)

局限与展望
├── 无原生 DPDK PMD (需自研或使用 VPP)
├── ChaCha20 无 NIC 原生卸载 (vs AES-GCM 有 ESP offload)
└── 握手状态管理复杂 (定时器、重试、rekey)
```

---

## 参考资源

- [WireGuard Protocol & Cryptography](https://www.wireguard.com/protocol/) — 官方协议规范
- [WireGuard Whitepaper (PDF)](https://www.wireguard.com/papers/wireguard.pdf) — 学术论文
- [Noise Protocol Framework](https://noiseprotocol.org/) — Noise 协议框架
- [wireguard-go](https://github.com/WireGuard/wireguard-go) — Go 参考实现
- [Linux kernel WireGuard](https://git.zx2c4.com/WireGuard/) — 内核实现
- [DPDK Cryptodev Library](https://doc.dpdk.org/guides/prog_guide/cryptodev_lib.html) — DPDK 加密设备框架
- [A Generic High-Performance Architecture for VPN Gateways (MDPI 2024)](https://www.mdpi.com/2079-9292/13/11/2031) — DPDK graph pipeline 架构论文
- [Intel QAT Accelerate WireGuard](https://builders.intel.com/docs/networkbuilders/) — QAT 加速 WireGuard 指南
- [VPP WireGuard (slowbootkernelhacks 2025)](https://slowbootkernelhacks.blogspot.com/) — VPP WireGuard 实战
- [WireGuard 形式化安全证明 (EuroS&P 2019)](https://inria.hal.science/hal-02100345v3/document) — 独立安全审计
- [[2026-04-09-dpdk-deep-dive-series-index|DPDK 深度探索系列索引]]
