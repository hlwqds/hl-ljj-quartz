---
title: "DPDK 深度探索 ch40：WireGuard 加速"
date: 2026-04-10 15:30:00
tags: [dpdk, wireguard, wireguard-go, noise-protocol, crypto, udp, vpn]
description: "深入解析 DPDK WireGuard：Noise Protocol、Curve25519、ChaCha20-Poly1305、内核模块与用户态实现"
---

# DPDK 深度探索 ch40：WireGuard 加速

> [!abstract] 核心要点
> WireGuard 是现代 VPN 协议。本章深入解析 Noise Protocol、WireGuard 协议、ChaCha20-Poly1305 与 DPDK 实现。

## 1. WireGuard 概述

### 1.1 WireGuard 特点

```
WireGuard 特点：

1. 简单
   - ~4000 行代码 (vs OpenVPN ~100000)
   - 单一协议，单一端口 (UDP 51871)
   - 基于 Noise Protocol

2. 高性能
   - ChaCha20-Poly1305 (SIMD 加速)
   - Curve25519 (椭圆曲线)
   - 内核模块实现 (零拷贝)

3. 安全
   - 完整前向保密
   - 抗量子算法 (混合密钥交换)
   - 严格验证
```

### 1.2 vs OpenVPN/IPsec

| 特性       | WireGuard  | OpenVPN | IPsec |
| ---------- | ---------- | ------- | ----- |
| **代码量** | ~4000      | ~100K   | ~500K |
| **性能**   | 极高       | 中      | 高    |
| **安全性** | 现代       | 高      | 高    |
| **兼容性** | Linux 为主 | 广泛    | 广泛  |
| **配置**   | 简单       | 复杂    | 复杂  |

## 2. Noise Protocol

### 2.1 Noise 框架

```
Noise Protocol Framework：

┌─────────────────────────────────────────────────────────────┐
│                    Noise 模式                               │
│                                                              │
│  Noise_IK:                                                 │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  ← s                                               │  │
│  │  → e, ee, s, es                                    │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                              │
│  - I: Initiator (我)                                       │
│  - K: Known server static key                             │
│  - s: 交换静态密钥                                         │
│  - e: 交换临时密钥                                         │
│                                                              │
│  符号说明：                                                │
│  - →: 发送                                                 │
│  - ←: 接收                                                 │
│  - e: 生成临时椭圆曲线公钥                                 │
│  - s: 发送静态公钥                                         │
│  - ee: 混合两个椭圆曲线公钥                               │
│  - es: initiator 静态 × responder 临时                    │
│  - se: initiator 临时 × responder 静态                     │
│  - ss: 两个静态公钥                                        │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 WireGuard 握手

```
WireGuard 握手：

Initiator                            Responder
  │                                      │
  │  ① handshake_initiation             │
  │  ─────────────────────────────────▶  │
  │     - 临时公钥 (e)                   │
  │     - 静态公钥 (s) 加密             │
  │     - timestamp (t)                  │
  │     - cookie (可选)                   │
  │                                      │
  │                      ② handshake_response
  │  ◀───────────────────────────────────
  │     - 临时公钥 (e)                   │
  │     - nothing (无静态密钥)            │
  │     - encrypted static               │
  │     - encrypted timestamp            │
  │     - MAC                           │
  │                                      │
  │  ③ transport_data (encrypted)        │
  │  ════════════════════════════════════│
  │     - IP packets (encrypted)         │
  │     - counter                        │
  │     - packet_auth                    │
  │                                      │
```

## 3. 加密原语

### 3.1 ChaCha20-Poly1305

```
ChaCha20-Poly1305：

┌─────────────────────────────────────────────────────────────┐
│                    AEAD 加密                               │
│                                                              │
│  ChaCha20:                                                  │
│  - 流加密                                                  │
│  - 256-bit key                                             │
│  - 64-bit nonce                                            │
│  - 20 rounds                                               │
│                                                              │
│  Poly1305:                                                  │
│  - MAC                                                     │
│  - 128-bit authentication tag                             │
│  - One-time key                                            │
│                                                              │
│  组合：                                                    │
│  - ChaCha20 加密 + Poly1305 认证                          │
│  - 加密 + 完整性保护                                      │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 ChaCha20 实现

