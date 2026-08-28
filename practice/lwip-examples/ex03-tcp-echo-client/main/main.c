/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * lwIP 示例工程 ex03：TCP 回显客户端（socket API 层模板）
 *
 * guest（10.0.2.15，QEMU openeth + SLIRP）主动外连宿主机 loopback：
 *
 *   场景 A  REFUSED  -> 10.0.2.2:8225   宿主无进程监听：connect 拒绝分支
 *   场景 B  TIMEOUT  -> 10.0.2.2:8221   服务器接了不回话：SO_RCVTIMEO 超时分支
 *   场景 C  RESET    -> 10.0.2.2:8222   服务器读到首条消息后 RST 掐线：ECONNRESET 分支
 *   场景 D  ECHO     -> 10.0.2.2:8220   正常路径：N 条编号消息往返 + Fletcher-16
 *                                        digest 校验 + 半关闭(shutdown)优雅收尾
 *
 * 错误账本纪律（ch16 方法学）：每个失败分支必须打印 rc/errno/符号名/strerror 与
 * 耗时，以真实测量为准；lwIP socket 层的 errno 语义与 Linux 有出入的地方在注释与
 * README 里明说，禁止凭 Linux 经验臆断。
 *
 * 教学锚点（对应源码位置）：
 *   - ERR_RST -> ECONNRESET 的映射来自 ~/esp/esp-idf/components/lwip/lwip/src/api/err.c
 *     的 err_to_errno_table[]——表里没有独立的 ECONNREFUSED 条目，所以「对端拒绝」
 *     在 lwIP 上不会原样浮现（Linux 上是 111/ECONNREFUSED）。
 *   - SO_RCVTIMEO 到期把阻塞 recv 打断为 -1/EAGAIN：err.c 表中 ERR_TIMEOUT(-3)
 *     映射 EWOULDBLOCK（newlib 里 ==EAGAIN），本环境实测 errno=11。
 *   - LWIP_SO_RCVTIMEO=1 在 IDF port 里硬编码
 *     （~/esp/esp-idf/components/lwip/port/include/lwipopts.h），无需 Kconfig 打开。
 *
 * 运行环境：ESP-IDF v6.0.2 + qemu-system-xtensa (Espressif fork)，-nic user,model=open_eth。
 * 宿主端配合脚本：tools/listener.py（echo/silent/reset 三模式）。
 */

#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"

#include "esp_eth.h"
#include "esp_event.h"
#include "esp_idf_version.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_timer.h"

#include "lwip/inet.h" /* htons / PP_HTONL / LWIP_MAKEU32 */
#include "lwip/sockets.h"

static const char *TAG = "ex03";

/* ------------------------------ 常量 ------------------------------ */

#define HOST_IP_OCTET1 10 /* SLIRP 网关 = 宿主机 loopback */
#define HOST_IP_OCTET2 0
#define HOST_IP_OCTET3 2
#define HOST_IP_OCTET4 2
/* 函数式宏的实参在展开前不分词，所以 IP 四段必须逐个传入（C-10 纪律） */
#define HOST_IP_CONNECT() \
    dst.sin_addr.s_addr = PP_HTONL(LWIP_MAKEU32(HOST_IP_OCTET1, HOST_IP_OCTET2, HOST_IP_OCTET3, HOST_IP_OCTET4))

/* 端口取自 ex03 号段 8220~8229：+0 主服务 / +1 辅助 / 其余保留（SPEC §4） */
#define PORT_ECHO   8220 /* 主服务槽：正常回显       */
#define PORT_SILENT 8221 /* 辅助槽：accept 后静默     */
#define PORT_RESET  8222 /* 保留槽：读一条后 RST 断连 */
#define PORT_DEAD   8225 /* 保留槽：宿主永不监听      */

#define MSG_LEN        256 /* 单条消息字节数                  */
#define N_MSG          8   /* 正常路径消息条数                */
#define RECV_TIMEOUT_S 3   /* 场景 B 的 SO_RCVTIMEO           */
#define SAFETY_RCvTO_S 10  /* 场景 C/D 兜底超时（防长挂）     */

/* 固定时刻表（相对 bring-up 完成的毫秒数）：给操作者在对端换监听模式留窗口；
 * 用 tools/listener.py --all 一口气起全三个端口时无需任何中途干预。 */
