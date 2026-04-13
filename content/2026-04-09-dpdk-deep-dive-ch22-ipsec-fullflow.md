---
title: "DPDK 深度探索 (二十二)：IPsec 完整处理流程与 SAD/SPD"
date: 2026-04-09
tags: [dpdk, series, ipsec, sad, spd, esp, ah, sa, tunnel, transport]
description: "深入理解 IPsec 完整处理流程——ESP/AH 协议、SAD 安全关联数据库、SPD 安全策略数据库、Tunnel/Transport 模式、IPsec 卸载"
---

> [!info] DPDK 深度探索系列
> 0. [[2026-04-09-dpdk-deep-dive-series-index|全栈学习路径总览]]
> 1-21. 前二十二章已完成
> 22. **第二十二章：IPsec 完整处理流程与 SAD/SPD**

---

## 1. 概述：IPsec 协议栈

### 1.1 IPsec 体系结构

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            IPsec 体系结构                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌──────────────────────────────────────────────────────────────────────┐ │
│  │                       IPsec 协议栈                                    │ │
│  │                                                                       │ │
│  │   ┌─────────────────────────────────────────────────────────────┐   │ │
│  │   │                    安全策略 (SPD)                             │   │ │
│  │   │              Security Policy Database                       │   │ │
│  │   │   ─────────────────────────────────────────────────────     │   │ │
│  │   │   Rule: Permit traffic from 10.0.0.0/8 to 192.168.0.0/16    │   │ │
│  │   │   Rule: Drop all other traffic                               │   │ │
│  │   └─────────────────────────────────────────────────────────────┘   │ │
│  │                                 │                                     │ │
│  │                                 ▼                                     │ │
│  │   ┌─────────────────────────────────────────────────────────────┐   │ │
│  │   │                    安全关联 (SAD)                             │   │ │
│  │   │               Security Association Database                 │   │ │
│  │   │   ─────────────────────────────────────────────────────     │   │ │
│  │   │   SA: SPI=0x1234, AES-256-GCM, 192.168.1.1 ←→ 10.0.0.1     │   │ │
│  │   │   SA: SPI=0x5678, AES-128-CBC+SHA256, 192.168.1.2 ←→ ...  │   │ │
│  │   └─────────────────────────────────────────────────────────────┘   │ │
│  │                                 │                                     │ │
│  │                                 ▼                                     │ │
│  │   ┌─────────────────────────────────────────────────────────────┐   │ │
│  │   │                    协议层                                    │   │ │
│  │   │   ┌─────────────────┐         ┌─────────────────┐           │   │ │
│  │   │   │      ESP        │         │       AH        │           │   │ │
│  │   │   │ (Encrypted)    │         │   (Auth Only)  │           │   │ │
│  │   │   └─────────────────┘         └─────────────────┘           │   │ │
│  │   │          │                            │                       │   │ │
│  │   └──────────┼────────────────────────────┼───────────────────┘   │ │
│  │              │                            │                           │ │
│  │              ▼                            ▼                           │ │
│  │   ┌─────────────────────────────────────────────────────────────┐   │ │
│  │   │                      IP 层                                    │   │ │
│  │   └─────────────────────────────────────────────────────────────┘   │ │
│  │                                                                       │ │
│  └───────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 1.2 ESP vs AH

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         ESP vs AH 协议对比                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ESP (Encapsulating Security Payload)                                      │
│  ──────────────────────────────────────────                                │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐  │
│  │ Original IP Header │ ESP Header │ Encrypted Payload │ ESP Trailer │ ESP ICV │  │
│  │                     │ SPI|Seq#   │ (Data)           │ Pad|PadLen|NH│ (Auth)  │  │
│  └─────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
│  功能:                                                                      │
│  - 加密: 机密性 (AES, 3DES, ChaCha20)                                      │
│  - 认证: 数据完整性 + 抗重放 (HMAC-SHA*, AES-GCM)                         │
│  - 加密和认证可选组合                                                       │
│                                                                             │
│  AH (Authentication Header)                                               │
│  ─────────────────────────────────                                        │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐  │
│  │ Original IP Header │ AH Header │ Authentication Data (ICV)       │  │
│  │                     │ NextHdr|SPI|Seq#|Auth Data                   │  │
│  └─────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
│  功能:                                                                      │
│  - 认证: 数据完整性 + 抗重放 (不含 IP 头可变字段)                          │
│  - 不加密: 无机密性                                                        │
│                                                                             │
│  场景选择:                                                                │
│  - 需要加密: ESP (推荐)                                                    │
│  - 仅需认证: AH (较少使用)                                                  │
│  - 最高安全: ESP+AH (开销大，不常用)                                      │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 1.3 Tunnel vs Transport 模式

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        Tunnel vs Transport 模式                           │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  Transport 模式 (端到端)                                                   │
│  ─────────────────────────────                                             │
│                                                                             │
│  原始数据包:                                                               │
│  │ IP Src │ TCP │ Data │                                              │
│                                                                             │
│  ESP Transport 加密后:                                                    │
│  │ IP Src │ ESP Header │ TCP │ Data │ ESP Trailer │ ESP ICV │          │
│  │ ←────────────── 加密 (不含新 IP 头) ──────────────→ │ ← Auth ─→ │   │
│                                                                             │
│  用途: VM → VM, Host → Host (同一网络内)                                  │
│                                                                             │
│  Tunnel 模式 (网关到网关)                                                 │
│  ──────────────────────────                                               │
│                                                                             │
│  原始数据包:                                                               │
│  │ Inner IP Src │ Inner TCP │ Data │                                   │
│                                                                             │
│  ESP Tunnel 加密后:                                                       │
│  │ Outer IP Src → Dst │ ESP Header │ Inner IP │ TCP │ Data │ ESP Trl │ ESP ICV │  │
│  │ ←────────────────── 新 IP 头 ──────────────────→ │ ← 加密+认证 ──→ │   │
│                                                                             │
│  用途: VPN 网关, Site-to-Site, 跨公网传输                                  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. SAD 安全关联数据库

