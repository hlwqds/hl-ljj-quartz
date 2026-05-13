---
title: "DPDK 深度探索 (二十二)：IPsec 完整处理流程与 SAD/SPD"
date: 2026-04-09
tags: [dpdk, series, ipsec, sad, spd, esp, ah, sa, tunnel, transport]
description: "深入理解 IPsec 完整处理流程——ESP/AH 协议、SAD 安全关联数据库、SPD 安全策略数据库、Tunnel/Transport 模式、IPsec 卸载"
---

> [!info] DPDK 深度探索系列 0. [[2026-04-09-dpdk-deep-dive-series-index|全栈学习路径总览]]
> 1-21. 前二十一章已完成 22. **第二十二章：IPsec 完整处理流程与 SAD/SPD**

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

### 2.1 SA 在 DPDK 中的表示

`rte_ipsec_sa` 在 DPDK 中是**不透明结构体**（opaque），应用层不能直接访问其字段。SA 通过 `rte_ipsec_sa_prm` 参数结构体初始化，由 `rte_ipsec_sa_init()` 完成。

```c
// lib/ipsec/rte_ipsec_sa.h

// SA 是不透明的，只提供前向声明
struct rte_ipsec_sa;

// SA 初始化参数
struct rte_ipsec_sa_prm {
    uint64_t userdata;                    // 用户自定义数据
    uint64_t flags;                       // RTE_IPSEC_SAFLAG_* 标志

    // IPsec 配置（方向、协议、模式、SPI、salt、生命周期等）
    struct rte_security_ipsec_xform ipsec_xform;

    // 加密配置（算法、密钥、IV 等）
    struct rte_crypto_sym_xform *crypto_xform;

    union {
        struct {
            uint8_t hdr_len;              // tunnel 头长度
            uint8_t hdr_l3_off;           // L3 头偏移
            uint8_t next_proto;           // 下一层协议
            const void *hdr;              // tunnel 头模板
        } tun;                            // Tunnel 模式参数
        struct {
            uint8_t proto;                // 下一层协议
        } trs;                            // Transport 模式参数
    };
};

// 初始化 SA（返回实际占用大小）
int rte_ipsec_sa_init(struct rte_ipsec_sa *sa,
                      const struct rte_ipsec_sa_prm *prm,
                      uint32_t size);

// 计算 SA 所需缓冲区大小
int rte_ipsec_sa_size(const struct rte_ipsec_sa_prm *prm);

// 查询 SA 的 type 位掩码（包含方向、协议、模式等信息）
uint64_t rte_ipsec_sa_type(const struct rte_ipsec_sa *sa);

// 清理 SA
void rte_ipsec_sa_fini(struct rte_ipsec_sa *sa);
```

> [!note] SA 的内部结构
> `rte_ipsec_sa` 内部（`lib/ipsec/sa.h`）包含 `type`（64-bit 位掩码，编码了 IPv4/IPv6、ESP/AH、入站/出站、Transport/Tunnel、ESN 等信息）、`spi`、`salt`、`sqn`（序列号）、`replay`（抗重放窗口）、`statistics` 等字段。但这些都是内部实现细节，应用层只需通过 `rte_ipsec_sa_prm` 来初始化。

#### SA type 位掩码

DPDK 用 64-bit `type` 字段编码 SA 的各种属性：

```c
// SA type 中的关键位掩码（lib/ipsec/rte_ipsec_sa.h）

// 方向
#define RTE_IPSEC_SATP_DIR_IB   0ULL  // Inbound
#define RTE_IPSEC_SATP_DIR_OB   1ULL  // Outbound

// 协议
#define RTE_IPSEC_SATP_PROTO_AH  0ULL  // AH
#define RTE_IPSEC_SATP_PROTO_ESP 1ULL  // ESP

// 模式
#define RTE_IPSEC_SATP_MODE_TRANS   0ULL  // Transport
#define RTE_IPSEC_SATP_MODE_TUNLV4  1ULL  // Tunnel (IPv4 外层)
#define RTE_IPSEC_SATP_MODE_TUNLV6  2ULL  // Tunnel (IPv6 外层)

// ESN
#define RTE_IPSEC_SATP_ESN_DISABLE 0ULL
#define RTE_IPSEC_SATP_ESN_ENABLE  1ULL
```

#### IPsec xform 配置

SA 的 IPsec 参数通过 `rte_security_ipsec_xform`（定义在 `lib/security/rte_security.h`）设置：

```c
// lib/security/rte_security.h

struct rte_security_ipsec_xform {
    uint32_t spi;                                    // Security Parameter Index
    uint32_t salt;                                   // GCM salt
    struct rte_security_ipsec_sa_options options;    // ESN、UDP encaps、DSCP 等
    enum rte_security_ipsec_sa_direction direction;  // EGRESS / INGRESS
    enum rte_security_ipsec_sa_protocol proto;       // ESP / AH
    enum rte_security_ipsec_sa_mode mode;            // TRANSPORT / TUNNEL
    struct rte_security_ipsec_tunnel_param tunnel;   // Tunnel 参数（src/dst IP）
    struct rte_security_ipsec_lifetime life;         // 生命周期限制
    uint32_t replay_win_sz;                          // 抗重放窗口大小
    union { uint64_t value; struct { uint32_t low; uint32_t hi; }; } esn;  // ESN
    struct rte_security_ipsec_udp_param udp;         // NAT-T UDP 参数
};

// 生命周期配置
struct rte_security_ipsec_lifetime {
    uint64_t packets_soft_limit;   // 软限制（触发通知）
    uint64_t bytes_soft_limit;
    uint64_t packets_hard_limit;   // 硬限制（触发 SA 失效）
    uint64_t bytes_hard_limit;
};
```

