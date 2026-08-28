/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * ex11 throughput-bench —— 吞吐基准模板（iperf-lite）
 *
 * 双模式单固件：
 *   TX 泵  ：guest 用阻塞 send() 把 N MB 图样灌到宿主机 tools/sink.py（10.0.2.2:8290，
 *            SLIRP 落宿主 loopback 同端口，无需 hostfwd）；发完半关连接，等 sink 回
 *            一个 'K' 作为「已被完整消费」的应答位。
 *   RX 灌入：guest 监听 :8291（经 hostfwd tcp::8291-:8291），宿主机 tools/flood.py
 *            连入灌 N MB 后半关；guest 收满/见 EOF 后回 'K'。
 *
 * 方法学（ch6/ch24 沉淀）：
 *   - 双计时口径：guest 用 esp_timer_get_time()（µs 网格），宿主工具用
 *     time.monotonic()；两侧各自报吞吐与字节量互相印证，不共用时钟。
 *   - digest 校验：Fletcher-16（与 ch6 同法 mod 255），配 64 KiB xorshift32
 *     确定性图样——C 与 Python 各自实现同一递推式，digest 对上即内容对上。
 *   - 轮次交错：BOTH 模式按 T1,R1,T2,R2,... 执行，证明两方向反复横跳后
 *     计数仍干净（无泄漏累积、无状态残留）。
 *
 * 旋钮：
 *   menuconfig "Example Throughput Bench Configuration"：模式/轮数/MB/等待秒数；
 *   SDK 级旋钮 CONFIG_LWIP_TCP_SND_BUF_DEFAULT / CONFIG_LWIP_TCP_WND_DEFAULT 走
 *   两档预设：sdkconfig.defaults（基线）/ sdkconfig.defaults.wide（宽窗，
 *   ⚠ 必须删 sdkconfig 重生成才生效）。开机打印实际生效值供核对。
 *
 * 运行环境：ESP-IDF v6.0.2 + qemu-system-xtensa (openeth/SLIRP)。
 */

#include <stdio.h>
#include <string.h>
#include <stdarg.h>
#include <errno.h>
#include <fcntl.h>
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <inttypes.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"

#include "esp_log.h"
#include "esp_timer.h"
#include "esp_event.h"
#include "esp_netif.h"
#include "esp_eth.h"

#include "lwip/opt.h"
#include "lwip/inet.h"
#include "lwip/sockets.h"

static const char *TAG = "ex11";

/* ---------------------------- 目标与负载 ----------------------------- */

#define HOST_IP      "10.0.2.2" /* SLIRP 网关 == 宿主机 loopback */
#define TX_PORT      8290       /* SPEC §4 ex11 号段：TX 模式宿主 sink 口（guest 出连）*/
#define RX_PORT      8291       /* RX 模式 guest 监听口（hostfwd tcp::8291-:8291）*/

#define TILE_LEN     (64u * 1024u) /* 确定性图样周期，两端同构 */
#define TX_CHUNK     (8u * 1024u)  /* 单次 send 切片上限 */
#define RX_BUF_SZ    (16u * 1024u)
#define ROUND_GAP_MS 300           /* 轮间缓冲，让串口日志冲刷出去 */

#define SEND_TIMEOUT_SEC 10 /* SO_SNDTIMEO：发送不许裸奔 */
#define RECV_TIMEOUT_SEC 15 /* SO_RCVTIMEO：接收不许裸奔 */
#define ACK_BYTE ('K')      /* 双端约定的完成应答位（ch24 手法）*/

enum { M_BOTH = 0, M_TX = 1, M_RX = 2 };
#if defined(CONFIG_EXAMPLE_BENCH_MODE_TX)
#define BENCH_MODE M_TX
#elif defined(CONFIG_EXAMPLE_BENCH_MODE_RX)
#define BENCH_MODE M_RX
#else
#define BENCH_MODE M_BOTH
#endif

#define ROUNDS          CONFIG_EXAMPLE_BENCH_ROUNDS
#define BYTES_ONE_ROUND ((uint32_t)CONFIG_EXAMPLE_BENCH_MB * 1000000u)

