/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * ex16 公共件：wire 格式 / Fletcher32 / 采样器 / tcpip 桥 / 收帧引擎 /
 * raw 客户端与发送泵骨架。
 */
#include <stdlib.h>
#include <string.h>

#include "esp_heap_caps.h"
#include "esp_timer.h"

#include "lwip/tcpip.h"

#include "zc_priv.h"

/* ---------------- wire ---------------- */

uint16_t zc_hdr_sum(const uint8_t *p12)
{
    uint32_t s = 0;
    for (int i = 0; i < 12; i++) {
        s = s * 31u + p12[i];
    }
    return (uint16_t)(s ^ (s >> 16));
}

uint32_t zc_body_xsum(const uint8_t *p, size_t n)
{
    uint32_t x = 0x811C9DC5u;
    for (size_t i = 0; i < n; i++) {
        x = (x ^ p[i]) * 16777619u;
    }
    return x;
}

uint8_t zc_pat_byte(uint32_t i)
{
    return (uint8_t)(((i)*2654435761u + 0x9E3779B9u) >> 24);
}

uint16_t zc_build_rec(uint8_t *dst, uint16_t type_cap, uint32_t seq,
                      const uint8_t *payload, uint16_t plen)
{
    zc_wr32(dst + 0, REC_MAGIC);
    zc_wr16(dst + 4, type_cap);
    zc_wr32(dst + 6, seq);
    zc_wr16(dst + 10, plen);
    dst[14] = dst[15] = 0;
    zc_wr16(dst + 12, zc_hdr_sum(dst));
    if (payload != NULL && plen > 0) {
        memcpy(dst + REC_HDR_LEN, payload, plen);
    }
    zc_wr32(dst + 14,
            zc_body_xsum(payload, plen)); /* 空载荷循环体不执行，NULL 安全 */
    return (uint16_t)(REC_HDR_LEN + plen);
}

/* 校验一条完整记录。成功返回 type（含变体位），失败返回 0xFFFF 并置原因。 */
uint16_t zc_check_rec(const uint8_t *rec, uint16_t tot, uint32_t *out_seq,
                      const char **why)
{
    if (tot < REC_HDR_LEN) {
        *why = "short";
        return 0xFFFF;
    }
    if (zc_rd32(rec) != REC_MAGIC) {
        *why = "magic";
        return 0xFFFF;
    }
    uint16_t type = zc_rd16(rec + 4);
    uint16_t len = zc_rd16(rec + 10);
    if (len != (uint16_t)(tot - REC_HDR_LEN)) {
        *why = "len";
        return 0xFFFF;
    }
    if (zc_hdr_sum(rec) != zc_rd16(rec + 12)) {
        *why = "hdr_sum";
        return 0xFFFF;
    }
    const uint8_t *pl = rec + REC_HDR_LEN;
    if (len > 0 && zc_body_xsum(pl, len) != zc_rd32(rec + 14)) {
        *why = "body_xsum";
        return 0xFFFF;
    }
    if ((type & 0x7FFFu) != RT_CTRL_ACK && (type & 0x7FFFu) != RT_CTRL_END &&
        (type & 0x7FFFu) > 0x0005u) {
        *why = "type";
        return 0xFFFF;
    }
    if (out_seq != NULL) {
        *out_seq = zc_rd32(rec + 6);
    }
    return type;
}

/* ---------------- Fletcher-32 ---------------- */

void zc_f32_init(zc_f32_t *f)
{
    f->s1 = 0xFFFF;
    f->s2 = 0xFFFF;
    f->nwords_run = 0;
}

static void f32_fold(zc_f32_t *f)
{
    f->s1 = (f->s1 & 0xFFFF) + (f->s1 >> 16);
    f->s2 = (f->s2 & 0xFFFF) + (f->s2 >> 16);
    f->nwords_run = 0;
}

void zc_f32_feed_le(zc_f32_t *f, const uint8_t *p, size_t len)
{
    for (size_t i = 0; i + 1 < len; i += 2) {
        uint16_t w = (uint16_t)p[i] | ((uint16_t)p[i + 1] << 8);
        f->s1 += w;
        f->s2 += f->s1;
        if (++f->nwords_run >= 359) {
            f32_fold(f);
        }
    }
}

