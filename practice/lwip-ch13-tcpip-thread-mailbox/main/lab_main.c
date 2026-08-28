/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * lwIP 深度解析（十三）实验工程：tcpip_thread 与邮箱模型
 *
 * 基于 ch3 联网模板（openeth bring-up + DHCP），做四组实验：
 *   A. 执行上下文证明：app 任务 / tcpip_callback / sys_timeout / raw udp 回调 /
 *      socket echo 各自打印"我现在跑在哪个任务里"，验证单线程模型；
 *   B. 邮箱时延测量：空载与满载（hammer 任务持续轰炸）下 tcpip 回调的
 *      单向投递时延与同步往返时延，各测 1000 次，出中位/P95/P99；
 *   C. 故障注入·单线程卡死：故意在回调里 sleep 3s，观察协议栈整体停摆；
 *   D. 故障注入·邮箱满：先让一个 blocker 占住 tcpip 线程，再从另一任务
 *      高频投递 >32 条消息，对比 tcpip_callback（阻塞）与
 *      tcpip_try_callback（失败即返）两种语义。
 *
 * 运行环境：ESP-IDF v6.0.2 + qemu-system-xtensa，
 *           -nic user,model=openeth,hostfwd=tcp::8015-:8888
 */

#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <assert.h>
#include <errno.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"

#include "esp_log.h"
#include "esp_event.h"
#include "esp_netif.h"
#include "esp_eth.h"
#include "esp_timer.h"

#include "lwip/inet.h"
#include "lwip/sockets.h"
#include "lwip/tcpip.h"
#include "lwip/udp.h"
#include "lwip/sys.h"

/* IDF v6 中 ping 应用在 lwIP 组件内：components/lwip/include/apps/ping/ping_sock.h */
#include "ping/ping_sock.h"

static const char *TAG = "ch13lab";

#define ECHO_PORT        8888     /* 主机侧经 hostfwd tcp::8015-:8888 访问 */
#define RAW_UDP_PORT     9777     /* loopback 探针：socket 发往自己的 raw udp 口 */
#define DHCP_TIMEOUT_MS  10000
#define STALL_MS         3000     /* 实验 C：回调内睡眠时长 */
#define BLOCK_MS         1500     /* 实验 D：blocker 占住 tcpip 线程时长 */
#define N_LAT            1000     /* 时延采样次数 */
#define FLOOD_N          80       /* 实验 D：顺序阻塞式投递条数(>32) */
#define TRY_N_MAX        4000     /* 实验 D：try_callback 尝试上限 */

static SemaphoreHandle_t s_got_ip;
static esp_ip4_addr_t s_ip;

/* --------------------------- 工具：任务清单 --------------------------- */

static void print_task_table(const char *when)
{
    UBaseType_t n = uxTaskGetNumberOfTasks();
    TaskStatus_t *st = pvPortMalloc(n * sizeof(TaskStatus_t));
    if (st == NULL) {
        ESP_LOGW(TAG, "[tasks] OOM for status array");
        return;
    }
    UBaseType_t got = uxTaskGetSystemState(st, n, NULL);
    ESP_LOGI(TAG, "[tasks] %s: %u tasks", when, (unsigned)got);
    for (UBaseType_t i = 0; i < got; i++) {
        printf("[tasks]   %-16s prio=%2u hwm=%5u\n",
               st[i].pcTaskName, (unsigned)st[i].uxCurrentPriority,
               (unsigned)st[i].usStackHighWaterMark);
    }
    vPortFree(st);
}

/* ------------------------ 实验 A：上下文探针 ------------------------ */

/* 在任意执行上下文里打印"我是谁" */
static void probe_ctx(const char *label)
{
    ESP_LOGI(TAG, "[ctx] %-24s task='%s' prio=%u core=%ld",
             label, pcTaskGetName(NULL),
             (unsigned)uxTaskPriorityGet(NULL), (long)xPortGetCoreID());
}

static void ctx_via_tcpip_callback(void *arg)
{
    probe_ctx((const char *)arg);
}

static void ctx_timer_probe(void *arg)
{
    probe_ctx("sys_timeout cb");
    (void)arg;
}

static struct udp_pcb *s_probe_pcb;

static void raw_udp_recv(void *arg, struct udp_pcb *pcb, struct pbuf *p,
                         const ip_addr_t *addr, u16_t port)
{
    probe_ctx("udp_raw recv cb");
    (void)arg; (void)pcb; (void)addr; (void)port;
    pbuf_free(p);
}

