---
title: "DPDK 深度探索 (三十)：Lookaside 加速——Cryptodev、QAT、IPsec"
date: 2026-04-10 10:30:00
tags: [dpdk, series, lookaside, crypto, ipsec, qat, aesni, cryptodev, rte_security]
description: "深入解析 DPDK Lookaside 加速：Cryptodev 框架、QAT 硬件卸载、AES-NI 软件 PMD、rte_security、IPsec 集成"
---

> [!info] DPDK 深度探索系列 0. [[dpdk-deep-dive|全栈学习路径总览]]
> 1-29. 前二十九章已完成 30. **第三十章：Lookaside 加速——Cryptodev、QAT、IPsec**

---

## 1. Lookaside 概述

### 1.1 什么是 Lookaside

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                   Inline vs Lookaside 加速                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  Inline 加速:                                                              │
│  ────────────                                                              │
│  数据路径直接经过 NIC 硬件处理 (加密在网卡内部完成)                         │
│  - 优点: 零额外延迟，CPU 完全不参与加密                                    │
│  - 缺点: 依赖网卡硬件能力，灵活性低                                       │
│  - 例: mlx5 IPsec offload, i40e IPsec offload                              │
│                                                                             │
│  Lookaside 加速:                                                           │
│  ─────────────────                                                          │
│  CPU 处理主体数据路径，加密/认证操作卸载到协处理器                          │
│  - 优点: 灵活，CPU 仍控制数据路径，可混用多种硬件                          │
│  - 缺点: 数据需要 CPU↔协处理器往返                                       │
│  - 例: Intel QAT, AES-NI 软件 PMD                                         │
│                                                                             │
│  ┌──────────────────────────────────────────────────────────────────┐      │
│  │  Inline:  App → NIC [加密] → 线路                               │      │
│  │  Lookaside: App → 加密请求 → Crypto Dev → App → NIC → 线路     │      │
│  └──────────────────────────────────────────────────────────────────┘      │
│                                                                             │
│  CPU Crypto (第三种方式):                                                  │
│  ──────────────────────                                                    │
│  CPU 直接使用 SIMD 指令完成加密，无硬件卸载                                │
│  - 优点: 最低延迟 (~几十 ns)，无需额外硬件                                │
│  - 缺点: 消耗 CPU 周期                                                    │
│  - 例: AESNI-MB/GCM PMD, rte_security CPU_CRYPTO mode                     │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 1.2 三种方式对比

| 特性           | Inline            | Lookaside      | CPU Crypto    |
| -------------- | ----------------- | -------------- | ------------- |
| **加密执行者** | NIC 硬件          | 协处理器 (QAT) | CPU SIMD      |
| **CPU 开销**   | 零                | 极低           | 高            |
| **延迟**       | ~100ns            | ~1-5μs         | ~50-200ns     |
| **灵活性**     | 低                | 高             | 最高          |
| **适用场景**   | 大流量 IPsec 网关 | 加密+压缩+PKI  | 小流量/低延迟 |

---

## 2. Cryptodev 框架

