/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * lwIP 示例工程 ex09：TLS 客户端模板（socket API 之上的 esp-tls 层）
 *
 * 主线（PHASE-A 外环）：guest（10.0.2.15，QEMU openeth + SLIRP）连宿主机
 * openssl s_server（tools/run_sserver.sh 一键生成自签证书并启动）：
 *   握手：esp_tls_conn_new_sync("10.0.2.2", 8280)，跳过证书验证（自签证书，
 *         生产升级到 CA 固定/pinning 的路径见下方 tls_attempt_outer() 注释）；
 *   应用层：握手成功后写一条 GET 式探针行（s_server -rev 按行反转回放），
 *         随后必须在 APP_REPLY_TIMEOUT_MS 内得到至少 1 字节应用记录。
 *   ※ 本环境实测外环悬案高发：三次尝试里握手全部成功、首条应用记录全部等不到，
 *     见 README「已知现象与边界」——这正是示例内置超时逃生的原因。
 *
 * 替代路径（PHASE-B 回环自连）：外环悬案命中时用于隔离问题域——guest 内部起一个
 * esp-tls TLS echo 服务端（127.0.0.1:8281，内嵌自签证书），再用同一套客户端代码
 * 自连。回环能完整走通"握手+应用记录往返"，即可证明 guest 协议栈与 esp-tls 本身
 * 无辜，把僵死定位在 SLIRP 外环边界上（ch22 用同款思路取证：kernel ACK 但服务
 * 进程不回放，openssl/python 服务端一致）。
 *
 * 【为什么必须内置超时逃生】ch22 实测悬案①：SLIRP 外环上 TLS 握手可以正常完成，
 * 但首条应用记录可能永远等不到响应——TCP 层活着（宿主 kernel ACK 了每个 segment），
 * 服务进程却不回放数据。表现形式不是报错而是"阻塞 recv 无限挂死"，所以模板代码
 * 绝不允许裸阻塞读：一切应用记录等待都必须过 select 超时预算，超时即报告并关闭。
 *
 * 【为什么选 select 而不是 SO_RCVTIMEO】把 SO_RCVTIMEO 挂在裸 socket 上确实能把
 * 底层 lwIP recv() 打断为 EAGAIN，但该错误经 esp-tls 映射成 MBEDTLS_ERR_SSL_WANT_READ
 * 后会被上层当作"再试一次"，应用侧很容易写出忙轮询甚至漏判。select 直接在等待入口
 * 处裁决"到底要不要继续等"，语义最干净。（两种手段 README 都写了，代码取前者。）
 *
 * 内存账本（加分项）：heap 三件套 free/largest/min-ever 在握手前后各打一次快照，
 * 峰值用 min-ever 阶段差兜底——口径照搬 ch22（CONVENTIONS Batch 6：「阶段前后差 +
 * 周期采样窗 min 双指标」「min-ever 是全局单调量，跨阶段取差会失真」，README 有展开）。
 *
 * 运行环境：ESP-IDF v6.0.2 + qemu-system-xtensa (Espressif fork)，
 *           -nic user,model=open_eth（无 hostfwd，本示例只有 guest 出向流量）。
 * 宿主端配合脚本：tools/run_sserver.sh（一键生成自签证书并启动 openssl s_server）。
 */

#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>

#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"

#include "esp_eth.h"
#include "esp_eth_mac_openeth.h"
#include "esp_event.h"
#include "esp_heap_caps.h"
#include "esp_idf_version.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_timer.h"
#include "esp_tls.h"

#include <sys/select.h>
#include "lwip/sockets.h" /* htons、close 等 lwIP socket 语义 */

#include <mbedtls/ssl.h> /* 协商结果打印（mbedtls_ssl_get_version 等） */

#include "tls_local_certs.h" /* PHASE-B 回环服务端的内嵌自签证书 */

static const char *TAG = "ex09";

/* ------------------------------ 常量 ------------------------------ */

