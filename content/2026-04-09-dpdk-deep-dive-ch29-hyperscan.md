---
title: "DPDK 深度探索 (二十九)：Hyperscan 高性能正则匹配"
date: 2026-04-10 10:00:00
tags: [dpdk, series, hyperscan, pattern-matching, regexp, dpi, intel, simd, vectorscan]
description: "深入解析 Hyperscan 正则匹配引擎：NFA/DFA 混合引擎、SIMD 向量化、三种扫描模式、DPDK DPI 集成与性能优化"
---

> [!info] DPDK 深度探索系列
> 0. [[2026-04-09-dpdk-deep-dive-series-index|全栈学习路径总览]]
> 1-28. 前二十八章已完成
> 29. **第二十九章：Hyperscan 高性能正则匹配**

---

## 1. Hyperscan 概述

### 1.1 什么是 Hyperscan

Hyperscan 是 Intel 开源的高性能正则表达式匹配库，专为网络深度包检测（DPI）场景设计。它利用 x86 SIMD 指令（SSE4.2 / AVX2 / AVX-512）实现多模式并行匹配，单核可达数十 Gbps 吞吐量。

2022 年 Intel 停止维护后，社区 fork 出 **Vectorscan** 项目（由 Vectorcamp 主导），保持 API 兼容并扩展了对 ARM NEON/SVE 的支持。以下内容以 Hyperscan API 为主，Vectorscan API 完全兼容。

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    Hyperscan 核心特点                                   │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  1. 纯软件实现，不需要专用硬件                                        │
│  2. 支持数万到数十万条正则同时匹配                                    │
│  3. 利用 SIMD 指令并行处理多个模式                                    │
│  4. 三种扫描模式: Block / Streaming / Vectored                         │
│  5. 编译期与运行期分离: 模式数据库只需编译一次                       │
│  6. 数据库只读，可跨进程共享; scratch 空间 per-thread                │
│                                                                         │
│  典型应用:                                                              │
│  ┌──────────────────────────────────────────────────────────────┐       │
│  │  Suricata / Snort (IDS/IPS)     → 入侵检测规则匹配         │       │
│  │  L7 协议识别                    → HTTP/TLS/DNS 协议解析     │       │
│  │  DDoS 防护                      → 恶意载荷特征检测         │       │
│  │  数据防泄漏 (DLP)              → 敏感信息模式匹配         │       │
│  └──────────────────────────────────────────────────────────────┘       │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 1.2 Hyperscan vs 传统方案

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    正则匹配方案对比                                     │
├──────────────┬──────────────┬──────────────┬──────────────────────────┤
│              │ Aho-Corasick │ Hyperscan    │ PCRE (libpcre)          │
├──────────────┼──────────────┼──────────────┼──────────────────────────┤
│ 匹配对象     │ 固定字符串   │ 正则表达式   │ 正则表达式              │
│ 算法         │ Trie + BFS   │ NFA/DFA 混合 │ 回溯 (backtracking)     │
│ SIMD 加速    │ 无           │ 原生支持     │ 无                      │
│ 模式数       │ 数千         │ 数万~数十万  │ 1 (逐个匹配)            │
│ 吞吐量       │ ~2-5 Gbps    │ ~10-70 Gbps  │ ~0.1-0.5 Gbps           │
│ 内存占用     │ 中           │ 低~中        │ 低                      │
│ 跨包匹配     │ 不支持       │ 支持(流模式) │ 需自己实现              │
│ 表达能力     │ 仅字面量     │ 正则子集     │ 完整正则                │
│ 适用场景     │ 精确匹配     │ DPI/IDS      │ 通用正则                │
└──────────────┴──────────────┴──────────────┴──────────────────────────┘

