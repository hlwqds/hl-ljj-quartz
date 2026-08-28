/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * 案例 A —— RX 就地解析（recv 回调直接在 pbuf payload 上解析 vs 先 memcpy 再解析）
 *
 * 测量对象：单条记录的【应用侧处理成本】——拷贝版含"整条 memcpy 进应用暂存缓冲"
 * 这一跳，零拷贝版直接在 TCP 收到的连续内存上解析。两版随后做同样的字段校验
 * （magic/hdr_sum/body_xsum/seq 连续），底层解析工作量一致，差值就是搬运本身。
 *
 * contiguous 现实检查：pbuf 多段链上 payload 可能跨段。就地路径只对"整条记录落在
 * 本次回调的单一连续区"走零拷贝；跨段记录必须先拼装（这时拷贝不可避免），如实计入
 * span_* 计数并单独记拼装耗时，不混入配对统计。
 *
 * 栈峰值演示：TIMING 阶段之后跑专门的栈探针——先 ZC 批读 tcpip 线程高水位，再 COPY
 * 批（回调内局部数组暂存）再读。HWM 单调性说明见打印与 README。
 */
#include <string.h>

#include "esp_timer.h"

#include "zc_priv.h"

/* ---------------- 采样账本（tcpip 线程独写，END 握手后读取） ---------------- */

/* 采样器改用共享池：pool[0]=拷贝版 pool[1]=零拷贝版（见 zc_priv.h） */
#define SMP_COPY (&g_smp_pool[0])
#define SMP_ZC   (&g_smp_pool[1])
static uint32_t s_n_contig_copy, s_n_contig_zc;
static uint32_t s_n_span_copy, s_n_span_zc;
static int64_t s_span_extra_us;
static uint32_t s_seq_expect;

/* 拷贝快路的应用暂存缓冲（TIMING 阶段用静态缓冲，避免污染栈对比） */
static uint8_t s_stage[REC_HARD_MAX];

/* 帧地址栈深探针：栈向下生长，记录两变体回调帧内对象出现的最低地址，
 * 差值即"拷贝版局部暂存缓冲"带来的真实帧深增量（HWM 的旁证见运行行） */
static volatile intptr_t s_spmin_zc, s_spmin_copy;

/* 探针模式：0=按块奇偶自动；1=强制零拷贝；2=强制拷贝且回调内局部数组暂存 */
#define AM_AUTO 0
#define AM_FORCE_ZC 1
#define AM_FORCE_COPY_STACK 2

typedef struct
{
    uint32_t planned_total;
    uint32_t emitted;
    uint32_t seq_base; /* 记录序号跨相位连续（汇点做全序对账） */
    volatile bool done;
    uint8_t probe_mode;
} agen_t;

static agen_t s_ag;

void ex16_caseA_reset(void)
{
    s_seq_expect = 0;
    s_n_contig_copy = s_n_contig_zc = 0;
    s_n_span_copy = s_n_span_zc = 0;
    s_span_extra_us = 0;
    zc_smp_reset(SMP_COPY);
    zc_smp_reset(SMP_ZC);
    s_spmin_zc = 0;
    s_spmin_copy = 0;
    memset(&s_ag, 0, sizeof(s_ag));
}

/* 记录本体校验（两变体同一套逻辑，吃哪个指针是唯一差别） */
static bool validate_record(const uint8_t *rec, uint16_t tot, uint32_t *out_seq)
{
    const char *why;
    uint16_t type = zc_check_rec(rec, tot, out_seq, &why);
    return type != 0xFFFF && (type & 0x7FFFu) == RT_DATA_A;
}

/* 拷贝快路的独立被调函数：局部暂存缓冲只在这个调用栈帧里存在——
 * 零拷贝路径从不调用它，因此该帧深是"拷贝写法专属"的栈开销。
 * （把数组放在与路由同一函数里会被编译器合并帧，量不出差值。） */
static bool parse_via_staging(const uint8_t *rec, uint16_t tot, uint32_t *seq)
{
    uint8_t local[REC_HDR_LEN + CONFIG_ZC_REC_BODY];
    intptr_t a = (intptr_t)&local[0];
    if (s_spmin_copy == 0 || a < s_spmin_copy) {
        s_spmin_copy = a;
    }
    memcpy(local, rec, tot);
    return validate_record(local, tot, seq);
}

