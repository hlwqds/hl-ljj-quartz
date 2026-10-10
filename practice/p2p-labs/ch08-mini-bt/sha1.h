/* sha1.h —— SHA-1 单文件实现（FIPS 180-4），ch02 校验分块 / ch08 造种子共用 */
#ifndef SHA1_H
#define SHA1_H

#include <stddef.h>
#include <stdint.h>

/* 一次性接口：足够本实验室使用（分块流式更新留给读者作为练习） */
void sha1(const void *data, size_t len, uint8_t out[20]);
void sha1_hex(const uint8_t digest[20], char out[41]);

#endif