uint32_t zc_f32_final(zc_f32_t *f)
{
    while (f->nwords_run) {
        f32_fold(f);
    }
    f->s1 = (f->s1 & 0xFFFF) + (f->s1 >> 16);
    f->s2 = (f->s2 & 0xFFFF) + (f->s2 >> 16);
    return (f->s2 << 16) | f->s1;
}

/* ---------------- 采样器 ---------------- */

zc_sampler_t g_smp_pool[EX16_SMP_POOL_N];

void zc_smp_reset(zc_sampler_t *s) { s->n = 0; }

void zc_smp_push(zc_sampler_t *s, int64_t val)
{
    if (s->n < ZC_SMP_MAX) {
        s->v[s->n++] = val;
    }
}

static int cmp_i64(const void *a, const void *b)
{
    int64_t x = *(const int64_t *)a, y = *(const int64_t *)b;
    return (x > y) - (x < y);
}

void zc_smp_sort(zc_sampler_t *s)
{
    qsort(s->v, s->n, sizeof(int64_t), cmp_i64);
}

int64_t zc_smp_med(zc_sampler_t *s)
{
    if (s->n == 0) {
        return -1;
    }
    return s->v[s->n / 2];
}

int64_t zc_smp_p95(zc_sampler_t *s)
{
    if (s->n == 0) {
        return -1;
    }
    return s->v[((uint64_t)s->n * 95u) / 100u];
}

double zc_smp_mean(zc_sampler_t *s)
{
    if (s->n == 0) {
        return 0.0;
    }
    int64_t sum = 0;
    for (unsigned i = 0; i < s->n; i++) {
        sum += s->v[i];
    }
    return (double)sum / (double)s->n;
}

void zc_smp_print(const char *who, zc_sampler_t *s)
{
    zc_smp_sort(s);
    printf("$$$ EX16-SAMPLE who=%s med_us=%lld p95_us=%lld mean_us=%.2f min=%lld "
           "max=%lld n=%u\n",
           who, (long long)zc_smp_med(s), (long long)zc_smp_p95(s),
           zc_smp_mean(s), s->n ? (long long)s->v[0] : 0,
           s->n ? (long long)s->v[s->n - 1] : 0, s->n);
}

void zc_print_pair_result(const char *cs, const char *metric, long long copy_med,
                          long long copy_p95, long long zc_med, long long zc_p95,
                          unsigned n_copy, unsigned n_zc)
{
    long long saved = 0;
    if (copy_med > 0) {
        saved = (long long)((double)(copy_med - zc_med) * 100.0 / (double)copy_med);
    }
    printf("$$$ EX16-RESULT case=%s metric=%s copy_med_us=%lld copy_p95_us=%lld "
           "zc_med_us=%lld zc_p95_us=%lld n_copy=%u n_zc=%u saved_pct=%lld\n",
           cs, metric, copy_med, copy_p95, zc_med, zc_p95, n_copy, n_zc, saved);
}

/* ---------------- 杂项 ---------------- */

void zc_heap_line(const char *at)
{
    printf("EX16-HEAP at=%s free=%u largest=%u min_ever=%u\n", at,
           (unsigned)heap_caps_get_free_size(MALLOC_CAP_8BIT),
           (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_8BIT),
           (unsigned)heap_caps_get_minimum_free_size(MALLOC_CAP_8BIT));
}

#if CONFIG_FREERTOS_USE_TRACE_FACILITY
#include "freertos/task.h"
int zc_tcpip_hwm(void)
{
    static TaskStatus_t st[24];
    UBaseType_t n = uxTaskGetNumberOfTasks();
    if (n > 24) {
        n = 24;
    }
    n = uxTaskGetSystemState(st, n, NULL);
    for (UBaseType_t i = 0; i < n; i++) {
        if (strncmp(st[i].pcTaskName, "tcpip", configMAX_TASK_NAME_LEN) == 0) {
            return (int)st[i].usStackHighWaterMark;
        }
    }
    return -1;
}
#else
int zc_tcpip_hwm(void) { return -1; }
#endif

volatile bool g_fail;

void zc_fail(const char *reason)
{
    if (!g_fail) { /* 只打首因，避免刷屏 */
        g_fail = true;
        printf("$$$ EXFAIL reason=%s\n", reason);
    }
}

typedef struct
{
    void (*fn)(void *);
    void *arg;
    SemaphoreHandle_t done;
} tc_wrap_t;

static tc_wrap_t s_tcw;

