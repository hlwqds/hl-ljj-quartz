---
title: WireGuard 内核深度探索 Ch2：加密引擎与 Key 管理
date: 2026-05-02 09:00:00
tags: [WireGuard, Kernel, Crypto, Noise, ChaCha20, Poly1305, AEAD, DH, Key Management, Key Rotation, Handshake, Cookie, Authentication, Cipher, Security, RFC 7539, RFC 7746]
description: WireGuard 内核源码深度解析 Ch2：Noise 握手协议实现、ChaCha20-Poly1305 AEAD 加密引擎、密钥生成与销毁、密钥轮换机制、Cookie 验证器的完整流程。
---

# WireGuard 内核深度探索 Ch2：加密引擎与 Key 管理

## 1. 概述

```
Ch2 加密引擎与 Key 管理：

本章内容：
  1. Noise 握手协议实现
  2. 密钥对生成与销毁
  3. ChaCha20-Poly1305 AEAD
  4. 密钥轮换机制
  5. Cookie 验证器

前置知识：
  · WireGuard 协议深度解析（Noise 协议基础）
  · RFC 7539 (ChaCha20-Poly1305)
  · RFC 7746 (Curve25519)
```

---

## 2. Noise 握手协议实现

### 2.1 握手状态机

```c
// noise.h — Noise 握手状态

enum noise_handshake_state {
    HANDSHAKE_ZERO,
    HANDSHAKE_CREATED_LOCAL_STATIC,
    HANDSHAKE_CREATED_LOCAL_STATIC__CREATED_REMOTE_STATIC,
    HANDSHAKE_CREATED_LOCAL_STATIC__CREATED_REMOTE_STATIC__CREATED_LOCAL_EPHEMERAL,
    HANDSHAKE_CREATED_LOCAL_STATIC__CREATED_REMOTE_STATIC__CREATED_LOCAL_EPHEMERAL__CREATED_REMOTE_EPHEMERAL,
    HANDSHAKE_AWAIT_LOCAL_EPHEMERAL,
    HANDSHAKE_AWAIT_LOCAL_EPHEMERAL__CREATED_REMOTE_EPHEMERAL,
    HANDSHAKE_AWAIT_LOCAL_EPHEMERAL__CREATED_REMOTE_EPHEMERAL__CREATED_LOCAL_EPHEMERAL,
    HANDSHAKE_AWAIT_LOCAL_EPHEMERAL__CREATED_REMOTE_EPHEMERAL__CREATED_LOCAL_EPHEMERAL__CREATED_REMOTE_EPHEMERAL,
    HANDSHAKE_CONSUMED_LOCAL_EPHEMERAL,
    HANDSHAKE_CONSUMED_LOCAL_EPHEMERAL__CREATED_REMOTE_EPHEMERAL,
    HANDSHAKE_CONSUMED_LOCAL_EPHEMERAL__CREATED_REMOTE_EPHEMERAL__CREATED_LOCAL_EPHEMERAL,
    HANDSHAKE_COMPLETED
};

struct noise_handshake {
    // 状态
    atomic_t state;
    struct mutex state_mutex;

    // 本地静态密钥
    u8 static_public[NOISE_PUBLIC_KEY_LEN];
    u8 static_private[NOISE_PRIVATE_KEY_LEN];

    // 预共享密钥（可选）
    u8 preshared_key[NOISE_SYMMETRIC_KEY_LEN];

    // 远程静态公钥
    u8 remote_static[NOISE_PUBLIC_KEY_LEN];

    // 远程临时公钥
    u8 remote_ephemeral[NOISE_PUBLIC_KEY_LEN];

    // DH 密钥
    struct crypto_dh *dh;
    struct dh秘密*dh_local_ephemeral;

    // 链式密钥和哈希
    u8 chain_key[NOISE_CHAIN_KEY_LEN];
    u8 hash[NOISE_HASH_LEN];

    // 发送/接收索引
    u32 sending_index;
    u32 receiving_index;

    // 用于解密初始包
    u8 er_ours[NOISE_PUBLIC_KEY_LEN_NO_FS];
    u8 er_theirs[NOISE_PUBLIC_KEY_LEN_NO_FS];

    // 重新传输计时器
    struct timer_list retransmit_timer;
};
```

### 2.2 握手初始化

```c
// noise.c — 握手初始化

int noise_handshake_init(struct noise_handshake *handshake,
                         const u8 public_key[NOISE_PUBLIC_KEY_LEN],
                         const u8 preshared_key[NOISE_SYMMETRIC_KEY_LEN])
{
    int ret;

    // 初始化互斥锁
    mutex_init(&handshake->state_mutex);
    atomic_set(&handshake->state, HANDSHAKE_ZERO);

    // 加载本地静态密钥
    if (public_key) {
        memcpy(handshake->static_public, public_key, NOISE_PUBLIC_KEY_LEN);
    }

    // 加载预共享密钥
    if (preshared_key) {
        memcpy(handshake->preshared_key, preshared_key, NOISE_SYMMETRIC_KEY_LEN);
    }

    // 初始化 DH（Curve25519）
    ret = crypto_dh_init(handshake);
    if (ret < 0)
        return ret;

    // 初始化哈希
    // Hash = HMAC(HMAC("Noise_IKpsk2_25519_ChaChaPoly_BLAKE2s",
    //                  "WireGuard v1.0"), remote_static || preshared_key)
    memcpy(handshake->hash, HMAC_SHA256,
           "Noise_IKpsk2_25519_ChaChaPoly_BLAKE2s" || ...);

    // 初始化链式密钥
    // Chain = HMAC(HMAC("Noise_IKpsk2_25519_ChaChaPoly_BLAKE2s",
    //                   "WireGuard v1.0"), preshared_key)
    memcpy(handshake->chain_key, HMAC_SHA256,
           "Noise_IKpsk2_25519_ChaChaPoly_BLAKE2s" || ...);

    return 0;
}
```

