/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * lwIP 深度解析（三）实验工程：QEMU 网络仿真第一包
 *
 * 本工程是《lwIP 深度解析》系列后续所有联网实验的标准模板：
 *   1. openeth（OpenCores MAC）bring-up：esp_netif + esp_eth + DHCP；
 *   2. 拿到 IP 后用 lwIP 的 ping 应用组件 ping SLIRP 网关 10.0.2.2；
 *   3. 起一个最小 TCP echo server（socket API），配合 QEMU hostfwd 供主机访问；
 *   4. 向 SLIRP 的 DNS 代理发起几次解析，观察其行为。
 *
 * 运行环境：ESP-IDF v6.0.2 + qemu-system-xtensa (Espressif fork)，
 *           -nic user,model=open_eth[,hostfwd=tcp::8003-:8888]
 */

#include <stdio.h>
#include <string.h>
#include <assert.h>
#include <errno.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"

#include "esp_log.h"
#include "esp_event.h"
#include "esp_netif.h"
#include "esp_eth.h"

#include "lwip/inet.h"
#include <netdb.h>

/* IDF v6 中 ping 应用在 lwIP 组件内：components/lwip/include/apps/ping/ping_sock.h */
#include "ping/ping_sock.h"

static const char *TAG = "ch3lab";

#define ECHO_PORT        8888     /* 主机侧经 hostfwd tcp::8003-:8888 访问 */
#define DHCP_TIMEOUT_MS  10000
#define KEEPALIVE_MS     15000    /* 留给主机 nc 连接的窗口 */

static SemaphoreHandle_t s_got_ip;      /* DHCP 完成信号量 */
static esp_ip4_addr_t s_ip, s_nm, s_gw; /* 由 IP_EVENT 回调填入 */

/* ------------------------- 事件处理 ------------------------- */

static void eth_event_handler(void *arg, esp_event_base_t base,
                              int32_t event_id, void *event_data)
{
    /* eth_event_t：ETHERNET_EVENT_START/STOP/CONNECTED/DISCONNECTED */
    switch (event_id) {
    case ETHERNET_EVENT_START:
        ESP_LOGI(TAG, "ETH_EVENT: START");
        break;
    case ETHERNET_EVENT_STOP:
        ESP_LOGI(TAG, "ETH_EVENT: STOP");
        break;
    case ETHERNET_EVENT_CONNECTED:
        ESP_LOGI(TAG, "ETH_EVENT: CONNECTED (link up)");
        break;
    case ETHERNET_EVENT_DISCONNECTED:
        ESP_LOGI(TAG, "ETH_EVENT: DISCONNECTED (link down)");
        break;
    default:
        ESP_LOGI(TAG, "ETH_EVENT: id=%ld", (long)event_id);
        break;
    }
}

static void ip_event_handler(void *arg, esp_event_base_t base,
                             int32_t event_id, void *event_data)
{
    ip_event_got_ip_t *evt = (ip_event_got_ip_t *)event_data;
    s_ip = evt->ip_info.ip;
    s_nm = evt->ip_info.netmask;
    s_gw = evt->ip_info.gw;
    ESP_LOGI(TAG, "GOT_IP: " IPSTR "/" IPSTR " gw " IPSTR,
             IP2STR(&s_ip), IP2STR(&s_nm), IP2STR(&s_gw));
    xSemaphoreGive(s_got_ip);
}

/* ------------------------- 实验 A：ping 网关 ------------------------- */

static void on_ping_success(esp_ping_handle_t hdl, void *args)
{
    uint8_t ttl;
    uint16_t seqno;
    uint32_t elapsed_us, recv_len;
    ip_addr_t from;

    esp_ping_get_profile(hdl, ESP_PING_PROF_SEQNO, &seqno, sizeof(seqno));
    esp_ping_get_profile(hdl, ESP_PING_PROF_TTL, &ttl, sizeof(ttl));
    esp_ping_get_profile(hdl, ESP_PING_PROF_TIMEGAP, &elapsed_us, sizeof(elapsed_us));
    esp_ping_get_profile(hdl, ESP_PING_PROF_SIZE, &recv_len, sizeof(recv_len));
    esp_ping_get_profile(hdl, ESP_PING_PROF_IPADDR, &from, sizeof(from));

    ESP_LOGI(TAG, "%lu bytes from %s icmp_seq=%u ttl=%u time=%lu ms",
             (unsigned long)recv_len, ipaddr_ntoa(&from), seqno, ttl,
             (unsigned long)elapsed_us);
}

static void on_ping_timeout(esp_ping_handle_t hdl, void *args)
{
    uint16_t seqno;
    ip_addr_t from;
    esp_ping_get_profile(hdl, ESP_PING_PROF_SEQNO, &seqno, sizeof(seqno));
    esp_ping_get_profile(hdl, ESP_PING_PROF_IPADDR, &from, sizeof(from));
    ESP_LOGW(TAG, "From %s icmp_seq=%u timeout", ipaddr_ntoa(&from), seqno);
}

