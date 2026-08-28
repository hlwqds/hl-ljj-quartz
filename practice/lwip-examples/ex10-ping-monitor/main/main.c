/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * ex10 ping-monitor —— 周期 ICMP 监控守护模板（openeth + SLIRP/QEMU 版）
 *
 * practice/lwip-examples 套件的第 10 课：起一个**单会话常驻**的 esp_ping 监控
 * （目标默认 SLIRP 网关 10.0.2.2），演示"监控守护"的三件套——
 *   1. 每 RTT 打印（EX10-RTT / EX10-TIMEOUT）；
 *   2. 每 N 个样本滚动汇总：min/avg/max RTT + 窗口内丢包率（EX10-SUMMARY）；
 *   3. 连续失败 K 次触发告警（$$$ EX10-ALARM，锁存直到恢复 $$$ EX10-RECOVER）。
 *
 * 另内置「拔网线」故障注入（ch7 手法）：到点后在 tcpip_thread 内执行
 * netif_set_link_down()，维持一段断网窗口后 netif_set_link_up() 自愈——无人值守
 * 即可完整走一遍 正常监控 → 告警触发 → 持续告警 → 恢复解除 的守护生命周期。
 *
 * 为什么坚持单会话：SLIRP 有一个会话边界怪癖——同一时刻开第二个 ping 会话恒
 * 超时（CONVENTIONS Batch 5）。本示例全程只建一次会话、永不重建；换目标请改
 * Kconfig 后重启，而不是运行中另开会话。
 *
 * 骨架与依赖说明：esp_ping 不是独立组件，实现在 IDF lwIP 组件内
 * （components/lwip/apps/ping/ping_sock.c，头文件 include/apps/ping/ping_sock.h），
 * PRIV_REQUIRES 写 lwip 即可；bring-up 序列遵循套件标准骨架。
 *
 * 运行环境：ESP-IDF v6.0.2 + qemu-system-xtensa (Espressif fork)，
 *           -nic user,model=open_eth（无 hostfwd：主机→guest ICMP 不通，
 *           ping 只能 guest 发起，监控方向是 guest → 目标）。
 */

#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"

#include "esp_log.h"
#include "esp_event.h"
#include "esp_netif.h"
#include "esp_netif_net_stack.h" /* esp_netif_get_netif_impl() */
#include "esp_timer.h"
#include "esp_eth.h"
#include "esp_eth_mac_openeth.h" /* esp_eth_mac_new_openeth() 的显式声明头 */

#include "lwip/tcpip.h" /* tcpip_callback() */
#include "lwip/netif.h" /* netif_set_link_down/up（必须在 tcpip_thread 内调） */

/* IDF v6 中 ping 应用在 lwIP 组件内：components/lwip/include/apps/ping/ping_sock.h */
#include "ping/ping_sock.h"

static const char *TAG = "ex10";

/* ------------------------- 配置（Kconfig 可调） ------------------------- */

#define TARGET_STR    CONFIG_EX10_TARGET_IP       /* 监控目标 */
#define INTERVAL_MS   CONFIG_EX10_INTERVAL_MS     /* 探测周期 */
#define TIMEOUT_MS    CONFIG_EX10_TIMEOUT_MS      /* 单次超时 */
#define ALARM_TH      CONFIG_EX10_ALARM_THRESHOLD /* 连续失败告警阈值 */
#define SUMMARY_EVERY CONFIG_EX10_SUMMARY_EVERY   /* 汇总窗口大小（样本数） */
#define WINDOW_MS     (CONFIG_EX10_MONITOR_WINDOW_S * 1000)

#if CONFIG_EX10_FAULT_AUTOINJECT
#define AUTOINJECT       1
#define INJECT_AT_MS  ((int64_t)CONFIG_EX10_INJECT_AT_S * 1000)
#define RECOVER_AT_MS ((int64_t)CONFIG_EX10_RECOVER_AT_S * 1000)
#endif

#define DHCP_TIMEOUT_MS 15000                          /* SLIRP DHCP 秒级应答，宽裕上限 */
#define QUIT_GRACE_MS (TIMEOUT_MS + INTERVAL_MS + 800) /* 等 ping 任务退出循环余量 */

