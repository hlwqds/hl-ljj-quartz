/*
 * dcf_sim.c — 离散时隙 CSMA/CA（IEEE 802.11 DCF）饱和竞争仿真
 *
 * 配套章节: [[ch01-dcf-contention-basics|第一章：争抢的账本]]
 * 语言/依赖: C11，零第三方依赖，单文件（仅 stdio / stdint / string）。
 *
 * 模型：
 *   - N 个饱和站点，始终有包可发；
 *   - 每站从 [0, CW) 均匀抽退避计数器，只在空闲时隙递减，忙时隙冻结；
 *   - 某时隙恰 1 站计数到 0 → 成功发送；≥2 站同时到 0 → 全部碰撞；
 *   - 碰撞后 BEB：CW 翻倍（封顶 CWmax）；成功后回 CWmin；
 *   - 发送 1 包占 1 时隙；E3 聚合时每次胜出连发 k 包、占 k 时隙
 *     （碰撞双方同时烧掉 k 时隙——碰撞的 A-MPDU 整条报废）；
 *   - E4 限速站：每 50 时隙醒一次，醒来抽 [0,CWmin) 退避正常参与竞争，
 *     完成一次尝试（无论成败）即继续睡，不做 BEB 重试。
 *
 * 指标（表格列名）：
 *   thr    归一化吞吐 = 成功包数 / 总时隙（k=1 时即 成功时隙/总时隙）
 *   idle%  空闲时隙占比
 *   coll%  碰撞时隙占比
 *   tryc%  每次发射尝试的碰撞概率 = 碰撞发射次数 / 总发射次数
 *   jain   Jain 公平指数 = (Σs_i)² / (N·Σs_i²)，s_i 为各站成功包数
 *
 * 随机数：xorshift32，固定种子 42；每个配置重新播种 → 同机重跑输出一致。
 */

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define MAX_STA 32
#define RNG_SEED 42u

/* ---------------- RNG: xorshift32，确定性可复现 ---------------- */

static uint32_t rng_state = RNG_SEED;

static void rng_seed(uint32_t s) { rng_state = s ? s : 1u; }

static uint32_t rng_next(void) {
    uint32_t x = rng_state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    rng_state = x;
    return x;
}

static uint32_t rng_below(uint32_t n) { return rng_next() % n; }

/* ---------------- 站点状态 ---------------- */

typedef struct {
    int contending;     /* 本时隙是否参与竞争（饱和站恒为 1；限速站苏醒期间为 1） */
    int backoff;        /* 退避计数器：空闲时隙递减，减到 0 的那个时隙发射 */
    uint32_t cw;        /* 当前竞争窗口，退避均匀抽自 [0, cw) */
    int limited;        /* 是否限速站 */
    int sleep_left;     /* 限速站：距下次苏醒的时隙数（忙/空闲时隙都计时） */
    uint64_t succ_pkts; /* 成功发出的总包数 */
    uint64_t attempts;  /* 发射尝试次数（成功 + 碰撞） */
    uint64_t coll_cnt;  /* 卷入碰撞的次数 */
} Sta;

/* ---------------- 配置与结果 ---------------- */

typedef struct {
    int n;            /* 站点数 */
    uint32_t cw_min;  /* 最小竞争窗口 */
    uint32_t cw_max;  /* 最大竞争窗口（BEB 封顶） */
    int agg_k;        /* 每次成功接入连发 k 包，占 k 时隙 */
    int limited_idx;  /* 限速站下标，-1 = 无 */
    int limit_period; /* 限速站相邻两次尝试的最小间隔时隙数 */
    uint64_t slots;   /* 目标仿真时隙数 */
} Cfg;

typedef struct {
    uint64_t total, idle, succ, coll; /* 时隙账本：总 / 空闲 / 成功忙 / 碰撞忙 */
    uint64_t wins, attempts, pkts;    /* 成功接入次数 / 发射尝试次数 / 成功包数 */
    double thr, idle_pct, coll_pct, try_coll, jain;
    double per_sta_thr[MAX_STA];
    uint64_t per_sta_pkts[MAX_STA];
    uint64_t per_sta_att[MAX_STA];
} Res;

