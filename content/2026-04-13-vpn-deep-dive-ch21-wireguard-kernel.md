---
title: "VPN 技术深度探索 (二十一)：WireGuard 内核实现"
date: 2026-04-13
tags: [vpn, series, wireguard, kernel, linux, device-driver]
description: "WireGuard Linux 内核实现深度解析——device.c 设备管理、peer.c 对等体管理、timers.c 定时器机制、allowedips.c 路由查找、noise.c 握手协议、queueing.c 数据包队列"
---

> [!info] VPN 技术深度探索系列 0. [[2026-04-13-vpn-deep-dive-series-index|全栈学习路径总览]]
>
> 1. [[2026-04-13-vpn-deep-dive-ch1-vpn-fundamentals|VPN 基础概念]]
> 2. [[2026-04-13-vpn-deep-dive-ch18-ipsec-troubleshooting|第十八章：IPSec 排错]]
> 3. [[2026-04-13-vpn-deep-dive-ch19-wireguard-protocol|第十九章：WireGuard 协议详解]]
> 4. [[2026-04-13-vpn-deep-dive-ch20-wireguard-crypto|第二十章：WireGuard 密码学]]
> 5. **第二十一章：WireGuard 内核实现**
> 6. [[2026-04-13-vpn-deep-dive-ch22-wireguard-config|第二十二章：WireGuard 配置部署]]
> 7. [[2026-04-13-vpn-deep-dive-ch23-wireguard-cloud|第二十三章：WireGuard 云端方案]]

---

## 1. 内核实现架构概述

### 1.1 代码结构

WireGuard 内核实现位于 `drivers/net/wireguard/`，约 4,000 行代码：

```
┌─────────────────────────────────────────────────────────────────┐
│                 WireGuard 内核模块文件结构                        │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  核心文件:                                                       │
│  ├─ device.c / device.h       # 网络设备注册、接口管理           │
│  ├─ peer.c / peer.h           # 对等体管理、生命周期             │
│  ├─ noise.c / noise.h         # Noise 握手协议实现                │
│  ├─ messages.h                # 消息格式定义                      │
│  ├─ allowedips.c / allowedips.h # IP → Peer 路由查找            │
│  ├─ timers.c / timers.h       # 定时器管理                        │
│  ├─ cookie.c / cookie.h       # Cookie 防 DoS 机制               │
│  ├─ receive.c                 # 数据包接收                        │
│  ├─ send.c                    # 数据包发送                        │
│  ├─ socket.c / socket.h       # UDP 套接字管理                    │
│  ├─ queueing.c / queueing.h   # 数据包队列管理                   │
│  ├─ peerlookup.c / peerlookup.h # 公钥哈希表查找                  │
│  ├─ netlink.c / netlink.h    # 用户空间配置接口                  │
│  ├─ ratelimiter.c / ratelimiter.h # 速率限制                     │
│  └─ main.c                    # 模块初始化                       │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 1.2 核心数据结构

```
┌─────────────────────────────────────────────────────────────────┐
│                 WireGuard 核心数据结构                           │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  struct wg_device: 设备结构                                      │
│  ├─ struct net_device *dev      # Linux 网络设备               │
│  ├─ struct crypt_queue           # 加密/解密/握手队列           │
│  ├─ struct sock *sock4, *sock6  # UDP 套接字                    │
│  ├─ struct noise_static_identity # 本机静态密钥                 │
│  ├─ struct pubkey_hashtable     # 公钥 → Peer 哈希表           │
│  ├─ struct index_hashtable      # 索引 → Peer 哈希表           │
│  ├─ struct allowedips            # AllowedIPs 路由表           │
│  └─ struct list_head peer_list  # 对等体列表                   │
│                                                                 │
│  struct wg_peer: 对等体结构                                      │
│  ├─ struct wg_device *device    # 所属设备                      │
│  ├─ struct noise_handshake      # 握手状态                      │
│  ├─ struct noise_keypairs       # 当前/上/下一个密钥对          │
│  ├─ struct endpoint             # 对端地址                      │
│  ├─ struct sk_buff_head         # 发送/接收队列                 │
│  ├─ 定时器: retransmit / keepalive / zero_keymaterial          │
│  └─ struct allowedips_node      # 在 AllowedIPs 中的节点        │
│                                                                 │
│  struct noise_handshake: 握手状态                                │
│  ├─ enum noise_handshake_state # 握手状态机                     │
│  ├─ u8 ephemeral_private        # 临时私钥                      │
│  ├─ u8 remote_static / remote_ephemeral # 对方公钥              │
│  ├─ u8 hash, chaining_key       # Noise 状态                    │
│  └─ struct noise_static_identity # 本机静态密钥引用              │
│                                                                 │
│  struct noise_keypair: 密钥对                                    │
│  ├─ struct noise_symmetric_key sending  # 发送密钥              │
│  ├─ struct noise_symmetric_key receiving # 接收密钥             │
│  ├─ atomic64_t sending_counter  # 发送计数器                   │
│  ├─ struct noise_replay_counter  # 防重放位图                   │
│  └─ __le32 remote_index         # 对方索引                      │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 2. device.c 设备管理

