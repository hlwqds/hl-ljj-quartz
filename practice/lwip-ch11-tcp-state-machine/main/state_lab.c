/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * lwIP 深度解析（十一）实验工程：TCP 状态机观测台
 *
 * 在 ch3 联网模板之上新增四件套：
 *   1. PCB 观测器：tcpip_callback 周期遍历 bound/listen/active/time-wait
 *      四条全局链表，打印状态直方图、非 ESTABLISHED PCB 明细与 TIME_WAIT 年龄；
 *   2. 双模式演示服务器 :8814 —— PASSIVE(被动关闭)/ACTIVE(主动关闭 =
 *      半关闭 shutdown(WR))；每条 accepted 连接都打开 keepalive；
 *   3. 控制通道 :8813 —— 主机脚本切换模式 / 调观测周期 / 下发故障注入 /
 *      触发 guest 出向短连接风暴（实验 b）；
 *   4. 入向故障注入：拿到 lwip netif 后替换 netif->input（ch12 同款手法），
 *      可静默吞掉指定流的入向段（制造真·半打开），或吞掉去往 :8814 的
 *      纯 ACK 第三次握手（把连接冻结在 SYN_RCVD，制造半连接积压）。
 *
 * 运行环境：ESP-IDF v6.0.2 + qemu-system-xtensa，
 *           -nic user,model=open_eth,hostfwd=tcp::8014-:8814
 */

#include <stdio.h>
#include <string.h>
#include <strings.h>
#include <stdlib.h>
#include <errno.h>
#include <unistd.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"

#include "esp_log.h"
#include "esp_event.h"
#include "esp_netif.h"
#include "esp_eth.h"
#include "esp_timer.h"

#include "lwip/sockets.h"
#include "lwip/tcpip.h"
#include "lwip/tcp.h"
#include "lwip/priv/tcp_priv.h"   /* 全局 PCB 链表、tcp_ticks、TCP_SLOW_INTERVAL */
#include "lwip/stats.h"
#include "lwip/netif.h"
#include "lwip/pbuf.h"
#include "lwip/inet.h"

/* 编译期注入的 IP4 输入 hook（同时被强制包含进 lwIP 组件本身） */
#include "ch11_ip4_hook.h"

static const char *TAG = "ch11lab";

#define GUEST_CTRL_PORT  8813      /* 控制通道（guest 内部约定）          */
#define GUEST_DEMO_PORT  8814      /* 演示服务器：hostfwd=tcp::8014-:8814 */

/* ------------------------- 全局状态 ------------------------- */

static SemaphoreHandle_t s_got_ip;
static esp_netif_t      *s_netif;

enum srv_mode { SRV_PASSIVE = 0, SRV_ACTIVE = 1 };
static volatile int      s_srv_mode     = SRV_PASSIVE;
static volatile uint32_t s_obs_period_ms = 1000;
static volatile int      s_gw_target_port = 8714;

/* ---- 故障注入策略（tcpip 线程的 netif->input 与控制任务共享）---- */
static volatile int       s_drop_handshake_ack; /* 1=吞掉去往 8814 的纯 ACK 第三次握手 */
enum vict_phase { VIC_IDLE = 0, VIC_ARMED = 1, VIC_CAPTURED = 2, VIC_FIRED = 3 };
static volatile int       s_victim_phase;       /* 受害流两阶段门控                    */
static volatile uint32_t  s_victim_ip;          /* 主机序，仅用于比对与打印            */
static volatile uint16_t  s_victim_port;

static const char *g_state_name[] = {
    "CLOSED", "LISTEN", "SYN_SENT", "SYN_RCVD", "ESTABLISHED",
    "FIN_WAIT_1", "FIN_WAIT_2", "CLOSE_WAIT", "CLOSING", "LAST_ACK", "TIME_WAIT"
};

static uint64_t ms_now(void) { return (uint64_t)(esp_timer_get_time() / 1000ULL); }

/* 入参为主机序 32 位地址（便于与 lwip_ntohl 后的比较值直接复用） */
static void fmt_ip(char out[16], uint32_t ho_addr)
{
    snprintf(out, 16, "%u.%u.%u.%u",
             (unsigned)((ho_addr >> 24) & 0xffU), (unsigned)((ho_addr >> 16) & 0xffU),
             (unsigned)((ho_addr >> 8) & 0xffU), (unsigned)(ho_addr & 0xffU));
}

