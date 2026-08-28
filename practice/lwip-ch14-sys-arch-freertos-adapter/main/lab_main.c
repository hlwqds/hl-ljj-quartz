/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * lwIP 深度解析（十四）实验工程：sys_arch 缝合层标定
 *
 * 基于 ch3 联网模板（openeth bring-up + DHCP），增加四组测量：
 *   A. 原语成本标定：sys_mbox post/fetch 往返 vs 裸 FreeRTOS 队列往返
 *      vs sys_sem give/take 往返 vs 任务通知往返（各 10000 次，中位/P95）
 *   B. sys_now 时基验证：与 esp_timer_get_time 的偏移分布 + tick 步进序列
 *   C. 故障注入：
 *      C1 自建邮箱 + 慢消费者 -> sys_mbox_post 阻塞时长分布
 *      C2 系统邮箱(tcpip mbox)：挂起填满判容量、恢复后排队税、
 *         慢回调期间 socket() 的端到端阻塞演示
 *   D. 任务清单观测（uxTaskGetSystemState，需 CONFIG_FREERTOS_USE_TRACE_FACILITY=y）
 *
 * 运行环境：ESP-IDF v6.0.2 + qemu-system-xtensa (Espressif fork)
 *           -nic user,model=open_eth,hostfwd=tcp::8016-:8888
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>
#include <assert.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"

#include "esp_log.h"
#include "esp_event.h"
#include "esp_netif.h"
#include "esp_eth.h"
#include "esp_timer.h"
#include "esp_rom_sys.h"

#include "lwip/inet.h"
#include "lwip/sockets.h" /* socket/close：实验 C2 阶段 3 与 echo server */
#include "lwip/sys.h"     /* sys_mbox_* / sys_sem_* / sys_now：测量对象本体 */
#include "lwip/tcpip.h"   /* tcpip_try_callback / tcpip_callback */
#include "lwip/opt.h"     /* TCPIP_MBOX_SIZE / MEMP_NUM_TCPIP_MSG_API 数值 */

static const char *TAG = "ch14lab";

#define ECHO_PORT        8888     /* 主机侧经 hostfwd tcp::8016-:8888 访问 */
#define DHCP_TIMEOUT_MS  10000

/* ------------------------- 通用统计工具 ------------------------- */

#define BENCH_N     10000
#define BATCH_N      500    /* 分批跑批，批间 vTaskDelay(1) 喂调度器 */

static int64_t g_dt[BENCH_N];

static int cmp_i64(const void *a, const void *b)
{
    int64_t d = *(const int64_t *)a - *(const int64_t *)b;
    return d < 0 ? -1 : (d > 0 ? 1 : 0);
}

static void report_us(const char *name, int64_t *dt, int n)
{
    qsort(dt, n, sizeof(int64_t), cmp_i64);
    printf("[bench] %-20s n=%5d min=%lld us median=%lld us P95=%lld us max=%lld us\n",
           name, n, (long long)dt[0], (long long)dt[n / 2],
           (long long)dt[(n * 95) / 100], (long long)dt[n - 1]);
}

typedef void (*rtt_fn)(void);

static void run_rtt(const char *name, rtt_fn fn)
{
    int k = 0;
    while (k < BENCH_N) {
        int end = (k + BATCH_N > BENCH_N) ? BENCH_N : k + BATCH_N;
        for (; k < end; k++) {
            int64_t t0 = esp_timer_get_time();
            fn();
            g_dt[k] = esp_timer_get_time() - t0;
        }
        vTaskDelay(1);
    }
    report_us(name, g_dt, BENCH_N);
}

/* ------------------------- 实验 A：原语微基准 ------------------------- */

static sys_mbox_t s_bench_mbox;        /* lwIP 缝合层邮箱（深度 32） */
static QueueHandle_t s_raw_queue;      /* 同参数裸 FreeRTOS 队列 */
static sys_sem_t s_bench_sem;          /* lwIP 二值信号量（IDF：值内嵌 StaticSemaphore_t）*/

