---
title: "DPDK 深度探索 ch36：IPsec 深度解析"
date: 2026-04-10 13:30:00
tags: [dpdk, ipsec, esp, ah, sa, spi, transport, tunnel, crypto]
description: "深入解析 DPDK IPsec：ESP/AH 协议、SA 管理、安全关联、SAD、IPsec 模式与 DPDK 实现"
---

# DPDK 深度探索 ch36：IPsec 深度解析

> [!abstract] 核心要点
> IPsec 是网络层安全标准。本章深入解析 ESP/AH 协议、SA/SAD、安全策略、传输/隧道模式与 DPDK IPsec 实现。

## 1. IPsec 概述

### 1.1 IPsec 协议栈

```
┌─────────────────────────────────────────────────────────────┐
│                    IPsec 协议栈                              │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              Application Data                         │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              IPsec                                    │  │
│  │                                                       │  │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐          │  │
│  │  │   ESP    │  │   AH     │  │   IKE    │          │  │
│  │  │(加密+认证)│  │ (仅认证) │  │ (密钥交换)│          │  │
│  │  └──────────┘  └──────────┘  └──────────┘          │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              IP Header                                │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 ESP vs AH

| 特性               | ESP | AH   |
| ------------------ | --- | ---- |
| **加密**           | ✅  | ❌   |
| **认证**           | ✅  | ✅   |
| **IP Header 认证** | ❌  | ✅   |
| **NAT-T**          | ✅  | ❌   |
| **使用广泛**       | ✅  | 较少 |

## 2. ESP 协议

### 2.1 ESP 头

```
┌─────────────────────────────────────────────────────────────┐
│                    ESP 报文格式                            │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  IP Header                                           │  │
│  └──────────────────────────────────────────────────────┘  │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  SPI (4B) | Sequence (4B)                          │  │
│  ├──────────────────────────────────────────────────────┤  │
│  │  IV (可变)                                          │  │
│  ├──────────────────────────────────────────────────────┤  │
│  │  Payload (加密)                                     │  │
│  │  ┌────────────────────────────────────────────┐   │  │
│  │  │  Original IP Header (隧道模式)              │   │  │
│  │  │  TCP/UDP Header                             │   │  │
│  │  │  Application Data                           │   │  │
│  │  └────────────────────────────────────────────┘   │  │
│  ├──────────────────────────────────────────────────────┤  │
│  │  ESP Trailer                                        │  │
│  │  Padding | Pad Len | Next Header | Auth Data       │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 ESP 头结构

```c
// ESP 头 (RFC 2406)
struct esp_hdr {
    uint32_t spi;        // Security Parameters Index
    uint32_t seq;        // Sequence Number
    uint8_t iv[];        // Initialization Vector (CBC 模式)
};

// ESP Trailer
struct esp_trailer {
    uint8_t pad_len;     // Padding Length
    uint8_t next_header;  // Next Header
    uint8_t auth_data[]; // Authentication Data (ICV)
};
```

## 3. 安全关联 (SA)

### 3.1 SA 概念

```
┌─────────────────────────────────────────────────────────────┐
│                    Security Association (SA)               │
│                                                              │
│  SA 是单向的逻辑连接：                                       │
│                                                              │
│  Host A ──────────────────────────────── Host B              │
│       │                                    │                 │
│       │  SA: A→B (ESP)                    │                 │
│       │  SPI: 0x1234                      │                 │
│       │  Algorithm: AES-256-GCM            │                 │
│       │  Key: 0x5678...                   │                 │
│       │                                    │                 │
│       │  SA: B→A (ESP)                    │                 │
│       │  SPI: 0x5678                      │                 │
│       │  Algorithm: AES-256-GCM            │                 │
│       │  Key: 0x9ABC...                   │                 │
│       │                                    │                 │
│  数据加密路径： A → B 使用 SA 0x1234                          │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 SAD 和 SPD

```
SAD (Security Association Database):
  - 所有 SA 的数据库
  - SPI → SA 映射
  - 包含密钥、算法、序列号等

SPD (Security Policy Database):
  - 选择如何处理数据包
  - 匹配规则 → SA
  - permit/deny/bypass
```

### 3.3 SAD 结构

```c
// SAD 条目
struct sad_entry {
    uint32_t spi;              // SPI 值
    ip_addr_t src_ip;          // 源地址
    ip_addr_t dst_ip;          // 目标地址

    // 协议
    uint8_t protocol;          // ESP or AH

