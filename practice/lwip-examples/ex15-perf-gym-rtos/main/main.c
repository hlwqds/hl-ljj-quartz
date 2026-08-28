/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * ex15 perf-gym-rtos —— RTOS 调度错误健身房（症状全部来自真实实测事实）
 *
 * 一个固件内建 5 个可切换场景（CONFIG_GYM_SCENARIO，0=健康基线）：
 *   sc0 健康基线：双层心跳满血对照轮，任何场景的"劣化"都以它为参照系；
 *   sc1 优先级倒挂：两核各钉一个高优自旋任务，低优心跳被饿死
 *       （ch19 实验 C：prio23 自旋钉核占空比 70%~85% 是分水岭、100% 全灭且
 *       serial 全程无声——本场景默认 100%，复现干净的"全灭"样本）；
 *   sc2 回调慢操作：raw UDP 回调里 busy-wait → tcpip 单线程全栈停摆
 *       （ch13 实验 C：3 秒回调卡死 → ICMP 会话零进展，应用版改成周期性慢回调）；
 *   sc3 邮箱打满：高频投递淹没 32 槽 tcpip 邮箱 → 投递方两种语义对决传导链
 *       （ch13 实验 D：第 33 发精确阻塞 1.42s、try 路线即时 ERR_MEM 零阻塞）；
 *   sc4 栈余量耗尽：分步填栈把 HWM 逼到告警阈值下 → 高水位告警教学，
 *       不做真溢出崩溃，核心演示"HWM 是历史极值，复位要靠重建任务"。
 *
 * 设计主线——心跳监控是贯穿全程的"被受害者"，源头本身健康：
 *   - RTOS 层：ex15_hb 任务（刻意低优）周期打印 EX15-HB 行，带调度滞后 lag_ms；
 *   - 网络层：esp_ping 无限会话 ping SLIRP 网关，打印 EX15-NET / EX15-NETTOUT。
 *   每个场景让它以不同方式失联/劣化，教使用者从失联模式反推根因：
 *   sc1 调度层先死（HB 缺席 + ALARM kind=sched），网络层随之陪葬且 serial 无声；
 *   sc2 网络死而调度活（HB 一拍不落 + NETTOUT 连发）＝"单线程堵点"指纹；
 *   sc3 邮箱水位饱和，投递方阻塞/失败两态分布，ping 长尾劣化；
 *   sc4 心跳一拍不少，HWM 告警先于一切崩溃出现。
 *
 * 观测纪律（Batch 4/7 双核测量陷阱）：诊断/编排任务 pin core1、prio 22，
 * 压过 tcpip(18) 与 spinner(默认 20)，活在受害者带宽之外——即使 sc1 把全系统
 * 冻住，诊断帧依然打得出来，告警由幸存的旁路观测者发出（ch19 控制面教训）。
 *
 * 机器可读行协议（CI 可 grep）：
 *   $$$ EX15-FACT / $$$ EXREADY / EX15-HB / EX15-NET / EX15-NETTOUT /
 *   $$$ EX15-ALARM kind=sched|net|mbx|stk / $$$ EX15-RECOVER kind=... /
 *   EX15-INJECT phase=in|out event=... / == EX15-PHASE ... ==
 *   诊断帧 $$$ EX15-FRAME id=.. phase=.. ... $$$ EX15-FRAME-END：
 *     EX15-TASK/EX15-T（uxTaskGetSystemState 任务表 + run-time 统计占比）、
 *     EX15-ST（lwip_stats 五段 snap-diff）、EX15-MBX（邮箱水位代理）、
 *     EX15-STKSTEP（sc4 填栈步进）、EX15-HEAP（三件套）。
 *
 * 运行环境：ESP-IDF v6.0.2 + qemu-system-xtensa (Espressif fork)，
 *           -nic user,model=open_eth（SLIRP，guest 得 10.0.2.15/24，gw 10.0.2.2）。
 *           端口：8320 号段自环负载为主，无 hostfwd（SPEC §4）。
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
#include "esp_timer.h"
#include "esp_eth.h"
#include "esp_heap_caps.h"
#include "esp_eth_mac_openeth.h" /* esp_eth_mac_new_openeth() 的显式声明头 */

#include "lwip/tcpip.h"    /* tcpip_callback()/tcpip_try_callback() */
#include "lwip/stats.h"    /* lwip_stats 五段计数（需 CONFIG_LWIP_STATS=y） */
#include "lwip/ip_addr.h"
#include "lwip/udp.h"      /* sc2：raw UDP PCB（必须在 tcpip_thread 内操作） */
#include "lwip/sockets.h"  /* sc2 泵任务用 socket 层制造触发流量 */

/* IDF v6 中 ping 应用在 lwIP 组件内：components/lwip/include/apps/ping/ping_sock.h */
#include "ping/ping_sock.h"

static const char *TAG = "ex15";

/* ========================= 场景与时间轴参数 ========================= */

#define SC_BASELINE 0
#define SC_PRIO 1
#define SC_SLOWCB 2
#define SC_MBOX 3
#define SC_STACK 4

#if CONFIG_GYM_SCENARIO == SC_PRIO
#define SC_NAME "1-prio-starve"
#elif CONFIG_GYM_SCENARIO == SC_SLOWCB
#define SC_NAME "2-slow-raw-callback"
#elif CONFIG_GYM_SCENARIO == SC_MBOX
#define SC_NAME "3-tcpip-mbox-flood"
#elif CONFIG_GYM_SCENARIO == SC_STACK
#define SC_NAME "4-stack-hwm-alarm"
#else
#define SC_NAME "0-healthy-baseline"
#endif

#define INJECT_AT_MS ((int64_t)CONFIG_EX15_INJECT_AT_S * 1000)
#define REMOVE_AT_MS ((int64_t)CONFIG_EX15_REMOVE_AT_S * 1000)
#define RUN_WINDOW_MS ((int64_t)CONFIG_EX15_RUN_WINDOW_S * 1000)

#define DHCP_TIMEOUT_MS 15000 /* SLIRP 的 DHCP 秒级应答，15s 已是宽裕上限 */

#define HB_PERIOD_MS CONFIG_EX15_HB_PERIOD_MS
#define SCHED_GAP_ALARM_MS ((int64_t)CONFIG_EX15_SCHED_ALARM_GAP_MS)

/* 故障观察窗内的诊断帧时刻（相对注入点）；越窗外的 phase 由编排器取名 */
#define OBS_TICK_MS 250 /* 观测者巡检/时间轴推进步长 */
#define OBS_T1_AFTER_INJECT_MS 6000
#define OBS_T2_AFTER_INJECT_MS 16000

/* sc3 收尾判定：解除后连续两个巡检周期零新增失败即判恢复 */
#define MBX_RECOVER_CONFIRM_TICKS 2

/* 观测者/编排任务的"制外"位置（Batch 4/7：测量与控制必须压过受害者优先级） */
#define GYM_OBS_PRIO 22
#define GYM_OBS_CORE 1

static inline int64_t now_ms(void)
{
    /* 时间戳用 esp_timer_get_time()；sys_now() 是 10ms tick 网格，精度不够 */
    return esp_timer_get_time() / 1000LL;
}

static inline int64_t now_us(void) { return esp_timer_get_time(); }

static int64_t s_ready_ms;  /* 相对时间零点 = READY 行 */
static inline int64_t rel_ms(void) { return now_ms() - s_ready_ms; }

/* 全局故障闸门：所有故障载荷在循环里轮询它，置 false 即开始解除 */
static volatile bool s_fault_active;

static uint32_t s_own_ip; /* GOT_IP 后记录，sc2 自环流量目标 */

/* 收尾账目（字宽单写者累加，多读，免锁口径见 README） */
static unsigned s_alarms_sched, s_alarms_net, s_alarms_mbx, s_alarms_stk;

/* ------------------------- 前置声明（场景执行器） ------------------------- */
/* 每个场景在自己的 #if 块内给出真实实现，其余场景给同签名空实现兜底，
 * 编排器即可用统一的时间轴驱动任意构建组合。 */
static void sc1_inject(void);
static void sc1_remove(void);
static void sc2_inject(void);
static void sc2_remove(void);
static void sc3_inject(void);
static void sc3_remove(void);
static void sc4_inject(void);
static void sc4_remove(void);
static void mbx_report_inner(void); /* sc3 帧内观测节；其余场景为空实现 */

/* ------------------------- 忙等原语（纯墙上时间驱动） ------------------------- */

