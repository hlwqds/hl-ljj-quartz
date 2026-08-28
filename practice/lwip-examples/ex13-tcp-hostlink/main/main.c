/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * lwIP 示例套件 ex13：tcp-hostlink —— QEMU 与宿主双向 TCP 交互模板
 *
 * 一个固件内同时演示两个发起方向的 TCP 应用，证伪"SLIRP 下只能单向"的误解：
 *
 *   入向命令面（hostfwd）：宿主 --tcp:8300--> [SLIRP hostfwd] --> guest 10.0.2.15:8300
 *     一行式命令协议（逐连接串行、先收后回，ch23/ch15 纪律）：
 *       PING          -> PONG
 *       ECHO <data>   -> <data> 原样返回
 *       STATS         -> lwip_stats(TCP 段)+heap+uptime 单行 JSON
 *       TIME          -> up_ms=...
 *       其他          -> ERR unknown
 *
 *   出向心跳面（guest 发起）：guest -> 10.0.2.2:8301 --SLIRP--> 宿主机 loopback:8301
 *     默认每 5s 一条独立 TCP 会话，上报一行 JSON 心跳（ip/uptime/heap/已服务连接数），
 *     收到宿主 "ACK" 即断开。宿主无监听时 connect 硬失败，只计数告警，绝不拖垮服务面。
 *
 * 两个方向跑在各自独立的 FreeRTOS 任务里，共享的只有几个字宽计数器——入向长会话
 * 卡住也挡不住心跳节拍，反之亦然；run.log 里"同一时间窗内既有 HB ACKED 行又有
 * EX13REPLY 行"就是并发不互阻塞的时间线证据。
 *
 * 从系列实验沉淀的纪律，全部固化在代码结构里：
 *
 * [ch23 结论 a] 单任务串行 accept 必须数据驱动推进（先 recv 后回写），对端
 *   FIN/RST 立即 close 回收；本模板再叠加 SO_RCVTIMEO 兜底，客户端连上不发话
 *   也会在空闲超时后放行下一条连接，串行 accept 循环不会死等。
 *
 * [ch23 结论 b] listen() 的 backlog 显式设足（超限 SYN 被 lwIP 静默吞掉，
 *   客户端五发空转后报 errno=113）。
 *
 * [ch16 错误账本] 每个失败分支打印 rc/errno/符号名与耗时。注意 lwIP err.c
 *   映射表没有 ECONNREFUSED 条目，SLIRP 对无监听端口代答 RST，guest 侧实测
 *   表现为 errno=104(ECONNRESET)——heartbeat 掉线分支据此如实打印。
 *
 * [tcpip_callback 异步语义] tcpip_callback() 只是把消息投进 tcpip 邮箱就返回
 *   （components/lwip/lwip/src/api/tcpip.c，IDF v6.0.2），并不等回调执行完。
 *   所以 STATS 快照用 "回调内 give 信号量 + 调用方带超时 take" 保同步取齐，
 *   这是跨线程读 lwip_stats 的正确姿势（勿学"投完就读"的竞态写法）。
 *
 * 运行环境：ESP-IDF v6.0.2 + qemu-system-xtensa (Espressif fork)
 *           -nic user,model=open_eth,hostfwd=tcp::8300-:8300
 * 宿主端配合工具：tools/hostlink.py（命令客户端）、tools/reverse_heartbeat.py
 * （8301 心跳接收器）。
 */

#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <strings.h> /* strncasecmp */

#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"

#include "esp_eth.h"
#include "esp_event.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_timer.h"

#include "lwip/inet.h" /* htons / PP_HTONL / LWIP_MAKEU32 */
#include "lwip/sockets.h"
#if LWIP_STATS
#include "lwip/stats.h" /* lwip_stats.tcp（需 CONFIG_LWIP_STATS=y） */
#include "lwip/tcpip.h" /* tcpip_callback() */
#endif

#define TAG "ex13"

/* ------------------------------ 服务参数 ------------------------------ */