static void rtt_sys_mbox(void)
{
    void *in = (void *)&s_bench_mbox, *out = NULL;
    sys_mbox_post(&s_bench_mbox, in);
    assert(sys_arch_mbox_tryfetch(&s_bench_mbox, &out) == 0);
}

static void rtt_raw_queue(void)
{
    void *in = (void *)&s_raw_queue, *out = NULL;
    assert(xQueueSend(s_raw_queue, &in, 0) == pdTRUE);
    assert(xQueueReceive(s_raw_queue, &out, 0) == pdTRUE);
}

static void rtt_sys_sem(void)
{
    /* IDF 的 sys_sem_t 是值内嵌的 StaticSemaphore_t：给/取都走它的地址 */
    assert(xSemaphoreGive((QueueHandle_t)&s_bench_sem) == pdTRUE);
    assert(xSemaphoreTake((QueueHandle_t)&s_bench_sem, 0) == pdTRUE);
}

static void rtt_task_notify(void)
{
    xTaskNotify(xTaskGetCurrentTaskHandle(), 0, eIncrement);
    assert(ulTaskNotifyTake(pdTRUE, 0) >= 1);
}

static void exp_a_primitives(void)
{
    printf("--- experiment A: primitive round-trip cost (%d iters) ---\n", BENCH_N);

    assert(sys_mbox_new(&s_bench_mbox, 32) == ERR_OK);
    s_raw_queue = xQueueCreate(32, sizeof(void *));
    assert(s_raw_queue != NULL);
    assert(sys_sem_new(&s_bench_sem, 0) == ERR_OK);

    run_rtt("lwip_sys_mbox_RTT", rtt_sys_mbox);
    run_rtt("raw_xQueue_RTT", rtt_raw_queue);
    run_rtt("lwip_sys_sem_RTT", rtt_sys_sem);
    run_rtt("task_notify_RTT", rtt_task_notify);

    sys_sem_free(&s_bench_sem);
    vQueueDelete(s_raw_queue);
    sys_mbox_free(&s_bench_mbox);
}

/* ------------------------- 实验 B：sys_now 时基 ------------------------- */

static void exp_b_sysnow(void)
{
    printf("--- experiment B: sys_now vs esp_timer_get_time ---\n");
    printf("[clock] portTICK_PERIOD_MS=%lu  configTICK_RATE_HZ=%d\n",
           (unsigned long)portTICK_PERIOD_MS, (int)configTICK_RATE_HZ);

    enum { SAMPLES = 200 };
    static int64_t offset_ms[SAMPLES];

    int64_t sum = 0, minv = INT64_MAX, maxv = INT64_MIN;
    for (int i = 0; i < SAMPLES; i++) {
        u32_t s0 = sys_now();
        int64_t e0 = esp_timer_get_time();
        int64_t off = e0 / 1000 - (int64_t)s0;
        offset_ms[i] = off;
        sum += off;
        if (off < minv) { minv = off; }
        if (off > maxv) { maxv = off; }
        vTaskDelay(pdMS_TO_TICKS(7));
    }
    printf("[clock] offset(esp_timer_ms - sys_now), first 20:");
    for (int i = 0; i < 20 && i < SAMPLES; i++) {
        printf(" %lld", (long long)offset_ms[i]);
    }
    printf("\n[clock] offset stats over %d samples: mean=%.2f ms min=%lld ms max=%lld ms span=%lld ms\n",
           (int)SAMPLES, (double)sum / SAMPLES,
           (long long)minv, (long long)maxv, (long long)(maxv - minv));

    printf("[clock] consecutive sys_now deltas (sleep 27ms->2 ticks x12):");
    u32_t prev = sys_now();
    for (int i = 0; i < 12; i++) {
        vTaskDelay(pdMS_TO_TICKS(27));
        u32_t cur = sys_now();
        printf(" %lu", (unsigned long)(cur - prev));
        prev = cur;
    }
    printf(" (ms)  <- 只能落在 10ms tick 网格上\n");
}