#define T_PHASE_A_MS 6000
#define T_PHASE_B_MS 14000
#define T_PHASE_C_MS 26000
#define T_PHASE_D_MS 30000

#define DHCP_TIMEOUT_MS 15000

/* --------------------------- 工具函数 ---------------------------- */

static int64_t now_ms(void)
{
    return esp_timer_get_time() / 1000;
}

/* 绝对时刻等待；被前一阶段超支时不许把负数塞进 vTaskDelay（会变成超长睡眠） */
static void wait_until_ms(int64_t abs_ms)
{
    int64_t remain = abs_ms - now_ms();
    vTaskDelay(pdMS_TO_TICKS((uint32_t)(remain > 1 ? remain : 1)));
}

/* Fletcher-16 校验累加器：与 tools/listener.py、ch6 接收器同一算法，
 * 用于「应用层字节流是否完整无损」的双端对账。 */
struct fletcher {
    uint16_t s1, s2;
};

static void fletcher_update(struct fletcher *f, const uint8_t *p, size_t n)
{
    for (size_t i = 0; i < n; i++) {
        f->s1 = (uint16_t)((f->s1 + p[i]) % 255);
        f->s2 = (uint16_t)((f->s2 + f->s1) % 255);
    }
}

static uint16_t fletcher_digest(const struct fletcher *f)
{
    return (uint16_t)((f->s2 << 8) | f->s1);
}

/* errno 符号名速查（newlib 值域，非 Linux 值域！详见 README 对照表）。
 * 关键差异先记两条：ECONNABORTED=113、ENOTCONN=128 都和 Linux 不同。 */
static const char *err_name(int e)
{
    switch (e) {
    case EINTR:
        return "EINTR";
    case EAGAIN:
        return "EAGAIN/EWOULDBLOCK";
    case EPIPE:
        return "EPIPE";
    case ECONNRESET:
        return "ECONNRESET";
    case ECONNREFUSED:
        return "ECONNREFUSED";
    case ECONNABORTED:
        return "ECONNABORTED";
    case EHOSTUNREACH:
        return "EHOSTUNREACH";
#ifdef EHOSTDOWN
    case EHOSTDOWN:
        return "EHOSTDOWN";
#endif
    case ETIMEDOUT:
        return "ETIMEDOUT";
    case ENOTCONN:
        return "ENOTCONN";
    default:
        return "?";
    }
}

/* 打固定长度的确定性消息体：序号前缀 + 可复现填充图案。digest 能对上的前提是
 * 双端字节流完全一致——消息由 guest 构造、宿主只负责原样回显。 */
static void build_msg(char *buf, unsigned seq, unsigned total)
{
    int off = snprintf(buf, MSG_LEN, "ex03 msg seq=%03u/%03u pad=", seq, total);
    while (off < MSG_LEN - 1) {
        unsigned pat = ((unsigned)off * 7u + seq * 13u) % 26u;
        buf[off] = (char)('A' + pat);
        off++;
    }
    buf[MSG_LEN - 1] = '\n';
}

/* send 全量循环：send() 返回值只是「已排入本机发送缓冲」的字节数，不是对端确认 */
static int send_full(int fd, const char *buf, size_t len)
{
    size_t got = 0;
    while (got < len) {
        ssize_t n = send(fd, buf + got, len - got, 0);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        got += (size_t)n;
    }
    return 0;
}

/* recv 全量循环：TCP 是字节流，一次 recv 不能保证拿齐一条消息 */
static ssize_t recv_exact(int fd, char *buf, size_t len)
{
    size_t got = 0;
    while (got < len) {
        ssize_t n = recv(fd, buf + got, len - got, 0);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1; /* 失败路径，errno 记录原因 */
        }
        if (n == 0) {
            return got > 0 ? (ssize_t)got : 0; /* 对端 FIN：EOF */
        }
        got += (size_t)n;
    }
    return (ssize_t)got;
}

/* 建立 TCP 连接并全程留痕（教学点：connect 的三种归宿——成功 / 立即被拒 /
 * 一直没人应答直到内核放弃，各自落在哪个 errno 上见 run.log 实测）。 */
