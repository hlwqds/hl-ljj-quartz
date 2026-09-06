---
title: "DPDK 深度探索 (二十)：AVX512/SIMD 数据包处理向量化"
date: 2026-04-09
tags: [dpdk, series, simd, avx512, sse, neon, vectorization, packet-processing, performance]
description: "深入理解 SIMD 向量化在 DPDK 中的应用——AVX512/SSE/NEON 指令集、数据包批量处理、校验和计算、查找表、RSS 散列向量化"
---

> [!info] DPDK 深度探索系列 0. [[dpdk-deep-dive|全栈学习路径总览]]
> 1-19. 前十九章已完成
> 19b. [[ch19b-dpu-smartnic|第十九章补充：DPU/SmartNIC 基础]] 20. **第二十章：AVX512/SIMD 数据包处理向量化**

---

## 1. 概述：为什么需要 SIMD？

### 1.1 标量 vs 向量处理

传统标量处理每条指令处理一个数据，而 SIMD (Single Instruction Multiple Data) 能用一条指令处理多个数据：

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        标量 vs SIMD 处理                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  标量处理 (SISD):                                                          │
│  ──────────────────                                                        │
│                                                                             │
│  数据: [D0] [D1] [D2] [D3] [D4] [D5] [D6] [D7]                            │
│         │     │     │     │     │     │     │     │                        │
│         ▼     ▼     ▼     ▼     ▼     ▼     ▼     ▼                        │
│  ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐ │
│  │ ADD  │ │ ADD  │ │ ADD  │ │ ADD  │ │ ADD  │ │ ADD  │ │ ADD  │ │ ADD  │ │
│  └──┬───┘ └──┬───┘ └──┬───┘ └──┬───┘ └──┬───┘ └──┬───┘ └──┬───┘ └──┬───┘ │
│     │        │        │        │        │        │        │        │         │
│     ▼        ▼        ▼        ▼        ▼        ▼        ▼        ▼         │
│  [R0]    [R1]    [R2]    [R3]    [R4]    [R5]    [R6]    [R7]        │
│                                                                             │
│  8 个周期完成 8 个操作 (1 op/cycle)                                         │
│                                                                             │
│  SIMD 处理 (AVX512 64字节 = 512位):                                        │
│  ──────────────────────────────────────                                    │
│                                                                             │
│  数据: [D0][D1][D2][D3][D4][D5][D6][D7] (64 字节, 16 个 32-bit 数据)      │
│         └──────────┬──────────┘                                            │
│                      │                                                      │
│                      ▼                                                      │
│  ┌──────────────────────────────────────────┐                              │
│  │           VPADDD (向量化加法)            │                              │
│  │      (一条指令同时加 16 个 32-bit 数据)   │                              │
│  └──────────────────┬───────────────────────┘                              │
│                     │                                                       │
│                     ▼                                                       │
│         [R0][R1][R2][R3][R4][R5][R6][R7]                                    │
│                                                                             │
│  吞吐: 每 2 周期可发出一条 512-bit 加法 (Skylake-X)                         │
│  延迟: 4 周期得到结果                                                       │
│  → 单条指令完成 16 个加法，吞吐量 8 ops/cycle                               │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘

> [!note] 延迟 vs 吞吐
> SIMD 不意味着"1 周期完成"。AVX512 加法在 Skylake-X 上延迟 4 周期，但吞吐 2 ops/cycle。
> 也就是说流水线满载时，每周期"产出" 16 个加法结果，但单个结果要等 4 周期。
> 对于包处理（批量处理成百上千个包），吞吐量才是关键。
```

### 1.2 SIMD 在 DPDK 中的应用

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        DPDK SIMD 应用场景                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐  │
│  │                     数据包处理                                      │  │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐             │  │
│  │  │ checksum│  │  parse   │  │   RSS   │  │ encrypt │             │  │
│  │  │ 计算    │  │  解析    │  │  散列    │  │ 解密    │             │  │
│  │  └─────────┘  └─────────┘  └─────────┘  └─────────┘             │  │
│  │       │            │            │            │                   │  │
│  │       ▼            ▼            ▼            ▼                   │  │
│  │  ┌─────────────────────────────────────────────────────────┐     │  │
│  │  │              批量处理 (每批次 16-32 个包)                 │     │  │
│  │  │                                                          │     │  │
│  │  │   包1 │ 包2 │ 包3 │ 包4 │ ... │ 包16                   │     │  │
│  │  │   └───┘ └───┘ └───┘ └───┘     └───┘                     │     │  │
│  │  │                   ▼                                      │     │  │
│  │  │        ┌─────────────────────┐                          │     │  │
│  │  │        │   SIMD 向量化处理    │                          │     │  │
│  │  │        │  (AVX512/SSE/NEON) │                          │     │  │
│  │  │        └──────────┬──────────┘                          │     │  │
│  │  │                   │                                     │     │  │
│  │  │   结果1│结果2│结果3│结果4│...│结果16                    │     │  │
│  │  └─────────────────────────────────────────────────────────┘     │  │
│  │                                                                     │  │
│  └─────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
│  常见向量化操作:                                                           │
│  - 校验和: CRC32, IP/TCP/UDP checksum                                     │
│  - 查找: 5-tuple 哈希, ACL 规则匹配                                       │
│  - 解析: IP 头解析, TCP 标志检测                                           │
│  - 加密: AES-CBC/GCM, CRC32                                              │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 1.3 SIMD 指令集发展

| 指令集       | 位宽                | 数据类型         | 典型应用           |
| ------------ | ------------------- | ---------------- | ------------------ |
| **MMX**      | 64-bit              | 整数             | 早期多媒体         |
| **SSE**      | 128-bit             | 单精度浮点、整数 | 包处理 (x86)       |
| **SSE2/3/4** | 128-bit             | 扩展类型         | 校验和、CRC32 指令 |
| **AVX**      | 256-bit             | 浮点             | 浮点计算           |
| **AVX2**     | 256-bit             | 整数+浮点        | 包处理、查找       |
| **AVX-512**  | 512-bit             | 全部类型 + mask  | 高性能包处理       |
| **NEON**     | 128-bit             | ARM 向量         | ARM 包处理         |
| **SVE/SVE2** | 可变 (128-2048-bit) | ARM 向量         | HPC、网络          |

---

## 2. AVX512 指令集详解

### 2.1 AVX512 架构

```c
// AVX512 提供 32 个 512-bit ZMM 寄存器 (ZMM0-ZMM31)
// 以及 8 个 mask 寄存器 (K0-K7)