关键区别:
- Aho-Corasick: 只匹配固定字符串，不能匹配 "http://[^\s]*" 这种模式
- PCRE: 功能强大但回溯算法导致 O(2^n) 最坏情况，不适合高速数据面
- Hyperscan: 功能和性能的平衡——支持正则子集，用 SIMD + NFA 保证线速
```

---

## 2. Hyperscan 架构

### 2.1 编译期与运行期分离

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    Hyperscan 两阶段架构                                 │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  阶段一: 编译期 (离线，只需一次)                                      │
│  ═════════════════════════════════                                     │
│                                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │  正则表达式 (PCRE 子集)                                        │    │
│  │    "GET /[^\s]*HTTP/1\.[01]"                                   │    │
│  │    "Host: [^\r\n]+"                                            │    │
│  │    "malware_signature_[0-9]+"                                  │    │
│  └──────────────────────────┬──────────────────────────────────────┘    │
│                             │ hs_compile_multi()                        │
│                             ▼                                          │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │  编译器 (hs_compiler)                                          │    │
│  │                                                                 │    │
│  │  1. 解析正则 → NFA (非确定性有限自动机)                       │    │
│  │  2. NFA 优化: 简化、合并等价状态                               │    │
│  │  3. 部分状态转换为 DFA (确定性有限自动机)                      │    │
│  │     → 热点路径用 DFA (确定性高、查表快)                       │    │
│  │     → 冷门路径保留 NFA (省内存、避免状态爆炸)                 │    │
│  │  4. 为 SIMD 向量化生成字节码 (Rose Engine)                    │    │
│  │                                                                 │    │
│  └──────────────────────────┬──────────────────────────────────────┘    │
│                             │                                          │
│                             ▼                                          │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │  hs_database_t (模式数据库)                                    │    │
│  │                                                                 │    │
│  │  - 只读、可序列化、可跨进程共享                               │    │
│  │  - 包含所有 NFA/DFA/SIMD 字节码                               │    │
│  │  - 编译一次，运行时反复使用                                    │    │
│  └─────────────────────────────────────────────────────────────────┘    │
│                                                                         │
│  阶段二: 运行期 (数据面，每包调用)                                    │
│  ═════════════════════════════════                                     │
│                                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │  hs_database_t (只读)                                          │    │
│  │         │                                                       │    │
│  │         ▼                                                       │    │
│  │  hs_scratch_t (per-thread 临时空间)                             │    │
│  │         │                                                       │    │
│  │         ▼                                                       │    │
│  │  Rose Engine (SIMD 向量化执行)                                 │    │
│  │    ┌──────────────────────────────────────────────────────┐    │    │
│  │    │  输入数据流 → SIMD 字节比较 → NFA/DFA 状态转移     │    │    │
│  │    │  SSE4.2: 16 字节/周期                               │    │    │
│  │    │  AVX2:   32 字节/周期                               │    │    │
│  │    │  AVX-512: 64 字节/周期                              │    │    │
│  │    └──────────────────────────────────────────────────────┘    │    │
│  │         │                                                       │    │
│  │         ▼                                                       │    │
│  │  匹配回调 (match_event_handler)                                │    │
│  └─────────────────────────────────────────────────────────────────┘    │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 2.2 Rose Engine：SIMD 加速的核心

Hyperscan 的 SIMD 加速不是简单的"一次比较多个字符"，而是通过 **Rose Engine** 实现了更复杂的向量化策略：

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    Rose Engine 的 SIMD 策略                             │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  策略 1: 字符类位图 (Character Class Bitmap)                          │
│  ──────────────────────────────────────────                             │
│                                                                         │
│  模式 "[0-9a-fA-F]+" (十六进制数字)                                   │
│  → 编译成 256-bit 位图: 第 0-9, a-f, A-F 位 = 1                      │
│  → AVX2 一次检查 32 字节中每个是否匹配                                │
│                                                                         │
│  输入: 3 A f 0 x 1 B 2 ... (32 bytes)                                  │
│  位图: 1 1 1 1 0 1 1 1 ... (SIMD 并行查表)                            │
│  结果: 连续 1 的位置就是匹配区间                                       │
│                                                                         │
│  策略 2: 换行符/定界符加速 (Literal Acceleration)                     │
│  ───────────────────────────────────────────────                        │
│                                                                         │
│  很多模式的触发点只在特定字符之后 (如 HTTP 头在 \r\n 之后)             │
│  → 先用 SIMD 快速扫描 \r\n 位置                                       │
│  → 只在候选位置附近启动完整 NFA 匹配                                  │
│  → 大幅减少无谓的状态转移                                             │
│                                                                         │
│  策略 3: 稀疏/密集 NFA 选择                                           │
│  ──────────────────────────────                                         │
│                                                                         │
│  稀疏 NFA (活动状态少):                                               │
│    → 用 SIMD 位掩码跟踪活跃状态，只处理活跃部分                      │
│    → 省内存、省计算                                                   │
│                                                                         │
│  密集 NFA (活动状态多):                                               │
│    → 转成 DFA 查表，一次查表确定所有状态的转移                       │
│    → 速度快但内存大                                                   │
│                                                                         │
│  Hyperscan 根据编译期分析自动选择最佳策略                             │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 3. 模式编译

### 3.1 基本编译

```c
#include <hs.h>

