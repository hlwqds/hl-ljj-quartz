---
title: "DPDK 深度探索 ch36b：IPsec 数据面——从 SA 状态机到硬件卸载"
date: 2026-04-10 13:30:00
tags:
  [
    dpdk,
    ipsec,
    esp,
    sa,
    spd,
    sad,
    aead,
    aes-gcm,
    esn,
    anti-replay,
    rte-ipsec,
    rte-security,
    cryptodev,
    inline-offload,
    lookaside,
  ]
description: "从工程数据路径解析 DPDK IPsec：SPD/SAD、ESP、AES-GCM、序列号与抗重放、rte_ipsec、cryptodev、rte_security、inline/lookaside 卸载、SA rekey、MTU 与 ipsec-secgw 验证方法"
---

# DPDK 深度探索 ch36b：IPsec 数据面——从 SA 状态机到硬件卸载

> [!info] 章节定位
> 系列中已有 [[2026-04-09-dpdk-deep-dive-ch36-p4-dpdk|第三十六章：P4 可编程数据面]]，
> 因此本文按 **ch36b 专题章**处理。
>
> 资料与 API 核对日期：**2026-06-09**，基于 DPDK 26.03。

> [!abstract] 核心结论
> DPDK IPsec 的难点不在 AES 指令本身，而在于同时维护四类正确性：
>
> 1. **策略正确性**：明文流量应该 protect、bypass 还是 discard；
> 2. **密码学正确性**：nonce、AAD、ICV、序列号和密钥生命周期不能出错；
> 3. **并发正确性**：同一 SA 的序列号与抗重放窗口不能被多个执行上下文无序更新；
> 4. **卸载正确性**：应用必须知道协议处理究竟由软件、crypto 设备还是 NIC 完成。
>
> `ipsec-secgw` 是理解这些边界的参考实现和验证工具，不是带 IKE、动态控制面、
> 高可用和完整运维能力的现成 VPN 产品。

> [!info] 关联章节
>
> - [[2026-04-09-dpdk-deep-dive-ch21-cryptodev|cryptodev 与 Crypto PMD]]
> - [[2026-04-09-dpdk-deep-dive-ch22-ipsec-fullflow|IPsec 完整处理流程与 SAD/SPD]]
> - [[2026-04-09-dpdk-deep-dive-ch24-raw-crypto-api|Raw Crypto API]]
> - [[2026-04-09-dpdk-deep-dive-ch30-lookaside-crypto|Lookaside 加速]]
> - [[2026-04-09-dpdk-deep-dive-ch30-performance-tuning|性能调优]]
> - [[2026-04-09-dpdk-deep-dive-ch40-wireguard-dpdk|WireGuard 与 DPDK]]

---

## 1. 先把 DPDK IPsec 的边界说清楚

Linux 内核 IPsec 通常由 XFRM 完成。应用使用普通 socket，内核根据 policy/state
选择 SA 并完成 ESP 处理。这里不存在“每个包都额外执行一次 IPsec syscall”；
系统调用发生在应用收发边界，XFRM 是内核协议栈中的处理阶段。

```text
Application
    │ socket
    ▼
TCP/IP ── XFRM policy/state ── ESP ── NIC
```

DPDK 方案把数据面所有权交给用户态应用：

```text
NIC RX
  │
  ├─ classify / SPD
  ├─ SAD lookup
  ├─ ESP pre-process
  ├─ crypto or security offload
  ├─ ESP post-process
  ├─ route / policy validation
  ▼
NIC TX
```

这样做的价值是：

- 数据包不必经过通用内核网络栈；
- 转发、ACL、QoS 与 IPsec 可以共用一个批处理 pipeline；
- 应用可选择 CPU、lookaside accelerator 或 inline NIC；
- 队列、NUMA、批量大小和状态所有权都可显式控制。

代价也很直接：

