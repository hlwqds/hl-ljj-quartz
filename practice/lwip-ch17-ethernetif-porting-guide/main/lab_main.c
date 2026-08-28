/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * lwIP 深度解析（十七）实验工程：ethernetif 移植指南
 *
 * 基于 ch3 联网模板（openeth + esp_netif + DHCP）。四组实验：
 *
 *   实验 a（INSTRUMENT）：驱动层观察点全集
 *     - TX 观察点：netif->linkoutput 换指针包装（tcpip_thread 上下文），
 *       统计帧数/字节数/分片长度分布，保留原函数调用链；
 *     - RX 观察点：esp_eth_update_input_path() 替换 glue 安装的输入路径，
 *       在 MAC 驱动 -> 协议栈边界统计帧数/字节数（本函数跑在 emac_rx 任务）；
 *     - 丢帧钩子位：两侧都留 drop 分支（TX 默认关、由实验 c 控制；
 *       RX 若丢弃必须自己 free(buffer)，与 esp_eth.c 无输入路径时行为一致）。
 *
 *   实验 b（RING SNAP）：绕过一切封装直接读 OpenCores DMA 描述符内存，
 *     打印 TX/RX 环每个描述符的 ownership 位与状态，在空闲/收发中两次采样。
 *
 *   实验 c（TX FULL）：在 linkoutput 包装层模拟「DMA 环满」——分别以
 *     ERR_IF 与 ERR_MEM 拒绝发送，观察 UDP sendto 的 errno 表现，
 *     以及配额用尽后的即时恢复（尝试序列 S/F 位图直观呈现）。
 *
 *   实验 d（RX OVERLOAD）：在 RX 输入路径里人为加 vTaskDelay 制造
 *     「搬运任务卡死」，配合主机侧 UDP 洪峰灌入，观测描述符环耗尽时的
 *     INT_BUSY 硬件丢帧告警与三时间窗送达率对比。
 *
 * 运行环境：ESP-IDF v6.0.2 + qemu-system-xtensa (Espressif fork)，
 *           -nic user,model=open_eth,hostfwd=tcp::8020-:8888,hostfwd=udp::8020-:8020
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdbool.h>
#include <inttypes.h>
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
#include "lwip/netif.h"
#include "lwip/pbuf.h"
#include "lwip/err.h"
#include "esp_netif_net_stack.h" /* esp_netif_get_netif_impl */
#include <netdb.h>
#include "ping/ping_sock.h"

/* 引号内数字都是编译期事实自报，防止 Kconfig 漂移后口径失真 */
#include "sdkconfig.h"

static const char *TAG = "ch17lab";

#define ECHO_PORT        8888      /* 主机侧经 hostfwd tcp::8020-:8888 访问 */
#define DHCP_TIMEOUT_MS  10000

/* ------------------------- 全局句柄 ------------------------- */

static SemaphoreHandle_t s_got_ip;
static esp_netif_t      *s_eth_netif;
static esp_eth_handle_t  s_eth_hdl;

/* ------------------------- 实验 a/c：TX 包装 -------------------------
 * linkoutput 只会在 tcpip_thread 里被调用（ch7/ch13 结论），所以这里
 * 的普通变量不需要锁；换指针手法来自 esp_netif_get_netif_impl()。
 */

static err_t (*s_orig_linkoutput)(struct netif *, struct pbuf *);

typedef struct {
    uint64_t frames;
    uint64_t bytes;
    uint32_t by128[9];      /* 指数分桶：0:[<=128] 1:(128,256] ... k:(128*2^(k-1),128*2^k] */
} port_counters_t;

static port_counters_t s_tx;
static port_counters_t s_rx;

/* 实验 d 的 RX 人为延迟（窗口控速器改写） */
static volatile int s_rx_delay_ms = 0;

/* 首次调用时记录各自执行的上下文任务名（观测点上下文的自证） */
static char s_tx_task[16], s_rx_task[16];
static volatile bool s_tx_task_known, s_rx_task_known;
static uint32_t s_dbg_rx_printed;
static uint32_t s_big_seen;

