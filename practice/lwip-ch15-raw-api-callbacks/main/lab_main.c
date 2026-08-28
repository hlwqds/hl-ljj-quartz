/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * lwIP 深度解析（十五）实验工程：raw API：回调式编程的艺术与陷阱
 *
 * 在 ch3 联网模板（openeth bring-up + esp_netif + DHCP）之上：
 *   服务 A  8017/tcp raw API echo：per-connection 状态机 + 发送背压队列。
 *           tcp_write 返回 ERR_MEM 时把到达的 pbuf 挂进等待队列，
 *           由 sent/poll 回调驱动补发；tcp_recved 延迟到真正入队之后，
 *           让接收窗口随消费速度收缩（背压可见化）。
 *   服务 B  8517/tcp socket API echo（独立任务，同题对照组）。
 *   控制口  8027/udp raw：
 *       st         统计/状态快照          pcbs      遍历四条 TCP PCB 链表
 *       leak:on|off EOF(p==NULL) 忘记 close —— 制造 CLOSE_WAIT 泄漏对照
 *       busy:<ms>  recv 回调内 busy-wait 注入（阻塞 tcpip 线程）
 *       xt         应用任务直接调 tcp_new()（跨线程误用·版本一）
 *       xtw        应用任务对在役 PCB 直接 tcp_write()（跨线程误用·版本二）
 *
 * 运行环境：ESP-IDF v6.0.2 + qemu-system-xtensa (Espressif fork)，
 *           -nic user,model=open_eth,hostfwd=tcp::8017-:8017,
 *                hostfwd=tcp::8517-:8517,hostfwd=udp::8027-:8027
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <errno.h>

#include "sdkconfig.h"

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"

#include "esp_log.h"
#include "esp_event.h"
#include "esp_netif.h"
#include "esp_eth.h"
#include "esp_timer.h"
#include "esp_heap_caps.h"

#include "lwip/tcp.h"
#include "lwip/priv/tcp_priv.h"   /* 全局 PCB 链表 extern 与 TCP_TMR_INTERVAL */
#include "lwip/pbuf.h"
#include "lwip/ip_addr.h"
#include "lwip/udp.h"
#include "lwip/tcpip.h"
#include "lwip/err.h"
#include "lwip/stats.h"

#include <sys/socket.h>
#include <netinet/in.h>

static const char *TAG = "ch15lab";

#define PORT_RAW        8017     /* hostfwd tcp::8017-:8017 */
#define PORT_SOCK       8517     /* hostfwd tcp::8517-:8517 */
#define PORT_CTRL_UDP   8027     /* hostfwd udp::8027-:8027 */
#define DHCP_TIMEOUT_MS 10000
#define KEEPALIVE_S     600

static SemaphoreHandle_t s_got_ip;

/* ---------------- 可注入旋钮（除特别注明外只在 tcpip 线程读写） ------------- */
static volatile int      s_busy_ms;     /* recv 回调内的 busy-wait 时长 */
static volatile int      s_leak_eof;    /* 1 = EOF 分支忘记 close */
static uint32_t          s_leak_events; /* 泄漏分支触发次数 */
static uint32_t          s_aborts_ok;   /* ABRT 标记正确终止次数 */
static uint32_t          s_sock_rx;     /* socket 版接收计数（自家任务自增） */
static struct tcp_pcb   *s_probe_pcb;   /* 最近一次 accept 的连接，供 xtw 用 */
static volatile int      s_xt_started[2];

/* -------------------------------- 工具 ------------------------------------ */