static void tc_trampoline(void *ctx)
{
    tc_wrap_t *w = (tc_wrap_t *)ctx;
    w->fn(w->arg);
    xSemaphoreGive(w->done);
}

bool zc_run_in_tcpip(void (*fn)(void *), void *arg, int64_t wait_ms)
{
    static SemaphoreHandle_t sem;
    if (sem == NULL) {
        sem = xSemaphoreCreateBinary();
    }
    s_tcw.fn = fn;
    s_tcw.arg = arg;
    s_tcw.done = sem;
    if (tcpip_callback(tc_trampoline, &s_tcw) != ERR_OK) {
        zc_fail("tcpip_callback_reject");
        return false;
    }
    if (xSemaphoreTake(sem, pdMS_TO_TICKS(wait_ms)) != pdTRUE) {
        zc_fail("tcpip_callback_timeout");
        return false;
    }
    return true;
}

ip_addr_t g_load_dst;
uint16_t g_load_port;

void zc_load_target_init(void)
{
#if CONFIG_ZC_HOST_REFLECTOR
    IP_ADDR4(&g_load_dst, 10, 0, 2, 2);
    g_load_port = PORT_HOST;
#else
    IP_ADDR4(&g_load_dst, 127, 0, 0, 1);
    g_load_port = PORT_SINK;
#endif
}

/* ==================== 收帧引擎 ==================== */

/*
 * deframe 推进规则：
 *   pend 非空 => 先补齐悬挂记录（跨回调 span，案例 A 的慢路样本来源）；
 *   否则按帧头长度就地切片；不足一整条留下悬挂。
 */
static void svc_deframe(zc_svc_t *svc, const uint8_t *data, uint16_t len)
{
    zc_sink_t *k = &svc->k;
    uint16_t off = 0;

    while (!g_fail) {
        if (k->pend_len > 0) {
            if (k->pend_len < REC_HDR_LEN) {
                uint16_t want = (uint16_t)(REC_HDR_LEN - k->pend_len);
                uint16_t left = (uint16_t)(len - off);
                uint16_t take = want < left ? want : left;
                memcpy(k->pend + k->pend_len, data + off, take);
                k->pend_len += take;
                off += take;
                if (k->pend_len < REC_HDR_LEN) {
                    return; /* 头还没凑齐 */
                }
            }
            uint16_t plen = zc_rd16(k->pend + 10);
            if (plen > REC_HARD_MAX - REC_HDR_LEN) {
                zc_fail("absurd_pend_len");
                return;
            }
            uint16_t ptot = (uint16_t)(REC_HDR_LEN + plen);
            uint16_t need = (uint16_t)(ptot - k->pend_len);
            uint16_t left2 = (uint16_t)(len - off);
            uint16_t take2 = need < left2 ? need : left2;
            memcpy(k->pend + k->pend_len, data + off, take2);
            k->pend_len += take2;
            off += take2;
            if (k->pend_len < ptot) {
                return; /* 仍不完整，继续悬挂 */
            }
            if (!svc->on_rec(k, k->pend, ptot, true)) {
                zc_fail("proto_fail_span");
                return;
            }
            k->pend_len = 0;
            continue;
        }

        uint16_t remain = (uint16_t)(len - off);
        if (remain == 0) {
            return;
        }
        if (remain < REC_HDR_LEN) {
            memcpy(k->pend, data + off, remain);
            k->pend_len = remain;
            return;
        }
        uint16_t flen = zc_rd16(data + off + 10);
        if (flen > REC_HARD_MAX - REC_HDR_LEN) {
            static bool dumped;
            if (!dumped) {
                dumped = true;
                printf("EX16-DBG absurd flen=%u off=%u len=%u bytes:", flen, off,
                       len);
                for (int i = 0; i < 24 && off + i < len; i++) {
                    printf(" %02x", data[off + i]);
                }
                printf("\n");
            }
            zc_fail("absurd_len");
            return;
        }
        uint16_t ftot = (uint16_t)(REC_HDR_LEN + flen);
        if (remain >= ftot) {
            if (!svc->on_rec(k, data + off, ftot, false)) {
                zc_fail("proto_fail_contig");
                return;
            }
            off += ftot;
        } else {
            memcpy(k->pend, data + off, remain);
            k->pend_len = remain;
            return;
        }
    }
}

