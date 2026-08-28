/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * lwIP 深度解析（十二）实验工程：TCP 可靠性：重传、滑动窗口、Nagle 与延迟 ACK
 *
 * 基于 ch3 联网模板（openeth + esp_netif + DHCP）。guest 作为 raw API 发送端：
 *
 *   实验 a（REXMIT，端口 8012）：
 *     在 netif->linkoutput 上包一层按概率丢帧的 wrapper（xorshift LCG，
 *     固定种子——每次运行丢同一批帧，实验可复现），丢 10% 的出站帧。
 *     50ms 周期采样 PCB 内部字段（cwnd/ssthresh/rto/nrtx/dupacks/snd_wnd，
 *     这些字段定义在公共头 lwip/tcp.h 中），nrtx/dupacks 变化时打事件行，
 *     观察 RTO 重传与指数退避序列；mib2.tcpretranssegs 前后对比。
 *
 *   实验 b（NAGLE，端口 8013）：
 *     同一固件内先后建立两个连接：先 Nagle 默认开（对照组），再
 *     tcp_nagle_disable()（TF_NODELAY，实验组）。每组 50 对消息，
 *     每对 = 连续两次 tcp_write(16B) 后一次 tcp_output()，对间隔 30ms。
 *     第二条消息在 Nagle 开启时必然被 tcp_do_output_nagle() 扣住，直到
 *     首条的 ACK 返回；sent 回调里用 esp_timer 打点释放时刻，直接量出
 *     "扣留时长 hold_us"。主机端 python 解析 16B 定长帧测到达间隔旁证。
 *
 *   实验 c（SWEEP，编译开关 CONFIG_CH12_SWEEP_ONLY=y）：
 *     只跑一条 8MB 传输到 8012，丢帧率 CONFIG_CH12_SWEEP_LOSS_PCT%，
 *     配合 sdkconfig 改 SND_BUF/WND 做 4 点窗口-吞吐扫描。
 *
 * 运行环境：ESP-IDF v6.0.2 + qemu-system-xtensa (Espressif fork)，
 *           -nic user,model=open_eth,hostfwd=tcp::8012-:8012,hostfwd=tcp::8013-:8013
 */

#include <stdio.h>
#include <inttypes.h>
#include <string.h>
#include <assert.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"

#include "esp_log.h"
#include "esp_timer.h"
#include "esp_event.h"
#include "esp_netif.h"
#include "esp_eth.h"

#include "lwip/tcp.h"
#include "lwip/netif.h"
#include "lwip/stats.h"
#include "lwip/priv/tcp_priv.h" /* TCP_FAST_INTERVAL / TCP_SLOW_INTERVAL */
#include "lwip/sys.h"    /* sys_timeout */
#include "lwip/tcpip.h"  /* tcpip_callback */
#include "esp_netif_net_stack.h" /* esp_netif_get_netif_impl */

static const char *TAG = "ch12lab";

#define DHCP_TIMEOUT_MS  10000

#define PORT_REXMIT     8012            /* hostfwd tcp::8012-:8012 */
#define PORT_NAGLE      8013            /* hostfwd tcp::8013-:8013 */

#ifdef CONFIG_CH12_SWEEP_ONLY
#define SWEEP_LOSS_PCT  CONFIG_CH12_SWEEP_LOSS_PCT
#define SWEEP_TOTAL     (2u * 1024u * 1024u)
#else
#define REXMIT_LOSS_PCT 10
#define REXMIT_TOTAL    (2u * 1024u * 1024u)
#define HEAVY_TOTAL     (768u * 1024u)
#endif

/* --------------------------- 构建/环境自报 --------------------------- */

static void print_build_facts(void)
{
    printf("CH12-FACT TCP_MSS=%d TCP_SND_BUF=%d TCP_WND=%d TCP_SND_QUEUELEN=%d\n",
           (int)TCP_MSS, (int)TCP_SND_BUF, (int)TCP_WND, (int)TCP_SND_QUEUELEN);
    printf("CH12-FACT LWIP_TCP_RTO_TIME=%d TCP_FAST_INTERVAL=%d TCP_SLOW_INTERVAL=%d"
           " TCP_MAXRTX=%d TCP_SYNMAXRTX=%d TCP_OOSEQ_TIMEOUT=%d\n",
           (int)LWIP_TCP_RTO_TIME, (int)TCP_FAST_INTERVAL, (int)TCP_SLOW_INTERVAL,
           (int)TCP_MAXRTX, (int)TCP_SYNMAXRTX, (int)TCP_OOSEQ_TIMEOUT);
}