/* ------------------------- 实验 C1：自建邮箱堵塞传导 ------------------------- */

#define CONG_DEPTH    32
#define CONG_POSTS    64      /* 大于深度：第 33 条起必然撞满队列 */
#define CONG_DRAIN_US 400     /* 消费者每条消息“处理耗时”（模拟 tcpip 忙） */

static sys_mbox_t s_cong_mbox;
static volatile bool s_cong_run;

static void cong_consumer_task(void *arg)
{
    (void)arg;
    void *msg;
    while (s_cong_run ||
           uxQueueMessagesWaiting((QueueHandle_t)&s_cong_mbox->os_mbox) != 0) {
        if (sys_arch_mbox_tryfetch(&s_cong_mbox, &msg) != SYS_MBOX_EMPTY) {
            esp_rom_delay_us(CONG_DRAIN_US);  /* “处理一条消息”的固定耗时 */
        } else {
            vTaskDelay(1);
        }
    }
    vTaskDelete(NULL);
}

static void exp_c1_own_mailbox(void)
{
    printf("--- experiment C1: own-mailbox congestion (depth=%d, drain=%d us) ---\n",
           CONG_DEPTH, (int)CONG_DRAIN_US);

    assert(sys_mbox_new(&s_cong_mbox, CONG_DEPTH) == ERR_OK);

    /* 相位 1 基线：空箱直投（无消费者），前 DEPTH 条应全部微秒级 */
    int64_t base_dt[CONG_DEPTH];
    for (int i = 0; i < CONG_DEPTH; i++) {
        int64_t t0 = esp_timer_get_time();
        sys_mbox_post(&s_cong_mbox, (void *)&s_cong_mbox);
        base_dt[i] = esp_timer_get_time() - t0;
    }
    report_us("post_free_slots", base_dt, CONG_DEPTH);
    void *m;
    while (sys_arch_mbox_tryfetch(&s_cong_mbox, &m) != SYS_MBOX_EMPTY) {}

    /* 相位 2：慢消费者开始排水，生产者连投 64 条并逐条计时 */
    s_cong_run = true;
    BaseType_t ok = xTaskCreatePinnedToCore(cong_consumer_task, "cong_rx", 2048,
                                            NULL, 9, NULL, 0);
    if (ok != pdPASS) {
        ESP_LOGE(TAG, "create cong_rx failed");
        sys_mbox_free(&s_cong_mbox);
        return;
    }

    static int64_t cong_dt[CONG_POSTS];
    printf("[cong ] per-post delay (idx:us):");
    for (int i = 0; i < CONG_POSTS; i++) {
        int64_t t0 = esp_timer_get_time();
        sys_mbox_post(&s_cong_mbox, (void *)&s_cong_mbox);
        cong_dt[i] = esp_timer_get_time() - t0;
        printf("%s%d:%lld", (i % 16 == 0) ? "\n[cong ]   " : " ",
               i, (long long)cong_dt[i]);
    }
    printf("\n");

    report_us("post_congested", &cong_dt[CONG_DEPTH], CONG_DEPTH);

    int blocked = 0;
    int64_t acc = 0;
    for (int i = CONG_DEPTH; i < CONG_POSTS; i++) {
        if (cong_dt[i] > 50) {
            blocked++;
            acc += cong_dt[i];
        }
    }
    printf("[cong ] posts#%d..%d blocked(>50us): %d/%d avg-blocked=%lld us\n",
           CONG_DEPTH, CONG_POSTS - 1, blocked, CONG_DEPTH,
           blocked ? (long long)(acc / blocked) : 0LL);

    s_cong_run = false;
    vTaskDelay(pdMS_TO_TICKS(200));   /* 排干尾巴再删箱 */
    sys_mbox_free(&s_cong_mbox);
}