### 2.1 SA 结构

```c
// lib/ipsec/rte_ipsec_sad.h

// 安全关联 (SA) 结构
struct rte_ipsec_sa {
    uint32_t spi;                         // Security Parameters Index

    // 方向
    uint32_t direction:1;                 // 0 = inbound, 1 = outbound

    // 协议
    uint32_t proto:4;                     // ESP or AH

    // 模式
    uint32_t mode:4;                      // Tunnel or Transport

    // 算法标识
    uint32_t cipher_algo:8;               // AES-CBC, AES-GCM, etc
    uint32_t auth_algo:8;                 // SHA-HMAC, AES-GCM, etc

    // 密钥 (敏感)
    uint8_t cipher_key[64];               // 加密密钥
    uint8_t auth_key[64];                 // 认证密钥
    uint8_t cipher_key_len;              // 密钥长度
    uint8_t auth_key_len;

    // IV/Nonce
    uint8_t salt;                         // GCM salt

    // ESN (Extended Sequence Number)
    uint32_t esn:1;
    uint64_t window_size;                // Anti-replay window

    // 生命周期
    uint64_t soft_bytes;                 // 软限制
    uint64_t hard_bytes;                 // 硬限制 (触发删除)
    uint64_t soft_packets;
    uint64_t hard_packets;

    // 序列号
    uint64_t seq;                        // 当前序列号
    uint32_t seq_mask;                   // 序列号溢出掩码

    // DPDK cryptodev session
    void *crypto_session;
    void *crypto_session_pool;

    // DPDK eventdev (可选)
    uint8_t evt_queue_id;
};

// SA 标识 (用于查找)
struct rte_ipsec_sa_id {
    uint32_t spi;                        // SPI
    uint32_t proto;                      // ESP or AH
    uint32_t dst_ip[4];                 // 目标 IP (IPv4/IPv6)
};
```

### 2.2 SAD 表结构

```c
// SAD 表实现

// SAD 表条目
struct rte_ipsec_sad_entry {
    struct rte_ipsec_sa_id id;           // SA 标识
    struct rte_ipsec_sa *sa;             // SA 指针

    // 冲突链 (同一个 SPI+dst_ip 的多个 SA)
    struct rte_ipsec_sad_entry *next;
};

// SAD 表配置
struct rte_ipsec_sad_config {
    int socket_id;                        // NUMA 节点

    // 表大小 (2 的幂)
    uint32_t nb_entries;

    // 查找类型
    uint32_t reserved:24;
    uint32_t lookup_types:8;             // RTE_IPSEC_SAD_LOOKUP_*

    // 可选: 期望的 SA 数量
    uint32_t expected_sa_num;
};

// SAD 表
struct rte_ipsec_sad {
    // 表结构
    struct rte_ipsec_sad_entry **table;  // 桶表
    uint32_t nb_entries;                  // 表大小
    uint32_t max_entries;                // 最大条目数

    // SPI + dst_ip 复合查找
    struct rte_rib_ipv4 *ipv4_rib;       // 或使用 RIB 结构
    struct rte_rib_ipv6 *ipv6_rib;

    // 统计
    uint64_t hits;
    uint64_t misses;
};

// 创建 SAD 表
struct rte_ipsec_sad *
rte_ipsec_sad_create(const char *name,
                      const struct rte_ipsec_sad_config *config)
{
    struct rte_ipsec_sad *sad;

    // 分配内存 (使用 hugepage)
    size_t size = sizeof(*sad) +
                  config->nb_entries * sizeof(void *);
    sad = rte_zmalloc_socket("ipsec_sad", size,
                              RTE_CACHE_LINE_SIZE,
                              config->socket_id);

    // 初始化
    sad->nb_entries = config->nb_entries;

    // 创建 RIB (路由信息库) 用于查找
    if (config->lookup_types & RTE_IPSEC_SAD_LOOKUP_SPI_DST_IP) {
        // SPI + dst_ip 复合查找
        sad->ipv4_rib = rte_rib4_create(name, socket_id, nb_entries);
        sad->ipv6_rib = rte_rib6_create(name, socket_id, nb_entries);
    }

    return sad;
}
```

### 2.3 SA 查找

```c
// SAD 查找 (Inbound 处理)

// 查找 key
struct rte_ipsec_sa *
rte_ipsec_sad_lookup(struct rte_ipsec_sad *sad,
                     const struct rte_ipsec_sa_id *id)
{
    struct rte_ipsec_sad_entry *entry;
    uint64_t key;

    // 构建查找 key: dst_ip << 32 | spi
    if (id->proto == RTE_IPSEC_PROTO_ESP) {
        // ESP
        key = ((uint64_t)id->dst_ip[0]) << 32 | id->spi;
    }

    // 查找
    entry = sad_find_entry(sad, key);

    if (entry)
        return entry->sa;

    // 未找到
    sad->misses++;
    return NULL;
}

// SAD 查找实现 (使用 RIB)
static inline struct rte_ipsec_sad_entry *
sad_find_entry(struct rte_ipsec_sad *sad, uint64_t key)
{
    // 简化实现: 直接哈希表查找
    uint32_t bucket = rte_hash_hash(sad->hash_table, &key);
    struct rte_ipsec_sad_entry *entry = sad->table[bucket];

    while (entry) {
        if (entry->id.spi == (key & 0xFFFFFFFF) &&
            entry->id.dst_ip == (key >> 32)) {
            sad->hits++;
            return entry;
        }
        entry = entry->next;
    }

    return NULL;
}
```

---

## 3. SPD 安全策略数据库

### 3.1 SPD 条目结构

