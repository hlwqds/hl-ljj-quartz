/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * 案例 D —— 流式校验零落地（边收边算 Fletcher32 vs 收完落地整包再算）
 *
 * 两种策略对同一条 L 字节模式流（L = CONFIG_ZC_D_ARENA_BYTES，默认 128KiB）：
 *   STREAM：recv 路径里直接喂 Fletcher32（ex06 方法学），不落地任何 payload，
 *           内存驻留只有当前记录；校验成本融合进收包热路径。
 *   LAND  ：payload 全部落进静态 arena（前向预留整块缓冲），收完在缓冲上做
 *           一遍计时 sweep。内存峰值多出整个 arena；校验是第二遍访问。
 *
 * 数字成对来自同一开机的交错流序列（LAND→STREAM→…×PASSES），阶段间以
 * END(seq=握手码) 闭环同步：握手码携带【下一阶段的模式与长度】，回 ACK 后
 * 才允许开始新流——杜绝"发完≠收全"竞态。
 */
#include <string.h>

#include "esp_timer.h"

#include "lwip/tcp.h"

#include "zc_priv.h"

#if CONFIG_ZC_CASE == 4

#define D_CHUNK_PAYLOAD 1360u /* 单块载荷：恰好在单段 MSS 内 */

/* 只在 case4 构建里存在的落地缓冲（其他构建零 RAM 开销） */
static uint8_t s_d_arena[CONFIG_ZC_D_ARENA_BYTES];

typedef struct
{
    bool stream_mode;      /* 当前接收策略 */
    uint32_t stream_len;   /* 本流期望字节数 */
    uint32_t accum;        /* 已收字节 */
    uint32_t expect_chunk; /* 块序连续性 */
    zc_f32_t f32;          /* 流式的在线累加器 */
    int64_t feed_us;       /* 流式喂和累计 */
} dstage_t;

static dstage_t s_ds; /* 仅 tcpip 线程读写；volatile 会传染 f32 指针 */

static uint32_t s_golden;
static bool s_have_golden;

/* 每完成一个流的归档结果（编排任务最后汇总） */
#define D_MAX_STREAMS 12
typedef struct
{
    bool ok;
    bool was_stream;
    uint32_t bytes;
    int64_t checksum_us_total; /* stream=feed 累计 / land=sweep 一次 */
    uint32_t got;
} dres_t;

static dres_t s_res[D_MAX_STREAMS];
static unsigned s_n_done;

void ex16_caseD_reset(void)
{
    memset((void *)&s_ds, 0, sizeof(s_ds));
    s_n_done = 0;
    memset(s_res, 0, sizeof(s_res));
}

/* golden：无落地预计算同样模式流的 Fletcher32 */
static void caseD_compute_golden(uint32_t len)
{
    zc_f32_t f;
    zc_f32_init(&f);
    static uint8_t blk[1024];
    for (uint32_t off = 0; off < len; off += sizeof(blk)) {
        size_t n = (len - off < sizeof(blk)) ? (len - off) : sizeof(blk);
        for (size_t i = 0; i < n; i++) {
            blk[i] = zc_pat_byte(off + (uint32_t)i);
        }
        zc_f32_feed_le(&f, blk, n & ~(size_t)1); /* 偶数对齐喂入 */
    }
    s_golden = zc_f32_final(&f);
    s_have_golden = true;
    printf("$$$ EX16-DIGEST item=d-golden len=%lu value=%08lx\n",
           (unsigned long)len, (unsigned long)s_golden);
}

static void caseD_prime_next(bool stream, uint32_t len)
{
    s_ds.stream_mode = stream;
    s_ds.stream_len = len;
    s_ds.accum = 0;
    s_ds.expect_chunk = 0;
    s_ds.feed_us = 0;
    if (stream) {
        zc_f32_init(&s_ds.f32);
        memset(s_d_arena, 0xCC, sizeof(s_d_arena)); /* 验证"未写区"用 */
    }
}

