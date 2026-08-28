/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * ex01 ethernet-dhcp —— 以太网起播基线（openeth bring-up 最小骨架）
 *
 * practice/lwip-examples 套件的第一课：只做一件事——把 QEMU 的 openeth 虚拟
 * 网卡带到 DHCP 拿到 IP，全程事件可见，随后观测链路计数。无业务连接、无
 * hostfwd 端口，复制改名即可作为新项目的起点。
 *
 * bring-up 序列遵循套件标准 15 步骨架（research/assets-and-constraints.md §1.3），
 * 唯一钦定差异点：esp_netif_init() 必须是第一句网络相关调用。
 *
 * 运行环境：ESP-IDF v6.0.2 + qemu-system-xtensa (Espressif fork)，
 *           -nic user,model=open_eth（SLIRP 用户态网络，DHCP 得 10.0.2.15/24）
 */

#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"

#include "esp_log.h"
#include "esp_event.h"
#include "esp_netif.h"
#include "esp_timer.h"
#include "esp_eth.h"
#include "esp_eth_mac_openeth.h" /* esp_eth_mac_new_openeth() 的显式声明头 */

#include "lwip/tcpip.h" /* tcpip_callback() */
#include "lwip/stats.h" /* lwip_stats.link（需 CONFIG_LWIP_STATS=y） */

static const char *TAG = "ex01";

#define DHCP_TIMEOUT_MS 15000 /* SLIRP 的 DHCP 秒级应答，15s 已是宽裕上限 */
#define STATS_PERIOD_MS 5000  /* 链路计数采样周期 */
#define STATS_WINDOW_MS 30000 /* 总观测窗，共 STATS_WINDOW/PERIOD 个采样点 */

/*
 * 一行 lwip_stats.link 快照。所有读取经 tcpip_callback() 投递到 tcpip_thread
 * 执行——套件纪律：跨线程观察协议栈状态不裸读、不裸调，统一走 tcpip_callback。
 * （仅观测计数的话直接读也常见，这里示范的是将来扩展成 raw API 观察时的正确姿势。）
 */
typedef struct {
    u32_t recv;
    u32_t xmit;
    u32_t drop;
    u32_t chkerr;
    u32_t lenerr;
    u32_t memerr;
} link_snap_t;

static SemaphoreHandle_t s_got_ip;     /* DHCP 完成信号量 */
static esp_netif_ip_info_t s_ip_info;  /* 由 IP_EVENT 回调填入 */
static bool s_got_ip_valid = false;

static inline int64_t now_ms(void)
{
    /* 时间戳用 esp_timer_get_time()；sys_now() 是 10ms tick 网格，精度不够 */
    return esp_timer_get_time() / 1000LL;
}

/* ------------------------- 事件处理 ------------------------- */

static void eth_event_handler(void *arg, esp_event_base_t base,
                              int32_t event_id, void *event_data)
{
    /* IDF v6 事件枚举是 ETHERNET_EVENT_*（不是 v5 的 ESP_ETH_EVENT_*） */
    switch (event_id) {
    case ETHERNET_EVENT_START:
        ESP_LOGI(TAG, "[t=%lld ms] ETH_EVENT START", now_ms());
        break;
    case ETHERNET_EVENT_CONNECTED:
        ESP_LOGI(TAG, "[t=%lld ms] ETH_EVENT CONNECTED (link up)", now_ms());
        break;
    case ETHERNET_EVENT_DISCONNECTED:
        ESP_LOGW(TAG, "[t=%lld ms] ETH_EVENT DISCONNECTED (link down)", now_ms());
        break;
    case ETHERNET_EVENT_STOP:
        ESP_LOGW(TAG, "[t=%lld ms] ETH_EVENT STOP", now_ms());
        break;
    default:
        ESP_LOGI(TAG, "[t=%lld ms] ETH_EVENT id=%ld", now_ms(), (long)event_id);
        break;
    }
}

static void ip_event_handler(void *arg, esp_event_base_t base,
                             int32_t event_id, void *event_data)
{
    ip_event_got_ip_t *evt = (ip_event_got_ip_t *)event_data;
    s_ip_info = evt->ip_info;
    s_got_ip_valid = true;
    ESP_LOGI(TAG, "[t=%lld ms] IP_EVENT GOT_IP: ip " IPSTR " nm " IPSTR " gw " IPSTR,
             now_ms(), IP2STR(&s_ip_info.ip), IP2STR(&s_ip_info.netmask),
             IP2STR(&s_ip_info.gw));
    xSemaphoreGive(s_got_ip);
}

