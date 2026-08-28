/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * 案例 C —— 接收路径层级拷贝差（同一回声负载走 raw / netconn / socket 三层）
 *
 * 拓扑：三对独立的 127.0.0.1 回环"客户端 ↔ 回声服务器"，各层一组：
 *   raw     客户端/服务器都跑在 tcpip 线程（回调驱动）
 *   netconn 客户端跑编排任务，服务器独立任务（每层一个专用本地端口）
 *   socket  同上（BSD 套接字形态）
 *
 * 负载：严格串行 ping-pong，每消息 = 一条完整记录（RT_PING_C），收端按位校验，
 * RTT 由 esp_timer 打点。层间交错轮次（raw→netconn→socket × CONFIG_ZC_C_PASSES
 * 遍）实现同开机配对；承接 ch10/ch15 的分层税数字，细化到 per-copy 成本。
 */
#include <string.h>

#include "esp_timer.h"

#include "lwip/api.h"
#include "lwip/netbuf.h"
#include "lwip/sockets.h"
#include "lwip/tcpip.h"

#include "zc_priv.h"

#define C_MSG_LEN ((uint16_t)CONFIG_ZC_C_MSG)

/* 各层目的地端口：自环模式连本地回声服务；反射器模式统一出连宿主 8331 */
static uint16_t c_layer_port(uint16_t local_port)
{
#if CONFIG_ZC_HOST_REFLECTOR
    (void)local_port;
    return PORT_HOST;
#else
    return local_port;
#endif
}

/* ---------------- 公共：确定性载荷（含 per-seq 变化，可逐位校验） ---------------- */

static void c_fill_payload(uint8_t *p, uint16_t len, uint32_t seq)
{
    for (uint16_t i = 0; i < len; i++) {
        p[i] = zc_pat_byte(seq * 131u + i);
    }
}

static bool c_verify_payload(const uint8_t *p, uint16_t len, uint32_t seq,
                             const char **why)
{
    if (len != C_MSG_LEN) {
        *why = "len";
        return false;
    }
    for (uint16_t i = 0; i < len; i++) {
        if (p[i] != zc_pat_byte(seq * 131u + i)) {
            *why = "content";
            return false;
        }
    }
    *why = NULL;
    return true;
}

static void c_build_ping(uint8_t *buf, uint32_t seq)
{
    static uint8_t pl[1400];
    c_fill_payload(pl, C_MSG_LEN, seq);
    zc_build_rec(buf, RT_PING_C, seq, pl, C_MSG_LEN);
}

/* ================= raw 层：回调式回声服务 + 回调式客户端 ================= */

static bool cecho_on_rec(zc_sink_t *k, const uint8_t *rec, uint16_t tot, bool span)
{
    (void)span;
    uint16_t t7 = zc_rd16(rec + 4) & 0x7FFFu;
    if (t7 == RT_CTRL_END) {
        return zc_engine_handle_end(k, rec, tot);
    }
    if (t7 != RT_PING_C) {
        return true;
    }
    err_t e = zc_sink_echo_cur(k, rec, tot);
    if (e == ERR_OK && k->conn != NULL) {
        tcp_output(k->conn);
    }
    /* sndbuf 极端不足时挂起欠账标记（基准串行节奏下不会发生） */
    if (e == ERR_INPROGRESS) {
        printf("EX16-NOTE cecho sndbuf backlog (unexpected)\n");
    }
    return e != ERR_MEM;
}

typedef struct
{
    uint32_t expect_seq;
    uint32_t target_n;
    uint32_t got_n;
    int64_t last_send_us;
    volatile bool armed;
} craw_t;

static craw_t s_craw;
#define SMP_RAW (&g_smp_pool[0])

static uint8_t s_craw_txbuf[REC_HDR_LEN + 1400];

static void craw_send_one(void)
{
    c_build_ping(s_craw_txbuf, s_craw.expect_seq);
    s_craw.last_send_us = esp_timer_get_time();
    err_t e =
        zc_cli_post(&g_cli_main, s_craw_txbuf,
                    (uint16_t)(REC_HDR_LEN + C_MSG_LEN), TCP_WRITE_FLAG_COPY);
    if (e != ERR_OK) {
        printf("$$$ EXFAIL reason=C_raw_post e=%d\n", (int)e);
        zc_fail("C_raw_post");
    }
}