### 2.1 设备初始化

WireGuard 在 Linux 中注册为网络设备驱动：

```c
// device.c - 设备初始化流程
static int __init wg_init(void)
{
    int ret;

    // 初始化各子系统
    wg_noise_init();           // Noise 协议
    wg_allowedips_slab_init(); // AllowedIPs Slab 缓存
    wg_packet_queue_init();    // 数据包队列
    wg_peer_slab_init();       // Peer Slab 缓存
    wg_cookie_slab_init();     // Cookie Slab 缓存

    // 注册网络设备驱动
    ret = register_netdevice_notifier(&wg_netdevice_notifier);
    ret = register_pernet_subsys(&wg_net_ops);

    return 0;
}
```

### 2.2 wg_device 结构

```c
// device.h - 核心设备结构
struct wg_device {
    struct net_device *dev;                    // Linux 网络设备
    struct crypt_queue encrypt_queue,           // 加密队列
                      decrypt_queue,           // 解密队列
                      handshake_queue;         // 握手队列

    struct sock __rcu *sock4, *sock6;          // UDP 套接字 (IPv4/IPv6)

    struct noise_static_identity static_identity; // 本机静态密钥

    // 工作队列
    struct workqueue_struct *packet_crypt_wq;     // 数据包加密
    struct workqueue_struct *handshake_receive_wq; // 握手接收
    struct workqueue_struct *handshake_send_wq;   // 握手发送

    struct cookie_checker cookie_checker;       // Cookie 检查器

    // 哈希表
    struct pubkey_hashtable *peer_hashtable;    // 公钥 → Peer
    struct index_hashtable *index_hashtable;    // 索引 → Peer

    // AllowedIPs 路由表
    struct allowedips peer_allowedips;

    // 锁
    struct mutex device_update_lock;     // 设备更新锁
    struct mutex socket_update_lock;     // 套接字更新锁

    struct list_head device_list;        // 设备链表
    struct list_head peer_list;          // Peer 链表

    atomic_t handshake_queue_len;        // 握手队列长度
    u32 fwmark;                         // fwmark 标记
};
```

### 2.3 数据包接收流程