static volatile uint32_t s_burn_sink; /* 防 GCC 删空循环的垃圾桶 */

/* 忙到截止时刻；返回是否中途被取消闸门打断 */
__attribute__((unused)) static bool burn_until(int64_t deadline_us,
                                               const volatile bool *cancel)
{
    while (now_us() < deadline_us) {
        for (int k = 0; k < 128; k++) {
            s_burn_sink += (uint32_t)k;
        }
        if (cancel != NULL && !*cancel) {
            return true;
        }
    }
    return false;
}

__attribute__((unused)) static void burn_us(int64_t us)
{
    burn_until(now_us() + us, NULL);
}

__attribute__((unused)) static void burn_ms_checked(int64_t total_ms,
                                                    const volatile bool *cancel,
                                                    int64_t slice_ms)
{
    int64_t start = now_ms();
    while (now_ms() - start < total_ms) {
        int64_t remain = total_ms - (now_ms() - start);
        int64_t step = remain < slice_ms ? remain : slice_ms;
        if (burn_until(now_us() + step * 1000LL, cancel)) {
            return;
        }
    }
}

/* ================================================================
 * 观测原语 A：lwip_stats 快照（带回执超时 —— 本身就是"tcpip 死没死"探测器）
 * ================================================================ */

#if LWIP_STATS

#define SNAP_PROTO_N 5
static const char *const s_proto_names[SNAP_PROTO_N] = {
    "link", "ip", "icmp", "tcp", "udp",
};

typedef struct {
    u32_t recv[SNAP_PROTO_N];
    u32_t xmit[SNAP_PROTO_N];
    u32_t drop[SNAP_PROTO_N];
    u32_t memerr[SNAP_PROTO_N];
} net_snap_t;

/*
 * 回执上下文。带代际号的原因：tcpip 卡死后放弃等待时，迟到的旧回调仍会在
 * 恢复后被补跑——代际不符就吞掉它的应答；专用共享缓冲承接迟到写入，
 * 调用方只在成功时 memcpy，迟到者污染不到任何新数据。
 */
typedef struct {
    SemaphoreHandle_t sem;
    net_snap_t buf; /* 回调唯一可写缓冲（迟到者也只写这里） */
    volatile uint32_t gen;
} snap_ctl_t;

static snap_ctl_t s_snap;

static void net_snap_cb(void *ctx)
{
    snap_ctl_t *ctl = (snap_ctl_t *)ctx;
    uint32_t my_gen = ctl->gen;
    const struct stats_proto *src[SNAP_PROTO_N] = {
        &lwip_stats.link, &lwip_stats.ip, &lwip_stats.icmp,
        &lwip_stats.tcp,  &lwip_stats.udp,
    };
    for (int i = 0; i < SNAP_PROTO_N; i++) {
        ctl->buf.recv[i]   = src[i]->recv;
        ctl->buf.xmit[i]   = src[i]->xmit;
        ctl->buf.drop[i]   = src[i]->drop;
        ctl->buf.memerr[i] = src[i]->memerr;
    }
    if (ctl->gen == my_gen) { /* 只给当前代回执 */
        xSemaphoreGive(ctl->sem);
    }
}

/* wait_ms 内没等到回执 = tcpip 线程没有消化任何消息。false 时 *late_may_arrive */
static bool net_snapshot(net_snap_t *out, int64_t wait_ms)
{
    memset(&s_snap.buf, 0, sizeof(s_snap.buf));
    xSemaphoreTake(s_snap.sem, 0); /* 清掉上一次迟到留下的余票 */
    s_snap.gen++;
    if (tcpip_callback(net_snap_cb, &s_snap) != ERR_OK) {
        return false; /* 投递本身失败（几乎不可能：memp 已全堆化） */
    }
    if (xSemaphoreTake(s_snap.sem, pdMS_TO_TICKS(wait_ms)) == pdTRUE) {
        /* 再验一次代际：超时路线里迟到的回执已把这一代的票消耗掉了？
         * 不会——超时路线我们没有 bump gen，这里读到的仍是本代结果 */
        memcpy(out, &s_snap.buf, sizeof(*out));
        return true;
    }
    return false; /* tcpip 无回执：冻结证据 */
}

/* 差值按计数器原生宽度回卷（LWIP_STATS_LARGE=n 时为 u16） */
static unsigned long c_delta(u32_t cur, u32_t prev)
{
#if LWIP_STATS_LARGE
    return (unsigned long)(cur >= prev ? cur - prev : 0);
#else
    return (unsigned long)(u16_t)(cur - prev);
#endif
}

#else /* !LWIP_STATS：降级路径 */

typedef struct {
    unsigned char pad;
} net_snap_t;
static bool net_snapshot(net_snap_t *out, int64_t wait_ms)
{
    (void)out;
    (void)wait_ms;
    return false;
}
static unsigned long c_delta(u32_t cur, u32_t prev)
{
    (void)cur;
    (void)prev;
    return 0;
}

#endif /* LWIP_STATS */

/* ================================================================
 * 观测原语 B：任务表 + run-time 统计（uxTaskGetSystemState 一手数据）
 * ================================================================ */

static const char *state_str(eTaskState st)
{
    switch (st) {
    case eRunning:
        return "running";
    case eReady:
        return "ready";
    case eBlocked:
        return "blocked";
    case eSuspended:
        return "suspend";
    case eDeleted:
        return "deleted";
    default:
        return "invalid";
    }
}

#if CONFIG_FREERTOS_USE_TRACE_FACILITY

/* 任务表快照缓冲：条目数运行期才知道，静态上限足够覆盖全系统任务 */
#define TASK_MAX 24

typedef struct {
    char name[configMAX_TASK_NAME_LEN];
    eTaskState state;
    UBaseType_t prio;
    BaseType_t core;
    unsigned long hwm;
    unsigned long long rt_us;
} task_row_t;

static task_row_t s_rows_prev[TASK_MAX]; /* 上帧存档，算窗口增量占比 */
static UBaseType_t s_rows_prev_n;

/* 插入排序按名字典序——保证帧间行序稳定，diff 才不失真 */
static void rows_sort(task_row_t *r, UBaseType_t n)
{
    for (UBaseType_t i = 1; i < n; i++) {
        task_row_t tmp = r[i];
        UBaseType_t j = i;
        while (j > 0 && strcmp(tmp.name, r[j - 1].name) < 0) {
            r[j] = r[j - 1];
            j--;
        }
        r[j] = tmp;
    }
}

static UBaseType_t rows_take(task_row_t *out, UBaseType_t cap)
{
    UBaseType_t n = uxTaskGetNumberOfTasks();
    if (n > cap) {
        n = cap; /* 超限截断（实际系统 ~14 条，远低于上限） */
    }
    TaskStatus_t st[TASK_MAX];
    n = uxTaskGetSystemState(st, n, NULL);
    for (UBaseType_t i = 0; i < n; i++) {
        snprintf(out[i].name, sizeof(out[i].name), "%s", st[i].pcTaskName);
        out[i].state = st[i].eCurrentState;
        out[i].prio = st[i].uxCurrentPriority;
        out[i].core = st[i].xCoreID;
        out[i].hwm = (unsigned long)st[i].usStackHighWaterMark;
        out[i].rt_us = (unsigned long long)st[i].ulRunTimeCounter;
    }
    rows_sort(out, n);
    return n;
}

static void rows_find_prev(const char *name, unsigned long long *rt_us)
{
    for (UBaseType_t i = 0; i < s_rows_prev_n; i++) {
        if (strcmp(s_rows_prev[i].name, name) == 0) {
            *rt_us = s_rows_prev[i].rt_us;
            return;
        }
    }
    *rt_us = 0;
}

/*
 * 任务表打印一行一个任务：状态/优先级/核/栈高水位/run-time 计数（µs 时钟）/
 * 相对上一帧的增量占比。rt 栏是 sc1 的定罪证据：spinner 的增速会吃掉几乎
 * 全部份额，而被饿死的低优任务增长近乎停滞。
 */
