---
title: "lwIP 深度解析（二十二）：TLS：esp-tls/mbedTLS 与 lwIP 的边界"
date: 2026-08-26
description: "TLS 记录层如何叠在 lwIP socket 字节流上：拆解 esp-tls 连接状态机与证书验证三种姿势，给出 IN/OUT 缓冲的精确尺寸公式（16717/4429 字节）与实测握手峰值增量 ~33KB、稳态 ~27KB 的内存账本；堆饥饿到 13.5KB 时 ssl_setup 在 4.5ms 内死于 alloc(16717) 失败；loopback 配对实测加密税 97%。附 vanilla 与 IDF 的 CONFIG_MBEDTLS_* 裁剪对照。"
tags: [lwip, network, esp32, esp-idf, tls, mbedtls, qemu]
---

> [!info] lwIP 深度解析系列 0. [[2026-08-26-lwip-deep-dive-series-index|系列索引]] 22. **第二十二章：TLS：esp-tls/mbedTLS 与 lwIP 的边界**

# lwIP 深度解析（二十二）：TLS：esp-tls/mbedTLS 与 lwIP 的边界

这一章回答三个问题：**TLS 记录层和 TCP 字节流怎么互相咬合**（mbedTLS 自身的分帧/缓冲叠在 lwIP recv 之上意味着什么）、**一次握手到底吃多少内存**（嵌入式第一问，给出公式与实测对照）、**握手 CPU 时延和包往返是什么关系**（用分段计时把 TCP 握手、ClientHello 往返、证书验证拆开看）。读完它，你应该能给任何"这个芯片跑得动 TLS 吗"的问题一个有数字的回答。源码参照：ESP-IDF v6.0.2 的 `components/esp-tls/` 与 `components/mbedtls/mbedtls`（**Mbed TLS 4.1.0**，注意它已并入 tf-psa-crypto，很多老教材的宏值在 4.x 已经改绑）。

---

## 22.1 设计动机：为什么需要一个 esp-tls 中间层

裸 mbedTLS 提供的是密码学原语和记录层协议机，它**不知道** socket 从哪来：收发要你通过 `mbedtls_net_send/net_recv` 回调自己接。直接用它写客户端，你要面对一整套工程问题：

1. **连接管理**：DNS 解析、非阻塞 connect、超时控制、错误分类——这些是 [[2026-08-26-lwip-deep-dive-ch16-socket-netconn-vfs|第十六章]] socket 层的事，但每个 TLS 应用都要重写一遍；
2. **证书验证策略**：CA bundle、全局 CA store、自带 CA、跳过验证——不同的信任来源在 `ssl_config` 上有不同的接线方式；
3. **错误传播**：mbedTLS 错误码、errno、证书 flags 三类错误混在一起，调用方很难拿到完整现场。

esp-tls 就是 IDF 对这三件事的标准答案：一个约 1900 行的组件（`components/esp-tls/`），向上暴露 `esp_tls_conn_new_sync/write/read/destroy` 六七个函数，向下把 mbedTLS（或注册的自定义栈）接到 lwIP 的 BSD socket 上。它**不改 lwIP 一个字节**——这一点和 [[2026-08-26-lwip-deep-dive-ch13-tcpip-thread-mailbox|第十三章]] 讲过的"IDF 对 tcpip.c 本体零改动"是同一种克制。

### 1. TLS 记录层叠在字节流上意味着什么

TCP 给应用的是无边界字节流；TLS 在上面重新划出**记录（record）**：每条记录 = 5 字节头（type/version/length）+ 加密载荷。这带来两个对嵌入式直接可见的后果：

- **收方向是攒包**：lwIP 把一段段字节递给 `recv()`，mbedTLS 必须先凑齐 5 字节头、再按头部声明凑齐全量载荷、然后才解密。缓冲不满时上层的 `esp_tls_conn_read()` 就必须返回 `WANT_READ`——哪怕对方早就发完了。第 22.4 节用日志逐行看这个过程。
- **发方向是分片**：应用一次 `write()` 大于出向记录容量时必须切成多条记录，每条独立加密独立成帧。esp-tls 的 write 循环显式做了这件事（22.3 节）。

叠加之后，guest 内一条 14 字节的应用消息在线路上是一条 ~42 字节的 TLS 记录（本章实验实测），中间的放大系数由套件开销决定（AES-GCM 是 8 字节显式 IV + 16 字节 tag）。

## 22.2 协议栈全景图：每一层的缓冲与拷贝点

延续 [[2026-08-26-lwip-deep-dive-ch6-zero-copy-tcp-write|第六章]]/[[2026-08-26-lwip-deep-dive-ch16-socket-netconn-vfs|第十六章]] 的拷贝地图，把 TLS 两层插进去之后全链路长这样（openeth/QEMU 平台）：