/* ------------------------- 故障注入过滤器 ------------------------- */
/*
 * LWIP_HOOK_IP4_INPUT 的实现（宏由 ch11_ip4_hook.h 注入 ip4.c 调用点）。
 * 运行在 tcpip 线程、ip_input() 入口处——比 netif->input 更靠近协议栈，
 * esp_netif/openeth 的收包路径一定会经过这里。
 * 语义见 opt.h：返回非 0 = hook 已消费该 pbuf（所有权移交，必须自己释放）；
 * 返回 0 = 放行，协议栈继续正常处理。
 */
int ch11_ip4_input_hook(struct pbuf *p, struct netif *inp)
{
    uint8_t hdr[80];
    struct tcp_hdr th;
    uint16_t sport, dport, tflags, seglen;

    (void)inp;
    if (p == NULL || p->len < 1 || p->tot_len < 40) return 0;

    /* 只认 IPv4；IHL 先从首个字节读出，再精确拷贝 ihl+20 字节（SYN 常见
     * tot_len=54，不足 sizeof(hdr)，绝不能要求整块拷满）。 */
    {
        const uint8_t *b0 = (const uint8_t *)p->payload;
        if ((b0[0] >> 4) != 4) return 0;
        uint8_t ihl = (uint8_t)((b0[0] & 0x0f) * 4);
        if (ihl < 20 || p->tot_len < (u16_t)(ihl + 20)) return 0;
        uint16_t need = (uint16_t)(ihl + 20);
        if (pbuf_copy_partial(p, hdr, need, 0) != need) return 0;
        if (hdr[9] != 6 /* TCP */) return 0;
        memcpy(&th, hdr + ihl, sizeof(th));
    }
    sport  = lwip_ntohs(th.src);
    dport  = lwip_ntohs(th.dest);
    tflags = TCPH_FLAGS(&th);
    /* 可用载荷 = IPv4 头里的 Total-Length 字段 - IPv4 头 - TCP 头。
     * 不能用 p->tot_len：openeth 收包路径会把以太网填充一起算进来，
     * 曾观察到纯 ACK 的 p->tot_len 比 IP 总长多 10 字节的案例。 */
    {
        uint16_t iph_tot = (uint16_t)(((uint16_t)hdr[2] << 8) | hdr[3]);
        uint8_t tcphlen_b = (uint8_t)TCPH_HDRLEN_BYTES(&th);
        uint8_t ihl_b = (uint8_t)((hdr[0] & 0x0f) * 4);
        if (tcphlen_b < 20 || iph_tot < (uint16_t)(tcphlen_b + ihl_b)) return 0;
        seglen = (uint16_t)(iph_tot - (uint16_t)(tcphlen_b + ihl_b));
    }

    /* 规则 R2：冻结第三次握手。丢掉去往 :8814 的纯 ACK（无载荷、无 SYN/FIN/RST/PSH），
     * 连接停在 SYN_RCVD —— 半连接积压实验。 */
    if (s_drop_handshake_ack && dport == GUEST_DEMO_PORT &&
        tflags == TCP_ACK && seglen == 0) {
        ESP_LOGW(TAG, "INJECT drop ACK3 %u->%u", sport, dport);
        pbuf_free(p);
        return 1;                                  /* consumed */
    }
    /* 诊断：FREEZE 期间打印去往 8814 段的 IPv4 总长与 TCP 头 12/13 字节原文 */
    if (s_drop_handshake_ack && dport == GUEST_DEMO_PORT &&
        (tflags & TCP_SYN) == 0 && p->tot_len <= 2000U) {
        uint8_t off_byte = hdr[(uint8_t)((hdr[0] & 0x0f) * 4) + 12];
        uint8_t flg_byte = hdr[(uint8_t)((hdr[0] & 0x0f) * 4) + 13];
        ESP_LOGI(TAG, "DBG seg %u->%u p->tot=%u iph_tot=%u off_b=%u flg=0x%02x",
                 sport, dport, (unsigned)p->tot_len,
                 (unsigned)(((uint16_t)hdr[2] << 8) | hdr[3]),
                 (unsigned)(off_byte >> 4), (unsigned)(flg_byte));
    }

    /* 规则 R1：受害流捕获与吞没（两阶段）：
     *   CAPTURE —— 武装后第一条到 :8814 的初始 SYN 记为受害元组并放行；
     *   SWALLOW —— VICTFIRE 后该元组的全部入向段（应答/FIN/RST）静默丢弃。 */
    if (dport == GUEST_DEMO_PORT &&
        (s_victim_phase == VIC_ARMED || s_victim_phase >= VIC_CAPTURED)) {
        /* 源 IP 从 IPv4 头取（TCP 头里只有端口！） */
        uint32_t sip_ho = ((uint32_t)hdr[12] << 24) | ((uint32_t)hdr[13] << 16) |
                          ((uint32_t)hdr[14] << 8) | (uint32_t)hdr[15];
        if (s_victim_phase == VIC_ARMED && (tflags & TCP_SYN) && !(tflags & TCP_ACK)) {
            s_victim_ip = sip_ho;
            s_victim_port = sport;
            s_victim_phase = VIC_CAPTURED;
            char ipb[16]; fmt_ip(ipb, sip_ho);
            ESP_LOGW(TAG, "INJECT victim captured %s:%u (waiting FIRE)", ipb, sport);
        } else if (s_victim_phase == VIC_FIRED &&
                   sip_ho == s_victim_ip && sport == s_victim_port) {
            char ipb[16]; fmt_ip(ipb, sip_ho);
            ESP_LOGW(TAG, "INJECT swallow inbound %s:%u flags=0x%x len=%u",
                     ipb, sport, tflags, seglen);
            pbuf_free(p);
            return 1;                              /* consumed */
        }
    }
    return 0;                                      /* not consumed */
}