err_t zc_sink_echo_cur(zc_sink_t *k, const uint8_t *rec, uint16_t tot)
{
    struct tcp_pcb *pcb = k->conn;
    if (pcb == NULL) {
        return ERR_CLSD;
    }
    if (tcp_sndbuf(pcb) < tot) {
        k->awaiting_reply = true;
        return ERR_INPROGRESS;
    }
    return tcp_write(pcb, rec, tot, TCP_WRITE_FLAG_COPY);
}

/* END 记录公共处理：回 ACK（seq 原样回带）、翻 end_seen 门。 */
bool zc_engine_handle_end(zc_sink_t *k, const uint8_t *rec, uint16_t tot)
{
    (void)tot;
    uint8_t ack[REC_HDR_LEN];
    memcpy(ack, rec, REC_HDR_LEN);
    zc_wr16(ack + 4, RT_CTRL_ACK); /* seq 槽位保持原值，形成握手回路 */
    ack[12] = ack[13] = 0;
    zc_wr16(ack + 12, zc_hdr_sum(ack));
    zc_wr32(ack + 14, zc_body_xsum(NULL, 0));
    err_t e = zc_sink_echo_cur(k, ack, REC_HDR_LEN);
    if (e == ERR_OK) {
        tcp_output(k->conn);
    }
    k->end_reason = zc_rd32(rec + 6);
    k->end_seen = true;
    return true;
}

/* 握手码编解码（走 END/ACK 的 seq 字段） */
uint32_t zc_end_pack(uint8_t mode, uint32_t stream_len)
{
    return ((uint32_t)(mode & 0xFFu) << 28) | (stream_len & 0x0FFFFFFFu);
}
uint8_t zc_end_mode(uint32_t code) { return (uint8_t)(code >> 28); }
uint32_t zc_end_len(uint32_t code) { return code & 0x0FFFFFFFu; }

static err_t svc_child_recv(void *arg, struct tcp_pcb *pcb, struct pbuf *p,
                            err_t err)
{
    zc_svc_t *svc = (zc_svc_t *)arg;
    if (p == NULL) {
        svc->k.conn = NULL;
        return ERR_OK;
    }
    (void)err;

    if (svc->k.line_mode) {
        /* case0 命令口：行协议（nc 友好） */
        for (struct pbuf *q = p; q != NULL && !g_fail; q = q->next) {
            const uint8_t *d = (const uint8_t *)q->payload;
            for (uint16_t i = 0; i < q->len; i++) {
                char ch = (char)d[i];
                if (ch == '\n' || ch == '\r') {
                    if (svc->k.linelen > 0) {
                        svc->k.linebuf[svc->k.linelen] = '\0';
                        if (svc->on_line != NULL) {
                            svc->on_line(&svc->k, svc->k.linebuf);
                        }
                        svc->k.linelen = 0;
                    }
                    continue;
                }
                if (svc->k.linelen + 1 < sizeof(svc->k.linebuf)) {
                    svc->k.linebuf[svc->k.linelen++] = ch;
                }
            }
        }
        tcp_recved(pcb, p->tot_len);
        pbuf_free(p);
        return ERR_OK;
    }

    for (struct pbuf *q = p; q != NULL && !g_fail; q = q->next) {
        svc_deframe(svc, (const uint8_t *)q->payload, q->len);
    }

    tcp_recved(pcb, p->tot_len);
    svc->k.awaiting_reply = false; /* 回声欠账只在批量场景可能出现，
                                    * 基准客户端均为串行/流水线有界节奏 */
    pbuf_free(p);
    return ERR_OK;
}

static void svc_child_err(void *arg, err_t err)
{
    zc_svc_t *svc = (zc_svc_t *)arg;
    printf("EX16-SINKERR svc=%s err=%d\n", svc->name, (int)err);
    svc->k.conn = NULL;
}

static err_t svc_accept_cb(void *arg, struct tcp_pcb *newpcb, err_t err)
{
    zc_svc_t *svc = (zc_svc_t *)arg;
    if (err != ERR_OK || newpcb == NULL) {
        return ERR_VAL;
    }
    if (svc->k.conn != NULL) {
        struct tcp_pcb *old = svc->k.conn;
        tcp_arg(old, NULL);
        tcp_recv(old, NULL);
        tcp_err(old, NULL);
        tcp_close(old);
        printf("EX16-SINKNOTE svc=%s replaced stale conn\n", svc->name);
    }
    svc->k.conn = newpcb;
    svc->k.pend_len = 0;
    svc->k.end_seen = false;
    tcp_arg(newpcb, svc);
    tcp_err(newpcb, svc_child_err);
    tcp_recv(newpcb, svc_child_recv);
    return ERR_OK;
}