static void gym_task_table(void)
{
    task_row_t rows[TASK_MAX];
    UBaseType_t n = rows_take(rows, TASK_MAX);

    unsigned long long total_d = 0;
    unsigned long long d[TASK_MAX];
    for (UBaseType_t i = 0; i < n; i++) {
        unsigned long long p = 0;
        rows_find_prev(rows[i].name, &p);
        d[i] = rows[i].rt_us >= p ? rows[i].rt_us - p : 0;
        total_d += d[i];
    }

    printf("EX15-TASK n=%u order=name_asc clock=esp_timer-1MHz\n", (unsigned)n);
    for (UBaseType_t i = 0; i < n; i++) {
        const char *cs =
            (rows[i].core == tskNO_AFFINITY) ? "NA" : (rows[i].core == 0 ? "0" : "1");
        unsigned long long share_x10 = total_d ? d[i] * 1000ULL / total_d : 0;
        printf("EX15-T %-16s st=%-8s prio=%2u core=%-2s hwm=%5lu rt_us=%-10llu "
               "win_ms=%llu share=%llu.%01lu%%\n",
               rows[i].name, state_str(rows[i].state), (unsigned)rows[i].prio, cs,
               rows[i].hwm, rows[i].rt_us, d[i] / 1000ULL, share_x10 / 10,
               (unsigned long)(share_x10 % 10));
    }

    /* 存档本帧供下帧求差 */
    memcpy(s_rows_prev, rows, sizeof(task_row_t) * n);
    s_rows_prev_n = n;
}

#else

static void gym_task_table(void)
{
    printf("EX15-TASK disabled reason=CONFIG_FREERTOS_USE_TRACE_FACILITY=n\n");
}

#endif /* CONFIG_FREERTOS_USE_TRACE_FACILITY */

/* ================================================================
 * 双层心跳之一：RTOS 层心跳（刻意低优先级 —— 各场景的标准受害样本）
 * ================================================================ */

typedef struct {
    uint32_t seq;              /* 已打出拍数 */
    volatile int64_t last_ms;  /* 最近一拍的绝对时刻 */
} hb_state_t;

static hb_state_t s_hb;

static void hb_task(void *arg)
{
    (void)arg;
    TickType_t next_wake = xTaskGetTickCount(); /* 锚点取当前 tick（约定教训） */
    int64_t planned_rel = 0;
    for (;;) {
        vTaskDelayUntil(&next_wake, pdMS_TO_TICKS(HB_PERIOD_MS));
        planned_rel += HB_PERIOD_MS;
        int64_t lag = rel_ms() - planned_rel;
        if (lag < 0) {
            lag = 0; /* 早于计划不存在；vTaskDelayUntil 只会晚不会早 */
        }
        s_hb.seq++;
        s_hb.last_ms = now_ms();
        printf("EX15-HB seq=%lu planned_rel_ms=%lld lag_ms=%lld prio=%d\n",
               (unsigned long)s_hb.seq, (long long)planned_rel, (long long)lag,
               CONFIG_EX15_HB_PRIO);
    }
}

/* 调度层告警（观测者侧巡检）：一次缺席超过阈值即升旗，恢复后降旗补账 */
static bool s_sched_alarm;
static uint32_t s_sched_alarm_seq; /* 升旗时的拍序号 */

static void sched_alarm_watch(void)
{
    int64_t gap = now_ms() - s_hb.last_ms;
    if (!s_sched_alarm && gap > SCHED_GAP_ALARM_MS) {
        s_sched_alarm = true;
        s_sched_alarm_seq = s_hb.seq;
        s_alarms_sched++;
        printf("$$$ EX15-ALARM kind=sched gap_ms=%lld last_seq=%lu "
               "threshold_ms=%lld (no beat since t+%lld ms)\n",
               (long long)gap, (unsigned long)s_hb.seq,
               (long long)SCHED_GAP_ALARM_MS, (long long)(s_hb.last_ms - s_ready_ms));
    }
    if (s_sched_alarm && gap <= 2 * HB_PERIOD_MS) {
        s_sched_alarm = false;
        printf("$$$ EX15-RECOVER kind=sched gap_back_to=%lldms "
               "beats_missing=%lu alarms_total=%u\n",
               (long long)gap, (unsigned long)(s_hb.seq - s_sched_alarm_seq),
               s_alarms_sched);
    }
}

/* ================================================================
 * 双层心跳之二：网络层心跳（esp_ping 单会话 ping 网关，ch3/ch9 单会话纪律）
 * ================================================================ */

typedef struct {
    uint32_t ok, tout;
    uint32_t consec_fail;
    uint32_t rtt_last_ms, rtt_min_ms, rtt_max_ms;
    bool alarm;
    int64_t alarm_at_ms;   /* 本次网络告警起点 */
    uint32_t alarm_ok0;    /* 升旗时累计成功数（算停摆期丢账） */
} net_mon_t;

static net_mon_t s_nm;

static void nm_on_success(esp_ping_handle_t hdl, void *args)
{
    (void)args;
    uint16_t seqno;
    uint32_t rtt_ms;
    esp_ping_get_profile(hdl, ESP_PING_PROF_SEQNO, &seqno, sizeof(seqno));
    esp_ping_get_profile(hdl, ESP_PING_PROF_TIMEGAP, &rtt_ms, sizeof(rtt_ms));

    s_nm.ok++;
    s_nm.consec_fail = 0;
    s_nm.rtt_last_ms = rtt_ms;
    if (s_nm.rtt_min_ms == 0 || rtt_ms < s_nm.rtt_min_ms) {
        s_nm.rtt_min_ms = rtt_ms;
    }
    if (rtt_ms > s_nm.rtt_max_ms) {
        s_nm.rtt_max_ms = rtt_ms;
    }

    if (s_nm.alarm) {
        s_nm.alarm = false;
        printf("$$$ EX15-RECOVER kind=net downtime_ms=%lld lost_during=%lu "
               "ok_total=%lu (path serving again)\n",
               (long long)(now_ms() - s_nm.alarm_at_ms),
               (unsigned long)s_nm.consec_fail, (unsigned long)s_nm.ok);
    }
    printf("EX15-NET seq=%u rtt_ms=%lu ok=%lu tout=%lu\n", seqno,
           (unsigned long)rtt_ms, (unsigned long)s_nm.ok, (unsigned long)s_nm.tout);
}

static void nm_on_timeout(esp_ping_handle_t hdl, void *args)
{
    (void)hdl;
    (void)args;
    s_nm.tout++;
    s_nm.consec_fail++;
    printf("EX15-NETTOUT consec=%u/%u ok_total=%lu\n",
           (unsigned)s_nm.consec_fail, (unsigned)CONFIG_EX15_NET_ALARM_AFTER,
           (unsigned long)s_nm.ok);

    if (!s_nm.alarm && s_nm.consec_fail >= CONFIG_EX15_NET_ALARM_AFTER) {
        s_nm.alarm = true;
        s_nm.alarm_at_ms = now_ms();
        s_nm.alarm_ok0 = s_nm.ok;
        s_alarms_net++;
        printf("$$$ EX15-ALARM kind=net consec_lost=%u at_rel_ms=%lld "
               "(gateway echo missing)\n",
               (unsigned)s_nm.consec_fail, (long long)rel_ms());
    }
}

static void start_net_heartbeat(const esp_ip4_addr_t *gw)
{
    ip_addr_t target;
    memset(&target, 0, sizeof(target));
    IP_SET_TYPE_VAL(target, IPADDR_TYPE_V4);
    ip4_addr_set_u32(ip_2_ip4(&target), gw->addr);

    esp_ping_config_t cfg = ESP_PING_DEFAULT_CONFIG();
    cfg.target_addr = target;
    cfg.count       = ESP_PING_COUNT_INFINITE;
    cfg.interval_ms = CONFIG_EX15_PING_INTERVAL_MS;
    cfg.timeout_ms  = CONFIG_EX15_PING_TIMEOUT_MS;

    esp_ping_callbacks_t cbs;
    memset(&cbs, 0, sizeof(cbs));
    cbs.on_ping_success = nm_on_success;
    cbs.on_ping_timeout = nm_on_timeout;

    esp_ping_handle_t hdl = NULL;
    ESP_ERROR_CHECK(esp_ping_new_session(&cfg, &cbs, &hdl));
    esp_ping_start(hdl);
    printf("EX15-NETSRC target=" IPSTR " interval_ms=%d timeout_ms=%d "
           "alarm_after=%d\n",
           IP2STR(gw), CONFIG_EX15_PING_INTERVAL_MS, CONFIG_EX15_PING_TIMEOUT_MS,
           CONFIG_EX15_NET_ALARM_AFTER);
    /* 句柄刻意不 delete：网络心跳贯穿全部场景生命周期（见 README） */
}

/* ================================================================
 * 诊断帧：每个场景的诊断节都真实调用这些观测原语并输出
 * ================================================================ */

