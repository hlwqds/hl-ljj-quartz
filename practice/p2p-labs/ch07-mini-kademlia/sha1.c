/* sha1.c —— SHA-1（FIPS 180-4）教科书实现
 *
 * 为什么不用系统库：Windows 没有预装的 crypto 头（bcrypt 一堆宏），
 * POSIX 的 OpenSSL 要拖依赖——协议实验室自己拥有哈希的字节级真相，
 * 也正是 ch08"piece SHA-1 防假块"教学点的底座。
 * 自检向量：sha1("abc") = a9993e364706816aba3e25717850c26c9cd0d89d
 */
#include "sha1.h"
#include <string.h>

static uint32_t rol(uint32_t v, int b) { return (v << b) | (v >> (32 - b)); }

static void sha1_block(uint32_t st[5], const uint8_t p[64])
{
    uint32_t w[80];
    for (int i = 0; i < 16; i++)
        w[i] = ((uint32_t)p[4 * i] << 24) | ((uint32_t)p[4 * i + 1] << 16) |
               ((uint32_t)p[4 * i + 2] << 8) | p[4 * i + 3];
    for (int i = 16; i < 80; i++)
        w[i] = rol(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);

    uint32_t a = st[0], b = st[1], c = st[2], d = st[3], e = st[4];
    for (int i = 0; i < 80; i++) {
        uint32_t f, k;
        if (i < 20) {
            f = (b & c) | (~b & d);
            k = 0x5A827999;
        } else if (i < 40) {
            f = b ^ c ^ d;
            k = 0x6ED9EBA1;
        } else if (i < 60) {
            f = (b & c) | (b & d) | (c & d);
            k = 0x8F1BBCDC;
        } else {
            f = b ^ c ^ d;
            k = 0xCA62C1D6;
        }
        uint32_t t = rol(a, 5) + f + e + k + w[i];
        e = d, d = c, c = rol(b, 30), b = a, a = t;
    }
    st[0] += a, st[1] += b, st[2] += c, st[3] += d, st[4] += e;
}

void sha1(const void *data, size_t len, uint8_t out[20])
{
    uint32_t st[5] = { 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0 };
    const uint8_t *p = data;

    for (size_t off = 0; off + 64 <= len; off += 64)
        sha1_block(st, p + off);

    uint8_t tail[128] = { 0 };
    size_t rem = len % 64;
    memcpy(tail, p + len - rem, rem);
    tail[rem] = 0x80;
    size_t total = (rem >= 56) ? 128 : 64;
    uint64_t bits = (uint64_t)len * 8;
    for (int i = 0; i < 8; i++)
        tail[total - 1 - i] = (uint8_t)(bits >> (8 * i));
    sha1_block(st, tail);
    if (total == 128)
        sha1_block(st, tail + 64);

    for (int i = 0; i < 5; i++) {
        out[4 * i] = (uint8_t)(st[i] >> 24);
        out[4 * i + 1] = (uint8_t)(st[i] >> 16);
        out[4 * i + 2] = (uint8_t)(st[i] >> 8);
        out[4 * i + 3] = (uint8_t)st[i];
    }
}

void sha1_hex(const uint8_t d[20], char out[41])
{
    static const char hex[] = "0123456789abcdef";
    for (int i = 0; i < 20; i++) {
        out[2 * i] = hex[d[i] >> 4];
        out[2 * i + 1] = hex[d[i] & 15];
    }
    out[40] = 0;
}
