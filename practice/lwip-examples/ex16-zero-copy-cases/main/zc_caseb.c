/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * 案例 B —— TX 分段提交（头/体分离 write+MORE vs 用户侧先拼大缓冲再整体 write）
 *
 * 拷贝版（传统写法）：用户先把应用头和体拼进一个连续大缓冲，再一次 tcp_write。
 * 零拷贝版：头、体各自直接从自己的存储 tcp_write（中间用 TCP_WRITE_FLAG_MORE
 * 连接），省掉的是【用户侧那次拼接 memcpy】。
 *
 * 边界（必须讲清）：IDF 硬编码 LWIP_NETIF_TX_SINGLE_PBUF=1 使协议栈内部的 COPY
 * 仍在——本案例量化的只是"少掉的那一跳"，不是协议栈拷贝的消失。见案例 E 与 README。
 *
 * 线格式：整个消息仍是一条完整记录（16B wire 头 + 应用头 CONFIG_ZC_B_HDR +
 * 体 CONFIG_ZC_B_BODY）。所有消息内容恒定 => 两变体上线字节流逐位相同，
 * 收端以 learned-once 校验和一致性对账；seq 维度在本案例不承载信息（写入
 * 顺序即序号，收端只认内容）。计时只包住【用户侧动作 + tcp_write 调用】，
 * 批末统一 tcp_output 冲刷不计入——两边对称。
 */
#include <string.h>

#include "esp_timer.h"

#include "zc_priv.h"

#define B_MSG_PAYLOAD (CONFIG_ZC_B_HDR + CONFIG_ZC_B_BODY)
#define B_WIRE_TOT (REC_HDR_LEN + B_MSG_PAYLOAD)

/* 源数据区：应用头模板 / 体模板 */
static uint8_t s_b_hdr[CONFIG_ZC_B_HDR];
static uint8_t s_b_body[CONFIG_ZC_B_BODY];

/* 完整线帧的常量模板（rec 头 + 应用头部分），零拷贝版的 write#1 直接引用它 */
static uint8_t s_b_tpl_head[REC_HDR_LEN + CONFIG_ZC_B_HDR];

/* 拷贝版的用户侧拼接缓冲（必须能装下整条线帧：曾按 payload 尺寸声明
 * 导致 18B 越界踩坏相邻静态区——第二批消息起头模板变垃圾，见 README 排障） */
static uint8_t s_b_stage[B_WIRE_TOT];

typedef struct
{
    uint32_t planned_total;
    uint32_t emitted;
    bool window_dirty; /* 本轮是否写过（批末冲刷判据） */
} bgen_t;

static bgen_t s_bg;

/* 共享池：pool[0]=拷贝版提交总账 pool[1]=零拷贝版提交总账
 * pool[2]=拷贝版中"用户侧拼接 memcpy"分项（被省掉的那一跳的本体） */
#define SMP_COPY (&g_smp_pool[0])
#define SMP_ZC   (&g_smp_pool[1])
static zc_sampler_t s_smp_concat; /* 仅 caseB 构建；DRAM 预算见 README */
static uint32_t s_n_copy, s_n_zc;

void ex16_caseB_reset(void)
{
    memset(&s_bg, 0, sizeof(s_bg));
    zc_smp_reset(SMP_COPY);
    zc_smp_reset(SMP_ZC);
    zc_smp_reset(&s_smp_concat);
    s_n_copy = s_n_zc = 0;

    /* 填充源数据与模板（一次性；恒定内容是收端对账的前提） */
    for (int i = 0; i < CONFIG_ZC_B_HDR; i++) {
        s_b_hdr[i] = zc_pat_byte((uint32_t)(i * 7 + 3));
    }
    for (int i = 0; i < CONFIG_ZC_B_BODY; i++) {
        s_b_body[i] = zc_pat_byte((uint32_t)(100000u + i));
    }
    /* 先拼一次得到全帧（也用作常量校验基准） */
    uint8_t full[B_WIRE_TOT];
    memcpy(full + REC_HDR_LEN, s_b_hdr, CONFIG_ZC_B_HDR);
    memcpy(full + REC_HDR_LEN + CONFIG_ZC_B_HDR, s_b_body, CONFIG_ZC_B_BODY);
    uint16_t plen = (uint16_t)B_MSG_PAYLOAD;
    zc_wr32(full + 0, REC_MAGIC);
    zc_wr16(full + 4, RT_DATA_B);
    zc_wr32(full + 6, 0);
    zc_wr16(full + 10, plen);
    full[12] = full[13] = 0;
    zc_wr16(full + 12, zc_hdr_sum(full));
    zc_wr32(full + 14, zc_body_xsum(full + REC_HDR_LEN, plen));
    memcpy(s_b_tpl_head, full, REC_HDR_LEN + CONFIG_ZC_B_HDR);
}

