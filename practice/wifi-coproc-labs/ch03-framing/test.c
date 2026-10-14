/* test.c —— 帧层全套验收：COBS 边界、CRC 向量、打包-流式解析回环、故障注入 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "cobs.h"
#include "crc32.h"
#include "framing.h"

static int g_pass = 0, g_fail = 0;
#define CHECK(cond, name)                                                                      \
    do {                                                                                       \
        if (cond) {                                                                            \
            g_pass++;                                                                          \
            printf("PASS %s\n", name);                                                         \
        } else {                                                                               \
            g_fail++;                                                                          \
            printf("FAIL %s\n", name);                                                         \
        }                                                                                      \
    } while (0)

static unsigned rng = 0x1234abcdu;
static uint8_t rnd(void)
{
    rng ^= rng << 13, rng ^= rng >> 17, rng ^= rng << 5;
    return (uint8_t)rng;
}

static int g_got;
static struct fr_frame g_last;
static void sink(struct fr_frame *f, void *user)
{
    (void)user;
    g_last = *f;
    g_got++;
}

int main(void)
{
    /* ---- 1) COBS 已知向量 ---- */
    uint8_t out[600];
    size_t n = cobs_encode((const uint8_t *)"\x00", 1, out, sizeof out);
    CHECK(n == 2 && out[0] == 0x01 && out[1] == 0x01, "COBS 向量 [00]→[01 01]");
    n = cobs_encode((const uint8_t *)"\x01", 1, out, sizeof out);
    CHECK(n == 2 && out[0] == 0x02 && out[1] == 0x01, "COBS 向量 [01]→[02 01]");

    /* ---- 2) COBS 254 边界 + 输出无零 + 回环 ---- */
    uint8_t in[2000], dec[2000];
    for (int t = 0; t < 3; t++) {
        size_t len = t == 0 ? 253 : t == 1 ? 254 : 255;
        for (size_t i = 0; i < len; i++)
            in[i] = 0x01 + (uint8_t)(i % 250); /* 连续非零段 */
        n = cobs_encode(in, len, out, sizeof out);
        int no_zero = 1;
        for (size_t i = 0; i < n; i++)
            if (out[i] == 0)
                no_zero = 0;
        size_t dn = cobs_decode(out, n, dec, sizeof dec);
        CHECK(no_zero && dn == len && !memcmp(in, dec, len), "COBS 254 边界回环");
    }
    int ok = 1;
    for (int t = 0; t < 3000; t++) { /* 随机数据（含密集零）回环 */
        size_t len = 1 + rnd() % 700;
        for (size_t i = 0; i < len; i++)
            in[i] = rnd() < 32 ? 0x00 : rnd();
        n = cobs_encode(in, len, out, sizeof out);
        size_t dn = cobs_decode(out, n, dec, sizeof dec);
        if (dn != len || memcmp(in, dec, len))
            ok = 0;
    }
    CHECK(ok, "COBS 随机回环 ×3000");

    /* ---- 3) CRC32 向量 ---- */
    CHECK(crc32_ieee("123456789", 9) == 0xCBF43926u, "CRC32 向量 123456789");
    CHECK(crc32_ieee("", 0) == 0x00000000u, "CRC32 空输入");

    /* ---- 4) 帧打包 → 流式解析（空闲填充/连发/截断续喂） ---- */
    struct fr_parser p;
    fr_parser_init(&p, sink, NULL);
    struct fr_frame f = { .seq = 0xBEEF, .type = FR_TYPE_DATA };
    for (int i = 0; i < 200; i++)
        f.payload[i] = rnd();
    f.plen = 200;
    uint8_t wire[1200];
    size_t wn = fr_pack(&f, wire, sizeof wire);

    uint8_t stream[2400]; /* 模拟交换缓冲：空闲填充 + 帧 + 填充 + 帧 */
    memset(stream, 0, sizeof stream);
    memcpy(stream + 16, wire, wn);
    memcpy(stream + 16 + wn + 7, wire, wn);
    size_t half = 16 + wn + 7 + wn / 2; /* 第一帧完整喂入，第二帧截成两半 */
    fr_feed(&p, stream, half);
    CHECK(g_got == 1 && g_last.seq == 0xBEEF && g_last.plen == 200, "帧回环（填充中切帧）");
    fr_feed(&p, stream + half, 16 + wn + 7 + wn - half);
    CHECK(g_got == 2, "截断续喂 + 连发双帧");

    /* ---- 5) 故障注入：翻一位必被拒（CRC 或头部检查其一），截断不误收 ---- */
    struct fr_parser q;
    fr_parser_init(&q, sink, NULL);
    uint8_t bad[1200];
    memcpy(bad, wire, wn);
    bad[wn / 2] ^= 0x01; /* 破坏线上字节中部（载荷区对应处） */
    fr_feed(&q, bad, wn);
    CHECK(q.bad_crc + q.bad_hdr >= 1 && g_got == 2, "翻位帧被拒收（CRC/头部）");
    fr_feed(&q, wire, wn - 3); /* 截断：不应产生帧也不崩溃 */
    CHECK(g_got == 2, "截断帧等待不误收");

    printf("\n合计：PASS %d / FAIL %d\n", g_pass, g_fail);
    return g_fail ? 1 : 0;
}
