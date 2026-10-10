/* secure.c —— 安全信封收发端 + 攻击注入实验（系列 ch05 §5.2–5.3）
 *
 * 帧格式（Encrypt-then-MAC）：
 *   [ctr(8B 大端)][ciphertext = ChaCha20(明文)][tag = HMAC-SHA256(mac_key, ctr‖ct)]
 * nonce 布局：12B = [方向魔数(4B)][帧计数器(8B)]——(key, nonce) 每帧唯一，
 * 且计数器本身被 MAC 覆盖，换旧计数器配旧密文的路也焊死。
 * 接收三步（顺序即安全）：验签（常量时间）→ 滑动窗口查重放 → 解密。
 *
 * 用法：
 *   ./secure            正常收发（帧 1..5 顺序）
 *   ./secure reorder    窗口内乱序：1,4,2,5,3 —— 全部放行
 *   ./secure replay     发 1..5 后重发 3 —— 重放拒绝
 *   ./secure tamper     第 4 帧翻转密文 1 比特 —— MAC 拒收
 *   ./secure old        先冲到 ctr=200 再发 ctr=100 —— 窗口外拒绝
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "chacha20.h"
#include "hmac.h"
#include "sha256.h"

#define WINDOW 64

/* 固定会话密钥（演示可复现；真部署由 ch06 的交换派生） */
static const uint8_t ENC_KEY[32] = "0123456789abcdef0123456789abcdef";
static const uint8_t MAC_KEY[32] = "fedcba9876543210fedcba9876543210";
static const uint8_t DIR_MAGIC[4] = { 'A', '2', 'B', 0x01 }; /* 方向标记入 nonce */

struct rx {
    uint64_t highest;   /* 已见最高计数器 */
    uint64_t bitmap;    /* 滑动窗口位图：bit i = highest-i 位置已收 */
};

static void put64(uint8_t *p, uint64_t v)
{
    for (int i = 0; i < 8; i++)
        p[i] = (uint8_t)(v >> (56 - 8 * i));
}
static uint64_t get64(const uint8_t *p)
{
    uint64_t v = 0;
    for (int i = 0; i < 8; i++)
        v = v << 8 | p[i];
    return v;
}

/* 常量时间比较：不提前 return，时序不泄露"第几字节不同" */
static int ct_memcmp(const uint8_t *a, const uint8_t *b, size_t n)
{
    uint8_t d = 0;
    for (size_t i = 0; i < n; i++)
        d |= a[i] ^ b[i];
    return d != 0;
}

static void seal(uint64_t ctr, const uint8_t *pt, size_t plen, uint8_t *frame, size_t *flen)
{
    uint8_t nonce[12], ct[1500];
    memcpy(nonce, DIR_MAGIC, 4);
    put64(nonce + 4, ctr);
    chacha20_xor(ENC_KEY, nonce, 0, pt, ct, plen); /* counter=0：帧号在 nonce 里 */

    put64(frame, ctr);
    memcpy(frame + 8, ct, plen);
    uint8_t macin[8 + 1500];
    memcpy(macin, frame, 8);
    memcpy(macin + 8, ct, plen);
    hmac_sha256(MAC_KEY, 32, macin, 8 + plen, frame + 8 + plen);
    *flen = 8 + plen + 32;
}

/* 返回：0=收下 1=MAC 拒 2=重放拒 3=窗口外拒 */
static int unseal(struct rx *rx, const uint8_t *frame, size_t flen, uint8_t *pt, size_t *plen)
{
    uint64_t ctr = get64(frame);
    size_t clen = flen - 8 - 32;

    uint8_t tag[32], macin[8 + 1500];
    memcpy(macin, frame, 8);
    memcpy(macin + 8, frame + 8, clen);
    hmac_sha256(MAC_KEY, 32, macin, 8 + clen, tag);
    if (ct_memcmp(tag, frame + 8 + clen, 32))
        return 1;

    if (ctr > rx->highest) { /* 窗口右移 */
        uint64_t shift = ctr - rx->highest;
        rx->bitmap = shift >= WINDOW ? 0 : (rx->bitmap << shift);
        rx->bitmap |= 1;
        rx->highest = ctr;
    } else {
        /* 窗口左沿：h-(W-1)；h<W-1 时会无符号回绕成天文数字——第一版就栽在
           这（ctr 全被判"窗口外"），左沿必须下限钳到 0（run.log 排错记） */
        uint64_t left = rx->highest >= WINDOW - 1 ? rx->highest - (WINDOW - 1) : 0;
        if (ctr < left)
            return 3; /* 窗口外历史包 */
        uint64_t bit = 1ull << (rx->highest - ctr);
        if (rx->bitmap & bit)
            return 2; /* 重放 */
        rx->bitmap |= bit;
    }

    uint8_t nonce[12];
    memcpy(nonce, DIR_MAGIC, 4);
    put64(nonce + 4, ctr);
    chacha20_xor(ENC_KEY, nonce, 0, frame + 8, pt, clen);
    pt[clen] = 0; /* 调用方按字符串打印：补 NUL，别让 %s 越界读栈垃圾 */
    *plen = clen;
    return 0;
}

