/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * ex05 http-server —— esp_http_server 服务模板（QEMU openeth + SLIRP）
 *
 * 目标：一个干净的 HTTP 服务起点工程（复制改名即可用）：
 *   - GET /hello  纯文本应答；
 *   - GET /info   JSON 应答：IP / uptime / heap free / error 计数；
 *   - 其余 URI 走 esp_http_server 默认 404。
 *
 * 骨架与《lwIP 深度解析》ch03/ch20 一致：esp_netif_init 第一句网络调用 →
 * openeth MAC + generic PHY → DHCP 等 GOT_IP → 再启动业务（httpd）。
 * 主机访问经 hostfwd tcp::8240-:80（套件端口表 ex05 号段 8240）。
 *
 * 运行环境：ESP-IDF v6.0.2 + qemu-system-xtensa (Espressif fork)，
 *           -nic user,model=open_eth,hostfwd=tcp::8240-:80
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <assert.h>

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

static const char *TAG = "ex05";

#define DHCP_TIMEOUT_MS 15000

/* ------------------------- 全局状态 ------------------------------------- */

static SemaphoreHandle_t s_got_ip;
static esp_ip4_addr_t    s_ip;          /* GOT_IP 事件填入，供 /info 使用 */
static httpd_handle_t    s_server;

/* 端点计数器：注册期经 user_ctx 注入 handler（模板惯例，官方示例同款手法） */
typedef struct {
    const char       *name;
    volatile uint32_t hits;
} ep_t;

static ep_t g_ep_hello = { .name = "/hello" };
static ep_t g_ep_info  = { .name = "/info"  };

/* error 计数：ESP_HTTP_SERVER_EVENT_ERROR（组件级错误事件）累计次数。
 * 回调跑在默认事件循环任务，handler 跑在 httpd 任务；uint32 读改写
 * 竞争窗口对演示用途可忽略，volatile 保证可见性即可。 */
static volatile uint32_t g_errors;

/* ------------------------- 以太网 bring-up（标准骨架） -------------------- */

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
    s_ip = evt->ip_info.ip;
    ESP_LOGI(TAG, "GOT_IP: " IPSTR, IP2STR(&s_ip));
    xSemaphoreGive(s_got_ip);
}

/* ------------------------- ESP_HTTP_SERVER_EVENT 记账 -------------------- */

static void httpd_evt_handler(void *arg, esp_event_base_t base,
                              int32_t id, void *data)
{
    if (id == HTTP_SERVER_EVENT_ERROR) {
        g_errors++;
        ESP_LOGW(TAG, "HTTP_SERVER_EVENT_ERROR #%lu", (unsigned long)g_errors);
    }
}

/* ------------------------- URI handlers --------------------------------- */

static esp_err_t h_hello(httpd_req_t *req)
{
    ep_t *self = (ep_t *)req->user_ctx;
    uint32_t n = ++self->hits;
    ESP_LOGI(TAG, "GET %s -> 200 (hits=%lu)", self->name, (unsigned long)n);

    char body[96];
    snprintf(body, sizeof(body),
             "hello from ex05-http-server (esp_http_server on QEMU openeth)\n");
    httpd_resp_set_type(req, "text/plain");
    return httpd_resp_send(req, body, HTTPD_RESP_USE_STRLEN);
}

static esp_err_t h_info(httpd_req_t *req)
{
    ep_t *self = (ep_t *)req->user_ctx;
    uint32_t n = ++self->hits;
    ESP_LOGI(TAG, "GET %s -> 200 (hits=%lu)", self->name, (unsigned long)n);

    char body[192];
    snprintf(body, sizeof(body),
             "{\"ip\":\"" IPSTR "\",\"uptime_s\":%llu,\"heap_free\":%u,"
             "\"errors\":%lu,\"hits_hello\":%lu,\"hits_info\":%lu}\n",
             IP2STR(&s_ip),
             (unsigned long long)(esp_timer_get_time() / 1000000ULL),
             (unsigned)heap_caps_get_free_size(MALLOC_CAP_DEFAULT),
             (unsigned long)g_errors,
             (unsigned long)g_ep_hello.hits,
             (unsigned long)self->hits);
    httpd_resp_set_type(req, "application/json");
    return httpd_resp_send(req, body, HTTPD_RESP_USE_STRLEN);
}

