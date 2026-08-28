/*
 * SPDX-FileCopyrightText: 2026 lwIP deep-dive series
 * SPDX-License-Identifier: CC0-1.0
 *
 * lwIP 深度解析（一）实验：在无任何网络接口的情况下，把协议栈核心跑起来，
 * 量它的静态体积（idf.py size）与启动期动态开销（堆差值 + 任务清单 + 统计账本）。
 */
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include "sdkconfig.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_heap_caps.h"
#include "esp_system.h"
#include "lwip/tcpip.h"
#include "lwip/stats.h"
#include "lwip/pbuf.h"
#include "lwip/tcp.h"
#include "lwip/udp.h"
#include "lwip/api.h"
#include "lwip/sockets.h"
#include "lwip/dns.h"
#include <netdb.h>

static unsigned dram_free(void)
{
    /* 内部 8bit 可用 DRAM：排除 PSRAM，反映片上 SRAM 的真实水位 */
    return (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT);
}

/* 并发探测：UDP 先建并保持打开，再建一个 TCP。
 * 在 MAX_SOCKETS/MAX_UDP_PCBS 等上限被压到 1 的最小化配置下，
 * 第二个 socket 会撞上容量上限——这是裁剪语义的第一手证据。 */
static void concurrency_probe(void)
{
    unsigned before = dram_free();
    int u = (int)lwip_socket(AF_INET, SOCK_DGRAM, 0);
    unsigned after_udp = dram_free();
    int c = (int)lwip_socket(AF_INET, SOCK_STREAM, 0);
    unsigned after_tcp = dram_free();

    printf("concurrency: udp_fd=%d tcp_fd=%d\n", u, c);
    if (c < 0) {
        printf("             tcp errno=%d (%s)\n", errno, strerror(errno));
    }
    printf("heap: udp hold=%dB, +tcp hold=%dB\n",
           (int)(before - after_udp),
           (int)(after_udp - after_tcp));

    if (c >= 0) { lwip_close(c); }
    if (u >= 0) { lwip_close(u); }
    vTaskDelay(pdMS_TO_TICKS(50));   /* 等 tcpip 线程异步回收 netconn */
}

#if configUSE_TRACE_FACILITY
static void list_tasks(void)
{
    UBaseType_t n = uxTaskGetNumberOfTasks();
    TaskStatus_t *st = pvPortMalloc(n * sizeof(TaskStatus_t));
    if (st == NULL) {
        printf("task snapshot: alloc failed\n");
        return;
    }
    n = uxTaskGetSystemState(st, n, NULL);
    printf("-- task inventory (%u tasks) --\n", (unsigned)n);
    unsigned tcpip_hwm = 0;
    for (UBaseType_t i = 0; i < n; i++) {
        printf("task %-14s prio %2u stack-hwm %6u\n",
               st[i].pcTaskName,
               (unsigned)st[i].uxCurrentPriority,
               (unsigned)st[i].usStackHighWaterMark);
        if (strcmp(st[i].pcTaskName, TCPIP_THREAD_NAME) == 0) {
            tcpip_hwm = (unsigned)st[i].usStackHighWaterMark;
        }
    }
    printf("tcpip thread '%s' stack high-water mark: %u bytes\n",
           TCPIP_THREAD_NAME, tcpip_hwm);
    vPortFree(st);
}
#else
static void list_tasks(void)
{
    /* CONFIG_FREERTOS_USE_TRACE_FACILITY 未开时无法枚举任务，跳过 */
}
#endif

void app_main(void)
{
    printf("== ch01 probe: bare protocol-stack core, no netif ==\n");
    printf("sizeof: pbuf=%u tcp_pcb=%u udp_pcb=%u netconn=%u\n",
           (unsigned)sizeof(struct pbuf),
           (unsigned)sizeof(struct tcp_pcb),
           (unsigned)sizeof(struct udp_pcb),
           (unsigned)sizeof(struct netconn));

    printf("DRAM free before tcpip_init: %u\n", dram_free());

    /* 只拉起协议栈核心：一个 FreeRTOS 线程（tcpip_thread）+ 一个邮箱。
     * 还没有任何 netif/套接字。 */
    tcpip_init(NULL, NULL);
    vTaskDelay(pdMS_TO_TICKS(200));

    printf("DRAM free after  tcpip_init: %u\n", dram_free());
    list_tasks();

    /* 链接与用量探测：并发建两个 socket，保证 socket/netconn/TCP/UDP/DNS
     * 路径都在最终镜像里，同时量出每个连接的最小堆开销与容量上限语义。 */
    concurrency_probe();

#if LWIP_DNS
    {
        struct hostent *he = lwip_gethostbyname("localhost");
        printf("dns localhost -> %p\n", (void *)he);
    }
#endif

#if LWIP_STATS
    /* 打印各协议层的 avail/used/max/err 账本（IDF 配置下无 MEM/MEMP 段：
       动态内存全部走 ESP-IDF 堆，见正文） */
    stats_display();
#endif

    printf("probe done, restarting\n");
    fflush(stdout);
    esp_restart();
}