static SemaphoreHandle_t s_diag_lock; /* 帧 = 不可分割的多行块（防交错） */
static unsigned s_frame_id;

static void heap_line(void)
{
    printf("EX15-HEAP free=%u largest=%u min_ever=%u cap=MALLOC_CAP_8BIT\n",
           (unsigned)heap_caps_get_free_size(MALLOC_CAP_8BIT),
           (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_8BIT),
           (unsigned)heap_caps_get_minimum_free_size(MALLOC_CAP_8BIT));
}

static void diag_frame(const char *phase)
{
    unsigned id = ++s_frame_id;
    xSemaphoreTake(s_diag_lock, portMAX_DELAY);

    printf("$$$ EX15-FRAME id=%u phase=%s rel_ms=%lld sc=%s fault=%d\n", id,
           phase, (long long)rel_ms(), SC_NAME, (int)s_fault_active);
    printf("EX15-HBSUM beats=%lu last_gap_ms=%lld alarms_sched=%u%s\n",
           (unsigned long)s_hb.seq,
           (long long)(now_ms() - s_hb.last_ms), s_alarms_sched,
           s_sched_alarm ? " latch=ACTIVE" : "");
    printf("EX15-NETSUM ok=%lu tout=%lu consec=%u rtt_last=%lu rtt_min=%lu "
           "rtt_max=%lu alarms_net=%u%s\n",
           (unsigned long)s_nm.ok, (unsigned long)s_nm.tout,
           (unsigned)s_nm.consec_fail, (unsigned long)s_nm.rtt_last_ms,
           (unsigned long)s_nm.rtt_min_ms, (unsigned long)s_nm.rtt_max_ms,
           s_alarms_net, s_nm.alarm ? " latch=ACTIVE" : "");

#if LWIP_STATS
    {
        static net_snap_t prev;
        static bool have_prev;
        net_snap_t cur;
        /* 快照等待 1500ms：健康时亚毫秒级回来；卡死时超时本身就是一手证据 */
        if (net_snapshot(&cur, 1500)) {
            if (!have_prev) {
                printf("EX15-ST basis=first-frame (deltas appear next frame)\n");
            } else {
                for (int i = 0; i < SNAP_PROTO_N; i++) {
                    printf("EX15-ST %-5s recv=%lu(+%lu) xmit=%lu(+%lu) "
                           "drop=%lu(+%lu) memerr=%lu(+%lu)\n",
                           s_proto_names[i], (unsigned long)cur.recv[i],
                           c_delta(cur.recv[i], prev.recv[i]),
                           (unsigned long)cur.xmit[i],
                           c_delta(cur.xmit[i], prev.xmit[i]),
                           (unsigned long)cur.drop[i],
                           c_delta(cur.drop[i], prev.drop[i]),
                           (unsigned long)cur.memerr[i],
                           c_delta(cur.memerr[i], prev.memerr[i]));
                }
            }
            prev = cur;
            have_prev = true;
        } else {
            printf("EX15-ST disabled reason=tcpip_no_ack wait_ms=1500 "
                   "(tcpip thread processed NOTHING for 1.5s)\n");
        }
    }
#else
    printf("EX15-ST disabled reason=CONFIG_LWIP_STATS=n\n");
#endif

    if (CONFIG_GYM_SCENARIO == SC_MBOX) {
        mbx_report_inner(); /* sc3 专属观测节：邮箱水位代理 + 投递等待分布 */
    }

    gym_task_table();
    heap_line();
    printf("$$$ EX15-FRAME-END id=%u\n", id);
    fflush(stdout);
    xSemaphoreGive(s_diag_lock);
}

/* ================================================================
 * 场景执行器
 * ================================================================ */

/* ------------------------- sc1 优先级倒挂 ------------------------- */

#if CONFIG_GYM_SCENARIO == SC_PRIO

/*
 * 两核各钉一个自旋任务（默认 prio 20：压过 tcpip=18 和一切受害者，留出
 * 观测者 22 的活路）。占空比 CONFIG_EX15_SC1_DUTY_PCT：
 *   100%（默认）   两核满转 = ch19 duty=100 全灭样本，serial 无声；
 *   70%~85%        分水岭区间，心跳半死（欢迎改配置复测 ch19 表格）。
 */
static void spinner_task(void *arg)
{
    int core = (int)(intptr_t)arg;
    int64_t cycle_us = 100000;               /* 100ms 周期 */
    int64_t work_us = cycle_us * CONFIG_EX15_SC1_DUTY_PCT / 100;
    printf("EX15-SPIN start core=%d prio=%d duty=%d work_us=%lld\n", core,
           CONFIG_EX15_SC1_SPIN_PRIO, CONFIG_EX15_SC1_DUTY_PCT,
           (long long)work_us);
    uint64_t rounds = 0;
    while (s_fault_active) {
        burn_until(now_us() + work_us, &s_fault_active);
        int64_t rest_us = cycle_us - work_us;
        if (rest_us > 0 && s_fault_active) {
            vTaskDelay(pdMS_TO_TICKS(rest_us / 1000));
        }
        rounds++;
    }
    printf("EX15-SPIN exit core=%d rounds=%llu\n", core, (unsigned long long)rounds);
    vTaskDelete(NULL);
}

static TaskHandle_t s_spin[2];

static void sc1_inject(void)
{
    s_fault_active = true;
    for (int c = 0; c < 2; c++) {
        char name[configMAX_TASK_NAME_LEN];
        snprintf(name, sizeof(name), "spin_c%d", c);
        BaseType_t rc = xTaskCreatePinnedToCore(spinner_task, name, 2048,
                                                (void *)(intptr_t)c,
                                                CONFIG_EX15_SC1_SPIN_PRIO,
                                                &s_spin[c], c);
        assert(rc == pdPASS);
    }
    printf("EX15-INJECT phase=in event=spinner_pin_both_cores "
           "prio=%d duty=%d victims='hb(5) ping tcpip(18)' silent_by_design=yes\n",
           CONFIG_EX15_SC1_SPIN_PRIO, CONFIG_EX15_SC1_DUTY_PCT);
}

static void sc1_remove(void)
{
    printf("EX15-INJECT phase=out event=spinner_stop\n");
    s_fault_active = false; /* spinner 循环自旋检查此闸门，自然退出自删 */
    /* 给足退出+删 TCB 的时间再打完成行 */
    vTaskDelay(pdMS_TO_TICKS(500));
    printf("EX15-INJECT done=out event=spinner_gone\n");
}

#else /* 其余场景：sc1 符号以空实现兜底，统一编排调用 */

static void sc1_inject(void) {}
static void sc1_remove(void) {}

#endif /* SC_PRIO */

/* ------------------------- sc2 回调慢操作 ------------------------- */

#if CONFIG_GYM_SCENARIO == SC_SLOWCB

#define SLOW_PORT 8320 /* 号段身份端口：8320（SPEC §4 ex15） */

static struct udp_pcb *s_slow_pcb; /* 只在 tcpip_thread 内创建/销毁 */
static volatile uint32_t s_stall_hits;
static int64_t s_last_stall_print_ms;

/* raw 回调本体：跑在 tcpip_thread —— 这就是被拖死的那个"人" */
static void sc2_recv_cb(void *arg, struct udp_pcb *pcb, struct pbuf *p,
                        const ip_addr_t *addr, u16_t port)
{
    (void)arg;
    (void)pcb;
    (void)addr;
    (void)port;
    s_stall_hits++;
    int64_t t = now_ms();
    if (t - s_last_stall_print_ms >= 2000) { /* 2s 节流打印，避免刷屏 */
        s_last_stall_print_ms = t;
        printf("EX15-SLOWCB enter hits=%lu busy_ms=%d "
               "(running INSIDE 'tcpip' -- whole stack stalls)\n",
               (unsigned long)s_stall_hits, CONFIG_EX15_SC2_BUSY_MS);
    }
    int64_t stall_start = now_ms();
    /* 分片忙等：每个 50ms 片检查解除闸门，un-inject 最迟到下一片就生效 */
    burn_ms_checked(CONFIG_EX15_SC2_BUSY_MS, &s_fault_active, 50);
    printf("EX15-SLOWCB leave hits=%lu stalled_ms=%lld aborted_by_gate=%d\n",
           (unsigned long)s_stall_hits, (long long)(now_ms() - stall_start),
           (int)!s_fault_active);
    pbuf_free(p);
}