static const char *state_str(enum tcp_state s)
{
    switch (s) {
    case CLOSED:       return "CLOSED";
    case LISTEN:       return "LISTEN";
    case SYN_SENT:     return "SYN_SENT";
    case SYN_RCVD:     return "SYN_RCVD";
    case ESTABLISHED:  return "ESTAB";
    case FIN_WAIT_1:   return "FIN_WAIT_1";
    case FIN_WAIT_2:   return "FIN_WAIT_2";
    case CLOSE_WAIT:   return "CLOSE_WAIT";
    case CLOSING:      return "CLOSING";
    case LAST_ACK:     return "LAST_ACK";
    case TIME_WAIT:    return "TIME_WAIT";
    default:           return "?";
    }
}

/* 遍历四条全局链表。仅在 tcpip 线程上下文调用。 */
static void dump_tcp_pcbs(void)
{
    struct tcp_pcb *p;
    int nb = 0, nl = 0, na = 0, nw = 0;

    for (p = tcp_bound_pcbs; p; p = p->next) { nb++; }
    for (p = (struct tcp_pcb *)tcp_listen_pcbs.pcbs; p; p = p->next) { nl++; }
    for (p = tcp_tw_pcbs; p; p = p->next) { nw++; }
    printf("CH15-PCBSUM bound=%d listen=%d tw=%d sizeof(tcp_pcb)=%d "
           "leak_events=%u aborts=%u busy_ms=%d leak_eof=%d\r\n",
           nb, nl, nw, (int)sizeof(struct tcp_pcb),
           (unsigned)s_leak_events, (unsigned)s_aborts_ok,
           s_busy_ms, s_leak_eof);
    for (p = tcp_active_pcbs; p; p = p->next, na++) {
        printf("CH15-PCBACT idx=%d state=%s lport=%u rport=%u sndbuf=%u rcv_wnd=%u ann_wnd=%u\r\n",
               na, state_str(p->state), p->local_port, p->remote_port,
               (unsigned)tcp_sndbuf(p), (unsigned)p->rcv_wnd,
               (unsigned)p->rcv_ann_wnd);
    }
    printf("CH15-PCBDONE active=%d\r\n", na);
}

/* -------------------- raw TCP echo：per-connection 状态机 ------------------ */

#define PEND_MAX 64

typedef struct {
    struct tcp_pcb *pcb;
    struct pbuf *pend[PEND_MAX];  /* 待发队列（环形），收到但没能立即 echo 的单元 */
    int qh, qt;
    u32_t rx_bytes, tx_bytes;
    u8_t fin_seen;                /* recv(p==NULL) 已经来过 */
    u8_t closng;                  /* 决定排空后是否走 close 收尾 */
} es_t;

static void raw_err_cb(void *arg, err_t err);

static int pend_count(const es_t *es) { return es->qt - es->qh; }

static void pend_push(es_t *es, struct pbuf *p)
{
    if (pend_count(es) >= PEND_MAX) {
        printf("CH15-PENFULL lport=%u drop %u bytes\r\n",
               es->pcb->local_port, p->tot_len);
        pbuf_free(p);
        return;
    }
    es->pend[es->qt++ % PEND_MAX] = p;
}

static void pend_free_all(es_t *es)
{
    while (pend_count(es) > 0) {
        pbuf_free(es->pend[es->qh++ % PEND_MAX]);
    }
}

static es_t *es_alloc(struct tcp_pcb *pcb)
{
    es_t *es = calloc(1, sizeof(*es));
    if (es) { es->pcb = pcb; }
    return es;
}

static void es_release_state(es_t *es)
{
    if (s_probe_pcb == es->pcb) { s_probe_pcb = NULL; }
    pend_free_all(es);
    free(es);
}

/* 登出全部回调，之后栈不再经由 pcb 触碰我们的状态 */
static void detatch_callbacks(struct tcp_pcb *pcb)
{
    tcp_arg(pcb, NULL);
    tcp_recv(pcb, NULL);
    tcp_sent(pcb, NULL);
    tcp_err(pcb, NULL);
    tcp_poll(pcb, NULL, 0);
}