- 应用必须管理 SPD、SAD、路由和 SA 生命周期；
- IKE、认证、证书、rekey 编排不由 DPDK 提供；
- 设备能力、fallback 和错误状态必须由应用处理；
- 错误的序列号、nonce 或回退策略可能直接破坏安全性。

> [!warning] 不要把“用户态”当成性能结论
> DPDK 省去了通用内核路径，但最终性能仍取决于包长、SA 数量、算法、NUMA、
> burst、设备队列、IOMMU、PCIe 和是否发生复制。没有测试条件的固定 Gbit/s
> 或微秒数字没有可比性。

---

## 2. 一条完整数据路径包含什么

### 2.1 出站：先匹配明文策略，再选择 SA

```text
明文包
  │
  ├─ SPD lookup
  │    ├─ bypass  ───────────────► route / TX
  │    ├─ discard ───────────────► drop
  │    └─ protect(SA selector)
  │
  ├─ 取得出站 SA
  ├─ 分配序列号
  ├─ 构造 ESP header / trailer / padding
  ├─ 生成 IV/nonce
  ├─ 加密并生成 ICV
  ├─ tunnel 模式添加 outer IP header
  ▼
路由并发送密文包
```

### 2.2 入站：先按 SPI 找 SA，再验证解密后的策略

```text
ESP 包
  │
  ├─ outer IP + SPI 查 SAD
  ├─ 重建 ESN 高位
  ├─ 抗重放预检查
  ├─ 验证 ICV 并解密
  ├─ 抗重放状态提交
  ├─ 去除 ESP / outer tunnel header
  ├─ 对明文执行 inbound SPD 检查
  ▼
路由并发送明文包
```

入站 SPD 检查不能省略。只验证“这个 SPI 的包能解密”还不够，还要确认解密后的
源/目的地址、协议和端口确实属于该 SA 允许保护的流量，避免策略绕过。

### 2.3 DPDK 各库分别负责什么

| 组件                | 主要职责                               | 不负责                    |
| ------------------- | -------------------------------------- | ------------------------- |
| `rte_acl` / 应用表  | SPD 分类                               | 密钥与 ESP                |
| `rte_ipsec_sad`     | 由 SPI、目的地址、源地址查找 SA        | 完整 SA 生命周期          |
| `rte_ipsec`         | ESP 数据准备、完成、序列号与抗重放协同 | IKE、全局策略编排         |
| `rte_cryptodev`     | 对称密码操作的异步队列                 | 自动理解完整 IPsec policy |
| `rte_security`      | 描述协议会话及其执行方式               | 保证任意设备支持任意组合  |
| ethdev / `rte_flow` | 收发、steering、部分 inline 路径       | 通用 IKE 控制面           |

`rte_security` 早在 DPDK 17.11 已加入，不是 20.05 才引入。

---

## 3. ESP、AH 与现代算法

### 3.1 生产数据面通常以 ESP 为中心

AH 为 IP 包提供完整性和源认证，但不加密，并且与 NAT 不易共存。
现代 VPN、云网络和移动核心网主要使用 ESP。DPDK IPsec 库支持 ESP 与 AH，
但 `ipsec-secgw` 官方示例只实现 ESP 路径。

### 3.2 AES-GCM 的 IPsec nonce 不是“随便填 12 字节”

AES-GCM 常见的 96-bit nonce，在 ESP 中通常由两部分组成：

```text
32-bit salt       64-bit explicit IV
  SA 固定值        每包变化并随 ESP 发送
       └──────────────┬──────────────┘
                  96-bit nonce
```

ESP 的 SPI 和序列号作为 AAD 的一部分参与认证。启用 ESN 时，AAD 还需要包含
序列号高 32 位。具体布局应遵循对应 RFC 和 PMD 的 capability/文档，不能仅凭
`iv.length = 12` 推断 mbuf 中要放置的字节。

> [!danger] Nonce 重用
> 同一 AES-GCM 密钥下重复 nonce 会严重破坏机密性与完整性。
> SA 恢复、进程重启、主备切换和序列号持久化都必须避免 nonce 回退。