static const char *mode_name(void)
{
    switch (BENCH_MODE) {
    case M_TX:
        return "tx";
    case M_RX:
        return "rx";
    default:
        return "both";
    }
}

/* 带冲刷的输出：机器可读行必须能完整落在串口里 */
static void out(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    fflush(stdout);
}

/* ------------------------ Fletcher-16 + 确定性图样 ----------------------
 * 两端逐位一致：guest C 版 / 宿主 python 版实现同一算法。
 * xorshift32：x^=x<<13; x^=x>>17; x^=x<<5；取高 8 位为一个字节。
 */
struct fletcher {
    uint16_t s1, s2;
};

static inline void fl_init(struct fletcher *f)
{
    f->s1 = f->s2 = 0;
}

static inline void fl_update(struct fletcher *f, const uint8_t *p, size_t n)
{
    for (size_t i = 0; i < n; i++) {
        f->s1 = (uint16_t)((f->s1 + p[i]) % 255);
        f->s2 = (uint16_t)((f->s2 + f->s1) % 255);
    }
}

static inline unsigned fl_digest(const struct fletcher *f)
{
    return (unsigned)((f->s2 << 8) | f->s1);
}

#define PAT_SEED 0x11c0ffeeu

static uint32_t xs32(uint32_t *st)
{
    *st ^= *st << 13;
    *st ^= *st >> 17;
    *st ^= *st << 5;
    return *st;
}

static void fill_tile(uint8_t *buf)
{
    uint32_t st = PAT_SEED;
    for (uint32_t i = 0; i < TILE_LEN; i++) {
        buf[i] = (uint8_t)(xs32(&st) >> 24);
    }
}

static uint8_t s_tile[TILE_LEN];   /* TX 图样环形缓冲 */
static uint8_t s_rxbuf[RX_BUF_SZ]; /* RX 搬运缓冲 */

/* ------------------------------- 时间辅助 ------------------------------ */

static int64_t now_us(void)
{
    return esp_timer_get_time();
}

static long us_to_ms(int64_t us)
{
    return (long)((us + 500) / 1000);
}

/* bytes × 8 / µs ⇒ Mbit/s */
static double mbit_of(uint64_t bytes, int64_t us)
{
    if (us <= 0) {
        return 0.0;
    }
    return (double)bytes * 8.0 / (double)us;
}

typedef enum {
    ST_OK = 0,
    ST_PARTIAL,   /* 中途出错或超时，只完成一部分 */
    ST_PEER_DOWN, /* 对端始终没来（拒连 / 无人接入） */
} bench_status_t;

static const char *st_name(bench_status_t s)
{
    switch (s) {
    case ST_OK:
        return "OK";
    case ST_PARTIAL:
        return "PARTIAL";
    default:
        return "PEER_DOWN";
    }
}

/* ------------------------- openeth bring-up 骨架 ------------------------ */

static SemaphoreHandle_t s_got_ip;

static void eth_event_handler(void *arg, esp_event_base_t base, int32_t event_id,
                              void *event_data)
{
    (void)arg;
    (void)base;
    (void)event_data;
    switch (event_id) {
    case ETHERNET_EVENT_START:
        ESP_LOGI(TAG, "[EX11] ETH START");
        break;
    case ETHERNET_EVENT_CONNECTED:
        ESP_LOGI(TAG, "[EX11] ETH CONNECTED (link up)");
        break;
    case ETHERNET_EVENT_DISCONNECTED:
        ESP_LOGW(TAG, "[EX11] ETH DISCONNECTED");
        break;
    default:
        break;
    }
}

static void ip_event_handler(void *arg, esp_event_base_t base, int32_t event_id,
                             void *event_data)
{
    (void)arg;
    (void)base;
    ip_event_got_ip_t *evt = (ip_event_got_ip_t *)event_data;
    ESP_LOGI(TAG, "[EX11] GOT_IP " IPSTR " gw " IPSTR, IP2STR(&evt->ip_info.ip),
             IP2STR(&evt->ip_info.gw));
    xSemaphoreGive(s_got_ip);
}

