/* test.c —— socket 代理验收：生命周期 / echo 吞吐 / 错误映射 / 背压水位 */
#include <stdio.h>
#include <string.h>
#include "sockproxy.h"
#include "control.h"
#include "sha1.h"

static int g_pass, g_fail;
#define CHECK(c, n)                                                                            \
    do {                                                                                       \
        if (c) {                                                                               \
            g_pass++, printf("PASS %s\n", n);                                                  \
        } else {                                                                               \
            g_fail++, printf("FAIL %s\n", n);                                                  \
        }                                                                                      \
    } while (0)

static unsigned rng = 0xfeedfaceu;
static uint8_t rnd(void)
{
    rng ^= rng << 13, rng ^= rng >> 17, rng ^= rng << 5;
    return (uint8_t)rng;
}

int main(void)
{
    ws_init();

    /* 1) 生命周期：socket→connect→收发→close，sid 分配递增 */
    uint8_t ip[4];
    ws_dns("demo.local", ip);
    int s = ws_socket(0);
    CHECK(s == 1, "SOCK_OPEN 分配 sid=1");
    CHECK(ws_connect(s, ip, 8080) == 0, "SOCK_CONNECT 成功");

    uint8_t msg[] = "hello-over-spi";
    ws_send(s, msg, sizeof msg);
    uint8_t back[64];
    int n = ws_recv(s, back, sizeof back);
    CHECK(n == (int)sizeof msg && !memcmp(back, msg, sizeof msg), "echo 数据往返一致");
    CHECK(ws_peer_watermark(s) >= sizeof msg, "S3 侧水位记账可见");

    int s2 = ws_socket(0);
    CHECK(ws_close(s) == 0 && ws_socket(0) == s2 + 1, "CLOSE 后新 socket 复用递增");

    /* 2) 错误映射：端口 1 = 注入拒绝，状态码跨河还原 */
    int s3 = ws_socket(0);
    int rc = ws_connect(s3, ip, 1);
    CHECK(rc == -(0x100 + CTL_E_APP + 111), "错误码跨河映射（应用层拒绝）");
    ws_close(s3);

    /* 3) echo 吞吐：1MB 分块收发 + SHA-1 对账（大块自动分帧在 ws_send 内部） */
    enum { TOTAL = 1u << 20 };
    static uint8_t blob[TOTAL];
    for (size_t i = 0; i < TOTAL; i++)
        blob[i] = rnd();
    static uint8_t rbuf[TOTAL];
    size_t got = 0;
    int t = ws_socket(0);
    ws_connect(t, ip, 9000);
    size_t off = 0;
    while (off < TOTAL) { /* 边发边收：宿主持续消费（背压闸门 3 在工作） */
        size_t chunk = 4600;
        if (off + chunk > TOTAL)
            chunk = TOTAL - off;
        ws_send(t, blob + off, chunk);
        off += chunk;
        while (got < off) {
            int r = ws_recv(t, rbuf + got, (size_t)(off - got));
            if (r <= 0)
                break;
            got += (size_t)r;
        }
    }
    uint8_t d1[20], d2[20];
    char h1[41], h2[41];
    sha1(blob, TOTAL, d1), sha1(rbuf, TOTAL, d2);
    sha1_hex(d1, h1), sha1_hex(d2, h2);
    CHECK(got == TOTAL && !strcmp(h1, h2), "1MiB echo 分帧重组 + SHA-1 对账");
    printf("     双向 SHA-1=%s…（S3 水线峰值 %u B / 高水位门限 %d）\n", h1 + 0,
           (unsigned)ws_peer_watermark(t), S3_RX_HIGH_WM);
    CHECK(ws_peer_watermark(t) <= S3_RX_HIGH_WM + 4600,
          "背压可见：水位未失控（持续消费下）");

    printf("\n合计：PASS %d / FAIL %d\n", g_pass, g_fail);
    return g_fail ? 1 : 0;
}
