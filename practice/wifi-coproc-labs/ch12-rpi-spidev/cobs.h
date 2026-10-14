/* cobs.h —— COBS（Consistent Overhead Byte Stuffing）透明打包
 *
 * 输出不含 0x00，因此可用 0x00 作帧分隔符；开销 ≤1B/254B（与内容无关）。
 * 分隔符由帧层添加（见 framing.c），本模块只做纯打包/解包。
 */
#ifndef COBS_H
#define COBS_H

#include <stddef.h>
#include <stdint.h>

/* out 需容量 ≥ len + 1 + len/254；返回写入字节数，失败返回 0（仅缓冲不足） */
size_t cobs_encode(const uint8_t *in, size_t len, uint8_t *out, size_t cap);
/* in 不含分隔符；返回解码字节数，0=流格式非法 */
size_t cobs_decode(const uint8_t *in, size_t len, uint8_t *out, size_t cap);

#endif
