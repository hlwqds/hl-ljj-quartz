/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * lwIP 深度解析（二十一）实验工程：MQTT（esp-mqtt）在 lwIP/QEMU 上的弱网行为
 *
 * 单次上电按顺序跑完四个阶段（宿主机侧只负责两种故障动作：SIGSTOP / SIGTERM+重启）：
 *   A. 基线：RTT ping-pong（每种 QoS 各 RTT_ROUNDS 轮，回声经宿主机桥）
 *      + 1KB 消息突发吞吐（QoS0/QoS1 各 BURST_N 条）；
 *   B. 有损链路：linkoutput TX 20% 丢帧注入下 QoS0/QoS1 各 LOSSY_N 条编号消息，
 *      到达数与重复数由宿主机桥侧统计；
 *   C. 无声掉线：宿主机 SIGSTOP 冻结 mosquitto —— 客户端靠 keepalive 检测，
 *      随后离线持续 publish 让 outbox 积压（heap 快照曲线），thaw 后观测排空速度；
 *   D. 硬杀：SIGTERM 杀掉 mosquitto —— FIN 时序 + 固定间隔重连时间轴，
 *      宿主机 HARDKILL_RESTART_S 秒后重启 broker 观察回连。
 *
 * 网络事实（系列 Batch 3 已验证）：SLIRP 下 guest 访问 10.0.2.2:<port> 会落到
 * 宿主机 loopback 同端口，因此直连 mqtt://10.0.2.2:1883 即达宿主机 mosquitto。
 *
 * 运行环境：ESP-IDF v6.0.2 + espressif/mqtt 1.1.0（managed component）
 *           + qemu-system-xtensa（-nic user,model=open_eth，无 hostfwd）
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"

#include "esp_log.h"
#include "esp_event.h"
#include "esp_netif.h"
#include "esp_eth.h"
#include "esp_timer.h"
#include "esp_heap_caps.h"

#include "lwip/tcpip.h"        /* tcpip_callback：把换指针操作投进 tcpip_thread */
#include "lwip/netif.h"
#include "esp_netif_net_stack.h"  /* esp_netif_get_netif_impl() */
#include "mqtt_client.h"

static const char *TAG = "ch21lab";

/* ------------------------------ 可调参数 ------------------------------ */

#define BROKER_URI           "mqtt://10.0.2.2:1883"
#define TOPIC_RTT_REQ        "ch21/rtt/req"    /* 桥收到后立即回 ch21/rtt/rsp */
#define TOPIC_RTT_RSP        "ch21/rtt/rsp"
#define TOPIC_LOSSY_Q0       "ch21/lossy/qos0"
#define TOPIC_LOSSY_Q1       "ch21/lossy/qos1"
#define TOPIC_OFFLINE        "ch21/offline/qos1"

#define MQTT_KEEPALIVE_S     5       /* 短 keepalive：探测节奏 = 半周期 ~2.5s */
#define MQTT_KEEPALIVE_LOSSY 90      /* B 干净段专用：屏蔽 keepalive 抖动，只留丢帧 */
#define RECONNECT_MS_STEADY  2000    /* 平时与 D 阶段的固定重连间隔 */
#define RECONNECT_MS_FREEZE  12000   /* C 阶段冻结期退避基准；排水靠应用层主动
                                        esp_mqtt_client_reconnect()，不依赖它收敛 */
#define NET_TIMEOUT_MS       5000

#define PAYLOAD_LEN          1024    /* 编号消息载荷字节数 */
#define RTT_ROUNDS           25      /* 每种 QoS 的 RTT 轮数 */
#define BURST_N              200     /* 突发吞吐条数 */
#define LOSSY_N              200     /* 丢帧注入下每档 QoS 发送条数 */
#define LOSSY_CADENCE_MS     60      /* 放宽：避免 20% 丢帧 + RTO 退避击穿 TCP 发送缓存
                                        （曾见同步写超时 -> abort 风暴把 qos0 拒收 176 条）*/
