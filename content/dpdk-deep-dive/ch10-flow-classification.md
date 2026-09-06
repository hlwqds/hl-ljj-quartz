---
title: "DPDK 深度探索 (十)：Flow Classification 流量分类与 rte_flow"
date: 2026-04-09
tags: [dpdk, series, flow, rte_flow, RSS, ACL, Flow Director, match-action]
description: "深入理解 DPDK 流量分类——RSS 哈希分散、Flow Director 精确匹配、ACL 库加速五元组查找、以及 rte_flow 通用匹配动作框架"
---

> [!info] DPDK 深度探索系列 0. [[dpdk-deep-dive|全栈学习路径总览]]
> 1-9. 前九章已完成 10. **第十章：Flow Classification 流量分类与 rte_flow**

---

## 1. 概述：为什么需要流量分类？

DPDK 处理百万级数据包时，需要识别"这是什么样的流量"：

| 场景               | 需求                                         |
| ------------------ | -------------------------------------------- |
| **多核负载均衡**   | 将不同 flows 分散到不同 lcore 处理           |
| **服务质量 (QoS)** | 语音流量优先，游戏流量次之，普通流量普通处理 |
| **安全过滤**       | 识别并阻断恶意流量                           |
| **会话跟踪**       | 同一个 flow 的包必须到同一个 lcore           |
| **策略路由**       | 特定流量走特定路径                           |

### 1.1 流量分类技术全景

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        DPDK 流量分类技术栈                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  用户态分类                                                                 │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │                     rte_flow (通用匹配-动作框架)                      │  │
│  │  ┌────────────┐  ┌────────────┐  ┌────────────┐  ┌────────────┐    │  │
│  │  │ Pattern    │  │    Action  │  │   Flow     │  │   Table    │    │  │
│  │  │ Matching   │  │  Steering  │  │  Inspection │  │  Management│    │  │
│  │  └────────────┘  └────────────┘  └────────────┘  └────────────┘    │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
│  硬件卸载分类                                                               │
│  ┌────────────┐  ┌────────────┐  ┌────────────┐                           │
│  │ RSS        │  │ Flow       │  │   ACL      │                           │
│  │ (散列分散)  │  │ Director   │  │  (访问控制) │                           │
│  │            │  │ (精确匹配)  │  │            │                           │
│  └────────────┘  └────────────┘  └────────────┘                           │
│                                                                             │
│  软件分类                                                                  │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │                    librte_acl (Trie + NFA/DFA)                          │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. RSS (Receive Side Scaling)

### 2.1 RSS 原理

RSS 使用 Toeplitz 哈希算法，将数据包分散到多个队列：

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              RSS 哈希分散                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   输入 (Layer 3/4 Header)                                                  │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │  Src IP, Dst IP, Src Port, Dst Port, Protocol                     │  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│                                    │                                        │
│                                    ▼                                        │
│                         ┌──────────────────┐                              │
│                         │  Toeplitz Hash   │                              │
│                         │  (对称哈希)       │                              │
│                         └────────┬─────────┘                              │
│                                    │                                        │
│                                    ▼                                        │
│                         ┌──────────────────┐                              │
│                         │  Hash Value      │                              │
│                         │  (32-bit)        │                              │
│                         └────────┬─────────┘                              │
│                                    │                                        │
│                                    ▼                                        │
│   输出                         ┌──────────────────┐                       │
│   ┌─────────────────────────────────────────────────────────────────────┐│
│   │  queue_id = hash & (nb_queues - 1)                                  ││
│   │                                                                      ││
│   │  queue[0] ◄── hash = 0x1234...                                       ││
│   │  queue[1] ◄── hash = 0x5678...                                       ││
│   │  queue[2] ◄── hash = 0x9ABC...                                       ││
│   │  queue[3] ◄── hash = 0xDEF0...                                       ││
│   └─────────────────────────────────────────────────────────────────────┘│
│                                                                             │
│   特点：                                                                   │
│   - 同一 flow 的包 → 同一队列（保证顺序）                                   │
│   - 不同 flows → 均匀分散到各队列                                          │
│   - NIC 硬件自动完成，无需 CPU 介入                                        │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 2.2 RSS 配置

```c
// 配置 RSS
struct rte_eth_conf conf = {
    .rxmode = {
        .mq_mode = RTE_ETH_MQ_RX_RSS,
        .offloads = DEV_RX_OFFLOAD_RSS_HASH,
    },
    .rx_adv_conf = {
        .rss_conf = {
            .rss_key = NULL,           // NULL = 使用默认 KEY
            .rss_key_len = 40,         // 40 字节
            .rss_hf = RTE_ETH_RSS_IP   // 哈希字段
                               | RTE_ETH_RSS_TCP
                               | RTE_ETH_RSS_UDP,
        },
    },
};

// RSS 哈希字段（部分常用值，完整列表见 rte_ethdev.h）
#define RTE_ETH_RSS_IPV4              0x1       // bit 0: IPv4（含所有 IPv4 子类型）
#define RTE_ETH_RSS_FRAG_IPV4         0x2       // bit 1: IPv4 分片
#define RTE_ETH_RSS_NONFRAG_IPV4_TCP  0x4       // bit 2: IPv4 非_frag + TCP
#define RTE_ETH_RSS_NONFRAG_IPV4_UDP  0x8       // bit 3: IPv4 非_frag + UDP
#define RTE_ETH_RSS_NONFRAG_IPV4_SCTP 0x10      // bit 4: IPv4 非_frag + SCTP
#define RTE_ETH_RSS_NONFRAG_IPV4_OTHER 0x20     // bit 5: IPv4 非_frag + 其他
#define RTE_ETH_RSS_IPV6              0x40      // bit 6: IPv6
#define RTE_ETH_RSS_L2_PAYLOAD        0x1000    // bit 12: L2 payload
#define RTE_ETH_RSS_L3_SRC_ONLY       0x10000   // bit 16: 仅 L3 源地址
#define RTE_ETH_RSS_L3_DST_ONLY       0x20000   // bit 17: 仅 L3 目的地址
#define RTE_ETH_RSS_L4_SRC_ONLY       0x40000   // bit 18: 仅 L4 源端口
#define RTE_ETH_RSS_L4_DST_ONLY       0x80000   // bit 19: 仅 L4 目的端口

// 注意：RTE_ETH_RSS_IP 和 RTE_ETH_RSS_TCP 是组合宏，不是单个 bit
// RTE_ETH_RSS_IP = RTE_ETH_RSS_IPV4 | RTE_ETH_RSS_IPV6 | RTE_ETH_RSS_FRAG_IPV4 | ...
// RTE_ETH_RSS_TCP = 所有 TCP 相关 bit 的组合
// RTE_ETH_RSS_UDP = 所有 UDP 相关 bit 的组合
```

### 2.3 RSS 硬件实现

```c
// RSS 哈希计算（软件实现，NIC 硬件自动完成，这里仅展示原理）
// 实际收包时 NIC 硬件已经算好了，CPU 只需要读 m->hash.rss

static inline uint32_t
rss_hash_ipv4_tcp(const struct rte_ipv4_hdr *ip,
                   const struct rte_tcp_hdr *tcp,
                   const uint8_t *rss_key)
{
    // Toeplitz 哈希输入：将五元组按 4 字节对齐拼成数组
    uint32_t input[6];
    uint32_t input_len = 0;

    // src_ip (4 字节) + dst_ip (4 字节)
    input[0] = ip->src_addr;
    input[1] = ip->dst_addr;
    input_len = 2;

    // src_port (2 字节) + dst_port (2 字节) 拼成一个 uint32_t
    // 注意：网络字节序，低 16 位是 src_port，高 16 位是 dst_port
    input[2] = (uint32_t)tcp->src_port | ((uint32_t)tcp->dst_port << 16);
    input_len = 3;

    return rte_softrss_be(input, input_len, rss_key);
    // rte_softrss_be 签名:
    //   uint32_t rte_softrss_be(const uint32_t *input,
    //                             uint32_t input_len,    // uint32_t 个数
    //                             const uint8_t *key);
    // key 需要通过 rte_convert_rss_key() 预转换
}
```

