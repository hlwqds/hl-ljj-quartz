---
title: "QUIC 深度探索 ch37 - LiteSpeed lsquic"
date: 2026-04-14
description: "深入解析 LiteSpeed lsquic：C 语言实现、轻量级设计、lsquic 的核心架构、与 OpenLiteSpeed/LiteSpeed Web Server 的集成、高并发连接处理、连接迁移优化"
tags:
  - quic
  - series
  - lsquic
  - litespeed
  - C language
  - webserver
  - http3
---

# QUIC 深度探索 ch37 - LiteSpeed lsquic

> [!tip] 本章内容
> 本章深入剖析 LiteSpeed 的 QUIC 实现——lsquic。涵盖 C 语言轻量级设计、核心架构、与 LiteSpeed Web Server 的深度集成、连接池管理、高并发处理，以及生产环境性能优化经验。

---

## 1. lsquic 概述

lsquic 是 LiteSpeed Technologies 开发的 QUIC 协议栈，使用纯 C 语言编写，是 OpenLiteSpeed 和 LiteSpeed Web Server 的内置 QUIC 支持引擎。

lsquic 的设计哲学：

1. **极致轻量**：最小化内存占用，适合共享主机环境
2. **零依赖**：不依赖外部 TLS 库，自己实现 TLS 1.3（基于 picotls）
3. **高性能**：单线程处理高并发连接，无锁设计
4. **兼容性**：与标准 QUIC RFC 9000 完全兼容

LiteSpeed 在 2018 年率先在 Web 服务器中支持 HTTP/3，lsquic 是其核心引擎：

- OpenLiteSpeed（开源）
- LiteSpeed Web Server（商业版）
- LiteSpeed Cache 插件

---

## 2. 核心架构

### 2.1 模块分层

```
+------------------------+
|   HTTP/3 Handler       |  ← 与 Web 服务器集成
+------------------------+
|   Stream Manager       |  ← STREAM 帧管理
+------------------------+
|   Connection Manager   |  ← 连接状态机
+------------------------+
|   Frame Processor      |  ← 帧解析与调度
+------------------------+
|   Packet I/O          |  ← 打包/解包
+------------------------+
|   Crypto Engine       |  ← TLS 1.3（内置 picotls）
+------------------------+
|   Congestion Control  |  ← 拥塞控制算法
+------------------------+
```

### 2.2 核心数据结构

```c
// lsquic 连接结构
struct lsquic_conn {
    lsquic_conn_ctx_t *cn_ctx;           // 连接上下文
    lsquic_handshaker_t *cn_handshaker; // 握手状态机

    lsquic_stream_t *cn_streams;         // Stream 链表
    lsquic_packets_t *cn_packets_out;    // 待发送包
    lsquic_packets_t *cn_packets_in;    // 已接收包

    lsquic_crypto_t *cn_crypto;         // TLS 状态
    lsquic_cc_t *cn_cc;                 // 拥塞控制状态

    lsquic_conn_public_t cn_pub;        // 公共接口
};

// Stream 结构
struct lsquic_stream {
    lsquic_stream_t *st_next, *st_prev; // 链表指针
    lsquic_conn_t *st_conn;            // 所属连接

    uint64_t st_stream_id;             // Stream ID
    uint64_t st_send_off;              // 发送偏移
    uint64_t st_recv_off;              // 接收偏移

    unsigned st_state;                  // Stream 状态
    unsigned st_flags;                 // 标志位

    lsquic_buf_t *st_send_buf;         // 发送缓冲区
    lsquic_buf_t *st_recv_buf;         // 接收缓冲区
};
```

---

## 3. 核心 API

### 3.1 库初始化