### 2.3 握手第一阶段：创建 Initiation

```c
// noise.c — 创建握手 Initiation

int noise_handshake_create_initiation(struct wg_peer *peer,
                                      struct message_handshake_initiation *packet)
{
    struct noise_handshake *handshake = &peer->handshake;
    u8 ephemeral_private[NOISE_PRIVATE_KEY_LEN];
    u8 hash[NOISE_HASH_LEN];
    u8 chain_key[NOISE_CHAIN_KEY_LEN];

    mutex_lock(&handshake->state_mutex);

    // 仅在初始状态
    if (atomic_read(&handshake->state) != HANDSHAKE_ZERO)
        goto out;

    // 1. 生成临时密钥（Ephemeral Key）
    //    生成 Curve25519 临时私钥
    generate_ephemeral_keypair(ephemeral_private, packet->unencrypted_ephemeral);

    // 2. 混合 Hash
    //    hash = HMAC(chain_key, local_ephemeral || remote_static)
    memcpy(hash, handshake->hash, NOISE_HASH_LEN);
    HMAC_ChaCha20_Poly1305(hash, packet->unencrypted_ephemeral,
                           NOISE_PUBLIC_KEY_LEN_NO_FS);
    HMAC_ChaCha20_Poly1305(hash, handshake->remote_static,
                           NOISE_PUBLIC_KEY_LEN);

    // 3. 混合 Chain Key
    //    chain_key = HMAC(chain_key, DH(local_ephemeral, remote_static))
    DHEC25519(ephemeral_private, handshake->remote_static,
              packet->ephemeral_our);
    HMAC_ChaCha20_Poly1305(chain_key, packet->ephemeral_our,
                           NOISE_PUBLIC_KEY_LEN_NO_FS);

    // 4. 加密 static public（使用预共享密钥）
    //    struct: sender_index || unencrypted_ephemeral
    //            || encrypted_static || mac1 || mac2
    packet->header.type = htolke(MESSAGE_HANDSHAKE_INITIATION);
    packet->sender_index = get_random_u32();

    // 5. 计算 MAC1
    //    mac1 = HMAC("mac1" || preshared_key, msg_without_mac)
    compute_mac1(packet, handshake->preshared_key, peer->device);

    // 6. 加密 static public
    //    encrypted_static = AEAD(chain_key, 0,
    //                            static_public, preshared_key)
    encrypt_static(handshake, packet, chain_key);

    // 7. 计算 MAC2
    //    mac2 = HMAC("mac2" || preshared_key,
    //                 msg_without_mac || mac1)
    compute_mac2(packet, handshake->preshared_key, peer->device);

    // 8. 保存状态用于后续
    memcpy(handshake->er_ours, packet->unencrypted_ephemeral,
           NOISE_PUBLIC_KEY_LEN_NO_FS);
    memcpy(handshake->chain_key, chain_key, NOISE_CHAIN_KEY_LEN);
    memcpy(handshake->hash, hash, NOISE_HASH_LEN);

    atomic_set(&handshake->state, HANDSHAKE_CREATED_LOCAL_EPHEMERAL);

    mutex_unlock(&handshake->state_mutex);

    // 9. 启动重传计时器
    mod_timer(&peer->retransmit_handshake,
              jiffies + RETRANSMIT_TIMEOUT);

    return 0;

out:
    mutex_unlock(&handshake->state_mutex);
    return -EBUSY;
}
```

### 2.4 握手第二阶段：处理 Response

```c
// noise.c — 处理握手 Response

int noise_handshake_consume_initiation(
    struct wg_device *wg,
    struct message_handshake_response *response,
    struct wg_peer **peer)
{
    struct wg_peer *found_peer;
    struct noise_handshake *handshake;
    u8 ephemeral_private[NOISE_PRIVATE_KEY_LEN];
    u8 hash[NOISE_HASH_LEN];
    u8 chain_key[NOISE_CHAIN_KEY_LEN];
    u8 key[NOISE_SYMMETRIC_KEY_LEN];

    // 1. 查找对应的 Peer（通过 receiver_index）
    found_peer = wg_pubkey_hashtable_lookup(wg->peer_hashtable,
                                            response->receiver_index);
    if (!found_peer)
        return -ENOENT;

    handshake = &found_peer->handshake;
    mutex_lock(&handshake->state_mutex);

    // 2. 验证状态
    if (atomic_read(&handshake->state) != HANDSHAKE_AWAIT_LOCAL_EPHEMERAL)
        goto fail;

    // 3. 验证 MAC1
    if (!verify_mac1(response, handshake->preshared_key, wg))
        goto fail;

    // 4. 混合密钥
    //    chain_key = HMAC(chain_key, DH(ephemeral_private, remote_ephemeral))
    DHEC25519(ephemeral_private, response->unencrypted_ephemeral,
              key);
    HMAC_ChaCha20_Poly1305(chain_key, key, NOISE_PUBLIC_KEY_LEN_NO_FS);

    // 5. 派生会话密钥
    //    key = HMAC(chain_key, 0)
    derive_session_keys(chain_key, key);

    // 6. 解密并验证
    //    decrypted = AEAD_DEC(key, response->encrypted_ephemeral)
    if (!decrypt_ephemeral(response, key, hash, chain_key))
        goto fail;

    // 7. 计算响应包的 sender_index
    response->sender_index = found_peer->internal_id;

    // 8. 创建并发送 Response
    noise_handshake_create_response(found_peer, response);

    // 9. 建立密钥对
    noise_keypair_init(found_peer, hash);

    atomic_set(&handshake->state, HANDSHAKE_COMPLETED);
    mutex_unlock(&handshake->state_mutex);

    *peer = found_peer;
    return 0;

fail:
    mutex_unlock(&handshake->state_mutex);
    wg_peer_put(found_peer);
    return -EINVAL;
}
```