### 2.4 对称哈希与 Hash 算法选择

#### 问题：非对称哈希导致双向流量分散

默认 Toeplitz 哈希把 src_ip/dst_ip、src_port/dst_port 当作不同字段顺序输入，交换方向后 hash 值不同：

```
  同一条 TCP 连接的两个方向：

  请求方向 (A→B)                         响应方向 (B→A)
  ┌──────────────────────┐               ┌──────────────────────┐
  │ src_ip  = 10.0.0.1   │               │ src_ip  = 10.0.0.2   │
  │ dst_ip  = 10.0.0.2   │               │ dst_ip  = 10.0.0.1   │
  │ src_port = 12345     │               │ src_port = 80        │
  │ dst_port = 80        │               │ dst_port = 12345     │
  └──────────┬───────────┘               └──────────┬───────────┘
             │                                      │
             ▼                                      ▼
        hash = 0xABCD                          hash = 0x37F1
             │                                      │
             ▼                                      ▼
        queue 3                                 queue 1

  问题：同一连接的正反方向包到了不同队列 → 不同 lcore 处理
        → 连接状态需要跨 lcore 共享或同步，严重影响性能
```

这在**有状态网关**（NAT、Firewall、Conntrack、Load Balancer）中是致命的——必须保证双向流量到同一队列。

#### 解决方案一：对称 RSS (Symmetric RSS)

DPDK 提供了 `RTE_ETH_RSS_SYMMETRIC` 功能标志，启用后硬件会自动将 src/dst 对调后再做一次 hash，取较小值（或组合），保证双向一致：

```c
// 查询硬件是否支持对称 RSS
struct rte_eth_dev_info dev_info;
rte_eth_dev_info_get(port_id, &dev_info);

if (dev_info.hash_key_config.supported_hash_functions &
    RTE_ETH_HASH_FUNCTION_SYMMETRIC_TOEPLITZ) {
    printf("硬件支持对称 Toeplitz\n");
}

// 启用对称 RSS：在 rss_hf 中加入 RTE_ETH_RSS_SYMMETRIC
struct rte_eth_rss_conf rss_conf;
rte_eth_dev_rss_hash_conf_get(port_id, &rss_conf);

rss_conf.rss_hf |= RTE_ETH_RSS_SYMMETRIC;

int ret = rte_eth_dev_rss_hash_conf_set(port_id, &rss_conf);
if (ret != 0) {
    printf("对称 RSS 设置失败: %s\n", strerror(-ret));
    // 可能硬件不支持，需要软件兜底
}
```

对称 Toeplitz 的原理很简单：对输入字段排序，使 (A→B) 和 (B→A) 产生相同的 hash 输入：

```
  标准 Toeplitz 输入：                     对称 Toeplitz 输入：
  [src_ip, dst_ip, src_port, dst_port]     [min(src,dst), max(src,dst), min(sport,dport), max(sport,dport)]

  A→B: [10.0.0.1, 10.0.0.2, 12345, 80]   A→B: [10.0.0.1, 10.0.0.2, 80, 12345]
  B→A: [10.0.0.2, 10.0.0.1, 80, 12345]    B→A: [10.0.0.1, 10.0.0.2, 80, 12345]
                                         ─────────────────────────────────────
         hash 不同                                hash 相同 ✓
```

#### 解决方案二：软件对称哈希（硬件不支持时）

不是所有 NIC 都支持对称 RSS。对于不支持的硬件，可以在收包路径上用软件补正：

```c
// 软件对称 hash：对原始 hash 输入排序后重新计算
static inline uint32_t
symmetric_rss_hash(uint32_t ip_a, uint32_t ip_b,
                   uint16_t port_a, uint16_t port_b,
                   const uint8_t *rss_key)
{
    // 排序：确保输入顺序一致
    if (ip_a > ip_b) {
        uint32_t tmp_ip = ip_a; ip_a = ip_b; ip_b = tmp_ip;
        uint16_t tmp_port = port_a; port_a = port_b; port_b = tmp_port;
    }

    uint32_t input[3];
    input[0] = ip_a;
    input[1] = ip_b;
    input[2] = (uint32_t)port_a | ((uint32_t)port_b << 16);

    return rte_softrss_be(input, 3, rss_key);
}
```

> [!warning] 软件对称 hash 的代价
> 每次 hash 需要 3 次比较 + 可能的交换，再加一次 Toeplitz 计算。在 14.88Mpps 线速下，
> 大约增加 ~5-8ns/包 的延迟。对于非线速场景（如出口网关）完全可以接受。

#### Hash 算法选择

不同硬件支持的 RSS hash 算法不同，DPDK 通过 `rte_eth_hash_function` 枚举统一抽象：

```c
// rte_ethdev.h 中的 hash 算法枚举
enum rte_eth_hash_function {
    RTE_ETH_HASH_FUNCTION_DEFAULT = 0,    // 硬件默认（通常是 Toeplitz）
    RTE_ETH_HASH_FUNCTION_TOEPLITZ,       // Toeplitz（最通用，RFC 1071）
    RTE_ETH_HASH_FUNCTION_SIMPLE_XOR,     // 简单异或（最快，但分布较差）
    RTE_ETH_HASH_FUNCTION_SYMMETRIC_TOEPLITZ,  // 对称 Toeplitz
    RTE_ETH_HASH_FUNCTION_SIMPLE_XOR_SYM,      // 对称简单异或
    RTE_ETH_HASH_FUNCTION_CRC,            // CRC32（部分 ARM NIC）
};
```

```c
// 查询硬件支持的 hash 算法
struct rte_eth_dev_info dev_info;
rte_eth_dev_info_get(port_id, &dev_info);

uint64_t supported = dev_info.hash_key_config.supported_hash_functions;

printf("支持的 hash 算法:\n");
if (supported & RTE_ETH_HASH_FUNCTION_TOEPLITZ)
    printf("  - Toeplitz\n");
if (supported & RTE_ETH_HASH_FUNCTION_SYMMETRIC_TOEPLITZ)
    printf("  - Symmetric Toeplitz\n");
if (supported & RTE_ETH_HASH_FUNCTION_SIMPLE_XOR)
    printf("  - Simple XOR\n");

// 设置 hash 算法（通过 rss_conf）
struct rte_eth_rss_conf rss_conf;
rte_eth_dev_rss_hash_conf_get(port_id, &rss_conf);

// 指定 hash 函数
rss_conf.algorithm = RTE_ETH_HASH_FUNCTION_SYMMETRIC_TOEPLITZ;
rss_conf.rss_hf = RTE_ETH_RSS_NONFRAG_IPV4_TCP | RTE_ETH_RSS_NONFRAG_IPV4_UDP
                | RTE_ETH_RSS_SYMMETRIC;

int ret = rte_eth_dev_rss_hash_conf_set(port_id, &rss_conf);
```

#### 算法对比