/* EOF/错误分支的正确收尾：清状态再交还 PCB 给核心关闭 */
static void close_graceful(struct tcp_pcb *pcb, es_t *es)
{
    printf("CH15-CLOSE lport=%u rx=%u tx=%u (graceful)\r\n",
           pcb->local_port, (unsigned)es->rx_bytes, (unsigned)es->tx_bytes);
    detatch_callbacks(pcb);
    es_release_state(es);
    err_t e = tcp_close(pcb);        /* 半关应答：发 FIN 走 LAST_ACK 一路 */
    if (e != ERR_OK) {
        /* snd_buf 不够放 FIN 时才发生；让核心 TF_CLOSEPEND 机制已不可能——
         * 我们已登出回调，干脆硬终止避免悬挂 */
        printf("CH15-CLOSE-FAIL err=%d -> abort\r\n", e);
        tcp_abort(pcb);
    }
}

/* ABRT 标记路径：先消费数据所有权，再清状态，最后 tcp_abort；返回 ERR_ABRT */
static err_t teardown_abrt(struct tcp_pcb *pcb, es_t *es)
{
    detatch_callbacks(pcb);
    es_release_state(es);
    tcp_abort(pcb);                  /* 本回调内自行调用了 tcp_abort —— 契约前提 */
    return ERR_ABRT;
}

/* 主推进函数：能发则发；排空且见 FIN 则优雅收尾。三个回调的最后一步都汇到这里。 */
static err_t raw_advance(es_t *es)
{
    struct tcp_pcb *pcb = es->pcb;

    while (pend_count(es) > 0) {
        struct pbuf *h = es->pend[es->qh % PEND_MAX];
        if (h->tot_len > tcp_sndbuf(pcb)) {
            break;                    /* 发送缓冲不够：sent 回调会再来叫我们 */
        }
        if (h->tot_len != h->len || h->next != NULL) {
            /* 实验负载 <=1440B 单 pbuf；出现链就保守终止，不给半套假设留门 */
            printf("CH15-PENCHAIN multi-pbuf unit (%u/%u) -> abort\r\n",
                   h->len, h->tot_len);
            detatch_callbacks(pcb);
            es_release_state(es);
            tcp_abort(pcb);
            return ERR_ABRT;          /* 返回值对 sent/poll 回调同样适用契约 */
        }
        err_t err = tcp_write(pcb, h->payload, h->len, TCP_WRITE_FLAG_COPY);
        if (err == ERR_MEM) {
            break;                    /* 同 snd_buf 不足：等下一轮 */
        }
        if (err != ERR_OK) {
            printf("CH15-WRFAIL err=%d -> abort\r\n", err);
            detatch_callbacks(pcb);
            es_release_state(es);
            tcp_abort(pcb);
            return ERR_ABRT;
        }
        es->pend[es->qh++ % PEND_MAX] = NULL;
        es->tx_bytes += h->len;
        /* 数据已在 recv 时 tcp_recved 签收，这里无需再归还窗口 */
    }
    tcp_output(pcb);

    if (pend_count(es) == 0 && es->closng) {
        close_graceful(pcb, es);      /* 之后不得再触碰 es/pcb */
        return ERR_OK;
    }
    return ERR_OK;
}