### 2.1 架构总览

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        Cryptodev 架构                                       │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌──────────────────────────────────────────────────────────────────┐      │
│  │                     Application                                 │      │
│  └────────────────────────┬─────────────────────────────────────────┘      │
│                           │                                                 │
│              ┌────────────┼────────────────┐                               │
│              │            │                │                                │
│  ┌───────────▼──┐  ┌──────▼───────┐  ┌─────▼──────────┐                  │
│  │ rte_cryptodev │  │ rte_security │  │  rte_ipsec     │                  │
│  │  (底层加密API) │  │ (安全会话管理)│  │ (IPsec 库)    │                  │
│  └───────┬──────┘  └──────┬───────┘  └───────┬────────┘                  │
│          │                │                   │                             │
│  ┌───────▼────────────────▼───────────────────▼──────────┐               │
│  │                   Cryptodev PMD                        │               │
│  │                                                         │               │
│  │  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐ │               │
│  │  │  QAT PMD │ │IPsec MB  │ │ OpenSSL  │ │  mlx5    │ │               │
│  │  │(硬件卸载)│ │(AESNI-MB │ │ (参考    │ │ (硬件+   │ │               │
│  │  │          │ │ AESNI-GCM│ │  实现)   │ │  inline) │ │               │
│  │  └──────────┘ └──────────┘ └──────────┘ └──────────┘ │               │
│  └─────────────────────────────────────────────────────────┘               │
│                                                                             │
│  三层关系:                                                                 │
│  - rte_cryptodev: 底层加密/解密操作 API                                   │
│  - rte_security: 统一安全会话管理 (支持 inline + lookaside)                │
│  - rte_ipsec: 高层 IPsec 协议处理 (SA 管理, ESP 封装/解封)                │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 2.2 PMD 类型

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     主要 Cryptodev PMD                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  硬件 PMD:                                                                │
│  ──────────                                                                │
│  - Intel QAT:    PCIe 加速卡 (C3xxx/C4xxx)                                 │
│      vdev/PCI 自动发现，支持 AES/SHA/RSA/EC/压缩                           │
│  - Mellanox mlx5: ConnectX 网卡内置加密引擎                                │
│      支持 inline + lookaside 两种模式                                      │
│  - cnxk:        Marvell OCTEON 系列内置加密                                │
│  - dpaa2_sec:   NXP Layerscape 内置加密                                    │
│                                                                             │
│  软件 PMD (CPU SIMD):                                                     │
│  ────────────────────                                                      │
│  - ipsec_mb:    Intel Multi-Buffer 框架                                    │
│      子 PMD: crypto_aesni_mb (AES-CBC/CTR/CCM/GCM, SHA, HMAC)             │
│      子 PMD: crypto_aesni_gcm (AES-GCM 专用，AVX-512 优化)                │
│      子 PMD: crypto_kasumi, crypto_snow3g, crypto_zuc (3GPP)               │
│  - openssl:     基于 OpenSSL 库的参考实现                                  │
│  - null:        空操作 (性能测试基线)                                      │
│                                                                             │
│  vdev 创建方式:                                                            │
│  --vdev crypto_aesni_mb     # AESNI-MB 软件 PMD                           │
│  --vdev crypto_aesni_gcm    # AESNI-GCM 软件 PMD                          │
│  --vdev crypto_openssl      # OpenSSL PMD                                  │
│  --vdev crypto_null         # Null PMD (直通)                              │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 2.3 PMD 本质：C 语言的面向对象

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    PMD 是什么？                                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  PMD = Poll Mode Driver (轮询模式驱动)                                     │
│  DPDK 官方术语, 详见:                                                      │
│  https://doc.dpdk.org/guides/prog_guide/poll_mode_drv.html                 │
│                                                                             │
│  名字由来:                                                                 │
│  - 传统驱动用中断通知 CPU "有数据了"                                       │
│  - DPDK 放弃中断, 改成应用不停轮询 (Poll)                                  │
│  - → Poll Mode Driver                                                      │
│                                                                             │
│  后来含义扩大:                                                             │
│  - 不只是网卡驱动, 所有 DPDK 设备驱动都叫 PMD                             │
│  - Crypto PMD, Compress PMD, Regex PMD, Baseband PMD...                   │
│  - 因为它们都遵循同一套 "注册函数指针" 的模式                              │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

```
PMD 在代码层面就是一个 C 结构体 + 函数指针:

  ┌─────────────────────────────────────────────────────────────────────┐
  │                                                                     │
  │  Crypto PMD 定义 (简化):                                           │
  │                                                                     │
  │  struct rte_cryptodev_ops {                                         │
  │      int (*dev_configure)(struct rte_cryptodev *, config *);       │
  │      int (*dev_start)(struct rte_cryptodev *);                     │
  │      uint16_t (*enqueue_burst)(qp, ops, n);                        │
  │      uint16_t (*dequeue_burst)(qp, ops, n);                        │
  │      // ...                                                        │
  │  };                                                                │
  │                                                                     │
  │  每个 PMD 就是: 一组函数实现 + 一个注册宏                          │
  │                                                                     │
  │  // AESNI-MB PMD                                                   │
  │  static struct rte_cryptodev_ops aesni_mb_ops = {                  │
  │      .enqueue_burst = aesni_mb_pmd_enqueue_burst,                  │
  │      .dequeue_burst = aesni_mb_pmd_dequeue_burst,                  │
  │      ...                                                           │
  │  };                                                                │
  │  RTE_PMD_REGISTER_VDEV(crypto_aesni_mb, ...);                      │
  │                                                                     │
  │  // QAT PMD                                                        │
  │  static struct rte_cryptodev_ops qat_ops = {                       │
  │      .enqueue_burst = qat_sym_enqueue_burst,                       │
  │      .dequeue_burst = qat_sym_dequeue_burst,                       │
  │      ...                                                           │
  │  };                                                                │
  │  RTE_PMD_REGISTER_PCI(qat, ...);                                   │
  │                                                                     │
  └─────────────────────────────────────────────────────────────────────┘
```

```
如果用 C++ 类比:

  ┌─────────────────────────────────────────────────────────────────────┐
  │                                                                     │
  │  C++ 写法:                                                         │
  │                                                                     │
  │  class Cryptodev {                          // 抽象基类             │
  │  public:                                                            │
  │      virtual uint16_t enqueue(qp, ops, n) = 0;                     │
  │      virtual uint16_t dequeue(qp, ops, n) = 0;                     │
  │  };                                                                │
  │                                                                     │
  │  class AESNI_MB_PMD : public Cryptodev {    // 具体实现            │
  │      uint16_t enqueue(...) override { /* CPU AES-NI 指令 */ }      │
  │  };                                                                │
  │                                                                     │
  │  class QAT_PMD : public Cryptodev {         // 另一个实现          │
  │      uint16_t enqueue(...) override { /* 发给 QAT 硬件 */ }        │
  │  };                                                                │
  │                                                                     │
  │  Cryptodev *dev = new AESNI_MB_PMD();                              │
  │  dev->enqueue(0, ops, 32);   // 多态, 运行时决定调哪个            │
  │                                                                     │
  │  ─────────────────────────────────────────────                      │
  │                                                                     │
  │  DPDK 的 C 写法 (本质一样):                                        │
  │                                                                     │
  │  struct rte_cryptodev {                     // "基类" = 结构体      │
  │      struct rte_cryptodev_ops *ops;         // "虚函数表"           │
  │  };                                                                │
  │                                                                     │
  │  rte_cryptodev_enqueue_burst(dev_id, ...) {                        │
  │      dev->ops->enqueue_burst(...);          // 函数指针 = 多态     │
  │  }                                                                 │
  │                                                                     │
  │  C 没有类, 用函数指针手动实现了面向对象多态                         │
  │  Linux 内核的 file_operations 也是同样的套路                       │
  │                                                                     │
  └─────────────────────────────────────────────────────────────────────┘
```

### 2.4 enqueue_burst 内部做了什么

```c
// rte_cryptodev_enqueue_burst 是一个 inline 函数
// 它做了一件事: 通过 dev_id 找到函数指针, 然后调用

static inline uint16_t
rte_cryptodev_enqueue_burst(uint8_t dev_id, uint16_t qp_id,
                             struct rte_crypto_op **ops, uint16_t nb_ops)
{
    struct rte_cryptodev *dev = &rte_crypto_devices[dev_id];
    //                       ↑
    //   全局数组, 存着所有 crypto 设备的函数指针表

    return (*dev->enqueue_burst)(
        dev->data->queue_pairs[qp_id], ops, nb_ops);
    //     ↑
    //  运行时跳转到对应 PMD 的实现
}
```

```
完整调用链:

  rte_cryptodev_enqueue_burst(0, 0, ops, n)
      │
      │  inline 展开
      ▼
  rte_crypto_devices[0]->enqueue_burst(qp, ops, n)
      │
      │  函数指针跳转 (运行时决定)
      │
      ├──→ aesni_mb_pmd_enqueue_burst()
      │      遍历 ops[], 对每个 op:
      │        1. 取出 mbuf 数据地址 + session 密钥
      │        2. 调用 Intel Multi-Buffer 库 (CPU AES-NI + AVX)
      │        3. 加密结果直接写回 mbuf (in-place)
      │        4. op->status = SUCCESS
      │
      ├──→ qat_sym_enqueue_burst()
      │      遍历 ops[], 对每个 op:
      │        1. 打包成 QAT 硬件请求格式
      │        2. 写入 QAT 的 MMIO ring buffer (PCIe)
      │        3. QAT 硬件异步加密
      │        4. (dequeue 时从 completion ring 取回)
      │
      └──→ openssl_pmd_enqueue_burst()
             遍历 ops[], 对每个 op:
               1. 转换成 OpenSSL EVP 接口
               2. EVP_EncryptUpdate()
               3. 结果写回 mbuf

  你的代码完全不知道底层是哪个 PMD 在干活
  它只知道 enqueue / dequeue 这两个 API
```

### 2.5 设备初始化

```c
#include <rte_cryptodev.h>

// 完整的 Cryptodev 初始化流程
int
crypto_init(uint8_t *dev_id_out)
{
    int ret;

    // 1. 查询可用设备数量
    uint8_t nb_devs = rte_cryptodev_count();
    if (nb_devs == 0) {
        // 尝试创建 vdev (软件 PMD)
        ret = rte_vdev_init("crypto_aesni_mb", NULL);
        if (ret < 0)
            return -1;
        nb_devs = rte_cryptodev_count();
    }
    printf("Found %u crypto devices\n", nb_devs);

    // 2. 选择设备 (遍历查找合适的)
    uint8_t dev_id = 0;
    struct rte_cryptodev_info info;
    rte_cryptodev_info_get(dev_id, &info);
    printf("Using device: %s (driver: %s)\n",
           rte_cryptodev_name_get(dev_id), info.driver_name);

    // 3. 创建 crypto op 内存池
    struct rte_mempool *crypto_op_pool;
    crypto_op_pool = rte_crypto_op_pool_create("crypto_op_pool",
            RTE_CRYPTO_OP_TYPE_SYMMETRIC,
            8192,          // nb_elts
            64,            // cache_size
            0,             // priv_size
            rte_socket_id());
    if (crypto_op_pool == NULL)
        return -1;

    // 4. 配置设备
    struct rte_cryptodev_config dev_conf = {
        .socket_id = rte_socket_id(),
        .nb_queue_pairs = 1,
        .ff_disable = 0,  // 不禁用任何特性
    };
    ret = rte_cryptodev_configure(dev_id, &dev_conf);
    if (ret < 0)
        return -1;

    // 5. 设置 queue pair
    struct rte_cryptodev_qp_conf qp_conf = {
        .nb_descriptors = 2048,
        .mp_session = crypto_op_pool,  // session 内存池
    };
    ret = rte_cryptodev_queue_pair_setup(dev_id, 0, &qp_conf,
                                          rte_socket_id());
    if (ret < 0)
        return -1;

    // 6. 启动设备
    ret = rte_cryptodev_start(dev_id);
    if (ret < 0)
        return -1;

    *dev_id_out = dev_id;
    return 0;
}
```

### 2.4 查看设备信息

```bash
# 查看 DPDK 支持的 crypto PMD
ls /home/huanglin/code/dpdk/drivers/crypto/

# dpdk-test-crypto-perf: 加密性能测试工具
./build/app/dpdk-test-crypto-perf -l 0-1 -- \
    --devtype crypto_aesni_mb \
    --optype aead \
    --aead-algo aes-gcm \
    --aead-key-sz 32 \
    --aead-iv-sz 12 \
    --buffer-sz 64,256,1024,1420 \
    --burst-sz 32 \
    --total-ops 1000000 \
    --ptest throughput

# 测试延迟
./build/app/dpdk-test-crypto-perf -l 0-1 -- \
    --devtype crypto_aesni_mb \
    --optype aead \
    --aead-algo aes-gcm \
    --ptest latency

# 测试 QAT 性能
./build/app/dpdk-test-crypto-perf -l 0-3 -a 3d:00.0 -- \
    --devtype qat \
    --optype cipher-then-auth \
    --cipher-algo aes-cbc \
    --auth-algo sha256-hmac \
    --ptest throughput
```

---

## 3. Crypto 操作详解

### 3.1 核心数据结构

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     Crypto 操作数据流                                       │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  Application:                                                              │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐                │
│  │  rte_mbuf    │    │ rte_crypto_op│    │   session    │                 │
│  │  (数据包)    │───→│  (操作描述)  │←───│  (密钥/算法) │                │
│  └──────────────┘    └──────┬───────┘    └──────────────┘                │
│                             │                                               │
│                     enqueue_burst()                                         │
│                             │                                               │
│  PMD:                 ┌─────▼──────┐                                       │
│                       │ Crypto Dev │                                       │
│                       └─────┬──────┘                                       │
│                             │                                               │
│                     dequeue_burst()                                         │
│                             │                                               │
│                      ┌──────▼───────┐                                      │
│                      │ 已完成的 op  │                                      │
│                      │ (检查 status)│                                      │
│                      └──────────────┘                                      │
│                                                                             │
│  rte_crypto_op 结构:                                                      │
│  ┌───────────────────────────────────────────────────────────┐            │
│  │ type: SYMMETRIC / ASYMMETRIC                              │            │
│  │ status: SUCCESS / NOT_PROCESSED / ERROR                   │            │
│  │ sess_type: SESSION / SESSIONLESS                          │            │
│  │ phys_addr: IOVA 地址 (DMA)                                │            │
│  │ [紧跟] rte_crypto_sym_op 或 rte_crypto_asym_op            │            │
│  └───────────────────────────────────────────────────────────┘            │
│                                                                             │
│  rte_crypto_sym_op 关键字段:                                              │
│  ┌───────────────────────────────────────────────────────────┐            │
│  │ m_src / m_dst: 源/目标 mbuf                               │            │
│  │ session: 会话句柄                                         │            │
│  │ cipher.data: { offset, length } 加密数据范围               │            │
│  │ auth.data:   { offset, length } 认证数据范围               │            │
│  │ auth.digest: { data, phys_addr } 认证摘要                  │            │
│  │ aead:        { data, digest, aad } AEAD 专用              │            │
│  └───────────────────────────────────────────────────────────┘            │
│                                                                             │
│  注意: cipher/auth 的数据范围通过 offset+length 指定,                       │
│  不是通过指针。IV 通过 xform 中的 iv.offset 指定。                         │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 3.2 Session 管理

```c
// DPDK 24.11 session API (合并了旧的 create + init)

// 创建 session 内存池
struct rte_mempool *
create_session_pool(int socket_id)
{
    return rte_mempool_create("session_pool",
            256,                        // max sessions
            rte_cryptodev_sym_get_private_session_size(0),  // element size
            64,                         // cache_size
            0,                          // priv_size
            NULL, NULL,                 // mp_init, mp_init_arg
            NULL, NULL,                 // obj_init, obj_init_arg
            socket_id, 0);              // socket_id, flags
}

// 创建 AES-GCM AEAD session
void *
create_aes_gcm_session(uint8_t dev_id, struct rte_mempool *sess_pool)
{
    // AEAD xform (加密 + 认证一体化)
    struct rte_crypto_sym_xform xform = {
        .next = NULL,
        .type = RTE_CRYPTO_SYM_XFORM_AEAD,
        .aead = {
            .op = RTE_CRYPTO_AEAD_OP_ENCRYPT,
            .algo = RTE_CRYPTO_AEAD_AES_GCM,
            .key = {
                .data = aes_key,  // 256-bit key
                .length = 32,
            },
            .iv = {
                .offset = 0,      // IV 在 mbuf 中的偏移
                .length = 12,     // GCM 推荐 12 字节 IV
            },
            .digest_length = 16,  // GCM tag = 128 bit
            .aad_length = 12,     // Additional Authenticated Data
        },
    };

    // 一步创建 session (DPDK 24.11 API)
    return rte_cryptodev_sym_session_create(dev_id, &xform, sess_pool);
}

// 创建 AES-CBC + HMAC-SHA256 链式 session
void *
create_cipher_auth_session(uint8_t dev_id, struct rte_mempool *sess_pool)
{
    // xform 链: cipher → auth
    struct rte_crypto_sym_xform cipher_xform = {
        .type = RTE_CRYPTO_SYM_XFORM_CIPHER,
        .cipher = {
            .op = RTE_CRYPTO_CIPHER_OP_ENCRYPT,
            .algo = RTE_CRYPTO_CIPHER_AES_CBC,
            .key = { .data = cipher_key, .length = 16 },
            .iv = { .offset = 0, .length = 16 },
        },
    };

    struct rte_crypto_sym_xform auth_xform = {
        .next = NULL,
        .type = RTE_CRYPTO_SYM_XFORM_AUTH,
        .auth = {
            .op = RTE_CRYPTO_AUTH_OP_GENERATE,
            .algo = RTE_CRYPTO_AUTH_SHA256_HMAC,
            .key = { .data = auth_key, .length = 32 },
            .digest_length = 32,
        },
    };

    // 链接: cipher → auth
    cipher_xform.next = &auth_xform;

    return rte_cryptodev_sym_session_create(dev_id, &cipher_xform, sess_pool);
}

// 销毁 session
void
destroy_session(uint8_t dev_id, void *session, struct rte_mempool *sess_pool)
{
    rte_cryptodev_sym_session_free(dev_id, session);
}
```

### 3.3 加密操作完整示例

```c
// AES-GCM 加密单个包
int
encrypt_packet_aes_gcm(uint8_t dev_id, uint16_t qp_id,
                        void *session,
                        struct rte_mbuf *mbuf,
                        struct rte_mempool *op_pool,
                        uint8_t *iv_data, uint8_t *aad_data)
{
    // 1. 从池中分配 crypto op
    struct rte_crypto_op *op;
    op = rte_crypto_op_alloc(op_pool, RTE_CRYPTO_OP_TYPE_SYMMETRIC);
    if (op == NULL)
        return -ENOMEM;

    // 2. 附加 session
    rte_crypto_op_attach_sym_session(op, session);

    // 3. 设置 mbuf
    op->sym->m_src = mbuf;
    op->sym->m_dst = NULL;  // in-place 加密

    // 4. 设置 AEAD IV (在 mbuf headroom 中预留空间)
    // IV 位置由 xform 的 iv.offset 指定
    // 这里直接设置指针
    op->sym->aead.data.offset = 0;
    op->sym->aead.data.length = rte_pktmbuf_data_len(mbuf);

    // AAD 和 digest
    op->sym->aead.aad.data = aad_data;
    op->sym->aead.digest.data = rte_pktmbuf_mtod_offset(mbuf,
            uint8_t *, rte_pktmbuf_data_len(mbuf));

    // 5. 提交到设备
    uint16_t nb_enq = rte_cryptodev_enqueue_burst(dev_id, qp_id, &op, 1);
    if (nb_enq != 1) {
        rte_crypto_op_free(op);
        return -EAGAIN;
    }

    // 6. 等待完成
    struct rte_crypto_op *deq_op;
    uint16_t nb_deq = rte_cryptodev_dequeue_burst(dev_id, qp_id,
                                                    &deq_op, 1);
    if (nb_deq != 1)
        return -EAGAIN;

    // 7. 检查状态
    if (deq_op->status != RTE_CRYPTO_OP_STATUS_SUCCESS) {
        rte_crypto_op_free(deq_op);
        return -EFAULT;
    }

    rte_crypto_op_free(deq_op);
    return 0;
}
```

### 3.4 批量加密

```c
// 批量 AES-GCM 加密 (生产级模式)
uint16_t
encrypt_batch(uint8_t dev_id, uint16_t qp_id,
              void *session,
              struct rte_mbuf **mbufs, uint16_t nb_pkts,
              struct rte_mempool *op_pool,
              struct rte_crypto_op **ops)
{
    uint16_t i, nb_enq, nb_deq;

    // 1. 批量分配 ops
    if (rte_crypto_op_bulk_alloc(op_pool,
                                  RTE_CRYPTO_OP_TYPE_SYMMETRIC,
                                  ops, nb_pkts) < nb_pkts)
        return 0;  // 池不足

    // 2. 配置每个 op
    for (i = 0; i < nb_pkts; i++) {
        rte_crypto_op_attach_sym_session(ops[i], session);
        ops[i]->sym->m_src = mbufs[i];
        ops[i]->sym->m_dst = NULL;
        ops[i]->sym->aead.data.offset = 0;
        ops[i]->sym->aead.data.length = rte_pktmbuf_data_len(mbufs[i]);
    }

    // 3. 提交到设备
    nb_enq = rte_cryptodev_enqueue_burst(dev_id, qp_id, ops, nb_pkts);

    // 4. 收集完成结果
    uint16_t total_deq = 0;
    struct rte_crypto_op *deq_ops[nb_enq];

    do {
        nb_deq = rte_cryptodev_dequeue_burst(dev_id, qp_id,
                                              deq_ops, nb_enq - total_deq);
        for (i = 0; i < nb_deq; i++) {
            // 检查每个 op 的状态
            if (deq_ops[i]->status != RTE_CRYPTO_OP_STATUS_SUCCESS)
                printf("Crypto op failed: %d\n", deq_ops[i]->status);
        }
        total_deq += nb_deq;
        // 注意: 生产环境不应死等，应配合 main loop 轮询
    } while (total_deq < nb_enq);

    // 5. 释放 ops
    for (i = 0; i < nb_enq; i++)
        rte_crypto_op_free(ops[i]);

    return nb_enq;
}
```

---

## 4. rte_security 框架

### 4.1 为什么需要 rte_security

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     rte_security 的必要性                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  问题:                                                                    │
│  - rte_cryptodev 只管加密/解密，不理解协议语义                             │
│  - IPsec 的 SA/SPI/序列号/防重放窗口需要额外管理                           │
│  - Inline 模式需要 NIC 和 crypto 协同，cryptodev 无法统一管理              │
│                                                                             │
│  解决: rte_security 提供统一的安全会话抽象                                 │
│  ──────────────────────────────────────────                                │
│                                                                             │
│  支持的 action_type:                                                       │
│  ──────────────────                                                        │
│  - LOOKASIDE_PROTOCOL: 协处理器完成协议处理 (IPsec 全流程)                 │
│  - INLINE_CRYPTO:     NIC 内联加密 (仅加密/认证)                           │
│  - INLINE_PROTOCOL:   NIC 内联协议处理 (IPsec 全流程)                      │
│  - CPU_CRYPTO:        CPU SIMD 完成 (无硬件卸载)                           │
│                                                                             │
│  支持的 protocol:                                                          │
│  ─────────────────                                                         │
│  - IPsec (ESP/AH, Tunnel/Transport)                                        │
│  - MACsec                                                                  │
│  - PDCP (4G/5G)                                                            │
│  - DOCSIS (有线宽带)                                                        │
│  - TLS Record                                                              │
│                                                                             │
│  优势:                                                                    │
│  ────                                                                    │
│  - 一套 API 覆盖 inline + lookaside + CPU crypto                          │
│  - 协议语义 (序列号、防重放) 由框架管理                                    │
│  - 硬件差异对应用透明                                                     │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 4.2 rte_security 使用

```c
#include <rte_security.h>

// 创建 security 会话 (以 IPsec Lookaside 为例)
struct rte_security_session *
create_ipsec_security_session(uint8_t dev_id,
                               struct rte_mempool *sess_pool)
{
    // 获取 security context
    struct rte_security_ctx *sec_ctx =
            (struct rte_security_ctx *)rte_cryptodev_get_sec_ctx(dev_id);

    // 配置 security 会话
    struct rte_security_session_conf sec_conf = {
        .action_type = RTE_SECURITY_ACTION_TYPE_LOOKASIDE_PROTOCOL,
        .protocol = RTE_SECURITY_PROTOCOL_IPSEC,

        .ipsec = {
            .proto = RTE_SECURITY_IPSEC_SA_PROTO_ESP,
            .mode = RTE_SECURITY_IPSEC_SA_MODE_TUNNEL,
            .direction = RTE_SECURITY_IPSEC_SA_DIR_EGRESS,
            .spi = 0x12345678,
            .salt = 0x11111111,
            .options = {
                .udp_encap = 0,
                .replay_win_sz = 64,
                .esn = 0,
            },
        },

        .crypto_xform = &(struct rte_crypto_sym_xform){
            .next = &(struct rte_crypto_sym_xform){
                .type = RTE_CRYPTO_SYM_XFORM_AUTH,
                .auth = {
                    .op = RTE_CRYPTO_AUTH_OP_GENERATE,
                    .algo = RTE_CRYPTO_AUTH_SHA256_HMAC,
                    .key = { .data = auth_key, .length = 32 },
                    .digest_length = 16,
                },
            },
            .type = RTE_CRYPTO_SYM_XFORM_CIPHER,
            .cipher = {
                .op = RTE_CRYPTO_CIPHER_OP_ENCRYPT,
                .algo = RTE_CRYPTO_CIPHER_AES_CBC,
                .key = { .data = cipher_key, .length = 16 },
                .iv = { .offset = 0, .length = 16 },
            },
        },

        .userdata = NULL,
    };

    return rte_security_session_create(sec_ctx, &sec_conf, sess_pool);
}

// 查询设备安全能力
void
check_security_capabilities(uint8_t dev_id)
{
    struct rte_security_ctx *sec_ctx =
            (struct rte_security_ctx *)rte_cryptodev_get_sec_ctx(dev_id);

    const struct rte_security_capability *caps =
            rte_security_capabilities_get(sec_ctx);

    if (caps == NULL) {
        printf("Device %u has no security capabilities\n", dev_id);
        return;
    }

    for (int i = 0; caps[i].action != RTE_SECURITY_ACTION_TYPE_NONE; i++) {
        printf("  action=%d, protocol=%d\n",
               caps[i].action, caps[i].protocol);

        if (caps[i].protocol == RTE_SECURITY_PROTOCOL_IPSEC) {
            printf("    IPsec: proto=%d, mode=%d, dir=%d\n",
                   caps[i].ipsec.proto,
                   caps[i].ipsec.mode,
                   caps[i].ipsec.direction);
        }
    }
}
```

---

## 5. QAT 硬件卸载

### 5.1 QAT 架构

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     Intel QAT (QuickAssist Technology)                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  QAT 是 Intel 的 PCIe 加速卡，专用于加密/压缩/PKI                          │
│                                                                             │
│  产品线:                                                                  │
│  ────────                                                                  │
│  - C2000/C3000: 入门级 (Atom), ~5 Gbps                                    │
│  - C620/C627:   中端 (Xeon), ~40 Gbps                                     │
│  - C4200/C4xxx: 高端, ~100 Gbps, 支持压缩                                │
│  - 4xxx:        第四代, Intel Xeon with QAT Integrated                    │
│                                                                             │
│  硬件能力:                                                                │
│  ──────────                                                                │
│  - 对称加密: AES-CBC/CTR/XCB/GCM, DES, 3DES, SM4                          │
│  - 认证: SHA1/256/384/512, MD5, HMAC, SM3                                  │
│  - AEAD: AES-GCM, AES-CCM, Chacha20-Poly1305                              │
│  - 非对称: RSA (up to 4096), ECDSA, ECDH, DH                              │
│  - 压缩: Deflate, LZ4, LZ4s                                               │
│                                                                             │
│  DPDK QAT PMD:                                                            │
│  ──────────────                                                            │
│  - 驱动: drivers/crypto/qat/                                               │
│  - 自动发现 PCIe 设备 (无需 --vdev)                                       │
│  - 多 service: cryptodev + compressdev 共享同一硬件                        │
│  - 支持多 queue pair (每 qp 独立提交队列)                                 │
│                                                                             │
│  数据流:                                                                  │
│  ────────                                                                  │
│  App → enqueue_burst(qp) → QAT MMIO ring → QAT HW →                       │
│  completion ring → dequeue_burst(qp) → App                                 │
│                                                                             │
│  绑定 QAT 设备:                                                           │
│  dpdk-devbind -b vfio-pci 0000:3d:00.0                                    │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 5.2 QAT vs AES-NI 软件对比

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                  QAT vs AES-NI PMD 性能对比                                │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  AES-256-GCM, 1420 字节包:                                               │
│  ──────────────────────────                                                │
│                                                                             │
│  方案            吞吐量         CPU 占用      延迟       成本              │
│  ────            ──────         ────────      ────       ────              │
│  AESNI-GCM PMD   ~8 Gbps/core  100% CPU     ~50ns      零 (CPU内置)      │
│  AESNI-MB PMD    ~6 Gbps/core  100% CPU     ~80ns      零 (CPU内置)      │
│  OpenSSL PMD     ~2 Gbps/core  100% CPU     ~200ns     零                │
│  QAT C627        ~40 Gbps      <5% CPU      ~1-3μs     需 PCIe 卡        │
│  QAT 4xxx        ~100 Gbps     <5% CPU      ~1-2μs     Xeon 内置         │
│                                                                             │
│  选择建议:                                                                │
│  ────────                                                                  │
│  - 包量 < 10 MPPS: AES-NI 软件足够，延迟更低                             │
│  - 包量 > 10 MPPS: QAT 卸载，释放 CPU 做业务处理                         │
│  - 需要压缩 + 加密: QAT (同时支持)                                        │
│  - 非对称 (TLS 握手): QAT 显著优于软件                                   │
│  - 无 PCIe 插槽: AES-NI 或 Xeon 内置 QAT                                 │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 6. IPsec 集成

### 6.1 DPDK IPsec 库架构

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     DPDK IPsec 库 (lib/ipsec)                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  IPsec 库提供 IPsec 协议处理的高层抽象:                                   │
│  - SA 管理 (opaque struct rte_ipsec_sa)                                   │
│  - ESP 封装/解封装                                                        │
│  - 序列号管理 + 防重放窗口                                                │
│  - Tunnel / Transport 模式                                                │
│  - 自动配合 cryptodev 或 rte_security                                     │
│                                                                             │
│  核心组件:                                                                │
│  ──────────                                                                │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────┐          │
│  │ rte_ipsec_sa:  SA 对象 (opaque, 通过 sa_prm 初始化)         │          │
│  │ rte_ipsec_session: 绑定 SA + crypto/security session        │          │
│  │ rte_ipsec_sad:  SA 数据库 (SPI/DIP/SIP 查找)                │          │
│  └─────────────────────────────────────────────────────────────┘          │
│                                                                             │
│  处理流程 (出方向):                                                       │
│  ──────────────────                                                        │
│                                                                             │
│  1. rte_ipsec_pkt_crypto_prepare(ss, mb, cop, n)                           │
│     准备 crypto op: 填充 IV、设置加密范围、序列号                         │
│                                                                             │
│  2. rte_cryptodev_enqueue_burst() + dequeue_burst()                        │
│     提交加密到硬件/CPU，等待完成                                          │
│                                                                             │
│  3. rte_ipsec_pkt_process(ss, mb, n)                                       │
│     后处理: 添加 ESP 头、更新 IP 头、计算 ICV                             │
│                                                                             │
│  处理流程 (入方向):                                                       │
│  ──────────────────                                                        │
│                                                                             │
│  1. SAD 查找: rte_ipsec_sad_lookup(sad, keys, sa_ptrs, n)                 │
│     根据 SPI 查找对应的 SA                                                 │
│                                                                             │
│  2. rte_ipsec_pkt_crypto_prepare(ss, mb, cop, n)                           │
│     准备解密操作                                                           │
│                                                                             │
│  3. 加密完成后: rte_ipsec_pkt_process(ss, mb, n)                           │
│     移除 ESP 头、验证 ICV、恢复原始 IP 头                                 │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 6.2 完整的 IPsec 包处理路线图

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                  出方向: 明文包 → 加密 → 封装 ESP → 发送                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ① 应用收到一个明文包                                                      │
│                                                                             │
│     rte_eth_rx_burst(port, queue, &mbuf, 1)                                │
│                                                                             │
│     mbuf 内容:                                                              │
│     ┌──────────┬───────────┬─────────┐                                     │
│     │ Ethernet │    IP     │ Payload │  ← 明文, 还没加密                   │
│     └──────────┴───────────┴─────────┘                                     │
│                                                                             │
│  ② 查 SA: 这个包要不要加密? 用哪个 SA?                                    │
│                                                                             │
│     解析 IP 头 → 查路由 → 匹配安全策略 (SP)                               │
│     → 命中 → 查 SAD 找到对应的 SA                                          │
│     rte_ipsec_sad_lookup(sad, &key, &sa_ptr, 1)                            │
│                                                                             │
│     sa_ptr → rte_ipsec_session, 里面绑定了:                                │
│       - SA 参数 (SPI, 序列号, 加密算法)                                    │
│       - crypto session (密钥)                                              │
│       - crypto device (用哪个加密设备)                                     │
│                                                                             │
│  ③ 准备加密操作 (IPsec 库自动完成)                                        │
│                                                                             │
│     rte_ipsec_pkt_crypto_prepare(session, &mbuf, &crypto_op, 1)            │
│                                                                             │
│     IPsec 库自动做了:                                                      │
│     - 从内存池分配 crypto_op                                               │
│     - 绑定 crypto_op 和 session                                            │
│     - 绑定 crypto_op 和 mbuf                                               │
│     - 设置加密范围 (offset, length)                                        │
│     - 生成 IV                                                              │
│     - 递增序列号                                                           │
│                                                                             │
│     此时 mbuf 还是明文, 但 crypto_op 已描述好了                            │
│     "请加密 mbuf 的 offset=X, length=Y 这一段"                             │
│                                                                             │
│  ④ 提交加密请求到 Cryptodev PMD                                           │
│                                                                             │
│     rte_cryptodev_enqueue_burst(dev_id, qp_id, &crypto_op, 1)              │
│                                                                             │
│     函数指针跳转到具体 PMD:                                                │
│     AESNI-MB PMD → CPU 执行 AES-NI + AVX 指令加密                        │
│     QAT PMD      → 通过 PCIe 发给 QAT 硬件加密                            │
│     OpenSSL PMD  → 调用 OpenSSL 库加密                                    │
│     对应用代码完全透明                                                     │
│                                                                             │
│  ⑤ 取回加密结果                                                           │
│                                                                             │
│     rte_cryptodev_dequeue_burst(dev_id, qp_id, &crypto_op, 1)              │
│                                                                             │
│     mbuf 的 payload 已加密, 但还没有 ESP 头:                               │
│     ┌──────────┬───────────┬─────────────────┐                            │
│     │ Ethernet │    IP     │ 密文 Payload     │                            │
│     └──────────┴───────────┴─────────────────┘                            │
│                                                                             │
│  ⑥ IPsec 后处理: 封装 ESP 头 (IPsec 库自动完成)                           │
│                                                                             │
│     rte_ipsec_pkt_process(session, &mbuf, 1)                               │
│                                                                             │
│     IPsec 库自动做了:                                                      │
│     - 插入 ESP 头 (SPI + 序列号 + IV)                                    │
│     - 添加 outer IP 头 (Tunnel 模式)                                      │
│     - 添加 ESP 尾 (padding + next_proto)                                  │
│     - 添加 ICV (认证标签)                                                  │
│                                                                             │
│     mbuf 变成完整的 ESP 包:                                                │
│     ┌──────────┬──────────┬─────────┬──────────┬─────┬─────┐             │
│     │Outer Eth │Outer IP  │ESP Hdr  │密文 Pay  │ Pad │ ICV │             │
│     └──────────┴──────────┴─────────┴──────────┴─────┴─────┘             │
│                                                                             │
│  ⑦ 发送加密后的包                                                         │
│                                                                             │
│     rte_eth_tx_burst(port, queue, &mbuf, 1)                                │
│     网卡把 ESP 密文包发到线路上                                            │
│                                                                             │
│  路线总结:                                                                 │
│  RX → 查SA → crypto_prepare → enqueue → [加密] → dequeue → pkt_process → TX│
│  ①      ②         ③            ④          ⑤        ⑥          ⑦          │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                  入方向: 收密文 → 查 SA → 解密 → 剥 ESP → 明文            │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ① 收到 ESP 加密包                                                        │
│                                                                             │
│     rte_eth_rx_burst(port, queue, &mbuf, 1)                                │
│                                                                             │
│     mbuf 是密文:                                                            │
│     ┌──────────┬──────────┬─────────┬──────────┬─────┬─────┐             │
│     │Outer Eth │Outer IP  │ESP Hdr  │密文 Pay  │ Pad │ ICV │             │
│     └──────────┴──────────┴─────────┴──────────┴─────┴─────┘             │
│                                                                             │
│  ② 解析 ESP 头, 提取 SPI, 查 SAD 找到 SA                                  │
│                                                                             │
│     从 ESP 头读 SPI → 构造 SAD key                                         │
│     rte_ipsec_sad_lookup(sad, &key, &sa_ptr, 1)                            │
│     sa_ptr → 入方向 SA (含解密密钥)                                        │
│                                                                             │
│  ③ 准备解密操作                                                            │
│                                                                             │
│     rte_ipsec_pkt_crypto_prepare(session, &mbuf, &crypto_op, 1)            │
│     IPsec 库自动: 提取 IV、设置解密范围、准备 ICV 验证                    │
│                                                                             │
│  ④ 提交解密到 Cryptodev PMD                                               │
│     rte_cryptodev_enqueue_burst(dev_id, qp_id, &crypto_op, 1)              │
│                                                                             │
│  ⑤ 取回解密结果                                                           │
│     rte_cryptodev_dequeue_burst(dev_id, qp_id, &crypto_op, 1)              │
│     payload 已解密, 但 ESP 头还在                                          │
│                                                                             │
│  ⑥ IPsec 后处理: 剥离 ESP 头                                             │
│                                                                             │
│     rte_ipsec_pkt_process(session, &mbuf, 1)                               │
│     IPsec 库自动:                                                          │
│     - 移除 outer IP 头 + ESP 头 + ESP 尾                                  │
│     - 恢复原始 IP 头                                                       │
│     - 验证序列号 (防重放)                                                  │
│                                                                             │
│     mbuf 恢复成明文:                                                       │
│     ┌──────────┬───────────┬─────────┐                                     │
│     │ Ethernet │    IP     │ Payload │  ← 明文! 可以交给业务逻辑了        │
│     └──────────┴───────────┴─────────┘                                     │
│                                                                             │
│  ⑦ 业务处理                                                               │
│     process_packet(mbuf)  ← 你的业务代码, 看到的是明文                    │
│                                                                             │
│  路线总结:                                                                 │
│  RX → 查SA → crypto_prepare → enqueue → [解密] → dequeue → pkt_process → 业务│
│  ①      ②         ③            ④          ⑤         ⑥            ⑦       │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

```c
// 出方向代码 (你实际写的)
rte_ipsec_pkt_crypto_prepare(ss, tx_mbufs, ops, n);   // 准备加密参数
rte_cryptodev_enqueue_burst(dev, qp, ops, n);          // 提交加密
rte_cryptodev_dequeue_burst(dev, qp, ops, n);          // 取回结果
rte_ipsec_pkt_process(ss, tx_mbufs, n);                // 封装 ESP 头
rte_eth_tx_burst(port, queue, tx_mbufs, n);            // 发送

// 入方向代码
rte_ipsec_sad_lookup(sad, keys, sa_ptrs, n);           // 查 SA
rte_ipsec_pkt_crypto_prepare(ss, rx_mbufs, ops, n);    // 准备解密参数
rte_cryptodev_enqueue_burst(dev, qp, ops, n);           // 提交解密
rte_cryptodev_dequeue_burst(dev, qp, ops, n);           // 取回结果
rte_ipsec_pkt_process(ss, rx_mbufs, n);                 // 剥离 ESP 头
process_packet(rx_mbufs);                                // 业务处理

// 复杂的细节 (IV 生成、序列号、ESP 头格式、padding、ICV)
// 全部被 rte_ipsec 库封装了, 你不需要手动处理
```

### 6.4 SA 初始化

```c
#include <rte_ipsec.h>
#include <rte_ipsec_sa.h>
#include <rte_ipsec_sad.h>

// 初始化 IPsec SA (Tunnel 模式, ESP, AES-GCM)
struct rte_ipsec_session ipsec_sess;  // 通常作为全局或 per-SA 存储

int
init_ipsec_sa_outbound(uint8_t dev_id, struct rte_mempool *sess_pool)
{
    // 1. 构造 crypto xform
    static struct rte_crypto_sym_xform xform = {
        .next = NULL,
        .type = RTE_CRYPTO_SYM_XFORM_AEAD,
        .aead = {
            .op = RTE_CRYPTO_AEAD_OP_ENCRYPT,
            .algo = RTE_CRYPTO_AEAD_AES_GCM,
            .key = { .data = aes_key, .length = 32 },
            .iv = { .offset = 0, .length = 12 },
            .digest_length = 16,
            .aad_length = 12,
        },
    };

    // 2. 构造 IPsec xform
    struct rte_security_ipsec_xform ipsec_xform = {
        .spi = 0x12345678,
        .salt = 0x11111111,
        .direction = RTE_SECURITY_IPSEC_SA_DIR_EGRESS,
        .proto = RTE_SECURITY_IPSEC_SA_PROTO_ESP,
        .mode = RTE_SECURITY_IPSEC_SA_MODE_TUNNEL,
        .tunnel = {
            .type = RTE_SECURITY_IPSEC_TUNNEL_IPV4,
            .ipv4 = {
                .src_ip = IPv4(10, 0, 0, 1),
                .dst_ip = IPv4(10, 0, 0, 2),
            },
        },
        .options = { .udp_encap = 0, .esn = 0 },
        .replay_win_sz = 64,
    };

    // 3. 构造 SA 参数
    struct rte_ipsec_sa_prm sa_prm = {
        .userdata = 0,
        .flags = RTE_IPSEC_SAFLAG_SQN_ATOM,  // 原子序列号
        .ipsec_xform = ipsec_xform,
        .crypto_xform = &xform,
        .tun = {
            .hdr_len = sizeof(struct rte_ipv4_hdr),
            .hdr_l3_off = 0,
            .next_proto = IPPROTO_IPIP,
            .hdr = &tun_hdr_template,  // 预构建的 tunnel header
        },
    };

    // 4. 计算 SA 对象大小并分配
    int32_t sa_sz = rte_ipsec_sa_size(&sa_prm);
    if (sa_sz <= 0)
        return -1;

    struct rte_ipsec_sa *sa = rte_zmalloc("ipsec_sa", sa_sz,
                                            RTE_CACHE_LINE_SIZE);

    // 5. 初始化 SA
    int32_t rc = rte_ipsec_sa_init(sa, &sa_prm, sa_sz);
    if (rc != sa_sz)
        return -1;

    // 6. 创建 crypto session 并绑定到 ipsec_session
    ipsec_sess.sa = sa;
    ipsec_sess.security.ctx = NULL;  // 不用 security offload
    ipsec_sess.security.ses = NULL;
    ipsec_sess.crypto.dev = dev_id;
    ipsec_sess.crypto qp = 0;
    ipsec_sess.crypto.ses = rte_cryptodev_sym_session_create(
            dev_id, &xform, sess_pool);

    // 7. 准备 session (设置内部函数指针)
    rc = rte_ipsec_session_prepare(&ipsec_sess);
    if (rc != 0)
        return -1;

    return 0;
}
```

### 6.5 SAD (SA Database)

```c
// 创建 SAD
struct rte_ipsec_sad *
create_sad(void)
{
    struct rte_ipsec_sad_conf conf = {
        .socket_id = rte_socket_id(),
        .max_sa = {
            [RTE_IPSEC_SAD_SPI_ONLY] = 1024,
            [RTE_IPSEC_SAD_SPI_DIP] = 0,
            [RTE_IPSEC_SAD_SPI_DIP_SIP] = 0,
        },
        .flags = 0,  // IPv4
    };

    return rte_ipsec_sad_create("ipsec_sad", &conf);
}

// 添加 SA 到 SAD
int
add_sa_to_sad(struct rte_ipsec_sad *sad, uint32_t spi, void *sa)
{
    union rte_ipsec_sad_key key;
    key.v4.spi = rte_cpu_to_be_32(spi);

    return rte_ipsec_sad_add(sad, &key,
                              RTE_IPSEC_SAD_SPI_ONLY, sa);
}

// 查找 SA (批量)
int
lookup_sa(struct rte_ipsec_sad *sad, uint32_t *spis,
           struct rte_ipsec_sa **sa_ptrs, uint16_t n)
{
    union rte_ipsec_sad_key keys[n];

    for (int i = 0; i < n; i++)
        keys[i].v4.spi = rte_cpu_to_be_32(spis[i]);

    return rte_ipsec_sad_lookup(sad, (const union rte_ipsec_sad_key **)&keys,
                                 (void **)sa_ptrs, n);
}
```

### 6.6 完整 IPsec 数据路径

```c
// 出方向: 加密并发送
uint16_t
ipsec_outbound(struct rte_ipsec_session *ss,
               struct rte_mbuf **pkts, uint16_t nb_pkts,
               struct rte_mempool *op_pool)
{
    struct rte_crypto_op *ops[nb_pkts];

    // 1. 分配 crypto ops
    if (rte_crypto_op_bulk_alloc(op_pool,
                                  RTE_CRYPTO_OP_TYPE_SYMMETRIC,
                                  ops, nb_pkts) < nb_pkts)
        return 0;

    // 2. IPsec 库准备加密操作 (填充 IV/序列号/加密范围)
    uint16_t nb_prepared =
        rte_ipsec_pkt_crypto_prepare(ss, pkts, ops, nb_pkts);
    if (nb_prepared == 0) {
        for (int i = 0; i < nb_pkts; i++)
            rte_crypto_op_free(ops[i]);
        return 0;
    }

    // 3. 提交加密
    uint16_t nb_enq = rte_cryptodev_enqueue_burst(
            ss->crypto.dev, ss->crypto qp, ops, nb_prepared);

    // 4. 等待完成
    struct rte_crypto_op *deq_ops[nb_enq];
    uint16_t nb_deq = rte_cryptodev_dequeue_burst(
            ss->crypto.dev, ss->crypto qp, deq_ops, nb_enq);

    // 5. IPsec 后处理 (添加 ESP/IP 头, 更新长度)
    // 注意: pkt_process 需要对应的 mbuf 数组
    struct rte_mbuf *deq_pkts[nb_deq];
    for (int i = 0; i < nb_deq; i++)
        deq_pkts[i] = deq_ops[i]->sym->m_src;

    uint16_t nb_processed = rte_ipsec_pkt_process(ss, deq_pkts, nb_deq);

    // 6. 释放 crypto ops
    for (int i = 0; i < nb_deq; i++)
        rte_crypto_op_free(deq_ops[i]);

    return nb_processed;
}

// 入方向: 接收、查 SAD、解密
uint16_t
ipsec_inbound(struct rte_ipsec_sad *sad,
              struct rte_ipsec_session **sessions,
              struct rte_mbuf **pkts, uint16_t nb_pkts,
              struct rte_mempool *op_pool)
{
    // 1. 从每个包中提取 SPI 并查找 SA
    uint32_t spis[nb_pkts];
    struct rte_ipsec_sa *sa_ptrs[nb_pkts];

    for (int i = 0; i < nb_pkts; i++) {
        struct rte_esp_hdr *esp = rte_pktmbuf_mtod_offset(pkts[i],
                struct rte_esp_hdr *,
                sizeof(struct rte_ether_hdr) + sizeof(struct rte_ipv4_hdr));
        spis[i] = esp->spi;
    }

    int nb_found = rte_ipsec_sad_lookup(sad, NULL,
                                          (void **)sa_ptrs, nb_pkts);

    // 2. 按 SA 分组 (同 SA 的包一起处理)
    // ... 分组逻辑 ...

    // 3. 对每组: crypto_prepare → enqueue → dequeue → pkt_process
    // (与出方向类似)
}
```

---

## 7. 性能优化

### 7.1 批量和异步

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     Crypto 性能优化要点                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  1. 批量提交 (最关键):                                                    │
│  ───────────────────────                                                    │
│  - rte_cryptodev_enqueue_burst 批量越大效率越高                            │
│  - 推荐 burst >= 32                                                        │
│  - 将加密请求攒成一批再提交，减少 MMIO/pipeline 切换                      │
│                                                                             │
│  2. 异步流水线:                                                           │
│  ──────────────                                                            │
│  - 不要等加密完成再做其他事                                                │
│  - RX burst → crypto prepare → enqueue → dequeue → process → TX burst     │
│  - 让加密和包处理重叠                                                      │
│                                                                             │
│  3. In-place 加密:                                                        │
│  ─────────────────                                                         │
│  - op->sym->m_dst = NULL 时，加密在 m_src 上原地完成                      │
│  - 避免 mbuf 拷贝，节省内存带宽                                           │
│                                                                             │
│  4. 多 queue pair:                                                        │
│  ──────────────────                                                        │
│  - 每个 lcore 使用独立的 qp                                                │
│  - 避免 qp 锁竞争                                                         │
│  - QAT 支持 64+ qp，AESNI 支持 1 qp (软件无并发需求)                     │
│                                                                             │
│  5. Session 复用:                                                         │
│  ─────────────────                                                         │
│  - 创建 session 开销大 (涉及密钥调度)                                     │
│  - 预创建所有 SA 对应的 session，数据路径只做 attach                      │
│  - 避免在快速路径中创建/销毁 session                                      │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 7.2 流水线模式

```c
// 生产级异步流水线: RX → 加密 → 处理 → TX
// 多个阶段重叠执行

#define CRYPTO_BURST_SIZE 32

void
crypto_pipeline_main_loop(uint8_t rx_port, uint16_t rx_queue,
                           uint8_t tx_port, uint16_t tx_queue,
                           uint8_t crypto_dev, uint16_t crypto_qp,
                           struct rte_ipsec_session *ss,
                           struct rte_mempool *op_pool)
{
    struct rte_mbuf *rx_pkts[CRYPTO_BURST_SIZE];
    struct rte_crypto_op *crypto_ops[CRYPTO_BURST_SIZE];
    struct rte_crypto_op *completed_ops[CRYPTO_BURST_SIZE];
    struct rte_mbuf *tx_pkts[CRYPTO_BURST_SIZE];

    for (;;) {
        // 阶段 1: 收集已完成的加密结果并发送
        uint16_t nb_completed = rte_cryptodev_dequeue_burst(
                crypto_dev, crypto_qp,
                completed_ops, CRYPTO_BURST_SIZE);

        if (nb_completed > 0) {
            uint16_t nb_tx = 0;
            for (int i = 0; i < nb_completed; i++) {
                if (completed_ops[i]->status ==
                        RTE_CRYPTO_OP_STATUS_SUCCESS) {
                    tx_pkts[nb_tx++] = completed_ops[i]->sym->m_src;
                }
                rte_crypto_op_free(completed_ops[i]);
            }
            // 发送已加密的包
            rte_eth_tx_burst(tx_port, tx_queue, tx_pkts, nb_tx);
        }

        // 阶段 2: 接收新包
        uint16_t nb_rx = rte_eth_rx_burst(rx_port, rx_queue,
                                            rx_pkts, CRYPTO_BURST_SIZE);
        if (nb_rx == 0)
            continue;

        // 阶段 3: 准备加密并提交
        if (rte_crypto_op_bulk_alloc(op_pool,
                                      RTE_CRYPTO_OP_TYPE_SYMMETRIC,
                                      crypto_ops, nb_rx) == nb_rx) {
            rte_ipsec_pkt_crypto_prepare(ss, rx_pkts,
                                          crypto_ops, nb_rx);
            rte_cryptodev_enqueue_burst(crypto_dev, crypto_qp,
                                         crypto_ops, nb_rx);
        }
    }
}
```

---

## 8. 小结

本章核心要点：

1. **三种加速方式**：Inline (NIC 硬件)、Lookaside (协处理器 QAT)、CPU Crypto (SIMD 指令)，各有适用场景。

2. **Cryptodev 框架**：统一 API 管理加密设备，通过 PMD 支持硬件和软件后端。初始化流程：info_get → configure → qp_setup → start。

3. **Session 管理**：DPDK 24.11 使用 `rte_cryptodev_sym_session_create(dev_id, xform, pool)` 一步创建 session，旧的两步 API 已移除。

4. **xform 链**：cipher + auth 通过 `next` 指针链接；AEAD (AES-GCM) 只需单个 xform。

5. **rte_security**：统一安全会话框架，一套 API 覆盖 inline/lookaside/CPU crypto，支持 IPsec/MACsec/PDCP 等协议。

6. **QAT**：Intel PCIe 加速卡，对称加密可达 40-100 Gbps，CPU 占用 <5%，适合大流量加密卸载。

7. **AES-NI PMD**：ipsec_mb 框架下的软件 PMD（crypto_aesni_mb、crypto_aesni_gcm），利用 CPU SIMD 指令，无需额外硬件。

8. **DPDK IPsec 库**：提供 SA 管理（opaque sa + sa_prm 初始化）、SAD 查找（SPI/DIP/SIP）、ESP 处理（crypto_prepare + pkt_process）。

9. **ipsec-secgw 示例**：DPDK 自带的完整 IPsec 安全网关示例，展示了 SP/SA/SAD/路由的集成。

10. **性能优化关键**：批量提交（burst >= 32）、异步流水线（加密与处理重叠）、in-place 加密、多 qp、session 复用。

**下一篇预告**：[[2026-04-09-dpdk-deep-dive-ch31-advanced-topics|第三十一章]]将讲解高级主题——BPF、动态配置、热升级。

---

> [!tip] 参考文献
>
> - DPDK Cryptodev Framework, https://doc.dpdk.org/guides/prog_guide/cryptodev_lib.html
> - DPDK rte_security, https://doc.dpdk.org/guides/prog_guide/rte_security.html
> - DPDK IPsec Library, https://doc.dpdk.org/guides/prog_guide/ipsec_lib.html
> - Intel QAT, https://www.intel.com/content/www/us/en/products/docs/accelerators/quick-assist-technology.html
> - Intel IPsec Multi-Buffer, https://github.com/intel/intel-ipsec-mb
> - DPDK ipsec-secgw Example, https://doc.dpdk.org/guides/sample_app_ug/ipsec_secgw.html
> - DPDK Crypto Performance Application, https://doc.dpdk.org/guides/tools/cryptoperf.html
> - [[2026-05-28-linux-ipsec-offload-practice|Linux IPsec 三种加密卸载模式实战]] — Linux 内核 xfrm 三种模式配置与性能对比
