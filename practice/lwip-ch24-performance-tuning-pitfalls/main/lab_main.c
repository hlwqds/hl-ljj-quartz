/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * lwIP 深度解析（二十四）实验工程：性能调优与故障注入实战（收官章）
 *
 * 一个固件覆盖三个实验，全部参数经 TCP 控制通道(hostfwd 8025->:9999)注入：
 *   exp A 天花板校准：三口径测同一负载——
 *         口径1 SLIRP 外环  (host 经 hostfwd 8024 -> :8888 bulk 口)；
 *         口径2 guest 内 loopback (:7777 常驻单连接，规避 ch22 首连后 RST 怪癖)；
 *         口径3 极限配置构建 (SND_BUF/WND=65535, MSS=1460, 另行烧写镜像)。
 *   exp B 调优矩阵：固定负载逐旋钮扫描（sdkconfig.defaults 每点重建烧写），
 *         三指标 = 外环吞吐(RX/TX 各4MB) + 回环 RTT(512B×200) + 堆水位。
 *   exp C 故障注入组合拳：TX 丢帧(linkoutput wrapper, ch12 手法) + 堆紧张
 *         (malloc 到只剩 target free)，HTTP 服务(:80, hostfwd 8026)行为画像。
 *
 * 复用模板：practice/lwip-ch19-isr-and-priority-design/main/lab_main.c
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
#include "lwip/netif.h"
#include "lwip/tcpip.h"
#include "lwip/stats.h"
#include "esp_netif_net_stack.h"

static const char *TAG = "ch24lab";

#define DATA_PORT   8888   /* hostfwd tcp::8024-:8888  bulk 吞吐口径 */
#define CTRL_PORT   9999   /* hostfwd tcp::8025-:9999  控制通道      */
#define HTTP_PORT     80   /* hostfwd tcp::8026-:80    HTTP 服务     */
#define LB_PORT     7777   /* guest 内部 loopback 测试对             */

/* ------------------------- 全局状态 ------------------------- */

static SemaphoreHandle_t s_got_ip;
static esp_netif_t *s_eth_netif;

/* 控制通道应答走当前连接的 socket（单命令单连接模型，同 ch19） */
static int s_ctrl_sock = -1;
static void ctrl_reply(const char *s)
{
    if (s_ctrl_sock >= 0) {
        size_t n = strlen(s);
        (void)send(s_ctrl_sock, s, n, 0);
    }
}

/* ------------------------- 任务表快照（同 ch19）------------------------- */

static TaskStatus_t *snap_tasks(UBaseType_t *cnt)
{
    UBaseType_t n = uxTaskGetNumberOfTasks();
    TaskStatus_t *st = pvPortMalloc(n * sizeof(TaskStatus_t));
    *cnt = 0;
    if (!st) return NULL;
    *cnt = uxTaskGetSystemState(st, n, NULL);
    return st;
}

static void dump_task_table(const char *when)
{
    UBaseType_t n = uxTaskGetNumberOfTasks();
    TaskStatus_t *st = pvPortMalloc(n * sizeof(TaskStatus_t));
    if (!st) return;
    n = uxTaskGetSystemState(st, n, NULL);
    printf("### TASKTABLE %s n=%u\n", when, (unsigned)n);
    for (UBaseType_t i = 0; i < n; i++) {
        BaseType_t core = st[i].xCoreID;
        const char *cstr = (core == tskNO_AFFINITY) ? "NA" : (core == 0 ? "0" : "1");
        printf("### T %-14s prio=%2u core=%-2s rt=%lu hwm=%lu\n",
               st[i].pcTaskName, (unsigned)st[i].uxCurrentPriority, cstr,
               (unsigned long)st[i].ulRunTimeCounter,
               (unsigned long)st[i].usStackHighWaterMark);
    }
    printf("### ENDTASKTABLE\n");
    fflush(stdout);
    vPortFree(st);
}

/* ------------------------- 内存账本 ------------------------- */

static void print_mem(const char *when)
{
    uint32_t free8   = heap_caps_get_free_size(MALLOC_CAP_8BIT);
    uint32_t large8  = heap_caps_get_largest_free_block(MALLOC_CAP_8BIT);
    uint32_t minever = heap_caps_get_minimum_free_size(MALLOC_CAP_8BIT);
    printf("$$$ MEM %s free=%u largest=%u min_ever=%u\n", when,
           (unsigned)free8, (unsigned)large8, (unsigned)minever);
    fflush(stdout);
}