### 3.3 算法选择不能只看 cryptodev 枚举

`rte_cryptodev` 支持某算法，不等于目标 IPsec action、设备和模式支持该算法。
应用需要同时验证：

```text
算法与 key / IV / digest 长度
        +
ESP tunnel / transport
        +
ingress / egress
        +
inline / lookaside / CPU crypto
        +
ESN / anti-replay / UDP encapsulation 等 option
```

工程上常见的优先级是：

| 场景                  | 通常优先评估            | 说明                  |
| --------------------- | ----------------------- | --------------------- |
| 通用 x86 / 服务器 NIC | AES-GCM                 | CPU 和硬件支持广泛    |
| 无高效 AES 指令的平台 | ChaCha20-Poly1305       | 需确认双方与 PMD 支持 |
| 兼容旧系统            | AES-CBC + HMAC          | 只在互操作要求下使用  |
| 仅完整性              | NULL cipher + 合适 auth | 必须明确威胁模型      |

RFC 8221 已将 3DES 标为不得实现，并降低了多种旧算法的推荐级别。
新部署应优先选择当前双方都支持的 AEAD 套件，而不是沿用示例文件中的
AES-CBC + HMAC-SHA1。

---

## 4. 序列号、抗重放与 ESN

### 4.1 抗重放窗口是状态机，不只是一个 bitmap

入站 SA 维护：

```text
T = 当前已验证的最高序列号
W = 抗重放窗口大小

sequence > T:
  候选新包，验证成功后推进窗口

T-W < sequence <= T:
  未见过则可接受，已见过则是 replay

sequence <= T-W:
  太旧，丢弃
```

密码验证完成前不能永久提交窗口更新，否则攻击者可发送伪造高序列号包推动窗口，
让合法包被判定为过旧。实现通常分为“预检查”和“认证成功后提交”两个阶段。

RFC 4303 要求发送端不得让普通 32-bit 序列号回绕。接收端通常应启用抗重放，
但如果接收端禁用该服务，发送端仍必须管理序列号生命周期。

### 4.2 32-bit 序列号多久耗尽

耗尽时间由包速率决定，而不是由链路 Gbit/s 单独决定：

```text
seconds_to_wrap = 2^32 / packets_per_second
```

以最小以太网帧的理论线速近似：

| 链路     | 包速率     | 32-bit 序列号耗尽时间 |
| -------- | ---------- | --------------------- |
| 10 Gb/s  | 14.88 Mpps | 约 289 秒             |
| 25 Gb/s  | 37.2 Mpps  | 约 115 秒             |
| 100 Gb/s | 148.8 Mpps | 约 29 秒              |

ESP 开销会改变实际 pps，但这个数量级足以说明：高速小包 SA 若不开 ESN，
必须非常频繁地 rekey。

### 4.3 ESN 如何工作

ESN 将逻辑序列号扩展为 64 位，但线上 ESP header 仍只携带低 32 位：

```text
logical sequence:
  high 32 bits | low 32 bits on wire
```

接收端根据当前窗口位置推断高位，并将高位纳入完整性校验。它不是简单地看到
`0xffffffff` 后无条件 `high++`；乱序包可能跨越低位回绕边界，必须按 RFC 4303
附录算法重建候选值。

### 4.4 并发所有权决定正确性

DPDK IPsec 文档明确指出，为保证正确处理，同一 SA 的包应由唯一 lcore 处理。
原因包括：

- 出站序列号必须严格唯一；
- 入站抗重放窗口是可变共享状态；
- 异步 crypto 返回可能改变包顺序；
- primary/fallback 路径之间可能发生乱序。

可靠做法不是“每个 lcore 复制一份 SAD 并定期同步”。SAD 可以复制或分片，
但 **同一个 SA 的序列号与 replay 状态不能无约束地复制**。

常见队列设计：