```c
// lib/ipsec/rte_ipsec_spd.h

// 安全策略条目 (SPE - Security Policy Entry)
struct rte_ipsec_spd_entry {
    // 优先级 (数值越小优先级越高)
    uint32_t priority;

    // 匹配条件
    struct {
        uint32_t src_ip;                  // 源 IP (IPv4)
        uint32_t src_ip_mask;             // 源 IP 掩码
        uint32_t dst_ip;                  // 目标 IP
        uint32_t dst_ip_mask;             // 目标 IP 掩码

        uint16_t src_port_low;            // 源端口范围
        uint16_t src_port_high;
        uint16_t dst_port_low;           // 目标端口范围
        uint16_t dst_port_high;

        uint8_t proto;                    // 协议 (TCP/UDP/ICMP/ANY)
        uint8_t userdata;                // 用户数据
    } match;

    // 处理动作
    enum rte_ipsec_spd_action {
        RTE_IPSEC_SPD_DROP,              // 丢弃
        RTE_IPSEC_SPD_PASS,              // 跳过 IPsec
        RTE_IPSEC_SPD_PROTECT,           // 使用 SA 保护
        RTE_IPSEC_SPD_BYPASS,            // 绕过 (管理流量)
        RTE_IPSEC_SPD_DISCARD,           // 丢弃 (明确的)
    } action;

    // 关联的 SA (用于 PROTECT 动作)
    struct rte_ipsec_sa *sa;

    // 统计
    uint64_t packet_count;
    uint64_t byte_count;
};

// SPD 表
struct rte_ipsec_spd {
    // 条目数组 (按优先级排序)
    struct rte_ipsec_spd_entry *entries;
    uint32_t nb_entries;
    uint32_t max_entries;

    // 命中统计
    uint64_t total_hits;
};

// 处理方向
enum rte_ipsec_spd_dir {
    RTE_IPSEC_SPD_INBOUND,               // 入站
    RTE_IPSEC_SPD_OUTBOUND,              // 出站
};
```

### 3.2 SPD 查找与匹配

```c
// SPD 查找 (最长匹配)

// 比较函数
static inline int
spd_entry_match(const struct rte_ipsec_spd_entry *entry,
                const struct rte_mbuf *m,
                uint8_t proto,
                uint32_t src_ip, uint32_t dst_ip,
                uint16_t src_port, uint16_t dst_port)
{
    // 检查协议
    if (entry->match.proto != proto && entry->match.proto != 0)
        return 0;  // 不匹配

    // 检查源 IP
    if ((src_ip & entry->match.src_ip_mask) !=
        (entry->match.src_ip & entry->match.src_ip_mask))
        return 0;

    // 检查目标 IP
    if ((dst_ip & entry->match.dst_ip_mask) !=
        (entry->match.dst_ip & entry->match.dst_ip_mask))
        return 0;

    // 检查源端口 (如果指定)
    if (entry->match.src_port_low != 0 ||
        entry->match.src_port_high != 0xFFFF) {
        if (src_port < entry->match.src_port_low ||
            src_port > entry->match.src_port_high)
            return 0;
    }

    // 检查目标端口
    if (entry->match.dst_port_low != 0 ||
        entry->match.dst_port_high != 0xFFFF) {
        if (dst_port < entry->match.dst_port_low ||
            dst_port > entry->match.dst_port_high)
            return 0;
    }

    return 1;  // 匹配
}

// SPD 查找 (最长匹配)
static inline enum rte_ipsec_spd_action
spd_lookup(struct rte_ipsec_spd *spd,
           const struct rte_mbuf *m,
           struct rte_ipsec_sa **sa)
{
    // 解析 IP 头
    struct ipv4_hdr *iph = rte_pktmbuf_mtod(m, struct ipv4_hdr *);
    uint32_t src_ip = iph->src_addr;
    uint32_t dst_ip = iph->dst_addr;
    uint8_t proto = iph->next_proto_id;

    // 解析传输层头 (TCP/UDP)
    uint16_t src_port = 0, dst_port = 0;
    if (proto == IPPROTO_TCP || proto == IPPROTO_UDP) {
        uint8_t *l4 = (uint8_t *)(iph + 1);
        src_port = (l4[0] << 8) | l4[1];
        dst_port = (l4[2] << 8) | l4[3];
    }

    // 按优先级遍历 (从高到低)
    struct rte_ipsec_spd_entry *best_match = NULL;
    uint32_t best_priority = UINT32_MAX;

    for (uint32_t i = 0; i < spd->nb_entries; i++) {
        struct rte_ipsec_spd_entry *entry = &spd->entries[i];

        if (spd_entry_match(entry, m, proto,
                            src_ip, dst_ip, src_port, dst_port)) {
            // 记录最长匹配 (优先级最低 = 最高优先级)
            if (entry->priority < best_priority) {
                best_match = entry;
                best_priority = entry->priority;
            }
        }
    }

    if (best_match) {
        best_match->packet_count++;
        if (sa)
            *sa = best_match->sa;
        return best_match->action;
    }

    // 默认: 丢弃
    return RTE_IPSEC_SPD_DROP;
}
```

### 3.3 SPD 配置示例