```c
#include <lsquic.h>

// 库初始化
int lsquic_global_init(void);

// 创建引擎
struct lsquic_engine *lsquic_engine_new(
    uint32_t flags,
    const struct lsquic_engine_api *api
);

// 引擎配置
struct lsquic_engine_api {
    .ea_packets_out = my_send_packets,     // 发送回调
    .ea_packet_in = my_recv_packet,        // 接收回调
    .ea_get_ssl_ctx = my_ssl_ctx_provider, // SSL 上下文
    .ea_cc_algos = CC_ALGO_CUBIC,          // 拥塞控制算法
    // ...
};
```

### 3.2 连接处理

```c
// 处理入站数据
void lsquic_engine_process_packet(
    struct lsquic_engine *engine,
    struct lsquic_packet_in *packet_in,
    void *peer_ctx,
    struct lsquic_packets_out **(*packets_out)[0]
);

// 获取事件
enum lsquic_event_type {
    LSQUIC_EVENT_NEW_CONNECTION,   // 新连接
    LSQUIC_EVENT_HANDSHAKE_DONE,    // 握手完成
    LSQUIC_EVENT_STREAM_NEW,       // 新 Stream
    LSQUIC_EVENT_STREAM_READABLE,   // Stream 可读
    LSQUIC_EVENT_STREAM_WRITABLE,   // Stream 可写
    LSQUIC_EVENT_CONNECTION_CLOSE,  // 连接关闭
};

const lsquic_event_t *lsquic_engine_get_event(struct lsquic_engine *);
```

### 3.3 Stream 操作

```c
// 发送数据
ssize_t lsquic_stream_write(
    lsquic_stream_t *stream,
    const void *buf,
    size_t size
);

// 读取数据
ssize_t lsquic_stream_read(
    lsquic_stream_t *stream,
    void *buf,
    size_t size
);

// 关闭 Stream
void lsquic_stream_close(lsquic_stream_t *stream);
```

---

## 4. 连接生命周期

### 4.1 连接建立

```
客户端                                lsquic 服务器
  |                                      |
  |-------- Initial (CID=X) ---------->|
  |                                      |
  |        <-------- Initial (CID=Y) ---|
  |           + Handshake (0-RTT)        |
  |                                      |
  |-------- Handshake (0-RTT data) --->|
  |                                      |
  |        <-------- 1-RTT (HANDSHAKE_DONE) --|
  |                                      |
  |-------- 1-RTT (HTTP Request) ----->|
  |                                      |
  |        <-------- 1-RTT (HTTP Response)-|
```

lsquic 的握手处理流程：

```c
static lsquic_conn_t *create_server_conn(lsquic_engine_t *engine,
    lsquic_packet_in_t *pkt)
{
    lsquic_conn_t *conn = lsquic_conn_new();

    // 1. 解析 Initial 包
    lsquic_handshaker_init(conn, pkt);

    // 2. 派生 0-RTT 密钥（如果支持）
    lsquic_crypto_derive_keys(conn, LSQUIC_CRYPTO_0RTT);

    // 3. 派生 1-RTT 密钥
    lsquic_crypto_derive_keys(conn, LSQUIC_CRYPTO_1RTT);

    // 4. 发送 Handshake 包
    lsquic_send_handshake(conn);

    return conn;
}
```

### 4.2 连接关闭

```c
void lsquic_conn_close(lsquic_conn_t *conn, uint64_t error_code)
{
    // 1. 发送 CONNECTION_CLOSE
    lsquic_frame_conn_close_t frame = {
        .error_code = error_code,
        .frame_type = 0, // 应用程序关闭
        .reason_phrase = "normal closure"
    };
    lsquic_out_frame_add(conn, &frame);

    // 2. 刷新所有待发送包
    lsquic_conn_flush(conn);

    // 3. 进入 draining 状态
    conn->cn_state = LSQUIC_CONN_DRAINING;
}
```

---

## 5. Stream 处理

### 5.1 Stream 调度

lsquic 实现了一个优化的 Stream 调度算法：

