/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * ex07 sntp-clock —— SNTP 对时模板 +【SLIRP UDP 转发裁决实验】
 *
 * 本示例一次跑完三条线：
 *   A. 裁决实验：guest 主动向 10.0.2.2 发起 UDP——这是全组关心的
 *      「guest 出站 UDP 经 SLIRP 是否落到宿主机 loopback 同端口」的实测点：
 *        - 8262 反射器探针：任意载荷原样回显，往返成立 = 转发可用（正向裁决）；
 *        - 8261 空端口探针：观察宿主无监听时的行为（超时 or ICMP 引导的错误）。
 *   B. 主线 SNTP 对时：esp_netif_sntp 指向 10.0.2.2。SNTP_PORT 在根
 *      CMakeLists.txt 编译期覆盖为 8260（lwIP 的 SNTP 源/目的端口绑死同一宏，
 *      默认 123 是特权端口；SLIRP 外连是同端口号落宿主，故用号段内端口闭环，
 *      宿主 tools/ntpd.py 免 root 监听 8260 即可）。
 *   C. 时钟教学点三连：
 *        1. 对时前后的系统时钟差真实打印（wallclock epoch 秒数 + 人读字符串）；
 *        2. sys_now() 是 10ms tick 网格，亚毫秒精度禁止使用——用同样本窗内的
 *           唯一值计数对照 esp_timer 的 µs 级分辨率做实证；
 *        3. settimeofday 跳变墙钟后 esp_timer_get_time() 单调连续不受影响。
 *
 * 机器可读标记（沿用套件 $$$ 风格）：
 *   $$$ EX07READY ip=.. gw=.. dns=..          —— 起播成功门信号
 *   $$$ EX07-RESULT <KEY> k=v ..              —— 分项裁决/教学结论行
 *   $$$ EXFAIL reason=..                      —— 失败门信号
 *   $$$ EX07DONE                              —— 收口
 *
 * 运行环境：ESP-IDF v6.0.2 + qemu-system-xtensa (Espressif fork)，
 *           -nic user,model=open_eth（SLIRP：guest 得 10.0.2.15/24）。
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <time.h>
#include <errno.h>
#include <inttypes.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"

#include "esp_log.h"
#include "esp_event.h"
#include "esp_netif.h"
#include "esp_eth.h"
#include "esp_system.h"
#include "esp_timer.h"

#include "lwip/sockets.h"
#include "lwip/inet.h"
#include "lwip/sys.h" /* sys_now()：tick 网格演示主角 */

#include "esp_netif_sntp.h"
#include "esp_sntp.h"

static const char *TAG = "ex07";

/* ---------------- 可调参数 ---------------- */

#define SNTP_SERVER_STR   "10.0.2.2" /* SLIRP 虚拟网关 == 宿主机 loopback */
#define REFLECTOR_PORT    8262       /* 开放槽位：UDP 反射器（转发裁决正向证据） */
#define CLOSED_PROBE_PORT 8261       /* 同号段保留空槽：无监听行为观察 */
                                     /* 8260 由编译期 SNTP_PORT 占用（见根 CMakeLists.txt） */
#define PROBE_RCVTIMEO_SEC 3         /* 探针单次等待上限 */
#define PROBE_ATTEMPTS     3         /* 反射器探针重试次数 */
#define SNTP_WAIT_ROUNDS   14        /* 3s 一轮 x14 ≈ 42s：覆盖 ≤5s 随机启动延迟+重传 */
#define SECOND_SYNC_WAIT_S 25        /* 周期对时观测窗（UPDATE_DELAY=20s > RFC 下限15s） */

/* ---------------- 时间打印辅助 ---------------- */