/* ------------------------- 链路统计快照 ------------------------- */

#if LWIP_STATS && LINK_STATS

/* 在 tcpip_thread 内执行：把 lwip_stats.link 拷进调用方给的缓冲 */
static void link_snap_cb(void *ctx)
{
    link_snap_t *snap = (link_snap_t *)ctx;
    snap->recv   = lwip_stats.link.recv;
    snap->xmit   = lwip_stats.link.xmit;
    snap->drop   = lwip_stats.link.drop;
    snap->chkerr = lwip_stats.link.chkerr;
    snap->lenerr = lwip_stats.link.lenerr;
    snap->memerr = lwip_stats.link.memerr;
}

static void link_snapshot(link_snap_t *out)
{
    memset(out, 0, sizeof(*out));
    if (tcpip_callback(link_snap_cb, out) != ERR_OK) {
        ESP_LOGW(TAG, "tcpip_callback failed, snapshot zeroed");
    }
}

#else /* !LWIP_STATS || !LINK_STATS */

static void link_snapshot(link_snap_t *out)
{
    memset(out, 0, sizeof(*out)); /* 关闭 CONFIG_LWIP_STATS 时恒为空，见 README */
}

#endif

static void print_stats_line(int tick, int ticks_total,
                             const link_snap_t *prev, const link_snap_t *cur)
{
    unsigned long d_recv = cur->recv > prev->recv ? cur->recv - prev->recv : 0;
    unsigned long d_xmit = cur->xmit > prev->xmit ? cur->xmit - prev->xmit : 0;
    unsigned long d_drop = cur->drop > prev->drop ? cur->drop - prev->drop : 0;
    /* err 聚合三个「协议栈侧」错误计数：校验和 / 长度 / 内存不足 */
    unsigned long e_prev = prev->chkerr + prev->lenerr + prev->memerr;
    unsigned long e_cur  = cur->chkerr + cur->lenerr + cur->memerr;
    unsigned long d_err  = e_cur > e_prev ? e_cur - e_prev : 0;

    ESP_LOGI(TAG,
             "EX01-ST tick=%d/%d up_s=%lld ip=" IPSTR " "
             "rx=%lu(+%lu) tx=%lu(+%lu) drop=+%lu err=+%lu",
             tick, ticks_total, (long long)(now_ms() / 1000), IP2STR(&s_ip_info.ip),
             (unsigned long)cur->recv, d_recv, (unsigned long)cur->xmit, d_xmit,
             d_drop, d_err);
}

/* ------------------------- app_main：标准 bring-up 序列 ------------------------- */