// 编译多个正则表达式到模式数据库
hs_database_t *
compile_pattern_db(void)
{
    const char *patterns[] = {
        "GET /[^\\s]*HTTP/1\\.[01]",     // HTTP GET 请求
        "Host: [^\\r\\n]+",              // Host 头
        "malware_sig_[0-9]+",            // 恶意特征
    };

    unsigned int flags[] = {
        HS_FLAG_CASELESS,                 // 不区分大小写
        HS_FLAG_CASELESS | HS_FLAG_SINGLEMATCH, // 大小写不敏感 + 只报告首次
        0,                                // 默认标志
    };

    unsigned int ids[] = {100, 200, 300};  // 每个模式的唯一 ID

    hs_database_t *db = NULL;
    hs_compile_error_t *compile_err = NULL;

    // hs_compile_multi: 编译多个模式到数据库
    //   patterns  → 正则表达式数组
    //   flags     → 每个模式的标志
    //   ids       → 每个模式的 ID
    //   elements  → 模式数量
    //   mode      → HS_MODE_BLOCK / HS_MODE_STREAM / HS_MODE_VECTORED
    //   platform  → NULL = 自动检测当前 CPU
    //   db        → 输出: 编译后的数据库
    //   error     → 输出: 编译错误信息
    hs_error_t err = hs_compile_multi(
        patterns, flags, ids, 3,
        HS_MODE_BLOCK,    // 块模式: 每次扫描独立的数据块
        NULL,             // platform: NULL = 本机
        &db,
        &compile_err
    );

    if (err != HS_SUCCESS) {
        fprintf(stderr, "compile error: %s\n", compile_err->message);
        hs_free_compile_error(compile_err);
        return NULL;
    }

    return db;
}
```

### 3.2 常用编译标志

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    Hyperscan 编译标志                                   │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  HS_FLAG_CASELESS        忽略大小写                                    │
│  HS_FLAG_DOTALL          . 匹配换行符                                  │
│  HS_FLAG_MULTILINE       ^/$ 匹配每行的开头/结尾                      │
│  HS_FLAG_SINGLEMATCH     每个模式只报告第一个匹配 (减少回调)          │
│  HS_FLAG_ALLOWEMPTY      允许匹配空字符串                              │
│  HS_FLAG_UTF8            UTF-8 模式                                   │
│  HS_FLAG_UCP             Unicode 字符属性 (\w 匹配中文等)            │
│  HS_FLAG_PREFILTER       宽松匹配模式，用于预筛选                     │
│                         (可能产生假阳性，需二次验证)                  │
│  HS_FLAG_SOM_LEFTMOST    报告匹配的起始位置 (Start of Match)          │
│                                                                         │
│  SOM (Start of Match) 说明:                                            │
│  ──────────────────────────                                             │
│  默认只报告匹配结束位置 (to)                                          │
│  设置 HS_FLAG_SOM_LEFTMOST 后同时报告起始位置 (from)                  │
│  用于提取完整匹配内容                                                  │
│  注意: 开启 SOM 会增加状态跟踪开销                                    │
│                                                                         │
│  运行模式 (编译时选择，运行时不可切换):                               │
│  ┌──────────────────┬──────────────────────────────────────────┐        │
│  │ HS_MODE_BLOCK    │ 每次扫描独立数据块，无跨块状态        │        │
│  │ HS_MODE_STREAM   │ 流模式，维护跨块匹配状态               │        │
│  │ HS_MODE_VECTORED │ 向量模式，一次扫描多个不连续缓冲区     │        │
│  └──────────────────┴──────────────────────────────────────────┘        │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 3.3 数据库序列化

```c
// 编译后的数据库可以序列化保存到磁盘
// 下次直接反序列化加载，跳过编译过程

// 序列化
int
save_database(hs_database_t *db, const char *path)
{
    char *bytes = NULL;
    size_t len = 0;

    hs_error_t err = hs_serialize_database(db, &bytes, &len);
    if (err != HS_SUCCESS)
        return -1;

    FILE *f = fopen(path, "wb");
    fwrite(bytes, 1, len, f);
    fclose(f);
    free(bytes);

    return 0;
}