```
┌─────────────────────────┬──────────────┬──────────────┬──────────────────┐
│ Hash 算法               │ 分布质量      │ 对称性       │ 典型硬件         │
├─────────────────────────┼──────────────┼──────────────┼──────────────────┤
│ Toeplitz                │ 好           │ ✗            │ Intel ixgbe/i40e │
│ Symmetric Toeplitz      │ 好           │ ✓            │ Intel i40e/Mellanox│
│ Simple XOR              │ 差           │ ✗            │ 部分 ARM NIC     │
│ Simple XOR (symmetric)  │ 差           │ ✓            │ 部分 ARM NIC     │
│ CRC32                   │ 中           │ ✗            │ Marvell, ARM     │
└─────────────────────────┴──────────────┴──────────────┴──────────────────┘

选型建议：
  - 默认场景（无状态转发）        → Toeplitz，分布好，兼容性强
  - 有状态网关（NAT/FW/LB）       → Symmetric Toeplitz，必须保证双向一致
  - 性能极致、对分布不敏感         → Simple XOR，计算开销最小
```

#### 通过 ethtool 配置对称 RSS（内核态）

DPDK 绑定端口之前，或者未使用 DPDK 的场景下，可以通过 `ethtool` 配置 RSS。但需要注意：**不同厂商实现对称 hash 的机制完全不同**，不能一概而论。

**Mellanox/ConnectX — 特殊 RSS Key**

Mellanox 的做法是写入一组精心构造的 Toeplitz key，利用 key 的数学特性使 hash 输出对称：

```bash
# 查看当前 RSS 配置
ethtool -x eth3

# 输出示例：
# RSS hash key:
# 6D:5A:6D:5A:6D:5A:6D:5A:6D:5A:6D:5A:6D:5A:6D:5A:6D:5A:6D:5A:6D:5A:6D:5A:6D:5A:6D:5A:6D:5A:6D:5A:6D:5A:6D:5A:6D:5A:6D:5A
# RSS indirection table:
# 0:  0  1  2  3  4  5  6  7  8  9  10  11  12  13  14  15
# 16: 0  1  2  3  4  5  6  7  8  9  10  11  12  13  14  15

# 写入对称 key + 均匀分配到 16 个队列
ethtool -X eth3 \
  hkey 6D:5A:6D:5A:6D:5A:6D:5A:6D:5A:6D:5A:6D:5A:6D:5A:6D:5A:6D:5A:6D:5A:6D:5A:6D:5A:6D:5A:6D:5A:6D:5A:6D:5A:6D:5A:6D:5A:6D:5A \
  equal 16

# 查看支持的 hash 字段组合
ethtool -n eth3 rx-flow-hash tcp4

# 查看 RSS 是否启用
ethtool -k eth3 | grep hash
```

`6D:5A` 交替重复 key 的数学原理：

```
Toeplitz 哈希中，key 的每个字节控制输入中对应 bit 位的权重。
对称 Toeplitz 矩阵要求：输入位 i 和输入位 (N-i) 的权重相同。

6D = 0110_1101
5A = 0101_1010
↑              ↑
bit 7..0     bit 7..0

6D 和 5A 互为"位翻转"关系：
  6D = ~5A 的低 7 位 + 保留 bit 7
  使得对称位置的 bit 权重互补，从而 hash(A,B) = hash(B,A)

这个 key 在 Mellanox ConnectX 的 PRM（Programmer's Reference Manual）
中有明确定义，是厂商提供的标准对称 key。
```

> [!warning] 6D:5A key 只对 Mellanox 有效
> 把这个 key 写到 Intel 网卡上不会产生对称 hash。Intel 的对称 hash 依赖
> 硬件内部重排输入字段，和 key 无关。使用前必须确认网卡型号。

**Intel 网卡 — 硬件功能标志**

Intel 不靠特殊 key，而是通过驱动标志让硬件自动重排 src/dst：

```bash
# 部分 Intel 驱动支持通过 ethtool 配置 hash 字段
# sdfn 表示：s(src) d(dst) f(fwd/both) n(no-change)
# 让 src 和 dst 都参与 hash 且位置对称
ethtool -N eth3 rx-flow-hash tcp4 sdfn

# 更可靠的方式是直接通过 DPDK API 配置（见上文代码示例）
```

**厂商差异总结**

```
┌───────────────────┬──────────────────────────────┬──────────────────────┐
│ 厂商              │ 对称 hash 机制               │ 配置方式             │
├───────────────────┼──────────────────────────────┼──────────────────────┤
│ Mellanox ConnectX │ 特殊 Toeplitz key 产生       │ ethtool -X 写入      │
│ (MLX4/MLX5)      │ 对称输出                     │ 6D:5A key            │
├───────────────────┼──────────────────────────────┼──────────────────────┤
│ Intel ixgbe/i40e/ │ 硬件内部 min/max 排序        │ DPDK: algorithm =   │
│ ice               │ 输入字段                     │ SYMMETRIC_TOEPLITZ  │
├───────────────────┼──────────────────────────────┼──────────────────────┤
│ Broadcom (bnxt)   │ 固件支持对称模式             │ firmware CLI 配置    │
├───────────────────┼──────────────────────────────┼──────────────────────┤
│ 部分 ARM NIC      │ 不支持                       │ 只能软件对称 hash    │
└───────────────────┴──────────────────────────────┴──────────────────────┘

重要：ethtool 操作的是内核态 RSS，DPDK 绑定端口后两者独立。
      使用 DPDK 时必须通过 rte_eth_dev_rss_hash_conf_set() 配置，
      ethtool 写入的 key 不会被 DPDK PMD 继承。
```

---

## 3. Flow Director (精确匹配)

### 3.1 Flow Director 原理

Flow Director 是 Intel 特有的硬件功能，支持精确的五元组匹配：

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          Flow Director vs RSS                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  RSS (散列分散)                                                             │
│  ─────────────                                                             │
│  flow_key = hash(5-tuple)                                                  │
│  queue = hash & mask                                                       │
│                                                                             │
│  问题：                                                                   │
│  - 无法指定特定 flow 到特定队列                                            │
│  - 无法过滤特定 flow                                                       │
│  - 无法区分不同的 flows                                                    │
│                                                                             │
│  Flow Director (精确匹配)                                                  │
│  ───────────────────────                                                   │
│  flow_key = hash(5-tuple) 存储到 FDIR Table                                 │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                    Flow Director Table                               │   │
│  │  ┌──────────┬──────────┬──────────┬──────────┬──────────┬────────┐    │   │
│  │  │ Src IP  │ Dst IP  │Protocol  │ Src Port│ Dst Port│ Queue  │    │   │
│  │  ├──────────┼──────────┼──────────┼──────────┼──────────┼────────┤    │   │
│  │  │ 10.0.0.1│ 10.0.0.2│   TCP    │   80    │  12345  │   0    │    │   │
│  │  │ 10.0.0.3│ 10.0.0.4│   UDP    │   53    │  54321  │   1    │    │   │
│  │  │   *     │   *     │   *      │   *     │   *     │ drop   │    │   │
│  │  └──────────┴──────────┴──────────┴──────────┴──────────┴────────┘    │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  优势：                                                                   │
│  - 精确匹配特定 flow                                                        │
│  - 可以 DROP 特定流量                                                       │
│  - 支持 ACL 规则                                                            │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 3.2 Flow Director 配置

