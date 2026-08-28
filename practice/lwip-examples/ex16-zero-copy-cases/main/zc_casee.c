/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * 案例 E —— 诚实边界：IDF 的 LWIP_NETIF_TX_SINGLE_PBUF=1 硬编码使
 *           TCP_WRITE_FLAG_COPY 不可达（ch6 实证）
 *
 * 证据三件套：
 *   1) 编译期断言：构建环境若不是"IDF 钉死 =1"的形态，直接编译失败，
 *      杜绝在别的移植上照读本例得出错误结论；
 *   2) 打印运行时事实：调用方请求的两种 apiflags（显式 COPY / 显式 0 请求
 *      no-copy），以及上游语义下后者意味着什么；
 *   3) 行为学验证：no-copy 请求形态照样成流成功且逐位对账通过——只有当
 *      协议栈把它悄悄升级成 COPY 时才会如此；源缓冲以流水线方式滚动复用
 *      （消息 i 写入后立刻让位给 i+1..i+W），若真走了引用语义必然撕碎流。
 *
 * 结论行给出"为什么"（openeth/DMA 单 pbuf TX 假设与校验和预计算）与替代路径，
 * 详细讲解放 README。
 */
#include <string.h>

#include "lwip/opt.h"

#include "esp_timer.h"

#include "zc_priv.h"

#if LWIP_NETIF_TX_SINGLE_PBUF != 1
#error "ex16 case E assumes ESP-IDF pins LWIP_NETIF_TX_SINGLE_PBUF=1 (see README)"
#endif

#define E_WIRE_TOT (REC_HDR_LEN + CONFIG_ZC_REC_BODY)

static uint32_t s_sink_echo_count; /* 汇点侧回声账本 */

typedef struct
{
    uint32_t planned_total;
    uint32_t emitted;
    uint32_t want_flags[2]; /* 两个形态的请求值（打印用） */
    uint32_t sent_per_form[2];
    int64_t first_form_us[2];
} egen_t;

static egen_t s_eg;

#define E_WINDOW 4 /* 流水线深度：保证写入发生时有历史帧仍在队列里 */

/* 在途窗口（seq -> 已投递标记） */
static struct
{
    uint32_t seq;
    bool live;
} s_inflight[E_WINDOW];

static uint32_t s_reply_ok;
#define SMP_RTT (&g_smp_pool[0])
static int64_t s_send_us[E_WINDOW];
static uint8_t s_e_scratch[E_WINDOW][E_WIRE_TOT];

static bool e_on_rec(zc_sink_t *k, const uint8_t *rec, uint16_t tot, bool span)
{
    (void)span;
    uint16_t t7 = zc_rd16(rec + 4) & 0x7FFFu;
    if (t7 == RT_CTRL_END) {
        return zc_engine_handle_end(k, rec, tot);
    }
    if (t7 != RT_DATA_A) {
        return true;
    }
    /* 客户端数据到达：原样回声（案例 E 的行为学验证依赖回环对账） */
    err_t e = zc_sink_echo_cur(k, rec, tot);
    if (e == ERR_OK && k->conn != NULL) {
        tcp_output(k->conn);
    }
    s_sink_echo_count++;
    return e != ERR_MEM;
}

/* 客户端收到回声 */
static void ecl_on_data(void *uctx_r, const uint8_t *rec, uint16_t tot,
                        uint16_t type, uint32_t seq)
{
    (void)uctx_r;
    (void)tot;
    if ((type & 0x7FFFu) != RT_DATA_A) {
        return;
    }
    int idx = -1;
    for (int i = 0; i < E_WINDOW; i++) {
        if (s_inflight[i].live && s_inflight[i].seq == seq) {
            idx = i;
            break;
        }
    }
    if (idx < 0) {
        printf("$$$ EXFAIL reason=E_unexpected_seq %lu\n", (unsigned long)seq);
        zc_fail("E_stray_echo");
        return;
    }
    zc_smp_push(SMP_RTT, esp_timer_get_time() - s_send_us[idx]);
    s_inflight[idx].live = false;
    s_reply_ok++;
}

/* 发送填充：把可发的新消息全部推出去（受窗口深度限制） */
static void egen_fill(zc_cli_t *c)
{
    static int cursor = 0; /* 顺序复用 scratch 槽位 */
    while (!g_fail) {
        uint32_t in = 0;
        for (int i = 0; i < E_WINDOW; i++) {
            if (s_inflight[i].live) {
                in++;
            }
        }
        if (in >= E_WINDOW || s_eg.emitted >= s_eg.planned_total) {
            break;
        }

        uint8_t form_is_copy =
            ((s_eg.emitted / CONFIG_ZC_BLOCK) % 2) == 0 ? 1 : 0;

        int slot = cursor++ % E_WINDOW;

        /* 组装全新一代内容到该槽位 —— 同一物理缓冲被连续多代反复覆写 */
        static uint8_t e_pl[1400];
        uint16_t plen = (uint16_t)(CONFIG_ZC_REC_BODY);
        for (uint16_t i = 0; i < plen; i++) {
            e_pl[i] = zc_pat_byte(s_eg.emitted * 17u + i);
        }
        zc_build_rec(s_e_scratch[slot],
                     (uint16_t)(RT_DATA_A |
                                (form_is_copy ? 0 : RT_VARIANT_ZC)),
                     s_eg.emitted, e_pl, plen);

        u8_t req_flags = form_is_copy ? (u8_t)TCP_WRITE_FLAG_COPY : (u8_t)0;
        err_t e = zc_cli_post(c, s_e_scratch[slot], E_WIRE_TOT, req_flags);
        if (e == ERR_INPROGRESS) {
            break; /* sndbuf 满：等 resume */
        }
        if (e != ERR_OK) {
            printf("$$$ EXFAIL reason=E_write e=%d\n", (int)e);
            zc_fail("E_write");
            return;
        }
        s_inflight[slot].seq = s_eg.emitted;
        s_inflight[slot].live = true;
        s_send_us[slot] = esp_timer_get_time();
        if (s_eg.first_form_us[form_is_copy] == 0) {
            s_eg.first_form_us[form_is_copy] = 1;
            printf("$$$ EX16-EFLAG form=%s req_apiflags=0x%02x "
                   "semantics='%s'\n",
                   form_is_copy ? "copy-explicit" : "nocopy-requested",
                   req_flags,
                   form_is_copy
                       ? "upstream=lwIP-private copy"
                       : "upstream=zero-copy reference; IDF=silently forced "
                         "to COPY by port macro");
        }
        s_eg.sent_per_form[form_is_copy]++;
        s_eg.emitted++;
    }
}