```text
 应用 buf (你的数据, e.g. 1KB)
   │ ① memcpy: 应用 → mbedTLS out_buf（加密就在这块缓冲里做）
   ▼
┌─────────────── mbedTLS ───────────────┐
│ out_buf: MBEDTLS_SSL_OUT_BUFFER_LEN    │ ← 13 + OUT_PAYLOAD_LEN（IDF 默认 4429B）
│ (SSL record: hdr5 | IV8 |密文 | tag16) │    按 OUT_CONTENT_LEN=4096 分片
└────────────────────────────────────────┘
   │ ② mbedtls_net_send() → send() 系统调用
   ▼
 lwIP socket/netconn（VFS 层）      ── 见 ch16
   │ ③ netconn_write → tcp_write()【IDF 强制 COPY，见 ch6】
   ▼
 tcpip_thread: pbuf 链 → IP → openeth linkoutput
   │                                    ══ SLIRP 用户态网络 ══
   ▼
 宿主机 loopback : openssl s_server / python echo

 宿主机响应 → SLIRP → emac_rx 任务 ④ memcpy(1516B 帧 → 堆, 见 ch5/ch17)
   │ pbuf 组装 → ip4_input → tcp_input
   ▼
 netconn recv 邮箱（CONFIG_LWIP_TCP_RECVMBOX_SIZE=6 个事件）
   │ ⑤ recv() 从邮箱取回数据 memcpy 到用户指针 —— 但注意：
   ▼
┌─────────────── mbedTLS ───────────────┐
│ in_buf: MBEDTLS_SSL_IN_BUFFER_LEN      │ ← TLS 收路径的终点是 ssl->in_buf，
│ recv() 直接写这里攒完整 record          │    攒满 → 校验 tag → 就地解密
└────────────────────────────────────────┘
   │ ⑥ 解密后 memcpy: in_buf → 应用 buf（esp_tls_conn_read 返回）
   ▼
 应用 buf
```

六个拷贝点里，⑤⑥ 是 TLS 叠加带来的新形态：**recv 的目标不是用户缓冲而是 mbedTLS 的 in_buf**，用户拿到的永远是解密后的二次拷贝。"零拷贝收路径"在 TLS 下不存在——这是协议设计的代价，不是实现的失误。顺带一提，本系列第十六章说过 fd 层还有一次 VFS 中转，TLS 客户端整条下行链路的拷贝次数是 **5 次**。

## 22.3 esp-tls 组件解剖：连接抽象与状态机

### 1. 一个结构体管三种连接

`private_include/esp_tls_private.h` 里的 `struct esp_tls` 是整个组件的核心句柄：

```c
struct esp_tls {
#ifdef CONFIG_ESP_TLS_USING_MBEDTLS
    mbedtls_ssl_context ssl;        /* TLS 协议机（含 in_buf/out_buf 指针） */
    mbedtls_ssl_config conf;        /* 配置（密码套件表、authmode、回调…） */
    mbedtls_net_context server_fd;  /* 只是包了一层的 int sockfd */
    mbedtls_x509_crt cacert;        /* CA 证书容器 */
    ...
#endif
    ssize_t (*read)(esp_tls_t *tls, char *data, size_t datalen);   /* 函数指针分路 */
    ssize_t (*write)(esp_tls_t *tls, const char *data, size_t datalen);
    int sockfd;
    esp_tls_conn_state_t conn_state; /* INIT/CONNECTING/HANDSHAKE/FAIL/DONE */
    bool is_tls;                     /* false = 明文 TCP 直通 */
    esp_tls_role_t role;             /* client/server */
};
```

两个值得咀嚼的设计：

- **`is_plain_tcp` 分路**：`esp_tls_cfg_t.is_plain_tcp=true` 时，`esp_tls_low_level_conn()` 完成 TCP 连接后把 `read/write` 指到裸 `send/recv` 直接返回——MQTT over WS、明文 HTTP 等场景复用同一套连接管理代码。这就是"抽象层"的价值：TLS 只是从 INIT 到 DONE 五个状态中的一个分支。
- **read/write 函数指针**：所有 IO 都经 `tls->read/tls->write` 分派，TLS 版与明文版共用一套上层循环。更换后端库（Kconfig 选 Custom TLS stack 时走 `esp_tls_custom_stack.c` 注册的 `esp_tls_stack_ops_t`）对上层完全透明。

### 2. 连接状态机：一次 sync 连接被拆成三段可重入的状态

`esp_tls.c` 的 `esp_tls_low_level_conn()` 是个手工状态机，`ESP_TLS_INIT → CONNECTING → HANDSHAKE` 三态顺序执行：

```c
switch (tls->conn_state) {
case ESP_TLS_INIT:
    ...tcp_connect(hostname, port, cfg, &tls->sockfd);   /* DNS + connect */
    if (!cfg->non_block) { /* select 等 ESTABLISHED */ }
    tls->conn_state = ESP_TLS_CONNECTING;
    /* falls through */
case ESP_TLS_CONNECTING:
    esp_ret = create_ssl_handle(...);     /* set_client_config + ssl_setup */
    tls->read  = _esp_tls_read;
    tls->write = _esp_tls_write;
    tls->conn_state = ESP_TLS_HANDSHAKE;
    /* falls through */
case ESP_TLS_HANDSHAKE:
    return esp_tls_handshake(tls, cfg);   /* mbedTLS 状态机的薄包装 */
}
```

阻塞模式下一次 `esp_tls_conn_new_sync()` 就是 while 循环驱动它跑到返回 1。但三个入口状态都是可重入的：**异步模式（`cfg->non_block=true`）下每次调用只推进一段，返回 0 表示"还没好"，让你把 TLS 连接塞进自己的事件循环**。22.7 节实验还利用了一个公开 API 技巧：先用普通 socket 完成 TCP 连接并计时，再用 `esp_tls_set_conn_sockfd()` + `esp_tls_set_conn_state(ESP_TLS_CONNECTING)` 把现成的 fd 移交进来从第二段续跑——两段耗时因此可以分开测量。

超时语义也在这层收口：`tcp_connect()` 里 connect 前 `fcntl` 设非阻塞、connect 后 `select()` 等可写事件、醒来后 `getsockopt(SO_ERROR)` 取真实结果；等待上限来自 `cfg->timeout_ms`（缺省 `ESP_TLS_DEFAULT_CONN_TIMEOUT` = 10 s）。TCP keepalive（`tls_keep_alive_cfg_t`）和 `SO_BINDTODEVICE` 绑定网卡也是在这里统一 setsockopt 的。