/* 端口取自 ex09 号段 8280~8289：+0 主服务 / +1 控制或辅助（SPEC §4）。
 * SLIRP 边界事实：guest 连 10.0.2.2:P 等价于宿主机连自己的 127.0.0.1:P，
 * 因此出连宿主 8280 无需任何 hostfwd；8281 只活在 guest 内部。 */
#define HOST_IP_STR    "10.0.2.2"
#define PORT_TLS       8280
#define PORT_LOCAL_TLS 8281

#define N_OUTER_ATTEMPTS     3   /* 多轮连接：验证可重入并统计悬案复现率 */
#define N_LOCAL_ATTEMPTS     2   /* 回环变体同样可重入                   */
#define TLS_HS_TIMEOUT_MS    10000 /* TCP 连接 + TLS 握手的总超时（esp-tls 自带） */
#define APP_REPLY_TIMEOUT_MS 8000  /* 首条应用记录等待预算 = 逃生舱口 */
#define SETTLE_GAP_MS        800   /* 两轮尝试之间的静默间隔 */
#define DHCP_TIMEOUT_MS      15000

/* GET 式探针行：单行且以 \n 结尾（s_server -rev 攒到 \n 才回放一条反转记录） */
static char g_probe[64];
static int  g_probe_len;

/* --------------------------- 工具函数 ---------------------------- */

static int64_t now_ms(void)
{
    return esp_timer_get_time() / 1000;
}

/* heap 三件套快照（内存账本口径引用 ch22）：free=当前空闲，largest=最大连续块，
 * min-ever=历史最低水位（全局单调，只降不升）。 */
static void mem_stamp(const char *tag)
{
    printf(
        "EX09-MEM tag=%-14s free=%u largest=%u min-ever=%u\n", tag,
        (unsigned)heap_caps_get_free_size(MALLOC_CAP_DEFAULT),
        (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_DEFAULT),
        (unsigned)heap_caps_get_minimum_free_size(MALLOC_CAP_DEFAULT));
}

/* 打印协商结果：协议版本 / 密码套件 / 对端证书体积。
 * 注意：skip_cert_verify 路径下对端证书可能不被解析保留（peer_cert_bytes=0 属预期）。 */
static void report_negotiated(esp_tls_t *tls)
{
    mbedtls_ssl_context *ssl = (mbedtls_ssl_context *)esp_tls_get_ssl_context(tls);
    const mbedtls_x509_crt *peer = mbedtls_ssl_get_peer_cert(ssl);
    printf("EX09-HS-OK version=%s suite=%s peer_cert_bytes=%u\n",
           mbedtls_ssl_get_version(ssl), mbedtls_ssl_get_ciphersuite(ssl),
           peer ? (unsigned)peer->raw.len : 0);
}

/* 握手失败时从 esp-tls 错误句柄里捞分类错误码（Mbed TLS 4.x 错误码已改绑 PSA） */
static void report_tls_error(esp_tls_t *tls)
{
    esp_tls_error_handle_t h = NULL;
    if (esp_tls_get_error_handle(tls, &h) != ESP_OK || h == NULL) {
        printf("EX09-HS-FAIL detail=no-error-handle\n");
        return;
    }
    int code = 0, flags = 0;
    esp_tls_get_and_clear_last_error(h, &code, &flags);
    int sys_err = 0, mb_err = 0, cert_flags = 0;
    esp_tls_get_and_clear_error_type(h, ESP_TLS_ERR_TYPE_SYSTEM, &sys_err);
    esp_tls_get_and_clear_error_type(h, ESP_TLS_ERR_TYPE_MBEDTLS, &mb_err);
    esp_tls_get_and_clear_error_type(h, ESP_TLS_ERR_TYPE_MBEDTLS_CERT_FLAGS,
                                     &cert_flags);
    printf(
        "EX09-HS-FAIL last_esp_err=0x%x tls_code=-0x%04x sys_errno=%d "
        "mb_code=-0x%04x cert_flags=0x%x\n",
        (unsigned)code, (unsigned)-code, -sys_err, (unsigned)-mb_err,
        (unsigned)cert_flags);
}