/* ------------------------- 网络 bring-up ------------------------- */

static SemaphoreHandle_t s_got_ip;
static esp_netif_t *s_eth_netif;

static void ip_event_handler(void *arg, esp_event_base_t base,
                             int32_t event_id, void *event_data)
{
    ip_event_got_ip_t *evt = (ip_event_got_ip_t *)event_data;
    ESP_LOGI(TAG, "GOT_IP: " IPSTR, IP2STR(&evt->ip_info.ip));
    xSemaphoreGive(s_got_ip);
}

/* --------------------- 故障注入：TX 按概率丢帧 --------------------- */

static err_t (*s_orig_linkoutput)(struct netif *, struct pbuf *);
static uint32_t s_rng = 0x1234abcd;      /* 固定种子：每次运行丢同一批帧 */
static uint32_t s_drop_total;
static volatile int s_drop_enable = 0;
static volatile uint32_t s_drop_pct_now = 10;

static uint32_t rng_next(void)
{
    uint32_t x = s_rng;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    s_rng = x;
    return x;
}

static err_t dropping_linkoutput(struct netif *netif, struct pbuf *p)
{
    if (s_drop_enable && (int)(rng_next() % 100u) < (int)s_drop_pct_now) {
        s_drop_total++;
        printf("CH12-DROP t_ms=%" PRId64 " total=%" PRIu32 " len=%d\n",
               (esp_timer_get_time() / 1000), s_drop_total, (int)p->tot_len);
        return ERR_OK;   /* 静默吞掉：链路层“丢了”，上层等超时重传 */
    }
    return s_orig_linkoutput(netif, p);
}

static void install_dropper(void)
{
    if (s_orig_linkoutput != NULL) {
        return;
    }
    struct netif *n = (struct netif *)esp_netif_get_netif_impl(s_eth_netif);
    assert(n != NULL && n->linkoutput != NULL);
    s_orig_linkoutput = n->linkoutput;
    n->linkoutput = dropping_linkoutput;
}

/* ============================ 传输会话 ============================
 * 全部回调 / sys_timeout 调度都在 tcpip_thread 内（raw API 纪律，同 ch6）。
 */

typedef enum { PH_REXMIT = 0, PH_REXMIT_HEAVY, PH_NAGLE_OFF, PH_NAGLE_ON,
               PH_SWEEP } phase_t;

static const char *phase_name(phase_t p)
{
    switch (p) {
    case PH_REXMIT:           return "REXMIT-10pct";
    case PH_REXMIT_HEAVY:     return "REXMIT-40pct";
    case PH_NAGLE_OFF:        return "NAGLE-default";
    case PH_NAGLE_ON:         return "NAGLE-NODELAY";
    case PH_SWEEP:            return "SWEEP";
    default:                  return "?";
    }
}

static struct {
    struct tcp_pcb *pcb;
    phase_t phase;
    uint32_t total, written, acked;
    int64_t t_start_us;
    uint32_t pat_off;
    int err_mem;
} S;

#define CHUNK   (2 * TCP_MSS)
#define PATLEN  (64u * 1024u)
static uint8_t s_pat[PATLEN];

static inline bool is_bulk_phase(phase_t p)
{
    return p == PH_REXMIT || p == PH_REXMIT_HEAVY || p == PH_SWEEP;
}

/* ---- 前置声明 ---- */
static void sched_next(int64_t delay_ms);
static void pump_bulk(void);
static void stats_snapshot(const char *when);
static void session_deadline_cb(void *arg);
static void nagle_send_pair_fn(void *arg);

/* ---- 统计快照 ---- */

static void stats_snapshot(const char *when)
{
    /* IDF 未暴露 MIB2_STATS（tcpretranssegs 只在 MIB2_STATS 下计数），
     * 重传次数用应用层事件计数器（见 samp_cb 的 CH12-RTOEV/CH12-FREV）。 */
    printf("CH12-TCPSTATS %s tcpxmit=%u tcprecv=%u tcpdrop=%u lenerr=%u\n",
           when,
           (unsigned)lwip_stats.tcp.xmit,
           (unsigned)lwip_stats.tcp.recv,
           (unsigned)lwip_stats.tcp.drop,
           (unsigned)lwip_stats.tcp.lenerr);
}