```
┌─────────────────────────────────────────────────────────────────────────┐
│                      数据包接收流程                                      │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  UDP Socket 接收 ──▶ wg_receive()                                       │
│                            │                                             │
│                            ▼                                             │
│                    解析 Message Header                                  │
│                            │                                             │
│              ┌─────────────┼─────────────┐                             │
│              ▼             ▼             ▼                              │
│         Type 1?        Type 2?        Type 4?                          │
│         (Init)         (Resp)         (Data)                           │
│              │             │             │                              │
│              ▼             ▼             ▼                              │
│     wg_noise_handshake_  wg_noise_handshake_  wg_noise_                 │
│     consume_initiation() consume_response()  received_with_keypair()   │
│              │             │             │                              │
│              │             │             ▼                              │
│              │             │      解密数据包                          │
│              │             │             │                              │
│              │             │             ▼                              │
│              │             │      路由查找                              │
│              │             │      (AllowedIPs)                         │
│              │             │             │                              │
│              │             │             ▼                              │
│              │             │      写入 tun 设备                        │
│              │             │             │                              │
│              └─────────────┴─────────────┘                             │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 3. peer.c 对等体管理

### 3.1 Peer 创建与销毁

```c
// peer.c - Peer 创建
struct wg_peer *wg_peer_create(struct wg_device *wg,
                               const u8 public_key[NOISE_PUBLIC_KEY_LEN],
                               const u8 preshared_key[NOISE_SYMMETRIC_KEY_LEN])
{
    struct wg_peer *peer = wg_peer_slab_alloc();

    // 初始化字段
    peer->device = wg;
    peer->internal_id = atomic64_inc_return(&wg->device_peer_id);

    // 初始化握手
    wg_noise_handshake_init(&peer->handshake, &wg->static_identity,
                           public_key, preshared_key, peer);

    // 初始化密钥对
    wg_noise_keypairs_init(&peer->keypairs);

    // 初始化队列
    skb_queue_head_init(&peer->staged_packet_queue);

    // 初始化定时器
    timer_setup(&peer->timer_retransmit_handshake, ...);
    timer_setup(&peer->timer_send_keepalive, ...);
    timer_setup(&peer->timer_new_handshake, ...);
    timer_setup(&peer->timer_zero_key_material, ...);
    timer_setup(&peer->timer_persistent_keepalive, ...);

    // 添加到设备列表和哈希表
    list_add_tail(&peer->peer_list, &wg->peer_list);
    pubkey_hashtable_add(wg->peer_hashtable, peer);

    return peer;
}
```

### 3.2 Peer 引用计数

WireGuard 使用 **kref** 实现安全的引用计数：

```c
// peer.h - 引用计数
struct wg_peer {
    // ...
    struct kref refcount;    // 引用计数
    struct rcu_head rcu;     // RCU 回调
    // ...
};

// 获取引用
static inline struct wg_peer *wg_peer_get(struct wg_peer *peer)
{
    kref_get(&peer->refcount);
    return peer;
}

// 释放引用
void wg_peer_put(struct wg_peer *peer)
{
    kref_put(&peer->refcount, wg_peer_destroy);
}

