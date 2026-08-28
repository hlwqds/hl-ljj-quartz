/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * lwIP 深度解析（二十）实验工程：esp_http_server 走读与压测
 *
 * 单一固件覆盖三个实验，参数经 TCP 控制通道(:9999)由主机注入，避免反复烧写：
 *   exp A  基线压测    ：GET /small(~100B) 与 GET /big(~10KB)，keep-alive
 *                        开/关两模式由主机压测器控制，各 3 轮配对测量；
 *   exp B  Slowloris   ：主机慢客户端半个请求头拖住会话，观察会话池耗尽、
 *                        新连接行为与 recv_wait_timeout 回收周期；
 *   exp C  大 POST     ：Content-Length 骗大 / chunked 持续上传，观察
 *                        接收路径压力、purge 行为与应用层防护。
 *
 * 服务端内建观测点：
 *   - 每个 handler 用 user_ctx 传递自己的计数器（命中数/handler 耗时分布）；
 *   - 订阅 ESP_HTTP_SERVER_EVENT 全部事件做连接级记账；
 *   - 控制通道可运行时重启 httpd（改 recv_wait_timeout / lru_purge_enable）。
 *
 * 模板来自 practice/lwip-ch03-qemu-network-lab 与 practice/lwip-ch19-isr-and-priority-design。
 * 运行环境：ESP-IDF v6.0.2 + qemu-system-xtensa (openeth)
 * 主机访问：hostfwd tcp::8024-:80，tcp::8025-:9999（端口表确认未占用）
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <assert.h>
#include <stdarg.h>
#include <errno.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"

#include "esp_log.h"
#include "esp_timer.h"
#include "esp_event.h"
#include "esp_heap_caps.h"
#include "esp_netif.h"
#include "esp_eth.h"
#include "esp_eth_mac_openeth.h"

#include "esp_http_server.h"
#include "lwip/sockets.h"

static const char *TAG = "ch20lab";

#define HTTP_PORT        80      /* 主机侧 hostfwd tcp::8024-:80 */
#define CTRL_PORT        9999    /* 主机侧 hostfwd tcp::8025-:9999 */
#define BIG_BODY_LEN     10240   /* /big 响应体大小（~10KB 档） */

/* ------------------------- 端点统计（经 user_ctx 传递） ------------------ */

typedef struct {
    const char        *name;
    volatile uint32_t  hits;
    volatile uint64_t  sum_us;    /* handler 内总耗时（esp_timer 口径） */
    volatile uint32_t  max_us;
} ep_stats_t;

static ep_stats_t g_small = { .name = "/small" };
static ep_stats_t g_big   = { .name = "/big"   };
static ep_stats_t g_post  = { .name = "/echo"  };
static ep_stats_t g_async = { .name = "/async" };

static void ep_hit(ep_stats_t *e, int64_t dt_us)
{
    e->hits++;
    e->sum_us += (uint64_t)dt_us;
    if (dt_us > (int64_t)e->max_us) {
        e->max_us = (uint32_t)dt_us;
    }
}

/* ------------------------- 全局状态 ------------------------------------- */

static SemaphoreHandle_t s_got_ip;
static httpd_handle_t    s_server;
static volatile int      s_busy_posts;       /* 正在接收中的 POST 数 */

/* /big 响应体启动时固化在静态缓冲，handler 只付 memcpy+send 的成本 */
static char g_big_body[BIG_BODY_LEN];

/* ESP_HTTP_SERVER_EVENT 计数：连接级记账（下标 = esp_http_server_event_id_t） */
static const char *s_evt_names[] = {
    "ERROR", "START", "ON_CONNECTED", "ON_HEADER", "HEADERS_SENT",
    "ON_DATA", "SENT_DATA", "DISCONNECTED", "STOP",
};
#define N_EVT_NAMES ((int)(sizeof(s_evt_names)/sizeof(s_evt_names[0])))
static volatile uint32_t s_evt_counts[N_EVT_NAMES];

static void httpd_evt_handler(void *arg, esp_event_base_t base,
                              int32_t id, void *data)
{
    if (id >= 0 && id < N_EVT_NAMES) {
        s_evt_counts[id]++;
    }
}

/* ------------------------- 以太网 bring-up（ch3 模板） ------------------- */

static void eth_event_handler(void *arg, esp_event_base_t base,
                              int32_t event_id, void *event_data)
{
    switch ((int)event_id) {
    case ETHERNET_EVENT_CONNECTED:    ESP_LOGI(TAG, "ETH_EVENT: CONNECTED"); break;
    case ETHERNET_EVENT_DISCONNECTED: ESP_LOGW(TAG, "ETH_EVENT: DISCONNECTED"); break;
    }
}

