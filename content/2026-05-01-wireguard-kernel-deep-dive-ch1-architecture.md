---
title: WireGuard 内核深度探索 Ch1：内核架构与初始化
date: 2026-05-01 09:00:00
tags:
  [
    WireGuard,
    Kernel,
    Linux,
    Source Code,
    Architecture,
    Device,
    Peer,
    Cryptokey,
    Queue,
    Init,
    Noise Protocol,
    Encryption,
    UDP,
    Netdev,
    Workqueue,
    Timer,
  ]
description: WireGuard 内核源码深度解析 Ch1：内核模块架构、核心数据结构、设备初始化、Peer 管理、Socket 绑定、加密队列与工作队列的完整流程。
---

# WireGuard 内核深度探索 Ch1：内核架构与初始化

## 1. 系列概述

```
WireGuard 内核源码深度探索系列：

  Ch1: 内核架构与初始化         ← 本章
  Ch2: 加密引擎与 Key 管理
  Ch3: 数据包发送路径
  Ch4: 数据包接收路径
  Ch5: WireGuard vs 内核网络栈
  Ch6: 生产部署与调优

前置知识（建议阅读）：
  · WireGuard 协议深度解析（87KB）
  · IPsec 协议深度解析（87KB）
  · WireGuard vs IPsec 深度对比（82KB）
```

---

## 2. 代码仓库

```bash
# WireGuard 内核源码
git clone https://git.zx2c4.com/wireguard-linux
cd wireguard-linux

# 内核版本（以 6.8 为例）
# 位于 drivers/net/wireguard/

tree drivers/net/wireguard/
```

```
wireguard/
├── Makefile
├── Kconfig
├── main.c              # 模块入口/出口
├── device.c            # 设备操作（netdev_ops）
├── socket.c            # UDP socket 管理
├── peer.c              # Peer 管理
├── peerlookup.c        # Peer 查找（hashtable）
├── queueing.c         # 数据包队列
├── ratelimiter.c      # 速率限制
├── cookies.c           # Cookie 验证
├── noise.c             # Noise 协议实现
├── messages.c          # 协议消息格式
├── allowedips.c         # 路由/AllowedIPs
├── binding.c           # 接口绑定
├── netlink.c           # Netlink 接口
└── ratelimiter.c       # 速率限制器
```

---

## 3. 核心数据结构

### 3.1 wg_device — 设备结构

```c
// device.h — 核心设备结构

struct wg_device {
    // 设备标识
    char name[IFNAMSIZ];
    struct net_device *net_dev;
    struct crypt_queue *device_queue;
    struct workqueue_struct *packet_crypt_wq;
    struct workqueue_struct *cookie_upload_wq;

    // WireGuard 消息接收
    struct socket *sock;

    // 密钥状态（Noise 协议）
    struct noise_handshake handshake;     // 静态密钥交换
    struct noise_symmetric_keys keys;     // 活跃密钥对

    // Peer 表（hashtable）
    struct pubkey_hashtable *peer_hashtable;
    struct endpoint_hashtable *endpoint_hashtable;
    struct allowedips_hashtable *allowedips_hashtable;

    // 当前活跃 peer（用于路由）
    struct wg_peer __rcu *active_peer;

    // 统计
    struct wg_device_statistics {
        __u64 tx_bytes;
        __u64 rx_bytes;
        __u64 tx_packets;
        __u64 rx_packets;
        __u64 rx_dropped;
        __u64 tx_dropped;
    } stats;

    // 序列号/计数器
    atomic64_t fwmark;
    atomic_t num_peers;

    // 引用计数（RCU）
    refcount_t refcount;

    // 锁
    spinlock_t pubkey_hash_lock;
    spinlock_t shared_keys_lock;
    struct mutex device_update_lock;

    // Netlink 通知
    struct notifier_block notifier_block;
    struct list_head device_list;
};
```

### 3.2 wg_peer — 对端结构