### 3. mbedTLS 上下文初始化：一行都不能少的参数清单

`esp_tls_mbedtls.c:set_client_config()` 是客户端配置的唯一入口，骨架为：

```c
if (!cfg->skip_common_name)                       /* ① SNI + 主机名校验 */
    mbedtls_ssl_set_hostname(&tls->ssl, host);
mbedtls_ssl_config_defaults(&tls->conf, IS_CLIENT, STREAM, PRESET_DEFAULT);
                                                   /* ② authmode 由下面四选一 */
if      (cfg->crt_bundle_attach)  cfg->crt_bundle_attach(&tls->conf);   /* bundle */
else if (cfg->use_global_ca_store) set_global_ca_store(tls);            /* global */
else if (cfg->cacert_buf)          set_ca_cert(tls, buf, len);          /* per-conn CA */
else if (cfg->psk_hint_key)        mbedtls_ssl_conf_psk(...);           /* PSK */
else
#ifdef CONFIG_ESP_TLS_SKIP_SERVER_CERT_VERIFY
    mbedtls_ssl_conf_authmode(&tls->conf, MBEDTLS_SSL_VERIFY_NONE);
#else
    return ESP_ERR_MBEDTLS_SSL_SETUP_FAILED;   /* 什么都不给 = 编译期拒绝放行 */
#endif
...
mbedtls_ssl_setup(&tls->ssl, &tls->conf);      /* 这里分配 in_buf/out_buf */
mbedtls_ssl_set_bio(&tls->ssl, &tls->server_fd, mbedtls_net_send,
                    mbedtls_net_recv, NULL);   /* IO 落到 lwIP socket */
```

优先级链是硬编码的：**bundle > 全局 store > 每连接自带 CA > PSK > skip**。最后一级是安全闸门——只有同时打开 `CONFIG_ESP_TLS_INSECURE` 和 `CONFIG_ESP_TLS_SKIP_SERVER_CERT_VERIFY` 才会走到 `VERIFY_NONE`，否则没给任何信任来源直接配置失败。这是值得学习的 API 设计：把"危险默认"变成"编译开关保护下的显式选择"。另外注意 `skip_common_name=true` 会同时关掉 SNI 和主机名匹配（v6 的警告日志原文："This disables ALL server-name authentication (CN/SAN/SNI)"）——本章实验连的是裸 IP，所以全程带着这条 warning 跑。

握手包装 `esp_mbedtls_handshake()` 把 mbedTLS 的返回值折叠成三态：`0`（WANT_READ/WANT_WRITE，异步下继续等）、`1`（成功）、`-1`（失败）。失败时调 `esp_mbedtls_verify_certificate()` 用 `mbedtls_ssl_get_verify_result()` 捞出证书 flags 存进错误跟踪器——调用方在 `-1` 之后能同时拿到三类错误码（见 22.7.e 实验）。

## 22.4 mbedTLS 与 lwIP 的咬合：日志逐行看

### 1. 收方向：nb_want 攒包协议

打开 `CONFIG_MBEDTLS_DEBUG` 后，一次真实的收包流程在串口上是这样的（本章 run15 日志原文）：

```text
I (xxx) mbedtls: ssl_msg.c:5663 => read
I (xxx) mbedtls: ssl_msg.c:4040 => read record
I (xxx) mbedtls: ssl_msg.c:1865 => fetch input
I (xxx) mbedtls: ssl_msg.c:2005 in_left: 0, nb_want: 5
```

`fetch input` 在目标就是 **`ssl->in_buf` 本体**：`net_recv()` 的 buf 参数直接指向 `in_buf + in_left`，要求凑够 `nb_want` 字节。先要 5（记录头），解析出头里的 length 后第二次进入时要整个载荷（比如 ServerHello 记录还要再攒几百字节）。所以：

> [!note] TLS 下的 recv 语义
> `esp_tls_conn_read(buf, n)` 里的 n **不是**一次网络读的量，而是"当前已解密 record 内剩余可消费字节数"的上限。底层可能已经躺着一整条 16KB 记录，你每次却只能拿走应用层要求的那么多；反之记录没攒齐时即使 n 再大也会得到 `MBEDTLS_ERR_SSL_WANT_READ`(-0x6900)。本章在吞吐排障时打印到它：恰好是日志里的 `read r=-26880`。

### 2. 发方向：OUT_CONTENT_LEN 定长分片

`esp_mbedtls_write()` 的循环（`esp_tls_mbedtls.c`）：

```c
while (written < datalen) {
    if (write_len > MBEDTLS_SSL_OUT_CONTENT_LEN)
        write_len = MBEDTLS_SSL_OUT_CONTENT_LEN;
    if (datalen > MBEDTLS_SSL_OUT_CONTENT_LEN)
        ESP_LOGD(TAG, "Fragmenting data of excessive size ...");
    ret = mbedtls_ssl_write(&tls->ssl, data + written, write_len);
```

IDF 默认 `OUT_CONTENT_LEN=4096`，一次发送 10KB 会被切成 3 条记录。而 MSS 视角下（guest MTU 1500 → MSS 1460）：4096B 记录 + 开销经 `tcp_write` 后仍会被 lwIP 按 MSS 分成 3 个报文段——**TLS 分片粒度和 TCP 分段粒度是两级独立的切刀**，选记录大小主要影响的是 `out_buf` 内存，不是包数。真正要小心的是反方向：如果服务器（或本地应用）一次灌入超过 IN 内容长度的大记录，mbedTLS 会以 `MBEDTLS_ERR_SSL_INVALID_RECORD` 断链。

### 3. 记录大小最优解：MTU 内最省的是"不留尾"