static void ip_event_handler(void *arg, esp_event_base_t base,
                             int32_t event_id, void *event_data)
{
    ip_event_got_ip_t *evt = (ip_event_got_ip_t *)event_data;
    ESP_LOGI(TAG, "GOT_IP: " IPSTR, IP2STR(&evt->ip_info.ip));
    xSemaphoreGive(s_got_ip);
}

/* ------------------------- URI handlers --------------------------------- */

/* 实验 A 目标之一：~100B 档。渲染即一次 snprintf。 */
static esp_err_t h_small(httpd_req_t *req)
{
    int64_t t0 = esp_timer_get_time();
    ep_stats_t *self = (ep_stats_t *)req->user_ctx;   /* user_ctx：注册期注入 */

    char body[128];
    snprintf(body, sizeof(body),
             "{\"ep\":\"small\",\"hits\":%lu,\"note\":\"lwip ch20 lab\"}",
             (unsigned long)(self->hits + 1));
    /* 补空格把响应体垫到 ~96B（HTTP 报文含头 ~140B 量级） */
    size_t n = strlen(body);
    while (n < sizeof(body) && n < 96) {
        body[n++] = ' ';
    }
    body[n] = '\0';

    httpd_resp_set_type(req, "application/json");
    esp_err_t rc = httpd_resp_send(req, body, HTTPD_RESP_USE_STRLEN);
    ep_hit(self, esp_timer_get_time() - t0);
    return rc;
}

/* 实验 A 目标之二：~10KB 档。末字节放轮次水印防客户端端到端误判。 */
static esp_err_t h_big(httpd_req_t *req)
{
    int64_t t0 = esp_timer_get_time();
    ep_stats_t *self = (ep_stats_t *)req->user_ctx;

    g_big_body[BIG_BODY_LEN - 1] = (char)('A' + (self->hits % 26));

    httpd_resp_set_type(req, "application/octet-stream");
    esp_err_t rc = httpd_resp_send(req, g_big_body, BIG_BODY_LEN);
    ep_hit(self, esp_timer_get_time() - t0);
    return rc;
}

/* 实验 C 目标：POST /echo?cap=N。逐段 httpd_req_recv 消费请求体；
 * cap= 即手工应用层上限——组件自身的 HTTPD_413 错误码没有任何自动触发点
 * （源码结论：HTTPD_413_CONTENT_TOO_LARGE 仅存在于错误码表），
 * Content-Length 上限必须由应用自己实现。 */
static esp_err_t h_echo_post(httpd_req_t *req)
{
    int64_t t0 = esp_timer_get_time();
    ep_stats_t *self = (ep_stats_t *)req->user_ctx;

    long cap = 0;
    char qval[64] = "";
    if (httpd_req_get_url_query_str(req, qval, sizeof(qval)) == ESP_OK) {
        char cbuf[24] = "";
        if (httpd_query_key_value(qval, "cap", cbuf, sizeof(cbuf)) == ESP_OK) {
            cap = atol(cbuf);
        }
    }

    size_t total = (size_t)req->content_len;
    if (cap > 0 && total > (size_t)cap) {
        ESP_LOGW(TAG, "POST rejected: content_len=%u > cap=%ld",
                 (unsigned)total, cap);
        httpd_resp_send_err(req, HTTPD_413_CONTENT_TOO_LARGE,
                            "body exceeds app-level cap");
        ep_hit(self, esp_timer_get_time() - t0);
        return ESP_FAIL;                    /* 关闭该会话 */
    }

    s_busy_posts++;
    static char sink[1024];                 /* 丢弃式消费：不缓存整个 body */
    size_t got = 0;
    while (got < total) {
        size_t want = total - got;
        if (want > sizeof(sink)) want = sizeof(sink);
        int n = httpd_req_recv(req, sink, want);
        if (n <= 0) {                       /* 对端停滞/断开：失败关会话 */
            ESP_LOGW(TAG, "POST abort at %u/%u rc=%d", (unsigned)got,
                     (unsigned)total, n);
            s_busy_posts--;
            ep_hit(self, esp_timer_get_time() - t0);
            return ESP_FAIL;
        }
        got += (size_t)n;
    }
    s_busy_posts--;

    char body[96];
    snprintf(body, sizeof(body), "consumed %u bytes", (unsigned)got);
    httpd_resp_set_type(req, "text/plain");
    esp_err_t rc = httpd_resp_send(req, body, HTTPD_RESP_USE_STRLEN);
    ESP_LOGW(TAG, "POST done len=%u elapsed_us=%lld", (unsigned)got,
             (long long)(esp_timer_get_time() - t0));
    ep_hit(self, esp_timer_get_time() - t0);
    return rc;
}

