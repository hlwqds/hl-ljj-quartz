/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * lwIP 深度解析（十八）实验工程：ESP32 WiFi 与 lwIP 的对接
 *
 * 本环境 QEMU 无 esp-wifi-mac，WiFi 不能仿真运行。本章实验定位：
 *   A. 编译期验证：把 wifi_sta netif 整条接缝链真实链接进固件
 *      （esp_netif_create_default_wifi_sta() 对象级创建，不触碰射频/esp_wifi_init），
 *      之后用 xtensa-esp32-elf-nm 从 elf 里 dump 接缝符号表。
 *   B. 以太网对照实验（QEMU 可跑）：openeth bring-up + TCP echo server；
 *      通过 tcpip_callback 在 tcpip 线程内换 netif->linkoutput 为「10% 随机丢帧」
 *      包装器，模拟 WiFi 无线损耗在 lwIP 层的表现（方法学替换，非真 WiFi）。
 *      宿主机用 tools/bench.py 分别测 baseline / lossy 两相位的 RTT 与吞吐。
 *
 * 运行环境：ESP-IDF v6.0.2 + qemu-system-xtensa (Espressif fork)，
 *           -nic user,model=open_eth,hostfwd=tcp::8050-:8888
 */

#include <stdio.h>
#include <string.h>
#include <assert.h>
#include <errno.h>

#include <sys/socket.h>
#include <netinet/in.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"

#include "esp_log.h"
#include "esp_event.h"
#include "esp_netif.h"
#include "esp_eth.h"
#include "esp_eth_mac_openeth.h"   /* esp_eth_mac_new_openeth() */
/* ---- 实验 A：编译期验证的接缝头文件 ---- */
#include "esp_wifi.h"            /* esp_wifi_init 等（本工程不调用其运行路径） */
#include "esp_wifi_default.h"    /* esp_netif_create_default_wifi_sta() */

#include "lwip/err.h"
#include "lwip/tcpip.h"
#include "lwip/netif.h"
#include "lwip/pbuf.h"
#include "esp_netif_net_stack.h" /* esp_netif_get_netif_impl() */

static const char *TAG = "ch18lab";

#define ECHO_PORT        8888     /* 主机侧经 hostfwd tcp::8050-:8888 访问 */
#define DHCP_TIMEOUT_MS  10000
#define KEEPALIVE_MS     120000   /* 两个 bench 相位 + 缓冲 */

#define LOSS_PERCENT     10       /* linkoutput 注入丢帧概率 (%) */

static SemaphoreHandle_t s_got_ip;      /* DHCP 完成信号量 */
static esp_ip4_addr_t s_ip, s_nm, s_gw;

static SemaphoreHandle_t s_ctl_sem;     /* echo 任务 -> app 任务的注入切换请求 */
static volatile int s_ctl_op;           /* 0=install 1=remove */

/* ------------------------- TX 故障注入（WiFi 损耗替身） -------------------------
 * 关键方法学：丢帧时返回 ERR_OK —— 发送方以为帧已交给介质（驱动收下了），
 * 损耗发生在“空中”，lwIP 层无任何错误反馈。这与真实无线一致：
 * 驱动不会告诉 TCP「这帧丢了」，只能靠对端沉默来重传。
 */

typedef err_t (*linkoutput_fn_t)(struct netif *, struct pbuf *);

static linkoutput_fn_t s_orig_linkoutput;
static uint32_t s_seed = 0x20260826u;   /* 固定种子 → 结果可复现 */
static uint32_t s_pass, s_drop;

static err_t lossy_linkoutput(struct netif *netif, struct pbuf *p)
{
    s_seed ^= s_seed << 13;
    s_seed ^= s_seed >> 17;
    s_seed ^= s_seed << 5;
    if ((s_seed % 100u) < (uint32_t)LOSS_PERCENT) {
        s_drop++;
        return ERR_OK;                  /* 帧在“空中”消失 */
    }
    s_pass++;
    return s_orig_linkoutput(netif, p);
}

/* 必须在 tcpip 线程内换函数指针（ch12 验证过的标准手法） */
static void install_lossy_cb(void *arg)
{
    struct netif *n = (struct netif *)arg;
    assert(s_orig_linkoutput == NULL);
    s_orig_linkoutput = n->linkoutput;
    n->linkoutput = lossy_linkoutput;
    ESP_LOGI(TAG, "INJECT: linkoutput wrapped, loss=%d%% seed=0x%08lx",
             LOSS_PERCENT, (unsigned long)s_seed);
}

static void remove_lossy_cb(void *arg)
{
    struct netif *n = (struct netif *)arg;
    if (s_orig_linkoutput) {
        n->linkoutput = s_orig_linkoutput;
        ESP_LOGI(TAG, "INJECT: removed, pass=%lu drop=%lu (%lu%%)",
                 (unsigned long)s_pass, (unsigned long)s_drop,
                 (unsigned long)(100UL * s_drop / (s_pass + s_drop ? (s_pass + s_drop) : 1)));
        s_orig_linkoutput = NULL;
    }
}

/* ------------------------- echo server（含相位控制字） ------------------------- */

#define CTL_ON  "CTL:LOSSY_ON"
#define CTL_OFF "CTL:LOSSY_OFF"