/*
 * AVX512 寄存器模型:
 *
 *  ZMM0 (511:0) ── 512-bit (AVX-512)
 *  ├─ YMM0 (255:0) ── 256-bit (AVX/AVX2)
 *  │   └─ XMM0 (127:0) ── 128-bit (SSE)
 *  │
 *  注意: XMM/YMM 是 ZMM 的子集，操作低位会自动清零高位
 */

// 向量整数类型
__m512i v0;  // 512-bit = 64 x int8_t 或 32 x int16_t 或 16 x int32_t 或 8 x int64_t

// 向量浮点类型
__m512  v0;  // 512-bit = 16 x float
__m512d v0;  // 512-bit = 8 x double

// 向量掩码类型 (k 寄存器)
__mmask8  k0;  // 8-bit mask  (用于 8 个 64-bit 元素)
__mmask16 k1;  // 16-bit mask (用于 16 个 32-bit 元素)
__mmask32 k2;  // 32-bit mask (用于 32 个 16-bit 元素)
__mmask64 k3;  // 64-bit mask (用于 64 个 8-bit 元素)
```

> [!note] `_mm512_set_epi32` 参数逆序
> Intel intrinsic 中所有 `set` 函数的参数都是**逆序**的：第一个参数是最高位元素（element 15），最后一个参数是最低位元素（element 0）。例如：
>
> ```c
> __m512i v = _mm512_set_epi32(15, 14, 13, ..., 1, 0);
> // element[0] = 0, element[1] = 1, ..., element[15] = 15
> ```

### 2.2 AVX512 基本运算

```c
#include <immintrin.h>

void
simd_examples(void)
{
    // ─────────────────────────────────────────────────────────────────
    // 1. 加载和存储 (Load/Store)
    // ─────────────────────────────────────────────────────────────────

    // 未对齐加载 512 位 (64 字节) — 包处理最常用
    __m512i v1 = _mm512_loadu_si512((const void *)ptr);

    // 对齐加载 (要求地址 64 字节对齐，更快)
    __m512i v2 = _mm512_load_si512((const __m512i *)aligned_ptr);

    // 存储 (未对齐)
    _mm512_storeu_si512((void *)ptr, v1);

    // ─────────────────────────────────────────────────────────────────
    // 2. 算术运算
    // ─────────────────────────────────────────────────────────────────

    // 广播: 所有元素设为同一值
    __m512i a = _mm512_set1_epi32(1);    // 16 个 32-bit 整数全为 1

    // 逐元素加法 (16 个 32-bit 整数同时加)
    __m512i b = _mm512_add_epi32(a, a);
    // b 中每个元素都是 2

    // 16 位整数加法 (32 个 16-bit 整数)
    __m512i c = _mm512_set1_epi16(100);
    __m512i d = _mm512_add_epi16(c, c);
    // d 中每个元素都是 200

    // 字节加法 (64 个 8-bit 整数)
    __m512i e = _mm512_set1_epi8(1);
    __m512i f = _mm512_add_epi8(e, e);

    // 浮点乘法 (16 个 float 同时乘)
    __m512 g = _mm512_set1_ps(2.0f);
    __m512 h = _mm512_mul_ps(g, g);
    // h 中每个元素都是 4.0f

    // ─────────────────────────────────────────────────────────────────
    // 3. 比较运算 (返回 mask，不是向量)
    // ─────────────────────────────────────────────────────────────────

    // 32-bit 整数比较: element[i] > 50 ?
    __m512i x = _mm512_set_epi32(80, 70, 60, 50, 40, 30, 20, 10,
                                  90, 85, 75, 65, 55, 45, 35, 25);
    // 注意: set_epi32 逆序! element[0]=25, element[15]=80

    __mmask16 cmp = _mm512_cmpgt_epi32_mask(x, _mm512_set1_epi32(50));
    // element[0]=25 ≤ 50 → bit 0 = 0
    // element[1]=35 ≤ 50 → bit 1 = 0
    // element[2]=45 ≤ 50 → bit 2 = 0
    // element[3]=55 > 50 → bit 3 = 1
    // element[4]=65 > 50 → bit 4 = 1
    // ... (element 5-14 都 > 50)
    // element[15]=80 > 50 → bit 15 = 1
    // cmp = 0b1111111111111000 (bit 3-15 置位，共 13 个 > 50)

    // 浮点比较
    __mmask16 fp_cmp = _mm512_cmp_ps_mask(g, _mm512_set1_ps(3.0f),
                                           _MM_CMPINT_GT);
    // g 中每个元素是 4.0f > 3.0f → 所有 bit 都置位

    // ─────────────────────────────────────────────────────────────────
    // 4. 逻辑运算
    // ─────────────────────────────────────────────────────────────────

    __m512i and_result = _mm512_and_si512(v1, v2);   // 按位与
    __m512i or_result  = _mm512_or_si512(v1, v2);    // 按位或
    __m512i xor_result = _mm512_xor_si512(v1, v2);   // 按位异或

    // ─────────────────────────────────────────────────────────────────
    // 5. Mask 操作 (AVX512 独有)
    // ─────────────────────────────────────────────────────────────────

    // 统计 mask 中置位的数量
    int count = _mm_popcnt_u32(cmp);

    // 根据 mask 选择元素: mask[i]=1 时取 a[i], 否则取 b[i]
    __m512i selected = _mm512_mask_blend_epi32(cmp, a, b);

    // 根据 mask 压缩: 只保留 mask[i]=1 的元素，紧凑排列
    __m512i compressed = _mm512_maskz_compress_epi32(cmp, a);
}
```

### 2.3 AVX512BW 字节/字操作

```c
// AVX512BW (Byte/Word) 扩展 — 包处理最常用的子集

