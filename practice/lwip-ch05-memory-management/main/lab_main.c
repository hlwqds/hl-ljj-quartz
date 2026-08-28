/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * lwIP 深度解析（五）实验工程：内存池、堆与耗尽实验
 *
 * 基于 ch3 联网模板（openeth bring-up + DHCP），新增：
 *   实验 A：IDF 全堆化下的内存基线 —— heap_caps 分区记账 + LWIP_STATS 协议统计；
 *           单次 echo 对话前后的堆快照 diff。
 *   实验 C：堆耗尽注入 —— 应用侧把堆吃到接近枯竭，观察 RX 路径分配失败传播；
 *           压力解除后观察自愈。
 *   实验 D：碎片化注入 —— 交错分配/释放制造空洞，用
 *           heap_caps_get_largest_free_block 展示 free 与 largest 的分叉。
 *   实验 B（单独构建）：sdkconfig 设 CONFIG_LWIP_MAX_ACTIVE_TCP=2 后重新构建，
 *           主机并发开多个连接，观察第 3 个及以后连接的拒绝位置。
 *           由 SLIM_MODE 宏在编译期裁剪掉 C/D 阶段、拉长观察窗口。
 *
 * 运行环境：ESP-IDF v6.0.2 + qemu-system-xtensa (Espressif fork)，
 *           -nic user,model=open_eth[,hostfwd=tcp::8005-:8888]
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <errno.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"

#include "esp_log.h"
#include "esp_event.h"
#include "esp_netif.h"
#include "esp_eth.h"
#include "esp_heap_caps.h"

/* 直接读 lwIP 全局统计与编译期选项；验证全堆化开关的运行时证据 */
#include "lwip/opt.h"
#include "lwip/stats.h"
/* socket 侧头文件（同 ch3 模板：VFS 集成经 netdb.h 链入 lwip/sockets 声明） */
#include "lwip/inet.h"
#include <netdb.h>

static const char *TAG = "ch5lab";

#define ECHO_PORT            8888   /* 主机侧经 hostfwd tcp::8005-:8888 访问 */
#define DHCP_TIMEOUT_MS      10000

/* 阶段时长：普通构建 vs MAX_ACTIVE_TCP<=2 的 SLIM_MODE 构建 */
#if defined(CONFIG_LWIP_MAX_ACTIVE_TCP) && (CONFIG_LWIP_MAX_ACTIVE_TCP <= 2)
#define SLIM_MODE             1
#endif

#ifndef SLIM_MODE
/* 普通构建的时间线 */
#define WINDOW1_S            15     /* 等 host 做 round-1 echo 对话 */
#define STARVE_START_DELAY_S 5      /* round-1 窗口结束后再开始吃堆 */
#define STARVE_HOLD_S        15     /* 枯竭状态保持期 */
#define WINDOW2_S            15     /* 恢复后等 host 做 round-2 复测 */
#define FINAL_KEEPALIVE_S    20
#else
#define WINDOW1_S            15     /* host 连发 5 连接，全部落在这个窗口 */
#define FINAL_KEEPALIVE_S    60     /* 拉长尾巴，观察 SYN 重试/SILIRP 行为 */
#endif

static SemaphoreHandle_t s_got_ip;
static SemaphoreHandle_t s_starve_done;
static esp_ip4_addr_t s_ip, s_nm, s_gw;

#if !defined(SLIM_MODE)
/* ---------------------- 实验 C：堆耗尽注入器 ---------------------- */

#define STARVE_NMAX   128
#define STARVE_CHUNK  4096
static void *s_starve_blk[STARVE_NMAX];

/* ---------------------- 实验 D：碎片化探针 ---------------------- */

#define FRAG_NB       24              /* 区块数 */
#define FRAG_SZ       2048            /* 单块字节数 */
#endif /* !SLIM_MODE */

/* ------------------------- 观测原语 ------------------------- */

static void heap_line(const char *tag)
{
    uint32_t caps = MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT;
    printf("[heap] %-16s free=%6u largest=%6u min-ever=%6u\n", tag,
           (unsigned)heap_caps_get_free_size(caps),
           (unsigned)heap_caps_get_largest_free_block(caps),
           (unsigned)heap_caps_get_minimum_free_size(caps));
}