/* 客户端收到回声：校验 + 计 RTT + 发下一条（同线程直续，无需再排队） */
static void craw_on_data(void *uctx_r, const uint8_t *rec, uint16_t tot,
                         uint16_t type, uint32_t seq)
{
    (void)uctx_r;
    (void)tot;
    if (!s_craw.armed || type != RT_PING_C) {
        return;
    }
    int64_t dt = esp_timer_get_time() - s_craw.last_send_us;
    const char *why;
    const uint8_t *pl = rec + REC_HDR_LEN;
    if (!c_verify_payload(pl, zc_rd16(rec + 10), seq, &why) ||
        seq != s_craw.expect_seq) {
        printf("$$$ EXFAIL reason=C_raw_reply why=%s seq=%lu\n", why ? why : "?",
               (unsigned long)seq);
        zc_fail("C_raw_bad_reply");
        return;
    }
    zc_smp_push(SMP_RAW, dt);
    s_craw.got_n++;
    s_craw.expect_seq++;
    if (s_craw.got_n >= s_craw.target_n) {
        s_craw.armed = false;
    } else {
        craw_send_one();
    }
}

/* 编排任务侧把第一批发送投进 tcpip 线程的入口 */
static void craw_kick(void *arg)
{
    (void)arg;
    if (s_craw.armed && !s_craw.got_n) {
        craw_send_one();
    }
}

bool ex16_caseC_run(void);

static bool craw_batch(uint32_t n, int64_t timeout_ms)
{
    s_craw.target_n = n;
    s_craw.got_n = 0;
    s_craw.armed = true;
    if (!zc_run_in_tcpip(craw_kick, NULL, 5000)) {
        return false;
    }
    int64_t deadline = esp_timer_get_time() + timeout_ms * 1000LL;
    while (s_craw.armed) {
        if (g_fail || esp_timer_get_time() > deadline) {
            zc_fail("C_raw_batch_timeout");
            return false;
        }
        vTaskDelay(pdMS_TO_TICKS(2));
    }
    return true;
}

/* ================= netconn 层：独立服务器任务 + 编排任务当客户端 ================= */

static SemaphoreHandle_t s_nc_ready;
static volatile bool s_nc_server_up;

static void c_nc_server_task(void *arg)
{
    (void)arg;
    struct netconn *l = netconn_new(NETCONN_TCP);
    if (l == NULL) {
        zc_fail("C_nc_listen_new");
        vTaskDelete(NULL);
        return;
    }
    if (netconn_bind(l, IP_ADDR_ANY, PORT_C_NC) != ERR_OK ||
        netconn_listen_with_backlog(l, 4) != ERR_OK) {
        zc_fail("C_nc_listen");
        vTaskDelete(NULL);
        return;
    }
    s_nc_server_up = true;
    xSemaphoreGive(s_nc_ready);
    printf("EX16-SRVUP layer=netconn port=%d\n", PORT_C_NC);

    for (;;) {
        struct netconn *nc = NULL;
        if (netconn_accept(l, &nc) != ERR_OK) {
            vTaskDelay(pdMS_TO_TICKS(100));
            continue;
        }
        netconn_set_recvtimeout(nc, 10000);
        for (;;) {
            struct pbuf *p = NULL;
            err_t e = netconn_recv_tcp_pbuf(nc, &p);
            if (e != ERR_OK || p == NULL) {
                break; /* 对端关闭或超时 */
            }
            /* 只处理恰好一条完整记录的到达（基准负载粒度=单记录）。
             * ch23 纪律：串行会话，先收后回，关闭前不交叉写。netconn 收包窗口
             * 由协议栈内部维护（应用无需手工 recved）。 */
            if (p->tot_len >= REC_HDR_LEN &&
                zc_rd16((uint8_t *)p->payload + 4) == RT_PING_C) {
                netconn_write(nc, p->payload, p->tot_len, NETCONN_COPY);
            }
            pbuf_free(p);
        }
        netconn_close(nc);
        netconn_delete(nc);
    }
}

#define SMP_NC (&g_smp_pool[1])
static uint8_t s_nc_buf[REC_HDR_LEN + 1400];

static bool c_nc_client_connect(struct netconn **out)
{
    struct netconn *nc = netconn_new(NETCONN_TCP);
    if (nc == NULL) {
        return false;
    }
    netconn_set_recvtimeout(nc, 5000);
    err_t e = netconn_connect(nc, &g_load_dst, c_layer_port(PORT_C_NC));
    if (e != ERR_OK) {
        netconn_delete(nc);
        printf("$$$ EXFAIL reason=C_nc_connect e=%d dst=%s:%d\n", (int)e,
               ipaddr_ntoa(&g_load_dst), PORT_C_NC);
        return false;
    }
    *out = nc;
    return true;
}

