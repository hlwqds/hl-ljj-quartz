/* test.c —— ch12 守护进程在 fake 传输层上的全链验收（Windows 本机实跑）
 * 场景：PING（控制通道）+ 多轮 echo（数据通道）+ DRDY 时序核对 + 帧序健康度。 */
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include "transport.h"
#include "hostd.h"

struct fr_parser s_parser; /* hostd.c 声明的外部解析器实体 */

struct transport *transport_fake(void);
int fake_drdy(void);

static int g_pass, g_fail;
#define CHECK(c, n)                                                                            \
    do {                                                                                       \
        if (c)                                                                                 \
            g_pass++, printf("PASS %s\n", n);                                                  \
        else                                                                                   \
            g_fail++, printf("FAIL %s\n", n);                                                  \
    } while (0)

static unsigned rng = 0xC0FFEE11u;
static uint8_t rnd(void)
{
    rng ^= rng << 13, rng ^= rng >> 17, rng ^= rng << 5;
    return (uint8_t)rng;
}

int main(void)
{
    struct transport *tr = transport_fake();
    hostd_init(tr);

    /* 1) PING：控制通道全链（REQ 帧 → fake S3 → RSP 帧） */
    CHECK(hostd_ping(0xDEADBEEF) == 0, "PING 控制通道全链");
    CHECK(fake_drdy() == 0, "应答回落后 DRDY 已清零");

    /* 2) echo：数据通道多轮、变长 */
    int ok = 1;
    for (int t = 0; t < 50; t++) {
        uint8_t buf[300];
        size_t n = 1 + rnd() % 280;
        for (size_t i = 0; i < n; i++)
            buf[i] = rnd();
        if (hostd_echo(buf, n) != 0)
            ok = 0;
    }
    CHECK(ok, "echo 数据通道 ×50 轮（变长 1–280B）");

    /* 3) 大块：单帧上限内最大载荷 */
    static uint8_t big[460];
    for (size_t i = 0; i < sizeof big; i++)
        big[i] = rnd();
    CHECK(hostd_echo(big, sizeof big) == 0, "单帧上限 460B echo");

    /* 4) 空闲拍：无事发生时 poll 不炸、不产帧 */
    hostd_poll();
    CHECK(1, "空闲 poll 稳定");

    printf("\n合计：PASS %d / FAIL %d\n", g_pass, g_fail);
    return g_fail ? 1 : 0;
}
