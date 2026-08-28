---
title: "lwIP 深度解析（二十）：HTTP server：esp_http_server 走读与压测"
date: 2026-08-26
description: "在 RTOS 上 HTTP 服务器只有事件驱动单线程一条路。走读 esp_http_server 的 select 单任务模型、fd→会话池、handler 分发链与缓冲策略，指出 keep-alive 三层语义混淆与 chunked 断裂、Content-Length 无上限等边界；用 keep-alive 开/关 × 100B/10KB 配对压测、Slowloris 与大 POST 两组故障注入给出真实数字：KA 复用使 150 请求只建 4 连接，关闭后 p99 从 12ms 爆到 6000ms；Slowloris 半个头拖死会话池被 recv_wait_timeout 以 5s/个的节奏串行回收，调小到 2s 后 ≤6s 恢复。"
tags: [lwip, http-server, esp32, esp-idf, esp-http-server, qemu, slowloris]
---

> [!info] lwIP 深度解析系列 0. [[2026-08-26-lwip-deep-dive-series-index|系列索引]] 20. **第二十章：HTTP server：esp_http_server 走读与压测**

# lwIP 深度解析（二十）：HTTP server：esp_http_server 走读与压测

这一章回答三个问题：**HTTP 服务器的并发模型该选「一连接一线程」还是「事件驱动单线程」**（以及在 RTOS 上为什么后者是唯一现实解）、**esp_http_server 在 lwIP socket 之上到底加了什么**（任务模型、会话池、分发链、缓冲策略）、**keep-alive 和会话池是怎么被管理的**（这里藏着一个最容易混淆的三层语义）。读完它，你应该能对着任何嵌入式 HTTP 框架 30 秒内判断出它的并发模型和第一瓶颈。源码参照：ESP-IDF v6.0.2 `components/esp_http_server/src/`（httpd_main.c / httpd_sess.c / httpd_parse.c / httpd_txrx.c / httpd_uri.c）与 Kconfig 实测拼写，Vanilla lwIP 对照 `components/lwip/lwip/src/apps/http/httpd.c`。所有实验数字来自本机 QEMU (openeth) 实测，方法学延续 [[2026-08-26-lwip-deep-dive-ch19-isr-and-priority-design|第十九章]] 的配对测量纪律。

---

## 20.1 并发模型：为什么没有「一连接一线程」这个选项

### 1. 线程模型的账，在 MCU 上根本立不住

一连接一线程（thread-per-connection）是 Linux 服务器世界的舒适区，代价被大内存掩埋了。把它搬到 ESP32 上算一遍：

| 资源           | 一连接一线程                             | 本机预算                        |
| -------------- | ---------------------------------------- | ------------------------------- |
| 任务栈下限     | ~2~4 KB/连接（HTTP 解析 + handler 峰值） | 全机 DRAM ~300 KB               |
| TCB + 内核对象 | ~100 B 量级/连接                         | 同上                            |
| 上下文切换     | 每次请求至少数次切换                     | `tcpip_thread` 本身已是共享单点 |

7 个并发连接就要烧掉 14~28 KB 栈，而 [[2026-08-26-lwip-deep-dive-ch5-memory-management|第五章]] 已经拆过 IDF lwIP 是全堆化的——这 28 KB 正是从协议栈抢内存。更致命的是**正确性**：`httpd_req_t`/解析状态若随线程复制，每个 per-connection 线程都要与 tcpip 线程竞争同一批 socket 邮箱（[[2026-08-26-lwip-deep-dive-ch16-socket-netconn-vfs|第十六章]] 的 VFS 层），复杂度全花在了错误的方向上。

### 2. 事件驱动单线程：RTOS 上的唯一现实解

于是只剩一条路：**一个服务任务 + I/O 多路复用**，所有连接的收发与处理串行化在同一个任务里。浏览器时代的 Apache→Nginx 演化在这里重演，只是动机从「省 CPU」变成「活下来」。esp_http_server 的选择就是这个模型的最直白形态——`httpd_thread()`（`src/httpd_main.c`）整个生命周期就是一行循环：

```c
/* httpd_main.c: httpd_thread() 主体——全部业务就是反复调 httpd_server() */
while (1) {
    ret = httpd_server(hd);      /* select → 控制消息 → 会话 → accept */
    if (ret != ESP_OK) break;
}
```

它的收益和代价在第 19 章 [[2026-08-26-lwip-deep-dive-ch13-tcpip-thread-mailbox|tcpip_thread]] 身上都见过：**零锁、零竞态、缓存友好**；换来的是**任意一个连接卡住就拖住全场**——这不是理论缺陷，20.6 节的 Slowloris 实验会让你亲眼看到回收 7 个慢会话花了 35 秒。

---

## 20.2 架构走读：select 单任务与会话池

### 1. 源码地图

| 文件                   | 行数  | 职责                                               |
| ---------------------- | ----- | -------------------------------------------------- |
| `src/httpd_main.c`     | ~600  | httpd 任务、select 主循环、accept、内部控制 socket |
| `src/httpd_sess.c`     | ~520  | 会话池（fd↔sock_db）、LRU 记账、开关与枚举         |
| `src/httpd_parse.c`    | ~1270 | 接收驱动 + http_parser 回调装配 + header 存取      |
| `src/httpd_uri.c`      | ~370  | URI 表注册/查找/分发（404/405 判定）               |
| `src/httpd_txrx.c`     | ~840  | resp_send/recv 封装、错误响应、异步请求拷贝        |
| `src/esp_httpd_priv.h` | ~610  | sock_db / parser 内部结构、`PARSER_BLOCK_SIZE` 等  |

