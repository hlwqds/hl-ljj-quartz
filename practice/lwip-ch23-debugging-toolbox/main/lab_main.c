/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * lwIP 深度解析（二十三）实验工程：调试工具箱 —— LWIP_DEBUG、统计与抓包
 *
 * 破案实战（主实验）：复现并解剖 ch22 悬案②
 *   「guest 内 loopback 明文服务仅第一条连接可用，后续 connect 全 RST」。
 *   PHASE-L1: 串行变体 —— connect→echo→close 循环 N 轮（观察 TIME_WAIT 的作用）
 *   PHASE-L2: 并发变体 —— 与 ch22 完全同构：连接 A 保持存活，随后再拨 B/C/D/E
 *   取证手段：
 *     - LWIP_HOOK_IP4_INPUT 观测点：loopback 流量也要过 ip4_input()，
 *       每段 TCP 包打一行（方向/flags/seglen），RST 由谁先发出一目了然；
 *     - lwip_stats.tcp 计数器 snap-diff：每次 connect 前后各拍一次快照打增量；
 *     - debug 变体构建（sdkconfig.debug.defaults + 注入 TCP_RST_DEBUG）重跑同一序列，
 *       让 lwIP 自己说出 RST 决策点的函数名。
 * 辅助实验（综合案例素材）：
 *   PHASE-P : ping SLIRP 网关 ×3（栈与外部网络面基线 RTT，供"慢"的分诊对照）
 *   PHASE-EXT: 0.0.0.0:8888 echo server 常驻，配合 hostfwd tcp::8031-:8888
 *              供宿主机 nc / python 定时客户端 / tcpdump -i lo 使用；
 *              心跳窗口期还每 5s 重拨一次 loopback，给 gdb 断点提供"活的"流量。
 *   收尾打印 heap 三件套 + stats_display() 全表。
 *
 * 运行环境：ESP-IDF v6.0.2 + qemu-system-xtensa (Espressif fork)，
 *           -nic user,model=open_eth,hostfwd=tcp::8031-:8888
 */

#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <assert.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <netinet/in.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"

#include "esp_log.h"
#include "esp_event.h"
#include "esp_netif.h"
#include "esp_netif_net_stack.h" /* esp_netif_get_netif_impl */
#include "esp_eth.h"
#include "esp_eth_mac_openeth.h"
#include "esp_timer.h"
#include "esp_heap_caps.h"

#include "lwip/sockets.h"
#include "lwip/tcp.h"
#include "lwip/tcpip.h"
#include "lwip/netif.h"
#include "lwip/priv/tcp_priv.h"   /* TCPH_FLAGS / 全局 PCB 链表（gdb 巡检同源） */
#include "lwip/stats.h"           /* lwip_stats.tcp snap-diff、stats_display */

#include "ping/ping_sock.h"

static const char *TAG = "ch23lab";

/* ------------------------- 实验参数 ------------------------- */
#define LO_ECHO_PORT      23210    /* guest 内部 loopback 明文 echo server（带病灶） */
#define FIX_ECHO_PORT     23211    /* 修复版：每连接一个 worker 任务 */
#define EXT_ECHO_PORT     8888     /* 对外 echo server，hostfwd tcp::8031-:8888 */
#define PING_COUNT        3        /* PHASE-P 探针数 */
#define SEQ_ROUNDS        5        /* PHASE-L1 串行轮数 */
#define CONC_ATTEMPTS     4        /* PHASE-L2 连接 A 存活时的再拨次数 */
#define HEARTBEATS        10       /* keepalive 窗口心跳数 */
#define BEAT_MS           4000     /* 心跳间隔 */

/* lwip_stats.tcp 的 12 个统计字段名（struct stats_proto 固定顺序） */
#define SNAP_FIELDS 12

/* ------------------------- 全局状态 ------------------------- */
static SemaphoreHandle_t s_got_ip;
static esp_netif_t *s_eth_netif;                 /* 供 TX 包装层取 lwip netif */
static volatile int s_lo_ready, s_fix_ready, s_ext_ready;