static bool nc_batch(struct netconn *nc, uint32_t seq_start, uint32_t n,
                     int64_t timeout_ms)
{
    int64_t deadline = esp_timer_get_time() + timeout_ms * 1000LL;
    for (uint32_t i = 0; i < n; i++) {
        uint32_t seq = seq_start + i;
        c_build_ping(s_nc_buf, seq);
        int64_t t0 = esp_timer_get_time();
        if (netconn_write(nc, s_nc_buf, REC_HDR_LEN + C_MSG_LEN,
                          NETCONN_COPY) != ERR_OK) {
            zc_fail("C_nc_write");
            return false;
        }
        struct pbuf *p = NULL;
        err_t e = netconn_recv_tcp_pbuf(nc, &p);
        if (e != ERR_OK || p == NULL) {
            zc_fail("C_nc_recv");
            return false;
        }
        int64_t dt = esp_timer_get_time() - t0;
        const char *why;
        bool ok = p->tot_len == REC_HDR_LEN + C_MSG_LEN &&
                  zc_rd16(p->payload + 4) == RT_PING_C &&
                  c_verify_payload((uint8_t *)p->payload + REC_HDR_LEN,
                                   C_MSG_LEN, seq, &why);
        pbuf_free(p);
        if (!ok) {
            printf("$$$ EXFAIL reason=C_nc_bad_reply why=%s\n", why ? why : "?");
            zc_fail("C_nc_bad_reply");
            return false;
        }
        zc_smp_push(SMP_NC, dt);
        if (esp_timer_get_time() > deadline) {
            zc_fail("C_nc_timeout");
            return false;
        }
    }
    return true;
}

/* ================= socket 层：独立服务器任务 + 编排任务当客户端 ================= */

static SemaphoreHandle_t s_sk_ready;
static volatile bool s_sk_server_up;

static void c_sk_server_task(void *arg)
{
    (void)arg;
    int l = socket(AF_INET, SOCK_STREAM, 0);
    if (l < 0) {
        zc_fail("C_sk_socket");
        vTaskDelete(NULL);
        return;
    }
    int one = 1;
    setsockopt(l, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_port = lwip_htons(PORT_C_SOCK);
    a.sin_addr.s_addr = PP_HTONL(INADDR_ANY);
    if (bind(l, (struct sockaddr *)&a, sizeof(a)) < 0 || listen(l, 4) < 0) {
        zc_fail("C_sk_listen");
        close(l);
        vTaskDelete(NULL);
        return;
    }
    s_sk_server_up = true;
    xSemaphoreGive(s_sk_ready);
    printf("EX16-SRVUP layer=socket port=%d\n", PORT_C_SOCK);

    for (;;) {
        int s = accept(l, NULL, NULL);
        if (s < 0) {
            vTaskDelay(pdMS_TO_TICKS(100));
            continue;
        }
        struct timeval tv = {.tv_sec = 10, .tv_usec = 0};
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        static uint8_t rb[REC_HDR_LEN + 1400];
        for (;;) {
            ssize_t n = recv(s, rb, sizeof(rb), 0);
            if (n <= 0) {
                break; /* 关闭/超时（ch23：先收后回、及时回收） */
            }
            if ((size_t)n >= REC_HDR_LEN &&
                zc_rd16(rb + 4) == RT_PING_C) {
                ssize_t off = 0;
                while (off < n) {
                    ssize_t w = send(s, rb + off, (size_t)(n - off), 0);
                    if (w <= 0) {
                        goto closed;
                    }
                    off += w;
                }
            }
        }
    closed:
        close(s);
    }
}

#define SMP_SK (&g_smp_pool[2])
static uint8_t s_sk_buf[REC_HDR_LEN + 1400];

static int c_sock_open_client(void)
{
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) {
        return -1;
    }
    struct timeval tv = {.tv_sec = 5, .tv_usec = 0};
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_port = lwip_htons(c_layer_port(PORT_C_SOCK));
    memcpy(&a.sin_addr.s_addr, &g_load_dst, sizeof(a.sin_addr.s_addr));
    if (connect(s, (struct sockaddr *)&a, sizeof(a)) < 0) {
        printf("$$$ EXFAIL reason=C_sk_connect errno=%d\n", errno);
        close(s);
        return -1;
    }
    return s;
}

static bool sk_batch(int s, uint32_t seq_start, uint32_t n, int64_t timeout_ms)
{
    int64_t deadline = esp_timer_get_time() + timeout_ms * 1000LL;
    for (uint32_t i = 0; i < n; i++) {
        uint32_t seq = seq_start + i;
        c_build_ping(s_sk_buf, seq);
        size_t tot = REC_HDR_LEN + C_MSG_LEN;

        int64_t t0 = esp_timer_get_time();
        size_t off = 0;
        while (off < tot) {
            ssize_t w = send(s, s_sk_buf + off, tot - off, 0);
            if (w <= 0) {
                zc_fail("C_sk_write");
                return false;
            }
            off += (size_t)w;
        }

        size_t got = 0;
        static uint8_t rx[REC_HDR_LEN + 1400];
        while (got < tot) {
            ssize_t r = recv(s, rx + got, sizeof(rx) - got, 0);
            if (r <= 0) {
                zc_fail("C_sk_recv");
                return false;
            }
            got += (size_t)r;
        }
        int64_t dt = esp_timer_get_time() - t0;

        const char *why;
        if (zc_rd16(rx + 4) != RT_PING_C ||
            !c_verify_payload(rx + REC_HDR_LEN, C_MSG_LEN, seq, &why)) {
            printf("$$$ EXFAIL reason=C_sk_bad_reply why=%s\n", why ? why : "?");
            zc_fail("C_sk_bad_reply");
            return false;
        }
        zc_smp_push(SMP_SK, dt);
        if (esp_timer_get_time() > deadline) {
            zc_fail("C_sk_timeout");
            return false;
        }
    }
    return true;
}

