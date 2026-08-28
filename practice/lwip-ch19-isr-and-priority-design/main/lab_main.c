/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * lwIP 深度解析（十九）实验工程：中断与优先级——ISR、任务与协议栈分工
 *
 * 单一固件覆盖四个实验，全部参数经 TCP 控制通道(:9999)由主机注入，
 * 避免反复烧写：
 *   exp A  bench   : guest 内部 127.0.0.1 回环 ping-pong，输出一次往返的
 *                    每任务 run-time 统计增量与 RTT（需要 TRACE_FACILITY +
 *                    RUN_TIME_STATS 两个 Kconfig）；
 *   exp B  prio    : 变 echo 任务优先级后，主机做开环压测取 RTT 分布；
 *   exp C  spin    : 创建高优先级自旋任务钉在 tcpip 所在核，按占空比观察劣化；
 *   exp D  rxprio  : 运行时改 emac_rx 优先级 + 压迫负载，看丢帧/延迟曲线。
 *
 * 模板来自 practice/lwip-ch03-qemu-network-lab/main/lab_main.c。
 * 运行环境：ESP-IDF v6.0.2 + qemu-system-xtensa (openeth)
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <assert.h>
#include <errno.h>
#include <stdatomic.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"

#include "esp_log.h"
#include "esp_timer.h"
#include "esp_event.h"
#include "esp_netif.h"
#include "esp_eth.h"
#include "esp_eth_mac_openeth.h"

#include "lwip/sockets.h"

static const char *TAG = "ch19lab";

#define ECHO_PORT        8888    /* 主机侧 hostfwd tcp::8022-:8888（8019/8020 已被占用） */
#define CTRL_PORT        9999    /* 主机侧 hostfwd tcp::8023-:9999 */

#ifndef APP_ECHO_PRIO
#define APP_ECHO_PRIO    5       /* 构建期默认，可用 idf.py -DCH19_APP_PRIO 覆盖 */
#endif

/* ------------------------- 全局状态 ------------------------- */

static SemaphoreHandle_t s_got_ip;
static TaskHandle_t s_echo_task;      /* echo 服务任务句柄：prio 实验目标 */
static atomic_int s_spin_run;         /* 自旋任务启停开关 */
static volatile uint32_t s_spin_sink; /* 自旋黑洞，防编译器优化掉循环 */

/* 控制通道应答走当前连接的 socket（单命令单连接模型） */
static int s_ctrl_sock = -1;

static void ctrl_reply(const char *s)
{
    if (s_ctrl_sock >= 0) {
        int n = strlen(s);
        (void)send(s_ctrl_sock, s, n, 0);
        (void)n;
    }
}

/* ------------------------- 以太网 bring-up ------------------------- */

static void eth_event_handler(void *arg, esp_event_base_t base,
                              int32_t event_id, void *event_data)
{
    switch ((int)event_id) {
    case ETHERNET_EVENT_START:        ESP_LOGI(TAG, "ETH_EVENT: START"); break;
    case ETHERNET_EVENT_CONNECTED:    ESP_LOGI(TAG, "ETH_EVENT: CONNECTED"); break;
    case ETHERNET_EVENT_DISCONNECTED: ESP_LOGI(TAG, "ETH_EVENT: DISCONNECTED"); break;
    case ETHERNET_EVENT_STOP:         ESP_LOGI(TAG, "ETH_EVENT: STOP"); break;
    }
}

static void ip_event_handler(void *arg, esp_event_base_t base,
                             int32_t event_id, void *event_data)
{
    ip_event_got_ip_t *evt = (ip_event_got_ip_t *)event_data;
    ESP_LOGI(TAG, "GOT_IP: " IPSTR, IP2STR(&evt->ip_info.ip));
    xSemaphoreGive(s_got_ip);
}

/* ------------------------- 任务表 dump（uxTaskGetSystemState）-------- */

/* 需要 Kconfig：
 *   CONFIG_FREERTOS_USE_TRACE_FACILITY=y        （uxTaskGetSystemState 本体）
 *   CONFIG_FREERTOS_GENERATE_RUN_TIME_STATS=y   （ulRunTimeCounter 有值）
 *   CONFIG_FREERTOS_VTASKLIST_INCLUDE_COREID=y  （xCoreID 字段存在） */
