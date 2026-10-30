/*
 * airtime_probe.c —— WiFi airtime 探针：解析 iw 文本输出，回答"信道时间被谁用掉了"
 *
 * 输入是两条命令的文本输出（真机由 collect.sh 采集，样例见 fixtures/）：
 *   iw dev wlan0 survey dump    —— 信道时间账本（active/busy/rx/tx/extbusy）
 *   iw dev wlan0 station dump   —— 每站点收发账本（signal/tx packets/retries/failed）
 *
 * 单位公约：内核 nl80211 的 survey 时间字段语义为 µs，iw 打印时已除以 1000 显示 ms。
 * 本解析器识别行尾单位并统一归一到 µs 后再算比例（比例与单位无关，绝对值必须归一）。
 *
 * 用法：
 *   ./airtime_probe                              自检：解析 fixtures/ 样例，
 *                                               与源码内编码的期望值逐项比对
 *   ./airtime_probe <survey.txt> [station.txt]   解析指定 iw 输出文件并打印报告
 *
 * 判定阈值（与 README/章节约定一致）：
 *   busy%  = busy/active       > 70% → 「饱和预警」
 *   重传率 = tx_retries/tx_packets > 30% → 「重传偏高」
 *
 * 编译：~/zig/zig cc -O2 -o airtime_probe airtime_probe.c
 * C11，零第三方依赖。
 */

#include <ctype.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_SURVEY_BLOCKS 16
#define MAX_STATIONS 32
#define LINE_BUF 2048

#define BUSY_SATURATION_PCT 70.0 /* busy/active 超过此值打「饱和预警」 */
#define RETRY_HIGH_PCT 30.0      /* tx_retries/tx_packets 超过此值打「重传偏高」 */

/* ---------------- 数据模型 ---------------- */

typedef struct {
    bool have_freq, in_use_seen, have_noise;
    bool have_active, have_busy, have_extbusy, have_rx, have_tx;
    double freq_mhz;
    int in_use; /* 1=在用（iw 只对当前信道打印 "in use: yes"） */
    int noise_dbm;
    uint64_t active_us, busy_us, extbusy_us, rx_us, tx_us;
} survey_block_t;

typedef struct {
    int n;
    char iface[32];
    survey_block_t b[MAX_SURVEY_BLOCKS];
} survey_dump_t;

typedef struct {
    bool valid;
    double freq_mhz;
    int in_use, noise_dbm;
    uint64_t active_us, busy_us, extbusy_us, rx_us, tx_us;
    double busy_pct, rx_pct, tx_pct, other_pct; /* 均相对 active */
    bool saturated;
} survey_stat_t;

typedef struct {
    char mac[32];
    bool have_signal, have_rx_bytes, have_rx_packets;
    bool have_tx_bytes, have_tx_packets, have_tx_retries, have_tx_failed, have_tx_bitrate;
    int signal_dbm;
    uint64_t rx_bytes, rx_packets, tx_bytes, tx_packets, tx_retries, tx_failed;
    double tx_bitrate_mbps;
} station_t;

typedef struct {
    int n;
    char iface[32];
    station_t s[MAX_STATIONS];
} station_dump_t;

typedef struct {
    bool valid; /* tx_packets>0 才可算 */
    double retry_pct;
    bool high_retry;
} station_stat_t;

/* ---------------- 通用小工具 ---------------- */

static char *skip_ws(char *s)
{
    while (*s && isspace((unsigned char)*s))
        s++;
    return s;
}

static void rstrip(char *s)
{
    size_t n = strlen(s);
    while (n && (isspace((unsigned char)s[n - 1]) || s[n - 1] == '\r'))
        s[--n] = '\0';
}

/* 把一行拆成「标签: 值」。标签去掉首尾空白，值为跳过空白后的余下内容。
 * 注意 MAC 地址行（Station aa:bb:.. (on wlan0)）不能走这里——调用方先处理前缀。 */
static bool split_label(char *line, char **label, char **value)
{
    char *colon = strchr(line, ':');
    char *end;
    if (!colon)
        return false;
    *colon = '\0';
    end = colon;
    while (end > line && isspace((unsigned char)end[-1]))
        end--;
    *end = '\0';
    *label = line;
    *value = skip_ws(colon + 1);
    return true;
}

static bool parse_u64(const char *v, uint64_t *out)
{
    char *end;
    unsigned long long x;
    if (!v || !*v)
        return false;
    x = strtoull(v, &end, 10);
    if (end == v)
        return false;
    *out = (uint64_t)x;
    return true;
}