---

## 3. 密钥对生成与销毁

### 3.1 密钥对结构

```c
// noise.h — 密钥对结构

struct noise_symmetric_key {
    struct chacha20poly1305_ctx send;
    struct chacha20poly1305_ctx recv;
    atomic64_t send_nonce;
    atomic64_t recv_nonce;
    unsigned long birth;
    bool is_valid;
};

struct noise_keypair {
    struct noise_symmetric_key *sending_key;
    struct noise_symmetric_key *receiving_key;
    atomic64_t sending_key_id;
    atomic64_t receiving_key_id;
    u8 ai_secret[NOISE_HASH_LEN];
    struct list_head list;
    refcount_t refcount;
};
```

### 3.2 密钥对初始化

```c
// noise.c — 密钥对初始化

void noise_keypair_init(struct wg_peer *peer, const u8 *chain_key)
{
    struct noise_symmetric_key *sending_key, *receiving_key;
    struct noise_keypair *keypair;
    u8 key_data[NOISE_SYMMETRIC_KEY_LEN * 2];

    // 1. 分配密钥对
    keypair = kzalloc(sizeof(*keypair), GFP_KERNEL);
    sending_key = kzalloc(sizeof(*sending_key), GFP_KERNEL);
    receiving_key = kzalloc(sizeof(*receiving_key), GFP_KERNEL);

    if (!keypair || !sending_key || !receiving_key)
        goto err;

    // 2. 派生发送密钥
    //    sending_key = HMAC(chain_key, 1)
    hmac_sha256(chain_key, NOISE_CHAIN_KEY_LEN,
                key_data, NOISE_SYMMETRIC_KEY_LEN, 1);

    // 3. 派生接收密钥
    //    receiving_key = HMAC(chain_key, 2)
    hmac_sha256(chain_key, NOISE_CHAIN_KEY_LEN,
                key_data + NOISE_SYMMETRIC_KEY_LEN,
                NOISE_SYMMETRIC_KEY_LEN, 2);

    // 4. 初始化 ChaCha20 上下文
    chacha20poly1305_init(&sending_key->send, key_data);
    chacha20poly1305_init(&receiving_key->recv,
                          key_data + NOISE_SYMMETRIC_KEY_LEN);

    // 5. 初始化计数器
    atomic64_set(&sending_key->send_nonce, 0);
    atomic64_set(&receiving_key->recv_nonce, 0);

    // 6. 设置元数据
    sending_key->birth = jiffies;
    receiving_key->birth = jiffies;
    sending_key->is_valid = true;
    receiving_key->is_valid = true;

    // 7. 生成密钥 ID
    keypair->sending_key_id = get_random_u64() & ~0xf;
    keypair->receiving_key_id = get_random_u64() & ~0xf;

    // 8. 保存到 peer
    spin_lock(&peer->keypair_lock);
    peer->keypair.sending_key = sending_key;
    peer->keypair.receiving_key = receiving_key;
    peer->keypair.keypair = keypair;
    peer->keypair.sending_key_id = keypair->sending_key_id;
    peer->keypair.receiving_key_id = keypair->receiving_key_id;
    spin_unlock(&peer->keypair_lock);

    // 9. 清除临时数据
    memzero_explicit(key_data, sizeof(key_data));

    return;

err:
    kfree(keypair);
    kfree(sending_key);
    kfree(receiving_key);
}
```

### 3.3 密钥对销毁

```c
// noise.c — 密钥对销毁

void noise_keypair_put(struct noise_keypair *keypair)
{
    if (refcount_dec_and_test(&keypair->refcount)) {
        // 清除敏感数据
        if (keypair->sending_key) {
            memzero_explicit(&keypair->sending_key->send,
                            sizeof(keypair->sending_key->send));
            kfree_sensitive(keypair->sending_key);
        }
        if (keypair->receiving_key) {
            memzero_explicit(&keypair->receiving_key->recv,
                            sizeof(keypair->receiving_key->recv));
            kfree_sensitive(keypair->receiving_key);
        }
        kfree_sensitive(keypair);
    }
}

void noise_handshake_clear(struct noise_handshake *handshake)
{
    // 清除所有敏感密钥材料
    memzero_explicit(handshake->static_private, NOISE_PRIVATE_KEY_LEN);
    memzero_explicit(handshake->remote_static, NOISE_PUBLIC_KEY_LEN);
    memzero_explicit(handshake->remote_ephemeral, NOISE_PUBLIC_KEY_LEN);
    memzero_explicit(handshake->chain_key, NOISE_CHAIN_KEY_LEN);
    memzero_explicit(handshake->hash, NOISE_HASH_LEN);

    // 删除计时器
    del_timer_sync(&handshake->retransmit_timer);

    atomic_set(&handshake->state, HANDSHAKE_ZERO);
}
```

---