/* /no-such-uri 不需要任何代码：uri 未命中时 httpd_task 调默认错误页
 * httpd_resp_send_err(HTTPD_404_NOT_FOUND)，等价于框架替我们注册了兜底。 */

/* ------------------------- httpd 启动 ----------------------------------- */

static httpd_handle_t start_httpd(void)
{
    /* HTTPD_DEFAULT_CONFIG 口径即 README keep-alive 说明的分析对象：
     * recv_wait_timeout=5s / max_open_sockets=7 / backlog_conn=5 /
     * lru_purge_enable=false / keep_alive_enable=false(TCP SO_KEEPALIVE)。 */
    httpd_config_t cfg = HTTPD_DEFAULT_CONFIG();
    cfg.server_port = 80;                     /* 主机侧 hostfwd tcp::8240-:80 */

    httpd_handle_t h = NULL;
    esp_err_t err = httpd_start(&h, &cfg);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "httpd_start failed %s", esp_err_to_name(err));
        return NULL;
    }

    httpd_register_uri_handler(h, &(httpd_uri_t){
        .uri = "/hello", .method = HTTP_GET, .handler = h_hello, .user_ctx = &g_ep_hello });
    httpd_register_uri_handler(h, &(httpd_uri_t){
        .uri = "/info",  .method = HTTP_GET, .handler = h_info,  .user_ctx = &g_ep_info });

    /* 机器可读 READY 行 + 配置事实行（CI/grep 可断言流程推进） */
    printf("$$$ READY role=httpd port=%d max_sockets=%d backlog=%d "
           "recv_to=%ds send_to=%ds lru_purge=%d fw=%s %s\n",
           cfg.server_port, cfg.max_open_sockets, cfg.backlog_conn,
           cfg.recv_wait_timeout, cfg.send_wait_timeout,
           (int)cfg.lru_purge_enable, __DATE__, __TIME__);
    fflush(stdout);
    return h;
}

/* ------------------------- app_main ------------------------------------- */

void app_main(void)
{
    ESP_LOGI(TAG, "== ex05 http-server: esp_http_server over QEMU openeth ==");

    /* 必须先于任何 socket/netconn 创建（tcpip 邮箱由它创建） */
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    s_got_ip = xSemaphoreCreateBinary();

    /* 组件事件记账（ERROR 计数进 /info） */
    ESP_ERROR_CHECK(esp_event_handler_register(ESP_HTTP_SERVER_EVENT,
                                               ESP_EVENT_ANY_ID,
                                               httpd_evt_handler, NULL));

    esp_netif_config_t netif_cfg = ESP_NETIF_DEFAULT_ETH();
    esp_netif_t *eth_netif = esp_netif_new(&netif_cfg);

    eth_mac_config_t mac_cfg = ETH_MAC_DEFAULT_CONFIG();
    eth_phy_config_t phy_cfg = ETH_PHY_DEFAULT_CONFIG();
    phy_cfg.reset_gpio_num      = -1;   /* 虚拟 PHY 无复位引脚 */
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

    if (xSemaphoreTake(s_got_ip, pdMS_TO_TICKS(DHCP_TIMEOUT_MS)) != pdTRUE) {
        ESP_LOGE(TAG, "DHCP timeout after %d ms -- check QEMU -nic hostfwd",
                 DHCP_TIMEOUT_MS);
        return;
    }

    s_server = start_httpd();
    if (s_server == NULL) {
        return;
    }

    while (1) {
        vTaskDelay(pdMS_TO_TICKS(60000));
    }
}
