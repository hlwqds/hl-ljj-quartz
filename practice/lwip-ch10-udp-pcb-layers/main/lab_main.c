/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * lwIP 深度解析（十）实验工程：UDP PCB 匹配与三层 API
 *
 * 在 ch3 联网模板（openeth bring-up + esp_netif + DHCP）之上：
 *   PHASE A  三层 API 同题 UDP echo，三个端口同时服役：
 *              8010/udp = raw      API（recv 回调内原 pbuf 直发）
 *              8011/udp = netconn  API（独立任务，邮箱消费 + netconn_sendto）
 *              8012/udp = socket   API（独立任务，recvfrom/sendto）
 *   PHASE B  netconn/socket 的"慢消费者"模式由主机经控制口下发；
 *   PHASE C  PCB 故障注入：顺序创建并绑定 6 个 socket，打印每个的 errno，
 *            close 之后再次创建验证恢复（配合 CONFIG_LWIP_MAX_UDP_PCBS=2 构建）；
 *   PHASE D  校验和验证：在 tcpip 线程上下文手工构造无链路层头的
 *            IPv4+UDP 数据报直塞 ip4_input()（应用层注入法），正确/
 *            篡改校验和各一发，对比 udp stats 计数与交付计数。
 *   控制口    8019/udp raw API：命令 "st" 打印计数/PCB 清单/udp stats，
 *            "slow:<ms>" 设置 netconn/socket 消费者延迟。
 *
 * 运行环境：ESP-IDF v6.0.2 + qemu-system-xtensa (Espressif fork)，
 *           -nic user,model=open_eth,hostfwd=udp::8010-:8010,...
 */

#include <stdio.h>
#include <stdlib.h>
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
#include "esp_eth_mac_openeth.h"

#include "lwip/inet.h"
#include "lwip/err.h"
#include "lwip/udp.h"
#include "lwip/api.h"
#include "lwip/ip4.h"
#include "lwip/tcpip.h"
#include "lwip/stats.h"
#include "lwip/inet_chksum.h"

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

static const char *TAG = "ch10lab";

#define PORT_RAW        8010
#define PORT_NETCONN    8011
#define PORT_SOCKET     8012
#define PORT_CTRL       8019
#define PORT_INJ        7777          /* 注入实验的接收端（raw pcb） */
#define EXP_C_FIRST_PORT 7730         /* 故障注入批量的 bind 起始端口 */
#define DHCP_TIMEOUT_MS  10000
#define KEEPALIVE_S      300

static SemaphoreHandle_t s_got_ip;
static uint32_t s_guest_ip;                    /* 网络序 guest 地址 */

/* 应用级接收计数：各自只在相应执行流里自增，读取端容忍瞬时偏差 */
volatile uint32_t s_raw_rx, s_nc_rx, s_sock_rx, s_inj_delivered;
volatile int s_slow_ms;                        /* PHASE B：netconn/socket 消费者延迟 */

static void ip_event_handler(void *arg, esp_event_base_t base,
                             int32_t event_id, void *event_data)
{
    ip_event_got_ip_t *evt = (ip_event_got_ip_t *)event_data;
    s_guest_ip = evt->ip_info.ip.addr;
    ESP_LOGI(TAG, "GOT_IP: " IPSTR, IP2STR(&evt->ip_info.ip));
    xSemaphoreGive(s_got_ip);
}

static void eth_event_handler(void *arg, esp_event_base_t base,
                              int32_t event_id, void *event_data)
{
    ESP_LOGI(TAG, "ETH_EVENT id=%ld", (long)event_id);
}

/* ------------------------- 观察：PCB 清单与 udp stats ------------------------- */

static void print_pcb_inventory(void)
{
    struct udp_pcb *p;
    int n = 0;

    /* udp_pcbs 是全局链表；观察点以 tcpip_callback 投递进 tcpip 线程执行，
     * 与内核遍历互斥安全（单线程模型）。这里为省事直接读——观察到轻微撕裂
     * 不影响结论，正式路径见 ctrl cmd 经 tcpip_callback。 */
    for (p = udp_pcbs; p != NULL; p = p->next) {
        printf("CH10-PCBLIST idx=%d lport=%u rport=%u connected=%d\r\n",
               n++, p->local_port, p->remote_port,
               (p->flags & UDP_FLAGS_CONNECTED) ? 1 : 0);
    }
    printf("CH10-FACT sizeof(struct udp_pcb)=%d active_pcbs=%d\r\n",
           (int)sizeof(struct udp_pcb), n);
}