/* ---------------- 核心仿真 ---------------- */

static void simulate(const Cfg *c, Res *r) {
    Sta st[MAX_STA];
    memset(st, 0, sizeof st);
    memset(r, 0, sizeof *r);
    rng_seed(RNG_SEED); /* 每个配置重新播种，输出可复现 */

    for (int i = 0; i < c->n; i++) {
        st[i].cw = c->cw_min;
        st[i].contending = 1;
        st[i].backoff = (int)rng_below(st[i].cw);
        if (i == c->limited_idx) {
            st[i].limited = 1;
            st[i].contending = 0; /* 先睡 limit_period 个时隙 */
            st[i].sleep_left = c->limit_period;
        }
    }

    while (r->total < c->slots) {
        /* 找出本时隙计数到 0 的竞争站 */
        int tx[MAX_STA];
        int ntx = 0;
        for (int i = 0; i < c->n; i++)
            if (st[i].contending && st[i].backoff == 0) tx[ntx++] = i;

        uint64_t elapsed; /* 本步推进的时隙数 */
        if (ntx == 0) {
            /* 空闲时隙：竞争站退避计数递减 */
            elapsed = 1;
            r->idle++;
            r->total++;
            for (int i = 0; i < c->n; i++)
                if (st[i].contending && st[i].backoff > 0) st[i].backoff--;
        } else if (ntx == 1) {
            /* 唯一到 0 者：成功，连发 agg_k 包占 agg_k 时隙 */
            int w = tx[0];
            elapsed = (uint64_t)c->agg_k;
            r->succ += elapsed;
            r->total += elapsed;
            r->wins++;
            r->attempts++;
            r->pkts += (uint64_t)c->agg_k;
            st[w].succ_pkts += (uint64_t)c->agg_k;
            st[w].attempts++;
            st[w].cw = c->cw_min; /* 成功 → 回 CWmin */
            st[w].backoff = (int)rng_below(st[w].cw);
            if (st[w].limited) { /* 限速站一次尝试完成，回去睡觉 */
                st[w].contending = 0;
                st[w].sleep_left = c->limit_period;
            }
        } else {
            /* ≥2 站同时到 0：碰撞，各方烧掉 agg_k 时隙后按 BEB 重抽 */
            elapsed = (uint64_t)c->agg_k;
            r->coll += elapsed;
            r->total += elapsed;
            r->attempts += (uint64_t)ntx;
            for (int j = 0; j < ntx; j++) {
                int w = tx[j];
                st[w].attempts++;
                st[w].coll_cnt++;
                st[w].cw = (st[w].cw * 2u > c->cw_max) ? c->cw_max : st[w].cw * 2u;
                st[w].backoff = (int)rng_below(st[w].cw);
                if (st[w].limited) { /* 限速站不重试：记一次失败尝试后睡眠 */
                    st[w].cw = c->cw_min;
                    st[w].contending = 0;
                    st[w].sleep_left = c->limit_period;
                }
            }
        }

        /* 限速站睡眠计时：每过一个真实时隙（含忙时隙）递减 */
        for (int i = 0; i < c->n; i++) {
            if (st[i].limited && !st[i].contending) {
                st[i].sleep_left -= (int)elapsed;
                if (st[i].sleep_left <= 0) {
                    st[i].contending = 1;
                    st[i].cw = c->cw_min;
                    st[i].backoff = (int)rng_below(st[i].cw);
                }
            }
        }
    }

    /* 汇总指标 */
    double sum = 0.0, sq = 0.0;
    for (int i = 0; i < c->n; i++) {
        double s = (double)st[i].succ_pkts;
        sum += s;
        sq += s * s;
        r->per_sta_pkts[i] = st[i].succ_pkts;
        r->per_sta_att[i] = st[i].attempts;
        r->per_sta_thr[i] = (double)st[i].succ_pkts / (double)r->total;
    }
    r->thr = (double)r->pkts / (double)r->total;
    r->idle_pct = 100.0 * (double)r->idle / (double)r->total;
    r->coll_pct = 100.0 * (double)r->coll / (double)r->total;
    r->try_coll = r->attempts ? (double)(r->attempts - r->wins) / (double)r->attempts : 0.0;
    r->jain = sq > 0.0 ? (sum * sum) / ((double)c->n * sq) : 1.0;
}