static err_t raw_recv_cb(void *arg, struct tcp_pcb *pcb, struct pbuf *p, err_t err)
{
    es_t *es = (es_t *)arg;

    /* ---- EOF / 错误分支 ---- */
    if ((err != ERR_OK) || (p == NULL)) {
        if (p != NULL) { pbuf_free(p); }          /* 带错来的数据也不能漏所有权 */
        if (es == NULL) { return ERR_OK; }
        es->fin_seen = 1;
        if (s_leak_eof) {
            s_leak_events++;
            printf("CH15-FIN lport=%u rport=%u leak-mode: 返回 ERR_OK 且不 close"
                   "（教科书式泄漏：PCB 卡在 CLOSE_WAIT）\r\n",
                   pcb->local_port, pcb->remote_port);
            return ERR_OK;                         /* 故意不做任何清理 —— 缺陷现场 */
        }
        printf("CH15-FIN lport=%u rport=%u close-path\r\n",
               pcb->local_port, pcb->remote_port);
        if (pend_count(es) == 0) {
            close_graceful(pcb, es);
        } else {
            es->closng = 1;                       /* 把余货送完再关，交给 advance */
        }
        return ERR_OK;
    }

    if (es == NULL) {                             /* accept 之外的理论防御 */
        pbuf_free(p);
        tcp_abort(pcb);
        return ERR_ABRT;
    }

    /* ---- 故障注入：回调内长时间处理 ---- */
    if (s_busy_ms > 0) {
        int64_t t0 = esp_timer_get_time();
        printf("CH15-BUSY enter %dms rport=%u len=%u rcv_wnd=%u ann=%u\r\n",
               s_busy_ms, pcb->remote_port, p->tot_len,
               (unsigned)pcb->rcv_wnd, (unsigned)pcb->rcv_ann_wnd);
        while ((esp_timer_get_time() - t0) < (int64_t)s_busy_ms * 1000) { }
        printf("CH15-BUSY exit after %lldus rport=%u rcv_wnd=%u ann=%u\r\n",
               (long long)(esp_timer_get_time() - t0), pcb->remote_port,
               (unsigned)pcb->rcv_wnd, (unsigned)pcb->rcv_ann_wnd);
    }

    /* ---- 返回值协议验证标记 ---- */
    if (p->tot_len >= 4 && p->len >= 4 && memcmp(p->payload, "ABRT", 4) == 0) {
        printf("CH15-ABRTMARK lport=%u: 见 ABRT 标记 -> 先释放 pbuf 再 tcp_abort()"
               "+return ERR_ABRT\r\n", pcb->local_port);
        s_aborts_ok++;
        pbuf_free(p);
        return teardown_abrt(pcb, es);
    }

    es->rx_bytes += p->tot_len;
    /* 常规路径：签收数据后原样回写（tcpecho_raw 官方同款次序）。
     * 仅当发送缓冲装不下（ERR_MEM）才退回背压队列，由 sent/poll 驱动补发。 */
    tcp_recved(pcb, p->tot_len);
    err_t werr = tcp_write(pcb, p->payload, p->len, TCP_WRITE_FLAG_COPY);
    if (werr == ERR_OK) {
        es->tx_bytes += p->len;
        tcp_output(pcb);
        pbuf_free(p);
        return ERR_OK;
    }
    printf("CH15-BACKPRESSURE sndbuf=%u len=%u err=%d -> 入队待发\r\n",
           (unsigned)tcp_sndbuf(pcb), p->tot_len, werr);
    pend_push(es, p);
    return raw_advance(es);
}

static err_t raw_sent_cb(void *arg, struct tcp_pcb *pcb, u16_t len)
{
    es_t *es = (es_t *)arg;
    (void)pcb; (void)len;
    if (es == NULL) { return ERR_OK; }
    return raw_advance(es);                       /* ACK 解锁 snd_buf -> 补发/续发 */
}

static err_t raw_poll_cb(void *arg, struct tcp_pcb *pcb)
{
    es_t *es = (es_t *)arg;
    if (es == NULL) {                             /* 孤儿保护：不该发生 */
        tcp_abort(pcb);
        return ERR_ABRT;
    }
    return raw_advance(es);                       /* 兜底泵：防 sent 依赖成死锁 */
}

static void raw_err_cb(void *arg, err_t err)
{
    es_t *es = (es_t *)arg;
    if (es == NULL) { return; }
    /* RST 或意外死亡：pcb 此刻已被核心释放，只剩应用状态要清理 */
    printf("CH15-ERRCB pcb 已被核心释放, arg es=%p err=%d rx=%u tx=%u\r\n",
           (void *)es, err, (unsigned)es->rx_bytes, (unsigned)es->tx_bytes);
    if (s_probe_pcb == es->pcb) { s_probe_pcb = NULL; }
    pend_free_all(es);
    free(es);
}