static void install_fault_injector(void)
{
    /* hook 宏在编译期已挂进 ip4.c，这里只做存在性提示 */
    ESP_LOGI(TAG, "fault injector compiled in: LWIP_HOOK_IP4_INPUT -> ch11_ip4_input_hook");
}

/* ------------------------- PCB 观测器 ------------------------- */

/* tcpip_callback 投递到 tcpip 线程执行，对全局链表的遍历天然互斥 */
static void pcb_snapshot_cb(void *arg)
{
    char ipb[16];
    int hist[11] = {0};
    int n_act = 0, n_tw = 0, n_ls = 0, n_bd = 0, n_detail = 0;
    unsigned memerr = 0;
    struct tcp_pcb *pcb;
    struct tcp_pcb_listen *lp;

#if LWIP_STATS
    memerr = (unsigned)lwip_stats.tcp.memerr;
#endif

    for (pcb = tcp_bound_pcbs; pcb; pcb = pcb->next) n_bd++;
    for (lp = tcp_listen_pcbs.listen_pcbs; lp; lp = lp->next) n_ls++;
    for (pcb = tcp_active_pcbs; pcb; pcb = pcb->next) {
        if (pcb->state >= CLOSED && pcb->state <= TIME_WAIT) hist[pcb->state]++;
        n_act++;
    }
    for (pcb = tcp_tw_pcbs; pcb; pcb = pcb->next) { hist[TIME_WAIT]++; n_tw++; }

    printf("PCBS t=%llu BND=%d LIST=%d ACT=%d TW=%d | SYNRCVD=%d EST=%d FINW1=%d FINW2=%d CWAIT=%d CLOSING=%d LASTACK=%d MEMERR=%u\n",
           (unsigned long long)ms_now(), n_bd, n_ls, n_act, n_tw,
           hist[SYN_RCVD], hist[ESTABLISHED], hist[FIN_WAIT_1], hist[FIN_WAIT_2],
           hist[CLOSE_WAIT], hist[CLOSING], hist[LAST_ACK], memerr);

    /* 非 ESTABLISHED 的活动 PCB 明细（最多 6 条）+ TIME_WAIT 样本（带年龄） */
    for (pcb = tcp_active_pcbs; pcb && n_detail < 6; pcb = pcb->next) {
        if (pcb->state == ESTABLISHED || !IP_IS_V4_VAL(pcb->remote_ip)) continue;
        fmt_ip(ipb, lwip_ntohl(ip_2_ip4(&pcb->remote_ip)->addr));
        printf("PCBD t=%llu %-11s rmt=%s:%u lport=%u age_ms=%u\n",
               (unsigned long long)ms_now(), g_state_name[pcb->state],
               ipb, pcb->remote_port, pcb->local_port,
               (unsigned)((tcp_ticks - pcb->tmr) * TCP_SLOW_INTERVAL));
        n_detail++;
    }
    for (pcb = tcp_tw_pcbs; pcb && n_detail < 8; pcb = pcb->next) {
        if (!IP_IS_V4_VAL(pcb->remote_ip)) continue;
        fmt_ip(ipb, lwip_ntohl(ip_2_ip4(&pcb->remote_ip)->addr));
        printf("PCBD t=%llu TIME_WAIT   rmt=%s:%u lport=%u age_ms=%u\n",
               (unsigned long long)ms_now(), ipb, pcb->remote_port, pcb->local_port,
               (unsigned)((tcp_ticks - pcb->tmr) * TCP_SLOW_INTERVAL));
        n_detail++;
    }
}