```text
RX RSS / rte_flow
  │ 按 SPI 或 tunnel tuple 稳定分流
  ▼
SA owner lcore
  │
  ├─ software / CPU crypto
  └─ dedicated crypto queue pair
```

---

## 5. 五种 security action，不能只分 inline/lookaside

DPDK 26.03 的 `rte_security_session_action_type` 定义了五类 action：

| Action               | 协议处理           | 密码处理             | 典型路径                    |
| -------------------- | ------------------ | -------------------- | --------------------------- |
| `NONE`               | 软件               | 普通 cryptodev       | 应用 + 异步 crypto PMD      |
| `CPU_CRYPTO`         | 软件               | CPU 同步 crypto      | 减少 crypto op/queue 开销   |
| `INLINE_CRYPTO`      | 软件负责大部分协议 | ethdev inline crypto | NIC 只做密码变换            |
| `INLINE_PROTOCOL`    | ethdev/NIC         | ethdev/NIC           | NIC 完成 ESP 协议与密码处理 |
| `LOOKASIDE_PROTOCOL` | security device    | security device      | 协处理器完成 ESP 与密码处理 |

这比“inline 等于 `rte_security`，lookaside 等于 `rte_cryptodev`”更准确：

- lookaside protocol 同样通过 `rte_security` session 描述；
- inline crypto 和 inline protocol 的应用职责不同；
- `NONE` 路径才是典型的 `rte_ipsec + rte_cryptodev` 组合；
- CPU crypto 是同步路径，适合评估小 burst 和低队列开销场景。

### 5.1 三条典型数据路径

```text
Software protocol + cryptodev
  rte_ipsec prepare
    → crypto enqueue/dequeue
    → rte_ipsec process
    → ethdev TX

Lookaside protocol
  security op enqueue/dequeue
    → accelerator 完成 ESP
    → ethdev TX

Inline protocol
  mbuf metadata / offload flags
    → ethdev TX
    → NIC 完成 ESP 并发送
```

“inline CPU 参与度为零”也不准确。CPU 仍要分类、查策略、选择 SA、构造 metadata、
管理流规则、处理异常路径和提交 TX descriptor；被卸载的是特定协议/密码工作。

---

## 6. Capability-driven：不要按网卡品牌猜能力

创建 session 前应先构造 capability index：

```c
struct rte_security_capability_idx idx = {
    .action = requested_action,
    .protocol = RTE_SECURITY_PROTOCOL_IPSEC,
    .ipsec = {
        .proto = RTE_SECURITY_IPSEC_SA_PROTO_ESP,
        .mode = requested_mode,
        .direction = requested_direction,
    },
};

const struct rte_security_capability *cap =
    rte_security_capability_get(sec_ctx, &idx);

if (cap == NULL)
    return -ENOTSUP;
```

然后继续检查：

- `cap->crypto_capabilities` 是否支持算法及参数长度；
- `cap->ipsec.options` 是否支持 ESN、UDP encapsulation、checksum 等选项；
- `replay_win_sz` 是否超过 `replay_win_sz_max`；
- 返回的 `ol_flags` 要求哪些 mbuf offload flag；
- ingress 是否需要 `rte_flow` 把 ESP 流量 steering 到正确队列；
- session 是挂在 ethdev security context 还是 cryptodev security context。

当前 session 创建接口是：

```c
void *rte_security_session_create(
    void *instance,
    struct rte_security_session_conf *conf,
    struct rte_mempool *mp);
```

`conf` 必须同时包含 `action_type`、IPsec transform 和 `crypto_xform`。
不能把 `rte_security_ipsec_xform` 直接当作完整 session 配置传入。

### 6.1 mlx5 的边界需要特别澄清

DPDK mlx5 ethdev 文档列出的 IPsec 能力是 ESP header 匹配与 flow steering，
并没有声明通用的 `rte_security` IPsec inline protocol offload。