## 4. ChaCha20-Poly1305 AEAD

### 4.1 算法概述

```
ChaCha20-Poly1305 AEAD：

┌──────────────────────────────────────────────────────────────────────┐
│                      RFC 7539: ChaCha20/Poly1305                   │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   ChaCha20:                                                         │
│   · 流密码，256 位密钥                                              │
│   · 20 轮 ChaCha 操作                                               │
│   · 64 位计数器 + 96 位 nonce                                       │
│   · 比 AES 快 3-4x（无硬件加速时）                                  │
│                                                                      │
│   Poly1305:                                                         │
│   · MAC，128 位输出                                                 │
│   · 130 位素数模运算                                                │
│   · 一次性密钥（每条消息不同）                                       │
│                                                                      │
│   AEAD 组合：                                                       │
│   · ChaCha20 加密 + Poly1305 认证                                   │
│   · 认证加密（加密同时认证）                                         │
│   · 无需 separate MAC                                              │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘

WireGuard 使用的参数：
  · 密钥：256 位（32 字节）                                          │
  · Nonce：96 位（12 字节）                                          │
  · Tag：128 位（16 字节）                                           │
  · 最大消息：16,777,215 字节（2^24 - 1）                            │
```

### 4.2 内核实现

```c
// crypto.c / noise.c — ChaCha20-Poly1305 实现

#include <crypto/chacha20poly1305.h>
#include <crypto/chacha.h>
#include <crypto/poly1305.h>

struct chacha20poly1305_ctx {
    struct chacha_ctx chacha;
    struct poly1305_ctx poly;
    u8 key[32];
    u8 nonce[12];
};

// 初始化
void chacha20poly1305_init(struct chacha20poly1305_ctx *ctx,
                           const u8 key[32])
{
    // 设置密钥
    memcpy(ctx->key, key, 32);

    // 初始化 ChaCha 上下文
    chacha_init(ctx->nonce, key, 20);
}

// 加密 + 认证
int chacha20poly1305_encrypt(struct chacha20poly1305_ctx *ctx,
                              u8 *dst, const u8 *src,
                              const size_t src_len,
                              const u8 *ad, const size_t ad_len,
                              u64 nonce_ctr)
{
    struct poly1305_ctx poly;
    u8 block[64];
    u8 tag[16];
    u8 nonce[12];

    // 1. 构造 nonce（little-endian）
    //    nonce = nonce_ctr || fixed nonce (4 bytes)
    memset(nonce, 0, 12);
    put_unaligned_le64(nonce_ctr, nonce);
    memcpy(nonce + 8, ctx->nonce + 8, 4);

    // 2. 生成 Poly1305 密钥
    //    Poly1305 key = ChaCha20(key, nonce=0, counter=0)
    chacha_init(ctx->chacha.key, ctx->key, 20);
    chacha_set_nonce(ctx->chacha.n, nonce);
    chacha_set_counter(ctx->chacha, 0);
    chacha_encrypt_bytes(ctx->chacha, block, block, 64);

    // 3. 初始化 Poly1305
    poly1305_init(&poly, block);

    // 4. Authenticate additional data
    if (ad_len > 0)
        poly1305_update(&poly, ad, ad_len);

    // 5. Pad source length
    poly1305_update(&poly, (u8 *)&src_len, sizeof(src_len));

    // 6. Encrypt + authenticate plaintext
    for (size_t i = 0; i < src_len; i += 64) {
        size_t chunk = min_t(size_t, 64, src_len - i);

        // 生成密文块
        chacha_encrypt_bytes(ctx->chacha, src + i, dst + i, chunk);

        // Authenticate密文
        poly1305_update(&poly, dst + i, chunk);

        // 计数器递增
        chacha_set_counter(ctx->chacha, chacha_get_counter(ctx->chacha) + 1);
    }

    // 7. 生成 tag
    poly1305_fini(&poly, tag);

    // 8. 追加 tag 到密文
    memcpy(dst + src_len, tag, 16);

    return 0;
}

// 解密 + 验证
int chacha20poly1305_decrypt(struct chacha20poly1305_ctx *ctx,
                              u8 *dst, const u8 *src,
                              const size_t src_len,
                              const u8 *ad, const size_t ad_len,
                              u64 nonce_ctr)
{
    struct poly1305_ctx poly;
    u8 block[64];
    u8 tag[16], expected_tag[16];
    u8 nonce[12];

    // 1. 构造 nonce
    memset(nonce, 0, 12);
    put_unaligned_le64(nonce_ctr, nonce);
    memcpy(nonce + 8, ctx->nonce + 8, 4);

    // 2. 生成 Poly1305 密钥
    chacha_init(ctx->chacha.key, ctx->key, 20);
    chacha_set_nonce(ctx->chacha.n, nonce);
    chacha_set_counter(ctx->chacha, 0);
    chacha_encrypt_bytes(ctx->chacha, block, block, 64);

    // 3. 初始化 Poly1305
    poly1305_init(&poly, block);

    // 4. Authenticate additional data
    if (ad_len > 0)
        poly1305_update(&poly, ad, ad_len);

    // 5. Pad source length
    poly1305_update(&poly, (u8 *)&src_len, sizeof(src_len));

    // 6. Decrypt + authenticate
    size_t data_len = src_len - 16;
    for (size_t i = 0; i < data_len; i += 64) {
        size_t chunk = min_t(size_t, 64, data_len - i);

        poly1305_update(&poly, src + i, chunk);
        chacha_encrypt_bytes(ctx->chacha, src + i, dst + i, chunk);

        chacha_set_counter(ctx->chacha, chacha_get_counter(ctx->chacha) + 1);
    }

    // 7. 提取并验证 tag
    poly1305_fini(&poly, expected_tag);
    memcpy(tag, src + data_len, 16);

    if (crypto_memneq(tag, expected_tag, 16) != 0)
        return -EBADMSG;  // 认证失败

    return 0;
}
```