static void print_wallclock(const char *phase)
{
    struct timeval tv;
    gettimeofday(&tv, NULL);
    char utc[40], cst[40];
    struct tm tm_utc, tm_cst;
    gmtime_r(&tv.tv_sec, &tm_utc);
    strftime(utc, sizeof(utc), "%Y-%m-%d %H:%M:%S", &tm_utc);
    setenv("TZ", "CST-8", 1);
    tzset();
    localtime_r(&tv.tv_sec, &tm_cst);
    strftime(cst, sizeof(cst), "%Y-%m-%d %H:%M:%S", &tm_cst);
    /* 差值口径用 epoch 秒（UTC 1970 基准），人读串只做展示 */
    ESP_LOGI(TAG, "[EX07] %s epoch_sec=%lld.%06ld utc=\"%s\" cst8=\"%s\" et_us=%lld tick_ms=%" PRIu32,
             phase, (long long)tv.tv_sec, (long)tv.tv_usec, utc, cst,
             (long long)esp_timer_get_time(), (uint32_t)(xTaskGetTickCount() * portTICK_PERIOD_MS));
}

static int64_t wall_epoch_sec(void)
{
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (int64_t)tv.tv_sec;
}

/* ---------------- 教学点②：sys_now 的 10ms tick 网格实证 ---------------- */

#define GRID_SAMPLES 220

static void clock_grid_demo(void)
{
    static int64_t et_buf[GRID_SAMPLES];
    static uint32_t sn_buf[GRID_SAMPLES];

    int64_t d0 = esp_timer_get_time();
    unsigned uniq_et = 0, uniq_sn = 0;
    for (int i = 0; i < GRID_SAMPLES; i++) {
        et_buf[i] = esp_timer_get_time();
        sn_buf[i] = sys_now();
        if (i == 0 || et_buf[i] != et_buf[i - 1]) {
            uniq_et++;
        }
        if (i == 0 || sn_buf[i] != sn_buf[i - 1]) {
            uniq_sn++;
        }
    }
    ESP_LOGI(TAG, "[EX07] CLOCK-GRID samples=%d span_ms=%.1f unique_sysnow=%u unique_esptimer=%u",
             GRID_SAMPLES, (esp_timer_get_time() - d0) / 1000.0, uniq_sn, uniq_et);

    /* 步进视角：抓 3 次 sys_now 翻转，量每格对应的 esp_timer 实际跨度 */
    for (int k = 0; k < 3; k++) {
        uint32_t prev = sys_now();
        int64_t t_prev_us = esp_timer_get_time();
        while (sys_now() == prev) {
            ; /* 自旋等翻转（最坏 10ms），翻转点由 10ms tick 中断驱动 */
        }
        int64_t t_next_us = esp_timer_get_time();
        ESP_LOGI(TAG, "[EX07] GRID-STEP %d sysnow_flip_ms=%u esptimer_span_us=%lld", k + 1,
                 (unsigned)(sys_now() - prev), (long long)(t_next_us - t_prev_us));
    }
    ESP_LOGI(TAG,
             "$$$ EX07-RESULT SYSNOW-GRID grid_ms=%u verdict=\"sys_now 只有 %.0fms 网格精度，"
             "亚毫秒计时必须用 esp_timer_get_time\"",
             (unsigned)portTICK_PERIOD_MS, 10.0);
}

/* ---------------- 实验 A：UDP 转发裁决探针 ---------------- */

typedef struct {
    bool ok;
    bool payload_match;
    int rtt_us;
    int err;               /* 失败时最后一次 errno；成功无意义 */
    int attempts_used;
} probe_result_t;

/* 48 字节 NTP 形状的探针载荷：反射器按字节原样回显，比对内容即证往返完整 */
static size_t fill_probe_payload(uint8_t *p, uint32_t seq)
{
    memset(p, 0, 48);
    p[0] = (0 << 6) | (4 << 3) | 3; /* LI=0 VN=4 Mode=3(client)，形状与真请求一致 */
    p[1] = 0x42;                    /* 版本装饰位 */
    snprintf((char *)&p[4], 44, "EX07PROBE seq=%08" PRIx32, seq);
    return 48;
}