enum attempt_result {
    ATTEMPT_PASS = 0,     /* 握手 + 应用记录往返全通                */
    ATTEMPT_HANG_ESCAPED, /* 握手成功但首条应用记录超时（悬案命中） */
    ATTEMPT_HS_FAIL,      /* TCP/TLS 握手本身失败                   */
    ATTEMPT_SHORT_ECHO,   /* 有回应但字节不齐/EOF 提前              */
};

/*
 * 共享的应用记录往返：写一条 GET 探针 -> select 等待（逃生舱口）-> 读应答对账。
 *
 * 外环 -rev 的应答是逐字节反转的探针行、回环 echo 的应答是原样字节——但对账
 * 用的是 XOR 累加和（ch22 同款技巧）：异或多重集与顺序无关，反转天然免疫。
 */
static enum attempt_result tls_exchange(esp_tls_t *tls, int fd, int seq)
{
    unsigned tx_xor = 0;
    int64_t w0 = now_ms();
    ssize_t w = esp_tls_conn_write(tls, g_probe, g_probe_len);
    if (w != g_probe_len) {
        printf("EX09-WRITE-FAIL seq=%d w=%zd/%d errno=%d(%s) waited_ms=%lld\n",
               seq, w, g_probe_len, errno, strerror(errno),
               (long long)(now_ms() - w0));
        return ATTEMPT_SHORT_ECHO;
    }
    for (int i = 0; i < g_probe_len; i++) {
        tx_xor ^= (unsigned char)g_probe[i];
    }
    printf(
        "EX09-WROTE seq=%d len=%d ms=%lld -> waiting app record (budget %d ms)\n",
        seq, g_probe_len, (long long)(now_ms() - w0), APP_REPLY_TIMEOUT_MS);

    /* ---- select 等待 = 逃生舱口 ----
     * 悬案现场是"握手后永远等不到第一条应用记录"，故等待必须有硬预算；
     * select 返回 0 即判定命中并立即收手。 */
    static char rx[256];
    int64_t deadline = now_ms() + APP_REPLY_TIMEOUT_MS;
    int got = 0;
    unsigned rx_xor = 0;
    bool hang_escaped = false;
    while (got < g_probe_len) {
        int64_t remain = deadline - now_ms();
        if (remain <= 0) {
            break;
        }
        struct timeval tv = {
            .tv_sec = (long)(remain / 1000),
            .tv_usec = (long)((remain % 1000) * 1000),
        };
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(fd, &rfds);
        int nready = select(fd + 1, &rfds, NULL, NULL, &tv);
        if (nready < 0) {
            printf("EX09-SELECT-ERR seq=%d errno=%d(%s)\n", seq, errno,
                   strerror(errno));
            break;
        }
        if (nready == 0) {
            hang_escaped = true; /* 预算耗尽仍无数据可读：正是悬案形态 */
            break;
        }
        ssize_t r = esp_tls_conn_read(tls, rx + got, sizeof(rx) - got);
        if (r <= 0) {
            printf("EX09-READ seq=%d r=%zd errno=%d(%s) got=%d\n", seq, r,
                   errno, strerror(errno), got);
            break; /* EOF 或传输错误：以已收字节数定胜负 */
        }
        got += (int)r;
        for (int i = 0; i < (int)r; i++) {
            rx_xor ^= (unsigned char)rx[i]; /* 跨 chunk 持续累计，与顺序无关 */
        }
    }

    /* ---- 判定 ---- */
    enum attempt_result result;
    if (hang_escaped) {
        printf(
            "EX09-APP-TIMEOUT seq=%d budget_ms=%d got=0 -> KNOWN-ISSUE-HIT "
            "(SLIRP outer-loop TLS, see ch22 case#1); closing by escape hatch\n",
            seq, APP_REPLY_TIMEOUT_MS);
        result = ATTEMPT_HANG_ESCAPED;
    } else if (got == g_probe_len && rx_xor == tx_xor) {
        printf("EX09-REPLY seq=%d len=%d xor_match=YES (%s)\n", seq, got,
               "xor order-independent: outer replies byte-reversed via "
               "s_server -rev, local echo returns as-is");
        result = ATTEMPT_PASS;
    } else {
        printf("EX09-REPLY seq=%d len=%d want=%d xor_rx=%04x xor_tx=%04x "
               "match=%s (short echo / early EOF)\n",
               seq, got, g_probe_len, rx_xor, tx_xor,
               (rx_xor == tx_xor) ? "YES" : "NO");
        result = ATTEMPT_SHORT_ECHO;
    }
    return result;
}

