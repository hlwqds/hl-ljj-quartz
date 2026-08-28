/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * ex08 mqtt-pubsub —— esp-mqtt 客户端模板（QEMU openeth + SLIRP + 宿主 mosquitto）
 *
 * 目标：一个干净的 MQTT 发布/订阅起点工程（复制改名即可用）：
 *   - 订阅 demo/topic（SUBSCRIBED 事件确认）；
 *   - 周期 publish 计数消息（QoS1，经 broker 回环形成自回显）；
 *   - 设置 LWT（异常掉线时由 broker 代发遗嘱到 demo/lwt）；
 *   - CONNECTED / DATA / DISCONNECTED 三类事件全程留真实日志；
 *   - 断线后按固定节奏自动重连、重连成功后在 CONNECTED 里重新订阅
 *     （默认 clean session，broker 不记订阅关系——重订阅是模板必修课）。
 *
 * clientId 必须带唯一后缀：MQTT 协议里同 id 的两个连接会让 broker 踢掉旧连接，
 * 多块板子/多个实例并行时表现为"互踢风暴"（ch21 Batch 6 教训）。本模板用
 * esp_read_mac() 基础 MAC 再叠加开机微秒数做后缀（QEMU 的 MAC 恒为全 0，
 * 只靠 MAC 并行两台虚拟机仍会撞 id）。
 *
 * 网络事实（系列已验证）：SLIRP 下 guest 访问 10.0.2.2:<port> 直接落到宿主机
 * loopback 同端口，因此 mqtt://10.0.2.2:1883 即达宿主机 mosquitto，无需 hostfwd。
 *
 * 组件来源：components/mqtt 是 espressif/mqtt v1.1.0 的树内 vendor 副本
 * （commit 1a1e5788a5cf57a0f44a3c6c061407f6c9be1026），构建零在线拉取；
 * IDF v6 树内的 components/mqtt 目录只剩 test_apps，直接 PRIV_REQUIRES mqtt
 * 会解析到本工程的 components/mqtt（工程组件优先），见 README「离线构建」小节。
 *
 * 运行环境：ESP-IDF v6.0.2 + qemu-system-xtensa (Espressif fork)，
 *           -nic user,model=open_eth（无 hostfwd）
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
#include "esp_mac.h"
#include "esp_netif.h"
#include "esp_eth.h"

#include "mqtt_client.h"

static const char *TAG = "ex08";

/* ------------------------- 可调参数 ------------------------------------- */

#define BROKER_URI        "mqtt://10.0.2.2:1883" /* SLIRP: 10.0.2.2 -> 宿主 loopback */
#define TOPIC_ECHO        "demo/topic"           /* 订阅 + 自回显主题               */
#define TOPIC_LWT         "demo/lwt"             /* 遗嘱主题                        */
#define PUB_PERIOD_S      3                      /* 计数消息周期                    */
#define KEEPALIVE_S       10                     /* 无声死亡检测窗 [1.5ka, 2ka] 秒   */
#define NET_TIMEOUT_MS    5000                   /* 连接/网络超时                    */
#define CONNECT_WAIT_MS   15000                  /* 首次连接等待                     */
#define LWT_PAYLOAD_FMT   "client %s left unexpectedly (no DISCONNECT)"

/* 重连节奏不设 network.reconnect_timeout_ms：走 esp-mqtt 默认固定间隔
 * MQTT_RECON_DEFAULT_MS = 10*1000（components/mqtt/lib/include/mqtt_config.h:24）。*/

/* ------------------------- 全局状态 ------------------------------------- */

static SemaphoreHandle_t s_got_ip;
static SemaphoreHandle_t s_connected;

static esp_mqtt_client_handle_t s_cli;
static char s_client_id[32];                 /* ex08-aabbccddeeff */
static char s_lwt_payload[96];

static volatile uint32_t g_seq;              /* 已发布计数消息编号               */
static volatile uint32_t g_acked;            /* QoS1 PUBACK 到达计数             */
static volatile uint32_t g_data_total;       /* DATA 事件总数                    */
static volatile uint32_t g_disc_total;       /* DISCONNECTED 事件总数            */
static volatile uint32_t g_connects;         /* CONNECTED 事件总数               */

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
    ESP_LOGI(TAG, "GOT_IP: " IPSTR, IP2STR(&evt->ip_info.ip));
    xSemaphoreGive(s_got_ip);
}

/* ------------------------- MQTT 事件处理 ---------------------------------
 * 事件回调跑在 mqtt 任务；这里只做日志 + 信号量，不做阻塞动作。
 * 三个核心事件 CONNECTED / DATA / DISCONNECTED 各留一行可 grep 的真实日志。
 */

