/* pacing.c —— ch07 整流（pacing）实验 harness
 *
 * UDP 发送端两种模式 + 接收端到达节奏统计，单进程内完成（收发线程经回环对接）：
 *   burst：连续尽快发 count 个 payload 字节的 UDP 包（默认 2000 x 1316B）；
 *   paced ：令牌桶限速发送，默认 500 pps（--pps 可调，--depth 桶深可调）。
 * 接收线程绑本机端口（默认 0.0.0.0:13201，收 127.0.0.1 的包），对每个到达包打
 * 单调时钟时间戳，统计到达间隔 gap 的 min/avg/p99/max、标准差 sigma、RFC3550
 * 抖动 J 与 gap 直方图，最后打印两种模式的对比表。
 *
 * 回环上验证的是「整流工具链 + gap 统计」本身：burst 的 gap 在微秒级聚簇
 * （突发形态证据），paced 的 gap 被令牌桶钉在 1/pps 附近。真机 WiFi 上把
 * --ip 指到接收端，同一命令即得空口节奏画像。
 *
 * 编译：zig cc -O2 -o pacing pacing.c -lws2_32    （POSIX 去掉 -lws2_32）
 */
#include "net_compat.h"

#include <inttypes.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#ifndef CREATE_WAITABLE_TIMER_HIGH_RESOLUTION /* Win10 1803+，旧头文件兜底 */
#define CREATE_WAITABLE_TIMER_HIGH_RESOLUTION 0x00000002
#endif
#ifndef TIMER_ALL_ACCESS
#define TIMER_ALL_ACCESS 0x1F0003
#endif
#else
#include <sched.h>
#include <time.h>
#endif

#define MAGIC 0x50414343u /* "PACC" */

/* 包头：发送侧随载荷携带 seq 与发送时刻，接收端据此算 RFC3550 抖动 */
struct pkt_hdr {
    uint32_t magic;
    uint32_t mode; /* 0=burst 1=paced */
    uint32_t seq;
    uint32_t count;
    uint64_t ts_ns; /* 发送侧单调时间戳 */
};

/* ---- 全局共享状态：接收线程写，主线程在静默期读 ----
 * 每包写入完成后才原子递增 g_rx[m]（seq_cst），主线程读到计数即可安全看到
 * 对应数组槽位——免锁的单写多读快照协议。 */
static _Atomic int g_ready, g_stop;
static _Atomic long long g_rx[2], g_malformed;
static uint64_t *g_arr[2];  /* 到达时间戳（按 seq 存放） */
static uint64_t *g_snd[2];  /* 发送时间戳（取自包内） */
static uint8_t *g_got[2];   /* 该 seq 是否收到 */
static uint64_t *g_txts[2]; /* 发送侧 sendto 前记录的时间戳 */
static int g_count, g_plen;
static SOCKET g_rx_sock;
static char g_rxbuf[65536];

/* ---------- 单调时钟 ---------- */
static uint64_t g_qpc_freq;

static void mono_init(void)
{
#ifdef _WIN32
    LARGE_INTEGER f;
    QueryPerformanceFrequency(&f);
    g_qpc_freq = (uint64_t)f.QuadPart;
#endif
}

static uint64_t now_ns(void)
{
#ifdef _WIN32
    LARGE_INTEGER c;
    QueryPerformanceCounter(&c);
    uint64_t s = (uint64_t)c.QuadPart; /* 先除后乘，避免 64 位溢出 */
    return s / g_qpc_freq * 1000000000ULL + (s % g_qpc_freq) * 1000000000ULL / g_qpc_freq;
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
#endif
}

static const char *clock_name(void)
{
#ifdef _WIN32
    return "QueryPerformanceCounter(单调)";
#else
    return "clock_gettime(CLOCK_MONOTONIC)";
#endif
}

/* ---------- 休眠基础设施：粗睡（定时器）+ 自旋收尾 ----------
 * 令牌桶要 2ms 级精度：Windows 默认 Sleep 粒度 ~15.6ms 不够用。
 * 优先 Win10 1803+ 的高精度可等待定时器（kernel32，无需额外链接库）；
 * 不可用则实测 Sleep(1) 粒度决定是否可粗睡；再不行纯自旋兜底。 */