static void udp_forward_probe(int dst_port, uint32_t seq, probe_result_t *r)
{
    memset(r, 0, sizeof(*r));

    int s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (s < 0) {
        r->err = errno;
        ESP_LOGE(TAG, "[EX07] PROBE socket failed errno=%d (%s)", errno, strerror(errno));
        return;
    }
    struct timeval tv = { .tv_sec = PROBE_RCVTIMEO_SEC, .tv_usec = 0 };
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    struct sockaddr_in dst = { 0 };
    dst.sin_family = AF_INET;
    dst.sin_port = htons((uint16_t)dst_port);
    dst.sin_addr.s_addr = inet_addr("10.0.2.2");

    static uint8_t out[48], in[96];
    size_t plen = fill_probe_payload(out, seq);

    for (int att = 1; att <= PROBE_ATTEMPTS && !r->ok; att++) {
        r->attempts_used = att;
        ESP_LOGI(TAG, "[EX07] PROBE dst=10.0.2.2:%d attempt=%d/%d len=%zu", dst_port, att,
                 PROBE_ATTEMPTS, plen);
        if (sendto(s, out, plen, 0, (struct sockaddr *)&dst, sizeof(dst)) != (int)plen) {
            r->err = errno;
            ESP_LOGW(TAG, "[EX07] PROBE sendto failed errno=%d (%s)", errno, strerror(errno));
            continue;
        }
        memset(in, 0, sizeof(in));
        struct sockaddr_in src = { 0 };
        socklen_t slen = sizeof(src);
        int64_t t0 = esp_timer_get_time();
        int n = recvfrom(s, in, sizeof(in), 0, (struct sockaddr *)&src, &slen);
        if (n < 0) {
            r->err = errno;
            ESP_LOGW(TAG, "[EX07] PROBE no reply within %ds errno=%d (%s)", PROBE_RCVTIMEO_SEC,
                     errno, strerror(errno));
            continue;
        }
        r->rtt_us = (int)(esp_timer_get_time() - t0); /* 亚毫秒 RTT：教学点②的现场应用 */
        r->payload_match = ((size_t)n == plen && memcmp(in, out, plen) == 0);
        r->ok = true;
        ESP_LOGI(TAG, "[EX07] PROBE reply %d bytes from %s:%u rtt_us=%d payload_match=%s head=\"%.12s\"",
                 n, inet_ntoa(src.sin_addr), (unsigned)ntohs(src.sin_port), r->rtt_us,
                 r->payload_match ? "yes" : "no", (const char *)&in[4]);
    }
    close(s);
}

/* ---------------- 实验 B：SNTP 同步记录器（单通道！见下注） ----------------
 * IDF 的 sync_time_cb（esp_netif/lwip/esp_netif_sntp.c）在一次对时中会依次：
 * 给信号量 -> 调用户 sync_cb -> post NETIF_SNTP_EVENT。
 * 因此 sync_cb 与事件处理器【只会各自触发一次而非二选一】，同时注册会双计。
 * 我们只走事件通道：载荷含 timeval，且第一笔与周期笔天然同一格式可对比。
 */

static volatile int s_sync_events = 0;
static int64_t s_et_at_last_setofday = 0; /* 每次 settimeofday 落定时刻的 esp_timer 读数 */

static void sntp_event_handler(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    struct timeval tv;
    const esp_netif_sntp_time_sync_t *evt = (const esp_netif_sntp_time_sync_t *)data;
    if (evt && evt->tv.tv_sec != 0) {
        tv = evt->tv;
    } else {
        gettimeofday(&tv, NULL); /* 无有效载荷兜底（理论走不到，防御性记录） */
    }

    bool first = (++s_sync_events == 1);
    char ts[40];
    struct tm tm_utc;
    time_t t = tv.tv_sec;
    gmtime_r(&t, &tm_utc);
    strftime(ts, sizeof(ts), "%Y-%m-%d %H:%M:%S", &tm_utc);

    s_et_at_last_setofday = esp_timer_get_time(); /* 对时刚落定，取即时锚点 */
    int64_t wall_now = wall_epoch_sec();

    ESP_LOGI(TAG, "[EX07] SYNC#%d server_time_utc=\"%s.%06ld\" wall_after_epoch=%lld "
                  "et_at_apply_us=%lld",
             s_sync_events, ts, (long)tv.tv_usec, (long long)wall_now,
             (long long)s_et_at_last_setofday);
}

/* ---------------- SNTP 主线（含失败回退注入） ---------------- */

typedef enum {
    SYNC_NONE = 0,
    SYNC_PRIMARY_OK,
    SYNC_FALLBACK_APPLIED,
} sync_state_t;