#define CMD_PORT        8300 /* SPEC §4 端口表 ex13 号段 8300/8301；hostfwd 两端同号 */
#define HB_PORT         8301 /* 出向心跳槽：guest 连 10.0.2.2:8301 = 宿主 loopback:8301 */
#define LISTEN_BACKLOG  8    /* ch23 结论 b：显式设足。< CONFIG_LWIP_MAX_ACTIVE_TCP(16) */
#define CMD_LINE_MAX    256  /* 单条命令行的上限（不含行尾 '\n'），超出即截断保护 */
#define RX_CHUNK        512  /* 单次 recv 缓冲，几条小命令可合并到达一次拿到 */
#define RCVTIMEO_S      30   /* accepted socket 的空闲兜底超时：串行 accept 不被哑客户端拖死 */
#define DHCP_TIMEOUT_MS 15000

/* 函数式宏的实参在展开前不分词，IP 四段必须逐个传入（C-10 纪律） */
#define HOST_IP_OCTET1 10 /* SLIRP：guest 发往 10.0.2.2 的 TCP 落宿主机 loopback 同端口 */
#define HOST_IP_OCTET2 0
#define HOST_IP_OCTET3 2
#define HOST_IP_OCTET4 2

#define HB_PERIOD_MS      5000 /* 心跳节拍（SPEC §5：默认 5s；首拍 = 任务创建后 +5s） */
#define HB_ACK_TIMEOUT_S  3    /* 等 ACK 的 SO_RCVTIMEO：接通了但不回话也算掉线  */

/* ------------------------------ 运行计数 ------------------------------ */
/* 只由各自任务写、观测面读；字宽读写原子，模板级统计无需加锁 */

static volatile unsigned s_conn_total;    /* 累计 accept 成功的入向连接数        */
static volatile unsigned s_conn_active;   /* 正在服务的入向连接数（串行模型 ≤1） */
static volatile unsigned s_replies_total; /* 累计应答的命令行数                  */
static volatile uint64_t s_bytes_in;      /* 累计入向字节数                      */
static volatile unsigned s_hb_ok;         /* 心跳 ACK 成功次数                   */
static volatile unsigned s_hb_fail;       /* 心跳失败次数                        */

static SemaphoreHandle_t s_got_ip;
static esp_ip4_addr_t s_ip;

/* ------------------------- errno 符号名速查 --------------------------
 * newlib 值域（非 Linux 值域）：EAGAIN=11、ECONNRESET=104、ENOTCONN=128、
 * ECONNABORTED=113——最后这个和 Linux 差异最大，详见 README 对照表。 */
static const char *err_name(int e)
{
    switch (e) {
    case EINTR:
        return "EINTR";
    case EAGAIN:
        return "EAGAIN/EWOULDBLOCK";
    case EPIPE:
        return "EPIPE";
    case ECONNRESET:
        return "ECONNRESET";
    case ECONNABORTED:
        return "ECONNABORTED";
    case ETIMEDOUT:
        return "ETIMEDOUT";
    case ENOTCONN:
        return "ENOTCONN";
    default:
        return "?";
    }
}

/* 回写必须凑齐：短写（SOCK_SNDBUF 满时 send 只收下一部分）对单行协议是丢帧 */
static int send_all(int sock, const char *buf, size_t len)
{
    size_t off = 0;
    while (off < len) {
        int n = send(sock, buf + off, len - off, 0);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            ESP_LOGE(TAG, "send failed errno=%d(%s)", errno, err_name(errno));
            return -1;
        }
        off += (size_t)n;
    }
    return 0;
}

/* --------------------- STATS 数据源：lwip_stats 快照 -------------------
 * lwip_stats 属于 tcpip_thread 的共享结构，禁止跨线程裸读；tcpip_callback()
 * 是异步投递（不等回调执行完），所以配信号量确认回调真正跑完再取数。 */

#if LWIP_STATS

struct stats_snap {
    u32_t tcp_rx;     /* tcp.recv  收包数        */
    u32_t tcp_tx;     /* tcp.xmit  发包数        */
    u32_t tcp_drop;   /* tcp.drop  主动丢弃      */
    u32_t tcp_memerr; /* tcp.memerr 内存不足计数 */
};

static SemaphoreHandle_t s_snap_done;