static void heap_line_total(const char *tag)
{
    printf("[heap-total] %-13s free=%6u\n", tag,
           (unsigned)heap_caps_get_free_size(MALLOC_CAP_DEFAULT));
}

/* 直接读 lwip_stats 关键计数器（LWIP_STATS=y 时可用） */
static void netstats_line(const char *tag)
{
    printf("[netstat] %-12s link.recv=%lu link.drop=%lu ip.recv=%lu ip.drop=%lu "
           "tcp.recv=%lu tcp.xmit=%lu tcp.memerr=%lu udp.recv=%lu "
           "sys.sem.used=%lu sys.mutex.used=%lu sys.mbox.used=%lu\n",
           tag,
           (unsigned long)lwip_stats.link.recv,
           (unsigned long)lwip_stats.link.drop,
           (unsigned long)lwip_stats.ip.recv,
           (unsigned long)lwip_stats.ip.drop,
           (unsigned long)lwip_stats.tcp.recv,
           (unsigned long)lwip_stats.tcp.xmit,
           (unsigned long)lwip_stats.tcp.memerr,
           (unsigned long)lwip_stats.udp.recv,
           (unsigned long)lwip_stats.sys.sem.used,
           (unsigned long)lwip_stats.sys.mutex.used,
           (unsigned long)lwip_stats.sys.mbox.used);
}

static void memory_census(void)
{
    struct {
        const char *name;
        uint32_t    caps;
    } rows[] = {
        { "INTERNAL",      MALLOC_CAP_INTERNAL },
        { "INT|8BIT",      MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT },
        { "DMA",           MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL },
        { "DEFAULT",       MALLOC_CAP_DEFAULT },
    };

    printf("[MARKER] ===== census: per-caps memory ledger =====\n");
    for (size_t i = 0; i < sizeof(rows) / sizeof(rows[0]); i++) {
        uint32_t c = rows[i].caps;
        printf("[caps] %-9s total=%7u free=%7u largest=%7u min-ever=%7u\n",
               rows[i].name,
               (unsigned)heap_caps_get_total_size(c),
               (unsigned)heap_caps_get_free_size(c),
               (unsigned)heap_caps_get_largest_free_block(c),
               (unsigned)heap_caps_get_minimum_free_size(c));
    }

    /* 关键编译期证据：IDF 的 lwipopts.h 固定了这两个开关 */
    printf("[cfg] MEM_LIBC_MALLOC=%d MEMP_MEM_MALLOC=%d MEM_ALIGNMENT=%d "
           "(MEM_USE_POOLS=%d)\n",
           MEM_LIBC_MALLOC ? 1 : 0,
           MEMP_MEM_MALLOC ? 1 : 0,
           MEM_ALIGNMENT,
           MEM_USE_POOLS ? 1 : 0);
    printf("[cfg] CONFIG_LWIP_MAX_ACTIVE_TCP=%d CONFIG_LWIP_MAX_SOCKETS=%d "
           "TCP_MSS=%d TCP_SND_BUF=%d TCP_WND=%d TCPIP_MBOX_SIZE=%d "
           "PBUF_POOL_SIZE=%d\n",
           CONFIG_LWIP_MAX_ACTIVE_TCP, CONFIG_LWIP_MAX_SOCKETS,
           (int)TCP_MSS, (int)TCP_SND_BUF, (int)TCP_WND,
           (int)TCPIP_MBOX_SIZE, PBUF_POOL_SIZE);

    printf("[MARKER] ----- stats_display(): expect NO MEM/MEMP section -----\n");
    stats_display();
    printf("[MARKER] ----------------------------------------------\n");

    heap_caps_print_heap_info(MALLOC_CAP_INTERNAL);
}

/* ------------------------- TCP echo server -------------------------
 * 与 ch3 相同的服务循环，但每个连接 accept / close 时打印堆快照，
 * 用于单次对话前后的 diff。串行处理，一接一发即断。 */