### 4.3 WireGuard 封装

```c
// noise.c — WireGuard AEAD 封装

#define AEAD_MESSAGE_OVERHEAD (16 + 4)  // tag (16) + counter (4)

int wg_encrypt(struct sk_buff *skb, struct noise_symmetric_key *key)
{
    struct chacha20poly1305_ctx ctx;
    u8 nonce[12];
    u64 nonce_ctr;
    int ret;

    // 1. 获取 nonce（从 keypair 的 nonce 计数器）
    nonce_ctr = atomic64_inc_return(&key->send_nonce);
    if (nonce_ctr >= (1ULL << 62)) {
        // 密钥耗尽
        key->is_valid = false;
        return -EOVERFLOW;
    }

    // 2. 构造 nonce
    memset(nonce, 0, 12);
    put_unaligned_le64(nonce_ctr, nonce);

    // 3. 初始化加密上下文
    memcpy(ctx.key, key->send.key, 32);
    chacha_init(ctx.nonce, nonce);

    // 4. 加密（IP 头 + UDP 头 + WireGuard 头）
    //    注意：header 不加密，只加密 payload
    struct wg_pkt *pkt = (struct wg_pkt *)skb->data;
    size_t data_len = skb->len - sizeof(struct wg_hdr);

    // 5. 加密 + 认证
    ret = chacha20poly1305_encrypt(&ctx,
                                    pkt->encrypted_data,
                                    pkt->encrypted_data,
                                    data_len,
                                    (u8 *)&pkt->header,
                                    sizeof(pkt->header),
                                    nonce_ctr);
    if (ret < 0)
        return ret;

    // 6. 更新计数器到包头
    pkt->counter = htol64(nonce_ctr);

    return 0;
}

int wg_decrypt(struct sk_buff *skb, struct noise_symmetric_key *key)
{
    struct chacha20poly1305_ctx ctx;
    u8 nonce[12];
    u64 nonce_ctr, age;
    int ret;

    // 1. 提取计数器
    struct wg_pkt *pkt = (struct wg_pkt *)skb->data;
    nonce_ctr = letoh64(pkt->counter);

    // 2. 防重放检查
    if (nonce_ctr <= key->recv_nonce_last) {
        if (nonce_ctr < key->recv_nonce_last - REJECT_AFTER_MESSAGES)
            return -EBADMSG;  // 太旧
        // 否则可能乱序，等待后续处理
    }

    // 3. 构造 nonce
    memset(nonce, 0, 12);
    put_unaligned_le64(nonce_ctr, nonce);

    // 4. 初始化解密上下文
    memcpy(ctx.key, key->recv.key, 32);
    chacha_init(ctx.nonce, nonce);

    // 5. 解密 + 验证
    size_t data_len = skb->len - sizeof(struct wg_hdr) - 16;
    ret = chacha20poly1305_decrypt(&ctx,
                                    pkt->encrypted_data,
                                    pkt->encrypted_data,
                                    data_len + 16,
                                    (u8 *)&pkt->header,
                                    sizeof(pkt->header),
                                    nonce_ctr);
    if (ret < 0)
        return ret;

    // 6. 更新接收 nonce
    atomic64_set(&key->recv_nonce, nonce_ctr);

    return 0;
}
```

---

## 5. 密钥轮换机制

### 5.1 密钥生命周期

```
WireGuard 密钥生命周期：

┌──────────────────────────────────────────────────────────────────────┐
│                        密钥生命周期                                  │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   T0 = 0 (握手完成，密钥建立)                                       │
│                                                                      │
│   密钥有效期内：                                                     │
│   │                                                                   │
│   │  发送密钥用于：发送方加密数据包                                  │
│   │  接收密钥用于：接收方解密数据包                                  │
│   │                                                                   │
│   │                                                                   │
│   │   ──────────────────────────────────────────►                   │
│   │                                                                   │
│   │   0                     TIME                       REJECT_AFTER   │
│   │   │                     │                         │              │
│   │   │                     │                         │              │
│   │   │    密钥有效         │      密钥过期警告        │   密钥失效  │
│   │   │    (0 - 120s)      │      (120 - 180s)        │   (> 180s) │
│   │   │                     │                         │              │
│   │   │                     │                         │              │
│   │   │  可以正常加密/解密   │  触发新握手建立新密钥    │   丢弃数据包│
│   │   │                     │                         │              │
│   │   │                     │                         │              │
│   ▼   ▼                     ▼                         ▼              │
│   ├─────────────────────────────────────────────────────────────────▶│
│                                                                      │
│   REJECT_AFTER_MESSAGES = 2^60 - 1 消息                              │
│   REJECT_AFTER_TIME = 180 秒                                         │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

### 5.2 密钥轮换实现

```c
// noise.c — 密钥轮换

#define REJECT_AFTER_MESSAGES (u64)(~0ULL >> 4)
#define REJECT_AFTER_TIME_SEC 180

