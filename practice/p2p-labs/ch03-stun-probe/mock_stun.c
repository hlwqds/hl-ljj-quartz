/* mock_stun.c —— 本地 STUN 测试服务器（离线等价演示 ch03 §3.5 的判型实验）
 *
 * 真实 STUN 服务器做的事：收到 Binding Request，把"自己看到的源地址端口"
 * 用 XOR-MAPPED-ADDRESS 回给请求方。本实现一字节不差地做这件事，外加一个
 * 教学开关：
 *   --offset N   把上报的端口号加 N——模拟"对称 NAT 换一个对端就换一个映射"：
 *                两个 offset 不同的 mock 服务器在客户端眼里就是一台对称 NAT
 *                的两个观察点（端口漂移），offset 相同则呈现 EIM（端口一致）。
 *
 * 用法：./mock_stun [端口=12040] [--offset 0]
 */
#include "net_compat.h"

#define MAGIC 0x2112A442u

static void put16(uint8_t *p, unsigned v) { p[0] = (uint8_t)(v >> 8), p[1] = (uint8_t)v; }
static void put32(uint8_t *p, uint32_t v)
{
    p[0] = (uint8_t)(v >> 24), p[1] = (uint8_t)(v >> 16);
    p[2] = (uint8_t)(v >> 8), p[3] = (uint8_t)v;
}
static unsigned get16(const uint8_t *p) { return (unsigned)p[0] << 8 | p[1]; }

int main(int argc, char **argv)
{
    int port = 12040, offset = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--offset") && i + 1 < argc)
            offset = atoi(argv[++i]);
        else
            port = atoi(argv[i]);
    }
    net_init();
    setvbuf(stdout, NULL, _IONBF, 0); /* 重定向到文件也要实时可见 */
    SOCKET s = socket(AF_INET, SOCK_DGRAM, 0);
    struct sockaddr_in me = { 0 };
    me.sin_family = AF_INET;
    me.sin_addr.s_addr = INADDR_ANY;
    me.sin_port = htons((unsigned short)port);
    if (bind(s, (struct sockaddr *)&me, sizeof me) != 0) {
        fprintf(stderr, "bind :%d 失败\n", port);
        return 1;
    }
    printf("mock STUN 已启动 :%d，上报端口偏移 +%d（≠0 即模拟对称 NAT 的映射漂移）\n",
           port, offset);

    for (;;) {
        uint8_t req[1500];
        struct sockaddr_in from;
        socklen_t fl = sizeof from;
        int n = recvfrom(s, (char *)req, sizeof req, 0, (struct sockaddr *)&from, &fl);
        if (n < 20 || get16(req) != 0x0001 || (uint32_t)((get16(req + 4) << 16) | get16(req + 6)) != MAGIC)
            continue;

        /* 应答：头 20B + XOR-MAPPED-ADDRESS（type2+len2+8B 值） */
        uint8_t resp[32];
        put16(resp, 0x0101);
        put16(resp + 2, 12);
        put16(resp + 4, MAGIC >> 16), put16(resp + 6, MAGIC & 0xFFFF);
        memcpy(resp + 8, req + 8, 12); /* 事务 ID 原样带回 */
        put16(resp + 20, 0x0020), put16(resp + 22, 8);
        resp[24] = 0, resp[25] = 0x01; /* reserved + family IPv4 */
        unsigned reported = ntohs(from.sin_port) + (unsigned)offset;
        put16(resp + 26, reported ^ (MAGIC >> 16));
        uint32_t ip = ntohl(from.sin_addr.s_addr) ^ MAGIC;
        put32(resp + 28, ip);
        sendto(s, (char *)resp, 32, 0, (struct sockaddr *)&from, fl);

        printf("binding %s:%u → 上报 %s:%u%s\n", inet_ntoa(from.sin_addr),
               ntohs(from.sin_port), inet_ntoa(from.sin_addr), reported,
               offset ? "（+offset 模拟漂移）" : "");
    }
}
