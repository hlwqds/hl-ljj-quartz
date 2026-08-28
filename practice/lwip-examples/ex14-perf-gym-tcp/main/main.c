/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * ex14 perf-gym-tcp —— TCP 配置错误健身房（每场景：症状→诊断→根因→修复→前后数据）
 *
 * 一个固件内建可切换的错误配置场景（CONFIG_GYM_SCENARIO，构建期切换），
 * 跑同一套基准负载让使用者亲手走完"性能坏了→定位→修复→优化"的闭环。
 *
 * 负载三腿（同开机交错轮次，ch6 方法学）：
 *   LB 镜像回声 ：guest 对宿主 tools/gym_echo.py(10.0.2.2:8312) 做全双工
 *                 select 泵，上/下行各计吞吐与 Fletcher-16 摘要。不用 127.0.0.1
 *                 自连——本环境内建回环路径有系统级咬死缺陷（见文件尾/README）。
 *   TX 外发泵   ：guest 用 **raw API**（tcp_write/tcp_output + 回调）把图样灌到宿主
 *                 tools/gym_sink.py 监听的 10.0.2.2:8311。用 raw API 是刻意的：
 *                 场景 3 的病就是"漏挂 tcp_sent"，只有在这条腿上才是原生病灶
 *                 （ch6 复刻）。回调全部活在 tcpip_thread 内；跨线程只投递
 *                 tcpip_callback 步进函数（ch15 纪律）。
 *   RX 灌入     ：guest 监听 :8310（QEMU 侧 hostfwd tcp::8310-:8310），宿主
 *                 tools/gym_flood.py 灌流，guest 收满回 'K'。openeth RX 描述符环
 *                 只在入向路径上——场景 2 的黑洞专挑这条腿发作。
 *
 * 场景表（坏值都由 sdkconfig.defaults.scN 预设提供，本文件只负责行为层）：
 *   0 健康基线            SND/WND=5760       ring=4(默认)  MAX_ACTIVE_TCP=16
 *   1 窗口过小            SND/WND=2×MSS=2880 ring=4        全部默认其余
 *   2 大窗小环黑洞        SND/WND=28800      ring=4 ← 病根  （修复版 ring=32）
 *   3 发送泵漏挂 tcp_sent 基线旋钮；main.c 条件编译跳过注册行 ← 病根在代码
 *   4 PCB 计数闸          MAX_ACTIVE_TCP=2 → listen(1)+client(1) 已占满，
 *                         child 分配失败 → SYN 静默丢 + tcp.memerr 爬升；
 *                         固件自动切为并发探针 profile（三腿数据轮关闭）。
 *
 * 方法论锚点：双计时口径（esp_timer 与宿主 monotonic 互证）、digest 校验、
 * 同开机成对测量（CONVENTIONS Batch 4：QEMU 吞吐受宿主负载 ±50% 摆动）。
 *
 * 运行环境：ESP-IDF v6.0.2 + qemu-system-xtensa (openeth/SLIRP)，SPEC §3 去_efuse
 *           runner。端口：套件号段 8310(guest 服务口)/8311(外发对端口)。
 */

#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"

#include "esp_eth.h"
#include "esp_event.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "esp_heap_caps.h"

#include "lwip/inet.h"
#include "lwip/opt.h"
#include "lwip/sockets.h"
#include "lwip/stats.h"
#include "lwip/tcp.h"
#include "lwip/tcpip.h"

static const char *TAG = "ex14";

/* --------------------------- 目标与口径常量 ---------------------------- */

#define HOST_IP "10.0.2.2" /* SLIRP 网关 == 宿主机 loopback            */
#define RX_PORT 8310       /* SPEC §4 ex14 号段：guest 监听(hostfwd 入向) */
#define TX_PORT 8311       /* SPEC §4 ex14 号段：guest 外连宿主 sink 口   */
#define TX_ECHO_PORT 8312 /* 宿主反射器口(tools/gym_echo.py)：LB 腿与探针的外部对端 */

#define TILE_LEN  (64u * 1024u) /* 确定性图样周期（ex11 同款 xorshift32）*/
#define PAT_SEED  0x11c0ffeeu
#define TX_CHUNK  (8u * 1024u)  /* LB 腿单次发送切片上限                  */
#define RX_BUF_SZ (16u * 1024u)

#define SEND_TIMEOUT_SEC 10 /* 所有 socket 的 SO_SNDTIMEO/SO_RCVTIMEO 兜底 */
#define RECV_TIMEOUT_SEC 15
#define LB_DEADLINE_MS   30000 /* 单轮自环硬预算                          */
#define CONN_ATTEMPT_MS  3000  /* sc4 探针每次连接的超时预算               */
#define TRICKLE_MIN_SEC  12    /* 早停规则：满此时长才开始判涓流           */
#define TRICKLE_BPS      20000 /* 涓流判定阈值（字节/秒）                  */

#define SCN CONFIG_GYM_SCENARIO

/* 行为层 profile 开关：谁在三腿上跑数据、谁切探针（编译期常量折叠） */
#define HAS_PROBE (SCN == 4)
#define HAS_LEGS (!HAS_PROBE)

#define BYTES_ONE_ROUND ((uint32_t)CONFIG_GYM_MB * 1000000u)
#define ROUNDS          CONFIG_GYM_ROUNDS

/* ------------------------------ 输出辅助 ------------------------------- */

/* 带冲刷的输出：$$$ 机器可读行必须完整落在串口里 */
static void out(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    fflush(stdout);
}

static const char *scenario_name(int n)
{
    switch (n) {
    case 0:
        return "baseline";
    case 1:
        return "tiny-window";
    case 2:
        return "wide-window-small-ring";
    case 3:
        return "missing-tcp_sent-hook";
    default:
        return "pcb-gate-2";
    }
}

static int64_t now_us(void)
{
    return esp_timer_get_time();
}

static long us_to_ms(int64_t us)
{
    return (long)((us + 500) / 1000);
}

static double mbit_of(uint64_t bytes, int64_t us)
{
    if (us <= 0) {
        return 0.0;
    }
    return (double)bytes * 8.0 / (double)us;
}

/* ---------------------- Fletcher-16 + 确定性图样 ------------------------
 * 两端逐位一致（ex11 同款）：guest C 版 / 宿主 python 版同一递推式。
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

static uint8_t s_tile[TILE_LEN];    /* 发送图样环形缓冲 */
static uint8_t s_rxbuf[RX_BUF_SZ];  /* 接收搬运缓冲 */

/* --------------------- 观测原语：lwip_stats 快照 -----------------------
 * lwip_stats 属于 tcpip_thread；快照统一经 tcpip_callback() 投递进协议栈线程
 * 拷贝（同步完成，带信号量握手），五段计数一次取齐保证同帧同时刻
 * （ex12/ex13 双验证手法）。只在两阶段间隙调用，不在传输中途采样。
 */
struct net_snap {
    u32_t link_recv, link_xmit, link_drop;
    u32_t ip_recv, ip_drop;
    u32_t tcp_recv, tcp_xmit, tcp_drop, tcp_chkerr, tcp_memerr;
};

static SemaphoreHandle_t s_snap_sem;