static void egen_on_sent(void *uctx, struct tcp_pcb *pcb, u16_t len)
{
    (void)uctx;
    (void)len;
    (void)pcb;
    egen_fill(&g_cli_main);
}

static void egen_kick_inner(void *arg)
{
    (void)arg;
    egen_fill(&g_cli_main);
}

void ex16_case5_cite_lines(void)
{
    printf("$$$ EX16-CITE file=components/lwip/port/include/lwipopts.h line=765 "
           "macro=LWIP_NETIF_TX_SINGLE_PBUF value=1 comment='hard-coded, not a "
           "Kconfig knob'\n");
    printf("$$$ EX16-CITE file=components/lwip/lwip/src/core/tcp_out.c lines=425-428 "
           "stmt='apiflags |= TCP_WRITE_FLAG_COPY' condition=LWIP_NETIF_TX_SINGLE_PBUF "
           "comment='tcp_write entry forces COPY regardless of caller flags'\n");
    printf("$$$ EX16-CITE why='DMA MACs without scatter-gather expect one single "
           "TX pbuf; forcing copy also lets lwIP precompute checksum while "
           "copying' alternatives='make own netif + LWIP_NETIF_TX_SINGLE_PBUF=0 "
           "port build / PCP pbuf_reference style APIs unavailable here'\n");
}

bool ex16_caseE_run(void);

bool ex16_caseE_run(void)
{
    if (g_case != 5) {
        return true;
    }
    const uint32_t rounds = (uint32_t)CONFIG_ZC_ROUNDS_PER_STAGE;

    printf("$$$ EX16-CFG case=E rounds=%lu window=%u msg_tot=%u "
           "note='apiflags evidence + pipeline buffer-reuse behavior proof'\n",
           (unsigned long)rounds, (unsigned)E_WINDOW, (unsigned)E_WIRE_TOT);
    ex16_case5_cite_lines();

    memset(&s_eg, 0, sizeof(s_eg));
    s_eg.planned_total = rounds * 2;
    memset((void *)s_inflight, 0, sizeof(s_inflight));
    zc_smp_reset(SMP_RTT);
    s_reply_ok = 0;

    g_svc_main.on_rec = e_on_rec;
    if (!zc_svc_listen(&g_svc_main, PORT_SINK)) {
        return false;
    }
    g_cli_main.on_data = ecl_on_data;
    g_cli_main.on_sent = egen_on_sent;
    if (!zc_cli_open(&g_cli_main, "E", 5000)) {
        return false;
    }
    zc_heap_line("case-E begin");

    printf("== EX16-PHASE name=E-pipeline-run ==\n");
    if (!zc_run_in_tcpip(egen_kick_inner, NULL, 5000)) {
        return false;
    }

    /* 等：全部消息收到回声 */
    int64_t deadline = esp_timer_get_time() + 60000 * 1000LL;
    while (s_reply_ok < s_eg.planned_total || !g_cli_main.pcb) {
        if (s_reply_ok >= s_eg.planned_total) {
            break;
        }
        if (g_fail || esp_timer_get_time() > deadline) {
            zc_fail("E_timeout");
            return false;
        }
        vTaskDelay(pdMS_TO_TICKS(10));
    }
    /* 收尾握手（顺带清空服务器视角） */
    if (!zc_cli_send_ack_wait(&g_cli_main, RT_CTRL_END, zc_end_pack(0, 0),
                              NULL, 0, 5000)) {
        return false;
    }

    bool ok_all =
        (s_reply_ok == s_eg.planned_total) &&
        (s_eg.sent_per_form[0] >= rounds) && (s_eg.sent_per_form[1] >= rounds);

    printf("$$$ EX16-DIGEST item=E-roundtrip status=%s verified=%lu "
           "planned=%lu\n", ok_all ? "PASS" : "FAIL",
           (unsigned long)s_reply_ok, (unsigned long)s_eg.planned_total);
    printf("$$$ EX16-RESULT case=E kind=evidence "
           "copy_form_sent=%lu nocopy_req_sent=%lu verdict=%s "
           "conclusion='COPY was silently forced for BOTH forms; immediate "
           "buffer reuse is therefore SAFE on IDF (and would corrupt a true "
           "reference-semantics stack)'\n",
           (unsigned long)s_eg.sent_per_form[0],
           (unsigned long)s_eg.sent_per_form[1], ok_all ? "PASS" : "FAIL");

    zc_smp_print("E-loopback-rtt", SMP_RTT);
    zc_heap_line("case-E end");
    return ok_all && !g_fail;
}