/* ----------------------------- 配置自报 ---------------------------------
 * 开机打印编译进镜像的真实配置指纹：核对 SND_BUF/WND 是否生效，并按
 * 「窗口×RX 环深不等式」（ch24）当场给出是否自毁式调参的判断。
 */
#ifdef CONFIG_ETH_OPENETH_DMA_RX_BUFFER_NUM
#define OPENETH_RING CONFIG_ETH_OPENETH_DMA_RX_BUFFER_NUM
#else
#define OPENETH_RING (-1) /* 未知 IDF 版本：不猜值 */
#endif

static void print_cfg(void)
{
    out("[EX11] PHASE=READY mode=%s rounds=%d mb=%d tile_kb=%u tx=%s:%d rx=:%d "
        "want_bytes_per_round=%" PRIu32 "\n",
        mode_name(), ROUNDS, (int)CONFIG_EXAMPLE_BENCH_MB, TILE_LEN / 1024, HOST_IP,
        TX_PORT, RX_PORT, BYTES_ONE_ROUND);
    out("[EX11] BUILD %s %s snd_buf=%d wnd=%d mss=%d openeth_ring=%d\n", __DATE__,
        __TIME__, (int)TCP_SND_BUF, (int)TCP_WND, (int)TCP_MSS, OPENETH_RING);

    /* 窗口×RX 环深不等式：WND>=11520 需环>=16，WND>=28800 需环>=32。
     * 只拧窗口不抬环 = 吞吐黑洞（个位数 Mbit），开机即可发现而不是跑完才发现。 */
    if (OPENETH_RING > 0 && (int)TCP_WND >= 28800 && OPENETH_RING < 32) {
        out("[EX11] CFGWARN wnd=%d ring=%d 不等式要求>=32 —— RX 方向可能坍缩！\n",
            (int)TCP_WND, OPENETH_RING);
    } else if (OPENETH_RING > 0 && (int)TCP_WND >= 11520 && OPENETH_RING < 16) {
        out("[EX11] CFGWARN wnd=%d ring=%d 不等式要求>=16 —— RX 方向可能黑洞！\n",
            (int)TCP_WND, OPENETH_RING);
    } else {
        out("[EX11] CFGOK wnd-ring inequality satisfied (or unknown)\n");
    }
}

/* ----------------------------- TX 泵轮次 -------------------------------- */

typedef struct {
    bench_status_t status;
    uint64_t bytes; /* 实际被 send() 接受的字节数 */
    long conn_ms;   /* 含重试等待的建链耗时（对端先起则≈纯建链） */
    long xfer_ms;   /* 首 byte 入栈 → 末 byte 被 send 接受 */
    long full_ms;   /* 直至 sink 回 'K' 应答位（≈完整投递口径） */
    double mbit;
    unsigned digest;
    int refusals; /* connect 被拒次数 */
    int stalls;   /* send EAGAIN 次数 */
    int ack_ok;   /* 'K' 应答位是否收到（1/0） */
    int err_no;
} tx_result_t;

static void sock_timeouts(int s)
{
    struct timeval tv = { .tv_sec = RECV_TIMEOUT_SEC, .tv_usec = 0 };
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    tv.tv_sec = SEND_TIMEOUT_SEC;
    setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
}