/* ------------------------- 监控状态 ------------------------- */

/*
 * 共享状态访问纪律（免锁的原因要讲清楚）：
 * - 全部**写**发生在 on_ping_success/on_ping_timeout 里——它们由 esp_ping 内部
 *   唯一的 ping 任务串行调用，彼此天然互斥；
 * - app_main 只在 esp_ping_stop() 之后、且过了 QUIT_GRACE_MS（覆盖末次超时窗）
 *   才读全程累计——此刻 ping 任务已退出循环并归还控制权，不存在并发读写。
 * 这就是「先静默再读」（quiesce-then-read）：用生命周期顺序替代互斥锁的守规模板。
 */
typedef struct {
    /* 滚动窗口口径（每条 SUMMARY 打印后清零重计） */
    uint32_t w_samples, w_ok, w_lost;
    uint32_t w_rtt_min_ms, w_rtt_max_ms, w_rtt_sum_ms;
    /* 全程累计口径 */
    uint32_t g_samples, g_ok, g_lost;
    uint32_t g_rtt_min_ms, g_rtt_max_ms;
    uint64_t g_rtt_sum_ms;
} mon_stats_t;

static mon_stats_t s_mon;

static volatile int s_consec_fail;   /* 当前连续失败计数 */
static volatile bool s_alarm_active; /* 告警锁存位 */
static uint32_t s_alarm_total;       /* 历史告警次数 */
static int64_t s_alarm_at_rel_ms;    /* 最近一次告警触发时刻 */
static int64_t s_mon_start_ms;       /* 监控纪元（rel 时间零点） */

static inline int64_t now_ms(void)
{
    /* 时间戳用 esp_timer_get_time()；sys_now() 是 10ms tick 网格，精度不够 */
    return esp_timer_get_time() / 1000LL;
}

static inline float rel_s(void) { return (float)(now_ms() - s_mon_start_ms) / 1000.0f; }

static void mon_window_reset(void)
{
    s_mon.w_samples = 0;
    s_mon.w_ok = 0;
    s_mon.w_lost = 0;
    s_mon.w_rtt_min_ms = UINT32_MAX; /* 哨兵：纯丢失窗口打印 rtt=- 而非误导性 0 */
    s_mon.w_rtt_max_ms = 0;
    s_mon.w_rtt_sum_ms = 0;
}

/* 丢包率带一位小数的整数打印：%lu.%lu（避免浮点格式化拖体积），实现见下 */
static void loss_pct(uint32_t lost, uint32_t total, unsigned long *hi, unsigned long *lo);

/* 汇总窗口满即打一行滚动汇总。成功/超时两条路径都要调用——否则纯丢包期
 * 的窗口会被无限拉长（模板第一版踩过的坑），断网期间看不到中间汇总。 */
static void mon_maybe_summary(void)
{
    if (s_mon.w_samples < SUMMARY_EVERY) {
        return;
    }
    unsigned long hi, lo;
    loss_pct(s_mon.w_lost, s_mon.w_samples, &hi, &lo);
    if (s_mon.w_ok == 0) {
        ESP_LOGI(TAG,
                 "EX10-SUMMARY window_n=%lu ok=%lu lost=%lu loss=%lu.%lu%% "
                 "rtt_min=-ms rtt_avg=-ms rtt_max=-ms",
                 (unsigned long)s_mon.w_samples, (unsigned long)s_mon.w_ok,
                 (unsigned long)s_mon.w_lost, hi, lo);
    } else {
        ESP_LOGI(TAG,
                 "EX10-SUMMARY window_n=%lu ok=%lu lost=%lu loss=%lu.%lu%% "
                 "rtt_min=%lums rtt_avg=%lu.%ums rtt_max=%lums",
                 (unsigned long)s_mon.w_samples, (unsigned long)s_mon.w_ok,
                 (unsigned long)s_mon.w_lost, hi, lo,
                 (unsigned long)s_mon.w_rtt_min_ms,
                 (unsigned long)(s_mon.w_rtt_sum_ms / s_mon.w_ok),
                 (unsigned long)((s_mon.w_rtt_sum_ms % s_mon.w_ok) * 10 / s_mon.w_ok),
                 (unsigned long)s_mon.w_rtt_max_ms);
    }
    mon_window_reset();
}

