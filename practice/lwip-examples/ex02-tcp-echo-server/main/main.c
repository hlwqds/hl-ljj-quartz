/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * lwIP 示例套件 ex02：TCP Echo Server（socket 单任务 accept 循环模型）
 *
 * 拓扑（QEMU SLIRP）：
 *   宿主机 nc/bench --tcp:8210--> [SLIRP hostfwd] --> guest 10.0.2.15:8210 --> 本服务
 *
 * 本工程演示"一个任务包打天下"的最小 TCP 服务端模板：
 *   listen -> 串行 accept -> 对每条连接阻塞 recv 后原样回写 -> close -> 下一条。
 *
 * 从系列实验沉淀的三条硬教训，全部固化在代码结构里：
 *
 * [ch15 livelock 教训] raw recv 回调里 busy-wait 200ms 曾把第二连接吞吐从
 *   103 Mbit 打到 0.06 Mbit——协议栈上下文绝不能被应用等待拖住。本模板的
 *   对应纪律：echo 循环只做"recv 阻塞等数据 -> 立即回写"两件事，
 *   不在回写与下一次 recv 之间插入任何 sleep/忙等/大计算；
 *   统计打印由独立的低频任务完成，不掺进数据面循环。
 *
 * [ch23 结论 a] 单任务串行 accept 的死法：前一条连接不解开，
 *   accept() 就永远回不来，后续连接全部堵在 backlog 里；若业务
 *   在收到数据前就停摆（先 write 后 read、或等一个不会来的事件），
 *   连接会变成互等的黑洞。对应纪律：per-connection 严格
 *   "先 recv 后回写"（数据驱动推进），对端 FIN/错误立即退出并 close。
 *
 * [ch23 结论 b] listen() 的 backlog 必须显式设足：backlog(2) 时第二条
 *   排队连接就可能吃满队列，SYN 被 lwIP 静默吞掉（SYNMAXRTX=4 五发空转后
 *   客户端报 errno=113）。对应纪律：BACKLOG 显式定义、给出注释依据，
 *   并受 CONFIG_LWIP_MAX_ACTIVE_TCP(默认16) 约束，模板取 8 留余量。
 *
 * 运行环境：ESP-IDF v6.0.2 + qemu-system-xtensa (Espressif fork)
 *           -nic user,model=open_eth,hostfwd=tcp::8210-:8210
 */

#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>

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

#define TAG "ex02"

/* ---- 服务参数 ---- */
#define ECHO_PORT       8210 /* SPEC §4 端口表 ex02 号段 8210/8211，hostfwd 两端同号 */
#define LISTEN_BACKLOG  8    /* ch23 结论 b：显式设足。lwIP 里 backlog 是“已完成
                              * 三次握手但还没被 accept 的连接”上限；超限的 SYN 被
                              * tcp_listen_with_backlog_and_err 静默丢弃（不发 RST），
                              * 客户端表现为 connect 五发 SYN 重试后 errno=113。
                              * 取 8 < CONFIG_LWIP_MAX_ACTIVE_TCP(16) 默认上限。 */
#define RX_BUF_SIZE     1024 /* 单次 recv 上限；回写按实际 len 原样返还 */
#define DHCP_TIMEOUT_MS 15000
#define STATS_PERIOD_S  10   /* 周期统计打印间隔 */

/* ---- 应用层连接计数器（只由 echo 任务写、stats 任务读，
 *      字宽读写原子，模板级统计无需加锁）---- */
static volatile unsigned s_conn_total;   /* 累计 accept 成功的连接数 */
static volatile unsigned s_conn_active;  /* 当前正在服务的连接数（串行模型 ≤1，
                                            backlog 中尚未 accept 的连接在此不可见）*/
static volatile uint64_t s_bytes_echoed; /* 累计回写字节数 */

static SemaphoreHandle_t s_got_ip;
static esp_ip4_addr_t s_ip, s_nm, s_gw;

/* ------------------------- 以太网事件处理（沿用 ch03 模板） ------------------------- */