/*
 * PHASE-A 单轮：guest esp_tls -> 宿主 openssl s_server（外环）。
 *
 * 证书验证升级路径（pinning）：当前默认姿势是 sdkconfig 里开了
 * CONFIG_ESP_TLS_INSECURE + CONFIG_ESP_TLS_SKIP_SERVER_CERT_VERIFY，
 * cfg 不带任何信任锚即放行任何证书。要升级为 CA 固定：
 *   1) sdkconfig 删掉上面两项（INSECURE 未开时带 cacert 才合法）；
 *   2) 把 tools/run_sserver.sh 生成的 certs/sserver.crt 内容转成 C 字符串
 *      （或改成运行时挂载），然后填：
 *       esp_tls_cfg_t cfg = {
 *           .cacert_buf   = (const unsigned char *)SERVER_CERT_PEM,
 *           .cacert_bytes = strlen(SERVER_CERT_PEM) + 1, // PEM 必须含结尾 NUL！
 *           .common_name  = "localhost",                 // 主机名对 CN/SAN 校验
 *           .timeout_ms   = TLS_HS_TIMEOUT_MS,
 *       };
 *   3) 证书每 renew 一次都得同步重嵌；common_name 要与 CN 匹配否则报
 *      MBEDTLS_ERR_X509_CERT_VERIFY_FAILED（cert_flags 里能看到细节）。
 */
static enum attempt_result tls_attempt_outer(int seq)
{
    printf("EX09-PHASE name=TLS-OUTER target=%s:%u seq=%d "
           "expect=app-roundtrip\n",
           HOST_IP_STR, PORT_TLS, seq);

    char tagbuf[24];
    snprintf(tagbuf, sizeof(tagbuf), "pre-hs-%d", seq);
    mem_stamp(tagbuf);
    uint32_t minever_before = heap_caps_get_minimum_free_size(MALLOC_CAP_DEFAULT);

    /* ---- 段 1：TCP 连接 + TLS 握手（合计时；分段计时法见 ch22 staged 手法）---- */
    esp_tls_t *tls = esp_tls_init();
    if (!tls) {
        printf("EX09-HS-FAIL detail=esp_tls_init-oom\n");
        return ATTEMPT_HS_FAIL;
    }

    esp_tls_cfg_t cfg = {
        .timeout_ms = TLS_HS_TIMEOUT_MS,
        /* 不提供 cacert_buf/use_global_ca_store => 走 SKIP_SERVER_CERT_VERIFY
         * 全局放行（sdkconfig.defaults 已开 INSECURE 组）。 */
    };

    int64_t t0 = now_ms();
    int rc = esp_tls_conn_new_sync(HOST_IP_STR, strlen(HOST_IP_STR), PORT_TLS,
                                   &cfg, tls);
    int64_t conn_elapsed = now_ms() - t0;

    if (rc != 1) {
        printf("EX09-HS-FAIL seq=%d elapsed_ms=%lld\n", seq,
               (long long)conn_elapsed);
        report_tls_error(tls);
        esp_tls_conn_destroy(tls);
        snprintf(tagbuf, sizeof(tagbuf), "post-fail-%d", seq);
        mem_stamp(tagbuf);
        return ATTEMPT_HS_FAIL;
    }
    printf("EX09-TCPPLUSHS seq=%d elapsed_ms=%lld (tcp_connect+tls_handshake)\n",
           seq, (long long)conn_elapsed);
    report_negotiated(tls);