/* 故障注入：模拟 DMA TX 环满（真实全速 MAC 上这是描述符无 free 态的时刻） */
enum { INJ_OFF = 0, INJ_ERR_IF, INJ_ERR_MEM };
static volatile int      s_inj_mode = INJ_OFF;
static volatile uint32_t s_inj_quota = 0;    /* 还要拒绝多少次 linkoutput */
static uint32_t          s_inj_fired;

static uint8_t bucket_of(uint16_t len)
{
    uint8_t b = 0;
    uint32_t v = (uint32_t)len >> 7;    /* /128 */
    while ((v >>= 1) != 0 && b < 8) {
        b++;
    }
    return b;
}

static err_t instrumented_linkoutput(struct netif *netif, struct pbuf *p)
{
    if (!s_tx_task_known) {
        strlcpy(s_tx_task, pcTaskGetName(NULL), sizeof(s_tx_task));
        s_tx_task_known = true;
    }
    if (p) {
        s_tx.frames++;
        s_tx.bytes += p->tot_len;
        s_tx.by128[bucket_of(p->tot_len)]++;
    }
    if (s_inj_mode != INJ_OFF && s_inj_quota > 0) {
        s_inj_quota--;
        s_inj_fired++;
        printf("[INJ-TX] reject t_us=%lld len=%d quota_left=%lu\n",
               (long long)esp_timer_get_time(), p ? (int)p->tot_len : -1,
               (unsigned long)s_inj_quota);
        /* 真实「环满」驱动的两种流派：报错回头 vs 自旋等待。此处演示报错派 */
        return (s_inj_mode == INJ_ERR_IF) ? ERR_IF : ERR_MEM;
    }
    return s_orig_linkoutput(netif, p);
}

static void tx_wrap_install(void)
{
    struct netif *n = (struct netif *)esp_netif_get_netif_impl(s_eth_netif);
    assert(n != NULL && n->linkoutput != NULL);
    s_orig_linkoutput = n->linkoutput;
    n->linkoutput = instrumented_linkoutput;
}

/* ------------------------- 实验 a/d：RX 包装 -------------------------
 * 覆盖 glue 层经 esp_eth_update_input_path_info 安装的输入路径。
 * 注意契约：stack_input 执行于 emac_rx 任务上下文；返回前 buffer 所有权
 * 已交出（成功→协议栈经 custom pbuf 归还，失败/丢弃→本函数负责 free）。
 */

static esp_err_t counting_stack_input(esp_eth_handle_t hdl, uint8_t *buffer,
                                      uint32_t length, void *priv)
{
    if (!s_rx_task_known) {
        strlcpy(s_rx_task, pcTaskGetName(NULL), sizeof(s_rx_task));
        s_rx_task_known = true;
    }
    /* 前 5 帧逐帧详报 + 之后每 200 帧抽一行：帧长/ethertype 指纹 */
    if (s_dbg_rx_printed < 5 || (s_rx.frames % 200 == 0)) {
        uint16_t ethertype = buffer && length >= 14
                             ? ((uint16_t)buffer[12] << 8) | buffer[13] : 0xFFFF;
        printf("[RXDBG] n=%llu len=%lu eth=0x%04x t_us=%lld\n",
               (unsigned long long)(s_rx.frames + 1), (unsigned long)length,
               ethertype, (long long)esp_timer_get_time());
        s_dbg_rx_printed++;
    }
    /* 大帧侦探：>=500B 的帧最多细看 25 个，解出 IP 协议号/端口，定位神秘洪流 */
    if (length >= 500 && s_big_seen < 25) {
        s_big_seen++;
        uint8_t ipproto = 0;
        uint16_t sp = 0, dp = 0;
        if (length >= 38 && buffer[12] == 0x08 && buffer[13] == 0x00) {
            ipproto = buffer[23];
            sp = ((uint16_t)buffer[34] << 8) | buffer[35];
            dp = ((uint16_t)buffer[36] << 8) | buffer[37];
        }
        printf("[RXBIG] len=%lu proto=%u sport=%u dport=%u t_us=%lld\n",
               (unsigned long)length, ipproto, sp, dp,
               (long long)esp_timer_get_time());
    }
    s_rx.frames++;
    s_rx.bytes += length;
    s_rx.by128[bucket_of((uint16_t)length)]++;

    /* 实验 d：人为拖慢搬运任务，制造环形缓冲耗尽条件 */
    if (s_rx_delay_ms > 0) {
        vTaskDelay(pdMS_TO_TICKS(s_rx_delay_ms));
    }

    /* 这里没有做 RX 丢帧注入。若要丢：必须先 free(buffer) 再返回，
     * 见 components/esp_eth/src/esp_eth.c 中“未安装输入路径”的兜底分支 */
    return esp_netif_receive(s_eth_netif, buffer, length, NULL);
}