/* 丢包率带一位小数的整数打印：%lu.%lu（避免浮点格式化拖体积） */
static void loss_pct(uint32_t lost, uint32_t total, unsigned long *hi, unsigned long *lo)
{
    if (total == 0) {
        *hi = 100;
        *lo = 0;
        return;
    }
    unsigned long x10 = (unsigned long)((uint64_t)lost * 1000UL / total);
    *hi = x10 / 10;
    *lo = x10 % 10;
}

/* ------------------------- esp_ping 回调（ping 任务上下文） ------------------------- */

static void on_ping_success(esp_ping_handle_t hdl, void *args)
{
    uint16_t seqno;
    uint8_t ttl;
    uint32_t rtt_ms, size;
    esp_ping_get_profile(hdl, ESP_PING_PROF_SEQNO, &seqno, sizeof(seqno));
    esp_ping_get_profile(hdl, ESP_PING_PROF_TTL, &ttl, sizeof(ttl));
    esp_ping_get_profile(hdl, ESP_PING_PROF_TIMEGAP, &rtt_ms, sizeof(rtt_ms));
    esp_ping_get_profile(hdl, ESP_PING_PROF_SIZE, &size, sizeof(size));

    /* 滚动窗口与全程累计各记一笔（w_rtt_min 复位为哨兵 UINT32_MAX，直接比即可） */
    if (rtt_ms < s_mon.w_rtt_min_ms) {
        s_mon.w_rtt_min_ms = rtt_ms;
    }
    if (s_mon.w_samples == 0 || rtt_ms > s_mon.w_rtt_max_ms) {
        s_mon.w_rtt_max_ms = rtt_ms;
    }
    s_mon.w_rtt_sum_ms += rtt_ms;
    s_mon.w_samples++;
    s_mon.w_ok++;
    s_mon.g_samples++;
    s_mon.g_ok++;
    s_mon.g_rtt_sum_ms += rtt_ms;
    if (s_mon.g_samples == 1 || rtt_ms < s_mon.g_rtt_min_ms) {
        s_mon.g_rtt_min_ms = rtt_ms;
    }
    if (s_mon.g_samples == 1 || rtt_ms > s_mon.g_rtt_max_ms) {
        s_mon.g_rtt_max_ms = rtt_ms;
    }

    s_consec_fail = 0;
    if (s_alarm_active) {
        s_alarm_active = false;
        ESP_LOGI(TAG,
                 "$$$ EX10-RECOVER rel_s=%.1f downtime_ms=%lld alarms_total=%lu "
                 "(consecutive-fail cleared, path is serving again)",
                 rel_s(), (long long)(now_ms() - s_mon_start_ms - s_alarm_at_rel_ms),
                 (unsigned long)s_alarm_total);
    }

    ESP_LOGI(TAG, "EX10-RTT seq=%u rtt_ms=%lu ttl=%u size=%lu ok=%lu", seqno,
             (unsigned long)rtt_ms, ttl, (unsigned long)size,
             (unsigned long)s_mon.g_ok);

    mon_maybe_summary();
}

static void on_ping_timeout(esp_ping_handle_t hdl, void *args)
{
    uint16_t seqno;
    esp_ping_get_profile(hdl, ESP_PING_PROF_SEQNO, &seqno, sizeof(seqno));

    s_mon.w_samples++;
    s_mon.w_lost++;
    s_mon.g_samples++;
    s_mon.g_lost++;
    s_consec_fail++;

    ESP_LOGW(TAG, "EX10-TIMEOUT seq=%u consec=%d/%d rel_s=%.1f", seqno,
             s_consec_fail, ALARM_TH, rel_s());

    if (!s_alarm_active && s_consec_fail >= ALARM_TH) {
        s_alarm_active = true;
        s_alarm_total++;
        s_alarm_at_rel_ms = now_ms() - s_mon_start_ms;
        ESP_LOGE(TAG,
                 "$$$ EX10-ALARM consec_lost=%d threshold=%d target=%s lost=%lu/%lu "
                 "rel_s=%.1f",
                 s_consec_fail, ALARM_TH, TARGET_STR, (unsigned long)s_mon.g_lost,
                 (unsigned long)s_mon.g_samples, rel_s());
    }

    mon_maybe_summary();
}