static void snap_cb(void *ctx)
{
    struct net_snap *s = (struct net_snap *)ctx;
    memset(s, 0, sizeof(*s));
#if LWIP_STATS
    s->link_recv = lwip_stats.link.recv;
    s->link_xmit = lwip_stats.link.xmit;
    s->link_drop = lwip_stats.link.drop;
    s->ip_recv = lwip_stats.ip.recv;
    s->ip_drop = lwip_stats.ip.drop;
    s->tcp_recv = lwip_stats.tcp.recv;
    s->tcp_xmit = lwip_stats.tcp.xmit;
    s->tcp_drop = lwip_stats.tcp.drop;
    s->tcp_chkerr = lwip_stats.tcp.chkerr;
    s->tcp_memerr = lwip_stats.tcp.memerr;
#else
    (void)s;
#endif
    xSemaphoreGive(s_snap_sem);
}

static bool snap_take(struct net_snap *out)
{
    memset(out, 0, sizeof(*out));
    if (tcpip_callback(snap_cb, out) != ERR_OK) {
        return false;
    }
    if (xSemaphoreTake(s_snap_sem, pdMS_TO_TICKS(2000)) != pdTRUE) {
        return false;
    }
    return true;
}

/* 打一帧相对 prev 的差值行；prev==NULL 时打绝对值基线行 */
static void snap_print(const char *phase, const struct net_snap *prev,
                       const struct net_snap *cur)
{
    if (cur == NULL) {
        out("$$$ EX14STATS phase=%s ERROR reason=snapshot-failed\n", phase);
        return;
    }
    if (prev == NULL) {
        out("$$$ EX14STATS phase=%s link.recv=%lu tcp.memerr=%lu tcp.drop=%lu "
            "tcp.chkerr=%lu (absolute)\n",
            phase, (unsigned long)cur->link_recv, (unsigned long)cur->tcp_memerr,
            (unsigned long)cur->tcp_drop, (unsigned long)cur->tcp_chkerr);
        return;
    }
    out("$$$ EX14STATS phase=%s d_link.recv=%lu d_tcp.xmit=%lu d_tcp.recv=%lu "
        "d_tcp.drop=%lu d_tcp.memerr=%lu\n",
        phase, (unsigned long)(cur->link_recv - prev->link_recv),
        (unsigned long)(cur->tcp_xmit - prev->tcp_xmit),
        (unsigned long)(cur->tcp_recv - prev->tcp_recv),
        (unsigned long)(cur->tcp_drop - prev->tcp_drop),
        (unsigned long)(cur->tcp_memerr - prev->tcp_memerr));
}

static void heap_line(const char *phase)
{
    out("$$$ EX14HEAP phase=%s free=%u largest=%u min_ever=%u\n", phase,
        (unsigned)heap_caps_get_free_size(MALLOC_CAP_8BIT),
        (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_8BIT),
        (unsigned)heap_caps_get_minimum_free_size(MALLOC_CAP_8BIT));
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
        ESP_LOGI(TAG, "[EX14] ETH START");
        break;
    case ETHERNET_EVENT_CONNECTED:
        ESP_LOGI(TAG, "[EX14] ETH CONNECTED (link up)");
        break;
    case ETHERNET_EVENT_DISCONNECTED:
        ESP_LOGW(TAG, "[EX14] ETH DISCONNECTED");
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
    ESP_LOGI(TAG, "[EX14] GOT_IP " IPSTR " gw " IPSTR, IP2STR(&evt->ip_info.ip),
             IP2STR(&evt->ip_info.gw));
    xSemaphoreGive(s_got_ip);
}

#ifdef CONFIG_ETH_OPENETH_DMA_RX_BUFFER_NUM
#define OPENETH_RING CONFIG_ETH_OPENETH_DMA_RX_BUFFER_NUM
#else
#define OPENETH_RING (-1)
#endif

/* ---------------------------- 配置自报与体检 ----------------------------
 * 开机打印编译进镜像的真实配置指纹并做四项确定性体检（CH24/Batch 5 结论的
 * 直接代码化）：症状没发生前先把"注定会发生什么"钉在日志里。
 */
static void fact_and_verdicts(void)
{
    out("$$$ EX14FACT build=\"" __DATE__ " " __TIME__ "\" scenario=%d name=%s "
        "mss=%d snd_buf=%d wnd=%d openeth_ring=%d max_active_tcp=%d "
        "lwip_stats=%d\n",
        SCN, scenario_name(SCN), (int)TCP_MSS, (int)TCP_SND_BUF, (int)TCP_WND,
        OPENETH_RING, CONFIG_LWIP_MAX_ACTIVE_TCP, (int)LWIP_STATS);

    out("$$$ EX14PROFILE legs=%s probe=%s rounds=%d mb_per_leg=%u "
        "tx_target=%s:%d rx_listen=:%d lb_mirror=%s:%d\n",
        HAS_LEGS ? "lb+tx+rx" : "none(concurrency-probe-profile)",
        HAS_PROBE ? "on" : "off", ROUNDS, BYTES_ONE_ROUND, HOST_IP, TX_PORT,
        RX_PORT, HOST_IP, TX_ECHO_PORT);

    /* 体检 1：窗口过小（<=2*MSS 即写入路径必塌缩） */
    bool tiny = ((int)TCP_SND_BUF <= 2 * (int)TCP_MSS || (int)TCP_WND <= 2 * (int)TCP_MSS);
    out("$$$ EX14VERDICT key=window_small %s snd_buf=%d wnd=%d mss=%d "
        "detail=external-path-rate~window/RTT(ch24)\n",
        tiny ? "predicted_broken" : "ok", (int)TCP_SND_BUF, (int)TCP_WND,
        (int)TCP_MSS);

    /* 体检 2：窗口×RX 环深不等式（ch24/Batch5：>=11520 需环>=16，>=28800 需>=32） */
    if (OPENETH_RING > 0 && (int)TCP_WND >= 28800 && OPENETH_RING < 32) {
        out("$$$ EX14VERDICT key=wnd_ring predicted_blackhole wnd=%d ring=%d "
            "need_ring=32 detail=WND>=28800-requires-ring>=32(ch24/Batch5)\n",
            (int)TCP_WND, OPENETH_RING);
    } else if (OPENETH_RING > 0 && (int)TCP_WND >= 11520 && OPENETH_RING < 16) {
        out("$$$ EX14VERDICT key=wnd_ring predicted_blackhole wnd=%d ring=%d "
            "need_ring=16 detail=WND>=11520-requires-ring>=16(ch24/Batch5)\n",
            (int)TCP_WND, OPENETH_RING);
    } else {
        out("$$$ EX14VERDICT key=wnd_ring ok wnd=%d ring=%d\n", (int)TCP_WND,
            OPENETH_RING);
    }

    /* 体检 3：PCB 计数闸算术（listen+client+child 最少 3 格，Batch2） */
    if (CONFIG_LWIP_MAX_ACTIVE_TCP > 0 && CONFIG_LWIP_MAX_ACTIVE_TCP < 4) {
        out("$$$ EX14VERDICT key=pcb_gate predicted_broken max_active_tcp=%d "
            "detail=list+client+child-minimum-is-3-pcbs(Batch2)\n",
            CONFIG_LWIP_MAX_ACTIVE_TCP);
    } else {
        out("$$$ EX14VERDICT key=pcb_gate ok max_active_tcp=%d\n",
            CONFIG_LWIP_MAX_ACTIVE_TCP);
    }

    /* 体检 4：tcp_sent 挂钩状态（sc3 的条件编译开关） */
#if SCN == 3
    out("$$$ EX14VERDICT key=sent_hook omitted detail=ch6-trickle-bug-armed\n");
#else
    out("$$$ EX14VERDICT key=sent_hook present detail=ack-driven-refill-on\n");
#endif
}