22.5 节会给 in/out 缓冲的公式。这里先说结论性的工程规则：IN 缓冲按最坏情况（对端最大记录 16384+开销）常驻；若双方都受你控制（如设备间私有协议），配 max_fragment_length 扩展或干脆对半砍 CONTENT_LEN（菜单里 `MBEDTLS_SSL_MAX_CONTENT_LEN` 支持 512~16384），IN/OUT 各省下来的就是纯 RAM。

### 4. renegotiation 与 session ticket：默认值背后的取舍

| 能力                  | Kconfig（IDF v6）                    | 默认             | 嵌入式视角                                                  |
| --------------------- | ------------------------------------ | ---------------- | ----------------------------------------------------------- |
| TLS renegotiation     | `MBEDTLS_SSL_RENEGOTIATION`          | y（依赖 TLS1_2） | 省 flash/RAM 且减小攻击面，产品端常见关闭                   |
| 客户端 session ticket | `MBEDTLS_CLIENT_SSL_SESSION_TICKETS` | y                | 重连免全套握手的前提（配合 `esp_tls_get_client_session()`） |
| 服务端 session ticket | `MBEDTLS_SERVER_SSL_SESSION_TICKETS` | y                | 服务端需要额外的密钥轮转上下文                              |
| 保留对端证书          | `MBEDTLS_SSL_KEEP_PEER_CERTIFICATE`  | **n**            | 关掉省 ~4KB/连接，代价是握完拿不到对端证书                  |

最后一行解释了本章实验的一个观测：握手明明完成了，`mbedtls_ssl_get_peer_cert()` 却返回 NULL——因为 IDF 默认不保留对端证书，校验完成后即释放。需要做证书内嵌指纹比对（pinning 的另一种实现）的应用要记得把这个选项打开。

## 22.5 内存预算方法论：把"一次握手多少钱"算清楚

### 1. 公式：两个大头的确切尺寸

Mbed TLS 4.x 在 `library/ssl_misc.h` 里定义了缓冲总长（`library/ssl_tls.c:mbedtls_ssl_setup()` 里两次 `mbedtls_calloc` 的实参）：

```text
BUFFER_LEN = SSL_HEADER_LEN(13) + CONTENT_LEN + PAYLOAD_OVERHEAD

PAYLOAD_OVERHEAD = MAX_IV_LENGTH(16)        /* GCM 显式 IV 与 CBC IV 取最大 */
                 + MAC_ADD                  /* AEAD=16(tag核算位)；CBC-HMAC 最高 48(SHA-384) */
                 + PADDING_ADD              /* 编译进 CBC 套件则预留 256，否则 0 */
                 + CID_EXPANSION            /* DTLS connection id，TLS 流模式为 0 */
```

IDF v6 默认编译出的差值是 `OVERHEAD = 320`，再代入 menuconfig 默认 `IN_CONTENT=16384 / OUT_CONTENT=4096`（`MBEDTLS_ASYMMETRIC_CONTENT_LEN=y`，帮助文本原话：_"enabling this with default values saves 12KB of dynamic memory per TLS connection"_）：

```text
IN_BUFFER_LEN  = 13 + 16384 + 320 = 16717 字节
OUT_BUFFER_LEN = 13 +  4096 + 320 =  4429 字节
两大缓冲合计                             21146 字节
```

这不是纸上谈兵——本章堆饥饿实验让 `mbedtls_calloc` 当场报出了分配失败的实参，与公式一字不差：**`alloc(16717 bytes) failed`**（run14/run15 日志原文）。握手期间在此之上再加：transform 上下文（对称密钥、序列号空间）、握手期 keying material、ECDHE 临时量、RNG（CTR_DRBG）上下文、以及证书解析的临时 ASN.1 结构。

### 2. 实测账本：基线、稳态、峰值、残差四个数

测量方法：`heap_caps_get_free_size/largest/minimum_free_size(MALLOC_CAP_DEFAULT)` 每 100ms 采样（观察任务）＋阶段点即时 stamp；握手峰用 min-ever 差值兜住采样间隙。QEMU esp32 平台、软件密码实现（`CONFIG_MBEDTLS_HARDWARE_AES/SHA/MPI=n`，因 QEMU 无外设仿真；真机默认开硬件）、client+openssl s_server 对话：

| 快照                          | free (B) | 相对本阶段基线           |
| ----------------------------- | -------- | ------------------------ |
| boot 稳定后                   | 226388   | —                        |
| RSA 阶段开始前                | 227960   | （前序清理完成后的高位） |
| TLS 连接保持中（稳态）        | 200976   | **−26 984**              |
| 握手瞬时深坑（min-ever 差值） | 191256   | **峰值 −33 072**         |
| close()+500ms 之后            | 226920   | −1040（残差≈1KB）        |

三个数合起来讲了个清晰的故事：**稳态成本 ≈ 两条大缓冲(21146B) + transform/RNG 等常驻 ≈ 27KB；握手过程的额外瞬时尖峰（key derivation、证书 ASN.1 解析临时区）再多 ~6KB；连接干净关闭后几乎全额归还**。对了拍：`27KB − 21KB = 6KB` 恰好是 mbedtls_ssl_context 栈内字段之外的常驻分配；关闭后 free 回到距基线 1040B 处，账单闭合。

多连接并存的换算即开即得：**每条 TLS 连接 ≈ 27KB RAM 起点 + 握手瞬间 33~37KB 高水位**。4MB PSRAM 的设备放十几个并发 HTTPS 客户端没问题；240KB 片内 RAM 的裸 ESP32 上就得精打细算了。

### 3. 可裁剪项清单：每一项省多少