/* ---------------- 汇点 ---------------- */

static uint32_t s_sink_count;
static uint32_t s_sink_xsum_learned;
static bool s_sink_learned;

static bool caseB_on_rec(zc_sink_t *k, const uint8_t *rec, uint16_t tot,
                         bool span)
{
    (void)span;
    uint16_t t7 = zc_rd16(rec + 4) & 0x7FFFu;
    if (t7 == RT_CTRL_END) {
        return zc_engine_handle_end(k, rec, tot);
    }
    if (t7 != RT_DATA_B) {
        return true;
    }
    uint32_t seq;
    const char *why;
    uint16_t type = zc_check_rec(rec, tot, &seq, &why);
    if (type == 0xFFFF) {
        printf("$$$ EXFAIL reason=B_bad_rec why=%s\n", why);
        zc_fail("B_bad_record");
        return false;
    }
    uint32_t xs = zc_rd32(rec + 14);
    if (!s_sink_learned) {
        s_sink_learned = true;
        s_sink_xsum_learned = xs;
    } else if (xs != s_sink_xsum_learned ||
               zc_rd16(rec + 10) != (uint16_t)B_MSG_PAYLOAD) {
        printf("$$$ EXFAIL reason=B_content_mismatch\n");
        zc_fail("B_mismatch");
        return false;
    }
    s_sink_count++;
    return true;
}

/* ---------------- 发送端形状引擎 ----------------
 * 每条消息（无论形状）的上线字节都相同：[rec头16 | 应用头H | 体B]。
 *   copy 形状 = 用户把三段全部 memcpy 进 stage 后整体 write（计时含拼接）；
 *   zc   形状 = 直接引用 tpl_head(16+H) 与 body 各自 write(MORE)，无拼接。
 */

static bool bgen_fill_once(zc_cli_t *c)
{
    while (s_bg.emitted < s_bg.planned_total) {
        if ((s_bg.emitted % (CONFIG_ZC_BLOCK * 4)) == 0 && s_bg.emitted > 0) {
            static uint32_t last_prog;
            if (last_prog != s_bg.emitted) {
                last_prog = s_bg.emitted;
                printf("EX16-PROG case=B emitted=%lu/%lu\n",
                       (unsigned long)s_bg.emitted, (unsigned long)s_bg.planned_total);
            }
        }
        bool want_zc = (s_bg.emitted / CONFIG_ZC_BLOCK) % 2 == 1;

        u16_t room = tcp_sndbuf(c->pcb);
        if (room < B_WIRE_TOT) {
            if (s_bg.window_dirty) {
                tcp_output(c->pcb); /* 批末冲刷（未计入任何采样） */
                s_bg.window_dirty = false;
            }
            return false; /* 等 tcp_sent 唤醒 */
        }

        if (want_zc) {
            int64_t t0 = esp_timer_get_time();
            err_t e1 = tcp_write(c->pcb, s_b_tpl_head,
                                 (u16_t)(REC_HDR_LEN + CONFIG_ZC_B_HDR),
                                 TCP_WRITE_FLAG_MORE);
            err_t e2 = tcp_write(c->pcb, s_b_body, (u16_t)CONFIG_ZC_B_BODY,
                                 TCP_WRITE_FLAG_COPY);
            int64_t dt = esp_timer_get_time() - t0;
            if (e1 != ERR_OK || e2 != ERR_OK) {
                printf("$$$ EXFAIL reason=B_wz e1=%d e2=%d\n", (int)e1, (int)e2);
                g_fail = true;
                return true;
            }
            s_n_zc++;
            zc_smp_push(SMP_ZC, dt);
        } else {
            int64_t t0 = esp_timer_get_time();
            memcpy(s_b_stage, s_b_tpl_head,
                   REC_HDR_LEN + CONFIG_ZC_B_HDR);
            memcpy(s_b_stage + REC_HDR_LEN + CONFIG_ZC_B_HDR, s_b_body,
                   CONFIG_ZC_B_BODY);
            int64_t t1 = esp_timer_get_time();
            err_t e = tcp_write(c->pcb, s_b_stage, (u16_t)B_WIRE_TOT,
                                TCP_WRITE_FLAG_COPY);
            int64_t dt = esp_timer_get_time() - t0;
            if (e != ERR_OK) {
                printf("$$$ EXFAIL reason=B_wc e=%d\n", (int)e);
                g_fail = true;
                return true;
            }
            s_n_copy++;
            zc_smp_push(SMP_COPY, dt);
            zc_smp_push(&s_smp_concat, t1 - t0); /* 被省掉的拼接跳，单独记账 */
        }
        s_bg.window_dirty = true;
        s_bg.emitted++;
    }
    if (s_bg.window_dirty) {
        tcp_output(c->pcb);
        s_bg.window_dirty = false;
    }
    return true;
}

