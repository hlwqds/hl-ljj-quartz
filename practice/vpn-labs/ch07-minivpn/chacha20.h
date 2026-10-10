/* chacha20.h —— RFC 8439 ChaCha20 流密码（手写版，配 chachatest.c 官方向量验收） */
#ifndef CHACHA20_H
#define CHACHA20_H

#include <stddef.h>
#include <stdint.h>

/* 生成一个 64B 密钥流块（counter 为块号，从 0 起——RFC 8439 原版） */
void chacha20_block(const uint8_t key[32], uint32_t counter, const uint8_t nonce[12],
                    uint8_t out[64]);

/* 流式加解密（同一函数）：in/out 可同址 */
void chacha20_xor(const uint8_t key[32], const uint8_t nonce[12], uint32_t counter0,
                  const uint8_t *in, uint8_t *out, size_t len);

#endif