/* 应用层重传事件计数（由 samp_cb 的状态迁移累加，采样间隔内并发
 * 发生的多个事件可能合并，故为观测下界） */
static u32_t ev_rto, ev_fastrexmit;

/* ---- 采样器：读公共头里可见的 PCB 字段 ---- */

static volatile bool s_samp_on;
static u32_t s_samp_period_ms;
static u8_t prev_nrtx, prev_dupacks;

static void samp_cb(void *arg)
{
    (void)arg;
    if (!s_samp_on || S.pcb == NULL) {
        return;   /* 会话已结束，停止重排 */
    }
    struct tcp_pcb *p = S.pcb;
    if (p->state != SYN_SENT) {
        int64_t tms = (esp_timer_get_time() - S.t_start_us) / 1000;
        printf("CH12-T t_ms=%lld sb=%d qlen=%d cwnd=%lu ssthresh=%lu rto=%d nrtx=%u dup=%u swnd=%lu\n",
               (long long)tms, (int)tcp_sndbuf(p), (int)tcp_sndqueuelen(p),
               (unsigned long)p->cwnd, (unsigned long)p->ssthresh,
               (int)p->rto, p->nrtx, p->dupacks, (unsigned long)p->snd_wnd);
        /* 事件：RTO 重传发生（nrtx 增加）或进入快速重传（dupacks 攀到 3+） */
        if (p->nrtx > prev_nrtx) {
            printf("CH12-RTOEV t_ms=%lld nrtx %u->%u rto_ticks=%d (~%d ms)\n",
                   (long long)tms, prev_nrtx, p->nrtx, (int)p->rto,
                   (int)p->rto * (int)TCP_SLOW_INTERVAL);
            ev_rto += p->nrtx - prev_nrtx;
        }
        if (p->dupacks >= 3 && prev_dupacks < 3) {
            printf("CH12-FREV t_ms=%lld dupacks=%u cwnd=%lu ssthresh=%lu\n",
                   (long long)tms, p->dupacks, (unsigned long)p->cwnd,
                   (unsigned long)p->ssthresh);
            ev_fastrexmit++;
        }
        prev_nrtx = p->nrtx;
        prev_dupacks = p->dupacks;
    }
    sys_timeout(s_samp_period_ms, samp_cb, NULL);
}

static void samp_start(u32_t period_ms)
{
    s_samp_period_ms = period_ms;
    prev_nrtx = 0;
    prev_dupacks = 0;
    ev_rto = 0;
    ev_fastrexmit = 0;
    s_samp_on = true;
    sys_timeout(period_ms, samp_cb, NULL);
}

static void samp_stop(void)
{
    s_samp_on = false;
    sys_untimeout(samp_cb, NULL);
}

/* ---- Nagle 对计数 ---- */

#define NAGLE_PAIRS   50
#define MSG_LEN       16

struct nagle_ctx {
    uint16_t pairs_done;
    int64_t  write2_us[NAGLE_PAIRS];        /* 第 2 条写入时刻（guest 时钟） */
    bool     pair_pending;                  /* 在等第 2 条被 ACK 释放 */
    uint32_t hold_us[NAGLE_PAIRS];          /* 扣留时长 = 首次 sent 相对 write2 */
};
#ifndef CONFIG_CH12_SWEEP_ONLY
static struct nagle_ctx NG;
#endif

#ifndef CONFIG_CH12_SWEEP_ONLY
static void le32(uint8_t *p, uint32_t v)
{
    p[0] = v & 0xff;
    p[1] = (v >> 8) & 0xff;
    p[2] = (v >> 16) & 0xff;
    p[3] = (v >> 24) & 0xff;
}
#endif

/* ---- 一轮收尾并调度下一步 ---- */

static void close_session_pcb(bool graceful_close)
{
    struct tcp_pcb *pcb = S.pcb;
    S.pcb = NULL;
    if (pcb != NULL) {
        tcp_arg(pcb, NULL);
        tcp_poll(pcb, NULL, 0);
        tcp_sent(pcb, NULL);
        tcp_err(pcb, NULL);
        if (graceful_close) {
            tcp_close(pcb);
        } else {
            tcp_abort(pcb);
        }
    }
}