static void sc2_setup_in_tcpip(void *arg)
{
    (void)arg;
    s_slow_pcb = udp_new();
    assert(s_slow_pcb != NULL);
    err_t err = udp_bind(s_slow_pcb, IP_ANY_TYPE, SLOW_PORT);
    assert(err == ERR_OK);
    udp_recv(s_slow_pcb, sc2_recv_cb, NULL);
    printf("EX15-INJECT arm event=udp_raw_bound port=%d busy_ms=%d "
           "trigger='loopback 127.0.0.1:%d'\n",
           SLOW_PORT, CONFIG_EX15_SC2_BUSY_MS, SLOW_PORT);
}

static void sc2_teardown_in_tcpip(void *arg)
{
    (void)arg;
    if (s_slow_pcb != NULL) {
        udp_remove(s_slow_pcb); /* 连同 recv 回调一并摘除 */
        s_slow_pcb = NULL;
    }
    printf("EX15-INJECT done=out event=udp_raw_removed (stack released)\n");
}

static volatile bool s_pump_run;
static volatile uint32_t s_pump_sent, s_pump_err;
static volatile int64_t s_pump_wait_sum_ms;
static volatile uint32_t s_pump_waits; /* 发送被拖慢的次数（等待>2ms） */
static volatile int64_t s_pump_wait_max_ms;

static void pump_task(void *arg)
{
    (void)arg;
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    assert(fd >= 0);

    struct sockaddr_in dst;
    memset(&dst, 0, sizeof(dst));
    dst.sin_family = AF_INET;
    dst.sin_port = htons(SLOW_PORT);
    /* 127.0.0.1：lwIP 把本机回环内建于 ip4_route 的特判（Batch 3 实测），包不出
     * 网卡、不惊动 SLIRP，经 loop 队列回到 tcpip_thread → udp_input → 慢回调。
     * 发给自身网卡 IP 则会从 openeth 出去被 SLIRP 吞掉——本地短路的只有回环。 */
    dst.sin_addr.s_addr = PP_HTONL(LWIP_MAKEU32(127, 0, 0, 1));
    uint8_t payload[32];
    memset(payload, 0xA5, sizeof(payload));

    int64_t next = now_ms();
    while (s_pump_run) {
        int64_t t0 = now_ms();
        int rc = sendto(fd, payload, sizeof(payload), 0,
                        (struct sockaddr *)&dst, sizeof(dst));
        int64_t waited = now_ms() - t0;
        if (rc < 0) {
            s_pump_err++;
            /* 只在首轮失败打原因：后续静默计数，避免刷屏 */
            printf("EX15-PUMP sendto_failed errno=%d sent=%lu\n", errno,
                   (unsigned long)s_pump_sent);
        }
        if (waited > 2) { /* 正常 send 自环亚毫秒级；>2ms 即是被拖住的证据 */
            s_pump_waits++;
            s_pump_wait_sum_ms += waited;
            if (waited > s_pump_wait_max_ms) {
                s_pump_wait_max_ms = waited;
            }
        }
        s_pump_sent++;
        next += CONFIG_EX15_SC2_PERIOD_MS;
        int64_t d = next - now_ms();
        vTaskDelay(pdMS_TO_TICKS(d > 0 ? d : 0));
    }
    close(fd);
    printf("EX15-PUMP exit sent=%lu slow_sends=%u avg_slow_ms=%lld max_ms=%lld\n",
           (unsigned long)s_pump_sent, (unsigned)s_pump_waits,
           s_pump_waits ? (long long)(s_pump_wait_sum_ms / s_pump_waits) : 0,
           (long long)s_pump_wait_max_ms);
    vTaskDelete(NULL);
}

static TaskHandle_t s_pump_h;

static void sc2_inject(void)
{
    s_fault_active = true;
    ESP_ERROR_CHECK(tcpip_callback(sc2_setup_in_tcpip, NULL));
    s_pump_run = true;
    s_last_stall_print_ms = now_ms();
    xTaskCreate(pump_task, "sc2_pump", 3072, NULL, 8, &s_pump_h);
    printf("EX15-INJECT phase=in event=slow_callback_armed "
           "busy_ms=%d trigger_period_ms=%d\n",
           CONFIG_EX15_SC2_BUSY_MS, CONFIG_EX15_SC2_PERIOD_MS);
}

static void sc2_remove(void)
{
    printf("EX15-INJECT phase=out event=slow_callback_disarm\n");
    s_fault_active = false; /* 让进行中的忙等最多 50ms 后中断 */
    vTaskDelay(pdMS_TO_TICKS(200));
    s_pump_run = false;
    vTaskDelay(pdMS_TO_TICKS(300)); /* 泵打最后一行收尾 */
    ESP_ERROR_CHECK(tcpip_callback(sc2_teardown_in_tcpip, NULL));
}

#else

static void sc2_inject(void) {}
static void sc2_remove(void) {}

#endif /* SC_SLOWCB */

/* ------------------------- sc3 邮箱打满 ------------------------- */

#if CONFIG_GYM_SCENARIO == SC_MBOX

static volatile uint32_t s_mbx_try_ok, s_mbx_try_fail; /* 已合并的总量（退出时入账） */
/* 工人在途计数：每拍由报告方现场求和——否则邮箱水位只在工人退场后才可见 */
static volatile uint32_t s_wip_ok[CONFIG_EX15_SC3_WORKERS];
static volatile uint32_t s_wip_fail[CONFIG_EX15_SC3_WORKERS];
static volatile uint32_t s_mbx_blk_n;                          /* 阻塞投递计数 */
static volatile int64_t s_mbx_blk_sum_us, s_mbx_blk_max_us;
static uint32_t s_mbx_mark_ok, s_mbx_mark_fail; /* 上一诊断帧存档（差值口径） */

/* 现场（瞬时一致）求和：单写者槽位化，读取容忍极小的撕裂误差（统计口径） */
static uint32_t mbx_totals(uint32_t *ok, uint32_t *fail)
{
    *ok = s_mbx_try_ok;
    *fail = s_mbx_try_fail;
    for (int i = 0; i < CONFIG_EX15_SC3_WORKERS; i++) {
        *ok += s_wip_ok[i];
        *fail += s_wip_fail[i];
    }
    return 0;
}

/* 被淹没端的工作负载：真实系统投进邮箱的消息本来就带工作量（诚实模拟） */
static void sc3_work_cb(void *arg)
{
    (void)arg;
#if CONFIG_EX15_SC3_WORK_US > 0
    burn_us(CONFIG_EX15_SC3_WORK_US);
#endif
}

static void flood_worker(void *arg)
{
    (void)arg;
    uint32_t id = (uint32_t)(uintptr_t)arg;
    uint32_t ok = 0, fail = 0;
    while (s_fault_active) {
        if (tcpip_try_callback(sc3_work_cb, NULL) == ERR_OK) {
            ok++;
        } else {
            fail++; /* 邮箱满 = ERR_MEM：失败即返语义的现场 */
        }
        /* 节流阀：投递间隙强制睡 PACE_MS。没有它，三个永不让路的
         * 生产者会顺带把比它们优先级更低的心跳也饿死——那是场景 1 的剧本。
         * 场景隔离是健身房的基本礼仪：本场景只讲邮箱水位这一件事。 */
        vTaskDelay(pdMS_TO_TICKS(CONFIG_EX15_SC3_PACE_MS));
        s_wip_ok[id]   = ok;
        s_wip_fail[id] = fail;
    }
    s_wip_ok[id]   = 0;
    s_wip_fail[id] = 0;
    s_mbx_try_ok += ok;
    s_mbx_try_fail += fail;
    printf("EX15-FLOODER exit id=%lu ok=%lu fail=%lu\n", (unsigned long)id,
           (unsigned long)ok, (unsigned long)fail);
    vTaskDelete(NULL);
}

/*
 * 容量探针：一口气连投 N 发 try，前 ~32 发应该全收（=邮箱硬容量），
 * 之后开始瞬时失败——ch13 实验 D"第 33 发精确阻塞"的本示例变体：
 * 用 try 语义展示同一容量边界（第 33 发起 ERR_MEM）。
 */
static void burst_probe(void *arg)
{
    (void)arg;
    uint32_t ok = 0, fail = 0;
    for (int i = 0; i < CONFIG_EX15_SC3_BURST_N; i++) {
        if (tcpip_try_callback(sc3_work_cb, NULL) == ERR_OK) {
            ok++;
        } else {
            fail++;
        }
    }
    s_mbx_try_ok += ok;
    s_mbx_try_fail += fail;
    printf("EX15-MBXEV kind=capacity_probe posted=%u accepted=%lu rejected=%lu "
           "(accepted≈TCPIP_MBOX_SIZE=CONFIG_LWIP_TCPIP_RECVMBOX_SIZE=32)\n",
           CONFIG_EX15_SC3_BURST_N, (unsigned long)ok, (unsigned long)fail);
    vTaskDelete(NULL);
}

