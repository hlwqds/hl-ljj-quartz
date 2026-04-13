---
title: "DPDK 深度探索 (二十)：AVX512/SIMD 数据包处理向量化"
date: 2026-04-09
tags: [dpdk, series, simd, avx512, sse, neon, vectorization, packet-processing, performance]
description: "深入理解 SIMD 向量化在 DPDK 中的应用——AVX512/SSE/NEON 指令集、数据包批量处理、校验和计算、查找表、RSS 散列向量化"
---

> [!info] DPDK 深度探索系列
> 0. [[2026-04-09-dpdk-deep-dive-series-index|全栈学习路径总览]]
> 1-19. 前十九章已完成
> 20. **第二十章：AVX512/SIMD 数据包处理向量化**

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
│  数据: [D0][D1][D2][D3][D4][D5][D6][D7] (64 字节, 8 个 64-bit 数据)       │
│         └──────────┬──────────┘                                            │
│                      │                                                      │
│                      ▼                                                      │
│  ┌──────────────────────────────────────────┐                              │
│  │           VADDPD (向量化加法)            │                              │
│  │      (一条指令同时加 8 个数据)           │                              │
│  └──────────────────┬───────────────────────┘                              │
│                     │                                                       │
│                     ▼                                                       │
│         [R0][R1][R2][R3][R4][R5][R6][R7]                                    │
│                                                                             │
│  1 个周期完成 8 个操作 (8 ops/cycle) → 8x 加速!                            │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
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
│  - 查找: 5-tuple 查找, ACL 规则匹配                                       │
│  - 解析: IP 头解析, TCP 标志检测                                           │
│  - 加密: AES-CBC/GCM, CRC32                                              │
│  - 排序: 数据包优先级排序                                                 │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 1.3 SIMD 指令集发展

| 指令集 | 位宽 | 数据类型 | 典型应用 |
|--------|------|----------|----------|
| **MMX** | 64-bit | 整数 | 早期多媒体 |
| **SSE** | 128-bit | 单精度浮点、整数 | 包处理 (x86) |
| **SSE2/3/4** | 128-bit | 扩展类型 | 校验和、加密 |
| **AVX** | 256-bit | 浮点 | 加密、向量计算 |
| **AVX2** | 256-bit | 整数 | 包处理、查找 |
| **AVX-512** | 512-bit | 全部类型 | 高性能包处理 |
| **NEON** | 128-bit | ARM 向量 | ARM 包处理 |
| **SVE/SVE2** | 可变 (128-2048-bit) | ARM 向量 | HPC、网络 |

---

## 2. AVX512 指令集详解

### 2.1 AVX512 架构

```c
// AVX512 提供 32 个 512-bit ZMM 寄存器 (ZMM0-ZMM31)
// 以及 32 个 512-bit mask 寄存器 (K0-K7)

/*
 * AVX512 寄存器模型:
 *
 *  ZMM31 (511:0)
 *  ├─ YMM31 (255:0) (AVX2 兼容)
 *  │   └─ XMM31 (127:0) (SSE 兼容)
 *  │
 *  YMM31 (255:0)
 *  └─ XMM31 (127:0)
 *
 *  XMM31 (127:0)
 *  (SSE 128-bit 寄存器)
 */

// 向量整数类型 (AVX512BW - Byte/Word)
__m512i v0;  // 512-bit = 64 x int8_t 或 32 x int16_t 或 16 x int32_t

// 向量浮点类型 (AVX512F)
__m512 v0;   // 512-bit = 16 x float
__m512d v0;  // 512-bit = 8 x double

// 向量掩码 (AVX512DQ)
__mmask8 k0;  // 8-bit mask
__mmask16 k0; // 16-bit mask
__mmask32 k0; // 32-bit mask
__mmask64 k0; // 64-bit mask
```

### 2.2 AVX512 基本运算

