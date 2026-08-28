/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * practice/lwip-examples/ex04-udp-echo-bidir —— UDP 双向收发模板
 *
 * 单一 socket 层（BSD API），演示 UDP 的四个关键事实：
 *   1. bind 固定本地端口：hostfwd=udp::8230-:8230 只认固定端口；
 *      不 bind 的 socket 端口是临时的，SLIRP 无处投递。
 *   2. 无连接语义：没有 listen/accept/connect 握手，一个 fd 同时服务任意多个
 *      对端——本例同一端口上就混着三种来源（宿主 send.py / 自环折返 / 宿主回声器）。
 *   3. 来源地址必须取自 recvfrom 返回值并原样回复（recvfrom 来源判断）：
 *      每个 sendto 都自带目的地址，绝不假设"对端是谁"。
 *   4. 超时必须自管：UDP 没有重传、没有 keepalive、没有连接状态。
 *      阻塞 recvfrom 若无 SO_RCVTIMEO，第一个丢包就能让单线程服务永久停摆；
 *      应用层靠"序号 + 自己的定时器"感知丢包——协议栈不会通知你任何事。
 *
 * 双路径设计（入向 + 出向各有真实往返证据）：
 *   入向   host: send.py --> 127.0.0.1:8230 --SLIRP hostfwd--> guest:8230，
 *          本程序 echo 回去；send.py 用序号+digest 校验完整往返。
 *   出向A  guest sendto 10.0.2.2:8230 --SLIRP--> 宿主 loopback:8230 —— 该端口恰是
 *          QEMU 自己的 hostfwd 监听，数据报被转发回 guest:8230（"回环打自己"）。
 *          往返证据 = 本程序发出的探针在 SO_RCVTIMEO 窗口内原样收回（digest OK）。
 *   出向B  guest sendto 10.0.2.2:8231 --SLIRP--> 宿主 tools/udp_echo_srv.py 回声。
 *          往返证据同上，但对端是独立宿主进程，证明出向 UDP 能到达任意监听者。
 *
 * payload 头（自定义协议，9 字节）：
 *   offset 0..3  magic "EX04"
 *   offset 4     tag：
 *                  'H' = 宿主入向测试流量（send.py 发的）→ 必须原样 echo 回来源；
 *                  'A' = 出向自环探针；'B' = 出向外服探针 → 这是"自己人的回声"，
 *                        收到后绝不再转发！否则会把回声当新请求无限放大成回声风暴。
 *   offset 5..8  seq u32 大端；其余为确定性填充体（echo 必须逐字节一致）。
 *
 * 运行环境：ESP-IDF v6.0.2 + qemu-system-xtensa (Espressif fork)，
 *           -nic user,model=open_eth,hostfwd=udp::8230-:8230
 * 端口规划见 ../SPEC.md §4：ex04 占 823 号段，8230=主服务(+0)，8231=宿主辅助回声器(+1)。
 */

#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <inttypes.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"

#include "esp_log.h"
#include "esp_event.h"
#include "esp_netif.h"
#include "esp_eth.h"
#include "esp_eth_mac_openeth.h"
#include "esp_timer.h"

#include "lwip/inet.h"
#include "lwip/err.h"

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

static const char *TAG = "ex04";

/* ------------------------------- 配置 ------------------------------------- */

#define APP_UDP_PORT       8230        /* 主服务端口（hostfwd 两端同号） */
#define EXT_ECHO_PORT      8231        /* 出向路径 B：宿主 udp_echo_srv.py */
#define GATEWAY_IP_STR     "10.0.2.2"  /* SLIRP 网关 = 宿主 loopback 映射入口 */
#define DHCP_TIMEOUT_MS    15000
#define RECV_TIMEOUT_MS    2000        /* SO_RCVTIMEO 基准值：UDP 超时唯一安全阀 */
#define PROBE_N            10          /* 每条出向路径的探针数 */
#define PROBE_INTERVAL_MS  100
#define ECHO_PRINT_MAX     40          /* 入向回显前 N 包逐行打印，之后节流 */
#define STATS_PERIOD_S     10
#define RX_BUF_LEN         1600        /* 单个数据报缓冲（≥MTU 即可，UDP 有界） */

/* payload 头长度：magic(4) + tag(1) + seq(4) */
#define HDR_LEN            9
static const uint8_t MAGIC_EX04[4] = { 'E', 'X', '0', '4' };