```c
// lib/ethdev/rte_eth_ctrl.h（不是 rte_fdir.h）

// Flow Director 模式
enum rte_eth_fdir_mode {
    RTE_ETH_FDIR_MODE_NONE      = 0,  // 关闭
    RTE_ETH_FDIR_MODE_SIGNATURE = 1,  // 签名模式（节省 FDIR 表项）
    RTE_ETH_FDIR_MODE_PERFECT   = 2,  // 精确匹配（默认）
    RTE_ETH_FDIR_MODE_PERFECT_MAC_VLAN = 3,  // 精确匹配 + MAC/VLAN
    RTE_ETH_FDIR_MODE_PERFECT_TUNNEL = 4,  // 隧道精确匹配
};

// FDIR 过滤器输入（五元组）
struct rte_eth_fdir_input {
    uint16_t flow_type;  // 指定匹配类型（如 ETH_RSS_IPV4_TCP）
    union {
        struct rte_eth_ipv4_flow ipv4;   // src/dst IP + src/dst port
        struct rte_eth_ipv6_flow ipv6;
        struct rte_eth_udpv4_flow udpv4;
    } flow;
    uint32_t flex_bytes;  // 灵活匹配字节
};

// FDIR 动作
struct rte_eth_fdir_action {
    enum rte_eth_fdir_action_type action_type;
    union {
        uint16_t rx_queue;   // QUEUE 动作的目标队列
        uint8_t  flex_off;   // FLEX 动作的偏移
    };
};

// 完整的 FDIR 过滤器结构
struct rte_eth_fdir_filter {
    uint16_t soft_id;              // 软件 ID（用户标识）
    enum rte_eth_fdir_behavior behavior;  // 匹配/不匹配时的行为
    struct rte_eth_fdir_input input;      // 匹配条件
    struct rte_eth_fdir_action action;    // 匹配后执行的动作
};

// 匹配/不匹配行为
enum rte_eth_fdir_behavior {
    RTE_ETH_FDIR_NO_BSWITCH = 0,    // 不影响队列分配
    RTE_ETH_FDIR_BSWITCH_FILTER = 1, // 匹配时执行 action，不匹配走 RSS
    RTE_ETH_FDIR_BSWITCH_FILTER_PERFECT = 2, // 仅在完美匹配时执行
};

// 动作类型
enum rte_eth_fdir_action_type {
    RTE_ETH_FDIR_ACTION_QUEUE     = 0,  // 分配到特定队列
    RTE_ETH_FDIR_ACTION_DROP      = 1,  // 丢弃
    RTE_ETH_FDIR_ACTION_PASSTHRU  = 2,  // 放行（走正常路径）
    RTE_ETH_FDIR_ACTION_REJECT    = 3,  // 拒绝
    RTE_ETH_FDIR_ACTION_FLEX      = 4,  // 灵活字节匹配
};

// 添加 Flow Director 规则（通过通用过滤 API）
int
rte_eth_dev_filter_ctrl(uint16_t port_id,
                         enum rte_filter_type filter_type,
                         enum rte_filter_op filter_op,
                         void *arg);
// filter_type = RTE_ETH_FILTER_FDIR
// filter_op   = RTE_ETH_FILTER_ADD / RTE_ETH_FILTER_DELETE
// arg         = (struct rte_eth_fdir_filter *)
```

### 3.3 Flow Director 使用示例

```c
// 示例：将来自 10.0.0.1 的 TCP 流量分配到队列 3

struct rte_eth_fdir_filter filter;

memset(&filter, 0, sizeof(filter));
filter.soft_id = 0;
filter.behavior = RTE_ETH_FDIR_BSWITCH_FILTER;

// 设置匹配条件：IPv4 + TCP 五元组
filter.input.flow_type = RTE_ETH_FLOW_NONFRAG_IPV4_TCP;
filter.input.flow.ipv4.src_ip = rte_cpu_to_be_32(RTE_IPV4(10, 0, 0, 1));
filter.input.flow.ipv4.dst_ip = 0;          // 匹配任意目的 IP
filter.input.flow.ipv4.src_port = 0;          // 匹配任意源端口
filter.input.flow.ipv4.dst_port = 0;          // 匹配任意目的端口

// 设置动作：分配到队列 3
filter.action.action_type = RTE_ETH_FDIR_ACTION_QUEUE;
filter.action.rx_queue = 3;

// 添加规则
int ret = rte_eth_dev_filter_ctrl(port_id,
                                    RTE_ETH_FILTER_FDIR,
                                    RTE_ETH_FILTER_ADD,
                                    &filter);
if (ret < 0)
    rte_exit(EXIT_FAILURE, "Failed to add FDIR rule\n");

printf("Flow Director: 10.0.0.1 TCP -> queue 3\n");
```

---

## 4. librte_acl (访问控制列表)

### 4.1 ACL 库概述

当硬件分类不够用时，librte_acl 提供软件层面的高性能 ACL：

```c
// lib/acl/rte_acl.h

// ACL 规则定义（使用宏生成）
// 每个字段包含 value（匹配值）和 mask_range（掩码或范围）
struct rte_acl_field {
    uint32_t value;                       // 匹配值
    union rte_acl_field_types {
        uint32_t mask;                    // 位掩码（MASK 类型）
        uint32_t range;                   // 范围（RANGE 类型，低 16 位=低，高 16 位=高）
    } mask_range;
};

// 规则数据（匹配后返回的信息）
struct rte_acl_rule_data {
    uint32_t category_mask;  // 类别掩码
    int32_t  priority;       // 优先级
    uint32_t userdata;       // 用户数据（存储 action、queue 等）
};

// 用宏定义规则结构（NUM_FIELDS = 匹配字段数）
RTE_ACL_RULE_DEF(acl_rule, NUM_FIELDS)
// 展开后生成:
struct acl_rule {
    struct rte_acl_rule_data data;       // 规则数据
    struct rte_acl_field field[NUM_FIELDS]; // 匹配字段数组
};
```

### 4.2 ACL 构建流程

```c
#define NUM_FIELDS 5

// 用宏定义规则结构
RTE_ACL_RULE_DEF(acl_rule, NUM_FIELDS);

// 1. 创建 ACL 上下文
struct rte_acl_ctx *acl_ctx;
struct rte_acl_param acl_param = {
    .name = "my_acl",
    .socket_id = SOCKET_ID_ANY,
    .rule_size = sizeof(struct acl_rule),
    .max_rule_count = 1024,
};

acl_ctx = rte_acl_create(&acl_param);
if (!acl_ctx) {
    // 创建失败
}

// 2. 添加规则
struct acl_rule rule;
memset(&rule, 0, sizeof(rule));

// 规则数据：匹配后返回 DROP（编码在 userdata 中）
rule.data.category_mask = 1;
rule.data.priority = 1;
rule.data.userdata = ACL_ACTION_DROP;

// 匹配字段：src_ip = 10.0.0.0/24
rule.field[0].value = RTE_IPV4(10, 0, 0, 0);
rule.field[0].mask_range.mask = RTE_IPV4(255, 255, 255, 0);

// dst_ip: 不限制
rule.field[1].value = 0;
rule.field[1].mask_range.mask = 0;

// src_port: 不限制
rule.field[2].value = 0;
rule.field[2].mask_range.mask = 0;

// dst_port: 不限制
rule.field[3].value = 0;
rule.field[3].mask_range.mask = 0;

// proto: TCP
rule.field[4].value = IPPROTO_TCP;
rule.field[4].mask_range.mask = 0xFF;

rte_acl_add_rules(acl_ctx, (struct rte_acl_rule *)&rule, 1);

// 3. 定义字段布局并构建（Trie 结构）
struct rte_acl_config build_config = {
    .num_categories = 1,           // 单一类别
    .num_fields = NUM_FIELDS,
    .defs = {
        [0] = { .type = RTE_ACL_FIELD_TYPE_BITMASK,
               .size = sizeof(uint32_t), .offset = sizeof(struct rte_ether_hdr),
               .field_index = 0, .input_index = 0 },
        [1] = { .type = RTE_ACL_FIELD_TYPE_BITMASK,
               .size = sizeof(uint32_t), .offset = sizeof(struct rte_ether_hdr) + 12,
               .field_index = 0, .input_index = 1 },
        [2] = { .type = RTE_ACL_FIELD_TYPE_RANGE,
               .size = sizeof(uint16_t), .offset = sizeof(struct rte_ether_hdr) + 20,
               .field_index = 0, .input_index = 2 },
        [3] = { .type = RTE_ACL_FIELD_TYPE_RANGE,
               .size = sizeof(uint16_t), .offset = sizeof(struct rte_ether_hdr) + 22,
               .field_index = 0, .input_index = 3 },
        [4] = { .type = RTE_ACL_FIELD_TYPE_BITMASK,
               .size = sizeof(uint8_t), .offset = sizeof(struct rte_ether_hdr) + 23,
               .field_index = 0, .input_index = 4 },
    },
};
};

rte_acl_build(acl_ctx, &build_config);
```

