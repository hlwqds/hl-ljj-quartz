/*
 * onvif_digest 宿主单元测试（ch17 §17.5.3）。
 *
 * 运行：  ./run.sh   （等价 gcc -I stub -I ../include test_digest.c ../src/onvif_digest.c）
 * 依赖注入：md5 → 本文件内 RFC 1321 参考实现（正确性由 RFC 2617 §3.5 规范向量
 *           端到端背书）；nonce → 测试内确定性序列。
 *
 * 覆盖：质询构建 / 头解析（带引号与无引号）/ 正路径 / 错口令 / 未知 nonce /
 *       一次性重放 / 非 Digest 头 / 缺字段 / realm 参与哈希。
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include "esp_stub.h"
#include "onvif_digest.h"
#include <psa/crypto.h>

/* ---- 紧凑 MD5（RFC 1321 参考实现风格，公开域算法；正确性由规范向量背书） ---- */
static void rfc1321_md5(const char *in, size_t len, uint8_t out[16]);

/* ---- 确定性 nonce 序列：NONCE1..NONCE8（可预测，便于重放断言） ---- */
static int nonce_seq;
static void test_nonce(char out[DIGEST_NONCE_HEX + 1])
{
    snprintf(out, DIGEST_NONCE_HEX + 1, "%032x", 0xABCDEF00u + (unsigned)nonce_seq++);
}

static int failures;
#define CHECK(cond, name)                                                     \
    do {                                                                      \
        if (cond) {                                                           \
            printf("  ok   %s\n", name);                                      \
        } else {                                                              \
            printf("  FAIL %s\n", name);                                      \
            failures++;                                                       \
        }                                                                     \
    } while (0)

/* 组一段 Authorization 头（带引号形态） */
static int build_auth(char *out, size_t max, const char *user, const char *nonce,
                      const char *uri, const char *resp, const char *realm)
{
    /* response 由被测模块同一公式重算（HA1/HA2 用组件同款 md5 注入函数算）——
     * 不能用组件内部函数，这里手拼：MD5 由 rfc1321_md5 提供 */
    extern void test_md5_hex(const char *in, size_t len, char out[33]);
    char ha1[33], ha2[33], resp_calc[33], cat[256];
    snprintf(cat, sizeof(cat), "%s:%s:%s", user, realm, "korvo-secret");
    test_md5_hex(cat, strlen(cat), ha1);
    snprintf(cat, sizeof(cat), "%s:%s", "DESCRIBE", uri);
    test_md5_hex(cat, strlen(cat), ha2);
    snprintf(cat, sizeof(cat), "%s:%s:%s", ha1, nonce, ha2);
    test_md5_hex(cat, strlen(cat), resp_calc);
    if (resp) {
        resp_calc[0] = 0; /* 用调用方给的坏 response */
        snprintf(resp_calc, sizeof(resp_calc), "%s", resp);
    }
    return snprintf(out, max,
                    "Authorization: Digest username=\"%s\", realm=\"%s\", "
                    "nonce=\"%s\", uri=\"%s\", response=\"%s\"",
                    user, realm, nonce, uri, resp_calc);
}