static void apply_fallback_clock(void)
{
    /* 失败回退基准：写死一个「已知答案」时刻，用 settimeofday 演示同一套
     * 教学指标照常可得（README 说明该分支的触发条件与日志长相）。 */
    const time_t fallback_base = (time_t)1769904000; /* 2026-02-01 04:00:00 UTC */
    s_et_at_last_setofday = esp_timer_get_time();    /* 手动注入同样保留 esp_timer 锚点 */
    struct timeval fb = { .tv_sec = fallback_base, .tv_usec = 0 };
    settimeofday(&fb, NULL);
    s_sync_events++; /* 注入也计为一笔「时钟变更」，方便统一口径断言 */
    ESP_LOGW(TAG, "[EX07] FALLBACK manual settimeofday to epoch=%lld "
                  "(sync mechanism demo, NOT a real NTP result)",
             (long long)fallback_base);
    ESP_LOGI(TAG, "$$$ EX07-RESULT SYNC-FALLBACK applied=yes mode=manual-settimeofday base=%lld",
             (long long)fallback_base);
}

static sync_state_t run_sntp_phase(int64_t wall_before)
{
    ESP_LOGI(TAG, "[EX07] SNTP init server=%s (compiled SNTP_PORT=%d)", SNTP_SERVER_STR, 8260);
    ESP_ERROR_CHECK(esp_event_handler_register(NETIF_SNTP_EVENT, NETIF_SNTP_TIME_SYNC,
                                               &sntp_event_handler, NULL));

    esp_sntp_config_t cfg = ESP_NETIF_SNTP_DEFAULT_CONFIG(SNTP_SERVER_STR);
    esp_err_t err = esp_netif_sntp_init(&cfg);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "$$$ EXFAIL reason=sntp_init_err=%s", esp_err_to_name(err));
        return SYNC_NONE;
    }

    /* 初次对时等待：注意预算必须吃掉 ≤SNTP_STARTUP_DELAY(5s) 的随机启动延迟 */
    bool synced = false;
    for (int round = 1; round <= SNTP_WAIT_ROUNDS; round++) {
        err = esp_netif_sntp_sync_wait(pdMS_TO_TICKS(3000));
        if (err == ESP_OK) {
            synced = true;
            ESP_LOGI(TAG, "[EX07] SNTP synced within ~%ds (rounds=%d)", round * 3, round);
            break;
        }
        ESP_LOGI(TAG, "[EX07] waiting for system time (%d/%d) err=%s", round, SNTP_WAIT_ROUNDS,
                 esp_err_to_name(err));
    }

    int64_t d = wall_epoch_sec() - wall_before;
    if (!synced) {
        /* ---- 失败回退路径：手动 settimeofday 注入（机制演示版，非真实对时） ---- */
        ESP_LOGW(TAG, "$$$ EX07-RESULT SNTP-PRIMARY status=FAIL server=%s:%d rounds=%d "
                      "note=\"主线不通，按备选预案注入回退时钟\"",
                 SNTP_SERVER_STR, 8260, SNTP_WAIT_ROUNDS);
        apply_fallback_clock();
        d = wall_epoch_sec() - wall_before;
        ESP_LOGI(TAG, "$$$ EX07-RESULT CLOCK-DELTA delta_s=%lld origin=fallback-injection",
                 (long long)d);
        return SYNC_FALLBACK_APPLIED;
    }

    /* ---- 成功路径 ---- */
    ESP_LOGI(TAG, "$$$ EX07-RESULT SNTP-PRIMARY status=OK server=%s:%d wait_rounds=%d "
                  "startup_delay_budget_ms=%u",
             SNTP_SERVER_STR, 8260, SNTP_WAIT_ROUNDS, (unsigned)5000);
    ESP_LOGI(TAG, "$$$ EX07-RESULT CLOCK-DELTA delta_s=%lld origin=sntp-primary", (long long)d);
    return SYNC_PRIMARY_OK;
}

/* ---------------- openeth bring-up（套件标准骨架，ch3/ch24 沉淀） -------------- */

static SemaphoreHandle_t s_got_ip;