/*
 * 阻塞语义探针（pacemaker）：每 300ms 一次阻塞投递，量投递等待时长分布。
 * 饱和期该值从 ~µs 涨到 ms 级 = "背压沿传导链爬上来"的直接观测。
 */
static void block_probe_task(void *arg)
{
    (void)arg;
    while (s_fault_active) {
        int64_t t0 = now_us();
        tcpip_callback(sc3_work_cb, NULL); /* 满则睡到有槽位 */
        int64_t w = now_us() - t0;
        s_mbx_blk_n++;
        s_mbx_blk_sum_us += w;
        if (w > s_mbx_blk_max_us) {
            s_mbx_blk_max_us = w;
        }
        vTaskDelay(pdMS_TO_TICKS(300));
    }
    vTaskDelete(NULL);
}

static void mbx_report_inner(void)
{
    uint32_t ok = 0, fail = 0;
    mbx_totals(&ok, &fail);
    uint32_t dok = ok - s_mbx_mark_ok, dfail = fail - s_mbx_mark_fail;
    s_mbx_mark_ok = ok;
    s_mbx_mark_fail = fail;
    uint64_t tot = (uint64_t)dok + dfail;
    unsigned long sat_x10 = tot ? (unsigned long)(dfail * 1000ULL / tot) : 0;
    printf("EX15-MBX mode=%s try_ok=%lu(+%lu) try_full=%lu(+%lu) "
           "satur=%lu.%01lu%% blk_n=%lu blk_avg_us=%lld blk_max_us=%lld "
           "cap_slots=32 recvmbox_kconfig=%d\n",
           s_fault_active ? "flooded" : "quiescent", (unsigned long)ok,
           (unsigned long)dok, (unsigned long)fail, (unsigned long)dfail,
           sat_x10 / 10, sat_x10 % 10, (unsigned long)s_mbx_blk_n,
           s_mbx_blk_n ? (long long)(s_mbx_blk_sum_us / s_mbx_blk_n) : 0,
           (long long)s_mbx_blk_max_us, CONFIG_LWIP_TCPIP_RECVMBOX_SIZE);
}

static TaskHandle_t s_flooders[CONFIG_EX15_SC3_WORKERS];

static void sc3_inject(void)
{
    s_fault_active = true;
    printf("EX15-INJECT phase=in event=mbox_flood workers=%d burst=%d work_us=%d "
           "(mailbox capacity = CONFIG_LWIP_TCPIP_RECVMBOX_SIZE=32 slots)\n",
           CONFIG_EX15_SC3_WORKERS, CONFIG_EX15_SC3_BURST_N,
           CONFIG_EX15_SC3_WORK_US);
    xTaskCreate(burst_probe, "mbx_burst", 2560, NULL, 10, NULL);
    for (int i = 0; i < CONFIG_EX15_SC3_WORKERS; i++) {
        char name[configMAX_TASK_NAME_LEN];
        snprintf(name, sizeof(name), "mbx_flood%d", i);
        xTaskCreate(flood_worker, name, 2560, (void *)(uintptr_t)i, 10,
                    &s_flooders[i]);
    }
    xTaskCreate(block_probe_task, "mbx_blkprobe", 2560, NULL, 11, NULL);
}

static void sc3_remove(void)
{
    printf("EX15-INJECT phase=out event=mbox_flood_stop\n");
    s_fault_active = false; /* 所有 flood/probe 循环自然退场 */
    vTaskDelay(pdMS_TO_TICKS(600)); /* 等 exit 行打完 */
    /* 收尾确认由编排器的 MBX_RECOVER 巡检给出 RECOVER 行 */
}

#else

static void sc3_inject(void) {}
static void sc3_remove(void) {}
static void mbx_report_inner(void) {}

#endif /* SC_MBOX */

/* ------------------------- sc4 栈余量耗尽 ------------------------- */

#if CONFIG_GYM_SCENARIO == SC_STACK

/*
 * 填栈护栏的实测依据（见 EX15_SC4_STOP_MARGIN 的 help）：首版把绝对地板定为
 * 192B，lvl=11 时 hwm_free 只剩 92B，而下一步之间的 printf 自己还要压几百字节
 * 栈 —— 结果真溢出，Backtrace 出现 "0xa5a5a5a5 |<-CORRUPTED"。教学目标是告警，
 * 不是表演崩溃：地板必须覆盖"留在栈上继续执行的代码"自身的需求。
 */
#define STACK_DEPTH_CAP 24

typedef struct {
    volatile int lvl;          /* 当前栈深层数 */
    volatile int hwm_now;      /* 受害者实测栈余量 */
    volatile bool alarm_hit;   /* 是否越过告警阈值（每轮只置位一次） */
    volatile int hwm_min_seen;
    volatile bool filling;     /* 填栈阶段进行中 */
    volatile bool done_unwind; /* 一轮完整填栈+回退结束 */
} stk_state_t;

static stk_state_t s_stk;
static TaskHandle_t s_stkburn_h;
static int s_stk_round;               /* 轮次：1=演示填栈，>=2=重建复位演示 */

/* 读回写穿防优化：GCC 无法删除带"读取+异或进全局"的局部数组初始化 */
static volatile uint32_t s_stack_touch_sink;

static void stk_descend(int lvl)
{
    volatile char pad[CONFIG_EX15_SC4_CHUNK];
    memset((void *)pad, 0xA5, sizeof(pad));
    for (size_t i = 0; i < sizeof(pad); i += 8) {
        s_stack_touch_sink ^= (uint32_t)pad[i];
    }

    int hwm = (int)uxTaskGetStackHighWaterMark(NULL); /* 自己量自己最准 */
    s_stk.lvl = lvl;
    s_stk.hwm_now = hwm;
    if (hwm < s_stk.hwm_min_seen) {
        s_stk.hwm_min_seen = hwm;
    }
    printf("EX15-STKSTEP lvl=%d chunk=%d hwm_free=%d min_seen=%d\n", lvl,
           (int)sizeof(pad), hwm, s_stk.hwm_min_seen);
    if (!s_stk.alarm_hit && hwm < CONFIG_EX15_SC4_ALARM_HWM) {
        s_stk.alarm_hit = true;
        s_alarms_stk++;
        printf("$$$ EX15-ALARM kind=stk task=ex15_stkburn hwm=%d below=%d lvl=%d "
               "(high-water alarm design point)\n",
               hwm, CONFIG_EX15_SC4_ALARM_HWM, lvl);
    }
    if (hwm <= CONFIG_EX15_SC4_STOP_MARGIN || lvl >= STACK_DEPTH_CAP) {
        return; /* 到底了：绝不真溢出——教学演示的安全护栏（实测教训见上） */
    }
    vTaskDelay(pdMS_TO_TICKS(400)); /* 放慢步进让日志可读、观测者可采样 */
    stk_descend(lvl + 1);

    /* 回退路径：HWM 是历史极值，只会停在 min_seen，不会随弹栈回升——
     * 这里如实展示这个"单调性"教学点 */
    int back = (int)uxTaskGetStackHighWaterMark(NULL);
    printf("EX15-STKUNWIND from_lvl=%d hwm_min_sofar=%d (monotonic, NOT current "
           "free)\n",
           lvl, back);
}

static void stkburn_task(void *arg)
{
    (void)arg;
    vTaskDelay(pdMS_TO_TICKS(200)); /* 等本任务栈底稳定 */
    memset((void *)&s_stk, 0, sizeof(s_stk));
    int hwm0 = (int)uxTaskGetStackHighWaterMark(NULL);
    s_stk.hwm_min_seen = hwm0;
    s_stk.filling = true;
    printf("EX15-STKSTART round=%d task=ex15_stkburn depth_words=%d "
           "hwm_initial=%d alarm_below=%d chunk=%d\n",
           s_stk_round, CONFIG_EX15_SC4_STACK_BYTES / (int)sizeof(StackType_t),
           hwm0, CONFIG_EX15_SC4_ALARM_HWM, CONFIG_EX15_SC4_CHUNK);

    if (s_stk_round == 1) {
        stk_descend(0); /* 只有第一轮真的下潜；重建轮只量初始水位即可 */
        int hwm_end = (int)uxTaskGetStackHighWaterMark(NULL);
        printf("EX15-STKDONE round=%d hwm_final=%d min_seen=%d note='HWM is "
               "monotonic: unwinding does NOT restore it; only recreation resets'\n",
               s_stk_round, hwm_end, s_stk.hwm_min_seen);
    } else {
        s_stk.hwm_now   = hwm0; /* 暴露给编排器：重建后的新鲜满格水位 */
        s_stk.hwm_min_seen = hwm0;
        printf("EX15-STKDONE round=%d note='fresh task => fresh HWM baseline'\n",
               s_stk_round);
    }
    s_stk.done_unwind = true;
    s_stk.filling = false;
    vTaskDelete(NULL);
}

