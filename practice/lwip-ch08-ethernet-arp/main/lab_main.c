/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * lwIP 深度解析（八）实验工程：以太网与 ARP：从帧到 IP 的第一跳
 *
 * 基于 ch3 联网模板（openeth bring-up + DHCP），本章实验：
 *   [A] 首包延迟：对 10.0.2.2 连续多次 TCP connect，
 *       第一次（冷，含 ARP 解析）与后续（热，缓存命中）对比。
 *   [B] ARP 表观测：tcpip_callback 进入 tcpip 线程后用
 *       etharp_get_entry() 遍历 stable 表项；PENDING 对公共 API 不可见，
 *       其生命周期靠 debug 变体的 ETHARP_DEBUG 日志观察。
 *   [C] 故障注入：build 时 -DARP_TABLE_SIZE=2 压缩表容量，
 *       用多个不可达目标 IP 制造驱逐/排队/失败，再测"网关被逐出后
 *       首包延迟回升"，量化缓存失效代价。
 *   [D] ETHARP_DEBUG 日志抓帧（debug 变体自动出现，代码无需变化）。
 *
 * 运行环境：ESP-IDF v6.0.2 + qemu-system-xtensa (Espressif fork)，
 *           -nic user,model=open_eth（本章流量方向为 guest→host，无需 hostfwd；
 *           宿主机侧先起 tools/host_listener.py 监听 127.0.0.1:8108）
 */

#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"

#include "esp_log.h"
#include "esp_event.h"
#include "esp_netif.h"
#include "esp_eth.h"
#include "esp_timer.h"

#include "lwip/inet.h"
#include "lwip/tcpip.h"
#include "lwip/netif.h"
#include "lwip/etharp.h"
#include "lwip/stats.h"

#include <sys/socket.h>
#include <sys/select.h>
#include <unistd.h>

static const char *TAG = "ch8lab";

#define GW_IP      "10.0.2.2"   /* SLIRP 网关 = 宿主机别名 */
#define HOST_PORT  8108         /* 宿主机监听端口 */
#define N_CONN     12           /* 实验 A 连接次数 */
#define DHCP_TIMEOUT_MS 10000

/* 编译期注入的表容量（root CMakeLists -D），打印出来确认注入成功 */
#ifndef ARP_TABLE_SIZE
#define ARP_TABLE_SIZE 10
#endif

static SemaphoreHandle_t s_got_ip;
static esp_ip4_addr_t s_ip, s_nm, s_gw;

/* ------------------------- 标准联网 bring-up（同 ch3 模板） ------------------------- */

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
        break; /* START/STOP 与本章无关，静音以保证日志可读 */
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

/* ------------------------- ARP 表观测（必须在 tcpip 线程内执行） -------------------------
 * arp_table[] 是 etharp.c 的 static 数组，公共入口只有两个：
 *   etharp_find_addr() / etharp_get_entry() —— 都只回报 state >= STABLE 的表项。
 * 又因为它们直接裸读共享数据，从 app 任务调用是数据竞争；用 tcpip_callback()
 * 把观测函数投递进 tcpip_thread 执行（系列暗线 A：单线程邮箱模型的又一例证）。
 */
static void arp_dump_cb(void *ctx)
{
    ip4_addr_t *ipa;
    struct netif *nif;
    struct eth_addr *ea;
    int found = 0;

    printf("[ARPTAB] stable entries (ARP_TABLE_SIZE=%d):\n", (int)ARP_TABLE_SIZE);
    for (size_t i = 0; i < ARP_TABLE_SIZE; i++) {
        if (etharp_get_entry(i, &ipa, &nif, &ea)) {
            found++;
            printf("[ARPTAB]   slot %2u: %s @ %02x:%02x:%02x:%02x:%02x:%02x netif=%c%c%d\n",
                   (unsigned)i, ip4addr_ntoa(ipa),
                   ea->addr[0], ea->addr[1], ea->addr[2],
                   ea->addr[3], ea->addr[4], ea->addr[5],
                   nif->name[0], nif->name[1], (int)netif_get_index(nif));
        }
    }
    if (!found) {
        printf("[ARPTAB]   (no stable entry)\n");
    }
}