static void print_udp_stats_line(void)
{
    printf("CH10-UDPSTATS recv=%u xmit=%u drop=%u chkerr=%u lenerr=%u memerr=%u "
           "rterr=%u proterr=%u | app rx raw=%u nc=%u sock=%u inj=%u slow_ms=%d\r\n",
           (unsigned)lwip_stats.udp.recv, (unsigned)lwip_stats.udp.xmit,
           (unsigned)lwip_stats.udp.drop, (unsigned)lwip_stats.udp.chkerr,
           (unsigned)lwip_stats.udp.lenerr, (unsigned)lwip_stats.udp.memerr,
           (unsigned)lwip_stats.udp.rterr, (unsigned)lwip_stats.udp.proterr,
           (unsigned)s_raw_rx, (unsigned)s_nc_rx, (unsigned)s_sock_rx,
           (unsigned)s_inj_delivered, s_slow_ms);
}

/* --------------------------- 控制口 8019（raw API） --------------------------- */

static struct udp_pcb *s_ctrl_pcb;

static void ctrl_recv_cb(void *arg, struct udp_pcb *pcb, struct pbuf *p,
                         const ip_addr_t *addr, u16_t port)
{
    if (!p) {
        return;
    }
    char cmd[64] = {0};
    size_t len = p->len < sizeof(cmd) - 1 ? p->len : sizeof(cmd) - 1;
    memcpy(cmd, p->payload, len);

    if (!strncmp(cmd, "slow:", 5)) {
        s_slow_ms = atoi(cmd + 5);
        printf("CH10-SLOW set to %d ms\r\n", s_slow_ms);
    } else if (!strncmp(cmd, "st", 2)) {
        print_udp_stats_line();
        print_pcb_inventory();
    }
    static const char ok[] = "ACK";
    struct pbuf *q = pbuf_alloc(PBUF_TRANSPORT, sizeof(ok) - 1, PBUF_RAM);
    if (q) {
        memcpy(q->payload, ok, sizeof(ok) - 1);
        udp_sendto(pcb, q, addr, port);      /* 回 ACK 给发送方 */
        pbuf_free(q);
    }
    pbuf_free(p);
}

/* --------------------------- PHASE A：三层 API echo --------------------------- */

/* raw API：回调就在 tcpip_thread 里执行，收到什么发回什么——同一个 pbuf 原样再出栈 */
static void raw_echo_recv_cb(void *arg, struct udp_pcb *pcb, struct pbuf *p,
                             const ip_addr_t *addr, u16_t port)
{
    if (!p) {
        return;
    }
    s_raw_rx++;
    udp_sendto(pcb, p, addr, port);          /* 零拷贝、零调度：同一线程同一 pbuf */
    pbuf_free(p);
}

static void raw_echo_start(uint16_t port)
{
    struct udp_pcb *pcb = udp_new();
    if (!pcb) {
        printf("CH10-SERVER api=raw port=%u udp_new() NULL\r\n", port);
        return;
    }
    err_t err = udp_bind(pcb, IP_ANY_TYPE, port);
    if (err != ERR_OK) {
        printf("CH10-SERVER api=raw port=%u bind failed err=%d\r\n", port, err);
        udp_remove(pcb);
        return;
    }
    udp_recv(pcb, raw_echo_recv_cb, NULL);
    printf("CH10-SERVER api=raw port=%u started (runs in tcpip thread)\r\n", port);
}

/* netconn API：独立任务，从 recvmbox 取 netbuf 后回发。注意自始至终没有数据拷贝：
 * recv 得到的是 pbuf 指针的所有权，sendto 又把同一个 pbuf 链交回协议栈。 */