/* raw udp pcb 的创建也必须在 tcpip 线程内完成 */
static void raw_udp_setup_cb(void *arg)
{
    err_t err;
    s_probe_pcb = udp_new();
    assert(s_probe_pcb != NULL);
    err = udp_bind(s_probe_pcb, IP_ANY_TYPE, RAW_UDP_PORT);
    assert(err == ERR_OK);
    udp_recv(s_probe_pcb, raw_udp_recv, NULL);
    probe_ctx("tcpip_callback(setup)");
    (void)arg;
}

static void run_exp_a(void)
{
    ESP_LOGI(TAG, "--- experiment A: who runs my code? ---");
    probe_ctx("app_main (direct)");

    ESP_ERROR_CHECK(tcpip_callback(ctx_via_tcpip_callback,
                                   (void *)"via tcpip_callback"));
    sys_timeout(700, ctx_timer_probe, NULL);
    ESP_ERROR_CHECK(tcpip_callback(raw_udp_setup_cb, NULL));

    vTaskDelay(pdMS_TO_TICKS(1100));   /* 等 timer/raw 注册就绪 */

    /* 用 loopback 把一条 UDP 从"普通任务"送进协议栈，触发 raw 接收回调：
     * 发送走 socket->netconn->邮箱；接收回调在 tcpip 线程内被消费 */
    for (int i = 0; i < 2; i++) {
        int s = socket(AF_INET, SOCK_DGRAM, 0);
        assert(s >= 0);
        struct sockaddr_in dst = {
            .sin_family = AF_INET,
            .sin_port   = htons(RAW_UDP_PORT),
            .sin_addr.s_addr = htonl(INADDR_LOOPBACK),
        };
        sendto(s, "probe", 5, 0, (struct sockaddr *)&dst, sizeof(dst));
        close(s);
        vTaskDelay(pdMS_TO_TICKS(150));
    }
    vTaskDelay(pdMS_TO_TICKS(200));
}

/* ------------------------ 实验 B：邮箱时延 ------------------------ */

static int cmp_i64(const void *a, const void *b)
{
    int64_t x = *(const int64_t *)a, y = *(const int64_t *)b;
    return (x > y) - (x < y);
}

static void pct_report(const char *tag, int64_t *v, int n)
{
    qsort(v, n, sizeof(int64_t), cmp_i64);
    int64_t sum = 0;
    for (int i = 0; i < n; i++) sum += v[i];
    printf("[bench] %-28s n=%d min=%lld med=%lld p95=%lld p99=%lld max=%lld avg=%.1f us\n",
           tag, n, (long long)v[0], (long long)v[n / 2],
           (long long)v[n * 95 / 100], (long long)v[n * 99 / 100],
           (long long)v[n - 1], (double)sum / n);
}

static void stamp_noop_cb(void *arg)
{
    int64_t *t = arg;
    *t = esp_timer_get_time();
}

static void plain_noop_cb(void *arg)
{
    (void)arg;
}

static volatile bool s_hammer_stop;
static volatile uint32_t s_hammer_posted;

