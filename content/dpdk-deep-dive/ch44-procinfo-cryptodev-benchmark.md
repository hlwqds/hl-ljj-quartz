---
title: "DPDK 深度探索 ch44：procinfo 与 Cryptodev 基准测试"
date: 2026-04-10 17:30:00
tags: [dpdk, procinfo, cryptodev, benchmark, crypto, performance, testpmd]
description: "深入解析 DPDK procinfo、Cryptodev 基准测试：加密性能测试、AES-NI、QAT 性能对比与优化"
---

# DPDK 深度探索 ch44：procinfo 与 Cryptodev 基准测试

> [!abstract] 核心要点
> 加密是 DPDK 安全功能的核心。本章深入解析 procinfo、Cryptodev 基准测试、AES-NI/QAT 性能与加密优化。

## 1. procinfo

### 1.1 概述

```
procinfo — DPDK 进程信息工具：

- 显示 lcore 使用情况
- 显示内存统计
- 显示 port 统计
- 实时监控 DPDK 应用
```

### 1.2 基本使用

```bash
# 查看帮助
dpdk-procinfo --help

# 基本运行
sudo ./build/app/dpdk-procinfo -- -m  # 显示内存
sudo ./build/app/dpdk-procinfo -- -t  # 显示 lcore

# 附加到运行中的进程
sudo dpdk-procinfo -- -p <pid>

# 统计模式
dpdk-procinfo -- --stats

# 显示 port 信息
dpdk-procinfo -- --port-info
```

### 1.3 输出示例

```
# lcore 信息
Lcore 0:  RUNNING    0.00% 0.00%
Lcore 1:  RUNNING    0.00% 0.00%
Lcore 2:  IDLE       0.00% 0.00%
Lcore 3:  IDLE       0.00% 0.00%

# 内存信息
Memory Statistics:
  Heap Size:    256 MB
  Heap Free:    200 MB
  Allocated:    56 MB
  Malloc Count: 1024
```

## 2. Cryptodev

### 2.1 Cryptodev 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    DPDK Cryptodev 架构                      │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              Application                               │  │
│  │  - EVP API / AES-NI                                 │  │
│  │  - Symmetric/Asymmetric                             │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              Cryptodev API                            │  │
│  │  - Session management                               │  │
│  │  - Operation pool                                   │  │
│  │  - Driver dispatch                                  │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐                │
│  │ AESNI-MB │  │   QAT    │  │  DPAA2   │                │
│  │  (SW)    │  │  (HW)    │  │  (HW)    │                │
│  └──────────┘  └──────────┘  └──────────┘                │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 设备发现

```c
#include <rte_cryptodev.h>

// 初始化 cryptodev
int
init_cryptodev(void)
{
    // 初始化
    rte_cryptodev_init(NULL);

    // 获取设备数量
    uint8_t nb_devs = rte_cryptodev_count();
    printf("Cryptodev devices: %u\n", nb_devs);

    // 获取设备信息
    struct rte_cryptodev_info info;
    for (uint8_t i = 0; i < nb_devs; i++) {
        rte_cryptodev_info_get(i, &info);
        printf("Dev %u: %s\n", i, info.device->name);
        printf("  Driver: %s\n", info.driver_name);
        printf("  Sym: %s\n",
            info.capabilities[RTE_CRYPTO_SYM] ? "Yes" : "No");
    }

    return 0;
}
```

### 2.3 设备配置

```c
// 配置 cryptodev
int
configure_cryptodev(uint8_t dev_id)
{
    struct rte_cryptodev_config conf = {
        .nb_queue_pairs = 4,
        .socket_id = 0,
        .session_mp = {
            .nb_objs = 1024,
            .cache_size = 64,
        },
    };

    // 配置设备
    int ret = rte_cryptodev_configure(dev_id, &conf);
    if (ret < 0) {
        printf("Config failed\n");
        return -1;
    }

    // 启动设备
    ret = rte_cryptodev_start(dev_id);
    if (ret < 0) {
        printf("Start failed\n");
        return -1;
    }

    return 0;
}
```

## 3. Cryptodev 测试

### 3.1 test-cryptodev

```bash
# 运行所有测试
sudo ./build/app/test-cryptodev

# 运行特定测试套件
sudo ./build/app/test-cryptodev -n 4 -l 0-3 \
    --testsuite=AESNI_MB

# 运行特定用例
sudo ./build/app/test-cryptodev -n 4 -l 0-3 \
    --testcase=GCM

# 查看帮助
./build/app/test-cryptodev --help
```

### 3.2 性能测试