// 字节比较 (64 个 8-bit 元素)
__mmask64 byte_cmp = _mm512_cmpgt_epi8_mask(v1, v2);

// 字节饱和加法 (溢出不回绕，停在最大值 — 用于 checksum)
__m512i sat_add = _mm512_adds_epu16(a, b);  // uint16 饱和到 65535

// 16-bit 打包为 8-bit
__m512i packed = _mm512_packs_epi16(v16_a, v16_b);

// 字节混洗 (按索引表重排字节 — 包头解析利器)
__m512i shuffled = _mm512_shuffle_epi8(v, shuffle_mask);

// CRC32 指令 (SSE4.2 提供，非 AVX512)
uint32_t crc = _mm_crc32_u8(crc_init, byte_val);
uint32_t crc = _mm_crc32_u32(crc_init, word_val);
uint64_t crc = _mm_crc32_u64(crc_init, dword_val);
```

---

## 3. DPDK SIMD 框架

### 3.1 rte_vect 库

```c
// DPDK 中的实际路径 (以 24.11 为例):
//   x86:   lib/eal/x86/include/rte_vect.h
//   ARM:   lib/eal/arm/include/rte_vect.h
//   通用:  lib/eal/include/generic/rte_vect.h

// 跨平台向量类型抽象
#if defined(RTE_ARCH_X86)
    #if defined(__AVX512F__)
    typedef __m512i  rte_zmm_t;   // 512-bit
    #endif
    #if defined(__AVX2__)
    typedef __m256i  rte_ymm_t;   // 256-bit
    #endif
    typedef __m128i  rte_xmm_t;   // 128-bit (SSE)
#endif

#if defined(RTE_ARCH_ARM)
    typedef uint8x16_t  rte_xmm_t;  // 128-bit NEON
#endif

// CPU 特性检测 (运行时)
// 检查 CPU 是否支持某个特性标志
if (rte_cpu_get_flag_enabled(RTE_CPUFLAG_AVX512F))
    printf("CPU supports AVX512F\n");
if (rte_cpu_get_flag_enabled(RTE_CPUFLAG_SSE4_2))
    printf("CPU supports SSE4.2\n");

// 可用的标志枚举 (定义在 lib/eal/include/rte_cpuflags.h):
// RTE_CPUFLAG_SSE, RTE_CPUFLAG_SSE2, RTE_CPUFLAG_AVX, RTE_CPUFLAG_AVX2,
// RTE_CPUFLAG_AVX512F, RTE_CPUFLAG_AVX512BW, RTE_CPUFLAG_AVX512DQ, ...
```

### 3.2 DPDK 中的 SIMD 实际用法

DPDK **没有**专门的"批量 mbuf 结构体"或"VECT_FOR_EACH_PROCESS 宏"。实际的 SIMD 向量化分散在各个模块中，以下是真实用法：

```c
// DPDK 实际的向量化模式: 直接在收发循环中用 SIMD 处理 mbuf 数组

// 例 1: rte_hash 中用 SIMD 加速批量查找 (lib/hash/rte_hash.h)
// 例 2: rte_acl 中用 AVX512 做 ACL 规则匹配 (lib/acl/)
// 例 3: net/i40e 中用 SSE 做 RX 校验和验证 (drivers/net/i40e/i40e_rxtx.c)
// 例 4: lib/net/rte_ip.h 中用 SIMD 做 IPv4 头部校验和

// DPDK 中的条件编译模式:
// 同一份代码，编译时根据目标 CPU 选择不同的实现

#if defined(__AVX512F__)
    // AVX512 路径
    static inline uint16_t
    process_bulk_avx512(struct rte_mbuf **pkts, uint16_t n)
    {
        uint16_t i;
        for (i = 0; i + 8 <= n; i += 8) {
            __m512i data = _mm512_loadu_si512(...);
            // 向量化处理 8 个包
        }
        // 尾部标量处理
        for (; i < n; i++) { ... }
    }
    #define process_bulk process_bulk_avx512