组件自带 Kconfig 共 9 个选项（拼写逐一 grep 过）：`HTTPD_MAX_REQ_HDR_LEN`(默认 1024)、`HTTPD_MAX_URI_LEN`(512)、`HTTPD_ERR_RESP_NO_DELAY`(y)、`HTTPD_PURGE_BUF_LEN`(32)、`HTTPD_LOG_PURGE_DATA`(n)、`HTTPD_WS_SUPPORT`(n)、`HTTPD_QUEUE_WORK_BLOCKING`、`HTTPD_SERVER_EVENT_POST_TIMEOUT`(2000ms)、两个 WS handshake callback 开关。注意：**没有任何 Content-Length 上限类配置**——这个缺席在 20.8 节有后果。

### 2. 任务模型：一个 httpd 任务 + 一对内部 UDP 控制口

`httpd_start()` 用 `HTTPD_DEFAULT_CONFIG()` 里的参数创建名为 `"httpd"` 的任务（优先级 `tskIDLE_PRIORITY+5`=5、栈 4096、默认 `core_id=tskNO_AFFINITY`，实验里显式钉核 0 保证测量矩阵稳定）。每个 fd 上 `SO_RCVTIMEO/SO_SNDTIMEO` 取自 `recv_wait_timeout/send_wait_timeout`（默认各 **5 秒**）。

最有意思的设计是**内部控制平面**：除了 listen_fd，组件还偷偷开了三个内部 socket（`httpd_server_init()`）：

```text
listen_fd : TCP :80              ← 业务入口
ctrl_fd   : UDP :32768(ESP_HTTPD_DEF_CTRL_PORT) 收方向
msg_fd    : UDP 同端口 发方向     ← httpd_queue_work()/shutdown 都走这对"本地 UDP 信箱"
```

`httpd_queue_work()` 把一个 `(函数指针, 参数)` 打包成 UDP 包发给自己，主循环 select 到 `ctrl_fd` 可读时执行（`httpd_process_ctrl_msg()`）。停服不用信号量不打断 select，而是投一条 `HTTPD_CTRL_SHUTDOWN` 消息让循环自己退——**控制消息与数据连接排在同一个 select 里，天然免锁**。20.3 节的异步模式还会再借这条信道一次。

每一圈 `httpd_server()` 按 Case0→1→2 的固定次序收账：

```c
/* httpd_main.c: httpd_server() 骨架 */
fd_set read_set;
FD_ZERO(&read_set);
if (hd->config.lru_purge_enable || httpd_is_sess_available(hd))
    FD_SET(hd->listen_fd, &read_set);        /* 池满且不许驱逐 → 不再收新客 */
FD_SET(hd->ctrl_fd, &read_set);
httpd_sess_set_descriptors(hd, &read_set, &tmp_max_fd);   /* 存活会话全入集 */

int active_cnt = select(maxfd + 1, &read_set, NULL, NULL, NULL);
...
if (FD_ISSET(hd->ctrl_fd, &read_set))          /* Case0: 控制消息/停服/工作队列 */
    httpd_process_ctrl_msg(hd);
httpd_sess_enum(hd, httpd_process_session, &context);     /* Case1: 逐会话处理 */
if (FD_ISSET(hd->listen_fd, &read_set))        /* Case2: 新连接最后接待 */
    httpd_accept_conn(hd, hd->listen_fd);
```

注意 Case1 对每个就绪会话只跑**一个请求**（`httpd_process_session` → `httpd_sess_process` → 一趟 parse+dispatch），随后回到 select 等下一轮唤醒——公平但多付一次循环开销。另有一个防御细节：select 出错（如 fd 失效）时走 `httpd_sess_delete_invalid()` 用 `fcntl(F_GETFD)` 逐槽体检清理。

会话的一生可以从状态视角串起来：

```text
                 accept()+池分配                      收到首字节
  [listen backlog] ────────────→ [SESSION 空闲] ──────────────→ [PARSE/DISPATCH]
                                      ↑    │ recv 超时(recv_wait_timeout)│ handler 阻塞>秒级？
                                      │    └──── 408/400/异常 ──→ [CLOSE] ←──┘
                    下一个 keep-alive 请求原位重来           │ 正常应答后回 [空闲]
                          异步占用: for_async_req=true → 主循环跳过、LRU 免疫
```

`httpd_start()` 还有一道闸门值得记住：服务自身占 3 个 socket，所以要求 `max_open_sockets + 3 ≤ CONFIG_LWIP_MAX_SOCKETS`。IDF 默认 `CONFIG_LWIP_MAX_SOCKETS=10` → **默认最多 7 个客户端会话**（Kconfig 默认值正好压线 7）。

### 3. fd→会话映射：数组池 + 全局 LRU 时钟

会话池就是一块 `calloc(max_open_sockets, sizeof(struct sock_db))` 数组（`httpd_create()`）。每个槽位记录 fd、per-session 用户上下文、send/recv/pending 函数指针（TLS 组件靠它替换成 SSL 读写）、以及两个关键字段：

```c
struct sock_db {
    int fd;                          /* -1 = 空槽 */
    ...
    uint64_t lru_counter;            /* 最近一次服务时刻（全局时钟 stamps） */
    char pending_data[PARSER_BLOCK_SIZE]; /* 128B 推回缓冲，见 20.2.5 */
    bool for_async_req;              /* 异步任务占用中：主循环跳过 + LRU 免疫 */
};
```

LRU 时钟实现极简：全局 `hd->lru_counter` 每服务完一个请求 `++`（`httpd_sess_process()` 末尾），当前值盖到该会话头上——**不需要时间源，比较数字大小就是新旧**。查 LRU 是一次 O(N) 枚举（`HTTPD_TASK_FIND_LOWEST_LRU`），N≤7 所以无所谓。当会话全部关闭时计数器归零防溢出（`httpd_sess_delete()`）。

有一个行为反直觉且重要：**池满时的表现取决于 `lru_purge_enable`（默认 false）**——