```bash
# 测试套件
# 1. AESNI_MB - Intel AES-NI Multi-buffer
# 2. AESNI_GCM - AES-NI GCM
# 3. QAT - QuickAssist Technology
# 4. DPAA2_SEC - NXP DPAA2

# 运行性能测试
./build/app/test-cryptodev -n 4 -l 0-3 \
    --perf

# 输出示例:
# Test: AES-128-CBC
#   Op/ms: 1000000
#   Throughput: 5.2 GB/s
#   Latency: 0.2 us
```

### 3.3 测试用例

```c
// 测试 AES-CBC
static int
test_aes_cbc(void)
{
    // 参数
    struct crypto_params {
        uint8_t cipher_algo;   // AES-CBC
        uint8_t key_len;       // 16/24/32
        uint8_t iv_len;       // 16
        uint8_t block_size;   // 16
    };

    struct rte_crypto_op *op;
    struct rte_crypto_sym_op *sym_op;

    // 分配操作
    op = rte_crypto_op_alloc(op_pool,
        RTE_CRYPTO_OP_TYPE_SYMMETRIC);

    // 设置参数
    sym_op = op->sym;
    sym_op->cipher.algo = RTE_CRYPTO_CIPHER_AES_CBC;
    sym_op->cipher.op = RTE_CRYPTO_CIPHER_OP_ENCRYPT;

    // 执行
    rte_cryptodev_enqueue_burst(dev_id, 0, &op, 1);

    return 0;
}
```

## 4. 加密基准测试

### 4.1 Benchmark 脚本

```python
#!/usr/bin/env python3
"""Crypto Benchmark Script"""

import subprocess
import json

class CryptoBenchmark:
    def __init__(self):
        self.results = []

    def run_test(self, algo, key_size, batch_size):
        """运行单个测试"""
        cmd = [
            "./build/app/test-cryptodev",
            "--algo", algo,
            "--key-size", str(key_size),
            "--batch", str(batch_size),
            "--iters", "10000"
        ]

        result = subprocess.run(cmd,
                              capture_output=True,
                              text=True)
        return self.parse_output(result.stdout)

    def parse_output(self, output):
        """解析输出"""
        data = {}
        for line in output.split('\n'):
            if 'Throughput' in line:
                data['throughput'] = float(
                    line.split(':')[1].strip().split()[0])
            elif 'Latency' in line:
                data['latency'] = float(
                    line.split(':')[1].strip().split()[0])
        return data

    def run_all(self):
        """运行所有测试"""
        algos = ['AES-CBC', 'AES-GCM', 'CHACHA20-POLY1305']
        key_sizes = [128, 192, 256]

        for algo in algos:
            for key_size in key_sizes:
                result = self.run_test(algo, key_size, 32)
                self.results.append({
                    'algo': algo,
                    'key_size': key_size,
                    **result
                })

        self.print_results()

    def print_results(self):
        """打印结果"""
        print("Crypto Performance Results")
        print("=" * 80)
        for r in self.results:
            print(f"{r['algo']}-{r['key_size']}: "
                  f"{r['throughput']:.2f} GB/s, "
                  f"{r['latency']:.2f} μs")
```

## 5. AES-NI

### 5.1 AES-NI 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    Intel AES-NI                           │
│                                                              │
│  指令集:                                                    │
│  - AESENC: 一轮 AES 加密                                   │
│  - AESENCLAST: 最后一轮                                   │
│  - AESDEC: 一轮 AES 解密                                   │
│  - AESDECLAST: 最后一轮解密                                │
│  - AESKEYGENASSIST: 密钥扩展                               │
│  - AESIMC: 密钥准备 (解密)                                │
│                                                              │
│  性能:                                                     │
│  - AES-128: ~10 cycles/byte                              │
│  - AES-256: ~15 cycles/byte                              │
│  - GCM: ~4-6 cycles/byte                                │
└─────────────────────────────────────────────────────────────┘
```

### 5.2 AES-NI PMD

```c
// 使用 AESNI-MB 驱动
#include <rte_cryptodev.h>

int
use_aesni_mb(uint8_t dev_id)
{
    // 检查驱动
    struct rte_cryptodev_info info;
    rte_cryptodev_info_get(dev_id, &info);

    if (strcmp(info.driver_name, "crypto_aesni_mb") != 0) {
        printf("Not AESNI-MB driver\n");
        return -1;
    }

    return 0;
}
```

## 6. QAT

### 6.1 QAT 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    Intel QAT                               │
│                                                              │
│  QAT Device:                                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  QAT Hardware (PCIe Adapter)                          │  │
│  │                                                       │  │
│  │  - Symmetric Crypto                                  │  │
│  │  - Asymmetric Crypto (RSA, DH, ECC)                │  │
│  │  - Compression                                      │  │
│  │  - SHA3                                              │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│  QAT Driver:                                               │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Intel QuickAssist Technology Driver                │  │
│  │                                                       │  │
│  │  - ADF (Accelerated Data Path)                      │  │
│  │  - ICP API                                          │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 6.2 QAT 配置

```bash
# 检查 QAT 设备
lspci | grep -i quick

