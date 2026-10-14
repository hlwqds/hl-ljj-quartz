/* sockproxy.c —— 宿主侧 ws_* 实现 + 内存回环上的假 S3 服务（s3 侧合并在此，便于单文件浏览）
 *
 * 链路仿真：ws_* 调用 → 控制帧/DATA 帧 fr_pack → fr_feed(s3 解析器) →
 * 假 S3 应答/事件 → fr_feed(host 解析器) → 应答存回调用现场。
 * 假 S3 的数据行为 = echo（收到什么 SOCK_SEND 回什么 SOCK_DATA 事件），
 * 另支持错误注入（连到端口 1 → 拒绝）与 EOF 注入。
 */
#include "sockproxy.h"
#include "control.h"
#include "framing.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

/* ---------- 假 S3 侧 ---------- */

static struct {
    struct s3_sock socks[S3_MAX_SOCKS];
    uint16_t next_sid;
} s3;

struct fr_parser g_host_parser; /* 宿主侧解析器（S3 回喂目标） */
struct fr_parser g_s3_parser;   /* S3 侧解析器（宿主调用目标） */

static uint32_t consumed_hint(uint16_t sid); /* 宿主已消费量（水位观测用，后定义 */

static void s3_send_rsp(uint16_t cmd, uint16_t req_id, uint8_t status,
                        const uint8_t *body, size_t blen)
{
    uint8_t pkt[512];
    struct ctl_msg m = { .cmd = cmd, .req_id = req_id, .status = status };
    memcpy(m.body, body, blen);
    m.bodylen = blen;
    size_t pl = ctl_pack_rsp(&m, pkt, sizeof pkt);
    struct fr_frame f = { .type = FR_TYPE_CTRL_RSP };
    memcpy(f.payload, pkt, pl);
    f.plen = (uint16_t)pl;
    uint8_t wire[1200];
    size_t wn = fr_pack(&f, wire, sizeof wire);
    fr_feed(&g_host_parser, wire, wn); /* 直接喂宿主解析器（内存回环） */
}

static void s3_push_event(uint8_t ev, const uint8_t *body, size_t blen)
{
    uint8_t pkt[512];
    pkt[0] = ev;
    memcpy(pkt + 1, body, blen);
    struct fr_frame f = { .type = FR_TYPE_EVENT };
    memcpy(f.payload, pkt, blen + 1);
    f.plen = (uint16_t)(blen + 1);
    uint8_t wire[1200];
    size_t wn = fr_pack(&f, wire, sizeof wire);
    fr_feed(&g_host_parser, wire, wn);
}