- `false`：`httpd_server()` 的 select 集合**直接不含 listen_fd**（"Only listen for new connections if server has capacity"），新连接不再被 accept；
- `true`：满了也照常 listen，accept 进来先触发 `httpd_sess_close_lru()` 经工作队列异步踢掉最旧会话，然后重进循环 accept 新连接。

也就是说不打开 `lru_purge_enable`，拒绝策略是"新连接排队饿死"；打开了才是"旧连接腾位置"。默认值选的是前者——对 Slowloris 反而更糟（见 20.6）。

### 4. handler 分发链：一次请求的五段旅程

请求到来后主循环内一条直线流水线（全部在 httpd 任务上下文执行）：

```text
select 返回 → httpd_sess_process(sess)
  ① httpd_req_new()          清空 req 结构、挂接 sd
  ② httpd_parse_req()        循环{read_block → parse_block}直到 PARSING_COMPLETE
       └ http_parser 回调：cb_url→cb_header_field/value→cb_headers_complete
       └ 校验 method/URI 长度/版本/URL 合法性（verify_url）
  ③ httpd_uri()              UF_PATH 字段定位 path → 查表(URI+method)
       └ 未命中：404；命中但方法不对：405（实测见 20.8.3）
       └ 命中：req->user_ctx = uri->user_ctx → uri->handler(req)
  ④ handler：httpd_resp_send* 组包发送（或返回 ESP_FAIL 关闭）
  ⑤ httpd_req_delete()       purge 未消费 body → 归还/释放 ctx、scratch
```

查找表 `hd_calls[]` 是 `max_uri_handlers=8` 个指针的数组，匹配默认 `strlen+strncmp` 精确比对，可换装通配符匹配器（`httpd_uri_match_wildcard()`，支持尾缀 `*` 与可选字符 `?`）。方法不匹配返回 405 有个短路细节：**错误响应发出后 httpd_uri 直接 FAIL，本次调用不再进入 purge 流程**——20.8.3 的实验证实 POST 打 GET-only URI 是毫秒级"秒拒"，不会构成资源驻留。

### 5. send/recv 缓冲策略：全组件只有四块缓冲

| 缓冲                      | 大小                                   | 生命周期 | 出处                      |
| ------------------------- | -------------------------------------- | -------- | ------------------------- |
| URL 阶段 scratch          | realloc 至 `max_uri_len`(512)          | 单请求   | `init_req_aux/read_block` |
| Header 阶段 scratch       | realloc 至 `max_req_hdr_len`(1024)     | 单请求   | 同上                      |
| `pending_data[]` 推回缓冲 | 固定 128 (`PARSER_BLOCK_SIZE`)         | 会话全程 | `sock_db`                 |
| purge 丢弃缓冲            | 固定 32 (`CONFIG_HTTPD_PURGE_BUF_LEN`) | 栈上临时 | `httpd_req_delete`        |

关键认知：**esp_http_server 从不缓存整个请求体，也不攒响应**。接收侧以 128B 为步长把数据读进 scratch 并喂给 parser（`PARSER_REQUEST` 分块暂停/续跑由 `pause_parsing/unrecv` 协议完成）；body 由 handler 按需 `httpd_req_recv()` 流式消费，handler 不消费的部分在请求结束时以 32B 撒进 dummy 缓冲丢弃。发送侧同样朴素：`httpd_resp_send()` 对 status line 用 `snprintf` 到 malloc 临时串，随后逐字段多次 `send()`（头部间甚至字段间都不合并），每个多余响应头都是 4 次 send call。热路径零日志零大缓冲，这正是它能跑出 20.4 数字的前提。唯一的"缓存外"开销是每响应头的 CRLF 拒绝注入检查（`strpbrk(field,"\r\n")`）与错误响应前临时开 `TCP_NODELAY` 保证错误包不被 Nagle 吞掉（`CONFIG_HTTPD_ERR_RESP_NO_DELAY=y`）。

### 6. 「keep-alive」三层语义：这是最容易踩的认知坑

文档与配置里 `keep_alive` 出现在三个互不相干的位置，必须分开：

| 名字                                              | 层                  | 默认                 | 实际作用                                                                  |
| ------------------------------------------------- | ------------------- | -------------------- | ------------------------------------------------------------------------- |
| HTTP/1.1 persistent connection                    | 应用层语义          | **永远开启（隐式）** | ①~⑤ 流程结束后 select 继续盯同一 fd，下一个请求原地复用，无任何"开关"可关 |
| `config.keep_alive_enable` 及 idle/interval/count | TCP 层 SO_KEEPALIVE | false（开则 5/5/3）  | 死链探测：半开连接兜底，与吞吐无关                                        |
| `config.recv_wait_timeout`（SO_RCVTIMEO）         | socket API 层       | **5 秒**             | 决定 keep-alive 会话空闲多久被回收的唯一裁判                              |

真正的回收路径是：空闲会话的下一个 `read_block()` 在 `recv()` 上睡满 `recv_wait_timeout` → `errno==EAGAIN` 映射为 `HTTPD_SOCK_ERR_TIMEOUT` → `httpd_req_handle_err(HTTPD_408)` → 发送 "408 Request Timeout" 后关会话。20.6 节日志会原样展示这条链。换句话说：**esp_http_server 的 keep-alive 没有"超时配置项"，SO_RCVTIMEO 就是超时配置本身**。

> [!tip]
> 想要"闲置 N 秒踢会话"，改的是 `recv_wait_timeout=N`，不是 `keep_alive_idle`——后者只影响 TCP keepalive 探测报文何时出门。搞混这两者的排查成本极高，因为现象都是"连接莫名断了"。

---

## 20.3 handler 注册、user_ctx 与异步工作队列

### 1. 注册即拷贝，ctx 即寄存

`httpd_register_uri_handler()` 把传入的 `httpd_uri_t` 深拷贝进表（uri 字符串 strdup）。`user_ctx` 是注册期挂在端点上的 `void *`，命中分发时自动装进 `req->user_ctx`——这是组件提供的**唯一合法的"配置传参"通道**。实验工程用它给每个端点挂自己的统计器：