```c
// ChaCha20 实现
#include <Sodium.h>

void
chacha20_encrypt(uint8_t *dst, const uint8_t *src,
                  size_t len, const uint8_t *key,
                  const uint8_t *nonce, uint64_t counter)
{
    crypto_stream_chacha20_xor(dst, src, len,
                               nonce, counter, key);
}

// Poly1305 实现
void
poly1305_auth(uint8_t *tag, const uint8_t *msg,
              size_t msg_len, const uint8_t *key)
{
    crypto_onetimeauth(tag, msg, msg_len, key);
}

// AEAD 加密
int
aead_encrypt(uint8_t *dst, const uint8_t *src, size_t src_len,
             const uint8_t *ad, size_t ad_len,
             const uint8_t *nonce, const uint8_t *key)
{
    // ChaCha20 加密
    chacha20_encrypt(dst, src, src_len, key, nonce, 0);

    // Poly1305 认证
    uint8_t poly_key[64];
    chacha20_encrypt(poly_key, poly_key, 64, key, nonce, 0);
    poly1305_auth(dst + src_len, ad, ad_len, poly_key);

    return src_len + 16;  // +16 for tag
}
```

### 3.3 Curve25519

```c
// Curve25519 密钥交换
#include <Sodium.h>

// 生成密钥对
int
generate_keypair(uint8_t *public_key, uint8_t *private_key)
{
    // 生成随机私钥
    randombytes_buf(private_key, 32);
    crypto_scalarmult_base(public_key, private_key);

    return 0;
}

// 共享密钥
int
compute_shared_secret(uint8_t *shared,
                      const uint8_t *private_key,
                      const uint8_t *peer_public)
{
    crypto_scalarmult(shared, private_key, peer_public);
    return 0;
}
```

## 4. WireGuard 数据包

### 4.1 数据包格式

```
┌─────────────────────────────────────────────────────────────┐
│                    WireGuard 数据包                         │
│                                                              │
│  握手 initiation:                                           │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Type: 1 (4 bytes)                                   │  │
│  │  Receiver: peer index (4 bytes)                      │  │
│  │  E: ephemeral public key (32 bytes)                  │  │
│  │  E + EEs || ESs || s || STATICStatic: encrypted    │  │
│  │  MAC1: authentication (16 bytes)                    │  │
│  │  MAC2: optional cookie reply (16 bytes)             │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                              │
│  传输数据:                                                   │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Type: 4 (4 bytes)                                   │  │
│  │  Receiver: peer index (4 bytes)                      │  │
│  │  Counter: packet number (8 bytes)                    │  │
│  │  Encrypted: [IP packet] + Poly1305 tag              │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 WireGuard 头

```c
// WireGuard 头
struct wg_header {
    uint32_t type;
    uint32_t receiver;
};

struct wg_handshake_init {
    uint32_t type;              // 1
    uint32_t receiver;           // Peer index
    uint8_t ephemeral[32];     // 临时公钥
    uint8_t encrypted[48];      // 加密数据
    uint8_t mac1[16];          // MAC
    uint8_t mac2[16];          // MAC2 (optional)
};

struct wg_transport_data {
    uint32_t type;              // 4
    uint32_t receiver;          // Peer index
    uint64_t counter;          // 包计数器
    uint8_t encrypted[];       // 加密 payload + tag
};
```

## 5. DPDK WireGuard 实现

### 5.1 WireGuard PMD

```c
// DPDK WireGuard 设备
struct wg_device {
    uint8_t port_id;           // DPDK port

    // 私钥
    uint8_t private_key[32];
    uint8_t public_key[32];

    // 对等点
    struct wg_peer *peers[MAX_PEERS];
    int num_peers;
};

// WireGuard Peer
struct wg_peer {
    uint32_t index;            // Peer index

    uint8_t public_key[32];   // 对等点公钥
    uint8_t preshared_key[32]; // 预共享密钥

    // 隧道地址
    uint32_t tunnel_ip;
    uint32_t tunnel_netmask;

    // 当前会话
    struct wg_session {
        uint8_t send_key[32];
        uint8_t recv_key[32];
        uint64_t send_counter;
        uint64_t recv_counter;
    } session;
};
```

### 5.2 WireGuard 处理

```c
// WireGuard 入站处理
int
wg_process_inbound(struct wg_device *wg,
                    struct rte_mbuf *mbuf)
{
    struct wg_header *hdr = rte_pktmbuf_mtod(mbuf, struct wg_header *);

    switch (hdr->type) {
    case WG_TYPE_HANDSHAKE_INIT:
        return wg_handle_handshake_init(wg, mbuf);
    case WG_TYPE_HANDSHAKE_RESPONSE:
        return wg_handle_handshake_response(wg, mbuf);
    case WG_TYPE_TRANSPORT_DATA:
        return wg_handle_transport(wg, mbuf);
    default:
        return -1;
    }
}

// 传输数据解密
int
wg_decrypt_transport(struct wg_peer *peer,
                     struct rte_mbuf *mbuf)
{
    struct wg_transport_data *hdr =
        rte_pktmbuf_mtod(mbuf, struct wg_transport_data *);

