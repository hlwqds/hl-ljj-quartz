/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * ex12 net-stats-dashboard —— 观测台模板（全系列"健康检查"收口）
 *
 * 每 30s 在控制台打一帧完整仪表盘，同一时刻快照、统一 key=value 格式，
 * 两帧相邻即可 diff 出各协议计数增量：
 *   a. lwip_stats 五段协议计数增量（LINK/IP/ICMP/TCP/UDP 的
 *      recv/xmit/drop/chkerr/memerr，snap-diff 口径）；
 *   b. heap 三件套 free / largest / min-ever；
 *   c. 任务表（task 名 / prio / 栈高水位 / core，需 TRACE_FACILITY）；
 *   d. uptime 与 NTP 缺省信息行占位。
 *
 * 后台挂一个轻量自流量源（esp_ping 无限会话 ping 网关 10.0.2.2，静默回调），
 * 让计数器动起来——否则纯观测在静默链路上增量恒为 +0。本示例无 hostfwd、
 * 无外部工具依赖，复制改名即是一个现成的运行观测底座。
 *
 * 线程纪律：lwip_stats 是 tcpip_thread 的共享结构，读取统一经
 * tcpip_callback() 投递到 tcpip_thread 内拷贝，五个协议段在同一次回调里
 * 取齐，保证同帧数据出自同一时刻（套件 §2 规范）。heap 与任务表是
 * RTOS/heap_caps 层 API，应用任务直接读安全。
 *
 * 运行环境：ESP-IDF v6.0.2 + qemu-system-xtensa (Espressif fork)，
 *           -nic user,model=open_eth（SLIRP 用户态网络，DHCP 得 10.0.2.15/24）
 */

#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"

#include "esp_log.h"
#include "esp_event.h"
#include "esp_netif.h"
#include "esp_timer.h"
#include "esp_eth.h"
#include "esp_heap_caps.h"
#include "esp_eth_mac_openeth.h" /* esp_eth_mac_new_openeth() 的显式声明头 */

#include "lwip/tcpip.h"     /* tcpip_callback() */
#include "lwip/stats.h"     /* lwip_stats.{link,ip,icmp,tcp,udp}（需 CONFIG_LWIP_STATS=y） */
#include "lwip/ip_addr.h"   /* ip_addr_t / IP_SET_TYPE_VAL / ip_2_ip4 */

/* IDF v6 中 ping 应用在 lwIP 组件内：components/lwip/include/apps/ping/ping_sock.h */
#include "ping/ping_sock.h"

static const char *TAG = "ex12";

#define DHCP_TIMEOUT_MS  15000 /* SLIRP 的 DHCP 秒级应答，15s 已是宽裕上限 */
#define DASH_PERIOD_MS   30000 /* 仪表盘周期（SPEC §5：30s 一帧）          */
#define PING_INTERVAL_MS 1000  /* 自流量节奏：1 pps 足够让计数器肉眼可见    */

/* ------------------------- 协议计数快照 ------------------------- */

#if LWIP_STATS

#define DASH_PROTO_N 5
/* 行序即打印序；与 lwip_stats 各段一一对应 */
static const char *const s_proto_names[DASH_PROTO_N] = {
    "link", "ip", "icmp", "tcp", "udp",
};

/*
 * 一帧五段协议的计数快照。只收仪表盘要展示的五个字段：
 *   recv 收包数 / xmit 发包数 / drop 主动丢弃 / chkerr 校验和错 / memerr 内存不足
 * 计数器原生宽度是 STAT_COUNTER（LWIP_STATS_LARGE=n 时为 u16_t），这里放宽成
 * u32_t 存放；差值计算仍按原生宽度做回卷（见 c_delta()）。
 */
typedef struct {
    u32_t recv[DASH_PROTO_N];
    u32_t xmit[DASH_PROTO_N];
    u32_t drop[DASH_PROTO_N];
    u32_t chkerr[DASH_PROTO_N];
    u32_t memerr[DASH_PROTO_N];
} net_snap_t;

/*
 * 在 tcpip_thread 内执行：一次回调拷贝全部五段。之所以不走"读全局变量"，
 * 一是裸读跨线程共享结构有竞态，二来分散读会让同帧内不同字段出自不同时刻。
 */
static void net_snap_cb(void *ctx)
{
    net_snap_t *snap = (net_snap_t *)ctx;
    const struct stats_proto *src[DASH_PROTO_N] = {
        &lwip_stats.link, &lwip_stats.ip, &lwip_stats.icmp,
        &lwip_stats.tcp,  &lwip_stats.udp,
    };
    for (int i = 0; i < DASH_PROTO_N; i++) {
        snap->recv[i]   = src[i]->recv;
        snap->xmit[i]   = src[i]->xmit;
        snap->drop[i]   = src[i]->drop;
        snap->chkerr[i] = src[i]->chkerr;
        snap->memerr[i] = src[i]->memerr;
    }
}