```c
typedef struct { const char *name;
                 volatile uint32_t hits; volatile uint64_t sum_us; } ep_stats_t;

static ep_stats_t g_small = { .name = "/small" };

httpd_register_uri_handler(server, &(httpd_uri_t){
    .uri = "/small", .method = HTTP_GET,
    .handler = h_small, .user_ctx = &g_small });   /* 注册期注入 */

static esp_err_t h_small(httpd_req_t *req) {
    ep_stats_t *self = req->user_ctx;               /* 处理期取回 */
    int64_t t0 = esp_timer_get_time();
    ... render + httpd_resp_send ...
    ep_hit(self, esp_timer_get_time() - t0);        /* guest 侧 µs 级计时 */
}
```

需要跨请求的状态（如登录 session）则用另一条通道：`httpd_sess_set_ctx()` 存进 sock_db 的 `session->ctx`，下个请求经 `req->sess_ctx` 自动带回——fd 即会话键。两套 ctx 的分工：`user_ctx` 随 URI（静态），`sess_ctx` 随连接（动态）。

```c
/* 会话级状态示例：同一条 keep-alive 连接上的多次调用共享一份 ctx */
static esp_err_t h_login(httpd_req_t *req) {
    my_sess_t *s = malloc(sizeof(my_sess_t));
    ...;
    httpd_sess_set_ctx(req->handle, httpd_req_to_sockfd(req),
                       s, free);                    /* 连接关闭时自动 free() */
    return ESP_OK;
}
static esp_err_t h_api(httpd_req_t *req) {          /* 同连接后续请求 */
    my_sess_t *s = httpd_sess_get_ctx(req->handle,
                                      httpd_req_to_sockfd(req));
    /* 注意：handler 内拿到的是 req->sess_ctx 视图；换连接拿不到 */
}
```

会话断开时组件按注册的 `free_fn` 清理（无则 `free()`），这是 sock_db 里 `free_ctx/free_transport_ctx` 两个字段存在的意义。

### 2. 异步工作队列：把 handler 从"快进快出"的枷锁里放出来

单任务模型的铁律是 handler 必须快，否则全场等待（第 19 章那个 busy-wait 200ms 拖死第二连接的实验还记得吧）。组件给的逃生舱是一对 API：handler 入口处 `httpd_req_async_handler_begin(req, &copy)` ——深拷贝 req/aux/scratch/resp_hdrs，并把原会话标记 `for_async_req=true`（主循环从此跳过该 fd，LRU 也免疫）；耗时工作做完后在自己的任务里应答，最后 `httpd_resp_send + httpd_req_async_handler_complete(r)` 归还——complete 内部会往内部控制口丢一条哑消息唤醒 select 把 fd 收编回监听集合。

实验工程 `/async` 端点的移交成本实测：**handler 平均只花 70µs（max 154µs）就完成了移交并返回**，后续 300ms 的工作由 `async_wk` 任务独立消化，期间其他会话照常服务。代价是三次堆分配（req/aux/resp_hdrs）+ scratch 拷贝，所以在 STM32 量级设备上这个模式更适合"低频重活"而非每个请求。

> [!note] HTTP_SERVER_EVENT 也值得一并接上
> 组件会向默认事件循环派发 `ESP_HTTP_SERVER_EVENT` 的 ON_CONNECTED/DISCONNECTED/ON_HEADER/SENT_DATA… 九种事件。实验工程订阅 ANY_ID 做连接级记账，压测期 conn/disc 计数成为验证会话复用率的硬证据（20.4.3），比抓包便宜得多。

---

## 20.4 性能账目：一次 GET /small 的完整生命周期

沿用 ch19 的口径纪律：**同时段开机、配对测量、guest 侧 µs 计时与主机侧墙钟分离**。下面每个站的成本都有实测归属。

### 1. 逐站账单

| 站点                                         | 代码位置            | 成本（实测口径）                                                                      |
| -------------------------------------------- | ------------------- | ------------------------------------------------------------------------------------- |
| TCP 握手 + accept + 设 3 个 sockopt + 池分配 | `httpd_accept_conn` | noka 模式摊入每请求 conn 均值 ~3~12ms（SLIRP 渡轮主导，见站0）                        |
| 等待首包 + parse（URL/头/校验）              | `httpd_parse_req`   | host 视角不可分，guest 视角计入 handler 计时之前的路上                                |
| handler：render(snprintf)+pad+send           | h_small/h_big       | `/small` avg **376µs** max 5781µs（N=5033）；/big avg **1592µs** max 6321µs（N=1141） |
| resp_send 额外段数                           | `httpd_resp_send`   | 每个附加响应头 = 4 次 send call（field/冒号/value/CRLF 各一次）                       |
| close/TIME_WAIT 退场                         | `httpd_sess_delete` | noka 独有：挥手帧触发 openeth RX 环压力（20.4.2）                                     |
| keep-alive 复用的边际成本                    | ②~④ 重跑            | 会话免重建：150 请求只建 4 条连接（20.4.3）                                           |

站0 的背景数字：裸 TCP 控制通道命令往返在同一路径上量得 1.7ms/8ms 双峰交替——**host↔SLIRP 渡轮本身就有 ~10ms 量化底噪**（QEMU 主循环粒度 + 10ms tick），所以 HTTP 请求 p50 ≈ 9.98ms 主要是传输路径的物理常数，不是组件开销。原始探针实录（与本固件控制通道 `:8025→9999` 同路径，8 次顺序测量）：

```text
probe0: connect=3.50ms cmd_rtt=4.46ms total=7.97ms
probe1: connect=0.10ms cmd_rtt=9.53ms total=9.63ms
probe2: connect=0.05ms cmd_rtt=1.67ms total=1.72ms
probe3: connect=0.04ms cmd_rtt=8.13ms total=8.18ms
probe4: connect=0.05ms cmd_rtt=1.96ms total=2.00ms
probe5: connect=0.12ms cmd_rtt=7.66ms total=7.78ms   ← 双峰：~2ms 与 ~8ms 交替
```

