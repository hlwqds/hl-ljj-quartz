/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * lwIP 深度解析（七）实验工程：netif 抽象层契约解剖
 *
 * 基于 ch3 openeth 联网模板（esp_netif + esp_eth + DHCP 等待 IP），本章实验：
 *   E1. 运行时解剖 struct netif：在 tcpip_thread 上下文里安全遍历 netif_list，
 *       打印 lo 与 en 两张网卡的字段实况（mtu/flags/hwaddr/ip 三元组/函数指针/
 *       state 背指针/DHCP client_data 槽位/loopback 队列），与源码结构对照。
 *   E2. 双 netif 路由分派：在 tcpip 线程里直接调用 ip4_route() 对四类目的地址
 *      （本网段子网内 / 回环 127.0.0.1 / 子网外走默认路由）做路由探测，再用
 *       esp_ping 分别 ping 10.0.2.2 与 127.0.0.1 做行为交叉验证。
 *   E3. 故障注入：tcpip 层直接 netif_set_link_down(en0)，观察发送失败传播、
 *       路由回退为 NULL；再 netif_set_link_up 观察恢复与 DHCP reboot（非重新
 *       discover）。全程用自注册的 netif ext-callback 记录 LWIP_NSC_* 事件流。
 *
 * 运行环境：ESP-IDF v6.0.2 + qemu-system-xtensa (Espressif fork)，
 *           -nic user,model=open_eth
 */

#include <stdio.h>
#include <string.h>
#include <assert.h>
#include <errno.h>
#include <unistd.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"

#include "esp_log.h"
#include "esp_event.h"
#include "esp_netif.h"
#include "esp_eth.h"
#include "esp_netif_net_stack.h"

#include "lwip/inet.h"
#include <netdb.h>          /* sockaddr_in / sendto：lwIP BSD socket 层 */
#include "lwip/tcpip.h"
#include "lwip/netif.h"
#include "lwip/ip4.h"
#include "lwip/stats.h"

/* IDF v6 中 ping 应用在 lwIP 组件内：components/lwip/include/apps/ping/ping_sock.h */
#include "ping/ping_sock.h"

static const char *TAG = "ch7lab";

#define DHCP_TIMEOUT_MS  10000

static SemaphoreHandle_t s_got_ip;          /* DHCP 完成信号量 */
static esp_ip4_addr_t s_ip, s_nm, s_gw;     /* 由 IP_EVENT 回调填入 */
static struct netif *s_eth_lwip;            /* en 网卡的 lwIP netif 句柄 */

/* ------------------------- 事件处理（ch3 模板原样） ------------------------- */

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

/* ------------------------- netif ext-callback：事件流记录仪 -------------------------
 * LWIP_NSC_* 是 lwIP 暴露给"栈外世界"的多订阅者事件通道；
 * esp_netif 自己也挂在同一条链上，把事件翻译成 IP_EVENT 与内部 DHCP 回调。
 */
NETIF_DECLARE_EXT_CALLBACK(s_ch7_ext_cb)

static void netif_ext_logger(struct netif *netif, netif_nsc_reason_t reason,
                             const netif_ext_callback_args_t *args)
{
    if (netif != NULL) {
        ESP_LOGI(TAG, "[extcb] netif %c%c%d reason=0x%04x", netif->name[0], netif->name[1],
                 netif->num, reason);
    } else {
        ESP_LOGI(TAG, "[extcb] netif NULL reason=0x%04x", reason);
    }
    if (reason & LWIP_NSC_NETIF_ADDED) {
        ESP_LOGI(TAG, "[extcb]   NETIF_ADDED");
    }
    if (reason & LWIP_NSC_LINK_CHANGED) {
        ESP_LOGI(TAG, "[extcb]   LINK_CHANGED state=%d", args ? args->link_changed.state : -1);
    }
    if (reason & LWIP_NSC_STATUS_CHANGED) {
        ESP_LOGI(TAG, "[extcb]   STATUS_CHANGED state=%d", args ? args->status_changed.state : -1);
    }
    if (reason & (LWIP_NSC_IPV4_ADDRESS_CHANGED | LWIP_NSC_IPV4_GATEWAY_CHANGED |
                  LWIP_NSC_IPV4_NETMASK_CHANGED | LWIP_NSC_IPV4_SETTINGS_CHANGED |
                  LWIP_NSC_IPV4_ADDR_VALID)) {
        if (args != NULL && args->ipv4_changed.old_address != NULL &&
            !ip_addr_isany(args->ipv4_changed.old_address)) {
            ESP_LOGI(TAG, "[extcb]   IPv4 settings event, old_addr=%s",
                     ipaddr_ntoa(args->ipv4_changed.old_address));
        } else {
            ESP_LOGI(TAG, "[extcb]   IPv4 settings event (old addr 为空/未变)");
        }
    }
}