### 2.2 SAD 表结构

DPDK 提供 `rte_ipsec_sad` 库来管理安全关联数据库。

```c
// lib/ipsec/rte_ipsec_sad.h

struct rte_ipsec_sad;   // 不透明句柄

// 查找 key 类型
enum {
    RTE_IPSEC_SAD_SPI_ONLY = 0,      // 仅按 SPI 查找
    RTE_IPSEC_SAD_SPI_DIP,           // SPI + 目标 IP
    RTE_IPSEC_SAD_SPI_DIP_SIP,       // SPI + 目标 IP + 源 IP
    RTE_IPSEC_SAD_KEY_TYPE_MASK,     // key 类型数量
};

// IPv4 查找 key
struct rte_ipsec_sadv4_key {
    uint32_t spi;
    uint32_t dip;
    uint32_t sip;
};

// IPv6 查找 key
struct rte_ipsec_sadv6_key {
    uint32_t spi;
    struct rte_ipv6_addr dip;
    struct rte_ipv6_addr sip;
};

// SAD key 联合体
union rte_ipsec_sad_key {
    struct rte_ipsec_sadv4_key v4;
    struct rte_ipsec_sadv6_key v6;
};

// SAD 配置
struct rte_ipsec_sad_conf {
    int socket_id;                                    // NUMA 节点
    uint32_t max_sa[RTE_IPSEC_SAD_KEY_TYPE_MASK];    // 每种 key 类型的最大 SA 数
    uint32_t flags;                                  // RTE_IPSEC_SAD_FLAG_*
};

#define RTE_IPSEC_SAD_FLAG_IPV6           0x1   // 支持 IPv6
#define RTE_IPSEC_SAD_FLAG_RW_CONCURRENCY 0x2   // 支持读写并发
```

#### SAD 管理函数

```c
// 创建 SAD
struct rte_ipsec_sad *
rte_ipsec_sad_create(const char *name,
                     const struct rte_ipsec_sad_conf *conf);

// 查找已有 SAD
struct rte_ipsec_sad *
rte_ipsec_sad_find_existing(const char *name);

// 销毁 SAD
void rte_ipsec_sad_destroy(struct rte_ipsec_sad *sad);

// 添加 SA 条目
int rte_ipsec_sad_add(struct rte_ipsec_sad *sad,
                      const union rte_ipsec_sad_key *key,
                      int key_type, void *sa);

// 删除 SA 条目
int rte_ipsec_sad_del(struct rte_ipsec_sad *sad,
                      const union rte_ipsec_sad_key *key,
                      int key_type);

// 批量查找 SA
int rte_ipsec_sad_lookup(const struct rte_ipsec_sad *sad,
                         const union rte_ipsec_sad_key *keys[],
                         void *sa[], uint32_t n);
// 返回成功查找的数量；未找到的对应 sa[i] 为 NULL
```

### 2.3 SAD 使用示例

```c
#include <rte_ipsec_sad.h>

// 创建 SAD
struct rte_ipsec_sad_conf sad_conf = {
    .socket_id = SOCKET_ID_ANY,
    .max_sa = {
        [RTE_IPSEC_SAD_SPI_ONLY]  = 1024,
        [RTE_IPSEC_SAD_SPI_DIP]   = 1024,
        [RTE_IPSEC_SAD_SPI_DIP_SIP] = 1024,
    },
    .flags = RTE_IPSEC_SAD_FLAG_RW_CONCURRENCY,
};
struct rte_ipsec_sad *sad = rte_ipsec_sad_create("my_sad", &sad_conf);

// 添加 SA 条目（IPv4, SPI + DIP 查找）
struct rte_ipsec_sadv4_key key = {
    .spi = rte_cpu_to_be_32(0x12345678),
    .dip = RTE_IPV4(192, 168, 1, 2),
    .sip = RTE_IPV4(10, 0, 0, 1),
};
// sa_ptr 指向已初始化的 rte_ipsec_sa 对象
rte_ipsec_sad_add(sad, (const union rte_ipsec_sad_key *)&key,
                  RTE_IPSEC_SAD_SPI_DIP_SIP, sa_ptr);

// 批量查找（典型入站处理）
const union rte_ipsec_sad_key *keys[MAX_PKT_BURST];
void *sa_out[MAX_PKT_BURST];

// 从收到的包中提取 SPI 和 IP 地址，构建 key 数组
for (uint16_t i = 0; i < nb_rx; i++) {
    struct rte_ipsec_sadv4_key *k = rte_malloc(NULL, sizeof(*k), 0);
    k->spi = extract_spi(pkts[i]);
    k->dip = extract_dst_ip(pkts[i]);
    k->sip = extract_src_ip(pkts[i]);
    keys[i] = (const union rte_ipsec_sad_key *)k;
}

int nb_found = rte_ipsec_sad_lookup(sad, keys, sa_out, nb_rx);
// sa_out[i] == NULL 表示未找到匹配的 SA
```

---

## 3. SPD 安全策略数据库

> [!important] DPDK 没有内置 SPD 库
> 与 SAD 不同，DPDK **没有提供官方的 SPD（Security Policy Database）实现**。SPD 的管理完全由应用层自行负责。DPDK 的 `ipsec-secgw` 示例应用中有自己的 SPD 实现（基于 ACL 库），但那不是公共 API。