/* ------------- “自环”腿说明（设计裁决，完整证据链见 README） -------------
 * 早期实现为 guest 内 127.0.0.1 回声服务器。实测（gdb 现场取证，两次独立样本）
 * 本环境 QEMU 下任何「目的地=自身IP」的 TCP 流量都会被 ip4_route 送进
 * lwIP 内建回环队列（netif_loop_output / loop_netif），该路径在持续吞吐下
 * 会把 tcpip 线程咬死在 pbuf_free / 保护互斥量里——与业务代码无关的环境级缺陷，
 * 与《深度解析》ch22 悬案② 同族。健身房改为「经 SLIRP 的镜像回声」：
 * 客户端全双工引擎不变，但对端换成宿主机 tools/gym_echo.py 反射器，
 * 全部流量走实测稳定的外部路径（openeth + SLIRP），协议栈旋钮的教学价值不变。
 *
 * 也因此：sc4 的入向“静默丢 SYN”证据改由 EX14RX 监听口与探针配合产生，
 * 见 conc_probe()。
 */

/* ------------------------- LB 腿客户端（自环轮次） ---------------------- */

typedef struct {
    int status; /* 0=OK 1=FAIL */
    long conn_ms, up_ms, dn_ms;
    double up_mbit, dn_mbit;
    unsigned up_digest, dn_digest;
    int digest_match;
    int err_no;
    char note[64];
} lb_result_t;


static int send_all(int fd, const uint8_t *buf, size_t len)
{
    size_t off = 0;
    while (off < len) {
        ssize_t w = send(fd, buf + off, len - off, 0);
        if (w > 0) {
            off += (size_t)w;
        } else if (w < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            vTaskDelay(pdMS_TO_TICKS(1));
        } else {
            return -1;
        }
    }
    return 0;
}

static void lb_sock_timeouts(int fd)
{
    struct timeval tv = { .tv_sec = RECV_TIMEOUT_SEC, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    tv.tv_sec = SEND_TIMEOUT_SEC;
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
}

static void lb_round(int r, lb_result_t *res)
{
    memset(res, 0, sizeof(*res));
    const int64_t t0 = now_us();
    /* LB 腿采样量封顶：回环链路每次协议步进受定时器节拍支配（实测见 README），
     * 绝对速率不代表外环能力——它的职责是「端到端正确性健康检查」，
     * 小样本足够；大流量吞吐交给 TX/RX 外环两腿按窗口口径说话。 */
    const uint32_t lb_target =
        BYTES_ONE_ROUND < 262144u ? BYTES_ONE_ROUND : 262144u;
    uint64_t sent = 0, recvd = 0; /* 提升到 goto 标签可见处（可复现的部分进度记账） */
    bool fresh_conn = false;
    int fd = -1;

    /* 每轮新建连接；对端是宿主反射器（为何不走 127.0.0.1，见文件头裁决） */
    fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (fd < 0) {
        res->status = 1;
        res->err_no = errno;
        snprintf(res->note, sizeof(res->note), "socket");
        goto out_row;
    }
    lb_sock_timeouts(fd);
    struct sockaddr_in la = {
        .sin_family = AF_INET,
        .sin_port = htons(TX_ECHO_PORT),
        .sin_addr.s_addr = inet_addr(HOST_IP),
    };
    if (connect(fd, (struct sockaddr *)&la, sizeof(la)) != 0) {
        res->status = 1;
        res->err_no = errno;
        snprintf(res->note, sizeof(res->note), "connect");
        close(fd);
        goto out_row;
    }
    fresh_conn = true;
    res->conn_ms = us_to_ms(now_us() - t0);

    /* 全双工泵：非阻塞 + select 同时盯读写两侧，防止
     * 「send 满 → 对端 echo 也满 → 相互等」的经典死锁形态。 */
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) {
        fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    }

    struct fletcher fu, fdn;
    fl_init(&fu);
    fl_init(&fdn);
    int64_t t_up0 = 0, t_dn0 = 0, t_up_end = 0, t_dn_end = 0;
    uint32_t pat_off = 0;
    bool up_done = false, dn_done = false, failed = false;
    const int64_t deadline = now_us() + LB_DEADLINE_MS * 1000LL;

    while (!(up_done && dn_done)) {
        if (now_us() >= deadline) {
            failed = true;
            snprintf(res->note, sizeof(res->note),
                     "deadline(up=%" PRIu64 "/%" PRIu32 " dn=%" PRIu64 ")", sent,
                     lb_target, recvd);
            break;
        }
        fd_set rfds, wfds;
        FD_ZERO(&rfds);
        FD_ZERO(&wfds);
        if (!dn_done) {
            FD_SET(fd, &rfds);
        }
        if (!up_done) {
            FD_SET(fd, &wfds);
        }
        struct timeval slice = { .tv_sec = 0, .tv_usec = 250000 };
        int rc = select(fd + 1, &rfds, &wfds, NULL, &slice);
        if (rc < 0) {
            failed = true;
            res->err_no = errno;
            snprintf(res->note, sizeof(res->note), "select");
            break;
        }
        if (FD_ISSET(fd, &wfds)) {
            if (t_up0 == 0) {
                t_up0 = now_us();
            }
            size_t want = TX_CHUNK;
            if ((size_t)(TILE_LEN - pat_off) < want) {
                want = TILE_LEN - pat_off;
            }
            if ((uint64_t)(lb_target - sent) < want) {
                want = (size_t)(BYTES_ONE_ROUND - sent);
            }
            ssize_t w = send(fd, s_tile + pat_off, want, 0);
            if (w > 0) {
                fl_update(&fu, s_tile + pat_off, (size_t)w);
                pat_off = (pat_off + (uint32_t)w) % TILE_LEN;
                sent += (uint64_t)w;
                if (sent >= lb_target) {
                    up_done = true;
                    t_up_end = now_us();
                }
            } else if (w < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
                failed = true;
                res->err_no = errno;
                snprintf(res->note, sizeof(res->note), "send");
                break;
            }
        }
        if (FD_ISSET(fd, &rfds)) {
            if (t_dn0 == 0) {
                t_dn0 = now_us();
            }
            ssize_t n = recv(fd, s_rxbuf, sizeof(s_rxbuf), 0);
            if (n > 0) {
                fl_update(&fdn, s_rxbuf, (size_t)n);
                recvd += (uint64_t)n;
                if (recvd >= lb_target) {
                    dn_done = true;
                    t_dn_end = now_us();
                    continue;
                }
                /* 一次唤醒尽量排空：后续数据不等下一轮 select（有的读） */
                for (;;) {
                    n = recv(fd, s_rxbuf, sizeof(s_rxbuf), 0);
                    if (n > 0) {
                        fl_update(&fdn, s_rxbuf, (size_t)n);
                        recvd += (uint64_t)n;
                        if (recvd >= lb_target) {
                            dn_done = true;
                            t_dn_end = now_us();
                            break;
                        }
                    } else if (n == 0) {
                        failed = true;
                        snprintf(res->note, sizeof(res->note),
                                 "peer-EOF(dn=%" PRIu64 ")", recvd);
                        break;
                    } else {
                        break; /* EAGAIN：这批排完了 */
                    }
                }
                if (failed || dn_done) {
                    break;
                }
            } else if (n == 0) {
                failed = true;
                snprintf(res->note, sizeof(res->note), "peer-EOF(dn=%" PRIu64 ")", recvd);
                break;
            } else if (errno != EAGAIN && errno != EWOULDBLOCK) {
                failed = true;
                res->err_no = errno;
                snprintf(res->note, sizeof(res->note), "recv");
                break;
            }
        }
    }

    close(fd); /* 每轮连接用毕即收（新鲜轮次语义） */
    (void)fresh_conn;
    res->status = (!failed && up_done && dn_done &&
                   fl_digest(&fu) == fl_digest(&fdn)) ? 0 : 1;
    res->up_ms = us_to_ms((t_up_end ? t_up_end : now_us()) - t_up0);
    res->dn_ms = us_to_ms((t_dn_end ? t_dn_end : now_us()) - (t_dn0 ? t_dn0 : t_up0));
    res->up_mbit = mbit_of(sent, res->up_ms * 1000L);
    res->dn_mbit = mbit_of(recvd, res->dn_ms * 1000L);
    res->up_digest = fl_digest(&fu);
    res->dn_digest = fl_digest(&fdn);
    res->digest_match = (res->up_digest == res->dn_digest);

out_row:
    if (res->status == 0) {
        out("$$$ EX14LB r=%d RESULT status=OK conn_ms=%ld up_mbit=%.2f dn_mbit=%.2f "
            "up_ms=%ld dn_ms=%ld up_digest=%04x dn_digest=%04x match=1\n",
            r, res->conn_ms, res->up_mbit, res->dn_mbit, res->up_ms, res->dn_ms,
            res->up_digest, res->dn_digest);
    } else {
        out("$$$ EX14LB r=%d RESULT status=FAIL conn_ms=%ld sent=%" PRIu64
            " recvd=%" PRIu64 " err=%d(%s) note=%s\n",
            r, res->conn_ms, sent, recvd, res->err_no,
            strerror(res->err_no ? res->err_no : EIO), res->note);
    }
}