/* ------------------- 观测点 3：linkoutput TX 计数包装 -------------------
 * loopback 流量根本不经过任何驱动（ip4_route 直接返回 loop_netif，
 * output = netif_loop_output），所以这个观测点只会看到走向 SLIRP 的包。
 * swap 必须发生在 tcpip_thread 内 —— 用 tcpip_callback 投递，同 ch12/ch17。
 */
static err_t (*s_orig_linkoutput)(struct netif *, struct pbuf *);
static uint32_t s_tx_pkts, s_tx_bytes;

static err_t counting_linkoutput(struct netif *netif, struct pbuf *p)
{
    s_tx_pkts++;
    s_tx_bytes += p->tot_len;
    /* 只打印控制类短帧（ARP/DHCP/纯 ACK/SYN 等），数据帧只计数不刷屏 */
    if (p->tot_len < 256) {
        printf("[tx ] len=%u pkts=%lu bytes=%lu\n",
               p->tot_len, (unsigned long)s_tx_pkts, (unsigned long)s_tx_bytes);
    }
    return s_orig_linkoutput(netif, p);
}

static void tx_wrap_install_in_tcpip(void *arg)
{
    struct netif *n = (struct netif *)esp_netif_get_netif_impl(s_eth_netif);
    if (n == NULL || n->linkoutput == NULL) return;
    s_orig_linkoutput = n->linkoutput;
    n->linkoutput = counting_linkoutput;
}

/* ------------------------- ch3 模板 bring-up ------------------------- */

static void eth_event_handler(void *arg, esp_event_base_t base,
                              int32_t event_id, void *event_data)
{
    if (event_id == ETHERNET_EVENT_CONNECTED)
        ESP_LOGI(TAG, "ETH link up");
}

static void ip_event_handler(void *arg, esp_event_base_t base,
                             int32_t event_id, void *event_data)
{
    ip_event_got_ip_t *evt = (ip_event_got_ip_t *)event_data;
    ESP_LOGI(TAG, "GOT_IP: " IPSTR, IP2STR(&evt->ip_info.ip));
    xSemaphoreGive(s_got_ip);
}

static void net_bringup(void)
{
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    s_got_ip = xSemaphoreCreateBinary();

    esp_netif_config_t netif_cfg = ESP_NETIF_DEFAULT_ETH();
    esp_netif_t *eth_netif = esp_netif_new(&netif_cfg);
    s_eth_netif = eth_netif;

    eth_mac_config_t mac_cfg = ETH_MAC_DEFAULT_CONFIG();
    eth_phy_config_t phy_cfg = ETH_PHY_DEFAULT_CONFIG();
    phy_cfg.reset_gpio_num      = -1;
    phy_cfg.autonego_timeout_ms = 3000;

    esp_eth_mac_t *mac = esp_eth_mac_new_openeth(&mac_cfg);
    assert(mac);
    esp_eth_phy_t *phy = esp_eth_phy_new_generic(&phy_cfg);
    assert(phy);

    esp_eth_config_t eth_cfg = ETH_DEFAULT_CONFIG(mac, phy);
    esp_eth_handle_t eth_handle = NULL;
    ESP_ERROR_CHECK(esp_eth_driver_install(&eth_cfg, &eth_handle));

    ESP_ERROR_CHECK(esp_event_handler_register(ETH_EVENT, ESP_EVENT_ANY_ID,
                                               &eth_event_handler, NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_ETH_GOT_IP,
                                               &ip_event_handler, NULL));

    esp_eth_netif_glue_handle_t glue = esp_eth_new_netif_glue(eth_handle);
    ESP_ERROR_CHECK(esp_netif_attach(eth_netif, glue));
    ESP_ERROR_CHECK(esp_eth_start(eth_handle));

    ESP_LOGI(TAG, "waiting for DHCP lease ...");
    if (xSemaphoreTake(s_got_ip, pdMS_TO_TICKS(10000)) != pdTRUE) {
        ESP_LOGE(TAG, "DHCP timeout");
        for (;;) vTaskDelay(pdMS_TO_TICKS(1000));
    }
}