static void on_ping_end(esp_ping_handle_t hdl, void *args)
{
    /* count=0 无限会话只有 stop 才走到这里；全程汇总由 app_main 收口，不在此重复 */
    ESP_LOGI(TAG, "ping session ended (stop called)");
}

/* ------------------------- 故障注入：「拔网线」与自愈 ------------------------- */

/*
 * 「拔网线模拟」注入器：
 * netif_set_link_down/up 是 lwIP core 调用，必须投递到 tcpip_thread 执行
 * （套件纪律：跨线程不裸调 raw API）。这里用 tcpip_callback 把函数指针快递过去。
 * 注入点在 TCP/IP 层而非驱动层：只摘 LINK_UP 标志位，admin UP 与 DHCP 租约、
 * IP 配置原样保留——对应真实世界"网线被踢松但接口配置还在"的场景。
 * （留作公开入口：关掉自动注入后也可从 console/调试器手动调用它们做验证。）
 */

static struct netif *s_lwip_netif; /* eth 对应的 lwIP netif，GOT_IP 后解析一次 */

/* 真正干活的部分（在 tcpip_thread 内执行），实现见下方 */
static void link_down_cb(void *ctx);
static void link_up_cb(void *ctx);

void ex10_inject_link_down(void)
{
    assert(s_lwip_netif != NULL);
    ESP_ERROR_CHECK(tcpip_callback(link_down_cb, s_lwip_netif));
}

void ex10_inject_link_up(void)
{
    assert(s_lwip_netif != NULL);
    ESP_ERROR_CHECK(tcpip_callback(link_up_cb, s_lwip_netif));
}

static void link_down_cb(void *ctx)
{
    struct netif *nw = (struct netif *)ctx;
    ESP_LOGW(TAG,
             ">>> EX10-INJECT event=link_down call=netif_set_link_down(%c%c%d) "
             "before flags=0x%02x link_up=%d up=%d",
             nw->name[0], nw->name[1], nw->num, nw->flags, netif_is_link_up(nw),
             netif_is_up(nw));
    netif_set_link_down(nw);
    ESP_LOGW(TAG,
             "<<< EX10-INJECT done=link_down after flags=0x%02x link_up=%d up=%d "
             "(UP bit still set: admin up untouched, only LINK_UP cleared)",
             nw->flags, netif_is_link_up(nw), netif_is_up(nw));
}

static void link_up_cb(void *ctx)
{
    struct netif *nw = (struct netif *)ctx;
    ESP_LOGW(TAG, ">>> EX10-INJECT event=link_up call=netif_set_link_up(%c%c%d)",
             nw->name[0], nw->name[1], nw->num);
    netif_set_link_up(nw);
    ESP_LOGI(TAG,
             "<<< EX10-INJECT done=link_up after flags=0x%02x link_up=%d "
             "(healed; recovery confirmation left to the probe loop)",
             nw->flags, netif_is_link_up(nw));
}

#if AUTOINJECT

/* 自动注入任务：到点拔线 → 断网维持期（探针全灭、告警升旗）→ 到点接回自愈 */
static void fault_injector_task(void *arg)
{
    vTaskDelay(pdMS_TO_TICKS(INJECT_AT_MS));
    ESP_LOGW(TAG, "== fault-inject phase=cut-link at monitor t=%.1fs ==",
             (double)(INJECT_AT_MS / 1000));
    ex10_inject_link_down();

    vTaskDelay(pdMS_TO_TICKS(RECOVER_AT_MS - INJECT_AT_MS));
    ESP_LOGW(TAG, "== fault-inject phase=restore-link at monitor t=%.1fs ==",
             (double)(RECOVER_AT_MS / 1000));
    ex10_inject_link_up();

    ESP_LOGI(TAG, "fault injector exits; recovery confirmation left to probe loop");
    vTaskDelete(NULL);
}

#endif /* AUTOINJECT */

/* ------------------------- 事件处理与 bring-up ------------------------- */

static SemaphoreHandle_t s_got_ip;