/* ------------------- TX 腿：raw API 发送泵（场景 3 载体） -----------------
 * 结构性说明（读代码比读文档准）：
 * - 整个泵是一个小状态机，所有 tcp_* 操作都发生在 tcpip_thread 内——要么直接在
 *   回调里，要么经 tcpip_callback() 投递的步进函数（ch15 纪律，绝无裸调）。
 * - 数据补充路径有两条：(a) sent_cb —— 收到 ACK 立刻补发（健康模式的主通路）；
 *   (b) poll_cb —— tcp_poll 兜底节拍（几百 ms 级慢车道，两条路都在也是 lwIP 惯用法）。
 * - 场景 3 的毒药是唯一的条件编译块：#if SCN!=3 才注册 tcp_sent。
 *   于是应用层的补发只能靠慢车道涓流——这就是 ch6 真 bug 的最小复刻。
 * - 电机端（gym_task）只递步进函数和读易失统计字，跨线程零共享写。
 */
enum pump_stage {
    PS_IDLE,
    PS_CONNECTING,
    PS_RUNNING,
    PS_CLOSING,
    PS_CLOSED_TAIL,
    PS_DONE_OK,
    PS_DONE_ERR,
    PS_ABORTED,
};

/* 驱动侧参数包：驱动只写这个独立结构，经 tcpip_callback 移交，
 * 工作上下文 s_pump 的全部写操作从此只发生在 tcpip 线程域内。 */
struct pump_req {
    ip_addr_t dst;
    uint16_t dst_port;
    uint32_t target;
};

typedef struct {
    volatile enum pump_stage stage;
    volatile int err;
    volatile bool eof_seen, k_seen;
    struct tcp_pcb *pcb;
    ip_addr_t dst;
    uint16_t dst_port;
    uint32_t target;

    volatile uint32_t written;    /* 被 tcp_write 接受的字节数          */
    volatile uint32_t acked_app;  /* 应用可见的 ACK 字节数（sent_cb 口径）*/
    volatile uint32_t sent_hits;  /* sent_cb 调用次数                    */
    volatile uint32_t poll_hits;  /* poll_cb 调用次数                    */
    volatile u16_t min_sndbuf;    /* 观测到的 tcp_sndbuf 水位下沿        */

    int64_t t_conn_req, t_established, t_first_write, t_last_write;
    struct fletcher fl; /* 仅在 tcpip_thread 内推进 */
} txpump_t;

static txpump_t s_pump; /* 必须静态：pcb 在关闭后仍短暂存活引用本结构 */
static struct pump_req s_pump_req; /* 驱动 -> tcpip 的参数移交区 */

static void disarm(txpump_t *p);

static err_t pump_sent_cb(void *arg, struct tcp_pcb *tpcb, u16_t len);
static err_t pump_recv_cb(void *arg, struct tcp_pcb *tpcb, struct pbuf *p, err_t err);
static err_t pump_poll_cb(void *arg, struct tcp_pcb *tpcb);

static void pump_fill(txpump_t *p)
{
    if (p->pcb == NULL) {
        return;
    }
    u16_t avail = tcp_sndbuf(p->pcb);
    if (avail < p->min_sndbuf) {
        p->min_sndbuf = avail; /* 水位观测：健康泵会在住回弹中刷出下沿 */
    }
    while ((avail = tcp_sndbuf(p->pcb)) > 0 && p->written < p->target) {
        size_t want = (size_t)avail;
        if ((size_t)(TILE_LEN - (p->written % TILE_LEN)) < want) {
            want = TILE_LEN - (p->written % TILE_LEN);
        }
        if ((size_t)(p->target - p->written) < want) {
            want = (size_t)(p->target - p->written);
        }
        if (want > 0xFFFF) {
            want = 0xFFFF; /* tcp_write 单发上限 u16 */
        }
        err_t e = tcp_write(p->pcb, s_tile + (p->written % TILE_LEN),
                            (u16_t)want, TCP_WRITE_FLAG_COPY);
        if (e != ERR_OK) {
            break; /* 缓冲暂满/暂时无 pbuf：等回调再来 */
        }
        if (p->t_first_write == 0) {
            p->t_first_write = now_us();
        }
        fl_update(&p->fl, s_tile + (p->written % TILE_LEN), want);
        p->written += (uint32_t)want;
        p->t_last_write = now_us();
    }
    tcp_output(p->pcb);

    if (p->written >= p->target && p->stage == PS_RUNNING) {
        p->stage = PS_CLOSING;
        if (tcp_close(p->pcb) == ERR_OK) {
            p->stage = PS_CLOSED_TAIL;
            disarm(p); /* 关键：close 后立即解除全部回调武装 */
        }
    }
}

/* close 之后 pcb 归栈所有（TIME_WAIT 直至回收）；此时仍注册着的 sent/poll 等
 * 回调与后续新连接的 pcb 分配在同一 tcpip 线程交错服务——实测存在低概率
 * 系统级停摆（见 README 排障节）。因此一旦进入终态立即把回调全部摘掉。 */
static void disarm(txpump_t *p)
{
    struct tcp_pcb *pcb = p->pcb;
    if (pcb == NULL) {
        return;
    }
    tcp_arg(pcb, NULL);
    tcp_err(pcb, NULL);
    tcp_recv(pcb, NULL);
    tcp_poll(pcb, NULL, 0);
}