/* 时间字段解析：识别行尾单位并归一到 µs。
 * "1234 ms"→1234000；"1234 us"/µs→1234；"1234 s"→1234000000；无单位按 µs。 */
static bool parse_time_us(const char *v, uint64_t *out)
{
    char *end;
    unsigned long long x;
    unsigned mult = 1;
    if (!v || !*v)
        return false;
    x = strtoull(v, &end, 10);
    if (end == v)
        return false;
    end = skip_ws(end);
    if (strncmp(end, "ms", 2) == 0)
        mult = 1000;
    else if (strncmp(end, "us", 2) == 0 || strncmp(end, "\xc2\xb5s", 3) == 0)
        mult = 1;
    else if (*end == 's')
        mult = 1000000;
    if (x != 0 && mult > (unsigned)(UINT64_MAX / x))
        return false; /* 溢出保护 */
    *out = (uint64_t)x * mult;
    return true;
}

static bool parse_int_dbm(const char *v, int *out)
{
    char *end;
    long x;
    if (!v || !*v)
        return false;
    x = strtol(v, &end, 10);
    if (end == v)
        return false;
    *out = (int)x;
    return true;
}

/* tx bitrate 解析："144.4 MBit/s"、"65000 kBit/s"、"5.5 MBit/s VHT..." → Mbit/s */
static bool parse_bitrate_mbps(const char *v, double *out)
{
    char *end;
    double r;
    if (!v || !*v)
        return false;
    r = strtod(v, &end);
    if (end == v)
        return false;
    end = skip_ws(end);
    if (strncmp(end, "kBit/s", 6) == 0)
        r /= 1000.0;
    else if (strncmp(end, "GBit/s", 6) == 0)
        r *= 1000.0;
    else if (strncmp(end, "Bit/s", 5) == 0)
        r /= 1e6;
    /* "MBit/s" 或无单位：按 MBit/s 原值 */
    *out = r;
    return true;
}

/* ---------------- survey 解析 ---------------- */

static survey_block_t *survey_new_block(survey_dump_t *d)
{
    survey_block_t *b;
    if (d->n >= MAX_SURVEY_BLOCKS)
        return NULL;
    b = &d->b[d->n++];
    memset(b, 0, sizeof *b);
    return b;
}

static bool survey_block_has_data(const survey_block_t *b)
{
    return b->have_freq || b->have_noise || b->have_active || b->have_busy ||
           b->have_extbusy || b->have_rx || b->have_tx || b->in_use_seen;
}

/* 去掉尾部空块（如末尾出现 "Survey results for" 却无字段） */
static void survey_trim(survey_dump_t *d)
{
    while (d->n > 0 && !survey_block_has_data(&d->b[d->n - 1]))
        d->n--;
}

static int parse_survey_file(const char *path, survey_dump_t *d)
{
    FILE *f;
    char line[LINE_BUF];
    survey_block_t *cur = NULL;

    memset(d, 0, sizeof *d);
    f = fopen(path, "r");
    if (!f)
        return -1;

    while (fgets(line, sizeof line, f)) {
        char *s = skip_ws(line), *label, *value;
        rstrip(s);

        if (!*s)
            continue;

        /* 每个信道记录都以 "Survey results for wlan0:" 开头（iw 逐记录打印头） */
        if (strncmp(s, "Survey results for", 18) == 0) {
            char *p = skip_ws(s + 18), *q;
            cur = survey_new_block(d);
            if (cur) {
                q = p;
                while (*q && *q != ':')
                    q++;
                if ((size_t)(q - p) < sizeof d->iface) {
                    memcpy(d->iface, p, (size_t)(q - p));
                    d->iface[q - p] = '\0';
                }
            }
            continue;
        }

        if (!split_label(s, &label, &value))
            continue; /* 无冒号的内容行直接忽略 */

        /* 防御：没有头行时，重复出现的 frequency: 也应开新块 */
        if (strcmp(label, "frequency") == 0 && cur && cur->have_freq)
            cur = survey_new_block(d);
        if (!cur)
            cur = survey_new_block(d);
        if (!cur)
            continue;

        if (strcmp(label, "frequency") == 0) {
            char *end;
            double fr = strtod(value, &end);
            if (end != value) {
                cur->freq_mhz = fr;
                cur->have_freq = true;
            }
        } else if (strcmp(label, "in use") == 0) {
            cur->in_use = (strncmp(value, "yes", 3) == 0);
            cur->in_use_seen = true;
        } else if (strcmp(label, "noise") == 0) {
            int n;
            if (parse_int_dbm(value, &n)) {
                cur->noise_dbm = n;
                cur->have_noise = true;
            }
        } else if (strcmp(label, "channel active time") == 0) {
            uint64_t t;
            if (parse_time_us(value, &t)) {
                cur->active_us = t;
                cur->have_active = true;
            }
        } else if (strcmp(label, "channel busy time") == 0) {
            uint64_t t;
            if (parse_time_us(value, &t)) {
                cur->busy_us = t;
                cur->have_busy = true;
            }
        } else if (strcmp(label, "extended channel busy time") == 0) {
            uint64_t t;
            if (parse_time_us(value, &t)) {
                cur->extbusy_us = t;
                cur->have_extbusy = true;
            }
        } else if (strcmp(label, "channel receive time") == 0) {
            uint64_t t;
            if (parse_time_us(value, &t)) {
                cur->rx_us = t;
                cur->have_rx = true;
            }
        } else if (strcmp(label, "channel transmit time") == 0) {
            uint64_t t;
            if (parse_time_us(value, &t)) {
                cur->tx_us = t;
                cur->have_tx = true;
            }
        }
        /* 其余标签（channel width 等）忽略 */
    }
    fclose(f);
    survey_trim(d);
    return 0;
}