# 加载 QAT 驱动
modprobe intel_qat
ls -la /dev/vfio/*

# 配置
cat /sys/class/uio/uio0/device/config
```

### 6.3 QAT 性能

```
QAT vs AES-NI (Software):

| Algorithm | QAT | AESNI-MB | Speedup |
|-----------|-----|----------|---------|
| AES-128-CBC | 40 Gbps | 10 Gbps | 4x |
| AES-256-GCM | 35 Gbps | 8 Gbps | 4x |
| AES-128-GCM | 45 Gbps | 12 Gbps | 3.7x |
| ZUC-EEA3 | 30 Gbps | 5 Gbps | 6x |
```

## 7. 性能对比

### 7.1 对比表

```
Cryptodev Performance (Cipher):

┌─────────────────────────────────────────────────────────────┐
│                    吞吐量对比 (32-byte bursts)              │
│                                                              │
│  Algorithm     │ AESNI-MB  │   QAT   │ OpenSSL  │           │
│  ──────────────┼───────────┼─────────┼──────────┼──────────│
│  AES-128-CBC  │  10 GB/s  │ 40 GB/s │  3 GB/s  │          │
│  AES-256-CBC  │   8 GB/s  │ 35 GB/s │  2 GB/s  │          │
│  AES-128-GCM  │  12 GB/s  │ 45 GB/s │  4 GB/s  │          │
│  AES-256-GCM  │   8 GB/s  │ 40 GB/s │  3 GB/s  │          │
│  ChaCha20-Poly│   5 GB/s  │  N/A    │  4 GB/s  │          │
└─────────────────────────────────────────────────────────────┘

Cryptodev Performance (Hash):

┌─────────────────────────────────────────────────────────────┐
│                    吞吐量对比                               │
│                                                              │
│  Algorithm     │ AESNI-MB  │   QAT   │ OpenSSL  │           │
│  ──────────────┼───────────┼─────────┼──────────┼──────────│
│  SHA-256       │  15 GB/s  │ 30 GB/s │  2 GB/s  │          │
│  SHA-512       │  10 GB/s  │ 25 GB/s │  1 GB/s  │          │
│  MD5           │  20 GB/s  │ 35 GB/s │  3 GB/s  │          │
│  AES-CMAC      │  12 GB/s  │ 40 GB/s │  4 GB/s  │          │
└─────────────────────────────────────────────────────────────┘
```

### 7.2 选择指南

```
加密驱动选择：

┌─────────────────────────────────────────────────────────────┐
│                    选择指南                                 │
│                                                              │
│  1. QAT (优先)                                             │
│     - 高吞吐量需求                                         │
│     - 静态加密 (有线速)                                   │
│     - IPsec/TLS 卸载                                       │
│                                                              │
│  2. AESNI-MB                                               │
│     - 中等吞吐量                                           │
│     - 灵活 (多算法)                                       │
│     - 无需额外硬件                                         │
│                                                              │
│  3. OpenSSL Engine                                         │
│     - 已有 OpenSSL 应用                                    │
│     - 简单集成                                             │
│     - 性能要求不高                                         │
└─────────────────────────────────────────────────────────────┘
```

## 8. 总结

Cryptodev 性能优化：

```
优化层次：

1. 硬件选择
   QAT > AESNI-MB > OpenSSL

2. 配置优化
   - 批量操作 (burst)
   - Session 复用
   - 异步操作

3. 算法选择
   - AES-GCM (认证加密)
   - CHACHA20-POLY1305 (移动端)

4. 部署
   - 专用 cryptodev lcore
   - RSS 分散到多个 queue
```

性能收益：

| 优化项           | 收益     | 成本   |
| ---------------- | -------- | ------ |
| **QAT vs AESNI** | 3-4x     | $2000+ |
| **Burst 32**     | 2-3x     | 无     |
| **Session 复用** | 50%      | 无     |
| **GCM 模式**     | 集成认证 | 无     |

---

## 参考资源

- [DPDK Cryptodev](https://doc.dpdk.org/guides/cryptodevs/)
- [Intel QAT](https://www.intel.com/content/www/us/en/developer/articles/technical/quickassist-technology.html)
- [AES-NI](https://www.intel.com/content/www/us/en/architecture-and-technology/advanced-encryption-standard-aes/data-protection-aes-general.html)