/* ------------------------------- 全局状态 --------------------------------- */
/* 本模板刻意单任务串行服务（简单优先）：所有计数只在本任务里读写，无需加锁。 */

static SemaphoreHandle_t s_got_ip;
static char s_guest_ip_str[16];            /* DHCP 结果，仅用于打印 */

/* 统计计数器（EX04-ST 周期汇总用） */
static struct {
    uint64_t rx_total;                     /* recvfrom 成功返回的数据报总数 */
    uint64_t rx_short;                     /* 长度不足一个合法头的包（截断/垃圾） */
    uint64_t echoed_h;                     /* tag 'H' 已回显数（宿主入向路径） */
    uint64_t self_ok, self_lost, self_corrupt;   /* 出向 A */
    uint64_t ext_ok, ext_lost, ext_corrupt;      /* 出向 B */
} g_st;

/* --------------------------- payload 编解码 ------------------------------- */

static void build_probe(uint8_t *buf, size_t total_len, char tag, uint32_t seq)
{
    buf[0] = 'E'; buf[1] = 'X'; buf[2] = '0'; buf[3] = '4';
    buf[4] = (uint8_t)tag;
    buf[5] = (uint8_t)(seq >> 24); buf[6] = (uint8_t)(seq >> 16);
    buf[7] = (uint8_t)(seq >> 8);  buf[8] = (uint8_t)(seq & 0xff);
    /* 确定性填充体：同一 (tag,seq,len) 恒定 → 收到的数据报可逐字节自校验 */
    for (size_t j = HDR_LEN; j < total_len; j++) {
        buf[j] = (uint8_t)((j * 13 + seq * 7 + 11) % 251);
    }
}

typedef struct {
    bool valid;
    char tag;
    uint32_t seq;
} hdr_t;

static bool parse_hdr(const uint8_t *buf, ssize_t len, hdr_t *out)
{
    if (len < HDR_LEN || memcmp(buf, MAGIC_EX04, 4) != 0) {
        return false;
    }
    out->valid = true;
    out->tag = (char)buf[4];
    out->seq = ((uint32_t)buf[5] << 24) | ((uint32_t)buf[6] << 16) |
               ((uint32_t)buf[7] << 8) | (uint32_t)buf[8];
    return true;
}

/* SO_RCVTIMEO 是 lwIP 里 recvfrom 的超时机制（LWIP_SO_RCVTIMEO 在 IDF port 中恒为 1） */
static void set_recv_timeout_ms(int sock, int ms)
{
    struct timeval tv = {
        .tv_sec = ms / 1000,
        .tv_usec = (ms % 1000) * 1000,
    };
    if (setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv)) != 0) {
        printf("EX04-WARN setsockopt(SO_RCVTIMEO,%dms) failed errno=%d (%s)\r\n",
               ms, errno, strerror(errno));
    }
}

static void sockaddr_to_str(const struct sockaddr_in *sa, char *out, size_t outlen)
{
    char ip[16];
    inet_ntop(AF_INET, &sa->sin_addr, ip, sizeof(ip));
    snprintf(out, outlen, "%s:%u", ip, (unsigned)ntohs(sa->sin_port));
}

/* --------------------------- 核心动作：echo -------------------------------
 * 教学点 3（recvfrom 来源判断）落在这里：
 * 回显目的地 = recvfrom 给我们的那个 src，而不是任何硬编码地址。
 * 固件自己都不知道对端是 SLIRP NAT 后面的哪条映射——只有内核知道。 */

static void udp_echo_one(int sock, const uint8_t *buf, ssize_t len,
                         const struct sockaddr_in *src, char tag, uint32_t seq)
{
    ssize_t sn = sendto(sock, buf, len, 0,
                        (const struct sockaddr *)src, sizeof(*src));
    if (sn < 0) {
        printf("EX04-ECHOERR tag=%c seq=%u sendto errno=%d (%s)\r\n",
               tag, (unsigned)seq, errno, strerror(errno));
        return;
    }
    if (tag == 'H') {
        g_st.echoed_h++;
        if (g_st.echoed_h <= ECHO_PRINT_MAX) {
            char srcstr[24];
            sockaddr_to_str(src, srcstr, sizeof(srcstr));
            printf("EX04-ECHO n=%" PRIu64 " from=%s len=%d seq=%u -> echoed\r\n",
                   (unsigned long long)g_st.echoed_h, srcstr, (int)len,
                   (unsigned)seq);
        }
    }
}