void app_main(void)
{
    ESP_LOGI(TAG, "== ex01 ethernet-dhcp: openeth bring-up baseline ==");
    /* 固件指纹：核对 QEMU 加载的不是旧镜像（Batch 7 实践） */
    ESP_LOGI(TAG, "EX01-FACT build=\"" __DATE__ " " __TIME__ "\" lwip_stats=%d",
             (int)LWIP_STATS);

    /* [1] 初始化 TCP/IP 协议栈适配层与默认事件循环：
     * esp_netif_init() 创建 tcpip 邮箱，必须是第一句网络相关调用；
     * 之后才能创建 socket/netconn 或投递 tcpip_callback。 */
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    s_got_ip = xSemaphoreCreateBinary();

    /* [2] 创建以太网默认配置的 esp_netif 实例 */
    esp_netif_config_t netif_cfg = ESP_NETIF_DEFAULT_ETH();
    esp_netif_t *eth_netif = esp_netif_new(&netif_cfg);

    /* [3] 组装 MAC 与 PHY 对象（openeth 仅可用于 QEMU） */
    eth_mac_config_t mac_cfg = ETH_MAC_DEFAULT_CONFIG(); /* rx 任务 4096B prio15 */
    eth_phy_config_t phy_cfg = ETH_PHY_DEFAULT_CONFIG(); /* phy_addr AUTO */
    phy_cfg.reset_gpio_num      = -1;  /* 虚拟 PHY 无复位引脚 */
    phy_cfg.autonego_timeout_ms = 3000;

    esp_eth_mac_t *mac = esp_eth_mac_new_openeth(&mac_cfg);
    assert(mac != NULL);
    esp_eth_phy_t *phy = esp_eth_phy_new_generic(&phy_cfg); /* v6 registry 机制通用 PHY */
    assert(phy != NULL);

    esp_eth_config_t eth_cfg = ETH_DEFAULT_CONFIG(mac, phy); /* check_link_period 2000ms */
    esp_eth_handle_t eth_handle = NULL;
    ESP_ERROR_CHECK(esp_eth_driver_install(&eth_cfg, &eth_handle));

    uint8_t mac_addr[6] = {0};
    ESP_ERROR_CHECK(esp_eth_ioctl(eth_handle, ETH_CMD_G_MAC_ADDR, mac_addr));

    /* [4] 注册事件处理器：链路事件全量 + 拿到 IP 事件 */
    ESP_ERROR_CHECK(esp_event_handler_register(ETH_EVENT, ESP_EVENT_ANY_ID,
                                               &eth_event_handler, NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_ETH_GOT_IP,
                                               &ip_event_handler, NULL));

    /* [5] glue 层挂接驱动：netif up 时 glue 会替我们启动 DHCP 客户端 */
    esp_eth_netif_glue_handle_t glue = esp_eth_new_netif_glue(eth_handle);
    ESP_ERROR_CHECK(esp_netif_attach(eth_netif, glue));

    /* [6] 启动驱动：PHY 自协商 → 链路 up → netif up → DHCP → GOT_IP */
    ESP_ERROR_CHECK(esp_eth_start(eth_handle));
    ESP_LOGI(TAG, "waiting for DHCP lease ...");

    if (xSemaphoreTake(s_got_ip, pdMS_TO_TICKS(DHCP_TIMEOUT_MS)) != pdTRUE) {
        ESP_LOGE(TAG, "$$$ EXFAIL reason=dhcp_timeout after %d ms", DHCP_TIMEOUT_MS);
        return; /* -no-reboot 下进程退出；用 tools/run_qemu.sh 时靠 timeout 兜底 */
    }

    /* [7] 顺带打印 DHCP 下发的 DNS（lwIP 全局存储，非 per-netif） */
    char dns_str[16] = "n/a";
    esp_netif_dns_info_t dns_info;
    if (esp_netif_get_dns_info(eth_netif, ESP_NETIF_DNS_MAIN, &dns_info) == ESP_OK) {
        snprintf(dns_str, sizeof(dns_str), IPSTR, IP2STR(&dns_info.ip.u_addr.ip4));
    }

    /* [8] 机器可读 READY 行：验收器 grep 这一行即可断言起播成功 */
    ESP_LOGI(TAG,
             "$$$ EXREADY ip=" IPSTR " nm=" IPSTR " gw=" IPSTR " dns=%s "
             "mac=%02x:%02x:%02x:%02x:%02x:%02x t_ms=%lld",
             IP2STR(&s_ip_info.ip), IP2STR(&s_ip_info.netmask), IP2STR(&s_ip_info.gw),
             dns_str, mac_addr[0], mac_addr[1], mac_addr[2], mac_addr[3],
             mac_addr[4], mac_addr[5], now_ms());

    /* [9] 30 秒观测窗：每 5s 打印一次 IP 信息 + lwip_stats.link 计数增量。
     * 静默链路上增量恒为 +0 属正常观测（本示例不造流量），README 有解释。 */
    const int ticks = STATS_WINDOW_MS / STATS_PERIOD_MS;
    link_snap_t prev, cur;
    link_snapshot(&prev);
    for (int n = 1; n <= ticks; n++) {
        vTaskDelay(pdMS_TO_TICKS(STATS_PERIOD_MS));
        if (!s_got_ip_valid) {
            break;
        }
        link_snapshot(&cur);
        print_stats_line(n, ticks, &prev, &cur);
        prev = cur;
    }
    ESP_LOGI(TAG, "$$$ EXDONE stats_window_ms=%d t_ms=%lld",
             STATS_WINDOW_MS, now_ms());

    /* [10] 应用阶段结束，保持进程存活（由外部 timeout 决定退出时机） */
    while (1) {
        vTaskDelay(pdMS_TO_TICKS(60000));
    }
}
