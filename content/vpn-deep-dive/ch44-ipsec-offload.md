---
title: "VPN 技术深度探索 (四十四)：IPSec 硬件卸载"
date: 2026-04-13
tags: [vpn, series, ipsec, hardware-offload, qat, caam, crypto-accelerator]
description: "IPSec 硬件卸载深度解析——Intel QAT、CAAM、NITROX、cloud hw-offload，内核 xfrm 卸载接口、DMA 引擎、密码学加速"
---

> [!info] VPN 技术深度探索系列 0. [[vpn-deep-dive|全栈学习路径总览]]
>
> 1. [[ch43-subnet-router|第四十三章：Subnet Router 模式]]
> 2. **第四十四章：IPSec 硬件卸载**
> 3. [[ch45-wireguard-perf|第四十五章：WireGuard 性能]]

---

## 1. 概述：为什么需要硬件卸载

软件执行 IPSec 加密解密消耗大量 CPU 周期。在 10Gbps 链路以上，软件加密成为瓶颈——AES-GCM-256 每 Gbps 约需 0.5-1 GHz CPU 频率。硬件卸载（Hardware Offload）将密码学操作卸载到专用加速器，释放 CPU 用于业务处理。

```
IPSec 软件加密瓶颈：

┌─────────────────────────────────────────────────────────────────┐
│                     CPU 资源消耗分析                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  10Gbps 线速 IPSec ESP 加密（AES-256-GCM）：                     │
│                                                                 │
│  每包开销（64B 包）：                                            │
│  ├─ AES-256-GCM: ~200-300 cycles/packet                        │
│  ├─ SHA-256 HMAC: ~150-200 cycles/packet                       │
│  └─ 总计: ~350-500 cycles/packet                               │
│                                                                 │
│  10Gbps = ~14.88M pps (64B packets)                             │
│  14.88M × 400 cycles ≈ 6 GHz CPU 单核                           │
│                                                                 │
│  实际场景中多核并行：                                            │
│  ├─ 4 核 @ 3GHz 可处理约 3-4 Gbps                               │
│  ├─ 8 核 @ 3GHz 可处理约 6-8 Gbps                               │
│  └─ 10Gbps+ 需要硬件卸载                                         │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 2. 硬件卸载架构

### 2.1 卸载类型

IPSec 硬件卸载分为三种粒度：

```
IPSec 卸载类型：

┌─────────────────────────────────────────────────────────────────┐
│                     卸载类型对比                                  │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  协议卸载（Protocol Offload）：                                   │
│  ├─ 网卡识别 IPSec ESP/AH 报文                                   │
│  ├─ 自动处理加密/解密                                           │
│  ├─ SA 状态由硬件维护                                            │
│  └─ 最佳性能，需要网卡支持                                       │
│                                                                 │
│  密码学卸载（Crypto Offload）：                                   │
│  ├─ 网卡承担加密计算                                             │
│  ├─ 协议处理（ESP 头）仍在 CPU                                   │
│  ├─ SA 状态由内核管理                                            │
│  └─ 广泛兼容                                                     │
│                                                                 │
│  分段卸载（Segment Offload）：                                   │
│  ├─ TSO (TCP Segmentation Offload)                              │
│  ├─ UFO (UDP Fragmentation Offload)                             │
│  └─ 减少 CPU 包处理开销                                          │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 2.2 硬件加速器类型

```
主流 IPSec 硬件加速器：

┌─────────────────────────────────────────────────────────────────┐
│                     硬件加速器对比                                │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Intel QAT (QuickAssist Technology)：                           │
│  ├─ 型号：DH895xx, C6xx, D15xx                                  │
│  ├─ 协议：IPSec, TLS, SSL, DPAA                                 │
│  ├─ 加密：AES-NI, SHA-NI, RSA, EC, DEFLATE                      │
│  ├─ 性能：40 Gbps 加密/解密                                      │
│  ├─ 接口：PCIe x16, QAT API                                     │
│  └─ 驱动：qat_uio, vfio-pci                                     │
│                                                                 │
│  NXP CAAM (Cryptographic Acceleration Module)：                  │
│  ├─ 型号：LS1043, LS1046, i.MX8                                  │
│  ├─ 协议：IPSec, SSL/TLS, Freescale SEC                         │
│  ├─ 加密：AES, DES, 3DES, MD5, SHA, RSA, ECC                    │
│  ├─ 接口：jr interrupt, job ring                                 │
│  └─ 驱动：caam_jr, caamalg                                      │
│                                                                 │
│  AMD CCP (Cryptographic Co-Processor)：                          │
│  ├─ 型号：Ryzen, EPYC 内置                                       │
│  ├─ 协议：IPSec, TLS                                             │
│  ├─ 加密：AES-NI, SHA-NI, RSA                                   │
│  └─ 驱动：ccp, ccp-ops                                           │
│                                                                 │
│  Cavium NITROX：                                                 │
│  ├─ 型号：NITROX V, NITROX PX                                   │
│  ├─ 性能：50 Gbps AES-256-GCM                                   │
│  └─ 接口：PCIe, QAT API 兼容                                     │
│                                                                 │
│  AWS Nitro Enclave：                                             │
│  ├─ 云端加密：KMS 集成                                           │
│  ├─ 托管 IPSec：EC2 内置                                        │
│  └─ ENA 加密加速                                                 │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 3. Linux 内核 xfrm 卸载接口

### 3.1 卸载注册与发现

内核通过 `xfrm_state_afinfo` 和 `xfrm_type` 机制支持硬件卸载：

```c
// include/net/xfrm.h

