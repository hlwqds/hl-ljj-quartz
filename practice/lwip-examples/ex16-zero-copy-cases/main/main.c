/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * ex16 zero-copy-cases —— 零拷贝优化案例集
 *
 * 一个固件内五个可切换案例（CONFIG_ZC_CASE），SPEC §5-ex16 规格实现：
 *   0 说明模式：五案例目录 + 引用行打印 + 8330 入向行命令口（hostfwd 可 nc）
 *   1 案例 A RX 就地解析   —— 见 zc_casea.c 头注释
 *   2 案例 B TX 分段提交   —— 见 zc_caseb.c
 *   3 案例 C 层级拷贝差    —— 见 zc_casec.c
 *   4 案例 D 流式校验      —— 见 zc_cased.c
 *   5 案例 E 诚实边界      —— 见 zc_casee.c
 *
 * 骨架纪律（SPEC §3）：esp_netif_init 第一句网络调用；openeth MAC +
 * generic PHY(reset_gpio_num=-1)；GOT_IP 15s 超时；READY 行后进应用；
 * 控制面任务 pin core1 prio22 压过 tcpip(18)。
 */
#include <assert.h>
#include <string.h>

#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"

#include "esp_eth.h"
#include "esp_eth_mac_openeth.h"
#include "esp_event.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_timer.h"

#include "lwip/stats.h"

#include "zc_priv.h"

static const char *TAG = "ex16";

#define DHCP_TIMEOUT_MS 15000

static SemaphoreHandle_t s_got_ip;
static int64_t s_ready_ms;

static inline int64_t now_ms(void) { return esp_timer_get_time() / 1000LL; }

static void door_reply(const char *msg, zc_sink_t *k);
static void catalog_print(void);

/* ============================ 案例 0：行命令口与目录 ============================ */

static void case0_on_line(zc_sink_t *k, const char *line)
{
    if (strcasecmp(line, "HELP") == 0 || strcasecmp(line, "?") == 0) {
        const char *msg =
            "ex16 case0 command door. Commands: HELP CASES STATS HEAP UPTIME\r\n";
        struct tcp_pcb *pcb = k->conn;
        if (pcb != NULL && tcp_sndbuf(pcb) >= strlen(msg)) {
            tcp_write(pcb, msg, (u16_t)strlen(msg), TCP_WRITE_FLAG_COPY);
            tcp_output(pcb);
        }
        printf("EX16-DOOR cmd=HELP\n");
        return;
    }
    if (strcasecmp(line, "CASES") == 0) {
        ex16_case5_cite_lines();
        catalog_print();
        return;
    }
    if (strcasecmp(line, "STATS") == 0) {
#if LWIP_STATS
        printf("EX16-ST link.recv=%u ip.recv=%u tcp.recv=%u tcp.xmit=%u\n",
               (unsigned)lwip_stats.link.recv, (unsigned)lwip_stats.ip.recv,
               (unsigned)lwip_stats.tcp.recv, (unsigned)lwip_stats.tcp.xmit);
#else
        printf("EX16-ST disabled reason=LWIP_STATS=n\n");
#endif
        door_reply("stats printed to serial console\r\n", k);
        return;
    }
    if (strcasecmp(line, "HEAP") == 0) {
        zc_heap_line("door-command");
        door_reply("heap printed to serial console\r\n", k);
        return;
    }
    if (strcasecmp(line, "UPTIME") == 0) {
        char buf[96];
        snprintf(buf, sizeof(buf), "uptime_ms=%lld ready_rel_ms=%lld\r\n",
                 (long long)(esp_timer_get_time() / 1000),
                 (long long)(now_ms() - s_ready_ms));
        door_reply(buf, k);
        return;
    }
    char buf[128];
    snprintf(buf, sizeof(buf), "ERR unknown cmd: %.60s\r\n", line);
    door_reply(buf, k);
    printf("EX16-DOOR cmd=unknown line='%.40s'\n", line);
}