```c
// AVX512 基本运算示例

#include <immintrin.h>

void
simd_examples(void)
{
    // ─────────────────────────────────────────────────────────────────
    // 1. 加载和存储 (Load/Store)
    // ─────────────────────────────────────────────────────────────────

    // 未对齐加载 512 位 (64 字节)
    __m512i v1 = _mm512_loadu_si512((const void *)ptr);

    // 对齐加载 (更快)
    __m512i v2 = _mm512_load_si512((const __m512i *)ptr);

    // 存储
    _mm512_store_si512((__m512i *)ptr, v1);

    // ─────────────────────────────────────────────────────────────────
    // 2. 算术运算
    // ─────────────────────────────────────────────────────────────────

    // 32 位整数加法 (16 个 32 位整数同时加)
    __m512i a = _mm512_set1_epi32(1);    // 广播 1
    __m512i b = _mm512_set_epi32(0, 1, 2, 3, 4, 5, 6, 7,
                                  8, 9, 10, 11, 12, 13, 14, 15);
    __m512i sum = _mm512_add_epi32(a, b);  // 结果: 1, 2, 3, ..., 16

    // 16 位整数加法 (32 个 16 位整数)
    __m512i c = _mm512_set1_epi16(100);
    __m512i d = _mm512_add_epi16(c, c);

    // 字节加法 (64 个字节)
    __m512i e = _mm512_set1_epi8(1);
    __m512i f = _mm512_add_epi8(e, e);

    // 浮点运算
    __m512 g = _mm512_set_ps(1.0f, 2.0f, 3.0f, 4.0f,
                              5.0f, 6.0f, 7.0f, 8.0f,
                              9.0f, 10.0f, 11.0f, 12.0f,
                              13.0f, 14.0f, 15.0f, 16.0f);
    __m512 h = _mm512_set1_ps(2.0f);
    __m512 i = _mm512_mul_ps(g, h);  // 乘以 2

    // ─────────────────────────────────────────────────────────────────
    // 3. 比较运算
    // ─────────────────────────────────────────────────────────────────

    // 比较 32 位整数 (大于)
    __m512i x = _mm512_set_epi32(10, 20, 30, 40, 50, 60, 70, 80,
                                  90, 100, 110, 120, 130, 140, 150, 160);
    __m512i y = _mm512_set1_epi32(100);
    __mmask16 cmp = _mm512_cmpgt_epi32_mask(x, y);
    // cmp: 0b0000000011111111 (前 8 个 > 100)

    // 浮点比较
    __m512 p1 = _mm512_set_ps(1.0f, 2.0f, 3.0f, 4.0f,
                              5.0f, 6.0f, 7.0f, 8.0f,
                              9.0f, 10.0f, 11.0f, 12.0f,
                              13.0f, 14.0f, 15.0f, 16.0f);
    __m512 p2 = _mm512_set1_ps(10.0f);
    __mmask16 fp_cmp = _mm512_cmp_ps_mask(p1, p2, _MM_CMPINT_GT);

    // ─────────────────────────────────────────────────────────────────
    // 4. 逻辑运算
    // ─────────────────────────────────────────────────────────────────

    // 按位与
    __m512i and_result = _mm512_and_si512(v1, v2);

    // 按位或
    __m512i or_result = _mm512_or_si512(v1, v2);

    // 按位异或
    __m512i xor_result = _mm512_xor_si512(v1, v2);

    // ─────────────────────────────────────────────────────────────────
    // 5. 字节操作 (查找/计数)
    // ─────────────────────────────────────────────────────────────────

    // 字节比较 (比较 64 个字节)
    __m512i vcmp = _mm512_cmpgt_epi8_mask(v1, v2);

    // 计算非零字节数
    int nz_bytes = _mm_popcnt_u32(cmp);

    // 压缩选择 (根据 mask 选择元素)
    __m512i selected = _mm512_maskz_compress_epi8(cmp, v1);
}
```

### 2.3 AVX512 字节/字操作

```c
// AVX512BW (Byte/Word) 扩展指令

// 字节比较
__mmask64 byte_cmp = _mm512_cmpgt_epi8_mask(a, b);

// 字节饱和加法 (用于 checksum 计算)
__m512i sat_add = _mm512_adds_epu16(a, b);  // 饱和到 65535

// 字节打包
__m512i packed = _mm512_packs_epi16(v16_a, v16_b);  // 16-bit → 8-bit

// 字节混排 (shuffle)
__m512i shuffled = _mm512_shuffle_epi8(v, shuffle_mask);

// 字节差值绝对值
__m512i diff = _mm512_abs_epi8(a);  // |a|

// CRC32 指令 (SSE4.2)
uint32_t crc = _mm_crc32_u8(crc, byte);
uint32_t crc = _mm_crc32_u32(crc, value);
uint32_t crc = _mm_crc32_u64(crc, value);
```

---

## 3. DPDK SIMD 框架

### 3.1 rte_vect 库