/* 每个 zc_svc_t 的监听装配参数 */
typedef struct
{
    zc_svc_t *svc;
    uint16_t port;
    bool ok;
} svc_setup_t;

static void svc_setup_inner(void *raw)
{
    svc_setup_t *a = (svc_setup_t *)raw;
    struct tcp_pcb *p = tcp_new_ip_type(IPADDR_TYPE_V4);
    if (p == NULL) {
        a->ok = false;
        return;
    }
    if (tcp_bind(p, IP_ANY_TYPE, a->port) != ERR_OK) {
        tcp_close(p);
        a->ok = false;
        return;
    }
    struct tcp_pcb *l = tcp_listen_with_backlog(p, 8);
    if (l == NULL) {
        tcp_close(p);
        a->ok = false;
        return;
    }
    tcp_arg(l, a->svc);
    tcp_accept(l, svc_accept_cb);
    a->ok = true;
}

bool zc_svc_listen(zc_svc_t *svc, uint16_t lport)
{
    svc->k.owner = svc; /* 引擎助手（END 处理）经回指针取服务上下文 */
    svc_setup_t a = {svc, lport, false};
    if (!zc_run_in_tcpip(svc_setup_inner, &a, 5000) || !a.ok) {
        zc_fail("listen_setup");
        return false;
    }
    return true;
}

zc_svc_t g_svc_main = {.on_rec = NULL, .name = "main"};
zc_svc_t g_svc_cecho = {.on_rec = NULL, .name = "cecho"};
zc_cli_t g_cli_main = {.on_data = NULL, .on_sent = NULL};

/* ==================== raw 客户端 ==================== */

const int g_case = CONFIG_ZC_CASE;

/* --- 接收侧微型定帧器 + ACK 扫描（每次连接独享 pend/scratch） --- */

static volatile uint32_t s_ack_want;
static volatile bool s_ack_hit;

void zc_cli_arm_ack_wait(uint32_t seq)
{
    s_ack_want = seq;
    s_ack_hit = false;
}

bool zc_cli_poll_ctrl_done(void) { return s_ack_hit; }
bool zc_cli_last_ack_ok(void) { return s_ack_hit; }

/*
 * 喂一段字节进定帧器：完整记录 → 检查类型；ACK 匹配等待值则点灯，
 * 其余复制到 scratch 后调 on_data。
 */
static void cli_feed(zc_cli_t *c, const uint8_t *data, uint16_t len)
{
    uint16_t off = 0;
    while (off < len && !g_fail) {
        if (c->pend_len > 0) {
            if (c->pend_len < REC_HDR_LEN) {
                uint16_t want = (uint16_t)(REC_HDR_LEN - c->pend_len);
                uint16_t left = (uint16_t)(len - off);
                uint16_t take = want < left ? want : left;
                memcpy(c->scratch + c->pend_len, data + off, take);
                c->pend_len += take;
                off += take;
                if (c->pend_len < REC_HDR_LEN) {
                    return;
                }
            }
            uint16_t plen = zc_rd16(c->scratch + 10);
            if (plen > REC_HARD_MAX - REC_HDR_LEN) {
                zc_fail("cli_absurd_len");
                return;
            }
            uint16_t ptot = (uint16_t)(REC_HDR_LEN + plen);
            uint16_t need = (uint16_t)(ptot - c->pend_len);
            uint16_t left2 = (uint16_t)(len - off);
            uint16_t take2 = need < left2 ? need : left2;
            memcpy(c->scratch + c->pend_len, data + off, take2);
            c->pend_len += take2;
            off += take2;
            if (c->pend_len < ptot) {
                return;
            }
            uint32_t seq;
            const char *why;
            uint16_t type = zc_check_rec(c->scratch, ptot, &seq, &why);
            if (type == 0xFFFF) {
                printf("$$$ EXFAIL reason=cli_rec_bad why=%s\n", why);
                g_fail = true;
                return;
            }
            if ((type & 0x7FFFu) == RT_CTRL_ACK) {
                if (seq == s_ack_want) {
                    s_ack_hit = true;
                }
            } else if (c->on_data != NULL) {
                c->on_data(c->uctx_r, c->scratch, ptot, type, seq);
            }
            c->pend_len = 0;
            continue;
        }

        uint16_t remain = (uint16_t)(len - off);
        if (remain < REC_HDR_LEN) {
            memcpy(c->scratch, data + off, remain);
            c->pend_len = remain;
            return;
        }
        uint16_t flen = zc_rd16(data + off + 10);
        if (flen > REC_HARD_MAX - REC_HDR_LEN) {
            zc_fail("cli_absurd_len");
            return;
        }
        uint16_t ftot = (uint16_t)(REC_HDR_LEN + flen);
        if (remain >= ftot) {
            /* 复用 scratch 走同一条分发路径 */
            memcpy(c->scratch, data + off, ftot);
            off += ftot;
            uint32_t seq;
            const char *why;
            uint16_t type = zc_check_rec(c->scratch, ftot, &seq, &why);
            if (type == 0xFFFF) {
                printf("$$$ EXFAIL reason=cli_rec_bad why=%s\n", why);
                g_fail = true;
                return;
            }
            if ((type & 0x7FFFu) == RT_CTRL_ACK) {
                if (seq == s_ack_want) {
                    s_ack_hit = true;
                }
            } else if (c->on_data != NULL) {
                c->on_data(c->uctx_r, c->scratch, ftot, type, seq);
            }
        } else {
            memcpy(c->scratch, data + off, remain);
            c->pend_len = remain;
            return;
        }
    }
}