// 反序列化
hs_database_t *
load_database(const char *path)
{
    // 读取文件到 buffer ...
    char *bytes = read_file(path, &len);

    hs_database_t *db = NULL;
    hs_error_t err = hs_deserialize_database(bytes, len, &db);
    free(bytes);

    if (err != HS_SUCCESS)
        return NULL;

    return db;
}
```

---

## 4. 三种扫描模式

### 4.1 Block 模式（独立数据块）

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Block 模式: 每次扫描独立的数据块，块之间无状态                     │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  适用: 独立数据包、日志行、固定大小记录                              │
│  性能: 最高（无状态管理开销）                                         │
│                                                                         │
│  ┌──────┐   ┌──────┐   ┌──────┐   ┌──────┐                          │
│  │ pkt1 │   │ pkt2 │   │ pkt3 │   │ pkt4 │                          │
│  │      │   │      │   │      │   │      │                          │
│  │scan()│   │scan()│   │scan()│   │scan()│                          │
│  └──┬───┘   └──┬───┘   └──┬───┘   └──┬───┘                          │
│     │          │          │          │                                  │
│     │  独立    │  独立    │  独立    │  独立                          │
│     ▼          ▼          ▼          ▼                                  │
│  [match?]  [match?]  [match?]  [match?]                                │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

```c
// 匹配回调函数
// 返回 0 = 继续扫描, 非 0 = 终止扫描
static int
on_match(unsigned int id, unsigned long long from,
         unsigned long long to, unsigned int flags, void *ctx)
{
    printf("pattern %u matched at [%llu, %llu)\n", id, from, to);
    return 0;
}