```c
// 优先级队列调度
static lsquic_stream_t *select_next_stream(lsquic_conn_t *conn)
{
    lsquic_stream_t *best = NULL;
    uint64_t best_score = UINT64_MAX;

    // 遍历所有 active stream
    for (stream in conn->cn_active_streams) {
        // 计算优先级分数
        uint64_t score = calculate_stream_score(stream);

        if (score < best_score) {
            best_score = score;
            best = stream;
        }
    }

    return best;
}

static uint64_t calculate_stream_score(lsquic_stream_t *stream)
{
    uint64_t score;

    // 考虑：已排队数据量、延迟、带宽
    score = stream->st_send_off;            // 已发送的数据量
    score += stream->st_priority * 1000;    // 优先级权重
    score -= stream->st_congestion_window;  // 拥塞窗口剩余空间

    return score;
}
```

### 5.2 STREAM 帧生成

```c
// STREAM 帧编码
static size_t gen_stream_frame(lsquic_stream_t *stream,
    unsigned char *buf, size_t bufsz)
{
    size_t off = 0;
    uint64_t stream_id = stream->st_stream_id;
    uint64_t offset = stream->st_send_off;
    size_t data_len = MIN(bufsz, stream->st_send_buf->size);

    // STREAM frame type
    buf[off++] = 0x08 | 0x04 | 0x02; // Stream Type = 2 (FIN + OFF + LEN)

    // Stream ID
    off += encode_varint(buf + off, stream_id);

    // Offset
    off += encode_varint(buf + off, offset);

    // Length + Data
    buf[off++] = data_len;
    memcpy(buf + off, stream->st_send_buf->data, data_len);
    off += data_len;

    return off;
}
```

---

## 6. 拥塞控制

lsquic 支持多种拥塞控制算法：

```c
// 拥塞控制算法接口
struct lsquic_cc {
    void (*cc_init)(struct lsquic_cc*, uint32_t);
    void (*cc_on_ack)(struct lsquic_cc*, uint64_t, uint64_t);
    void (*cc_on_loss)(struct lsquic_cc*, uint64_t);
    void (*cc_on_persistent_congestion)(struct lsquic_cc*);
    uint32_t (*cc_in_flight)(struct lsquic_cc*);
};

// Cubic 实现
static const struct cc_algo cubic_algo = {
    .cc_init = cubic_init,
    .cc_on_ack = cubic_on_ack,
    .cc_on_loss = cubic_on_loss,
    .cc_get_cwnd = cubic_get_cwnd,
};

// BBR 实现
static const struct cc_algo bbr_algo = {
    .cc_init = bbr_init,
    .cc_on_ack = bbr_on_ack,
    .cc_on_loss = bbr_on_loss,
    .cc_get_cwnd = bbr_get_cwnd,
};
```

---

## 7. 与 LiteSpeed Web Server 的集成

### 7.1 架构

```
+---------------------------+
|   LiteSpeed Web Server    |
|   (HTTP/3 + QUIC)         |
+---------------------------+
|   lsquic engine           |
|   (per-vhost connection)   |
+---------------------------+
|   Shared SSL session pool |
+---------------------------+
|   UDP socket (per CPU)    |
+---------------------------+
```

### 7.2 配置

```
# lsquic 在 OpenLiteSpeed 中的配置
vi /usr/local/lsws/conf/httpd.conf

# 启用 HTTP/3
modules                    {
    modquic
}

# QUIC 设置
quicenable                 1
quicfusion                 1
quicCCAlgo                 cubic
quicmaxconcurrent          100
```

### 7.3 连接池管理

lsquic 在 LiteSpeed 中使用连接池复用：

```c
// 每个 Worker 维护独立的连接池
struct lsquic_engine_pool {
    lsquic_engine_t *pool_engines[MAX_CPU];
    size_t pool_size;
};

// 连接复用
static lsquic_conn_t *get_reusable_conn(lsquic_engine_t *engine)
{
    lsquic_conn_t *conn;

    // 从空闲队列中获取
    if ((conn = TAILQ_FIRST(&engine->eng_free_conns))) {
        TAILQ_REMOVE(&engine->eng_free_conns, conn, cn_link);
        return conn;
    }

    return NULL;
}
```

