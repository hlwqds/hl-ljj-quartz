/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * lwIP 深度解析（六）实验工程：tcp_write 的 copy 语义与发送通路吞吐
 *
 * 基于 ch3 联网模板（openeth + esp_netif + DHCP）。
 * guest 作为 TCP 发送端（raw API），向主机 10.0.2.2:8006 发送固定总量数据：
 *   - 阶段 A：TCP_WRITE_FLAG_COPY / no-copy 各 3 次，共 6 个连接，各发 TCP_TOTAL 字节；
 *   - 阶段 B：同一固件内置一个「反压」轮次：主机端逐包限速读取，
 *     周期性打印 tcp_sndbuf / snd_queuelen / ERR_MEM 计数曲线。
 *
 * 所有 raw API 操作通过 tcpip_callback / sys_timeout 调度，全部运行在
 * tcpip_thread 上下文中——这是 raw API 的线程纪律。
 *
 * 运行环境：ESP-IDF v6.0.2 + qemu-system-xtensa (Espressif fork)，
 *           -nic user,model=open_eth
 */

#include <stdio.h>
#include <inttypes.h>
#include <string.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"

#include "esp_log.h"
#include "esp_timer.h"
#include "esp_event.h"
#include "esp_netif.h"
#include "esp_eth.h"

#include "lwip/tcp.h"
#include "lwip/sys.h"    /* sys_timeout */
#include "lwip/tcpip.h"  /* tcpip_callback */

static const char *TAG = "ch6lab";

#define HOST_IP         "10.0.2.2"      /* SLIRP 网关 = 宿主机回环 */
#define HOST_PORT       8006            /* 吞吐轮监听端口 */
#define HOST_PORT_BP    8007            /* 反压轮监听端口（独立限速接收器） */
#define BENCH_TOTAL     (10u * 1024u * 1024u)   /* 每轮 10MB */
#define BP_TOTAL        (16u * 1024u * 1024u)   /* 反压轮上限（主机限速读取） */
#define BP_DURATION_MS  15000                   /* 反压轮硬超时 */
#define PATLEN          (64u * 1024u)           /* 发送模式环形缓冲 > 最大在途数据 */
#define CHUNK           (2 * TCP_MSS)           /* 每次 tcp_write 的固定块大小 */
#define N_PER_MODE      3                       /* COPY / NOCOPY 各测几轮 */
#define PUMP_MAX_CALLS  8                       /* 单次回调内最多 tcp_write 次数 */
#define NEXT_RUN_DELAY_MS 300

#define DHCP_TIMEOUT_MS 10000

/* ---------------------------- 环境自报 ---------------------------- */

static void print_build_facts(void)
{
#ifdef LWIP_NETIF_TX_SINGLE_PBUF
    printf("CH06-FACT LWIP_NETIF_TX_SINGLE_PBUF=%d\n", LWIP_NETIF_TX_SINGLE_PBUF);
#else
    printf("CH06-FACT LWIP_NETIF_TX_SINGLE_PBUF=undef\n");
#endif
#if defined(CONFIG_LWIP_TCP_SND_BUF_DEFAULT)
    printf("CH06-FACT CONFIG_LWIP_TCP_SND_BUF_DEFAULT=%d\n", CONFIG_LWIP_TCP_SND_BUF_DEFAULT);
#endif
#if defined(CONFIG_LWIP_TCP_WND_DEFAULT)
    printf("CH06-FACT CONFIG_LWIP_TCP_WND_DEFAULT=%d\n", CONFIG_LWIP_TCP_WND_DEFAULT);
#endif
#if defined(CONFIG_LWIP_TCP_MSS)
    printf("CH06-FACT CONFIG_LWIP_TCP_MSS=%d\n", CONFIG_LWIP_TCP_MSS);
#endif
    printf("CH06-FACT TCP_SND_QUEUELEN=%d CHUNK=%d PATLEN=%u TOTAL=%u\n",
           (int)TCP_SND_QUEUELEN, (int)CHUNK, (unsigned)PATLEN, (unsigned)BENCH_TOTAL);
}

/* ------------------------- 网络 bring-up ------------------------- */

static SemaphoreHandle_t s_got_ip;

static void eth_event_handler(void *arg, esp_event_base_t base,
                              int32_t event_id, void *event_data)
{
    if (event_id == ETHERNET_EVENT_CONNECTED) {
        ESP_LOGI(TAG, "ETH_EVENT: CONNECTED (link up)");
    }
}