struct xfrm_state_offload {
    struct net_device *dev;          // 关联的网络设备
    unsigned long flags;            // XFRM_STATE flags
    struct crypto_aead *aead;       // AEAD 密码算法
    struct crypto_sync_skcipher *geniv;
    void *drv_data;                 // 驱动私有数据
};

// 卸载标志位
#define XFRM_STATE_OFFLOAD_FLAG    0x1  // 启用硬件卸载
#define XFRM_STATE_ESN_FLAG       0x2  // 扩展序列号
```

### 3.2 卸载流程

```
IPSec 硬件卸载流程：

┌─────────────────────────────────────────────────────────────────┐
│                     卸载启用流程                                  │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. SADB 注册（内核 -> 驱动）：                                   │
│     setsockopt(XFRM_MSG_NEWSA)                                  │
│     └─> xfrm_init_state()                                       │
│         └─> xfrm_init_state_tfm()                               │
│             └─> crypto_aead_setauthsize()                       │
│             └─> crypto_aead_setkey()                            │
│             └─> dev->xfrmdev_ops->init_sequence()               │
│                                                                 │
│  2. 设备查找（算法 -> 设备）：                                    │
│     ├─ crypto_lookup_skcipher()                                 │
│     ├─ crypto_lookup_aead()                                     │
│     └─ 查找支持对应算法的硬件设备                                 │
│                                                                 │
│  3. SA 下发到硬件：                                              │
│     └─ dev->xfrmdev_ops->init_sequence()                        │
│         └─ 将 SA 参数写入硬件                                     │
│         └─ 建立 DMA 描述符环                                      │
│         └─ 配置密钥/IV/盐值                                      │
│                                                                 │
│  4. 数据面（零拷贝路径）：                                        │
│     ├─ 网卡收到 ESP 包                                          │
│     ├─ DMA 传递到加速器                                          │
│     ├─ 硬件解密/验证                                             │
│     ├─ DMA 回传明文                                              │
│     └─ 协议栈处理                                                │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 3.3 netdev XFRM 驱动接口

```c
// include/linux/netdevice.h

struct xfrmdev_ops {
    int     (*init_sequence)(struct xfrm_state *x, struct net_device *dev);
    void    (*init_sequence_done)(struct xfrm_state *x);
    void    (*destroy)(struct xfrm_state *x);
    int     (*is_ipsec_sa)(struct xfrm_state *x);
    void    (* Protective_MTU)(struct xfrm_state *x, unsigned int mtu);
};

// 示例：ixgbe 驱动注册
static const struct xfrmdev_ops xfrmdev_ops_ixgbe = {
    .init_sequence      = ixgbe_ipsec_init,
    .init_sequence_done = ixgbe_ipsec_init_done,
    .destroy            = ixgbe_ipsec_del_sa,
};
```

---

## 4. Intel QAT 深度解析

### 4.1 QAT 架构

