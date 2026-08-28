/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * pcapx S3 集成验收 lab：openeth bring-up → esp_console → pcapx 抓包全流程
 *
 * 会话设计（全自动，不依赖串口交互；复现命令见本工程 README.md）：
 *   1. openeth + DHCP（照抄 ch3 模板 practice/lwip-ch03-qemu-network-lab，
 *      SLIRP 下 guest 得 10.0.2.15，网关/DNS 10.0.2.2/10.0.2.3）。
 *   2. esp_console_init → pcapx_console_register（IDF v6 语义：init 之前不能
 *      register，见 components/console/esp_console.h "Call this once before
 *      using other console module features"）。
 *   3. 契约失败路径演示（三种 ATTACH_FAIL reason 里的两种 + SINK_OPEN_FAIL）：
 *      - attach(netif=NULL, sink=NULL)          → E pcapx: ATTACH_FAIL reason=arg
 *      - attach(netif=ok, sink="/tmp/.")        → E pcapx: SINK_OPEN_FAIL（basename
 *        是 "."，fopen 目录在半托管后端必失败——与「QEMU 未加 -semihosting」在
 *        sink 层走同一行修复提示）→ E pcapx: ATTACH_FAIL reason=sink_open
 *      - 已 attach 后再次 attach                → E pcapx: ATTACH_FAIL reason=busy
 *        （注意：busy 分支 core 未接管 sink，本演示故意泄漏一个 sink 对象，
 *         ~4.3KB，验收会话一次性可接受，见函数内注释）
 *   4. 主抓包会话（默认）：semihost sink /tmp/cap.pcap，rx+tx，snaplen=128，
 *      过滤全 0；50 个 UDP 包 × 20ms → 10.0.2.2:9999（闭合端口；目的 MAC 是
 *      网关 → 首包触发 ARP 请求/应答，闭合端口回 ICMP port-unreachable，
 *      天然覆盖 ARP+IP+UDP+ICMP）+ 一次 getaddrinfo("baidu.com")（DNS 查询/
 *      响应，覆盖 DNS 回包）；排空 500ms → pcapx_stats（console 命令）→ detach
 *      → 再打一次 stats（契约：未 attach 时全 0）。
 *
 * 编译期实验开关（main/Kconfig.projbuild，经 sdkconfig.defaults 控制，默认关）：
 *   - DROP ：ring=2048 / snaplen=64 / N=500 / 无间隔 → 期望 W pcapx: DROP cnt=N
 *            契约行 + 丢包恒等式 rx+tx == filtered+dropped+written（排空后）。
 *   - CHURN：UDP 流量进行中 attach/detach ×100 → 无 crash + heap 前后对账。
 */

#include <errno.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <netdb.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"

#include "esp_console.h"
#include "esp_err.h"
#include "esp_event.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_netif_net_stack.h" /* esp_netif_get_netif_impl（返回 lwip netif*） */
#include "esp_eth.h"
#include "esp_timer.h"

#include "lwip/inet.h"
#include "lwip/netif.h" /* netif_is_up / struct netif */

#include "pcapx.h"

/* pcapx_console.c 导出的注册函数：S2 的设计决定是不经冻结头文件 pcapx.h 暴露
 * console 专用入口（见 practice/pcapx/src/pcapx_console.c 头注释），lab 侧自行声明 */
extern esp_err_t pcapx_console_register(void);

static const char *TAG = "pcapxlab";

#define UDP_DST_IP       "10.0.2.2" /* SLIRP 网关（也是 hostfwd 之外的主机侧入口） */
#define UDP_DST_PORT     9999       /* 闭合端口：SLIRP 无服务 → ICMP type3 回弹素材 */
#define UDP_PAYLOAD_LEN  48
#define N_UDP_DEFAULT    50
#define UDP_GAP_MS       20
#define DNS_PROBE_NAME   "baidu.com"
#define DHCP_TIMEOUT_MS  15000
#define PCAP_HOST_PATH   "/tmp/cap.pcap" /* VFS /tmp 挂载 → 宿主落在 QEMU cwd 下 */

static SemaphoreHandle_t s_got_ip;       /* DHCP 完成信号量 */
static esp_ip4_addr_t s_ip, s_nm, s_gw;  /* IP_EVENT 回调填入 */
static esp_netif_t *s_eth_netif;
static volatile bool s_traffic_stop;     /* churn 实验的流量发生器停机标志 */