```c
// peer.h — Peer 结构

struct wg_peer {
    // 标识
    struct crypto_key *handshake_remote_static;
    struct noise_handshake *handshake;

    // 加密密钥
    struct noise_symmetric_keys keypair;
    atomic64_t sent_keypair_time;
    atomic64_t received_keypair_time;

    // 状态
    enum {
        WGPEER_REMOTE_KEY_VALID,
        WGPEER_SETCOOKIE_RECEIVED,
        WGPEER handshake_IN_PROGRESS,
    } remote_established:1;

    // 网络
    struct endpoint {
        union {
            struct sockaddr addr;
            struct sockaddr_in addr4;
            struct sockaddr_in6 addr6;
        };
        union inet_addr saddr4;
        int mark;
    } endpoint;

    // AllowedIPs（路由）
    struct allowedips_node *allowedips_list;

    // 数据包队列
    struct crypt_queue tx_queue;
    struct crypt_queue rx_queue;

    // 重传计时器
    struct timer_list retransmit_handshake;
    struct timer_list keepalive;

    // 统计
    struct wg_peer_statistics {
        __u64 tx_bytes;
        __u64 rx_bytes;
        __u64 last_handshake_time_sec;
        __u64 keepalive_interval_sec;
        __u64 rx_packets;
        __u64 tx_packets;
    } stats;

    // 引用计数
    refcount_t refcount;

    // 锁
    spinlock_t endpoint_lock;
    spinlock_t keypair_lock;

    // 链表
    struct list_head pubkey_hash_list;
    struct list_head endpoint_hash_list;

    // 数据包缓冲
    struct sk_buff_head incoming_handshake_queue;
};
```

### 3.3 wg_packet — 数据包结构

```c
// queueing.h — 数据包封装

struct wg_crypt_ctx {
    struct sk_buff *skb;
    struct wg_peer *peer;
    atomic_t *keypair_produced;
    struct list_head wait_list;
    unsigned long padding;
};

// 数据包状态
enum {
    WG_PACKET_CRYPTED,
    WG_PACKET_DEAD,
};

// 每个 CPU 的 crypt 队列
struct crypt_queue {
    struct wg_crypt_ctx __percpu *cpu;
    int len;
    struct {
        struct {
            u32 *ptr;
            u32 nent;
        } r;
        struct {
            u32 *ptr;
            u32 nent;
        } w;
    } hlist;
};
```

---

## 4. 模块初始化

### 4.1 模块入口

```c
// main.c — 模块入口

#include <linux/module.h>
#include <linux/init.h>
#include <linux/genetlink.h>
#include "device.h"
#include "noise.h"
#include "messages.h"
#include "peer.h"
#include "socket.h"
#include "queueing.h"
#include "cookies.h"
#include "netlink.h"
#include "ratelimiter.h"

MODULE_DESCRIPTION("WireGuard: fast, modern, secure VPN tunnel");
MODULE_LICENSE("GPL v2");
MODULE_AUTHOR("Jason A. Donenfeld <Jason@zx2c4.com>");
MODULE_VERSION("1.0.0");
MODULE_ALIAS_RTNL_LINK("wireguard");
MODULE_SOFTDEP("pre: udp_tunnel");

static int __init wg_init(void)
{
    int ret;

    pr_info("WireGuard init\n");

    // 1. 初始化 Noise 协议
    ret = noise_init();
    if (ret < 0) {
        pr_err("WireGuard: noise init failed: %d\n", ret);
        goto err_noise;
    }

    // 2. 初始化 Cookie 验证器
    ret = cookies_init();
    if (ret < 0) {
        pr_err("WireGuard: cookie init failed: %d\n", ret);
        goto err_cookies;
    }

    // 3. 初始化速率限制器
    ret = ratelimiter_init();
    if (ret < 0) {
        pr_err("WireGuard: ratelimiter init failed: %d\n", ret);
        goto err_ratelimiter;
    }

    // 4. 初始化 AllowedIPs
    ret = allowedips_init();
    if (ret < 0) {
        pr_err("WireGuard: allowedips init failed: %d\n", ret);
        goto err_allowedips;
    }

    // 5. 初始化 Peer Lookup
    ret = peerlookup_init();
    if (ret < 0) {
        pr_err("WireGuard: peerlookup init failed: %d\n", ret);
        goto err_peerlookup;
    }

    // 6. 注册 netdev ops
    ret = wg_device_init();
    if (ret < 0) {
        pr_err("WireGuard: device init failed: %d\n", ret);
        goto err_device;
    }

    // 7. 注册 genetlink 家族
    ret = wg_genetlink_init();
    if (ret < 0) {
        pr_err("WireGuard: genetlink init failed: %d\n", ret);
        goto err_genetlink;
    }

    pr_info("WireGuard loaded\n");
    return 0;

err_genetlink:
    wg_device_uninit();
err_device:
    peerlookup_uninit();
err_peerlookup:
    allowedips_uninit();
err_allowedips:
    ratelimiter_uninit();
err_ratelimiter:
    cookies_uninit();
err_cookies:
    noise_uninit();
err_noise:
    return ret;
}

static void __exit wg_exit(void)
{
    pr_info("WireGuard exit\n");

    wg_genetlink_uninit();
    wg_device_uninit();
    peerlookup_uninit();
    allowedips_uninit();
    ratelimiter_uninit();
    cookies_uninit();
    noise_uninit();

    rcu_barrier();
}

module_init(wg_init);
module_exit(wg_exit);
```