/* ---------------------- 出向探测：一次真实的往返 ---------------------------
 * 教学点 2 与 4 都在这里体现：
 *  - 对端是 10.0.2.2:<port>，sendto 自带目的地址（无连接，不用先 connect）；
 *  - 每包独立等待 SO_RCVTIMEO 窗口；窗口内每收到一个非本探针的数据报
 *    （例如宿主正在跑 send.py），顺手按入向规则处理，单线程也不停摆；
 *  - 窗口耗尽仍没等到匹配 seq 的回声 → 记 LOST。这就是 UDP 下应用层
 *    感知丢包的全部手段：序号 + 自己的定时器，协议栈零提示。 */

typedef struct {
    long long min_us, max_us, sum_us;
    int sent, ok, lost;
} phase_rtt_t;

static void run_outbound_phase(int sock, char tag, uint16_t dst_port,
                               const char *mode, uint64_t *okc,
                               uint64_t *lostc, uint64_t *corruptc)
{
    struct sockaddr_in dst = {
        .sin_family = AF_INET,
        .sin_port   = htons(dst_port),
    };
    inet_pton(AF_INET, GATEWAY_IP_STR, &dst.sin_addr);

    static uint8_t tx[RX_BUF_LEN], rx[RX_BUF_LEN];
    const size_t plen = 64;
    phase_rtt_t r = { .min_us = 0, .max_us = 0 };

    printf("EX04-PHASE mode=%s target=%s:%u n=%d interval_ms=%d timeout_ms=%d\r\n",
           mode, GATEWAY_IP_STR, dst_port, PROBE_N, PROBE_INTERVAL_MS,
           RECV_TIMEOUT_MS);

    for (uint32_t i = 0; i < PROBE_N; i++) {
        build_probe(tx, plen, tag, i);
        r.sent++;
        printf("EX04-TX mode=%s seq=%u dst=%s:%u len=%d\r\n", mode,
               (unsigned)i, GATEWAY_IP_STR, dst_port, (int)plen);

        int64_t t0 = esp_timer_get_time();
        ssize_t sn = sendto(sock, tx, plen, 0,
                            (const struct sockaddr *)&dst, sizeof(dst));
        if (sn < 0) {
            printf("EX04-TXFAIL mode=%s seq=%u sendto errno=%d (%s)\r\n",
                   mode, (unsigned)i, errno, strerror(errno));
            (*lostc)++;
            r.lost++;
            vTaskDelay(pdMS_TO_TICKS(PROBE_INTERVAL_MS));
            continue;
        }

        /* 等待回声：绝对截止时刻由应用自管，SO_RCVTIMEO 按剩余时间切片设置。
         * （先整体设满窗口再被动等也行，但切片法可在等待中继续服务别的流量。） */
        bool matched = false;
        int64_t deadline = t0 + (int64_t)RECV_TIMEOUT_MS * 1000;
        while (!matched) {
            int remain_us = (int)(deadline - esp_timer_get_time());
            if (remain_us <= 0) {
                break;                          /* 应用层判定：此包已丢 */
            }
            set_recv_timeout_ms(sock, (remain_us + 999) / 1000);

            struct sockaddr_in src;
            socklen_t slen = sizeof(src);
            ssize_t rn = recvfrom(sock, rx, sizeof(rx), 0,
                                  (struct sockaddr *)&src, &slen);
            if (rn < 0) {
                if (errno == EAGAIN || errno == EWOULDBLOCK) {
                    continue;                   /* 切片到期，重查总截止时刻 */
                }
                printf("EX04-RXERR mode=%s recvfrom errno=%d (%s)\r\n",
                       mode, errno, strerror(errno));
                break;
            }

            hdr_t h;
            parse_hdr(rx, rn, &h);
            if (h.valid && h.seq == i && h.tag == tag && rn == (ssize_t)plen &&
                memcmp(rx, tx, plen) == 0) {
                long long rtt = esp_timer_get_time() - t0;
                (*okc)++;
                r.ok++;
                r.sum_us += rtt;
                if (r.min_us == 0 || rtt < r.min_us) {
                    r.min_us = rtt;
                }
                if (rtt > r.max_us) {
                    r.max_us = rtt;
                }
                char srcstr[24];
                sockaddr_to_str(&src, srcstr, sizeof(srcstr));
                printf("EX04-RX mode=%s seq=%u from=%s len=%d rtt_us=%lld digest=OK\r\n",
                       mode, (unsigned)i, srcstr, (int)rn, (long long)rtt);
                matched = true;
            } else if (h.valid && h.tag == 'H') {
                /* 等待期间混进的宿主入向流量：照常服务（单线程不停摆的关键） */
                udp_echo_one(sock, rx, rn, &src, h.tag, h.seq);
            } else {
                /* 同 tag 但内容不符 = 数据损坏；其它一律按垃圾/短包计 */
                if (h.valid && h.tag == tag) {
                    (*corruptc)++;
                    printf("EX04-CORRUPT mode=%s seq=%u rx_len=%d want=%d\r\n",
                           mode, (unsigned)i, (int)rn, (int)plen);
                } else {
                    g_st.rx_total++;
                    g_st.rx_short++;
                }
            }
        }

        if (!matched) {
            (*lostc)++;
            r.lost++;
            printf("EX04-LOSS mode=%s seq=%u 无回声超过 %dms —— "
                   "应用层定时器判丢（协议栈不会有任何通知）\r\n",
                   mode, (unsigned)i, RECV_TIMEOUT_MS);
        }
        vTaskDelay(pdMS_TO_TICKS(PROBE_INTERVAL_MS));
    }

    long long avg = r.ok ? r.sum_us / r.ok : 0;
    printf("EX04-LOOPSUM mode=%s target=%s:%u sent=%d ok=%d lost=%d corrupt=%"
           PRIu64 " loss_pct=%.1f rtt_avg_us=%lld rtt_min_us=%lld rtt_max_us=%lld\r\n",
           mode, GATEWAY_IP_STR, dst_port, r.sent, r.ok, r.lost, *corruptc,
           r.sent ? 100.0 * r.lost / r.sent : 0.0, avg, r.min_us, r.max_us);
}