// 销毁 Peer（最终回调）
static void wg_peer_destroy(struct kref *refcount)
{
    struct wg_peer *peer = container_of(refcount, struct wg_peer, refcount);

    // 清除握手
    wg_noise_handshake_clear(&peer->handshake);

    // 清除密钥对
    wg_noise_keypairs_clear(&peer->keypairs);

    // 移除定时器
    del_timer_sync(&peer->timer_retransmit_handshake);
    del_timer_sync(&peer->timer_send_keepalive);
    del_timer_sync(&peer->timer_new_handshake);
    del_timer_sync(&peer->timer_zero_key_material);
    del_timer_sync(&peer->timer_persistent_keepalive);

    // 移除出哈希表
    pubkey_hashtable_remove(peer->device->peer_hashtable, peer);

    // 从 AllowedIPs 移除
    wg_allowedips_remove_by_peer(&peer->device->peer_allowedips, peer);

    // 释放内存
    wg_peer_slab_free(peer);
}
```

---

## 4. noise.c 握手协议实现

### 4.1 握手状态机

WireGuard Noise 握手有 5 个状态：

```
┌─────────────────────────────────────────────────────────────────┐
│                    Noise 握手状态机                               │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  enum noise_handshake_state:                                   │
│                                                                 │
│  ┌──────────────────┐                                          │
│  │ HANDSHAKE_ZEROED │ ← 初始状态                               │
│  └────────┬─────────┘                                          │
│           │ wg_noise_handshake_create_initiation()              │
│           ▼                                                     │
│  ┌──────────────────────────┐                                   │
│  │ HANDSHAKE_CREATED_INITIATION │ ← 已发送 Initiation         │
│  └────────┬──────────────────┘                                   │
│           │ wg_noise_handshake_consume_initiation()             │
│           ▼                                                     │
│  ┌──────────────────────────────┐                               │
│  │ HANDSHAKE_CONSUMED_INITIATION │ ← 已收到并处理 Initiation  │
│  └────────┬──────────────────────┘                               │
│           │ wg_noise_handshake_create_response()                 │
│           ▼                                                     │
│  ┌─────────────────────────┐                                     │
│  │ HANDSHAKE_CREATED_RESPONSE │ ← 已发送 Response              │
│  └────────┬────────────────┘                                      │
│           │ wg_noise_handshake_consume_response()               │
│           ▼                                                     │
│  ┌──────────────────────────────┐                               │
│  │ HANDSHAKE_CONSUMED_RESPONSE  │ ← 已收到并处理 Response     │
│  └────────┬──────────────────────┘                               │
│           │ wg_noise_handshake_begin_session()                  │
│           ▼                                                     │
│      Session Started ← 切换到加密会话                            │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 4.2 发起握手

```c
// noise.c - 创建 Initiation 消息
bool wg_noise_handshake_create_initiation(
    struct message_handshake_initiation *dst,
    struct noise_handshake *handshake)
{
    // 1. 生成临时密钥对
    curve25519_generate_secret(handshake->ephemeral_private);
    curve25519_mult(handshake->ephemeral_public,
                   handshake->ephemeral_private, curve25519_basepoint);

    // 2. 计算 DH
    u8 dh_result[32];
    curve25519_mult(dh_result, handshake->ephemeral_private,
                   handshake->remote_static);
    // → DH1 = e_i * R

    // 3. 派生中间密钥
    u8 chaining_key[32], hash[32];
    blake2s_init(chaining_key, 32);
    blake2s_update(chaining_key, ...);  // 初始化
    // KDF(DH1) → chaining_key, hash

    // 4. 加密静态公钥
    struct chacha20poly1305_ctx ctx;
    chacha20poly1305_setkey(&ctx, chaining_key, ...);
    chacha20poly1305_encrypt(dst->encrypted_static,
                            &ctx,
                            handshake->static_identity->static_public);

    // 5. 填充消息
    dst->header.type = MESSAGE_HANDSHAKE_INITIATION;
    dst->ephemeral = handshake->ephemeral_public;
    // ...

    return true;
}
```

### 4.3 密钥对管理

```c
// noise.h - 密钥对结构
struct noise_keypair {
    struct index_hashtable_entry entry;

    struct noise_symmetric_key sending;   // 发送密钥
    atomic64_t sending_counter;           // 发送计数器

    struct noise_symmetric_key receiving; // 接收密钥
    struct noise_replay_counter receiving_counter; // 防重放

    __le32 remote_index;      // 对方索引
    bool i_am_the_initiator;  // 是否为发起方

    struct kref refcount;     // 引用计数
    struct rcu_head rcu;
};

// noise.c - 密钥对初始化
struct noise_keypairs {
    struct noise_keypair __rcu *current_keypair;   // 当前使用
    struct noise_keypair __rcu *previous_keypair;    // 上一密钥对
    struct noise_keypair __rcu *next_keypair;        // 下一个密钥对
    spinlock_t keypair_update_lock;
};
```

### 4.4 防重放计数器