static void dump_task_table(const char *when)
{
    UBaseType_t n = uxTaskGetNumberOfTasks();
    TaskStatus_t *st = pvPortMalloc(n * sizeof(TaskStatus_t));
    if (!st) return;

    n = uxTaskGetSystemState(st, n, NULL);
    printf("### TASKTABLE %s n=%u\n", when, (unsigned)n);
    for (UBaseType_t i = 0; i < n; i++) {
        BaseType_t core = st[i].xCoreID;
        const char *cstr = (core == tskNO_AFFINITY) ? "NA" :
                           (core == 0 ? "0" : "1");
        printf("### T %-14s prio=%2u core=%-2s rt=%lu hwm=%lu\n",
               st[i].pcTaskName, (unsigned)st[i].uxCurrentPriority, cstr,
               (unsigned long)st[i].ulRunTimeCounter,
               (unsigned long)st[i].usStackHighWaterMark);
    }
    printf("### ENDTASKTABLE\n");
    fflush(stdout);
    vPortFree(st);
}

/* 两张任务表快照里按名字找 run-time 计数差（单位 = us，时钟源 esp_timer） */
static long diff_rt(const TaskStatus_t *a, UBaseType_t na,
                    const TaskStatus_t *b, UBaseType_t nb, const char *name)
{
    unsigned long ra = 0, rb = 0;
    for (UBaseType_t i = 0; i < na; i++)
        if (!strcmp(a[i].pcTaskName, name)) ra = (unsigned long)a[i].ulRunTimeCounter;
    for (UBaseType_t i = 0; i < nb; i++)
        if (!strcmp(b[i].pcTaskName, name)) rb = (unsigned long)b[i].ulRunTimeCounter;
    return (long)(rb - ra);
}

static TaskStatus_t *snap_tasks(UBaseType_t *cnt)
{
    UBaseType_t n = uxTaskGetNumberOfTasks();
    TaskStatus_t *st = pvPortMalloc(n * sizeof(TaskStatus_t));
    *cnt = 0;
    if (!st) return NULL;
    *cnt = uxTaskGetSystemState(st, n, NULL);
    return st;
}

/* ------------------------- 实验 A：回环 ping-pong ---------------------
 * client(prio5, core0) <-> server(prio5, core1)，走 127.0.0.1 的 lwIP 内核
 * 回环快速路径（不过 emac_rx/NIC 中断），只量 应用<->tcpip<->应用 这两跳。
 */
typedef struct {
    SemaphoreHandle_t done;
} lb_arg_t;