/* 完成一个流的对账与归档（零长度占位流直接通过，不做 digest） */
static void caseD_finalize(void)
{
    if (s_n_done >= D_MAX_STREAMS) {
        return;
    }
    dres_t *r = &s_res[s_n_done++];
    r->was_stream = s_ds.stream_mode;
    r->bytes = s_ds.stream_len;
    r->got = s_ds.accum;
    r->ok = (s_ds.accum == s_ds.stream_len);

    if (r->bytes == 0) { /* 引导/收尾占位：无内容可校验 */
        printf("EX16-STAGE name=D-finalize mode=%s bytes=0 ok=%d role=marker\n",
               r->was_stream ? "STREAM" : "LAND", (int)r->ok);
        return;
    }

    if (!s_ds.stream_mode) {
        /* 落地版：现在才在校验和维度访问数据（第二遍） */
        zc_f32_t f;
        zc_f32_init(&f);
        int64_t t0 = esp_timer_get_time();
        for (uint32_t off = 0; off < s_ds.stream_len; off += 2048) {
            size_t n = (s_ds.stream_len - off < 2048) ? (s_ds.stream_len - off)
                                                      : 2048;
            zc_f32_feed_le(&f, s_d_arena + off, n & ~(size_t)1);
        }
        uint32_t v = zc_f32_final(&f);
        r->checksum_us_total = esp_timer_get_time() - t0;
        if (v != s_golden || !r->ok) {
            printf("$$$ EXFAIL reason=D_land_digest v=%08lx want=%08lx\n",
                   (unsigned long)v, (unsigned long)s_golden);
            r->ok = false;
            zc_fail("D_land_digest");
        }
    } else {
        uint32_t v = zc_f32_final(&s_ds.f32);
        r->checksum_us_total = s_ds.feed_us;
        if (v != s_golden || !r->ok) {
            printf("$$$ EXFAIL reason=D_stream_digest v=%08lx want=%08lx\n",
                   (unsigned long)v, (unsigned long)s_golden);
            r->ok = false;
            zc_fail("D_stream_digest");
        }
    }
    printf("EX16-STAGE name=D-finalize mode=%s bytes=%lu us=%lld ok=%d\n",
           r->was_stream ? "STREAM" : "LAND", (unsigned long)r->bytes,
           (long long)r->checksum_us_total, (int)r->ok);
}

static bool cased_on_rec(zc_sink_t *k, const uint8_t *rec, uint16_t tot,
                         bool span)
{
    (void)span;
    uint16_t t7 = zc_rd16(rec + 4) & 0x7FFFu;

    if (t7 == RT_CTRL_END) {
        uint32_t code = zc_rd32(rec + 6);
        /* 先落账本流，再用握手码给下一流布景，最后回 ACK */
        caseD_finalize();
        caseD_prime_next(zc_end_mode(code) != 0, zc_end_len(code));
        return zc_engine_handle_end(k, rec, tot);
    }

    if (t7 != RT_CHUNK_D) {
        return true;
    }

    uint16_t plen = zc_rd16(rec + 10);
    uint32_t seq = zc_rd32(rec + 6);
    const uint8_t *pl = rec + REC_HDR_LEN;

    if (seq != s_ds.expect_chunk) {
        printf("$$$ EXFAIL reason=D_seq got=%lu want=%lu\n", (unsigned long)seq,
               (unsigned long)s_ds.expect_chunk);
        zc_fail("D_chunk_seq");
        return false;
    }
    s_ds.expect_chunk++;

    { /* 头与帧完整性照常对账（两变体共同开销，不影响配对差值口径） */
        const char *why;
        if (zc_check_rec(rec, tot, NULL, &why) == 0xFFFF) {
            printf("$$$ EXFAIL reason=D_frame why=%s\n", why);
            zc_fail("D_bad_frame");
            return false;
        }
    }

    if (s_ds.stream_mode) {
        /* —— 流式：校验逻辑长在收包热路径上 —— */
        int64_t t0 = esp_timer_get_time();
        zc_f32_feed_le(&s_ds.f32, pl, plen & ~(u16_t)1);
        s_ds.feed_us += esp_timer_get_time() - t0;
    } else {
        /* —— 落地版：只搬运，校验延迟到 finalize —— */
        if ((uint32_t)plen > s_ds.stream_len - s_ds.accum) {
            zc_fail("D_overflow");
            return false;
        }
        memcpy(s_d_arena + s_ds.accum, pl, plen);
    }

    /* 每 16 块抽一块做全内容比对（采样级 digest 强证据） */
    if ((seq & 15u) == 0) {
        for (uint16_t i = 0; i < plen; i++) {
            if (pl[i] != zc_pat_byte((uint32_t)(seq * D_CHUNK_PAYLOAD) + i)) {
                zc_fail("D_content");
                printf("$$$ EXFAIL reason=D_content chunk=%lu\n", (unsigned long)seq);
                return false;
            }
        }
    }

    s_ds.accum += plen;
    if (s_ds.accum > s_ds.stream_len) {
        zc_fail("D_overrun");
        return false;
    }
    return true;
}

/* ---------------- 发送端 ---------------- */

typedef struct
{
    uint32_t planned_chunks;
    uint32_t emitted;
} dgen_t;

static dgen_t s_dg;
static uint8_t s_d_tx[REC_HDR_LEN + D_CHUNK_PAYLOAD];