```c
// 配置 SPD

// 添加 SPD 条目
int
spd_add_entry(struct rte_ipsec_spd *spd,
              const struct rte_ipsec_spd_entry *entry)
{
    if (spd->nb_entries >= spd->max_entries)
        return -ENOSPC;

    // 复制条目
    spd->entries[spd->nb_entries++] = *entry;

    // 重新排序 (按优先级)
    qsort(spd->entries, spd->nb_entries,
          sizeof(struct rte_ipsec_spd_entry),
          compare_priority);

    return 0;
}

// 示例: 配置 site-to-site VPN
void
configure_spd(struct rte_ipsec_spd *spd)
{
    struct rte_ipsec_sa *sa1, *sa2;

    // 创建 SA
    sa1 = create_sa(ESP, TUNNEL,
                    0x12345678,  // SPI
                    10.0.0.1, 10.0.0.2,  // Tunnel endpoints
                    aes_256_gcm_key, sizeof(aes_256_gcm_key));

    // 添加 SPD 条目: 允许 192.168.1.0/24 → 192.168.2.0/24
    struct rte_ipsec_spd_entry entry1 = {
        .priority = 100,
        .match = {
            .src_ip = RTE_IPV4(192, 168, 1, 0),
            .src_ip_mask = RTE_IPV4(255, 255, 255, 0),
            .dst_ip = RTE_IPV4(192, 168, 2, 0),
            .dst_ip_mask = RTE_IPV4(255, 255, 255, 0),
            .proto = 0,  // ANY
        },
        .action = RTE_IPSEC_SPD_PROTECT,
        .sa = sa1,
    };
    spd_add_entry(spd, &entry1);

    // 添加 SPD 条目: 允许 ICMP (ping)
    struct rte_ipsec_spd_entry entry2 = {
        .priority = 200,
        .match = {
            .src_ip = RTE_IPV4(0, 0, 0, 0),
            .src_ip_mask = 0,
            .dst_ip = RTE_IPV4(0, 0, 0, 0),
            .dst_ip_mask = 0,
            .proto = IPPROTO_ICMP,
        },
        .action = RTE_IPSEC_SPD_PASS,
        .sa = NULL,
    };
    spd_add_entry(spd, &entry2);

    // 默认: 丢弃所有
    struct rte_ipsec_spd_entry default_entry = {
        .priority = UINT32_MAX,
        .action = RTE_IPSEC_SPD_DROP,
    };
    spd_add_entry(spd, &default_entry);
}
```

---

## 4. ESP 协议详解

### 4.1 ESP 头结构

```c
// ESP 头格式

struct esp_hdr {
    uint32_t spi;            // Security Parameters Index
    uint32_t seq;           // Sequence Number
    // 加密载荷开始
};

struct esp_tailer {
    uint8_t pad_len;        // Padding Length (0-255)
    uint8_t next_header;    // Next Header (IPPROTO_TCP, etc)
    // Authentication Data (ICV) 可选
};

// ESP packet layout
// ─────────────────────
//
// Transport mode:
// │ Orig IP Hdr │ ESP Hdr │ TCP | Data | ESP Tlr │ ESP ICV │


// Tunnel mode:
// │ New IP Hdr │ ESP Hdr │ Orig IP Hdr | TCP | Data | ESP Tlr │ ESP ICV │
```

### 4.2 ESP 加密处理

```c
// ESP 加密流程 (Outbound)

// 构建 ESP packet
struct rte_mbuf *
esp_outbound(struct rte_mbuf *pkt,
             struct rte_ipsec_sa *sa)
{
    uint8_t *esp_hdr;
    uint8_t *esp_tlr;
    uint8_t *iv;
    uint16_t pad_len, align_len;

    // 计算填充长度 (使总长度对齐到 4 字节)
    uint16_t payload_len = rte_pktmbuf_pkt_len(pkt);
    pad_len = (4 - (payload_len + 2) % 4) % 4;  // +2 for pad_len + next_header
    align_len = payload_len + pad_len + 2;

    // 预置 ESP 头
    esp_hdr = (uint8_t *)rte_pktmbuf_prepend(pkt, sizeof(struct esp_hdr));
    esp_hdr[0] = (sa->spi >> 24) & 0xFF;
    esp_hdr[1] = (sa->spi >> 16) & 0xFF;
    esp_hdr[2] = (sa->spi >> 8) & 0xFF;
    esp_hdr[3] = sa->spi & 0xFF;

    // 序列号
    uint32_t seq = rte_atomic32_fetch_add(&sa->seq, 1);
    esp_hdr[4] = (seq >> 24) & 0xFF;
    esp_hdr[5] = (seq >> 16) & 0xFF;
    esp_hdr[6] = (seq >> 8) & 0xFF;
    esp_hdr[7] = seq & 0xFF;

    // 生成 IV (对于 CBC 模式)
    if (sa->cipher_algo == RTE_CRYPTO_CIPHER_AES_CBC) {
        iv = rte_pktmbuf_prepend(pkt, 16);
        rte_rand(iv, 16);
    } else if (sa->cipher_algo == RTE_CRYPTO_CIPHER_AES_GCM) {
        // GCM: 4-byte salt + 8-byte counter (隐式 IV)
        iv = rte_pktmbuf_prepend(pkt, 8);
        rte_rand(iv, 8);  // ESP IV
    }

    // 追加 ESP trailer
    esp_tlr = (uint8_t *)rte_pktmbuf_append(pkt, pad_len + 2);
    memset(esp_tlr, 0, pad_len);  // 填充
    esp_tlr[pad_len] = pad_len;
    esp_tlr[pad_len + 1] = IPPROTO_IPIP;  // Next Header (Tunnel mode = IP)

    // 发送到 cryptodev 加密
    return cryptodev_encrypt(pkt, sa);
}
```

### 4.3 ESP 解密处理

