/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * lwIP 深度解析（二十二）实验工程：TLS —— esp-tls/mbedTLS 与 lwIP 的边界
 *
 * 实验（宿主机 openssl s_server 为服务器端点，guest 经 SLIRP 连 10.0.2.2）：
 *   PHASE-A/B: 握手全记录 + 内存账本。先自建 socket 计时 TCP connect，
 *              再把 fd 交给 esp-tls 接着做 TLS 握手，两段分别用 esp_timer 打点；
 *              观察任务 100ms 周期采样 heap free；min-ever 差值取握手峰值。
 *   PHASE-D  : 吞吐对比：明文 TCP echo vs TLS echo，1KB × 2048 锁步回显，
 *              明文/TLS 交错三轮（配对测量纪律）。
 *   PHASE-C  : 堆饥饿注入（复用 ch5 手法：malloc 到只剩 ~20KB），发起握手
 *              捕获失败路径与错误码；释放后自愈重试。
 *   PHASE-E  : 证书验证姿势：skip_cert_verify / CA 固定(正确) / CA 固定(错证书)。
 *
 * 运行环境：ESP-IDF v6.0.2 + qemu-system-xtensa (Espressif fork)，
 *           -nic user,model=open_eth（无 hostfwd，本实验只有 guest 出向流量）
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
#include "esp_eth.h"
#include "esp_eth_mac_openeth.h"
#include "esp_timer.h"
#include "esp_heap_caps.h"

#include "esp_tls.h"
#include <mbedtls/ssl.h>
#include <mbedtls/debug.h>      /* mbedtls_debug_set_threshold：阶段 A 后静音 */

#include "certs.h"              /* 内嵌自签证书（openssl req 生成，见 certs/） */

static const char *TAG = "ch22lab";

/* ------------------------- 实验参数 ------------------------- */
#define HOST_IP_STR        "10.0.2.2"
#define PORT_TLS_RSA       22443     /* openssl s_server -rev -cert ch22_rsa.crt */
#define PORT_TLS_EC        22444     /* openssl s_server -rev -cert ch22_ec.crt  */
#define PORT_PLAIN_ECHO    22450     /* python3 明文 echo server                 */
#define PORT_TLS_ECHO      22454     /* python3 TLS echo server（吞吐实验专用）  */
#define PORT_LOCAL_TLS     22455     /* guest 内部 TLS echo server（loopback）   */
#define PORT_LOCAL_PLAIN   22456     /* guest 内部明文 echo server（loopback）   */
#define TLS_TIMEOUT_MS     10000

#define RTT_MSG_N          5         /* 握手后小载荷回显轮数                     */
#define THR_MSG_LEN        1024      /* 吞吐实验消息大小                         */
#define THR_MSG_N          2048      /* 每轮消息数（2 MiB/轮）                   */
#define THR_ROUNDS         3         /* 明文/TLS 各三轮，交错进行                */

#define STARVE_FLOOR_BYTES 12000     /* 饥饿注水停止线（free <= 该值）           */
#define STARVE_CHUNK       4096

#define MEM_TICK_MS        100       /* 内存观察任务周期                         */

/* ------------------------- 全局状态 ------------------------- */
static SemaphoreHandle_t s_got_ip;
static volatile bool     s_mem_tick_run;
static char             *s_mem_phase = (char *)"idle";   /* 观察任务打印当前阶段名 */

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

/* ------------------------- 测量辅助 ------------------------- */

static int64_t now_us(void) { return esp_timer_get_time(); }

static unsigned int heap_free_b(void)
{
    return (unsigned)heap_caps_get_free_size(MALLOC_CAP_DEFAULT);
}

static void mem_stamp(const char *tag)
{
    printf("[mem] %-22s free=%u largest=%u min-ever=%u\n", tag,
           (unsigned)heap_free_b(),
           (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_DEFAULT),
           (unsigned)heap_caps_get_minimum_free_size(MALLOC_CAP_DEFAULT));
}

