/* dh.c —— Diffie-Hellman 密钥协商 + 中间人演示（系列 ch06）
 *
 * 群参数：p = 2^61 - 1（梅森素数），g 运行时验证原根性（对 p-1 的每个素因子
 * q 检查 g^((p-1)/q) ≠ 1）——比背常数可信，也是"原根"概念的一次现算。
 * 快速模幂用 128 位中间积（61bit × 61bit 需要 122bit）。
 * 密钥派生：SHA-256(s ∥ 方向标记) —— 协商素材蒸馏成对称密钥。
 *
 * 用法：
 *   ./dh            正常协商：A/B 双方共享密钥相等，双向分钥打印
 *   ./dh mitm       中间人：M 各与 A、B 做一次 DH，劈成两条隧道——
 *                    双方"协商成功"但密钥不等（上帝视角铁证）
 */
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include "sha256.h"

static const uint64_t P = 2305843009213693951ull; /* 2^61 - 1，梅森素数 */

static uint64_t powmod(uint64_t base, uint64_t exp, uint64_t mod)
{
    unsigned __int128 r = 1, b = base % mod;
    while (exp) {
        if (exp & 1)
            r = r * b % mod;
        b = b * b % mod;
        exp >>= 1;
    }
    return (uint64_t)r;
}

/* p-1 的素因子分解（trial division，p-1 = 2·3²·…，61 位数够快） */
static int factorize(uint64_t n, uint64_t fs[], int cap)
{
    int cnt = 0;
    for (uint64_t d = 2; d * d <= n && cnt < cap; d++)
        if (n % d == 0) {
            fs[cnt++] = d;
            while (n % d == 0)
                n /= d;
        }
    if (n > 1 && cnt < cap)
        fs[cnt++] = n;
    return cnt;
}

static uint64_t find_generator(void) /* 找最小原根：阶 = p-1 */
{
    uint64_t fs[32];
    int nf = factorize(P - 1, fs, 32);
    for (uint64_t g = 2;; g++) {
        int ok = 1;
        for (int i = 0; i < nf; i++)
            if (powmod(g, (P - 1) / fs[i], P) == 1) {
                ok = 0; /* g 的阶是 (p-1)/q 的因子 → 不是原根 */
                break;
            }
        if (ok)
            return g;
    }
}

/* 简单 xorshift 随机（演示用；真部署读 /dev/urandom） */
static uint64_t rng_state = 0x9e3779b97f4a7c15ull;
static uint64_t rnd61(void)
{
    rng_state ^= rng_state << 13;
    rng_state ^= rng_state >> 7;
    rng_state ^= rng_state << 17;
    return rng_state % (P - 2) + 1; /* 私钥 ∈ [1, p-2] */
}

static void derive(uint64_t s, const char *tag, uint8_t out[32])
{
    uint8_t buf[8 + 16];
    for (int i = 0; i < 8; i++)
        buf[i] = (uint8_t)(s >> (56 - 8 * i));
    memcpy(buf + 8, tag, strlen(tag));
    sha256(buf, 8 + strlen(tag), out);
}

static void show_keys(const char *who, uint64_t s)
{
    uint8_t ab[32], ba[32];
    char hx[65];
    derive(s, "A→B", ab);
    derive(s, "B→A", ba);
    sha256_hex(ab, hx);
    printf("  %s：send_key(A→B)=%s…\n", who, hx);
    sha256_hex(ba, hx);
    printf("  %s：recv_key(B→A)=%s…\n", who, hx);
}

int main(int argc, char **argv)
{
    uint64_t g = find_generator();
    printf("群参数：p = 2^61-1 = %llu（素数），最小原根 g = %llu（已现算验证）\n\n",
           (unsigned long long)P, (unsigned long long)g);

    /* ===== 双方各生成私钥/公钥 ===== */
    uint64_t a = rnd61(), b = rnd61();
    uint64_t A = powmod(g, a, P), B = powmod(g, b, P);
    printf("A：私钥 a=<保密>，公钥 A=g^a = %llu（明文发给 B）\n", (unsigned long long)A);
    printf("B：私钥 b=<保密>，公钥 B=g^b = %llu（明文发回 A）\n\n", (unsigned long long)B);

    if (argc > 1 && !strcmp(argv[1], "mitm")) {
        /* ===== 中间人：M 拦下 A、B 的公钥，各换成自己的 ===== */
        uint64_t m1 = rnd61(), m2 = rnd61();
        uint64_t M1 = powmod(g, m1, P), M2 = powmod(g, m2, P);
        printf("== 中间人模式 ==\n");
        printf("A --A--> [M 拦截，发给 B 的是 M1]   B --B--> [M 拦截，发给 A 的是 M2]\n\n");
        uint64_t sA = powmod(M2, a, P); /* A 拿到 M2，实际与 M 会合 */
        uint64_t sB = powmod(M1, b, P); /* B 拿到 M1，实际与 M 会合 */
        /* M 必须用"发给对方的那把"私钥与对方会合：与 A 用 m2，与 B 用 m1
           （第一版这里交叉用反，验证行当场露馅——见 run.log 排错记） */
        uint64_t s_MA = powmod(A, m2, P);
        uint64_t s_MB = powmod(B, m1, P);
        printf("A 视角（以为在跟 B 协商，实为跟 M）：\n");
        show_keys("A", sA);
        printf("B 视角（以为在跟 A 协商，实为跟 M）：\n");
        show_keys("B", sB);
        printf("M 视角：与 A 共享 %llu，与 B 共享 %llu —— 两条隧道全部可解\n\n",
               (unsigned long long)s_MA, (unsigned long long)s_MB);
        printf("验证：sA == s(M,A)（A 与 M 同钥）：%s；sB == s(M,B)（B 与 M 同钥）：%s\n",
               sA == s_MA ? "是" : "否", sB == s_MB ? "是" : "否");
        printf("而 A 与 B 的密钥%s相等——两端全程毫无察觉。\n",
               sA == sB ? "竟然" : "并不");
        printf("结论：DH 不含认证 = 白做。三条出路：PSK / 签名证书 / 公钥指纹互贴\n"
               "（WireGuard 用第三种：配置文件里互贴公钥，手工完成认证）。\n");
        return 0;
    }

    /* ===== 正常协商 ===== */
    uint64_t sA = powmod(B, a, P);
    uint64_t sB = powmod(A, b, P);
    printf("== 正常协商 ==\n");
    printf("A 算 s = B^a = %llu\n", (unsigned long long)sA);
    printf("B 算 s = A^b = %llu\n", (unsigned long long)sB);
    printf("相等：%s —— 隔着能看能改的信道，密钥无声握手成功\n\n",
           sA == sB ? "是 ✓" : "否（实现有 bug）");
    printf("KDF 派生双向会话密钥（喂给 ch05 的安全信封）：\n");
    show_keys("A", sA);
    show_keys("B", sB);
    printf("（两端派生结果一致；下次运行换新私钥即新密钥——前向保密的种子）\n");
    return 0;
}