### 3.1 SPD 概念

SPD 是 IPsec 体系中的策略决策层，定义了哪些流量需要 IPsec 保护、哪些可以跳过、哪些应该丢弃。标准的策略动作：

| 动作        | 说明                                              |
| ----------- | ------------------------------------------------- |
| **PROTECT** | 对流量应用 IPsec 保护（加密/认证），关联到一个 SA |
| **BYPASS**  | 绕过 IPsec，明文放行（用于 IKE 等管理流量）       |
| **DISCARD** | 丢弃流量                                          |

### 3.2 SPD 匹配规则

SPD 条目基于五元组（src_ip, dst_ip, src_port, dst_port, protocol）进行匹配，支持 CIDR 掩码。匹配顺序通常按优先级排列，第一个命中的规则决定动作。

### 3.3 DPDK 应用中的 SPD 实现方式

在 DPDK 应用中，SPD 通常使用以下方式实现：

- **rte_acl 库**：最常用，支持五元组 + CIDR 规则的高效匹配
- **rte_hash**：精确匹配场景（固定 IP 对）
- **应用自定义逻辑**：简单的线性遍历（规则数量少时足够）

DPDK 官方示例 `ipsec-secgw` 使用 `rte_acl` 实现 SPD，通过配置文件加载规则，在运行时对每个包进行 ACL 查询来决定是否需要 IPsec 处理。

---

## 4. ESP 协议详解

### 4.1 ESP 头结构

```c
// ESP 头格式（RFC 4303）

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

### 4.2 ESP 加密处理流程（概念）

Outbound 处理的完整步骤：

```
原始包 → 计算填充 → prepend ESP Header → append ESP Trailer
       → 构造 crypto op → 提交 cryptodev → 加密完成 → 发送
```

> [!note] 实际开发中不手动处理 ESP
> DPDK 的 `rte_ipsec` 库封装了完整的 ESP 协议处理。应用只需调用 `rte_ipsec_pkt_crypto_prepare()` 和 `rte_ipsec_pkt_process()`，库会自动完成 ESP 头构造、填充计算、IV 填充、序列号管理等。下面的伪代码仅用于理解协议原理。

```c
// ESP 加密流程伪代码 (仅供理解原理，实际使用 rte_ipsec API)

// 1. 计算填充长度（使载荷对齐到 4 字节）
//    ESP 要求加密范围从 SPI 之后到 ICV 之前，总长度必须是 4 的倍数
//    pad_len = 4 - (payload_len + 2) % 4
//
// 2. prepend ESP Header (8 字节): SPI(4) + Seq(4)
//
// 3. 对于 CBC 模式: prepend 显式 IV（16 字节）
//    对于 GCM 模式: IV 由 salt(4) + ESP_IV(8) 组成，salt 在 SA 中配置
//
// 4. append ESP Trailer: Padding + PadLen(1) + NextHeader(1)
//
// 5. 对于非 AEAD 算法: append ICV（HMAC 认证数据）
//    对于 AEAD 算法 (GCM/CCM): ICV 由硬件自动附加
//
// 6. 构造 rte_crypto_op，提交到 cryptodev
```

### 4.3 ESP 解密处理流程（概念）

Inbound 处理的完整步骤：

```
收到 ESP 包 → 从 IP 头提取 SPI → SAD 查找 SA
            → 抗重放检查 → 构造 crypto op → 提交 cryptodev
            → 解密+认证完成 → 移除 ESP Header/Trailer/ICV
            → 恢复原始包 → 交给上层处理
```

```c
// ESP 解密流程伪代码 (仅供理解原理)

// 1. 解析 ESP 头（跳过 IP 头，读取 SPI 和 Seq）
//    SPI 在网络字节序，需要 rte_be_to_cpu_32() 转换

// 2. 用 SPI + dst_ip 构建 SAD key，查找 SA
//    union rte_ipsec_sad_key key = { .v4.spi = spi, .v4.dip = dst_ip };

// 3. 抗重放检查（如果 SA 启用了 replay_win_sz > 0）
//    由 rte_ipsec 库内部处理，应用层不需要手动检查

// 4. 构造 crypto op，提交 cryptodev 解密+认证
//    AEAD 算法 (GCM): 单次 op 完成加密+认证
//    非 AEAD: 需要 cipher + auth 两个 op

// 5. 解密完成后，移除 ESP Header/Trailer/ICV
//    调整 mbuf 的 data_off 和 data_len
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

### 5.2 DPDK 中的抗重放

抗重放功能在 SA 创建时通过 `replay_win_sz` 参数配置：

```c
// 在 rte_security_ipsec_xform 中配置
struct rte_security_ipsec_xform xform = {
    .spi = 0x12345678,
    .replay_win_sz = 64,   // 0 = 禁用抗重放检查
    // ...
};
```

> [!note] 抗重放由库内部处理
> `rte_ipsec` 库在 `rte_ipsec_pkt_process()` 内部自动执行抗重放检查。SA 内部使用 `replay.win_sz` 和分桶位图结构（`replay_sqn`）来跟踪已接收的序列号。如果检测到重放包，该包会被移到输出数组的末尾（不释放），应用层需要检查返回值处理失败的包。

### 5.3 ESN（扩展序列号）

标准 32-bit 序列号在 2^32 个包后会溢出。ESN（Extended Sequence Number）使用 64-bit 序列号来避免此问题。