static void hammer_task(void *arg)
{
    while (!s_hammer_stop) {
        if (tcpip_callback(plain_noop_cb, NULL) == ERR_OK)
            s_hammer_posted++;
        else
            vTaskDelay(1);          /* 极罕见：memp 池耗尽，退避一下 */
    }
    vTaskDelete(NULL);
}
static void run_exp_b(void)
{
    ESP_LOGI(TAG, "--- experiment B: mailbox latency (n=%d each) ---", N_LAT);
    int64_t *rtt = pvPortMalloc(N_LAT * sizeof(int64_t));
    int64_t *ow  = pvPortMalloc(N_LAT * sizeof(int64_t));
    assert(rtt && ow);

    /* 空载：同步往返 tcpip_callback_wait(含每次调用建/删信号量的开销) */
    for (int i = 0; i < N_LAT; i++) {
        int64_t t0 = esp_timer_get_time();
        ESP_ERROR_CHECK(tcpip_callback_wait(plain_noop_cb, NULL));
        rtt[i] = esp_timer_get_time() - t0;
    }
    pct_report("idle sync RTT(wait)", rtt, N_LAT);

    /* 空载：异步单向时延（回调被实际执行的瞬间打时间戳） */
    for (int i = 0; i < N_LAT; i++) {
        int64_t stamp = 0;
        int64_t t0 = esp_timer_get_time();
        ESP_ERROR_CHECK(tcpip_callback(stamp_noop_cb, &stamp));
        while (!stamp) {
            vTaskDelay(0);          /* 让出 CPU 给 tcpip 线程消化 */
        }
        ow[i] = stamp - t0;
    }
    pct_report("idle async 1-way", ow, N_LAT);

    /* 满载：hammer 任务无节流轰炸 noop 回调，把 tcpip 线程喂饱 */
    ESP_LOGI(TAG, "[bench] starting hammer task (saturating tcpip thread)...");
    s_hammer_stop = false;
    s_hammer_posted = 0;
    xTaskCreate(hammer_task, "mbox_hammer", 3072, NULL, 4, NULL); /* 比测量任务低，避免饿死计时方 */
    vTaskDelay(pdMS_TO_TICKS(300));  /* 先把队列喂积压起来 */

    for (int i = 0; i < N_LAT; i++) {
        int64_t t0 = esp_timer_get_time();
        ESP_ERROR_CHECK(tcpip_callback_wait(plain_noop_cb, NULL));
        rtt[i] = esp_timer_get_time() - t0;
    }
    pct_report("loaded sync RTT(wait)", rtt, N_LAT);

    for (int i = 0; i < N_LAT; i++) {
        int64_t stamp = 0;
        int64_t t0 = esp_timer_get_time();
        ESP_ERROR_CHECK(tcpip_callback(stamp_noop_cb, &stamp));
        while (!stamp) {
            vTaskDelay(0);
        }
        ow[i] = stamp - t0;
    }
    pct_report("loaded async 1-way", ow, N_LAT);

    /* 停锤并等尾部排空 */
    s_hammer_stop = true;
    vTaskDelay(pdMS_TO_TICKS(500));
    ESP_LOGI(TAG, "[bench] hammer posted=%u messages total", (unsigned)s_hammer_posted);
    vPortFree(rtt);
    vPortFree(ow);
}

/* --------------------- 实验 C：单线程心脏停跳 --------------------- */

static void stall_ping_success(esp_ping_handle_t hdl, void *args)
{
    uint16_t seqno;
    uint32_t elapsed_us;
    esp_ping_get_profile(hdl, ESP_PING_PROF_SEQNO, &seqno, sizeof(seqno));
    esp_ping_get_profile(hdl, ESP_PING_PROF_TIMEGAP, &elapsed_us, sizeof(elapsed_us));
    ESP_LOGI(TAG, "[C-ping] reply seq=%u time=%lu us", seqno, (unsigned long)elapsed_us);
}

static void stall_ping_timeout(esp_ping_handle_t hdl, void *args)
{
    uint16_t seqno;
    esp_ping_get_profile(hdl, ESP_PING_PROF_SEQNO, &seqno, sizeof(seqno));
    ESP_LOGW(TAG, "[C-ping] seq=%u TIMEOUT", seqno);
}

static void stall_cb(void *arg)
{
    ESP_LOGI(TAG, "[C] stall BEGIN inside '%s' (sleeping %d ms) -- whole stack frozen",
             pcTaskGetName(NULL), STALL_MS);
    vTaskDelay(pdMS_TO_TICKS(STALL_MS));
    ESP_LOGI(TAG, "[C] stall END -- heart beating again");
    (void)arg;
}

static void run_exp_c(void)
{
    ESP_LOGI(TAG, "--- experiment C: stall tcpip thread %d ms ---", STALL_MS);

    /* 一路贯穿整个卡死窗口的 ICMP 会话：请求/回复都走 tcpip 线程，
     * 卡死期间发出的请求排队、卡死恢复后一起冲出，观测时延爆表 */
    ip_addr_t target;
    IP_SET_TYPE_VAL(target, IPADDR_TYPE_V4);
    ip_2_ip4(&target)->addr = PP_HTONL(0x0A000202);   /* SLIRP 网关 10.0.2.2 */
    esp_ping_config_t cfg = ESP_PING_DEFAULT_CONFIG();
    cfg.target_addr = target;
    cfg.count       = 28;
    cfg.interval_ms = 250;        /* 覆盖约 7s，含 3s 卡死窗口 */
    cfg.timeout_ms  = 1200;
    esp_ping_callbacks_t cbs = {
        .on_ping_success = stall_ping_success,
        .on_ping_timeout = stall_ping_timeout,
    };
    esp_ping_handle_t hdl = NULL;
    ESP_ERROR_CHECK(esp_ping_new_session(&cfg, &cbs, &hdl));
    esp_ping_start(hdl);

    vTaskDelay(pdMS_TO_TICKS(700));  /* 先建立基线：几发正常往返 + ARP 预热 */
    ESP_LOGI(TAG, "[C] baseline done, about to post stall callback");
    int64_t t0 = esp_timer_get_time();
    ESP_ERROR_CHECK(tcpip_callback(stall_cb, NULL));
    ESP_LOGI(TAG, "[C] post took %lld us (fire-and-forget)",
             (long long)(esp_timer_get_time() - t0));
    /* 此刻起 3s 内：ICMP 回复、TCP 握手、定时器全部冻结在邮箱后面 */

    vTaskDelay(pdMS_TO_TICKS(STALL_MS + 2600));  /* 等观察窗收尾 */
    esp_ping_stop(hdl);
    esp_ping_delete_session(hdl);
    ESP_LOGI(TAG, "[C] observation window over");
}