| 手段                | 关闭什么                                 | 省多少（每连接）               | 备注                                               |
| ------------------- | ---------------------------------------- | ------------------------------ | -------------------------------------------------- |
| 不对称缓冲          | 默认已开（y）                            | 已省 12KB                      | 对照全对称 16384 双份                              |
| 降低 CONTENT_LEN    | `MBEDTLS_SSL_MAX_CONTENT_LEN=2048` 类    | 每方向 ~(16384−N)B             | 双端可控时安全                                     |
| 动态缓冲            | `MBEDTLS_DYNAMIC_BUFFER=y`               | 握手完即刻归还没用满的部分     | 握手瞬时不降、稳态降；代价是运行期反复 malloc/free |
| 丢弃对端证书        | `MBEDTLS_SSL_KEEP_PEER_CERTIFICATE=n`    | ~4KB                           | 默认已关（帮助文本原值）                           |
| 砍 CBC 套件         | 仅留 GCM/ChaCha                          | PADDING_ADD 256 + MAC_ADD 差值 | 同时省掉 CBC 实现 flash                            |
| 砍握手代码          | `KEY_EXCHANGE_RSA/DHE-*` 只留 ECDHE-P256 | 数 KB flash + 更小握手临时区   | 也提速（RSA 证书验签除外）                         |
| session ticket 复用 | 第二次起跳过完整握手                     | 握手期峰值整体免除             | 时延收益更明显                                     |

## 22.6 Vanilla lwIP 与 ESP-IDF lwIP：边界处的差异清单

先把概念理直：**esp-tls 不是 lwIP 的一部分**，vanilla lwIP 世界里对应物是你手写的那层"mbedTLS bio 回调 + 证书装载"。差异因此不在协议栈而在适配习惯：

| 维度       | Vanilla lwIP + 裸 mbedTLS           | ESP-IDF（esp-tls 封装）                                                        |
| ---------- | ----------------------------------- | ------------------------------------------------------------------------------ |
| 连接建立   | 自拼 getaddrinfo/connect/bio_set_fd | 一个 API + 五态可重入状态机                                                    |
| 错误传递   | mbedtls err 散落                    | 事件跟踪器分类（system/mbedtls/cert_flags/esp 四通道）                         |
| 证书信任   | 自己 parse + conf_ca_chain          | bundle（编译期打包 Mozilla 根）/全局/per-conn 三级                             |
| 内存归口   | 你自己的 heap/mempool               | 归 libc 堆（LWIP 全堆化见 ch5）；另有 alloc 模式菜单（internal/SPIRAM/custom） |
| 硬件加速   | 无此概念                            | AES/SHA/MPI/ECC 外设选项 + soft fallback（QEMU 里我们特意全关）                |
| 时钟源     | `mbedtls_timing` 你实现             | `esp_tls_platform_port.c` 提供                                                 |
| debug 输出 | stdout                              | `mbedtls_esp_enable_debug_log()` 桥到 ESP_LOG                                  |

裁剪相关 Kconfig 一览（默认值为 v6 当前值，都在 `components/mbedtls/Kconfig` 或 `components/esp-tls/Kconfig`）：

| 选项                                                     | 默认            | 省下的去向                                  |
| -------------------------------------------------------- | --------------- | ------------------------------------------- |
| `MBEDTLS_SSL_IN_CONTENT_LEN`                             | 16384           | ↓ 即 IN 缓冲线性变小                        |
| `MBEDTLS_SSL_OUT_CONTENT_LEN`                            | 4096            | 同上（出向）                                |
| `MBEDTLS_DYNAMIC_BUFFER(+FREE_CA/FREE_CONFIG)`           | n/n/y 链        | 按需分释放，稳态最低                        |
| `MBEDTLS_CERTIFICATE_BUNDLE`(FULL/CMN)                   | y(FULL)         | CMN 砍掉低频根证书，bundle 常驻小几 KB × N  |
| `MBEDTLS_KEY_EXCHANGE_RSA / DHE_RSA / ECDHE_ECDSA / PSK` | y               | 每砍一个少一组套件表 + 密钥交换实现         |
| `MBEDTLS_ECP_DP_*_ENABLED`                               | 部分 y          | 曲线表与实现，留 secp256r1/25519 即覆盖主流 |
| `MBEDTLS_HARDWARE_AES/SHA/MPI`                           | y(有外设的芯片) | =n 走软算，只在仿真器口径下用（真机勿关！） |
| `MBEDTLS_ERR_*_STRINGS`(`MBEDTLS_ERROR_STRINGS`)         | y               | 纯 flash，发布版可关                        |
| `MBEDTLS_DEBUG`                                          | n               | ~十几 KB flash + 运行期格式化开销           |

一句话总结边界哲学：**lwIP 管"字节怎么可靠过网"，mbedTLS 管"字节怎么保密"，esp-tls 管"这两者怎么用最少的样板代码接起来，并且别让我把私钥证书摆错位置"**。

## 22.7 实验：给一次 TLS 握手开全套仪表

实验工程：`practice/lwip-ch22-tls-esp-tls-mbedtls/`（ch3 bring-up 模板 + esp-tls/mbedtls 组件）。测量的对象是五件事：握手逐行日志与三段耗时（a）、100ms 粒度的内存曲线与两级增量（b）、堆饥饿下的死法与自愈（c）、明文/TLS 同径吞吐对比（d）、证书三种姿势（e）。

### 0. 环境：宿主机双服务器 + 内建回环服务器