static void session_report(const char *tag, bool full)
{
    int64_t us = esp_timer_get_time() - S.t_start_us;
    double mbit = us > 0 ? (double)S.acked * 8.0 / (double)us : 0.0;
    (void)full;
    printf("CH12-%s acked=%" PRIu32 "/%" PRIu32 " elapsed_ms=%lld mbit=%.2f "
           "rto_events=%u fastrexmit_events=%u dropped_frames=%" PRIu32 " err_mem=%d\n",
           tag, S.acked, S.total, (long long)(us / 1000), mbit,
           (unsigned)ev_rto, (unsigned)ev_fastrexmit, s_drop_total, S.err_mem);
    stats_snapshot("after");
}

/* Nagle 一组结束：吐出全部扣留测量并关连接 */
#ifndef CONFIG_CH12_SWEEP_ONLY
static void nagle_finish_cb(void *arg)
{
    (void)arg;
    for (int i = 0; i < NAGLE_PAIRS; i++) {
        printf("CH12-NPAIR idx=%d nodeelay=%d hold_us=%" PRIu32 "\n",
               i, S.phase == PH_NAGLE_ON ? 1 : 0, NG.hold_us[i]);
    }
    printf("CH12-NEND phase=%s pairs=%u\n", phase_name(S.phase), NG.pairs_done);
    samp_stop();
    close_session_pcb(true);
    sched_next(1500);
}
#endif

static void finish_bulk(bool full_done)
{
    samp_stop();
    const char *tag;
    if (!full_done) {
        tag = "ABORTED";
    } else {
        tag = (S.phase == PH_SWEEP) ? "SWEEPDONE" : "REXDONE";
    }
    session_report(tag, full_done);
    s_drop_enable = 0;
    s_drop_total = 0;
    close_session_pcb(full_done);
    sched_next(2000);
}

/* ---- raw API 回调 ---- */

static err_t connected_cb(void *arg, struct tcp_pcb *tpcb, err_t err)
{
    (void)arg; (void)tpcb; (void)err;
    printf("CH12-PHASE %s start total=%u\n", phase_name(S.phase),
           (unsigned)S.total);
    S.t_start_us = esp_timer_get_time();
#ifndef CONFIG_CH12_SWEEP_ONLY
    if (is_bulk_phase(S.phase)) {
        samp_start(50);
        pump_bulk();
    } else {
        samp_start(200);
        memset(&NG, 0, sizeof(NG));
        sys_timeout(10, nagle_send_pair_fn, NULL);
    }
#else
    samp_start(500);
    pump_bulk();
#endif
    return ERR_OK;
}

static err_t sent_cb(void *arg, struct tcp_pcb *tpcb, u16_t len)
{
    (void)arg; (void)tpcb;
    S.acked += len;
#ifndef CONFIG_CH12_SWEEP_ONLY
    /* Nagle 扣留测量：pair pending 时第一次 sent 回调 ≈ 第二条被放行的时刻 */
    if ((S.phase == PH_NAGLE_OFF || S.phase == PH_NAGLE_ON) &&
        NG.pair_pending && NG.pairs_done > 0) {
        int k = NG.pairs_done - 1;
        if (NG.write2_us[k] > 0 && NG.hold_us[k] == 0) {
            NG.hold_us[k] = (uint32_t)(esp_timer_get_time() - NG.write2_us[k]);
        }
        NG.pair_pending = false;
    }
#endif
    if (is_bulk_phase(S.phase)) {
        if (S.acked >= S.total) {
            finish_bulk(true);
            return ERR_OK;
        }
        pump_bulk();
    }
    return ERR_OK;
}

/* bulk 泵：尽量塞满发送缓冲（ACK 驱动，见第六章发送泵） */
static void pump_bulk(void)
{
    while (S.written < S.total) {
        uint32_t left = S.total - S.written;
        u16_t len = (u16_t)(left < CHUNK ? left : CHUNK);
        if ((uint32_t)len > PATLEN - S.pat_off) {
            len = (u16_t)(PATLEN - S.pat_off);
        }
        if (len == 0) {
            break;
        }
        if (tcp_write(S.pcb, s_pat + S.pat_off, len, TCP_WRITE_FLAG_COPY) != ERR_OK) {
            S.err_mem++;
            break;
        }
        S.written += len;
        S.pat_off = (S.pat_off + len) % PATLEN;
    }
    if (S.written > 0) {
        tcp_output(S.pcb);
    }
}

static err_t poll_cb(void *arg, struct tcp_pcb *tpcb)
{
    (void)arg; (void)tpcb;
    if (is_bulk_phase(S.phase) && S.acked < S.total) {
        pump_bulk();          /* ACK 流停顿时的兜底驱动 */
    }
    return ERR_OK;
}