static void netconn_echo_task(void *arg)
{
    struct netconn *conn = netconn_new(NETCONN_UDP);
    if (!conn) {
        printf("CH10-SERVER api=netconn conn_new FAILED errno_check MEMP pool full?\r\n");
        vTaskDelete(NULL);
        return;
    }
    err_t err = netconn_bind(conn, &ip_addr_any, PORT_NETCONN);
    if (err != ERR_OK) {
        printf("CH10-SERVER api=netconn bind err=%d\r\n", err);
        netconn_delete(conn);
        vTaskDelete(NULL);
        return;
    }
    printf("CH10-SERVER api=netconn port=%u task=%s prio=%d stack=4096\r\n",
           PORT_NETCONN, pcTaskGetName(NULL), uxTaskPriorityGet(NULL));

    while (1) {
        struct netbuf *buf = NULL;
        err_t rerr = netconn_recv(conn, &buf);
        if (rerr != ERR_OK || !buf) {
            continue;
        }
        s_nc_rx++;
        if (s_slow_ms > 0) {          /* PHASE B：模拟慢消费者 */
            vTaskDelay(pdMS_TO_TICKS(s_slow_ms));
        }
        netconn_sendto(conn, buf, netbuf_fromaddr(buf), netbuf_fromport(buf));
        netbuf_delete(buf);
    }
}

/* socket API：独立任务，标准 BSD 循环 */
static void socket_echo_task(void *arg)
{
    struct sockaddr_in local_addr = {
        .sin_family      = AF_INET,
        .sin_port        = htons(PORT_SOCKET),
        .sin_addr.s_addr = htonl(INADDR_ANY),
    };

    int sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (sock < 0) {
        printf("CH10-SERVER api=socket socket() FAILED errno=%d (%s)\r\n",
               errno, strerror(errno));
        vTaskDelete(NULL);
        return;
    }
    if (bind(sock, (struct sockaddr *)&local_addr, sizeof(local_addr)) != 0) {
        printf("CH10-SERVER api=socket bind FAILED errno=%d (%s)\r\n",
               errno, strerror(errno));
        close(sock);
        vTaskDelete(NULL);
        return;
    }
    printf("CH10-SERVER api=socket fd=%d port=%u task=%s prio=%d\r\n",
           sock, PORT_SOCKET, pcTaskGetName(NULL), uxTaskPriorityGet(NULL));

    while (1) {
        struct sockaddr_in src_addr;
        socklen_t addr_len = sizeof(src_addr);
        static char rx_buf[2048];

        ssize_t len = recvfrom(sock, rx_buf, sizeof(rx_buf), 0,
                               (struct sockaddr *)&src_addr, &addr_len);
        if (len <= 0) {
            printf("CH10-SOCK recvfrom ret=%d errno=%d\r\n", (int)len, errno);
            continue;
        }
        s_sock_rx++;
        if (s_slow_ms > 0) {          /* PHASE B：与 netconn 相同节奏的慢消费 */
            vTaskDelay(pdMS_TO_TICKS(s_slow_ms));
        }
        sendto(sock, rx_buf, len, 0, (struct sockaddr *)&src_addr, sizeof(src_addr));
    }
}

/* --------------------------- PHASE C：PCB 故障注入 --------------------------- */
/* 无论构建配置都执行：MAX_UDP_PCBS=16 全绿做对照；=2 时看闸门落在哪里 */