// Block 模式扫描
void
scan_block_mode(hs_database_t *db)
{
    // 分配 scratch 空间 (per-thread)
    hs_scratch_t *scratch = NULL;
    hs_alloc_scratch(db, &scratch);

    const char *data = "GET /index.html HTTP/1.1\r\nHost: example.com";
    size_t len = strlen(data);

    // hs_scan: Block 模式扫描
    //   db       → 模式数据库
    //   data     → 输入数据
    //   length   → 数据长度
    //   flags    → 保留，传 0
    //   scratch  → 临时空间 (per-thread，不可跨线程共享)
    //   handler  → 匹配回调
    //   context  → 传给回调的用户上下文
    hs_error_t err = hs_scan(db, data, len, 0,
                              scratch, on_match, NULL);

    // 释放 scratch
    hs_free_scratch(scratch);
}
```

### 4.2 Streaming 模式（跨数据包）

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Streaming 模式: 维护跨数据包的匹配状态                              │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  适用: TCP 流重组后的协议解析、跨包正则匹配                          │
│  性能: 中等（需要状态管理）                                           │
│                                                                         │
│  TCP 流:                                                               │
│                                                                         │
│  ┌─────────────────────────────────────────────────────┐               │
│  │  pkt1: "GET /index"    pkt2: ".html HT"   pkt3: "TP/1.1\r\n" │   │
│  └─────────────────────────────────────────────────────┘               │
│                                                                         │
│  模式: "GET /[^\s]*HTTP/1\.[01]"                                      │
│  ↓ 这个模式横跨了 3 个数据包!                                       │
│                                                                         │
│  ┌──────────┐   ┌──────────┐   ┌──────────┐                          │
│  │  pkt 1   │   │  pkt 2   │   │  pkt 3   │                          │
│  │  "GET /  │   │  index.  │   │  html HT │   ...                    │
│  │  index"  │   │  html HT"│   │  TP/1.1" │                          │
│  └────┬─────┘   └────┬─────┘   └────┬─────┘                          │
│       │              │              │                                  │
│  open_stream()  scan_stream()  scan_stream()  close_stream()          │
│       │              │              │              │                   │
│       │  状态保存 →  │  状态保存 →  │  状态保存 →  │                  │
│       │              │              │              │                   │
│       │              │              │              ▼                   │
│       │              │              │         匹配回调触发!           │
│       │              │              │         (跨包匹配成功)          │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

```c
// Streaming 模式需要 hs_scratch_t 用于 scan 和 close
void
scan_streaming_mode(hs_database_t *db)
{
    hs_scratch_t *scratch = NULL;
    hs_alloc_scratch(db, &scratch);

    // 1. 打开流
    hs_stream_t *stream = NULL;
    hs_open_stream(db, 0, &stream);

    // 2. 逐包扫描 (模拟 TCP 流)
    const char *chunks[] = {
        "GET /index",
        ".html HT",
        "TP/1.1\r\nHost: example.com\r\n\r\n",
    };

    for (int i = 0; i < 3; i++) {
        hs_scan_stream(stream, chunks[i], strlen(chunks[i]),
                        0, scratch, on_match, NULL);
    }

    // 3. 关闭流 (刷新剩余状态，可能触发最后的匹配)
    hs_close_stream(stream, scratch, on_match, NULL);

    hs_free_scratch(scratch);
}
```

### 4.3 Vectored 模式（多缓冲区）

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Vectored 模式: 一次扫描多个不连续的缓冲区                           │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  适用: 数据分散在多个 mbuf segment 中，无需拼接到连续内存            │
│  性能: 高（避免了 memcpy）                                             │
│                                                                         │
│  mbuf 链:                                                              │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐                         │
│  │ segment 1│───→│ segment 2│───→│ segment 3│                         │
│  │ "GET /"  │    │ "index"  │    │ ".html"  │                         │
│  └──────────┘    └──────────┘    └──────────┘                         │
│       │               │               │                                │
│       └───────────────┴───────────────┘                                │
│                       │                                                 │
│              hs_scan_vector(data[], len[], 3)                           │
│              一次扫描，逻辑上等同于连续内存                           │
│                                                                         │
│  vs Block 模式:                                                        │
│  Block:  需要 memcpy 把所有 segment 拼成连续 buffer → 再 scan         │
│  Vectored: 直接传指针数组，零拷贝扫描                                 │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

```c
// Vectored 模式: 扫描分散在多个缓冲区中的数据
void
scan_vectored_mode(hs_database_t *db, struct rte_mbuf *m)
{
    hs_scratch_t *scratch = NULL;
    hs_alloc_scratch(db, &scratch);

    // 从 mbuf 链中提取各 segment 的指针和长度
    const char *data[16];
    unsigned int lengths[16];
    int count = 0;

    struct rte_mbuf *seg = m;
    while (seg && count < 16) {
        data[count] = rte_pktmbuf_mtod(seg, const char *);
        lengths[count] = rte_pktmbuf_data_len(seg);
        count++;
        seg = seg->next;
    }

    // hs_scan_vector: Vectored 模式扫描
    //   db      → 模式数据库
    //   data    → 缓冲区指针数组
    //   length  → 各缓冲区长度数组
    //   count   → 缓冲区数量
    //   flags   → 保留，传 0
    //   scratch → per-thread 临时空间
    //   handler → 匹配回调
    //   context → 用户上下文
    hs_scan_vector(db, data, lengths, count, 0,
                    scratch, on_match, NULL);

    hs_free_scratch(scratch);
}
```

### 4.4 三种模式对比

| 模式 | 跨数据状态 | 适用场景 | 性能 | 状态管理 |
|------|-----------|---------|------|---------|
| **Block** | 无 | 独立包、日志行 | 最高 | 无 |
| **Streaming** | 有 | TCP 流、协议解析 | 中 | open/close stream |
| **Vectored** | 无 | 多 segment mbuf | 高 | 无 |

---

## 5. DPDK 集成

### 5.1 集成架构

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    DPDK + Hyperscan DPI 架构                            │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │  控制面 (master lcore)                                           │  │
│  │                                                                   │  │
│  │  规则管理 → hs_compile_multi() → hs_database_t                   │  │
│  │                                ↓                                  │  │
│  │              hs_serialize_database() → 共享内存 / rte_ring       │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│                                                                         │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │  数据面 (worker lcore × N)                                       │  │
│  │                                                                   │  │
│  │  每个 worker 独立持有:                                            │  │
│  │  - hs_database_t *db     (只读，可共享)                         │  │
│  │  - hs_scratch_t *scratch (per-thread，不可共享)                  │  │
│  │  - 流表 (per-thread 或共享)                                      │  │
│  │                                                                   │  │
│  │  ┌─────────┐   ┌──────────┐   ┌──────────┐   ┌─────────┐     │  │
│  │  │  PMD    │→ │ 流表查找 │→ │ Hyperscan│→ │ Action  │     │  │
│  │  │ Rx/Tx   │   │ (5-tuple)│   │  scan    │   │ forward │     │  │
│  │  └─────────┘   └──────────┘   └──────────┘   └─────────┘     │  │
│  │                                                                   │  │
│  │  多线程模型:                                                      │  │
│  │  ┌──────────────────────────────────────────────────────────┐    │  │
│  │  │  database: 多线程只读共享 ✅ (编译后不可变)              │    │  │
│  │  │  scratch:  每个 thread 独立持有 ❌ (不可跨线程)          │    │  │
│  │  │  stream:   每个 TCP 流独立持有 ❌ (不可跨线程)           │    │  │
│  │  └──────────────────────────────────────────────────────────┘    │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 5.2 DPI Pipeline 实现

```c
// dpdk_hyperscan_dpi.c