    // 加密
    enum cipher_algo cipher;   // AES-CBC, AES-GCM, etc.
    uint8_t cipher_key[32];    // 密钥
    uint16_t cipher_iv_len;    // IV 长度

    // 认证
    enum auth_algo auth;       // HMAC-SHA256, etc.
    uint8_t auth_key[64];       // 认证密钥
    uint16_t auth_icv_len;     // ICV 长度

    // 序列号
    uint32_t seq;              // 当前序列号
    uint32_t seq_mask;         // 窗口大小

    // 生命周期
    uint64_t soft_lifetime;    // 软过期时间
    uint64_t hard_lifetime;    // 硬过期时间
};

// SAD 表
struct sad_table {
    struct rte_hash *by_spi;   // SPI → SA
    struct rte_hash *by_dst;    // DST + SPI → SA
};
```

## 4. 安全策略 (SPD)

### 4.1 SPD 结构

```c
// SPD 条目
struct spd_entry {
    // 匹配条件
    ip_addr_t src_ip;
    ip_addr_t dst_ip;
    uint16_t src_port_start;
    uint16_t src_port_end;
    uint16_t dst_port_start;
    uint16_t dst_port_end;
    uint8_t next_header;       // TCP, UDP, ICMP, etc.
    uint8_t protocol;

    // 动作
    enum spd_action {
        SPD_DISCARD,           // 丢弃
        SPD_BYPASS,            // 不保护 (e.g., ICMP)
        SPD_PROTECT,           // 加密/认证
    } action;

    // 关联的 SA (如果是 PROTECT)
    struct sad_entry *sa_inbound;   // 入方向 SA
    struct sad_entry *sa_outbound;   // 出方向 SA
};
```

### 4.2 SPD 处理

```c
// SPD 查找
struct spd_entry *
spd_lookup(struct spd_table *spd,
           ip_addr_t src, ip_addr_t dst,
           uint8_t protocol, uint16_t src_port, uint16_t dst_port)
{
    // 精确匹配
    for (int i = 0; i < spd->n_entries; i++) {
        struct spd_entry *e = &spd->entries[i];

        if (ip_match(src, e->src_ip, e->src_mask) &&
            ip_match(dst, e->dst_ip, e->dst_mask) &&
            protocol == e->protocol) {
            return e;
        }
    }

    return NULL;
}
```

## 5. IPsec 模式

### 5.1 传输模式 vs 隧道模式

```
┌─────────────────────────────────────────────────────────────┐
│                    传输模式 (Transport)                      │
│                                                              │
│  Original IP: [Src][Dst][TCP][Data]                        │
│                      ↓ ESP                                   │
│  Protected: [Src][Dst][ESP][TCP][Data][ESP.Tail][Auth]     │
│                                                              │
│  - 只加密 payload                                          │
│  - 保留原始 IP 头                                          │
│  - 用于 host-to-host                                        │
│                                                              │
├─────────────────────────────────────────────────────────────┤
│                    隧道模式 (Tunnel)                        │
│                                                              │
│  Original IP: [Src][Dst][TCP][Data]                         │
│                      ↓ ESP                                   │
│  Protected:                        │                          │
│  New IP: [NewSrc][NewDst] | [Src][Dst][ESP][TCP][Data]... │ [Auth]
│                               ↑                              │
│                       新 IP 头                              │
│                                                              │
│  - 加密整个原始 IP 包                                        │
│  - 添加新的 IP 头                                          │
│  - 用于 gateway-to-gateway 或 host-to-gateway              │
└─────────────────────────────────────────────────────────────┘
```

## 6. DPDK IPsec 实现

### 6.1 IPsec 库

```c
// DPDK IPsec 库
#include <rte_ipsec.h>

// 创建 IPsec SA
struct rte_ipsec_sa *
create_ipsec_sa(uint32_t spi,
                enum rte_ipsec_sa_direction dir)
{
    struct rte_ipsec_sa_params sa_params = {
        .spi = spi,
        .direction = dir,
        .cipher = {
            .algo = RTE_CRYPTO_CIPHER_AES_GCM,
            .key = {0x00, 0x01, ...},  // 128/256 bit
            .key_len = 32,
            .iv_len = 8,  // GCM IV
        },
        .auth = {
            .algo = RTE_CRYPTO_AUTH_AES_GCM,
            .key = {0x00, 0x02, ...},
            .key_len = 16,
            .digest_len = 16,
        },
        .options = {
            .udp_encap = 0,
            .tunnel_hdr_len = 20,
        },
    };