#define LOSS_PCT             20      /* TX 帧丢弃概率 % */
#define LOSSY_PAYLOAD_LEN    256     /* lossy 段专用：压低带宽需求，绕开发送缓存击穿 */
#define OUTBOX_ACC_MAX_MSGS  400     /* C 阶段离线积压上限（条）*/
#define OUTBOX_ACC_MAX_MS    8000    /* 以及时间上限 */
#define FREEZE_SETTLE_MS     1500    /* ARM 后先静默片刻再等掉线检测 */
#define FREEZE_CONT_AT_MS    14000   /* 宿主机 kill -CONT 时点约定（=run_lab.sh TOTAL_S）*/
#define HARDKILL_RESTART_S   6       /* D 阶段 broker 掉线窗口（宿主侧重启时机）*/

static volatile uint32_t s_disc_total;     /* DISCONNECTED 事件累计 */

/* ------------------------------ 全局状态 ------------------------------ */

static SemaphoreHandle_t s_got_ip;
static SemaphoreHandle_t s_connected;
static SemaphoreHandle_t s_disconnected;
static SemaphoreHandle_t s_sub_ack;
static SemaphoreHandle_t s_rtt_seen;

static esp_mqtt_client_handle_t s_cli;
static volatile uint32_t s_puback_total;   /* MQTT_EVENT_PUBLISHED 累计（QoS1 ACK 完成数）*/
static volatile int64_t s_ack_ring_ms[64]; /* PUBACK 到达时刻环（排空曲线素材）*/
static volatile int     s_ack_ring_head;

/* C 阶段（冻结检测时延只在 ARM 后结算一次）*/
static volatile bool s_freeze_armed;
static int64_t s_freeze_arm_us;

/* 注入统计 */
static volatile bool s_inj_enable;
static unsigned int  s_inj_seed = 20260826u;
static uint32_t s_inj_dropped, s_inj_passed;

/* --------------------- 故障注入：TX 丢帧（ch12 手法） ---------------------
 * netif->linkoutput 是 pbuf 出网的最后一步（tcpip_thread 上下文执行）。
 * 在这里按概率吞帧并谎报 ERR_OK —— 对上层而言帧已发出，只会觉得链路很吵。
 * tot_len>=60 过滤 ARP 等 42B 小控制帧，避免把地址解析搞瘫。
 */

static err_t (*s_orig_linkoutput)(struct netif *, struct pbuf *);

static err_t ch21_linkoutput(struct netif *netif, struct pbuf *p)
{
    if (s_inj_enable && p->tot_len >= 60 &&
            (int)(rand_r(&s_inj_seed) % 100) < LOSS_PCT) {
        s_inj_dropped++;
        return ERR_OK;
    }
    s_inj_passed++;
    return s_orig_linkoutput(netif, p);
}

static void swap_linkoutput_cb(void *ctx)
{
    struct netif *n = (struct netif *)ctx;
    if (!s_orig_linkoutput) {
        s_orig_linkoutput = n->linkoutput;
        n->linkoutput = ch21_linkoutput;
        ESP_LOGI(TAG, "[INJ] linkoutput wrapped in tcpip_thread");
    }
}

/* --------------------------- 打点小工具 --------------------------- */

static int64_t now_us(void) { return esp_timer_get_time(); }

#define MARK(fmt, ...) ESP_LOGI(TAG, "T+%lldms " fmt, (long long)(now_us() / 1000), ##__VA_ARGS__)

static void heap_line(const char *what)
{
    ESP_LOGI(TAG, "[HEAP] %-24s free=%6u largest=%6u", what,
             (unsigned)heap_caps_get_free_size(MALLOC_CAP_8BIT),
             (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_8BIT));
}

static char paybuf[1200];

