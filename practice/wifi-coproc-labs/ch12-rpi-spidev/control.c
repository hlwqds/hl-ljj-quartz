/* control.c —— 控制通道实现：TLV 编解码、请求/应答拼装、扫描分片重组 */
#include "control.h"
#include <string.h>

/* ---- 编码游标 ---- */

void tlvw_init(struct tlvw *w, uint8_t *buf, size_t cap)
{
    w->buf = buf, w->cap = cap, w->len = 0, w->overflow = 0;
}

void tlvw_put(struct tlvw *w, uint8_t type, const void *val, uint16_t len)
{
    if (w->len + 3 + len > w->cap) {
        w->overflow = 1; /* 溢出置位不截断：调用方据此换分片策略 */
        return;
    }
    w->buf[w->len++] = type;
    w->buf[w->len++] = len >> 8, w->buf[w->len++] = len; /* len 是 value 的字节数 */
    memcpy(w->buf + w->len, val, len);
    w->len += len;
}

void tlvw_put_u8(struct tlvw *w, uint8_t type, uint8_t v)
{
    tlvw_put(w, type, &v, 1);
}
void tlvw_put_u16(struct tlvw *w, uint8_t type, uint16_t v)
{
    uint8_t b[2] = { v >> 8, v }; /* 网络序纪律 */
    tlvw_put(w, type, b, 2);
}
void tlvw_put_u32(struct tlvw *w, uint8_t type, uint32_t v)
{
    uint8_t b[4] = { v >> 24, v >> 16, v >> 8, v };
    tlvw_put(w, type, b, 4);
}

/* ---- 解码游标 ---- */

void tlvr_init(struct tlvr *r, const uint8_t *buf, size_t len)
{
    r->buf = buf, r->len = len, r->pos = 0;
}

int tlvr_next(struct tlvr *r, uint8_t *type, const uint8_t **val, uint16_t *len)
{
    if (r->pos + 3 > r->len)
        return 0;
    *type = r->buf[r->pos];
    *len = (uint16_t)(r->buf[r->pos + 1] << 8 | r->buf[r->pos + 2]);
    if (r->pos + 3 + *len > r->len)
        return 0; /* len 越界=线协议 bug，直接拒绝 */
    *val = r->buf + r->pos + 3;
    r->pos += 3 + *len;
    return 1;
}

/* ---- 请求/应答 ---- */

static void put16(uint8_t *p, uint16_t v)
{
    p[0] = v >> 8, p[1] = v;
}
static uint16_t get16(const uint8_t *p)
{
    return (uint16_t)(p[0] << 8 | p[1]);
}

size_t ctl_pack_req(const struct ctl_msg *m, uint8_t *out, size_t cap)
{
    if (cap < 4 + m->bodylen)
        return 0;
    put16(out, m->cmd);
    put16(out + 2, m->req_id);
    memcpy(out + 4, m->body, m->bodylen);
    return 4 + m->bodylen;
}

size_t ctl_pack_rsp(const struct ctl_msg *m, uint8_t *out, size_t cap)
{
    if (cap < 5 + m->bodylen)
        return 0;
    put16(out, m->cmd);
    put16(out + 2, m->req_id);
    out[4] = m->status;
    memcpy(out + 5, m->body, m->bodylen);
    return 5 + m->bodylen;
}

int ctl_parse(const uint8_t *in, size_t len, int is_rsp, struct ctl_msg *m)
{
    if (len < (is_rsp ? 5u : 4u))
        return 0;
    m->cmd = get16(in);
    m->req_id = get16(in + 2);
    m->status = is_rsp ? in[4] : 0;
    size_t off = is_rsp ? 5 : 4;
    m->bodylen = len - off > sizeof m->body ? 0 : len - off;
    memcpy(m->body, in + off, m->bodylen);
    return 1;
}

/* ---- 扫描分片重组：分片载荷 [total(1)][index(1)][data…] ---- */

void scan_reasm_init(struct scan_reasm *s)
{
    memset(s, 0, sizeof *s);
}

int scan_reasm_feed(struct scan_reasm *s, const uint8_t *tlv_val, uint16_t tlv_len)
{
    if (tlv_len < 2 || tlv_len > 2 + 16)
        return 0;
    uint8_t total = tlv_val[0], idx = tlv_val[1];
    if (total == 0 || total > 64 || idx >= total)
        return 0;
    if (s->total == 0)
        s->total = total; /* 首片定总数 */
    else if (s->total != total)
        return 0; /* 新一轮扫描开始前旧片作废 */
    if (s->seen[idx])
        return 0; /* 重放的分片 */
    s->seen[idx] = 1;
    uint8_t n = (uint8_t)(tlv_len - 2 > 16 ? 16 : tlv_len - 2);
    memcpy(s->buf[idx], tlv_val + 2, n);
    return ++s->got == s->total; /* 攒齐才返回 1 */
}