/* 跑在 tcpip_thread 内：只做拷贝 + give，绝不阻塞 */
static void stats_copy_cb(void *ctx)
{
    struct stats_snap *snap = (struct stats_snap *)ctx;
    snap->tcp_rx     = lwip_stats.tcp.recv;
    snap->tcp_tx     = lwip_stats.tcp.xmit;
    snap->tcp_drop   = lwip_stats.tcp.drop;
    snap->tcp_memerr = lwip_stats.tcp.memerr;
    xSemaphoreGive(s_snap_done); /* 在 tcpip_thread 里 give FreeRTOS 信号量是安全的 */
}

static bool stats_snapshot(struct stats_snap *out)
{
    memset(out, 0, sizeof(*out));
    xSemaphoreTake(s_snap_done, 0); /* 清掉可能残留的旧令牌 */
    if (tcpip_callback(stats_copy_cb, out) != ERR_OK) {
        return false; /* 邮箱满等极端情形：本拍放弃，不阻塞服务循环 */
    }
    /* 等回调真执行完；100ms 拿不到视为异常，宁可少一拍也不卡死命令面 */
    return xSemaphoreTake(s_snap_done, pdMS_TO_TICKS(100)) == pdTRUE;
}

#endif /* LWIP_STATS */

/* heap 三件套：heap_caps 层 API，任意任务直接读安全（口径见 README）*/
static unsigned heap_free(void)
{
    return (unsigned)heap_caps_get_free_size(MALLOC_CAP_8BIT);
}
static unsigned heap_largest(void)
{
    return (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_8BIT);
}
static unsigned heap_min_ever(void)
{
    return (unsigned)heap_caps_get_minimum_free_size(MALLOC_CAP_8BIT);
}

static int64_t now_us(void)
{
    return esp_timer_get_time(); /* 亚毫秒计时用 esp_timer，不用 sys_now（10ms 网格）*/
}

/* ------------------------- 命令处理（逐行） ------------------------- */

/*
 * 处理一条完整命令行并回一行响应。返回回写字节数（<0 表示回写失败）。
 * 除快照/回写外不做任何耗时动作——这是 ch15 教训的落点。
 * cmd 不含 '\n'；可能含 '\r'（CRLF 客户端），解析前剥掉。解析会修改 cmd，
 * 因此调用方给的是可改写的原始缓冲。
 */