void wg_peer_reset_handshake(struct wg_peer *peer)
{
    struct noise_handshake *handshake = &peer->handshake;

    mutex_lock(&handshake->state_mutex);

    // 1. 清除握手状态
    memzero_explicit(handshake->remote_static,
                    sizeof(handshake->remote_static));
    memzero_explicit(handshake->remote_ephemeral,
                    sizeof(handshake->remote_ephemeral));
    memzero_explicit(handshake->er_ours, sizeof(handshake->er_ours));
    memzero_explicit(handshake->er_theirs, sizeof(handshake->er_theirs));

    // 2. 重置握手计数器
    handshake->sending_index = 0;
    handshake->receiving_index = 0;

    // 3. 重置状态
    atomic_set(&handshake->state, HANDSHAKE_ZERO);

    mutex_unlock(&handshake->state_mutex);

    // 4. 清除密钥对
    spin_lock(&peer->keypair_lock);
    if (peer->keypair.sending_key) {
        peer->keypair.sending_key->is_valid = false;
        wg_symmetric_key_put(peer->keypair.sending_key);
    }
    if (peer->keypair.receiving_key) {
        peer->keypair.receiving_key->is_valid = false;
        wg_symmetric_key_put(peer->keypair.receiving_key);
    }
    spin_unlock(&peer->keypair_lock);

    // 5. 删除计时器
    del_timer_sync(&peer->retransmit_handshake);
    del_timer_sync(&peer->keepalive);

    // 6. 启动新握手
    queue_work(peer->device->packet_crypt_wq,
              &peer->init_handshake_work);
}

// 定时检查密钥是否过期
static void wg_keypair_expiry(struct work_struct *work)
{
    struct wg_peer *peer = container_of(work, struct wg_peer,
                                        keypair_expiry_work);
    struct noise_symmetric_key *key = peer->keypair.sending_key;
    unsigned long age;
    u64 messages;

    spin_lock(&peer->keypair_lock);

    if (!key || !key->is_valid) {
        spin_unlock(&peer->keypair_lock);
        return;
    }

    // 检查消息数量
    messages = atomic64_read(&key->send_nonce);
    if (messages >= REJECT_AFTER_MESSAGES) {
        key->is_valid = false;
        goto rekey;
    }

    // 检查时间
    age = (jiffies - key->birth) / HZ;
    if (age >= REJECT_AFTER_TIME_SEC) {
        key->is_valid = false;
        goto rekey;
    }

    spin_unlock(&peer->keypair_lock);
    return;

rekey:
    spin_unlock(&peer->keypair_lock);

    // 触发重新握手
    wg_queue_handshake(peer, true);
}
```

### 5.3 主动密钥轮换

```c
// noise.c — 主动重新握手

void wg_queue_handshake(struct wg_peer *peer, bool immediate)
{
    struct wg_device *wg = peer->device;

    // 1. 创建 initiation 消息
    struct message_handshake_initiation msg;
    if (noise_handshake_create_initiation(peer, &msg) < 0)
        return;

    // 2. 设置重传
    if (immediate) {
        // 立即发送
        wg_socket_send_buffer(wg, peer, &msg, sizeof(msg));
        mod_timer(&peer->retransmit_handshake,
                 jiffies + HZ / 4);  // 250ms
    } else {
        // 延迟发送
        mod_timer(&peer->retransmit_handshake,
                 jiffies + HZ * 2);  // 2s
    }
}
```

---

## 6. Cookie 验证器

### 6.1 Cookie 机制

```
WireGuard Cookie 机制（Anti-DoS）：

┌──────────────────────────────────────────────────────────────────────┐
│                        Cookie 验证流程                               │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  背景：                                                              │
│  · WireGuard 握手消息容易被用于 DDoS                                │
│  · 攻击者发送大量伪造的 initiation 消息                            │
│  · 服务器需要验证握手来自真实客户端                                  │
│                                                                      │
│  Cookie 机制：                                                       │
│  1. 服务器收到 Initiation，记录 sender IP                          │
│  2. 如果 IP 可信，立即回复 Cookie Reply                            │
│  3. Cookie Reply 包含加密的 cookie                                 │
│  4. 后续 Initiation 包含 cookie，证明来源真实性                     │
│                                                                      │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │                      Cookie Reply                              │ │
│  │  struct message_cookie_reply {                                │ │
│  │      __u32 receiver_index;  // 接收方 ID                     │ │
│  │      __u8 nonce[24];         // 24 字节 nonce                 │ │
│  │      __u8 encrypted_cookie[47]; // 加密的 cookie              │ │
│  │      __u8 mac1[16];          // MAC #1                        │ │
│  │      __u8 mac2[16];          // MAC #2                        │ │
│  │  };                                                         │ │
│  │                                                               │ │
│  │  encrypted_cookie = ChaCha20(                                 │ │
│  │      cookie_mac_key(IP),                                     │ │
│  │      nonce=counter,                                           │ │
│  │      "cookie----" || reply.receiver_index ||                  │ │
│  │        current_time || cookie                                 │ │
│  │  )                                                            │ │
│  └────────────────────────────────────────────────────────────────┘ │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

### 6.2 Cookie 生成与验证