/* 内存观察任务：100ms 周期采样 */
static void mem_observer_task(void *arg)
{
    while (s_mem_tick_run) {
        printf("[mem-tick] t=%8lld ms phase=%-12s free=%u\n",
               (long long)(now_us() / 1000), s_mem_phase,
               (unsigned)heap_free_b());
        vTaskDelay(pdMS_TO_TICKS(MEM_TICK_MS));
    }
    vTaskDelete(NULL);
}

/* 打印协商结果：协议版本 / 密码套件 / 对端证书体积 */
static void report_negotiated(esp_tls_t *tls)
{
    mbedtls_ssl_context *ssl = (mbedtls_ssl_context *)esp_tls_get_ssl_context(tls);
    const mbedtls_x509_crt *peer = mbedtls_ssl_get_peer_cert(ssl);
    printf("[neg] version=%s suite=%s peer_cert=%u bytes\n",
           mbedtls_ssl_get_version(ssl), mbedtls_ssl_get_ciphersuite(ssl),
           peer ? (unsigned)peer->raw.len : 0);
}

/* 打印并清空 esp-tls 错误句柄里分类记录的错误码 */
static void report_tls_error(esp_tls_t *tls, const char *when)
{
    esp_tls_error_handle_t h = NULL;
    if (esp_tls_get_error_handle(tls, &h) != ESP_OK || h == NULL) {
        printf("[err] %s: no error handle\n", when);
        return;
    }
    int code = 0, flags = 0;
    esp_err_t last = esp_tls_get_and_clear_last_error(h, &code, &flags);
    int sys_err = 0, mb_err = 0, cert_flags = 0;
    esp_tls_get_and_clear_error_type(h, ESP_TLS_ERR_TYPE_SYSTEM, &sys_err);
    esp_tls_get_and_clear_error_type(h, ESP_TLS_ERR_TYPE_MBEDTLS, &mb_err);
    esp_tls_get_and_clear_error_type(h, ESP_TLS_ERR_TYPE_MBEDTLS_CERT_FLAGS, &cert_flags);
    printf("[err] %s: last_esp_err=0x%x tls_code=-0x%04x cert_flags=0x%x "
           "(sys_errno=%d mb_code=-0x%04x)\n", when, (unsigned)last, (unsigned)-code,
           (unsigned)flags, -sys_err, (unsigned)-mb_err);
}

/*
 * 分段计时连接：
 *   1) 自己 socket()+connect() 计 TCP 三次握手耗时；
 *   2) 把 fd 交给 esp-tls（set_conn_sockfd + set_conn_state(CONNECTING)），
 *      由 esp_tls_conn_new_sync 从 CONNECTING 状态续跑 create_ssl_handle +
 *      handshake，计 TLS 握手耗时。
 */
typedef struct {
    esp_tls_t *tls;
    int64_t tcp_us;
    int64_t hs_us;
} staged_conn_t;