static void tx_round(int round, tx_result_t *r)
{
    memset(r, 0, sizeof(*r));
    r->status = ST_OK;
    const int64_t budget_us = (int64_t)CONFIG_EXAMPLE_BENCH_PEER_WAIT_SEC * 1000000LL;
    const int64_t t_round0 = now_us();
    const int64_t t_deadline = t_round0 + budget_us;
    struct sockaddr_in dst = {
        .sin_family = AF_INET,
        .sin_port = htons(TX_PORT),
        .sin_addr.s_addr = inet_addr(HOST_IP),
    };

    /* --- 建连：非阻塞 connect + select 死线（ex06 手法），对端拒绝就退避重试 --- */
    int s = -1;
    for (;;) {
        s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (s < 0) {
            r->status = ST_PARTIAL;
            r->err_no = errno;
            break;
        }
        sock_timeouts(s);
        int flags = fcntl(s, F_GETFL, 0);
        if (flags >= 0) {
            fcntl(s, F_SETFL, flags | O_NONBLOCK);
        }

        int rc = connect(s, (struct sockaddr *)&dst, sizeof(dst));
        if (rc != 0 && errno == EINPROGRESS) {
            const int64_t wait_us = t_deadline - now_us();
            if (wait_us <= 0) {
                errno = ETIMEDOUT;
                rc = -1;
            } else {
                fd_set wfds;
                FD_ZERO(&wfds);
                FD_SET(s, &wfds);
                struct timeval slice = {
                    .tv_sec = (long)(wait_us / 1000000),
                    .tv_usec = (long)(wait_us % 1000000),
                };
                rc = select(s + 1, NULL, &wfds, NULL, &slice);
                if (rc > 0) {
                    int soerr = 0;
                    socklen_t slen = sizeof(soerr);
                    getsockopt(s, SOL_SOCKET, SO_ERROR, &soerr, &slen);
                    /* 关键：把 select 的 ">0 可写" 归一成完成态，
                     * 否则陈旧 errno(EINPROGRESS=119) 会被当成失败 */
                    if (soerr != 0) {
                        errno = soerr;
                        rc = -1;
                    } else {
                        rc = 0;
                    }
                } else if (rc == 0) {
                    errno = ETIMEDOUT;
                    rc = -1;
                }
            }
        }

        if (rc == 0) {
            r->conn_ms = us_to_ms(now_us() - t_round0);
            break; /* 连上了（不管试了几次） */
        }
        const int cerr = errno;
        close(s);
        s = -1;
        if (cerr == ECONNREFUSED || cerr == ECONNRESET || cerr == EHOSTUNREACH ||
            cerr == ENETUNREACH || cerr == ETIMEDOUT) {
            r->refusals++;
            if (now_us() >= t_deadline) {
                r->status = ST_PEER_DOWN; /* 等到死线仍无 sink：放弃本轮 */
                r->err_no = ECONNREFUSED;
                break;
            }
            vTaskDelay(pdMS_TO_TICKS(300));
            continue;
        }
        r->status = ST_PARTIAL;
        r->err_no = cerr;
        break;
    }

    if (s < 0) {
        out("[EX11] TX R=%d RESULT status=%s refusals=%d err=%d(%s)\n", round,
            st_name(r->status), r->refusals, r->err_no,
            strerror(r->err_no ? r->err_no : ECONNREFUSED));
        return;
    }

    int flat_flags = fcntl(s, F_GETFL, 0);
    if (flat_flags >= 0) {
        fcntl(s, F_SETFL, flat_flags & ~O_NONBLOCK); /* 还原阻塞模式再灌流 */
    }
    ESP_LOGI(TAG, "[EX11] TX R=%d connected %s:%d (wait %ld ms)", round, HOST_IP, TX_PORT,
             r->conn_ms);

    /* --- 泵循环：图样环形切片；send 部分接受也按字节记账进 digest --- */
    struct fletcher fl;
    fl_init(&fl);
    uint32_t pat_off = 0;
    uint64_t sent_ok = 0;
    int last_err = 0;
#if PROGRESS_ON
    uint64_t last_mib = 0;
#endif
    const int64_t t_x0 = now_us();

    while (sent_ok < BYTES_ONE_ROUND && last_err == 0) {
        size_t want = TX_CHUNK;
        if ((size_t)(TILE_LEN - pat_off) < want) {
            want = TILE_LEN - pat_off;
        }
        if ((uint64_t)(BYTES_ONE_ROUND - sent_ok) < want) {
            want = (size_t)(BYTES_ONE_ROUND - sent_ok);
        }
        ssize_t w = send(s, s_tile + pat_off, want, 0);
        if (w > 0) {
            fl_update(&fl, s_tile + pat_off, (size_t)w);
            sent_ok += (uint64_t)w;
            pat_off = (pat_off + (uint32_t)w) % TILE_LEN;
#if PROGRESS_ON
            if (sent_ok / 1048576u > last_mib) {
                last_mib = sent_ok / 1048576u;
                out("[EX11] TX R=%d progress %" PRIu64 " MiB\n", round, last_mib);
            }
#endif
        } else if (w < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            r->stalls++; /* 发送缓冲超时未排空：缓一口再继续 */
            vTaskDelay(pdMS_TO_TICKS(10));
        } else if (w < 0) {
            last_err = errno;
        } else {
            last_err = EIO; /* w==0 防御分支 */
        }
    }
    const int64_t t_xend = now_us();
    r->bytes = sent_ok;
    r->digest = fl_digest(&fl);
    r->xfer_ms = us_to_ms(t_xend - t_x0);
    r->mbit = mbit_of(sent_ok, t_xend - t_x0);

    /* --- 半关 + 等 'K'：sink 把数据全部消费完的时刻才是真正的投递终点 --- */
    shutdown(s, SHUT_WR);
    char ack = 0;
    int64_t t_full_end = t_xend;
    ssize_t k = recv(s, &ack, 1, 0);
    if (k == 1 && ack == ACK_BYTE) {
        r->ack_ok = 1;
        t_full_end = now_us();
    }
    close(s);
    r->full_ms = us_to_ms(t_full_end - t_x0);

    r->status = (sent_ok >= BYTES_ONE_ROUND) ? ST_OK : ST_PARTIAL;
    r->err_no = last_err;

    out("[EX11] TX R=%d RESULT status=%s bytes=%" PRIu64 "/%" PRIu32
        " conn_ms=%ld xfer_ms=%ld full_ms=%ld mbit=%.2f stall=%d refusals=%d ack=%d "
        "digest=%04x err=%d\n",
        round, st_name(r->status), sent_ok, BYTES_ONE_ROUND, r->conn_ms, r->xfer_ms,
        r->full_ms, r->mbit, r->stalls, r->refusals, r->ack_ok, r->digest, r->err_no);
}