```c
// cookies.c — Cookie 验证

struct cookie_checker {
    struct HMAC_SHA256_Context {
        u8 key[32];
    } mac1_key, cookie_key;
    atomic_t rate;
    struct timer_list unlock_time;
    bool has_unlocked;
};

struct cookie_packet {
    __u32 receiver_index;
    __u8 nonce[24];
    __u8 encrypted_cookie[47];
    __u8 mac1[16];
    __u8 mac2[16];
};

// 生成 Cookie
int wg_cookie_message_create(struct message_cookie_reply *reply,
                            const struct cookie_macs *macs,
                            __u32 receiver_index,
                            struct wg_device *wg)
{
    struct cookie *cookie;
    u8 cookie_mac_key[32];
    u8 reply_index[4];
    u8 timestamp[8];

    // 1. 获取当前 cookie（或生成新的）
    cookie = wg_cookie_get(&wg->cookie_state);

    // 2. 派生 MAC 密钥
    //    mac_key = HMAC(wg->cookie_checker.mac1_key,
    //                    "mac1----" || wg->device_name)
    derive_mac_key(cookie_mac_key,
                  wg->cookie_state.mac1_key,
                  "mac1----");

    // 3. 构造要加密的数据
    //    data = "cookie----" || receiver_index || timestamp || cookie
    memset(reply->encrypted_cookie, 0, 47);
    put_unaligned_le32(receiver_index, reply_index);
    put_unaligned_le64(wg_get_time_secs(), timestamp);

    memcpy(reply->encrypted_cookie, "cookie----", 8);
    memcpy(reply->encrypted_cookie + 8, reply_index, 4);
    memcpy(reply->encrypted_cookie + 12, timestamp, 8);
    memcpy(reply->encrypted_cookie + 20, cookie, 24);

    // 4. 生成 nonce
    get_random_bytes(reply->nonce, 24);

    // 5. 加密 cookie
    //    reply->encrypted_cookie = ChaCha20(cookie_key, nonce, data)
    chacha20poly1305_encrypt(&wg->cookie_state.encrypt_ctx,
                             reply->encrypted_cookie,
                             reply->encrypted_cookie, 47,
                             NULL, 0,
                             get_counter());

    // 6. 设置 receiver_index
    reply->receiver_index = receiver_index;

    // 7. 计算 MACs
    compute_mac1((struct wg_pkt *)reply, wg->device_name);
    compute_mac2((struct wg_pkt *)reply, wg->device_name);

    return 0;
}

// 验证 Cookie
bool wg_cookie_message_validate(struct message_handshake_initiation *init,
                                 struct wg_device *wg)
{
    struct cookie cookie;
    u8 cookie_mac_key[32];
    u8 data[47];
    __u64 timestamp;
    __u32 entry_index;

    // 1. 派生 cookie 密钥
    derive_mac_key(cookie_mac_key,
                  wg->cookie_state.cookie_key,
                  "cookie--");

    // 2. 解密 cookie
    memcpy(data, init->encrypted_cookie, 47);
    chacha20poly1305_decrypt(&wg->cookie_state.decrypt_ctx,
                            data, data, 47,
                            NULL, 0,
                            get_counter());

    // 3. 验证 magic
    if (memcmp(data, "cookie----", 8) != 0)
        return false;

    // 4. 验证时间戳（5 分钟内）
    timestamp = get_unaligned_le64(data + 12);
    if (wg_get_time_secs() - timestamp > 300)
        return false;

    // 5. 提取 cookie
    memcpy(cookie, data + 20, 24);

    // 6. 验证 MAC1
    //    expected = HMAC(mac1_key, initiation_without_mac)
    //    actual = initiation.mac1
    if (!verify_mac1(init, mac1_key))
        return false;

    // 7. 验证 MAC2
    //    expected = HMAC(mac2_key,
    //                    initiation_without_mac || mac1)
    if (!verify_mac2(init, mac2_key, cookie))
        return false;

    return true;
}
```

---

## 7. 密钥派生函数

### 7.1 密钥派生链

```
WireGuard 密钥派生链：

┌──────────────────────────────────────────────────────────────────────┐
│                        密钥派生流程                                  │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  1. 静态密钥（Static Key）                                           │
│     · Curve25519 生成                                               │
│     · 公钥公开，私钥保密                                             │
│     · 长期存在                                                       │
│                                                                      │
│  2. 预共享密钥（Preshared Key）                                      │
│     · 手动配置                                                       │
│     · 抗量子                                                       │
│     · 可选                                                           │
│                                                                      │
│  3. 临时密钥（Ephemeral Key）                                        │
│     · 每次握手生成                                                   │
│     · 临时使用                                                       │
│     · DH 混合                                                        │
│                                                                      │
│  4. Chain Key                                                       │
│     · HMAC(chain_key, DH_result)                                    │
│     · 每步更新                                                       │
│                                                                      │
│  5. Session Keys                                                    │
│     · sending_key = HMAC(chain_key, 1)                             │
│     · receiving_key = HMAC(chain_key, 2)                           │
│                                                                      │
│  6. 传输密钥（Transport Keys）                                       │
│     · 用于加密实际数据流量                                           │
│     · 256 位 ChaCha20 密钥                                           │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘

DKIM HMAC 链：

  chain_key_0 = HMAC(preshared_key, "Noise_IKpsk2...")
  chain_key_1 = HMAC(chain_key_0, DH(ephemeral_private, remote_static))
  chain_key_2 = HMAC(chain_key_1, DH(ephemeral_private, remote_ephemeral))

  key_1 = HMAC(chain_key_2, 1)
  key_2 = HMAC(chain_key_2, 2)
```

### 7.2 实现