/* ------------------------- 观测点 1：IP4_INPUT hook ------------------------- */
/*
 * 运行在 tcpip_thread、ip4_input() 入口。loopback 流量同样经过这里：
 * netif_loop_output() 只是把 pbuf 拷贝塞进 loop_netif 的 loop_first 队列，
 * 之后 netif_poll() -> tcpip_input() -> ip_input() 正常走全 IP/TCP 栈。
 * 本函数只读 pbuf、永不清费（返回 0），纯观测不改包。
 */
int ch23_ip4_input_hook(struct pbuf *p, struct netif *inp)
{
    uint8_t hdr[80];
    struct tcp_hdr th;
    uint16_t sport, dport, tflags, seglen;

    (void)inp;
    if (p == NULL || p->len < 1 || p->tot_len < 40) return 0;

    const uint8_t *b0 = (const uint8_t *)p->payload;
    if ((b0[0] >> 4) != 4) return 0;              /* 非 IPv4（IPv6/ARP 不看） */
    uint8_t ihl = (uint8_t)((b0[0] & 0x0f) * 4);
    if (ihl < 20 || p->tot_len < (u16_t)(ihl + 20)) return 0;
    uint16_t need = (uint16_t)(ihl + 20);
    if (pbuf_copy_partial(p, hdr, need, 0) != need) return 0;
    if (hdr[9] != 6 /* TCP */) return 0;
    memcpy(&th, hdr + ihl, sizeof(th));

    sport  = lwip_ntohs(th.src);
    dport  = lwip_ntohs(th.dest);
    tflags = TCPH_FLAGS(&th);
    {
        uint16_t iph_tot = (uint16_t)(((uint16_t)hdr[2] << 8) | hdr[3]);
        uint8_t tcphlen_b = (uint8_t)TCPH_HDRLEN_BYTES(&th);
        if (tcphlen_b < 20 || iph_tot < (uint16_t)(tcphlen_b + ihl)) return 0;
        seglen = (uint16_t)(iph_tot - (uint16_t)(tcphlen_b + ihl));
    }

    char f[7]; int fi = 0;
    if (tflags & TCP_SYN)  f[fi++] = 'S';
    if (tflags & TCP_ACK)  f[fi++] = 'A';
    if (tflags & TCP_FIN)  f[fi++] = 'F';
    if (tflags & TCP_RST)  f[fi++] = 'R';
    if (tflags & TCP_PSH)  f[fi++] = 'P';
    if (tflags & TCP_URG)  f[fi++] = 'U';
    f[fi] = '\0';

    printf("[ip4in] %u.%u.%u.%u:%u > %u.%u.%u.%u:%u %-4s len=%u\n",
           (unsigned)hdr[12], (unsigned)hdr[13], (unsigned)hdr[14], (unsigned)hdr[15],
           sport,
           (unsigned)hdr[16], (unsigned)hdr[17], (unsigned)hdr[18], (unsigned)hdr[19],
           dport, f, seglen);
    return 0;                                     /* 放行，正常协议处理 */
}

/* ------------------------- 观测点 2：stats snap-diff ------------------------- */

#ifdef CONFIG_LWIP_STATS
typedef struct { uint32_t v[SNAP_FIELDS]; } proto_snap_t;

static const char *snap_names[SNAP_FIELDS] = {
    "xmit", "recv", "fw", "drop", "chkerr", "lenerr",
    "memerr", "rterr", "proterr", "opterr", "err", "cachehit"
};

static void snap_take(proto_snap_t *s)
{
    const struct stats_proto *p = &lwip_stats.tcp;
    uint32_t *d = &s->v[0];
    d[0] = p->xmit;   d[1] = p->recv;   d[2] = p->fw;
    d[3] = p->drop;   d[4] = p->chkerr; d[5] = p->lenerr;
    d[6] = p->memerr; d[7] = p->rterr;  d[8] = p->proterr;
    d[9] = p->opterr; d[10] = p->err;   d[11] = p->cachehit;
}