static void register_ext_cb(void *arg)
{
    netif_add_ext_callback(&s_ch7_ext_cb, netif_ext_logger);
}

/* ------------------------- E1：运行时解剖 struct netif ------------------------- */

static void dump_one_netif(struct netif *nw)
{
    char flags_str[64];
    char ip_s[16], nm_s[16], gw_s[16];   /* ntoa 系列带静态缓冲，必须逐字段落地 */
    /* 逐位解码 flags（含义见 src/include/lwip/netif.h 的 @ref netif_flags 组） */
    snprintf(flags_str, sizeof(flags_str), "%s%s%s%s%s%s%s",
             (nw->flags & NETIF_FLAG_UP)        ? "UP "     : "",
             (nw->flags & NETIF_FLAG_BROADCAST) ? "BCAST "  : "",
             (nw->flags & NETIF_FLAG_LINK_UP)   ? "LINK_UP ": "",
             (nw->flags & NETIF_FLAG_ETHARP)    ? "ETHARP " : "",
             (nw->flags & NETIF_FLAG_ETHERNET)  ? "ETH "    : "",
             (nw->flags & NETIF_FLAG_IGMP)      ? "IGMP "   : "",
             (nw->flags & NETIF_FLAG_MLD6)      ? "MLD6 "   : "");

    ipaddr_ntoa_r(&nw->ip_addr, ip_s, sizeof(ip_s));
    ipaddr_ntoa_r(&nw->netmask, nm_s, sizeof(nm_s));
    ipaddr_ntoa_r(&nw->gw, gw_s, sizeof(gw_s));

    ESP_LOGI(TAG, "--- netif %c%c%d (index=%d) ---", nw->name[0], nw->name[1],
             nw->num, netif_get_index(nw));
    ESP_LOGI(TAG, "  struct@%p size=%d state(背指针)=%p", nw, (int)sizeof(struct netif), nw->state);
    ESP_LOGI(TAG, "  ip/mask/gw: %s/%s gw %s", ip_s, nm_s, gw_s);
    ESP_LOGI(TAG, "  mtu=%u hwaddr_len=%u hwaddr=%02x:%02x:%02x:%02x:%02x:%02x flags=0x%02x[%s]",
             nw->mtu, nw->hwaddr_len,
             nw->hwaddr[0], nw->hwaddr[1], nw->hwaddr[2],
             nw->hwaddr[3], nw->hwaddr[4], nw->hwaddr[5], nw->flags, flags_str);
    ESP_LOGI(TAG, "  input=%p output=%p linkoutput=%p",
             nw->input, nw->output, nw->linkoutput);
#if LWIP_NETIF_HOSTNAME
    ESP_LOGI(TAG, "  hostname=\"%s\"", nw->hostname ? nw->hostname : "(null)");
#endif
#if LWIP_DHCP
    /* DHCP 状态存在内部保留槽位 client_data[LWIP_NETIF_CLIENT_DATA_INDEX_DHCP] */
    ESP_LOGI(TAG, "  client_data[DHCP]=%p%s", nw->client_data[LWIP_NETIF_CLIENT_DATA_INDEX_DHCP],
             nw->client_data[LWIP_NETIF_CLIENT_DATA_INDEX_DHCP] ? "" : " (无 DHCP 实例)");
#endif
#if ENABLE_LOOPBACK
    ESP_LOGI(TAG, "  loopback 队列 first=%p last=%p", nw->loop_first, nw->loop_last);
#endif
}