```c
// noise.c — 密钥派生

static void hmac_sha256(const u8 *key, size_t key_len,
                        u8 *dst, size_t dst_len, u8 label)
{
    struct shash_desc *desc;
    struct crypto_shash *tfm;
    u8 data[64];

    tfm = crypto_alloc_shash("hmac(sha256)", 0, 0);
    desc = kmalloc(sizeof(*desc) + crypto_shash_descsize(tfm),
                   GFP_KERNEL);

    desc->tfm = tfm;
    crypto_shash_setkey(tfm, key, key_len);

    // 构造输入: label || 0
    memset(data, 0, 64);
    data[0] = label;

    crypto_shash_digest(desc, data, 64, dst);

    crypto_free_shash(tfm);
    kfree(desc);
}

// 派生会话密钥
static void derive_session_keys(struct noise_symmetric_key *sending,
                                struct noise_symmetric_key *receiving,
                                const u8 *chain_key)
{
    u8 keys[NOISE_SYMMETRIC_KEY_LEN * 2];

    // 派生两个密钥
    hmac_sha256(chain_key, NOISE_CHAIN_KEY_LEN,
               keys, NOISE_SYMMETRIC_KEY_LEN, 1);
    hmac_sha256(chain_key, NOISE_CHAIN_KEY_LEN,
               keys + NOISE_SYMMETRIC_KEY_LEN,
               NOISE_SYMMETRIC_KEY_LEN, 2);

    // 初始化 ChaCha20 上下文
    chacha20poly1305_init(&sending->send, keys);
    chacha20poly1305_init(&receiving->recv,
                          keys + NOISE_SYMMETRIC_KEY_LEN);

    memzero_explicit(keys, sizeof(keys));
}

// Curve25519 DH
static void curve25519_dh(u8 *out, const u8 *private,
                         const u8 *public)
{
    curve25519_generic(out, private, public);
}
```

---

## 8. 安全特性

### 8.1 防重放

```c
// noise.c — 防重放机制

#define REJECT_AFTER_MESSAGES (u64)(~0ULL >> 4)
#define REJECT_AFTER_TIME 180
#define REPLAY_WINDOW_SIZE 64

struct replay_filter {
    u64 bitmap;
    u64 counter;
    spinlock_t lock;
};

// 检查是否是重复包
bool wg_replay_filter(struct replay_filter *filter, u64 nonce)
{
    bool ret = false;
    u64 diff;

    spin_lock(&filter->lock);

    // nonce 太旧
    if (nonce > filter->counter)
        goto ok;

    if (nonce + REPLAY_WINDOW_SIZE < filter->counter)
        goto out;

    // 在窗口内检查
    diff = filter->counter - nonce;
    if (filter->bitmap & (1ULL << diff)) {
        goto out;  // 已收到过
    }

ok:
    // 更新 bitmap
    if (nonce > filter->counter) {
        diff = nonce - filter->counter;
        filter->bitmap = (filter->bitmap << diff) | 1;
        filter->counter = nonce;
    } else {
        filter->bitmap |= (1ULL << (filter->counter - nonce));
    }

    ret = true;

out:
    spin_unlock(&filter->lock);
    return ret;
}
```

### 8.2 密钥清除

```c
// noise.c — 密钥安全清除

void memzero_explicit(void *s, size_t count)
{
    memset(s, 0, count);
    // 防止编译器优化掉 memset
    barrier();
}

// 在释放前清除敏感数据
void wg_peer_free(struct wg_peer *peer)
{
    // 清除握手
    memzero_explicit(&peer->handshake.static_private,
                    sizeof(peer->handshake.static_private));
    memzero_explicit(&peer->handshake.chain_key,
                    sizeof(peer->handshake.chain_key));
    memzero_explicit(&peer->handshake.hash,
                    sizeof(peer->handshake.hash));

    // 清除密钥对
    if (peer->keypair.sending_key) {
        memzero_explicit(&peer->keypair.sending_key->send,
                        sizeof(peer->keypair.sending_key->send));
        memzero_explicit(&peer->keypair.sending_key->key,
                        sizeof(peer->keypair.sending_key->key));
    }

    // ...
}
```

---

## 9. 小结

```
WireGuard 加密引擎总结：

Noise 握手协议：
  · IKpsk2 模式（带预共享密钥的 Station-to-Station）
  · 静态公钥身份认证
  · 临时密钥前向保密
  · 5 个握手消息完成密钥建立

密钥派生：
  · Curve25519 DH 混合
  · HMAC-SHA256 链式派生
  · 发送/接收密钥分离
  · 64 位计数器防重放

ChaCha20-Poly1305 AEAD：
  · RFC 7539 标准实现
  · 256 位密钥，96 位 nonce
  · 128 位认证标签
  · 无硬件加速时比 AES 快 3-4x

密钥轮换：
  · 180 秒过期
  · 2^60 消息上限
  · 自动触发重新握手
  · 主动密钥轮换

Cookie 防 DoS：
  · HMAC 验证来源
  · 5 分钟有效期
  · 防止伪造握手

安全特性：
  · 密钥前向保密
  · 防重放
  · 密钥自动清除
  · 抗时序攻击

下一章预告：
  Ch3: 数据包发送路径
  - wg_xmit 入口
  - 路由查找
  - 加密队列
  - UDP 发送
```

---

## 延伸阅读

- RFC 7539: ChaCha20-Poly1305 AEAD: https://www.rfc-editor.org/rfc/rfc7539
- RFC 7746: Curve25519: https://www.rfc-editor.org/rfc/rfc7746
- Noise Protocol Framework: https://noiseprotocol.org/
- WireGuard Whitepaper: https://www.wireguard.com/papers/wireguard.pdf
- RFC 8439: ChaCha20-Poly1305 (IETF): https://www.rfc-editor.org/rfc/rfc8439
- 内核 crypto API: `Documentation/crypto/`
- LWN: "ChaCha20-Poly1305 in the kernel": https://lwn.net/