/* 快照入口：经 tcpip_callback 投递；投递失败按全零处理并在帧内如实标注 */
static bool net_snapshot(net_snap_t *out, const char **err)
{
    memset(out, 0, sizeof(*out));
    *err = NULL;
    if (tcpip_callback(net_snap_cb, out) != ERR_OK) {
        *err = "tcpip_callback-failed";
        return false;
    }
    return true;
}

/* 差值按计数器原生宽度回卷：u16 计数器单次过 65535 回卷仍得正确增量 */
static unsigned long c_delta(u32_t cur, u32_t prev)
{
#if LWIP_STATS_LARGE
    return (unsigned long)(cur >= prev ? cur - prev : 0);
#else
    return (unsigned long)(u16_t)(cur - prev);
#endif
}

#else /* !LWIP_STATS：统计关闭时整段降级，见 README「已知边界」 */

#define DASH_PROTO_N 5
static const char *const s_proto_names[DASH_PROTO_N] = {
    "link", "ip", "icmp", "tcp", "udp",
};
typedef struct {
    u32_t recv[DASH_PROTO_N];
    u32_t xmit[DASH_PROTO_N];
    u32_t drop[DASH_PROTO_N];
    u32_t chkerr[DASH_PROTO_N];
    u32_t memerr[DASH_PROTO_N];
} net_snap_t;
static bool net_snapshot(net_snap_t *out, const char **err)
{
    (void)s_proto_names;
    memset(out, 0, sizeof(*out));
    *err = "lwip-stats-disabled";
    return false;
}
static unsigned long c_delta(u32_t cur, u32_t prev)
{
    return (unsigned long)(cur >= prev ? cur - prev : 0);
}

#endif /* LWIP_STATS */

/* ------------------------- heap 三件套 ------------------------- */

static void print_heap_line(void)
{
    /* 三件套口径见 README：min-ever 是多区域 sum-of-minima 的历史极值，
     * 只会往下走，禁止拿它跨阶段取差（Batch 6 实测教训） */
    printf("EX12-HEAP free=%u largest=%u min_ever=%u unit=bytes "
           "cap=MALLOC_CAP_8BIT\n",
           (unsigned)heap_caps_get_free_size(MALLOC_CAP_8BIT),
           (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_8BIT),
           (unsigned)heap_caps_get_minimum_free_size(MALLOC_CAP_8BIT));
}

/* ------------------------- 任务表快照 ------------------------- */

#if CONFIG_FREERTOS_USE_TRACE_FACILITY

/* 任务表一行：task 名 / prio / core / 栈高水位。排序规则：
 * prio 降序、同名次按名字典序升序——保证两帧行序稳定，diff 才不失真 */
static int dash_task_table(void)
{
    UBaseType_t n = uxTaskGetNumberOfTasks();
    TaskStatus_t *st = pvPortMalloc(n * sizeof(TaskStatus_t));
    if (!st) {
        printf("EX12-TASK alloc_failed need=%u\n", (unsigned)n);
        return -1;
    }
    n = uxTaskGetSystemState(st, n, NULL);

    for (UBaseType_t i = 1; i < n; i++) { /* 插入排序：条目少，稳定性优先 */
        TaskStatus_t tmp = st[i];
        UBaseType_t j = i;
        while (j > 0 &&
               (tmp.uxCurrentPriority > st[j - 1].uxCurrentPriority ||
                (tmp.uxCurrentPriority == st[j - 1].uxCurrentPriority &&
                 strcmp(tmp.pcTaskName, st[j - 1].pcTaskName) < 0))) {
            st[j] = st[j - 1];
            j--;
        }
        st[j] = tmp;
    }

    printf("EX12-TASK n=%u order=prio_desc,name_asc hwm_unit=bytes\n",
           (unsigned)n);
    for (UBaseType_t i = 0; i < n; i++) {
        BaseType_t core = st[i].xCoreID;
        const char *cstr =
            (core == tskNO_AFFINITY) ? "NA" : (core == 0 ? "0" : "1");
        printf("EX12-T %-16s prio=%2u core=%-2s hwm=%lu\n",
               st[i].pcTaskName, (unsigned)st[i].uxCurrentPriority, cstr,
               (unsigned long)st[i].usStackHighWaterMark);
    }
    vPortFree(st);
    return (int)n;
}

#else /* !TRACE_FACILITY：任务表降级为占位提示 */

static int dash_task_table(void)
{
    printf("EX12-TASK disabled reason=CONFIG_FREERTOS_USE_TRACE_FACILITY=n\n");
    return 0;
}

#endif /* CONFIG_FREERTOS_USE_TRACE_FACILITY */

/* ------------------------- 仪表盘一帧 ------------------------- */