NVIDIA BlueField/ConnectX 平台可以通过 DOCA IPsec 等厂商栈实现硬件 IPsec，
但这不能自动等价为“任意 mlx5 PMD 都支持 DPDK inline IPsec”。

已公开支持 DPDK security/IPsec 的设备也常有严格限制，例如：

- 某些 ixgbe 设备只支持特定 inline crypto 组合；
- Marvell CNXK 同时提供 inline 与 lookaside protocol 能力；
- QAT 能力取决于具体代际、固件和 PMD；
- 同一设备的 VF、PF、representor 能力可能不同。

所以产品表应记录 **实际 capability dump + 固件/驱动版本**，而不是写
“某系列网卡固定支持 100G AES-GCM-256”。

---

## 7. SA 生命周期：真正困难的是 rekey 与切换

一个可运营的 SA 至少包含：

```text
selector / SPI / direction
mode / tunnel endpoints
algorithm / key / salt
sequence / ESN
anti-replay state
soft lifetime / hard lifetime
packet and byte counters
device session / flow rule
generation and control-plane identity
```

### 7.1 生命周期状态

```text
NEW
  │ 创建 crypto/security session 与 flow
  ▼
STANDBY
  │ 控制面原子发布
  ▼
ACTIVE
  │ soft lifetime 触发 rekey
  ▼
DRAINING
  │ 新流/新包切换到新 SA，旧 SA 接收在途包
  ▼
EXPIRED
  │ hard lifetime 或 drain 超时
  ▼
DESTROYED
```

### 7.2 无损 rekey 的基本顺序

1. 创建新入站 SA，使新旧 SPI 可同时接收；
2. 创建新出站 SA，但暂不发布给数据面；
3. 完成对端协商后，原子切换出站 SA 指针；
4. 保留旧入站 SA 一个受控 drain period；
5. 确认无在途 crypto op、mbuf 引用和 flow 命中；
6. 删除旧 flow、security session、密钥和 SA。

直接原地修改 ACTIVE SA 的 key、salt 或序列号，容易让在途包使用混合状态。

### 7.3 DPDK 不提供 IKE

DPDK 不实现 IKEv2、证书认证、MOBIKE 或 Dead Peer Detection。
`ipsec-secgw` 从静态配置读取 SA，不会直接参与 IKE 协商。

strongSwan 默认通过 kernel plugin 将 CHILD_SA 安装到 Linux XFRM。
要让它驱动自定义 DPDK 数据面，需要额外开发受保护的控制面适配层，负责：

- 接收 CHILD_SA 建立、rekey、删除和过期事件；
- 安全地取得或派生数据面所需 key material；
- 将 policy/SA 转换为 DPDK 的 session、flow 与路由对象；
- 处理失败回滚和新旧 SA 双活窗口；
- 保证日志、core dump 和遥测不泄露密钥。

VICI 主要是 strongSwan 的配置与控制接口，不能简单假设它会把 CHILD_SA 密钥
直接暴露给任意客户端。监听 `NETLINK_XFRM` 也不是一条现成、可移植的 DPDK 集成方案。

---

## 8. MTU、NAT-T 与分片

### 8.1 ESP 会吃掉有效 MTU

隧道模式开销大致包括：

```text
outer IP header
ESP header
explicit IV
padding + pad length + next header
ICV/tag
可选 UDP encapsulation header
```

以 IPv4 tunnel + AES-GCM 为例，常见基础开销约为：

```text
20 outer IPv4
+ 8 ESP header
+ 8 explicit IV
+ 2 trailer fields
+ 16 ICV
= 54 bytes + 0..padding
```

使用 IPv6 outer header或 NAT-T 时还会增加。实际值取决于算法和对齐要求。

### 8.2 先分片还是先加密

不同位置分片会改变接收端负担和策略语义：