static void ip_event_handler(void *arg, esp_event_base_t base,
                             int32_t event_id, void *event_data)
{
    ip_event_got_ip_t *evt = (ip_event_got_ip_t *)event_data;
    ESP_LOGI(TAG, "GOT_IP: " IPSTR, IP2STR(&evt->ip_info.ip));
    xSemaphoreGive(s_got_ip);
}

/* --------------------- 吞吐/反压实验核心（raw API） --------------------- */

typedef enum { MODE_COPY = 0, MODE_NOCOPY, MODE_BP } bench_mode_t;

/* Fletcher-16 校验累加器：guest 与主机脚本用同一算法比对字节流 */
struct fletcher { uint16_t s1, s2; };

static inline void fletcher_update(struct fletcher *f, const uint8_t *p, size_t n)
{
    for (size_t i = 0; i < n; i++) {
        f->s1 = (uint16_t)((f->s1 + p[i]) % 255);
        f->s2 = (uint16_t)((f->s2 + f->s1) % 255);
    }
}

struct bench_ctx {
    struct tcp_pcb *pcb;
    bench_mode_t mode;
    int run_idx;                /* 本模式的第几轮，从 1 计 */
    uint32_t total, written, acked;
    uint32_t pat_off;           /* 环形模式缓冲内的偏移 */
    struct fletcher fx;         /* 已写入数据的校验和 */
    int64_t t_start_us;
    int err_mem;                /* tcp_write 返回非 ERR_OK 次数 */
    int sndbuf_min_seen;        /* 周期内见到的 sndbuf 最小值（反压观测） */
};

static struct bench_ctx s_b;
static uint8_t s_pat[PATLEN];
static int s_sched_idx = 0;     /* 总调度序号；<N_PER_MODE*2 为吞吐轮，随后进入反压轮 */

static const bench_mode_t s_sched[N_PER_MODE * 2] = {
    MODE_COPY, MODE_NOCOPY,
    MODE_COPY, MODE_NOCOPY,
    MODE_COPY, MODE_NOCOPY,
};

static void sched_next(int64_t delay_ms);

static err_t pump(void);        /* 前置声明 */

static const char *mode_name(bench_mode_t m)
{
    switch (m) {
    case MODE_COPY:   return "COPY";
    case MODE_NOCOPY: return "NOCOPY";
    default:          return "BP";
    }
}

/* ---- 发送泵：把发送缓冲能吃的量按 CHUNK 写进栈 ---- */

static err_t pump(void)
{
    struct bench_ctx *b = &s_b;
    u8_t apiflags = (b->mode == MODE_COPY) ? TCP_WRITE_FLAG_COPY : 0;
    int calls = 0;

    while (b->written < b->total && calls < PUMP_MAX_CALLS) {
        uint32_t left = b->total - b->written;
        /* len 不越过模式缓冲边界（payload 必须连续有效），也不超过 CHUNK */
        u16_t len = (u16_t)(left < CHUNK ? left : CHUNK);
        if ((uint32_t)len > PATLEN - b->pat_off) {
            len = (u16_t)(PATLEN - b->pat_off);
        }
        if (len == 0) {
            break;
        }
        err_t err = tcp_write(b->pcb, s_pat + b->pat_off, len, apiflags);
        if (err != ERR_OK) {
            b->err_mem++;
            break;
        }
        fletcher_update(&b->fx, s_pat + b->pat_off, len);
        b->written += len;
        b->pat_off = (b->pat_off + len) % PATLEN;
        calls++;
    }
    if (calls > 0) {
        tcp_output(b->pcb);
    }
    return calls > 0 && b->err_mem == 0 ? ERR_OK : ERR_INPROGRESS;
}

/* ---- 完成一轮的汇报 ---- */

static double mbps(uint32_t bytes, int64_t us)
{
    if (us <= 0) {
        return 0.0;
    }
    return (double)bytes * 8.0 * 1e6 / ((double)us * 1e6); /* = bytes*8/us */
}

static void report_run(const char *phase, bench_mode_t mode, int run_idx,
                       uint32_t sent, int64_t us, int errs)
{
    printf("CH06-%s mode=%s run=%d sent=%" PRIu32 " us=%lld mbit=%.2f err_mem=%d digest=%04x\n",
           phase, mode_name(mode), run_idx, sent, (long long)us,
           mbps(sent, us), errs, s_b.fx.s2 << 8 | s_b.fx.s1);
}

/* ---- 定期采样（反压轮）：观察 tcp_sndbuf 下降曲线与 ERR_MEM 频次 ---- */