```c
// 在 SA options 中启用 ESN
struct rte_security_ipsec_sa_options options = {
    .esn = 1,   // 启用 ESN
};

// ESN 值设置
xform.esn.low = 0;    // 低 32 位
xform.esn.hi = 0;    // 高 32 位
```

ESN 的低 32 位随每个包递增，溢出后高 32 位递增。ESP 头中只传输低 32 位，高 32 位由收发双方通过 IKE 协商或带外方式同步。

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
│  │   │  (lib/ipsec/)                                             │     │ │
│  │   │                                                            │     │ │
│  │   │  ┌──────────┐  ┌──────────┐  ┌──────────────────────────┐  │     │ │
│  │   │  │   SAD    │  │   SA    │  │      Session             │  │     │ │
│  │   │  │  管理    │  │  管理    │  │  (sa + crypto/security)  │  │     │ │
│  │   │  └──────────┘  └──────────┘  └──────────────────────────┘  │     │ │
│  │   │                                                            │     │ │
│  │   │  ┌──────────────────────────────────────────────────────┐   │     │ │
│  │   │  │              IPsec 协议处理                           │   │     │ │
│  │   │  │   ESP/AH 封装/解封装、序列号、抗重放、ICV 验证       │   │     │ │
│  │   │  └──────────────────────────────────────────────────────┘   │     │ │
│  │   └────────────────────────────────────────────────────────────┘     │ │
│  │                                  │                                    │ │
│  └──────────────────────────────────┼────────────────────────────────────┘ │
│                                     ▼                                       │
│  ┌──────────────────────────────────────────────────────────────────────┐ │
│  │               rte_security / rte_cryptodev                         │ │
│  │  (安全框架 / 加密设备抽象)                                          │ │
│  └──────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 6.2 IPsec Session

`rte_ipsec_session` 是 DPDK IPsec 处理的核心对象，定义在 `rte_ipsec.h` 中：

```c
// lib/ipsec/rte_ipsec.h

struct __rte_cache_aligned rte_ipsec_session {
    struct rte_ipsec_sa *sa;   // 关联的 SA（多个 session 可共享同一个 SA）
    enum rte_security_session_action_type type;   // session 类型

    union {
        // Lookaside 模式：使用 cryptodev
        struct {
            struct rte_cryptodev_sym_session *ses;  // crypto session
            uint8_t dev_id;                         // crypto 设备 ID
        } crypto;

        // Inline 模式：使用 ethdev security
        struct {
            struct rte_security_session *ses;       // security session
            struct rte_security_ctx *ctx;           // security 上下文
            uint32_t ol_flags;                      // offload 标志
        } security;
    };

    // 包处理函数指针（由 rte_ipsec_session_prepare 设置）
    struct rte_ipsec_sa_pkt_func pkt_func;
};
```

#### Session 类型

```c
// lib/security/rte_security.h

enum rte_security_session_action_type {
    RTE_SECURITY_ACTION_TYPE_NONE,
    RTE_SECURITY_ACTION_TYPE_INLINE_CRYPTO,         // NIC 内联加密
    RTE_SECURITY_ACTION_TYPE_INLINE_PROTOCOL,       // NIC 内联完整 IPsec
    RTE_SECURITY_ACTION_TYPE_LOOKASIDE_PROTOCOL,    // 外部 crypto 设备
    RTE_SECURITY_ACTION_TYPE_CPU_CRYPTO,            // CPU 加密（AESNI）
};
```

#### Session 初始化

DPDK **没有** `rte_ipsec_session_create()` 函数。Session 由应用自行分配，然后调用 `rte_ipsec_session_prepare()` 来初始化函数指针：

```c
// 分配 session（通常放在 lcore 变量中）
struct rte_ipsec_session session;

// 填充 session 字段
session.sa = &sa;
session.type = RTE_SECURITY_ACTION_TYPE_LOOKASIDE_PROTOCOL;

// 创建 crypto session
session.crypto.ses = rte_cryptodev_sym_session_create(
    crypto_dev_id, &crypto_xform, session_mempool);
session.crypto.dev_id = crypto_dev_id;

// 初始化 pkt_func 函数指针
int ret = rte_ipsec_session_prepare(&session);
// 返回 0 表示成功，-EINVAL 表示参数无效
```

### 6.3 包处理 API

DPDK IPsec 的包处理分为两阶段：

**阶段 1：准备 crypto op（lookaside 模式）**

```c
// 将 mbuf 数组转换为 crypto_op 数组
// 入站：从 ESP 包中提取加密数据，设置解密参数
// 出站：添加 ESP 头，设置加密参数
uint16_t
rte_ipsec_pkt_crypto_prepare(const struct rte_ipsec_session *ss,
                              struct rte_mbuf *mb[],
                              struct rte_crypto_op *cop[],
                              uint16_t num);
// 返回: 成功准备的包数量
// 注意: 出错的包不会被释放，而是被移到 mb[] 数组末尾
```

**阶段 2：处理完成后的包**

```c
// lookaside 模式：cryptodev 完成加密/解密后调用
// inline 模式：NIC 返回解密后的包时直接调用
uint16_t
rte_ipsec_pkt_process(const struct rte_ipsec_session *ss,
                       struct rte_mbuf *mb[],
                       uint16_t num);
// 入站: 移除 ESP 头/trailer，更新 l2_len/l3_len
// 出站: 更新 ol_flags/tx_offloads
// 返回: 成功处理的包数量，出错包移到数组末尾
```