#elif defined(__AVX2__)
    // AVX2 路径
    #define process_bulk process_bulk_avx2
#elif defined(__SSE4_2__)
    // SSE 路径
    #define process_bulk process_bulk_sse
#else
    // 标量回退
    #define process_bulk process_bulk_scalar
#endif
```

### 3.3 编译配置

```bash
# DPDK meson.build 中配置 SIMD 优化
# DPDK 默认为构建机器编译 (-march=native)
# 交叉编译时需要指定目标架构

# 查看 DPDK 编译时启用了哪些 SIMD 特性
meson configure build/ | grep machine

# 强制指定目标架构 (例如部署到不同 CPU)
meson setup build/ -Dmachine=haswell    # AVX2
meson setup build/ -Dmachine=icelake    # AVX512

# GCC/Clang 编译选项
# -msse4.2    : SSE4.2 (CRC32 指令)
# -mavx2      : AVX2 (256-bit 整数)
# -mavx512f   : AVX512 基础 (512-bit 浮点+整数)
# -mavx512bw  : AVX512 字节/字操作 (包处理关键!)
# -mavx512dq  : AVX512 双字/四字操作
```

---

## 4. 校验和计算向量化

### 4.1 IP/TCP/UDP Checksum

```c
// 校验和计算: 16-bit 反码求和
// 原理: 将数据按 16-bit 为单位求和，溢出部分回卷，最后取反

// 标量版本 (正确但慢)
static uint16_t
csum_scalar(const void *data, size_t len)
{
    uint32_t sum = 0;
    const uint16_t *p = data;

    while (len > 1) {
        sum += *p++;
        len -= 2;
    }

    if (len)
        sum += *(const uint8_t *)p;

    // 回卷: 将高 16 位加回低 16 位
    while (sum >> 16)
        sum = (sum & 0xFFFF) + (sum >> 16);

    return ~sum;
}

// AVX512 向量化版本
static uint16_t
csum_avx512(const void *data, size_t len)
{
    __m512i sum_vec = _mm512_setzero_si512();
    const uint8_t *ptr = (const uint8_t *)data;

    // 主循环: 每次 64 字节 (32 个 16-bit 值)
    while (len >= 64) {
        __m512i v = _mm512_loadu_si512((const void *)ptr);

        // 将 64 字节看作 32 个 16-bit 值，展开到 32 个 32-bit 槽位
        // 高 16 位 → 低半部分，低 16 位 → 高半部分
        __m512i lo = _mm512_and_si512(v, _mm512_set1_epi32(0xFFFF));
        __m512i hi = _mm512_srli_epi32(v, 16);
        sum_vec = _mm512_add_epi32(sum_vec, _mm512_add_epi32(lo, hi));

        ptr += 64;
        len -= 64;
    }

    // 处理剩余 32 字节
    if (len >= 32) {
        __m256i v = _mm256_loadu_si256((const void *)ptr);
        __m256i lo = _mm256_and_si256(v, _mm256_set1_epi32(0xFFFF));
        __m256i hi = _mm256_srli_epi32(v, 16);
        __m256i sum256 = _mm256_add_epi32(lo, hi);
        // 扩展到 512-bit 再加
        sum_vec = _mm512_add_epi32(sum_vec,
                    _mm512_zextsi256_si512(sum256));
        ptr += 32;
        len -= 32;
    }

    // 水平归约: 将 16 个 32-bit 累加为一个值
    uint32_t sum = _mm512_reduce_add_epi32(sum_vec);

    // 处理剩余字节 (标量)
    while (len > 1) {
        sum += *(const uint16_t *)ptr;
        ptr += 2;
        len -= 2;
    }
    if (len)
        sum += *ptr;

    // 回卷 + 取反
    sum = (sum & 0xFFFF) + (sum >> 16);
    sum = (sum & 0xFFFF) + (sum >> 16);
    return ~sum;
}
```

### 4.2 CRC32 计算

```c
// CRC32-C (Castagnoli) — 用于 iSCSI、SCTP、NVMe 等
// 使用 SSE4.2 的 CRC32 硬件指令 (一条指令处理 8 字节)

#include <smmintrin.h>

// 单字节 CRC
static inline uint32_t
crc32c_u8(uint32_t crc, uint8_t byte)
{
    return _mm_crc32_u8(crc, byte);
}

// 4 字节 CRC
static inline uint32_t
crc32c_u32(uint32_t crc, uint32_t value)
{
    return _mm_crc32_u32(crc, value);
}

// 8 字节 CRC
static inline uint64_t
crc32c_u64(uint64_t crc, uint64_t value)
{
    return _mm_crc32_u64(crc, value);
}

// 完整数据包的 CRC32 (处理 mbuf 链)
static inline uint32_t
crc32c_pkt(const struct rte_mbuf *m, uint32_t crc_init)
{
    uint32_t crc = crc_init;

    // 处理每个 segment
    for (const struct rte_mbuf *seg = m; seg != NULL; seg = seg->next) {
        const uint8_t *data = rte_pktmbuf_mtod(seg, const uint8_t *);
        uint32_t seg_len = seg->data_len;
        const uint8_t *end = data + seg_len;

        // 对齐到 8 字节边界
        while (data < end && ((uintptr_t)data & 7)) {
            crc = _mm_crc32_u8(crc, *data++);
        }

        // 主循环: 每次 8 字节
        for (; data + 8 <= end; data += 8) {
            crc = _mm_crc32_u64(crc, *(const uint64_t *)data);
        }

        // 尾部
        while (data < end) {
            crc = _mm_crc32_u8(crc, *data++);
        }
    }

    return crc;
}
```

---

## 5. 查找表向量化

### 5.1 5-Tuple 哈希计算

```c
// 5-tuple: SIP(32) + DIP(32) + SP(16) + DP(16) + Protocol(8)
// 用于流分类、RSS 等场景

