/* crc32.c —— 按位实现（~10 行，无查表；吞吐敏感时再换 256×4B 查表版，结果一致） */
#include "crc32.h"

uint32_t crc32_ieee(const void *data, size_t len)
{
    const uint8_t *p = data;
    uint32_t crc = 0xFFFFFFFF; /* 初值全 1（反射式惯例） */
    for (size_t i = 0; i < len; i++) {
        crc ^= p[i];
        for (int b = 0; b < 8; b++)
            crc = (crc >> 1) ^ (0xEDB88320u & (-(int32_t)(crc & 1)));
    }
    return crc ^ 0xFFFFFFFF; /* 终值取反 */
}