#include <rte_eal.h>
#include <rte_mbuf.h>
#include <rte_hash.h>
#include <hs.h>

// DPI 上下文
struct dpi_ctx {
    hs_database_t *db;
    hs_scratch_t *scratch;       // per-thread
    struct rte_hash *flow_table; // 流表
};

// 流状态
struct dpi_flow {
    uint32_t src_ip, dst_ip;
    uint16_t src_port, dst_port;
    uint8_t proto;
    hs_stream_t *hs_stream;     // Hyperscan 流
    uint64_t last_seen;
};

// 匹配回调
static int
dpi_on_match(unsigned int id, unsigned long long from,
             unsigned long long to, unsigned int flags, void *ctx)
{
    struct dpi_flow *flow = ctx;

    // 根据匹配的模式 ID 执行动作
    switch (id) {
    case 100:  // HTTP 检测
        printf("HTTP detected in flow %x:%u→%x:%u\n",
               flow->src_ip, flow->src_port,
               flow->dst_ip, flow->dst_port);
        break;
    case 200:  // 恶意特征
        printf("ALERT: malware signature %u in flow %x→%x\n",
               id, flow->src_ip, flow->dst_ip);
        break;
    }

    return 0;  // 继续扫描
}

// 初始化 (每个 worker lcore 调用一次)
struct dpi_ctx *
dpi_init(hs_database_t *shared_db, unsigned int lcore_id)
{
    struct dpi_ctx *ctx = rte_malloc(NULL, sizeof(*ctx),
                                      RTE_CACHE_LINE_SIZE);

    // 数据库: 只读共享
    ctx->db = shared_db;

    // scratch: 每个 lcore 独立分配
    ctx->scratch = NULL;
    hs_alloc_scratch(ctx->db, &ctx->scratch);

    // 流表: per-lcore 避免锁竞争
    char name[64];
    snprintf(name, sizeof(name), "flow_%u", lcore_id);

    struct rte_hash_parameters params = {
        .name = name,
        .entries = 65536,
        .key_len = sizeof(struct dpi_flow) - offsetof(struct dpi_flow, src_ip),
        .socket_id = rte_lcore_to_socket_id(lcore_id),
    };
    ctx->flow_table = rte_hash_create(&params);

    return ctx;
}