#ifdef _WIN32
static HANDLE g_timer;
static int g_sleep_mode; /* 1=高精度定时器 2=Sleep(1) 实测可用 0=纯自旋 */

static void sleep_init(void)
{
    g_timer = CreateWaitableTimerExW(NULL, NULL, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION,
                                     TIMER_ALL_ACCESS);
    if (g_timer) {
        g_sleep_mode = 1;
        return;
    }
    uint64_t t0 = now_ns();
    Sleep(1);
    g_sleep_mode = (now_ns() - t0 < 2500000ULL) ? 2 : 0; /* 实测 >2.5ms 视为不可靠 */
}

static const char *sleep_mode_name(void)
{
    return g_sleep_mode == 1 ? "高精度可等待定时器(HIGH_RESOLUTION)+自旋收尾"
         : g_sleep_mode == 2 ? "Sleep(1ms 实测可用)+自旋收尾"
                             : "纯自旋(粗睡粒度不可靠)";
}

static void coarse_sleep_us(uint64_t us)
{
    if (g_sleep_mode == 1) {
        LARGE_INTEGER due; /* 负值=相对到期，单位 100ns：1us = 10 */
        due.QuadPart = -(LONGLONG)(us * 10);
        if (SetWaitableTimer(g_timer, &due, 0, NULL, NULL, FALSE))
            WaitForSingleObject(g_timer, INFINITE);
    } else if (g_sleep_mode == 2) {
        Sleep((DWORD)(us / 1000));
    }
}

#else /* POSIX */

static void sleep_init(void) {}
static const char *sleep_mode_name(void) { return "clock_nanosleep(CLOCK_MONOTONIC)+自旋收尾"; }

static void coarse_sleep_us(uint64_t us)
{
    struct timespec ts = { (time_t)(us / 1000000), (long)((us % 1000000) * 1000) };
    clock_nanosleep(CLOCK_MONOTONIC, 0, &ts, NULL);
}
#endif

/* 睡到 deadline：离目标 >800us 用定时器粗睡（留 600us 余量吸收定时器误差），
 * 末段 600us 纯自旋——不用 yield：SwitchToThread/sched_yield 可能让出整个
 * 调度节拍（实测产生 5~8ms 的尾部毛刺），宁可烧一点 CPU 换节奏精度。 */
static void sleep_until_ns(uint64_t deadline)
{
    for (;;) {
        uint64_t now = now_ns();
        if (now >= deadline)
            return;
        uint64_t rem = deadline - now;
        if (rem > 800000ULL)
            coarse_sleep_us((rem - 600000ULL) / 1000ULL); /* ns -> us */
        /* 其余：自旋等 QueryPerformanceCounter 走完，精度取决于时钟本身 */
    }
}

/* ---------- 免 libm 的小工具（编译命令不带 -lm，保持零依赖） ---------- */
static double dabs_(double x) { return x < 0 ? -x : x; }

static double dsqrt_(double v) /* 牛顿迭代，正数全域收敛 */
{
    if (v <= 0)
        return 0;
    double x = v > 1 ? v : 1;
    for (int i = 0; i < 80; i++) {
        double nx = 0.5 * (x + v / x);
        if (nx >= x)
            break; /* 收敛后单调递减到不动点，开始回升即停 */
        x = nx;
    }
    return x;
}

static int cmp_u64(const void *a, const void *b)
{
    uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
    return x < y ? -1 : x > y ? 1 : 0;
}

static int cmp_d(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y ? 1 : 0;
}

/* ---------- 输出格式化 ---------- */
static const char *fus(double ns) /* 纳秒 -> 微秒字符串，自适应精度 */
{
    static char b[8][32];
    static int i = 0;
    i = (i + 1) & 7;
    double us = ns / 1000.0;
    if (us < 10)
        snprintf(b[i], 32, "%.2f", us);
    else if (us < 1000)
        snprintf(b[i], 32, "%.1f", us);
    else if (us < 10000000.0)
        snprintf(b[i], 32, "%.0f", us);
    else
        snprintf(b[i], 32, "%.3g", us);
    return b[i];
}

