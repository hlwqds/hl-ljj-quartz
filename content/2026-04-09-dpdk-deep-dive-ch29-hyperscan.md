---
title: "DPDK 深度探索 ch29：Hyperscan 集成"
date: 2026-04-10 10:00:00
tags: [dpdk, hyperscan, pattern-matching, regexp, dpi, intel, simd]
description: "深入解析 DPDK Hyperscan 集成：正则匹配、SIMD 加速、模式数据库、DPI 应用与性能优化"
---

# DPDK 深度探索 ch29：Hyperscan 集成

> [!abstract] 核心要点
> Hyperscan 是 Intel 的高性能正则匹配库。本章深入解析 Hyperscan 架构、SIMD 加速、DPDK 集成与 DPI 应用。

## 1. Hyperscan 概述

### 1.1 什么是 Hyperscan

```
Hyperscan: Intel 正则匹配库

特点：
- 基于 x86 SIMD (SSE/AVX)
- 支持多个模式并行匹配
- 软甲架构纯软件实现
- 最高性能正则匹配

应用场景：
- 深度包检测 (DPI)
- IDS/IPS (Suricata, Snort)
- 防火墙规则匹配
- 数据包分类
```

### 1.2 Hyperscan vs AC 自动机

| 特性       | AC 自动机    | Hyperscan      |
| ---------- | ------------ | -------------- |
| **算法**   | Aho-Corasick | NFA/DFA hybrid |
| **SIMD**   | 可选         | 原生支持       |
| **模式数** | 数千         | 数十万         |
| **吞吐量** | ~2-5 Gbps    | ~10-20 Gbps    |
| **内存**   | 中           | 低             |

## 2. Hyperscan 架构

### 2.1 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    Hyperscan 架构                            │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              Pattern Database                         │  │
│  │  - 编译多个正则表达式                                │  │
│  │  - NFA/DFA hybrid                                    │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              Streaming Mode                            │  │
│  │  - 跨数据包状态保存                                  │  │
│  │  - Scratch area                                      │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              Vector Primitive (VP)                   │  │
│  │  - SIMD 向量化                                       │  │
│  │  - NFA/DFA 表达式                                    │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              Intel SIMD (SSE/AVX)                     │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 模式编译

```c
#include <hs.h>

// 编译模式数据库
int
compile_patterns(void)
{
    // 模式数组
    hs_expr_t *expressions[] = {
        "http://[^\\s]*",           // HTTP URL
        "src=([0-9.]+)",            // IP 地址
        "Host:.*\\.example\\.com", // 特定域名
    };

    const char *patterns[] = {
        "http://[^\\s]*",           // 描述符 0
        "src=([0-9.]+)",            // 描述符 1
        "Host:.*\\.example\\.com", // 描述符 2
    };

    unsigned flags[] = {
        HS_FLAG_SINGLEMATCH,        // 单次匹配
        HS_FLAG_CASELESS,           // 不区分大小写
        0,
    };

    unsigned ids[] = {1, 2, 3};

    // 编译数据库
    hs_database_t *db;
    hs_compile_error_t *compile_err;

    hs_error_t err = hs_compile_ext_multi(
        patterns,      // 模式数组
        flags,         // 标志
        ids,           // ID
        3,             // 模式数
        HS_MODE_STREAM | HS_MODE_SOM_HORIZON,
        NULL,          // allocator
        &db,
        &compile_err
    );

    if (err != HS_SUCCESS) {
        fprintf(stderr, "Compile error: %s\n",
                compile_err->message);
        return -1;
    }

    return 0;
}
```

## 3. 匹配模式

### 3.1 流模式 (Streaming)

```c
// 流模式 - 跨数据包状态保持
// 适合 TCP 流重组

struct stream_context {
    hs_stream_t *stream;
    // 其他上下文信息
};

// 打开流
hs_stream_t *
open_stream(hs_database_t *db, uint64_t flags)
{
    hs_stream_t *stream;
    hs_open_stream(db, flags, &stream);
    return stream;
}

// 扫描数据
int
scan_stream(hs_stream_t *stream,
            const uint8_t *data,
            size_t len,
            void *ctx)
{
    return hs_scan_stream(stream, data, len, 0, ctx,
                          match_event, NULL);
}

// 关闭流
void
close_stream(hs_stream_t *stream)
{
    hs_close_stream(stream, NULL, NULL);
}
```

### 3.2 向量模式 (Vectored)