### 4.2 设备初始化

```c
// device.c — 设备操作

static const struct net_device_ops wg_netdev_ops = {
    .ndo_start_xmit = wg_xmit,
    .ndo_set_mac_address = wg_set_mac_address,
    .ndo_get_stats64 = wg_get_stats64,
    .ndo_change_mtu = wg_change_mtu,
};

static struct device_type wg_device_type = {
    .name = "wireguard",
};

int wg_device_init(void)
{
    // 注册 netdev 通知链
    register_netdevice_notifier(&wg_notifier_block);
    return 0;
}

void wg_device_uninit(void)
{
    unregister_netdevice_notifier(&wg_notifier_block);
}

// 创建设备时的回调
static int wg_newlink(struct net *src_net, struct ifinfomsg *ifi,
                      struct nlattr **tb, struct nlattr **data,
                      struct netlink_ext_ack *ack)
{
    struct wg_device *wg;
    struct net_device *dev;
    int ret;

    // 1. 分配 net_device
    dev = alloc_netdev_mqs(sizeof(*wg), name,
                            NET_NAME_UNKNOWN, wg_setup,
                            1, 1);
    if (!dev)
        return -ENOMEM;

    wg = netdev_priv(dev);
    memset(wg, 0, sizeof(*wg));

    // 2. 初始化设备名
    dev->tstats = netdev_alloc_pcpu_stats(struct pcpu_sw_netstats);
    if (!dev->tstats) {
        free_netdev(dev);
        return -ENOMEM;
    }

    // 3. 设置 netdev_ops
    dev->netdev_ops = &wg_netdev_ops;
    dev->type = ARPHRD_NONE;
    dev->flags = IFF_NOARP | IFF_POINTOPOINT | IFF_NO_PI;
    dev->hard_header_len = 0;
    dev->addr_len = 0;
    dev->mtu = ETH_DATA_LEN - AEAD_BOTTOM_HLEN;
    dev->needed_headroom = 0;
    dev->needed_tailroom = 0;

    // 4. 设置 qdisc
    dev->qdisc = &noop_qdisc;
    netif_keep_txq(dev);

    // 5. 初始化 WireGuard 特有字段
    wg->net_dev = dev;
    wg->dev = dev_net(dev);

    // 6. 初始化锁
    spin_lock_init(&wg->pubkey_hash_lock);
    spin_lock_init(&wg->shared_keys_lock);
    mutex_init(&wg->device_update_lock);
    INIT_LIST_HEAD(&wg->device_list);

    // 7. 初始化哈希表
    wg->peer_hashtable = pubkey_hashtable_alloc();
    if (!wg->peer_hashtable) {
        ret = -ENOMEM;
        goto err;
    }

    wg->endpoint_hashtable = endpoint_hashtable_alloc();
    if (!wg->endpoint_hashtable) {
        ret = -ENOMEM;
        goto err;
    }

    wg->allowedips_hashtable = allowedips_hashtable_alloc();
    if (!wg->allowedips_hashtable) {
        ret = -ENOMEM;
        goto err;
    }

    // 8. 初始化工作队列
    wg->packet_crypt_wq = alloc_workqueue("wg-crypt-%s",
                                            WQ_CPU_INTENSIVE | WQ_MEM_RECLAIM,
                                            0, dev->name);
    if (!wg->packet_crypt_wq) {
        ret = -ENOMEM;
        goto err;
    }

    wg->cookie_upload_wq = alloc_workqueue("wg-cookie-%s",
                                            WQ_FREEZABLE | WQ_MEM_RECLAIM,
                                            0, dev->name);
    if (!wg->cookie_upload_wq) {
        ret = -ENOMEM;
        goto err;
    }

    // 9. 初始化 crypto 队列
    INIT_WORK(&wg->device_work, wg_work);
    timer_setup(&wg->clear_peers_timer, wg_clear_peers_timers, 0);

    // 10. 注册设备
    ret = register_netdevice(dev);
    if (ret < 0)
        goto err;

    // 11. 添加到设备列表
    list_add(&wg->device_list, &device_list);

    return 0;

err:
    free_percpu(dev->tstats);
    free_netdev(dev);
    return ret;
}
```

### 4.3 netdev_setup