/* ------------------------- 事件处理（ch3 模板） ------------------------- */

static void eth_event_handler(void *arg, esp_event_base_t base,
                              int32_t event_id, void *event_data)
{
    (void)arg;
    (void)base;
    (void)event_data;
    switch (event_id) {
    case ETHERNET_EVENT_START:        ESP_LOGI(TAG, "ETH_EVENT: START"); break;
    case ETHERNET_EVENT_STOP:         ESP_LOGI(TAG, "ETH_EVENT: STOP"); break;
    case ETHERNET_EVENT_CONNECTED:    ESP_LOGI(TAG, "ETH_EVENT: CONNECTED (link up)"); break;
    case ETHERNET_EVENT_DISCONNECTED: ESP_LOGI(TAG, "ETH_EVENT: DISCONNECTED"); break;
    default:                          ESP_LOGI(TAG, "ETH_EVENT: id=%ld", (long)event_id); break;
    }
}

static void ip_event_handler(void *arg, esp_event_base_t base,
                             int32_t event_id, void *event_data)
{
    (void)arg;
    (void)base;
    ip_event_got_ip_t *evt = (ip_event_got_ip_t *)event_data;
    s_ip = evt->ip_info.ip;
    s_nm = evt->ip_info.netmask;
    s_gw = evt->ip_info.gw;
    ESP_LOGI(TAG, "GOT_IP: " IPSTR "/" IPSTR " gw " IPSTR,
             IP2STR(&s_ip), IP2STR(&s_nm), IP2STR(&s_gw));
    xSemaphoreGive(s_got_ip);
}

/* ------------------------- 小工具 ------------------------- */

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

/* stats 打印：console 命令（S2 交付物，证明 esp_console 路径可用）+ 带阶段标签的
 * ESP_LOG 版（grep 对账用；两条取自同一把锁下的快照，帧数可能相差在飞帧） */
static void print_stats(const char *phase)
{
    int cmd_ret = 0;
    esp_err_t err = esp_console_run("pcapx_stats", &cmd_ret);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "console run pcapx_stats failed: %s", esp_err_to_name(err));
    }

    pcapx_stats_t st;
    pcapx_get_stats(&st);
    ESP_LOGI(TAG, "STATS phase=%s rx=%u tx=%u filtered=%u dropped=%u truncated=%u "
                  "written=%u ring_high_wm=%u",
             phase, (unsigned)st.rx, (unsigned)st.tx, (unsigned)st.filtered,
             (unsigned)st.dropped, (unsigned)st.truncated, (unsigned)st.written,
             (unsigned)st.ring_high_wm);
}

/* ------------------------- UDP 打流 ------------------------- */

/* 向闭合端口发 n 个 UDP 包；返回 sendto 成功数。gap_ms=0 表示背靠背（DROP 实验） */
static int udp_burst(int n, int gap_ms)
{
    struct sockaddr_in dst = {
        .sin_family = AF_INET,
        .sin_port = htons(UDP_DST_PORT),
        .sin_addr.s_addr = inet_addr(UDP_DST_IP),
    };
    uint8_t buf[UDP_PAYLOAD_LEN];
    memset(buf, 0xA5, sizeof(buf));

    int s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s < 0) {
        ESP_LOGE(TAG, "udp socket failed errno=%d", errno);
        return -1;
    }
    int sent = 0;
    for (int i = 0; i < n; i++) {
        if (sendto(s, buf, sizeof(buf), 0,
                   (const struct sockaddr *)&dst, sizeof(dst)) >= 0) {
            sent++;
        }
        if (gap_ms) {
            vTaskDelay(pdMS_TO_TICKS(gap_ms));
        }
    }
    close(s);
    return sent;
}

/* ------------------------- 契约失败路径演示 ------------------------- */