### 4.3 ACL 查找

```c
// 查找数据包匹配哪个规则
uint32_t results[1];  // 只查找最优匹配

int
classify_packet(struct rte_acl_ctx *acl_ctx,
                 struct rte_mbuf *m)
{
    uint8_t buffer[128];
    struct rte_ether_hdr *eth = rte_pktmbuf_mtod(m, struct rte_ether_hdr *);

    // 提取要匹配的字段到 buffer
    struct rte_ipv4_hdr *ip = (struct rte_ipv4_hdr *)(eth + 1);
    memcpy(buffer + 12, &ip->src_addr, 4);
    memcpy(buffer + 16, &ip->dst_addr, 4);

    if (ip->next_proto_id == IPPROTO_TCP) {
        struct rte_tcp_hdr *tcp = (struct rte_tcp_hdr *)((char *)ip +
                        (ip->version_ihl & 0x0F) * 4);
        *(uint16_t *)(buffer + 20) = tcp->src_port;
        *(uint16_t *)(buffer + 22) = tcp->dst_port;
        buffer[23] = IPPROTO_TCP;
    }

    // 执行查找
    int ret = rte_acl_classify(acl_ctx,
                                &buffer,  // 输入
                                results,   // 输出
                                1,         // 只查一条
                                RTE_ACL_CLASSIFY_DEFAULT);

    if (ret == 0) {
        uint32_t action = results[0] & 0xFF;
        return action;
    }

    return 0;  // 无匹配
}
```

### 4.4 ACL 内部实现：Trie + 多字段比较

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     ACL 内部结构（Trie + 多字段并行比较）                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  示例规则：                                                                 │
│  Rule 1: src_ip=10.0.0.0/24, action=ACCEPT                                  │
│  Rule 2: src_ip=10.0.1.0/24, action=DROP                                    │
│                                                                             │
│  构建过程：                                                                 │
│                                                                             │
│  1. 规则 → NFA (非确定性有限自动机)                                        │
│     多条规则合并为一个 NFA，共享公共前缀                                  │
│                                                                             │
│     ┌────────┐                                                            │
│     │ START  │                                                            │
│     └───┬────┘                                                            │
│         │ 10.0.x.x                                                        │
│         ▼                                                                  │
│     ┌────────┐                                                            │
│     │  Trie   │  ← 共享前缀 "10.0."                                      │
│     │  节点   │                                                            │
│     └───┬────┘                                                            │
│         │                                                                  │
│    ┌────┴────┐                                                            │
│    │         │                                                            │
│    ▼         ▼                                                            │
│  ┌────┐   ┌────┐                                                         │
│  │R1: │   │R2: │                                                         │
│  │0.x │   │1.x │                                                         │
│  └──┬─┘   └──┬─┘                                                         │
│     │       │                                                             │
│     ▼       ▼                                                             │
│  ACCEPT      DROP                                                           │
│                                                                             │
│  2. NFA → DFA (确定性有限自动机，subset construction)                      │
│     消除非确定性，保证每个输入只有唯一匹配路径                              │
│                                                                             │
│  3. DFA → Trie 优化                                                       │
│     DPDK ACL 的独特之处：不是纯字节级 Trie，而是按字段粒度构建            │
│     一次比较一个完整字段（如整个 src_ip），减少跳转次数                   │
│                                                                             │
│  查找时：从 Trie 根节点开始，逐字段比较，O(W) 其中 W 是字段总宽度        │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 5. rte_flow 通用匹配-动作框架

### 5.1 rte_flow 概述

rte_flow 是 DPDK 引入的通用流规则 API，抽象了硬件能力。注意 `struct rte_flow` 是**不透明句柄**，应用程序不直接访问其内部成员，而是通过 API 操作：

```c
// lib/ethdev/rte_flow.h

// 创建流规则（返回不透明句柄）
struct rte_flow *
rte_flow_create(uint16_t port_id,
    const struct rte_flow_attr *attr,       // 规则属性
    const struct rte_flow_item pattern[],   // 匹配模式（以 END 结尾）
    const struct rte_flow_action actions[], // 执行动作（以 END 结尾）
    struct rte_flow_error *error);

// 销毁流规则
int
rte_flow_destroy(uint16_t port_id, struct rte_flow *flow,
    struct rte_flow_error *error);

// 属性
struct rte_flow_attr {
    uint32_t group;          // 流表组（0 是最高优先级）
    uint32_t priority;       // 组内优先级（0 最高）
    uint32_t ingress;         // 入口流量
    uint32_t egress;          // 出口流量
    uint32_t transfer;       // 转移（switch domain）
};
```

#### rte_flow 抽象了哪些硬件能力

rte_flow 的设计目标是将不同厂商网卡各自独立的流分类 API 统一到一个接口下。在 rte_flow 出现之前，Intel 有 Flow Director、Mellanox 有 Flow Steering、Broadcom 有 CCE（Content Classification Engine）——每个厂商的 API 完全不同。rte_flow 通过 Pattern + Action 的 match-action 模型把它们统一起来了：

```
┌───────────────────────────────────────────────────────────────────────────┐
│                    rte_flow 统一抽象层                                     │
├───────────────────────────────────────────────────────────────────────────┤
│                                                                           │
│  应用程序                                                                 │
│  ┌─────────────────────────────────────────────────────────────────────┐ │
│  │  rte_flow_create(port, attr, pattern, actions, &error)              │ │
│  │  rte_flow_destroy(port, flow, &error)                               │ │
│  └───────────────────────────┬─────────────────────────────────────────┘ │
│                              │                                            │
│                              ▼                                            │
│  ┌───────────────────────────────────────────────────────────────────┐   │
│  │                      PMD 翻译层                                    │   │
│  └────┬──────────┬──────────┬──────────┬──────────┬─────────────────┘   │
│       │          │          │          │          │                       │
│       ▼          ▼          ▼          ▼          ▼                       │
│  ┌─────────┐┌─────────┐┌──────────┐┌──────────┐┌──────────┐             │
│  │ Intel   ││Mellanox ││ Broadcom ││ Marvell  ││ Huawei   │             │
│  │ i40e/ice││ MLX5    ││ bnxt    ││ octeontx ││ hinic    │             │
│  └────┬────┘└────┬────┘└────┬─────┘└────┬─────┘└────┬─────┘             │
│       │          │          │           │            │                    │
│       ▼          ▼          ▼           ▼            ▼                    │
│  ┌─────────┐┌─────────┐┌──────────┐┌──────────┐┌──────────┐             │
│  │ FD/FDIR ││Flow     ││ CCE      ││ PKTFLW   ││ Normal   │             │
│  │+FDID    ││Steering ││ TCAM     ││ Cam/FLW  ││ Match    │             │
│  │+SIDEBAND││(NIC +   ││          ││          ││          │             │
│  │+COMMS   ││ Switch) ││          ││          ││          │             │
│  └─────────┘└─────────┘└──────────┘└──────────┘└──────────┘             │
│                                                                           │
└───────────────────────────────────────────────────────────────────────────┘
```