/* ----------------------------- RX 灌入轮次 ------------------------------ */

typedef struct {
    bench_status_t status;
    uint64_t got; /* 实收字节数 */
    long wait_ms; /* listener 就绪 → 对端接入 */
    long xfer_ms; /* 首 byte 到达 → EOF/收满 */
    double mbit;
    unsigned digest;
    int stalls; /* recv EAGAIN 次数 */
    int err_no;
    char peer[18];
} rx_result_t;

static void rx_round(int round, int lsock, rx_result_t *r)
{
    memset(r, 0, sizeof(*r));
    r->status = ST_OK;
    const int64_t t_wait0 = now_us();
    const int64_t deadline =
        t_wait0 + (int64_t)CONFIG_EXAMPLE_BENCH_RX_WAIT_SEC * 1000000LL;

    /* --- 等 flood 工具来连：select 片式轮询保证可超时退出 --- */
    int sock = -1;
    while (sock < 0) {
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(lsock, &rfds);
        struct timeval slice = { .tv_sec = 0, .tv_usec = 250000 };
        int rc = select(lsock + 1, &rfds, NULL, NULL, &slice);
        if (rc > 0) {
            struct sockaddr_in sa;
            socklen_t alen = sizeof(sa);
            int fd = accept(lsock, (struct sockaddr *)&sa, &alen);
            if (fd >= 0) {
                sock = fd;
                r->wait_ms = us_to_ms(now_us() - t_wait0);
                inet_ntoa_r(sa.sin_addr, r->peer, sizeof(r->peer));
                ESP_LOGI(TAG, "[EX11] RX R=%d CONN from=%s:%d (wait %ld ms)", round,
                         r->peer, (int)ntohs(sa.sin_port), r->wait_ms);
                /* 应用层就绪握手：accept 完成即回 'R'。
                 * 背景：SLIRP 的 hostfwd 会立刻接受宿主侧 connect()（哪怕 guest
                 * 还没监听），flood 若直接开始灌流会把数据灌进幻影连接、搅乱
                 * 测量窗口甚至吃 RST——所以由 guest 亲自发令枪。 */
                (void)!send(sock, "R", 1, 0);
                break;
            }
            r->err_no = errno;
        }
        if (now_us() >= deadline) {
            r->status = ST_PEER_DOWN;
            out("[EX11] RX R=%d RESULT status=PEER_DOWN waited_s=%d\n", round,
                (int)CONFIG_EXAMPLE_BENCH_RX_WAIT_SEC);
            return;
        }
    }

    /* --- 收满 / 见 EOF 为止，边收边算 digest --- */
    sock_timeouts(sock);
    struct fletcher fl;
    fl_init(&fl);
    uint64_t got = 0;
    int last_err = 0;
    const int64_t t0 = now_us();
    for (;;) {
        ssize_t n = recv(sock, s_rxbuf, sizeof(s_rxbuf), 0);
        if (n > 0) {
            fl_update(&fl, s_rxbuf, (size_t)n);
            got += (uint64_t)n;
            if (got >= BYTES_ONE_ROUND) {
                break; /* 收满即止（flood 只发精确量） */
            }
        } else if (n == 0) {
            break; /* 对端半关：正常终点 */
        } else if (errno == EAGAIN || errno == EWOULDBLOCK) {
            last_err = ETIMEDOUT; /* 流中途断供 15s：判死而不是傻等 */
            break;
        } else {
            last_err = errno;
            break;
        }
    }
    const int64_t tend = now_us();
    r->got = got;
    r->digest = fl_digest(&fl);
    r->xfer_ms = us_to_ms(tend - t0);
    r->mbit = mbit_of(got, tend - t0);

    /* 完成应答位：flood 以此确定 guest 已收完并记账 */
    (void)!send(sock, "K", 1, 0);
    shutdown(sock, SHUT_RDWR);
    close(sock);

    r->status = (got >= BYTES_ONE_ROUND)  ? ST_OK
                : (last_err == ETIMEDOUT) ? ST_PEER_DOWN
                                          : ST_PARTIAL;
    r->err_no = last_err;
    out("[EX11] RX R=%d RESULT status=%s got=%" PRIu64 "/%" PRIu32 " wait_ms=%ld "
        "xfer_ms=%ld mbit=%.2f digest=%04x stall=%d err=%d\n",
        round, st_name(r->status), got, BYTES_ONE_ROUND, r->wait_ms, r->xfer_ms, r->mbit,
        r->digest, r->stalls, r->err_no);
}