static void demo_fail_paths(struct netif *lwip_netif)
{
    ESP_LOGI(TAG, "PHASE fail-demos: begin");

    /* 1) netif=NULL + sink=NULL → reason=arg（零资源、零泄漏） */
    {
        pcapx_config_t cfg = {
            .netif = NULL,
            .direction = PCAPX_DIR_RX | PCAPX_DIR_TX,
            .snaplen = 128,
            .filter = { 0 },
            .ring_bytes = 0,
            .sink = NULL,
        };
        esp_err_t err = pcapx_attach(&cfg);
        ESP_LOGI(TAG, "demo arg: attach(netif=NULL,sink=NULL) -> %s (expect INVALID_ARG)",
                 esp_err_to_name(err));
    }

    /* 2) basename="." 的 semihost 路径：fopen 目录必失败 → SINK_OPEN_FAIL 契约行
     *    + ATTACH_FAIL reason=sink_open。该失败路径 core 会 close+free sink，无泄漏 */
    {
        pcapx_sink_t *sink = pcapx_sink_semihost_new("/tmp/.");
        assert(sink != NULL);
        pcapx_config_t cfg = {
            .netif = lwip_netif,
            .direction = PCAPX_DIR_RX | PCAPX_DIR_TX,
            .snaplen = 128,
            .filter = { 0 },
            .ring_bytes = 0,
            .sink = sink,
        };
        esp_err_t err = pcapx_attach(&cfg);
        ESP_LOGI(TAG, "demo sink_open: attach(sink=/tmp/.) -> %s (expect INVALID_ARG "
                      "after SINK_OPEN_FAIL)", esp_err_to_name(err));
    }

    ESP_LOGI(TAG, "PHASE fail-demos: done");
}

/* ------------------------- 主抓包会话（默认构建） ------------------------- */

static void session_default(struct netif *lwip_netif)
{
    ESP_LOGI(TAG, "PHASE session-default: begin");

    pcapx_sink_t *sink = pcapx_sink_semihost_new(PCAP_HOST_PATH);
    assert(sink != NULL);
    pcapx_config_t cfg = {
        .netif = lwip_netif,
        .direction = PCAPX_DIR_RX | PCAPX_DIR_TX,
        .snaplen = 128,
        .filter = { 0 }, /* 全 0 = 通配（ARP/IP/ICMP/UDP/DNS 全收） */
        .ring_bytes = 0, /* 0 → CONFIG_PCAPX_RING_BYTES（默认 8192） */
        .sink = sink,
    };

    ESP_LOGI(TAG, "STEP attach (host file: QEMU cwd/cap.pcap via -semihosting)");
    ESP_ERROR_CHECK(pcapx_attach(&cfg)); /* → I pcapx: ATTACH netif=.. */

    /* busy：已 attach 时再次 attach。busy 分支 core 未接管第二个 sink 对象，
     * 构造器所有权契约（include/pcapx.h："返回对象所有权移交 pcapx"）只在
     * attach 成功/失败接管路径成立——此处故意遗留一个 ~4.3KB 的 sink 对象
     * 换取契约行证据，验收会话一次性，可接受（heap 影响只计入本会话）。 */
    {
        pcapx_sink_t *sink2 = pcapx_sink_semihost_new("/tmp/cap-dup.pcap");
        assert(sink2 != NULL);
        pcapx_config_t cfg2 = cfg;
        cfg2.sink = sink2;
        esp_err_t err = pcapx_attach(&cfg2);
        ESP_LOGI(TAG, "demo busy: attach#2 while attached -> %s "
                      "(sink2 object intentionally orphaned, ~4.3KB)",
                 esp_err_to_name(err));
    }

    ESP_LOGI(TAG, "STEP udp burst n=%d gap=%dms dst=%s:%d (closed port; first frame "
                  "triggers ARP to gateway)", N_UDP_DEFAULT, UDP_GAP_MS, UDP_DST_IP,
             UDP_DST_PORT);
    int sent = udp_burst(N_UDP_DEFAULT, UDP_GAP_MS);
    ESP_LOGI(TAG, "STEP udp sent=%d/%d", sent, N_UDP_DEFAULT);

    ESP_LOGI(TAG, "STEP dns probe %s (covers DNS query/response over UDP/53)",
             DNS_PROBE_NAME);
    dns_probe(DNS_PROBE_NAME);

    ESP_LOGI(TAG, "STEP drain 500ms");
    vTaskDelay(pdMS_TO_TICKS(500));

    print_stats("default-before-detach");
    ESP_LOGI(TAG, "STEP detach");
    ESP_ERROR_CHECK(pcapx_detach()); /* → I pcapx: DETACH netif=.. rx=.. tx=.. */

    print_stats("default-after-detach"); /* 契约：未 attach 时全 0 */

    ESP_LOGI(TAG, "PHASE session-default: done");
}

