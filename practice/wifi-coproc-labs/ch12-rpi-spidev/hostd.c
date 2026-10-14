/* hostd.c —— 宿主守护进程（ch12 §12.3 事件泵；双目标：fake 测试 / Linux 真机）
 *
 * 主循环三类事件源 → do_exchange（传输层 xfer + 帧层 fr_feed + 分发）。
 * 与 ch02 的 f429/spi_master.c 主循环逐行同构——变的是"交换"动词的实现。
 * 真机形态：int main() 里 spidev_open 后进 loop；测试形态：test.c 直调
 * hostd_init/hostd_ping/hostd_echo（fake 传输层）。
 */
#include "hostd.h"
#include "transport.h"
#include "framing.h"
#include "control.h"
#include <string.h>
#include <stdio.h>

static struct transport *s_tr;
static uint8_t s_txbuf[TR_XCHG], s_rxbuf[TR_XCHG];
static uint8_t s_stage[TR_XCHG]; /* 待发帧暂存：do_exchange 装填后清零
    （首版 do_exchange 先 memset 发送缓冲，把 ping 刚装好的帧当场擦掉——
     交换层负责"擦"，业务层负责"装"，时序不能颠倒，run.log 排错记） */
static size_t s_stage_len;

static struct ctl_msg s_rsp;
static int s_rsp_got;
static uint8_t s_evbuf[TR_XCHG];
static size_t s_evlen;
static int s_ev_got;

static void host_sink(struct fr_frame *f, void *user)
{
    (void)user;
    if (f->type == FR_TYPE_CTRL_RSP) {
        ctl_parse(f->payload, f->plen, 1, &s_rsp);
        s_rsp_got = 1;
    } else if (f->type == FR_TYPE_EVENT) {
        size_t n = f->plen < sizeof s_evbuf ? f->plen : sizeof s_evbuf;
        memcpy(s_evbuf, f->payload, n);
        s_evlen = n;
        s_ev_got = 1;
    }
}

void hostd_init(struct transport *tr)
{
    s_tr = tr;
    s_rsp_got = s_ev_got = 0;
    fr_parser_init(&s_parser, host_sink, NULL);
}

static void do_exchange(void)
{
    memset(s_txbuf, 0, sizeof s_txbuf); /* IDLE 填充（帧层合法空闲） */
    if (s_stage_len) {
        memcpy(s_txbuf, s_stage, s_stage_len); /* 有待发帧则装填 */
        s_stage_len = 0;
    }
    s_tr->xfer(s_txbuf, s_rxbuf, TR_XCHG);
    fr_feed(&s_parser, s_rxbuf, TR_XCHG);
}

/* 主循环一拍：DRDY 有信号或本端有积压 → 交换（ch12 §12.3 同构） */
void hostd_poll(void)
{
    if (s_tr->drdy())
        do_exchange();
}

static uint16_t s_req_id = 1;

int hostd_ping(uint32_t cookie)
{
    struct ctl_msg m = { .cmd = CMD_PING, .req_id = s_req_id++ };
    struct tlvw w;
    tlvw_init(&w, m.body, sizeof m.body);
    tlvw_put_u32(&w, 1, cookie);
    m.bodylen = w.len;

    uint8_t pkt[512];
    size_t pl = ctl_pack_req(&m, pkt, sizeof pkt);
    struct fr_frame f = { .type = FR_TYPE_CTRL_REQ };
    memcpy(f.payload, pkt, pl);
    f.plen = (uint16_t)pl;
    s_stage_len = fr_pack(&f, s_stage, sizeof s_stage);
    s_rsp_got = 0;
    do_exchange(); /* 本端有货直发（与 ch02 enqueue 路径同义） */
    return s_rsp_got && s_rsp.status == CTL_OK ? 0 : -1;
}

int hostd_echo(const void *data, size_t len)
{
    if (len > TR_XCHG - 16)
        return -1;
    struct fr_frame f = { .type = FR_TYPE_DATA };
    f.payload[0] = 0, f.payload[1] = 1; /* sid=1 */
    f.payload[2] = (uint8_t)(len >> 8), f.payload[3] = (uint8_t)len;
    memcpy(f.payload + 4, data, len);
    f.plen = (uint16_t)(4 + len);
    s_stage_len = fr_pack(&f, s_stage, sizeof s_stage);
    s_ev_got = 0;
    do_exchange();
    do_exchange(); /* 应答以事件帧从对端队列送回：第二拍取走 */
    return s_ev_got && s_evlen == 3 + len && s_evbuf[0] == EV_SOCK_DATA &&
                   !memcmp(s_evbuf + 3, data, len)
               ? 0
               : -1;
}

/* 真机入口（Linux 版编译时启用；fake 测试下不链接） */
#ifdef HOSTD_LINUX_MAIN
int main(int argc, char **argv)
{
    const char *dev = argc > 1 ? argv[1] : "/dev/spidev0.0";
    uint32_t speed = argc > 2 ? (uint32_t)atoi(argv[2]) : 1000000;
    if (spidev_open(dev, speed) < 0)
        return 1;
    struct transport *tr = transport_spidev();
    hostd_init(tr);
    printf("[hostd] %s 就绪，PING 循环开始（Ctrl-C 退出）\n", dev);
    for (;;) {
        if (hostd_ping(0x600DF00Du) == 0)
            printf("[hostd] PING ok\n");
        hostd_poll();
        sleep(1); /* 演示节奏；真机按 DRDY/定时事件驱动 */
    }
}
#endif