static bool sc4_spawn_round(void)
{
    s_stk_round++;
    BaseType_t rc =
        xTaskCreate(stkburn_task, "ex15_stkburn",
                    CONFIG_EX15_SC4_STACK_BYTES / sizeof(StackType_t), NULL, 12,
                    &s_stkburn_h);
    if (rc != pdPASS) {
        printf("$$$ EXFAIL reason=stkburn_create round=%d\n", s_stk_round);
        return false;
    }
    return true;
}

static void sc4_wait_round_done(int64_t timeout_ms)
{
    int64_t deadline = now_ms() + timeout_ms;
    while (!s_stk.done_unwind && now_ms() < deadline) {
        vTaskDelay(pdMS_TO_TICKS(200));
    }
}

static void sc4_inject(void)
{
    printf("EX15-INJECT phase=in event=stk_fill_armed stack_bytes=%d chunk=%d "
           "alarm_below=%d stop_margin=%d\n",
           CONFIG_EX15_SC4_STACK_BYTES, CONFIG_EX15_SC4_CHUNK,
           CONFIG_EX15_SC4_ALARM_HWM, CONFIG_EX15_SC4_STOP_MARGIN);
    sc4_spawn_round();
}

static void sc4_remove(void)
{
    /* 填栈全程受 STOP_MARGIN 护栏保护早已结束；此处等一轮收尾后重建任务，
     * 用"新任务的 HWM 从满格重新开始"证明高水位复位必须靠重建。 */
    sc4_wait_round_done(12000);
    int min_seen_r1 = s_stk.hwm_min_seen;
    vTaskDelay(pdMS_TO_TICKS(300));

    printf("EX15-INJECT phase=out event=stk_recreate (fresh task => fresh HWM)\n");
    s_stk.done_unwind = false; /* 先清标志再换代，防止等的是上一轮的遗训 */
    if (sc4_spawn_round()) { /* 第二轮：只汇报初始水位即退场，不再触发告警 */
        sc4_wait_round_done(6000);
        printf("$$$ EX15-RECOVER kind=stk round1_min_seen=%d "
               "round2_fresh_initial_hwm=%d (reset by task recreation)\n",
               min_seen_r1, s_stk.hwm_now);
    }
}

#else

static void sc4_inject(void) {}
static void sc4_remove(void) {}

#endif /* SC_STACK */

/* ================================================================
 * 独立告警看门狗：全窗 250ms 巡检 kind=sched
 * 为什么独立成任务：编排器在诊断帧里会被 tcpip 无回执超时拖住 1.5s/帧，
 * 告警必须由不参与时间轴的旁路发出（ch19 控制面纪律的观测侧应用）。
 * ================================================================ */

static void gym_watchdog(void *arg)
{
    (void)arg;
    while (rel_ms() < RUN_WINDOW_MS + 5000) {
        sched_alarm_watch();
        vTaskDelay(pdMS_TO_TICKS(OBS_TICK_MS));
    }
    vTaskDelete(NULL);
}

/* ================================================================
 * 编排器：起振 → 注入 → 观测 → 解除 的公共时间轴
 * ================================================================ */

static void gym_orchestrator(void *arg)
{
    (void)arg;
    const bool has_fault = (CONFIG_GYM_SCENARIO != SC_BASELINE);

    /* -- 基线帧：所有场景的第一份对照材料 -- */
    vTaskDelay(pdMS_TO_TICKS(1500));
    diag_frame("baseline");

    if (has_fault) {
        while (rel_ms() < INJECT_AT_MS) {
            vTaskDelay(pdMS_TO_TICKS(OBS_TICK_MS));
        }
        printf("== EX15-PHASE name=inject t=%.1fs ==\n", (double)rel_ms() / 1000.0);
        /* 运行期按编译常量分派：所有场景执行器在任何构建里都被引用到 */
        switch (CONFIG_GYM_SCENARIO) {
        case SC_PRIO:
            sc1_inject();
            break;
        case SC_SLOWCB:
            sc2_inject();
            break;
        case SC_MBOX:
            sc3_inject();
            break;
        case SC_STACK:
            sc4_inject();
            break;
        default:
            break;
        }

        /* 故障观察窗：两张诊断帧（紧邻 + 中段），MBX/STK 数据在这里成形。
         * 调度层告警由独立的 gym_watchdog 巡检，这里只负责时间轴。 */
        vTaskDelay(pdMS_TO_TICKS(OBS_T1_AFTER_INJECT_MS));
        diag_frame("fault_obs_1");
        vTaskDelay(pdMS_TO_TICKS(OBS_T2_AFTER_INJECT_MS -
                                 OBS_T1_AFTER_INJECT_MS));
        diag_frame("fault_obs_2");

        while (rel_ms() < REMOVE_AT_MS) {
            vTaskDelay(pdMS_TO_TICKS(OBS_TICK_MS));
        }

        printf("== EX15-PHASE name=remove t=%.1fs ==\n",
               (double)rel_ms() / 1000.0);
        switch (CONFIG_GYM_SCENARIO) {
        case SC_PRIO:
            sc1_remove();
            break;
        case SC_SLOWCB:
            sc2_remove();
            break;
        case SC_MBOX:
            sc3_remove();
            break;
        case SC_STACK:
            sc4_remove();
            break;
        default:
            break;
        }

        /* 恢复确认窗：网络心跳的重放/SLOWCB 释放/邮箱静默都在这发生 */
        vTaskDelay(pdMS_TO_TICKS(OBS_T1_AFTER_INJECT_MS));
        diag_frame("post_recover_1");

#if CONFIG_GYM_SCENARIO == SC_MBOX
        {
            int quiet = 0;
            uint32_t ok_snap, fail0, fail_now;
            while (quiet < MBX_RECOVER_CONFIRM_TICKS &&
                   rel_ms() < RUN_WINDOW_MS - 2000) {
                mbx_totals(&ok_snap, &fail0);
                vTaskDelay(pdMS_TO_TICKS(1000));
                mbx_totals(&ok_snap, &fail_now);
                quiet = (fail_now == fail0) ? quiet + 1 : 0;
            }
            s_alarms_mbx++; /* 注入期饱和事件记一笔（饱和率数值见各帧 MBX 行） */
            mbx_totals(&ok_snap, &fail_now);
            printf("$$$ EX15-RECOVER kind=mbx quiet_ticks=%d "
                   "final_try_full=%lu (mailbox drained, posters unblocked)\n",
                   quiet, (unsigned long)fail_now);
        }
#endif

        vTaskDelay(pdMS_TO_TICKS(OBS_T2_AFTER_INJECT_MS -
                                 OBS_T1_AFTER_INJECT_MS));
        diag_frame("post_recover_2");
        while (rel_ms() < RUN_WINDOW_MS) {
            vTaskDelay(pdMS_TO_TICKS(OBS_TICK_MS));
        }
    } else {
        /* 基线轮：等间隔三张观测帧，无故障无告警 */
        vTaskDelay(pdMS_TO_TICKS(15000));
        diag_frame("baseline_obs_1");
        vTaskDelay(pdMS_TO_TICKS(20000));
        diag_frame("baseline_obs_2");
        vTaskDelay(pdMS_TO_TICKS(20000));
        diag_frame("baseline_obs_3");
        while (rel_ms() < RUN_WINDOW_MS) {
            vTaskDelay(pdMS_TO_TICKS(OBS_TICK_MS));
        }
    }

    printf("$$$ EXDONE sc=%d(%s) result=ok alarms[sched=%u net=%u mbx=%u stk=%u] "
           "hb_beats=%lu net_ok=%lu net_tout=%lu window_ms=%lld\n",
           CONFIG_GYM_SCENARIO, SC_NAME, s_alarms_sched, s_alarms_net,
           s_alarms_mbx, s_alarms_stk, (unsigned long)s_hb.seq,
           (unsigned long)s_nm.ok, (unsigned long)s_nm.tout,
           (long long)rel_ms());
    fflush(stdout);
    vTaskDelete(NULL); /* 观察窗收口；进程存活交给 runner timeout */
}