static const char *fpps(double v) /* pps 字符串 */
{
    static char b[4][32];
    static int i = 0;
    i = (i + 1) & 3;
    if (v >= 10000)
        snprintf(b[i], 32, "%.0f", v);
    else if (v >= 100)
        snprintf(b[i], 32, "%.1f", v);
    else
        snprintf(b[i], 32, "%.2f", v);
    return b[i];
}

/* ---------- gap 直方图（对数梯子 + 目标间隔附近加密分箱） ---------- */
#define HIST_MAX 40
struct hist {
    int nb;                        /* 边数（桶数 = nb+1） */
    double edges_us[HIST_MAX];     /* 升序上边界 */
    long cnt[HIST_MAX + 1];
};

static void hist_build(struct hist *h, double target_us)
{
    int n = 0;
    const double mults[3] = { 1, 2, 5 };
    for (int k = 0; k <= 4; k++)
        for (int j = 0; j < 3; j++) {
            double e = mults[j];
            for (int t = 0; t < k; t++)
                e *= 10;
            if (e < 20000 && n < HIST_MAX)
                h->edges_us[n++] = e; /* 1,2,5,...,10000us */
        }
    if (target_us > 20 && target_us < 20000) { /* 目标 ±10% 加密 */
        const double f[5] = { 0.90, 0.95, 1.00, 1.05, 1.10 };
        for (int i = 0; i < 5 && n < HIST_MAX; i++)
            h->edges_us[n++] = target_us * f[i];
    }
    qsort(h->edges_us, (size_t)n, sizeof(double), cmp_d);
    int m = 0; /* 去重 */
    for (int i = 0; i < n; i++)
        if (m == 0 || h->edges_us[i] > h->edges_us[m - 1] + 1e-9)
            h->edges_us[m++] = h->edges_us[i];
    h->nb = m;
    memset(h->cnt, 0, sizeof h->cnt);
}

static void hist_add_ns(struct hist *h, double gap_ns)
{
    double us = gap_ns / 1000.0;
    int b = h->nb; /* 末桶 = >= 最大边 */
    for (int i = 0; i < h->nb; i++)
        if (us < h->edges_us[i]) {
            b = i;
            break;
        }
    h->cnt[b]++;
}

static void hist_print(const struct hist *h, long ntotal)
{
    char lab[32];
    for (int b = 0; b <= h->nb; b++) {
        if (!h->cnt[b])
            continue; /* 空桶不打印，行数可控 */
        if (b == 0)
            snprintf(lab, sizeof lab, "<%g", h->edges_us[0]);
        else if (b == h->nb)
            snprintf(lab, sizeof lab, ">=%g", h->edges_us[h->nb - 1]);
        else
            snprintf(lab, sizeof lab, "%g-%g", h->edges_us[b - 1], h->edges_us[b]);
        double pct = ntotal ? 100.0 * h->cnt[b] / ntotal : 0;
        int bar = (int)(pct / 2.0 + 0.5); /* 每个 '#' 约 2% */
        if (bar > 50)
            bar = 50;
        printf("      %-12s %6ld %6.1f%% %.*s\n", lab, h->cnt[b], pct, bar,
               "##################################################");
    }
}

/* ---------- gap 统计 ---------- */
struct gap_stats {
    long n;                 /* gap 个数（= 包数-1） */
    double min, avg, p99, max, sigma; /* 全为 ns */
    double lt100;           /* gap < 100us 的占比 % */
};