static void exp_c_pcb_exhaustion(void)
{
    static int fds[48];
    int kept = 0;
    int fail_at = -1, fail_errno = -1;

    printf("CH10-PHASE C start MAX_UDP_PCBS=%d MAX_SOCKETS=%d "
           "(probe: allocate+bind up to 40 udp sockets)\r\n",
           CONFIG_LWIP_MAX_UDP_PCBS, CONFIG_LWIP_MAX_SOCKETS);

    for (int i = 0; i < 40 && kept < 40; i++) {
        int fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        if (fd < 0) {
            fail_at = i;
            fail_errno = errno;
            printf("CH10-PCBFAIL #%d socket()=-1 errno=%d (%s)\r\n",
                   i, errno, strerror(errno));
            break;
        }
        struct sockaddr_in la = {
            .sin_family = AF_INET,
            .sin_port   = htons(EXP_C_FIRST_PORT + i),
            .sin_addr.s_addr = htonl(INADDR_ANY),
        };
        if (bind(fd, (struct sockaddr *)&la, sizeof(la)) != 0) {
            fail_at = i;
            fail_errno = errno;
            printf("CH10-PCBFAIL #%d fd=%d bind=-1 errno=%d (%s)\r\n",
                   i, fd, errno, strerror(errno));
            close(fd);
            break;
        }
        fds[kept++] = fd;
    }

    printf("CH10-PCBSUMMARY allocated_and_bound=%d first_failure_at=%s%d "
           "errno=%d (%s)\r\n", kept,
           fail_at < 0 ? "none/" : "#", fail_at < 0 ? -1 : fail_at,
           fail_errno, strerror(fail_errno));
    printf("CH10-PHASE C closing %d sockets, recovery probe:\r\n", kept);

    for (int i = 0; i < kept; i++) {
        close(fds[i]);
    }

    int fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (fd >= 0) {
        printf("CH10-PCBRECOVERY socket=%d OK after close -> 资源已归还\r\n", fd);
        close(fd);
    } else {
        printf("CH10-PCBRECOVERY socket()=-1 errno=%d still exhausted!\r\n", errno);
    }
}

/* ------------------- PHASE D：校验和应用层注入（绕开 SLIRP 干扰） ------------------- */

static struct udp_pcb *s_inj_pcb;

static void inj_recv_cb(void *arg, struct udp_pcb *pcb, struct pbuf *p,
                        const ip_addr_t *addr, u16_t port)
{
    if (!p) {
        return;
    }
    s_inj_delivered++;
    printf("CH10-INJ delivered payload='%.*s'\r\n",
           (int)(p->len > 32 ? 32 : p->len), (char *)p->payload);
    pbuf_free(p);
}

/* RFC1071 可链式累加的部分和：返回折返后的"原始和"（不取反），便于多段拼接 */
static u32_t ones_sum_raw(const void *data, size_t len, u32_t sum)
{
    const u8_t *b = data;
    while (len > 1) {
        sum += (b[0] << 8) | b[1];     /* 网络序 16 位字累加 */
        b += 2;
        len -= 2;
    }
    if (len == 1) {
        sum += (b[0] << 8);
    }
    while (sum >> 16) {
        sum = (sum & 0xffff) + (sum >> 16);
    }
    return sum;
}

/* 单段版本：取反得到最终校验和字段值 */
static u16_t ones_sum(const void *data, size_t len)
{
    return (u16_t)(~ones_sum_raw(data, len, 0) & 0xffff);
}

/*
 * 组装 [IPv4][UDP][payload] 连续缓冲（无链路层头），返回总长。
 * udp_correct=1 计算正确的伪头校验和；否则算对后最低位翻转 1 bit。
 */
static size_t build_inject_datagram(u8_t *b, const char *payload,
                                    int udp_correct, u16_t *reported_cksum)
{
    const u8_t src_ip[4] = { 10, 0, 2, 2 };       /* 扮演 SLIRP 方向来的包 */
    u8_t dst_ip[4];
    memcpy(dst_ip, &s_guest_ip, 4);

    size_t plen = strlen(payload);
    size_t ulen = 8 + plen;
    size_t ilen = 20 + ulen;

    memset(b, 0, ilen);
    b[0] = 0x45;                       /* ver=4 ihl=5 */
    b[3] = ilen & 0xff;
    b[2] = (ilen >> 8) & 0xff;
    b[4] = 0x12; b[5] = 0x34;          /* id */
    b[6] = 0x40;                       /* DF */
    b[8] = 64;                         /* TTL */
    b[9] = 17;                         /* proto = UDP */
    memcpy(b + 12, src_ip, 4);
    memcpy(b + 16, dst_ip, 4);
    u16_t ipck = ones_sum(b, 20);
    b[10] = ipck >> 8; b[11] = ipck & 0xff;

    b[20] = 0xC3; b[21] = 0x35;                    /* sport 50005 */
    b[22] = (PORT_INJ >> 8) & 0xff;
    b[23] = PORT_INJ & 0xff;
    b[24] = (ulen >> 8) & 0xff;
    b[25] = ulen & 0xff;
    memcpy(b + 28, payload, plen);

    u8_t pseudo[12];
    memset(pseudo, 0, sizeof(pseudo));
    memcpy(pseudo, src_ip, 4);
    memcpy(pseudo + 4, dst_ip, 4);
    pseudo[9] = 17;
    pseudo[10] = (ulen >> 8) & 0xff;
    pseudo[11] = ulen & 0xff;

    /* 伪头与数据区两段部分和相加后再折返取反——中间段不能提前取反 */
    u16_t ck = (u16_t)(~ones_sum_raw(b + 20, ulen,
                                     ones_sum_raw(pseudo, 12, 0)) & 0xffff);
    if (!udp_correct && ck != 0) {
        ck ^= 0x0001;
    }
    *reported_cksum = ck;
    b[26] = ck >> 8;
    b[27] = ck & 0xff;
    return ilen;
}