static void snap_diff(const char *tag, const proto_snap_t *a, const proto_snap_t *b)
{
    printf("[tcpdiff] %s:", tag);
    int any = 0;
    for (int i = 0; i < SNAP_FIELDS; i++) {
        uint32_t delta = b->v[i] - a->v[i];
        if (delta != 0) {
            printf(" %s=%lu", snap_names[i], (unsigned long)delta);
            any = 1;
        }
    }
    fputs(any ? "\n" : " (no delta)\n", stdout);
}
#else
typedef struct { uint32_t v[1]; } proto_snap_t;
static void snap_take(proto_snap_t *s) { (void)s; }
static void snap_diff(const char *tag, const proto_snap_t *a, const proto_snap_t *b)
{ (void)tag; (void)a; (void)b; }
#endif

/* ------------------------- 内存三件套（ch22 修正口径） ------------------------- */

static void mem_stamp(const char *tag)
{
    printf("[mem] %-14s free=%u largest=%u min-ever=%u\n", tag,
           (unsigned)heap_caps_get_free_size(MALLOC_CAP_DEFAULT),
           (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_DEFAULT),
           (unsigned)heap_caps_get_minimum_free_size(MALLOC_CAP_DEFAULT));
}

/* ------------------------- PHASE-P：ping 网关 ------------------------- */

static void on_ping_success(esp_ping_handle_t hdl, void *args)
{
    uint32_t elapsed_us;
    uint16_t seqno;
    esp_ping_get_profile(hdl, ESP_PING_PROF_SEQNO, &seqno, sizeof(seqno));
    esp_ping_get_profile(hdl, ESP_PING_PROF_TIMEGAP, &elapsed_us, sizeof(elapsed_us));
    ESP_LOGI(TAG, "%u bytes from %s icmp_seq=%u time=%lu ms",
             32, "10.0.2.2", seqno, (unsigned long)elapsed_us);
}

static void phase_ping(void)
{
    printf("==== PHASE-P: ping gateway baseline ====\n");
    ip_addr_t target;
    IP_SET_TYPE_VAL(target, IPADDR_TYPE_V4);
    ip4_addr_set_u32(ip_2_ip4(&target), inet_addr("10.0.2.2"));

    esp_ping_config_t cfg = ESP_PING_DEFAULT_CONFIG();
    cfg.target_addr = target;
    cfg.count       = PING_COUNT;
    cfg.interval_ms = 300;
    cfg.timeout_ms  = 1000;

    static const char *name = "gw";
    esp_ping_callbacks_t cbs = {
        .cb_args         = (void *)name,
        .on_ping_success = on_ping_success,
        .on_ping_end     = NULL,
    };
    esp_ping_handle_t hdl = NULL;
    ESP_ERROR_CHECK(esp_ping_new_session(&cfg, &cbs, &hdl));
    esp_ping_start(hdl);
    vTaskDelay(pdMS_TO_TICKS(cfg.count * cfg.interval_ms + cfg.timeout_ms + 1500));
    esp_ping_stop(hdl);
    esp_ping_delete_session(hdl);
}

/* ------------------------- echo server（loopback / 外环共壳） ------------------------- */

static void echo_server_task(void *arg)
{
    int port = (int)(intptr_t)arg;
    char rx[1024];
    struct sockaddr_in la = {
        .sin_family = AF_INET,
        .sin_port   = htons(port),
        .sin_addr.s_addr = htonl(INADDR_ANY),
    };
    int ls = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    assert(ls >= 0);
    setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &(int){1}, sizeof(int));
    assert(bind(ls, (struct sockaddr *)&la, sizeof(la)) == 0);
    assert(listen(ls, 2) == 0);

    if (port == LO_ECHO_PORT) {
        s_lo_ready = 1;
        printf("[srv-lo] listening on 127.0.0.1:%d backlog=2\n", port);
    } else {
        s_ext_ready = 1;
        printf("[srv-ext] listening on 0.0.0.0:%d (hostfwd tcp::8031-:8888)\n", port);
    }

    for (;;) {
        int c = accept(ls, NULL, NULL);
        if (c < 0) {
            printf("[srv %d] accept errno=%d\n", port, errno);
            continue;
        }
        int n;
        while ((n = recv(c, rx, sizeof(rx), 0)) > 0) {
            int off = 0;
            while (off < n) off += send(c, rx + off, n - off, 0);
        }
        close(c);
        printf("[srv %d] client closed\n", port);
    }
}

/* ------------------------- 客户端探针 ------------------------- */

