/* stun.c —— 手搓 STUN 客户端：Binding 事务 + XOR-MAPPED-ADDRESS 解析
 *          （系列 ch03 §3.5 / ch04 §4.2，RFC 5389）
 *
 * 报文 20 字节头：type(2) len(2) magic(4) txn(12)。
 * 应答里按 TLV 走属性表找 XOR-MAPPED-ADDRESS：地址与 magic cookie 异或。
 *
 * 用法：
 *   ./stun <服务器>[:端口] [<服务器2>[:端口] ...]
 * 单个服务器：打印它看到的你的公网映射；多个服务器：逐个查询并按
 * "同一本地端点在不同服务器眼中的端口是否一致" 给出映射行为判定
 * （一致 → EIM 锥形特征；漂移 → 对称特征——ch03 §3.3 的判据）。
 */
#include "net_compat.h"
#include <time.h>

#define MAGIC 0x2112A442u
#define STUN_PORT 3478
#define XOR_MAPPED 0x0020
#define MAPPED_ADDR 0x0001

static void put16(uint8_t *p, unsigned v) { p[0] = (uint8_t)(v >> 8), p[1] = (uint8_t)v; }
static unsigned get16(const uint8_t *p) { return (unsigned)p[0] << 8 | p[1]; }
static uint32_t get32(const uint8_t *p)
{
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

struct result {
    char server[64];
    char ip[24];
    int port;
    int rtt_ms;
    int ok;
};

static int query(SOCKET s, const char *server, struct result *r)
{
    char host[64] = "";
    int port = STUN_PORT;
    const char *colon = strrchr(server, ':');
    if (colon && strchr(server, ':') == colon && colon[1] >= '0' && colon[1] <= '9') {
        snprintf(host, sizeof host, "%.*s", (int)(colon - server), server);
        port = atoi(colon + 1);
    } else {
        snprintf(host, sizeof host, "%s", server);
    }
    snprintf(r->server, sizeof r->server, "%s:%d", host, port);

    struct sockaddr_in dst = { 0 };
    dst.sin_family = AF_INET;
    dst.sin_port = htons((unsigned short)port);
    dst.sin_addr.s_addr = inet_addr(host); /* 实验室只处理 IP；真实实现要 getaddrinfo */

    uint8_t req[20], resp[1500];
    put16(req, 0x0001); /* Binding Request */
    put16(req + 2, 0);
    put16(req + 4, MAGIC >> 16), put16(req + 6, MAGIC & 0xFFFF);
    srand((unsigned)time(NULL) ^ (unsigned)clock());
    for (int i = 8; i < 20; i++)
        req[i] = (uint8_t)rand();

    for (int attempt = 0; attempt < 3; attempt++) {
        clock_t t0 = clock();
        sendto(s, (char *)req, sizeof req, 0, (struct sockaddr *)&dst, sizeof dst);
        struct sockaddr_in from;
        socklen_t fl = sizeof from;
        int n = recvfrom(s, (char *)resp, sizeof resp, 0, (struct sockaddr *)&from, &fl);
        if (n < 20)
            continue; /* 超时/太短：重试 */
        if (get16(resp) != 0x0101) /* Binding Success Response */
            continue;
        if (memcmp(resp + 8, req + 8, 12) != 0)
            continue; /* Transaction ID 不匹配：不是本事务的应答 */
        int mlen = (int)get16(resp + 2);
        if (20 + mlen > n)
            continue;

        int off = 20;
        while (off + 4 <= n) {
            unsigned t = get16(resp + off), l = get16(resp + off + 2);
            const uint8_t *v = resp + off + 4;
            if (t == XOR_MAPPED && l >= 8 && v[1] == 0x01) { /* family: IPv4 */
                unsigned xport = get16(v + 2) ^ (MAGIC >> 16);
                uint32_t xip = get32(v + 4) ^ MAGIC;
                sprintf(r->ip, "%u.%u.%u.%u", xip >> 24, (xip >> 16) & 255,
                        (xip >> 8) & 255, xip & 255);
                r->port = (int)xport;
                r->rtt_ms = (int)((clock() - t0) * 1000 / CLOCKS_PER_SEC);
                r->ok = 1;
                return 0;
            }
            off += 4 + ((l + 3) & ~3u); /* 属性按 4 字节对齐步进 */
        }
    }
    r->ok = 0;
    return -1;
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "用法: %s <服务器[:端口]>... （示例: %s stun.stunprotocol.org "
                        "127.0.0.1:12041 127.0.0.1:12042）\n", argv[0], argv[0]);
        return 1;
    }
    net_init();
    struct result rs[8] = { 0 };
    int n = argc - 1 > 8 ? 8 : argc - 1;

    /* 全部查询共用一个 socket：判型实验的前提是"同一本地端点"被多个服务器观察。
     * 如果每次查询新开 socket，源端口都不一样，结论天然失真——本工程第一版
     * 就在这里翻过车（详见 run.log 的排错记录）。 */
    SOCKET s = socket(AF_INET, SOCK_DGRAM, 0);
    set_rcvtimeo(s, 500);

    printf("%-24s %-22s %s\n", "STUN 服务器", "它看到的我", "RTT");
    for (int i = 0; i < n; i++) {
        query(s, argv[i + 1], &rs[i]);
        if (rs[i].ok) {
            char seen[32];
            snprintf(seen, sizeof seen, "%s:%d", rs[i].ip, rs[i].port);
            printf("%-24s %-22s %dms\n", rs[i].server, seen, rs[i].rtt_ms);
        } else {
            printf("%-24s %s\n", rs[i].server, "(超时/无应答)");
        }
    }
    CLOSE_SOCK(s);

    int good = 0;
    for (int i = 0; i < n; i++)
        good += rs[i].ok;
    if (good >= 2) {
        int same = 1;
        for (int i = 1; i < n; i++)
            if (strcmp(rs[i].ip, rs[0].ip) || rs[i].port != rs[0].port)
                same = 0;
        printf("\n判定：同一本地端点在 %d 个服务器眼中%s\n", good,
               same ? "映射一致 → EIM（锥形）特征，打洞友好（ch04）"
                    : "映射漂移 → 对称（APDM）特征，打洞情报失真（ch03 §3.4）");
    }
    net_cleanup();
    return 0;
}