static int handle_line(int sock, int idx, unsigned seq_in_conn,
                       char *cmd, size_t len)
{
    static char resp[384]; /* 最长的是 STATS JSON 单行，实测 <300B；静态避免吃任务栈 */
    size_t rlen = 0;
    const char *cname = "?";
    int64_t t0 = now_us();

    if (len > 0 && cmd[len - 1] == '\r') {
        cmd[--len] = '\0'; /* CR 剥离，容忍 CRLF 客户端 */
    }

    /* 关键词 = 第一个空格前的 token；大小写不敏感是模板宽容度 */
    size_t kw = 0;
    while (kw < len && cmd[kw] != ' ') {
        kw++;
    }
    const char *data = (kw < len) ? &cmd[kw + 1] : NULL; /* 第一个空格后的原样字节流 */
    size_t dlen = (kw < len) ? len - kw - 1 : 0;

    if (len == 0) {
        return 0; /* 空行静默忽略：不发 ERR，避免盲敲回车刷屏（README 有说明）*/
    }

    if (kw == 4 && strncasecmp(cmd, "PING", 4) == 0) {
        cname = "PING";
        memcpy(resp, "PONG\n", 5);
        rlen = 5;
    } else if (kw == 4 && strncasecmp(cmd, "ECHO", 4) == 0) {
        cname = "ECHO";
        if (data != NULL) { /* ECHO <data> -> 原样返回 data + 换行；缺参回空行 */
            memcpy(resp, data, dlen);
        }
        resp[dlen] = '\n';
        rlen = dlen + 1;
    } else if (kw == 5 && strncasecmp(cmd, "STATS", 5) == 0) {
        cname = "STATS";
#if LWIP_STATS
        struct stats_snap snap;
        bool have = stats_snapshot(&snap);
        int n;
        if (have) {
            n = snprintf(resp, sizeof(resp),
                         "{\"tcp\":{\"rx\":%lu,\"tx\":%lu,\"drop\":%lu,"
                         "\"memerr\":%lu},\"heap\":{\"free\":%u,\"largest\":%u,"
                         "\"min\":%u},\"up_s\":%lld}\n",
                         (unsigned long)snap.tcp_rx, (unsigned long)snap.tcp_tx,
                         (unsigned long)snap.tcp_drop,
                         (unsigned long)snap.tcp_memerr, heap_free(),
                         heap_largest(), heap_min_ever(),
                         (long long)(now_us() / 1000000LL));
        } else {
            n = snprintf(resp, sizeof(resp),
                         "{\"tcp\":null,\"heap\":{\"free\":%u,\"largest\":%u,"
                         "\"min\":%u},\"up_s\":%lld}\n",
                         heap_free(), heap_largest(), heap_min_ever(),
                         (long long)(now_us() / 1000000LL));
        }
#else
        int n = snprintf(resp, sizeof(resp),
                         "{\"tcp\":null,\"heap\":{\"free\":%u,\"largest\":%u,"
                         "\"min\":%u},\"up_s\":%lld}\n",
                         heap_free(), heap_largest(), heap_min_ever(),
                         (long long)(now_us() / 1000000LL));
#endif
        rlen = (n >= 0 && (size_t)n < sizeof(resp)) ? (size_t)n : sizeof(resp) - 1;
    } else if (kw == 4 && strncasecmp(cmd, "TIME", 4) == 0) {
        cname = "TIME";
        int n = snprintf(resp, sizeof(resp), "up_ms=%lld up_s=%lld\n",
                         (long long)(now_us() / 1000LL),
                         (long long)(now_us() / 1000000LL));
        rlen = (n >= 0 && (size_t)n < sizeof(resp)) ? (size_t)n : sizeof(resp) - 1;
    } else {
        cname = "?"; /* 含 HELP 在内的一切未登记命令 */
        memcpy(resp, "ERR unknown\n", 12);
        rlen = 12;
    }

    if (send_all(sock, resp, rlen) != 0) {
        return -1;
    }

    s_replies_total++;
    ESP_LOGI(TAG, "conn #%d cmd[%u] %s req=%u resp=%u proc=%lldus", idx,
             seq_in_conn, cname, (unsigned)len, (unsigned)rlen,
             (long long)(now_us() - t0));
    printf("$$$ EX13REPLY idx=%d n=%u cmd=%s req_len=%u resp_len=%u us=%lld\n",
           idx, seq_in_conn, cname, (unsigned)len, (unsigned)rlen,
           (long long)(now_us() - t0));
    fflush(stdout);
    return (int)rlen;
}

/* ------------------------- 入向数据面：串行 echo 循环 ------------------------- */

/*
 * 单条入向连接的生命周期：
 *   阻塞 recv -> 按行拆包 -> 逐行处理回写，直到对端 FIN(len==0)/RST(错误)/空闲超时。
 * 命令超长截断保护：行累计缓冲只有 CMD_LINE_MAX-1 字节；超限部分的字节被丢弃并打
 * TRUNC 标记，到换行为止按"截断后的残行"继续走正常命令分发——协议永不被灌爆。
 */