static int probe_connect(int port, int64_t *elapsed_us)
{
    struct sockaddr_in dst = {
        .sin_family = AF_INET,
        .sin_port   = htons(port),
        .sin_addr.s_addr = inet_addr("127.0.0.1"),
    };
    int fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (fd < 0) { printf("[cli ] socket errno=%d\n", errno); return -1; }
    struct timeval tv = { .tv_sec = 2, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    int64_t t0 = esp_timer_get_time();
    if (connect(fd, (struct sockaddr *)&dst, sizeof(dst)) != 0) {
        printf("[cli ] connect 127.0.0.1:%d FAILED errno=%d (%lld us)\n",
               port, errno, (long long)(esp_timer_get_time() - t0));
        close(fd);
        return -1;
    }
    if (elapsed_us) *elapsed_us = esp_timer_get_time() - t0;
    return fd;
}

static int probe_echo_once(int fd, int seq)
{
    char tx[40], rx[40];
    int len = snprintf(tx, sizeof(tx), "ch23-probe-%02d", seq);
    if (send(fd, tx, len, 0) != len) {
        printf("[cli ] send errno=%d\n", errno);
        return -1;
    }
    int got = 0;
    while (got < len) {
        int r = recv(fd, rx + got, len - got, 0);
        if (r <= 0) {
            printf("[cli ] recv r=%d errno=%d (want %d)\n", r, errno, len);
            return -1;
        }
        got += r;
    }
    return memcmp(rx, tx, len) == 0 ? 0 : -1;
}

/* ------------------------- 修复版服务器：每连接一个 worker ------------------------- */

static void lo_conn_worker(void *arg)
{
    int c = (int)(intptr_t)arg;
    char rx[1024];
    int n;
    while ((n = recv(c, rx, sizeof(rx), 0)) > 0) {
        int off = 0;
        while (off < n) off += send(c, rx + off, n - off, 0);
    }
    close(c);
    vTaskDelete(NULL);
}

static void fixed_server_task(void *arg)
{
    int port = FIX_ECHO_PORT;
    struct sockaddr_in la = {
        .sin_family = AF_INET,
        .sin_port   = htons(port),
        .sin_addr.s_addr = htonl(INADDR_ANY),
    };
    int ls = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    assert(ls >= 0);
    setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &(int){1}, sizeof(int));
    assert(bind(ls, (struct sockaddr *)&la, sizeof(la)) == 0);
    assert(listen(ls, 2) == 0);          /* 故意保持与病灶版相同的 backlog */
    s_fix_ready = 1;
    printf("[srv-fix] listening on 127.0.0.1:%d backlog=2 (per-conn worker)\n", port);

    for (;;) {
        int c = accept(ls, NULL, NULL);
        if (c < 0) continue;
        /* 关键差异：accept 立即转手 worker，主循环马上回到 accept() */
        if (xTaskCreate(lo_conn_worker, "lo_w", 3072,
                        (void *)(intptr_t)c, 6, NULL) != pdTRUE) {
            close(c);
            continue;
        }
    }
}

/* ------------------------- PHASE-L1：串行变体 ------------------------- */

static void phase_loop_seq(void)
{
    printf("==== PHASE-L1: sequential connect/echo/close x%d ====\n", SEQ_ROUNDS);
    for (int i = 0; i < SEQ_ROUNDS; i++) {
        proto_snap_t a, b;
        snap_take(&a);
        int fd = probe_connect(LO_ECHO_PORT, NULL);
        int ok = -1;
        if (fd >= 0) {
            ok = probe_echo_once(fd, i);
            close(fd);
        }
        vTaskDelay(pdMS_TO_TICKS(50));   /* 让响应包走完再拍快照 */
        snap_take(&b);
        printf("[seq ] round%d connect+echo -> %s\n",
               i, ok == 0 ? "OK" : "FAIL");
        snap_diff("L1-round", &a, &b);
    }
}

/* ------------------------- PHASE-L2：并发变体（ch22 悬案②场景） ------------------------- */