**CPU 同步模式（不经过 cryptodev）**

```c
// 在 CPU 上直接执行加密（如 AESNI），不经过 cryptodev PMD
uint16_t
rte_ipsec_pkt_cpu_prepare(const struct rte_ipsec_session *ss,
                           struct rte_mbuf *mb[],
                           uint16_t num);
```

### 6.4 完整的出站处理流程

```c
// Lookaside 模式下的出站加密流程

#define MAX_PKT_BURST 32

void
outbound_process(struct rte_ipsec_session *session,
                 uint8_t crypto_dev_id, uint16_t crypto_qp_id,
                 struct rte_mbuf *pkts[], uint16_t nb_pkts,
                 uint16_t port_id, uint16_t tx_queue_id)
{
    struct rte_crypto_op *crypto_ops[MAX_PKT_BURST];
    struct rte_mbuf *copied_pkts[MAX_PKT_BURST];

    // 1. 准备 crypto op
    //    出站：添加 ESP 头、填充、设置加密参数
    uint16_t nb_prep = rte_ipsec_pkt_crypto_prepare(
        session, pkts, crypto_ops, nb_pkts);

    // 2. 入队到 cryptodev
    uint16_t nb_enq = rte_cryptodev_enqueue_burst(
        crypto_dev_id, crypto_qp_id, crypto_ops, nb_prep);

    // 处理未入队的 op
    for (uint16_t i = nb_enq; i < nb_prep; i++)
        rte_crypto_op_free(crypto_ops[i]);

    // 3. 轮询 cryptodev 完成结果
    uint16_t nb_deq = 0;
    do {
        nb_deq += rte_cryptodev_dequeue_burst(
            crypto_dev_id, crypto_qp_id,
            &crypto_ops[nb_deq], MAX_PKT_BURST - nb_deq);
    } while (nb_deq < nb_enq);

    // 4. 从 crypto_op 中提取 mbuf
    for (uint16_t i = 0; i < nb_deq; i++)
        copied_pkts[i] = crypto_ops[i]->sym->m_src;

    // 5. 完成处理（更新 IP 头、校验和等）
    uint16_t nb_processed = rte_ipsec_pkt_process(session, copied_pkts, nb_deq);

    // 6. 发送加密后的包
    uint16_t nb_tx = rte_eth_tx_burst(port_id, tx_queue_id, copied_pkts, nb_processed);

    // 7. 释放未发送的包
    for (uint16_t i = nb_tx; i < nb_processed; i++)
        rte_pktmbuf_free(copied_pkts[i]);

    // 8. 释放 crypto op
    for (uint16_t i = 0; i < nb_deq; i++)
        rte_crypto_op_free(crypto_ops[i]);
}
```

### 6.5 完整的入站处理流程

```c
void
inbound_process(struct rte_ipsec_session *session,
                uint8_t crypto_dev_id, uint16_t crypto_qp_id,
                struct rte_mbuf *pkts[], uint16_t nb_pkts,
                uint16_t port_id, uint16_t tx_queue_id)
{
    struct rte_crypto_op *crypto_ops[MAX_PKT_BURST];

    // 1. 准备 crypto op（入站：提取 ESP 加密载荷）
    uint16_t nb_prep = rte_ipsec_pkt_crypto_prepare(
        session, pkts, crypto_ops, nb_pkts);

    // 2. 入队到 cryptodev
    uint16_t nb_enq = rte_cryptodev_enqueue_burst(
        crypto_dev_id, crypto_qp_id, crypto_ops, nb_prep);

    // 3. 轮询完成
    uint16_t nb_deq = 0;
    do {
        nb_deq += rte_cryptodev_dequeue_burst(
            crypto_dev_id, crypto_qp_id,
            &crypto_ops[nb_deq], MAX_PKT_BURST - nb_deq);
    } while (nb_deq < nb_enq);

    // 4. 从 crypto_op 中提取 mbuf
    struct rte_mbuf *processed_pkts[MAX_PKT_BURST];
    for (uint16_t i = 0; i < nb_deq; i++)
        processed_pkts[i] = crypto_ops[i]->sym->m_src;

    // 5. 完成处理
    //    入站：移除 ESP 头/trailer，验证 ICV，抗重放检查
    //    成功的包：processed_pkts[0..n) 是解密后的明文包
    //    失败的包：processed_pkts[n..nb_deq) 需要应用层处理
    uint16_t nb_ok = rte_ipsec_pkt_process(session, processed_pkts, nb_deq);

    // 6. 转发明文包到本地网络
    for (uint16_t i = 0; i < nb_ok; i++) {
        // 更新 l2_len/l3_len 后，包已恢复为原始格式
        forward_to_local_stack(processed_pkts[i]);
    }

    // 7. 处理失败的包（认证失败、重放等）
    for (uint16_t i = nb_ok; i < nb_deq; i++) {
        // 检查失败原因并记录
        rte_pktmbuf_free(processed_pkts[i]);
    }
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
│  INLINE_CRYPTO: NIC 做加密，CPU 做协议处理                                   │
│  ─────────────────────────────────────                                      │
│  ┌─────────┐     ┌──────────┐     ┌─────────┐     ┌───────┐              │
│  │   CPU   │────►│   NIC    │────►│  Wire   │     │       │              │
│  │ESP 头构造│ DMA │(加密引擎)│     │         │     │       │              │
│  └─────────┘     └──────────┘     └─────────┘     └───────┘              │
│                                                                             │
│  INLINE_PROTOCOL: NIC 做完整 IPsec 处理                                     │
│  ───────────────────────────────────────                                    │
│  ┌─────────┐     ┌──────────┐     ┌───────┐                               │
│  │   CPU   │────►│   NIC    │────►│  Wire │                               │
│  │(仅配置SA)│ DMA │(完整IPsec│     │       │                               │
│  └─────────┘     │  处理)   │     └───────┘                               │
│                   └──────────┘                                             │
│                   │                                                         │
│                   ▼                                                         │
│            ┌─────────────┐                                                  │
│            │ SA lookup   │                                                  │
│            │ (TCAM/HW)   │                                                  │
│            └─────────────┘                                                  │
│                                                                             │
│  优势: CPU 完全不参与数据路径                                               │
│  限制: 需要支持 IPsec 卸载的 NIC (如 Intel E810, Mellanox ConnectX)       │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 7.2 Lookaside IPsec (Crypto 卸载)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     Lookaside IPsec (Crypto 卸载)                         │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  模式: CPU 做协议处理，专门的 Crypto 设备做加密                              │
│                                                                             │
│  ┌─────────┐     ┌──────────────┐     ┌─────────┐     ┌───────┐          │
│  │   CPU   │     │  rte_ipsec   │     │  Crypto │     │  Wire │          │
│  │         │────►│  (ESP 头构造) │────►│  (AES)  │────►│       │          │
│  │         │ DMA │              │ DMA │  QAT/.. │     │       │          │
│  └─────────┘     └──────────────┘     └─────────┘     └───────┘          │
│                                                                             │
│  Packet Flow (Outbound):                                                   │
│  1. CPU 通过 rte_ipsec_pkt_crypto_prepare() 准备 crypto op                │
│  2. crypto op 入队到 cryptodev (QAT / AESNI-MB / SW)                      │
│  3. crypto 设备加密 (GCM/CBC)                                              │
│  4. CPU 通过 rte_ipsec_pkt_process() 完成处理                              │
│  5. 发送加密后的包                                                         │
│                                                                             │
│  常见 Crypto 设备:                                                         │
│  - Intel QAT (QuickAssist Technology)                                      │
│  - Intel AESNI-MB (Multi Buffer, SW)                                       │
│  - ARM Crypto Extension                                                    │
│  - NVIDIA BlueField DPU                                                    │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 7.3 通过 rte_security 配置 HW IPsec

DPDK 中 IPsec 卸载通过 **rte_security** 框架实现，不是通过 ethdev 直接提供的：

```c
#include <rte_security.h>
#include <rte_ethdev.h>