static err_t cli_connected_cb(void *arg, struct tcp_pcb *tpcb, err_t err)
{
    zc_cli_t *c = (zc_cli_t *)arg;
    if (err != ERR_OK) {
        c->estab_fail = true;
        xSemaphoreGive(c->estab);
        return err;
    }
    c->pcb = tpcb;
    xSemaphoreGive(c->estab);
    return ERR_OK;
}

static err_t cli_recv_fwd(void *arg, struct tcp_pcb *pcb, struct pbuf *p, err_t err)
{
    zc_cli_t *c = (zc_cli_t *)arg;
    (void)err;
    if (p == NULL) {
        c->peer_closed = true;
        return ERR_OK;
    }
    for (struct pbuf *q = p; q != NULL && !g_fail; q = q->next) {
        cli_feed(c, (const uint8_t *)q->payload, q->len);
    }
    tcp_recved(pcb, p->tot_len);
    pbuf_free(p);
    return ERR_OK;
}

static err_t cli_sent_fwd(void *arg, struct tcp_pcb *pcb, u16_t len)
{
    zc_cli_t *c = (zc_cli_t *)arg;
    if (c->on_sent != NULL) {
        c->on_sent(c->uctx_s, pcb, len);
    }
    return ERR_OK;
}

static void cli_err_fwd(void *arg, err_t err)
{
    zc_cli_t *c = (zc_cli_t *)arg;
    printf("EX16-CLIERR err=%d (%s)\n", (int)err,
           err == ERR_RST ? "RST" : "other");
    c->pcb = NULL;
    c->fatal = true;
    c->peer_closed = true;
    c->estab_fail = true; /* 让建连等待方立即退出 */
    xSemaphoreGive(c->estab);
}

typedef struct
{
    zc_cli_t *c;
    uint16_t dport;
} cli_open_arg_t;

static void cli_open_inner(void *raw)
{
    cli_open_arg_t *a = (cli_open_arg_t *)raw;
    zc_cli_t *c = a->c;
    struct tcp_pcb *p = tcp_new_ip_type(IPADDR_TYPE_V4);
    if (p == NULL) {
        c->estab_fail = true;
        xSemaphoreGive(c->estab);
        return;
    }
    tcp_arg(p, c);
    tcp_err(p, cli_err_fwd);
    tcp_recv(p, cli_recv_fwd);
    tcp_sent(p, cli_sent_fwd);
    err_t e = tcp_connect(p, &g_load_dst, a->dport, cli_connected_cb);
    if (e != ERR_OK) {
        tcp_arg(p, NULL);
        tcp_err(p, NULL);
        tcp_recv(p, NULL);
        tcp_sent(p, NULL);
        tcp_close(p);
        c->estab_fail = true;
        xSemaphoreGive(c->estab);
    }
}