static void serve_connection(int sock, const struct sockaddr_in *peer, int idx)
{
    static char chunk[RX_CHUNK];
    char line[CMD_LINE_MAX];
    size_t fill = 0;
    bool trunc = false;
    unsigned msgs = 0;
    uint64_t bytes = 0;
    const char *why = "FIN";
    int64_t t0 = now_us();

    while (1) {
        int len = recv(sock, chunk, sizeof(chunk), 0); /* 阻塞等数据（SO_RCVTIMEO 兜底）*/
        if (len > 0) {
            bytes += (uint64_t)len;
            s_bytes_in += (uint64_t)len;
            for (int i = 0; i < len; i++) { /* TCP 字节流按行拆分（消息边界自己管）*/
                char c = chunk[i];
                if (c == '\n') {
                    line[fill] = '\0';
                    msgs++;
                    if (handle_line(sock, idx, msgs, line, fill) < 0) {
                        why = "SEND-FAIL"; /* 多为对端 RST 掐线 */
                        goto done;
                    }
                    fill = 0;
                    trunc = false;
                } else if (fill < sizeof(line) - 1) {
                    line[fill++] = c;
                } else if (!trunc) {
                    /* 截断保护第一现场：只告警一次，后续同段字节静默丢弃 */
                    trunc = true;
                    ESP_LOGW(TAG, "conn #%d line too long (>=%u B), truncating "
                                  "until LF",
                             idx, (unsigned)sizeof(line));
                    printf("$$$ EX13TRUNC idx=%d n=%u kept=%u limit=%u\n", idx,
                           msgs + 1, (unsigned)(sizeof(line) - 1),
                           (unsigned)(sizeof(line) - 1));
                    fflush(stdout);
                }
            }
        } else if (len == 0) {
            break; /* 对端 FIN：优雅关闭 */
        } else {
            int e = errno;
            if (e == EAGAIN || e == EWOULDBLOCK) {
                why = "IDLE-TIMEOUT"; /* SO_RCVTIMEO 打断：哑客户端放行 */
                ESP_LOGW(TAG, "conn #%d idle timeout (%ds), releasing", idx,
                         RCVTIMEO_S);
            } else {
                why = "ERR";
                /* ECONNRESET=104 对端强断；ENOTCONN=128(newlib) 常见于复位竞态 */
                ESP_LOGW(TAG, "conn #%d recv failed errno=%d(%s)", idx, e,
                         err_name(e));
            }
            break;
        }
    }

done:
    close(sock); /* 及时回收：close 之前 PCB 持续占位 */
    ESP_LOGI(TAG, "conn #%d from %s:%d CLOSED why=%s srv=%ums msgs=%u "
                  "(%llu B in)",
             idx, inet_ntoa(peer->sin_addr), ntohs(peer->sin_port), why,
             (unsigned)((now_us() - t0) / 1000000ULL), msgs,
             (unsigned long long)bytes);
    printf("$$$ EX13CLOSE idx=%d reason=%s msgs=%u bytes=%llu ms=%u\n", idx,
           why, msgs, (unsigned long long)bytes,
           (unsigned)((now_us() - t0) / 1000ULL));
    fflush(stdout);
}

/* 入向 accept 循环：一次服务一条，先收后回、及时回收（ch23 纪律的模板落法） */
static void cmd_server_task(void *arg)
{
    struct sockaddr_in local_addr = {
        .sin_family = AF_INET,
        .sin_port = htons(CMD_PORT),
        .sin_addr.s_addr = htonl(INADDR_ANY),
    };

    /* 注意：socket 创建必须晚于 app_main 里的 esp_netif_init()
     * （tcpip 邮箱未就绪时创建/使用 socket 会 assert 复位，Batch 1 实测）。*/
    int listen_sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    assert(listen_sock >= 0);

    int opt = 1;
    setsockopt(listen_sock, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    if (bind(listen_sock, (struct sockaddr *)&local_addr, sizeof(local_addr)) != 0) {
        ESP_LOGE(TAG, "bind :%d failed errno=%d", CMD_PORT, errno);
        vTaskDelete(NULL);
    }
    if (listen(listen_sock, LISTEN_BACKLOG) != 0) {
        ESP_LOGE(TAG, "listen failed errno=%d", errno);
        vTaskDelete(NULL);
    }
    ESP_LOGI(TAG, "cmd server listening on 0.0.0.0:%d backlog=%d", CMD_PORT,
             LISTEN_BACKLOG);

    while (1) {
        struct sockaddr_in src_addr;
        socklen_t addr_len = sizeof(src_addr);
        int sock = accept(listen_sock, (struct sockaddr *)&src_addr, &addr_len);
        if (sock < 0) {
            ESP_LOGE(TAG, "accept failed errno=%d", errno);
            continue;
        }

        struct timeval tv = {.tv_sec = RCVTIMEO_S, .tv_usec = 0};
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv)); /* 空闲兜底 */

        int idx = (int)++s_conn_total;
        s_conn_active++;
        ESP_LOGI(TAG, "conn #%d ACCEPT from %s:%d (active=%u total=%u)", idx,
                 inet_ntoa(src_addr.sin_addr), ntohs(src_addr.sin_port),
                 (unsigned)s_conn_active, (unsigned)s_conn_total);
        printf("$$$ EX13CONN idx=%d from=%s:%d\n", idx,
               inet_ntoa(src_addr.sin_addr), ntohs(src_addr.sin_port));
        fflush(stdout);

        serve_connection(sock, &src_addr, idx);
        s_conn_active--;
    }
}

