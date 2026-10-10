/* filecast.c —— 分块传输：请求-数据块协议 + SHA-1 校验（系列 ch02 §2.3）
 *
 * BitTorrent 的微缩雏形：文件切块、按块请求、按块校验、丢了重试。
 * 协议四条文本前缀报文（全走 UDP）：
 *   HELLO                →  接收方开场，请求元数据
 *   META <n> <hex40>\n   ←  发送方报总块数与整文件 SHA-1
 *   GET  <i>\n           →  请求第 i 块
 *   DATA <i> <bytes>\n   ←  第 i 块内容（≤1024B）
 *
 * 用法（本机或局域网均可）：
 *   发送方：./filecast send <文件> [端口=12020]
 *   接收方：./filecast recv <发送方IP:端口> <输出文件>
 * 接收端自动逐块重试，最终核对整文件 SHA-1，一致才写盘退出。
 */
#include "net_compat.h"
#include "sha1.h"

#define BLOCK 1024
#define RETRY_WINDOW 50 /* 每轮等待的收包窗口数 */

#ifdef _WIN32
static void sleep_ms(int ms) { Sleep(ms); }
#else
#include <unistd.h>
static void sleep_ms(int ms) { usleep(ms * 1000); }
#endif

static int serve(const char *path, int port)
{
    FILE *f = fopen(path, "rb");
    if (!f) {
        perror(path);
        return 1;
    }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    uint8_t *blob = malloc(sz ? sz : 1);
    fread(blob, 1, sz, f);
    fclose(f);

    int nblocks = (int)((sz + BLOCK - 1) / BLOCK);
    uint8_t dig[20];
    char hex[41];
    sha1(blob, sz, dig);
    sha1_hex(dig, hex);
    printf("[send] %s %ldB = %d 块，sha1=%s… 监听 :%d\n", path, sz, nblocks, hex, port);

    SOCKET s = socket(AF_INET, SOCK_DGRAM, 0);
    struct sockaddr_in me = { 0 };
    me.sin_family = AF_INET;
    me.sin_addr.s_addr = INADDR_ANY;
    me.sin_port = htons((unsigned short)port);
    bind(s, (struct sockaddr *)&me, sizeof me);

    char *served = calloc(1, nblocks + 1);
    int nserved = 0;
    char buf[128];
    while (nserved < nblocks) {
        struct sockaddr_in from;
        socklen_t fl = sizeof from;
        int n = recvfrom(s, buf, sizeof buf - 1, 0, (struct sockaddr *)&from, &fl);
        if (n <= 0)
            continue;
        buf[n] = 0;
        if (strcmp(buf, "HELLO") == 0) {
            char meta[80];
            snprintf(meta, sizeof meta, "META %d %s", nblocks, hex);
            sendto(s, meta, (int)strlen(meta), 0, (struct sockaddr *)&from, fl);
        } else if (strncmp(buf, "GET ", 4) == 0) {
            int i = atoi(buf + 4);
            if (i < 0 || i >= nblocks)
                continue;
            char head[24];
            int hl = snprintf(head, sizeof head, "DATA %d ", i);
            long off = (long)i * BLOCK;
            int len = (int)((sz - off < BLOCK) ? sz - off : BLOCK);
            char pkt[64 + BLOCK];
            memcpy(pkt, head, hl);
            memcpy(pkt + hl, blob + off, len);
            sendto(s, pkt, hl + len, 0, (struct sockaddr *)&from, fl);
            if (!served[i]) {
                served[i] = 1;
                if (++nserved % 32 == 0 || nserved == nblocks)
                    printf("[send] 已被取走 %d/%d 块\n", nserved, nblocks);
            }
        }
    }
    printf("[send] 全部块均已被取走，退出（真实 BT 会继续做种，见 ch08）\n");
    return 0;
}