static void lb_server(void *arg)
{
    char buf[2048];

    int lsock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    struct sockaddr_in la = { .sin_family = AF_INET,
                              .sin_port = htons(7777),
                              .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
    int opt = 1;
    setsockopt(lsock, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    assert(bind(lsock, (struct sockaddr *)&la, sizeof(la)) == 0);
    assert(listen(lsock, 1) == 0);

    int sock = accept(lsock, NULL, NULL);
    if (sock >= 0) {
        int len;
        while ((len = recv(sock, buf, sizeof(buf), 0)) > 0)
            send(sock, buf, len, 0);
        close(sock);
    }
    close(lsock);
    vTaskDelete(NULL);
}

static void lb_client(void *arg)
{
    lb_arg_t *p = (lb_arg_t *)arg;
    static char tx[2048], rx[2048];
    const int count = 200, size = 512;
    int64_t min_rtt = INT64_MAX, max_rtt = 0, sum = 0;

    memset(tx, 'x', size);
    vTaskDelay(pdMS_TO_TICKS(50));            /* 等 server 进入 listen+accept */

    /* 测前快照 */
    UBaseType_t na; TaskStatus_t *sa = snap_tasks(&na);

    int sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    struct sockaddr_in dst = { .sin_family = AF_INET,
                               .sin_port = htons(7777),
                               .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
    assert(connect(sock, (struct sockaddr *)&dst, sizeof(dst)) == 0);

    for (int i = 0; i < count; i++) {
        int64_t t0 = esp_timer_get_time();
        send(sock, tx, size, 0);
        int off = 0;
        while (off < size) {
            int r = recv(sock, rx + off, size - off, 0);
            if (r <= 0) break;
            off += r;
        }
        int64_t dt = esp_timer_get_time() - t0;
        if (dt < min_rtt) min_rtt = dt;
        if (dt > max_rtt) max_rtt = dt;
        sum += dt;
    }
    close(sock);

    /* 测后快照 + 报数 */
    UBaseType_t nb; TaskStatus_t *sb = snap_tasks(&nb);
    printf("$$$ LOOPMETRICS count=%d size=%d avg_rtt_us=%lld min=%lld max=%lld\n",
           count, size, (long long)(sum / count),
           (long long)min_rtt, (long long)max_rtt);
    const char *names[] = { "lb_cli", "lb_srv", "tcpip", "emac_rx", "IDLE0", "IDLE1" };
    for (unsigned k = 0; k < sizeof(names) / sizeof(names[0]); k++) {
        long d = diff_rt(sa, na, sb, nb, names[k]);
        printf("$$$ LOOPTASK %s rt_delta=%ld us_per_round=%.2f\n",
               names[k], d, (double)d / (double)count);
    }
    printf("### ENDMETRICS\n");
    fflush(stdout);
    vPortFree(sa); vPortFree(sb);
    xSemaphoreGive(p->done);
    vTaskDelete(NULL);
}

static void run_loop_bench(void)
{
    static lb_arg_t arg = { NULL };
    arg.done = xSemaphoreCreateBinary();

    /* server 钉核 1、client 钉核 0，两个应用站点的切换都躲不开 tcpip 中转 */
    assert(xTaskCreatePinnedToCore(lb_server, "lb_srv", 4096, NULL, 5, NULL, 1) == pdPASS);
    assert(xTaskCreatePinnedToCore(lb_client, "lb_cli", 4096, &arg, 5, NULL, 0) == pdPASS);

    xSemaphoreTake(arg.done, pdMS_TO_TICKS(30000));
    vSemaphoreDelete(arg.done);
}

/* ------------------------- 实验 C：高优先级自旋任务 ------------------- */

static void spin_task(void *arg)
{
    int duty = (int)(intptr_t)arg;          /* 占空比 % */
    const int64_t period = 100000;          /* 100ms 周期（us） */
    while (atomic_load(&s_spin_run)) {
        int64_t spin_until = esp_timer_get_time() + period * duty / 100;
        while (esp_timer_get_time() < spin_until) {
            for (int i = 0; i < 2000; i++) s_spin_sink += i;  /* 纯自旋，无阻塞调用 */
        }
        if (duty < 100)
            vTaskDelay(pdMS_TO_TICKS((100 - duty) / 2));      /* 剩余时间让出 */
    }
    vTaskDelete(NULL);
}

/* ------------------------- TCP echo 服务（实验 B 目标） ---------------
 * 每个 accept 出来的连接交给独立 handler 任务，优先级取自运行时变量
 * s_echo_prio（prio 命令改它）。主机每轮先改优先级再开新连接，
 * 即可让"探测连接"与"背景锤子连接"以相同新优先级并行受试。 */

static volatile int s_echo_prio = APP_ECHO_PRIO;

static void echo_conn_task(void *arg)
{
    int sock = (int)(intptr_t)arg;
    char *rx_buf = pvPortMalloc(2048);
    int len;
    if (rx_buf) {
        while ((len = recv(sock, rx_buf, 2048, 0)) > 0)
            send(sock, rx_buf, len, 0);           /* 热路径零日志 */
        vPortFree(rx_buf);
    }
    close(sock);
    vTaskDelete(NULL);
}

static void echo_server_task(void *arg)
{
    (void)arg;
    struct sockaddr_in local_addr = { 0 };
    local_addr.sin_family = AF_INET;
    local_addr.sin_port = htons(ECHO_PORT);
    local_addr.sin_addr.s_addr = htonl(INADDR_ANY);

    int lsock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    assert(lsock >= 0);
    int opt = 1;
    setsockopt(lsock, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    assert(bind(lsock, (struct sockaddr *)&local_addr, sizeof(local_addr)) == 0);
    assert(listen(lsock, 8) == 0);
    s_echo_task = xTaskGetCurrentTaskHandle();
    printf("$$$ ECHOREADY accept_prio=%d port=%d\n", (int)uxTaskPriorityGet(NULL), ECHO_PORT);

    while (1) {
        int sock = accept(lsock, NULL, NULL);
        if (sock < 0) continue;
        if (xTaskCreate(echo_conn_task, "echo_hdl", 3072,
                        (void *)(intptr_t)sock,
                        (UBaseType_t)s_echo_prio, NULL) != pdPASS) {
            close(sock);
        }
    }
}

/* ------------------------- 控制通道 ----------------------------------- */

static void ctrl_exec(char *line)
{
    char word[32];
    if (sscanf(line, "%31s", word) != 1) return;

    if (!strcmp(word, "stats")) {
        dump_task_table("on-cmd");
    } else if (!strcmp(word, "prio")) {
        int p = atoi(line + 4);
        s_echo_prio = p;                       /* 新连接的 handler 用这个优先级 */
        vTaskPrioritySet(s_echo_task, (UBaseType_t)p);
        char b[96];
        snprintf(b, sizeof(b), "$$$ SET prio(echo)=%d actual=%d\n",
                 p, (int)uxTaskPriorityGet(s_echo_task));
        ctrl_reply(b);
    } else if (!strcmp(word, "rxprio") || !strcmp(word, "tcpprio")) {
        int p = atoi(line + 6);
        const char *target = !strcmp(word, "rxprio") ? "emac_rx" : "tcpip_thread";
        UBaseType_t n; TaskStatus_t *st = snap_tasks(&n);
        if (!st) { ctrl_reply("$$$ ERR mem\n"); return; }
        for (UBaseType_t i = 0; i < n; i++) {
            if (!strcmp(st[i].pcTaskName, target)) {
                vTaskPrioritySet(st[i].xHandle, (UBaseType_t)p);
                char b[96];
                snprintf(b, sizeof(b), "$$$ SET prio(%s)=%d actual=%d\n",
                         target, p, (int)uxTaskPriorityGet(st[i].xHandle));
                ctrl_reply(b);
                break;
            }
        }
        vPortFree(st);
    } else if (!strcmp(word, "spin")) {
        int core = 0, prio = 23, duty = 90;
        sscanf(line, "%*s %d %d %d", &core, &prio, &duty);
        atomic_store(&s_spin_run, 1);
        BaseType_t r = xTaskCreatePinnedToCore(spin_task, "spinner", 3072,
                                               (void *)(intptr_t)duty,
                                               (UBaseType_t)prio, NULL, (BaseType_t)core);
        char b[96];
        snprintf(b, sizeof(b), "$$$ SPIN start core=%d prio=%d duty=%d rc=%ld\n",
                 core, prio, duty, (long)r);
        ctrl_reply(b);
    } else if (!strcmp(word, "spinstop")) {
        atomic_store(&s_spin_run, 0);
        vTaskDelay(pdMS_TO_TICKS(250));
        ctrl_reply("$$$ SPIN stopped\n");
    } else if (!strcmp(word, "bench")) {
        ctrl_reply("$@@ BENCHSTART\n");
        run_loop_bench();
        ctrl_reply("$@@ BENCHDONE\n");
    } else if (!strcmp(word, "hello")) {
        ctrl_reply("$$$ ch19 ready\n");
    } else {
        ctrl_reply("$$$ ERR unknown cmd\n");
    }
}

static void ctrl_server_task(void *arg)
{
    (void)arg;
    int lsock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    struct sockaddr_in la = { 0 };
    la.sin_family = AF_INET;
    la.sin_port = htons(CTRL_PORT);
    la.sin_addr.s_addr = htonl(INADDR_ANY);
    int opt = 1;
    setsockopt(lsock, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    assert(bind(lsock, (struct sockaddr *)&la, sizeof(la)) == 0);
    assert(listen(lsock, 1) == 0);
    printf("$$$ CTRLREADY port=%d\n", CTRL_PORT);
    fflush(stdout);

    char buf[128];
    while (1) {
        int sock = accept(lsock, NULL, NULL);
        if (sock < 0) continue;
        s_ctrl_sock = sock;
        int len = recv(sock, buf, sizeof(buf) - 1, 0);   /* 一条连接一条命令 */
        if (len > 0) {
            buf[len] = '\0';
            ctrl_exec(buf);
        }
        close(sock);
        s_ctrl_sock = -1;
    }
}

/* ------------------------- app_main ---------------------------------- */

void app_main(void)
{
    ESP_LOGI(TAG, "== ch19 lab: ISR / priority / affinity ==");

    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    s_got_ip = xSemaphoreCreateBinary();

    /* echo 服务优先级来自构建参数 CH19_APP_PRIO（默认 5），钉核 0 保证矩阵稳定 */
    xTaskCreatePinnedToCore(echo_server_task, "echo_srv", 4096, NULL,
                            APP_ECHO_PRIO, NULL, 0);
    /* 控制通道钉核 1、优先级压过 esp_timer：哪怕另一核自旋风暴也接得住命令 */
    xTaskCreatePinnedToCore(ctrl_server_task, "ctrl_srv", 4096, NULL, 22, NULL, 1);

    esp_netif_config_t netif_cfg = ESP_NETIF_DEFAULT_ETH();
    esp_netif_t *eth_netif = esp_netif_new(&netif_cfg);

    eth_mac_config_t mac_cfg = ETH_MAC_DEFAULT_CONFIG();   /* rx task 4096B prio15 */
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

    if (xSemaphoreTake(s_got_ip, pdMS_TO_TICKS(15000)) != pdTRUE) {
        ESP_LOGE(TAG, "DHCP timeout");
        return;
    }

    dump_task_table("boot");
    ESP_LOGI(TAG, "READY echo:%d ctrl:%d", ECHO_PORT, CTRL_PORT);
    while (1) vTaskDelay(pdMS_TO_TICKS(60000));
}