static void samp_cb(void *arg);
static void samp_stop(void);
static void bp_retry_cb(void *arg);

/* ---- 反压轮硬超时：放弃连接，继续调度 ---- */

static void bp_end_cb(void *arg)
{
    samp_stop();
    int64_t us = esp_timer_get_time() - s_b.t_start_us;
    printf("CH06-BPSTOP elapsed_ms=%lld written=%" PRIu32 " acked=%" PRIu32 " err_mem=%d "
           "sndbuf_min=%d mbit=%.2f\n",
           (long long)(us / 1000), s_b.written, s_b.acked, s_b.err_mem,
           s_b.sndbuf_min_seen, mbps(s_b.written, us));
    struct tcp_pcb *pcb = s_b.pcb;
    s_b.pcb = NULL;
    if (pcb) {
        tcp_arg(pcb, NULL);
        tcp_poll(pcb, NULL, 0);
        tcp_sent(pcb, NULL);
        tcp_abort(pcb);   /* 演示轮直接放弃连接，不等优雅关闭 */
    }
    sched_next(500);
}

/* ---- 统一周期采样：反压轮每 250ms，吞吐轮每 1000ms ---- */

static volatile bool s_samp_on;
static u32_t s_samp_ms;

static void samp_cb(void *arg)
{
    if (!s_samp_on || !s_b.pcb) {
        return;
    }
    int64_t el = (esp_timer_get_time() - s_b.t_start_us) / 1000;
    int sb = (int)tcp_sndbuf(s_b.pcb);
    if (sb < s_b.sndbuf_min_seen) {
        s_b.sndbuf_min_seen = sb;
    }
    printf("CH06-%s t=%lldms sndbuf=%d qlen=%d written=%" PRIu32 " acked=%" PRIu32
           " err_mem=%d\n",
           s_b.mode == MODE_BP ? "BP" : "SAMP", (long long)el, sb,
           (int)tcp_sndqueuelen(s_b.pcb), s_b.written, s_b.acked, s_b.err_mem);
    sys_timeout(s_samp_ms, samp_cb, NULL);
}

static void samp_stop(void)
{
    s_samp_on = false;
    sys_untimeout(samp_cb, NULL);
    sys_untimeout(bp_retry_cb, NULL);
}

/* ---- 反压轮的持续重试泵：以 100ms 节拍主动探测 tcp_write/ERR_MEM ---- */

static void bp_retry_cb(void *arg)
{
    if (s_b.mode != MODE_BP || !s_b.pcb || s_b.written >= s_b.total) {
        return;
    }
    pump();
    sys_timeout(100, bp_retry_cb, NULL);
}

/* ---- raw API 回调 ---- */

static err_t bench_connected_cb(void *arg, struct tcp_pcb *tpcb, err_t err)
{
    struct bench_ctx *b = &s_b;
    ESP_LOGI(TAG, "connected to %s:%d (mode=%s run=%d)", HOST_IP, HOST_PORT,
             mode_name(b->mode), b->run_idx);
    b->t_start_us = esp_timer_get_time();
    s_samp_on = true;
    sys_timeout(s_samp_ms, samp_cb, NULL);
    if (b->mode == MODE_BP) {
        sys_timeout(BP_DURATION_MS, bp_end_cb, NULL);
        sys_timeout(100, bp_retry_cb, NULL);
    }
    pump();
    return ERR_OK;
}

static err_t bench_sent_cb(void *arg, struct tcp_pcb *tpcb, u16_t len)
{
    struct bench_ctx *b = &s_b;
    b->acked += len;
    if (b->mode != MODE_BP && b->acked >= b->total) {
        int64_t us = esp_timer_get_time() - b->t_start_us;
        samp_stop();
        report_run("BENCH", b->mode, b->run_idx, b->acked, us, b->err_mem);
        struct tcp_pcb *pcb = b->pcb;
        b->pcb = NULL;
        tcp_arg(pcb, NULL);
        tcp_poll(pcb, NULL, 0);
        tcp_sent(pcb, NULL);
        tcp_close(pcb);
        sched_next(NEXT_RUN_DELAY_MS);
        return ERR_OK;
    }
    pump();
    return ERR_OK;
}

static err_t bench_poll_cb(void *arg, struct tcp_pcb *tpcb)
{
    if (s_b.pcb == tpcb && s_b.written < s_b.total) {
        pump();     /* ACK 流停顿时的兜底驱动 */
    }
    return ERR_OK;
}