static void gap_stats(const uint64_t *ts /* 升序 */, long n, struct gap_stats *g, struct hist *h)
{
    memset(g, 0, sizeof *g);
    g->n = n > 0 ? n - 1 : 0;
    if (g->n < 1)
        return;
    double *gap = malloc(sizeof(double) * (size_t)g->n);
    if (!gap)
        return;
    double sum = 0, mn = 1e30, mx = 0;
    long lt = 0;
    for (long i = 0; i < g->n; i++) {
        double d = (double)(ts[i + 1] - ts[i]);
        gap[i] = d;
        sum += d;
        if (d < mn)
            mn = d;
        if (d > mx)
            mx = d;
        if (d < 100000.0)
            lt++;
        if (h)
            hist_add_ns(h, d);
    }
    g->min = mn;
    g->max = mx;
    g->avg = sum / (double)g->n;
    g->lt100 = 100.0 * (double)lt / (double)g->n;
    qsort(gap, (size_t)g->n, sizeof(double), cmp_d);
    long k = (99 * g->n + 99) / 100; /* 最近邻法 p99：ceil(0.99n) */
    if (k < 1)
        k = 1;
    if (k > g->n)
        k = g->n;
    g->p99 = gap[k - 1];
    double var = 0;
    for (long i = 0; i < g->n; i++) {
        double d = gap[i] - g->avg;
        var += d * d;
    }
    g->sigma = dsqrt_(var / (double)g->n);
    free(gap);
}

/* RFC3550 A.8 到达间抖动：J += (|D(i-1,i)| - J)/16，D=到达差-发送差 */
static double jitter3550(int m)
{
    double J = 0;
    long pairs = 0;
    for (long i = 1; i < g_count; i++) {
        if (!g_got[m][i] || !g_got[m][i - 1])
            continue;
        double D = (double)((int64_t)(g_arr[m][i] - g_arr[m][i - 1]) -
                            (int64_t)(g_snd[m][i] - g_snd[m][i - 1]));
        J += (dabs_(D) - J) / 16.0;
        pairs++;
    }
    return pairs ? J : -1.0;
}

/* ---------- 接收线程 ---------- */
static void rx_thread(void *unused)
{
    (void)unused;
    set_rcvtimeo(g_rx_sock, 100); /* 100ms 超时醒来查 stop 旗标 */
    atomic_store(&g_ready, 1);
    for (;;) {
        int n = recvfrom(g_rx_sock, g_rxbuf, sizeof g_rxbuf, 0, NULL, NULL);
        if (n < 0) {
            if (atomic_load(&g_stop))
                break;
            continue;
        }
        uint64_t t = now_ns(); /* 收到即打点（用户态 recvfrom 返回时刻） */
        if ((uint32_t)n < sizeof(struct pkt_hdr)) {
            atomic_fetch_add(&g_malformed, 1);
            continue;
        }
        struct pkt_hdr h;
        memcpy(&h, g_rxbuf, sizeof h);
        if (h.magic != MAGIC || h.mode > 1 || h.seq >= (uint32_t)g_count ||
            h.count != (uint32_t)g_count) {
            atomic_fetch_add(&g_malformed, 1);
            continue;
        }
        int m = (int)h.mode;
        g_arr[m][h.seq] = t;
        g_snd[m][h.seq] = h.ts_ns;
        g_got[m][h.seq] = 1;
        atomic_fetch_add(&g_rx[m], 1); /* 发布上面的写入 */
    }
}

/* ---------- 发送（两种模式共用主干） ---------- */
static long long send_mode(int mode, double pps, double depth, const struct sockaddr_in *dst)
{
    SOCKET tx = socket(AF_INET, SOCK_DGRAM, 0);
    if (tx == INVALID_SOCKET) {
        fprintf(stderr, "发送 socket 创建失败\n");
        exit(1);
    }
    char *buf = malloc((size_t)g_plen);
    if (!buf) {
        fprintf(stderr, "内存不足\n");
        exit(1);
    }
    memset(buf, 0xA5, (size_t)g_plen);
    double tokens = 1.0; /* 首包立即可发，之后按速率补充 */
    uint64_t t_last = now_ns();
    long long err = 0;
    for (uint32_t i = 0; i < (uint32_t)g_count; i++) {
        if (mode == 1) { /* 令牌桶：攒够 1 个令牌才准发 */
            for (;;) {
                uint64_t now = now_ns();
                tokens += (double)(now - t_last) * pps / 1e9;
                if (tokens > depth)
                    tokens = depth; /* 桶深封顶：不攒突发信用 */
                t_last = now;
                if (tokens >= 1.0)
                    break;
                double need = 1.0 - tokens;
                uint64_t deadline = now + (uint64_t)(need / pps * 1e9 + 0.5);
                sleep_until_ns(deadline);
            }
            tokens -= 1.0;
        }
        struct pkt_hdr h = { MAGIC, (uint32_t)mode, i, (uint32_t)g_count, now_ns() };
        memcpy(buf, &h, sizeof h);
        g_txts[mode][i] = h.ts_ns;
        if (sendto(tx, buf, (int)g_plen, 0, (const struct sockaddr *)dst, sizeof *dst) < 0)
            err++;
    }
    free(buf);
    CLOSE_SOCK(tx);
    return err;
}