/* ---------------- 四组实验 ---------------- */

static void legend_common(void) {
    puts("thr=归一化吞吐(成功包/总时隙)  idle%=空闲时隙占比  coll%=碰撞时隙占比");
    puts("tryc%=每次发射尝试的碰撞概率  jain=各站按成功包数的Jain公平指数");
}

static void run_e1(uint64_t slots) {
    puts("");
    puts("==================================================================");
    puts("E1 站点数 N 的影响: CWmin=15, CWmax=1023, 聚合 k=1, N∈{2,4,8,16}");
    puts("==================================================================");
    legend_common();
    printf("%4s %8s %8s %8s %8s %8s\n", "N", "thr", "idle%", "coll%", "tryc%", "jain");
    static const int ns[] = {2, 4, 8, 16};
    for (size_t k = 0; k < sizeof ns / sizeof ns[0]; k++) {
        Cfg c = {0};
        c.n = ns[k];
        c.cw_min = 15;
        c.cw_max = 1023;
        c.agg_k = 1;
        c.limited_idx = -1;
        c.slots = slots;
        Res r;
        simulate(&c, &r);
        printf("%4d %8.4f %8.2f %8.2f %8.2f %8.4f\n", ns[k], r.thr, r.idle_pct, r.coll_pct,
               100.0 * r.try_coll, r.jain);
    }
}

static void run_e2(uint64_t slots) {
    puts("");
    puts("==================================================================");
    puts("E2 CWmin 的影响: N=8, CWmax=1023, 聚合 k=1, CWmin∈{3,7,15,31,63}");
    puts("==================================================================");
    legend_common();
    printf("%6s %8s %8s %8s %8s %8s\n", "CWmin", "thr", "idle%", "coll%", "tryc%", "jain");
    static const uint32_t cws[] = {3, 7, 15, 31, 63};
    for (size_t k = 0; k < sizeof cws / sizeof cws[0]; k++) {
        Cfg c = {0};
        c.n = 8;
        c.cw_min = cws[k];
        c.cw_max = 1023;
        c.agg_k = 1;
        c.limited_idx = -1;
        c.slots = slots;
        Res r;
        simulate(&c, &r);
        printf("%6u %8.4f %8.2f %8.2f %8.2f %8.4f\n", (unsigned)cws[k], r.thr, r.idle_pct,
               r.coll_pct, 100.0 * r.try_coll, r.jain);
    }
}

static void run_e3(uint64_t slots) {
    puts("");
    puts("==================================================================");
    puts("E3 A-MPDU 聚合收益: N=8, CWmin=15, CWmax=1023, 每次胜出连发 k 包(占 k 时隙)");
    puts("   (碰撞双方同样烧掉 k 时隙——碰撞的 A-MPDU 整条报废)");
    puts("==================================================================");
    puts("thr=有效吞吐(成功包/总时隙)  wins=成功接入次数  att=发射尝试次数");
    puts("coll=碰撞发射次数  pkts=成功包总数");
    puts("ovh/win=每次成功接入摊到的竞争开销时隙((idle+coll)/wins)  ovh/pkt=摊到每包");
    printf("%4s %8s %10s %10s %10s %12s %10s %10s\n", "k", "thr", "wins", "att", "coll",
           "pkts", "ovh/win", "ovh/pkt");
    static const int ks[] = {1, 4, 16, 64};
    for (size_t i = 0; i < sizeof ks / sizeof ks[0]; i++) {
        Cfg c = {0};
        c.n = 8;
        c.cw_min = 15;
        c.cw_max = 1023;
        c.agg_k = ks[i];
        c.limited_idx = -1;
        c.slots = slots;
        Res r;
        simulate(&c, &r);
        double ovh = (double)r.idle + (double)r.coll;
        double ovh_win = r.wins ? ovh / (double)r.wins : 0.0;
        double ovh_pkt = r.pkts ? ovh / (double)r.pkts : 0.0;
        printf("%4d %8.4f %10llu %10llu %10llu %12llu %10.2f %10.3f\n", ks[i], r.thr,
               (unsigned long long)r.wins, (unsigned long long)r.attempts,
               (unsigned long long)(r.attempts - r.wins), (unsigned long long)r.pkts, ovh_win,
               ovh_pkt);
    }
}

