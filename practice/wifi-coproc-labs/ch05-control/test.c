/* test.c —— 控制通道验收：命令回环（经 ch03 帧层）、TLV 性质、分片重组 */
#include <stdio.h>
#include <string.h>
#include "control.h"
#include "framing.h"

static int g_pass, g_fail;
#define CHECK(c, n)                                                                            \
    do {                                                                                       \
        if (c) {                                                                               \
            g_pass++, printf("PASS %s\n", n);                                                  \
        } else {                                                                               \
            g_fail++, printf("FAIL %s\n", n);                                                  \
        }                                                                                      \
    } while (0)

/* 内存回环传输层：REQ 帧打包→喂给"假 S3"解析→生成 RSP 帧→喂回宿主解析 */
static struct fr_parser s3_side, host_side;

static void s3_sink(struct fr_frame *f, void *user);
static void host_sink(struct fr_frame *f, void *user);

static struct ctl_msg g_rsp; /* 假 S3 的应答（测试用例逐个设置） */

static void roundtrip(const struct ctl_msg *req, struct ctl_msg *rsp_out)
{
    (void)rsp_out;
    uint8_t pkt[512], wire[1200];
    size_t pl = ctl_pack_req(req, pkt, sizeof pkt);
    struct fr_frame f = { .type = FR_TYPE_CTRL_REQ };
    memcpy(f.payload, pkt, pl);
    f.plen = (uint16_t)pl;
    size_t wn = fr_pack(&f, wire, sizeof wire);
    fr_feed(&s3_side, wire, wn); /* → s3_sink 生成应答 → 喂回 host_sink */
}

static void s3_sink(struct fr_frame *f, void *user)
{
    (void)user;
    if (f->type != FR_TYPE_CTRL_REQ)
        return;
    struct ctl_msg req;
    if (!ctl_parse(f->payload, f->plen, 0, &req))
        return;
    /* 假 S3：PING 原样回；DNS 回固定 IP；JOIN 回受理——按用例设置好的 g_rsp */
    struct ctl_msg rsp = g_rsp;
    rsp.cmd = req.cmd;
    rsp.req_id = req.req_id;
    uint8_t pkt[512], wire[1200];
    size_t pl = ctl_pack_rsp(&rsp, pkt, sizeof pkt);
    struct fr_frame of = { .seq = f->seq, .type = FR_TYPE_CTRL_RSP };
    memcpy(of.payload, pkt, pl);
    of.plen = (uint16_t)pl;
    size_t wn = fr_pack(&of, wire, sizeof wire);
    fr_feed(&host_side, wire, wn);
}

static struct ctl_msg g_host_got;
static int g_host_n;
static void host_sink(struct fr_frame *f, void *user)
{
    (void)user;
    if (f->type == FR_TYPE_CTRL_RSP) {
        ctl_parse(f->payload, f->plen, 1, &g_host_got);
        g_host_n++;
    }
}

int main(void)
{
    fr_parser_init(&s3_side, s3_sink, NULL);
    fr_parser_init(&host_side, host_sink, NULL);

    /* 1) PING：参数原样回显（含 4B 任意数据） */
    struct ctl_msg req = { .cmd = CMD_PING, .req_id = 0x1234 };
    struct tlvw w;
    tlvw_init(&w, req.body, sizeof req.body);
    uint32_t cookie = 0xDEADBEEF;
    tlvw_put_u32(&w, 1, cookie);
    req.bodylen = w.len;
    memset(&g_rsp, 0, sizeof g_rsp);
    struct tlvw rw;
    tlvw_init(&rw, g_rsp.body, sizeof g_rsp.body);
    tlvw_put_u32(&rw, 1, cookie);
    g_rsp.bodylen = rw.len;
    g_rsp.status = CTL_OK;

    roundtrip(&req, NULL);
    CHECK(g_host_n == 1 && g_host_got.cmd == CMD_PING && g_host_got.req_id == 0x1234 &&
              g_host_got.status == CTL_OK,
          "PING 请求-应答全链回环（req_id/status 保持）");
    struct tlvr r;
    tlvr_init(&r, g_host_got.body, g_host_got.bodylen);
    uint8_t t;
    const uint8_t *v;
    uint16_t vl;
    int found = 0;
    while (tlvr_next(&r, &t, &v, &vl))
        if (t == 1 && vl == 4 && v[0] == 0xDE && v[1] == 0xAD && v[2] == 0xBE &&
            v[3] == 0xEF) /* 网络序逐字节比，别拿本机小端内存比对（本测试自己踩过） */
            found = 1;
    CHECK(found, "应答 TLV 载荷无损");

    /* 2) JOIN：参数乱序 + 未知 TLV 混入，解码按 type 取 */
    struct ctl_msg j = { .cmd = CMD_JOIN, .req_id = 2 };
    tlvw_init(&w, j.body, sizeof j.body);
    tlvw_put_u8(&w, 0x77, 0xAA);            /* 未知 type（应被跳过） */
    tlvw_put(&w, 2, "HomeNet", 7);          /* SSID 放前面 */
    uint8_t ip[4] = { 10, 0, 0, 9 };
    tlvw_put(&w, 3, ip, 4);                 /* 换个顺序也无妨 */
    tlvw_put(&w, 2, "pass-word", 9);        /* 重复 type：后写覆盖语义由应用定 */
    j.bodylen = w.len;
    CHECK(!w.overflow, "JOIN 参数拼装无溢出");
    tlvr_init(&r, j.body, j.bodylen);
    char ssid[16] = "";
    int got_unknown = 0;
    while (tlvr_next(&r, &t, &v, &vl)) {
        if (t == 2)
            snprintf(ssid, sizeof ssid, "%.*s", vl, v);
        if (t == 0x77)
            got_unknown++;
    }
    CHECK(!strcmp(ssid, "pass-word") && got_unknown == 1,
          "TLV 顺序无关 + 未知 type 跳过");

    /* 3) 溢出游标：塞超容量必置位且不写越界 */
    uint8_t small[8];
    struct tlvw sw;
    tlvw_init(&sw, small, sizeof small);
    tlvw_put(&sw, 9, "0123456789ABCDEF", 16);
    CHECK(sw.overflow == 1 && sw.len == 0, "TLV 溢出置位不截断");

    /* 4) 扫描分片重组：5 片乱序 + 1 片重放 */
    struct scan_reasm sr;
    scan_reasm_init(&sr);
    uint8_t frag[3 + 16];
    int done_at = -1;
    for (int order[] = { 3, 0, 4, 1, 2 }, i = 0; i < 5; i++) {
        frag[0] = 5, frag[1] = (uint8_t)order[i], frag[2] = (uint8_t)('A' + order[i]);
        int done = scan_reasm_feed(&sr, frag, 3);
        if (done)
            done_at = order[i];
    }
    frag[0] = 5, frag[1] = 2, frag[2] = 'C';
    CHECK(done_at == 2 && !scan_reasm_feed(&sr, frag, 3),
          "扫描分片乱序攒齐 + 重放片被拒");

    /* 5) len 越界的 TLV 拒绝（线协议 bug 探测） */
    uint8_t badtlv[] = { 0x02, 0xFF, 0xFF, 'x' };
    tlvr_init(&r, badtlv, sizeof badtlv);
    CHECK(!tlvr_next(&r, &t, &v, &vl), "越界 len 的 TLV 被拒");

    printf("\n合计：PASS %d / FAIL %d\n", g_pass, g_fail);
    return g_fail ? 1 : 0;
}
