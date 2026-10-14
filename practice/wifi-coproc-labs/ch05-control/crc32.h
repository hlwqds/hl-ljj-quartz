/* crc32.h —— CRC-32（IEEE 802.3，反射式，多项式 0xEDB88320）
 * 自检向量："123456789" → 0xCBF43926（test.c 与 zlib.crc32 双重对拍） */
#ifndef CRC32_H
#define CRC32_H

#include <stddef.h>
#include <stdint.h>

uint32_t crc32_ieee(const void *data, size_t len);

#endif