static inline int64_t now_ms(void)
{
    /* 时间戳用 esp_timer_get_time()；sys_now() 是 10ms tick 网格，精度不够 */
    return esp_timer_get_time() / 1000LL;
}

static void dash_frame(unsigned id, const net_snap_t *prev, const net_snap_t *cur,
                       const char *stats_err)
{
    printf("$$$ EX12-FRAME id=%u up_ms=%lld period_ms=%d "
           "src=self-ping iv_ms=%d\n",
           id, (long long)now_ms(), DASH_PERIOD_MS, PING_INTERVAL_MS);

    if (stats_err != NULL) {
        printf("EX12-ST disabled reason=%s\n", stats_err);
    } else {
        for (int i = 0; i < DASH_PROTO_N; i++) {
            printf("EX12-ST %-5s recv=%lu(+%lu) xmit=%lu(+%lu) drop=%lu(+%lu) "
                   "chkerr=%lu(+%lu) memerr=%lu(+%lu)\n",
                   s_proto_names[i],
                   (unsigned long)cur->recv[i], c_delta(cur->recv[i], prev->recv[i]),
                   (unsigned long)cur->xmit[i], c_delta(cur->xmit[i], prev->xmit[i]),
                   (unsigned long)cur->drop[i], c_delta(cur->drop[i], prev->drop[i]),
                   (unsigned long)cur->chkerr[i], c_delta(cur->chkerr[i], prev->chkerr[i]),
                   (unsigned long)cur->memerr[i], c_delta(cur->memerr[i], prev->memerr[i]));
        }
    }

    print_heap_line();
    (void)dash_task_table();

    /* NTP 缺省信息行占位：本示例不跑 SNTP（对时模板见 ex07 sntp-clock），
     * 但这行预留了时钟观测位——扩展时替换成真实同步状态即可，帧格式不变 */
    printf("EX12-SYS uptime_s=%lld ntp=disabled(ntp-line-placeholder) "
           "clock_src=esp_timer\n",
           (long long)(now_ms() / 1000));
    printf("$$$ EX12-FRAME-END id=%u\n", id);
    fflush(stdout);
}

/* ------------------------- 后台自流量源 ------------------------- */

/*
 * 无限会话 ping 网关（SLIRP 恒应答）：每秒一发 ICMP echo，让 LINK/IP/ICMP
 * 段计数以稳定斜率爬升。回调全部留空——ping 应用对各回调都做了非空调用保护
 * （apps/ping/ping_sock.c 内逐个 if 判空），自流量保持静默，仪表盘帧之间
 * 不被日志污染。单会话长期稳定（ch3/ch9 验证）；同时刻第二会话才有毛刺。
 */
static void start_self_traffic(const esp_ip4_addr_t *gw)
{
    esp_ping_handle_t hdl = NULL;

    ip_addr_t target;
    memset(&target, 0, sizeof(target));
    IP_SET_TYPE_VAL(target, IPADDR_TYPE_V4);
    ip4_addr_set_u32(ip_2_ip4(&target), gw->addr);

    /* ESP_PING_DEFAULT_CONFIG 是初始化列表宏，只能在声明处赋初值再改字段 */
    esp_ping_config_t cfg = ESP_PING_DEFAULT_CONFIG();
    cfg.target_addr        = target;
    cfg.count              = ESP_PING_COUNT_INFINITE; /* 0 = 永续会话 */
    cfg.interval_ms        = PING_INTERVAL_MS;
    cfg.timeout_ms         = 1000;

    esp_ping_callbacks_t cbs;    /* 静默回调：计数器自己会说话 */
    memset(&cbs, 0, sizeof(cbs));

    ESP_ERROR_CHECK(esp_ping_new_session(&cfg, &cbs, &hdl));
    esp_ping_start(hdl);
    ESP_LOGI(TAG, "$$$ EXTRAFFIC target=" IPSTR " interval_ms=%d count=infinite",
             IP2STR(gw), PING_INTERVAL_MS);
    /* 会话句柄刻意不 delete：观测台全生命周期都需要这份自流量（见 README） */
}

/* ------------------------- 事件处理 ------------------------- */

static SemaphoreHandle_t s_got_ip; /* DHCP 完成信号量（IP_EVENT 回调 give） */

static void eth_event_handler(void *arg, esp_event_base_t base,
                              int32_t event_id, void *event_data)
{
    (void)arg;
    (void)base;
    (void)event_data;
    /* IDF v6 事件枚举是 ETHERNET_EVENT_*（不是 v5 的 ESP_ETH_EVENT_*） */
    switch (event_id) {
    case ETHERNET_EVENT_CONNECTED:
        ESP_LOGI(TAG, "[t=%lld ms] ETH_EVENT CONNECTED (link up)", now_ms());
        break;
    case ETHERNET_EVENT_DISCONNECTED:
        ESP_LOGW(TAG, "[t=%lld ms] ETH_EVENT DISCONNECTED (link down)",
                 now_ms());
        break;
    default:
        break;
    }
}