```c
// device.c — netdev setup

void wg_setup(struct net_device *dev)
{
    SET_NETDEV_DEV(dev, &init_net);
    dev->netdev_ops = &wg_netdev_ops;
    dev->priv_destructor = wg_destruct;

    dev->features |= NETIF_F_LLTX | NETIF_F_SG | NETIF_F_HW_CSUM;
    dev->features |= NETIF_F_RXCSUM | NETIF_F_NO_INIT_V6;
    dev->hw_features |= NETIF_F_HW_CSUM | NETIF_F_SG;
    dev->hw_enc_features |= NETIF_F_HW_CSUM | NETIF_F_SG;

    dev->wanted_features &= ~(NETIF_F_GSO_MASK | NETIF_F_SG);

    dev->mtu = ETH_DATA_LEN - AEAD_BOTTOM_HLEN;
    dev->type = ARPHRD_NONE;
    dev->flags &= ~(IFF_BROADCAST | IFF_MULTICAST);
    dev->flags |= IFF_NOARP | IFF_POINTOPOINT | IFF_NO_PI;
    dev->hard_header_len = 0;
    dev->addr_len = 0;
    dev->tx_queue_len = 0;
}
```

---

## 5. Socket 管理

### 5.1 Socket 创建与绑定

```c
// socket.c — Socket 管理

int wg_socket_init(struct wg_device *wg, u16 port)
{
    struct sockaddr_in sin;
    int ret;

    // 1. 创建 UDP socket
    ret = sock_create(AF_INET, SOCK_DGRAM, IPPROTO_UDP, &wg->sock);
    if (ret < 0) {
        pr_err("%s: socket create failed: %d\n", wg->name, ret);
        return ret;
    }

    // 2. 设置 SO_REUSEADDR
    sock_set_reuseaddr(wg->sock->sk);

    // 3. 绑定到指定端口（0 = 自动选择）
    memset(&sin, 0, sizeof(sin));
    sin.sin_family = AF_INET;
    sin.sin_port = htons(port);
    sin.sin_addr.s_addr = htonl(INADDR_ANY);

    ret = kernel_bind(wg->sock, (struct sockaddr *)&sin, sizeof(sin));
    if (ret < 0) {
        pr_err("%s: socket bind failed: %d\n", wg->name, ret);
        goto out;
    }

    // 4. 设置 socket 选项
    wg_socket_reinit(wg);

    // 5. 启动接收线程
    wg_socket_set_peer(wg, 0);

    return 0;

out:
    sock_release(wg->sock);
    wg->sock = NULL;
    return ret;
}

void wg_socket_reinit(struct wg_device *wg)
{
    struct sock *sk = wg->sock->sk;

    // 允许 fragment
    sk->sk_allocation = GFP_KERNEL;

    // 设置接收 buffer
    sk->sk_rcvbuf = READ_ONCE(net_unstable_rps_default);
    sk->sk_sndbuf = READ_ONCE(net_unstable_rps_default);

    // 设置 cookie 验证
    if (sk->sk_destruct != wg_sock_destruct) {
        wg->sock->sk->sk_destruct = wg_sock_destruct;
        wg->sock->sk->sk_user_data = wg;
    }

    // 设置 peer
    wg_socket_set_peer(wg, sk);
}
```

### 5.2 数据接收

```c
// socket.c — 数据接收

static void wg_socket_receive(struct sock *sk)
{
    struct wg_device *wg = sk->sk_user_data;
    struct sk_buff *skb;
    size_t len;

    // 从 socket 接收数据
    skb = skb_recv_datagram(sk, 0, 0, &len, &ret);
    if (ret < 0)
        return;

    // 设置 metadata
    skb->dev = wg->net_dev;
    skb->protocol = htons(ETH_P_IP);
    skb->pkt_type = PACKET_HOST;
    skb->skb_iif = wg->net_dev->ifindex;

    // 移除 UDP 头部（由内核处理）

    // 发送到 WireGuard 处理
    wg_received_data(wg, skb);
}

// 数据包处理入口
void wg_received_data(struct wg_device *wg, struct sk_buff *skb)
{
    struct wg_peer *peer;
    struct noise_handshake *handshake;
    struct wg_pkt *pkt = (struct wg_pkt *)skb->data;

    // 根据消息类型分发
    switch (pkt->type) {
    case WG_PKT_INITIATION:
        wg_receive_handshake_ packet(skb, wg);
        break;

    case WG_PKT_RESPONSE:
        wg_receive_handshake_packet(skb, wg);
        break;

    case WG_PKT_COOKIE_REPLY:
        wg_receive_cookie_reply(skb, wg);
        break;

    case WG_PKT_TRANSPORT_DATA:
        // 查找对应 peer
        peer = wg_lookup_peer(wg, pkt->sender_index);
        if (!peer) {
            kfree_skb(skb);
            return;
        }
        wg_receive_transport(skb, wg, peer);
        break;

    default:
        kfree_skb(skb);
    }
}
```

---

## 6. Peer 管理

### 6.1 Peer 创建