static void ip_event_handler(void *arg, esp_event_base_t base, int32_t event_id,
                             void *event_data)
{
    ip_event_got_ip_t *evt = (ip_event_got_ip_t *)event_data;
    ESP_LOGI(TAG,
             "[t=%lld ms] IP_EVENT GOT_IP: ip " IPSTR " nm " IPSTR " gw " IPSTR,
             (long long)now_ms(), IP2STR(&evt->ip_info.ip), IP2STR(&evt->ip_info.netmask),
             IP2STR(&evt->ip_info.gw));
    xSemaphoreGive(s_got_ip);
}

static void start_monitor_session(void)
{
    ip_addr_t target;
    IP_SET_TYPE_VAL(target, IPADDR_TYPE_V4);
    ip4_addr_set_u32(ip_2_ip4(&target), ipaddr_addr(TARGET_STR));

    esp_ping_config_t cfg = ESP_PING_DEFAULT_CONFIG();
    cfg.target_addr = target;
    cfg.count       = ESP_PING_COUNT_INFINITE; /* 0 = 无限会话，stop 之前一直跑 */
    cfg.interval_ms = INTERVAL_MS;
    cfg.timeout_ms  = TIMEOUT_MS;

    esp_ping_callbacks_t cbs = {
        .cb_args         = NULL,
        .on_ping_success = on_ping_success,
        .on_ping_timeout = on_ping_timeout,
        .on_ping_end     = on_ping_end,
    };

    /*
     * 高水位失败观察点：堆紧张时 esp_ping_new_session 在 "create ping task failed"
     * / "no memory for esp_ping object" 处返回 ESP_ERR_NO_MEM（ch4 实测可复现）。
     * 生产守护应在这里带退避重试；模板保持一次尝试 + 明确失败门信号，行为诚实。
     */
    esp_ping_handle_t hdl = NULL;
    esp_err_t err = esp_ping_new_session(&cfg, &cbs, &hdl);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "$$$ EXFAIL reason=ping_session_create err=0x%x", err);
        return;
    }
    ESP_ERROR_CHECK(esp_ping_start(hdl));

    /* 监控窗收口：先静默再读（见文件头「先静默再读」注释），最后才删会话 */
    vTaskDelay(pdMS_TO_TICKS(WINDOW_MS));
    esp_ping_stop(hdl);
    vTaskDelay(pdMS_TO_TICKS(QUIT_GRACE_MS));

    unsigned long hi, lo;
    loss_pct(s_mon.g_lost, s_mon.g_samples, &hi, &lo);
    ESP_LOGI(TAG,
             "EX10-FINAL samples=%lu ok=%lu lost=%lu loss=%lu.%lu%% "
             "rtt_min=%lums rtt_avg=%lums rtt_max=%lums alarms=%lu window_ms=%ld",
             (unsigned long)s_mon.g_samples, (unsigned long)s_mon.g_ok,
             (unsigned long)s_mon.g_lost, hi, lo, (unsigned long)s_mon.g_rtt_min_ms,
             (unsigned long)(s_mon.g_samples ? s_mon.g_rtt_sum_ms / s_mon.g_samples : 0),
             (unsigned long)s_mon.g_rtt_max_ms, (unsigned long)s_alarm_total,
             (long)WINDOW_MS);
    ESP_LOGI(TAG, "$$$ EXDONE monitor_window_ms=%ld t_ms=%lld", (long)WINDOW_MS,
             (long long)now_ms());

    esp_ping_delete_session(hdl);
}

