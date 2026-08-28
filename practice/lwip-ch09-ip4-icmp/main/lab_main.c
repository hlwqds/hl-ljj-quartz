/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * lwIP 深度解析（九）实验工程：IP 路由决策 / 分片重组 / ICMP 往返
 *
 * 基于 ch3 验证过的 openeth bring-up 模板，做四组实验：
 *   A. 大包分片往返：data_size=4000 的 ping，观察 ip4_frag 出向切分与
 *      SLIRP 回程分片在 ip4_reass() 重组；
 *   B. TTL 行为对照：ping 10.0.2.2（SLIRP 网关代答）vs 10.0.2.3（DNS 代理）
 *      vs 公网地址（经 SLIRP NAT 多跳转发），比较 reply TTL；
 *   C. 故障注入·重组缓冲耗尽：data_size=15000 的单发大包触发回程分片洪峰与驱动丢片，
 *      观察"永久不完整数据报"的停摆（IP_REASS_MAXAGE=3s 回收 + ICMP Time Exceeded）、
 *      耗尽窗口内小包不受影响、三路并发大包顶高 ip_reass_pbufcount、以及自愈验证；
 *   D. 故障注入·不可达：ping 10.0.2.250（网内不存在），看 ARP 解析失败后的静默丢弃。
 *
 * 运行环境：ESP-IDF v6.0.2 + qemu-system-xtensa (Espressif fork)，
 *           -nic user,model=open_eth[,hostfwd=tcp::8009-:8888]
 */

#include <stdio.h>
#include <string.h>
#include <assert.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"

#include "esp_log.h"
#include "esp_event.h"
#include "esp_netif.h"
#include "esp_eth.h"

#include "lwip/inet.h"
#include "lwip/stats.h"   /* lwip_stats.ip_frag / .icmp / .mib2 */

/* IDF v6 中 ping 应用在 lwIP 组件内：components/lwip/include/apps/ping/ping_sock.h */
#include "ping/ping_sock.h"

static const char *TAG = "ch9lab";

#define DHCP_TIMEOUT_MS  10000

static SemaphoreHandle_t s_got_ip;      /* DHCP 完成信号量 */
static esp_ip4_addr_t s_ip, s_nm, s_gw; /* 由 IP_EVENT 回调填入 */

/* ------------------------- 统计快照 ------------------------- */

struct ip_stats_snap {
    u32_t ip_recv, ip_xmit, ip_drop, ip_chkerr, ip_lenerr;
    u32_t frag_recv, frag_xmit, frag_drop, frag_memerr, frag_cachehit;
    u32_t icmp_recv, icmp_xmit, icmp_lenerr, icmp_err;
    u32_t arp_xmit, arp_drop;
    u32_t mib_reasmreqds, mib_reasmoks, mib_reasmfails;
};

static void snap_take(struct ip_stats_snap *s)
{
    memset(s, 0, sizeof(*s));
    s->ip_recv     = lwip_stats.ip.recv;
    s->ip_xmit     = lwip_stats.ip.xmit;
    s->ip_drop     = lwip_stats.ip.drop;
    s->ip_chkerr   = lwip_stats.ip.chkerr;
    s->ip_lenerr   = lwip_stats.ip.lenerr;
    s->frag_recv   = lwip_stats.ip_frag.recv;
    s->frag_xmit   = lwip_stats.ip_frag.xmit;
    s->frag_drop   = lwip_stats.ip_frag.drop;
    s->frag_memerr = lwip_stats.ip_frag.memerr;
    s->frag_cachehit = lwip_stats.ip_frag.cachehit;
    s->icmp_recv   = lwip_stats.icmp.recv;
    s->icmp_xmit   = lwip_stats.icmp.xmit;
    s->icmp_lenerr = lwip_stats.icmp.lenerr;
    s->icmp_err    = lwip_stats.icmp.err;
    s->arp_xmit    = lwip_stats.etharp.xmit;   /* ARP request 发出数 */
    s->arp_drop    = lwip_stats.etharp.drop;
    s->mib_reasmreqds = lwip_stats.mib2.ipreasmreqds;
    s->mib_reasmoks   = lwip_stats.mib2.ipreasmoks;
    s->mib_reasmfails = lwip_stats.mib2.ipreasmfails;
}