static err_t pump_connected(void *arg, struct tcp_pcb *tpcb, err_t err)
{
    txpump_t *p = (txpump_t *)arg;
    if (err != ERR_OK || tpcb == NULL) {
        p->err = err;
        p->stage = PS_DONE_ERR;
        return ERR_OK;
    }
    p->t_established = now_us();
    p->stage = PS_RUNNING;
#if SCN != 3
    /* 健康模式的补发主通路：ACK 一到就继续灌（ch6 手法）。
     * 场景 3 构建时整个注册行被剔除——这就是那颗代码级毒药。 */
    tcp_sent(tpcb, pump_sent_cb);
#endif
    tcp_recv(tpcb, pump_recv_cb); /* 观察 sink 的 'K'/EOF 尾巴 */
    tcp_poll(tpcb, pump_poll_cb, 1); /* 兜底慢车道（两种模式都有） */
    pump_fill(p);
    return ERR_OK;
}

static err_t pump_sent_cb(void *arg, struct tcp_pcb *tpcb, u16_t len)
{
    (void)tpcb;
    txpump_t *p = (txpump_t *)arg;
    if (arg == NULL || tpcb == NULL) {
        return ERR_OK;
    }
    /* 纪律（本仓实录教训）：回调运行于 tcpip 线程，printf 会把 UART 背压
     * 变成整个协议栈的节拍地狱——回调里只许动计数器，禁止碰控制台。 */
    p->sent_hits++;
    p->acked_app += len; /* 应用可见的 ACK 流水账——sc3 里恒冻结 */
    if (p->stage == PS_RUNNING || p->stage == PS_CLOSING) {
        pump_fill(p);
    }
    return ERR_OK;
}

static err_t pump_poll_cb(void *arg, struct tcp_pcb *tpcb)
{
    (void)tpcb;
    txpump_t *p = (txpump_t *)arg;
    p->poll_hits++;
    if (p->stage == PS_RUNNING) {
        pump_fill(p);
    } else if (p->stage == PS_CLOSING && p->pcb != NULL) {
        if (tcp_close(p->pcb) == ERR_OK) {
            p->stage = PS_CLOSED_TAIL;
            disarm(p);
        }
    }
    return ERR_OK;
}

static err_t pump_recv_cb(void *arg, struct tcp_pcb *tpcb, struct pbuf *p, err_t err)
{
    (void)tpcb;
    (void)err;
    txpump_t *pp = (txpump_t *)arg;
    if (p == NULL) {
        pp->eof_seen = true; /* 对端关了写侧 */
        return ERR_OK;
    }
    /* 只关心有没有 'K'（sink 的完成应答位），逐字节扫一遍小尾巴 */
    for (struct pbuf *q = p; q != NULL; q = q->next) {
        const uint8_t *d = (const uint8_t *)q->payload;
        for (u16_t i = 0; i < q->len; i++) {
            if (d[i] == 'K') {
                pp->k_seen = true;
            }
        }
    }
    pbuf_free(p);
    return ERR_OK;
}

static void pump_err_cb(void *arg, err_t err)
{
    txpump_t *p = (txpump_t *)arg;
    p->err = err;    /* 记录原始 err（数字进 RESULT 行），但不一定算故障 */
    p->pcb = NULL;   /* err_cb 之后 pcb 已被栈回收，不能再碰 */
    switch (p->stage) {
    case PS_CLOSED_TAIL:
        /* 我们主动 close 之后到来的拆卸噪音（实测常见 ERR_CLSD=-13：
         * sink 回的 'K'/FIN 落在已关闭的 pcb 上）——不算传输故障 */
        p->stage = PS_DONE_OK;
        break;
    case PS_ABORTED: /* 截断早停/超时打断：保留 ABORTED 语义 */
    case PS_DONE_OK:
        break;
    default:         /* 传输中途 RST/无路由等：真故障 */
        p->stage = PS_DONE_ERR;
        break;
    }
}

/* ---- 步进函数（tcpip_callback 投递，运行于 tcpip_thread 内） ---- */

static void pump_step_start(void *ctx)
{
    /* 初始化整体移入 tcpip 域：驱动先填好 s_pump_req 再投递本函数；
     * 此前"任务侧 memset 工作结构"与上一轮尾巴上仍在飞的回调存在
     * 数据竞争（曾以 LoadProhibited 形式翻车），此修复按构造消除竞争。 */
    txpump_t *p = (txpump_t *)ctx;
    struct pump_req *req = &s_pump_req;
    memset((void *)p, 0, sizeof(*p));
    p->dst = req->dst;
    p->dst_port = req->dst_port;
    p->target = req->target;
    p->min_sndbuf = 0xFFFF;
    p->stage = PS_IDLE;
    p->t_conn_req = now_us();

    struct tcp_pcb *pcb = tcp_new_ip_type(IPADDR_TYPE_V4);
    if (pcb == NULL) {
        p->err = ERR_MEM;
        p->stage = PS_DONE_ERR; /* pcb 池满时第一现场就在这里（sc4 相关） */
        return;
    }
    tcp_arg(pcb, p);
    tcp_err(pcb, pump_err_cb);
    p->pcb = pcb; /* 关键：后续 fill/poll/abort 都通过 ctx 引用这块 pcb */
    err_t e = tcp_connect(pcb, &p->dst, p->dst_port, pump_connected);
    if (e != ERR_OK) {
        p->err = e;
        p->stage = PS_DONE_ERR;
        tcp_arg(pcb, NULL);
        tcp_err(pcb, NULL);
        tcp_abort(pcb);
        return;
    }
    p->stage = PS_CONNECTING;
}

static void pump_step_advance(void *ctx)
{
    txpump_t *p = (txpump_t *)ctx;
    if (p->stage == PS_RUNNING) {
        pump_fill(p);
    } else if (p->stage == PS_CLOSING && p->pcb) {
        if (tcp_close(p->pcb) == ERR_OK) {
            p->stage = PS_CLOSED_TAIL;
            disarm(p);
        }
    }
}

static void pump_step_abort(void *ctx)
{
    txpump_t *p = (txpump_t *)ctx;
    if (p->pcb != NULL) {
        tcp_abort(p->pcb); /* 截断早停/超时中断；pcb 由栈立即回收 */
        p->pcb = NULL;
    }
    p->stage = PS_ABORTED;
}

static const char *pump_stage_name(enum pump_stage s)
{
    switch (s) {
    case PS_CONNECTING:
        return "connecting";
    case PS_RUNNING:
        return "running";
    case PS_CLOSING:
        return "closing";
    case PS_CLOSED_TAIL:
        return "closed_tail";
    case PS_DONE_OK:
        return "done_ok";
    case PS_DONE_ERR:
        return "done_err";
    case PS_ABORTED:
        return "aborted";
    default:
        return "idle";
    }
}

typedef struct {
    int status; /* 0=COMPLETE 1=TRICKLE_STOP 2=DEADLINE 3=CONN_FAIL 4=RST */
    uint64_t bytes;
    long xfer_ms;
    double mbit;
    uint32_t sent_hits, poll_hits, acked_app, written;
    u16_t min_sndbuf;
    int err_no;
    int k_seen;
} tx_result_t;

