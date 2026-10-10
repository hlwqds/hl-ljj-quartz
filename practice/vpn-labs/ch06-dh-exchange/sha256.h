/* sha256.h —— SHA-256 单文件实现（FIPS 180-4），HMAC 的底座 */
#ifndef SHA256_H
#define SHA256_H

#include <stddef.h>
#include <stdint.h>

void sha256(const void *data, size_t len, uint8_t out[32]);
void sha256_hex(const uint8_t d[32], char out[65]);

#endif