int main(void)
{
    onvif_digest_bind(rfc1321_md5, test_nonce);

    /* T-U1: RFC 2617 §3.5 规范向量（端到端 md5 正确性） */
    CHECK(onvif_digest_selftest(), "RFC2617 selftest vector");

    /* T-U2: 质询构建 */
    char val[192];
    onvif_digest_challenge_t ch;
    int n = onvif_digest_challenge("onvif@korvo-1", &ch, val, sizeof(val));
    CHECK(n > 40 && strstr(val, "Digest realm=\"onvif@korvo-1\"") != NULL &&
              strstr(val, "nonce=\"") != NULL,
          "challenge format");

    /* T-U3: 正路径 —— DESCRIBE 带正确凭据 → 0 */
    char auth[512];
    build_auth(auth, sizeof(auth), "admin", ch.nonce, "rtsp://x/mjpeg", NULL,
               "onvif@korvo-1");
    onvif_digest_auth_t parsed;
    CHECK(onvif_digest_verify(auth, "DESCRIBE", "rtsp://x/mjpeg", "admin",
                              "korvo-secret", "onvif@korvo-1", &parsed) == 0,
          "verify ok path");

    /* T-U4: 同 nonce 重放 → -2（一次性消费） */
    CHECK(onvif_digest_verify(auth, "DESCRIBE", "rtsp://x/mjpeg", "admin",
                              "korvo-secret", "onvif@korvo-1", NULL) == -2,
          "nonce replay rejected");

    /* T-U5: 未知 nonce → -2 */
    char auth_unknown[512];
    build_auth(auth_unknown, sizeof(auth_unknown), "admin",
               "ffffffffffffffffffffffffffffffff", "rtsp://x/mjpeg", NULL,
               "onvif@korvo-1");
    CHECK(onvif_digest_verify(auth_unknown, "DESCRIBE", "rtsp://x/mjpeg", "admin",
                              "korvo-secret", "onvif@korvo-1", NULL) == -2,
          "unknown nonce rejected");

    /* T-U6: 错口令 → 1（凭据错，nonce 退还） */
    char val2[192];
    onvif_digest_challenge_t ch2;
    onvif_digest_challenge("onvif@korvo-1", &ch2, val2, sizeof(val2));
    char bad[512];
    build_auth(bad, sizeof(bad), "admin", ch2.nonce, "rtsp://x/mjpeg", NULL,
               "onvif@korvo-1");
    /* 把 response 换成错口令算的（模拟客户端拿错 pass） */
    CHECK(onvif_digest_verify(bad, "DESCRIBE", "rtsp://x/mjpeg", "admin",
                              "wrong-pass", "onvif@korvo-1", NULL) == 1,
          "wrong pass rejected");
    /* nonce 已退还：同 nonce 正确凭据可再试（RFC 行为） */
    CHECK(onvif_digest_verify(bad, "DESCRIBE", "rtsp://x/mjpeg", "admin",
                              "korvo-secret", "onvif@korvo-1", NULL) == 0,
          "nonce returned after cred fail");

    /* T-U7: 非 Digest 头 → -1 */
    CHECK(onvif_digest_verify("Authorization: Basic YWRtaW4=", "DESCRIBE",
                              "rtsp://x/mjpeg", "admin", "korvo-secret",
                              "onvif@korvo-1", NULL) == -1,
          "basic auth rejected");

    /* T-U8: 缺 response 字段 → -1 */
    CHECK(onvif_digest_verify(
              "Authorization: Digest username=\"admin\", nonce=\"00000000000000000000000000000000\", uri=\"/x\"",
              "DESCRIBE", "rtsp://x/mjpeg", "admin", "korvo-secret",
              "onvif@korvo-1", NULL) == -1,
          "missing response rejected");

    /* T-U9: 无引号形态（ffmpeg 某些版本） */
    char val3[192];
    onvif_digest_challenge_t ch3;
    onvif_digest_challenge("onvif@korvo-1", &ch3, val3, sizeof(val3));
    char plain[512], ha1[33], ha2[33], resp3[33], cat[256];
    extern void test_md5_hex(const char *in, size_t len, char out[33]);
    snprintf(cat, sizeof(cat), "admin:onvif@korvo-1:korvo-secret");
    test_md5_hex(cat, strlen(cat), ha1);
    snprintf(cat, sizeof(cat), "DESCRIBE:rtsp://x/mjpeg");
    test_md5_hex(cat, strlen(cat), ha2);
    snprintf(cat, sizeof(cat), "%s:%s:%s", ha1, ch3.nonce, ha2);
    test_md5_hex(cat, strlen(cat), resp3);
    snprintf(plain, sizeof(plain),
             "Authorization: Digest username=admin, realm=\"onvif@korvo-1\", "
             "nonce=%s, uri=rtsp://x/mjpeg, response=%s",
             ch3.nonce, resp3);
    CHECK(onvif_digest_verify(plain, "DESCRIBE", "rtsp://x/mjpeg", "admin",
                              "korvo-secret", "onvif@korvo-1", NULL) == 0,
          "unquoted form accepted");

    /* T-U10: realm 参与哈希——换 realm 的头应被拒 */
    char val4[192];
    onvif_digest_challenge_t ch4;
    onvif_digest_challenge("other-realm", &ch4, val4, sizeof(val4));
    char wrong_realm[512];
    build_auth(wrong_realm, sizeof(wrong_realm), "admin", ch4.nonce,
               "rtsp://x/mjpeg", NULL, "other-realm");
    CHECK(onvif_digest_verify(wrong_realm, "DESCRIBE", "rtsp://x/mjpeg", "admin",
                              "korvo-secret", "onvif@korvo-1", NULL) == 1,
          "wrong realm rejected");

    printf(failures ? "\n%d FAILURES\n" : "\nALL PASS\n", failures);
    return failures ? 1 : 0;
}