- **加密前分片**：每个 inner fragment 分别受 ESP 保护，会消耗更多序列号与 SA 处理；
- **加密后外层分片**：接收端必须先重组 outer packet 才能验证 ESP；
- **避免分片**：通过 PMTU、MSS clamp、合适的 inner MTU 或 tunnel MTU 管理。

生产网关应明确：

- DF bit 的 copy/clear/set 策略；
- IPv4/IPv6 PMTU 与 ICMP error 处理；
- multi-segment mbuf 和硬件 scatter/gather 能力；
- inline 设备的 maximum packet size 与 TSO/segmentation 组合。

### 8.3 NAT-T

NAT-T 通常把 ESP 封装在 UDP/4500 中。启用前需要核对：

- action 是否支持 `udp_encap`；
- source/destination port 能否配置；
- checksum 行为；
- ingress flow 如何区分 IKE 与 UDP-encapsulated ESP；
- 硬件是否支持该模式与 tunnel/transport 组合。

---

## 9. `ipsec-secgw`：正确的学习和验证方式

官方示例支持：

- IPv4/IPv6；
- ESP transport/tunnel；
- SPD、SAD 与路由；
- software、CPU crypto、inline、lookaside protocol 等路径；
- ESN、抗重放、UDP encapsulation 和部分 fallback 场景；
- poll mode 与 event mode。

它不提供：

- IKE 与动态 peer 管理；
- 完整 HA、配置事务和密钥托管；
- 通用管理 API；
- 自动适配所有 PMD 的生产配置。

### 9.1 配置对象的关系

```text
sp ... protect <spi>
        │
        └────────► sa in/out <spi> ...

sa ...
  ├─ algorithm / key / mode / tunnel
  ├─ type <action type>
  ├─ port_id <security device or ethdev>
  └─ optional esn / udp-encap / fallback

rt ...
  └─ destination prefix → output port
```

官方 `ep0.cfg` 中的基本语法形态如下：

```ini
sp ipv4 out esp protect 5 pri 1 \
  dst 192.168.105.0/24 sport 0:65535 dport 0:65535

sa out 5 \
  cipher_algo aes-128-cbc \
  cipher_key 0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0 \
  auth_algo sha1-hmac \
  auth_key 0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0 \
  mode ipv4-tunnel src 172.16.1.5 dst 172.16.2.5

rt ipv4 dst 172.16.2.5/32 port 0
```

这只是语法示例。示例中的全零 key 和旧算法不得用于生产。
AEAD、action type 和设备参数应以当前版本 sample guide 与 `--help` 为准，
不能混用不同 DPDK 版本的配置格式。

### 9.2 推荐的四阶段实验

- **NULL crypto 基线**：验证 SPD、SAD、路由、包头增删和 MTU。
- **software / CPU crypto**：验证 AES-GCM、ICV 失败、ESN 和抗重放。
- **lookaside**：观察 enqueue/dequeue、queue pair、batch 和 reorder。
- **inline**：验证 capability、mbuf flags、flow steering、metadata 和硬件统计。

每次只改变一个主要变量，并保存双方配置、pcap、设备 capability 和统计快照。

---

## 10. 性能测试：先定义口径

### 10.1 最低限度的测试矩阵

| 维度     | 建议取值                                            |
| -------- | --------------------------------------------------- |
| 包长     | 64、128、256、512、1024、IMIX、接近 MTU             |
| SA 数量  | 1、1K、10K 或业务目标                               |
| 流量方向 | 单向、双向                                          |
| 模式     | transport、IPv4 tunnel、IPv6 tunnel、NAT-T          |
| action   | NONE、CPU crypto、lookaside protocol、inline        |
| 特性     | ESN、anti-replay、fallback、multi-segment           |
| 指标     | Mpps、Gbit/s、p50/p99/p99.9、丢包、CPU cycles、功耗 |

必须同时写清：