---

## 8. 性能优化

### 8.1 无锁设计

lsquic 在单线程模式下完全无锁：

```c
// 每个 CPU 核心独立的引擎实例
static void init_per_cpu_engines(void)
{
    for (int i = 0; i < ncpu; i++) {
        engines[i] = lsquic_engine_new(
            LSQUIC_ENGINE_SERVER |
            LSQUIC_ENGINE_NO_HTTPQ |
            LSQUIC_ENGINE_MADVISE,
            &api
        );
    }
}
```

### 8.2 内存池

lsquic 使用内存池减少分配开销：

```c
// mem池 API
lsquic_mpool_t *mp = lsquic_mpool_create(4096);

// 分配对象
lsquic_packet_t *pkt = mpool_get(&mp, sizeof(*pkt));

// 归还对象
mpool_put(&mp, pkt);
```

### 8.3 GSO 支持

```c
// UDP GSO 批量发送
static ssize_t send_packets_gso(int fd, struct iovec *pkts, int npkts)
{
    struct mmsghdr msgvec[MAX_PKTS];
    struct mmsghdr *msg = msgvec;

    for (int i = 0; i < npkts; i++) {
        memset(msg, 0, sizeof(*msg));
        msg->msg_hdr.msg_iov = &pkts[i];
        msg->msg_hdr.msg_iovlen = 1;
        msg++;
    }

    return sendmmsg(fd, msgvec, npkts, 0);
}
```

---

## 9. 生产环境配置

### 9.1 高并发配置

```c
// 针对高并发场景的配置
struct lsquic_engine_api api = {
    .ea_packets_out = my_send_packets,
    .ea_packet_in = my_recv_packet,
    .ea_cc_algos = CC_ALGO_CUBIC | CC_ALGO_BBR,
    .ea_max_conns = 100000,        // 最大连接数
    .ea_max_stream_in = 100000,    // 最大并发流
    .ea_idle_timeout = 60,         // 60s idle
};
```

### 9.2 监控接口

```c
// 连接统计
struct lsquic_conn_stats {
    uint64_t n_total_streams;       // 总 Stream 数
    uint64_t n_open_streams;        // 打开的 Stream
    uint64_t n_bytes_sent;          // 发送字节数
    uint64_t n_bytes_recv;          // 接收字节数
    uint64_t n_packets_sent;        // 发送包数
    uint64_t n_packets_recv;        // 接收包数
    uint64_t n_retrans;             // 重传数
    uint64_t n_spurious;            // 虚假超时
};

void lsquic_conn_get_stats(lsquic_conn_t*, struct lsquic_conn_stats*);
```

---

## 10. 局限性

1. **纯 C 复杂度**：手动内存管理容易出错
2. **TLS 限制**：内置 picotls 功能有限，不支持某些高级 TLS 特性
3. **文档匮乏**：开源社区文档较少
4. **调试困难**：缺少详细的日志和调试工具
5. **Windows 支持**：主要面向 Linux

---

## 11. 总结

lsquic 是 LiteSpeed 在 QUIC 领域的核心产品，其极致轻量的设计和零外部依赖使其特别适合 Web 服务器场景。C 语言实现虽然增加了开发复杂度，但带来了极致的性能和最小的内存占用。与 LiteSpeed Web Server 的深度集成使其成为生产环境 HTTP/3 部署的成熟选择。对于需要高性能、轻量级 QUIC 实现的 Web 服务器场景，lsquic 值得关注。

---

> [!note] 下章预告
> 下一章我们将探讨 ngtcp2，结合 OpenSSL 的 C/C++ QUIC 实现，分析其在高性能场景中的应用与优化。