```
Intel QAT 架构：

┌─────────────────────────────────────────────────────────────────┐
│                     QAT 内部结构                                 │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│                    Host CPU                                     │
│                       │                                          │
│              ┌────────┴────────┐                               │
│              │    PCIe Bus     │                               │
│              └────────┬────────┘                               │
│                       │                                          │
│              ┌────────┴────────┐                               │
│              │   QAT Device    │                               │
│              │  (DH895xx/C6xx) │                               │
│              └────────┬────────┘                               │
│                       │                                          │
│         ┌─────────────┼─────────────┐                         │
│         ▼             ▼             ▼                         │
│   ┌──────────┐  ┌──────────┐  ┌──────────┐                   │
│   │   CPE    │  │   PPE    │  │   DMA    │                   │
│   │(Crypto) │  │ (Packete)│  │ (Memory) │                   │
│   └──────────┘  └──────────┘  └──────────┘                   │
│   └─ AES/KAS │  └─ Compress │  └─ Data   │                   │
│   └─ RSA/EC  │  └─ Checksum │  └─ Move   │                   │
│   └─ SHA     │               │          │                   │
│                                                                 │
│   QAT 提供 4 类服务：                                            │
│   ├─ Symmetric (对称)：AES/DES/SHA/MAC                          │
│   ├─ Asymmetric (非对称)：RSA/EC/DH                             │
│   ├─ Pipeline (管道)：Compression/CRC                            │
│   └─ DMA：内存搬运                                               │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 4.2 QAT 驱动架构

```
QAT 驱动层次：

┌─────────────────────────────────────────────────────────────────┐
│                     QAT 驱动软件栈                               │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  用户空间：                                                      │
│  ├─ QAT API (qatzip, openssl, ipsec-tools)                     │
│  └─ OpenSSL ENGINE (qat_openssl)                                │
│                                                                 │
│  内核空间：                                                      │
│  ├─ QAT char device (/dev/crypto_adf)                          │
│  ├─ ICP tradss/ICQAS (QuickAssist SDK)                         │
│  ├─ Linux Crypto API (crypto.ko)                               │
│  └─ VFIO/UIO driver (qat_uio.ko)                               │
│                                                                 │
│  固件层：                                                        │
│  ├─ QAT Firmware (微码)                                        │
│  └─ uC (卸载微控制器)                                           │
│                                                                 │
│  硬件层：                                                        │
│  └─ QAT ASIC                                                    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 4.3 QAT IPSec 配置示例

```bash
# 检查 QAT 设备
lspci | grep -i quickassist

# 加载 QAT 驱动
modprobe qat_uio
modprobe intel_qat

# 验证驱动加载
ls -la /sys/bus/pci/drivers/qat_uio/

# 配置内核 crypto 使用 QAT
echo 1 > /sys/module/kernel/parameters/crypto_intel_qat

# ip xfrm 使用硬件卸载
# 编辑 /etc/ipsec.conf 或使用 ip 命令
ip xfrm state add src 203.0.113.1 dst 203.0.113.2 \
    proto esp \
    spi 0x1001 \
    reqid 0x01 \
    enc aesni '0x0123456789abcdef0123456789abcdef' \
    auth sha256 '0xabcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef' \
    mode tunnel \
    encap espinudp 4500 \
    offload dev eth0
```

---

## 5. ，云服务商硬件卸载

### 5.1 AWS Nitro IPSec

```
AWS Nitro IPSec 卸载：

┌─────────────────────────────────────────────────────────────────┐
│                     AWS Nitro 安全通道                           │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  EC2 实例：                                                      │
│  ├─ Nitro Card (内置 IPSec 卸载)                               │
│  ├─ ENA Express (弹性网络适配器)                                │
│  └─ KMS 集成 (密钥管理)                                         │
│                                                                 │
│  流量路径：                                                      │
│  VM ──> Nitro ──> ESP加密 ──> 网络                             │
│                                                                 │
│  优势：                                                          │
│  ├─ 零 CPU 开销 IPSec                                          │
│  ├─ KMS 托管密钥，自动轮换                                      │
│  └─ 25 Gbps 加密带宽                                            │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 5.2 Azure DDoS Protection + IPSec

```
Azure 加密选项：

┌─────────────────────────────────────────────────────────────────┐
│                     Azure 加密方案                               │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Azure VPN Gateway：                                            │
│  ├─ PolicyBased VPN (基于策略)                                  │
│  ├─ RouteBased VPN (基于路由，默认)                             │
│  ├─ Crypto: AES-256, SHA-384, DH14                             │
│  └─ 吞吐：100 Mbps - 6.6 Gbps                                   │
│                                                                 │
│  Azure Accelerated Networking：                                 │
│  ├─ SR-IOV 支持                                                │
│  └─ VM 内置加密卸载                                             │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 6. 性能对比与基准测试

### 6.1 卸载前后性能对比