static survey_stat_t survey_analyze(const survey_block_t *b)
{
    survey_stat_t st;
    memset(&st, 0, sizeof st);
    st.freq_mhz = b->freq_mhz;
    st.in_use = b->in_use;
    st.noise_dbm = b->noise_dbm;
    st.active_us = b->active_us;
    st.busy_us = b->busy_us;
    st.extbusy_us = b->extbusy_us;
    st.rx_us = b->rx_us;
    st.tx_us = b->tx_us;
    if (!b->have_active || b->active_us == 0)
        return st; /* valid=false：无 active 时间无法算占比 */
    st.valid = true;
    st.busy_pct = 100.0 * (double)b->busy_us / (double)b->active_us;
    st.rx_pct = 100.0 * (double)b->rx_us / (double)b->active_us;
    st.tx_pct = 100.0 * (double)b->tx_us / (double)b->active_us;
    /* busy 里扣掉本机 rx/tx，余下是他人流量/干扰占用的信道时间 */
    st.other_pct = 100.0 * (double)(b->busy_us > b->rx_us + b->tx_us
                                        ? b->busy_us - b->rx_us - b->tx_us
                                        : 0) /
                   (double)b->active_us;
    st.saturated = st.busy_pct > BUSY_SATURATION_PCT;
    return st;
}

/* ---------------- station 解析 ---------------- */

static station_t *station_new(station_dump_t *d)
{
    station_t *st;
    if (d->n >= MAX_STATIONS)
        return NULL;
    st = &d->s[d->n++];
    memset(st, 0, sizeof *st);
    return st;
}