static void dump_netifs(void *arg)
{
    int count = 0;
    struct netif *nw;
    ESP_LOGI(TAG, "=== E1: netif_list 解剖（sizeof(struct netif)=%d）===", (int)sizeof(struct netif));
    NETIF_FOREACH(nw) {
        dump_one_netif(nw);
        count++;
    }
    ESP_LOGI(TAG, "=== E1 done: 共 %d 个 netif, 默认网卡(netif_default)=%p ===",
             count, (void *)netif_default);
}

/* ip4_addr_t.addr 的正确构造方式（照抄 IP4_ADDR 宏本体）：
 * addr = PP_HTONL(LWIP_MAKEU32(a,b,c,d))——LWIP_MAKEU32 只拼出 a<<24|b<<16|...，
 * 在小端 CPU 上还要再经 PP_HTONL 换一次字节序才是 .addr 的真身。
 * 手写 0x7F000001 会被打印成 "1.0.0.127" 且路由匹配全盘失灵。 */
#define IP4ADDR_U32(a, b, c, d) PP_HTONL(LWIP_MAKEU32(a, b, c, d))

/* ------------------------- E2：ip4_route 路由分派探测 ------------------------- */

struct route_case {
    uint32_t dst_be;     /* 目的地址：lwip ip4_addr_t.addr 原始值
                            （点分 A.B.C.D 对应 LWIP_MAKEU32(A,B,C,D)，别想当然写 0xAABBCCDD） */
    const char *label;
};

static void route_probe(void *arg)
{
    /* 四类代表性目的地址：
     *  127.0.0.1        —— loopback 网卡自己的地址
     *  10.0.2.2         —— SLIRP 网关，落在 en 的 10.0.2.0/24 前缀内
     *  10.0.2.3         —— SLIRP DNS 代理，同前缀
     *  192.168.199.99   —— 不在任何 netif 前缀内，只能靠默认路由
     */
    static const struct route_case cases[] = {
        { .dst_be = IP4ADDR_U32(127, 0, 0, 1),      .label = "lo-self" },
        { .dst_be = IP4ADDR_U32(10, 0, 2, 2),       .label = "in-subnet" },
        { .dst_be = IP4ADDR_U32(10, 0, 2, 3),       .label = "dns" },
        { .dst_be = IP4ADDR_U32(192, 168, 199, 99), .label = "off-subnet" },
    };

    ESP_LOGI(TAG, "=== E2a: ip4_route() 分派表（ctx=tcpip_thread）===");
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        char dst_s[16], if_s[16];
        ip4_addr_t dest;
        dest.addr = cases[i].dst_be;
        struct netif *out = ip4_route(&dest);
        ip4addr_ntoa_r(&dest, dst_s, sizeof(dst_s));
        if (out == NULL) {
            ESP_LOGI(TAG, "  %-10s %-16s -> NO ROUTE (ip.rterr+1)", cases[i].label, dst_s);
        } else {
            ipaddr_ntoa_r(&out->ip_addr, if_s, sizeof(if_s));
            ESP_LOGI(TAG, "  %-10s %-16s -> netif %c%c%d (ip=%s)",
                     cases[i].label, dst_s, out->name[0], out->name[1], out->num, if_s);
        }
    }
    ESP_LOGI(TAG, "=== E2a done ===");
}

/* ------------------------- ping（复用 ch3 回调形态，精简） ------------------------- */

static void on_ping_success(esp_ping_handle_t hdl, void *args)
{
    uint16_t seqno;
    uint32_t elapsed_us;
    esp_ping_get_profile(hdl, ESP_PING_PROF_SEQNO, &seqno, sizeof(seqno));
    esp_ping_get_profile(hdl, ESP_PING_PROF_TIMEGAP, &elapsed_us, sizeof(elapsed_us));
    ESP_LOGI(TAG, "[ping %s] seq=%u reply time=%lu us",
             (const char *)args, seqno, (unsigned long)elapsed_us);
}

static void on_ping_timeout(esp_ping_handle_t hdl, void *args)
{
    uint16_t seqno;
    esp_ping_get_profile(hdl, ESP_PING_PROF_SEQNO, &seqno, sizeof(seqno));
    ESP_LOGW(TAG, "[ping %s] seq=%u TIMEOUT", (const char *)args, seqno);
}