static void on_ping_end(esp_ping_handle_t hdl, void *args)
{
    uint32_t sent, received, total_time_ms;

    esp_ping_get_profile(hdl, ESP_PING_PROF_REQUEST, &sent, sizeof(sent));
    esp_ping_get_profile(hdl, ESP_PING_PROF_REPLY, &received, sizeof(received));
    esp_ping_get_profile(hdl, ESP_PING_PROF_DURATION, &total_time_ms, sizeof(total_time_ms));

    ESP_LOGI(TAG, "--- %s ping statistics ---", (const char *)args);
    ESP_LOGI(TAG, "%lu packets transmitted, %lu received, %lu%% packet loss, time %lums",
             (unsigned long)sent, (unsigned long)received,
             sent ? 100UL * (sent - received) / sent : 100,
             (unsigned long)total_time_ms);
}

static void run_ping_gateway(void)
{
    /* 把事件回调里的网关（esp_ip4_addr_t）塞进 lwIP 的 ip_addr_t */
    ip_addr_t target;
    IP_SET_TYPE_VAL(target, IPADDR_TYPE_V4);
    ip4_addr_set_u32(ip_2_ip4(&target), s_gw.addr);

    esp_ping_config_t cfg = ESP_PING_DEFAULT_CONFIG();
    cfg.target_addr = target;
    cfg.count       = 5;
    cfg.interval_ms = 200;   /* 加速实验节奏，SLIRP 网内丢不了包 */
    cfg.timeout_ms  = 1000;

    static const char *target_name = "10.0.2.2 (slirp gateway)";
    esp_ping_callbacks_t cbs = {
        .cb_args         = (void *)target_name,
        .on_ping_success = on_ping_success,
        .on_ping_timeout = on_ping_timeout,
        .on_ping_end     = on_ping_end,
    };
    esp_ping_handle_t hdl = NULL;
    ESP_ERROR_CHECK(esp_ping_new_session(&cfg, &cbs, &hdl));
    esp_ping_start(hdl);
    /* 会话结束时回调打印统计；count*interval 后必然结束，留余量再删会话 */
    vTaskDelay(pdMS_TO_TICKS(cfg.count * cfg.interval_ms + 5 * cfg.timeout_ms));
    esp_ping_stop(hdl);
    esp_ping_delete_session(hdl);
}

/* ------------------------- 实验 B：TCP echo server ------------------------- */

static void echo_server_task(void *arg)
{
    char rx_buf[512];
    struct sockaddr_in local_addr = {
        .sin_family      = AF_INET,
        .sin_port        = htons(ECHO_PORT),
        .sin_addr.s_addr = htonl(INADDR_ANY),
    };

    int listen_sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    assert(listen_sock >= 0);

    int opt = 1;
    setsockopt(listen_sock, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt)); /* 便于重复运行 */

    int err = bind(listen_sock, (struct sockaddr *)&local_addr, sizeof(local_addr));
    if (err != 0) {
        ESP_LOGE(TAG, "bind :%d failed errno=%d", ECHO_PORT, errno);
        vTaskDelete(NULL);
    }
    err = listen(listen_sock, 1);
    assert(err == 0);
    ESP_LOGI(TAG, "echo server listening on 0.0.0.0:%d", ECHO_PORT);

    while (1) {
        struct sockaddr_in src_addr;
        socklen_t addr_len = sizeof(src_addr);
        int sock = accept(listen_sock, (struct sockaddr *)&src_addr, &addr_len);
        if (sock < 0) {
            ESP_LOGE(TAG, "accept failed errno=%d", errno);
            continue;
        }
        ESP_LOGI(TAG, "echo: client %s:%d connected",
                 inet_ntoa(src_addr.sin_addr), ntohs(src_addr.sin_port));

        int len;
        while ((len = recv(sock, rx_buf, sizeof(rx_buf), 0)) > 0) {
            ESP_LOGI(TAG, "echo: recv %d bytes: %.*s", len, len > 80 ? 80 : len, rx_buf);
            send(sock, rx_buf, len, 0);   /* 原样回显 */
        }
        close(sock);
        ESP_LOGI(TAG, "echo: client disconnected");
    }
}

/* ------------------------- 实验 C：DNS 探针 ------------------------- */

static void dns_probe(const char *name)
{
    const struct addrinfo hints = { .ai_family = AF_INET };
    struct addrinfo *res = NULL;

    int rc = getaddrinfo(name, NULL, &hints, &res);
    if (rc != 0 || res == NULL) {
        ESP_LOGW(TAG, "DNS probe \"%s\": FAILED rc=%d", name, rc);
        return;
    }
    struct sockaddr_in *a = (struct sockaddr_in *)res->ai_addr;
    ESP_LOGI(TAG, "DNS probe \"%s\" -> %s", name, inet_ntoa(a->sin_addr));
    freeaddrinfo(res);
}