static int tcp_connect(uint16_t port, int64_t *elapsed_ms_out)
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        printf("EX03-ERR socket() fail errno=%d(%s)\n", errno,
               strerror(errno));
        return -1;
    }

    struct sockaddr_in dst = {
        .sin_family = AF_INET,
        .sin_port   = htons(port),
    };
    HOST_IP_CONNECT();

    int64_t t0 = esp_timer_get_time();
    int rc = connect(fd, (struct sockaddr *)&dst, sizeof(dst));
    double el_ms = (double)(esp_timer_get_time() - t0) / 1000.0;

    if (rc != 0) {
        /* 教学点：这里的 errno 取决于 SLIRP 是否立刻代答 RST——Linux 教科书
         * 说该情形是 ECONNREFUSED(111)，lwIP 上未必如此，实测落点见 README。 */
        printf("EX03-CONNECT-DENY port=%u rc=%d errno=%d(%s:%s) "
               "elapsed_ms=%.1f\n",
               port, rc, errno, err_name(errno), strerror(errno), el_ms);
        close(fd);
        return -1;
    }
    if (elapsed_ms_out) {
        *elapsed_ms_out = (int64_t)(el_ms / 1);
    }
    printf("EX03-CONNECT-OK port=%u elapsed_ms=%.1f fd=%d\n", port, el_ms,
           fd);
    return fd;
}

static void arm_rcvtimeo(int fd, long sec)
{
    struct timeval tv = { .tv_sec = sec, .tv_usec = 0 };
    int rc = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    if (rc != 0) {
        printf("EX03-SOCKOPT SO_RCVTIMEO=%lds fd=%d rc=%d errno=%d(%s)\n",
               sec, fd, rc, errno, strerror(errno));
    } else {
        printf("EX03-SOCKOPT SO_RCVTIMEO=%lds fd=%d rc=0\n", sec, fd);
    }
}

/* ------------------------------ 场景 ------------------------------ */

/* 场景 A：宿主 8225 无进程监听 → SLIRP 代答 RST → connect 硬失败。
 * 教学点：lwIP err.c 没有 ECONNREFUSED 映射条目，「拒绝」由 ERR_RST 承载，
 * 所以 socket 层看到的多半不是教科书里的 111，而可能是别的值。 */
static bool phase_refused(void)
{
    printf("EX03-PHASE name=REFUSED target=10.0.2.2:%u expect=connect-deny\n",
           PORT_DEAD);
    int fd = tcp_connect(PORT_DEAD, NULL); /* 打出 DENY 行即本场景正解 */
    bool pass = (fd < 0);
    printf("EX03-RES phase=REFUSED status=%s%s\n", pass ? "PASS" : "FAIL",
           pass ? ""
                : " unexpected-success -- someone is listening there?");
    if (fd >= 0) {
        close(fd);
    }
    return pass;
}

/* 场景 B：silent 监听器 accept 后一言不发 → 阻塞 recv 被 SO_RCVTIMEO 打断为
 * -1/EAGAIN（本环境实测 errno=11）。连续两次证明行为可重入，之后 close 收场。 */
static bool phase_timeout(void)
{
    printf("EX03-PHASE name=TIMEOUT target=10.0.2.2:%u expect=EAGAIN x2\n",
           PORT_SILENT);
    int64_t conn_ms = 0;
    int fd = tcp_connect(PORT_SILENT, &conn_ms);
    if (fd < 0) {
        printf("EX03-RES phase=TIMEOUT status=FAIL reason=no-connection\n");
        return false;
    }
    arm_rcvtimeo(fd, RECV_TIMEOUT_S);

    char buf[64];
    bool pass = true;
    for (int k = 1; k <= 2; k++) {
        int64_t t0 = esp_timer_get_time();
        ssize_t n = recv(fd, buf, sizeof(buf), 0);
        int64_t el_ms = (esp_timer_get_time() - t0) / 1000;
        int e = errno;
        /* 判定必须用宏名而不是字面量 11：EWOULDBLOCK 在 newlib 里就是 EAGAIN */
        bool timed_out =
            (n < 0 && e == EWOULDBLOCK && el_ms >= RECV_TIMEOUT_S * 900);
        printf("EX03-TIMEOUT hit#%d n=%lld errno=%d(%s:%s) elapsed_ms=%lld "
               "%s\n",
               k, (long long)n, e, err_name(e), strerror(e),
               (long long)el_ms, timed_out ? "-> EAGAIN branch taken"
                                           : "-> UNEXPECTED");
        pass &= timed_out;
    }
    close(fd); /* 无在途数据，close 即发 FIN 干净离场 */
    printf("EX03-RES phase=TIMEOUT status=%s conn_ms=%lld\n",
           pass ? "PASS" : "FAIL", (long long)conn_ms);
    return pass;
}

