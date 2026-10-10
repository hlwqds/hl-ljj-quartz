/* hmac.c —— HMAC-SHA256 实现
 *
 * 双轮结构的必要性（系列 ch05 §5.1）：SHA-2 有长度扩展性，
 * 直接 SHA256(key ∥ msg) 允许在不知密钥的情况下续算后缀。
 * ipad(0x36)/opad(0x5c) 两轮把密钥拌进两个独立前缀，拆掉扩展性。
 * 自检向量：HMAC-SHA256("key", "The quick brown fox jumps over the lazy dog")
 *   = f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8
 */
#include "hmac.h"
#include "sha256.h"
#include <string.h>

void hmac_sha256(const uint8_t *key, size_t keylen, const void *msg, size_t msglen,
                 uint8_t out[32])
{
    uint8_t k[64] = { 0 }, ipad[64], opad[64], inner[32];

    if (keylen > 64) /* 超长密钥先哈希折叠（RFC 2104 规定） */
        sha256(key, keylen, k);
    else
        memcpy(k, key, keylen);

    for (int i = 0; i < 64; i++) {
        ipad[i] = k[i] ^ 0x36;
        opad[i] = k[i] ^ 0x5c;
    }

    uint8_t buf[64 + 4096]; /* inner = SHA256(ipad ∥ msg) */
    memcpy(buf, ipad, 64);
    size_t take = msglen > 4096 ? 4096 : msglen; /* 演示规模；流式接口留作练习 */
    memcpy(buf + 64, msg, take);
    sha256(buf, 64 + take, inner);

    memcpy(buf, opad, 64); /* outer = SHA256(opad ∥ inner) */
    memcpy(buf + 64, inner, 32);
    sha256(buf, 96, out);
}