这也解释了为什么下面 QPS 绝对值不高、且按 ch19 经验 ±50% 漂移是常态——**相对对比才有效**。同理，表格里的 QPS 波动区间应理解为宿主机/QEMU 负载噪声，而非组件性能抖动。

### 2. 实验 A：keep-alive 开/关 × 两档响应（配对 3 轮）

方法：固件四个端点，主机 python 压测器 4 worker（各预热 10 请求统一开表），`ka`=单连接顺序请求；`noka`=每请求新建连接并带 `Connection: close`。三轮交错执行于同一 QEMU 实例同一时段。下表数字全部来自逐轮 JSON 存档（`results/a_*.json`），按轮列出：

| 配置                   | 载荷    | QPS（轮1/2/3）        | p50 区间 (ms) | p90 区间 (ms) | 尾延迟特征（逐轮）                                                             |
| ---------------------- | ------- | --------------------- | ------------- | ------------- | ------------------------------------------------------------------------------ |
| KA /small (~140B 报文) | 300×3轮 | 84.5 / 144.2 / 171.4  | 9.97~9.98     | 10.2~10.3     | 两轮 p99≤12ms；一轮被单次丢帧恢复拖出 p99=1422ms、max=1442ms                   |
| NOKA /small            | 300×3轮 | 9.8 / 23.8 / 39.1     | 9.89~9.90     | 10.0~10.2     | 两轮 p99 5857~6000ms；最干净的一轮 p99=11.9ms 但 max 仍 5918ms（<1% 重灾样本） |
| KA /big (10 240B)      | 150×3轮 | 128.3 / 483.4 / 650.5 | 4.4~8.4       | 5.9~9.6       | 三轮 p99 全部 ≤10.4ms；仅一轮 max=1076ms                                       |
| NOKA /big              | 150×3轮 | 24.0 / 53.4 / 117.5   | 5.7~9.8       | 7.0~13.5      | 一轮 p99=5975ms、一轮 p99=1251ms、一轮干净 10.0ms                              |

读表要领：**中位延迟在四种配置下几乎没动**（都贴着 5~10ms 的路径底噪）——差距全部在尾部与吞吐上。每请求新建连接的惩罚不是"加一次握手"那么温柔，而是**周期性把个别请求拖进 6 秒量级的重传深渊，吞吐随之掉 4~17 倍**。原因不在 esp_http_server 而在下层：

```text
W (454274) opencores.emac: emac_opencores_isr_handler: RX frame dropped (0x14)
W (454274) opencores.emac: emac_opencores_isr_handler: RX frame dropped (0x14)
...（noka 洪峰期间连续刷屏 19 帧/200请求；KA 各轮 0 次）
```

noka 每请求多产生 SYN/SYNACK/FIN/ACK 四帧小包，把 ch17 拆过的 openeth RX 描述符环（深度仅 4）打溢出，丢帧引发 TCP 重传恢复——多秒级 RTO 尾巴由此而来（[[2026-08-26-lwip-deep-dive-ch12-tcp-reliability-flow-control|第十二章]] 的 RTO 台阶在此完美复现）。而 heap 全程纹丝不动（free ~250KB，min-ever 无衰减）：**连接 churn 的代价是 CPU/RX 环，不是内存**。

### 3. 连接数增量：keep-alive 复用率的硬证据

用一个 150 请求的固定载荷前后采样事件计数器：

```text
KA   150 请求 → conn/delta = +4     （恰好等于 worker 数，37.5 req/conn）
NOKA 150 请求 → conn/delta = +190   （超出 150 的部分是丢帧后的重连）
```

`Connection: close` 场景里那 40 条超额连接就是 RX 丢帧罚金的直接可视化。

### 4. 结论

- **嵌入式 HTTP 性能的第一杠杆是连接复用**，其次是响应体大小；两者都兑现不了时才轮到优化 handler。
- 掉进性能优化深坑之前，先把「在 SLIRP 底噪 10ms 的环境里量毫秒级差异」这类测量陷阱排除掉——guest 侧 `esp_timer` 微秒计时（376µs vs 墙钟 10ms）就是用来劈开这两层的。
- 不要在 QEMU 上给任何绝对 QPS 下结论；真机以太网 + 同款 esp_http_server 的上限结构与本章一致（RX 环→CPU→序列化），数值另测。

---

## 20.5 实验工程：复现命令

工程位于 `practice/lwip-ch20-http-server/`，基于 ch3 联网模板 bring-up + ch19 的 TCP 控制通道注入模式（`:9999` 免烧写改参）。`main/lab_main.c` 约 430 行；固件内四个端点与控制命令：

| 端点/命令                           | 用途                                                               | 实验归属  |
| ----------------------------------- | ------------------------------------------------------------------ | --------- |
| `GET /small` (~140B 报文)           | 小响应档，user_ctx 挂计数器                                        | 实验 A    |
| `GET /big` (10 240B 静态体)         | 大响应档                                                           | 实验 A    |
| `POST /echo?cap=N`                  | 流式消费 body；cap 超限手工 413                                    | 实验 C1   |
| `GET /async`                        | async_handler_begin 移交给工作任务                                 | 20.3 演示 |
| 控制口 `hello/st/restart <s> <lru>` | 就绪探测 / 计数器+堆快照 / 运行时改 recv_wait_timeout 与 lru_purge | 全部实验  |

主机工具在 `tools/`：`bench.py`（压测器）、`slowloris.py`（慢客户端）、`bigpost.py`（POST 注入）、`ch20ctl.py`（控制通道），用法随各实验小节给出。