static void tx_round(int r, uint32_t round_bytes, tx_result_t *res)
{
    memset(res, 0, sizeof(*res));
    memset((void *)&s_pump, 0, sizeof(s_pump));

    /* 只准备参数包；工作上下文的清零与装配交给 tcpip 域内的 step_start */
    ipaddr_aton(HOST_IP, &s_pump_req.dst);
    s_pump_req.dst_port = TX_PORT;
    s_pump_req.target = round_bytes;

    out("$$$ EX14TX r=%d BEGIN target=%s:%d bytes=%" PRIu32 "\n", r, HOST_IP,
        TX_PORT, round_bytes);

    if (tcpip_callback(pump_step_start, &s_pump) != ERR_OK) {
        res->status = 3;
        res->err_no = EIO;
        goto out;
    }

    const int64_t t0 = now_us();
    const int64_t budget_us = (int64_t)CONFIG_GYM_TX_DEADLINE_SEC * 1000000LL;
    const int64_t deadline = t0 + budget_us;
    uint32_t last_written = 0;
    int64_t t_rate_mark = t0;

    while (true) {
        vTaskDelay(pdMS_TO_TICKS(100));
        enum pump_stage st = s_pump.stage;
        if (st == PS_DONE_OK || st == PS_CLOSED_TAIL) {
            /* 回调已解除武装，'K' 观察位取消；只留极短尾窗让行 LOG 收尾 */
            int64_t tail_deadline = now_us() + 300000LL;
            while (!s_pump.k_seen && !s_pump.eof_seen && now_us() < tail_deadline) {
                vTaskDelay(pdMS_TO_TICKS(50));
            }
            res->k_seen = s_pump.k_seen;
            s_pump.stage = PS_DONE_OK;
            break;
        }
        if (st == PS_DONE_ERR) {
            /* 罕见竞态：target 恰好写满后才收 RST/CLSD——按数据完整性记账 */
            res->status = (s_pump.written >= round_bytes) ? 0 : 4;
            break;
        }
        if (now_us() >= deadline) {
            tcpip_callback(pump_step_abort, &s_pump);
            res->status = 2;
            break;
        }
        /* 涓流早停：慢车道节拍的特征值以下且已满观察窗 → 判 TRICKLE_STOP */
        const int64_t el = now_us() - t0;
        if (el >= TRICKLE_MIN_SEC * 1000000LL) {
            const int64_t dt = now_us() - t_rate_mark;
            const uint32_t dw = s_pump.written - last_written;
            const double bps = (double)dw * 1000000.0 / (double)dt;
            if (bps < TRICKLE_BPS) {
                out("$$$ EX14TX r=%d SNAP t_ms=%ld win_bps=%.0f written=%u/%u "
                    "sent_hits=%u poll_hits=%u -- slow-lane-only signature\n",
                    r, us_to_ms(el), bps, s_pump.written, round_bytes,
                    s_pump.sent_hits, s_pump.poll_hits);
                tcpip_callback(pump_step_abort, &s_pump);
                res->status = 1;
                break;
            }
        }
        if (now_us() - t_rate_mark >= 5000000LL) { /* 每 5s 打一行进度证据 */
            const int64_t dt = now_us() - t_rate_mark;
            const uint32_t dw = s_pump.written - last_written;
            last_written = s_pump.written;
            t_rate_mark = now_us();
            out("$$$ EX14TX r=%d SNAP t_ms=%ld written=%u/%u win_mbit=%.2f "
                "sent_hits=%u poll_hits=%u min_sndbuf=%u acked_app=%u\n",
                r, us_to_ms(el), s_pump.written, round_bytes,
                (double)dw * 8.0 / (double)dt, s_pump.sent_hits, s_pump.poll_hits,
                (unsigned)s_pump.min_sndbuf, s_pump.acked_app);
        }
        tcpip_callback(pump_step_advance, &s_pump); /* 幂等补步进 */
    }

    res->bytes = s_pump.written;
    res->xfer_ms = us_to_ms((s_pump.t_last_write ? s_pump.t_last_write : now_us()) -
                            (s_pump.t_first_write ? s_pump.t_first_write : t0));
    res->mbit = mbit_of(res->bytes, (int64_t)res->xfer_ms * 1000L);
    res->sent_hits = s_pump.sent_hits;
    res->poll_hits = s_pump.poll_hits;
    res->acked_app = s_pump.acked_app;
    res->written = s_pump.written;
    res->min_sndbuf = s_pump.min_sndbuf;
    res->err_no = s_pump.err;

out:
    static const char *const tx_status[] = {
        "COMPLETE", "TRICKLE_STOP", "DEADLINE", "CONN_FAIL", "RST",
    };
    unsigned dg = fl_digest(&s_pump.fl);
    out("$$$ EX14TX r=%d RESULT status=%s bytes=%u/%u xfer_ms=%ld mbit=%.3f "
        "sent_hits=%u poll_hits=%u acked_app=%u min_sndbuf=%u k=%d digest=%04x "
        "err=%d stage=%s\n",
        r, tx_status[res->status], res->written, round_bytes, res->xfer_ms,
        res->mbit, res->sent_hits, res->poll_hits, res->acked_app,
        (unsigned)res->min_sndbuf, res->k_seen, dg, res->err_no,
        pump_stage_name(s_pump.stage));
}

/* --------------------- RX 腿：hostfwd 入向灌流（ex11 同法） -------------- */

typedef struct {
    int status; /* 0=OK 1=PEER_DOWN 2=FAIL */
    uint64_t got;
    long wait_ms, xfer_ms;
    double mbit;
    unsigned digest;
    int err_no;
    char peer[18];
} rx_result_t;

static void sock_timeouts_rx(int fd)
{
    struct timeval tv = { .tv_sec = RECV_TIMEOUT_SEC, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    tv.tv_sec = SEND_TIMEOUT_SEC;
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
}

static int make_ext_listener(void)
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
    if (bind(ls, (struct sockaddr *)&la, sizeof(la)) != 0 || listen(ls, 4) != 0) {
        ESP_LOGE(TAG, "[EX14] ext bind/listen(:%d) errno=%d", RX_PORT, errno);
        close(ls);
        return -1;
    }
    out("$$$ EX14RX_LISTEN port=%d backlog=4 hint=needs-QEMU-hostfwd-tcp::8310-:8310\n",
        RX_PORT);
    return ls;
}

static void rx_round(int r, int lsock, rx_result_t *res)
{
    memset(res, 0, sizeof(*res));
    const int64_t t_wait0 = now_us();
    const int64_t deadline =
        t_wait0 + (int64_t)CONFIG_GYM_PEER_WAIT_SEC * 1000000LL;

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
                res->wait_ms = us_to_ms(now_us() - t_wait0);
                inet_ntoa_r(sa.sin_addr, res->peer, sizeof(res->peer));
                ESP_LOGI(TAG, "[EX14] RX r=%d CONN from=%s:%d (wait %ld ms)", r,
                         res->peer, (int)ntohs(sa.sin_port), res->wait_ms);
                /* 发令枪 'R'：SLIRP hostfwd 会先于 guest 监听放行宿主 connect
                 *（幻影连接，ex11 验证的手法），由 guest 亲自开闸保证测量窗口干净 */
                (void)!send(sock, "R", 1, 0);
                break;
            }
            res->err_no = errno;
        }
        if (now_us() >= deadline) {
            res->status = 1;
            out("$$$ EX14RX r=%d RESULT status=PEER_DOWN waited_s=%d\n", r,
                (int)CONFIG_GYM_PEER_WAIT_SEC);
            return;
        }
    }

    sock_timeouts_rx(sock);
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
                break;
            }
        } else if (n == 0) {
            break;
        } else if (errno == EAGAIN || errno == EWOULDBLOCK) {
            last_err = ETIMEDOUT;
            break;
        } else {
            last_err = errno;
            break;
        }
    }
    const int64_t tend = now_us();
    res->got = got;
    res->digest = fl_digest(&fl);
    res->xfer_ms = us_to_ms(tend - t0);
    res->mbit = mbit_of(got, tend - t0);

    (void)!send(sock, "K", 1, 0); /* 完成应答位 */
    shutdown(sock, SHUT_RDWR);
    close(sock);

    res->status = (got >= BYTES_ONE_ROUND) ? 0 : 2;
    out("$$$ EX14RX r=%d RESULT status=%s got=%" PRIu64 "/%" PRIu32 " wait_ms=%ld "
        "xfer_ms=%ld mbit=%.3f digest=%04x err=%d\n",
        r, res->status == 0 ? "OK" : "FAIL", got, BYTES_ONE_ROUND, res->wait_ms,
        res->xfer_ms, res->mbit, res->digest, last_err);
}