static int mk_payload_len(int seq, const char *tag, int len)
{
    int n = snprintf(paybuf, sizeof(paybuf), "i=%d;t=%lld;%s;",
                     seq, (long long)(now_us() / 1000), tag);
    memset(paybuf + n, 'x', len - n);
    return len;
}
static int mk_payload(int seq, const char *tag)
{
    return mk_payload_len(seq, tag, PAYLOAD_LEN);
}

static void drain_sem(SemaphoreHandle_t s)
{
    while (xSemaphoreTake(s, 0) == pdTRUE) { }
}

static void wait_connected(const char *why, int timeout_ms)
{
    drain_sem(s_connected);
    if (xSemaphoreTake(s_connected, pdMS_TO_TICKS(timeout_ms)) == pdTRUE) {
        MARK("connected ok (%s)", why);
    } else {
        MARK("FATAL: not connected (%s) after %dms", why, timeout_ms);
    }
}

/* --------------------------- MQTT 配置 ---------------------------
 * esp_mqtt_set_config() 是整体替换语义（未填字段落回默认值），所以统一从
 * 模板重建整份配置，阶段间只调 reconnect_timeout_ms 一个旋钮。
 */

static esp_mqtt_client_config_t build_cfg(int keepalive_s, int reconnect_ms)
{
    esp_mqtt_client_config_t c = { 0 };
    c.broker.address.uri = BROKER_URI;
    c.session.keepalive = keepalive_s;
    c.network.timeout_ms = NET_TIMEOUT_MS;
    c.network.reconnect_timeout_ms = reconnect_ms;
    /* 默认 in/out buffer 都是 1024B：装不下 1024B 载荷+固定头+topic，
     * 会触发长消息分片路径；这里放大到 2048 保证单包直发。 */
    c.buffer.size = 2048;
    c.buffer.out_size = 2048;
    return c;
}

/* 运行中换配置：set_config 全量替换（顺带重建收发缓冲，持 API 锁安全），
 * 再主动断开让 auto_reconnect 用新参数（keepalive 等）完成下一次 CONNECT。
 */
static void apply_cfg_live(const char *why, int keepalive_s, int reconnect_ms)
{
    esp_mqtt_client_config_t c = build_cfg(keepalive_s, reconnect_ms);
    ESP_ERROR_CHECK(esp_mqtt_set_config(s_cli, &c));
    MARK("cfg->(%s) ka=%ds rec=%dms, 干净断开触发重连", why, keepalive_s, reconnect_ms);
    esp_mqtt_client_disconnect(s_cli);
    wait_connected("reconnect-after-cfg", 15000);
}

/* --------------------------- MQTT 事件处理 --------------------------- */

static void mqtt_event_handler(void *handler_args, esp_event_base_t base,
                               int32_t event_id, void *event_data)
{
    (void)handler_args; (void)base;
    esp_mqtt_event_handle_t ev = event_data;

    switch (event_id) {
    case MQTT_EVENT_BEFORE_CONNECT:
        MARK("EV BEFORE_CONNECT");
        break;
    case MQTT_EVENT_CONNECTED:
        MARK("EV CONNECTED session_present=%d", ev->session_present);
        xSemaphoreGive(s_connected);
        break;
    case MQTT_EVENT_DISCONNECTED:
        s_disc_total++;
        MARK("EV DISCONNECTED (total=%u)", s_disc_total);
        if (s_freeze_armed) {
            long long lag = (long long)((now_us() - s_freeze_arm_us) / 1000);
            MARK("[FREEZE] detect-lag-since-arm=%lldms", lag);
        }
        xSemaphoreGive(s_disconnected);
        break;
    case MQTT_EVENT_SUBSCRIBED:
        MARK("EV SUBSCRIBED msg_id=%d", ev->msg_id);
        xSemaphoreGive(s_sub_ack);
        break;
    case MQTT_EVENT_PUBLISHED: {
        s_puback_total++;
        int slot = s_ack_ring_head % 64;
        s_ack_ring_ms[slot] = esp_timer_get_time() / 1000;
        s_ack_ring_head++;
        break;
    }
    case MQTT_EVENT_DATA: {
        if (ev->topic && ev->topic_len == (int)strlen(TOPIC_RTT_RSP) &&
                strncmp(ev->topic, TOPIC_RTT_RSP, ev->topic_len) == 0) {
            xSemaphoreGive(s_rtt_seen);
        } else {
            MARK("EV DATA topic=%.*s len=%d qos=%d", ev->topic_len, ev->topic,
                 ev->data_len, ev->qos);
        }
        break;
    }
    case MQTT_EVENT_ERROR:
        MARK("EV ERROR type=%d sock_errno=%d connect_rc=%d",
             ev->error_handle->error_type,
             ev->error_handle->esp_transport_sock_errno,
             (int)ev->error_handle->connect_return_code);
        break;
    case MQTT_EVENT_DELETED:
        MARK("EV DELETED msg_id=%d", ev->msg_id);
        break;
    default:
        MARK("EV id=%ld", (long)event_id);
        break;
    }
}