// 标量 5-tuple 哈希 (简单的 XOR + 乘法)
static inline uint32_t
hash_5tuple_scalar(uint32_t sip, uint32_t dip,
                   uint16_t sp, uint16_t dp, uint8_t proto)
{
    uint32_t h = sip;
    h ^= dip;
    h ^= ((uint32_t)sp << 16) | dp;
    h ^= proto;
    // 乘以黄金比例常数，混合高位和低位
    h *= 0x9E3779B9;
    h ^= h >> 16;
    return h;
}

// AVX512 批量 5-tuple 哈希 (16 个包一组)
// 前提: 已经将 16 个包的 5-tuple 提取到向量寄存器中
static void
hash_5tuple_batch_avx512(__m512i sip_vec,    // 16 x 32-bit SIP
                          __m512i dip_vec,    // 16 x 32-bit DIP
                          __m512i ports_vec,  // 16 x 32-bit (SP<<16|DP)
                          __m512i proto_vec,  // 16 x 32-bit (proto in low byte)
                          uint32_t *results)   // 输出: 16 个哈希值
{
    __m512i h = _mm512_xor_si512(sip_vec, dip_vec);
    h = _mm512_xor_si512(h, ports_vec);
    h = _mm512_xor_si512(h, proto_vec);
    h = _mm512_mullo_epi32(h, _mm512_set1_epi32(0x9E3779B9));
    h = _mm512_xor_si512(h, _mm512_srli_epi32(h, 16));

    // 存储结果
    _mm512_storeu_si512((__m512i *)results, h);
}

// 从 mbuf 数组中提取 5-tuple 并批量计算哈希
static void
hash_mbuf_batch(struct rte_mbuf **pkts, uint16_t nb_pkts,
                uint32_t *hashes)
{
    uint16_t i = 0;

    // 每 16 个包一组用 AVX512 处理
    for (; i + 16 <= nb_pkts; i += 16) {
        __m512i sip, dip, ports, proto;
        // 从 16 个 mbuf 的包头中 gather 5-tuple
        // (实际代码用 _mm512_i32gather_epi32 按 offset 从各包数据中取)
        // 这里省略 gather 细节，假设已提取完成

        hash_5tuple_batch_avx512(sip, dip, ports, proto, hashes + i);
    }

    // 尾部标量处理
    for (; i < nb_pkts; i++) {
        const uint8_t *pkt = rte_pktmbuf_mtod(pkts[i], const uint8_t *);
        // 跳过以太网头 (14 字节)
        const uint8_t *ip = pkt + 14;
        uint32_t sip = rte_be_to_cpu_32(*(const uint32_t *)(ip + 12));
        uint32_t dip = rte_be_to_cpu_32(*(const uint32_t *)(ip + 16));
        uint16_t sp = rte_be_to_cpu_16(*(const uint16_t *)(ip + 20));
        uint16_t dp = rte_be_to_cpu_16(*(const uint16_t *)(ip + 22));
        uint8_t  proto = ip[9];
        hashes[i] = hash_5tuple_scalar(sip, dip, sp, dp, proto);
    }
}
```

### 5.2 ACL 范围匹配

```c
// ACL (Access Control List) 规则匹配
// 每条规则是 5-tuple 的范围: SIP ∈ [lo, hi], DIP ∈ [lo, hi], etc.

// AVX512 一次检查 16 个包是否在某个规则范围内
static inline __mmask16
acl_rule_match_epi32(__m512i value, __m512i lo, __m512i hi)
{
    // value[i] >= lo[i] && value[i] <= hi[i]
    return _mm512_cmplt_epi32_mask(lo, value) &
           _mm512_cmplt_epi32_mask(value, hi);
}