static err_t raw_accept_cb(void *arg, struct tcp_pcb *newpcb, err_t err)
{
    (void)arg;
    if ((err != ERR_OK) || (newpcb == NULL)) {
        return (err == ERR_OK) ? ERR_ABRT : err;  /* 只在确曾 abort 过时返 ABRT */
    }
    es_t *es = es_alloc(newpcb);
    if (es == NULL) {
        tcp_abort(newpcb);
        return ERR_ABRT;
    }
    tcp_arg(newpcb, es);
    tcp_recv(newpcb, raw_recv_cb);
    tcp_sent(newpcb, raw_sent_cb);
    tcp_err(newpcb, raw_err_cb);
    tcp_poll(newpcb, raw_poll_cb, 4);             /* 每 4 个 slow-tick 兜底一次 */
    s_probe_pcb = newpcb;
    printf("CH15-ACCEPT pcb=%p lport=%u\r\n", (void *)newpcb, newpcb->local_port);
    return ERR_OK;
}

static void raw_echo_start(void)
{
    struct tcp_pcb *pcb = tcp_new_ip_type(IPADDR_TYPE_V4);
    if (pcb == NULL) {
        printf("CH15-SERVER api=raw port=%u tcp_new() NULL\r\n", PORT_RAW);
        return;
    }
    err_t err = tcp_bind(pcb, IP_ANY_TYPE, PORT_RAW);
    if (err != ERR_OK) {
        printf("CH15-SERVER api=raw port=%u bind err=%d\r\n", PORT_RAW, err);
        tcp_close(pcb);
        return;
    }
    struct tcp_pcb *l = tcp_listen_with_backlog(pcb, 4);   /* pcb 从此作废！ */
    if (l == NULL) {
        printf("CH15-SERVER api=raw port=%u listen failed\r\n", PORT_RAW);
        return;
    }
    tcp_accept(l, raw_accept_cb);
    printf("CH15-SERVER api=raw port=%u listening (runs in tcpip thread)\r\n", PORT_RAW);
}

/* --------------------------- socket 版对照组 ------------------------------- */

static void socket_echo_task(void *arg)
{
    struct sockaddr_in la = {
        .sin_family      = AF_INET,
        .sin_port        = htons(PORT_SOCK),
        .sin_addr.s_addr = htonl(INADDR_ANY),
    };

    int ls = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (ls < 0) { goto fail; }
    int opt = 1;
    setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    if (bind(ls, (struct sockaddr *)&la, sizeof(la)) != 0 ||
        listen(ls, 4) != 0) {
        close(ls);
        goto fail;
    }
    printf("CH15-SERVER api=socket port=%u fd=%d listening (task=%s)\r\n",
           PORT_SOCK, ls, pcTaskGetName(NULL));

    static char rx_buf[2048];
    while (1) {
        int c = accept(ls, NULL, NULL);
        if (c < 0) { continue; }
        printf("CH15-SOCK-OPEN fd=%d\r\n", c);
        ssize_t n;
        while ((n = recv(c, rx_buf, sizeof(rx_buf), 0)) > 0) {
            s_sock_rx += (uint32_t)n;
            send(c, rx_buf, n, 0);
        }
        close(c);
        printf("CH15-SOCK-CLOSE fd=%d\r\n", c);
    }
fail:
    printf("CH15-SERVER api=socket FAILED errno=%d\r\n", errno);
    vTaskDelete(NULL);
}

/* ------------------------------ 跨线程误用 -------------------------------- */