static int fetch(const char *dst_s, const char *out)
{
    char ip[64] = "127.0.0.1";
    int port = 12020;
    char *colon = strrchr(dst_s, ':');
    if (colon) {
        snprintf(ip, sizeof ip, "%.*s", (int)(colon - dst_s), dst_s);
        port = atoi(colon + 1);
    }

    SOCKET s = socket(AF_INET, SOCK_DGRAM, 0);
    set_rcvtimeo(s, 400); /* 丢包窗口：超时即进入下一轮重试 */
    struct sockaddr_in dst = { 0 };
    dst.sin_family = AF_INET;
    dst.sin_port = htons((unsigned short)port);
    dst.sin_addr.s_addr = inet_addr(ip);

    int nblocks = -1;
    char want_hex[41] = "";
    char buf[64 + BLOCK];
    while (nblocks < 0) {
        sendto(s, "HELLO", 5, 0, (struct sockaddr *)&dst, sizeof dst);
        for (int w = 0; w < RETRY_WINDOW; w++) {
            struct sockaddr_in from;
            socklen_t fl = sizeof from;
            int n = recvfrom(s, buf, sizeof buf - 1, 0, (struct sockaddr *)&from, &fl);
            if (n <= 0)
                break; /* 窗口超时，重发 HELLO */
            buf[n] = 0;
            int nb;
            char hex[64];
            if (sscanf(buf, "META %d %40s", &nb, hex) == 2) {
                nblocks = nb;
                snprintf(want_hex, sizeof want_hex, "%s", hex);
                printf("[recv] META：%d 块，整文件 sha1=%s…\n", nblocks, hex);
            }
        }
    }

    uint8_t **blocks = calloc(nblocks, sizeof *blocks);
    int *lens = calloc(nblocks, sizeof *lens); /* 末块短于 BLOCK：按实收长度记账 */
    int got = 0, npkts = 0;
    while (got < nblocks) {
        char req[32];
        for (int i = 0; i < nblocks; i++) /* 缺哪块要哪块：重试的自愈 */
            if (!blocks[i]) {
                snprintf(req, sizeof req, "GET %d", i);
                sendto(s, req, (int)strlen(req), 0, (struct sockaddr *)&dst, sizeof dst);
            }
        for (int w = 0; w < RETRY_WINDOW; w++) {
            struct sockaddr_in from;
            socklen_t fl = sizeof from;
            int n = recvfrom(s, buf, sizeof buf, 0, (struct sockaddr *)&from, &fl);
            if (n <= 0)
                break;
            if (strncmp(buf, "DATA ", 5) == 0) {
                int i = atoi(buf + 5);
                char *p = buf + 5; /* 跳过块号，找到载荷前的第二个空格 */
                while (*p >= '0' && *p <= '9')
                    p++;
                if (*p == ' ' && i >= 0 && i < nblocks && !blocks[i]) {
                    int head = (int)(p - buf) + 1;
                    blocks[i] = malloc(n - head);
                    memcpy(blocks[i], buf + head, n - head);
                    lens[i] = n - head;
                    got++;
                }
                npkts++;
            }
        }
        printf("[recv] %d/%d 块（收包 %d，含重试冗余）\r", got, nblocks, npkts);
        fflush(stdout);
    }

    long total = 0;
    for (int i = 0; i < nblocks; i++)
        total += lens[i];
    uint8_t *blob = malloc(total);
    long off = 0;
    for (int i = 0; i < nblocks; i++) {
        memcpy(blob + off, blocks[i], lens[i]);
        off += lens[i];
    }
    uint8_t dig[20];
    char hex[41];
    sha1(blob, off, dig);
    sha1_hex(dig, hex);
    printf("\n[recv] 拼回 %ldB，sha1=%s\n", off, hex);
    if (strcmp(hex, want_hex) == 0) {
        FILE *f = fopen(out, "wb");
        fwrite(blob, 1, off, f);
        fclose(f);
        printf("[recv] SHA-1 核对通过，已写 %s\n", out);
        return 0;
    }
    fprintf(stderr, "[recv] 摘要不匹配！拒绝写盘（永远不要信任网络另一端）\n");
    return 1;
}

int main(int argc, char **argv)
{
    net_init();
    int rc;
    if (argc >= 4 && !strcmp(argv[1], "send"))
        rc = serve(argv[2], argc > 3 ? atoi(argv[3]) : 12020);
    else if (argc >= 4 && !strcmp(argv[1], "recv"))
        rc = fetch(argv[2], argv[3]);
    else {
        fprintf(stderr, "用法: %s send <文件> [端口] | recv <IP:端口> <输出文件>\n", argv[0]);
        rc = 2;
    }
    net_cleanup();
    return rc;
}