```c
// noise.h - 防重放计数器
struct noise_replay_counter {
    u64 counter;              // 最后一个接收的计数器
    spinlock_t lock;
    unsigned long backtrack[COUNTER_BITS_TOTAL / BITS_PER_LONG];
    // 8192 位 = 256 字节的位图
};

// messages.h - 计数器常量
enum counter_values {
    COUNTER_BITS_TOTAL = 8192,
    COUNTER_REDUNDANT_BITS = BITS_PER_LONG,
    COUNTER_WINDOW_SIZE = COUNTER_BITS_TOTAL - COUNTER_REDUNDANT_BITS
    // 滑动窗口大小: 8192 - 64 = 8128 位
};
```

---

## 5. allowedips.c 路由查找

### 5.1 路由数据结构

WireGuard 使用 **基数树 (Radix Tree)** 实现高效的 IP 路由查找：

```c
// allowedips.h - AllowedIPs 节点
struct allowedips_node {
    struct wg_peer __rcu *peer;    // 指向的对等体
    struct allowedips_node __rcu *bit[2]; // 子节点
    u8 cidr;                        // CIDR 前缀长度
    u8 bit_at_a, bit_at_b;          // 位位置
    u8 bitlen;                      // IP 长度 (4 或 16)
    u8 bits[16] __aligned(__alignof(u64)); // IP 地址/前缀

    union {
        struct list_head peer_list; // 在 Peer 的链表中的节点
        struct rcu_head rcu;        // RCU 释放
    };
};

// allowedips.h - AllowedIPs 表
struct allowedips {
    struct allowedips_node __rcu *root4;  // IPv4 根节点
    struct allowedips_node __rcu *root6;  // IPv6 根节点
    u64 seq;                              // 序列号（用于锁-free RCU）
};
```

### 5.2 基数树查找

```
┌─────────────────────────────────────────────────────────────────────────┐
│                      AllowedIPs 基数树查找                               │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  示例：添加以下 AllowedIPs:                                             │
│  - Peer A: 10.0.0.0/24                                                │
│  - Peer B: 10.0.0.5/32                                                │
│  - Peer C: 192.168.1.0/24                                             │
│                                                                         │
│  树结构:                                                               │
│  ┌─────────────────────────────────────────────────────────────────┐  │
│  │                                                                 │  │
│  │                        root                                     │  │
│  │                          │                                      │  │
│  │              ┌───────────┴───────────┐                         │  │
│  │              │                       │                         │  │
│  │            bit=10                  bit=192                   │  │
│  │              │                       │                         │  │
│  │      ┌───────┴───────┐                 │                         │  │
│  │      │               │            bit=168                     │  │
│  │   bit=0          bit=0             (Peer C)                   │  │
│  │      │               │                                          │  │
│  │   Peer A      ┌─────┴─────┐                                    │  │
│  │  (10.0.0/24)  │           │                                     │  │
│  │            bit=5       bit=5                                    │  │
│  │              │           │                                      │  │
│  │           Peer A     Peer B                                    │  │
│  │         (10.0.0/24) (10.0.0.5/32)                            │  │
│  │                                                                 │  │
│  └─────────────────────────────────────────────────────────────────┘  │
│                                                                         │
│  查找 10.0.0.5 时:                                                     │
│  1. 从根开始，按位查找                                                  │
│  2. 10 → 右子树 (192.168.x.x)                                          │
│  3. 0 → 左子树 (10.x.x.x)                                              │
│  4. 0 → 左子树                                                        │
│  5. 0 → 左子树                                                        │
│  6. 0 → 右子树                                                        │
│  7. 5 → 右子树 (Peer B)                                               │
│  8. 找到 10.0.0.5/32 → Peer B                                         │
│                                                                         │
│  复杂度: O(32) for IPv4, O(128) for IPv6                               │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 5.4 插入与删除

```c
// allowedips.c - 插入 IPv4
int wg_allowedips_insert_v4(struct allowedips *table,
                            const struct in_addr *ip,
                            u8 cidr, struct wg_peer *peer,
                            struct mutex *lock)
{
    // 1. 锁定
    mutex_lock(lock);

