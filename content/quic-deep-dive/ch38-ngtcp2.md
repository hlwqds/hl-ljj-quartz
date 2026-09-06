---
title: "QUIC 深度探索 ch38 - ngtcp2"
date: 2026-04-14
description: "深入解析 ngtcp2：C/C++ QUIC 实现、与 libngtcp2/libssl 的集成、OpenSSL/BoringSSL 支持、连接管理、HTTP/3 支持、性能优化、与 nginx/h2o 的集成"
tags:
  - quic
  - series
  - ngtcp2
  - C++
  - openssl
  - http3
  - nginx
---

# QUIC 深度探索 ch38 - ngtcp2

> [!tip] 本章内容
> 本章深入剖析 ngtcp2，C/C++ 实现的 QUIC 协议栈。涵盖 libngtcp2 核心架构、libngtcp2_crypto_ossl 与 OpenSSL 的集成、连接生命周期管理、HTTP/3 支持、性能优化，以及与 nginx、h2o 等服务器的集成方式。

---

## 1. ngtcp2 概述

ngtcp2 是由 nghttp2 作者 Tatsuhiro Tsujikawa 开发的 QUIC 协议栈，采用 C/C++ 实现。它是目前社区最活跃、功能最完整的 QUIC 实现之一，被 nginx、h2o、curl 等知名项目采用。

ngtcp2 的核心设计哲学：

1. **完整协议实现**：严格遵循 RFC 9000 及相关标准
2. **灵活加密集成**：不绑定特定 TLS 库，支持 OpenSSL、BoringSSL、wolfSSL
3. **高性能**：专为高并发、低延迟场景设计
4. **零拷贝**：最小化数据复制，最大化吞吐量

ngtcp2 实际上是一个项目集合：

- **libngtcp2**：核心 QUIC 协议实现
- **libngtcp2_crypto_ossl**：OpenSSL 集成
- **libngtcp2_crypto_boringssl**：BoringSSL 集成
- **libngtcp2_crypto_wolfssl**：wolfSSL 集成
- **nghttp3**：HTTP/3 实现

---

## 2. 架构分层

```
+------------------------+
|  Application          |  ← nginx / h2o / curl
+------------------------+
|  nghttp3 (HTTP/3)     |  ← HTTP/3 逻辑
+------------------------+
|  libngtcp2            |  ← QUIC 连接管理
+------------------------+
|  libngtcp2_crypto_*   |  ← TLS 1.3 集成
+------------------------+
|  OpenSSL / BoringSSL  |  ← 加密原语
+------------------------+
|  UDP Socket          |  ← 网络 I/O
+------------------------+
```

---

## 3. 核心 API

### 3.1 库初始化与配置

```cpp
#include <ngtcp2/ngtcp2.h>
#include <ngtcp2_crypto_ossl.h>

int main() {
    // 创建配置
    ngtcp2_settings settings = {
        .max_udp_payload_size = 1400,
        .max_concurrent_streams = 100,
        .idle_timeout = 60000,
        .ping_avoid = 0,
    };

    ngtcp2_callbacks callbacks = {
        .recv_client_initial = on_recv_client_initial,
        .recv_crypto_data = on_recv_crypto_data,
        .handshake_completed = on_handshake_completed,
        .recv_stream_data = on_recv_stream_data,
        .ack_most_data = on_ack_most_data,
        .stream_close = on_stream_close,
    };

    // 创建连接
    ngtcp2_conn *conn;
    ngtcp2_conn_server_new(&conn, &conn_id, &callbacks, &settings, NULL);

    return 0;
}
```

### 3.2 连接建立

```cpp
// 客户端连接
ngtcp2_conn_client_new(
    ngtcp2_conn **pconn,
    const ngtcp2_cid *dcid,
    const ngtcp2_settings *settings,
    const ngtcp2_callbacks *callbacks,
    void *user_data
);

// 服务端连接
ngtcp2_conn_server_new(
    ngtcp2_conn **pconn,
    const ngtcp2_cid *scid,
    const ngtcp2_settings *settings,
    const ngtcp2_callbacks *callbacks,
    void *user_data
);
```

### 3.3 数据发送

```cpp
// 发送数据到 Stream
int ngtcp2_conn_write_stream(
    ngtcp2_conn *conn,
    ngtcp2_path *path,
    uint32_t *pktns,
    ngtcp2_buf *buf,
    size_t *pdatalen,
    int *pfinal,
    uint32_t stream_id,
    uint64_t stream_offset,
    const uint8_t *data,
    size_t datalen,
    size_t max_pktlen,
    uint32_t flags
);

// 接收数据
int ngtcp2_conn_read_stream(
    ngtcp2_conn *conn,
    uint32_t stream_id,
    uint64_t offset,
    const uint8_t *data,
    size_t datalen,
    int fin
);
```