    snprintf(tagbuf, sizeof(tagbuf), "post-hs-%d", seq);
    mem_stamp(tagbuf);
    uint32_t minever_after_hs = heap_caps_get_minimum_free_size(MALLOC_CAP_DEFAULT);
    /* 握手峰值增量（min-ever 阶段差，ch22 HANDSHAKE_PEAK_DELTA 同口径）。
     * 教学点：min-ever 是全局单调水位，从第二轮起这里只反映"比历史更深的坑"，
     * 与 ch22 的告警一致——跨阶段直接取差不代表本轮真实分配量。 */
    printf("EX09-LEDGER seq=%d handshake_peak_delta=%u (min-ever %u -> %u)\n",
           seq, (unsigned)(minever_before - minever_after_hs),
           (unsigned)minever_before, (unsigned)minever_after_hs);

    int fd = -1;
    if (esp_tls_get_conn_sockfd(tls, &fd) != ESP_OK || fd < 0) {
        printf("EX09-WRITE-FAIL seq=%d detail=no-sockfd\n", seq);
        esp_tls_conn_destroy(tls);
        return ATTEMPT_HS_FAIL;
    }

    enum attempt_result result = tls_exchange(tls, fd, seq);
    esp_tls_conn_destroy(tls);
    snprintf(tagbuf, sizeof(tagbuf), "post-close-%d", seq);
    mem_stamp(tagbuf);
    return result;
}

/* --------------- PHASE-B：guest 内回环 TLS echo 服务端 --------------- */

static esp_tls_cfg_server_t s_local_srv_cfg;
static SemaphoreHandle_t s_local_ready;

/* 回环 TLS echo 服务（ch22 local_tls_echo_task 同款骨架）。Batch 7 教训已消化：
 * 单任务串行 accept，但每条连接必须读至 EOF 并及时 close+回收会话，否则后续
 * connect 全部进 backlog 等死。backlog 给 4 吃满余量。 */
static void tls_local_echo_task(void *arg)
{
    memset(&s_local_srv_cfg, 0, sizeof(s_local_srv_cfg));
    /* PEM 作为字符串字面量自带结尾 NUL，bytes 取 strlen()+1 覆盖之 */
    s_local_srv_cfg.servercert_buf = (const unsigned char *)TLS_LOCAL_CERT_PEM;
    s_local_srv_cfg.servercert_bytes = sizeof(TLS_LOCAL_CERT_PEM);
    s_local_srv_cfg.serverkey_buf = (const unsigned char *)TLS_LOCAL_KEY_PEM;
    s_local_srv_cfg.serverkey_bytes = sizeof(TLS_LOCAL_KEY_PEM);
    s_local_srv_cfg.tls_handshake_timeout_ms = 15000;

    struct sockaddr_in la = {
        .sin_family = AF_INET,
        .sin_port = htons(PORT_LOCAL_TLS),
    };
    int ls = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    assert(ls >= 0);
    setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &(int){1}, sizeof(int));
    assert(bind(ls, (struct sockaddr *)&la, sizeof(la)) == 0);
    assert(listen(ls, 4) == 0);
    xSemaphoreGive(s_local_ready);

    char rx[256];
    for (;;) {
        int c = accept(ls, NULL, NULL);
        if (c < 0) {
            continue;
        }
        esp_tls_t *sess = esp_tls_init();
        if (!sess) {
            printf("EX09-SRV oom on accept\n");
            close(c);
            continue;
        }
        if (esp_tls_server_session_create(&s_local_srv_cfg, c, sess) != 0) {
            printf("EX09-SRV handshake failed fd=%d\n", c);
            esp_tls_server_session_delete(sess);
            close(c);
            continue;
        }
        printf("EX09-SRV session established fd=%d\n", c);
        int n;
        while ((n = esp_tls_conn_read(sess, rx, sizeof(rx))) > 0) {
            int off = 0;
            while (off < n) {
                ssize_t wcnt = esp_tls_conn_write(sess, rx + off, n - off);
                if (wcnt <= 0) {
                    break;
                }
                off += (int)wcnt;
            }
        }
        esp_tls_server_session_delete(sess);
        close(c); /* 及时回收：不干净关会造成下一条连接排队饿死（Batch 7） */
        printf("EX09-SRV session closed\n");
    }
}

