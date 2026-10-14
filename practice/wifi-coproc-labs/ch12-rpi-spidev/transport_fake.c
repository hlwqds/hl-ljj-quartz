/* transport_fake.c —— 内存回环的假 S3 从机（ch12 的 Windows 可测半边）
 *
 * xfer 的行为忠实模拟真 SPI 从机：对端"事先挂好"的 TX 缓冲在交换时被带回——
 * 实现为：把主机 tx 喂给对端解析器（可能产生应答帧排队），再把队头帧装进 rx。
 * 假 S3 的行为：PING → 原样应答；DATA → echo 事件。
 */
#include "transport.h"
#include "framing.h"
#include "control.h"
#include <string.h>
#include <stdio.h>

static uint8_t s_pending[TR_XCHG];
static size_t s_pending_len;
static int s_drdy_flag;

static void peer_send(uint8_t type, const uint8_t *payload, size_t plen, uint16_t seq)
{
    struct fr_frame f = { .seq = seq, .type = type };
    memcpy(f.payload, payload, plen);
    f.plen = (uint16_t)plen;
    s_pending_len = fr_pack(&f, s_pending, sizeof s_pending);
    s_drdy_flag = 1; /* 队列非空：DRDY 拉高（ch02 §2.3 时序） */
}

static void peer_sink(struct fr_frame *f, void *user)
{
    (void)user;
    if (f->type == FR_TYPE_CTRL_REQ) {
        struct ctl_msg m;
        if (!ctl_parse(f->payload, f->plen, 0, &m))
            return;
        struct ctl_msg r = { .cmd = m.cmd, .req_id = m.req_id, .status = CTL_OK };
        memcpy(r.body, m.body, m.bodylen);
        r.bodylen = m.bodylen; /* PING：原样回显（含 cookie TLV） */
        uint8_t pkt[512];
        size_t pl = ctl_pack_rsp(&r, pkt, sizeof pkt);
        peer_send(FR_TYPE_CTRL_RSP, pkt, pl, f->seq);
    } else if (f->type == FR_TYPE_DATA && f->plen >= 4) {
        uint8_t evt[520];
        evt[0] = EV_SOCK_DATA;
        evt[1] = f->payload[0], evt[2] = f->payload[1]; /* sid 原样 */
        memcpy(evt + 3, f->payload + 4, f->plen - 4);
        peer_send(FR_TYPE_EVENT, evt, 3 + (size_t)(f->plen - 4), f->seq);
    }
}

static struct fr_parser s_peer;

int fake_xfer(uint8_t *tx, uint8_t *rx, size_t n)
{
    if (n != TR_XCHG)
        return -1;
    fr_feed(&s_peer, tx, n); /* 对端收到主机发的（含 IDLE 填充，帧层合法） */
    memset(rx, 0, n);        /* 对端"事先挂好"的缓冲：有队头帧则装填 */
    if (s_pending_len) {
        memcpy(rx, s_pending, s_pending_len);
        s_pending_len = 0;
        s_drdy_flag = 0; /* 队列清空：DRDY 回落 */
    }
    return 0;
}

int fake_drdy(void)
{
    return s_drdy_flag;
}

struct transport *transport_fake(void)
{
    static struct transport t = { "fake", fake_xfer, fake_drdy };
    fr_parser_init(&s_peer, peer_sink, NULL);
    s_pending_len = 0;
    s_drdy_flag = 0;
    return &t;
}