```c
// lib/librte_eal/common/include/rte_vect.h

// DPDK 向量化类型抽象

// 128-bit SIMD (SSE/NEON)
#if defined(__SSE4_2__)
typedef __m128i rte_xmm_t;    // 128-bit = 16 x int8_t
#endif

// 256-bit SIMD (AVX2)
#if defined(__AVX2__)
typedef __m256i rte_ymm_t;    // 256-bit = 32 x int8_t
#endif

// 512-bit SIMD (AVX512)
#if defined(__AVX512F__)
typedef __m512i rte_zmm_t;    // 512-bit = 64 x int8_t
#endif

// 向量长度类型 (VL) - 用于返回多个值
#if defined(__AVX512F__)
typedef uint16_t rte_vle16_t;  // 16 元素
typedef uint32_t rte_vle32_t;  // 32 元素
#endif

// 运行时 SIMD 能力检测
struct rte_cpu_features {
    int sse;     // SSE 支持
    int sse2;    // SSE2 支持
    int sse3;    // SSE3 支持
    int ssse3;   // SSSE3 支持
    int sse4_1;  // SSE4.1 支持
    int sse4_2;  // SSE4.2 支持
    int avx;     // AVX 支持
    int avx2;    // AVX2 支持
    int avx512f; // AVX512F 支持
    int avx512bw;// AVX512BW 支持
};

// 检查 CPU 支持
int rte_cpu_get_supported_instruction_set(void);
```

### 3.2 SIMD 批量数据包处理

```c
// lib/vect/rte_vect.h

// 批量数据包结构 (SIMD friendly)
struct rte_pktmbuf_batch {
    // 批量 mbuf 指针 (与 SIMD 寄存器对齐)
    struct rte_mbuf *mbufs[RTE_VECT_SIMD_MAX];
    uint16_t nb_mbufs;

    // 批量数据指针 (用于直接处理)
    void *data_ptrs[RTE_VECT_SIMD_MAX];
    uint16_t nb_ptrs;
};

// SIMD 处理宏
#define RTE_VECT_SIMD_MAX 64  // AVX512 最大处理量

// 批量处理循环
#define VECT_FOR_EACH_PROCESS(mbufs, nb_mbufs, batch_size, func) \
    do { \
        uint16_t nb_processed = 0; \
        for (; nb_processed < (nb_mbufs) - (batch_size) + 1; \
             nb_processed += (batch_size)) { \
            (func)((mbufs) + nb_processed, (batch_size)); \
        } \
        /* 处理剩余的 */ \
        for (; nb_processed < (nb_mbufs); nb_processed++) { \
            (func)((mbufs) + nb_processed, 1); \
        } \
    } while (0)
```

### 3.3 自动向量化

```c
// DPDK 提供的手动和自动向量化工具

// 1. ICC 自动向量化报告
// 编译选项: -qopt-report=5 -qopt-report-phase=vec

// 2. GCC 自动向量化报告
// 编译选项: -fopt-info-vec-optimized -fopt-info-vec-missed

// 3. 手动 SIMD intrinsics
#include <rte_vect.h>

// 4. 条件向量化
#if defined(__AVX512F__)
    // AVX512 代码
#elif defined(__AVX2__)
    // AVX2 代码
#elif defined(__SSE4_2__)
    // SSE 代码
#else
    // 标量回退
#endif

// 5. 编译时选择
// meson.build 中配置
simd_deps = []
if cc.get_id() == 'gcc' or cc.get_id() == 'clang'
    simd_deps += [['-msse4']]
    if cc.has_argument('-mavx2')
        simd_deps += [['-mavx2']]
    if cc.has_argument('-mavx512f')
        simd_deps += [['-mavx512f']]
endif
```

---

## 4. 校验和计算向量化

### 4.1 IP/TCP/UDP Checksum

```c
// 校验和计算是包处理中最常见的操作之一
// 16-bit 反码求和

// 标量版本
static uint16_t
csum_scalar(const void *data, size_t len)
{
    uint32_t sum = 0;
    const uint16_t *p = data;

    while (len > 1) {
        sum += *p++;
        len -= 2;
    }

    if (len) {
        sum += *(const uint8_t *)p;
    }

    // 反码
    while (sum >> 16) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }

    return ~sum;
}

// SIMD 版本 (AVX512)
static uint16_t
csum_avx512(const void *data, size_t len)
{
    __m512i sum_vec = _mm512_setzero_si512();
    const uint8_t *ptr = (const uint8_t *)data;

    // 以 64 字节为单位处理
    while (len >= 64) {
        __m512i v = _mm512_loadu_si512((const __m512i *)ptr);

        // 字节混洗相加 (16-bit 打包)
        __m512i sum_lo = _mm512_srli_epi32(v, 16);
        __m512i sum_hi = _mm512_and_si512(v, _mm512_set1_epi32(0xFFFF));
        sum_vec = _mm512_add_epi32(sum_vec, sum_lo);
        sum_vec = _mm512_add_epi32(sum_vec, sum_hi);

        ptr += 64;
        len -= 64;
    }

    // 处理剩余的 32 字节 (AVX2)
    if (len >= 32) {
        __m256i v = _mm256_loadu_si256((const __m256i *)ptr);
        sum_vec = _mm256256_add_epi32(sum_vec, v);  // 混洗
        ptr += 32;
        len -= 32;
    }

    // 水平相加所有 32-bit
    uint32_t sum = _mm512_reduce_add_epi32(sum_vec);

    // 处理剩余字节
    while (len > 1) {
        sum += *ptr++;
        len -= 2;
    }
    if (len) {
        sum += *ptr;
    }

    // 反码
    sum = (sum & 0xFFFF) + (sum >> 16);
    sum = (sum & 0xFFFF) + (sum >> 16);
    return ~sum;
}
```