/* --------------------------- 实验 A：RTT --------------------------- */

static int cmp_i64(const void *a, const void *b)
{
    int64_t x = *(const int64_t *)a, y = *(const int64_t *)b;
    return x < y ? -1 : (x > y ? 1 : 0);
}

static void rtt_stage(int qos)
{
    static int64_t dt[RTT_ROUNDS];
    int ok = 0, fail = 0;

    drain_sem(s_rtt_seen);
    for (int i = 0; i < RTT_ROUNDS; i++) {
        mk_payload(i, qos ? "rttq1" : "rttq0");
        int64_t t0 = now_us();
        if (esp_mqtt_client_publish(s_cli, TOPIC_RTT_REQ, paybuf, PAYLOAD_LEN,
                                    qos, 0) < 0) {
            fail++;
            continue;
        }
        if (xSemaphoreTake(s_rtt_seen, pdMS_TO_TICKS(3000)) == pdTRUE) {
            dt[i] = now_us() - t0;
            ok++;
        } else {
            dt[i] = -1;
            fail++;
        }
        vTaskDelay(pdMS_TO_TICKS(5));
    }

    qsort(dt, RTT_ROUNDS, sizeof(int64_t), cmp_i64);
    int cnt = 0;
    int64_t sum = 0;
    for (int i = 0; i < RTT_ROUNDS; i++) {
        if (dt[i] >= 0) { sum += dt[i]; cnt++; }
    }
    if (cnt == 0) {
        MARK("[RTT] qos%d all failed", qos);
        return;
    }
    int lo = RTT_ROUNDS - cnt;                 /* 失败样本(-1)排在数组前部 */
    int idx95 = lo + (cnt * 95) / 100 - 1;
    if (idx95 < lo)                idx95 = lo;
    if (idx95 >= RTT_ROUNDS)       idx95 = RTT_ROUNDS - 1;

    MARK("[RTT] qos%d ok=%d fail=%d min=%lldus p50=%lldus p95=%lldus max=%lldus avg=%lldus",
         qos, ok, fail,
         (long long)dt[lo], (long long)dt[lo + cnt / 2], (long long)dt[idx95],
         (long long)dt[RTT_ROUNDS - 1], (long long)(sum / cnt));
}

/* --------------------------- 实验 A：突发吞吐 --------------------------- */