static void err_cb(void *arg, err_t err)
{
    (void)arg;
    ESP_LOGE(TAG, "pcb error: %s (phase=%s)", lwip_strerr(err), phase_name(S.phase));
    S.pcb = NULL;
}

/* Nagle 组内的成对发送：write(16B) ×2 → 单次 tcp_output() */
#ifndef CONFIG_CH12_SWEEP_ONLY
static void nagle_send_pair_fn(void *arg)
{
    (void)arg;
    uint8_t msg[MSG_LEN];
    uint16_t k = NG.pairs_done;
    if (S.pcb == NULL) {
        return;
    }
    /* 第一条 */
    le32(msg + 0, 2u * k);
    le32(msg + 4, (uint32_t)esp_timer_get_time());
    le32(msg + 8, 0xC112BEEF);
    le32(msg + 12, ((uint32_t)k << 16) | 0u);   /* 高16位 pair 序号，低16位对内序号 */
    if (tcp_write(S.pcb, msg, MSG_LEN, TCP_WRITE_FLAG_COPY) != ERR_OK) {
        ESP_LOGE(TAG, "nagle write#1 failed");
        return;
    }
    /* 第二条紧接着写入：Nagle 若开启会在 output 时被扣住 */
    le32(msg + 0, 2u * k + 1u);
    le32(msg + 4, (uint32_t)esp_timer_get_time());
    le32(msg + 12, ((uint32_t)k << 16) | 1u);
    if (tcp_write(S.pcb, msg, MSG_LEN, TCP_WRITE_FLAG_COPY) != ERR_OK) {
        ESP_LOGE(TAG, "nagle write#2 failed");
        return;
    }
    NG.write2_us[k] = esp_timer_get_time();
    NG.pair_pending = true;
    NG.pairs_done++;
    tcp_output(S.pcb);

    if (NG.pairs_done < NAGLE_PAIRS) {
        sys_timeout(30, nagle_send_pair_fn, NULL);
    } else {
        sys_timeout(2000, nagle_finish_cb, NULL);   /* 等 ACK 尾巴后汇总 */
    }
}
#endif

/* 会话硬超时：丢包太狠跑不完就止损 */
static void session_deadline_cb(void *arg)
{
    (void)arg;
    if (S.pcb != NULL && is_bulk_phase(S.phase)) {
        printf("CH12-DEADLINE hit at acked=%" PRIu32 "/%" PRIu32 "\n",
               S.acked, S.total);
        finish_bulk(false);
    }
}

/* ------------------------------ 调度 ------------------------------ */

static void start_conn(phase_t ph, uint16_t port, uint32_t total, u32_t deadline_ms)
{
    memset(&S, 0, sizeof(S));
    S.phase = ph;
    S.total = total;

    struct tcp_pcb *pcb = tcp_new_ip_type(IPADDR_TYPE_V4);
    if (pcb == NULL) {
        ESP_LOGE(TAG, "tcp_new failed");
        return;
    }
#ifndef CONFIG_CH12_SWEEP_ONLY
    if (ph == PH_NAGLE_ON) {
        tcp_nagle_disable(pcb);       /* TF_NODELAY：实验组 */
    }
#endif
    tcp_arg(pcb, NULL);
    tcp_err(pcb, err_cb);
    tcp_sent(pcb, sent_cb);
    tcp_poll(pcb, poll_cb, 4);
    ip_addr_t peer;
    IP_ADDR4((&peer), 10, 0, 2, 2);
    err_t err = tcp_connect(pcb, &peer, port, connected_cb);
    if (err != ERR_OK) {
        ESP_LOGE(TAG, "tcp_connect failed: %s", lwip_strerr(err));
        tcp_close(pcb);
        return;
    }
    S.pcb = pcb;
    if (deadline_ms > 0) {
        sys_timeout(deadline_ms, session_deadline_cb, NULL);
    }
}

#ifndef CONFIG_CH12_SWEEP_ONLY
static void start_next_cb(void *arg);

/* 转步进调度：finish_bulk / nagle_finish_cb 经此推进阶段 */
static void sched_next(int64_t delay_ms)
{
    sys_timeout(delay_ms > 0 ? (u32_t)delay_ms : 1, start_next_cb, NULL);
}