### 4.2 CRC32 向量化

```c
// CRC32-C 校验 (用于 iSCSI、网络等)
// 使用 SSE4.2 的 CRC32 指令

#include <smmintrin.h>

// 单字节 CRC
static inline uint32_t
crc32c_u8(uint32_t crc, uint8_t byte)
{
    return _mm_crc32_u8(crc, byte);
}

// 32 位 CRC
static inline uint32_t
crc32c_u32(uint32_t crc, uint32_t value)
{
    return _mm_crc32_u32(crc, value);
}

// 64 位 CRC
static inline uint64_t
crc32c_u64(uint64_t crc, uint64_t value)
{
    return _mm_crc32_u64(crc, value);
}

// CRC32 批量处理 (使用 SIMD 拼接)
static uint32_t
crc32c_vec(const void *data, size_t len, uint32_t crc_init)
{
    uint32_t crc = crc_init;
    const uint8_t *ptr = data;

    // 对齐到 8 字节
    while (((uintptr_t)ptr & 7) && len) {
        crc = crc32c_u8(crc, *ptr++);
        len--;
    }

    // 处理 8 字节块
    const uint64_t *ptr64 = (const uint64_t *)ptr;
    while (len >= 8) {
        crc = crc32c_u64(crc, *ptr64++);
        len -= 8;
    }

    // 处理剩余字节
    ptr = (const uint8_t *)ptr64;
    while (len--) {
        crc = crc32c_u8(crc, *ptr++);
    }

    return crc;
}

// 完整数据包的 CRC32
static inline uint32_t
crc32c_pkt(const struct rte_mbuf *m, uint32_t crc_init)
{
    uint32_t crc = crc_init;
    uint32_t len = m->pkt_len;

    // 处理每个 segment
    struct rte_mbuf *seg = m;
    while (seg) {
        crc = crc32c_vec(rte_pktmbuf_mtod(seg, const void *),
                          seg->data_len, crc);
        seg = seg->next;
    }

    return crc;
}
```

---

## 5. 查找表向量化

### 5.1 5-Tuple 查找

```c
// 网络流查找 (5-tuple: SIP, DIP, SP, DP, Protocol)
// 使用向量化的桶排序或哈希

// SIMD 友好的哈希结构
struct flow_key_simd {
    __m512i sip;      // 8 x 64-bit SIP
    __m512i dip;      // 8 x 64-bit DIP
    __m512i ports;    // 8 x 32-bit SP<<16 | DP
    __m512i proto;    // 8 x 8-bit Protocol
};

// 向量化哈希计算
static inline __m512i
hash_5tuple_avx512(__m512i sip, __m512i dip,
                    __m512i ports, __m512i proto)
{
    // 简单的向量哈希 (可替换为更复杂的算法)
    __m512i hash = sip;
    hash = _mm512_xor_si512(hash, dip);
    hash = _mm512_mullo_epi32(hash, _mm512_set1_epi32(0x9E3779B9));

    // 混洗 ports
    __m512i shuffled = _mm512_shuffle_epi8(ports, ports);
    hash = _mm512_xor_si512(hash, shuffled);
    hash = _mm512_mullo_epi32(hash, _mm512_set1_epi32(0x9E3779B9));

    // 加入 protocol
    hash = _mm512_xor_si512(hash, proto);
    hash = _mm512_mullo_epi32(hash, _mm512_set1_epi32(0x9E3779B9));

    return hash;
}

// 批量流查找
static uint16_t
flow_lookup_avx512(struct flow_key_simd *keys,
                   struct flow_entry **results,
                   uint16_t nb_keys)
{
    uint16_t i = 0;

    // 以 8 个为一组处理
    for (; i + 8 <= nb_keys; i += 8) {
        __m512i sip_vec, dip_vec, ports_vec, proto_vec;

        // 加载 8 个键
        // (实际代码需要从 keys 数组提取并合并为向量)
        sip_vec = ...;
        dip_vec = ...;
        ports_vec = ...;
        proto_vec = ...;

        // 计算哈希
        __m512i hash = hash_5tuple_avx512(sip_vec, dip_vec,
                                           ports_vec, proto_vec);

        // 提取哈希值
        uint64_t hashes[8];
        _mm512_storeu_si512(hashes, hash);

        // 批量查找
        for (int j = 0; j < 8; j++) {
            results[i + j] = flow_table_lookup(hashes[j]);
        }
    }

    // 处理剩余的
    for (; i < nb_keys; i++) {
        uint64_t h = hash_5tuple_scalar(keys[i]);
        results[i] = flow_table_lookup(h);
    }

    return nb_keys;
}
```