static void burst_stage(int qos)
{
    uint32_t ack0 = s_puback_total;
    int sent = 0, err = 0;
    int64_t t0 = now_us();

    for (int i = 0; i < BURST_N; i++) {
        mk_payload(i, qos ? "burstq1" : "burstq0");
        /* 注意语义：QoS0 成功时返回 0（无 packet id），负值才是失败 */
        if (esp_mqtt_client_publish(s_cli, qos ? TOPIC_LOSSY_Q1 : TOPIC_LOSSY_Q0,
                                    paybuf, PAYLOAD_LEN, qos, 0) >= 0) {
            sent++;
        } else {
            err++;
        }
    }

    if (qos > 0) {
        /* 等最后一个 PUBACK 到齐再停表：完整度量"发完且被确认"的吞吐 */
        while (s_puback_total < ack0 + (uint32_t)sent &&
                now_us() - t0 < 20000000LL) {
            vTaskDelay(1);
        }
    }
    int64_t span_us = now_us() - t0;
    double secs = (double)span_us / 1000000.0;
    MARK("[BURST] qos%d sent=%d pub_err=%d acked=%u span=%.3fs -> %.0f msg/s (%.1f kbit/s payload)",
         qos, sent, err, s_puback_total - ack0, secs,
         secs > 0 ? sent / secs : 0.0,
         secs > 0 ? sent * PAYLOAD_LEN * 8.0 / 1000.0 / secs : 0.0);
    heap_line(qos ? "after-burst-qos1" : "after-burst-qos0");
    vTaskDelay(pdMS_TO_TICKS(800));   /* 留 SLIRP 一点消化时间 */
}

/* --------------------------- 实验 B：丢帧注入发送 --------------------------- */

static void lossy_send_phase(int qos)
{
    int sent = 0, refused = 0;
    uint32_t ack0 = s_puback_total;

    int skipped = 0;
    for (int i = 0; i < LOSSY_N; ) {
        if (esp_mqtt_client_get_state(s_cli) != MQTT_CLIENT_STATE_CONNECTED) {
            /* 断连窗内不入队，等回连再继续：编号消息一条不丢地按序发满 */
            skipped++;
            if (skipped > 200) { break; }          /* 保护上限 */
            vTaskDelay(pdMS_TO_TICKS(100));
            continue;
        }
        mk_payload_len(i, qos ? "lossyq1" : "lossyq0", LOSSY_PAYLOAD_LEN);
        int rc = esp_mqtt_client_publish(s_cli, qos ? TOPIC_LOSSY_Q1 : TOPIC_LOSSY_Q0,
                                         paybuf, LOSSY_PAYLOAD_LEN, qos, 0);
        if (rc >= 0) {                             /* QoS0 成功返回 0 */
            sent++;
            i++;
        } else {
            refused++;   /* 写超时/瞬时故障；下轮重试同一条 */
        }
        vTaskDelay(pdMS_TO_TICKS(LOSSY_CADENCE_MS));
    }

    MARK("[LOSSY] qos%d enqueue-done sent=%d refused=%d skipped=%d (drop=%u pass=%u)",
         qos, sent, refused, skipped, s_inj_dropped, s_inj_passed);

    if (qos > 0) {
        int64_t t0 = now_us();
        while (s_puback_total < ack0 + (uint32_t)sent &&
                now_us() - t0 < 15000000LL) {
            vTaskDelay(1);
        }
        MARK("[LOSSY] qos%u acked=%u (puback 延迟由桥侧时间戳评估)",
             qos, s_puback_total - ack0);
    }
}

/* --------------------------- 实验 C：离线积压 --------------------------- */