```bash
. ~/esp/esp-idf/export.sh
cd practice/lwip-ch20-http-server
idf.py set-target esp32 && idf.py build
cd build && python -m esptool --chip esp32 merge-bin \
  -o qemu_flash.bin --pad-to-size 4MB @flash_args   # monitor 静默失败的兜底
QEMU_BIN=~/.espressif/tools/qemu-xtensa/esp_develop_9.2.2_20250817/qemu/bin/qemu-system-xtensa
timeout 900 $QEMU_BIN -M esp32 -m 4M \
  -drive file=build/qemu_flash.bin,if=mtd,format=raw \
  -drive file=build/qemu_efuse.bin,if=none,format=raw,id=efuse \
  -global driver=timer.esp32.timg,property=wdt_disable,value=true \
  -nic user,model=open_eth,hostfwd=tcp::8024-:80,hostfwd=tcp::8025-:9999 \
  -nographic -no-reboot 2>&1 | tee run.log
# 8024/8025 选号依据 CONVENTIONS 第六章端口占用表（8020/8022/8023/8050 已占用）

python3 tools/ch20ctl.py hello                    # $$$ ch20 ready
curl http://127.0.0.1:8024/small                  # 冒烟
python3 tools/bench.py --mode ka --path /small --count 300 --workers 4
```

启动横幅（run.log 实录，默认口径一目了然）：

```text
$$$ CTRLREADY port=9999
W (2814) ch20lab: httpd START port=80 recv_to=5s send_to=5s lru=0 max_sockets=7 backlog=5 stack=4096 prio=5 ctrl_port=32768
$$$ HTTPREADY port=80 ctrl=9999
```

---

## 20.6 故障注入·Slowloris：半个请求头拖死七格会话池

### 1. 攻击面在哪

回顾 20.2.4 流水线的第二步：parser 在头部读完前的状态（PARSING_HDR_FIELD/VALUE）可以无限期停在两次 `recv` 之间，唯一的缰绳是 1024B 的 header 预算与每步 5s 的 SO_RCVTIMEO。经典 Slowloris 正好踩在这个缝上：**发一半请求头，然后每隔 <5s 滴一个字节续命**。每条这样的连接钉住一格 `max_open_sockets=7` 的会话槽，而池满后（lru_purge=false）listen_fd 退出 select 集合——新连接进不来也无超时。

### 2. B1：静默挂起者的回收节奏（默认 5s）

7 条连接各发半个请求头后完全沉默。服务端日志逐帧记录了回收全过程：

```text
W (638784) httpd_txrx: httpd_sock_err: error in recv : 11      ← EAGAIN：SO_RCVTIMEO 打响
W (638784) httpd_txrx: httpd_resp_send_err: 408 Request Timeout - Server closed this connection
W (643784) httpd_txrx: httpd_sock_err: error in recv : 11
W (643784) httpd_txrx: httpd_resp_send_err: 408 Request Timeout - Server closed this connection
W (648784) ...（间隔精确等于 5000ms，共 6 条可见 + 第 7 条紧随其后）
```

两个发现比预期更有教学价值：

1. **回收是串行慢动作**：单线程服务器一次只能陪一个死会话睡满 5 秒，7 格池彻底清空要 ~35 秒——攻击者只要以 ≥1/5s 的速率补充新慢连接，就永远压得住。
2. errno 11（EAGAIN）映射 TIMEOUT→408 这条判定链全在 `httpd_sock_err()+read_block()` 里，没看到它你永远不会知道"408 是这么来的"。

### 3. B2：滴流续命 + 运行时降超时防线

攻击升级为每 3s 滴 6B（<5s，续命成功）：7 条连接稳定占据 28 秒以上。攻击脚本的完整时间线（摘自 `results/b_slowloris_hold.txt`）：

```text
[  0.00s] held conn #0 ... #6            （7 条全部到手）
--- phase2: dripping 6B every 3.0s for 40.0s ---
[  1.00s] conn #0 EVICTED / #5 EVICTED    （两条撞在上一轮超时扫描上）
[ 28.07s] drip 6B -> alive=5              ← 27 秒里滴流持续续命成功
[ 29.07s] conn #1~#4、#6 全部 EVICTED      ← restart 下发瞬间清场
```

期间合法请求被拒之门外：

```text
$ curl -m 8 http://127.0.0.1:8024/small
HTTP 000 t=8.002158s     rc=28 （TIMEOUT）
```

注意 curl 的 connect 其实成功了（lwIP 的 listen backlog 完成了握手排队），卡死在"无人 accept 也无响应"——这就是池满 + `lru_purge=false` 时 select 摘除 listen_fd 的外在形状：**TCP 层礼貌接收，应用层无限白等**。若连接数再超过 backlog_conn(5)，SYN 将被静默丢弃呈现为 connect 层的 RST/拒绝——两种形态取决于攻击强度。

防线验证用控制通道运行时重启服务（免烧写）：`restart 2 0` → `recv_wait_timeout` 降到 2s。滴流间隔 3s > 2s，续命失效——

```text
[ 29.07s] conn #1 EVICTED ... #2 #3 #4 #6 全部 EVICTED（attack 脚本视角瞬间清场）
W (738204) ch20lab: httpd START port=80 recv_to=2s send_to=2s lru=0 max_sockets=7 backlog=5 ...
probe1: HTTP 200 t=0.005982s            ← 6 秒内恢复满血
probe2/3: HTTP 200 t≈0.01s
```

防线效果表：

| 口径                         | 默认 recv_wait_timeout=5s | 收紧到 2s                         |
| ---------------------------- | ------------------------- | --------------------------------- |
| 单格会话最长驻留（滴流攻击） | ∞（3s 滴流即可续命）      | 攻击节奏被迫 <2s（发送放大 2.5×） |
| 静默挂起者全场清空           | 7×5=35s 串行              | 7×2=14s（同机制加速）             |
| 重启后服务恢复               | —                         | ≤6s 探针全绿                      |