/* 汇点入口（引擎保证 rec 指向完整记录；span=true 表示已过拼装） */
static bool caseA_on_rec(zc_sink_t *k, const uint8_t *rec, uint16_t tot,
                         bool span)
{
    uint16_t raw_type = zc_rd16(rec + 4);
    uint16_t t7 = raw_type & 0x7FFFu;

    if (t7 == RT_CTRL_END) {
        return zc_engine_handle_end(k, rec, tot);
    }
    if (t7 != RT_DATA_A) {
        return true;
    }

    bool want_zc =
        (s_ag.probe_mode == AM_FORCE_ZC) ||
        (s_ag.probe_mode == AM_AUTO && (raw_type & RT_VARIANT_ZC) != 0);

    { /* 帧地址基准：任何一条记录的处理都会走到这里 */
        int sp_marker;
        intptr_t a = (intptr_t)&sp_marker;
        if (s_spmin_zc == 0 || a < s_spmin_zc) {
            s_spmin_zc = a;
        }
    }

    if (!span && want_zc) {
        /* —— 零拷贝快路：直接就地在 pbuf 内存上解析 —— */
        int64_t t0 = esp_timer_get_time();
        uint32_t seq = 0;
        bool ok = validate_record(rec, tot, &seq);
        int64_t dt = esp_timer_get_time() - t0;
        if (ok && seq == s_seq_expect) {
            s_seq_expect++;
            s_n_contig_zc++;
            zc_smp_push(SMP_ZC, dt);
        } else {
            printf("$$$ EXFAIL reason=A_zc_check seq=%lu expect=%lu\n",
                   (unsigned long)seq, (unsigned long)s_seq_expect);
            zc_fail("A_bad_record");
        }
        return !g_fail;
    }

    if (!span) {
        /* —— 拷贝快路：整条 memcpy 到应用缓冲后再解析（传统写法）。
         *    栈探针阶段把暂存缓冲放进回调局部变量——这正是"传统写法"在真实
         *    嵌入式代码里的常见形态，也是它对 tcpip 线程栈的隐性税。 —— */
        int64_t t0 = esp_timer_get_time();
        uint32_t seq = 0;
        bool ok;
        if (s_ag.probe_mode == AM_FORCE_COPY_STACK) {
            ok = parse_via_staging(rec, tot, &seq); /* 栈探针：局部缓冲形态 */
        } else {
            memcpy(s_stage, rec, tot); /* 计时形态：静态暂存缓冲 */
            ok = validate_record(s_stage, tot, &seq);
        }
        int64_t dt = esp_timer_get_time() - t0;
        if (ok && seq == s_seq_expect) {
            s_seq_expect++;
            s_n_contig_copy++;
            zc_smp_push(SMP_COPY, dt);
        } else {
            const char *dbg_why;
            uint32_t dbg_seq;
            uint16_t dbg_type = zc_check_rec(s_stage, tot, &dbg_seq, &dbg_why);
            printf(
                "EX16-DBG copycheck type=%04x why=%s tot=%u b0=%02x%02x%02x%02x "
                "len=%u sum=%04x/%04x xs=%08lx/%08lx pl=%02x,%02x,%02x,%02x "
                "want=%02x,%02x,%02x,%02x\n",
                dbg_type, dbg_why ? dbg_why : "?", tot, s_stage[0], s_stage[1],
                s_stage[2], s_stage[3], zc_rd16(s_stage + 10),
                zc_rd16(s_stage + 12), zc_hdr_sum(s_stage),
                (unsigned long)zc_rd32(s_stage + 14),
                (unsigned long)zc_body_xsum(s_stage + REC_HDR_LEN,
                                            zc_rd16(s_stage + 10)),
                s_stage[16], s_stage[17], s_stage[18], s_stage[19],
                zc_pat_byte(0), zc_pat_byte(1), zc_pat_byte(2), zc_pat_byte(3));
            printf("$$$ EXFAIL reason=A_copy_check seq=%lu expect=%lu\n",
                   (unsigned long)seq, (unsigned long)s_seq_expect);
            zc_fail("A_bad_record");
        }
        return !g_fail;
    }

    /* —— 慢路：记录躺在拼装缓冲里，拼装拷贝发生在 deframe 引擎（不可避免）；
     *    计数如实分桶、耗时记进 span 总账，不进配对样本 —— */
    uint32_t seq = 0;
    int64_t t0 = esp_timer_get_time();
    bool ok = validate_record(rec, tot, &seq);
    s_span_extra_us += esp_timer_get_time() - t0;
    if (!ok) {
        zc_fail("A_bad_record_span");
        return false;
    }
    if (want_zc) {
        s_n_span_zc++;
    } else {
        s_n_span_copy++;
    }
    if (seq == s_seq_expect) {
        s_seq_expect++;
    }
    return true;
}