    // 2. 遍历/创建路径
    struct allowedips_node **pos = &table->root4;
    for (int i = 0; i < cidr; ++i) {
        int bit = (ip->s_addr >> (31 - (i % 8))) & 1;
        if (!*pos) {
            // 创建新节点
            *pos = kzalloc(...);
            INIT_RCU_HEAD(&(*pos)->rcu);
        }
        pos = &(*pos)->bit[bit];
    }

    // 3. 设置叶子节点
    if (*pos == NULL)
        *pos = kzalloc(...);
    (*pos)->peer = wg_peer_get(peer);
    (*pos)->cidr = cidr;

    // 4. 解锁
    mutex_unlock(lock);

    return 0;
}
```

---

## 6. timers.c 定时器机制

### 6.1 定时器类型

WireGuard 为每个 Peer 维护 5 个定时器：

```c
// peer.h - Peer 定时器
struct wg_peer {
    // ...
    struct timer_list timer_retransmit_handshake; // 握手重传
    struct timer_list timer_send_keepalive;        // 发送 keepalive
    struct timer_list timer_new_handshake;          // 新握手
    struct timer_list timer_zero_key_material;       // 清除密钥材料
    struct timer_list timer_persistent_keepalive;    // 持久 keepalive

    u16 persistent_keepalive_interval;  // keepalive 间隔
    // ...
};
```

### 6.2 定时器功能

```
┌─────────────────────────────────────────────────────────────────────────┐
│                      WireGuard 定时器机制                                │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  1. timer_retransmit_handshake (握手重传)                              │
│     ├─ 触发: 发送 Initiation 后未收到 Response                         │
│     ├─ 间隔: REKEY_TIMEOUT + jitter = 5s + 随机抖动                   │
│     ├─ 重试: 最多 MAX_TIMER_HANDSHAKES = 90/5 = 18 次                  │
│     └─ 超时: 放弃，清除 staged packets，设置 timer_zero_key_material   │
│                                                                         │
│  2. timer_send_keepalive (发送 keepalive)                               │
│     ├─ 触发: 收到数据包但超过 KEEPALIVE_TIMEOUT (10s) 未发送           │
│     ├─ 动作: 发送空的加密数据包                                        │
│     └─ 目的: 维持 NAT 映射                                             │
│                                                                         │
│  3. timer_new_handshake (发起新握手)                                    │
│     ├─ 触发: 发送数据包后超过 KEEPALIVE_TIMEOUT + REKEY_TIMEOUT 未收到 │
│     ├─ 动作: 发起新的握手                                              │
│     └─ 目的: 确保连接活跃                                              │
│                                                                         │
│  4. timer_zero_key_material (清除密钥材料)                               │
│     ├─ 触发: REJECT_AFTER_TIME * 3 = 180 * 3 = 540s 未收到新密钥      │
│     ├─ 动作: 清除所有密钥对                                            │
│     └─ 目的: 确保旧密钥材料被及时清除                                  │
│                                                                         │
│  5. timer_persistent_keepalive (持久 keepalive)                         │
│     ├─ 触发: 用户配置 PersistentKeepalive                              │
│     ├─ 间隔: 用户指定（默认 25s）                                      │
│     └─ 动作: 发送空的加密数据包                                        │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 6.3 定时器实现