```c
// peer.c — Peer 管理

struct wg_peer *wg_peer_create(struct wg_device *wg,
                                const u8 public_key[NOISE_PUBLIC_KEY_LEN],
                                const u8 preshared_key[NOISE_SYMMETRIC_KEY_LEN])
{
    struct wg_peer *peer;

    // 1. 分配内存
    peer = kzalloc(sizeof(*peer), GFP_KERNEL);
    if (!peer)
        return NULL;

    // 2. 初始化引用计数
    refcount_set(&peer->refcount, 1);

    // 3. 初始化锁
    spin_lock_init(&peer->endpoint_lock);
    spin_lock_init(&peer->keypair_lock);

    // 4. 初始化数据包队列
    INIT_LIST_HEAD(&peer->peer_list);
    skb_queue_head_init(&peer->incoming_handshake_queue);

    // 5. 初始化握手
    if (noise_handshake_init(&peer->handshake, public_key,
                             preshared_key) < 0) {
        kfree(peer);
        return NULL;
    }

    // 6. 初始化计时器
    timer_setup(&peer->retransmit_handshake,
                wg_handshake_receive_timeout, 0);
    timer_setup(&peer->keepalive, wg_keepalive_xmit, 0);

    // 7. 插入哈希表
    wg_pubkey_hashtable_add(wg->peer_hashtable, peer);

    // 8. 添加到设备 peer 列表
    list_add_tail(&peer->peer_list, &wg->peer_list);
    atomic_inc(&wg->num_peers);

    // 9. 设置 device 引用
    peer->device = wg;

    return peer;
}
```

### 6.2 Peer 查找

```c
// peerlookup.c — Peer 查找

struct pubkey_hashtable {
    struct rhashtable ht;
};

struct endpoint_hashtable {
    struct rhashtable ht;
};

// 通过公钥查找 Peer
struct wg_peer *wg_pubkey_hashtable_lookup(struct pubkey_hashtable *table,
                                            const u8 *pubkey)
{
    // 使用 rhashtable 查找，O(1) 复杂度
    struct wg_peer *peer;
    struct pubkey_entry entry = { .pubkey = pubkey };

    rcu_read_lock();
    peer = rhashtable_lookup(&table->ht, &entry, pubkey_rhash_params);
    if (peer)
        wg_peer_get(peer);
    rcu_read_unlock();

    return peer;
}

// 通过 endpoint（IP:Port）查找 Peer
struct wg_peer *wg_endpoint_hashtable_lookup(
    struct endpoint_hashtable *table,
    const struct sockaddr *addr)
{
    struct endpoint_entry entry = {
        .addr = addr,
        .addr_len = addr->sa_family == AF_INET6 ?
                    sizeof(struct sockaddr_in6) :
                    sizeof(struct sockaddr_in)
    };

    rcu_read_lock();
    peer = rhashtable_lookup(&table->ht, &entry, endpoint_rhash_params);
    if (peer)
        wg_peer_get(peer);
    rcu_read_unlock();

    return peer;
}
```

### 6.3 Peer 生命周期

```c
// peer.c — Peer 生命周期

// 增加引用
void wg_peer_get(struct wg_peer *peer)
{
    refcount_inc(&peer->refcount);
}

// 释放引用
void wg_peer_put(struct wg_peer *peer)
{
    if (refcount_dec_and_test(&peer->refcount))
        wg_peer_free(peer);
}

// 实际释放
void wg_peer_free(struct wg_peer *peer)
{
    struct wg_device *wg = peer->device;

    // 1. 删除计时器
    del_timer_sync(&peer->retransmit_handshake);
    del_timer_sync(&peer->keepalive);

    // 2. 清理握手
    noise_handshake_clear(&peer->handshake);

    // 3. 清理密钥对
    wg_noise_keypair_put(&peer->keypair);

    // 4. 从哈希表移除
    spin_lock(&wg->pubkey_hash_lock);
    list_del_init(&peer->pubkey_hash_list);
    spin_unlock(&wg->pubkey_hash_lock);

    spin_lock(&peer->endpoint_lock);
    list_del_init(&peer->endpoint_hash_list);
    spin_unlock(&peer->endpoint_lock);

    // 5. 清理 AllowedIPs
    allowedips_remove_by_peer(&wg->allowedips_hashtable, peer);

    // 6. 释放数据包队列
    skb_queue_purge(&peer->incoming_handshake_queue);
    wg_queue_crypto_queues_peer(peer);

    // 7. 从列表移除
    list_del_init(&peer->peer_list);
    atomic_dec(&wg->num_peers);

    // 8. 释放内存
    kfree_sensitive(peer);
}
```

---

## 7. 加密队列

### 7.1 队列结构