/* ------------------------------ bring-up ---------------------------------- */

static void ip_event_handler(void *arg, esp_event_base_t base,
                             int32_t event_id, void *event_data)
{
    ip_event_got_ip_t *evt = (ip_event_got_ip_t *)event_data;
    snprintf(s_guest_ip_str, sizeof(s_guest_ip_str), IPSTR, IP2STR(&evt->ip_info.ip));
    ESP_LOGI(TAG, "GOT_IP: %s", s_guest_ip_str);
    xSemaphoreGive(s_got_ip);
}

static void eth_event_handler(void *arg, esp_event_base_t base,
                              int32_t event_id, void *event_data)
{
    ESP_LOGI(TAG, "ETH_EVENT id=%ld", (long)event_id);
}

void app_main(void)
{
    ESP_LOGI(TAG, "== ex04 udp-echo-bidir / 单一 socket 层 / 双向路径 ==");

    /* 骨架纪律：esp_netif_init() 必须是第一句网络调用（tcpip 邮箱由它创建），
     * 之后才允许创建任何 socket/netconn。 */
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    s_got_ip = xSemaphoreCreateBinary();

    esp_netif_config_t netif_cfg = ESP_NETIF_DEFAULT_ETH();
    esp_netif_t *eth_netif = esp_netif_new(&netif_cfg);

    eth_mac_config_t mac_cfg = ETH_MAC_DEFAULT_CONFIG();
    eth_phy_config_t phy_cfg = ETH_PHY_DEFAULT_CONFIG();
    phy_cfg.reset_gpio_num = -1;                 /* 虚拟 PHY 无复位脚 */
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

    printf("EX04-FACT build_time=%s guest_ip=%s app_port=%d ext_echo_port=%d "
           "probe_n=%d recv_timeout_ms=%d api=socket\r\n",
           __TIME__, s_guest_ip_str, APP_UDP_PORT, EXT_ECHO_PORT,
           PROBE_N, RECV_TIMEOUT_MS);

    /* ---- 建 socket：bind 固定端口是 hostfwd 能投递的前提 ---- */
    int sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (sock < 0) {
        printf("EX04-FATAL socket() errno=%d (%s)\r\n", errno, strerror(errno));
        return;
    }
    int one = 1;
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    struct sockaddr_in local = {
        .sin_family      = AF_INET,
        .sin_port        = htons(APP_UDP_PORT),     /* 教学点 1：固定 bind */
        .sin_addr.s_addr = htonl(INADDR_ANY),
    };
    if (bind(sock, (struct sockaddr *)&local, sizeof(local)) != 0) {
        printf("EX04-FATAL bind(:%d) errno=%d (%s)\r\n",
               APP_UDP_PORT, errno, strerror(errno));
        return;
    }
    set_recv_timeout_ms(sock, RECV_TIMEOUT_MS);    /* 教学点 4：不设就是永锁隐患 */
    printf("$$$ EX04READY port=%d mode=udp-echo tag_h=ECHO tags_ab=INTERNAL\r\n",
           APP_UDP_PORT);

    /* ---- 出向路径先行取证（此后进入纯服务循环）----
     * 注意两点：
     *  - 本 socket 已 bind :8230，因此外发包源端口也是 8230，两条出向路径的
     *    回声都会自然回到同一个 fd 上，无需第二个 socket；
     *  - 探针丢失不影响继续运行：LOST 只是统计，这正是无连接语义的容错边界。 */
    run_outbound_phase(sock, 'A', APP_UDP_PORT, "self-loop",
                       &g_st.self_ok, &g_st.self_lost, &g_st.self_corrupt);
    run_outbound_phase(sock, 'B', EXT_ECHO_PORT, "ext-srv",
                       &g_st.ext_ok, &g_st.ext_lost, &g_st.ext_corrupt);

    printf("EX04-PHASE mode=inbound-service note=\"此后 :%d 进入常驻 echo，"
           "宿主 tools/send.py 可随时打入\"\r\n", APP_UDP_PORT);

    /* ---- 常驻 echo 服务 + 周期统计（QEMU 由外部精确 kill 结束）---- */
    static uint8_t rx[RX_BUF_LEN];
    for (;;) {
        struct sockaddr_in src;
        socklen_t slen = sizeof(src);
        ssize_t rn = recvfrom(sock, rx, sizeof(rx), 0,
                              (struct sockaddr *)&src, &slen);
        if (rn < 0) {
            /* SO_RCVTIMEO 到期（EAGAIN）：不是错误，是无流量。空转一段时间后
             * 打一行统计，证明服务还活着（机器可读，便于 CI 轮询）。 */
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                static int idle_ticks;
                if (++idle_ticks >= STATS_PERIOD_S * 1000 / RECV_TIMEOUT_MS) {
                    idle_ticks = 0;
                    printf("EX04-ST rx_total=%llu echoed_h=%llu rx_short=%llu "
                           "self_ok=%llu self_lost=%llu ext_ok=%llu ext_lost=%llu "
                           "uptime_s=%lld\r\n",
                           (unsigned long long)g_st.rx_total,
                           (unsigned long long)g_st.echoed_h,
                           (unsigned long long)g_st.rx_short,
                           (unsigned long long)g_st.self_ok,
                           (unsigned long long)g_st.self_lost,
                           (unsigned long long)g_st.ext_ok,
                           (unsigned long long)g_st.ext_lost,
                           (long long)(esp_timer_get_time() / 1000000));
                }
                continue;
            }
            printf("EX04-RXERR recvfrom errno=%d (%s)\r\n", errno, strerror(errno));
            continue;
        }

        g_st.rx_total++;
        hdr_t h;
        if (!parse_hdr(rx, rn, &h)) {
            g_st.rx_short++;
            char srcstr[24];
            sockaddr_to_str(&src, srcstr, sizeof(srcstr));
            printf("EX04-SHORT from=%s len=%d rx_total=%llu（非 EX04 协议，仅计数）\r\n",
                   srcstr, (int)rn, (unsigned long long)g_st.rx_total);
            continue;
        }
        if (h.tag == 'H') {
            udp_echo_one(sock, rx, rn, &src, h.tag, h.seq);
        } else {
            /* 'A'/'B' 探针迟到（本轮窗口外才回来）：只计数，绝不转发。
             * 若在这里也 sendto 回去，等于把回声当成新请求——无限放大。 */
            printf("EX04-LATE tag=%c seq=%u len=%d （迟到的探针回声，不再转发）\r\n",
                   h.tag, (unsigned)h.seq, (int)rn);
        }
    }
}
