/*
 * lwIP 深度解析（二）实验：ESP-IDF 网络架构总览
 *
 * 只做四件事，不创建任何真实网口：
 *   [1] 打印 lwIP 版本（LWIP_VERSION_STRING）
 *   [2] 打印编译期关键配置（lwipopts.h 由 sdkconfig 展开的宏）
 *   [3] 按标准顺序执行 esp_event_loop_create_default() + esp_netif_init()
 *       —— 后者内部调用 tcpip_init() 启动 tcpip_thread
 *   [4] 使能 CONFIG_LWIP_STATS 后打印协议统计基线，
 *       并用一个 socket() 的建立/关闭演示"统计在什么时候开始计数"
 */
#include <stdio.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/select.h>
#include "sdkconfig.h"
#include "esp_err.h"
#include "esp_log.h"
#include "esp_event.h"
#include "esp_netif.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "lwip/init.h"
#include "lwip/opt.h"
#include "lwip/stats.h"
#include "lwip/sys.h"

static void print_macro(const char *name, long v)
{
    printf("  %-32s = %ld\n", name, v);
}

static void print_stats_baseline(const char *when)
{
    printf("-- stats baseline (%s) --\n", when);
    LINK_STATS_DISPLAY();
    ETHARP_STATS_DISPLAY();
    IP_STATS_DISPLAY();
    ICMP_STATS_DISPLAY();
    UDP_STATS_DISPLAY();
    TCP_STATS_DISPLAY();
}

void app_main(void)
{
    printf("\n=== ch02: ESP-IDF network architecture probe ===\n");

    /* ---- [1] 版本 ---- */
    printf("[1] LWIP_VERSION_STRING = %s\n", LWIP_VERSION_STRING);

    /* ---- [2] 编译期关键配置（组件/lwip/port/include/lwipopts.h 展开） ---- */
    printf("[2] compile-time configuration:\n");
    print_macro("NO_SYS", NO_SYS);                                   /* 必须为 0：走 OS 模式 */
    print_macro("LWIP_SOCKET", LWIP_SOCKET);
    print_macro("LWIP_NETCONN", LWIP_NETCONN);
    print_macro("LWIP_TCPIP_CORE_LOCKING", LWIP_TCPIP_CORE_LOCKING); /* IDF 默认 n：邮箱模型 */
    print_macro("TCPIP_MBOX_SIZE", TCPIP_MBOX_SIZE);                 /* 默认 32 */
    print_macro("LWIP_TCPIP_TASK_AFFINITY", CONFIG_LWIP_TCPIP_TASK_AFFINITY);
    print_macro("FD_SETSIZE", FD_SETSIZE);
    print_macro("CONFIG_LWIP_MAX_SOCKETS", CONFIG_LWIP_MAX_SOCKETS);
    print_macro("LWIP_SOCKET_OFFSET", LWIP_SOCKET_OFFSET);           /* 第一个 socket 的 fd 号 */
    print_macro("MEMP_NUM_TCP_PCB (MAX_ACTIVE_TCP)", MEMP_NUM_TCP_PCB);
    print_macro("TCP_SND_BUF", TCP_SND_BUF);
    print_macro("TCP_WND", TCP_WND);
    print_macro("MEM_LIBC_MALLOC", MEM_LIBC_MALLOC);                 /* IDF 用 libc 堆 */
    print_macro("MEMP_MEM_MALLOC", MEMP_MEM_MALLOC);
    print_macro("LWIP_STATS", LWIP_STATS);

    /* ---- [3] 标准启动序列 ---- */
    printf("[3] boot sequence: event loop -> esp_netif_init()\n");
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    ESP_ERROR_CHECK(esp_netif_init()); /* 内部: tcpip_init() -> tcpip_thread 就绪 */

    /* ---- [4] 协议统计基线 ---- */
    printf("[4] protocol statistics baseline:\n");
    print_stats_baseline("before any activity, no netif exists");

    /*
     * 谁真的在记账？socket 建立又关闭。
     * 注意：IDF 配置下 MEM_LIBC_MALLOC=1 且 MEMP_MEM_MALLOC=1，
     * mem/memp 两套池计数器被编译期关闭，显示宏展开为空；
     * 协议统计（LINK/IP/UDP/TCP...）只在实际收发包时开始计数，
     * 本实验不建网口，所以它们保持全 0 —— 这正是"基线"的含义。
     */
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    printf("-- after socket(): fd = %d (expect >= LWIP_SOCKET_OFFSET)\n", fd);
    if (fd >= 0) {
        close(fd);
        printf("-- after close(fd): VFS slot released back to the pool\n");
    }

    printf("=== done; no real interface created, application idles ===\n");
    fflush(stdout);

    while (true) {
        vTaskDelay(portMAX_DELAY);
    }
}