```c
// ESP 解密流程 (Inbound)

// 解析 ESP 头
static int
esp_inbound_parse(struct rte_mbuf *pkt,
                  struct esp_hdr **hdr,
                  uint32_t *spi,
                  uint32_t *seq)
{
    uint8_t *data = rte_pktmbuf_mtod(pkt, uint8_t *);

    // 定位 ESP 头 (在 IP 头之后)
    struct ipv4_hdr *iph = (struct ipv4_hdr *)data;
    uint8_t *esp_data = data + (iph->version_ihl & 0x0F) * 4;

    *hdr = (struct esp_hdr *)esp_data;
    *spi = rte_be_to_cpu_32((*hdr)->spi);
    *seq = rte_be_to_cpu_32((*hdr)->seq);

    return 0;
}

// ESP 入站处理
struct rte_mbuf *
esp_inbound(struct rte_mbuf *pkt,
            struct rte_ipsec_sa **sa_ptr)
{
    struct esp_hdr *hdr;
    uint32_t spi, seq;
    struct rte_ipsec_sa *sa;

    // 解析 ESP 头
    esp_inbound_parse(pkt, &hdr, &spi, &seq);

    // SAD 查找
    struct rte_ipsec_sa_id said = {
        .spi = spi,
        .proto = RTE_IPSEC_PROTO_ESP,
        .dst_ip = /* 从 IP 头提取 */,
    };
    sa = rte_ipsec_sad_lookup(sad, &said);
    if (!sa) {
        // 未找到 SA，丢弃
        rte_pktmbuf_free(pkt);
        return NULL;
    }

    // 检查序列号 (抗重放)
    if (anti_replay_check(sa, seq) < 0) {
        rte_pktmbuf_free(pkt);
        return NULL;
    }

    // 发送到 cryptodev 解密
    int ret = cryptodev_decrypt(pkt, sa);
    if (ret < 0) {
        rte_pktmbuf_free(pkt);
        return NULL;
    }

    // 移除 ESP 头和 trailer
    remove_esp_hdr_trl(pkt, hdr);

    *sa_ptr = sa;
    return pkt;
}
```

---

## 5. 抗重放机制

### 5.1 滑动窗口

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           抗重放滑动窗口                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  序列号: 0 ─────────────────────────────────────────────────────► MAX     │
│          │                                                            │     │
│          │                                                            │     │
│  窗口:   │███████████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░│     │
│          │                                                            │     │
│          ↑ lower    ↑ new                ↑ upper                      │     │
│                   (最新接收)            (窗口边界)                      │     │
│                                                                             │
│  Window Size = 64 (典型值)                                                 │
│                                                                             │
│  接收包 Seq = 100:                                                         │
│  ─────────────────                                                         │
│  - 如果 lower < 100 < upper: 检查 bitmap[100-lower]                        │
│    - bitmap[100-lower] == 0: 接收，标记为 1                                │
│    - bitmap[100-lower] == 1: 重复，丢弃                                   │
│  - 如果 100 <= lower: 过期，丢弃                                          │
│  - 如果 100 >= upper: 扩展窗口                                            │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 5.2 实现

```c
// Anti-replay 检查

struct anti_replay_window {
    uint64_t lower;              // 窗口下界 (已接收最小序列号)
    uint64_t bitmap[64];         // 位图 (64*64 = 4096 bits = 窗口大小)
    uint32_t size;               // 窗口大小 (bits)
};

// ESN (Extended Sequence Number)
struct esn {
    uint32_t low;               // 低 32 位
    uint32_t high;              // 高 32 位 (溢出时递增)
};

// 检查序列号
static inline int
anti_replay_check(struct rte_ipsec_sa *sa,
                  uint32_t seq)
{
    struct anti_replay_window *window = &sa->replay_window;
    uint64_t seq64;

    if (sa->esn) {
        // Extended Sequence Number
        // 从低 32 位和 SA 状态推导完整序列号
        seq64 = (((uint64_t)sa->esn_high) << 32) | seq;
    } else {
        seq64 = seq;
    }

    // 检查序列号范围
    if (seq64 <= window->lower) {
        // 过期包 (在窗口左侧)
        return -1;
    }

    if (seq64 >= window->lower + window->size) {
        // 新包 (在窗口右侧)，扩展窗口
        uint64_t delta = seq64 - window->lower - window->size + 1;

        // 左移窗口
        for (uint32_t i = 0; i < 64 && delta > 0; i++) {
            // 处理位图
        }

        window->lower = seq64 - window->size + 1;
    }

    // 在窗口内: 检查位图
    uint32_t offset = (uint32_t)(seq64 - window->lower);
    uint32_t word = offset / 64;
    uint32_t bit = offset % 64;

    if (window->bitmap[word] & (1ULL << bit)) {
        // 已接收，重复包
        return -1;
    }

    // 标记为已接收
    window->bitmap[word] |= (1ULL << bit);

    return 0;
}
```

---

## 6. DPDK IPsec 库

### 6.1 rte_ipsec 架构

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        DPDK IPsec 库架构                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌──────────────────────────────────────────────────────────────────────┐ │
│  │                      Application                                       │ │
│  │  ┌────────────────┐  ┌────────────────┐  ┌────────────────┐          │ │
│  │  │ IPsec Gateway  │  │  VPN Client    │  │   Firewall     │          │ │
│  │  └───────┬────────┘  └───────┬────────┘  └───────┬────────┘          │ │
│  └──────────┼───────────────────┼───────────────────┼───────────────────┘ │
│             │                   │                   │                      │
│  ┌──────────┼───────────────────┼───────────────────┼───────────────────┐ │
│  │          ▼                   ▼                   ▼                    │ │
│  │   ┌─────────────────────────────────────────────────────────────┐     │ │
│  │   │                  rte_ipsec 库                               │     │ │
│  │   │  (lib/librte_ipsec/)                                       │     │ │
│  │   │                                                              │     │ │
│  │   │  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐    │     │ │
│  │   │  │   SPD    │  │   SAD    │  │  Session │  │    SA    │    │     │ │
│  │   │  │  管理    │  │  管理    │  │   管理    │  │   管理    │    │     │ │
│  │   │  └──────────┘  └──────────┘  └──────────┘  └──────────┘    │     │ │
│  │   │                                                              │     │ │
│  │   │  ┌──────────────────────────────────────────────────────┐   │     │ │
│  │   │  │              IPsec 协议处理                           │   │     │ │
│  │   │  │   ESP/AH 封装/解封装、序列号、ICV 验证               │   │     │ │
│  │   │  └──────────────────────────────────────────────────────┘   │     │ │
│  │   │                                                              │     │ │
│  │   └───────────────────────────────────────────────────────────────┘     │ │
│  │                                  │                                       │ │
│  └──────────────────────────────────┼───────────────────────────────────────┘ │
│                                     ▼                                          │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │                     cryptodev / ethdev                               │ │
│  │  (加密卸载 / 洪泛卸载)                                                │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 6.2 IPsec 会话