```c
// 向量模式 - 单次扫描多个模式
// 适合独立数据包

// 匹配回调
int
match_event(unsigned int id,
            unsigned long long from,
            unsigned long long to,
            unsigned int flags,
            void *ctx)
{
    printf("Match: pattern %u, offset %llu-%llu\n",
           id, from, to);
    return 0;  // 继续匹配
}

// 向量扫描
int
scan_vectored(hs_database_t *db,
               const uint8_t **data,
               size_t *len,
               int count,
               void *ctx)
{
    return hs_scan_vector(db, data, len, count,
                         0, ctx, match_event, NULL);
}
```

### 3.3 数据库模式 (Block)

```c
// 数据库模式 - 纯块扫描
// 最简单，性能最高

int
scan_block(hs_database_t *db,
           const uint8_t *data,
           size_t len,
           void *ctx)
{
    return hs_scan(db, data, len, 0, ctx,
                  match_event, NULL);
}
```

## 4. DPDK 集成

### 4.1 集成架构

```
┌─────────────────────────────────────────────────────────────┐
│                    DPDK + Hyperscan                         │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              DPDK Pipeline                            │  │
│  │                                                       │  │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐            │  │
│  │  │nic (PMD)│→│ classifier│→│ Hyperscan│           │  │
│  │  └─────────┘  └─────────┘  └─────────┘            │  │
│  │                                    ↓                  │  │
│  │                              ┌─────────┐            │  │
│  │                              │ Action  │            │  │
│  │                              └─────────┘            │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 PMD 设计

```c
// dpdk_hyperscan.c

#include <rte_eal.h>
#include <rte_mbuf.h>
#include <hs.h>

struct hs_pmd_ctx {
    hs_database_t *db;
    hs_scratch_t *scratch;  // 临时匹配区

    // 流表
    struct rte_hash *flow_table;
};

struct hs_pmd_ctx ctx;

// 初始化
int
hs_pmd_init(void)
{
    // 编译数据库
    const char *patterns[] = {"malware", "backdoor", "exploit"};
    hs_compile_multi(patterns, NULL, 3,
                     HS_MODE_BLOCK, NULL, &ctx.db, NULL);

    // 分配 scratch
    hs_alloc_scratch(ctx.db, &ctx.scratch);

    // 创建流表
    struct rte_hash_parameters flow_params = {
        .name = "hs_flow_table",
        .entries = 65536,
        .key_len = sizeof(uint32_t),
    };
    ctx.flow_table = rte_hash_create(&flow_params);

    return 0;
}

// 处理包
int
hs_pmd_process(struct rte_mbuf *mbuf)
{
    uint8_t *data = rte_pktmbuf_mtod(mbuf, uint8_t *);
    uint32_t len = rte_pktmbuf_data_len(mbuf);

    // 获取/创建流上下文
    uint32_t flow_id = get_flow_id(mbuf);
    hs_stream_t *stream = get_stream(ctx.flow_table, flow_id);

    // 扫描
    int result = hs_scan_stream(stream, data, len, 0,
                                 &ctx, match_event, NULL);

    return result;
}
```

### 4.3 Flow Classification 集成

```c
// Hyperscan 用于流分类
struct rte_flow_classifier *
create_hs_classifier(void)
{
    struct rte_flow_classifier *cls;

    // 创建分类器
    struct rte_flow_classifier_params cls_params = {
        .table_type = RTE_FLOW_CLASSIFIER_TABLE_TYPE_ACL,
    };

    cls = rte_flow_classifier_create(&cls_params);

    // 添加 Hyperscan 作为 action
    struct rte_flow_action_hs hs_action = {
        .db = ctx.db,
        .scratch = ctx.scratch,
    };

    return cls;
}
```

## 5. SIMD 加速

### 5.1 SIMD 原理

```
┌─────────────────────────────────────────────────────────────┐
│                    SIMD 加速原理                            │
│                                                              │
│  传统标量 (一次处理1个):                                     │
│    Pattern: A        Pattern: B        Pattern: C           │
│    Data: x                                        │           │
│    Compare: x==A?                               │           │
│                                                          │           │
│  SIMD (一次处理16/32个):                                │           │
│    Pattern: ABCDEFGHIJKLMNOP                         │           │
│    Data:    xxxxxxxxxxxxxxxxxx                        │           │
│    Compare: CMP each in parallel                      │           │
│                        ↓                                │
│              16x-32x 性能提升                          │
└─────────────────────────────────────────────────────────────┘
```

### 5.2 AVX2/AVX-512

```c
// Hyperscan 自动使用可用的最高 SIMD 级别