### 5.2 ACL 规则匹配

```c
// 数据包分类 - 向量化的 Trie/DFA

// SIMD 友好的 ACL 规则
struct acl_rule_simd {
    __m512i sip_lo;     // SIP 范围下限
    __m512i sip_hi;     // SIP 范围上限
    __m512i dip_lo;     // DIP 范围下限
    __m512i dip_hi;     // DIP 范围上限
    __m512i sp_lo;      // 源端口范围下限
    __m512i sp_hi;      // 源端口范围上限
    __m512i dp_lo;      // 目的端口范围下限
    __m512i dp_hi;      // 目的端口范围上限
    __m512i proto;      // 协议掩码
};

// 向量化范围检查
static inline __mmask8
in_range_avx512(__m512i value, __m512i lo, __m512i hi)
{
    return _mm512_cmpge_epi32_mask(value, lo) &
           _mm512_cmple_epi32_mask(value, hi);
}

// 批量 ACL 匹配
static uint32_t
acl_match_avx512(__m512i sip, __m512i dip,
                  __m512i sp, __m512i dp,
                  __m512i proto,
                  const struct acl_rule_simd *rules,
                  uint16_t nb_rules)
{
    uint32_t result = 0;  // 匹配的第一个规则

    for (uint16_t i = 0; i < nb_rules; i++) {
        const struct acl_rule_simd *r = &rules[i];

        // 检查每个字段是否在范围内
        __mmask8 sip_ok = in_range_avx512(sip, r->sip_lo, r->sip_hi);
        __mmask8 dip_ok = in_range_avx512(dip, r->dip_lo, r->dip_hi);
        __mmask8 sp_ok = in_range_avx512(sp, r->sp_lo, r->sp_hi);
        __mmask8 dp_ok = in_range_avx512(dp, r->dp_lo, r->dp_hi);

        // 协议匹配 (需要掩码处理)
        __mmask8 proto_ok = _mm512_cmpeq_epi32_mask(proto, r->proto);

        // 所有字段都匹配
        __mmask8 match = sip_ok & dip_ok & sp_ok & dp_ok & proto_ok;

        if (match) {
            result = i;
            break;
        }
    }

    return result;
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
│  RSS 使用 Toeplitz 散列函数将数据包映射到队列:                              │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐  │
│  │                         RSS 输入                                      │  │
│  │                                                                      │  │
│  │  4-tuple: SIP[32] ⊕ DIP[32] ⊕ SP[16] ⊕ DP[16] ⊕ Protocol[8]        │  │
│  │                                                                      │  │
│  │  示例: 192.168.1.100 + 10.0.0.1 + 12345 + 80 + TCP                  │  │
│  │                                                                      │  │
│  └────────────────────────────────┬────────────────────────────────────┘  │
│                                   │                                           │
│                                   ▼                                           │
│  ┌─────────────────────────────────────────────────────────────────────┐  │
│  │                    Toeplitz 散列                                      │  │
│  │                                                                      │  │
│  │   Key[0]   Key[1]   Key[2]   ... Key[k]                            │  │
│  │      │        │        │        │                                   │  │
│  │      ▼        ▼        ▼        ▼                                    │  │
│  │   ┌─────┐  ┌─────┐  ┌─────┐  ┌─────┐                              │  │
│  │   │ XOR │─►│ XOR │─►│ XOR │─►│ XOR │                              │  │
│  │   └─────┘  └─────┘  └─────┘  └─────┘                              │  │
│  │      │                                                     │        │  │
│  │      ▼                                                     ▼        │  │
│  │   Input[0] XOR Input[1] XOR Input[2] XOR ... XOR Input[n]        │  │
│  │                                                                      │  │
│  └────────────────────────────────┬────────────────────────────────────┘  │
│                                   │                                           │
│                                   ▼                                           │
│                          ┌────────────────┐                                 │
│                          │  Hash[32-bit]  │                                 │
│                          └───────┬────────┘                                 │
│                                  │                                           │
│                                  ▼                                           │
│                          ┌────────────────┐                                 │
│                          │ Indirection    │                                 │
│                          │ Table          │                                 │
│                          │ [0..2^m-1]     │                                 │
│                          └───────┬────────┘                                 │
│                                  │                                           │
│                                  ▼                                           │
│                           Queue = Hash & (2^m-1)                            │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 6.2 向量化 RSS

```c
// SSE4.2/AVX2 实现 Toeplitz 散列