/* ---------------- 发送端生成器（tcpip 线程内被驱动） ---------------- */

static uint16_t agen_rec_total(void)
{
    return (uint16_t)(REC_HDR_LEN + CONFIG_ZC_REC_BODY);
}

/* 发送侧缓冲静态化：发送器与被测解析器共享 tcpip 线程栈，
 * 栈探针阶段必须把发送路径的帧深压到最小，避免掩盖两变体的差值。 */
static uint8_t s_send_rec[REC_HARD_MAX];

/* 构建第 idx 条记录进 buf；probe 模式覆写变体位 */
static void agen_build(uint8_t *buf, uint32_t idx)
{
    bool zc;
    if (s_ag.probe_mode == AM_FORCE_ZC) {
        zc = true;
    } else if (s_ag.probe_mode == AM_FORCE_COPY_STACK) {
        zc = false;
    } else {
        zc = (idx / CONFIG_ZC_BLOCK) % 2 == 1;
    }
    uint16_t type = (uint16_t)(RT_DATA_A | (zc ? RT_VARIANT_ZC : 0u));
    static uint8_t payload[CONFIG_ZC_REC_BODY];
    for (int i = 0; i < CONFIG_ZC_REC_BODY; i++) {
        payload[i] = zc_pat_byte(idx * 31u + (uint32_t)i);
    }
    zc_build_rec(buf, type, s_ag.seq_base + idx, payload,
                 (uint16_t)sizeof(payload));
}

/* 灌窗口：一次尽量多投；投满计划量后返回 true（调用方随后发 END） */
static bool agen_fill_once(zc_cli_t *c)
{
    while (s_ag.emitted < s_ag.planned_total) {
        if ((s_ag.emitted % (CONFIG_ZC_BLOCK * 4)) == 0 && s_ag.emitted > 0) {
            static uint32_t last_prog;
            if (last_prog != s_ag.emitted) {
                last_prog = s_ag.emitted;
                printf("EX16-PROG case=A emitted=%lu/%lu\n",
                       (unsigned long)s_ag.emitted, (unsigned long)s_ag.planned_total);
            }
        }
        agen_build(s_send_rec, s_ag.emitted);
        err_t e = zc_cli_post(c, s_send_rec, agen_rec_total(), TCP_WRITE_FLAG_MORE);
        if (e == ERR_INPROGRESS) {
            return false; /* 等 tcp_sent 唤醒 */
        }
        if (e != ERR_OK) {
            zc_fail("A_write_fail");
            s_ag.done = true;
            return false;
        }
        s_ag.emitted++;
    }
    return true;
}

static void agen_on_sent(void *uctx, struct tcp_pcb *pcb, u16_t len)
{
    (void)uctx;
    (void)len;
    agen_fill_once(&g_cli_main);
    (void)pcb;
}

static void agen_kick_inner(void *arg)
{
    (void)arg;
    agen_fill_once(&g_cli_main);
}

/* 跑一段完整发送计划并等 END-ACK 回环。mode 见 AM_*。 */
static bool agen_run_phase(uint32_t total_recs, uint8_t mode,
                           const char *phase_name, int64_t timeout_ms)
{
    static uint32_t s_seq_cursor; /* 跨相位递增 */
    s_ag.planned_total = total_recs;
    s_ag.emitted = 0;
    s_ag.seq_base = s_seq_cursor;
    s_seq_cursor += total_recs;
    s_ag.done = false;
    s_ag.probe_mode = mode;
    g_svc_main.k.end_seen = false;

    g_cli_main.on_sent = agen_on_sent;
    g_cli_main.uctx_s = NULL;

    printf("== EX16-PHASE name=%s ==\n", phase_name);
    if (!zc_run_in_tcpip(agen_kick_inner, NULL, 5000)) {
        return false;
    }
    /* 等发送泵灌完计划量，然后由编排任务发 END 做闭环握手 */
    int64_t deadline = esp_timer_get_time() + timeout_ms * 1000LL;
    while (s_ag.emitted < s_ag.planned_total) {
        if (g_fail || !g_cli_main.pcb || esp_timer_get_time() > deadline) {
            zc_fail("A_phase_timeout");
            return false;
        }
        vTaskDelay(pdMS_TO_TICKS(10));
    }
    if (!zc_cli_send_ack_wait(&g_cli_main, RT_CTRL_END, zc_end_pack(0, 0),
                              NULL, 0, 5000)) {
        return false;
    }
    g_svc_main.k.end_seen = true; /* ACK 回环已完成，语义等同 */
    printf("EX16-PHASE name=%s done emitted=%lu\n", phase_name,
           (unsigned long)s_ag.emitted);
    return true;
}