```bash
cd practice/lwip-ch22-tls-esp-tls-mbedtls/main/certs
# 三张自签证书：RSA 主角 / ECDSA 对照 / 冒名顶替者
openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
  -subj "/CN=localhost" -keyout ch22_rsa.key -out ch22_rsa.crt
openssl ecparam -name prime256v1 -genkey -noout -out ch22_ec.key
openssl req -x509 -key ch22_ec.key -days 30 -subj "/CN=localhost" \
  -out ch22_ec.crt
openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
  -subj "/CN=imposter.example" -keyout ch22_wrong.key -out ch22_wrong.crt
# 服务器 A：RSA + 回显（-msg 打印记录级 trace，供排障）
openssl s_server -accept 22443 -rev -msg -cert ch22_rsa.crt \
  -key ch22_rsa.key -tls1_2
# 服务器 B：ECDSA 对照
openssl s_server -accept 22444 -rev -quiet -cert ch22_ec.crt \
  -key ch22_ec.key -tls1_2
```

构建运行沿用系列公约第 3 节的标准流程；本工程无 hostfwd 需求，QEMU 以 `-nic user,model=open_eth` 直启。guest 视角的测量全部由固件打点：`esp_timer_get_time()` 做 µs 级时间戳，观察任务 100ms 采样堆。

### a. 握手全记录与三段耗时

固件把连接拆成两段计时：自己的 socket/connect（TCP 握手），再把 fd 通过 `esp_tls_set_conn_sockfd/set_conn_state(CONNECTING)` 移交给 esp-tls 续跑（TLS 握手）。外部 openssl 目标的实测（run15）：

```text
[phase-a] tcp_connect=8997 us | tls_handshake=334671 us | total=343668 us
[neg] version=TLSv1.2 suite=TLS-ECDHE-RSA-WITH-AES-256-GCM-SHA384 peer_cert=0 bytes
[phase-a] app-echo #0 rtt=5149 us payload=14 B
... (#1~#4 依次 8204/6404/5613/5870 us，含外部 -msg 服务器的日志写入抖动)
```

EC 证书对照组（同一轮的第二个连接，路由缓存已热）：

```text
[phase-a] tcp_connect=2110 us | tls_handshake=347850 us | total=349960 us
[neg] version=TLSv1.2 suite=TLS-ECDHE-ECDSA-WITH-AES-256-GCM-SHA384 peer_cert=0 bytes
```

解读三条：

1. **TCP 是毫秒级、TLS 是百毫秒级**——两个数量级的差距全部来自 ECDHE 密钥生成/共享与 X.509 验签（qemu Xtensa 软算口径；真机开启硬件 MPI/ECC 后该比值会显著缩小，这正是配置项存在的意义）。
2. 首次 `tcp_connect` 8997µs vs 第二个连接的 2110µs——[[2026-08-26-lwip-deep-dive-ch8-ethernet-arp|第八章]] 的 ARP 首包税在真实业务面前又现身了一次。
3. `peer_cert=0 bytes` 不是 bug：`MBEDTLS_SSL_KEEP_PEER_CERTIFICATE=n` 默认握手后即弃（22.4 节）。握手期内它确实在——debug 日志里能看到完整的 `Certificate` 记录解析全程。

握手行日志最有价值的两条摘录（完整 ClientHello 17 套件列表太长，只取关键行）：

```text
I (xxx) mbedtls: ssl_tls.c:4201 client state: MBEDTLS_SSL_CLIENT_HELLO
D (xxx) mbedtls: ssl_client.c:386 adding EMPTY_RENEGOTIATION_INFO_SCSV
D (xxx) mbedtls: ssl_client.c:395 client hello, got 17 cipher suites
D (xxx) mbedtls: ssl_client.c:280 NamedGroup: x25519 ( 1d )
...
W (xxx) mbedtls: ssl_tls12_server.c:xxxx found session ticket extension
D (xxx) mbedtls: ssl_msg.c:2005 in_left: 0, nb_want: 5
```

### b. 内存账本：采样窗、三个数与构成核算

观察任务 100ms 一拍的 min_free 序列（关键窗口摘要）：

| 窗口                    | 时间范围(ms) | 窗口 min_free(B) | 含义                                    |
| ----------------------- | ------------ | ---------------- | --------------------------------------- |
| boot-baseline           | 1169–1267    | 224368           | 系统底噪                                |
| RSA-handshake           | 1664–1866    | 197088           | 客户端握手主坑                          |
| closing→settled         | 1964–2764    | 226920           | 归还后稳态（−1040 残差）                |
| EC-handshake            | 3165–3464    | 193680           | EC 的窗口采样值更低、RSA 的瞬时尖峰更深 |
| thr-setup               | 4466–5474    | 161960           | **本地服务端+客户端同时在握手**         |
| thr-t0..t2（持续 140s） | —            | ~170300          | 会话稳态池                              |
| starved-floor           | ~142500      | 13528            | 人为压到底（largest 仅 2944B！）        |

结合 `[mem]` stamp：**握手峰值增量 33072B（min-ever 法）、稳态增量 26984B、关闭残差 1040B**（run15 原文 `[ledger] HANDSHAKE_PEAK_DELTA(RSA) = 33072 bytes`）。按 22.5 的公式拆分：21146B 是两个大缓冲，剩下 ~12KB 是 transform/handshake 常驻 + RNG + 客户端解析 server 证书的临时区——证书越大这个尾巴越长，Mozilla 全量 bundle 场景要用动态缓冲方案压平它。

> [!tip] 测量方法的两个坑
> 其一，min-ever（`heap_caps_get_minimum_free_size`）是多区域 sum-of-minima，跨长会话看趋势可以，跨阶段取差值会把历史低洼错算进本期——所以正文数据都用「阶段前后 min-ever 差」+「周期采样窗内 min」双指标交叉；其二，一个真正模拟"同时多连接"的峰值要看 **thr-setup 窗口**（161960B）：那一刻 guest 里同时存在进行中的服务端握手与客户端握手，比任何单连接都深——预算按这个口径留余量才叫工程。