// 批量 ACL: 16 个包 vs 1 条规则
static __mmask16
acl_batch_match(__m512i sip, __m512i dip,
                __m512i sp,  __m512i dp,
                __m512i proto,
                const struct acl_rule *rule)
{
    __mmask16 sip_ok  = acl_rule_match_epi32(sip,   rule->sip_lo,   rule->sip_hi);
    __mmask16 dip_ok  = acl_rule_match_epi32(dip,   rule->dip_lo,   rule->dip_hi);
    __mmask16 sp_ok   = acl_rule_match_epi32(sp,    rule->sp_lo,    rule->sp_hi);
    __mmask16 dp_ok   = acl_rule_match_epi32(dp,    rule->dp_lo,    rule->dp_hi);
    __mmask16 proto_ok = _mm512_cmpeq_epi32_mask(proto, rule->proto_mask);

    return sip_ok & dip_ok & sp_ok & dp_ok & proto_ok;
}
```

---

## 6. RSS 散列向量化

### 6.1 RSS 原理

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            RSS (Receive Side Scaling)                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  RSS 使用 Toeplitz 散列将数据包映射到不同接收队列:                          │
│                                                                             │
│  输入: 5-tuple 字节流 (或 4-tuple)                                          │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  SIP[4B] │ DIP[4B] │ SP[2B] │ DP[2B] │ Proto[1B] = 13 字节       │   │
│  │  (网络字节序)                                                      │   │
│  └──────────────────────────────┬──────────────────────────────────────┘   │
│                                  │                                           │
│                                  ▼                                           │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  Toeplitz 散列 (位级操作)                                           │   │
│  │                                                                      │   │
│  │  核心思想: 对输入的每个 bit，从 40 字节密钥中取出对应 bit，           │   │
│  │  按位 XOR 累积到一个 32-bit hash 值中。                              │   │
│  │                                                                      │   │
│  │  伪代码:                                                            │   │
│  │  hash = 0                                                            │   │
│  │  for each byte in input:                                            │   │
│  │      for each bit in byte (MSB first):                              │   │
│  │          if bit == 1:                                                │   │
│  │              hash ^= (key_bytes << bit_position) >> 0               │   │
│  │                                                                      │   │
│  │  这是 O(n_bits) 的位级操作，无法用 SIMD 直接向量化。                  │   │
│  └──────────────────────────────┬──────────────────────────────────────┘   │
│                                  │                                           │
│                                  ▼                                           │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  hash & (nb_queues - 1) → 队列编号                                 │   │
│  │  例: hash=0x3A2B, nb_queues=8 → queue = 0x3A2B & 7 = 3             │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  注意: Toeplitz 是位级运算，不适合 SIMD 向量化。                            │
│        DPDK 的软件 RSS 实现 (rte_softrss) 是标量循环。                      │
│        实际硬件中 RSS 由网卡硬件完成，不消耗 CPU。                          │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 6.2 DPDK 中的 RSS 实现

```c
#include <rte_thash.h>
#include <rte_hash.h>

// DPDK 提供的软件 RSS (Toeplitz) 实现
// lib/hash/rte_thash.h

// 生成 RSS 密钥 (随机 40 字节)
uint8_t rss_key[RTE_THASH_V4_L4_KEY_LEN]; // 40 字节 for IPv4+L4
rte_thash_generate_key(rss_key);

// 软件计算 RSS hash (标量 Toeplitz，不可向量化)
uint32_t rss_hash = rte_softrss(tuple, tuple_len, rss_key);

// ─────────────────────────────────────────────────────────────────
// 更常见的做法: 让硬件做 RSS
// ─────────────────────────────────────────────────────────────────

// 配置网卡硬件 RSS (在 dev_configure 阶段)
struct rte_eth_rss_conf rss_conf = {
    .rss_key = rss_key,
    .rss_key_len = RTE_THASH_V4_L4_KEY_LEN,
    .rss_hf = ETH_RSS_IP | ETH_RSS_TCP | ETH_RSS_UDP,
};

struct rte_eth_conf port_conf = {
    .rxmode = { .mq_mode = RTE_ETH_MQ_RX_RSS },
    .rx_adv_conf = { .rss_conf = rss_conf },
};
rte_eth_dev_configure(port_id, nb_rxq, nb_txq, &port_conf);

// 收包时，mbuf->hash.rss 就是网卡硬件计算好的 RSS hash
struct rte_mbuf *pkts[32];
uint16_t nb_rx = rte_eth_rx_burst(port_id, queue_id, pkts, 32);
for (uint16_t i = 0; i < nb_rx; i++) {
    uint32_t rss = pkts[i]->hash.rss;  // 硬件已算好，零 CPU 开销
    uint16_t queue = rss & (nb_rxq - 1);
}
```

> [!note] RSS 向量化的真相
> Toeplitz 是位级运算（逐 bit 处理），无法直接用 SIMD 向量化。实际生产中 RSS 由网卡硬件完成（零 CPU 开销）。软件 RSS (`rte_softrss`) 只在特殊场景使用（如 VXLAN 内层包的 RSS，需要软件解析内层 5-tuple）。

---

## 7. 数据包解析向量化

### 7.1 IPv4 头部批量校验

```c
// 验证一批 IPv4 包的头部校验和是否正确
// 使用 DPDK 中的实际方法 (lib/net/rte_ip.h)

#include <rte_ip.h>

static void
verify_ipv4_csum_batch(struct rte_mbuf **pkts, uint16_t nb_pkts,
                       uint64_t *valid_mask)  // bitmask: bit[i]=1 表示第 i 个包 csum 正确
{
    uint64_t mask = 0;

    for (uint16_t i = 0; i < nb_pkts; i++) {
        const uint8_t *pkt = rte_pktmbuf_mtod(pkts[i], const uint8_t *);
        // 跳过以太网头 (14 字节)，取 IPv4 头
        const struct rte_ipv4_hdr *iph = (const struct rte_ipv4_hdr *)(pkt + 14);

        // rte_ipv4_cksum_verify: 验证头部校验和 (内部可能使用 SIMD)
        if (rte_ipv4_cksum_verify(iph) == 0)
            mask |= (1ULL << i);
    }

    *valid_mask = mask;
}
```

### 7.2 TCP 标志批量检测

```c
#define TCP_FIN  0x01
#define TCP_SYN  0x02
#define TCP_RST  0x04
#define TCP_PSH  0x08
#define TCP_ACK  0x10
#define TCP_URG  0x20