### 3.4 包处理

```cpp
// 处理入站包
int ngtcp2_conn_read_pkt(
    ngtcp2_conn *conn,
    const ngtcp2_path *path,
    uint32_t *pktns,
    const uint8_t *pkt,
    size_t pktlen,
    ngtcp2_tstamp ts
);

// 获取待发送包
int ngtcp2_conn_write_pkt(
    ngtcp2_conn *conn,
    ngtcp2_path *path,
    uint32_t *pktns,
    uint8_t *buf,
    size_t buflen,
    size_t max_pktlen
);
```

---

## 4. 连接管理

### 4.1 连接状态

ngtcp2 定义了完整的连接状态机：

```cpp
typedef enum {
    NGTCP2_STATE_NONE,
    NGTCP2_STATE_CLIENT_INITIAL,
    NGTCP2_STATE_CLIENT_HANDSHAKE,
    NGTCP2_STATE_CLIENT_TLS_1RTT,
    NGTCP2_STATE_SERVER_INITIAL,
    NGTCP2_STATE_SERVER_HANDSHAKE,
    NGTCP2_STATE_SERVER_TLS_1RTT,
    NGTCP2_STATE_CONNECTION_CLOSE,
    NGTCP2_STATE_DRAINING,
    NGTCP2_STATE_CLOSING,
    NGTCP2_STATE_STATELESS_RETRY,
} ngtcp2_state;
```

### 4.2 回调机制

ngtcp2 使用回调机制通知应用层事件：

```cpp
// 回调结构
struct ngtcp2_callbacks {
    // 握手相关
    int (*recv_client_initial)(ngtcp2_conn *conn, const ngtcp2_cid *dcid,
                               void *user_data);
    int (*recv_crypto_data)(ngtcp2_conn *conn,
                             ngtcp2_crypto_level crypto_level,
                             uint64_t offset,
                             const uint8_t *data, size_t datalen,
                             void *user_data);
    int (*handshake_completed)(ngtcp2_conn *conn, void *user_data);
    int (*recv_key_update)(ngtcp2_conn *conn, void *user_data);

    // Stream 相关
    int (*recv_stream_data)(ngtcp2_conn *conn, uint32_t stream_id,
                             uint64_t offset,
                             const uint8_t *data, size_t datalen,
                             int fin, void *user_data);
    int (*ack_most_data)(ngtcp2_conn *conn, uint32_t stream_id,
                          uint64_t offset, void *user_data);
    int (*stream_close)(ngtcp2_conn *conn, uint32_t stream_id,
                         uint64_t app_error_code, void *user_data);

    // 拥塞控制相关
    int (*recv_rtt_sample)(ngtcp2_conn *conn, void *user_data);
    int (*ecn_recv)(ngtcp2_conn *conn, ngtcp2_cid *cid,
                     const ngtcp2_pkt_info *pi, const uint8_t *buf,
                     size_t buflen, void *user_data);
};

// 示例：处理 Stream 数据
static int recv_stream_data(ngtcp2_conn *conn, uint32_t stream_id,
                              uint64_t offset, const uint8_t *data,
                              size_t datalen, int fin, void *user_data) {
    MyConnection *my_conn = (MyConnection*)user_data;

    // 处理数据
    my_conn->handle_data(stream_id, data, datalen);

    if (fin) {
        my_conn->handle_stream_close(stream_id);
    }

    return 0;
}
```

---

## 5. TLS 集成

### 5.1 OpenSSL 集成

ngtcp2 通过 libngtcp2_crypto_ossl 与 OpenSSL 集成：

```cpp
#include <ngtcp2_crypto_ossl.h>

// 初始化 OpenSSL
SSL_CTX *ssl_ctx = SSL_CTX_new(TLS_method());
SSL_CTX_set_min_proto_version(ssl_ctx, TLS1_3_VERSION);

// 配置 ngtcp2 使用 OpenSSL
ngtcp2_conn *conn;
ngtcp2_settings settings = {
    // ...
};

ngtcp2_crypto_conn_ref conn_ref = {
    .get_ssl = my_get_ssl,        // 返回对应连接的 SSL*
    .set_tls_user_data = my_set_tls_user_data,
};

// 初始化
int rv = ngtcp2_conn_client_new(&conn, dcid, &settings, &callbacks,
                                  &conn_ref, ssl_ctx);
```