/* ---- 紧凑 MD5 实现（RFC 1321, 公开域参考风格） ---- */

static uint32_t rol(uint32_t x, int c) { return (x << c) | (x >> (32 - c)); }

static void md5_block(uint32_t st[4], const uint8_t blk[64])
{
    static const uint32_t K[64] = {
        0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a,
        0xa8304613, 0xfd469501, 0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
        0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821, 0xf61e2562, 0xc040b340,
        0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
        0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8,
        0x676f02d9, 0x8d2a4c8a, 0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
        0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70, 0x289b7ec6, 0xeaa127fa,
        0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
        0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92,
        0xffeff47d, 0x85845dd1, 0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
        0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391};
    static const int R[64] = {7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
                              5, 9,  14, 20, 5, 9,  14, 20, 5, 9,  14, 20, 5, 9,  14, 20,
                              4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
                              6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21};
    uint32_t M[16];
    memcpy(M, blk, 64);
    uint32_t a = st[0], b = st[1], c = st[2], d = st[3];
    for (int i = 0; i < 64; i++) {
        uint32_t f;
        int g;
        if (i < 16)      { f = (b & c) | (~b & d);        g = i; }
        else if (i < 32) { f = (d & b) | (~d & c);        g = (5 * i + 1) % 16; }
        else if (i < 48) { f = b ^ c ^ d;                 g = (3 * i + 5) % 16; }
        else             { f = c ^ (b | ~d);              g = (7 * i) % 16; }
        uint32_t tmp = d;
        d = c;
        c = b;
        b = b + rol(a + f + K[i] + M[g], R[i]);
        a = tmp;
    }
    st[0] += a; st[1] += b; st[2] += c; st[3] += d;
}

static void rfc1321_md5(const char *in, size_t len, uint8_t out[16])
{
    uint32_t st[4] = {0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476};
    size_t full = len / 64;
    for (size_t i = 0; i < full; i++) {
        md5_block(st, (const uint8_t *)in + i * 64);
    }
    uint8_t tail[128];
    size_t rem = len - full * 64;
    memcpy(tail, in + full * 64, rem);
    tail[rem++] = 0x80;
    size_t padded = (rem <= 56) ? 64 : 128;
    memset(tail + rem, 0, padded - rem);
    uint64_t bits = (uint64_t)len * 8;
    memcpy(tail + padded - 8, &bits, 8); /* 小端长度 */
    md5_block(st, tail);
    if (padded == 128) {
        md5_block(st, tail + 64);
    }
    for (int i = 0; i < 4; i++) {
        out[i * 4] = (uint8_t)(st[i] & 0xff);
        out[i * 4 + 1] = (uint8_t)((st[i] >> 8) & 0xff);
        out[i * 4 + 2] = (uint8_t)((st[i] >> 16) & 0xff);
        out[i * 4 + 3] = (uint8_t)((st[i] >> 24) & 0xff);
    }
}

/* 供测试体使用的 hex 包装 */
void test_md5_hex(const char *in, size_t len, char out[33])
{
    uint8_t d[16];
    rfc1321_md5(in, len, d);
    static const char hex[] = "0123456789abcdef";
    for (int i = 0; i < 16; i++) {
        out[i * 2] = hex[d[i] >> 4];
        out[i * 2 + 1] = hex[d[i] & 0xf];
    }
    out[32] = '\0';
}

/* esp_fill_random 桩（默认 nonce 生成路径在注入后不可达） */
void esp_fill_random(void *buf, size_t len) { memset(buf, 0x5a, len); }

/* mbedtls_md5 / psa_hash_compute 符号桩（注入后均不可达） */
int mbedtls_md5(const unsigned char *in, size_t len, unsigned char out[16])
{
    (void)in; (void)len; (void)out;
    return -1;
}

psa_status_t psa_hash_compute(psa_algorithm_t alg, const uint8_t *input, size_t input_len,
                              uint8_t *hash, size_t hash_size, size_t *hash_length)
{
    (void)alg; (void)input; (void)input_len; (void)hash; (void)hash_size;
    (void)hash_length;
    return -1;
}