/* ------------------------- 出向心跳面 ------------------------- */

static void heartbeat_task(void *arg)
{
    unsigned seq = 0;
    unsigned fail_streak = 0;
    char ipbuf[16];

    /*
     * 绝对节拍锚点。FreeRTOS 契约：*pxPreviousWakeTime 必须"不超过当前
     * tick"（语义是"上一次醒来的时刻"，不是"下一次想睡到哪"）。曾按
     * 直觉写成 now+period 当锚点，结果内核的 tick 回卷启发式永远误判为
     * 已回卷、vTaskDelayUntil 判定"无需延时"当拍返回，心跳风暴式重试；
     * 正确姿势就是锚点取当前 tick——任务创建后首拍自然落在 +HB_PERIOD_MS。
     */
    TickType_t wake = xTaskGetTickCount();

    while (1) {
        vTaskDelayUntil(&wake, pdMS_TO_TICKS(HB_PERIOD_MS)); /* 所有分支都回到这里 */
        seq++;

        /* 心跳载荷在连接前组装：ip/uptime/heap_free/已服务连接数（SPEC 规定四件套）*/
        uint32_t ip_raw = ntohl(s_ip.addr);
        snprintf(ipbuf, sizeof(ipbuf), "%u.%u.%u.%u",
                 (unsigned)((ip_raw >> 24) & 0xff), (unsigned)((ip_raw >> 16) & 0xff),
                 (unsigned)((ip_raw >> 8) & 0xff), (unsigned)(ip_raw & 0xff));
        char payload[160];
        int plen = snprintf(payload, sizeof(payload),
                            "{\"type\":\"hb\",\"seq\":%u,\"ip\":\"%s\","
                            "\"up_s\":%lld,\"heap_free\":%u,\"conn_total\":%u}\n",
                            seq, ipbuf, (long long)(now_us() / 1000000LL),
                            heap_free(), (unsigned)s_conn_total);
        if (plen <= 0 || plen >= (int)sizeof(payload)) {
            continue; /* 组装失败这拍直接跳过，绝不带病连接 */
        }

        int fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (fd < 0) {
            s_hb_fail++;
            fail_streak++;
            printf("$$$ EX13HBDROP seq=%u result=SOCKET_FAIL errno=%d "
                   "streak=%u conn_total=%u\n",
                   seq, errno, fail_streak, (unsigned)s_conn_total);
            fflush(stdout);
            continue;
        }

        struct sockaddr_in dst = {
            .sin_family = AF_INET,
            .sin_port = htons(HB_PORT),
        };
        dst.sin_addr.s_addr =
            PP_HTONL(LWIP_MAKEU32(HOST_IP_OCTET1, HOST_IP_OCTET2, HOST_IP_OCTET3, HOST_IP_OCTET4));

        int64_t t0 = now_us();
        int rc = connect(fd, (struct sockaddr *)&dst, sizeof(dst));
        if (rc != 0) {
            int e = errno;
            s_hb_fail++;
            fail_streak++;
            /* SLIRP 无监听端口代答 RST -> lwIP 无 ECONNREFUSED 映射 ->
             * 实测落在 104/ECONNRESET 上（不是 Linux 教科书的 111）*/
            ESP_LOGW(TAG, "HB #%u target 10.0.2.2:%d CONNECT-FAIL errno=%d(%s)"
                          " streak=%u -- service plane unaffected",
                     seq, HB_PORT, e, err_name(e), fail_streak);
            printf("$$$ EX13HBDROP seq=%u result=CONNECT_FAIL errno=%d "
                   "name=%s elapsed_ms=%lld streak=%u conn_total=%u\n",
                   seq, e, err_name(e), (long long)((now_us() - t0) / 1000LL),
                   fail_streak, (unsigned)s_conn_total);
            close(fd);
            fflush(stdout);
            continue;
        }

        struct timeval tv = {.tv_sec = HB_ACK_TIMEOUT_S, .tv_usec = 0};
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

        if (send_all(fd, payload, (size_t)plen) != 0) {
            s_hb_fail++;
            fail_streak++;
            printf("$$$ EX13HBDROP seq=%u result=SEND_FAIL errno=%d streak=%u\n",
                   seq, errno, fail_streak);
            close(fd);
            fflush(stdout);
            continue;
        }

        char ack[32];
        int n = recv(fd, ack, sizeof(ack) - 1, 0);
        int64_t rtt_ms = (now_us() - t0) / 1000LL;
        bool acked = (n > 0) && (strncmp(ack, "ACK", 3) == 0);
        if (acked) {
            s_hb_ok++;
            fail_streak = 0;
            ESP_LOGI(TAG, "HB #%u ACKED rtt=%lldms heap=%u conn_total=%u "
                          "(up_s=%lld)",
                     seq, (long long)rtt_ms, heap_free(),
                     (unsigned)s_conn_total, (long long)(now_us() / 1000000LL));
            printf("$$$ EX13HB seq=%u result=ACK rtt_ms=%lld json=\"%.*s\"\n",
                   seq, (long long)rtt_ms, plen - 1, payload);
            fflush(stdout);
        } else {
            int e = (n < 0) ? errno : 0;
            s_hb_fail++;
            fail_streak++;
            /* 典型分支：接收器 --mode noack 故意不回话 -> SO_RCVTIMEO 到期
             * -> n=-1, errno=11(EAGAIN)；n==0 是对端发 FIN 后无 ACK */
            ESP_LOGW(TAG, "HB #%u NO_ACK n=%d errno=%d(%s) rtt=%lldms "
                          "streak=%u -- service plane unaffected",
                     seq, n, e, err_name(e), (long long)rtt_ms, fail_streak);
            printf("$$$ EX13HBDROP seq=%u result=NO_ACK recv_n=%d errno=%d "
                   "name=%s rtt_ms=%lld streak=%u conn_total=%u\n",
                   seq, n, e, err_name(e), (long long)rtt_ms, fail_streak,
                   (unsigned)s_conn_total);
            fflush(stdout);
        }

        close(fd); /* 等到 ACK（或判定失败）即断开：一拍一会话 */
        /* 节拍统一收口在循环顶部的 vTaskDelayUntil：错误分支的 continue
         * 也一样绕回顶部先过节拍再发下一拍，风暴路径不再可能绕过周期。 */
    }
}