### 5.2 TLS 握手回调

```cpp
static int set_tls_user_data(ngtcp2_conn *conn, void *tls_user_data) {
    // 将 ngtcp2 连接与 TLS session 关联
    return 0;
}

static SSL* my_get_ssl(ngtcp2_conn *conn) {
    MyConn *my_conn = (MyConn*)conn->user_data;
    return my_conn->ssl;
}

// 处理 TLS 警报
static int recv_crypto_data(ngtcp2_conn *conn,
                              ngtcp2_crypto_level crypto_level,
                              uint64_t offset,
                              const uint8_t *data, size_t datalen,
                              void *user_data) {
    MyConn *my_conn = (MyConn*)user_data;

    // 将 TLS 数据注入到 OpenSSL
    SSL_provide_quic_data(my_conn->ssl, crypto_level_to_ssl(crypto_level),
                          data, datalen);

    // 继续 TLS 握手
    SSL_do_handshake(my_conn->ssl);

    return 0;
}
```

---

## 6. HTTP/3 支持

### 6.1 nghttp3 集成

nghttp3 提供了完整的 HTTP/3 实现：

```cpp
#include <nghttp3/nghttp3.h>

// 创建 QPACK 编码器/解码器
nghttp3_qpack_encoder encoder;
nghttp3_qpack_decoder decoder;

// 初始化
nghttp3_qpack_encoder_init(&encoder, 4096, 0);
nghttp3_qpack_decoder_init(&decoder, 4096, 100);

// 处理 HTTP 帧
static ngtcp2_ssize h3_recv_http(ngtcp2_conn *conn,
                                    uint32_t stream_id,
                                    const uint8_t *data,
                                    size_t datalen) {
    nghttp3_stream *stream = my_get_h3_stream(stream_id);

    // 解析 HTTP 帧
    ngtcp2_ssize n = nghttp3_conn_read_stream(&h3_conn, stream_id,
                                                data, datalen);
    return n;
}
```

### 6.2 请求/响应处理

```cpp
// 发送 HTTP 请求
int send_request(ngtcp2_conn *conn, uint32_t stream_id) {
    // 构造 HTTP 请求头
    nghttp3_nv hdrs[] = {
        {(uint8_t*)":method", 7, (uint8_t*)"GET", 3},
        {(uint8_t*)":path", 5, (uint8_t*)"/", 1},
        {(uint8_t*)":scheme", 7, (uint8_t*)"https", 5},
        {(uint8_t*)":authority", 10, (uint8_t*)"example.com", 11},
    };

    // 发送请求头
    nghttp3_conn_submit_request(&h3_conn, stream_id, hdrs, 4, NULL);

    // 获取编码后的数据并通过 ngtcp2 发送
    nghttp3_buf buf;
    nghttp3_buf_init(&buf, 4096);
    nghttp3_conn_read_or_write_data(&h3_conn, stream_id, &buf);

    ngtcp2_conn_write_stream(conn, stream_id, buf.pos, buf.buf,
                              nghttp3_buf_len(&buf), NGTCP2_WRITE_STREAM_FLAG_NONE);

    return 0;
}
```

---

## 7. 性能优化

### 7.1 批量包处理

ngtcp2 支持批量处理多个包：

```cpp
// 批量处理入站包
int process_packets(ngtcp2_conn *conn, ngtcp2_pkt_info *pkts, int npkts) {
    for (int i = 0; i < npkts; i++) {
        rv = ngtcp2_conn_read_pkt(conn, &path, &pktns,
                                   pkts[i].pkt, pkts[i].pktlen, ts);
        if (rv != 0) {
            return rv;
        }
    }
    return 0;
}

// 批量发送
int flush_packets(ngtcp2_conn *conn, int (*send_func)(void*, ...)) {
    uint8_t buf[1500];
    ngtcp2_ssize n;

    while ((n = ngtcp2_conn_write_pkt(conn, &path, &pktns,
                                        buf, sizeof(buf), ts)) > 0) {
        send_func(user_data, buf, n);
    }
}
```

### 7.2 GSO 和 sendmmsg