static void arp_dump(const char *when)
{
    printf("[ARPTAB] --- dump @%s ---\n", when);
    tcpip_callback(arp_dump_cb, NULL);
}

/* ------------------------- 实验 A/C 核心：非阻塞 connect 计时 ------------------------- */

/* 单次非阻塞 connect（带超时上限），返回耗时 us；失败时 errout 带 errno */
static int64_t timed_connect_us(const char *ip, uint16_t port, int *ok, int *errout)
{
    int64_t t0 = esp_timer_get_time();
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { *ok = 0; *errout = errno; return -1; }

    /* 非阻塞：connect 只负责发 SYN，结果由 select + SO_ERROR 收割，
     * 同时保证宿主机侧没有监听时 guest 不至于把整个实验拖死在重传上 */
    int fl = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, fl | O_NONBLOCK);

    struct sockaddr_in dst = {
        .sin_family = AF_INET,
        .sin_port   = htons(port),
    };
    inet_pton(AF_INET, ip, &dst.sin_addr);

    *ok = 0; *errout = 0;
    int rc = connect(fd, (struct sockaddr *)&dst, sizeof(dst));
    if (rc == 0) {
        *ok = 1;                                   /* 极小概率同步完成 */
    } else if (errno == EINPROGRESS) {
        struct timeval tv = { .tv_sec = 1, .tv_usec = 500000 };  /* 上限 1.5s */
        fd_set wf;
        FD_ZERO(&wf);
        FD_SET(fd, &wf);
        if (select(fd + 1, NULL, &wf, NULL, &tv) > 0) {
            socklen_t elen = sizeof(*errout);
            getsockopt(fd, SOL_SOCKET, SO_ERROR, errout, &elen);
            *ok = (*errout == 0);
        } else {
            *errout = ETIMEDOUT;                   /* select 超时（含 SYN 重传期内） */
        }
    } else {
        *errout = errno;
    }
    close(fd);
    return esp_timer_get_time() - t0;
}

static void bench_connect(const char *label, const char *ip, int iters)
{
    printf("[BENCH] === %s: %dx connect %s:%d ===\n", label, iters, ip, HOST_PORT);
    for (int i = 0; i < iters; i++) {
        int ok, err;
        int64_t us = timed_connect_us(ip, HOST_PORT, &ok, &err);
        if (us >= 0) {
            printf("[BENCH] %-10s conn#%02d took %lld us : %s%s\n",
                   label, i, (long long)us,
                   ok ? "ESTABLISHED" : "FAIL",
                   ok ? "" : strerror(err));
        }
        vTaskDelay(pdMS_TO_TICKS(150));
    }
}

/* ------------------------- UDP 探针：制造 PENDING 表项 / 触发排队 ------------------------- */

/* 发一个无连接 UDP 包。目标若不在 ARP 缓存中：
 * ip4_output -> etharp_output -> etharp_query 会为它建 PENDING 表项并发 ARP 请求，
 * 数据包本体则挂在表项的队列上（IDF ARP_QUEUEING=1）。返回值保留 errno。 */
static void udp_probe(const char *label, const char *ip)
{
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) { printf("[UDP] %s socket failed errno=%d\n", label, errno); return; }

    struct sockaddr_in dst = {
        .sin_family = AF_INET,
        .sin_port   = htons(9999),   /* 无人接听也无妨，目的只在 ARP 路径 */
    };
    inet_pton(AF_INET, ip, &dst.sin_addr);

    char payload[4] = "ch8";
    int rc = sendto(fd, payload, sizeof(payload), 0,
                    (struct sockaddr *)&dst, sizeof(dst));
    printf("[UDP] probe %-6s -> %s : rc=%d%s\n",
           label, ip, rc, rc < 0 ? strerror(errno) : "");
    close(fd);
}

/* 连发 count 个到同一目标：解析完成前只会有前几个入队，后面的撞 ARP_QUEUE_LEN 上限 */
static void udp_burst(const char *label, const char *ip, int count)
{
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) { printf("[UDP] %s socket failed\n", label); return; }

    struct sockaddr_in dst = {
        .sin_family = AF_INET,
        .sin_port   = htons(9999),
    };
    inet_pton(AF_INET, ip, &dst.sin_addr);

    printf("[BURST] %s: %d rapid datagrams -> %s (resolve pending)\n", label, count, ip);
    for (int i = 0; i < count; i++) {
        int rc = sendto(fd, "ch08", 4, 0, (struct sockaddr *)&dst, sizeof(dst));
        printf("[BURST]   #%d rc=%d%s\n", i, rc, rc < 0 ? strerror(errno) : "");
    }
    close(fd);
}