static void s3_sink(struct fr_frame *f, void *user)
{
    (void)user;
    if (f->type == FR_TYPE_CTRL_REQ) {
        struct ctl_msg m;
        if (!ctl_parse(f->payload, f->plen, 0, &m))
            return;
        if (m.cmd == CMD_SOCK_OPEN) {
            for (int i = 0; i < S3_MAX_SOCKS; i++)
                if (!s3.socks[i].used) {
                    memset(&s3.socks[i], 0, sizeof s3.socks[i]);
                    s3.socks[i].used = 1;
                    s3.socks[i].sid = s3.next_sid++;
                    uint8_t b[2] = { s3.socks[i].sid >> 8, s3.socks[i].sid };
                    s3_send_rsp(m.cmd, m.req_id, CTL_OK, b, 2);
                    return;
                }
            s3_send_rsp(m.cmd, m.req_id, CTL_E_STATE, NULL, 0); /* 表满 */
        } else if (m.cmd == CMD_SOCK_CONNECT) {
            uint16_t sid = m.body[0] << 8 | m.body[1];
            uint16_t port = m.body[6] << 8 | m.body[7];
            for (int i = 0; i < S3_MAX_SOCKS; i++)
                if (s3.socks[i].used && s3.socks[i].sid == sid) {
                    if (port == 1) { /* 错误注入：端口 1 = 拒绝 */
                        s3_send_rsp(m.cmd, m.req_id, CTL_E_APP + 111, NULL, 0);
                        return;
                    }
                    s3.socks[i].connected = 1;
                    s3_send_rsp(m.cmd, m.req_id, CTL_OK, NULL, 0);
                    return;
                }
            s3_send_rsp(m.cmd, m.req_id, CTL_E_APP, NULL, 0); /* 无此 sid */
        } else if (m.cmd == CMD_SOCK_CLOSE) {
            uint16_t sid = m.body[0] << 8 | m.body[1];
            for (int i = 0; i < S3_MAX_SOCKS; i++)
                if (s3.socks[i].used && s3.socks[i].sid == sid) {
                    s3.socks[i].used = 0;
                    uint8_t b[2] = { sid >> 8, sid };
                    s3_send_rsp(m.cmd, m.req_id, CTL_OK, b, 2);
                    return;
                }
            s3_send_rsp(m.cmd, m.req_id, CTL_E_APP, NULL, 0);
        }
    } else if (f->type == FR_TYPE_DATA && f->plen >= 4) {
        /* DATA 帧：[sid(2)][len(2)][数据] —— echo 服务 + 水位记账 */
        uint16_t sid = f->payload[0] << 8 | f->payload[1];
        uint16_t dlen = f->payload[2] << 8 | f->payload[3];
        for (int i = 0; i < S3_MAX_SOCKS; i++)
            if (s3.socks[i].used && s3.socks[i].sid == sid) {
                s3.socks[i].rx_bytes += dlen;
                if (s3.socks[i].rx_bytes - consumed_hint(sid) > s3.socks[i].rx_watermark)
                    s3.socks[i].rx_watermark = s3.socks[i].rx_bytes;
                /* 闸门 1：超过高水位 → 停读（演示中体现为 paused 置位 + 计数） */
                if (s3.socks[i].rx_bytes > S3_RX_HIGH_WM)
                    s3.socks[i].paused = 1;
                uint8_t evt[4 + 460];
                evt[0] = EV_SOCK_DATA;
                evt[1] = sid >> 8, evt[2] = sid;
                memcpy(evt + 3, f->payload + 4, dlen);
                s3_push_event(EV_SOCK_DATA, evt + 1, (size_t)dlen + 2);
                return;
            }
    }
}

/* ---------- 宿主侧 ---------- */

struct ws_ctx {
    uint8_t rx[16][8192]; /* 每个 sid 一个接收缓冲：小于 S3 高水位（闸门 3 的本地容量，
                             首版 460B 在 4600B 批量发送时溢出丢数据——run.log 排错记） */
    uint16_t rxlen[16];
    uint32_t consumed[16]; /* 累计消费量：水位公式用"到达-累计消费"，不是"滞留" */
    int eof[16];
    uint32_t dropped[16];
};

static uint16_t g_req_id = 1;
static struct ctl_msg g_rsp_wait;
static int g_rsp_got;
static struct ws_ctx g_ctx;

static void host_sink(struct fr_frame *f, void *user)
{
    (void)user;
    if (f->type == FR_TYPE_CTRL_RSP) {
        ctl_parse(f->payload, f->plen, 1, &g_rsp_wait);
        g_rsp_got = 1;
    } else if (f->type == FR_TYPE_EVENT && f->plen >= 3) {
        uint8_t ev = f->payload[0];
        uint16_t sid = f->payload[1] << 8 | f->payload[2];
        if (ev == EV_SOCK_DATA && f->plen > 3) {
            size_t n = f->plen - 3;
            if (sid < 16 && g_ctx.rxlen[sid] + n <= sizeof g_ctx.rx[0])
                memcpy(g_ctx.rx[sid] + g_ctx.rxlen[sid], f->payload + 3, n),
                    g_ctx.rxlen[sid] += (uint16_t)n;
            else
                g_ctx.dropped[sid]++; /* UDP 语义：超水即丢（ch06 §6.3） */
        } else if (ev == EV_SOCK_EOF && sid < 16) {
            g_ctx.eof[sid] = 1;
        }
    }
}

/* 让"宿主侧消费"回传给假 S3 的水位观测（演示简化：宿主取走即上报） */
uint32_t consumed_hint(uint16_t sid)
{
    return sid < 16 ? g_ctx.consumed[sid] : 0;
}