/*
 * 注入器本体：运行在 tcpip 线程（经 tcpip_callback 投递），
 * 直接调用 ip4_input —— 相当于"ethernet_input 解析完 MAC 之后的那一格"。
 */
typedef struct {
    const char *payload;
    int udp_correct;
} inject_arg_t;

static void inject_fn(void *arg)
{
    inject_arg_t *ia = (inject_arg_t *)arg;
    static u8_t buf[128];
    u16_t ck;
    size_t len = build_inject_datagram(buf, ia->payload, ia->udp_correct, &ck);

    printf("CH10-INJ inject \"%s\" len=%d udp_cksum=0x%04x (%s)\r\n",
           ia->payload, (int)len, ck, ia->udp_correct ? "CORRECT" : "CORRUPT");

    print_udp_stats_line();
    struct pbuf *p = pbuf_alloc(PBUF_RAW, len, PBUF_RAM);
    if (!p) {
        printf("CH10-INJ pbuf_alloc failed\r\n");
        return;
    }
    memcpy(p->payload, buf, len);

    struct netif *nif = netif_default;
    err_t err = ip4_input(p, nif);      /* pbuf 所有权移交给协议栈 */
    printf("CH10-INJ ip4_input returned %d (%s)\r\n", err,
           err == ERR_OK ? "consumed by stack" : lwip_strerr(err));
    print_udp_stats_line();
}

static void exp_d_checksum_injection(void)
{
#if CHECKSUM_CHECK_UDP
    printf("CH10-FACT CHECKSUM_CHECK_UDP=1 (per-netif flags may still veto)\r\n");
#else
    printf("CH10-FACT CHECKSUM_CHECK_UDP=0 -- RX 校验和验证编译期关闭\r\n");
#endif
    static inject_arg_t ia_ok =  { .payload = "ch10-inject-ok",     .udp_correct = 1 };
    static inject_arg_t ia_bad = { .payload = "ch10-inject-corrupt", .udp_correct = 0 };

    tcpip_callback(inject_fn, &ia_ok);
    vTaskDelay(pdMS_TO_TICKS(100));     /* 让打印落盘、计数稳定 */
    tcpip_callback(inject_fn, &ia_bad);
    vTaskDelay(pdMS_TO_TICKS(100));
}

/* ------------------------------ bring-up + 调度 ------------------------------ */