static void on_ping_end(esp_ping_handle_t hdl, void *args)
{
    uint32_t sent, received;
    esp_ping_get_profile(hdl, ESP_PING_PROF_REQUEST, &sent, sizeof(sent));
    esp_ping_get_profile(hdl, ESP_PING_PROF_REPLY, &received, sizeof(received));
    ESP_LOGI(TAG, "[ping %s] 统计: sent=%lu recv=%lu loss=%lu%%",
             (const char *)args, (unsigned long)sent, (unsigned long)received,
             sent ? 100UL * (sent - received) / sent : 100UL);
}

static void run_ping(uint32_t dst_be, int count, const char *label)
{
    ip_addr_t target;
    IP_SET_TYPE_VAL(target, IPADDR_TYPE_V4);
    ip4_addr_set_u32(ip_2_ip4(&target), dst_be);

    esp_ping_config_t cfg = ESP_PING_DEFAULT_CONFIG();
    cfg.target_addr = target;
    cfg.count       = count;
    cfg.interval_ms = 200;
    cfg.timeout_ms  = 900;

    esp_ping_callbacks_t cbs = {
        .cb_args         = (void *)label,
        .on_ping_success = on_ping_success,
        .on_ping_timeout = on_ping_timeout,
        .on_ping_end     = on_ping_end,
    };
    esp_ping_handle_t hdl = NULL;
    if (esp_ping_new_session(&cfg, &cbs, &hdl) != ESP_OK) {
        ESP_LOGE(TAG, "ping session create failed");
        return;
    }
    esp_ping_start(hdl);
    vTaskDelay(pdMS_TO_TICKS(count * cfg.interval_ms + 5 * cfg.timeout_ms));
    esp_ping_stop(hdl);
    esp_ping_delete_session(hdl);
}

/* ------------------------- 协议栈计数器探针（定位包死在哪一跳） ------------------------- */

static void stats_probe(void *arg)
{
#if LWIP_STATS
    const char *when = (const char *)arg;
    ESP_LOGI(TAG, "[stats %s] icmp.xmit=%u icmp.recv=%u icmp.err=%u | ip.xmit=%u ip.rterr=%u | link.xmit=%u link.recv=%u link.drop=%u",
             when,
             (unsigned)lwip_stats.icmp.xmit, (unsigned)lwip_stats.icmp.recv, (unsigned)lwip_stats.icmp.err,
             (unsigned)lwip_stats.ip.xmit, (unsigned)lwip_stats.ip.rterr,
             (unsigned)lwip_stats.link.xmit, (unsigned)lwip_stats.link.recv, (unsigned)lwip_stats.link.drop);
#else
    (void)arg;
#endif
}

/* ------------------------- E3 辅助：link down/up 注入与 UDP 探针 ------------------------- */

static void inject_link_down(void *arg)
{
    struct netif *nw = (struct netif *)arg;
    ESP_LOGI(TAG, ">>> 注入: netif_set_link_down(%c%c%d)，注入前 flags=0x%02x link_up=%d up=%d",
             nw->name[0], nw->name[1], nw->num, nw->flags,
             netif_is_link_up(nw), netif_is_up(nw));
    netif_set_link_down(nw);
    ESP_LOGI(TAG, "<<< 注入完成: flags=0x%02x link_up=%d up=%d（注意 UP 位仍置位）",
             nw->flags, netif_is_link_up(nw), netif_is_up(nw));
}

static void inject_link_up(void *arg)
{
    struct netif *nw = (struct netif *)arg;
    ESP_LOGI(TAG, ">>> 注入: netif_set_link_up(%c%c%d)", nw->name[0], nw->name[1], nw->num);
    netif_set_link_up(nw);
    ESP_LOGI(TAG, "<<< 注入完成: flags=0x%02x link_up=%d up=%d",
             nw->flags, netif_is_link_up(nw), netif_is_up(nw));
}