static void dgen_build_chunk(uint8_t *buf, uint32_t idx, uint16_t *out_plen)
{
    uint32_t remaining =
        (uint32_t)CONFIG_ZC_D_ARENA_BYTES -
        idx * (uint32_t)D_CHUNK_PAYLOAD;
    uint16_t plen =
        remaining >= D_CHUNK_PAYLOAD ? (uint16_t)D_CHUNK_PAYLOAD : (uint16_t)remaining;
    static uint8_t pl[D_CHUNK_PAYLOAD];
    for (uint16_t i = 0; i < plen; i++) {
        pl[i] = zc_pat_byte(idx * (uint32_t)D_CHUNK_PAYLOAD + i);
    }
    zc_build_rec(buf, RT_CHUNK_D, idx, pl, plen);
    *out_plen = plen;
}

static void dgen_on_sent(void *uctx, struct tcp_pcb *pcb, u16_t len)
{
    (void)uctx;
    (void)len;
    (void)pcb;
    while (s_dg.emitted < s_dg.planned_chunks && !g_fail) {
        uint16_t plen;
        dgen_build_chunk(s_d_tx, s_dg.emitted, &plen);
        u16_t tot = (u16_t)(REC_HDR_LEN + plen);
        err_t e = zc_cli_post(&g_cli_main, s_d_tx, tot, TCP_WRITE_FLAG_COPY);
        if (e == ERR_INPROGRESS) {
            return;
        }
        if (e != ERR_OK) {
            zc_fail("D_write");
            return;
        }
        s_dg.emitted++;
        if ((s_dg.emitted & 15u) == 0) {
            printf("EX16-PROG case=D emitted=%lu/%lu sink_accum=%lu\n",
                   (unsigned long)s_dg.emitted, (unsigned long)s_dg.planned_chunks,
                   (unsigned long)s_ds.accum);
        }
    }
}

static void dgen_kick_inner(void *arg)
{
    (void)arg;
    dgen_on_sent(NULL, NULL, 0);
}

/* 泵到计划量发完为止（编排任务侧轮询；恢复由 tcp_sent 驱动） */
static bool dgen_pump(int64_t timeout_ms)
{
    int64_t dl = esp_timer_get_time() + timeout_ms * 1000LL;
    while (s_dg.emitted < s_dg.planned_chunks) {
        if (g_fail || !g_cli_main.pcb || esp_timer_get_time() > dl) {
            zc_fail("D_pump_timeout");
            return false;
        }
        vTaskDelay(pdMS_TO_TICKS(10));
    }
    return true;
}