```c
// timers.c - 握手重传定时器
static void wg_expired_retransmit_handshake(struct timer_list *timer)
{
    struct wg_peer *peer = from_timer(peer, timer,
                                      timer_retransmit_handshake);

    if (peer->timer_handshake_attempts > MAX_TIMER_HANDSHAKES) {
        // 重试次数用尽
        pr_debug("Handshake failed after %d attempts\n",
                MAX_TIMER_HANDSHAKES);

        // 清除待发送数据包
        wg_packet_purge_staged_packets(peer);

        // 设置清除密钥材料的定时器
        if (!timer_pending(&peer->timer_zero_key_material))
            mod_timer(&peer->timer_zero_key_material,
                      jiffies + REJECT_AFTER_TIME * 3 * HZ);
        return;
    }

    // 重试握手
    wg_peer_get(peer);
    if (!queue_work(peer->device->handshake_send_wq,
                    &peer->transmit_handshake_work))
        wg_peer_put(peer);

    // 更新重试计数
    peer->timer_handshake_attempts++;

    // 调度下一次重传 (5s + 随机抖动)
    mod_peer_timer(peer, timer,
                  jiffies + REKEY_TIMEOUT +
                  prandom_u32_max(REKEY_TIMEOUT_JITTER_MAX_JIFFIES));
}
```

---

## 7. 数据包队列与处理

### 7.1 队列结构

WireGuard 使用多核并行处理：

```c
// device.h - 加密队列
struct crypt_queue {
    struct ptr_ring ring;                    // 环形缓冲区
    struct multicore_worker __percpu *worker; // 每 CPU 工作线程
    int last_cpu;                            // 上次使用的 CPU
};

// peer.h - Peer 队列
struct wg_peer {
    struct prev_queue tx_queue, rx_queue;  // 发送/接收队列
    struct sk_buff_head staged_packet_queue; // 待加密数据包队列
    // ...
};
```

### 7.2 数据包处理流程

```
┌─────────────────────────────────────────────────────────────────────────┐
│                      数据包加密流程                                      │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  应用 ──▶ 路由 ──▶ wg_xmit()                                            │
│                                    │                                    │
│                                    ▼                                    │
│                           查找 AllowedIPs                              │
│                                    │                                    │
│                                    ▼                                    │
│                    获取 Peer 的 current_keypair                         │
│                                    │                                    │
│                          ┌─────────┴─────────┐                         │
│                          │  keypair 有效?   │                         │
│                          └─────────┬─────────┘                         │
│                           否        │        是                        │
│                            │         ▼                                │
│                            │    加密数据包                              │
│                            │    (ChaCha20-Poly1305)                    │
│                            │         │                                │
│                            │         ▼                                │
│                            │    放入 crypt_queue                       │
│                            │         │                                │
│                            │         ▼                                │
│                            │    每 CPU worker 加密                     │
│                            │         │                                │
│                            │         ▼                                │
│                            │    发送到 socket                          │
│                            │         │                                │
│                            │         │                                │
│                            ▼         ▼                                │
│              无效密钥 ──▶ 发起握手 ──▶ 放入 staged_queue               │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 8. 数据流总览

### 8.1 完整数据流

```
┌─────────────────────────────────────────────────────────────────────────┐
│                      WireGuard 完整数据流                               │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  发送方向 (Tx):                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐  │
│  │                                                                 │  │
│  │  应用数据                                                        │  │
│  │      │                                                          │  │
│  │      ▼                                                          │  │
│  │  内核协议栈 (路由查找)                                           │  │
│  │      │                                                          │  │
│  │      ▼                                                          │  │
│  │  wg_xmit() ──▶ AllowedIPs 查找 ──▶ 获取 Peer                    │  │
│  │      │                                                          │  │
│  │      ▼                                                          │  │
│  │  检查/更新密钥对                                                 │  │
│  │      │                                                          │  │
│  │      ▼                                                          │  │
│  │  ChaCha20-Poly1305 加密 (内核 crypto)                          │  │
│  │      │                                                          │  │
│  │      ▼                                                          │  │
│  │  发送到 UDP Socket                                               │  │
│  │      │                                                          │  │
│  │      ▼                                                          │  │
│  │  Outer IP + UDP + WireGuard Header + 密文                       │  │
│  │                                                                 │  │
│  └─────────────────────────────────────────────────────────────────┘  │
│                                                                         │
│  接收方向 (Rx):                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐  │
│  │                                                                 │  │
│  │  UDP 数据包                                                      │  │
│  │      │                                                          │  │
│  │      ▼                                                          │  │
│  │  UDP Socket ──▶ wg_receive()                                    │  │
│  │      │                                                          │  │
│  │      ▼                                                          │  │
│  │  解析 WireGuard Header                                          │  │
│  │      │                                                          │  │
│  │      ▼                                                          │  │
│  │  Type 4 (数据)? ──▶ 解密 ──▶ 写入 tun 设备                     │  │
│  │      │                                                          │  │
│  │  Type 1/2 (握手)? ──▶ handshake_queue ──▶ Noise 处理            │  │
│  │      │                                                          │  │
│  │  Type 3 (Cookie)? ──▶ 处理 Cookie                               │  │
│  │                                                                 │  │
│  └─────────────────────────────────────────────────────────────────┘  │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 8.2 与 OpenVPN 的架构对比