// 处理单个包
void
dpi_process_packet(struct dpi_ctx *ctx, struct rte_mbuf *m)
{
    // 解析 5-tuple (简化)
    struct dpi_flow flow_key = {0};
    parse_5tuple(m, &flow_key);

    // 查找或创建流
    struct dpi_flow *flow = NULL;
    int ret = rte_hash_lookup_data(ctx->flow_table,
                                    &flow_key.src_ip, (void **)&flow);

    if (ret < 0) {
        // 新流: 创建 Hyperscan stream
        flow = rte_malloc(NULL, sizeof(*flow), 0);
        *flow = flow_key;
        hs_open_stream(ctx->db, 0, &flow->hs_stream);
        rte_hash_add_key_data(ctx->flow_table,
                               &flow_key.src_ip, flow);
    }

    flow->last_seen = rte_get_tsc_cycles();

    // 扫描 payload
    uint8_t *payload = rte_pktmbuf_mtod(m, uint8_t *) +
                        sizeof(struct rte_ether_hdr) +
                        sizeof(struct rte_ipv4_hdr) +
                        sizeof(struct rte_tcp_hdr);
    size_t payload_len = rte_pktmbuf_data_len(m) -
                          sizeof(struct rte_ether_hdr) -
                          sizeof(struct rte_ipv4_hdr) -
                          sizeof(struct rte_tcp_hdr);

    // Streaming 模式扫描: 跨包匹配
    hs_scan_stream(flow->hs_stream, (const char *)payload,
                    payload_len, 0, ctx->scratch,
                    dpi_on_match, flow);
}
```

---

## 6. 性能优化

### 6.1 Scratch 空间管理

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    Scratch 空间规则                                    │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌──────────────────────────────────────────────────────────────┐       │
│  │                                                              │       │
│  │  规则 1: 每个 thread 必须有自己的 scratch                    │       │
│  │  → hs_scratch_t 不可跨线程使用                              │       │
│  │  → 违反会导致数据竞争和崩溃                                 │       │
│  │                                                              │       │
│  │  规则 2: scratch 可以跨 database 复用                        │       │
│  │  → 如果更新了 database (重新编译)，需要调用                  │       │
│  │    hs_alloc_scratch(new_db, &scratch) 扩展                   │       │
│  │  → 会自动扩展，不需要先 free 再 alloc                        │       │
│  │                                                              │       │
│  │  规则 3: scratch 可以跨流复用                                │       │
│  │  → 同一个 thread 中的多个 stream 共享一个 scratch            │       │
│  │  → 但不能同时使用（同一次 scan 完成后才能开始下一次）        │       │
│  │                                                              │       │
│  │  规则 4: scratch 分配代价较高                                │       │
│  │  → 初始化时分配，运行时复用                                  │       │
│  │  → 不要在每包处理路径中 alloc/free                           │       │
│  │                                                              │       │
│  └──────────────────────────────────────────────────────────────┘       │
│                                                                         │
│  正确模式:                                                              │
│  ┌──────────────────────────────────────────────────────────────┐       │
│  │  thread_init():                                              │       │
│  │    scratch = hs_alloc_scratch(db, &scratch);                 │       │
│  │                                                              │       │
│  │  main_loop:                                                  │       │
│  │    for each packet:                                          │       │
│  │      hs_scan(db, data, len, 0, scratch, handler, ctx);       │       │
│  │    // scratch 复用，不释放                                   │       │
│  │                                                              │       │
│  │  thread_exit():                                              │       │
│  │    hs_free_scratch(scratch);                                 │       │
│  └──────────────────────────────────────────────────────────────┘       │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 6.2 模式分组与预筛选

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    HS_FLAG_PREFILTER 优化                               │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  问题: 数万条规则全部精确匹配太慢                                     │
│                                                                         │
│  解决: 两级匹配                                                       │
│                                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │  Level 1: 预筛选 (HS_FLAG_PREFILTER)                          │    │
│  │                                                                 │    │
│  │  将复杂正则简化为简单模式:                                     │    │
│  │  原始: "[a-z]+\.exe\x00[^\x00]{100,}"                          │    │
│  │  预筛选: ".exe" (只匹配核心特征)                              │    │
│  │                                                                 │    │
│  │  → 极快，可能有假阳性                                          │    │
│  │  → 目的: 快速排除不相关流量                                   │    │
│  └──────────────────────────┬──────────────────────────────────────┘    │
│                             │ 命中 → 进入 Level 2                      │
│                             ▼                                          │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │  Level 2: 精确匹配                                             │    │
│  │                                                                 │    │
│  │  对预筛选命中的流量执行完整正则匹配                           │    │
│  │  → 无假阳性                                                    │    │
│  │  → 只有少量流量走到这一步，代价可控                           │    │
│  └─────────────────────────────────────────────────────────────────┘    │
│                                                                         │
│  效果: 数万条规则中，99% 的流量在 Level 1 就被排除                   │
│        只有 <1% 的流量需要精确匹配，整体吞吐量大幅提升               │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 6.3 规则更新热加载

```c
// 不中断数据面的情况下更新规则

// 控制面: 编译新规则
hs_database_t *new_db = compile_new_rules();

// 序列化到共享内存
char *serialized;
size_t ser_len;
hs_serialize_database(new_db, &serialized, &ser_len);