static void udp_probe(const char *what)
{
    struct sockaddr_in dst = {
        .sin_family      = AF_INET,
        .sin_port        = htons(9),              /* discard */
        .sin_addr.s_addr = inet_addr("10.0.2.2"),
    };
    int sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (sock < 0) {
        ESP_LOGE(TAG, "[udp-probe %s] socket failed errno=%d", what, errno);
        return;
    }
    int rc = sendto(sock, "ch7", 3, 0, (struct sockaddr *)&dst, sizeof(dst));
    if (rc < 0) {
        ESP_LOGW(TAG, "[udp-probe %s] sendto 失败 rc=%d errno=%d", what, rc, errno);
    } else {
        ESP_LOGI(TAG, "[udp-probe %s] sendto OK (%d bytes)", what, rc);
    }
    close(sock);
}

/* ------------------------- app_main ------------------------- */

void app_main(void)
{
    ESP_LOGI(TAG, "== ch7 lab: netif contract anatomy / routing dispatch / link fault injection ==");

    ESP_ERROR_CHECK(esp_netif_init());                 /* 内部 tcpip_init：lo 网卡在这一步诞生 */
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    s_got_ip = xSemaphoreCreateBinary();

    /* 注册我们的 ext-callback 观察者（必须进 tcpip 线程执行） */
    ESP_ERROR_CHECK(tcpip_callback(register_ext_cb, NULL));

    /* ---- 标准 openeth bring-up（照抄 ch3 模板）---- */
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

    /* 抓住 lwIP netif 句柄，后续所有 tcpip 侧操作都用它当参数 */
    s_eth_lwip = (struct netif *)esp_netif_get_netif_impl(eth_netif);
    ESP_LOGI(TAG, "en lwip netif handle = %p", (void *)s_eth_lwip);

    /* ---- 实验 1：静态解剖 ---- */
    ESP_ERROR_CHECK(tcpip_callback(dump_netifs, NULL));
    vTaskDelay(pdMS_TO_TICKS(300));

    /* ---- 实验 2：路由分派 ---- */
    ESP_LOGI(TAG, "--- experiment B: routing dispatch ---");
    ESP_ERROR_CHECK(tcpip_callback(route_probe, NULL));
    ESP_ERROR_CHECK(tcpip_callback(stats_probe, (void *)"before-pings"));

    ESP_LOGI(TAG, "--- experiment B2: ping 交叉验证（link 正常）---");
    run_ping(IP4ADDR_U32(10, 0, 2, 2), 2, "10.0.2.2");
    ESP_ERROR_CHECK(tcpip_callback(stats_probe, (void *)"after-eth-ping"));
    run_ping(IP4ADDR_U32(127, 0, 0, 1), 2, "127.0.0.1");
    ESP_ERROR_CHECK(tcpip_callback(stats_probe, (void *)"after-lo-ping"));

    /* ---- 实验 3：link down 故障注入 ---- */
    ESP_LOGI(TAG, "--- experiment C: link-down fault injection ---");
    ESP_ERROR_CHECK(tcpip_callback(inject_link_down, s_eth_lwip));
    vTaskDelay(pdMS_TO_TICKS(200));

    udp_probe("link-down");
    ESP_LOGI(TAG, "走 eth 的 ping（预期全超时）：");
    run_ping(IP4ADDR_U32(10, 0, 2, 2), 2, "10.0.2.2-DOWN");
    ESP_ERROR_CHECK(tcpip_callback(stats_probe, (void *)"after-down-pings"));
    ESP_LOGI(TAG, "走 lo 的 ping（预期照常成功——此路不经过物理网卡）：");
    run_ping(IP4ADDR_U32(127, 0, 0, 1), 2, "127.0.0.1-DOWN");

    ESP_LOGI(TAG, "down 态路由复测：");
    ESP_ERROR_CHECK(tcpip_callback(route_probe, NULL));

    /* ---- 恢复 ---- */
    ESP_LOGI(TAG, "--- experiment C2: link-up recovery ---");
    ESP_ERROR_CHECK(tcpip_callback(inject_link_up, s_eth_lwip));
    vTaskDelay(pdMS_TO_TICKS(1200));   /* 给 DHCP reboot 一点时间 */

    udp_probe("recovered");
    ESP_LOGI(TAG, "恢复后 netif 终态：");
    ESP_ERROR_CHECK(tcpip_callback(dump_netifs, NULL));

    ESP_LOGI(TAG, "== all ch7 experiments done ==");
    vTaskDelay(pdMS_TO_TICKS(4000));
}