static void echo_server_task(void *arg)
{
    char rx_buf[1024];
    struct sockaddr_in local_addr = {
        .sin_family      = AF_INET,
        .sin_port        = htons(ECHO_PORT),
        .sin_addr.s_addr = htonl(INADDR_ANY),
    };
    int conns = 0;

    int listen_sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    assert(listen_sock >= 0);
    int opt = 1;
    setsockopt(listen_sock, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    int err = bind(listen_sock, (struct sockaddr *)&local_addr, sizeof(local_addr));
    if (err != 0) {
        ESP_LOGE(TAG, "bind :%d failed errno=%d", ECHO_PORT, errno);
        vTaskDelete(NULL);
    }
    err = listen(listen_sock, 6);
    assert(err == 0);
    ESP_LOGI(TAG, "echo server listening on 0.0.0.0:%d", ECHO_PORT);
    printf("[MARKER] ECHO_READY_PORT_%d\n", ECHO_PORT);

    while (1) {
        struct sockaddr_in src_addr;
        socklen_t addr_len = sizeof(src_addr);
        int sock = accept(listen_sock, (struct sockaddr *)&src_addr, &addr_len);
        if (sock < 0) {
            ESP_LOGE(TAG, "accept failed errno=%d", errno);
            vTaskDelay(pdMS_TO_TICKS(100));    /* 失败也稍作退避 */
            continue;
        }
        conns++;
        printf("[echo] #%d ACCEPT from %s:%d\n", conns,
               inet_ntoa(src_addr.sin_addr), ntohs(src_addr.sin_port));
        heap_line("on-accept");

        int len;
        int total = 0, rounds = 0;
        while ((len = recv(sock, rx_buf, sizeof(rx_buf), 0)) > 0) {
            if (send(sock, rx_buf, len, 0) < 0) {
                ESP_LOGE(TAG, "send failed errno=%d", errno);
                break;
            }
            total += len; rounds++;
        }
        if (len < 0) {
            ESP_LOGE(TAG, "recv failed errno=%d", errno);
        }
        close(sock);
        printf("[echo] #%d CLOSE served_rounds=%d bytes=%d\n",
               conns, rounds, total);
        heap_line("on-close");
        netstats_line("post-close");
    }
}

/* ------------------------- 以太网 bring-up（同 ch3） ------------------------- */

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

#if !defined(SLIM_MODE)

static void starver_task(void *arg)
{
    vTaskDelay(pdMS_TO_TICKS(WINDOW1_S * 1000 + STARVE_START_DELAY_S * 1000));

    printf("[MARKER] ===== PHASE-C heap starvation begin =====\n");
    int n = 0;
    size_t held = 0;
    while (n < STARVE_NMAX) {
        void *b = malloc(STARVE_CHUNK);          /* 与 lwIP 同一个 libc 堆 */
        if (!b) {
            b = malloc(512);                     /* 收尾阶段换小颗粒继续啃 */
            if (!b) {
                break;                            /* 真的没得吃了 */
            }
            held += 512;
        } else {
            held += STARVE_CHUNK;
        }
        s_starve_blk[n++] = b;
        if ((n & 7) == 0) {
            printf("[starve] grabbed=%d held=%uB", n, (unsigned)held);
            heap_line("");
        }
    }
    printf("[starve] saturated: grabbed=%d held=%uB (allocation returned NULL)\n",
           n, (unsigned)held);
    heap_line("starved-floor");

    /* 保持期：host 持续灌流量，RX 分配失败应当出现 */
    for (int i = 0; i < STARVE_HOLD_S / 5; i++) {
        vTaskDelay(pdMS_TO_TICKS(5000));
        printf("[starve-hold] +%ds", (i + 1) * 5);
        netstats_line("hold");
    }

    printf("[MARKER] ===== PHASE-C release: free everything -----\n");
    while (n > 0) {
        free(s_starve_blk[--n]);
    }
    vTaskDelay(pdMS_TO_TICKS(300));
    heap_line("released+t300ms");
    heap_line_total("released+t300ms");
    vTaskDelay(pdMS_TO_TICKS(2700));
    heap_line("released+t3s");
    printf("[MARKER] ===== PHASE-C done, expect recovery =====\n");
    xSemaphoreGive(s_starve_done);
    vTaskDelete(NULL);
}

static void frag_probe(void)
{
    static void *blk[FRAG_NB];
    printf("[MARKER] ===== PHASE-D fragmentation probes =====\n");

    heap_line("frag-baseline");

    /* 1) 大块整体分配：连续切分最大块 */
    memset(blk, 0, sizeof(blk));
    for (int i = 0; i < FRAG_NB; i++) {
        blk[i] = malloc(FRAG_SZ);
        assert(blk[i]);
    }
    heap_line("frag-all-alloc");

    /* 2) 隔块释放：留下 2KB 单洞，被活块隔开 */
    for (int i = 0; i < FRAG_NB; i += 2) {
        free(blk[i]);
        blk[i] = NULL;
    }
    heap_line("frag-even-freed");

    /* 3) 回填空洞：新的小块应能精确填回 */
    for (int i = 0; i < FRAG_NB; i += 2) {
        blk[i] = malloc(FRAG_SZ);
    }
    heap_line("frag-refilled");

    /* 4) 全部释放：相邻合并应还原大块 */
    for (int i = 0; i < FRAG_NB; i++) {
        free(blk[i]);
        blk[i] = NULL;
    }
    vTaskDelay(pdMS_TO_TICKS(100));
    heap_line("frag-all-free");

    /* 5) 混合尺寸 churn：模拟协议栈日常分配模式 */
    {
        enum { SLOTS = 32, CYCLES = 400 };
        static void *slot[SLOTS];
        static const size_t sizes[] = { 64, 128, 256, 552, 1024, 1516 };
        unsigned seed = 1234;
        for (int c = 0; c < CYCLES; c++) {
            int idx = c % SLOTS;
            if (slot[idx]) {
                free(slot[idx]);
            }
            seed = seed * 1103515245 + 12345;    /* 简单 LCG，确定性 */
            slot[idx] = malloc(sizes[(seed >> 16) % (sizeof(sizes)/sizeof(sizes[0]))]);
        }
        for (int i = 0; i < SLOTS; i++) {
            free(slot[i]);
        }
        heap_line("frag-after-churn");
    }
}
#endif /* !SLIM_MODE */

/* ------------------------- app_main ------------------------- */

void app_main(void)
{
    ESP_LOGI(TAG, "== ch5 lab: memory pools / heap / exhaustion injections ==");
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    s_got_ip = xSemaphoreCreateBinary();
#if !defined(SLIM_MODE)
    s_starve_done = xSemaphoreCreateBinary();
#endif

    xTaskCreate(echo_server_task, "echo_srv", 4096, NULL, 5, NULL);

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

    ESP_ERROR_CHECK(esp_event_handler_register(ETH_EVENT, ESP_EVENT_ANY_ID,
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

    /* ===== 实验 A：空闲基线 ===== */
    printf("[MARKER] ===== PHASE-A idle memory census =====\n");
    heap_line("idle-after-dhcp");
    heap_line_total("idle-after-dhcp");
    memory_census();

#if defined(SLIM_MODE)
    /* ===== 实验 B 构建：只留 echo 服务与超长观察窗口 ===== */
    printf("[MARKER] ===== PHASE-B window open: fire >=5 concurrent connections at port 8888 =====\n");
    printf("[MARKER] SLIM_MODE: max_active_tcp=%d, watch where SYN #3.. gets rejected\n",
           CONFIG_LWIP_MAX_ACTIVE_TCP);
#else
    /* ===== 等 host 做 round-1 单次对话 ===== */
    printf("[MARKER] ===== PHASE-A2 waiting %ds for host echo round-1 =====\n", WINDOW1_S);
    vTaskDelay(pdMS_TO_TICKS(WINDOW1_S * 1000));
    netstats_line("round1-done");

    /* ===== 实验 C：starver 结束后用信号量握手，避免固定延时猜节奏 ===== */
    xTaskCreate(starver_task, "starver", 3072, NULL, 4, NULL);
    xSemaphoreTake(s_starve_done, pdMS_TO_TICKS((STARVE_START_DELAY_S + 90) * 1000));

    /* ===== 恢复证明窗口：host 再来一次 echo round-2 ===== */
    printf("[MARKER] ===== WINDOW2 (%ds): host echo round-2 == recovery proof =====\n", WINDOW2_S);
    vTaskDelay(pdMS_TO_TICKS(WINDOW2_S * 1000));

    /* ===== 实验 D ===== */
    frag_probe();

    /* ===== 尾声 ===== */
    printf("[MARKER] ===== final watermark =====\n");
    heap_line("final");
    netstats_line("final");
    printf("[MARKER] keepalive %ds\n", FINAL_KEEPALIVE_S);
#endif
    vTaskDelay(pdMS_TO_TICKS(FINAL_KEEPALIVE_S * 1000));
}