/* PHASE-B 单轮：同一套客户端代码自连 guest 内部 TLS echo（loopback）。 */
static enum attempt_result tls_attempt_local(int seq)
{
    printf("EX09-PHASE name=TLS-LOCAL target=127.0.0.1:%u seq=%d "
           "expect=app-roundtrip\n",
           PORT_LOCAL_TLS, seq);

    esp_tls_t *tls = esp_tls_init();
    if (!tls) {
        printf("EX09-HS-FAIL detail=esp_tls_init-oom\n");
        return ATTEMPT_HS_FAIL;
    }
    esp_tls_cfg_t cfg = { .timeout_ms = TLS_HS_TIMEOUT_MS };

    int64_t t0 = now_ms();
    int rc = esp_tls_conn_new_sync("127.0.0.1", strlen("127.0.0.1"),
                                   PORT_LOCAL_TLS, &cfg, tls);
    int64_t conn_elapsed = now_ms() - t0;
    if (rc != 1) {
        printf("EX09-HS-FAIL seq=%d elapsed_ms=%lld\n", seq,
               (long long)conn_elapsed);
        report_tls_error(tls);
        esp_tls_conn_destroy(tls);
        return ATTEMPT_HS_FAIL;
    }
    printf("EX09-TCPPLUSHS seq=%d elapsed_ms=%lld (tcp_connect+tls_handshake, "
           "loopback)\n",
           seq, (long long)conn_elapsed);
    report_negotiated(tls);
    /* 账本口径说明：本阶段 client/server 两端都在本 guest 里，堆快照混合了双方
     * 分配量，不能直接当"单连接稳态成本"引用——对照值以 PHASE-A 为准。 */

    int fd = -1;
    if (esp_tls_get_conn_sockfd(tls, &fd) != ESP_OK || fd < 0) {
        printf("EX09-WRITE-FAIL seq=%d detail=no-sockfd\n", seq);
        esp_tls_conn_destroy(tls);
        return ATTEMPT_HS_FAIL;
    }

    enum attempt_result result = tls_exchange(tls, fd, seq);
    esp_tls_conn_destroy(tls);
    return result;
}

/* ------------------------- 客户端主任务 -------------------------- */

static void client_task(void *arg)
{
    /* 探针内容固定，方便双端（run.log 与 sserv.log）肉眼对账 */
    g_probe_len =
        snprintf(g_probe, sizeof(g_probe),
                 "GET /tls-probe HTTP/1.0\r\nX-Probe-Seq: %d\r\n", 1);
    /* 末尾保证以 \n 结尾：-rev 按行攒包，无换行则永远不发（见 tools 注释） */
    if (g_probe[g_probe_len - 1] != '\n') {
        g_probe[g_probe_len++] = '\n';
    }

    printf(
        "$$$ EXREADY outer=%s:%u local=127.0.0.1:%u attempts=%d+%d "
        "probe_len=%d escape_budget_ms=%d\n",
        HOST_IP_STR, PORT_TLS, PORT_LOCAL_TLS, N_OUTER_ATTEMPTS,
        N_LOCAL_ATTEMPTS, g_probe_len, APP_REPLY_TIMEOUT_MS);
    mem_stamp("boot-baseline");

    /* ---- PHASE-A：外环 s_server ---- */
    int n_pass = 0, n_hang = 0, n_hsfail = 0, n_short = 0;
    for (int seq = 1; seq <= N_OUTER_ATTEMPTS; seq++) {
        enum attempt_result r = tls_attempt_outer(seq);
        switch (r) {
        case ATTEMPT_PASS:
            n_pass++;
            break;
        case ATTEMPT_HANG_ESCAPED:
            n_hang++;
            break;
        case ATTEMPT_HS_FAIL:
            n_hsfail++;
            break;
        case ATTEMPT_SHORT_ECHO:
            n_short++;
            break;
        }
        vTaskDelay(pdMS_TO_TICKS(SETTLE_GAP_MS));
    }
    printf("EX09-PHASEOVER name=OUTER attempts=%d pass=%d hang_escaped=%d "
           "hs_fail=%d short_echo=%d\n",
           N_OUTER_ATTEMPTS, n_pass, n_hang, n_hsfail, n_short);

    /* ---- PHASE-B：回环自连（替代路径，隔离问题域用）---- */
    int l_pass = 0, l_other = 0;
    s_local_ready = xSemaphoreCreateBinary();
    if (xTaskCreate(tls_local_echo_task, "ex09srv", 12288, NULL, 5, NULL) ==
        pdPASS) {
        xSemaphoreTake(s_local_ready, pdMS_TO_TICKS(5000)); /* 等 listen 就绪 */
        for (int seq = N_OUTER_ATTEMPTS + 1;
             seq <= N_OUTER_ATTEMPTS + N_LOCAL_ATTEMPTS; seq++) {
            enum attempt_result r = tls_attempt_local(seq);
            (r == ATTEMPT_PASS) ? l_pass++ : l_other++;
            vTaskDelay(pdMS_TO_TICKS(SETTLE_GAP_MS));
        }
    }
    printf("EX09-PHASEOVER name=LOCAL attempts=%d pass=%d other=%d\n",
           N_LOCAL_ATTEMPTS, l_pass, l_other);

    printf("EX09-SUMMARY outer=pass:%d/hang:%d/hsfail:%d/short:%d "
           "local=pass:%d/other:%d\n",
           n_pass, n_hang, n_hsfail, n_short, l_pass, l_other);
    mem_stamp("final");
    printf("$$$ EXDONE all-phases-run idling\n");

    /* KEEPALIVE：示例收尾后保持进程存活，便于继续手工做附加实验 */
    for (;;) {
        vTaskDelay(pdMS_TO_TICKS(30000));
        printf("EX09-IDLE uptime_ms=%lld\n", (long long)now_ms());
    }
}