/* ------------------------- 实验 C2：系统邮箱（tcpip mbox）压力 ------------------------- */

#define GATE_CB_US  2000     /* 每条慢回调占用 tcpip 线程的时长 */
#define GATE_CB_N   8        /* 共压入 8 条 = ~16ms 忙碌窗口 */

static volatile int s_slow_execs;

static void noop_cb(void *ctx) { (void)ctx; }
static void slow_cb(void *ctx)
{
    __atomic_add_fetch(&s_slow_execs, 1, __ATOMIC_RELAXED);
    esp_rom_delay_us((uint32_t)(uintptr_t)ctx);
}

/* 核 1 探针：与被钉死在核 0 的 tcpip 线程物理隔离后测端到端时延 */
static volatile bool s_probe_done;

static void slowphase_probe_task(void *arg)
{
    (void)arg;
    printf("[sock ] calm baseline:");
    int fd_arr[4];
    for (int i = 0; i < 4; i++) {
        int64_t t0 = esp_timer_get_time();
        fd_arr[i] = socket(AF_INET, SOCK_STREAM, IPPROTO_IP);
        printf(" %.2f", (double)(esp_timer_get_time() - t0) / 1000.0);
        close(fd_arr[i]);
    }
    printf(" ms  <- socket() create cost, idle stack\n");

    __atomic_store_n(&s_slow_execs, 0, __ATOMIC_RELAXED);
    int64_t t_posts0 = esp_timer_get_time();
    for (int i = 0; i < GATE_CB_N; i++) {
        assert(tcpip_callback(slow_cb, (void *)(uintptr_t)GATE_CB_US) == ERR_OK);
    }
    printf("[gate ] %d x %d us queued in %lld us (posting itself stays cheap)\n",
           GATE_CB_N, (int)GATE_CB_US,
           (long long)(esp_timer_get_time() - t_posts0));

    printf("[sock ] slow phase (%d x %d us queued):", GATE_CB_N, (int)GATE_CB_US);
    int64_t win0 = esp_timer_get_time();
    for (int i = 0; i < 4; i++) {
        int64_t t0 = esp_timer_get_time();
        fd_arr[i] = socket(AF_INET, SOCK_STREAM, IPPROTO_IP);
        printf(" %.2f", (double)(esp_timer_get_time() - t0) / 1000.0);
    }
    printf(" ms  window=%.2f ms <- drained through the congested stack\n",
           (double)(esp_timer_get_time() - win0) / 1000.0);
    for (int i = 0; i < 4; i++) {
        close(fd_arr[i]);
    }

    s_probe_done = true;
    vTaskDelete(NULL);
}

static TaskHandle_t find_task_by_name(const char *name)
{
    UBaseType_t n = uxTaskGetNumberOfTasks();
    TaskStatus_t *st = malloc(n * sizeof(TaskStatus_t));
    TaskHandle_t found = NULL;
    if (st == NULL) {
        return NULL;
    }
    UBaseType_t real = uxTaskGetSystemState(st, n, NULL);
    for (UBaseType_t i = 0; i < real; i++) {
        if (strcmp(st[i].pcTaskName, name) == 0) {
            found = st[i].xHandle;
            break;
        }
    }
    free(st);
    return found;
}