```c
// lib/ipsec/rte_ipsec_session.h

// IPsec 会话
struct rte_ipsec_session {
    // 关联的 SAD 条目
    struct rte_ipsec_sa *sa;

    // 方向
    uint8_t direction:1;              // inbound / outbound
    uint8_t type:2;                   // inline / lookaside / offload

    // 标记
    uint8_t status:4;

    // Crypto session (用于 lookaside 模式)
    void *crypto_session;
    uint8_t crypto_ses_pool_id;

    // Ethdev session (用于 inline 模式)
    uint16_t ethdev_port_id;
    uint16_t ethdev_queue_id;

    // 统计
    uint64_t stats(bytes, packets, failed);
};

// 创建 IPsec 会话
struct rte_ipsec_session *
rte_ipsec_session_create(uint8_t lcore_id,
                         struct rte_ipsec_sa *sa,
                         uint32_t type)
{
    struct rte_ipsec_session *sess;

    // 分配会话
    sess = rte_zmalloc(NULL, sizeof(*sess), RTE_CACHE_LINE_SIZE);

    sess->sa = sa;
    sess->direction = sa->direction;
    sess->type = type;

    // 创建 cryptodev session (lookaside 模式)
    if (type == RTE_IPSEC_SESSION_LOOKASIDE) {
        sess->crypto_session = rte_cryptodev_sym_session_create(
            sa->crypto_dev_id, sa->xforms);
    }

    return sess;
}

// 更新 SA 的会话引用
int
rte_ipsec_session_update(struct rte_ipsec_session *sess,
                         struct rte_ipsec_sa *sa)
{
    // 清除旧的 crypto session
    if (sess->crypto_session)
        rte_cryptodev_sym_session_free(sess->crypto_dev_id,
                                        sess->crypto_session);

    // 更新 SA
    sess->sa = sa;

    // 创建新的 crypto session
    if (sess->type == RTE_IPSEX_SESSION_LOOKASIDE) {
        sess->crypto_session = rte_cryptodev_sym_session_create(
            sa->crypto_dev_id, sa->xforms);
    }

    return 0;
}
```

### 6.3 IPsec 批量处理

```c
// IPsec 出站处理 (批量)

uint16_t
rte_ipsec_outb_process(const struct rte_ipsec_session *sess,
                        struct rte_mbuf **pkts,
                        struct rte_ipsec_mbuf **privs,
                        uint16_t nb_pkts)
{
    uint16_t i, j;
    uint16_t nb_err = 0;

    // 遍历每个包
    for (i = 0; i < nb_pkts; i++) {
        struct rte_mbuf *pkt = pkts[i];
        struct rte_ipsec_sa *sa = sess->sa;

        // 检查 SA 状态
        if (sa->status != RTE_IPSEC_SA_STATUS_VALID) {
            // SA 无效，丢弃
            rte_pktmbuf_free(pkt);
            pkts[i] = NULL;
            nb_err++;
            continue;
        }

        // 检查生命周期
        if (sa->soft_packets >= sa->soft_bytes) {
            // 软限制触发，通知更新 SA
            notify_sa_update(sa);
        }

        // 添加 ESP 头
        esp_outbound_prepare(pkt, sa);

        // 发送到 cryptodev
        // (实际实现会批量入队以提高性能)
    }

    return nb_pkts - nb_err;
}

// IPsec 入站处理 (批量)
uint16_t
rte_ipsec_inb_process(const struct rte_ipsec_session *sess,
                       struct rte_mbuf **pkts,
                       uint16_t nb_pkts)
{
    uint16_t i, nb_pass = 0;
    struct rte_ipsec_sa *sa = sess->sa;

    for (i = 0; i < nb_pkts; i++) {
        struct rte_mbuf *pkt = pkts[i];
        uint32_t spi, seq;

        // 提取 SPI
        struct esp_hdr *hdr = get_esp_header(pkt, &spi, &seq);

        // SAD 查找
        struct rte_ipsec_sa *pkt_sa = sad_lookup(sad, spi);
        if (!pkt_sa) {
            rte_pktmbuf_free(pkt);
            continue;
        }

        // 抗重放检查
        if (anti_replay_check(pkt_sa, seq) < 0) {
            rte_pktmbuf_free(pkt);
            continue;
        }

        // 发送到 cryptodev 解密
        if (cryptodev_decrypt(pkt, pkt_sa) < 0) {
            rte_pktmbuf_free(pkt);
            continue;
        }

        // 移除 ESP 头/trailer
        esp_inbound_finish(pkt, hdr);

        pkts[nb_pass++] = pkt;
    }

    return nb_pass;
}
```

---

## 7. IPsec 卸载