/* ------------------------- DROP 实验（编译期开关） ------------------------- */

#ifdef CONFIG_LAB_PCAPX_EXP_DROP
/* 慢 sink：DROP 实验专用（lab 私有 vtable 实现，用满 pcapx 可插拔轴）。
 * write 每帧睡 2ms 模拟慢速落盘介质，把 writer 出环速率压到 ~500 帧/s：
 * 500 背靠背帧以 tcpip_thread 优先级入环，2048B 环（~26 帧）迅速塞满，
 * 触发「环满丢新」契约路径。数据丢弃仅计数——DROP 实验对账的是 stats
 * 恒等式与 DROP 日志行，pcap 产物由默认会话的 semihost sink 提供。 */
typedef struct {
    pcapx_sink_t base;
    uint32_t writes;
    uint32_t bytes;
} slow_sink_t;

static esp_err_t slow_open(pcapx_sink_t *s)
{
    ((slow_sink_t *)s)->writes = 0;
    ((slow_sink_t *)s)->bytes = 0;
    ESP_LOGI(TAG, "SINK_OPEN sink=slow (2ms/frame)");
    return ESP_OK;
}

static esp_err_t slow_write(pcapx_sink_t *s, const void *buf, size_t len)
{
    (void)buf;
    slow_sink_t *me = (slow_sink_t *)s;
    me->writes++;
    me->bytes += (uint32_t)len;
    /* busy-wait 而非 vTaskDelay：writer(17) 睡眠会让出 CPU 且实验实测
     * （QEMU 下 tick 语义偏软）背压不稳定；自旋 2ms 稳定占用 writer 时间片，
     * tcpip(18) 仍可抢占继续入环——出环速率被钉死在 ~500 帧/s */
    int64_t until = esp_timer_get_time() + 2000;
    while (esp_timer_get_time() < until) {
        /* 空转：cpu_relax 等价 */
        __asm__ __volatile__("nop");
    }
    return ESP_OK;
}

static esp_err_t slow_close(pcapx_sink_t *s)
{
    slow_sink_t *me = (slow_sink_t *)s;
    ESP_LOGI(TAG, "SINK_CLOSE sink=slow writes=%u bytes=%u",
             (unsigned)me->writes, (unsigned)me->bytes);
    return ESP_OK;
}

static void slow_free(pcapx_sink_t *s)
{
    free(s);
}

static pcapx_sink_t *slow_sink_new(void)
{
    slow_sink_t *me = calloc(1, sizeof(*me));
    if (me == NULL) {
        return NULL;
    }
    me->base.name = "slow:2ms";
    me->base.open = slow_open;
    me->base.write = slow_write;
    me->base.close = slow_close;
    me->base.free_fn = slow_free;
    return &me->base;
}

#define DROP_RING_BYTES 2048
#define DROP_SNAPLEN    64
#define DROP_N          500

static void session_drop(struct netif *lwip_netif)
{
    ESP_LOGI(TAG, "PHASE session-drop: ring=%d snaplen=%d n=%d gap=0 (back-to-back)",
             DROP_RING_BYTES, DROP_SNAPLEN, DROP_N);

    pcapx_sink_t *sink = slow_sink_new();
    assert(sink != NULL);
    pcapx_config_t cfg = {
        .netif = lwip_netif,
        .direction = PCAPX_DIR_RX | PCAPX_DIR_TX,
        .snaplen = DROP_SNAPLEN,
        .filter = { 0 },
        .ring_bytes = DROP_RING_BYTES,
        .sink = sink,
    };
    ESP_ERROR_CHECK(pcapx_attach(&cfg));

    int sent = udp_burst(DROP_N, 0); /* 无间隔：塞满 2048B 环 → 丢新计数 */
    ESP_LOGI(TAG, "STEP udp sent=%d/%d (no pacing)", sent, DROP_N);

    ESP_LOGI(TAG, "STEP drain 1000ms (writer 排空 + 等待 ICMP 回弹尾巴)");
    vTaskDelay(pdMS_TO_TICKS(1000));

    print_stats("drop-before-detach");

    /* 恒等式核对（detach 前、环已排空时成立）：tap 收到的每一帧，要么被硬过滤
     * 排除（filtered）、要么环满丢弃（dropped）、要么已写入 sink（written）。
     * detach 后 core 会清零统计，所以快照必须取在 detach 之前。 */
    {
        pcapx_stats_t st;
        pcapx_get_stats(&st);
        uint32_t lhs = st.rx + st.tx;
        uint32_t rhs = st.filtered + st.dropped + st.written;
        ESP_LOGI(TAG, "IDENTITY rx+tx=%u filtered=%u dropped=%u written=%u -> %s",
                 (unsigned)lhs, (unsigned)st.filtered, (unsigned)st.dropped,
                 (unsigned)st.written, lhs == rhs ? "OK" : "MISMATCH");
    }

    ESP_ERROR_CHECK(pcapx_detach());
    ESP_LOGI(TAG, "PHASE session-drop: done");
}
#endif /* CONFIG_LAB_PCAPX_EXP_DROP */

