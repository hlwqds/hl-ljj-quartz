/* framing.c —— 帧层实现：打包 = 头+CRC → COBS → 首尾 0x00；
 * 解析 = 状态机按 0x00 切段 → COBS 解码 → 查头 → 验 CRC → 回调。 */
#include "framing.h"
#include "cobs.h"
#include "crc32.h"
#include <string.h>

static void put16(uint8_t *p, uint16_t v)
{
    p[0] = v >> 8, p[1] = v; /* 网络序（大端），ch05 的纪律从帧层开始 */
}
static uint16_t get16(const uint8_t *p)
{
    return (uint16_t)(p[0] << 8 | p[1]);
}
static void put32(uint8_t *p, uint32_t v)
{
    p[0] = v >> 24, p[1] = v >> 16, p[2] = v >> 8, p[3] = v;
}
static uint32_t get32(const uint8_t *p)
{
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

size_t fr_pack(const struct fr_frame *f, uint8_t *out, size_t cap)
{
    uint8_t raw[8 + FR_MAX_PAYLOAD + 4];
    size_t rl = 0;
    raw[0] = FR_MAGIC0, raw[1] = FR_MAGIC1;
    raw[2] = FR_VER;
    put16(raw + 3, f->plen);
    put16(raw + 5, f->seq);
    raw[7] = f->type;
    memcpy(raw + 8, f->payload, f->plen);
    rl = 8 + f->plen;
    put32(raw + rl, crc32_ieee(raw, rl));
    rl += 4;

    uint8_t enc[2 * sizeof raw]; /* COBS 上界足够 */
    size_t el = cobs_encode(raw, rl, enc, sizeof enc);
    if (!el || cap < el + 2)
        return 0;
    out[0] = 0x00; /* 首分隔符 */
    memcpy(out + 1, enc, el);
    out[1 + el] = 0x00; /* 尾分隔符 */
    return el + 2;
}

void fr_parser_init(struct fr_parser *p, fr_sink sink, void *user)
{
    memset(p, 0, sizeof *p);
    p->sink = sink;
    p->user = user;
}

void fr_feed(struct fr_parser *p, const uint8_t *bytes, size_t n)
{
    for (size_t i = 0; i < n; i++) {
        uint8_t b = bytes[i];
        if (b == 0x00) { /* 分隔符：一段结束 */
            if (p->len == 0)
                continue; /* 空闲填充，合法且无事发生 */
            struct fr_frame f;
            uint8_t raw[8 + FR_MAX_PAYLOAD + 4];
            size_t rl = cobs_decode(p->buf, p->len, raw, sizeof raw);
            p->len = 0;
            if (!rl || rl < 8 + 4 || raw[0] != FR_MAGIC0 || raw[1] != FR_MAGIC1 ||
                raw[2] != FR_VER || get16(raw + 3) > FR_MAX_PAYLOAD) {
                p->bad_hdr++;
                continue;
            }
            size_t plen = get16(raw + 3);
            if (get32(raw + 8 + plen) != crc32_ieee(raw, 8 + plen)) {
                p->bad_crc++;
                continue; /* 差错丢弃：链路误码在此现形 */
            }
            f.seq = get16(raw + 5);
            f.type = raw[7];
            f.plen = (uint16_t)plen;
            memcpy(f.payload, raw + 8, plen);
            p->sink(&f, p->user);
        } else if (p->len < sizeof p->buf) {
            p->buf[p->len++] = b;
        } else { /* 超长段：噪声，整段丢弃重新同步 */
            p->bad_hdr++;
            p->len = 0;
        }
    }
}