static void bench_err_cb(void *arg, err_t err)
{
    ESP_LOGE(TAG, "bench pcb error: %s", lwip_strerr(err));
    memset(&s_b, 0, sizeof(s_b));
}

/* ---- 调度：建连下一轮，或报告结束 ---- */

static bool start_conn(bench_mode_t mode, int run_idx, uint32_t total, u16_t port)
{
    memset(&s_b, 0, sizeof(s_b));
    s_b.mode = mode;
    s_b.run_idx = run_idx;
    s_b.total = total;
    s_b.sndbuf_min_seen = (int)TCP_SND_BUF;

    struct tcp_pcb *pcb = tcp_new_ip_type(IPADDR_TYPE_V4);
    if (!pcb) {
        ESP_LOGE(TAG, "tcp_new failed");
        return false;
    }
    tcp_arg(pcb, NULL);
    tcp_err(pcb, bench_err_cb);
    tcp_sent(pcb, bench_sent_cb);               /* ACK 驱动的补充发送 */
    tcp_poll(pcb, bench_poll_cb, 4);            /* 每 2s 兜底 */
    s_samp_ms = (mode == MODE_BP) ? 250 : 1000;
    ip_addr_t peer;
    IP_ADDR4((&peer), 10, 0, 2, 2);
    err_t err = tcp_connect(pcb, &peer, port, bench_connected_cb);
    if (err != ERR_OK) {
        ESP_LOGE(TAG, "tcp_connect failed: %s", lwip_strerr(err));
        tcp_close(pcb);
        return false;
    }
    s_b.pcb = pcb;
    return true;
}

static void start_next_cb(void *arg)
{
    if (s_sched_idx < (int)(sizeof(s_sched) / sizeof(s_sched[0]))) {
        bench_mode_t mode = s_sched[s_sched_idx++];
        int nth = 1 + (s_sched_idx - 1) / 2;
        start_conn(mode, nth, BENCH_TOTAL, HOST_PORT);
    } else if (s_sched_idx == (int)(sizeof(s_sched) / sizeof(s_sched[0]))) {
        s_sched_idx++;
        printf("CH06-SUMMARY benches done (COPY x%d, NOCOPY x%d), starting backpressure phase\n",
               N_PER_MODE, N_PER_MODE);
        start_conn(MODE_BP, 1, BP_TOTAL, HOST_PORT_BP);
    } else {
        printf("CH06-DONE all phases complete, idling\n");
    }
}

static void sched_next(int64_t delay_ms)
{
    sys_timeout(delay_ms > 0 ? (u32_t)delay_ms : 1, start_next_cb, NULL);
}

static void kick_cb(void *arg)
{
    printf("== ch6 lab: zero-copy throughput / backpressure ==\n");
    print_build_facts();
    memset(s_pat, 0, sizeof(s_pat));
    for (uint32_t i = 0; i < PATLEN; i++) {
        s_pat[i] = (uint8_t)(((uint32_t)i * 2654435761u) >> 21);
    }
    sched_next(50);
}

/* ------------------------------ app_main ------------------------------ */

void app_main(void)
{
    ESP_LOGI(TAG, "== ch6 lab: openeth bring-up then tcp_write bench ==");

    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    s_got_ip = xSemaphoreCreateBinary();

    esp_netif_config_t netif_cfg = ESP_NETIF_DEFAULT_ETH();
    esp_netif_t *eth_netif = esp_netif_new(&netif_cfg);

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

    ESP_ERROR_CHECK(esp_event_handler_register(ETH_EVENT, ETHERNET_EVENT_CONNECTED,
                                               &eth_event_handler, NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_ETH_GOT_IP,
                                               &ip_event_handler, NULL));

    esp_eth_netif_glue_handle_t glue = esp_eth_new_netif_glue(eth_handle);
    ESP_ERROR_CHECK(esp_netif_attach(eth_netif, glue));

    ESP_ERROR_CHECK(esp_eth_start(eth_handle));
    ESP_LOGI(TAG, "waiting for DHCP lease ...");

    if (xSemaphoreTake(s_got_ip, pdMS_TO_TICKS(DHCP_TIMEOUT_MS)) != pdTRUE) {
        ESP_LOGE(TAG, "DHCP timeout -- check QEMU -nic");
        return;
    }

    /* raw API 入口必须投递到 tcpip_thread。此后一切调度都在该线程内自续。 */
    ESP_ERROR_CHECK(tcpip_callback(kick_cb, NULL));
}