### c. 故障注入：堆饥饿下的握手死亡报告

手法复用 [[2026-08-26-lwip-deep-dive-ch5-memory-management|第五章]] 的堆饥饿注入（本轮内联进主任务消除竞态）：malloc(4096) 连吃到 free≤12000 为止，然后发起同样的握手。run15 现场：

```text
[starve] grabbed=52 held=212992B free=13528 largest=2944
[phase-c] attempting TLS handshake with only 13528 bytes free ...
W (144461) mbedtls: ssl_tls.c:1204 0x3ffdf414: alloc(16717 bytes) failed
E (144461) esp-tls-mbedtls: mbedtls_ssl_setup returned -0x008D
[conn] TLS to 10.0.2.2:22443 FAILED after 4504 us
[err] handshake: last_esp_err=0x8017 tls_code=-0xffffff73 cert_flags=0x0
       (sys_errno=0 mb_code=-0x0000)
```

四条值得背下来的结论：

1. **死点正是 22.5 预言的位置**：`mbedtls_ssl_setup()` 第一笔 `calloc(in_buf)` 要求 16717B，当前自由块最大只有 2944B，必须失败。
2. **死得极早极便宜**：从发起 try 到判死仅 4.5ms——失败发生在碰巧未发出 ClientHello 之前（`ssl_setup` 先于 BIO 写入），对端 openssl 甚至毫无感知。这是把资源检查放在协议交互之前的天然优点。
3. **错误码跨版本搬家**：教材时代的 `MBEDTLS_ERR_SSL_ALLOC_FAILED = -0x7F00` 在 Mbed TLS 4.x 已重定义为 `PSA_ERROR_INSUFFICIENT_MEMORY = -141`（`ssl.h:101` 直通 `crypto_values.h:144`），esp-tls 的错误跟踪器把它如实记录为 `tls_code=-141(-0x8D)`、ESP 层 `last_esp_err=0x8017(ESP_ERR_MBEDTLS_SSL_SETUP_FAILED)`。写代码匹配字面值的老项目要当心。
4. **自愈只需 free**：`starve_release()` 归还 212992B（free 回 226396）后重试立刻成功：`[phase-c] HEALED: handshake ok in 229030 us`。没有任何持久性损坏——OOM 死亡是干净的、可恢复的，前提是你的错误处理路径真的把句柄 destroy 干净了。

> [!warning] 本次调试踩出的真实事故（留给读者对照 ch23）
> 第一版 phase C 为了"对冲延迟释放"加了个 top-up 重抓循环，结果每次调用都会把已持有的块指针数组清零——212KB 就地蒸发成孤儿内存，后续所有阶段全军覆没在 alloc 失败上，且日志表面完全看不出谁吃了内存。最终靠 `[starve] grabbed=0 held=0` 这条反常日志定位。内存实验最大的敌人从来不是"吃不掉"，而是"以为还捏着其实已经丢了"。

另一条真实的坑留档：早期版本曾观察到"SLIRP 外环上的 TLS 建立后首条应用记录永远等不到响应，但同样字节流在本机 python client 上瞬时往返"的现象——先后对比过 openssl（-quiet 有无一致）与 python ssl 服务端、并用 tcpdump -X 证明 guest 的 1053B 记录完整到达宿主机 kernel（segment 被 ACK 但进程 never replayed）。最终放弃外环、改用 guest 内部 loopback 服务器做吞吐配对（见 d）。这类"传输层活着、会话层僵死"的问题本身就是第二十三章调试工具箱的好素材。

### d. 吞吐对比：同径明文 vs TLS 的"加密税"

负载：1024B/消息 ×2048 条锁步回显，单轮 2MiB；明文/TLS 交错三轮（配对测量纪律：同环境、同时段、交替进行，消除宿主机负载漂移）。两条路径都在 guest 内环 loopback 上（分别打本地内建明文/TLS echo 服务），网络条件完全相同。下面引用其中一轮的完整输出；文中各节其余数字来自同一 firmware 的相邻轮次，跨轮差异仅体现在绝对值（约 ±12%，宿主机负载），比值稳定：

```text
[thr] round0 PLAIN 2097152 B in 1097937 us = 15.28 Mbit/s
[thr] round0 TLS   2097152 B in 42214374 us = 0.40 Mbit/s
[thr] round1 PLAIN 2097152 B in 1116041 us = 15.03 Mbit/s
[thr] round1 TLS   2097152 B in 43226449 us = 0.39 Mbit/s
[thr] round2 PLAIN 2097152 B in 1143997 us = 14.67 Mbit/s
[thr] round2 TLS   2097152 B in 44286847 us = 0.38 Mbit/s
[thr] MEAN plain=14.99 Mbit/s tls=0.39 Mbit/s tax=97.4%
```

结论表：

| 维度              | 明文 echo          | TLS echo（AES-256-GCM/SHA-384）    |
| ----------------- | ------------------ | ---------------------------------- |
| 吞吐（均值±极差） | 14.99 Mbit/s ±0.31 | 0.39 Mbit/s ±0.01                  |
| 跨轮次复测均值    | 13.4 ~ 15.0 Mbit/s | 0.37 ~ 0.39 Mbit/s                 |
| 每字节成本比      | 1×                 | **~38×**                           |
| 内存占用          | socket pcb 级      | +27KB 稳态 / +33KB 峰值            |
| 重连成本          | ~0                 | 260~350ms 全额握手（可 ticket 化） |