/* ----------------------- 实验 D：邮箱塞满 ----------------------- */

static void blocker_cb(void *arg)
{
    ESP_LOGI(TAG, "[D] blocker running in '%s', hogging tcpip thread %d ms",
             pcTaskGetName(NULL), BLOCK_MS);
    vTaskDelay(pdMS_TO_TICKS(BLOCK_MS));
    ESP_LOGI(TAG, "[D] blocker done");
    (void)arg;
}

static void flooded_noop_cb(void *arg)
{
    (void)arg;
}

static volatile uint32_t s_flood_ok, s_flood_blocked_max_us;
static volatile bool s_try_stop;
static SemaphoreHandle_t s_flood_done;

static void flood_poster_task(void *arg)
{
    int instant = 0, blocked = 0;
    int64_t worst_gap = 0;
    for (int i = 0; i < FLOOD_N; i++) {
        int64_t t0 = esp_timer_get_time();
        err_t rc = tcpip_callback(flooded_noop_cb, NULL);
        int64_t dt = esp_timer_get_time() - t0;
        if (rc != ERR_OK) {
            ESP_LOGE(TAG, "[D] flood[%02d] FAILED rc=%d", i, rc);
            continue;
        }
        if (dt > 2000) {          /* >2ms 视为发生过阻塞等待 */
            blocked++;
            ESP_LOGW(TAG, "[D] flood[%02d] BLOCKED %lld us waiting for mbox slot", i,
                     (long long)dt);
            if (dt > worst_gap) worst_gap = dt;
        } else {
            instant++;
            ESP_LOGI(TAG, "[D] flood[%02d] instant (%lld us)", i, (long long)dt);
        }
    }
    s_flood_ok = instant;
    s_flood_blocked_max_us = (uint32_t)worst_gap;
    ESP_LOGI(TAG, "[D] flood summary: instant=%d blocked=%d worst=%lld us",
             instant, blocked, (long long)worst_gap);
    xSemaphoreGive(s_flood_done);
    vTaskDelete(NULL);
}

static void try_poster_task(void *arg)
{
    uint32_t ok = 0, fail = 0;
    while (!s_try_stop && fail < TRY_N_MAX) {
        if (tcpip_try_callback(flooded_noop_cb, NULL) == ERR_OK)
            ok++;
        else
            fail++;
    }
    ESP_LOGI(TAG, "[D] try_callback while saturated: OK=%u ERR_MEM(full)=%u "
             "(source returns ERR_MEM immediately, never blocks)", (unsigned)ok, (unsigned)fail);
    vTaskDelete(NULL);
}

static void run_exp_d(void)
{
    ESP_LOGI(TAG, "--- experiment D: mailbox overflow (depth=%d) ---",
             (int)CONFIG_LWIP_TCPIP_RECVMBOX_SIZE);
    s_flood_done = xSemaphoreCreateBinary();

    /* 1. 先投 blocker 占住 tcpip 线程，制造稳定的"消费者停摆"窗口 */
    ESP_ERROR_CHECK(tcpip_callback(blocker_cb, NULL));
    vTaskDelay(pdMS_TO_TICKS(80));   /* 确保 blocker 已被取走并开始睡 */

    /* 2. 两路并发轰炸 */
    xTaskCreate(flood_poster_task, "flood", 3072, NULL, 5, NULL);
    xTaskCreate(try_poster_task, "tryflood", 3072, NULL, 5, NULL);

    xSemaphoreTake(s_flood_done, pdMS_TO_TICKS(BLOCK_MS * 4));
    s_try_stop = true;               /* 停掉 try_poster 的观察窗口 */
    vTaskDelay(pdMS_TO_TICKS(1000)); /* 积压完全排空 */
    ESP_LOGI(TAG, "[D] backlog drained, system back to normal");
    vSemaphoreDelete(s_flood_done);
}