static void start_next_cb(void *arg)
{
    (void)arg;
    static int step = 0;
    switch (step++) {
    case 0:
        install_dropper();
        s_drop_enable = 1;
        s_drop_pct_now = 10;
        start_conn(PH_REXMIT, PORT_REXMIT, REXMIT_TOTAL, 100000);
        break;
    case 1:
        /* 重丢包子阶段：40% 稳态丢帧，重传本身也会被丢，
         * 构造 nrtx 连续攀升的 RTO 退避阶梯 */
        s_drop_enable = 1;            /* finish_bulk 会复位，重开 */
        s_drop_pct_now = 40;
        start_conn(PH_REXMIT_HEAVY, PORT_REXMIT, HEAVY_TOTAL, 110000);
        break;
    case 2:                       /* 控制组：Nagle 默认开 */
        s_drop_enable = 0;
        start_conn(PH_NAGLE_OFF, PORT_NAGLE, 0, 0);
        break;
    case 3:                       /* 实验组：TF_NODELAY */
        start_conn(PH_NAGLE_ON, PORT_NAGLE, 0, 0);
        break;
    default:
        printf("CH12-DONE all phases complete, idling\n");
        break;
    }
}
#else
static void sweep_kick_cb(void *arg);

static void sched_next(int64_t delay_ms)
{
    sys_timeout(delay_ms > 0 ? (u32_t)delay_ms : 1, sweep_kick_cb, NULL);
}

static void sweep_kick_cb(void *arg)
{
    (void)arg;
    static bool ran = false;
    if (!ran) {
        ran = true;
        s_drop_enable = 1;
        start_conn(PH_SWEEP, PORT_REXMIT, SWEEP_TOTAL, 95000);
    } else {
        printf("CH12-DONE sweep transfer finished, idling\n");
    }
}
#endif

static void kick_cb(void *arg)
{
    (void)arg;
    printf("== ch12 lab: retransmission / sliding window / nagle / delayed ack ==\n");
    print_build_facts();
    stats_snapshot("before");
    for (uint32_t i = 0; i < PATLEN; i++) {
        s_pat[i] = (uint8_t)(((uint32_t)i * 2654435761u) >> 21);
    }
#ifndef CONFIG_CH12_SWEEP_ONLY
    sys_timeout(200, start_next_cb, NULL);
#else
    install_dropper();
    sys_timeout(200, sweep_kick_cb, NULL);
#endif
}

/* ------------------------------ app_main ------------------------------ */

void app_main(void)
{
    ESP_LOGI(TAG, "== ch12 lab: openeth bring-up then reliability bench ==");

    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    s_got_ip = xSemaphoreCreateBinary();

    esp_netif_config_t netif_cfg = ESP_NETIF_DEFAULT_ETH();
    s_eth_netif = esp_netif_new(&netif_cfg);

    eth_mac_config_t mac_cfg = ETH_MAC_DEFAULT_CONFIG();
    eth_phy_config_t phy_cfg = ETH_PHY_DEFAULT_CONFIG();
    phy_cfg.reset_gpio_num = -1;
    phy_cfg.autonego_timeout_ms = 3000;

    esp_eth_mac_t *mac = esp_eth_mac_new_openeth(&mac_cfg);
    assert(mac != NULL);
    esp_eth_phy_t *phy = esp_eth_phy_new_generic(&phy_cfg);
    assert(phy != NULL);

    esp_eth_config_t eth_cfg = ETH_DEFAULT_CONFIG(mac, phy);
    esp_eth_handle_t eth_handle = NULL;
    ESP_ERROR_CHECK(esp_eth_driver_install(&eth_cfg, &eth_handle));

    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_ETH_GOT_IP,
                                               &ip_event_handler, NULL));

    esp_eth_netif_glue_handle_t glue = esp_eth_new_netif_glue(eth_handle);
    ESP_ERROR_CHECK(esp_netif_attach(s_eth_netif, glue));

    ESP_ERROR_CHECK(esp_eth_start(eth_handle));
    ESP_LOGI(TAG, "waiting for DHCP lease ...");

    if (xSemaphoreTake(s_got_ip, pdMS_TO_TICKS(DHCP_TIMEOUT_MS)) != pdTRUE) {
        ESP_LOGE(TAG, "DHCP timeout -- check QEMU -nic");
        return;
    }

    /* raw API 入口必须投递到 tcpip_thread；此后一切调度在该线程内自续 */
    ESP_ERROR_CHECK(tcpip_callback(kick_cb, NULL));
}