static void snap_diff(const char *label, const struct ip_stats_snap *a)
{
    ESP_LOGI(TAG, "[%s] dSTAT ip(recv=%u xmit=%u drop=%u chkerr=%u lenerr=%u)",
             label,
             (unsigned)(lwip_stats.ip.recv - a->ip_recv),
             (unsigned)(lwip_stats.ip.xmit - a->ip_xmit),
             (unsigned)(lwip_stats.ip.drop - a->ip_drop),
             (unsigned)(lwip_stats.ip.chkerr - a->ip_chkerr),
             (unsigned)(lwip_stats.ip.lenerr - a->ip_lenerr));
    ESP_LOGI(TAG, "[%s] dSTAT ip_frag(frag_out=%u reass_in=%u cachehit=%u DROP=%u MEMERR=%u)",
             label,
             (unsigned)(lwip_stats.ip_frag.xmit - a->frag_xmit),
             (unsigned)(lwip_stats.ip_frag.recv - a->frag_recv),
             (unsigned)(lwip_stats.ip_frag.cachehit - a->frag_cachehit),
             (unsigned)(lwip_stats.ip_frag.drop - a->frag_drop),
             (unsigned)(lwip_stats.ip_frag.memerr - a->frag_memerr));
    ESP_LOGI(TAG, "[%s] dSTAT icmp(rx=%u tx=%u lenerr=%u err=%u)",
             label,
             (unsigned)(lwip_stats.icmp.recv - a->icmp_recv),
             (unsigned)(lwip_stats.icmp.xmit - a->icmp_xmit),
             (unsigned)(lwip_stats.icmp.lenerr - a->icmp_lenerr),
             (unsigned)(lwip_stats.icmp.err - a->icmp_err));
    ESP_LOGI(TAG, "[%s] dSTAT etharp(req=%u drop=%u) mib2(reasmreqds=%u reasmOK=%u reasmFAIL=%u)",
             label,
             (unsigned)(lwip_stats.etharp.xmit - a->arp_xmit),
             (unsigned)(lwip_stats.etharp.drop - a->arp_drop),
             (unsigned)(lwip_stats.mib2.ipreasmreqds - a->mib_reasmreqds),
             (unsigned)(lwip_stats.mib2.ipreasmoks - a->mib_reasmoks),
             (unsigned)(lwip_stats.mib2.ipreasmfails - a->mib_reasmfails));
}

/* ------------------------- 事件处理 ------------------------- */