// SSE4.2 版本 (128-bit, 每次处理 4 字节)
static inline uint32_t
rss_toeplitz_sse4(const uint8_t *input, size_t len,
                   const uint8_t *key)
{
    uint32_t hash = 0;

    // 以 4 字节为单位处理
    for (size_t i = 0; i < len; i++) {
        uint8_t shift = input[i];
        uint32_t key_word = *(uint32_t *)(key + 4 * i);
        hash ^= key_word << shift | key_word >> (32 - shift);
    }

    return hash;
}

// AVX2 版本 (256-bit, 每次处理 8 字节)
static inline uint32_t
rss_toeplitz_avx2(const uint8_t *input, size_t len,
                   const uint8_t *key)
{
    __m256i hash_acc = _mm256_setzero_si256();

    size_t i = 0;

    // 以 8 字节为单位处理
    for (; i + 8 <= len; i += 8) {
        // 加载 8 字节
        __m256i data = _mm256_set_epi32(
            input[i+3] << 24 | input[i+2] << 16 | input[i+1] << 8 | input[i],
            input[i+7] << 24 | input[i+6] << 16 | input[i+5] << 8 | input[i+4],
            0, 0, 0, 0, 0, 0);

        // 加载 8 字节 key
        __m256i key_vec = _mm256_loadu_si256((__m256i *)(key + 4 * i));

        // SIMD 旋转
        // (实际需要字节级旋转，代码更复杂)
        __m256i rotated = _mm256_or_si256(
            _mm256_slli_epi32(key_vec, data),
            _mm256_srli_epi32(key_vec, 32 - data));

        hash_acc = _mm256_xor_si256(hash_acc, rotated);
    }

    // 水平 XOR
    uint32_t hash = _mm256_extract_epi32(hash_acc, 0);
    hash ^= _mm256_extract_epi32(hash_acc, 1);

    // 处理剩余字节
    for (; i < len; i++) {
        uint8_t shift = input[i];
        uint32_t key_word = *(uint32_t *)(key + 4 * i);
        hash ^= key_word << shift | key_word >> (32 - shift);
    }

    return hash;
}

// 批量 RSS 计算
static void
rss_batch_avx2(const uint8_t (*packets)[42],  // IP + TCP/UDP 头
               uint32_t *results,
               uint16_t nb_packets,
               const uint8_t *key)
{
    // 解析并批量计算 5-tuple 哈希
    for (uint16_t i = 0; i < nb_packets; i++) {
        const uint8_t *pkt = packets[i];

        // 提取 5-tuple
        uint32_t sip = *(uint32_t *)(pkt + 12);  // IP src
        uint32_t dip = *(uint32_t *)(pkt + 16);  // IP dst
        uint16_t sp = *(uint16_t *)(pkt + 20);   // src port
        uint16_t dp = *(uint16_t *)(pkt + 22);  // dst port
        uint8_t proto = *(uint8_t *)(pkt + 23); // protocol

        // 组合并计算哈希
        uint8_t tuple[12] = {
            (uint8_t)(sip >> 24), (uint8_t)(sip >> 16), (uint8_t)(sip >> 8), (uint8_t)sip,
            (uint8_t)(dip >> 24), (uint8_t)(dip >> 16), (uint8_t)(dip >> 8), (uint8_t)dip,
            (uint8_t)(sp >> 8), (uint8_t)sp,
            (uint8_t)(dp >> 8), (uint8_t)dp
        };
        // + proto

        results[i] = rss_toeplitz_avx2(tuple, 12, key);
    }
}
```

---

## 7. 数据包解析向量化

### 7.1 IP 头解析

```c
// 向量化 IP 头解析

// IPv4 头结构 (固定 20 字节)
struct ipv4_hdr {
    uint8_t version_ihl;    // version << 4 | ihl
    uint8_t tos;
    uint16_t total_length;
    uint16_t packet_id;
    uint16_t fragment_offset;
    uint8_t ttl;
    uint8_t next_proto;
    uint16_t hdr_checksum;
    uint32_t src_addr;
    uint32_t dst_addr;
};