// 1. 获取 ethdev 的 security context
struct rte_security_ctx *ctx = rte_eth_dev_security_ctx_get(port_id);

// 2. 查询设备 IPsec 能力
const struct rte_security_capability *cap;
struct rte_security_capability_idx idx = {
    .action = RTE_SECURITY_ACTION_TYPE_INLINE_PROTOCOL,
    .protocol = RTE_SECURITY_PROTOCOL_IPSEC,
    .ipsec.proto = RTE_SECURITY_IPSEC_SA_PROTO_ESP,
    .ipsec.mode = RTE_SECURITY_IPSEC_SA_MODE_TUNNEL,
    .ipsec.direction = RTE_SECURITY_IPSEC_SA_DIR_EGRESS,
};
cap = rte_security_capability_get(ctx, &idx);
if (!cap) {
    // 设备不支持此 IPsec 配置
}

// 3. 创建 security session
struct rte_security_session_conf sec_conf = {
    .action_type = RTE_SECURITY_ACTION_TYPE_INLINE_PROTOCOL,
    .protocol = RTE_SECURITY_PROTOCOL_IPSEC,
    .ipsec = {
        .spi = 0x12345678,
        .salt = 0x01020304,
        .proto = RTE_SECURITY_IPSEC_SA_PROTO_ESP,
        .mode = RTE_SECURITY_IPSEC_SA_MODE_TUNNEL,
        .direction = RTE_SECURITY_IPSEC_SA_DIR_EGRESS,
        .tunnel.type = RTE_SECURITY_IPSEC_TUNNEL_IPV4,
        .tunnel.ipv4.src_ip = RTE_IPV4(10, 0, 0, 1),
        .tunnel.ipv4.dst_ip = RTE_IPV4(10, 0, 0, 2),
        .tunnel.ipv4.ttl = 64,
    },
    .crypto_xform = &crypto_xform,  // 加密算法配置
};

struct rte_security_session *sec_session = rte_security_session_create(
    ctx, &sec_conf, session_pool);

// 4. 创建 rte_ipsec session 并准备
struct rte_ipsec_session ipsec_session = {
    .sa = &sa,
    .type = RTE_SECURITY_ACTION_TYPE_INLINE_PROTOCOL,
    .security.ses = sec_session,
    .security.ctx = ctx,
};
rte_ipsec_session_prepare(&ipsec_session);

// 5. Inline 模式下，发送包时只需要调用 rte_ipsec_pkt_process()
//    NIC 会自动执行加密和 ESP 封装
uint16_t nb = rte_ipsec_pkt_process(&ipsec_session, pkts, nb_pkts);
rte_eth_tx_burst(port_id, tx_queue_id, pkts, nb);
```

---

## 8. 完整使用示例

### 8.1 创建 Outbound SA

```c
#include <rte_ipsec.h>
#include <rte_ipsec_sa.h>
#include <rte_ipsec_sad.h>
#include <rte_crypto.h>
#include <rte_cryptodev.h>