### 7.1 Inline IPsec (NIC 卸载)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        Inline IPsec (NIC 卸载)                            │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  模式: 数据平面完全由 NIC 硬件处理                                           │
│                                                                             │
│  Outbound:                                                                 │
│  ┌─────────┐         ┌─────────┐         ┌─────────┐         ┌─────────┐ │
│  │   CPU   │────────►│   NIC   │────────►│   Wire  │         │         │ │
│  │(SA only)│  DMA SA │ (Inline│  Encrypted │         │         │         │ │
│  └─────────┘         │  Crypto)│         └─────────┘         └─────────┘ │
│                             │                                              │
│                             ▼                                              │
│                      ┌─────────────┐                                       │
│                      │   MACsec   │                                       │
│                      │   Engine   │                                       │
│                      └─────────────┘                                       │
│                                                                             │
│  Inbound:                                                                 │
│  ┌─────────┐         ┌─────────┐                                           │
│  │   CPU   │◄────────│   NIC   │◄────────────── Wire                       │
│  │(verify) │  DMA    │ (Inline │  Decrypted & Auth                         │
│  └─────────┘         │  Crypto)│                                           │
│                             │                                              │
│                             ▼                                              │
│                      ┌─────────────┐                                       │
│                      │ SA lookup   │                                       │
│                      │ (TCAM)      │                                       │
│                      └─────────────┘                                       │
│                                                                             │
│  优势: CPU 完全不参与数据路径                                               │
│  限制: 需要支持 IPsec 卸载的 NIC (如 Intel 82599, Fortville)              │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 7.2 Lookaside IPsec (Crypto 卸载)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     Lookaside IPsec (Crypto 卸载)                         │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  模式: NIC 做协议处理，专门的 Crypto 设备做加密                              │
│                                                                             │
│  ┌─────────┐         ┌─────────┐         ┌─────────┐         ┌─────────┐ │
│  │   CPU   │         │   NIC   │         │  Crypto │         │         │ │
│  │         │────────►│  (IPsec) │────────►│  (AES)  │────────►│   Wire  │ │
│  │         │ DMA     │ Parse ESP│ DMA     │ Encrypt │         │         │ │
│  └─────────┘         └─────────┘         └─────────┘         └─────────┘ │
│                                                                             │
│  Packet Flow:                                                              │
│  1. CPU 配置 SA 到 NIC 和 Crypto 设备                                      │
│  2. NIC 解析 ESP 头，提取 SPI                                              │
│  3. NIC DMA 包数据到 Crypto 设备                                          │
│  4. Crypto 设备加密 (GCM/CBC)                                              │
│  5. Crypto 设备返回加密结果                                                │
│  6. NIC 添加 ESP 尾和 ICV                                                 │
│  7. NIC 发送加密包                                                        │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 7.3 DPDK HW IPsec 配置

```c
// 使用 ethdev IPsec API

// 查询设备 IPsec 能力
struct rte_eth_ipsec_offload caps;
rte_eth_ipsec_inb_caps_get(port_id, &caps);

if (caps.spi || caps.esn || caps.udp_encap) {
    // 设备支持 IPsec 卸载
}

// 配置 SA (offload 到 NIC)
struct rte_eth_ipsec_sa_entry sa_entry = {
    .spi = rte_cpu_to_be_32(spi),
    .src_ip = RTE_IPV4(192, 168, 1, 1),
    .dst_ip = RTE_IPV4(192, 168, 1, 2),

    // 加密参数
    .cipher_algo = RTE_IPSEC_CIPHER_AES_GCM,
    .cipher_key_len = 32,
    .cipher_key = aes_key,

    // 认证参数
    .auth_algo = RTE_IPSEC_AUTH_AES_GCM,
    .auth_key_len = 32,
    .auth_key = auth_key,

    // 模式
    .mode = RTE_IPSEC_SA_TUNNEL_MODE,
    .direction = RTE_IPSEC_SA_DIR_INBOUND,
};

rte_eth_ipsec_sa_add(port_id, &sa_entry, &sa_id);

// 配置 SPD
struct rte_eth_ipsec_spd_entry spd_entry = {
    .spi = sa_id,
    .remote_ip = RTE_IPV4(192, 168, 1, 2),
    .remote_ip_mask = 0xFFFFFFFF,

    .action = RTE_IPSEC_POLICY_PROTECT,
};

rte_eth_ipsec_spd_add(port_id, 0, &spd_entry);
```

---

## 8. 完整使用示例

### 8.1 IPsec Gateway 配置