bool ex16_caseD_run(void)
{
    if (g_case != 4) {
        return true;
    }
    const uint32_t len = (uint32_t)CONFIG_ZC_D_ARENA_BYTES;
    const unsigned pairs = 3; /* LAND/STREAM 各 3 次，共 6 个流（含引导外的全部） */

    printf("$$$ EX16-CFG case=D stream_len=%u chunk_payload=%u passes_per_variant=%u "
           "note='END handshake code carries NEXT stage mode+len'\n", (unsigned)len,
           (unsigned)D_CHUNK_PAYLOAD, pairs);

    ex16_caseD_reset();
    g_svc_main.on_rec = cased_on_rec;
    if (!zc_svc_listen(&g_svc_main, PORT_SINK)) {
        return false;
    }
    if (!zc_cli_open(&g_cli_main, "D", 5000)) {
        return false;
    }
    caseD_compute_golden(len);
    caseD_prime_next(true, 0); /* 占位：第一个 END 会真正布置 LAND 流 */
    zc_heap_line("case-D begin");

    /*
     * 阶段序列：[引导 END(LAND)] + (LAND 传输 + END(STREAM))×pairs + (STREAM 传输)
     * 共 2*pairs 个数据流。每步之间用 ACK 握手闭环。
     */
    uint32_t chunks =
        (len + D_CHUNK_PAYLOAD - 1) / D_CHUNK_PAYLOAD;

    /* 引导：宣布第一个流为 LAND */
    if (!zc_cli_send_ack_wait(&g_cli_main, RT_CTRL_END, zc_end_pack(0, len),
                              NULL, 0, 5000)) {
        return false;
    }
    /* 首个 END 也触发了一次空 finalize——重置账本指针 */
    s_n_done = 0;
    memset(s_res, 0, sizeof(s_res));

    for (unsigned p = 0; p < pairs; p++) {
        /* LAND 流 */
        s_dg.planned_chunks = chunks;
        s_dg.emitted = 0;
        g_cli_main.on_sent = dgen_on_sent;
        printf("== EX16-PHASE name=D-transfer kind=LAND round=%u ==\n", p);
        if (!zc_run_in_tcpip(dgen_kick_inner, NULL, 5000)) {
            return false;
        }
        if (!dgen_pump(60000)) {
            return false;
        }
        /* 泵完成后由本端发 END（握手码宣布下一流为 STREAM）；sink 收到即落账
         * + 布景 + 回 ACK —— ACK 到手时账已落定，天然闭环 */
        if (!zc_cli_send_ack_wait(&g_cli_main, RT_CTRL_END, zc_end_pack(1, len),
                                  NULL, 0, 10000)) {
            zc_fail("D_land_end_ack");
            return false;
        }

        /* STREAM 流 */
        s_dg.emitted = 0;
        printf("== EX16-PHASE name=D-transfer kind=STREAM round=%u ==\n", p);
        if (!zc_run_in_tcpip(dgen_kick_inner, NULL, 5000)) {
            return false;
        }
        if (!dgen_pump(60000)) {
            return false;
        }
        if (p + 1 < pairs) {
            /* 下一轮 LAND（本 END 同时落定本轮 STREAM 账） */
            if (!zc_cli_send_ack_wait(&g_cli_main, RT_CTRL_END,
                                      zc_end_pack(0, len), NULL, 0, 10000)) {
                zc_fail("D_stream_end_ack");
                return false;
            }
        } else {
            /* 收尾占位流：仅为落定最后一个 STREAM 账 */
            if (!zc_cli_send_ack_wait(&g_cli_main, RT_CTRL_END,
                                      zc_end_pack(0, 0), NULL, 0, 10000)) {
                zc_fail("D_final_end_ack");
                return false;
            }
        }
    }

    /* 汇总成对数字（按变体聚合，跨轮取中位） */
    long long stream_us[8], land_us[8];
    unsigned ns = 0, nl = 0;
    for (unsigned i = 0; i < s_n_done && i < D_MAX_STREAMS; i++) {
        if (!s_res[i].ok || s_res[i].bytes == 0) {
            continue; /* 空的收尾占位流不计 */
        }
        if (s_res[i].was_stream && ns < 8) {
            stream_us[ns++] = (long long)s_res[i].checksum_us_total;
        } else if (!s_res[i].was_stream && nl < 8) {
            land_us[nl++] = (long long)s_res[i].checksum_us_total;
        }
    }

    printf("EX16-STAGE name=D-mem land_residency_bytes=%u stream_residency_bytes<=~%u "
           "(single record spill)\n", (unsigned)sizeof(s_d_arena),
           REC_HDR_LEN + D_CHUNK_PAYLOAD);
    printf("$$$ EX16-RESULT case=D kind=memory peak_extra_bytes_land=%u "
           "peak_extra_bytes_stream=0 ratio_numerator=arena\n",
           (unsigned)sizeof(s_d_arena));
    for (unsigned i = 0; i < nl; i++) {
        printf("$$$ EX16-SAMPLE who=D-land-checksum-%u us=%lld bytes=%u\n", i,
               land_us[i], (unsigned)len);
    }
    for (unsigned i = 0; i < ns; i++) {
        printf("$$$ EX16-SAMPLE who=D-stream-checksum-%u us=%lld bytes=%u\n", i,
               stream_us[i], (unsigned)len);
    }
    if (nl && ns) {
        /* 中位（小样本直取排序中值） */
        for (unsigned a = 0; a < nl; a++)
            for (unsigned b = a + 1; b < nl; b++)
                if (land_us[b] < land_us[a]) {
                    long long t = land_us[a];
                    land_us[a] = land_us[b];
                    land_us[b] = t;
                }
        for (unsigned a = 0; a < ns; a++)
            for (unsigned b = a + 1; b < ns; b++)
                if (stream_us[b] < stream_us[a]) {
                    long long t = stream_us[a];
                    stream_us[a] = stream_us[b];
                    stream_us[b] = t;
                }
        long long lm = land_us[nl / 2], sm = stream_us[ns / 2];
        printf("$$$ EX16-RESULT case=D kind=pair metric=fletcher32_total_us "
               "copy_med_us=%lld land=n/a zc_med_us=%lld land_sweep_med=%lld "
               "n_land=%u n_stream=%u note='zc med=feed sum fused into rx; "
               "copy med=deferred sweep'\n",
               lm, sm, lm, nl, ns);
    }

    zc_heap_line("case-D end");
    return !g_fail;
}

#else /* 非 case4 构建：提供桩函数避免链接缺口 */

bool ex16_caseD_run(void) { return g_case != 4; }

#endif /* CONFIG_ZC_CASE == 4 */