static void wild_new_task(void *a)
{
    (void)a;
    vTaskDelay(pdMS_TO_TICKS(30));
    printf("CH15-XT BEGIN task=%s （非 tcpip 上下文直接调 tcp_new()）\r\n",
           pcTaskGetName(NULL));
    int n = 0;
    while (n < 20000) {
        struct tcp_pcb *p = tcp_new();            /* 非法上下文！ */
        n++;
        if (p != NULL && tcp_close(p) != ERR_OK) {
            /* tcp_close 同样非法上下文；关闭失败仅计数 */
        }
        if ((n % 2000) == 0) {
            printf("CH15-XT n=%d 仍存活\r\n", n);
        }
    }
    printf("CH15-XT END 存活 %d 次（CHECK_THREAD_SAFETY 未开时可能无感）\r\n", n);
    vTaskDelete(NULL);
}

static void wild_write_task(void *a)
{
    (void)a;
    vTaskDelay(pdMS_TO_TICKS(100));
    struct tcp_pcb *t = s_probe_pcb;              /* 故意无同步地抓取指针 */
    if (t == NULL) {
        printf("CH15-XTW 无在役连接可打：先让主机连上 %d 再发 xtw\r\n", PORT_RAW);
        vTaskDelete(NULL);
        return;
    }
    printf("CH15-XTW BEGIN 对在役 PCB %p 非法 tcp_write()\r\n", (void *)t);
    char buf[40];
    memset(buf, 'X', sizeof(buf));
    int i = 0;
    TickType_t deadline = xTaskGetTickCount() + pdMS_TO_TICKS(5000);
    while (xTaskGetTickCount() < deadline) {
        tcp_write(t, buf, sizeof(buf), TCP_WRITE_FLAG_COPY);   /* 非法上下文！ */
        i++;
        if ((i % 200) == 0) { vTaskDelay(1); }
        if ((i % 4000) == 0) {
            printf("CH15-XTW i=%d 仍存活\r\n", i);
        }
    }
    printf("CH15-XTW END 共 %d 次越权写入完成（后果未定义）\r\n", i);
    vTaskDelete(NULL);
}

/* -------------------------------- 控制口 ----------------------------------- */

static struct udp_pcb *s_ctrl_pcb;

static void ctrl_ack(const char *msg, const ip_addr_t *addr, u16_t port)
{
    struct pbuf *q = pbuf_alloc(PBUF_TRANSPORT, strlen(msg), PBUF_RAM);
    if (q) {
        memcpy(q->payload, msg, strlen(msg));
        udp_sendto(s_ctrl_pcb, q, addr, port);
        pbuf_free(q);
    }
}