static void exp_c2_tcpip_mbox(void)
{
    printf("--- experiment C2: tcpip-mbox pressure ---\n");
    printf("[tcpip] config: TCPIP_MBOX_SIZE=%d slots, MEMP_NUM_TCPIP_MSG_API=%d tickets\n",
           (int)TCPIP_MBOX_SIZE, (int)MEMP_NUM_TCPIP_MSG_API);

    TaskHandle_t tcpip_task = find_task_by_name("tcpip");
    if (tcpip_task == NULL) {
        ESP_LOGE(TAG, "tcpip task not found -- skip C2");
        return;
    }

    /* 经典内核（CONFIG_FREERTOS_SMP=n）没有 vTaskCoreAffinitySet，
       改为把“测量方”抬到 tcpip(prio18) 之上并钉核 1：高优先级计时任务
       绝不会被 NO_AFFINITY 慢回调的自旋饿住——首批实验的真实教训。 */
    printf("[tcpip] tcpip thread left NO_AFFINITY(prio %lu); probe will outrun it\n",
           (unsigned long)uxTaskPriorityGet(tcpip_task));

    /* 阶段 1：挂起 tcpip 线程，持续 try-callback 直到失败 => 实测排队容量 */
    printf("[tcpip] freezing tcpip thread (vTaskSuspend %p)\n", (void *)tcpip_task);
    vTaskSuspend(tcpip_task);

    int filled = 0;
    int64_t t_fail_us = -1;
    while (filled < 256) {
        int64_t t0 = esp_timer_get_time();
        err_t err = tcpip_try_callback(noop_cb, NULL);
        if (err != ERR_OK) {
            t_fail_us = esp_timer_get_time() - t0;
            break;
        }
        filled++;
    }
    if (filled >= 256) {
        ESP_LOGE(TAG, "never hit capacity -- unexpected");
        vTaskResume(tcpip_task);
        return;
    }
    printf("[tcpip] froze->filled %d msgs until ERR_MEM; the failing try took %lld us (immediate)\n",
           filled, (long long)t_fail_us);

    /* 阶段 2：恢复消费线程，测紧随其后的阻塞式回调的“等排水”时延分布 */
    vTaskResume(tcpip_task);
    enum { PROBES = 24 };
    static int64_t pd[PROBES];
    printf("[tcpip] 24 blocking callbacks right after resume:");
    for (int i = 0; i < PROBES; i++) {
        int64_t t0 = esp_timer_get_time();
        err_t err = tcpip_callback(noop_cb, NULL);
        pd[i] = (err == ERR_OK) ? (esp_timer_get_time() - t0) : -1LL;
        printf(" %lld", (long long)pd[i]);
    }
    printf(" (us)\n");

    vTaskDelay(pdMS_TO_TICKS(50));    /* 积压排干 */

    /* 阶段 3：在核 1 起高优先级（21>tcpip18）探针跑
       “平静基线 -> 压 8 条慢回调 -> 计时创建 socket”；
       探针不阻塞时 tcpip 抢不了它 => 计时只反映真正的排队等待 */
    s_probe_done = false;
    if (xTaskCreatePinnedToCore(slowphase_probe_task, "probe14", 4096,
                                NULL, 21, NULL, 1) != pdPASS) {
        ESP_LOGE(TAG, "create probe14 failed");
        return;
    }
    while (!s_probe_done) {
        vTaskDelay(pdMS_TO_TICKS(5));
    }
    vTaskDelay(pdMS_TO_TICKS(25));   /* 慢回调消化完再读执行计数 */
    printf("[gate ] slow-callback executions observed=%d\n",
           __atomic_load_n(&s_slow_execs, __ATOMIC_RELAXED));

    vTaskDelay(pdMS_TO_TICKS(30));
}

/* ------------------------- 实验 D：任务清单快照 ------------------------- */

static const char *task_state_name(eTaskState st)
{
    switch (st) {
    case eRunning:   return "Running";
    case eReady:     return "Ready";
    case eBlocked:   return "Blocked";
    case eSuspended: return "Suspended";
    case eDeleted:   return "Deleted";
    case eInvalid:   return "Invalid";
    default:         return "?";
    }
}