/* 收集某模式全部到达时间戳并升序排序；返回收到包数 */
static long collect(int m, uint64_t *out)
{
    long n = 0;
    for (long i = 0; i < g_count; i++)
        if (g_got[m][i])
            out[n++] = g_arr[m][i];
    qsort(out, (size_t)n, sizeof(uint64_t), cmp_u64);
    return n;
}

static void report_mode(int m, const char *name, double target_us, double pps, double depth,
                        long long send_err, int sent, struct gap_stats *out, double *out_pps,
                        long *out_nrx)
{
    uint64_t *ts = malloc(sizeof(uint64_t) * (size_t)(g_count + 1));
    if (!ts)
        exit(1);
    long nrx = collect(m, ts);
    struct gap_stats rs;
    struct hist h;
    hist_build(&h, target_us);
    gap_stats(ts, nrx, &rs, &h);

    printf("\n---- 模式 %s ----\n", name);
    if (sent && m == 1)
        printf("[TX] 令牌桶: rate=%g pps, 桶深=%g 包, 目标间隔 %.0f us\n", pps, depth, target_us);

    if (sent) { /* 发送侧节奏（sendto 前打点） */
        struct gap_stats txs;
        gap_stats(g_txts[m], g_count, &txs, NULL);
        double tx_span_us = (double)(g_txts[m][g_count - 1] - g_txts[m][0]) / 1000.0;
        double tx_pps = tx_span_us > 0 ? (g_count - 1) * 1e6 / tx_span_us : 0;
        printf("[TX] %d 包 / %s us / 平均 %s pps / sendto 失败 %lld\n", g_count,
               fus(tx_span_us * 1000.0), fpps(tx_pps), send_err);
        printf("[TX] 发送 gap(us): min %s | avg %s | p99 %s | max %s\n", fus(txs.min), fus(txs.avg),
               fus(txs.p99), fus(txs.max));
    }

    /* 接收侧节奏 */
    double loss_pct = (double)(g_count - nrx) * 100.0 / (double)g_count;
    double rx_pps = 0, mbps = 0;
    if (nrx > 1) {
        double span_s = (double)(ts[nrx - 1] - ts[0]) / 1e9;
        rx_pps = (nrx - 1) / span_s;
        mbps = (double)nrx * g_plen * 8.0 / span_s / 1e6;
    }
    printf("[RX] 收到 %ld/%d 包(丢失 %.1f%%), 到达 %s pps, 载荷吞吐 %.1f Mbps, 畸形包 %lld\n", nrx,
           g_count, loss_pct, fpps(rx_pps), mbps, atomic_load(&g_malformed));
    if (rs.n >= 1) {
        double J = jitter3550(m);
        printf("[RX] 到达 gap(us): min %s | avg %s | p99 %s | max %s | sigma %s | <100us 占比 %.1f%%\n",
               fus(rs.min), fus(rs.avg), fus(rs.p99), fus(rs.max), fus(rs.sigma), rs.lt100);
        printf("[RX] RFC3550 到达间抖动 J = %s us\n", J >= 0 ? fus(J) : "n/a");
        printf("[RX] 到达 gap 直方图(us 桶, '#'=2%%):\n");
        hist_print(&h, rs.n);
    } else {
        printf("[RX] 样本不足，无 gap 统计\n");
    }
    *out = rs;
    *out_pps = rx_pps;
    *out_nrx = nrx;
    free(ts);
}