// SSE (128-bit, 16 bytes/cycle)
#define HS_SSE

// AVX2 (256-bit, 32 bytes/cycle)
#define HS_AVX2

// AVX-512 (512-bit, 64 bytes/cycle)
#define HS_AVX512

// 检测 SIMD 能力
void
detect_simd(void)
{
#ifdef __AVX512F__
    printf("Using AVX-512\n");
#elif defined(__AVX2__)
    printf("Using AVX-2\n");
#elif defined(__SSE4_2__)
    printf("Using SSE 4.2\n");
#endif
}
```

## 6. DPI 应用

### 6.1 HTTP 检测

```c
// HTTP DPI 示例
const char *http_patterns[] = {
    "GET /[^\\s]*HTTP/1\\.[01]",   // GET 请求
    "POST /[^\\s]*HTTP/1\\.[01]",  // POST 请求
    "Host: ([^\\r\\n]+)",          // Host 头
    "User-Agent: ([^\\r\\n]+)",   // UA
    "Content-Length: ([0-9]+)",    // 内容长度
};

struct http_info {
    char host[256];
    char user_agent[256];
    int content_length;
};

int
http_match(unsigned id, unsigned long long from,
           unsigned long long to, unsigned flags, void *ctx)
{
    struct http_info *info = ctx;

    switch (id) {
    case 1:  // Host
        snprintf(info->host, sizeof(info->host),
                "matched at %llu", from);
        break;
    case 2:  // User-Agent
        snprintf(info->user_agent, sizeof(info->user_agent),
                "matched at %llu", from);
        break;
    }
    return 0;
}
```

### 6.2 TLS 检测

```c
// TLS DPI
const char *tls_patterns[] = {
    "\\x16\\x03[:\\x01]...",        // TLS Handshake
    "Server Name: ([^\\x00-\\x1f]+)", // SNI
    "Certificate",                   // 证书
    "\\x14\\x03[:\\x01]...",        // TLS Finished
};
```

## 7. 性能调优

### 7.1 编译器选项

```bash
# Hyperscan 编译优化
export CFLAGS="-O3 -march=native -ffast-math"

# 启用 CPU 特定指令
# -msse4.2 (SSE 4.2)
# -mavx2 (AVX2)
# -mavx512f -mavx512bw (AVX-512)
```

### 7.2 Scratch 区域

```c
// Scratch 区域复用
// 每个线程独立的 scratch，避免锁

struct thread_local {
    hs_scratch_t *scratch;
};

struct thread_local *
alloc_thread_local(hs_database_t *db)
{
    struct thread_local *tl = malloc(sizeof(*tl));
    hs_alloc_scratch(db, &tl->scratch);
    return tl;
}

// 匹配时复用 scratch
void
scan_batch(struct thread_local *tl,
           struct rte_mbuf **pkts,
           int n)
{
    for (int i = 0; i < n; i++) {
        uint8_t *data = rte_pktmbuf_mtod(pkts[i], uint8_t *);
        size_t len = rte_pktmbuf_data_len(pkts[i]);

        hs_scan(db, data, len, 0, tl->scratch,
               match_callback, NULL);
    }
}
```

## 8. 总结

Hyperscan 性能：

```
┌─────────────────────────────────────────────────────────────┐
│                    Hyperscan 性能                           │
│                                                              │
│  吞吐量：                                                   │
│  - 单核 SSE: ~2-4 Gbps                                     │
│  - 单核 AVX2: ~5-8 Gbps                                    │
│  - 单核 AVX-512: ~10-15 Gbps                               │
│                                                              │
│  模式数：                                                   │
│  - 支持 10,000+ 模式同时匹配                               │
│                                                              │
│  延迟：                                                     │
│  - ~10-20ns per pattern                                    │
└─────────────────────────────────────────────────────────────┘
```

DPDK 集成模式：

| 模式          | 适用场景 | 性能 |
| ------------- | -------- | ---- |
| **Block**     | 独立包   | 最高 |
| **Streaming** | TCP 流   | 中   |
| **Vectored**  | 批量包   | 高   |

---

## 参考资源

- [Intel Hyperscan](https://www.intel.com/content/www/us/en/developer/articles/technical/introduction-to-hyperscan.html)
- [Hyperscan GitHub](https://github.com/intel/hyperscan)
- [Hyperscan API](https://intel.github.io/hyperscan/)