static void dump_tasks(const char *when)
{
    UBaseType_t n = uxTaskGetNumberOfTasks();
    TaskStatus_t *st = malloc(n * sizeof(TaskStatus_t));
    if (st == NULL) {
        ESP_LOGE(TAG, "dump_tasks: OOM");
        return;
    }
    UBaseType_t real = uxTaskGetSystemState(st, n, NULL);
    printf("[tasks] snapshot(%s): %u tasks\n", when, (unsigned)real);
    printf("[tasks] %-12s %4s %-10s %5s\n", "NAME", "PRIO", "STATE", "HWM");
    for (UBaseType_t i = 0; i < real; i++) {
        printf("[tasks] %-12s %4lu %-10s %5u\n",
               st[i].pcTaskName,
               (unsigned long)st[i].uxCurrentPriority,
               task_state_name(st[i].eCurrentState),
               (unsigned)st[i].usStackHighWaterMark);
    }
    free(st);
}

/* ------------------------- echo server（hostfwd 8016 用） ------------------------- */

static void echo_server_task(void *arg)
{
    char rx_buf[256];
    struct sockaddr_in la = {
        .sin_family = AF_INET,
        .sin_port   = htons(ECHO_PORT),
        .sin_addr.s_addr = htonl(INADDR_ANY),
    };
    int ls = socket(AF_INET, SOCK_STREAM, IPPROTO_IP);
    assert(ls >= 0);
    int opt = 1;
    setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    assert(bind(ls, (struct sockaddr *)&la, sizeof(la)) == 0);
    assert(listen(ls, 1) == 0);
    ESP_LOGI(TAG, "echo listening :%d", ECHO_PORT);
    while (1) {
        int cs = accept(ls, NULL, NULL);
        if (cs < 0) { continue; }
        int len;
        while ((len = recv(cs, rx_buf, sizeof(rx_buf), 0)) > 0) {
            send(cs, rx_buf, len, 0);
        }
        close(cs);
    }
}

/* ------------------------- bring-up（沿用 ch3 模板） ------------------------- */

static SemaphoreHandle_t s_got_ip;
static esp_ip4_addr_t s_ip, s_nm, s_gw;

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

static void bench_task(void *arg)
{
    (void)arg;
    if (xSemaphoreTake(s_got_ip, pdMS_TO_TICKS(DHCP_TIMEOUT_MS)) != pdTRUE) {
        ESP_LOGE(TAG, "DHCP timeout -- bring-up failed");
        esp_restart();
    }
    vTaskDelay(pdMS_TO_TICKS(200));

    dump_tasks("after-bringup");
    exp_a_primitives();
    exp_b_sysnow();
    exp_c1_own_mailbox();
    exp_c2_tcpip_mbox();
    dump_tasks("after-experiments");

    printf("== ch14 lab DONE, restarting ==\n");
    vTaskDelay(pdMS_TO_TICKS(100));
    esp_restart();
}

void app_main(void)
{
    ESP_LOGI(TAG, "== ch14 lab: sys_arch calibration on openeth ==");

    ESP_ERROR_CHECK(esp_netif_init());            /* 内部经 tcpip_init 启动 tcpip 线程 */
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    s_got_ip = xSemaphoreCreateBinary();

    BaseType_t ok = xTaskCreatePinnedToCore(echo_server_task, "echo_srv", 4096, NULL, 5, NULL, 1);
    assert(ok == pdPASS);
    ok = xTaskCreatePinnedToCore(bench_task, "bench14", 8192, NULL, 10, NULL, 0);
    assert(ok == pdPASS);

    esp_netif_config_t netif_cfg = ESP_NETIF_DEFAULT_ETH();
    esp_netif_t *eth_netif = esp_netif_new(&netif_cfg);

    eth_mac_config_t mac_cfg = ETH_MAC_DEFAULT_CONFIG();   /* emac_rx 4096B prio15 */
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

    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_ETH_GOT_IP,
                                               &ip_event_handler, NULL));

    esp_eth_netif_glue_handle_t glue = esp_eth_new_netif_glue(eth_handle);
    ESP_ERROR_CHECK(esp_netif_attach(eth_netif, glue));
    ESP_ERROR_CHECK(esp_eth_start(eth_handle));
    ESP_LOGI(TAG, "waiting for DHCP lease ...");
}