static int parse_station_file(const char *path, station_dump_t *d)
{
    FILE *f;
    char line[LINE_BUF];
    station_t *cur = NULL;

    memset(d, 0, sizeof *d);
    f = fopen(path, "r");
    if (!f)
        return -1;

    while (fgets(line, sizeof line, f)) {
        char *s = skip_ws(line), *label, *value;
        rstrip(s);

        if (!*s)
            continue;

        if (strncmp(s, "Station ", 8) == 0) {
            char *p = s + 8, *paren;
            cur = station_new(d);
            if (cur)
                sscanf(p, "%31s", cur->mac);
            paren = strstr(s, "(on ");
            if (paren && strlen(paren) > 4) {
                size_t i = 0;
                paren += 4;
                while (paren[i] && paren[i] != ')' && i + 1 < sizeof d->iface) {
                    d->iface[i] = paren[i];
                    i++;
                }
                d->iface[i] = '\0';
            }
            continue;
        }

        if (!split_label(s, &label, &value))
            continue;
        if (!cur)
            continue;

        if (strcmp(label, "signal") == 0) { /* 注意与 "signal avg" 是不同标签 */
            int v;
            if (parse_int_dbm(value, &v)) {
                cur->signal_dbm = v;
                cur->have_signal = true;
            }
        } else if (strcmp(label, "rx bytes") == 0) {
            uint64_t v;
            if (parse_u64(value, &v)) {
                cur->rx_bytes = v;
                cur->have_rx_bytes = true;
            }
        } else if (strcmp(label, "rx packets") == 0) {
            uint64_t v;
            if (parse_u64(value, &v)) {
                cur->rx_packets = v;
                cur->have_rx_packets = true;
            }
        } else if (strcmp(label, "tx bytes") == 0) {
            uint64_t v;
            if (parse_u64(value, &v)) {
                cur->tx_bytes = v;
                cur->have_tx_bytes = true;
            }
        } else if (strcmp(label, "tx packets") == 0) {
            uint64_t v;
            if (parse_u64(value, &v)) {
                cur->tx_packets = v;
                cur->have_tx_packets = true;
            }
        } else if (strcmp(label, "tx retries") == 0) {
            uint64_t v;
            if (parse_u64(value, &v)) {
                cur->tx_retries = v;
                cur->have_tx_retries = true;
            }
        } else if (strcmp(label, "tx failed") == 0) {
            uint64_t v;
            if (parse_u64(value, &v)) {
                cur->tx_failed = v;
                cur->have_tx_failed = true;
            }
        } else if (strcmp(label, "tx bitrate") == 0) {
            double v;
            if (parse_bitrate_mbps(value, &v)) {
                cur->tx_bitrate_mbps = v;
                cur->have_tx_bitrate = true;
            }
        }
        /* 其余标签（TID/authorized/WMM…）忽略——TID 行的标签是 "TID 00" */
    }
    fclose(f);
    while (d->n > 0 && d->s[d->n - 1].mac[0] == '\0' && !d->s[d->n - 1].have_tx_packets)
        d->n--; /* 去掉尾部空站 */
    return 0;
}

static station_stat_t station_analyze(const station_t *st)
{
    station_stat_t a;
    memset(&a, 0, sizeof a);
    if (!st->have_tx_packets || st->tx_packets == 0)
        return a; /* valid=false */
    a.valid = true;
    a.retry_pct = 100.0 * (double)st->tx_retries / (double)st->tx_packets;
    a.high_retry = a.retry_pct > RETRY_HIGH_PCT;
    return a;
}

/* ---------------- 报告打印 ---------------- */

static void survey_report(const survey_dump_t *d, const char *src)
{
    int i;
    printf("== iw survey dump 解析（%s，接口 %s）==\n", src,
           d->iface[0] ? d->iface : "?");
    for (i = 0; i < d->n; i++) {
        survey_stat_t st = survey_analyze(&d->b[i]);
        printf("[survey %d] freq=%.0f MHz  in-use=%s", i + 1, st.freq_mhz,
               d->b[i].in_use_seen ? (st.in_use ? "YES" : "no") : "n/a");
        if (d->b[i].have_noise)
            printf("  noise=%d dBm", st.noise_dbm);
        printf("\n");
        if (!st.valid) {
            printf("    active 缺失或为 0，无法计算占用率\n");
            continue;
        }
        printf("    active=%llu us  busy=%llu us  rx=%llu us  tx=%llu us  extbusy=%llu us\n",
               (unsigned long long)st.active_us, (unsigned long long)st.busy_us,
               (unsigned long long)st.rx_us, (unsigned long long)st.tx_us,
               (unsigned long long)st.extbusy_us);
        printf("    信道占用 busy=%.2f%%  rx 份额=%.2f%%  tx 份额=%.2f%%  其余 busy=%.2f%%\n",
               st.busy_pct, st.rx_pct, st.tx_pct, st.other_pct);
        if (st.saturated)
            printf("    >>> 饱和预警: busy %.2f%% > %.0f%%，信道时间已被占满（排查邻道/干扰或换信道）\n",
                   st.busy_pct, BUSY_SATURATION_PCT);
        else
            printf("    busy=%.2f%% <= %.0f%%，未触发饱和预警\n", st.busy_pct,
                   BUSY_SATURATION_PCT);
    }
    if (d->n == 0)
        printf("（未解析到任何 survey 记录）\n");
}