static void echo_server_task(void *arg)
{
    static char rx_buf[16384];
    struct sockaddr_in local_addr = {
        .sin_family      = AF_INET,
        .sin_port        = htons(ECHO_PORT),
        .sin_addr.s_addr = htonl(INADDR_ANY),
    };

    int listen_sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    assert(listen_sock >= 0);

    int opt = 1;
    setsockopt(listen_sock, SOCK_STREAM, SO_REUSEADDR, &opt, sizeof(opt));

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
        /* 防呆：读写都设超时，丢包相位下对端半死连接不能把唯一 echo 任务挂死 */
        struct timeval tv_rcv = { .tv_sec = 60, .tv_usec = 0 };
        struct timeval tv_snd = { .tv_sec = 10, .tv_usec = 0 };
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv_rcv, sizeof(tv_rcv));
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv_snd, sizeof(tv_snd));

        uint64_t nmsg = 0, nbytes = 0;
        int len;
        while ((len = recv(sock, rx_buf, sizeof(rx_buf), 0)) > 0) {
            nmsg++; nbytes += len;
            if ((int)len == strlen(CTL_ON) && memcmp(rx_buf, CTL_ON, len) == 0) {
                s_ctl_op = 0;
                xSemaphoreGive(s_ctl_sem);          /* 让 app 任务去切 linkoutput */
                send(sock, "OK\n", 3, 0);
            } else if ((int)len == strlen(CTL_OFF) && memcmp(rx_buf, CTL_OFF, len) == 0) {
                s_ctl_op = 1;
                xSemaphoreGive(s_ctl_sem);
                send(sock, "OK\n", 3, 0);
            } else {
                /* 吞吐测试期禁止逐包刷日志；每 512 个消息报一次心跳 */
                if ((nmsg & 511) == 1) {
                    ESP_LOGI(TAG, "echo: %llu msgs, %llu bytes", nmsg, nbytes);
                }
                send(sock, rx_buf, len, 0);
            }
        }
        close(sock);
        if (len < 0) {
            ESP_LOGI(TAG, "echo: conn aborted err=%d (idle/snd timeout)", errno);
        } else {
            ESP_LOGI(TAG, "echo: client disconnected after %llu msgs/%llu bytes",
                     nmsg, nbytes);
        }
    }
}

/* ------------------------- 事件处理（同 ch3 模板） ------------------------- */

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

void app_main(void)
{
    ESP_LOGI(TAG, "== ch18 lab: wifi seam symbols in elf + openeth lossy-linkoutput A/B ==");

    /* 1. tcpip 任务与默认事件循环 */
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    s_got_ip = xSemaphoreCreateBinary();
    s_ctl_sem = xSemaphoreCreateBinary();

    /* 2. 【实验 A】wifi_sta netif 对象级创建：
     *    只做对象构造 + 默认 handler 注册（内部走 wlanif_init_sta / wlanif_input /
     *    esp_netif_receive / esp_wifi_register_if_rxcb 这条接缝链的符号依赖），
     *    不调 esp_wifi_init/start——QEMU 无射频、libnet80211 无法运行。
     *    这样整条接缝代码被真实链接进 elf，nm 可验证。 */
    esp_netif_t *sta_netif = esp_netif_create_default_wifi_sta();
    ESP_LOGI(TAG, "wifi sta netif object created @%p (object-level only, no RF)", sta_netif);

    /* 3. openeth bring-up（同 ch3 模板） */
    xTaskCreate(echo_server_task, "echo_srv", 8192, NULL, 5, NULL);

    esp_netif_config_t netif_cfg = ESP_NETIF_DEFAULT_ETH();
    esp_netif_t *eth_netif = esp_netif_new(&netif_cfg);

    eth_mac_config_t mac_cfg = ETH_MAC_DEFAULT_CONFIG();
    eth_phy_config_t phy_cfg = ETH_PHY_DEFAULT_CONFIG();
    phy_cfg.reset_gpio_num      = -1;
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
    ESP_ERROR_CHECK(esp_netif_attach(eth_netif, glue));

    ESP_ERROR_CHECK(esp_eth_start(eth_handle));
    ESP_LOGI(TAG, "waiting for DHCP lease ...");

    if (xSemaphoreTake(s_got_ip, pdMS_TO_TICKS(DHCP_TIMEOUT_MS)) != pdTRUE) {
        ESP_LOGE(TAG, "DHCP timeout after %d ms -- check QEMU -nic and events",
                 DHCP_TIMEOUT_MS);
        return;
    }

    /* 打印 lwIP netif 名字，确认注入目标（eth 是 en 前缀） */
    struct netif *lwip_if = (struct netif *)esp_netif_get_netif_impl(eth_netif);
    ESP_LOGI(TAG, "ETH netif impl @%p name=%c%c%d", lwip_if,
             lwip_if->name[0], lwip_if->name[1], lwip_if->num);

    /* 4. 相位循环：由宿主机 bench.py 用控制字切换丢包包装器 */
    while (1) {
        xSemaphoreTake(s_ctl_sem, portMAX_DELAY);
        if (s_ctl_op == 0) {
            tcpip_callback(install_lossy_cb, lwip_if);
        } else {
            tcpip_callback(remove_lossy_cb, lwip_if);
        }
        s_ctl_op = 0;
    }
}