static void mqtt_event_handler(void *handler_args, esp_event_base_t base,
                               int32_t event_id, void *event_data)
{
    (void)handler_args; (void)base;
    esp_mqtt_event_handle_t ev = event_data;

    switch (event_id) {
    case MQTT_EVENT_BEFORE_CONNECT:
        ESP_LOGI(TAG, "[MQTT] BEFORE_CONNECT (uri=%s)", BROKER_URI);
        break;

    case MQTT_EVENT_CONNECTED: {
        g_connects++;
        /* session_present=1 表示 broker 还留着上次的会话（clean_session=false 时
         * 才可能出现）；默认 clean session 下恒为 0。 */
        ESP_LOGI(TAG, "[MQTT] CONNECTED #%lu session_present=%d",
                 (unsigned long)g_connects, ev->session_present);
        printf("$$$ EVT CONNECTED n=%lu\n", (unsigned long)g_connects);

        /* 关键点：默认 clean session，broker 不替我们记住订阅关系，
         * 每次连接成功都必须重新订阅（断线重连场景的必备操作）。 */
        int mid = esp_mqtt_client_subscribe(s_cli, TOPIC_ECHO, 1);
        if (mid > 0) {
            ESP_LOGI(TAG, "[APP] SUBSCRIBE sent topic=%s qos=1 msg_id=%d", TOPIC_ECHO, mid);
        } else {
            ESP_LOGE(TAG, "[APP] SUBSCRIBE failed rc=%d", mid);
        }
        xSemaphoreGive(s_connected);
        break;
    }

    case MQTT_EVENT_SUBSCRIBED:
        ESP_LOGI(TAG, "[MQTT] SUBSCRIBED msg_id=%d (topic=%s confirmed)",
                 ev->msg_id, TOPIC_ECHO);
        printf("$$$ EVT SUBSCRIBED msg_id=%d\n", ev->msg_id);
        break;

    case MQTT_EVENT_PUBLISHED:
        g_acked++;
        /* QoS>=1 的发布在收到 broker PUBACK 后触发；每条计数消息各一次。 */
        break;

    case MQTT_EVENT_DATA: {
        g_data_total++;
        /* 区分"自己计数消息的回环回显"与"宿主 demo_pub.sh 注入的外部消息"：
         * 只看 payload 前缀，topic 相同（这就是发布/订阅的解耦本质）。
         * 注意 ESP_LOGI 的格式串必须是编译期字面量，不能放运行期三目。 */
        if (ev->data_len >= 15 && strncmp(ev->data, "ex08-counter=", 13) == 0) {
            ESP_LOGI(TAG,
                     "[MQTT] DATA #%lu (self-echo) topic=%.*s qos=%d len=%d data=%.*s",
                     (unsigned long)g_data_total,
                     ev->topic_len, ev->topic, ev->qos, ev->data_len,
                     ev->data_len, ev->data);
        } else {
            ESP_LOGI(TAG,
                     "[MQTT] DATA #%lu (external)  topic=%.*s qos=%d len=%d data=%.*s",
                     (unsigned long)g_data_total,
                     ev->topic_len, ev->topic, ev->qos, ev->data_len,
                     ev->data_len, ev->data);
        }
        break;
    }

    case MQTT_EVENT_DISCONNECTED:
        g_disc_total++;
        /* TCP FIN/RST（broker 被 kill）、keepalive 判死（对端静默）都会到这里；
         * 之后客户端按固定间隔自动重连，无需应用干预。 */
        ESP_LOGW(TAG, "[MQTT] DISCONNECTED #%lu -> auto-reconnect in ~10s intervals",
                 (unsigned long)g_disc_total);
        printf("$$$ EVT DISCONNECTED n=%lu outbox_bytes=%u\n",
               (unsigned long)g_disc_total,
               (unsigned)esp_mqtt_client_get_outbox_size(s_cli));
        break;

    case MQTT_EVENT_ERROR:
        ESP_LOGW(TAG, "[MQTT] ERROR type=%d sock_errno=%d connect_rc=%d",
                 ev->error_handle->error_type,
                 ev->error_handle->esp_transport_sock_errno,
                 (int)ev->error_handle->connect_return_code);
        break;

    case MQTT_EVENT_DELETED:
        ESP_LOGD(TAG, "[MQTT] DELETED msg_id=%d", ev->msg_id);
        break;

    default:
        break;
    }
}

/* ------------------------- app_main ------------------------------------- */