static void accumulate_offline(void)
{
    drain_sem(s_disconnected);

    /* 先把重连间隔拉到冻结窗外（见 RECONNECT_MS_FREEZE 注释），再 ARM */
    esp_mqtt_client_config_t cfg = build_cfg(MQTT_KEEPALIVE_S, RECONNECT_MS_FREEZE);
    ESP_ERROR_CHECK(esp_mqtt_set_config(s_cli, &cfg));

    s_freeze_armed = true;
    s_freeze_arm_us = now_us();
    MARK("APP_PHASE_FREEZE_ARMED (宿主机请立即 kill -STOP mosquitto)");
    heap_line("freeze-armed");

    /* 静默观察期：此后不再主动发包，keepalive 定时器接管 */
    vTaskDelay(pdMS_TO_TICKS(FREEZE_SETTLE_MS));

    if (xSemaphoreTake(s_disconnected, pdMS_TO_TICKS(25000)) != pdTRUE) {
        MARK("[FREEZE] 掉线未被检出（异常！）——放弃本阶段");
        s_freeze_armed = false;
        return;
    }
    s_freeze_armed = false;   /* 已结算，后续 DISCONNECT 不再误报 lag */

    /* ---- 离线持续 publish，让 QoS1 消息堆进 outbox ---- */
    uint32_t n = 0, full_hit = 0;
    int64_t t_acc = now_us();
    uint32_t free0 = heap_caps_get_free_size(MALLOC_CAP_8BIT);
    int64_t ob0 = (int64_t)esp_mqtt_client_get_outbox_size(s_cli);

    while (n < OUTBOX_ACC_MAX_MSGS && now_us() - t_acc < OUTBOX_ACC_MAX_MS * 1000LL) {
        mk_payload((int)n, "offline");
        int rc = esp_mqtt_client_publish(s_cli, TOPIC_OFFLINE, paybuf,
                                         PAYLOAD_LEN, 1, 0);
        if (rc <= 0) {          /* -1：拒绝；-2：outbox 超 limit（未设 limit 则罕见）*/
            full_hit++;
            break;
        }
        n++;
        if (n % 50 == 0) {
            MARK("[OUTBOX] n=%3u wire=%5dB free=%6u largest=%6u",
                 n, (unsigned)esp_mqtt_client_get_outbox_size(s_cli),
                 (unsigned)heap_caps_get_free_size(MALLOC_CAP_8BIT),
                 (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_8BIT));
        }
    }

    int64_t acc_ms = (now_us() - t_acc) / 1000;
    uint32_t free1 = heap_caps_get_free_size(MALLOC_CAP_8BIT);
    unsigned wire_now = esp_mqtt_client_get_outbox_size(s_cli);
    double bpm = n > 0 ? (double)(wire_now - (unsigned)ob0) / n : 0.0;
    MARK("APP_OUTBOX_ACC_DONE n=%u span=%lldms wire_bytes=%u full_hits=%u "
         "heap_drop=%uB bytes_per_msg~%.1f",
         n, (long long)acc_ms, wire_now, full_hit, free0 - free1, bpm);
    MARK("[STATS] disc_total=%u pubacks=%u（freeze 全程）",
         s_disc_total, s_puback_total);
}

/* --------------------------- 以太网事件处理（ch3 模板） --------------------------- */

static void eth_event_handler(void *arg, esp_event_base_t base,
                              int32_t event_id, void *event_data)
{
    (void)arg; (void)base; (void)event_data;
    switch (event_id) {
    case ETHERNET_EVENT_CONNECTED:
        ESP_LOGI(TAG, "ETH: link up");
        break;
    case ETHERNET_EVENT_DISCONNECTED:
        ESP_LOGW(TAG, "ETH: link down");
        break;
    default:
        break;
    }
}

static void ip_event_handler(void *arg, esp_event_base_t base,
                             int32_t event_id, void *event_data)
{
    (void)arg; (void)base;
    ip_event_got_ip_t *evt = (ip_event_got_ip_t *)event_data;
    ESP_LOGI(TAG, "GOT_IP: " IPSTR, IP2STR(&evt->ip_info.ip));
    xSemaphoreGive(s_got_ip);
}

/* --------------------------- app_main：总编排 --------------------------- */