- 线速是否包含 preamble、IFG 和 FCS；
- Gbit/s 统计的是 wire bytes、ESP bytes 还是 inner payload；
- latency 是单向还是 RTT；
- CPU 核数、频率、NUMA、SMT 与隔离方式；
- PMD、固件、微码和设备 SKU；
- crypto queue pair 数和 burst；
- 是否包含 SPD/SAD lookup、route 和 replay check。

### 10.2 不能只测单 SA

单 SA 跑分容易命中 cache，也绕开了生产系统的关键压力：

- SAD/flow table 容量；
- session cache miss；
- 多 SA 到队列/lcore 的负载均衡；
- 热点隧道与长尾隧道；
- rekey 时双倍 session/flow 数；
- 统计读取对数据面的干扰。

### 10.3 primary/fallback 会引入顺序问题

硬件不支持某个包时，应用可能让它走软件 fallback。若 primary 与 fallback 延迟不同，
后发包可能先到，进而触发接收端抗重放误判。

```text
packet N     → slow fallback ─────────┐
packet N + 1 → fast primary ─────┐    │
                                 ▼    ▼
                           arrival N+1, N
```

因此 fallback 设计必须考虑：

- 是否允许同一 SA 同时走两条路径；
- 是否需要 reorder buffer；
- replay window 能否容纳最大乱序；
- fallback 是否只用于不支持的 SA，而不是逐包切换。

---

## 11. 故障排查：沿数据路径定位

### 11.1 SA 存在但没有 ESP 发出

按顺序检查：

1. RX 是否收到明文；
2. outbound SPD 是否命中 protect；
3. protect 指向的 SPI 是否存在；
4. SA direction/mode/tunnel endpoint 是否正确；
5. crypto/security session 是否创建成功；
6. crypto op 或 TX descriptor 是否成功提交；
7. route 是否把 outer destination 发到正确端口。

### 11.2 ESP 到达但无法解密

检查：

- SPI、方向和 outer endpoint；
- key、salt、IV、digest length；
- ESN 是否双方一致；
- NAT-T 是否双方一致；
- ICV/auth failure counter；
- ingress flow 是否把包送到正确 queue/SA owner；
- mbuf data offset 与 multi-segment 支持。

不要在确认根因前通过关闭校验、清除 mbuf error flag 或禁用抗重放“解决”问题。

### 11.3 合法包被判定 replay

需要同时观察：

- 收到的低 32-bit sequence；
- 推断出的 ESN 高位；
- 当前 `T` 与窗口大小；
- 包是否跨多路径乱序；
- 同一 SA 是否被多个 lcore 并发处理；
- primary/fallback completion 是否乱序；
- rekey 后旧、新 SPI 是否仍在 drain window。

### 11.4 rekey 时短暂丢包

典型根因：

- 先删除旧 SA，再创建新 SA；
- 新出站 SA 已启用，但对端新入站 SA 尚未准备；
- flow rule 与 security session 发布顺序错误；
- 旧 session 仍被在途 crypto op 引用；
- 新旧 SA 使用相同 SPI 或 nonce 状态发生回退。

---

## 12. 可观测性与密钥安全

每个 SA 至少应暴露：

```text
packets / bytes in and out
policy miss / SAD miss
auth or ICV failure
replay duplicate / too-old
sequence near exhaustion
soft / hard lifetime
crypto enqueue / dequeue / error
inline hardware hit / fallback
current generation and owner lcore
```

日志不得输出完整 key、salt、派生密钥或可复现密钥材料。还应防止密钥进入：

- core dump；
- 普通 metrics label；
- 未受保护的 telemetry socket；
- 配置管理历史；
- crash report；
- CLI 命令历史。

销毁 SA 时要清理应用保存的 key buffer；至于 PMD、固件或硬件中的 key 是否可擦除，
必须查看设备和驱动的安全保证，不能仅凭 `rte_free()` 作出假设。

---

## 13. 后量子 IPsec：变化主要发生在 IKE

量子威胁首先影响 IKE 中的公钥认证和密钥交换。ESP 数据面仍使用 AES-GCM 等
对称算法，因此后量子迁移的重点通常是：