/* ------------------------- 实验 b：描述符环可视化 -------------------------
 * 以下寄存器地址与结构布局逐字复制自 IDF 私有头
 * components/esp_eth/src/openeth/openeth.h（Apache-2.0），
 * 目的是让实验代码不依赖组件私有路径也能核对同一块内存。
 */

#define CH17_OPENETH_BASE        0x3FF69000UL  /* DR_REG_EMAC_BASE (esp32 soc/reg_base.h) */
#define CH17_DESC_BASE           (CH17_OPENETH_BASE + 0x400)
#define CH17_TX_BD_NUM_REG       (CH17_OPENETH_BASE + 0x20)

#define CH17_DMA_BUF_SIZE        1600          /* openeth.h 同名宏的值 */
#define CH17_TX_CNT              CONFIG_ETH_OPENETH_DMA_TX_BUFFER_NUM
#define CH17_RX_CNT              CONFIG_ETH_OPENETH_DMA_RX_BUFFER_NUM
#define CH17_DESC_TOTAL          128           /* QEMU 固定 128 个槽位，TX 在前 */

/* volatile 告诉编译器这片内存随时会被硬件改写 */
typedef struct {
    volatile uint16_t cs: 1, df: 1, lc: 1, rl: 1, rtry: 4, ur: 1, rsv: 2,
                      crc: 1, pad: 1, wr: 1, irq: 1, rd: 1;
    volatile uint16_t len;
    volatile void    *txpnt;
} ch17_tx_desc_t;

typedef struct {
    volatile uint16_t lc: 1, crc: 1, sf: 1, tl: 1, dn: 1, is: 1, or_: 1,
                      m: 1, rsv: 5, wr: 1, irq: 1, e: 1;
    volatile uint16_t len;
    volatile void    *rxpnt;
} ch17_rx_desc_t;

_Static_assert(sizeof(ch17_tx_desc_t) == 8, "desc layout mismatch");
_Static_assert(sizeof(ch17_rx_desc_t) == 8, "desc layout mismatch");

static inline ch17_tx_desc_t *tx_desc(int i) {
    return &((ch17_tx_desc_t *)CH17_DESC_BASE)[i];
}
static inline ch17_rx_desc_t *rx_desc(int i) {
    /* RX 槽位排在全部 TX 槽之后（openeth_rx_desc 的实现语义） */
    return &((ch17_rx_desc_t *)CH17_DESC_BASE)[i + CH17_TX_CNT];
}

static void ring_snapshot(const char *label)
{
    int64_t now = esp_timer_get_time();
    printf("[RING][%s] t_ms=%lld hw_tx_bd_num=%ld\n", label,
           (long long)(now / 1000),
           (long)*(volatile uint32_t *)CH17_TX_BD_NUM_REG);

    for (int i = 0; i < CH17_TX_CNT; i++) {
        ch17_tx_desc_t *d = tx_desc(i);
        printf("[RING][%s] TX[%d/%d] rd=%u wr=%u len=%u buf=%p\n",
               label, i, CH17_TX_CNT, d->rd, d->wr, d->len, (void *)d->txpnt);
    }
    /* 一行聚齐整个 RX 环：e 位串 + 长度串，方便肉眼看 ownership 波动 */
    printf("[RING][%s] RX e-bit: ", label);
    for (int i = 0; i < CH17_RX_CNT; i++) {
        printf("%u", rx_desc(i)->e);
    }
    printf("  len:");
    for (int i = 0; i < CH17_RX_CNT; i++) {
        printf(" %u", rx_desc(i)->len);
    }
    printf("\n");
}

/* ------------------------- 网络 bring-up（承 ch3 模板） ------------------ */

