/* framing.h —— 帧层：八字节头 + CRC32，COBS 打包，0x00 分隔，流式解析
 *
 * 线格式（ch03 §3.3）：[magic 2B][ver 1B][len 2B][seq 2B][type 1B][payload ≤480B][crc32 4B]
 * 线上形态：COBS(frame) 前后各一个 0x00 分隔符；空闲填充（全 0x00）合法。
 */
#ifndef FRAMING_H
#define FRAMING_H

#include <stddef.h>
#include <stdint.h>

#define FR_MAGIC0 0xA5
#define FR_MAGIC1 0x5A
#define FR_VER 1
#define FR_MAX_PAYLOAD 480
#define FR_TYPE_CTRL_REQ 1
#define FR_TYPE_CTRL_RSP 2
#define FR_TYPE_DATA 3
#define FR_TYPE_EVENT 4

struct fr_frame {
    uint16_t seq;
    uint8_t type;
    uint8_t payload[FR_MAX_PAYLOAD];
    uint16_t plen;
};

/* 打包：frame → 线上字节（含 COBS 与前后分隔符），返回字节数，0=缓冲不足 */
size_t fr_pack(const struct fr_frame *f, uint8_t *out, size_t cap);

/* 流式解析器：逐字节喂入（来自 SPI 交换缓冲或 UART），完整帧到达时回调 */
typedef void (*fr_sink)(struct fr_frame *f, void *user);
struct fr_parser {
    uint8_t buf[2 + 1 + 2 + 2 + 1 + FR_MAX_PAYLOAD + 4 + 4]; /* 原始帧+CRC */
    size_t len;
    fr_sink sink;
    void *user;
    long bad_crc, bad_hdr; /* 统计：坏帧计数（观测用） */
};

void fr_parser_init(struct fr_parser *p, fr_sink sink, void *user);
/* 喂一段字节（可含任意 0x00 填充、多帧相连、残帧） */
void fr_feed(struct fr_parser *p, const uint8_t *bytes, size_t n);

#endif