static int staged_tls_connect(const char *host_ip, int port, const esp_tls_cfg_t *cfg,
                              bool skip_hostname, staged_conn_t *out)
{
    struct sockaddr_in dst = {
        .sin_family = AF_INET,
        .sin_port   = htons(port),
    };
    inet_aton(host_ip, &dst.sin_addr);

    int fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (fd < 0) { printf("[conn] socket failed errno=%d\n", errno); return -1; }

    struct timeval tv = { .tv_sec = TLS_TIMEOUT_MS / 1000, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    int64_t t0 = now_us();
    if (connect(fd, (struct sockaddr *)&dst, sizeof(dst)) != 0) {
        printf("[conn] connect :%d failed errno=%d (%lld us)\n",
               port, errno, (long long)(now_us() - t0));
        close(fd);
        return -1;
    }
    out->tcp_us = now_us() - t0;

    esp_tls_t *tls = esp_tls_init();
    if (!tls) { printf("[conn] esp_tls_init OOM\n"); close(fd); return -1; }
    esp_tls_set_conn_sockfd(tls, fd);
    /* 跳过 INIT（那里会再做一次 tcp_connect），从 CONNECTING 状态续跑 */
    esp_tls_set_conn_state(tls, ESP_TLS_CONNECTING);

    esp_tls_cfg_t cfg_copy = *cfg;
    cfg_copy.skip_common_name = skip_hostname;
    cfg_copy.timeout_ms = TLS_TIMEOUT_MS;

    int64_t t1 = now_us();
    int rc = esp_tls_conn_new_sync(host_ip, strlen(host_ip),
                                   port, &cfg_copy, tls);
    out->hs_us = now_us() - t1;
    out->tls = tls;

    if (rc != 1) {
        printf("[conn] TLS to %s:%d FAILED after %lld us\n",
               HOST_IP_STR, port, (long long)out->hs_us);
        report_tls_error(tls, "handshake");
        esp_tls_conn_destroy(tls);
        out->tls = NULL;
        return -1;
    }
    return 0;
}

/*
 * 小载荷锁步回显。注意 openssl s_server -rev 是"按行"回显（攒到 \n 才发），
 * 载荷必须以换行结尾；返回内容是字节序反转，但字节多重集合不变，
 * 因此校验用 XOR 累加和（与顺序无关）。
 */
static unsigned xor_sum(const void *p, size_t n)
{
    const unsigned char *b = p;
    unsigned x = 0;
    for (size_t i = 0; i < n; i++) x ^= b[i];
    return x;
}

static int echo_once_tls(esp_tls_t *tls, int seq, int64_t *rtt_us)
{
    char tx[64], rx[64];
    int len = snprintf(tx, sizeof(tx), "ch22-probe-%02d\n", seq);
    unsigned want = xor_sum(tx, len);

    int64_t t0 = now_us();
    ssize_t w = esp_tls_conn_write(tls, tx, len);
    if (w != len) { printf("[echo] write %zd/%d\n", w, len); return -1; }

    int got = 0;
    while (got < len) {
        ssize_t r = esp_tls_conn_read(tls, rx + got, len - got);
        if (r <= 0) { printf("[echo] read r=%zd\n", r); return -1; }
        got += r;
    }
    *rtt_us = now_us() - t0;
    if (xor_sum(rx, got) != want) {
        printf("[echo] payload xor mismatch (got %dB)\n", got);
        return -1;
    }
    return 0;
}

/* ------------------- PHASE A+B：握手全记录 + 内存账本 ------------------- */

static const esp_tls_cfg_t s_skip_cfg = {
    .timeout_ms = TLS_TIMEOUT_MS,
};

static void phase_ab(const char *label, int port)
{
    printf("\n===== PHASE A/B [%s] port=%d =====\n", label, port);

    char phname[24];
    snprintf(phname, sizeof(phname), "%s-baseline", label);
    s_mem_phase = phname;
    vTaskDelay(pdMS_TO_TICKS(300));            /* 观察任务记几拍基线 */

    uint32_t free_before   = heap_free_b();
    uint32_t minever_before = heap_caps_get_minimum_free_size(MALLOC_CAP_DEFAULT);
    mem_stamp("baseline");

    /* ---- 阶段 1+2：TCP 连接 -> esp-tls 接管 -> TLS 握手 ---- */
    s_mem_phase = "handshake";
    staged_conn_t sc;
    if (staged_tls_connect(HOST_IP_STR, port, &s_skip_cfg, true, &sc) == 0) {
        printf("[phase-a] tcp_connect=%lld us | tls_handshake=%lld us | total=%lld us\n",
               (long long)sc.tcp_us, (long long)sc.hs_us,
               (long long)(sc.tcp_us + sc.hs_us));
        report_negotiated(sc.tls);
    } else {
        printf("[phase-a] handshake FAILED (%s)\n", label);
        goto settle;
    }
    mem_stamp("post-handshake");

    /* ---- 阶段 3：会话期小载荷往返 ---- */
    {
        uint32_t minever_after_hs = heap_caps_get_minimum_free_size(MALLOC_CAP_DEFAULT);
        printf("[ledger] HANDSHAKE_PEAK_DELTA(%s) = %u bytes "
               "(min-ever %u -> %u)\n", label,
               (unsigned)(minever_before - minever_after_hs),
               (unsigned)minever_before, (unsigned)minever_after_hs);
    }
    s_mem_phase = "session";
    for (int i = 0; i < RTT_MSG_N; i++) {
        int64_t rtt = 0;
        if (echo_once_tls(sc.tls, i, &rtt) != 0) break;
        printf("[phase-a] app-echo #%d rtt=%lld us payload=%d B\n",
               i, (long long)rtt, 14);
    }
    mem_stamp("post-session");

    /* ---- 阶段 4：关闭 ---- */
    s_mem_phase = "closing";
    esp_tls_conn_destroy(sc.tls);
    vTaskDelay(pdMS_TO_TICKS(500));
    printf("[ledger] CLOSED(%s): free now=%u, before-this-phase=%u, retained=%d\n",
           label, (unsigned)heap_free_b(), (unsigned)free_before,
           (int)((int)free_before - (int)heap_free_b()));

settle:
    snprintf(phname, sizeof(phname), "%s-settled", label);
    s_mem_phase = phname;
    vTaskDelay(pdMS_TO_TICKS(400));
    mem_stamp("settled");
}


/* --------------- guest 内部 echo 服务（PHASE-D′ loopback 配对） --------------- */

static volatile int s_plain_ready, s_tls_ready;

/* 明文 echo：socket API 一收一发，tcpip_thread 之上纯 socket 路径 */
static void local_plain_echo_task(void *arg)
{
    char rx[2048];
    struct sockaddr_in la = {
        .sin_family = AF_INET,
        .sin_port   = htons(PORT_LOCAL_PLAIN),
    };
    int ls = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    assert(ls >= 0);
    setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &(int){1}, sizeof(int));
    assert(bind(ls, (struct sockaddr *)&la, sizeof(la)) == 0);
    assert(listen(ls, 2) == 0);
    s_plain_ready = 1;

    printf("[srv-p] accepting\n");
    for (;;) {
        int c = accept(ls, NULL, NULL);
        if (c < 0) { printf("[srv-p] accept errno=%d\n", errno); continue; }
        int n;
        while ((n = recv(c, rx, sizeof(rx), 0)) > 0) {
            int off = 0;
            while (off < n) off += send(c, rx + off, n - off, 0);
        }
        close(c);
    }
}