/* 场景 C：reset 监听器读完第一条消息后用 SO_LINGER(1,0)+close 发 RST 掐线。
 * 客户端正等回显时收到的是硬复位而非 FIN——对照场景 D 收尾时的 0 字节 EOF，
 * 这正是「FIN 优雅 vs RST 暴力」的教学对照点。 */
static bool phase_reset(void)
{
    printf("EX03-PHASE name=RESET target=10.0.2.2:%u expect=ECONNRESET\n",
           PORT_RESET);
    int fd = tcp_connect(PORT_RESET, NULL);
    if (fd < 0) {
        printf("EX03-RES phase=RESET status=FAIL reason=no-connection\n");
        return false;
    }
    arm_rcvtimeo(fd, SAFETY_RCvTO_S);

    static char msg[MSG_LEN];
    build_msg(msg, 1, 0);
    struct fletcher fx = { 0 };
    if (send_full(fd, msg, sizeof(msg)) != 0) {
        printf("EX03-RES phase=RESET status=FAIL reason=send errno=%d(%s)\n",
               errno, strerror(errno));
        close(fd);
        return false;
    }
    fletcher_update(&fx, (const uint8_t *)msg, sizeof(msg));
    printf("EX03-SENT port=%u msg_len=%d digest_sent=%04x "
           "now-waiting-for-echo\n",
           PORT_RESET, MSG_LEN, fletcher_digest(&fx));

    static char echo[MSG_LEN];
    int64_t t0 = esp_timer_get_time();
    ssize_t n = recv(fd, echo, sizeof(echo), 0);
    int64_t el_ms = (esp_timer_get_time() - t0) / 1000;
    int e = errno;

    bool pass;
    if (n < 0 && e == ECONNRESET) {
        /* 教学点：对 recv 而言 FIN 给 0（EOF），RST 给 -1+ECONNRESET。
         * 数据确实送达过对端应用层（对方读完了），掐线发生在之后——这是
         * 「中途断开」的典型形态，也是重试策略必须处理的错误类别。 */
        printf("EX03-RST n=-1 errno=%d(%s:%s) waited_ms=%lld -> connection "
               "killed by peer AFTER server consumed our message\n",
               e, err_name(e), strerror(e), (long long)el_ms);
        pass = true;
    } else if (n == 0) {
        printf("EX03-EOF-BUT-WANT-RST n=0 waited_ms=%lld (peer did graceful "
               "close instead of reset)\n",
               (long long)el_ms);
        pass = false;
    } else {
        printf("EX03-RST-UNEXPECTED n=%lld errno=%d(%s) waited_ms=%lld\n",
               (long long)n, e, err_name(e), (long long)el_ms);
        pass = false;
    }
    close(fd); /* 已被 RST，close 只是回收 fd */
    printf("EX03-RES phase=RESET status=%s\n", pass ? "PASS" : "FAIL");
    return pass;
}

/* 场景 D（正常路径主干）：N 条编号消息逐条 request/response，双端 Fletcher-16
 * 对账；结束后 shutdown(SHUT_WR) 半关闭 + drain 到 EOF + close——全周期
 * connect/write/read/shutdown/close 完整演示。 */