void app_main(void)
{
    ESP_LOGI(TAG, "== ex08 mqtt-pubsub: esp-mqtt over QEMU openeth ==");

    /* 必须先于任何 socket/netconn 创建（tcpip 邮箱由它创建） */
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    s_got_ip    = xSemaphoreCreateBinary();
    s_connected = xSemaphoreCreateBinary();

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

    if (xSemaphoreTake(s_got_ip, pdMS_TO_TICKS(15000)) != pdTRUE) {
        ESP_LOGE(TAG, "DHCP timeout after 15000 ms -- check QEMU -nic");
        return;
    }

    /* --- clientId：MAC 后缀 + 开机时刻后缀（双重防互踢）---
     * 只用 MAC 还不够：本环境 QEMU 的 eFuse 基础 MAC 恒为全 0
     * （READY 行可见 clientId=ex08-...-usXXXXXX 的实测形态），两台并行
     * 虚拟机会拿到相同 id 互踢；拼上 esp_timer_get_time() 开机微秒数，
     * 并行实例天然错开（ch21 互踢风暴教训，CONVENTIONS Batch 6）。 */
    uint8_t mac_id[6] = { 0 };
    ESP_ERROR_CHECK(esp_read_mac(mac_id, ESP_MAC_WIFI_STA));
    snprintf(s_client_id, sizeof(s_client_id), "ex08-%02x%02x%02x-us%lld",
             mac_id[3], mac_id[4], mac_id[5],
             (long long)(esp_timer_get_time() % 100000000LL));
    snprintf(s_lwt_payload, sizeof(s_lwt_payload), LWT_PAYLOAD_FMT, s_client_id);

    /* --- MQTT 客户端配置 --- */
    esp_mqtt_client_config_t cfg = { 0 };
    cfg.broker.address.uri         = BROKER_URI;
    cfg.credentials.client_id      = s_client_id;
    cfg.session.keepalive          = KEEPALIVE_S;
    cfg.network.timeout_ms         = NET_TIMEOUT_MS;
    /* 遗嘱：TCP 在未发 MQTT DISCONNECT 时断开（kill -9 / 掉电 / 崩溃复位），
     * broker 会代为发布这条消息（ch21 教训/CONVENTIONS Batch 6：
     * 干净的 esp_mqtt_client_disconnect() 不会触发遗嘱）。 */
    cfg.session.last_will.topic    = TOPIC_LWT;
    cfg.session.last_will.msg      = s_lwt_payload;
    cfg.session.last_will.msg_len  = (int)strlen(s_lwt_payload);
    cfg.session.last_will.qos      = 1;
    cfg.session.last_will.retain   = 0;

    s_cli = esp_mqtt_client_init(&cfg);
    assert(s_cli != NULL);
    ESP_ERROR_CHECK(esp_mqtt_client_register_event(s_cli, MQTT_EVENT_ANY,
                                                   mqtt_event_handler, NULL));

    /* 机器可读 READY 行（CI/grep 可断言流程推进；fw= 时间戳防跑旧镜像） */
    printf("$$$ READY role=mqtt-client uri=%s clientId=%s sub=%s lwt=%s "
           "ka=%ds pub_period=%ds fw=%s %s\n",
           BROKER_URI, s_client_id, TOPIC_ECHO, TOPIC_LWT,
           KEEPALIVE_S, PUB_PERIOD_S, __DATE__, __TIME__);
    fflush(stdout);

    ESP_ERROR_CHECK(esp_mqtt_client_start(s_cli));

    if (xSemaphoreTake(s_connected, pdMS_TO_TICKS(CONNECT_WAIT_MS)) != pdTRUE) {
        ESP_LOGE(TAG, "first CONNECT not established in %d ms -- "
                      "is tools/run_broker.sh started?", CONNECT_WAIT_MS);
        /* 即使失败也进入发布循环：断线期间 QoS1 消息进 outbox，broker 回来后排空 */
    }

    /* --- 主循环：周期 publish 计数消息（QoS1）---
     * 正常在线时消息经 broker 回环回到自己（DATA 自回显）；断线期间入 outbox，
     * 重连成功后统一定向排空（DISCONNECTED 行会打印 outbox 积压字节数）。 */
    while (1) {
        vTaskDelay(pdMS_TO_TICKS(PUB_PERIOD_S * 1000));

        char payload[64];
        snprintf(payload, sizeof(payload),
                 "ex08-counter=%lu uptime_ms=%lld",
                 (unsigned long)(g_seq + 1), esp_timer_get_time() / 1000);

        int mid = esp_mqtt_client_publish(s_cli, TOPIC_ECHO, payload, 0, 1, 0);
        if (mid > 0) {
            g_seq++;
            ESP_LOGI(TAG,
                     "[APP] PUBLISH seq=%lu msg_id=%d topic=%s outbox=%uB acked=%lu",
                     (unsigned long)g_seq, mid, TOPIC_ECHO,
                     (unsigned)esp_mqtt_client_get_outbox_size(s_cli),
                     (unsigned long)g_acked);
        } else if (mid == 0) {
            ESP_LOGW(TAG, "[APP] PUBLISH seq queued as QoS0 path (rc=0)");
        } else {
            ESP_LOGE(TAG, "[APP] PUBLISH rejected rc=%d (outbox full?)", mid);
        }
    }
}