// 创建一个 ESP Tunnel AES-256-GCM 出站 SA

// 1. 准备 crypto xform（加密参数）
struct rte_crypto_sym_xform crypto_xform = {
    .type = RTE_CRYPTO_SYM_XFORM_AEAD,
    .aead = {
        .algo = RTE_CRYPTO_AEAD_AES_GCM,
        .op = RTE_CRYPTO_AEAD_OP_ENCRYPT,
        .key = { .data = aes_key, .length = 32 },   // 256-bit key
        .iv_offset = sizeof(struct esp_hdr),         // IV 在 ESP 头之后
        .iv.length = 12,                            // GCM IV = 12 字节
        .aad_length = 12,                           // AAD = SPI(4) + Seq(4) + salt(4)
        .digest_length = 16,                        // GCM ICV = 16 字节
    },
    .next = NULL,
};

// 2. 准备 IPsec xform
struct rte_security_ipsec_xform ipsec_xform = {
    .spi = 0x12345678,
    .salt = 0x01020304,
    .direction = RTE_SECURITY_IPSEC_SA_DIR_EGRESS,
    .proto = RTE_SECURITY_IPSEC_SA_PROTO_ESP,
    .mode = RTE_SECURITY_IPSEC_SA_MODE_TUNNEL,
    .options.esn = 1,           // 启用 ESN
    .options.udp_encap = 0,     // 不使用 NAT-T
    .replay_win_sz = 0,        // 出站不需要抗重放
    .tunnel.type = RTE_SECURITY_IPSEC_TUNNEL_IPV4,
    .tunnel.ipv4.src_ip = RTE_IPV4(10, 0, 0, 1),
    .tunnel.ipv4.dst_ip = RTE_IPV4(10, 0, 0, 2),
    .tunnel.ipv4.ttl = 64,
    .life.bytes_soft_limit = 0,
    .life.bytes_hard_limit = UINT64_MAX,
};

// 3. 准备 SA 参数
struct rte_ipsec_sa_prm sa_prm = {
    .flags = 0,
    .ipsec_xform = ipsec_xform,
    .crypto_xform = &crypto_xform,
    .tun.hdr_len = sizeof(struct rte_ipv4_hdr),
    .tun.hdr_l3_off = 0,
    .tun.next_proto = IPPROTO_IPIP,
};

// 4. 计算 SA 大小并分配
int sa_size = rte_ipsec_sa_size(&sa_prm);
struct rte_ipsec_sa *sa = rte_zmalloc("sa", sa_size, RTE_CACHE_LINE_SIZE);

// 5. 初始化 SA
int actual_size = rte_ipsec_sa_init(sa, &sa_prm, sa_size);
if (actual_size < 0) {
    // 初始化失败
}

// 6. 创建 crypto session（lookaside 模式）
struct rte_cryptodev_sym_session *crypto_sess =
    rte_cryptodev_sym_session_create(crypto_dev_id, &crypto_xform, session_pool);

// 7. 创建 ipsec session
struct rte_ipsec_session session = {
    .sa = sa,
    .type = RTE_SECURITY_ACTION_TYPE_LOOKASIDE_PROTOCOL,
    .crypto = {
        .ses = crypto_sess,
        .dev_id = crypto_dev_id,
    },
};
rte_ipsec_session_prepare(&session);

// 8. 添加到 SAD
struct rte_ipsec_sadv4_key sad_key = {
    .spi = rte_cpu_to_be_32(0x12345678),
    .dip = RTE_IPV4(10, 0, 0, 2),
    .sip = RTE_IPV4(10, 0, 0, 1),
};
rte_ipsec_sad_add(sad,
    (const union rte_ipsec_sad_key *)&sad_key,
    RTE_IPSEC_SAD_SPI_DIP_SIP, sa);
```

### 8.2 IPsec Gateway 主处理循环

```c
// Lookaside 模式的 IPsec Gateway 主循环

#define NB_CRYPTO_OP  64
#define MAX_PKT_BURST 32

void
ipsec_gateway_loop(uint16_t port_rx, uint16_t port_tx,
                   uint8_t crypto_dev_id, uint16_t crypto_qp_id,
                   struct rte_ipsec_session *out_session,
                   struct rte_ipsec_session *in_session,
                   struct rte_ipsec_sad *sad)
{
    struct rte_mbuf *pkts[MAX_PKT_BURST];
    struct rte_crypto_op *crypto_ops[NB_CRYPTO_OP];
    struct rte_crypto_op *done_ops[NB_CRYPTO_OP];