/* -------------------- sc4 并发探针：PCB 计数闸现场取证 -------------------
 * 算术先行：listen PCB(1) + 探针 socket PCB(1) = 2 格已满，
 * child PCB 分配必然失败 → tcp_listen_input 静默丢 SYN 且 memerr++
 * （源码：lwip/src/core/tcp_in.c，Batch 2 记录的现象）。
 * 修复档(max_active_tcp=16)则第一次尝试就该 SUCCESS 并带回声校验。
 */
typedef struct {
    int ok_n, drop_n, alloc_fail_n;
    int first_errno;
} conc_probe_t;

static void conc_probe(conc_probe_t *res, uint32_t *memerr_delta_out)
{
    struct net_snap pre;
    struct net_snap *pre_p = snap_take(&pre) ? &pre : NULL;
    if (pre_p == NULL) {
        snap_print("conc_pre", NULL, NULL);
    } else {
        heap_line("conc_pre");
    }

    memset(res, 0, sizeof(*res));
    int held[3] = { -1, -1, -1 };
    for (int i = 1; i <= 3; i++) {
        int64_t ta = now_us();
        int fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (fd < 0) {
            /* socket 创建就要从池里领 pcb——这里失败说明 creation 一线即被闸死 */
            res->alloc_fail_n++;
            if (!res->first_errno) {
                res->first_errno = errno;
            }
            out("$$$ EX14CONC attempt=%d op=socket_alloc result=FAIL errno=%d(%s) "
                "elapsed_ms=%ld\n",
                i, errno, strerror(errno), us_to_ms(now_us() - ta));
            continue;
        }
        struct sockaddr_in la = {
            .sin_family = AF_INET,
            .sin_port = htons(TX_ECHO_PORT),
            .sin_addr.s_addr = inet_addr(HOST_IP),
        };
        /* 非阻塞 connect + select 死线：静默丢 SYN 表现为到点 TIMEOUT 无 RST */
        int flags = fcntl(fd, F_GETFL, 0);
        if (flags >= 0) {
            fcntl(fd, F_SETFL, flags | O_NONBLOCK);
        }
        int rc = connect(fd, (struct sockaddr *)&la, sizeof(la));
        bool established = false;
        if (rc == 0) {
            established = true;
        } else if (errno == EINPROGRESS) {
            fd_set wfds;
            FD_ZERO(&wfds);
            FD_SET(fd, &wfds);
            struct timeval sl = { .tv_sec = CONN_ATTEMPT_MS / 1000,
                                  .tv_usec = (CONN_ATTEMPT_MS % 1000) * 1000 };
            rc = select(fd + 1, NULL, &wfds, NULL, &sl);
            if (rc > 0) {
                int soerr = 0;
                socklen_t slen = sizeof(soerr);
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &slen);
                if (soerr == 0) {
                    established = true;
                } else {
                    errno = soerr;
                }
            }
        }
        if (!established) {
            res->drop_n++;
            if (!res->first_errno) {
                res->first_errno = errno;
            }
            out("$$$ EX14CONC attempt=%d op=connect result=DROP_NO_RST "
                "until_ms=%d errno_now=%d(%s) -- silent-SYN-drop-signature\n",
                i, (int)CONN_ATTEMPT_MS, errno, strerror(errno));
            close(fd);
            continue;
        }
        /* 建链成功：恢复阻塞模式后再做微型回声校验（刚才是非阻塞 connect）*/
        res->ok_n++;
        int bflags = fcntl(fd, F_GETFL, 0);
        if (bflags >= 0) {
            fcntl(fd, F_SETFL, bflags & ~O_NONBLOCK);
        }
        const char msg[8] = "GYMPING";
        uint8_t back[16] = { 0 };
        struct timeval tv = { .tv_sec = 5, .tv_usec = 0 };
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        send_all(fd, (const uint8_t *)msg, 7);
        ssize_t bn = recv(fd, back, sizeof(back), 0);
        bool echoed = (bn >= 7 && memcmp(back, msg, 7) == 0);
        out("$$$ EX14CONC attempt=%d op=connect result=SUCCESS echo_check=%s "
            "-- holding-socket\n",
            i, echoed ? "PASS" : "FAIL");
        held[i - 1] = fd; /* 故意不关：制造「占住 PCB 槽位」的并发压力 */
    }

    /* 入向排水窗：宿主此刻向 127.0.0.1:8310 打入短连接，让满池状态下的
     * tcp_listen_input 静默丢 SYN 并推高 tcp.memerr（证据在 diff 快照里） */
    out("$$$ EX14CONC PHASE=inbound-syn-drain window_s=6 "
        "expect=host-nc-to-8310\n");
    vTaskDelay(pdMS_TO_TICKS(6000));

    struct net_snap post;
    struct net_snap *post_p = snap_take(&post) ? &post : NULL;
    for (int i = 0; i < 3; i++) {
        if (held[i] >= 0) {
            shutdown(held[i], SHUT_RDWR);
            close(held[i]);
        }
    }
    if (pre_p != NULL && post_p != NULL) {
        snap_print("conc_post_diff", pre_p, post_p);
        if (memerr_delta_out) {
            *memerr_delta_out = (unsigned)(post.tcp_memerr - pre.tcp_memerr);
        }
    }
    heap_line("conc_post");
}

/* --------------------- 诊断看门狗（长驻轻量观察位） ---------------------- */

static void wd_task(void *arg)
{
    (void)arg;
    struct net_snap prev;
    bool have_prev = false;
    for (;;) {
        vTaskDelay(pdMS_TO_TICKS(5000));
        struct net_snap cur;
        bool ok = snap_take(&cur);
        out("$$$ EX14WD t_ms=%lld d_tcp.xmit=%lu d_tcp.recv=%lu d_link.recv=%lu "
            "%s\n",
            (long long)(now_us() / 1000),
            ok && have_prev ? (unsigned long)(cur.tcp_xmit - prev.tcp_xmit) : 0,
            ok && have_prev ? (unsigned long)(cur.tcp_recv - prev.tcp_recv) : 0,
            ok && have_prev ? (unsigned long)(cur.link_recv - prev.link_recv) : 0,
            ok ? "" : "SNAP_FAIL");
#if CONFIG_FREERTOS_USE_TRACE_FACILITY
        {
            UBaseType_t n = uxTaskGetNumberOfTasks();
            static TaskStatus_t st[24];
            uint32_t total_rt = 0;
            n = uxTaskGetSystemState(st, (n < 24) ? n : 24, &total_rt);
            /* 打出本窗口里 CPU 时间占比最高的 6 个任务 */
            for (UBaseType_t i = 1; i < n; i++) {
                for (UBaseType_t j = i; j > 0 && st[j].ulRunTimeCounter >
                                              st[j - 1].ulRunTimeCounter;
                     j--) {
                    TaskStatus_t tmp = st[j];
                    st[j] = st[j - 1];
                    st[j - 1] = tmp;
                }
            }
            UBaseType_t show = (n < 6) ? n : 6;
            printf("EX14WD-TASK");
            for (UBaseType_t i = 0; i < show; i++) {
                printf(" %s=%.1f%%(p%u)", st[i].pcTaskName,
                       total_rt ? 100.0f * st[i].ulRunTimeCounter / total_rt : 0.f,
                       (unsigned)st[i].uxCurrentPriority);
            }
            printf("\n");
            fflush(stdout);
        }
#endif
        if (ok) {
            prev = cur;
            have_prev = true;
        }
        fflush(stdout);
    }
}

