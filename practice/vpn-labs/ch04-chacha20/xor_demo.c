/* xor_demo.c —— XOR 加密的两种死法现场（系列 ch04 §4.1）
 *
 * 死法一（密钥复用互消）：同一条"密钥流"加密两条消息，
 *   C1 ⊕ C2 = P1 ⊕ P2 —— 密钥消掉，两明文的差异直接裸奔。
 * 死法二（已知明文还魂）：隧道里封装的是 IP 包，头 20 字节高度可预测；
 *   已知明文 ⊕ 密文 = 一段密钥流，同密钥下可解其它密文的同位置前缀。
 *
 * 构建：zig cc -o xor_demo xor_demo.c
 */
#include <stdio.h>
#include <string.h>

static const char *K =
    "SuperSecretKeyUsedOnlyOnceTheySaid0123456789abcdef"; /* 56B "密钥流" */

static void xor_str(const char *p, unsigned char *c, int n)
{
    for (int i = 0; i < n; i++)
        c[i] = (unsigned char)(p[i] ^ K[i]);
}

static void dump_ascii(const unsigned char *b, int n)
{
    for (int i = 0; i < n; i++)
        putchar(b[i] >= 0x20 && b[i] < 0x7f ? b[i] : '.');
    putchar('\n');
}

int main(void)
{
    /* ---------- 死法一：密钥复用，两条密文互消 ---------- */
    const char *p1 = "GET /index.html HTTP/1.1 Host: example.com";
    const char *p2 = "GET /admin?x=1  HTTP/1.1 Host: example.com";
    int n = (int)strlen(p1);
    unsigned char c1[64], c2[64], x[64];

    xor_str(p1, c1, n);
    xor_str(p2, c2, n);
    for (int i = 0; i < n; i++)
        x[i] = c1[i] ^ c2[i];

    printf("== 死法一：密钥复用 ==\n");
    printf("明文1: %s\n", p1);
    printf("明文2: %s\n", p2);
    printf("C1⊕C2（密钥已消掉，只剩两明文的差异）:\n    ");
    dump_ascii(x, n);
    printf("    ↑ 相同位置全为 .（泄露\"两处明文相等\"），不同处直接可见差异。\n");
    printf("    攻击者从此起步：拿一处的猜测去试另一处（crib dragging）。\n\n");

    /* ---------- 死法二：已知明文还原密钥流 ---------- */
    unsigned char ip_pkt[32]; /* 伪造一个"隧道内的 IP 包\"前 32B */
    memset(ip_pkt, 0, sizeof ip_pkt);
    ip_pkt[0] = 0x45;                       /* 版本 4 + 头长 5 —— 永远可猜 */
    ip_pkt[1] = 0x00;                       /* DS */
    ip_pkt[9] = 0x06;                       /* 协议 TCP */
    ip_pkt[16] = 10;
    ip_pkt[17] = 7;                         /* 源 10.7.0.1（隧道内网段，也可猜） */
    ip_pkt[18] = 0;
    ip_pkt[19] = 1;
    unsigned char c3[32], ks[32];
    for (int i = 0; i < 32; i++)
        c3[i] = ip_pkt[i] ^ K[i];
    for (int i = 0; i < 32; i++)
        ks[i] = c3[i] ^ ip_pkt[i]; /* 攻击者：已知明文 ⊕ 密文 */

    printf("== 死法二：已知明文 ==\n");
    printf("密文（前 32B）: ");
    for (int i = 0; i < 32; i++)
        printf("%02x", c3[i]);
    printf("\n攻击者猜头 20B（45 00 … 06 … 0a070001），还原密钥流前 20B: ");
    for (int i = 0; i < 20; i++)
        printf("%02x", ks[i]);
    printf("\n比对真实密钥流前 20B:                          ");
    for (int i = 0; i < 20; i++)
        printf("%02x", (unsigned char)K[i]);
    printf("\n→ 完全一致。同一 (key,nonce) 下的后续密文同位置全部可解。\n");
    printf("结论：问题从来不是 XOR，是密钥流重复——所以流密码的全部纪律在 nonce。\n");
    return 0;
}