static void door_reply(const char *msg, zc_sink_t *k)
{
    struct tcp_pcb *pcb = k->conn;
    size_t n = strlen(msg);
    if (pcb != NULL && tcp_sndbuf(pcb) >= n) {
        tcp_write(pcb, msg, (u16_t)n, TCP_WRITE_FLAG_COPY);
        tcp_output(pcb);
    }
}

static void catalog_line(int n, const char *name, const char *gist)
{
    printf("$$$ EX16-CATALOG case=%d name=\"%s\" gist=\"%s\"\n", n, name, gist);
}

static void catalog_print(void)
{
    catalog_line(1, "rx-inplace-parse",
                 "tcp_recv 回调就地解析 pbuf payload vs memcpy 后解析；带 contiguous/span 检查与栈峰值探针");
    catalog_line(2, "tx-segmented-submit",
                 "头/体分离 write+MORE vs 用户侧拼接整体 write；量化省掉的用户侧 memcpy 一跳（栈内 COPY 仍在）");
    catalog_line(3, "layer-tax-per-copy",
                 "同一回声负载过 raw/netconn/socket 三层，127.0.0.1 RTT 定位分层拷贝税（承接 ch10/ch15）");
    catalog_line(4, "stream-checksum-zero-landing",
                 "边收边算 Fletcher32 vs 落地整包再算；内存驻留差与校验摊销");
    catalog_line(5, "honest-boundary",
                 "IDF LWIP_NETIF_TX_SINGLE_PBUF=1 硬编码使 TCP_WRITE_FLAG_COPY 不可达；apiflags+行为学证据");
}

/* ============================ bring-up（套件骨架 §3） ============================ */

static void eth_event_handler(void *arg, esp_event_base_t base, int32_t id,
                              void *data)
{
    (void)arg;
    (void)base;
    (void)data;
    switch (id) {
    case ETHERNET_EVENT_CONNECTED:
        ESP_LOGI(TAG, "[t=%lld ms] ETH_EVENT CONNECTED", (long long)now_ms());
        break;
    case ETHERNET_EVENT_DISCONNECTED:
        ESP_LOGW(TAG, "[t=%lld ms] ETH_EVENT DISCONNECTED", (long long)now_ms());
        break;
    default:
        break;
    }
}

static void ip_event_handler(void *arg, esp_event_base_t base, int32_t id,
                             void *data)
{
    (void)arg;
    (void)base;
    (void)id;
    ip_event_got_ip_t *evt = (ip_event_got_ip_t *)data;
    ESP_LOGI(TAG, "[t=%lld ms] IP_EVENT GOT_IP: ip " IPSTR " gw " IPSTR,
             (long long)now_ms(), IP2STR(&evt->ip_info.ip),
             IP2STR(&evt->ip_info.gw));
    xSemaphoreGive(s_got_ip);
}

/* ---------------- 编排任务 ---------------- */