/* ---------------------- socket echo server（对照物） ---------------------- */

static void echo_server_task(void *arg)
{
    char rx_buf[512];
    struct sockaddr_in local_addr = {
        .sin_family      = AF_INET,
        .sin_port        = htons(ECHO_PORT),
        .sin_addr.s_addr = htonl(INADDR_ANY),
    };

    int listen_sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    assert(listen_sock >= 0);
    int opt = 1;
    setsockopt(listen_sock, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    int err = bind(listen_sock, (struct sockaddr *)&local_addr, sizeof(local_addr));
    assert(err == 0);
    assert(listen(listen_sock, 1) == 0);
    ESP_LOGI(TAG, "echo server listening on 0.0.0.0:%d", ECHO_PORT);

    while (1) {
        struct sockaddr_in src_addr;
        socklen_t addr_len = sizeof(src_addr);
        int sock = accept(listen_sock, (struct sockaddr *)&src_addr, &addr_len);
        if (sock < 0) {
            ESP_LOGE(TAG, "accept failed errno=%d", errno);
            continue;
        }
        probe_ctx("socket accept");
        ESP_LOGI(TAG, "echo: client %s:%d connected",
                 inet_ntoa(src_addr.sin_addr), ntohs(src_addr.sin_port));
        int len;
        while ((len = recv(sock, rx_buf, sizeof(rx_buf), 0)) > 0) {
            send(sock, rx_buf, len, 0);
        }
        close(sock);
        ESP_LOGI(TAG, "echo: client disconnected");
    }
}

/* ------------------------------ bring-up ------------------------------ */

static void eth_event_handler(void *arg, esp_event_base_t base,
                              int32_t event_id, void *event_data)
{
    switch (event_id) {
    case ETHERNET_EVENT_CONNECTED:
        ESP_LOGI(TAG, "ETH_EVENT: CONNECTED (link up)");
        break;
    case ETHERNET_EVENT_DISCONNECTED:
        ESP_LOGI(TAG, "ETH_EVENT: DISCONNECTED");
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
    ESP_LOGI(TAG, "GOT_IP: " IPSTR, IP2STR(&s_ip));
    xSemaphoreGive(s_got_ip);
}

void app_main(void)
{
    ESP_LOGI(TAG, "== ch13 lab: tcpip_thread & mailbox model ==");
    ESP_LOGI(TAG, "build facts: TCPIP_MBOX_SIZE=%d CORE_LOCKING=%d",
             (int)CONFIG_LWIP_TCPIP_RECVMBOX_SIZE,
#ifdef CONFIG_LWIP_TCPIP_CORE_LOCKING
             1);
#else
             0);
#endif

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
    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_ETH_GOT_IP,
                                               &ip_event_handler, NULL));

    esp_eth_netif_glue_handle_t glue = esp_eth_new_netif_glue(eth_handle);
    ESP_ERROR_CHECK(esp_netif_attach(eth_netif, glue));

    ESP_ERROR_CHECK(esp_eth_start(eth_handle));
    ESP_LOGI(TAG, "waiting for DHCP lease ...");

    if (xSemaphoreTake(s_got_ip, pdMS_TO_TICKS(DHCP_TIMEOUT_MS)) != pdTRUE) {
        ESP_LOGE(TAG, "DHCP timeout -- check QEMU -nic");
        return;
    }

    xTaskCreate(echo_server_task, "echo_srv", 4096, NULL, 5, NULL);
    vTaskDelay(pdMS_TO_TICKS(300));

    print_task_table("after bring-up");

    run_exp_a();                     /* 执行上下文证明 */
    vTaskDelay(pdMS_TO_TICKS(300));
    run_exp_b();                     /* 邮箱时延（空载/满载） */
    vTaskDelay(pdMS_TO_TICKS(500));
    run_exp_c();                     /* 单线程卡死（主机侧同步观察） */
    vTaskDelay(pdMS_TO_TICKS(500));
    run_exp_d();                     /* 邮箱满 */

    vTaskDelay(pdMS_TO_TICKS(1000));
    print_task_table("at end");
    ESP_LOGI(TAG, "== ch13 lab all phases done, echo stays on :%d ==", ECHO_PORT);
    vTaskDelay(portMAX_DELAY);
}