#if LWIP_STATS
static void print_lwstats(const char *when)
{
    printf("$$$ LWSTATS %s link.recv=%u link.xmit=%u link.drop=%u tcp.memerr=%u "
#if MIB2_STATS
           "tcp.retranssegs=%u "
#endif
           "tcp.err=%u tcp.drop=%u\n",
           when,
           (unsigned)lwip_stats.link.recv,  (unsigned)lwip_stats.link.xmit,
           (unsigned)lwip_stats.link.drop,
#if MIB2_STATS
           (unsigned)lwip_stats.mib2.tcpretranssegs,
#endif
           (unsigned)lwip_stats.tcp.memerr,
           (unsigned)lwip_stats.tcp.err,    (unsigned)lwip_stats.tcp.drop);
    fflush(stdout);
}
#else
static void print_lwstats(const char *when)
{ printf("$$$ LWSTATS %s disabled(LWIP_STATS=n)\n", when); fflush(stdout); }
#endif

/* ------------------------- 故障注入 1：TX 丢帧（ch12 手法）-------------- */

static err_t (*s_orig_linkoutput)(struct netif *, struct pbuf *);
static uint32_t s_rng = 0x24a7c001;              /* 固定种子可复现 */
static atomic_uint s_drop_total;
static volatile int s_drop_enable = 0;
static volatile int s_drop_pct_now = 0;

static uint32_t rng_next(void)
{
    uint32_t x = s_rng;
    x ^= x << 13; x ^= x >> 17; x ^= x << 5;
    s_rng = x;
    return x;
}

static err_t dropping_linkoutput(struct netif *netif, struct pbuf *p)
{
    if (s_drop_enable && (int)(rng_next() % 100u) < s_drop_pct_now) {
        unsigned t = atomic_fetch_add(&s_drop_total, 1) + 1;
        printf("### DROP seq=%u pct=%d len=%d\n", t, s_drop_pct_now, (int)p->tot_len);
        return ERR_OK;                            /* 静默吞掉，等上层超时 */
    }
    return s_orig_linkoutput(netif, p);
}

/* 在 tcpip_thread 内执行：换 netif->linkoutput 指针才无竞态 */
static void install_dropper_in_tcpip(void *arg)
{
    (void)arg;
    if (s_orig_linkoutput != NULL) return;
    struct netif *n = (struct netif *)esp_netif_get_netif_impl(s_eth_netif);
    assert(n != NULL && n->linkoutput != NULL);
    s_orig_linkoutput = n->linkoutput;
    n->linkoutput = dropping_linkoutput;
}

/* ------------------------- 故障注入 2：堆紧张 --------------------------- */

#define MAX_STRESS_BLOCKS 16
static void *s_stress[MAX_STRESS_BLOCKS];

static void heap_stress_off(void);

/* 持续分配直到剩余堆 <= free_kb；返回实际压掉的 KB */
static long heap_stress_on(int free_kb)
{
    heap_stress_off();
    long eaten_kb = 0;
    size_t chunk = 32768;
    for (int i = 0; i < MAX_STRESS_BLOCKS && chunk >= 256;) {
        size_t remain = heap_caps_get_free_size(MALLOC_CAP_8BIT);
        if ((long)(remain / 1024) <= free_kb + (long)(chunk / 1024)) {
            chunk /= 2;                            /* 快到线了减半逼近 */
            continue;
        }
        void *b = malloc(chunk);
        if (!b) { chunk /= 2; continue; }
        memset(b, 'S', chunk);                     /* 真实占住物理页 */
        s_stress[i++] = b;
        eaten_kb += chunk / 1024;
    }
    return eaten_kb;
}

static void heap_stress_off(void)
{
    for (int i = 0; i < MAX_STRESS_BLOCKS; i++) {
        if (s_stress[i]) { free(s_stress[i]); s_stress[i] = NULL; }
    }
}

/* ------------------------- 实验 A/B 共用：bulk 数据面 -------------------- *
 * sinkmode=rx  （默认）：客户端灌入，服务器只 recv 计数；
 *               收到 EOF 后回一个字节 'K' 让主机端确定完成时刻。
 * sinkmode=tx ：accept 后服务器持续 send() 直到发完 pump_bytes 再关连接。
 */
typedef enum { SINK_RX = 0, SINK_TX } sink_mode_t;
static volatile sink_mode_t s_sink_mode = SINK_RX;
static volatile uint32_t s_pump_bytes = 4u * 1000 * 1000;
static SemaphoreHandle_t s_data_done;              /* 连接串行化闸门 */