static void bgen_on_sent(void *uctx, struct tcp_pcb *pcb, u16_t len)
{
    (void)uctx;
    (void)len;
    (void)pcb;
    bgen_fill_once(&g_cli_main);
}

static void bgen_kick_inner(void *arg)
{
    (void)arg;
    bgen_fill_once(&g_cli_main);
}

static bool bgen_run_phase(uint32_t total_msgs, const char *name,
                           int64_t timeout_ms)
{
    s_bg.planned_total = total_msgs;
    s_bg.emitted = 0;
    s_bg.window_dirty = false;
    g_svc_main.k.end_seen = false;
    g_cli_main.on_sent = bgen_on_sent;

    printf("== EX16-PHASE name=%s ==\n", name);
    if (!zc_run_in_tcpip(bgen_kick_inner, NULL, 5000)) {
        return false;
    }
    int64_t deadline = esp_timer_get_time() + timeout_ms * 1000LL;
    while (s_bg.emitted < s_bg.planned_total) {
        if (g_fail || !g_cli_main.pcb || esp_timer_get_time() > deadline) {
            zc_fail("B_phase_timeout");
            return false;
        }
        vTaskDelay(pdMS_TO_TICKS(10));
    }
    /* 泵灌完计划量后由编排任务发 END 做闭环握手 */
    if (!zc_cli_send_ack_wait(&g_cli_main, RT_CTRL_END, zc_end_pack(0, 0),
                              NULL, 0, 5000)) {
        return false;
    }
    g_svc_main.k.end_seen = true;
    return true;
}

bool ex16_caseB_run(void)
{
    if (g_case != 2) {
        return true;
    }
    const uint32_t rounds = (uint32_t)CONFIG_ZC_ROUNDS_PER_STAGE;

    printf("$$$ EX16-CFG case=B rounds_per_variant=%lu block=%u "
           "msg_wire_total=%u hdr=%u body=%u note='quantifies USER-side concat "
           "hop only; lwIP-internal COPY remains (see case E)'\n",
           (unsigned long)rounds, CONFIG_ZC_BLOCK, B_WIRE_TOT,
           CONFIG_ZC_B_HDR, CONFIG_ZC_B_BODY);

    ex16_caseB_reset();
    s_sink_count = 0;
    s_sink_learned = false;
    g_svc_main.on_rec = caseB_on_rec;

    if (!zc_svc_listen(&g_svc_main, PORT_SINK)) {
        return false;
    }
    if (!zc_cli_open(&g_cli_main, "B", 5000)) {
        return false;
    }
    zc_heap_line("case-B begin");

    if (!bgen_run_phase(rounds * 2, "B-timing-interleaved", 60000)) {
        return false;
    }

    uint32_t seen = s_sink_count;
    if (seen != rounds * 2 || s_n_copy != rounds || s_n_zc != rounds) {
        printf("$$$ EXFAIL reason=B_count sink=%lu copy=%lu zc=%lu want=%lu\n",
               (unsigned long)seen, (unsigned long)s_n_copy,
               (unsigned long)s_n_zc, (unsigned long)(rounds * 2));
        return false;
    }

    zc_sampler_t *scopy = SMP_COPY, *szc = SMP_ZC;
    zc_smp_print("B-copy-stage-concat-write", scopy);
    zc_smp_print("B-zc-two-part-submit", szc);
    zc_smp_print("B-copy-concat-memcpy-only", &s_smp_concat);
    zc_print_pair_result(
        "B", "tx_submit_per_msg", (long long)zc_smp_med(scopy),
        (long long)zc_smp_p95(scopy), (long long)zc_smp_med(szc),
        (long long)zc_smp_p95(szc), scopy->n, szc->n);
    printf("$$$ EX16-RESULT case=B metric=concat_hop decomposition "
           "concat_mean_us=%.2f copy_total_mean_us=%.2f zc_total_mean_us=%.2f "
           "write_call_overhead_us=%.2f\n",
           zc_smp_mean(&s_smp_concat), zc_smp_mean(scopy), zc_smp_mean(szc),
           zc_smp_mean(szc) - (zc_smp_mean(scopy) - zc_smp_mean(&s_smp_concat)));

    printf("EX16-STAGE name=B-boundary saved_hop=user_side_concat_only "
           "stack_internal_copy=still_forced_by_TX_SINGLE_PBUF\n");

    zc_heap_line("case-B end");
    return !g_fail;
}