/* ================= 编排入口 ================= */

bool ex16_caseC_run(void)
{
    if (g_case != 3) {
        return true;
    }
    const uint32_t msgs = (uint32_t)CONFIG_ZC_C_MSGS;
    const uint32_t passes = (uint32_t)CONFIG_ZC_C_PASSES;

    printf("$$$ EX16-CFG case=C msg_len=%u msgs_per_pass=%lu passes=%lu "
           "layers='raw,netconn,socket' interleave='layer round-robin'\n",
           C_MSG_LEN, (unsigned long)msgs, (unsigned long)passes);

    zc_smp_reset(SMP_RAW);
    zc_smp_reset(SMP_NC);
    zc_smp_reset(SMP_SK);

    /* 三套服务先立起来 */
    g_svc_cecho.on_rec = cecho_on_rec;
    if (!zc_svc_listen(&g_svc_cecho, PORT_C_RAW)) {
        return false;
    }
    s_nc_ready = xSemaphoreCreateBinary();
    s_sk_ready = xSemaphoreCreateBinary();
    if (xTaskCreate(c_nc_server_task, "c_nc_srv", 3072, NULL, 6, NULL) != pdPASS ||
        xTaskCreate(c_sk_server_task, "c_sk_srv", 3072, NULL, 6, NULL) != pdPASS) {
        zc_fail("C_srv_spawn");
        return false;
    }
    if (xSemaphoreTake(s_nc_ready, pdMS_TO_TICKS(5000)) != pdTRUE ||
        xSemaphoreTake(s_sk_ready, pdMS_TO_TICKS(5000)) != pdTRUE) {
        zc_fail("C_srv_ready_timeout");
        return false;
    }

    /* raw 客户端连接（事件机常驻） */
    g_cli_main.on_data = craw_on_data;
    g_cli_main.on_sent = NULL;
    memset(&s_craw, 0, sizeof(s_craw));
    if (!zc_cli_open_ext(&g_cli_main, "C-raw", c_layer_port(PORT_C_RAW), 5000)) {
        return false;
    }
    /* netconn / socket 客户端连接（编排任务持有） */
    struct netconn *nc = NULL;
    if (!c_nc_client_connect(&nc)) {
        return false;
    }
    int sk = c_sock_open_client();
    if (sk < 0) {
        return false;
    }

    zc_heap_line("case-C begin");

    uint32_t raw_seq_base = 1, nc_seq_base = 1, sk_seq_base = 1;
    for (uint32_t p = 0; p < passes; p++) {
        printf("EX16-STAGE name=C-pass pass=%lu/%lu order=raw,netconn,socket\n",
               (unsigned long)(p + 1), (unsigned long)passes);
        if (!craw_batch(msgs, 60000)) {
            return false;
        }
        zc_heap_line("after-raw");
        if (!nc_batch(nc, nc_seq_base, msgs, 60000)) {
            return false;
        }
        nc_seq_base += msgs;
        zc_heap_line("after-netconn");
        if (!sk_batch(sk, sk_seq_base, msgs, 60000)) {
            return false;
        }
        sk_seq_base += msgs;
        zc_heap_line("after-socket");
    }

    /* 关闭非 raw 会话 */
    netconn_close(nc);
    netconn_delete(nc);
    close(sk);

    zc_smp_print("C-raw-loopback", SMP_RAW);
    zc_smp_print("C-netconn-loopback", SMP_NC);
    zc_smp_print("C-socket-loopback", SMP_SK);

    double rm = (double)zc_smp_med(SMP_RAW);
    double nm = (double)zc_smp_med(SMP_NC);
    double sm = (double)zc_smp_med(SMP_SK);
    printf("$$$ EX16-RESULT case=C kind=triad raw_med_us=%.0f netconn_med_us=%.0f "
           "socket_med_us=%.0f nc_over_raw_x=%.2f sock_over_raw_x=%.2f "
           "sock_over_nc_x=%.2f n_raw=%u n_nc=%u n_sk=%u\n",
           rm, nm, sm, nm / rm, sm / rm, sm / nm, SMP_RAW->n, SMP_NC->n,
           SMP_SK->n);

    zc_heap_line("case-C end");
    return !g_fail;
}