static void data_conn_task(void *arg)
{
    int sock = (int)(intptr_t)arg;
    static char buf[16384];                        /* 共享静态缓冲：串行闸门保证互斥 */
    uint64_t total = 0;
    /* 接收超时：邮箱丢包（Batch3 事实）或 FIN 丢失时避免永久卡死 */
    struct timeval tvo = { .tv_sec = 8, .tv_usec = 0 };
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tvo, sizeof(tvo));

    if (s_sink_mode == SINK_RX) {
        int len;
        while ((len = recv(sock, buf, sizeof(buf), 0)) > 0) total += len;
        char ack = 'K';
        (void)send(sock, &ack, 1, 0);              /* EOF 应答位 */
        printf("$$$ RXDONE bytes=%llu\n", (unsigned long long)total);
        fflush(stdout);
    } else {                                       /* SINK_TX */
        memset(buf, 'T', sizeof(buf));
        unsigned long left = s_pump_bytes;
        while (left > 0) {
            size_t once = left > sizeof(buf) ? sizeof(buf) : left;
            int w = send(sock, buf, once, 0);      /* 阻塞写，靠对端 ACK 前进 */
            if (w <= 0) break;
            left -= w;
            total += w;
        }
        shutdown(sock, SHUT_WR);
        printf("$$$ TXPUMP done want=%lu got=%llu\n",
               s_pump_bytes, (unsigned long long)total);
        fflush(stdout);
    }
    close(sock);
    xSemaphoreGive(s_data_done);                   /* 允许下一条连接进入 */
    vTaskDelete(NULL);
}