// 通知各 worker 更新 (通过 rte_ring 或原子指针)
for (int i = 0; i < num_workers; i++) {
    struct dpi_ctx *ctx = workers[i];

    hs_database_t *old_db = ctx->db;

    // 1. 扩展 scratch 以适配新数据库
    hs_alloc_scratch(new_db, &ctx->scratch);

    // 2. 原子替换 database 指针
    ctx->db = new_db;

    // 3. 释放旧数据库 (RCU 语义: 等所有线程不再使用)
    // 注意: 需要确保没有线程还在用 old_db 做 scan
    // 可以用 rte_ring 做延迟释放
    hs_free_database(old_db);
}
```

### 6.4 性能参考数据

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    Hyperscan 性能参考 (Intel Xeon)                      │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  吞吐量 (Block 模式, 单核):                                            │
│  ┌──────────────────────────────────────────────────────────────┐       │
│  │                                                              │       │
│  │  规则数    SSE4.2      AVX2        AVX-512                  │       │
│  │  100       ~25 Gbps    ~40 Gbps    ~70 Gbps                 │       │
│  │  1,000     ~15 Gbps    ~25 Gbps    ~45 Gbps                 │       │
│  │  10,000    ~5 Gbps     ~10 Gbps    ~15 Gbps                 │       │
│  │  50,000    ~1 Gbps     ~3 Gbps     ~5 Gbps                  │       │
│  │                                                              │       │
│  │  注意: 实际性能取决于规则复杂度和数据特征                    │       │
│  │  以上为典型 HTTP 流量的参考值                                │       │
│  └──────────────────────────────────────────────────────────────┘       │
│                                                                         │
│  Streaming 模式吞吐量约为 Block 模式的 60-80%                         │
│  (状态管理的额外开销)                                                  │
│                                                                         │
│  关键性能因素:                                                          │
│  ┌──────────────────────────────────────────────────────────────┐       │
│  │  1. 规则数量: 线性增长时吞吐量近似线性下降                   │       │
│  │  2. 规则复杂度: 量词 (*, +, {n,m}) 比字面量慢               │       │
│  │  3. 数据特征: 随机数据比结构化数据快 (少匹配)               │       │
│  │  4. SIMD 级别: AVX-512 比 SSE4.2 快 2-3x                   │       │
│  │  5. SOM 追踪: 开启后性能下降 20-50%                          │       │
│  └──────────────────────────────────────────────────────────────┘       │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 7. Hyperscan 支持的正则语法

Hyperscan 支持 PCRE 的一个子集，不是所有 PCRE 语法都能用：

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    Hyperscan 支持的正则语法                             │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ✅ 支持:                                                              │
│  ┌──────────────────────────────────────────────────────────────┐       │
│  │  字面量:      abc, hello                                     │       │
│  │  字符类:      [a-z], [^0-9], \d, \w, \s                     │       │
│  │  量词:        *, +, ?, {n}, {n,m}, {n,}                      │       │
│  │  贪婪/懒惰:   .*?, .+?, \d{1,3}?                             │       │
│  │  锚点:        ^, $, \b                                       │       │
│  │  分组:        (pattern)                                       │       │
│  │  选择:        pattern1|pattern2                               │       │
│  │  转义:        \., \\, \n, \r, \t                             │       │
│  │  十六进制:    \x41, \x{1F600}                                │       │
│  └──────────────────────────────────────────────────────────────┘       │
│                                                                         │
│  ❌ 不支持:                                                            │
│  ┌──────────────────────────────────────────────────────────────┐       │
│  │  反向引用:    \1, \2 (backreference)                         │       │
│  │  前瞻:        (?=...), (?!...) (lookahead)                   │       │
│  │  后瞻:        (?<=...), (?<!...) (lookbehind)                │       │
│  │  原子分组:    (?>...) (atomic group)                         │       │
│  │  条件:        (?(cond)yes|no)                                │       │
│  │  递归:        (?R), (?1)                                     │       │
│  │  命名分组:    (?P<name>...)                                  │       │
│  │  Unicode 类:  \p{Ll}, \p{Greek} (部分)                      │       │
│  └──────────────────────────────────────────────────────────┘       │
│                                                                         │
│  原因: 不支持的特性会导致 NFA 状态爆炸或需要回溯                    │
│        Hyperscan 的设计目标是保证线性时间复杂度 O(n)                 │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 8. 小结

本章核心要点：

1. **Hyperscan 是 Intel 的高性能正则匹配库**，利用 x86 SIMD 实现多模式并行匹配，单核可达数十 Gbps。

2. **NFA/DFA 混合引擎**：编译期将正则转为 NFA/DFA 混合表示，热点路径用 DFA（快），冷门路径保留 NFA（省内存），再生成 SIMD 字节码。

3. **三种扫描模式**：Block（独立数据块，最快）、Streaming（跨包状态保持，TCP 流）、Vectored（多缓冲区零拷贝）。

4. **编译期与运行期分离**：`hs_database_t` 只读可共享，`hs_scratch_t` per-thread 不可共享，`hs_stream_t` per-flow 不可共享。

5. **DPDK 集成要点**：每个 worker lcore 持有独立 scratch，database 跨线程共享；Streaming 模式配合流表实现跨包 DPI。

6. **性能优化**：`HS_FLAG_PREFILTER` 预筛选减少精确匹配量；SOM 追踪有开销按需开启；规则热加载通过序列化/反序列化实现。

**下一篇预告**：[[2026-04-09-dpdk-deep-dive-ch30-packet-framework|第三十章]]将讲解 DPDK Packet Framework。

---

> [!tip] 参考文献
>
> - Intel, "Introduction to Hyperscan", https://intel.github.io/hyperscan/
> - Vectorscan (Community Fork), https://github.com/VectorCamp/vectorscan
> - Xiangyu Zou et al., "Hyperscan: A Fast Multi-pattern Regex Matcher for Modern CPUs", NSDI 2019
> - "Suricata with Hyperscan", https://suricata.readthedocs.io/