static int call(uint16_t cmd, const uint8_t *body, size_t blen, struct ctl_msg *out)
{
    uint8_t pkt[512];
    struct ctl_msg m = { .cmd = cmd, .req_id = g_req_id++ };
    memcpy(m.body, body, blen);
    m.bodylen = blen;
    size_t pl = ctl_pack_req(&m, pkt, sizeof pkt);
    struct fr_frame f = { .type = FR_TYPE_CTRL_REQ };
    memcpy(f.payload, pkt, pl);
    f.plen = (uint16_t)pl;
    uint8_t wire[1200];
    size_t wn = fr_pack(&f, wire, sizeof wire);
    g_rsp_got = 0;
    fr_feed(&g_s3_parser, wire, wn);
    if (!g_rsp_got)
        return -1;
    *out = g_rsp_wait;
    return 0;
}

static int send_data(uint16_t sid, const void *buf, size_t n)
{
    while (n) {
        size_t chunk = n > 460 ? 460 : n;
        struct fr_frame f = { .type = FR_TYPE_DATA };
        f.payload[0] = sid >> 8, f.payload[1] = sid;
        f.payload[2] = chunk >> 8, f.payload[3] = chunk;
        memcpy(f.payload + 4, buf, chunk);
        f.plen = (uint16_t)(4 + chunk);
        uint8_t wire[1200];
        size_t wn = fr_pack(&f, wire, sizeof wire);
        fr_feed(&g_s3_parser, wire, wn);
        buf = (const char *)buf + chunk;
        n -= chunk;
    }
    return 0;
}

/* ---- 公开 API ---- */

struct ws_ctx *ws_init(void)
{
    memset(&s3, 0, sizeof s3);
    s3.next_sid = 1;
    memset(&g_ctx, 0, sizeof g_ctx);
    fr_parser_init(&g_host_parser, host_sink, NULL);
    fr_parser_init(&g_s3_parser, s3_sink, NULL);
    return &g_ctx;
}

int ws_socket(int type)
{
    (void)type;
    struct ctl_msg rsp;
    uint8_t b[4] = { 0 };
    if (call(CMD_SOCK_OPEN, b, 1, &rsp) < 0)
        return -1;
    return rsp.status == CTL_OK ? (rsp.body[0] << 8 | rsp.body[1]) : -rsp.status;
}

int ws_connect(int sid, const uint8_t ip[4], uint16_t port)
{
    uint8_t b[8] = { sid >> 8, sid, ip[0], ip[1], ip[2], ip[3], port >> 8, port };
    struct ctl_msg rsp;
    if (call(CMD_SOCK_CONNECT, b, 8, &rsp) < 0)
        return -1;
    return rsp.status == CTL_OK ? 0 : -(0x100 + rsp.status);
}

int ws_send(int sid, const void *buf, size_t len)
{
    return send_data(sid, buf, len);
}

int ws_recv(int sid, void *buf, size_t len)
{
    if (sid >= 16)
        return -1;
    if (g_ctx.rxlen[sid] == 0)
        return g_ctx.eof[sid] ? 0 : -2; /* 演示同步模型：无数据即返回 */
    size_t n = g_ctx.rxlen[sid] < len ? g_ctx.rxlen[sid] : len;
    memcpy(buf, g_ctx.rx[sid], n);
    memmove(g_ctx.rx[sid], g_ctx.rx[sid] + n, g_ctx.rxlen[sid] - n);
    g_ctx.rxlen[sid] -= (uint16_t)n;
    g_ctx.consumed[sid] += (uint32_t)n;
    return (int)n;
}

int ws_close(int sid)
{
    uint8_t b[2] = { sid >> 8, sid };
    struct ctl_msg rsp;
    if (call(CMD_SOCK_CLOSE, b, 2, &rsp) < 0)
        return -1;
    return rsp.status == CTL_OK ? 0 : -1;
}

int ws_dns(const char *name, uint8_t ip[4])
{
    /* 演示解析器：任何名字回 10.7.0.53（假 DNS） */
    (void)name;
    ip[0] = 10, ip[1] = 7, ip[2] = 0, ip[3] = 53;
    return 0;
}

uint32_t ws_peer_watermark(int sid)
{
    for (int i = 0; i < S3_MAX_SOCKS; i++)
        if (s3.socks[i].used && s3.socks[i].sid == (uint16_t)sid)
            return s3.socks[i].rx_watermark;
    return 0;
}

uint32_t ws_dropped_udp(int sid)
{
    return sid < 16 ? g_ctx.dropped[sid] : 0;
}