/* ---------------------------- 编排器 ------------------------------------ */

static void bench_task(void *arg)
{
    (void)arg;
    fill_tile(s_tile);
    fact_and_verdicts();

    conc_probe_t conc = { 0 };
    uint32_t conc_memerr = 0;

    if (HAS_PROBE) {
        /* 探针场里 :8310 监听口保持开启：它就是 PCB 池的第 1 格占用者，
         * 入向 SYN 静默丢弃（memerr 爬升）的受害者——算术见 README 场景4 */
        int lsock = make_ext_listener();
        if (lsock < 0) {
            out("$$$ EX14RX_LISTEN FAIL errno=%d\n", errno);
        }
        out("$$$ EX14CONC PHASE=BEGIN profile=concurrency-probe note=legs-disabled\n");
        conc_probe(&conc, &conc_memerr);
        bool broken_pattern =
            ((conc.ok_n == 0 &&
              conc.drop_n + conc.alloc_fail_n >= 2 && conc_memerr > 0) ||
             (conc.ok_n >= 1 && conc.alloc_fail_n + conc.drop_n > 0));
        bool healthy_pattern =
            (conc.ok_n == 3) && (conc.alloc_fail_n + conc.drop_n == 0);
        out("$$$ EX14CONC SUMMARY attempts=3 ok=%d silent_drop=%d alloc_fail=%d "
            "memerr_delta=%lu verdict=%s\n",
            conc.ok_n, conc.drop_n, conc.alloc_fail_n,
            (unsigned long)conc_memerr,
            broken_pattern ? "starved" : (healthy_pattern ? "healthy" : "ambiguous"));
    }

    if (HAS_LEGS) {
        /* 外部工具在场的记录行：缺席按 PEER_DOWN 记账不算错（README 解释） */
        unsigned lb_ok = 0, tx_done = 0, rx_ok = 0, tx_trickle = 0;
        double lb_up_acc = 0, lb_dn_acc = 0, tx_acc = 0, rx_acc = 0;
        struct net_snap sbegin, sbetween, send_;
        bool have_begin = snap_take(&sbegin);
        if (have_begin) {
            snap_print("rounds_pre", NULL, &sbegin);
            heap_line("rounds_pre");
        }

        for (int r = 1; r <= ROUNDS; r++) {
            lb_result_t lr;
#ifdef EX14_DBG_DOUBLE_LB
            out("$$$ EX14ROUND r=%d leg=LB-a begin\n", r);
            lb_round(r * 100 + 1, &lr);
            out("$$$ EX14ROUND r=%d leg=LB-b begin\n", r);
            lb_round(r * 100 + 2, &lr);
#else
            out("$$$ EX14ROUND r=%d leg=LB begin\n", r);
            lb_round(r, &lr);
#endif
            if (lr.status == 0) {
                lb_ok++;
                lb_up_acc += lr.up_mbit;
                lb_dn_acc += lr.dn_mbit;
            }
            vTaskDelay(pdMS_TO_TICKS(300));

            tx_result_t tr;
            out("$$$ EX14ROUND r=%d leg=TX begin (needs tools/gym_sink.py on host:%d)\n",
                r, TX_PORT);
            tx_round(r, BYTES_ONE_ROUND, &tr);
            if (tr.status == 0) {
                tx_done++;
                tx_acc += tr.mbit;
            } else if (tr.status == 1) {
                tx_trickle++;
            }
            vTaskDelay(pdMS_TO_TICKS(300));

            if (r == 1) {
                /* RX 监听口整场懒建：首轮才出现，由 flood 工具的重试去对接 */
            }
            out("$$$ EX14ROUND r=%d leg=RX begin (needs tools/gym_flood.py -> hostfwd %d)\n",
                r, RX_PORT);
            int lsock = make_ext_listener();
            if (lsock < 0) {
                out("$$$ EX14RX r=%d RESULT status=LISTENER_FAIL errno=%d\n", r, errno);
            } else {
                rx_result_t rr;
                rx_round(r, lsock, &rr);
                close(lsock);
                if (rr.status == 0) {
                    rx_ok++;
                    rx_acc += rr.mbit;
                }
            }
            vTaskDelay(pdMS_TO_TICKS(300));

            if (r == 1 && snap_take(&sbetween)) {
                snap_print("after_round1", have_begin ? &sbegin : NULL, &sbetween);
            }
        }
        bool have_end = snap_take(&send_);
        if (have_end) {
            snap_print("rounds_post", have_begin ? &sbegin : NULL, &send_);
        }
        heap_line("rounds_post");

        out("$$$ EX14SUMMARY scenario=%d rounds=%d lb_ok=%u/%d avg_lb_up=%.2f "
            "avg_lb_dn=%.2f | tx_complete=%u trickle_or_partial=%u avg_tx_mbit=%.2f | "
            "rx_ok=%u/%d avg_rx_mbit=%.2f | conc=skipped hints=README-sc%d\n",
            SCN, ROUNDS, lb_ok, ROUNDS, lb_ok ? lb_up_acc / lb_ok : 0.0,
            lb_ok ? lb_dn_acc / lb_ok : 0.0, tx_done, tx_trickle,
            tx_done ? tx_acc / tx_done : 0.0, rx_ok, ROUNDS,
            rx_ok ? rx_acc / rx_ok : 0.0, SCN);
    }

    out("$$$ EX14DONE scenario=%d name=%s -- restarting to exit QEMU cleanly\n", SCN,
        scenario_name(SCN));
    vTaskDelay(pdMS_TO_TICKS(500)); /* 让 DONE 行冲出 UART */
    esp_restart();                  /* -no-reboot 下进程干净结束（ex06/ex11 先例） */
}

void app_main(void)
{
    ESP_LOGI(TAG, "== ex14 perf-gym-tcp: TCP misconfiguration gym ==");
    ESP_LOGI(TAG, "$$$ EX14BOOT board=esp32-qemu-openeth");

    /* 1. esp_netif_init 必须是第一句网络调用（tcpip 邮箱在此建立） */
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    s_got_ip = xSemaphoreCreateBinary();
    s_snap_sem = xSemaphoreCreateBinary();

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
        ESP_LOGE(TAG, "$$$ EX14FAIL reason=dhcp_timeout after 15000 ms");
        return;
    }
    esp_netif_ip_info_t info;
    ESP_ERROR_CHECK(esp_netif_get_ip_info(eth_netif, &info));
    out("$$$ EX14NETUP ip=" IPSTR " gw=" IPSTR "\n", IP2STR(&info.ip),
        IP2STR(&info.gw));

    /* 回声服务器先起：它是 LB 腿的服务端；sc4 里它还是 PCB 池的第一格占位者 */
    xTaskCreate(bench_task, "ex14_gym", 8192, NULL, 10, NULL);
    xTaskCreate(wd_task, "ex14_wd", 4096, NULL, 6, NULL);
}