/* ------------------------- app_main：标准 bring-up 序列 ------------------------- */

void app_main(void)
{
    ESP_LOGI(TAG, "== ch3 lab: openeth bring-up / ping gw / tcp echo / dns ==");

    /* 1. 初始化 TCP/IP 协议栈适配层与默认事件循环 */
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    s_got_ip = xSemaphoreCreateBinary();

    /* 0'. echo server 在 tcpip 线程起来之后再创建：
     * socket() 需要向 tcpip_thread 发消息，mbox 由 esp_netif_init() 创建。
     * 绑定 INADDR_ANY 不依赖已拿到 IP。 */
    xTaskCreate(echo_server_task, "echo_srv", 4096, NULL, 5, NULL);

    /* 2. 创建以太网默认配置的 esp_netif 实例 */
    esp_netif_config_t netif_cfg = ESP_NETIF_DEFAULT_ETH();
    esp_netif_t *eth_netif = esp_netif_new(&netif_cfg);

    /* 3. 组装 MAC 与 PHY 对象（openeth 仅可用于 QEMU） */
    eth_mac_config_t mac_cfg = ETH_MAC_DEFAULT_CONFIG();  /* rx task 4096B prio15 */
    eth_phy_config_t phy_cfg = ETH_PHY_DEFAULT_CONFIG();  /* phy_addr AUTO, autonego 4000ms */
    phy_cfg.reset_gpio_num    = -1;   /* 虚拟 PHY 无复位引脚 */
    phy_cfg.autonego_timeout_ms = 3000;

    esp_eth_mac_t *mac = esp_eth_mac_new_openeth(&mac_cfg);
    assert(mac != NULL);
    esp_eth_phy_t *phy = esp_eth_phy_new_generic(&phy_cfg);
    assert(phy != NULL);

    esp_eth_config_t eth_cfg = ETH_DEFAULT_CONFIG(mac, phy); /* check_link_period_ms=2000 */
    esp_eth_handle_t eth_handle = NULL;
    ESP_ERROR_CHECK(esp_eth_driver_install(&eth_cfg, &eth_handle));

    /* 4. 注册事件处理器：链路事件与拿到 IP 的事件 */
    ESP_ERROR_CHECK(esp_event_handler_register(ETH_EVENT, ESP_EVENT_ANY_ID,
                                               &eth_event_handler, NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_ETH_GOT_IP,
                                               &ip_event_handler, NULL));

    /* 5. 用 glue 层把驱动挂到 netif（netif up 时 glue 会替我们启动 DHCP 客户端） */
    esp_eth_netif_glue_handle_t glue = esp_eth_new_netif_glue(eth_handle);
    ESP_ERROR_CHECK(esp_netif_attach(eth_netif, glue));

    /* 6. 启动驱动：PHY 自协商 → 链路 up → netif up → DHCP → GOT_IP 事件 */
    ESP_ERROR_CHECK(esp_eth_start(eth_handle));
    ESP_LOGI(TAG, "waiting for DHCP lease ...");

    if (xSemaphoreTake(s_got_ip, pdMS_TO_TICKS(DHCP_TIMEOUT_MS)) != pdTRUE) {
        ESP_LOGE(TAG, "DHCP timeout after %d ms -- check QEMU -nic and events",
                 DHCP_TIMEOUT_MS);
        return;
    }

    /* 6'. 顺带打印 DHCP 下发的 DNS 服务器（lwIP 全局存储，非 per-netif） */
    esp_netif_dns_info_t dns_info;
    if (esp_netif_get_dns_info(eth_netif, ESP_NETIF_DNS_MAIN, &dns_info) == ESP_OK) {
        ESP_LOGI(TAG, "DNS server from DHCP: " IPSTR, IP2STR(&dns_info.ip.u_addr.ip4));
    }

    /* 实验 A：设备 -> 主机方向，ping SLIRP 网关 */
    ESP_LOGI(TAG, "--- experiment A: ping gateway %s ---", inet_ntoa(*((struct in_addr *)&s_gw)));
    run_ping_gateway();

    /* 实验 C：SLIRP DNS 行为探针 */
    ESP_LOGI(TAG, "--- experiment C: slirp DNS probes ---");
    dns_probe("baidu.com");                /* 公网域名：看 SLIRP 是否转发到宿主机上游 DNS */
    dns_probe("lwip3slirp.test");          /* 宿主机 /etc/hosts 注入的名字：看 SLIRP 是否查 hosts */
    dns_probe("no-such-host-ch3.invalid"); /* 必然不存在的名字：看 NXDOMAIN/失败路径 */

    ESP_LOGI(TAG, "all experiments done, echo server stays on :%d", ECHO_PORT);
    vTaskDelay(pdMS_TO_TICKS(KEEPALIVE_MS)); /* 给主机端 nc 留出连接窗口 */
}
