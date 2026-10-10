/* chacha20.c —— RFC 8439 ChaCha20 教科书实现
 *
 * 状态 16 个 32 位字（4×4）：常量 4 + 密钥 8 + 计数器 1 + nonce 3。
 * 20 轮 = 10 ×（列 quarter round ×4 + 对角线 quarter round ×4），
 * 每块输出 = 混合态 + 初始态（加法喂回，防可逆）。全 little-endian。
 * 三大易错点（都被 chachatest.c 的官方向量钉死）：
 *   ① 末态必须加回初始态；② counter 从 0 起（TLS 变体从 1，别混）；
 *   ③ 字节装填全按小端。
 */
#include "chacha20.h"
#include <string.h>

static uint32_t rotl(uint32_t v, int n)
{
    return (v << n) | (v >> (32 - n));
}

static uint32_t le32(const uint8_t *p)
{
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 |
           (uint32_t)p[3] << 24;
}

static void qround(uint32_t *s, int a, int b, int c, int d)
{
    s[a] += s[b];
    s[d] ^= s[a];
    s[d] = rotl(s[d], 16);
    s[c] += s[d];
    s[b] ^= s[c];
    s[b] = rotl(s[b], 12);
    s[a] += s[b];
    s[d] ^= s[a];
    s[d] = rotl(s[d], 8);
    s[c] += s[d];
    s[b] ^= s[c];
    s[b] = rotl(s[b], 7);
}

void chacha20_block(const uint8_t key[32], uint32_t counter, const uint8_t nonce[12],
                    uint8_t out[64])
{
    static const uint32_t CONST[4] = { 0x61707865, 0x3320646e, 0x79622d32, 0x6b206574 };
    uint32_t init[16], st[16];

    init[0] = CONST[0], init[1] = CONST[1], init[2] = CONST[2], init[3] = CONST[3];
    for (int i = 0; i < 8; i++)
        init[4 + i] = le32(key + 4 * i);
    init[12] = counter;
    init[13] = le32(nonce);
    init[14] = le32(nonce + 4);
    init[15] = le32(nonce + 8);
    memcpy(st, init, sizeof st);

    for (int i = 0; i < 10; i++) { /* 10 个双轮 = 20 轮 */
        qround(st, 0, 4, 8, 12);  /* 列 */
        qround(st, 1, 5, 9, 13);
        qround(st, 2, 6, 10, 14);
        qround(st, 3, 7, 11, 15);
        qround(st, 0, 5, 10, 15); /* 对角线 */
        qround(st, 1, 6, 11, 12);
        qround(st, 2, 7, 8, 13);
        qround(st, 3, 4, 9, 14);
    }

    for (int i = 0; i < 16; i++) { /* 末态 + 初始态，小端吐出 */
        uint32_t w = st[i] + init[i];
        out[4 * i] = (uint8_t)w;
        out[4 * i + 1] = (uint8_t)(w >> 8);
        out[4 * i + 2] = (uint8_t)(w >> 16);
        out[4 * i + 3] = (uint8_t)(w >> 24);
    }
}

void chacha20_xor(const uint8_t key[32], const uint8_t nonce[12], uint32_t counter0,
                  const uint8_t *in, uint8_t *out, size_t len)
{
    uint8_t ks[64];
    for (size_t off = 0; off < len; off += 64) {
        chacha20_block(key, counter0++, nonce, ks);
        size_t n = len - off < 64 ? len - off : 64;
        for (size_t i = 0; i < n; i++)
            out[off + i] = in[off + i] ^ ks[i];
    }
}