static bool phase_echo(void)
{
    printf("EX03-PHASE name=ECHO target=10.0.2.2:%u msgs=%d len=%d "
           "expect=digest-match\n",
           PORT_ECHO, N_MSG, MSG_LEN);

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in dst = {
        .sin_family = AF_INET,
        .sin_port   = htons(PORT_ECHO),
    };
    HOST_IP_CONNECT();
    if (connect(fd, (struct sockaddr *)&dst, sizeof(dst)) != 0) {
        printf("EX03-RES phase=ECHO status=FAIL reason=connect errno=%d(%s)\n",
               errno, strerror(errno));
        close(fd);
        return false;
    }
    printf("EX03-CONNECT-OK port=%u fd=%d\n", PORT_ECHO, fd);
    arm_rcvtimeo(fd, SAFETY_RCvTO_S); /* 兜底，正常永远触发不到 */

    static char msg[MSG_LEN];
    static char echo[MSG_LEN];
    struct fletcher sent_fx = { 0 }, recv_fx = { 0 };

    double rtt_sum = 0.0, rtt_min = 1e9, rtt_max = 0.0;
    for (unsigned seq = 1; seq <= N_MSG; seq++) {
        build_msg(msg, seq, N_MSG);
        fletcher_update(&sent_fx, (const uint8_t *)msg, sizeof(msg));

        int64_t t0 = esp_timer_get_time();
        if (send_full(fd, msg, sizeof(msg)) != 0) {
            printf("EX03-ECHO-FAIL seq=%u stage=send errno=%d(%s:%s)\n", seq,
                   errno, err_name(errno), strerror(errno));
            close(fd);
            return false;
        }
        ssize_t n = recv_exact(fd, echo, sizeof(echo));
        int64_t rtt_ms = (esp_timer_get_time() - t0) / 1000;

        if (n < 0) {
            printf("EX03-ECHO-FAIL seq=%u stage=recv errno=%d(%s:%s)\n", seq,
                   errno, err_name(errno), strerror(errno));
            close(fd);
            return false;
        }
        if ((size_t)n != sizeof(msg)) {
            printf("EX03-ECHO-FAIL seq=%u stage=length got=%lld want=%d "
                   "(peer closed early?)\n",
                   seq, (long long)n, MSG_LEN);
            close(fd);
            return false;
        }
        fletcher_update(&recv_fx, (const uint8_t *)echo, (size_t)n);

        bool identical = (memcmp(msg, echo, MSG_LEN) == 0);
        rtt_sum += (double)rtt_ms;
        rtt_min = rtt_ms < rtt_min ? (double)rtt_ms : rtt_min;
        rtt_max = rtt_ms > rtt_max ? (double)rtt_ms : rtt_max;

        printf("EX03-ROUND seq=%02u/%02u bytes=%d rtt_ms=%lld memcmp=%s\n",
               seq, N_MSG, MSG_LEN, (long long)rtt_ms,
               identical ? "equal" : "MISMATCH");
    }

    /* ---- 优雅关闭三步：shutdown(SHUT_WR) 发 FIN -> drain 到 EOF -> close ---- */
    printf("EX03-CLOSE graceful: shutdown(SHUT_WR) -> drain until EOF\n");
    int rc = shutdown(fd, SHUT_WR); /* 半关闭：我不再写，仍可读残余数据 */
    if (rc != 0) {
        printf("EX03-CLOSE shutdown rc=%d errno=%d(%s)\n", rc, errno,
               strerror(errno));
    } else {
        printf("EX03-CLOSE shutdown rc=0 (FIN queued)\n");
    }

    static char tail[128];
    ssize_t n;
    unsigned long extra = 0;
    while ((n = recv(fd, tail, sizeof(tail), 0)) > 0) {
        extra += (unsigned long)n; /* 正常应为 0：逐条 ping-pong 已吃干净 */
    }
    printf("EX03-CLOSE recv-final n=%lld extra_bytes=%lu (%s)\n",
           (long long)n, extra,
           n == 0 ? "clean EOF from peer FIN" : "unexpected residue/error");
    close(fd);

    uint16_t d_sent = fletcher_digest(&sent_fx);
    uint16_t d_recv = fletcher_digest(&recv_fx);
    bool match = (extra == 0 && d_sent == d_recv);
    printf("EX03-DIGEST sent=%04x received=%04x total_bytes=%d match=%s\n",
           d_sent, d_recv, N_MSG * MSG_LEN, match ? "YES" : "NO");

    printf("EX03-RES phase=ECHO status=%s rtt_avg_ms=%.1f rtt_min_ms=%.1f "
           "rtt_max_ms=%.1f\n",
           match ? "PASS" : "FAIL", rtt_sum / N_MSG, rtt_min, rtt_max);
    return match;
}

/* ------------------------- 客户端主任务 -------------------------- */