static void ex16_orchestrator(void *arg)
{
    (void)arg;
    static const char *case_names[] = {
        "catalog",         "rx-inplace-parse",  "tx-segmented-submit",
        "layer-tax",       "stream-checksum",   "honest-boundary",
    };

    bool ok = false;
    switch (g_case) {
    case 0: {
        catalog_print();
        ex16_case5_cite_lines(); /* 每次开机都可核对引用事实 */
        g_svc_main.k.line_mode = true;
        g_svc_main.on_line = case0_on_line;
        ok = zc_svc_listen(&g_svc_main, PORT_SINK);
        if (ok) {
            printf(
                "\n案例 0 已在 %d 端口开入向命令门（hostfwd tcp::8330-:8330）。"
                "\n宿主机试：nc localhost 8330 然后输入 HELP / CASES / STATS。\n"
                "基准构建请用 sdkconfig.defaults.case{1..5}（见 README）。\n\n",
                PORT_SINK);
        }
        /* 周期性心跳，方便确认活着 */
        for (int i = 0; i < 6; i++) {
            vTaskDelay(pdMS_TO_TICKS(5000));
            zc_heap_line("case0-heartbeat");
        }
        ok = true;
        break;
    }
    case 1:
        ok = ex16_caseA_run();
        break;
    case 2:
        ok = ex16_caseB_run();
        break;
    case 3:
        ok = ex16_caseC_run();
        break;
    case 4:
        ok = ex16_caseD_run();
        break;
    case 5:
        ok = ex16_caseE_run();
        break;
    default:
        zc_fail("bad_case_number");
        ok = false;
        break;
    }

    const char *name = (g_case <= 5) ? case_names[g_case] : "bad";
    printf("$$$ EXDONE case=%d(%s) result=%s dur_ms=%lld fail=%d\n", g_case,
           name, ok ? "ok" : "fail", (long long)(now_ms() - s_ready_ms),
           (int)g_fail);
    fflush(stdout);
    vTaskDelete(NULL);
}

/* ---------------- app_main ---------------- */

void app_main(void)
{
    esp_log_level_set("*", ESP_LOG_INFO);
    printf("\n=== ex16 zero-copy-cases | build %s %s ===\n", __DATE__, __TIME__);

    printf(
        "$$$ EX16-FACT build=\"%s %s\" case=%d idf_lwip_port='TX_SINGLE_PBUF "
        "hardcoded=1' target='%s' reflector=%d rounds_per_stage=%d block=%d "
        "rec_body=%d b_hdr=%d b_body=%d c_msg=%d c_msgs=%d c_passes=%d "
        "d_arena=%d trace_facility=%d lwip_stats=%d\n",
        __DATE__, __TIME__, CONFIG_ZC_CASE,
        CONFIG_IDF_TARGET,
        EX16_REFLECTOR, (int)CONFIG_ZC_ROUNDS_PER_STAGE,
        (int)CONFIG_ZC_BLOCK, (int)CONFIG_ZC_REC_BODY, (int)CONFIG_ZC_B_HDR,
        (int)CONFIG_ZC_B_BODY, (int)CONFIG_ZC_C_MSG, (int)CONFIG_ZC_C_MSGS,
        (int)CONFIG_ZC_C_PASSES, (int)CONFIG_ZC_D_ARENA_BYTES,
        (int)CONFIG_FREERTOS_USE_TRACE_FACILITY, (int)LWIP_STATS);

    /* [1] esp_netif_init 必须是第一句网络相关调用 */
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    s_got_ip = xSemaphoreCreateBinary();

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
    ESP_LOGI(TAG, "waiting for DHCP lease ...");

    if (xSemaphoreTake(s_got_ip, pdMS_TO_TICKS(DHCP_TIMEOUT_MS)) != pdTRUE) {
        printf("$$$ EXFAIL reason=dhcp_timeout after=%d ms\n", DHCP_TIMEOUT_MS);
        return;
    }
    esp_netif_ip_info_t info;
    ESP_ERROR_CHECK(esp_netif_get_ip_info(eth_netif, &info));

    zc_load_target_init();
    s_ready_ms = now_ms();
    printf("$$$ EXREADY case=%d ip=" IPSTR " gw=" IPSTR " dst=%s:%u "
           "self_target_forbidden=10.0.2.15 note='Batch8: own-IP as dst wedges "
           "tcpip'\n",
           CONFIG_ZC_CASE, IP2STR(&info.ip), IP2STR(&info.gw),
           ipaddr_ntoa(&g_load_dst), (unsigned)g_load_port);

    /* [2] 编排任务：pin core1、prio22 —— 测量与控制活在受害者带宽之外 */
    xTaskCreatePinnedToCore(ex16_orchestrator, "ex16_run", 6144, NULL, 22, NULL, 1);

    while (1) {
        vTaskDelay(pdMS_TO_TICKS(60000));
    }
}