/* TLS echo：esp_tls server 会话。握手在 accept 后阻塞完成。 */
static esp_tls_cfg_server_t s_srv_cfg;

static void local_tls_echo_task(void *arg)
{
    memset(&s_srv_cfg, 0, sizeof(s_srv_cfg));
    s_srv_cfg.servercert_buf   = (const unsigned char *)CERT_OK_PEM;
    s_srv_cfg.servercert_bytes = strlen(CERT_OK_PEM) + 1;
    s_srv_cfg.serverkey_buf    = (const unsigned char *)KEY_OK_PEM;
    s_srv_cfg.serverkey_bytes  = strlen(KEY_OK_PEM) + 1;
    s_srv_cfg.tls_handshake_timeout_ms = 15000;

    struct sockaddr_in la = {
        .sin_family = AF_INET,
        .sin_port   = htons(PORT_LOCAL_TLS),
    };
    int ls = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    assert(ls >= 0);
    setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &(int){1}, sizeof(int));
    assert(bind(ls, (struct sockaddr *)&la, sizeof(la)) == 0);
    assert(listen(ls, 2) == 0);
    s_tls_ready = 1;

    char rx[2048];
    for (;;) {
        int c = accept(ls, NULL, NULL);
        if (c < 0) continue;
        esp_tls_t *tls = esp_tls_init();
        if (!tls) { close(c); continue; }
        if (esp_tls_server_session_create(&s_srv_cfg, c, tls) != 0) {
            printf("[srv-tls] handshake failed\n");
            esp_tls_server_session_delete(tls);
            close(c);
            continue;
        }
        printf("[srv-tls] session established\n");
        int n;
        while ((n = esp_tls_conn_read(tls, rx, sizeof(rx))) > 0) {
            int off = 0;
            while (off < n) {
                ssize_t w = esp_tls_conn_write(tls, rx + off, n - off);
                if (w <= 0) break;
                off += w;
            }
        }
        esp_tls_server_session_delete(tls);
        close(c);
        printf("[srv-tls] session closed\n");
    }
}