static void client_task(void *arg)
{
    int64_t base = now_ms();

    printf("$$$ EXREADY target=10.0.2.2 ports=8220:echo,8221:silent,"
           "8222:reset,8225:dead msgs=%dx%d\n",
           N_MSG, MSG_LEN);

    wait_until_ms(base + T_PHASE_A_MS);
    bool ok_a = phase_refused(); /* A 前置条件：8225 上没有任何进程 */

    wait_until_ms(base + T_PHASE_B_MS);
    bool ok_b = phase_timeout();

    wait_until_ms(base + T_PHASE_C_MS);
    bool ok_c = phase_reset();

    wait_until_ms(base + T_PHASE_D_MS);
    bool ok_d = phase_echo();

    printf("EX03-SUMMARY refused=%s timeout=%s reset=%s echo=%s\n",
           ok_a ? "PASS" : "FAIL", ok_b ? "PASS" : "FAIL",
           ok_c ? "PASS" : "FAIL", ok_d ? "PASS" : "FAIL");
    printf("$$$ EXDONE all-phases-run idling\n");

    /* KEEPALIVE：示例收尾后保持进程存活，便于继续手工做附加实验 */
    for (;;) {
        vTaskDelay(pdMS_TO_TICKS(30000));
        printf("EX03-IDLE uptime_ms=%lld\n", (long long)now_ms());
    }
}

/* ------------------------ 网络 bring-up 骨架 --------------------- */

static SemaphoreHandle_t s_got_ip;

static void eth_event_handler(void *arg, esp_event_base_t base,
                              int32_t event_id, void *event_data)
{
    if (event_id == ETHERNET_EVENT_CONNECTED) {
        ESP_LOGI(TAG, "ETH_EVENT: CONNECTED (link up)");
    } else if (event_id == ETHERNET_EVENT_DISCONNECTED) {
        ESP_LOGW(TAG, "ETH_EVENT: DISCONNECTED");
    }
}

static void ip_event_handler(void *arg, esp_event_base_t base,
                             int32_t event_id, void *event_data)
{
    ip_event_got_ip_t *evt = (ip_event_got_ip_t *)event_data;
    ESP_LOGI(TAG, "GOT_IP: " IPSTR, IP2STR(&evt->ip_info.ip));
    xSemaphoreGive(s_got_ip);
}

void app_main(void)
{
    ESP_LOGI(TAG, "== ex03: openeth bring-up then tcp-echo-client scenarios ==");
    printf("EX03-FACT built=\"%s %s\" idf_version=%s\n", __DATE__, __TIME__,
           esp_get_idf_version());

    /* 步序契约：esp_netif_init 必须是第一句网络调用——socket 创建都得排在它
     * 后面（tcpip 邮箱此时才存在，次序颠倒会 assert 复位）。 */
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    s_got_ip = xSemaphoreCreateBinary();

    esp_netif_config_t netif_cfg = ESP_NETIF_DEFAULT_ETH();
    esp_netif_t *eth_netif = esp_netif_new(&netif_cfg);

    eth_mac_config_t mac_cfg = ETH_MAC_DEFAULT_CONFIG();
    eth_phy_config_t phy_cfg = ETH_PHY_DEFAULT_CONFIG();
    phy_cfg.reset_gpio_num      = -1; /* 虚拟 PHY 没有复位脚 */
    phy_cfg.autonego_timeout_ms = 3000;

    esp_eth_mac_t *mac = esp_eth_mac_new_openeth(&mac_cfg);
    assert(mac != NULL);
    esp_eth_phy_t *phy = esp_eth_phy_new_generic(&phy_cfg);
    assert(phy != NULL);

    esp_eth_config_t eth_cfg = ETH_DEFAULT_CONFIG(mac, phy);
    esp_eth_handle_t eth_handle = NULL;
    ESP_ERROR_CHECK(esp_eth_driver_install(&eth_cfg, &eth_handle));

    ESP_ERROR_CHECK(esp_event_handler_register(
        ETH_EVENT, ETHERNET_EVENT_CONNECTED, &eth_event_handler, NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_ETH_GOT_IP,
                                               &ip_event_handler, NULL));

    esp_eth_netif_glue_handle_t glue = esp_eth_new_netif_glue(eth_handle);
    ESP_ERROR_CHECK(esp_netif_attach(eth_netif, glue));

    ESP_ERROR_CHECK(esp_eth_start(eth_handle));
    ESP_LOGI(TAG, "waiting for DHCP lease ...");

    if (xSemaphoreTake(s_got_ip, pdMS_TO_TICKS(DHCP_TIMEOUT_MS)) != pdTRUE) {
        ESP_LOGE(TAG, "DHCP timeout -- check QEMU -nic user,model=open_eth");
        return;
    }

    /* 业务任务：优先级压在 tcpip(18)/emac_rx(15) 之下即可（事务型小流量） */
    xTaskCreate(client_task, "ex03cli", 6144, NULL, 5, NULL);
}