各厂商的硬件功能与 rte_flow 的对应关系：

```
┌───────────────┬─────────────────────────────┬──────────────────────────┐
│ 厂商 / 系列    │ 底层硬件功能                 │ rte_flow 翻译到           │
├───────────────┼─────────────────────────────┼──────────────────────────┤
│ Intel         │ FDIR (Flow Director)        │ QUEUE / DROP / MARK      │
│ ixgbe         │   五元组精确匹配             │ → FDIR 精确表             │
│               │                             │                          │
│ Intel         │ FDID (Flow Director ID)     │ MARK                     │
│ i40e/ice      │   标记 + 元数据传递           │ → FDIR ID 字段            │
│               │                             │                          │
│ Intel         │ RSS (Receive Side Scaling)   │ RSS 动作                  │
│ i40e/ice      │   Toeplitz / XOR hash       │ → 硬件 hash 配置           │
│               │                             │                          │
│ Intel         │ SIDEBAND (Switch Filter)     │ transfer + PORT / VF     │
│ ice           │   E-Switch 级别的流规则       │ → E-Switch TCAM          │
│               │   (SR-IOV 场景下 VF 间转发)   │                          │
│               │                             │                          │
│ Intel         │ COMMS (Comms Package)        │ PFC / DSCP 动作           │
│ ice           │   QoS 相关流规则              │ → QoS 硬件配置            │
├───────────────┼─────────────────────────────┼──────────────────────────┤
│ Mellanox      │ Flow Steering (NIC)         │ QUEUE / DROP / RSS       │
│ ConnectX-4/5  │   NIC 级别的 match-action    │ → NIC Steering Table      │
│               │   基于 hash 或 exact match   │                          │
│               │                             │                          │
│ Mellanox      │ Flow Steering (FDB)         │ transfer + PORT / VF     │
│ ConnectX-4/5  │   E-Switch FDB 表            │ → FDB (Forwarding DB)     │
│               │   (SR-IOV VF 间转发/镜像)    │   TCAM                   │
│               │                             │                          │
│ Mellanox      │ TIR (Transport Interface)   │ RSS                      │
│ ConnectX-6/7  │   高级 RSS + 间接表          │ → TIR hash 配置           │
│               │                             │                          │
│ NVIDIA        │ Match-Action Engine         │ 多种组合                  │
│ BlueField DPU │   DPU 内部可编程流水线       │ → 硬件流水线              │
├───────────────┼─────────────────────────────┼──────────────────────────┤
│ Broadcom      │ CCE (Content Classification│ QUEUE / DROP / MARK      │
│ NetXtreme     │   Engine)                   │ → CCE 规则                │
│               │   TCAM + Exact Match        │                          │
│               │                             │                          │
│ Broadcom      │ TRUFLOW                     │ RSS + 复杂规则             │
│ (SmartNIC)    │   高级流分类引擎              │ → TRUFLOW 硬件表          │
├───────────────┼─────────────────────────────┼──────────────────────────┤
│ Marvell       │ PKTFLOW / CAM               │ QUEUE / DROP             │
│ OcteonTX      │   硬件 CAM 匹配              │ → 硬件 CAM 表             │
├───────────────┼─────────────────────────────┼──────────────────────────┤
│ Huawei        │ Normal Match                │ QUEUE / DROP             │
│ Hi1822        │   硬件流分类                  │ → 硬件规则表              │
└───────────────┴─────────────────────────────┴──────────────────────────┘
```

> [!tip] 理解翻译层
> rte_flow 不是"在软件里实现流分类"，而是一个**翻译层**。`rte_flow_create()` 被调用后，
> 对应的 PMD 将 pattern + action 翻译成该厂商硬件能理解的寄存器配置或表项写入命令。
> 如果硬件不支持某个 pattern/action 组合，调用会返回错误，应用需要 fallback 到软件处理。
>
> 查询硬件能力的方式：
>
> ```c
> struct rte_flow_action actions[] = {
>     { .type = RTE_FLOW_ACTION_TYPE_COUNT },  // 想用 COUNT
>     { .type = RTE_FLOW_ACTION_TYPE_END },
> };
>
> // 检查硬件是否支持这个动作
> int ret = rte_flow_validate(port_id, &attr, pattern, actions, &error);
> if (ret != 0) {
>     printf("不支持: %s\n", error.message);  // 获取具体原因
>     // fallback 到软件计数
> }
> ```

### 5.2 模式项 (Pattern Items)

```c
// 匹配模式定义

// Ethernet
RTE_FLOW_ITEM_TYPE_ETH   // 匹配 Ethernet 头部
//  example: dst_mac = xx:xx:xx:xx:xx:xx

// VLAN
RTE_FLOW_ITEM_TYPE_VLAN  // 匹配 VLAN tag

// IPv4/IPv6
RTE_FLOW_ITEM_TYPE_IPV4  // 匹配 IPv4
RTE_FLOW_ITEM_TYPE_IPV6  // 匹配 IPv6
//  example: src_addr = 10.0.0.1

// TCP/UDP/SCTP
RTE_FLOW_ITEM_TYPE_TCP   // 匹配 TCP
RTE_FLOW_ITEM_TYPE_UDP   // 匹配 UDP
RTE_FLOW_ITEM_TYPE_SCTP  // 匹配 SCTP
//  example: src_port = 80

// 隧道
RTE_FLOW_ITEM_TYPE_VXLAN       // 匹配 VXLAN
RTE_FLOW_ITEM_TYPE_GRE         // 匹配 GRE
RTE_FLOW_ITEM_TYPE_NVGRE       // 匹配 NVGRE

// 原始数据
RTE_FLOW_ITEM_TYPE_raw   // 匹配原始字节

// 通配符
RTE_FLOW_ITEM_TYPE_END   // 模式结束

// 模式示例：匹配 UDP 流量
static const struct rte_flow_item pattern[] = {
    { .type = RTE_FLOW_ITEM_TYPE_ETH },
    { .type = RTE_FLOW_ITEM_TYPE_IPV4 },
    { .type = RTE_FLOW_ITEM_TYPE_UDP },
    { .type = RTE_FLOW_ITEM_TYPE_END },
};
```

### 5.3 动作 (Actions)