static void station_report(const station_dump_t *d, const char *src)
{
    int i;
    printf("== iw station dump 解析（%s，接口 %s）==\n", src,
           d->iface[0] ? d->iface : "?");
    for (i = 0; i < d->n; i++) {
        const station_t *st = &d->s[i];
        station_stat_t a = station_analyze(st);
        printf("[station %d] %s", i + 1, st->mac);
        if (st->have_signal)
            printf("  signal=%d dBm", st->signal_dbm);
        if (st->have_tx_bitrate)
            printf("  tx_bitrate=%.1f MBit/s", st->tx_bitrate_mbps);
        printf("\n");
        printf("    tx: packets=%llu bytes=%llu retries=%llu failed=%llu\n",
               (unsigned long long)st->tx_packets, (unsigned long long)st->tx_bytes,
               (unsigned long long)st->tx_retries, (unsigned long long)st->tx_failed);
        if (!a.valid) {
            printf("    tx packets 缺失或为 0，无法计算重传率\n");
            continue;
        }
        printf("    重传率 = %llu/%llu = %.2f%%\n",
               (unsigned long long)st->tx_retries, (unsigned long long)st->tx_packets,
               a.retry_pct);
        if (a.high_retry)
            printf("    >>> 重传偏高: %.2f%% > %.0f%%（链路质量差/信号弱，降速率或改善覆盖）\n",
                   a.retry_pct, RETRY_HIGH_PCT);
        else
            printf("    重传率 %.2f%% <= %.0f%%，正常\n", a.retry_pct, RETRY_HIGH_PCT);
    }
    if (d->n == 0)
        printf("（未解析到任何站点）\n");
}

/* ---------------- 自检：期望值与源码逐项比对 ---------------- */

static int g_pass = 0, g_fail = 0;

static void t_int(const char *name, long long got, long long exp)
{
    if (got == exp) {
        printf("[PASS] %s = %lld\n", name, exp);
        g_pass++;
    } else {
        printf("[FAIL] %s: 实得 %lld, 期望 %lld\n", name, got, exp);
        g_fail++;
    }
}

static void t_dbl(const char *name, double got, double exp)
{
    double tol = 1e-6 * (fabs(exp) > 1.0 ? fabs(exp) : 1.0);
    if (fabs(got - exp) <= tol) {
        printf("[PASS] %s = %.2f\n", name, exp);
        g_pass++;
    } else {
        printf("[FAIL] %s: 实得 %.4f, 期望 %.4f\n", name, got, exp);
        g_fail++;
    }
}

static void t_bool(const char *name, bool got, bool exp)
{
    if (got == exp) {
        printf("[PASS] %s = %s\n", name, exp ? "真" : "假");
        g_pass++;
    } else {
        printf("[FAIL] %s: 实得 %s, 期望 %s\n", name, got ? "真" : "假",
               exp ? "真" : "假");
        g_fail++;
    }
}

static void t_str(const char *name, const char *got, const char *exp)
{
    if (strcmp(got, exp) == 0) {
        printf("[PASS] %s = %s\n", name, exp);
        g_pass++;
    } else {
        printf("[FAIL] %s: 实得 \"%s\", 期望 \"%s\"\n", name, got, exp);
        g_fail++;
    }
}

/* 依次尝试「工程根相对路径」与「裸文件名」两种位置 */
static FILE *open_fixture(const char *path, const char *base)
{
    char buf[512];
    FILE *f = fopen(path, "r");
    if (f)
        return f;
    snprintf(buf, sizeof buf, "%s", base);
    f = fopen(buf, "r");
    if (f)
        return f;
    fprintf(stderr, "无法打开 %s（也试过 %s）——请在工程目录内运行\n", path, buf);
    return NULL;
}