static void usage(void)
{
    printf("用法: pacing [--count N] [--pps F] [--depth N] [--port N] [--dport N] "
           "[--ip A] [--payload N] [--rx-only 秒]\n"
           "默认: count=2000 pps=500 depth=1 port=13201 dport=同port ip=127.0.0.1 payload=1316\n"
           "burst 与 paced 各跑一遍，打印接收端到达 gap 对比表\n"
           "--rx-only: 只收不发（当对端节奏画像的接收器；静默 2s 或到时收工）\n");
}

int main(int argc, char **argv)
{
    long count = 2000;
    double pps = 500.0, depth = 1.0;
    int port = 13201, dport = -1, plen = 1316, rx_only = 0;
    const char *ip = "127.0.0.1";

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--count") && i + 1 < argc)
            count = atol(argv[++i]);
        else if (!strcmp(argv[i], "--pps") && i + 1 < argc)
            pps = atof(argv[++i]);
        else if (!strcmp(argv[i], "--depth") && i + 1 < argc)
            depth = atof(argv[++i]);
        else if (!strcmp(argv[i], "--port") && i + 1 < argc)
            port = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--dport") && i + 1 < argc)
            dport = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--ip") && i + 1 < argc)
            ip = argv[++i];
        else if (!strcmp(argv[i], "--rx-only") && i + 1 < argc)
            rx_only = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--payload") && i + 1 < argc)
            plen = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) {
            usage();
            return 0;
        } else {
            fprintf(stderr, "未知参数: %s\n", argv[i]);
            usage();
            return 1;
        }
    }
    if (count < 2)
        count = 2;
    if (count > 500000)
        count = 500000;
    if (pps < 1.0)
        pps = 1.0;
    if (pps > 200000.0)
        pps = 200000.0;
    if (depth < 1.0)
        depth = 1.0;
    if (depth > 1000.0)
        depth = 1000.0;
    if (plen < 32)
        plen = 32;
    if (plen > 65507)
        plen = 65507;
    if (dport < 1 || dport > 65535)
        dport = port; /* 发送目的端口默认同本地端口 */
    if (rx_only < 0)
        rx_only = 0;
    if (rx_only > 3600)
        rx_only = 3600;
    g_count = (int)count;
    g_plen = plen;

    mono_init();
    net_init();
    sleep_init();
    printf("pacing harness —— UDP 发送节奏整形 + 到达 gap 统计 (ch07-pacing-harness)\n");
    printf("参数: 目的 %s:%d | %d 包 x %dB | paced: %g pps (令牌桶深 %g 包)%s\n", ip, dport, g_count,
           g_plen, pps, depth, rx_only ? " | 模式=只收不发(rx-only)" : "");
    printf("计时: %s | 粗睡路径: %s\n", clock_name(), sleep_mode_name());

    /* 接收端：bind 全接口（回环可达；真机上外部设备也可发进来） */
    g_rx_sock = socket(AF_INET, SOCK_DGRAM, 0);
    struct sockaddr_in ba;
    memset(&ba, 0, sizeof ba);
    ba.sin_family = AF_INET;
    ba.sin_port = htons((unsigned short)port);
    ba.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(g_rx_sock, (const struct sockaddr *)&ba, sizeof ba) != 0) {
        fprintf(stderr, "bind :%d 失败\n", port);
        return 1;
    }
    int rcvbuf = 8 * 1024 * 1024, gotbuf = 0;
    setsockopt(g_rx_sock, SOL_SOCKET, SO_RCVBUF, (const char *)&rcvbuf, sizeof rcvbuf);
    socklen_t bl = sizeof gotbuf;
    getsockopt(g_rx_sock, SOL_SOCKET, SO_RCVBUF, (char *)&gotbuf, &bl);
    printf("SO_RCVBUF: 请求 %d B -> 实得 %d B (burst %d 包 x %dB 约需 %ld KB)\n", rcvbuf, gotbuf,
           g_count, g_plen, (long)((double)g_count * (g_plen + 64) / 1024.0));

    for (int m = 0; m < 2; m++) {
        g_arr[m] = calloc((size_t)g_count, 8);
        g_snd[m] = calloc((size_t)g_count, 8);
        g_got[m] = calloc((size_t)g_count, 1);
        g_txts[m] = calloc((size_t)g_count, 8);
    }
    if (thread_start(rx_thread, NULL) != 0) {
        fprintf(stderr, "接收线程创建失败\n");
        return 1;
    }
    while (!atomic_load(&g_ready))
        coarse_sleep_us(500);

    struct sockaddr_in dst;
    memset(&dst, 0, sizeof dst);
    dst.sin_family = AF_INET;
    dst.sin_port = htons((unsigned short)dport);
    if (inet_pton(AF_INET, ip, &dst.sin_addr) != 1) {
        fprintf(stderr, "非法目的地址: %s\n", ip);
        return 1;
    }

    struct gap_stats saved[2];
    double saved_pps[2];
    long saved_nrx[2];
    int have[2] = { 0, 0 };
    double target_us = 1e6 / pps;

    if (rx_only) {
        /* 只收不发：给对端当节奏画像接收器（真机上跑在 PC 侧）。
         * 收工条件：到时，或已收到包且静默 3s（须大于对端两模式间的排空间隔）。 */
        printf("[rx-only] 最长 %d s, 静默 3s 提前收工, 期望每模式 %d 包 (对端 --count 须一致)\n",
               rx_only, g_count);
        uint64_t t_end = now_ns() + (uint64_t)rx_only * 1000000000ULL;
        long long last_total = -1, last_printed = 0;
        uint64_t last_prog = now_ns();
        for (;;) {
            coarse_sleep_us(100000);
            long long tot = atomic_load(&g_rx[0]) + atomic_load(&g_rx[1]);
            uint64_t now = now_ns();
            if (tot != last_total) {
                if (tot / 100 > last_printed / 100) { /* 每 100 包报一次进度 */
                    printf("[rx-only] 已收 %lld 包\n", tot);
                    last_printed = tot;
                }
                last_total = tot;
                last_prog = now;
            }
            if (now >= t_end)
                break;
            if (last_total > 0 && now - last_prog > 3000000000ULL)
                break;
        }
        printf("[rx-only] 收工, 共收 %lld 包 (burst %lld + paced %lld)\n", last_total,
               atomic_load(&g_rx[0]), atomic_load(&g_rx[1]));
        atomic_store(&g_stop, 1);
        coarse_sleep_us(200000);
        for (int m = 0; m < 2; m++) {
            if (atomic_load(&g_rx[m]) == 0)
                continue;
            have[m] = 1;
            char nm[48];
            snprintf(nm, sizeof nm, "%s(对端发来)", m == 0 ? "burst" : "paced");
            report_mode(m, nm, 0.0, pps, depth, 0, 0, &saved[m], &saved_pps[m], &saved_nrx[m]);
        }
        printf("\n==== 对比表: burst vs paced (接收端到达 gap, 单位 us; 收 %d 包 x %dB) ====\n",
               g_count, g_plen);
        printf("%-6s %12s %10s %8s %8s %8s %10s %8s %8s %7s\n", "mode", "rx/loss", "rx_pps", "min",
               "avg", "p99", "max", "sigma", "J3550", "<100us");
        for (int m = 0; m < 2; m++) {
            if (!have[m])
                continue;
            double loss_pct = (double)(g_count - saved_nrx[m]) * 100.0 / (double)g_count;
            double J = jitter3550(m);
            char losslab[32];
            snprintf(losslab, sizeof losslab, "%ld/%.1f%%", saved_nrx[m], loss_pct);
            printf("%-6s %12s %10s %8s %8s %8s %10s %8s %8s %6.1f%%\n",
                   m == 0 ? "burst" : "paced", losslab, fpps(saved_pps[m]), fus(saved[m].min),
                   fus(saved[m].avg), fus(saved[m].p99), fus(saved[m].max), fus(saved[m].sigma),
                   J >= 0 ? fus(J) : "n/a", saved[m].lt100);
        }
        if (have[0] && saved[0].n >= 1)
            printf("[结论] burst: %.1f%% 的到达 gap < 100us —— 微秒级聚簇, 即突发形态的证据\n",
                   saved[0].lt100);
        if (have[1] && saved[1].n >= 1)
            printf("       paced: 平均 gap %s us (对端令牌桶目标未知, 由其 --pps 决定)\n",
                   fus(saved[1].avg));
        for (int m = 0; m < 2; m++) {
            free(g_arr[m]);
            free(g_snd[m]);
            free(g_got[m]);
            free(g_txts[m]);
        }
        CLOSE_SOCK(g_rx_sock);
        net_cleanup();
        return 0;
    }

    for (int m = 0; m < 2; m++) {
        const char *name = m == 0 ? "burst(连续尽快发)" : "paced(令牌桶限速)";
        long long err = send_mode(m, pps, depth, &dst);
        /* 排空等待：收齐或 1s 超时（回环包 µs 级到达；间隔须小于对端 rx-only
         * 的静默阈值），再静默沉淀 200ms 保证写读不交叠 */
        uint64_t deadline = now_ns() + 1000000000ULL;
        while (atomic_load(&g_rx[m]) < g_count && now_ns() < deadline)
            coarse_sleep_us(5000);
        coarse_sleep_us(200000);
        report_mode(m, name, target_us, pps, depth, err, 1, &saved[m], &saved_pps[m], &saved_nrx[m]);
        if (m == 0)
            coarse_sleep_us(300000); /* 两模式间隔 */
    }
    atomic_store(&g_stop, 1);
    coarse_sleep_us(200000);

    printf("\n==== 对比表: burst vs paced (接收端到达 gap, 单位 us; %d 包 x %dB -> %s:%d) ====\n",
           g_count, g_plen, ip, dport);
    printf("%-6s %12s %10s %8s %8s %8s %10s %8s %8s %7s\n", "mode", "rx/loss", "rx_pps", "min",
           "avg", "p99", "max", "sigma", "J3550", "<100us");
    for (int m = 0; m < 2; m++) {
        double loss_pct = (double)(g_count - saved_nrx[m]) * 100.0 / (double)g_count;
        double J = jitter3550(m);
        char losslab[32];
        snprintf(losslab, sizeof losslab, "%ld/%.1f%%", saved_nrx[m], loss_pct);
        printf("%-6s %12s %10s %8s %8s %8s %10s %8s %8s %6.1f%%\n", m == 0 ? "burst" : "paced",
               losslab, fpps(saved_pps[m]), fus(saved[m].min), fus(saved[m].avg),
               fus(saved[m].p99), fus(saved[m].max), fus(saved[m].sigma), J >= 0 ? fus(J) : "n/a",
               saved[m].lt100);
    }
    if (saved[0].n >= 1)
        printf("[结论] burst: %.1f%% 的到达 gap < 100us —— 微秒级聚簇, 即突发形态在回环上的证据\n",
               saved[0].lt100);
    if (saved[1].n >= 1) {
        double dev = (saved[1].avg / 1000.0 - target_us) / target_us * 100.0;
        if (dev > -15.0 && dev < 15.0)
            printf("       paced: 平均 gap %s us vs 目标 %.0f us (偏差 %+.2f%%), p99 %s us, max %s us —— 令牌桶把节奏钉在目标附近\n",
                   fus(saved[1].avg), target_us, dev, fus(saved[1].p99), fus(saved[1].max));
        else
            printf("       paced: 平均 gap %s us vs 目标 %.0f us (偏差 %+.2f%%), p99 %s us, max %s us —— 本轮宿主负载干扰大, 尾部毛刺把均值拉偏; 用户态整流的常态限制, 见 README\n",
                   fus(saved[1].avg), target_us, dev, fus(saved[1].p99), fus(saved[1].max));
    }

    for (int m = 0; m < 2; m++) {
        free(g_arr[m]);
        free(g_snd[m]);
        free(g_got[m]);
        free(g_txts[m]);
    }
    CLOSE_SOCK(g_rx_sock);
    net_cleanup();
    return 0;
}