static void eth_event_handler(void *arg, esp_event_base_t base,
                              int32_t event_id, void *event_data)
{
    switch (event_id) {
    case ETHERNET_EVENT_CONNECTED:
        ESP_LOGI(TAG, "ETH_EVENT: CONNECTED (link up)");
        break;
    case ETHERNET_EVENT_DISCONNECTED:
        ESP_LOGI(TAG, "ETH_EVENT: DISCONNECTED (link down)");
        break;
    default:
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

/* ------------------------- ping 会话封装 ------------------------- */

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
    ESP_LOGW(TAG, "From %s icmp_seq=%u TIMEOUT", ipaddr_ntoa(&from), seqno);
}

static void on_ping_end(esp_ping_handle_t hdl, void *args)
{
    uint32_t sent, received, total_time_ms;

    esp_ping_get_profile(hdl, ESP_PING_PROF_REQUEST, &sent, sizeof(sent));
    esp_ping_get_profile(hdl, ESP_PING_PROF_REPLY, &received, sizeof(received));
    esp_ping_get_profile(hdl, ESP_PING_PROF_DURATION, &total_time_ms, sizeof(total_time_ms));

    ESP_LOGI(TAG, "--- %s ping statistics: %lu transmitted, %lu received ---",
             (const char *)args, (unsigned long)sent, (unsigned long)received);
}

/* 对 target 发起一个 count 次的 esp_ping 会话并等它结束 */
static void run_ping(const char *target_str, const char *label,
                     uint32_t count, uint32_t interval_ms,
                     uint32_t timeout_ms, uint32_t data_size)
{
    ip_addr_t target;
    memset(&target, 0, sizeof(target));
    IP_SET_TYPE_VAL(target, IPADDR_TYPE_V4);
    ip4_addr_set_u32(ip_2_ip4(&target), ipaddr_addr(target_str));

    esp_ping_config_t cfg = ESP_PING_DEFAULT_CONFIG();
    cfg.target_addr = target;
    cfg.count       = count;
    cfg.interval_ms = interval_ms;
    cfg.timeout_ms  = timeout_ms;
    cfg.data_size   = data_size;

    esp_ping_callbacks_t cbs = {
        .cb_args         = (void *)label,
        .on_ping_success = on_ping_success,
        .on_ping_timeout = on_ping_timeout,
        .on_ping_end     = on_ping_end,
    };
    esp_ping_handle_t hdl = NULL;
    ESP_ERROR_CHECK(esp_ping_new_session(&cfg, &cbs, &hdl));
    ESP_LOGI(TAG, "== ping %s data=%lu count=%lu timeout=%lums ==",
             target_str, (unsigned long)data_size, (unsigned long)count,
             (unsigned long)timeout_ms);
    esp_ping_start(hdl);
    /* 会话结束的确定性窗口：count * 单发周期 + 最后一次等待超时 + 余量 */
    vTaskDelay(pdMS_TO_TICKS(count * (interval_ms > timeout_ms ? interval_ms : timeout_ms)
                             + timeout_ms + 800));
    esp_ping_stop(hdl);
    esp_ping_delete_session(hdl);
}

/* 并行发起 n 个一次性大包会话（各自独立任务），制造分片交织 */
static void run_ping_parallel_concurrent(const char *const targets[], int n,
                                         const char *label_base,
                                         uint32_t timeout_ms, uint32_t data_size)
{
    char label[24];
    esp_ping_handle_t hdl[n];
    for (int i = 0; i < n; i++) {
        ip_addr_t target;
        memset(&target, 0, sizeof(target));
        IP_SET_TYPE_VAL(target, IPADDR_TYPE_V4);
        ip4_addr_set_u32(ip_2_ip4(&target), ipaddr_addr(targets[i]));

        snprintf(label, sizeof(label), "%s#%d", label_base, i);
        static char tagstore[3][24];   /* 回调闭包用的静态存储 */
        strlcpy(tagstore[i], label, sizeof(tagstore[i]));

        esp_ping_config_t cfg = ESP_PING_DEFAULT_CONFIG();
        IP_SET_TYPE_VAL(cfg.target_addr, IPADDR_TYPE_V4);
        ip4_addr_set_u32(ip_2_ip4(&cfg.target_addr), ipaddr_addr(targets[i]));
        cfg.count       = 1;
        cfg.interval_ms = 200;
        cfg.timeout_ms  = timeout_ms;
        cfg.data_size   = data_size;

        esp_ping_callbacks_t cbs = {
            .cb_args         = tagstore[i],
            .on_ping_success = on_ping_success,
            .on_ping_timeout = on_ping_timeout,
            .on_ping_end     = on_ping_end,
        };
        ESP_ERROR_CHECK(esp_ping_new_session(&cfg, &cbs, &hdl[i]));
    }
    ESP_LOGI(TAG, "== %d parallel big pings (%lu bytes each) ==",
             n, (unsigned long)data_size);
    for (int i = 0; i < n; i++) {
        esp_ping_start(hdl[i]);
    }
    vTaskDelay(pdMS_TO_TICKS(timeout_ms + 800));
    for (int i = 0; i < n; i++) {
        esp_ping_stop(hdl[i]);
        esp_ping_delete_session(hdl[i]);
    }
}

/* ------------------------- app_main：bring-up 与四组实验 ------------------------- */

void app_main(void)
{
    ESP_LOGI(TAG, "== ch9 lab: ip4 routing / frag&reass / icmp round trip ==");

    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    s_got_ip = xSemaphoreCreateBinary();

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
                                               &eth_event_handler, NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_ETH_GOT_IP,
                                               &ip_event_handler, NULL));

    esp_eth_netif_glue_handle_t glue = esp_eth_new_netif_glue(eth_handle);
    ESP_ERROR_CHECK(esp_netif_attach(eth_netif, glue));

    ESP_ERROR_CHECK(esp_eth_start(eth_handle));
    ESP_LOGI(TAG, "waiting for DHCP lease ...");

    if (xSemaphoreTake(s_got_ip, pdMS_TO_TICKS(DHCP_TIMEOUT_MS)) != pdTRUE) {
        ESP_LOGE(TAG, "DHCP timeout after %d ms", DHCP_TIMEOUT_MS);
        return;
    }

    struct ip_stats_snap snap;

    /* ---------- 实验 B-0：基线小包 ping 网关（ttl=255 现象再现） ---------- */
    snap_take(&snap);
    run_ping("10.0.2.2", "B-small-gw", 2, 200, 1000, 64);
    snap_diff("B-small-gw", &snap);

    /* ---------- 实验 A：大包（4000B payload）分片往返 ---------- */
    snap_take(&snap);
    run_ping("10.0.2.2", "A-big4000", 3, 300, 1500, 4000);
    snap_diff("A-big4000", &snap);

    /* ---------- 实验 B：TTL 三连对照 ---------- */
    snap_take(&snap);
    run_ping("10.0.2.3", "B-ttl-dnsproxy", 2, 200, 1000, 64);
    snap_diff("B-ttl-dnsproxy", &snap);

    snap_take(&snap);
    run_ping("223.5.5.5", "B-ttl-public", 2, 300, 2000, 64);
    snap_diff("B-ttl-public", &snap);

    /* ---------- 实验 C：重组缓冲耗尽（15000B → 回程 11 片 > MAX_PBUFS=10） ---------- */
    snap_take(&snap);
    run_ping("10.0.2.2", "C-flood15000-1", 1, 200, 3000, 15000);
    snap_diff("C-flood15000-1", &snap);

    /* 同窗口内小包不受影响（不进重组路径）：证明故障面收窄 */
    run_ping("10.0.2.2", "C-during-exhaustion-small", 1, 200, 1000, 64);

    /* IDF 的 IP_REASS_MAXAGE=3（vanilla 是 15，见 port/include/lwipopts.h），
     * 滞留分片 3 个计时滴答后被回收——这里等它走完这趟回收 */
    ESP_LOGI(TAG, "sleep 6s waiting for ip_reass MAXAGE(=3s in IDF) expiry ...");
    vTaskDelay(pdMS_TO_TICKS(6000));

    /* 缓冲耗尽加强版：三路并发大包，各 ~9 片出向、回程分片交织，
     * 把 ip_reass_pbufcount 顶过 IP_REASS_MAX_PBUFS=10，触发逐出路径 */
    snap_take(&snap);
    {
        const char *tg[3] = { "10.0.2.2", "10.0.2.2", "10.0.2.3" };
        run_ping_parallel_concurrent(tg, 3, "C-tri-flood12000", 4000, 12000);
    }
    snap_diff("C-tri-flood12000", &snap);

    /* 自愈验证：再来一发同样的大包 */
    snap_take(&snap);
    run_ping("10.0.2.2", "C-flood15000-2-recovered", 1, 200, 3000, 15000);
    snap_diff("C-flood15000-2-recovered", &snap);

    /* ---------- 实验 D：网内不可达（ARP 解析失败路径） ---------- */
    snap_take(&snap);
    run_ping("10.0.2.250", "D-unreachable", 2, 200, 1000, 64);
    snap_diff("D-unreachable", &snap);

    ESP_LOGI(TAG, "== all experiments done, cumulative stats ==");
    ESP_LOGI(TAG, "FINAL ip(recv=%u xmit=%u fw=%u rterr=%u) ip_frag(xmit=%u recv=%u drop=%u memerr=%u)",
             (unsigned)lwip_stats.ip.recv, (unsigned)lwip_stats.ip.xmit,
             (unsigned)lwip_stats.ip.fw, (unsigned)lwip_stats.ip.rterr,
             (unsigned)lwip_stats.ip_frag.xmit, (unsigned)lwip_stats.ip_frag.recv,
             (unsigned)lwip_stats.ip_frag.drop, (unsigned)lwip_stats.ip_frag.memerr);
    ESP_LOGI(TAG, "FINAL mib2 ipreasmreqds=%u ipreasmoks=%u ipreasmfails=%u",
             (unsigned)lwip_stats.mib2.ipreasmreqds, (unsigned)lwip_stats.mib2.ipreasmoks,
             (unsigned)lwip_stats.mib2.ipreasmfails);

    vTaskDelay(pdMS_TO_TICKS(3000)); /* 收尾余量 */
}