static const char *VERDICT[] = { "收下 ✓", "MAC 校验失败，拒收 ❌（篡改）",
                                 "重放，拒收 ❌", "窗口外旧帧，拒收 ❌" };

static int deliver(struct rx *rx, uint64_t ctr, int tamper, int quiet)
{
    uint8_t pt[64];
    snprintf((char *)pt, sizeof pt, "payload-of-frame-%llu", (unsigned long long)ctr);
    uint8_t frame[1600];
    size_t flen;
    seal(ctr, pt, strlen((char *)pt), frame, &flen);
    if (tamper)
        frame[10] ^= 0x01; /* 攻击者：翻转密文一个比特 */
    uint8_t out[1600];
    size_t olen;
    int v = unseal(rx, frame, flen, out, &olen);
    if (!quiet) {
        printf("  帧 ctr=%-4llu → %s", (unsigned long long)ctr, VERDICT[v]);
        if (v == 0)
            printf("（明文=\"%s\"）", out);
        printf("\n");
    }
    return v;
}

int main(int argc, char **argv)
{
    const char *mode = argc > 1 ? argv[1] : "normal";

    /* 自检：SHA-256/HMAC 官方向量不过验，后面全免谈 */
    uint8_t d[32];
    char hx[65];
    sha256("abc", 3, d);
    sha256_hex(d, hx);
    if (strcmp(hx, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"))
        return puts("SHA-256 自检失败"), 1;
    hmac_sha256((const uint8_t *)"key", 3, "The quick brown fox jumps over the lazy dog",
                43, d);
    sha256_hex(d, hx);
    if (strcmp(hx, "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8"))
        return puts("HMAC 自检失败"), 1;
    printf("[自检] SHA-256 与 HMAC-SHA256 官方向量 PASS\n\n");

    struct rx rx = { 0, 0 };
    printf("== 模式：%s ==\n", mode);
    if (!strcmp(mode, "normal")) {
        for (uint64_t c = 1; c <= 5; c++)
            deliver(&rx, c, 0, 0);
        printf("顺序到达全部收下；窗口 h=%llu\n\n", (unsigned long long)rx.highest);
    } else if (!strcmp(mode, "reorder")) {
        uint64_t order[] = { 1, 4, 2, 5, 3 };
        for (int i = 0; i < 5; i++)
            deliver(&rx, order[i], 0, 0);
        printf("网络乱序（UDP 常态）：窗口内的洞后补，全部放行——窗口宽度 %d 的意义\n\n",
               WINDOW);
    } else if (!strcmp(mode, "replay")) {
        for (uint64_t c = 1; c <= 5; c++)
            deliver(&rx, c, 0, 0);
        printf("攻击者重放截获的旧帧：\n");
        deliver(&rx, 3, 0, 0);
        printf("位图早标记过 ctr=3 → 重放拒绝；这正是滑动窗口的第二职能\n\n");
    } else if (!strcmp(mode, "tamper")) {
        for (uint64_t c = 1; c <= 3; c++)
            deliver(&rx, c, 0, 0);
        deliver(&rx, 4, 1, 0);
        printf("密文翻转 1 比特 → MAC 当场爆炸；EtM 顺序保证解密器永远不见脏数据\n\n");
    } else if (!strcmp(mode, "old")) {
        for (uint64_t c = 1; c <= 200; c++)
            deliver(&rx, c, 0, 1); /* 静默冲高计数器 */
        printf("(已静默收完 ctr=1..200，攻击者重发窗口外的旧帧 ctr=100：)\n");
        deliver(&rx, 100, 0, 0);
        printf("窗口左沿 = h-64 = %llu，ctr=100 落在窗外 → 历史包一律作废\n\n",
               (unsigned long long)(rx.highest - WINDOW));
    } else {
        fprintf(stderr, "未知模式：%s（normal/reorder/replay/tamper/old）\n", mode);
        return 1;
    }
    return 0;
}