/* 异步工作队列模式：handler 拷出异步请求后立刻返回，
 * 重活由独立任务完成并接管响应；期间主循环照常服务其他会话。
 * （对应 httpd_txrx.c 的 httpd_req_async_handler_begin/complete）
 * 注意 for_async_req=true 的会话同时被主循环跳过、对 LRU 免疫。 */
static void async_worker(void *arg)
{
    httpd_req_t *r = (httpd_req_t *)arg;
    vTaskDelay(pdMS_TO_TICKS(300));              /* 模拟重活：300ms */

    char body[128];
    snprintf(body, sizeof(body), "async done after 300ms");
    httpd_resp_set_type(r, "text/plain");
    httpd_resp_send(r, body, HTTPD_RESP_USE_STRLEN);
    httpd_req_async_handler_complete(r);         /* 归还 fd 给主循环 select */
    vTaskDelete(NULL);
}

static esp_err_t h_async(httpd_req_t *req)
{
    int64_t t0 = esp_timer_get_time();
    ep_stats_t *self = (ep_stats_t *)req->user_ctx;

    httpd_req_t *copy = NULL;
    if (httpd_req_async_handler_begin(req, &copy) != ESP_OK) {
        return ESP_FAIL;
    }
    ep_hit(self, esp_timer_get_time() - t0);     /* 只计移交耗时 */
    if (xTaskCreate(async_worker, "async_wk", 3072, copy, 6, NULL) != pdPASS) {
        httpd_req_async_handler_complete(copy);
        return ESP_FAIL;
    }
    return ESP_OK;
}

/* ------------------------- httpd 启停 ----------------------------------- */

static httpd_handle_t start_httpd(uint16_t recv_to_s, bool lru)
{
    httpd_config_t cfg = HTTPD_DEFAULT_CONFIG();
    cfg.server_port       = HTTP_PORT;
    cfg.core_id           = 0;                   /* 钉核 0 保证矩阵稳定 */
    cfg.task_priority     = 5;                   /* 默认值，显式写出便于引用 */
    cfg.recv_wait_timeout = recv_to_s;
    cfg.send_wait_timeout = recv_to_s;           /* 两口径同步改，实验可控 */
    cfg.lru_purge_enable  = lru;

    httpd_handle_t h = NULL;
    esp_err_t err = httpd_start(&h, &cfg);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "httpd_start failed %s", esp_err_to_name(err));
        return NULL;
    }
    httpd_register_uri_handler(h, &(httpd_uri_t){
        .uri = "/small", .method = HTTP_GET,  .handler = h_small, .user_ctx = &g_small });
    httpd_register_uri_handler(h, &(httpd_uri_t){
        .uri = "/big",   .method = HTTP_GET,  .handler = h_big,   .user_ctx = &g_big });
    httpd_register_uri_handler(h, &(httpd_uri_t){
        .uri = "/echo",  .method = HTTP_POST, .handler = h_echo_post, .user_ctx = &g_post });
    httpd_register_uri_handler(h, &(httpd_uri_t){
        .uri = "/async", .method = HTTP_GET,  .handler = h_async, .user_ctx = &g_async });

    ESP_LOGW(TAG, "httpd START port=%d recv_to=%ds send_to=%ds lru=%d "
             "max_sockets=%d backlog=%d stack=%u prio=%u ctrl_port=%d",
             cfg.server_port, (int)cfg.recv_wait_timeout, (int)cfg.send_wait_timeout,
             (int)lru, (int)cfg.max_open_sockets, (int)cfg.backlog_conn,
             (unsigned)cfg.stack_size, (unsigned)cfg.task_priority,
             (int)cfg.ctrl_port);
    return h;
}

/* ------------------------- 控制通道（ch19 模式） ------------------------ */

static int s_ctrl_sock = -1;

static void ctrl_reply(const char *fmt, ...)
{
    char buf[768];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (n > 0 && s_ctrl_sock >= 0) {
        (void)send(s_ctrl_sock, buf, (size_t)n, 0);
    }
}

/* restart <recv_to> <lru>：运行时调参免烧写——Slowloris 防线的第二道验证用 */
static void do_restart(const char *line)
{
    int to = 5, lru = 0;
    sscanf(line, "%*s %d %d", &to, &lru);
    if (to < 1 || to > 60) to = 5;
    if (s_server) httpd_stop(s_server);
    vTaskDelay(pdMS_TO_TICKS(100));
    s_server = start_httpd((uint16_t)to, lru != 0);
    ctrl_reply("$$$ RESTART recv_wait_timeout=%ds lru=%d rc=%s\n", to, lru,
               s_server ? "OK" : "FAIL");
}