/* ------------------------- 低频观测面 -------------------------
 * 与两个数据面彻底分离的健康检查钩子（CI 可 grep '$$$ EX13STATS' 断言存活）。*/
static void obs_task(void *arg)
{
    while (1) {
        vTaskDelay(pdMS_TO_TICKS(15000));
        printf("$$$ EX13STATS conn_total=%u active=%u replies=%u hb_ok=%u "
               "hb_fail=%u bytes_in=%llu uptime_s=%lld\n",
               (unsigned)s_conn_total, (unsigned)s_conn_active,
               (unsigned)s_replies_total, (unsigned)s_hb_ok,
               (unsigned)s_hb_fail, (unsigned long long)s_bytes_in,
               (long long)(now_us() / 1000000LL));
        fflush(stdout);
    }
}

/* ------------------------- 事件处理（标准模板） ------------------------- */

static void eth_event_handler(void *arg, esp_event_base_t base,
                              int32_t event_id, void *event_data)
{
    switch (event_id) {
    case ETHERNET_EVENT_START:
        ESP_LOGI(TAG, "ETH_EVENT: START");
        break;
    case ETHERNET_EVENT_STOP:
        ESP_LOGI(TAG, "ETH_EVENT: STOP");
        break;
    case ETHERNET_EVENT_CONNECTED:
        ESP_LOGI(TAG, "ETH_EVENT: CONNECTED (link up)");
        break;
    case ETHERNET_EVENT_DISCONNECTED:
        ESP_LOGI(TAG, "ETH_EVENT: DISCONNECTED (link down)");
        break;
    default:
        ESP_LOGI(TAG, "ETH_EVENT: id=%ld", (long)event_id);
        break;
    }
}

static void ip_event_handler(void *arg, esp_event_base_t base,
                             int32_t event_id, void *event_data)
{
    ip_event_got_ip_t *evt = (ip_event_got_ip_t *)event_data;
    s_ip = evt->ip_info.ip;
    ESP_LOGI(TAG, "GOT_IP: " IPSTR "/255.255.255.0 gw 10.0.2.2",
             IP2STR(&evt->ip_info.ip));
    xSemaphoreGive(s_got_ip);
}