static void ctrl_recv_cb(void *arg, struct udp_pcb *pcb, struct pbuf *p,
                         const ip_addr_t *addr, u16_t port)
{
    (void)arg;
    if (!p) { return; }
    char cmd[32] = {0};
    size_t len = p->len < sizeof(cmd) - 1 ? p->len : sizeof(cmd) - 1;
    memcpy(cmd, p->payload, len);

    if (!strncmp(cmd, "st", 2)) {
        printf("CH15-ST leaks=%u aborts=%u sock_rx=%u busy=%d leak_eof=%d "
               "tcp.memerr=%u tcp.drop=%u\r\n",
               (unsigned)s_leak_events, (unsigned)s_aborts_ok,
               (unsigned)s_sock_rx, s_busy_ms, s_leak_eof,
               (unsigned)lwip_stats.tcp.memerr,
               (unsigned)lwip_stats.tcp.drop);
        dump_tcp_pcbs();
        ctrl_ack("ACK st", addr, port);
    } else if (!strncmp(cmd, "leak:on", 7)) {
        s_leak_eof = 1;
        printf("CH15-MODE leak:on -- EOF 将忘记 close\r\n");
        ctrl_ack("ACK leak:on", addr, port);
    } else if (!strncmp(cmd, "leak:off", 8)) {
        s_leak_eof = 0;
        printf("CH15-MODE leak:off -- EOF 走正确关闭\r\n");
        ctrl_ack("ACK leak:off", addr, port);
    } else if (!strncmp(cmd, "busy:", 5)) {
        s_busy_ms = atoi(cmd + 5);
        if (s_busy_ms < 0)   { s_busy_ms = 0; }
        if (s_busy_ms > 1000){ s_busy_ms = 1000; }
        printf("CH15-MODE busy=%dms（tcpip 线程每包加价）\r\n", s_busy_ms);
        ctrl_ack("ACK busy", addr, port);
    } else if (!strcmp(cmd, "xt")) {
        if (!s_xt_started[0]++) {
            BaseType_t ok = xTaskCreate(wild_new_task, "ch15_xt", 2048, NULL, 12, NULL);
            printf("CH15-CMD xt spawn=%ld\r\n", (long)ok);
        } else {
            printf("CH15-CMD xt already\r\n");
        }
        ctrl_ack("ACK xt", addr, port);
    } else if (!strcmp(cmd, "xtw")) {
        if (!s_xt_started[1]++) {
            BaseType_t ok = xTaskCreate(wild_write_task, "ch15_xtw", 2048, NULL, 12, NULL);
            printf("CH15-CMD xtw spawn=%ld\r\n", (long)ok);
        } else {
            printf("CH15-CMD xtw already\r\n");
        }
        ctrl_ack("ACK xtw", addr, port);
    } else {
        printf("CH15-CMD unknown '%s'\r\n", cmd);
        ctrl_ack("ACK ?", addr, port);
    }
    pbuf_free(p);
}

static void ctrl_start(void)
{
    s_ctrl_pcb = udp_new();
    if (s_ctrl_pcb && udp_bind(s_ctrl_pcb, IP_ANY_TYPE, PORT_CTRL_UDP) == ERR_OK) {
        udp_recv(s_ctrl_pcb, ctrl_recv_cb, NULL);
        printf("CH15-SERVER ctrl port=%u started\r\n", PORT_CTRL_UDP);
    }
}

/* ------------------------------ FACT 与心跳 -------------------------------- */

static void print_facts(void)
{
    printf("CH15-FACT sizeof(struct tcp_pcb)=%d MSS=%d WND=%d SND_BUF=%d "
           "TCPIP_RECVMBOX=%d MAX_ACTIVE_TCP=%d SLOW_TMR=%d FAST_TMR=%d "
           "CHECK_THREAD_SAFETY=%d CORE_LOCKING=%d\r\n",
           (int)sizeof(struct tcp_pcb), TCP_MSS, TCP_WND, TCP_SND_BUF,
           CONFIG_LWIP_TCPIP_RECVMBOX_SIZE, CONFIG_LWIP_MAX_ACTIVE_TCP,
           TCP_TMR_INTERVAL, TCP_FAST_INTERVAL,
#if defined(CONFIG_LWIP_CHECK_THREAD_SAFETY) && CONFIG_LWIP_CHECK_THREAD_SAFETY
           1,
#else
           0,
#endif
#ifdef CONFIG_LWIP_TCPIP_CORE_LOCKING
           1
#else
           0
#endif
           );
}

/* 心跳展示正确范式：应用任务不在 tcpip 上下文，改经 tcpip_callback 投递观察器 */
static void hb_in_stack(void *ctx)
{
    (void)ctx;
    int na = 0;
    for (struct tcp_pcb *p = tcp_active_pcbs; p; p = p->next) { na++; }
    printf("CH15-HB active=%d leaks=%u aborts=%u sock_rx=%u busy=%d leak_eof=%d\r\n",
           na, (unsigned)s_leak_events, (unsigned)s_aborts_ok,
           (unsigned)s_sock_rx, s_busy_ms, s_leak_eof);
#if MEM_STATS
    printf("CH15-HEAP free=%u low=%u lfb=%u mem.used=%u mem.max=%u mem.err=%u\r\n",
           (unsigned)heap_caps_get_free_size(MALLOC_CAP_8BIT),
           (unsigned)heap_caps_get_minimum_free_size(MALLOC_CAP_8BIT),
           (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_8BIT),
           (unsigned)lwip_stats.mem.used, (unsigned)lwip_stats.mem.max,
           (unsigned)lwip_stats.mem.err);
#else
    printf("CH15-HEAP free=%u low=%u lfb=%u (MEM_STATS 编译期关闭)\r\n",
           (unsigned)heap_caps_get_free_size(MALLOC_CAP_8BIT),
           (unsigned)heap_caps_get_minimum_free_size(MALLOC_CAP_8BIT),
           (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_8BIT));
#endif
}