```cpp
// sendmmsg 批量发送
static ssize_t send_packets(int fd, ngtcp2_pkt_info *pkts, int npkts) {
    struct mmsghdr msgvec[MAX_BATCH];
    struct iovec iovecs[MAX_BATCH];

    for (int i = 0; i < npkts; i++) {
        iovecs[i].iov_base = pkts[i].pkt;
        iovecs[i].iov_len = pkts[i].pktlen;

        memset(&msgvec[i].msg_hdr, 0, sizeof(struct mmsghdr));
        msgvec[i].msg_hdr.msg_iov = &iovecs[i];
        msgvec[i].msg_hdr.msg_iovlen = 1;
    }

    return sendmmsg(fd, msgvec, npkts, 0);
}
```

### 7.3 拥塞控制

ngtcp2 支持多种拥塞控制算法：

```cpp
// 配置拥塞控制算法
ngtcp2_settings settings = {
    .cc_algo = NGTCP2_CC_ALGO_CUBIC,  // 或 NGTCP2_CC_ALGO_BBR
};

// BBR 配置
struct ngtcp2_cc_bbr {
    uint64_t min_rtt;
    uint64_t maxBw;           // 最大带宽
    double pacing_gain;
    double cwnd_gain;
};
```

---

## 8. 与服务器集成

### 8.1 nginx 集成

nginx 通过 submodule 方式集成 ngtcp2：

```nginx
# nginx.conf
http {
    # 启用 QUIC
    quic on;

    # 绑定到 443 端口
    listen 443 http3 reuseport;

    # TLS 配置
    ssl_certificate /path/to/cert.pem;
    ssl_certificate_key /path/to/key.pem;
    ssl_protocols TLSv1.3;
}

# 验证 nginx QUIC 支持
nginx -V 2>&1 | grep -o quic
```

### 8.2 h2o 集成

h2o 是另一个使用 ngtcp2 的服务器：

```yaml
# h2o.conf
listen:
  port: 443
  ssl:
    key-file: /path/to/key.pem
    certificate-file: /path/to/cert.pem
    alpn: ["h3", "h2", "http/1.1"]
  quic:
    streams: 100
    max-udp-payload-size: 1400
```

---

## 9. 统计与调试

### 9.1 连接统计

```cpp
struct ngtcp2_conn_stat {
    uint64_t n송_bytes;           // 发送字节数
    uint64_t nrecv_bytes;         // 接收字节数
    uint64_t nsent_packets;      // 发送包数
    uint64_t nrecv_packets;      // 接收包数
    uint64_t ndropped_packets;   // 丢弃包数
    uint64_t nloss;              // 丢包数
    uint64_t nackd_packets;      // 已确认包数
    uint64_t n spurious;          // 虚假超时
    uint64_t min_rtt;             // 最小 RTT
    uint64_t smooth_rtt;          // 平滑 RTT
    uint64_t rttvar;             // RTT 变化
};

void ngtcp2_conn_get_conn_stat(ngtcp2_conn *conn, ngtcp2_conn_stat *stat);
```

### 9.2 日志级别

```cpp
// 设置日志级别
ngtcp2_log_printf(conn, NGTCP2_LOG_LEVEL_INFO,
                   "Connection established: CID=%016lx", cid);

// 日志级别定义
typedef enum {
    NGTCP2_LOG_LEVEL_NONE,
    NGTCP2_LOG_LEVEL_FATAL,
    NGTCP2_LOG_LEVEL_ERROR,
    NGTCP2_LOG_LEVEL_WARNING,
    NGTCP2_LOG_LEVEL_INFO,
    NGTCP2_LOG_LEVEL_DEBUG,
    NGTCP2_LOG_LEVEL_DETAIL,
} ngtcp2_log_level;
```

---

## 10. 局限性

1. **API 复杂度**：回调驱动的 API 学习曲线较陡
2. **TLS 依赖**：需要与外部 TLS 库配合使用
3. **文档不足**：官方文档较少，主要靠示例代码
4. **内存管理**：需要应用层正确管理连接生命周期
5. **Windows 支持**：需要 Cygwin/MSYS2，不如 Linux 完善

---

## 11. 总结

ngtcp2 是目前社区最活跃、功能最完整的 QUIC 实现之一，C/C++ 的实现使其兼具性能和可移植性。OpenSSL 集成、HTTP/3 支持、与主流服务器（nginx、h2o）的深度集成使其成为生产环境的首选。虽然 API 复杂度较高，但通过回调机制实现了高度灵活的事件通知。对于需要高性能、完整 RFC 兼容性的项目，ngtcp2 是最佳选择。

---

> [!note] 下章预告
> 下一章我们将探讨 Go 生态中的 QUIC 实现，分析 quic-go 和 quicly 的设计理念与适用场景。