/* ------------------------- app_main：标准 bring-up 序列（SPEC §3）------------------------- */

void app_main(void)
{
    ESP_LOGI(TAG, "== ex13 tcp-hostlink build@%s %s ==", __DATE__, __TIME__);
    printf("$$$ EX13BUILD \"%s %s\"\n", __DATE__, __TIME__);
    fflush(stdout);

    /* netif 初始化三件套：esp_netif_init 必须是第一句网络调用
     * （socket 创建在其之后才安全，见 cmd_server_task 注释）*/
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    s_got_ip = xSemaphoreCreateBinary();
#if LWIP_STATS
    s_snap_done = xSemaphoreCreateBinary();
#endif

    esp_netif_config_t netif_cfg = ESP_NETIF_DEFAULT_ETH();
    esp_netif_t *eth_netif = esp_netif_new(&netif_cfg);

    eth_mac_config_t mac_cfg = ETH_MAC_DEFAULT_CONFIG();
    eth_phy_config_t phy_cfg = ETH_PHY_DEFAULT_CONFIG();
    phy_cfg.reset_gpio_num = -1; /* 虚拟 PHY 无复位引脚 */
    phy_cfg.autonego_timeout_ms = 3000;

    esp_eth_mac_t *mac = esp_eth_mac_new_openeth(&mac_cfg);
    assert(mac != NULL);
    esp_eth_phy_t *phy = esp_eth_phy_new_generic(&phy_cfg);
    assert(phy != NULL);

    esp_eth_config_t eth_cfg = ETH_DEFAULT_CONFIG(mac, phy);
    esp_eth_handle_t eth_handle = NULL;
    ESP_ERROR_CHECK(esp_eth_driver_install(&eth_cfg, &eth_handle));

    ESP_ERROR_CHECK(esp_event_handler_register(ETH_EVENT, ESP_EVENT_ANY_ID,
                                               &eth_event_handler, NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_ETH_GOT_IP,
                                               &ip_event_handler, NULL));

    esp_eth_netif_glue_handle_t glue = esp_eth_new_netif_glue(eth_handle);
    ESP_ERROR_CHECK(esp_netif_attach(eth_netif, glue));

    /* 观测面先行创建也无妨（不碰 socket）；两个数据面等拿到 IP 再启动 */
    xTaskCreate(obs_task, "ex13_obs", 2560, NULL, 4, NULL);

    ESP_ERROR_CHECK(esp_eth_start(eth_handle));
    ESP_LOGI(TAG, "waiting for DHCP lease ...");

    if (xSemaphoreTake(s_got_ip, pdMS_TO_TICKS(DHCP_TIMEOUT_MS)) != pdTRUE) {
        ESP_LOGE(TAG, "DHCP timeout after %d ms", DHCP_TIMEOUT_MS);
        printf("$$$ EXFAIL reason=dhcp_timeout after_ms=%d\n", DHCP_TIMEOUT_MS);
        fflush(stdout);
        return;
    }
    ESP_LOGI(TAG, "net ready: " IPSTR "/24 gw 10.0.2.2", IP2STR(&s_ip));
    printf("$$$ EX13NETUP ip=" IPSTR " gw=10.0.2.2\n", IP2STR(&s_ip));
    fflush(stdout);

    /* 双面并发：各自独立任务，优先级同为应用级 5，互不为对方前置 */
    xTaskCreate(cmd_server_task, "ex13_cmd_srv", 4096, NULL, 5, NULL);
    xTaskCreate(heartbeat_task, "ex13_hb_cli", 8192, NULL, 5, NULL);

    printf("$$$ EX13READY port=%d backlog=%d hb_target=10.0.2.2:%d "
           "hb_period_ms=%d cmd_max=%u idle_rcvtimeo_s=%d\n",
           CMD_PORT, LISTEN_BACKLOG, HB_PORT, HB_PERIOD_MS,
           (unsigned)(CMD_LINE_MAX - 1), RCVTIMEO_S);
    fflush(stdout);

    /* KEEPALIVE：app_main 返回即自杀，服务器要常驻 */
    while (1) {
        vTaskDelay(pdMS_TO_TICKS(60000));
    }
}