static void on_ping_reply(esp_ping_handle_t hdl, void *args);
static void on_ping_timeout(esp_ping_handle_t hdl, void *args);

static void ip_event_handler(void *arg, esp_event_base_t base,
                             int32_t event_id, void *event_data)
{
    ip_event_got_ip_t *evt = (ip_event_got_ip_t *)event_data;
    ESP_LOGI(TAG, "GOT_IP: " IPSTR, IP2STR(&evt->ip_info.ip));
    xSemaphoreGive(s_got_ip);
}

static void run_ping_gateway(int count, int interval_ms)
{
    ip_addr_t target;
    IP_SET_TYPE_VAL(target, IPADDR_TYPE_V4);

    esp_ping_config_t cfg = ESP_PING_DEFAULT_CONFIG();
    cfg.target_addr = target;
    cfg.count       = count;
    cfg.interval_ms = interval_ms;
    cfg.timeout_ms  = 800;

    static const char *tn = "gw";
    esp_ping_callbacks_t cbs = {
        .cb_args        = (void *)tn,
        .on_ping_success = on_ping_reply,
        .on_ping_timeout = on_ping_timeout,
        .on_ping_end     = NULL,
    };
    esp_ping_handle_t hdl;
    ESP_ERROR_CHECK(esp_ping_new_session(&cfg, &cbs, &hdl));
    esp_ping_start(hdl);
    vTaskDelay(pdMS_TO_TICKS(count * interval_ms + 5 * cfg.timeout_ms));
    esp_ping_stop(hdl);
    esp_ping_delete_session(hdl);
}

static void on_ping_reply(esp_ping_handle_t hdl, void *args)
{
    uint16_t seqno;
    uint32_t recv_len;
    int64_t now_ms = esp_timer_get_time() / 1000;
    esp_ping_get_profile(hdl, ESP_PING_PROF_SEQNO, &seqno, sizeof(seqno));
    esp_ping_get_profile(hdl, ESP_PING_PROF_SIZE, &recv_len, sizeof(recv_len));
    /* 同时报 RX 计数器现状：验证回复是否真的流过我们的观察点 */
    printf("[PING-REPLY] seq=%u size=%lu t_ms=%lld rx_counter=%llu\n",
           seqno, (unsigned long)recv_len, (long long)now_ms,
           (unsigned long long)s_rx.frames);
}

static void on_ping_timeout(esp_ping_handle_t hdl, void *args)
{
    uint16_t seqno;
    int64_t now_ms = esp_timer_get_time() / 1000;
    esp_ping_get_profile(hdl, ESP_PING_PROF_SEQNO, &seqno, sizeof(seqno));
    printf("[PING-TIMEOUT] seq=%u t_ms=%lld rx_counter=%llu\n",
           seqno, (long long)now_ms, (unsigned long long)s_rx.frames);
}

/* ------------------------- 流量发生器 ------------------------- */

static SemaphoreHandle_t s_burst_done;

static void udp_burst_task(void *arg)
{
    uint32_t cnt = (uint32_t)(uintptr_t)arg;
    uint8_t payload[1024];
    memset(payload, 'Z', sizeof(payload));

    struct sockaddr_in dst = {
        .sin_family = AF_INET,
        .sin_port   = htons(9),                       /* discard 端口 */
        .sin_addr.s_addr = htonl(0x0A000202UL),       /* 10.0.2.2 (PP_HTONL 手工字面量) */
    };

    int fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_IP);
    assert(fd >= 0);
    connect(fd, (struct sockaddr *)&dst, sizeof(dst));

    for (uint32_t i = 0; i < cnt; i++) {
        send(fd, payload, sizeof(payload), 0);
        vTaskDelay(pdMS_TO_TICKS(3));
    }
    close(fd);
    xSemaphoreGive(s_burst_done);
    vTaskDelete(NULL);
}