    return rte_ipsec_sa_create(&sa_params);
}
```

### 6.2 IPsec 加密/解密

```c
// IPsec 加密 (Outbound)
int
ipsec_encap(struct rte_ipsec_session *session,
            struct rte_mbuf *mbuf)
{
    // 准备 SA
    struct rte_ipsec_sa *sa = session->sa;

    // 加密
    struct rte_crypto_op *op = session->crypto_op;
    op->sym->session = sa->session;
    op->sym->m_src = mbuf;

    // 设置加密参数
    op->sym->cipher.data.offset = 0;
    op->sym->cipher.data.length = mbuf->pkt_len;

    // 提交到 crypto 设备
    rte_cryptodev_enqueue_burst(cdev_id, 0, &op, 1);

    return 0;
}

// IPsec 解密 (Inbound)
int
ipsec_decap(struct rte_ipsec_session *session,
            struct rte_mbuf *mbuf)
{
    // 查找 SA (根据 SPI)
    struct rte_ipsec_sa *sa = lookup_sa_by_spi(mbuf->esp.spi);

    // 解密
    struct rte_crypto_op *op = session->crypto_op;
    op->sym->session = sa->session;
    op->sym->m_src = mbuf;

    rte_cryptodev_enqueue_burst(cdev_id, 0, &op, 1);

    return 0;
}
```

### 6.3 全流程

```c
// IPsec 处理管道
int
ipsec_process(struct rte_mbuf *mbuf)
{
    // 1. 解析 IP 头
    struct ip_hdr *ip = rte_pktmbuf_mtod(mbuf, struct ip_hdr *);

    if (ip->proto == IPPROTO_ESP) {
        // 2. 查找 SA
        struct esp_hdr *esp = (struct esp_hdr *)(ip + 1);
        struct rte_ipsec_sa *sa = sad_lookup(esp->spi);

        if (!sa)
            return -1;  // 丢弃

        // 3. 验证序列号
        if (!verify_seq(sa, esp->seq))
            return -1;

        // 4. 解密
        decrypt_packet(sa, mbuf);

        // 5. 验证认证
        if (!verify_auth(sa, mbuf))
            return -1;

        // 6. 移除 ESP 头/尾
        remove_esphdr(mbuf);

        // 7. 转发到原始目的地
        forward_packet(mbuf);
    }

    return 0;
}
```

## 7. NAT-T

### 7.1 NAT-T 问题

```
NAT-T (NAT Traversal)：

问题：
- NAT 设备修改 IP 头
- ESP 不包含可修改的字段
- AH 会破坏校验和

解决方案：
- UDP 封装 ESP
- 使用 UDP 端口 4500
- NAT 设备可以修改 UDP 端口
```

### 7.2 NAT-T 实现

```c
// NAT-T 封装
struct nat_t_hdr {
    uint16_t src_port;   // NAT-T 源端口
    uint16_t dst_port;   // NAT-T 目标端口
    uint16_t length;     // UDP 长度
    uint16_t checksum;   // UDP 校验和
};

struct esp_udp_hdr {
    struct nat_t_hdr udp;
    struct esp_hdr esp;
};
```

## 8. 总结

IPsec 架构：

```
┌─────────────────────────────────────────────────────────────┐
│                    IPsec 处理流程                           │
│                                                              │
│  Outbound:                                                  │
│  1. SPD lookup → SA                                        │
│  2. 添加 ESP 头                                            │
│  3. 加密 (AES-GCM)                                         │
│  4. 添加认证 ICV                                           │
│  5. 添加新 IP 头 (隧道模式)                                │
│                                                              │
│  Inbound:                                                   │
│  1. 验证 SPI → SA                                          │
│  2. 验证序列号                                             │
│  3. 验证 ICV                                               │
│  4. 解密                                                   │
│  5. 移除 ESP 头                                            │
│  6. SPD 验证                                               │
└─────────────────────────────────────────────────────────────┘
```

ESP vs AH：

| 特性     | ESP | AH         |
| -------- | --- | ---------- |
| 加密     | ✅  | ❌         |
| 认证     | ✅  | ✅         |
| NAT-T    | ✅  | ❌         |
| 抗重放   | ✅  | ✅         |
| 典型应用 | VPN | 完整性保护 |

---

## 参考资源

- [RFC 2406 (ESP)](https://tools.ietf.org/html/rfc2406)
- [RFC 2402 (AH)](https://tools.ietf.org/html/rfc2402)
- [DPDK IPsec](https://doc.dpdk.org/guides/prog_guide/ipsec_lib.html)