static int self_test(void)
{
    survey_dump_t sd;
    station_dump_t td;
    survey_stat_t s1, s2;
    station_stat_t a1, a2;
    FILE *f;

    printf("airtime_probe 自检：解析 fixtures/ 构造样例并与源码期望值比对\n");
    printf("（fixtures 按 iw 输出布局构造，真机数据由 collect.sh 采集）\n\n");

    f = open_fixture("fixtures/survey_sample.txt", "survey_sample.txt");
    if (!f)
        return 2;
    fclose(f);
    if (parse_survey_file("fixtures/survey_sample.txt", &sd) != 0 &&
        parse_survey_file("survey_sample.txt", &sd) != 0)
        return 2;

    f = open_fixture("fixtures/station_sample.txt", "station_sample.txt");
    if (!f)
        return 2;
    fclose(f);
    if (parse_station_file("fixtures/station_sample.txt", &td) != 0 &&
        parse_station_file("station_sample.txt", &td) != 0)
        return 2;

    survey_report(&sd, "fixtures/survey_sample.txt");
    printf("\n");
    station_report(&td, "fixtures/station_sample.txt");
    printf("\n");

    s1 = survey_analyze(&sd.b[0]);
    s2 = survey_analyze(&sd.b[1]);
    a1 = station_analyze(&td.s[0]);
    a2 = station_analyze(&td.s[1]);

    printf("== 期望值逐项比对（fixtures 设计值 → 解析实得）==\n");

    t_int("survey.记录数", sd.n, 2);
    t_dbl("survey[1].frequency_mhz", sd.b[0].freq_mhz, 2412.0);
    t_bool("survey[1].in_use", sd.b[0].in_use, true);
    t_int("survey[1].noise_dbm", sd.b[0].noise_dbm, -92);
    t_int("survey[1].active_us(1000000 ms 归一)", (long long)sd.b[0].active_us,
          1000000000LL);
    t_int("survey[1].busy_us(764000 ms 归一)", (long long)sd.b[0].busy_us, 764000000LL);
    t_int("survey[1].rx_us(321000 ms 归一)", (long long)sd.b[0].rx_us, 321000000LL);
    t_int("survey[1].tx_us(298000 ms 归一)", (long long)sd.b[0].tx_us, 298000000LL);
    t_int("survey[1].extbusy_us(45000 ms 归一)", (long long)sd.b[0].extbusy_us,
          45000000LL);
    t_dbl("survey[1].busy_pct", s1.busy_pct, 76.40);
    t_dbl("survey[1].rx_pct", s1.rx_pct, 32.10);
    t_dbl("survey[1].tx_pct", s1.tx_pct, 29.80);
    t_dbl("survey[1].other_pct(busy-rx-tx)", s1.other_pct, 14.50);
    t_bool("survey[1].饱和预警(>70%)", s1.saturated, true);
    t_dbl("survey[2].frequency_mhz", sd.b[1].freq_mhz, 2437.0);
    t_bool("survey[2].in_use(未打印该行)", sd.b[1].in_use, false);
    t_int("survey[2].noise_dbm", sd.b[1].noise_dbm, -95);
    t_dbl("survey[2].busy_pct", s2.busy_pct, 35.00);
    t_bool("survey[2].饱和预警(>70%)", s2.saturated, false);

    t_int("station.站点数", td.n, 2);
    t_str("station[1].mac", td.s[0].mac, "3c:71:bf:9a:1c:44");
    t_int("station[1].signal_dbm", td.s[0].signal_dbm, -52);
    t_int("station[1].tx_packets", (long long)td.s[0].tx_packets, 50000LL);
    t_int("station[1].tx_bytes", (long long)td.s[0].tx_bytes, 9412877LL);
    t_int("station[1].tx_retries", (long long)td.s[0].tx_retries, 18500LL);
    t_int("station[1].tx_failed", (long long)td.s[0].tx_failed, 2100LL);
    t_dbl("station[1].tx_bitrate_mbps", td.s[0].tx_bitrate_mbps, 144.4);
    t_dbl("station[1].retry_pct", a1.retry_pct, 37.00);
    t_bool("station[1].重传偏高(>30%)", a1.high_retry, true);
    t_str("station[2].mac", td.s[1].mac, "ac:37:43:9f:22:10");
    t_int("station[2].signal_dbm", td.s[1].signal_dbm, -67);
    t_dbl("station[2].tx_bitrate_mbps", td.s[1].tx_bitrate_mbps, 72.2);
    t_dbl("station[2].retry_pct", a2.retry_pct, 7.50);
    t_bool("station[2].重传偏高(>30%)", a2.high_retry, false);

    printf("\n自检汇总: %d/%d PASS\n", g_pass, g_pass + g_fail);
    if (g_fail == 0) {
        printf("ALL TESTS PASSED\n");
        return 0;
    }
    printf("SELF-TEST FAILED (%d 项不匹配)\n", g_fail);
    return 1;
}

/* 只解析并打印报告（不给期望值）——真机采集文件用 */
static int run_files(const char *survey_path, const char *station_path)
{
    survey_dump_t sd;
    station_dump_t td;

    if (parse_survey_file(survey_path, &sd) != 0) {
        fprintf(stderr, "无法打开 survey 文件: %s\n", survey_path);
        return 2;
    }
    survey_report(&sd, survey_path);
    printf("\n");

    if (station_path) {
        if (parse_station_file(station_path, &td) != 0) {
            fprintf(stderr, "无法打开 station 文件: %s\n", station_path);
            return 2;
        }
        station_report(&td, station_path);
    }
    return 0;
}

int main(int argc, char **argv)
{
    if (argc >= 2)
        return run_files(argv[1], argc >= 3 ? argv[2] : NULL);
    return self_test();
}