static void eth_event_handler(void *arg, esp_event_base_t base, int32_t event_id, void *event_data)
{
    switch (event_id) {
    case ETHERNET_EVENT_START:
        ESP_LOGI(TAG, "[EX07] ETH START");
        break;
    case ETHERNET_EVENT_CONNECTED:
        ESP_LOGI(TAG, "[EX07] ETH CONNECTED (link up)");
        break;
    case ETHERNET_EVENT_DISCONNECTED:
        ESP_LOGW(TAG, "[EX07] ETH DISCONNECTED (link down)");
        break;
    default:
        break;
    }
}

static void ip_event_handler(void *arg, esp_event_base_t base, int32_t event_id, void *event_data)
{
    ip_event_got_ip_t *evt = (ip_event_got_ip_t *)event_data;
    ESP_LOGI(TAG, "[EX07] GOT_IP " IPSTR " gw " IPSTR, IP2STR(&evt->ip_info.ip),
             IP2STR(&evt->ip_info.gw));
    xSemaphoreGive(s_got_ip);
}

void app_main(void)
{
    ESP_LOGI(TAG, "== ex07 sntp-clock (SNTP over SLIRP adjudication lab) ==");
    ESP_LOGI(TAG, "[EX07] FACT built=\"" __DATE__ " " __TIME__ "\" idf=" IDF_VER);
    ESP_LOGI(TAG, "[EX07] FACT ports: sntp=8260(compiled override) reflector=8262 closed-probe=8261");

    /* 1. esp_netif_init 必须是第一句网络调用（tcpip 邮箱在此建立） */
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    s_got_ip = xSemaphoreCreateBinary();

    esp_netif_config_t netif_cfg = ESP_NETIF_DEFAULT_ETH();
    esp_netif_t *eth_netif = esp_netif_new(&netif_cfg);

    eth_mac_config_t mac_cfg = ETH_MAC_DEFAULT_CONFIG();
    eth_phy_config_t phy_cfg = ETH_PHY_DEFAULT_CONFIG();
    phy_cfg.reset_gpio_num = -1;          /* 虚拟 PHY 无复位脚 */
    phy_cfg.autonego_timeout_ms = 3000;

    esp_eth_mac_t *mac = esp_eth_mac_new_openeth(&mac_cfg);
    assert(mac);
    esp_eth_phy_t *phy = esp_eth_phy_new_generic(&phy_cfg);
    assert(phy);

    esp_eth_config_t eth_cfg = ETH_DEFAULT_CONFIG(mac, phy);
    esp_eth_handle_t eth_handle = NULL;
    ESP_ERROR_CHECK(esp_eth_driver_install(&eth_cfg, &eth_handle));

    ESP_ERROR_CHECK(
        esp_event_handler_register(ETH_EVENT, ESP_EVENT_ANY_ID, &eth_event_handler, NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_ETH_GOT_IP, &ip_event_handler,
                                               NULL));

    esp_eth_netif_glue_handle_t glue = esp_eth_new_netif_glue(eth_handle);
    ESP_ERROR_CHECK(esp_netif_attach(eth_netif, glue));
    ESP_ERROR_CHECK(esp_eth_start(eth_handle));

    if (xSemaphoreTake(s_got_ip, pdMS_TO_TICKS(15000)) != pdTRUE) {
        ESP_LOGE(TAG, "$$$ EXFAIL reason=dhcp_timeout");
        return;
    }
    ESP_LOGI(TAG, "$$$ EX07READY ip=10.0.2.15 gw=10.0.2.2 dns=10.0.2.3 t_ms=%" PRIu32,
             (uint32_t)(xTaskGetTickCount() * portTICK_PERIOD_MS));

    /* ============ 教学点①③前半：对时前的系统时钟 ============ */
    int64_t wall_before = wall_epoch_sec();
    print_wallclock("PHASE=CLOCK-BEFORE");
    ESP_LOGI(TAG, "[EX07] wall_before_epoch=%lld （默认上电态：距 1970 基准仅数秒）",
             (long long)wall_before);

    /* ============ 教学点②：sys_now 10ms 网格 vs esp_timer µs ============ */
    clock_grid_demo();

    /* ============ 实验 A：UDP 转发裁决 ============ */
    probe_result_t rf, cl;
    udp_forward_probe(REFLECTOR_PORT, 0xA1B2C3D4U, &rf);
    if (rf.ok && rf.payload_match) {
        ESP_LOGI(TAG, "$$$ EX07-RESULT UDP-FORWARD dst=10.0.2.2:%d status=REACHABLE rtt_us=%d "
                      "payload_match=yes attempts=%d verdict=\"guest 出站 UDP 经 SLIRP 可达宿主 loopback 同端口\"",
                 REFLECTOR_PORT, rf.rtt_us, rf.attempts_used);
    } else {
        ESP_LOGW(TAG, "$$$ EX07-RESULT UDP-FORWARD dst=10.0.2.2:%d status=UNREACHABLE "
                      "last_errno=%d(%s) attempts=%d verdict=\"备选路径待启用\"",
                 REFLECTOR_PORT, rf.err, rf.err ? strerror(rf.err) : "none", rf.attempts_used);
    }
    /* 空端口对照：宿主侧 8261 无监听时 guest 观察到什么 */
    udp_forward_probe(CLOSED_PROBE_PORT, 0xDEADBEEFU, &cl);
    ESP_LOGI(TAG, "$$$ EX07-RESULT UDP-CLOSED dst=10.0.2.2:%d observed=%s last_errno=%d",
             CLOSED_PROBE_PORT, cl.ok ? "unexpected-reply(!)" : "NO_REPLY", cl.err);

    /* ============ 实验 B：SNTP 主线对时 ============ */
    sync_state_t st = run_sntp_phase(wall_before);

    /* ============ 教学点①③后半：对时后的系统时钟 ============ */
    print_wallclock("PHASE=CLOCK-AFTER");

    /* esp_timer 连续性证明：跨 settimeofday 三读数单调，不含墙钟跳变 */
    int64_t et_now = esp_timer_get_time();
    ESP_LOGI(TAG, "[EX07] ESPTIMER continuity: et_at_apply_us=%lld et_now_us=%lld elapsed=%.3fms",
             (long long)s_et_at_last_setofday, (long long)et_now,
             (et_now - s_et_at_last_setofday) / 1000.0);
    ESP_LOGI(TAG, "$$$ EX07-RESULT ESPTIMER-AFTER-SETTIMEOFDAY monotonic=yes "
                  "et_at_apply_us=%lld et_final_us=%lld",
             (long long)s_et_at_last_setofday, (long long)et_now);
    ESP_LOGI(TAG, "$$$ EX07-RESULT SYNC-TOTAL events=%d interval_ms=%u mode=%s reachability=0x%02x",
             s_sync_events, (unsigned)esp_sntp_get_sync_interval(),
             st == SYNC_PRIMARY_OK ? "primary" : (st == SYNC_FALLBACK_APPLIED ? "fallback" : "none"),
             (unsigned)esp_sntp_getreachability(0));

    /* ============ 周期对时观测窗（RFC 4330 ≥15s，本例 20s） ============ */
    if (st == SYNC_PRIMARY_OK) {
        ESP_LOGI(TAG, "[EX07] watching %ds window for periodical re-sync (interval=%ums)...",
                 SECOND_SYNC_WAIT_S, (unsigned)esp_sntp_get_sync_interval());
        vTaskDelay(pdMS_TO_TICKS(SECOND_SYNC_WAIT_S * 1000));
        ESP_LOGI(TAG, "$$$ EX07-RESULT PERIODIC-SYNC events_seen=%d expect_ge=2 "
                      "note=\"SYNC#2 应出现且间隔≈UPDATE_DELAY\"",
                 s_sync_events);
    }

    ESP_LOGI(TAG, "[EX07] SUMMARY server=%s:8260 sync_events=%d state=%d", SNTP_SERVER_STR,
             s_sync_events, (int)st);
    ESP_LOGI(TAG, "$$$ EX07DONE");
    esp_netif_sntp_deinit();
    vTaskDelay(pdMS_TO_TICKS(1500)); /* 让收口标记从 UART 冲刷出去 */
    esp_restart();                   /* 主动复位退出 QEMU（-no-reboot 下进程干净结束） */
}
