/* chachatest.c —— ChaCha20 验收：RFC 8439 官方向量 + 加解密回环 + 文件 CLI
 *
 * 1) 无参数：跑 RFC 8439 §2.3.2 block function 测试向量（必须逐字节一致），
 *    再做 1MB 随机数据回环；
 * 2) enc <入> <出> <hexkey64> <hexnonce24>：加密文件；
 *    dec <入> <出> <hexkey64> <hexnonce24>：解密文件（sha1sum 对账用）。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "chacha20.h"

static int hex2bin(const char *hex, uint8_t *out, int cap)
{
    int n = 0;
    while (hex[0] && hex[1] && n < cap) {
        unsigned v;
        if (sscanf(hex, "%2x", &v) != 1)
            return -1;
        out[n++] = (uint8_t)v;
        hex += 2;
    }
    return n;
}

static void dump(const char *tag, const uint8_t *p, int n)
{
    printf("%s", tag);
    for (int i = 0; i < n; i++)
        printf("%02x", p[i]);
    printf("\n");
}

static int rfc_vector(void) /* RFC 8439 §2.3.2 */
{
    uint8_t key[32], nonce[12], out[64];
    for (int i = 0; i < 32; i++)
        key[i] = (uint8_t)i;
    hex2bin("000000090000004a00000000", nonce, 12);
    const uint8_t want[64] = {
        0x10, 0xf1, 0xe7, 0xe4, 0xd1, 0x3b, 0x59, 0x15, 0x50, 0x0f, 0xdd, 0x1f,
        0xa3, 0x20, 0x71, 0xc4, 0xc7, 0xd1, 0xf4, 0xc7, 0x33, 0xc0, 0x68, 0x03,
        0x04, 0x22, 0xaa, 0x9a, 0xc3, 0xd4, 0x6c, 0x4e, 0xd2, 0x82, 0x64, 0x46,
        0x07, 0x9f, 0xaa, 0x09, 0x14, 0xc2, 0xd7, 0x05, 0xd9, 0x8b, 0x02, 0xa2,
        0xb5, 0x12, 0x9c, 0xd1, 0xde, 0x16, 0x4e, 0xb9, 0xcb, 0xd0, 0x83, 0xe8,
        0xa2, 0x50, 0x3c, 0x4e
    };
    chacha20_block(key, 1, nonce, out);
    dump("  实测 keystream 块: ", out, 64);
    dump("  RFC  期望值     : ", want, 64);
    return memcmp(out, want, 64) == 0;
}

static unsigned rng_state = 0x12345678u;
static uint8_t rnd(void)
{
    rng_state ^= rng_state << 13;
    rng_state ^= rng_state >> 17;
    rng_state ^= rng_state << 5;
    return (uint8_t)rng_state;
}

static int roundtrip(void)
{
    enum { N = 1 << 20 };
    uint8_t *a = malloc(N), *b = malloc(N), *c = malloc(N);
    uint8_t key[32], nonce[12];
    for (int i = 0; i < 32; i++)
        key[i] = rnd();
    for (int i = 0; i < 12; i++)
        nonce[i] = rnd();
    for (int i = 0; i < N; i++)
        a[i] = rnd();
    chacha20_xor(key, nonce, 1, a, b, N);  /* 加密 */
    chacha20_xor(key, nonce, 1, b, c, N);  /* 解密（同函数） */
    int ok = memcmp(a, c, N) == 0;
    printf("1MiB 随机数据回环：%s（密文前 16B: ", ok ? "PASS" : "FAIL");
    for (int i = 0; i < 16; i++)
        printf("%02x", b[i]);
    printf("…）\n");
    free(a), free(b), free(c);
    return ok;
}

int main(int argc, char **argv)
{
    if (argc == 6 && (!strcmp(argv[1], "enc") || !strcmp(argv[1], "dec"))) {
        uint8_t key[32], nonce[12];
        if (hex2bin(argv[4], key, 32) != 32 || hex2bin(argv[5], nonce, 12) != 12) {
            fprintf(stderr, "key 需 64 位 hex、nonce 需 24 位 hex\n");
            return 1;
        }
        FILE *fi = fopen(argv[2], "rb"), *fo = fopen(argv[3], "wb");
        if (!fi || !fo) {
            perror("open");
            return 1;
        }
        uint8_t in[64], out[64];
        size_t n;
        while ((n = fread(in, 1, sizeof in, fi)) > 0) {
            chacha20_xor(key, nonce, 1, in, out, n);
            fwrite(out, 1, n, fo);
        }
        fclose(fi), fclose(fo);
        printf("%s 完成（同 key+nonce+counter1 可逆）\n", argv[1]);
        return 0;
    }

    printf("== RFC 8439 §2.3.2 block function 向量 ==\n");
    int ok1 = rfc_vector();
    printf("向量比对：%s\n\n", ok1 ? "PASS" : "FAIL");
    int ok2 = roundtrip();
    return ok1 && ok2 ? 0 : 1;
}