/* ------------------------- CHURN 实验（编译期开关） ------------------------- */

#ifdef CONFIG_LAB_PCAPX_EXP_CHURN
#define CHURN_ROUNDS      100
#define CHURN_TRAFFIC_MS  8   /* 流量发生器发包间隔 */

static void traffic_gen_task(void *arg)
{
    (void)arg;
    struct sockaddr_in dst = {
        .sin_family = AF_INET,
        .sin_port = htons(UDP_DST_PORT),
        .sin_addr.s_addr = inet_addr(UDP_DST_IP),
    };
    uint8_t buf[UDP_PAYLOAD_LEN];
    memset(buf, 0xC3, sizeof(buf));

    int s = socket(AF_INET, SOCK_DGRAM, 0);
    assert(s >= 0);
    uint32_t sent = 0;
    while (!s_traffic_stop) {
        if (sendto(s, buf, sizeof(buf), 0,
                   (const struct sockaddr *)&dst, sizeof(dst)) >= 0) {
            sent++;
        }
        vTaskDelay(pdMS_TO_TICKS(CHURN_TRAFFIC_MS));
    }
    close(s);
    ESP_LOGI(TAG, "traffic gen stopped, total sent=%u", (unsigned)sent);
    vTaskDelete(NULL);
}

static void session_churn(struct netif *lwip_netif)
{
    uint32_t heap_before = heap_caps_get_free_size(MALLOC_CAP_INTERNAL);
    ESP_LOGI(TAG, "PHASE session-churn: %d attach/detach rounds under UDP traffic "
                  "(%dms pacing), heap_before=%u",
             CHURN_ROUNDS, CHURN_TRAFFIC_MS, (unsigned)heap_before);

    s_traffic_stop = false;
    TaskHandle_t gen = NULL;
    assert(xTaskCreate(traffic_gen_task, "udp_gen", 4096, NULL, 4, &gen) == pdPASS);
    vTaskDelay(pdMS_TO_TICKS(200)); /* 流量先起，再开始 churn */

    int ok_rounds = 0;
    for (int i = 0; i < CHURN_ROUNDS; i++) {
        pcapx_sink_t *sink = pcapx_sink_semihost_new(PCAP_HOST_PATH);
        assert(sink != NULL);
        pcapx_config_t cfg = {
            .netif = lwip_netif,
            .direction = PCAPX_DIR_RX | PCAPX_DIR_TX,
            .snaplen = 128,
            .filter = { 0 },
            .ring_bytes = 0,
            .sink = sink,
        };
        esp_err_t err = pcapx_attach(&cfg);
        if (err != ESP_OK) {
            ESP_LOGE(TAG, "churn attach#%d failed: %s", i, esp_err_to_name(err));
            break;
        }
        vTaskDelay(pdMS_TO_TICKS(5 + i % 3)); /* 变化停留时长：1~2 帧/轮 */
        err = pcapx_detach();
        if (err != ESP_OK) {
            ESP_LOGE(TAG, "churn detach#%d failed: %s", i, esp_err_to_name(err));
            break;
        }
        ok_rounds++;
        if ((i + 1) % 25 == 0) {
            ESP_LOGI(TAG, "churn progress %d/%d heap=%u", i + 1, CHURN_ROUNDS,
                     (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL));
        }
    }

    s_traffic_stop = true;
    vTaskDelay(pdMS_TO_TICKS(100)); /* 等 gen 任务收尾 + idle 收尸最后一轮 writer TCB */
    uint32_t heap_after = heap_caps_get_free_size(MALLOC_CAP_INTERNAL);
    ESP_LOGI(TAG, "CHURN RESULT rounds_ok=%d/%d heap_before=%u heap_after=%u delta=%d",
             ok_rounds, CHURN_ROUNDS, (unsigned)heap_before, (unsigned)heap_after,
             (int)((int64_t)heap_before - (int64_t)heap_after));
    ESP_LOGI(TAG, "PHASE session-churn: done");
}
#endif /* CONFIG_LAB_PCAPX_EXP_CHURN */