```text
IKE authentication / key exchange
  classical + post-quantum hybrid
              │
              ▼
      派生 ESP symmetric keys
              │
              ▼
      DPDK 继续执行 ESP data plane
```

DPDK 25.11 的 cryptodev 增加了 ML-KEM、ML-DSA 等算法支持，但 DPDK 没有
`lib/pqc` 或自动的 PQ-IKE 状态机。把 cryptodev 支持写成“DPDK 已支持后量子
IPsec”是不准确的。

生产路线应是：

1. 盘点长期保密数据与算法依赖；
2. 跟踪 IETF IPsecME 的多密钥交换与 ML-KEM 相关标准；
3. 在 IKE 实现中测试 hybrid key exchange；
4. 保持 ESP 数据面与控制面算法协商解耦；
5. 测量更大 IKE message 对 MTU、分片、DoS 防护和握手 CPU 的影响。

不要预测某个具体年份一定出现可破解 RSA-2048 的量子计算机。应根据数据保密期、
迁移周期和“先收集后解密”风险制定计划。

---

## 14. 总结

DPDK IPsec 可以浓缩为三层：

```text
Policy plane
  SPD / route / peer / lifetime

Stateful protocol plane
  SA / SPI / sequence / ESN / anti-replay / ESP

Execution plane
  CPU crypto / cryptodev / lookaside protocol / inline
```

真正可靠的实现必须满足：

- 同一 SA 有明确的状态 owner；
- nonce 和序列号不会重用或回退；
- inbound 解密后再次执行 policy validation；
- 所有 action 和 option 都经过 capability 检查；
- rekey 使用新旧 SA 并存和受控 drain；
- MTU、NAT-T、分片和 fallback 被纳入测试；
- 性能数字附带完整测试口径；
- key material 不进入日志和不受控存储。

因此，选择 DPDK IPsec 方案时，不应先问“mlx5、QAT 还是 AES-NI 谁更快”，
而应先问：

> **谁维护 SA 状态，谁保证顺序，谁执行 ESP，失败时包会走到哪里？**

---

## 参考资料

### 标准

- [RFC 4301: Security Architecture for IP](https://www.rfc-editor.org/rfc/rfc4301)
- [RFC 4303: IP Encapsulating Security Payload](https://www.rfc-editor.org/rfc/rfc4303)
- [RFC 4106: AES-GCM for IPsec ESP](https://www.rfc-editor.org/rfc/rfc4106)
- [RFC 7634: ChaCha20-Poly1305 for IPsec](https://www.rfc-editor.org/rfc/rfc7634)
- [RFC 8221: Cryptographic Algorithm Requirements for ESP and AH](https://www.rfc-editor.org/rfc/rfc8221)
- [RFC 7296: Internet Key Exchange Protocol Version 2](https://www.rfc-editor.org/rfc/rfc7296)

### DPDK

- [DPDK IPsec Packet Processing Library](https://doc.dpdk.org/guides-26.03/prog_guide/ipsec_lib.html)
- [DPDK Security Library](https://doc.dpdk.org/guides-26.03/prog_guide/rte_security.html)
- [DPDK Cryptodev Library](https://doc.dpdk.org/guides-26.03/prog_guide/cryptodev_lib.html)
- [DPDK IPsec Security Gateway Sample](https://doc.dpdk.org/guides-26.03/sample_app_ug/ipsec_secgw.html)
- [DPDK 26.03 `rte_security.h`](https://doc.dpdk.org/api-26.03/rte__security_8h.html)
- [DPDK mlx5 ethdev documentation](https://doc.dpdk.org/guides-26.03/nics/mlx5.html)

### 控制面与厂商实现

- [strongSwan documentation](https://docs.strongswan.org/)
- [NVIDIA DOCA IPsec Gateway](https://docs.nvidia.com/doca/sdk/doca+ipsec+gateway+application+guide/index.html)
