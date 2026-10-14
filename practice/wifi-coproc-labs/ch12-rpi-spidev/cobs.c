/* cobs.c —— COBS 编解码（Cheshire & Baker 1999 的经典块指针实现）
 *
 * 编码直觉：每个 0x00 被替换成"距下一个零的距离码"，开头补总距码——
 * 输出永远没有 0x00。254 字节块边界：连续 254 个非零字节要插入 0xFF
 * 强制开新块（test.c 的边界用例专踩这里）。
 */
#include "cobs.h"

size_t cobs_encode(const uint8_t *in, size_t len, uint8_t *out, size_t cap)
{
    size_t need = len + 1 + len / 254; /* 最坏开销上界 */
    if (cap < need)
        return 0;

    size_t oi = 0;      /* 输出游标 */
    size_t code_idx = oi++; /* 当前块的距离码位置 */
    uint8_t code = 1;   /* 距下一个零的距离（至少 1） */

    for (size_t i = 0; i < len; i++) {
        if (in[i] == 0x00) {
            out[code_idx] = code; /* 本块到此为止 */
            code_idx = oi++;
            code = 1;
        } else {
            out[oi++] = in[i];
            code++;
            if (code == 0xFF) { /* 254 个非零：满块，防止距离码溢出 */
                out[code_idx] = code;
                code_idx = oi++;
                code = 1;
            }
        }
    }
    out[code_idx] = code; /* 收尾码：指向"帧尾的隐式零" */
    return oi;
}

size_t cobs_decode(const uint8_t *in, size_t len, uint8_t *out, size_t cap)
{
    size_t oi = 0;
    size_t i = 0;
    while (i < len) {
        uint8_t code = in[i++];
        if (code == 0x00)
            return 0; /* 编码后的流里不该有零（帧层负责剥分隔符） */
        for (uint8_t j = 1; j < code && i < len; j++)
            if (oi >= cap)
                return 0;
            else
                out[oi++] = in[i++];
        if (code < 0xFF && i < len) /* 隐式零：块结束处还原一个 0x00 */
            if (oi >= cap)
                return 0;
            else
                out[oi++] = 0x00;
    }
    return oi;
}