```
IPSec 性能基准（实验室数据）：

┌─────────────────────────────────────────────────────────────────┐
│               AES-256-GCM 吞吐量对比 (单向)                      │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  配置                  │ 64B pps    │ 1Gbps   │ 10Gbps           │
│  ─────────────────────┼────────────┼─────────┼─────────         │
│  软件（4核 3GHz）     │ 1.2M       │ 0.6 Gbps │ 失败              │
│  软件（8核 3GHz）     │ 2.4M       │ 1.2 Gbps │ 2.4 Gbps         │
│  QAT DH895xx (单卡)   │ 14.88M     │ 10 Gbps  │ 40 Gbps          │
│  QAT C6xx (双卡)      │ 29.76M     │ 20 Gbps  │ 80 Gbps          │
│  Nitro (EC2 c5n)      │ 14.88M     │ 10 Gbps  │ 25 Gbps          │
│                                                                 │
│  CPU 利用率对比（10Gbps 24小时负载）：                            │
│  配置                  │ CPU 利用率                               │
│  ─────────────────────┼────────────                               │
│  软件（8核）          │ 85%                                       │
│  QAT 卸载             │ 5%                                        │
│  Nitro                │ 2%                                        │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 6.2 延迟对比

```
IPSec 延迟对比（单程）：

┌─────────────────────────────────────────────────────────────────┐
│                     延迟对比 (UDP 回环)                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  MTU=1400, AES-256-GCM:                                        │
│                                                                 │
│  配置                  │ 延迟 (μs)                               │
│  ─────────────────────┼────────────                               │
│  明文                 │ 15                                       │
│  软件 IPSec          │ 85-120                                   │
│  QAT 卸载            │ 25-35                                    │
│  Nitro               │ 20-30                                    │
│                                                                 │
│  抖动 (jitter)：                                              │
│  软件 IPSec: ±15 μs                                            │
│  QAT 卸载: ±3 μs                                               │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 7. 常见问题与排查

### 7.1 卸载失败排查

```bash
# 1. 检查驱动状态
dmesg | grep -i qat
dmesg | grep -i caam

# 2. 检查 crypto API
cat /proc/crypto | grep -i aes

# 3. 检查设备
ls /sys/bus/pci/devices/*/driver

# 4. 验证 xfrm 卸载
ip -s xfrm state list
# 查看是否有 "offload" 标记

# 5. ethtool 检查卸载能力
ethtool -k eth0 | grep ipsec

# 6. 启用调试
echo 'module xfrm4_tunnel +p' > /dbg/dynamic_debug/control
echo 'module esp4 +p' > /dbg/dynamic_debug/control
```

### 7.2 卸载不稳定处理

```
常见卸载问题：

┌─────────────────────────────────────────────────────────────────┐
│                     卸载问题与解决方案                            │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  问题1：卸载后丢包严重                                          │
│  原因：MTU 不匹配，硬件无法处理分片                              │
│  解决：设置合理的 MTU (1400-1500), 启用 PMTUD                  │
│                                                                 │
│  问题2：QAT 初始化失败                                          │
│  原因：固件未加载，PCIe BAR 地址错误                            │
│  解决：重启服务，加载正确的固件                                  │
│                                                                 │
│  问题3：性能未提升                                              │
│  原因：SA 数量超过硬件容量                                      │
│  解决：检查硬件 SA 限制，分散到多队列                            │
│                                                                 │
│  问题4：长连接中断                                              │
│  原因：硬件 SA 超时                                              │
│  解决：调整 SADB 超时时间，确保软件硬件同步                     │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 8. 总结

IPSec 硬件卸载是高性能 VPN 部署的关键技术：

- **软件瓶颈**：10Gbps+ 线速需要专用硬件加速器
- **卸载类型**：协议卸载 > 密码学卸载 > 分段卸载
- **主流方案**：Intel QAT（NITROX）、CAAM（NXP）、Nitro（AWS）
- **Linux 支持**：xfrm State Offload 接口，netdev XFRM 驱动
- **性能提升**：CPU 利用率从 80%+ 降至 <5%，吞吐提升 10x+
- **适用场景**：数据中心互联、云服务出口、高密度 VPN 网关

下一章我们将深入探讨 **WireGuard 性能优化**，分析其极致性能背后的设计原理与调优策略。

---

> [!tip] 延伸阅读
>
> - Intel QAT 官方文档：https://intel.com/QAT
> - Linux IPSec 硬件卸载：Documentation/networking/ipsec-offload.rst
> - Kernel Crypto API：Documentation/crypto/api.rst