// TCP flags 是 bitfield，一个字节中可以同时有多个标志
// 例如 SYN+ACK = 0x12，SYN+FIN = 0x03

// 标量: 检测单个包是否有 SYN 标志
static inline int
has_syn_scalar(const uint8_t *tcp_hdr)
{
    return tcp_hdr[13] & TCP_SYN;  // AND 掩码，不是比较
}

// AVX512: 批量检测 64 个包的 TCP 标志
// flags_vec: 64 个包的 TCP flags 字节 (偏移 13)
static inline void
tcp_flags_batch_avx512(__m512i flags_vec,  // 低 32 字节 (32 个包)
                        __m512i flags_vec2, // 高 32 字节 (另外 32 个包)
                        __mmask64 *has_syn_mask,
                        __mmask64 *has_synack_mask,
                        __mmask64 *has_rst_mask)
{
    __mmask32 syn_lo = _mm512_test_epi8_mask(flags_vec,
                         _mm512_set1_epi8(TCP_SYN));
    __mmask32 syn_hi = _mm512_test_epi8_mask(flags_vec2,
                         _mm512_set1_epi8(TCP_SYN));
    *has_syn_mask = (__mmask64)syn_lo | ((__mmask64)syn_hi << 32);

    // SYN+ACK = (flags & 0x12) == 0x12
    __mmask32 sa_lo = _mm512_cmpeq_epi8_mask(
        _mm512_and_si512(flags_vec, _mm512_set1_epi8(TCP_SYN | TCP_ACK)),
        _mm512_set1_epi8(TCP_SYN | TCP_ACK));
    __mmask32 sa_hi = _mm512_cmpeq_epi8_mask(
        _mm512_and_si512(flags_vec2, _mm512_set1_epi8(TCP_SYN | TCP_ACK)),
        _mm512_set1_epi8(TCP_SYN | TCP_ACK));
    *has_synack_mask = (__mmask64)sa_lo | ((__mmask64)sa_hi << 32);

    // RST 标志
    __mmask32 rst_lo = _mm512_test_epi8_mask(flags_vec,
                         _mm512_set1_epi8(TCP_RST));
    __mmask32 rst_hi = _mm512_test_epi8_mask(flags_vec2,
                         _mm512_set1_epi8(TCP_RST));
    *has_rst_mask = (__mmask64)rst_lo | ((__mmask64)rst_hi << 32);
}

// 注意: 检测 TCP flags 必须用 AND 掩码 (_mm512_test_epi8_mask)，
// 不能用比较 (cmpgt/cmpeq)，因为 flags 是 bitfield，多个标志可以同时存在。
// 例如 flags=0x12 (SYN+ACK)，如果用 cmpgt(..., TCP_SYN-1) 会匹配，
// 但也会错误匹配 flags=0x04 (RST) 等不包含 SYN 的值。
```

---

## 8. NEON (ARM 向量化)

### 8.1 NEON 基础

```c
#include <arm_neon.h>

// ARM NEON 提供 128-bit 向量寄存器 (Q0-Q31)
// 标准类型 (不需要自定义 typedef):

uint8x16_t  v_u8;    // 16 x uint8_t
uint16x8_t  v_u16;   // 8  x uint16_t
uint32x4_t  v_u32;   // 4  x uint32_t
uint64x2_t  v_u64;   // 2  x uint64_t
int8x16_t   v_s8;    // 16 x int8_t
int16x8_t   v_s16;   // 8  x int16_t
int32x4_t   v_s32;   // 4  x int32_t

// 加载/存储
v_u8  = vld1q_u8(ptr);           // 加载 16 字节
vst1q_u8(ptr, v_u8);             // 存储 16 字节

// 算术
v_u16 = vaddq_u16(v_u16, v_u16); // 8 个 16-bit 加法
v_u32 = vmulq_u32(v_u32, v_u32); // 4 个 32-bit 乘法

// 比较 (NEON 没有独立 mask 寄存器，比较结果是 0xFF/0x00)
uint8x16_t cmp = vcgtq_u8(v_u8, threshold);
// 每个元素: 条件为真 = 0xFF, 条件为假 = 0x00

// 字节混洗
uint8x16_t shuffled = vqtbl1q_u8(table, index);

// CRC32 (ARMv8-a 提供的硬件指令，不是 NEON 指令)
uint32_t crc = __crc32cw(initial, value);   // CRC-32C (Castagnoli)
uint32_t crc = __crc32w(initial, value);    // CRC-32  (ISO 3309)
```

> [!note] NEON vs AVX512 的关键差异
>
> - NEON 没有 mask 寄存器，比较结果是全宽向量（0xFF/0x00），不是位掩码
> - NEON 最大 128-bit，吞吐约为 AVX512 的 1/4
> - ARMv8 的 CRC32 是独立指令，不是 NEON 的一部分

### 8.2 NEON 校验和示例

```c
#include <arm_neon.h>