void app_main(void)
{
    ESP_LOGI(TAG, "== ch21 lab: esp-mqtt over lwIP/QEMU ==");

    s_got_ip       = xSemaphoreCreateBinary();
    s_connected    = xSemaphoreCreateBinary();
    s_disconnected = xSemaphoreCreateBinary();
    s_sub_ack      = xSemaphoreCreateBinary();
    s_rtt_seen     = xSemaphoreCreateBinary();

    /* --- ch3 标准 bring-up：openeth + esp_netif + DHCP --- */
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());

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
                                               &eth_event_handler, NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_ETH_GOT_IP,
                                               &ip_event_handler, NULL));

    esp_eth_netif_glue_handle_t glue = esp_eth_new_netif_glue(eth_handle);
    ESP_ERROR_CHECK(esp_netif_attach(eth_netif, glue));
    ESP_ERROR_CHECK(esp_eth_start(eth_handle));

    if (xSemaphoreTake(s_got_ip, pdMS_TO_TICKS(10000)) != pdTRUE) {
        ESP_LOGE(TAG, "DHCP timeout");
        return;
    }

    /* TX 故障注入挂点：拿到 IP、链路安静后换 linkoutput（tcpip_thread 内完成） */
    struct netif *lwip_netif = (struct netif *)esp_netif_get_netif_impl(eth_netif);
    ESP_ERROR_CHECK(tcpip_callback(swap_linkoutput_cb, lwip_netif));

    /* --- MQTT 客户端启动 --- */
    esp_mqtt_client_config_t cfg = build_cfg(MQTT_KEEPALIVE_S, RECONNECT_MS_STEADY);
    s_cli = esp_mqtt_client_init(&cfg);
    assert(s_cli != NULL);
    ESP_ERROR_CHECK(esp_mqtt_client_register_event(s_cli, MQTT_EVENT_ANY,
                                                   mqtt_event_handler, NULL));
    ESP_ERROR_CHECK(esp_mqtt_client_start(s_cli));

    wait_connected("first connect", 15000);

    int mid = esp_mqtt_client_subscribe(s_cli, TOPIC_RTT_RSP, 0);
    if (mid <= 0 || xSemaphoreTake(s_sub_ack, pdMS_TO_TICKS(3000)) != pdTRUE) {
        MARK("WARN: subscribe rtt/rsp 未确认，RTT 实验不可信");
    }
    heap_line("baseline-idle");

    /* ======================= 阶段 A：基线（keepalive=5s）======================= */
    MARK("APP_STAGE_A_BEGIN");
    rtt_stage(0);
    rtt_stage(1);
    burst_stage(0);
    burst_stage(1);
    MARK("APP_STAGE_A_END outbox=%uB",
         (unsigned)esp_mqtt_client_get_outbox_size(s_cli));

    /* ========== 阶段 C：无声掉线 + outbox 积压 + 排空（keepalive=5s 必须）========== */
    MARK("APP_STAGE_C_BEGIN");
    accumulate_offline();
    MARK("APP_STAGE_C_END free_heap=%u",
         (unsigned)heap_caps_get_free_size(MALLOC_CAP_8BIT));

    /* ===== 阶段 B1：纯丢帧对照 —— keepalive 拉到 90s，杜绝断连抖动混入 =====
     * keepalive 在 CONNECT 报文里协商，必须先 set_config 再干净断开重连才生效。 */
    MARK("APP_STAGE_B_BEGIN");
    apply_cfg_live("B-flapless", MQTT_KEEPALIVE_LOSSY, RECONNECT_MS_STEADY);

    MARK("[INJ] ON p=%d%% (flapless)", LOSS_PCT);
    s_inj_enable = true;
    vTaskDelay(pdMS_TO_TICKS(400));
    lossy_send_phase(0);                     /* QoS0 ×200 @25ms */
    vTaskDelay(pdMS_TO_TICKS(3000));         /* 烘焙尾巴：注入保持开 */
    vTaskDelay(pdMS_TO_TICKS(3000));
    lossy_send_phase(1);                     /* QoS1 ×200 @25ms */
    vTaskDelay(pdMS_TO_TICKS(8000));         /* 覆盖 1s 重发窗的多轮重试 */
    s_inj_enable = false;
    MARK("[INJ] OFF(B1) dropped=%u passed=%u", s_inj_dropped, s_inj_passed);
    vTaskDelay(pdMS_TO_TICKS(4000));
    MARK("APP_STAGE_B1_END outbox=%uB disc_total=%u", (unsigned)esp_mqtt_client_get_outbox_size(s_cli), s_disc_total);

    /* ===== 阶段 B2：抖动复现 —— keepalive 回到 5s，弱网下自动断连重连 ===== */
    apply_cfg_live("B-flappy", MQTT_KEEPALIVE_S, RECONNECT_MS_STEADY);
    MARK("[INJ] ON p=%d%% (flappy)", LOSS_PCT);
    s_inj_enable = true;
    vTaskDelay(pdMS_TO_TICKS(400));
    lossy_send_phase(0);
    vTaskDelay(pdMS_TO_TICKS(6000));
    vTaskDelay(pdMS_TO_TICKS(3000));
    lossy_send_phase(1);
    vTaskDelay(pdMS_TO_TICKS(8000));
    s_inj_enable = false;
    MARK("[INJ] OFF(B2) dropped=%u passed=%u", s_inj_dropped, s_inj_passed);
    vTaskDelay(pdMS_TO_TICKS(4000));
    MARK("APP_STAGE_B_END outbox=%uB pubacks=%u disc=%u",
         (unsigned)esp_mqtt_client_get_outbox_size(s_cli), s_puback_total,
         s_disc_total);

    /* ============ 阶段 D：硬杀（FIN 时序 + 固定间隔重连梯）============ */
    MARK("APP_STAGE_D_BEGIN (sanity ping)");
    if (esp_mqtt_client_publish(s_cli, TOPIC_OFFLINE, "sanity", 6, 0, 0) < 0) {
        MARK("WARN: sanity publish 失败，链路可能已断");
    }
    vTaskDelay(pdMS_TO_TICKS(500));

    MARK("APP_PHASE_HARDKILL_ARMED (宿主机 kill -TERM mosquitto,%ds 后重启)",
         HARDKILL_RESTART_S);

    drain_sem(s_disconnected);
    if (xSemaphoreTake(s_disconnected, pdMS_TO_TICKS(12000)) == pdTRUE) {
        MARK("[HARDKILL] DISCONNECTED 已到达（FIN 检测时延看 EV 行时序）");
    } else {
        MARK("[HARDKILL] 12s 内未见 DISCONNECTED（异常）");
    }

    /* ---- broker 已死窗口内离线入队 30 条 QoS1，重启后排空演示 ---- */
    {
        uint32_t flushed = 0;
        for (int i = 0; i < 30; i++) {
            mk_payload_len(i, "offline", LOSSY_PAYLOAD_LEN);
            int rc = esp_mqtt_client_publish(s_cli, TOPIC_OFFLINE, paybuf,
                                             LOSSY_PAYLOAD_LEN, 1, 0);
            if (rc > 0) { flushed++; }     /* 离线时 qos>0 返回 msg_id */
            vTaskDelay(pdMS_TO_TICKS(80));
        }
        uint32_t ack_pre = s_puback_total;
        MARK("APP_OFFLINE_ENQUEUED n=%u outbox=%uB ack_pre=%u",
             flushed, (unsigned)esp_mqtt_client_get_outbox_size(s_cli), ack_pre);

        wait_connected("broker restarted", 30000);
        vTaskDelay(pdMS_TO_TICKS(2500));   /* 给重发/确认留时间 */
        MARK("APP_OFFLINE_DRAINED outbox=%uB puback_delta=%u (期望 n)",
             (unsigned)esp_mqtt_client_get_outbox_size(s_cli),
             s_puback_total - ack_pre);
    }
    vTaskDelay(pdMS_TO_TICKS(500));

    MARK("[FINAL] inj dropped=%u/%u pubacks=%u free_heap=%u",
         s_inj_dropped, s_inj_dropped + s_inj_passed, s_puback_total,
         (unsigned)heap_caps_get_free_size(MALLOC_CAP_8BIT));
    heap_line("final");
    MARK("APP_ALL_DONE");

    vTaskDelay(portMAX_DELAY);   /* 宿主编排脚本看到 DONE 标记后收尾关机 */
}