工程含义：**Slowloris 无法在框架内根治（header 总有解析态），但 `recv_wait_timeout` 越小、攻击者维持成本越高**；再叠加 `max_req_hdr_len`(1024B) 的 431 出口、应用层认证失败立刻 `httpd_sess_trigger_close()`，就是把攻击压缩到经济学不合算的水平。生产部署还可开 `lru_purge_enable=true` 让真实用户挤掉慢攻击者——代价是被误伤风险，需自行权衡。

---

## 20.7 故障注入·大 POST：三条路径，三个真相

### C1 Content-Length 骗大：没有上限，只有不活动超时

宣称 100MB 却一字不发：

```text
$ python3 tools/bigpost.py cl-lie --uri /echo --claim 104857600 --rate 0
headers sent (POST /echo Content-Length: 104857600, real rate 0B/s)
server says: b'HTTP/1.1 408 Request Timeout\r\n...\r\n\r\nSer'
FIN from server (session closed)

W (832444) httpd_txrx: httpd_sock_err: error in recv : 11
W (832444) httpd_txrx: httpd_resp_send_err: 408 Request Timeout - Server closed this connection
```

真相一：**`104857600` 这个 Content-Length 被照单全收**——组件没有 CL 上限配置，头文件里躺着的 `HTTPD_413_CONTENT_TOO_LARGE` 错误码在整个 src/ 里找不到任何触发者（grep 证实，仅存于错误码表与文档字符串）。防御只剩两个防线：解析阶段的 5s 不活动超时（上文，谎报者在收到第一个 body 字节前就被收割）；以及进了 handler 后的流式消费循环，对端停滞时同样以 EAGAIN 出口退出（实验代码里的 `POST abort at %u/%u` 日志）。应用层上限要自己写——实验工程演示了写法：`?cap=N` 超限即手工 `httpd_resp_send_err(req, HTTPD_413_CONTENT_TOO_LARGE, ...)`（实测 200 响应体换 413 文案 + 会话关闭）。

真相二：由于 CL 只是声明、内存从不按声明分配（20.2.5 的流式设计），骗大 CL 只能造成**时间型 DoS**（占会话直到超时），不能造成堆耗尽。这与 [[2026-08-26-lwip-deep-dive-ch5-memory-management|第五章]] 的全堆化事实组合出的安全性质值得单独记一笔。

### C2 chunked 上传：解析器的断裂带

每秒 3 块小 chunk 持续上传，实际发生的事：

```text
W (845314) ch20lab: POST done len=0 elapsed_us=415          ← handler 拿到 content_len=0！
W (845644) httpd_parse: parse_block: incomplete (1/18) with parser error = 16
W (845644) httpd_txrx: httpd_resp_send_err: 400 Bad Request - Bad request syntax

客户端视角同刻收到两段拼接响应：
'HTTP/1.1 200 OK..consumed 0 bytes' + 'HTTP/1.1 400 Bad Re...' → Broken pipe
```

真相三：这一版 esp*http_server **对 chunked 请求体没有真正的分块读取支持**——`parse_init()` 的 settings 没有注册 on_chunk*\* 回调，headers_complete 时 `content_length==-1` 被 `cb_headers_complete` 归零为 `remaining_len=0`，于是 handler 挂着"空 body"提前开工；后续到达的 chunk 数据躺在 pending/push-back 区，下一轮 select 被当成**新请求的起始字节**去解析，自然炸出 400 并关连接。结论直接可用：面向嵌入式服务端的客户端请坚持 Content-Length 模式，chunked 请求留给下载方向（响应侧的 `httpd_resp_send_chunk` 是完善支持的）。

### C3 负结果：POST 打 GET-only URI 不是攻击向量

原假设：请求带未消费的大 body 打到不匹配的 URI，会触发 `httpd_req_delete()` 的 32B purge 循环长时间占住会话。实测推翻——首个滴流字节一到，dispatch 立即短路：

```text
W (32572) httpd_uri: Method '3' not allowed for URI '/small'
W (32572) httpd_txrx: httpd_resp_send_err: 405 Method Not Allowed - Specified method is invalid for this resource
客户端 @2.00s 即收 FIN：
'HTTP/1.1 405 Method Not Allowed..45\r\n\r\n'
```

对照源码路径：`httpd_uri()` 对 405 走 `httpd_req_handle_err()` 后返回 FAIL，上层直接判会话失败关闭——purge 循环根本没机会执行。**资源驻留只会发生在两处：parser 的中间态（20.6）与 handler 自愿的流式消费（C1 中段）**。方法论备注：这个负结果的价值在于精确划定了攻击面，把后续渗透测试清单里"URI/method 错配驻留"这一项直接划掉。

---

## 20.8 Vanilla lwIP 与 ESP-IDF lwIP：两种 httpd 哲学

lwIP 上游其实自带一个 HTTP 服务器（`components/lwip/lwip/src/apps/http/httpd.c`，~2770 行，IDF 仓库里就有），但它与 esp_http_server 是两种截然不同的哲学——IDF 默认压根不启用原生 httpd 应用，另造了一个 socket API 组件：