/* 秒级心跳：给 debug 变体日志提供时间基准（etharp_tmr 每秒跑一轮） */
static void heartbeat(int seconds)
{
    for (int t = 1; t <= seconds; t++) {
        printf("[TICK] +%ds\n", t);
        vTaskDelay(pdMS_TO_TICKS(1000));
    }
}

/* ------------------------- app_main ------------------------- */

void app_main(void)
{
    ESP_LOGI(TAG, "== ch8 lab: ethernet RX path + ARP cache ==");
    ESP_LOGI(TAG, "[CFG] build: ARP_TABLE_SIZE=%d, ARP_QUEUEING=%d, LWIP_STATS=%d",
             (int)ARP_TABLE_SIZE, (int)ARP_QUEUEING, (int)LWIP_STATS);

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

    ESP_ERROR_CHECK(esp_event_handler_register(ETH_EVENT, ETHERNET_EVENT_CONNECTED,
                                               &eth_event_handler, NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(ETH_EVENT, ETHERNET_EVENT_DISCONNECTED,
                                               &eth_event_handler, NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_ETH_GOT_IP,
                                               &ip_event_handler, NULL));

    esp_eth_netif_glue_handle_t glue = esp_eth_new_netif_glue(eth_handle);
    ESP_ERROR_CHECK(esp_netif_attach(eth_netif, glue));

    ESP_ERROR_CHECK(esp_eth_start(eth_handle));
    ESP_LOGI(TAG, "waiting for DHCP lease ...");
    if (xSemaphoreTake(s_got_ip, pdMS_TO_TICKS(DHCP_TIMEOUT_MS)) != pdTRUE) {
        ESP_LOGE(TAG, "DHCP timeout");
        return;
    }

    vTaskDelay(pdMS_TO_TICKS(1000));              /* 让启动期事件链安静下来 */

    /* [W] 出手之前先看一眼地面真相：DHCP 流程有没有顺带把谁解析进缓存 */
    arp_dump("W boot ground truth");

    /* [A] 冷 vs 热：第一次 connect 含 ARP 解析，后续全走缓存命中 */
    bench_connect("cold-warm", GW_IP, N_CONN);

    /* [B] 新目标 → stable 入表；再加一个不可解目标 → PENDING 全过程（tmr 主导） */
    udp_probe("gw-dns", "10.0.2.3");              /* SLIRP DNS，会应答 */
    vTaskDelay(pdMS_TO_TICKS(300));               /* 给应答留一拍 */
    arp_dump("B after resolved 10.0.2.3");

    printf("[PEND] sent probe to unresolved 10.0.2.77, watch pending lifecycle ...\n");
    udp_probe("dead-ip", "10.0.2.77");
    arp_dump("B right after pending created (public API sees nothing)");
    heartbeat(7);                                  /* PENDING 5s 寿命窗 + 余量 */

    /* [C] 故障注入序列：两种表容量下都可运行；表=2 时可见驱逐 */
    arp_dump("C before fault sequence");

    udp_burst("queue-fill", "10.0.2.101", 5);     /* 同目标连发 5 个：队列上限演示 */
    vTaskDelay(pdMS_TO_TICKS(300));

    udp_probe("evictor", "10.0.2.201");           /* 第二个新目标：TRY_HARD 时开始挤压老表项 */
    vTaskDelay(pdMS_TO_TICKS(300));

    /* [C'] 关键对照：表满驱逐后，对网关的"热"连接退化回"冷" */
    bench_connect("post-evict", GW_IP, 3);

    arp_dump("C after fault sequence");

    printf("[STATS] final lwIP stats (ETHARP row: xmit/recv/fw/drop/err/memerr/cachehit)\n");
    stats_display();

    ESP_LOGI(TAG, "== ch8 lab done, idle ==");
    while (1) {
        vTaskDelay(pdMS_TO_TICKS(60000));
    }
}