static void eth_event_handler(void *arg, esp_event_base_t base,
                              int32_t event_id, void *event_data)
{
    switch (event_id) {
    case ETHERNET_EVENT_START:
        ESP_LOGI(TAG, "ETH_EVENT: START");
        break;
    case ETHERNET_EVENT_STOP:
        ESP_LOGI(TAG, "ETH_EVENT: STOP");
        break;
    case ETHERNET_EVENT_CONNECTED:
        ESP_LOGI(TAG, "ETH_EVENT: CONNECTED (link up)");
        break;
    case ETHERNET_EVENT_DISCONNECTED:
        ESP_LOGI(TAG, "ETH_EVENT: DISCONNECTED (link down)");
        break;
    default:
        ESP_LOGI(TAG, "ETH_EVENT: id=%ld", (long)event_id);
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

/* ------------------------- echo 数据面 ------------------------- */

/* 回写必须凑齐：短写（SOCK_SNDBUF 满时 send 只收下一部分）对 echo 语义是丢数据 */
static int send_all(int sock, const char *buf, size_t len)
{
    size_t off = 0;
    while (off < len) {
        int n = send(sock, buf + off, len - off, 0);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            ESP_LOGE(TAG, "send failed errno=%d", errno);
            return -1;
        }
        off += (size_t)n;
    }
    return 0;
}

/*
 * 单条连接的生命周期：循环“recv -> 原样 send”，直到对端 FIN(len==0) 或出错。
 * 这是全工程唯一的数据面函数，除回写外不做任何耗时动作（见文件头 ch15 教训）。
 */
static void serve_connection(int sock, const struct sockaddr_in *peer, unsigned conn_idx)
{
    char rx[RX_BUF_SIZE];
    unsigned msgs = 0;
    uint64_t bytes = 0;
    int64_t t0 = esp_timer_get_time(); /* 亚毫秒计时用 esp_timer，不用 sys_now（10ms 网格）*/

    while (1) {
        int len = recv(sock, rx, sizeof(rx), 0); /* 阻塞等数据：数据驱动推进（ch23 结论 a）*/
        if (len > 0) {
            if (send_all(sock, rx, (size_t)len) != 0) {
                break; /* 回写失败（多为对端 RST），结束本连接 */
            }
            msgs++;
            bytes += (uint64_t)len;
            s_bytes_echoed += (uint64_t)len;
            ESP_LOGI(TAG, "conn #%u msg %u: echo %d bytes%s%.*s%s",
                     conn_idx, msgs, len,
                     " \"", len > 48 ? 48 : len, rx, len > 48 ? "..." : "\"");
        } else if (len == 0) {
            ESP_LOGI(TAG, "conn #%u peer closed (FIN) after %u msgs, %llu bytes",
                     conn_idx, msgs, (unsigned long long)bytes);
            break;
        } else {
            /* ECONNRESET=104 对端强制断开，ETIMEDOUT=113 栈层超时重传失败 */
            ESP_LOGW(TAG, "conn #%u recv failed errno=%d after %u msgs",
                     conn_idx, errno, msgs);
            break;
        }
    }

    close(sock); /* 及时回收：close 之前 PCB 持续占位，串行模型的下一个 accept 也被它压着 */
    ESP_LOGI(TAG, "conn #%u %s:%d CLOSED srv=%ums (%llu bytes echoed)",
             conn_idx, inet_ntoa(peer->sin_addr), ntohs(peer->sin_port),
             (unsigned)((esp_timer_get_time() - t0) / 1000),
             (unsigned long long)bytes);
    printf("$$$ EX02CLOSE conn=%u bytes=%llu\n", conn_idx, (unsigned long long)bytes);
}

static void echo_server_task(void *arg)
{
    struct sockaddr_in local_addr = {
        .sin_family      = AF_INET,
        .sin_port        = htons(ECHO_PORT),
        .sin_addr.s_addr = htonl(INADDR_ANY),
    };

    /* 注意：socket 创建必须晚于 app_main 里的 esp_netif_init()
     * （tcpip 邮箱未就绪时会 assert 复位，CONVENTIONS Batch 1）。*/
    int listen_sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    assert(listen_sock >= 0);

    int opt = 1;
    setsockopt(listen_sock, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    if (bind(listen_sock, (struct sockaddr *)&local_addr, sizeof(local_addr)) != 0) {
        ESP_LOGE(TAG, "bind :%d failed errno=%d", ECHO_PORT, errno);
        vTaskDelete(NULL);
    }
    if (listen(listen_sock, LISTEN_BACKLOG) != 0) {
        ESP_LOGE(TAG, "listen failed errno=%d", errno);
        vTaskDelete(NULL);
    }
    ESP_LOGI(TAG, "echo server listening on 0.0.0.0:%d backlog=%d", ECHO_PORT, LISTEN_BACKLOG);
    printf("$$$ EX02ECHOREADY port=%d backlog=%d\n", ECHO_PORT, LISTEN_BACKLOG);

    while (1) {
        struct sockaddr_in src_addr;
        socklen_t addr_len = sizeof(src_addr);
        int sock = accept(listen_sock, (struct sockaddr *)&src_addr, &addr_len);
        if (sock < 0) {
            ESP_LOGE(TAG, "accept failed errno=%d", errno);
            continue;
        }

        unsigned idx = ++s_conn_total;
        s_conn_active++;
        ESP_LOGI(TAG, "conn #%u ACCEPT from %s:%d (active=%u)",
                 idx, inet_ntoa(src_addr.sin_addr), ntohs(src_addr.sin_port),
                 (unsigned)s_conn_active);
        printf("$$$ EX02CONN idx=%u\n", idx);

        serve_connection(sock, &src_addr, idx);
        s_conn_active--;
    }
}

/* ------------------------- 低频观测面：周期打印当前连接数 -------------------------
 * 与数据面彻底分离：就算回写路径被压测打满，这里也只是读几个计数器，
 * 属于模板的"健康检查"钩子（CI 可 grep '$$$ EX02STATS' 断言存活）。*/
static void stats_task(void *arg)
{
    while (1) {
        vTaskDelay(pdMS_TO_TICKS(STATS_PERIOD_S * 1000));
        printf("$$$ EX02STATS active=%u total_accepted=%u bytes_echoed=%llu uptime_s=%lld\n",
               (unsigned)s_conn_active, (unsigned)s_conn_total,
               (unsigned long long)s_bytes_echoed, (long long)(esp_timer_get_time() / 1000000));
        fflush(stdout);
    }
}

/* ------------------------- app_main：标准 bring-up 序列（SPEC §3）------------------------- */

void app_main(void)
{
    ESP_LOGI(TAG, "== ex02 tcp-echo-server build@%s %s ==", __DATE__, __TIME__);
    printf("$$$ EX02BUILD \"%s %s\"\n", __DATE__, __TIME__);

    /* ①②③ netif 初始化三件套：esp_netif_init 必须是第一句网络调用
     * （socket 的创建在它之后才安全，见 echo_server_task 注释）*/
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    s_got_ip = xSemaphoreCreateBinary();

    /* ⑤~⑬ openeth bring-up（MAC `52:54:00:12:34:56`，DHCP 得 10.0.2.15/24）*/
    esp_netif_config_t netif_cfg = ESP_NETIF_DEFAULT_ETH();
    esp_netif_t *eth_netif = esp_netif_new(&netif_cfg);

    eth_mac_config_t mac_cfg = ETH_MAC_DEFAULT_CONFIG();
    eth_phy_config_t phy_cfg = ETH_PHY_DEFAULT_CONFIG();
    phy_cfg.reset_gpio_num      = -1; /* 虚拟 PHY 无复位引脚 */
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

    /* 观测面先行创建也无妨（不碰 socket）；数据面等拿到 IP 再启动更稳 */
    xTaskCreate(stats_task, "ex02_stats", 3072, NULL, 4, NULL);

    ESP_ERROR_CHECK(esp_eth_start(eth_handle));
    ESP_LOGI(TAG, "waiting for DHCP lease ...");

    if (xSemaphoreTake(s_got_ip, pdMS_TO_TICKS(DHCP_TIMEOUT_MS)) != pdTRUE) {
        ESP_LOGE(TAG, "DHCP timeout after %d ms", DHCP_TIMEOUT_MS);
        return;
    }
    ESP_LOGI(TAG, "net ready: " IPSTR "/24 gw " IPSTR ", starting echo server on :%d",
             IP2STR(&s_ip), IP2STR(&s_gw), ECHO_PORT);
    printf("$$$ EX02NETUP ip=" IPSTR " gw=" IPSTR "\n", IP2STR(&s_ip), IP2STR(&s_gw));
    fflush(stdout);

    /* ⑯ 应用逻辑：单任务 accept 循环（栈给足 4096，优先级 5=应用类基准）*/
    xTaskCreate(echo_server_task, "echo_srv", 4096, NULL, 5, NULL);

    /* ⑰ KEEPALIVE：app_main 返回即自杀，服务器要常驻 */
    while (1) {
        vTaskDelay(pdMS_TO_TICKS(60000));
    }
}