| 维度             | Vanilla lwIP httpd                                                                            | esp_http_server                                                    |
| ---------------- | --------------------------------------------------------------------------------------------- | ------------------------------------------------------------------ |
| 编程接口         | raw/altcp API 回调，跑在 **tcpip_thread 上下文**                                              | socket API + 自有 FreeRTOS 任务 select                             |
| 文件系统         | ROM 化 fsdata（makefsdata 转 C 数组）+ SSI 变量替换                                           | 无 FS 概念，纯 handler 编程模型                                    |
| 动态内容         | CGI 钩子（`LWIP_HTTPD_CGI`，默认 0）                                                          | 第一公民（handler/user_ctx/逐请求流式 body）                       |
| POST 支持        | `LWIP_HTTPD_SUPPORT_POST`，默认 0                                                             | 完整（流式 recv + purge）                                          |
| WebSocket        | 无                                                                                            | `HTTPD_WS_SUPPORT` 编译开关（默认 0）                              |
| 空闲连接回收     | `altcp_poll` 计数：`HTTPD_POLL_INTERVAL`=4 个 500ms 粗 tick × `HTTPD_MAX_RETRIES`=4 → **~8s** | SO_RCVTIMEO 逐步超时（默认 5s）→ 408                               |
| 内存告急策略     | `LWIP_HTTPD_KILL_OLD_ON_CONNECTIONS_EXCEEDED`（默认 0）：链表遍历 **RST 杀最老**              | `lru_purge_enable`（默认 false）：可选踢最久未用，走工作队列优雅关 |
| 解析器           | 手写状态机（httpd.c 内嵌 + `httpd_structs.h`）                                                | nodejs http_parser（node 10 同源）回调装配                         |
| 与 lwIP 内核关系 | 零拷贝上游（pbuf 直读）                                                                       | 经过 netconn/socket 双层搬运（ch16 的两层税都交了）                |

两条系列暗线在此交汇：IDF 对 vanilla httpd 的答案是"不用也不裁剪"（`LWIP_MQTT=0` 式的死码待遇，见 ch21 的 MQTT 对照），转而用 socket API 写一个与 TLS 组件可插拔（send_fn/recv_fn 替换）、与 IDF 事件总线/工作队列生态兼容的应用层服务器。代价是把每次读写推进 tcpip 邮箱一层（每 syscall ~37µs 账单，ch13 实测过），收益是语义清晰、可在任务内自由阻塞与调度。**在 RTOS 上做网络服务，「贴内核」还是「借抽象」，这个分叉在本章给出了第三次实例。**

---

## 20.9 小结

- 并发模型：MCU 上 thread-per-connection 因栈预算与同步成本出局；esp_http_server 是标准的事件驱动单任务模型——一个 `httpd` 任务跑 `select`，控制消息（UDP 自环信箱 ：32768）、会话、accept 同集串行处理，天然免锁；代价是任一会话的处理停顿全场买单。
- 会话池是 `max_open_sockets`（默认 7=`CONFIG_LWIP_MAX_SOCKETS`−3）个 sock_db 槽位 + 全局 LRU 计数器（无时钟源，单调 ++）；池满行为由 `lru_purge_enable` 定性：默认**摘除 listen_fd** 让新连接饿死，开启则踢最旧腾位。服务完一个请求 LRU 时间戳才刷新，异步占用的槽位免死。
- 分发链五段式：parse（128B 步进喂 nodejs http_parser，头区最大 1024B）→ dispatch（8 格 URI 表，method 不符短路 405，不触发 purge）→ handler（user_ctx 注册注入/sess_ctx 会话级）→ resp（status malloc + 逐字段 send，从不攒大块）→ cleanup（32B purge 未消费 body）。全组件四块小缓冲，从不缓存整包——CL 谎报打不出内存事故，只能打出时间事故。
- 「keep-alive」三义辨析：HTTP 持久连接**隐式常开无开关**；`keep_alive_*` 配置管的是 TCP SO_KEEPALIVE 探测；**会话寿命裁判其实是 recv_wait_timeout（默认 5s）**，EAGAIN→408→close 就是回收路径的全部实现。
- 实验 A 数字（同窗配对）：KA/NOKA 在 300×4w 下 QPS 84~171 vs 9.8~39.1；p50 都约 10ms（host↔SLIRP 渡轮底噪，裸 TCP 对照 1.7/8ms 双峰佐证）；NOKA 尾延迟被 RX 环丢帧重传抬到 p99 5.9~6.0s，因果链 = 每 +150 请求多 186 条连接 → openeth RX 环（深 4）溢出丢帧 → RTO 尾巴；heap 全程平稳。keep-alive 复用率硬指标：150 请求 Δconn=+4 vs +190。handler 侧成本（guest µs）：/small 376、/big 1592、async 移交 70。
- 实验 B（Slowloris）：半个头+3s 滴流拖死 7 格池，合法请求 connect 成功但 8s 无响应（backlog 握手 + 池满摘 listen_fd 的复合症状）；静默挂起者以精确 5000ms/格串行回收（EAGAIN→408 日志全留痕）；`restart 2 0` 运行时收紧 recv_wait_timeout 后 ≤6s 清场恢复。防线组合拳：小 recv_timeout + lru_purge + 1024B header 预算 + 应用层主动 trigger_close。
- 实验 C（大 POST）：CL 100MB 照单收，唯二防线是 5s 不活动超时与应用层 cap（HTTPD_413 存在但无自动触发者，须手工调用）；chunked 请求体无真正支持——handler 见 content_len=0，残渣被判成新请求 400（坚持 CL 模式）；POST→GET-only 是 405 毫秒级短路的负结果，purge 不背锅。
- Vanilla 对照：lwIP 原生 httpd（raw API、ROM fs、手写解析器、8s poll 回收、RST-杀最老） vs esp_http_server（socket+自有任务、handler/ctx 模型、http_parser、SO_RCVTIMEO 回收、TLS 插拔）——IDF 的选择代表"借抽象换生态"路线，性能税与灵活性共存。

下一章继续啃应用层协议栈：ESP-IDF 官方推荐的 MQTT 客户端 `esp-mqtt`（components/mqtt）——outbox 离线积压的真实单价、broker 判死的 [1.5×,2×] keepalive 公式、clientId 冲突风暴都会带上 QEMU 实测数字；顺带看清上游 lwIP 自己那份 `src/apps/mqtt` 为何在 IDF 里沦为死码。见 [[2026-08-26-lwip-deep-dive-ch21-mqtt|第二十一章：MQTT：esp-mqtt 与 publish/subcribe 的内存剖面]]。