static int phase_loop_conc(int port, const char *tag)
{
    printf("==== PHASE-%s: conn A alive, then %d fresh connects to :%d ====\n",
           tag, CONC_ATTEMPTS, port);
    int fa = probe_connect(port, NULL);
    if (fa < 0) {
        printf("[%s] first connect already failed, abort\n", tag);
        return -1;
    }
    printf("[%s] A: connect OK fd=%d (kept open)\n", tag, fa);
    printf("[%s] A: echo -> %s\n", tag,
           probe_echo_once(fa, 100) == 0 ? "OK" : "FAIL");

    for (int i = 0; i < CONC_ATTEMPTS; i++) {
        proto_snap_t a, b;
        int64_t us = 0;
        snap_take(&a);
        int fd = probe_connect(port, &us);
        int ok = -1;
        if (fd >= 0) ok = probe_echo_once(fd, 200 + i);
        if (ok == 0)
            printf("[%s] #%d connect+echo OK (%lld us), now closing it\n",
                   tag, i, (long long)us);
        else
            printf("[%s] #%d FAILED\n", tag, i);
        if (fd >= 0) close(fd);
        vTaskDelay(pdMS_TO_TICKS(50));
        snap_take(&b);
        snap_diff(i == 0 ? "first-extra-conn" : "next-extra-conns", &a, &b);
    }
    /* 观察 A 是否仍然健康 */
    printf("[%s] A still alive: echo -> %s\n", tag,
           probe_echo_once(fa, 999) == 0 ? "OK" : "FAIL");
    close(fa);
    return 0;
}

/* ------------------------- 总控 ------------------------- */

static void lab_main_task(void *arg)
{
    printf("\n== ch23 lab start ==\n");
    mem_stamp("boot-baseline");

    /* socket/netconn 必须在 esp_netif_init() 之后创建（tcpip 邮箱先就绪），
     * 所以 bring-up 在前、server 任务在后。 */
    net_bringup();

    xTaskCreate(echo_server_task, "lo_srv", 3072, (void *)(intptr_t)LO_ECHO_PORT, 5, NULL);
    xTaskCreate(fixed_server_task, "fix_srv", 3072, NULL, 5, NULL);
    xTaskCreate(echo_server_task, "ext_srv", 3072, (void *)(intptr_t)EXT_ECHO_PORT, 5, NULL);
    for (int i = 0; i < 30 && !(s_lo_ready && s_fix_ready && s_ext_ready); i++)
        vTaskDelay(pdMS_TO_TICKS(100));
    printf("[srv-ready] lo=%d fix=%d ext=%d\n", s_lo_ready, s_fix_ready, s_ext_ready);

    /* 安装 TX 观测点（在 tcpip_thread 内完成指针替换） */
    tcpip_callback((tcpip_callback_fn)tx_wrap_install_in_tcpip, NULL);

    phase_ping();
    mem_stamp("post-ping");

    phase_loop_seq();

    /* 悬案②复现：与 ch22 完全同构的"连接 A 保持存活"场景 */
    phase_loop_conc(LO_ECHO_PORT, "L2");
    /* 同一探针矩阵打修复版服务器：一针对照 */
    phase_loop_conc(FIX_ECHO_PORT, "L2b-FIXED");
    mem_stamp("post-case");

#ifdef CONFIG_LWIP_STATS
    printf("==== FULL STATS TABLE ====\n");
    stats_display();
#endif

    printf("==== KEEPALIVE WINDOW (%ds): host tools now; heartbeat probes ====\n",
           HEARTBEATS * (BEAT_MS / 1000));
    for (int beat = 0; beat < HEARTBEATS; beat++) {
        vTaskDelay(pdMS_TO_TICKS(BEAT_MS));
        printf("[beat %02d] free=%u\n", beat,
               (unsigned)heap_caps_get_free_size(MALLOC_CAP_DEFAULT));
        /* 给 gdb/tcpdump 观察窗制造活的周期性事件 */
        int fd = probe_connect(LO_ECHO_PORT, NULL);
        if (fd >= 0) close(fd);
    }

    printf("== ch23 lab done ==\n");
    vTaskDelete(NULL);
}

void app_main(void)
{
    ESP_LOGI(TAG, "== ch23: debugging toolbox over openeth ==");
    xTaskCreate(lab_main_task, "ch23main", 16384, NULL, 6, NULL);
}