static void ip_event_handler(void *arg, esp_event_base_t base,
                             int32_t event_id, void *event_data)
{
    (void)arg;
    (void)base;
    (void)event_id;
    ip_event_got_ip_t *evt = (ip_event_got_ip_t *)event_data;
    ESP_LOGI(TAG, "[t=%lld ms] IP_EVENT GOT_IP: ip " IPSTR " nm " IPSTR
                  " gw " IPSTR,
             now_ms(), IP2STR(&evt->ip_info.ip), IP2STR(&evt->ip_info.netmask),
             IP2STR(&evt->ip_info.gw));
    xSemaphoreGive(s_got_ip);
}

/* ------------------------- app_main：标准 bring-up 序列 ------------------------- */

void app_main(void)
{
    ESP_LOGI(TAG, "== ex12 net-stats-dashboard: observation console ==");
    /* 固件指纹：核对 QEMU 加载的不是旧镜像（Batch 7 实践） */
    ESP_LOGI(TAG, "$$$ EX12-FACT build=\"" __DATE__ " " __TIME__ "\" "
                  "lwip_stats=%d trace_facility=%d",
             (int)LWIP_STATS, (int)CONFIG_FREERTOS_USE_TRACE_FACILITY);

    /* [1] esp_netif_init() 必须是第一句网络相关调用：它创建 tcpip 邮箱；
     * 之后才能投递 tcpip_callback 或创建 socket/netconn */
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    s_got_ip = xSemaphoreCreateBinary();

    /* [2] 以太网默认配置的 esp_netif 实例 */
    esp_netif_config_t netif_cfg = ESP_NETIF_DEFAULT_ETH();
    esp_netif_t *eth_netif = esp_netif_new(&netif_cfg);

    /* [3] MAC + PHY 组装（openeth 仅可用于 QEMU） */
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

    uint8_t mac_addr[6] = {0};
    ESP_ERROR_CHECK(esp_eth_ioctl(eth_handle, ETH_CMD_G_MAC_ADDR, mac_addr));

    /* [4] 事件注册：链路事件全量 + GOT_IP 事件 */
    ESP_ERROR_CHECK(esp_event_handler_register(ETH_EVENT, ESP_EVENT_ANY_ID,
                                               &eth_event_handler, NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_ETH_GOT_IP,
                                               &ip_event_handler, NULL));

    /* [5] glue 挂接：netif up 时 glue 替我们启动 DHCP 客户端 */
    esp_eth_netif_glue_handle_t glue = esp_eth_new_netif_glue(eth_handle);
    ESP_ERROR_CHECK(esp_netif_attach(eth_netif, glue));

    /* [6] 启动驱动：PHY 自协商 → 链路 up → netif up → DHCP → GOT_IP */
    ESP_ERROR_CHECK(esp_eth_start(eth_handle));
    ESP_LOGI(TAG, "waiting for DHCP lease ...");

    if (xSemaphoreTake(s_got_ip, pdMS_TO_TICKS(DHCP_TIMEOUT_MS)) != pdTRUE) {
        ESP_LOGE(TAG, "$$$ EXFAIL reason=dhcp_timeout after %d ms",
                 DHCP_TIMEOUT_MS);
        return; /* -no-reboot 下进程退出；runner 由 timeout 兜底收尸 */
    }
    esp_netif_ip_info_t info;
    ESP_ERROR_CHECK(esp_netif_get_ip_info(eth_netif, &info));

    /* [7] 机器可读 READY 行：验收器 grep 这一行即可断言起播成功 */
    ESP_LOGI(TAG, "$$$ EXREADY ip=" IPSTR " nm=" IPSTR " gw=" IPSTR " t_ms=%lld",
             IP2STR(&info.ip), IP2STR(&info.netmask), IP2STR(&info.gw),
             (long long)now_ms());

    /* [8] 挂后台自流量源，让仪表盘有增量可看 */
    start_self_traffic(&info.gw);

    /* [9] 仪表盘主循环：基线快照后每 30s 打一帧（绝对值+增量），永不退出，
     * 由 runner 的 timeout 决定收场时机 */
    net_snap_t base, cur;
    const char *base_err = NULL, *cur_err = NULL;
    net_snapshot(&base, &base_err);
    ESP_LOGI(TAG, "dashboard baseline taken, period=%d ms", DASH_PERIOD_MS);

    for (unsigned id = 1;; id++) {
        vTaskDelay(pdMS_TO_TICKS(DASH_PERIOD_MS));
        net_snapshot(&cur, &cur_err);
        dash_frame(id, &base, &cur, cur_err != NULL ? cur_err : base_err);
        base = cur;
    }
}