    // 检查计数器
    uint64_t counter = rte_be_to_cpu_64(hdr->counter);

    if (counter <= peer->session.recv_counter)
        return -1;  // 重放攻击

    // 解密
    uint8_t *ciphertext = hdr->encrypted;
    size_t cipher_len = rte_pktmbuf_data_len(mbuf) -
        sizeof(struct wg_transport_data) - 16;  // -tag

    uint8_t *plaintext = rte_pktmbuf_adj(mbuf,
        sizeof(struct wg_transport_data));

    // Poly1305 验证 + ChaCha20 解密
    crypto_aead_chacha20_poly1305_decrypt(
        plaintext, ciphertext, cipher_len,
        NULL, 0,  // no AD
        peer->session.recv_key,
        hdr->counter);

    peer->session.recv_counter = counter;

    return 0;
}
```

### 5.3 WireGuard 出站

```c
// WireGuard 出站封装
int
wg_process_outbound(struct wg_device *wg,
                    struct wg_peer *peer,
                    struct rte_mbuf *mbuf)
{
    struct ipv4_hdr *ip = rte_pktmbuf_mtod(mbuf, struct ipv4_hdr *);

    // 准备传输头
    struct wg_transport_data *hdr =
        rte_pktmbuf_prepend(mbuf, sizeof(struct wg_transport_data));

    hdr->type = rte_cpu_to_be_32(WG_TYPE_TRANSPORT_DATA);
    hdr->receiver = rte_cpu_to_be_32(peer->index);
    hdr->counter = rte_cpu_to_be_64(peer->session.send_counter);

    // 加密
    uint8_t *plaintext = (uint8_t *)(hdr + 1);
    size_t plain_len = rte_pktmbuf_data_len(mbuf) - sizeof(struct wg_transport_data);

    crypto_aead_chacha20_poly1305_encrypt(
        hdr->encrypted, plaintext, plain_len,
        (uint8_t *)ip, sizeof(struct ipv4_hdr),  // AD = IP header
        peer->session.send_key,
        hdr->counter);

    // 添加 tag
    uint8_t *tag = hdr->encrypted + plain_len;

    peer->session.send_counter++;

    return 0;
}
```

## 6. 与内核 WireGuard 比较

### 6.1 内核模块 vs DPDK

| 特性         | 内核 WireGuard | DPDK WireGuard |
| ------------ | -------------- | -------------- |
| **部署位置** | 内核           | 用户态         |
| **性能**     | ~10 Gbps       | ~20-40 Gbps    |
| **延迟**     | ~100μs         | ~10-50μs       |
| **集成**     | 路由/NF        | 独立处理       |
| **依赖**     | 内核模块       | DPDK           |

### 6.2 性能数据

```
WireGuard 性能对比：

内核 WireGuard:
  - 吞吐量: ~1-2 Gbps (per core)
  - CPU: ~30% (4 cores @ 3GHz)
  - 延迟: ~100-200μs

DPDK WireGuard:
  - 吞吐量: ~5-10 Gbps (per core)
  - CPU: ~15% (4 cores @ 3GHz)
  - 延迟: ~20-50μs

WireGuard vs IPsec:
  - WireGuard: 简单，ChaCha20-Poly1305
  - IPsec: 复杂，AES-GCM (硬件加速)
```

## 7. 总结

WireGuard 架构：

```
┌─────────────────────────────────────────────────────────────┐
│                    WireGuard 数据流                         │
│                                                              │
│  应用数据                                                    │
│     ↓                                                        │
│  WireGuard (ChaCha20-Poly1305)                              │
│     ↓                                                        │
│  UDP (51871)                                                │
│     ↓                                                        │
│  IP 网络                                                    │
│     ↓                                                        │
│  WireGuard (ChaCha20-Poly1305)                              │
│     ↓                                                        │
│  应用数据                                                    │
└─────────────────────────────────────────────────────────────┘
```

WireGuard vs 其他 VPN：

| 特性       | WireGuard  | IPsec      | OpenVPN    |
| ---------- | ---------- | ---------- | ---------- |
| **安全性** | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐   | ⭐⭐⭐     |
| **性能**   | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐   | ⭐⭐       |
| **简单性** | ⭐⭐⭐⭐⭐ | ⭐⭐       | ⭐⭐       |
| **兼容性** | ⭐⭐       | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ |

---

## 参考资源

- [WireGuard](https://www.wireguard.com/)
- [Noise Protocol](https://noiseexplorer.com/)
- [WireGuard Linux](https://git.zx2c4.com/WireGuard/)
- [libsodium](https://libsodium.gitbook.io/doc/)