```
┌─────────────────────────────────────────────────────────────────┐
│              WireGuard vs OpenVPN 内核架构对比                   │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  OpenVPN (用户态):                                               │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │                                                         │   │
│  │   tun 设备 ──▶ 内核 ──▶ 用户态 OpenVPN ──▶ 内核 ──▶ NIC │   │
│  │       │              │              │              │        │   │
│  │    拷贝 1         拷贝 2         加密           拷贝 3       │   │
│  │                   上下文切换                           │        │   │
│  │                                                         │   │
│  │   4 次拷贝 + 上下文切换 + 用户态加密                    │   │
│  │                                                         │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│  WireGuard (内核态):                                            │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │                                                         │   │
│  │   tun 设备 ──▶ WireGuard 内核模块 ──▶ NIC               │   │
│  │       │              │              │                      │   │
│  │       │         直接 skb          无拷贝                   │   │
│  │       │         内核加密                                 │   │
│  │                                                         │   │
│  │   0 次拷贝 + 0 次上下文切换                             │   │
│  │                                                         │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 9. 总结

### 9.1 内核实现要点

```
WireGuard Linux 内核实现要点：

┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│  1. 设备管理 (device.c):                                        │
│     ├─ 注册为网络设备驱动                                       │
│     ├─ 使用工作队列并行处理                                      │
│     └─ 管理 UDP Socket                                          │
│                                                                 │
│  2. 对等体管理 (peer.c):                                        │
│     ├─ kref 引用计数                                            │
│     ├─ RCU 机制安全释放                                         │
│     └─ 5 个定时器管理连接状态                                   │
│                                                                 │
│  3. 握手协议 (noise.c):                                         │
│     ├─ 5 状态握手状态机                                         │
│     ├─ Curve25519 DH                                            │
│     └─ ChaCha20-Poly1305 加密                                  │
│                                                                 │
│  4. 路由查找 (allowedips.c):                                     │
│     ├─ 基数树实现 O(1) 查找                                     │
│     ├─ 支持 IPv4/IPv6                                           │
│     └─ RCU 安全更新                                             │
│                                                                 │
│  5. 定时器 (timers.c):                                          │
│     ├─ 握手重传 / keepalive / 密钥清除                         │
│     └─ 抖动防止同步                                              │
│                                                                 │
│  6. 性能优化:                                                   │
│     ├─ 每 CPU 工作队列                                          │
│     ├─ 零拷贝直接访问 skb                                       │
│     └─ RCU 减少锁竞争                                           │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 9.2 代码量对比

|| 项目 | 代码量 | 说明 |
||------|--------|------|
| WireGuard 内核 | ~4,000 行 | 包括所有核心功能 |
| OpenVPN | ~100,000 行 | 用户态 VPN |
| IPSec (内核) | ~400,000 行 | Linux 内核 IPSec |

---

## 外部参考

- [WireGuard 内核源码](https://git.zx2c4.com/wireguard-linux)
- [WireGuard 网站](https://www.wireguard.com/)
- [Linux 内核网络设备驱动文档](https://www.kernel.org/doc/html/latest/networking/device_drivers.html)