```c
// queueing.c — 队列管理

struct wg_crypt_queue {
    struct wg_device *wg;
    struct crypt_queue queue;
    struct work_struct work;
};

struct crypt_queue {
    struct wg_crypt_ctx __percpu *cpu;
    struct list_head list;
    atomic_t state;
#ifdef CONFIG_BPF_SYSCALL
    struct xdp_mem_info mem;
#endif
    unsigned int len_max;
    struct wait_queue_head wait;
    atomic_t pending;
};

// 每个 CPU 的上下文
struct wg_crypt_ctx {
    struct sk_buff *skb;
    struct wg_peer *peer;
    struct list_head list;
    atomic_t *keypair_produced;
    struct wg_crypt_ctx *next;
};
```

### 7.2 队列初始化

```c
// queueing.c — 队列初始化

int wg_queue_crypto_init(void)
{
    int ret, cpu;

    // 初始化发送队列
    for_each_possible_cpu(cpu) {
        struct wg_crypt_ctx *ctx;

        ctx = per_cpu_ptr(send_crypto.ctx, cpu);
        ctx->next = NULL;
    }

    // 初始化接收队列
    ret = crypt_queue_init(&receiving_queue, wg_receive,
                           MAX_STAGGERED_MTU);
    if (ret < 0)
        return ret;

    return 0;
}

static int crypt_queue_init(struct crypt_queue *queue,
                             void (*callback)(struct work_struct *),
                             unsigned int len_max)
{
    int ret;

    queue->len_max = len_max;
    INIT_LIST_HEAD(&queue->list);
    init_waitqueue_head(&queue->wait);
    atomic_set(&queue->pending, 0);

    ret = ptr_ring_init(&queue->ring, len_max, GFP_KERNEL);
    if (ret < 0)
        return ret;

    return 0;
}
```

### 7.3 数据包入队

```c
// queueing.c — 数据包入队

void wg_queue_crypto(struct wg_device *wg, struct wg_peer *peer,
                     struct sk_buff *skb, struct wg_crypt_ctx *ctx)
{
    int cpu;

    // 1. 选择目标 CPU（软路由）
    cpu = wg_cpumask_next(wg->crypt_queue.selected);

    // 2. 获取当前 CPU 的 crypt_ctx
    ctx = per_cpu_ptr(send_crypto.ctx, cpu);

    // 3. 设置上下文
    ctx->skb = skb;
    ctx->peer = peer;

    // 4. 入队
    spin_lock(&queue->lock);
    list_add_tail(&ctx->list, &queue->list);
    if (queue->len >= queue->len_max) {
        kfree_skb(skb);
        goto out;
    }
    ++queue->len;
    spin_unlock(&queue->lock);

    // 5. 触发工作队列
    queue_work_on(cpu, wg->packet_crypt_wq,
                  &per_cpu_ptr(wg->crypt_queue.cpu, cpu)->work);
}
```

---

## 8. 工作队列

### 8.1 packet_crypt_wq

```c
// queueing.c — 加密工作队列

static void wg_packet_encrypt(struct work_struct *work)
{
    struct wg_crypt_ctx *ctx = container_of(work, typeof(*ctx), work);
    struct sk_buff *skb = ctx->skb;
    struct wg_peer *peer = ctx->peer;
    struct wg_device *wg = peer->device;

    // 1. 获取密钥对
    struct noise_symmetric_key *keypair;
    spin_lock(&peer->keypair_lock);
    keypair = &peer->keypair;
    if (!keypair->is_valid) {
        // 密钥无效，排队等待
        spin_unlock(&peer->keypair_lock);
        wg_queue_handshake(peer, false);
        goto out;
    }
    spin_unlock(&peer->keypair_lock);

    // 2. 加密数据包
    if (wg_encrypt(skb, keypair) < 0) {
        ++wg->stats.tx_dropped;
        goto out;
    }

    // 3. 发送到网络
    wg_socket_send_buffer(wg, peer, skb);

    ++peer->stats.tx_packets;
    wg->stats.tx_bytes += skb->len;

out:
    wg_peer_put(peer);
    skb_gro_remcsum_process(skb, -ctx->padding);
    list_del_init(&ctx->list);
}
```

### 8.2 cookie_upload_wq

```c
// cookies.c — Cookie 上传工作队列

static void wg_cookie_packet_work(struct work_struct *work)
{
    struct wg_peer *peer = container_of(work, typeof(*peer),
                                         cookie_check_work);
    struct wg_device *wg = peer->device;

    // 发送 cookie reply
    if (wg_cookie_packet_append(&peer->latest_cookie,
                                 &peer->endpoint, wg) < 0)
        wg_peer_put(peer);

    wg_peer_put(peer);
}
```

---

## 9. 初始化时序图