static void observer_task(void *arg)
{
    while (1) {
        tcpip_callback(pcb_snapshot_cb, NULL);
        vTaskDelay(pdMS_TO_TICKS(s_obs_period_ms));
    }
}

/* ------------------------- 演示服务器 :8814 ------------------------- */

static void apply_keepalive(int fd)
{
    int en = 1;
    int idle_s = 5, intvl_s = 2, cnt = 3;   /* sockets 层单位是秒（内部 x1000 转 ms）*/
    setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &en, sizeof(en));
    setsockopt(fd, IPPROTO_TCP, TCP_KEEPIDLE, &idle_s, sizeof(idle_s));
    setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, &intvl_s, sizeof(intvl_s));
    setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT, &cnt, sizeof(cnt));
}

static void demo_server_task(void *arg)
{
    char rx_buf[512];

    int listen_sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    configASSERT(listen_sock >= 0);
    int opt = 1;
    setsockopt(listen_sock, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in la = {
        .sin_family = AF_INET,
        .sin_port = htons(GUEST_DEMO_PORT),
        .sin_addr.s_addr = htonl(INADDR_ANY),
    };
    configASSERT(bind(listen_sock, (struct sockaddr *)&la, sizeof(la)) == 0);
    listen(listen_sock, 4);
    ESP_LOGI(TAG, "demo server listening 0.0.0.0:%d mode=%s",
             GUEST_DEMO_PORT, s_srv_mode == SRV_ACTIVE ? "ACTIVE" : "PASSIVE");

    while (1) {
        struct sockaddr_in sa; socklen_t sl = sizeof(sa);
        int conn = accept(listen_sock, (struct sockaddr *)&sa, &sl);
        if (conn < 0) continue;
        apply_keepalive(conn);
        ESP_LOGI(TAG, "srv accepted fd=%d peer=%s:%u", conn,
                 inet_ntoa(sa.sin_addr), ntohs(sa.sin_port));

        if (s_srv_mode == SRV_PASSIVE) {
            /* 被动关闭线：先 echo 服务；对端 FIN 到达（recv==0）之后才 close */
            int len;
            while ((len = recv(conn, rx_buf, sizeof(rx_buf), 0)) > 0) {
                ESP_LOGI(TAG, "srv PASSIVE recv %d bytes", len);
                send(conn, rx_buf, len, 0);
            }
            if (len == 0)
                ESP_LOGW(TAG, "srv PASSIVE got FIN(clean EOF) -> CLOSE_WAIT; linger 600ms");
            else
                ESP_LOGW(TAG, "srv PASSIVE recv ABORTED len=%d errno=%d (keepalive timeout path)", len, errno);
            vTaskDelay(pdMS_TO_TICKS(600));  /* 给观察器留出抓拍 CLOSE_WAIT 的窗口 */
            close(conn);                      /* CLOSE_WAIT -> LAST_ACK -> CLOSED */
            ESP_LOGI(TAG, "srv PASSIVE closed fd=%d", conn);
        } else {
            /* 主动关闭线（半关闭演示）：立即 shutdown(SHUT_WR) 发 FIN 并继续读，
             * 直到对端 FIN 到达再 close —— FIN_WAIT_1/FIN_WAIT_2/TIME_WAIT 全序列 */
            const char *hi = "CH11-ACTIVE-CLOSE\r\n";
            send(conn, hi, strlen(hi), 0);
            shutdown(conn, SHUT_WR);
            ESP_LOGI(TAG, "srv ACTIVE sent greeting + FIN (shutdown WR)");
            int len;
            while ((len = recv(conn, rx_buf, sizeof(rx_buf), 0)) > 0) {
                ESP_LOGI(TAG, "srv ACTIVE recv %d bytes after our FIN", len);
            }
            ESP_LOGI(TAG, "srv ACTIVE peer FIN arrived (recv=%d errno=%d), closing", len, errno);
            close(conn);
            ESP_LOGI(TAG, "srv ACTIVE closed fd=%d", conn);
        }
    }
}

/* ------------------------- guest 出向短连接发生器（实验 b）------------------------- */

static void gw_burst_task(void *arg)
{
    int n = (int)(intptr_t)arg;
    int port = s_gw_target_port;

    for (int i = 0; i < n; i++) {
        int fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (fd < 0) { ESP_LOGE(TAG, "GW[%d] socket fail errno=%d", i, errno); break; }
        struct timeval tv = { .tv_sec = 2, .tv_usec = 0 };
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

        struct sockaddr_in ra = {
            .sin_family = AF_INET,
            .sin_port = htons((uint16_t)port),
        };
        inet_aton("10.0.2.2", &ra.sin_addr);

        if (connect(fd, (struct sockaddr *)&ra, sizeof(ra)) != 0) {
            ESP_LOGE(TAG, "GW[%d] connect 10.0.2.2:%d fail errno=%d", i, port, errno);
            close(fd);
            break;
        }
        char req[24], resp[64];
        int rl = snprintf(req, sizeof(req), "PING%03d\n", i);
        send(fd, req, rl, 0);
        int got = recv(fd, resp, sizeof(resp) - 1, 0);
        if (got > 0) resp[(got < 63 ? got : 63)] = 0;
        close(fd);   /* 客户端主动关闭：guest 进 TIME_WAIT 的关键 */
        ESP_LOGI(TAG, "GW[%d] req=%.*s ack=%.*s", i, rl, req,
                 got > 0 ? got : 0, got > 0 ? resp : "-");
        vTaskDelay(pdMS_TO_TICKS(120));
    }
    ESP_LOGI(TAG, "GW burst finished (%d conns -> 10.0.2.2:%d)", n, port);
    vTaskDelete(NULL);
}

/* ------------------------- 控制通道 :8813 ------------------------- */

static void ctrl_task(void *arg)
{
    char buf[96];

    int ls = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    configASSERT(ls >= 0);
    int opt = 1;
    setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    struct sockaddr_in la = {
        .sin_family = AF_INET,
        .sin_port = htons(GUEST_CTRL_PORT),
        .sin_addr.s_addr = htonl(INADDR_ANY),
    };
    configASSERT(bind(ls, (struct sockaddr *)&la, sizeof(la)) == 0);
    listen(ls, 2);
    ESP_LOGI(TAG, "ctrl listening :%d (STANDBY)", GUEST_CTRL_PORT);

    while (1) {
        int fd = accept(ls, NULL, NULL);
        if (fd < 0) continue;
        int len = recv(fd, buf, sizeof(buf) - 1, 0);
        if (len <= 0) { close(fd); continue; }
        buf[len] = 0;
        for (char *c = buf; c < buf + len; c++) if (*c == '\r' || *c == '\n') { *c = 0; }

        if (!strncasecmp(buf, "MODE ", 5)) {
            s_srv_mode = !strncasecmp(buf + 5, "ACTIVE", 6) ? SRV_ACTIVE : SRV_PASSIVE;
            send(fd, "OK\n", 3, 0);
        } else if (!strncasecmp(buf, "OBS ", 4)) {
            uint32_t v = (uint32_t)atoi(buf + 4);
            s_obs_period_ms = v < 50 ? 50 : v;
            send(fd, "OK\n", 3, 0);
        } else if (!strncasecmp(buf, "GW ", 3)) {
            int n = atoi(buf + 3);
            const char *pp = strchr(buf + 3, ' ');
            if (pp) s_gw_target_port = atoi(pp + 1);
            if (n > 0 && n <= 200 &&
                xTaskCreate(gw_burst_task, "gw", 3584, (void *)(intptr_t)n, 5, NULL) == pdTRUE)
                send(fd, "OK\n", 3, 0);
            else
                send(fd, "ERR\n", 4, 0);
        } else if (!strncasecmp(buf, "VICTARM", 7)) {
            s_victim_ip = 0; s_victim_port = 0;
            s_victim_phase = VIC_ARMED;
            send(fd, "OK armed\n", 9, 0);
        } else if (!strncasecmp(buf, "VICTFIRE", 8)) {
            if (s_victim_phase != VIC_CAPTURED) send(fd, "ERR no-victim\n", 14, 0);
            else { s_victim_phase = VIC_FIRED; send(fd, "OK fired\n", 9, 0); }
        } else if (!strncasecmp(buf, "FREEZE ", 7)) {
            s_drop_handshake_ack = !strncasecmp(buf + 7, "ON", 2);
            send(fd, s_drop_handshake_ack ? "OK frozen\n" : "OK thawed\n", 10, 0);
        } else if (!strncasecmp(buf, "STAT", 4)) {
            char out[128];
#if LWIP_STATS
            int ml = snprintf(out, sizeof(out),
                    "STAT recv=%u xmit=%u drop=%u chkerr=%u lenerr=%u memerr=%u\n",
                    (unsigned)lwip_stats.tcp.recv, (unsigned)lwip_stats.tcp.xmit,
                    (unsigned)lwip_stats.tcp.drop, (unsigned)lwip_stats.tcp.chkerr,
                    (unsigned)lwip_stats.tcp.lenerr, (unsigned)lwip_stats.tcp.memerr);
#else
            int ml = snprintf(out, sizeof(out), "STAT disabled\n");
#endif
            send(fd, out, ml, 0);
        } else {
            send(fd, "ERR unknown\n", 12, 0);
        }
        close(fd);
    }
}

/* ------------------------- 以太网事件（ch3 模板骨架）------------------------- */

static void eth_event_handler(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    switch (id) {
    case ETHERNET_EVENT_CONNECTED:    ESP_LOGI(TAG, "ETH connected"); break;
    case ETHERNET_EVENT_DISCONNECTED: ESP_LOGI(TAG, "ETH disconnected"); break;
    default: break;
    }
}

static void ip_event_handler(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    ip_event_got_ip_t *evt = (ip_event_got_ip_t *)data;
    ESP_LOGI(TAG, "GOT_IP " IPSTR, IP2STR(&evt->ip_info.ip));
    xSemaphoreGive(s_got_ip);
}

/* ------------------------- app_main ------------------------- */

void app_main(void)
{
    ESP_LOGI(TAG, "== ch11 lab: TCP state machine observatory ==");
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    s_got_ip = xSemaphoreCreateBinary();

    esp_netif_config_t nc = ESP_NETIF_DEFAULT_ETH();
    s_netif = esp_netif_new(&nc);

    eth_mac_config_t mc = ETH_MAC_DEFAULT_CONFIG();
    eth_phy_config_t pc = ETH_PHY_DEFAULT_CONFIG();
    pc.reset_gpio_num = -1;
    pc.autonego_timeout_ms = 3000;

    esp_eth_mac_t *mac = esp_eth_mac_new_openeth(&mc);
    configASSERT(mac != NULL);
    esp_eth_phy_t *phy = esp_eth_phy_new_generic(&pc);
    configASSERT(phy != NULL);

    esp_eth_config_t ec = ETH_DEFAULT_CONFIG(mac, phy);
    esp_eth_handle_t eth = NULL;
    ESP_ERROR_CHECK(esp_eth_driver_install(&ec, &eth));

    ESP_ERROR_CHECK(esp_event_handler_register(ETH_EVENT, ESP_EVENT_ANY_ID, &eth_event_handler, NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_ETH_GOT_IP, &ip_event_handler, NULL));

    esp_eth_netif_glue_handle_t glue = esp_eth_new_netif_glue(eth);
    ESP_ERROR_CHECK(esp_netif_attach(s_netif, glue));

    ESP_ERROR_CHECK(esp_eth_start(eth));
    ESP_LOGI(TAG, "waiting DHCP ...");
    if (xSemaphoreTake(s_got_ip, pdMS_TO_TICKS(15000)) != pdTRUE) {
        ESP_LOGE(TAG, "DHCP timeout");
        return;
    }

    install_fault_injector();

    xTaskCreate(demo_server_task, "demo_srv", 4096, NULL, 5, NULL);
    xTaskCreate(ctrl_task, "ctrl", 4096, NULL, 5, NULL);
    xTaskCreate(observer_task, "observer", 3072, NULL, 4, NULL);

    /* 之后一切由主机脚本经控制通道驱动；观测从此刻起滚动输出 */
}