```c
// 支持的动作

RTE_FLOW_ACTION_TYPE_END           // 结束
RTE_FLOW_ACTION_TYPE_PASSTHRU      // 穿透
RTE_FLOW_ACTION_TYPE_DROP          // 丢弃
RTE_FLOW_ACTION_TYPE_QUEUE         // 排队到特定队列
RTE_FLOW_ACTION_TYPE_RSS           // RSS
RTE_FLOW_ACTION_TYPE_PHY_PORT     // 物理端口
RTE_FLOW_ACTION_TYPE_VOID          // 空动作
RTE_FLOW_ACTION_TYPE_MARK          // 标记（添加 ID）
RTE_FLOW_ACTION_TYPE_COUNT         // 计数
RTE_FLOW_ACTION_TYPE_SET_MAC_SRC   // 修改源 MAC
RTE_FLOW_ACTION_TYPE_SET_MAC_DST   // 修改目标 MAC
RTE_FLOW_ACTION_TYPE_SET_IPV4_SRC  // 修改源 IP
RTE_FLOW_ACTION_TYPE_SET_IPV4_DST  // 修改目标 IP
RTE_FLOW_ACTION_TYPE_SET_TP_SRC    // 修改源端口
RTE_FLOW_ACTION_TYPE_SET_TP_DST    // 修改目标端口
RTE_FLOW_ACTION_TYPE_OF_POP_VLAN   // 弹出 VLAN
RTE_FLOW_ACTION_TYPE_OF_PUSH_VLAN  // 插入 VLAN
RTE_FLOW_ACTION_TYPE_JUMP          // 跳转到其他流表组
RTE_FLOW_ACTION_TYPE_METER         // 流量计量
RTE_FLOW_ACTION_TYPE_SECURITY      // 安全处理

// 动作示例：丢弃所有 TCP 流量
static const struct rte_flow_action actions[] = {
    { .type = RTE_FLOW_ACTION_TYPE_DROP },
    { .type = RTE_FLOW_ACTION_TYPE_END },
};

// 动作示例：标记并排队
static const struct rte_flow_action actions[] = {
    {
        .type = RTE_FLOW_ACTION_TYPE_MARK,
        .conf = &(struct rte_flow_action_mark) { .id = 42 },
    },
    {
        .type = RTE_FLOW_ACTION_TYPE_QUEUE,
        .conf = &(struct rte_flow_action_queue) { .index = 3 },
    },
    { .type = RTE_FLOW_ACTION_TYPE_END },
};
```

### 5.4 完整示例

```c
// 示例 1：匹配特定 UDP 流量并指定队列

// spec/mask 必须用 static 变量，不能用 compound literal（悬垂指针风险）
static const struct rte_flow_item_ipv4 ipv4_spec = {
    .hdr.dst_addr = RTE_IPV4(10, 0, 0, 1),
};
static const struct rte_flow_item_udp udp_spec = {
    .hdr.dst_port = rte_cpu_to_be_16(80),
};

static int
setup_flow_redirect(uint16_t port_id, uint16_t queue_id)
{
    struct rte_flow_error error;
    struct rte_flow_attr attr = {
        .ingress = 1,     // 入方向
        .priority = 0,   // 高优先级
    };

    // 匹配模式：ETH → IPv4(dst=10.0.0.1) → UDP(dst_port=80)
    struct rte_flow_item pattern[] = {
        {
            .type = RTE_FLOW_ITEM_TYPE_ETH,
            .spec = &rte_flow_item_eth_mask,  // match any ETH
        },
        {
            .type = RTE_FLOW_ITEM_TYPE_IPV4,
            .spec = &ipv4_spec,
            .mask = &rte_flow_item_ipv4_mask,
        },
        {
            .type = RTE_FLOW_ITEM_TYPE_UDP,
            .spec = &udp_spec,
            .mask = &rte_flow_item_udp_mask,
        },
        { .type = RTE_FLOW_ITEM_TYPE_END },
    };

    // 动作：排队到指定队列
    static struct rte_flow_action_queue queue_conf = { .index = 0 };
    queue_conf.index = queue_id;

    struct rte_flow_action actions[] = {
        { .type = RTE_FLOW_ACTION_TYPE_QUEUE, .conf = &queue_conf },
        { .type = RTE_FLOW_ACTION_TYPE_END },
    };

    struct rte_flow *flow = rte_flow_create(port_id, &attr,
                                              pattern, actions, &error);
    if (!flow) {
        printf("Flow creation failed: %s\n", error.message);
        return -1;
    }

    return 0;
}

// 示例 2：使用 RSS 分散负载

static int
setup_flow_rss(uint16_t port_id)
{
    struct rte_flow_error error;
    struct rte_flow_attr attr = {
        .ingress = 1,
    };

    struct rte_flow_item pattern[] = {
        { .type = RTE_FLOW_ITEM_TYPE_ETH },
        { .type = RTE_FLOW_ITEM_TYPE_IPV4 },
        { .type = RTE_FLOW_ITEM_TYPE_END },
    };

    // RSS 配置：按 L3+L4 哈希分散到 4 个队列
    uint16_t queues[] = { 0, 1, 2, 3 };
    struct rte_flow_action_rss rss_conf = {
        .func = RTE_ETH_HASH_FUNCTION_DEFAULT,
        .level = 0,
        .types = RTE_ETH_RSS_NONFRAG_IPV4_UDP | RTE_ETH_RSS_NONFRAG_IPV4_TCP,
        .key_len = 40,
        .queue_num = 4,
        .queue = queues,
    };

    struct rte_flow_action actions[] = {
        { .type = RTE_FLOW_ACTION_TYPE_RSS, .conf = &rss_conf },
        { .type = RTE_FLOW_ACTION_TYPE_END },
    };

    return rte_flow_create(port_id, &attr, pattern, actions, &error) != NULL;
}

// 示例 3：VLAN 流量镜像到指定物理端口

static const struct rte_flow_item_vlan vlan_spec = {
    .tci = rte_cpu_to_be_16(100),  // VLAN ID 100
};

static int
setup_flow_mirror(uint16_t port_id, uint16_t mirror_port)
{
    struct rte_flow_error error;
    struct rte_flow_attr attr = {
        .ingress = 1,
        .group = 1,  // 使用 group 1
    };

    // 匹配：ETH → VLAN(100) → any
    struct rte_flow_item pattern[] = {
        { .type = RTE_FLOW_ITEM_TYPE_ETH },
        {
            .type = RTE_FLOW_ITEM_TYPE_VLAN,
            .spec = &vlan_spec,
            .mask = &rte_flow_item_vlan_mask,
        },
        { .type = RTE_FLOW_ITEM_TYPE_END },
    };

    // 动作：转发到指定物理端口
    static struct rte_flow_action_phy_port port_conf = { .id = 0 };
    port_conf.id = mirror_port;

    struct rte_flow_action actions[] = {
        { .type = RTE_FLOW_ACTION_TYPE_PHY_PORT, .conf = &port_conf },
        { .type = RTE_FLOW_ACTION_TYPE_END },
    };

    return rte_flow_create(port_id, &attr, pattern, actions, &error) != NULL;
}
```

### 5.5 流表组 (Flow Group)

```c
// 流表组用于分层管理流规则

// Group 0: 默认规则
//   - 所有流量 RSS 到多个队列
//   - 普通处理

// Group 1: 高优先级规则
//   - 特定流量 DROP
//   - 特定流量 QUEUE 到专用队列
//   - 特定流量 镜像到分析端口

// Group 2: 安全规则
//   - DDoS 防护
//   - 异常流量检测

// 规则匹配顺序：
// 1. 按 group 优先级匹配（group 0 最高优先级，逐级递减）
// 2. 同 group 内按 priority 匹配（数值越小优先级越高）
// 3. 匹配到则执行动作，不再继续匹配

// 示例：多组配置
static void
setup_flow_groups(uint16_t port_id)
{
    // Group 0: 默认 RSS
    create_rss_flow(port_id, 0, 0, queues, nb_queues);

    // Group 1: 特殊流量
    create_drop_flow(port_id, 1, 1, bad_ip);
    create_mirror_flow(port_id, 1, 1, monitor_port);

    // Group 2: 紧急拦截
    create_rate_limit_flow(port_id, 2, 2, ddos_ip);
}
```