```
WireGuard 模块初始化时序：

[insmod]
    │
    ▼
┌──────────────────────────────────────────────────────────────────┐
│  wg_init()                                                       │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  1. noise_init()           → 初始化 Noise 协议                    │
│     │                      → 分配 handshake 缓存                │
│     │                                                               │
│  2. cookies_init()        → 初始化 Cookie 验证器                  │
│     │                      → 设置 MAC key                         │
│     │                                                               │
│  3. ratelimiter_init()    → 初始化速率限制器                      │
│     │                      → 分配 bucket                         │
│     │                                                               │
│  4. allowedips_init()     → 初始化 AllowedIPs                     │
│     │                      → 分配 patricia trie                   │
│     │                                                               │
│  5. peerlookup_init()     → 初始化 Peer 哈希表                     │
│     │                      → rhashtable                          │
│     │                                                               │
│  6. wg_device_init()      → 注册 netdev notifier                  │
│     │                                                               │
│  7. wg_genetlink_init()  → 注册 genetlink 家族                   │
│     │                                                               │
│     ▼                                                               │
│  [模块加载完成]                                                    │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌──────────────────────────────────────────────────────────────────┐
│  ip link add wg0 type wireguard                                  │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  wg_newlink()                                                    │
│     │                                                            │
│     ▼                                                            │
│  1. alloc_netdev()        → 分配 net_device                      │
│     │                      → 分配 wg_device                       │
│     │                                                               │
│  2. wg_setup()            → 设置 netdev_ops                      │
│     │                      → 设置 features                        │
│     │                                                               │
│  3. pubkey_hashtable_alloc()  → 分配 Pubkey 哈希表                │
│     │                                                               │
│  4. endpoint_hashtable_alloc() → 分配 Endpoint 哈希表            │
│     │                                                               │
│  5. allowedips_hashtable_alloc() → 分配 AllowedIPs trie          │
│     │                                                               │
│  6. alloc_workqueue("wg-crypt-%s")  → 创建加密工作队列            │
│     │                                                               │
│  7. alloc_workqueue("wg-cookie-%s") → 创建 Cookie工作队列         │
│     │                                                               │
│  8. register_netdevice()   → 注册网络设备                         │
│     │                                                               │
│     ▼                                                               │
│  [设备创建完成]                                                    │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌──────────────────────────────────────────────────────────────────┐
│  wg set wg0 listen-port 51820 private-key /path/to/private.key  │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  wg_set_device() (via netlink)                                   │
│     │                                                            │
│     ▼                                                            │
│  1. wg_socket_init()        → 创建 UDP socket                    │
│     │                      → 绑定到指定端口                       │
│     │                      → 设置 socket callbacks               │
│     │                                                               │
│  2. wg_noise_set_private_key()  → 加载私钥                        │
│     │                      → 初始化 DH                           │
│     │                                                               │
│     ▼                                                               │
│  [Socket 绑定完成]                                                │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌──────────────────────────────────────────────────────────────────┐
│  wg set wg0 peer <pubkey> allowed-ips 10.0.0.0/24               │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  wg_set_peer() (via netlink)                                     │
│     │                                                            │
│     ▼                                                            │
│  1. wg_peer_create()        → 创建 Peer                          │
│     │                      → 初始化握手                          │
│     │                      → 设置计时器                          │
│     │                                                               │
│  2. allowedips_insert()     → 添加到 AllowedIPs                   │
│     │                      → 插入 patricia trie                  │
│     │                                                               │
│  3. pubkey_hashtable_add() → 添加到 Pubkey 哈希表                 │
│     │                                                               │
│     ▼                                                               │
│  [Peer 创建完成]                                                  │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

---

## 10. 内存布局

```
WireGuard 内存布局（每设备）：