/* RX 监听口：整个会话建一次，避免轮间重建竞态 */
static int make_listener(void)
{
    int ls = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (ls < 0) {
        return -1;
    }
    int opt = 1;
    setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    struct sockaddr_in la = {
        .sin_family = AF_INET,
        .sin_port = htons(RX_PORT),
        .sin_addr.s_addr = htonl(INADDR_ANY),
    };
    if (bind(ls, (struct sockaddr *)&la, sizeof(la)) != 0) {
        ESP_LOGE(TAG, "[EX11] bind(:%d) failed errno=%d(%s)", RX_PORT, errno,
                 strerror(errno));
        close(ls);
        return -1;
    }
    if (listen(ls, 4) != 0) {
        ESP_LOGE(TAG, "[EX11] listen(:%d) failed errno=%d", RX_PORT, errno);
        close(ls);
        return -1;
    }
    out("[EX11] RX_LISTEN port=%d backlog=4\n", RX_PORT);
    return ls;
}

/* ------------------------------- 调度任务 ------------------------------- */

static void bench_task(void *arg)
{
    (void)arg;
    fill_tile(s_tile);
    print_cfg();

    const bool do_tx = (BENCH_MODE == M_BOTH || BENCH_MODE == M_TX);
    const bool do_rx = (BENCH_MODE == M_BOTH || BENCH_MODE == M_RX);

    unsigned tx_ok = 0, rx_ok = 0;
    double tx_mbit_acc = 0.0, rx_mbit_acc = 0.0;
    bool tx_peer_down = false, rx_peer_down = false;

    for (int r = 1; r <= ROUNDS; r++) {
        if (do_tx && !tx_peer_down) {
            out("[EX11] -- T%d BEGIN target=%s:%d bytes=%" PRIu32 "\n", r, HOST_IP, TX_PORT,
                BYTES_ONE_ROUND);
            tx_result_t tr;
            tx_round(r, &tr);
            if (tr.status == ST_OK) {
                tx_ok++;
                tx_mbit_acc += tr.mbit;
            } else if (tr.status == ST_PEER_DOWN) {
                tx_peer_down = true; /* 对端不在：跳过剩余 TX 轮，别空转 */
            }
        }
        if (do_rx && !rx_peer_down) {
            /* 监听口按轮懒建懒拆： flood 拿不到 backlog 里排队的机会，
             * connect 只会"拒绝→重试"，序列化天然成立，双方计时窗口不互相污染。 */
            out("[EX11] -- R%d BEGIN listening=:%d bytes=%" PRIu32 "\n", r, RX_PORT,
                BYTES_ONE_ROUND);
            int lsock = make_listener();
            if (lsock < 0) {
                rx_peer_down = true; /* bind/listen 失败不会自愈，别再试 */
            } else {
                rx_result_t rr;
                rx_round(r, lsock, &rr);
                close(lsock);
                if (rr.status == ST_OK) {
                    rx_ok++;
                    rx_mbit_acc += rr.mbit;
                } else if (rr.status == ST_PEER_DOWN) {
                    rx_peer_down = true;
                }
            }
        }
        vTaskDelay(pdMS_TO_TICKS(ROUND_GAP_MS));
    }
    out("[EX11] SUMMARY mode=%s rounds=%d tx_ok=%u/%d avg_tx_mbit=%.1f rx_ok=%u/%d "
        "avg_rx_mbit=%.1f\n",
        mode_name(), ROUNDS, tx_ok, do_tx ? ROUNDS : 0, tx_ok ? tx_mbit_acc / tx_ok : 0.0,
        rx_ok, do_rx ? ROUNDS : 0, rx_ok ? rx_mbit_acc / rx_ok : 0.0);
    out("[EX11] PHASE=DONE -- rounds finished, restarting to exit QEMU cleanly\n");
    vTaskDelay(pdMS_TO_TICKS(500)); /* 让 DONE 行从 UART 冲出去 */
    esp_restart();                  /* -no-reboot 下进程干净结束（ex06 先例） */
}

