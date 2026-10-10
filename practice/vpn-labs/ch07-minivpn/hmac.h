/* hmac.h —— HMAC-SHA256（RFC 2104 结构：ipad/opad 双轮，块宽 64） */
#ifndef HMAC_H
#define HMAC_H

#include <stddef.h>
#include <stdint.h>

void hmac_sha256(const uint8_t *key, size_t keylen, const void *msg, size_t msglen,
                 uint8_t out[32]);

#endif