/* ------------------------------ bring-up ----------------------------------- */

static void ip_event_handler(void *arg, esp_event_base_t base,
                             int32_t event_id, void *event_data)
{
    ip_event_got_ip_t *evt = (ip_event_got_ip_t *)event_data;
    ESP_LOGI(TAG, "GOT_IP: " IPSTR, IP2STR(&evt->ip_info.ip));
    xSemaphoreGive(s_got_ip);
}

static void eth_event_handler(void *arg, esp_event_base_t base,
                              int32_t event_id, void *event_data)
{
    ESP_LOGI(TAG, "ETH_EVENT id=%ld", (long)event_id);
}

void app_main(void)
{
    ESP_LOGI(TAG, "== ch15 lab: raw tcp callbacks / retval protocol / faults ==");

    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    s_got_ip = xSemaphoreCreateBinary();

    esp_netif_config_t netif_cfg = ESP_NETIF_DEFAULT_ETH();
    esp_netif_t *eth_netif = esp_netif_new(&netif_cfg);

    eth_mac_config_t mac_cfg = ETH_MAC_DEFAULT_CONFIG();
    eth_phy_config_t phy_cfg = ETH_PHY_DEFAULT_CONFIG();
    phy_cfg.reset_gpio_num      = -1;
    phy_cfg.autonego_timeout_ms = 3000;

    esp_eth_mac_t *mac = esp_eth_mac_new_openeth(&mac_cfg);
    esp_eth_phy_t *phy = esp_eth_phy_new_generic(&phy_cfg);
    esp_eth_config_t eth_cfg = ETH_DEFAULT_CONFIG(mac, phy);
    esp_eth_handle_t eth_handle = NULL;
    ESP_ERROR_CHECK(esp_eth_driver_install(&eth_cfg, &eth_handle));

    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_ETH_GOT_IP,
                                               &ip_event_handler, NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(ETH_EVENT, ESP_EVENT_ANY_ID,
                                               &eth_event_handler, NULL));

    esp_eth_netif_glue_handle_t glue = esp_eth_new_netif_glue(eth_handle);
    ESP_ERROR_CHECK(esp_netif_attach(eth_netif, glue));
    ESP_ERROR_CHECK(esp_eth_start(eth_handle));

    if (xSemaphoreTake(s_got_ip, pdMS_TO_TICKS(DHCP_TIMEOUT_MS)) != pdTRUE) {
        ESP_LOGE(TAG, "DHCP timeout -- aborting");
        return;
    }

    print_facts();

    ctrl_start();
    raw_echo_start();
    xTaskCreate(socket_echo_task, "ch15_sock", 4096, NULL, 5, NULL);

    printf("CH15-READY raw=%d sock=%d ctrl_udp=%d keepalive=%ds\r\n",
           PORT_RAW, PORT_SOCK, PORT_CTRL_UDP, KEEPALIVE_S);

    for (int i = 0; i < KEEPALIVE_S / 5; i++) {
        vTaskDelay(pdMS_TO_TICKS(5000));
        if (tcpip_callback(hb_in_stack, NULL) == ERR_OK) {
            /* 心跳已在 tcpip 线程内打印 */
        }
    }
    printf("CH15-BYE\r\n");
}