/* ------------------------- app_main ------------------------- */

void app_main(void)
{
    ESP_LOGI(TAG, "== pcapx S3 lab start (built " __DATE__ " " __TIME__ ") ==");

    /* 1. 协议栈与事件循环（socket 创建必须在 esp_netif_init 之后，公约 Batch1） */
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    s_got_ip = xSemaphoreCreateBinary();

    /* 2. openeth bring-up（ch3 模板原样） */
    esp_netif_config_t netif_cfg = ESP_NETIF_DEFAULT_ETH();
    s_eth_netif = esp_netif_new(&netif_cfg);
    assert(s_eth_netif != NULL);

    eth_mac_config_t mac_cfg = ETH_MAC_DEFAULT_CONFIG();
    mac_cfg.rx_task_stack_size = 8192; /* pcapx wrap 在 RX 任务内加深调用链
                                          （tap_capture + pbuf_copy_partial），
                                          4096 默认值在异常入口二次异常（实测） */
    eth_phy_config_t phy_cfg = ETH_PHY_DEFAULT_CONFIG();
    phy_cfg.reset_gpio_num = -1;        /* 虚拟 PHY 无复位引脚 */
    phy_cfg.autonego_timeout_ms = 3000; /* QEMU 下自协商立即完成，缩短超时 */

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
    ESP_ERROR_CHECK(esp_netif_attach(s_eth_netif, glue));
    ESP_ERROR_CHECK(esp_eth_start(eth_handle));
    ESP_LOGI(TAG, "waiting for DHCP lease ...");

    if (xSemaphoreTake(s_got_ip, pdMS_TO_TICKS(DHCP_TIMEOUT_MS)) != pdTRUE) {
        ESP_LOGE(TAG, "DHCP timeout after %d ms -- check QEMU -nic and events",
                 DHCP_TIMEOUT_MS);
        return;
    }

    esp_netif_dns_info_t dns_info;
    if (esp_netif_get_dns_info(s_eth_netif, ESP_NETIF_DNS_MAIN, &dns_info) == ESP_OK) {
        ESP_LOGI(TAG, "DNS server from DHCP: " IPSTR, IP2STR(&dns_info.ip.u_addr.ip4));
    }

    /* 3. 拿 lwIP netif（pcapx attach 的目标），核对 up 状态 */
    struct netif *lwip_netif = (struct netif *)esp_netif_get_netif_impl(s_eth_netif);
    assert(lwip_netif != NULL);
    ESP_LOGI(TAG, "lwip netif name=%c%c up=%d", lwip_netif->name[0],
             lwip_netif->name[1], netif_is_up(lwip_netif));

    /* 4. esp_console：v6 语义 init → register（顺序反了 register 会失败） */
    esp_console_config_t console_cfg = ESP_CONSOLE_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_console_init(&console_cfg));
    ESP_ERROR_CHECK(pcapx_console_register());
    ESP_LOGI(TAG, "console ready (pcapx_stats / pcapx_ram_dump registered)");

    /* 5. 契约失败路径（arg / sink_open；busy 在 attach 成功后演示） */
    demo_fail_paths(lwip_netif);

    /* 6. 实验主体：默认会话 / DROP / CHURN 按编译期开关选择（可叠加） */
#ifdef CONFIG_LAB_PCAPX_EXP_DROP
    session_drop(lwip_netif);
#else
    session_default(lwip_netif);
#endif
#ifdef CONFIG_LAB_PCAPX_EXP_CHURN
    session_churn(lwip_netif);
#endif

    ESP_LOGI(TAG, "== LAB DONE ==");
    /* app_main 返回后固件空转；QEMU 由宿主 timeout 击杀。semihost sink 每次
     * write 后即 fflush（pcapx_sink_semihost.c 设计决定），cap.pcap 完整可解析。 */
}