static void data_server_task(void *arg)
{
    (void)arg;
    int lsock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    assert(lsock >= 0);
    int opt = 1;
    setsockopt(lsock, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    struct sockaddr_in la = { .sin_family = AF_INET,
                              .sin_port = htons(DATA_PORT),
                              .sin_addr.s_addr = htonl(INADDR_ANY) };
    assert(bind(lsock, (struct sockaddr *)&la, sizeof(la)) == 0);
    assert(listen(lsock, 4) == 0);
    printf("$$$ DATAREADY port=%d mode=%s\n", DATA_PORT,
           s_sink_mode == SINK_RX ? "rx" : "tx");
    fflush(stdout);
    s_data_done = xSemaphoreCreateBinary();
    xSemaphoreGive(s_data_done);
    while (1) {
        int sock = accept(lsock, NULL, NULL);
        if (sock < 0) continue;
        if (xSemaphoreTake(s_data_done, pdMS_TO_TICKS(30000)) != pdTRUE) {
            close(sock);                           /* 上一条连接未收尾，拒新 */
            continue;
        }
        if (xTaskCreate(data_conn_task, "data_hdl", 3072,
                        (void *)(intptr_t)sock, 5, NULL) != pdPASS) {
            close(sock);
            xSemaphoreGive(s_data_done);
        }
    }
}

/* ------------------------- 实验 A 口径2：loopback 测试对 ----------------- *
 * 采用 ch19 验证过的形状：一对任务同时创建（srv 钉核1 prio5、cli 钉核0），
 * 一条连接、无帧头协议——server 对收到的每个 chunk 立即原样回显；client 单
 * 在途帧推进。mode=rtt 测 ping-pong RTT；mode=th 客户端连灌 bytes 后半关，
 * server drain 至目标字节数后关闭，client 以 EOF 判定计时终点。
 * 每次调用新建连接对：这会踩到 ch22 记录的"guest 内 loopback 第二条连接
 * 全 RST"怪癖的作用域问题，实测见正文。
 */
static SemaphoreHandle_t s_lb_done;
static volatile int s_lb_mode;          /* 0=rtt 1=th */
static volatile uint32_t s_lb_count, s_lb_size;

static void lb_server_task(void *arg)
{
    (void)arg;
    static char buf[16384];
    int lsock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    assert(lsock >= 0);
    int opt = 1;
    setsockopt(lsock, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    struct sockaddr_in la = { .sin_family = AF_INET,
                              .sin_port = htons(LB_PORT),
                              .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
    assert(bind(lsock, (struct sockaddr *)&la, sizeof(la)) == 0);
    assert(listen(lsock, 1) == 0);
    int sock = accept(lsock, NULL, NULL);
    if (sock < 0) { close(lsock); vTaskDelete(NULL); }

    if (s_lb_mode == 0) {                                  /* RTT echo 泵 */
        int len;
        while ((len = recv(sock, buf, sizeof(buf), 0)) > 0) {
            int off = 0;
            while (off < len) {
                int w = send(sock, buf + off, len - off, 0);
                if (w < 0) goto out;
                off += w;
            }
        }
    } else {                                               /* TH drain 泵 */
        uint64_t target = s_lb_size, total = 0;
        int len;
        while ((len = recv(sock, buf, sizeof(buf), 0)) > 0) {
            total += len;
            if ((uint64_t)total >= target) break;
        }
        printf("$$$ LBTHR drained=%llu\n", (unsigned long long)total);
    }
out:
    close(sock);
    close(lsock);
    vTaskDelete(NULL);
}

static void lb_client_task(void *arg)
{
    (void)arg;
    static char payload[16384];
    memset(payload, 'X', sizeof(payload));

    /* ch19 形状：client 等 server 进 accept 后一次性建连 */
    vTaskDelay(pdMS_TO_TICKS(80));
    int sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    struct sockaddr_in dst = { .sin_family = AF_INET,
                               .sin_port = htons(LB_PORT),
                               .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
    if (connect(sock, (struct sockaddr *)&dst, sizeof(dst)) != 0) {
        printf("$$$ LBFAIL connect errno=%d\n", errno);
        fflush(stdout);
        xSemaphoreGive(s_lb_done);
        vTaskDelete(NULL);
    }

    if (s_lb_mode == 0) {
        uint32_t count = s_lb_count, size = s_lb_size;
        int64_t sum = 0, mn = INT64_MAX, mx = 0;
        uint32_t okr = 0;
        for (uint32_t i = 0; i < count; i++) {
            int64_t t0 = esp_timer_get_time();
            int w = send(sock, payload, size, 0);
            if (w <= 0) break;
            int off = 0;
            while (off < (int)size) {
                int r = recv(sock, payload + off, size - off, 0);
                if (r <= 0) goto report;
                off += r;
            }
            {   int64_t dt = esp_timer_get_time() - t0;
                sum += dt; if (dt < mn) mn = dt; if (dt > mx) mx = dt;
                okr++;
            }
        }
report:
        printf("$$$ LBRTT ok=%lu/%u size=%u avg_rtt_us=%lld min=%lld max=%lld\n",
               (unsigned long)okr, (unsigned)count, (unsigned)size,
               (long long)(okr ? sum / okr : 0), (long long)mn, (long long)mx);
    } else {
        uint32_t size = s_lb_size;
        uint64_t sent = 0;
        int64_t t0 = esp_timer_get_time();
        while (sent < size) {
            size_t once = size - sent > sizeof(payload) ? sizeof(payload) : size - sent;
            int w = send(sock, payload, once, 0);
            if (w <= 0) break;
            sent += w;
        }
        shutdown(sock, SHUT_WR);                    /* 让 server 触达 drain 目标 */
        char eof = 0;
        int r = recv(sock, &eof, 1, 0);             /* server 达标后 close → EOF */
        int64_t dt = esp_timer_get_time() - t0;
        printf("$$$ LBTH ack_r=%d bytes=%lu elapsed_us=%lld mbit=%.2f\n",
               r, (unsigned long)sent, (long long)dt,
               dt > 0 ? (double)sent * 8.0 / dt : 0.0);
    }
    close(sock);
    fflush(stdout);
    xSemaphoreGive(s_lb_done);
    vTaskDelete(NULL);
}

static void run_lb_bench(int mode, uint32_t a, uint32_t b)
{
    static SemaphoreHandle_t s_local;
    if (s_local == NULL) s_local = xSemaphoreCreateBinary();
    else xSemaphoreTake(s_local, 0);
    s_lb_mode = mode;
    s_lb_count = mode == 0 ? a : 1;
    s_lb_size  = mode == 0 ? b : a;
    s_lb_done = s_local;

    TaskHandle_t srvh = NULL, clih = NULL;
    if (xTaskCreatePinnedToCore(lb_server_task, "lb_srv", 4096, NULL, 5, &srvh, 1)
        != pdPASS)
        return;
    if (xTaskCreatePinnedToCore(lb_client_task, "lb_cli", 4096, NULL, 21, &clih, 0)
        != pdPASS) {
        if (srvh) vTaskDelete(srvh);
        return;
    }
    xSemaphoreTake(s_lb_done, pdMS_TO_TICKS(120000));      /* client 汇报完成 */
}

/* ------------------------- 实验 C 目标：最小 HTTP 服务 ------------------- */

static const char RESP_200[] =
    "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 22\r\n"
    "\r\nch24 fault-injection ok";

static void http_conn_task(void *arg)
{
    int sock = (int)(intptr_t)arg;
    char req[512];
    int off = 0, len;
    /* 读到请求头结束（\r\n\r\n）或缓冲满为止 */
    while (off < (int)sizeof(req) - 1) {
        len = recv(sock, req + off, sizeof(req) - 1 - off, 0);
        if (len <= 0) goto out;
        off += len;
        req[off] = '\0';
        if (strstr(req, "\r\n\r\n")) break;
    }
    (void)send(sock, RESP_200, sizeof(RESP_200) - 1, 0);
    shutdown(sock, SHUT_WR);
    /* 吃掉残余再关闭，避免 RST 打断应答投递 */
    do { len = recv(sock, req, sizeof(req), 0); } while (len > 0);
out:
    close(sock);
    vTaskDelete(NULL);
}

static void http_server_task(void *arg)
{
    (void)arg;
    int lsock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    assert(lsock >= 0);
    int opt = 1;
    setsockopt(lsock, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    struct sockaddr_in la = { .sin_family = AF_INET,
                              .sin_port = htons(HTTP_PORT),
                              .sin_addr.s_addr = htonl(INADDR_ANY) };
    assert(bind(lsock, (struct sockaddr *)&la, sizeof(la)) == 0);
    assert(listen(lsock, 4) == 0);
    printf("$$$ HTTPREADY port=%d\n", HTTP_PORT);
    fflush(stdout);
    while (1) {
        int sock = accept(lsock, NULL, NULL);
        if (sock < 0) continue;
        if (xTaskCreate(http_conn_task, "http_hdl", 3072,
                        (void *)(intptr_t)sock, 5, NULL) != pdPASS)
            close(sock);
    }
}

/* ------------------------- 控制通道 -------------------------------------- */

static void ctrl_exec(char *line)
{
    char word[24];
    if (sscanf(line, "%23s", word) != 1) return;

    if (!strcmp(word, "hello")) {
        ctrl_reply("$$$ ch24 ready\n");
    } else if (!strcmp(word, "mem")) {
        print_mem("on-cmd"); print_lwstats("on-cmd");
    } else if (!strcmp(word, "tasks")) {
        dump_task_table("on-cmd");
    } else if (!strcmp(word, "sinkmode")) {
        char m[8];
        sscanf(line, "%*s %7s", m);
        if (!strcmp(m, "tx"))  { s_sink_mode = SINK_TX; ctrl_reply("$$$ SET sinkmode=tx\n"); }
        else                   { s_sink_mode = SINK_RX; ctrl_reply("$$$ SET sinkmode=rx\n"); }
    } else if (!strcmp(word, "pumpmb")) {
        s_pump_bytes = strtoul(line + 7, NULL, 10) * 1000000u;
        ctrl_reply("$$$ SET pump\n");
    } else if (!strcmp(word, "loss")) {
        int p = atoi(line + 5);
        tcpip_callback(install_dropper_in_tcpip, NULL);   /* 幂等安装 */
        s_drop_pct_now = p;
        s_drop_enable = (p > 0);
        char b[64];
        snprintf(b, sizeof(b), "$$$ SET loss=%d installed=%d\n",
                 p, s_orig_linkoutput != NULL);
        ctrl_reply(b);
    } else if (!strcmp(word, "heap")) {
        char a[12];
        sscanf(line, "%*s %11s", a);
        if (!strcmp(a, "off")) {
            heap_stress_off();
            ctrl_reply("$$$ HEAP stress removed\n");
            print_mem("after-off");
        } else {
            int kb = atoi(a);
            long e = heap_stress_on(kb);
            char b[96];
            snprintf(b, sizeof(b), "$$$ HEAP stress eat_kb=%ld now_free=%u\n",
                     e, (unsigned)heap_caps_get_free_size(MALLOC_CAP_8BIT));
            ctrl_reply(b);
            print_mem("under-stress");
        }
    } else if (!strcmp(word, "rtt")) {
        /* rtt <count> <size>：新建 loopback 对做 ping-pong，结果走串口 */
        uint32_t c = 200, s = 512;
        sscanf(line, "%*s %lu %lu", (unsigned long *)&c, (unsigned long *)&s);
        ctrl_reply("$$$ LBRUN start\n");
        run_lb_bench(0, c, s);
    } else if (!strcmp(word, "th")) {
        /* th <bytes>：新建 loopback 对做单向批量，结果走串口 */
        uint32_t n = 4000000;
        sscanf(line, "%*s %lu", (unsigned long *)&n);
        if (n < 65536) n = 4000000;
        ctrl_reply("$$$ LBRUN start\n");
        run_lb_bench(1, n, 0);
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

    char buf[96];
    while (1) {
        int sock = accept(lsock, NULL, NULL);
        if (sock < 0) continue;
        s_ctrl_sock = sock;
        int len = recv(sock, buf, sizeof(buf) - 1, 0);
        if (len > 0) { buf[len] = '\0'; ctrl_exec(buf); }
        close(sock);
        s_ctrl_sock = -1;
    }
}

/* ------------------------- app_main -------------------------------------- */

static void eth_event_handler(void *arg, esp_event_base_t base,
                              int32_t event_id, void *event_data)
{
    switch ((int)event_id) {
    case ETHERNET_EVENT_START:        ESP_LOGI(TAG, "ETH START"); break;
    case ETHERNET_EVENT_CONNECTED:    ESP_LOGI(TAG, "ETH CONNECTED"); break;
    case ETHERNET_EVENT_DISCONNECTED: ESP_LOGI(TAG, "ETH DISCONNECTED"); break;
    case ETHERNET_EVENT_STOP:         ESP_LOGI(TAG, "ETH STOP"); break;
    }
}

static void ip_event_handler(void *arg, esp_event_base_t base,
                             int32_t event_id, void *event_data)
{
    ip_event_got_ip_t *evt = (ip_event_got_ip_t *)event_data;
    ESP_LOGI(TAG, "GOT_IP: " IPSTR, IP2STR(&evt->ip_info.ip));
    xSemaphoreGive(s_got_ip);
}

/* 心跳观测位：每 10s 报告存活与堆水位，用于给"冻结"定位起始时刻 */
static void heart_task(void *arg)
{
    (void)arg;
    for (;;) {
        vTaskDelay(pdMS_TO_TICKS(10000));
        printf("### HEART t=%lld s free=%u\n",
               (long long)(esp_timer_get_time() / 1000000),
               (unsigned)heap_caps_get_free_size(MALLOC_CAP_8BIT));
        fflush(stdout);
    }
}

void app_main(void)
{
    ESP_LOGI(TAG, "== ch24 lab: performance tuning / fault injection ==");

    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    s_got_ip = xSemaphoreCreateBinary();

    xTaskCreatePinnedToCore(data_server_task, "data_srv", 4096, NULL, 5, NULL, 0);
    xTaskCreatePinnedToCore(http_server_task, "http_srv", 4096, NULL, 5, NULL, 0);
    /* 控制平面必须活在受害者带宽之外（ch19 教训）：core1 高优先级 */
    xTaskCreatePinnedToCore(ctrl_server_task, "ctrl_srv", 4096, NULL, 22, NULL, 1);

    esp_netif_config_t netif_cfg = ESP_NETIF_DEFAULT_ETH();
    s_eth_netif = esp_netif_new(&netif_cfg);

    eth_mac_config_t mac_cfg = ETH_MAC_DEFAULT_CONFIG();  /* rx task 4096B prio15 */
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
    ESP_ERROR_CHECK(esp_netif_attach(s_eth_netif, glue));
    ESP_ERROR_CHECK(esp_eth_start(eth_handle));

    if (xSemaphoreTake(s_got_ip, pdMS_TO_TICKS(15000)) != pdTRUE) {
        ESP_LOGE(TAG, "DHCP timeout");
        return;
    }

    xTaskCreatePinnedToCore(heart_task, "heart", 2048, NULL, 3, NULL, 0);
    dump_task_table("boot");
    print_mem("boot");
    printf("$$$ BUILD %s sndbuf=%d wnd=%d mss=%d tcpip_mbox=%d pbuf_pool=%d\n", __TIME__,
           (int)TCP_SND_BUF, (int)TCP_WND, (int)TCP_MSS,
           (int)TCPIP_MBOX_SIZE, (int)PBUF_POOL_SIZE);
    fflush(stdout);
    while (1) vTaskDelay(pdMS_TO_TICKS(60000));
}