```c
// IPsec Gateway 示例 (Site-to-Site VPN)

struct ipsec_gateway {
    struct rte_ipsec_sad *sad;         // SAD
    struct rte_ipsec_spd *spd_in;      // 入站 SPD
    struct rte_ipsec_spd *spd_out;     // 出站 SPD

    uint8_t cryptodev_id;              // Crypto 设备
    uint8_t ethdev_port;               // 网口
};

int
ipsec_gateway_init(struct ipsec_gateway *gw)
{
    // 创建 SAD
    struct rte_ipsec_sad_config sad_conf = {
        .socket_id = SOCKET_ID_ANY,
        .nb_entries = 16384,
        .lookup_types = RTE_IPSEC_SAD_LOOKUP_SPI_DST_IP,
    };
    gw->sad = rte_ipsec_sad_create("gw_sad", &sad_conf);

    // 创建 SPD
    struct rte_ipsec_spd *spd;
    gw->spd_in = spd_create(1024);
    gw->spd_out = spd_create(1024);

    // 配置 SA (本地网关 10.0.0.1, 远端网关 10.0.0.2)
    struct rte_ipsec_sa *sa_tunnel1 = create_sa_entry(
        ESP, TUNNEL,
        SPI(0x12345678),
        10.0.0.1, 10.0.0.2,       // Tunnel endpoints
        AES_256_GCM_KEY, 32,
        NULL, 0,
        0x00000001, 0x00000000    // ESN high
    );
    rte_ipsec_sad_add(gw->sad, sa_tunnel1);

    // 配置 SPD 规则
    // 10.0.0.0/24 ↔ 10.1.0.0/24 (内部网络)
    add_spd_rule(gw->spd_out,
        RTE_IPV4(10, 0, 0, 0), RTE_IPV4(255, 255, 255, 0),
        RTE_IPV4(10, 1, 0, 0), RTE_IPV4(255, 255, 255, 0),
        sa_tunnel1
    );

    return 0;
}

// 主处理循环
int
ipsec_process(struct ipsec_gateway *gw, uint16_t port_id)
{
    struct rte_mbuf *pkts[MAX_PKT_BURST];
    struct rte_ipsec_session *sessions[MAX_PKT_BURST];

    // 接收包
    uint16_t nb_rx = rte_eth_rx_burst(port_id, 0, pkts, MAX_PKT_BURST);

    if (nb_rx == 0)
        return 0;

    // 入站处理 (解密)
    uint16_t i = 0;
    for (i = 0; i < nb_rx; i++) {
        // 解析 IP 头
        struct ipv4_hdr *iph = rte_pktmbuf_mtod(pkts[i], struct ipv4_hdr *);

        if (iph->next_proto_id == IPPROTO_ESP) {
            // ESP 包，查找 SA
            struct rte_ipsec_sa *sa = sad_lookup(gw->sad, pkts[i]);

            if (sa) {
                sessions[i] = sa->session;
            } else {
                // 无效 SA，丢弃
                rte_pktmbuf_free(pkts[i]);
                pkts[i] = NULL;
            }
        } else {
            // 非 ESP，SPD 检查
            if (spd_check(gw->spd_in, pkts[i]) == RTE_IPSEC_SPD_DROP) {
                rte_pktmbuf_free(pkts[i]);
                pkts[i] = NULL;
            }
            sessions[i] = NULL;
        }
    }

    // 批量发送到 cryptodev
    nb_rx = rte_ipsec_prepare(sessions, pkts, nb_rx);

    // cryptodev 入队
    nb_enqueued = rte_cryptodev_enqueue_burst(gw->cryptodev_id, 0,
                                               cryptodev_ops, nb_rx);

    // 轮询完成
    uint16_t nb_dequeued = rte_cryptodev_dequeue_burst(gw->cryptodev_id, 0,
                                                        cryptodev_ops, 32);

    // 处理解密后的包
    for (i = 0; i < nb_dequeued; i++) {
        struct rte_mbuf *pkt = cryptodev_ops[i]->m_src;
        // 发送到本地网络栈
        local_stack_process(pkt);
    }

    return 0;
}
```

---

## 9. 性能与优化

### 9.1 IPsec 性能数据

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        IPsec 性能对比                                       │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  AES-256-GCM + SHA-256 (Tunnel mode, 64B packets)                         │
│                                                                             │
│  方案                  吞吐量        CPU 利用率    CPU cycles/pkt          │
│  ──────────────────────────────────────────────────────────────────────── │
│  软件 (AESNI-MB)      15 Gbps         100%           2000                 │
│  QAT (2x40GbE)       70 Gbps          20%            250                    │
│  Inline (Intel XL710)  40 Gbps          5%            50                   │
│  Inline + QAT          80 Gbps          3%            30                   │
│                                                                             │
│  包处理速率:                                                              │
│  ──────────────                                                            │
│  64B:  ~55 Mpps (wire rate 40GbE)                                        │
│  128B: ~45 Mpps                                                             │
│  512B: ~25 Mpps                                                             │
│  1518B: ~12 Mpps                                                           │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 9.2 优化建议

| 优化项 | 说明 | 效果 |
|--------|------|------|
| **批量处理** | 批量加/解密 | 3-5x 提升 |
| **SA 预配置** | 避免运行时 SAD 查找 | 降低延迟 |
| **硬件卸载** | Inline/QAT 加速 | 10x+ 提升 |
| **ESN** | 避免序列号溢出 | 支持长连接 |
| **mbuf 布局** | 连续缓冲区 | 减少 DMA 开销 |
| **RSS** | 多核并行 | 线性扩展 |

---

## 10. 小结

本章核心要点：

1. **IPsec 体系结构**：SPD (安全策略) → SAD (安全关联) → ESP/AH 协议。

2. **ESP vs AH**：ESP 提供加密+认证，AH 仅认证。Tunnel 模式封装整个 IP 包，Transport 模式仅加密载荷。

3. **SAD**：存储 SA 条目 (SPI、密钥、算法、序列号)，SPI+dst_ip 复合查找。

4. **SPD**：存储安全策略条目，按优先级匹配 (最长匹配)，动作包括 DROP/PASS/PROTECT/BYPASS。

5. **抗重放**：滑动窗口机制，64-4096 位窗口，ESN 支持长连接。

6. **ESP 协议**：SPI+序列号头，填充+尾部，可选 ICV。CBC 需要显式 IV，GCM 使用隐式 IV。

7. **rte_ipsec 库**：提供 Session/SAD/SPD 管理，批量处理 API，支持 inline/lookaside/offload 模式。

8. **IPsec 卸载**：Inline (NIC 完全处理)、Lookaside (NIC 协议 + Crypto 加密)。

9. **性能**：QAT 可达 70 Gbps，Inline NIC 可达 40 Gbps，软件方案 15 Gbps。

10. **应用场景**：Site-to-Site VPN、Remote Access VPN、Cloud IPsec。

**下一篇预告**：[[2026-04-09-dpdk-deep-dive-ch23-tls-dtls-accel|第二十三章]]将讲解 TLS/DTLS 加速与 session 管理——用户态 TLS 卸载。

---

> [!tip] 参考文献
> - RFC 4301, "Security Architecture for IPsec"
> - RFC 4302, "IP Authentication Header (AH)"
> - RFC 4303, "Encapsulating Security Payload (ESP)"
> - RFC 4309, "AES-CBC with ICV"
> - Intel, "DPDK IPsec Pipeline", https://doc.dpdk.org/guides/prog_guide/ipsec_lib.html
> - "IPsec in DPDK", https://doc.dpdk.org/guides-21.02/sample_app_ug/ipsec_secgw.html