// 批量解析 IPv4 头
static void
parse_ipv4_batch_avx512(struct rte_mbuf **mbufs,
                         uint16_t nb_mbufs,
                         struct ipv4_info *info)
{
    uint16_t i = 0;

    // 对齐到 8 个包
    for (; i + 8 <= nb_mbufs; i += 8) {
        // 批量提取 version/ihl
        // (实际需要从 mbuf 数据中 gather)

        // 提取 protocol
        // 提取 TTL
        // 提取头长度
        // ...

        // SIMD 比较判断
        __m512i proto_vec = ...;
        __mmask8 is_tcp = _mm512_cmpeq_epi32_mask(proto_vec, _mm512_set1_epi32(6));
        __mmask8 is_udp = _mm512_cmpeq_epi32_mask(proto_vec, _mm512_set1_epi32(17));
        __mmask8 is_icmp = _mm512_cmpeq_epi32_mask(proto_vec, _mm512_set1_epi32(1));

        // 存储结果
        for (int j = 0; j < 8; j++) {
            info[i + j].protocol = ((uint8_t *)&proto_vec)[j];
            info[i + j].is_tcp = (is_tcp >> j) & 1;
            info[i + j].is_udp = (is_udp >> j) & 1;
        }
    }

    // 处理剩余的 (标量)
    for (; i < nb_mbufs; i++) {
        parse_ipv4_scalar(mbufs[i], &info[i]);
    }
}
```

### 7.2 TCP 标志检测

```c
// 批量 TCP 标志检测 (SYN, FIN, ACK, etc.)

#define TCP_FIN  0x01
#define TCP_SYN  0x02
#define TCP_RST  0x04
#define TCP_PSH  0x08
#define TCP_ACK  0x10
#define TCP_URG  0x20

// 标量版本
static uint8_t
tcp_flag_scalar(const uint8_t *tcp_hdr)
{
    return tcp_hdr[13];
}

// 向量版本
static __m512i
tcp_flags_avx512(__m512i flags_vec)
{
    // flags_vec 包含 16 个包的 TCP flags (每个 1 字节)
    // 偏移 13 = TCP flags 偏移

    // 提取 flags
    // ...

    // 一次比较多个标志
    __mmask64 has_syn = _mm512_cmpgt_epi8_mask(flags_vec, _mm512_set1_epi8(TCP_SYN - 1));
    __mmask64 has_ack = _mm512_cmpgt_epi8_mask(flags_vec, _mm512_set1_epi8(TCP_ACK - 1));
    // ...

    return 0;  // 返回压缩后的标志
}
```

---

## 8. NEON (ARM 向量化)

### 8.1 NEON 架构

```c
// ARM NEON 128-bit 寄存器 (与 SSE 相当)
// 64-bit 和 128-bit 两种模式

// NEON intrinsics (arm_neon.h)

// 64-bit 寄存器 (D0-D31)
typedef uint64x1_t neon64_t;

// 128-bit 寄存器 (Q0-Q31)
typedef uint8x16_t neon128_t;    // 16 x uint8_t
typedef uint16x8_t neon128_16_t; // 8 x uint16_t
typedef uint32x4_t neon128_32_t; // 4 x uint32_t
typedef uint64x2_t neon128_64_t; // 2 x uint64_t

// ARM NEON 等价操作

// 加法
neon128_32_t vaddq_u32(neon128_32_t a, neon128_32_t b);

// 比较
uint32x4_t vcgeq_u32(neon128_32_t a, neon128_32_t b);

// 加载/存储
neon128_t vld1q_u8(const uint8_t *ptr);
void vst1q_u8(uint8_t *ptr, neon128_t value);

// 字节混洗
neon128_t vqtbl1q_u8(neon128_t table, neon128_t index);

// CRC32 (ARMv8-a)
uint32_t vcrc32_32(uint32_t initial, uint32_t value);
```

### 8.2 NEON 包处理示例

```c
// ARM NEON 批量校验和

#include <arm_neon.h>