/* ------------------------ 网络 bring-up 骨架 --------------------- */

static SemaphoreHandle_t s_got_ip;

static void eth_event_handler(void *arg, esp_event_base_t base, int32_t event_id,
                              void *event_data)
{
    if (event_id == ETHERNET_EVENT_CONNECTED) {
        ESP_LOGI(TAG, "ETH_EVENT: CONNECTED (link up)");
    } else if (event_id == ETHERNET_EVENT_DISCONNECTED) {
        ESP_LOGW(TAG, "ETH_EVENT: DISCONNECTED");
    }
}

static void ip_event_handler(void *arg, esp_event_base_t base, int32_t event_id,
                             void *event_data)
{
    ip_event_got_ip_t *evt = (ip_event_got_ip_t *)event_data;
    ESP_LOGI(TAG, "GOT_IP: " IPSTR, IP2STR(&evt->ip_info.ip));
    xSemaphoreGive(s_got_ip);
}

void app_main(void)
{
    ESP_LOGI(TAG, "== ex09: openeth bring-up then esp-tls client template ==");
    printf("EX09-FACT built=\"%s %s\" idf_version=%s\n", __DATE__, __TIME__,
           esp_get_idf_version());

    /* 步序契约：esp_netif_init 必须是第一句网络调用（socket 相关一切创建都得
     * 排它后面，次序颠倒 tcpip 邮箱未就绪会 assert 复位） */
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    s_got_ip = xSemaphoreCreateBinary();

    esp_netif_config_t netif_cfg = ESP_NETIF_DEFAULT_ETH();
    esp_netif_t *eth_netif = esp_netif_new(&netif_cfg);

    eth_mac_config_t mac_cfg = ETH_MAC_DEFAULT_CONFIG();
    eth_phy_config_t phy_cfg = ETH_PHY_DEFAULT_CONFIG();
    phy_cfg.reset_gpio_num = -1; /* 虚拟 PHY 没有复位脚 */
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

    /* 业务任务栈给足：esp-tls + 软件 MPI 运算吃栈（ch22 同规模实践值），
     * 优先级压在 tcpip(18)/emac_rx(15) 之下即可（事务型小流量） */
    xTaskCreate(client_task, "ex09cli", 20480, NULL, 5, NULL);
}