/* ------------------------------- app_main ------------------------------- */

void app_main(void)
{
    ESP_LOGI(TAG, "== ex11 throughput-bench (iperf-lite, TX pump + RX flood) ==");

    /* 1. esp_netif_init 必须是第一句网络调用（tcpip 邮箱在此建立） */
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    s_got_ip = xSemaphoreCreateBinary();

    esp_netif_config_t netif_cfg = ESP_NETIF_DEFAULT_ETH();
    esp_netif_t *eth_netif = esp_netif_new(&netif_cfg);

    eth_mac_config_t mac_cfg = ETH_MAC_DEFAULT_CONFIG();
    eth_phy_config_t phy_cfg = ETH_PHY_DEFAULT_CONFIG();
    phy_cfg.reset_gpio_num = -1; /* 虚拟 PHY 无复位脚 */
    phy_cfg.autonego_timeout_ms = 3000;

    esp_eth_mac_t *mac = esp_eth_mac_new_openeth(&mac_cfg);
    assert(mac);
    esp_eth_phy_t *phy = esp_eth_phy_new_generic(&phy_cfg);
    assert(phy);

    esp_eth_config_t eth_cfg = ETH_DEFAULT_CONFIG(mac, phy);
    esp_eth_handle_t eth_handle = NULL;
    ESP_ERROR_CHECK(esp_eth_driver_install(&eth_cfg, &eth_handle));

    ESP_ERROR_CHECK(
        esp_event_handler_register(ETH_EVENT, ESP_EVENT_ANY_ID, &eth_event_handler, NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_ETH_GOT_IP,
                                               &ip_event_handler, NULL));

    esp_eth_netif_glue_handle_t glue = esp_eth_new_netif_glue(eth_handle);
    ESP_ERROR_CHECK(esp_netif_attach(eth_netif, glue));
    ESP_ERROR_CHECK(esp_eth_start(eth_handle));

    if (xSemaphoreTake(s_got_ip, pdMS_TO_TICKS(15000)) != pdTRUE) {
        ESP_LOGE(TAG, "[EX11] DHCP timeout after 15s -- check QEMU -nic");
        return;
    }

    xTaskCreate(bench_task, "bench", 6144, NULL, 5, NULL);
}