static void do_stats(void)
{
    uint32_t conn = s_evt_counts[HTTP_SERVER_EVENT_ON_CONNECTED];
    uint32_t disc = s_evt_counts[HTTP_SERVER_EVENT_DISCONNECTED];
    ctrl_reply("$$$ STATS conn=%lu disc=%lu busy_post=%d heap_free=%u largest=%u min8=%u\n",
               (unsigned long)conn, (unsigned long)disc, (int)s_busy_posts,
               (unsigned)heap_caps_get_free_size(MALLOC_CAP_DEFAULT),
               (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_DEFAULT),
               (unsigned)heap_caps_get_minimum_free_size(MALLOC_CAP_DEFAULT));

    ep_stats_t *eps[] = { &g_small, &g_big, &g_post, &g_async };
    for (int i = 0; i < 4; i++) {
        ep_stats_t *e = eps[i];
        uint64_t avg = e->hits ? e->sum_us / e->hits : 0;
        ctrl_reply("$$$ EP %-7s hits=%lu avg_us=%llu max_us=%lu\n",
                   e->name, (unsigned long)e->hits,
                   (unsigned long long)avg, (unsigned long)e->max_us);
    }
    ctrl_reply("$$$ ENDSTATS\n");
}

static void ctrl_exec(char *line)
{
    char word[32];
    if (sscanf(line, "%31s", word) != 1) return;

    if      (!strcmp(word, "hello"))   ctrl_reply("$$$ ch20 ready\n");
    else if (!strcmp(word, "st"))      do_stats();
    else if (!strcmp(word, "restart")) do_restart(line);
    else                               ctrl_reply("$$$ ERR unknown cmd\n");
}

static void ctrl_server_task(void *arg)
{
    (void)arg;
    int lsock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    struct sockaddr_in la = { .sin_family = AF_INET,
                              .sin_port = htons(CTRL_PORT),
                              .sin_addr.s_addr = htonl(INADDR_ANY) };
    int opt = 1;
    setsockopt(lsock, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    assert(bind(lsock, (struct sockaddr *)&la, sizeof(la)) == 0);
    assert(listen(lsock, 1) == 0);
    printf("$$$ CTRLREADY port=%d\n", CTRL_PORT);
    fflush(stdout);

    char buf[128];
    while (1) {
        int sock = accept(lsock, NULL, NULL);
        if (sock < 0) continue;
        s_ctrl_sock = sock;
        int len = recv(sock, buf, sizeof(buf) - 1, 0);   /* 一条连接一条命令 */
        if (len > 0) {
            buf[len] = '\0';
            ctrl_exec(buf);
        }
        close(sock);
        s_ctrl_sock = -1;
    }
}

/* ------------------------- app_main ------------------------------------- */

void app_main(void)
{
    ESP_LOGW(TAG, "== ch20 lab: esp_http_server bench / slowloris / big-post ==");

    ESP_ERROR_CHECK(esp_netif_init());                 /* 必须先于任何 socket */
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    s_got_ip = xSemaphoreCreateBinary();

    /* 连接级事件记账（组件经默认事件循环派发 ESP_HTTP_SERVER_EVENT） */
    ESP_ERROR_CHECK(esp_event_handler_register(ESP_HTTP_SERVER_EVENT, ESP_EVENT_ANY_ID,
                                               httpd_evt_handler, NULL));

    /* 控制平面钉核 1 高优先级：活在受害者带宽之外（ch19 教训） */
    xTaskCreatePinnedToCore(ctrl_server_task, "ctrl_srv", 4096, NULL, 22, NULL, 1);

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

    ESP_ERROR_CHECK(esp_event_handler_register(ETH_EVENT, ESP_EVENT_ANY_ID,
                                               eth_event_handler, NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_ETH_GOT_IP,
                                               ip_event_handler, NULL));

    esp_eth_netif_glue_handle_t glue = esp_eth_new_netif_glue(eth_handle);
    ESP_ERROR_CHECK(esp_netif_attach(eth_netif, glue));
    ESP_ERROR_CHECK(esp_eth_start(eth_handle));

    if (xSemaphoreTake(s_got_ip, pdMS_TO_TICKS(15000)) != pdTRUE) {
        ESP_LOGE(TAG, "DHCP timeout");
        return;
    }

    /* 固化 /big 响应体：一行头部 + 周期性标记便于核对字节量 */
    memset(g_big_body, '.', sizeof(g_big_body));
    for (size_t i = 0; i < BIG_BODY_LEN; i += 64) {
        memcpy(g_big_body + i, "[BIG ch20 lwip lab]", 19);
    }

    memset((void *)s_evt_counts, 0, sizeof(s_evt_counts));
    s_server = start_httpd(5, false);          /* 默认口径：recv_to=5s, lru=off */
    printf("$$$ HTTPREADY port=%d ctrl=%d\n", HTTP_PORT, CTRL_PORT);
    fflush(stdout);

    while (1) vTaskDelay(pdMS_TO_TICKS(60000));
}