static void counter_diff(const char *label, const port_counters_t *a0,
                         const port_counters_t *a1, const port_counters_t *b0,
                         const port_counters_t *b1)
{
    long long df = (long long)a1->frames - (long long)a0->frames;
    long long db = (long long)a1->bytes  - (long long)a0->bytes;
    long long rf = (long long)b1->frames - (long long)b0->frames;
    long long rb = (long long)b1->bytes  - (long long)b0->bytes;
    printf("[%s] delta tx_frames=%lld tx_bytes=%lld rx_frames=%lld rx_bytes=%lld\n",
           label, df, db, rf, rb);
    printf("[%s] tx_hist<=", label);
    for (int i = 0; i < 9; i++) {
        printf("%ld,", (long)((int64_t)a1->by128[i] - (int64_t)a0->by128[i]));
    }
    printf("> rx_hist<=");
    for (int i = 0; i < 9; i++) {
        printf("%ld,", (long)((int64_t)b1->by128[i] - (int64_t)b0->by128[i]));
    }
    printf(">\n");
}

/* ------------------------- 实验 c：sendto 探针 -------------------------
 * 与 udp_burst_task 不同，这条探针记录每一次调用的成败与 errno 序列：
 * 返回值行被压缩成 S/F 位图，一眼看出注入配额何时耗尽、恢复点在哪。
 */

static void udp_probe_errno(const char *tag, int cnt, int size, int gap_ms)
{
    uint8_t payload[1200];
    memset(payload, tag[0], sizeof(payload));

    struct sockaddr_in dst = {
        .sin_family = AF_INET,
        .sin_port   = htons(9),
        .sin_addr.s_addr = htonl(0x0A000202UL),
    };
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    assert(fd >= 0);
    connect(fd, (struct sockaddr *)&dst, sizeof(dst));

    char seq[201] = {0};
    int ok = 0, bad = 0;
    int saved_rc = 0, saved_en = 0;

    for (int i = 0; i < cnt && i < 200; i++) {
        errno = 0;
        ssize_t rc = send(fd, payload, size, 0);
        if (rc >= 0) {
            seq[i] = 'S'; ok++;
        } else {
            seq[i] = 'F'; bad++;
            saved_rc = (int)rc; saved_en = errno;
            /* 只打前几个失败样本与最后一个失败样本，控制日志量 */
            if (bad <= 3 || i == cnt - 1) {
                printf("[PROBE-%s] #%d FAIL rc=%d errno=%d (%s)\n",
                       tag, i, (int)rc, errno, strerror(errno));
            }
            vTaskDelay(pdMS_TO_TICKS(gap_ms));   /* 失败也按节奏来，保证时间轴均匀 */
            continue;
        }
        if (gap_ms) vTaskDelay(pdMS_TO_TICKS(gap_ms));
    }
    printf("[PROBE-%s] total=%d ok=%d fail=%d last_fail(rc=%d errno=%d)\n",
           tag, cnt, ok, bad, saved_rc, saved_en);
    printf("[PROBE-%s] seq=%s\n", tag, seq);
    close(fd);
}

/* ------------------------- 实验 d：三时间窗控速器 -------------------------
 * 控制窗(6s, 延迟0) -> 过载窗(8s, 每帧延迟30ms) -> 恢复窗(6s, 延迟0)。
 * 主机洪峰在整个期间匀速灌入，guest 按 500ms 刻度打送达增量行。
 */
struct dwin { const char *name; uint64_t frames; uint64_t bytes; int32_t t0; };

static void phase_d_run(void)
{
    uint64_t f_prev = s_rx.frames, b_prev = s_rx.bytes;
    struct dwin w = { "ctl", 0, 0, (int32_t)(esp_timer_get_time() / 1000) };
    printf("[D] ARMED ctl=6s stress(delay=30ms)=8s recover=6s\n");

    for (int slot = 0; slot < 40; slot++) {         /* 40 x 500ms = 20s */
        vTaskDelay(pdMS_TO_TICKS(500));
        int64_t now = esp_timer_get_time();

        if (slot == 12) {                            /* 6s 后进入过载窗 */
            w.name = "stress"; f_prev = s_rx.frames; b_prev = s_rx.bytes;
            w.frames = 0; w.bytes = 0; w.t0 = (int32_t)(now / 1000);
            s_rx_delay_ms = 30;
            printf("[D] >>> stress window ON: rx_task now sleeps 30ms/frame <<<\n");
            ring_snapshot("d-stress-on");
        }
        if (slot == 28) {                            /* 14s 处回到正常 */
            w.name = "recover"; f_prev = s_rx.frames; b_prev = s_rx.bytes;
            w.frames = 0; w.bytes = 0; w.t0 = (int32_t)(now / 1000);
            s_rx_delay_ms = 0;
            printf("[D] >>> recover window: delay cleared <<<\n");
        }
        /* 每 2s 打一行窗口内累计 */
        if (slot % 4 == 3) {
            uint64_t df = s_rx.frames - f_prev;
            uint64_t db = s_rx.bytes  - b_prev;
            printf("[D-WIN %s] +%llu frames +%llu bytes\n",
                   w.name, (unsigned long long)df, (unsigned long long)db);
        }
    }
    ring_snapshot("d-end");
    printf("[D] lifetime rx_frames=%llu rx_bytes=%llu\n",
           (unsigned long long)s_rx.frames, (unsigned long long)s_rx.bytes);
}