void app_main(void)
{
    ESP_LOGI(TAG, "== ch10 lab: udp pcb layers / 3-api echo / fault injection ==");

    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    s_got_ip = xSemaphoreCreateBinary();

    printf("CH10-FACT MAX_UDP_PCBS=%d UDP_RECVMBOX_SIZE=%d MAX_SOCKETS=%d\r\n",
           CONFIG_LWIP_MAX_UDP_PCBS, CONFIG_LWIP_UDP_RECVMBOX_SIZE,
           CONFIG_LWIP_MAX_SOCKETS);

    esp_netif_config_t netif_cfg = ESP_NETIF_DEFAULT_ETH();
    esp_netif_t *eth_netif = esp_netif_new(&netif_cfg);

    eth_mac_config_t mac_cfg = ETH_MAC_DEFAULT_CONFIG();
    eth_phy_config_t phy_cfg = ETH_PHY_DEFAULT_CONFIG();
    phy_cfg.reset_gpio_num      = -1;
    phy_cfg.autonego_timeout_ms = 3000;

    esp_eth_mac_t *mac = esp_eth_mac_new_openeth(&mac_cfg);
    esp_eth_phy_t *phy = esp_eth_phy_new_generic(&phy_cfg);
    esp_eth_config_t eth_cfg = ETH_DEFAULT_CONFIG(mac, phy);
    esp_eth_handle_t eth_handle = NULL;
    ESP_ERROR_CHECK(esp_eth_driver_install(&eth_cfg, &eth_handle));

    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_ETH_GOT_IP,
                                               &ip_event_handler, NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(ETH_EVENT, ESP_EVENT_ANY_ID,
                                               &eth_event_handler, NULL));

    esp_eth_netif_glue_handle_t glue = esp_eth_new_netif_glue(eth_handle);
    ESP_ERROR_CHECK(esp_netif_attach(eth_netif, glue));
    ESP_ERROR_CHECK(esp_eth_start(eth_handle));

    if (xSemaphoreTake(s_got_ip, pdMS_TO_TICKS(DHCP_TIMEOUT_MS)) != pdTRUE) {
        ESP_LOGE(TAG, "DHCP timeout -- aborting");
        return;
    }

    /*
     * 系统占用的 UDP PCB 清单此刻应有：DHCP 客户端(:68)，
     * 取决于配置可能还有 DNS / mdNS 等。PHASE C 的可用额度以此为背景。
     */
    print_pcb_inventory();

    /* 控制口先起来，主机一切协调动作走它 */
    s_ctrl_pcb = udp_new();
    if (s_ctrl_pcb && udp_bind(s_ctrl_pcb, IP_ANY_TYPE, PORT_CTRL) == ERR_OK) {
        udp_recv(s_ctrl_pcb, ctrl_recv_cb, NULL);
        printf("CH10-SERVER api=raw(port=ctrl) port=%u started\r\n", PORT_CTRL);
    }

    /* PHASE A 三层 echo 服务齐开 */
    raw_echo_start(PORT_RAW);
    xTaskCreate(netconn_echo_task, "ch10_nc", 4096, NULL, 5, NULL);
    xTaskCreate(socket_echo_task, "ch10_sock", 4096, NULL, 5, NULL);

    /* PHASE D 的接收端：绑定 7777 的 raw pcb 必须先就位，否则注入包走无端口分支 */
    s_inj_pcb = udp_new();
    if (s_inj_pcb && udp_bind(s_inj_pcb, IP_ANY_TYPE, PORT_INJ) == ERR_OK) {
        udp_recv(s_inj_pcb, inj_recv_cb, NULL);
        printf("CH10-SERVER api=raw(port=inj) port=%u started\r\n", PORT_INJ);
    } else if (s_inj_pcb == NULL) {
        printf("CH10-SERVER api=raw(port=inj) udp_new() NULL -- 注入实验失效\r\n");
    }

    vTaskDelay(pdMS_TO_TICKS(500));     /* 让 SERVER 日志完整落地 */

    /* PHASE D 校验和注入 */
    exp_d_checksum_injection();

    /* PHASE C PCB 故障注入 */
    exp_c_pcb_exhaustion();

    printf("CH10-READY servers on %d/%d/%d/%d, keepalive %ds\r\n",
           PORT_RAW, PORT_NETCONN, PORT_SOCKET, PORT_CTRL, KEEPALIVE_S);

    /* 周期性自报状态，便于主机压测时对账 */
    for (int i = 0; i < KEEPALIVE_S; i++) {
        vTaskDelay(pdMS_TO_TICKS(1000));
        if (i % 10 == 9 && (s_raw_rx | s_nc_rx | s_sock_rx)) {
            print_udp_stats_line();
        }
    }
    printf("CH10-BYE\r\n");
}