/* ================================================================
 * bring-up（套件标准骨架 §3）与 app_main
 * ================================================================ */

static SemaphoreHandle_t s_got_ip;

static void eth_event_handler(void *arg, esp_event_base_t base, int32_t id,
                              void *data)
{
    (void)arg;
    (void)base;
    (void)data;
    switch (id) {
    case ETHERNET_EVENT_CONNECTED:
        ESP_LOGI(TAG, "[t=%lld ms] ETH_EVENT CONNECTED", (long long)now_ms());
        break;
    case ETHERNET_EVENT_DISCONNECTED:
        ESP_LOGW(TAG, "[t=%lld ms] ETH_EVENT DISCONNECTED", (long long)now_ms());
        break;
    default:
        break;
    }
}

static void ip_event_handler(void *arg, esp_event_base_t base, int32_t id,
                             void *data)
{
    (void)arg;
    (void)base;
    (void)id;
    ip_event_got_ip_t *evt = (ip_event_got_ip_t *)data;
    ESP_LOGI(TAG, "[t=%lld ms] IP_EVENT GOT_IP: ip " IPSTR " gw " IPSTR,
             (long long)now_ms(), IP2STR(&evt->ip_info.ip), IP2STR(&evt->ip_info.gw));
    xSemaphoreGive(s_got_ip);
}

void app_main(void)
{
    ESP_LOGI(TAG, "== ex15 perf-gym-rtos: RTOS scheduling error gym ==");
    printf(
        "$$$ EX15-FACT build=\"%s %s\" scenario=%d name=%s hb_period_ms=%d "
        "sched_gap_alarm_ms=%lld ping_interval_ms=%d ping_timeout_ms=%d "
        "net_alarm_after=%d inject_at_s=%d remove_at_s=%d window_s=%d "
        "trace=%d runtime_stats=%d lwip_stats=%d\n",
        __DATE__, __TIME__, CONFIG_GYM_SCENARIO, SC_NAME, HB_PERIOD_MS,
        (long long)SCHED_GAP_ALARM_MS, CONFIG_EX15_PING_INTERVAL_MS,
        CONFIG_EX15_PING_TIMEOUT_MS, CONFIG_EX15_NET_ALARM_AFTER,
        CONFIG_EX15_INJECT_AT_S, CONFIG_EX15_REMOVE_AT_S,
        CONFIG_EX15_RUN_WINDOW_S, (int)CONFIG_FREERTOS_USE_TRACE_FACILITY,
        (int)CONFIG_FREERTOS_GENERATE_RUN_TIME_STATS, (int)LWIP_STATS);
#if CONFIG_GYM_SCENARIO == SC_PRIO
    printf("EX15-CFGSC spin_prio=%d duty=%d\n", CONFIG_EX15_SC1_SPIN_PRIO,
           CONFIG_EX15_SC1_DUTY_PCT);
#elif CONFIG_GYM_SCENARIO == SC_SLOWCB
    printf("EX15-CFGSC busy_ms=%d trigger_period_ms=%d\n", CONFIG_EX15_SC2_BUSY_MS,
           CONFIG_EX15_SC2_PERIOD_MS);
#elif CONFIG_GYM_SCENARIO == SC_MBOX
    printf("EX15-CFGSC workers=%d burst=%d work_us=%d\n", CONFIG_EX15_SC3_WORKERS,
           CONFIG_EX15_SC3_BURST_N, CONFIG_EX15_SC3_WORK_US);
#elif CONFIG_GYM_SCENARIO == SC_STACK
    printf("EX15-CFGSC stack_bytes=%d chunk=%d alarm_below=%d\n",
           CONFIG_EX15_SC4_STACK_BYTES, CONFIG_EX15_SC4_CHUNK,
           CONFIG_EX15_SC4_ALARM_HWM);
#endif

    /* [1] esp_netif_init() 必须是第一句网络相关调用（创建 tcpip 邮箱） */
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    s_got_ip = xSemaphoreCreateBinary();

    /* [2] 以太网默认 esp_netif 实例 */
    esp_netif_config_t netif_cfg = ESP_NETIF_DEFAULT_ETH();
    esp_netif_t *eth_netif = esp_netif_new(&netif_cfg);

    /* [3] MAC + PHY 组装（openeth 仅 QEMU） */
    eth_mac_config_t mac_cfg = ETH_MAC_DEFAULT_CONFIG(); /* rx 任务 4096B prio15 */
    eth_phy_config_t phy_cfg = ETH_PHY_DEFAULT_CONFIG();
    phy_cfg.reset_gpio_num      = -1;
    phy_cfg.autonego_timeout_ms = 3000;

    esp_eth_mac_t *mac = esp_eth_mac_new_openeth(&mac_cfg);
    assert(mac != NULL);
    esp_eth_phy_t *phy = esp_eth_phy_new_generic(&phy_cfg);
    assert(phy != NULL);

    esp_eth_config_t eth_cfg = ETH_DEFAULT_CONFIG(mac, phy);
    esp_eth_handle_t eth_handle = NULL;
    ESP_ERROR_CHECK(esp_eth_driver_install(&eth_cfg, &eth_handle));

    /* [4] 事件 + glue + 启动 → DHCP → GOT_IP */
    ESP_ERROR_CHECK(esp_event_handler_register(ETH_EVENT, ESP_EVENT_ANY_ID,
                                               &eth_event_handler, NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_ETH_GOT_IP,
                                               &ip_event_handler, NULL));
    esp_eth_netif_glue_handle_t glue = esp_eth_new_netif_glue(eth_handle);
    ESP_ERROR_CHECK(esp_netif_attach(eth_netif, glue));
    ESP_ERROR_CHECK(esp_eth_start(eth_handle));
    ESP_LOGI(TAG, "waiting for DHCP lease ...");

    if (xSemaphoreTake(s_got_ip, pdMS_TO_TICKS(DHCP_TIMEOUT_MS)) != pdTRUE) {
        ESP_LOGE(TAG, "$$$ EXFAIL reason=dhcp_timeout after %d ms", DHCP_TIMEOUT_MS);
        return;
    }
    esp_netif_ip_info_t info;
    ESP_ERROR_CHECK(esp_netif_get_ip_info(eth_netif, &info));
    s_own_ip = info.ip.addr;

    /* [5] READY 行：验收器 grep 这一行断言起播成功 */
    s_ready_ms = now_ms();
    printf("$$$ EXREADY sc=%d(%s) ip=" IPSTR " gw=" IPSTR " t_ms=%lld\n",
           CONFIG_GYM_SCENARIO, SC_NAME, IP2STR(&info.ip), IP2STR(&info.gw),
           (long long)s_ready_ms);

    /* [6] 共享基础设施初始化 */
    s_diag_lock = xSemaphoreCreateMutex();
    s_hb.last_ms = now_ms();
    memset(&s_nm, 0, sizeof(s_nm));

#if LWIP_STATS
    s_snap.sem = xSemaphoreCreateBinary();
#endif

    /* [7] 双层心跳源上线（受害者本体保持健康） */
    /* 低优先级=标准受害样本；sc3 变体会经 Kconfig 提到 19 压过 tcpip(18) */
    xTaskCreate(hb_task, "ex15_hb", 2560, NULL, CONFIG_EX15_HB_PRIO, NULL);
    start_net_heartbeat(&info.gw);

    /* [8] 编排器 + 独立告警看门狗：都 pin core1、prio>=21 —— 活在受害者带宽
     * 之外（Batch 4/7 双核测量陷阱：测量与控制必须压过 tcpip(18) 与 spinner） */
    xTaskCreatePinnedToCore(gym_orchestrator, "ex15_gym", 4096, NULL, GYM_OBS_PRIO,
                            NULL, GYM_OBS_CORE);
    xTaskCreatePinnedToCore(gym_watchdog, "ex15_watch", 2560, NULL,
                            GYM_OBS_PRIO - 1, NULL, GYM_OBS_CORE);

    /* [9] app_main 收工；观察窗结束由 orchestrator 自删，进程交 runner timeout */
    while (1) {
        vTaskDelay(pdMS_TO_TICKS(60000));
    }
}