static uint16_t
csum_neon(const void *data, size_t len)
{
    uint32x4_t sum_vec = vmovq_n_u32(0);
    const uint8_t *ptr = data;

    // 以 16 字节为单位处理
    while (len >= 16) {
        uint8x16_t v = vld1q_u8(ptr);

        // 字节交叉相加 (16-bit 打包)
        uint16x8_t sum_lo = vpaddl_u8(v);
        uint16x8_t sum_hi = vpaddl_u8(vrlq_n_u8(v, 8));
        sum_vec = vpadalq_u16(sum_vec, sum_lo);
        sum_vec = vpadalq_u16(sum_vec, sum_hi);

        ptr += 16;
        len -= 16;
    }

    // 处理剩余
    // ...

    // 水平相加
    uint32_t sum = vgetq_lane_u32(sum_vec, 0) +
                    vgetq_lane_u32(sum_vec, 1) +
                    vgetq_lane_u32(sum_vec, 2) +
                    vgetq_lane_u32(sum_vec, 3);

    return ~sum;
}
```

---

## 9. 性能对比

### 9.1 SIMD 加速比

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        SIMD 加速效果                                        │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  操作                    标量     SSE4.2   AVX2    AVX512   加速比(AVX512) │
│  ──────────────────────────────────────────────────────────────────────────│
│  CRC32C (per byte)      2.5 GB/s  8 GB/s  12 GB/s  18 GB/s    7x        │
│  IP Checksum            1.2 GB/s   4 GB/s   7 GB/s  10 GB/s    8x        │
│  TCP Checksum           1.1 GB/s   4 GB/s   6 GB/s   9 GB/s    8x        │
│  RSS Hash (40B)         50 Mops   200 M   400 Mops  800 Mops  16x        │
│  5-tuple Lookup         30 Mops   100 M   200 Mops  350 Mops  12x        │
│  String Search          100 Mops  300 M   500 Mops  800 Mops   8x        │
│  AES-128-CBC            200 MB/s  800 MB/s 1.5 GB/s 3 GB/s   15x        │
│                                                                             │
│  包处理 (64B packets):                                                    │
│  ─────────────────────                                                      │
│  解析 + 分类 + 转发        5 Mpps   15 Mpps  30 Mpps  55 Mpps  11x        │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 9.2 编译优化建议

```bash
# 启用 SIMD 自动向量化
CFLAGS="-O3 -march=native"

# 手动指定目标架构
CFLAGS="-O3 -mavx512f -mavx512bw -mavx512dq"

# 启用链接时优化 (LTO)
CFLAGS="-O3 -flto -march=native"

# SSE/AVX 选择
# -msse4.2    : 基础向量化 (大多数 CPU)
# -mavx2      : 256-bit 向量 (Haswell+)
# -mavx512f   : 512-bit 向量 (Skylake-SP+)
# -mavx512bw  : 字节/字操作 (重要!)
# -mavx512dq  : 双字/四字操作
```

---

## 10. 小结

本章核心要点：

1. **SIMD 背景**：单条指令处理多个数据，标量 8 操作 vs SIMD 1 指令 8 操作，理论上 8x 加速。

2. **指令集演进**：SSE (128-bit) → AVX2 (256-bit) → AVX512 (512-bit)，以及 ARM NEON (128-bit)。

3. **AVX512 架构**：32 个 ZMM (512-bit) 寄存器 + 32 个 mask (K) 寄存器，支持字节/字/双字/四字操作。

4. **DPDK 向量化框架**：rte_vect 库提供跨平台抽象，rte_zmm_t/rte_ymm_t/rte_xmm_t 类型，运行时 CPU 能力检测。

5. **校验和向量化**：16-bit 反码求和可向量化，CRC32 使用 SSE4.2 的 _mm_crc32_u32/u64 指令。

6. **查找表向量化**：5-tuple 哈希批量计算，ACL 规则范围匹配，AVX512 mask 操作加速比较。

7. **RSS 散列向量化**：Toeplitz 散列函数向量化实现，批量 5-tuple 哈希计算。

8. **数据包解析向量化**：批量 IP 头解析、TCP 标志检测，gather/scatter 操作。

9. **NEON 支持**：ARM 平台的 128-bit 向量，与 SSE 等价，DPDK 跨平台支持。

10. **性能收益**：AVX512 可达 8-16x 加速，使 DPDK 包处理达到 50-100 Mpps。

**下一篇预告**：[[2026-04-09-dpdk-deep-dive-ch21-cryptodev|第二十一章]]将讲解 cryptodev 加密设备与 Crypto PMD——DPDK 的硬件加密加速框架。

---

> [!tip] 参考文献
> - Intel, "Intel Intrinsics Guide", https://software.intel.com/sites/landingpage/IntrinsicsGuide/
> - Intel, "DPDK vect programmer guide", https://doc.dpdk.org/guides/prog_guide/vect_processing.html
> - ARM, "ARM NEON Intrinsics", https://developer.arm.com/architectures/instruction-sets/simd-isas/neon
> - "SIMD in DPDK", https://doc.dpdk.org/guides-21.02/proGuides/optimization.html