void app_main(void)
{
    ESP_LOGI(TAG, "== ex10 ping-monitor: single-session ICMP watchdog ==");
    /* 固件指纹：核对 QEMU 加载的不是旧镜像 */
    ESP_LOGI(TAG,
             "EX10-FACT build=\"" __DATE__ " " __TIME__ "\" target=%s interval_ms=%d "
             "timeout_ms=%d alarm_th=%d summary_every=%d window_s=%d autoinject=%d",
             TARGET_STR, INTERVAL_MS, TIMEOUT_MS, ALARM_TH, SUMMARY_EVERY,
             CONFIG_EX10_MONITOR_WINDOW_S, AUTOINJECT);

    /* [1] 初始化 TCP/IP 协议栈适配层与默认事件循环：
     * esp_netif_init() 创建 tcpip 邮箱，必须是第一句网络相关调用；
     * esp_ping 底层 raw ICMP socket 的创建同样依赖它就绪。 */
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    s_got_ip = xSemaphoreCreateBinary();

    /* [2] 创建以太网默认配置的 esp_netif 实例 */
    esp_netif_config_t netif_cfg = ESP_NETIF_DEFAULT_ETH();
    esp_netif_t *eth_netif = esp_netif_new(&netif_cfg);

    /* [3] 组装 MAC 与 PHY 对象（openeth 仅可用于 QEMU） */
    eth_mac_config_t mac_cfg = ETH_MAC_DEFAULT_CONFIG(); /* rx 任务 4096B prio15 */
    eth_phy_config_t phy_cfg = ETH_PHY_DEFAULT_CONFIG(); /* phy_addr AUTO */
    phy_cfg.reset_gpio_num      = -1; /* 虚拟 PHY 无复位引脚 */
    phy_cfg.autonego_timeout_ms = 3000;

    esp_eth_mac_t *mac = esp_eth_mac_new_openeth(&mac_cfg);
    assert(mac != NULL);
    esp_eth_phy_t *phy = esp_eth_phy_new_generic(&phy_cfg); /* v6 registry 通用 PHY */
    assert(phy != NULL);

    esp_eth_config_t eth_cfg = ETH_DEFAULT_CONFIG(mac, phy);
    esp_eth_handle_t eth_handle = NULL;
    ESP_ERROR_CHECK(esp_eth_driver_install(&eth_cfg, &eth_handle));

    /* [4] 注册事件处理器 + glue 挂接：netif up 时 glue 会替我们启动 DHCP 客户端 */
    ESP_ERROR_CHECK(
        esp_event_handler_register(IP_EVENT, IP_EVENT_ETH_GOT_IP, &ip_event_handler, NULL));
    esp_eth_netif_glue_handle_t glue = esp_eth_new_netif_glue(eth_handle);
    ESP_ERROR_CHECK(esp_netif_attach(eth_netif, glue));

    /* [5] 启动驱动：PHY 自协商 → 链路 up → netif up → DHCP → GOT_IP */
    ESP_ERROR_CHECK(esp_eth_start(eth_handle));
    ESP_LOGI(TAG, "waiting for DHCP lease ...");

    if (xSemaphoreTake(s_got_ip, pdMS_TO_TICKS(DHCP_TIMEOUT_MS)) != pdTRUE) {
        ESP_LOGE(TAG, "$$$ EXFAIL reason=dhcp_timeout after %d ms", DHCP_TIMEOUT_MS);
        return; /* -no-reboot 下进程退出；用 tools/run_qemu.sh 时靠 timeout 兜底 */
    }

    /* [6] 解析 lwIP netif 备用（注入器要在 tcpip_thread 里动它）；
     * esp_netif 与 lwip netif 是组合关系：背指针走 esp_netif_get_netif_impl()。 */
    s_lwip_netif = (struct netif *)esp_netif_get_netif_impl(eth_netif);
    assert(s_lwip_netif != NULL);

    /* [7] 机器可读 READY 行：验收器 grep 这一行即可断言起播成功 */
    ESP_LOGI(TAG,
             "$$$ EXREADY target=%s interval_ms=%d timeout_ms=%d alarm_th=%d "
             "netif=%c%c%d t_ms=%lld",
             TARGET_STR, INTERVAL_MS, TIMEOUT_MS, ALARM_TH, s_lwip_netif->name[0],
             s_lwip_netif->name[1], s_lwip_netif->num, (long long)now_ms());

    /* [8] 进入监控主线（单会话 + 单一注入任务，杜绝 SLIRP 同刻双会话怪癖） */
    s_mon_start_ms = now_ms();
#if AUTOINJECT
    xTaskCreate(fault_injector_task, "fault_inj", 3072, NULL, 5, NULL);
#endif
    start_monitor_session();

    /* [9] 应用阶段结束，保持进程存活（由外部 timeout 决定退出时机） */
    while (1) {
        vTaskDelay(pdMS_TO_TICKS(60000));
    }
}