/* ------------------------- echo server（承接模板，供主机访问） ---------- */

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
    bind(listen_sock, (struct sockaddr *)&local_addr, sizeof(local_addr));
    listen(listen_sock, 1);
    ESP_LOGI(TAG, "echo server listening on 0.0.0.0:%d", ECHO_PORT);

    while (1) {
        int sock = accept(listen_sock, NULL, NULL);
        if (sock < 0) continue;
        int len;
        while ((len = recv(sock, rx_buf, sizeof(rx_buf), 0)) > 0) {
            send(sock, rx_buf, len, 0);
        }
        close(sock);
    }
}

/* ------------------------- app_main ------------------------- */

void app_main(void)
{
    ESP_LOGI(TAG, "== ch17 lab: ethernetif porting guide ==");
    ESP_LOGI(TAG, "BUILD-FACT dma_buf=%d tx_cnt=%d rx_cnt=%d eth_max_frame=1522",
             CH17_DMA_BUF_SIZE, CH17_TX_CNT, CH17_RX_CNT);

    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    s_got_ip = xSemaphoreCreateBinary();
    s_burst_done = xSemaphoreCreateBinary();

    xTaskCreate(echo_server_task, "echo_srv", 4096, NULL, 5, NULL);

    esp_netif_config_t netif_cfg = ESP_NETIF_DEFAULT_ETH();
    s_eth_netif = esp_netif_new(&netif_cfg);

    eth_mac_config_t mac_cfg = ETH_MAC_DEFAULT_CONFIG();  /* rx task 4096B prio15 */
    eth_phy_config_t phy_cfg = ETH_PHY_DEFAULT_CONFIG();
    phy_cfg.reset_gpio_num      = -1;
    phy_cfg.autonego_timeout_ms = 3000;

    esp_eth_mac_t *mac = esp_eth_mac_new_openeth(&mac_cfg);
    assert(mac);
    esp_eth_phy_t *phy = esp_eth_phy_new_generic(&phy_cfg);
    assert(phy);

    esp_eth_config_t eth_cfg = ETH_DEFAULT_CONFIG(mac, phy);
    ESP_ERROR_CHECK(esp_eth_driver_install(&eth_cfg, &s_eth_hdl));

    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_ETH_GOT_IP,
                                               &ip_event_handler, NULL));

    esp_eth_netif_glue_handle_t glue = esp_eth_new_netif_glue(s_eth_hdl);
    ESP_ERROR_CHECK(esp_netif_attach(s_eth_netif, glue));

    /* 关键一步：覆写 glue 的输入路径为我们的计数版。
     * 放在 attach 之后、start 之前，DHCP 流量也会流经它。 */
    ESP_ERROR_CHECK(esp_eth_update_input_path(s_eth_hdl, counting_stack_input, NULL));
    ESP_LOGI(TAG, "RX input path instrumented (was glue eth_input_to_netif)");

    ESP_ERROR_CHECK(esp_eth_start(s_eth_hdl));
    ESP_LOGI(TAG, "waiting for DHCP lease ...");
    assert(xSemaphoreTake(s_got_ip, pdMS_TO_TICKS(DHCP_TIMEOUT_MS)) == pdTRUE);

    tx_wrap_install();          /* ARP 未热身也可能有帧，早装早计数 */
    printf("[SANITY] before warmup: rx=%llu tx=%llu\n",
           (unsigned long long)s_rx.frames, (unsigned long long)s_tx.frames);
    run_ping_gateway(2, 200);   /* 先放两发 ARP/ping 把链路焐热，不计入对比 */
    printf("[SANITY] after warmup: rx=%llu tx=%llu\n",
           (unsigned long long)s_rx.frames, (unsigned long long)s_tx.frames);

    /* ================= 实验 a：观察点仪表盘 =================
     * 流量源 1：向 SLIRP 发 12 个小 UDP —— 实测它会立刻回弹
     * ICMP Port-Unreachable（594B 大帧，[RXBIG] 可见指纹），
     * 这给了我们一批确定性的入站帧；
     * 流量源 2：网关 ping —— 温启动会话可达，第二次起的会话
     * 实测恒超时（SLIRP 怪癖），如实呈现两种结果。 */
    printf("===== PHASE A: driver observability t_ms=%lld =====\n",
           (long long)(esp_timer_get_time() / 1000));
    port_counters_t a0t = s_tx, a0r = s_rx;
    udp_probe_errno("A-udp", 12, 256, 20);
    run_ping_gateway(4, 200);
    printf("[A] after traffic t_ms=%lld rx=%llu tx=%llu\n",
           (long long)(esp_timer_get_time() / 1000),
           (unsigned long long)s_rx.frames, (unsigned long long)s_tx.frames);
    ring_snapshot("a-post-ping");
    counter_diff("A", &a0t, &s_tx, &a0r, &s_rx);
    printf("[A] hook contexts: TX-linkoutput in '%s', RX-stack_input in '%s'\n",
           s_tx_task_known ? s_tx_task : "?", s_rx_task_known ? s_rx_task : "?");

    /* ================= 实验 b：描述符环快照 ================= */
    printf("===== PHASE B: descriptor ring snapshots t_ms=%lld =====\n",
           (long long)(esp_timer_get_time() / 1000));
    ring_snapshot("b-idle-before");
    xTaskCreate(udp_burst_task, "udp_burst", 4096, (void *)(uintptr_t)16, 5, NULL);
    for (int round = 0; round < 4; round++) {     /* 出站突发进行中每 40ms 快照 */
        ring_snapshot("b-tx-active");
        vTaskDelay(pdMS_TO_TICKS(40));
    }
    xSemaphoreTake(s_burst_done, pdMS_TO_TICKS(3000));
    vTaskDelay(pdMS_TO_TICKS(300));
    ring_snapshot("b-idle-after");

    /* ================= 实验 c：TX 环满注入 ================= */
    printf("===== PHASE C: TX-ring-full injection =====\n");

    printf("--- C0 baseline ---\n");
    udp_probe_errno("C0", 30, 1024, 3);

    printf("--- C1 ERR_IF injected on every call (quota=huge) ---\n");
    s_inj_mode = INJ_ERR_IF;
    s_inj_quota = 0xFFFFFFFF;
    udp_probe_errno("C1", 20, 1024, 3);
    s_inj_mode = INJ_OFF;
    s_inj_quota = 0;

    printf("--- C2 recovery: ERR_IF quota=15 inside 40-call burst ---\n");
    s_inj_mode = INJ_ERR_IF;
    s_inj_quota = 15;
    udp_probe_errno("C2", 40, 1024, 10);   /* 拉开间隔看恢复节奏 */
    s_inj_mode = INJ_OFF;

    printf("--- C3 ERR_MEM injected on every call (quota=huge) ---\n");
    s_inj_mode = INJ_ERR_MEM;
    s_inj_quota = 0xFFFFFFFF;
    udp_probe_errno("C3", 20, 1024, 3);
    s_inj_mode = INJ_OFF;
    s_inj_quota = 0;
    printf("[C] injection fired %lu times total\n", (unsigned long)s_inj_fired);

    /* ================= 实验 d：RX 超载（等主机洪峰） ================= */
    printf("===== PHASE D: RX overload, host flood window opens NOW =====\n");
    phase_d_run();

    printf("===== ALL PHASES DONE, echo server stays on :%d =====\n", ECHO_PORT);
    vTaskDelay(portMAX_DELAY);   /* 交给外部 timeout 收割进程 */
}