    while (1) {
        // ── RX ──
        uint16_t nb_rx = rte_eth_rx_burst(port_rx, 0, pkts, MAX_PKT_BURST);
        if (nb_rx == 0)
            continue;

        // ── 入站处理：解密 ESP 包 ──
        uint16_t nb_inb = 0;
        for (uint16_t i = 0; i < nb_rx; i++) {
            struct rte_ipv4_hdr *iph = rte_pktmbuf_mtod(pkts[i],
                                                         struct rte_ipv4_hdr *);

            if (iph->next_proto_id == IPPROTO_ESP) {
                // ESP 包：需要解密
                pkts[nb_inb++] = pkts[i];
            } else {
                // 非 ESP 包：直接转发或丢弃（SPD 逻辑）
                handle_non_esp(pkts[i]);
            }
        }

        if (nb_inb > 0) {
            // 准备 crypto op
            uint16_t nb_prep = rte_ipsec_pkt_crypto_prepare(
                in_session, pkts, crypto_ops, nb_inb);

            // 入队
            uint16_t nb_enq = rte_cryptodev_enqueue_burst(
                crypto_dev_id, crypto_qp_id, crypto_ops, nb_prep);

            // 轮询完成
            uint16_t nb_done = 0;
            while (nb_done < nb_enq) {
                nb_done += rte_cryptodev_dequeue_burst(
                    crypto_dev_id, crypto_qp_id,
                    &done_ops[nb_done], nb_enq - nb_done);
            }

            // 提取 mbuf 并完成处理
            struct rte_mbuf *decrypted[MAX_PKT_BURST];
            for (uint16_t i = 0; i < nb_done; i++)
                decrypted[i] = done_ops[i]->sym->m_src;

            uint16_t nb_ok = rte_ipsec_pkt_process(in_session, decrypted, nb_done);

            // 转发解密后的包
            for (uint16_t i = 0; i < nb_ok; i++)
                forward_decrypted(decrypted[i]);

            // 释放失败的包和 crypto op
            for (uint16_t i = nb_ok; i < nb_done; i++)
                rte_pktmbuf_free(decrypted[i]);
            for (uint16_t i = 0; i < nb_done; i++)
                rte_crypto_op_free(done_ops[i]);
        }
    }
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
│  AES-256-GCM (Tunnel mode, 64B packets)                                    │
│                                                                             │
│  方案                  吞吐量        CPU 利用率    CPU cycles/pkt          │
│  ──────────────────────────────────────────────────────────────────────── │
│  软件 (AESNI-MB)      15 Gbps         100%           2000                 │
│  QAT (2x40GbE)       70 Gbps          20%            250                    │
│  Inline (Intel E810)   40 Gbps          5%            50                   │
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

| 优化项            | 说明                                                   | 效果       |
| ----------------- | ------------------------------------------------------ | ---------- |
| **批量处理**      | 使用 `rte_ipsec_pkt_crypto_prepare` 批量准备 crypto op | 3-5x 提升  |
| **硬件卸载**      | Inline 或 QAT 加速，CPU 不参与加密                     | 10x+ 提升  |
| **ESN**           | 避免 32-bit 序列号溢出                                 | 支持长连接 |
| **连续 mbuf**     | 使用单 segment mbuf，减少 DMA 碎片                     | 降低延迟   |
| **多队列并行**    | 每个 lcore 独立的 crypto queue pair + IPsec session    | 线性扩展   |
| **inline crypto** | 对于支持 RTE_SECURITY_ACTION_TYPE_INLINE_CRYPTO 的设备 | 最低延迟   |

---

## 10. 小结

本章核心要点：

1. **IPsec 体系结构**：SPD（安全策略）→ SAD（安全关联）→ ESP/AH 协议。DPDK 提供了 SAD 库，但**没有内置 SPD 库**——SPD 由应用层自行实现（通常用 `rte_acl`）。

2. **ESP vs AH**：ESP 提供加密+认证，AH 仅认证。Tunnel 模式封装整个 IP 包，Transport 模式仅加密载荷。

3. **SA（rte_ipsec_sa）**：不透明结构体，通过 `rte_ipsec_sa_prm` + `rte_ipsec_sa_init()` 初始化。内部用 64-bit type 位掩码编码方向、协议、模式、ESN 等属性。

4. **SAD（rte_ipsec_sad）**：支持三种查找粒度（SPI only / SPI+DIP / SPI+DIP+SIP），批量查找 API `rte_ipsec_sad_lookup()`。

5. **Session（rte_ipsec_session）**：聚合 SA + crypto/security session + 处理函数指针。通过 `rte_ipsec_session_prepare()` 初始化。

6. **包处理两阶段**：`rte_ipsec_pkt_crypto_prepare()`（准备 crypto op）→ `rte_ipsec_pkt_process()`（完成处理）。方向自动由 SA 的 type 决定。

7. **IPsec 卸载**：通过 `rte_security` 框架配置。`INLINE_PROTOCOL`（NIC 全处理）、`INLINE_CRYPTO`（NIC 加密 + CPU 协议）、`LOOKASIDE_PROTOCOL`（外部 crypto 设备）。

8. **抗重放**：在 SA 的 `replay_win_sz` 参数配置，`rte_ipsec_pkt_process()` 内部自动检查。

9. **性能**：QAT 可达 70 Gbps，Inline NIC 可达 40 Gbps，软件 AESNI 方案 15 Gbps。

10. **应用场景**：Site-to-Site VPN、Remote Access VPN、Cloud IPsec、5G UPF 加密。

**下一篇预告**：[[2026-04-09-dpdk-deep-dive-ch23-tls-dtls-accel|第二十三章]]将讲解 TLS/DTLS 加速与 session 管理——用户态 TLS 卸载。

---

> [!tip] 参考文献
>
> - RFC 4301, "Security Architecture for IPsec"
> - RFC 4302, "IP Authentication Header (AH)"
> - RFC 4303, "Encapsulating Security Payload (ESP)"
> - DPDK IPsec Library, https://doc.dpdk.org/guides/prog_guide/ipsec_lib.html
> - DPDK Security Library, https://doc.dpdk.org/guides/prog_guide/rte_security.html
> - DPDK ipsec-secgw Sample, https://doc.dpdk.org/guides/sample_app_ug/ipsec_secgw.html
