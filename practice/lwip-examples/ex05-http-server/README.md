# ex05 http-server —— esp_http_server 服务模板

QEMU openeth 网络上的最小 HTTP 服务模板：`esp_http_server` 起三个路由（`/hello`
纯文本、`/info` JSON 状态、未注册 URI 默认 404），复制改名即可作为新项目起点。
keep-alive 行为与死链路回收机制见 [下文专节](#keep-alive-行为与死链路回收)，
配套串行小压测脚本在 `tools/bench.py`。

## 目的与路由

| 路由         | 方法 | Content-Type     | 内容                                                    |
| ------------ | ---- | ---------------- | ------------------------------------------------------- |
| `/hello`     | GET  | text/plain       | 一行问候文本                                            |
| `/info`      | GET  | application/json | IP、uptime、heap free、error 计数、端点命中计数         |
| 其他任意 URI | ANY  | text/html        | esp_http_server 默认 404 页（无需注册任何兜底 handler） |

## 网络拓扑

```text
   宿主机                                QEMU SLIRP                     guest (ESP32, openeth)
┌───────────────────────┐          ┌──────────────────────┐          ┌──────────────────────┐
│ curl / tools/bench.py │ ─TCP───► │ hostfwd tcp::8240-:80│ ───────► │ 10.0.2.15:80         │
│ 127.0.0.1:8240        │          │ (用户态转发)          │          │ esp_http_server      │
└───────────────────────┘          └──────────────────────┘          └──────────────────────┘
                                        DHCP: guest 得 10.0.2.15/24, gw 10.0.2.2
```

端口按套件号段表分配：ex05 号段 **8240**，hostfwd 两端异号映射宿主 8240 → guest 80
（HTTP 标准口留在 guest 侧，与 curl URL 的"裸 :8240"形态对齐）。

## 构建

```bash
. ~/esp/esp-idf/export.sh
cd practice/lwip-examples/ex05-http-server
idf.py set-target esp32        # 仅首次
idf.py build
```

## 运行

```bash
# 生成 QEMU 镜像（monitor 因无 TTY 失败可忽略，镜像已生成）
idf.py qemu monitor < /dev/null || true
ls build/qemu_flash.bin build/qemu_efuse.bin   # 必须存在
# 若重复构建后镜像未更新（Batch 6 已知坑），手动合并兜底：
# cd build && python -m esptool --chip esp32 merge-bin -o qemu_flash.bin --pad-to-size 4MB @flash_args

tools/run_qemu.sh 300          # 前台跑 300s；到点 timeout 截停（退出码 124 属正常结束）
```

`tools/run_qemu.sh` 使用**去 efuse `-global` 行**的启动形态（该行在本机 QEMU 偶发导致
openeth NIC 未创建，CONVENTIONS Batch 4），并自动 `tee run.log`。固件就绪标志是机器可读行：

```text
$$$ READY role=httpd port=80 max_sockets=7 backlog=5 recv_to=5s send_to=5s lru_purge=0 fw=Aug 27 2026 12:42:04
```

对照实验请核对 `fw=` 时间戳确信跑的是新镜像。想后台跑就 `tools/run_qemu.sh 300 &`，
结束时按 `pgrep -f "qemu-system-xtensa.*8240"` 找 PID 精确 kill（禁止 pkill）。

## 验证：三个路由的 curl 输出（真实摘录）

```console
$ curl -s -i http://127.0.0.1:8240/hello
HTTP/1.1 200 OK
Content-Type: text/plain
Content-Length: 62

hello from ex05-http-server (esp_http_server on QEMU openeth)

$ curl -s http://127.0.0.1:8240/info
{"ip":"10.0.2.15","uptime_s":31,"heap_free":266452,"errors":0,"hits_hello":1,"hits_info":1}
$ curl -s http://127.0.0.1:8240/info        # 再来一次：计数递增可观测
{"ip":"10.0.2.15","uptime_s":31,"heap_free":266452,"errors":0,"hits_hello":1,"hits_info":2}

$ curl -s -i http://127.0.0.1:8240/no-such-uri   # 未注册 URI -> 默认 404
HTTP/1.1 404 Not Found
Content-Type: text/html
Content-Length: 29

Nothing matches the given URI
```

guest 侧 `run.log` 对应证据行：

```text
I (32883) ex05: GET /info -> 200 (hits=1)
W (32933) httpd_uri: httpd_uri: URI '/no-such-uri' not found
W (32933) httpd_txrx: httpd_resp_send_err: 404 Not Found - Nothing matches the given URI
W (32933) ex05: HTTP_SERVER_EVENT_ERROR #1
```

`errors` 字段的口径：`ESP_HTTP_SERVER_EVENT_ERROR` 组件级错误事件的累计次数
（404 应答也计一次 error 事件，这是组件的设计而非 bug）。

## keep-alive 行为与死链路回收

esp_http_server 的 HTTP 层 keep-alive 是天然行为：响应发出后会话不关，
回到 select() 继续等同一条连接上的下一个请求——HTTP/1.1 客户端不发特殊头即可复用。
真正决定一个挂死会话什么时候被回收的是 `recv_wait_timeout`
（`httpd_config_t` 默认 5 秒）：

- 等待下一个请求报文的任何时刻，socket 收零/超时的时间预算是
  SO_RCVTIMEO = `recv_wait_timeout`；
- 超时触发 `httpd_sock_err: error in recv : 11`，服务端回
  `408 Request Timeout` 并关闭会话——**它才是空闲会话的回收裁判**；
- 配置项里名字带 keep_alive 的 `keep_alive_enable/idle/interval/count`
  是 TCP 层 **SO_KEEPALIVE** 探测，管的是"对端主机死了"这类半开连接，
  与 HTTP 持久连接无关，不要混淆。

实测验证（保持半个请求头静默，模拟挂死的 keep-alive 会话）：

```console
$ python3  # connect 后只发 "GET /hello HTTP/1.1\r\nHost: ex05\r\n"，随后沉默等读
[5.01s after connect] received 106 bytes:
HTTP/1.1 408 Request Timeout
Content-Type: text/html
Content-Length: 29

Server closed this connection
```

正好 5 秒（= recv_wait_timeout）后 408 到达、会话关闭；guest 侧签名与源码结论一致：

```text
W (55373) httpd_txrx: httpd_sock_err: error in recv : 11
W (55373) httpd_txrx: httpd_resp_send_err: 408 Request Timeout - Server closed this connection
W (55373) ex05: HTTP_SERVER_EVENT_ERROR #2
```

### 并发上限与池满行为（ch20 源码事实）

- 会话池固定 `max_open_sockets=7` 格（READY 行打印）；默认
  `lru_purge_enable=false` 时池满**不再摘除 listen_fd 迎新**，新连接被直接拒绝；
  把 LRU 打开后才会挤掉最旧会话腾位；
- 会话回收是串行化的：若 7 个会话同时挂死，最坏要
  `7 × recv_wait_timeout = 35s` 才全部清空——慢客户端（Slowloris 类）攻击面就在这里，
  缩短 recv_wait_timeout 或开 lru_purge 是第一道防线；
- 没有 Content-Length 上限配置项：错误码 `HTTPD_413_CONTENT_TOO_LARGE` 存在于
  错误码表但全源码无自动触发者，请求体大小限制必须应用层自己实现（先查
  `req->content_len` 再决定是否 `httpd_req_recv`）；
- chunked 编码的请求体不支持（解析器只认定长 body），响应用 chunked 出去可以，
  进来的必须带 Content-Length。

## 小压测：keep-alive vs 非 keep-alive（真实数字）

```bash
python3 tools/bench.py            # 127.0.0.1:8240 /hello，各 50 请求串行
```

方法学：单线程串行逐个请求；ka 组一条连接复用到底，noka 组每请求新建连接 +
`Connection: close`；每组前 5 次预热把 ARP 首包税/SLIRP 冷路径抖出测量窗；
两组同一次开机内连续配对测量（QEMU 数字受宿主负载影响 ±50%，隔时段不可比）。
测于本机 QEMU（esp_develop_9.2.2_20250817）单轮：

| 组   | 请求数 | 成功 | 平均延迟  | p50     | p90      | max      |
| ---- | ------ | ---- | --------- | ------- | -------- | -------- |
| ka   | 50     | 50   | 9.594 ms  | 9.967ms | 10.156ms | 10.396ms |
| noka | 50     | 50   | 10.102 ms | 9.905ms | 10.260ms | 17.906ms |

差值 **+0.508 ms/请求**（noka − ka）。复跑一轮得 ka 9.597 / noka 9.897
（差 +0.3ms），结论稳定：串行负载下每请求省掉三次握手约 0.3~0.5ms，
占平均延迟仅 3~5%——因为本环境的延迟地板（~10ms）由 SLIRP 用户态转发 +
openeth RX 描述符环路径主导，握手占比小。并发越高、对象越小，keep-alive
的相对收益越大；且 noka 高频建连会让会话槽位反复进出，接近
max_open_sockets 上限时风险敞口也更大。

机器可读输出（JSON 行）：

```json
{"mode": "ka", "path": "/hello", "sent": 50, "ok": 50, "fail": 0, "avg_ms": 9.594, "p50_ms": 9.967, "p90_ms": 10.156, "max_ms": 10.396}
{"mode": "noka", "path": "/hello", "sent": 50, "ok": 50, "fail": 0, "avg_ms": 10.102, "p50_ms": 9.905, "p90_ms": 10.26, "max_ms": 17.906}
```

压测结束后 `/info` 自证账目吻合：
`{"ip":"10.0.2.15","uptime_s":122,"heap_free":266260,"errors":2,"hits_hello":221,...}`
（221 = 初始 curl 1 次 + 两组压测各 5 预热 + 50 正式 × 2 轮）。heap 全程稳在
~266 KB 无泄漏迹象。

## 已知边界与排障

- 启动时固定刷 3 条 MAC filter ioctl 错误
  （`add mac address to filter not supported` / `Failed to add multicast filter`）
  属 openeth 白名单噪音，不是故障；虚拟网卡 MAC 固定 `52:54:00:12:34:56`。
- 主机 → guest 只有 hostfwd 一条路，且 ICMP 不通——连通性检查一律用 curl/TCP 探针，
  别 ping 10.0.2.15。
- 单条请求头总数受 `CONFIG_HTTPD_MAX_REQ_HDR_LEN`（默认 512B）、URI 受
  `CONFIG_HTTPD_MAX_URI_LEN`（512B）约束，超限得 `431 Req HDR Fields Too Large`。
- QEMU 启动即报 `could not set up host forwarding` = 宿主 8240 被别的进程占了，
  先查占用再起；并行多示例时遵守套件号段表。
- 本模板默认口径刻意不改（recv_wait_timeout=5s、lru_purge=false），README 各处
  行为描述都以此为前提；调参实验请参照 ch20 章节《lwIP 深度解析（二十）》。
- 改 `sdkconfig.defaults` 后必须删 `sdkconfig` 重新生成才生效。

## 文件清单

| 文件                | 说明                                                |
| ------------------- | --------------------------------------------------- |
| `main/main.c`       | openeth bring-up 标准骨架 + 两个 handler + READY 行 |
| `tools/run_qemu.sh` | QEMU 启动器（去 efuse 行，tee run.log）             |
| `tools/bench.py`    | 串行 ka/noka 双组小压测                             |
| `run.log`           | 真实运行留存（本次验证全程）                        |

> 参考实现：`~/esp/esp-idf/examples/protocols/http_server/simple`（官方示例依赖
> protocol_examples_common 连接层，本模板用自带 openeth 骨架替换之，无在线拉取依赖）。