static void run_e4(uint64_t slots) {
    puts("");
    puts("==================================================================");
    puts("E4 用户场景: N=2, CWmin=15, CWmax=1023, k=1");
    puts("   both-saturated = 两站全饱和");
    puts("   A-sat+B-lim50  = A 全饱和 + B 限速(每 50 时隙只尝试一次)");
    puts("==================================================================");
    legend_common();
    printf("%-16s %8s %8s %8s %8s %8s %8s\n", "scenario", "thr_A", "thr_B", "thr_all", "coll%",
           "tryc%", "jain");

    Cfg c1 = {0};
    c1.n = 2;
    c1.cw_min = 15;
    c1.cw_max = 1023;
    c1.agg_k = 1;
    c1.limited_idx = -1;
    c1.slots = slots;
    Res r1;
    simulate(&c1, &r1);
    printf("%-16s %8.4f %8.4f %8.4f %8.2f %8.2f %8.4f\n", "both-saturated", r1.per_sta_thr[0],
           r1.per_sta_thr[1], r1.thr, r1.coll_pct, 100.0 * r1.try_coll, r1.jain);

    Cfg c2 = {0};
    c2.n = 2;
    c2.cw_min = 15;
    c2.cw_max = 1023;
    c2.agg_k = 1;
    c2.limited_idx = 1;
    c2.limit_period = 50;
    c2.slots = slots;
    Res r2;
    simulate(&c2, &r2);
    printf("%-16s %8.4f %8.4f %8.4f %8.2f %8.2f %8.4f\n", "A-sat+B-lim50", r2.per_sta_thr[0],
           r2.per_sta_thr[1], r2.thr, r2.coll_pct, 100.0 * r2.try_coll, r2.jain);

    printf("  both-saturated : A 成功 %llu 包 / %llu 次尝试, B 成功 %llu 包 / %llu 次尝试\n",
           (unsigned long long)r1.per_sta_pkts[0], (unsigned long long)r1.per_sta_att[0],
           (unsigned long long)r1.per_sta_pkts[1], (unsigned long long)r1.per_sta_att[1]);
    printf("  A-sat+B-lim50  : A 成功 %llu 包 / %llu 次尝试, B 尝试 %llu 次(成功 %llu 次, 碰撞 %llu 次)\n",
           (unsigned long long)r2.per_sta_pkts[0], (unsigned long long)r2.per_sta_att[0],
           (unsigned long long)r2.per_sta_att[1], (unsigned long long)r2.per_sta_pkts[1],
           (unsigned long long)(r2.per_sta_att[1] - r2.per_sta_pkts[1]));
}

int main(void) {
    const uint64_t slots = 1000000;
    puts("DCF 饱和竞争离散时隙仿真 dcf_sim.c (C11, 零依赖)");
    puts("退避均匀抽自 [0,CW); 空闲时隙递减, 忙时隙冻结; 恰 1 站到 0=成功, ≥2 站=碰撞;");
    puts("碰撞 CW 翻倍封顶 CWmax, 成功回 CWmin; 发送 1 包占 1 时隙(E3 聚合 k 包占 k 时隙)。");
    printf("RNG xorshift32 固定种子 %u, 每配置重播; 每配置仿真 %llu 时隙(≥5 万, 末次忙传输可略超)\n",
           (unsigned)RNG_SEED, (unsigned long long)slots);
    run_e1(slots);
    run_e2(slots);
    run_e3(slots);
    run_e4(slots);
    return 0;
}