bool zc_cli_open_ext(zc_cli_t *c, const char *who, uint16_t dport,
                     int64_t timeout_ms)
{
    if (c->estab == NULL) {
        c->estab = xSemaphoreCreateBinary();
    }
    c->estab_fail = false;
    c->fatal = false;
    c->peer_closed = false;
    c->pend_len = 0;
    static cli_open_arg_t a;
    a.c = c;
    a.dport = dport;
    xSemaphoreTake(c->estab, 0);
    if (!zc_run_in_tcpip(cli_open_inner, &a, timeout_ms)) {
        return false;
    }
    if (xSemaphoreTake(c->estab, pdMS_TO_TICKS(timeout_ms)) != pdTRUE ||
        c->estab_fail || c->pcb == NULL) {
        printf("$$$ EXFAIL reason=cli_connect who=%s port=%u dst=%s\n", who,
               (unsigned)dport, ipaddr_ntoa(&g_load_dst));
        return false;
    }
    printf("EX16-CLICONN who=%s dst=%s:%u\n", who, ipaddr_ntoa(&g_load_dst),
           (unsigned)dport);
    return true;
}

static void cli_unwire_inner(void *raw)
{
    zc_cli_t *c = (zc_cli_t *)raw;
    struct tcp_pcb *p = c->pcb;
    if (p == NULL) {
        return;
    }
    tcp_arg(p, NULL);
    tcp_err(p, NULL);
    tcp_recv(p, NULL);
    tcp_sent(p, NULL);
    c->pcb = NULL;
    tcp_close(p); /* 基准结束后的正常回收，TIME_WAIT 属预期 */
}

void zc_cli_close(zc_cli_t *c)
{
    if (c->pcb != NULL) {
        zc_run_in_tcpip(cli_unwire_inner, c, 2000);
    }
}

err_t zc_cli_post(zc_cli_t *c, const uint8_t *rec, uint16_t tot, u8_t apiflags)
{
    if (c->pcb == NULL) {
        return ERR_CLSD;
    }
    if (tcp_sndbuf(c->pcb) < tot) {
        return ERR_INPROGRESS;
    }
    err_t e = tcp_write(c->pcb, rec, tot, apiflags);
    if (e == ERR_OK) {
        tcp_output(c->pcb);
    }
    return e;
}

/* 任务侧投递通道：tcp_write 只能在 tcpip 线程调用（ch15 的 xtw 误用即此），
 * 任务上下文一律经 tcpip_callback 排程执行。 */
typedef struct
{
    zc_cli_t *c;
    const uint8_t *rec;
    uint16_t tot;
    err_t e;
} postmsg_t;

static void cli_post_inner(void *raw)
{
    postmsg_t *m = (postmsg_t *)raw;
    m->e = zc_cli_post(m->c, m->rec, m->tot, TCP_WRITE_FLAG_COPY);
}

static err_t zc_cli_post_from_task(zc_cli_t *c, const uint8_t *rec, uint16_t tot)
{
    postmsg_t m = {c, rec, tot, ERR_VAL};
    if (!zc_run_in_tcpip(cli_post_inner, &m, 3000)) {
        return ERR_IF;
    }
    return m.e;
}

bool zc_cli_send_ack_wait(zc_cli_t *c, uint16_t type, uint32_t seq,
                          const uint8_t *payload, uint16_t plen,
                          int64_t timeout_ms)
{
    if (c->pcb == NULL || c->fatal) {
        return false;
    }
    uint8_t rec[REC_HDR_LEN];
    zc_build_rec(rec, type, seq, payload, plen);
    zc_cli_arm_ack_wait(seq);

    int64_t deadline = esp_timer_get_time() + timeout_ms * 1000LL;
    for (;;) {
        err_t e = zc_cli_post_from_task(c, rec, REC_HDR_LEN);
        if (e == ERR_OK) {
            break;
        }
        if (e != ERR_INPROGRESS) {
            return false; /* 通道/连接故障 */
        }
        if (esp_timer_get_time() > deadline) {
            return false;
        }
        vTaskDelay(pdMS_TO_TICKS(2));
    }
    while (!s_ack_hit) {
        if (c->pcb == NULL || c->fatal || g_fail ||
            esp_timer_get_time() > deadline) {
            return false;
        }
        vTaskDelay(pdMS_TO_TICKS(1));
    }
    return true;
}