static uint16_t
csum_neon(const void *data, size_t len)
{
    uint32x4_t sum_vec = vdupq_n_u32(0);
    const uint8_t *ptr = data;

    // 每次 16 字节
    while (len >= 16) {
        uint8x16_t v = vld1q_u8(ptr);

        // 交错相加: 将 16 字节展开为 8 个 16-bit 值
        uint16x8_t sum16 = vpaddlq_u8(v);

        // 再展开为 4 个 32-bit 值，累加
        sum_vec = vpadalq_u16(sum_vec, sum16);

        ptr += 16;
        len -= 16;
    }

    // 水平归约
    uint32_t sum = vgetq_lane_u32(sum_vec, 0) +
                   vgetq_lane_u32(sum_vec, 1) +
                   vgetq_lane_u32(sum_vec, 2) +
                   vgetq_lane_u32(sum_vec, 3);

    // 尾部标量处理
    while (len > 1) {
        sum += *(const uint16_t *)ptr;
        ptr += 2;
        len -= 2;
    }
    if (len)
        sum += *ptr;

    // 回卷 + 取反
    sum = (sum & 0xFFFF) + (sum >> 16);
    sum = (sum & 0xFFFF) + (sum >> 16);
    return ~sum;
}
```

---

## 9. 性能参考

### 9.1 SIMD 加速效果

> [!note] 数据来源说明
> 以下数据为典型量级参考，综合自 Intel whitepaper 和社区 benchmark。实际性能取决于 CPU 型号、内存带宽、包大小分布和代码实现质量。

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        SIMD 加速效果 (典型量级)                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  操作                    标量     SSE4.2   AVX2    AVX512                  │
│  ─────────────────────────────────────────────────────────────────────────│
│  CRC32C 吞吐              2 GB/s   8 GB/s  12 GB/s  15-20 GB/s             │
│  IP Checksum              1 GB/s   4 GB/s   7 GB/s  10-12 GB/s             │
│  AES-128-GCM              0.5 GB/s  2 GB/s   5 GB/s  10-15 GB/s             │
│                                                                             │
│  包处理 (64B, 解析+分类):                                                   │
│  ─────────────────────                                                      │
│  标量                        5-8 Mpps                                       │
│  SSE4.2                     15-20 Mpps                                     │
│  AVX2                       25-35 Mpps                                     │
│  AVX512                     40-55 Mpps                                     │
│                                                                             │
│  注意: Mpps 值受内存带宽和 CPU 型号影响大，上表为 Haswell/Skylake 参考       │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 9.2 编译优化建议

```bash
# 启用 SIMD 自动向量化 (编译器自动识别循环)
CFLAGS="-O3 -march=native"

# 查看编译器是否成功向量化 (GCC)
CFLAGS="-O3 -march=native -fopt-info-vec-optimized -fopt-info-vec-missed"
# 编译后终端会输出: "loop vectorized" 或 "not vectorized: ..."

# 手动指定目标架构
CFLAGS="-O3 -mavx512f -mavx512bw"   # AVX512 (字节/字操作对包处理最重要)
CFLAGS="-O3 -mavx2"                  # AVX2 (更通用，大多数服务器支持)

# 链接时优化 (LTO)
CFLAGS="-O3 -flto -march=native"
```

---

## 10. 小结

本章核心要点：

1. **SIMD 背景**：单条指令处理多个数据。AVX512 一条 512-bit 加法处理 16 个 32-bit 值。关键是**吞吐量**（2 ops/cycle），不是单条延迟（4 cycles）。

2. **指令集演进**：SSE (128-bit) → AVX2 (256-bit) → AVX512 (512-bit)，ARM NEON (128-bit)。

3. **AVX512 架构**：32 个 ZMM 寄存器 + 8 个 K mask 寄存器。mask 操作是 AVX512 的核心优势——条件处理不用分支。

4. **DPDK 向量化框架**：`rte_vect.h` 提供跨平台类型抽象（`rte_xmm_t/rte_ymm_t/rte_zmm_t`），`rte_cpu_get_flag_enabled()` 检测 CPU 特性。DPDK 没有专门的批量结构体，SIMD 分散在各模块中。

5. **校验和向量化**：16-bit 反码求和适合 SIMD（拆高低 16-bit 并行加），CRC32 用 SSE4.2 硬件指令（`_mm_crc32_u64`，每条处理 8 字节）。

6. **5-tuple 哈希**：简单的 XOR+乘法哈希可以批量向量化；Toeplitz RSS 是位级运算，**不可向量化**，实际由网卡硬件完成。

7. **TCP 标志检测**：flags 是 bitfield，必须用 AND 掩码（`_mm512_test_epi8_mask`），不能用比较（`cmpgt`），因为多个标志可以同时存在。

8. **NEON**：ARM 128-bit 向量，没有 mask 寄存器（比较结果是 0xFF/0x00 向量），CRC32 用 `__crc32cw` 独立指令。

9. **性能收益**：AVX512 可达 8-16x 加速（相比标量），但需要好的批量处理模式才能发挥。

**上一篇**：[[ch19b-dpu-smartnic|第十九章补充：DPU/SmartNIC 基础]]

**下一篇预告**：[[ch21-cryptodev|第二十一章]]将讲解 cryptodev 加密设备与 Crypto PMD——DPDK 的硬件加密加速框架。

---

> [!tip] 参考文献
>
> - Intel, "Intel Intrinsics Guide", https://www.intel.com/content/www/us/en/docs/intrinsics-guide/
> - Intel, "Intel Architecture Instruction Set Extensions Programming Reference"
> - DPDK, "rte_vect.h", https://doc.dpdk.org/api/rte__vect_8h.html
> - DPDK, "rte_thash.h", https://doc.dpdk.org/api/rte__thash_8h.html
> - ARM, "ARM NEON Intrinsics Reference", https://developer.arm.com/architectures/instruction-sets/simd-isas/neon/intrinsics