┌─────────────────────────────────────────────────────────────────┐
│                      wg_device                                  │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │  char name[IFNAMSIZ]              // "wg0"                  ││
│  │  struct net_device *net_dev        // 指向 net_device       ││
│  │  struct socket *sock               // UDP socket           ││
│  │  struct crypt_queue *device_queue   // 设备加密队列         ││
│  │  struct workqueue_struct *packet_crypt_wq  // 加密工作队列   ││
│  │  struct workqueue_struct *cookie_upload_wq // Cookie 队列    ││
│  │  struct noise_handshake handshake  // 握手状态              ││
│  │  struct pubkey_hashtable *peer_hashtable  // Peer 查找      ││
│  │  atomic_t num_peers                // Peer 数量             ││
│  │  refcount_t refcount               // 引用计数              ││
│  └─────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────┐
│                      wg_peer (每个 Peer)                        │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │  struct noise_handshake handshake  // 握手状态（200+ 字节） ││
│  │  struct noise_symmetric_keys keypair  // 加密密钥对         ││
│  │  struct endpoint endpoint            // 远端地址           ││
│  │  struct allowedips_node *allowedips_list // 路由           ││
│  │  struct crypt_queue tx_queue           // 发送队列          ││
│  │  struct crypt_queue rx_queue           // 接收队列          ││
│  │  struct timer_list retransmit_handshake // 重传计时器      ││
│  │  struct timer_list keepalive            // keepalive 计时器││
│  │  struct sk_buff_head incoming_queue      // 待处理握手包    ││
│  │  refcount_t refcount                     // 引用计数        ││
│  └─────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────┐
│                      Noise Handshake                            │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │  u8 static_private[NOISE_DH25519_PRIVATE_LEN]  // 32B    ││
│  │  u8 static_public[NOISE_DH25519_PUBLIC_LEN]   // 32B     ││
│  │  u8 ephemeral_private[NOISE_DH25519_PRIVATE_LEN] // 32B   ││
│  │  u8 ephemeral_public[NOISE_DH25519_PUBLIC_LEN]  // 32B    ││
│  │  u8 preshared_key[NOISE_SYMMETRIC_KEY_LEN]    // 32B     ││
│  │  u8 chain_key[NOISE_CHAIN_KEY_LEN]            // 32B     ││
│  │  u8 hash[NOISE_HASH_LEN]                      // 32B      ││
│  │  u8 session_id[NOISE_HASH_LEN]               // 32B      ││
│  │  // 总计：~224 字节                                              ││
│  └─────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────┐
│                      Symmetric Keys                            │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │  struct chacha20poly1305_ctx send  // 发送密钥              ││
│  │  struct chacha20poly1305_ctx recv  // 接收密钥              ││
│  │  atomic64_t send_nonce              // 发送序列号           ││
│  │  atomic64_t recv_nonce              // 接收序列号           ││
│  │  u64 send_counter                  // 发送计数器           ││
│  │  u64 recv_counter                   // 接收计数器           ││
│  │  bool is_valid                      // 密钥有效标志        ││
│  └─────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────┘
```

---

## 11. 调试接口

```bash
# 查看 WireGuard 设备
ip link show wg0
ip -br addr show wg0

# 查看 peers
wg show wg0
wg show wg0 dump  # 详细信息

# 查看统计
wg show wg0 transfer

# 内核日志
dmesg | grep WireGuard
dmesg -w | grep WireGuard

# tracepoints
cat /sys/kernel/debug/tracing/available_events | grep wireguard
cat /sys/kernel/debug/tracing/trace | grep WireGuard

# BPF 调试（如果有）
bpftool prog show | grep wireguard
bpftool map show | grep wireguard

# 查看设备队列
cat /proc/net/wireguard/wg0

# netlink 调试
ip -.detail link show wg0
```

---

## 12. 小结

```
WireGuard 内核架构总结：

模块结构：
  · main.c：入口/出口
  · device.c：netdev 操作
  · socket.c：UDP socket 管理
  · peer.c：Peer 生命周期
  · peerlookup.c：Peer 查找（哈希表）
  · noise.c：Noise 协议实现
  · messages.c：协议消息格式
  · queueing.c：数据包队列
  · cookies.c：Cookie 验证
  · allowedips.c：路由表

核心数据结构：
  · wg_device：整个 VPN 设备
  · wg_peer：每个对端
  · noise_handshake：握手状态
  · noise_symmetric_keys：加密密钥对
  · wg_crypt_ctx：加密上下文

初始化流程：
  1. 模块加载 → noise/cookies/ratelimiter/allowedips/peerlookup init
  2. 设备创建 → alloc_netdev + wg_setup + register_netdevice
  3. Socket 绑定 → socket() + bind() + socket callbacks
  4. Peer 添加 → wg_peer_create + allowedips_insert

性能特性：
  · O(1) Peer 查找（rhashtable）
  · per-CPU 加密队列
  · 工作队列异步处理
  · RCU 锁优化

下一章预告：
  Ch2: 加密引擎与 Key 管理
  - Noise 握手详解
  - 密钥对生成与销毁
  - ChaCha20-Poly1305 实现
  - 密钥轮换机制
```

---

## 延伸阅读

- WireGuard 官网: https://www.wireguard.com/
- WireGuard 源码: https://git.zx2c4.com/wireguard-linux/
- WireGuard 论文: "WireGuard: Next Generation Kernel Network Tunnel"
- Noise 协议框架: https://noiseprotocol.org/
- 内核源码: `Documentation/networking/wireguard.rst`
- LWN 系列: "WireGuard in the kernel": https://lwn.net/Articles/842385/
- Jason Donenfeld (WireGuard 作者) 博客