/* ------------------------- PHASE D：吞吐对比 ------------------------- */

static char g_rcv[THR_MSG_LEN];   /* 吞吐轮接收缓冲（与发送样例分开） */

/* 长命明文连接：实验期间复用同一条连接，避免每轮重新拨号 */
static int g_plain_fd = -1;

static int open_persistent_plain(void)
{
    struct sockaddr_in dst = { .sin_family = AF_INET,
                               .sin_port = htons(PORT_LOCAL_PLAIN) };
    inet_aton("127.0.0.1", &dst.sin_addr);
    g_plain_fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (g_plain_fd < 0) return -1;
    struct timeval tv = { .tv_sec = 60, .tv_usec = 0 };
    setsockopt(g_plain_fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(g_plain_fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    if (connect(g_plain_fd, (struct sockaddr *)&dst, sizeof(dst)) != 0)
        return -1;
    const char *ping = "conn-ping";
    char back[16] = {0};
    if (send(g_plain_fd, ping, 9, 0) != 9) return -1;
    int n = 0;
    while (n < 9) {
        int r = recv(g_plain_fd, back + n, 9 - n, 0);
        if (r <= 0) return -1;
        n += r;
    }
    return memcmp(back, ping, 9) == 0 ? 0 : -1;
}

/* 明文 echo 轮：直连宿主机 python echo server，锁步 send/recv */
static int throughput_round_plain(uint32_t *bytes, int64_t *elapsed_us, char *buf)
{
    int fd = g_plain_fd;
    if (fd < 0) { printf("[thr-p] no persistent conn\n"); return -1; }

    /* 消息末尾放 \n：TLS 路径的 -rev 按行回显；XOR 校验对反转天然免疫 */
    memset(buf, 'A', THR_MSG_LEN - 1);
    buf[THR_MSG_LEN - 1] = '\n';
    unsigned want_xor = xor_sum(buf, THR_MSG_LEN);
    int64_t t0 = now_us();
    for (int i = 0; i < THR_MSG_N; i++) {
        int sent = 0;
        while (sent < THR_MSG_LEN) {
            ssize_t w = send(fd, buf + sent, THR_MSG_LEN - sent, 0);
            if (w <= 0) { printf("[thr-p] send %zd errno=%d\n", w, errno); return -1; }
            sent += w;
        }
        int got = 0; unsigned rx_xor = 0;
        while (got < THR_MSG_LEN) {
            ssize_t r = recv(fd, g_rcv, THR_MSG_LEN - got, 0);
            if (r <= 0) { printf("[thr-p] recv %zd errno=%d got=%d\n", r, errno, got); return -1; }
            rx_xor ^= xor_sum(g_rcv, r);
            got += r;
        }
        if (rx_xor != want_xor) { printf("[thr-p] xor mismatch\n"); return -1; }
    }
    *elapsed_us = now_us() - t0;
    *bytes = (uint32_t)THR_MSG_N * THR_MSG_LEN;
    return 0;
}

/* TLS echo 轮：复用已建立的 TLS 会话，锁步 write/read */
static int throughput_round_tls(esp_tls_t *tls, uint32_t *bytes,
                                int64_t *elapsed_us, char *buf)
{
    memset(buf, 'B', THR_MSG_LEN - 1);
    buf[THR_MSG_LEN - 1] = '\n';
    unsigned want_xor = xor_sum(buf, THR_MSG_LEN);
    int64_t t0 = now_us();
    for (int i = 0; i < THR_MSG_N; i++) {
        int sent = 0;
        while (sent < THR_MSG_LEN) {
            ssize_t w = esp_tls_conn_write(tls, buf + sent, THR_MSG_LEN - sent);
            if (w <= 0 && sent == 0) return -1;
            if (w > 0) sent += w;
        }
        int got = 0; unsigned rx_xor = 0;
        while (got < THR_MSG_LEN) {
            ssize_t r = esp_tls_conn_read(tls, g_rcv, THR_MSG_LEN - got);
            if (r <= 0) return -1;
            rx_xor ^= xor_sum(g_rcv, r);
            got += r;
        }
        if (rx_xor != want_xor) { printf("[thr-t] xor mismatch\n"); return -1; }
    }
    *elapsed_us = now_us() - t0;
    *bytes = (uint32_t)THR_MSG_N * THR_MSG_LEN;
    return 0;
}


static double mbit(uint32_t bytes, int64_t us)
{
    return (double)bytes * 8.0 / ((double)us / 1e6) / 1e6;
}

static void phase_d(void)
{
    printf("\n===== PHASE D: throughput plain-vs-tls "
           "(%d rounds interleaved, %dB x %d msgs each) =====\n",
           THR_ROUNDS, THR_MSG_LEN, THR_MSG_N);
    static char buf[THR_MSG_LEN];

    s_mem_phase = "thr-setup";
    staged_conn_t sc;
    /* 吞吐会话连 guest 内部 loopback 的 TLS echo：明文轮与 TLS 轮共用完全相同
       的网络路径（loopback netif -> tcpip_thread），差值全部来自 TLS 层本身 */
    if (staged_tls_connect("127.0.0.1", PORT_LOCAL_TLS, &s_skip_cfg, true, &sc) != 0) {
        printf("[thr] local tls conn failed\n"); return;
    }
    esp_tls_t *tls = sc.tls;
    report_negotiated(tls);

    double plain_sum = 0, tls_sum = 0;
    for (int round = 0; round < THR_ROUNDS; round++) {
        uint32_t bytes = 0; int64_t el = 0;
        char ph[16];

        snprintf(ph, sizeof(ph), "thr-p%d", round);
        s_mem_phase = ph;
        if (throughput_round_plain(&bytes, &el, buf) == 0) {
            double v = mbit(bytes, el);
            plain_sum += v;
            printf("[thr] round%d PLAIN %u B in %lld us = %.2f Mbit/s\n",
                   round, (unsigned)bytes, (long long)el, v);
        } else {
            printf("[thr] round%d PLAIN failed\n", round);
        }

        snprintf(ph, sizeof(ph), "thr-t%d", round);
        s_mem_phase = ph;
        if (throughput_round_tls(tls, &bytes, &el, buf) == 0) {
            double v = mbit(bytes, el);
            tls_sum += v;
            printf("[thr] round%d TLS   %u B in %lld us = %.2f Mbit/s\n",
                   round, (unsigned)bytes, (long long)el, v);
        } else {
            printf("[thr] round%d TLS failed\n", round);
            break;
        }
    }
    printf("[thr] MEAN plain=%.2f Mbit/s tls=%.2f Mbit/s tax=%.1f%%\n",
           plain_sum / THR_ROUNDS, tls_sum / THR_ROUNDS,
           100.0 * (plain_sum / THR_ROUNDS - tls_sum / THR_ROUNDS) /
           (plain_sum / THR_ROUNDS));
    s_mem_phase = "thr-done";
    esp_tls_conn_destroy(tls);
    mem_stamp("after-thr-close");
}

/* --------------------- PHASE C：堆饥饿下的握手 --------------------- */

/* 堆饥饿注入（复用 ch5 手法，内联在主任务里做，消除任务间竞态） */
#define STARVE_NMAX_INL 128
static void *s_starve_blk[STARVE_NMAX_INL];
static int   s_starve_n;

static int starve_grab(int floor)
{
    s_starve_n = 0;
    while (s_starve_n < STARVE_NMAX_INL) {
        if ((int)heap_free_b() <= floor) break;
        void *b = malloc(STARVE_CHUNK);
        if (!b) break;
        s_starve_blk[s_starve_n++] = b;
    }
    printf("[starve] grabbed=%d held=%uB free=%u largest=%u\n",
           s_starve_n, (unsigned)(s_starve_n * STARVE_CHUNK),
           heap_free_b(),
           (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_DEFAULT));
    return (int)heap_free_b();
}

static void starve_release(void)
{
    while (s_starve_n > 0) free(s_starve_blk[--s_starve_n]);
    printf("[starve] released, free-now=%u\n", heap_free_b());
}

static void phase_c(void)
{
    printf("\n===== PHASE C: handshake under memory pressure =====\n");
    s_mem_phase = "starving";
    vTaskDelay(pdMS_TO_TICKS(200));
    mem_stamp("pre-starve");

    starve_grab(STARVE_FLOOR_BYTES);
    s_mem_phase = "starved";
    mem_stamp("starved-floor");

    printf("[phase-c] attempting TLS handshake with only %u bytes free ...\n",
           heap_free_b());
    staged_conn_t sc;
    if (staged_tls_connect(HOST_IP_STR, PORT_TLS_RSA, &s_skip_cfg, true, &sc) != 0) {
        printf("[phase-c] FAIL captured (see [err]/mbedtls lines above)\n");
    } else {
        printf("[phase-c] UNEXPECTED success at free=%u -- closing\n", heap_free_b());
        esp_tls_conn_destroy(sc.tls);
    }

    s_mem_phase = "release";
    starve_release();
    vTaskDelay(pdMS_TO_TICKS(300));
    mem_stamp("after-release");

    printf("[phase-c] retrying same handshake after release ...\n");
    s_mem_phase = "heal";
    if (staged_tls_connect(HOST_IP_STR, PORT_TLS_RSA, &s_skip_cfg, true, &sc) == 0) {
        printf("[phase-c] HEALED: handshake ok in %lld us\n", (long long)sc.hs_us);
        report_negotiated(sc.tls);
        esp_tls_conn_destroy(sc.tls);
    } else {
        printf("[phase-c] still failing after release\n");
    }
}

/* -------------------- PHASE E：证书验证三种姿势 -------------------- */

static void phase_e(void)
{
    printf("\n===== PHASE E: cert verification postures =====\n");

    /* E0: 不提供任何验证数据；全局开了 SKIP_SERVER_CERT_VERIFY => 默认放行 */
    printf("--- E0: no verification option given (skip compiled in) ---\n");
    s_mem_phase = "e0";
    {
        esp_tls_cfg_t empty_cfg = { .timeout_ms = TLS_TIMEOUT_MS };
        staged_conn_t sc;
        if (staged_tls_connect(HOST_IP_STR, PORT_TLS_RSA, &empty_cfg, true, &sc) == 0) {
            printf("[e0] connection ACCEPTED with NO verification data "
                   "(CONFIG_ESP_TLS_SKIP_SERVER_CERT_VERIFY)\n");
            report_negotiated(sc.tls);
            esp_tls_conn_destroy(sc.tls);
        } else {
            printf("[e0] unexpected failure\n");
        }
    }

    /* E1: 固定正确 CA（自签叶证书本身当 trust anchor）+ 主机名匹配 */
    printf("--- E1: pinned correct self-signed cert as CA, common_name=localhost ---\n");
    s_mem_phase = "e1";
    {
        esp_tls_cfg_t cfg = {
            .cacert_buf   = (const unsigned char *)CERT_OK_PEM,
            .cacert_bytes = strlen(CERT_OK_PEM) + 1,   /* PEM 需含结尾 NUL */
            .common_name  = "localhost",
            .timeout_ms   = TLS_TIMEOUT_MS,
        };
        staged_conn_t sc;
        if (staged_tls_connect(HOST_IP_STR, PORT_TLS_RSA, &cfg, false, &sc) == 0) {
            printf("[e1] connected with PINNED cert, handshake=%lld us\n",
                   (long long)sc.hs_us);
            esp_tls_conn_destroy(sc.tls);
        } else {
            printf("[e1] pinned-correct FAILED\n");
        }
    }

    /* E2: 固定了错误证书 => verify flags 非 0，握手失败 */
    printf("--- E2: pinned WRONG cert as CA => expect verify failure ---\n");
    s_mem_phase = "e2";
    {
        esp_tls_cfg_t cfg = {
            .cacert_buf   = (const unsigned char *)CERT_WRONG_PEM,
            .cacert_bytes = strlen(CERT_WRONG_PEM) + 1,
            .common_name  = "localhost",
            .timeout_ms   = TLS_TIMEOUT_MS,
        };
        staged_conn_t sc;
        if (staged_tls_connect(HOST_IP_STR, PORT_TLS_RSA, &cfg, false, &sc) == 0) {
            printf("[e2] UNEXPECTED success with wrong CA\n");
            esp_tls_conn_destroy(sc.tls);
        } else {
            printf("[e2] wrong-cert path captured above\n");
        }
    }
}

/* ---------------------------- 总控 ---------------------------- */

static void lab_main_task(void *arg)
{
    printf("\n== ch22 lab start ==\n");
    printf("[info] sizeof(mbedtls_ssl_context)=%u sizeof(mbedtls_ssl_config)=%u\n",
           (unsigned)sizeof(mbedtls_ssl_context),
           (unsigned)sizeof(mbedtls_ssl_config));

    s_mem_tick_run = true;
    xTaskCreate(mem_observer_task, "mem_obs", 3072, NULL, 3, NULL);
    BaseType_t r1 = xTaskCreate(local_plain_echo_task, "loc_echo", 4096, NULL, 5, NULL);
    BaseType_t r2 = xTaskCreate(local_tls_echo_task,   "loc_tlse", 12288, NULL, 5, NULL);
    printf("[srv-create] plain=%ld tls=%ld\n", (long)r1, (long)r2);
    for (int i = 0; i < 30 && !(s_plain_ready && s_tls_ready); i++)
        vTaskDelay(pdMS_TO_TICKS(100));
    printf("[srv-ready] plain=%d tls=%d\n", s_plain_ready, s_tls_ready);
    printf("[plain-conn] %s\n",
           open_persistent_plain() == 0 ? "persistent OK" : "FAILED");

    mem_stamp("boot-baseline");

    /* 阶段 A 的全记录：RSA 证书主流场景 + EC 证书对照各来一次
       （两台 openssl s_server 分别监听 22443/22444）*/
    phase_ab("RSA", PORT_TLS_RSA);
    phase_ab("EC",  PORT_TLS_EC);

    /* 拿到全记录后静音后续握手的 mbedTLS 逐行日志（全局阈值归零） */
    mbedtls_debug_set_threshold(0);

    phase_d();
    phase_c();
    phase_e();

    s_mem_tick_run = false;
    vTaskDelay(pdMS_TO_TICKS(200));
    mem_stamp("final");
    printf("== ch22 lab done ==\n");
    vTaskDelete(NULL);
}

void app_main(void)
{
    ESP_LOGI(TAG, "== ch22: tls/esp-tls/mbedtls over openeth ==");
    net_bringup();
    xTaskCreate(lab_main_task, "ch22main", 24576, NULL, 6, NULL);
}