/* ---------------- 编排入口 ---------------- */

bool ex16_caseA_run(void)
{
    if (g_case != 1) {
        return true;
    }
    const uint32_t rounds = (uint32_t)CONFIG_ZC_ROUNDS_PER_STAGE;

    printf("$$$ EX16-CFG case=A rounds_per_variant=%lu block=%u rec_total=%u "
           "note='variant carried in record type bit; interleaved per %u-block'\n",
           (unsigned long)rounds, CONFIG_ZC_BLOCK,
           REC_HDR_LEN + CONFIG_ZC_REC_BODY, CONFIG_ZC_BLOCK);

    ex16_caseA_reset();
    g_svc_main.on_rec = caseA_on_rec;

    if (!zc_svc_listen(&g_svc_main, PORT_SINK)) {
        return false;
    }
    if (!zc_cli_open(&g_cli_main, "A", 5000)) {
        return false;
    }
    zc_heap_line("case-A begin");

    /* ---- 阶段一：交错计时主测量 ---- */
    if (!agen_run_phase(rounds * 2, AM_AUTO, "A-timing-interleaved", 60000)) {
        return false;
    }

    /* 统计快照（END-ACK 后接收路径静止，读数安全） */
    zc_sampler_t *scopy = SMP_COPY, *szc = SMP_ZC;
    uint32_t ncc = s_n_contig_copy, ncz = s_n_contig_zc;
    uint32_t nsc = s_n_span_copy, nsz = s_n_span_zc;
    int64_t span_us = s_span_extra_us;
    uint32_t seen = ncc + ncz + nsc + nsz;

    if (seen != rounds * 2 || s_seq_expect != rounds * 2) {
        printf("$$$ EXFAIL reason=A_count seen=%lu seq=%lu want=%lu\n",
               (unsigned long)seen, (unsigned long)s_seq_expect,
               (unsigned long)(rounds * 2));
        return false;
    }

    zc_smp_print("A-copy-stage-parse", scopy);
    zc_smp_print("A-zc-inplace-parse", szc);

    long long cm = (long long)zc_smp_med(scopy), cp = (long long)zc_smp_p95(scopy);
    long long zm = (long long)zc_smp_med(szc), zp = (long long)zc_smp_p95(szc);
    zc_print_pair_result("A", "rx_parse_per_record", cm, cp, zm, zp, scopy->n,
                         szc->n);
    printf("EX16-STAGE name=A-spans contig_copy=%lu contig_zc=%lu span_copy=%lu "
           "span_zc=%lu span_extra_us_total=%lld note='spans excluded from pair "
           "stats'\n",
           (unsigned long)ncc, (unsigned long)ncz, (unsigned long)nsc,
           (unsigned long)nsz, (long long)span_us);

    /* ---- 阶段二：栈峰值探针（顺序固定 ZC→COPY；HWM 单调性见 README） ---- */
    if (!agen_run_phase(200, AM_FORCE_ZC, "A-stack-probe-zc", 30000)) {
        return false;
    }
    int hwm_zc = zc_tcpip_hwm();
    if (!agen_run_phase(200, AM_FORCE_COPY_STACK, "A-stack-probe-copy", 30000)) {
        return false;
    }
    int hwm_copy = zc_tcpip_hwm();

    long long addr_delta =
        (s_spmin_zc && s_spmin_copy) ? (long long)(s_spmin_zc - s_spmin_copy) : -1;
    printf("$$$ EX16-RESULT case=A kind=stack hwm_after_zc=%d "
           "hwm_after_copy=%d frame_addr_delta_bytes=%lld "
           "stage_buf_bytes=%d note='addr delta = real extra frame depth of "
           "copy-route local staging; HWM monotonic, order fixed zc-first'\n",
           hwm_zc, hwm_copy, addr_delta,
           REC_HDR_LEN + CONFIG_ZC_REC_BODY);

    zc_heap_line("case-A end");
    return !g_fail;
}