97% 的税率是这个特定口径的真实数字：QEMU 仿真的 240MHz Xtensa 上纯软件执行 AES-256-GCM 加解密 + SHA-384（硬件加速已刻意禁用），且套件选的是最重的 SHA-384 变体。真机上三件武器都能改写它——AES/SHA/MPI 外设加速、切到 SHA-256/AES-128 套件、session resumption 免掉后续握手。方法是本章给的，数字请按自己的真机口径重测。

### e. 证书验证三种姿势的失败现场

同一台 openssl s_server，三次不同配置的连接（skip 为编译期放行的测试姿势）：

**E0 — 什么都不给**（依赖 `CONFIG_ESP_TLS_SKIP_SERVER_CERT_VERIFY`）：

```text
[e0] connection ACCEPTED with NO verification data
      (CONFIG_ESP_TLS_SKIP_SERVER_CERT_VERIFY)
```

> [!warning] 生产镜像绝不打开这两个 Kconfig——否则任何"忘记带 CA"的调用点都会静默降级成无验证连接。

**E1 — 固定正确自签证书 + common_name 匹配**：

```text
D (...) mbedtls: ssl_tls.c:8881 Certificate verification flags clear
[e1] connected with PINNED cert, handshake=247955 us
```

内部设备互信的最简正解：不需要 CA 树，把对端的叶证书本体当 trust anchor。

**E2 — 固定了冒名顶替者的证书**（这才是最值得看的失败路径）：

```text
W (...) mbedtls: ssl_tls.c:8778 x509_verify_cert() returned -9984 (-0x2700)
D (...) mbedtls: ssl_msg.c:5059 send alert level=2 message=48
D (...) mbedtls: ssl_tls.c:8878 ! Certificate verification flags 00000008
E (...) esp-tls-mbedtls: mbedtls_ssl_handshake returned -0x2700
I (...) esp-tls-mbedtls: (FFFFD900): X509 - Certificate verification failed...
[err] handshake: last_esp_err=0x801a tls_code=-0xffffd900 cert_flags=0x0
[conn] TLS to 10.0.2.2:22443 FAILED after 33898 us
```

三层翻译：mbedTLS 层 `-0x2700(X509_CERT_VERIFY_FAILED)` + flags `0x08 = MBEDTLS_X509_BADCERT_NOT_TRUSTED`（`x509.h:90` 原文）；协议层发出 fatal alert unknown_ca(48)；esp-tls 错误跟踪器给出 `last_esp_err=0x801A(ESP_ERR_MBEDTLS_SSL_HANDSHAKE_FAILED)`。**一次失败同时在三个抽象层级留下指纹**——这就是 22.3 节说的"分层错误收集"的价值：你的 app 无论订阅哪一层，都能拼出完整案情。

## 22.8 小结

- **esp-tls 是个约两千行的胶水层**：五态可重入连接状态机（INIT/CONNECTING/HANDSHAKE 经 `esp_tls_low_level_conn()`）+ read/write 函数指针分路（TLS/明文直通二选一）+ 超时/keepalive/绑卡统一收口，对 lwIP 零改动。
- 证书验证是一个**硬编码优先级链**：crt_bundle > global_ca_store > per-conn cacert > PSK > skip；最后一级需要两个 insecure Kconfig 同时打开才能到达，否则"什么都不给"直接编译期拒绝——安全的默认应该靠编译器守护而不是文档呼吁。
- TLS on lwIP 的**收路径**是"recv 进 in_buf 攒完整记录再就地解密"（日志特征：`in_left / nb_want` 成对推进），**发路径**按 `OUT_CONTENT_LEN`(默认 4096) 分片，两者都与 MSS 各切各的。`WANT_READ(-0x6900)` 在应用侧表现为读返回 `-26880`，是必认识的信号。
- **内存公式**（Mbed TLS 4.x）：`IN/OUT_BUFFER_LEN = 13 + CONTENT_LEN + 320(IV16+MAC48+CBC-pad256)`；IDF 默认 16717 + 4429 = 21146B，加上 transform/RNG/证书临时区，实测单连接**稳态 ~27KB、握手峰值 ~33KB**（含双端握手并存时最高可探到 ~66KB 深水），close 后残差 ~1KB。
- **吞吐税**要在同口径下配对测才有意义：内环 lockstep 口径下本次为 **97%（38×）**；改写它的三个旋钮是真机外设加速、session resumption、SHA-256/AES-128 套件。
- 饿死它一次就知道它怕什么：free 13.5KB、largest 2.9KB 时 `alloc(16717)` 在 4.5ms 内死刑，错误码 -141/-0x008D（4.x 新地址）+ 0x8017 双轨上报；归还内存立即满血复活。
- Vanilla vs IDF 的边界清单记两条主线：IDF 把「你自己写的 bio/证书装载/错误传递」产品化成组件与 Kconfig；并把 mbedtls 推到 4.x/PSA 时代——老宏值/老错误码一律以本仓库源码为准。

---

**Part VI《协议之上的世界》到此收官。**从 [[2026-08-26-lwip-deep-dive-ch20-http-server| 第二十章]] 的 HTTP 到本章的 TLS，我们一直在做同一件事：把"增加一层"变成"看清一层新增的字节、内存与时延账单"。当账单摊开后，你会发现每一层都不神秘——神秘感只是没有测量而已。

下一章进入 **Part VII《性能与调试》**：离开功能搭建的舒适区，把自己武装成协议栈医生。我们将把散落在前面各章的观察技巧（ext-callback 记录仪、linkoutput 替换、stats 计数器、GDB/QEMU 半主机、heap 视图、协议分诊套路）整合成一个系统化的调试工具箱——包括本章那条"记录层僵死"悬案的完整破案过程重现。见 [[2026-08-26-lwip-deep-dive-ch23-debugging-toolbox|第二十三章]]。