---

## 6. 性能对比

### 6.1 各技术性能对比

| 技术              | 吞吐量       | 延迟       | 灵活性 | 适用范围           |
| ----------------- | ------------ | ---------- | ------ | ------------------ |
| **RSS**           | 线速         | ~0         | 低     | 负载均衡           |
| **Flow Director** | 线速         | ~0         | 中     | Intel NIC 精确匹配 |
| **librte_acl**    | ~50-100 Mpps | ~50ns      | 高     | 软件分类/复杂规则  |
| **rte_flow**      | 取决于底层   | 取决于底层 | 高     | 通用 API           |

### 6.2 选型指南

```c
// 选型决策树

if (需要负载均衡) {
    // RSS
    选择 RSS，按 5-tuple 分散到多个队列
}
else if (硬件支持 && 规则简单) {
    // Flow Director
    添加 FDIR 规则到 NIC
}
else if (规则复杂 || 需要跨 NIC) {
    // rte_flow (抽象层)
    使用 rte_flow_create()
}
else if (需要软件分类) {
    // librte_acl
    构建 ACL 分类器
}
else {
    // 组合使用
    RSS 做负载均衡 + rte_flow 做精确控制
}
```

---

## 7. 实际应用场景

### 7.1 负载均衡器

```c
// 场景：DPDK 做负载均衡，将请求分散到多个后端

// 1. RSS 做基础负载均衡
struct rte_flow_action_rss rss_conf = {
    .types = RTE_ETH_RSS_NONFRAG_IPV4_TCP | RTE_ETH_RSS_NONFRAG_IPV4_UDP,
    .queue_num = nb_queues,
    .queue = queues,
};

// 2. 额外规则处理特定流量
//    - 管理流量 → 管理队列 (queue 0)
//    - 视频流量 → 视频队列 (queue 1-3)
//    - 普通流量 → 普通队列 (queue 4-7)

static const struct rte_flow_item_ipv4 mgmt_ipv4_spec = {
    .hdr.dst_addr = RTE_IPV4(10, 0, 0, 254),
};
static const struct rte_flow_item_tcp mgmt_tcp_spec = {
    .hdr.dst_port = rte_cpu_to_be_16(22),
};

static int
setup_lb_flows(uint16_t port_id)
{
    struct rte_flow_error error;

    // 管理流量 - 高优先级
    struct rte_flow_item pattern_mgmt[] = {
        { .type = RTE_FLOW_ITEM_TYPE_IPV4,
          .spec = &mgmt_ipv4_spec,
          .mask = &rte_flow_item_ipv4_mask },
        { .type = RTE_FLOW_ITEM_TYPE_TCP,
          .spec = &mgmt_tcp_spec,
          .mask = &rte_flow_item_tcp_mask },
        { .type = RTE_FLOW_ITEM_TYPE_END },
    };

    static struct rte_flow_action_queue queue0 = { .index = 0 };
    struct rte_flow_action actions_mgmt[] = {
        { .type = RTE_FLOW_ACTION_TYPE_QUEUE, .conf = &queue0 },
        { .type = RTE_FLOW_ACTION_TYPE_END },
    };

    struct rte_flow_attr attr_mgmt = { .ingress = 1, .priority = 1 };
    rte_flow_create(port_id, &attr_mgmt, pattern_mgmt, actions_mgmt, &error);

    // ... 类似处理其他流量类型
}
```

### 7.2 DDoS 防护

```c
// 场景：检测并阻断异常流量

static int
setup_ddos_protection(uint16_t port_id)
{
    struct rte_flow_error error;

    // 1. 统计每个 IP 的流量
    struct rte_flow_action_count count_conf = {
        .id = 0,  // 统计 ID
    };

    struct rte_flow_item pattern_count[] = {
        { .type = RTE_FLOW_ITEM_TYPE_IPV4 },
        { .type = RTE_FLOW_ITEM_TYPE_END },
    };

    struct rte_flow_action actions_count[] = {
        { .type = RTE_FLOW_ACTION_TYPE_COUNT, .conf = &count_conf },
        { .type = RTE_FLOW_ACTION_TYPE_PASSTHRU },  // 继续处理
        { .type = RTE_FLOW_ACTION_TYPE_END },
    };

    struct rte_flow_attr attr_count = { .ingress = 1, .group = 2 };
    rte_flow_create(port_id, &attr_count,
                    pattern_count, actions_count, &error);

    // 2. 读取统计，超过阈值的 DROP
    //    (在定时器中检查 rate，超过 10000 pps 则添加 DROP 规则)

    // 3. DROP 规则
    static struct rte_flow_item_ipv4 drop_ipv4_spec;
    drop_ipv4_spec.hdr.src_addr = attacker_ip;

    struct rte_flow_item pattern_drop[] = {
        { .type = RTE_FLOW_ITEM_TYPE_IPV4,
          .spec = &drop_ipv4_spec,
          .mask = &rte_flow_item_ipv4_mask },
        { .type = RTE_FLOW_ITEM_TYPE_END },
    };

    struct rte_flow_action actions_drop[] = {
        { .type = RTE_FLOW_ACTION_TYPE_DROP },
        { .type = RTE_FLOW_ACTION_TYPE_END },
    };

    struct rte_flow_attr attr_drop = { .ingress = 1, .priority = 0 };
    rte_flow_create(port_id, &attr_drop,
                    pattern_drop, actions_drop, &error);
}
```

---

## 8. 小结

本章核心要点：

1. **RSS 哈希分散**：基于 5-tuple 的 Toeplitz 哈希，将流量均匀分散到多队列，保证同一 flow 在同一队列处理。

2. **Flow Director**：Intel 硬件支持的精确匹配，支持 DROP、QUEUE 等动作，适合 DDoS 防护、流量过滤。

3. **librte_acl**：软件层面的 ACL 库，使用 NFA → DFA → Trie 多阶段编译，支持复杂规则匹配（如 CIDR 范围）。

4. **rte_flow**：DPDK 统一的匹配-动作框架，抽象了底层硬件差异，支持 Pattern + Action 组合。

5. **Pattern Items**：ETH、VLAN、IPv4/IPv6、TCP/UDP/SCTP、隧道协议等。

6. **Actions**：DROP、QUEUE、RSS、MARK、COUNT、修改 Header 等。

7. **Flow Group**：分层管理流规则，支持多级优先级。

8. **选型**：负载均衡选 RSS，简单精确匹配选 FDIR，复杂规则选 rte_flow 或 librte_acl。

**下一篇预告**：[[ch11-ether-ip-udp|第十一章]]将深入讲解 Ether/IP/UDP 协议处理与 checksum offload。

---

> [!tip] 参考文献
>
> - Intel, "DPDK Flow API", https://doc.dpdk.org/guides/prog_guide/rte_flow.html
> - Intel, "RSS and Flow Director", https://doc.dpdk.org/guides/prog_guide/rte_ethdev.html
> - "librte_acl", https://doc.dpdk.org/guides/prog_guide/acl_lib.html
> - "Hyperscan", https://www.intel.com/content/www/us/en/developer/articles/technical/introduction-hyperscan.html
